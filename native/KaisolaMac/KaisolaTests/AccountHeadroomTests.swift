import XCTest
@testable import Kaisola

/// Kaisola reads every account's remaining limit; these cover it finally acting
/// on what it read, before a turn fails rather than after.
final class AccountHeadroomTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

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
            updatedAt: Self.now.timeIntervalSince1970 * 1_000
        )
    }

    /// An account with room says nothing at all.
    func testAHealthyAccountIsNotWarnedAbout() {
        XCTAssertNil(SessionAccountBinding.headroomWarning(
            for: binding("work"),
            readings: [reading("work", [10, 40])],
            now: Self.now
        ))
    }

    /// Michael's own case: 0% on the five-hour window and 100% on the weekly
    /// one. The binding constraint is what "spent" means, so the *worst* window
    /// decides — averaging would have called this account half free.
    func testTheWorstWindowDecidesNotTheAverage() throws {
        let warning = try XCTUnwrap(SessionAccountBinding.headroomWarning(
            for: binding("mofengenden"),
            readings: [reading("mofengenden", [0, 99, 100])],
            now: Self.now
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
            ],
            now: Self.now
        ))
        XCTAssertTrue(warning.contains("mofengend is at 21%"), warning)
        XCTAssertFalse(warning.contains("spare"), "the freest alternative wins: \(warning)")
    }

    /// Swapping a spent account for a nearly-spent one is churn.
    func testANearlyAsFullAlternativeIsNotSuggested() throws {
        let warning = try XCTUnwrap(SessionAccountBinding.headroomWarning(
            for: binding("a"),
            readings: [reading("a", [96]), reading("b", [94])],
            now: Self.now
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
            ],
            now: Self.now
        ))
        XCTAssertFalse(warning.contains("codex-main"), warning)
    }

    /// An account with no reading yet is not assumed to be spent.
    func testAnUnreadAccountIsNotWarnedAbout() {
        XCTAssertNil(SessionAccountBinding.headroomWarning(
            for: binding("fresh"),
            readings: [reading("other", [100])],
            now: Self.now
        ))
    }

    func testPreflightNamesTheBindingWindowAndKeepsFractionalUsage() throws {
        let reset = Self.now.addingTimeInterval(3_600).timeIntervalSince1970
        let current = UsageCenter.ProviderPlanUsage(
            provider: "claude",
            displayName: "Claude",
            profileID: "work",
            profileLabel: "work",
            ok: true,
            sourceLabel: "Claude Agent SDK",
            windows: [
                UsageCenter.PlanWindow(label: "5 hour", usedPercent: 12, resetsAt: reset),
                UsageCenter.PlanWindow(label: "7 day", usedPercent: 97.5, resetsAt: reset),
            ],
            updatedAt: Self.now.timeIntervalSince1970 * 1_000
        )

        let warning = try XCTUnwrap(SessionAccountBinding.headroomWarning(
            for: binding("work"),
            readings: [current],
            now: Self.now
        ))
        XCTAssertTrue(warning.contains("7 day limit"), warning)
        XCTAssertTrue(warning.contains("97.5%"), warning)
    }

    func testStaleOrUndatedCurrentReadingNeverDrivesPreflight() {
        let old = Self.now.addingTimeInterval(-UsageCenter.automaticPlanUsageTTL - 1)
        let stale = UsageCenter.ProviderPlanUsage(
            provider: "claude",
            displayName: "Claude",
            profileID: "work",
            profileLabel: "work",
            ok: true,
            sourceLabel: "Claude Agent SDK",
            windows: [UsageCenter.PlanWindow(label: "7 day", usedPercent: 100, resetsAt: nil)],
            updatedAt: old.timeIntervalSince1970 * 1_000
        )
        let undated = UsageCenter.ProviderPlanUsage(
            provider: "claude",
            displayName: "Claude",
            profileID: "work",
            profileLabel: "work",
            ok: true,
            sourceLabel: "Claude Agent SDK",
            windows: [UsageCenter.PlanWindow(label: "7 day", usedPercent: 100, resetsAt: nil)],
            updatedAt: nil
        )

        XCTAssertNil(SessionAccountBinding.headroomWarning(
            for: binding("work"), readings: [stale], now: Self.now
        ))
        XCTAssertNil(SessionAccountBinding.headroomWarning(
            for: binding("work"), readings: [undated], now: Self.now
        ))
    }

    func testStaleAlternativeIsNotRecommendedAsCurrentHeadroom() throws {
        let staleAt = Self.now.addingTimeInterval(-UsageCenter.automaticPlanUsageTTL - 1)
            .timeIntervalSince1970 * 1_000
        let warning = try XCTUnwrap(SessionAccountBinding.headroomWarning(
            for: binding("work"),
            readings: [
                reading("work", [100]),
                UsageCenter.ProviderPlanUsage(
                    provider: "claude",
                    displayName: "Claude",
                    profileID: "stale-spare",
                    profileLabel: "stale-spare",
                    ok: true,
                    sourceLabel: "Claude Agent SDK",
                    windows: [UsageCenter.PlanWindow(label: "7 day", usedPercent: 2, resetsAt: nil)],
                    updatedAt: staleAt
                ),
            ],
            now: Self.now
        ))
        XCTAssertFalse(warning.contains("stale-spare"), warning)
    }

    func testFailedOrIdentityMismatchedReadingNeverDrivesPreflight() {
        let failed = UsageCenter.ProviderPlanUsage(
            provider: "claude",
            displayName: "Claude",
            profileID: "work",
            profileLabel: "work",
            ok: false,
            sourceLabel: "Claude Agent SDK",
            windows: [UsageCenter.PlanWindow(label: "7 day", usedPercent: 100, resetsAt: nil)],
            updatedAt: Self.now.timeIntervalSince1970 * 1_000
        )
        let wrongIdentity = UsageCenter.ProviderPlanUsage(
            provider: "claude",
            displayName: "Claude",
            profileID: "different-account",
            profileLabel: "work",
            ok: true,
            sourceLabel: "Claude Agent SDK",
            windows: [UsageCenter.PlanWindow(label: "7 day", usedPercent: 100, resetsAt: nil)],
            updatedAt: Self.now.timeIntervalSince1970 * 1_000
        )

        XCTAssertNil(SessionAccountBinding.headroomWarning(
            for: binding("work"), readings: [failed], now: Self.now
        ))
        XCTAssertNil(SessionAccountBinding.headroomWarning(
            for: binding("work"), readings: [wrongIdentity], now: Self.now
        ))
    }
}

final class UsageLimitWindowPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDuplicateWindowLabelsRemainDistinctAndOrdered() {
        let provider = UsageCenter.ProviderPlanUsage(
            provider: "codex",
            displayName: "Codex",
            ok: true,
            sourceLabel: "Codex CLI app-server",
            windows: [
                UsageCenter.PlanWindow(label: "Weekly", usedPercent: 25, resetsAt: 1),
                UsageCenter.PlanWindow(label: "Weekly", usedPercent: nil, resetsAt: 2),
                UsageCenter.PlanWindow(label: "5 hour", usedPercent: 1, resetsAt: 3),
            ],
            updatedAt: 1_800_000_000_000
        )

        XCTAssertEqual(provider.windowRows.map(\.id), [0, 1, 2])
        XCTAssertEqual(provider.windowRows.map(\.window.label), ["Weekly", "Weekly", "5 hour"])
    }

    func testFractionalAndUnknownPercentagesAreTruthful() {
        XCTAssertEqual(SubscriptionUsageMeter.percentCaption(37.5), "37.5%")
        XCTAssertEqual(SubscriptionUsageMeter.percentCaption(37), "37%")
        XCTAssertEqual(SubscriptionUsageMeter.percentCaption(nil), "—")
        XCTAssertEqual(SubscriptionUsageMeter.percentCaption(.nan), "—")
        XCTAssertEqual(SubscriptionUsageMeter.percentCaption(-1), "—")
        XCTAssertEqual(SubscriptionUsageMeter.percentCaption(10_001), "—")

        let unknown = UsageCenter.PlanWindow(label: "7 day", usedPercent: nil, resetsAt: nil)
        XCTAssertEqual(
            SubscriptionUsageMeter.accessibilityValue(for: unknown, now: now),
            "Usage unavailable"
        )
        XCTAssertNil(SubscriptionUsageMeter.resetCaption(resetsAt: .nan, now: now))
        XCTAssertNil(SubscriptionUsageMeter.resetDescription(resetsAt: .infinity, now: now))
    }

    func testFreshnessAcceptsSecondAndMillisecondEpochsButRejectsUnknownAndFuture() {
        func reading(updatedAt: Double?) -> UsageCenter.ProviderPlanUsage {
            UsageCenter.ProviderPlanUsage(
                provider: "codex",
                displayName: "Codex",
                ok: true,
                sourceLabel: "Codex CLI app-server",
                windows: [],
                updatedAt: updatedAt
            )
        }

        XCTAssertTrue(reading(updatedAt: now.timeIntervalSince1970 - 30).isFresh(at: now))
        XCTAssertTrue(reading(updatedAt: (now.timeIntervalSince1970 - 30) * 1_000).isFresh(at: now))
        XCTAssertTrue(reading(
            updatedAt: now.addingTimeInterval(-UsageCenter.automaticPlanUsageTTL + 1).timeIntervalSince1970
        ).isFresh(at: now))
        XCTAssertFalse(reading(
            updatedAt: now.addingTimeInterval(-UsageCenter.automaticPlanUsageTTL).timeIntervalSince1970
        ).isFresh(at: now))
        XCTAssertFalse(reading(updatedAt: nil).isFresh(at: now))
        XCTAssertFalse(reading(updatedAt: .nan).isFresh(at: now))
        XCTAssertFalse(reading(updatedAt: now.addingTimeInterval(61).timeIntervalSince1970).isFresh(at: now))
    }

    func testProvenanceCaptionShowsSourceAndUpdateAgeWithoutInventingMissingTime() {
        XCTAssertEqual(
            SubscriptionCardView.provenanceCaption(
                sourceLabel: "Codex CLI app-server",
                updatedAt: now.addingTimeInterval(-125).timeIntervalSince1970 * 1_000,
                now: now
            ),
            "Codex CLI app-server · updated 2m ago"
        )
        XCTAssertEqual(
            SubscriptionCardView.provenanceCaption(
                sourceLabel: "Codex CLI app-server",
                updatedAt: nil,
                now: now
            ),
            "Codex CLI app-server"
        )
        XCTAssertEqual(
            SubscriptionCardView.provenanceCaption(sourceLabel: "  ", updatedAt: nil, now: now),
            ""
        )
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
