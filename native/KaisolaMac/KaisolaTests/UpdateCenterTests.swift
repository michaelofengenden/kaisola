import XCTest
@testable import Kaisola

/// The pending-update claim. Sparkle's installation block relaunches the app,
/// but not immediately — the quit request is cancelled once and the windows
/// drain first — so every path that could invoke it twice inside that window is
/// covered here. `UpdateCenter.shared` is a singleton, so each test starts from
/// a cleared pending update.
@MainActor
final class UpdateCenterTests: XCTestCase {
    override func setUp() async throws {
        UpdateCenter.shared.clear()
    }

    override func tearDown() async throws {
        UpdateCenter.shared.clear()
    }

    func testPendingUpdateStartsReady() {
        let center = UpdateCenter.shared
        center.markReady(version: "1.2.3") {}
        XCTAssertEqual(center.pendingUpdate?.state, .ready)
        XCTAssertFalse(center.isInstalling)
    }

    func testRepeatedActivationInstallsOnce() {
        let center = UpdateCenter.shared
        var installs = 0
        center.markReady(version: "1.2.3") { installs += 1 }

        XCTAssertTrue(center.installAndRelaunch())
        for _ in 0..<4 {
            XCTAssertFalse(center.installAndRelaunch())
        }
        XCTAssertEqual(installs, 1)
    }

    /// The claim has to be published *before* the block runs, not after: the
    /// block never returns in production, so anything that reads the state
    /// while Sparkle is winding the app down reads it from inside this call.
    func testStateBecomesInstallingBeforeTheBlockRuns() {
        let center = UpdateCenter.shared
        var invocations = 0
        var observedState: UpdateCenter.PendingUpdate.State?
        var observedIsInstalling = false
        var reentrantClaim: Bool?
        center.markReady(version: "1.2.3") {
            invocations += 1
            // Re-enter once only. An unclaimed update would otherwise recurse
            // until the stack runs out instead of failing an assertion.
            guard invocations == 1 else { return }
            observedState = center.pendingUpdate?.state
            observedIsInstalling = center.isInstalling
            reentrantClaim = center.installAndRelaunch()
        }

        XCTAssertTrue(center.installAndRelaunch())
        XCTAssertEqual(invocations, 1)
        XCTAssertEqual(observedState, .installing)
        XCTAssertTrue(observedIsInstalling)
        XCTAssertEqual(reentrantClaim, false)
    }

    /// Two windows, one shared claim: the second window's button is reading the
    /// same state the first window's press moved, so it is already disabled and
    /// its action is a no-op even if it fires anyway.
    func testSecondWindowRestartActionIsDisabledAndInert() {
        let center = UpdateCenter.shared
        var installs = 0
        center.markReady(version: "1.2.3") { installs += 1 }

        // Window A presses Restart and Update.
        XCTAssertTrue(center.installAndRelaunch())
        // Window B's row still shows a pending update, but disabled.
        XCTAssertNotNil(center.pendingUpdate)
        XCTAssertTrue(center.isInstalling)
        // …and firing it anyway changes nothing.
        XCTAssertFalse(center.installAndRelaunch())
        XCTAssertEqual(installs, 1)
    }

    /// Sparkle re-offers the installation block when a termination request is
    /// cancelled, which is exactly what `applicationShouldTerminate` does on its
    /// first pass — during the relaunch this claim started. Taking the re-offer
    /// would re-arm the button the user just pressed.
    func testSparkleReofferDoesNotRearmTheRestartAction() {
        let center = UpdateCenter.shared
        var installs = 0
        center.markReady(version: "1.2.3") { installs += 1 }
        XCTAssertTrue(center.installAndRelaunch())

        var reofferedInstalls = 0
        center.markReady(version: "1.2.3") { reofferedInstalls += 1 }

        XCTAssertTrue(center.isInstalling)
        XCTAssertFalse(center.installAndRelaunch())
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(reofferedInstalls, 0)
    }

    /// A claim on a version that is no longer pending must not install: the
    /// block Sparkle handed over belongs to the update that was replaced.
    func testMarkReadyBeforeAnyClaimStillReplacesTheBlock() {
        let center = UpdateCenter.shared
        var oldInstalls = 0
        var newInstalls = 0
        center.markReady(version: "1.2.3") { oldInstalls += 1 }
        center.markReady(version: "1.2.4") { newInstalls += 1 }

        XCTAssertEqual(center.pendingUpdate?.version, "1.2.4")
        XCTAssertTrue(center.installAndRelaunch())
        XCTAssertEqual(oldInstalls, 0)
        XCTAssertEqual(newInstalls, 1)
    }

    func testClaimWithNoPendingUpdateIsANoOp() {
        XCTAssertFalse(UpdateCenter.shared.installAndRelaunch())
        XCTAssertFalse(UpdateCenter.shared.isInstalling)
    }
}
