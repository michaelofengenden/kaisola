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

    override convenience init() {
        self.init(bundle: .main)
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

    /// Owns the generation of the in-flight explicit check and matches
    /// Sparkle's cycle callbacks to it, so a stale, duplicate, or scheduled
    /// completion cannot overwrite a newer check's status (2026-08-06 spec
    /// §3d).
    private let checks = UpdateCheckArbiter(center: .shared)

    /// The menu item, the command palette, Settings' "Check Now", and the
    /// `.kaisolaCheckForUpdates` notification all land here, so two of them can
    /// easily arrive back to back. A trigger during a live cycle is a no-op:
    /// Sparkle folds a second request into the cycle it is already running, so
    /// asking again would only leave the running cycle's completion attached to
    /// a generation nobody is waiting on.
    func checkForUpdates(_ sender: Any?) {
        guard availability.canCheck, let standardController else { return }
        guard checks.beginExplicitCheck() else { return }
        standardController.checkForUpdates(sender)
    }

    fileprivate func finishCycle(_ cycle: UpdateCheckArbiter.Cycle, error: (any Error)?) {
        guard let error else {
            checks.finish(cycle: cycle, outcome: .upToDate)
            return
        }
        let ns = error as NSError
        // "The user cancelled" and "no update found" both surface as errors
        // from Sparkle; only real failures should read as failed.
        if ns.domain == "SUSparkleErrorDomain", ns.code == 1_001 {
            checks.finish(cycle: cycle, outcome: .upToDate)
        } else {
            checks.finish(cycle: cycle, outcome: .failed(reason: ns.localizedDescription))
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
        let cycle = UpdateCheckArbiter.Cycle(updateCheck)
        let boxed = error.map(UncheckedSendableBox.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                self?.finishCycle(cycle, error: boxed?.value)
            }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                self?.checks.finish(cycle: .explicit, outcome: .foundUpdate)
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

// MARK: - Check arbitration

/// Serializes explicit update checks against Sparkle's single update cycle.
///
/// `SPUUpdater` runs one cycle at a time. A second user-initiated request while
/// one is in flight is folded into the running cycle instead of starting
/// another, and a scheduled cycle is cancelled outright to make room for a
/// user-initiated one — that cancellation arrives as its own finished-cycle
/// callback. So the naive "mint a generation per trigger, resolve on the next
/// callback" pairing is wrong in both directions: the cancellation resolves a
/// check that never ran, and the real cycle's completion arrives with its
/// generation already consumed, leaving the spinner up for good.
///
/// One generation per real cycle fixes both. Deliberately free of Sparkle types
/// so the racing rules can be driven directly rather than through the updater.
@MainActor
final class UpdateCheckArbiter {
    /// Which Sparkle cycle a completion belongs to.
    enum Cycle: Equatable {
        /// `SPUUpdateCheckUpdates` — the user-initiated cycle this arbiter owns.
        case explicit
        /// A scheduled or informational cycle. Kaisola's check status never
        /// belongs to one, so its completion must not resolve anything.
        case background
    }

    /// How a cycle ended, in Kaisola's terms rather than Sparkle's.
    enum Outcome: Equatable {
        case upToDate
        case foundUpdate
        case failed(reason: String)
    }

    private let center: UpdateCenter
    private var activeGeneration: UInt64?

    init(center: UpdateCenter) {
        self.center = center
    }

    /// True while an explicit cycle is unresolved.
    var isChecking: Bool { activeGeneration != nil }

    /// Claims the cycle for a new explicit check. Returns `false` when one is
    /// already running, in which case the caller must leave Sparkle alone.
    @discardableResult
    func beginExplicitCheck() -> Bool {
        guard activeGeneration == nil else { return false }
        activeGeneration = center.beginCheck()
        return true
    }

    /// Resolves the explicit cycle. Completions from any other cycle, and
    /// completions that arrive after the explicit one already resolved, are
    /// dropped rather than allowed to rewrite the status.
    func finish(cycle: Cycle, outcome: Outcome) {
        guard cycle == .explicit, let generation = activeGeneration else { return }
        activeGeneration = nil
        switch outcome {
        case .upToDate:
            center.finishCheckUpToDate(generation: generation)
        case .foundUpdate:
            center.finishCheckFoundUpdate(generation: generation)
        case let .failed(reason):
            center.finishCheckFailed(generation: generation, reason: reason)
        }
    }
}

extension UpdateCheckArbiter.Cycle {
    init(_ updateCheck: SPUUpdateCheck) {
        self = updateCheck == .updates ? .explicit : .background
    }
}

/// Carries Sparkle's non-`Sendable` installation closure across the hop to the
/// main actor. Sparkle invokes its delegates on the main thread already, so the
/// value never actually crosses a thread; this only satisfies the checker.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
