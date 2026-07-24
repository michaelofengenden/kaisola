import Combine
import Foundation

/// Session-lifetime token-usage aggregator across every ACP chat in the app.
///
/// Each `AcpConversation` publishes a live per-chat context window (`AcpUsage`
/// used/max) that the chat header shows on its own. Electron additionally shows
/// whole-session usage gauges; the native app had no equivalent. `UsageCenter`
/// fills that gap: it fans every chat's usage updates into one place so the
/// Settings ▸ Usage tab and the footer cost chip can show session totals and
/// context pressure. State is in-memory and lasts for the app session only
/// (nothing is persisted — this mirrors Electron's live gauges, not history).
@MainActor
final class UsageCenter: ObservableObject {
    /// The canonical instance the app UI observes. Tests may construct their own
    /// isolated instance via `init()` to avoid clobbering shared state.
    static let shared = UsageCenter()

    /// One chat's usage rollup. `latest*` is the most recent context-window
    /// reading (what the gauge shows); `peakUsed` is the high-water mark of used
    /// tokens seen this session (context can shrink after a compaction, so the
    /// latest reading undercounts how much the chat has actually pushed through).
    struct ChatUsage: Identifiable, Equatable {
        let id: String
        var title: String
        var agentID: String
        var latestUsed: Int
        var latestMax: Int
        var peakUsed: Int
        var turns: Int
    }

    struct PlanWindow: Decodable, Equatable, Identifiable, Sendable {
        let label: String
        let usedPercent: Double?
        let resetsAt: Double?

        var id: String { label }
    }

    struct ProviderPlanUsage: Decodable, Equatable, Identifiable, Sendable {
        let provider: String
        let displayName: String
        let ok: Bool
        let sourceLabel: String
        let experimental: Bool?
        let account: String?
        let plan: String?
        let windows: [PlanWindow]
        let message: String?
        let updatedAt: Double?

        var id: String { provider }
    }

    private struct PlanUsageEnvelope: Decodable, Sendable {
        let providers: [ProviderPlanUsage]
        let error: String?
    }

    @Published private(set) var byChat: [String: ChatUsage] = [:]
    @Published private(set) var planUsage: [ProviderPlanUsage] = []
    @Published private(set) var isRefreshingPlanUsage = false
    @Published private(set) var planUsageError: String?

    private var planRefreshTask: Task<Void, Never>?

    init() {}

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
    func record(chatID: String, title: String, agentID: String, usage used: Int, max: Int) {
        if var existing = byChat[chatID] {
            existing.title = title
            existing.agentID = agentID
            existing.latestUsed = used
            existing.latestMax = max
            existing.peakUsed = Swift.max(existing.peakUsed, used)
            byChat[chatID] = existing
        } else {
            byChat[chatID] = ChatUsage(
                id: chatID,
                title: title,
                agentID: agentID,
                latestUsed: used,
                latestMax: max,
                peakUsed: used,
                turns: 0
            )
        }
    }

    /// Count one completed turn for a chat already being tracked. A no-op for an
    /// unknown chat: a chat that never emitted a usage reading has nothing to
    /// show, so it is deliberately not conjured into existence here.
    func recordTurn(chatID: String) {
        guard var existing = byChat[chatID] else { return }
        existing.turns += 1
        byChat[chatID] = existing
    }

    /// Forget a chat's usage (e.g. when it is closed). Safe for unknown ids.
    func remove(chatID: String) {
        byChat.removeValue(forKey: chatID)
    }

    /// Clear all tracked usage (the Usage tab's Reset button).
    func reset() {
        byChat.removeAll()
    }

    // MARK: - Provider account limits

    /// Refresh exact provider account limits for the active project's account
    /// overlay. The signed helper owns the Node/SDK dependency surface; all
    /// package hashing and provider processes stay off the main actor.
    func refreshPlanUsage(workspace: URL?, force: Bool = false) {
        if isRefreshingPlanUsage, !force { return }
        planRefreshTask?.cancel()
        isRefreshingPlanUsage = true
        planUsageError = nil

        let projectOverride = workspace.map {
            ProjectAccountStore().override(
                forProject: NativeSessionStore.projectID(forDirectory: $0.path)
            )
        } ?? nil
        let overlay = ProjectAccountStore.mergedOverlay(
            app: NativePreviewSettings.shared.agentEnvironmentOverlay,
            project: projectOverride
        )
        let environment = ProcessInfo.processInfo.environment.merging(overlay) { _, project in project }
        let helperRoot = Bundle.main.resourceURL?
            .appendingPathComponent("BrokerHelper", isDirectory: true)
        let currentDirectory = workspace

        planRefreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.readProviderPlanUsage(
                    helperRoot: helperRoot,
                    currentDirectory: currentDirectory,
                    environment: environment
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            switch result {
            case let .success(providers):
                self.planUsage = providers
                self.planUsageError = nil
            case let .failure(message):
                self.planUsageError = message
            }
            self.isRefreshingPlanUsage = false
            self.planRefreshTask = nil
        }
    }

    /// Deterministic provider cards for the hosted macOS visual job. No local
    /// account process or credential is touched; production never calls this.
    func loadVisualFixture() {
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
        environment: [String: String]
    ) -> ProviderPlanReadResult {
        do {
            guard let helperRoot else {
                return .failure("The signed usage helper is not packaged in this build.")
            }
            let package = try BrokerHelperPackageVerification.verify(
                root: helperRoot,
                requireSignatures: environment["KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER"] != "1"
            )
            guard FileManager.default.fileExists(atPath: package.usageScript.path) else {
                return .failure("The packaged usage reader is missing.")
            }

            let process = Process()
            process.executableURL = package.nodeExecutable
            process.arguments = [package.usageScript.path]
            process.environment = environment
            process.currentDirectoryURL = currentDirectory
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile().suffix(1_000),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !data.isEmpty else {
                return .failure(stderr.isEmpty ? "Provider usage returned no data." : stderr)
            }
            do {
                return .success(try decodeProviderPlanUsage(data))
            } catch {
                return .failure(stderr.isEmpty ? error.localizedDescription : stderr)
            }
        } catch {
            return .failure(error.localizedDescription)
        }
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
            return Swift.max(current, Double(usage.latestUsed) / Double(usage.latestMax))
        }
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
