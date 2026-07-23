import AppKit
import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: NativePreviewSettings
    @State private var renameTarget: String?
    @State private var renameProjectTarget: String?
    @State private var renameText: String = ""
    @State private var gitRepo: URL?
    @State private var showPalette = false

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { model.selectedChatID ?? model.selectedSessionID },
            set: { id in
                if let id, id.hasPrefix("chat-") { model.selectChat(id) }
                else { model.selectChat(nil); Task { await model.select(id) } }
            }
        )
    }

    var body: some View {
        Group {
            switch settings.navigationLayout {
            case .leftTree: leftTreeLayout
            case .topBar: topBarLayout
            }
        }
        .preferredColorScheme(settings.appearance.colorScheme)
        .sheet(item: Binding(get: { renameTarget.map(RenameID.init) }, set: { renameTarget = $0?.id })) { target in
            RenameSheet(text: $renameText) { newTitle in
                model.renameSession(target.id, to: newTitle)
                renameTarget = nil
            } cancel: {
                renameTarget = nil
            }
            .onAppear {
                renameText = model.sessions.first(where: { $0.id == target.id })?.title ?? ""
            }
        }
        .sheet(item: Binding(get: { renameProjectTarget.map(RenameID.init) }, set: { renameProjectTarget = $0?.id })) { target in
            RenameSheet(text: $renameText, title: "Rename Project") { newName in
                model.renameProject(id: target.id, to: newName)
                renameProjectTarget = nil
            } cancel: {
                renameProjectTarget = nil
            }
        }
        .sheet(item: Binding(get: { gitRepo.map(GitRepoID.init) }, set: { gitRepo = $0?.url })) { repo in
            VStack(spacing: 0) {
                HStack {
                    Text(repo.url.lastPathComponent).font(.headline)
                    Spacer()
                    Button("Done") { gitRepo = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
                Divider()
                GitPanelView(repoRoot: repo.url)
                    .frame(width: 520, height: 460)
            }
        }
        .background(
            Button(action: { showPalette.toggle() }) { EmptyView() }
                .keyboardShortcut("k", modifiers: .command)
                .accessibilityLabel("Command Palette")
        )
        .overlay {
            if showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { showPalette = false }
                    CommandPaletteView(model: model, settings: settings, isPresented: $showPalette)
                        .padding(.top, 72)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Layouts

    /// Nested project→session tree in a left sidebar (the default).
    private var leftTreeLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                if !model.chats.isEmpty {
                    Section("Chats") {
                        ForEach(model.chats) { chat in
                            ChatRow(chat: chat)
                                .tag(Optional(chat.id))
                                .contextMenu {
                                    Button("Close Chat", role: .destructive) { model.closeChat(chat.id) }
                                }
                        }
                    }
                }
                ForEach(model.projects) { project in
                    Section {
                        ForEach(project.sessions) { session in
                            sessionRow(session)
                        }
                        if project.sessions.isEmpty {
                            Text("No sessions yet")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    } header: {
                        Text(project.name)
                            .contextMenu {
                                Button("Rename Project…") { renameProjectTarget = project.id; renameText = project.name }
                                Button("Close Project", role: .destructive) { model.closeProject(id: project.id) }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 235, max: 300)
            .safeAreaInset(edge: .bottom) { footer }
            .accessibilityLabel("Projects, chats, and terminal sessions")
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// A project tab strip over a session row, then the detail pane (Electron's
    /// "Top bar" mode).
    private var topBarLayout: some View {
        VStack(spacing: 0) {
            ProjectTabStrip(
                projects: model.projects,
                chatCount: model.chats.count,
                selected: activeProjectBinding,
                renameProject: { renameProjectTarget = $0; renameText = model.projects.first { $0.id == renameProjectTarget }?.name ?? "" },
                closeProject: { model.closeProject(id: $0) },
                openFolder: { RootShellView.promptForOpenFolder(model: model) }
            )
            Divider()
            SessionStrip(
                model: model,
                projectName: activeProjectName,
                rename: { renameTarget = $0 }
            )
            Divider()
            detailPane
            footer
        }
    }

    private var activeProjectName: String? {
        model.selectedProjectName ?? model.projects.first?.name
    }

    private var activeProjectBinding: Binding<String?> {
        Binding(get: { activeProjectName }, set: { model.selectedProjectName = $0 })
    }

    @ViewBuilder
    private func sessionRow(_ session: BrokerTerminalRecord) -> some View {
        SessionRow(
            session: session,
            owned: model.isOwned(session.id),
            agent: model.agentProfile(for: session.id)
        )
        .tag(Optional(session.id))
        .contextMenu {
            if model.isOwned(session.id) {
                Button("Rename…") { renameTarget = session.id }
                if let dir = model.directory(for: session.id) {
                    Button("Git Panel…") { gitRepo = dir }
                }
                if !session.exited {
                    Button("End Session", role: .destructive) {
                        Task { await model.endSession(session.id) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let chat = model.chats.first(where: { $0.id == model.selectedChatID }) {
            AcpChatView(conversation: chat.conversation)
                .id(chat.id)
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            VStack(spacing: 0) {
                StatusBar(
                    state: model.connectionState,
                    ownsSelection: model.selectedSessionID.map(model.isOwned) ?? false
                )
                Divider()
                terminalContent
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var footer: some View {
        ConnectionFooter(
            state: model.connectionState,
            canCreate: model.controlAvailable,
            reload: { Task { await model.reload() } },
            newTerminal: { RootShellView.promptForNewTerminal(model: model) },
            newAgent: { agent in RootShellView.promptForNewAgent(agent, model: model) },
            newChat: { agent in RootShellView.promptForNewChat(agent, model: model) }
        )
    }

    /// New owned shell in the active project (or a picked folder when there's no
    /// project context). Reused by the File menu and the sidebar button.
    @MainActor
    static func promptForNewTerminal(model: AppModel) {
        guard let directory = model.currentProjectDirectory
            ?? chooseDirectory(prompt: "Open Terminal Here", startingAt: model.currentProjectDirectory) else { return }
        Task { await model.createTerminal(inDirectory: directory) }
    }

    /// New agent session running the agent's CLI in the active project (or a
    /// picked folder).
    @MainActor
    static func promptForNewAgent(_ agent: AgentProfile, model: AppModel) {
        guard let directory = model.currentProjectDirectory
            ?? chooseDirectory(prompt: "Start \(agent.name) Here", startingAt: model.currentProjectDirectory) else { return }
        Task { await model.createAgentSession(agent, inDirectory: directory) }
    }

    /// Folder picker → open a folder as a project tab (no session yet). This one
    /// always prompts — its whole purpose is choosing a new folder.
    @MainActor
    static func promptForOpenFolder(model: AppModel) {
        guard let directory = chooseDirectory(prompt: "Open Project", startingAt: model.currentProjectDirectory) else { return }
        model.openProject(directory: directory)
    }

    /// New ACP chat with the agent in the active project (or a picked folder).
    @MainActor
    static func promptForNewChat(_ agent: AgentProfile, model: AppModel) {
        guard AcpAdapter.forAgent(agent.id) != nil else { return }
        guard let directory = model.currentProjectDirectory
            ?? chooseDirectory(prompt: "Chat with \(agent.name) Here", startingAt: model.currentProjectDirectory) else { return }
        model.openChat(agent, inDirectory: directory)
    }

    @MainActor
    private static func chooseDirectory(prompt: String, startingAt: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = "Choose the folder for the new session."
        if let startingAt { panel.directoryURL = startingAt }
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.first
    }

    /// The fresh/offline empty state: instead of a dead end, offer the first
    /// actions (start a shell, open a chat, open a folder) right where the user
    /// is looking.
    @ViewBuilder
    private var emptyWorkspaceState: some View {
        let chatAgent = AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil }
        ContentUnavailableView {
            Label("Nothing running yet", systemImage: "sparkles")
        } description: {
            Text("Start a terminal or an agent here. Existing Electron sessions appear automatically when its broker advertises observation.")
        } actions: {
            HStack(spacing: 10) {
                Button {
                    RootShellView.promptForNewTerminal(model: model)
                } label: {
                    Label("New Terminal", systemImage: "terminal")
                }
                if let chatAgent {
                    Button {
                        RootShellView.promptForNewChat(chatAgent, model: model)
                    } label: {
                        Label("Chat with \(chatAgent.name)", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                Button {
                    RootShellView.promptForOpenFolder(model: model)
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var terminalContent: some View {
        if let message = model.terminalDocument.errorMessage {
            ContentUnavailableView(
                "Terminal unavailable",
                systemImage: "terminal",
                description: Text(message)
            )
        } else if model.terminalDocument.sessionID == nil {
            if model.sessions.isEmpty {
                emptyWorkspaceState
            } else {
                ContentUnavailableView(
                    "Choose a terminal",
                    systemImage: "terminal",
                    description: Text("Pick a session from the sidebar to view its durable output.")
                )
            }
        } else {
            let sessionID = model.terminalDocument.sessionID
            let owned = sessionID.map(model.isOwned) ?? false
            ZStack(alignment: .topTrailing) {
                NativeTerminalSurface(
                    output: model.terminalDocument.output,
                    streamEpoch: model.terminalDocument.cursor?.streamEpoch,
                    endOffset: model.terminalDocument.cursor?.offset,
                    isOwned: owned,
                    onInput: owned ? { data in
                        guard let sessionID else { return }
                        model.sendInput(data, to: sessionID)
                    } : nil,
                    onResize: owned ? { columns, rows in
                        guard let sessionID else { return }
                        model.resizeTerminal(sessionID, columns: columns, rows: rows)
                    } : nil
                )
                .id("\(sessionID ?? "none")-\(owned)")
                if model.terminalDocument.truncated {
                    Label("Retained tail", systemImage: "ellipsis.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .accessibilityLabel("Older terminal output was outside the retained history")
                }
            }
        }
    }
}

/// A horizontal strip of project tabs plus a Chats pill, for the top-bar
/// layout. Clicking a tab makes it the active project.
private struct ProjectTabStrip: View {
    let projects: [AppModel.ProjectGroup]
    let chatCount: Int
    @Binding var selected: String?
    let renameProject: (String) -> Void
    let closeProject: (String) -> Void
    let openFolder: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if chatCount > 0 {
                    Label("\(chatCount) Chats", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
                ForEach(projects) { project in
                    Button {
                        selected = project.name
                    } label: {
                        Text(project.name)
                            .font(.callout.weight(selected == project.name ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                selected == project.name ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename Project…") { renameProject(project.id) }
                        Button("Close Project", role: .destructive) { closeProject(project.id) }
                    }
                }
                Button(action: openFolder) {
                    Image(systemName: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .help("Open a folder as a project (⌘O)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 40)
    }
}

/// The session row for the active project, in the top-bar layout.
private struct SessionStrip: View {
    @ObservedObject var model: AppModel
    let projectName: String?
    let rename: (String) -> Void

    private var sessions: [BrokerTerminalRecord] {
        model.projects.first { $0.name == projectName }?.sessions ?? []
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if sessions.isEmpty {
                    Text("No sessions in this project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
                ForEach(sessions) { session in
                    Button {
                        model.selectChat(nil)
                        Task { await model.select(session.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.agentProfile(for: session.id)?.symbol
                                ?? (model.isOwned(session.id) ? "terminal.fill" : "terminal"))
                            Text(session.title).lineLimit(1)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            model.selectedSessionID == session.id
                                ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if model.isOwned(session.id) {
                            Button("Rename…") { rename(session.id) }
                            if !session.exited {
                                Button("End Session", role: .destructive) {
                                    Task { await model.endSession(session.id) }
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 40)
    }
}

private struct ChatRow: View {
    @ObservedObject var conversation: AcpConversation

    init(chat: AcpChatHandle) {
        self.conversation = chat.conversation
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(conversation.isConnected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title).lineLimit(1)
                Text(conversation.isRunning ? "Working…" : conversation.isConnected ? "Chat" : "Starting…")
                    .font(.caption)
                    .foregroundStyle(conversation.isRunning ? Color.accentColor : .secondary)
            }
            if conversation.isRunning {
                Spacer()
                ProgressView().controlSize(.mini).scaleEffect(0.6)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Identifiable wrapper so a session id can drive a `.sheet(item:)`.
private struct RenameID: Identifiable { let id: String }

/// Identifiable wrapper so a repo URL can drive a `.sheet(item:)`.
private struct GitRepoID: Identifiable { let url: URL; var id: String { url.path } }

private struct RenameSheet: View {
    @Binding var text: String
    var title: String = "Rename Session"
    let commit: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { commit(text) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                Button("Rename") { commit(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct SessionRow: View {
    let session: BrokerTerminalRecord
    let owned: Bool
    let agent: AgentProfile?

    var body: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: rowSymbol)
                    .foregroundStyle(iconColor)
                if case .working = session.agentActivity, !session.exited {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(sessionDetail)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(sessionDetail)
    }

    private var rowSymbol: String {
        if let agent { return agent.symbol }
        return owned ? "terminal.fill" : "terminal"
    }

    private var iconColor: Color {
        if session.exited { return .secondary }
        if agent != nil { return .accentColor }
        return owned ? .accentColor : .green
    }

    private var sessionDetail: String {
        if session.exited { return "Finished" }
        if agent != nil {
            switch session.agentActivity {
            case .working: return "Working…"
            case .responded: return "Responded"
            case .idle: return owned ? "Ready" : "Ready · observed"
            }
        }
        let liveDetail = "Live · PID \(session.pid.map(String.init) ?? "—")"
        return owned ? liveDetail : "\(liveDetail) · observed"
    }

    private var statusColor: Color {
        if case .working = session.agentActivity, !session.exited { return .accentColor }
        return .secondary
    }
}

private struct StatusBar: View {
    let state: AppModel.ConnectionState
    let ownsSelection: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.isConnected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(state.title)
                .font(.subheadline.weight(.medium))
            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if ownsSelection {
                Label("Interactive", systemImage: "keyboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("This terminal accepts keyboard input")
            } else {
                Label("Read only", systemImage: "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Terminal access is read only")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
}

private struct ConnectionFooter: View {
    let state: AppModel.ConnectionState
    let canCreate: Bool
    let reload: () -> Void
    let newTerminal: () -> Void
    let newAgent: (AgentProfile) -> Void
    let newChat: (AgentProfile) -> Void

    private var chatAgents: [AgentProfile] {
        AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Native preview")
                    .font(.caption.weight(.semibold))
                Text(state.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canCreate {
                Menu {
                    ForEach(chatAgents) { agent in
                        Button {
                            newChat(agent)
                        } label: {
                            Label("Chat with \(agent.name)", systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                    Divider()
                    Button {
                        newTerminal()
                    } label: {
                        Label("New Terminal", systemImage: "terminal")
                    }
                    ForEach(AgentRegistry.all) { agent in
                        Button {
                            newAgent(agent)
                        } label: {
                            Label("New \(agent.name) Agent (Terminal)", systemImage: agent.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New chat or session")
                .accessibilityLabel("New session")
            }
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reconnect without changing terminal ownership")
            .accessibilityLabel("Reconnect to terminal broker")
        }
        .padding(12)
        .background(.bar)
    }
}
