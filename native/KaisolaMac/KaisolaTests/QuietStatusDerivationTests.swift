import Foundation
import XCTest
@testable import Kaisola

/// The adapter seam between the rail's live objects and the `QuietSessionStatus`
/// grammar. These rules used to live inline in `QuietProjectRail`, where they
/// were unreachable from a test and two of them were wrong.
@MainActor
final class QuietStatusDerivationTests: XCTestCase {
    private func entry(
        _ kind: AttentionCenter.Kind,
        target: String = "s1"
    ) -> AttentionCenter.Entry {
        AttentionCenter.Entry(
            id: UUID().uuidString,
            kind: kind,
            targetID: target,
            title: "title",
            detail: "detail",
            at: Date()
        )
    }

    // MARK: Attention filtering

    /// `AppModel` raises `.sessionResponded` on EVERY working -> responded edge,
    /// so counting it as needs-you made `doneUnseen` unreachable for terminals.
    func testSessionRespondedIsNotNeedsYou() {
        XCTAssertFalse(QuietStatusDerivation.needsAttention(entries: [entry(.sessionResponded)], for: "s1"))
    }

    func testTurnCompletedIsNotNeedsYou() {
        XCTAssertFalse(QuietStatusDerivation.needsAttention(entries: [entry(.turnCompleted)], for: "s1"))
    }

    func testPermissionIsNeedsYou() {
        XCTAssertTrue(QuietStatusDerivation.needsAttention(entries: [entry(.permission)], for: "s1"))
    }

    /// A terminal BEL is routed to its own `.bell` kind (not `.turnCompleted`)
    /// precisely so it reads as needs-you here, unlike a finished chat turn.
    func testBellIsNeedsYou() {
        XCTAssertTrue(QuietStatusDerivation.needsAttention(entries: [entry(.bell)], for: "s1"))
    }

    func testAttentionOnlyCountsMatchingTarget() {
        let entries = [entry(.permission, target: "other")]
        XCTAssertFalse(QuietStatusDerivation.needsAttention(entries: entries, for: "s1"))
        XCTAssertTrue(QuietStatusDerivation.needsAttention(entries: entries, for: "other"))
    }

    // MARK: Terminal

    /// The green "done, unseen" state is reachable only because a
    /// `.sessionResponded` entry does not read as attention.
    func testRespondedWithSessionRespondedEntryIsDoneUnseen() {
        let status = QuietStatusDerivation.terminal(
            activity: .responded(at: 7),
            exited: false,
            hasPermissionAttention: QuietStatusDerivation.needsAttention(
                entries: [entry(.sessionResponded)],
                for: "s1"
            ),
            respondedAcknowledged: false
        )
        XCTAssertEqual(status, .doneUnseen)
    }

    func testRespondedAndAcknowledgedIsIdle() {
        let status = QuietStatusDerivation.terminal(
            activity: .responded(at: 7),
            exited: false,
            hasPermissionAttention: false,
            respondedAcknowledged: true
        )
        XCTAssertEqual(status, .idle)
    }

    func testPermissionOutranksWorking() {
        let status = QuietStatusDerivation.terminal(
            activity: .working,
            exited: false,
            hasPermissionAttention: QuietStatusDerivation.needsAttention(
                entries: [entry(.permission)],
                for: "s1"
            ),
            respondedAcknowledged: false
        )
        XCTAssertEqual(status, .needsYou)
    }

    /// A terminal BEL must outrank `.working` the same way a permission ask
    /// does — the whole point of routing bells through their own kind.
    func testBellOutranksWorking() {
        let status = QuietStatusDerivation.terminal(
            activity: .working,
            exited: false,
            hasPermissionAttention: QuietStatusDerivation.needsAttention(
                entries: [entry(.bell)],
                for: "s1"
            ),
            respondedAcknowledged: false
        )
        XCTAssertEqual(status, .needsYou)
    }

    /// `.turnCompleted` and `.sessionResponded` entries must NOT read as
    /// needs-you at the terminal level either — only `.permission` and
    /// `.bell` do.
    func testTurnCompletedAndSessionRespondedDoNotOutrankWorking() {
        for kind: AttentionCenter.Kind in [.turnCompleted, .sessionResponded] {
            let status = QuietStatusDerivation.terminal(
                activity: .working,
                exited: false,
                hasPermissionAttention: QuietStatusDerivation.needsAttention(
                    entries: [entry(kind)],
                    for: "s1"
                ),
                respondedAcknowledged: false
            )
            XCTAssertEqual(status, .working, "\(kind) must not read as needs-you")
        }
    }

    func testExitedTerminalIsEnded() {
        let status = QuietStatusDerivation.terminal(
            activity: .working,
            exited: true,
            hasPermissionAttention: false,
            respondedAcknowledged: false
        )
        XCTAssertEqual(status, .ended)
    }

    // MARK: Chat

    /// A clean agent exit publishes a `statusMessage` too, so a disconnected
    /// chat is `.ended`, never `.failed`.
    func testChatCleanExitIsEnded() {
        let status = QuietStatusDerivation.chat(
            isRunning: false,
            isConnected: false,
            hasPendingPermission: false,
            hasPermissionAttention: false,
            statusMessage: "agent exited"
        )
        XCTAssertEqual(status, .ended)
    }

    /// A chat that has never connected yet (no message at all) is also `.ended`.
    func testChatStartingUpIsEnded() {
        let status = QuietStatusDerivation.chat(
            isRunning: false,
            isConnected: false,
            hasPendingPermission: false,
            hasPermissionAttention: false
        )
        XCTAssertEqual(status, .ended)
    }

    func testChatRunningIsWorking() {
        let status = QuietStatusDerivation.chat(
            isRunning: true,
            isConnected: true,
            hasPendingPermission: false,
            hasPermissionAttention: false
        )
        XCTAssertEqual(status, .working)
    }

    func testChatPendingPermissionIsNeedsYou() {
        let status = QuietStatusDerivation.chat(
            isRunning: true,
            isConnected: true,
            hasPendingPermission: true,
            hasPermissionAttention: false
        )
        XCTAssertEqual(status, .needsYou)
    }

    func testChatIdleWhenConnectedAndQuiet() {
        let status = QuietStatusDerivation.chat(
            isRunning: false,
            isConnected: true,
            hasPendingPermission: false,
            hasPermissionAttention: false
        )
        XCTAssertEqual(status, .idle)
    }

    // MARK: Mesh

    /// Interrupted / timed-out meshes are not running, so they must settle to
    /// idle instead of pulsing forever behind a display string.
    func testMeshNotRunningIsIdle() {
        XCTAssertEqual(
            QuietStatusDerivation.mesh(anyColumnRunning: false, hasPermissionAttention: false),
            .idle
        )
    }

    func testMeshRunningIsWorking() {
        XCTAssertEqual(
            QuietStatusDerivation.mesh(anyColumnRunning: true, hasPermissionAttention: false),
            .working
        )
    }

    func testMeshPermissionIsNeedsYou() {
        XCTAssertEqual(
            QuietStatusDerivation.mesh(anyColumnRunning: true, hasPermissionAttention: true),
            .needsYou
        )
    }
}
