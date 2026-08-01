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

    /// v1.1.6 repainted `working` from olive to blue. The rollup's ordering is
    /// about *urgency*, not about hue, so recolouring a state must not move it:
    /// done < working < failed < needsYou, amber outermost.
    func testRecolouringWorkingDidNotChangeTheRollupOrder() {
        let r = QuietRollup.of([.needsYou, .doneUnseen, .working, .failed])
        XCTAssertEqual(r.dots, [.working, .failed, .needsYou])
        XCTAssertEqual(QuietRollup.of([.working, .doneUnseen]).dots, [.doneUnseen, .working])
        XCTAssertEqual(QuietRollup.of([.working, .failed]).dots, [.working, .failed])
    }

    /// Every dot the rollup can emit must actually have a colour to draw with,
    /// which is what `QuietRollupView` assumes when it unwraps `dotColor`.
    func testEveryRollupDotCanBeDrawn() {
        let r = QuietRollup.of([.working, .failed, .needsYou, .doneUnseen])
        for state in r.dots {
            XCTAssertNotNil(state.dotColor, "\(state) reached the rollup with no colour")
        }
    }
}
// Kind-glyph coverage moved to QuietIdentityMarkTests when the text glyphs
// became drawn identity marks (v4.4 "quiet fleet / Safari").
