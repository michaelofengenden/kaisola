import AppKit
import SwiftUI
import XCTest
@testable import Kaisola

/// Mesh used to divide whatever width it had into equal side-by-side columns
/// with no floor, so three agents on a laptop wrapped filenames mid-path, cut
/// tool rows down to "Inspect n…", and gave every code block its own
/// horizontal scrollbar. These pin the measured minimum, the deck that takes
/// over below it, and what survives the swap.
final class MeshColumnDeckTests: XCTestCase {
    /// Mesh pane widths, not window widths — the sidebar and the workspace rail
    /// take a growing share of the window before the columns see any of it.
    /// These three are what the `min`, `typical`, and `full` visual fixtures
    /// actually hand the deck, read off the running app.
    private let narrowPaneWidth: CGFloat = 321
    private let typicalPaneWidth: CGFloat = 921
    private let fullScreenPaneWidth: CGFloat = 1_289

    // MARK: - The measured minimum

    func testMinimumColumnWidthHoldsAnUnwrappedCodeLine() {
        let font = NSFont.monospacedSystemFont(
            ofSize: MeshColumnWidth.captionPointSize,
            weight: .regular
        )
        let line = String(repeating: "0", count: MeshColumnWidth.codeLineCharacters)
        let codeLine = (line as NSString).size(withAttributes: [.font: font]).width
        let needed = codeLine
            + 2 * MeshColumnWidth.codeBlockInset
            + 2 * MeshColumnWidth.transcriptInset

        XCTAssertGreaterThanOrEqual(MeshColumnWidth.minimum(), needed)
        // And it is a real floor, not a nominal one: a column narrow enough to
        // wrap that line has to be below it.
        XCTAssertGreaterThan(MeshColumnWidth.minimum(), 320)
    }

    func testLargerTextRaisesTheMinimum() {
        let standard = MeshColumnWidth.minimum(textScale: MeshColumnWidth.textScale(for: .large))
        let large = MeshColumnWidth.minimum(
            textScale: MeshColumnWidth.textScale(for: .accessibility1)
        )
        XCTAssertGreaterThan(large, standard)
        XCTAssertEqual(MeshColumnWidth.textScale(for: .large), 1)
        XCTAssertGreaterThan(MeshColumnWidth.textScale(for: .accessibility3), 2)
    }

    // MARK: - Which deck each width gets

    /// 2/3/4 agents at a narrow, a typical, and a full-screen pane width. The
    /// unpatched view had one answer for every cell — side by side, always.
    func testDeckMatrixAcrossAgentCountsAndWidths() {
        for columns in 2...4 {
            XCTAssertEqual(
                MeshColumnDeckPolicy.deck(availableWidth: narrowPaneWidth, columnCount: columns),
                .focused,
                "\(columns) columns should not share a narrow pane"
            )
        }

        XCTAssertEqual(
            MeshColumnDeckPolicy.deck(availableWidth: typicalPaneWidth, columnCount: 2),
            .sideBySide
        )
        for columns in 3...4 {
            XCTAssertEqual(
                MeshColumnDeckPolicy.deck(availableWidth: typicalPaneWidth, columnCount: columns),
                .focused,
                "\(columns) columns should not share a typical laptop width"
            )
        }

        for columns in 2...3 {
            XCTAssertEqual(
                MeshColumnDeckPolicy.deck(availableWidth: fullScreenPaneWidth, columnCount: columns),
                .sideBySide,
                "\(columns) columns fit a full-screen width"
            )
        }
        XCTAssertEqual(
            MeshColumnDeckPolicy.deck(availableWidth: fullScreenPaneWidth, columnCount: 4),
            .focused
        )
    }

    /// The fixture matrix is only worth capturing if its three widths land on
    /// different answers. They do: nothing fits the narrow pane, two columns
    /// fit a typical one, three fit a full-screen one.
    func testTheThreeFixtureWidthsLandOnDifferentDecks() {
        XCTAssertLessThan(
            NativeVisualMeshFixture.Width.min.points,
            NativeVisualMeshFixture.Width.typical.points
        )
        XCTAssertLessThan(
            NativeVisualMeshFixture.Width.typical.points,
            NativeVisualMeshFixture.Width.full.points
        )

        let decks = [narrowPaneWidth, typicalPaneWidth, fullScreenPaneWidth].map {
            MeshColumnDeckPolicy.deck(availableWidth: $0, columnCount: 3)
        }
        XCTAssertEqual(decks, [.focused, .focused, .sideBySide])
    }

    func testLargeTextTakesAwayAWidthThatOtherwiseFits() {
        XCTAssertEqual(
            MeshColumnDeckPolicy.deck(
                availableWidth: fullScreenPaneWidth,
                columnCount: 3,
                textScale: MeshColumnWidth.textScale(for: .large)
            ),
            .sideBySide
        )
        XCTAssertEqual(
            MeshColumnDeckPolicy.deck(
                availableWidth: fullScreenPaneWidth,
                columnCount: 3,
                textScale: MeshColumnWidth.textScale(for: .accessibility1)
            ),
            .focused
        )
    }

    /// A single column is the same picture either way, and a width SwiftUI has
    /// not measured yet must not decide anything.
    func testDegenerateGeometryKeepsTheOriginalLayout() {
        XCTAssertEqual(
            MeshColumnDeckPolicy.deck(availableWidth: 320, columnCount: 1),
            .sideBySide
        )
        XCTAssertEqual(
            MeshColumnDeckPolicy.deck(availableWidth: 0, columnCount: 3),
            .sideBySide
        )
        XCTAssertEqual(
            MeshColumnDeckPolicy.deck(availableWidth: .nan, columnCount: 3),
            .sideBySide
        )
    }

    // MARK: - What each deck draws and runs

    func testFocusedDeckDrawsOneTranscriptAndStillRunsEveryAgent() {
        let ids = ["a", "b", "c"]

        XCTAssertEqual(
            MeshColumnDeckPolicy.renderedColumnIDs(ids, deck: .sideBySide, focusedColumnID: "b"),
            ids
        )
        XCTAssertEqual(
            MeshColumnDeckPolicy.renderedColumnIDs(ids, deck: .focused, focusedColumnID: "b"),
            ["b"]
        )
        XCTAssertEqual(
            MeshColumnDeckPolicy.renderedColumnIDs(ids, deck: .focused, focusedColumnID: "gone"),
            ["a"]
        )

        // Running state is not a function of what is on screen.
        XCTAssertEqual(
            MeshColumnDeckPolicy.startedColumnIDs(ids, deck: .focused, focusedColumnID: "b"),
            ids
        )
        XCTAssertEqual(
            MeshColumnDeckPolicy.startedColumnIDs(ids, deck: .sideBySide, focusedColumnID: nil),
            ids
        )
    }

    func testSelectionSurvivesRelayoutAndColumnChurn() {
        let ids = ["a", "b", "c"]

        // An explicit choice wins over urgency: a permission elsewhere must not
        // yank the reader off the transcript they picked.
        XCTAssertEqual(
            MeshColumnDeckPolicy.focusedColumnID(
                requested: "b",
                columnIDs: ids,
                needingAttention: ["c"]
            ),
            "b"
        )
        // With no choice made, a waiting permission is the useful default.
        XCTAssertEqual(
            MeshColumnDeckPolicy.focusedColumnID(
                requested: nil,
                columnIDs: ids,
                needingAttention: ["c"]
            ),
            "c"
        )
        XCTAssertEqual(
            MeshColumnDeckPolicy.focusedColumnID(requested: nil, columnIDs: ids),
            "a"
        )
        // A column that goes away falls back instead of blanking the deck.
        XCTAssertEqual(
            MeshColumnDeckPolicy.focusedColumnID(requested: "b", columnIDs: ["a", "c"]),
            "a"
        )
        XCTAssertNil(MeshColumnDeckPolicy.focusedColumnID(requested: "b", columnIDs: []))
    }

    func testPermissionShortcutsOnlyReachAColumnThatIsOnScreen() {
        let ids = ["a", "b", "c"]

        XCTAssertEqual(
            MeshColumnDeckPolicy.permissionShortcutColumnID(
                renderedColumnIDs: ids,
                permissionColumnIDs: ["b", "c"]
            ),
            "b"
        )
        XCTAssertEqual(
            MeshColumnDeckPolicy.permissionShortcutColumnID(
                renderedColumnIDs: ["b"],
                permissionColumnIDs: ["b"]
            ),
            "b"
        )
        // Answering an invisible prompt by keystroke is the failure mode here.
        XCTAssertNil(
            MeshColumnDeckPolicy.permissionShortcutColumnID(
                renderedColumnIDs: ["a"],
                permissionColumnIDs: ["b", "c"]
            )
        )
    }

    // MARK: - The overview for columns that are not focused

    @MainActor
    func testOverviewKeepsStatusAndPermissionUrgencyOffScreen() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mesh-overview-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let mesh = MeshSession(baseDirectory: repo)
        mesh.loadVisualFixture()
        let waiting = try XCTUnwrap(mesh.columns.last)
        let options = [
            AcpPermissionRequest.Option(id: "allow", name: "Allow", kind: "allow_once"),
            AcpPermissionRequest.Option(id: "reject", name: "Reject", kind: "reject_once"),
        ]
        waiting.conversation.receivePermissionForTesting(AcpPermissionRequest(
            id: 1, sessionID: "overview", title: "Write MeshView.swift", options: options
        ))
        waiting.conversation.receivePermissionForTesting(AcpPermissionRequest(
            id: 2, sessionID: "overview", title: "Run the tests", options: options
        ))

        let items = mesh.columns.map(MeshColumnOverviewItem.init(column:))
        XCTAssertEqual(items.map(\.id), mesh.columns.map(\.id))

        let urgent = try XCTUnwrap(items.last)
        XCTAssertTrue(urgent.needsYou)
        XCTAssertEqual(urgent.pendingPermissionCount, 2)
        XCTAssertEqual(urgent.urgencyDescription, "2 permissions waiting")
        XCTAssertTrue(urgent.accessibilityLabel.contains(waiting.agent.name))
        XCTAssertTrue(urgent.accessibilityLabel.contains("2 permissions waiting"))

        let calm = try XCTUnwrap(items.first)
        XCTAssertFalse(calm.needsYou)
        XCTAssertNil(calm.urgencyDescription)
        XCTAssertEqual(calm.statusDescription, "Connected")
        XCTAssertEqual(calm.statusSymbol, "circle.fill")
        XCTAssertFalse(calm.accessibilityLabel.contains("permission"))
    }

    func testOverviewStatusShapesStayDistinctFromColour() {
        let running = MeshColumnOverviewItem(
            id: "a", name: "Claude", symbol: "sparkle",
            isRunning: true, isConnected: true, pendingPermissionCount: 0
        )
        let idle = MeshColumnOverviewItem(
            id: "b", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right",
            isRunning: false, isConnected: true, pendingPermissionCount: 0
        )
        let offline = MeshColumnOverviewItem(
            id: "c", name: "Gemini", symbol: "diamond",
            isRunning: false, isConnected: false, pendingPermissionCount: 1
        )

        XCTAssertEqual(
            Set([running.statusSymbol, idle.statusSymbol, offline.statusSymbol]).count,
            3
        )
        XCTAssertEqual(running.statusDescription, "Working")
        XCTAssertEqual(offline.statusDescription, "Not connected")
        XCTAssertEqual(offline.urgencyDescription, "1 permission waiting")
    }

    // MARK: - Scroll anchors across a deck change

    func testEachColumnKeepsItsOwnScrollAnchorThroughADeckChange() {
        let rows: [AcpTranscriptRow] = [
            .user(id: "1", text: "one", failed: false),
            .message(id: "2", text: "two"),
            .message(id: "3", text: "three"),
        ]
        let states = MeshTranscriptViewStates()
        let scrolledBack = states.state(for: "a")
        let following = states.state(for: "b")

        // Column A: the reader scrolled up to the middle of the transcript.
        scrolledBack.noteMounted(true)
        scrolledBack.noteBottomSentinel(isVisible: true)
        scrolledBack.noteRow("msg-2", isVisible: true, in: rows)
        scrolledBack.noteRow("msg-3", isVisible: true, in: rows)
        scrolledBack.noteBottomSentinel(isVisible: false)
        XCTAssertFalse(scrolledBack.isAtBottom)
        XCTAssertEqual(scrolledBack.restorationAnchor(in: rows), "msg-2")

        // Column B is following its stream.
        following.noteMounted(true)
        following.noteRow("msg-3", isVisible: true, in: rows)
        following.noteBottomSentinel(isVisible: true)
        XCTAssertTrue(following.isAtBottom)
        XCTAssertNil(following.restorationAnchor(in: rows))

        // The deck flips: every column tears down. Teardown must not read as
        // "the reader scrolled away".
        for state in [scrolledBack, following] {
            for row in rows { state.noteRow(row.id, isVisible: false, in: rows) }
            state.noteBottomSentinel(isVisible: false)
            state.noteMounted(false)
        }

        XCTAssertFalse(states.state(for: "a").isAtBottom)
        XCTAssertEqual(states.state(for: "a").restorationAnchor(in: rows), "msg-2")
        XCTAssertTrue(states.state(for: "b").isAtBottom)
        XCTAssertNil(states.state(for: "b").restorationAnchor(in: rows))
        XCTAssertTrue(states.state(for: "a") === scrolledBack)
        XCTAssertTrue(states.state(for: "b") === following)
    }

    func testUnseenOutputBadgeSurvivesTheSwapAndClearsAtTheBottom() {
        let rows: [AcpTranscriptRow] = [.message(id: "1", text: "one")]
        let state = MeshTranscriptViewState()
        state.noteMounted(true)
        state.noteRow("msg-1", isVisible: true, in: rows)
        state.noteBottomSentinel(isVisible: true)
        state.noteBottomSentinel(isVisible: false)
        state.hasUnseenUpdates = true

        state.noteMounted(false)
        XCTAssertTrue(state.hasUnseenUpdates)
        XCTAssertFalse(state.isReady)

        state.followStream()
        XCTAssertFalse(state.hasUnseenUpdates)
        XCTAssertTrue(state.isAtBottom)
    }

    func testColumnStateIsPrunedWhenItsColumnGoesAway() {
        let states = MeshTranscriptViewStates()
        _ = states.state(for: "a")
        _ = states.state(for: "b")
        XCTAssertEqual(states.trackedColumnIDs, ["a", "b"])

        states.prune(keeping: ["b"])
        XCTAssertEqual(states.trackedColumnIDs, ["b"])
    }

    // MARK: - The visual-fixture matrix

    func testMeshFixtureSurfacesDescribeTheirOwnShape() {
        XCTAssertEqual(
            NativeVisualMeshFixture.parse("mesh"),
            NativeVisualMeshFixture(agentCount: 3, width: .typical, usesLargeText: false)
        )
        XCTAssertEqual(
            NativeVisualMeshFixture.parse("mesh-2-min"),
            NativeVisualMeshFixture(agentCount: 2, width: .min, usesLargeText: false)
        )
        XCTAssertEqual(
            NativeVisualMeshFixture.parse("mesh-4-full"),
            NativeVisualMeshFixture(agentCount: 4, width: .full, usesLargeText: false)
        )
        XCTAssertEqual(
            NativeVisualMeshFixture.parse("mesh-3-typical-large-text"),
            NativeVisualMeshFixture(agentCount: 3, width: .typical, usesLargeText: true)
        )

        // A surface the workflow mistypes must not quietly capture some other
        // shape and pass the geometry gate anyway.
        XCTAssertNil(NativeVisualMeshFixture.parse("meshy"))
        XCTAssertNil(NativeVisualMeshFixture.parse("mesh-9-typical"))
        XCTAssertNil(NativeVisualMeshFixture.parse("mesh-3-huge"))
        XCTAssertNil(NativeVisualMeshFixture.parse("mesh-3"))
        XCTAssertNil(NativeVisualMeshFixture.parse("mixed"))
    }

    /// The large-text pass is the one that pulls a width back over the line:
    /// three columns that fit a full-screen pane at the default size do not at
    /// an accessibility size.
    func testLargeTextFixturesChangeTheDeckTheyCapture() {
        XCTAssertEqual(
            MeshColumnDeckPolicy.deck(
                availableWidth: fullScreenPaneWidth,
                columnCount: 2,
                textScale: MeshColumnWidth.textScale(for: .accessibility1)
            ),
            .sideBySide
        )
        XCTAssertEqual(
            MeshColumnDeckPolicy.deck(
                availableWidth: typicalPaneWidth,
                columnCount: 2,
                textScale: MeshColumnWidth.textScale(for: .accessibility1)
            ),
            .focused
        )
    }
}
