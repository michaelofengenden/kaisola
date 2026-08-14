import Foundation

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

public struct FreshTerminalCreation: Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let existed: Bool
    public let streamEpoch: String
    public let endOffset: Int64
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

    public init(
        streamEpoch: String,
        output: String,
        startOffset: Int64,
        endOffset: Int64,
        truncated: Bool,
        exited: Bool
    ) {
        self.streamEpoch = streamEpoch
        self.output = output
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.truncated = truncated
        self.exited = exited
    }
}

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
        }
    }
}

public actor FreshTerminalStore {
    private enum Limits {
        static let maximumLiveTerminals = 64
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
    private let activityClock = FreshTerminalActivityClock()
    private var records: [String: Record] = [:]
    private var pendingCreates: [String: PendingCreate] = [:]
    private var pendingReleases: [String: PendingRelease] = [:]
    private var isShuttingDown = false
    private var exitSequence: UInt64 = 0

    public init(factory: any FreshTerminalProcessFactory) {
        self.factory = factory
    }

    public func create(
        client: BrokerAuthenticatedClient,
        request: FreshTerminalCreateRequest
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
                activityClock.advance()
                return creation(from: record, existed: true)
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
        guard liveCount + pendingCreates.count < Limits.maximumLiveTerminals else {
            throw FreshTerminalStoreError.capacityExceeded(
                maximum: Limits.maximumLiveTerminals
            )
        }

        let geometry = try validatedGeometry(cols: request.cols, rows: request.rows)
        let token = UUID()
        let streamEpoch = UUID().uuidString.lowercased()
        let output: FreshTerminalOutputAccumulator
        do {
            output = try FreshTerminalOutputAccumulator(
                streamEpoch: streamEpoch,
                tailByteLimit: Limits.outputTailBytes,
                activityClock: activityClock
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
            await self?.markExited(terminalID: request.id, token: token)
        }
        removePendingCreate(id: request.id, token: token)
        if isShuttingDown {
            throw FreshTerminalStoreError.shuttingDown
        }
        if pending.cancellationRequested {
            throw FreshTerminalStoreError.terminalReleaseInProgress
        }
        return creation(from: record, existed: false)
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
            exited: record.exited
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

    private func creation(from record: Record, existed: Bool) -> FreshTerminalCreation {
        let snapshot = record.output.snapshot()
        return FreshTerminalCreation(
            id: record.id,
            pid: record.process.pid,
            existed: existed,
            streamEpoch: snapshot.streamEpoch,
            endOffset: snapshot.endOffset,
            cwd: record.cwd,
            cols: record.cols,
            rows: record.rows
        )
    }

    private func markExited(terminalID: String, token: UUID) {
        guard var record = records[terminalID], record.token == token else { return }
        record.output.finish()
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

private final class FreshTerminalOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let activityClock: FreshTerminalActivityClock
    private var buffer: TerminalOutputBuffer

    init(
        streamEpoch: String,
        tailByteLimit: Int,
        activityClock: FreshTerminalActivityClock
    ) throws {
        self.activityClock = activityClock
        buffer = try TerminalOutputBuffer(
            streamEpoch: streamEpoch,
            tailByteLimit: tailByteLimit
        )
    }

    func append(_ data: Data) {
        activityClock.withCriticalSection { epoch in
            lock.lock()
            defer { lock.unlock() }
            if (try? buffer.append(data).emission) != nil {
                epoch = FreshTerminalActivityClock.advanced(epoch)
            }
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        _ = try? buffer.finish()
    }

    func snapshot() -> TerminalOutputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return buffer.snapshot()
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
