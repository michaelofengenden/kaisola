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

/// The chat account menu's idea of "current", kept pure so the menu cannot
/// invent its own.
final class ChatAccountMenuRowTests: XCTestCase {
    private func binding(_ id: String?) -> SessionAccountBinding {
        SessionAccountBinding(
            accountID: id,
            provider: .claude,
            label: id ?? "Project/default",
            configDirectory: "/Users/x/.claude-test"
        )
    }

    /// The "Project/default" row is current exactly when the binding names no
    /// account, and a named row exactly when its profile id matches. A chat
    /// with no binding at all (a pre-account legacy descriptor) reads as
    /// default rather than as some named account it never had.
    func testTheAccountMenuMarksTheRightRowCurrent() {
        XCTAssertTrue(SessionAccountBinding.menuRowIsCurrent(binding: binding("work"), profileID: "work"))
        XCTAssertFalse(SessionAccountBinding.menuRowIsCurrent(binding: binding("work"), profileID: "personal"))
        XCTAssertFalse(SessionAccountBinding.menuRowIsCurrent(binding: binding("work"), profileID: nil))
        XCTAssertTrue(SessionAccountBinding.menuRowIsCurrent(binding: binding(nil), profileID: nil))
        XCTAssertFalse(SessionAccountBinding.menuRowIsCurrent(binding: binding(nil), profileID: "work"))
        XCTAssertTrue(SessionAccountBinding.menuRowIsCurrent(binding: nil, profileID: nil))
        XCTAssertFalse(SessionAccountBinding.menuRowIsCurrent(binding: nil, profileID: "work"))
    }
}

/// The per-chat model override's env mapping — the same variables the
/// app-wide Models & Keys routing sets, so the CLIs need nothing new.
final class SessionModelOverrideTests: XCTestCase {
    func testEachProviderGetsItsOwnVariable() {
        let claude = SessionModelOverride.applying("opus", agentID: "claude-code", to: [:])
        XCTAssertEqual(claude["ANTHROPIC_MODEL"], "opus")
        XCTAssertNil(claude["OPENAI_MODEL"])
        let codex = SessionModelOverride.applying("gpt-x", agentID: "codex", to: [:])
        XCTAssertEqual(codex["OPENAI_MODEL"], "gpt-x")
        XCTAssertNil(codex["ANTHROPIC_MODEL"])
    }

    /// An unknown agent, an empty string, or a hostile value leaves the
    /// environment untouched — the override is inert, never guessed.
    func testInvalidOverridesAreInert() {
        XCTAssertEqual(SessionModelOverride.applying("m", agentID: "custom-thing", to: ["A": "1"]), ["A": "1"])
        XCTAssertEqual(SessionModelOverride.applying("   ", agentID: "claude-code", to: [:]), [:])
        XCTAssertEqual(SessionModelOverride.applying(nil, agentID: "claude-code", to: [:]), [:])
        XCTAssertEqual(
            SessionModelOverride.applying("bad\u{0}model", agentID: "claude-code", to: [:]),
            [:]
        )
        XCTAssertEqual(
            SessionModelOverride.applying(String(repeating: "m", count: 200), agentID: "claude-code", to: [:]),
            [:]
        )
    }

    func testTheOverrideWinsOverAnAppWideRoutingValue() {
        let env = SessionModelOverride.applying(
            "haiku",
            agentID: "claude-code",
            to: ["ANTHROPIC_MODEL": "sonnet"]
        )
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "haiku")
    }

    /// The persisted chat descriptor round-trips the override, and a legacy
    /// archive without the key decodes as nil rather than failing.
    func testDescriptorRoundTripsAndLegacyDecodes() throws {
        let descriptor = NativeRestorableAgentChatDescriptor(
            id: "chat-1",
            projectID: "nproj_abc",
            agentID: "claude-code",
            workspacePath: "/tmp/x",
            acpSessionID: "s1",
            title: "T",
            queuedPrompts: ["later"],
            modelOverride: "opus"
        )
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(NativeRestorableAgentChatDescriptor.self, from: data)
        XCTAssertEqual(decoded.modelOverride, "opus")

        let legacy = Data("""
        {"id":"chat-2","projectID":"nproj_abc","agentID":"codex","workspacePath":"/tmp/x","queuedPrompts":[]}
        """.utf8)
        let old = try JSONDecoder().decode(NativeRestorableAgentChatDescriptor.self, from: legacy)
        XCTAssertNil(old.modelOverride)
    }
}
