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
    @State private var quickActionsTarget: QuickActionsTarget?
    @State private var workspaceRailDragOrigin: Double?
    @State private var hoveredTerminalPaneID: String?
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

    var body: some View {
        chromeDecorated
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaOpenFileLink)) { note in
                guard let url = note.userInfo?["url"] as? URL else { return }
                model.openFilePreview(url, line: note.userInfo?["line"] as? Int)
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
        .sheet(item: $quickActionsTarget) { target in
            VStack(spacing: 0) {
                HStack {
                    Text("Quick Actions").font(.headline)
                    Spacer()
                    Button("Done") { quickActionsTarget = nil }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(14)
                Divider()
                QuickActionsEditor(
                    projectID: target.id,
                    projectName: target.name,
                    onSave: {}
                )
                .padding(8)
            }
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
            // A selection-bound macOS sidebar paints a full-width blue block.
            // Navigation is explicit here so visible surfaces are communicated
            // by their blue icons instead of a heavy row treatment.
            List {
                ForEach(model.projects) { project in
                    let chats = model.chats(in: project.id)
                    let meshes = model.meshes(in: project.id)
                    Section(isExpanded: expansionBinding(project.id)) {
                        if !chats.isEmpty {
                            ProjectSurfaceHeader(title: "Chats", systemImage: "bubble.left.and.text.bubble.right")
                            ForEach(chats) { chat in
                                Button {
                                    model.selectChat(chat.id)
                                } label: {
                                    ChatRow(chat: chat)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(model.selectedChatID == chat.id ? .isSelected : [])
                                    .listRowInsets(.init(top: 1, leading: 20, bottom: 1, trailing: 7))
                                    .contextMenu {
                                        Button("Close Chat", role: .destructive) { model.closeChat(chat.id) }
                                    }
                            }
                        }
                        if !meshes.isEmpty {
                            ProjectSurfaceHeader(title: "Mesh", systemImage: "circle.hexagongrid.fill")
                            ForEach(meshes) { mesh in
                                Button {
                                    model.selectMesh(mesh.id)
                                } label: {
                                    MeshRow(mesh: mesh)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(model.selectedMeshID == mesh.id ? .isSelected : [])
                                    .listRowInsets(.init(top: 1, leading: 20, bottom: 1, trailing: 7))
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
                                HStack(spacing: 8) {
                                    if let tint = ProjectTint.color(project.colorHex) {
                                        Circle().fill(tint).frame(width: 10, height: 10)
                                    } else {
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(activeProjectID == project.id ? Color.accentColor : .secondary)
                                    }
                                    Text(project.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
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
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(activeProjectID == project.id ? Color.accentColor : .secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("New session in \(project.name)")
                        }
                        .padding(.horizontal, 6)
                        .frame(minHeight: 44)
                        .background(
                            activeProjectID == project.id
                                ? AnyShapeStyle(Color.accentColor.opacity(0.13))
                                : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .contextMenu { projectContextMenu(project) }
                        .textCase(nil)
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
                // Keep representable content (especially SwiftTerm) inside the
                // hosting view's real layout bounds. Moving the NSView itself
                // through the titlebar safe area can leave it with a valid frame
                // that AppKit does not composite after a window transition.
                // Only the canvas paint extends beneath the transparent titlebar.
                .background {
                    WorkspaceBackdropView(mode: settings.workspaceBackdrop)
                        .ignoresSafeArea(.container, edges: .top)
                }
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
            }
            SessionStrip(
                model: model,
                projectID: activeProjectID,
                rename: { renameTarget = $0 },
                closeMesh: requestCloseMesh
            )
            Divider()
            detailPane
            HStack(spacing: 0) {
                footer.frame(width: 235)
                Spacer(minLength: 0)
            }
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
        HStack(spacing: 8) {
            Text("Projects")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.82))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.clear)
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
        Button("Quick Actions…") {
            quickActionsTarget = QuickActionsTarget(id: project.id, name: project.name)
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
            isVisible: session.id == model.selectedSessionID
                || model.splitDocuments[session.id] != nil,
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
            },
            select: {
                guard session.id != model.selectedSessionID
                    || model.selectedChatID != nil
                    || model.selectedMeshID != nil
                    || model.browserCardURL != nil else { return }
                Task { await model.select(session.id) }
            }
        )
        .listRowInsets(.init(top: 1, leading: 20, bottom: 1, trailing: 7))
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
            Button("Rename…") { renameTarget = session.id }
            if model.isOwned(session.id) {
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
        HStack(spacing: 0) {
            HSplitView {
                detailContent
                    .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                if let fileURL = model.previewedFileURL {
                    FilePreviewView(url: fileURL, workspaceRoot: model.currentProjectDirectory) {
                        model.closeFilePreview()
                    }
                    .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if settings.workspaceRailVisible, let root = model.currentProjectDirectory {
                // Files live on the right, matching the editor/reference rail in
                // the Electron workspace and leaving the project hierarchy as the
                // sole navigation surface on the left.
                workspaceRailDivider
                WorkspaceRailView(root: root, openFile: { model.openFilePreview($0) }) {
                    settings.workspaceRailVisible = false
                }
                .id(root)
                .frame(width: CGFloat(settings.workspaceRailWidth))
            }
        }
    }

    private var workspaceRailDivider: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.8))
                .frame(width: 1)
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
        }
        .frame(width: 7)
        .onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if workspaceRailDragOrigin == nil {
                        workspaceRailDragOrigin = settings.workspaceRailWidth
                    }
                    guard let origin = workspaceRailDragOrigin else { return }
                    settings.workspaceRailWidth = NativePreviewSettings.clampedWorkspaceRailWidth(
                        origin - Double(value.translation.width)
                    )
                }
                .onEnded { _ in workspaceRailDragOrigin = nil }
        )
        .help("Drag to resize Files")
        .accessibilityHidden(true)
    }

    private var splitCandidates: [BrokerTerminalRecord] {
        let primaryID = model.terminalDocument.sessionID
        let sessions = model.projects.first(where: { $0.id == activeProjectID })?.sessions ?? model.sessions
        return sessions.filter {
            !$0.exited && $0.id != primaryID && model.splitDocuments[$0.id] == nil
        }
    }

    private var detailContent: some View {
        let alternateSurfaceVisible = model.browserCardURL != nil
            || model.selectedMeshID != nil
            || model.selectedChatID != nil
        return ZStack {
            terminalContent
                .background { WorkspaceBackdropView(mode: settings.workspaceBackdrop) }
                .opacity(alternateSurfaceVisible ? 0 : 1)
                .allowsHitTesting(!alternateSurfaceVisible)
                .accessibilityHidden(alternateSurfaceVisible)

            if let browserURL = model.browserCardURL {
                BrowserCardView(url: browserURL) { model.browserCardURL = nil }
            } else if let mesh = model.meshes.first(where: { $0.id == model.selectedMeshID }) {
                MeshView(mesh: mesh)
                    .id(mesh.id)
            } else if let chat = model.chats.first(where: { $0.id == model.selectedChatID }) {
                AcpChatView(conversation: chat.conversation)
                    .id(chat.id)
                    .background { WorkspaceBackdropView(mode: settings.workspaceBackdrop) }
            }
        }
        .transaction { $0.animation = nil }
    }

    private var footer: some View {
        ConnectionFooter(
            state: model.connectionState,
            reload: { Task { await model.reload() } },
            jumpToAttention: { model.jumpToAttentionTarget($0) },
            newMesh: { RootShellView.promptForNewMesh(model: model) },
            newStagedMesh: { RootShellView.promptForNewMesh(model: model, staged: true) },
            newIdeaMesh: { RootShellView.promptForNewMesh(model: model, idea: true) },
            openProject: { RootShellView.promptForOpenFolder(model: model) },
            splitTargets: splitCandidates.map {
                FooterSplitTarget(
                    id: $0.id,
                    title: model.sessionTitle(for: $0),
                    systemImage: model.agentProfile(for: $0.id)?.symbol ?? "terminal"
                )
            },
            openSplit: { id in Task { await model.openInSplit(id) } },
            filesVisible: settings.workspaceRailVisible,
            toggleFiles: { settings.workspaceRailVisible.toggle() },
            filePreviewVisible: model.previewedFileURL != nil,
            toggleFilePreview: {
                if !model.toggleFilePreview() {
                    settings.workspaceRailVisible = true
                }
            },
            showSettings: { showSettings = true },
            showCommandPalette: { showPalette = true }
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

    /// New Mesh belongs to the active project. The project-scoped plus menu is
    /// the place to create one; a global folder picker would make its ACP/MCP
    /// account and configuration context ambiguous.
    @MainActor
    static func promptForNewMesh(model: AppModel, staged: Bool = false, idea: Bool = false) {
        guard let directory = model.currentProjectDirectory else {
            ToastCenter.shared.show("Open or select a project before starting Mesh.", style: .info)
            return
        }
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
        let showsIdentityHeader = TerminalPaneGrid.showsIdentityHeader(paneCount: paneIDs.count)
        let isHovered = hoveredTerminalPaneID == id
        let cornerRadius: CGFloat = showsIdentityHeader ? 12 : 14
        return ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if showsIdentityHeader {
                    terminalPaneHeader(id, isPrimary: isPrimary, isHovered: isHovered)
                }
                if isPrimary {
                    primaryPane
                } else {
                    splitPane(id)
                }
            }

            if !showsIdentityHeader {
                soloTerminalControls(id, isHovered: isHovered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.48), lineWidth: 0.6)
        }
        .padding(showsIdentityHeader ? 5 : 3)
        .frame(minWidth: 240, idealWidth: 480, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        .onHover { hovering in
            if hovering {
                hoveredTerminalPaneID = id
            } else if hoveredTerminalPaneID == id {
                hoveredTerminalPaneID = nil
            }
        }
    }

    /// Session identity is useful only when two or more terminals share the
    /// canvas. A lone terminal is already named by the selected sidebar row.
    private func terminalPaneHeader(_ id: String, isPrimary: Bool, isHovered: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: model.agentProfile(for: id)?.symbol ?? "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 15)
            Text(model.sessionTitle(for: id))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Circle()
                .fill(model.isOwned(id) ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 5, height: 5)
                .accessibilityLabel(model.isOwned(id) ? "Live" : "View only")
            Spacer(minLength: 4)
            terminalPaneButtons(id, isPrimary: isPrimary, revealSecondary: isHovered)
        }
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.58))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.42))
                .frame(height: 0.5)
        }
    }

    /// Keep the one essential pane action visible without rebuilding a full
    /// toolbar. Pop-out appears on hover, matching the Electron session card's
    /// quiet secondary actions.
    private func soloTerminalControls(_ id: String, isHovered: Bool) -> some View {
        HStack(spacing: 1) {
            minimizeTerminalButton(id)
            if isHovered {
                popOutTerminalButton(id)
                    .transition(.opacity)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.38), lineWidth: 0.5)
        }
        .opacity(isHovered ? 1 : 0.58)
        .padding(8)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func terminalPaneButtons(_ id: String, isPrimary: Bool, revealSecondary: Bool) -> some View {
        HStack(spacing: 1) {
            minimizeTerminalButton(id)
            if revealSecondary {
                popOutTerminalButton(id)
                if !isPrimary {
                    Button {
                        Task { await model.promoteSplit(id) }
                    } label: {
                        Image(systemName: "arrow.up.left")
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Make this the primary session")
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: revealSecondary)
    }

    private func minimizeTerminalButton(_ id: String) -> some View {
        Button {
            minimizeTerminalPane(id)
        } label: {
            Image(systemName: "minus")
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Minimize this pane; keep the session running")
        .accessibilityLabel("Minimize \(model.sessionTitle(for: id)) pane")
    }

    private func popOutTerminalButton(_ id: String) -> some View {
        Button {
            KaisolaMacAppDelegate.popOut(sessionID: id)
        } label: {
            Image(systemName: "macwindow.badge.plus")
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Open this session in a new window")
    }

    /// Minimizing is purely a view operation: the broker-backed session keeps
    /// running. A minimized primary yields to the first visible split, or to
    /// the project's empty canvas when it was the only pane.
    private func minimizeTerminalPane(_ id: String) {
        Task {
            switch TerminalPaneGrid.minimizeAction(
                targetID: id,
                primaryID: model.terminalDocument.sessionID,
                splitOrder: model.splitOrder
            ) {
            case .closeSplit(let splitID):
                await model.closeSplit(splitID)
            case .promote(let splitID):
                await model.promoteSplit(splitID)
            case .clearPrimary:
                await model.select(nil)
            case .none:
                break
            }
        }
    }

    private var primaryPane: some View {
        let sessionID = model.terminalDocument.sessionID
        return ZStack(alignment: .topTrailing) {
            ForEach(model.terminalSurfaceOrder, id: \.self) { terminalID in
                if let retainedDocument = model.terminalSurfaceDocuments[terminalID] {
                    let document = terminalID == sessionID
                        ? model.terminalDocument
                        : retainedDocument
                    primaryTerminalSurface(
                        terminalID: terminalID,
                        document: document,
                        active: terminalID == sessionID
                    )
                }
            }
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
        .transaction { $0.animation = nil }
    }

    private func primaryTerminalSurface(
        terminalID: String,
        document: TerminalDocument,
        active: Bool
    ) -> some View {
        let owned = model.isOwned(terminalID)
        return NativeTerminalSurface(
            output: document.output,
            streamEpoch: document.cursor?.streamEpoch,
            endOffset: document.cursor?.offset,
            isOwned: owned,
            fontSize: settings.terminalFontSize,
            fontFamily: settings.terminalFontFamily,
            fontWeight: settings.terminalFontWeight,
            paletteMode: settings.terminalPalette,
            lightSurface: colorScheme == .light,
            onInput: owned && active ? { data in model.sendInput(data, to: terminalID) } : nil,
            onResize: owned && active ? { columns, rows in
                model.resizeTerminal(terminalID, columns: columns, rows: rows)
            } : nil,
            onTitleChange: owned && active ? { title in model.applyAutoTitle(title, to: terminalID) } : nil
        )
        .id("primary-\(terminalID)-\(owned)")
        .opacity(active ? 1 : 0)
        .allowsHitTesting(active)
        .accessibilityHidden(!active)
        .zIndex(active ? 1 : 0)
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
        SettingsView(
            settings: settings,
            checkForUpdates: {
                NotificationCenter.default.post(name: .kaisolaCheckForUpdates, object: nil)
            },
            workspace: workspace,
            dismiss: dismiss
        )
        .background {
            WorkspaceBackdropView(mode: settings.workspaceBackdrop)
                .ignoresSafeArea()
        }
    }
}

/// Pure layout policy for the terminal card grid. Kept separate from SwiftUI so
/// pane balancing stays deterministic and directly testable.
enum TerminalPaneGrid {
    static func showsIdentityHeader(paneCount: Int) -> Bool {
        paneCount > 1
    }

    static func columns(for ids: [String]) -> [[String]] {
        guard ids.count > 2 else { return ids.map { [$0] } }
        let midpoint = (ids.count + 1) / 2
        return [
            Array(ids[..<midpoint]),
            Array(ids[midpoint...]),
        ]
    }

    static func minimizeAction(
        targetID: String,
        primaryID: String?,
        splitOrder: [String]
    ) -> TerminalPaneMinimizeAction {
        if splitOrder.contains(targetID) { return .closeSplit(targetID) }
        guard targetID == primaryID else { return .none }
        if let replacement = splitOrder.first { return .promote(replacement) }
        return .clearPrimary
    }
}

enum TerminalPaneMinimizeAction: Equatable {
    case closeSplit(String)
    case promote(String)
    case clearPrimary
    case none
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
                        .background {
                            surfaceTabBackground(
                                selected: model.selectedChatID == chat.id,
                                tint: .accentColor
                            )
                        }
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
                        .background {
                            surfaceTabBackground(
                                selected: model.selectedMeshID == mesh.id,
                                tint: .accentColor
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Close Mesh", role: .destructive) { closeMesh(mesh) }
                    }
                }
                ForEach(sessions) { session in
                    let visible = model.selectedSessionID == session.id
                        || model.splitDocuments[session.id] != nil
                    let working: Bool = {
                        if case .working = session.agentActivity, !session.exited { return true }
                        return false
                    }()
                    Button {
                        Task { await model.select(session.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.agentProfile(for: session.id)?.symbol
                                ?? (model.isOwned(session.id) ? "terminal.fill" : "terminal"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(visible || working ? Color.accentColor : Color.secondary)
                                .frame(width: 20, height: 20)
                                .background(
                                    (visible || working) ? Color.accentColor.opacity(0.13) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                            Text(model.sessionTitle(for: session)).lineLimit(1)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            surfaceTabBackground(
                                selected: model.selectedSessionID == session.id,
                                tint: .accentColor
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename…") { rename(session.id) }
                        if model.isOwned(session.id) {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 36)
    }

    private func surfaceTabBackground(selected: Bool, tint: Color) -> some View {
        Capsule(style: .continuous)
            .fill(selected ? tint.opacity(0.14) : Color.primary.opacity(0.035))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        selected ? tint.opacity(0.30) : Color.primary.opacity(0.075),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: .black.opacity(selected ? 0.06 : 0.025), radius: 2, y: 1)
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

private struct QuickActionsTarget: Identifiable {
    let id: String
    let name: String
}

/// Lightweight footer menu item; keeping broker records out of the footer makes
/// its bottom-left utility shelf purely presentational.
private struct FooterSplitTarget: Identifiable {
    let id: String
    let title: String
    let systemImage: String
}

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
    let isVisible: Bool
    let canOpenSplit: Bool
    let isOpenInSplit: Bool
    let toggleSplit: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: select) {
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
                    .frame(width: 22, height: 22)
                    .background(
                        isVisible ? Color.accentColor.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .lineLimit(1)
                        Text(sessionDetail)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(sessionDetail)
            .accessibilityAddTraits(isVisible ? .isSelected : [])
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
        if isVisible { return .accentColor }
        if case .working = session.agentActivity { return .accentColor }
        return .secondary
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
    let reload: () -> Void
    var jumpToAttention: ((String) -> Void)?
    var newMesh: (() -> Void)?
    var newStagedMesh: (() -> Void)?
    var newIdeaMesh: (() -> Void)?
    let openProject: () -> Void
    let splitTargets: [FooterSplitTarget]
    let openSplit: (String) -> Void
    let filesVisible: Bool
    let toggleFiles: () -> Void
    let filePreviewVisible: Bool
    let toggleFilePreview: () -> Void
    let showSettings: () -> Void
    let showCommandPalette: () -> Void

    @ObservedObject private var usage = UsageCenter.shared

    @ObservedObject private var attention = AttentionCenter.shared
    @State private var showInbox = false

    private static let appVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "Dev"

    var body: some View {
        HStack(spacing: 7) {
            accountMenu
                .help(state.detail ?? state.title)
            Spacer(minLength: 4)
            attentionButton
            shelfButton(
                filesVisible ? "sidebar.trailing" : "sidebar.right",
                help: filesVisible ? "Hide Files (Command-B)" : "Show Files (Command-B)",
                active: filesVisible,
                action: toggleFiles
            )

            shelfButton(
                filePreviewVisible ? "doc.text.fill" : "doc.text.magnifyingglass",
                help: filePreviewVisible ? "Hide file preview" : "Show file preview",
                active: filePreviewVisible,
                action: toggleFilePreview
            )

            if newMesh != nil || newStagedMesh != nil || newIdeaMesh != nil {
                Menu {
                    if let newMesh { Button("New Mesh (all agents)", action: newMesh) }
                    if let newStagedMesh { Button("New Staged Mesh (scout → execute)", action: newStagedMesh) }
                    if let newIdeaMesh { Button("New Idea Mesh (brainstorm)", action: newIdeaMesh) }
                } label: {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.purple)
                        .frame(width: 27, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(.purple)
                .help("New Mesh — flat, staged, or idea")
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.7)).frame(height: 1)
        }
    }

    private func shelfButton(
        _ symbol: String,
        help: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 25, height: 24)
                .background(
                    active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(active ? 0.10 : 0.055), lineWidth: 0.75)
                }
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var accountMenu: some View {
        Menu {
            Button(action: showSettings) {
                Label("Settings…", systemImage: "gearshape")
            }
            Button(action: openProject) {
                Label("Open Project…", systemImage: "folder.badge.plus")
            }
            Menu("Open Beside", systemImage: "rectangle.split.2x1") {
                if splitTargets.isEmpty {
                    Button("No other live sessions") {}.disabled(true)
                } else {
                    ForEach(splitTargets) { target in
                        Button {
                            openSplit(target.id)
                        } label: {
                            Label(target.title, systemImage: target.systemImage)
                        }
                    }
                }
            }
            .disabled(splitTargets.isEmpty)
            Button(action: showCommandPalette) {
                Label("Command Palette", systemImage: "command")
            }
            Divider()
            Button(action: reload) {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Text(state.detail ?? state.title)
            if usage.totalPeakTokens > 0 {
                Text("Usage: \(usage.totalPeakTokens / 1000)k tokens · \(Int((usage.contextPressure * 100).rounded()))% context")
            }
        } label: {
            HStack(spacing: 7) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(state.isConnected ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(.background, lineWidth: 1.25))
                }
                Text("Kaisola · v\(Self.appVersion)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Account and workspace settings")
        .accessibilityLabel("Kaisola account and settings")
    }

    @ViewBuilder
    private var attentionButton: some View {
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
    }
}
