import XCTest
@testable import KaisolaMacPreview

/// `UsageCenter` — the session-lifetime usage aggregator behind the Settings
/// Usage tab and the footer cost chip. Each test uses an isolated instance so
/// the shared singleton is never clobbered.
@MainActor
final class UsageCenterTests: XCTestCase {
    private func makeCenter() -> UsageCenter { UsageCenter() }

    // MARK: - record: latest + peak

    func testRecordCreatesEntryWithZeroTurns() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 120, max: 1000)

        let entry = center.byChat["a"]
        XCTAssertEqual(entry?.title, "Alpha")
        XCTAssertEqual(entry?.agentID, "claude-code")
        XCTAssertEqual(entry?.latestUsed, 120)
        XCTAssertEqual(entry?.latestMax, 1000)
        XCTAssertEqual(entry?.peakUsed, 120)
        XCTAssertEqual(entry?.turns, 0)
    }

    func testRecordAdvancesLatestAndKeepsPeakHighWater() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 100, max: 1000)
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 250, max: 1000)
        // Context shrinks after a compaction: latest drops, peak must NOT.
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 80, max: 1000)

        let entry = center.byChat["a"]
        XCTAssertEqual(entry?.latestUsed, 80, "latest tracks the most recent reading")
        XCTAssertEqual(entry?.peakUsed, 250, "peak is the session high-water mark")
        XCTAssertEqual(center.byChat.count, 1, "same chat id updates in place")
    }

    func testRecordRefreshesTitleAndAgentAndPreservesTurns() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 100, max: 1000)
        center.recordTurn(chatID: "a")
        center.record(chatID: "a", title: "Alpha (renamed)", agentID: "codex", usage: 140, max: 2000)

        let entry = center.byChat["a"]
        XCTAssertEqual(entry?.title, "Alpha (renamed)")
        XCTAssertEqual(entry?.agentID, "codex")
        XCTAssertEqual(entry?.latestMax, 2000)
        XCTAssertEqual(entry?.turns, 1, "turns survive later records")
    }

    // MARK: - turns

    func testRecordTurnIncrements() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 100, max: 1000)
        center.recordTurn(chatID: "a")
        center.recordTurn(chatID: "a")
        center.recordTurn(chatID: "a")
        XCTAssertEqual(center.byChat["a"]?.turns, 3)
    }

    func testRecordTurnOnUnknownChatIsNoOp() {
        let center = makeCenter()
        center.recordTurn(chatID: "ghost")
        XCTAssertTrue(center.byChat.isEmpty, "a turn without any usage does not conjure an entry")
    }

    // MARK: - ordering

    func testAllOrderedByPeakDescending() {
        let center = makeCenter()
        center.record(chatID: "low", title: "Low", agentID: "claude-code", usage: 300, max: 1000)
        center.record(chatID: "high", title: "High", agentID: "codex", usage: 900, max: 1000)
        center.record(chatID: "mid", title: "Mid", agentID: "gemini", usage: 600, max: 1000)

        XCTAssertEqual(center.all.map(\.id), ["high", "mid", "low"])
    }

    func testAllOrderingIsStableOnEqualPeaks() {
        let center = makeCenter()
        center.record(chatID: "b", title: "Bravo", agentID: "codex", usage: 500, max: 1000)
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 500, max: 1000)
        // Equal peaks fall back to title, then id — deterministic order.
        XCTAssertEqual(center.all.map(\.id), ["a", "b"])
    }

    // MARK: - remove / reset

    func testRemove() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 100, max: 1000)
        center.record(chatID: "b", title: "Bravo", agentID: "codex", usage: 200, max: 1000)
        center.remove(chatID: "a")
        XCTAssertNil(center.byChat["a"])
        XCTAssertNotNil(center.byChat["b"])
    }

    func testRemoveUnknownChatIsSafe() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 100, max: 1000)
        center.remove(chatID: "ghost")
        XCTAssertEqual(center.byChat.count, 1)
    }

    func testReset() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 100, max: 1000)
        center.record(chatID: "b", title: "Bravo", agentID: "codex", usage: 200, max: 1000)
        center.reset()
        XCTAssertTrue(center.byChat.isEmpty)
        XCTAssertEqual(center.totalPeakTokens, 0)
        XCTAssertEqual(center.contextPressure, 0)
    }

    // MARK: - aggregates

    func testTotalPeakTokensSumsPeaks() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 100, max: 1000)
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 400, max: 1000) // peak 400
        center.record(chatID: "b", title: "Bravo", agentID: "codex", usage: 250, max: 1000)       // peak 250
        XCTAssertEqual(center.totalPeakTokens, 650)
    }

    func testContextPressureIsMaxFractionAcrossChats() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 250, max: 1000) // 0.25
        center.record(chatID: "b", title: "Bravo", agentID: "codex", usage: 900, max: 1000)       // 0.90
        XCTAssertEqual(center.contextPressure, 0.90, accuracy: 0.0001)
    }

    func testContextPressureUsesLatestNotPeak() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 900, max: 1000) // peak 900
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 100, max: 1000) // latest 100
        // Pressure reflects the live window (0.10), not the 0.90 high-water mark.
        XCTAssertEqual(center.contextPressure, 0.10, accuracy: 0.0001)
    }

    func testContextPressureEmptyIsZero() {
        let center = makeCenter()
        XCTAssertEqual(center.contextPressure, 0)
    }

    func testContextPressureDivideByZeroSafety() {
        let center = makeCenter()
        // A max of 0 must never divide-by-zero; that chat contributes 0 pressure.
        center.record(chatID: "a", title: "Alpha", agentID: "claude-code", usage: 500, max: 0)
        XCTAssertEqual(center.contextPressure, 0)

        center.record(chatID: "b", title: "Bravo", agentID: "codex", usage: 300, max: 1000)
        XCTAssertEqual(center.contextPressure, 0.30, accuracy: 0.0001)
    }

    func testUsageSanitizesNegativeValuesAndCapsPressure() {
        let center = makeCenter()
        center.record(chatID: "negative", title: "N", agentID: "codex", usage: -5, max: -1)
        XCTAssertEqual(center.byChat["negative"]?.latestUsed, 0)
        XCTAssertEqual(center.byChat["negative"]?.latestMax, 0)

        center.record(chatID: "over", title: "O", agentID: "codex", usage: 2_000, max: 1_000)
        XCTAssertEqual(center.contextPressure, 1)
    }

    func testUsageRejectsNegativeCostAndNormalizesCurrency() {
        let center = makeCenter()
        center.record(
            chatID: "a", title: "Alpha", agentID: "codex",
            usage: 1, max: 10, costAmount: -1, costCurrency: " usd "
        )
        XCTAssertNil(center.byChat["a"]?.costAmount)
        center.record(
            chatID: "a", title: "Alpha", agentID: "codex",
            usage: 2, max: 10, costAmount: 0.25, costCurrency: " usd "
        )
        XCTAssertEqual(center.byChat["a"]?.costCurrency, "USD")
    }

    func testProviderPlanUsageDecodesNeutralBridgeShape() throws {
        let data = Data(#"""
        {
          "providers": [{
            "provider": "claude",
            "displayName": "Claude",
            "ok": true,
            "sourceLabel": "Claude Agent SDK 0.3.205",
            "experimental": true,
            "plan": "max",
            "windows": [{"label":"5 hour","usedPercent":37.5,"resetsAt":1800000000}],
            "updatedAt": 1700000000000
          }]
        }
        """#.utf8)

        let providers = try UsageCenter.decodeProviderPlanUsage(data)
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers.first?.provider, "claude")
        XCTAssertEqual(providers.first?.plan, "max")
        XCTAssertEqual(providers.first?.windows.first?.usedPercent, 37.5)
        XCTAssertEqual(providers.first?.windows.first?.resetsAt, 1_800_000_000)
    }

    func testProviderPlanUsageSurfacesBridgeError() {
        let data = Data(#"{"providers":[],"error":"helper unavailable"}"#.utf8)
        XCTAssertThrowsError(try UsageCenter.decodeProviderPlanUsage(data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("helper unavailable"))
        }
    }

    func testRecordTracksCumulativeCostWithoutMixingCurrencies() {
        let center = makeCenter()
        center.record(
            chatID: "a", title: "Alpha", agentID: "claude-code",
            usage: 100, max: 1000, costAmount: 0.25, costCurrency: "usd"
        )
        center.record(
            chatID: "a", title: "Alpha", agentID: "claude-code",
            usage: 200, max: 1000, costAmount: 0.40, costCurrency: "USD"
        )
        center.record(
            chatID: "b", title: "Bravo", agentID: "codex",
            usage: 150, max: 1000, costAmount: 0.10, costCurrency: "EUR"
        )

        XCTAssertEqual(center.byChat["a"]?.costAmount, 0.40)
        XCTAssertEqual(center.costTotals.map(\.currency), ["EUR", "USD"])
        XCTAssertEqual(center.costTotals.first { $0.currency == "USD" }?.amount, 0.40)
    }
}
