import Foundation
import Sparkle

@MainActor
final class NativeUpdateController: NSObject {
    enum Availability: Equatable {
        case ready
        case unavailable(String)

        var canCheck: Bool {
            if case .ready = self { return true }
            return false
        }

        var detail: String? {
            if case let .unavailable(message) = self { return message }
            return nil
        }
    }

    private(set) var availability: Availability
    private var standardController: SPUStandardUpdaterController?
    private(set) var startedUpdater = false

    override convenience init() {
        self.init(bundle: .main)
    }

    /// Visual/resource fixtures exercise the installed application bundle in
    /// place. Starting Sparkle there would allow a background update to replace
    /// that evidence target and relaunch without the fixture's isolation
    /// environment, so these processes receive an inert controller that never
    /// constructs or starts an `SPUUpdater`.
    convenience init(isolatedFixture: Bool) {
        if isolatedFixture {
            self.init(disabledReason: "Updates are disabled in isolated fixtures.")
        } else {
            self.init(bundle: .main)
        }
    }

    private init(disabledReason: String) {
        availability = .unavailable(disabledReason)
        standardController = nil
        super.init()
    }

    init(bundle: Bundle) {
        // Seeded before `super.init()` so `self` is fully formed and can be
        // handed to Sparkle as a delegate below. Sparkle holds both delegates
        // weakly; the app delegate owns this object, so the lifetime is fine.
        availability = .unavailable("The Kaisola updater has not started.")
        standardController = nil
        super.init()

        do {
            _ = try NativeUpdateConfiguration.bundled(bundle)
            let controller = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            try controller.updater.start()
            standardController = controller
            startedUpdater = true
            availability = .ready
            UpdateCenter.shared.installPreferenceBridge(
                UpdateCenter.PreferenceBridge(
                    automaticallyChecks: { controller.updater.automaticallyChecksForUpdates },
                    setAutomaticallyChecks: { controller.updater.automaticallyChecksForUpdates = $0 },
                    automaticallyDownloads: { controller.updater.automaticallyDownloadsUpdates },
                    setAutomaticallyDownloads: { controller.updater.automaticallyDownloadsUpdates = $0 },
                    allowsAutomaticUpdates: { controller.updater.allowsAutomaticUpdates }
                )
            )
        } catch {
            standardController = nil
            availability = .unavailable(
                (error as? LocalizedError)?.errorDescription
                    ?? "The Kaisola updater could not start."
            )
        }
    }

    /// The generation of the in-flight explicit check, matched against
    /// Sparkle's cycle-finished callback so a stale completion cannot
    /// overwrite a newer check's status (2026-08-06 spec §3d).
    private var activeCheckGeneration: UInt64?

    func checkForUpdates(_ sender: Any?) {
        guard availability.canCheck, let standardController else { return }
        activeCheckGeneration = UpdateCenter.shared.beginCheck()
        standardController.checkForUpdates(sender)
    }

    fileprivate func finishCycle(error: (any Error)?, foundUpdate: Bool) {
        guard let generation = activeCheckGeneration else { return }
        activeCheckGeneration = nil
        if let error {
            let ns = error as NSError
            // "The user cancelled" and "no update found" both surface as
            // errors from Sparkle; only real failures should read as failed.
            if ns.domain == "SUSparkleErrorDomain", ns.code == 1_001 {
                UpdateCenter.shared.finishCheckUpToDate(generation: generation)
            } else {
                UpdateCenter.shared.finishCheckFailed(
                    generation: generation,
                    reason: ns.localizedDescription
                )
            }
        } else if foundUpdate {
            UpdateCenter.shared.finishCheckFoundUpdate(generation: generation)
        } else {
            UpdateCenter.shared.finishCheckUpToDate(generation: generation)
        }
    }

    // MARK: - Automatic update preferences
    //
    // These are read from and written straight through to `SPUUpdater`. Sparkle
    // resolves them from user defaults first and Info.plist second, so the
    // Info.plist values are only initial defaults — mirroring them into a
    // separate Kaisola preference would create a second source of truth that
    // silently disagrees with the updater. Sparkle's own docs warn against it.

    var automaticallyChecksForUpdates: Bool {
        get { standardController?.updater.automaticallyChecksForUpdates ?? false }
        set { standardController?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { standardController?.updater.automaticallyDownloadsUpdates ?? false }
        set { standardController?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Sparkle refuses background downloads for update kinds that must be shown
    /// (for example a major upgrade), so the toggle has to be disabled there.
    var allowsAutomaticUpdates: Bool {
        standardController?.updater.allowsAutomaticUpdates ?? false
    }

    var lastUpdateCheckDate: Date? {
        standardController?.updater.lastUpdateCheckDate
    }
}

// MARK: - SPUUpdaterDelegate

extension NativeUpdateController: SPUUpdaterDelegate {
    /// The hand-off that turns Sparkle's silent install-on-quit into a prompt.
    ///
    /// With no delegate, `SPUAutomaticUpdateDriver` aborts the cycle here and
    /// the update lands whenever the user next happens to quit, with no notice
    /// at all. Returning `true` claims the installation and hands us the block
    /// that installs and relaunches immediately, which is what the restart
    /// affordance invokes. Sparkle still installs on quit if the user never
    /// acts, so claiming it cannot strand the update.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        let install = UncheckedSendableBox(immediateInstallationBlock)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                UpdateCenter.shared.markReady(version: version, install: install.value)
            }
        }
        return true
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        let boxed = error.map(UncheckedSendableBox.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                self?.finishCycle(error: boxed?.value, foundUpdate: false)
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                self?.finishCycle(error: nil, foundUpdate: true)
            }
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension NativeUpdateController: SPUStandardUserDriverDelegate {
    /// Opt in to gentle reminders so Sparkle does not steal focus for updates
    /// the automatic driver declines to download silently (informational
    /// updates, major upgrades, or a failed signature check).
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let Sparkle present only when it already has the user's attention;
        // otherwise Kaisola surfaces it quietly through `UpdateCenter`.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                UpdateCenter.shared.setSparklePresenting(handleShowingUpdate)
                guard !handleShowingUpdate else { return }
                ToastCenter.shared.show("Kaisola \(version) is available", style: .info)
            }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                UpdateCenter.shared.setSparklePresenting(false)
            }
        }
    }
}

/// Carries Sparkle's non-`Sendable` installation closure across the hop to the
/// main actor. Sparkle invokes its delegates on the main thread already, so the
/// value never actually crosses a thread; this only satisfies the checker.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
