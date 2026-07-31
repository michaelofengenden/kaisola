import XCTest
@testable import Kaisola

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

    func testRenameUpdatesExistingUsageWithoutChangingCounters() {
        let center = makeCenter()
        center.record(chatID: "a", title: "Alpha", agentID: "codex", usage: 420, max: 1000)
        center.recordTurn(chatID: "a")

        center.rename(chatID: "a", title: "Research")

        XCTAssertEqual(center.byChat["a"]?.title, "Research")
        XCTAssertEqual(center.byChat["a"]?.peakUsed, 420)
        XCTAssertEqual(center.byChat["a"]?.turns, 1)
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

    func testSubscriptionStalenessAcceptsMillisecondAndSecondEpochs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let twoHoursAgo = now.addingTimeInterval(-7_200).timeIntervalSince1970

        XCTAssertEqual(
            SubscriptionCardView.stalenessCaption(updatedAt: twoHoursAgo, now: now),
            "2h ago"
        )
        XCTAssertEqual(
            SubscriptionCardView.stalenessCaption(updatedAt: twoHoursAgo * 1_000, now: now),
            "2h ago"
        )
        XCTAssertNil(SubscriptionCardView.stalenessCaption(
            updatedAt: now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000,
            now: now
        ))
        XCTAssertNil(SubscriptionCardView.stalenessCaption(updatedAt: .nan, now: now))
    }

    func testUsageTokenFormattingChangesUnitsAtOneMillion() {
        XCTAssertEqual(UsageSettingsTab.tokens(999), "999")
        XCTAssertEqual(UsageSettingsTab.tokens(1_000), "1k")
        XCTAssertEqual(UsageSettingsTab.tokens(999_999), "999k")
        XCTAssertEqual(UsageSettingsTab.tokens(1_000_000), "1m")
        XCTAssertEqual(UsageSettingsTab.tokens(1_999_999), "2m")
        XCTAssertEqual(UsageSettingsTab.tokens(1_250_000), "1.3m")
        XCTAssertEqual(UsageSettingsTab.tokens(-1), "0")
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

    func testCostLabelsStayCurrencyAwareAndNeverBlendTotals() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(
            UsageCenter.costLabel(amount: 1.25, currency: " usd ", locale: locale),
            "$1.25"
        )
        XCTAssertNil(UsageCenter.costLabel(amount: -.infinity, currency: "USD", locale: locale))

        let usd = UsageCenter.CostTotal(currency: "USD", amount: 0.40)
        let eur = UsageCenter.CostTotal(currency: "EUR", amount: 0.10)
        XCTAssertEqual(UsageCenter.footerCostChipLabel([usd], locale: locale), "$0.40")
        XCTAssertEqual(UsageCenter.footerCostChipLabel([eur, usd], locale: locale), "2 currencies")

        let accessibility = UsageCenter.costAccessibilityLabel([eur, usd], locale: locale)
        XCTAssertTrue(accessibility?.contains("EUR") == true)
        XCTAssertTrue(accessibility?.contains("USD") == true)
        XCTAssertTrue(accessibility?.contains("€0.10") == true)
        XCTAssertTrue(accessibility?.contains("$0.40") == true)
    }

    func testPersistedSnapshotRestoresUsageTurnsAndCost() throws {
        let center = makeCenter()
        let snapshot = AcpPersistedUsage(
            title: "Claude · Project", agentID: "claude-code",
            latestUsed: 900, latestMax: 10_000, peakUsed: 1_400, turns: 6,
            costAmount: 1.25, costCurrency: "USD"
        )

        center.restore(chatID: "restored", snapshot: snapshot)

        XCTAssertEqual(center.persistedSnapshot(chatID: "restored"), snapshot)
        XCTAssertEqual(center.totalPeakTokens, 1_400)
        XCTAssertEqual(center.contextPressure, 0.09, accuracy: 0.0001)
    }

    func testAutomaticProviderRefreshUsesFreshWorkspaceCache() async throws {
        let clock = Date(timeIntervalSince1970: 2_000)
        let center = UsageCenter(now: { clock })
        let workspace = URL(fileURLWithPath: "/tmp/kaisola-usage-cache", isDirectory: true)
        let providers = try UsageCenter.decodeProviderPlanUsage(Data(#"""
        {"providers":[{
          "provider":"codex","displayName":"Codex","ok":true,
          "sourceLabel":"Codex CLI app-server","windows":[]
        }]}
        """#.utf8))
        await center.cachePlanUsage(
            providers,
            workspace: workspace,
            fetchedAt: clock.addingTimeInterval(-UsageCenter.automaticPlanUsageTTL + 1)
        )

        center.refreshPlanUsage(workspace: workspace)
        await center.waitForPlanUsageRefresh()

        XCTAssertEqual(center.planUsage, providers)
        XCTAssertFalse(center.isRefreshingPlanUsage)
        XCTAssertNil(center.planUsageError)
    }

    func testProviderRefreshResolvesCredentialContextOffMainActorOncePerPath() async throws {
        let clock = Date(timeIntervalSince1970: 3_000)
        let probe = UsageContextResolverProbe(delay: 0.2, key: "opaque-test-context")
        let center = UsageCenter(
            now: { clock },
            planUsageContextResolver: { workspace, environment in
                probe.resolve(workspace: workspace, environment: environment)
            }
        )
        let workspace = URL(fileURLWithPath: "/tmp/kaisola-usage-responsive", isDirectory: true)
        let providers = try UsageCenter.decodeProviderPlanUsage(Data(#"""
        {"providers":[{
          "provider":"codex","displayName":"Codex","ok":true,
          "sourceLabel":"Codex CLI app-server","windows":[]
        }]}
        """#.utf8))

        await center.cachePlanUsage(
            providers,
            workspace: workspace,
            accountEnvironment: [:],
            fetchedAt: clock
        )
        XCTAssertEqual(probe.count, 1, "cache insertion fingerprints exactly once")

        let started = Date()
        center.refreshPlanUsage(workspace: workspace)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            0.1,
            "slow credential I/O must not block the main actor"
        )
        await center.waitForPlanUsageRefresh()

        XCTAssertEqual(probe.count, 2, "refresh fingerprints once and reuses that key for lookup")
        XCTAssertEqual(center.planUsage, providers)
        XCTAssertFalse(center.isRefreshingPlanUsage)
    }

    func testProviderCacheContextChangesWithEffectiveAccountWithoutExposingIt() {
        let workspace = URL(fileURLWithPath: "/tmp/kaisola-usage-account", isDirectory: true)
        let first = UsageCenter.planUsageContextKey(
            workspace: workspace,
            environment: ["CODEX_HOME": "/tmp/codex-one", "OPENAI_API_KEY": "secret-one"]
        )
        let second = UsageCenter.planUsageContextKey(
            workspace: workspace,
            environment: ["CODEX_HOME": "/tmp/codex-two", "OPENAI_API_KEY": "secret-two"]
        )

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("secret-one"))
        XCTAssertFalse(second.contains("/tmp/codex-two"))
    }

    func testProviderCacheContextChangesWhenCredentialFileChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-usage-credentials-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = codexHome.appendingPathComponent("auth.json")
        let environment = ["HOME": root.path, "CODEX_HOME": codexHome.path]

        try Data(#"{"token":"first-secret"}"#.utf8).write(to: auth)
        let first = UsageCenter.planUsageContextKey(workspace: nil, environment: environment)
        try Data(#"{"token":"second-secret"}"#.utf8).write(to: auth)
        let second = UsageCenter.planUsageContextKey(workspace: nil, environment: environment)

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("first-secret"))
        XCTAssertFalse(second.contains("second-secret"))
        XCTAssertFalse(second.contains(codexHome.path))
    }

    func testProviderCacheContextChangesWhenCustomClaudeAccountIdentityChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-usage-claude-account-\(UUID().uuidString)", isDirectory: true)
        let claudeHome = root.appendingPathComponent("claude-project", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = claudeHome.appendingPathComponent(".claude.json")
        let environment = ["HOME": root.path, "CLAUDE_CONFIG_DIR": claudeHome.path]

        try Data(#"{"userID":"first-private-account"}"#.utf8).write(to: identity)
        let first = UsageCenter.planUsageContextKey(workspace: nil, environment: environment)
        try Data(#"{"userID":"second-private-account"}"#.utf8).write(to: identity)
        let second = UsageCenter.planUsageContextKey(workspace: nil, environment: environment)

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("first-private-account"))
        XCTAssertFalse(second.contains("second-private-account"))
        XCTAssertFalse(second.contains(claudeHome.path))
    }

    func testStaleSecondWindowRestoreCannotDowngradeLiveUsage() {
        let center = makeCenter()
        center.record(
            chatID: "shared", title: "Live title", agentID: "codex",
            usage: 900, max: 2_000, costAmount: 4, costCurrency: "USD"
        )
        center.recordTurn(chatID: "shared")
        center.recordTurn(chatID: "shared")

        center.restore(
            chatID: "shared",
            snapshot: AcpPersistedUsage(
                title: "Stale title", agentID: "claude-code",
                latestUsed: 100, latestMax: 1_000, peakUsed: 1_100, turns: 1,
                costAmount: 3, costCurrency: "USD"
            )
        )

        let usage = center.byChat["shared"]
        XCTAssertEqual(usage?.title, "Live title")
        XCTAssertEqual(usage?.agentID, "codex")
        XCTAssertEqual(usage?.latestUsed, 900)
        XCTAssertEqual(usage?.latestMax, 2_000)
        XCTAssertEqual(usage?.peakUsed, 1_100)
        XCTAssertEqual(usage?.turns, 2)
        XCTAssertEqual(usage?.costAmount, 4)
    }

    func testPersistenceQueueOrdersResetAfterPriorUsageWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-usage-reset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AcpTranscriptStore(fileURL: directory.appendingPathComponent("transcripts.json"))
        let center = UsageCenter(persistenceStore: store)

        center.record(chatID: "a", title: "Alpha", agentID: "codex", usage: 100, max: 1_000)
        center.recordTurn(chatID: "a")
        center.reset()
        await center.flushPersistence()

        XCTAssertTrue(center.byChat.isEmpty)
        let resetEntry = await store.entry(for: "a")
        XCTAssertNil(resetEntry?.usage)
    }

    func testMultipleWindowSourcesOnlyForgetUsageAfterLastExplicitClose() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-usage-sources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AcpTranscriptStore(fileURL: directory.appendingPathComponent("transcripts.json"))
        let center = UsageCenter(persistenceStore: store)
        center.register(chatID: "shared", sourceID: "window-a")
        center.register(chatID: "shared", sourceID: "window-b")
        center.record(chatID: "shared", title: "Shared", agentID: "claude-code", usage: 80, max: 800)

        XCTAssertFalse(center.unregister(chatID: "shared", sourceID: "window-a", forgetWhenLast: true))
        XCTAssertNotNil(center.byChat["shared"])
        XCTAssertTrue(center.unregister(chatID: "shared", sourceID: "window-b", forgetWhenLast: true))
        await center.flushPersistence()

        XCTAssertNil(center.byChat["shared"])
        let closedEntry = await store.entry(for: "shared")
        XCTAssertNil(closedEntry?.usage)
    }

    func testUsageAccountStoreRoundTripsNamedProfilesWithoutCredentialMaterial() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-usage-profiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("usage-accounts.json")
        let store = UsageAccountStore(fileURL: fileURL)

        let claude = try XCTUnwrap(store.add(
            provider: .claude,
            label: " Work ",
            directory: "~/.claude-work"
        ))
        XCTAssertEqual(claude.label, "Work")
        XCTAssertNil(store.add(provider: .claude, label: "Duplicate", directory: "~/.claude-work"))
        XCTAssertNotNil(store.add(provider: .codex, label: "Research", directory: "~/.codex-research"))
        XCTAssertEqual(store.profiles().map(\.label), ["Work", "Research"])

        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(persisted.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(persisted.localizedCaseInsensitiveContains("credential"))
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue ?? 0, 0o600)

        XCTAssertTrue(store.remove(id: claude.id))
        XCTAssertEqual(store.profiles().map(\.label), ["Research"])
        XCTAssertFalse(store.remove(id: "missing"))
    }

    func testUsageAccountStoreSuggestedDirectoriesMatchProviderIsolation() {
        XCTAssertEqual(
            UsageAccountStore.suggestedDirectory(provider: .claude, label: "Research Team"),
            "~/.claude-research-team"
        )
        XCTAssertEqual(
            UsageAccountStore.suggestedDirectory(provider: .codex, label: "Work / Two"),
            "~/.codex-work-two"
        )
        XCTAssertNil(UsageAccountStore.suggestedDirectory(provider: .claude, label: " -- "))
    }

    func testSessionAccountBindingSnapshotsNamedProfileAndCanonicalPath() throws {
        let profile = UsageAccountProfile(
            id: "codex-research",
            provider: .codex,
            label: " Research ",
            directory: "/tmp/accounts/../codex-research"
        )
        let binding = try XCTUnwrap(SessionAccountBinding.resolve(
            agentID: "codex",
            profile: profile,
            fallbackEnvironment: ["CODEX_HOME": "/tmp/ignored"]
        ))
        let expectedDirectory = URL(fileURLWithPath: "/tmp/codex-research", isDirectory: true)
            .resolvingSymlinksInPath().path

        XCTAssertEqual(binding.accountID, "codex-research")
        XCTAssertEqual(binding.provider, .codex)
        XCTAssertEqual(binding.label, "Research")
        XCTAssertEqual(binding.configDirectory, expectedDirectory)
        XCTAssertEqual(binding.environmentOverlay, ["CODEX_HOME": expectedDirectory])
        XCTAssertEqual(binding.continuationKey, "codex\u{1f}\(expectedDirectory)")
    }

    func testSessionAccountBindingSnapshotsEffectiveDefaultAndWinsOverlay() throws {
        let binding = try XCTUnwrap(SessionAccountBinding.resolve(
            agentID: "claude-code",
            profile: nil,
            fallbackEnvironment: ["CLAUDE_CONFIG_DIR": "/tmp/project-claude"]
        ))
        let applied = SessionAccountBinding.applying(binding, to: [
            "CLAUDE_CONFIG_DIR": "/tmp/changed-later",
            "PATH": "/usr/bin",
        ])
        let expectedDirectory = URL(fileURLWithPath: "/tmp/project-claude", isDirectory: true)
            .resolvingSymlinksInPath().path

        XCTAssertNil(binding.accountID)
        XCTAssertEqual(binding.label, "Project/default")
        XCTAssertEqual(binding.configDirectory, expectedDirectory)
        XCTAssertEqual(applied["CLAUDE_CONFIG_DIR"], expectedDirectory)
        XCTAssertEqual(applied["PATH"], "/usr/bin")
    }

    func testSessionAccountBindingRejectsProviderMismatchAndUnsafeDirectory() {
        let claudeProfile = UsageAccountProfile(
            id: "claude-work",
            provider: .claude,
            label: "Work",
            directory: "/tmp/claude-work"
        )
        XCTAssertNil(SessionAccountBinding.resolve(
            agentID: "codex",
            profile: claudeProfile,
            fallbackEnvironment: [:]
        ))
        XCTAssertNil(SessionAccountBinding(
            accountID: "unsafe",
            provider: .codex,
            label: "Unsafe",
            configDirectory: "relative/path"
        ).normalized)
    }

    func testSessionAccountBindingPinsExistingSymlinkTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-account-binding-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("actual", isDirectory: true)
        let link = root.appendingPathComponent("selected", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let binding = try XCTUnwrap(SessionAccountBinding(
            accountID: "codex-linked",
            provider: .codex,
            label: "Linked",
            configDirectory: link.path
        ).normalized)

        XCTAssertEqual(binding.configDirectory, target.resolvingSymlinksInPath().path)
    }

    func testPlanUsageRequestsFanOutNamedAccountsAndCollapseActiveDuplicate() throws {
        let profiles = [
            UsageAccountProfile(id: "claude-work", provider: .claude, label: "Work", directory: "/tmp/claude-work"),
            UsageAccountProfile(id: "claude-personal", provider: .claude, label: "Personal", directory: "/tmp/claude-personal"),
            UsageAccountProfile(id: "codex-research", provider: .codex, label: "Research", directory: "/tmp/codex-research"),
        ]
        let requests = UsageCenter.planUsageRequests(
            workspace: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            environment: [
                "HOME": "/tmp/home",
                "CLAUDE_CONFIG_DIR": "/tmp/claude-work",
            ],
            profiles: profiles
        )

        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.map { "\($0.provider.rawValue):\($0.profileLabel)" }, [
            "claude:Work", "claude:Personal", "codex:Current project", "codex:Research",
        ])
        XCTAssertEqual(requests[0].profileID, "claude-work")
        XCTAssertEqual(requests[1].environment["CLAUDE_CONFIG_DIR"], "/tmp/claude-personal")
        XCTAssertEqual(requests[3].environment["CODEX_HOME"], "/tmp/codex-research")
        XCTAssertEqual(Set(requests.map { "\($0.provider.rawValue):\($0.profileID)" }).count, requests.count)
    }

    func testNamedAccountFingerprintInvalidatesCacheWithoutExposingPaths() {
        let firstProfiles = [
            UsageAccountProfile(id: "a", provider: .claude, label: "Work", directory: "/private/account-one"),
        ]
        let secondProfiles = [
            UsageAccountProfile(id: "a", provider: .claude, label: "Work", directory: "/private/account-two"),
        ]
        let firstFingerprint = UsageAccountStore.contextFingerprint(firstProfiles)
        let secondFingerprint = UsageAccountStore.contextFingerprint(secondProfiles)

        XCTAssertNotEqual(firstFingerprint, secondFingerprint)
        XCTAssertFalse(firstFingerprint.contains("account-one"))
        XCTAssertEqual(firstFingerprint.count, 64)
    }
}

private final class UsageContextResolverProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let key: String
    private var resolutionCount = 0

    init(delay: TimeInterval, key: String) {
        self.delay = delay
        self.key = key
    }

    var count: Int {
        lock.withLock { resolutionCount }
    }

    func resolve(workspace: URL?, environment: [String: String]) -> String {
        _ = workspace
        _ = environment
        lock.withLock { resolutionCount += 1 }
        Thread.sleep(forTimeInterval: delay)
        return key
    }
}
