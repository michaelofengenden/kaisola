import AppKit
import SwiftUI
import XCTest
@testable import Kaisola

@MainActor
final class RootShellLayoutsTests: XCTestCase {
    func testLeftTreeShellRendersProjectsWorkspaceAndFooter() throws {
        XCTAssertEqual(
            RootShellRenderContract.regions(for: .leftTree, preview: .off),
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

    func testTopBarShellKeepsTheShippedFiveRegionStackWhenThePreviewIsOff() throws {
        // 2026-08-28 feedback round: the shell revision is a runtime preview
        // now. Off must be exactly the shipped shell — main's five regions,
        // Quick Actions row included.
        XCTAssertEqual(
            RootShellRenderContract.regions(for: .topBar, preview: .off),
            [.projects, .quickActions, .sessions, .workspace, .footer]
        )

        let image = try renderRootShell(
            RootTopBarShell(actions: inertRootShellActions()) { _ in
                Text("Projects")
            } quickActions: { _ in
                Text("Quick Actions")
            } sessions: { _ in
                Text("Sessions")
            } detail: { _ in
                Text("Workspace")
            } footer: { _ in
                Text("Footer")
            }
        )

        XCTAssertEqual(image.size, NSSize(width: 720, height: 480))
        XCTAssertGreaterThan(image.tiffRepresentation?.count ?? 0, 1_000)
    }

    func testTopBarShellMergesIntoOneBarOnlyWhileThePreviewIsOn() throws {
        // 2026-08-28 revision, decision 2: under the preview the project strip
        // and session strip are one 40pt bar and the persistent Quick Actions
        // row is gone. Both on-variants share the merged structure.
        for variant in [ShellPreviewVariant.pills, .capsules] {
            XCTAssertEqual(
                RootShellRenderContract.regions(for: .topBar, preview: variant),
                [.projects, .sessions, .workspace, .footer]
            )
        }

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

    func testLeftTreeContractIsTheSameWithThePreviewOnAndOff() {
        for variant in ShellPreviewVariant.allCases {
            XCTAssertEqual(
                RootShellRenderContract.regions(for: .leftTree, preview: variant),
                [.projects, .workspace, .footer]
            )
        }
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

    func testQuietRailFillsOnlyTheSelectedRowWhileThePreviewIsOn() {
        // Michael, 2026-08-28: "I'd like there'd not to be a double card
        // situation for the lhs rail." Under the preview's card rail, resting
        // rows — split companions included — draw no fill; only the selected
        // row wears the pill, and hover answers with the faint wash.
        for variant in [ShellPreviewVariant.pills, .capsules] {
            XCTAssertEqual(
                QuietSelectionPill.fill(isSelected: true, isOnScreen: true, hovering: false, preview: variant),
                .selectionPill
            )
            XCTAssertEqual(
                QuietSelectionPill.fill(isSelected: true, isOnScreen: false, hovering: true, preview: variant),
                .selectionPill,
                "selection outranks hover"
            )
            XCTAssertEqual(
                QuietSelectionPill.fill(isSelected: false, isOnScreen: true, hovering: false, preview: variant),
                QuietRowFill.none,
                "an on-screen companion row rests quiet inside the rail card"
            )
            XCTAssertEqual(
                QuietSelectionPill.fill(isSelected: false, isOnScreen: true, hovering: true, preview: variant),
                .hoverWash
            )
            XCTAssertEqual(
                QuietSelectionPill.fill(isSelected: false, isOnScreen: false, hovering: false, preview: variant),
                QuietRowFill.none
            )
        }
    }

    func testQuietRailKeepsTheShippedCompanionPillAndNoHoverWashWhenThePreviewIsOff() {
        XCTAssertEqual(
            QuietSelectionPill.fill(isSelected: true, isOnScreen: false, hovering: false, preview: .off),
            .selectionPill
        )
        XCTAssertEqual(
            QuietSelectionPill.fill(isSelected: false, isOnScreen: true, hovering: false, preview: .off),
            .companionPill,
            "off is exactly the shipped rail: a split's other pane keeps its fainter pill"
        )
        XCTAssertEqual(
            QuietSelectionPill.fill(isSelected: false, isOnScreen: false, hovering: true, preview: .off),
            QuietRowFill.none,
            "the hover wash is part of the preview, not the shipped rail"
        )
        XCTAssertEqual(
            QuietSelectionPill.fill(isSelected: false, isOnScreen: false, hovering: false, preview: .off),
            QuietRowFill.none
        )
    }

    func testShellPreviewSettingDefaultsOffRoundTripsAndRejectsJunk() throws {
        let suite = "kaisola-tests.shell-preview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = NativePreviewSettings(defaults: defaults, persistsChanges: true)
        XCTAssertEqual(fresh.shellPreviewVariant, .off, "the preview never turns itself on")

        fresh.shellPreviewVariant = .capsules
        XCTAssertEqual(defaults.string(forKey: "shellPreviewVariant"), "capsules")
        let reread = NativePreviewSettings(defaults: defaults, persistsChanges: true)
        XCTAssertEqual(reread.shellPreviewVariant, .capsules)

        defaults.set("lozenges", forKey: "shellPreviewVariant")
        let junk = NativePreviewSettings(defaults: defaults, persistsChanges: true)
        XCTAssertEqual(junk.shellPreviewVariant, .off, "an unknown stored value falls back to the shipped shell")
    }

    func testShellPreviewEnvironmentOverrideOutranksTheSetting() {
        // KAISOLA_SHELL_PREVIEW_TABS keeps working for fixture processes and
        // wins over the persisted choice; anything unparseable defers to it.
        XCTAssertEqual(
            ShellPreviewVariant.resolved(
                environment: ["KAISOLA_SHELL_PREVIEW_TABS": "capsules"],
                setting: .off
            ),
            .capsules
        )
        XCTAssertEqual(
            ShellPreviewVariant.resolved(
                environment: ["KAISOLA_SHELL_PREVIEW_TABS": "pills"],
                setting: .capsules
            ),
            .pills
        )
        XCTAssertEqual(
            ShellPreviewVariant.resolved(
                environment: ["KAISOLA_SHELL_PREVIEW_TABS": "off"],
                setting: .pills
            ),
            .off
        )
        XCTAssertEqual(
            ShellPreviewVariant.resolved(
                environment: ["KAISOLA_SHELL_PREVIEW_TABS": "wedges"],
                setting: .capsules
            ),
            .capsules
        )
        XCTAssertEqual(
            ShellPreviewVariant.resolved(environment: [:], setting: .pills),
            .pills
        )
        XCTAssertEqual(
            ShellPreviewVariant.resolved(environment: [:], setting: .off),
            .off
        )
    }

    func testWindowCornerStaysSystemSquareUntilThePreviewTurnsItOn() {
        XCTAssertEqual(ShellPreviewVariant.off.windowCornerRadius, 0)
        XCTAssertEqual(ShellPreviewVariant.pills.windowCornerRadius, KaisolaVisualSystem.shellRadius)
        XCTAssertEqual(ShellPreviewVariant.capsules.windowCornerRadius, KaisolaVisualSystem.shellRadius)
    }

    func testTopBarWorkspaceDoesNotReserveAnEmptyToggleStrip() {
        XCTAssertEqual(
            NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar),
            KaisolaVisualSystem.chromeInset
        )
        XCTAssertEqual(
            NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar),
            NativeWorkspaceChrome.detailPanelTopInset(layout: .leftTree)
        )
    }

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
