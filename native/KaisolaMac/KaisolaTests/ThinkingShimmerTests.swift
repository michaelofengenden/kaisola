import XCTest
@testable import Kaisola

/// The thinking shimmer's geometry and pace, held without a screen: the
/// `locations` function is pure, so the sweep's shape is asserted here rather
/// than eyeballed in a capture.
final class ThinkingShimmerTests: XCTestCase {
    func testSweepLocationsAreMonotoneAndClearBothEdges() {
        for phase in [0.0, 0.5, 1.0] {
            let locations = ThinkingShimmerMotion.locations(phase: phase)
            XCTAssertEqual(locations.count, 5)
            for (earlier, later) in zip(locations, locations.dropFirst()) {
                XCTAssertLessThanOrEqual(earlier, later, "stops crossed at phase \(phase)")
            }
        }
        XCTAssertLessThanOrEqual(
            ThinkingShimmerMotion.startLocations.max() ?? .infinity,
            0,
            "the highlight materialises inside the word instead of entering it"
        )
        XCTAssertGreaterThanOrEqual(
            ThinkingShimmerMotion.endLocations.min() ?? -.infinity,
            1,
            "the highlight dies inside the word instead of leaving it"
        )
    }

    func testLocationsFunctionIsPureAndAdvancesWithPhase() {
        XCTAssertEqual(
            ThinkingShimmerMotion.locations(phase: 0.3),
            ThinkingShimmerMotion.locations(phase: 0.3)
        )
        let early = ThinkingShimmerMotion.locations(phase: 0.2)
        let late = ThinkingShimmerMotion.locations(phase: 0.8)
        for (before, after) in zip(early, late) {
            XCTAssertLessThan(before, after, "the sweep must travel with phase")
        }
    }

    func testSweepPaceAndHighlightWidthStayBounded() {
        XCTAssertGreaterThanOrEqual(
            ThinkingShimmerMotion.period, 1.0,
            "below one second the sweep is a strobe"
        )
        XCTAssertLessThanOrEqual(
            ThinkingShimmerMotion.period, 2.5,
            "above two and a half seconds it reads as a hang"
        )
        XCTAssertGreaterThan(ThinkingShimmerMotion.highlightWidth, 0.05)
        XCTAssertLessThan(ThinkingShimmerMotion.highlightWidth, 0.35)
        XCTAssertGreaterThanOrEqual(
            ThinkingShimmerMotion.overscan, ThinkingShimmerMotion.highlightWidth,
            "an overscan under the highlight width cannot clear the edges"
        )
    }

    func testHighlightLandsExactlyOnThePrimaryInk() {
        for isDark in [false, true] {
            let resting = KaisolaInk.alpha(.secondary, isDark: isDark)
            let primary = KaisolaInk.alpha(.primary, isDark: isDark)
            XCTAssertEqual(
                ThinkingShimmerMotion.highlightAlpha(resting: resting, primary: primary),
                primary,
                "the shimmer is secondary ink becoming primary ink, not a new colour"
            )
        }
    }
}
