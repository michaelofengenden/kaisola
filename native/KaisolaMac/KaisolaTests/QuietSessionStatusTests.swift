import XCTest
@testable import Kaisola

final class QuietSessionStatusTests: XCTestCase {
    func testTerminalDerivation() {
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .working, exited: false, hasAttention: false, respondedAcknowledged: false), .working)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .working, exited: true, hasAttention: false, respondedAcknowledged: false), .ended)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .responded(at: 5), exited: false, hasAttention: false, respondedAcknowledged: false), .doneUnseen)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .responded(at: 5), exited: false, hasAttention: false, respondedAcknowledged: true), .idle)
        // attention (bell / permission) outranks everything on a live terminal
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .working, exited: false, hasAttention: true, respondedAcknowledged: false), .needsYou)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .idle, exited: false, hasAttention: false, respondedAcknowledged: false), .idle)
    }

    func testChatDerivation() {
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: true, isConnected: true, hasPendingPermission: false, hasAttention: false, statusMessage: nil), .working)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: true, isConnected: true, hasPendingPermission: true, hasAttention: false, statusMessage: nil), .needsYou)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: false, hasPendingPermission: false, hasAttention: false, statusMessage: "agent exited"), .failed)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: true, hasPendingPermission: false, hasAttention: true, statusMessage: nil), .needsYou)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: true, hasPendingPermission: false, hasAttention: false, statusMessage: nil), .idle)
    }

    func testMeshDerivation() {
        XCTAssertEqual(QuietSessionStatus.mesh(stageIsIdle: false, hasAttention: false), .working)
        XCTAssertEqual(QuietSessionStatus.mesh(stageIsIdle: true, hasAttention: true), .needsYou)
        XCTAssertEqual(QuietSessionStatus.mesh(stageIsIdle: true, hasAttention: false), .idle)
    }

    func testDotPresence() {
        XCTAssertNil(QuietSessionStatus.idle.accessibilityWord)
        XCTAssertNil(QuietSessionStatus.ended.accessibilityWord)
        XCTAssertEqual(QuietSessionStatus.needsYou.accessibilityWord, "needs you")
        XCTAssertEqual(QuietSessionStatus.working.accessibilityWord, "working")
        XCTAssertEqual(QuietSessionStatus.doneUnseen.accessibilityWord, "done")
        XCTAssertEqual(QuietSessionStatus.failed.accessibilityWord, "failed")
        XCTAssertTrue(QuietSessionStatus.ended.isDimmed)
        XCTAssertFalse(QuietSessionStatus.idle.isDimmed)
    }
}
