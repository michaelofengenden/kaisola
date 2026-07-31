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
}
// Kind-glyph coverage moved to QuietIdentityMarkTests when the text glyphs
// became drawn identity marks (v4.4 "quiet fleet / Safari").
