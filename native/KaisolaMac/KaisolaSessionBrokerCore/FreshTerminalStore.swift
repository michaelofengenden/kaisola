import Foundation
import KaisolaBrokerProtocol

public struct FreshTerminalSpawnRequest: Equatable, Sendable {
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public let cwd: String
    public let columns: Int
    public let rows: Int

    public init(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        columns: Int,
        rows: Int
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.columns = columns
        self.rows = rows
    }
}

/// The `{exitCode, signal}` record protocol 2 publishes with terminal exit.
/// `signal` is the raw signal number, mirroring node-pty's exit callback, and
/// `exitCode` substitutes 0 for a signal-terminated child exactly as the Node
/// broker does before putting the record on the wire.
public struct FreshTerminalExitStatus: Equatable, Sendable {
    public let exitCode: Int64
    public let signal: Int64?

    public init(exitCode: Int64, signal: Int64? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

/// The minimum process boundary the fresh-session store needs. A concrete
/// Darwin PTY remains free to expose richer exit information; its conformance
/// can discard that detail in these two lifecycle adapter methods.
public protocol FreshTerminalProcess: Sendable {
    var pid: Int32 { get }
    func write(_ data: Data) throws
    func resize(columns: Int, rows: Int) throws
    func send(signal: Int32) throws
    func waitForFreshTerminalExit() async
    func terminateFreshTerminal(graceNanoseconds: UInt64) async throws
    /// Resolved after `waitForFreshTerminalExit`. Nil means the backend could
    /// not attribute a status; exit publication then carries a null record
    /// rather than a fabricated success.
    func freshTerminalExitStatus() async -> FreshTerminalExitStatus?
}

extension FreshTerminalProcess {
    public func freshTerminalExitStatus() async -> FreshTerminalExitStatus? { nil }
}

public protocol FreshTerminalProcessFactory: Sendable {
    func spawn(
        request: FreshTerminalSpawnRequest,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> any FreshTerminalProcess
}

/// The authenticated connection is separate from these three wire fields.
/// Keeping the request identity explicit prevents a caller from authorizing one
/// project and then mutating a terminal under another project in the same call.
public struct FreshTerminalIdentity: Equatable, Sendable {
    public let ownerID: String
    public let projectID: String
    public let id: String

    public init(ownerID: String, projectID: String, id: String) {
        self.ownerID = ownerID
        self.projectID = projectID
        self.id = id
    }
}

/// Exact fields currently emitted by `BrokerControlClient` for
/// `terminal.create`. `restore` is represented so fresh mode can refuse it
/// explicitly instead of silently starting a replacement shell.
public struct FreshTerminalCreateRequest: Equatable, Sendable {
    public let ownerID: String
    public let projectID: String
    public let id: String
    public let command: String
    public let args: [String]
    public let cwd: String
    public let env: [String: String]
    public let cols: Int
    public let rows: Int
    public let restore: Bool

    public init(
        ownerID: String,
        projectID: String,
        id: String,
        command: String,
        args: [String],
        cwd: String,
        env: [String: String],
        cols: Int,
        rows: Int,
        restore: Bool = false
    ) {
        self.ownerID = ownerID
        self.projectID = projectID
        self.id = id
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.cols = cols
        self.rows = rows
        self.restore = restore
    }
}

/// Carries the whole reply snapshot, captured in the same critical section
/// that arms the creator's primary stream — the create response is built from
/// this one value, never from a second read that live output could outrun.
public struct FreshTerminalCreation: Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let existed: Bool
    public let streamEpoch: String
    public let output: String
    public let startOffset: Int64
    public let endOffset: Int64
    public let truncated: Bool
    public let exited: Bool
    public let cwd: String
    public let cols: Int
    public let rows: Int
}

public struct FreshTerminalInventoryRecord: Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let exited: Bool
    public let owner: String
    public let lastOwner: String
    public let streamEpoch: String
    public let endOffset: Int64
    public let cwd: String
    public let cols: Int
    public let rows: Int
}

public struct FreshTerminalInventorySnapshot: Equatable, Sendable {
    public let activityEpoch: Int64
    public let records: [FreshTerminalInventoryRecord]

    public init(activityEpoch: Int64, records: [FreshTerminalInventoryRecord]) {
        self.activityEpoch = activityEpoch
        self.records = records
    }
}

public struct FreshTerminalSnapshot: Equatable, Sendable {
    public let streamEpoch: String
    public let output: String
    public let startOffset: Int64
    public let endOffset: Int64
    public let truncated: Bool
    public let exited: Bool
    public let exitStatus: FreshTerminalExitStatus?

    public init(
        streamEpoch: String,
        output: String,
        startOffset: Int64,
        endOffset: Int64,
        truncated: Bool,
        exited: Bool,
        exitStatus: FreshTerminalExitStatus? = nil
    ) {
        self.streamEpoch = streamEpoch
        self.output = output
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.truncated = truncated
        self.exited = exited
        self.exitStatus = exitStatus
    }
}

/// One `terminal.subscribe` answer, produced inside the same critical section
/// that registers the subscription so nothing can slot between the snapshot
/// and the first live event.
public enum FreshTerminalSubscribeReply: Equatable, Sendable {
    case unavailable
    case snapshot(FreshTerminalSnapshot, resetReason: String?)
    case current(streamEpoch: String, offset: Int64)
}

public struct FreshTerminalHistoryPage: Equatable, Sendable {
    public let streamEpoch: String
    public let output: String
    public let startOffset: Int64
    public let endOffset: Int64
    public let hasMore: Bool
    public let truncated: Bool
}

/// The Node broker sends `{type:'event', ownerId, projectId, channel, payload}`
/// on the subscriber's own connection. The store only knows subscriber owner
/// keys; the service resolves them to connections and enforces per-client
/// payload shaping, so the sink is exactly Node's `mgr.setEventSink` boundary.
public typealias FreshTerminalEventSink = @Sendable (
    _ owner: String,
    _ channel: String,
    _ payload: BrokerJSONValue,
    _ maxQueueBytes: Int?,
    _ force: Bool
) -> Bool

public struct FreshTerminalRelease: Equatable, Sendable {
    public let id: String
    public let released: Bool
    public let alreadyAbsent: Bool
}

public enum FreshTerminalSignal: Int32, Equatable, Sendable {
    case hangup = 1
    case interrupt = 2
    case terminate = 15
    case kill = 9
}

public enum FreshTerminalStoreError: Error, Equatable, LocalizedError, Sendable {
    case controllerRequired
    case invalidClientIdentity
    case invalidOwner
    case invalidProject
    case invalidTerminalID
    case invalidCommand
    case invalidArguments
    case invalidEnvironment
    case invalidCWD
    case invalidGeometry(field: String)
    case restoreUnsupported
    case capacityExceeded(maximum: Int)
    case terminalCreationInProgress
    case terminalReleaseInProgress
    case terminalNotFound
    case terminalAccessDenied
    case terminalEnded
    case writePayloadTooLarge(maximumBytes: Int, actualBytes: Int)
    case processOperationFailed(operation: String)
    case shuttingDown
    case shutdownIncomplete(ids: [String])
    case invalidObserverCursor
    case invalidObserverSubscriber
    case observerLimitReached(maximum: Int)
    case historyEpochMismatch
    case invalidHistoryOffset

    public var errorDescription: String? {
        switch self {
        case .controllerRequired:
            "terminal mutations require controller access"
        case .invalidClientIdentity:
            "invalid terminal client identity"
        case .invalidOwner:
            "invalid terminal owner identity"
        case .invalidProject:
            "invalid terminal project scope"
        case .invalidTerminalID:
            "invalid terminal id"
        case .invalidCommand:
            "invalid terminal command"
        case .invalidArguments:
            "invalid terminal arguments"
        case .invalidEnvironment:
            "invalid terminal environment"
        case .invalidCWD:
            "invalid terminal working directory"
        case let .invalidGeometry(field):
            "terminal \(field) must be a finite positive integer"
        case .restoreUnsupported:
            "fresh Swift broker does not restore prior terminal state"
        case let .capacityExceeded(maximum):
            "broker terminal capacity reached (maximum \(maximum))"
        case .terminalCreationInProgress:
            "terminal creation is already in progress"
        case .terminalReleaseInProgress:
            "terminal release is already in progress"
        case .terminalNotFound:
            "terminal is no longer available"
        case .terminalAccessDenied:
            "terminal access denied"
        case .terminalEnded:
            "terminal already ended"
        case let .writePayloadTooLarge(maximumBytes, actualBytes):
            "terminal write is \(actualBytes) bytes; maximum is \(maximumBytes)"
        case let .processOperationFailed(operation):
            "terminal process operation failed: \(operation)"
        case .shuttingDown:
            "terminal store is shutting down"
        case let .shutdownIncomplete(ids):
            "terminal shutdown is incomplete for \(ids.count) processes"
        // The next five reuse the Node broker's exact rejection strings:
        // protocol-2 clients branch on these messages, not on typed codes.
        case .invalidObserverCursor:
            "invalid terminal observer cursor"
        case .invalidObserverSubscriber:
            "terminal subscriber is invalid"
        case let .observerLimitReached(maximum):
            "terminal observer limit of \(maximum) reached"
        case .historyEpochMismatch:
            "terminal history epoch mismatch"
        case .invalidHistoryOffset:
            "invalid terminal history offset"
        }
    }
}

public actor FreshTerminalStore {
    private enum Limits {
        static let maximumRetainedExitedTerminals = 64
        static let outputTailBytes = 512 * 1_024
        static let maximumTerminalIDCharacters = 240
        static let maximumCommandBytes = 16 * 1_024
        static let maximumCWDBytes = 16 * 1_024
        static let maximumArgumentCount = 200
        static let maximumArgumentBytes = 16 * 1_024
        static let maximumArgumentsBytes = 256 * 1_024
        static let maximumEnvironmentEntries = 256
        static let maximumEnvironmentKeyBytes = 1_024
        static let maximumEnvironmentValueBytes = 64 * 1_024
        static let maximumEnvironmentBytes = 256 * 1_024
        static let maximumGeometry = 1_000
        static let maximumWriteBytes = 64 * 1_024
        static let releaseGraceNanoseconds: UInt64 = 500_000_000
    }

    private struct Record {
        let token: UUID
        let process: any FreshTerminalProcess
        let id: String
        let projectID: String
        var owner: String
        var lastOwner: String
        let output: FreshTerminalOutputAccumulator
        let cwd: String
        var cols: Int
        var rows: Int
        var exited: Bool
        var exitSequence: UInt64?
    }

    private struct PendingCreate {
        let token: UUID
        let projectID: String
        let owner: String
        let output: FreshTerminalOutputAccumulator
        var cancellationRequested: Bool
        var waiters: [CheckedContinuation<Void, Never>]
    }

    private struct PendingRelease {
        let token: UUID
        let task: Task<Void, any Error>
    }

    private let factory: any FreshTerminalProcessFactory
    private let maximumLiveTerminals: Int
    private let activityClock = FreshTerminalActivityClock()
    private let eventSinkBox = FreshTerminalEventSinkBox()
    private var records: [String: Record] = [:]
    private var pendingCreates: [String: PendingCreate] = [:]
    private var pendingReleases: [String: PendingRelease] = [:]
    private var isShuttingDown = false
    private var exitSequence: UInt64 = 0

    public init(
        factory: any FreshTerminalProcessFactory,
        maximumLiveTerminals: Int = BrokerWire.defaultMaximumLiveTerminals
    ) {
        self.factory = factory
        self.maximumLiveTerminals = min(
            max(maximumLiveTerminals, 1),
            BrokerWire.maximumConfigurableLiveTerminals
        )
    }

    /// Installed once by the broker service. Nonisolated because deliveries
    /// happen synchronously on the PTY read path, under each terminal's own
    /// output lock — never through this actor's mailbox, whose reentrancy
    /// would break the snapshot-then-live ordering guarantee.
    public nonisolated func setEventSink(_ sink: FreshTerminalEventSink?) {
        eventSinkBox.set(sink)
    }

    /// `respond` is the create analog of `subscribe`'s reply hand-off: it runs
    /// exactly once, synchronously, inside the terminal's output critical
    /// section and *before* the creator's primary stream is armed. A connection
    /// that enqueues the response there gets it onto the wire ahead of every
    /// `terminal:data` event, and the reply's snapshot ends exactly where those
    /// events begin — no byte in both, no byte in neither.
    public func create(
        client: BrokerAuthenticatedClient,
        request: FreshTerminalCreateRequest,
        primaryStreamEnabled: Bool = true,
        respond: (@Sendable (FreshTerminalCreation) -> Void)? = nil
    ) async throws -> FreshTerminalCreation {
        guard !isShuttingDown else { throw FreshTerminalStoreError.shuttingDown }
        let owner = try validatedOwner(
            client: client,
            ownerID: request.ownerID,
            projectID: request.projectID
        )
        try validateTerminalID(request.id)
        try validateCreatePayload(request)
        guard !request.restore else { throw FreshTerminalStoreError.restoreUnsupported }

        if var record = records[request.id] {
            guard record.projectID == request.projectID else {
                throw FreshTerminalStoreError.terminalAccessDenied
            }
            guard pendingReleases[request.id] == nil else {
                throw FreshTerminalStoreError.terminalReleaseInProgress
            }
            if !record.exited {
                // `terminal.create` is the explicit same-project adoption path.
                // Ordinary writes below still require this exact new owner.
                record.owner = owner
                record.lastOwner = owner
                records[request.id] = record
                // Adoption is the fresh analog of a renderer reattach: the
                // adopting connection re-answers the primary-stream policy
                // and clears any slow-consumer pause, because the create
                // response it just received replays the snapshot — captured,
                // answered, and armed as one step against concurrent output.
                let adopted = record.output.armPrimary(
                    owner: owner,
                    enabled: primaryStreamEnabled
                ) { snapshot in
                    let adopted = Self.creation(
                        record: record,
                        existed: true,
                        snapshot: snapshot
                    )
                    respond?(adopted)
                    return adopted
                }
                activityClock.advance()
                return adopted
            }
            // Retain the ended record until the replacement process has
            // spawned successfully. Installing the new live record below is
            // the atomic replacement point; capacity or spawn failure must
            // leave the prior output snapshot and activity epoch intact.
        }

        if let pending = pendingCreates[request.id] {
            guard pending.projectID == request.projectID else {
                throw FreshTerminalStoreError.terminalAccessDenied
            }
            throw FreshTerminalStoreError.terminalCreationInProgress
        }
        let liveCount = records.values.lazy.filter { !$0.exited }.count
        guard liveCount + pendingCreates.count < maximumLiveTerminals else {
            throw FreshTerminalStoreError.capacityExceeded(
                maximum: maximumLiveTerminals
            )
        }

        let geometry = try validatedGeometry(cols: request.cols, rows: request.rows)
        let token = UUID()
        let streamEpoch = UUID().uuidString.lowercased()
        let output: FreshTerminalOutputAccumulator
        do {
            output = try FreshTerminalOutputAccumulator(
                terminalID: request.id,
                streamEpoch: streamEpoch,
                tailByteLimit: Limits.outputTailBytes,
                activityClock: activityClock,
                eventSink: eventSinkBox
            )
        } catch {
            throw FreshTerminalStoreError.processOperationFailed(operation: "output")
        }
        pendingCreates[request.id] = PendingCreate(
            token: token,
            projectID: request.projectID,
            owner: owner,
            output: output,
            cancellationRequested: false,
            waiters: []
        )
        let spawnRequest = FreshTerminalSpawnRequest(
            command: request.command,
            arguments: request.args,
            environment: request.env,
            cwd: request.cwd,
            columns: geometry.cols,
            rows: geometry.rows
        )

        let process: any FreshTerminalProcess
        do {
            process = try await factory.spawn(
                request: spawnRequest,
                onOutput: { data in
                    output.append(data)
                }
            )
        } catch {
            removePendingCreate(id: request.id, token: token)
            throw FreshTerminalStoreError.processOperationFailed(operation: "create")
        }

        guard let pending = pendingCreates[request.id], pending.token == token else {
            do {
                try await process.terminateFreshTerminal(
                    graceNanoseconds: Limits.releaseGraceNanoseconds
                )
            } catch {
                throw FreshTerminalStoreError.processOperationFailed(operation: "create")
            }
            throw FreshTerminalStoreError.terminalCreationInProgress
        }

        let record = Record(
            token: token,
            process: process,
            id: request.id,
            projectID: request.projectID,
            owner: owner,
            lastOwner: owner,
            output: output,
            cwd: request.cwd,
            cols: geometry.cols,
            rows: geometry.rows,
            exited: false,
            exitSequence: nil
        )
        records[request.id] = record
        activityClock.advance()
        Task { [weak self] in
            await process.waitForFreshTerminalExit()
            let status = await process.freshTerminalExitStatus()
            await self?.markExited(terminalID: request.id, token: token, status: status)
        }
        removePendingCreate(id: request.id, token: token)
        if isShuttingDown {
            throw FreshTerminalStoreError.shuttingDown
        }
        if pending.cancellationRequested {
            throw FreshTerminalStoreError.terminalReleaseInProgress
        }
        // Armed last, past every throw above (a reply already handed out could
        // not be taken back), and atomically with the reply: bytes produced up
        // to this moment are in the reply's snapshot, bytes after it are the
        // armed stream's.
        return record.output.armPrimary(
            owner: owner,
            enabled: primaryStreamEnabled
        ) { snapshot in
            let made = Self.creation(record: record, existed: false, snapshot: snapshot)
            respond?(made)
            return made
        }
    }

    /// `terminal.attach` for an in-process controller: take ownership of an
    /// EXISTING terminal without ever spawning a replacement. Unlike `create`
    /// with an existing id, a missing terminal throws and an ended terminal is
    /// a successful no-op (its writes will still refuse with `terminalEnded`).
    /// Returns whether the terminal is still live.
    @discardableResult
    public func adopt(
        client: BrokerAuthenticatedClient,
        identity: FreshTerminalIdentity
    ) throws -> Bool {
        let owner = try validatedOwner(
            client: client,
            ownerID: identity.ownerID,
            projectID: identity.projectID
        )
        try validateTerminalID(identity.id)
        guard var record = records[identity.id] else {
            throw FreshTerminalStoreError.terminalNotFound
        }
        guard record.projectID == identity.projectID else {
            throw FreshTerminalStoreError.terminalAccessDenied
        }
        guard pendingReleases[identity.id] == nil else {
            throw FreshTerminalStoreError.terminalReleaseInProgress
        }
        guard !record.exited else { return false }
        record.owner = owner
        record.lastOwner = owner
        records[identity.id] = record
        // Same discipline as create-adoption: clear any slow-consumer pause
        // and re-answer the primary policy atomically against output.
        record.output.armPrimary(owner: owner, enabled: false) { _ in }
        activityClock.advance()
        return true
    }

    public func write(
        client: BrokerAuthenticatedClient,
        identity: FreshTerminalIdentity,
        data: String
    ) throws {
        let record = try liveAuthorizedRecord(client: client, identity: identity)
        let bytes = Data(data.utf8)
        guard bytes.count <= Limits.maximumWriteBytes else {
            throw FreshTerminalStoreError.writePayloadTooLarge(
                maximumBytes: Limits.maximumWriteBytes,
                actualBytes: bytes.count
            )
        }
        do {
            try record.process.write(bytes)
            activityClock.advance()
        } catch {
            throw FreshTerminalStoreError.processOperationFailed(operation: "write")
        }
    }

    public func resize(
        client: BrokerAuthenticatedClient,
        identity: FreshTerminalIdentity,
        cols: Int,
        rows: Int
    ) throws {
        let record = try liveAuthorizedRecord(client: client, identity: identity)
        let geometry = try validatedGeometry(cols: cols, rows: rows)
        do {
            try record.process.resize(columns: geometry.cols, rows: geometry.rows)
        } catch {
            throw FreshTerminalStoreError.processOperationFailed(operation: "resize")
        }
        guard var current = records[identity.id], current.token == record.token else {
            throw FreshTerminalStoreError.terminalNotFound
        }
        current.cols = geometry.cols
        current.rows = geometry.rows
        records[identity.id] = current
        activityClock.advance()
    }

    public func signal(
        client: BrokerAuthenticatedClient,
        identity: FreshTerminalIdentity,
        signal: FreshTerminalSignal
    ) throws {
        let record = try liveAuthorizedRecord(client: client, identity: identity)
        do {
            try record.process.send(signal: signal.rawValue)
            activityClock.advance()
        } catch {
            throw FreshTerminalStoreError.processOperationFailed(operation: "signal")
        }
    }

    public func kill(
        client: BrokerAuthenticatedClient,
        identity: FreshTerminalIdentity
    ) throws {
        let record = try liveAuthorizedRecord(client: client, identity: identity)
        do {
            try record.process.send(signal: FreshTerminalSignal.kill.rawValue)
            activityClock.advance()
        } catch {
            throw FreshTerminalStoreError.processOperationFailed(operation: "kill")
        }
    }

    public func release(
        client: BrokerAuthenticatedClient,
        identity: FreshTerminalIdentity
    ) async throws -> FreshTerminalRelease {
        let owner = try validatedOwner(
            client: client,
            ownerID: identity.ownerID,
            projectID: identity.projectID
        )
        try validateTerminalID(identity.id)
        if var pendingCreate = pendingCreates[identity.id] {
            guard pendingCreate.projectID == identity.projectID,
                  pendingCreate.owner == owner else {
                throw FreshTerminalStoreError.terminalAccessDenied
            }
            pendingCreate.cancellationRequested = true
            await withCheckedContinuation { continuation in
                pendingCreate.waiters.append(continuation)
                pendingCreates[identity.id] = pendingCreate
            }
        }
        guard let record = records[identity.id] else {
            return FreshTerminalRelease(
                id: identity.id,
                released: true,
                alreadyAbsent: true
            )
        }
        guard record.projectID == identity.projectID, record.owner == owner else {
            throw FreshTerminalStoreError.terminalAccessDenied
        }
        if record.exited {
            records.removeValue(forKey: identity.id)
            activityClock.advance()
            return FreshTerminalRelease(
                id: identity.id,
                released: true,
                alreadyAbsent: false
            )
        }

        let pending: PendingRelease
        if let existing = pendingReleases[identity.id], existing.token == record.token {
            pending = existing
        } else {
            let process = record.process
            let task = Task {
                try await process.terminateFreshTerminal(
                    graceNanoseconds: Limits.releaseGraceNanoseconds
                )
            }
            pending = PendingRelease(token: record.token, task: task)
            pendingReleases[identity.id] = pending
        }

        do {
            try await pending.task.value
        } catch {
            if pendingReleases[identity.id]?.token == pending.token {
                pendingReleases.removeValue(forKey: identity.id)
            }
            throw FreshTerminalStoreError.processOperationFailed(operation: "release")
        }
        if records[identity.id]?.token == pending.token {
            records.removeValue(forKey: identity.id)
            activityClock.advance()
        }
        if pendingReleases[identity.id]?.token == pending.token {
            pendingReleases.removeValue(forKey: identity.id)
        }
        return FreshTerminalRelease(
            id: identity.id,
            released: true,
            alreadyAbsent: false
        )
    }

    public func inventory() -> [FreshTerminalInventoryRecord] {
        inventoryRecords()
    }

    public func atomicInventorySnapshot() -> FreshTerminalInventorySnapshot {
        activityClock.withCriticalSection { epoch in
            FreshTerminalInventorySnapshot(
                activityEpoch: epoch,
                records: inventoryRecords()
            )
        }
    }

    public func currentActivityEpoch() -> Int64 {
        activityClock.current()
    }

    private func inventoryRecords() -> [FreshTerminalInventoryRecord] {
        records.values
            .map { record in
                let snapshot = record.output.snapshot()
                return FreshTerminalInventoryRecord(
                    id: record.id,
                    pid: record.process.pid,
                    exited: record.exited,
                    owner: record.owner,
                    lastOwner: record.lastOwner,
                    streamEpoch: snapshot.streamEpoch,
                    endOffset: snapshot.endOffset,
                    cwd: record.cwd,
                    cols: record.cols,
                    rows: record.rows
                )
            }
            .sorted { $0.id < $1.id }
    }

    public func snapshot(
        id: String,
        projectID: String,
        owner: String? = nil
    ) throws -> FreshTerminalSnapshot? {
        guard let record = records[id] else { return nil }
        guard record.projectID == projectID,
              owner == nil || record.owner == owner else {
            throw FreshTerminalStoreError.terminalAccessDenied
        }
        let snapshot = record.output.snapshot()
        return FreshTerminalSnapshot(
            streamEpoch: snapshot.streamEpoch,
            output: snapshot.output,
            startOffset: snapshot.startOffset,
            endOffset: snapshot.endOffset,
            truncated: snapshot.truncated,
            exited: record.exited,
            exitStatus: record.output.currentExitStatus()
        )
    }

    /// Registers one bounded live subscription and answers with the snapshot
    /// (or resume classification) taken inside the same critical section that
    /// serializes PTY output — the ordering barrier that makes the reply and
    /// the first live event gapless and duplicate-free. `respond` runs exactly
    /// once, synchronously, before any later output can be broadcast; when it
    /// enqueues onto a connection's outbound queue, the wire order is
    /// response first, events after.
    public func subscribe(
        id: String,
        projectID: String,
        accessOwner: String?,
        subscriber: String,
        streamEpoch: String?,
        afterOffset: Int64?,
        maxQueueBytes: Int64?,
        respond: @Sendable (FreshTerminalSubscribeReply) -> Void
    ) throws {
        guard let record = records[id] else {
            respond(.unavailable)
            return
        }
        guard record.projectID == projectID,
              accessOwner == nil || record.owner == accessOwner else {
            throw FreshTerminalStoreError.terminalAccessDenied
        }
        try record.output.subscribe(
            subscriber: subscriber,
            maxQueueBytes: maxQueueBytes,
            streamEpoch: streamEpoch,
            afterOffset: afterOffset,
            respond: respond
        )
    }

    /// Reports `removed` truthfully. A missing terminal is not an error — the
    /// subscription it would have carried is definitionally gone.
    public func unsubscribe(
        id: String,
        projectID: String,
        accessOwner: String?,
        subscriber: String
    ) throws -> Bool {
        guard let record = records[id] else { return false }
        guard record.projectID == projectID,
              accessOwner == nil || record.owner == accessOwner else {
            throw FreshTerminalStoreError.terminalAccessDenied
        }
        return record.output.unsubscribe(subscriber: subscriber)
    }

    /// Socket loss removes every subscription that connection registered, on
    /// every terminal, exactly like the Node broker's
    /// `unsubscribeSubscriberPrefix(instanceId + "|")`.
    public func unsubscribeSubscriberPrefix(_ prefix: String) {
        guard !prefix.isEmpty else { return }
        for record in records.values {
            record.output.unsubscribe(prefix: prefix)
        }
    }

    /// One older observer-safe history page over the retained tail. Nil means
    /// the terminal is gone (the caller answers the Node unavailable shape);
    /// epoch and offset violations throw the Node broker's exact rejections.
    public func history(
        id: String,
        projectID: String,
        accessOwner: String?,
        streamEpoch: String?,
        beforeOffset: Int64?,
        maxBytes: Int64?
    ) throws -> FreshTerminalHistoryPage? {
        guard let record = records[id] else { return nil }
        guard record.projectID == projectID,
              accessOwner == nil || record.owner == accessOwner else {
            throw FreshTerminalStoreError.terminalAccessDenied
        }
        return try record.output.historyPage(
            streamEpoch: streamEpoch,
            beforeOffset: beforeOffset,
            maxBytes: maxBytes
        )
    }

    /// Shutdown is fail-closed: it attempts every process even after one
    /// failure, removes only confirmed terminations, and names retained ids so
    /// a caller can retry instead of mistaking an accepted signal for reaping.
    public func shutdown() async throws {
        isShuttingDown = true
        for id in pendingCreates.keys {
            pendingCreates[id]?.cancellationRequested = true
        }
        while !pendingCreates.isEmpty {
            await Task.yield()
        }

        var failed: [String] = []
        for id in records.keys.sorted() {
            guard let record = records[id] else { continue }
            if record.exited {
                records.removeValue(forKey: id)
                activityClock.advance()
                continue
            }
            let pending: PendingRelease
            if let existing = pendingReleases[id], existing.token == record.token {
                pending = existing
            } else {
                let process = record.process
                let task = Task {
                    try await process.terminateFreshTerminal(
                        graceNanoseconds: Limits.releaseGraceNanoseconds
                    )
                }
                pending = PendingRelease(token: record.token, task: task)
                pendingReleases[id] = pending
            }
            do {
                try await pending.task.value
                if records[id]?.token == record.token {
                    records.removeValue(forKey: id)
                    activityClock.advance()
                }
            } catch {
                failed.append(id)
            }
            if pendingReleases[id]?.token == record.token {
                pendingReleases.removeValue(forKey: id)
            }
        }
        guard failed.isEmpty else {
            throw FreshTerminalStoreError.shutdownIncomplete(ids: failed.sorted())
        }
    }

    private func liveAuthorizedRecord(
        client: BrokerAuthenticatedClient,
        identity: FreshTerminalIdentity
    ) throws -> Record {
        let owner = try validatedOwner(
            client: client,
            ownerID: identity.ownerID,
            projectID: identity.projectID
        )
        try validateTerminalID(identity.id)
        guard let record = records[identity.id] else {
            throw FreshTerminalStoreError.terminalNotFound
        }
        guard record.projectID == identity.projectID, record.owner == owner else {
            throw FreshTerminalStoreError.terminalAccessDenied
        }
        guard pendingReleases[identity.id] == nil else {
            throw FreshTerminalStoreError.terminalReleaseInProgress
        }
        guard !record.exited else { throw FreshTerminalStoreError.terminalEnded }
        return record
    }

    private func validatedOwner(
        client: BrokerAuthenticatedClient,
        ownerID: String,
        projectID: String
    ) throws -> String {
        guard client.role == .controller else {
            throw FreshTerminalStoreError.controllerRequired
        }
        guard let uuid = UUID(uuidString: client.instanceID),
              uuid.uuidString.lowercased() == client.instanceID else {
            throw FreshTerminalStoreError.invalidClientIdentity
        }
        guard ownerID != "0", matches(ownerID, pattern: #"^[a-zA-Z0-9_-]{1,80}$"#) else {
            throw FreshTerminalStoreError.invalidOwner
        }
        guard matches(projectID, pattern: #"^[a-zA-Z0-9_.:-]{1,160}$"#) else {
            throw FreshTerminalStoreError.invalidProject
        }
        return "\(client.instanceID)|\(ownerID)|\(projectID)"
    }

    private func validateTerminalID(_ id: String) throws {
        guard !id.isEmpty,
              id.count <= Limits.maximumTerminalIDCharacters,
              !id.contains("\0") else {
            throw FreshTerminalStoreError.invalidTerminalID
        }
    }

    private func validateCreatePayload(_ request: FreshTerminalCreateRequest) throws {
        let commandBytes = request.command.utf8.count
        guard !request.command.isEmpty,
              !request.command.contains("\0"),
              commandBytes <= Limits.maximumCommandBytes else {
            throw FreshTerminalStoreError.invalidCommand
        }
        guard request.cwd.hasPrefix("/"),
              !request.cwd.contains("\0"),
              request.cwd.utf8.count <= Limits.maximumCWDBytes else {
            throw FreshTerminalStoreError.invalidCWD
        }
        guard request.args.count <= Limits.maximumArgumentCount else {
            throw FreshTerminalStoreError.invalidArguments
        }
        var argumentBytes = 0
        for argument in request.args {
            let bytes = argument.utf8.count
            guard !argument.contains("\0"), bytes <= Limits.maximumArgumentBytes else {
                throw FreshTerminalStoreError.invalidArguments
            }
            argumentBytes += bytes
            guard argumentBytes <= Limits.maximumArgumentsBytes else {
                throw FreshTerminalStoreError.invalidArguments
            }
        }
        guard request.env.count <= Limits.maximumEnvironmentEntries else {
            throw FreshTerminalStoreError.invalidEnvironment
        }
        var environmentBytes = 0
        for (key, value) in request.env {
            let keyBytes = key.utf8.count
            let valueBytes = value.utf8.count
            guard !key.isEmpty,
                  !key.contains("="),
                  !key.contains("\0"),
                  !value.contains("\0"),
                  keyBytes <= Limits.maximumEnvironmentKeyBytes,
                  valueBytes <= Limits.maximumEnvironmentValueBytes else {
                throw FreshTerminalStoreError.invalidEnvironment
            }
            environmentBytes += keyBytes + valueBytes
            guard environmentBytes <= Limits.maximumEnvironmentBytes else {
                throw FreshTerminalStoreError.invalidEnvironment
            }
        }
        _ = try validatedGeometry(cols: request.cols, rows: request.rows)
    }

    private func validatedGeometry(cols: Int, rows: Int) throws -> (cols: Int, rows: Int) {
        guard cols > 0 else {
            throw FreshTerminalStoreError.invalidGeometry(field: "cols")
        }
        guard rows > 0 else {
            throw FreshTerminalStoreError.invalidGeometry(field: "rows")
        }
        return (
            min(cols, Limits.maximumGeometry),
            min(rows, Limits.maximumGeometry)
        )
    }

    private func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// Pure by design: it runs inside `armPrimary`'s critical section, where
    /// reaching back into the accumulator would deadlock its non-reentrant
    /// lock — the snapshot must arrive as an argument.
    private static func creation(
        record: Record,
        existed: Bool,
        snapshot: FreshTerminalSnapshot
    ) -> FreshTerminalCreation {
        FreshTerminalCreation(
            id: record.id,
            pid: record.process.pid,
            existed: existed,
            streamEpoch: snapshot.streamEpoch,
            output: snapshot.output,
            startOffset: snapshot.startOffset,
            endOffset: snapshot.endOffset,
            truncated: snapshot.truncated,
            exited: snapshot.exited,
            cwd: record.cwd,
            cols: record.cols,
            rows: record.rows
        )
    }

    private func markExited(
        terminalID: String,
        token: UUID,
        status: FreshTerminalExitStatus?
    ) {
        guard var record = records[terminalID], record.token == token else { return }
        // Final repaired output, then the exit event, in one critical section:
        // no subscriber may observe the exit ahead of the bytes that ended it.
        record.output.finishAndPublishExit(status: status)
        exitSequence &+= 1
        record.exited = true
        record.exitSequence = exitSequence
        records[terminalID] = record
        evictOldExitedRecordsIfNeeded()
        activityClock.advance()
    }

    private func removePendingCreate(id: String, token: UUID) {
        guard let pending = pendingCreates[id], pending.token == token else { return }
        pendingCreates.removeValue(forKey: id)
        for waiter in pending.waiters {
            waiter.resume()
        }
    }

    private func evictOldExitedRecordsIfNeeded() {
        let exited = records.values
            .filter(\.exited)
            .sorted {
                let lhsSequence = $0.exitSequence ?? UInt64.max
                let rhsSequence = $1.exitSequence ?? UInt64.max
                if lhsSequence != rhsSequence {
                    return lhsSequence < rhsSequence
                }
                return $0.id < $1.id
            }
        let excess = exited.count - Limits.maximumRetainedExitedTerminals
        guard excess > 0 else { return }
        for record in exited.prefix(excess) {
            guard pendingReleases[record.id] == nil else { continue }
            records.removeValue(forKey: record.id)
        }
    }
}

/// Holds the one sink through which every event leaves the store. A plain
/// lock-protected box rather than actor state: deliveries run synchronously on
/// PTY read threads inside each terminal's output critical section.
final class FreshTerminalEventSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: FreshTerminalEventSink?

    func set(_ sink: FreshTerminalEventSink?) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    func deliver(
        owner: String,
        channel: String,
        payload: BrokerJSONValue,
        maxQueueBytes: Int?,
        force: Bool
    ) -> Bool {
        lock.lock()
        let current = sink
        lock.unlock()
        guard let current else { return false }
        return current(owner, channel, payload, maxQueueBytes, force)
    }
}

/// Owns one terminal's output intake AND its observer fan-out. A single lock
/// serializes appends, subscription registration, snapshots, exit publication,
/// and history reads — which is exactly what guarantees a subscribe reply and
/// the first live event are gapless under concurrent PTY output.
private final class FreshTerminalOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let activityClock: FreshTerminalActivityClock
    private let eventSink: FreshTerminalEventSinkBox
    private let terminalID: String
    private var buffer: TerminalOutputBuffer
    private var observers: TerminalOutputObservers
    private var exitStatus: FreshTerminalExitStatus?
    private var exitPublished = false
    // The primary `terminal:data:<id>` copy for the owner connection, present
    // for protocol-2 clients that never negotiated observer-only-output. Same
    // pause discipline as observers: one forced snapshot-required marker, then
    // silence until adoption replays a snapshot and re-arms the stream.
    private var primaryOwner: String?
    private var primaryEnabled = true
    private var primaryPaused = false

    // Mirrors the Node broker's history clamps: at most one 4 MiB page
    // (TERMINAL_HISTORY_PAGE_BYTES), never smaller than a useful 64 KiB read.
    private static let historyPageByteLimit = 4 * 1_024 * 1_024
    private static let historyPageByteFloor = 64 * 1_024

    init(
        terminalID: String,
        streamEpoch: String,
        tailByteLimit: Int,
        activityClock: FreshTerminalActivityClock,
        eventSink: FreshTerminalEventSinkBox
    ) throws {
        self.terminalID = terminalID
        self.activityClock = activityClock
        self.eventSink = eventSink
        observers = TerminalOutputObservers(terminalID: terminalID)
        buffer = try TerminalOutputBuffer(
            streamEpoch: streamEpoch,
            tailByteLimit: tailByteLimit
        )
    }

    func append(_ data: Data) {
        activityClock.withCriticalSection { epoch in
            lock.lock()
            defer { lock.unlock() }
            guard let drain = try? buffer.append(data) else { return }
            epoch = FreshTerminalActivityClock.advanced(epoch)
            if let emission = drain.emission {
                publishLocked(emission)
            }
        }
    }

    /// Flushes trailing repaired bytes, then publishes exit — in that order
    /// and inside one critical section, so no reader sees the exit ahead of
    /// the output that ended the stream. Idempotent.
    func finishAndPublishExit(status: FreshTerminalExitStatus?) {
        lock.lock()
        defer { lock.unlock() }
        if let status { exitStatus = status }
        if let drain = try? buffer.finish(), let emission = drain.emission {
            publishLocked(emission)
        }
        guard !exitPublished else { return }
        exitPublished = true
        let snapshot = buffer.snapshot()
        let statusValue = Self.exitStatusValue(exitStatus)
        _ = observers.broadcast(
            channel: "terminal:observer-exit",
            payload: .object([
                "id": .string(terminalID),
                "streamEpoch": .string(snapshot.streamEpoch),
                "offset": .integer(snapshot.endOffset),
                "exitStatus": statusValue,
            ]),
            cursor: TerminalObserverCursor(
                streamEpoch: snapshot.streamEpoch,
                endOffset: snapshot.endOffset
            ),
            deliver: deliverLocked
        )
        // The primary exit copy goes to the owner unconditionally — the
        // observer-only-output feature suppresses `terminal:data`, never exit.
        // The service downgrades the payload per the owner's negotiation.
        if let owner = primaryOwner {
            _ = eventSink.deliver(
                owner: owner,
                channel: "terminal:exit:\(terminalID)",
                payload: statusValue,
                maxQueueBytes: nil,
                force: false
            )
        }
    }

    func snapshot() -> TerminalOutputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return buffer.snapshot()
    }

    func currentExitStatus() -> FreshTerminalExitStatus? {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus
    }

    /// Registration and the reply are one atomic step against `append`: the
    /// reply's end offset is exactly where this subscriber's live events
    /// begin. `respond` must therefore publish to the subscriber's connection
    /// (or capture the value) synchronously.
    func subscribe(
        subscriber: String,
        maxQueueBytes: Int64?,
        streamEpoch: String?,
        afterOffset: Int64?,
        respond: (FreshTerminalSubscribeReply) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try observers.subscribe(owner: subscriber, maxQueueBytes: maxQueueBytes)
        } catch TerminalObserverRegistryError.invalidSubscriber {
            throw FreshTerminalStoreError.invalidObserverSubscriber
        } catch let TerminalObserverRegistryError.observerLimitReached(maximum) {
            throw FreshTerminalStoreError.observerLimitReached(maximum: maximum)
        }
        respond(classifyResumeLocked(streamEpoch: streamEpoch, afterOffset: afterOffset))
    }

    func unsubscribe(subscriber: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observers.unsubscribe(owner: subscriber)
    }

    @discardableResult
    func unsubscribe(prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return observers.unsubscribe(prefix: prefix)
    }

    /// The create/adoption analog of `subscribe`: the reply snapshot and the
    /// primary arming are one atomic step against `append`. `respond` runs
    /// exactly once, synchronously, before arming — a connection enqueueing
    /// the create response there puts it on the wire ahead of the first
    /// `terminal:data` event, and the snapshot's end offset is exactly where
    /// that stream begins. Also clears any slow-consumer pause, because the
    /// reply replays the snapshot the pause demanded.
    func armPrimary<Reply>(
        owner: String,
        enabled: Bool,
        respond: (FreshTerminalSnapshot) -> Reply
    ) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        let reply = respond(freshSnapshotLocked())
        primaryOwner = owner
        primaryEnabled = enabled
        primaryPaused = false
        return reply
    }

    func historyPage(
        streamEpoch: String?,
        beforeOffset: Int64?,
        maxBytes: Int64?
    ) throws -> FreshTerminalHistoryPage {
        lock.lock()
        defer { lock.unlock() }
        guard streamEpoch == buffer.streamEpoch else {
            throw FreshTerminalStoreError.historyEpochMismatch
        }
        let requested = maxBytes ?? Int64(Self.historyPageByteLimit)
        let cap = Int(min(
            Int64(Self.historyPageByteLimit),
            max(Int64(Self.historyPageByteFloor), requested)
        ))
        guard let beforeOffset,
              let slice = buffer.historySlice(before: beforeOffset, maximumBytes: cap) else {
            throw FreshTerminalStoreError.invalidHistoryOffset
        }
        return FreshTerminalHistoryPage(
            streamEpoch: buffer.streamEpoch,
            output: slice.output,
            startOffset: slice.startOffset,
            endOffset: slice.endOffset,
            hasMore: slice.hasMore,
            truncated: slice.truncated
        )
    }

    /// Port of the Node broker's `resumeFromSnapshot`: the caller's cursor is
    /// classified against the retained tail, answering the smallest snapshot
    /// that provably reconnects the stream — or the exact reset reason.
    private func classifyResumeLocked(
        streamEpoch: String?,
        afterOffset: Int64?
    ) -> FreshTerminalSubscribeReply {
        let current = freshSnapshotLocked()
        guard let streamEpoch, let afterOffset else {
            return .snapshot(current, resetReason: nil)
        }
        guard streamEpoch == current.streamEpoch else {
            return .snapshot(current, resetReason: "epoch_mismatch")
        }
        guard afterOffset <= current.endOffset else {
            return .snapshot(current, resetReason: "cursor_ahead")
        }
        guard afterOffset >= current.startOffset else {
            return .snapshot(current, resetReason: "event_gap")
        }
        if afterOffset == current.endOffset {
            return .current(streamEpoch: current.streamEpoch, offset: afterOffset)
        }
        let bytes = Data(current.output.utf8)
        let relative = Int(afterOffset - current.startOffset)
        guard relative == 0 || bytes[relative] & 0xC0 != 0x80 else {
            return .snapshot(current, resetReason: "invalid_utf8_boundary")
        }
        return .snapshot(
            FreshTerminalSnapshot(
                streamEpoch: current.streamEpoch,
                output: String(decoding: bytes[relative...], as: UTF8.self),
                startOffset: afterOffset,
                endOffset: current.endOffset,
                truncated: current.truncated || afterOffset > 0,
                exited: current.exited,
                exitStatus: current.exitStatus
            ),
            resetReason: nil
        )
    }

    private func freshSnapshotLocked() -> FreshTerminalSnapshot {
        let snapshot = buffer.snapshot()
        return FreshTerminalSnapshot(
            streamEpoch: snapshot.streamEpoch,
            output: snapshot.output,
            startOffset: snapshot.startOffset,
            endOffset: snapshot.endOffset,
            truncated: snapshot.truncated,
            exited: snapshot.state == .final,
            exitStatus: exitStatus
        )
    }

    /// Broadcast happens inside the intake lock so per-terminal event order is
    /// the append order, always. Pieces stay under the Node broker's 64 KiB
    /// observer chunk so worst-case JSON escaping fits the encoded frame cap.
    private func publishLocked(_ emission: TerminalOutputEmission) {
        for piece in emission.splitForObserverFrames() {
            _ = observers.broadcast(
                channel: "terminal:observer-output",
                payload: .object([
                    "id": .string(terminalID),
                    "streamEpoch": .string(piece.streamEpoch),
                    "startOffset": .integer(piece.startOffset),
                    "endOffset": .integer(piece.endOffset),
                    "data": .string(piece.output),
                ]),
                cursor: TerminalObserverCursor(
                    streamEpoch: piece.streamEpoch,
                    endOffset: piece.endOffset
                ),
                deliver: deliverLocked
            )
        }
        deliverPrimaryLocked(emission)
    }

    private func deliverLocked(
        owner: String,
        channel: String,
        payload: BrokerJSONValue,
        maxQueueBytes: Int?,
        force: Bool
    ) -> Bool {
        eventSink.deliver(
            owner: owner,
            channel: channel,
            payload: payload,
            maxQueueBytes: maxQueueBytes,
            force: force
        )
    }

    /// Node's `deliverPrimaryOutput`: a refused delta pauses the primary copy
    /// behind one forced `terminal:snapshot-required` marker; only an explicit
    /// adoption (the fresh analog of attach) resumes it with a fresh snapshot.
    /// Pieces stay under the primary chunk bound so a full 64 KiB PTY read is
    /// deliverable at all — unsplit it exceeds the ordinary event channel's
    /// encoded cap, and that deterministic refusal would masquerade here as a
    /// slow consumer and pause the stream for good.
    private func deliverPrimaryLocked(_ emission: TerminalOutputEmission) {
        guard let owner = primaryOwner, primaryEnabled, !primaryPaused else { return }
        for piece in emission.splitForPrimaryFrames() {
            let delivered = eventSink.deliver(
                owner: owner,
                channel: "terminal:data:\(terminalID)",
                payload: .string(piece.output),
                maxQueueBytes: TerminalOutputObservers.defaultQueueBytes,
                force: false
            )
            if delivered { continue }
            primaryPaused = true
            _ = eventSink.deliver(
                owner: owner,
                channel: "terminal:snapshot-required",
                payload: .object([
                    "id": .string(terminalID),
                    "reason": .string("slow_consumer"),
                    "streamEpoch": .string(emission.streamEpoch),
                    "endOffset": .integer(emission.endOffset),
                ]),
                maxQueueBytes: TerminalOutputObservers.defaultQueueBytes,
                force: true
            )
            return
        }
    }

    private static func exitStatusValue(
        _ status: FreshTerminalExitStatus?
    ) -> BrokerJSONValue {
        guard let status else { return .null }
        return .object([
            "exitCode": .integer(status.exitCode),
            "signal": status.signal.map(BrokerJSONValue.integer) ?? .null,
        ])
    }
}

private final class FreshTerminalActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: Int64 = 1

    @discardableResult
    func advance() -> Int64 {
        withCriticalSection { epoch in
            epoch = Self.advanced(epoch)
            return epoch
        }
    }

    func current() -> Int64 {
        withCriticalSection { $0 }
    }

    func withCriticalSection<T>(_ body: (inout Int64) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&epoch)
    }

    static func advanced(_ epoch: Int64) -> Int64 {
        epoch == Int64.max ? 1 : epoch + 1
    }
}
