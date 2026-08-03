import SwiftUI
import XCTest
@testable import Kaisola

/// The meter ramp, and the rule that one subscription gets one card.
final class UsageMeterPaletteTests: XCTestCase {
    /// A gauge, not a traffic light: neighbouring values must be neighbouring
    /// colours. Three flat buckets made 59% and 61% look like different
    /// categories of problem.
    func testTheRampIsContinuous() {
        var previous = UsageMeterPalette.rgb(for: 0)
        for step in 1...100 {
            let current = UsageMeterPalette.rgb(for: Double(step) / 100)
            let jump = max(
                abs(current.red - previous.red),
                max(abs(current.green - previous.green), abs(current.blue - previous.blue))
            )
            XCTAssertLessThan(jump, 0.05, "1% of fill should never jump a hue at \(step)%")
            previous = current
        }
    }

    /// Cool at rest, warm when nearly gone — the direction is the signal.
    func testTheRampRunsCoolToWarm() {
        let empty = UsageMeterPalette.rgb(for: 0.02)
        let full = UsageMeterPalette.rgb(for: 0.98)
        XCTAssertGreaterThan(empty.blue, full.blue, "low usage should be the cooler end")
        XCTAssertGreaterThan(full.red, empty.red, "high usage should be the warmer end")
    }

    /// Out-of-range readings clamp rather than wrapping to a stray colour.
    func testOutOfRangeFillsClamp() {
        XCTAssertEqual(UsageMeterPalette.rgb(for: -3), UsageMeterPalette.rgb(for: 0))
        XCTAssertEqual(UsageMeterPalette.rgb(for: 42), UsageMeterPalette.rgb(for: 1))
    }

    // MARK: - One subscription, one card

    private func reading(
        id: String?,
        account: String?,
        provider: String = "claude"
    ) -> UsageCenter.ProviderPlanUsage {
        UsageCenter.ProviderPlanUsage(
            provider: provider,
            displayName: provider.capitalized,
            profileID: id,
            profileLabel: id,
            ok: true,
            sourceLabel: "test",
            experimental: false,
            account: account,
            plan: "max",
            windows: [],
            message: nil,
            updatedAt: 0
        )
    }

    /// The reported bug: the CLI's default login is one of the named accounts,
    /// so Usage drew that subscription twice — once by name, once as "Current
    /// project" — with identical percentages and reset times.
    func testTheDefaultLoginIsRecognisedAsTheNamedAccountItIs() {
        let readings = [
            reading(id: "pazalouie", account: "pazalouie@gmail.com"),
            reading(id: "active", account: "pazalouie@gmail.com"),
        ]
        XCTAssertEqual(
            SessionAccountBinding.currentProjectProfileIDs(readings: readings),
            ["pazalouie"]
        )
        XCTAssertTrue(
            SessionAccountBinding.isRepresentedByNamedAccount(readings[1], readings: readings)
        )
    }

    /// A default login that is genuinely its own account still gets a card.
    func testAnUnnamedDefaultLoginKeepsItsOwnCard() {
        let readings = [
            reading(id: "work", account: "work@example.com"),
            reading(id: "active", account: "someone-else@example.com"),
        ]
        XCTAssertTrue(SessionAccountBinding.currentProjectProfileIDs(readings: readings).isEmpty)
        XCTAssertFalse(
            SessionAccountBinding.isRepresentedByNamedAccount(readings[1], readings: readings)
        )
    }

    /// Same email on two providers is two subscriptions, not one.
    func testProvidersAreNotCrossMatched() {
        let readings = [
            reading(id: "claude-one", account: "me@example.com", provider: "claude"),
            reading(id: "active", account: "me@example.com", provider: "codex"),
        ]
        XCTAssertTrue(SessionAccountBinding.currentProjectProfileIDs(readings: readings).isEmpty)
    }

    /// A reading with no account cannot be matched to anything.
    func testAnAccountlessReadingMatchesNothing() {
        let readings = [
            reading(id: "work", account: nil),
            reading(id: "active", account: nil),
        ]
        XCTAssertTrue(SessionAccountBinding.currentProjectProfileIDs(readings: readings).isEmpty)
        XCTAssertFalse(
            SessionAccountBinding.isRepresentedByNamedAccount(readings[1], readings: readings)
        )
    }
}
