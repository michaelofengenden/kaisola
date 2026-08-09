import Foundation
import Sparkle
import XCTest
@testable import Kaisola

/// Racing rules for explicit Sparkle update checks (issue #379).
///
/// Four surfaces trigger a check — the app menu, the command palette, Settings'
/// "Check Now", and the `.kaisolaCheckForUpdates` notification — and all four
/// funnel into `NativeUpdateController.checkForUpdates`. Sparkle's scheduled
/// cycles report through the same delegate the explicit ones do, so a trigger
/// landing on a live cycle and a scheduled cycle finishing mid-check are both
/// ordinary runtime events, not corner cases.
@MainActor
final class NativeUpdateCheckRaceTests: XCTestCase {
    private func makeArbiter() -> (UpdateCheckArbiter, UpdateCenter) {
        let center = UpdateCenter()
        return (UpdateCheckArbiter(center: center), center)
    }

    func testTriggersDuringALiveCheckAreIgnored() {
        let (arbiter, center) = makeArbiter()

        XCTAssertTrue(arbiter.beginExplicitCheck(), "the menu trigger starts the cycle")
        XCTAssertEqual(center.checkStatus, .checking(generation: 1))

        // Settings' "Check Now" and the command palette, both landing while the
        // menu's cycle is still running. Neither may reach Sparkle, and neither
        // may move the generation the running cycle will report against.
        XCTAssertFalse(arbiter.beginExplicitCheck(), "the Settings trigger is a no-op")
        XCTAssertFalse(arbiter.beginExplicitCheck(), "the palette trigger is a no-op")
        XCTAssertEqual(center.checkStatus, .checking(generation: 1))

        arbiter.finish(cycle: .explicit, outcome: .upToDate)
        guard case .upToDate = center.checkStatus else {
            return XCTFail("the one real cycle should settle the status, got \(center.checkStatus)")
        }
        XCTAssertFalse(arbiter.isChecking)
    }

    func testAScheduledCycleFinishingDoesNotResolveTheExplicitCheck() {
        let (arbiter, center) = makeArbiter()
        XCTAssertTrue(arbiter.beginExplicitCheck())

        // Sparkle cancels a scheduled cycle to make room for a user-initiated
        // one, and that cancellation arrives as a finished cycle of its own.
        // Resolving on it would stop the spinner on a check that never ran and
        // leave the real completion with nothing to report against.
        arbiter.finish(cycle: .background, outcome: .failed(reason: "cancelled"))
        XCTAssertEqual(center.checkStatus, .checking(generation: 1))
        XCTAssertTrue(arbiter.isChecking)

        arbiter.finish(cycle: .explicit, outcome: .upToDate)
        guard case .upToDate = center.checkStatus else {
            return XCTFail("the explicit cycle should settle the status, got \(center.checkStatus)")
        }
    }

    func testAScheduledCycleOnItsOwnLeavesTheStatusIdle() {
        let (arbiter, center) = makeArbiter()

        arbiter.finish(cycle: .background, outcome: .foundUpdate)
        arbiter.finish(cycle: .background, outcome: .failed(reason: "the feed is unreachable"))

        XCTAssertEqual(center.checkStatus, .idle(lastChecked: nil))
        XCTAssertFalse(arbiter.isChecking)
    }

    func testALateCompletionCannotRewriteASettledStatus() {
        let (arbiter, center) = makeArbiter()
        XCTAssertTrue(arbiter.beginExplicitCheck())

        arbiter.finish(cycle: .explicit, outcome: .upToDate)
        arbiter.finish(cycle: .explicit, outcome: .failed(reason: "the feed is unreachable"))

        guard case .upToDate = center.checkStatus else {
            return XCTFail("a second completion should be dropped, got \(center.checkStatus)")
        }
    }

    func testTheNextTriggerRunsOnceTheCycleResolves() {
        let (arbiter, center) = makeArbiter()
        XCTAssertTrue(arbiter.beginExplicitCheck())
        arbiter.finish(cycle: .explicit, outcome: .failed(reason: "the feed is unreachable"))

        XCTAssertTrue(arbiter.beginExplicitCheck(), "checking again after a failure is allowed")
        XCTAssertEqual(center.checkStatus, .checking(generation: 2))
    }

    /// Finding an update ends the spinner on the check axis and hands the rest
    /// to Sparkle's own UI, so the arbiter has to let go of the cycle too —
    /// otherwise "Check Now" could never bring that window back to the front.
    func testFindingAnUpdateReleasesTheCycle() {
        let (arbiter, center) = makeArbiter()
        XCTAssertTrue(arbiter.beginExplicitCheck())

        arbiter.finish(cycle: .explicit, outcome: .foundUpdate)

        guard case let .idle(lastChecked) = center.checkStatus else {
            return XCTFail("finding an update should return to idle, got \(center.checkStatus)")
        }
        XCTAssertNotNil(lastChecked)
        XCTAssertTrue(arbiter.beginExplicitCheck())
    }

    func testOnlyUserInitiatedSparkleChecksCountAsExplicit() {
        XCTAssertEqual(UpdateCheckArbiter.Cycle(.updates), .explicit)
        XCTAssertEqual(UpdateCheckArbiter.Cycle(.updatesInBackground), .background)
        XCTAssertEqual(UpdateCheckArbiter.Cycle(.updateInformation), .background)
    }
}
