import AppKit
import Combine
import Foundation

@MainActor
struct UpdateInstallGateHooks {
    let hasBlockingPresentation: @MainActor () -> Bool
    let schedule: @MainActor (
        TimeInterval,
        @escaping @MainActor () -> Void
    ) -> Void

    static var live: UpdateInstallGateHooks {
        UpdateInstallGateHooks(
            hasBlockingPresentation: {
                applicationHasBlockingPresentation(NSApplication.shared)
            },
            schedule: { delay, work in
                Task { @MainActor in
                    if delay > 0 {
                        try? await Task.sleep(for: .seconds(delay))
                    } else {
                        await Task.yield()
                    }
                    guard !Task.isCancelled else { return }
                    work()
                }
            }
        )
    }

    static func applicationHasBlockingPresentation(_ application: NSApplication) -> Bool {
        application.modalWindow != nil
            || application.windows.contains { $0.attachedSheet != nil }
    }
}

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
        /// relaunches with no further Sparkle UI. Sparkle explicitly permits
        /// invoking this block again when AppKit cancels or delays the quit
        /// request, so it stays retained until the request reaches Kaisola's
        /// application delegate.
        fileprivate let install: (() -> Void)?

        static func == (lhs: PendingUpdate, rhs: PendingUpdate) -> Bool {
            lhs.version == rhs.version && lhs.phase == rhs.phase
        }
    }

    /// Non-nil once an update is downloaded and verified. The phase remains
    /// visible while installation starts so every app window can remove its
    /// restart action before Sparkle begins relaunching.
    @Published private(set) var pendingUpdate: PendingUpdate?

    /// The user's restart choice is app-global, but sheets are window-local.
    /// Keep the ready install block until every AppKit modal boundary is gone;
    /// consuming it while any window still owns a sheet reproduces AppKit's
    /// `App termination blocked by modal sheet` failure.
    private let installGate: UpdateInstallGateHooks
    private var installTicket: UInt64 = 0
    private var activeInstallTicket: UInt64?
    private var confirmedClearTicket: UInt64?
    private var scheduledInstallTicket: UInt64?

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

    /// The app always goes through `shared`; the initializer is reachable so
    /// check-status transitions can be driven on a throwaway instance while
    /// installed-app QA can inject its explicitly gated visual environment.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        installGate: UpdateInstallGateHooks = .live
    ) {
        self.installGate = installGate
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
        // A later update cycle can hand over a newer ready block before the
        // user chooses to restart. Keep the newest one and do not re-toast for
        // a version already pending. Once installation starts, never restore
        // an action that another window could invoke during relaunch latency.
        guard pendingUpdate?.phase != .installing else { return }
        let alreadyPending = pendingUpdate?.version == version
        pendingUpdate = PendingUpdate(version: version, phase: .ready, install: install)
        if let activeInstallTicket, scheduledInstallTicket == nil {
            advanceInstallation(ticket: activeInstallTicket)
        }
        guard !alreadyPending else { return }
        ToastCenter.shared.show("Kaisola \(version) is ready — restart to install", style: .success)
    }

    func setSparklePresenting(_ presenting: Bool) {
        sparkleIsPresentingUpdate = presenting
    }

    func clear() {
        installTicket &+= 1
        activeInstallTicket = nil
        confirmedClearTicket = nil
        scheduledInstallTicket = nil
        pendingUpdate = nil
    }

    /// Install and relaunch now. Terminal PTYs end with the app; the Sparkle
    /// relaunch reopens them at their recorded cwd via dormant-terminal
    /// resurrection. ACP chats and Mesh columns are interrupted mid-turn, so
    /// callers should warn when `AppModel.interruptibleTurnCount` is nonzero.
    func installAndRelaunch() {
        guard let pendingUpdate,
              pendingUpdate.phase == .ready,
              pendingUpdate.install != nil else { return }
        if activeInstallTicket == nil {
            installTicket &+= 1
            activeInstallTicket = installTicket
            confirmedClearTicket = nil
        }
        guard let activeInstallTicket, scheduledInstallTicket == nil else { return }
        advanceInstallation(ticket: activeInstallTicket)
    }

    /// Sparkle sends an ordinary Apple quit event after its asynchronous
    /// installer work reaches stage two. AppKit may reject that event before
    /// calling the application delegate when any window owns a modal sheet.
    /// Until this acknowledgement arrives, keep retrying Sparkle's documented
    /// repeatable immediate-install handler. Once it arrives, Kaisola's bounded
    /// teardown owns the prepared second quit and the handler can be released.
    func applicationTerminationDidReachDelegate() {
        guard let activeInstallTicket,
              let pendingUpdate,
              pendingUpdate.phase == .installing else { return }
        self.activeInstallTicket = nil
        confirmedClearTicket = nil
        scheduledInstallTicket = nil
        self.pendingUpdate = PendingUpdate(
            version: pendingUpdate.version,
            phase: .installing,
            install: nil
        )
        // Advance the generation so any scheduler callback that escaped the
        // active-ticket guard cannot match a later install request.
        installTicket = max(installTicket, activeInstallTicket) &+ 1
    }

    private func advanceInstallation(ticket: UInt64) {
        guard activeInstallTicket == ticket,
              let pendingUpdate,
              pendingUpdate.phase == .ready || pendingUpdate.phase == .installing,
              let install = pendingUpdate.install else { return }

        if installGate.hasBlockingPresentation() {
            confirmedClearTicket = nil
            scheduleInstallationAdvance(ticket: ticket, after: 0.05)
            return
        }

        guard confirmedClearTicket == ticket else {
            confirmedClearTicket = ticket
            scheduleInstallationAdvance(ticket: ticket, after: 0)
            return
        }

        confirmedClearTicket = nil
        scheduledInstallTicket = nil
        self.pendingUpdate = PendingUpdate(
            version: pendingUpdate.version,
            phase: .installing,
            install: install
        )
        install()
        // `immediateInstallationBlock` first queues Sparkle's real installer
        // work onto the main queue. A sheet can therefore appear after the
        // clear probes above and block the later Apple quit event before the
        // application delegate sees it. Keep a single watchdog alive until
        // the delegate acknowledges the request; another invocation causes
        // Sparkle's installer to send the quit event again.
        scheduleInstallationAdvance(ticket: ticket, after: 1.0)
    }

    private func scheduleInstallationAdvance(ticket: UInt64, after delay: TimeInterval) {
        guard activeInstallTicket == ticket, scheduledInstallTicket == nil else { return }
        scheduledInstallTicket = ticket
        installGate.schedule(delay) { [weak self] in
            guard let self,
                  self.activeInstallTicket == ticket,
                  self.scheduledInstallTicket == ticket else { return }
            self.scheduledInstallTicket = nil
            self.advanceInstallation(ticket: ticket)
        }
    }
}
