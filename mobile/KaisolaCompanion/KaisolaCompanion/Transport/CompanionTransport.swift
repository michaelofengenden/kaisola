@preconcurrency import Network
import Foundation

enum CompanionTransportState: String, Codable, Hashable, Sendable {
    case idle
    case discovering
    case connecting
    case handshaking
    case live
    case reconnecting

    var storeState: CompanionConnectionState {
        switch self {
        case .live: .live
        case .reconnecting, .connecting, .handshaking, .discovering: .reconnecting
        case .idle: .offline
        }
    }
}

struct CompanionDiscoveredDesktop: Identifiable, Hashable, @unchecked Sendable {
    let endpoint: NWEndpoint
    let name: String

    var id: String { String(describing: endpoint) }
}

@MainActor
final class CompanionTransport: ObservableObject {
    @Published private(set) var state: CompanionTransportState = .idle
    @Published private(set) var discoveredDesktops: [CompanionDiscoveredDesktop] = []

    var onWireFrame: ((Data) throws -> Void)?
    var onStateChange: ((CompanionTransportState) -> Void)?
    var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.kaisola.companion.transport", qos: .userInitiated)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var decoder = CompanionLengthFrameDecoder()
    private var selectedEndpoint: NWEndpoint?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var intentionallyStopped = true
    private let autoConnect: Bool
    private var preferredEndpoint: NWEndpoint?

    init(autoConnect: Bool = true) {
        self.autoConnect = autoConnect
    }

    func startDiscovery(preferred hint: CompanionPairingTransportHint? = nil) {
        stopResources()
        intentionallyStopped = false
        reconnectAttempt = 0
        preferredEndpoint = Self.directEndpoint(from: hint)
        selectedEndpoint = nil
        discoveredDesktops = []
        transition(to: .discovering)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_kaisola._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.update(results: results)
            }
        }
        browser.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case let .failed(error) = newState {
                    self.onError?(error)
                    if self.connection == nil { self.scheduleReconnect() }
                }
            }
        }
        browser.start(queue: queue)
        if let preferredEndpoint {
            selectedEndpoint = preferredEndpoint
            connect(to: preferredEndpoint, reconnecting: false)
        }
    }

    func connect(to desktop: CompanionDiscoveredDesktop) {
        intentionallyStopped = false
        selectedEndpoint = desktop.endpoint
        reconnectAttempt = 0
        connect(to: desktop.endpoint, reconnecting: false)
    }

    func markLive() {
        guard state == .handshaking else { return }
        reconnectAttempt = 0
        transition(to: .live)
    }

    func send(_ payload: Data) throws {
        guard let connection, state == .handshaking || state == .live else {
            throw CompanionWireError.connectionUnavailable
        }
        let framed = try CompanionLengthFrameDecoder.encode(payload)
        connection.send(content: framed, completion: .contentProcessed { [weak self, weak connection] error in
            guard let error else { return }
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, connection === self.connection else { return }
                self.onError?(error)
                self.scheduleReconnect()
            }
        })
    }

    func stop() {
        intentionallyStopped = true
        stopResources()
        selectedEndpoint = nil
        preferredEndpoint = nil
        discoveredDesktops = []
        transition(to: .idle)
    }

    private func update(results: Set<NWBrowser.Result>) {
        let desktops: [CompanionDiscoveredDesktop] = results.map { result in
            let name: String
            if case let .service(serviceName, _, _, _) = result.endpoint { name = serviceName }
            else { name = String(describing: result.endpoint) }
            return CompanionDiscoveredDesktop(endpoint: result.endpoint, name: name)
        }.sorted { (left: CompanionDiscoveredDesktop, right: CompanionDiscoveredDesktop) in
            left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        discoveredDesktops = desktops
        guard autoConnect, connection == nil, let first = desktops.first else { return }
        selectedEndpoint = first.endpoint
        connect(to: first.endpoint, reconnecting: state == .reconnecting)
    }

    private func connect(to endpoint: NWEndpoint, reconnecting: Bool) {
        reconnectWorkItem?.cancel()
        connection?.cancel()
        decoder = CompanionLengthFrameDecoder()
        transition(to: reconnecting ? .reconnecting : .connecting)

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, connection === self.connection else { return }
                switch newState {
                case .ready:
                    self.transition(to: .handshaking)
                    self.receiveNext(on: connection)
                case let .failed(error):
                    self.onError?(error)
                    self.connection = nil
                    self.selectedEndpoint = nil
                    if let discovered = self.discoveredDesktops.first {
                        self.selectedEndpoint = discovered.endpoint
                        self.connect(to: discovered.endpoint, reconnecting: true)
                        return
                    }
                    self.scheduleReconnect()
                case .cancelled:
                    if !self.intentionallyStopped { self.scheduleReconnect() }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self, weak connection] content, _, isComplete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, connection === self.connection else { return }
                do {
                    if let content, !content.isEmpty {
                        for frame in try self.decoder.push(content) {
                            try self.onWireFrame?(frame)
                        }
                    }
                } catch {
                    self.onError?(error)
                    self.scheduleReconnect()
                    return
                }
                if let error {
                    self.onError?(error)
                    self.scheduleReconnect()
                } else if isComplete {
                    self.scheduleReconnect()
                } else {
                    self.receiveNext(on: connection)
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !intentionallyStopped else { return }
        connection?.cancel()
        connection = nil
        transition(to: .reconnecting)
        reconnectWorkItem?.cancel()
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        reconnectAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.intentionallyStopped else { return }
                if let endpoint = self.selectedEndpoint {
                    self.connect(to: endpoint, reconnecting: true)
                } else if let discovered = self.discoveredDesktops.first {
                    self.selectedEndpoint = discovered.endpoint
                    self.connect(to: discovered.endpoint, reconnecting: true)
                } else if let preferred = self.preferredEndpoint {
                    self.selectedEndpoint = preferred
                    self.connect(to: preferred, reconnecting: true)
                } else if self.browser != nil {
                    self.transition(to: .discovering)
                } else {
                    self.startDiscovery()
                }
            }
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func stopResources() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
    }

    private func transition(to newState: CompanionTransportState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    static func directEndpoint(from hint: CompanionPairingTransportHint?) -> NWEndpoint? {
        guard let host = hint?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              let portValue = hint?.port,
              (1...65_535).contains(portValue),
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}
