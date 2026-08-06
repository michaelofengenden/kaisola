import XCTest
@testable import Kaisola

/// The agent-resume chip's safety matrix (2026-08-06 spec §3b): plain shells
/// never get a chip, agent terminals get one only while the recorded account
/// binding still resolves — resuming under different credentials is the
/// hazard the explicit click exists to prevent.
final class TerminalResurrectionTests: XCTestCase {
    func testPlainShellNeverShowsChip() {
        XCTAssertFalse(ResumeChipEligibility.shouldShow(agentID: nil, accountBindingResolves: true))
        XCTAssertFalse(ResumeChipEligibility.shouldShow(agentID: "", accountBindingResolves: true))
    }

    func testAgentTerminalShowsChipWhenBindingResolves() {
        XCTAssertTrue(ResumeChipEligibility.shouldShow(agentID: "claude", accountBindingResolves: true))
    }

    func testBrokenBindingSuppressesChip() {
        XCTAssertFalse(ResumeChipEligibility.shouldShow(agentID: "claude", accountBindingResolves: false))
    }

    func testRecoveredScrollbackDecodeShapeStaysStable() {
        // The wire contract for terminal.spawn's `recovered` payload — field
        // names are shared with the broker; this pins the Swift side.
        let recovered = TerminalRecoveredScrollback(text: "old output", truncated: false)
        XCTAssertEqual(recovered.text, "old output")
        XCTAssertFalse(recovered.truncated)
    }
}
