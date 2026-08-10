import XCTest
@testable import Kaisola

/// The first-run readiness gate: shown once, then never again — and keyed by a
/// versioned flag so a future onboarding revision can re-show without
/// disturbing an earlier record. Each test runs in its own throwaway
/// UserDefaults suite so nothing leaks into `.standard` or across tests.
final class OnboardingStateTests: XCTestCase {
    /// A fresh, empty defaults domain unique to each call.
    private func makeDefaults() -> UserDefaults {
        let suite = "kaisola-onboarding-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testShowsInitiallyThenHiddenAfterMarkSeen() {
        let defaults = makeDefaults()
        XCTAssertTrue(OnboardingState.shouldShow(defaults: defaults),
                      "A fresh install should show onboarding once.")
        OnboardingState.markSeen(defaults: defaults)
        XCTAssertFalse(OnboardingState.shouldShow(defaults: defaults),
                       "Once seen, onboarding must not show again.")
    }

    func testMarkSeenIsIdempotent() {
        let defaults = makeDefaults()
        OnboardingState.markSeen(defaults: defaults)
        OnboardingState.markSeen(defaults: defaults)
        XCTAssertFalse(OnboardingState.shouldShow(defaults: defaults))
    }

    /// Marking the current checklist seen must not disturb the historical tour
    /// or a hypothetical future version.
    func testVersionKeyIsolation() {
        let defaults = makeDefaults()
        OnboardingState.markSeen(defaults: defaults)

        XCTAssertNotNil(defaults.object(forKey: "onboardingSeen.v2"),
                        "markSeen writes the v2 readiness flag it owns.")
        XCTAssertFalse(defaults.bool(forKey: "onboardingSeen.v1"),
                       "markSeen must not rewrite the historical v1 tour flag.")
        XCTAssertFalse(defaults.bool(forKey: "onboardingSeen.v3"),
                       "markSeen must not touch a future v3 key.")
    }

    /// The default is `.standard`, but every real call site passes the preview's
    /// own suite; confirm two suites stay fully independent.
    func testSeparateSuitesAreIndependent() {
        let seen = makeDefaults()
        let fresh = makeDefaults()
        OnboardingState.markSeen(defaults: seen)
        XCTAssertFalse(OnboardingState.shouldShow(defaults: seen))
        XCTAssertTrue(OnboardingState.shouldShow(defaults: fresh),
                      "A different suite has its own, still-unseen record.")
    }

    func testManualReopenInstructionNamesPaletteRouteWithoutResettingSeenState() {
        let defaults = makeDefaults()
        OnboardingState.markSeen(defaults: defaults)

        XCTAssertEqual(
            OnboardingState.reopenInstruction,
            "Reopen anytime: press Command-K and choose Readiness Checklist…"
        )
        XCTAssertFalse(
            OnboardingState.shouldShow(defaults: defaults),
            "explaining or using the manual route must not re-arm first-run onboarding"
        )
    }

    func testHostedFixturesNeverCoverTheirDeclaredSurfaceWithOnboarding() {
        let defaults = makeDefaults()
        XCTAssertTrue(OnboardingState.shouldShow(defaults: defaults))
        XCTAssertFalse(RootShellView.shouldPresentOnboarding(
            environment: ["KAISOLA_NATIVE_VISUAL_FIXTURE": "1"],
            defaults: defaults
        ))
        XCTAssertFalse(RootShellView.shouldPresentOnboarding(
            environment: ["KAISOLA_NATIVE_RESOURCE_WORKLOAD": "terminal-idle"],
            defaults: defaults
        ))
        XCTAssertTrue(RootShellView.shouldPresentOnboarding(
            environment: [:],
            defaults: defaults
        ))
    }

    func testReadinessReopenFixtureUsesOnlyItsBrokerFreeSurface() {
        XCTAssertTrue(RootShellView.shouldPresentReadinessReopenFixture(environment: [
            "KAISOLA_NATIVE_VISUAL_FIXTURE": "1",
            "KAISOLA_NATIVE_VISUAL_SURFACE": "onboarding-reopen",
        ]))
        XCTAssertFalse(RootShellView.shouldPresentReadinessReopenFixture(environment: [
            "KAISOLA_NATIVE_VISUAL_FIXTURE": "1",
            "KAISOLA_NATIVE_VISUAL_SURFACE": "onboarding",
        ]))
        XCTAssertFalse(RootShellView.shouldPresentReadinessReopenFixture(environment: [
            "KAISOLA_NATIVE_VISUAL_SURFACE": "onboarding-reopen",
        ]))
    }

    func testTerminalReadinessRequiresWriteControlNotOnlyObservation() {
        XCTAssertEqual(
            OnboardingReadiness.terminalService(
                connectionState: .connected(
                    version: "fixture",
                    pid: 42,
                    serverEnforcedObserver: true
                ),
                controlAvailable: false
            ).kind,
            .needsAction
        )
        XCTAssertEqual(
            OnboardingReadiness.terminalService(
                connectionState: .connected(
                    version: "fixture",
                    pid: 42,
                    serverEnforcedObserver: true
                ),
                controlAvailable: true
            ).kind,
            .ready
        )
    }

    func testAgentReadinessSeparatesCheckingSignedInAndUnverifiedStates() {
        XCTAssertEqual(
            OnboardingReadiness.agentAccount(
                agentID: "codex",
                readings: [],
                isRefreshing: true
            ).kind,
            .checking
        )

        let verified = UsageCenter.ProviderPlanUsage(
            provider: "codex",
            displayName: "Codex",
            ok: true,
            sourceLabel: "fixture",
            account: "ready@example.test",
            windows: []
        )
        let status = OnboardingReadiness.agentAccount(
            agentID: "codex",
            readings: [verified],
            isRefreshing: false
        )
        XCTAssertEqual(status.kind, .ready)
        XCTAssertEqual(status.detail, "Codex is signed in as ready@example.test.")

        XCTAssertEqual(
            OnboardingReadiness.agentAccount(
                agentID: "claude-code",
                readings: [],
                isRefreshing: false
            ).kind,
            .needsAction
        )
    }

    func testPlainTerminalDoesNotClaimAnAgentAccountIsRequired() {
        XCTAssertEqual(
            OnboardingReadiness.agentAccount(
                agentID: AgentProfile.shell.id,
                readings: [],
                isRefreshing: false
            ),
            .init(kind: .ready, detail: "A plain terminal does not require an agent account.")
        )
    }

    /// An unsigned build has no updater, so Settings can only explain the
    /// limitation. The row must keep that explanation and offer nothing.
    func testUnsignedBuildKeepsTheUpdateExplanationWithoutAnInertAction() {
        let status = OnboardingReadiness.updates(
            canConfigure: false,
            checksAutomatically: false,
            pendingVersion: nil
        )
        XCTAssertEqual(status.kind, .information)
        XCTAssertEqual(status.detail, "Update controls become available in a signed Kaisola build.")
        XCTAssertNil(
            OnboardingReadiness.updateAction(for: status),
            "Update Settings cannot change an unsigned build's update state, so the row must not offer it."
        )

        let unsignedWithStalePendingUpdate = OnboardingReadiness.updates(
            canConfigure: false,
            checksAutomatically: true,
            pendingVersion: "2.0"
        )
        XCTAssertEqual(unsignedWithStalePendingUpdate, status)
        XCTAssertNil(OnboardingReadiness.updateAction(for: unsignedWithStalePendingUpdate))
    }

    /// A signed build's action tracks whether a control there can act: the
    /// automatic-check toggle for an off state, Restart and Update for a
    /// pending version, and nothing at all once updates are already handled.
    func testSignedBuildOffersUpdateSettingsOnlyForStatesSettingsCanChange() {
        let checksOff = OnboardingReadiness.updates(
            canConfigure: true,
            checksAutomatically: false,
            pendingVersion: nil
        )
        XCTAssertEqual(checksOff.kind, .needsAction)
        XCTAssertEqual(OnboardingReadiness.updateAction(for: checksOff), "Update Settings")

        let checksOn = OnboardingReadiness.updates(
            canConfigure: true,
            checksAutomatically: true,
            pendingVersion: nil
        )
        XCTAssertEqual(checksOn.kind, .ready)
        XCTAssertNil(OnboardingReadiness.updateAction(for: checksOn))

        // Restart and Update is live in Settings whenever a version is waiting,
        // so that state stays actionable even with nothing left to configure.
        let pending = OnboardingReadiness.updates(
            canConfigure: true,
            checksAutomatically: true,
            pendingVersion: "9.9.9"
        )
        XCTAssertEqual(pending.kind, .needsAction)
        XCTAssertEqual(OnboardingReadiness.updateAction(for: pending), "Update Settings")
    }

    /// The decision is only worth having while the checklist actually asks it.
    /// The row used to offer the button for every non-ready status, which is
    /// how the unsigned build got a dead end in the first place.
    func testChecklistRoutesTheUpdatesActionThroughTheSharedDecision() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Kaisola/Features/Onboarding/OnboardingView.swift"),
            encoding: .utf8
        )
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(
            code.contains("actionTitle: OnboardingReadiness.updateAction(for: updateStatus)"),
            "The Updates row must take its action from OnboardingReadiness.updateAction."
        )
        XCTAssertFalse(
            code.contains("updateStatus.kind == .ready ? nil : \"Update Settings\""),
            "Offering Update Settings for every non-ready status puts a dead button on unsigned builds."
        )
    }

    func testHelpTargetsTheUserGuideInsteadOfDeveloperSetup() {
        XCTAssertEqual(
            KaisolaMacAppDelegate.userHelpURL?.path,
            "/michaelofengenden/kaisola/blob/main/docs/user-guide.md"
        )
    }
}
