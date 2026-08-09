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
        enum Phase: Equatable {
            case ready
            case installing
        }

        let version: String
        let phase: Phase
        /// Sparkle's immediate-installation block. Invoking it installs and
        /// relaunches with no further Sparkle UI. It is removed before the
        /// phase becomes `installing`, so no path can retain and invoke it
        /// twice while the relaunch is pending.
        fileprivate let install: (() -> Void)?

        static func == (lhs: PendingUpdate, rhs: PendingUpdate) -> Bool {
            lhs.version == rhs.version && lhs.phase == rhs.phase
        }
    }

    /// Non-nil once an update is downloaded and verified. The phase remains
    /// visible while installation starts so every app window can remove its
    /// restart action before Sparkle begins relaunching.
    @Published private(set) var pendingUpdate: PendingUpdate?

    var canInstallPendingUpdate: Bool {
        pendingUpdate?.phase == .ready
    }

    var isInstallingUpdate: Bool {
        pendingUpdate?.phase == .installing
    }

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

    private init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        pendingUpdate = Self.visualFixturePendingUpdate(environment: environment)
    }

    /// Installed-app QA can exercise the real ready → installing UI without
    /// asking Sparkle to contact a feed or relaunch the fixture. Both gates are
    /// required so an ordinary launch can never manufacture update state.
    static func visualFixturePendingUpdate(
        environment: [String: String]
    ) -> PendingUpdate? {
        guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1" else { return nil }
        let phase: PendingUpdate.Phase
        switch environment["KAISOLA_NATIVE_VISUAL_UPDATE_PHASE"] {
        case "ready": phase = .ready
        case "installing": phase = .installing
        default: return nil
        }
        let requestedVersion = environment["KAISOLA_NATIVE_VISUAL_UPDATE_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = requestedVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "99.0"
        let install: (() -> Void)? = phase == .ready ? {
            let line = Data("KAISOLA_NATIVE_VISUAL_UPDATE_INSTALL=PASS\n".utf8)
            FileHandle.standardOutput.write(line)
            try? FileHandle.standardOutput.synchronize()
        } : nil
        return PendingUpdate(version: version, phase: phase, install: install)
    }

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
        // the newest ready block and do not re-toast for a version already
        // pending. Once installation starts, however, never restore an action
        // that another window could invoke during relaunch latency.
        guard pendingUpdate?.phase != .installing else { return }
        let alreadyPending = pendingUpdate?.version == version
        pendingUpdate = PendingUpdate(version: version, phase: .ready, install: install)
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
        guard let pendingUpdate,
              pendingUpdate.phase == .ready,
              let install = pendingUpdate.install else { return }
        self.pendingUpdate = PendingUpdate(
            version: pendingUpdate.version,
            phase: .installing,
            install: nil
        )
        install()
    }
}
