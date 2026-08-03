import XCTest
@testable import Kaisola

/// Kaisola reads every account's remaining limit; these cover it finally acting
/// on what it read, before a turn fails rather than after.
final class AccountHeadroomTests: XCTestCase {
    private func binding(_ label: String) -> SessionAccountBinding {
        SessionAccountBinding(
            accountID: label,
            provider: .claude,
            label: label,
            configDirectory: "/Users/x/.claude-\(label)"
        )
    }

    private func reading(
        _ label: String,
        _ percents: [Double],
        provider: String = "claude"
    ) -> UsageCenter.ProviderPlanUsage {
        UsageCenter.ProviderPlanUsage(
            provider: provider,
            displayName: provider.capitalized,
            profileID: label,
            profileLabel: label,
            ok: true,
            sourceLabel: "test",
            experimental: false,
            account: "\(label)@example.com",
            plan: "max",
            windows: percents.enumerated().map { index, percent in
                UsageCenter.PlanWindow(label: "w\(index)", usedPercent: percent, resetsAt: nil)
            },
            message: nil,
            updatedAt: 0
        )
    }

    /// An account with room says nothing at all.
    func testAHealthyAccountIsNotWarnedAbout() {
        XCTAssertNil(SessionAccountBinding.headroomWarning(
            for: binding("work"),
            readings: [reading("work", [10, 40])]
        ))
    }

    /// Michael's own case: 0% on the five-hour window and 100% on the weekly
    /// one. The binding constraint is what "spent" means, so the *worst* window
    /// decides — averaging would have called this account half free.
    func testTheWorstWindowDecidesNotTheAverage() throws {
        let warning = try XCTUnwrap(SessionAccountBinding.headroomWarning(
            for: binding("mofengenden"),
            readings: [reading("mofengenden", [0, 99, 100])]
        ))
        XCTAssertTrue(warning.contains("mofengenden is 100% used"), warning)
    }

    /// The useful half: name the subscription that still has room.
    func testAFreerAccountOfTheSameProviderIsNamed() throws {
        let warning = try XCTUnwrap(SessionAccountBinding.headroomWarning(
            for: binding("mofengenden"),
            readings: [
                reading("mofengenden", [100]),
                reading("mofengend", [21]),
                reading("spare", [64]),
            ]
        ))
        XCTAssertTrue(warning.contains("mofengend is at 21%"), warning)
        XCTAssertFalse(warning.contains("spare"), "the freest alternative wins: \(warning)")
    }

    /// Swapping a spent account for a nearly-spent one is churn.
    func testANearlyAsFullAlternativeIsNotSuggested() throws {
        let warning = try XCTUnwrap(SessionAccountBinding.headroomWarning(
            for: binding("a"),
            readings: [reading("a", [96]), reading("b", [94])]
        ))
        XCTAssertFalse(warning.contains("b is at"), warning)
    }

    /// A Codex subscription is no help to a Claude session.
    func testAnAlternativeFromAnotherProviderIsNotOffered() throws {
        let warning = try XCTUnwrap(SessionAccountBinding.headroomWarning(
            for: binding("claude-main"),
            readings: [
                reading("claude-main", [99]),
                reading("codex-main", [3], provider: "codex"),
            ]
        ))
        XCTAssertFalse(warning.contains("codex-main"), warning)
    }

    /// An account with no reading yet is not assumed to be spent.
    func testAnUnreadAccountIsNotWarnedAbout() {
        XCTAssertNil(SessionAccountBinding.headroomWarning(
            for: binding("fresh"),
            readings: [reading("other", [100])]
        ))
    }
}
