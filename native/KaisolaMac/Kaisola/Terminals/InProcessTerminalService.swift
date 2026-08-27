import Darwin
import Foundation
import KaisolaBrokerProtocol
import KaisolaCore
import KaisolaSessionBrokerCore

/// The process-wide terminal engine that replaced the detached session broker.
///
/// One `FreshTerminalStore` owns every PTY as a direct child of this process;
/// every window's `AppModel` (and the Companion stream hub) talks to it through
/// its own `InProcessTerminalService` facade so per-window controller identity
/// keeps the exact ownership semantics the broker enforced across connections.
/// Terminals now live and die with the app: quitting Kaisola ends its shells.
final class InProcessTerminalCore: @unchecked Sendable {
    static let shared = InProcessTerminalCore()

    let store: FreshTerminalStore
    /// Milliseconds, mirroring the broker's `startedAt` identity field.
    let startedAt = Int64(Date().timeIntervalSince1970 * 1_000)

    private let lock = NSLock()
    private var handlers: [String: @Sendable (BrokerEvent) -> Void] = [:]
    private var agentActivity: [String: AgentActivity] = [:]
    private var controlLeases: Set<String> = []
    /// Adapter-side additions to the store's activity epoch. Agent-turn and
    /// lease changes must move the inventory fence exactly like the broker's
    /// did, or reconcile would not notice them.
    private var activityBoost: Int64 = 0

    init(factory: any FreshTerminalProcessFactory = DarwinPTYProcessFactory()) {
        store = FreshTerminalStore(factory: factory)
        store.setEventSink { [weak self] owner, channel, payload, _, _ in
            guard let self else { return false }
            self.route(owner: owner, channel: channel, payload: payload)
            // In-process delivery has no socket queue to overflow; refusing a
            // delivery would only pause the stream behind a snapshot marker.
            return true
        }
    }

    // MARK: - Facade registry

    func register(facadeID: String, handler: @escaping @Sendable (BrokerEvent) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        handlers[facadeID] = handler
    }

    func unregister(facadeID: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: facadeID)
    }

    // MARK: - Agent activity & leases

    func activity(for terminalID: String) -> AgentActivity {
        lock.lock()
        defer { lock.unlock() }
        return agentActivity[terminalID] ?? .idle
    }

    func setAgentTurn(ownerID: String, projectID: String, terminalID: String, busy: Bool) {
        let recipients: [@Sendable (BrokerEvent) -> Void]
        let completedAt: Int64?
        lock.lock()
        if busy {
            agentActivity[terminalID] = .working
            completedAt = nil
        } else {
            let at = Int64(Date().timeIntervalSince1970 * 1_000)
            agentActivity[terminalID] = .responded(at: at)
            completedAt = at
        }
        activityBoost += 1
        recipients = Array(handlers.values)
        lock.unlock()
        let event = BrokerEvent(
            ownerID: ownerID,
            projectID: projectID,
            terminalID: terminalID,
            kind: .activity(busy: busy, completedAt: completedAt)
        )
        for handler in recipients { handler(event) }
    }

    func setControlLease(terminalID: String, active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if active { controlLeases.insert(terminalID) } else { controlLeases.remove(terminalID) }
        activityBoost += 1
    }

    func forgetActivity(terminalID: String) {
        lock.lock()
        defer { lock.unlock() }
        agentActivity.removeValue(forKey: terminalID)
        controlLeases.remove(terminalID)
    }

    // MARK: - Inventory

    func inventoryStatus() async -> BrokerStatus {
        let snapshot = await store.atomicInventorySnapshot()
        let (activities, boost) = activityState()
        let terminals = snapshot.records.compactMap { record -> BrokerTerminalRecord? in
            terminalRecord(record, activity: activities[record.id] ?? .idle)
        }
        return BrokerStatus(
            terminals: terminals,
            activityEpoch: snapshot.activityEpoch + boost,
            terminalCapacity: nil
        )
    }

    func combinedActivityEpoch() async -> Int64 {
        let epoch = await store.currentActivityEpoch()
        return epoch + activityState().boost
    }

    private func activityState() -> (activities: [String: AgentActivity], boost: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (agentActivity, activityBoost)
    }

    private func terminalRecord(
        _ record: FreshTerminalInventoryRecord,
        activity: AgentActivity
    ) -> BrokerTerminalRecord? {
        // Store owner strings are exactly `instanceID|ownerID|projectID`.
        let owner = record.owner.split(separator: "|", omittingEmptySubsequences: false)
        let lastOwner = record.lastOwner.split(separator: "|", omittingEmptySubsequences: false)
        guard owner.count == 3 else { return nil }
        var terminal = BrokerTerminalRecord(
            id: record.id,
            projectID: String(owner[2]),
            pid: record.exited ? nil : record.pid,
            exited: record.exited,
            streamEpoch: record.streamEpoch,
            endOffset: record.endOffset,
            diskBytes: 0,
            columns: record.cols,
            rows: record.rows,
            currentOwnerID: String(owner[1]),
            lastOwnerID: lastOwner.count == 3 ? String(lastOwner[1]) : String(owner[1]),
            currentOwnerInstanceID: String(owner[0]),
            lastOwnerInstanceID: lastOwner.count == 3 ? String(lastOwner[0]) : String(owner[0]),
            agentActivity: activity
        )
        terminal.cwd = record.cwd
        return terminal
    }

    // MARK: - Event routing

    /// Sink deliveries arrive synchronously on PTY read threads. Observer
    /// subscriber keys are `facadeID|ownerID|projectID|terminalID`; primary
    /// owner strings are `facadeID|ownerID|projectID`. Primary copies are
    /// dropped: the native app consumes only the observer stream.
    private func route(owner: String, channel: String, payload: BrokerJSONValue) {
        let pieces = owner.split(separator: "|", omittingEmptySubsequences: false)
        guard pieces.count >= 3 else { return }
        let facadeID = String(pieces[0])
        let ownerID = String(pieces[1])
        let projectID = String(pieces[2])
        let subscribedTerminalID = pieces.count >= 4 ? String(pieces[3]) : nil

        let kind: BrokerEvent.Kind
        switch channel {
        case "terminal:observer-output":
            guard let object = payload.objectValue,
                  let epoch = object["streamEpoch"]?.stringValue,
                  let start = object["startOffset"]?.integerValue,
                  let end = object["endOffset"]?.integerValue,
                  let data = object["data"]?.stringValue else { return }
            kind = .output(epoch: epoch, startOffset: start, endOffset: end, data: data)
        case "terminal:observer-exit":
            kind = .exit
        case "terminal:observer-snapshot-required":
            kind = .snapshotRequired
        default:
            // `terminal:data:*`, `terminal:exit:*`, and the primary
            // snapshot-required marker have no in-process consumer.
            return
        }
        guard let terminalID = payload.objectValue?["id"]?.stringValue ?? subscribedTerminalID else {
            return
        }

        lock.lock()
        let handler = handlers[facadeID]
        lock.unlock()
        handler?(BrokerEvent(
            ownerID: ownerID,
            projectID: projectID,
            terminalID: terminalID,
            kind: kind
        ))
    }
}

/// One window's (or the Companion hub's) connection-equivalent onto the shared
/// in-process terminal core. Each facade keeps its own controller identity so
/// cross-window ownership, adoption, and takeover behave exactly as they did
/// across separate broker connections.
final class InProcessTerminalService: @unchecked Sendable {
    private let core: InProcessTerminalCore
    /// Lowercase UUID: the store requires this exact shape for controller
    /// identities, and reconcile compares it against inventory instance IDs.
    let facadeID = UUID().uuidString.lowercased()
    private let client: BrokerAuthenticatedClient

    private let lock = NSLock()
    private var controlOwnerID = "native"

    init(core: InProcessTerminalCore = .shared) {
        self.core = core
        client = BrokerAuthenticatedClient(
            instanceID: facadeID,
            role: .controller,
            negotiatedFeatures: BrokerWire.advertisedFeatures
        )
    }

    private func hello() -> BrokerHello {
        BrokerHello(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: nil,
            packageVersion: nil,
            features: Set(BrokerWire.advertisedFeatures),
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: core.startedAt,
            version: "in-process",
            serverEnforcedObserver: true
        )
    }

    private func identity(projectID: String, terminalID: String) -> FreshTerminalIdentity {
        FreshTerminalIdentity(ownerID: ownerID(), projectID: projectID, id: terminalID)
    }

    private func ownerID() -> String {
        lock.lock()
        defer { lock.unlock() }
        return controlOwnerID
    }

    private func subscriberKey(ownerID: String, terminal: BrokerTerminalRecord) -> String {
        "\(facadeID)|\(ownerID)|\(terminal.projectID)|\(terminal.id)"
    }

    private static func mapStoreError(_ error: any Error) -> any Error {
        guard let storeError = error as? FreshTerminalStoreError else { return error }
        switch storeError {
        case .terminalNotFound:
            return TerminalWriteError.missing
        case .terminalEnded:
            return TerminalWriteError.ended
        case let .capacityExceeded(maximum):
            return BrokerClientError.terminalCapacityExceeded(maximum: maximum)
        default:
            return BrokerClientError.requestFailed(storeError.errorDescription ?? "terminal request failed")
        }
    }
}

// MARK: - BrokerInfoPreparing / BrokerInfoLocating

extension InProcessTerminalService: BrokerInfoLocating {
    /// The Companion hub locates its terminal source before connecting; the
    /// in-process engine is always already here.
    func locate() throws -> BrokerInfo {
        syntheticInfo()
    }
}

extension InProcessTerminalService: BrokerInfoPreparing {
    func prepare() async throws -> BrokerInfo {
        syntheticInfo()
    }

    private func syntheticInfo() -> BrokerInfo {
        BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: nil,
            packageVersion: nil,
            pid: ProcessInfo.processInfo.processIdentifier,
            socketPath: "in-process",
            token: "in-process",
            startedAt: core.startedAt,
            version: "in-process"
        )
    }
}

// MARK: - ObserveOnlyBrokerServing

extension InProcessTerminalService: ObserveOnlyBrokerServing {
    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async {
        if let handler {
            core.register(facadeID: facadeID, handler: handler)
        } else {
            core.unregister(facadeID: facadeID)
        }
    }

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {
        // In-process connections cannot drop.
    }

    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        hello()
    }

    func inventory() async throws -> BrokerStatus {
        await core.inventoryStatus()
    }

    func inventoryActivityEpoch() async throws -> Int64? {
        await core.combinedActivityEpoch()
    }

    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        try await subscribeBounded(
            to: terminal,
            ownerID: ownerID,
            cursor: cursor,
            maximumSnapshotBytes: .max
        )
    }

    func subscribeBounded(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?,
        maximumSnapshotBytes: Int
    ) async throws -> TerminalSubscriptionResult {
        let reply = LockedReplyBox<FreshTerminalSubscribeReply>()
        do {
            try await core.store.subscribe(
                id: terminal.id,
                projectID: terminal.projectID,
                accessOwner: nil,
                subscriber: subscriberKey(ownerID: ownerID, terminal: terminal),
                streamEpoch: cursor?.streamEpoch,
                afterOffset: cursor?.offset,
                maxQueueBytes: nil,
                respond: { reply.set($0) }
            )
        } catch {
            throw Self.mapStoreError(error)
        }
        switch reply.take() {
        case .none, .unavailable:
            throw TerminalWriteError.missing
        case let .snapshot(snapshot, resetReason):
            let bounded = Self.bounded(snapshot, to: maximumSnapshotBytes)
            return .snapshot(
                TerminalSnapshot(
                    streamEpoch: bounded.streamEpoch,
                    output: bounded.output,
                    startOffset: bounded.startOffset,
                    endOffset: bounded.endOffset,
                    truncated: bounded.truncated,
                    exited: bounded.exited
                ),
                resetReason: resetReason
            )
        case let .current(streamEpoch, offset):
            return .current(TerminalCursor(streamEpoch: streamEpoch, offset: offset))
        }
    }

    func historyPage(
        for terminal: BrokerTerminalRecord,
        ownerID: String,
        streamEpoch: String,
        beforeOffset: Int64,
        maxBytes: Int
    ) async throws -> TerminalHistoryPage {
        let page: FreshTerminalHistoryPage?
        do {
            page = try await core.store.history(
                id: terminal.id,
                projectID: terminal.projectID,
                accessOwner: nil,
                streamEpoch: streamEpoch,
                beforeOffset: beforeOffset,
                maxBytes: Int64(maxBytes)
            )
        } catch {
            throw Self.mapStoreError(error)
        }
        guard let page else { throw TerminalWriteError.missing }
        return TerminalHistoryPage(
            streamEpoch: page.streamEpoch,
            output: page.output,
            startOffset: page.startOffset,
            endOffset: page.endOffset,
            hasMore: page.hasMore,
            truncated: page.truncated
        )
    }

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {
        _ = try? await core.store.unsubscribe(
            id: terminal.id,
            projectID: terminal.projectID,
            accessOwner: nil,
            subscriber: subscriberKey(ownerID: ownerID, terminal: terminal)
        )
    }

    func disconnect() async {
        core.unregister(facadeID: facadeID)
        await core.store.unsubscribeSubscriberPrefix("\(facadeID)|")
    }

    /// Keeps the whole retained tail when it fits; otherwise keeps the newest
    /// bytes up to the bound, advancing the start to a UTF-8 boundary so the
    /// byte-accounting invariant (`utf8.count == end - start`) still holds.
    private static func bounded(
        _ snapshot: FreshTerminalSnapshot,
        to maximumBytes: Int
    ) -> FreshTerminalSnapshot {
        let bytes = Array(snapshot.output.utf8)
        guard maximumBytes > 0, bytes.count > maximumBytes else { return snapshot }
        var cut = bytes.count - maximumBytes
        while cut < bytes.count, bytes[cut] & 0xC0 == 0x80 { cut += 1 }
        let output = String(decoding: bytes[cut...], as: UTF8.self)
        return FreshTerminalSnapshot(
            streamEpoch: snapshot.streamEpoch,
            output: output,
            startOffset: snapshot.startOffset + Int64(cut),
            endOffset: snapshot.endOffset,
            truncated: true,
            exited: snapshot.exited,
            exitStatus: snapshot.exitStatus
        )
    }
}

// MARK: - BrokerControlServing

extension InProcessTerminalService: BrokerControlServing {
    var connectionInstanceID: String { facadeID }

    func connect(to info: BrokerInfo, ownerID: String) async throws {
        setControlOwnerID(ownerID)
    }

    private func setControlOwnerID(_ ownerID: String) {
        lock.lock()
        defer { lock.unlock() }
        controlOwnerID = ownerID
    }

    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int,
        restore: Bool
    ) async throws -> TerminalCreation {
        // Restore asks the broker to serve a prior spool without spawning.
        // In-process there is no outlived spool, so it degrades to a fresh
        // spawn — the same terminal id simply starts a new shell.
        let creation: FreshTerminalCreation
        do {
            creation = try await core.store.create(
                client: client,
                request: FreshTerminalCreateRequest(
                    ownerID: ownerID(),
                    projectID: projectID,
                    id: terminalID,
                    command: command,
                    args: arguments,
                    cwd: cwd,
                    env: Self.cleanTerminalEnvironment,
                    cols: columns,
                    rows: rows,
                    restore: false
                ),
                primaryStreamEnabled: false
            )
        } catch {
            throw Self.mapStoreError(error)
        }
        return TerminalCreation(
            terminalID: creation.id,
            projectID: projectID,
            pid: creation.exited ? nil : creation.pid,
            exited: creation.exited,
            streamEpoch: creation.streamEpoch,
            recovered: nil
        )
    }

    func attach(projectID: String, terminalID: String) async throws {
        do {
            try await core.store.adopt(
                client: client,
                identity: identity(projectID: projectID, terminalID: terminalID)
            )
        } catch {
            throw Self.mapStoreError(error)
        }
    }

    func write(projectID: String, terminalID: String, data: String) async throws {
        do {
            try await core.store.write(
                client: client,
                identity: identity(projectID: projectID, terminalID: terminalID),
                data: data
            )
        } catch {
            throw Self.mapStoreError(error)
        }
    }

    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws {
        do {
            try await core.store.resize(
                client: client,
                identity: identity(projectID: projectID, terminalID: terminalID),
                cols: columns,
                rows: rows
            )
        } catch {
            throw Self.mapStoreError(error)
        }
    }

    func kill(projectID: String, terminalID: String) async throws {
        do {
            try await core.store.kill(
                client: client,
                identity: identity(projectID: projectID, terminalID: terminalID)
            )
        } catch {
            throw Self.mapStoreError(error)
        }
    }

    func release(projectID: String, terminalID: String) async throws {
        _ = try await release(projectID: projectID, terminalID: terminalID, brokerGenerationID: nil)
    }

    func release(
        projectID: String,
        terminalID: String,
        brokerGenerationID: String?
    ) async throws -> BrokerTerminalReleaseDisposition {
        let release: FreshTerminalRelease
        do {
            release = try await core.store.release(
                client: client,
                identity: identity(projectID: projectID, terminalID: terminalID)
            )
        } catch {
            throw Self.mapStoreError(error)
        }
        core.forgetActivity(terminalID: terminalID)
        return release.alreadyAbsent ? .terminalAbsent : .released
    }

    func detachOwner(projectID: String, terminalID: String) async throws {
        // Ownership handoff previously kept a PTY alive past its window on the
        // detached broker. In-process, the terminal lives with the app either
        // way; another window adopts it through `attach`.
    }

    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws {
        core.setAgentTurn(
            ownerID: ownerID(),
            projectID: projectID,
            terminalID: terminalID,
            busy: busy
        )
    }

    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws {
        core.setControlLease(terminalID: terminalID, active: active)
    }

    func detachGenerations(_ generationIDs: Set<String>) async {
        // No generations exist in-process.
    }
}

// MARK: - CompanionTerminalBrokerServing

extension InProcessTerminalService: CompanionTerminalBrokerServing {}

/// Same call-completion box the observer client used: `respond` runs
/// synchronously inside the store's critical section, before `subscribe`
/// returns, so a plain lock-protected slot is enough to carry the reply out.
private final class LockedReplyBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

extension InProcessTerminalService {
    /// The compatibility values the control client historically placed on the
    /// wire; `DarwinPTYProcessFactory` layers them over its clean inherited
    /// boundary exactly as the broker's terminal manager did.
    static let cleanTerminalEnvironment: [String: String] = [
        "PROMPT_EOL_MARK": "",
        "NO_COLOR": "",
        "FORCE_COLOR": "1",
        "CODEX_CI": "",
        "CODEX_MANAGED_BY_NPM": "",
        "CODEX_MANAGED_PACKAGE_ROOT": "",
        "CODEX_THREAD_ID": "",
    ]
}
