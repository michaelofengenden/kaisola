import Combine
import Foundation
import KaisolaCore

enum CompanionRelayError: LocalizedError, Equatable {
    case unavailable
    case authenticationRequired
    case invalidResponse
    case disconnected
    case slowConsumer

    var errorDescription: String? {
        switch self {
        case .unavailable: "Kaisola Link is temporarily unavailable."
        case .authenticationRequired: "Sign in again to reconnect through Kaisola Link."
        case .invalidResponse: "Kaisola Link returned an invalid response."
        case .disconnected: "Kaisola Link disconnected."
        case .slowConsumer: "Kaisola Link closed a slow connection."
        }
    }
}

enum CompanionRelayMux {
    enum Kind: UInt8, Sendable {
        case open = 1
        case data = 2
        case close = 3
    }

    struct Frame: Equatable, Sendable {
        let kind: Kind
        let channelID: String
        let payload: Data
    }

    static let version: UInt8 = 1
    static let channelIDBytes = 22
    static let maximumMessageBytes = 2 * 1_024 * 1_024
    static let frameOverhead = 64
    static let maximumDevicePayloadBytes = maximumMessageBytes - frameOverhead
    static let maximumBufferedBytes = 4 * 1_024 * 1_024
    static let maximumChannels = 16

    static func encode(_ kind: Kind, channelID: String, payload: Data = Data()) throws -> Data {
        guard validChannelID(channelID) else { throw CompanionRelayError.invalidResponse }
        let channel = Data(channelID.utf8)
        guard 3 + channel.count + payload.count <= maximumMessageBytes else {
            throw CompanionRelayError.invalidResponse
        }
        var result = Data(capacity: 3 + channel.count + payload.count)
        result.append(contentsOf: [version, kind.rawValue, UInt8(channel.count)])
        result.append(channel)
        result.append(payload)
        return result
    }

    static func decode(_ data: Data) throws -> Frame {
        guard data.count >= 4, data.count <= maximumMessageBytes,
              data[data.startIndex] == version,
              let kind = Kind(rawValue: data[data.startIndex + 1]) else {
            throw CompanionRelayError.invalidResponse
        }
        let channelLength = Int(data[data.startIndex + 2])
        guard channelLength > 0, 3 + channelLength <= data.count else {
            throw CompanionRelayError.invalidResponse
        }
        let channelRange = (data.startIndex + 3)..<(data.startIndex + 3 + channelLength)
        guard let channelID = String(data: data[channelRange], encoding: .utf8),
              validChannelID(channelID) else {
            throw CompanionRelayError.invalidResponse
        }
        return Frame(
            kind: kind,
            channelID: channelID,
            payload: Data(data[(data.startIndex + 3 + channelLength)...])
        )
    }

    static func validChannelID(_ value: String) -> Bool {
        value.utf8.count == channelIDBytes && value.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil
                || $0 == "_" || $0 == "-")
        }
    }
}

/// One opaque relay channel behaves like a bounded byte stream. Bytes arriving
/// between OPEN and host installation are retained only up to the relay's
/// global backpressure cap, preventing a fast peer from racing setup into an
/// unbounded queue.
actor CompanionRelayVirtualSocket {
    typealias Receiver = @Sendable (Data) async -> Void
    typealias CloseHandler = @Sendable () async -> Void
    typealias Writer = @Sendable (Data) async throws -> Void
    typealias Closer = @Sendable () async -> Void

    nonisolated let id: String
    private let writer: Writer
    private let closer: Closer
    private var receiver: Receiver?
    private var closeHandler: CloseHandler?
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var closed = false

    init(id: String, writer: @escaping Writer, closer: @escaping Closer) {
        self.id = id
        self.writer = writer
        self.closer = closer
    }

    func install(receiver: @escaping Receiver, onClose: @escaping CloseHandler) async {
        guard !closed else {
            await onClose()
            return
        }
        self.receiver = receiver
        closeHandler = onClose
        let buffered = pending
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        for data in buffered where !closed { await receiver(data) }
    }

    func receive(_ data: Data) async {
        guard !closed, !data.isEmpty,
              data.count <= CompanionRelayMux.maximumDevicePayloadBytes else {
            await abort()
            return
        }
        if let receiver {
            await receiver(data)
            return
        }
        guard pendingBytes + data.count <= CompanionRelayMux.maximumBufferedBytes else {
            await abort()
            return
        }
        pending.append(data)
        pendingBytes += data.count
    }

    func write(_ data: Data) async throws {
        guard !closed, !data.isEmpty,
              data.count <= CompanionRelayMux.maximumDevicePayloadBytes else {
            throw CompanionRelayError.disconnected
        }
        try await writer(data)
    }

    func localClose() async {
        guard !closed else { return }
        closed = true
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        await closer()
    }

    func remoteClose() async {
        guard !closed else { return }
        closed = true
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        if let closeHandler { await closeHandler() }
    }

    private func abort() async {
        guard !closed else { return }
        closed = true
        pending.removeAll(keepingCapacity: false)
        pendingBytes = 0
        let closeHandler = closeHandler
        await closer()
        if let closeHandler { await closeHandler() }
    }
}

/// The same protocol session used by accepted TCP sockets, backed by one
/// Cloudflare relay channel. The relay never sees or interprets the framed
/// handshake/application bytes carried here.
actor CompanionRelayConnection: CompanionHostConnection {
    static let authenticationTimeout = Duration.seconds(30)

    nonisolated let id: String
    private let socket: CompanionRelayVirtualSocket
    private let coordinator: CompanionPairingCoordinator
    private let epoch: String
    private let eventSink: CompanionConnectionSession.EventSink
    private let diagnosticSink: CompanionConnectionSession.DiagnosticSink
    private var session: CompanionConnectionSession?
    private var timeoutTask: Task<Void, Never>?
    private var started = false

    init(
        id: String = "relay-\(UUID().uuidString.lowercased())",
        socket: CompanionRelayVirtualSocket,
        coordinator: CompanionPairingCoordinator,
        epoch: String,
        eventSink: @escaping CompanionConnectionSession.EventSink,
        diagnosticSink: @escaping CompanionConnectionSession.DiagnosticSink = { _ in }
    ) {
        self.id = id
        self.socket = socket
        self.coordinator = coordinator
        self.epoch = epoch
        self.eventSink = eventSink
        self.diagnosticSink = diagnosticSink
    }

    deinit { timeoutTask?.cancel() }

    func start() async throws {
        guard !started else { return }
        started = true
        let session = try CompanionConnectionSession(
            socketID: id,
            coordinator: coordinator,
            epoch: epoch,
            transportHint: nil,
            writer: { [weak socket] data in
                guard let socket else { throw CompanionRelayError.disconnected }
                try await socket.write(data)
            },
            closer: { [weak socket] in await socket?.localClose() },
            eventSink: eventSink,
            diagnosticSink: diagnosticSink
        )
        self.session = session
        await socket.install(
            receiver: { [weak session] data in await session?.receive(data) },
            onClose: { [weak session] in await session?.close(reason: "relay_channel_closed") }
        )
        timeoutTask = Task { [weak session] in
            try? await Task.sleep(for: Self.authenticationTimeout)
            guard !Task.isCancelled else { return }
            await session?.authenticationTimedOut()
        }
    }

    func confirmPairing(pairingID: String) async -> Bool {
        await session?.confirmPairing(pairingID: pairingID) ?? false
    }

    func send(
        kind: CompanionEnvelopeKind,
        id: String,
        sequence: Int64,
        sentAt: Int64,
        body: CompanionBody
    ) async throws -> CompanionEnvelope? {
        guard let session else { throw CompanionRelayError.disconnected }
        return try await session.send(
            kind: kind,
            id: id,
            sequence: sequence,
            sentAt: sentAt,
            body: body
        )
    }

    func sendReceipt(
        _ receipt: CompanionReceiptBody,
        sequence: Int64? = nil,
        sentAt: Int64? = nil
    ) async throws {
        guard let session else { throw CompanionRelayError.disconnected }
        try await session.sendReceipt(receipt, sequence: sequence, sentAt: sentAt)
    }

    func updateCapabilities(
        _ capabilities: [CompanionCapability]
    ) async throws -> [CompanionCapability] {
        guard let session else { throw CompanionRelayError.disconnected }
        return try await session.updateCapabilities(capabilities)
    }

    func sendDeviceRevoked() async throws {
        guard let session else { throw CompanionRelayError.disconnected }
        try await session.sendDeviceRevoked()
    }

    func close(reason: String = "closed") async {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let session { await session.close(reason: reason) }
        else { await socket.localClose() }
    }
}

@MainActor
protocol CompanionLinkWebSocket: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: CompanionLinkWebSocket {}

@MainActor
final class CompanionLinkClient: ObservableObject {
    enum Phase: String, Equatable, Sendable {
        case off
        case unavailable
        case authenticationRequired
        case connecting
        case ready
        case reconnecting

        var title: String {
            switch self {
            case .off: "Off"
            case .unavailable: "Unavailable"
            case .authenticationRequired: "Sign in required"
            case .connecting: "Connecting…"
            case .ready: "Ready anywhere"
            case .reconnecting: "Reconnecting…"
            }
        }
    }

    typealias TokenProvider = @MainActor () async throws -> String
    typealias SocketFactory = @MainActor (URL) -> any CompanionLinkWebSocket
    typealias SocketAcceptor = @MainActor (CompanionRelayVirtualSocket) -> Void

    private struct TicketRequest: Encodable {
        let role = "desktop"
        let desktopId: String
    }

    private struct TicketResponse: Decodable {
        let ok: Bool
        let websocketUrl: String
        let expiresAt: Int64
    }

    private struct ControlMessage: Decodable { let type: String }
    private struct OpenDetails: Decodable { let deviceId: String }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var channelCount = 0
    @Published private(set) var lastConnectedAt: Int64?

    private let desktopID: String
    private let baseURL: URL
    private let tokenProvider: TokenProvider
    private let socketFactory: SocketFactory
    private let acceptSocket: SocketAcceptor
    private let session: URLSession
    private let now: () -> Int64
    private var desired = false
    private var generation = 0
    private var retryAttempt = 0
    private var webSocket: (any CompanionLinkWebSocket)?
    private var channels: [String: CompanionRelayVirtualSocket] = [:]
    private var connectionTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var readyDeadlineTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pendingSendBytes = 0

    init?(
        desktopID: String,
        baseURL: URL,
        tokenProvider: @escaping TokenProvider,
        session: URLSession = URLSession(configuration: .ephemeral),
        socketFactory: SocketFactory? = nil,
        acceptSocket: @escaping SocketAcceptor,
        now: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        guard (try? CompanionCrypto.validateIdentifier(desktopID, label: "desktopId")) != nil,
              let normalized = Self.validatedBaseURL(baseURL) else { return nil }
        self.desktopID = desktopID
        self.baseURL = normalized
        self.tokenProvider = tokenProvider
        self.session = session
        self.acceptSocket = acceptSocket
        self.now = now
        self.socketFactory = socketFactory ?? { url in
            session.webSocketTask(with: URLRequest(url: url, timeoutInterval: 15))
        }
    }

    func enable() {
        desired = true
        guard webSocket == nil, connectionTask == nil, retryTask == nil else { return }
        connect()
    }

    func disable() {
        desired = false
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        readyDeadlineTask?.cancel()
        readyDeadlineTask = nil
        retryTask?.cancel()
        retryTask = nil
        let socket = webSocket
        webSocket = nil
        socket?.cancel(with: .normalClosure, reason: Data("disabled".utf8))
        closeChannels()
        retryAttempt = 0
        setPhase(.off)
    }

    func refresh() {
        guard desired, phase != .ready, phase != .connecting else { return }
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        connect()
    }

    private func connect() {
        guard desired, webSocket == nil, connectionTask == nil else { return }
        generation &+= 1
        let expectedGeneration = generation
        setPhase(.connecting)
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == expectedGeneration { self.connectionTask = nil }
            }
            do {
                let token = try await tokenProvider()
                guard isCurrent(expectedGeneration),
                      (20...20_000).contains(token.utf8.count) else {
                    throw CompanionRelayError.authenticationRequired
                }
                let socketURL = try await requestTicket(token: token)
                guard isCurrent(expectedGeneration) else { return }
                let socket = socketFactory(socketURL)
                webSocket = socket
                socket.resume()
                startReadyDeadline(socket: socket, generation: expectedGeneration)
                receiveTask = Task { @MainActor [weak self, weak socket] in
                    guard let self, let socket else { return }
                    await self.receiveLoop(socket: socket, generation: expectedGeneration)
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(expectedGeneration) else { return }
                fail(error)
            }
        }
    }

    private func requestTicket(token: String) async throws -> URL {
        guard let endpoint = Self.ticketURL(baseURL: baseURL) else {
            throw CompanionRelayError.unavailable
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TicketRequest(desktopId: desktopID))
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CompanionRelayError.invalidResponse
        }
        if response.statusCode == 401 { throw CompanionRelayError.authenticationRequired }
        guard response.statusCode == 200, data.count <= 64 * 1_024,
              let decoded = try? JSONDecoder().decode(TicketResponse.self, from: data),
              decoded.ok, decoded.expiresAt > now(),
              let socketURL = Self.validatedWebSocketURL(decoded.websocketUrl, baseURL: baseURL) else {
            throw CompanionRelayError.invalidResponse
        }
        return socketURL
    }

    private func receiveLoop(
        socket: any CompanionLinkWebSocket,
        generation expectedGeneration: Int
    ) async {
        do {
            while isCurrent(expectedGeneration), socket === webSocket {
                let message = try await socket.receive()
                guard isCurrent(expectedGeneration), socket === webSocket else { return }
                switch message {
                case let .string(text): try receiveControl(text, socket: socket, generation: expectedGeneration)
                case let .data(data): try await receiveMux(data)
                @unknown default: throw CompanionRelayError.invalidResponse
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(expectedGeneration), socket === webSocket else { return }
            socket.cancel(with: .protocolError, reason: Data("invalid_relay_frame".utf8))
            webSocket = nil
            closeChannels()
            fail(error)
        }
    }

    private func receiveControl(
        _ text: String,
        socket: any CompanionLinkWebSocket,
        generation expectedGeneration: Int
    ) throws {
        guard text.utf8.count <= 1_024,
              let control = try? JSONDecoder().decode(ControlMessage.self, from: Data(text.utf8)) else {
            throw CompanionRelayError.invalidResponse
        }
        if control.type == "relay.pong" { return }
        guard control.type == "relay.desktop-ready" else {
            throw CompanionRelayError.invalidResponse
        }
        readyDeadlineTask?.cancel()
        readyDeadlineTask = nil
        retryAttempt = 0
        lastConnectedAt = now()
        setPhase(.ready)
        startHeartbeat(socket: socket, generation: expectedGeneration)
    }

    private func receiveMux(_ data: Data) async throws {
        let frame = try CompanionRelayMux.decode(data)
        switch frame.kind {
        case .open:
            guard frame.payload.count <= 1_024,
                  let details = try? JSONDecoder().decode(OpenDetails.self, from: frame.payload),
                  (try? CompanionCrypto.validateIdentifier(details.deviceId, label: "deviceId")) != nil else {
                throw CompanionRelayError.invalidResponse
            }
            guard channels[frame.channelID] != nil
                    || channels.count < CompanionRelayMux.maximumChannels else {
                throw CompanionRelayError.invalidResponse
            }
            if let previous = channels.removeValue(forKey: frame.channelID) {
                await previous.remoteClose()
            }
            let channel = CompanionRelayVirtualSocket(
                id: frame.channelID,
                writer: { [weak self] payload in
                    guard let self else { throw CompanionRelayError.disconnected }
                    try await self.sendChannel(frame.channelID, payload: payload)
                },
                closer: { [weak self] in
                    guard let self else { return }
                    await self.closeChannel(frame.channelID)
                }
            )
            channels[frame.channelID] = channel
            channelCount = channels.count
            acceptSocket(channel)
        case .data:
            guard !frame.payload.isEmpty,
                  frame.payload.count <= CompanionRelayMux.maximumDevicePayloadBytes else {
                throw CompanionRelayError.invalidResponse
            }
            guard let channel = channels[frame.channelID] else { return }
            // URLSession delivers WebSocket messages in order. Await the
            // per-channel actor here so adjacent protocol frames (notably
            // resume key-confirmation followed by device hello) cannot be
            // reordered by independent unstructured tasks.
            await channel.receive(frame.payload)
        case .close:
            guard frame.payload.isEmpty else { throw CompanionRelayError.invalidResponse }
            guard let channel = channels.removeValue(forKey: frame.channelID) else { return }
            channelCount = channels.count
            await channel.remoteClose()
        }
    }

    private func sendChannel(_ channelID: String, payload: Data) async throws {
        guard phase == .ready, let socket = webSocket,
              !payload.isEmpty, payload.count <= CompanionRelayMux.maximumDevicePayloadBytes,
              channels[channelID] != nil else { throw CompanionRelayError.disconnected }
        let frame = try CompanionRelayMux.encode(.data, channelID: channelID, payload: payload)
        guard pendingSendBytes + frame.count <= CompanionRelayMux.maximumBufferedBytes else {
            throw CompanionRelayError.slowConsumer
        }
        pendingSendBytes += frame.count
        defer { pendingSendBytes -= frame.count }
        try await socket.send(.data(frame))
    }

    private func closeChannel(_ channelID: String) async {
        guard channels.removeValue(forKey: channelID) != nil else { return }
        channelCount = channels.count
        guard phase == .ready, let socket = webSocket,
              let frame = try? CompanionRelayMux.encode(.close, channelID: channelID) else { return }
        try? await socket.send(.data(frame))
    }

    private func closeChannels() {
        let active = Array(channels.values)
        channels.removeAll()
        channelCount = 0
        for channel in active { Task { await channel.remoteClose() } }
    }

    private func fail(_ error: Error) {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        readyDeadlineTask?.cancel()
        readyDeadlineTask = nil
        let socket = webSocket
        webSocket = nil
        socket?.cancel(with: .goingAway, reason: nil)
        closeChannels()
        let relayError = error as? CompanionRelayError
        if relayError == .authenticationRequired { setPhase(.authenticationRequired) }
        else { setPhase(.unavailable) }
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard desired, retryTask == nil else { return }
        if phase != .authenticationRequired { setPhase(.reconnecting) }
        let exponent = min(retryAttempt, 5)
        let delay = min(30, 1 << exponent)
        retryAttempt += 1
        let expectedGeneration = generation
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.desired,
                  self.generation == expectedGeneration else { return }
            self.retryTask = nil
            self.connect()
        }
    }

    private func startHeartbeat(
        socket: any CompanionLinkWebSocket,
        generation expectedGeneration: Int
    ) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self, weak socket] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, let socket,
                      self.isCurrent(expectedGeneration), socket === self.webSocket,
                      self.pendingSendBytes <= CompanionRelayMux.maximumBufferedBytes else { return }
                do { try await socket.send(.string(#"{"type":"relay.ping"}"#)) }
                catch { self.fail(error); return }
            }
        }
    }

    private func startReadyDeadline(
        socket: any CompanionLinkWebSocket,
        generation expectedGeneration: Int
    ) {
        readyDeadlineTask?.cancel()
        readyDeadlineTask = Task { @MainActor [weak self, weak socket] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let socket,
                  self.isCurrent(expectedGeneration), socket === self.webSocket,
                  self.phase != .ready else { return }
            self.fail(CompanionRelayError.unavailable)
        }
    }

    private func isCurrent(_ expectedGeneration: Int) -> Bool {
        desired && generation == expectedGeneration
    }

    private func setPhase(_ value: Phase) {
        if phase != value { phase = value }
    }

    static func validatedBaseURL(_ value: URL) -> URL? {
        guard value.scheme?.lowercased() == "https", value.host?.isEmpty == false,
              value.user == nil, value.password == nil else { return nil }
        var components = URLComponents(url: value, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        if var path = components?.path {
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            components?.path = path
        }
        return components?.url
    }

    static func ticketURL(baseURL: URL) -> URL? {
        guard let base = validatedBaseURL(baseURL) else { return nil }
        return base
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("ticket", isDirectory: false)
    }

    static func validatedWebSocketURL(_ value: String, baseURL: URL) -> URL? {
        guard let base = validatedBaseURL(baseURL), let url = URL(string: value),
              url.scheme?.lowercased() == "wss",
              url.host?.lowercased() == base.host?.lowercased(),
              url.port == base.port,
              url.user == nil, url.password == nil,
              url.path.hasPrefix("/v1/connect/") else { return nil }
        return url
    }
}
