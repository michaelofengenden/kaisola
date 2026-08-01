import SwiftUI
import XCTest
@testable import Kaisola

/// The rail's three pure derivations: who a row belongs to (`QuietIdentity`),
/// what a row is called when its title carries no information
/// (`QuietRailTitle`), and where a compact-list drag lands in the persisted
/// project order once the active project is pinned out of that list
/// (`QuietRailOrder`).
final class QuietIdentityMarkTests: XCTestCase {

    // MARK: - Identity mapping

    func testClaudeAgentsMapToTheStarburst() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "Claude Code", processName: nil), .claude)
        XCTAssertEqual(QuietIdentity.identity(agentName: "claude", processName: "node"), .claude)
        XCTAssertEqual(QuietIdentity.identity(agentName: "CLAUDE", processName: nil), .claude)
    }

    func testCodexAndOpenAIMapToTheOpenAIMark() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "codex", processName: nil), .openai)
        XCTAssertEqual(QuietIdentity.identity(agentName: "Codex CLI", processName: nil), .openai)
        XCTAssertEqual(QuietIdentity.identity(agentName: "OpenAI", processName: nil), .openai)
    }

    func testMeshMapsToTheMeshTile() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "mesh", processName: nil), .mesh)
        XCTAssertEqual(QuietIdentity.identity(agentName: "Mesh", processName: "node"), .mesh)
    }

    func testSSHProcessMapsToTheTransferTile() {
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "ssh"), .ssh)
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "SSH"), .ssh)
    }

    func testPlainShellsAreTheDefault() {
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "zsh"), .shell)
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: nil), .shell)
        // An agent name that is only whitespace has no letter to fall back to.
        XCTAssertEqual(QuietIdentity.identity(agentName: "   ", processName: nil), .shell)
        XCTAssertEqual(QuietIdentity.identity(agentName: "", processName: nil), .shell)
    }

    func testUnrecognizedAgentsFallBackToTheirInitial() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "Gemini", processName: "node"), .letter("G"))
        XCTAssertEqual(QuietIdentity.identity(agentName: "aider", processName: nil), .letter("A"))
        XCTAssertEqual(QuietIdentity.identity(agentName: "  opencode", processName: nil), .letter("O"))
    }

    /// Documents the precedence the spec lists: the transport is checked before
    /// the initial fallback, so an unrecognized agent reached over ssh still
    /// reads as an ssh row.
    func testSSHTransportWinsOverAnUnrecognizedAgentName() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "Gemini", processName: "ssh"), .ssh)
    }

    /// …but a recognized agent still wins over the transport.
    func testRecognizedAgentWinsOverTheSSHTransport() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "Claude Code", processName: "ssh"), .claude)
    }

    // MARK: - Display-title fallback

    func testTitleThatSaysSomethingIsKeptVerbatim() {
        XCTAssertEqual(
            QuietRailTitle.displayTitle(rawTitle: "build the rail", projectName: "Kaisola", processName: "zsh", ordinal: 1),
            "build the rail"
        )
    }

    func testSessionsNamedAfterTheirProjectBecomeProcessOrdinals() {
        // Three same-named sessions must read as three different rows.
        let titles = (1...3).map { ordinal in
            QuietRailTitle.displayTitle(rawTitle: "Kaisola", projectName: "Kaisola", processName: "zsh", ordinal: ordinal)
        }
        XCTAssertEqual(titles, ["zsh · 1", "zsh · 2", "zsh · 3"])
        XCTAssertEqual(Set(titles).count, 3)
    }

    func testProjectNamedTitleWithoutAProcessFallsBackToTerminalOrdinal() {
        XCTAssertEqual(
            QuietRailTitle.displayTitle(rawTitle: "Kaisola", projectName: "Kaisola", processName: nil, ordinal: 2),
            "Terminal 2"
        )
    }

    func testTitleComparisonIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(
            QuietRailTitle.displayTitle(rawTitle: "  kaisola \n", projectName: "Kaisola", processName: "fish", ordinal: 4),
            "fish · 4"
        )
    }

    // MARK: - Row width budget

    /// The regression this covers: at the default sidebar width a session title
    /// must read as a title, not as an abbreviation. v1.1.4 left it 56pt —
    /// "Audit K…" — because the row's fixed tokens were charged against it and
    /// its trailing lane could still be compressed below its own first glyph.
    func testSessionTitleGetsMostOfTheRowAtTheDefaultSidebarWidth() {
        let titleFont = NSFont.systemFont(ofSize: 13)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let timeWidth = ("now" as NSString).size(withAttributes: [.font: timeFont]).width

        let available = QuietRowBudget.titleWidth(
            sidebarWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            timeLabelWidth: timeWidth,
            showsReveal: false
        )
        XCTAssertGreaterThan(available, 100, "the title lane lost its share of the row again")

        // Stated the way the complaint was: how much of a real title is legible.
        let sample = "Audit Kaisola Sidebar parity"
        var visible = 0
        for count in 1...sample.count {
            let candidate = String(sample.prefix(count)) + "…"
            let width = (candidate as NSString).size(withAttributes: [.font: titleFont]).width
            if width <= available { visible = count } else { break }
        }
        XCTAssertGreaterThanOrEqual(visible, 15, "only \(visible) characters survive at 200pt")

        // The hover-only reveal control may cost the title, but never this much.
        XCTAssertGreaterThan(
            QuietRowBudget.titleWidth(
                sidebarWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
                timeLabelWidth: timeWidth,
                showsReveal: true
            ),
            80
        )
    }

    // MARK: - Hierarchy step

    /// The complaint this covers: after the v1.1.5 width-budget work a session
    /// sat 10pt in from its project row, which the eye read as a ragged edge
    /// rather than as nesting. The step is now paid for out of the wider
    /// default sidebar, so it does not come back out of the title.
    func testSessionsSitClearlyDeeperThanTheirProjectRow() {
        XCTAssertGreaterThan(
            QuietRowBudget.sessionIndent,
            QuietRowBudget.projectIndent,
            "sessions must not start on the same column as their project"
        )
        XCTAssertGreaterThanOrEqual(
            QuietRowBudget.indentStep,
            QuietIdentityMarkView.slot,
            "the hierarchy step is narrower than one identity mark — it reads as ragged, not nested"
        )
    }

    /// Item 3 and item 2 are one trade: the indent grew, so the sidebar had to.
    /// Assert the *outcome* — that the wider default really did buy both — so a
    /// future width tweak cannot quietly re-flatten the rail.
    func testTheWiderDefaultSidebarPaysForTheDeeperIndent() {
        XCTAssertGreaterThan(NativeWorkspaceChrome.projectSidebarIdealWidth, 200)
        XCTAssertGreaterThan(
            NativeWorkspaceChrome.projectSidebarMaximumWidth,
            NativeWorkspaceChrome.projectSidebarIdealWidth
        )
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarMinimumWidth, 168, "the narrow rail must not move")

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let timeWidth = ("now" as NSString).size(withAttributes: [.font: timeFont]).width

        // The title lane at the new default is wider than it was at the old
        // one, *after* paying for the deeper indent.
        let now = QuietRowBudget.titleWidth(
            sidebarWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            timeLabelWidth: timeWidth,
            showsReveal: false
        )
        let before = 200 - 18 - 10 - QuietIdentityMarkView.slot - 8 - 5 - (timeWidth + 5 + 6)
        XCTAssertGreaterThan(now, before, "the wider sidebar was spent entirely on the indent")
    }

    // MARK: - Active project glass

    /// The whole risk of a tinted row is drift toward candy. These are the
    /// ceilings the mock approved; the relationships between them are what keep
    /// it reading as glass.
    func testActiveProjectGlassStaysRestrained() {
        XCTAssertGreaterThan(QuietActiveGlass.topFillOpacity, QuietActiveGlass.bottomFillOpacity,
                             "a flat fill is a coloured chip, not glass")
        XCTAssertLessThan(QuietActiveGlass.topFillOpacity, 0.25, "the tint is a wash, not a fill")
        XCTAssertGreaterThan(QuietActiveGlass.strokeOpacity, QuietActiveGlass.topFillOpacity,
                             "the edge must read against the fill")
        XCTAssertLessThan(QuietActiveGlass.strokeOpacity, 0.4, "that is an outline, not a hairline")

        // The lit top edge: bright in light mode, barely there in dark, where
        // white at light-mode strength reads as a seam.
        XCTAssertGreaterThan(
            QuietActiveGlass.highlightOpacity(dark: false),
            QuietActiveGlass.highlightOpacity(dark: true)
        )
        XCTAssertLessThan(QuietActiveGlass.highlightOpacity(dark: true), 0.2)
        XCTAssertLessThan(QuietActiveGlass.highlightOpacity(dark: false), 0.5)

        // It is a *top* highlight: it has to be gone before the row's bottom
        // edge, or it is a second fill.
        XCTAssertLessThanOrEqual(QuietActiveGlass.highlightFalloff, 0.6)
        XCTAssertGreaterThan(QuietActiveGlass.highlightFalloff, 0)
    }

    // MARK: - Compact-list drag mapping

    func testDragToTopOfTheCompactListLandsBelowThePinnedProject() {
        // Rail shows: A (pinned, store index 0) then B, C, D. Dragging D to the
        // top of the compact list must leave the compact order D, B, C without
        // displacing A from the slot it holds in the persisted order.
        let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B", "C", "D"], from: 2, to: 0)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "D", toIndex: 1))
    }

    func testDragToTopTakesSlotZeroWhenThePinnedProjectIsNotThere() {
        // Store order B, A, C, D with A active: the first compact slot *is*
        // store index 0, so a compact-top drop lands there.
        let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["B", "A", "C", "D"], from: 2, to: 0)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "D", toIndex: 0))
    }

    /// The mapping is only correct if the store's remove-then-insert really
    /// reproduces the dragged compact order *and* leaves the pinned project put.
    func testDragToTopKeepsThePinnedProjectAtItsStoredIndex() {
        let ordered = ["A", "B", "C", "D"]
        guard let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ordered, from: 2, to: 0) else {
            return XCTFail("expected a move")
        }
        var stored = ordered
        let from = stored.firstIndex(of: move.id)!
        let clamped = max(0, min(move.toIndex, stored.count - 1))
        stored.insert(stored.remove(at: from), at: clamped)
        XCTAssertEqual(stored, ["A", "D", "B", "C"])
        XCTAssertEqual(stored.firstIndex(of: "A"), 0)
        XCTAssertEqual(stored.filter { $0 != "A" }, ["D", "B", "C"])
    }

    func testDragMapsThroughAnActiveProjectHeldInTheMiddleOfTheStoreOrder() {
        // Store order B, A, C, D with A active: the compact list is B, C, D.
        // Dragging B to the end must land B last in the store order too.
        let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["B", "A", "C", "D"], from: 0, to: 3)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "B", toIndex: 3))
    }

    func testDragOneStepDownSkipsThePinnedProject() {
        // Compact list B, C, D; move B below C.
        let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B", "C", "D"], from: 0, to: 2)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "B", toIndex: 2))
    }

    func testNoOpDragsAreIgnored() {
        XCTAssertNil(QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B", "C"], from: 0, to: 0))
        XCTAssertNil(QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B", "C"], from: 0, to: 1))
    }

    func testOutOfRangeDragsAreIgnored() {
        XCTAssertNil(QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B"], from: 4, to: 0))
        XCTAssertNil(QuietRailOrder.moveIndex(activeID: "A", orderedIDs: [], from: 0, to: 0))
    }

    func testWithoutAnActiveProjectTheCompactListIsTheStoreOrder() {
        let move = QuietRailOrder.moveIndex(activeID: nil, orderedIDs: ["A", "B", "C"], from: 2, to: 0)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "C", toIndex: 0))
    }

    /// The rail's mapping must agree with `NativeSessionStore.moveProject`'s
    /// remove-then-insert, so the resulting compact list is what was dragged.
    func testMappedIndexReproducesTheDraggedCompactOrder() {
        let ordered = ["B", "A", "C", "D"]
        guard let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ordered, from: 0, to: 3) else {
            return XCTFail("expected a move")
        }
        var stored = ordered
        let from = stored.firstIndex(of: move.id)!
        let clamped = max(0, min(move.toIndex, stored.count - 1))
        stored.insert(stored.remove(at: from), at: clamped)
        XCTAssertEqual(stored.filter { $0 != "A" }, ["C", "D", "B"])
    }
}
