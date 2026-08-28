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
    case sessions
    case workspace
    case footer
}

/// A small, explicit contract for the regions each navigation shell renders.
/// The view tests exercise these alongside an actual SwiftUI render, which
/// keeps a future extraction from silently dropping a layout-only surface.
///
/// Graduated 2026-08-28: the shell revision Michael previewed and confirmed
/// is THE shell. Left tree is the default; the top-bar mode survives as the
/// merged 40pt bar — `.projects` and `.sessions` are the two halves of that
/// single band, and the legacy five-region stack (persistent Quick Actions
/// row included) is gone. Saved Quick Actions keep their project context
/// menus and the command palette.
enum RootShellRenderContract {
    static func regions(for layout: NavigationLayout) -> [RootShellRenderRegion] {
        switch layout {
        case .leftTree:
            [.projects, .workspace, .footer]
        case .topBar:
            [.projects, .sessions, .workspace, .footer]
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

/// The top-bar presentation: ONE merged session-tab bar over the detail pane.
/// Compact project switcher leading, the active project's session tabs inline,
/// New Session and the trailing controls at the end. The shell draws no
/// hairline dividers around the band — the tabs sit directly on the window
/// glass and the workspace below is flush.
struct RootMergedTopBarShell<Bar: View, Detail: View, Footer: View>: View {
    /// The single bar's height. The old 36pt session strip moved to 40 so the
    /// tabs breathe.
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
