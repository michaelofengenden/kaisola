import AppKit
import Combine
import Darwin
import KaisolaCore
import QuartzCore
import ScreenCaptureKit
import Security
import SwiftUI
import WebKit

private let linkSmokeTimeoutSignalHandler: @convention(c) (Int32) -> Void = { _ in
    // Signal-handler context permits only async-signal-safe work. The marker is
    // a 34-byte ASCII literal; `write` and `_exit` keep the smoke probe bounded
    // even when a framework blocks the main actor or a cooperative task.
    "KAISOLA_NATIVE_LINK_SMOKE=TIMEOUT\n".withCString { pointer in
        _ = Darwin.write(STDOUT_FILENO, pointer, 34)
    }
    Darwin._exit(124)
}

private let linkSmokeAuthTimeoutSignalHandler: @convention(c) (Int32) -> Void = { _ in
    "KAISOLA_NATIVE_LINK_SMOKE=AUTH_TIMEOUT\n".withCString { pointer in
        _ = Darwin.write(STDOUT_FILENO, pointer, 39)
    }
    Darwin._exit(124)
}

private let linkSmokeStorageTimeoutSignalHandler: @convention(c) (Int32) -> Void = { _ in
    "KAISOLA_NATIVE_LINK_SMOKE=STORAGE_TIMEOUT\n".withCString { pointer in
        _ = Darwin.write(STDOUT_FILENO, pointer, 42)
    }
    Darwin._exit(124)
}

private let linkSmokeInputTimeoutSignalHandler: @convention(c) (Int32) -> Void = { _ in
    "KAISOLA_NATIVE_LINK_SMOKE=INPUT_TIMEOUT\n".withCString { pointer in
        _ = Darwin.write(STDOUT_FILENO, pointer, 40)
    }
    Darwin._exit(124)
}

private let linkSmokeRelayTimeoutSignalHandler: @convention(c) (Int32) -> Void = { _ in
    "KAISOLA_NATIVE_LINK_SMOKE=RELAY_TIMEOUT\n".withCString { pointer in
        _ = Darwin.write(STDOUT_FILENO, pointer, 40)
    }
    Darwin._exit(124)
}

private let catalogSmokeTimeoutSignalHandler: @convention(c) (Int32) -> Void = { _ in
    "KAISOLA_NATIVE_CATALOG_SMOKE=TIMEOUT\n".withCString { pointer in
        _ = Darwin.write(STDOUT_FILENO, pointer, 37)
    }
    Darwin._exit(124)
}

private let catalogSmokeInputTimeoutSignalHandler: @convention(c) (Int32) -> Void = { _ in
    "KAISOLA_NATIVE_CATALOG_SMOKE=INPUT_TIMEOUT\n".withCString { pointer in
        _ = Darwin.write(STDOUT_FILENO, pointer, 43)
    }
    Darwin._exit(124)
}

/// The pre-0.1.131 local app wrote its Firebase refresh token under an ad-hoc
/// code-signing identity. macOS correctly requires a human decision before a
/// differently designated Developer ID build can read or rewrite that item.
/// Production builds therefore start in their stable bundle-derived namespace
/// and ask for one clean sign-in instead of blocking every launch on the legacy
/// ACL. Once established, the Developer ID requirement remains stable across
/// subsequent updates.
private enum NativeAccountKeychainMigration {
    static let completionDefaultsKey = "firebase-auth.developer-id-keychain-v1"
    static let notice = "Kaisola is now Developer ID signed. Sign in once to create a stable saved session for this and future updates."
}

/// End-to-end production-relay proof used only by the signed smoke artifact.
/// It deliberately creates an ephemeral desktop identity and 0700/0600 roster
/// instead of touching the user's production Companion identity or paired
/// devices. The real browser initiator must complete Noise, mutual key/SAS
/// confirmation, observe-only hello negotiation, projection decryption, and an
/// authenticated ACK, pinned resume, live revocation, and denied post-revoke
/// resume before this actor reports success.
private actor CompanionNativeBrowserLinkSmoke {
    typealias Finish = @Sendable (String) -> Void
    typealias Emit = @Sendable (String) -> Void

    private let coordinator: CompanionPairingCoordinator
    private let roster: CompanionDeviceRosterStore
    private let epoch: String
    private let cleanupURL: URL
    private let emit: Emit
    private let finish: Finish
    private var connection: CompanionRelayConnection?
    private var connectionID: String?
    private var authenticatedAsResume = false
    private var initialProjectionSent = false
    private var initialProjectionAcknowledged = false
    private var resumeProjectionSent = false
    private var authenticatedDeviceID: String?
    private var revocationStarted = false
    private var revokedResumeAttemptAccepted = false
    private var revocationDenied = false
    private var finished = false

    init(
        coordinator: CompanionPairingCoordinator,
        roster: CompanionDeviceRosterStore,
        cleanupURL: URL,
        emit: @escaping Emit,
        finish: @escaping Finish
    ) {
        self.coordinator = coordinator
        self.roster = roster
        self.cleanupURL = cleanupURL
        self.emit = emit
        self.finish = finish
        epoch = "epoch-native-browser-smoke-\(UUID().uuidString.lowercased())"
    }

    func accept(_ socket: CompanionRelayVirtualSocket) async {
        guard !finished else {
            await socket.localClose()
            return
        }
        if let previous = connection {
            guard initialProjectionAcknowledged, !resumeProjectionSent else {
                await socket.localClose()
                await fail()
                return
            }
            connection = nil
            connectionID = nil
            await previous.close(reason: "smoke_reconnecting")
        }
        if revocationStarted {
            guard !revokedResumeAttemptAccepted else {
                await socket.localClose()
                await fail()
                return
            }
            revokedResumeAttemptAccepted = true
        }
        // Match the production host's replacement fence: a relay can reuse a
        // mux channel ID while the old close is still draining, so the
        // coordinator socket key must remain unique per accepted connection.
        let id = "relay-native-browser-smoke-\(socket.id)-\(UUID().uuidString.lowercased())"
        let connection = CompanionRelayConnection(
            id: id,
            socket: socket,
            coordinator: coordinator,
            epoch: epoch
        ) { [weak self] event in
            Task { await self?.handle(event, connectionID: id) }
        } diagnosticSink: { [weak self] diagnostic in
            Task { await self?.reportDiagnostic(diagnostic) }
        }
        self.connection = connection
        connectionID = id
        do { try await connection.start() }
        catch { await fail() }
    }

    private func handle(_ event: CompanionConnectionEvent, connectionID eventConnectionID: String) async {
        guard !finished, eventConnectionID == connectionID, let connection else { return }
        switch event {
        case let .pairingPhrase(pairingID, _, _, _):
            guard await connection.confirmPairing(pairingID: pairingID) else {
                await fail()
                return
            }
        case let .authenticated(device, resumed):
            guard !revocationStarted else {
                await fail()
                return
            }
            authenticatedDeviceID = device.deviceId
            authenticatedAsResume = resumed
            emit("KAISOLA_NATIVE_LINK_STAGE=AUTHENTICATED_\(resumed ? "RESUME" : "PAIR")")
        case let .live(_, capabilities, _):
            guard capabilities == [.observe] else {
                await fail()
                return
            }
            let sequence: Int64
            if authenticatedAsResume {
                guard initialProjectionAcknowledged, !resumeProjectionSent else {
                    await fail()
                    return
                }
                resumeProjectionSent = true
                sequence = 2
            } else {
                guard !initialProjectionSent else {
                    await fail()
                    return
                }
                initialProjectionSent = true
                sequence = 1
            }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let projection = CompanionProjectionBuilder.build(
                drafts: [RememberedSessionDraft(
                    id: "terminal-native-browser-smoke",
                    projectID: "project-native-browser-smoke",
                    projectName: "Kaisola",
                    title: "Native browser relay proof",
                    kind: .terminal,
                    agentID: "Codex",
                    activity: .working,
                    resumeKind: .livePTY,
                    createdAt: now,
                    lastActivityAt: now,
                    hasLocalTranscript: true
                )],
                revision: Int(sequence),
                nowMilliseconds: now
            )
            do {
                _ = try await connection.send(
                    kind: .snapshot,
                    id: "snapshot-native-browser-smoke-\(sequence)",
                    sequence: sequence,
                    sentAt: now,
                    body: CompanionBody(CompanionSnapshotBody(
                        type: "snapshot.projects",
                        revision: Int(sequence),
                        projection: projection
                    ))
                )
            } catch {
                await fail()
            }
        case let .envelope(envelope, _):
            guard envelope.kind == .ack,
                  let acknowledgement = try? envelope.body.decode(CompanionAckBody.self) else {
                return
            }
            if acknowledgement.ackSeq == 1, initialProjectionSent,
               !initialProjectionAcknowledged {
                initialProjectionAcknowledged = true
                emit("KAISOLA_NATIVE_LINK_RESUME_READY=1")
            } else if acknowledgement.ackSeq == 2, resumeProjectionSent {
                await revokeLiveBrowser()
            }
        case let .closed(reason):
            emit("KAISOLA_NATIVE_LINK_STAGE=CLOSED_\(reason.uppercased())")
            self.connection = nil
            connectionID = nil
            if revocationStarted, revokedResumeAttemptAccepted {
                if revocationDenied { complete(passStatus) }
            } else if !initialProjectionAcknowledged || resumeProjectionSent {
                await fail()
            }
        }
    }

    private var passStatus: String {
        "KAISOLA_NATIVE_LINK_SMOKE=PASS_E2E protocol=1 transport=wss noise=xx sas=confirmed capability=observe projection=acked resume=acked revoke=denied"
    }

    private func revokeLiveBrowser() async {
        guard !revocationStarted, let deviceID = authenticatedDeviceID else {
            await fail()
            return
        }
        do {
            guard try await roster.revoke(deviceID) else {
                await fail()
                return
            }
        } catch {
            await fail()
            return
        }
        revocationStarted = true
        let active = connection
        connection = nil
        connectionID = nil
        if let active { await active.close(reason: "device_revoked") }
        emit("KAISOLA_NATIVE_LINK_REVOKED=1")
    }

    private func fail() async {
        guard !finished else { return }
        let active = connection
        complete("KAISOLA_NATIVE_LINK_SMOKE=E2E_PROTOCOL_ERROR")
        if let active { await active.close(reason: "smoke_failed") }
    }

    private func reportDiagnostic(_ value: String) {
        let safe = value.uppercased().filter { $0.isASCII && ($0.isLetter || $0 == "_") }
        emit("KAISOLA_NATIVE_LINK_STAGE=ERROR_\(safe.isEmpty ? "PROTOCOL" : String(safe.prefix(80)))")
        if revocationStarted,
           revokedResumeAttemptAccepted,
           safe == "PAIRING_AUTHENTICATION_FAILED" {
            revocationDenied = true
            if connection == nil { complete(passStatus) }
        }
    }

    private func complete(_ status: String) {
        guard !finished else { return }
        finished = true
        try? FileManager.default.removeItem(at: cleanupURL)
        finish(status)
    }
}

/// The main workspace is a full-size-content window. Giving SwiftUI the
/// hosting view's real full-height bounds lets every workspace surface meet the
/// top edge without translating AppKit representables (notably SwiftTerm)
/// outside their compositor. Sidebar content adds its own traffic-light
/// clearance; detail panes intentionally use the entire height.
@MainActor
final class FullHeightWorkspaceHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

struct NativeFrameCadenceReport: Encodable, Equatable, Sendable {
    struct Thresholds: Encodable, Equatable, Sendable {
        let maximumDeadlineLossRateMsPerSecond: Double
        let maximumP95IntervalFrames: Double
        let maximumIntervalMs: Double
        let minimumCallbackCoverage: Double
    }

    struct Checks: Encodable, Equatable, Sendable {
        let deadlineLossRate: Bool
        let p95Interval: Bool
        let maximumInterval: Bool
        let callbackCoverage: Bool

        var pass: Bool {
            deadlineLossRate && p95Interval && maximumInterval && callbackCoverage
        }
    }

    static let thresholds = Thresholds(
        maximumDeadlineLossRateMsPerSecond: 10,
        maximumP95IntervalFrames: 1.5,
        maximumIntervalMs: 100,
        minimumCallbackCoverage: 0.95
    )

    let schemaVersion: Int
    let workload: String
    let callbackCount: Int
    let measurementDurationSeconds: Double
    let nominalFrameDurationMs: Double
    let p95IntervalMs: Double
    let maximumIntervalMs: Double
    let missedFrameCount: Int
    let deadlineLossMs: Double
    let deadlineLossRateMsPerSecond: Double
    let callbackCoverage: Double
    let thresholds: Thresholds
    let checks: Checks
    let pass: Bool

    static func summarize(
        workload: String,
        callbackTimestamps: [Double],
        nominalFrameDurations: [Double]
    ) -> NativeFrameCadenceReport? {
        guard callbackTimestamps.count >= 2,
              callbackTimestamps.allSatisfy({ $0.isFinite }),
              zip(callbackTimestamps, callbackTimestamps.dropFirst()).allSatisfy({ $0 < $1 }) else {
            return nil
        }
        let usableDurations = nominalFrameDurations.filter { $0.isFinite && $0 > 0 }
        guard !usableDurations.isEmpty else { return nil }
        let nominal = percentile(usableDurations, fraction: 0.5)
        let intervals = zip(callbackTimestamps, callbackTimestamps.dropFirst()).map {
            earlier, later in later - earlier
        }
        guard let maximumInterval = intervals.max(), maximumInterval > 0 else { return nil }
        let duration = callbackTimestamps.last! - callbackTimestamps.first!
        guard duration > 0 else { return nil }
        let missedFrames = intervals.reduce(into: 0) { total, interval in
            let representedFrames = max(1, Int((interval / nominal + 0.5).rounded(.down)))
            total += representedFrames - 1
        }
        let lossSeconds = Double(missedFrames) * nominal
        let lossRate = lossSeconds * 1_000 / duration
        let coverage = min(1, Double(intervals.count) * nominal / duration)
        let p95 = percentile(intervals, fraction: 0.95)
        let thresholds = Self.thresholds
        let checks = Checks(
            deadlineLossRate: lossRate <= thresholds.maximumDeadlineLossRateMsPerSecond,
            p95Interval: p95 <= nominal * thresholds.maximumP95IntervalFrames,
            maximumInterval: maximumInterval * 1_000 <= thresholds.maximumIntervalMs,
            callbackCoverage: coverage >= thresholds.minimumCallbackCoverage
        )
        return NativeFrameCadenceReport(
            schemaVersion: 1,
            workload: workload,
            callbackCount: callbackTimestamps.count,
            measurementDurationSeconds: duration,
            nominalFrameDurationMs: nominal * 1_000,
            p95IntervalMs: p95 * 1_000,
            maximumIntervalMs: maximumInterval * 1_000,
            missedFrameCount: missedFrames,
            deadlineLossMs: lossSeconds * 1_000,
            deadlineLossRateMsPerSecond: lossRate,
            callbackCoverage: coverage,
            thresholds: thresholds,
            checks: checks,
            pass: checks.pass
        )
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.sorted()
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
        )
        return sorted[index]
    }
}

/// A fixture-only, view-bound main-run-loop cadence probe. Instruments remains
/// the rendered-hitch authority; this complementary signal catches deadline
/// loss without enabling a machine-wide trace when unrelated daemons are busy.
@MainActor
final class NativeFrameCadenceProbe: NSObject {
    static let warmupSeconds: Double = 60
    static let measurementSeconds: Double = 30
    static let timeoutSeconds: Double = 95

    private let workload: String
    private let completion: (NativeFrameCadenceReport?) -> Void
    private let measurementStartsAt: Double
    private var callbackTimestamps: [Double] = []
    private var nominalFrameDurations: [Double] = []
    private var displayLink: CADisplayLink?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    init(
        view: NSView,
        workload: String,
        completion: @escaping (NativeFrameCadenceReport?) -> Void
    ) {
        self.workload = workload
        self.completion = completion
        measurementStartsAt = CACurrentMediaTime() + Self.warmupSeconds
        super.init()
        let displayLink = view.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            self?.finish(report: nil)
        }
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard !completed else { return }
        let now = CACurrentMediaTime()
        guard now >= measurementStartsAt else { return }
        callbackTimestamps.append(now)
        let reportedDuration = displayLink.targetTimestamp - displayLink.timestamp
        nominalFrameDurations.append(reportedDuration > 0 ? reportedDuration : displayLink.duration)
        guard now - measurementStartsAt >= Self.measurementSeconds else { return }
        finish(report: NativeFrameCadenceReport.summarize(
            workload: workload,
            callbackTimestamps: callbackTimestamps,
            nominalFrameDurations: nominalFrameDurations
        ))
    }

    private func finish(report: NativeFrameCadenceReport?) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        displayLink?.invalidate()
        displayLink = nil
        completion(report)
    }
}

@main
@MainActor
enum KaisolaMacMain {
    private static let appDelegate = KaisolaMacAppDelegate()

    static func main() {
        let environment = ProcessInfo.processInfo.environment
        if environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
            || environment["KAISOLA_NATIVE_RESOURCE_WORKLOAD"] != nil {
            // Keep the quit policy process-local so fixture termination cannot
            // opt into saving windows in the production defaults domain. The
            // delegate callbacks below reject save/restore explicitly. Avoid
            // ApplePersistenceIgnoreState here: AppKit writes a notice to
            // stderr for that key, while fixture stdout/stderr is intentionally
            // a fail-closed protocol surface.
            var arguments = UserDefaults.standard.volatileDomain(
                forName: UserDefaults.argumentDomain
            )
            arguments["NSQuitAlwaysKeepsWindows"] = false
            UserDefaults.standard.setVolatileDomain(
                arguments,
                forName: UserDefaults.argumentDomain
            )
        }
        // This mode intentionally returns before touching user state or the
        // broker. dyld must still load every linked framework first, making it
        // a cheap packaging check for hardened-runtime/library-validation
        // failures in CI and release preflight.
        if ProcessInfo.processInfo.arguments.dropFirst().contains("--launch-probe") {
            print("KAISOLA_NATIVE_LAUNCH_PROBE=PASS")
            return
        }
        KaisolaProductMigration.run()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = appDelegate
        application.run()
    }
}

@MainActor
final class KaisolaMacAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    /// Hosted visual fixtures must never write appearance/layout choices into
    /// the signed app's production defaults domain. A per-process suite keeps
    /// captures deterministic and makes off-desktop inspection side-effect free.
    private static let isolatedSettingsSuite: String? = {
        NativePreviewSettings.isolatedFixtureSuiteName(
            environment: ProcessInfo.processInfo.environment,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }()

    private static func makeSettings() -> NativePreviewSettings {
        guard let suite = isolatedSettingsSuite else {
            return .shared
        }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = NativePreviewSettings(defaults: defaults, persistsChanges: false)
        if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_RESOURCE_WORKLOAD"] != nil {
            // Electron 0.1.126 hard-codes xterm to 5,000 rows. Pin the same live
            // renderer budget here; the separate 20k/100k native gate measures
            // the shipping default and maximum-depth policies.
            settings.terminalScrollbackLines = 5_000
            settings.appearance = .light
            settings.sidebarAppearance = .solid
            settings.workspaceBackdrop = .system
            settings.semanticShellIntegration = false
        }
        if let raw = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_RESOURCE_SCROLLBACK_LINES"],
           let lines = Int(raw),
           NativePreviewSettings.terminalScrollbackRange.contains(lines) {
            settings.terminalScrollbackLines = lines
        }
        if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "settings-models" {
            settings.anthropicBaseURL = "https://gateway.example.test/v1"
            settings.anthropicModel = "claude-sonnet"
        }
        return settings
    }

    private let settings = KaisolaMacAppDelegate.makeSettings()
    private lazy var auth: AuthModel = {
        if visualFixture || resourceWorkload != nil {
            return visualSurface == "settings-account-recovery"
                ? AuthModel.previewSignedOut(notice: NativeAccountKeychainMigration.notice)
                : AuthModel.previewSignedIn()
        }
        let notice = UserDefaults.standard.bool(
            forKey: NativeAccountKeychainMigration.completionDefaultsKey
        ) ? nil : NativeAccountKeychainMigration.notice
        return AuthModel(
            backend: FirebaseAuthBackend(secureStore: KeychainAuthSecureStore()),
            signedOutNotice: notice
        )
    }()
    private let updateController = NativeUpdateController()
    // Each window is an independent workspace with its own AppModel and broker
    // observer connection — the broker's coexistence contract makes concurrent
    // observers safe. Keyed by the NSWindow so menu actions target the key one.
    private var windowModels: [ObjectIdentifier: AppModel] = [:]
    /// The last actual project window remains the Settings target while the
    /// standalone Settings window itself is key.
    private weak var lastWorkspaceWindow: NSWindow?
    private var companionProjectionObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var companionAttentionObserver: AnyCancellable?
    private var teardownTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var terminationDrainTask: Task<Void, Never>?
    private var terminationDeadlineTask: Task<Void, Never>?
    private var terminationPreparationInProgress = false
    private var terminationPrepared = false
    static let terminationDrainDeadlineNanoseconds: UInt64 = 12_000_000_000
    private var windowCounter = 0
    private var wakeObserver: NSObjectProtocol?
    private var agentsObserver: NSObjectProtocol?
    private var keymapObserver: NSObjectProtocol?
    private var commandPresentationObserver: NSObjectProtocol?
    private var runInTerminalObserver: NSObjectProtocol?
    private var checkForUpdatesObserver: NSObjectProtocol?
    private var attentionJumpObserver: NSObjectProtocol?
    private var authPhaseObserver: AnyCancellable?
    private var settingsWorkspaceObserver: AnyCancellable?
    private var settingsWorkspaceModelID: ObjectIdentifier?
    private var settingsSelectedSectionID: String?
    private var rememberedSessionRefreshObserver: NSObjectProtocol?
    private var rememberedSessionSyncTask: Task<Void, Never>?
    private var rememberedSessionAccountID: String?
    private var rememberedSessionAccountGeneration: UInt64 = 0
    private var rememberedSessionRefreshGeneration: UInt64?
    private lazy var companionTerminalControlAdapter = CompanionTerminalControlAdapter(
        availability: { [weak self] terminal in
            self?.companionController(for: terminal)?
                .companionTerminalAvailability(for: terminal)
        },
        write: { [weak self] terminal, data in
            guard let model = self?.companionController(for: terminal) else {
                throw CompanionTerminalControlAdapterError.unavailable
            }
            try await model.companionWrite(data, to: terminal)
        },
        resize: { [weak self] terminal, geometry in
            guard let model = self?.companionController(for: terminal) else {
                throw CompanionTerminalControlAdapterError.unavailable
            }
            try await model.companionResize(geometry, terminal: terminal)
        },
        interrupt: { [weak self] terminal in
            guard let model = self?.companionController(for: terminal) else {
                throw CompanionTerminalControlAdapterError.unavailable
            }
            try await model.companionInterrupt(terminal)
        },
        controlStateChanged: { [weak self] terminal, active in
            guard let self else { return }
            if active {
                self.companionController(for: terminal)?
                    .setCompanionControlActive(true, for: terminal)
            } else {
                for model in self.windowModels.values {
                    model.setCompanionControlActive(false, for: terminal)
                }
            }
        }
    )
    private lazy var rememberedSessions: RememberedSessionCatalogCenter = {
        let isolated = visualFixture || resourceWorkload != nil
        let ownerID = isolated
            ? "fixture-\(ProcessInfo.processInfo.processIdentifier)"
            : NativeSessionStore().ownerID()
        let localID = RememberedSessionCatalogDevice.id(from: ownerID)
        return isolated
            ? RememberedSessionCatalogCenter.preview(localDeviceID: localID)
            : RememberedSessionCatalogCenter(localDeviceID: localID)
    }()
    private lazy var firebaseAuthConfiguration = try? FirebaseAuthConfiguration.load()
    private lazy var rememberedSessionCatalog: RememberedSessionCatalogClient? = {
        guard let configuration = firebaseAuthConfiguration else { return nil }
        return try? RememberedSessionCatalogClient(sessionURL: configuration.serverURL)
    }()
    private lazy var rememberedSessionCatalogCache = RememberedSessionCatalogSnapshotStore(
        directory: NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("remembered-session-catalog-v1", isDirectory: true)
    )
    private let runtimeSmoke = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_RUNTIME_SMOKE"] == "1"
    /// Broker-free production relay proof. It restores the normal native
    /// account, obtains a fresh ID token through AuthModel, opens one isolated
    /// smoke desktop on Kaisola Link, waits for `relay.desktop-ready`, and
    /// exits without creating windows, listeners, broker clients, or PTYs.
    private let linkSmoke = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_LINK_SMOKE"] == "1"
    private var linkSmokeFinished = false
    /// Signed, headless proof of the deployed remembered-session lifecycle.
    /// It restores the production Firebase account, publishes one synthetic
    /// device, reads it back exactly, removes it, proves removal, and exits
    /// without starting Companion, the broker, a window, or any PTY.
    private let catalogSmoke = ProcessInfo.processInfo.environment[
        "KAISOLA_NATIVE_CATALOG_SMOKE"
    ] == "1"
    private var catalogSmokeFinished = false
    /// Hosted visual QA runs the real SwiftUI/AppKit window with deterministic
    /// state, captures it from inside the process, and exits. It never connects
    /// to a broker or takes over the user's local desktop.
    private let visualFixture = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
    private let visualSurface = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] ?? "terminal"
    private let visualAppearance = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_APPEARANCE"] ?? "light"
    private let visualWorkspace = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_WORKSPACE"]
    private let visualDocument = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_DOCUMENT"]
    private let visualCapturePath = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_CAPTURE_PATH"]
    private let resourceWorkloadRequested = ProcessInfo.processInfo.environment[
        "KAISOLA_NATIVE_RESOURCE_WORKLOAD"
    ] != nil
    private let resourceWorkload = NativeResourceWorkloadConfiguration.resolve()
    private let resourceFrameCadenceRequested = ProcessInfo.processInfo.environment[
        "KAISOLA_NATIVE_FRAME_CADENCE"
    ] == "1"
    private var resourceFrameCadenceProbe: NativeFrameCadenceProbe?
    private var visualStreamingFixtureTask: Task<Void, Never>?
    private struct ResourceTerminalReceipt {
        let terminalID: String
        let observedOffset: Int64
        let windowWidth: Int
        let windowHeight: Int
    }
    private var resourceTerminalReceipts: [ResourceTerminalReceipt] = []
    private var resourceReceiptEmitted = false
    private let visualFixtureStorageRoot: URL? = {
        guard ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1" else {
            return nil
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-native-visual-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }()
    private let resourceFixtureStorageRoot: URL? = {
        guard let configuration = NativeResourceWorkloadConfiguration.resolve() else { return nil }
        try? FileManager.default.createDirectory(
            at: configuration.appStateRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(configuration.appStateRoot.path, 0o700)
        return configuration.appStateRoot
    }()

    /// Disposable visual/resource launches use the production bundle ID so the
    /// measured binary is real, but their state lives under an isolated root.
    /// Never let AppKit's process-global persistent-UI crash history cross that
    /// boundary: after repeated fixture termination it otherwise presents a
    /// modal "restore windows" prompt before `applicationDidFinishLaunching`,
    /// leaving a headless gate waiting forever.
    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        !visualFixture && resourceWorkload == nil
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        !visualFixture && resourceWorkload == nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // XCTest injects the bundle into the real app executable. Launching a
        // normal workspace here would connect to the user's broker, restore
        // their projects, scan FileProvider folders, and spawn background git
        // probes alongside otherwise hermetic unit tests. That can both disturb
        // a live workspace and starve process-based ACP/Mesh tests. Tests create
        // every AppModel/window they need explicitly.
        guard !NotificationBridge.isRunningUnderXCTest else { return }
        if resourceWorkloadRequested, resourceWorkload == nil {
            print("KAISOLA_NATIVE_RESOURCE_WORKLOAD_READY=FAIL invalid-private-temporary-root")
            NSApp.terminate(nil)
            return
        }
        if catalogSmoke {
            Darwin.signal(SIGALRM, catalogSmokeTimeoutSignalHandler)
            Darwin.alarm(90)
            Task { @MainActor [weak self] in
                await self?.runKaisolaCatalogSmoke()
            }
            return
        }
        if linkSmoke {
            Darwin.signal(SIGALRM, linkSmokeTimeoutSignalHandler)
            Darwin.alarm(35)
            Task { @MainActor [weak self] in
                await self?.runKaisolaLinkSmoke()
            }
            return
        }
        // Kaisola-owned state stays separate from every historical Electron
        // profile. Broker discovery is explicitly read-only and lives elsewhere.
        if !visualFixture && resourceWorkload == nil {
            try? NativePreviewPaths.prepareApplicationSupport()
        }
        if visualFixture {
            settings.navigationLayout = ["topbar", "topbar-attention"].contains(visualSurface)
                ? .topBar
                : .leftTree
            settings.appearance = visualAppearance == "dark" ? .dark : .light
            settings.sidebarAppearance = .glass
            settings.workspaceBackdrop = .glass
            settings.workspaceRailVisible = visualSurface != "topbar" && visualSurface != "terminal-solo"
            settings.workspaceRailWidth = 196
            // Pin both ordinary and failure-boundary document widths. The
            // fixture settings object is non-persistent, so these values can
            // never leak into the user's next production window.
            settings.filePreviewWidth = visualSurface == "preview-narrow" ? 300 : 480
        }
        settings.applyAppearance()
        if !visualFixture && resourceWorkload == nil {
            NotificationBridge.shared.requestAuthorizationIfNeeded()
            CompanionHost.shared.configureTerminalControl(
                adapter: companionTerminalControlAdapter
            )
            if let relayURL = firebaseAuthConfiguration?.relayURL {
                CompanionHost.shared.configureKaisolaLink(
                    baseURL: relayURL,
                    tokenProvider: { [weak self] in
                        guard let self else { throw CompanionRelayError.authenticationRequired }
                        return try await self.auth.freshIDToken()
                    }
                )
            }
            CompanionHost.shared.startIfEnabled()
            companionAttentionObserver = AttentionCenter.shared.$entries
                .dropFirst()
                .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor in self?.publishCompanionProjection() }
                }
            authPhaseObserver = auth.$phase.sink { [weak self] phase in
                Task { @MainActor in self?.handleRememberedSessionAuthPhase(phase) }
            }
            rememberedSessionRefreshObserver = NotificationCenter.default.addObserver(
                forName: .kaisolaRefreshRememberedSessions,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.publishRememberedSessions() }
            }
            Task { await auth.restore() }
        }
        installMainMenu()
        keymapObserver = NotificationCenter.default.addObserver(
            forName: .kaisolaKeymapChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installMainMenu() }
        }
        commandPresentationObserver = NotificationCenter.default.addObserver(
            forName: .kaisolaCommandPresentationChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuStates() }
        }
        // Custom agents added/removed in Settings reload both the typed
        // registry and its validated keymap before rebuilding AppKit menus.
        agentsObserver = NotificationCenter.default.addObserver(
            forName: .kaisolaAgentsChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                AppCommandKeymapCenter.shared.reload()
            }
        }
        // The Settings sign-in card asks for a terminal via notification (it
        // has no AppModel). Handled here — not per-window — so exactly one
        // shell window spawns the terminal.
        runInTerminalObserver = NotificationCenter.default.addObserver(
            forName: .kaisolaRunInTerminal, object: nil, queue: .main
        ) { [weak self] note in
            let command = note.userInfo?[SignInCardView.commandUserInfoKey] as? String
            Task { @MainActor in
                guard let command, let model = self?.keyModel() else { return }
                await model.runCommandInNewTerminal(command)
            }
        }
        checkForUpdatesObserver = NotificationCenter.default.addObserver(
            forName: .kaisolaCheckForUpdates, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateController.checkForUpdates(nil) }
        }
        // A system-notification click is process-global. Route it once through
        // the window registry; per-RootShell observers made every window act on
        // the same target and could clear an unrelated window's selection.
        attentionJumpObserver = NotificationCenter.default.addObserver(
            forName: .kaisolaAttentionJump, object: nil, queue: .main
        ) { [weak self] note in
            let targetID = note.userInfo?[NotificationBridge.targetIDKey] as? String
            Task { @MainActor in
                guard let self, let targetID else { return }
                self.revealAttentionTarget(targetID)
            }
        }
        if let resourceWorkload,
           resourceWorkload.workloadID == NativeResourceWorkloadConfiguration.restoredWindowsID {
            startRestoredWindowsResourceWorkload(resourceWorkload)
        } else {
            _ = makeWindow()
        }
        NSApp.activate(ignoringOtherApps: true)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                for model in self?.windowModels.values ?? [:].values {
                    await model.recoverAfterWake()
                }
            }
        }
    }

    /// Create a fresh, independent workspace window.
    @discardableResult
    private func makeWindow(
        initialProjectDirectory: URL? = nil,
        legacyInitialProjectName: String? = nil,
        preparesResourceWorkload: Bool = true
    ) -> NSWindow? {
        guard !terminationPreparationInProgress, !terminationPrepared else { return nil }
        let model = makeAppModel()
        if visualFixture {
            let workspace: URL
            if ["preview-code-editor", "preview-dirty-tab", "preview-tab-overflow"].contains(visualSurface),
               let visualFixtureStorageRoot {
                workspace = visualFixtureStorageRoot.appendingPathComponent("project", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: workspace,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } else {
                workspace = URL(
                    fileURLWithPath: visualWorkspace ?? FileManager.default.currentDirectoryPath,
                    isDirectory: true
                )
            }
            model.loadVisualFixture(
                workspace: workspace,
                includeSplit: visualSurface == "terminal"
                    || visualSurface == "companion-control"
            )
            if visualSurface == "companion-control",
               let terminal = model.sessions.first {
                model.setCompanionControlActive(true, for: terminal)
            } else if ["attention-completed", "topbar-attention"].contains(visualSurface) {
                model.loadVisualCompletedAttentionFixture()
            } else if visualSurface == "mixed" || visualSurface == "permission" {
                model.loadVisualMixedSessionFixture(
                    workspace: workspace,
                    includePermission: visualSurface == "permission"
                )
            } else if visualSurface == "preview-dirty-tab" {
                let document = workspace.appendingPathComponent("README.md", isDirectory: false)
                let docsDirectory = workspace.appendingPathComponent("docs", isDirectory: true)
                let duplicateDocument = docsDirectory.appendingPathComponent("README.md", isDirectory: false)
                let fixture = """
                # Preview tab

                A single-click preview stays replaceable until editing begins.

                The first edit keeps the document open and marks the tab as modified.
                """
                let duplicateFixture = """
                # Documentation README

                Duplicate filenames use their workspace-relative parent in the tab strip.
                """
                try? FileManager.default.createDirectory(
                    at: docsDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if (try? fixture.write(to: document, atomically: true, encoding: .utf8)) != nil,
                   (try? duplicateFixture.write(
                    to: duplicateDocument,
                    atomically: true,
                    encoding: .utf8
                   )) != nil {
                    model.openFilePreview(duplicateDocument, pinned: true)
                    model.openFilePreview(document)
                }
            } else if visualSurface == "preview-tab-overflow" {
                let fixtureNames = [
                    "01-Architecture.md",
                    "02-Data-Model.md",
                    "03-Terminal-Runtime.md",
                    "04-Session-History.md",
                    "05-Companion-Sync.md",
                    "06-Markdown-Editor.md",
                    "07-Release-Checklist.md",
                    "08-Accessibility-Audit.md",
                    "09-Performance-Notes.md",
                    "10-Selected-Document.md",
                ]
                var firstDocument: URL?
                for name in fixtureNames {
                    let document = workspace.appendingPathComponent(name, isDirectory: false)
                    let fixture = """
                    # \(name.replacingOccurrences(of: ".md", with: ""))

                    The selected tab remains visible when the document deck overflows.
                    """
                    guard (try? fixture.write(to: document, atomically: true, encoding: .utf8)) != nil else {
                        continue
                    }
                    if firstDocument == nil { firstDocument = document }
                    model.openFilePreview(document, pinned: true)
                }
                if let firstDocument {
                    model.openFilePreview(firstDocument, pinned: true)
                }
            } else if visualSurface == "preview-code-editor" {
                let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
                let document = sources.appendingPathComponent("ReleaseGate.swift", isDirectory: false)
                let fixture = """
                import Foundation

                struct ReleaseGate {
                    let surface: String

                    func summary(isReady: Bool) -> String {
                        let state = isReady ? "Ready" : "Needs review"
                        return "\\(surface): \\(state)"
                    }
                }

                let gate = ReleaseGate(surface: "Confined CodeMirror")
                print(gate.summary(isReady: true))
                """.replacingOccurrences(of: "\n", with: "\r\n")
                try? FileManager.default.createDirectory(
                    at: sources,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if (try? fixture.write(to: document, atomically: true, encoding: .utf8)) != nil {
                    // A file citation is the production route into editable
                    // source and gives the fixture a deterministic active line.
                    model.openFilePreview(document, line: 6)
                }
            } else if visualSurface == "preview"
                        || visualSurface == "preview-edit"
                        || visualSurface == "preview-narrow" {
                let document = visualDocument.map {
                    URL(fileURLWithPath: $0, relativeTo: workspace).standardizedFileURL
                } ?? workspace.appendingPathComponent("README.md", isDirectory: false)
                let workspacePath = workspace.standardizedFileURL.path
                let documentPath = document.path
                let isInsideWorkspace = documentPath == workspacePath
                    || documentPath.hasPrefix(workspacePath + "/")
                if isInsideWorkspace, FileManager.default.fileExists(atPath: documentPath) {
                    model.openFilePreview(document)
                }
            } else if visualSurface == "preview-table-edit" {
                let document = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Kaisola visual table.md", isDirectory: false)
                let fixture = """
                # Release readiness

                Edit one cell without leaving the rendered document.

                | Surface | State | Evidence |
                | :------ | :---- | :------- |
                | Terminal | Stable | Scroll anchoring verified |
                | Markdown | Editable | Exact source ranges |
                | Companion | Ready | Encrypted observer path |

                Every pipe, alignment rule, and neighboring paragraph stays byte-for-byte intact.
                """
                if (try? fixture.write(to: document, atomically: true, encoding: .utf8)) != nil {
                    model.openFilePreview(document)
                }
            } else if visualSurface == "preview-html" {
                let page = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Kaisola visual preview.html", isDirectory: false)
                let fixture = """
                <!doctype html>
                <html lang="en">
                <head>
                  <meta charset="utf-8">
                  <style>
                    * { box-sizing: border-box; }
                    body { margin: 0; background: #f7f8fb; color: #17191d;
                      font: 15px -apple-system, BlinkMacSystemFont, sans-serif; }
                    main { max-width: 620px; margin: 0 auto; padding: 48px 42px; }
                    .eyebrow { color: #5d5ce2; font-size: 12px; font-weight: 700;
                      letter-spacing: .08em; text-transform: uppercase; }
                    h1 { margin: 10px 0 12px; font-size: 34px; line-height: 1.08; }
                    p { color: #595e69; line-height: 1.55; }
                    .cards { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-top: 24px; }
                    .card { background: rgba(255,255,255,.88); border: 1px solid #e5e7ee;
                      border-radius: 14px; padding: 16px; box-shadow: 0 8px 24px rgba(31,35,48,.06); }
                    .card strong { display: block; margin-bottom: 5px; }
                    .card span { color: #737986; font-size: 13px; }
                  </style>
                </head>
                <body>
                  <main>
                    <div class="eyebrow">Kaisola project</div>
                    <h1>Native HTML preview</h1>
                    <p>Inspect project pages beside live terminals, then edit the source without leaving the project.</p>
                    <section class="cards">
                      <div class="card"><strong>Confined</strong><span>Assets stay inside this project.</span></div>
                      <div class="card"><strong>Fast</strong><span>Rendered in an ephemeral view.</span></div>
                    </section>
                  </main>
                </body>
                </html>
                """
                if (try? fixture.write(to: page, atomically: true, encoding: .utf8)) != nil {
                    model.openFilePreview(page)
                }
            } else if visualSurface == "preview-docx" {
                let document = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Kaisola visual document.docx", isDirectory: false)
                let contents = NSMutableAttributedString(
                    string: "Native documents\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold)]
                )
                contents.append(NSAttributedString(
                    string: "Edit rich text without leaving the project. Zoom, search, undo, and save stay native and immediate.\n\nA calm, focused page for notes and working documents.",
                    attributes: [.font: NSFont.systemFont(ofSize: 15)]
                ))
                if (try? RichDocumentIO.write(contents, to: document)) != nil {
                    model.openFilePreview(document)
                }
            } else if visualSurface == "preview-pdf" {
                let document = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Kaisola visual document.pdf", isDirectory: false)
                let page = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
                page.drawsBackground = true
                page.backgroundColor = .white
                page.textColor = .black
                page.textContainerInset = NSSize(width: 44, height: 48)
                page.textStorage?.setAttributedString(NSMutableAttributedString(
                    string: "Native PDF review\n\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 30, weight: .bold),
                        .foregroundColor: NSColor.black,
                    ]
                ))
                page.textStorage?.append(NSAttributedString(
                    string: "Read selectable project documents beside live terminals. PDFKit keeps page scrolling, trackpad magnification, and accessibility native.\n\nRelease evidence\n• Parsing runs away from the main actor\n• Oversized files fail closed\n• Finder and external-app recovery stay available",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 16),
                        .foregroundColor: NSColor.darkGray,
                    ]
                ))
                let data = page.dataWithPDF(inside: page.bounds)
                if !data.isEmpty, (try? data.write(to: document, options: .atomic)) != nil {
                    model.openFilePreview(document)
                }
            } else if visualSurface == "mesh" {
                model.loadVisualMeshFixture(workspace: workspace)
            }
        }
        if let initialProjectDirectory, !visualFixture {
            // Paint the requested workspace in the first frame. Reload still
            // owns broker/session restoration below and reasserts this choice
            // after its asynchronous state merge, preventing a stale project
            // from another window from becoming the visible destination.
            model.openProject(directory: initialProjectDirectory)
        } else if let legacyInitialProjectName, !visualFixture {
            // Pre-path saved-window records can still paint their remembered
            // label immediately; the post-reload branch below resolves it to a
            // real project id or leaves the ordinary restored selection alone.
            model.selectedProjectName = legacyInitialProjectName
        }
        let content: AnyView
        if visualFixture, visualSurface == "onboarding" {
            UsageCenter.shared.loadVisualFixture()
            content = AnyView(OnboardingView(
                model: model,
                settings: settings,
                dismiss: {},
                openAccounts: {},
                openUpdateSettings: {}
            ))
        } else if visualFixture, ["settings", "settings-terminal", "settings-terminal-history", "settings-terminal-interaction", "settings-companion", "settings-mcp", "settings-accounts", "settings-models", "settings-shortcuts", "settings-account-recovery", "usage"].contains(visualSurface) {
            let workspace = URL(
                fileURLWithPath: visualWorkspace ?? FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            if visualSurface == "usage" {
                UsageCenter.shared.loadVisualFixture()
            } else if visualSurface == "settings-companion" {
                CompanionHost.shared.loadVisualLinkFixture()
            }
            let initialSectionID: String?
            switch visualSurface {
            case "usage": initialSectionID = "usage"
            case "settings-terminal", "settings-terminal-history", "settings-terminal-interaction": initialSectionID = "terminal"
            case "settings-companion": initialSectionID = "companion"
            case "settings-mcp": initialSectionID = "mcp"
            case "settings-accounts": initialSectionID = "accounts"
            case "settings-models": initialSectionID = "models"
            case "settings-shortcuts": initialSectionID = "shortcuts"
            default: initialSectionID = nil
            }
            let initialContentAnchorID: String?
            switch visualSurface {
            case "settings-terminal-history": initialContentAnchorID = "terminal-history"
            case "settings-terminal-interaction": initialContentAnchorID = "terminal-interaction"
            default: initialContentAnchorID = nil
            }
            content = AnyView(SettingsView(
                settings: settings,
                workspace: workspace,
                initialSectionID: initialSectionID,
                initialContentAnchorID: initialContentAnchorID
            ).environmentObject(auth))
        } else {
            content = AnyView(
                RootShellView()
                    .environmentObject(model)
                    .environmentObject(settings)
                    .environmentObject(auth)
                    .environmentObject(rememberedSessions)
            )
        }

        let visualSettings = visualFixture
            && ["settings", "settings-terminal", "settings-terminal-history", "settings-terminal-interaction", "settings-companion", "settings-mcp", "settings-accounts", "settings-models", "settings-shortcuts", "settings-account-recovery", "usage"].contains(visualSurface)
        let visualOnboarding = visualFixture && visualSurface == "onboarding"

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: visualSettings ? 810 : (visualOnboarding ? 760 : (resourceWorkload != nil ? 1_280 : (visualFixture ? 1_360 : 1_080))),
                height: visualSettings ? 540 : (visualOnboarding ? 560 : (resourceWorkload != nil ? 800 : (visualFixture ? 860 : 700)))
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Kaisola"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        // Cascade extra windows so they do not stack exactly.
        if windowCounter == 0 {
            window.center()
            // Visual fixtures are isolated processes with a declared capture
            // size. Registering the production autosave key here lets AppKit
            // replace that size with whichever window (often compact Settings)
            // the runner saved last, making workspace QA nondeterministic.
            if !visualFixture && resourceWorkload == nil {
                window.setFrameAutosaveName("KaisolaNativePreview.MainWindow")
            }
        } else {
            window.cascadeTopLeft(from: NSPoint(x: 40 * CGFloat(windowCounter), y: 40 * CGFloat(windowCounter)))
        }
        if resourceWorkload != nil {
            // Electron BrowserWindow width/height describe the outer frame.
            // Force the same interpretation instead of merely declaring a
            // 1280x800 content rectangle and emitting a misleading receipt.
            let origin = window.frame.origin
            window.setFrame(
                NSRect(x: origin.x, y: origin.y, width: 1_280, height: 800),
                display: false
            )
        }
        windowCounter += 1
        if visualSettings || visualOnboarding {
            window.contentView = NSHostingView(rootView: content)
        } else {
            window.contentView = FullHeightWorkspaceHostingView(rootView: content)
        }
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        windowModels[ObjectIdentifier(window)] = model
        if resourceWorkload == nil {
            observeCompanionProjection(model, id: ObjectIdentifier(window))
        }
        if visualFixture, visualSurface == "terminal-scroll-output" {
            scheduleVisualTerminalStreamingFixture(in: window, model: model)
        }
        if visualFixture, visualSurface == "preview-tab-overflow" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                let didWrap = model.selectAdjacentFileTab(direction: -1)
                let selected = model.previewedFileURL?.lastPathComponent ?? "none"
                print(
                    "KAISOLA_NATIVE_VISUAL_TAB_OVERFLOW="
                        + (didWrap && selected == "10-Selected-Document.md" ? "PASS" : "FAIL")
                        + " selected=\(selected)"
                )
            }
        }
        if visualFixture, visualSurface == "account-picker",
           let agent = AgentRegistry.profile(id: "codex") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                RootShellView.promptForNewChat(agent, model: model)
            }
        }
        // The release pipeline's real-bundle smoke loads AppKit, SwiftUI,
        // notifications, settings, and every linked framework, but deliberately
        // skips broker discovery so it cannot leave a CI helper behind.
        if let resourceWorkload, preparesResourceWorkload {
            Task {
                await prepareResourceWorkload(
                    resourceWorkload,
                    model: model,
                    window: window,
                    workspace: initialProjectDirectory ?? resourceWorkload.workspaceRoot
                )
            }
        } else if resourceWorkload == nil && !runtimeSmoke && !visualFixture {
            Task {
                await model.reload()
                if let initialProjectDirectory {
                    model.openProject(directory: initialProjectDirectory)
                } else if let legacyInitialProjectName,
                          let project = model.projects.first(where: {
                              $0.name == legacyInitialProjectName
                          }) {
                    model.activateProject(id: project.id)
                }
            }
        }
        if visualFixture, let visualCapturePath {
            scheduleVisualCapture(of: window, path: visualCapturePath)
        }
        return window
    }

    /// Visual captures run the real AppKit/SwiftUI product but keep every
    /// mutable model store in a private per-process directory. This makes CI
    /// and local off-desktop inspection incapable of adding fixture sessions,
    /// drafts, cursors, or usage to the signed app's production profile.
    private func makeAppModel() -> AppModel {
        let root = resourceFixtureStorageRoot ?? visualFixtureStorageRoot
        guard let root else { return AppModel() }
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("agent-chat-transcripts-v1.json")
        )
        return AppModel(
            brokerPreparer: resourceWorkload.map {
                BrokerStartupCoordinator.resourceFixture(userDataRoot: $0.brokerUserDataRoot)
            } ?? BrokerStartupCoordinator.live(),
            sessionStore: NativeSessionStore(
                fileURL: root.appendingPathComponent("native-sessions.json")
            ),
            cursorStore: TerminalCursorStore(
                fileURL: root.appendingPathComponent("terminal-cursors-v1.json")
            ),
            workspaceStateStore: NativeWorkspaceStateStore(
                fileURL: root.appendingPathComponent("workspace-state-v1.json")
            ),
            transcriptStore: transcriptStore,
            // The fixture-scoped singleton is persistence-free (see
            // `UsageCenter.shared`) and is also what the footer observes. Using
            // it here keeps chat/session/footer visual state coherent without
            // reading or writing the user's live usage archive.
            usageCenter: UsageCenter.shared
        )
    }

    /// Construct the same ordinary shell workload as the archived Electron
    /// probe: one 1280x800 window, one fresh detached broker, one terminal, and
    /// either an idle prompt or the exact continuously repainting command.
    private func prepareResourceWorkload(
        _ configuration: NativeResourceWorkloadConfiguration,
        model: AppModel,
        window: NSWindow,
        workspace: URL
    ) async {
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(workspace.path, 0o700)
            await model.reload()
            model.openProject(directory: workspace)
            guard let terminalID = await model.createTerminal(
                inDirectory: workspace
            ) else {
                throw CocoaError(.fileReadUnknown)
            }
            let marker = "__KAISOLA_RESOURCE_READY__"
            if configuration.workloadID == NativeResourceWorkloadConfiguration.streamingID {
                let command = "printf '\(marker)\\n'; while :; do printf '\\033[H'; for i in 1 2 3 4 5 6 7 8 9 10; do printf '── streaming line %s %s ──────────────────────\\033[K\\n' \"$i\" \"$RANDOM\"; done; sleep 0.08; done\r"
                model.sendInput(command, to: terminalID)
            } else {
                model.sendInput("printf '\(marker)\\n'\r", to: terminalID)
            }

            let deadline = Date().addingTimeInterval(10)
            var firstStreamingOffset: Int64?
            while Date() < deadline {
                let document = model.terminalDocument
                if document.output.contains(marker), let offset = document.cursor?.offset {
                    if configuration.workloadID != NativeResourceWorkloadConfiguration.streamingID {
                        firstStreamingOffset = offset
                        break
                    }
                    if let firstStreamingOffset, offset > firstStreamingOffset + 1_024 { break }
                    if firstStreamingOffset == nil { firstStreamingOffset = offset }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let observedOffset = model.terminalDocument.cursor?.offset,
                  model.terminalDocument.output.contains(marker),
                  configuration.workloadID != NativeResourceWorkloadConfiguration.streamingID
                    || observedOffset > (firstStreamingOffset ?? observedOffset) + 1_024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            recordResourceTerminalReady(
                configuration: configuration,
                terminalID: terminalID,
                observedOffset: observedOffset,
                window: window
            )
        } catch {
            print("KAISOLA_NATIVE_RESOURCE_WORKLOAD_READY=FAIL \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    private func startRestoredWindowsResourceWorkload(
        _ configuration: NativeResourceWorkloadConfiguration
    ) {
        do {
            var windows: [(model: AppModel, window: NSWindow, workspace: URL)] = []
            for (offset, workspace) in configuration.restoredWorkspaceRoots.enumerated() {
                try FileManager.default.createDirectory(
                    at: workspace,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                _ = chmod(workspace.path, 0o700)
                let state = SavedWindowState(
                    name: "Resource window \(offset + 1)",
                    frame: NSStringFromRect(NSRect(
                        x: 80 + CGFloat(offset * 36),
                        y: 80 + CGFloat(offset * 36),
                        width: 1_280,
                        height: 800
                    )),
                    projectName: workspace.lastPathComponent,
                    projectPath: workspace.path
                )
                savedWindows.save(state)
                guard let window = openSavedWindowState(
                    state,
                    preparesResourceWorkload: false
                ), let model = windowModels[ObjectIdentifier(window)] else {
                    throw CocoaError(.fileReadUnknown)
                }
                windows.append((model, window, workspace))
            }
            guard windows.count == configuration.expectedWindowCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            Task {
                // The shipping multi-window path shares one detached broker and
                // durable stores. Prepare sequentially so readiness measures
                // restoration, not a synthetic three-way broker-launch race.
                for item in windows {
                    await prepareResourceWorkload(
                        configuration,
                        model: item.model,
                        window: item.window,
                        workspace: item.workspace
                    )
                }
            }
        } catch {
            print("KAISOLA_NATIVE_RESOURCE_WORKLOAD_READY=FAIL \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    private func recordResourceTerminalReady(
        configuration: NativeResourceWorkloadConfiguration,
        terminalID: String,
        observedOffset: Int64,
        window: NSWindow
    ) {
        guard !resourceReceiptEmitted else { return }
        resourceTerminalReceipts.append(ResourceTerminalReceipt(
            terminalID: terminalID,
            observedOffset: observedOffset,
            windowWidth: Int(window.frame.width.rounded()),
            windowHeight: Int(window.frame.height.rounded())
        ))
        guard resourceTerminalReceipts.count == configuration.expectedWindowCount else { return }
        do {
            let rows = resourceTerminalReceipts.sorted { $0.terminalID < $1.terminalID }
            guard Set(rows.map(\.terminalID)).count == configuration.expectedWindowCount,
                  rows.allSatisfy({ $0.windowWidth == 1_280 && $0.windowHeight == 800 }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let broker = try BrokerInfoLocator(
                userDataCandidates: [configuration.brokerUserDataRoot]
            ).locate()
            var receipt: [String: Any] = [
                "workload": configuration.workloadID,
                "appPid": ProcessInfo.processInfo.processIdentifier,
                "brokerPid": broker.pid,
                "brokerStartedAt": broker.startedAt,
                "terminalIds": rows.map(\.terminalID),
                "rendererScrollbackLines": settings.terminalScrollbackLines,
                "windowCount": rows.count,
                "windowWidth": rows[0].windowWidth,
                "windowHeight": rows[0].windowHeight,
                "observedOffsets": rows.map(\.observedOffset),
            ]
            if let only = rows.first, rows.count == 1 {
                receipt["terminalId"] = only.terminalID
                receipt["observedOffset"] = only.observedOffset
            }
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            resourceReceiptEmitted = true
            FileHandle.standardOutput.write(Data("KAISOLA_NATIVE_RESOURCE_WORKLOAD_READY=".utf8))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            try? FileHandle.standardOutput.synchronize()
            if resourceFrameCadenceRequested {
                startResourceFrameCadenceProbe(
                    configuration: configuration,
                    window: window
                )
            }
        } catch {
            print("KAISOLA_NATIVE_RESOURCE_WORKLOAD_READY=FAIL \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    private func startResourceFrameCadenceProbe(
        configuration: NativeResourceWorkloadConfiguration,
        window: NSWindow
    ) {
        guard resourceFrameCadenceProbe == nil,
              configuration.workloadID == NativeResourceWorkloadConfiguration.streamingID,
              configuration.expectedWindowCount == 1,
              let contentView = window.contentView else {
            print("KAISOLA_NATIVE_FRAME_CADENCE=FAIL invalid-streaming-surface")
            try? FileHandle.standardOutput.synchronize()
            return
        }
        resourceFrameCadenceProbe = NativeFrameCadenceProbe(
            view: contentView,
            workload: configuration.workloadID
        ) { [weak self] report in
            defer { self?.resourceFrameCadenceProbe = nil }
            guard let report,
                  let data = try? JSONEncoder().encode(report),
                  let payload = String(data: data, encoding: .utf8) else {
                print("KAISOLA_NATIVE_FRAME_CADENCE=FAIL display-link-timeout")
                try? FileHandle.standardOutput.synchronize()
                return
            }
            FileHandle.standardOutput.write(Data("KAISOLA_NATIVE_FRAME_CADENCE=".utf8))
            FileHandle.standardOutput.write(Data(payload.utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
            try? FileHandle.standardOutput.synchronize()
        }
    }

    private func observeCompanionProjection(_ model: AppModel, id: ObjectIdentifier) {
        companionProjectionObservers[id] = model.objectWillChange
            .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.publishCompanionProjection() }
            }
        publishCompanionProjection()
    }

    private func publishCompanionProjection() {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let drafts = Dictionary(
            windowModels.values.flatMap { $0.companionProjectionDrafts(now: now) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { current, candidate in
                (candidate.lastActivityAt ?? candidate.createdAt ?? 0)
                    > (current.lastActivityAt ?? current.createdAt ?? 0)
                    ? candidate
                    : current
            }
        ).values.sorted { $0.id < $1.id }
        var terminalStreams: [String: CompanionTerminalStreamHead] = [:]
        for stream in windowModels.values.flatMap({ $0.companionTerminalStreams() }) {
            if let existing = terminalStreams[stream.key],
               existing.streamEpoch == stream.value.streamEpoch,
               existing.endOffset >= stream.value.endOffset {
                continue
            }
            terminalStreams[stream.key] = stream.value
        }
        CompanionHost.shared.publishProjection(
            drafts: drafts,
            terminalStreams: terminalStreams,
            terminalRecords: windowModels.values.flatMap(\.sessions)
        )
    }

    /// Multiple windows may observe the same PTY, but only the AppModel whose
    /// controller socket matches the broker's current owner may service a
    /// phone lease. This prevents a second window from implicitly adopting or
    /// stealing a terminal merely because it shares the installation owner.
    private func companionController(for terminal: BrokerTerminalRecord) -> AppModel? {
        windowModels.values.first {
            $0.companionTerminalAvailability(for: terminal) != nil
        }
    }

    private func scheduleVisualCapture(of window: NSWindow, path: String) {
        Task { @MainActor in
            // Let SwiftUI settle, SwiftTerm receive real geometry, and the
            // lazy file tree finish its first background enumeration.
            // WKWebView launches a separate content process on a cold hosted
            // runner. Give that one visual surface enough time to reach its
            // delegate-confirmed ready/error state; normal app launches do not
            // pay this fixture-only delay.
            let delay: UInt64
            switch visualSurface {
            case "preview-code-editor", "preview-html": delay = 4_000_000_000
            case "terminal-scroll-output": delay = 1_800_000_000
            default: delay = 1_800_000_000
            }
            try? await Task.sleep(nanoseconds: delay)
            // The packet fixture is deliberately frame-paced through the real
            // 16 ms coalescer. A fixed capture deadline raced that bounded task
            // on loaded CI runners, cancelling it mid-stream and reporting both
            // `stream-incomplete` and `packet-rejected`. Wait for the declared
            // finite burst itself; product launches never enter this path.
            if visualSurface == "terminal-scroll-output",
               let streamingTask = visualStreamingFixtureTask {
                await streamingTask.value
            }
            guard let captureWindow = NativeVisualCaptureTarget.window(
                rootedAt: window,
                surface: visualSurface
            ) else {
                print("KAISOLA_NATIVE_VISUAL_CAPTURE=FAIL no-attached-sheet")
                requestVisualFixtureTermination()
                return
            }
            captureWindow.displayIfNeeded()
            guard let view = captureWindow.contentView else {
                print("KAISOLA_NATIVE_VISUAL_CAPTURE=FAIL no-content-view")
                requestVisualFixtureTermination()
                return
            }

            // Mixed and Mesh both select a non-terminal pane before the view is
            // hosted. Their generation-based request must survive that mount
            // and land on the real composer field editor, or the visible focus
            // ring and keyboard target have drifted again.
            if ["mixed", "mesh"].contains(visualSurface) {
                guard captureWindow.firstResponder is NSText else {
                    let responder = captureWindow.firstResponder
                        .map { String(describing: type(of: $0)) }
                        ?? "nil"
                    print(
                        "KAISOLA_NATIVE_VISUAL_COMPOSER_FOCUS=FAIL "
                            + "surface=\(visualSurface) responder=\(responder)"
                    )
                    requestVisualFixtureTermination()
                    return
                }
                print(
                    "KAISOLA_NATIVE_VISUAL_COMPOSER_FOCUS=PASS "
                        + "surface=\(visualSurface)"
                )
            }

            let terminalAccessibilityMarkers = NativeVisualTerminalAccessibilityGate.expectedMarkers(
                for: visualSurface
            )
            if let terminal = firstTerminalView(in: view) {
                let buffer = terminal.getTerminal().getBufferAsData()
                let hasFixtureText = String(data: buffer, encoding: .utf8)?.contains("Last login:") == true
                print(
                    "KAISOLA_NATIVE_VISUAL_TERMINAL="
                        + "frame=\(NSStringFromRect(terminal.frame)) "
                        + "buffer=\(buffer.count) fixtureText=\(hasFixtureText)"
                )
                if let expectedMarkers = terminalAccessibilityMarkers {
                    let accessibilityText = terminal.accessibilityValue() as? String ?? ""
                    if let failure = NativeVisualTerminalAccessibilityGate.failure(
                        in: accessibilityText,
                        expectedMarkers: expectedMarkers
                    ) {
                        print(
                            "KAISOLA_NATIVE_VISUAL_TERMINAL_ACCESSIBILITY=FAIL "
                                + "surface=\(visualSurface) reason=\(failure)"
                        )
                        requestVisualFixtureTermination()
                        return
                    }
                    print(
                        "KAISOLA_NATIVE_VISUAL_TERMINAL_ACCESSIBILITY=PASS "
                            + "surface=\(visualSurface) characters=\(accessibilityText.count)"
                    )
                    if visualSurface == "terminal-scroll-output" {
                        let scrollPosition = terminal.scrollPosition
                        let hasFinalFrame = String(data: buffer, encoding: .utf8)?
                            .contains(VisualTerminalStreamingFixture.finalMarker) == true
                        guard scrollPosition < 0.9 else {
                            print(
                                "KAISOLA_NATIVE_VISUAL_TERMINAL_SCROLL_OUTPUT=FAIL "
                                    + "reason=repinned position=\(scrollPosition)"
                            )
                            requestVisualFixtureTermination()
                            return
                        }
                        guard hasFinalFrame else {
                            print(
                                "KAISOLA_NATIVE_VISUAL_TERMINAL_SCROLL_OUTPUT=FAIL "
                                    + "reason=stream-incomplete"
                            )
                            requestVisualFixtureTermination()
                            return
                        }
                        guard let fixtureModel = windowModels[ObjectIdentifier(window)],
                              let stored = fixtureModel.persistedOwnedSessions.first(where: {
                                  $0.id == "visual-terminal"
                              }) else {
                            print(
                                "KAISOLA_NATIVE_VISUAL_TERMINAL_SCROLL_OUTPUT=FAIL "
                                    + "reason=no-persisted-session"
                            )
                            requestVisualFixtureTermination()
                            return
                        }
                        let defaultTitle = (stored.cwd as NSString).lastPathComponent
                        guard stored.title == defaultTitle,
                              stored.lastAutoTitle == nil else {
                            print(
                                "KAISOLA_NATIVE_VISUAL_TERMINAL_SCROLL_OUTPUT=FAIL "
                                    + "reason=activity-title-persisted "
                                    + "title=\(stored.title.debugDescription)"
                            )
                            requestVisualFixtureTermination()
                            return
                        }
                        print(
                            "KAISOLA_NATIVE_VISUAL_TERMINAL_SCROLL_OUTPUT=PASS "
                                + "position=\(String(format: "%.3f", scrollPosition)) "
                                + "finalMarker=true titleStable=true"
                        )
                    }
                }
            } else if terminalAccessibilityMarkers != nil {
                print(
                    "KAISOLA_NATIVE_VISUAL_TERMINAL_ACCESSIBILITY=FAIL "
                        + "surface=\(visualSurface) reason=no-terminal-view"
                )
                requestVisualFixtureTermination()
                return
            }

            if visualSurface == "preview-code-editor" {
                guard let webView = firstWebView(in: view) else {
                    print("KAISOLA_NATIVE_CODE_EDITOR_VISUAL=FAIL no-web-view")
                    requestVisualFixtureTermination()
                    return
                }
                do {
                    let inserted = try await webView.evaluateJavaScript(
                        "window.KaisolaEditor.fixtureInsert('    // Bridge edit verified\\n')"
                    ) as? Bool
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    let containsEdit = try await webView.evaluateJavaScript(
                        "window.KaisolaEditor.fixtureContains('Bridge edit verified')"
                    ) as? Bool
                    let requestedUndo = try await webView.evaluateJavaScript(
                        "window.KaisolaEditor.fixtureUndo()"
                    ) as? Bool
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    let undoRemovedEdit = try await webView.evaluateJavaScript(
                        "!window.KaisolaEditor.fixtureContains('Bridge edit verified')"
                    ) as? Bool
                    let requestedRedo = try await webView.evaluateJavaScript(
                        "window.KaisolaEditor.fixtureRedo()"
                    ) as? Bool
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    let redoRestoredEdit = try await webView.evaluateJavaScript(
                        "window.KaisolaEditor.fixtureContains('Bridge edit verified')"
                    ) as? Bool
                    let ready = try await webView.evaluateJavaScript("""
                    Boolean(
                      window.KaisolaEditor
                      && document.querySelector('.cm-editor')
                      && document.querySelectorAll('.cm-line').length >= 10
                      && document.querySelectorAll('.cm-line span').length >= 5
                    )
                    """) as? Bool
                    guard inserted == true,
                          containsEdit == true,
                          requestedUndo == true,
                          undoRemovedEdit == true,
                          requestedRedo == true,
                          redoRestoredEdit == true,
                          ready == true else {
                        print("KAISOLA_NATIVE_CODE_EDITOR_VISUAL=FAIL interaction-or-render")
                        requestVisualFixtureTermination()
                        return
                    }
                    print(
                        "KAISOLA_NATIVE_CODE_EDITOR_VISUAL=PASS "
                            + "syntax=true lines=14 edit=true undo=true redo=true"
                    )
                } catch {
                    print("KAISOLA_NATIVE_CODE_EDITOR_VISUAL=FAIL \(error.localizedDescription)")
                    requestVisualFixtureTermination()
                    return
                }
            }

            // ScreenCaptureKit captures Kaisola's WindowServer surface, but a
            // WKWebView renders through a separate WebContent process. On the
            // current-process capture path that remote layer can therefore be
            // transparent even after navigation has reached `didFinish`.
            // Capture that viewport through WebKit's own public snapshot API
            // and composite it back into the exact on-screen view rectangle.
            let webSnapshot: NativeVisualCapture.ViewSnapshot?
            if let webView = firstWebView(in: view) {
                do {
                    let image = try await webView.takeSnapshot(configuration: nil)
                    let windowRect = webView.convert(webView.bounds, to: nil)
                    let screenRect = captureWindow.convertToScreen(windowRect)
                    if let cgImage = NativeVisualCapture.cgImage(from: image) {
                        webSnapshot = .init(image: cgImage, screenFrame: screenRect)
                        print(
                            "KAISOLA_NATIVE_VISUAL_WEBKIT_SNAPSHOT="
                                + "frame=\(NSStringFromRect(screenRect)) "
                                + "pixels=\(cgImage.width)x\(cgImage.height)"
                        )
                    } else {
                        webSnapshot = nil
                        print("KAISOLA_NATIVE_VISUAL_WEBKIT_SNAPSHOT=FAIL cg-image")
                    }
                } catch {
                    webSnapshot = nil
                    print(
                        "KAISOLA_NATIVE_VISUAL_WEBKIT_SNAPSHOT=FAIL "
                            + error.localizedDescription
                    )
                }
            } else {
                webSnapshot = nil
            }

            let screenCapture: (image: CGImage, method: String)?
            if #available(macOS 14.4, *) {
                do {
                    if let parent = captureWindow.sheetParent,
                       let parentImage = try await NativeVisualCapture.image(
                            windowNumber: parent.windowNumber,
                            includeChildWindows: true
                       ),
                       let sheetImage = NativeVisualCapture.croppedImage(
                            parentImage,
                            parentFrame: parent.frame,
                            childFrame: captureWindow.frame
                       ) {
                        screenCapture = (sheetImage, "screen-capture-kit-sheet-crop")
                    } else if let image = try await NativeVisualCapture.image(
                        windowNumber: captureWindow.windowNumber,
                        includeChildWindows: false
                    ) {
                        screenCapture = (image, "screen-capture-kit")
                    } else {
                        screenCapture = nil
                    }
                } catch {
                    print(
                        "KAISOLA_NATIVE_VISUAL_CAPTURE_SCREEN_CAPTURE_KIT_ERROR="
                            + error.localizedDescription
                    )
                    screenCapture = nil
                }
            } else {
                screenCapture = nil
            }

            let data: Data?
            if let screenCapture {
                let rendered: CGImage
                let method: String
                if let webSnapshot,
                   let composited = NativeVisualCapture.compositedImage(
                        base: screenCapture.image,
                        baseScreenFrame: captureWindow.frame,
                        snapshot: webSnapshot
                   ) {
                    rendered = composited
                    method = screenCapture.method + "+webkit-snapshot"
                } else {
                    rendered = screenCapture.image
                    method = screenCapture.method
                }
                print("KAISOLA_NATIVE_VISUAL_CAPTURE_METHOD=\(method)")
                data = NSBitmapImageRep(cgImage: rendered)
                    .representation(using: .png, properties: [:])
            } else if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                print("KAISOLA_NATIVE_VISUAL_CAPTURE_METHOD=view-cache-fallback")
                view.cacheDisplay(in: view.bounds, to: bitmap)
                data = bitmap.representation(using: .png, properties: [:])
            } else {
                data = nil
            }
            guard let data else {
                print("KAISOLA_NATIVE_VISUAL_CAPTURE=FAIL png-encoding")
                requestVisualFixtureTermination()
                return
            }
            do {
                let url = URL(fileURLWithPath: path, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try data.write(to: url, options: .atomic)
                print("KAISOLA_NATIVE_VISUAL_CAPTURE=PASS \(url.path)")
            } catch {
                print("KAISOLA_NATIVE_VISUAL_CAPTURE=FAIL \(error.localizedDescription)")
            }
            requestVisualFixtureTermination()
        }
    }

    /// `terminate(_:)` enters AppKit's synchronous termination loop. Queue it
    /// after the capture task returns so the MainActor is free to run the
    /// delegate's async teardown before replying to `.terminateLater`.
    private func requestVisualFixtureTermination() {
        visualStreamingFixtureTask?.cancel()
        visualStreamingFixtureTask = nil
        DispatchQueue.main.async { [visualFixture] in
            if visualFixture {
                // A SwiftUI sheet can keep AppKit's terminate path inside its
                // modal presentation even after the capture is written. These
                // fixtures are broker-free and use disposable per-process
                // stores, so stop the explicit `application.run()` loop and
                // post one wake event that lets it return naturally.
                NSApp.stop(nil)
                if let wake = NSEvent.otherEvent(
                    with: .applicationDefined,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0,
                    context: nil,
                    subtype: 0,
                    data1: 0,
                    data2: 0
                ) {
                    NSApp.postEvent(wake, atStart: false)
                }
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func firstTerminalView(in view: NSView) -> ReadOnlyTerminalView? {
        if let terminal = view as? ReadOnlyTerminalView { return terminal }
        for child in view.subviews {
            if let terminal = firstTerminalView(in: child) { return terminal }
        }
        return nil
    }

    /// Scroll a real SwiftTerm viewport away from live output, then deliver a
    /// dense packet burst through AppModel's ordinary 16 ms coalescer. The
    /// capture gate later proves the historical viewport survived while the
    /// final packet still reached the parser.
    private func scheduleVisualTerminalStreamingFixture(
        in window: NSWindow,
        model: AppModel
    ) {
        visualStreamingFixtureTask?.cancel()
        visualStreamingFixtureTask = Task { @MainActor [weak self, weak window, weak model] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self,
                  let window,
                  let model,
                  !Task.isCancelled,
                  let contentView = window.contentView,
                  let terminal = self.firstTerminalView(in: contentView),
                  terminal.canScroll else {
                print("KAISOLA_NATIVE_VISUAL_TERMINAL_SCROLL_OUTPUT=FAIL reason=no-scrollable-terminal")
                self?.requestVisualFixtureTermination()
                return
            }

            // The event monitor normally records a user's wheel/page gesture.
            // Hosted QA has no human input, so mark the exact isolated view and
            // invoke SwiftTerm's public scroll API; its delegate still owns the
            // production user-unpinned transition.
            TerminalScrollGestureMonitor.noteGestureForTesting(view: terminal)
            terminal.scroll(toPosition: 0.35)
            await Task.yield()
            let startingPosition = terminal.scrollPosition
            guard startingPosition < 0.9 else {
                print(
                    "KAISOLA_NATIVE_VISUAL_TERMINAL_SCROLL_OUTPUT=FAIL "
                        + "reason=scroll-did-not-leave-bottom position=\(startingPosition)"
                )
                requestVisualFixtureTermination()
                return
            }

            for index in VisualTerminalStreamingFixture.packetIndices {
                guard !Task.isCancelled,
                      model.enqueueVisualTerminalStreamingPacket(index) else {
                    print(
                        "KAISOLA_NATIVE_VISUAL_TERMINAL_SCROLL_OUTPUT=FAIL "
                            + "reason=packet-rejected index=\(index)"
                    )
                    requestVisualFixtureTermination()
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000)
            }
            model.finishVisualTerminalStreamingBurst()
            await Task.yield()
            print(
                "KAISOLA_NATIVE_VISUAL_TERMINAL_SCROLL_OUTPUT_BURST=PASS "
                    + "packets=\(VisualTerminalStreamingFixture.packetIndices.count) "
                    + "start=\(String(format: "%.3f", startingPosition)) "
                    + "end=\(String(format: "%.3f", terminal.scrollPosition))"
            )
            self.visualStreamingFixtureTask = nil
        }
    }

    private func firstWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let webView = firstWebView(in: child) { return webView }
        }
        return nil
    }

    /// The AppModel for the frontmost window (menu-command target).
    private func keyModel() -> AppModel? {
        guard !terminationPreparationInProgress, !terminationPrepared else { return nil }
        if let key = NSApp.keyWindow, let model = windowModels[ObjectIdentifier(key)] { return model }
        if let lastWorkspaceWindow,
           let model = windowModels[ObjectIdentifier(lastWorkspaceWindow)] {
            return model
        }
        return NSApp.orderedWindows.compactMap { windowModels[ObjectIdentifier($0)] }.first
    }

    /// Typed command plumbing. The registry owns command meaning; the delegate
    /// contributes only process/window capabilities that a value-type SwiftUI
    /// view cannot own.
    func commandWindow(for model: AppModel?) -> NSWindow? {
        if let model,
           let entry = windowModels.first(where: { $0.value === model }) {
            return NSApp.windows.first { ObjectIdentifier($0) == entry.key }
        }
        if let key = NSApp.keyWindow, windowModels[ObjectIdentifier(key)] != nil { return key }
        if let lastWorkspaceWindow,
           windowModels[ObjectIdentifier(lastWorkspaceWindow)] != nil {
            return lastWorkspaceWindow
        }
        return NSApp.orderedWindows.first { windowModels[ObjectIdentifier($0)] != nil }
    }

    func commandFocusedTerminal(for model: AppModel?) -> ReadOnlyTerminalView? {
        let model = model ?? keyModel()
        return TerminalFocusResolver.focusedTerminal(
            in: commandWindow(for: model),
            paneID: model?.focusedPaneID
        )
    }

    var commandCanCheckForUpdates: Bool { updateController.availability.canCheck }
    var commandUpdateDetail: String? { updateController.availability.detail }

    func performNewWindowCommand() { _ = makeWindow() }
    func performOpenProjectInNewWindowCommand() { openFolderInNewWindow(nil) }
    func performOpenSettingsCommand() { openSettings(nil) }
    func performCheckForUpdatesCommand() { updateController.checkForUpdates(nil) }
    func performOpenHelpCommand() { openHelp(nil) }

    func performCloseWindowCommand(for model: AppModel?) {
        commandWindow(for: model)?.performClose(nil)
    }

    @objc private func runRegisteredCommand(_ sender: Any?) {
        guard let rawID = (sender as? NSMenuItem)?.representedObject as? String else { return }
        _ = AppCommandRegistry.execute(
            AppCommandID(rawValue: rawID),
            in: AppCommandContext(model: keyModel(), settings: settings)
        )
    }

    private func revealAttentionTarget(_ targetID: String) {
        let ordered = NSApp.orderedWindows.compactMap { window -> (NSWindow, AppModel)? in
            windowModels[ObjectIdentifier(window)].map { (window, $0) }
        }
        let visibleOwner = ordered.first { $0.1.isSurfaceVisible(targetID) }
        let keyOwner = NSApp.keyWindow.flatMap { window -> (NSWindow, AppModel)? in
            guard let model = windowModels[ObjectIdentifier(window)],
                  model.containsAttentionTarget(targetID) else { return nil }
            return (window, model)
        }
        guard let (window, model) = visibleOwner
            ?? keyOwner
            ?? ordered.first(where: { $0.1.containsAttentionTarget(targetID) }) else {
            AttentionCenter.shared.clear(targetID: targetID)
            ToastCenter.shared.show("That session is no longer open", style: .info)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.jumpToAttentionTarget(targetID)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for model in windowModels.values { model.resumeIfNeeded() }
    }

    private func handleRememberedSessionAuthPhase(_ phase: AuthPhase) {
        let nextAccountID: String?
        if case let .signedIn(account) = phase {
            nextAccountID = account.uid
            if !visualFixture {
                UserDefaults.standard.set(
                    true,
                    forKey: NativeAccountKeychainMigration.completionDefaultsKey
                )
            }
        } else {
            nextAccountID = nil
        }

        CompanionHost.shared.setKaisolaLinkSignedIn(nextAccountID != nil)
        guard nextAccountID != rememberedSessionAccountID else { return }

        rememberedSessionAccountID = nextAccountID
        rememberedSessionAccountGeneration &+= 1
        rememberedSessionSyncTask?.cancel()
        rememberedSessionSyncTask = nil
        rememberedSessionRefreshGeneration = nil
        rememberedSessions.clear()

        guard let accountID = nextAccountID else {
            if let rememberedSessionCatalog {
                Task { await rememberedSessionCatalog.deactivate() }
            }
            return
        }
        guard rememberedSessionCatalog != nil else { return }
        let generation = rememberedSessionAccountGeneration
        rememberedSessionSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let snapshot = try? await self.rememberedSessionCatalogCache.load(
                accountID: accountID
            ),
               !Task.isCancelled,
               self.rememberedSessionAccountID == accountID,
               self.rememberedSessionAccountGeneration == generation,
               self.auth.account?.uid == accountID {
                self.rememberedSessions.apply(
                    snapshot.devices,
                    now: snapshot.savedAt,
                    source: .savedSnapshot
                )
            }
            while !Task.isCancelled,
                  self.rememberedSessionAccountID == accountID,
                  self.rememberedSessionAccountGeneration == generation {
                await self.publishRememberedSessions(
                    expectedAccountID: accountID,
                    expectedGeneration: generation
                )
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    break
                }
            }
        }
    }

    private func publishRememberedSessions(
        expectedAccountID: String? = nil,
        expectedGeneration: UInt64? = nil
    ) async {
        guard let rememberedSessionCatalog,
              let accountID = auth.account?.uid,
              accountID == rememberedSessionAccountID else { return }
        let generation = rememberedSessionAccountGeneration
        guard expectedAccountID == nil || expectedAccountID == accountID,
              expectedGeneration == nil || expectedGeneration == generation,
              rememberedSessionRefreshGeneration != generation else { return }
        rememberedSessionRefreshGeneration = generation
        rememberedSessions.beginRefresh()
        defer {
            if rememberedSessionRefreshGeneration == generation {
                rememberedSessionRefreshGeneration = nil
            }
        }

        func isCurrent() -> Bool {
            !Task.isCancelled
                && rememberedSessionAccountID == accountID
                && rememberedSessionAccountGeneration == generation
                && auth.account?.uid == accountID
        }

        do {
            let token = try await auth.freshIDToken()
            guard isCurrent() else { return }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let allDrafts = windowModels.values.flatMap { $0.rememberedSessionDrafts(now: now) }
            let drafts = Dictionary(
                allDrafts.map { ($0.id, $0) },
                uniquingKeysWith: { current, candidate in
                    (candidate.lastActivityAt ?? 0) > (current.lastActivityAt ?? 0)
                        ? candidate
                        : current
                }
            ).values.sorted { $0.id < $1.id }
            let ownerID = NativeSessionStore().ownerID()
            let deviceID = RememberedSessionCatalogDevice.id(from: ownerID)
            let rawDeviceName = Host.current().localizedName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceName = rawDeviceName?.isEmpty == false ? rawDeviceName! : "Kaisola Mac"
            try await rememberedSessionCatalog.publish(
                idToken: token,
                accountID: accountID,
                deviceID: deviceID,
                deviceName: deviceName,
                drafts: drafts,
                now: now
            )
            guard isCurrent() else { return }
            let devices = try await rememberedSessionCatalog.list(
                idToken: token,
                accountID: accountID
            )
            guard isCurrent() else { return }
            rememberedSessions.apply(devices, now: now)
            try? await rememberedSessionCatalogCache.save(
                accountID: accountID,
                devices: devices,
                savedAt: now
            )
        } catch is CancellationError {
            // Account transitions deliberately invalidate suspended catalog
            // work. The new account owns the next refresh state.
        } catch {
            // Catalog sync is an account convenience, never a reason to log the
            // user out or interfere with local sessions. The next heartbeat
            // retries with a fresh Firebase ID token and revision handshake.
            guard isCurrent() else { return }
            rememberedSessions.fail(error)
        }
    }

    private func runKaisolaLinkSmoke() async {
        // An ad-hoc/XCTest build cannot reliably read the production Keychain
        // access group and is not representative of the shipped app. Refuse
        // before restoring account state so a local debug probe has a fast,
        // explicit result instead of looking like a relay timeout.
        guard Self.hasTeamSignedExecutable else {
            finishLinkSmoke("KAISOLA_NATIVE_LINK_SMOKE=UNSIGNED")
            return
        }
        guard let relayURL = firebaseAuthConfiguration?.relayURL else {
            finishLinkSmoke("KAISOLA_NATIVE_LINK_SMOKE=UNAVAILABLE")
            return
        }
        let pipedToken: String?
        if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_LINK_SMOKE_TOKEN_STDIN"] == "1" {
            // The live bridge probe writes a short-lived Firebase ID token over
            // an anonymous pipe. It never appears in argv, environment, logs,
            // or files, and lets a Developer ID build prove its own native WSS
            // stack even when a local ad-hoc build owns the Keychain ACL.
            Darwin.signal(SIGALRM, linkSmokeInputTimeoutSignalHandler)
            Darwin.alarm(5)
            let bytes = FileHandle.standardInput.readDataToEndOfFile()
            let value = String(data: bytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, (20...20_000).contains(value.utf8.count) else {
                finishLinkSmoke("KAISOLA_NATIVE_LINK_SMOKE=INVALID_INPUT")
                return
            }
            pipedToken = value
        } else {
            pipedToken = nil
            Darwin.signal(SIGALRM, linkSmokeStorageTimeoutSignalHandler)
            Darwin.alarm(10)
            do {
                let smokeStore = KeychainAuthSecureStore(
                    interactionPolicy: .failIfInteractionRequired
                )
                guard try smokeStore.data(for: "firebase-refresh-token") != nil else {
                    finishLinkSmoke("KAISOLA_NATIVE_LINK_SMOKE=AUTH_REQUIRED")
                    return
                }
            } catch {
                finishLinkSmoke("KAISOLA_NATIVE_LINK_SMOKE=KEYCHAIN_ERROR")
                return
            }
            Darwin.signal(SIGALRM, linkSmokeAuthTimeoutSignalHandler)
            Darwin.alarm(20)
            await auth.restore()
            guard auth.isSignedIn else {
                finishLinkSmoke("KAISOLA_NATIVE_LINK_SMOKE=AUTH_REQUIRED")
                return
            }
        }
        let endToEnd = ProcessInfo.processInfo.environment[
            "KAISOLA_NATIVE_LINK_SMOKE_BROWSER_E2E"
        ] == "1"
        Darwin.signal(SIGALRM, linkSmokeRelayTimeoutSignalHandler)
        Darwin.alarm(endToEnd ? 45 : 25)
        let smokeID: String
        let cleanupURL: URL?
        let pairingCode: String?
        let endToEndState: CompanionNativeBrowserLinkSmoke?
        if endToEnd {
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "kaisola-native-browser-smoke-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let identity = try CompanionIdentity(
                    id: "desktop-smoke-\(UUID().uuidString.lowercased())",
                    role: .desktop,
                    displayName: "Kaisola signed relay smoke"
                )
                let roster = try CompanionDeviceRosterStore(
                    fileURL: directory.appendingPathComponent("devices-v1.json")
                )
                let coordinator = try CompanionPairingCoordinator(
                    identity: identity,
                    roster: roster
                )
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                let offer = try await coordinator.createOffer(
                    listenerPort: 49_321,
                    requestedCapabilities: [.observe],
                    nowMilliseconds: now
                )
                let encodedOffer = try CanonicalJSON.data(from: offer)
                    .base64URLEncodedString()
                smokeID = identity.id
                cleanupURL = directory
                pairingCode = encodedOffer
                endToEndState = CompanionNativeBrowserLinkSmoke(
                    coordinator: coordinator,
                    roster: roster,
                    cleanupURL: directory,
                    emit: { [weak self] line in
                        Task { @MainActor [weak self] in self?.writeLinkSmokeLine(line) }
                    },
                    finish: { [weak self] status in
                        Task { @MainActor [weak self] in self?.finishLinkSmoke(status) }
                    }
                )
            } catch {
                finishLinkSmoke("KAISOLA_NATIVE_LINK_SMOKE=E2E_SETUP_ERROR")
                return
            }
        } else {
            smokeID = "desktop-smoke-\(UUID().uuidString.lowercased())"
            cleanupURL = nil
            pairingCode = nil
            endToEndState = nil
        }
        guard let client = CompanionLinkClient(
            desktopID: smokeID,
            baseURL: relayURL,
            tokenProvider: { [weak self, pipedToken] in
                if let pipedToken { return pipedToken }
                guard let self else { throw CompanionRelayError.authenticationRequired }
                return try await self.auth.freshIDToken()
            },
            acceptSocket: { socket in
                if let endToEndState {
                    Task { await endToEndState.accept(socket) }
                } else {
                    Task { await socket.localClose() }
                }
            }
        ) else {
            if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) }
            finishLinkSmoke("KAISOLA_NATIVE_LINK_SMOKE=UNAVAILABLE")
            return
        }
        client.enable()
        let deadline = ContinuousClock.now.advanced(by: .seconds(endToEnd ? 35 : 15))
        var pairingCodeEmitted = false
        while ContinuousClock.now < deadline {
            if client.phase == .ready {
                if endToEnd {
                    if !pairingCodeEmitted, let pairingCode {
                        pairingCodeEmitted = true
                        writeLinkSmokeLine("KAISOLA_NATIVE_LINK_PAIRING=\(pairingCode)")
                    }
                    if linkSmokeFinished { return }
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                client.disable()
                let credential = pipedToken == nil ? "keychain" : "pipe"
                finishLinkSmoke(
                    "KAISOLA_NATIVE_LINK_SMOKE=PASS protocol=1 transport=wss credential=\(credential)"
                )
                return
            }
            if client.phase == .authenticationRequired {
                client.disable()
                finishLinkSmoke("KAISOLA_NATIVE_LINK_SMOKE=AUTH_REQUIRED")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        client.disable()
        if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) }
        finishLinkSmoke(endToEnd
            ? "KAISOLA_NATIVE_LINK_SMOKE=E2E_TIMEOUT"
            : "KAISOLA_NATIVE_LINK_SMOKE=TIMEOUT")
    }

    private enum CatalogSmokeFailure: Error {
        case timeout
        case verification
    }

    private func runKaisolaCatalogSmoke() async {
        guard Self.hasTeamSignedExecutable else {
            finishCatalogSmoke("KAISOLA_NATIVE_CATALOG_SMOKE=UNSIGNED")
        }
        guard let catalog = rememberedSessionCatalog else {
            finishCatalogSmoke("KAISOLA_NATIVE_CATALOG_SMOKE=UNAVAILABLE")
        }

        let token: String
        let accountID: String
        let credential: String
        if ProcessInfo.processInfo.environment[
            "KAISOLA_NATIVE_CATALOG_SMOKE_TOKEN_STDIN"
        ] == "1" {
            // The existing Electron account can exercise the source-current
            // native client before the one-time native sign-in. Its short-lived
            // token crosses only an anonymous pipe and is never placed in argv,
            // environment, logs, files, or the catalog body.
            Darwin.signal(SIGALRM, catalogSmokeInputTimeoutSignalHandler)
            Darwin.alarm(5)
            let bytes = FileHandle.standardInput.readDataToEndOfFile()
            guard let value = String(data: bytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  (20...20_000).contains(value.utf8.count) else {
                finishCatalogSmoke("KAISOLA_NATIVE_CATALOG_SMOKE=INVALID_INPUT")
            }
            token = value
            accountID = "catalog-smoke-anonymous-pipe"
            credential = "pipe"
        } else {
            // Avoid opening a Keychain authorization prompt in a headless
            // process. A deliberate sign-in through the ordinary account UI is
            // the one human gate; the same Developer ID requirement is silent
            // thereafter.
            Darwin.alarm(10)
            do {
                let smokeStore = KeychainAuthSecureStore(
                    interactionPolicy: .failIfInteractionRequired
                )
                guard try smokeStore.data(for: "firebase-refresh-token") != nil else {
                    finishCatalogSmoke("KAISOLA_NATIVE_CATALOG_SMOKE=AUTH_REQUIRED")
                }
            } catch {
                finishCatalogSmoke("KAISOLA_NATIVE_CATALOG_SMOKE=KEYCHAIN_ERROR")
            }

            Darwin.alarm(20)
            await auth.restore()
            guard let restoredAccountID = auth.account?.uid else {
                finishCatalogSmoke("KAISOLA_NATIVE_CATALOG_SMOKE=AUTH_REQUIRED")
            }
            accountID = restoredAccountID
            do {
                token = try await auth.freshIDToken()
            } catch {
                finishCatalogSmoke("KAISOLA_NATIVE_CATALOG_SMOKE=TOKEN_ERROR")
            }
            credential = "keychain"
        }

        Darwin.alarm(90)
        // A stable device key makes a killed previous run self-healing: the
        // next publish replaces that account's old synthetic snapshot and the
        // final remove still deletes the whole smoke document.
        let deviceID = "catalog-smoke-native-macos"
        let sessionID = "catalog-smoke-\(UUID().uuidString.lowercased())"
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let draft = RememberedSessionDraft(
            id: sessionID,
            projectID: "kaisola-catalog-smoke",
            projectName: "Kaisola catalog smoke",
            title: "Signed account catalog proof",
            kind: .agentChat,
            agentID: "kaisola-smoke",
            activity: .idle,
            resumeKind: .metadataOnly,
            createdAt: now,
            lastActivityAt: now,
            hasLocalTranscript: false
        )
        var needsCleanup = false
        do {
            needsCleanup = true
            _ = try await withCatalogSmokeTimeout {
                try await catalog.publish(
                    idToken: token,
                    accountID: accountID,
                    deviceID: deviceID,
                    deviceName: "Kaisola signed smoke",
                    drafts: [draft],
                    now: now
                )
            }
            writeCatalogSmokeLine("KAISOLA_NATIVE_CATALOG_STAGE=PUBLISHED")

            let afterPublish = try await withCatalogSmokeTimeout {
                try await catalog.list(idToken: token, accountID: accountID)
            }
            guard let device = afterPublish.first(where: { $0.deviceId == deviceID }),
                  device.deviceName == "Kaisola signed smoke",
                  device.sessions == [RememberedSessionRecord(
                    id: sessionID,
                    projectId: "kaisola-catalog-smoke",
                    projectName: "Kaisola catalog smoke",
                    title: "Signed account catalog proof",
                    kind: .agentChat,
                    agentId: "kaisola-smoke",
                    activity: .idle,
                    resumeKind: .metadataOnly,
                    createdAt: now,
                    lastActivityAt: now,
                    hasLocalTranscript: false
                  )] else {
                throw CatalogSmokeFailure.verification
            }
            writeCatalogSmokeLine("KAISOLA_NATIVE_CATALOG_STAGE=READ_EXACT")

            try await withCatalogSmokeTimeout {
                try await catalog.removeDevice(
                    idToken: token,
                    accountID: accountID,
                    deviceID: deviceID
                )
            }
            needsCleanup = false
            writeCatalogSmokeLine("KAISOLA_NATIVE_CATALOG_STAGE=REMOVED")

            let afterRemove = try await withCatalogSmokeTimeout {
                try await catalog.list(idToken: token, accountID: accountID)
            }
            guard !afterRemove.contains(where: { $0.deviceId == deviceID }) else {
                throw CatalogSmokeFailure.verification
            }
            await catalog.deactivate()
            finishCatalogSmoke(
                "KAISOLA_NATIVE_CATALOG_SMOKE=PASS publish=1 read=exact remove=1 absent=1 account-scoped=1 credential=\(credential)"
            )
        } catch {
            // Invalidate a timed-out request before cleanup. If the publish did
            // reach Firestore, the deterministic smoke device is deleted with
            // the same in-memory token and UID; neither is printed or stored.
            await catalog.deactivate()
            if needsCleanup {
                try? await withCatalogSmokeTimeout {
                    try await catalog.removeDevice(
                        idToken: token,
                        accountID: accountID,
                        deviceID: deviceID
                    )
                }
            }
            await catalog.deactivate()
            finishCatalogSmoke("KAISOLA_NATIVE_CATALOG_SMOKE=FAILED")
        }
    }

    private func withCatalogSmokeTimeout<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw CatalogSmokeFailure.timeout
            }
            guard let result = try await group.next() else {
                throw CatalogSmokeFailure.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private static var hasTeamSignedExecutable: Bool {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
              let dynamicCode else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess,
              let information = rawInformation as? [String: Any],
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String else {
            return false
        }
        return !teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func finishLinkSmoke(_ value: String) {
        guard !linkSmokeFinished else { return }
        linkSmokeFinished = true
        Darwin.alarm(0)
        writeLinkSmokeLine(value)
        // The multi-channel E2E probe can finish from inside URLSession's
        // WebSocket receive callback. AppKit may defer terminate(_:) in that
        // reentrant path even after accepting the request, leaving a proved
        // smoke child alive until its outer alarm. The status is synchronized
        // above and the probe owns only ephemeral state, so successful E2E
        // completion exits directly. Normal app and failure teardown still use
        // the ordinary AppKit lifecycle below.
        if value.hasPrefix("KAISOLA_NATIVE_LINK_SMOKE=PASS_E2E ") {
            Darwin._exit(0)
        }
        NSApp.terminate(nil)
    }

    private func finishCatalogSmoke(_ value: String) -> Never {
        guard !catalogSmokeFinished else { Darwin._exit(1) }
        catalogSmokeFinished = true
        Darwin.alarm(0)
        writeCatalogSmokeLine(value)
        // This path intentionally skips applicationWillTerminate, whose normal
        // workspace cleanup reaches shared Companion state. The smoke process
        // owns no windows, broker clients, listeners, or PTYs.
        Darwin._exit(value.hasPrefix("KAISOLA_NATIVE_CATALOG_SMOKE=PASS ") ? 0 : 1)
    }

    private func writeCatalogSmokeLine(_ value: String) {
        let handle = FileHandle.standardOutput
        handle.write(Data("\(value)\n".utf8))
        try? handle.synchronize()
    }

    private func writeLinkSmokeLine(_ value: String) {
        let handle = FileHandle.standardOutput
        handle.write(Data("\(value)\n".utf8))
        try? handle.synchronize()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CompanionHost.shared.shutdown()
        companionProjectionObservers.removeAll()
        companionAttentionObserver?.cancel()
        companionAttentionObserver = nil
        rememberedSessionSyncTask?.cancel()
        rememberedSessionSyncTask = nil
        if let rememberedSessionRefreshObserver {
            NotificationCenter.default.removeObserver(rememberedSessionRefreshObserver)
        }
        rememberedSessionRefreshObserver = nil
        authPhaseObserver?.cancel()
        authPhaseObserver = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let agentsObserver { NotificationCenter.default.removeObserver(agentsObserver) }
        if let keymapObserver { NotificationCenter.default.removeObserver(keymapObserver) }
        if let commandPresentationObserver {
            NotificationCenter.default.removeObserver(commandPresentationObserver)
        }
        if let runInTerminalObserver { NotificationCenter.default.removeObserver(runInTerminalObserver) }
        if let checkForUpdatesObserver { NotificationCenter.default.removeObserver(checkForUpdatesObserver) }
        wakeObserver = nil
        agentsObserver = nil
        keymapObserver = nil
        commandPresentationObserver = nil
        runInTerminalObserver = nil
        checkForUpdatesObserver = nil
        if let suite = Self.isolatedSettingsSuite {
            let defaults = UserDefaults(suiteName: suite)
            defaults?.removePersistentDomain(forName: suite)
            defaults?.synchronize()
        }
        if let visualFixtureStorageRoot {
            try? FileManager.default.removeItem(at: visualFixtureStorageRoot)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// AppKit's synchronous `terminate(_:)` loop does not service new MainActor
    /// jobs while waiting on `.terminateLater`. Cancel the first quit attempt,
    /// finish model teardown after AppKit unwinds, then issue one prepared quit
    /// that returns `.terminateNow`. The drain is persistence-first and bounded:
    /// a wedged adapter or continuously painting terminal must never leave every
    /// workspace window hidden while the app consumes CPU forever.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPrepared { return .terminateNow }
        if terminationPreparationInProgress { return .terminateCancel }
        terminationPreparationInProgress = true
        // Returning terminateCancel lets MainActor teardown run, so remove all
        // interactive entry points immediately. Incoming ACP/broker events are
        // still drained by each model's awaited teardown below.
        NotificationCenter.default.post(name: .kaisolaFlushFilePreviews, object: nil)
        for window in NSApp.windows where windowModels[ObjectIdentifier(window)] != nil {
            window.ignoresMouseEvents = true
            window.orderOut(nil)
            // A hidden SwiftTerm view can continue invalidating its backing
            // layers while output arrives. Unmount the UI once previews have
            // flushed; the AppModel remains owned until its async drain ends.
            window.contentView = nil
        }
        guard !windowModels.isEmpty || !teardownTasks.isEmpty else {
            terminationPreparationInProgress = false
            return .terminateNow
        }
        terminationDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-snapshot until quiescent. makeWindow() is gated while this
            // loop runs, but the loop also safely absorbs a window registered
            // by an already-enqueued action from before the quit request.
            while !self.windowModels.isEmpty || !self.teardownTasks.isEmpty {
                for (id, model) in self.windowModels where self.teardownTasks[id] == nil {
                    self.teardownTasks[id] = Task { await model.teardown() }
                }
                let pending = self.teardownTasks
                for (id, task) in pending {
                    await task.value
                    self.teardownTasks.removeValue(forKey: id)
                    self.windowModels.removeValue(forKey: id)
                }
            }
            self.finishTerminationPreparation(timedOut: false)
        }
        terminationDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.terminationDrainDeadlineNanoseconds)
            guard !Task.isCancelled else { return }
            self?.finishTerminationPreparation(timedOut: true)
        }
        return .terminateCancel
    }

    private func finishTerminationPreparation(timedOut: Bool) {
        guard terminationPreparationInProgress else { return }
        if timedOut {
            terminationDrainTask?.cancel()
            FileHandle.standardError.write(Data("KAISOLA_TERMINATION_DRAIN=TIMEOUT\n".utf8))
        } else {
            terminationDeadlineTask?.cancel()
        }
        terminationDrainTask = nil
        terminationDeadlineTask = nil
        terminationPreparationInProgress = false
        terminationPrepared = true
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWorkspaceObserver?.cancel()
            settingsWorkspaceObserver = nil
            settingsWorkspaceModelID = nil
            settingsWindow = nil
            return
        }
        let id = ObjectIdentifier(window)
        let model = windowModels.removeValue(forKey: id)
        if window === lastWorkspaceWindow { lastWorkspaceWindow = nil }
        if settingsWorkspaceModelID == id {
            settingsWorkspaceObserver?.cancel()
            settingsWorkspaceObserver = nil
            settingsWorkspaceModelID = nil
            if let settingsWindow, settingsWindow.isVisible {
                bindSettingsWindow(settingsWindow, to: activeSettingsModel())
            }
        }
        guard let model else { return }
        companionProjectionObservers.removeValue(forKey: id)
        publishCompanionProjection()
        if teardownTasks[id] == nil {
            teardownTasks[id] = Task { @MainActor [weak self] in
                await model.teardown()
                // Ordinary window closes must not retain a completed Task for
                // the rest of the process lifetime. The termination drain has
                // its own snapshot-and-remove loop for models still open when
                // Quit begins.
                self?.teardownTasks.removeValue(forKey: id)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              windowModels[ObjectIdentifier(window)] != nil else { return }
        lastWorkspaceWindow = window
        if let settingsWindow, settingsWindow.isVisible {
            bindSettingsWindow(settingsWindow, to: windowModels[ObjectIdentifier(window)])
        }
    }

    /// Choose a folder first, then create an independent workspace window for
    /// it. This keeps the existing key window untouched and makes the semantic
    /// difference between "switch project" and "open another project" explicit.
    @objc private func openFolderInNewWindow(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open in New Window"
        panel.message = "Choose a project folder for a separate Kaisola window."
        panel.directoryURL = NativeFolderPickerStartingPoint.preferred(
            currentProject: keyModel()?.currentProjectDirectory
        )
        panel.begin { [weak self] response in
            guard response == .OK, let directory = panel.urls.first else { return }
            Task { @MainActor in
                _ = self?.makeWindow(initialProjectDirectory: directory)
            }
        }
    }

    /// SwiftUI utility shelves can use the same nonmodal project-window flow
    /// without reaching into the delegate's private window registry.
    static func promptForProjectInNewWindow() {
        (NSApp.delegate as? KaisolaMacAppDelegate)?.openFolderInNewWindow(nil)
    }

    /// Open a session in its own fresh window (the native "pop out"): the new
    /// window's independent AppModel selects the same broker session.
    static func popOut(sessionID: String) {
        guard let delegate = NSApp.delegate as? KaisolaMacAppDelegate else {
            ToastCenter.shared.show("Kaisola could not open a new window.", style: .error)
            return
        }
        guard let window = delegate.makeWindow() else {
            ToastCenter.shared.show("Kaisola could not open a new window right now.", style: .error)
            return
        }
        guard let model = delegate.windowModels[ObjectIdentifier(window)] else {
            window.close()
            ToastCenter.shared.show("The new window could not load its project.", style: .error)
            return
        }
        Task {
            // Wait for the fresh model's broker connection before selecting.
            for _ in 0..<50 where !model.connectionState.isConnected {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await model.openPopOutTarget(sessionID)
        }
    }

    /// A normal click on a terminal already displayed by another workspace
    /// window should reveal that live surface instead of silently creating a
    /// second observer in the current window. Hidden terminals still select in
    /// the current window, and cross-project selection remains AppModel-owned.
    static func focusWindow(displayingSurface id: String) -> Bool {
        guard let delegate = NSApp.delegate as? KaisolaMacAppDelegate else { return false }
        let keyWindow = NSApp.keyWindow
        for window in NSApp.windows {
            if let keyWindow, window === keyWindow { continue }
            guard let model = delegate.windowModels[ObjectIdentifier(window)],
                  model.isSurfaceVisible(id) else { continue }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        return false
    }

    // MARK: - Recents & saved windows

    private lazy var savedWindows: SavedWindowsStore = {
        guard let suite = Self.isolatedSettingsSuite,
              let defaults = UserDefaults(suiteName: suite) else {
            return SavedWindowsStore()
        }
        return SavedWindowsStore(defaults: defaults)
    }()

    @objc private func openRecentFolder(_ sender: Any?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String,
              let model = keyModel() else { return }
        model.openProject(directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Save the key window's frame + active project under a user-chosen name.
    @objc private func saveWindowLayout(_ sender: Any?) {
        guard let window = NSApp.keyWindow, let model = windowModels[ObjectIdentifier(window)] else { return }
        let alert = NSAlert()
        alert.messageText = "Save Window Layout"
        alert.informativeText = "Name this window state; opening it later restores the frame and active project."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Layout name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        savedWindows.save(SavedWindowState(
            name: name,
            frame: NSStringFromRect(window.frame),
            projectName: model.selectedProjectName,
            projectPath: model.currentProjectDirectory?.standardizedFileURL.path
        ))
        ToastCenter.shared.show("Layout saved", style: .success)
    }

    @objc private func openSavedWindow(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String,
              let state = savedWindows.all().first(where: { $0.name == name }) else { return }
        _ = openSavedWindowState(state)
    }

    @discardableResult
    private func openSavedWindowState(
        _ state: SavedWindowState,
        preparesResourceWorkload: Bool = true
    ) -> NSWindow? {
        let projectDirectory = state.projectDirectory()
        guard let window = makeWindow(
            initialProjectDirectory: projectDirectory,
            legacyInitialProjectName: projectDirectory == nil ? state.projectName : nil,
            preparesResourceWorkload: preparesResourceWorkload
        ) else { return nil }
        let frame = NSRectFromString(state.frame)
        if frame.width > 200, frame.height > 200 { window.setFrame(frame, display: true) }
        return window
    }

    @objc private func deleteSavedWindow(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        savedWindows.remove(name: name)
    }

    /// Populates the dynamic submenus (Open Recent / Saved Windows) on open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu.title {
        case "Open Recent":
            let recents = NativeSessionStore().recentFolders()
            if recents.isEmpty {
                menu.addItem(NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: ""))
            }
            for path in recents {
                let item = menu.addItem(
                    withTitle: (path as NSString).abbreviatingWithTildeInPath,
                    action: #selector(openRecentFolder(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = path
            }
        case "Saved Windows":
            let states = savedWindows.all()
            if states.isEmpty {
                menu.addItem(NSMenuItem(title: "No Saved Windows", action: nil, keyEquivalent: ""))
            }
            for state in states {
                let item = menu.addItem(withTitle: state.name, action: #selector(openSavedWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = state.name
            }
            if !states.isEmpty {
                menu.addItem(.separator())
                let deleteItem = menu.addItem(withTitle: "Delete Saved Window", action: nil, keyEquivalent: "")
                let deleteMenu = NSMenu(title: "Delete Saved Window")
                for state in states {
                    let item = deleteMenu.addItem(withTitle: state.name, action: #selector(deleteSavedWindow(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = state.name
                }
                deleteItem.submenu = deleteMenu
            }
        default:
            break
        }
    }

    private var settingsWindow: NSWindow?

    @objc func openSettings(_ sender: Any?) {
        let model = activeSettingsModel()
        if let settingsWindow, settingsWindow.isVisible {
            bindSettingsWindow(settingsWindow, to: model)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 810, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        window.delegate = self
        bindSettingsWindow(window, to: model)
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    /// Resolve Settings against the frontmost project window, never against
    /// the Settings window or dictionary iteration order.
    private func activeSettingsModel() -> AppModel? {
        if let key = NSApp.keyWindow,
           let model = windowModels[ObjectIdentifier(key)] {
            lastWorkspaceWindow = key
            return model
        }
        if let lastWorkspaceWindow,
           let model = windowModels[ObjectIdentifier(lastWorkspaceWindow)] {
            return model
        }
        return NSApp.orderedWindows.compactMap { windowModels[ObjectIdentifier($0)] }.first
            ?? windowModels.values.first
    }

    /// Re-render workspace-scoped tabs whenever their owning AppModel switches
    /// projects while Settings is open. This prevents MCP/account changes from
    /// silently landing in the project that happened to be active at creation.
    private func bindSettingsWindow(_ window: NSWindow, to model: AppModel?) {
        settingsWorkspaceObserver?.cancel()
        let capturedModel = model
        installSettingsContent(in: window, model: capturedModel)
        guard let capturedModel else {
            settingsWorkspaceModelID = nil
            settingsWorkspaceObserver = nil
            return
        }
        settingsWorkspaceModelID = windowModels.first(where: { $0.value === capturedModel })?.key
        settingsWorkspaceObserver = capturedModel.$selectedProjectID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window, weak capturedModel] _ in
                guard let self, let window, window.isVisible else { return }
                self.installSettingsContent(in: window, model: capturedModel)
            }
    }

    private func installSettingsContent(in window: NSWindow, model: AppModel?) {
        let capturedModel = model
        let view = SettingsView(
            settings: settings,
            checkForUpdates: { [weak self] in self?.updateController.checkForUpdates(nil) },
            updateDetail: updateController.availability.detail,
            interruptibleTurnCount: { [weak capturedModel] in capturedModel?.interruptibleTurnCount ?? 0 },
            workspace: capturedModel?.currentProjectDirectory,
            initialSectionID: settingsSelectedSectionID,
            sectionChanged: { [weak self] sectionID in
                self?.settingsSelectedSectionID = sectionID
            }
        )
        window.contentView = NSHostingView(rootView: view.environmentObject(auth))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let rawID = menuItem.representedObject as? String,
              AppCommandRegistry.definition(for: AppCommandID(rawValue: rawID)) != nil else {
            return true
        }
        let id = AppCommandID(rawValue: rawID)
        if id == .closeContext {
            menuItem.title = keyModel()?.previewedFileURL == nil ? "Close Window" : "Close File Tab"
        }
        let availability = AppCommandRegistry.availability(
            of: id,
            in: AppCommandContext(model: keyModel(), settings: settings)
        )
        if let reason = availability.reason { menuItem.toolTip = reason }
        return availability.isEnabled
    }

    /// Reflect the current layout/appearance selection as menu checkmarks.
    private func refreshMenuStates() {
        for item in NSApp.mainMenu?.item(withTitle: "View")?.submenu?.items ?? [] {
            if let raw = item.representedObject as? String {
                let id = AppCommandID(rawValue: raw)
                if let layout = id.navigationLayout {
                    item.state = layout == settings.navigationLayout ? .on : .off
                } else if let appearance = id.appearance {
                    item.state = appearance == settings.appearance ? .on : .off
                }
            }
        }
    }

    private func installMainMenu() {
        NSApp.mainMenu = Self.makeMainMenu(
            updateTarget: nil,
            updateAction: nil,
            updateEnabled: updateController.availability.canCheck,
            updateDetail: updateController.availability.detail,
            commandTarget: self,
            commandAction: #selector(runRegisteredCommand(_:)),
            keymap: AppCommandKeymapCenter.shared.snapshot,
            dynamicMenusDelegate: self,
            saveWindowTarget: self,
            saveWindowAction: #selector(saveWindowLayout(_:)),
            currentLayout: settings.navigationLayout.rawValue,
            currentAppearance: settings.appearance.rawValue
        )
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = NSApp.mainMenu?.item(withTitle: "Help")?.submenu
    }

    /// Pure menu construction so tests can assert the exact edit/find wiring.
    /// SwiftTerm's `performFindPanelAction(_:)` requires NSMenuItem senders
    /// whose tags carry NSFindPanelAction raw values; anything else is ignored.
    static func makeMainMenu(
        updateTarget: AnyObject?,
        updateAction: Selector?,
        updateEnabled: Bool,
        updateDetail: String?,
        commandTarget: AnyObject? = nil,
        commandAction: Selector? = nil,
        keymap: AppCommandKeymapSnapshot? = nil,
        newWindowTarget: AnyObject? = nil,
        newWindowAction: Selector? = nil,
        openFolderTarget: AnyObject? = nil,
        openFolderAction: Selector? = nil,
        openFolderInNewWindowTarget: AnyObject? = nil,
        openFolderInNewWindowAction: Selector? = nil,
        reopenClosedProjectTarget: AnyObject? = nil,
        reopenClosedProjectAction: Selector? = nil,
        reopenClosedSessionTarget: AnyObject? = nil,
        reopenClosedSessionAction: Selector? = nil,
        reopenClosedFileTabTarget: AnyObject? = nil,
        reopenClosedFileTabAction: Selector? = nil,
        closeFileTabTarget: AnyObject? = nil,
        closeFileTabAction: Selector? = nil,
        newTerminalTarget: AnyObject? = nil,
        newTerminalAction: Selector? = nil,
        newAgentTarget: AnyObject? = nil,
        newAgentAction: Selector? = nil,
        newChatTarget: AnyObject? = nil,
        newChatAction: Selector? = nil,
        viewTarget: AnyObject? = nil,
        layoutAction: Selector? = nil,
        appearanceAction: Selector? = nil,
        fileTabTarget: AnyObject? = nil,
        previousFileTabAction: Selector? = nil,
        nextFileTabAction: Selector? = nil,
        fontTarget: AnyObject? = nil,
        fontIncreaseAction: Selector? = nil,
        fontDecreaseAction: Selector? = nil,
        fontResetAction: Selector? = nil,
        terminalCommandTarget: AnyObject? = nil,
        clearTerminalAction: Selector? = nil,
        scrollToLatestOutputAction: Selector? = nil,
        paneFocusTarget: AnyObject? = nil,
        focusNextPaneAction: Selector? = nil,
        focusPreviousPaneAction: Selector? = nil,
        dynamicMenusDelegate: NSMenuDelegate? = nil,
        saveWindowTarget: AnyObject? = nil,
        saveWindowAction: Selector? = nil,
        currentLayout: String = NavigationLayout.leftTree.rawValue,
        currentAppearance: String = AppearanceMode.system.rawValue
    ) -> NSMenu {
        let effectiveKeymap = keymap ?? AppCommandKeymapSnapshot(
            effectiveShortcuts: AppCommandKeymapStore.defaultShortcuts(
                definitions: AppCommandRegistry.keymapDefinitions
            ),
            status: .defaults,
            fileExists: false
        )

        @discardableResult
        func addRegisteredItem(
            to menu: NSMenu,
            id: AppCommandID,
            title: String? = nil,
            fallbackTarget: AnyObject?,
            fallbackAction: Selector?
        ) -> NSMenuItem {
            let definition = AppCommandRegistry.definition(for: id)
            let shortcut = effectiveKeymap.shortcut(for: id)
            let item = menu.addItem(
                withTitle: title ?? definition?.title ?? id.rawValue,
                action: commandAction ?? fallbackAction,
                keyEquivalent: shortcut?.appKitKeyEquivalent ?? ""
            )
            if let shortcut { item.keyEquivalentModifierMask = shortcut.appKitModifiers }
            item.target = commandAction == nil ? fallbackTarget : commandTarget
            item.representedObject = id.rawValue
            return item
        }

        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.title = "Kaisola"
        mainMenu.addItem(applicationItem)

        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "About Kaisola",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let updateItem = addRegisteredItem(
            to: applicationMenu,
            id: .checkForUpdates,
            fallbackTarget: updateTarget,
            fallbackAction: updateAction
        )
        updateItem.isEnabled = updateEnabled
        updateItem.toolTip = updateDetail
        applicationMenu.addItem(.separator())
        _ = addRegisteredItem(
            to: applicationMenu,
            id: .openSettings,
            fallbackTarget: nil,
            fallbackAction: #selector(KaisolaMacAppDelegate.openSettings(_:))
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Hide Kaisola",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Quit Kaisola",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu

        let fileItem = NSMenuItem()
        fileItem.title = "File"
        let fileMenu = NSMenu(title: "File")
        if commandAction != nil || newWindowAction != nil {
            addRegisteredItem(
                to: fileMenu,
                id: .newWindow,
                fallbackTarget: newWindowTarget,
                fallbackAction: newWindowAction
            )
            fileMenu.addItem(.separator())
        }
        if commandAction != nil || openFolderAction != nil {
            addRegisteredItem(
                to: fileMenu,
                id: .openProject,
                fallbackTarget: openFolderTarget,
                fallbackAction: openFolderAction
            )
        }
        if commandAction != nil || openFolderInNewWindowAction != nil {
            addRegisteredItem(
                to: fileMenu,
                id: .openProjectInNewWindow,
                fallbackTarget: openFolderInNewWindowTarget,
                fallbackAction: openFolderInNewWindowAction
            )
        }
        if let dynamicMenusDelegate {
            let recentItem = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
            let recentMenu = NSMenu(title: "Open Recent")
            recentMenu.delegate = dynamicMenusDelegate
            recentItem.submenu = recentMenu
        }
        if commandAction != nil || reopenClosedFileTabAction != nil {
            addRegisteredItem(
                to: fileMenu,
                id: .reopenClosedFileTab,
                fallbackTarget: reopenClosedFileTabTarget,
                fallbackAction: reopenClosedFileTabAction
            )
        }
        if commandAction != nil || reopenClosedProjectAction != nil {
            addRegisteredItem(
                to: fileMenu,
                id: .reopenClosedProject,
                fallbackTarget: reopenClosedProjectTarget,
                fallbackAction: reopenClosedProjectAction
            )
        }
        if commandAction != nil || reopenClosedSessionAction != nil {
            addRegisteredItem(
                to: fileMenu,
                id: .reopenClosedSession,
                fallbackTarget: reopenClosedSessionTarget,
                fallbackAction: reopenClosedSessionAction
            )
        }
        if commandAction != nil || closeFileTabAction != nil {
            fileMenu.addItem(.separator())
            addRegisteredItem(
                to: fileMenu,
                id: .closeContext,
                title: "Close File Tab",
                fallbackTarget: closeFileTabTarget,
                fallbackAction: closeFileTabAction
            )
            addRegisteredItem(
                to: fileMenu,
                id: .closeWindow,
                fallbackTarget: nil,
                fallbackAction: #selector(NSWindow.performClose(_:))
            )
        }
        if commandAction != nil || openFolderAction != nil || openFolderInNewWindowAction != nil
            || reopenClosedFileTabAction != nil || reopenClosedProjectAction != nil
            || reopenClosedSessionAction != nil {
            fileMenu.addItem(.separator())
        }
        if commandAction != nil || newChatAction != nil {
            let chatItem = fileMenu.addItem(withTitle: "New Chat", action: nil, keyEquivalent: "")
            let chatMenu = NSMenu(title: "New Chat")
            for agent in AgentRegistry.all where AcpAdapter.forAgent(agent.id) != nil {
                addRegisteredItem(
                    to: chatMenu,
                    id: .newChat(agent.id),
                    fallbackTarget: newChatTarget,
                    fallbackAction: newChatAction
                )
            }
            chatItem.submenu = chatMenu
            fileMenu.addItem(.separator())
        }
        addRegisteredItem(
            to: fileMenu,
            id: .newTerminal,
            fallbackTarget: newTerminalTarget,
            fallbackAction: newTerminalAction
        )
        if commandAction != nil || newAgentAction != nil {
            let agentItem = fileMenu.addItem(withTitle: "New Agent Session", action: nil, keyEquivalent: "")
            let agentMenu = NSMenu(title: "New Agent Session")
            for agent in AgentRegistry.all {
                addRegisteredItem(
                    to: agentMenu,
                    id: .newAgent(agent.id),
                    title: agent.name,
                    fallbackTarget: newAgentTarget,
                    fallbackAction: newAgentAction
                )
            }
            agentItem.submenu = agentMenu
        }
        if commandAction != nil {
            let meshItem = fileMenu.addItem(withTitle: "New Mesh", action: nil, keyEquivalent: "")
            let meshMenu = NSMenu(title: "New Mesh")
            for id in [AppCommandID.newMesh, .newStagedMesh, .newIdeaMesh] {
                addRegisteredItem(
                    to: meshMenu,
                    id: id,
                    fallbackTarget: nil,
                    fallbackAction: nil
                )
            }
            meshItem.submenu = meshMenu
        }
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Keep the standard text-system commands on the responder chain. The
        // whole-file Markdown editor has a native UndoManager, but Command-Z
        // is dispatched through the main menu on macOS; omitting these items
        // made undo/redo unreachable in the real app even though direct unit
        // tests of the text view's undo manager passed.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        // AppKit resolves Command-V through the main menu before it reaches the
        // first responder. Without an explicit Paste item, SwiftTerm's
        // bracket-aware `paste(_:)` is never invoked — ordinary text fields may
        // still paste through SwiftUI, which made this look specific to agent
        // CLIs such as Codex. Keep the target nil so the action follows the
        // responder chain to the active owned terminal (or any normal editor).
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())

        let findAction = #selector(NSTextView.performFindPanelAction(_:))
        let find = editMenu.addItem(withTitle: "Find…", action: findAction, keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let findNext = editMenu.addItem(withTitle: "Find Next", action: findAction, keyEquivalent: "g")
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        let findPrevious = editMenu.addItem(withTitle: "Find Previous", action: findAction, keyEquivalent: "G")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        findPrevious.tag = Int(NSFindPanelAction.previous.rawValue)
        let useSelection = editMenu.addItem(withTitle: "Use Selection for Find", action: findAction, keyEquivalent: "e")
        useSelection.tag = Int(NSFindPanelAction.setFindString.rawValue)

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        if commandAction != nil || (layoutAction != nil && appearanceAction != nil) {
            let viewItem = NSMenuItem()
            viewItem.title = "View"
            let viewMenu = NSMenu(title: "View")
            viewMenu.addItem(sectionHeader("Navigation Layout"))
            for layout in NavigationLayout.allCases {
                let item = addRegisteredItem(
                    to: viewMenu,
                    id: .navigationLayout(layout),
                    title: layout.title,
                    fallbackTarget: viewTarget,
                    fallbackAction: layoutAction
                )
                item.state = layout.rawValue == currentLayout ? .on : .off
            }
            viewMenu.addItem(.separator())
            viewMenu.addItem(sectionHeader("Appearance"))
            for mode in AppearanceMode.allCases {
                let item = addRegisteredItem(
                    to: viewMenu,
                    id: .appearance(mode),
                    title: mode.title,
                    fallbackTarget: viewTarget,
                    fallbackAction: appearanceAction
                )
                item.state = mode.rawValue == currentAppearance ? .on : .off
            }
            if commandAction != nil {
                viewMenu.addItem(.separator())
                viewMenu.addItem(sectionHeader("Workspace"))
                for id in [
                    AppCommandID.commandPalette,
                    .messageCurrentAgent,
                    .toggleFiles,
                    .toggleDocumentPreview,
                    .openExternalEditor,
                ] {
                    addRegisteredItem(
                        to: viewMenu,
                        id: id,
                        fallbackTarget: nil,
                        fallbackAction: nil
                    )
                }
            }
            if commandAction != nil || (previousFileTabAction != nil && nextFileTabAction != nil) {
                viewMenu.addItem(.separator())
                viewMenu.addItem(sectionHeader("Editor Tabs"))
                addRegisteredItem(
                    to: viewMenu,
                    id: .previousFileTab,
                    fallbackTarget: fileTabTarget,
                    fallbackAction: previousFileTabAction
                )
                addRegisteredItem(
                    to: viewMenu,
                    id: .nextFileTab,
                    fallbackTarget: fileTabTarget,
                    fallbackAction: nextFileTabAction
                )
            }
            if commandAction != nil
                || (fontIncreaseAction != nil && fontDecreaseAction != nil && fontResetAction != nil) {
                viewMenu.addItem(.separator())
                viewMenu.addItem(sectionHeader("Terminal Font"))
                addRegisteredItem(
                    to: viewMenu,
                    id: .increaseTerminalFont,
                    fallbackTarget: fontTarget,
                    fallbackAction: fontIncreaseAction
                )
                addRegisteredItem(
                    to: viewMenu,
                    id: .decreaseTerminalFont,
                    fallbackTarget: fontTarget,
                    fallbackAction: fontDecreaseAction
                )
                addRegisteredItem(
                    to: viewMenu,
                    id: .resetTerminalFont,
                    fallbackTarget: fontTarget,
                    fallbackAction: fontResetAction
                )
            }
            if commandAction != nil
                || (clearTerminalAction != nil && scrollToLatestOutputAction != nil) {
                viewMenu.addItem(.separator())
                viewMenu.addItem(sectionHeader("Terminal"))
                let clear = addRegisteredItem(
                    to: viewMenu,
                    id: .clearTerminal,
                    fallbackTarget: terminalCommandTarget,
                    fallbackAction: clearTerminalAction
                )
                clear.toolTip = "Clears this terminal's visible output and scroll buffer. Retained history stays available in the transcript."
                addRegisteredItem(
                    to: viewMenu,
                    id: .scrollTerminalToLatest,
                    fallbackTarget: terminalCommandTarget,
                    fallbackAction: scrollToLatestOutputAction
                )
            }
            if commandAction != nil
                || (focusNextPaneAction != nil && focusPreviousPaneAction != nil) {
                viewMenu.addItem(.separator())
                viewMenu.addItem(sectionHeader("Focus"))
                addRegisteredItem(
                    to: viewMenu,
                    id: .focusPreviousPane,
                    fallbackTarget: paneFocusTarget,
                    fallbackAction: focusPreviousPaneAction
                )
                addRegisteredItem(
                    to: viewMenu,
                    id: .focusNextPane,
                    fallbackTarget: paneFocusTarget,
                    fallbackAction: focusNextPaneAction
                )
            }
            viewItem.submenu = viewMenu
            mainMenu.addItem(viewItem)
        }

        // Standard Window menu (NSApp.windowsMenu appends the live window list).
        let windowItem = NSMenuItem()
        windowItem.title = "Window"
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        if let saveWindowAction {
            windowMenu.addItem(.separator())
            let save = windowMenu.addItem(withTitle: "Save Window Layout…", action: saveWindowAction, keyEquivalent: "")
            save.target = saveWindowTarget
            if let dynamicMenusDelegate {
                let savedItem = windowMenu.addItem(withTitle: "Saved Windows", action: nil, keyEquivalent: "")
                let savedMenu = NSMenu(title: "Saved Windows")
                savedMenu.delegate = dynamicMenusDelegate
                savedItem.submenu = savedMenu
            }
        }
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        // Help menu. This used to open the native-migration roadmap, which is
        // a document for people building Kaisola, not people using it.
        let helpItem = NSMenuItem()
        helpItem.title = "Help"
        let helpMenu = NSMenu(title: "Help")
        addRegisteredItem(
            to: helpMenu,
            id: .openHelp,
            fallbackTarget: nil,
            fallbackAction: #selector(KaisolaMacAppDelegate.openHelp(_:))
        )
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        return mainMenu
    }

    nonisolated static let userHelpURL = URL(
        string: "https://github.com/michaelofengenden/kaisola/blob/main/docs/user-guide.md"
    )

    @objc func openHelp(_ sender: Any?) {
        if let url = Self.userHelpURL {
            NSWorkspace.shared.open(url)
        }
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

enum NativeVisualCaptureTarget {
    @MainActor
    static func window(rootedAt root: NSWindow, surface: String) -> NSWindow? {
        surface == "terminal-transcript" || surface == "account-picker"
            || surface == "workspace-rename" || surface == "workspace-new-file"
            ? root.attachedSheet
            : root
    }
}

/// A pixel-perfect fixture can still be unusable to VoiceOver if its custom
/// terminal view exposes the raw PTY stream. Gate the real, laid-out AppKit
/// surface before capture: ordinary terminal fixtures must contain their
/// expected visible text, remain inside the public accessibility bound, and
/// contain no C0/C1 terminal controls. Returning a failure suppresses the PNG,
/// so the existing visual workflow fails rather than accepting pixels alone.
@MainActor
enum NativeVisualTerminalAccessibilityGate {
    static func expectedMarkers(for surface: String) -> [String]? {
        switch surface {
        case "terminal", "terminal-solo":
            return ["Last login:", "git status --short"]
        case "terminal-semantic":
            return ["swift test", "Test Suite 'KaisolaTests' passed", "git status --short"]
        case "terminal-scroll-output":
            return ["historical-anchor-"]
        default:
            return nil
        }
    }

    static func failure(
        in value: String,
        expectedMarkers: [String]
    ) -> String? {
        if value.isEmpty { return "empty-value" }
        if value.count > ReadOnlyTerminalView.accessibilityTailLimit {
            return "over-limit-\(value.count)"
        }
        if value.unicodeScalars.contains(where: isForbiddenControl) {
            return "terminal-control-scalar"
        }
        if let missing = expectedMarkers.first(where: { !value.contains($0) }) {
            return "missing-marker-\(missing.replacingOccurrences(of: " ", with: "_"))"
        }
        return nil
    }

    private static func isForbiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D:
            return false
        case 0x00 ... 0x1F, 0x7F ... 0x9F:
            return true
        default:
            return false
        }
    }
}

enum NativeVisualCapture {
    struct PixelSize: Equatable {
        let width: Int
        let height: Int
    }

    struct ViewSnapshot {
        let image: CGImage
        let screenFrame: CGRect
    }

    static func pixelSize(contentRect: CGRect, pointPixelScale: CGFloat) -> PixelSize {
        PixelSize(
            width: max(1, Int(ceil(contentRect.width * pointPixelScale))),
            height: max(1, Int(ceil(contentRect.height * pointPixelScale)))
        )
    }

    static func cropRect(
        imageSize: CGSize,
        parentFrame: CGRect,
        childFrame: CGRect
    ) -> CGRect? {
        guard imageSize.width > 0,
              imageSize.height > 0,
              parentFrame.width > 0,
              parentFrame.height > 0,
              childFrame.width > 0,
              childFrame.height > 0 else { return nil }

        let scaleX = imageSize.width / parentFrame.width
        let scaleY = imageSize.height / parentFrame.height
        let raw = CGRect(
            x: (childFrame.minX - parentFrame.minX) * scaleX,
            y: (parentFrame.maxY - childFrame.maxY) * scaleY,
            width: childFrame.width * scaleX,
            height: childFrame.height * scaleY
        )
        let outward = CGRect(
            x: floor(raw.minX),
            y: floor(raw.minY),
            width: ceil(raw.maxX) - floor(raw.minX),
            height: ceil(raw.maxY) - floor(raw.minY)
        )
        let bounded = outward.intersection(CGRect(origin: .zero, size: imageSize))
        return bounded.isNull || bounded.isEmpty ? nil : bounded
    }

    static func croppedImage(
        _ image: CGImage,
        parentFrame: CGRect,
        childFrame: CGRect
    ) -> CGImage? {
        guard let rect = cropRect(
            imageSize: CGSize(width: image.width, height: image.height),
            parentFrame: parentFrame,
            childFrame: childFrame
        ) else { return nil }
        return image.cropping(to: rect)
    }

    static func overlayRect(
        imageSize: CGSize,
        baseScreenFrame: CGRect,
        overlayScreenFrame: CGRect
    ) -> CGRect? {
        guard imageSize.width > 0,
              imageSize.height > 0,
              baseScreenFrame.width > 0,
              baseScreenFrame.height > 0,
              overlayScreenFrame.width > 0,
              overlayScreenFrame.height > 0 else { return nil }

        let scaleX = imageSize.width / baseScreenFrame.width
        let scaleY = imageSize.height / baseScreenFrame.height
        let raw = CGRect(
            x: (overlayScreenFrame.minX - baseScreenFrame.minX) * scaleX,
            y: (overlayScreenFrame.minY - baseScreenFrame.minY) * scaleY,
            width: overlayScreenFrame.width * scaleX,
            height: overlayScreenFrame.height * scaleY
        )
        let outward = CGRect(
            x: floor(raw.minX),
            y: floor(raw.minY),
            width: ceil(raw.maxX) - floor(raw.minX),
            height: ceil(raw.maxY) - floor(raw.minY)
        )
        let bounded = outward.intersection(CGRect(origin: .zero, size: imageSize))
        return bounded.isNull || bounded.isEmpty ? nil : bounded
    }

    static func compositedImage(
        base: CGImage,
        baseScreenFrame: CGRect,
        snapshot: ViewSnapshot
    ) -> CGImage? {
        let imageSize = CGSize(width: base.width, height: base.height)
        guard let destination = overlayRect(
            imageSize: imageSize,
            baseScreenFrame: baseScreenFrame,
            overlayScreenFrame: snapshot.screenFrame
        ) else { return nil }

        let colorSpace = base.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: base.width,
            height: base.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(base, in: CGRect(origin: .zero, size: imageSize))
        context.draw(snapshot.image, in: destination)
        return context.makeImage()
    }

    static func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        )
    }

    /// ScreenCaptureKit's current-process catalog is deliberately used here:
    /// visual fixtures only capture Kaisola's own window or attached sheet, so
    /// they do not need a screen-recording consent prompt. macOS 14.0-14.3
    /// retain the AppKit view-cache path in `scheduleVisualCapture`.
    @available(macOS 14.4, *)
    static func image(
        windowNumber: Int,
        includeChildWindows: Bool
    ) async throws -> CGImage? {
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: {
            $0.windowID == CGWindowID(windowNumber)
        }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = pixelSize(
            contentRect: filter.contentRect,
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.includeChildWindows = includeChildWindows
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}
