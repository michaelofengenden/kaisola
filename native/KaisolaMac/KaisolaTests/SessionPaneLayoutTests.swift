import AppKit
import XCTest
@testable import Kaisola

final class SessionPaneLayoutTests: XCTestCase {
    @MainActor
    func testSidebarAccessibilityActionTargetsTheDividerUnderItsHandle() throws {
        let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 192, height: 600))
        let detail = NSView(frame: NSRect(x: 193, y: 0, width: 607, height: 600))
        splitView.addSubview(sidebar)
        splitView.addSubview(detail)

        let window = NSWindow(
            contentRect: splitView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = splitView
        splitView.frame = window.contentView!.bounds
        splitView.adjustSubviews()
        splitView.setPosition(192, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        let handle = NavigationSidebarResizeHandle.TrackingView()
        sidebar.addSubview(handle)
        handle.frame = NSRect(
            x: sidebar.bounds.maxX - 8.5,
            y: 0,
            width: 17,
            height: sidebar.bounds.height
        )

        XCTAssertFalse(handle.isAccessibilityElement())
        let element = try XCTUnwrap(
            handle.accessibilityChildren()?.first as? NavigationSidebarAccessibilityElement
        )
        XCTAssertEqual(element.accessibilityRole(), .slider)
        XCTAssertEqual(try XCTUnwrap(element.accessibilityValue() as? NSNumber).doubleValue, 192, accuracy: 0.5)
        XCTAssertTrue(element.accessibilityPerformIncrement())
        splitView.layoutSubtreeIfNeeded()
        XCTAssertEqual(sidebar.frame.width, 208, accuracy: 0.5)
        XCTAssertTrue(element.accessibilityPerformDecrement())
        splitView.layoutSubtreeIfNeeded()
        XCTAssertEqual(sidebar.frame.width, 192, accuracy: 0.5)

        XCTAssertTrue(handle.applyAccessibilityAdjustment(16))
        splitView.layoutSubtreeIfNeeded()
        XCTAssertEqual(sidebar.frame.width, 208, accuracy: 0.5)
        XCTAssertTrue(handle.applyAccessibilityAdjustment(-16))
        splitView.layoutSubtreeIfNeeded()
        XCTAssertEqual(sidebar.frame.width, 192, accuracy: 0.5)
    }

    func testExplicitAddsOpenBesideThenBalanceIntoStacks() {
        var layout = SessionPaneLayout(sessionID: "one")
        layout.add("two")
        layout.add("three")
        layout.add("four")

        XCTAssertEqual(layout.columns.count, 2)
        XCTAssertEqual(layout.columns[0].sessionIDs, ["one", "three"])
        XCTAssertEqual(layout.columns[1].sessionIDs, ["two", "four"])
    }

    func testFocusReplacesOnlyPrimaryAndKeepsExplicitSplits() {
        var layout = SessionPaneLayout(columns: [
            .init(sessionIDs: ["one", "three"]),
            .init(sessionIDs: ["two"]),
        ])
        layout.focus("replacement")
        XCTAssertEqual(layout.columns[0].sessionIDs, ["replacement", "three"])
        XCTAssertEqual(layout.columns[1].sessionIDs, ["two"])
    }

    func testTargetedReplacementPreservesExactPaneGeometry() {
        var layout = SessionPaneLayout(columns: [
            .init(id: "left", sessionIDs: ["one"], weight: 1.4, rowWeights: [1]),
            .init(id: "right", sessionIDs: ["ended", "three"], weight: 0.6, rowWeights: [0.7, 1.3]),
        ])

        XCTAssertTrue(layout.replace("ended", with: "reopened"))
        XCTAssertEqual(layout.columns.map(\.sessionIDs), [["one"], ["reopened", "three"]])
        XCTAssertEqual(layout.columns.map(\.weight), [1.4, 0.6])
        XCTAssertEqual(layout.columns[1].rowWeights, [0.7, 1.3])
        XCTAssertFalse(layout.replace("missing", with: "another"))
        XCTAssertFalse(layout.replace("reopened", with: "three"))
    }

    func testEdgePlacementMakesColumnsAndRows() {
        var layout = SessionPaneLayout(columns: [
            .init(sessionIDs: ["one", "two"]),
            .init(sessionIDs: ["three"]),
        ])
        layout.place("two", relativeTo: "three", edge: .top)
        XCTAssertEqual(layout.columns.map(\.sessionIDs), [["one"], ["two", "three"]])

        layout.place("one", relativeTo: "three", edge: .right)
        XCTAssertEqual(layout.columns.map(\.sessionIDs), [["two", "three"], ["one"]])
    }

    func testNormalizeDropsStaleDuplicatesAndCapsCards() {
        var layout = SessionPaneLayout(columns: [
            .init(sessionIDs: ["one", "one", "stale"]),
            .init(sessionIDs: (2...12).map { "s\($0)" }),
        ])
        layout.normalize(availableSessionIDs: Set(["one"] + (2...12).map { "s\($0)" }))
        XCTAssertEqual(layout.sessionIDs.first, "one")
        XCTAssertEqual(Set(layout.sessionIDs).count, layout.sessionIDs.count)
        XCTAssertLessThanOrEqual(layout.sessionIDs.count, SessionPaneLayout.maximumPaneCount)
        XCTAssertFalse(layout.sessionIDs.contains("stale"))
    }

    func testResizeTransfersWeightWithoutChangingPairTotal() {
        var layout = SessionPaneLayout(columns: [
            .init(sessionIDs: ["one"], weight: 1),
            .init(sessionIDs: ["two"], weight: 1),
        ])
        layout.resizeColumns(boundary: 0, delta: 0.4, minimumWeight: 0.2)
        XCTAssertEqual(layout.columns[0].weight, 1.4, accuracy: 0.0001)
        XCTAssertEqual(layout.columns[1].weight, 0.6, accuracy: 0.0001)
        XCTAssertEqual(layout.columns.map(\.weight).reduce(0, +), 2, accuracy: 0.0001)
    }

    func testResizeMathUsesStablePointToWeightConversion() {
        XCTAssertEqual(
            SessionPaneLayout.weightDelta(
                pointDelta: 80,
                availableExtent: 800,
                totalWeight: 2
            ),
            0.2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            SessionPaneLayout.minimumWeight(
                minimumExtent: 180,
                availableExtent: 900,
                totalWeight: 2
            ),
            0.4,
            accuracy: 0.0001
        )
    }

    func testResizeMathFailsClosedForInvalidGeometry() {
        XCTAssertEqual(
            SessionPaneLayout.weightDelta(
                pointDelta: 30,
                availableExtent: 0,
                totalWeight: 2
            ),
            0
        )
        XCTAssertEqual(
            SessionPaneLayout.weightDelta(
                pointDelta: .infinity,
                availableExtent: 800,
                totalWeight: 2
            ),
            0
        )
    }

    func testResizeClampsAtMinimumWithoutOscillatingPairTotal() {
        var layout = SessionPaneLayout(columns: [
            .init(sessionIDs: ["one"], weight: 1),
            .init(sessionIDs: ["two"], weight: 1),
        ])
        layout.resizeColumns(boundary: 0, delta: 50, minimumWeight: 0.35)
        XCTAssertEqual(layout.columns[0].weight, 1.65, accuracy: 0.0001)
        XCTAssertEqual(layout.columns[1].weight, 0.35, accuracy: 0.0001)

        layout.resizeColumns(boundary: 0, delta: 50, minimumWeight: 0.35)
        XCTAssertEqual(layout.columns[0].weight, 1.65, accuracy: 0.0001)
        XCTAssertEqual(layout.columns[1].weight, 0.35, accuracy: 0.0001)
        XCTAssertEqual(layout.columns.map(\.weight).reduce(0, +), 2, accuracy: 0.0001)
    }

    func testDividerResetBalancesColumnsAndOnlyTheTargetRows() {
        var layout = SessionPaneLayout(columns: [
            .init(id: "left", sessionIDs: ["one", "two"], weight: 1.6, rowWeights: [0.4, 1.6]),
            .init(id: "right", sessionIDs: ["three", "four"], weight: 0.4, rowWeights: [1.4, 0.6]),
        ])

        layout.resetColumnWeights()
        layout.resetRowWeights(columnID: "left")

        XCTAssertEqual(layout.columns.map(\.weight), [1, 1])
        XCTAssertEqual(layout.columns[0].rowWeights, [1, 1])
        XCTAssertEqual(layout.columns[1].rowWeights, [1.4, 0.6])
    }

    func testCodableRoundTripPreservesGeometry() throws {
        var layout = SessionPaneLayout(columns: [
            .init(id: "left", sessionIDs: ["one", "two"], weight: 1.4, rowWeights: [0.7, 1.3]),
            .init(id: "right", sessionIDs: ["three"], weight: 0.6),
        ])
        layout.resizeRows(columnID: "left", boundary: 0, delta: 0.1, minimumWeight: 0.2)
        let decoded = try JSONDecoder().decode(SessionPaneLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
    }

    func testPaneFocusCycleWrapsInBothDirectionsAndAlwaysMovesSomewhere() {
        let ids = ["terminal:a", "chat:b", "mesh:c"]

        XCTAssertEqual(PaneFocusCycle.target(after: "terminal:a", in: ids, forward: true), "chat:b")
        XCTAssertEqual(PaneFocusCycle.target(after: "mesh:c", in: ids, forward: true), "terminal:a")
        XCTAssertEqual(PaneFocusCycle.target(after: "terminal:a", in: ids, forward: false), "mesh:c")
        XCTAssertEqual(PaneFocusCycle.target(after: "chat:b", in: ids, forward: false), "terminal:a")

        // Nothing focused, or a pane that has since closed: start from the end
        // the direction implies rather than making the command a silent no-op.
        XCTAssertEqual(PaneFocusCycle.target(after: nil, in: ids, forward: true), "terminal:a")
        XCTAssertEqual(PaneFocusCycle.target(after: nil, in: ids, forward: false), "mesh:c")
        XCTAssertEqual(PaneFocusCycle.target(after: "terminal:gone", in: ids, forward: true), "terminal:a")

        XCTAssertNil(PaneFocusCycle.target(after: "terminal:a", in: [], forward: true))
        XCTAssertEqual(
            PaneFocusCycle.target(after: "terminal:a", in: ["terminal:a"], forward: true),
            "terminal:a"
        )
    }

    func testPaneFocusCycleFollowsTheLayoutsReadingOrder() {
        let layout = SessionPaneLayout(columns: [
            SessionPaneLayout.Column(id: "left", sessionIDs: ["a", "b"], weight: 1, rowWeights: [1, 1]),
            SessionPaneLayout.Column(id: "right", sessionIDs: ["c"], weight: 1, rowWeights: [1]),
        ])
        XCTAssertEqual(layout.sessionIDs, ["a", "b", "c"])
        XCTAssertEqual(PaneFocusCycle.target(after: "b", in: layout.sessionIDs, forward: true), "c")
    }

    /// Every unified pane now has a concrete keyboard target: terminals use
    /// AppKit first responder and Chat/Mesh use their composer FocusState.
    func testPaneFocusCycleIncludesChatAndMeshSurfaces() {
        let ids = ["terminal:a", "chat:b", "mesh:c", "terminal:d"]

        XCTAssertEqual(
            PaneFocusCycle.target(after: "terminal:a", in: ids, forward: true),
            "chat:b"
        )
        XCTAssertEqual(
            PaneFocusCycle.target(after: "chat:b", in: ids, forward: true),
            "mesh:c"
        )
        XCTAssertEqual(
            PaneFocusCycle.target(after: "terminal:a", in: ids, forward: false),
            "terminal:d"
        )
        XCTAssertEqual(
            PaneFocusCycle.target(after: nil, in: ids, forward: true),
            "terminal:a"
        )
        XCTAssertEqual(
            PaneFocusCycle.target(after: nil, in: ["chat:b", "mesh:c"], forward: true),
            "chat:b"
        )
    }

    func testRepeatedKeyboardFocusRequestsRemainObservable() {
        let first = SurfaceKeyboardFocusRequest(targetID: "chat:b", generation: 1)
        let repeated = SurfaceKeyboardFocusRequest(targetID: "chat:b", generation: 2)
        XCTAssertNotEqual(first, repeated)
        XCTAssertEqual(repeated.targetID, first.targetID)
    }

    /// A focus ring means "this one, not the others", so a lone pane must not
    /// draw one. It used to: the single terminal that most windows show all day
    /// was permanently framed in accent blue, distinguishing it from nothing,
    /// while the sidebar was already marking the same session in the same
    /// colour.
    func testALonePaneIsNotMarkedAsFocusedButSiblingsAre() {
        let alone = SessionPaneLayout(sessionID: "terminal:a")
        XCTAssertFalse(alone.marksFocus("terminal:a", focusedID: "terminal:a"))
        XCTAssertFalse(alone.marksFocus("terminal:a", focusedID: nil))

        let split = SessionPaneLayout(columns: [
            .init(sessionIDs: ["terminal:a"]),
            .init(sessionIDs: ["terminal:b"]),
        ])
        XCTAssertTrue(split.marksFocus("terminal:a", focusedID: "terminal:a"))
        XCTAssertFalse(split.marksFocus("terminal:b", focusedID: "terminal:a"))
        XCTAssertFalse(split.marksFocus("terminal:a", focusedID: nil))

        // Stacked rows in one column are siblings too.
        let stacked = SessionPaneLayout(columns: [
            .init(sessionIDs: ["terminal:a", "chat:b"]),
        ])
        XCTAssertTrue(stacked.marksFocus("chat:b", focusedID: "chat:b"))

        // A maximized pane is drawn alone, so the layout having siblings is
        // beside the point: the window is showing exactly one card, and ringing
        // it is the same lone accent rectangle reached by another route.
        XCTAssertFalse(
            split.marksFocus("terminal:a", focusedID: "terminal:a", maximizedID: "terminal:a")
        )
        XCTAssertFalse(
            stacked.marksFocus("chat:b", focusedID: "chat:b", maximizedID: "chat:b")
        )
        // A stale maximized id for some other project's pane must not silently
        // suppress the ring on a genuine split.
        XCTAssertTrue(
            split.marksFocus("terminal:a", focusedID: "terminal:a", maximizedID: "terminal:zz")
        )
    }

    func testTerminalHeaderResolverUsesOnlyEachTerminalsLifecycleAndInputAuthority() {
        struct Case {
            let name: String
            let exited: Bool
            let authority: TerminalSurfaceAuthority
            let symbol: String
            let label: String
            let tone: TerminalHeaderPresentation.Tone
        }

        let cases = [
            Case(
                name: "ended",
                exited: true,
                authority: .localController(active: true),
                symbol: "stop.circle.fill",
                label: "Session ended",
                tone: .inactive
            ),
            Case(
                name: "interactive owner",
                exited: false,
                authority: .localController(active: true),
                symbol: "checkmark.circle.fill",
                label: "Terminal ready",
                tone: .ready
            ),
            Case(
                name: "temporarily inactive owner",
                exited: false,
                authority: .localController(active: false),
                symbol: "clock.arrow.circlepath",
                label: "Terminal input retrying automatically",
                tone: .inactive
            ),
            Case(
                name: "observer only",
                exited: false,
                authority: .observerOnly,
                symbol: "eye",
                label: "Terminal controlled by another window or Companion",
                tone: .inactive
            ),
        ]

        for testCase in cases {
            let presentation = TerminalHeaderPresentation.resolve(
                exited: testCase.exited,
                authority: testCase.authority
            )
            XCTAssertEqual(presentation.systemImage, testCase.symbol, testCase.name)
            XCTAssertEqual(presentation.accessibilityLabel, testCase.label, testCase.name)
            XCTAssertEqual(presentation.tone, testCase.tone, testCase.name)
        }
    }

    func testTerminalHeaderReportsPausedInputInsteadOfReadyOwnership() {
        let presentation = TerminalHeaderPresentation.resolve(
            exited: false,
            authority: .localController(active: true),
            inputDegraded: true
        )

        XCTAssertEqual(presentation.systemImage, "exclamationmark.triangle.fill")
        XCTAssertEqual(presentation.accessibilityLabel, "Terminal input paused")
        XCTAssertEqual(presentation.tone, .inactive)
    }

    func testRunningChatHeaderParentAccessibilityLabelRetainsLiveToolStatus() {
        let label = SessionHeaderAccessibilityLabel.resolve(
            title: "Kaisola",
            statusLabel: "Chat connected",
            liveActivityLabel: "Running tests, working"
        )

        XCTAssertEqual(label, "Kaisola, Running tests, working")
    }

    func testDurablyOwnedEndedTerminalKeepsLocalChromeWithoutLiveInput() {
        let directory = URL(fileURLWithPath: "/tmp/kaisola-ended")
        let ended = TerminalOwnershipPresentation(
            isLiveOwner: false,
            hasDurableOwnership: true,
            directory: directory
        )
        let observed = TerminalOwnershipPresentation(
            isLiveOwner: false,
            hasDurableOwnership: false,
            directory: nil
        )

        XCTAssertFalse(ended.isObserved)
        XCTAssertEqual(ended.gitDirectory, directory)
        XCTAssertTrue(observed.isObserved)
        XCTAssertNil(observed.gitDirectory)
    }

    func testMissingTerminalPresentationCoversEveryRestorationState() {
        struct Case {
            let name: String
            let context: MissingTerminalPaneContext
            let title: String
            let symbol: String
            let statusLabel: String
            let contentTitle: String
            let detail: String
            let showsClose: Bool
        }

        let cases = [
            Case(
                name: "awaiting inventory, active durable",
                context: MissingTerminalPaneContext(
                    state: .awaitingInventory,
                    title: "Plan agent",
                    symbol: "hammer.fill",
                    canClose: true
                ),
                title: "Plan agent",
                symbol: "hammer.fill",
                statusLabel: "Restoring terminal",
                contentTitle: "Restoring terminal",
                detail: "Checking local terminal state before restoring this session.",
                showsClose: true
            ),
            Case(
                name: "awaiting inventory, archived unowned",
                context: MissingTerminalPaneContext(
                    state: .awaitingInventory,
                    title: "Archived terminal",
                    symbol: "",
                    canClose: false
                ),
                title: "Archived terminal",
                symbol: "terminal",
                statusLabel: "Restoring terminal",
                contentTitle: "Restoring terminal",
                detail: "Checking local terminal state before restoring this session.",
                showsClose: false
            ),
            Case(
                name: "restoring controller, active durable absent",
                context: MissingTerminalPaneContext(
                    state: .restoringController,
                    title: "Build agent",
                    symbol: "wrench.and.screwdriver.fill",
                    canClose: true
                ),
                title: "Build agent",
                symbol: "wrench.and.screwdriver.fill",
                statusLabel: "Restoring terminal",
                contentTitle: "Restoring terminal",
                detail: "Restoring terminal input.",
                showsClose: true
            ),
            Case(
                name: "settled, active durable absent",
                context: MissingTerminalPaneContext(
                    state: .settledDurable,
                    title: "Review agent",
                    symbol: "checkmark.seal.fill",
                    canClose: true
                ),
                title: "Review agent",
                symbol: "checkmark.seal.fill",
                statusLabel: "Terminal unavailable",
                contentTitle: "Terminal unavailable",
                detail: "This terminal is no longer running. Close it or start a new session.",
                showsClose: true
            ),
            Case(
                name: "ended persisted record",
                context: MissingTerminalPaneContext(
                    state: .invalid,
                    title: "Ended agent",
                    symbol: "stop.circle.fill",
                    canClose: true
                ),
                title: "Terminal",
                symbol: "terminal",
                statusLabel: "Session unavailable",
                contentTitle: "Session unavailable",
                detail: "",
                showsClose: false
            ),
            Case(
                name: "stale unowned after inventory",
                context: MissingTerminalPaneContext(
                    state: .invalid,
                    title: "Stale terminal",
                    symbol: "questionmark",
                    canClose: false
                ),
                title: "Terminal",
                symbol: "terminal",
                statusLabel: "Session unavailable",
                contentTitle: "Session unavailable",
                detail: "",
                showsClose: false
            ),
        ]

        for testCase in cases {
            let presentation = MissingTerminalPanePresentation.resolve(
                context: testCase.context
            )

            XCTAssertEqual(presentation.title, testCase.title, testCase.name)
            XCTAssertEqual(presentation.symbol, testCase.symbol, testCase.name)
            XCTAssertEqual(presentation.statusLabel, testCase.statusLabel, testCase.name)
            XCTAssertEqual(presentation.contentTitle, testCase.contentTitle, testCase.name)
            XCTAssertEqual(presentation.detail, testCase.detail, testCase.name)
            XCTAssertEqual(presentation.showsClose, testCase.showsClose, testCase.name)
            XCTAssertEqual(
                presentation.accessibilityLabel,
                "\(presentation.title), \(presentation.statusLabel)",
                testCase.name
            )
        }
    }

}
