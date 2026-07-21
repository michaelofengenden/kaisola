import Foundation

enum KaisolaLinkError: LocalizedError, Equatable {
    case unavailable
    case authenticationRequired
    case invalidResponse
    case disconnected

    var errorDescription: String? {
        switch self {
        case .unavailable: "Kaisola Link is temporarily unavailable."
        case .authenticationRequired: "Sign in again to reconnect through Kaisola Link."
        case .invalidResponse: "Kaisola Link returned an invalid connection response."
        case .disconnected: "Kaisola Link disconnected."
        }
    }
}

@MainActor
final class KaisolaLinkConnection {
    enum Event {
        case waiting
        case ready
        case data(Data)
        case failed(Error)
        case closed
    }

    typealias TokenProvider = @MainActor () async throws -> String

    private struct TicketRequest: Encodable {
        let role = "device"
        let desktopId: String
        let deviceId: String
    }

    private struct TicketResponse: Decodable {
        let ok: Bool
        let websocketUrl: String
        let expiresAt: Int64
    }

    private struct ControlMessage: Decodable {
        let type: String
    }

    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private var connectionTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var sendTail: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var controlDeadlineTask: Task<Void, Never>?
    private var generation = 0
    private(set) var isActive = false
    private(set) var isReady = false
    var onEvent: ((Event) -> Void)?

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func connect(
        baseURL: URL,
        desktopId: String,
        deviceId: String,
        tokenProvider: @escaping TokenProvider
    ) {
        cancel(notify: false)
        generation &+= 1
        let expectedGeneration = generation
        isActive = true
        isReady = false
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let token = try await tokenProvider()
                guard self.isCurrent(expectedGeneration),
                      token.utf8.count >= 20,
                      token.utf8.count <= 20_000 else {
                    throw KaisolaLinkError.authenticationRequired
                }
                let socketURL = try await self.requestTicket(
                    baseURL: baseURL,
                    token: token,
                    desktopId: desktopId,
                    deviceId: deviceId
                )
                guard self.isCurrent(expectedGeneration) else { return }
                let request = URLRequest(url: socketURL, timeoutInterval: 15)
                let task = self.session.webSocketTask(with: request)
                self.webSocket = task
                task.resume()
                self.startControlDeadline(task: task, generation: expectedGeneration)
                self.startHeartbeat(task: task, generation: expectedGeneration)
                self.receiveTask = Task { @MainActor [weak self, weak task] in
                    guard let self, let task else { return }
                    await self.receiveLoop(task: task, generation: expectedGeneration)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrent(expectedGeneration) else { return }
                self.isActive = false
                self.onEvent?(.failed(error))
            }
        }
    }

    func send(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 2 * 1_024 * 1_024 - 64,
              let webSocket, isActive else { throw KaisolaLinkError.disconnected }
        let expectedGeneration = generation
        let prior = sendTail
        let operation = Task { @MainActor [weak self, weak webSocket] in
            if let prior { await prior.value }
            guard let self, let webSocket, self.isCurrent(expectedGeneration),
                  webSocket === self.webSocket else { return }
            do {
                try await webSocket.send(.data(data))
            } catch {
                guard self.isCurrent(expectedGeneration) else { return }
                self.isActive = false
                self.onEvent?(.failed(error))
            }
        }
        sendTail = operation
    }

    func cancel(notify: Bool = true) {
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        sendTail?.cancel()
        sendTail = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        controlDeadlineTask?.cancel()
        controlDeadlineTask = nil
        let socket = webSocket
        webSocket = nil
        socket?.cancel(with: .goingAway, reason: nil)
        let wasActive = isActive
        isActive = false
        isReady = false
        if notify, wasActive { onEvent?(.closed) }
    }

    private func requestTicket(
        baseURL: URL,
        token: String,
        desktopId: String,
        deviceId: String
    ) async throws -> URL {
        guard let endpoint = Self.ticketURL(baseURL: baseURL) else { throw KaisolaLinkError.unavailable }
        var request = URLRequest(url: endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TicketRequest(desktopId: desktopId, deviceId: deviceId))
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw KaisolaLinkError.invalidResponse }
        if response.statusCode == 401 { throw KaisolaLinkError.authenticationRequired }
        guard response.statusCode == 200, data.count <= 64 * 1_024,
              let decoded = try? JSONDecoder().decode(TicketResponse.self, from: data),
              decoded.ok,
              decoded.expiresAt > Int64(Date.now.timeIntervalSince1970 * 1_000),
              let socketURL = Self.validatedWebSocketURL(decoded.websocketUrl, baseURL: baseURL) else {
            throw KaisolaLinkError.invalidResponse
        }
        return socketURL
    }

    private func receiveLoop(task: URLSessionWebSocketTask, generation expectedGeneration: Int) async {
        do {
            while isCurrent(expectedGeneration), task === webSocket {
                let message = try await task.receive()
                guard isCurrent(expectedGeneration), task === webSocket else { return }
                switch message {
                case let .data(data):
                    guard !data.isEmpty, data.count <= 2 * 1_024 * 1_024 - 64 else {
                        throw KaisolaLinkError.invalidResponse
                    }
                    onEvent?(.data(data))
                case let .string(text):
                    guard text.utf8.count <= 1_024,
                          let control = try? JSONDecoder().decode(ControlMessage.self, from: Data(text.utf8)) else {
                        throw KaisolaLinkError.invalidResponse
                    }
                    if control.type == "relay.ready" {
                        isReady = true
                        controlDeadlineTask?.cancel()
                        controlDeadlineTask = nil
                        onEvent?(.ready)
                    } else if control.type == "relay.waiting" {
                        isReady = false
                        controlDeadlineTask?.cancel()
                        controlDeadlineTask = nil
                        onEvent?(.waiting)
                    }
                    else if control.type == "relay.pong" { continue }
                    else { throw KaisolaLinkError.invalidResponse }
                @unknown default:
                    throw KaisolaLinkError.invalidResponse
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(expectedGeneration) else { return }
            isActive = false
            isReady = false
            heartbeatTask?.cancel()
            heartbeatTask = nil
            onEvent?(.failed(error))
        }
    }

    private func startHeartbeat(task: URLSessionWebSocketTask, generation expectedGeneration: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self, weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, let task,
                      self.isCurrent(expectedGeneration), task === self.webSocket else { return }
                do {
                    try await task.send(.string(#"{"type":"relay.ping"}"#))
                } catch {
                    guard self.isCurrent(expectedGeneration) else { return }
                    self.isActive = false
                    self.isReady = false
                    self.onEvent?(.failed(error))
                    return
                }
            }
        }
    }

    private func startControlDeadline(task: URLSessionWebSocketTask, generation expectedGeneration: Int) {
        controlDeadlineTask?.cancel()
        controlDeadlineTask = Task { @MainActor [weak self, weak task] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, let task,
                  self.isCurrent(expectedGeneration), task === self.webSocket,
                  !self.isReady else { return }
            self.isActive = false
            self.onEvent?(.failed(KaisolaLinkError.unavailable))
        }
    }

    private func isCurrent(_ expectedGeneration: Int) -> Bool {
        isActive && generation == expectedGeneration
    }

    static func ticketURL(baseURL: URL) -> URL? {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host?.isEmpty == false,
              baseURL.user == nil,
              baseURL.password == nil else { return nil }
        return baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("ticket", isDirectory: false)
    }

    static func validatedWebSocketURL(_ value: String, baseURL: URL) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "wss",
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.port == baseURL.port,
              url.user == nil,
              url.password == nil,
              url.path.hasPrefix("/v1/connect/") else { return nil }
        return url
    }
}
