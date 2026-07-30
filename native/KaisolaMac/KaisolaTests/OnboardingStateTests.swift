import XCTest
@testable import Kaisola

/// The first-run onboarding gate: shown once, then never again — and keyed by a
/// versioned flag so a future onboarding revision (v2, v3, …) can re-show
/// without disturbing the v1 record. Each test runs in its own throwaway
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

    /// Marking v1 seen must not set a hypothetical future version key, so a
    /// later onboarding revision keyed on v2 would still show.
    func testVersionKeyIsolation() {
        let defaults = makeDefaults()
        OnboardingState.markSeen(defaults: defaults)

        XCTAssertNotNil(defaults.object(forKey: "onboardingSeen.v1"),
                        "markSeen writes the v1 flag it owns.")
        XCTAssertFalse(defaults.bool(forKey: "onboardingSeen.v2"),
                       "markSeen must not touch a future v2 key.")
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
}
