import XCTest
@testable import Kaisola

/// Clear is the one glass setting that trades text contrast for transparency,
/// and the trade has to be bounded in both directions: it must actually buy
/// transparency, and it must never reach someone who has told the system they
/// need contrast.
final class GlassClarityTradeTests: XCTestCase {
    /// It has to be a real step, not the 11% it used to be — an 0.89 multiplier
    /// is not a visible difference and is why "Clear" did not look clear.
    func testClearIsSubstantiallyThinnerThanBalanced() {
        let clear = GlassClarity.clear.veilScale
        let balanced = GlassClarity.balanced.veilScale
        XCTAssertLessThan(clear, balanced * 0.3, "Clear must be a real step, not a nudge")
        XCTAssertGreaterThan(clear, 0, "…and still a veil, not nothing")
        XCTAssertGreaterThan(GlassClarity.frosted.veilScale, balanced)
    }

    /// Only Clear makes the trade; the other two still meet the full floors.
    func testOnlyClearRelaxesContrast() {
        XCTAssertTrue(GlassClarity.clear.relaxesTextContrast)
        XCTAssertFalse(GlassClarity.balanced.relaxesTextContrast)
        XCTAssertFalse(GlassClarity.frosted.relaxesTextContrast)
    }

    /// Increase Contrast and Reduce Transparency are the user telling the
    /// system that legibility outranks appearance. A preference typed into
    /// Kaisola must never override one typed into System Settings.
    func testAccessibilitySettingsOverrideClear() {
        XCTAssertEqual(
            GlassClarity.clear.resolved(increasedContrast: true, reduceTransparency: false),
            .balanced
        )
        XCTAssertEqual(
            GlassClarity.clear.resolved(increasedContrast: false, reduceTransparency: true),
            .balanced
        )
        XCTAssertEqual(
            GlassClarity.clear.resolved(increasedContrast: true, reduceTransparency: true),
            .balanced
        )
    }

    /// With neither set, the choice stands — the guard must not quietly disable
    /// the feature for everyone.
    func testClearSurvivesWhenNoAccessibilitySettingAsksOtherwise() {
        XCTAssertEqual(
            GlassClarity.clear.resolved(increasedContrast: false, reduceTransparency: false),
            .clear
        )
    }

    /// The other clarities are never rewritten, in either direction.
    func testTheGuardOnlyTouchesClear() {
        for clarity in [GlassClarity.frosted, .balanced] {
            XCTAssertEqual(
                clarity.resolved(increasedContrast: true, reduceTransparency: true),
                clarity
            )
        }
    }

    /// Crisp has to be a real step too: at 18pt over a 210pt sidebar nothing
    /// read as itself, which is why "crisp" changed nothing visible.
    func testCrispIsMeaningfullySharperThanBalanced() {
        XCTAssertLessThan(GlassTexture.crisp.blurPoints, GlassTexture.balanced.blurPoints * 0.25)
        XCTAssertGreaterThan(
            GlassTexture.crisp.blurPoints, 0,
            "still a blur — text behind the window must never be readable through it"
        )
        XCTAssertGreaterThan(GlassTexture.soft.blurPoints, GlassTexture.balanced.blurPoints)
    }
}
