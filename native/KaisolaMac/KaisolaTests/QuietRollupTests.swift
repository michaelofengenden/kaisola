import XCTest
@testable import Kaisola

final class QuietRollupTests: XCTestCase {
    func testRollupCountsActiveSessionsOnly() {
        let r = QuietRollup.of([.idle, .working, .needsYou, .doneUnseen, .ended, .working])
        XCTAssertEqual(r.total, 4) // idle+ended are silent, not counted
        XCTAssertEqual(r.dots.last, .needsYou) // amber outermost
        XCTAssertTrue(r.dots.contains(.working))
        XCTAssertLessThanOrEqual(r.dots.count, 3)
    }

    func testRollupDeduplicatesStates() {
        let r = QuietRollup.of([.working, .working, .working])
        XCTAssertEqual(r.total, 3)
        XCTAssertEqual(r.dots, [.working]) // one dot per distinct state
    }

    func testFullyIdleProjectIsSilent() {
        let r = QuietRollup.of([.idle, .ended, .idle])
        XCTAssertEqual(r.total, 0)
        XCTAssertTrue(r.dots.isEmpty)
    }

    func testGlyphs() {
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: "Claude Code", processName: nil), "✦")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: "codex", processName: nil), "⌁")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: nil, processName: "ssh"), "⇅")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: "mesh", processName: nil), "⌗")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: nil, processName: "zsh"), "❯")
        XCTAssertEqual(QuietKindGlyph.glyph(agentName: nil, processName: nil), "❯")
    }
}
