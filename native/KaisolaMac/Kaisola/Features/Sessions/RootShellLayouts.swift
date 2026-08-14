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
enum RootShellRenderContract {
    static func regions(for layout: NavigationLayout) -> [RootShellRenderRegion] {
        switch layout {
        case .leftTree:
            [.projects, .workspace, .footer]
        case .topBar:
            [.projects, .quickActions, .sessions, .workspace, .footer]
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

/// The project-tab presentation. Its five regions are injected independently
/// so workspace content remains in RootShellView while the layout can be
/// rendered and regression-tested in isolation.
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
