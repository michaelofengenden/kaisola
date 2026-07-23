import Foundation
import KaisolaBrokerProtocol
import KaisolaCore

/// The exact mutation surface the native app is allowed to use, and nothing
/// else. This enum is deliberately separate from `ObserveOnlyBrokerMethod`:
/// the observer client keeps its cannot-represent-mutation guarantee, while
/// every native write travels through this sealed set on its own controller
/// connection and is gated by the app's ownership registry before it reaches
/// the wire.
enum ControlBrokerMethod: String, CaseIterable, Sendable {
    case create = "terminal.create"
    case attach = "terminal.attach"
    case write = "terminal.write"
    case resize = "terminal.resize"
    case kill = "terminal.kill"
    case detachOwner = "terminal.detachOwner"
    case agentTurn = "terminal.agentTurn"
}

struct TerminalCreation: Equatable, Sendable {
    let terminalID: String
    let projectID: String
    let pid: Int32
    let streamEpoch: String?
}

protocol BrokerControlServing: Sendable {
    func connect(to info: BrokerInfo, ownerID: String) async throws
    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int
    ) async throws -> TerminalCreation
    func attach(projectID: String, terminalID: String) async throws
    func write(projectID: String, terminalID: String, data: String) async throws
    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws
    func kill(projectID: String, terminalID: String) async throws
    func detachOwner(projectID: String, terminalID: String) async throws
    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws
    func disconnect() async
}

/// A second, write-capable connection to the same broker the observer client
/// streams from. Reads never travel here; writes never travel there. The
/// broker's own ownership model (attach-before-write, stale-write rejection)
/// stays the final authority on every mutation.
actor BrokerControlClient: BrokerControlServing {
    private let transport: any BrokerByteTransport
    private let operationTimeoutNanoseconds: UInt64
    private var decoder = BrokerLineFrameDecoder()
    private var connected = false
    private var ownerID = ""
    private var helloWaiter: CheckedContinuation<Void, any Error>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var readerTask: Task<Void, Never>?

    init(
        transport: any BrokerByteTransport = UnixBrokerTransport(),
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        precondition(operationTimeoutNanoseconds > 0)
        self.transport = transport
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
    }

    func connect(to info: BrokerInfo, ownerID: String) async throws {
        if connected { return }
        try info.validate()
        guard !ownerID.isEmpty else { throw BrokerClientError.requestFailed("controller owner id") }
        self.ownerID = ownerID
        try await transport.connect(path: info.socketPath)
        readerTask = Task { await readLoop() }

        let frame: JSONValue = .object([
            "type": .string("hello"),
            "protocol": .integer(Int64(BrokerWire.protocolVersion)),
            "token": .string(info.token),
            // The broker validates instanceId as a UUID shape; the durable
            // owner identity travels in request params instead, and reattach
            // is authorized by project capability rather than instance.
            "instanceId": .string(UUID().uuidString.lowercased()),
            "appVersion": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "native-preview"),
            "access": .string("controller"),
        ])
        let encoded = try encode(frame)
        return try await withCheckedThrowingContinuation { continuation in
            helloWaiter = continuation
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: operationTimeoutNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await abortConnection(with: BrokerClientError.connectionTimedOut)
            }
            Task {
                do { try await transport.send(encoded) }
                catch { await abortConnection(with: error) }
            }
        }
    }

    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int
    ) async throws -> TerminalCreation {
        let result = try await request(.create, params: .object([
            "ownerId": .string(ownerID),
            "projectId": .string(projectID),
            "id": .string(terminalID),
            "command": .string(command),
            "args": .array(arguments.map(JSONValue.string)),
            "cwd": .string(cwd),
            // Native shells should open at the prompt, without zsh's inverse
            // partial-line marker during the initial PTY resize. This is a
            // fixed, non-secret environment value; account secrets still use
            // the short-lived 0600 file in AppModel and never enter argv/wire.
            "env": .object(["PROMPT_EOL_MARK": .string("")]),
            "cols": .integer(Int64(columns)),
            "rows": .integer(Int64(rows)),
        ]))
        guard let object = result.objectValue,
              object["ok"]?.boolValue != false,
              let pid = object["pid"]?.intValue.flatMap(Int32.init(exactly:)) else {
            throw BrokerClientError.requestFailed("terminal.create")
        }
        return TerminalCreation(
            terminalID: terminalID,
            projectID: projectID,
            pid: pid,
            streamEpoch: object["streamEpoch"]?.stringValue
        )
    }

    func attach(projectID: String, terminalID: String) async throws {
        _ = try await request(.attach, params: identity(projectID: projectID, terminalID: terminalID))
    }

    func write(projectID: String, terminalID: String, data: String) async throws {
        guard var params = identity(projectID: projectID, terminalID: terminalID).objectValue else {
            throw BrokerClientError.malformedResponse
        }
        params["data"] = .string(data)
        _ = try await request(.write, params: .object(params))
    }

    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws {
        guard var params = identity(projectID: projectID, terminalID: terminalID).objectValue else {
            throw BrokerClientError.malformedResponse
        }
        params["cols"] = .integer(Int64(columns))
        params["rows"] = .integer(Int64(rows))
        _ = try await request(.resize, params: .object(params))
    }

    func kill(projectID: String, terminalID: String) async throws {
        _ = try await request(.kill, params: identity(projectID: projectID, terminalID: terminalID))
    }

    func detachOwner(projectID: String, terminalID: String) async throws {
        _ = try await request(.detachOwner, params: identity(projectID: projectID, terminalID: terminalID))
    }

    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws {
        guard var params = identity(projectID: projectID, terminalID: terminalID).objectValue else {
            throw BrokerClientError.malformedResponse
        }
        params["busy"] = .bool(busy)
        _ = try await request(.agentTurn, params: .object(params))
    }

    func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        for task in requestTimeoutTasks.values { task.cancel() }
        requestTimeoutTasks.removeAll()
        await transport.close()
        failConnection(with: BrokerClientError.connectionClosed)
        decoder = BrokerLineFrameDecoder()
        connected = false
    }

    private func identity(projectID: String, terminalID: String) -> JSONValue {
        .object([
            "ownerId": .string(ownerID),
            "projectId": .string(projectID),
            "id": .string(terminalID),
        ])
    }

    private func request(_ method: ControlBrokerMethod, params: JSONValue) async throws -> JSONValue {
        guard connected else { throw BrokerClientError.notConnected }
        let requestID = UUID().uuidString.lowercased()
        let frame: JSONValue = .object([
            "type": .string("request"),
            "id": .string(requestID),
            "method": .string(method.rawValue),
            "params": params,
        ])
        let encoded = try encode(frame)
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            requestTimeoutTasks[requestID] = Task {
                do {
                    try await Task.sleep(nanoseconds: operationTimeoutNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                failRequest(requestID, with: BrokerClientError.requestTimedOut)
            }
            Task {
                do { try await transport.send(encoded) }
                catch { failRequest(requestID, with: error) }
            }
        }
    }

    private func readLoop() async {
        do {
            while !Task.isCancelled {
                guard let data = try await transport.receive(maximumBytes: 64 * 1_024) else {
                    throw BrokerClientError.connectionClosed
                }
                if data.isEmpty { continue }
                var activeDecoder = decoder
                try activeDecoder.consume(data) { data in
                    let frame = try JSONDecoder().decode(JSONValue.self, from: data)
                    try handle(frame)
                }
                decoder = activeDecoder
            }
        } catch {
            if !Task.isCancelled { await abortConnection(with: error) }
        }
    }

    private func abortConnection(with error: any Error) async {
        await transport.close()
        readerTask = nil
        decoder = BrokerLineFrameDecoder()
        failConnection(with: error)
    }

    private func handle(_ frame: JSONValue) throws {
        guard let object = frame.objectValue, let type = object["type"]?.stringValue else {
            throw BrokerClientError.malformedResponse
        }
        switch type {
        case "hello":
            guard object["ok"]?.boolValue == true else { throw BrokerClientError.authenticationRejected }
            guard object["protocol"]?.intValue == Int64(BrokerWire.protocolVersion) else {
                throw BrokerClientError.protocolMismatch
            }
            guard object["securityEpoch"]?.intValue == Int64(BrokerWire.securityEpoch) else {
                throw BrokerClientError.securityEpochMismatch
            }
            // Control requires a broker modern enough to advertise observation:
            // the same generation that enforces roles server-side. Older live
            // brokers stay strictly observed-or-offline.
            let features = Set(object["features"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            guard features.contains(BrokerWire.terminalObserveFeature) else {
                throw BrokerClientError.observeFeatureMissing
            }
            connected = true
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            helloWaiter?.resume(returning: ())
            helloWaiter = nil
        case "response":
            guard let id = object["id"]?.stringValue, let continuation = pending.removeValue(forKey: id) else {
                return
            }
            requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            if object["ok"]?.boolValue == true, let result = object["result"] {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: BrokerClientError.requestFailed(object["message"]?.stringValue ?? "request"))
            }
        case "event":
            // The controller connection carries no streams; events belong to
            // the observer connection.
            break
        default:
            break
        }
    }

    private func encode(_ frame: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        guard data.count <= BrokerWire.maximumFrameBytes else { throw BrokerClientError.frameRejected }
        data.append(0x0A)
        return data
    }

    private func failRequest(_ id: String, with error: any Error) {
        requestTimeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failConnection(with error: any Error) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        helloWaiter?.resume(throwing: error)
        helloWaiter = nil
        for task in requestTimeoutTasks.values { task.cancel() }
        requestTimeoutTasks.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        connected = false
    }
}
