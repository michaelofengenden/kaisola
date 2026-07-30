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
        let version: String
        /// Sparkle's immediate-installation block. Invoking it installs and
        /// relaunches with no further Sparkle UI.
        let install: () -> Void

        static func == (lhs: PendingUpdate, rhs: PendingUpdate) -> Bool {
            lhs.version == rhs.version
        }
    }

    /// Non-nil once an update is downloaded, verified, and ready to install.
    @Published private(set) var pendingUpdate: PendingUpdate?

    /// True while Sparkle is showing its own update UI, so Kaisola's affordance
    /// can step aside rather than duplicate it.
    @Published private(set) var sparkleIsPresentingUpdate = false

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
        // Kaisola's `applicationShouldTerminate` does on its first pass. Keep
        // the newest block and do not re-toast for a version already pending.
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
    func installAndRelaunch() {
        guard let pendingUpdate else { return }
        pendingUpdate.install()
    }
}
