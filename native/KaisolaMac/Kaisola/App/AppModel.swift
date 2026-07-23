import AppKit
import Combine
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
    /// A file opened from the workspace rail / palette; non-nil replaces the
    /// detail pane with the preview/editor until closed.
    @Published var previewedFileURL: URL?
    /// Line target for the previewed file (from a terminal :LINE citation);
    /// retained for a future editor scroll.
    @Published var previewedFileLine: Int?
    /// A local dev-server URL opened as an in-app browser card (Electron
    /// parity); non-nil raises a BrowserCardView in the detail pane.
    @Published var browserCardURL: URL?

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
        fallbackPreparer: (any BrokerInfoPreparing)? = BrokerStartupCoordinator(
            locator: .nativeOwn(),
            launcher: BrokerBootstrapClient(directOnly: true)
        ),
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
        self.fallbackPreparer = fallbackPreparer
        self.client = client
        self.controlClient = controlClient
        self.sessionStore = sessionStore
        self.cursorStore = cursorStore
        self.reconnectBackoff = reconnectBackoff
        self.sleep = sleep
        self.jitter = jitter
    }

    /// Keeps the per-chat usage observers alive for this window's lifetime.
    private var usageObservers = Set<AnyCancellable>()
    /// The separate native-profile broker used when Electron's is incompatible.
    private let fallbackPreparer: (any BrokerInfoPreparing)?
    /// True when this window is connected to the app's own separate broker
    /// (Electron's remains untouched beside it).
    @Published private(set) var usingSeparateBroker = false

    /// A project grouping for the sidebar/tabs: a stable id, a display name,
    /// its optional local directory, and its live sessions. Explicitly-opened
    /// project tabs appear even with no sessions.
    struct ProjectGroup: Identifiable, Equatable {
        let id: String
        let name: String
        let directory: URL?
        let sessions: [BrokerTerminalRecord]
        /// Tab tint (hex RGB) chosen by the user, nil = default.
        var colorHex: String?
        /// Sessions currently in an agent "working" state — the activity badge.
        var workingCount: Int = 0
    }

    var projects: [ProjectGroup] {
        let opened = sessionStore.projects()
        let openedByID = Dictionary(uniqueKeysWithValues: opened.map { ($0.id, $0) })
        let ownedByID = Dictionary(
            sessionStore.sessions().map { ($0.projectID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sessionsByProject = Dictionary(grouping: sessions, by: \.projectID)
        let pins = SessionPinStore().pins()

        func group(for id: String) -> ProjectGroup {
            let sessions = AppModel.pinnedOrder(sessionsByProject[id] ?? [], pinned: pins)
            let name = openedByID[id]?.name
                ?? ownedByID[id].map { ($0.cwd as NSString).lastPathComponent }
                ?? id
            let directory = openedByID[id].map { URL(fileURLWithPath: $0.path) }
                ?? ownedByID[id].map { URL(fileURLWithPath: $0.cwd) }
            let working = sessions.filter { record in
                if case .working = record.agentActivity, !record.exited { return true }
                return false
            }.count
            return ProjectGroup(
                id: id, name: name, directory: directory, sessions: sessions,
                colorHex: openedByID[id]?.colorHex, workingCount: working
            )
        }

        // Opened tabs keep their persisted (user-reordered) sequence; projects
        // that only exist through live sessions follow, sorted by name.
        let openedGroups = opened.map { group(for: $0.id) }
        let sessionOnly = Set(sessionsByProject.keys).subtracting(opened.map(\.id))
            .map(group(for:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return openedGroups + sessionOnly
    }

    func setProjectColor(id: String, colorHex: String?) {
        sessionStore.setProjectColor(id: id, colorHex: colorHex)
        objectWillChange.send()
    }

    func moveProject(id: String, delta: Int) {
        sessionStore.moveProject(id: id, delta: delta)
        objectWillChange.send()
    }

    func moveProject(id: String, toIndex: Int) {
        sessionStore.moveProject(id: id, toIndex: toIndex)
        objectWillChange.send()
    }

    func relocateProject(id: String, to directory: URL) {
        if let relocated = sessionStore.relocateProject(id: id, toDirectory: directory.path) {
            selectedProjectName = relocated.name
        }
        objectWillChange.send()
    }

    var recentFolders: [String] { sessionStore.recentFolders() }

    func isOwned(_ terminalID: String) -> Bool {
        ownedTerminalIDs.contains(terminalID)
    }

    // MARK: - Project tabs

    /// Open a folder as a project tab (persists even with no sessions).
    func openProject(directory: URL) {
        let project = sessionStore.openProject(directory: directory.path)
        selectedProjectName = project.name
        objectWillChange.send()
    }

    func renameProject(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionStore.renameProject(id: id, name: trimmed)
        objectWillChange.send()
    }

    /// Close a project tab. Its live sessions keep running on the broker; this
    /// just removes the tab from the persisted list.
    func closeProject(id: String) {
        sessionStore.closeProject(id: id)
        objectWillChange.send()
    }

    /// Restore the most recently closed project tab (⌘⇧T) and select it.
    func reopenLastClosedProject() {
        if let restored = sessionStore.reopenLastClosedProject() {
            selectedProjectName = restored.name
        }
        objectWillChange.send()
    }

    var hasClosedProjects: Bool { !sessionStore.closedProjects().isEmpty }

    /// The working directory of an owned session (for the Git panel). Observed
    /// Electron terminals have no known local directory here.
    func directory(for terminalID: String) -> URL? {
        sessionStore.sessions().first { $0.id == terminalID }.map { URL(fileURLWithPath: $0.cwd) }
    }

    /// The directory of the project the user is currently working in, used to
    /// default new terminals/agents/chats to the active project instead of
    /// forcing a folder picker every time (matching the Electron workflow).
    /// Nil only when there's genuinely no project context to infer.
    var currentProjectDirectory: URL? {
        if let name = selectedProjectName,
           let project = projects.first(where: { $0.name == name }),
           let directory = project.directory {
            return directory
        }
        if let sessionID = selectedSessionID, let directory = directory(for: sessionID) {
            return directory
        }
        // With a single project open, that's unambiguously the context.
        let all = projects
        if all.count == 1 { return all.first?.directory }
        return nil
    }

    // MARK: - ACP chats

    /// Open a new ACP chat with the given agent in a directory. The adapter is
    /// spawned as a child of this app (ACP sessions are app-scoped, unlike the
    /// broker-durable terminals). Selecting the chat shows its conversation.
    func openChat(_ agent: AgentProfile, inDirectory directory: URL) {
        guard let adapter = AcpAdapter.forAgent(agent.id) else { return }
        let chatID = "chat-\(UUID().uuidString.lowercased().prefix(8))"
        let mcp = McpConfigStore(workspace: directory).servers()
        let conversation = AcpConversation(
            title: "\(agent.name) · \((directory.path as NSString).lastPathComponent)",
            command: adapter.command,
            arguments: adapter.arguments,
            environment: ProcessInfo.processInfo.environment.merging(
                ProjectAccountStore.mergedOverlay(
                    app: NativePreviewSettings.shared.agentEnvironmentOverlay,
                    project: ProjectAccountStore().override(
                        forProject: NativeSessionStore.projectID(forDirectory: directory.path)
                    )
                )
            ) { _, custom in custom },
            cwd: directory.path,
            mcpServers: McpConfigStore.jsonValues(mcp),
            sensitiveGlobs: NativePreviewSettings.shared.sensitiveGlobs,
            draftKey: "\(agent.id)|\(directory.path)"
        )
        // Fan this chat's live context usage into the session-wide UsageCenter.
        let usageTitle = conversation.title
        conversation.$usage
            .compactMap { $0 }
            .sink { usage in
                UsageCenter.shared.record(
                    chatID: chatID, title: usageTitle, agentID: agent.id,
                    usage: usage.used, max: usage.max
                )
            }
            .store(in: &usageObservers)
        conversation.$isRunning
            .scan((false, false)) { ($0.1, $1) }
            .filter { $0.0 && !$0.1 }
            .sink { _ in UsageCenter.shared.recordTurn(chatID: chatID) }
            .store(in: &usageObservers)
        // Needs-you moments land in the inbox only when the chat isn't the
        // focused surface (or the app is in the background).
        let title = conversation.title
        conversation.onAttention = { [weak self] kind, detail in
            guard let self else { return }
            let appActive = NSApp?.isActive ?? true
            if self.selectedChatID == chatID, appActive { return }
            AttentionCenter.shared.notify(kind: kind, targetID: chatID, title: title, detail: detail)
        }
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
        if let chatID {
            selectedSessionID = nil
            selectedMeshID = nil
            AttentionCenter.shared.clear(targetID: chatID)
        }
    }

    // MARK: - Kaisola Mesh

    /// Live Mesh sessions (app-scoped, like chats).
    @Published private(set) var meshes: [MeshSession] = []
    @Published var selectedMeshID: String?

    /// Start a Mesh in a directory with every ACP-capable agent. `staged`
    /// runs the scout→execute pipeline; `idea` runs the read-only brainstorm.
    func openMesh(inDirectory directory: URL, staged: Bool = false, idea: Bool = false) {
        let agents = AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil }
        guard !agents.isEmpty else { return }
        let mesh = MeshSession(
            baseDirectory: directory,
            mode: staged ? .staged : .flat,
            purpose: idea ? .idea : .build
        )
        meshes.append(mesh)
        selectedMeshID = mesh.id
        selectedChatID = nil
        selectedSessionID = nil
        let environment = ProcessInfo.processInfo.environment.merging(
            ProjectAccountStore.mergedOverlay(
                app: NativePreviewSettings.shared.agentEnvironmentOverlay,
                project: ProjectAccountStore().override(
                    forProject: NativeSessionStore.projectID(forDirectory: directory.path)
                )
            )
        ) { _, custom in custom }
        Task { await mesh.start(agents: agents, environment: environment) }
    }

    func closeMesh(_ meshID: String) {
        meshes.first { $0.id == meshID }?.shutdown()
        meshes.removeAll { $0.id == meshID }
        if selectedMeshID == meshID { selectedMeshID = nil }
    }

    func selectMesh(_ meshID: String?) {
        selectedMeshID = meshID
        if meshID != nil {
            selectedChatID = nil
            selectedSessionID = nil
        }
    }

    /// Full window teardown: stop every app-scoped surface this model owns
    /// (chat adapters and their terminal hosts, Mesh agents + worktrees), then
    /// drop the broker connections. Closing a window must not leak child
    /// processes or leave Mesh worktrees registered.
    func teardown() async {
        for chat in chats {
            chat.conversation.stop()
        }
        chats.removeAll()
        for mesh in meshes {
            mesh.shutdown()
        }
        meshes.removeAll()
        await disconnect()
    }

    /// Jump from an inbox entry to its surface (chat or terminal session).
    func jumpToAttentionTarget(_ targetID: String) {
        AttentionCenter.shared.clear(targetID: targetID)
        if chats.contains(where: { $0.id == targetID }) {
            selectChat(targetID)
        } else {
            selectChat(nil)
            selectedSessionID = targetID
            Task { await select(targetID) }
        }
    }

    func reload() async {
        hasStarted = true
        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await persistCurrentCursor()
        await clearSplits()
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
        sessionStore.recordSelectedSession(next.id)
        AttentionCenter.shared.clear(targetID: next.id)
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
    @discardableResult
    func createTerminal(inDirectory directory: URL) async -> String? {
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
    /// Returns the created terminal's id on success, nil on failure — so a
    /// caller (e.g. a Quick Action) can target exactly the shell it spawned
    /// rather than racing the shared `selectedSessionID`.
    @discardableResult
    private func createOwnedSession(inDirectory directory: URL, agent: AgentProfile?) async -> String? {
        guard controlAvailable else {
            // Never fail silently: say WHY sessions can't be created here.
            terminalDocument = .failure(
                sessionID: "create-unavailable",
                message: connectionState.isConnected
                    ? "The connected broker doesn't accept native control (it predates the controller lane), so new sessions can't be created from this app yet. Chats and Mesh still work — they don't need the broker."
                    : "No broker connection — new sessions need a running session broker. Chats and Mesh still work without one."
            )
            return nil
        }
        let cwd = directory.path
        let projectID = NativeSessionStore.projectID(forDirectory: cwd)
        let terminalID = NativeSessionStore.terminalID(projectID: projectID)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Account isolation (custom CLAUDE_CONFIG_DIR / CODEX_HOME) rides in
        // as exported variables ahead of the CLI. Per-project overrides win
        // over the app-wide setting, key by key.
        let overlay = ProjectAccountStore.mergedOverlay(
            app: NativePreviewSettings.shared.agentEnvironmentOverlay,
            project: ProjectAccountStore().override(forProject: projectID)
        )
        // The overlay can carry secrets (ANTHROPIC_API_KEY / OPENAI_API_KEY).
        // The broker's createTerminal has no env channel, so the env must reach
        // the shell through the `-c` command — but embedding `export KEY=secret`
        // there leaves the secret in the parent shell's argv, visible to every
        // `ps`/diagnostic while the agent runs. Instead write the exports to a
        // per-session 0600 file and `source` + `rm` it, so only the file PATH
        // (not the secret) is ever in argv. Falls back to inline exports if the
        // file can't be written, so a write failure never blocks a session.
        let exports = overlay
            .map { "export \($0.key)=\(Self.shellQuote($0.value)); " }
            .sorted()
            .joined()
        let prelude: String
        if overlay.isEmpty {
            prelude = ""
        } else if let envFile = Self.writeSessionEnvFile(exports: exports, terminalID: terminalID) {
            prelude = "source \(Self.shellQuote(envFile)); rm -f \(Self.shellQuote(envFile)); "
        } else {
            prelude = exports
        }
        let arguments: [String]
        if let agent, !agent.launchCommand.isEmpty {
            // -ilc runs the agent as the login shell's command so it inherits
            // the interactive environment, then hands control to the user.
            arguments = ["-ilc", "\(prelude)\(agent.launchCommand); exec \(shell) -il"]
        } else if !prelude.isEmpty {
            // Plain shells get the account env too, so a hand-typed `claude`
            // or `codex` (and the Sign-in card's login) uses the right dir.
            arguments = ["-ilc", "\(prelude)exec \(shell) -il"]
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
            // Ensure the session's folder is a persistent project tab.
            sessionStore.openProject(directory: cwd)
            ownedTerminalIDs.insert(terminalID)
            await refreshInventory()
            selectedSessionID = terminalID
            await select(terminalID)
            return terminalID
        } catch {
            terminalDocument = .failure(sessionID: terminalID, message: error.kaisolaSafeDescription)
            return nil
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Write the export prelude to a per-session mode-0600 file under Application
    /// Support so account secrets reach the broker-spawned shell without landing
    /// in its argv. Returns the file path, or nil on any failure (caller then
    /// falls back to inline exports — availability over secrecy). The shell
    /// `rm`s it immediately after sourcing; a stale file (shell never ran) is a
    /// 0600 file only the user can read.
    private static func writeSessionEnvFile(exports: String, terminalID: String) -> String? {
        let directory = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("session-env", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Sanitize the id into a filename; it is broker-generated but keep
            // the path from ever escaping the directory.
            let safeID = terminalID.replacingOccurrences(
                of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression
            )
            let file = directory.appendingPathComponent("\(safeID).sh", isDirectory: false)
            try Data(exports.utf8).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path
            )
            return file.path
        } catch {
            return nil
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

    /// A live OSC title from an owned session's terminal (SwiftTerm's
    /// setTerminalTitle). Auto-names the session unless the user renamed it.
    func applyAutoTitle(_ rawTitle: String, to terminalID: String) {
        guard isOwned(terminalID),
              let stored = sessionStore.sessions().first(where: { $0.id == terminalID }) else { return }
        let agentName = agentProfile(for: terminalID)?.name
        let folder = (stored.cwd as NSString).lastPathComponent
        guard let auto = SessionTitleTracker.autoTitle(fromOSC: rawTitle, agentName: agentName, folder: folder) else { return }
        let defaultTitle = agentName.map { "\($0) · \(folder)" } ?? folder
        guard SessionTitleTracker.shouldApply(
            autoTitle: auto,
            currentTitle: stored.title,
            userRenamed: sessionStore.hasCustomTitle(terminalID, defaultTitle: defaultTitle)
        ) else { return }
        sessionStore.applyAutoTitle(auto, terminalID: terminalID)
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
        // Remember enough to recreate it (⌘⌥T) before the registry forgets.
        if let stored = sessionStore.sessions().first(where: { $0.id == terminalID }) {
            sessionStore.pushClosedSession(ClosedSession(cwd: stored.cwd, agentID: stored.agentID, title: stored.title))
        }
        try? await controlClient.kill(projectID: record.projectID, terminalID: terminalID)
        sessionStore.remove(terminalID: terminalID)
        ownedTerminalIDs.remove(terminalID)
        if selectedSessionID == terminalID {
            selectedSessionID = nil
            await select(nil)
        }
        await refreshInventory()
    }

    /// Recreate the most recently ended session (⌘⌥T): a fresh shell (and agent
    /// CLI, if it had one) in the same folder. The old PTY is gone — this is a
    /// new session with the old identity.
    func reopenLastClosedSession() async {
        guard let closed = sessionStore.popClosedSession() else { return }
        let directory = URL(fileURLWithPath: closed.cwd)
        let agent = closed.agentID.flatMap { AgentRegistry.profile(id: $0) }
        await createOwnedSession(inDirectory: directory, agent: agent)
    }

    var hasClosedSessions: Bool { !sessionStore.closedSessions().isEmpty }

    /// Refresh the session list from the broker without disturbing streams.
    /// The `list()` rows carry agent busy/completed fields, so this keeps every
    /// row's agent status current, not just the subscribed one.
    func refreshInventory() async {
        guard connectionState.isConnected else { return }
        if let status = try? await client.inventory() {
            sessions = status.terminals
        }
        refreshBranches()
        refreshMeta()
    }

    /// Process-name + listening-port meta per OWNED session (Electron's meta
    /// poller), refreshed on a TTL so the inventory tick stays cheap.
    @Published private(set) var metaByTerminalID: [String: TerminalMeta] = [:]
    private var lastMetaScan = Date.distantPast

    func meta(for terminalID: String) -> TerminalMeta? { metaByTerminalID[terminalID] }

    private func refreshMeta() {
        guard Date().timeIntervalSince(lastMetaScan) > 5 else { return }
        lastMetaScan = Date()
        let owned: [(String, Int32)] = sessions.compactMap {
            guard ownedTerminalIDs.contains($0.id), !$0.exited, let pid = $0.pid else { return nil }
            return ($0.id, pid)
        }
        Task.detached(priority: .utility) { [weak self] in
            var out: [String: TerminalMeta] = [:]
            for (id, pid) in owned { out[id] = TerminalMetaService.collect(pid: pid) }
            let collected = out
            await MainActor.run { [weak self] in self?.metaByTerminalID = collected }
        }
    }

    /// Git branch per owned-session folder (session-row meta), refreshed on a
    /// TTL so the inventory tick doesn't spawn a git process per 2.5s.
    @Published private(set) var branchesByCwd: [String: String] = [:]
    private var lastBranchScan = Date.distantPast

    func branch(for terminalID: String) -> String? {
        guard let cwd = sessionStore.sessions().first(where: { $0.id == terminalID })?.cwd else { return nil }
        return branchesByCwd[cwd]
    }

    private func refreshBranches() {
        guard Date().timeIntervalSince(lastBranchScan) > 10 else { return }
        lastBranchScan = Date()
        let cwds = Set(sessionStore.sessions().map(\.cwd))
        guard !cwds.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var result: [String: String] = [:]
            for cwd in cwds {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
                process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continue }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { continue }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let branch = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !branch.isEmpty { result[cwd] = branch }
            }
            let branches = result
            await MainActor.run { [weak self] in self?.branchesByCwd = branches }
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
        await clearSplits()
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
            // The disconnect handler stays DISARMED until a connection is fully
            // established: an aborted probe handshake (e.g. Electron's broker
            // failing the feature check) must never fire connectionLost against
            // the connection the fallback goes on to establish.
            await client.setDisconnectHandler(nil)
            await client.setEventHandler { [weak self] event in
                Task { @MainActor in self?.consume(event) }
            }
            var info: BrokerInfo
            var hello: BrokerHello
            do {
                info = try await brokerPreparer.prepare()
                activeBrokerIdentity = info.persistenceIdentity
                hello = try await client.connect(to: info)
                usingSeparateBroker = false
            } catch BrokerClientError.observeFeatureMissing where fallbackPreparer != nil {
                // Electron's broker is alive but predates the features this app
                // needs. Leave it (and every session on it) untouched and run
                // the app's OWN broker under its separate profile instead.
                guard let fallbackPreparer else { throw BrokerClientError.observeFeatureMissing }
                // The failed hello leaves the client attached to the old
                // socket; reset it before dialing the separate broker.
                await client.disconnect()
                info = try await fallbackPreparer.prepare()
                activeBrokerIdentity = info.persistenceIdentity
                hello = try await client.connect(to: info)
                usingSeparateBroker = true
            }
            let status = try await client.inventory()
            guard generation == connectionGeneration, shouldReconnect else { return false }
            await client.setDisconnectHandler { [weak self] error in
                Task { @MainActor in self?.connectionLost(error, generation: generation) }
            }

            sessions = status.terminals
            connectionState = .connected(
                version: hello.version + (usingSeparateBroker ? " · separate native broker" : ""),
                pid: hello.pid,
                serverEnforcedObserver: hello.serverEnforcedObserver
            )
            await restoreOwnedSessions(info: info)
            startInventoryRefresh(generation: generation)
            // Prefer the in-memory selection, then the persisted one from the
            // last run (whole-app persistence), then the first session.
            let preferredID = selectedSessionID.flatMap { selected in
                sessions.contains(where: { $0.id == selected }) ? selected : nil
            } ?? sessionStore.lastSelectedSessionID().flatMap { stored in
                sessions.contains(where: { $0.id == stored }) ? stored : nil
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
        guard event.ownerID == observerOwnerID else { return }

        // Split panes get the same event handling as the primary document.
        if splitDocuments[event.terminalID] != nil, event.terminalID != selectedSession?.id {
            switch event.kind {
            case let .output(epoch, startOffset, endOffset, data):
                if splitDocuments[event.terminalID]?.append(
                    epoch: epoch, startOffset: startOffset, endOffset: endOffset, data: data
                ) != true {
                    Task { await resubscribeSplit(event.terminalID) }
                }
            case .snapshotRequired:
                Task { await resubscribeSplit(event.terminalID) }
            case .exit:
                splitDocuments[event.terminalID]?.exited = true
            case .activity:
                break
            }
            return
        }

        guard event.projectID == selectedSession?.projectID,
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

    // MARK: - Split panes (multiple sessions open at once)

    /// Additional open sessions, each with its own live subscription and
    /// document, rendered beside the primary pane. Order = pane order.
    @Published private(set) var splitDocuments: [String: TerminalDocument] = [:]
    @Published private(set) var splitOrder: [String] = []
    static let maxSplitPanes = 3

    /// Open a session in a split pane beside the primary one.
    func openInSplit(_ terminalID: String) async {
        guard connectionState.isConnected,
              splitDocuments[terminalID] == nil,
              terminalID != selectedSessionID,
              splitOrder.count < Self.maxSplitPanes,
              let record = sessions.first(where: { $0.id == terminalID }) else { return }
        do {
            let result = try await client.subscribe(to: record, ownerID: observerOwnerID, cursor: nil)
            splitDocuments[terminalID] = TerminalDocument.empty.applying(result, sessionID: terminalID)
            splitOrder.append(terminalID)
        } catch {
            splitDocuments[terminalID] = nil
        }
    }

    /// Close a split pane; its session keeps running on the broker.
    func closeSplit(_ terminalID: String) async {
        guard splitDocuments[terminalID] != nil else { return }
        await persistSplitCursor(terminalID)
        if connectionState.isConnected,
           let record = sessions.first(where: { $0.id == terminalID }) {
            try? await client.unsubscribe(from: record, ownerID: observerOwnerID)
        }
        splitDocuments[terminalID] = nil
        splitOrder.removeAll { $0 == terminalID }
    }

    /// Promote a split to the primary pane (tab click): the split subscription
    /// closes with its cursor persisted, then the normal select path resumes
    /// from that cursor — continuous scrollback, one subscription per terminal.
    func promoteSplit(_ terminalID: String) async {
        guard splitDocuments[terminalID] != nil else { return }
        await closeSplit(terminalID)
        selectedChatID = nil
        selectedMeshID = nil
        await select(terminalID)
    }

    /// Drop every split (connection loss / reload), persisting cursors.
    private func clearSplits() async {
        for id in splitOrder { await persistSplitCursor(id) }
        splitDocuments.removeAll()
        splitOrder.removeAll()
    }

    private func resubscribeSplit(_ terminalID: String) async {
        guard splitDocuments[terminalID] != nil,
              let record = sessions.first(where: { $0.id == terminalID }) else { return }
        if let result = try? await client.subscribe(to: record, ownerID: observerOwnerID, cursor: nil) {
            splitDocuments[terminalID] = TerminalDocument.empty.applying(result, sessionID: terminalID)
        }
    }

    private func persistSplitCursor(_ terminalID: String) async {
        guard let document = splitDocuments[terminalID],
              let record = sessions.first(where: { $0.id == terminalID }),
              let scope = cursorScope(for: record),
              let cursor = document.cursor else { return }
        try? await cursorStore.save(cursor, for: scope)
    }

    private func applyActivity(busy: Bool, completedAt: Int64?, to terminalID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == terminalID }) else { return }
        let wasWorking = { if case .working = sessions[index].agentActivity { return true }; return false }()
        if busy {
            sessions[index].agentActivity = .working
        } else if let completedAt {
            sessions[index].agentActivity = .responded(at: completedAt)
            // A working agent that settled while the user was elsewhere is a
            // needs-you moment.
            let appActive = NSApp?.isActive ?? true
            if wasWorking, selectedSessionID != terminalID || !appActive {
                AttentionCenter.shared.notify(
                    kind: .sessionResponded,
                    targetID: terminalID,
                    title: sessions[index].title,
                    detail: "Agent responded"
                )
            }
        } else {
            sessions[index].agentActivity = .idle
        }
    }

    private func connectionLost(_ error: any Error, generation: Int) {
        guard generation == connectionGeneration, shouldReconnect else { return }
        connectionState = .unavailable(error.kaisolaSafeDescription)
        Task { await clearSplits() }   // subscriptions died with the socket
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
