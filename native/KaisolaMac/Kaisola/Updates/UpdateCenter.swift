import Combine
import Foundation

/// App-global "an update is downloaded and waiting" state.
///
/// Sparkle's automatic driver, left to itself, installs silently on the next
/// quit and tells the user nothing. That is the wrong contract for Kaisola:
/// relaunching is a visible event here (ACP chats and Mesh columns are
/// in-process children that a relaunch aborts), so the user should be the one
/// who chooses the moment.
///
/// `NativeUpdateController` intercepts the install-on-quit hand-off and parks
/// the installation here instead. Nothing is lost by waiting — Sparkle still
/// installs on quit if the prompt is ignored — so this only ever *adds* a
/// chance to restart deliberately.
///
/// Lives as a shared singleton for the same reason `ToastCenter` and
/// `AttentionCenter` do: `RootShellView` is per-window and this state is
/// per-app, so a per-window `@State` would desync across windows.
@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    struct PendingUpdate: Equatable {
        /// A pending update is claimed exactly once. `installing` is entered
        /// *before* Sparkle's block runs, because the relaunch that follows is
        /// not instantaneous: Sparkle asks the app to quit, Kaisola's
        /// `applicationShouldTerminate` cancels that first pass and drains its
        /// windows, and the whole window is wide enough for a second click to
        /// land on a restart button that is still enabled.
        enum State: Equatable { case ready, installing }

        let version: String
        /// Sparkle's immediate-installation block. Invoking it installs and
        /// relaunches with no further Sparkle UI.
        let install: () -> Void
        /// Only `installAndRelaunch()` moves this, and only forwards.
        fileprivate(set) var state: State = .ready

        static func == (lhs: PendingUpdate, rhs: PendingUpdate) -> Bool {
            lhs.version == rhs.version && lhs.state == rhs.state
        }
    }

    /// Non-nil once an update is downloaded, verified, and ready to install.
    @Published private(set) var pendingUpdate: PendingUpdate?

    /// The single flag every restart affordance disables on. Settings is a
    /// per-window view — the standalone ⌘, window and each workspace's settings
    /// sheet each build their own button — so the disable has to come from this
    /// shared state or the other windows keep offering a restart that has
    /// already been claimed.
    var isInstalling: Bool { pendingUpdate?.state == .installing }

    /// True while Sparkle is showing its own update UI, so Kaisola's affordance
    /// can step aside rather than duplicate it.
    @Published private(set) var sparkleIsPresentingUpdate = false

    /// What checking is doing right now — deliberately a SEPARATE axis from
    /// `pendingUpdate` (2026-08-06 spec §3d): clearing or replacing check
    /// state must never discard a handed-over install block. Every Sparkle
    /// delegate callback maps to exactly one transition here, and results are
    /// generation-fenced so an abandoned check cannot overwrite a newer one.
    enum CheckStatus: Equatable {
        case idle(lastChecked: Date?)
        case checking(generation: UInt64)
        case upToDate(at: Date)
        case failed(reason: String, at: Date)
    }

    @Published private(set) var checkStatus: CheckStatus = .idle(lastChecked: nil)
    private var checkGeneration: UInt64 = 0

    /// A user- or timer-initiated check began.
    func beginCheck() -> UInt64 {
        checkGeneration &+= 1
        checkStatus = .checking(generation: checkGeneration)
        return checkGeneration
    }

    /// The check finished with no update available.
    func finishCheckUpToDate(generation: UInt64) {
        guard case .checking(let current) = checkStatus, current == generation else { return }
        checkStatus = .upToDate(at: Date())
    }

    /// The check failed (network, appcast, signature…).
    func finishCheckFailed(generation: UInt64, reason: String) {
        guard case .checking(let current) = checkStatus, current == generation else { return }
        checkStatus = .failed(reason: reason, at: Date())
    }

    /// The check found an update (Sparkle proceeds to download/present); the
    /// spinner ends, and readiness arrives later on the OTHER axis.
    func finishCheckFoundUpdate(generation: UInt64) {
        guard case .checking(let current) = checkStatus, current == generation else { return }
        checkStatus = .idle(lastChecked: Date())
    }

    /// Mirrors of Sparkle's preferences, republished so SwiftUI re-renders on
    /// change. `SPUUpdater` remains the source of truth — these are refreshed
    /// from it after every write rather than stored independently, because
    /// Sparkle resolves the real values from user defaults itself and a second
    /// store would quietly disagree with the updater that acts on them.
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var canConfigureUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false

    /// Installed once by `NativeUpdateController`, so any window can reach the
    /// updater without threading a reference through every Settings call site.
    struct PreferenceBridge {
        let automaticallyChecks: () -> Bool
        let setAutomaticallyChecks: (Bool) -> Void
        let automaticallyDownloads: () -> Bool
        let setAutomaticallyDownloads: (Bool) -> Void
        let allowsAutomaticUpdates: () -> Bool
    }

    private var bridge: PreferenceBridge?

    private init() {}

    func installPreferenceBridge(_ bridge: PreferenceBridge) {
        self.bridge = bridge
        canConfigureUpdates = true
        refreshPreferences()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        bridge?.setAutomaticallyChecks(enabled)
        refreshPreferences()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        bridge?.setAutomaticallyDownloads(enabled)
        refreshPreferences()
    }

    private func refreshPreferences() {
        guard let bridge else { return }
        automaticallyChecksForUpdates = bridge.automaticallyChecks()
        automaticallyDownloadsUpdates = bridge.automaticallyDownloads()
        allowsAutomaticUpdates = bridge.allowsAutomaticUpdates()
    }

    func markReady(version: String, install: @escaping () -> Void) {
        // Sparkle can hand the block over more than once — the docs note the
        // installer may re-offer when a termination request is cancelled, which
        // Kaisola's `applicationShouldTerminate` does on its first pass. Once a
        // restart has been claimed that re-offer arrives *during* the relaunch,
        // so taking it would re-arm the button the user just pressed; the app is
        // already on its way out and there is nothing left to offer.
        guard !isInstalling else { return }
        // Otherwise keep the newest block and do not re-toast for a version
        // already pending.
        let alreadyPending = pendingUpdate?.version == version
        pendingUpdate = PendingUpdate(version: version, install: install)
        guard !alreadyPending else { return }
        ToastCenter.shared.show("Kaisola \(version) is ready — restart to install", style: .success)
    }

    func setSparklePresenting(_ presenting: Bool) {
        sparkleIsPresentingUpdate = presenting
    }

    func clear() {
        pendingUpdate = nil
    }

    /// Install and relaunch now. Terminal sessions survive this — they live in
    /// the detached broker — but in-process ACP chats and Mesh columns do not,
    /// so callers should warn when `AppModel.interruptibleTurnCount` is nonzero.
    ///
    /// One-shot: the pending update moves to `.installing` before the block is
    /// invoked, so a second activation — a double-click, a second window's
    /// button, a re-offer from Sparkle — returns `false` instead of starting a
    /// second installation while the first is still relaunching.
    @discardableResult
    func installAndRelaunch() -> Bool {
        guard let pendingUpdate, pendingUpdate.state == .ready else { return false }
        // Claim first, invoke second. The claim is published before the block
        // runs, so anything the block re-enters (Sparkle's quit request drives
        // MainActor work) already sees the update as spoken for.
        self.pendingUpdate?.state = .installing
        pendingUpdate.install()
        return true
    }
}
