import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState: Equatable {
        case looking
        case connecting
        case reconnecting(attempt: Int)
        case connected(version: String, pid: Int32, serverEnforcedObserver: Bool)
        case unavailable(String)

        var title: String {
            switch self {
            case .looking: "Looking for broker"
            case .connecting: "Connecting"
            case .reconnecting: "Reconnecting"
            case .connected: "Connected"
            case .unavailable: "Offline"
            }
        }

        var detail: String? {
            switch self {
            case let .reconnecting(attempt):
                "Attempt \(attempt) · running terminals remain on the broker"
            case let .connected(version, pid, serverEnforced):
                "Broker \(version) · PID \(pid) · \(serverEnforced ? "server-enforced observer" : "local observer policy")"
            case let .unavailable(message): message
            default: nil
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var connectionState: ConnectionState = .looking
    @Published private(set) var sessions: [BrokerTerminalRecord] = []
    @Published var selectedSessionID: String?
    @Published private(set) var terminalDocument = TerminalDocument.empty
    /// Terminals this app created and may mutate. Everything else stays
    /// strictly observed no matter what the UI asks for.
    @Published private(set) var ownedTerminalIDs: Set<String> = []
    /// Whether the connected broker accepted a controller connection; older
    /// brokers stay observe-only and hide every mutation affordance.
    @Published private(set) var controlAvailable = false
    /// Open ACP chat conversations, keyed by a synthetic chat id. These run
    /// independently of the broker (the adapter is a child of this app).
    @Published private(set) var chats: [AcpChatHandle] = []
    @Published var selectedChatID: String?
    /// The project tab shown in the top-bar layout. Nil means the first project.
    @Published var selectedProjectName: String?

    private let brokerPreparer: any BrokerInfoPreparing
    private let client: any ObserveOnlyBrokerServing
    private let controlClient: any BrokerControlServing
    private let sessionStore: NativeSessionStore
    private let cursorStore: TerminalCursorStore
    private let reconnectBackoff: BrokerReconnectBackoff
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let jitter: @Sendable () -> Double
    private var selectedSession: BrokerTerminalRecord?
    private var activeBrokerIdentity: String?
    private var reconnectTask: Task<Void, Never>?
    private var cursorSaveTask: Task<Void, Never>?
    private var inventoryRefreshTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var shouldReconnect = false
    private var hasStarted = false
    private let observerOwnerID = "native-preview"

    init(
        brokerPreparer: any BrokerInfoPreparing = BrokerStartupCoordinator.live(),
        client: any ObserveOnlyBrokerServing = ObserveOnlyBrokerClient(),
        controlClient: any BrokerControlServing = BrokerControlClient(),
        sessionStore: NativeSessionStore = NativeSessionStore(),
        cursorStore: TerminalCursorStore = TerminalCursorStore(fileURL: NativePreviewPaths.terminalCursorStore),
        reconnectBackoff: BrokerReconnectBackoff = BrokerReconnectBackoff(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        jitter: @escaping @Sendable () -> Double = {
            Double.random(in: -1...1)
        }
    ) {
        self.brokerPreparer = brokerPreparer
        self.client = client
        self.controlClient = controlClient
        self.sessionStore = sessionStore
        self.cursorStore = cursorStore
        self.reconnectBackoff = reconnectBackoff
        self.sleep = sleep
        self.jitter = jitter
    }

    var projects: [(name: String, sessions: [BrokerTerminalRecord])] {
        let ownedNames = Dictionary(
            uniqueKeysWithValues: sessionStore.sessions().map {
                ($0.projectID, ($0.cwd as NSString).lastPathComponent)
            }
        )
        return Dictionary(grouping: sessions, by: \.projectID)
            .map { (name: ownedNames[$0.key] ?? $0.key, sessions: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isOwned(_ terminalID: String) -> Bool {
        ownedTerminalIDs.contains(terminalID)
    }

    /// The working directory of an owned session (for the Git panel). Observed
    /// Electron terminals have no known local directory here.
    func directory(for terminalID: String) -> URL? {
        sessionStore.sessions().first { $0.id == terminalID }.map { URL(fileURLWithPath: $0.cwd) }
    }

    // MARK: - ACP chats

    /// Open a new ACP chat with the given agent in a directory. The adapter is
    /// spawned as a child of this app (ACP sessions are app-scoped, unlike the
    /// broker-durable terminals). Selecting the chat shows its conversation.
    func openChat(_ agent: AgentProfile, inDirectory directory: URL) {
        guard let adapter = AcpAdapter.forAgent(agent.id) else { return }
        let chatID = "chat-\(UUID().uuidString.lowercased().prefix(8))"
        let conversation = AcpConversation(
            title: "\(agent.name) · \((directory.path as NSString).lastPathComponent)",
            command: adapter.command,
            arguments: adapter.arguments,
            cwd: directory.path
        )
        chats.append(AcpChatHandle(id: chatID, agentID: agent.id, conversation: conversation))
        selectedChatID = chatID
        selectedSessionID = nil
    }

    func closeChat(_ chatID: String) {
        if let chat = chats.first(where: { $0.id == chatID }) {
            chat.conversation.stop()
        }
        chats.removeAll { $0.id == chatID }
        if selectedChatID == chatID { selectedChatID = nil }
    }

    func selectChat(_ chatID: String?) {
        selectedChatID = chatID
        if chatID != nil { selectedSessionID = nil }
    }

    func reload() async {
        hasStarted = true
        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await persistCurrentCursor()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionState = .looking
        await client.disconnect()
        selectedSession = nil

        if !(await connect(generation: generation, reconnectAttempt: nil)) {
            scheduleReconnect(attempt: 0, generation: generation)
        }
    }

    /// Called when the app returns to the foreground. An existing healthy
    /// observer is left alone; an offline one resumes its bounded retry loop.
    func resumeIfNeeded() {
        guard hasStarted,
              shouldReconnect,
              case .unavailable = connectionState else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        scheduleReconnect(attempt: 0, generation: connectionGeneration, immediate: true)
    }

    /// Sleep can invalidate a Unix socket without promptly waking a blocked
    /// read. Reopening the observer is safe and retains the in-memory cursor.
    func recoverAfterWake() async {
        guard hasStarted, shouldReconnect else { return }
        await reload()
    }

    func select(_ id: String?) async {
        guard let id, let next = sessions.first(where: { $0.id == id }) else {
            await persistCurrentCursor()
            if let current = selectedSession, connectionState.isConnected {
                try? await client.unsubscribe(from: current, ownerID: observerOwnerID)
            }
            selectedSession = nil
            selectedSessionID = nil
            terminalDocument = .empty
            return
        }

        if let current = selectedSession, current.id != next.id {
            await persistCurrentCursor()
            if connectionState.isConnected {
                try? await client.unsubscribe(from: current, ownerID: observerOwnerID)
            }
        }

        let retainedDocument = terminalDocument.sessionID == next.id ? terminalDocument : .empty
        selectedSession = next
        selectedSessionID = next.id
        guard connectionState.isConnected else {
            terminalDocument = retainedDocument
            return
        }

        let resumeCursor = retainedDocument.cursor
        let priorPersistedCursor: TerminalCursor?
        if let scope = cursorScope(for: next) {
            priorPersistedCursor = try? await cursorStore.cursor(for: scope)
        } else {
            priorPersistedCursor = nil
        }

        do {
            let result = try await client.subscribe(
                to: next,
                ownerID: observerOwnerID,
                cursor: resumeCursor
            )
            var document = retainedDocument.applying(result, sessionID: next.id)
            // A cold launch asks for the full retained snapshot instead of
            // skipping bytes merely because a disk cursor exists. The cursor
            // still proves whether history disappeared while the UI was away.
            if resumeCursor == nil,
               let priorPersistedCursor,
               case let .snapshot(snapshot, _) = result,
               (priorPersistedCursor.streamEpoch != snapshot.streamEpoch
                   || priorPersistedCursor.offset < snapshot.startOffset
                   || priorPersistedCursor.offset > snapshot.endOffset) {
                document.truncated = true
            }
            terminalDocument = document
            await persistCurrentCursor()
        } catch {
            terminalDocument = .failure(sessionID: next.id, message: error.kaisolaSafeDescription)
        }
    }

    // MARK: - Native terminal ownership (Phase 2)

    /// Creates a plain shell the native app owns in the given directory.
    func createTerminal(inDirectory directory: URL) async {
        await createOwnedSession(inDirectory: directory, agent: nil)
    }

    /// Launches a one-click agent session: an owned terminal that boots the
    /// agent's CLI in the chosen directory, exactly like Electron's prepared
    /// terminal agents.
    func createAgentSession(_ agent: AgentProfile, inDirectory directory: URL) async {
        await createOwnedSession(inDirectory: directory, agent: agent)
    }

    /// Registers a durable owned session and selects it. The PTY lives on the
    /// broker, so it survives this app quitting, updating, or crashing exactly
    /// like Electron's do. An agent session boots its CLI via a login shell so
    /// the user's PATH and CLI config apply.
    private func createOwnedSession(inDirectory directory: URL, agent: AgentProfile?) async {
        guard controlAvailable else { return }
        let cwd = directory.path
        let projectID = NativeSessionStore.projectID(forDirectory: cwd)
        let terminalID = NativeSessionStore.terminalID(projectID: projectID)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let arguments: [String]
        if let agent, !agent.launchCommand.isEmpty {
            // -ilc runs the agent as the login shell's command so it inherits
            // the interactive environment, then hands control to the user.
            arguments = ["-ilc", "\(agent.launchCommand); exec \(shell) -il"]
        } else {
            arguments = ["-il"]
        }
        do {
            _ = try await controlClient.createTerminal(
                projectID: projectID,
                terminalID: terminalID,
                command: shell,
                arguments: arguments,
                cwd: cwd,
                columns: 100,
                rows: 30
            )
            let folder = (cwd as NSString).lastPathComponent
            sessionStore.upsert(NativeOwnedSession(
                id: terminalID,
                projectID: projectID,
                cwd: cwd,
                title: agent.map { "\($0.name) · \(folder)" } ?? folder,
                createdAt: Int64(Date().timeIntervalSince1970 * 1_000),
                agentID: agent?.id
            ))
            ownedTerminalIDs.insert(terminalID)
            await refreshInventory()
            selectedSessionID = terminalID
            await select(terminalID)
        } catch {
            terminalDocument = .failure(sessionID: terminalID, message: error.kaisolaSafeDescription)
        }
    }

    /// The agent profile a session runs, or nil for a plain shell / observed
    /// Electron terminal.
    func agentProfile(for terminalID: String) -> AgentProfile? {
        guard let stored = sessionStore.sessions().first(where: { $0.id == terminalID }),
              let agentID = stored.agentID else { return nil }
        return AgentRegistry.profile(id: agentID)
    }

    /// Rename an owned session's sidebar title.
    func renameSession(_ terminalID: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOwned(terminalID), !trimmed.isEmpty,
              var stored = sessionStore.sessions().first(where: { $0.id == terminalID }) else { return }
        stored.title = trimmed
        sessionStore.upsert(stored)
        objectWillChange.send()
    }

    /// Keyboard bytes from an owned session's surface. Ownership is re-checked
    /// here so no UI wiring mistake can ever write to an observed terminal. For
    /// an agent session, a submitted line (carriage return) opens an agent
    /// turn; the broker's quiet timer settles it back to idle.
    func sendInput(_ data: String, to terminalID: String) {
        guard controlAvailable, isOwned(terminalID),
              let record = sessions.first(where: { $0.id == terminalID }) else { return }
        let projectID = record.projectID
        let opensAgentTurn = agentProfile(for: terminalID) != nil && data.contains("\r")
        Task {
            try? await controlClient.write(projectID: projectID, terminalID: terminalID, data: data)
            if opensAgentTurn {
                try? await controlClient.setAgentTurn(projectID: projectID, terminalID: terminalID, busy: true)
            }
        }
    }

    func resizeTerminal(_ terminalID: String, columns: Int, rows: Int) {
        guard controlAvailable, isOwned(terminalID),
              let record = sessions.first(where: { $0.id == terminalID }) else { return }
        let projectID = record.projectID
        Task { try? await controlClient.resize(projectID: projectID, terminalID: terminalID, columns: columns, rows: rows) }
    }

    /// Ends an owned session for good: the PTY dies and the registry entry is
    /// removed. (App quit is different — quitting detaches and the shell keeps
    /// running on the broker.)
    func endSession(_ terminalID: String) async {
        guard isOwned(terminalID),
              let record = sessions.first(where: { $0.id == terminalID }) else { return }
        try? await controlClient.kill(projectID: record.projectID, terminalID: terminalID)
        sessionStore.remove(terminalID: terminalID)
        ownedTerminalIDs.remove(terminalID)
        if selectedSessionID == terminalID {
            selectedSessionID = nil
            await select(nil)
        }
        await refreshInventory()
    }

    /// Refresh the session list from the broker without disturbing streams.
    /// The `list()` rows carry agent busy/completed fields, so this keeps every
    /// row's agent status current, not just the subscribed one.
    func refreshInventory() async {
        guard connectionState.isConnected else { return }
        if let status = try? await client.inventory() {
            sessions = status.terminals
        }
    }

    /// A light periodic refresh so agent working/idle state stays current on
    /// every row while the app is connected. The subscribed session also gets
    /// immediate activity events; this covers the rest.
    private func startInventoryRefresh(generation: Int) {
        inventoryRefreshTask?.cancel()
        let sleeper = sleep
        inventoryRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleeper(2_500_000_000) } catch { return }
                guard let self, generation == self.connectionGeneration else { return }
                await self.refreshInventory()
            }
        }
    }

    /// After the observer connects, bring up the controller lane and re-own
    /// the terminals this app created in earlier runs. Any registry entry the
    /// broker no longer knows is pruned.
    private func restoreOwnedSessions(info: BrokerInfo) async {
        controlAvailable = false
        ownedTerminalIDs = []
        do {
            try await controlClient.connect(to: info, ownerID: sessionStore.ownerID())
        } catch {
            // Observation continues against brokers that refuse control.
            return
        }
        controlAvailable = true
        var owned: Set<String> = []
        for stored in sessionStore.sessions() {
            guard let record = sessions.first(where: { $0.id == stored.id }) else {
                sessionStore.remove(terminalID: stored.id)
                continue
            }
            if record.exited {
                owned.insert(stored.id)
                continue
            }
            do {
                try await controlClient.attach(projectID: stored.projectID, terminalID: stored.id)
                owned.insert(stored.id)
            } catch {
                // Another controller holds it; leave it observed.
            }
        }
        ownedTerminalIDs = owned
    }

    /// App-quit path: detach so owned shells keep running on the broker, then
    /// drop the controller connection.
    func releaseOwnedSessionsForQuit() async {
        guard controlAvailable else { return }
        for stored in sessionStore.sessions() where ownedTerminalIDs.contains(stored.id) {
            try? await controlClient.detachOwner(projectID: stored.projectID, terminalID: stored.id)
        }
        await controlClient.disconnect()
        controlAvailable = false
    }

    func disconnect() async {
        shouldReconnect = false
        connectionGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        inventoryRefreshTask?.cancel()
        inventoryRefreshTask = nil
        cursorSaveTask?.cancel()
        cursorSaveTask = nil
        await persistCurrentCursor()
        await releaseOwnedSessionsForQuit()
        if let selectedSession, connectionState.isConnected {
            try? await client.unsubscribe(from: selectedSession, ownerID: observerOwnerID)
        }
        await client.disconnect()
    }

    private func connect(generation: Int, reconnectAttempt: Int?) async -> Bool {
        guard generation == connectionGeneration, shouldReconnect else { return false }
        // Retrying from a settled offline state stays silent: flipping to
        // "Reconnecting" every backoff cycle strobes the UI forever against a
        // broker that will keep refusing (for example one that predates
        // terminal observation). The state only moves when the outcome does.
        let silentRetry: Bool
        if case .unavailable = connectionState, reconnectAttempt != nil {
            silentRetry = true
        } else {
            silentRetry = false
        }
        if !silentRetry {
            connectionState = reconnectAttempt.map { .reconnecting(attempt: $0 + 1) } ?? .connecting
        }

        do {
            let info = try await brokerPreparer.prepare()
            activeBrokerIdentity = info.persistenceIdentity
            await client.setEventHandler { [weak self] event in
                Task { @MainActor in self?.consume(event) }
            }
            await client.setDisconnectHandler { [weak self] error in
                Task { @MainActor in self?.connectionLost(error, generation: generation) }
            }
            let hello = try await client.connect(to: info)
            let status = try await client.inventory()
            guard generation == connectionGeneration, shouldReconnect else { return false }

            sessions = status.terminals
            connectionState = .connected(
                version: hello.version,
                pid: hello.pid,
                serverEnforcedObserver: hello.serverEnforcedObserver
            )
            await restoreOwnedSessions(info: info)
            startInventoryRefresh(generation: generation)
            let preferredID = selectedSessionID.flatMap { selected in
                sessions.contains(where: { $0.id == selected }) ? selected : nil
            } ?? sessions.first?.id
            selectedSession = nil
            if let preferredID {
                selectedSessionID = preferredID
                await select(preferredID)
            } else {
                selectedSessionID = nil
                terminalDocument = .empty
            }
            return true
        } catch {
            guard generation == connectionGeneration, shouldReconnect else { return false }
            let description = error.kaisolaSafeDescription
            if case let .unavailable(existing) = connectionState, existing == description {
                // identical settled state — no churn for observers
            } else {
                connectionState = .unavailable(description)
            }
            return false
        }
    }

    private func scheduleReconnect(attempt: Int, generation: Int, immediate: Bool = false) {
        guard generation == connectionGeneration,
              shouldReconnect,
              reconnectTask == nil else { return }
        let delay = immediate ? 0 : reconnectBackoff.delayNanoseconds(
            forAttempt: attempt,
            jitterUnit: jitter()
        )
        let sleeper = sleep
        reconnectTask = Task { [weak self] in
            do {
                if delay > 0 { try await sleeper(delay) }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runReconnectAttempt(attempt, generation: generation)
        }
    }

    private func runReconnectAttempt(_ attempt: Int, generation: Int) async {
        reconnectTask = nil
        guard generation == connectionGeneration, shouldReconnect else { return }
        await client.disconnect()
        selectedSession = nil
        if !(await connect(generation: generation, reconnectAttempt: attempt)) {
            scheduleReconnect(attempt: attempt + 1, generation: generation)
        }
    }

    private func consume(_ event: BrokerEvent) {
        // Agent activity updates the session's row even if it is the selected
        // one; it is scoped to the subscribed terminal like every other event.
        if case let .activity(busy, completedAt) = event.kind {
            applyActivity(busy: busy, completedAt: completedAt, to: event.terminalID)
        }
        guard event.ownerID == observerOwnerID,
              event.projectID == selectedSession?.projectID,
              event.terminalID == selectedSession?.id else { return }

        switch event.kind {
        case let .output(epoch, startOffset, endOffset, data):
            guard terminalDocument.append(
                epoch: epoch,
                startOffset: startOffset,
                endOffset: endOffset,
                data: data
            ) else {
                Task { await select(selectedSessionID) }
                return
            }
            queueCursorPersistence()
        case .snapshotRequired:
            Task { await select(selectedSessionID) }
        case .exit:
            terminalDocument.exited = true
            queueCursorPersistence()
        case .activity:
            break
        }
    }

    private func applyActivity(busy: Bool, completedAt: Int64?, to terminalID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == terminalID }) else { return }
        if busy {
            sessions[index].agentActivity = .working
        } else if let completedAt {
            sessions[index].agentActivity = .responded(at: completedAt)
        } else {
            sessions[index].agentActivity = .idle
        }
    }

    private func connectionLost(_ error: any Error, generation: Int) {
        guard generation == connectionGeneration, shouldReconnect else { return }
        connectionState = .unavailable(error.kaisolaSafeDescription)
        scheduleReconnect(attempt: 0, generation: generation)
    }

    private func cursorScope(for session: BrokerTerminalRecord) -> TerminalCursorScope? {
        guard let activeBrokerIdentity else { return nil }
        return TerminalCursorScope(
            brokerIdentity: activeBrokerIdentity,
            projectID: session.projectID,
            terminalID: session.id
        )
    }

    private func persistCurrentCursor() async {
        cursorSaveTask?.cancel()
        cursorSaveTask = nil
        guard let session = selectedSession,
              let scope = cursorScope(for: session),
              terminalDocument.sessionID == session.id,
              let cursor = terminalDocument.cursor else { return }
        try? await cursorStore.save(cursor, for: scope)
    }

    private func queueCursorPersistence() {
        guard let session = selectedSession,
              let scope = cursorScope(for: session),
              terminalDocument.sessionID == session.id,
              let cursor = terminalDocument.cursor else { return }
        cursorSaveTask?.cancel()
        let store = cursorStore
        cursorSaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            try? await store.save(cursor, for: scope)
        }
    }
}

private extension Error {
    var kaisolaSafeDescription: String {
        if let localized = self as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "The terminal observer could not connect. The running broker and its sessions were left untouched."
    }
}
