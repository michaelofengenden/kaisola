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
    case controlLease = "terminal.controlLease"
}

enum TerminalWriteError: Error, Equatable, LocalizedError {
    case ended
    case missing

    var errorDescription: String? {
        switch self {
        case .ended: "This terminal has ended and cannot accept input."
        case .missing: "This terminal is no longer available."
        }
    }
}

struct TerminalCreation: Equatable, Sendable {
    let terminalID: String
    let projectID: String
    /// Nil for a cold record: a restore of a terminal that ended before the
    /// broker restart serves history without spawning a shell (§2h-1b).
    let pid: Int32?
    /// True when the create resolved to an ended terminal (cold record).
    var exited: Bool = false
    let streamEpoch: String?
    /// Cold scrollback captured from a retained spool when the spawn carried
    /// `restore: true`. Informational: when the broker keeps the spool as one
    /// continuous transcript, history replay already covers it and this may
    /// be nil or empty.
    var recovered: TerminalRecoveredScrollback?
}

struct TerminalRecoveredScrollback: Equatable, Sendable {
    let text: String
    let truncated: Bool
}

/// A terminal release is complete both when a broker acknowledges the
/// idempotent request and when validated generation routing proves there is no
/// broker left that could still own it. Transport/identity errors throw and
/// remain retryable instead of being confused with either safe outcome.
enum BrokerTerminalReleaseDisposition: Equatable, Sendable {
    case released
    case terminalAbsent
    case generationAbsent
}

protocol BrokerControlServing: Sendable {
    var connectionInstanceID: String { get }
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async
    func connect(to info: BrokerInfo, ownerID: String) async throws
    func connect(to topology: BrokerGenerationTopology, ownerID: String) async throws
    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int,
        restore: Bool
    ) async throws -> TerminalCreation
    func attach(projectID: String, terminalID: String) async throws
    func write(projectID: String, terminalID: String, data: String) async throws
    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws
    func kill(projectID: String, terminalID: String) async throws
    func release(projectID: String, terminalID: String) async throws
    func release(
        projectID: String,
        terminalID: String,
        brokerGenerationID: String?
    ) async throws -> BrokerTerminalReleaseDisposition
    func detachOwner(projectID: String, terminalID: String) async throws
    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws
    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws
    func detachGenerations(_ generationIDs: Set<String>) async
    func disconnect() async
}

extension BrokerControlServing {
    var connectionInstanceID: String { "" }

    /// Source compatibility for callers and doubles that predate resurrection.
    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int
    ) async throws -> TerminalCreation {
        try await createTerminal(
            projectID: projectID,
            terminalID: terminalID,
            command: command,
            arguments: arguments,
            cwd: cwd,
            columns: columns,
            rows: rows,
            restore: false
        )
    }

    func connect(
        to topology: BrokerGenerationTopology,
        ownerID: String
    ) async throws {
        try await connect(to: topology.current.info, ownerID: ownerID)
    }
    /// Keeps focused test doubles and additive alternative implementations
    /// source-compatible. The production controller below reports a lane-only
    /// disconnect so AppModel can stop accepting writes and reattach ownership.
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {}
    func detachGenerations(_ generationIDs: Set<String>) async {}

    /// Single-generation clients and focused doubles need no routing metadata:
    /// their ordinary idempotent release is an acknowledgement.
    func release(
        projectID: String,
        terminalID: String,
        brokerGenerationID: String?
    ) async throws -> BrokerTerminalReleaseDisposition {
        try await release(projectID: projectID, terminalID: terminalID)
        return .released
    }
}

/// A second, write-capable connection to the same broker the observer client
/// streams from. Reads never travel here; writes never travel there. The
/// broker's own ownership model (attach-before-write, stale-write rejection)
/// stays the final authority on every mutation.
actor BrokerControlClient: BrokerControlServing, BrokerRollingUpdateRequesting {
    typealias DisconnectHandler = @Sendable (any Error) -> Void
    private enum ConnectionAccess: String, Equatable {
        case controller
        case administrator
    }

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, any Error>
    }
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

    /// The broker plus owner a controller connection speaks for. Reuse is only
    /// safe for this exact identity. Concurrent callers naming the same broker
    /// and owner share one handshake; any other identity is refused.
    private struct ConnectionIdentity: Equatable {
        let info: BrokerInfo
        let ownerID: String
        let access: ConnectionAccess
    }

    private let transport: any BrokerByteTransport
    private let operationTimeoutNanoseconds: UInt64
    nonisolated let connectionInstanceID: String
    private var decoder = BrokerLineFrameDecoder()
    private var connected = false
    private var connectedFeatures: Set<String> = []
    private var connectedIdentity: ConnectionIdentity?
    private var connectInFlight: ConnectionIdentity?
    private var ownerID: String { connectedIdentity?.ownerID ?? "" }
    /// Every caller waiting on the single in-flight handshake, in arrival
    /// order. A list rather than one slot: the old single continuation was
    /// overwritten by a second concurrent connect, and the first caller then
    /// waited forever on a continuation nobody could resume.
    private var helloWaiters: [CheckedContinuation<Void, any Error>] = []
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var pending: [String: PendingRequest] = [:]
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var readerTask: Task<Void, Never>?
    private var disconnectHandler: DisconnectHandler?
    private var connectionAbortInProgress = false

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

    func setDisconnectHandler(_ handler: DisconnectHandler?) async {
        disconnectHandler = handler
    }

    /// Test seam: how many callers are parked on the in-flight handshake right
    /// now. Lets a concurrency test wait for a second connect to coalesce
    /// instead of guessing at a sleep.
    var connectWaiterCount: Int { helloWaiters.count }

    func connect(to info: BrokerInfo, ownerID: String) async throws {
        try await connect(to: info, ownerID: ownerID, access: .controller)
    }

    /// Administrative control is a distinct authenticated lane. Keeping this
    /// internal lets the upgrade coordinator request it without exposing it
    /// through the ordinary terminal-control protocol.
    func connectForAdministration(to info: BrokerInfo) async throws {
        try await connect(to: info, ownerID: "0", access: .administrator)
    }

    private func connect(
        to info: BrokerInfo,
        ownerID: String,
        access: ConnectionAccess
    ) async throws {
        try info.validate()
        let ownerIDIsValid = access == .administrator
            ? ownerID == "0"
            : !ownerID.isEmpty && ownerID != "0"
        guard ownerIDIsValid else {
            throw BrokerClientError.requestFailed("controller owner id")
        }
        let requested = ConnectionIdentity(info: info, ownerID: ownerID, access: access)
        if let connectedIdentity {
            // Reusing this lane for a different broker or owner would hand the
            // caller a success it cannot act on: later mutations would still
            // travel to the connection recorded here.
            guard connectedIdentity == requested else { throw BrokerClientError.identityChanged }
            if connected { return }
        }
        if let connectInFlight {
            // Opening the socket and awaiting hello both suspend, so a second
            // caller can arrive mid-handshake. Same broker: wait on the one
            // already running. Different broker: refuse, because succeeding
            // here would hand the caller a connection to somebody else's.
            guard connectInFlight == requested else { throw BrokerClientError.identityChanged }
            return try await withCheckedThrowingContinuation { continuation in
                helloWaiters.append(continuation)
            }
        }
        connectedIdentity = requested
        connectInFlight = requested

        let encoded: Data
        do {
            try await transport.connect(path: info.socketPath)
            // The controller reads output on the observer connection and throws
            // this connection's copy away, so ask the broker not to build it.
            // An older broker ignores the unknown feature and keeps sending the
            // channel we already discard, which is exactly today's behaviour.
            var requestedFeatures: [JSONValue] = [
                .string(BrokerWire.terminalObserverOnlyOutputFeature),
                .string(BrokerWire.terminalAttachAcknowledgementFeature),
            ]
            if access == .administrator {
                requestedFeatures.append(.string(BrokerWire.brokerAdministrationFeature))
            }
            let frame: JSONValue = .object([
                "type": .string("hello"),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "token": .string(info.token),
                // The broker validates instanceId as a UUID shape; the durable
                // owner identity travels in request params instead, and reattach
                // is authorized by project capability rather than instance.
                "instanceId": .string(connectionInstanceID),
                "appVersion": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "kaisola-native"),
                "access": .string(access.rawValue),
                "features": .array(requestedFeatures),
            ])
            encoded = try encode(frame, purpose: .hello)
        } catch {
            // Callers that joined while the socket was opening fail with the
            // error this one saw instead of waiting on a handshake that will
            // never be sent.
            failConnect(with: error)
            throw error
        }
        readerTask = Task { await readLoop() }

        return try await withCheckedThrowingContinuation { continuation in
            helloWaiters.append(continuation)
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
        rows: Int,
        restore: Bool = false
    ) async throws -> TerminalCreation {
        var params: [String: JSONValue] = [
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
        ]
        if restore {
            // Resurrection: the broker keeps this id's retained spool instead
            // of wiping it, so old scrollback survives into the new session.
            params["restore"] = .bool(true)
        }
        let result = try await request(.create, params: .object(params))
        guard let object = result.objectValue else {
            throw BrokerClientError.requestFailed("terminal.create")
        }
        if object["ok"]?.boolValue == false {
            if object["code"]?.stringValue == "terminal_capacity_exceeded",
               let maximum = object["maximumLiveTerminals"]?.intValue.flatMap(Int.init(exactly:)),
               (1...BrokerWire.maximumConfigurableLiveTerminals).contains(maximum) {
                throw BrokerClientError.terminalCapacityExceeded(maximum: maximum)
            }
            throw BrokerClientError.requestFailed("terminal.create")
        }
        let pid = object["pid"]?.intValue.flatMap(Int32.init(exactly:))
        let exited = object["exited"]?.boolValue ?? false
        // A live spawn always has a pid; only a cold record (ended terminal
        // restored for history) may omit it.
        guard pid != nil || exited else {
            throw BrokerClientError.requestFailed("terminal.create")
        }
        var recovered: TerminalRecoveredScrollback?
        if let payload = object["recovered"]?.objectValue,
           let text = payload["text"]?.stringValue {
            recovered = TerminalRecoveredScrollback(
                text: text,
                truncated: payload["truncated"]?.boolValue ?? false
            )
        }
        return TerminalCreation(
            terminalID: terminalID,
            projectID: projectID,
            pid: pid,
            exited: exited,
            streamEpoch: object["streamEpoch"]?.stringValue,
            recovered: recovered
        )
    }

    func attach(projectID: String, terminalID: String) async throws {
        let result = try await request(
            .attach,
            params: identity(projectID: projectID, terminalID: terminalID)
        )
        guard let object = result.objectValue else {
            throw BrokerClientError.requestFailed("terminal.attach")
        }
        // Attach is an ownership mutation, so a broker that cannot prove it
        // adopted the terminal must not be believed. That check is worth
        // keeping — but only a broker that acknowledges attach can satisfy it.
        //
        // A broker retained from before the acknowledgement existed answers
        // with a bare snapshot: no `ok`, no `id`. Demanding them turned every
        // attach against a still-running older broker into a refusal, and
        // `restoreOwnedSessions` reads a thrown attach as "another controller
        // holds it". Terminals came back read-only, and because only owned
        // terminals reach `scheduleDesiredTerminalResize`, they also stayed at
        // whatever geometry the broker had retained.
        //
        // The question is therefore what the broker is capable of saying, not
        // what this particular response happens to contain. Inferring "old
        // broker" from a missing field would also excuse a current broker that
        // answered malformed, which is exactly the case worth failing on.
        guard connectedFeatures.contains(BrokerWire.terminalAttachAcknowledgementFeature) else {
            return
        }
        guard object["ok"]?.boolValue == true,
              object["id"]?.stringValue == terminalID else {
            throw BrokerClientError.requestFailed("terminal.attach")
        }
    }

    func write(projectID: String, terminalID: String, data: String) async throws {
        guard var params = identity(projectID: projectID, terminalID: terminalID).objectValue else {
            throw BrokerClientError.malformedResponse
        }
        params["data"] = .string(data)
        let result = try await request(.write, params: .object(params))
        guard let object = result.objectValue,
              let accepted = object["ok"]?.boolValue else {
            throw BrokerClientError.malformedResponse
        }
        guard accepted else {
            if object["message"]?.stringValue == "terminal already ended" {
                throw TerminalWriteError.ended
            }
            if object["message"] == nil {
                throw TerminalWriteError.missing
            }
            throw BrokerClientError.requestFailed("terminal.write")
        }
    }

    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws {
        guard var params = identity(projectID: projectID, terminalID: terminalID).objectValue else {
            throw BrokerClientError.malformedResponse
        }
        params["cols"] = .integer(Int64(columns))
        params["rows"] = .integer(Int64(rows))
        let result = try await request(.resize, params: .object(params))
        guard result.objectValue?["ok"]?.boolValue == true else {
            throw BrokerClientError.requestFailed("terminal.resize")
        }
    }

    func kill(projectID: String, terminalID: String) async throws {
        let result = try await request(
            .kill,
            params: identity(projectID: projectID, terminalID: terminalID)
        )
        guard let object = result.objectValue,
              object["ok"]?.boolValue == true,
              object["id"]?.stringValue == terminalID else {
            throw BrokerClientError.requestFailed("terminal.kill")
        }
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
        let result = try await request(.agentTurn, params: .object(params))
        // The broker answers `{ok:false}` when the record is gone or predates
        // activity tracking. Discarding that left the app believing a turn was
        // protected while the broker still counted the terminal idle and
        // eligible for rolling cutover, so the rejection has to travel.
        guard result.objectValue?["ok"]?.boolValue == true else {
            throw BrokerClientError.requestFailed("terminal.agentTurn")
        }
    }

    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws {
        guard var params = identity(projectID: projectID, terminalID: terminalID).objectValue else {
            throw BrokerClientError.malformedResponse
        }
        params["active"] = .bool(active)
        let result = try await request(.controlLease, params: .object(params))
        guard result.objectValue?["ok"]?.boolValue == true,
              result.objectValue?["active"]?.boolValue == active else {
            throw BrokerClientError.requestFailed("terminal.controlLease")
        }
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
            try await connectForAdministration(to: info)
            guard connectedFeatures.contains(BrokerWire.brokerUpdateFeature) else {
                throw BrokerClientError.requestFailed("broker sealed update capability")
            }
            let status = try await request(
                "broker.status",
                params: .object(["ownerId": .string("0")])
            )
            try Self.validateUpgradeStatus(status, expected: info)
            let rolling = BrokerRollingUpdatePolicy.clientRoutingEnabled
                && (info.implementationVersion ?? 1) >= 2
            if rolling,
               !connectedFeatures.contains(BrokerWire.brokerRollingUpdateFeature) {
                throw BrokerClientError.requestFailed("broker rolling update capability")
            }
            let result = try await requestMutation(
                rolling ? "broker.prepareRollingUpdate" : "broker.shutdownForUpdate",
                params: .object([
                    "ownerId": .string("0"),
                    "expectedPid": .integer(Int64(info.pid)),
                    "expectedStartedAt": .integer(info.startedAt),
                    "expectedContentDigest": .string(runningDigest),
                    "targetContentDigest": .string(targetContentDigest),
                    "stabilityWindowMs": .integer(300),
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

    func cancelRollingUpdate(
        from info: BrokerInfo,
        targetContentDigest: String
    ) async throws {
        guard let runningDigest = info.contentDigest else {
            throw BrokerClientError.requestFailed("broker helper identity")
        }
        do {
            try await connectForAdministration(to: info)
            let result = try await requestMutation(
                "broker.cancelRollingUpdate",
                params: .object([
                    "ownerId": .string("0"),
                    "expectedPid": .integer(Int64(info.pid)),
                    "expectedStartedAt": .integer(info.startedAt),
                    "expectedContentDigest": .string(runningDigest),
                    "targetContentDigest": .string(targetContentDigest),
                ])
            )
            guard result.objectValue?["ok"]?.boolValue == true,
                  result.objectValue?["state"]?.stringValue == "current" else {
                throw BrokerClientError.identityChanged
            }
            await disconnect()
        } catch {
            await disconnect()
            throw error
        }
    }

    func requestRetirement(
        of info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerRetirementDecision {
        guard let runningDigest = info.contentDigest else {
            throw BrokerClientError.requestFailed("broker helper identity")
        }
        do {
            try await connectForAdministration(to: info)
            let status = try await request(
                "broker.status",
                params: .object(["ownerId": .string("0")])
            )
            try Self.validateUpgradeStatus(status, expected: info)
            let result = try await requestMutation(
                "broker.retireDraining",
                params: .object([
                    "ownerId": .string("0"),
                    "expectedPid": .integer(Int64(info.pid)),
                    "expectedStartedAt": .integer(info.startedAt),
                    "expectedContentDigest": .string(runningDigest),
                    "targetContentDigest": .string(targetContentDigest),
                ])
            )
            let decision = try Self.retirementDecision(result)
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
        try await requestMutation(method.rawValue, params: params)
    }

    private func requestMutation(_ method: String, params: JSONValue) async throws -> JSONValue {
        guard var mutationParams = params.objectValue else {
            throw BrokerClientError.malformedResponse
        }
        // A timeout only proves the response was not observed. Retrying once
        // with the same idempotency key lets the broker join/replay the exact
        // mutation instead of duplicating input, processes, or lifecycle work.
        mutationParams["mutationId"] = .string(UUID().uuidString.lowercased())
        let reconciledParams = JSONValue.object(mutationParams)
        do {
            return try await request(method, params: reconciledParams)
        } catch BrokerClientError.requestTimedOut {
            guard connectedFeatures.contains(BrokerWire.brokerMutationIdempotencyFeature) else {
                throw BrokerClientError.requestTimedOut
            }
            return try await request(method, params: reconciledParams)
        }
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
        let encoded = try encode(frame, purpose: .request(method))
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = PendingRequest(method: method, continuation: continuation)
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
                // A failed socket write is verified controller-connection
                // loss, not a terminal rejection. Abort the lane so the
                // router cannot reuse a poisoned child on reconnect.
                catch { await abortConnection(with: error) }
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
        case "updating", "rolling":
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
            let blockers = BrokerUpgradeBlockers(
                liveTerminalCount: liveCount,
                liveTerminalIDs: liveIDs,
                busyAgentCount: busyCount,
                busyTerminalIDs: busyIDs,
                childTaskCount: childCount
            )
            switch object["reason"]?.stringValue {
            case "activity_changed": return .activityChanged(blockers)
            case "lease_changed": return .companionLeaseChanged(blockers)
            default: return .deferred(blockers)
            }
        default:
            throw BrokerClientError.malformedResponse
        }
    }

    nonisolated static func retirementDecision(_ value: JSONValue) throws -> BrokerRetirementDecision {
        guard let object = value.objectValue,
              let state = object["state"]?.stringValue else {
            throw BrokerClientError.malformedResponse
        }
        switch state {
        case "retiring":
            guard object["ok"]?.boolValue == true else { throw BrokerClientError.malformedResponse }
            return .accepted
        case "identity_changed":
            guard object["ok"]?.boolValue == false else { throw BrokerClientError.malformedResponse }
            return .identityChanged
        case "pending":
            guard object["ok"]?.boolValue == false,
                  let clientCount = object["clientCount"]?.intValue.flatMap(Int.init(exactly:)),
                  clientCount >= 0 else {
                throw BrokerClientError.malformedResponse
            }
            let decision = try upgradeDecision(value)
            guard case let .deferred(blockers) = decision else {
                throw BrokerClientError.malformedResponse
            }
            return .deferred(blockers, clientCount: clientCount)
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
                    _ = try BrokerWire.validateDecodedFrame(data) { id in
                        pending[id]?.method
                    }
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
        // Closing the transport wakes the reader, which can observe the same
        // failure. Settle and report the connection only once.
        guard !connectionAbortInProgress,
              connected || connectInFlight != nil || !helloWaiters.isEmpty || !pending.isEmpty else { return }
        connectionAbortInProgress = true
        defer { connectionAbortInProgress = false }
        await transport.close()
        readerTask = nil
        decoder = BrokerLineFrameDecoder()
        failConnection(with: error)
        disconnectHandler?(error)
    }

    private func handle(_ frame: JSONValue) throws {
        guard let object = frame.objectValue, let type = object["type"]?.stringValue else {
            throw BrokerClientError.malformedResponse
        }
        switch type {
        case "hello":
            guard let info = connectInFlight?.info else { throw BrokerClientError.notConnected }
            guard object["ok"]?.boolValue == true else { throw BrokerClientError.authenticationRejected }
            guard object["protocol"]?.intValue == Int64(info.protocolVersion) else {
                throw BrokerClientError.protocolMismatch
            }
            guard object["securityEpoch"]?.intValue == Int64(info.securityEpoch) else {
                throw BrokerClientError.securityEpochMismatch
            }
            let advertisedImplementation = object["implementationVersion"]?.intValue
                .flatMap(Int.init(exactly:))
            guard BrokerWire.accepts(
                protocolVersion: info.protocolVersion,
                securityEpoch: info.securityEpoch,
                implementationVersion: advertisedImplementation
            ) else {
                throw BrokerClientError.implementationMismatch
            }
            let implementationVersion = advertisedImplementation ?? 1
            let packageSchema = object["packageSchema"]?.intValue.flatMap(Int.init(exactly:))
            let packageVersion = object["packageVersion"]?.stringValue
            let contentDigest = object["contentDigest"]?.stringValue
            if let contentDigest,
               !BrokerHelperPackageVerification.isLowercaseSHA256(contentDigest) {
                throw BrokerClientError.identityChanged
            }
            // The socket path selected the peer and the token authenticated it;
            // every non-secret immutable field echoed by hello must still bind
            // that endpoint to the exact BrokerInfo reviewed before connect.
            guard object["pid"]?.intValue == Int64(info.pid),
                  object["startedAt"]?.intValue == info.startedAt,
                  object["version"]?.stringValue == info.version,
                  info.implementationVersion == nil || info.implementationVersion == implementationVersion,
                  info.packageSchema == nil || info.packageSchema == packageSchema,
                  info.packageVersion == nil || info.packageVersion == packageVersion,
                  info.contentDigest == nil || info.contentDigest == contentDigest else {
                throw BrokerClientError.identityChanged
            }
            // Control requires a broker modern enough to advertise observation:
            // the same generation that enforces roles server-side. Older live
            // brokers stay strictly observed-or-offline.
            let features = Set(object["features"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            guard features.contains(BrokerWire.terminalObserveFeature) else {
                throw BrokerClientError.observeFeatureMissing
            }
            guard let expectedIdentity = connectInFlight ?? connectedIdentity,
                  object["access"]?.stringValue == expectedIdentity.access.rawValue else {
                throw BrokerClientError.authenticationRejected
            }
            let negotiatedFeatures = Set(
                object["negotiatedFeatures"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            if expectedIdentity.access == .administrator {
                guard features.contains(BrokerWire.brokerAdministrationFeature),
                      negotiatedFeatures.contains(BrokerWire.brokerAdministrationFeature) else {
                    throw BrokerClientError.authenticationRejected
                }
            } else if negotiatedFeatures.contains(BrokerWire.brokerAdministrationFeature) {
                throw BrokerClientError.authenticationRejected
            }
            connected = true
            connectedFeatures = features
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            completeConnect()
        case "response":
            guard let id = object["id"]?.stringValue, let request = pending.removeValue(forKey: id) else {
                return
            }
            requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            if object["ok"]?.boolValue == true, let result = object["result"] {
                request.continuation.resume(returning: result)
            } else {
                request.continuation.resume(
                    throwing: BrokerClientError.requestFailed(object["message"]?.stringValue ?? "request")
                )
            }
        case "event":
            // The controller connection carries no streams; events belong to
            // the observer connection.
            break
        default:
            break
        }
    }

    private func encode(_ frame: JSONValue, purpose: BrokerFramePurpose) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        do {
            try BrokerWire.validateEncodedFrame(data, purpose: purpose)
        } catch {
            throw BrokerClientError.frameRejected
        }
        data.append(0x0A)
        return data
    }

    private func failRequest(_ id: String, with error: any Error) {
        requestTimeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }

    /// Hands the settled handshake to everyone who coalesced onto it and closes
    /// the window, so the next connect starts a fresh one.
    private func completeConnect() {
        connectInFlight = nil
        let waiters = helloWaiters
        helloWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ()) }
    }

    private func failConnect(with error: any Error) {
        connectInFlight = nil
        connectedIdentity = nil
        let waiters = helloWaiters
        helloWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func failConnection(with error: any Error) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        failConnect(with: error)
        for task in requestTimeoutTasks.values { task.cancel() }
        requestTimeoutTasks.removeAll()
        for request in pending.values { request.continuation.resume(throwing: error) }
        pending.removeAll()
        connected = false
        connectedFeatures = []
        // A dead lane holds no identity: the next connect is free to adopt a
        // replacement broker or a new owner.
        connectedIdentity = nil
    }
}
