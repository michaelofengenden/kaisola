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
    case release = "terminal.release"
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
    func release(projectID: String, terminalID: String) async throws
    func detachOwner(projectID: String, terminalID: String) async throws
    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws
    func disconnect() async
}

/// A second, write-capable connection to the same broker the observer client
/// streams from. Reads never travel here; writes never travel there. The
/// broker's own ownership model (attach-before-write, stale-write rejection)
/// stays the final authority on every mutation.
actor BrokerControlClient: BrokerControlServing, BrokerUpgradeRequesting {
    /// Compatibility values for a durable pre-fix broker. Older brokers merge
    /// their own launcher environment after receiving terminal.create; an
    /// outer Codex process can therefore leak NO_COLOR=1 into every nested CLI.
    /// Empty NO_COLOR plus FORCE_COLOR restores TTY styling on that broker.
    /// Current brokers remove both keys and let the PTY decide naturally.
    nonisolated static let cleanTerminalEnvironment: [String: JSONValue] = [
        "PROMPT_EOL_MARK": .string(""),
        "NO_COLOR": .string(""),
        "FORCE_COLOR": .string("1"),
        "CODEX_CI": .string(""),
        "CODEX_MANAGED_BY_NPM": .string(""),
        "CODEX_MANAGED_PACKAGE_ROOT": .string(""),
        "CODEX_THREAD_ID": .string(""),
    ]

    private let transport: any BrokerByteTransport
    private let operationTimeoutNanoseconds: UInt64
    nonisolated let connectionInstanceID: String
    private var decoder = BrokerLineFrameDecoder()
    private var connected = false
    private var connectedFeatures: Set<String> = []
    private var ownerID = ""
    private var helloWaiter: CheckedContinuation<Void, any Error>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var readerTask: Task<Void, Never>?

    init(
        transport: any BrokerByteTransport = UnixBrokerTransport(),
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000,
        connectionInstanceID: String = UUID().uuidString.lowercased()
    ) {
        precondition(operationTimeoutNanoseconds > 0)
        precondition(UUID(uuidString: connectionInstanceID) != nil)
        self.transport = transport
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
        self.connectionInstanceID = connectionInstanceID.lowercased()
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
            "instanceId": .string(connectionInstanceID),
            "appVersion": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "kaisola-native"),
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
            // Fixed, non-secret compatibility values only; account secrets
            // still use AppModel's short-lived 0600 file and never enter the
            // terminal wire request.
            "env": .object(Self.cleanTerminalEnvironment),
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

    /// Permanently ends an owned terminal and removes its retained broker
    /// record/spool. `kill` alone intentionally leaves a finished diagnostic;
    /// the user-facing End Session action must use this stronger operation.
    func release(projectID: String, terminalID: String) async throws {
        _ = try await request(.release, params: identity(projectID: projectID, terminalID: terminalID))
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

    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerUpgradeDecision {
        guard let runningDigest = info.contentDigest,
              BrokerHelperPackageVerification.isLowercaseSHA256(runningDigest),
              BrokerHelperPackageVerification.isLowercaseSHA256(targetContentDigest) else {
            throw BrokerClientError.requestFailed("broker helper identity")
        }
        do {
            try await connect(to: info, ownerID: "0")
            guard connectedFeatures.contains(BrokerWire.brokerUpdateFeature) else {
                throw BrokerClientError.requestFailed("broker sealed update capability")
            }
            let status = try await request(
                "broker.status",
                params: .object(["ownerId": .string("0")])
            )
            try Self.validateUpgradeStatus(status, expected: info)
            let result = try await request(
                "broker.shutdownForUpdate",
                params: .object([
                    "ownerId": .string("0"),
                    "expectedPid": .integer(Int64(info.pid)),
                    "expectedStartedAt": .integer(info.startedAt),
                    "expectedContentDigest": .string(runningDigest),
                    "targetContentDigest": .string(targetContentDigest),
                ])
            )
            let decision = try Self.upgradeDecision(result)
            await disconnect()
            return decision
        } catch {
            await disconnect()
            throw error
        }
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
        connectedFeatures = []
    }

    private func identity(projectID: String, terminalID: String) -> JSONValue {
        .object([
            "ownerId": .string(ownerID),
            "projectId": .string(projectID),
            "id": .string(terminalID),
        ])
    }

    private func request(_ method: ControlBrokerMethod, params: JSONValue) async throws -> JSONValue {
        try await request(method.rawValue, params: params)
    }

    private func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        guard connected else { throw BrokerClientError.notConnected }
        let requestID = UUID().uuidString.lowercased()
        let frame: JSONValue = .object([
            "type": .string("request"),
            "id": .string(requestID),
            "method": .string(method),
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

    nonisolated static func upgradeDecision(_ value: JSONValue) throws -> BrokerUpgradeDecision {
        guard let object = value.objectValue,
              let state = object["state"]?.stringValue else {
            throw BrokerClientError.malformedResponse
        }
        switch state {
        case "current":
            guard object["ok"]?.boolValue == true else { throw BrokerClientError.malformedResponse }
            return .current
        case "updating":
            guard object["ok"]?.boolValue == true else { throw BrokerClientError.malformedResponse }
            return .accepted
        case "identity_changed":
            guard object["ok"]?.boolValue == false else { throw BrokerClientError.malformedResponse }
            return .identityChanged
        case "pending":
            guard object["ok"]?.boolValue == false,
                  let liveCount = object["liveTerminalCount"]?.intValue.flatMap(Int.init(exactly:)),
                  let busyCount = object["busyAgentCount"]?.intValue.flatMap(Int.init(exactly:)),
                  let childCount = object["childTaskCount"]?.intValue.flatMap(Int.init(exactly:)),
                  liveCount >= 0, busyCount >= 0, childCount >= 0 else {
                throw BrokerClientError.malformedResponse
            }
            let liveIDs = object["liveTerminalIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let busyIDs = object["busyTerminalIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard liveIDs.count == liveCount,
                  busyIDs.count == busyCount,
                  Set(liveIDs).count == liveIDs.count,
                  Set(busyIDs).count == busyIDs.count else {
                throw BrokerClientError.malformedResponse
            }
            return .deferred(BrokerUpgradeBlockers(
                liveTerminalCount: liveCount,
                liveTerminalIDs: liveIDs,
                busyAgentCount: busyCount,
                busyTerminalIDs: busyIDs,
                childTaskCount: childCount
            ))
        default:
            throw BrokerClientError.malformedResponse
        }
    }

    nonisolated static func validateUpgradeStatus(
        _ value: JSONValue,
        expected info: BrokerInfo
    ) throws {
        guard let object = value.objectValue,
              object["ok"]?.boolValue == true,
              object["pid"]?.intValue == Int64(info.pid),
              object["startedAt"]?.intValue == info.startedAt,
              object["contentDigest"]?.stringValue == info.contentDigest,
              object["implementationVersion"]?.intValue == info.implementationVersion.map(Int64.init),
              object["packageSchema"]?.intValue == info.packageSchema.map(Int64.init),
              object["packageVersion"]?.stringValue == info.packageVersion,
              Set(object["features"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                .contains(BrokerWire.brokerUpdateFeature) else {
            throw BrokerClientError.identityChanged
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
            connectedFeatures = features
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
        connectedFeatures = []
    }
}
