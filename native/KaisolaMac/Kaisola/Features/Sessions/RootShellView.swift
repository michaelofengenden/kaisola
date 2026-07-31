import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct RootShellView: View {
    nonisolated static func shouldAutomaticallyRefreshPlanUsage(
        environment: [String: String]
    ) -> Bool {
        !NativePreviewSettings.isIsolatedFixture(environment: environment)
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: NativePreviewSettings
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var rememberedSessions: RememberedSessionCatalogCenter
    @ObservedObject private var attention = AttentionCenter.shared
    @ObservedObject private var companionHost = CompanionHost.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.undoManager) private var undoManager
    @State private var renameTarget: String?
    @State private var renameProjectTarget: String?
    @State private var renameText: String = ""
    @State private var gitRepo: URL?
    @State private var showPalette = false
    @State private var showOmniBar = false
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var settingsSectionID: String?
    @State private var quickActionsTarget: QuickActionsTarget?
    @State private var terminalTranscriptTarget: AppModel.TerminalTranscriptContext?
    @State private var terminalTranscriptOpenedFromLiveBoundary = false
    @State private var hoveredTerminalPaneID: String?
    /// A Close Mesh request whose worktrees still hold uncommitted changes.
    @State private var meshCloseConfirm: (id: String, dirty: Int)?

    /// Close immediately only when every column has neither working-tree
    /// changes nor unique commits; all uncertainty blocks deletion.
    private func requestCloseMesh(_ mesh: MeshSession) {
        Task {
            switch await model.requestCloseMesh(mesh.id, allowRecoverableWork: false) {
            case .closed, .unavailable:
                break
            case let .needsConfirmation(columns):
                meshCloseConfirm = (mesh.id, columns)
            case let .blocked(message):
                ToastCenter.shared.show(message, style: .error, duration: 5)
            }
        }
    }

    var body: some View {
        chromeDecorated
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaOpenFileLink)) { note in
                guard let url = note.userInfo?["url"] as? URL else { return }
                model.openFilePreview(
                    url,
                    line: note.userInfo?["line"] as? Int,
                    workspaceHint: note.userInfo?["workspaceHint"] as? URL
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaOpenBrowserCard)) { note in
                guard let url = note.object as? URL else { return }
                model.openBrowserCard(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaAttentionJump)) { note in
                if let targetID = note.userInfo?[NotificationBridge.targetIDKey] as? String {
                    model.jumpToAttentionTarget(targetID)
                }
            }
            .onAppear {
                let environment = ProcessInfo.processInfo.environment
                if environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
                   environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "terminal-transcript",
                   let terminalID = model.sessions.first?.id {
                    DispatchQueue.main.async {
                        terminalTranscriptTarget = model.terminalTranscriptContext(for: terminalID)
                    }
                } else if OnboardingState.shouldShow() {
                    showOnboarding = true
                }
            }
            .task(id: model.currentProjectDirectory?.standardizedFileURL.path) {
                guard Self.shouldAutomaticallyRefreshPlanUsage(
                    environment: ProcessInfo.processInfo.environment
                ) else { return }
                UsageCenter.shared.refreshPlanUsage(workspace: model.currentProjectDirectory)
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
                model.renameSurface(target.id, to: newTitle)
                renameTarget = nil
            } cancel: {
                renameTarget = nil
            }
            .onAppear {
                renameText = model.editableSurfaceTitle(for: target.id)
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
                initialSectionID: settingsSectionID,
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
        .sheet(item: $terminalTranscriptTarget) { target in
            TerminalTranscriptView(
                model: model,
                settings: settings,
                context: target,
                openedFromLiveBoundary: terminalTranscriptOpenedFromLiveBoundary
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
                if let confirm = meshCloseConfirm {
                    Task {
                        if case let .blocked(message) = await model.requestCloseMesh(
                            confirm.id,
                            allowRecoverableWork: true
                        ) {
                            ToastCenter.shared.show(message, style: .error, duration: 5)
                        }
                    }
                }
                meshCloseConfirm = nil
            }
            Button("Cancel", role: .cancel) { meshCloseConfirm = nil }
        } message: {
            Text("\(meshCloseConfirm?.dirty ?? 0) column(s) contain unintegrated files or commits. Closing discards that recoverable work permanently — integrate what you want to keep first.")
        }
    }

    // MARK: - Layouts

    /// Nested project→session tree in a left sidebar (the default).
    private var leftTreeLayout: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                projectSidebarHeader
                // A selection-bound macOS sidebar paints a full-width blue block.
                // Navigation is explicit here so visible surfaces are communicated
                // by their blue icons instead of a heavy row treatment.
                List {
                    QuietProjectRail(
                        model: model,
                        attention: attention,
                        expansion: { expansionBinding($0) },
                        isActiveProject: { model.selectedProjectID == $0 },
                        selectSession: { session in
                            if KaisolaMacAppDelegate.focusWindow(displayingSurface: session.id) { return }
                            guard SurfaceSelectionPolicy.shouldRequestFocus(
                                focusedPaneID: model.focusedPaneID,
                                targetID: session.id,
                                browserOpen: model.browserCardURL != nil,
                                activeProjectID: model.selectedProjectID,
                                targetProjectID: session.projectID
                            ) else { return }
                            Task { await model.focusSurface(session.id) }
                        },
                        launchMenu: { AnyView(projectLaunchMenu($0)) },
                        contextMenu: { AnyView(projectContextMenu($0)) },
                        sessionContextMenu: { AnyView(sessionContextMenuContent($0)) },
                        chatContextMenu: { AnyView(chatContextMenuContent($0)) },
                        meshContextMenu: { AnyView(meshContextMenuContent($0)) }
                    )
                    if auth.isSignedIn {
                        rememberedSessionSidebarSection
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Projects, chats, and terminal sessions")
                footer
            }
            .background {
                SidebarBackdropView(appearance: settings.sidebarAppearance)
                    .ignoresSafeArea()
            }
            .navigationSplitViewColumnWidth(
                min: NativeWorkspaceChrome.projectSidebarMinimumWidth,
                ideal: NativeWorkspaceChrome.projectSidebarIdealWidth,
                max: NativeWorkspaceChrome.projectSidebarMaximumWidth
            )
            // NavigationSplitView exposes only the one-pixel AppKit divider.
            // Add a quiet in-sidebar acquisition target that drives the same
            // NSSplitView in window coordinates, matching every other Kaisola
            // panel handle without replacing native sidebar behavior.
            .overlay(alignment: .trailing) {
                NavigationSidebarResizeAffordance()
                    .frame(width: NativeWorkspaceChrome.projectSidebarDividerWidth)
            }
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: Left-tree context menus
    //
    // The quiet rail is pure presentation, so the sidebar's menus live here and
    // are handed to it as closures. Each one is the menu the pre-rail row built
    // inline, plus the visibility action that row's trailing button used to own.

    @ViewBuilder
    private func sessionContextMenuContent(_ session: BrokerTerminalRecord) -> some View {
        let visible = model.isSurfaceVisible(session.id)
        Button("Open in New Window") {
            KaisolaMacAppDelegate.popOut(sessionID: session.id)
        }
        Button {
            model.togglePin(session.id)
        } label: {
            Label(model.isPinned(session.id) ? "Unpin" : "Pin",
                  systemImage: model.isPinned(session.id) ? "pin.slash" : "pin")
        }
        if !visible {
            Button("Open in Split") {
                model.revealSurfaceBeside(session.id)
            }
        }
        if visible {
            Button("Minimize Pane") {
                Task { await model.minimizeSurface(session.id) }
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

    @ViewBuilder
    private func chatContextMenuContent(_ chat: AcpChatHandle) -> some View {
        Button("Open Beside") { model.revealSurfaceBeside(chat.id) }
        if model.isSurfaceVisible(chat.id) {
            Button("Minimize Pane") { Task { await model.minimizeSurface(chat.id) } }
        }
        Button("Rename…") { renameTarget = chat.id }
        Button("Close Chat", role: .destructive) { model.closeChat(chat.id) }
    }

    @ViewBuilder
    private func meshContextMenuContent(_ mesh: MeshSession) -> some View {
        Button("Open Beside") { model.revealSurfaceBeside(mesh.id) }
        if model.isSurfaceVisible(mesh.id) {
            Button("Minimize Pane") { Task { await model.minimizeSurface(mesh.id) } }
        }
        Button("Rename…") { renameTarget = mesh.id }
        Button("Close Mesh", role: .destructive) { requestCloseMesh(mesh) }
    }

    @ViewBuilder
    private var rememberedSessionSidebarSection: some View {
        Section {
            if rememberedSessions.remoteDevices.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                    Text(rememberedSessions.isRefreshing ? "Checking your Macs…" : "No other Macs yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowInsets(.init(top: 5, leading: 16, bottom: 5, trailing: 10))
            } else {
                ForEach(rememberedSessions.remoteDevices) { device in
                    DisclosureGroup {
                        ForEach(device.sessions) { session in
                            rememberedSessionRow(session, device: device)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(device.presence == .online ? Color.green : Color.secondary.opacity(0.45))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.deviceName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(device.sessions.count) remembered \(device.sessions.count == 1 ? "session" : "sessions")")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .help("Metadata only; live control remains on this Mac until Companion is connected")
                }
            }
            if let error = rememberedSessions.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            if let freshness = rememberedSessions.freshnessTitle {
                Label(freshness, systemImage: rememberedSessions.source == .savedSnapshot
                    ? "clock.arrow.circlepath"
                    : "checkmark.icloud")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Remembered-session catalog freshness")
                    .accessibilityLabel("Remembered sessions, \(freshness)")
            }
        } header: {
            HStack {
                Text("Other Macs")
                Spacer()
                Button { rememberedSessions.requestRefresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(rememberedSessions.isRefreshing)
                .help("Refresh remembered sessions")
            }
            .textCase(nil)
        }
    }

    private func rememberedSessionRow(
        _ session: RememberedSessionRecord,
        device: RememberedDeviceCatalog
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: rememberedSessionSymbol(session.kind))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(rememberedSessionTint(session.activity))
                .frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Text("\(session.projectName) · \(rememberedSessionActivityTitle(session.activity))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help("Remembered on \(device.deviceName). This row contains metadata only.")
    }

    private func rememberedSessionSymbol(_ kind: RememberedSessionKind) -> String {
        switch kind {
        case .terminal: "terminal"
        case .agentChat: "bubble.left.and.text.bubble.right"
        case .mesh: "circle.hexagongrid.fill"
        }
    }

    private func rememberedSessionTint(_ activity: RememberedSessionActivity) -> Color {
        switch activity {
        case .working: WorkspacePalette.active
        case .needsAttention: .orange
        case .idle: .secondary
        case .ended: .secondary.opacity(0.6)
        }
    }

    private func rememberedSessionActivityTitle(_ activity: RememberedSessionActivity) -> String {
        switch activity {
        case .working: "Working"
        case .needsAttention: "Needs attention"
        case .idle: "Idle"
        case .ended: "Ended"
        }
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
                useSidebar: { settings.navigationLayout = .leftTree },
                reorder: { model.moveProject(id: $0, toIndex: $1) }
            )
            .padding(.leading, NativeWorkspaceChrome.topBarTrafficLightClearance)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.82))
                .padding(.leading, 12)
            Spacer()
            Button {
                RootShellView.promptForOpenFolder(model: model)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Project")
            .accessibilityLabel("Open Project")
            Button {
                settings.navigationLayout = .topBar
            } label: {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Move projects and sessions to top bars")
            .accessibilityLabel("Use top bar navigation")
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .padding(.top, NativeWorkspaceChrome.sidebarTrafficLightClearance)
        .frame(height: 36 + NativeWorkspaceChrome.sidebarTrafficLightClearance, alignment: .bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Self.chooseDirectoryForRelocate(startingAt: project.directory) { directory in
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
                    Self.startAgentSession(agent, in: directory, model: model)
                } label: {
                    Label("New \(agent.name) Terminal", systemImage: agent.symbol)
                }
            }
            Divider()
            ForEach(AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil }) { agent in
                Button {
                    model.activateProject(id: project.id)
                    Self.startChat(agent, in: directory, model: model)
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
    static func chooseDirectoryForRelocate(
        startingAt: URL? = nil,
        then handle: @escaping @MainActor (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Relocate Project"
        panel.message = "Choose the folder this project moved to."
        panel.directoryURL = NativeFolderPickerStartingPoint.preferred(currentProject: startingAt)
        // Async for the same reason as Open Project: `runModal()` freezes the
        // whole run loop while Finder and File Provider enumerate, which stalls
        // terminal output and repaints along with it.
        panel.begin { response in
            guard response == .OK, let directory = panel.urls.first else { return }
            Task { @MainActor in handle(directory) }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: BrokerTerminalRecord) -> some View {
        let visible = model.isSurfaceVisible(session.id)
        SessionRow(
            session: session,
            title: model.sessionTitle(for: session),
            owned: model.isOwned(session.id),
            companionControllerName: companionControllerName(for: session.id),
            agent: model.agentProfile(for: session.id),
            accountLabel: model.accountLabel(for: session.id),
            branch: model.branch(for: session.id),
            meta: model.meta(for: session.id),
            isVisible: visible,
            canOpenSplit: !visible,
            isOpenInSplit: visible,
            toggleSplit: {
                if visible {
                    Task { await model.minimizeSurface(session.id) }
                } else {
                    model.revealSurfaceBeside(session.id)
                }
            },
            select: {
                if KaisolaMacAppDelegate.focusWindow(displayingSurface: session.id) { return }
                guard SurfaceSelectionPolicy.shouldRequestFocus(
                    focusedPaneID: model.focusedPaneID,
                    targetID: session.id,
                    browserOpen: model.browserCardURL != nil,
                    activeProjectID: model.selectedProjectID,
                    targetProjectID: session.projectID
                ) else { return }
                Task { await model.focusSurface(session.id) }
            }
        )
        .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 10))
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
            if !visible {
                Button("Open in Split") {
                    model.revealSurfaceBeside(session.id)
                }
            }
            if visible {
                Button("Minimize Pane") {
                    Task { await model.minimizeSurface(session.id) }
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

    private func surfaceVisibilityButton(_ id: String) -> some View {
        let visible = model.isSurfaceVisible(id)
        return Button {
            if visible {
                Task {
                    await model.minimizeSurface(id)
                }
            } else {
                model.revealSurfaceBeside(id)
            }
        } label: {
            SurfaceVisibilityControlLabel(isVisible: visible)
        }
        .buttonStyle(.plain)
        .help(visible ? "Hide this session from the workspace" : "Open this session beside the current one")
        .accessibilityLabel(visible ? "Hide session" : "Open session beside current session")
    }

    @ViewBuilder
    private var detailPane: some View {
        GeometryReader { geometry in
            let widths = NativeDetailPaneSizing.resolve(
                totalWidth: geometry.size.width,
                preferredPreview: model.previewedFileURL == nil && model.browserCardURL == nil
                    ? nil
                    : settings.filePreviewWidth,
                preferredRail: settings.workspaceRailVisible && model.currentProjectDirectory != nil
                    ? settings.workspaceRailWidth
                    : nil
            )
            HStack(spacing: 0) {
                detailContent
                    .frame(minWidth: NativeDetailPaneSizing.minimumContentWidth,
                           maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                if let browserURL = model.browserCardURL {
                    filePreviewDivider
                    BrowserCardView(url: browserURL) { model.browserCardURL = nil }
                        .frame(width: widths.preview)
                        .frame(maxHeight: .infinity)
                } else if let fileURL = model.previewedFileURL {
                    filePreviewDivider
                    FilePreviewView(
                        url: fileURL,
                        workspaceRoot: model.currentProjectDirectory,
                        targetLine: model.previewedFileLine,
                        tabs: model.fileTabs(for: model.selectedProjectID),
                        selectTab: { model.selectFileTab($0) },
                        setTabPinned: { model.setFileTabPinned($0, pinned: $1) },
                        closeTab: { model.closeFileTab($0) },
                        canReopenClosedTab: model.canReopenClosedFileTab,
                        reopenClosedTab: { model.reopenClosedFileTab() },
                        commandScopeID: ObjectIdentifier(model),
                        navigationCommitted: { model.commitFileNavigation($0) },
                        restoreSelection: { model.cancelFileNavigation(restoring: $0) }
                    ) {
                        model.closeFilePreview()
                    }
                    .frame(width: widths.preview)
                    .frame(maxHeight: .infinity)
                }
                if settings.workspaceRailVisible, let root = model.currentProjectDirectory {
                    // Files live on the right, matching the editor/reference rail in
                    // the Electron workspace and leaving the project hierarchy as the
                    // sole navigation surface on the left.
                    workspaceRailDivider
                    WorkspaceRailView(root: root, selectedFile: model.previewedFileURL, openFile: { url, pinned in
                        model.openFilePreview(url, pinned: pinned)
                    }, didMoveItem: { source, destination in
                        model.reconcileWorkspaceFileMove(from: source, to: destination)
                        model.registerWorkspaceRenameUndo(
                            .init(source: source, destination: destination),
                            workspaceRoot: root,
                            undoManager: undoManager
                        )
                    }, didTrashItem: { move in
                        let snapshot = model.reconcileWorkspaceFileRemoval(move.original)
                        model.registerWorkspaceTrashUndo(
                            move,
                            removalSnapshot: snapshot,
                            workspaceRoot: root,
                            undoManager: undoManager
                        )
                    }, didCreateItem: { created in
                        model.registerWorkspaceCreationUndo(
                            created,
                            workspaceRoot: root,
                            undoManager: undoManager
                        )
                    }) {
                        settings.workspaceRailVisible = false
                    }
                    .id(root)
                    .frame(width: widths.rail)
                }
            }
        }
    }

    private var workspaceRailDivider: some View {
        StablePanelResizeHandle(
            label: "Resize Files",
            onBegan: settings.beginPanelResize,
            onDelta: { delta in
                settings.workspaceRailWidth = NativePreviewSettings.clampedWorkspaceRailWidth(
                    settings.workspaceRailWidth - Double(delta)
                )
            },
            onEnded: settings.endPanelResize,
            onDoubleClick: {
                settings.workspaceRailWidth = NativePreviewSettings.workspaceRailWidthDefault
            }
        )
        .help("Drag to resize Files; double-click to reset")
        .accessibilityAdjustableAction { direction in
            settings.workspaceRailWidth = NativePreviewSettings.clampedWorkspaceRailWidth(
                settings.workspaceRailWidth + (direction == .increment ? 16 : -16)
            )
        }
    }

    private var filePreviewDivider: some View {
        StablePanelResizeHandle(
            label: "Resize document preview",
            onBegan: settings.beginPanelResize,
            onDelta: { delta in
                settings.filePreviewWidth = NativePreviewSettings.clampedFilePreviewWidth(
                    settings.filePreviewWidth - Double(delta)
                )
            },
            onEnded: settings.endPanelResize,
            onDoubleClick: {
                settings.filePreviewWidth = NativePreviewSettings.filePreviewWidthDefault
            }
        )
            .help("Drag to resize the document; double-click to reset")
            .accessibilityAdjustableAction { direction in
                settings.filePreviewWidth = NativePreviewSettings.clampedFilePreviewWidth(
                    settings.filePreviewWidth + (direction == .increment ? 24 : -24)
                )
            }
    }

    private var detailContent: some View {
        unifiedSessionPaneGrid
        .transaction { $0.animation = nil }
    }

    private var footer: some View {
        ConnectionFooter(
            state: model.connectionState,
            brokerUpgradeState: model.brokerUpgradeState,
            reload: { Task { await model.reload() } },
            jumpToAttention: { model.jumpToAttentionTarget($0) },
            newMesh: { RootShellView.promptForNewMesh(model: model) },
            newStagedMesh: { RootShellView.promptForNewMesh(model: model, staged: true) },
            newIdeaMesh: { RootShellView.promptForNewMesh(model: model, idea: true) },
            filesVisible: settings.workspaceRailVisible,
            toggleFiles: { settings.workspaceRailVisible.toggle() },
            filePreviewVisible: model.previewedFileURL != nil,
            toggleFilePreview: {
                if !model.toggleFilePreview() {
                    settings.workspaceRailVisible = true
                }
            },
            showSettings: {
                settingsSectionID = nil
                showSettings = true
            },
            showUsage: {
                settingsSectionID = "usage"
                showSettings = true
            }
        )
    }

    /// New owned shell in the active project (or a picked folder when there's no
    /// project context). Reused by the File menu and the sidebar button.
    @MainActor
    static func promptForNewTerminal(model: AppModel) {
        if let directory = model.currentProjectDirectory {
            Task { await model.createTerminal(inDirectory: directory) }
            return
        }
        chooseDirectory(prompt: "Open Terminal Here") { directory in
            Task { await model.createTerminal(inDirectory: directory) }
        }
    }

    /// New agent session running the agent's CLI in the active project (or a
    /// picked folder).
    @MainActor
    static func promptForNewAgent(_ agent: AgentProfile, model: AppModel) {
        if let directory = model.currentProjectDirectory {
            startAgentSession(agent, in: directory, model: model)
            return
        }
        chooseDirectory(prompt: "Start \(agent.name) Here") { directory in
            startAgentSession(agent, in: directory, model: model)
        }
    }

    /// Folder picker → open a folder as a project tab (no session yet). This one
    /// always prompts — its whole purpose is choosing a new folder.
    @MainActor
    static func promptForOpenFolder(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a folder to open as a project."
        panel.directoryURL = NativeFolderPickerStartingPoint.preferred(
            currentProject: model.currentProjectDirectory
        )
        // `runModal()` blocks the main run loop while Finder and File Provider
        // enumerate. The async panel keeps terminals, panes, and clicks live
        // even when a network-backed location is slow to respond.
        panel.begin { response in
            guard response == .OK, let directory = panel.urls.first else { return }
            Task { @MainActor in model.openProject(directory: directory) }
        }
    }

    /// New ACP chat with the agent in the active project (or a picked folder).
    @MainActor
    static func promptForNewChat(_ agent: AgentProfile, model: AppModel) {
        guard AcpAdapter.forAgent(agent.id) != nil else { return }
        if let directory = model.currentProjectDirectory {
            startChat(agent, in: directory, model: model)
            return
        }
        chooseDirectory(prompt: "Chat with \(agent.name) Here") { directory in
            startChat(agent, in: directory, model: model)
        }
    }

    @MainActor
    private static func startAgentSession(
        _ agent: AgentProfile,
        in directory: URL,
        model: AppModel
    ) {
        chooseSessionAccount(for: agent) { profile in
            Task { await model.createAgentSession(
                agent,
                inDirectory: directory,
                accountProfile: profile
            ) }
        }
    }

    @MainActor
    private static func startChat(
        _ agent: AgentProfile,
        in directory: URL,
        model: AppModel
    ) {
        chooseSessionAccount(for: agent) { profile in
            model.openChat(agent, inDirectory: directory, accountProfile: profile)
        }
    }

    /// Pick a local provider-owned config directory without ever reading or
    /// copying its credentials. No named profiles means zero extra ceremony.
    /// Once selected, AppModel snapshots the resolved path into the session so
    /// later settings changes cannot redirect an existing continuation.
    @MainActor
    private static func chooseSessionAccount(
        for agent: AgentProfile,
        then handle: @escaping @MainActor (UsageAccountProfile?) -> Void
    ) {
        guard let provider = SessionAccountBinding.provider(forAgentID: agent.id) else {
            handle(nil)
            return
        }
        var profiles = UsageAccountStore().profiles()
            .filter { $0.provider == provider }
        if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
           ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "account-picker" {
            profiles = [
                UsageAccountProfile(
                    id: "visual-work",
                    provider: provider,
                    label: "Work",
                    directory: "/Users/example/.\(provider.rawValue)-work"
                ),
                UsageAccountProfile(
                    id: "visual-research",
                    provider: provider,
                    label: "Research",
                    directory: "/Users/example/.\(provider.rawValue)-research"
                ),
            ]
        }
        profiles.sort { lhs, rhs in
                lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        guard !profiles.isEmpty else {
            handle(nil)
            return
        }

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        picker.addItem(withTitle: "Project/default")
        picker.item(at: 0)?.toolTip = "Use this project's effective \(provider.environmentKey)"
        for profile in profiles {
            picker.addItem(withTitle: profile.label)
            picker.item(at: picker.numberOfItems - 1)?.toolTip = profile.expandedDirectory
        }
        picker.setAccessibilityLabel("Account")
        if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
           ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "account-picker" {
            picker.selectItem(at: min(1, picker.numberOfItems - 1))
        }

        let alert = NSAlert()
        alert.messageText = "Choose \(agent.name) account"
        alert.informativeText = "This account stays locked to the new session and all of its continuations. Credentials remain in the provider's own config directory."
        alert.alertStyle = .informational
        alert.accessoryView = picker
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let selected = picker.indexOfSelectedItem
            handle(selected > 0 ? profiles[selected - 1] : nil)
        }
        if let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            alert.beginSheetModal(for: window) { response in
                Task { @MainActor in finish(response) }
            }
        } else {
            finish(alert.runModal())
        }
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
    private static func chooseDirectory(
        prompt: String,
        startingAt: URL? = nil,
        then handle: @escaping @MainActor (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = "Choose the folder for the new session."
        // Start beside the current project rather than wherever Finder was last,
        // so the panel does not re-enumerate a large repository on open.
        panel.directoryURL = NativeFolderPickerStartingPoint.preferred(currentProject: startingAt)
        panel.begin { response in
            guard response == .OK, let directory = panel.urls.first else { return }
            Task { @MainActor in handle(directory) }
        }
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
                ? "Start a terminal, agent, chat, or Mesh run for this project."
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

    // MARK: - Unified movable session dock

    private var unifiedSessionPaneGrid: some View {
        let layout = model.paneLayout(for: activeProjectID)
        return Group {
            if let maximized = model.maximizedPaneID, layout.contains(maximized) {
                unifiedSessionCard(maximized)
            } else if layout.isEmpty {
                emptyWorkspaceState
            } else {
                GeometryReader { geometry in
                    let dividerSpace = CGFloat(max(0, layout.columns.count - 1)) * SessionPaneDividerSizing.layoutExtent
                    let available = max(1, geometry.size.width - dividerSpace)
                    let totalWeight = max(0.01, layout.columns.reduce(0) { $0 + $1.weight })
                    HStack(spacing: 0) {
                        ForEach(Array(layout.columns.enumerated()), id: \.element.id) { index, column in
                            unifiedSessionColumn(column, projectID: activeProjectID)
                                .frame(width: available * CGFloat(column.weight / totalWeight))
                            if index < layout.columns.count - 1, let projectID = activeProjectID {
                                paneColumnDivider(
                                    projectID: projectID,
                                    boundary: index,
                                    available: available,
                                    totalWeight: totalWeight
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func unifiedSessionColumn(
        _ column: SessionPaneLayout.Column,
        projectID: String?
    ) -> some View {
        GeometryReader { geometry in
            let dividerSpace = CGFloat(max(0, column.sessionIDs.count - 1)) * SessionPaneDividerSizing.layoutExtent
            let available = max(1, geometry.size.height - dividerSpace)
            let totalWeight = max(0.01, column.rowWeights.reduce(0, +))
            VStack(spacing: 0) {
                ForEach(Array(column.sessionIDs.enumerated()), id: \.element) { index, id in
                    unifiedSessionCard(id)
                        .frame(height: available * CGFloat(column.rowWeights[index] / totalWeight))
                    if index < column.sessionIDs.count - 1, let projectID {
                        paneRowDivider(
                            projectID: projectID,
                            columnID: column.id,
                            boundary: index,
                            available: available,
                            totalWeight: totalWeight
                        )
                    }
                }
            }
        }
    }

    private func paneColumnDivider(
        projectID: String,
        boundary: Int,
        available: CGFloat,
        totalWeight: Double
    ) -> some View {
        return PaneResizeHandle(
            axis: .horizontal,
            onDelta: { incremental in
                model.resizePaneColumns(
                    projectID: projectID,
                    boundary: boundary,
                    delta: SessionPaneLayout.weightDelta(
                        pointDelta: Double(incremental),
                        availableExtent: Double(available),
                        totalWeight: totalWeight
                    ),
                    minimumWeight: SessionPaneLayout.minimumWeight(
                        minimumExtent: 180,
                        availableExtent: Double(available),
                        totalWeight: totalWeight
                    )
                )
            },
            onEnded: { model.finishPaneResize(projectID: projectID) },
            onDoubleClick: { model.resetPaneColumns(projectID: projectID) }
        )
    }

    private func paneRowDivider(
        projectID: String,
        columnID: String,
        boundary: Int,
        available: CGFloat,
        totalWeight: Double
    ) -> some View {
        return PaneResizeHandle(
            axis: .vertical,
            onDelta: { incremental in
                model.resizePaneRows(
                    projectID: projectID,
                    columnID: columnID,
                    boundary: boundary,
                    delta: SessionPaneLayout.weightDelta(
                        pointDelta: Double(incremental),
                        availableExtent: Double(available),
                        totalWeight: totalWeight
                    ),
                    minimumWeight: SessionPaneLayout.minimumWeight(
                        minimumExtent: 150,
                        availableExtent: Double(available),
                        totalWeight: totalWeight
                    )
                )
            },
            onEnded: { model.finishPaneResize(projectID: projectID) },
            onDoubleClick: {
                model.resetPaneRows(projectID: projectID, columnID: columnID)
            }
        )
    }

    private func unifiedSessionCard(_ id: String) -> some View {
        GeometryReader { geometry in
            let cardRadius: CGFloat = 8
            VStack(spacing: 0) {
                unifiedSessionHeader(id)
                unifiedSessionContent(id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .stroke(
                        model.focusedPaneID == id
                            ? Color.accentColor.opacity(0.38)
                            : Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: model.focusedPaneID == id
                            ? KaisolaVisualSystem.focusStroke
                            : KaisolaVisualSystem.hairline
                    )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .onDrop(
                of: [UTType.utf8PlainText],
                delegate: SessionPaneDropDelegate(
                    targetID: id,
                    targetSize: geometry.size,
                    move: { sourceID, targetID, edge in
                        model.placeSurface(sourceID, relativeTo: targetID, edge: edge)
                    }
                )
            )
        }
        .frame(minWidth: 220, minHeight: 150)
    }

    private func unifiedSessionHeader(_ id: String) -> some View {
        HStack(spacing: 7) {
            Button {
                Task { await model.focusSurface(id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: surfaceSymbol(id))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(surfaceTint(id))
                        .frame(width: 16)
                    Text(surfaceTitle(id))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if surfaceWorking(id) {
                        ProgressView().controlSize(.mini).scaleEffect(0.55)
                    } else {
                        Circle()
                            .fill(surfaceLive(id) ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 5, height: 5)
                    }
                    if let deviceName = companionControllerName(for: id) {
                        Label(deviceName, systemImage: "iphone")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .help("Controlled from \(deviceName)")
                            .accessibilityLabel("Controlled from \(deviceName)")
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Focus \(surfaceTitle(id))")
            if let mesh = model.meshes.first(where: { $0.id == id }) {
                MeshConfigurationMenu(mesh: mesh)
            }
            Button { model.toggleMaximizeSurface(id) } label: {
                Image(systemName: model.maximizedPaneID == id
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.maximizedPaneID == id ? "Restore pane" : "Maximize pane")
            if model.sessions.contains(where: { $0.id == id }) {
                Button {
                    openTerminalTranscript(id)
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.terminalTranscriptContext(for: id) == nil)
                .help("Open the full retained terminal transcript")
                popOutTerminalButton(id)
            }
            Button { Task { await model.minimizeSurface(id) } } label: {
                Image(systemName: "minus.circle")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Minimize this session; keep it running")
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.38)).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: id as NSString)
        }
        .contextMenu {
            Button("Rename…") { renameTarget = id }
            if model.sessions.contains(where: { $0.id == id }) {
                Button("Open Transcript") {
                    openTerminalTranscript(id)
                }
                .disabled(model.terminalTranscriptContext(for: id) == nil)
            }
            Button("Minimize") { Task { await model.minimizeSurface(id) } }
        }
    }

    private func companionControllerName(for terminalID: String) -> String? {
        guard let terminal = model.sessions.first(where: { $0.id == terminalID }) else { return nil }
        if let deviceName = companionHost.controllingDeviceName(
            projectID: terminal.projectID,
            terminalID: terminal.id
        ) {
            return deviceName
        }
        // Deterministic visual fixtures exercise the chip without manufacturing
        // a paired-device roster or network lease. Production sets both states
        // together through CompanionHost's lease callback.
        return model.companionControlledTerminalIDs.contains(terminalID)
            ? "iPhone"
            : nil
    }

    private func openTerminalTranscript(_ terminalID: String, fromLiveBoundary: Bool = false) {
        guard let context = model.terminalTranscriptContext(for: terminalID) else { return }
        terminalTranscriptOpenedFromLiveBoundary = fromLiveBoundary
        terminalTranscriptTarget = context
    }

    @ViewBuilder
    private func unifiedSessionContent(_ id: String) -> some View {
        if model.sessions.contains(where: { $0.id == id }) {
            unifiedTerminalSurface(id)
            .padding(.leading, TerminalPaneGrid.contentLeadingInset)
            .padding(.top, TerminalPaneGrid.contentTopInset)
            .padding(.trailing, TerminalPaneGrid.contentTrailingInset)
            .padding(.bottom, TerminalPaneGrid.contentBottomInset)
        } else if let chat = model.chats.first(where: { $0.id == id }) {
            AcpChatView(conversation: chat.conversation, presentation: .embedded)
                .id(chat.id)
        } else if let mesh = model.meshes.first(where: { $0.id == id }) {
            MeshView(mesh: mesh, presentation: .embedded)
                .id(mesh.id)
        } else {
            ContentUnavailableView("Session unavailable", systemImage: "rectangle.slash")
        }
    }

    /// A terminal card always owns exactly one SwiftTerm representable keyed by
    /// the card's stable session id. Broker focus may swap a session between the
    /// primary and secondary subscription lanes, but that no longer swaps the
    /// SwiftUI subtree (the source of the old white flash and ANSI replay).
    @ViewBuilder
    private func unifiedTerminalSurface(_ id: String) -> some View {
        if unifiedTerminalDocument(id) != nil,
           let feed = model.terminalSurfaceFeed(for: id) {
            let owned = model.isOwned(id)
            TerminalSurfaceFeedView(feed: feed) { liveDocument in
                NativeTerminalSurface(
                    output: "",
                    streamEpoch: liveDocument.cursor?.streamEpoch,
                    endOffset: liveDocument.cursor?.offset,
                    scrollback: liveDocument.scrollback,
                    surfaceDelta: liveDocument.surfaceDelta,
                    workingDirectory: model.directory(for: id),
                    isOwned: owned,
                    fontSize: settings.terminalFontSize,
                    fontFamily: settings.terminalFontFamily,
                    fontWeight: settings.terminalFontWeight,
                    lineSpacing: settings.terminalLineSpacing,
                    scrollbackLines: settings.terminalScrollbackLines,
                    paletteMode: settings.terminalPalette,
                    lightSurface: colorScheme == .light,
                    sessionID: id,
                    agentLaunchCommand: model.agentProfile(for: id)?.launchCommand,
                    onInput: owned ? { data in model.sendInput(data, to: id) } : nil,
                    onResize: owned ? { columns, rows in model.resizeTerminal(id, columns: columns, rows: rows) } : nil,
                    onTitleChange: owned ? { title in model.applyAutoTitle(title, to: id) } : nil,
                    onHistoryBoundary: { openTerminalTranscript(id, fromLiveBoundary: true) }
                )
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading terminal")
        }
    }

    private func unifiedTerminalDocument(_ id: String) -> TerminalDocument? {
        UnifiedTerminalDocumentResolver.resolve(
            id: id,
            primary: model.terminalDocument,
            splits: model.splitDocuments,
            retained: model.terminalSurfaceDocuments
        )
    }

    private func surfaceTitle(_ id: String) -> String {
        if let terminal = model.sessions.first(where: { $0.id == id }) {
            return model.sessionTitle(for: terminal)
        }
        if let chat = model.chats.first(where: { $0.id == id }) { return chat.conversation.title }
        if let mesh = model.meshes.first(where: { $0.id == id }) { return mesh.title }
        return "Session"
    }

    private func surfaceSymbol(_ id: String) -> String {
        if model.sessions.contains(where: { $0.id == id }) {
            return model.agentProfile(for: id)?.symbol ?? "terminal"
        }
        if model.chats.contains(where: { $0.id == id }) { return "bubble.left.and.text.bubble.right" }
        return "circle.hexagongrid.fill"
    }

    private func surfaceTint(_ id: String) -> Color {
        model.meshes.contains(where: { $0.id == id }) ? .purple : .accentColor
    }

    private func surfaceWorking(_ id: String) -> Bool {
        if let terminal = model.sessions.first(where: { $0.id == id }), case .working = terminal.agentActivity {
            return !terminal.exited
        }
        if let chat = model.chats.first(where: { $0.id == id }) { return chat.conversation.isRunning }
        if let mesh = model.meshes.first(where: { $0.id == id }) { return mesh.stage != "Idle" }
        return false
    }

    private func surfaceLive(_ id: String) -> Bool {
        if let terminal = model.sessions.first(where: { $0.id == id }) { return !terminal.exited }
        if let chat = model.chats.first(where: { $0.id == id }) { return chat.conversation.isConnected }
        return model.meshes.contains(where: { $0.id == id })
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
                        .padding(.leading, TerminalPaneGrid.contentLeadingInset)
                        .padding(.top, TerminalPaneGrid.contentTopInset)
                        .padding(.trailing, TerminalPaneGrid.contentTrailingInset)
                        .padding(.bottom, TerminalPaneGrid.contentBottomInset)
                } else {
                    splitPane(id)
                        .padding(.leading, TerminalPaneGrid.contentLeadingInset)
                        .padding(.top, TerminalPaneGrid.contentTopInset)
                        .padding(.trailing, TerminalPaneGrid.contentTrailingInset)
                        .padding(.bottom, TerminalPaneGrid.contentBottomInset)
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
            if let deviceName = companionControllerName(for: id) {
                Label(deviceName, systemImage: "iphone")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                    .help("Controlled from \(deviceName)")
                    .accessibilityLabel("Controlled from \(deviceName)")
            }
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
        .background {
            if isHovered {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay {
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.38), lineWidth: 0.5)
                .opacity(isHovered ? 1 : 0)
        }
        .opacity(isHovered ? 1 : 0.46)
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
                if model.terminalSurfaceDocuments[terminalID] != nil {
                    primaryTerminalSurface(
                        terminalID: terminalID,
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

    @ViewBuilder
    private func primaryTerminalSurface(
        terminalID: String,
        active: Bool
    ) -> some View {
        if let feed = model.terminalSurfaceFeed(for: terminalID) {
            let owned = model.isOwned(terminalID)
            TerminalSurfaceFeedView(feed: feed) { liveDocument in
                NativeTerminalSurface(
                    output: "",
                    streamEpoch: liveDocument.cursor?.streamEpoch,
                    endOffset: liveDocument.cursor?.offset,
                    scrollback: liveDocument.scrollback,
                    surfaceDelta: liveDocument.surfaceDelta,
                    workingDirectory: model.directory(for: terminalID),
                    isOwned: owned,
                    fontSize: settings.terminalFontSize,
                    fontFamily: settings.terminalFontFamily,
                    fontWeight: settings.terminalFontWeight,
                    lineSpacing: settings.terminalLineSpacing,
                    paletteMode: settings.terminalPalette,
                    lightSurface: colorScheme == .light,
                    onInput: owned && active ? { data in model.sendInput(data, to: terminalID) } : nil,
                    onResize: owned && active ? { columns, rows in
                        model.resizeTerminal(terminalID, columns: columns, rows: rows)
                    } : nil,
                    onTitleChange: owned && active ? { title in model.applyAutoTitle(title, to: terminalID) } : nil,
                    onHistoryBoundary: active
                        ? { openTerminalTranscript(terminalID, fromLiveBoundary: true) }
                        : nil
                )
            }
            .id("primary-\(terminalID)-\(owned)")
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
        }
    }

    @ViewBuilder
    private func splitPane(_ splitID: String) -> some View {
        // Keep the last complete frame mounted while a broker reconnect or
        // owner-role handoff replaces the live secondary subscription.
        if (model.splitDocuments[splitID]
            ?? model.terminalSurfaceDocuments[splitID]) != nil,
           let feed = model.terminalSurfaceFeed(for: splitID) {
            let owned = model.isOwned(splitID)
            TerminalSurfaceFeedView(feed: feed) { liveDocument in
                NativeTerminalSurface(
                    output: "",
                    streamEpoch: liveDocument.cursor?.streamEpoch,
                    endOffset: liveDocument.cursor?.offset,
                    scrollback: liveDocument.scrollback,
                    surfaceDelta: liveDocument.surfaceDelta,
                    workingDirectory: model.directory(for: splitID),
                    isOwned: owned,
                    fontSize: settings.terminalFontSize,
                    fontFamily: settings.terminalFontFamily,
                    fontWeight: settings.terminalFontWeight,
                    lineSpacing: settings.terminalLineSpacing,
                    paletteMode: settings.terminalPalette,
                    lightSurface: colorScheme == .light,
                    onInput: owned ? { data in model.sendInput(data, to: splitID) } : nil,
                    onResize: owned ? { columns, rows in model.resizeTerminal(splitID, columns: columns, rows: rows) } : nil,
                    onTitleChange: owned ? { title in model.applyAutoTitle(title, to: splitID) } : nil,
                    onHistoryBoundary: { openTerminalTranscript(splitID, fromLiveBoundary: true) }
                )
            }
            .id("split-\(splitID)-\(owned)")
        }
    }
}

private struct PaneResizeHandle: View {
    let axis: Axis
    let onDelta: (CGFloat) -> Void
    let onEnded: () -> Void
    let onDoubleClick: () -> Void
    @State private var hovered = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
            Capsule()
                .fill(hovered ? Color.accentColor.opacity(0.62) : Color.primary.opacity(0.13))
                .frame(
                    width: axis == .horizontal ? 2 : 34,
                    height: axis == .horizontal ? 34 : 2
                )
        }
        .frame(
            width: axis == .horizontal ? SessionPaneDividerSizing.layoutExtent : nil,
            height: axis == .vertical ? SessionPaneDividerSizing.layoutExtent : nil
        )
        .contentShape(Rectangle())
        .overlay {
            PaneResizeTrackingView(
                axis: axis,
                hoverChanged: { hovered = $0 },
                dragBegan: {},
                deltaChanged: onDelta,
                dragEnded: onEnded,
                doubleClicked: onDoubleClick
            )
            .frame(
                width: axis == .horizontal ? SessionPaneDividerSizing.hitExtent : nil,
                height: axis == .vertical ? SessionPaneDividerSizing.hitExtent : nil
            )
        }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .focusable()
        .accessibilityElement(children: .ignore)
        .onKeyPress(.leftArrow) {
            guard axis == .horizontal else { return .ignored }
            onDelta(-16)
            onEnded()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard axis == .horizontal else { return .ignored }
            onDelta(16)
            onEnded()
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard axis == .vertical else { return .ignored }
            onDelta(-16)
            onEnded()
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard axis == .vertical else { return .ignored }
            onDelta(16)
            onEnded()
            return .handled
        }
        .accessibilityAdjustableAction { direction in
            onDelta(direction == .increment ? 16 : -16)
            onEnded()
        }
        .accessibilityLabel(axis == .horizontal ? "Resize session columns" : "Resize stacked sessions")
        .accessibilityHint("Drag or use arrow keys to resize; double-click to balance panes")
        .help("Drag or use arrow keys to resize; double-click to balance panes")
    }
}

private enum SessionPaneDividerSizing {
    /// The visible rule consumes only one layout point. Its overlaid pointer
    /// target reaches into both adjacent cards, so acquisition stays generous
    /// without turning a splitter into a blank gutter.
    static let layoutExtent: CGFloat = 1
    static let hitExtent: CGFloat = 17
}

/// Makes the system NavigationSplitView divider easy to acquire while leaving
/// AppKit in charge of its min/max constraints, collapse behavior, restoration,
/// and accessibility. The tracker lives just inside the sidebar so it does not
/// shift layout or add another visible divider.
private struct NavigationSidebarResizeAffordance: View {
    @State private var hovered = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(hovered ? 0.95 : 0.42))
                .frame(width: NativeWorkspaceChrome.projectSidebarDividerWidth)
            Capsule()
                .fill(Color.accentColor.opacity(hovered ? 0.72 : 0.08))
                .frame(width: 3, height: 32)
        }
        // Overlay geometry does not consume layout, so the 17-point AppKit
        // tracker is centered across the real one-point divider. The former
        // right-aligned 17-point container lived wholly inside the sidebar and
        // was easy to miss when the pointer approached from the terminal.
        .overlay {
            NavigationSidebarResizeHandle()
                .frame(width: NativeWorkspaceChrome.projectSidebarDividerHitWidth)
                .onHover { hovered = $0 }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("Drag or use Left/Right arrows to resize; double-click to reset")
    }
}

struct NavigationSidebarResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
        nsView.updateAccessibilityFrame()
    }

    final class TrackingView: NSView {
        private var lastWindowX: CGFloat?
        private weak var activeSplitView: NSSplitView?
        private var activeDividerIndex: Int?
        private lazy var dividerAccessibilityElement = NavigationSidebarAccessibilityElement(
            owner: self
        )

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? {
            updateAccessibilityFrame()
            return [dividerAccessibilityElement]
        }

        fileprivate func updateAccessibilityFrame() {
            dividerAccessibilityElement.setAccessibilityFrameInParentSpace(bounds)
        }

        fileprivate func reportVisualAccessibilityAdjustment(_ action: String, adjusted: Bool) {
            guard ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1" else {
                return
            }
            print(
                "KAISOLA_NATIVE_VISUAL_SIDEBAR_AX="
                    + "\(action) adjusted=\(adjusted) value=\(accessibilityValue() ?? "nil")"
            )
        }

        func applyAccessibilityAdjustment(_ delta: CGFloat) -> Bool {
            let adjusted = adjustSidebar(by: delta)
            reportVisualAccessibilityAdjustment(
                delta >= 0 ? "element-increment" : "element-decrement",
                adjusted: adjusted
            )
            return adjusted
        }

        fileprivate var accessibilitySidebarValue: NSNumber? {
            guard let match = enclosingVerticalDivider() else { return nil }
            return NSNumber(value: Double(match.splitView.subviews[match.index].frame.maxX))
        }

        fileprivate var accessibilitySidebarEnabled: Bool {
            enclosingVerticalDivider() != nil
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            guard let match = enclosingVerticalDivider() else { return }
            window?.makeFirstResponder(self)
            if event.clickCount == 2 {
                match.splitView.setPosition(
                    NativeWorkspaceChrome.projectSidebarIdealWidth,
                    ofDividerAt: match.index
                )
                return
            }
            activeSplitView = match.splitView
            activeDividerIndex = match.index
            lastWindowX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard let splitView = activeSplitView,
                  let dividerIndex = activeDividerIndex,
                  let previous = lastWindowX,
                  splitView.subviews.indices.contains(dividerIndex) else { return }
            let current = event.locationInWindow.x
            lastWindowX = current
            let delta = current - previous
            guard abs(delta) >= 0.25 else { return }
            splitView.setPosition(
                splitView.subviews[dividerIndex].frame.maxX + delta,
                ofDividerAt: dividerIndex
            )
        }

        override func mouseUp(with event: NSEvent) {
            lastWindowX = nil
            activeSplitView = nil
            activeDividerIndex = nil
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123:
                adjustSidebar(by: -16)
            case 124:
                adjustSidebar(by: 16)
            default:
                super.keyDown(with: event)
            }
        }

        @discardableResult
        private func adjustSidebar(by delta: CGFloat) -> Bool {
            guard let match = enclosingVerticalDivider() else { return false }
            match.splitView.setPosition(
                match.splitView.subviews[match.index].frame.maxX + delta,
                ofDividerAt: match.index
            )
            NSAccessibility.post(element: self, notification: .valueChanged)
            return true
        }

        /// SwiftUI can place the overlay beneath more than one vertical
        /// NSSplitView. Select the actual divider whose window-coordinate X is
        /// under this handle; taking the first ancestor can resize a nested
        /// detail split instead of the 192-point project sidebar.
        private func enclosingVerticalDivider() -> (splitView: NSSplitView, index: Int)? {
            guard window != nil else { return nil }
            let handleX = convert(
                NSPoint(x: bounds.midX, y: bounds.midY),
                to: nil
            ).x
            var best: (splitView: NSSplitView, index: Int, distance: CGFloat)?
            var candidate = superview
            while let view = candidate {
                if let splitView = view as? NSSplitView,
                   splitView.isVertical,
                   splitView.subviews.count >= 2 {
                    for index in 0..<(splitView.subviews.count - 1) {
                        let dividerX = splitView.convert(
                            NSPoint(x: splitView.subviews[index].frame.maxX, y: 0),
                            to: nil
                        ).x
                        let distance = abs(dividerX - handleX)
                        if best == nil || distance < best!.distance {
                            best = (splitView, index, distance)
                        }
                    }
                }
                candidate = view.superview
            }
            guard let best,
                  best.distance <= NativeWorkspaceChrome.projectSidebarDividerHitWidth else {
                return nil
            }
            return (best.splitView, best.index)
        }
    }
}

/// SwiftUI proxies an NSViewRepresentable's role and value into its own
/// accessibility object, but macOS 26 does not forward standard adjustable
/// actions back to that view. A dedicated non-view element remains owned by
/// AppKit, so VoiceOver, Switch Control, and automation can address the real
/// divider instead of the silent SwiftUI proxy.
private final class NavigationSidebarAccessibilityOwner: @unchecked Sendable {
    weak var view: NavigationSidebarResizeHandle.TrackingView?

    init(_ view: NavigationSidebarResizeHandle.TrackingView) {
        self.view = view
    }
}

@MainActor
final class NavigationSidebarAccessibilityElement: NSAccessibilityElement, NSAccessibilitySlider {
    nonisolated private let owner: NavigationSidebarAccessibilityOwner

    init(owner: NavigationSidebarResizeHandle.TrackingView) {
        self.owner = NavigationSidebarAccessibilityOwner(owner)
        super.init()
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Resize project sidebar")
        setAccessibilityHelp("Drag or use Left and Right arrows to resize; double-click to reset")
        setAccessibilityParent(owner)
        setAccessibilityFrameInParentSpace(owner.bounds)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityLabel() -> String? {
        "Resize project sidebar"
    }

    // `NSAccessibilityElement` predates the role-specific protocols and
    // imports this optional Objective-C requirement as `String?`, while
    // `NSAccessibilitySlider` requires the selector explicitly as `String`.
    // Narrowing the override keeps the same Objective-C selector and satisfies
    // the role contract instead of relying on the inherited optional method.
    override func accessibilityIdentifier() -> String {
        "kaisola.navigation-sidebar-resize-handle"
    }

    nonisolated override func isAccessibilityEnabled() -> Bool {
        let owner = owner
        return MainActor.assumeIsolated {
            owner.view?.accessibilitySidebarEnabled == true
        }
    }

    nonisolated override func accessibilityValue() -> Any? {
        let owner = owner
        return MainActor.assumeIsolated {
            owner.view?.accessibilitySidebarValue
        }
    }

    nonisolated override func accessibilityPerformIncrement() -> Bool {
        let owner = owner
        return MainActor.assumeIsolated {
            owner.view?.applyAccessibilityAdjustment(16) == true
        }
    }

    nonisolated override func accessibilityPerformDecrement() -> Bool {
        let owner = owner
        return MainActor.assumeIsolated {
            owner.view?.applyAccessibilityAdjustment(-16) == true
        }
    }
}

/// The document and Files dividers use the same window-coordinate tracker as
/// session cards. Their previous SwiftUI DragGesture measured translation in a
/// coordinate space that moved as the panel width changed, feeding alternating
/// deltas back into the layout and making rich previews visibly oscillate.
private struct StablePanelResizeHandle: View {
    let label: String
    let onBegan: () -> Void
    let onDelta: (CGFloat) -> Void
    let onEnded: () -> Void
    let onDoubleClick: () -> Void
    @State private var hovered = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(hovered ? 0.95 : 0.58))
                .frame(width: 1)
            Capsule()
                .fill(Color.accentColor.opacity(hovered ? 0.72 : 0.10))
                .frame(width: 3, height: 32)
        }
        .frame(width: NativeDetailPaneSizing.dividerWidth)
        .contentShape(Rectangle())
        .overlay {
            PaneResizeTrackingView(
                axis: .horizontal,
                hoverChanged: { hovered = $0 },
                dragBegan: onBegan,
                deltaChanged: onDelta,
                dragEnded: onEnded,
                doubleClicked: onDoubleClick
            )
            .frame(width: NativeDetailPaneSizing.dividerHitWidth)
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .focusable()
        .accessibilityElement(children: .ignore)
        .onKeyPress(.leftArrow) {
            onBegan()
            onDelta(-16)
            onEnded()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            onBegan()
            onDelta(16)
            onEnded()
            return .handled
        }
        .accessibilityHint("Drag or use arrow keys to resize; double-click to reset")
        .accessibilityLabel(label)
    }
}

/// Tracks divider drags in window coordinates. A SwiftUI `DragGesture` uses
/// the moving divider's local coordinate space; updating pane weights during
/// the gesture moves that coordinate space and can feed a false reverse delta
/// back into the next event. AppKit's window coordinates remain stable and the
/// callback carries only the real incremental pointer motion.
private struct PaneResizeTrackingView: NSViewRepresentable {
    let axis: Axis
    let hoverChanged: (Bool) -> Void
    let dragBegan: () -> Void
    let deltaChanged: (CGFloat) -> Void
    let dragEnded: () -> Void
    let doubleClicked: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        update(nsView)
    }

    private func update(_ view: TrackingView) {
        view.axis = axis
        view.hoverChanged = hoverChanged
        view.dragBegan = dragBegan
        view.deltaChanged = deltaChanged
        view.dragEnded = dragEnded
        view.doubleClicked = doubleClicked
        view.window?.invalidateCursorRects(for: view)
    }

    final class TrackingView: NSView {
        var axis: Axis = .horizontal
        var hoverChanged: (Bool) -> Void = { _ in }
        var dragBegan: () -> Void = {}
        var deltaChanged: (CGFloat) -> Void = { _ in }
        var dragEnded: () -> Void = {}
        var doubleClicked: () -> Void = {}
        private var lastWindowPoint: NSPoint?
        private var trackingArea: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }

        override func mouseEntered(with event: NSEvent) {
            hoverChanged(true)
        }

        override func mouseExited(with event: NSEvent) {
            hoverChanged(false)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                lastWindowPoint = nil
                doubleClicked()
                return
            }
            lastWindowPoint = event.locationInWindow
            dragBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            let point = event.locationInWindow
            guard let previous = lastWindowPoint else {
                lastWindowPoint = point
                return
            }
            lastWindowPoint = point
            let delta = axis == .horizontal ? point.x - previous.x : point.y - previous.y
            guard abs(delta) >= 0.25 else { return }
            // AppKit's y axis grows upward; pane row weights grow downward.
            deltaChanged(axis == .vertical ? -delta : delta)
        }

        override func mouseUp(with event: NSEvent) {
            guard lastWindowPoint != nil else { return }
            lastWindowPoint = nil
            dragEnded()
        }
    }
}

private struct SessionPaneDropDelegate: DropDelegate {
    let targetID: String
    let targetSize: CGSize
    let move: @MainActor @Sendable (String, String, SessionPaneLayout.Edge) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.utf8PlainText])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.utf8PlainText]).first else { return false }
        let edge = nearestEdge(at: info.location)
        provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
            guard let data, let sourceID = String(data: data, encoding: .utf8), !sourceID.isEmpty else { return }
            Task { @MainActor in move(sourceID, targetID, edge) }
        }
        return true
    }

    private func nearestEdge(at point: CGPoint) -> SessionPaneLayout.Edge {
        let left = point.x
        let right = max(0, targetSize.width - point.x)
        let top = point.y
        let bottom = max(0, targetSize.height - point.y)
        let minimum = min(left, right, top, bottom)
        if minimum == left { return .left }
        if minimum == right { return .right }
        if minimum == top { return .top }
        return .bottom
    }
}

/// Settings lives inside the workspace as a sheet so discoverability no longer
/// depends on knowing the macOS menu shortcut. The traditional Command-comma
/// settings window remains available too.
private struct InAppSettingsSheet: View {
    @ObservedObject var settings: NativePreviewSettings
    let workspace: URL?
    let initialSectionID: String?
    let dismiss: () -> Void

    var body: some View {
        SettingsView(
            settings: settings,
            checkForUpdates: {
                NotificationCenter.default.post(name: .kaisolaCheckForUpdates, object: nil)
            },
            workspace: workspace,
            dismiss: dismiss,
            initialSectionID: initialSectionID
        )
    }
}

/// Pure layout policy for the terminal card grid. Kept separate from SwiftUI so
/// pane balancing stays deterministic and directly testable.
enum TerminalPaneGrid {
    /// Insets belong to the renderer frame, not the terminal card. The opaque
    /// card still reaches every rounded edge while the first glyph and caret
    /// stay clear of the curved mask.
    static let contentLeadingInset: CGFloat = 8
    static let contentTopInset: CGFloat = 7
    static let contentTrailingInset: CGFloat = 6
    static let contentBottomInset: CGFloat = 5

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

/// Pure document routing for a stable terminal card. During focus handoff the
/// broker role can move from split to primary (or back), so the last retained
/// snapshot is the no-blank-frame fallback until the new subscription arrives.
enum UnifiedTerminalDocumentResolver {
    static func resolve(
        id: String,
        primary: TerminalDocument,
        splits: [String: TerminalDocument],
        retained: [String: TerminalDocument]
    ) -> TerminalDocument? {
        if primary.sessionID == id { return primary }
        return splits[id] ?? retained[id]
    }
}

/// Full-height workspace metrics. The detail canvas has no titlebar inset;
/// only navigation that sits beneath the traffic lights reserves clearance.
enum NativeWorkspaceChrome {
    static let sidebarTrafficLightClearance: CGFloat = 40
    static let topBarTrafficLightClearance: CGFloat = 76
    static let projectSidebarMinimumWidth: CGFloat = 168
    static let projectSidebarIdealWidth: CGFloat = 200
    static let projectSidebarMaximumWidth: CGFloat = 260
    static let projectSidebarDividerWidth: CGFloat = 1
    /// Centered across the visible divider, not laid wholly inside either pane.
    static let projectSidebarDividerHitWidth: CGFloat = 17
    static let projectSidebarDividerReach: CGFloat =
        (projectSidebarDividerHitWidth - projectSidebarDividerWidth) / 2
}

/// A row that is still the focused pane can belong to a project that is no
/// longer active. In that case a click must still switch project context.
enum SurfaceSelectionPolicy {
    static func shouldRequestFocus(
        focusedPaneID: String?,
        targetID: String,
        browserOpen: Bool,
        activeProjectID: String?,
        targetProjectID: String
    ) -> Bool {
        browserOpen
            || focusedPaneID != targetID
            || activeProjectID != targetProjectID
    }
}

/// Opening a project is a sibling-navigation action. Starting NSOpenPanel in
/// the current repository makes Finder/File Provider enumerate that repository
/// before the user can move anywhere; its parent opens materially faster while
/// still landing beside the folders the user is most likely to choose.
enum NativeFolderPickerStartingPoint {
    static func preferred(currentProject: URL?) -> URL? {
        guard let currentProject else { return nil }
        let normalized = currentProject.standardizedFileURL
        let parent = normalized.deletingLastPathComponent()
        return parent.path == normalized.path ? normalized : parent
    }
}

/// Turns persisted panel preferences into widths that fit the *current* detail
/// canvas. Preferences remain untouched, so expanding the window restores the
/// user's chosen sizes; only the effective presentation compresses. This keeps
/// terminal + document + Files simultaneously usable at the minimum window.
enum NativeDetailPaneSizing {
    struct Widths: Equatable {
        let preview: CGFloat
        let rail: CGFloat
    }

    /// One visible/layout point with a forgiving overlaid acquisition target.
    static let dividerWidth: CGFloat = 1
    static let dividerHitWidth: CGFloat = 17
    static let minimumContentWidth: CGFloat = 220
    private static let compactPreviewFloor: CGFloat = 210
    private static let compactRailFloor: CGFloat = 150

    static func resolve(
        totalWidth: CGFloat,
        preferredPreview: Double?,
        preferredRail: Double?
    ) -> Widths {
        var preview: CGFloat = preferredPreview.map { CGFloat($0) } ?? 0
        var rail: CGFloat = preferredRail.map { CGFloat($0) } ?? 0
        let panelCount = (preferredPreview == nil ? 0 : 1) + (preferredRail == nil ? 0 : 1)
        let panelBudget = max(
            0,
            totalWidth - CGFloat(panelCount) * dividerWidth - minimumContentWidth
        )
        var excess = max(0, preview + rail - panelBudget)

        // Files is the utility rail, so it yields width before the active
        // document. This keeps rendered Markdown legible while preserving a
        // useful terminal minimum when all three surfaces are open.
        if preferredRail != nil {
            let reduction = min(excess, max(0, rail - compactRailFloor))
            rail -= reduction
            excess -= reduction
        }
        if preferredPreview != nil {
            let reduction = min(excess, max(0, preview - compactPreviewFloor))
            preview -= reduction
            excess -= reduction
        }
        // An already-narrow split-view sidebar can leave less than the compact
        // floors. Continue compressing proportionally rather than clipping or
        // silently hiding one of the two explicitly-open panels.
        if excess > 0, preview + rail > 0 {
            let sum = preview + rail
            let previewShare = preview / sum
            preview = max(80, preview - excess * previewShare)
            rail = max(80, rail - excess * (1 - previewShare))
        }
        return Widths(preview: preview, rail: rail)
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

    private var selectedSurfaceID: String? {
        model.selectedChatID ?? model.selectedMeshID ?? model.selectedSessionID
    }

    var body: some View {
        ScrollViewReader { proxy in
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
                            if let usage = chat.conversation.usage,
                               let amount = usage.costAmount,
                               let cost = UsageCenter.costLabel(
                                   amount: amount,
                                   currency: usage.costCurrency
                               ) {
                                Text(cost)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            surfaceTabBackground(
                                selected: model.selectedChatID == chat.id,
                                tint: WorkspacePalette.chat
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Close Chat", role: .destructive) { model.closeChat(chat.id) }
                    }
                    .id(chat.id)
                }
                ForEach(meshes) { mesh in
                    Button { model.selectMesh(mesh.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.hexagongrid.fill")
                                .foregroundStyle(WorkspacePalette.mesh)
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
                                tint: WorkspacePalette.mesh
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Close Mesh", role: .destructive) { closeMesh(mesh) }
                    }
                    .id(mesh.id)
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
                            // A dot, not the agent glyph. This tab is the most
                            // width-starved surface in the shell and the agent
                            // name is already the title's prefix ("Claude ·
                            // kaisola"), so a 20x20 tinted chip spent a fifth of
                            // the tab restating it. The dot keeps the one signal
                            // the tab has nowhere else to put — live/working —
                            // since there is no detail line or spinner here.
                            Circle()
                                .fill(visible || working
                                      ? WorkspacePalette.terminal
                                      : Color.secondary.opacity(0.45))
                                .frame(width: 6, height: 6)
                            Text(model.sessionTitle(for: session)).lineLimit(1)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            surfaceTabBackground(
                                selected: model.selectedSessionID == session.id,
                                tint: WorkspacePalette.terminal
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
                    .id(session.id)
                }
                Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: selectedSurfaceID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: 36)
    }

    private func surfaceTabBackground(selected: Bool, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius, style: .continuous)
            .fill(selected ? tint.opacity(0.10) : Color.primary.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius, style: .continuous)
                    .stroke(
                        selected ? tint.opacity(0.22) : Color.primary.opacity(0.075),
                        lineWidth: KaisolaVisualSystem.hairline
                    )
            }
    }
}

private struct ChatRow: View {
    @ObservedObject var conversation: AcpConversation
    let accountLabel: String?
    let isVisible: Bool

    init(chat: AcpChatHandle, isVisible: Bool) {
        self.conversation = chat.conversation
        self.accountLabel = chat.accountBinding?.accountID == nil
            ? nil
            : chat.accountBinding?.label
        self.isVisible = isVisible
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: KaisolaVisualSystem.rowIconGlyph, weight: .medium))
                .foregroundStyle(isVisible || conversation.isConnected ? WorkspacePalette.chat : Color.secondary)
                .frame(width: KaisolaVisualSystem.rowIconSize, height: KaisolaVisualSystem.rowIconSize)
                .background(isVisible ? WorkspacePalette.chat.opacity(0.11) : Color.clear,
                            in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.rowIconRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title).font(.system(size: 12)).lineLimit(1).layoutPriority(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(conversation.isRunning ? WorkspacePalette.chat : .secondary)
            }
            if conversation.isRunning {
                Spacer()
                ProgressView().controlSize(.mini).scaleEffect(0.6)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var value = conversation.isRunning ? "Working…" : conversation.isConnected ? "Chat" : "Starting…"
        if let accountLabel { value += " · \(accountLabel)" }
        if let usage = conversation.usage,
           let amount = usage.costAmount,
           let cost = UsageCenter.costLabel(amount: amount, currency: usage.costCurrency) {
            value += " · \(cost)"
        }
        return value
    }
}

private struct MeshRow: View {
    @ObservedObject var mesh: MeshSession
    let isVisible: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: KaisolaVisualSystem.rowIconGlyph, weight: .medium))
                .foregroundStyle(WorkspacePalette.mesh)
                .frame(width: KaisolaVisualSystem.rowIconSize, height: KaisolaVisualSystem.rowIconSize)
                .background(isVisible ? WorkspacePalette.mesh.opacity(0.11) : Color.clear,
                            in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.rowIconRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(mesh.title).font(.system(size: 12)).lineLimit(1).layoutPriority(1)
                Text(mesh.stage == "Idle" ? "Ready" : mesh.stage)
                    .font(.system(size: 10))
                    .foregroundStyle(mesh.stage == "Idle" ? Color.secondary : WorkspacePalette.mesh)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
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
    let companionControllerName: String?
    let agent: AgentProfile?
    let accountLabel: String?
    var branch: String?
    var meta: TerminalMeta?
    let isVisible: Bool
    let canOpenSplit: Bool
    let isOpenInSplit: Bool
    let toggleSplit: () -> Void
    let select: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: select) {
                HStack(spacing: 7) {
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
                    .font(.system(size: KaisolaVisualSystem.rowIconGlyph, weight: .medium))
                    .frame(width: KaisolaVisualSystem.rowIconSize, height: KaisolaVisualSystem.rowIconSize)
                    .background(
                        isVisible ? WorkspacePalette.terminal.opacity(0.11) : Color.clear,
                        in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.rowIconRadius, style: .continuous)
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            // The title is the only compressible view in this
                            // row; without this it always loses to its
                            // fixed-size siblings and truncates first.
                            .layoutPriority(1)
                        Text(sessionDetail)
                            .font(.system(size: 10))
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
                    SurfaceVisibilityControlLabel(isVisible: isOpenInSplit)
                }
                .buttonStyle(.plain)
                .help(isOpenInSplit ? "Hide this session from the workspace" : "Open this session beside the current one")
                .accessibilityLabel(isOpenInSplit ? "Hide \(title) session" : "Open \(title) beside the current session")
            }
        }
        .padding(.vertical, 1)
    }

    private var rowSymbol: String {
        if let agent { return agent.symbol }
        return owned ? "terminal.fill" : "terminal"
    }

    private var iconColor: Color {
        if session.exited { return .secondary }
        if isVisible { return WorkspacePalette.terminal }
        if case .working = session.agentActivity { return WorkspacePalette.terminal }
        return .secondary
    }

    private var sessionDetail: String {
        var detail: String
        if session.exited {
            detail = "Finished"
        } else if let companionControllerName {
            detail = "Controlled from \(companionControllerName)"
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
        if let accountLabel { detail += " · \(accountLabel)" }
        if let branch, !session.exited { detail += " · ⎇ \(branch)" }
        if let meta, !session.exited {
            if let name = meta.processName { detail += " · \(name)" }
            if !meta.ports.isEmpty { detail += " · :" + meta.ports.map(String.init).joined(separator: ",") }
        }
        return detail
    }

    private var statusColor: Color {
        if companionControllerName != nil, !session.exited { return .accentColor }
        if case .working = session.agentActivity, !session.exited { return WorkspacePalette.terminal }
        return .secondary
    }
}

private struct SurfaceVisibilityControlLabel: View {
    let isVisible: Bool

    var body: some View {
        // Icon-only: the spelled-out "Show"/"Hide" cost ~30pt of every sidebar
        // row — over a third of the width the session title was competing for —
        // to restate what the glyph and the tooltip already say. Both call sites
        // supply `.help` and `.accessibilityLabel`, so nothing is lost.
        Label(
            isVisible ? "Hide" : "Show",
            systemImage: isVisible ? "rectangle.split.2x1.fill" : "rectangle.split.2x1"
        )
        .font(.system(size: 10, weight: .semibold))
        .labelStyle(.iconOnly)
        .foregroundStyle(isVisible ? WorkspacePalette.active : Color.secondary)
        .frame(width: 22, height: 20)
        .background(
            (isVisible ? WorkspacePalette.active : Color.secondary).opacity(isVisible ? 0.11 : 0.07),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    (isVisible ? WorkspacePalette.active : Color.secondary).opacity(0.18),
                    lineWidth: 0.5
                )
        }
        .contentShape(Capsule())
    }
}

private struct ConnectionFooter: View {
    @EnvironmentObject private var auth: AuthModel
    let state: AppModel.ConnectionState
    let brokerUpgradeState: BrokerUpgradeState
    let reload: () -> Void
    var jumpToAttention: ((String) -> Void)?
    var newMesh: (() -> Void)?
    var newStagedMesh: (() -> Void)?
    var newIdeaMesh: (() -> Void)?
    let filesVisible: Bool
    let toggleFiles: () -> Void
    let filePreviewVisible: Bool
    let toggleFilePreview: () -> Void
    let showSettings: () -> Void
    let showUsage: () -> Void

    @ObservedObject private var usage = UsageCenter.shared

    @ObservedObject private var attention = AttentionCenter.shared
    @State private var showInbox = false

    private static let appVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "Dev"

    var body: some View {
        HStack(spacing: 4) {
            accountMenu
                .padding(.leading, 12)
                .help(state.detail ?? state.title)
            KaisolaGlassEffectGroup(spacing: 4) {
                HStack(spacing: 4) {
                    shelfButton(
                        "gearshape.fill",
                        help: "Settings",
                        tint: Color(red: 0.44, green: 0.50, blue: 0.20),
                        action: showSettings
                    )

                    brokerUpgradeIndicator

                    if newMesh != nil || newStagedMesh != nil || newIdeaMesh != nil {
                        Menu {
                            if let newMesh { Button("New Mesh (all agents)", action: newMesh) }
                            if let newStagedMesh { Button("New Staged Mesh (scout → execute)", action: newStagedMesh) }
                            if let newIdeaMesh { Button("New Idea Mesh (brainstorm)", action: newIdeaMesh) }
                        } label: {
                            Image(systemName: "circle.hexagongrid.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.purple)
                                .frame(width: 22, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .tint(.purple)
                        .help("New Mesh — flat, staged, or idea")
                    }

                    shelfButton(
                        filePreviewVisible ? "doc.text.fill" : "doc.text.magnifyingglass",
                        help: filePreviewVisible ? "Hide file preview" : "Show file preview",
                        active: filePreviewVisible,
                        action: toggleFilePreview
                    )

                    shelfButton(
                        filesVisible ? "sidebar.trailing" : "sidebar.right",
                        help: filesVisible ? "Hide Files (Command-B)" : "Show Files (Command-B)",
                        active: filesVisible,
                        action: toggleFiles
                    )

                    if UsageCenter.footerCostChipLabel(usage.costTotals) != nil {
                        footerCostButton
                    }

                    attentionButton
                }
            }
            Spacer(minLength: 2)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 7)
        .frame(height: 40)
    }

    private var accountSignInIsRunning: Bool {
        if case .signingIn = auth.phase { return true }
        return false
    }

    private func shelfButton(
        _ symbol: String,
        help: String,
        active: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let color = tint ?? (active ? Color.primary : Color.secondary)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(
                    active ? color.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var footerCostButton: some View {
        let totals = usage.costTotals
        let label = UsageCenter.footerCostChipLabel(totals) ?? "Cost"
        let accessibility = UsageCenter.costAccessibilityLabel(totals) ?? "Session cost"
        return Button(action: showUsage) {
            HStack(spacing: 3) {
                Image(systemName: "dollarsign.circle")
                Text(label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Color.secondary.opacity(0.08), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help(accessibility)
        .accessibilityLabel(accessibility)
        .accessibilityHint("Opens Usage settings")
    }

    private var accountMenu: some View {
        Menu {
            if let account = auth.account {
                Text(account.displayName ?? account.email)
                Text(account.email)
                Button {
                    Task { await auth.signOut() }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(accountSignInIsRunning)
            }
            Divider()
            Button(action: showSettings) {
                Label("Settings…", systemImage: "gearshape")
            }
            Button(action: showUsage) {
                Label("Usage…", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            Divider()
            Button(action: reload) {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Text("Kaisola v\(Self.appVersion)")
            Text(state.detail ?? state.title)
            if case .current = brokerUpgradeState {
                Text("Broker helper is current")
            } else if case .unknown = brokerUpgradeState {
                EmptyView()
            } else {
                Text(brokerUpgradeState.detail)
            }
            if usage.totalPeakTokens > 0 {
                Text("Usage: \(usage.totalPeakTokens / 1000)k tokens · \(Int((usage.contextPressure * 100).rounded()))% context")
            }
        } label: {
            Color.clear
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .clipped()
        // Keep the asynchronously loaded photo outside AppKit's Menu label
        // bridge. The bridge otherwise promotes the source bitmap's intrinsic
        // dimensions and drops its SwiftUI mask when the image finishes loading.
        .overlay {
            AccountAvatarView(account: auth.account, size: 22)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(state.isConnected ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                }
                .allowsHitTesting(false)
        }
        .help("Account and workspace settings")
        .accessibilityLabel("Kaisola account and settings")
    }

    @ViewBuilder
    private var brokerUpgradeIndicator: some View {
        switch brokerUpgradeState {
        case .unknown, .current:
            EmptyView()
        case .checking, .updating:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
                .help(brokerUpgradeState.detail)
                .accessibilityLabel(brokerUpgradeState.detail)
        case .pending:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 26, height: 26)
                .background(Color.orange.opacity(0.11), in: Capsule())
                .help(brokerUpgradeState.detail)
                .accessibilityLabel(brokerUpgradeState.detail)
        }
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
