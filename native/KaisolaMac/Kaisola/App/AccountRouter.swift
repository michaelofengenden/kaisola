import Foundation

/// How Kaisola picks the subscription a new session runs on.
///
/// The registry can hold half a dozen Claude and Codex accounts, yet every
/// launch used to start on "Project default" until the user changed a popup by
/// hand, every time. The router turns the per-account readings Kaisola already
/// takes into a launch-time choice — as a *suggestion* the picker preselects,
/// never a silent override of an explicit selection.
enum AccountRoutingPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Today's behavior: Project default unless the user picks.
    case manual
    /// Preselect whatever account was chosen for this agent last time.
    case sticky
    /// Preselect the same-provider account with the most headroom.
    case balanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: "Manual"
        case .sticky: "Remember last choice"
        case .balanced: "Balance by headroom"
        }
    }

    var caption: String {
        switch self {
        case .manual:
            "New sessions start on the project default until you pick an account."
        case .sticky:
            "New sessions suggest the account you last used with that agent."
        case .balanced:
            "New sessions suggest the signed-in account with the most limit left; Mesh spreads its columns across accounts."
        }
    }
}

/// Chooses which named subscription a new session should be offered.
///
/// Pure and handed its inputs — profiles from the registry, readings from the
/// usage probe — so every rule is testable without a signed-in account. A nil
/// verdict always means "no basis to suggest anything": the caller keeps
/// today's Project-default behavior.
enum AccountRouter {
    struct Verdict: Equatable {
        let profileID: String
        /// One sentence the picker can show for why this account is selected.
        let reason: String
    }

    /// The sticky sentinel for "the user explicitly chose Project default".
    /// Distinct from no memory at all: an explicit default choice is a choice.
    static let projectDefaultSelection = ""

    static func route(
        provider: UsageAccountProfile.Provider,
        profiles: [UsageAccountProfile],
        readings: [UsageCenter.ProviderPlanUsage],
        policy: AccountRoutingPolicy,
        lastUsedProfileID: String?,
        now: Date = Date()
    ) -> Verdict? {
        switch policy {
        case .manual:
            return nil
        case .sticky:
            guard let lastUsedProfileID,
                  lastUsedProfileID != projectDefaultSelection,
                  let profile = profiles.first(where: {
                      $0.id == lastUsedProfileID && $0.provider == provider
                  }) else { return nil }
            return Verdict(
                profileID: profile.id,
                reason: "You used \(profile.label) with this agent last time."
            )
        case .balanced:
            guard let best = rankedByHeadroom(
                provider: provider,
                profiles: profiles,
                readings: readings,
                now: now
            ).first else { return nil }
            let used = UsageCenter.PlanWindow.percentCaption(best.usedPercent)
            return Verdict(
                profileID: best.profile.id,
                reason: "\(best.profile.label) has the most room: \(used) used on its \(best.windowLabel) limit."
            )
        }
    }

    /// One usable candidate: a registered account with a fresh, signed-in
    /// reading and at least one window reporting a percentage.
    struct Candidate: Equatable {
        let profile: UsageAccountProfile
        /// Highest percentage across the account's windows — the binding
        /// constraint, same rule as `SessionAccountBinding.headroomAdvice`.
        let usedPercent: Double
        let windowLabel: String
    }

    /// Same-provider accounts ordered freest first.
    ///
    /// Accounts are skipped rather than guessed at: no reading, a stale
    /// reading, a signed-out reading, or a reading with no percentages gives
    /// the router no basis, and suggesting on no basis is how a router loses
    /// trust. Two directories holding the same login (the reading's account
    /// identity matches) collapse to one candidate — "spreading" work across
    /// two pointers at one subscription balances nothing.
    static func rankedByHeadroom(
        provider: UsageAccountProfile.Provider,
        profiles: [UsageAccountProfile],
        readings: [UsageCenter.ProviderPlanUsage],
        now: Date = Date()
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        var representedLogins: Set<String> = []
        let sortedProfiles = profiles
            .filter { $0.provider == provider }
            .sorted {
                if $0.label != $1.label {
                    return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
                }
                return $0.id < $1.id
            }
        for profile in sortedProfiles {
            guard let reading = readings.first(where: {
                $0.provider == provider.rawValue && $0.profileID == profile.id
            }), reading.ok, reading.authRequired != true, reading.isFresh(at: now) else { continue }
            var binding: (used: Double, label: String)?
            for window in reading.windows {
                guard let used = window.reportedUsedPercent else { continue }
                if binding.map({ used > $0.used }) ?? true {
                    binding = (used, window.label)
                }
            }
            guard let binding else { continue }
            if let login = reading.account?.trimmingCharacters(in: .whitespacesAndNewlines),
               !login.isEmpty {
                guard representedLogins.insert(login).inserted else { continue }
            }
            candidates.append(Candidate(
                profile: profile,
                usedPercent: binding.used,
                windowLabel: binding.label
            ))
        }
        // Stable: label order breaks percentage ties, from sortedProfiles.
        return candidates.sorted { lhs, rhs in
            if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent < rhs.usedPercent }
            return lhs.profile.label.localizedCaseInsensitiveCompare(rhs.profile.label) == .orderedAscending
        }
    }

    /// Account assignments for a Mesh launch: column `i` of a provider takes
    /// the `i`-th freest account of that provider, wrapping — so a Mesh fans
    /// its columns across subscriptions instead of stacking every column on
    /// the project default. Only `.balanced` spreads; the other policies
    /// return all-nil and Mesh behaves exactly as before.
    static func meshSpread(
        columnProviders: [UsageAccountProfile.Provider?],
        profiles: [UsageAccountProfile],
        readings: [UsageCenter.ProviderPlanUsage],
        policy: AccountRoutingPolicy,
        now: Date = Date()
    ) -> [UsageAccountProfile?] {
        guard policy == .balanced else {
            return Array(repeating: nil, count: columnProviders.count)
        }
        var ranked: [UsageAccountProfile.Provider: [Candidate]] = [:]
        var cursor: [UsageAccountProfile.Provider: Int] = [:]
        return columnProviders.map { provider in
            guard let provider else { return nil }
            let candidates = ranked[
                provider,
                default: rankedByHeadroom(
                    provider: provider,
                    profiles: profiles,
                    readings: readings,
                    now: now
                )
            ]
            ranked[provider] = candidates
            guard !candidates.isEmpty else { return nil }
            let index = cursor[provider, default: 0]
            cursor[provider] = index + 1
            return candidates[index % candidates.count].profile
        }
    }
}
