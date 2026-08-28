import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Window-local presentation effects carried by registered commands. Keeping
/// this mapping value-based lets tests prove that a global command targets the
/// intended window without mounting the full workspace or touching a broker.
enum RootShellLocalCommand: Equatable, Sendable {
    case toggleCommandPalette
    case toggleOmniBar
    case toggleDocumentPreview
    case presentReadinessChecklist

    init?(commandID: AppCommandID) {
        switch commandID {
        case .commandPalette: self = .toggleCommandPalette
        case .messageCurrentAgent: self = .toggleOmniBar
        case .toggleDocumentPreview: self = .toggleDocumentPreview
        case .readinessChecklist: self = .presentReadinessChecklist
        default: return nil
        }
    }
}

/// What happens to the in-workspace Settings takeover for each way the user
/// can act on it. Pure, so the toggle contract ("pressing the gear again
/// restores the workspace", Esc and Back always restore, a deep link always
/// opens) is a table the tests hold rather than four call sites agreeing.
enum SettingsTakeoverPolicy {
    enum Action: Equatable {
        /// The footer gear, the ⌘, command, the menu item — the doors toggle.
        case pressSettingsDoor
        /// The takeover's own "Back to app".
        case backToApp
        case escape
        /// A deep link that names a section (provider settings, onboarding
        /// hand-off, usage) always lands on the open page.
        case openSection
    }

    static func isPresented(after action: Action, from isPresented: Bool) -> Bool {
        switch action {
        case .pressSettingsDoor: !isPresented
        case .backToApp, .escape: false
        case .openSection: true
        }
    }

    /// `kaisolaOpenSettingsSurface` carries a section identifier only when
    /// something deep-linked to one. A bare post is a whole-app door — ⌘, or
    /// the bare menu item — and so toggles exactly like the footer gear;
    /// with the takeover covering the footer, that press is the way back.
    static func action(forOpenSettingsSurfaceSection sectionID: String?) -> Action {
        sectionID == nil ? .pressSettingsDoor : .openSection
    }
}

/// The terminal header is resolved from the terminal's own lifecycle and input
/// authority so its icon and VoiceOver label always describe the same state.
struct TerminalHeaderPresentation: Equatable {
    enum Tone: Equatable {
        case ready
        case inactive
    }

    let systemImage: String
    let accessibilityLabel: String
    let tone: Tone

    static func resolve(
        exited: Bool,
        authority: TerminalSurfaceAuthority,
        inputDegraded: Bool = false
    ) -> Self {
        if exited {
            return Self(
                systemImage: "stop.circle.fill",
                accessibilityLabel: "Session ended",
                tone: .inactive
            )
        }

        if inputDegraded {
            return Self(
                systemImage: "exclamationmark.triangle.fill",
                accessibilityLabel: "Terminal input paused",
                tone: .inactive
            )
        }

        switch authority {
        case .localController(active: true):
            return Self(
                systemImage: "checkmark.circle.fill",
                accessibilityLabel: "Terminal ready",
                tone: .ready
            )
        case .localController(active: false):
            return Self(
                systemImage: "clock.arrow.circlepath",
                accessibilityLabel: "Terminal input retrying automatically",
                tone: .inactive
            )
        case .observerOnly:
            return Self(
                systemImage: "eye",
                accessibilityLabel: "Terminal controlled by another window or Companion",
                tone: .inactive
            )
        }
    }
}

/// Separates live write authority from durable local provenance for chrome.
/// An ended local terminal is no longer input-enabled, but it must not be
/// relabeled as a foreign observation or lose its local Git affordance.
struct TerminalOwnershipPresentation: Equatable {
    let isObserved: Bool
    let gitDirectory: URL?

    init(
        isLiveOwner: Bool,
        hasDurableOwnership: Bool,
        directory: URL?
    ) {
        let isLocal = isLiveOwner || hasDurableOwnership
        isObserved = !isLocal
        gitDirectory = isLocal ? directory : nil
    }
}

/// Resolves the label applied to the whole session-header focus button. An
/// explicit parent label must carry a running chat's live activity because it
/// replaces the labels of the thinking indicator nested inside the button.
struct SessionHeaderAccessibilityLabel {
    static func resolve(
        title: String,
        statusLabel: String,
        liveActivityLabel: String? = nil
    ) -> String {
        "\(title), \(liveActivityLabel ?? statusLabel)"
    }
}

/// Value-only restoration state shared with the session pane. AppModel owns
/// the lifecycle classification; the view only turns this context into copy
/// and controls.
struct MissingTerminalPaneContext: Equatable {
    enum State: Equatable {
        case awaitingInventory
        case restoringController
        case settledDurable
        case invalid
    }

    let state: State
    let title: String
    let symbol: String
    let canClose: Bool
}

/// One presentation contract for every place an absent terminal appears. This
/// keeps its header, empty state, accessibility label, and Close affordance in
/// agreement while terminal restoration is still being decided.
struct MissingTerminalPanePresentation: Equatable {
    let title: String
    let symbol: String
    let statusLabel: String
    let contentTitle: String
    let detail: String
    let accessibilityLabel: String
    let showsClose: Bool

    static func resolve(context: MissingTerminalPaneContext) -> Self {
        let title: String
        let symbol: String
        let statusLabel: String
        let contentTitle: String
        let detail: String
        let showsClose: Bool

        switch context.state {
        case .awaitingInventory:
            title = context.title.isEmpty ? "Terminal" : context.title
            symbol = context.symbol.isEmpty ? "terminal" : context.symbol
            statusLabel = "Restoring terminal"
            contentTitle = "Restoring terminal"
            detail = "Checking local terminal state before restoring this session."
            showsClose = context.canClose
        case .restoringController:
            title = context.title.isEmpty ? "Terminal" : context.title
            symbol = context.symbol.isEmpty ? "terminal" : context.symbol
            statusLabel = "Restoring terminal"
            contentTitle = "Restoring terminal"
            detail = "Restoring terminal input."
            showsClose = context.canClose
        case .settledDurable:
            title = context.title.isEmpty ? "Terminal" : context.title
            symbol = context.symbol.isEmpty ? "terminal" : context.symbol
            statusLabel = "Terminal unavailable"
            contentTitle = "Terminal unavailable"
            detail = "This terminal is no longer running. Close it or start a new session."
            showsClose = context.canClose
        case .invalid:
            title = "Terminal"
            symbol = "terminal"
            statusLabel = "Session unavailable"
            contentTitle = "Session unavailable"
            detail = ""
            showsClose = false
        }

        return Self(
            title: title,
            symbol: symbol,
            statusLabel: statusLabel,
            contentTitle: contentTitle,
            detail: detail,
            accessibilityLabel: "\(title), \(statusLabel)",
            showsClose: showsClose
        )
    }
}

struct RootShellView: View {
    nonisolated static func shouldAutomaticallyRefreshPlanUsage(
        environment: [String: String]
    ) -> Bool {
        !NativePreviewSettings.isIsolatedFixture(environment: environment)
    }

    nonisolated static func shouldPresentOnboarding(
        environment: [String: String],
        defaults: UserDefaults = .standard
    ) -> Bool {
        !NativePreviewSettings.isIsolatedFixture(environment: environment)
            && OnboardingState.shouldShow(defaults: defaults)
    }

    /// Drives the isolated optimized interaction gate through the same sheet,
    /// dismissal, command palette, and local-command route as production. The
    /// app delegate still supplies a broker-free fixture model.
    nonisolated static func shouldPresentReadinessReopenFixture(
        environment: [String: String]
    ) -> Bool {
        environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
            && environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "onboarding-reopen"
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: NativePreviewSettings
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var rememberedSessions: RememberedSessionCatalogCenter
    @ObservedObject private var attention = AttentionCenter.shared
    @ObservedObject private var companionHost = CompanionHost.shared
    @ObservedObject private var keymap = AppCommandKeymapCenter.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @State private var renameTarget: String?
    @State private var sidebarDropTargeted = false
    /// Chat id awaiting a typed model id (the menu's "Custom Model…").
    @State private var customModelTarget: String?
    @State private var customModelText: String = ""
    @State private var signingInChatAccount: UsageAccountProfile?
    /// The blocked chat whose sign-in sheet is open, so dismissal can start
    /// that chat's verification window rather than leaving the gate hanging.
    @State private var signingInChatID: String?
    @State private var renameProjectTarget: String?
    @State private var renameText: String = ""
    @State private var gitRepo: URL?
    @State private var showPalette = false
    @State private var showOmniBar = false
    @State private var showOnboarding = false
    /// Whether the Settings takeover covers the workspace. Never write this
    /// directly — `applySettingsTakeover(_:)` routes every change through the
    /// deferred structural-switch discipline (see
    /// `NativePreviewSettings.requestNavigationLayout` for the crash this
    /// guards against). The workspace stays mounted underneath, so sessions
    /// keep running and Back to app restores it exactly as it was.
    @State private var showSettings = false
    @State private var settingsSectionID: String?
    /// One unfinished chooser tab per project, owned by this window only. It
    /// never enters AppModel or any durable session and process state.
    @State private var newSessionDrafts = NewSessionDraftState()
    /// Native sidebar visibility is window-local. Once AppKit collapses the
    /// source list, the detail column reaches the titlebar and its first pane
    /// must clear the traffic lights and native Show Sidebar button itself.
    @State private var leftTreeColumnVisibility = RootSidebarVisibilityFixture.initialVisibility(
        environment: ProcessInfo.processInfo.environment
    )
    /// Opt-in, window-local follow mode. It is deliberately off at launch so a
    /// background tool call can never steal the user's document unexpectedly.
    @State private var followsSelectedAgentFiles = false
    /// A Settings destination requested from the readiness sheet. Present it
    /// only after that sheet has actually dismissed so SwiftUI never has to
    /// arbitrate two simultaneous sheet presentations.
    @State private var onboardingSettingsSectionID: String?
    @State private var quickActionsTarget: QuickActionsTarget?
    @State private var terminalTranscriptTarget: AppModel.TerminalTranscriptContext?
    @State private var terminalTranscriptOpenedFromLiveBoundary = false
    /// A permanent Mesh deletion whose active turns or worktrees require a deliberate
    /// destructive choice.
    private struct MeshDeleteConfirmation {
        let id: String
        let dirty: Int
        let running: Bool
    }
    @State private var meshDeleteConfirm: MeshDeleteConfirmation?
    /// Shared by the two halves of the sidebar divider's grab corridor, which
    /// have to be separate views on separate sides of an `NSSplitView` clip but
    /// are one affordance to the user.
    @State private var sidebarDividerHovered = false
    /// Bumped on every hover transition reported by EITHER half's tracker.
    ///
    /// The two halves are separate `NSTrackingArea`s on separate `NSView`s, so
    /// as the pointer crosses the split boundary there is no ordering guarantee
    /// between "the old side's exit" and "the new side's enter" — they are
    /// independent event streams, not one gesture. Measured, the sidebar side's
    /// clipped `visibleRect` reaches only ~0.5pt past the divider's centre
    /// before `NSSplitView` clips it away, so the margin an exit can race an
    /// enter within is thin rather than absent. Debouncing the exit (below)
    /// removes the dependency on that margin instead of trusting it.
    @State private var sidebarDividerHoverGeneration = 0
    /// Which detail divider the pointer is in the corridor of, if any. Their
    /// trackers were hoisted out of the handles into one overlay on the detail
    /// stack, so the highlight has to travel back down from here.
    @State private var hoveredDetailDivider: NativeDetailPaneSizing.Divider?

    /// Both halves write through this instead of the raw `@State` so a leaving
    /// tracker's "false" cannot land after the other half's tracker has already
    /// reported "true" for the same crossing — see
    /// `sidebarDividerHoverGeneration`. A "true" from either side is immediate;
    /// a "false" is applied only if 50ms pass with no intervening "true" from
    /// either tracker, which comfortably covers ordinary pointer speeds while
    /// staying well under anything a user would perceive as a stuck highlight.
    private var sidebarDividerHoveredBinding: Binding<Bool> {
        Binding(
            get: { sidebarDividerHovered },
            set: { inside in
                sidebarDividerHoverGeneration &+= 1
                guard inside else {
                    let generation = sidebarDividerHoverGeneration
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        guard generation == sidebarDividerHoverGeneration else { return }
                        sidebarDividerHovered = false
                    }
                    return
                }
                sidebarDividerHovered = true
            }
        )
    }

    /// Assess before presenting the permanent-delete confirmation. Clean work
    /// still requires that explicit decision; uncertainty blocks deletion.
    private func requestDeleteMesh(_ mesh: MeshSession) {
        Task {
            switch await mesh.discardAssessment() {
            case .safe:
                meshDeleteConfirm = .init(id: mesh.id, dirty: 0, running: mesh.anyRunning)
            case let .recoverableWork(columns):
                meshDeleteConfirm = .init(id: mesh.id, dirty: columns, running: mesh.anyRunning)
            case let .blocked(message):
                ToastCenter.shared.show(message, style: .error, duration: 5)
            }
        }
    }

    private var meshDeleteDestructiveTitle: String {
        guard let confirmation = meshDeleteConfirm else { return "Delete Mesh" }
        if confirmation.running, confirmation.dirty > 0 { return "Stop, Discard, and Delete" }
        if confirmation.running { return "Stop and Delete" }
        return "Discard and Delete"
    }

    /// Non-destructive Mesh close still stops active adapters, so make that
    /// consequence explicit while promising the durable state that remains.
    private func requestMoveMeshToRecentlyClosed(_ mesh: MeshSession) {
        let close: () -> Void = {
            _ = Task {
                if case let .blocked(message) = await model.closeMesh(
                    mesh.id,
                    allowStoppingRunning: true
                ) {
                    ToastCenter.shared.show(message, style: .error, duration: 5)
                }
            }
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Close “\(mesh.title)” to Recently Closed?"
        alert.informativeText = mesh.anyRunning
            ? "This stops every active agent. Transcripts, drafts, queued prompts, and recoverable worktrees stay available to restore."
            : "Transcripts, drafts, queued prompts, and recoverable worktrees stay available to restore."
        alert.addButton(withTitle: mesh.anyRunning ? "Close and Stop" : "Close Mesh")
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { close() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            close()
        }
    }

    /// Chat deletion really removes its persisted transcript and draft. Keep a
    /// separate non-destructive Stop action and require an explicit decision
    /// before entering the deletion path.
    private func requestDeleteChat(_ chat: AcpChatHandle) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(chat.conversation.title)”?"
        alert.informativeText = "This permanently removes the chat transcript and saved draft. Use Stop Chat if you only want to end the current agent process."
        alert.addButton(withTitle: "Delete Chat")
        alert.addButton(withTitle: "Cancel")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { Task { await model.deleteChat(chat.id) } }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            Task { await model.deleteChat(chat.id) }
        }
    }

    private func requestDeleteRecentlyClosed(_ surface: AppModel.RecentlyClosedSurface) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Permanently delete “\(surface.title)”?"
        switch surface.kind {
        case .chat:
            alert.informativeText = "This permanently removes the saved transcript, draft, and usage. This cannot be undone."
        case .mesh:
            alert.informativeText = "This permanently removes transcripts, draft, queued prompts, and every recoverable Mesh worktree, including unintegrated files or commits. This cannot be undone."
        }
        alert.addButton(withTitle: "Delete Permanently")
        alert.addButton(withTitle: "Cancel")
        let performDelete: () -> Void = {
            _ = Task {
                switch await model.deleteRecentlyClosedSurface(
                    surface.id,
                    allowRecoverableWork: true
                ) {
                case .completed, .unavailable:
                    break
                case .needsConfirmation:
                    ToastCenter.shared.show("Deletion still needs confirmation.", style: .error)
                case let .blocked(message):
                    ToastCenter.shared.show(message, style: .error, duration: 5)
                }
            }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { performDelete() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            performDelete()
        }
    }

    var body: some View {
        chromeWithPresentation
    }

    /// Notification handlers are kept in their own modifier chain so older
    /// Swift compilers do not have to solve the entire root view at once.
    private var chromeWithNotifications: some View {
        chromeDecorated
            .kaisolaReduceMotionFallback()
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
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaLocalCommand)) { note in
                guard let target = note.object as? AppModel,
                      target === model,
                      let rawID = note.userInfo?[AppCommandNotificationKey.commandID] as? String else {
                    return
                }
                performLocalCommand(AppCommandID(rawValue: rawID))
            }
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaOpenProviderSettings)) { note in
                guard let target = note.object as? AppModel,
                      target === model,
                      let sectionID = note.userInfo?[AcpProviderSettingsNotificationKey.sectionID] as? String else {
                    return
                }
                settingsSectionID = sectionID
                applySettingsTakeover(.openSection)
            }
            .onReceive(NotificationCenter.default.publisher(for: .kaisolaOpenSettingsSurface)) { note in
                guard let target = note.object as? AppModel, target === model else { return }
                let sectionID = note.userInfo?[
                    AcpProviderSettingsNotificationKey.sectionID
                ] as? String
                // A deep link names its destination and always lands open;
                // a bare post is the ⌘, door and toggles.
                if let sectionID { settingsSectionID = sectionID }
                applySettingsTakeover(
                    SettingsTakeoverPolicy.action(forOpenSettingsSurfaceSection: sectionID)
                )
            }
    }

    /// Model observation and fixture setup are separated from notification
    /// delivery to stay within the Swift 6.0 type-checking budget.
    private var chromeWithLifecycle: some View {
        chromeWithNotifications
            .onChange(of: model.latestAgentFileActivity) { _, activity in
                guard let activity,
                      WorkspaceAgentFileFollowPolicy.shouldOpen(
                        activity,
                        enabled: followsSelectedAgentFiles,
                        selectedProjectID: model.selectedProjectID,
                        selectedChatID: model.selectedChatID,
                        selectedMeshID: model.selectedMeshID
                      ) else { return }
                model.openFilePreview(activity.fileURL, pinned: false)
            }
            .onChange(of: model.projects.map(\.id)) { _, projectIDs in
                newSessionDrafts.retainProjects(Set(projectIDs))
            }
            .onAppear {
                let environment = ProcessInfo.processInfo.environment
                if Self.shouldPresentReadinessReopenFixture(environment: environment) {
                    showOnboarding = true
                } else if environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
                   environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "palette" {
                    showPalette = true
                } else if environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
                   environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "terminal-transcript",
                   let terminalID = model.sessions.first?.id {
                    DispatchQueue.main.async {
                        terminalTranscriptTarget = model.terminalTranscriptContext(for: terminalID)
                    }
                } else if Self.shouldPresentOnboarding(environment: environment) {
                    showOnboarding = true
                }
                if environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
                   ["new-session", "new-session-topbar"].contains(
                    environment["KAISOLA_NATIVE_VISUAL_SURFACE"] ?? ""
                   ) {
                    DispatchQueue.main.async {
                        guard let project = model.projects.first else { return }
                        beginNewSession(in: project)
                    }
                }
                // The Settings takeover over a live workspace, for visual QA
                // of the ChatGPT-style page: same deferred presentation path
                // as the footer gear.
                if environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
                   environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "settings-takeover" {
                    applySettingsTakeover(.openSection)
                }
            }
            .task(id: model.currentProjectDirectory?.standardizedFileURL.path) {
                guard Self.shouldAutomaticallyRefreshPlanUsage(
                    environment: ProcessInfo.processInfo.environment
                ) else { return }
                UsageCenter.shared.refreshPlanUsage(workspace: model.currentProjectDirectory)
            }
    }

    private var chromeWithPresentation: some View {
        chromeWithLifecycle
            .sheet(isPresented: $showOnboarding, onDismiss: presentOnboardingSettingsIfNeeded) {
                OnboardingView(
                    model: model,
                    settings: settings,
                    dismiss: { finishOnboarding() },
                    openAccounts: { finishOnboarding(openingSettings: .accounts) },
                    openUpdateSettings: { finishOnboarding(openingSettings: .updates) }
                )
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
            WorkspaceBackdropView(
                mode: settings.workspaceBackdrop,
                idle: NativeWorkspaceChrome.canvasIsIdle(
                    layoutIsEmpty: model.paneLayout(for: activeProjectID).isEmpty,
                    hasRecovery: model.missingSessionRecovery != nil,
                    browserMounted: model.browserCardURL != nil,
                    previewMounted: model.previewedFileURL != nil,
                    filesRailVisible: settings.workspaceRailVisible
                        && model.currentProjectDirectory != nil
                )
            )
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
        .sheet(item: Binding(get: { customModelTarget.map(RenameID.init) }, set: { customModelTarget = $0?.id })) { target in
            RenameSheet(text: $customModelText, title: "Model for this chat") { modelID in
                customModelTarget = nil
                Task { await model.switchChatModel(target.id, to: modelID) }
            } cancel: {
                customModelTarget = nil
            }
        }
        // Completion rides onDismiss, not the sheet's own dismiss closure, so
        // it runs however the sheet ends — Done, Cancel, auto-dismiss, or any
        // dismissal that bypasses the buttons. It re-arms the chat's bounded
        // verification with the window a real post-sign-in probe needs; the
        // launch-time five-second window always expired while the user was
        // still in the browser.
        .sheet(item: $signingInChatAccount, onDismiss: {
            if let chatID = signingInChatID {
                signingInChatID = nil
                model.completeChatAccountSignIn(chatID)
            }
        }) { profile in
            AccountSignInSheet(profile: profile) {
                signingInChatAccount = nil
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
                GitPanelView(repoRoot: repo.url) { agent, draft in
                    model.openChat(agent, inDirectory: repo.url, initialDraft: draft)
                    gitRepo = nil
                }
                    .frame(width: 520, height: 460)
            }
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
                registeredShortcut(.commandPalette)
                registeredShortcut(.toggleFiles)
                registeredShortcut(.toggleDocumentPreview)
                registeredShortcut(.messageCurrentAgent)
                registeredShortcut(.openExternalEditor)
            }
        )
        // The ChatGPT-style Settings takeover: a full-window page presented
        // OVER the workspace, which stays mounted (sessions keep running).
        // Below the palette and toast overlays so a summoned palette and any
        // toast still read above Settings.
        .overlay {
            if showSettings {
                WorkspaceSettingsTakeover(
                    settings: settings,
                    workspace: model.currentProjectDirectory,
                    initialSectionID: settingsSectionID,
                    interruptibleTurnCount: { model.interruptibleTurnCount },
                    close: { applySettingsTakeover(.backToApp) },
                    closeOnEscape: { applySettingsTakeover(.escape) }
                )
                .transition(.opacity)
            }
        }
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
            } else if showOmniBar {
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
            "Permanently Delete Mesh?",
            isPresented: Binding(get: { meshDeleteConfirm != nil }, set: { if !$0 { meshDeleteConfirm = nil } })
        ) {
            Button(meshDeleteDestructiveTitle, role: .destructive) {
                if let confirm = meshDeleteConfirm {
                    Task {
                        if case let .blocked(message) = await model.requestDeleteMesh(
                            confirm.id,
                            allowRecoverableWork: true
                        ) {
                            ToastCenter.shared.show(message, style: .error, duration: 5)
                        }
                    }
                }
                meshDeleteConfirm = nil
            }
            Button("Cancel", role: .cancel) { meshDeleteConfirm = nil }
        } message: {
            if let confirmation = meshDeleteConfirm, confirmation.running, confirmation.dirty > 0 {
                Text("Agents are still working and \(confirmation.dirty) column(s) contain unintegrated files or commits. Deleting stops the run and permanently discards that recoverable work.")
            } else if meshDeleteConfirm?.running == true {
                Text("One or more agents are still working. Deleting stops every turn and permanently removes the Mesh transcripts and draft.")
            } else if (meshDeleteConfirm?.dirty ?? 0) > 0 {
                Text("\(meshDeleteConfirm?.dirty ?? 0) column(s) contain unintegrated files or commits. Deleting discards that recoverable work permanently — integrate what you want to keep first.")
            } else {
                Text("This permanently removes the Mesh transcripts, draft, queued prompts, and worktree manifest. This cannot be undone.")
            }
        }
    }

    private func toggleCommandPalette() {
        let shouldPresent = !showPalette
        showOmniBar = false
        showPalette = shouldPresent
    }

    private func toggleOmniBar() {
        let shouldPresent = !showOmniBar
        showPalette = false
        showOmniBar = shouldPresent
    }

    private var commandContext: AppCommandContext {
        AppCommandContext(model: model, settings: settings)
    }

    private func runCommand(_ id: AppCommandID) {
        _ = AppCommandRegistry.execute(id, in: commandContext)
    }

    private func performLocalCommand(_ id: AppCommandID) {
        guard let command = RootShellLocalCommand(commandID: id) else { return }
        switch command {
        case .toggleCommandPalette:
            toggleCommandPalette()
        case .toggleOmniBar:
            toggleOmniBar()
        case .toggleDocumentPreview:
            toggleFilePreviewColumn()
        case .presentReadinessChecklist:
            showPalette = false
            showOmniBar = false
            showOnboarding = true
        }
    }

    @ViewBuilder
    private func registeredShortcut(_ id: AppCommandID) -> some View {
        if let definition = AppCommandRegistry.definition(for: id),
           let shortcut = keymap.shortcut(for: id) {
            let availability = AppCommandRegistry.availability(of: id, in: commandContext)
            Button(action: { runCommand(id) }) { EmptyView() }
                .keyboardShortcut(
                    shortcut.swiftUIKeyEquivalent,
                    modifiers: shortcut.swiftUIModifiers
                )
                .disabled(!availability.isEnabled)
                .accessibilityLabel(definition.title)
                .accessibilityHint(availability.reason ?? "")
        }
    }

    private func finishOnboarding(
        openingSettings destination: OnboardingSettingsDestination? = nil
    ) {
        OnboardingState.markSeen()
        onboardingSettingsSectionID = destination?.sectionID
        showOnboarding = false
    }

    private func presentOnboardingSettingsIfNeeded() {
        guard let sectionID = onboardingSettingsSectionID else { return }
        onboardingSettingsSectionID = nil
        settingsSectionID = sectionID
        applySettingsTakeover(.openSection)
    }

    /// The ONE write path for the Settings takeover. The next state comes
    /// from `SettingsTakeoverPolicy` and lands through
    /// `StructuralShellSwitch.performOutsideEventTracking`, the same
    /// discipline as a navigation-layout change: a whole-root presentation
    /// swap must never apply inside an AppKit event-tracking pass (the
    /// v0.1.146 NSSplitView divider crash).
    private func applySettingsTakeover(_ action: SettingsTakeoverPolicy.Action) {
        let next = SettingsTakeoverPolicy.isPresented(after: action, from: showSettings)
        StructuralShellSwitch.performOutsideEventTracking {
            guard showSettings != next else { return }
            // The chrome-wide Reduce Motion fallback neutralizes this
            // animation when asked; otherwise the page fades over the
            // workspace instead of cutting.
            withAnimation(.easeOut(duration: 0.18)) {
                showSettings = next
            }
        }
    }

    // MARK: - Layouts

    /// The one action surface injected into either navigation shell. Layout
    /// switching changes presentation only; it cannot select a different
    /// implementation of project, session, or destructive actions.
    private var shellActions: RootShellActionModel {
        RootShellActionModel(
            openDroppedProjects: { urls in
                let folders = urls.filter(\.hasDirectoryPath)
                guard !folders.isEmpty else { return false }
                for folder in folders { model.openProject(directory: folder) }
                return true
            },
            beginNewSession: { beginNewSession(in: $0) },
            selectRealSurface: { selectRealSurface() },
            useLeftTreeNavigation: { runCommand(.navigationLayout(.leftTree)) },
            moveProject: { model.moveProject(id: $0, toIndex: $1) },
            runQuickAction: { action, directory in
                Task { await model.runQuickAction(action, inProject: directory) }
            },
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
            projectContextMenu: { AnyView(projectContextMenu($0)) },
            sessionContextMenu: { AnyView(sessionContextMenuContent($0)) },
            chatContextMenu: { AnyView(chatContextMenuContent($0)) },
            meshContextMenu: { AnyView(meshContextMenuContent($0)) },
            renameSurface: { renameTarget = $0 },
            closeChat: { model.closeChat($0.id) },
            deleteChat: requestDeleteChat,
            closeMesh: requestMoveMeshToRecentlyClosed,
            deleteMesh: requestDeleteMesh,
            deleteRecentlyClosed: requestDeleteRecentlyClosed
        )
    }

    /// Nested project→session tree in a left sidebar (the default).
    private var leftTreeLayout: some View {
        let actions = shellActions
        return RootLeftTreeShell(
            actions: actions,
            columnVisibility: $leftTreeColumnVisibility
        ) { actions in
            VStack(spacing: 0) {
                // No "Projects" title row: the chrome panel already starts below
                // the traffic lights, the rail's own pinned project names the
                // workspace, and the two buttons that lived here survive in the
                // menu bar (File ▸ Open Folder…, View ▸ Navigation) and the
                // command palette. The rail begins directly under the traffic
                // light clearance, as the v4 mock has it.
                //
                // A selection-bound macOS sidebar paints a full-width blue block.
                // Navigation is explicit here so visible surfaces are communicated
                // by their blue icons instead of a heavy row treatment.
                List {
                    QuietProjectRail(
                        model: model,
                        attention: attention,
                        expansion: { expansionBinding($0) },
                        // The same fallback-bearing id the expansion binding
                        // uses, so the rail always pins exactly the project
                        // whose sessions are expanded.
                        isActiveProject: { activeProjectID == $0 },
                        selectSession: actions.selectSession,
                        beginNewSession: actions.beginNewSession,
                        draftForProject: { newSessionDrafts.draft(for: $0) },
                        selectedDraftID: newSessionDrafts.selectedDraftID,
                        selectDraft: selectNewSessionDraft,
                        selectRealSurface: actions.selectRealSurface,
                        cancelDraft: cancelNewSession,
                        contextMenu: actions.projectContextMenu,
                        sessionContextMenu: actions.sessionContextMenu,
                        chatContextMenu: actions.chatContextMenu,
                        meshContextMenu: actions.meshContextMenu,
                        deleteRecentlyClosed: actions.deleteRecentlyClosed
                    )
                    addProjectRow
                        .listRowInsets(QuietRailMetrics.listRowBleed)
                        .listRowSeparator(.hidden)
                    if auth.isSignedIn, showsRememberedSessionSection {
                        rememberedSessionSidebarSection
                    }
                }
                // A folder from Finder dropped anywhere on the rail opens as a
                // project — the zero-chrome sibling of the ghost row below it.
                // Typed to URLs, so the rail's own internal text drags (project
                // reorder) never collide with it.
                .dropDestination(for: URL.self) { urls, _ in
                    actions.openDroppedProjects(urls)
                } isTargeted: { sidebarDropTargeted = $0 }
                .overlay {
                    if sidebarDropTargeted {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                            .padding(3)
                            .allowsHitTesting(false)
                    }
                }
                // `.sidebar` reserves ~16pt of leading and trailing row inset
                // for a source-list look this rail does not use: every row
                // already zeroes its `listRowInsets` and paints its own wash.
                // At the 200pt default width those 31pt were the difference
                // between a title showing 7 characters and 15.
                .listStyle(.plain)
                // A rail shorter than its column has nowhere to go, and letting
                // it rubber-band anyway is what made the sidebar "recoil
                // spazztically" with no projects below the fold: every elastic
                // frame put the clip view outside its own scrollable range, and
                // `SidebarScrollTopPin` — which clamps to that range — yanked it
                // back mid-bounce, so the two fought at frame rate. Bouncing only
                // when there is something to bounce *to* removes the fight at its
                // source; the pin is taught to stand down during a gesture too,
                // for the case where the rail genuinely does overflow.
                .scrollBounceBehavior(.basedOnSize)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Projects, chats, and terminal sessions")
                // NavigationSplitView exposes only the one-pixel AppKit divider.
                // Add a quiet in-sidebar acquisition target that drives the same
                // NSSplitView in window coordinates, matching every other Kaisola
                // panel handle without replacing native sidebar behavior.
                //
                // Anchored to the List rather than the column as a whole: the
                // corridor's tracker fills whatever height it is given, and
                // attached any higher it ran the full column height, straight
                // through the footer row below. Centred 22pt on the trailing
                // edge, that reached ~5.5pt into the footer's own trailing
                // controls (settings/overflow) before a click or hover ever got
                // to them. The List already ends exactly where the footer
                // begins, so anchoring here excludes the footer's row height
                // for free — no footer-height constant to duplicate or keep in
                // sync. (The active header's "+" menu, at the List's own top
                // edge, still overlaps the corridor by ~1.5pt; fixing that
                // needs a change inside `QuietProjectRail`, out of scope here.)
                //
                // This is the ONE instance that vends the AX slider; the two
                // segments below cover the rest of the boundary silently.
                .overlay(alignment: .trailing) {
                    NavigationSidebarResizeAffordance(hovered: sidebarDividerHoveredBinding)
                        .frame(width: NativeWorkspaceChrome.projectSidebarDividerWidth)
                }
                // The footer's own 40pt of the boundary is deliberately NOT
                // covered. A background segment there was measured and does not
                // work — behind the footer's controls the tracker never receives
                // `.cursorUpdate` — and an overlay would put an 11pt corridor
                // straight through the gear and overflow buttons, whose tap
                // targets start 3pt in from the trailing edge. The corridor runs
                // the List and the header band; the footer keeps its controls.
                footer
            }
            // The graduated rail is Safari's full-height sidebar, not an
            // inset card: ONE surface that owns the entire left edge of the
            // window — traffic lights inside its top band — with the content
            // starting below the traffic-light/toolbar lane. The floating
            // chrome card the preview wave tried (gutter, radius, shadow) is
            // gone; Michael's corrections ask for the card to BE the column
            // and for its tone to run seamlessly into the canvas, so the
            // boundary is carried by the split divider's hairline alone.
            .padding(.top, NativeWorkspaceChrome.chromePanelTopInset)
            // The traffic-light clearance band the padding above just created is
            // the third and last piece of the boundary. It carries nothing at
            // all, so this segment can be a plain overlay — and it has to be
            // attached AFTER the padding, or it lands on the List's top rows
            // instead of on the empty band.
            .overlay(alignment: .topTrailing) {
                NavigationSidebarResizeAffordance(
                    hovered: sidebarDividerHoveredBinding,
                    exposesAccessibility: false
                )
                .frame(
                    width: NativeWorkspaceChrome.projectSidebarDividerWidth,
                    height: NativeWorkspaceChrome.chromePanelTopInset
                )
            }
            // Seamless rails ↔ canvas (2026-08-28, "the color and theme of
            // the lhs and rhs rails should look seemless transition with the
            // canvas"): the rail mounts the CANVAS recipe, not the rail
            // recipe. Measured on the light empty-workspace fixture: the
            // sidebar samples 239/239/240 — byte-identical to the canvas —
            // because the material plate composites over the column, not
            // with it, so the boundary carries no tone jump and the divider
            // hairline is the whole seam. Mounting nothing here instead
            // reads 246 against 239: NavigationSplitView's own column
            // material shows through, a visibly lighter rail. The dedicated
            // sidebar wash (`.sidebar` material + its own veil) that made
            // the shipped rails read a step apart from the canvas is simply
            // no longer mounted; its constants stay untouched in the
            // appearance layer.
            .background {
                WorkspaceBackdropView(mode: settings.workspaceBackdrop)
                    .ignoresSafeArea()
            }
            // `ideal:` below is honoured for the double-click reset but not for
            // the opening width; this plants the one AppKit view that can fix
            // that, once per window. It draws nothing and takes no hits.
            .background {
                InitialSidebarWidthApplier(idealWidth: resolvedProjectRailIdealWidth)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            // Holds the rail at its top through launch. Without it AppKit's
            // keep-the-top-row-stable compensation, which SwiftUI triggers on
            // every row diff, leaves the list parked above its own content and
            // the first project row clipped or gone. See `SidebarScrollPin`.
            .background {
                SidebarScrollTopPin()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .navigationSplitViewColumnWidth(
                min: NativeWorkspaceChrome.projectSidebarMinimumWidth,
                ideal: resolvedProjectRailIdealWidth,
                max: NativeWorkspaceChrome.projectSidebarMaximumWidth
            )
        } detail: { _ in
            detailArea
        }
    }

    /// The detail column: the content on its own inset floating card, gutters
    /// equal on all four sides.
    ///
    /// v1.1.9 deleted the 40pt chrome band that used to sit above it and gave
    /// the card the height — but only 12 of the 40 points actually reached the
    /// pane. The card could not run to the window's top, because the two panel
    /// toggles were still anchored to *its* top-right corner and the Files
    /// rail's own 30pt header bar starts 6pt below that corner: a card at the
    /// top put the revealed pair directly over the controls the user was aiming
    /// at.
    ///
    /// v1.1.10 moved the pair out of this column entirely, which let the card
    /// take the whole column down to the standard `chromeInset` gutter; the
    /// remaining 22pt of the original band is now pane. The pane chrome now
    /// lives on the surfaces themselves — each pane hides from its own minus,
    /// and `detailShowDoors` floats the show buttons over the content surface
    /// only while something is hidden.
    private var detailArea: some View {
        GeometryReader { geometry in
            // Edge to edge (2026-08-28 graduation): the workspace fills its
            // region completely — no floating chrome card, no gutters. The
            // window's own 30pt corner is the only clip; inside it, content
            // is flush.
            let widths = NativeDetailPaneSizing.resolve(
                totalWidth: geometry.size.width,
                preferredPreview: detailPreviewPanelVisible ? settings.filePreviewWidth : nil,
                preferredRail: detailRailPanelVisible ? settings.workspaceRailWidth : nil
            )
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // A degraded workspace archive usually means an empty detail pane,
                    // so this belongs in the layout rather than over it: covering the
                    // empty state's own actions is exactly the wrong trade.
                    // Keep the observer mounted even while it renders no content.
                    // ProjectAccountRecoveryCenter is a nested ObservableObject, so
                    // RootShell cannot reliably decide when its child should exist.
                    WorkspaceRestorationNoticeView(model: model)
                    detailPane(widths)
                }
                if detailRailPanelVisible, let root = model.currentProjectDirectory {
                    // Files live on the right, a full-height flush column like
                    // the left project rail: the same canvas surface, with the
                    // resize divider's hairline as the whole boundary.
                    workspaceRailDivider
                    workspaceRail(root: root)
                        .id(root)
                        .frame(width: widths.rail)
                }
            }
            // See the corridor note in `detailPane`: the trackers must be
            // top-level siblings above every hosted AppKit view, and now that
            // the rail is the trailing-most panel they anchor to the window
            // edge itself.
            .overlay(alignment: .trailing) {
                detailDividerTrackers(widths: widths)
            }
        }
        // The other half of the sidebar divider's corridor. It has to live in
        // this column: a tracking area is clipped to its own split-view
        // subview, so the sidebar's tracker stops dead at the boundary.
        //
        // `detailArea` is also the top-bar layout's content column (see
        // `topBarLayout`), which has no `NSSplitView` at all — there is no
        // sidebar divider there to grab. Gated on `.leftTree` so the strip
        // only exists where a real divider does; without this a `.topBar`
        // window still showed a resize cursor over a phantom corridor and
        // could eat the click meant for whatever sat under it, because
        // `TrackingView.mouseDown` only discovered there was nothing to drive
        // *after* accepting the event. `TrackingView` is now defensive on top
        // of this gate too (its `hitTest` and `cursorUpdate` both bail when
        // `enclosingVerticalDivider()` finds nothing), so a future layout that
        // forgets this `if` still cannot reintroduce the phantom.
        .overlay(alignment: .leading) {
            if settings.navigationLayout == .leftTree {
                DetailEdgeResizeAffordance(hovered: sidebarDividerHoveredBinding)
            }
        }
    }

    /// The show half of the pane chrome: each hidden pane's door floats at the
    /// content surface's top-right, on a material capsule so it reads over
    /// terminal text. The panes' own minus buttons are the hide half, so when
    /// both panes are open this renders nothing and the corner is clean.
    ///
    /// Doors keep the old pair's order (document left of Files, matching how
    /// the panels themselves sit) and their identifiers/labels, so VoiceOver
    /// and automation keep their addresses. Every non-pointer door stays open:
    /// ⌘B / the toggle-document shortcut, the command palette, and one item
    /// each in the footer's overflow menu.
    ///
    /// The Show Document door reuses the toggle path, so with nothing to
    /// restore it opens Files instead of doing nothing — same fallback the
    /// footer's menu item has always had.
    /// The two panel toggles as bare header controls: same 24×22 slot, same
    /// inherited glyph size, same secondary ink as the pane controls beside
    /// them. The grey `.regularMaterial` capsule that used to wrap them — and
    /// the overlay that floated it over the header's own buttons — is gone.
    ///
    /// Both toggles render whenever they can act; only the words flip between
    /// Show and Hide. A door that existed only while its panel was hidden
    /// deleted itself on click and slid the neighbouring control into the
    /// pixel under the cursor — the toolbar-toggle permanence Apple's own
    /// sidebar buttons have is what keeps the slot geometry stable.
    @ViewBuilder
    private var detailShowDoorButtons: some View {
        let doors = DetailShowDoors.resolve(
            railVisible: detailRailPanelVisible,
            previewVisible: detailPreviewPanelVisible,
            hasProjectDirectory: model.currentProjectDirectory != nil
        )
        showDoor(
            symbol: "doc.text",
            label: doors.showDocument ? "Show Document" : "Hide Document",
            shortcut: keymap.shortcut(for: .toggleDocumentPreview)?.display,
            identifier: "detail.toggle-document",
            action: { runCommand(.toggleDocumentPreview) }
        )
        if model.currentProjectDirectory != nil {
            showDoor(
                symbol: "sidebar.trailing",
                label: doors.showFiles ? "Show Files" : "Hide Files",
                shortcut: keymap.shortcut(for: .toggleFiles)?.display,
                identifier: "detail.toggle-files",
                action: { runCommand(.toggleFiles) }
            )
        }
    }

    /// With no pane open there is no header to host the doors, so the empty
    /// workspace carries them itself, at the same trailing metrics a header
    /// would give them.
    private var emptyWorkspaceDoors: some View {
        HStack(spacing: 7) {
            detailShowDoorButtons
        }
        .padding(.top, 5)
        .padding(.trailing, 9)
    }

    private func showDoor(
        symbol: String,
        label: String,
        shortcut: String?,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(.kaisolaSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.kaisolaChrome)
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func toggleFilePreviewColumn() {
        if model.browserCardURL != nil {
            model.browserCardURL = nil
            return
        }
        if !model.toggleFilePreview() { settings.workspaceRailVisible = true }
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
        if model.pinsUnreadable != nil {
            // Pinning stays stuck until the unreadable file moves aside, and
            // this is the only action allowed to give up on that file.
            Button("Reset Pinned Sessions") { model.resetUnreadablePins() }
        }
        if !visible {
            Button("Open in Split") {
                model.revealSurfaceBeside(session.id)
            }
        }
        if visible {
            Button("Hide Terminal") {
                Task { await model.minimizeSurface(session.id) }
            }
        }
        Button("Rename…") { renameTarget = session.id }
        Menu("Move to Project") {
            ForEach(model.projects.filter { $0.id != model.displayProjectID(session) }) { project in
                Button(project.name) {
                    model.moveTerminal(session.id, toProject: project.id)
                }
            }
        }
        if model.sessionAdoptions[session.id] != nil {
            Button("Return to \(model.projects.first(where: { $0.id == session.projectID })?.name ?? "its project")") {
                model.moveTerminal(session.id, toProject: session.projectID)
            }
        }
        let ownership = TerminalOwnershipPresentation(
            isLiveOwner: model.isOwned(session.id),
            hasDurableOwnership: model.canClose(session.id),
            directory: model.directory(for: session.id)
        )
        if let dir = ownership.gitDirectory {
            Button("Git Panel…") { gitRepo = dir }
        }
        // Closing must be available for every state — live, exited, dormant,
        // unavailable. The commit is synchronous (closed-stays-closed §4a);
        // broker cleanup drains behind it.
        if model.isOwned(session.id) || model.canClose(session.id) {
            Button("End Session", role: .destructive) {
                model.commitClose(session.id)
                Task { await model.drainPendingReleases() }
            }
        }
    }

    @ViewBuilder
    private func chatContextMenuContent(_ chat: AcpChatHandle) -> some View {
        Button("Open Beside") { model.revealSurfaceBeside(chat.id) }
        if model.isSurfaceVisible(chat.id) {
            Button("Hide Chat") { Task { await model.minimizeSurface(chat.id) } }
        }
        Button("Rename…") { renameTarget = chat.id }
        if chat.conversation.isRunning {
            Button("Stop Chat") { model.stopChat(chat.id) }
        }
        Button("Close to Recently Closed") { model.closeChat(chat.id) }
        Button("Delete Chat…", role: .destructive) { requestDeleteChat(chat) }
    }

    @ViewBuilder
    private func meshContextMenuContent(_ mesh: MeshSession) -> some View {
        Button("Open Beside") { model.revealSurfaceBeside(mesh.id) }
        if model.isSurfaceVisible(mesh.id) {
            Button("Hide Mesh") { Task { await model.minimizeSurface(mesh.id) } }
        }
        Button("Rename…") { renameTarget = mesh.id }
        if mesh.anyRunning {
            Button("Stop All Columns") { Task { await mesh.stopAllTurns() } }
        }
        Button("Close to Recently Closed") { requestMoveMeshToRecentlyClosed(mesh) }
        Button("Delete Mesh…", role: .destructive) { requestDeleteMesh(mesh) }
    }

    /// "Other Macs" is a *report on other machines*. With none paired it was a
    /// permanent empty state plus a "Updated N seconds ago" line — two rows of
    /// chrome saying nothing, which is exactly what the v4 rail is meant not to
    /// carry. It appears when there is something to report: a remote device, or
    /// an error about a fleet that has actually been seen.
    private var showsRememberedSessionSection: Bool {
        RememberedSessionsSectionVisibility.shouldShow(
            remoteDeviceCount: rememberedSessions.remoteDevices.count,
            errorMessage: rememberedSessions.errorMessage,
            hasEverSeenRemoteDevice: rememberedSessions.hasEverSeenRemoteDevice
        )
    }

    /// A dragged rail width persists and becomes every window's opening
    /// width; a never-dragged install follows the chrome's resting ideal.
    private var resolvedProjectRailIdealWidth: CGFloat {
        NativeWorkspaceChrome.resolvedProjectRailIdealWidth(
            storedWidth: settings.projectRailWidth
        )
    }

    /// Recent folders not already open — the one-click reopen list behind the
    /// ghost row's chevron. Existence is deliberately NOT checked here: this
    /// recomputes on every body evaluation, and a stat against a sleeping
    /// network volume would stall the main thread on renders that have
    /// nothing to do with the sidebar. A dead folder is caught at click time.
    private var addableRecentFolders: [URL] {
        AddableRecentFolders.compute(
            recent: model.recentFolders,
            openProjectPaths: Set(model.projects.compactMap { $0.directory?.standardizedFileURL.path }),
            isDirectory: { _ in true }
        )
    }

    private func openRecentFolder(_ folder: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            ToastCenter.shared.show(
                "\(folder.lastPathComponent) is no longer there.",
                style: .error
            )
            return
        }
        model.openProject(directory: folder)
    }

    /// The rail's only standing invitation: a quiet "+ Add Project" row at the
    /// bottom of the project list. Click opens the folder picker; the chevron
    /// (or a long press) offers recent folders for one-click reopen. Styled to
    /// the quiet-fleet rules — secondary at rest, no wash, 32pt row.
    private var addProjectRow: some View {
        Menu {
            ForEach(addableRecentFolders, id: \.self) { folder in
                Button(folder.lastPathComponent) {
                    openRecentFolder(folder)
                }
                .help(folder.path)
            }
            if !addableRecentFolders.isEmpty { Divider() }
            Button("Choose Folder…") { Self.promptForOpenFolder(model: model) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: QuietRailMetrics.plusText, weight: .semibold))
                Text("Add Project")
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.kaisolaSecondary)
            .padding(.leading, 12)
            .frame(height: QuietRailMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // The sidebar's resize corridor overlays the List's trailing
            // ~10.5pt; a permanent control cannot share its edge with a drag
            // handle (the header "+" learned this — see
            // QuietRailMetrics.plusTrailingInset), so the hit target stops
            // short of the corridor's reach.
            .padding(.trailing, QuietRailMetrics.plusTrailingInset)
        } primaryAction: {
            Self.promptForOpenFolder(model: model)
        }
        // Default menu style, deliberately: `.borderlessButton` opens the
        // menu on any press and never honors the primaryAction split, which
        // would put an extra click on every mouse-driven add. The default
        // style fires primaryAction on click and keeps the indicator as the
        // visible doorway to recent folders.
        .buttonStyle(.plain)
        .help("Add a project folder (⌘O); the chevron holds recent folders")
        .accessibilityLabel("Add Project")
    }

    @ViewBuilder
    private var rememberedSessionSidebarSection: some View {
        Section {
            ForEach(rememberedSessions.remoteDevices) { device in
                DisclosureGroup {
                    ForEach(device.sessions) { session in
                        rememberedSessionRow(session, device: device)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(device.presence == .online ? Color.green : Color.kaisolaTertiary)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.deviceName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text("\(device.sessions.count) remembered \(device.sessions.count == 1 ? "session" : "sessions")")
                                .font(.system(size: 10))
                                .foregroundStyle(.kaisolaSecondary)
                        }
                    }
                }
                .help("Metadata only; live control remains on this Mac until Companion is connected")
            }
            if let error = rememberedSessions.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                    .lineLimit(2)
            }
            if let freshness = rememberedSessions.freshnessTitle {
                Label(freshness, systemImage: rememberedSessions.source == .savedSnapshot
                    ? "clock.arrow.circlepath"
                    : "checkmark.icloud")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.kaisolaTertiary)
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
                    .foregroundStyle(.kaisolaSecondary)
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

    /// The top-bar mode: one 40pt session-tab bar over the detail pane —
    /// compact project switcher leading, the active project's session tabs
    /// packed immediately beside it, the bar's one flexible gap, then the
    /// tight trailing cluster (New Session and the sidebar switch). Project
    /// switching lives in the switcher's menu and saved Quick Actions keep
    /// their context-menu and palette homes. The bar renders by iterating
    /// `MergedTopBarGrammar.slots`, so the arrangement the tests pin is the
    /// arrangement on screen.
    private var topBarLayout: some View {
        let actions = shellActions
        return RootMergedTopBarShell(actions: actions) { actions in
            HStack(spacing: MergedTopBarGrammar.barSpacing) {
                ForEach(MergedTopBarGrammar.slots, id: \.self) { slot in
                    mergedBarSlot(slot, actions: actions)
                }
            }
        } detail: { _ in
            detailArea
        } footer: { _ in
            footer
        }
    }

    @ViewBuilder
    private func mergedBarSlot(
        _ slot: MergedTopBarGrammar.Slot,
        actions: RootShellActionModel
    ) -> some View {
        switch slot {
        case .projectSwitcher:
            TopBarProjectSwitcher(
                projects: model.projects,
                selected: activeProjectBinding,
                contextMenu: actions.projectContextMenu
            )
            .padding(.leading, NativeWorkspaceChrome.topBarTrafficLightClearance)
        case .sessionTabs:
            sessionStrip(actions: actions)
        case .flexibleSpace:
            Spacer(minLength: 0)
        case .trailingControls:
            TopBarTrailingControls(
                activeProject: model.projects.first { $0.id == activeProjectID },
                newSession: actions.beginNewSession,
                useSidebar: actions.useLeftTreeNavigation
            )
            .padding(.trailing, MergedTopBarGrammar.trailingInset)
        }
    }

    /// The one SessionStrip both top-bar presentations mount; the strip
    /// itself switches container (scrolling 36pt band, or the merged bar's
    /// packed tabs) on the same preview the shells switch on.
    private func sessionStrip(actions: RootShellActionModel) -> SessionStrip {
        SessionStrip(
            model: model,
            projectID: activeProjectID,
            draft: activeProjectID.flatMap { newSessionDrafts.draft(for: $0) },
            selectedDraftID: newSessionDrafts.selectedDraftID,
            selectDraft: selectNewSessionDraft,
            selectRealSurface: actions.selectRealSurface,
            cancelDraft: cancelNewSession,
            rename: actions.renameSurface,
            closeChat: actions.closeChat,
            deleteChat: actions.deleteChat,
            closeMesh: actions.closeMesh,
            deleteMesh: actions.deleteMesh,
            deleteRecentlyClosed: actions.deleteRecentlyClosed
        )
    }

    private var activeProjectID: String? {
        model.selectedProjectID
            ?? model.selectedProjectName.flatMap { name in model.projects.first(where: { $0.name == name })?.id }
            ?? model.projects.first?.id
    }

    private var activeProjectBinding: Binding<String?> {
        Binding(get: { activeProjectID }, set: { model.activateProject(id: $0) })
    }

    private var selectedNewSessionDraft: NewSessionDraft? {
        guard let draft = newSessionDrafts.selectedDraft,
              draft.projectID == activeProjectID else { return nil }
        return draft
    }

    private func beginNewSession(in project: AppModel.ProjectGroup) {
        guard project.directory != nil else {
            ToastCenter.shared.show(
                "Locate \(project.name) before starting a session.",
                style: .info
            )
            return
        }
        model.activateProject(id: project.id)
        newSessionDrafts.begin(projectID: project.id)
    }

    private func selectNewSessionDraft(_ id: String) {
        guard let draft = newSessionDrafts.draftsByProject.values.first(where: { $0.id == id }),
              model.projects.contains(where: { $0.id == draft.projectID && $0.directory != nil }) else {
            return
        }
        model.activateProject(id: draft.projectID)
        newSessionDrafts.selectDraft(id)
    }

    private func selectRealSurface() {
        newSessionDrafts.selectRealSurface()
    }

    private func cancelNewSession(_ projectID: String) {
        newSessionDrafts.cancel(projectID: projectID)
    }

    /// The blank project workspace is the same launch surface as the project
    /// plus button, without manufacturing a temporary tab before the user has
    /// chosen anything. The first concrete choice creates that draft and then
    /// travels through the one existing launch path below.
    private func chooseNewSessionFromEmptyWorkspace(
        _ choice: NewSessionChoice,
        project: AppModel.ProjectGroup
    ) {
        let draft = newSessionDrafts.begin(projectID: project.id)
        chooseNewSession(choice, draft: draft)
    }

    private func chooseNewSession(_ choice: NewSessionChoice, draft: NewSessionDraft) {
        guard let project = model.projects.first(where: {
            $0.id == draft.projectID && $0.directory != nil
        }), let directory = project.directory else {
            newSessionDrafts.cancel(projectID: draft.projectID)
            ToastCenter.shared.show("This project folder is no longer available.", style: .info)
            return
        }
        model.activateProject(id: draft.projectID)
        switch choice {
        case .terminal:
            guard let launchID = newSessionDrafts.beginLaunch(projectID: draft.projectID) else {
                return
            }
            Task { @MainActor in
                let result = await model.createTerminalLaunch(inDirectory: directory)
                let accepted = newSessionDrafts.finishLaunch(
                    projectID: draft.projectID,
                    launchID: launchID,
                    succeeded: result.terminalID != nil,
                    failureMessage: result.failureMessage
                )
                if accepted, result.terminalID == nil {
                    ToastCenter.shared.show(
                        NewSessionChooserPresentation.launchFailureMessage(
                            detail: result.failureMessage
                        ),
                        style: .info
                    )
                }
            }
        case let .agentTerminal(agentID):
            guard let agent = AgentRegistry.profile(id: agentID) else {
                ToastCenter.shared.show("That terminal agent is no longer available.", style: .info)
                return
            }
            guard let launchID = newSessionDrafts.beginLaunch(projectID: draft.projectID) else {
                return
            }
            Self.promptForNewAgent(
                agent,
                model: model,
                preferredDirectory: directory,
                cancelled: {
                    newSessionDrafts.cancelLaunch(
                        projectID: draft.projectID,
                        launchID: launchID
                    )
                },
                completed: { result in
                    let accepted = newSessionDrafts.finishLaunch(
                        projectID: draft.projectID,
                        launchID: launchID,
                        succeeded: result.terminalID != nil,
                        failureMessage: result.failureMessage
                    )
                    if accepted, result.terminalID == nil {
                        ToastCenter.shared.show(
                            NewSessionChooserPresentation.launchFailureMessage(
                                detail: result.failureMessage
                            ),
                            style: .info
                        )
                    }
                }
            )
        case let .chat(agentID):
            guard let agent = AgentRegistry.profile(id: agentID),
                  AcpAdapter.forAgent(agentID) != nil else {
                ToastCenter.shared.show("That chat agent is no longer available.", style: .info)
                return
            }
            guard let launchID = newSessionDrafts.beginLaunch(projectID: draft.projectID) else {
                return
            }
            Self.promptForNewChat(
                agent,
                model: model,
                preferredDirectory: directory,
                cancelled: {
                    newSessionDrafts.cancelLaunch(
                        projectID: draft.projectID,
                        launchID: launchID
                    )
                },
                completed: { chatID in
                    let accepted = newSessionDrafts.finishLaunch(
                        projectID: draft.projectID,
                        launchID: launchID,
                        succeeded: chatID != nil
                    )
                    if accepted, chatID == nil {
                        ToastCenter.shared.show(
                            NewSessionChooserPresentation.launchFailureMessage,
                            style: .info
                        )
                    }
                }
            )
        case .mesh:
            newSessionDrafts.complete(projectID: draft.projectID)
            runCommand(.newMesh)
        }
    }

    /// Projects the user explicitly expanded. Absent from this set, a
    /// non-active project stays collapsed — peeking is opt-in.
    @AppStorage("expandedProjects") private var expandedProjectsRaw = ""
    /// Projects the user explicitly collapsed. Retained under its original key
    /// so an install that had collapsed projects before the default flipped
    /// keeps them collapsed rather than springing open.
    @AppStorage("collapsedProjects") private var collapsedProjectsRaw = ""

    private func expansionBinding(_ projectID: String) -> Binding<Bool> {
        Binding(
            get: {
                ProjectExpansionState.isExpanded(
                    projectID: projectID,
                    isActive: activeProjectID == projectID,
                    expanded: ProjectExpansionState.decode(expandedProjectsRaw),
                    collapsed: ProjectExpansionState.decode(collapsedProjectsRaw)
                )
            },
            set: { expanded in
                let next = ProjectExpansionState.toggled(
                    expanded: expanded,
                    projectID: projectID,
                    isActive: activeProjectID == projectID,
                    expanded: ProjectExpansionState.decode(expandedProjectsRaw),
                    collapsed: ProjectExpansionState.decode(collapsedProjectsRaw)
                )
                expandedProjectsRaw = ProjectExpansionState.encode(next.expanded)
                collapsedProjectsRaw = ProjectExpansionState.encode(next.collapsed)
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
        Button("Close Project", role: .destructive) { requestCloseProject(project) }
    }

    /// Closing a project hides its tab but does NOT stop its work (§4d): the
    /// user confirms when live sessions would keep running out of sight
    /// (in-process, so only until the app quits). Attention events still
    /// surface; ⌘⇧T reopens with everything intact.
    private func requestCloseProject(_ project: AppModel.ProjectGroup) {
        let running = model.runningWorkCount(inProject: project.id)
        guard running > 0 else {
            model.closeProject(id: project.id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close \(project.name)?"
        alert.informativeText = running == 1
            ? "1 session stays available until Kaisola quits. Reopen the project with ⌘⇧T to get back to it."
            : "\(running) sessions stay available until Kaisola quits. Reopen the project with ⌘⇧T to get back to them."
        alert.addButton(withTitle: "Close Project")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            model.closeProject(id: project.id)
        }
    }

    /// Session creation is anchored to the project whose menu was clicked — it
    /// never falls back to whichever project happened to be selected before the
    /// click. This is the Electron workflow for running different CLIs in
    /// different folders without reopening a folder picker each time.
    @ViewBuilder
    private func projectLaunchMenu(_ project: AppModel.ProjectGroup) -> some View {
        if project.directory != nil {
            Button {
                model.activateProject(id: project.id)
                selectRealSurface()
                runCommand(.newTerminal)
            } label: {
                Label("New Terminal", systemImage: "terminal")
            }
            ForEach(AgentRegistry.all) { agent in
                Button {
                    model.activateProject(id: project.id)
                    selectRealSurface()
                    runCommand(.newAgent(agent.id))
                } label: {
                    Label("New \(agent.name) Terminal", systemImage: agent.symbol)
                }
            }
            Divider()
            ForEach(AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil }) { agent in
                Button {
                    model.activateProject(id: project.id)
                    selectRealSurface()
                    runCommand(.newChat(agent.id))
                } label: {
                    Label("Chat with \(agent.name)", systemImage: "bubble.left.and.bubble.right")
                }
            }
            Button {
                model.activateProject(id: project.id)
                selectRealSurface()
                runCommand(.newMesh)
            } label: {
                Label("New Mesh", systemImage: "circle.hexagongrid.fill")
            }
        } else {
            Button("Folder Unavailable") {}.disabled(true)
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

    /// The document preview (or the browser card, which shares its width and
    /// its divider) is open.
    private var detailPreviewPanelVisible: Bool {
        model.previewedFileURL != nil || model.browserCardURL != nil
    }

    /// The Files rail is open.
    private var detailRailPanelVisible: Bool {
        settings.workspaceRailVisible && model.currentProjectDirectory != nil
    }

    @ViewBuilder
    private func detailPane(_ widths: NativeDetailPaneSizing.Widths) -> some View {
        // Both detail dividers' pointer trackers live in one overlay on
        // `detailArea`'s outer HStack, not inside the handles they belong to.
        //
        // `FilePreviewView` hosts real AppKit views — a `WKWebView` for
        // rendered Markdown, an `NSTextView` for source — and a hosted
        // AppKit view outranks a SwiftUI sibling for cursor dispatch.
        // `zIndex` reorders SwiftUI's drawing but NOT the backing NSViews,
        // measured: with the tracker inside the handle the document
        // divider's corridor read `arrow` across its whole width at every
        // zIndex, while the identical Files handle (whose neighbour hosts
        // no web view) read `resizeLeftRight`. An overlay attached to the
        // outer HStack is added to the same backing hierarchy AFTER the
        // panels, so those tracking views are true top-level siblings above
        // the hosted content and receive `.cursorUpdate` first.
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
                    restoreSelection: { model.cancelFileNavigation(restoring: $0) },
                    hide: { runCommand(.toggleDocumentPreview) }
                ) {
                    model.closeFilePreview()
                }
                // Keep document/tab state while navigating inside a
                // project, but remount the FSEvents watcher when the file
                // workbench moves to a different project root.
                .id("file-preview-\(model.currentProjectDirectory?.standardizedFileURL.path ?? fileURL.deletingLastPathComponent().path)")
                .frame(width: widths.preview)
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// The Files rail, mounted by `detailArea` OUTSIDE the chrome card so it
    /// runs flush to the window edges the way the left project rail does.
    private func workspaceRail(root: URL) -> some View {
        WorkspaceRailView(root: root, selectedFile: model.previewedFileURL, openFile: { url, pinned in
            model.openFilePreview(url, pinned: pinned)
        }, followsAgentFiles: $followsSelectedAgentFiles, canFollowAgentFiles: canFollowAgentFiles,
        didMoveItem: { source, destination in
            model.reconcileWorkspaceFileMove(from: source, to: destination)
            model.registerWorkspaceMoveUndo(
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
    }

    private var canFollowAgentFiles: Bool {
        model.selectedChatID != nil || model.selectedMeshID != nil
    }

    /// The hoisted corridors, owned by one AppKit overlay.
    ///
    /// The overlay fills the detail stack but returns `nil` from hit testing
    /// outside the two `dividerHitWidth` corridors. That keeps the hosted
    /// document views below it in backing-view order without placing an
    /// invisible pointer surface over the terminal, preview, or Files panel.
    private func detailDividerTrackers(widths: NativeDetailPaneSizing.Widths) -> some View {
        // `trailingPanelInset` is zero now: the chrome card whose trailing
        // gutter it measured is gone, so the preview divider sits directly
        // against the rail divider's lane and the corridors must not carry a
        // phantom 6pt offset.
        let corridors = NativeDetailPaneSizing.corridors(
            widths: widths,
            previewVisible: detailPreviewPanelVisible,
            railVisible: detailRailPanelVisible
        )
        return DetailDividerTrackingView(
            corridors: corridors,
            corridorWidth: NativeDetailPaneSizing.dividerHitWidth,
            hoverChanged: { hoveredDetailDivider = $0 },
            dragBegan: settings.beginPanelResize,
            deltaChanged: { resizeDetailPanel($0, by: $1) },
            dragEnded: settings.endPanelResize,
            doubleClicked: { resetDetailPanel($0) }
        )
        // The corridor is a pointer surface only. Each divider's single AX
        // slider stays on its handle, where the label, the hint, and the
        // adjustable action already are.
        .accessibilityHidden(true)
    }

    /// The one width-write path per detail panel, shared by the hoisted tracker
    /// (drag) and the handle itself (arrow keys, VoiceOver adjustment).
    private func resizeDetailPanel(_ divider: NativeDetailPaneSizing.Divider, by delta: CGFloat) {
        switch divider {
        case .preview:
            settings.filePreviewWidth = NativePreviewSettings.clampedFilePreviewWidth(
                settings.filePreviewWidth - Double(delta)
            )
        case .rail:
            settings.workspaceRailWidth = NativePreviewSettings.clampedWorkspaceRailWidth(
                settings.workspaceRailWidth - Double(delta)
            )
        }
    }

    private func resetDetailPanel(_ divider: NativeDetailPaneSizing.Divider) {
        switch divider {
        case .preview:
            settings.filePreviewWidth = NativePreviewSettings.filePreviewWidthDefault
        case .rail:
            settings.workspaceRailWidth = NativePreviewSettings.workspaceRailWidthDefault
        }
    }

    private var workspaceRailDivider: some View {
        StablePanelResizeHandle(
            label: "Resize Files",
            help: "Drag to resize Files; double-click to reset",
            hovered: hoveredDetailDivider == .rail,
            onBegan: settings.beginPanelResize,
            onDelta: { resizeDetailPanel(.rail, by: $0) },
            onEnded: settings.endPanelResize
        )
        .accessibilityAdjustableAction { direction in
            settings.workspaceRailWidth = NativePreviewSettings.clampedWorkspaceRailWidth(
                settings.workspaceRailWidth + (direction == .increment ? 16 : -16)
            )
        }
    }

    private var filePreviewDivider: some View {
        StablePanelResizeHandle(
            label: "Resize document preview",
            help: "Drag to resize the document; double-click to reset",
            hovered: hoveredDetailDivider == .preview,
            onBegan: settings.beginPanelResize,
            onDelta: { resizeDetailPanel(.preview, by: $0) },
            onEnded: settings.endPanelResize
        )
            .accessibilityAdjustableAction { direction in
                settings.filePreviewWidth = NativePreviewSettings.clampedFilePreviewWidth(
                    settings.filePreviewWidth + (direction == .increment ? 24 : -24)
                )
            }
    }

    private var detailContent: some View {
        ZStack {
            // Keep every real pane mounted while the draft chooser is in
            // front. Live terminals and chats retain their view state, and the
            // pane layout returns exactly as it was when the draft closes.
            unifiedSessionPaneGrid
            if let draft = selectedNewSessionDraft,
               let project = model.projects.first(where: { $0.id == draft.projectID }) {
                // The opaque rect hides the still-mounted panes; the primary
                // wash on top gives the white chooser card a ground to sit on
                // — card and backdrop otherwise both resolve to #FFFFFF in
                // light Aqua, with only a hairline between them.
                Color(nsColor: .windowBackgroundColor)
                    .overlay(Color.primary.opacity(0.05))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                NewSessionChooserView(
                    projectName: project.name,
                    catalog: .live,
                    terminalControlAvailable: model.controlAvailable,
                    isLaunching: newSessionDrafts.isLaunching(projectID: draft.projectID),
                    launchFailureMessage: NewSessionChooserPresentation
                        .retainedLaunchFailureMessage(
                            didFail: newSessionDrafts.didLastLaunchFail(
                                projectID: draft.projectID
                            ),
                            detail: newSessionDrafts.lastLaunchFailureMessage(
                                projectID: draft.projectID
                            )
                        ),
                    choose: { chooseNewSession($0, draft: draft) },
                    cancel: { cancelNewSession(draft.projectID) }
                )
                .id(draft.id)
                .padding(32)
                .accessibilityIdentifier("new-session-chooser")
            }
        }
        .transaction { $0.animation = nil }
    }

    private var footer: some View {
        ConnectionFooter(
            jumpToAttention: { model.jumpToAttentionTarget($0) },
            attentionContext: { model.attentionContext(for: $0) },
            newMesh: { runCommand(.newMesh) },
            newStagedMesh: { runCommand(.newStagedMesh) },
            newIdeaMesh: { runCommand(.newIdeaMesh) },
            filePreviewVisible: detailPreviewPanelVisible,
            toggleFilePreview: { runCommand(.toggleDocumentPreview) },
            // The Files toggle's permanent, pointer-independent door. Its
            // visible controls live on the panes themselves now (a minus on
            // each open pane, `detailShowDoors` while hidden), and a keyboard
            // or VoiceOver user still needs a door that is always drawn —
            // this one costs the footer no width at all.
            filesVisible: settings.workspaceRailVisible,
            toggleFiles: { runCommand(.toggleFiles) },
            // The footer gear TOGGLES the takeover: pressing it with Settings
            // open is "back to app" (Michael's ChatGPT-app reference).
            showSettings: {
                if !showSettings { settingsSectionID = nil }
                applySettingsTakeover(.pressSettingsDoor)
            },
            showUsage: {
                settingsSectionID = "usage"
                applySettingsTakeover(.openSection)
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

    /// New agent session with an explicit execution boundary. Even when a
    /// project is active, the user sees where the process, branch, account, and
    /// host will be before anything launches.
    @MainActor
    static func promptForNewAgent(_ agent: AgentProfile, model: AppModel) {
        promptForNewAgent(
            agent,
            model: model,
            preferredDirectory: nil,
            cancelled: {},
            completed: { _ in }
        )
    }

    /// The draft chooser uses the same explicit Run On and account boundary as
    /// every other agent launch. It only adds completion/cancellation hooks so
    /// the temporary tab survives a cancelled picker or a failed terminal.
    @MainActor
    private static func promptForNewAgent(
        _ agent: AgentProfile,
        model: AppModel,
        preferredDirectory: URL?,
        cancelled: @escaping @MainActor () -> Void,
        completed: @escaping @MainActor (AppModel.TerminalLaunchResult) -> Void
    ) {
        promptForRunOn(
            agent,
            model: model,
            additionalDirectory: preferredDirectory,
            cancelled: cancelled
        ) { directory, profile in
            Task { @MainActor in
                let result = await model.createAgentSessionLaunch(
                    agent,
                    inDirectory: directory,
                    accountProfile: profile
                )
                completed(result)
            }
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

    /// ACP chat launch shares the same location/account authority as a terminal
    /// agent launch; the transport kind must not change where it runs.
    @MainActor
    static func promptForNewChat(_ agent: AgentProfile, model: AppModel) {
        promptForNewChat(
            agent,
            model: model,
            preferredDirectory: nil,
            cancelled: {},
            completed: { _ in }
        )
    }

    /// New-chat setup is reversible. The temporary New Session tab remains the
    /// visible owner while location and subscription are chosen, and is
    /// consumed only after AppModel confirms a real chat was appended. The
    /// chat starts on the default run profile; policies are edited in
    /// Settings, not re-decided at every launch.
    @MainActor
    private static func promptForNewChat(
        _ agent: AgentProfile,
        model: AppModel,
        preferredDirectory: URL?,
        cancelled: @escaping @MainActor () -> Void,
        completed: @escaping @MainActor (String?) -> Void
    ) {
        guard AcpAdapter.forAgent(agent.id) != nil else {
            completed(nil)
            return
        }
        promptForRunOn(
            agent,
            model: model,
            additionalDirectory: preferredDirectory,
            isChat: true,
            cancelled: cancelled
        ) { directory, profile in
            completed(model.openChat(
                agent,
                inDirectory: directory,
                accountProfile: profile
            ))
        }
    }

    private typealias RunOnLaunch = @MainActor (
        URL,
        UsageAccountProfile?
    ) -> Void

    @MainActor
    private static func promptForRunOn(
        _ agent: AgentProfile,
        model: AppModel,
        additionalDirectory: URL? = nil,
        isChat: Bool = false,
        restoredSelection: RunOnPickerSelection? = nil,
        cancelled: @escaping @MainActor () -> Void = {},
        then launch: @escaping RunOnLaunch
    ) {
        let preferredPath = additionalDirectory?.standardizedFileURL.path
            ?? model.currentProjectDirectory?.standardizedFileURL.path
        var projects = model.projects.compactMap { project -> RunOnTargetBuilder.Project? in
            guard let directory = project.directory?.standardizedFileURL else { return nil }
            return .init(name: project.name, path: directory.path)
        }
        if let additionalDirectory {
            let path = additionalDirectory.standardizedFileURL.path
            projects.removeAll { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }
            projects.insert(.init(name: additionalDirectory.lastPathComponent, path: path), at: 0)
        } else if let preferredPath,
                  let preferredIndex = projects.firstIndex(where: { $0.path == preferredPath }),
                  preferredIndex != 0 {
            projects.insert(projects.remove(at: preferredIndex), at: 0)
        }
        let worktrees = model.meshes.flatMap { mesh in
            mesh.columns.compactMap { column -> RunOnTargetBuilder.Worktree? in
                guard let path = column.worktreePath, let branch = column.branch else { return nil }
                return .init(
                    name: "\(mesh.title) — \(column.agent.name)",
                    path: path,
                    branch: branch
                )
            }
        }
        let recentPaths = model.recentFolders
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let visualFixture = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
            && ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "account-picker"
        if visualFixture, projects.isEmpty {
            projects = [.init(name: "Kaisola", path: "/Users/example/Developer/Kaisola")]
        }
        let projectSnapshot = projects
        let worktreeSnapshot = worktrees
        let recentSnapshot = recentPaths
        let fixturePaths = visualFixture ? Set(projectSnapshot.map(\.path)) : []

        Task {
            let targets = await Task.detached(priority: .userInitiated) {
                [projectSnapshot, worktreeSnapshot, recentSnapshot, host, fixturePaths] in
                RunOnTargetBuilder.build(
                    projects: projectSnapshot,
                    recentPaths: recentSnapshot,
                    worktrees: worktreeSnapshot,
                    host: host,
                    isDirectory: { path in
                        if fixturePaths.contains(path) { return true }
                        var isDirectory: ObjCBool = false
                        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                            && isDirectory.boolValue
                    },
                    branch: { path in
                        if fixturePaths.contains(path) { return "main" }
                        guard let status = try? GitService(
                            repoRoot: URL(fileURLWithPath: path, isDirectory: true)
                        ).status() else { return nil }
                        return status.branch
                    }
                )
            }.value
            presentRunOnPicker(
                agent,
                model: model,
                targets: targets,
                preferredPath: preferredPath,
                isChat: isChat,
                restoredSelection: restoredSelection,
                cancelled: cancelled,
                launch: launch
            )
        }
    }

    @MainActor
    private static func presentRunOnPicker(
        _ agent: AgentProfile,
        model: AppModel,
        targets: [RunOnTarget],
        preferredPath: String?,
        isChat: Bool,
        restoredSelection: RunOnPickerSelection?,
        cancelled: @escaping @MainActor () -> Void,
        launch: @escaping RunOnLaunch
    ) {
        let selectedTarget = targets.first { $0.path == preferredPath }
        let provider = SessionAccountBinding.provider(forAgentID: agent.id)
        var profiles = provider.map { provider in
            UsageAccountStore().profiles().filter { $0.provider == provider }
        } ?? []
        let visualFixture = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
            && ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "account-picker"
        if visualFixture, let provider {
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
        profiles.sort {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }

        // The router suggests; the popup decides. Fixtures keep their own
        // deterministic preselection instead of routing over invented data.
        let routingSettings = NativePreviewSettings.shared
        let routedVerdict: AccountRouter.Verdict? = visualFixture ? nil : provider.flatMap {
            AccountRouter.route(
                provider: $0,
                profiles: profiles,
                readings: UsageCenter.shared.planUsage,
                policy: routingSettings.accountRoutingPolicy,
                lastUsedProfileID: routingSettings.recallAccountSelection(agentID: agent.id)
            )
        }

        // Fixtures show a deterministic design surface: invented captions
        // instead of routing over invented accounts.
        let usageCaptions: [String: String] = visualFixture
            ? [
                "visual-work": "38% used · 5-hour limit",
                "visual-research": "12% used · Weekly limit",
            ]
            : RunOnPickerViewModel.usageCaptions(
                profiles: profiles,
                readings: UsageCenter.shared.planUsage
            )
        let viewModel = RunOnPickerViewModel(
            picker: RunOnPickerModel(
                targets: targets,
                selectedScope: selectedTarget?.scope,
                selectedTargetID: selectedTarget?.id
            ),
            profiles: profiles,
            provider: provider,
            restoredSelection: restoredSelection,
            preferNamedAccount: visualFixture,
            routedVerdict: routedVerdict,
            usageCaptions: usageCaptions,
            removeRecent: { path in model.removeRecentFolder(path) }
        )

        let finish: @MainActor (RunOnPickerOutcome) -> Void = { outcome in
            switch outcome {
            case .chooseFolder:
                chooseDirectory(
                    prompt: "Run \(agent.name) Here",
                    cancelled: cancelled
                ) { directory in
                    promptForRunOn(
                        agent,
                        model: model,
                        additionalDirectory: directory,
                        isChat: isChat,
                        restoredSelection: viewModel.selection,
                        cancelled: cancelled,
                        then: launch
                    )
                }
            case .cancel:
                cancelled()
            case .start:
                guard let target = viewModel.selectedTarget, target.canStart else {
                    cancelled()
                    return
                }
                // What actually launched is what sticky remembers — including
                // an explicit Project default, which is a choice, not an
                // absence.
                if provider != nil, !visualFixture {
                    routingSettings.rememberAccountSelection(
                        agentID: agent.id,
                        profileID: viewModel.selectedProfile?.id
                    )
                }
                launch(
                    URL(fileURLWithPath: target.path, isDirectory: true),
                    viewModel.selectedProfile
                )
            }
        }

        // A plain hosted sheet instead of NSAlert: the picker owns its whole
        // hierarchy, so it can speak the Start a Session chooser's design
        // language instead of an alert accessory's.
        var complete: (@MainActor (RunOnPickerOutcome) -> Void) = { _ in }
        let hosting = NSHostingController(rootView: RunOnPickerView(
            title: isChat ? "Chat with \(agent.name)" : "Start \(agent.name)",
            subtitle: provider == nil
                ? "Choose where this \(isChat ? "chat" : "agent") runs."
                : "Pick the subscription and choose where this \(isChat ? "chat" : "agent") runs.",
            startTitle: isChat ? "Start Chat" : "Start",
            viewModel: viewModel,
            complete: { outcome in complete(outcome) }
        ))
        let sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.isReleasedWhenClosed = false
        sheet.setContentSize(hosting.view.fittingSize)

        // Clearing the handler box on completion breaks the cycle
        // sheet → hosting → view → box → handler → sheet, so a dismissed
        // picker's window is actually released.
        if let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            complete = { outcome in
                complete = { _ in }
                window.endSheet(sheet)
                finish(outcome)
            }
            window.beginSheet(sheet)
        } else {
            complete = { outcome in
                complete = { _ in }
                NSApp.stopModal()
                sheet.orderOut(nil)
                finish(outcome)
            }
            sheet.center()
            NSApp.runModal(for: sheet)
        }
    }

    /// Choose only the provider account for an already-restored chat. Its
    /// execution location is fixed by the existing session, so presenting the
    /// Run on picker here would incorrectly imply that switching credentials
    /// can also move the continuation to another project or worktree.
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
        profiles.sort {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
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

        let alert = NSAlert()
        alert.messageText = "Choose \(agent.name) account"
        alert.informativeText = "This account stays locked to the restored session and its continuations. Credentials remain in the provider's own config directory."
        alert.alertStyle = .informational
        alert.accessoryView = picker
        alert.addButton(withTitle: "Switch")
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
        cancelled: @escaping @MainActor () -> Void = {},
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
            Task { @MainActor in
                guard response == .OK, let directory = panel.urls.first else {
                    cancelled()
                    return
                }
                handle(directory)
            }
        }
    }

    /// The fresh/offline empty state: instead of a dead end, offer the first
    /// actions (start a shell, open a chat, open a folder) right where the user
    /// is looking.
    ///
    /// The card carries its own material because the canvas underneath it does
    /// not guarantee legibility any more: an empty canvas is exactly when the
    /// glass drops to the clear still (see `WorkspaceBackdropView.idle`), so
    /// this text is the one thing that must bring its own surface.
    @ViewBuilder
    private var emptyWorkspaceState: some View {
        if let project = model.projects.first(where: {
            $0.id == activeProjectID && $0.directory != nil
        }) {
            NewSessionChooserView(
                projectName: project.name,
                catalog: .live,
                terminalControlAvailable: model.controlAvailable,
                isLaunching: false,
                launchFailureMessage: nil,
                showsCancel: false,
                choose: { chooseNewSessionFromEmptyWorkspace($0, project: project) },
                cancel: {}
            )
            .padding(32)
            .accessibilityIdentifier("empty-workspace-session-chooser")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyWorkspaceContent
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(
                        cornerRadius: KaisolaVisualSystem.chromeRadius,
                        style: .continuous
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var emptyWorkspaceContent: some View {
        let chatAgent = AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil }
        ContentUnavailableView {
            Label("Nothing running yet", systemImage: "sparkles")
        } description: {
            Text(model.controlAvailable
                ? "Start a terminal, agent, chat, or Mesh run for this project."
                : "Chats and Mesh are ready. \(NewSessionChooserPresentation.terminalUnavailableReason)")
        } actions: {
            HStack(spacing: 10) {
                Button {
                    runCommand(.newTerminal)
                } label: {
                    Label("New Terminal", systemImage: "terminal")
                }
                .disabled(!model.controlAvailable)
                .help(model.controlAvailable ? "Open a shell in the active project" : NewSessionChooserPresentation.terminalUnavailableReason)
                if let chatAgent {
                    Button {
                        runCommand(.newChat(chatAgent.id))
                    } label: {
                        Label("Chat with \(chatAgent.name)", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                Button {
                    runCommand(.openProject)
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func missingSessionRecoveryState(
        _ recovery: AppModel.MissingSessionRecovery
    ) -> some View {
        ContentUnavailableView {
            Label("Session unavailable", systemImage: "rectangle.slash")
        } description: {
            Text(recovery.message)
        } actions: {
            HStack(spacing: 10) {
                Button("Try Again") {
                    Task { await model.retryMissingSession() }
                }
                Button("Back to Main Window") {
                    model.dismissMissingSessionRecovery()
                }
            }
            .buttonStyle(.bordered)
        }
        .accessibilityIdentifier("kaisola.missing-session-recovery")
    }

    // MARK: - Unified movable session dock

    private var unifiedSessionPaneGrid: some View {
        let layout = model.paneLayout(for: activeProjectID)
        return Group {
            if let recovery = model.missingSessionRecovery {
                missingSessionRecoveryState(recovery)
            } else if let maximized = model.maximizedPaneID, layout.contains(maximized) {
                unifiedSessionCard(
                    maximized,
                    clearsWindowControls: true,
                    isSolo: true,
                    hostsDetailDoors: true
                )
            } else if layout.isEmpty {
                // The draft overlay paints its own chooser over this grid;
                // mounting the empty state's chooser underneath it doubled
                // the AX tree and left two `@FocusState` publishers fighting
                // over "Start a session".
                if selectedNewSessionDraft == nil {
                    emptyWorkspaceState
                        .overlay(alignment: .topTrailing) { emptyWorkspaceDoors }
                }
            } else {
                GeometryReader { geometry in
                    let dividerSpace = CGFloat(max(0, layout.columns.count - 1)) * SessionPaneDividerSizing.layoutExtent
                    let available = max(1, geometry.size.width - dividerSpace)
                    let totalWeight = max(0.01, layout.columns.reduce(0) { $0 + $1.weight })
                    let isSolo = layout.sessionIDs.count == 1
                    HStack(spacing: 0) {
                        ForEach(Array(layout.columns.enumerated()), id: \.element.id) { index, column in
                            unifiedSessionColumn(
                                column,
                                projectID: activeProjectID,
                                clearsWindowControls: index == 0,
                                isSolo: isSolo,
                                hostsDetailDoors: index == layout.columns.count - 1
                            )
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
        projectID: String?,
        clearsWindowControls: Bool,
        isSolo: Bool = false,
        hostsDetailDoors: Bool = false
    ) -> some View {
        GeometryReader { geometry in
            let dividerSpace = CGFloat(max(0, column.sessionIDs.count - 1)) * SessionPaneDividerSizing.layoutExtent
            let available = max(1, geometry.size.height - dividerSpace)
            let totalWeight = max(0.01, column.rowWeights.reduce(0, +))
            VStack(spacing: 0) {
                ForEach(Array(column.sessionIDs.enumerated()), id: \.element) { index, id in
                    unifiedSessionCard(
                        id,
                        clearsWindowControls: clearsWindowControls && index == 0,
                        isSolo: isSolo,
                        hostsDetailDoors: hostsDetailDoors && index == 0
                    )
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

    private func unifiedSessionCard(
        _ id: String,
        clearsWindowControls: Bool = false,
        isSolo: Bool = false,
        hostsDetailDoors: Bool = false
    ) -> some View {
        GeometryReader { geometry in
            let terminalChrome = terminalPaneChrome(for: id)
            let marksFocus = model.paneLayout(for: activeProjectID)
                .marksFocus(
                    id,
                    focusedID: model.focusedPaneID,
                    maximizedID: model.maximizedPaneID
                )
            VStack(spacing: 0) {
                unifiedSessionHeader(
                    id,
                    paneWidth: geometry.size.width,
                    clearsWindowControls: clearsWindowControls,
                    hostsDetailDoors: hostsDetailDoors
                )
                unifiedSessionContent(id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(terminalChrome.map { Color(nsColor: $0.background) }
                ?? Color(nsColor: .textBackgroundColor))
            // Edge to edge (2026-08-28 graduation, "the chats/session tabs
            // can take up the whole workspace, no need for them to have
            // rounded corners"): panes fill their cells completely — no
            // rounded pane-card silhouette, no gutters. The window's 30pt
            // corner is the only curve. In a grid the square hairline ring
            // still separates siblings, and focus keeps its accent edge; a
            // solo pane IS the region and draws neither.
            .clipped()
            .overlay {
                if !isSolo {
                    Rectangle()
                        .strokeBorder(
                            marksFocus
                                ? Color.accentColor.opacity(0.30)
                                : terminalChrome.map {
                                    Color(nsColor: $0.foreground).opacity($0.ruleOpacity)
                                } ?? Color(nsColor: .separatorColor).opacity(0.55),
                            lineWidth: marksFocus
                                ? KaisolaVisualSystem.focusStroke
                                : KaisolaVisualSystem.hairline
                        )
                }
            }
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

    private func unifiedSessionHeader(
        _ id: String,
        paneWidth: CGFloat,
        clearsWindowControls: Bool,
        hostsDetailDoors: Bool = false
    ) -> some View {
        let terminalChrome = terminalPaneChrome(for: id)
        return HStack(spacing: 7) {
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
                        if let chat = model.chats.first(where: { $0.id == id }),
                           let status = chat.conversation.liveThinkingStatus {
                            HStack(spacing: 4) {
                                if reduceMotion {
                                    Image(systemName: "hourglass")
                                        .font(.system(size: 8, weight: .bold))
                                } else {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .scaleEffect(0.5)
                                }
                                Text(status.word)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(KaisolaStatusTone.working.foregroundColor)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(status.spoken)
                        } else if reduceMotion {
                            Image(systemName: "hourglass")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(KaisolaStatusTone.working.foregroundColor)
                                .accessibilityLabel(surfaceStatusLabel(id))
                        } else {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.55)
                                .accessibilityLabel(surfaceStatusLabel(id))
                        }
                    } else {
                        if let terminal = terminalHeaderPresentation(id) {
                            Image(systemName: terminal.systemImage)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(terminalHeaderStatusColor(terminal))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(terminal.accessibilityLabel)
                        } else {
                            Image(systemName: surfaceLive(id) ? "checkmark.circle.fill" : "circle.slash")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(
                                    surfaceLive(id)
                                        ? KaisolaStatusTone.done.foregroundColor
                                        : Color.kaisolaSecondary
                                )
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(surfaceStatusLabel(id))
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(surfaceAccessibilityLabel(id))
            .help("Focus \(surfaceTitle(id))")
            // Outside the focus button on purpose: the chip is its own control,
            // and the higher priority means it takes its width before the
            // button's label does. A pane title that is usually the project
            // name again truncates first; who holds control does not.
            if let source = companionControllerChipSource(for: id) {
                CompanionControllerChipView(source: source, paneWidth: paneWidth)
                    .layoutPriority(1)
            }
            // ONE tight trailing cluster, built by iterating the pinned
            // grammar so the declutter the tests hold is the render on
            // screen. 2026-08-28: the maximize arrow and the account button
            // are gone from the header — maximize lives in the pane's
            // context menu, account-and-model switching inside the ellipsis.
            HStack(spacing: UnifiedSessionHeaderGrammar.clusterSpacing) {
                ForEach(
                    UnifiedSessionHeaderGrammar.trailingControls(
                        isChat: model.chats.contains { $0.id == id },
                        isMesh: model.meshes.contains { $0.id == id },
                        isTerminal: model.sessions.contains { $0.id == id },
                        hostsDetailDoors: hostsDetailDoors
                    ),
                    id: \.self
                ) { control in
                    headerControl(control, paneID: id)
                }
            }
        }
        .padding(
            .leading,
            UnifiedSessionHeaderLayout.leadingInset(
                navigationLayout: settings.navigationLayout,
                columnVisibility: leftTreeColumnVisibility,
                isWindowLeadingPane: clearsWindowControls
            )
        )
        .padding(.trailing, 9)
        .frame(height: 32)
        .background {
            if let terminalChrome {
                ZStack {
                    Color(nsColor: terminalChrome.background)
                    Color(nsColor: terminalChrome.foreground)
                        .opacity(terminalChrome.headerTintOpacity)
                }
            } else {
                // The one bar voice — white-led, not the 62% control-color
                // wash that read as grey. Terminals keep their theme-derived
                // chrome (pinned by its own contrast test).
                Color.clear.kaisolaBarSurface()
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(terminalChrome.map {
                    Color(nsColor: $0.foreground).opacity($0.ruleOpacity)
                } ?? Color(nsColor: .separatorColor).opacity(0.38))
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: id as NSString)
        }
        .contextMenu {
            Button("Rename…") { renameTarget = id }
            if let record = model.sessions.first(where: { $0.id == id }) {
                Button("Open Transcript") {
                    openTerminalTranscript(id)
                }
                .disabled(model.terminalTranscriptContext(for: id) == nil)
                // The adoption overlay: show this terminal in another open
                // project. The broker keeps addressing its real project — see
                // `AppModel.moveTerminal`.
                Menu("Move to Project") {
                    ForEach(model.projects.filter { $0.id != model.displayProjectID(record) }) { project in
                        Button(project.name) {
                            model.moveTerminal(id, toProject: project.id)
                        }
                    }
                }
                if model.sessionAdoptions[id] != nil {
                    Button("Return to \(model.projects.first(where: { $0.id == record.projectID })?.name ?? "its project")") {
                        model.moveTerminal(id, toProject: record.projectID)
                    }
                }
            }
            // The removed header arrow's action, kept one right-click away
            // (`UnifiedSessionHeaderGrammar.contextActions` pins it here).
            Button(model.maximizedPaneID == id ? "Restore Pane" : "Maximize Pane") {
                model.toggleMaximizeSurface(id)
            }
            Button("Hide Pane") { Task { await model.minimizeSurface(id) } }
        }
    }

    /// One trailing-cluster control, addressed by the grammar case the tests
    /// pin. Every control keeps the shared 24×22 slot and the chrome style's
    /// eased hover/press answer.
    @ViewBuilder
    private func headerControl(
        _ control: UnifiedSessionHeaderGrammar.Control,
        paneID id: String
    ) -> some View {
        switch control {
        case .meshQueue:
            if let mesh = model.meshes.first(where: { $0.id == id }) {
                MeshStagedPromptQueueButton(mesh: mesh)
            }
        case .meshConfiguration:
            if let mesh = model.meshes.first(where: { $0.id == id }) {
                MeshConfigurationMenu(mesh: mesh)
            }
        case .chatOverflow:
            // The chat's whole session-control set — account and model (the
            // removed header button's actions), zoom, checkpoints,
            // accounting, export — as one overflow in the pane's only bar.
            if let chat = model.chats.first(where: { $0.id == id }) {
                AcpChatOverflowMenu(conversation: chat.conversation) {
                    if SessionAccountBinding.declaredProvider(forAgentID: chat.agentID) != nil {
                        chatAccountMenuContent(chat)
                        Divider()
                    }
                }
                .foregroundStyle(.kaisolaSecondary)
            }
        case .terminalTranscript:
            Button {
                openTerminalTranscript(id)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.kaisolaChrome)
            .foregroundStyle(.kaisolaSecondary)
            .disabled(model.terminalTranscriptContext(for: id) == nil)
            .help("Open the full retained terminal transcript")
        case .terminalPopOut:
            popOutTerminalButton(id)
        case .hide:
            Button { Task { await model.minimizeSurface(id) } } label: {
                Image(systemName: "minus.circle")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.kaisolaChrome)
            .foregroundStyle(.kaisolaSecondary)
            .help("Hide this session; keep it running")
        case .detailDoors:
            detailShowDoorButtons
        }
    }

    private func terminalPaneChrome(for id: String) -> TerminalTheme.PaneChrome? {
        guard model.sessions.contains(where: { $0.id == id }) else { return nil }
        return TerminalTheme.paneChrome(
            light: colorScheme == .light,
            themeID: settings.terminalThemeID
        )
    }

    /// The chat's subscription account and model, visible and changeable from
    /// inside the chat — including mid-conversation. Switching accounts
    /// restarts the provider session under the new credentials; the
    /// transcript, draft, and queued prompts stay (see
    /// `AppModel.switchChatAccount`). 2026-08-28: no longer its own header
    /// button — these sections open the ellipsis menu
    /// (`AcpChatOverflowMenu`), the pane's one overflow.
    @ViewBuilder
    private func chatAccountMenuContent(_ chat: AcpChatHandle) -> some View {
        let provider = SessionAccountBinding.provider(forAgentID: chat.agentID)
        let currentLabel = chat.accountBinding?.label ?? "Project/default"
        Section("Account · \(currentLabel)") {
            accountMenuRow(
                title: "Project/default",
                isCurrent: SessionAccountBinding.menuRowIsCurrent(
                    binding: chat.accountBinding, profileID: nil
                )
            ) {
                Task { await model.switchChatAccount(chat.id, to: nil) }
            }
            ForEach(
                UsageAccountStore().profiles()
                    .filter { $0.provider == provider }
                    .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            ) { profile in
                accountMenuRow(
                    title: profile.label,
                    isCurrent: SessionAccountBinding.menuRowIsCurrent(
                        binding: chat.accountBinding, profileID: profile.id
                    )
                ) {
                    Task { await model.switchChatAccount(chat.id, to: profile) }
                }
            }
        }
        Section("Model · \(chat.modelOverride ?? "Default")") {
            accountMenuRow(title: "App default", isCurrent: chat.modelOverride == nil) {
                Task { await model.switchChatModel(chat.id, to: nil) }
            }
            ForEach(SessionModelOverride.quickChoices(forAgentID: chat.agentID), id: \.id) { choice in
                accountMenuRow(title: choice.title, isCurrent: chat.modelOverride == choice.id) {
                    Task { await model.switchChatModel(chat.id, to: choice.id) }
                }
            }
            Button("Custom Model…") {
                customModelText = chat.modelOverride ?? ""
                customModelTarget = chat.id
            }
        }
    }

    private func signInToRestoredChatAccount(_ chat: AcpChatHandle) {
        guard let profile = model.accountSignInProfile(for: chat.id) else {
            settingsSectionID = "accounts"
            applySettingsTakeover(.openSection)
            ToastCenter.shared.show(
                "Open Accounts to add or repair this provider account.",
                style: .info
            )
            return
        }
        signingInChatID = chat.id
        signingInChatAccount = profile
    }

    private func chooseRestoredChatAccount(_ chat: AcpChatHandle) {
        guard let agent = AgentRegistry.profile(id: chat.agentID) else { return }
        Self.chooseSessionAccount(for: agent) { profile in
            Task { await model.switchChatAccount(chat.id, to: profile) }
        }
    }

    @ViewBuilder
    private func accountMenuRow(
        title: String,
        isCurrent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func companionControllerChipSource(
        for terminalID: String
    ) -> CompanionControllerChipSource? {
        guard let terminal = model.sessions.first(where: { $0.id == terminalID }) else { return nil }
        if let source = companionHost.controllerChipSource(
            projectID: terminal.projectID,
            terminalID: terminal.id
        ) {
            return source
        }
        // Deterministic visual fixtures exercise the chip without manufacturing
        // a paired-device roster or network lease. Gated on the fixture flag:
        // a production pane must never invent a controller name during the few
        // milliseconds between a lease being fenced and its status publishing.
        guard ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              model.companionControlledTerminalIDs.contains(terminalID) else { return nil }
        return CompanionControllerChipSource(
            deviceName: "Michael's iPhone",
            // Far enough out that a slow capture still photographs a live
            // lease rather than the chip decaying to amber mid-run.
            expiresAt: CompanionControllerChipSource.milliseconds(Date()) + 3_600_000
        )
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
            AcpChatView(
                conversation: chat.conversation,
                accountAccess: chat.accountAccess,
                presentation: .embedded,
                focusRequestGeneration: keyboardFocusGeneration(for: id),
                onKeyboardFocus: { model.focusSurfaceFromKeyboard(id) },
                onSignIn: { signInToRestoredChatAccount(chat) },
                onChooseAccount: { chooseRestoredChatAccount(chat) },
                onPreserveTranscript: {
                    Task { await model.preserveBlockedChat(chat.id) }
                }
            )
                .id(chat.id)
        } else if let mesh = model.meshes.first(where: { $0.id == id }) {
            MeshView(
                mesh: mesh,
                presentation: .embedded,
                focusRequestGeneration: keyboardFocusGeneration(for: id),
                onKeyboardFocus: { model.focusSurfaceFromKeyboard(id) }
            )
                .id(mesh.id)
        } else {
            let presentation = missingTerminalPanePresentation(id)
            VStack(spacing: 12) {
                if presentation.detail.isEmpty {
                    ContentUnavailableView(
                        presentation.contentTitle,
                        systemImage: presentation.symbol
                    )
                } else {
                    ContentUnavailableView(
                        presentation.contentTitle,
                        systemImage: presentation.symbol,
                        description: Text(presentation.detail)
                    )
                }
                if presentation.showsClose {
                    Button("Close") {
                        model.commitClose(id)
                        Task { await model.drainPendingReleases() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    /// A resurrected terminal that was running an agent CLI before the
    /// restart: one click resumes it, one click dismisses. Never auto-run —
    /// usage cost and account binding are the user's call (2026-08-06 spec §3).
    private func agentResumeChip(_ id: String, agentID: String) -> some View {
        let agent = AgentRegistry.all.first { $0.id == agentID }
        let command = agent?.resumeCommand ?? "resume"
        return HStack(spacing: 8) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("Resume \(agent?.name ?? agentID)")
                .fontWeight(.semibold)
            Text(command)
                .font(.caption.monospaced())
                .foregroundStyle(.kaisolaSecondary)
            Button {
                Task { await model.runPendingAgentResume(for: id) }
            } label: {
                Text("Run").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                model.dismissPendingAgentResume(for: id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss resume suggestion")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: KaisolaVisualSystem.hairline))
        .padding(.top, 10)
        .help("This terminal was running \(agent?.name ?? agentID) before the restart. Run resumes the conversation; dismiss keeps the plain shell.")
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
            let authority = TerminalSurfaceAuthority(
                isOwned: owned,
                hasDurableOwnership: model.canClose(id)
            )
            ZStack(alignment: .top) {
                TerminalSurfaceFeedView(feed: feed) { liveDocument in
                    NativeTerminalSurface(
                        output: "",
                        streamEpoch: liveDocument.cursor?.streamEpoch,
                        endOffset: liveDocument.cursor?.offset,
                        scrollback: liveDocument.scrollback,
                        surfaceDelta: liveDocument.surfaceDelta,
                        workingDirectory: model.directory(for: id),
                        authority: authority,
                        fontSize: settings.terminalFontSize,
                        fontFamily: settings.terminalFontFamily,
                        fontWeight: settings.terminalFontWeight,
                        lineSpacing: settings.terminalLineSpacing,
                        scrollbackLines: settings.terminalScrollbackLines,
                        allowsClipboardWrite: settings.terminalClipboardWriteAllowed,
                        themeID: settings.terminalThemeID,
                        lightSurface: colorScheme == .light,
                        sessionID: id,
                        agentLaunchCommand: model.agentProfile(for: id)?.launchCommand,
                        onInput: owned ? { data in model.sendInput(data, to: id) } : nil,
                        onResize: owned ? { columns, rows in model.resizeTerminal(id, columns: columns, rows: rows) } : nil,
                        onTitleChange: owned ? { title in model.applyAutoTitle(title, to: id) } : nil,
                        onBell: { handleTerminalBell(id) },
                        onHistoryBoundary: { openTerminalTranscript(id, fromLiveBoundary: true) },
                        onKeyboardFocus: { model.focusSurfaceFromKeyboard(id) }
                    )
                }
                // Local ownership can be temporarily unavailable. Keep the
                // exact parsed view and revoke its input capability in place;
                // only a genuine observer/controller class change may remount.
                .id("unified-\(id)-\(authority.controllerCapable)")
                .onAppear { fulfillTerminalKeyboardFocusRequest(for: id) }
                .onChange(of: model.keyboardFocusRequest) { _, _ in
                    fulfillTerminalKeyboardFocusRequest(for: id)
                }

                // Never alongside the "Session ended" banner: both are
                // top-center capsules in this ZStack, and a resurrected shell
                // that exits immediately would otherwise stack them.
                if let agentID = model.pendingAgentResume[id],
                   unifiedTerminalDocument(id)?.exited != true {
                    agentResumeChip(id, agentID: agentID)
                }
                terminalLifecycleOverlay(id)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading terminal")
        }
    }

    @ViewBuilder
    private func terminalLifecycleOverlay(_ id: String) -> some View {
        if let terminal = model.sessions.first(where: { $0.id == id }) {
            if terminal.exited {
                HStack(spacing: 8) {
                    Label("Session ended", systemImage: "stop.circle.fill")
                    if model.canClose(id) {
                        Button {
                            Task { await model.reopenEndedSession(id) }
                        } label: {
                            if model.reopeningTerminalIDs.contains(id) {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini)
                                    Text("Reopening…")
                                }
                            } else {
                                Text("Reopen")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.canReopenEndedSession(id))
                        .accessibilityHint("Starts a new terminal in this pane with the same agent and folder")
                    }
                    Button("Open Transcript") { openTerminalTranscript(id) }
                        .buttonStyle(.borderless)
                        .disabled(model.terminalTranscriptContext(for: id) == nil)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.kaisolaSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: KaisolaVisualSystem.hairline)
                }
                .padding(10)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Session ended")
                .accessibilityHint("Open the retained terminal transcript to review its output")
            } else if model.isTerminalInputDegraded(id) {
                let recovering = model.isTerminalInputRecovering(id)
                HStack(spacing: 8) {
                    Label("Input paused", systemImage: "exclamationmark.triangle.fill")
                    Button(recovering ? "Checking…" : "Resume input") {
                        Task { await model.recoverTerminalInput(id) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(recovering)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.kaisolaSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: KaisolaVisualSystem.hairline)
                }
                .padding(10)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Input paused for \(surfaceTitle(id))")
                .accessibilityHint("The last write could not be confirmed. Other terminals remain connected. Resume input revalidates only this terminal.")
            } else if let progress = model.terminalPasteProgress(for: id) {
                HStack(spacing: 8) {
                    ProgressView(
                        value: Double(progress.sentBytes),
                        total: Double(progress.totalBytes)
                    )
                    .controlSize(.small)
                    .frame(width: 72)
                    Text("Pasting \(progress.sentBytes) of \(progress.totalBytes) bytes")
                    Button("Cancel") { model.cancelTerminalPaste(for: id) }
                        .buttonStyle(.borderless)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: KaisolaVisualSystem.hairline)
                }
                .padding(10)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Pasting into \(surfaceTitle(id))")
                .accessibilityValue("\(progress.sentBytes) of \(progress.totalBytes) bytes sent")
                .accessibilityHint("Cancel stops chunks that have not started sending")
            }
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

    private func keyboardFocusGeneration(for id: String) -> UInt64? {
        guard let request = model.keyboardFocusRequest,
              request.targetID == id else { return nil }
        return request.generation
    }

    private func fulfillTerminalKeyboardFocusRequest(for id: String) {
        guard let request = model.keyboardFocusRequest,
              request.targetID == id else { return }
        DispatchQueue.main.async {
            guard model.keyboardFocusRequest == request else { return }
            TerminalKeyboardFocus.moveFirstResponder(toSessionID: id)
        }
    }

    private func surfaceTitle(_ id: String) -> String {
        if let terminal = model.sessions.first(where: { $0.id == id }) {
            return model.sessionTitle(for: terminal)
        }
        if let chat = model.chats.first(where: { $0.id == id }) { return chat.conversation.title }
        if let mesh = model.meshes.first(where: { $0.id == id }) { return mesh.title }
        return missingTerminalPanePresentation(id).title
    }

    private func surfaceSymbol(_ id: String) -> String {
        if model.sessions.contains(where: { $0.id == id }) {
            return model.agentProfile(for: id)?.symbol ?? "terminal"
        }
        if model.chats.contains(where: { $0.id == id }) { return "bubble.left.and.text.bubble.right" }
        if model.meshes.contains(where: { $0.id == id }) { return "circle.hexagongrid.fill" }
        return missingTerminalPanePresentation(id).symbol
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

    private func terminalHeaderPresentation(_ id: String) -> TerminalHeaderPresentation? {
        guard let terminal = model.sessions.first(where: { $0.id == id }) else { return nil }
        return TerminalHeaderPresentation.resolve(
            exited: terminal.exited,
            authority: TerminalSurfaceAuthority(
                isOwned: model.isOwned(id),
                hasDurableOwnership: model.canClose(id)
            ),
            inputDegraded: model.isTerminalInputDegraded(id)
        )
    }

    private func terminalHeaderStatusColor(_ presentation: TerminalHeaderPresentation) -> Color {
        switch presentation.tone {
        case .ready: KaisolaStatusTone.done.foregroundColor
        case .inactive: .kaisolaSecondary
        }
    }

    private func surfaceLive(_ id: String) -> Bool {
        if let chat = model.chats.first(where: { $0.id == id }) { return chat.conversation.isConnected }
        return model.meshes.contains(where: { $0.id == id })
    }

    private func surfaceStatusLabel(_ id: String) -> String {
        if let terminal = terminalHeaderPresentation(id) {
            return terminal.accessibilityLabel
        }
        if let chat = model.chats.first(where: { $0.id == id }) {
            return chat.conversation.isConnected ? "Chat connected" : "Chat disconnected"
        }
        if model.meshes.contains(where: { $0.id == id }) { return "Mesh session" }
        return missingTerminalPanePresentation(id).statusLabel
    }

    private func surfaceAccessibilityLabel(_ id: String) -> String {
        if !model.sessions.contains(where: { $0.id == id }),
           !model.chats.contains(where: { $0.id == id }),
           !model.meshes.contains(where: { $0.id == id }) {
            return missingTerminalPanePresentation(id).accessibilityLabel
        }
        let liveActivityLabel = model.chats
            .first(where: { $0.id == id })
            .flatMap { chat in
                chat.conversation.isRunning
                    ? chat.conversation.liveThinkingStatus?.spoken
                    : nil
            }
        return SessionHeaderAccessibilityLabel.resolve(
            title: surfaceTitle(id),
            statusLabel: surfaceStatusLabel(id),
            liveActivityLabel: liveActivityLabel
        )
    }

    private func missingTerminalPanePresentation(_ id: String) -> MissingTerminalPanePresentation {
        guard let projectID = activeProjectID else {
            return MissingTerminalPanePresentation.resolve(
                context: MissingTerminalPaneContext(
                    state: .invalid,
                    title: "Terminal",
                    symbol: "terminal",
                    canClose: false
                )
            )
        }
        return MissingTerminalPanePresentation.resolve(
            context: model.missingTerminalPaneContext(for: id, projectID: projectID)
        )
    }

    private func handleTerminalBell(_ id: String) {
        guard let terminal = model.sessions.first(where: { $0.id == id }), !terminal.exited else {
            return
        }
        // AttentionCenter already models one live entry per target and kind;
        // avoid replacing it (and posting another system notification) for a
        // repaint burst that contains repeated BEL bytes.
        guard !attention.entries.contains(where: {
            $0.targetID == id && $0.kind == .bell
        }) else { return }
        attention.notify(
            // `sessionResponded` advances a durable broker-completion
            // acknowledgement watermark when cleared. BEL has no broker event
            // timestamp, so keep it in the dedicated bell lane, which reads as
            // needs-you (unlike `.turnCompleted`).
            kind: .bell,
            targetID: id,
            title: model.sessionTitle(for: terminal),
            detail: "Terminal requested attention"
        )
    }

    private func popOutTerminalButton(_ id: String) -> some View {
        Button {
            KaisolaMacAppDelegate.popOut(sessionID: id)
        } label: {
            Image(systemName: "macwindow.badge.plus")
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.kaisolaChrome)
        .foregroundStyle(.kaisolaSecondary)
        .help("Open this session in a new window")
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
        // The tracker is the explicit pointer surface and stays the final
        // overlay on a session divider. The verified cursor bug here was the
        // terminal's window-wide mouse monitor overwriting `resizeLeftRight`
        // after entry; detail-panel dividers have a different issue — hosted
        // AppKit siblings outrank nested SwiftUI trackers — and are hoisted at
        // `detailDividerTrackers`. Do not attribute either failure to `.help`:
        // its view is sized to the one-point rule, not the whole corridor.
        //
        // The cross-axis dimension is left `nil` on purpose: the tracker
        // stretches to the handle's full length, so the resize cursor and the
        // drag are live along the ENTIRE divider rather than over a centred
        // grip. The other axis is the corridor, which overhangs the one-point
        // rule by `SessionPaneDividerSizing.reach` on each side.
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
        // The corridor overhangs both neighbouring cards, and in a stack a
        // later sibling is drawn — and hit-tested — above an earlier one. Left
        // at the default the divider only reached backwards, so half the
        // corridor was swallowed by the card after it.
        .zIndex(1)
    }
}

enum SessionPaneDividerSizing {
    /// The visible rule consumes only one layout point. Its overlaid pointer
    /// target reaches into both adjacent cards, so acquisition stays generous
    /// without turning a splitter into a blank gutter.
    static let layoutExtent: CGFloat = 1
    /// 17 → 22 in v1.1.7, so the corridor clears
    /// `NativeWorkspaceChrome.dividerCorridorReach` on each side and matches
    /// the sidebar splitter exactly. Internal, not private, because "every
    /// divider is grabbable" is a claim worth a test.
    static let hitExtent: CGFloat = 22
    /// How far the corridor reaches past the visible rule on each side.
    static var reach: CGFloat { (hitExtent - layoutExtent) / 2 }
}

/// Makes the system NavigationSplitView divider easy to acquire while leaving
/// AppKit in charge of its min/max constraints, collapse behavior, restoration,
/// and accessibility. The tracker lives just inside the sidebar so it does not
/// shift layout or add another visible divider.
///
/// Only the SIDEBAR half of the corridor lives here. `NSTrackingArea` is created
/// `.inVisibleRect`, and the sidebar is an `NSSplitView` subview, so everything
/// past the split boundary is clipped away: measured off the running app, a
/// 40pt-wide tracker centred on the divider had a `visibleRect` that stopped
/// 0.5pt past the divider's centre. Widening this view can therefore never buy
/// reach on the detail side — that half is `DetailEdgeResizeAffordance`, which
/// lives inside the detail column and drives the same `NSSplitView`.
private struct NavigationSidebarResizeAffordance: View {
    @Binding var hovered: Bool
    /// Only ONE instance in the column may vend the shared AX slider; the
    /// segments that cover the header band and the footer are silent. See
    /// `NavigationSidebarResizeHandle.exposesAccessibility`.
    var exposesAccessibility = true

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(hovered ? 0.95 : 0.42))
                .frame(width: NativeWorkspaceChrome.projectSidebarDividerWidth)
            Capsule()
                .fill(Color.accentColor.opacity(hovered ? 0.72 : 0.08))
                .frame(width: 3, height: 32)
        }
        // Overlay geometry does not consume layout, so the AppKit tracker is
        // centered across the real one-point divider and spans the whole
        // visible gap between the two inset chrome cards. Hover is reported by
        // that one AppKit view: a SwiftUI `.onHover` on the same rectangle is a
        // second tracking region over the same pixels, and the two disagreed at
        // the boundary, which is what made the pointer flicker there.
        // Width only: the tracker takes the affordance's full height, so the
        // corridor and the resize cursor run the ENTIRE length of the divider,
        // from the traffic-light clearance down past the footer. There is no
        // centred grip to find.
        .overlay {
            NavigationSidebarResizeHandle(
                hoverChanged: { hovered = $0 },
                exposesAccessibility: exposesAccessibility
            )
            .frame(width: NativeWorkspaceChrome.projectSidebarDividerHitWidth)
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("Drag or use Left/Right arrows to resize; double-click to reset")
    }
}

/// The detail-column half of the sidebar divider's grab corridor.
///
/// Draws nothing: the visible rule and the hover highlight belong to
/// `NavigationSidebarResizeAffordance` on the other side of the boundary. This
/// exists only because a tracking area cannot cross an `NSSplitView` subview's
/// clip, so "10pt of reach on each side of the line" needs a view on each side.
/// It reports its hover into the same state, so the rule still lights up when
/// the pointer approaches from the content side.
///
/// `.accessibilityHidden(true)` below prunes the SwiftUI accessibility tree,
/// but `TrackingView` also vends its own AX child directly through
/// `NSAccessibilityElement`/`accessibilityChildren()` — an AppKit-owned node
/// outside SwiftUI's tree, not covered by that modifier. Left unguarded, this
/// second instance of the handle exposed a second "Resize project sidebar"
/// slider sharing the sidebar's fixed identifier; `exposesAccessibility:
/// false` is what actually silences it.
private struct DetailEdgeResizeAffordance: View {
    @Binding var hovered: Bool

    var body: some View {
        NavigationSidebarResizeHandle(hoverChanged: { hovered = $0 }, exposesAccessibility: false)
            .frame(width: NativeWorkspaceChrome.dividerCorridorReach)
            .accessibilityHidden(true)
    }
}

/// A fallback for the SwiftUI versions that ignore
/// `navigationSplitViewColumnWidth`'s `ideal:` when *opening* a column, honour
/// only its `min:` and `max:`, and leave `ideal:` governing nothing but the
/// double-click reset. Where that happens, Kaisola's rail — sized in
/// `NativeWorkspaceChrome` for a row grammar that needs the room — opens at
/// AppKit's own ~195pt and truncates its titles until the user drags it.
///
/// Measured status, so nobody has to guess whether this is load-bearing: on
/// macOS 26 with the current SDK it is **inert**. A cold launch against cleared
/// defaults opens the column at exactly the ideal before this code gets a look, so
/// `shouldForceInitialWidth` returns false and nothing is written or moved. It
/// is kept because the guards make an inert fallback free — it can only act on
/// a column sitting at AppKit's untouched default, only once per window, and
/// only if the hierarchy walk finds a real `NSSplitView` — and because the
/// widths it protects are the ones the row grammar is designed around. If a
/// future SDK stops honouring `ideal:`, this is what keeps the rail at its ideal
/// instead of shipping truncated titles.
///
/// The rules that decide whether to override, kept pure and free of AppKit so
/// they can be tested without a window:
enum InitialSidebarWidth {
    /// The width AppKit opens a SwiftUI sidebar at when it ignores `ideal:`.
    /// Not a documented constant, so it is matched with a tolerance rather than
    /// for equality, and the whole feature is a no-op if the match fails.
    static let systemDefault: CGFloat = 195
    static let tolerance: CGFloat = 10

    /// Resting widths this feature itself asked for in earlier releases.
    ///
    /// A window the v1.1.8 applier forced to 210 restores at 210 forever: the
    /// persisted flag says the work is done and 210 sits outside the system
    /// default's band, so the 2026-08-14 widening could never reach the very
    /// windows the request was about. Widths the *app* placed are the app's to
    /// move again — matched exactly (±2 for the restoration round-trip), so a
    /// width the user dragged anywhere else stays exactly as found. 248
    /// joined the list with the v0.1.125 move to 290; 290 joined with the
    /// 2026-08-26 move to 245. Dragged widths persist, so a user choice can
    /// never sit in this band by accident.
    static let previouslyForcedIdeals: [CGFloat] = [210, 248, 290]
    static let previouslyForcedTolerance: CGFloat = 2

    /// True only for a column still sitting at AppKit's untouched default.
    ///
    /// This is the guard that makes the override safe: a restored width the
    /// user dragged, or any width a future macOS opens at, falls outside the
    /// window and is left exactly as found.
    static func isSystemDefault(_ width: CGFloat) -> Bool {
        abs(width - systemDefault) <= tolerance
    }

    static func isPreviouslyForcedIdeal(_ width: CGFloat) -> Bool {
        previouslyForcedIdeals.contains { abs(width - $0) <= previouslyForcedTolerance }
    }

    /// - Parameters:
    ///   - currentWidth: the sidebar column's width right now.
    ///   - didForce: whether this window's restoration id has already been
    ///     widened once *under the current key generation*. Persisted, so a
    ///     user who drags the rail narrower and relaunches keeps their width
    ///     even though it may land back inside the default's tolerance.
    static func shouldForceInitialWidth(currentWidth: CGFloat, didForce: Bool) -> Bool {
        guard !didForce else { return false }
        return isSystemDefault(currentWidth) || isPreviouslyForcedIdeal(currentWidth)
    }

    /// The key generation moves whenever the flag's meaning changes: v2
    /// recorded "this window was widened to 248", v3 "moved to 290", and each
    /// bump revisits flagged windows exactly once to move them to the current
    /// ideal (or to the user's own persisted width, which wins outright).
    static func defaultsKey(restorationID: String) -> String {
        "kaisola.sidebar.openedAtIdealWidth.v4.\(restorationID)"
    }

    static func hasApplied(restorationID: String, defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: defaultsKey(restorationID: restorationID))
    }

    static func markApplied(restorationID: String, defaults: UserDefaults) {
        defaults.set(true, forKey: defaultsKey(restorationID: restorationID))
    }

    /// Where the flag lives. A visual fixture runs the production hierarchy in
    /// a short-lived process and must not rewrite the real user's layout just
    /// because QA needed a screenshot — the same rule, and the same per-process
    /// suite, that the rest of the preview settings follow.
    static func store(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> UserDefaults {
        guard let suite = NativePreviewSettings.isolatedFixtureSuiteName(
            environment: environment,
            processIdentifier: processIdentifier
        ), let defaults = UserDefaults(suiteName: suite) else { return .standard }
        return defaults
    }

    /// Windows restored by SwiftUI carry an identifier; the autosave name is the
    /// fallback for anything that does not.
    static func restorationID(identifier: String?, frameAutosaveName: String) -> String {
        if let identifier, !identifier.isEmpty { return identifier }
        if !frameAutosaveName.isEmpty { return frameAutosaveName }
        return "kaisola.window"
    }
}

/// Applies `InitialSidebarWidth` once per window, by reaching the `NSSplitView`
/// that `NavigationSplitView` is built on.
///
/// Introspection, so it is written to fail quietly: if a future SwiftUI stops
/// backing the split with an `NSSplitView`, or reparents it, the hierarchy walk
/// finds nothing and the sidebar simply opens at whatever macOS chose — the
/// pre-existing behaviour, not a broken one.
struct InitialSidebarWidthApplier: NSViewRepresentable {
    var idealWidth: CGFloat = NativeWorkspaceChrome.projectSidebarIdealWidth
    var defaults: UserDefaults = InitialSidebarWidth.store()

    func makeNSView(context: Context) -> ApplierView {
        let view = ApplierView()
        view.idealWidth = idealWidth
        view.defaults = defaults
        return view
    }

    func updateNSView(_ nsView: ApplierView, context: Context) {}

    final class ApplierView: NSView {
        var idealWidth: CGFloat = NativeWorkspaceChrome.projectSidebarIdealWidth
        var defaults: UserDefaults = InitialSidebarWidth.store()
        private var settled = false
        private var attempts = 0
        /// The split view joins the hierarchy before it has laid its subviews
        /// out, so the first look can find no ancestor at all or a zero-width
        /// column. Retries are spaced in *time* rather than chained through
        /// `async`: five immediate runloop hops all land inside the same
        /// millisecond and answer the same unlaid-out question five times,
        /// which is indistinguishable from not retrying. Bounded hard, so this
        /// is a short settling window and never a poll.
        private static let maximumAttempts = 12
        private static let retryInterval: TimeInterval = 0.05

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !settled else { return }
            scheduleApply()
        }

        private func scheduleApply(afterSettling: Bool = false) {
            guard afterSettling else {
                DispatchQueue.main.async { [weak self] in self?.applyIfNeeded() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                self?.applyIfNeeded()
            }
        }

        private func applyIfNeeded() {
            guard !settled, let window else { return }
            attempts += 1
            guard let splitView = enclosingVerticalSplitView() else {
                // Nothing to drive. Retry through the settling window in case
                // the view simply has not been parented yet, then give up for
                // good — a SwiftUI that no longer uses NSSplitView must leave
                // the sidebar exactly as it found it.
                if attempts < Self.maximumAttempts {
                    scheduleApply(afterSettling: true)
                } else {
                    settled = true
                }
                return
            }
            let currentWidth = splitView.subviews[0].frame.width
            guard currentWidth > 1 else {
                if attempts < Self.maximumAttempts {
                    scheduleApply(afterSettling: true)
                } else {
                    settled = true
                }
                return
            }

            let restorationID = InitialSidebarWidth.restorationID(
                identifier: window.identifier?.rawValue,
                frameAutosaveName: window.frameAutosaveName
            )
            settled = true
            guard InitialSidebarWidth.shouldForceInitialWidth(
                currentWidth: currentWidth,
                didForce: InitialSidebarWidth.hasApplied(restorationID: restorationID, defaults: defaults)
            ) else { return }

            splitView.setPosition(idealWidth, ofDividerAt: 0)
            InitialSidebarWidth.markApplied(restorationID: restorationID, defaults: defaults)
            reportVisualFixtureWidth(splitView)
        }

        /// The sidebar column is the leading pane of the *nearest* enclosing
        /// vertical split. Nothing nested lies above this view: it is planted
        /// inside the sidebar, so any detail-side split is a sibling's
        /// descendant rather than an ancestor.
        private func enclosingVerticalSplitView() -> NSSplitView? {
            var candidate: NSView? = superview
            while let view = candidate {
                if let splitView = view as? NSSplitView,
                   splitView.isVertical,
                   splitView.subviews.count >= 2 {
                    return splitView
                }
                candidate = view.superview
            }
            return nil
        }

        private func reportVisualFixtureWidth(_ splitView: NSSplitView) {
            guard ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1" else {
                return
            }
            DispatchQueue.main.async {
                print(
                    "KAISOLA_NATIVE_VISUAL_SIDEBAR_WIDTH="
                        + "\(splitView.subviews[0].frame.width)"
                )
            }
        }
    }
}

// MARK: - Sidebar scroll pin

/// Where the sidebar list is allowed to be scrolled to, kept pure and free of
/// AppKit so the arithmetic can be tested without a window.
///
/// The defect it exists for: at launch the rail was reliably left scrolled 8pt
/// down with its content shorter than its own clip view, so the first project
/// row was clipped by a quarter — and on a workspace whose sessions arrive over
/// several seconds, once for every batch, until the first project row was gone
/// altogether. It is not an inset and not a safe area (both measured zero); it
/// is AppKit's own `-[NSTableRowData _keepTopRowStableAtLeastOnce:…]`
/// compensation, which runs inside the `endUpdates` that SwiftUI's
/// `OutlineListCoordinator.diffRows` performs whenever the rail's row set
/// changes. That compensation exists to hold a *user's* scroll position steady
/// while rows are inserted above it. At launch there is no such position to
/// hold, so what it preserves is an artefact.
enum SidebarScrollPin {
    /// How long after the sidebar appears the list is held at its top.
    ///
    /// Long enough to cover the row-diff batches a restored workspace produces
    /// (measured: the first compensation lands between 0.5s and 1.0s, and
    /// restored terminal state can add more), short enough that it can never be
    /// confused with owning the scroll position. Any deliberate scroll ends it
    /// early — see `SidebarScrollTopPin`.
    static let pinDuration: TimeInterval = 3.0

    /// - Parameters:
    ///   - currentY: the clip view's current vertical bounds origin.
    ///   - contentHeight: the document view's height.
    ///   - visibleHeight: the clip view's height.
    ///   - pinnedToTop: whether the launch settling window is still open.
    /// - Returns: the offset the clip view should be moved to, or `nil` when
    ///   the current one is already legal.
    ///
    /// Two rules, and neither can fight a user:
    /// 1. While pinned, the top is the only legal offset.
    /// 2. Always, the offset must lie inside the scrollable range. Landing
    ///    outside it is not something a scroll gesture can do — it is only ever
    ///    a compensation that out-ran its own content, which is exactly the bug.
    static func correction(
        currentY: CGFloat,
        contentHeight: CGFloat,
        visibleHeight: CGFloat,
        pinnedToTop: Bool
    ) -> CGFloat? {
        if pinnedToTop { return currentY == 0 ? nil : 0 }
        let maximum = max(0, contentHeight - visibleHeight)
        let clamped = min(max(currentY, 0), maximum)
        return clamped == currentY ? nil : clamped
    }
}

/// Holds the project rail at its top through launch, and forever after keeps it
/// inside its own scrollable range.
///
/// Introspection, written to fail quietly for the same reason
/// `InitialSidebarWidthApplier` is: if a future SwiftUI stops backing the
/// sidebar `List` with an `NSTableView`, the walk finds nothing and the rail
/// behaves exactly as it does today — the pre-existing behaviour, not a broken
/// one.
struct SidebarScrollTopPin: NSViewRepresentable {
    var pinDuration: TimeInterval = SidebarScrollPin.pinDuration

    func makeNSView(context: Context) -> PinView {
        let view = PinView()
        view.pinDuration = pinDuration
        return view
    }

    func updateNSView(_ nsView: PinView, context: Context) {}

    final class PinView: NSView {
        var pinDuration: TimeInterval = SidebarScrollPin.pinDuration

        private weak var scrollView: NSScrollView?
        private var pinDeadline: Date?
        private var liveScrolling = false
        private var liveScrollGraceUntil: Date?
        /// How long past a gesture's end the offset still belongs to AppKit.
        /// Covers momentum and the elastic snap-back that follows it.
        private static let liveScrollGrace: TimeInterval = 0.5
        private var attempts = 0
        private var correcting = false
        /// Same settling shape the width applier uses: the list is not backed by
        /// a table view the instant this is parented.
        private static let maximumAttempts = 12
        private static let retryInterval: TimeInterval = 0.05

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit { NotificationCenter.default.removeObserver(self) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, scrollView == nil else { return }
            pinDeadline = Date().addingTimeInterval(pinDuration)
            attach()
        }

        private func attach() {
            attempts += 1
            guard let found = sidebarScrollView() else {
                if attempts < Self.maximumAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
                        self?.attach()
                    }
                }
                return
            }
            scrollView = found
            found.contentView.postsBoundsChangedNotifications = true
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: found.contentView
            )
            // A deliberate scroll ends the pin immediately, so the settling
            // window can never be felt as the list refusing to move.
            center.addObserver(
                self,
                selector: #selector(beginLiveScroll),
                name: NSScrollView.willStartLiveScrollNotification,
                object: found
            )
            center.addObserver(
                self,
                selector: #selector(endLiveScroll),
                name: NSScrollView.didEndLiveScrollNotification,
                object: found
            )
            correct()
        }

        @objc private func beginLiveScroll() {
            pinDeadline = nil
            liveScrolling = true
        }

        /// Momentum keeps moving the clip view after the fingers leave, and the
        /// elastic snap-back is the last thing to run, so corrections stay
        /// suspended for a short tail past the gesture's own end.
        @objc private func endLiveScroll() {
            liveScrolling = false
            liveScrollGraceUntil = Date().addingTimeInterval(Self.liveScrollGrace)
        }

        @objc private func clipBoundsChanged() { correct() }

        /// Whether AppKit currently owns the offset and will settle it itself.
        private var scrollIsUserOwned: Bool {
            if liveScrolling { return true }
            guard let until = liveScrollGraceUntil else { return false }
            if Date() < until { return true }
            liveScrollGraceUntil = nil
            return false
        }

        private func correct() {
            guard !correcting, let scrollView, let document = scrollView.documentView else { return }
            // Never clamp underneath a live gesture. Elastic overscroll puts the
            // clip view outside its scrollable range *by design*, and AppKit
            // returns it on its own when the gesture ends; clamping each elastic
            // frame instead is what made the rail "recoil spazztically" under the
            // pointer. The clamp exists for the offset AppKit leaves behind after
            // a row diff, which is not a gesture and is unaffected here.
            guard !scrollIsUserOwned else { return }
            let clip = scrollView.contentView
            let pinned = pinDeadline.map { Date() < $0 } ?? false
            guard let target = SidebarScrollPin.correction(
                currentY: clip.bounds.origin.y,
                contentHeight: document.frame.height,
                visibleHeight: clip.bounds.height,
                pinnedToTop: pinned
            ) else { return }
            correcting = true
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
            correcting = false
        }

        /// The rail's scroll view is the nearest `NSTableView`-backed one at or
        /// above this view, which is planted in the sidebar column. The detail
        /// column's own scroll views are siblings' descendants, never ancestors.
        private func sidebarScrollView() -> NSScrollView? {
            var candidate: NSView? = superview
            while let view = candidate {
                if let scroll = tableBackedScrollView(in: view) { return scroll }
                candidate = view.superview
            }
            return nil
        }

        private func tableBackedScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return scroll }
            for child in view.subviews {
                if let scroll = tableBackedScrollView(in: child) { return scroll }
            }
            return nil
        }
    }
}

struct NavigationSidebarResizeHandle: NSViewRepresentable {
    var hoverChanged: (Bool) -> Void = { _ in }
    /// Whether this instance vends the shared AX slider.
    ///
    /// The handle is planted twice — once in the sidebar column, once in the
    /// detail column, because a tracking area cannot cross the `NSSplitView`'s
    /// clip (see `DetailEdgeResizeAffordance`) — but VoiceOver should find
    /// exactly one "Resize project sidebar" slider, not two elements sharing
    /// one fixed identifier. Only the sidebar-side instance exposes it; the
    /// detail-side one still tracks hover/cursor/drag identically, it just
    /// stays silent to accessibility.
    var exposesAccessibility = true

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.hoverChanged = hoverChanged
        view.exposesAccessibility = exposesAccessibility
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.hoverChanged = hoverChanged
        nsView.exposesAccessibility = exposesAccessibility
        // Deliberately NOT `invalidateCursorRects` here. `updateNSView` runs on
        // every SwiftUI pass — including every frame of the hover animation this
        // view's own callback drives — and each invalidation makes AppKit drop
        // and re-derive the cursor under the pointer, which is seen as the
        // resize cursor flickering back to the arrow while the pointer is
        // resting on the divider. The cursor now comes from a `.cursorUpdate`
        // tracking area, which is stable across re-renders and needs no
        // push/pop balancing.
        nsView.updateAccessibilityFrame()
    }

    final class TrackingView: NSView {
        var hoverChanged: (Bool) -> Void = { _ in }
        var exposesAccessibility = true
        private var lastWindowX: CGFloat?
        private weak var activeSplitView: NSSplitView?
        private var activeDividerIndex: Int?
        /// A bare click on the (deliberately wide) divider corridor must not
        /// stamp the current app-chosen width as a user choice — a stored
        /// width opts the user out of every future default-width migration.
        /// Only a drag that actually moved the divider persists.
        private var dragMoved = false
        private var trackingArea: NSTrackingArea?
        private lazy var dividerAccessibilityElement = NavigationSidebarAccessibilityElement(
            owner: self
        )

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { true }

        /// One tracking area owns both the cursor and the hover highlight, so
        /// there is exactly one source of truth for "the pointer is on the
        /// divider" and no second region to disagree with it.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        /// Defensive independently of whichever layout SwiftUI plants this view
        /// in: `enclosingVerticalDivider()` is the same guard `mouseDown` and
        /// the accessibility value/actions already trust, so a handle with
        /// nothing to drive shows no resize cursor either, rather than only
        /// discovering that after the pointer has already landed on it.
        override func cursorUpdate(with event: NSEvent) {
            guard enclosingVerticalDivider() != nil else {
                super.cursorUpdate(with: event)
                return
            }
            NSCursor.resizeLeftRight.set()
        }

        /// Same defense on the hit-testing side: a handle with no divider to
        /// drive takes no hits at all, so it can never sit in front of a click
        /// meant for whatever is actually under it. `mouseDown` already bails
        /// via the same guard, but only after accepting the event — this stops
        /// it from being routed here in the first place.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard enclosingVerticalDivider() != nil else { return nil }
            return super.hitTest(point)
        }

        override func mouseEntered(with event: NSEvent) { hoverChanged(true) }

        override func mouseExited(with event: NSEvent) {
            guard lastWindowX == nil else { return }
            hoverChanged(false)
        }

        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? {
            guard exposesAccessibility else { return [] }
            updateAccessibilityFrame()
            return [dividerAccessibilityElement]
        }

        fileprivate func updateAccessibilityFrame() {
            guard exposesAccessibility else { return }
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

        override func mouseDown(with event: NSEvent) {
            guard let match = enclosingVerticalDivider() else { return }
            window?.makeFirstResponder(self)
            if event.clickCount == 2 {
                match.splitView.setPosition(
                    NativeWorkspaceChrome.projectSidebarIdealWidth,
                    ofDividerAt: match.index
                )
                // A double-click means "back to the default", so it clears the
                // persisted drag rather than pinning the current ideal as one.
                NativePreviewSettings.shared.projectRailWidth =
                    NativePreviewSettings.projectRailWidthUnset
                return
            }
            activeSplitView = match.splitView
            activeDividerIndex = match.index
            lastWindowX = event.locationInWindow.x
            dragMoved = false
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
            dragMoved = true
        }

        override func mouseUp(with event: NSEvent) {
            // The width the user let go at is the width every window opens at
            // from now on. Written once per drag, here rather than per
            // mouseDragged, so a long drag is one defaults write. A zero-move
            // click writes nothing, and a collapsed pane's maxX of 0 would
            // round-trip as the unset sentinel, silently erasing the stored
            // choice — reject it.
            if dragMoved,
               let splitView = activeSplitView,
               let index = activeDividerIndex,
               splitView.subviews.indices.contains(index) {
                let width = Double(splitView.subviews[index].frame.maxX)
                if width > 0 {
                    NativePreviewSettings.shared.projectRailWidth = width
                }
            }
            dragMoved = false
            lastWindowX = nil
            activeSplitView = nil
            activeDividerIndex = nil
            // A drag that ended outside the handle swallowed its own exit
            // event while the mouse was down; settle the highlight here.
            if let window, !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                hoverChanged(false)
            }
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
            // Keyboard resizes persist the same way a drag's mouse-up does,
            // reading back the split view's clamped result.
            let width = Double(match.splitView.subviews[match.index].frame.maxX)
            if width > 0 {
                NativePreviewSettings.shared.projectRailWidth = width
            }
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
///
/// The tracker itself is no longer here: it is hoisted into one overlay on the
/// detail `HStack` (see `detailDividerTrackers`), because a tracker nested in
/// this handle sits in the backing hierarchy UNDER the panel beside it, and the
/// document panel hosts AppKit views that then answer for the corridor's
/// cursor. What stays is the visible rule, the keyboard path, and the AX
/// slider — one per divider.
private struct StablePanelResizeHandle: View {
    let label: String
    /// Kept with the semantic handle so its tooltip, label, and keyboard path
    /// describe the same divider. Pointer tracking is hoisted separately.
    let help: String
    /// Driven by the hoisted tracker's hover callback rather than local state:
    /// the pointer now enters a view that is no longer this one's descendant.
    let hovered: Bool
    let onBegan: () -> Void
    let onDelta: (CGFloat) -> Void
    let onEnded: () -> Void

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
        .help(help)
        // The visible rule is one layout point but its hover capsule is three,
        // so it still has to draw over the panel beside it.
        .zIndex(1)
    }
}

/// One AppKit overlay owns every detail-divider corridor. A SwiftUI `HStack` of
/// separate representables puts each tracking view inside another hosting
/// container; the document panel's hosted WKWebView/NSTextView can still outrank
/// that nested container for cursor dispatch. This representable is attached
/// directly to the detail stack, so it is one front-most AppKit sibling. Its
/// `hitTest` returns `nil` outside the narrow corridor rectangles, leaving the
/// document, terminal, and Files surfaces completely interactive.
private struct DetailDividerTrackingView: NSViewRepresentable {
    let corridors: [NativeDetailPaneSizing.Corridor]
    let corridorWidth: CGFloat
    let hoverChanged: (NativeDetailPaneSizing.Divider?) -> Void
    let dragBegan: () -> Void
    let deltaChanged: (NativeDetailPaneSizing.Divider, CGFloat) -> Void
    let dragEnded: () -> Void
    let doubleClicked: (NativeDetailPaneSizing.Divider) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        update(nsView)
    }

    private func update(_ view: TrackingView) {
        let geometryChanged = view.corridors != corridors || view.corridorWidth != corridorWidth
        view.corridors = corridors
        view.corridorWidth = corridorWidth
        view.hoverChanged = hoverChanged
        view.dragBegan = dragBegan
        view.deltaChanged = deltaChanged
        view.dragEnded = dragEnded
        view.doubleClicked = doubleClicked
        if geometryChanged { view.updateTrackingAreas() }
    }

    final class TrackingView: NSView {
        var corridors: [NativeDetailPaneSizing.Corridor] = []
        var corridorWidth: CGFloat = 0
        var hoverChanged: (NativeDetailPaneSizing.Divider?) -> Void = { _ in }
        var dragBegan: () -> Void = {}
        var deltaChanged: (NativeDetailPaneSizing.Divider, CGFloat) -> Void = { _, _ in }
        var dragEnded: () -> Void = {}
        var doubleClicked: (NativeDetailPaneSizing.Divider) -> Void = { _ in }

        private static let dividerKey = "divider"
        private var corridorTrackingAreas: [NSTrackingArea] = []
        private var draggingDivider: NativeDetailPaneSizing.Divider?
        private var lastWindowPoint: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func isAccessibilityElement() -> Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview else { return nil }
            let localPoint = convert(point, from: superview)
            return divider(at: localPoint) == nil ? nil : self
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in corridorTrackingAreas { removeTrackingArea(area) }
            corridorTrackingAreas = corridors.compactMap { corridor in
                let centerX = bounds.maxX - corridor.centerFromTrailing
                let rect = NSRect(
                    x: centerX - corridorWidth / 2,
                    y: bounds.minY,
                    width: corridorWidth,
                    height: bounds.height
                ).intersection(bounds)
                guard !rect.isEmpty else { return nil }
                let area = NSTrackingArea(
                    rect: rect,
                    options: [.activeInActiveApp, .mouseEnteredAndExited, .cursorUpdate],
                    owner: self,
                    userInfo: [Self.dividerKey: corridor.divider.rawValue]
                )
                addTrackingArea(area)
                return area
            }
        }

        override func cursorUpdate(with event: NSEvent) {
            guard divider(for: event.trackingArea) != nil else { return }
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            hoverChanged(divider(for: event.trackingArea))
        }

        override func mouseExited(with event: NSEvent) {
            guard draggingDivider == nil else { return }
            hoverChanged(nil)
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let divider = divider(at: point) else { return }
            if event.clickCount == 2 {
                draggingDivider = nil
                lastWindowPoint = nil
                doubleClicked(divider)
                return
            }
            draggingDivider = divider
            lastWindowPoint = event.locationInWindow
            dragBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            let point = event.locationInWindow
            guard let divider = draggingDivider, let previous = lastWindowPoint else { return }
            lastWindowPoint = point
            let delta = point.x - previous.x
            guard abs(delta) >= 0.25 else { return }
            deltaChanged(divider, delta)
        }

        override func mouseUp(with event: NSEvent) {
            guard draggingDivider != nil else { return }
            draggingDivider = nil
            lastWindowPoint = nil
            dragEnded()
            hoverChanged(divider(at: convert(event.locationInWindow, from: nil)))
        }

        private func divider(at point: NSPoint) -> NativeDetailPaneSizing.Divider? {
            corridors.first { corridor in
                abs((bounds.maxX - point.x) - corridor.centerFromTrailing) <= corridorWidth / 2
            }?.divider
        }

        private func divider(for area: NSTrackingArea?) -> NativeDetailPaneSizing.Divider? {
            guard let rawValue = area?.userInfo?[Self.dividerKey] as? String else { return nil }
            return NativeDetailPaneSizing.Divider(rawValue: rawValue)
        }
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
        // No `invalidateCursorRects`: this runs on every SwiftUI pass, and the
        // hover callback below drives one. Re-deriving the cursor while the
        // pointer sits on the divider is what made it flicker between the
        // resize cursor and the arrow. The cursor comes from the tracking
        // area's `.cursorUpdate` instead. Session dividers keep this view as
        // their final overlay; detail dividers use
        // `DetailDividerTrackingView` above hosted AppKit content.
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

        /// The divider's one AX slider is vended by the SwiftUI handle. Hoisted
        /// out of that handle's accessibility element, this view would otherwise
        /// be free to appear in the tree beside it as a second, silent element.
        override func isAccessibilityElement() -> Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func cursorUpdate(with event: NSEvent) {
            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        }

        override func mouseEntered(with event: NSEvent) {
            hoverChanged(true)
        }

        override func mouseExited(with event: NSEvent) {
            // A drag that leaves the handle keeps the divider live until mouse
            // up; dropping the highlight mid-drag reads as the handle letting
            // go of the pointer.
            guard lastWindowPoint == nil else { return }
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
            if let window, !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                hoverChanged(false)
            }
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

/// Settings takes over the workspace (2026-08-28, "should take over the
/// whole workspace kind of like chatgpt app"): the full-window two-column
/// page — "← Back to app" atop the left rail, search, grouped sections; the
/// selected section's card-grouped rows on the right. It is presentation
/// only, mounted OVER the running workspace, so closing it restores every
/// session exactly as it was. The old standalone ⌘, window and the sheet are
/// retired; this is the one Settings surface.
///
/// Because this is an overlay rather than a sheet, Sparkle actions no longer
/// need the dismissal dance the sheet coordinator existed for: an attached
/// sheet blocked the termination request, an overlay blocks nothing, so
/// check and install run directly.
private struct WorkspaceSettingsTakeover: View {
    @ObservedObject var settings: NativePreviewSettings
    let workspace: URL?
    let initialSectionID: String?
    let interruptibleTurnCount: () -> Int
    let close: () -> Void
    let closeOnEscape: () -> Void

    var body: some View {
        SettingsView(
            settings: settings,
            checkForUpdates: KaisolaMacAppDelegate.sharedCanCheckForUpdates()
                ? { NotificationCenter.default.post(name: .kaisolaCheckForUpdates, object: nil) }
                : nil,
            installPendingUpdate: { UpdateCenter.shared.installAndRelaunch() },
            updateDetail: KaisolaMacAppDelegate.sharedUpdateAvailabilityDetail(),
            interruptibleTurnCount: interruptibleTurnCount,
            workspace: workspace,
            initialSectionID: initialSectionID,
            backToApp: close,
            titleBarClearance: NativeWorkspaceChrome.chromePanelTopInset
        )
        // The page must fully occlude the live workspace beneath it. The
        // canvas recipe does that by construction — its material samples
        // behind the WINDOW (or paints the baked still), never sibling
        // views — so Settings sits on the shell's own ground.
        .background {
            WorkspaceBackdropView(mode: settings.workspaceBackdrop)
                .ignoresSafeArea()
        }
        // Esc restores the workspace. A zero-size cancel-action button is
        // deterministic regardless of which control inside the page holds
        // focus; `.onExitCommand` would need the takeover itself focused.
        .background {
            Button(action: closeOnEscape) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
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
    /// Where the inset chrome panels start. Clears the traffic lights *and*
    /// the 52pt AppKit toolbar band that `NavigationSplitView` installs for its
    /// own Hide Sidebar toggle, which otherwise clips the sidebar card's
    /// top-right corner.
    static let chromePanelTopInset: CGFloat = 46
    /// 76 → 88 with the Safari-inset traffic lights: the zoom button's
    /// trailing edge moved from ~61 to ~74, and the merged bar's switcher
    /// keeps a comfortable lane after it.
    static let topBarTrafficLightClearance: CGFloat = 88
    static let projectSidebarMinimumWidth: CGFloat = 168
    /// The rail's resting width. 200 → 248 in v1.1.6 to buy a legible title and
    /// a visible hierarchy step; 248 → 228 in v1.1.7 once the rail stopped
    /// spending width on chrome; 228 → 210 in v1.1.8; 210 → 248 in v0.1.124 by
    /// request — long project and session titles were the point of the wide
    /// rail, and the density passes had walked the default back below legible;
    /// 248 → 290 in v0.1.125, again by request, matching the width Michael
    /// pins the Files rail to; 290 → 245 on 2026-08-26, again by request —
    /// the double-click reset should land "1-2cm less wide" than it did.
    /// Users who dragged their rail keep their width — a drag persists
    /// (`NativePreviewSettings.projectRailWidth`), so this constant sizes
    /// fresh windows and the divider's double-click reset.
    static let projectSidebarIdealWidth: CGFloat = 245
    /// Raised alongside the ideal so a user who wants long titles can have
    /// them; the minimum is unchanged, so nothing about the narrow rail moves.
    static let projectSidebarMaximumWidth: CGFloat = 340

    /// The width a fresh sidebar column opens at: the user's persisted drag
    /// when one exists (clamped to this rail's own band), else the resting
    /// ideal above. Pure, so "which width wins" is a test rather than a
    /// window.
    static func resolvedProjectRailIdealWidth(storedWidth: Double) -> CGFloat {
        guard storedWidth > 0 else { return projectSidebarIdealWidth }
        return CGFloat(min(
            max(storedWidth, Double(projectSidebarMinimumWidth)),
            Double(projectSidebarMaximumWidth)
        ))
    }
    static let projectSidebarDividerWidth: CGFloat = 1
    /// Centered across the visible divider, not laid wholly inside either pane.
    ///
    /// Sized from what the eye sees rather than from the one-point rule: the
    /// detail card is inset by `chromeInset`, so the gap the pointer aims at is
    /// that gutter plus the rule. The hit zone spans the whole gap and reaches
    /// well past it onto the surface on each side, so the pointer never crosses
    /// a dead band between "over the content" and "over the divider" — a dead
    /// band is what made the cursor flicker there.
    ///
    /// v1.1.7 widened it from 18 to 22 so the reach clears
    /// `dividerCorridorReach` on both sides: "grab it anywhere" has to mean the
    /// pointer finds the divider before the user aims at it, and 8.5pt of reach
    /// was still a line you had to hit.
    static let projectSidebarDividerHitWidth: CGFloat =
        KaisolaVisualSystem.chromeInset * 2 + 10
    static let projectSidebarDividerReach: CGFloat =
        (projectSidebarDividerHitWidth - projectSidebarDividerWidth) / 2
    /// The floor every draggable divider in the app clears on each side of its
    /// visible line. One number so the sidebar splitter and the pane handles
    /// cannot drift apart; see `SessionPaneDividerSizing`.
    static let dividerCorridorReach: CGFloat = 10
    /// A detail-chrome toggle's own height, which the chrome band wraps.
    static let detailChromeControlHeight: CGFloat = 24
    static let detailChromeControlWidth: CGFloat = 26
    /// Monoline SF Symbols at toolbar weight. 12 → 16 in v1.1.8: at 12 the lone
    /// Files glyph read as a hairline sitting in an empty 40pt band, and a pair
    /// of controls at that size reads as debris rather than as a control group.
    static let detailChromeGlyphSize: CGFloat = 16
    /// Between the two toggles. Tight enough that they read as one group and not
    /// as two unrelated buttons that happen to share a corner.
    static let detailChromeControlGap: CGFloat = 2
    /// Breathing room around the hover-revealed toggles, which is also what
    /// sizes the strip they live in.
    static let detailToggleRevealPadding: CGFloat = 2
    /// How far past the two controls the hover target reaches, leading side.
    ///
    /// Sized from the pointer rather than from the pair it reveals: a target the
    /// size of what it shows is one you have to already know is there. It costs
    /// nothing to be generous — the strip is empty at rest, and the sensor takes
    /// no clicks.
    static let detailToggleRevealLead: CGFloat = 60
    /// The whole hover target, which is what a test can hold: the two controls,
    /// their gap, the padding around them, and the leading reach.
    static var detailToggleRevealWidth: CGFloat {
        detailChromeControlWidth * 2
            + detailChromeControlGap
            + detailToggleRevealPadding * 2
            + detailToggleRevealLead
    }

    /// The detail card's top gutter in the **top-bar** layout, and the height of
    /// the strip the two panel toggles are revealed in there.
    ///
    /// v1.1.9 cut this from 46 to 28 — deleting the 40pt chrome band and leaving
    /// a strip exactly as tall as the controls it reveals, empty at rest.
    static var detailToggleStripHeight: CGFloat {
        detailChromeControlHeight + detailToggleRevealPadding * 2
    }

    /// The workspace's top gutter, per navigation layout. History below;
    /// the shipped answer is the final paragraph.
    ///
    /// The card era's `.leftTree` answer was `chromeInset`: the card ran to
    /// the window's own top edge with nothing above it but the standard
    /// gutter every other side already had.
    ///
    /// v1.1.9 stopped 28pt short and said why: the Files rail opens a 30pt
    /// header bar 6pt below the card's top edge, and the hover-revealed toggles
    /// were anchored to the card's top-**right** corner, which is precisely
    /// where that header's controls are. Only 12 of the original 40pt band ever
    /// reached the pane.
    ///
    /// Three homes for the pair were tried and measured on a dev launch before
    /// settling on none of them:
    ///
    /// 1. **The sidebar's traffic-light band.** The obvious answer — 46pt of
    ///    space the platform reserves whether or not anything is drawn in it.
    ///    Two problems, both found by measurement rather than by reasoning.
    ///    `NavigationSplitView` already puts its own Hide Sidebar item in the
    ///    band's trailing 47pt (`AXButton "Hide Sidebar" @(305, 95) 47×52`), and
    ///    — fatally — that band is the AppKit `AXToolbar`'s territory, which
    ///    swallows mouse events over the sidebar column. Controls drawn there
    ///    render, report correct frames, and respond to `AXPress`, but a real
    ///    synthesized click at their centre does nothing. A control that only
    ///    VoiceOver can operate is not a control.
    /// 2. **The card's top-leading corner.** 16pt of clearance before the
    ///    session pane's own title button starts.
    /// 3. **The card's top-trailing corner with the card at the top.** The
    ///    original collision, unchanged.
    ///
    /// So the pair is *removed* here rather than relocated, which is also the
    /// direction this rail has been moving in for three releases. Every door it
    /// held stays open, and all of them were verified present on the same
    /// launch: the Files rail's own header carries a permanent, clickable Hide
    /// Files button; the document preview carries its own close control; the
    /// sidebar footer's overflow menu carries a permanent `Show or Hide Files`
    /// and `Show or Hide Document Preview`; and ⌘B / ⇧⌘B, the View menu and the
    /// command palette are untouched. Closing a panel stays one click. Opening
    /// one by mouse is the footer menu instead of a hover the user had to know
    /// about.
    ///
    /// The detail column at this height *is* clickable — the same launch put a
    /// real click through the Files rail's own header button at window-top + 31
    /// and watched the rail close — so the card's own contents lose nothing by
    /// moving up into the toolbar band. Only the sidebar half of that band is
    /// dead to the mouse.
    ///
    /// **Graduated 2026-08-28: zero, both layouts.** The floating chrome card
    /// is gone — the workspace fills its region edge to edge and the window's
    /// 30pt corner is the only clip — so there is no card gutter left for
    /// this inset to size. The function survives (rather than a deleted
    /// constant) because it is the one place a future band would come back,
    /// and the contract test pins the flush state.
    static func detailPanelTopInset(layout: NavigationLayout) -> CGFloat {
        switch layout {
        case .leftTree: return 0
        case .topBar: return 0
        }
    }

    /// Whether the canvas is holding *nothing* — the state in which the glass
    /// backdrop is allowed to drop its legibility wash and be genuinely
    /// transparent to the wallpaper (see `WorkspaceBackdropView.idle`).
    ///
    /// Every mounted surface disqualifies it, because every one of them puts
    /// text over the backdrop that the wash's contrast floors are solved for:
    /// session panes, the document preview, the browser card, and the Files
    /// rail all count, and so does the missing-session recovery state, which is
    /// itself text on the canvas. The empty-state card does not — it carries
    /// its own material.
    nonisolated static func canvasIsIdle(
        layoutIsEmpty: Bool,
        hasRecovery: Bool,
        browserMounted: Bool,
        previewMounted: Bool,
        filesRailVisible: Bool
    ) -> Bool {
        layoutIsEmpty && !hasRecovery && !browserMounted && !previewMounted && !filesRailVisible
    }
}

/// The pane header's trailing cluster and context actions, pinned as data so
/// the 2026-08-28 declutter cannot silently regress: Michael — "the spacing
/// of these should be done better, we can remove the arrow full screen
/// button and the account button." `RootShellView.unifiedSessionHeader`
/// renders the cluster by iterating `trailingControls`, so what the tests
/// hold is what is on screen.
///
/// Action inventory for the two removed buttons:
/// - Maximize/Restore (the arrow) → the pane's context menu
///   (`contextActions` pins `.toggleMaximize`).
/// - Account & model switching (the person glyph) → the chat's ellipsis
///   overflow (`chatOverflow` carries `chatAccountMenuContent`); the app
///   account stays on the footer's account chip.
enum UnifiedSessionHeaderGrammar {
    /// One tight, evenly spaced cluster instead of the old spread.
    static let clusterSpacing: CGFloat = 2

    enum Control: Hashable {
        case meshQueue
        case meshConfiguration
        case chatOverflow
        case terminalTranscript
        case terminalPopOut
        case hide
        case detailDoors
    }

    static func trailingControls(
        isChat: Bool,
        isMesh: Bool,
        isTerminal: Bool,
        hostsDetailDoors: Bool
    ) -> [Control] {
        var controls: [Control] = []
        if isMesh { controls.append(contentsOf: [.meshQueue, .meshConfiguration]) }
        if isChat { controls.append(.chatOverflow) }
        if isTerminal { controls.append(contentsOf: [.terminalTranscript, .terminalPopOut]) }
        controls.append(.hide)
        if hostsDetailDoors { controls.append(.detailDoors) }
        return controls
    }

    enum ContextAction: Hashable {
        case rename
        case openTranscript
        case moveToProject
        case toggleMaximize
        case hide
    }

    static func contextActions(isTerminal: Bool) -> [ContextAction] {
        var actions: [ContextAction] = [.rename]
        if isTerminal { actions.append(contentsOf: [.openTranscript, .moveToProject]) }
        actions.append(contentsOf: [.toggleMaximize, .hide])
        return actions
    }
}

/// Horizontal clearance for the first session pane. The source list normally
/// owns the titlebar controls' lane. In detail-only mode that lane belongs to
/// the workspace, so its identity header starts after both the traffic lights
/// and the native Show Sidebar control rather than drawing underneath them.
enum UnifiedSessionHeaderLayout {
    static let ordinaryLeadingInset: CGFloat = 10
    static let collapsedSidebarLeadingInset: CGFloat = 152

    static func leadingInset(
        navigationLayout: NavigationLayout,
        columnVisibility: NavigationSplitViewVisibility,
        isWindowLeadingPane: Bool
    ) -> CGFloat {
        guard navigationLayout == .leftTree,
              columnVisibility == .detailOnly,
              isWindowLeadingPane else { return ordinaryLeadingInset }
        return collapsedSidebarLeadingInset
    }
}

/// Lets the isolated screenshot harness start with the native source list
/// collapsed, so the real full-size titlebar geometry can be inspected. Normal
/// launches ignore the presentation flag even if it happens to be present.
enum RootSidebarVisibilityFixture {
    nonisolated static func initialVisibility(
        environment: [String: String]
    ) -> NavigationSplitViewVisibility {
        guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              environment["KAISOLA_NATIVE_VISUAL_SIDEBAR_VISIBILITY"] == "detailOnly" else {
            return .all
        }
        return .detailOnly
    }
}

/// When the sidebar carries an "Other Macs" section at all. Pure so the rule
/// can be tested without a signed-in account or a catalog fetch.
enum RememberedSessionsSectionVisibility {
    /// - Returns: `true` only when the section has something to say — at least
    ///   one remembered remote device, or an error about a fleet that has
    ///   actually been seen. An empty, healthy catalog draws nothing, and a
    ///   never-paired install stays silent even when the saved-session refresh
    ///   fails: an error is only worth showing about a fleet that exists.
    static func shouldShow(
        remoteDeviceCount: Int,
        errorMessage: String?,
        hasEverSeenRemoteDevice: Bool
    ) -> Bool {
        if remoteDeviceCount > 0 { return true }
        guard hasEverSeenRemoteDevice, let errorMessage else { return false }
        return !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Sidebar disclosure defaults, kept pure so the persistence semantics can be
/// tested without a `List`.
///
/// The active project always shows its own sessions; every other project is a
/// compact one-line row until the user opens it, so the rail stays short no
/// matter how many folders are open. Only the non-active state persists: the
/// expanded set records opt-in peeks and the original `collapsedProjects` key
/// keeps its meaning as an explicit collapse, which is also what migrates an
/// install made before the default flipped.
enum ProjectExpansionState {
    static func decode(_ raw: String) -> Set<String> {
        Set(raw.components(separatedBy: ",").filter { !$0.isEmpty })
    }

    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }

    static func isExpanded(
        projectID: String,
        isActive: Bool,
        expanded: Set<String>,
        collapsed: Set<String>
    ) -> Bool {
        // The active project's surfaces always show, the way Safari always
        // shows the current tab group's tabs. This also fences the upgrade
        // hazard: an install that collapsed a project before the default
        // flipped must not open onto an empty rail when that project is the
        // one being worked in.
        if isActive { return true }
        if collapsed.contains(projectID) { return false }
        return expanded.contains(projectID)
    }

    /// Records a disclosure toggle. Collapsing the active project is refused —
    /// and the legacy `collapsedProjects` entry an upgrading install may still
    /// carry for it is dropped on the way through, so the row heals itself the
    /// first time it is touched.
    static func toggled(
        expanded shouldExpand: Bool,
        projectID: String,
        isActive: Bool,
        expanded: Set<String>,
        collapsed: Set<String>
    ) -> (expanded: Set<String>, collapsed: Set<String>) {
        var expandedSet = expanded
        var collapsedSet = collapsed
        guard !isActive else {
            collapsedSet.remove(projectID)
            return (expandedSet, collapsedSet)
        }
        if shouldExpand {
            expandedSet.insert(projectID)
            collapsedSet.remove(projectID)
        } else {
            expandedSet.remove(projectID)
            collapsedSet.insert(projectID)
        }
        return (expandedSet, collapsedSet)
    }
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

    /// Which panel a detail divider resizes. The two dividers now share one
    /// tracker overlay, so each corridor has to name the panel it drives.
    enum Divider: String, Hashable, CaseIterable, Identifiable {
        case preview
        case rail

        var id: String { rawValue }
    }

    /// One divider's pointer corridor, measured from the detail pane's TRAILING
    /// edge because that is the edge the panels are anchored to: the content
    /// column is the flexible one, so a corridor's distance from the right of
    /// the pane depends only on the panel widths `resolve` already returned.
    struct Corridor: Equatable, Identifiable {
        let divider: Divider
        /// Trailing edge → the CENTRE of the divider's one-point rule.
        let centerFromTrailing: CGFloat

        var id: String { divider.rawValue }
    }

    /// Where each visible detail divider sits, right to left. The overlay that
    /// hosts the trackers is attached to the whole detail `HStack`, so it has
    /// to place them itself rather than inherit the stack's own layout.
    static func corridors(
        widths: Widths,
        previewVisible: Bool,
        railVisible: Bool,
        trailingPanelInset: CGFloat = 0
    ) -> [Corridor] {
        var corridors: [Corridor] = []
        // Walk in from the trailing edge in the same order the layout mounts
        // the panels: [ content | preview divider | preview | rail divider |
        // rail ]. Everything is flush now — `trailingPanelInset` survives
        // only for a hypothetical future gutter and is zero in the shipped
        // layout.
        var consumed: CGFloat = trailingPanelInset
        if railVisible {
            corridors.append(
                Corridor(divider: .rail, centerFromTrailing: widths.rail + dividerWidth / 2)
            )
            consumed = widths.rail + dividerWidth + trailingPanelInset
        }
        if previewVisible {
            corridors.append(
                Corridor(
                    divider: .preview,
                    centerFromTrailing: consumed + widths.preview + dividerWidth / 2
                )
            )
        }
        return corridors
    }

    /// One visible/layout point with a forgiving overlaid acquisition target.
    static let dividerWidth: CGFloat = 1
    /// 17 → 22 in v1.1.8. These two dividers (the document preview's and the
    /// Files rail's) were the last in the app still below
    /// `NativeWorkspaceChrome.dividerCorridorReach`: 17 buys 8pt of reach on
    /// each side where every other divider buys 10.5. Matching
    /// `SessionPaneDividerSizing.hitExtent` exactly is the point — "every
    /// divider is grabbable, and grabbable by the same amount" is one claim, not
    /// three, and a test now reads all three constants against the one floor.
    static let dividerHitWidth: CGFloat = 22
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
/// The merged bar's leading control (2026-08-28 decision 2): the current
/// project's name and a chevron, opening a menu of every open project. It
/// replaces the full project tab strip; reordering and per-project actions
/// stay on the context menu the strip's chips carried.
private struct TopBarProjectSwitcher: View {
    let projects: [AppModel.ProjectGroup]
    @Binding var selected: String?
    let contextMenu: (AppModel.ProjectGroup) -> AnyView

    @State private var hovering = false

    var body: some View {
        let current = projects.first { $0.id == selected }
        Menu {
            ForEach(projects) { project in
                Button {
                    selected = project.id
                } label: {
                    if project.id == selected {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let tint = ProjectTint.color(current?.colorHex) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                }
                Text(current?.name ?? "No Project")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let current, current.attentionCount > 0 {
                    KaisolaStatusBadge(
                        text: "\(current.attentionCount)",
                        systemImage: "exclamationmark",
                        tone: .needsYou
                    )
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.kaisolaSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                ShellTabShape.shape()
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            }
            .contentShape(Rectangle())
        }
        // `.button` + `.plain`, the footer account chip's recipe: the
        // borderless bridge flattens a custom HStack label to its text and
        // draws its own leading indicator, which is exactly what the compact
        // switcher must not look like.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { inside in
            withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) {
                hovering = inside
            }
        }
        .help("Switch project")
        .accessibilityLabel(
            current.map { "Project: \($0.name)" } ?? "Project switcher"
        )
        .accessibilityIdentifier("topbar.project-switcher")
        .contextMenu {
            if let current { contextMenu(current) }
        }
    }
}

/// The merged bar's trailing cluster: New Session in the active project, and
/// the existing switch-to-sidebar control, unchanged from the old project
/// strip's trailing pair.
private struct TopBarTrailingControls: View {
    let activeProject: AppModel.ProjectGroup?
    let newSession: (AppModel.ProjectGroup) -> Void
    let useSidebar: () -> Void

    @State private var hoveredKey: String?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                guard let activeProject, activeProject.directory != nil else { return }
                newSession(activeProject)
            } label: {
                iconCircle("plus", enabled: activeProject?.directory != nil)
            }
            .buttonStyle(.plain)
            .onHover { hoveredKey = $0 ? "plus" : (hoveredKey == "plus" ? nil : hoveredKey) }
            .disabled(activeProject?.directory == nil)
            .help(
                activeProject.map { project in
                    project.directory == nil
                        ? "Locate this project before starting a session"
                        : "New session in \(project.name)"
                } ?? "Open a project before starting a session"
            )
            .accessibilityLabel(
                activeProject.map { "New session in \($0.name)" } ?? "New session"
            )
            Button(action: useSidebar) {
                iconCircle("sidebar.left", enabled: true, hoverKey: "sidebar")
            }
            .buttonStyle(.plain)
            .onHover { hoveredKey = $0 ? "sidebar" : (hoveredKey == "sidebar" ? nil : hoveredKey) }
            .help("Move projects and sessions to the sidebar")
            .accessibilityLabel("Use sidebar navigation")
        }
    }

    private func iconCircle(
        _ symbol: String,
        enabled: Bool,
        hoverKey: String? = nil
    ) -> some View {
        let key = hoverKey ?? symbol
        let hovering = hoveredKey == key && enabled
        let presence = enabled ? 1.0 : 0.45
        return Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.kaisolaDisabled))
            .frame(width: 26, height: 26)
            .background(Color.primary.opacity((hovering ? 0.09 : 0.04) * presence), in: Circle())
            .overlay {
                Circle().stroke(
                    Color.primary.opacity((hovering ? 0.16 : 0.08) * presence),
                    lineWidth: 0.8
                )
            }
            .animation(.easeOut(duration: KaisolaVisualSystem.hoverDuration), value: hovering)
    }
}

private struct SessionStrip: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One hover at a time across the whole strip; the tabs had no pointer
    /// feedback at all, and a per-row `@State` would leave stale highlights
    /// behind fast pointer sweeps.
    @State private var hoveredTabID: String?
    let projectID: String?
    let draft: NewSessionDraft?
    let selectedDraftID: String?
    let selectDraft: (String) -> Void
    let selectRealSurface: () -> Void
    let cancelDraft: (String) -> Void
    let rename: (String) -> Void
    let closeChat: (AcpChatHandle) -> Void
    let deleteChat: (AcpChatHandle) -> Void
    let closeMesh: (MeshSession) -> Void
    let deleteMesh: (MeshSession) -> Void
    let deleteRecentlyClosed: (AppModel.RecentlyClosedSurface) -> Void

    private var project: AppModel.ProjectGroup? {
        model.projects.first { $0.id == projectID }
    }

    var body: some View {
        // Derived once per pass, on purpose.
        //
        // These were four computed properties, each reaching `project`, which
        // rebuilds `model.projects` — six dictionaries, three filtered counts, a
        // set union and a sort. The body reads them a dozen times, so a single
        // render rebuilt that a dozen times, in a view that re-renders whenever
        // anything on AppModel publishes.
        //
        // Kept as locals rather than properties so the cost cannot quietly come
        // back: a new reference in this body reuses the binding instead of
        // reaching through an accessor that looks free and is not.
        let project = self.project
        let sessions = project?.sessions ?? []
        let chats = project.map { model.chats(in: $0.id) } ?? []
        let meshes = project.map { model.meshes(in: $0.id) } ?? []
        let recentlyClosed = project.map { model.recentlyClosedSurfaces(in: $0.id) } ?? []
        // `draft != nil` matters: with no draft at all, `draft?.id ==
        // selectedDraftID` is `nil == nil` — true — and that phantom
        // "selected draft" suppressed every real tab's selected state. The
        // old strip's resting fills hid the bug; the graduated active-card
        // design exposed it.
        let draftSelected = draft != nil && draft?.id == selectedDraftID
        // The merged bar's packed tabs (2026-08-28 feedback: "condensed"): a
        // plain HStack at fixed `MergedTopBarGrammar.tabGap` gaps, not a
        // horizontal ScrollView, sized to its content so the bar's flexible
        // gap stays OUTSIDE the strip. At narrow widths the tabs compress in
        // place — inactive titles truncate first, the active tab keeps its
        // title longest via `layoutPriority` — and they never spread to fill
        // a wide bar. (The full overflow policy, a count menu, is future
        // work.)
        return HStack(spacing: MergedTopBarGrammar.tabGap) {
            tabRows(
                draftSelected: draftSelected,
                sessions: sessions,
                chats: chats,
                meshes: meshes,
                recentlyClosed: recentlyClosed
            )
        }
        .padding(.leading, MergedTopBarGrammar.tabGap)
        .frame(maxHeight: .infinity)
        // The one animated value the whole strip shares: hover washes ease
        // in and out instead of flipping (2026-08-28, "General UI buttons
        // and clicking should be smooth").
        .animation(
            reduceMotion ? nil : .easeOut(duration: KaisolaChromeControlWash.duration),
            value: hoveredTabID
        )
    }

    /// Every tab in the strip, shared verbatim by the two containers: the
    /// empty-state line, the draft, chats, meshes, the Recently Closed menu,
    /// and the terminal sessions, in the shipped order.
    @ViewBuilder
    private func tabRows(
        draftSelected: Bool,
        sessions: [BrokerTerminalRecord],
        chats: [AcpChatHandle],
        meshes: [MeshSession],
        recentlyClosed: [AppModel.RecentlyClosedSurface]
    ) -> some View {
                if sessions.isEmpty, chats.isEmpty, meshes.isEmpty, recentlyClosed.isEmpty, draft == nil {
                    Text("No activity in this project")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                        .padding(.horizontal, 8)
                }
                if let draft {
                    Button { selectDraft(draft.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("New Session")
                        }
                        .font(.callout.weight(draftSelected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            surfaceTabBackground(
                                selected: draftSelected,
                                tint: WorkspacePalette.project,
                                hovered: hoveredTabID == draft.id
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(draftSelected ? 1 : 0)
                    .onHover { hovering in
                        hoveredTabID = hovering ? draft.id : (hoveredTabID == draft.id ? nil : hoveredTabID)
                    }
                    .accessibilityLabel("New Session")
                    .accessibilityAddTraits(draftSelected ? .isSelected : [])
                    .contextMenu {
                        Button("Cancel New Session") { cancelDraft(draft.projectID) }
                    }
                    .id(draft.id)
                }
                ForEach(chats) { chat in
                    Button {
                        selectRealSurface()
                        model.selectChatPreservingConcurrentOutput(chat.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                            Text(chat.conversation.title).lineLimit(1)
                            if let status = chat.conversation.liveThinkingStatus {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.mini).scaleEffect(0.5)
                                    Text(status.word)
                                        .font(.caption2.weight(.medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(KaisolaStatusTone.working.foregroundColor)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(status.spoken)
                            }
                            if let usage = chat.conversation.usage,
                               let amount = usage.costAmount,
                               let cost = UsageCenter.costLabel(
                                   amount: amount,
                                   currency: usage.costCurrency
                               ) {
                                Text(cost)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.kaisolaSecondary)
                            }
                        }
                        .font(.callout.weight(
                            !draftSelected && model.selectedChatID == chat.id ? .semibold : .regular
                        ))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            surfaceTabBackground(
                                selected: !draftSelected && model.selectedChatID == chat.id,
                                tint: WorkspacePalette.chat,
                                hovered: hoveredTabID == chat.id
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(!draftSelected && model.selectedChatID == chat.id ? 1 : 0)
                    .onHover { hovering in
                        hoveredTabID = hovering ? chat.id : (hoveredTabID == chat.id ? nil : hoveredTabID)
                    }
                    .contextMenu {
                        if chat.conversation.isRunning {
                            Button("Stop Chat") { model.stopChat(chat.id) }
                        }
                        Button("Close to Recently Closed") { closeChat(chat) }
                        Button("Delete Chat…", role: .destructive) { deleteChat(chat) }
                    }
                    .id(chat.id)
                }
                ForEach(meshes) { mesh in
                    Button {
                        selectRealSurface()
                        model.selectMesh(mesh.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.hexagongrid.fill")
                                .foregroundStyle(WorkspacePalette.mesh)
                            Text(mesh.title).lineLimit(1)
                            if mesh.stage != "Idle" {
                                Text(mesh.stage)
                                    .font(.caption2)
                                    .foregroundStyle(.kaisolaSecondary)
                            }
                        }
                        .font(.callout.weight(
                            !draftSelected && model.selectedMeshID == mesh.id ? .semibold : .regular
                        ))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            surfaceTabBackground(
                                selected: !draftSelected && model.selectedMeshID == mesh.id,
                                tint: WorkspacePalette.mesh,
                                hovered: hoveredTabID == mesh.id
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(!draftSelected && model.selectedMeshID == mesh.id ? 1 : 0)
                    .onHover { hovering in
                        hoveredTabID = hovering ? mesh.id : (hoveredTabID == mesh.id ? nil : hoveredTabID)
                    }
                    .contextMenu {
                        if mesh.anyRunning {
                            Button("Stop All Columns") { Task { await mesh.stopAllTurns() } }
                        }
                        Button("Close to Recently Closed") { closeMesh(mesh) }
                        Button("Delete Mesh…", role: .destructive) { deleteMesh(mesh) }
                    }
                    .id(mesh.id)
                }
                if !recentlyClosed.isEmpty {
                    Menu {
                        if let newest = recentlyClosed.first {
                            Button("Undo Last Close") { restoreRecentlyClosed(newest.id) }
                            Divider()
                        }
                        ForEach(recentlyClosed) { surface in
                            Menu(surface.title) {
                                Button("Restore") { restoreRecentlyClosed(surface.id) }
                                Button("Delete Permanently…", role: .destructive) {
                                    deleteRecentlyClosed(surface)
                                }
                            }
                        }
                    } label: {
                        Label("Recently Closed \(recentlyClosed.count)", systemImage: "clock.arrow.circlepath")
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .menuStyle(.borderlessButton)
                    // A macOS Menu accepts whatever width it is offered;
                    // pinned to its label so it can never soak up the bar's
                    // flexible gap and shove the tabs apart.
                    .fixedSize()
                    .help("Restore or permanently delete closed chats and Mesh runs")
                    .accessibilityLabel("Recently Closed, \(recentlyClosed.count) items")
                }
                ForEach(sessions) { session in
                    let visible = model.selectedSessionID == session.id
                        || model.splitDocuments[session.id] != nil
                    let working: Bool = {
                        if case .working = session.agentActivity, !session.exited { return true }
                        return false
                    }()
                    Button {
                        selectRealSurface()
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
                                      : Color.kaisolaTertiary)
                                .frame(width: 6, height: 6)
                            Text(model.sessionTitle(for: session)).lineLimit(1)
                        }
                        .font(.callout.weight(
                            !draftSelected && model.selectedSessionID == session.id ? .semibold : .regular
                        ))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            surfaceTabBackground(
                                selected: !draftSelected && model.selectedSessionID == session.id,
                                tint: WorkspacePalette.terminal,
                                hovered: hoveredTabID == session.id
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(!draftSelected && model.selectedSessionID == session.id ? 1 : 0)
                    .onHover { hovering in
                        hoveredTabID = hovering ? session.id : (hoveredTabID == session.id ? nil : hoveredTabID)
                    }
                    .contextMenu {
                        Button("Rename…") { rename(session.id) }
                        if model.isOwned(session.id) || model.canClose(session.id) {
                            Button("End Session", role: .destructive) {
                                model.commitClose(session.id)
                                Task { await model.drainPendingReleases() }
                            }
                        }
                    }
                    .id(session.id)
                }
    }

    private func restoreRecentlyClosed(_ id: String) {
        Task {
            switch await model.restoreRecentlyClosedSurface(id) {
            case .completed, .unavailable, .needsConfirmation:
                break
            case let .blocked(message):
                ToastCenter.shared.show(message, style: .error, duration: 5)
            }
        }
    }

    /// The graduated pill tabs: the active tab is a white-led card on the
    /// shared bar surface with the existing soft shadow language; inactive
    /// tabs are quiet text on the glass with NO resting fill, gaining a
    /// faint wash on hover. Status speaks through the small mark before each
    /// title, so `tint` does not colour the plate. (`tint` stays in the
    /// signature because each tab family still declares its palette voice —
    /// the leading marks use it.)
    @ViewBuilder
    private func surfaceTabBackground(
        selected: Bool,
        tint: Color,
        hovered: Bool = false
    ) -> some View {
        if selected {
            ShellTabCardBackground()
        } else if hovered {
            ShellTabShape.shape()
                .fill(Color.primary.opacity(KaisolaChromeControlWash.hoverOpacity))
        }
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

/// The footer's plan-usage chip, derived from the same `UsageCenter` readings
/// Settings ▸ Usage renders as cards.
///
/// Pure, and deliberately not a method on `UsageCenter`: the chip is a *view*
/// decision (which one number earns four characters of a 40pt-tall footer),
/// not a fact about usage, and keeping it here means the rule can be changed
/// without touching the probe.
enum FooterUsageChip {
    enum Level: Equatable {
        case normal, warning, critical
    }

    struct Reading: Equatable {
        /// Rounded, clamped to 0…100.
        let percent: Int
        let level: Level
        /// The account the number belongs to, for the tooltip. The chip itself
        /// never spends width on it.
        let providerName: String
        /// Which limit window the number came from.
        let windowLabel: String

        var label: String { "\(percent)%" }

        var accessibilityLabel: String {
            "\(providerName) plan usage, \(percent) percent of \(windowLabel) used"
        }

        var help: String {
            "\(providerName) · \(windowLabel) \(percent)% used — open Usage settings"
        }
    }

    /// Amber from three-quarters, red from ninety percent. Both are *late*: a
    /// footer that is orange most of the day has stopped meaning anything.
    static let warningThreshold = 75
    static let criticalThreshold = 90

    static func level(forPercent percent: Int) -> Level {
        if percent >= criticalThreshold { return .critical }
        if percent >= warningThreshold { return .warning }
        return .normal
    }

    /// The one number the chip shows.
    ///
    /// The *primary* account is the first reading that can answer at all —
    /// `UsageCenter.planUsage` is built in the order the accounts are
    /// configured, so "first" is the user's own ordering — and a healthy
    /// (`ok`) account is preferred over one that is reporting a problem.
    /// Within that account the chip shows its *tightest* window rather than an
    /// average: what matters is the limit you are about to hit, and a 5-hour
    /// window at 95% is not softened by a monthly window at 10%.
    static func reading(_ providers: [UsageCenter.ProviderPlanUsage]) -> Reading? {
        let candidates = providers.filter { !windows($0).isEmpty }
        guard let provider = candidates.first(where: \.ok) ?? candidates.first else { return nil }
        guard let tightest = windows(provider).max(by: { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }),
              let used = tightest.usedPercent else { return nil }
        let percent = Int(min(max(used, 0), 100).rounded())
        return Reading(
            percent: percent,
            level: level(forPercent: percent),
            providerName: provider.displayName,
            windowLabel: tightest.label
        )
    }

    private static func windows(_ provider: UsageCenter.ProviderPlanUsage) -> [UsageCenter.PlanWindow] {
        provider.windows.filter { window in
            guard let used = window.usedPercent else { return false }
            return used.isFinite
        }
    }
}

/// What the footer's account name is actually given, stated as arithmetic for
/// the same reason `QuietRowBudget` is: the name silently regressed to a fixed
/// 118pt chip, so widening the sidebar did nothing and "michael ofen…" stayed
/// truncated at every width. The chip is now bounded by the *footer*, not by a
/// constant, and this is the number that says so.
enum FooterAccountBudget {
    /// Leading and trailing padding the footer row itself pays. The leading side
    /// went 8 → 6 in v1.1.8, the first rung of the 210pt rail's recovery ladder.
    static let leadingPadding: CGFloat = 6
    static let trailingPadding: CGFloat = 5
    static var horizontalPadding: CGFloat { leadingPadding + trailingPadding }
    /// Gap between footer controls. The 228pt resting rail (down from 248pt)
    /// left only 99.0pt for a name that needs 117.3pt, so this shrank from 5
    /// to 2 to help buy that back — the controls sit closer, the name lane
    /// gets the difference.
    static let gap: CGFloat = 2
    /// The avatar that leads the account chip, plus its gap to the name.
    ///
    /// 22 → 18 in v1.1.8, the second rung. An avatar is an identity cue, not a
    /// portrait; at 18 it is still comfortably above the ~16pt where a circular
    /// photo stops resolving as a face, and the 4pt goes straight to the name.
    static let avatarGap: CGFloat = 6
    /// 18 → 24 by request: at 18 the avatar was an identity cue and not much
    /// else, and the footer as a whole read smaller than the thing it
    /// represents. This spends 6pt of the name lane, which the lane can afford
    /// only because v1.1.8 also made the label the *first name* — see
    /// `nameWidth` for the measured budget that decision leaves behind.
    static let avatarSize: CGFloat = 24
    static var avatarSlot: CGFloat { avatarSize + avatarGap }
    /// A square footer control (gear, overflow). Shrank from 22 to 16 for the
    /// same reason `gap` did: the glyphs inside are 12pt and were never what
    /// needed a 22pt frame, so the slot now sits closer to the glyph and the
    /// tap target is restored separately, via `tapTargetExpansion`, instead of
    /// being reserved as layout width. Every point bought back here is a
    /// point the account name keeps — see `FooterAccountBudget` callers and
    /// the test that pins the name's width at the default sidebar.
    /// 16 → 14 when the attention bell took a permanent lane.
    ///
    /// Reserving that lane so the footer stops rearranging itself costs the
    /// account name 16pt, which would have pushed it back under the 118pt fixed
    /// chip the v1.1.8 ladder was built to escape. Rather than pay for a stable
    /// footer with the regression that ladder exists to prevent, the three
    /// trailing controls give up a point each side: their glyphs are 12pt and
    /// never needed a 16pt frame, and `tapTargetExpansion` keeps the hit target
    /// where it was.
    /// 14 → 18 by request, alongside the avatar. The glyphs inside grow with it
    /// (12 → 14) and take a heavier ink, because at 12pt in secondary grey the
    /// gear and the bell were the quietest things in a column of names they are
    /// meant to sit level with.
    static let controlSlot: CGFloat = 18
    /// How far a control's *hit* region extends past its visual
    /// `controlSlot` frame, on every side. `contentShape` grows into the
    /// row's own gaps rather than the frame growing into the name's width, so
    /// the tap target stays ≥20pt (16 + 2×2) without costing the name a
    /// single point.
    static let tapTargetExpansion: CGFloat = 3
    /// Padding inside the usage chip, on each side. 2 → 1 in v1.1.8, the third
    /// and last rung: the chip is text with no capsule behind it, so its padding
    /// only separates four characters from the `gap` already on either side.
    static let usageChipHorizontalPadding: CGFloat = 1

    /// - Returns: points the account *name* can use before it must truncate.
    /// The attention bell is charged **unconditionally**, unlike the usage chip.
    ///
    /// It used to be charged only while it was showing, which is what made it the
    /// "bizarre button in the middle": the control cluster is right-aligned as a
    /// unit, so a bell that came and went slid the gear and the usage percentage
    /// about 32pt sideways every time an agent finished a turn, and it landed in
    /// the empty middle of the row as the only saturated colour among 12pt grey
    /// glyphs. Reserving its lane buys a footer whose controls never move.
    static func nameWidth(
        footerWidth: CGFloat,
        usageChipWidth: CGFloat
    ) -> CGFloat {
        // gear + attention + overflow all hold their slots always; the usage chip
        // is the one control still present only when it has something to say, and
        // it sits at the cluster's leading edge where its arrival moves nothing
        // to its right.
        var trailing = controlSlot * 3 + gap * 3
        if usageChipWidth > 0 { trailing += usageChipWidth + gap }
        return footerWidth - horizontalPadding - avatarSlot - trailing
    }
}

/// What the account chip renders. The footer is a compact identity control, so
/// it consistently shows the first name rather than changing labels as the rail
/// is resized. The whole account name remains in help text and the account menu.
enum FooterAccountName {
    /// Case is the account's own. A single-token name and the email fallback
    /// remain intact; multi-part display names reduce to their first token.
    static func displayed(_ name: String) -> String {
        guard !name.contains("@"), let first = name.split(whereSeparator: \.isWhitespace).first else {
            return name
        }
        return String(first)
    }
}

/// The "Add Project" ghost row's recent-folders menu: recents that still exist
/// as directories and are not already open, newest first, capped so the menu
/// stays a quick pick rather than a history browser.
enum AddableRecentFolders {
    static let limit = 8

    static func compute(
        recent: [String],
        openProjectPaths: Set<String>,
        isDirectory: (URL) -> Bool
    ) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for path in recent {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard !openProjectPaths.contains(url.path),
                  seen.insert(url.path).inserted,
                  isDirectory(url) else { continue }
            result.append(url)
            if result.count == limit { break }
        }
        return result
    }
}

/// The first decision in the Run on picker. Unavailable paths are deliberately
/// their own scope so a search can never make an offline recent look runnable.
enum RunOnScope: String, CaseIterable, Equatable, Sendable {
    case local
    case worktree
    case unavailable

    var sectionTitle: String {
        switch self {
        case .local: "This Computer"
        case .worktree: "Mesh Worktrees"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .local: "desktopcomputer"
        case .worktree: "arrow.triangle.branch"
        case .unavailable: "externaldrive.badge.exclamationmark"
        }
    }
}

/// One exact execution boundary. The confirmation string is intentionally a
/// complete four-line contract: a friendly project name alone is never enough
/// authority to start a process.
struct RunOnTarget: Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let branch: String?
    let host: String
    let scope: RunOnScope
    let isRecent: Bool

    var id: String { "\(scope.rawValue):\(path):\(branch ?? "")" }
    var canStart: Bool { scope != .unavailable }

    func confirmation(accountName: String) -> String {
        [
            "Filesystem: \(path)",
            "Git branch: \(branch ?? "Not a Git repository")",
            "Account: \(accountName)",
            "Execution host: \(host)",
        ].joined(separator: "\n")
    }
}

/// Pure picker state shared by AppKit and contract tests. Filtering starts
/// with the selected scope and only then applies the query.
struct RunOnPickerModel: Equatable, Sendable {
    private(set) var targets: [RunOnTarget]
    private(set) var selectedScope: RunOnScope
    private(set) var query = ""
    private(set) var selectedTargetID: String?

    init(targets: [RunOnTarget], selectedScope: RunOnScope? = nil, selectedTargetID: String? = nil) {
        self.targets = targets
        self.selectedScope = selectedScope
            ?? RunOnScope.allCases.first(where: { scope in targets.contains { $0.scope == scope } })
            ?? .local
        self.selectedTargetID = selectedTargetID
        normalizeSelection()
    }

    var filteredTargets: [RunOnTarget] {
        let scoped = targets.filter { $0.scope == selectedScope }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return scoped }
        return scoped.filter { target in
            target.name.localizedCaseInsensitiveContains(needle)
                || target.path.localizedCaseInsensitiveContains(needle)
                || (target.branch?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    var selectedTarget: RunOnTarget? {
        filteredTargets.first { $0.id == selectedTargetID } ?? filteredTargets.first
    }

    mutating func selectScope(_ scope: RunOnScope) {
        selectedScope = scope
        query = ""
        selectedTargetID = nil
        normalizeSelection()
    }

    mutating func updateQuery(_ query: String) {
        self.query = query
        normalizeSelection()
    }

    mutating func selectTarget(_ id: String?) {
        selectedTargetID = id
        normalizeSelection()
    }

    @discardableResult
    mutating func removeRecent(targetID: String) -> String? {
        guard let target = targets.first(where: { $0.id == targetID }), target.isRecent else {
            return nil
        }
        targets.removeAll { $0.id == targetID }
        if selectedTargetID == targetID { selectedTargetID = nil }
        normalizeSelection()
        return target.path
    }

    private mutating func normalizeSelection() {
        if !targets.contains(where: { $0.scope == selectedScope }),
           let remainingScope = RunOnScope.allCases.first(where: { scope in
               targets.contains { $0.scope == scope }
           }) {
            selectedScope = remainingScope
            query = ""
            selectedTargetID = nil
        }
        let visible = filteredTargets
        if !visible.contains(where: { $0.id == selectedTargetID }) {
            selectedTargetID = visible.first?.id
        }
    }
}

/// Snapshot inputs used off the main actor so file-system and Git probes never
/// block terminal rendering while the picker is prepared.
enum RunOnTargetBuilder {
    struct Project: Equatable, Sendable {
        let name: String
        let path: String
    }

    struct Worktree: Equatable, Sendable {
        let name: String
        let path: String
        let branch: String
    }

    static func build(
        projects: [Project],
        recentPaths: [String],
        worktrees: [Worktree],
        host: String,
        isDirectory: (String) -> Bool,
        branch: (String) -> String?
    ) -> [RunOnTarget] {
        var seen = Set<String>()
        var availableLocal: [RunOnTarget] = []
        var availableWorktrees: [RunOnTarget] = []
        var unavailable: [RunOnTarget] = []

        func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        }

        func appendLocal(name: String, path rawPath: String, recent: Bool) {
            let path = normalized(rawPath)
            guard seen.insert(path).inserted else { return }
            let exists = isDirectory(path)
            let target = RunOnTarget(
                name: name,
                path: path,
                branch: exists ? branch(path) : nil,
                host: host,
                scope: exists ? .local : .unavailable,
                isRecent: recent
            )
            if exists { availableLocal.append(target) } else { unavailable.append(target) }
        }

        for project in projects {
            appendLocal(name: project.name, path: project.path, recent: false)
        }
        for recentPath in recentPaths {
            appendLocal(
                name: URL(fileURLWithPath: recentPath, isDirectory: true).lastPathComponent,
                path: recentPath,
                recent: true
            )
        }
        for worktree in worktrees {
            let path = normalized(worktree.path)
            guard seen.insert(path).inserted else { continue }
            let exists = isDirectory(path)
            let target = RunOnTarget(
                name: worktree.name,
                path: path,
                branch: worktree.branch,
                host: host,
                scope: exists ? .worktree : .unavailable,
                isRecent: false
            )
            if exists { availableWorktrees.append(target) } else { unavailable.append(target) }
        }
        return availableLocal + availableWorktrees + unavailable
    }
}

/// Human-readable launch summaries for the Run On sheet, value-based so the
/// same contract can be verified without driving a modal window.
enum RunOnPickerPresentation {
    static func accountTitle(
        _ profile: UsageAccountProfile,
        among profiles: [UsageAccountProfile]
    ) -> String {
        let duplicates = profiles.filter {
            $0.label.localizedCaseInsensitiveCompare(profile.label) == .orderedSame
        }
        guard duplicates.count > 1 else { return profile.label }
        let directoryName = URL(fileURLWithPath: profile.expandedDirectory).lastPathComponent
        return "\(profile.label) · \(directoryName)"
    }

    static func confirmation(
        target: RunOnTarget?,
        accountName: String
    ) -> String {
        guard let target else {
            return "No project or worktree in this location matches the search."
        }
        let branch = target.branch ?? "Not a Git repository"
        return "\(target.name) · \(branch) · \(target.host)\n\(target.path)\nSubscription: \(accountName)"
    }
}

/// The launch choice that remains authoritative while only the execution
/// folder is being changed. The optional outer value means "use defaults";
/// a present value with a nil account explicitly means Project default.
struct RunOnPickerSelection: Equatable, Sendable {
    let accountProfileID: String?
}

/// The account menu's visible contract. Keeping the rows as values makes the
/// shipping menu and its diagnostics use the same presentation decisions.
struct ConnectionFooterPresentation: Equatable {
    enum SectionID: String, Hashable {
        case authentication
        case destinations
        case about
    }

    enum Action: String, Hashable {
        case signInWithGoogle
        case signOut
        case settings
        case usage
        case copyDiagnostics

        var title: String {
            switch self {
            case .signInWithGoogle: "Sign In with Google"
            case .signOut: "Sign Out"
            case .settings: "Settings…"
            case .usage: "Usage…"
            case .copyDiagnostics: "Copy Diagnostics"
            }
        }

        var systemImage: String {
            switch self {
            case .signInWithGoogle: "person.crop.circle.badge.plus"
            case .signOut: "rectangle.portrait.and.arrow.right"
            case .settings: "gearshape"
            case .usage: "gauge.with.dots.needle.bottom.50percent"
            case .copyDiagnostics: "doc.on.doc"
            }
        }
    }

    enum Row: Hashable, Identifiable {
        case action(Action)

        var id: String {
            switch self {
            case let .action(action): "action:\(action.rawValue)"
            }
        }
    }

    struct Section: Equatable, Identifiable {
        let id: SectionID
        let title: String?
        let rows: [Row]
    }

    let sections: [Section]
    let diagnosticLines: [String]

    init(
        accountName: String?,
        appVersion: String
    ) {
        sections = [
            Section(
                id: .authentication,
                title: accountName,
                rows: [.action(accountName == nil ? .signInWithGoogle : .signOut)]
            ),
            Section(
                id: .destinations,
                title: nil,
                rows: [.action(.settings), .action(.usage)]
            ),
            Section(
                id: .about,
                title: "Kaisola v\(appVersion)",
                rows: [.action(.copyDiagnostics)]
            ),
        ]
        diagnosticLines = ["Kaisola \(appVersion)"]
    }

    static func attentionInboxIsPresented(afterActivating isPresented: Bool) -> Bool {
        !isPresented
    }
}

/// The footer's update affordance (2026-08-28: "when there is a new update it
/// should be downloadable and small update button next to notification button
/// in the bottom left corner"). Pure presentation over `UpdateCenter`'s two
/// axes so visibility is a table the tests hold: absent entirely when nothing
/// is downloaded, an actionable badge while an install is ready, and a
/// disabled spinner once installation has started (so a second click cannot
/// race the relaunch).
enum FooterUpdateBadge: Equatable {
    case hidden
    case ready(version: String)
    case installing

    static func resolve(pendingVersion: String?, isInstalling: Bool) -> FooterUpdateBadge {
        guard let pendingVersion else { return .hidden }
        return isInstalling ? .installing : .ready(version: pendingVersion)
    }

    var help: String {
        switch self {
        case .hidden: ""
        case let .ready(version): "Update to Kaisola \(version) — restarts to install"
        case .installing: "Installing update and restarting…"
        }
    }
}

private struct ConnectionFooter: View {
    @EnvironmentObject private var auth: AuthModel
    var jumpToAttention: ((String) -> Void)?
    /// Resolves an inbox target to its project and liveness at render time —
    /// see `AttentionInboxModel`. Nil (previews, fixtures) renders the flat
    /// ungrouped inbox.
    var attentionContext: ((String) -> (projectName: String?, exists: Bool))?
    @State private var inboxFilter: Set<AttentionCenter.Kind>?
    var newMesh: (() -> Void)?
    var newStagedMesh: (() -> Void)?
    var newIdeaMesh: (() -> Void)?
    let filePreviewVisible: Bool
    let toggleFilePreview: () -> Void
    let filesVisible: Bool
    let toggleFiles: () -> Void
    let showSettings: () -> Void
    let showUsage: () -> Void

    @ObservedObject private var usage = UsageCenter.shared

    @ObservedObject private var attention = AttentionCenter.shared
    @ObservedObject private var updates = UpdateCenter.shared
    @State private var showInbox = false

    private static let appVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "Dev"

    /// Identity, the two things worth one click, then everything else behind
    /// one overflow.
    ///
    /// The footer used to be a six-glyph multicolor shelf, and the correction
    /// for that over-corrected: Settings and Usage both went behind a menu, so
    /// the two destinations the user visits daily cost two clicks and a read.
    /// v1.1.6 promotes exactly those two, and pays for the width by no longer
    /// spending a fixed 118pt on the account chip. Both promotions are quiet —
    /// a monochrome gear and a secondary-text percentage, no color unless the
    /// usage number has earned it.
    ///
    /// The account chip is the only flexible child: everything else is
    /// `fixedSize`, so the name gets the whole remainder and truncates only
    /// when the sidebar is genuinely at its minimum.
    ///
    /// Order, graduated 2026-08-28: account chip, usage, the gear (the
    /// Settings-takeover door — pressing it again is Back to app), then the
    /// update badge sitting next to the bell it belongs beside, the bell,
    /// and the overflow.
    var body: some View {
        HStack(spacing: FooterAccountBudget.gap) {
            accountMenu
            usageChip
            settingsButton
            updateButton
            attentionButton
            overflowMenu
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.leading, FooterAccountBudget.leadingPadding)
        .padding(.trailing, FooterAccountBudget.trailingPadding)
        .frame(height: 40)
    }

    /// One click to Settings — the workspace takeover's door and, while the
    /// takeover is up, its "back to app". Monochrome on purpose: it is a
    /// door, not a state.
    private var settingsButton: some View {
        Button(action: showSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.kaisolaPrimary)
                .frame(width: FooterAccountBudget.controlSlot, height: FooterAccountBudget.controlSlot)
                .contentShape(Rectangle().inset(by: -FooterAccountBudget.tapTargetExpansion))
        }
        .buttonStyle(.kaisolaChrome)
        .fixedSize()
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("footer.settings")
    }

    /// The small install-and-relaunch affordance beside the bell. Wired to
    /// `UpdateCenter`'s published state — the Sparkle plumbing that already
    /// owns readiness — never a poll loop; absent entirely when there is
    /// nothing to install (`FooterUpdateBadge`).
    @ViewBuilder
    private var updateButton: some View {
        let badge = FooterUpdateBadge.resolve(
            pendingVersion: updates.pendingUpdate?.version,
            isInstalling: updates.isInstallingUpdate
        )
        if badge != .hidden {
            Button {
                UpdateCenter.shared.installAndRelaunch()
            } label: {
                Group {
                    if badge == .installing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: FooterAccountBudget.controlSlot, height: FooterAccountBudget.controlSlot)
                .contentShape(Rectangle().inset(by: -FooterAccountBudget.tapTargetExpansion))
            }
            .buttonStyle(.kaisolaChrome)
            .fixedSize()
            .disabled(badge == .installing)
            .help(badge.help)
            .accessibilityLabel(badge.help)
            .accessibilityIdentifier("footer.update")
        }
    }

    /// The primary account's tightest plan window, as one percentage that opens
    /// Settings ▸ Usage. Absent entirely until a reading exists — an empty
    /// chip, a spinner or a "—" would all be noise in a 40pt footer.
    ///
    /// Text only, with no capsule behind it. A filled chip was the first draft
    /// and it cost ~10pt of padding, which is width the account name needs at
    /// the default sidebar; it also read louder than the gear beside it, which
    /// is the opposite of what this footer is for. The tooltip and the
    /// accessibility label carry what the four characters cannot.
    @ViewBuilder
    private var usageChip: some View {
        if let reading = FooterUsageChip.reading(usage.planUsage) {
            Button(action: showUsage) {
                Text(reading.label)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Self.usageTint(reading.level))
                    .padding(.horizontal, FooterAccountBudget.usageChipHorizontalPadding)
                    .frame(height: FooterAccountBudget.controlSlot)
                    .contentShape(Rectangle().inset(by: -FooterAccountBudget.tapTargetExpansion))
            }
            .buttonStyle(.kaisolaChrome)
            .fixedSize()
            .help(reading.help)
            .accessibilityLabel(reading.accessibilityLabel)
            .accessibilityIdentifier("footer.usage")
        }
    }

    /// Secondary until the number matters. Warning and critical readings use
    /// the filled-status foreground tokens so small text clears contrast in
    /// either appearance instead of relying on raw system orange/red.
    static func usageTint(_ level: FooterUsageChip.Level) -> Color {
        switch level {
        case .normal: .secondary
        case .warning: KaisolaStatusTone.needsYou.foregroundColor
        case .critical: KaisolaStatusTone.failed.foregroundColor
        }
    }

    private var accountSignInIsRunning: Bool {
        if case .signingIn = auth.phase { return true }
        return false
    }

    /// The account chip never gets narrower than its avatar plus a couple of
    /// characters; below that the name is not worth the width and the row's
    /// remaining controls matter more.
    ///
    /// This replaced a fixed `accountChipWidth` of 118pt. That constant — not
    /// the font, not the priority — is why "michael ofen…" stayed truncated no
    /// matter how wide the sidebar was dragged: the chip was framed to 118pt
    /// and then `fixedSize`d, so the extra points went to the spacer beside it.
    private static let accountChipMinimumWidth: CGFloat = 52

    private var accountName: String {
        guard let account = auth.account else { return "Kaisola" }
        return account.displayName ?? account.email
    }

    private var presentation: ConnectionFooterPresentation {
        ConnectionFooterPresentation(
            accountName: auth.account.map { $0.displayName ?? $0.email },
            appVersion: Self.appVersion
        )
    }

    /// What the compact chip draws; see `FooterAccountName`.
    private var displayedAccountName: String {
        FooterAccountName.displayed(accountName)
    }

    /// The tooltip leads with the whole name whenever the chip is showing less
    /// than all of it, so the first-name label is never the only copy on screen.
    private var accountHelp: String {
        let base = "Account and project settings"
        return displayedAccountName == accountName ? base : "\(accountName) — \(base)"
    }

    /// Everything the old shelf buttons did, minus the Files toggle (now a
    /// content-area control) and minus any persistent color.
    private var overflowMenu: some View {
        Menu {
            // The two panel toggles' permanent doors. Their visible controls are
            // hover-only at the content pane's top-right (v1.1.9 reclaimed the
            // 40pt band they used to sit in), so the menu is what a pointer that
            // never visits that corner — or a user driving by keyboard alone —
            // finds instead. Both, symmetrically: shipping one here and one on
            // screen is the asymmetry v1.1.6 already had to correct once.
            Button(action: toggleFilePreview) {
                Label(
                    filePreviewVisible ? "Hide File Preview" : "Show File Preview",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            Button(action: toggleFiles) {
                Label(
                    filesVisible ? "Hide Files" : "Show Files",
                    systemImage: "sidebar.trailing"
                )
            }
            if newMesh != nil || newStagedMesh != nil || newIdeaMesh != nil {
                Divider()
                if let newMesh { Button("New Mesh (All Agents)", action: newMesh) }
                if let newStagedMesh { Button("New Staged Mesh (Scout → Execute)", action: newStagedMesh) }
                if let newIdeaMesh { Button("New Idea Mesh (Brainstorm)", action: newIdeaMesh) }
            }
            Divider()
            if let cost = UsageCenter.costAccessibilityLabel(usage.costTotals) {
                Text(cost)
            }
            Button(action: showUsage) {
                Label("Usage…", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            Button(action: showSettings) {
                Label("Settings…", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.kaisolaPrimary)
                .frame(width: FooterAccountBudget.controlSlot, height: FooterAccountBudget.controlSlot)
                .contentShape(Rectangle().inset(by: -FooterAccountBudget.tapTargetExpansion))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More project actions")
        .accessibilityLabel("More project actions")
    }

    /// Identity, then the two doors, then recovery, then status — each in its
    /// own section.
    ///
    /// It used to be one flat list where the account name, the email, and five
    /// diagnostic lines were bare `Text` items. SwiftUI renders those as
    /// *disabled menu rows*, so the top of the menu looked like two commands
    /// that had been greyed out and the bottom like four more. Michael: "make
    /// this drop-up menu easier and more clear to read."
    ///
    /// Sections fix that at the root: a section header is typographically a
    /// caption rather than a dead command, so the version becomes a heading for
    /// the status beneath it and the account name a heading for the identity
    /// actions. Lines that say nothing are no longer said.
    /// Everything the menu used to print, on the clipboard instead.
    ///
    /// The version and available usage detail remain useful when reporting a
    /// problem. One item collects them in a form that can be pasted into an
    /// issue, which the menu rows never could.
    private func copyDiagnostics() {
        var lines = presentation.diagnosticLines
        if usage.totalPeakTokens > 0 {
            lines.append(
                "Usage: \(usage.totalPeakTokens / 1000)k tokens · "
                + "\(Int((usage.contextPressure * 100).rounded()))% context"
            )
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private var accountMenu: some View {
        Menu {
            ForEach(presentation.sections) { section in
                if let title = section.title {
                    Section(title) {
                        accountMenuRows(section.rows)
                    }
                } else {
                    Section {
                        accountMenuRows(section.rows)
                    }
                }
            }
        } label: {
            HStack(spacing: FooterAccountBudget.avatarGap) {
                // Placeholder for the avatar, which is drawn in the overlay
                // below; see the note there.
                Color.clear
                    .frame(width: FooterAccountBudget.avatarSize, height: FooterAccountBudget.avatarSize)
                Text(displayedAccountName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.kaisolaPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Sized by its contents, floored so a short name still leaves a
            // usable target, then laid leading inside whatever the footer has
            // left over. `contentShape` is applied BEFORE the stretch, so the
            // blank remainder of the footer is not a click target for the
            // account menu.
            .frame(minWidth: Self.accountChipMinimumWidth, alignment: .leading)
            .frame(height: 24)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `.button` rather than `.borderlessButton`: the borderless bridge
        // collapses an explicitly framed label down to the menu arrow's own
        // metrics, which shrank the whole chip to a few points of hit area.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Keep the asynchronously loaded photo outside AppKit's Menu label
        // bridge. The bridge otherwise promotes the source bitmap's intrinsic
        // dimensions and drops its SwiftUI mask when the image finishes loading.
        .overlay(alignment: .leading) {
            AccountAvatarView(account: auth.account, size: FooterAccountBudget.avatarSize)
                .allowsHitTesting(false)
        }
        .help(accountHelp)
        .accessibilityLabel("Kaisola account and settings")
    }

    @ViewBuilder
    private func accountMenuRows(_ rows: [ConnectionFooterPresentation.Row]) -> some View {
        ForEach(rows) { row in
            switch row {
            case let .action(action):
                Button {
                    performAccountMenuAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(action == .signInWithGoogle && accountSignInIsRunning)
            }
        }
    }

    private func performAccountMenuAction(_ action: ConnectionFooterPresentation.Action) {
        switch action {
        case .signInWithGoogle:
            Task { await auth.signInWithGoogle() }
        case .signOut:
            Task { await auth.signOut() }
        case .settings:
            showSettings()
        case .usage:
            showUsage()
        case .copyDiagnostics:
            copyDiagnostics()
        }
    }

    /// Inbox row glyphs. Exhaustive on purpose: a new `AttentionCenter.Kind`
    /// must fail the build here rather than silently inherit a checkmark.
    static func attentionSymbol(_ kind: AttentionCenter.Kind) -> String {
        switch kind {
        case .permission: "hand.raised.fill"
        // A BEL is the terminal asking for the user, not a completed turn, so
        // it keeps a bell rather than borrowing the permission hand.
        case .bell: "bell.fill"
        case .turnCompleted, .sessionResponded: "checkmark.circle.fill"
        }
    }

    /// Needs-you and finished use the same filled semantic vocabulary as the
    /// project badges, instead of raw system orange/green on unknown material.
    static func attentionTone(_ kind: AttentionCenter.Kind) -> KaisolaStatusTone {
        switch kind {
        case .permission, .bell: .needsYou
        case .turnCompleted, .sessionResponded: .done
        }
    }

    private var attentionButton: some View {
        // A storage problem keeps the bell lit on its own: the notice explaining
        // lost or unsaved work would otherwise have nowhere to live once the
        // inbox reads empty.
        let needsYou = attention.count > 0 || !attention.storageNotices.isEmpty
        return Button {
            showInbox = ConnectionFooterPresentation.attentionInboxIsPresented(
                afterActivating: showInbox
            )
        } label: {
            Image(systemName: needsYou ? "bell.badge.fill" : "bell")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(needsYou ? KaisolaStatusTone.needsYou.foregroundColor : Color.kaisolaPrimary)
                .frame(
                    width: FooterAccountBudget.controlSlot,
                    height: FooterAccountBudget.controlSlot
                )
                .contentShape(
                    Rectangle().inset(by: -FooterAccountBudget.tapTargetExpansion)
                )
        }
        .buttonStyle(.kaisolaChrome)
        .fixedSize()
        .help(
            attention.count > 0
                ? "Needs you — \(attention.count) permission asks and finished agents"
                : (needsYou ? "Saved inbox needs attention" : "Nothing needs you")
        )
        .accessibilityLabel(
            attention.count > 0
                ? "Attention inbox, \(attention.count) items"
                : (needsYou ? "Attention inbox, saved inbox needs attention" : "Attention inbox, empty")
        )
        .accessibilityIdentifier("footer.attention")
        .popover(isPresented: $showInbox, arrowEdge: .top) {
            attentionInbox
        }
        // Every path that empties the inbox — this popover, the Companion, a
        // notification click, focusing the surface — now closes the popover with
        // it, rather than leaving an anchored empty sheet behind.
        .onChange(of: needsYou) { _, stillNeeded in
            if !stillNeeded { showInbox = false }
        }
    }

    /// The all-agents inbox: grouped by project, filterable by kind, with
    /// gone-target rows dimmed to clear-only. Every session that needs you,
    /// across every project, in one place.
    private var attentionInbox: some View {
        let sections = AttentionInboxModel.sections(
            entries: attention.entries,
            kinds: inboxFilter,
            context: attentionContext ?? { _ in (nil, true) }
        )
        return VStack(alignment: .leading, spacing: 0) {
            attentionStorageNotices
            HStack(spacing: 6) {
                inboxFilterChip(label: "All", kinds: nil)
                ForEach(AttentionInboxModel.filterChips, id: \.label) { chip in
                    inboxFilterChip(label: chip.label, kinds: chip.kinds)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        if attentionContext != nil {
                            Text(section.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.kaisolaSecondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                        ForEach(section.rows) { row in
                            attentionRow(row)
                        }
                    }
                    if sections.isEmpty {
                        Text("Nothing needs you in this filter.")
                            .font(.caption)
                            .foregroundStyle(.kaisolaSecondary)
                            .padding(12)
                    }
                }
            }
            .frame(maxHeight: 360)
            Divider()
            Button("Clear All") { attention.clearAll(); showInbox = false }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(8)
        }
        .frame(width: 320)
        .padding(.vertical, 6)
    }

    /// What the saved inbox lost, or is failing to save, in the one place the
    /// user goes to read it. Reset is offered only when saving is actually
    /// blocked, because it throws the kept damaged copy away.
    @ViewBuilder
    private var attentionStorageNotices: some View {
        if !attention.storageNotices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(attention.storageNotices) { notice in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(notice.title).font(.caption.weight(.semibold))
                        Text(notice.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 10) {
                    if attention.storageNotices.contains(where: \.blocksSaving) {
                        Button("Reset Saved Inbox") { attention.resetStorage() }
                            .buttonStyle(.borderless)
                    }
                    Button("Dismiss") { attention.dismissStorageNotices() }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("footer.attention.storageNotice")
            Divider()
                .padding(.bottom, 6)
        }
    }

    private func inboxFilterChip(label: String, kinds: Set<AttentionCenter.Kind>?) -> some View {
        let selected = inboxFilter == kinds
        return Button(label) { inboxFilter = kinds }
            .buttonStyle(.borderless)
            .font(.caption2.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.accentColor : Color.kaisolaSecondary)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func attentionRow(_ row: AttentionInboxModel.Row) -> some View {
        if row.targetExists {
            Button {
                showInbox = false
                jumpToAttention?(row.entry.targetID)
            } label: {
                attentionRowLabel(row)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        } else {
            // The surface is gone: jumping would land on "session
            // unavailable", so the row dims and offers only its own removal.
            HStack(spacing: 8) {
                attentionRowLabel(row)
                    .opacity(0.55)
                Button {
                    attention.clear(targetID: row.entry.targetID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.kaisolaSecondary)
                }
                .buttonStyle(.plain)
                .help("This session is gone; clear the entry")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private func attentionRowLabel(_ row: AttentionInboxModel.Row) -> some View {
        HStack(spacing: 8) {
            KaisolaStatusGlyph(
                systemImage: Self.attentionSymbol(row.entry.kind),
                tone: Self.attentionTone(row.entry.kind)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(row.entry.title).font(.callout).lineLimit(1)
                Text(row.entry.detail).font(.caption).foregroundStyle(.kaisolaSecondary).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
