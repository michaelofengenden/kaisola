import AppKit
import Combine
import SwiftUI

struct RootShellView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: NativePreviewSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var renameTarget: String?
    @State private var renameProjectTarget: String?
    @State private var renameText: String = ""
    @State private var gitRepo: URL?
    @State private var showPalette = false
    @State private var showOmniBar = false
    @State private var showOnboarding = false
    @State private var showSettings = false
    /// A Close Mesh request whose worktrees still hold uncommitted changes.
    @State private var meshCloseConfirm: (id: String, dirty: Int)?

    /// Close immediately when every column is clean; confirm when closing
    /// would destroy uncommitted agent work in the worktrees.
    private func requestCloseMesh(_ mesh: MeshSession) {
        Task {
            let dirty = await mesh.dirtyColumnCount()
            if dirty == 0 {
                model.closeMesh(mesh.id)
            } else {
                meshCloseConfirm = (mesh.id, dirty)
            }
        }
    }

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { model.selectedChatID ?? model.selectedMeshID ?? model.selectedSessionID },
            set: { id in
                if let id, id.hasPrefix("chat-") { model.selectChat(id) }
                else if let id, id.hasPrefix("mesh-") { model.selectMesh(id) }
                else { model.selectChat(nil); model.selectMesh(nil); Task { await model.select(id) } }
            }
        )
    }

    var body: some View {
        chromeDecorated
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaOpenFileLink)) { note in
                guard let url = note.userInfo?["url"] as? URL else { return }
                model.previewedFileLine = note.userInfo?["line"] as? Int
                model.previewedFileURL = url
            }
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaOpenBrowserCard)) { note in
                guard let url = note.object as? URL else { return }
                model.previewedFileURL = nil
                model.selectedMeshID = nil
                model.browserCardURL = url
            }
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaAttentionJump)) { note in
                if let targetID = note.userInfo?[NotificationBridge.targetIDKey] as? String {
                    model.jumpToAttentionTarget(targetID)
                }
            }
            .onAppear {
                if OnboardingState.shouldShow() { showOnboarding = true }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView {
                    OnboardingState.markSeen()
                    showOnboarding = false
                }
                .frame(width: 640, height: 460)
            }
    }

    /// The layout plus its sheets — split from `body` so the modifier chain
    /// stays within the type-checker's budget.
    private var sheeted: some View {
        Group {
            switch settings.navigationLayout {
            case .leftTree: leftTreeLayout
            case .topBar: topBarLayout
            }
        }
        .preferredColorScheme(settings.appearance.colorScheme)
        .background {
            WorkspaceBackdropView(mode: settings.workspaceBackdrop)
                .ignoresSafeArea()
        }
        .sheet(item: Binding(get: { renameTarget.map(RenameID.init) }, set: { renameTarget = $0?.id })) { target in
            RenameSheet(text: $renameText) { newTitle in
                model.renameSession(target.id, to: newTitle)
                renameTarget = nil
            } cancel: {
                renameTarget = nil
            }
            .onAppear {
                renameText = model.editableSessionTitle(for: target.id)
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
        .sheet(isPresented: $showSettings) {
            InAppSettingsSheet(
                settings: settings,
                workspace: model.currentProjectDirectory,
                dismiss: { showSettings = false }
            )
        }
    }

    /// Shortcuts, overlays, toasts, and the Mesh-close dialog over `sheeted`.
    private var chromeDecorated: some View {
        sheeted
        .background(
            Group {
                Button(action: { showPalette.toggle() }) { EmptyView() }
                    .keyboardShortcut("k", modifiers: .command)
                    .accessibilityLabel("Command Palette")
                Button(action: { settings.workspaceRailVisible.toggle() }) { EmptyView() }
                    .keyboardShortcut("b", modifiers: .command)
                    .accessibilityLabel("Toggle Workspace Rail")
                Button(action: { showOmniBar.toggle() }) { EmptyView() }
                    .keyboardShortcut("l", modifiers: .command)
                    .accessibilityLabel("Message Current Agent")
                Button(action: {
                    if let target = model.previewedFileURL ?? model.currentProjectDirectory {
                        settings.openInExternalEditor(target)
                    }
                }) { EmptyView() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .accessibilityLabel("Open in External Editor")
            }
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
            if showOmniBar {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { showOmniBar = false }
                    OmniBarView(model: model, isPresented: $showOmniBar)
                        .padding(.top, 72)
                }
                .transition(.opacity)
            }
        }
        .overlay { ToastOverlayView() }
        .confirmationDialog(
            "Close Mesh?",
            isPresented: Binding(get: { meshCloseConfirm != nil }, set: { if !$0 { meshCloseConfirm = nil } })
        ) {
            Button("Discard and Close", role: .destructive) {
                if let confirm = meshCloseConfirm { model.closeMesh(confirm.id) }
                meshCloseConfirm = nil
            }
            Button("Cancel", role: .cancel) { meshCloseConfirm = nil }
        } message: {
            Text("\(meshCloseConfirm?.dirty ?? 0) column(s) have uncommitted changes in their worktrees. Closing discards that work permanently — integrate what you want to keep first (Diff → apply/commit).")
        }
    }

    // MARK: - Layouts

    /// Nested project→session tree in a left sidebar (the default).
    private var leftTreeLayout: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(model.projects) { project in
                    let chats = model.chats(in: project.id)
                    let meshes = model.meshes(in: project.id)
                    Section(isExpanded: expansionBinding(project.id)) {
                        if !chats.isEmpty {
                            ProjectSurfaceHeader(title: "Chats", systemImage: "bubble.left.and.text.bubble.right")
                            ForEach(chats) { chat in
                                ChatRow(chat: chat)
                                    .tag(Optional(chat.id))
                                    .contextMenu {
                                        Button("Close Chat", role: .destructive) { model.closeChat(chat.id) }
                                    }
                            }
                        }
                        if !meshes.isEmpty {
                            ProjectSurfaceHeader(title: "Mesh", systemImage: "circle.hexagongrid.fill")
                            ForEach(meshes) { mesh in
                                MeshRow(mesh: mesh)
                                    .tag(Optional(mesh.id))
                                    .contextMenu {
                                        Button("Close Mesh", role: .destructive) { requestCloseMesh(mesh) }
                                    }
                            }
                        }
                        if !project.sessions.isEmpty {
                            ProjectSurfaceHeader(title: "Sessions", systemImage: "terminal")
                            ForEach(project.sessions) { session in
                                sessionRow(session)
                            }
                        }
                        if project.sessions.isEmpty, chats.isEmpty, meshes.isEmpty {
                            Text("No activity yet")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    } header: {
                        HStack(spacing: 5) {
                            Button {
                                model.activateProject(id: project.id)
                            } label: {
                                HStack(spacing: 6) {
                                    if let tint = ProjectTint.color(project.colorHex) {
                                        Circle().fill(tint).frame(width: 8, height: 8)
                                    } else {
                                        Image(systemName: "folder.fill")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(project.name)
                                    if project.workingCount > 0 {
                                        Text("\(project.workingCount)")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.9), in: Capsule())
                                            .foregroundStyle(.white)
                                            .accessibilityLabel("\(project.workingCount) agents working")
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(project.name) project")
                            Menu {
                                projectLaunchMenu(project)
                            } label: {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("New session in \(project.name)")
                        }
                        .padding(.vertical, 2)
                        .background(
                            activeProjectID == project.id
                                ? AnyShapeStyle(Color.accentColor.opacity(0.10))
                                : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .contextMenu { projectContextMenu(project) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background {
                SidebarBackdropView(appearance: settings.sidebarAppearance)
                    .ignoresSafeArea()
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 235, max: 300)
            .safeAreaInset(edge: .top, spacing: 0) {
                projectSidebarHeader
            }
            .safeAreaInset(edge: .bottom) { footer }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.85))
                    .frame(width: 1)
                    .shadow(color: .black.opacity(0.14), radius: 2, x: 1)
            }
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
            ProjectTabStripView(
                projects: model.projects,
                selected: activeProjectBinding,
                menu: { project in AnyView(self.projectContextMenu(project)) },
                openFolder: { RootShellView.promptForOpenFolder(model: model) },
                reorder: { model.moveProject(id: $0, toIndex: $1) }
            )
            Divider()
            if let active = model.projects.first(where: { $0.id == activeProjectID }),
               let activeDir = active.directory {
                QuickActionsBar(projectID: active.id, projectName: active.name) { action in
                    Task { await model.runQuickAction(action, inProject: activeDir) }
                }
                Divider()
            }
            SessionStrip(
                model: model,
                projectID: activeProjectID,
                rename: { renameTarget = $0 },
                closeMesh: requestCloseMesh
            )
            Divider()
            detailPane
            footer
        }
    }

    private var activeProjectName: String? {
        model.projects.first(where: { $0.id == activeProjectID })?.name
            ?? model.selectedProjectName
            ?? model.projects.first?.name
    }

    private var activeProjectID: String? {
        model.selectedProjectID
            ?? model.selectedProjectName.flatMap { name in model.projects.first(where: { $0.name == name })?.id }
            ?? model.projects.first?.id
    }

    private var activeProjectBinding: Binding<String?> {
        Binding(get: { activeProjectID }, set: { model.activateProject(id: $0) })
    }

    private var projectSidebarHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Projects", systemImage: "folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    RootShellView.promptForOpenFolder(model: model)
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Open project folder")
                Menu {
                    if splitCandidates.isEmpty {
                        Button("No other live sessions") {}.disabled(true)
                    } else {
                        ForEach(splitCandidates) { session in
                            Button {
                                Task { await model.openInSplit(session.id) }
                            } label: {
                                Label(model.sessionTitle(for: session), systemImage: "terminal")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.terminalDocument.sessionID == nil || model.splitOrder.count >= AppModel.maxSplitPanes)
                .help("Open another session beside this one")
                Button {
                    settings.workspaceRailVisible.toggle()
                } label: {
                    Image(systemName: settings.workspaceRailVisible ? "sidebar.left" : "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help(settings.workspaceRailVisible ? "Hide file browser (Command-B)" : "Show file browser (Command-B)")
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Open in-app settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
        }
        .background(.bar)
    }

    /// Collapsed project sections, persisted per project id.
    @AppStorage("collapsedProjects") private var collapsedProjectsRaw = ""

    private func expansionBinding(_ projectID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedProjectsRaw.components(separatedBy: ",").contains(projectID) },
            set: { expanded in
                var set = Set(collapsedProjectsRaw.components(separatedBy: ",").filter { !$0.isEmpty })
                if expanded { set.remove(projectID) } else { set.insert(projectID) }
                collapsedProjectsRaw = set.sorted().joined(separator: ",")
            }
        )
    }

    /// The shared project context menu: rename, tint, reorder, relocate, close.
    @ViewBuilder
    func projectContextMenu(_ project: AppModel.ProjectGroup) -> some View {
        projectLaunchMenu(project)
        Divider()
        Button("Rename Project…") { renameProjectTarget = project.id; renameText = project.name }
        Menu("Color") {
            Button("None") { model.setProjectColor(id: project.id, colorHex: nil) }
            ForEach(ProjectTint.choices, id: \.hex) { choice in
                Button(choice.name) { model.setProjectColor(id: project.id, colorHex: choice.hex) }
            }
        }
        Button("Move Left") { model.moveProject(id: project.id, delta: -1) }
        Button("Move Right") { model.moveProject(id: project.id, delta: 1) }
        Button("Relocate…") {
            if let directory = Self.chooseDirectoryForRelocate() {
                model.relocateProject(id: project.id, to: directory)
            }
        }
        Divider()
        Button("Close Project", role: .destructive) { model.closeProject(id: project.id) }
    }

    /// Session creation is anchored to the project whose menu was clicked — it
    /// never falls back to whichever project happened to be selected before the
    /// click. This is the Electron workflow for running different CLIs in
    /// different folders without reopening a folder picker each time.
    @ViewBuilder
    private func projectLaunchMenu(_ project: AppModel.ProjectGroup) -> some View {
        if let directory = project.directory {
            Button {
                model.activateProject(id: project.id)
                Task { await model.createTerminal(inDirectory: directory) }
            } label: {
                Label("New Terminal", systemImage: "terminal")
            }
            ForEach(AgentRegistry.all) { agent in
                Button {
                    model.activateProject(id: project.id)
                    Task { await model.createAgentSession(agent, inDirectory: directory) }
                } label: {
                    Label("New \(agent.name) Terminal", systemImage: agent.symbol)
                }
            }
            Divider()
            ForEach(AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil }) { agent in
                Button {
                    model.activateProject(id: project.id)
                    model.openChat(agent, inDirectory: directory)
                } label: {
                    Label("Chat with \(agent.name)", systemImage: "bubble.left.and.bubble.right")
                }
            }
            Button {
                model.activateProject(id: project.id)
                model.openMesh(inDirectory: directory)
            } label: {
                Label("New Mesh", systemImage: "circle.hexagongrid.fill")
            }
        } else {
            Button("Folder unavailable") {}.disabled(true)
        }
    }

    @MainActor
    static func chooseDirectoryForRelocate() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Relocate Project"
        panel.message = "Choose the folder this project moved to."
        guard panel.runModal() == .OK else { return nil }
        return panel.urls.first
    }

    @ViewBuilder
    private func sessionRow(_ session: BrokerTerminalRecord) -> some View {
        SessionRow(
            session: session,
            title: model.sessionTitle(for: session),
            owned: model.isOwned(session.id),
            agent: model.agentProfile(for: session.id),
            branch: model.branch(for: session.id),
            meta: model.meta(for: session.id),
            canOpenSplit: session.id != model.selectedSessionID
                && model.splitDocuments[session.id] == nil
                && model.splitOrder.count < AppModel.maxSplitPanes,
            isOpenInSplit: model.splitDocuments[session.id] != nil,
            toggleSplit: {
                if model.splitDocuments[session.id] != nil {
                    Task { await model.closeSplit(session.id) }
                } else {
                    Task { await model.openInSplit(session.id) }
                }
            }
        )
        .tag(Optional(session.id))
        .contextMenu {
            Button("Open in New Window") {
                KaisolaMacAppDelegate.popOut(sessionID: session.id)
            }
            Button {
                model.togglePin(session.id)
            } label: {
                Label(model.isPinned(session.id) ? "Unpin" : "Pin",
                      systemImage: model.isPinned(session.id) ? "pin.slash" : "pin")
            }
            if session.id != model.selectedSessionID,
               model.splitDocuments[session.id] == nil,
               model.splitOrder.count < AppModel.maxSplitPanes {
                Button("Open in Split") {
                    Task { await model.openInSplit(session.id) }
                }
            }
            if model.splitDocuments[session.id] != nil {
                Button("Close Split") {
                    Task { await model.closeSplit(session.id) }
                }
            }
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
        HSplitView {
            detailContent
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            if settings.workspaceRailVisible, let root = model.currentProjectDirectory {
                // Files live on the right, matching the editor/reference rail in
                // the Electron workspace and leaving the project hierarchy as the
                // sole navigation surface on the left.
                WorkspaceRailView(
                    root: root,
                    openFile: { model.previewedFileURL = $0 },
                    close: { settings.workspaceRailVisible = false }
                )
                .id(root)
            }
        }
    }

    private var splitCandidates: [BrokerTerminalRecord] {
        let primaryID = model.terminalDocument.sessionID
        let sessions = model.projects.first(where: { $0.id == activeProjectID })?.sessions ?? model.sessions
        return sessions.filter {
            !$0.exited && $0.id != primaryID && model.splitDocuments[$0.id] == nil
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let fileURL = model.previewedFileURL {
            FilePreviewView(url: fileURL, workspaceRoot: model.currentProjectDirectory) {
                model.previewedFileURL = nil
            }
        } else if let mesh = model.meshes.first(where: { $0.id == model.selectedMeshID }) {
            MeshView(mesh: mesh)
                .id(mesh.id)
        } else if let chat = model.chats.first(where: { $0.id == model.selectedChatID }) {
            AcpChatView(conversation: chat.conversation)
                .id(chat.id)
                .background { WorkspaceBackdropView(mode: settings.workspaceBackdrop) }
        } else {
            terminalContent
                .background { WorkspaceBackdropView(mode: settings.workspaceBackdrop) }
        }
    }

    private var footer: some View {
        ConnectionFooter(
            state: model.connectionState,
            canCreate: model.controlAvailable,
            reload: { Task { await model.reload() } },
            newTerminal: { RootShellView.promptForNewTerminal(model: model) },
            newAgent: { agent in RootShellView.promptForNewAgent(agent, model: model) },
            newChat: { agent in RootShellView.promptForNewChat(agent, model: model) },
            jumpToAttention: { model.jumpToAttentionTarget($0) },
            newMesh: { RootShellView.promptForNewMesh(model: model) },
            newStagedMesh: { RootShellView.promptForNewMesh(model: model, staged: true) },
            newIdeaMesh: { RootShellView.promptForNewMesh(model: model, idea: true) }
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

    /// New Mesh in the active project (or a picked folder): every ACP-capable
    /// agent, each in an isolated worktree when the folder is a git repo.
    @MainActor
    static func promptForNewMesh(model: AppModel, staged: Bool = false, idea: Bool = false) {
        guard let directory = model.currentProjectDirectory
            ?? chooseDirectory(prompt: "Run Mesh Here", startingAt: model.currentProjectDirectory) else { return }
        model.openMesh(inDirectory: directory, staged: staged, idea: idea)
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
            Text(model.controlAvailable
                ? "Start a terminal or an agent here. Existing Electron sessions appear automatically when its broker advertises observation."
                : "Chats and Mesh are ready. Terminals need a broker that accepts native control — this connection doesn't, so terminal creation is disabled.")
        } actions: {
            HStack(spacing: 10) {
                Button {
                    RootShellView.promptForNewTerminal(model: model)
                } label: {
                    Label("New Terminal", systemImage: "terminal")
                }
                .disabled(!model.controlAvailable)
                .help(model.controlAvailable ? "Open a shell in the active project" : "The connected broker doesn't accept native control")
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
            terminalPaneGrid
        }
    }

    private var paneIDs: [String] {
        guard let primaryID = model.terminalDocument.sessionID else { return [] }
        return [primaryID] + model.splitOrder
    }

    /// One session stays completely clean. Two sessions split side-by-side;
    /// three or four balance into a resizable two-column grid instead of
    /// squeezing every terminal into an unreadable horizontal strip.
    private var terminalPaneGrid: some View {
        let columns = TerminalPaneGrid.columns(for: paneIDs)
        return GeometryReader { geometry in
            let dividerWidth: CGFloat = columns.count > 1 ? 1 : 0
            let availableWidth = max(0, geometry.size.width - dividerWidth * CGFloat(columns.count - 1))
            let columnWidth = columns.isEmpty ? 0 : availableWidth / CGFloat(columns.count)
            HStack(spacing: 0) {
                ForEach(columns.indices, id: \.self) { columnIndex in
                    terminalColumn(columns[columnIndex])
                        .frame(width: columnWidth, height: geometry.size.height)
                    if columnIndex < columns.count - 1 {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: dividerWidth)
                    }
                }
            }
        }
    }

    /// Equal geometry is intentional: SwiftUI split views persist stale divider
    /// positions across minimize/zoom/remount and were reopening a two-pane view
    /// at roughly 2/3 + 1/3. A deterministic grid always starts and remains at
    /// the visual midpoint, while SwiftTerm receives one coherent resize per
    /// pane instead of a cascade of intermediate sizes.
    private func terminalColumn(_ ids: [String]) -> some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = ids.count > 1 ? 1 : 0
            let availableHeight = max(0, geometry.size.height - dividerHeight * CGFloat(ids.count - 1))
            let paneHeight = ids.isEmpty ? 0 : availableHeight / CGFloat(ids.count)
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    terminalPane(id)
                        .frame(width: geometry.size.width, height: paneHeight)
                    if index < ids.count - 1 {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: dividerHeight)
                    }
                }
            }
        }
    }

    private func terminalPane(_ id: String) -> some View {
        let isPrimary = id == model.terminalDocument.sessionID
        return VStack(spacing: 0) {
            if paneIDs.count > 1 {
                HStack(spacing: 7) {
                    Image(systemName: model.agentProfile(for: id)?.symbol ?? "terminal")
                        .foregroundStyle(isPrimary ? Color.accentColor : .secondary)
                    Text(model.sessionTitle(for: id))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if model.isOwned(id) {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("VIEW")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        KaisolaMacAppDelegate.popOut(sessionID: id)
                    } label: {
                        Image(systemName: "macwindow.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Open this session in a new window")
                    if !isPrimary {
                        Button {
                            Task { await model.promoteSplit(id) }
                        } label: {
                            Image(systemName: "arrow.up.left")
                        }
                        .buttonStyle(.borderless)
                        .help("Make this the primary session")
                        Button {
                            Task { await model.closeSplit(id) }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Close pane; keep the session running")
                        .accessibilityLabel("Close \(model.sessionTitle(for: id)) pane")
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(.bar)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.7)).frame(height: 1)
                }
            }
            if isPrimary {
                primaryPane
            } else {
                splitPane(id)
            }
        }
        .frame(minWidth: 240, idealWidth: 480, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
    }

    private var primaryPane: some View {
        let sessionID = model.terminalDocument.sessionID
        let owned = sessionID.map(model.isOwned) ?? false
        return ZStack(alignment: .topTrailing) {
            NativeTerminalSurface(
                output: model.terminalDocument.output,
                streamEpoch: model.terminalDocument.cursor?.streamEpoch,
                endOffset: model.terminalDocument.cursor?.offset,
                isOwned: owned,
                fontSize: settings.terminalFontSize,
                fontFamily: settings.terminalFontFamily,
                fontWeight: settings.terminalFontWeight,
                paletteMode: settings.terminalPalette,
                lightSurface: colorScheme == .light,
                onInput: owned ? { data in
                    guard let sessionID else { return }
                    model.sendInput(data, to: sessionID)
                } : nil,
                onResize: owned ? { columns, rows in
                    guard let sessionID else { return }
                    model.resizeTerminal(sessionID, columns: columns, rows: rows)
                } : nil,
                onTitleChange: owned ? { title in
                    guard let sessionID else { return }
                    model.applyAutoTitle(title, to: sessionID)
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

    @ViewBuilder
    private func splitPane(_ splitID: String) -> some View {
        if let document = model.splitDocuments[splitID] {
            let owned = model.isOwned(splitID)
            NativeTerminalSurface(
                output: document.output,
                streamEpoch: document.cursor?.streamEpoch,
                endOffset: document.cursor?.offset,
                isOwned: owned,
                fontSize: settings.terminalFontSize,
                fontFamily: settings.terminalFontFamily,
                fontWeight: settings.terminalFontWeight,
                paletteMode: settings.terminalPalette,
                lightSurface: colorScheme == .light,
                onInput: owned ? { data in model.sendInput(data, to: splitID) } : nil,
                onResize: owned ? { columns, rows in model.resizeTerminal(splitID, columns: columns, rows: rows) } : nil,
                onTitleChange: owned ? { title in model.applyAutoTitle(title, to: splitID) } : nil
            )
            .id("split-\(splitID)-\(owned)")
        }
    }
}

/// Settings lives inside the workspace as a sheet so discoverability no longer
/// depends on knowing the macOS menu shortcut. The traditional Command-comma
/// settings window remains available too.
private struct InAppSettingsSheet: View {
    @ObservedObject var settings: NativePreviewSettings
    let workspace: URL?
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Settings")
                        .font(.title3.weight(.semibold))
                    Text("Everything applies instantly")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismiss) {
                    HStack(spacing: 6) {
                        Text("Done")
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.quaternary.opacity(0.55), in: Capsule())
                }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .background(.ultraThinMaterial)
            Divider()
            SettingsView(
                settings: settings,
                checkForUpdates: {
                    NotificationCenter.default.post(name: .kaisolaCheckForUpdates, object: nil)
                },
                workspace: workspace
            )
        }
        .background {
            WorkspaceBackdropView(mode: settings.workspaceBackdrop)
                .ignoresSafeArea()
        }
    }
}

/// Pure layout policy for the terminal card grid. Kept separate from SwiftUI so
/// pane balancing stays deterministic and directly testable.
enum TerminalPaneGrid {
    static func columns(for ids: [String]) -> [[String]] {
        guard ids.count > 2 else { return ids.map { [$0] } }
        let midpoint = (ids.count + 1) / 2
        return [
            Array(ids[..<midpoint]),
            Array(ids[midpoint...]),
        ]
    }
}

/// Every live surface for the active project, in the top-bar layout. Chats and
/// Mesh runs intentionally share this row with terminals so project tabs are a
/// real workspace boundary rather than decoration.
private struct SessionStrip: View {
    @ObservedObject var model: AppModel
    let projectID: String?
    let rename: (String) -> Void
    let closeMesh: (MeshSession) -> Void

    private var project: AppModel.ProjectGroup? {
        model.projects.first { $0.id == projectID }
    }

    private var sessions: [BrokerTerminalRecord] { project?.sessions ?? [] }
    private var chats: [AcpChatHandle] {
        project.map { model.chats(in: $0.id) } ?? []
    }
    private var meshes: [MeshSession] {
        project.map { model.meshes(in: $0.id) } ?? []
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if sessions.isEmpty, chats.isEmpty, meshes.isEmpty {
                    Text("No activity in this project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
                ForEach(chats) { chat in
                    Button { model.selectChat(chat.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                            Text(chat.conversation.title).lineLimit(1)
                            if chat.conversation.isRunning {
                                ProgressView().controlSize(.mini).scaleEffect(0.55)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            model.selectedChatID == chat.id
                                ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Close Chat", role: .destructive) { model.closeChat(chat.id) }
                    }
                }
                ForEach(meshes) { mesh in
                    Button { model.selectMesh(mesh.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.hexagongrid.fill")
                                .foregroundStyle(.purple)
                            Text(mesh.title).lineLimit(1)
                            if mesh.stage != "Idle" {
                                Text(mesh.stage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            model.selectedMeshID == mesh.id
                                ? AnyShapeStyle(Color.purple.opacity(0.14)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Close Mesh", role: .destructive) { closeMesh(mesh) }
                    }
                }
                ForEach(sessions) { session in
                    Button {
                        model.selectChat(nil)
                        Task { await model.select(session.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.agentProfile(for: session.id)?.symbol
                                ?? (model.isOwned(session.id) ? "terminal.fill" : "terminal"))
                            Text(model.sessionTitle(for: session)).lineLimit(1)
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

private struct MeshRow: View {
    @ObservedObject var mesh: MeshSession

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "circle.hexagongrid.fill")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(mesh.title).lineLimit(1)
                Text(mesh.stage == "Idle" ? "Ready" : mesh.stage)
                    .font(.caption)
                    .foregroundStyle(mesh.stage == "Idle" ? Color.secondary : Color.purple)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectSurfaceHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
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
    let title: String
    let owned: Bool
    let agent: AgentProfile?
    var branch: String?
    var meta: TerminalMeta?
    let canOpenSplit: Bool
    let isOpenInSplit: Bool
    let toggleSplit: () -> Void

    var body: some View {
        HStack(spacing: 9) {
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
                    Text(title)
                        .lineLimit(1)
                    Text(sessionDetail)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(sessionDetail)
            Spacer(minLength: 4)
            if canOpenSplit || isOpenInSplit {
                Button(action: toggleSplit) {
                    Image(systemName: isOpenInSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        .font(.caption)
                        .foregroundStyle(isOpenInSplit ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isOpenInSplit ? "Close this pane; keep the session running" : "Open beside the current session")
                .accessibilityLabel(isOpenInSplit ? "Close \(title) pane" : "Open \(title) in another pane")
            }
        }
        .padding(.vertical, 2)
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
        var detail: String
        if session.exited {
            detail = "Finished"
        } else if agent != nil {
            switch session.agentActivity {
            case .working: detail = "Working…"
            case .responded: detail = "Responded"
            case .idle: detail = owned ? "Ready" : "Ready · observed"
            }
        } else {
            let liveDetail = "Live · PID \(session.pid.map(String.init) ?? "—")"
            detail = owned ? liveDetail : "\(liveDetail) · observed"
        }
        if let branch, !session.exited { detail += " · ⎇ \(branch)" }
        if let meta, !session.exited {
            if let name = meta.processName { detail += " · \(name)" }
            if !meta.ports.isEmpty { detail += " · :" + meta.ports.map(String.init).joined(separator: ",") }
        }
        return detail
    }

    private var statusColor: Color {
        if case .working = session.agentActivity, !session.exited { return .accentColor }
        return .secondary
    }
}

private struct ConnectionFooter: View {
    let state: AppModel.ConnectionState
    let canCreate: Bool
    let reload: () -> Void
    let newTerminal: () -> Void
    let newAgent: (AgentProfile) -> Void
    let newChat: (AgentProfile) -> Void
    var jumpToAttention: ((String) -> Void)?
    var newMesh: (() -> Void)?
    var newStagedMesh: (() -> Void)?
    var newIdeaMesh: (() -> Void)?

    @ObservedObject private var usage = UsageCenter.shared

    @ObservedObject private var attention = AttentionCenter.shared
    @State private var showInbox = false

    private var chatAgents: [AgentProfile] {
        AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kaisola")
                    .font(.caption.weight(.semibold))
                Text(state.detail ?? state.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if usage.totalPeakTokens > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    Text("\(usage.totalPeakTokens / 1000)k").monospacedDigit()
                    Text("· \(Int((usage.contextPressure * 100).rounded()))%")
                        .foregroundStyle(usage.contextPressure >= 0.85 ? .orange : .secondary)
                }
                .font(.caption)
                .help("Session tokens (peak) · highest context pressure")
            }
            if newMesh != nil || newStagedMesh != nil || newIdeaMesh != nil {
                Menu {
                    if let newMesh { Button("New Mesh (all agents)", action: newMesh) }
                    if let newStagedMesh { Button("New Staged Mesh (scout → execute)", action: newStagedMesh) }
                    if let newIdeaMesh { Button("New Idea Mesh (brainstorm)", action: newIdeaMesh) }
                } label: {
                    Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.purple)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New Mesh — flat, staged, or idea")
            }
            if attention.count > 0 {
                Button {
                    showInbox.toggle()
                } label: {
                    Label("\(attention.count)", systemImage: "bell.badge.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Needs you — permission asks and finished agents")
                .popover(isPresented: $showInbox, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(attention.entries.reversed()) { entry in
                            Button {
                                showInbox = false
                                jumpToAttention?(entry.targetID)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.kind == .permission ? "hand.raised.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(entry.kind == .permission ? Color.orange : .green)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.title).font(.callout).lineLimit(1)
                                        Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        Divider()
                        Button("Clear All") { attention.clearAll(); showInbox = false }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .padding(8)
                    }
                    .frame(width: 300)
                    .padding(.vertical, 6)
                }
            }
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
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}
