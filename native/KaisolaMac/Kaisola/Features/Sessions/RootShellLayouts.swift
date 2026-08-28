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
/// 2026-08-28 revision: the top-bar layout's project strip and session strip
/// merged into one 40pt bar, so `.projects` and `.sessions` are now the two
/// halves of a single band, and the persistent Quick Actions row is gone
/// (saved Quick Actions keep their project context menus and the command
/// palette).
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

/// The session-tab presentation. Its regions are injected independently so
/// workspace content remains in RootShellView while the layout can be
/// rendered and regression-tested in isolation.
///
/// 2026-08-28 revision, decision 2: the stacked project strip and session
/// strip merged into ONE bar. `bar` receives the whole band — compact project
/// switcher leading, the active project's session tabs inline, New Session
/// and the trailing controls at the end — and the shell no longer draws
/// hairline dividers around it: the tabs sit directly on the window glass and
/// the detail chrome card's own gutter separates the content below.
struct RootTopBarShell<Bar: View, Detail: View, Footer: View>: View {
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
