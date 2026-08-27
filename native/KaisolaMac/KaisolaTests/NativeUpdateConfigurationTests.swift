import AppKit
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
        let gate = ManualUpdateInstallGate()
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
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
        XCTAssertEqual(installCallCount, 0)
        XCTAssertEqual(center.pendingUpdate?.phase, .ready)

        gate.elapse()

        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(phaseDuringInstall, .installing)
        XCTAssertEqual(center.pendingUpdate?.phase, .installing)
        XCTAssertFalse(center.canInstallPendingUpdate)
        XCTAssertTrue(center.isInstallingUpdate)
    }

    func testInstallingStatePublishesToEveryObserverAndRejectsAReofferedClosure() {
        let gate = ManualUpdateInstallGate()
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
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
        gate.elapse()
        center.markReady(version: "2.0.0") { replacementCallCount += 1 }
        center.installAndRelaunch()

        XCTAssertEqual(firstWindowPhases, [.ready, .installing])
        XCTAssertEqual(secondWindowPhases, [.ready, .installing])
        XCTAssertEqual(center.pendingUpdate?.phase, .installing)
        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(replacementCallCount, 0)
    }

    func testReadyUpdateReplacementInvokesOnlyTheNewestInstallClosure() {
        let gate = ManualUpdateInstallGate()
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
        var replacedInstallCallCount = 0
        var currentInstallCallCount = 0

        center.markReady(version: "2.0.0") { replacedInstallCallCount += 1 }
        center.markReady(version: "2.0.1") { currentInstallCallCount += 1 }

        XCTAssertEqual(center.pendingUpdate?.version, "2.0.1")
        XCTAssertEqual(center.pendingUpdate?.phase, .ready)
        center.installAndRelaunch()
        gate.elapse()
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

    func testWorkspaceSettingsCheckRunsOnlyAfterTheSheetDismisses() {
        let coordinator = SettingsSheetUpdateCoordinator()
        var events: [String] = []

        coordinator.request(.check) {
            events.append("dismiss")
        }

        XCTAssertEqual(events, ["dismiss"])
        XCTAssertEqual(coordinator.pendingAction, .check)

        coordinator.performAfterDismissal(
            check: { events.append("check") },
            install: { events.append("install") }
        )
        coordinator.performAfterDismissal(
            check: { events.append("duplicate-check") },
            install: { events.append("duplicate-install") }
        )

        XCTAssertEqual(events, ["dismiss", "check"])
        XCTAssertNil(coordinator.pendingAction)
    }

    func testWorkspaceSettingsInstallRunsOnlyAfterTheSheetDismisses() {
        let coordinator = SettingsSheetUpdateCoordinator()
        var events: [String] = []

        coordinator.request(.install) {
            events.append("dismiss")
        }
        coordinator.request(.check) {
            events.append("second-dismiss")
        }

        XCTAssertEqual(events, ["dismiss"])
        XCTAssertEqual(coordinator.pendingAction, .install)

        coordinator.performAfterDismissal(
            check: { events.append("check") },
            install: { events.append("install") }
        )

        XCTAssertEqual(events, ["dismiss", "install"])
        XCTAssertNil(coordinator.pendingAction)
    }

    func testProductionInstallGateDetectsAnyApplicationSheet() {
        _ = NSApplication.shared
        let firstRoot = makeUpdateTestWindow()
        let secondRoot = makeUpdateTestWindow()
        let firstSheet = makeUpdateTestWindow()
        let secondSheet = makeUpdateTestWindow()
        firstRoot.beginSheet(firstSheet, completionHandler: nil)
        secondRoot.beginSheet(secondSheet, completionHandler: nil)
        defer {
            if firstRoot.attachedSheet != nil { firstRoot.endSheet(firstSheet) }
            if secondRoot.attachedSheet != nil { secondRoot.endSheet(secondSheet) }
        }

        XCTAssertTrue(
            UpdateInstallGateHooks.applicationHasBlockingPresentation(NSApplication.shared)
        )

        firstRoot.endSheet(firstSheet)
        XCTAssertTrue(
            UpdateInstallGateHooks.applicationHasBlockingPresentation(NSApplication.shared)
        )

        secondRoot.endSheet(secondSheet)
        XCTAssertFalse(
            UpdateInstallGateHooks.applicationHasBlockingPresentation(NSApplication.shared)
        )
    }

    func testInstallDefersUntilEveryBlockerClears() {
        let gate = ManualUpdateInstallGate(blockerCount: 2)
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
        var installCallCount = 0
        center.markReady(version: "2.0.0") { installCallCount += 1 }

        center.installAndRelaunch()
        XCTAssertEqual(installCallCount, 0)
        XCTAssertEqual(center.pendingUpdate?.phase, .ready)
        XCTAssertEqual(gate.waitingCount, 1)

        gate.elapse()
        gate.blockerCount = 1
        gate.elapse()
        XCTAssertEqual(installCallCount, 0)
        XCTAssertEqual(center.pendingUpdate?.phase, .ready)

        gate.blockerCount = 0
        gate.elapse()
        XCTAssertEqual(installCallCount, 0, "the first clear probe only arms confirmation")
        XCTAssertEqual(center.pendingUpdate?.phase, .ready)

        gate.elapse()
        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(center.pendingUpdate?.phase, .installing)
    }

    func testInstallReturnsToWaitingWhenABlockerAppearsDuringClearConfirmation() {
        let gate = ManualUpdateInstallGate(blockerCount: 1)
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
        var installCallCount = 0
        center.markReady(version: "2.0.0") { installCallCount += 1 }

        center.installAndRelaunch()
        gate.blockerCount = 0
        gate.elapse()
        XCTAssertEqual(installCallCount, 0)

        gate.blockerCount = 1
        gate.elapse()
        XCTAssertEqual(installCallCount, 0)
        XCTAssertEqual(center.pendingUpdate?.phase, .ready)

        gate.blockerCount = 0
        gate.elapse()
        XCTAssertEqual(installCallCount, 0)
        gate.elapse()
        XCTAssertEqual(installCallCount, 1)
    }

    func testInstallRetriesWhenAModalAppearsAfterTheFirstSparkleInvocation() {
        let gate = ManualUpdateInstallGate()
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
        var installCallCount = 0
        center.markReady(version: "2.0.0") {
            installCallCount += 1
            if installCallCount == 1 {
                // Sparkle queues the real install and quit work. Model a sheet
                // arriving after Kaisola's final clear probe but before that
                // queued quit request reaches the application delegate.
                gate.blockerCount = 1
            }
        }

        center.installAndRelaunch()
        gate.elapse()
        gate.elapse()
        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(center.pendingUpdate?.phase, .installing)
        XCTAssertEqual(gate.waitingCount, 1, "the first invocation must remain retryable")

        gate.elapse()
        XCTAssertEqual(installCallCount, 1)

        gate.blockerCount = 0
        gate.elapse()
        XCTAssertEqual(installCallCount, 1, "a clear retry boundary still needs confirmation")
        gate.elapse()

        XCTAssertEqual(installCallCount, 2)
        XCTAssertEqual(center.pendingUpdate?.phase, .installing)
    }

    func testTerminationDelegateAcknowledgementStopsInstallRetries() {
        let gate = ManualUpdateInstallGate()
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
        var installCallCount = 0
        center.markReady(version: "2.0.0") { installCallCount += 1 }

        center.installAndRelaunch()
        gate.elapse()
        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(gate.waitingCount, 1)

        center.applicationTerminationDidReachDelegate()
        gate.elapse()
        gate.elapse()

        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(center.pendingUpdate?.phase, .installing)
        XCTAssertEqual(gate.waitingCount, 0)
    }

    func testTerminationCleanupEndsAttachedSheetsAcrossApplicationWindows() {
        _ = NSApplication.shared
        let firstRoot = makeUpdateTestWindow()
        let secondRoot = makeUpdateTestWindow()
        let firstSheet = makeUpdateTestWindow()
        let secondSheet = makeUpdateTestWindow()
        firstRoot.beginSheet(firstSheet, completionHandler: nil)
        secondRoot.beginSheet(secondSheet, completionHandler: nil)

        KaisolaMacAppDelegate.endAttachedSheets(in: NSApplication.shared)

        XCTAssertNil(firstRoot.attachedSheet)
        XCTAssertNil(secondRoot.attachedSheet)
    }

    func testPreparedTerminationWaitsForModalSessionToUnwind() {
        let state = ManualPreparedTerminationState()
        var events: [String] = []
        let coordinator = PreparedApplicationTerminationCoordinator(
            hooks: PreparedApplicationTerminationHooks(
                dismissAttachedSheets: { events.append("dismiss-sheets") },
                hasBlockingPresentation: { state.blockerPresent },
                hasModalWindow: { state.modalPresent },
                abortModal: { events.append("abort-modal") },
                schedule: { _, work in state.scheduled.append(work) },
                terminate: { events.append("terminate") }
            )
        )

        coordinator.attempt()

        XCTAssertEqual(events, ["dismiss-sheets", "abort-modal"])
        XCTAssertEqual(state.scheduled.count, 1)

        // AppKit keeps modalWindow populated until the modal session unwinds,
        // even after abortModal. The next scheduled turn observes the clear
        // boundary and only then asks AppKit to terminate.
        state.modalPresent = false
        state.blockerPresent = false
        let due = state.scheduled
        state.scheduled.removeAll()
        due.forEach { $0() }

        XCTAssertEqual(
            events,
            ["dismiss-sheets", "abort-modal", "dismiss-sheets", "terminate"]
        )
        XCTAssertTrue(state.scheduled.isEmpty)
    }

    func testPreparedTerminationAbortsRealRunModalAndThenTerminates() {
        let application = NSApplication.shared
        let modalWindow = makeUpdateTestWindow()
        let state = ManualPreparedTerminationState()
        let coordinator = PreparedApplicationTerminationCoordinator(
            hooks: PreparedApplicationTerminationHooks(
                dismissAttachedSheets: {
                    KaisolaMacAppDelegate.endAttachedSheets(in: application)
                },
                hasBlockingPresentation: {
                    UpdateInstallGateHooks.applicationHasBlockingPresentation(application)
                },
                hasModalWindow: { application.modalWindow != nil },
                abortModal: { application.abortModal() },
                schedule: { _, work in state.scheduled.append(work) },
                terminate: { state.terminateCallCount += 1 }
            )
        )

        // `runModal` is the modal API used by Kaisola's alerts and panels. Its
        // nested loop services the queued coordinator attempt, which aborts
        // the real AppKit modal session but must not terminate on that turn.
        DispatchQueue.main.async { coordinator.attempt() }
        let response = application.runModal(for: modalWindow)

        XCTAssertEqual(response, .abort)
        XCTAssertNil(application.modalWindow)
        XCTAssertEqual(state.terminateCallCount, 0)
        XCTAssertEqual(state.scheduled.count, 1)

        let due = state.scheduled
        state.scheduled.removeAll()
        due.forEach { $0() }

        XCTAssertEqual(state.terminateCallCount, 1)
        XCTAssertTrue(state.scheduled.isEmpty)
    }

    func testRepeatedInstallRequestsCoalesceAndStaleCallbacksCannotReinstall() {
        let gate = ManualUpdateInstallGate(blockerCount: 1)
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
        var installCallCount = 0
        center.markReady(version: "2.0.0") { installCallCount += 1 }

        center.installAndRelaunch()
        center.installAndRelaunch()
        center.installAndRelaunch()
        XCTAssertEqual(gate.waitingCount, 1)

        gate.blockerCount = 0
        gate.elapse()
        gate.elapse()
        center.applicationTerminationDidReachDelegate()
        gate.elapse()

        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(gate.waitingCount, 0)
    }

    func testClearInvalidatesADeferredInstall() {
        let gate = ManualUpdateInstallGate(blockerCount: 1)
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
        var installCallCount = 0
        center.markReady(version: "2.0.0") { installCallCount += 1 }
        center.installAndRelaunch()

        center.clear()
        gate.blockerCount = 0
        gate.elapse()
        gate.elapse()

        XCTAssertEqual(installCallCount, 0)
        XCTAssertNil(center.pendingUpdate)
        XCTAssertEqual(gate.waitingCount, 0)
    }

    func testReadyClosureReplacementWhileWaitingInstallsOnlyTheNewestUpdate() {
        let gate = ManualUpdateInstallGate(blockerCount: 1)
        let center = UpdateCenter(environment: [:], installGate: gate.hooks)
        var firstInstallCallCount = 0
        var replacementInstallCallCount = 0
        center.markReady(version: "2.0.0") { firstInstallCallCount += 1 }
        center.installAndRelaunch()
        center.markReady(version: "2.0.1") { replacementInstallCallCount += 1 }

        gate.blockerCount = 0
        gate.elapse()
        gate.elapse()

        XCTAssertEqual(firstInstallCallCount, 0)
        XCTAssertEqual(replacementInstallCallCount, 1)
        XCTAssertEqual(center.pendingUpdate?.version, "2.0.1")
        XCTAssertEqual(center.pendingUpdate?.phase, .installing)
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

    private func makeUpdateTestWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
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

/// Advances the install gate one scheduled turn at a time. Work queued while a
/// turn drains belongs to the next turn, matching the production main-actor
/// confirmation hop without a clock or run-loop race.
@MainActor
private final class ManualUpdateInstallGate {
    var blockerCount: Int
    private var waiting: [@MainActor () -> Void] = []

    init(blockerCount: Int = 0) {
        self.blockerCount = blockerCount
    }

    var waitingCount: Int { waiting.count }

    var hooks: UpdateInstallGateHooks {
        UpdateInstallGateHooks(
            hasBlockingPresentation: { [unowned self] in blockerCount > 0 },
            schedule: { [unowned self] _, work in waiting.append(work) }
        )
    }

    func elapse() {
        let due = waiting
        waiting.removeAll()
        for work in due { work() }
    }
}

@MainActor
private final class ManualPreparedTerminationState {
    var blockerPresent = true
    var modalPresent = true
    var scheduled: [@MainActor () -> Void] = []
    var terminateCallCount = 0
}
