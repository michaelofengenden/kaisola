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
    /// Where each observer subscription lives. Activity broadcasts go to these
    /// identities, exactly as the broker delivered its observer-activity frames
    /// per subscription — the app authenticates events against its observer
    /// owner, so a copy addressed with the control owner would be dropped.
    private var observers: [String: [ObserverIdentity]] = [:]
    /// The spawn request carries no terminal identity, so the output tap keys
    /// chunks by pid; the facade registers the pairing when `create` returns.
    private var terminalsByPid: [Int32: String] = [:]
    private var openTurns: [String: OpenAgentTurn] = [:]
    /// Monotonic across all turns, so a quiet task armed for a settled turn
    /// can never mistake a successor turn on the same terminal for its own.
    private var quietGenerationCounter = 0
    /// The broker's AGENT_QUIET_MS. Injectable so tests need not wait 4.5s.
    private let agentQuietInterval: TimeInterval

    struct ObserverIdentity: Equatable, Sendable {
        let facadeID: String
        let ownerID: String
        let projectID: String
    }

    /// Mirror of the broker's per-record turn fields. `completedAt` is set by
    /// the quiet fallback; a later command-end mark confirms the turn without
    /// moving the timestamp the UI already shows.
    private struct OpenAgentTurn {
        var busy = true
        var completedAt: Int64?
        /// Straddle buffer so an OSC 133;D mark split across pty reads still
        /// matches. Maintained only while the turn is open.
        var markCarry: [UInt8] = []
        var lastOutputAt = Date()
        var quietGeneration = 0
    }

    /// The shell's end-of-command mark (OSC 133;D). The only sequence trusted
    /// beyond quietness to close an agent turn: the foreground command the
    /// turn was opened for has returned to the prompt.
    private static let commandEndMark: [UInt8] = Array("\u{1B}]133;D".utf8)

    init(
        factory: any FreshTerminalProcessFactory = DarwinPTYProcessFactory(),
        agentQuietInterval: TimeInterval = 4.5
    ) {
        self.agentQuietInterval = agentQuietInterval
        let relay = OutputTapRelay()
        store = FreshTerminalStore(factory: AgentMarkTappingFactory(base: factory, relay: relay))
        relay.core = self
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

    // MARK: - Observer & spawn registries

    func noteObserver(facadeID: String, ownerID: String, projectID: String, terminalID: String) {
        let identity = ObserverIdentity(facadeID: facadeID, ownerID: ownerID, projectID: projectID)
        lock.lock()
        defer { lock.unlock() }
        var list = observers[terminalID] ?? []
        guard !list.contains(identity) else { return }
        list.append(identity)
        observers[terminalID] = list
    }

    func removeObserver(facadeID: String, ownerID: String, terminalID: String) {
        lock.lock()
        defer { lock.unlock() }
        observers[terminalID]?.removeAll { $0.facadeID == facadeID && $0.ownerID == ownerID }
        if observers[terminalID]?.isEmpty == true { observers.removeValue(forKey: terminalID) }
    }

    func removeObservers(facadeID: String) {
        lock.lock()
        defer { lock.unlock() }
        for (terminalID, list) in observers {
            let kept = list.filter { $0.facadeID != facadeID }
            if kept.isEmpty {
                observers.removeValue(forKey: terminalID)
            } else {
                observers[terminalID] = kept
            }
        }
    }

    func registerSpawn(pid: Int32, terminalID: String) {
        lock.lock()
        defer { lock.unlock() }
        terminalsByPid[pid] = terminalID
    }

    // MARK: - Agent activity & leases

    func activity(for terminalID: String) -> AgentActivity {
        lock.lock()
        defer { lock.unlock() }
        return agentActivity[terminalID] ?? .idle
    }

    func setAgentTurn(ownerID: String, projectID: String, terminalID: String, busy: Bool) {
        guard busy else {
            settleAgentTurn(terminalID: terminalID)
            return
        }
        lock.lock()
        quietGenerationCounter += 1
        var turn = OpenAgentTurn()
        turn.quietGeneration = quietGenerationCounter
        openTurns[terminalID] = turn
        agentActivity[terminalID] = .working
        activityBoost += 1
        let recipients = activityRecipients(terminalID: terminalID)
        armAgentQuiet(terminalID: terminalID, generation: turn.quietGeneration, after: agentQuietInterval)
        lock.unlock()
        broadcast(recipients, terminalID: terminalID, busy: true, completedAt: nil)
    }

    /// The authoritative end of a turn: the controller's `busy: false`, the
    /// pty exiting, or the shell's own command-end mark. Quietness never
    /// gets here — it only relaxes the spinner while the turn stays open.
    private func settleAgentTurn(terminalID: String) {
        lock.lock()
        let turn = openTurns.removeValue(forKey: terminalID)
        let working = { if case .working = agentActivity[terminalID] { return true }; return false }()
        guard turn != nil || working else {
            lock.unlock()
            return
        }
        let at = turn?.completedAt ?? Int64(Date().timeIntervalSince1970 * 1_000)
        agentActivity[terminalID] = .responded(at: at)
        activityBoost += 1
        let recipients = activityRecipients(terminalID: terminalID)
        lock.unlock()
        broadcast(recipients, terminalID: terminalID, busy: false, completedAt: at)
    }

    /// Degraded fallback for agents that never emit an end-of-turn signal:
    /// after the quiet interval the busy indicator relaxes so the UI stops
    /// claiming live work, but the turn stays open and a later mark confirms
    /// it without moving this timestamp.
    private func relaxQuietAgentTurn(terminalID: String, generation: Int) {
        lock.lock()
        guard var turn = openTurns[terminalID], turn.busy, turn.quietGeneration == generation else {
            lock.unlock()
            return
        }
        let elapsed = Date().timeIntervalSince(turn.lastOutputAt)
        guard elapsed >= agentQuietInterval else {
            armAgentQuiet(
                terminalID: terminalID,
                generation: generation,
                after: agentQuietInterval - elapsed
            )
            lock.unlock()
            return
        }
        let at = Int64(Date().timeIntervalSince1970 * 1_000)
        turn.busy = false
        turn.completedAt = at
        openTurns[terminalID] = turn
        agentActivity[terminalID] = .responded(at: at)
        activityBoost += 1
        let recipients = activityRecipients(terminalID: terminalID)
        lock.unlock()
        broadcast(recipients, terminalID: terminalID, busy: false, completedAt: at)
    }

    /// Caller holds the lock.
    private func armAgentQuiet(terminalID: String, generation: Int, after interval: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            self?.relaxQuietAgentTurn(terminalID: terminalID, generation: generation)
        }
    }

    /// Caller holds the lock. Activity frames go per observer subscription
    /// with that observer's own identity; a terminal nobody watches settles
    /// silently and reconcile paints it from inventory.
    private func activityRecipients(
        terminalID: String
    ) -> [(handler: @Sendable (BrokerEvent) -> Void, identity: ObserverIdentity)] {
        (observers[terminalID] ?? []).compactMap { identity in
            handlers[identity.facadeID].map { ($0, identity) }
        }
    }

    private func broadcast(
        _ recipients: [(handler: @Sendable (BrokerEvent) -> Void, identity: ObserverIdentity)],
        terminalID: String,
        busy: Bool,
        completedAt: Int64?
    ) {
        for (handler, identity) in recipients {
            handler(BrokerEvent(
                ownerID: identity.ownerID,
                projectID: identity.projectID,
                terminalID: terminalID,
                kind: .activity(busy: busy, completedAt: completedAt)
            ))
        }
    }

    /// Every pty read passes here once, keyed by pid. Only open turns pay for
    /// the scan; bytes outside a turn (including the spawn banner racing the
    /// pid registration) carry no mark worth finding.
    fileprivate func observeChunk(pid: Int32, data: Data) {
        lock.lock()
        guard let terminalID = terminalsByPid[pid], var turn = openTurns[terminalID] else {
            lock.unlock()
            return
        }
        turn.lastOutputAt = Date()
        var window = turn.markCarry
        window.append(contentsOf: data)
        let ended = Self.containsCommandEndMark(window)
        turn.markCarry = Array(window.suffix(Self.commandEndMark.count - 1))
        openTurns[terminalID] = turn
        lock.unlock()
        if ended { settleAgentTurn(terminalID: terminalID) }
    }

    private static func containsCommandEndMark(_ window: [UInt8]) -> Bool {
        let mark = commandEndMark
        guard window.count >= mark.count else { return false }
        for start in 0...(window.count - mark.count) {
            var offset = 0
            while offset < mark.count, window[start + offset] == mark[offset] { offset += 1 }
            if offset == mark.count { return true }
        }
        return false
    }

    private func noteTerminalExit(terminalID: String) {
        lock.lock()
        for (pid, id) in terminalsByPid where id == terminalID {
            terminalsByPid.removeValue(forKey: pid)
        }
        lock.unlock()
        settleAgentTurn(terminalID: terminalID)
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
        openTurns.removeValue(forKey: terminalID)
        observers.removeValue(forKey: terminalID)
        for (pid, id) in terminalsByPid where id == terminalID {
            terminalsByPid.removeValue(forKey: pid)
        }
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
        // The primary exit copy fires exactly once per terminal even with the
        // primary data stream disarmed, which makes it the engine's own settle
        // signal: a dying pty ends whatever agent turn it was running.
        if channel.hasPrefix("terminal:exit:") {
            noteTerminalExit(terminalID: String(channel.dropFirst("terminal:exit:".count)))
        }
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

/// The factory decorator closes over this before the core exists, and pty
/// read threads call through it afterwards; the lock covers that handoff.
private final class OutputTapRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: InProcessTerminalCore?

    var core: InProcessTerminalCore? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return target
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            target = newValue
        }
    }

    func deliver(pid: Int32, data: Data) {
        core?.observeChunk(pid: pid, data: data)
    }
}

/// Wraps the real PTY factory so every output chunk passes the engine once.
/// Chunks are keyed by pid because the spawn request carries no terminal
/// identity; bytes read before the pid lands in the box precede any agent
/// turn and are deliberately not scanned.
private struct AgentMarkTappingFactory: FreshTerminalProcessFactory {
    let base: any FreshTerminalProcessFactory
    let relay: OutputTapRelay

    func spawn(
        request: FreshTerminalSpawnRequest,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> any FreshTerminalProcess {
        let box = PidBox()
        let relay = relay
        let process = try await base.spawn(request: request) { data in
            if let pid = box.value { relay.deliver(pid: pid, data: data) }
            onOutput(data)
        }
        box.value = process.pid
        return process
    }
}

private final class PidBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?

    var value: Int32? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return pid
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            pid = newValue
        }
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

    /// Everything the in-process engine actually implements. Observer
    /// coalescing is deliberately absent: the store publishes each pty read as
    /// it lands, and a client that sees the coalescing capability switches off
    /// its own frame window — advertising it here would put every raw chunk
    /// straight on the main thread.
    static let engineFeatures: [String] = BrokerWire.advertisedFeatures.filter {
        $0 != BrokerWire.terminalObserverCoalescingFeature
    }

    init(core: InProcessTerminalCore = .shared) {
        self.core = core
        client = BrokerAuthenticatedClient(
            instanceID: facadeID,
            role: .controller,
            negotiatedFeatures: Self.engineFeatures
        )
    }

    private func hello() -> BrokerHello {
        BrokerHello(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: nil,
            packageVersion: nil,
            features: Set(Self.engineFeatures),
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
            core.noteObserver(
                facadeID: facadeID,
                ownerID: ownerID,
                projectID: terminal.projectID,
                terminalID: terminal.id
            )
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
            core.noteObserver(
                facadeID: facadeID,
                ownerID: ownerID,
                projectID: terminal.projectID,
                terminalID: terminal.id
            )
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
        core.removeObserver(facadeID: facadeID, ownerID: ownerID, terminalID: terminal.id)
        _ = try? await core.store.unsubscribe(
            id: terminal.id,
            projectID: terminal.projectID,
            accessOwner: nil,
            subscriber: subscriberKey(ownerID: ownerID, terminal: terminal)
        )
    }

    func disconnect() async {
        core.unregister(facadeID: facadeID)
        core.removeObservers(facadeID: facadeID)
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
        if !creation.exited {
            core.registerSpawn(pid: creation.pid, terminalID: creation.id)
        }
        return TerminalCreation(
            terminalID: creation.id,
            projectID: projectID,
            pid: creation.exited ? nil : creation.pid,
            existed: creation.existed,
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
