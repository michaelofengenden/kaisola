import SwiftUI

/// The navigation shells do not own application state. RootShellView injects
/// one action model into either presentation, so switching layouts cannot grow
/// a second copy of session, project, or quick-action behavior.
struct RootShellActionModel {
    let openDroppedProjects: ([URL]) -> Bool
    let beginNewSession: (AppModel.ProjectGroup) -> Void
    let selectRealSurface: () -> Void
    let useLeftTreeNavigation: () -> Void
    let moveProject: (String, Int) -> Void
    let runQuickAction: (QuickAction, URL) -> Void
    let selectSession: (BrokerTerminalRecord) -> Void
    let projectContextMenu: (AppModel.ProjectGroup) -> AnyView
    let sessionContextMenu: (BrokerTerminalRecord) -> AnyView
    let chatContextMenu: (AcpChatHandle) -> AnyView
    let meshContextMenu: (MeshSession) -> AnyView
    let renameSurface: (String) -> Void
    let closeChat: (AcpChatHandle) -> Void
    let deleteChat: (AcpChatHandle) -> Void
    let closeMesh: (MeshSession) -> Void
    let deleteMesh: (MeshSession) -> Void
    let deleteRecentlyClosed: (AppModel.RecentlyClosedSurface) -> Void
}

enum RootShellRenderRegion: String, Equatable {
    case projects
    case quickActions
    case sessions
    case workspace
    case footer
}

/// A small, explicit contract for the regions each navigation shell renders.
/// The view tests exercise these alongside an actual SwiftUI render, which
/// keeps a future extraction from silently dropping a layout-only surface.
///
/// 2026-08-28 revision, now preview-gated: with the shell preview ON the
/// top-bar layout's project strip and session strip merge into one 40pt bar —
/// `.projects` and `.sessions` become the two halves of a single band, and
/// the persistent Quick Actions row is gone (saved Quick Actions keep their
/// project context menus and the command palette). With the preview OFF the
/// contract is exactly the shipped five-region stack.
enum RootShellRenderContract {
    static func regions(
        for layout: NavigationLayout,
        preview: ShellPreviewVariant
    ) -> [RootShellRenderRegion] {
        switch layout {
        case .leftTree:
            [.projects, .workspace, .footer]
        case .topBar:
            preview.isOn
                ? [.projects, .sessions, .workspace, .footer]
                : [.projects, .quickActions, .sessions, .workspace, .footer]
        }
    }
}

/// The merged bar's internal arrangement, pinned as data so the tests and the
/// render cannot drift apart: `RootShellView` builds the bar by iterating
/// `slots`. Michael's 2026-08-28 feedback — "condensed, the buttons are all
/// spread out" — fixed here structurally: the switcher leads, the tabs pack
/// immediately beside it at fixed Safari-ish gaps, the bar's ONE flexible gap
/// comes after the tabs, and the trailing cluster stays tight at the far end.
/// Tabs keep their intrinsic width and never spread to fill a wide bar; when
/// the bar is genuinely full they compress through the existing truncation
/// policy instead.
enum MergedTopBarGrammar {
    enum Slot: Hashable {
        case projectSwitcher
        case sessionTabs
        case flexibleSpace
        case trailingControls
    }

    static let slots: [Slot] = [.projectSwitcher, .sessionTabs, .flexibleSpace, .trailingControls]

    /// The bar stack owns no spacing of its own; every gap belongs to a slot,
    /// so nothing can silently double up.
    static let barSpacing: CGFloat = 0
    /// Between the switcher and the first tab, and between tab hit areas.
    static let tabGap: CGFloat = 8
    /// The trailing cluster's clearance from the window edge.
    static let trailingInset: CGFloat = 10
}

/// The card-rail treatment of the 2026-08-28 revision, preview-gated. On:
/// the rail floats on the shared `kaisolaChromePanel` chrome card (decisions
/// 1 and 6). Off: exactly the shipped treatment — the project sidebar keeps
/// its bare traffic-light top padding (`padsTopWhenOff`) and the Files rail
/// mounts flush with no panel at all.
struct ShellPreviewRailPanel: ViewModifier {
    @Environment(\.shellPreview) private var shellPreview

    let topInset: CGFloat
    var padsTopWhenOff = false

    func body(content: Content) -> some View {
        if shellPreview.isOn {
            content.kaisolaChromePanel(topInset: topInset)
        } else if padsTopWhenOff {
            content.padding(.top, topInset)
        } else {
            content
        }
    }
}

/// The source-list presentation. RootShellView supplies the project rail and
/// workspace content; this view owns the navigation split and receives the
/// same action model as the top-bar shell.
struct RootLeftTreeShell<Sidebar: View, Detail: View>: View {
    let actions: RootShellActionModel
    @Binding private var columnVisibility: NavigationSplitViewVisibility
    private let sidebar: (RootShellActionModel) -> Sidebar
    private let detail: (RootShellActionModel) -> Detail

    init(
        actions: RootShellActionModel,
        columnVisibility: Binding<NavigationSplitViewVisibility> = .constant(.all),
        @ViewBuilder sidebar: @escaping (RootShellActionModel) -> Sidebar,
        @ViewBuilder detail: @escaping (RootShellActionModel) -> Detail
    ) {
        self.actions = actions
        self._columnVisibility = columnVisibility
        self.sidebar = sidebar
        self.detail = detail
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar(actions)
        } detail: {
            detail(actions)
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("root-shell-left-tree")
    }
}

/// The shipped project-tab presentation — what renders while the shell
/// preview is off. Its five regions are injected independently so workspace
/// content remains in RootShellView while the layout can be rendered and
/// regression-tested in isolation.
struct RootTopBarShell<Projects: View, QuickActions: View, Sessions: View, Detail: View, Footer: View>: View {
    let actions: RootShellActionModel
    private let projects: (RootShellActionModel) -> Projects
    private let quickActions: (RootShellActionModel) -> QuickActions
    private let sessions: (RootShellActionModel) -> Sessions
    private let detail: (RootShellActionModel) -> Detail
    private let footer: (RootShellActionModel) -> Footer

    init(
        actions: RootShellActionModel,
        @ViewBuilder projects: @escaping (RootShellActionModel) -> Projects,
        @ViewBuilder quickActions: @escaping (RootShellActionModel) -> QuickActions,
        @ViewBuilder sessions: @escaping (RootShellActionModel) -> Sessions,
        @ViewBuilder detail: @escaping (RootShellActionModel) -> Detail,
        @ViewBuilder footer: @escaping (RootShellActionModel) -> Footer
    ) {
        self.actions = actions
        self.projects = projects
        self.quickActions = quickActions
        self.sessions = sessions
        self.detail = detail
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            projects(actions)
            Divider()
            quickActions(actions)
            sessions(actions)
            Divider()
            detail(actions)
            HStack(spacing: 0) {
                footer(actions).frame(width: 235)
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("root-shell-top-bar")
    }
}

/// The previewed session-tab presentation (2026-08-28 revision, decision 2):
/// the stacked project strip and session strip merged into ONE bar. `bar`
/// receives the whole band — compact project switcher leading, the active
/// project's session tabs inline, New Session and the trailing controls at
/// the end — and the shell no longer draws hairline dividers around it: the
/// tabs sit directly on the window glass and the detail chrome card's own
/// gutter separates the content below. Mounted only while the shell preview
/// is on; the two shells never coexist, so both carry the same accessibility
/// identifier.
struct RootMergedTopBarShell<Bar: View, Detail: View, Footer: View>: View {
    /// The single bar's height. The old 36pt session strip moves to 40 so the
    /// tabs breathe (revision decision 3).
    static var barHeight: CGFloat { 40 }

    let actions: RootShellActionModel
    private let bar: (RootShellActionModel) -> Bar
    private let detail: (RootShellActionModel) -> Detail
    private let footer: (RootShellActionModel) -> Footer

    init(
        actions: RootShellActionModel,
        @ViewBuilder bar: @escaping (RootShellActionModel) -> Bar,
        @ViewBuilder detail: @escaping (RootShellActionModel) -> Detail,
        @ViewBuilder footer: @escaping (RootShellActionModel) -> Footer
    ) {
        self.actions = actions
        self.bar = bar
        self.detail = detail
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            bar(actions)
                .frame(height: Self.barHeight)
            detail(actions)
            HStack(spacing: 0) {
                footer(actions).frame(width: 235)
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("root-shell-top-bar")
    }
}
