import XCTest
@testable import Kaisola

/// The router only ever *suggests* — a nil verdict keeps today's
/// Project-default behavior — so every rule here is about when it is allowed
/// to open its mouth: fresh signed-in readings only, no guessing, and one
/// candidate per real login no matter how many directories point at it.
final class AccountRouterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(
        _ id: String,
        label: String,
        provider: UsageAccountProfile.Provider = .claude
    ) -> UsageAccountProfile {
        UsageAccountProfile(
            id: id,
            provider: provider,
            label: label,
            directory: "/tmp/kaisola-router/\(id)"
        )
    }

    private func reading(
        profileID: String,
        provider: String = "claude",
        ok: Bool = true,
        authRequired: Bool? = nil,
        account: String? = nil,
        usedPercents: [(String, Double?)],
        ageSeconds: TimeInterval = 30
    ) -> UsageCenter.ProviderPlanUsage {
        UsageCenter.ProviderPlanUsage(
            provider: provider,
            displayName: provider.capitalized,
            profileID: profileID,
            profileLabel: profileID,
            ok: ok,
            authRequired: authRequired,
            sourceLabel: "test",
            account: account,
            windows: usedPercents.map {
                UsageCenter.PlanWindow(label: $0.0, usedPercent: $0.1, resetsAt: nil)
            },
            updatedAt: (now.timeIntervalSince1970 - ageSeconds) * 1_000
        )
    }

    func testBalancedPicksTheFreestAccountByItsBindingWindow() throws {
        let profiles = [
            profile("work", label: "Work"),
            profile("research", label: "Research"),
        ]
        // Research is freer on five hours but MORE spent on its weekly
        // window; the binding constraint is the worst window, so Work wins.
        let readings = [
            reading(profileID: "work", usedPercents: [("5 hour", 38), ("Weekly", 41)]),
            reading(profileID: "research", usedPercents: [("5 hour", 12), ("Weekly", 91)]),
        ]

        let verdict = try XCTUnwrap(AccountRouter.route(
            provider: .claude,
            profiles: profiles,
            readings: readings,
            policy: .balanced,
            lastUsedProfileID: nil,
            now: now
        ))
        XCTAssertEqual(verdict.profileID, "work")
        XCTAssertTrue(verdict.reason.contains("Work"), verdict.reason)
        XCTAssertTrue(verdict.reason.contains("41%"), verdict.reason)
        XCTAssertTrue(verdict.reason.contains("Weekly"), verdict.reason)
    }

    /// No reading, a stale reading, a signed-out reading, or a reading with
    /// no percentages is no basis. Suggesting on no basis loses the router
    /// every future argument.
    func testBalancedRefusesToGuess() {
        let profiles = [
            profile("silent", label: "Silent"),
            profile("stale", label: "Stale"),
            profile("signedout", label: "SignedOut"),
            profile("blank", label: "Blank"),
        ]
        let readings = [
            reading(profileID: "stale", usedPercents: [("5 hour", 5)], ageSeconds: 3_600),
            reading(
                profileID: "signedout",
                ok: false,
                authRequired: true,
                usedPercents: [("5 hour", 1)]
            ),
            reading(profileID: "blank", usedPercents: [("5 hour", nil)]),
        ]

        XCTAssertNil(AccountRouter.route(
            provider: .claude,
            profiles: profiles,
            readings: readings,
            policy: .balanced,
            lastUsedProfileID: nil,
            now: now
        ))
    }

    /// Two directories holding one login are one subscription. "Spreading"
    /// across them balances nothing, so only one survives ranking.
    func testTwoDirectoriesWithOneLoginCollapseToOneCandidate() {
        let profiles = [
            profile("main", label: "Main"),
            profile("mirror", label: "Mirror"),
            profile("other", label: "Other"),
        ]
        let readings = [
            reading(profileID: "main", account: "m@example.com", usedPercents: [("5 hour", 10)]),
            reading(profileID: "mirror", account: "m@example.com", usedPercents: [("5 hour", 10)]),
            reading(profileID: "other", account: "o@example.com", usedPercents: [("5 hour", 60)]),
        ]

        let ranked = AccountRouter.rankedByHeadroom(
            provider: .claude,
            profiles: profiles,
            readings: readings,
            now: now
        )
        XCTAssertEqual(ranked.map(\.profile.id), ["main", "other"])
    }

    func testStickyReturnsTheRegisteredLastChoiceAndNothingElse() {
        let profiles = [profile("work", label: "Work")]

        let remembered = AccountRouter.route(
            provider: .claude,
            profiles: profiles,
            readings: [],
            policy: .sticky,
            lastUsedProfileID: "work",
            now: now
        )
        XCTAssertEqual(remembered?.profileID, "work")

        // An explicit Project default last time is a choice to respect, and a
        // memory of a since-removed account is no memory at all.
        XCTAssertNil(AccountRouter.route(
            provider: .claude,
            profiles: profiles,
            readings: [],
            policy: .sticky,
            lastUsedProfileID: AccountRouter.projectDefaultSelection,
            now: now
        ))
        XCTAssertNil(AccountRouter.route(
            provider: .claude,
            profiles: profiles,
            readings: [],
            policy: .sticky,
            lastUsedProfileID: "removed",
            now: now
        ))
        XCTAssertNil(AccountRouter.route(
            provider: .claude,
            profiles: profiles,
            readings: [],
            policy: .manual,
            lastUsedProfileID: "work",
            now: now
        ))
    }

    /// Mesh columns take accounts freest-first and wrap, and only under
    /// `.balanced` — every other policy hands back all-nil so Mesh behaves
    /// exactly as it did.
    func testMeshSpreadFansColumnsAcrossAccountsFreestFirst() {
        let profiles = [
            profile("work", label: "Work"),
            profile("research", label: "Research"),
        ]
        let readings = [
            reading(profileID: "work", usedPercents: [("5 hour", 60)]),
            reading(profileID: "research", usedPercents: [("5 hour", 20)]),
        ]

        let spread = AccountRouter.meshSpread(
            columnProviders: [.claude, .claude, .claude, nil],
            profiles: profiles,
            readings: readings,
            policy: .balanced,
            now: now
        )
        XCTAssertEqual(
            spread.map { $0?.id },
            ["research", "work", "research", nil]
        )

        let unrouted = AccountRouter.meshSpread(
            columnProviders: [.claude, .claude],
            profiles: profiles,
            readings: readings,
            policy: .sticky,
            now: now
        )
        XCTAssertEqual(unrouted.map { $0?.id }, [nil, nil])
    }
}
