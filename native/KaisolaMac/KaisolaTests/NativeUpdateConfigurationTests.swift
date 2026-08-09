import Combine
import Foundation
import XCTest
@testable import Kaisola

@MainActor
final class NativeUpdateConfigurationTests: XCTestCase {
    private let validKey = Data(repeating: 0xA5, count: 32).base64EncodedString()

    override func setUp() async throws {
        UpdateCenter.shared.clear()
        for toast in ToastCenter.shared.toasts {
            ToastCenter.shared.dismiss(toast.id)
        }
    }

    override func tearDown() async throws {
        UpdateCenter.shared.clear()
        for toast in ToastCenter.shared.toasts {
            ToastCenter.shared.dismiss(toast.id)
        }
    }

    func testValidSignedHTTPSFeedIsAccepted() throws {
        let configuration = try NativeUpdateConfiguration.parse([
            "SUFeedURL": "https://updates.kaisola.app/appcast.xml",
            "SUPublicEDKey": validKey,
        ])
        XCTAssertEqual(configuration.feedURL.absoluteString, "https://updates.kaisola.app/appcast.xml")
        XCTAssertEqual(configuration.publicEDKey, validKey)
    }

    func testMissingReleaseConfigurationFailsClosed() {
        XCTAssertThrowsError(try NativeUpdateConfiguration.parse([:])) {
            XCTAssertEqual($0 as? NativeUpdateConfigurationError, .notConfigured)
        }
    }

    func testInsecureOrCredentialedFeedIsRejected() {
        for feed in [
            "http://updates.kaisola.app/appcast.xml",
            "https://user:secret@updates.kaisola.app/appcast.xml",
            "https://updates.kaisola.app/appcast.xml#replacement",
        ] {
            XCTAssertThrowsError(try NativeUpdateConfiguration.parse([
                "SUFeedURL": feed,
                "SUPublicEDKey": validKey,
            ])) {
                XCTAssertEqual($0 as? NativeUpdateConfigurationError, .unsafeFeedURL)
            }
        }
    }

    func testSigningKeyMustBeExactlyOneEd25519PublicKey() {
        for key in ["not-base64", Data(repeating: 1, count: 31).base64EncodedString()] {
            XCTAssertThrowsError(try NativeUpdateConfiguration.parse([
                "SUFeedURL": "https://updates.kaisola.app/appcast.xml",
                "SUPublicEDKey": key,
            ])) {
                XCTAssertEqual($0 as? NativeUpdateConfigurationError, .invalidPublicKey)
            }
        }
    }

    func testInstallTransitionsBeforeClosureAndRejectsRapidReentry() {
        let center = UpdateCenter.shared
        var installCallCount = 0
        var phaseDuringInstall: UpdateCenter.PendingUpdate.Phase?

        center.markReady(version: "2.0.0") {
            installCallCount += 1
            phaseDuringInstall = center.pendingUpdate?.phase
            center.installAndRelaunch()
        }

        XCTAssertEqual(center.pendingUpdate?.phase, .ready)
        XCTAssertTrue(center.canInstallPendingUpdate)

        center.installAndRelaunch()
        center.installAndRelaunch()

        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(phaseDuringInstall, .installing)
        XCTAssertEqual(center.pendingUpdate?.phase, .installing)
        XCTAssertFalse(center.canInstallPendingUpdate)
        XCTAssertTrue(center.isInstallingUpdate)
    }

    func testInstallingStatePublishesToEveryObserverAndRejectsAReofferedClosure() {
        let center = UpdateCenter.shared
        var firstWindowPhases: [UpdateCenter.PendingUpdate.Phase] = []
        var secondWindowPhases: [UpdateCenter.PendingUpdate.Phase] = []
        var installCallCount = 0
        var replacementCallCount = 0
        let firstWindow = center.$pendingUpdate
            .compactMap { $0?.phase }
            .sink { firstWindowPhases.append($0) }
        let secondWindow = center.$pendingUpdate
            .compactMap { $0?.phase }
            .sink { secondWindowPhases.append($0) }
        defer {
            firstWindow.cancel()
            secondWindow.cancel()
        }

        center.markReady(version: "2.0.0") { installCallCount += 1 }
        center.installAndRelaunch()
        center.markReady(version: "2.0.0") { replacementCallCount += 1 }
        center.installAndRelaunch()

        XCTAssertEqual(firstWindowPhases, [.ready, .installing])
        XCTAssertEqual(secondWindowPhases, [.ready, .installing])
        XCTAssertEqual(center.pendingUpdate?.phase, .installing)
        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(replacementCallCount, 0)
    }

    func testSettingsPresentationFailsClosedToAccessibleInstallingState() {
        XCTAssertEqual(
            SettingsView.SoftwareUpdateActionPresentation.resolve(
                canInstall: true,
                isInstalling: true,
                isChecking: true,
                canCheck: true,
                sparkleIsPresenting: false
            ),
            .installing
        )
        XCTAssertEqual(
            SettingsView.SoftwareUpdateActionPresentation.installingAccessibilityLabel,
            "Installing update and restarting Kaisola"
        )
        XCTAssertEqual(
            SettingsView.SoftwareUpdateActionPresentation.resolve(
                canInstall: false,
                isInstalling: false,
                isChecking: false,
                canCheck: true,
                sparkleIsPresenting: true
            ),
            .check(enabled: false)
        )
    }

    func testVisualFixtureUpdateStateRequiresBothIsolationGates() throws {
        XCTAssertNil(UpdateCenter.visualFixturePendingUpdate(environment: [:]))
        XCTAssertNil(UpdateCenter.visualFixturePendingUpdate(environment: [
            "KAISOLA_NATIVE_VISUAL_UPDATE_PHASE": "ready",
        ]))
        XCTAssertNil(UpdateCenter.visualFixturePendingUpdate(environment: [
            "KAISOLA_NATIVE_VISUAL_FIXTURE": "1",
            "KAISOLA_NATIVE_VISUAL_UPDATE_PHASE": "unknown",
        ]))

        let ready = try XCTUnwrap(UpdateCenter.visualFixturePendingUpdate(environment: [
            "KAISOLA_NATIVE_VISUAL_FIXTURE": "1",
            "KAISOLA_NATIVE_VISUAL_UPDATE_PHASE": "ready",
            "KAISOLA_NATIVE_VISUAL_UPDATE_VERSION": " 2.0.0 ",
        ]))
        XCTAssertEqual(ready.version, "2.0.0")
        XCTAssertEqual(ready.phase, .ready)

        let installing = try XCTUnwrap(UpdateCenter.visualFixturePendingUpdate(environment: [
            "KAISOLA_NATIVE_VISUAL_FIXTURE": "1",
            "KAISOLA_NATIVE_VISUAL_UPDATE_PHASE": "installing",
        ]))
        XCTAssertEqual(installing.version, "99.0")
        XCTAssertEqual(installing.phase, .installing)
    }

}
