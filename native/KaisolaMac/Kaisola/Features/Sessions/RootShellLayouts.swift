import AppKit
import SwiftUI

/// Presentation geometry only. Stored pane identities and resize weights
/// remain the source of truth when a window becomes wide enough again.
enum SessionPaneAdaptiveSizing {
    enum Mode: Equatable { case columns, stacked, focused }
    static let minimumWidth: CGFloat = 220
    static let minimumHeight: CGFloat = 150

    static func mode(size: CGSize, rowCounts: [Int], divider: CGFloat) -> Mode {
        guard !rowCounts.isEmpty else { return .focused }
        let columnHeights = rowCounts.map { rowMinimum(count: $0, divider: divider) }
        let columnDividers = CGFloat(max(0, rowCounts.count - 1)) * divider
        if size.width >= CGFloat(rowCounts.count) * minimumWidth + columnDividers,
           size.height >= (columnHeights.max() ?? minimumHeight) {
            return .columns
        }
        if size.width >= minimumWidth,
           size.height >= columnHeights.reduce(0, +) + columnDividers {
            return .stacked
        }
        return .focused
    }

    static func rowMinimum(count: Int, divider: CGFloat) -> CGFloat {
        CGFloat(max(1, count)) * minimumHeight + CGFloat(max(0, count - 1)) * divider
    }

    static func resizeDelta(
        points: CGFloat, leadingExtent: CGFloat, trailingExtent: CGFloat,
        leadingWeight: Double, trailingWeight: Double,
        leadingMinimum: CGFloat, trailingMinimum: CGFloat
    ) -> Double {
        let pairExtent = leadingExtent + trailingExtent
        guard pairExtent >= leadingMinimum + trailingMinimum, pairExtent > 0 else { return 0 }
        let target = min(pairExtent - trailingMinimum, max(leadingMinimum, leadingExtent + points))
        return Double(target / pairExtent) * (leadingWeight + trailingWeight) - leadingWeight
    }

    static func extents(available: CGFloat, weights: [Double], minima: [CGFloat]) -> [CGFloat] {
        guard !weights.isEmpty, weights.count == minima.count else { return [] }
        let budget = max(0, available)
        let minimumTotal = minima.reduce(0, +)
        if budget <= minimumTotal {
            return minima.map { minimumTotal > 0 ? budget * $0 / minimumTotal : 0 }
        }
        let normalized = weights.map { $0.isFinite ? max(0.01, $0) : 1 }
        var pending = Array(weights.indices)
        var remaining = budget
        var result = Array(repeating: CGFloat.zero, count: weights.count)
        while !pending.isEmpty {
            let totalWeight = pending.reduce(0.0) { $0 + normalized[$1] }
            let constrained = pending.filter {
                remaining * CGFloat(normalized[$0] / totalWeight) < minima[$0]
            }
            if constrained.isEmpty {
                for index in pending {
                    result[index] = remaining * CGFloat(normalized[index] / totalWeight)
                }
                break
            }
            for index in constrained {
                result[index] = minima[index]
                remaining -= minima[index]
            }
            let fixed = Set(constrained)
            pending.removeAll { fixed.contains($0) }
        }
        return result
    }
}

/// Remembers the editing control beneath a temporary command overlay without
/// retaining the view, its window, or a terminal session.
@MainActor
final class CommandOverlayFocusState {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    private var textSelection: NSRange?

    func capture(in window: NSWindow) {
        self.window = window
        textSelection = (window.firstResponder as? NSTextView)?.selectedRange()
        if let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor,
           let control = editor.delegate as? NSResponder {
            responder = control
        } else {
            responder = window.firstResponder
        }
    }

    func restoreIfUnclaimed() {
        defer {
            window = nil
            responder = nil
            textSelection = nil
        }
        guard let window, let responder, window.attachedSheet == nil else { return }
        let currentResponder: NSResponder?
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            currentResponder = editor.delegate as? NSResponder
        } else {
            currentResponder = window.firstResponder
        }
        let originalControlIsFocused = currentResponder === responder
        guard originalControlIsFocused || currentResponder == nil || currentResponder === window else { return }
        if let view = responder as? NSView, view.window !== window { return }
        guard originalControlIsFocused || window.makeFirstResponder(responder) else { return }
        // AppKit selects all of a text field when focus returns. Restore the
        // user's caret or selection, including when SwiftUI refocused the
        // original field before this deferred restoration ran.
        if let textSelection, textSelection.location != NSNotFound,
           let editor = window.firstResponder as? NSTextView {
            let length = (editor.string as NSString).length
            let location = min(textSelection.location, length)
            editor.setSelectedRange(NSRange(
                location: location,
                length: min(textSelection.length, length - location)
            ))
        }
    }
}

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
    /// Match the workspace identity row and its comfortable pointer targets.
    static var barHeight: CGFloat { NativeWorkspaceChrome.sessionHeaderHeight }

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
