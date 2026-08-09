import AppKit
import Combine
import CryptoKit
import Foundation

/// Serializes the competing process-exit and timeout callbacks without tying
/// completion to the pipe-drain queue. The timeout itself runs on that queue,
/// so synchronously re-entering it would trap in libdispatch.
final class UsageProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// A locally named subscription whose credentials remain inside the provider's
/// normal config directory. Kaisola stores only this label + directory pointer;
/// tokens and credential contents are never copied into app state or usage
/// result payloads.
struct UsageAccountProfile: Codable, Equatable, Identifiable, Sendable {
    enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
        case claude
        case codex

        var id: String { rawValue }
        var displayName: String { self == .claude ? "Claude" : "Codex" }
        var environmentKey: String { self == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME" }
        var defaultDirectory: String { self == .claude ? "~/.claude" : "~/.codex" }
    }

    let id: String
    var provider: Provider
    var label: String
    var directory: String

    var normalized: UsageAccountProfile? {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty, !cleanDirectory.isEmpty else { return nil }
        return UsageAccountProfile(
            id: id,
            provider: provider,
            label: String(cleanLabel.prefix(80)),
            directory: cleanDirectory
        )
    }

    var expandedDirectory: String {
        (directory as NSString).expandingTildeInPath
    }
}

/// Immutable account context captured when an agent session begins. The
/// profile id is useful presentation metadata, but continuation safety is keyed
/// on `provider + configDirectory`: a profile may later be removed or renamed,
/// while resuming a provider thread under different credentials is never safe.
///
/// This value remains local app state. It is intentionally absent from the
/// remembered-session and Companion projection allowlists.
struct SessionAccountBinding: Codable, Equatable, Hashable, Sendable {
    let accountID: String?
    let provider: UsageAccountProfile.Provider
    let label: String
    let configDirectory: String

    var environmentOverlay: [String: String] {
        [provider.environmentKey: configDirectory]
    }

    var continuationKey: String {
        "\(provider.rawValue)\u{1f}\(configDirectory)"
    }

    var normalized: SessionAccountBinding? {
        let cleanID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDirectory = Self.canonicalDirectory(configDirectory)
        guard cleanID?.count ?? 0 <= 128,
              !(cleanID?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ?? false),
              !cleanLabel.isEmpty,
              cleanLabel.count <= 80,
              let cleanDirectory else { return nil }
        return SessionAccountBinding(
            accountID: cleanID?.isEmpty == false ? cleanID : nil,
            provider: provider,
            label: cleanLabel,
            configDirectory: cleanDirectory
        )
    }

    static func provider(forAgentID agentID: String) -> UsageAccountProfile.Provider? {
        switch agentID {
        case "claude-code": .claude
        case "codex": .codex
        default: nil
        }
    }

    /// The provider an agent's chats bind to, consulting the roster's
    /// *declared* credentials for custom agents — declared data, never
    /// inferred from an id or a package name (review finding 3). Returns nil
    /// both for a declared `.none` and for an unknown agent; callers that
    /// need the distinction check the roster's spec directly.
    static func declaredProvider(
        forAgentID agentID: String,
        store: CustomAgentStore = CustomAgentStore()
    ) -> UsageAccountProfile.Provider? {
        if let builtin = provider(forAgentID: agentID) { return builtin }
        guard let spec = store.all().first(where: { $0.id == agentID }) else { return nil }
        switch spec.resolvedCredentials {
        case .claude: return .claude
        case .codex: return .codex
        case .none: return nil
        }
    }

    /// `resolve(agentID:…)`'s body with the provider already decided, so a
    /// declared custom provider resolves through the identical rules.
    static func resolve(
        provider: UsageAccountProfile.Provider,
        profile: UsageAccountProfile?,
        fallbackEnvironment: [String: String]
    ) -> SessionAccountBinding? {
        if let profile {
            guard let profile = profile.normalized, profile.provider == provider else { return nil }
            return SessionAccountBinding(
                accountID: profile.id,
                provider: provider,
                label: profile.label,
                configDirectory: profile.expandedDirectory
            ).normalized
        }
        let directory = fallbackEnvironment[provider.environmentKey] ?? provider.defaultDirectory
        return SessionAccountBinding(
            accountID: nil,
            provider: provider,
            label: "Project/default",
            configDirectory: directory
        ).normalized
    }

    /// Resolve either an explicit named profile or the exact effective
    /// app/project default. Returning nil for a provider mismatch is deliberate:
    /// a Claude profile must never be applied to a Codex continuation.
    static func resolve(
        agentID: String,
        profile: UsageAccountProfile?,
        fallbackEnvironment: [String: String]
    ) -> SessionAccountBinding? {
        guard let provider = provider(forAgentID: agentID) else { return nil }
        if let profile {
            guard let profile = profile.normalized, profile.provider == provider else { return nil }
            return SessionAccountBinding(
                accountID: profile.id,
                provider: provider,
                label: profile.label,
                configDirectory: profile.expandedDirectory
            ).normalized
        }
        let directory = fallbackEnvironment[provider.environmentKey] ?? provider.defaultDirectory
        return SessionAccountBinding(
            accountID: nil,
            provider: provider,
            label: "Project/default",
            configDirectory: directory
        ).normalized
    }

    /// Whether a session is about to start on an account with nothing left,
    /// and which account does have room.
    ///
    /// Kaisola reads every account's remaining limit and then took no notice of
    /// it at launch: an account sitting at 100% on its weekly window would
    /// accept a new session and fail on the first turn, while another
    /// subscription sat idle. Knowing and not saying is the worst of the two.
    ///
    /// Pure, and handed its readings rather than reaching for them, so the rule
    /// is testable without a probe or a signed-in account.
    struct HeadroomAdvice: Equatable {
        /// Highest percentage used across the account's windows — the binding
        /// constraint, which is what "spent" actually means. An account at 0%
        /// on five hours and 100% on its weekly bucket is spent.
        let usedPercent: Double
        /// An account of the same provider with meaningfully more room.
        let alternativeLabel: String?
        let alternativeUsedPercent: Double?
    }

    /// At or above this, an account counts as spent. Not 100: the last few
    /// percent buy a turn or two, and hearing about it after the failure is no
    /// use.
    static let exhaustedPercent: Double = 95

    /// An alternative is only worth naming if it is this much freer. Trading a
    /// 96% account for a 94% one is churn, not advice.
    static let worthSwitchingMargin: Double = 20

    static func headroomAdvice(
        for binding: SessionAccountBinding,
        readings: [UsageCenter.ProviderPlanUsage]
    ) -> HeadroomAdvice? {
        func worst(_ reading: UsageCenter.ProviderPlanUsage) -> Double? {
            reading.windows.compactMap(\.usedPercent).max()
        }
        let current = readings.first {
            $0.provider == binding.provider.rawValue
                && $0.profileID != nil
                && $0.profileLabel == binding.label
        }
        guard let current, let used = worst(current), used >= exhaustedPercent else { return nil }

        let ceiling = used - worthSwitchingMargin
        var bestLabel: String?
        var bestUsed: Double?
        for reading in readings {
            guard reading.provider == binding.provider.rawValue else { continue }
            guard let label = reading.profileLabel, !label.isEmpty, label != binding.label else { continue }
            guard let value = worst(reading), value <= ceiling else { continue }
            if bestUsed == nil || value < bestUsed! {
                bestUsed = value
                bestLabel = label
            }
        }

        return HeadroomAdvice(
            usedPercent: used,
            alternativeLabel: bestLabel,
            alternativeUsedPercent: bestUsed
        )
    }

    /// Which named accounts the CLI's own default login resolves to.
    ///
    /// A reading with `profileID == "active"` is whatever a session gets when
    /// no named account is pinned. That is usually one of the accounts already
    /// listed — so Usage drew the same subscription twice, once under its name
    /// and once as "Current project", with identical percentages and identical
    /// reset times. Michael: "usage should see which account is current
    /// project, not put the same twice."
    ///
    /// Matched on provider plus account identity rather than directory, because
    /// the active reading reports the credentials it actually used and two
    /// directories can hold the same login.
    ///
    /// Pure and given its readings, so the rule is testable without a probe.
    static func currentProjectProfileIDs(
        readings: [UsageCenter.ProviderPlanUsage]
    ) -> Set<String> {
        var active: [String: String] = [:]
        for reading in readings where reading.profileID == "active" {
            guard let account = reading.account?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !account.isEmpty else { continue }
            active[reading.provider] = account
        }
        guard !active.isEmpty else { return [] }

        var matched: Set<String> = []
        for reading in readings {
            guard let id = reading.profileID, id != "active" else { continue }
            guard let account = reading.account?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !account.isEmpty else { continue }
            if active[reading.provider] == account { matched.insert(id) }
        }
        return matched
    }

    /// Whether an "active" reading is already represented by a named card.
    static func isRepresentedByNamedAccount(
        _ reading: UsageCenter.ProviderPlanUsage,
        readings: [UsageCenter.ProviderPlanUsage]
    ) -> Bool {
        guard reading.profileID == "active" else { return false }
        guard let account = reading.account?.trimmingCharacters(in: .whitespacesAndNewlines),
              !account.isEmpty else { return false }
        return readings.contains { other in
            guard let id = other.profileID, id != "active" else { return false }
            guard other.provider == reading.provider else { return false }
            return other.account?.trimmingCharacters(in: .whitespacesAndNewlines) == account
        }
    }

    /// One sentence a person can act on, or nothing.
    static func headroomWarning(
        for binding: SessionAccountBinding,
        readings: [UsageCenter.ProviderPlanUsage]
    ) -> String? {
        guard let advice = headroomAdvice(for: binding, readings: readings) else { return nil }
        let used = Int(advice.usedPercent.rounded())
        guard let label = advice.alternativeLabel,
              let alternative = advice.alternativeUsedPercent else {
            return "\(binding.label) is \(used)% used."
        }
        return "\(binding.label) is \(used)% used. \(label) is at \(Int(alternative.rounded()))%."
    }

    static func applying(
        _ binding: SessionAccountBinding?,
        to environment: [String: String]
    ) -> [String: String] {
        guard let binding = binding?.normalized else { return environment }
        return environment.merging(binding.environmentOverlay) { _, session in session }
    }

    /// Which row of a chat's account menu carries the checkmark. `profileID`
    /// nil is the "Project/default" row, current exactly when the live binding
    /// names no account (the resolve fallback). Pure so the menu cannot invent
    /// its own idea of "current".
    static func menuRowIsCurrent(binding: SessionAccountBinding?, profileID: String?) -> Bool {
        guard let profileID else { return binding?.accountID == nil }
        return binding?.accountID == profileID
    }
}

/// A per-chat model override, expressed the way both CLIs already accept one:
/// the same environment variables the app-wide Models & Keys routing sets.
/// Pure so the env mapping is testable.
enum SessionModelOverride {
    /// The variable each provider's CLI honors for model selection, or nil
    /// for agents with no known model env (the override is then inert rather
    /// than guessed).
    static func environmentKey(forAgentID agentID: String) -> String? {
        switch agentID {
        case "claude-code": "ANTHROPIC_MODEL"
        case "codex": "OPENAI_MODEL"
        default: nil
        }
    }

    /// The curated quick choices per agent. Claude Code accepts its alias
    /// names; Codex model ids move too fast to curate honestly, so its menu
    /// offers only Default plus free-text.
    static func quickChoices(forAgentID agentID: String) -> [(id: String, title: String)] {
        switch agentID {
        case "claude-code":
            [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
        default:
            []
        }
    }

    static func applying(
        _ model: String?,
        agentID: String,
        to environment: [String: String]
    ) -> [String: String] {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.count <= 128,
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let key = environmentKey(forAgentID: agentID) else { return environment }
        var environment = environment
        environment[key] = model
        return environment
    }
}

extension SessionAccountBinding {
    fileprivate static func canonicalDirectory(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 4_096,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        // Resolve any existing symlink components now. Otherwise changing a
        // profile symlink after session creation could silently redirect an
        // existing provider continuation to different credentials.
        return URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

/// Small private registry used by both Accounts settings and the Usage reader.
/// It deliberately stores no OAuth/API material; provider CLIs continue to own
/// authentication in their isolated config directories.
struct UsageAccountStore: Sendable {
    private struct Payload: Codable {
        let schemaVersion: Int
        var profiles: [UsageAccountProfile]
    }

    static let schemaVersion = 1
    let fileURL: URL

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("usage-accounts.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    func profiles() -> [UsageAccountProfile] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else { return [] }
        var seen = Set<String>()
        return payload.profiles.compactMap(\.normalized).filter { profile in
            let key = "\(profile.provider.rawValue)\u{1f}\(profile.expandedDirectory)"
            return seen.insert(key).inserted
        }
    }

    @discardableResult
    func add(provider: UsageAccountProfile.Provider, label: String, directory: String) -> UsageAccountProfile? {
        guard let profile = UsageAccountProfile(
            id: UUID().uuidString.lowercased(),
            provider: provider,
            label: label,
            directory: directory
        ).normalized else { return nil }
        var current = profiles()
        guard !current.contains(where: {
            $0.provider == profile.provider && $0.expandedDirectory == profile.expandedDirectory
        }) else { return nil }
        current.append(profile)
        guard write(current) else { return nil }
        return profile
    }

    @discardableResult
    func remove(id: String) -> Bool {
        let current = profiles()
        let remaining = current.filter { $0.id != id }
        guard remaining.count != current.count else { return false }
        return write(remaining)
    }

    static func suggestedDirectory(provider: UsageAccountProfile.Provider, label: String) -> String? {
        let slug = label.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return nil }
        return provider == .claude ? "~/.claude-\(slug)" : "~/.codex-\(slug)"
    }

    static func contextFingerprint(_ profiles: [UsageAccountProfile]) -> String {
        let material = profiles.sorted { $0.id < $1.id }.map {
            "\($0.id)\u{1f}\($0.provider.rawValue)\u{1f}\($0.label)\u{1f}\($0.expandedDirectory)"
        }.joined(separator: "\u{1e}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func write(_ profiles: [UsageAccountProfile]) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let payload = Payload(schemaVersion: Self.schemaVersion, profiles: profiles)
            let data = try JSONEncoder().encode(payload)
            let temporary = directory.appendingPathComponent(
                ".\(fileURL.lastPathComponent).\(UUID().uuidString)",
                isDirectory: false
            )
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            return true
        } catch {
            return false
        }
    }
}

extension Notification.Name {
    static let kaisolaUsageAccountsChanged = Notification.Name("kaisola.usageAccountsChanged")
}

/// Token-usage aggregator across every ACP chat in the app.
///
/// Each `AcpConversation` publishes a live per-chat context window (`AcpUsage`
/// used/max) that the chat header shows on its own. Electron additionally shows
/// whole-session usage gauges; the native app had no equivalent. `UsageCenter`
/// fills that gap: it fans every chat's usage updates into one place so the
/// Settings ▸ Usage tab and the footer cost chip show session totals and
/// context pressure. ACP chat rollups are restored beside their transcripts so
/// usage remains useful across an app update or restart.
@MainActor
final class UsageCenter: ObservableObject {
    typealias PlanUsageContextResolver = @Sendable (URL?, [String: String]) -> String

    /// The canonical instance the app UI observes. Tests may construct their own
    /// isolated instance via `init()` to avoid clobbering shared state.
    static let shared = UsageCenter(
        persistenceStore: NativePreviewSettings.isIsolatedFixture(
            environment: ProcessInfo.processInfo.environment
        )
            ? nil
            : .live
    )
    static let automaticPlanUsageTTL: TimeInterval = 180

    /// One chat's usage rollup. `latest*` is the most recent context-window
    /// reading (what the gauge shows); `peakUsed` is the high-water mark of used
    /// tokens seen this session (context can shrink after a compaction, so the
    /// latest reading undercounts how much the chat has actually pushed through).
    struct ChatUsage: Identifiable, Equatable {
        /// One completed turn's cost, as a delta against the turn before it.
        /// `usedDelta` may be negative — compaction shrinks the context, and a
        /// ledger that clamped it would quietly overstate every session.
        struct TurnDelta: Equatable, Identifiable {
            let index: Int
            let at: Date
            let usedDelta: Int
            let costDelta: Double?

            var id: Int { index }
        }

        /// How many completed turns the ledger keeps. Session-local by
        /// design: the persisted usage schema stays untouched, and a relaunch
        /// starts the ledger fresh rather than pretending to remember.
        static let ledgerLimit = 12

        let id: String
        var title: String
        var agentID: String
        var latestUsed: Int
        var latestMax: Int
        var peakUsed: Int
        var turns: Int
        var costAmount: Double?
        var costCurrency: String?
        var recentTurns: [TurnDelta] = []
        /// The reading the last completed turn ended on — the baseline the
        /// next turn's delta is measured against.
        var lastTurnUsed: Int = 0
        var lastTurnCost: Double = 0
    }

    // Encodable as well as Decodable so the last good reading can be persisted
    // and re-rendered instantly on the next launch. Nothing secret lives here:
    // a label, a percentage, and a reset timestamp.
    struct PlanWindow: Codable, Equatable, Identifiable, Sendable {
        let label: String
        let usedPercent: Double?
        let resetsAt: Double?

        var id: String { label }
    }

    struct ProviderPlanUsage: Codable, Equatable, Identifiable, Sendable {
        let provider: String
        let displayName: String
        let profileID: String?
        let profileLabel: String?
        let ok: Bool
        let sourceLabel: String
        let experimental: Bool?
        let account: String?
        let plan: String?
        let windows: [PlanWindow]
        let message: String?
        let updatedAt: Double?

        var id: String { "\(provider):\(profileID ?? "active")" }

        init(
            provider: String,
            displayName: String,
            profileID: String? = nil,
            profileLabel: String? = nil,
            ok: Bool,
            sourceLabel: String,
            experimental: Bool? = nil,
            account: String? = nil,
            plan: String? = nil,
            windows: [PlanWindow],
            message: String? = nil,
            updatedAt: Double? = nil
        ) {
            self.provider = provider
            self.displayName = displayName
            self.profileID = profileID
            self.profileLabel = profileLabel
            self.ok = ok
            self.sourceLabel = sourceLabel
            self.experimental = experimental
            self.account = account
            self.plan = plan
            self.windows = windows
            self.message = message
            self.updatedAt = updatedAt
        }

        func identified(by request: PlanUsageRequest, safeMessage: String?) -> ProviderPlanUsage {
            ProviderPlanUsage(
                provider: provider,
                displayName: displayName,
                profileID: request.profileID,
                profileLabel: request.profileLabel,
                ok: ok,
                sourceLabel: sourceLabel,
                experimental: experimental,
                account: account,
                plan: plan,
                windows: windows,
                message: safeMessage,
                updatedAt: updatedAt
            )
        }
    }

    struct PlanUsageRequest: Equatable, Sendable {
        let provider: UsageAccountProfile.Provider
        let profileID: String
        let profileLabel: String
        let environment: [String: String]
    }

    struct CostTotal: Identifiable, Equatable, Sendable {
        let currency: String
        let amount: Double
        var id: String { currency }
    }

    /// Currency-aware labels shared by the chat chrome, session navigation,
    /// and footer. Invalid values stay absent, and currencies are never added
    /// together merely to make one compact number.
    static func costLabel(
        amount: Double,
        currency: String?,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard amount.isFinite, amount >= 0 else { return nil }
        let trimmed = currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let code = trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        return amount.formatted(.currency(code: code).locale(locale))
    }

    static func footerCostChipLabel(
        _ totals: [CostTotal],
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let first = totals.first else { return nil }
        guard totals.count == 1 else { return "\(totals.count) currencies" }
        return costLabel(amount: first.amount, currency: first.currency, locale: locale)
    }

    static func costAccessibilityLabel(
        _ totals: [CostTotal],
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        let parts = totals.compactMap { total in
            costLabel(amount: total.amount, currency: total.currency, locale: locale)
                .map { "\(total.currency) \($0)" }
        }
        guard !parts.isEmpty else { return nil }
        return "Session cost: " + parts.joined(separator: ", ")
    }

    private struct PlanUsageEnvelope: Decodable, Sendable {
        let providers: [ProviderPlanUsage]
        let error: String?
    }

    @Published private(set) var byChat: [String: ChatUsage] = [:]
    @Published private(set) var planUsage: [ProviderPlanUsage] = []

    /// Background freshness (2026-08-06 spec §3e): every 5 minutes while the
    /// app is active, the frontmost workspace refreshes non-forced (the 180s
    /// TTL keeps coalescing), re-armed on wake and activation. Stats are
    /// simply fresh when you look — Settings, the footer chip, headroom
    /// advice — instead of fetching while you wait.
    private var backgroundRefreshTask: Task<Void, Never>?
    private var backgroundObservers: [NSObjectProtocol] = []
    static let backgroundRefreshInterval: TimeInterval = 300

    func startBackgroundRefresh(activeWorkspace: @escaping @MainActor () -> URL?) {
        guard backgroundRefreshTask == nil else { return }
        let arm: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.backgroundRefreshTask?.cancel()
            self.backgroundRefreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    if NSApp?.isActive == true, let workspace = activeWorkspace() {
                        self?.refreshPlanUsage(workspace: workspace, force: false)
                    }
                    try? await Task.sleep(for: .seconds(Self.backgroundRefreshInterval))
                }
            }
        }
        arm()
        let center = NotificationCenter.default
        backgroundObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { arm() } })
        backgroundObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { arm() } })
    }
    @Published private(set) var isRefreshingPlanUsage = false
    @Published private(set) var planUsageError: String?

    private var planRefreshTask: Task<Void, Never>?
    private var planRefreshGeneration = 0
    private var planRefreshContextKey: String?
    private var planUsageCache: [String: (providers: [ProviderPlanUsage], fetchedAt: Date)] = [:]
    /// Disk backing for `planUsageCache`, so cards render on launch instead of
    /// after a multi-second probe. Hydrated lazily on first access.
    private let planUsageSnapshots = PlanUsageSnapshotStore()
    private var hasHydratedPlanUsageSnapshots = false
    private let now: () -> Date
    private let persistenceStore: AcpTranscriptStore?
    private let planUsageContextResolver: PlanUsageContextResolver
    private let usageAccountStore: UsageAccountStore
    private let projectAccountRecoveryCenter: ProjectAccountRecoveryCenter
    private var persistenceTask: Task<Void, Never>?
    private var chatSources: [String: Set<String>] = [:]

    init(
        now: @escaping () -> Date = Date.init,
        persistenceStore: AcpTranscriptStore? = nil,
        usageAccountStore: UsageAccountStore = UsageAccountStore(),
        projectAccountRecoveryCenter: ProjectAccountRecoveryCenter = .shared,
        planUsageContextResolver: @escaping PlanUsageContextResolver = { workspace, environment in
            UsageCenter.planUsageContextKey(workspace: workspace, environment: environment)
        }
    ) {
        self.now = now
        self.persistenceStore = persistenceStore
        self.usageAccountStore = usageAccountStore
        self.projectAccountRecoveryCenter = projectAccountRecoveryCenter
        self.planUsageContextResolver = planUsageContextResolver
    }

    /// Every tracked chat, heaviest first (peak used tokens, descending). The
    /// title/id tiebreak keeps the order stable when peaks match.
    var all: [ChatUsage] {
        byChat.values.sorted { lhs, rhs in
            if lhs.peakUsed != rhs.peakUsed { return lhs.peakUsed > rhs.peakUsed }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }

    /// Fold one context-window reading into a chat's rollup, creating the entry
    /// on first sight. Refreshes the latest reading and title/agent (they can
    /// change if the chat is renamed or the model switches) and advances the
    /// peak. `turns` is preserved across records.
    @discardableResult
    func record(
        chatID: String,
        title: String,
        agentID: String,
        usage used: Int,
        max: Int,
        costAmount: Double? = nil,
        costCurrency: String? = nil
    ) -> AcpPersistedUsage {
        let safeUsed = Swift.max(0, used)
        let safeMax = Swift.max(0, max)
        let cleanCost = costAmount.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let cleanCurrency = costCurrency?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let currency = cleanCurrency?.isEmpty == false ? cleanCurrency : nil
        if var existing = byChat[chatID] {
            existing.title = title
            existing.agentID = agentID
            existing.latestUsed = safeUsed
            existing.latestMax = safeMax
            existing.peakUsed = Swift.max(existing.peakUsed, safeUsed)
            if let cleanCost { existing.costAmount = cleanCost }
            if let currency { existing.costCurrency = currency }
            byChat[chatID] = existing
        } else {
            byChat[chatID] = ChatUsage(
                id: chatID,
                title: title,
                agentID: agentID,
                latestUsed: safeUsed,
                latestMax: safeMax,
                peakUsed: safeUsed,
                turns: 0,
                costAmount: cleanCost,
                costCurrency: currency
            )
        }
        let snapshot = persistedSnapshot(chatID: chatID)!
        enqueuePersistence { store in
            await store.scheduleUsage(snapshot, for: chatID)
        }
        return snapshot
    }

    /// Count one completed turn for a chat already being tracked. A no-op for an
    /// unknown chat: a chat that never emitted a usage reading has nothing to
    /// show, so it is deliberately not conjured into existence here.
    @discardableResult
    func recordTurn(chatID: String) -> AcpPersistedUsage? {
        guard var existing = byChat[chatID] else { return nil }
        existing.turns += 1
        let costDelta: Double?
        if let cost = existing.costAmount, cost > existing.lastTurnCost {
            costDelta = cost - existing.lastTurnCost
        } else {
            costDelta = nil
        }
        existing.recentTurns.append(ChatUsage.TurnDelta(
            index: existing.turns,
            at: Date(),
            usedDelta: existing.latestUsed - existing.lastTurnUsed,
            costDelta: costDelta
        ))
        if existing.recentTurns.count > ChatUsage.ledgerLimit {
            existing.recentTurns.removeFirst(existing.recentTurns.count - ChatUsage.ledgerLimit)
        }
        existing.lastTurnUsed = existing.latestUsed
        existing.lastTurnCost = existing.costAmount ?? existing.lastTurnCost
        byChat[chatID] = existing
        let snapshot = persistedSnapshot(chatID: chatID)
        if let snapshot {
            enqueuePersistence { store in
                await store.scheduleUsage(snapshot, for: chatID)
            }
        }
        return snapshot
    }

    /// Forget a chat's usage (e.g. when it is closed). Safe for unknown ids.
    func remove(chatID: String) {
        byChat.removeValue(forKey: chatID)
        enqueuePersistence { store in
            await store.removeUsage(chatID: chatID)
        }
    }

    @discardableResult
    func rename(chatID: String, title: String) -> AcpPersistedUsage? {
        guard var existing = byChat[chatID] else { return nil }
        existing.title = title
        byChat[chatID] = existing
        let snapshot = persistedSnapshot(chatID: chatID)
        if let snapshot {
            enqueuePersistence { store in
                await store.scheduleUsage(snapshot, for: chatID)
            }
        }
        return snapshot
    }

    func restore(chatID: String, snapshot: AcpPersistedUsage) {
        let restored = ChatUsage(
            id: chatID,
            title: snapshot.title,
            agentID: snapshot.agentID,
            latestUsed: Swift.max(0, snapshot.latestUsed),
            latestMax: Swift.max(0, snapshot.latestMax),
            peakUsed: Swift.max(0, Swift.max(snapshot.peakUsed, snapshot.latestUsed)),
            turns: Swift.max(0, snapshot.turns),
            costAmount: snapshot.costAmount.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            costCurrency: snapshot.costCurrency
        )
        guard var existing = byChat[chatID] else {
            byChat[chatID] = restored
            return
        }
        // Another native window may already have a newer live reading for the
        // same durable chat. Restores are monotonic: they can contribute older
        // high-water/cumulative totals, but never replace the active window's
        // latest context, title, agent, or lower any counter.
        existing.peakUsed = Swift.max(existing.peakUsed, restored.peakUsed)
        existing.turns = Swift.max(existing.turns, restored.turns)
        if existing.costCurrency == nil, let restoredCost = restored.costAmount {
            existing.costAmount = restoredCost
            existing.costCurrency = restored.costCurrency
        } else if existing.costCurrency == restored.costCurrency,
                  let restoredCost = restored.costAmount {
            existing.costAmount = Swift.max(existing.costAmount ?? 0, restoredCost)
        }
        byChat[chatID] = existing
    }

    func persistedSnapshot(chatID: String) -> AcpPersistedUsage? {
        guard let usage = byChat[chatID] else { return nil }
        return AcpPersistedUsage(
            title: usage.title,
            agentID: usage.agentID,
            latestUsed: usage.latestUsed,
            latestMax: usage.latestMax,
            peakUsed: usage.peakUsed,
            turns: usage.turns,
            costAmount: usage.costAmount,
            costCurrency: usage.costCurrency
        )
    }

    /// Multiple native windows can restore the same durable chat. Track each
    /// window's source so closing one copy never erases usage still displayed
    /// by another copy.
    func register(chatID: String, sourceID: String) {
        guard !chatID.isEmpty, !sourceID.isEmpty else { return }
        chatSources[chatID, default: []].insert(sourceID)
    }

    /// Returns true only when an explicit close removed the last live source,
    /// allowing the caller to delete that chat's durable transcript as well.
    @discardableResult
    func unregister(chatID: String, sourceID: String, forgetWhenLast: Bool) -> Bool {
        chatSources[chatID]?.remove(sourceID)
        if chatSources[chatID]?.isEmpty == true { chatSources.removeValue(forKey: chatID) }
        let isLast = chatSources[chatID] == nil
        if isLast, forgetWhenLast { remove(chatID: chatID) }
        return isLast && forgetWhenLast
    }

    /// Clear all tracked usage (the Usage tab's Reset button).
    func reset() {
        byChat.removeAll()
        enqueuePersistence { store in await store.clearUsage() }
    }

    func flushPersistence() async {
        await persistenceTask?.value
        if let persistenceStore { await persistenceStore.flush() }
    }

    private func enqueuePersistence(
        _ operation: @escaping @Sendable (AcpTranscriptStore) async -> Void
    ) {
        guard let persistenceStore else { return }
        let previous = persistenceTask
        persistenceTask = Task {
            await previous?.value
            await operation(persistenceStore)
        }
    }

    // MARK: - Provider account limits

    /// Refresh exact provider account limits for the active project's account
    /// overlay. The signed helper owns the Node/SDK dependency surface; all
    /// credential reads, package hashing, and provider processes stay off the
    /// main actor.
    func refreshPlanUsage(workspace: URL?, force: Bool = false) {
        let appOverlay = NativePreviewSettings.shared.agentEnvironmentOverlay
        let overlay: [String: String]
        if let workspace {
            switch projectAccountRecoveryCenter.launchOverlay(
                app: appOverlay,
                forProject: NativeSessionStore.projectID(forDirectory: workspace.path)
            ) {
            case .success(let resolved):
                overlay = resolved
            case .failure(let issue):
                planRefreshTask?.cancel()
                planRefreshTask = nil
                planRefreshGeneration &+= 1
                isRefreshingPlanUsage = false
                planUsageError = issue.message
                return
            }
        } else {
            overlay = appOverlay
        }
        let environment = ProcessInfo.processInfo.environment.merging(overlay) { _, project in project }
        let profiles = usageAccountStore.profiles()
        let requests = Self.planUsageRequests(
            workspace: workspace,
            environment: environment,
            profiles: profiles
        )
        planRefreshTask?.cancel()
        planRefreshGeneration &+= 1
        let generation = planRefreshGeneration
        isRefreshingPlanUsage = true
        planUsageError = nil

        let helperRoot = Bundle.main.resourceURL?
            .appendingPathComponent("BrokerHelper", isDirectory: true)
        let currentDirectory = workspace
        let contextResolver = planUsageContextResolver

        planRefreshTask = Task { [weak self] in
            // Credential files can live on a slow or synchronized volume. Their
            // contents are bounded before hashing, but even that bounded I/O must
            // never stall SwiftUI's main actor.
            let contextReader = Task.detached(priority: .userInitiated) {
                var contextEnvironment = environment
                contextEnvironment["KAISOLA_USAGE_PROFILE_FINGERPRINT"] = Self.planUsageProfileContextFingerprint(
                    profiles: profiles,
                    requests: requests
                )
                return contextResolver(workspace, contextEnvironment)
            }
            let contextKey = await withTaskCancellationHandler {
                await contextReader.value
            } onCancel: {
                contextReader.cancel()
            }
            guard !Task.isCancelled, let self,
                  self.planRefreshGeneration == generation else { return }

            self.hydratePlanUsageSnapshotsIfNeeded()
            if !force,
               let cached = self.planUsageCache[contextKey],
               self.now().timeIntervalSince(cached.fetchedAt) < Self.automaticPlanUsageTTL {
                self.planRefreshContextKey = contextKey
                self.planUsage = cached.providers
                self.planUsageError = nil
                self.isRefreshingPlanUsage = false
                self.planRefreshTask = nil
                return
            }
            if self.planRefreshContextKey != contextKey {
                // Never show another project or account's limits while this one
                // refreshes — but a stale reading for *this exact* context is
                // not another context's data. The key folds in the workspace,
                // the account environment, and digests of the credential files,
                // so seeding from it shows the user's own last-known numbers
                // instead of an empty spinner while the probe runs.
                self.planUsage = self.planUsageCache[contextKey]?.providers ?? []
            }
            self.planRefreshContextKey = contextKey

            let reader = Task.detached(priority: .userInitiated) {
                await Self.readProviderPlanUsage(
                    helperRoot: helperRoot,
                    currentDirectory: currentDirectory,
                    environment: environment,
                    requests: requests
                )
            }
            let result = await withTaskCancellationHandler {
                await reader.value
            } onCancel: {
                reader.cancel()
            }
            guard !Task.isCancelled,
                  self.planRefreshGeneration == generation,
                  self.planRefreshContextKey == contextKey else { return }
            switch result {
            case let .success(providers):
                self.planUsage = providers
                // Reuse the already-resolved opaque context. Re-reading and
                // hashing credentials here used to double the I/O for every
                // successful refresh.
                self.storeCachedPlanUsage(providers, contextKey: contextKey, fetchedAt: self.now())
                self.planUsageError = nil
            case let .failure(message):
                self.planUsageCache.removeValue(forKey: contextKey)
                self.planUsage = []
                self.planUsageError = message
            }
            self.isRefreshingPlanUsage = false
            self.planRefreshTask = nil
        }
    }

    /// Retain provider cards in the app process so reopening Settings does not
    /// respawn the signed helper within the short freshness window. Kept
    /// internal so deterministic tests can validate the automatic-refresh path.
    func cachePlanUsage(
        _ providers: [ProviderPlanUsage],
        workspace: URL?,
        accountEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fetchedAt: Date
    ) async {
        let contextResolver = planUsageContextResolver
        let accountStore = usageAccountStore
        let contextReader = Task.detached(priority: .utility) {
            let profiles = accountStore.profiles()
            let requests = Self.planUsageRequests(
                workspace: workspace,
                environment: accountEnvironment,
                profiles: profiles
            )
            var contextEnvironment = accountEnvironment
            contextEnvironment["KAISOLA_USAGE_PROFILE_FINGERPRINT"] = Self.planUsageProfileContextFingerprint(
                profiles: profiles,
                requests: requests
            )
            return contextResolver(workspace, contextEnvironment)
        }
        let key = await withTaskCancellationHandler {
            await contextReader.value
        } onCancel: {
            contextReader.cancel()
        }
        guard !Task.isCancelled else { return }
        storeCachedPlanUsage(providers, contextKey: key, fetchedAt: fetchedAt)
    }

    /// Test/support synchronization for callers that need the final cache or
    /// helper result. UI callers remain fire-and-forget and responsive.
    func waitForPlanUsageRefresh() async {
        await planRefreshTask?.value
    }

    private func storeCachedPlanUsage(
        _ providers: [ProviderPlanUsage],
        contextKey: String,
        fetchedAt: Date
    ) {
        hydratePlanUsageSnapshotsIfNeeded()
        planUsageCache[contextKey] = (providers, fetchedAt)
        // Persist off the main actor: this is a small JSON write, but it runs
        // on every completed refresh and must not sit in the UI's path.
        let snapshot = planUsageCache.mapValues {
            PlanUsageSnapshotStore.Entry(providers: $0.providers, fetchedAt: $0.fetchedAt)
        }
        let store = planUsageSnapshots
        Task.detached(priority: .utility) { store.save(snapshot) }
    }

    /// Seed the in-memory cache from disk once per process.
    ///
    /// Safe to show eagerly because the context key already folds in the
    /// workspace, the account environment, and digests of the credential files —
    /// a different project or a re-authentication simply misses the cache rather
    /// than displaying someone else's numbers.
    private func hydratePlanUsageSnapshotsIfNeeded() {
        guard !hasHydratedPlanUsageSnapshots else { return }
        hasHydratedPlanUsageSnapshots = true
        for (key, entry) in planUsageSnapshots.entries() where planUsageCache[key] == nil {
            planUsageCache[key] = (entry.providers, entry.fetchedAt)
        }
    }

    nonisolated static func planUsageContextKey(
        workspace: URL?,
        environment: [String: String]
    ) -> String {
        let accountKeys = [
            "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CONFIG_DIR", "CODEX_HOME", "OPENAI_API_KEY", "OPENAI_BASE_URL",
            "KAISOLA_USAGE_PROFILE_FINGERPRINT",
        ]
        var accountParts = accountKeys
            .map { "\($0)=\(environment[$0] ?? "<unset>")" }
        accountParts.append(contentsOf: credentialFileFingerprints(environment: environment))
        let accountMaterial = accountParts.joined(separator: "\u{1f}")
        let fingerprint = SHA256.hash(data: Data(accountMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(workspace?.standardizedFileURL.path ?? "<global>")|\(fingerprint)"
    }

    /// Build one provider-scoped request for the active project plus every
    /// additional named account. Active/named duplicates are collapsed by
    /// canonical directory so a subscription is never queried twice.
    nonisolated static func planUsageRequests(
        workspace: URL?,
        environment: [String: String],
        profiles: [UsageAccountProfile]
    ) -> [PlanUsageRequest] {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        func canonical(_ value: String) -> String {
            let expanded = (value as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
        }
        func activeDirectory(for provider: UsageAccountProfile.Provider) -> String {
            if let configured = environment[provider.environmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
                return canonical(configured)
            }
            return canonical((home as NSString).appendingPathComponent(
                provider == .claude ? ".claude" : ".codex"
            ))
        }

        var requests: [PlanUsageRequest] = []
        for provider in UsageAccountProfile.Provider.allCases {
            let providerProfiles = profiles
                .filter { $0.provider == provider }
                .compactMap(\.normalized)
                .sorted {
                    if $0.label != $1.label { return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
                    return $0.id < $1.id
                }
            let active = activeDirectory(for: provider)
            let matched = providerProfiles.first { canonical($0.expandedDirectory) == active }
            requests.append(PlanUsageRequest(
                provider: provider,
                profileID: matched?.id ?? "active",
                profileLabel: matched?.label ?? (workspace == nil ? "Default" : "Current project"),
                environment: environment
            ))

            for profile in providerProfiles where canonical(profile.expandedDirectory) != active {
                var profileEnvironment = environment
                profileEnvironment[provider.environmentKey] = profile.expandedDirectory
                requests.append(PlanUsageRequest(
                    provider: provider,
                    profileID: profile.id,
                    profileLabel: profile.label,
                    environment: profileEnvironment
                ))
            }
        }
        return requests
    }

    private nonisolated static func planUsageProfileContextFingerprint(
        profiles: [UsageAccountProfile],
        requests: [PlanUsageRequest]
    ) -> String {
        var material = UsageAccountStore.contextFingerprint(profiles)
        for request in requests {
            material += "\u{1e}\(request.provider.rawValue):"
            material += credentialFileFingerprints(environment: request.environment).joined(separator: "\u{1f}")
        }
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Account switches performed by `claude auth login` or `codex login`
    /// mutate credential files without changing CODEX_HOME/CLAUDE_CONFIG_DIR.
    /// Fold the small credential files into the opaque cache fingerprint so a
    /// different account cannot inherit the previous account's 180-second card.
    /// Only digests enter the returned context key; paths and tokens never do.
    private nonisolated static func credentialFileFingerprints(
        environment: [String: String]
    ) -> [String] {
        let home = environment["HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
        let claudeRoot = environment["CLAUDE_CONFIG_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".claude", isDirectory: true)
        let codexRoot = environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".codex", isDirectory: true)
        let candidates = [
            claudeRoot.appendingPathComponent(".credentials.json"),
            claudeRoot.appendingPathComponent("credentials.json"),
            claudeRoot.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".claude.json"),
            codexRoot.appendingPathComponent("auth.json"),
        ]
        var seenPaths = Set<String>()
        let uniqueCandidates = candidates.filter {
            seenPaths.insert($0.standardizedFileURL.path).inserted
        }
        return uniqueCandidates.map { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size >= 0,
                  size <= 4 * 1_024 * 1_024,
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                return "missing"
            }
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            return "present:\(size):\(digest)"
        }
    }

    /// Deterministic provider cards for the hosted macOS visual job. No local
    /// account process or credential is touched; production never calls this.
    func loadVisualFixture() {
        planRefreshTask?.cancel()
        planRefreshTask = nil
        planRefreshGeneration &+= 1
        planRefreshContextKey = nil
        byChat = [
            "visual-claude": ChatUsage(
                id: "visual-claude",
                title: "Claude · Kaisola",
                agentID: "claude-code",
                latestUsed: 18_400,
                latestMax: 200_000,
                peakUsed: 31_200,
                turns: 4,
                costAmount: 0.42,
                costCurrency: "USD"
            ),
            "visual-codex": ChatUsage(
                id: "visual-codex",
                title: "Codex · Release review",
                agentID: "codex",
                latestUsed: 9_600,
                latestMax: 128_000,
                peakUsed: 14_200,
                turns: 2,
                costAmount: 0.08,
                costCurrency: "USD"
            ),
        ]
        let reset = Date().addingTimeInterval(7_200).timeIntervalSince1970
        planUsage = [
            ProviderPlanUsage(
                provider: "claude",
                displayName: "Claude",
                ok: true,
                sourceLabel: "Claude Agent SDK 0.3.205",
                experimental: true,
                account: nil,
                plan: "max",
                windows: [
                    PlanWindow(label: "5 hour", usedPercent: 38, resetsAt: reset),
                    PlanWindow(label: "7 day", usedPercent: 16, resetsAt: reset + 338_400),
                ],
                message: nil,
                updatedAt: Date().timeIntervalSince1970 * 1_000
            ),
            ProviderPlanUsage(
                provider: "codex",
                displayName: "Codex",
                ok: true,
                sourceLabel: "Codex CLI app-server",
                experimental: false,
                account: nil,
                plan: "pro",
                windows: [PlanWindow(label: "5 hour", usedPercent: 24, resetsAt: reset)],
                message: nil,
                updatedAt: Date().timeIntervalSince1970 * 1_000
            ),
        ]
        planUsageError = nil
        isRefreshingPlanUsage = false
    }

    nonisolated static func decodeProviderPlanUsage(_ data: Data) throws -> [ProviderPlanUsage] {
        let envelope = try JSONDecoder().decode(PlanUsageEnvelope.self, from: data)
        if envelope.providers.isEmpty, let error = envelope.error, !error.isEmpty {
            throw ProviderUsageError.message(error)
        }
        return envelope.providers
    }

    private nonisolated static func readProviderPlanUsage(
        helperRoot: URL?,
        currentDirectory: URL?,
        environment: [String: String],
        requests: [PlanUsageRequest]
    ) async -> ProviderPlanReadResult {
        do {
            if Task.isCancelled { return .failure("Provider usage refresh cancelled.") }
            guard let helperRoot else {
                return .failure("The signed usage helper is not packaged in this build.")
            }
            let package = try VerifiedUsageHelperCache.shared.package(
                root: helperRoot,
                requireSignatures: environment["KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER"] != "1"
            )
            guard FileManager.default.fileExists(atPath: package.usageScript.path) else {
                return .failure("The packaged usage reader is missing.")
            }

            let providers = await withTaskGroup(
                of: (Int, ProviderPlanUsage).self,
                returning: [ProviderPlanUsage].self
            ) { group in
                for (index, request) in requests.enumerated() {
                    group.addTask {
                        (
                            index,
                            await readSingleProviderPlanUsage(
                                package: package,
                                currentDirectory: currentDirectory,
                                request: request
                            )
                        )
                    }
                }
                var indexed: [(Int, ProviderPlanUsage)] = []
                for await value in group { indexed.append(value) }
                return indexed.sorted { $0.0 < $1.0 }.map(\.1)
            }
            if Task.isCancelled { return .failure("Provider usage refresh cancelled.") }
            return .success(providers)
        } catch {
            return .failure("The signed usage helper could not be verified.")
        }
    }

    private nonisolated static func readSingleProviderPlanUsage(
        package: VerifiedBrokerHelperPackage,
        currentDirectory: URL?,
        request: PlanUsageRequest
    ) async -> ProviderPlanUsage {
        let unavailable: (String) -> ProviderPlanUsage = { message in
            ProviderPlanUsage(
                provider: request.provider.rawValue,
                displayName: request.provider.displayName,
                profileID: request.profileID,
                profileLabel: request.profileLabel,
                ok: false,
                sourceLabel: request.provider == .claude
                    ? "Claude Agent SDK"
                    : "Codex CLI app-server",
                experimental: request.provider == .claude,
                windows: [],
                message: message,
                updatedAt: Date().timeIntervalSince1970 * 1_000
            )
        }
        if Task.isCancelled { return unavailable("Limit check cancelled.") }
        do {
            let process = Process()
            process.executableURL = package.nodeExecutable
            process.arguments = [package.usageScript.path, "--provider", request.provider.rawValue]
            process.environment = request.environment
            process.currentDirectoryURL = currentDirectory
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            // Drain both pipes CONCURRENTLY with the wait — a chatty child
            // that fills a pipe buffer would otherwise deadlock against a
            // parent that reads only after exit — and wait via the
            // termination handler instead of the old 50 ms Thread.sleep spin
            // that burned a thread per account per refresh (spec §3e).
            nonisolated(unsafe) var stdoutData = Data()
            nonisolated(unsafe) var stderrDrained = false
            let drainQueue = DispatchQueue(label: "kaisola.usage.drain")
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                drainQueue.sync { stdoutData.append(chunk) }
            }
            errors.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
                drainQueue.sync { stderrDrained = true }
            }
            try process.run()
            let finished: Bool = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let completionGate = UsageProcessCompletionGate()
                    let resumeOnce: @Sendable (Bool) -> Void = { value in
                        guard completionGate.claim() else { return }
                        continuation.resume(returning: value)
                    }
                    process.terminationHandler = { _ in resumeOnce(true) }
                    drainQueue.asyncAfter(deadline: .now() + 20) {
                        if process.isRunning { process.terminate() }
                        resumeOnce(!process.isRunning)
                    }
                }
            } onCancel: {
                process.terminate()
            }
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            _ = stderrDrained
            if Task.isCancelled {
                return unavailable("Limit check cancelled.")
            }
            if !finished {
                return unavailable("\(request.provider.displayName) limit check timed out.")
            }
            let trailing = output.fileHandleForReading.readDataToEndOfFile()
            let data = drainQueue.sync { stdoutData + trailing }
            guard !data.isEmpty else {
                return unavailable("\(request.provider.displayName) limit reader returned no data.")
            }
            guard let provider = try decodeProviderPlanUsage(data)
                .first(where: { $0.provider == request.provider.rawValue }) else {
                return unavailable("\(request.provider.displayName) limit reader returned no account result.")
            }
            return provider.identified(
                by: request,
                safeMessage: sanitizedProviderMessage(provider.message, environment: request.environment)
            )
        } catch {
            return unavailable("\(request.provider.displayName) limit reader could not start.")
        }
    }

    private nonisolated static func sanitizedProviderMessage(
        _ message: String?,
        environment: [String: String]
    ) -> String? {
        guard var safe = message.map({ String($0.prefix(500)) }) else { return nil }
        for key in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY"] {
            guard let value = environment[key], value.count >= 4 else { continue }
            safe = safe.replacingOccurrences(of: value, with: "[redacted]")
        }
        let pattern = #"(?i)(bearer|oauth token|api[ _-]?key)(\s*[:=]?\s*)[^\s,;]+"#
        if let expression = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(safe.startIndex..<safe.endIndex, in: safe)
            safe = expression.stringByReplacingMatches(in: safe, range: range, withTemplate: "$1$2[redacted]")
        }
        return safe
    }

    // MARK: - Aggregates

    /// Sum of every chat's peak used tokens — the session's total token weight.
    var totalPeakTokens: Int {
        byChat.values.reduce(0) { $0 + $1.peakUsed }
    }

    /// Highest current context fill across all chats, in `0...1` (0 when there
    /// are no chats, or none has a positive max). Uses the latest reading so it
    /// reflects live pressure, and guards divide-by-zero on an absent max.
    var contextPressure: Double {
        byChat.values.reduce(0.0) { current, usage in
            guard usage.latestMax > 0 else { return current }
            return Swift.max(current, Swift.min(1, Double(usage.latestUsed) / Double(usage.latestMax)))
        }
    }

    /// Cumulative cost grouped by ISO currency. A session can contain adapters
    /// that report different currencies, so totals are never silently mixed.
    var costTotals: [CostTotal] {
        var totals: [String: Double] = [:]
        for chat in byChat.values {
            guard let amount = chat.costAmount, amount.isFinite, amount >= 0 else { continue }
            totals[chat.costCurrency?.uppercased() ?? "USD", default: 0] += amount
        }
        return totals.keys.sorted().map { CostTotal(currency: $0, amount: totals[$0] ?? 0) }
    }
}

private enum ProviderPlanReadResult: Sendable {
    case success([UsageCenter.ProviderPlanUsage])
    case failure(String)
}

private enum ProviderUsageError: LocalizedError, Sendable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}
