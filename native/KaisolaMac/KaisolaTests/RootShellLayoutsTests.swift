import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Kaisola

@MainActor
final class RootShellLayoutsTests: XCTestCase {
    func testNarrowSessionColumnsStackWithoutChangingTheirStoredLayout() {
        XCTAssertEqual(SessionPaneAdaptiveSizing.mode(
            size: CGSize(width: 312, height: 500), rowCounts: [1, 1], divider: 1
        ), .stacked)
        XCTAssertEqual(SessionPaneAdaptiveSizing.mode(
            size: CGSize(width: 312, height: 500), rowCounts: [2, 1], divider: 1
        ), .stacked)
        XCTAssertEqual(SessionPaneAdaptiveSizing.mode(
            size: CGSize(width: 800, height: 500), rowCounts: [2, 1], divider: 1
        ), .columns)
    }

    func testOversubscribedSessionGridKeepsTheFocusedPaneUsable() {
        XCTAssertEqual(SessionPaneAdaptiveSizing.mode(
            size: CGSize(width: 312, height: 500), rowCounts: [2, 2], divider: 1
        ), .focused)
        XCTAssertEqual(SessionPaneAdaptiveSizing.mode(
            size: CGSize(width: 800, height: 250), rowCounts: [2, 1], divider: 1
        ), .focused)
    }

    func testPaneAllocationPreservesUsableMinimaAndAvailableExtent() {
        let widths = SessionPaneAdaptiveSizing.extents(
            available: 700, weights: [99, 1], minima: [220, 220]
        )
        XCTAssertEqual(widths, [480, 220])
        let heights = SessionPaneAdaptiveSizing.extents(
            available: 499, weights: [1, 1], minima: [301, 150]
        )
        XCTAssertEqual(heights, [301, 198])
        XCTAssertEqual(SessionPaneAdaptiveSizing.extents(
            available: 900, weights: [2, 1], minima: [220, 220]
        ), [600, 300])
    }

    func testPaneResizeTracksRenderedExtentsAndDistinctAdjacentMinima() {
        for (movement, expected) in [(CGFloat(-20), [CGFloat(301), 198]), (CGFloat(20), [CGFloat(321), 178])] {
            let delta = SessionPaneAdaptiveSizing.resizeDelta(
                points: movement, leadingExtent: 301, trailingExtent: 198,
                leadingWeight: 1, trailingWeight: 1, leadingMinimum: 301, trailingMinimum: 150
            )
            let extents = SessionPaneAdaptiveSizing.extents(
                available: 499, weights: [1 + delta, 1 - delta], minima: [301, 150]
            )
            XCTAssertEqual(extents[0], expected[0], accuracy: 0.001)
            XCTAssertEqual(extents[1], expected[1], accuracy: 0.001)
        }
        let delta = SessionPaneAdaptiveSizing.resizeDelta(
            points: -10, leadingExtent: 480, trailingExtent: 220,
            leadingWeight: 99, trailingWeight: 1, leadingMinimum: 220, trailingMinimum: 220
        )
        let extents = SessionPaneAdaptiveSizing.extents(
            available: 700, weights: [99 + delta, 1 - delta], minima: [220, 220]
        )
        XCTAssertEqual(extents[0], 470, accuracy: 0.001)
        XCTAssertEqual(extents[1], 230, accuracy: 0.001)
    }

    func testClosingCommandOverlayRestoresTheOriginalEditingControl() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { NativeHostedTestWindows.keep(window) }
        let source = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        source.stringValue = "Draft stays here"
        let search = NSTextField(frame: NSRect(x: 20, y: 80, width: 240, height: 24))
        window.contentView?.addSubview(source)
        window.contentView?.addSubview(search)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(source))
        let originalEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let insertionPoint = NSRange(location: source.stringValue.utf16.count, length: 0)
        originalEditor.setSelectedRange(insertionPoint)
        let focus = CommandOverlayFocusState()
        focus.capture(in: window)
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertTrue(window.makeFirstResponder(nil))

        focus.restoreIfUnclaimed()

        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate as? NSTextField === source)
        XCTAssertEqual(editor.selectedRange(), insertionPoint)
    }

    func testClosingCommandOverlayDoesNotStealACommandDestinationsFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { NativeHostedTestWindows.keep(window) }
        let source = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        let destination = NSTextField(frame: NSRect(x: 20, y: 80, width: 240, height: 24))
        window.contentView?.addSubview(source)
        window.contentView?.addSubview(destination)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(source))
        let focus = CommandOverlayFocusState()
        focus.capture(in: window)
        XCTAssertTrue(window.makeFirstResponder(destination))

        focus.restoreIfUnclaimed()

        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.delegate as? NSTextField === destination)
    }

    func testClosingCommandOverlayPreservesSelectionAfterAutomaticRefocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { NativeHostedTestWindows.keep(window) }
        let source = NSTextField(frame: NSRect(x: 20, y: 20, width: 240, height: 24))
        source.stringValue = "Draft stays here"
        let search = NSTextField(frame: NSRect(x: 20, y: 80, width: 240, height: 24))
        window.contentView?.addSubview(source)
        window.contentView?.addSubview(search)
        XCTAssertTrue(window.makeFirstResponder(source))
        let selection = NSRange(location: 6, length: 5)
        try XCTUnwrap(window.firstResponder as? NSTextView).setSelectedRange(selection)
        let focus = CommandOverlayFocusState()
        focus.capture(in: window)
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertTrue(window.makeFirstResponder(source))

        focus.restoreIfUnclaimed()

        XCTAssertEqual(try XCTUnwrap(window.firstResponder as? NSTextView).selectedRange(), selection)
    }

    // MARK: - Graduated shell contract

    func testLeftTreeShellRendersProjectsWorkspaceAndFooter() throws {
        XCTAssertEqual(
            RootShellRenderContract.regions(for: .leftTree),
            [.projects, .workspace, .footer]
        )

        let image = try renderRootShell(
            RootLeftTreeShell(actions: inertRootShellActions()) { _ in
                VStack {
                    Text("Projects")
                    Text("Footer")
                }
            } detail: { _ in
                Text("Workspace")
            }
        )

        XCTAssertEqual(image.size, NSSize(width: 720, height: 480))
        XCTAssertGreaterThan(image.tiffRepresentation?.count ?? 0, 1_000)
    }

    func testTopBarShellIsTheMergedCondensedBar() throws {
        // Graduation, 2026-08-28: the merged 40pt bar IS the top-bar mode.
        // The legacy five-region stack (project strip, Quick Actions row,
        // session strip) is deleted, so `.projects` and `.sessions` are the
        // two halves of the one band.
        XCTAssertEqual(
            RootShellRenderContract.regions(for: .topBar),
            [.projects, .sessions, .workspace, .footer]
        )

        let image = try renderRootShell(
            RootMergedTopBarShell(actions: inertRootShellActions()) { _ in
                Text("Bar")
            } detail: { _ in
                Text("Workspace")
            } footer: { _ in
                Text("Footer")
            }
        )

        XCTAssertEqual(image.size, NSSize(width: 720, height: 480))
        XCTAssertGreaterThan(image.tiffRepresentation?.count ?? 0, 1_000)
    }

    func testMergedBarPacksTabsAfterTheSwitcherWithOneFlexibleGapBeforeTheTrailingCluster() {
        // Michael, 2026-08-28: "the top bars of session tabs needs to be
        // fixed, and condensed, the buttons are all spread out." The bar is
        // switcher → tabs → the ONLY flexible gap → trailing cluster, so tabs
        // pack leading at fixed Safari-ish gaps and never spread to fill.
        XCTAssertEqual(
            MergedTopBarGrammar.slots,
            [.projectSwitcher, .sessionTabs, .flexibleSpace, .trailingControls]
        )
        XCTAssertEqual(
            MergedTopBarGrammar.slots.filter { $0 == .flexibleSpace }.count,
            1,
            "exactly one flexible gap, and it sits after the tabs"
        )
        XCTAssertEqual(MergedTopBarGrammar.barSpacing, 0, "every gap is owned by a slot, none by the stack")
        XCTAssertEqual(MergedTopBarGrammar.tabGap, 8)
    }

    func testQuietRailFillsOnlyTheSelectedRow() {
        // Michael, 2026-08-28: "I'd like there'd not to be a double card
        // situation for the lhs rail." Resting rows — split companions
        // included — draw no fill; only the selected row wears the pill, and
        // hover answers with the faint wash.
        XCTAssertEqual(
            QuietSelectionPill.fill(isSelected: true, isOnScreen: true, hovering: false),
            .selectionPill
        )
        XCTAssertEqual(
            QuietSelectionPill.fill(isSelected: true, isOnScreen: false, hovering: true),
            .selectionPill,
            "selection outranks hover"
        )
        XCTAssertEqual(
            QuietSelectionPill.fill(isSelected: false, isOnScreen: true, hovering: false),
            QuietRowFill.none,
            "an on-screen companion row rests quiet inside the rail"
        )
        XCTAssertEqual(
            QuietSelectionPill.fill(isSelected: false, isOnScreen: true, hovering: true),
            .hoverWash
        )
        XCTAssertEqual(
            QuietSelectionPill.fill(isSelected: false, isOnScreen: false, hovering: false),
            QuietRowFill.none
        )
    }

    func testTheWindowCornerIsTheShellRadiusUnconditionally() {
        // The 30pt real window corner graduated with the shell: no
        // preview gate, no zero state.
        XCTAssertEqual(ShellWindowChrome.cornerRadius, KaisolaVisualSystem.shellRadius)
        XCTAssertEqual(ShellWindowChrome.cornerRadius, 30)
    }

    func testTheWorkspaceIsFlushInBothLayouts() {
        // Edge to edge: no chrome-card gutter above the content in either
        // layout; the window corner is the only clip.
        XCTAssertEqual(NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar), 0)
        XCTAssertEqual(NativeWorkspaceChrome.detailPanelTopInset(layout: .leftTree), 0)
    }

    // MARK: - Navigation-layout default and persistence

    func testFreshInstallDefaultsToTheLeftTreeRailAndIgnoresTheRetiredPreviewKey() throws {
        let suite = "kaisola-tests.shell-graduation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // A preview-era install may still carry the retired key; it must be
        // ignored rather than migrated or crashed on.
        defaults.set("capsules", forKey: "shellPreviewVariant")

        let fresh = NativePreviewSettings(defaults: defaults, persistsChanges: true)
        XCTAssertEqual(fresh.navigationLayout, .leftTree, "left tree is the graduated default")

        // An explicitly persisted layout choice is preserved — only the
        // fallback default changed.
        defaults.set("topBar", forKey: "navigationLayout")
        let chosen = NativePreviewSettings(defaults: defaults, persistsChanges: true)
        XCTAssertEqual(chosen.navigationLayout, .topBar)

        defaults.set("ribbonBar", forKey: "navigationLayout")
        let junk = NativePreviewSettings(defaults: defaults, persistsChanges: true)
        XCTAssertEqual(junk.navigationLayout, .leftTree, "an unknown stored layout falls back to the default")
    }

    // MARK: - The v0.1.146 crash fix: structural switches defer

    func testNavigationLayoutRequestNeverAppliesOnTheRequestingStack() throws {
        // Crash signature (v0.1.146): objc_loadWeak ←
        // -[NSSplitView _beginInteractivePeekAtInitialLocation:] ← mouseDown —
        // a same-stack shell swap tearing the split view down inside AppKit's
        // event-tracking pass. The fix is that a layout request must apply on
        // a LATER default-mode run-loop turn, never synchronously.
        let suite = "kaisola-tests.layout-defer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NativePreviewSettings(defaults: defaults, persistsChanges: true)

        XCTAssertEqual(settings.navigationLayout, .leftTree)
        settings.requestNavigationLayout(.topBar)
        XCTAssertEqual(
            settings.navigationLayout,
            .leftTree,
            "same-stack application is exactly the NSSplitView divider crash"
        )

        spinRunLoop(until: { settings.navigationLayout == .topBar })
        XCTAssertEqual(settings.navigationLayout, .topBar)
        XCTAssertEqual(
            defaults.string(forKey: "navigationLayout"),
            "topBar",
            "the deferred application still persists the choice"
        )
    }

    func testBurstsOfLayoutRequestsCoalesceToTheLastOne() throws {
        let suite = "kaisola-tests.layout-coalesce.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NativePreviewSettings(defaults: defaults, persistsChanges: true)
        var applied: [NavigationLayout] = []
        let cancellable = settings.$navigationLayout.dropFirst().sink { applied.append($0) }
        defer { cancellable.cancel() }

        settings.requestNavigationLayout(.topBar)
        settings.requestNavigationLayout(.leftTree)
        settings.requestNavigationLayout(.topBar)

        spinRunLoop(until: { settings.navigationLayout == .topBar })
        XCTAssertEqual(
            applied,
            [.topBar],
            "one structural swap for a burst of requests, landing on the last"
        )
    }

    func testBootstrapNavigationLayoutIsSynchronousForLaunchTimeFixtureSetup() throws {
        let suite = "kaisola-tests.layout-bootstrap.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NativePreviewSettings(defaults: defaults, persistsChanges: true)

        settings.bootstrapNavigationLayout(.topBar)
        XCTAssertEqual(settings.navigationLayout, .topBar)
    }

    func testSettingsTakeoverPolicyTogglesOnTheDoorAndAlwaysRestoresOnBackAndEscape() {
        // The takeover uses the same deferred structural-switch discipline;
        // this pins its state table. The gear (and ⌘,) toggles; Back to app
        // and Esc always restore; a deep link always lands open.
        XCTAssertTrue(SettingsTakeoverPolicy.isPresented(after: .pressSettingsDoor, from: false))
        XCTAssertFalse(
            SettingsTakeoverPolicy.isPresented(after: .pressSettingsDoor, from: true),
            "pressing the gear again restores the workspace"
        )
        XCTAssertFalse(SettingsTakeoverPolicy.isPresented(after: .backToApp, from: true))
        XCTAssertFalse(SettingsTakeoverPolicy.isPresented(after: .escape, from: true))
        XCTAssertTrue(SettingsTakeoverPolicy.isPresented(after: .openSection, from: false))
        XCTAssertTrue(SettingsTakeoverPolicy.isPresented(after: .openSection, from: true))
    }

    func testBareOpenSettingsSurfacePostIsADoorWhileASectionDeepLinks() {
        // `kaisolaOpenSettingsSurface` is posted both by ⌘, / the bare menu
        // item and by deep links that name a section. Only the latter carries
        // a section identifier, and only the former may toggle: with the
        // takeover covering the footer gear, ⌘, is the way back out.
        XCTAssertEqual(
            SettingsTakeoverPolicy.action(forOpenSettingsSurfaceSection: nil),
            .pressSettingsDoor
        )
        XCTAssertEqual(
            SettingsTakeoverPolicy.action(forOpenSettingsSurfaceSection: "providers"),
            .openSection
        )
        XCTAssertFalse(
            SettingsTakeoverPolicy.isPresented(
                after: SettingsTakeoverPolicy.action(forOpenSettingsSurfaceSection: nil),
                from: true
            ),
            "⌘, with the takeover already up restores the workspace"
        )
    }

    // MARK: - Pane header declutter (2026-08-28)

    func testChatHeaderDropsTheMaximizeArrowAndAccountButtonsIntoOneTightCluster() {
        let chat = UnifiedSessionHeaderGrammar.trailingControls(
            isChat: true,
            isMesh: false,
            isTerminal: false,
            hostsDetailDoors: true
        )
        XCTAssertEqual(
            chat,
            [.chatOverflow, .detailDoors],
            "session actions share one menu while the panel toggles stay directly available"
        )

        let terminal = UnifiedSessionHeaderGrammar.trailingControls(
            isChat: false,
            isMesh: false,
            isTerminal: true,
            hostsDetailDoors: false
        )
        XCTAssertEqual(terminal, [.terminalOverflow])

        let mesh = UnifiedSessionHeaderGrammar.trailingControls(
            isChat: false,
            isMesh: true,
            isTerminal: false,
            hostsDetailDoors: false
        )
        XCTAssertEqual(mesh, [.meshQueue, .meshConfiguration, .hide])
        XCTAssertEqual(UnifiedSessionHeaderGrammar.clusterSpacing, 2, "one tight cluster, not a spread")
    }

    func testTheRemovedMaximizeActionLivesInThePaneContextMenu() {
        // Old spec's action-inventory rule: an action loses its button only
        // if it keeps a home.
        XCTAssertTrue(
            UnifiedSessionHeaderGrammar.contextActions(isTerminal: false)
                .contains(.toggleMaximize)
        )
        XCTAssertEqual(
            UnifiedSessionHeaderGrammar.contextActions(isTerminal: true),
            [.rename, .openTranscript, .moveToProject, .toggleMaximize, .hide]
        )
    }

    /// "The default rail width should also be the default when double-clicking
    /// the panel divider" (2026-08-28). It is — both read
    /// `projectSidebarIdealWidth` — and this is what stops them drifting into
    /// two literals that answer the question differently.
    ///
    /// The divider's own `mouseDown` sets that constant and then clears the
    /// persisted drag, so the width the reset lands on and the width a fresh
    /// window opens at have to be the same number by construction rather than
    /// by coincidence.
    func testDoubleClickResetAndTheOpeningDefaultAreTheSameWidth() {
        let opening = NativeWorkspaceChrome.resolvedProjectRailIdealWidth(
            storedWidth: NativePreviewSettings.projectRailWidthUnset
        )
        XCTAssertEqual(
            opening,
            NativeWorkspaceChrome.projectSidebarIdealWidth,
            "clearing the drag is what a double-click does, so it must resolve to the default"
        )
        XCTAssertEqual(opening, 244)

        // A width the user dragged still outranks the default when the window
        // reopens — the reset is the only thing that discards it.
        XCTAssertEqual(
            NativeWorkspaceChrome.resolvedProjectRailIdealWidth(storedWidth: 268),
            268
        )
    }

    // MARK: - Retained shell behaviors

    func testCollapsedSidebarMovesSessionIdentityPastWindowControls() {
        XCTAssertEqual(
            UnifiedSessionHeaderLayout.leadingInset(
                navigationLayout: .leftTree,
                columnVisibility: .all,
                isWindowLeadingPane: true
            ),
            10
        )
        XCTAssertGreaterThanOrEqual(
            UnifiedSessionHeaderLayout.leadingInset(
                navigationLayout: .leftTree,
                columnVisibility: .detailOnly,
                isWindowLeadingPane: true
            ),
            150,
            "the title must clear both the traffic lights and native sidebar button"
        )
        XCTAssertEqual(
            UnifiedSessionHeaderLayout.leadingInset(
                navigationLayout: .leftTree,
                columnVisibility: .detailOnly,
                isWindowLeadingPane: false
            ),
            10,
            "only the pane whose header owns the window corner needs titlebar clearance"
        )
        XCTAssertEqual(
            UnifiedSessionHeaderLayout.leadingInset(
                navigationLayout: .topBar,
                columnVisibility: .detailOnly,
                isWindowLeadingPane: true
            ),
            10,
            "top-bar navigation already reserves its own traffic-light lane"
        )
    }

    func testRestorationNoticeReservesSpaceOnlyWhenItsObservedChildHasContent() {
        XCTAssertFalse(
            WorkspaceRestorationNoticeView.reservesLayoutSpace(
                hasWorkspaceNotice: false,
                hasProjectAccountIssue: false
            )
        )
        XCTAssertTrue(
            WorkspaceRestorationNoticeView.reservesLayoutSpace(
                hasWorkspaceNotice: true,
                hasProjectAccountIssue: false
            )
        )
        XCTAssertTrue(
            WorkspaceRestorationNoticeView.reservesLayoutSpace(
                hasWorkspaceNotice: false,
                hasProjectAccountIssue: true
            )
        )
    }

    func testCollapsedSidebarVisualFixtureStartsInDetailOnlyWithoutChangingProduction() {
        XCTAssertEqual(
            RootSidebarVisibilityFixture.initialVisibility(environment: [:]),
            .all
        )
        XCTAssertEqual(
            RootSidebarVisibilityFixture.initialVisibility(environment: [
                "KAISOLA_NATIVE_VISUAL_SIDEBAR_VISIBILITY": "detailOnly",
            ]),
            .all,
            "an ordinary launch must ignore fixture-only presentation flags"
        )
        XCTAssertEqual(
            RootSidebarVisibilityFixture.initialVisibility(environment: [
                "KAISOLA_NATIVE_VISUAL_FIXTURE": "1",
                "KAISOLA_NATIVE_VISUAL_SIDEBAR_VISIBILITY": "detailOnly",
            ]),
            .detailOnly
        )
    }

    func testBothNavigationShellsShareTheNewSessionAndRealSurfaceRoutes() {
        let project = AppModel.ProjectGroup(
            id: "project-a",
            name: "Kaisola",
            directory: URL(fileURLWithPath: "/tmp/kaisola", isDirectory: true),
            sessions: [],
            colorHex: nil
        )
        var startedProjectIDs: [String] = []
        var realSurfaceSelections = 0
        let actions = inertRootShellActions(
            beginNewSession: { startedProjectIDs.append($0.id) },
            selectRealSurface: { realSurfaceSelections += 1 }
        )

        actions.beginNewSession(project)
        actions.selectRealSurface()

        XCTAssertEqual(startedProjectIDs, ["project-a"])
        XCTAssertEqual(realSurfaceSelections, 1)
    }

    // MARK: - Helpers

    /// Spins the main run loop in default mode until the condition holds (or
    /// two seconds pass) — the deferred structural switch applies via
    /// `RunLoop.main.perform(inModes: [.default])`, which a plain
    /// expectation-wait can miss because XCTest waits in its own mode.
    private func spinRunLoop(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func renderRootShell<Content: View>(_ content: Content) throws -> NSImage {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        let hostingView = NSHostingView(rootView: content.frame(width: 720, height: 480))
        hostingView.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let image = NSImage(size: frame.size)
        image.addRepresentation(representation)
        NativeHostedTestWindows.keep(window)
        return image
    }

    private func inertRootShellActions(
        beginNewSession: @escaping (AppModel.ProjectGroup) -> Void = { _ in },
        selectRealSurface: @escaping () -> Void = {}
    ) -> RootShellActionModel {
        RootShellActionModel(
            openDroppedProjects: { _ in false },
            beginNewSession: beginNewSession,
            selectRealSurface: selectRealSurface,
            useLeftTreeNavigation: {},
            moveProject: { _, _ in },
            runQuickAction: { _, _ in },
            selectSession: { _ in },
            projectContextMenu: { _ in AnyView(EmptyView()) },
            sessionContextMenu: { _ in AnyView(EmptyView()) },
            chatContextMenu: { _ in AnyView(EmptyView()) },
            meshContextMenu: { _ in AnyView(EmptyView()) },
            renameSurface: { _ in },
            closeChat: { _ in },
            deleteChat: { _ in },
            closeMesh: { _ in },
            deleteMesh: { _ in },
            deleteRecentlyClosed: { _ in }
        )
    }
}

/// Closing a hosted window is production app quit behavior. Keep these small,
/// detached test windows alive until the test process exits so a later run-loop
/// test cannot service a quit queued by an earlier geometry or focus test.
@MainActor
enum NativeHostedTestWindows {
    private static var windows: [NSWindow] = []

    static func keep(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        windows.append(window)
    }
}
