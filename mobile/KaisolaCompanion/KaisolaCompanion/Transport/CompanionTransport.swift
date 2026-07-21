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

enum CompanionTransportRoute: String, Codable, Hashable, Sendable {
    case none
    case lan
    case tailscale
    case kaisolaLink

    var title: String {
        switch self {
        case .none: "Automatic"
        case .lan: "Nearby"
        case .tailscale: "Private"
        case .kaisolaLink: "Kaisola Link"
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
    @Published private(set) var route: CompanionTransportRoute = .none

    var onWireFrame: ((Data) throws -> Void)?
    var onStateChange: ((CompanionTransportState) -> Void)?
    var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "com.kaisola.companion.transport", qos: .userInitiated)
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var connection: NWConnection?
    private let linkConnection = KaisolaLinkConnection()
    private var decoder = CompanionLengthFrameDecoder()
    private var selectedEndpoint: NWEndpoint?
    private var connectionEndpoint: NWEndpoint?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectionDeadlineWorkItem: DispatchWorkItem?
    private var alternateFallbackWorkItem: DispatchWorkItem?
    private var intentionallyStopped = true
    private let autoConnect: Bool
    private var preferredEndpoint: NWEndpoint?
    private var tailscaleEndpoint: NWEndpoint?
    private var targetDesktopId: String?
    private var targetDeviceId: String?
    private var preferTailscale = false
    private var preferLink = false
    private var linkBaseURL: URL?
    private var linkTokenProvider: KaisolaLinkConnection.TokenProvider?

    init(autoConnect: Bool = true) {
        self.autoConnect = autoConnect
        linkConnection.onEvent = { [weak self] event in
            self?.handleLinkEvent(event)
        }
    }

    func configureKaisolaLink(
        baseURL: URL?,
        tokenProvider: KaisolaLinkConnection.TokenProvider?
    ) {
        linkBaseURL = baseURL.flatMap { KaisolaLinkConnection.ticketURL(baseURL: $0) == nil ? nil : $0 }
        linkTokenProvider = tokenProvider
        if !intentionallyStopped, state != .live, connection == nil, !linkConnection.isActive {
            nudgeReconnect()
        }
    }

    func startDiscovery(
        preferred hint: CompanionPairingTransportHint? = nil,
        desktopId: String? = nil,
        deviceId: String? = nil,
        force: Bool = false
    ) {
        let nextPreferred = Self.directEndpoint(from: hint)
        let nextTailscale = Self.tailscaleEndpoint(from: hint)
        let normalizedDesktopId = desktopId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDeviceId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameTarget = targetDesktopId == normalizedDesktopId
            && targetDeviceId == normalizedDeviceId
            && Self.endpointKey(preferredEndpoint) == Self.endpointKey(nextPreferred)
            && Self.endpointKey(tailscaleEndpoint) == Self.endpointKey(nextTailscale)
        // App launch and scene activation can arrive together. Reasserting the
        // same target must not cancel a healthy connection or its handshake.
        if !force, !intentionallyStopped, sameTarget, browser != nil {
            if state == .live || connection != nil || linkConnection.isActive { return }
            connectBestAvailable(reconnecting: state == .reconnecting)
            return
        }

        stopResources()
        intentionallyStopped = false
        reconnectAttempt = 0
        preferredEndpoint = nextPreferred
        tailscaleEndpoint = nextTailscale
        targetDesktopId = normalizedDesktopId
        targetDeviceId = normalizedDeviceId
        preferTailscale = false
        preferLink = false
        selectedEndpoint = nil
        discoveredDesktops = []
        transition(to: .discovering)
        startPathMonitor()
        startBrowser()
        if let preferredEndpoint {
            selectedEndpoint = preferredEndpoint
            connect(to: preferredEndpoint, reconnecting: false)
        } else if let tailscaleEndpoint {
            preferTailscale = true
            selectedEndpoint = tailscaleEndpoint
            connect(to: tailscaleEndpoint, reconnecting: false)
        } else if canUseLink {
            preferLink = true
            connectLink(reconnecting: false)
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
                    if self.connection == nil && !self.linkConnection.isActive { self.scheduleReconnect() }
                }
            }
        }
        browser.start(queue: queue)
    }

    func connect(to desktop: CompanionDiscoveredDesktop) {
        intentionallyStopped = false
        preferTailscale = false
        preferLink = false
        selectedEndpoint = desktop.endpoint
        reconnectAttempt = 0
        connect(to: desktop.endpoint, reconnecting: false)
    }

    /// Lifecycle callbacks can arrive while the transport is already marked
    /// reconnecting. Give that existing attempt an immediate nudge without
    /// cancelling a TCP/Noise handshake that is still inside its deadline.
    func nudgeReconnect() {
        guard !intentionallyStopped, state != .live else { return }
        if connection != nil || linkConnection.isReady { return }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        connectBestAvailable(reconnecting: true)
    }

    func markLive() {
        guard state == .handshaking else { return }
        connectionDeadlineWorkItem?.cancel()
        connectionDeadlineWorkItem = nil
        reconnectAttempt = 0
        alternateFallbackWorkItem?.cancel()
        alternateFallbackWorkItem = nil
        transition(to: .live)
    }

    func send(_ payload: Data) throws {
        guard state == .handshaking || state == .live else {
            throw CompanionWireError.connectionUnavailable
        }
        let framed = try CompanionLengthFrameDecoder.encode(payload)
        if route == .kaisolaLink {
            try linkConnection.send(framed)
            return
        }
        guard let connection else { throw CompanionWireError.connectionUnavailable }
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
        tailscaleEndpoint = nil
        targetDesktopId = nil
        targetDeviceId = nil
        preferTailscale = false
        preferLink = false
        route = .none
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
        // Never replace a socket while TCP or Noise is still negotiating.
        // Bonjour result identities can churn as interfaces wake, and each
        // update used to cancel the in-flight secure resume before it could
        // become live. The existing deadline/failure path chooses this Bonjour
        // candidate immediately if the current direct endpoint is actually stale.
        guard Self.mayAdoptDiscoveredEndpoint(hasConnection: connection != nil || linkConnection.isReady) else { return }
        preferTailscale = false
        preferLink = false
        selectedEndpoint = candidate.endpoint
        connect(to: candidate.endpoint, reconnecting: state == .reconnecting)
    }

    private func connect(to endpoint: NWEndpoint, reconnecting: Bool) {
        reconnectWorkItem?.cancel()
        connectionDeadlineWorkItem?.cancel()
        alternateFallbackWorkItem?.cancel()
        linkConnection.cancel(notify: false)
        connection?.cancel()
        decoder = CompanionLengthFrameDecoder()
        connectionEndpoint = endpoint
        route = isTailscale(endpoint) ? .tailscale : .lan
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
                        self.preferTailscale = false
                        self.selectedEndpoint = discovered.endpoint
                        self.connect(to: discovered.endpoint, reconnecting: true)
                        return
                    }
                    if !self.isTailscale(failedEndpoint), let tailscale = self.tailscaleEndpoint {
                        self.preferTailscale = true
                        self.preferLink = false
                        self.selectedEndpoint = tailscale
                        self.connect(to: tailscale, reconnecting: true)
                        return
                    }
                    if self.canUseLink {
                        self.preferTailscale = false
                        self.preferLink = true
                        self.connectLink(reconnecting: true)
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
        armAlternateFallback(for: connection)
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
        alternateFallbackWorkItem?.cancel()
        alternateFallbackWorkItem = nil
        linkConnection.cancel(notify: false)
        connection?.cancel()
        connection = nil
        connectionEndpoint = nil
        route = .none
        transition(to: .reconnecting)
        reconnectWorkItem?.cancel()
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        reconnectAttempt += 1
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.intentionallyStopped else { return }
                if self.browser == nil { self.startBrowser() }
                if let discovered = self.preferredDiscoveredDesktop() {
                    self.preferTailscale = false
                    self.selectedEndpoint = discovered.endpoint
                    self.connect(to: discovered.endpoint, reconnecting: true)
                } else if self.preferTailscale, let tailscale = self.tailscaleEndpoint {
                    self.selectedEndpoint = tailscale
                    self.connect(to: tailscale, reconnecting: true)
                } else if self.preferLink, self.canUseLink {
                    self.connectLink(reconnecting: true)
                } else if let preferred = self.preferredEndpoint {
                    self.selectedEndpoint = preferred
                    self.connect(to: preferred, reconnecting: true)
                } else if let tailscale = self.tailscaleEndpoint {
                    self.preferTailscale = true
                    self.selectedEndpoint = tailscale
                    self.connect(to: tailscale, reconnecting: true)
                } else if self.canUseLink {
                    self.preferLink = true
                    self.connectLink(reconnecting: true)
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
        alternateFallbackWorkItem?.cancel()
        alternateFallbackWorkItem = nil
        browser?.cancel()
        browser = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
        connection?.cancel()
        connection = nil
        connectionEndpoint = nil
        linkConnection.cancel(notify: false)
        route = .none
    }

    private func connectBestAvailable(reconnecting: Bool) {
        if browser == nil { startBrowser() }
        if let discovered = preferredDiscoveredDesktop() {
            preferTailscale = false
            selectedEndpoint = discovered.endpoint
            connect(to: discovered.endpoint, reconnecting: reconnecting)
        } else if preferTailscale, let tailscaleEndpoint {
            selectedEndpoint = tailscaleEndpoint
            connect(to: tailscaleEndpoint, reconnecting: reconnecting)
        } else if preferLink, canUseLink {
            connectLink(reconnecting: reconnecting)
        } else if let preferredEndpoint {
            selectedEndpoint = preferredEndpoint
            connect(to: preferredEndpoint, reconnecting: reconnecting)
        } else if let tailscaleEndpoint {
            preferTailscale = true
            selectedEndpoint = tailscaleEndpoint
            connect(to: tailscaleEndpoint, reconnecting: reconnecting)
        } else if canUseLink {
            preferLink = true
            connectLink(reconnecting: reconnecting)
        } else {
            transition(to: .discovering)
        }
    }

    private func armAlternateFallback(for direct: NWConnection, after seconds: TimeInterval = 1.8) {
        guard !isTailscale(connectionEndpoint), tailscaleEndpoint != nil || canUseLink else { return }
        alternateFallbackWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak direct] in
            Task { @MainActor [weak self, weak direct] in
                guard let self, let direct, direct === self.connection,
                      self.state == .connecting || self.state == .reconnecting else { return }
                if let tailscaleEndpoint = self.tailscaleEndpoint {
                    self.preferTailscale = true
                    self.preferLink = false
                    self.selectedEndpoint = tailscaleEndpoint
                    self.connect(to: tailscaleEndpoint, reconnecting: true)
                } else {
                    self.preferLink = true
                    self.connectLink(reconnecting: true)
                }
            }
        }
        alternateFallbackWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func isTailscale(_ endpoint: NWEndpoint?) -> Bool {
        Self.endpointKey(endpoint) == Self.endpointKey(tailscaleEndpoint)
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            Task { @MainActor [weak self, weak monitor] in
                guard let self, let monitor, monitor === self.pathMonitor, !self.intentionallyStopped else { return }
                let signature = [
                    path.status == .satisfied ? "online" : path.status == .requiresConnection ? "waiting" : "offline",
                    path.usesInterfaceType(.wifi) ? "wifi" : "",
                    path.usesInterfaceType(.cellular) ? "cellular" : "",
                    path.usesInterfaceType(.wiredEthernet) ? "wired" : "",
                ].joined(separator: ":")
                let previous = self.lastPathSignature
                self.lastPathSignature = signature
                guard path.status == .satisfied, self.state != .live else { return }
                if path.usesInterfaceType(.cellular), let tailscale = self.tailscaleEndpoint,
                   !self.isTailscale(self.connectionEndpoint) {
                    self.preferTailscale = true
                    self.selectedEndpoint = tailscale
                    self.connect(to: tailscale, reconnecting: self.state != .discovering)
                    return
                }
                if path.usesInterfaceType(.cellular), self.canUseLink,
                   self.route != .kaisolaLink {
                    self.preferTailscale = false
                    self.preferLink = true
                    self.connectLink(reconnecting: self.state != .discovering)
                    return
                }
                guard previous != nil, previous != signature else { return }
                self.preferTailscale = false
                self.preferLink = false
                self.connectionDeadlineWorkItem?.cancel()
                self.connectionDeadlineWorkItem = nil
                self.connection?.cancel()
                self.connection = nil
                self.connectionEndpoint = nil
                self.selectedEndpoint = nil
                self.nudgeReconnect()
            }
        }
        monitor.start(queue: queue)
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
                if !self.isTailscale(self.connectionEndpoint), let tailscale = self.tailscaleEndpoint {
                    self.preferTailscale = true
                    self.preferLink = false
                    self.selectedEndpoint = tailscale
                    self.connect(to: tailscale, reconnecting: true)
                } else if self.canUseLink {
                    self.preferTailscale = false
                    self.preferLink = true
                    self.connectLink(reconnecting: true)
                } else {
                    self.scheduleReconnect()
                }
            }
        }
        connectionDeadlineWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private var canUseLink: Bool {
        linkBaseURL != nil
            && linkTokenProvider != nil
            && targetDesktopId?.isEmpty == false
            && targetDeviceId?.isEmpty == false
    }

    private func connectLink(reconnecting: Bool) {
        guard let baseURL = linkBaseURL,
              let tokenProvider = linkTokenProvider,
              let desktopId = targetDesktopId,
              let deviceId = targetDeviceId else {
            scheduleReconnect()
            return
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        connectionDeadlineWorkItem?.cancel()
        connectionDeadlineWorkItem = nil
        alternateFallbackWorkItem?.cancel()
        alternateFallbackWorkItem = nil
        connection?.cancel()
        connection = nil
        connectionEndpoint = nil
        selectedEndpoint = nil
        decoder = CompanionLengthFrameDecoder()
        route = .kaisolaLink
        transition(to: reconnecting ? .reconnecting : .connecting)
        linkConnection.connect(
            baseURL: baseURL,
            desktopId: desktopId,
            deviceId: deviceId,
            tokenProvider: tokenProvider
        )
    }

    private func handleLinkEvent(_ event: KaisolaLinkConnection.Event) {
        guard !intentionallyStopped, route == .kaisolaLink else { return }
        switch event {
        case .ready:
            guard state != .live else { return }
            decoder = CompanionLengthFrameDecoder()
            reconnectAttempt = 0
            transition(to: .handshaking)
            armLinkHandshakeDeadline()
        case .waiting:
            connectionDeadlineWorkItem?.cancel()
            connectionDeadlineWorkItem = nil
            decoder = CompanionLengthFrameDecoder()
            if state != .reconnecting { transition(to: .reconnecting) }
        case let .data(data):
            do {
                for frame in try decoder.push(data) { try onWireFrame?(frame) }
            } catch {
                onError?(error)
                scheduleReconnect()
            }
        case let .failed(error):
            onError?(error)
            scheduleReconnect()
        case .closed:
            scheduleReconnect()
        }
    }

    private func transition(to newState: CompanionTransportState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    private func armLinkHandshakeDeadline(after seconds: TimeInterval = 8) {
        connectionDeadlineWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.intentionallyStopped,
                      self.route == .kaisolaLink,
                      self.state == .handshaking else { return }
                self.scheduleReconnect()
            }
        }
        connectionDeadlineWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    static func directEndpoint(from hint: CompanionPairingTransportHint?) -> NWEndpoint? {
        guard let host = hint?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              let portValue = hint?.port,
              (1...65_535).contains(portValue),
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    static func tailscaleEndpoint(from hint: CompanionPairingTransportHint?) -> NWEndpoint? {
        guard let host = hint?.tailscaleHost?.trimmingCharacters(in: .whitespacesAndNewlines),
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

    /// Endpoint election is deliberately sticky for the lifetime of an
    /// in-flight TCP/Noise attempt. Exposed for the reconnect regression test.
    static func mayAdoptDiscoveredEndpoint(hasConnection: Bool) -> Bool {
        !hasConnection
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
