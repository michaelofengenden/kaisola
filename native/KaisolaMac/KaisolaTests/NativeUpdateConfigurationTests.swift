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

    func testReadyUpdateReplacementInvokesOnlyTheNewestInstallClosure() {
        let center = UpdateCenter(environment: [:])
        var replacedInstallCallCount = 0
        var currentInstallCallCount = 0

        center.markReady(version: "2.0.0") { replacedInstallCallCount += 1 }
        center.markReady(version: "2.0.1") { currentInstallCallCount += 1 }

        XCTAssertEqual(center.pendingUpdate?.version, "2.0.1")
        XCTAssertEqual(center.pendingUpdate?.phase, .ready)
        center.installAndRelaunch()
        XCTAssertEqual(replacedInstallCallCount, 0)
        XCTAssertEqual(currentInstallCallCount, 1)
    }

    func testInstallWithNoPendingUpdateIsANoOp() {
        let center = UpdateCenter(environment: [:])

        center.installAndRelaunch()

        XCTAssertNil(center.pendingUpdate)
        XCTAssertFalse(center.canInstallPendingUpdate)
        XCTAssertFalse(center.isInstallingUpdate)
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
            .check(.updateWindowOpen)
        )
    }

    func testSettingsPresentationExplainsEveryCheckAvailability() throws {
        let unavailable = SettingsView.SoftwareUpdateActionPresentation.resolve(
            canInstall: false,
            isInstalling: false,
            isChecking: false,
            canCheck: false,
            sparkleIsPresenting: false
        )
        let updateWindowOpen = SettingsView.SoftwareUpdateActionPresentation.resolve(
            canInstall: false,
            isInstalling: false,
            isChecking: false,
            canCheck: true,
            sparkleIsPresenting: true
        )
        let ready = SettingsView.SoftwareUpdateActionPresentation.resolve(
            canInstall: false,
            isInstalling: false,
            isChecking: false,
            canCheck: true,
            sparkleIsPresenting: false
        )

        XCTAssertEqual(unavailable, .check(.unavailable))
        XCTAssertEqual(updateWindowOpen, .check(.updateWindowOpen))
        XCTAssertEqual(ready, .check(.ready))

        let unavailableState = try XCTUnwrap(unavailable.checkAvailability)
        let updateWindowOpenState = try XCTUnwrap(updateWindowOpen.checkAvailability)
        let readyState = try XCTUnwrap(ready.checkAvailability)

        XCTAssertFalse(unavailableState.isEnabled)
        XCTAssertEqual(unavailableState.visibleTitle, "Unavailable")
        XCTAssertEqual(
            unavailableState.accessibilityLabel,
            "Check for updates unavailable"
        )
        XCTAssertEqual(
            unavailableState.accessibilityHint,
            "This build does not include an update checker."
        )

        XCTAssertFalse(updateWindowOpenState.isEnabled)
        XCTAssertEqual(
            updateWindowOpenState.visibleTitle,
            "Update Window Open"
        )
        XCTAssertEqual(
            updateWindowOpenState.accessibilityLabel,
            "Update window already open"
        )
        XCTAssertEqual(
            updateWindowOpenState.accessibilityHint,
            "Finish or close the existing update window before checking again."
        )

        XCTAssertTrue(readyState.isEnabled)
        XCTAssertEqual(readyState.visibleTitle, "Check Now")
        XCTAssertEqual(
            readyState.accessibilityLabel,
            "Check for updates now"
        )
        XCTAssertEqual(
            readyState.accessibilityHint,
            "Opens Kaisola's update checker."
        )
    }

    func testBackgroundDownloadPresentationExplainsEveryAvailability() {
        let unavailable = SettingsView.SoftwareUpdateDownloadAvailability.resolve(
            canConfigureUpdates: false,
            allowsAutomaticUpdates: true,
            automaticallyChecksForUpdates: true
        )
        XCTAssertEqual(unavailable, .updaterUnavailable)
        XCTAssertFalse(unavailable.isEnabled)
        XCTAssertEqual(
            unavailable.visibleDetail,
            "Unavailable because this build cannot configure automatic updates"
        )
        XCTAssertEqual(
            unavailable.accessibilityHint,
            "Background downloads are unavailable because this build cannot configure automatic updates."
        )

        let unsupported = SettingsView.SoftwareUpdateDownloadAvailability.resolve(
            canConfigureUpdates: true,
            allowsAutomaticUpdates: false,
            automaticallyChecksForUpdates: true
        )
        XCTAssertEqual(unsupported, .interactiveUpdateRequired)
        XCTAssertFalse(unsupported.isEnabled)
        XCTAssertEqual(
            unsupported.visibleDetail,
            "This update type must be downloaded interactively"
        )
        XCTAssertEqual(
            unsupported.accessibilityHint,
            "Background downloads are unavailable because this update type requires an interactive download."
        )

        let checksRequired = SettingsView.SoftwareUpdateDownloadAvailability.resolve(
            canConfigureUpdates: true,
            allowsAutomaticUpdates: true,
            automaticallyChecksForUpdates: false
        )
        XCTAssertEqual(checksRequired, .automaticChecksRequired)
        XCTAssertFalse(checksRequired.isEnabled)
        XCTAssertEqual(
            checksRequired.visibleDetail,
            "Turn on automatic checks first"
        )
        XCTAssertEqual(
            checksRequired.accessibilityHint,
            "Enable Check for updates automatically before enabling background downloads."
        )

        let ready = SettingsView.SoftwareUpdateDownloadAvailability.resolve(
            canConfigureUpdates: true,
            allowsAutomaticUpdates: true,
            automaticallyChecksForUpdates: true
        )
        XCTAssertEqual(ready, .ready)
        XCTAssertTrue(ready.isEnabled)
        XCTAssertEqual(ready.visibleDetail, "Kaisola asks before restarting to install")
        XCTAssertEqual(
            ready.accessibilityHint,
            "Downloads updates in the background. Kaisola asks before restarting to install."
        )
    }

    func testBackgroundDownloadPresentationPrioritizesHardCapabilityLimits() {
        XCTAssertEqual(
            SettingsView.SoftwareUpdateDownloadAvailability.resolve(
                canConfigureUpdates: false,
                allowsAutomaticUpdates: false,
                automaticallyChecksForUpdates: false
            ),
            .updaterUnavailable
        )
        XCTAssertEqual(
            SettingsView.SoftwareUpdateDownloadAvailability.resolve(
                canConfigureUpdates: true,
                allowsAutomaticUpdates: false,
                automaticallyChecksForUpdates: false
            ),
            .interactiveUpdateRequired
        )
        XCTAssertEqual(
            SettingsView.SoftwareUpdateDownloadAvailability.resolve(
                canConfigureUpdates: true,
                allowsAutomaticUpdates: true,
                automaticallyChecksForUpdates: false
            ),
            .automaticChecksRequired
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
