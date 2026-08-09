import KaisolaCore
import Foundation
import XCTest
@testable import KaisolaCompanion

@MainActor
final class CompanionResumePolicyTests: XCTestCase {
    func testAutomaticResumeHasOneFiniteExponentialRetryEpisode() {
        let expectedDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]

        XCTAssertEqual(CompanionReconnectPolicy.maximumAutomaticAttempts, expectedDelays.count)
        XCTAssertEqual(CompanionReconnectPolicy.discoveryTimeout, 8)
        XCTAssertEqual(CompanionReconnectPolicy.linkWaitingTimeout, 10)
        for (attempt, delay) in expectedDelays.enumerated() {
            XCTAssertEqual(
                CompanionReconnectPolicy.decision(forAttempt: attempt),
                .retry(afterSeconds: delay)
            )
        }
        XCTAssertEqual(
            CompanionReconnectPolicy.decision(forAttempt: expectedDelays.count),
            .requireUserAction
        )
        XCTAssertEqual(
            CompanionReconnectPolicy.decision(forAttempt: .max),
            .requireUserAction
        )
    }

    func testReconnectRequiredPreservesCachedStateForExplicitRecovery() {
        XCTAssertEqual(CompanionTransportState.reconnectRequired.storeState, .stale)
        XCTAssertFalse(
            CompanionReconnectPolicy.allowsPassiveRouteAdoption(in: .reconnectRequired)
        )
        for state in [
            CompanionTransportState.idle,
            .discovering,
            .connecting,
            .handshaking,
            .live,
            .reconnecting,
        ] {
            XCTAssertTrue(CompanionReconnectPolicy.allowsPassiveRouteAdoption(in: state))
        }
    }

    func testFreshConnectionEpochOverridesPersistedReplayCursorForEveryCommand() {
        let staleCursor = CompanionAckCursor(epoch: "desktop-before-relaunch", seq: 42)

        XCTAssertEqual(
            CompanionClient.outboundCommandEpoch(
                liveEpoch: "desktop-after-relaunch",
                persistedCursor: staleCursor
            ),
            "desktop-after-relaunch"
        )
        XCTAssertEqual(
            CompanionClient.outboundCommandEpoch(liveEpoch: nil, persistedCursor: staleCursor),
            "desktop-before-relaunch"
        )
        XCTAssertEqual(
            CompanionClient.outboundCommandEpoch(liveEpoch: nil, persistedCursor: nil),
            "initial"
        )
    }

    func testPairedDesktopSurvivesRelaunchWithoutWideningCapabilities() throws {
        let suite = "CompanionResumePolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = UserDefaultsPairedDesktopStore(defaults: defaults)
        let desktop = CompanionPairedDesktop(
            desktopId: "desktop-resume-test",
            identityPublic: "desktop-ed25519-pin",
            x25519StaticPublic: "desktop-x25519-pin",
            capabilities: [.observe, .agentControl],
            transportHint: CompanionPairingTransportHint(
                service: "_kaisola._tcp",
                protocol: "tcp",
                host: "mac.local",
                port: 49_200
            )
        )

        persistence.save(desktop)

        let relaunchedStore = UserDefaultsPairedDesktopStore(defaults: defaults)
        XCTAssertEqual(relaunchedStore.load(), desktop)
        XCTAssertEqual(relaunchedStore.load()?.capabilities, [.observe, .agentControl])
        XCTAssertFalse(relaunchedStore.load()?.capabilities.contains(.terminalControl) == true)
    }
}
