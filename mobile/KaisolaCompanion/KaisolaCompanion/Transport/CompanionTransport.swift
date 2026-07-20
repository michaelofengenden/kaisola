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
    private var connectionEndpoint: NWEndpoint?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectionDeadlineWorkItem: DispatchWorkItem?
    private var intentionallyStopped = true
    private let autoConnect: Bool
    private var preferredEndpoint: NWEndpoint?
    private var targetDesktopId: String?

    init(autoConnect: Bool = true) {
        self.autoConnect = autoConnect
    }

    func startDiscovery(
        preferred hint: CompanionPairingTransportHint? = nil,
        desktopId: String? = nil,
        force: Bool = false
    ) {
        let nextPreferred = Self.directEndpoint(from: hint)
        let normalizedDesktopId = desktopId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameTarget = targetDesktopId == normalizedDesktopId
            && Self.endpointKey(preferredEndpoint) == Self.endpointKey(nextPreferred)
        // App launch and scene activation can arrive together. Reasserting the
        // same target must not cancel a healthy connection or its handshake.
        if !force, !intentionallyStopped, sameTarget, browser != nil {
            if state == .live || connection != nil { return }
            connectBestAvailable(reconnecting: state == .reconnecting)
            return
        }

        stopResources()
        intentionallyStopped = false
        reconnectAttempt = 0
        preferredEndpoint = nextPreferred
        targetDesktopId = normalizedDesktopId
        selectedEndpoint = nil
        discoveredDesktops = []
        transition(to: .discovering)
        startBrowser()
        if let preferredEndpoint {
            selectedEndpoint = preferredEndpoint
            connect(to: preferredEndpoint, reconnecting: false)
        }
    }

    private func startBrowser() {
        guard browser == nil, !intentionallyStopped else { return }
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
                    guard self.browser === browser else { return }
                    self.browser = nil
                    self.onError?(error)
                    if self.connection == nil { self.scheduleReconnect() }
                }
            }
        }
        browser.start(queue: queue)
    }

    func connect(to desktop: CompanionDiscoveredDesktop) {
        intentionallyStopped = false
        selectedEndpoint = desktop.endpoint
        reconnectAttempt = 0
        connect(to: desktop.endpoint, reconnecting: false)
    }

    func markLive() {
        guard state == .handshaking else { return }
        connectionDeadlineWorkItem?.cancel()
        connectionDeadlineWorkItem = nil
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
        connectionEndpoint = nil
        preferredEndpoint = nil
        targetDesktopId = nil
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
        guard autoConnect, let candidate = preferredDiscoveredDesktop() else { return }
        if connection == nil {
            selectedEndpoint = candidate.endpoint
            connect(to: candidate.endpoint, reconnecting: state == .reconnecting)
            return
        }
        // A QR's direct address is only a launch accelerator. Bonjour carries
        // the stable paired-Mac identity and wins before authentication if the
        // listener port or network changed.
        if state != .live,
           Self.endpointKey(connectionEndpoint) != Self.endpointKey(candidate.endpoint) {
            selectedEndpoint = candidate.endpoint
            connect(to: candidate.endpoint, reconnecting: true)
        }
    }

    private func connect(to endpoint: NWEndpoint, reconnecting: Bool) {
        reconnectWorkItem?.cancel()
        connectionDeadlineWorkItem?.cancel()
        connection?.cancel()
        decoder = CompanionLengthFrameDecoder()
        connectionEndpoint = endpoint
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
                    self.connectionDeadlineWorkItem?.cancel()
                    self.connectionDeadlineWorkItem = nil
                    self.transition(to: .handshaking)
                    // A TCP socket can be ready while the peer is stale or an
                    // old listener never completes Noise. Bound that state too
                    // so foreground recovery cannot remain stuck indefinitely.
                    self.armConnectionDeadline(for: connection, after: 8)
                    self.receiveNext(on: connection)
                case let .failed(error):
                    self.onError?(error)
                    let failedEndpoint = self.connectionEndpoint
                    self.connectionDeadlineWorkItem?.cancel()
                    self.connectionDeadlineWorkItem = nil
                    self.connection = nil
                    self.connectionEndpoint = nil
                    self.selectedEndpoint = nil
                    if let discovered = self.preferredDiscoveredDesktop(),
                       Self.endpointKey(discovered.endpoint) != Self.endpointKey(failedEndpoint) {
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
        armConnectionDeadline(for: connection)
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
        connectionDeadlineWorkItem?.cancel()
        connectionDeadlineWorkItem = nil
        connection?.cancel()
        connection = nil
        connectionEndpoint = nil
        transition(to: .reconnecting)
        reconnectWorkItem?.cancel()
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        reconnectAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.intentionallyStopped else { return }
                if self.browser == nil { self.startBrowser() }
                if let discovered = self.preferredDiscoveredDesktop() {
                    self.selectedEndpoint = discovered.endpoint
                    self.connect(to: discovered.endpoint, reconnecting: true)
                } else if let preferred = self.preferredEndpoint {
                    self.selectedEndpoint = preferred
                    self.connect(to: preferred, reconnecting: true)
                } else if let endpoint = self.selectedEndpoint {
                    self.connect(to: endpoint, reconnecting: true)
                } else if self.browser != nil {
                    self.transition(to: .discovering)
                } else {
                    self.startBrowser()
                    self.transition(to: .discovering)
                }
            }
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func stopResources() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connectionDeadlineWorkItem?.cancel()
        connectionDeadlineWorkItem = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        connectionEndpoint = nil
    }

    private func connectBestAvailable(reconnecting: Bool) {
        if browser == nil { startBrowser() }
        if let discovered = preferredDiscoveredDesktop() {
            selectedEndpoint = discovered.endpoint
            connect(to: discovered.endpoint, reconnecting: reconnecting)
        } else if let preferredEndpoint {
            selectedEndpoint = preferredEndpoint
            connect(to: preferredEndpoint, reconnecting: reconnecting)
        } else {
            transition(to: .discovering)
        }
    }

    private func preferredDiscoveredDesktop() -> CompanionDiscoveredDesktop? {
        Self.preferredDesktop(in: discoveredDesktops, desktopId: targetDesktopId)
    }

    private func armConnectionDeadline(for connection: NWConnection, after seconds: TimeInterval = 5) {
        connectionDeadlineWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak connection] in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, connection === self.connection,
                      self.state == .connecting || self.state == .reconnecting || self.state == .handshaking else { return }
                self.scheduleReconnect()
            }
        }
        connectionDeadlineWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
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

    static func preferredDesktop(
        in desktops: [CompanionDiscoveredDesktop],
        desktopId: String?
    ) -> CompanionDiscoveredDesktop? {
        guard let desktopId, !desktopId.isEmpty else { return desktops.first }
        let wanted = serviceInstanceName(for: desktopId)
        return desktops.first { desktop in
            guard case let .service(name, _, _, _) = desktop.endpoint else { return false }
            return name.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    static func serviceInstanceName(for desktopId: String) -> String {
        let ascii = desktopId.unicodeScalars.filter { scalar in
            let value = scalar.value
            return (48...57).contains(value) || (65...90).contains(value)
                || (97...122).contains(value) || value == 45
        }
        let clean = String(String.UnicodeScalarView(ascii))
        return "Kaisola-\(String(clean.suffix(16)).isEmpty ? "desktop" : String(clean.suffix(16)))"
    }

    private static func endpointKey(_ endpoint: NWEndpoint?) -> String? {
        endpoint.map(String.init(describing:))
    }
}
