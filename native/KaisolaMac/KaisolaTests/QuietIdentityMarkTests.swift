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

    // MARK: - Compact-list drag mapping

    func testDragToTopOfTheCompactListLandsAboveThePinnedProject() {
        // Rail shows: A (pinned) then B, C, D. Dragging D to the top of the
        // compact list must leave the compact order D, B, C.
        let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B", "C", "D"], from: 2, to: 0)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "D", toIndex: 0))
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
