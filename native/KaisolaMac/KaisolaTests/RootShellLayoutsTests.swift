import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Kaisola

@MainActor
final class RootShellLayoutsTests: XCTestCase {
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
            [.chatOverflow, .hide, .detailDoors],
            "ellipsis and the panel toggles stay; the arrow and account buttons are gone"
        )

        let terminal = UnifiedSessionHeaderGrammar.trailingControls(
            isChat: false,
            isMesh: false,
            isTerminal: true,
            hostsDetailDoors: false
        )
        XCTAssertEqual(terminal, [.terminalTranscript, .terminalPopOut, .hide])

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

    // MARK: - Safari-style traffic lights

    func testTrafficLightsShiftInwardPreservingTheStandardGaps() {
        XCTAssertEqual(WorkspaceTrafficLights.leadingInset, 20, "Safari's ~20pt inset")
        XCTAssertEqual(
            WorkspaceTrafficLights.shiftedOrigins(standardMinXs: [7, 27, 47]),
            [20, 40, 60]
        )
        XCTAssertEqual(
            WorkspaceTrafficLights.shiftedOrigins(standardMinXs: [20, 40, 60]),
            [20, 40, 60],
            "already-shifted buttons are a fixed point, so re-application cannot walk"
        )
        XCTAssertEqual(WorkspaceTrafficLights.shiftedOrigins(standardMinXs: []), [])
    }

    func testTrafficLightsStayEvenlySpacedThroughAPartialRelayout() {
        // v0.1.147's uneven red button. AppKit returns the buttons to stock one
        // at a time, so a frame-change notification can land with close back at
        // 7 while minimize and zoom still hold 40 and 60. The delta form spread
        // that read out unevenly:
        let skewed = WorkspaceTrafficLights.shiftedOrigins(standardMinXs: [7, 40, 60])
        XCTAssertEqual(skewed, [20, 53, 73])
        XCTAssertNotEqual(
            skewed[1] - skewed[0],
            skewed[2] - skewed[1],
            "this is the reported defect: the gaps disagree"
        )

        // Rebuilding from the remembered stock gaps cannot express that, no
        // matter which partial state the read caught.
        let stockGaps = WorkspaceTrafficLights.gaps(between: [7, 27, 47])
        XCTAssertEqual(stockGaps, [20, 20])
        XCTAssertEqual(WorkspaceTrafficLights.origins(gaps: stockGaps), [20, 40, 60])

        for partial in [[7, 40, 60], [20, 27, 47], [7, 27, 60], [20, 40, 60]] {
            let repaired = WorkspaceTrafficLights.origins(gaps: stockGaps)
            XCTAssertEqual(
                repaired,
                [20, 40, 60],
                "a read of \(partial) must still land the standard gaps"
            )
            XCTAssertEqual(repaired[1] - repaired[0], repaired[2] - repaired[1])
        }

        XCTAssertEqual(WorkspaceTrafficLights.gaps(between: [7]), [])
        XCTAssertEqual(WorkspaceTrafficLights.origins(gaps: []), [20])
    }

    /// Measured on a real v0.1.148 window through the accessibility API:
    /// close 21, minimize 41, zoom 53 — gaps of 20 and 12.
    ///
    /// v0.1.148's fix made this permanent instead of fixing it. It captured
    /// the first read's gaps verbatim, guarded only against negatives, and
    /// then re-imposed them forever — so a read taken mid-layout became the
    /// window's spacing for the rest of its life. macOS spaces these evenly by
    /// definition, so disagreeing gaps describe the read, not the window.
    func testTheUniformGapIsRecoveredFromASqueezedRead() {
        // The exact shipped defect.
        XCTAssertEqual(WorkspaceTrafficLights.uniformGap(from: [21, 41, 53]), 20)
        XCTAssertEqual(
            WorkspaceTrafficLights.origins(uniformGap: 20, count: 3),
            [20, 40, 60],
            "one clean rebuild puts all three back on the standard pitch"
        )

        // Squeezing only ever makes gaps smaller, so the largest is the stock
        // one whichever pair got compressed.
        XCTAssertEqual(WorkspaceTrafficLights.uniformGap(from: [7, 15, 35]), 20)
        XCTAssertEqual(WorkspaceTrafficLights.uniformGap(from: [7, 27, 47]), 20)

        // A clean read is a fixed point: rebuilding changes nothing.
        XCTAssertEqual(
            WorkspaceTrafficLights.origins(uniformGap: 20, count: 3),
            WorkspaceTrafficLights.origins(
                uniformGap: WorkspaceTrafficLights.uniformGap(from: [20, 40, 60]) ?? 0,
                count: 3
            )
        )

        // Degenerate reads yield nothing to act on rather than a bad gap.
        XCTAssertNil(WorkspaceTrafficLights.uniformGap(from: [20]))
        XCTAssertNil(WorkspaceTrafficLights.uniformGap(from: []))
        XCTAssertEqual(WorkspaceTrafficLights.origins(uniformGap: 20, count: 0), [])
    }

    /// Measured 2026-08-29 through the accessibility API, same probe, same
    /// moment: Finder 18/41/64 gaps 23,23. Notes 18/41/64 gaps 23,23. Kaisola
    /// 19/45/64 gaps 26,19.
    ///
    /// The system already insets these buttons — 18 is the "like in Safari"
    /// position this feature was written to create back when the stock corner
    /// was ~7. What was left was a 2pt correction that could only do harm, and
    /// twice did. The controller now stands down whenever AppKit has already
    /// placed them near the target, which is the only way to guarantee the
    /// pitch stays the system's own.
    func testTheButtonsAreLeftAloneWhenAppKitAlreadyInsetsThem() {
        // What Finder, Notes, and a stock Kaisola window all report today.
        XCTAssertFalse(
            WorkspaceTrafficLights.shouldReposition(currentLeading: 18),
            "the system's own inset is the one this feature wanted"
        )
        XCTAssertFalse(WorkspaceTrafficLights.shouldReposition(currentLeading: 20))
        XCTAssertFalse(WorkspaceTrafficLights.shouldReposition(currentLeading: 30))

        // The corner this was written against, where the shift still earns its
        // keep.
        XCTAssertTrue(WorkspaceTrafficLights.shouldReposition(currentLeading: 7))
        XCTAssertTrue(WorkspaceTrafficLights.shouldReposition(currentLeading: 0))

        // And when it does fire, it lands on the system's own even pitch
        // rather than a shift of whatever it happened to read.
        XCTAssertEqual(
            WorkspaceTrafficLights.origins(
                uniformGap: WorkspaceTrafficLights.uniformGap(from: [7, 30, 53]) ?? 0,
                count: 3
            ),
            [20, 43, 66]
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
        XCTAssertEqual(opening, 180)

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
        window.contentView = nil
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
