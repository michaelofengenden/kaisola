import AppKit
import Combine
import Darwin
import KaisolaCore
import KaisolaSessionBrokerCore
import QuartzCore
import ScreenCaptureKit
import Security
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
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

/// The visible workspace surface that owns Edit > Find. AppKit's ordinary
/// responder chain is retained for real file editors, but a hidden retained
/// editor cannot outrank the pane the workspace model says is focused.
enum WorkspaceFindSurfaceTarget: Equatable {
    case nativeFileResponder
    case chat(String)
    case terminal(String)
    case responderChain
}

@MainActor
enum WorkspaceFindSurfaceResolver {
    private static var fileAccessibilityLabels: Set<String> {
        ["File contents", "Markdown document", "Source editor"]
    }

    static func resolve(
        focusedPaneID: String?,
        chatIDs: Set<String>,
        terminalIDs: Set<String>,
        hasVisibleFileResponder: Bool
    ) -> WorkspaceFindSurfaceTarget {
        if hasVisibleFileResponder { return .nativeFileResponder }
        guard let focusedPaneID else { return .responderChain }
        if chatIDs.contains(focusedPaneID) { return .chat(focusedPaneID) }
        if terminalIDs.contains(focusedPaneID) { return .terminal(focusedPaneID) }
        return .responderChain
    }

    /// A file editor has to be mounted, visible through every ancestor, and in
    /// the target window. The labels are the existing inspectable contracts of
    /// the TextKit readers/editors and the networkless CodeMirror web view.
    static func isVisibleFileResponder(_ responder: NSResponder?, in window: NSWindow?) -> Bool {
        guard let window, let view = responder as? NSView, view.window === window else {
            return false
        }
        var isFileSurface = false
        var candidate: NSView? = view
        while let current = candidate {
            guard !current.isHidden else { return false }
            if current is MarkdownNativeTextView { isFileSurface = true }
            if let label = current.accessibilityLabel(), fileAccessibilityLabels.contains(label) {
                isFileSurface = true
            }
            candidate = current.superview
        }
        return isFileSurface
    }

    static func isFindBarResponder(_ responder: NSResponder?, in window: NSWindow?) -> Bool {
        guard let window, let view = responder as? NSView, view.window === window else {
            return false
        }
        var belongsToFindBar = false
        var candidate: NSView? = view
        while let current = candidate {
            guard !current.isHidden else { return false }
            let name = String(describing: type(of: current)).lowercased()
            if name.contains("find") && name.contains("bar") { belongsToFindBar = true }
            candidate = current.superview
        }
        return belongsToFindBar
    }
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

/// The workspace window's SwiftUI root: resolves the 2026-08-28 shell preview
/// once per render — `KAISOLA_SHELL_PREVIEW_TABS` over the persisted setting
/// — injects it as `\.shellPreview` for every preview-gated view in the
/// window, and applies decision 4's real window shape.
///
/// Observing the settings object here is what makes the Settings picker apply
/// live: the window is created once, but this view re-renders on every
/// settings publish, so flipping the preview re-clips and re-injects without
/// a relaunch.
///
/// The corner itself: the window already runs a transparent titlebar over a
/// full-size, clear-backed content view, so clipping the root container at
/// the shell's 30pt continuous corner makes the corner the window's own — the
/// pixels outside the curve are genuinely transparent, not painted over the
/// system corner. With the preview off the radius is zero: a bounds-rect clip
/// that changes nothing, leaving the shipped system corner. Known preview
/// limits, named honestly: full screen and split view still need their own
/// fixture pass before the corner ships by default.
struct ShellPreviewWindowRoot: View {
    @ObservedObject var settings: NativePreviewSettings
    let content: AnyView

    var body: some View {
        let preview = ShellPreviewVariant.resolved(
            environment: ProcessInfo.processInfo.environment,
            setting: settings.shellPreviewVariant
        )
        content
            .clipShape(
                RoundedRectangle(
                    cornerRadius: preview.windowCornerRadius,
                    style: .continuous
                )
            )
            .environment(\.shellPreview, preview)
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

enum NativeTerminalHistoryFrameCadence {
    static let environmentKey = "KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE"
    static let workloadID = "terminal-history-sustained-12-surface-v1"
    static let receiptPrefix = "KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE="

    static func encodeReceipt(
        report: NativeFrameCadenceReport,
        appPID: Int32,
        brokerPID: Int32,
        capturedAt: String
    ) throws -> Data {
        guard report.workload == workloadID,
              appPID > 1,
              brokerPID > 1,
              !capturedAt.isEmpty,
              let encoded = try? JSONEncoder().encode(report),
              let object = try? JSONSerialization.jsonObject(with: encoded),
              var receipt = object as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        receipt["appPid"] = appPID
        receipt["brokerPid"] = brokerPID
        receipt["capturedAt"] = capturedAt
        return try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
    }
}

/// A request-gated, view-bound main-run-loop cadence probe. Instruments remains
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

/// Machine-readable acceptance contract emitted only by the isolated,
/// optimized continuous-terminal-scroll visual fixture.
struct VisualTerminalContinuousScrollReceipt: Codable, Equatable, Sendable {
    static let maximumP95Milliseconds = 25.0

    let optimizedBuild: Bool
    let scheduledHertz: Int
    let measuredHertz: Double
    let sampleCount: Int
    let sampleIntervalCount: Int
    let sampleTimestampsMilliseconds: [Double]
    let sampleDurationMilliseconds: Double
    let cadenceP95Milliseconds: Double
    let handledSampleCount: Int
    let momentumSampleCount: Int
    let distinctOriginCount: Int
    let maximumAnchorStep: Int
    let maximumContinuityError: Double
    let processingP95Milliseconds: Double
    let scrollbarMaximumError: Double
    let topRubberBand: Bool
    let bottomRubberBand: Bool
    let edgesSettled: Bool
    let selectionPreserved: Bool
    let linkPreserved: Bool
    let semanticPromptPreserved: Bool
    let promptNavigationCoherent: Bool
    let keyboardPagingCoherent: Bool
    let accessibilityPagingCoherent: Bool
    let accessibilityActionsExposed: Bool
    let scrollerFramePreserved: Bool
    let alternateScreenPreserved: Bool
    let appMouseRoutingPreserved: Bool
    let liveBottomCoherent: Bool
    let viewIdentityPreserved: Bool
    let coordinatorIdentityPreserved: Bool
    let terminalEngineIdentityPreserved: Bool
    let finalFractionalViewport: Bool
    let fixtureUpdaterDisabled: Bool
    let fixtureBrokerIsolated: Bool
    let fixtureBuildNumber: Int
    let feedBuildFloor: Int
    let cursorBefore: Int64
    let cursorAfter: Int64
    let expectedCursorAfter: Int64
    let finalMarkerPresent: Bool

    var failure: String? {
        if !optimizedBuild { return "not-optimized" }
        if scheduledHertz != 120 { return "wrong-scheduled-hertz-\(scheduledHertz)" }
        if sampleCount != 120 { return "wrong-sample-count-\(sampleCount)" }
        if sampleIntervalCount != sampleCount - 1 {
            return "wrong-interval-count-\(sampleIntervalCount)"
        }
        if sampleTimestampsMilliseconds.count != sampleCount {
            return "wrong-timestamp-count-\(sampleTimestampsMilliseconds.count)"
        }
        if sampleTimestampsMilliseconds.contains(where: { !$0.isFinite }) {
            return "timestamp-not-finite"
        }
        if sampleTimestampsMilliseconds.first.map({ abs($0) > 0.001 }) ?? true {
            return "timestamp-origin-invalid"
        }
        if zip(
            sampleTimestampsMilliseconds.dropFirst(),
            sampleTimestampsMilliseconds
        ).contains(where: { !$0.0.isFinite || $0.0 <= $0.1 }) {
            return "timestamps-not-monotonic"
        }
        if let timestampDuration = sampleTimestampsMilliseconds.last,
           abs(timestampDuration - sampleDurationMilliseconds) > 0.001 {
            return "timestamp-duration-drift-\(timestampDuration)-\(sampleDurationMilliseconds)"
        }
        if !(80...145).contains(measuredHertz) {
            return "measured-cadence-out-of-range-\(measuredHertz)"
        }
        if !(800...1_600).contains(sampleDurationMilliseconds) {
            return "sample-duration-out-of-range-\(sampleDurationMilliseconds)"
        }
        if cadenceP95Milliseconds > Self.maximumP95Milliseconds {
            return "cadence-p95-out-of-range-\(cadenceP95Milliseconds)"
        }
        if handledSampleCount != sampleCount { return "sample-not-handled-\(handledSampleCount)" }
        if momentumSampleCount != 48 { return "wrong-momentum-count-\(momentumSampleCount)" }
        if distinctOriginCount < 115 { return "origins-quantized-\(distinctOriginCount)" }
        if maximumAnchorStep > 1 { return "row-jump-\(maximumAnchorStep)" }
        if maximumContinuityError > 0.001 { return "continuity-error-\(maximumContinuityError)" }
        // Keep synchronous input-plus-render work inside the same tail budget
        // as the independently measured callback cadence. This preserves the
        // original >=80 Hz acceptance floor on hosted Macs while still
        // rejecting a p95 stall beyond 25 ms.
        if processingP95Milliseconds > Self.maximumP95Milliseconds {
            return "processing-over-budget-\(processingP95Milliseconds)"
        }
        if scrollbarMaximumError > 0.000_001 { return "scrollbar-drift-\(scrollbarMaximumError)" }
        if !topRubberBand { return "no-top-rubber-band" }
        if !bottomRubberBand { return "no-bottom-rubber-band" }
        if !edgesSettled { return "edge-did-not-settle" }
        if !selectionPreserved { return "selection-lost" }
        if !linkPreserved { return "link-lost" }
        if !semanticPromptPreserved { return "semantic-prompt-lost" }
        if !promptNavigationCoherent { return "prompt-navigation-incoherent" }
        if !keyboardPagingCoherent { return "keyboard-paging-incoherent" }
        if !accessibilityPagingCoherent { return "accessibility-paging-incoherent" }
        if !accessibilityActionsExposed { return "accessibility-actions-missing" }
        if !scrollerFramePreserved { return "scroller-frame-moved" }
        if !alternateScreenPreserved { return "alternate-screen-routing-changed" }
        if !appMouseRoutingPreserved { return "app-mouse-routing-changed" }
        if !liveBottomCoherent { return "live-bottom-incoherent" }
        if !viewIdentityPreserved { return "view-identity-changed" }
        if !coordinatorIdentityPreserved { return "coordinator-identity-changed" }
        if !terminalEngineIdentityPreserved { return "terminal-engine-identity-changed" }
        if !finalFractionalViewport { return "final-viewport-quantized" }
        if !fixtureUpdaterDisabled { return "fixture-updater-started" }
        if !fixtureBrokerIsolated { return "fixture-broker-route-live" }
        if fixtureBuildNumber <= feedBuildFloor {
            return "fixture-build-not-above-feed-\(fixtureBuildNumber)-\(feedBuildFloor)"
        }
        if cursorAfter != expectedCursorAfter { return "broker-cursor-drift-\(cursorAfter)-\(expectedCursorAfter)" }
        if !finalMarkerPresent { return "stream-incomplete" }
        return nil
    }

    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@main
@MainActor
enum KaisolaMacMain {
    private static let appDelegate = KaisolaMacAppDelegate()

    static func main() {
        // The in-process terminal engine re-enters this executable to perform
        // the async-signal-sensitive PTY child setup (login_tty, chdir, exec)
        // in a fresh process. This must run before AppKit or user state.
        if ProcessInfo.processInfo.arguments.dropFirst().first == "--pty-child" {
            DarwinPTYChild.run()
        }
        let environment = ProcessInfo.processInfo.environment
        if environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
            || environment["KAISOLA_NATIVE_RESOURCE_WORKLOAD"] != nil
            || environment["KAISOLA_NATIVE_PDF_PREVIEW_BUDGET"] != nil {
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
        // The layout gate judges snapshots a capture run already wrote. It only
        // reads JSON, so it runs on a headless runner with no window, no
        // display and no user state, and reports through the exit status.
        let commandArguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        if NativeVisualLayoutCommand.requestsGate(arguments: commandArguments) {
            guard let invocation = NativeVisualLayoutCommand.parse(arguments: commandArguments) else {
                FileHandle.standardError.write(Data(
                    ("KAISOLA_NATIVE_VISUAL_LAYOUT_GATE=FAIL usage: "
                        + "--visual-layout-gate <directory> | --visual-layout-self-test <directory>"
                        + " [--expectations <path>] [--review <path>]\n").utf8
                ))
                exit(2)
            }
            exit(NativeVisualLayoutCommand.run(invocation))
        }
        KaisolaProductMigration.run()
        BrokerTeardownMigration.run()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = appDelegate
        application.run()
    }
}

@MainActor
struct PreparedApplicationTerminationHooks {
    let dismissAttachedSheets: @MainActor () -> Void
    let hasBlockingPresentation: @MainActor () -> Bool
    let hasModalWindow: @MainActor () -> Bool
    let abortModal: @MainActor () -> Void
    let schedule: @MainActor (
        TimeInterval,
        @escaping @MainActor () -> Void
    ) -> Void
    let terminate: @MainActor () -> Void

    static var live: PreparedApplicationTerminationHooks {
        PreparedApplicationTerminationHooks(
            dismissAttachedSheets: {
                KaisolaMacAppDelegate.endAttachedSheets(in: NSApplication.shared)
            },
            hasBlockingPresentation: {
                UpdateInstallGateHooks.applicationHasBlockingPresentation(NSApplication.shared)
            },
            hasModalWindow: { NSApplication.shared.modalWindow != nil },
            abortModal: { NSApplication.shared.abortModal() },
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
            },
            terminate: { NSApplication.shared.terminate(nil) }
        )
    }
}

/// AppKit leaves `modalWindow` populated until a modal session has unwound,
/// even after `abortModal()`. Drive the prepared quit from one scheduled probe
/// at a time and call `terminate` only on a turn where every AppKit modal
/// boundary is already clear.
@MainActor
final class PreparedApplicationTerminationCoordinator {
    private let hooks: PreparedApplicationTerminationHooks
    private var advanceScheduled = false
    private var completed = false

    init(hooks: PreparedApplicationTerminationHooks = .live) {
        self.hooks = hooks
    }

    func attempt() {
        guard !completed else { return }
        hooks.dismissAttachedSheets()
        if hooks.hasBlockingPresentation() {
            if hooks.hasModalWindow() {
                hooks.abortModal()
            }
            guard !advanceScheduled else { return }
            advanceScheduled = true
            hooks.schedule(0.05) { [weak self] in
                guard let self else { return }
                self.advanceScheduled = false
                self.attempt()
            }
            return
        }

        completed = true
        hooks.terminate()
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
    // Installed visual/resource/PDF fixtures return before this property is
    // touched. Keeping Sparkle lazy prevents a disposable copied app from
    // checking, downloading, or installing an update before its isolated
    // launch-mode guard runs; the explicit flag also keeps those modes closed
    // if a future fixture path needs updater state before returning.
    private lazy var updateController = NativeUpdateController(
        isolatedFixture: visualFixture || resourceWorkload != nil || pdfPreviewBudgetRequested
    )

    /// The in-workspace settings sheet needs the updater's state without a
    /// delegate reference threaded through every view (spec §3c).
    static func sharedUpdateAvailabilityDetail() -> String? {
        (NSApp.delegate as? KaisolaMacAppDelegate)?.updateController.availability.detail
    }

    static func sharedCanCheckForUpdates() -> Bool {
        (NSApp.delegate as? KaisolaMacAppDelegate)?.updateController.availability.canCheck ?? false
    }

    /// Settings can be hosted either as a workspace sheet or in the standalone
    /// Command-comma window. Resolve its workspace back to the owning AppModel
    /// instead of making the editor guess which window/session is active.
    @MainActor
    static func sharedMcpOpenChatCount(in workspace: URL) -> Int {
        guard let delegate = NSApp.delegate as? KaisolaMacAppDelegate,
              let context = delegate.mcpWorkspaceContext(for: workspace) else { return 0 }
        return context.model.chats(in: context.projectID).count
    }

    /// Route the MCP affordance through the product's existing New Chat command
    /// so account selection, adapter availability, focus, and persistence stay
    /// identical to every other launch surface. Existing chats are untouched.
    @MainActor
    @discardableResult
    static func sharedStartMcpChat(agentID: String, in workspace: URL) -> Bool {
        guard let delegate = NSApp.delegate as? KaisolaMacAppDelegate,
              let context = delegate.mcpWorkspaceContext(for: workspace) else { return false }
        context.model.activateProject(id: context.projectID)
        context.window?.makeKeyAndOrderFront(nil)
        return AppCommandRegistry.execute(
            .newChat(agentID),
            in: AppCommandContext(model: context.model, settings: delegate.settings)
        )
    }

    @MainActor
    private func mcpWorkspaceContext(
        for workspace: URL
    ) -> (model: AppModel, projectID: String, window: NSWindow?)? {
        let target = workspace.standardizedFileURL
        let preferred = keyModel()
        let models = ([preferred].compactMap { $0 } + windowModels.values).reduce(into: [AppModel]()) {
            models, candidate in
            if !models.contains(where: { existing in existing === candidate }) {
                models.append(candidate)
            }
        }
        for model in models {
            guard let project = model.projects.first(where: {
                $0.directory?.standardizedFileURL == target
            }) else { continue }
            let window = NSApp.windows.first {
                windowModels[ObjectIdentifier($0)] === model
            }
            return (model, project.id, window)
        }
        return nil
    }
    // Each window is an independent workspace with its own AppModel and broker
    // observer connection — the broker's coexistence contract makes concurrent
    // observers safe. Keyed by the NSWindow so menu actions target the key one.
    private var windowModels: [ObjectIdentifier: AppModel] = [:]
    /// Remembers which native find bar a window just opened. AppKit moves first
    /// responder into the find field, whose private view is no longer a child
    /// of the document text view, so Command-G needs this scoped continuation.
    private var lastWorkspaceFindTargets: [ObjectIdentifier: WorkspaceFindSurfaceTarget] = [:]
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
    private lazy var preparedTerminationCoordinator = PreparedApplicationTerminationCoordinator()
    static let terminationDrainDeadlineNanoseconds: UInt64 = 12_000_000_000
    private var windowCounter = 0
    private var wakeObserver: NSObjectProtocol?
    private var agentsObserver: NSObjectProtocol?
    private var keymapObserver: NSObjectProtocol?
    private var commandPresentationObserver: NSObjectProtocol?
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
            guard let self else { throw CompanionTerminalControlAdapterError.unavailable }
            if active {
                guard let model = await MainActor.run(body: {
                    self.companionController(for: terminal)
                }) else {
                    throw CompanionTerminalControlAdapterError.unavailable
                }
                try await model.setCompanionControlActive(true, for: terminal)
            } else {
                let models = await MainActor.run(body: {
                    Array(self.windowModels.values)
                })
                for model in models {
                    try? await model.setCompanionControlActive(false, for: terminal)
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
    private let visualLargeText = ProcessInfo.processInfo.environment[
        "KAISOLA_NATIVE_VISUAL_LARGE_TEXT"
    ] == "1"
    /// Pixels per point the capture is written at. Unset (0) keeps whatever the
    /// host renders; `1` is the non-Retina inspection.
    private let visualCaptureScale: CGFloat = ProcessInfo.processInfo.environment[
        "KAISOLA_NATIVE_VISUAL_SCALE"
    ].flatMap { Double($0) }.map { CGFloat($0) } ?? 0
    private let pdfPreviewBudgetRequested = ProcessInfo.processInfo.environment[
        "KAISOLA_NATIVE_PDF_PREVIEW_BUDGET"
    ] != nil
    private let pdfPreviewBudget = PDFPreviewBudgetConfiguration.resolve()
    private var pdfPreviewBudgetRunner: PDFPreviewBudgetRunner?
    private let resourceWorkloadRequested = ProcessInfo.processInfo.environment[
        "KAISOLA_NATIVE_RESOURCE_WORKLOAD"
    ] != nil
    private let resourceWorkload = NativeResourceWorkloadConfiguration.resolve()
    private let resourceFrameCadenceRequested = ProcessInfo.processInfo.environment[
        "KAISOLA_NATIVE_FRAME_CADENCE"
    ] == "1"
    /// Release qualification only. Unlike the disposable resource workload,
    /// this instruments the ordinary installed workspace so a physical
    /// twelve-surface tour and its live broker share one exact app process.
    private let terminalHistoryFrameCadenceRequested = ProcessInfo.processInfo.environment[
        NativeTerminalHistoryFrameCadence.environmentKey
    ] == "1"
    private var resourceFrameCadenceProbe: NativeFrameCadenceProbe?
    private var resourceStreamHeadsTimer: Timer?
    private var visualStreamingFixtureTask: Task<Void, Never>?
    private var visualContinuousScrollReceipt: VisualTerminalContinuousScrollReceipt?
    private var visualOwnershipFlapTask: Task<Void, Never>?
    private struct ResourceTerminalReceipt {
        let terminalID: String
        let observedOffset: Int64
        let windowWidth: Int
        let windowHeight: Int
    }
    private struct VisualOwnershipSurfaceState: Equatable {
        let selectionRange: NSRange
        let topVisibleRow: Int
        let scrollPosition: Double
        let cursorX: Int
        let cursorY: Int
        let cursorStyle: String
        let linkMode: String
        let explicitLinkURL: String?
        let workingDirectory: URL?
        let followsLiveOutput: Bool
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
        !visualFixture && resourceWorkload == nil && !pdfPreviewBudgetRequested
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        !visualFixture && resourceWorkload == nil && !pdfPreviewBudgetRequested
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // XCTest injects the bundle into the real app executable. Launching a
        // normal workspace here would connect to the user's broker, restore
        // their projects, scan FileProvider folders, and spawn background git
        // probes alongside otherwise hermetic unit tests. That can both disturb
        // a live workspace and starve process-based ACP/Mesh tests. Tests create
        // every AppModel/window they need explicitly.
        guard !NotificationBridge.isRunningUnderXCTest else { return }
        // The installed PDF gate is a single private PDFKit surface. It uses
        // isolated non-persistent settings, then returns before Sparkle,
        // usage, Companion, broker, workspace, or PTY startup so the receipt
        // measures only the optimized app and PDF preview path.
        if pdfPreviewBudgetRequested {
            guard let pdfPreviewBudget else {
                print("\(PDFPreviewBudgetRunner.receiptPrefix)FAIL invalid-private-temporary-root-or-fixture")
                try? FileHandle.standardOutput.synchronize()
                NSApp.terminate(nil)
                return
            }
            do {
                try FileManager.default.createDirectory(
                    at: pdfPreviewBudget.root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                _ = chmod(pdfPreviewBudget.root.path, 0o700)
            } catch {
                print("\(PDFPreviewBudgetRunner.receiptPrefix)FAIL private-root-create")
                try? FileHandle.standardOutput.synchronize()
                NSApp.terminate(nil)
                return
            }
            let runner = PDFPreviewBudgetRunner(configuration: pdfPreviewBudget)
            pdfPreviewBudgetRunner = runner
            runner.start()
            return
        }
        // Memory pressure sheds every discretionary cache (2026-08-06 §2g).
        MemoryPressureResponder.shared.register(name: "terminal-surfaces") {
            TerminalSurfaceCache.shared.removeAll()
        }
        MemoryPressureResponder.shared.register(name: "markdown-images") {
            MarkdownLocalImageCache.shared.purge()
        }
        MemoryPressureResponder.shared.register(name: "backdrop-bakes") {
            DesktopBackdropProvider.shared.purgeBakes()
        }
        MemoryPressureResponder.shared.register(name: "project-file-index") {
            ProjectFileIndex.shared.purge()
        }
        MemoryPressureResponder.shared.start()
        // Usage stats stay fresh on their own (spec §3e): frontmost window's
        // workspace, every 5 minutes while active.
        if !visualFixture && resourceWorkload == nil {
            UsageCenter.shared.startBackgroundRefresh { [weak self] in
                self?.activeSettingsModel()?.currentProjectDirectory
            }
        }
        if resourceWorkloadRequested, resourceWorkload == nil {
            print("KAISOLA_NATIVE_RESOURCE_WORKLOAD_READY=FAIL invalid-private-temporary-root")
            NSApp.terminate(nil)
            return
        }
        if terminalHistoryFrameCadenceRequested,
           visualFixture || resourceWorkloadRequested || runtimeSmoke || linkSmoke || catalogSmoke {
            print("KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=FAIL invalid-launch-mode")
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
            settings.navigationLayout = [
                "topbar", "topbar-attention", "new-session-topbar",
                "topbar-mixed", "topbar-mixed-narrow",
            ].contains(visualSurface)
                ? .topBar
                : .leftTree
            // The two shell-revision surfaces exist to preview the redesign,
            // so they default the preview on (pill tabs); every other fixture
            // keeps the shipped shell and its existing baselines. The
            // KAISOLA_SHELL_PREVIEW_TABS override — resolved at the window
            // root — still outranks this, exactly as on a live install, so a
            // capture run can force any surface into either state.
            settings.shellPreviewVariant = [
                "topbar-mixed", "topbar-mixed-narrow",
            ].contains(visualSurface) ? .pills : .off
            settings.appearance = visualAppearance == "dark" ? .dark : .light
            settings.sidebarAppearance = .glass
            settings.workspaceBackdrop = .glass
            if visualSurface == "tinted" {
                settings.sidebarAppearance = .tinted
                settings.workspaceBackdrop = .tinted
                // A screenshot must never catch a mid-breath frame.
                settings.tintedBreathing = false
            }
            if visualSurface == "solid" {
                settings.sidebarAppearance = .solid
                settings.workspaceBackdrop = .system
            }
            // Pinned for every surface, not just tinted, so no baseline can
            // pick up a stray palette default. `.desktop` must never be the
            // fixture value: it samples the machine's wallpaper and is
            // therefore not deterministic.
            //
            // Pinned on BOTH settings objects: the delegate's instance feeds
            // the injected environment, but `FlowingTintedBackdrop` reads
            // `NativePreviewSettings.shared` directly (the same trap the
            // mixed-density pin below already sidesteps). Pinning only the
            // local instance left the palette env override silently inert.
            let fixtureTintPalette = ProcessInfo.processInfo
                .environment["KAISOLA_NATIVE_VISUAL_TINT_PALETTE"]
                .flatMap(TintPalette.init) ?? .meadow
            settings.tintPalette = fixtureTintPalette
            NativePreviewSettings.shared.tintPalette = fixtureTintPalette
            // Same discipline for intensity: Standard is every baseline's
            // value, and captures of the louder rungs opt in by env.
            let fixtureTintIntensity = ProcessInfo.processInfo
                .environment["KAISOLA_NATIVE_VISUAL_TINT_INTENSITY"]
                .flatMap(TintIntensity.init) ?? .standard
            settings.tintIntensity = fixtureTintIntensity
            NativePreviewSettings.shared.tintIntensity = fixtureTintIntensity
            // `empty-workspace` is the *idle* canvas — nothing mounted is its
            // whole definition, and a visible Files rail is a mounted surface.
            settings.workspaceRailVisible = visualSurface != "topbar" && visualSurface != "terminal-solo"
                && visualSurface != "empty-workspace" && visualSurface != "new-session"
                && visualSurface != "new-session-topbar"
                && visualSurface != "topbar-mixed" && visualSurface != "topbar-mixed-narrow"
            settings.workspaceRailWidth = 196
            // Pin both ordinary and failure-boundary document widths. The
            // fixture settings object is non-persistent, so these values can
            // never leak into the user's next production window.
            settings.filePreviewWidth = visualSurface == "preview-narrow" ? 300 : 480
            if visualSurface == "mixed-density" {
                NativePreviewSettings.shared.toolCallDensity = .compact
            }
        }
        settings.applyAppearance()
        if !visualFixture && resourceWorkload == nil {
            // The summon hotkey (⌥⌘K), armed only when the user turned it on —
            // fixtures and workloads must never claim a system-wide key.
            GlobalHotkeyCenter.shared.onSummon = { Self.summon() }
            GlobalHotkeyCenter.shared.setEnabled(settings.summonHotkeyEnabled)
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
                model.setCompanionControlFixtureActive(true, for: terminal)
            } else if ["attention-completed", "topbar-attention"].contains(visualSurface) {
                model.loadVisualCompletedAttentionFixture()
            } else if [
                "mixed", "mixed-search", "mixed-density", "permission", "chat-thinking",
                // The 2026-08-28 shell-revision previews: the same three mixed
                // sessions (terminal, agent terminal, chat) under the merged
                // session-tab bar, at the ordinary width and at a narrow one.
                "topbar-mixed", "topbar-mixed-narrow",
            ].contains(visualSurface) {
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
            } else if let mesh = NativeVisualMeshFixture.parse(visualSurface) {
                model.loadVisualMeshFixture(workspace: workspace, agentCount: mesh.agentCount)
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
        var content: AnyView
        if visualFixture, visualSurface == "onboarding" {
            UsageCenter.shared.loadVisualFixture()
            content = AnyView(OnboardingView(
                model: model,
                settings: settings,
                dismiss: {},
                openAccounts: {},
                openUpdateSettings: {}
            ))
        } else if visualFixture, SettingsWindowChrome.visualSurfaces.contains(visualSurface) {
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
            case "settings-extensions", "settings-extensions-narrow": initialSectionID = "extensions"
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
            )
            .environment(\.dynamicTypeSize, visualLargeText ? .accessibility1 : .large)
            .environmentObject(auth))
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
            && SettingsWindowChrome.visualSurfaces.contains(visualSurface)
        let visualOnboarding = visualFixture && visualSurface == "onboarding"
        let visualMesh = visualFixture ? NativeVisualMeshFixture.parse(visualSurface) : nil
        if visualMesh?.usesLargeText == true {
            // The accessibility text sizes are what actually strand a Mesh
            // column, so the large-text fixtures ask for one rather than
            // nudging the ordinary steps.
            content = AnyView(content.dynamicTypeSize(.accessibility1))
        }
        // Settings fixtures now capture a window the product can actually be
        // resized to: the minimum, or the ideal for `settings-ideal`.
        let visualSettingsSize = SettingsWindowChrome.visualContentSize(surface: visualSurface)

        // The shell-revision compression preview: the same merged-bar window,
        // narrow enough that the inactive tabs visibly give up title width.
        let visualWorkspaceWidth: CGFloat = visualSurface == "topbar-mixed-narrow" ? 820 : 1_360
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: visualSettings ? visualSettingsSize.width : (visualOnboarding ? 760 : (resourceWorkload != nil ? 1_280 : (visualMesh?.width.points ?? (visualFixture ? visualWorkspaceWidth : 1_080)))),
                height: visualSettings ? visualSettingsSize.height : (visualOnboarding ? 560 : (resourceWorkload != nil ? 800 : (visualFixture ? 860 : 700)))
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
            // The workspace window's root rides `ShellPreviewWindowRoot`,
            // which resolves the 2026-08-28 shell preview (env override over
            // the persisted setting), injects it as `\.shellPreview` for
            // every gated view below, and applies decision 4's real window
            // shape while the preview is on. Settings and onboarding keep
            // their system chrome.
            window.contentView = FullHeightWorkspaceHostingView(
                rootView: AnyView(
                    ShellPreviewWindowRoot(settings: settings, content: content)
                )
            )
        }
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        windowModels[ObjectIdentifier(window)] = model
        if terminalHistoryFrameCadenceRequested {
            startTerminalHistoryFrameCadenceProbe(in: window)
        }
        if resourceWorkload == nil {
            observeCompanionProjection(model, id: ObjectIdentifier(window))
        }
        if visualFixture, visualSurface == "terminal-scroll-output" {
            scheduleVisualTerminalStreamingFixture(in: window, model: model)
        }
        if visualFixture, visualSurface == "terminal-continuous-scroll" {
            scheduleVisualTerminalContinuousScrollFixture(in: window, model: model)
        }
        if visualFixture, visualSurface == "terminal-ownership-flap" {
            scheduleVisualTerminalOwnershipFlapFixture(in: window, model: model)
        }
        if visualFixture, visualSurface == "mixed-density" {
            scheduleVisualToolDensityFixture(in: window)
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
        // Terminals are in-process children now, so fixture isolation is
        // inherent: every PTY dies with the fixture app and no detached
        // profile state can leak into (or out of) the production root.
        return AppModel(
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
            // Terminals run in-process: the terminal engine's identity IS the
            // app's. The receipt keeps both fields so the Node gate's shape
            // stays stable across the broker removal.
            var receipt: [String: Any] = [
                "workload": configuration.workloadID,
                "appPid": ProcessInfo.processInfo.processIdentifier,
                "brokerPid": ProcessInfo.processInfo.processIdentifier,
                "brokerStartedAt": InProcessTerminalCore.shared.startedAt,
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
            let cadenceRequested = resourceFrameCadenceRequested
            // The Node gate reads terminal stream heads from a file now that
            // there is no broker to query: the first dump must exist before
            // readiness is announced, and a refresh cadence keeps the
            // after-capture read current.
            Task { @MainActor [weak self] in
                await Self.writeResourceStreamHeads(configuration: configuration)
                FileHandle.standardOutput.write(Data("KAISOLA_NATIVE_RESOURCE_WORKLOAD_READY=".utf8))
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                try? FileHandle.standardOutput.synchronize()
                self?.startResourceStreamHeadsRefresh(configuration: configuration)
                if cadenceRequested {
                    self?.startResourceFrameCadenceProbe(
                        configuration: configuration,
                        window: window
                    )
                }
            }
        } catch {
            print("KAISOLA_NATIVE_RESOURCE_WORKLOAD_READY=FAIL \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
    }

    /// `<fixture root>/stream-heads.json`: `{terminalID: {streamEpoch,
    /// endOffset}}` from the in-process engine, replacing the `broker.status`
    /// stream-head probe the frame gates used against the detached broker.
    private static func writeResourceStreamHeads(
        configuration: NativeResourceWorkloadConfiguration
    ) async {
        let snapshot = await InProcessTerminalCore.shared.store.atomicInventorySnapshot()
        let heads = Dictionary(uniqueKeysWithValues: snapshot.records.map { record in
            (record.id, ["streamEpoch": record.streamEpoch, "endOffset": record.endOffset] as [String: Any])
        })
        guard let data = try? JSONSerialization.data(
            withJSONObject: heads,
            options: [.sortedKeys]
        ) else { return }
        let destination = configuration.root.appendingPathComponent("stream-heads.json")
        try? data.write(to: destination, options: [.atomic])
    }

    private func startResourceStreamHeadsRefresh(
        configuration: NativeResourceWorkloadConfiguration
    ) {
        resourceStreamHeadsTimer?.invalidate()
        resourceStreamHeadsTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { _ in
            Task.detached(priority: .utility) {
                await Self.writeResourceStreamHeads(configuration: configuration)
            }
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

    private func startTerminalHistoryFrameCadenceProbe(in window: NSWindow) {
        guard resourceFrameCadenceProbe == nil,
              resourceWorkload == nil,
              !visualFixture,
              let contentView = window.contentView else {
            print("KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=FAIL invalid-workspace-surface")
            try? FileHandle.standardOutput.synchronize()
            return
        }
        resourceFrameCadenceProbe = NativeFrameCadenceProbe(
            view: contentView,
            workload: NativeTerminalHistoryFrameCadence.workloadID
        ) { [weak self] report in
            defer { self?.resourceFrameCadenceProbe = nil }
            guard let report else {
                print("KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=FAIL display-link-timeout")
                try? FileHandle.standardOutput.synchronize()
                return
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
            guard let payload = try? NativeTerminalHistoryFrameCadence.encodeReceipt(
                report: report,
                appPID: ProcessInfo.processInfo.processIdentifier,
                brokerPID: ProcessInfo.processInfo.processIdentifier,
                capturedAt: formatter.string(from: Date())
            ) else {
                print("KAISOLA_NATIVE_TERMINAL_HISTORY_FRAME_CADENCE=FAIL receipt-encoding")
                try? FileHandle.standardOutput.synchronize()
                return
            }
            FileHandle.standardOutput.write(
                Data(NativeTerminalHistoryFrameCadence.receiptPrefix.utf8)
            )
            FileHandle.standardOutput.write(payload)
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
            case "terminal-scroll-output", "terminal-continuous-scroll": delay = 1_800_000_000
            default: delay = 1_800_000_000
            }
            try? await Task.sleep(nanoseconds: delay)
            // The packet fixture is deliberately frame-paced through the real
            // 16 ms coalescer. A fixed capture deadline raced that bounded task
            // on loaded CI runners, cancelling it mid-stream and reporting both
            // `stream-incomplete` and `packet-rejected`. Wait for the declared
            // finite burst itself; product launches never enter this path.
            if ["terminal-scroll-output", "terminal-continuous-scroll"].contains(visualSurface),
               let streamingTask = visualStreamingFixtureTask {
                await streamingTask.value
            }
            if visualSurface == "terminal-ownership-flap",
               let ownershipFlapTask = visualOwnershipFlapTask {
                await ownershipFlapTask.value
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

            // Settings draws its own chrome under a hidden title bar, so the
            // window buttons are only safe by construction. Prove it on the
            // real, laid-out window before the PNG is written.
            if NativeVisualWindowControlGate.applies(to: visualSurface) {
                let report = NativeVisualWindowControlGate.inspect(captureWindow)
                if let failure = report.failure {
                    print(
                        "KAISOLA_NATIVE_VISUAL_WINDOW_CONTROLS=FAIL "
                            + "surface=\(visualSurface) reason=\(failure)"
                    )
                    requestVisualFixtureTermination()
                    return
                }
                print(
                    "KAISOLA_NATIVE_VISUAL_WINDOW_CONTROLS=PASS "
                        + "surface=\(visualSurface) controls=\(report.controls) "
                        + "accessibilityElements=\(report.accessibilityElements)"
                )
            }

            if visualSurface == "settings-account-recovery" {
                let size: DynamicTypeSize = visualLargeText ? .accessibility1 : .large
                let layout = AppAccountRecoveryLayout.resolve(
                    hasRecoveryNotice: true,
                    dynamicTypeSize: size
                )
                guard layout.stacksActionBelowIdentity,
                      layout.headlineLineLimit == nil,
                      layout.dynamicTypeSize == size else {
                    print(
                        "KAISOLA_NATIVE_ACCOUNT_RECOVERY_LAYOUT=FAIL "
                            + "largeText=\(visualLargeText)"
                    )
                    requestVisualFixtureTermination()
                    return
                }
                print(
                    "KAISOLA_NATIVE_ACCOUNT_RECOVERY_LAYOUT=PASS "
                        + "largeText=\(visualLargeText) verticalAction=true unclampedHeadline=true"
                )
            }

            if ["settings-extensions", "settings-extensions-narrow"].contains(visualSurface) {
                guard let model = windowModels[ObjectIdentifier(window)] else {
                    print("KAISOLA_NATIVE_EXTENSIONS_SETTINGS=FAIL no-mounted-model")
                    requestVisualFixtureTermination()
                    return
                }
                let accessibility = NativeVisualAccessibilitySnapshot.capture(from: view)
                let fixtureItems = ExtensionsSettingsFixture.items
                let receipt = NativeVisualExtensionsSettingsReceipt(
                    surface: visualSurface,
                    contentWidth: view.bounds.width,
                    contentHeight: view.bounds.height,
                    categoryCount: Set(fixtureItems.map(\.category)).count,
                    itemCount: fixtureItems.count,
                    invalidCount: fixtureItems.filter { $0.validationMessage != nil }.count,
                    accessibilityIdentifiers: accessibility.identifiers.sorted(),
                    accessibilityLabels: accessibility.labels.sorted(),
                    fixtureUpdaterDisabled: !updateController.startedUpdater,
                    fixtureBrokerIsolated: model.usesBrokerFreeFixturePreparer
                )
                guard let payload = receipt.json else {
                    print("KAISOLA_NATIVE_EXTENSIONS_SETTINGS=FAIL receipt-encoding")
                    requestVisualFixtureTermination()
                    return
                }
                FileHandle.standardOutput.write(Data("KAISOLA_NATIVE_EXTENSIONS_SETTINGS=".utf8))
                FileHandle.standardOutput.write(Data(payload.utf8))
                FileHandle.standardOutput.write(Data("\n".utf8))
                try? FileHandle.standardOutput.synchronize()
                if let failure = receipt.failure {
                    print("KAISOLA_NATIVE_EXTENSIONS_SETTINGS=FAIL \(failure)")
                    requestVisualFixtureTermination()
                    return
                }
                print("KAISOLA_NATIVE_EXTENSIONS_SETTINGS=PASS surface=\(visualSurface)")
            }

            // Mixed and Mesh both select a non-terminal pane before the view is
            // hosted. Their generation-based request must survive that mount
            // and land on the real composer field editor, or the visible focus
            // ring and keyboard target have drifted again.
            if ["mixed", "mixed-search", "mixed-density"].contains(visualSurface)
                || NativeVisualMeshFixture.parse(visualSurface) != nil {
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

            // The chooser covers a still-mounted terminal so the terminal can
            // retain its buffer and viewport. The keyboard must nevertheless
            // belong to the chooser before capture; otherwise ordinary typing
            // is delivered to the hidden shell underneath it.
            if ["new-session", "new-session-topbar"].contains(visualSurface) {
                let responder = captureWindow.firstResponder
                guard let responder,
                      !(responder is ReadOnlyTerminalView),
                      responder !== captureWindow else {
                    let name = responder.map { String(describing: type(of: $0)) } ?? "nil"
                    let receipt = "KAISOLA_NATIVE_VISUAL_NEW_SESSION_FOCUS=FAIL "
                        + "surface=\(visualSurface) responder=\(name)\n"
                    FileHandle.standardOutput.write(Data(receipt.utf8))
                    try? FileHandle.standardOutput.synchronize()
                    requestVisualFixtureTermination()
                    return
                }
                let receipt = "KAISOLA_NATIVE_VISUAL_NEW_SESSION_FOCUS=PASS "
                    + "surface=\(visualSurface) responder=\(type(of: responder))\n"
                FileHandle.standardOutput.write(Data(receipt.utf8))
                try? FileHandle.standardOutput.synchronize()
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
                    } else if visualSurface == "terminal-continuous-scroll" {
                        guard let receipt = visualContinuousScrollReceipt else {
                            print(
                                "KAISOLA_NATIVE_VISUAL_TERMINAL_CONTINUOUS_SCROLL=FAIL "
                                    + "reason=no-receipt"
                            )
                            requestVisualFixtureTermination()
                            return
                        }
                        guard let json = receipt.json else {
                            print(
                                "KAISOLA_NATIVE_VISUAL_TERMINAL_CONTINUOUS_SCROLL=FAIL "
                                    + "reason=receipt-encoding"
                            )
                            requestVisualFixtureTermination()
                            return
                        }
                        if let failure = receipt.failure {
                            print(
                                "KAISOLA_NATIVE_VISUAL_TERMINAL_CONTINUOUS_SCROLL=FAIL "
                                    + "reason=\(failure) receipt=\(json)"
                            )
                            requestVisualFixtureTermination()
                            return
                        }
                        print(
                            "KAISOLA_NATIVE_VISUAL_TERMINAL_CONTINUOUS_SCROLL=PASS "
                                + json
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
                // A cold WebContent process can finish after the fixture's
                // initial settling delay. Probe the editor's actual DOM state
                // instead of racing its JavaScript export on slower runners.
                var editorReady = false
                for attempt in 0..<50 {
                    if let ready = try? await webView.evaluateJavaScript("""
                    Boolean(
                      window.KaisolaEditor
                      && document.querySelector('.cm-editor')
                    )
                    """) as? Bool,
                       ready == true {
                        editorReady = true
                        break
                    }
                    if attempt < 49 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                guard editorReady else {
                    print("KAISOLA_NATIVE_CODE_EDITOR_VISUAL=FAIL editor-not-ready")
                    requestVisualFixtureTermination()
                    return
                }
                do {
                    let inserted = try await webView.callAsyncJavaScript(
                        "return window.KaisolaEditor.fixtureInsert(text)",
                        arguments: ["text": "    // Bridge edit verified\n"],
                        in: nil,
                        contentWorld: .page
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
                    let exception = (error as NSError).userInfo[
                        "WKJavaScriptExceptionMessage"
                    ] as? String
                    print(
                        "KAISOLA_NATIVE_CODE_EDITOR_VISUAL=FAIL "
                            + (exception ?? error.localizedDescription)
                    )
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

            let rendered: CGImage?
            if let screenCapture {
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
            } else if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                print("KAISOLA_NATIVE_VISUAL_CAPTURE_METHOD=view-cache-fallback")
                view.cacheDisplay(in: view.bounds, to: bitmap)
                rendered = bitmap.cgImage
            } else {
                rendered = nil
            }
            // A Retina host captures two pixels per point. `SCALE=1` asks for
            // the same window at one, which is the inspection a hairline, a
            // 30pt mark and a traffic-light clearance are actually decided at.
            // CI's headless WindowServer already renders near 1×, so this is a
            // no-op there and a real resample on a developer's display.
            let scaled = rendered.map { image -> CGImage in
                guard let resampled = NativeVisualCapture.rescaled(
                    image,
                    pointSize: captureWindow.frame.size,
                    pointPixelScale: visualCaptureScale
                ) else { return image }
                print(
                    "KAISOLA_NATIVE_VISUAL_CAPTURE_SCALE=\(visualCaptureScale) "
                        + "pixels=\(resampled.width)x\(resampled.height)"
                )
                return resampled
            }
            let data = scaled.flatMap {
                NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
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
            // A PNG only proves something rendered. Record the geometry the
            // screenshot cannot be checked for by eye — window-control zone,
            // accessibility inventory, app-drawn ink — beside it, and let the
            // post-capture gate judge every surface at once.
            writeVisualLayoutSnapshot(of: captureWindow, capturePath: path)
            requestVisualFixtureTermination()
        }
    }

    /// Structural evidence beside the capture. Never fails the fixture on its
    /// own: the surface still gets its PNG, and `--visual-layout-gate` decides
    /// after the whole inspection set exists, so one verdict covers every
    /// screenshot instead of aborting at the first bad one.
    private func writeVisualLayoutSnapshot(of window: NSWindow, capturePath: String) {
        guard let snapshot = NativeVisualLayoutProbe.snapshot(
            of: window,
            surface: visualSurface,
            appearance: visualAppearance
        ) else {
            print("KAISOLA_NATIVE_VISUAL_LAYOUT_SNAPSHOT=FAIL surface=\(visualSurface) reason=no-content-view")
            return
        }
        let url = NativeVisualLayoutProbe.snapshotURL(forCapturePath: capturePath)
        do {
            try NativeVisualLayoutProbe.write(snapshot, to: url)
            print(
                "KAISOLA_NATIVE_VISUAL_LAYOUT_SNAPSHOT=PASS surface=\(visualSurface) "
                    + "elements=\(snapshot.elements.count) source=\(snapshot.inventorySource) "
                    + "controls=\(snapshot.windowControls.filter { !$0.isHidden }.count) "
                    + "path=\(url.path)"
            )
        } catch {
            print(
                "KAISOLA_NATIVE_VISUAL_LAYOUT_SNAPSHOT=FAIL surface=\(visualSurface) "
                    + "reason=\(error.localizedDescription)"
            )
        }
    }

    /// `terminate(_:)` enters AppKit's synchronous termination loop. Queue it
    /// after the capture task returns so the MainActor is free to run the
    /// delegate's async teardown before replying to `.terminateLater`.
    private func requestVisualFixtureTermination() {
        visualStreamingFixtureTask?.cancel()
        visualStreamingFixtureTask = nil
        visualOwnershipFlapTask?.cancel()
        visualOwnershipFlapTask = nil
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

    /// Optimized broker-free proof for issue #277/#785. The fixture moves the
    /// real transcript clip view away from live bottom, then changes the same
    /// app-wide density setting used by Settings. AcpChatView owns the actual
    /// mounted-row capture/restoration receipts; this scheduler supplies only
    /// the deterministic height-change stimulus.
    private func scheduleVisualToolDensityFixture(in window: NSWindow) {
        Task { @MainActor [weak window] in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard let window,
                  let contentView = window.contentView,
                  let scrollView = Self.transcriptScrollView(in: contentView),
                  let documentView = scrollView.documentView else {
                print("KAISOLA_NATIVE_TRANSCRIPT_DENSITY_STIMULUS=FAIL no-mounted-transcript")
                return
            }

            scrollView.layoutSubtreeIfNeeded()
            documentView.layoutSubtreeIfNeeded()
            let clipView = scrollView.contentView
            var target = clipView.bounds
            target.origin.y = max(
                documentView.bounds.minY,
                documentView.bounds.midY - target.height / 2
            )
            target = clipView.constrainBoundsRect(target)
            clipView.scroll(to: target.origin)
            scrollView.reflectScrolledClipView(clipView)
            scrollView.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 250_000_000)

            NativePreviewSettings.shared.toolCallDensity = .detailed
            try? await Task.sleep(nanoseconds: 450_000_000)
            NativePreviewSettings.shared.toolCallDensity = .compact
            print(
                "KAISOLA_NATIVE_TRANSCRIPT_DENSITY_STIMULUS=PASS "
                    + "documentHeight=\(String(format: "%.1f", documentView.bounds.height)) "
                    + "viewportY=\(String(format: "%.1f", scrollView.documentVisibleRect.minY))"
            )
        }
    }

    private static func transcriptScrollView(in view: NSView) -> NSScrollView? {
        if let marker = view as? AcpTranscriptViewportAnchor.MarkerView,
           let scrollView = marker.enclosingScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = transcriptScrollView(in: subview) { return scrollView }
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

    /// Drive the installed optimized renderer with one deterministic second of
    /// 120 Hz sub-row input while the ordinary AppModel coalescer receives two
    /// agent packets per sample. The receipt covers interaction invariants that
    /// pixels alone cannot: momentum, edges, scroller/keyboard/AX agreement,
    /// alternate-screen routing, selection/semantic state, view identity, and
    /// the broker-style byte cursor. No broker, PTY, socket, or live app is used.
    private func scheduleVisualTerminalContinuousScrollFixture(
        in window: NSWindow,
        model: AppModel
    ) {
        visualStreamingFixtureTask?.cancel()
        visualContinuousScrollReceipt = nil
        visualStreamingFixtureTask = Task { @MainActor [weak self, weak window, weak model] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self,
                  let window,
                  let model,
                  !Task.isCancelled,
                  let contentView = window.contentView,
                  let terminal = self.firstTerminalView(in: contentView),
                  terminal.canScroll,
                  let cursorBefore = model.terminalDocument.cursor?.offset else {
                print(
                    "KAISOLA_NATIVE_VISUAL_TERMINAL_CONTINUOUS_SCROLL=FAIL "
                        + "reason=no-scrollable-terminal"
                )
                self?.requestVisualFixtureTermination()
                return
            }

            let originalIdentity = ObjectIdentifier(terminal)
            let originalCoordinatorIdentity = (terminal.terminalDelegate as? NativeTerminalSurface.Coordinator)
                .map(ObjectIdentifier.init)
            let originalTerminalEngineIdentity = ObjectIdentifier(terminal.getTerminal())
            terminal.selectAll(nil)
            let originalSelection = terminal.selectedRange()
            var processingMilliseconds: [Double] = []
            var sampleTimestamps: [TimeInterval] = []
            var distinctOrigins: Set<Int64> = []
            var handledSampleCount = 0
            var maximumAnchorStep = 0
            var maximumContinuityError: CGFloat = 0
            var scrollbarMaximumError = 0.0
            var previousAnchor: Int? = terminal.getTerminal().getTopVisibleRow()
            let scrollerFrameBefore = terminal.nativeScrollerWindowFrame
            let cadenceOrigin = ProcessInfo.processInfo.systemUptime

            for sample in 0..<120 {
                guard !Task.isCancelled else { return }
                if sample > 0 {
                    let deadline = cadenceOrigin + Double(sample) / 120
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining > 0 {
                        do {
                            try await Task.sleep(
                                nanoseconds: UInt64((remaining * 1_000_000_000).rounded())
                            )
                        } catch {
                            return
                        }
                    }
                    guard !Task.isCancelled else { return }
                }
                let gesturePhase: NSEvent.Phase
                let momentumPhase: NSEvent.Phase
                if sample < 72 {
                    gesturePhase = sample == 0 ? .began : (sample == 71 ? .ended : .changed)
                    momentumPhase = []
                } else {
                    gesturePhase = []
                    momentumPhase = sample == 72 ? .began : (sample == 119 ? .ended : .changed)
                }
                let delta: CGFloat = if sample < 72 {
                    0.42
                } else {
                    0.08 + 0.30 * CGFloat(119 - sample) / 47
                }

                TerminalScrollGestureMonitor.noteGestureForTesting(
                    view: terminal,
                    scrollingUpward: true
                )
                let started = ProcessInfo.processInfo.systemUptime
                sampleTimestamps.append(started)
                let handled = terminal.handleContinuousScroll(
                    scrollingDeltaY: delta,
                    hasPreciseScrollingDeltas: true,
                    phase: gesturePhase,
                    momentumPhase: momentumPhase,
                    routesToNativeScrollback: true
                )
                // Force the optimized AppKit renderer to consume this exact
                // invalidation before recording the processing budget.
                terminal.displayIfNeeded()
                processingMilliseconds.append(
                    (ProcessInfo.processInfo.systemUptime - started) * 1_000
                )
                if handled { handledSampleCount += 1 }
                if let projection = terminal.continuousScrollSnapshot {
                    distinctOrigins.insert(Int64((terminal.bounds.origin.y * 1_000_000).rounded()))
                    let actualAnchor = terminal.getTerminal().getTopVisibleRow()
                    let actualPresentedPosition = CGFloat(actualAnchor) * projection.rowHeight
                        - terminal.bounds.origin.y
                    maximumContinuityError = max(
                        maximumContinuityError,
                        abs(actualPresentedPosition - projection.presentedPosition)
                    )
                    scrollbarMaximumError = max(
                        scrollbarMaximumError,
                        abs(terminal.nativeScrollerValue - projection.scrollbarPosition)
                    )
                    if let previousAnchor {
                        maximumAnchorStep = max(
                            maximumAnchorStep,
                            abs(actualAnchor - previousAnchor)
                        )
                    }
                    previousAnchor = actualAnchor
                }

                for packetIndex in (sample * 2 + 1)...(sample * 2 + 2) {
                    guard model.enqueueVisualTerminalStreamingPacket(packetIndex) else {
                        print(
                            "KAISOLA_NATIVE_VISUAL_TERMINAL_CONTINUOUS_SCROLL=FAIL "
                                + "reason=packet-rejected index=\(packetIndex)"
                        )
                        requestVisualFixtureTermination()
                        return
                    }
                }
            }
            model.finishVisualTerminalStreamingBurst()
            await Task.yield()

            let selectionPreserved = terminal.selectedRange() == originalSelection
                && originalSelection.length > 0
            let semanticPromptPreserved = !terminal.semanticTracker.commands.isEmpty
            let scrollerFrameAfter = terminal.nativeScrollerWindowFrame
            let scrollerFramePreserved = if let before = scrollerFrameBefore,
                                            let after = scrollerFrameAfter {
                abs(before.origin.x - after.origin.x) <= 0.001
                    && abs(before.origin.y - after.origin.y) <= 0.001
                    && abs(before.size.width - after.size.width) <= 0.001
                    && abs(before.size.height - after.size.height) <= 0.001
            } else {
                false
            }

            terminal.prepareForDiscreteScrollInput()
            terminal.scroll(toPosition: 0)
            TerminalScrollGestureMonitor.noteGestureForTesting(
                view: terminal,
                scrollingUpward: false
            )
            let linkHandled = terminal.handleContinuousScroll(
                scrollingDeltaY: -3.25,
                hasPreciseScrollingDeltas: true,
                phase: .changed,
                momentumPhase: [],
                routesToNativeScrollback: true
            )
            let linkPreserved: Bool
            if linkHandled,
               let projection = terminal.continuousScrollSnapshot {
                let dimensions = terminal.getTerminal().getDims()
                let optimal = terminal.getOptimalFrameSize().size
                let scrollerWidth = NSScroller.scrollerWidth(
                    for: .regular,
                    scrollerStyle: terminal.scrollerStyle
                )
                let cellWidth = (optimal.width - scrollerWidth) / CGFloat(dimensions.cols)
                let point = NSPoint(
                    x: cellWidth * 10,
                    y: terminal.frame.height - projection.rowHeight * 1.5
                )
                linkPreserved = terminal.terminalLink(at: point) == "https://kaisola.app"
            } else {
                linkPreserved = false
            }

            terminal.prepareForDiscreteScrollInput()
            TerminalScrollGestureMonitor.noteGestureForTesting(view: terminal)
            terminal.scroll(toPosition: 0)
            _ = terminal.handleContinuousScroll(
                scrollingDeltaY: 32,
                hasPreciseScrollingDeltas: true,
                phase: .ended,
                momentumPhase: [],
                routesToNativeScrollback: true
            )
            let topRubberBand = terminal.continuousScrollSnapshot?.isRubberBanding == true
                && terminal.bounds.origin.y > 0
            terminal.settleContinuousScrollImmediately()
            let topSettled = terminal.bounds.origin.y == 0

            terminal.resumeLiveFollow()
            terminal.scrollToLiveBottom()
            TerminalScrollGestureMonitor.noteGestureForTesting(
                view: terminal,
                scrollingUpward: false
            )
            _ = terminal.handleContinuousScroll(
                scrollingDeltaY: -32,
                hasPreciseScrollingDeltas: true,
                phase: .ended,
                momentumPhase: [],
                routesToNativeScrollback: true
            )
            let bottomRubberBand = terminal.continuousScrollSnapshot?.isRubberBanding == true
                && terminal.bounds.origin.y < 0
            terminal.settleContinuousScrollImmediately()
            let bottomSettled = terminal.bounds.origin.y == 0
            let liveBottomCoherent = terminal.isViewportAtLiveBottom

            terminal.prepareForDiscreteScrollInput()
            terminal.feed(text: "\u{1B}[?1049h")
            terminal.reconcileContinuousViewportAfterBufferChange()
            let alternateScreenPreserved = terminal.getTerminal().isCurrentBufferAlternate
                && !terminal.handleContinuousScroll(
                    scrollingDeltaY: 3,
                    hasPreciseScrollingDeltas: true,
                    phase: .changed,
                    momentumPhase: [],
                    routesToNativeScrollback: true
                )
            terminal.feed(text: "\u{1B}[?1049l")
            terminal.reconcileContinuousViewportAfterBufferChange()

            terminal.feed(text: "\u{1B}[?1000h")
            let appMouseRoutingPreserved = !terminal.handleContinuousScroll(
                scrollingDeltaY: 3,
                hasPreciseScrollingDeltas: true,
                phase: .changed,
                momentumPhase: [],
                routesToNativeScrollback: false
            )
            terminal.feed(text: "\u{1B}[?1000l")

            terminal.resumeLiveFollow()
            terminal.scrollToLiveBottom()
            let keyboardBottom = terminal.getTerminal().getTopVisibleRow()
            TerminalScrollGestureMonitor.noteGestureForTesting(view: terminal)
            terminal.pageUp()
            let keyboardUp = terminal.getTerminal().getTopVisibleRow()
            TerminalScrollGestureMonitor.noteGestureForTesting(
                view: terminal,
                scrollingUpward: false
            )
            terminal.pageDown()
            let keyboardPagingCoherent = keyboardUp < keyboardBottom
                && terminal.getTerminal().getTopVisibleRow() > keyboardUp
                && terminal.continuousScrollSnapshot == nil

            terminal.resumeLiveFollow()
            terminal.scrollToLiveBottom()
            let accessibilityBottom = terminal.getTerminal().getTopVisibleRow()
            let accessibilityUp = terminal.accessibilityPerformDecrement()
            let accessibilityUpRow = terminal.getTerminal().getTopVisibleRow()
            let accessibilityDown = terminal.accessibilityPerformIncrement()
            let accessibilityPagingCoherent = accessibilityUp
                && accessibilityDown
                && accessibilityUpRow < accessibilityBottom
                && terminal.getTerminal().getTopVisibleRow() > accessibilityUpRow
                && terminal.continuousScrollSnapshot == nil
            let accessibilityActionNames = Set(
                terminal.accessibilityCustomActions()?.map(\.name) ?? []
            )
            let accessibilityActionsExposed = accessibilityActionNames.contains(
                "Scroll one page up"
            ) && accessibilityActionNames.contains("Scroll one page down")

            terminal.resumeLiveFollow()
            terminal.scrollToLiveBottom()
            let promptTopBefore = terminal.getTerminal().getTopVisibleRow()
            let promptNavigationCoherent = terminal.navigateSemanticPrompt(backward: true)
                && terminal.getTerminal().getTopVisibleRow() < promptTopBefore
                && terminal.continuousScrollSnapshot == nil

            terminal.prepareForDiscreteScrollInput()
            TerminalScrollGestureMonitor.noteGestureForTesting(view: terminal)
            terminal.scroll(toPosition: 0.35)
            _ = terminal.handleContinuousScroll(
                scrollingDeltaY: 3.25,
                hasPreciseScrollingDeltas: true,
                phase: .changed,
                momentumPhase: [],
                routesToNativeScrollback: true
            )
            terminal.displayIfNeeded()
            let finalProjection = terminal.continuousScrollSnapshot
            let finalFractionalViewport = finalProjection.map {
                abs($0.offsetWithinAnchor) > 0.1
                    && abs($0.offsetWithinAnchor) < $0.rowHeight - 0.1
            } ?? false

            let sortedProcessing = processingMilliseconds.sorted()
            let p95Index = max(0, Int(ceil(Double(sortedProcessing.count) * 0.95)) - 1)
            let processingP95 = sortedProcessing.indices.contains(p95Index)
                ? sortedProcessing[p95Index]
                : .infinity
            let sampleIntervals = zip(sampleTimestamps.dropFirst(), sampleTimestamps)
                .map { ($0.0 - $0.1) * 1_000 }
            let sortedSampleIntervals = sampleIntervals.sorted()
            let cadenceP95Index = max(
                0,
                Int(ceil(Double(sortedSampleIntervals.count) * 0.95)) - 1
            )
            let cadenceP95 = sortedSampleIntervals.indices.contains(cadenceP95Index)
                ? sortedSampleIntervals[cadenceP95Index]
                : .infinity
            let sampleDurationMilliseconds: Double = if let first = sampleTimestamps.first,
                                                        let last = sampleTimestamps.last {
                (last - first) * 1_000
            } else {
                Double.infinity
            }
            let measuredHertz = sampleDurationMilliseconds.isFinite
                && sampleDurationMilliseconds > 0
                ? Double(sampleIntervals.count) / (sampleDurationMilliseconds / 1_000)
                : 0
            let sampleTimestampsMilliseconds = sampleTimestamps.first.map { first in
                sampleTimestamps.map { ($0 - first) * 1_000 }
            } ?? []
            let remountedTerminal = window.contentView.flatMap {
                self.firstTerminalView(in: $0)
            }
            let viewIdentityPreserved = remountedTerminal.map {
                ObjectIdentifier($0) == originalIdentity && $0 === terminal
            } ?? false
            let coordinatorIdentityPreserved = if let remountedTerminal,
                                                   let originalCoordinatorIdentity,
                                                   let coordinator = remountedTerminal.terminalDelegate
                                                    as? NativeTerminalSurface.Coordinator {
                ObjectIdentifier(coordinator) == originalCoordinatorIdentity
            } else {
                false
            }
            let terminalEngineIdentityPreserved = remountedTerminal.map {
                ObjectIdentifier($0.getTerminal()) == originalTerminalEngineIdentity
            } ?? false
            let environment = ProcessInfo.processInfo.environment
            let fixtureBuildNumber = Int(
                Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            ) ?? -1
            let feedBuildFloor = Int(
                environment["KAISOLA_NATIVE_VISUAL_FEED_BUILD_FLOOR"] ?? ""
            ) ?? Int.max
            let expectedCursorAfter = cursorBefore + VisualTerminalStreamingFixture.packetIndices.reduce(Int64(0)) {
                $0 + Int64(VisualTerminalContinuousScrollFixture.packet(index: $1).utf8.count)
            }
            let cursorAfter = model.terminalDocument.cursor?.offset ?? -1
            let buffer = terminal.getTerminal().getBufferAsData()
            let finalMarkerPresent = String(data: buffer, encoding: .utf8)?
                .contains(VisualTerminalStreamingFixture.finalMarker) == true

            self.visualContinuousScrollReceipt = VisualTerminalContinuousScrollReceipt(
                optimizedBuild: !_isDebugAssertConfiguration(),
                scheduledHertz: 120,
                measuredHertz: measuredHertz,
                sampleCount: 120,
                sampleIntervalCount: sampleIntervals.count,
                sampleTimestampsMilliseconds: sampleTimestampsMilliseconds,
                sampleDurationMilliseconds: sampleDurationMilliseconds,
                cadenceP95Milliseconds: cadenceP95,
                handledSampleCount: handledSampleCount,
                momentumSampleCount: 48,
                distinctOriginCount: distinctOrigins.count,
                maximumAnchorStep: maximumAnchorStep,
                maximumContinuityError: Double(maximumContinuityError),
                processingP95Milliseconds: processingP95,
                scrollbarMaximumError: scrollbarMaximumError,
                topRubberBand: topRubberBand,
                bottomRubberBand: bottomRubberBand,
                edgesSettled: topSettled && bottomSettled,
                selectionPreserved: selectionPreserved,
                linkPreserved: linkPreserved,
                semanticPromptPreserved: semanticPromptPreserved,
                promptNavigationCoherent: promptNavigationCoherent,
                keyboardPagingCoherent: keyboardPagingCoherent,
                accessibilityPagingCoherent: accessibilityPagingCoherent,
                accessibilityActionsExposed: accessibilityActionsExposed,
                scrollerFramePreserved: scrollerFramePreserved,
                alternateScreenPreserved: alternateScreenPreserved,
                appMouseRoutingPreserved: appMouseRoutingPreserved,
                liveBottomCoherent: liveBottomCoherent,
                viewIdentityPreserved: viewIdentityPreserved,
                coordinatorIdentityPreserved: coordinatorIdentityPreserved,
                terminalEngineIdentityPreserved: terminalEngineIdentityPreserved,
                finalFractionalViewport: finalFractionalViewport,
                fixtureUpdaterDisabled: !self.updateController.startedUpdater,
                fixtureBrokerIsolated: model.usesBrokerFreeFixturePreparer,
                fixtureBuildNumber: fixtureBuildNumber,
                feedBuildFloor: feedBuildFloor,
                cursorBefore: cursorBefore,
                cursorAfter: cursorAfter,
                expectedCursorAfter: expectedCursorAfter,
                finalMarkerPresent: finalMarkerPresent
            )
            self.visualStreamingFixtureTask = nil
        }
    }

    /// Drive a real SwiftUI/AppKit ownership transition against the exact
    /// maximum retained transcript. This fixture is broker-free and runs only
    /// under `KAISOLA_NATIVE_VISUAL_FIXTURE=1`; its receipt proves that the
    /// mounted view/parser state never changed while input was revoked.
    private func scheduleVisualTerminalOwnershipFlapFixture(
        in window: NSWindow,
        model: AppModel
    ) {
        visualOwnershipFlapTask?.cancel()
        visualOwnershipFlapTask = Task { @MainActor [weak self, weak window, weak model] in
            guard let self, let window, let model else { return }
            let expectedBytes = TerminalDocument.maximumRetainedBytes
            let readyDeadline = ContinuousClock().now.advanced(by: .seconds(20))
            var mountedView: OwnedTerminalView?
            var mountedCoordinator: NativeTerminalSurface.Coordinator?
            while ContinuousClock().now < readyDeadline, !Task.isCancelled {
                window.displayIfNeeded()
                if let view = window.contentView.flatMap({ self.firstTerminalView(in: $0) })
                    as? OwnedTerminalView,
                   let coordinator = view.terminalDelegate
                    as? NativeTerminalSurface.Coordinator,
                   !coordinator.isProgressivelyReplaying,
                   coordinator.replayMetrics.fullReplayStarts == 1,
                   coordinator.replayMetrics.progressiveBytesFed == expectedBytes {
                    mountedView = view
                    mountedCoordinator = coordinator
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled,
                  let view = mountedView,
                  let coordinator = mountedCoordinator else {
                self.emitVisualOwnershipFlapReceipt(ok: false, reason: "surface-not-ready")
                self.requestVisualFixtureTermination()
                return
            }

            let terminal = view.getTerminal()
            guard let linkAnchor = self.visualOwnershipLinkAnchor(in: terminal) else {
                self.emitVisualOwnershipFlapReceipt(ok: false, reason: "missing-explicit-link")
                self.requestVisualFixtureTermination()
                return
            }
            view.selectAll(nil)
            TerminalScrollGestureMonitor.noteGestureForTesting(view: view)
            view.scroll(toPosition: 0.35)
            coordinator.scrolled(source: view, position: view.scrollPosition)
            let initialSelection = view.getSelection()
            let initialState = self.visualOwnershipSurfaceState(
                view: view,
                coordinator: coordinator,
                linkPosition: linkAnchor.position
            )
            let initialMetrics = coordinator.replayMetrics
            let viewIdentity = ObjectIdentifier(view)
            let coordinatorIdentity = ObjectIdentifier(coordinator)
            let terminalIdentity = ObjectIdentifier(terminal)
            let linkPresent = linkAnchor.url == VisualTerminalOwnershipFlapFixture.linkURL
                && initialState.explicitLinkURL == VisualTerminalOwnershipFlapFixture.linkURL
            guard initialSelection != nil,
                  !coordinator.isFollowingLiveOutput,
                  linkPresent,
                  initialMetrics == .init(
                    fullReplayStarts: 1,
                    scheduledProgressiveBytes: expectedBytes,
                    progressiveBytesFed: expectedBytes,
                    synchronousReplayBytes: 0
                  ) else {
                self.emitVisualOwnershipFlapReceipt(ok: false, reason: "invalid-initial-state")
                self.requestVisualFixtureTermination()
                return
            }

            var samples: [Double] = []
            var revokedPresentationObserved = true
            var stateStayedExact = true
            var scrollStayedExact = true
            var cursorStayedExact = true
            var linkStayedExact = true
            var liveFollowStayedExact = true
            let recordState: (VisualOwnershipSurfaceState) -> Void = { state in
                stateStayedExact = stateStayedExact && state == initialState
                scrollStayedExact = scrollStayedExact
                    && state.topVisibleRow == initialState.topVisibleRow
                    && state.scrollPosition == initialState.scrollPosition
                cursorStayedExact = cursorStayedExact
                    && state.cursorX == initialState.cursorX
                    && state.cursorY == initialState.cursorY
                    && state.cursorStyle == initialState.cursorStyle
                linkStayedExact = linkStayedExact
                    && state.linkMode == initialState.linkMode
                    && state.explicitLinkURL == initialState.explicitLinkURL
                liveFollowStayedExact = liveFollowStayedExact
                    && state.followsLiveOutput == initialState.followsLiveOutput
            }

            for toast in ToastCenter.shared.toasts
                where toast.message.hasSuffix(AppModel.terminalInputDiscardNoticeSuffix)
                    || toast.message == AppModel.terminalInputDiscardAggregateNotice {
                ToastCenter.shared.dismiss(toast.id)
            }
            let queuedInputSecrets = [
                "visual-stale-text-secret",
                "private visual paste",
            ]
            let queuedInputs = [
                queuedInputSecrets[0],
                "\u{1B}[A",
                "\u{1B}[200~\(queuedInputSecrets[1])\r\u{1B}[201~",
                "\r",
            ]
            for data in queuedInputs {
                model.sendInput(data, to: "visual-terminal")
            }

            var discardNoticeVisible = false
            var discardNoticeRedacted = false
            for _ in 0..<7 {
                let started = ProcessInfo.processInfo.systemUptime
                guard model.setVisualFixtureTerminalOwnership(false),
                      await self.waitForVisualTerminalAuthorization(
                        false,
                        view: view,
                        coordinator: coordinator,
                        window: window
                      ) else {
                    self.emitVisualOwnershipFlapReceipt(ok: false, reason: "revoke-timeout")
                    self.requestVisualFixtureTermination()
                    return
                }
                let discardNotices = ToastCenter.shared.toasts.filter {
                    $0.message.hasSuffix(AppModel.terminalInputDiscardNoticeSuffix)
                        || $0.message == AppModel.terminalInputDiscardAggregateNotice
                }
                discardNoticeVisible = discardNoticeVisible || discardNotices.count == 1
                discardNoticeRedacted = discardNoticeRedacted
                    || (discardNotices.count == 1 && queuedInputSecrets.allSatisfy {
                        !discardNotices[0].message.contains($0)
                    })
                revokedPresentationObserved = revokedPresentationObserved
                    && !view.allowMouseReporting
                    && view.accessibilityLabel() == "Read-only terminal output"
                recordState(self.visualOwnershipSurfaceState(
                    view: view,
                    coordinator: coordinator,
                    linkPosition: linkAnchor.position
                ))
                stateStayedExact = stateStayedExact
                    && coordinator.replayMetrics == initialMetrics

                guard model.setVisualFixtureTerminalOwnership(true),
                      await self.waitForVisualTerminalAuthorization(
                        true,
                        view: view,
                        coordinator: coordinator,
                        window: window
                      ) else {
                    self.emitVisualOwnershipFlapReceipt(ok: false, reason: "restore-timeout")
                    self.requestVisualFixtureTermination()
                    return
                }
                samples.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                recordState(self.visualOwnershipSurfaceState(
                    view: view,
                    coordinator: coordinator,
                    linkPosition: linkAnchor.position
                ))
                stateStayedExact = stateStayedExact
                    && coordinator.replayMetrics == initialMetrics
            }

            let sortedSamples = samples.sorted()
            let p95Index = max(0, Int(ceil(Double(sortedSamples.count) * 0.95)) - 1)
            let p95Milliseconds = sortedSamples[p95Index]
            let sameView = ObjectIdentifier(view) == viewIdentity
            let sameCoordinator = ObjectIdentifier(coordinator) == coordinatorIdentity
                && (view.terminalDelegate as? NativeTerminalSurface.Coordinator) === coordinator
            let sameTerminal = ObjectIdentifier(view.getTerminal()) == terminalIdentity
            let mountedViewStable = window.contentView.flatMap({ self.firstTerminalView(in: $0) }) === view
            let identitiesStable = sameView && sameCoordinator && sameTerminal && mountedViewStable
            let selectionStable = view.getSelection() == initialSelection
                && view.selectedRange() == initialState.selectionRange
            let ok = identitiesStable
                && stateStayedExact
                && selectionStable
                && revokedPresentationObserved
                && discardNoticeVisible
                && discardNoticeRedacted
                && view.isInputAuthorized
                && coordinator.replayMetrics == initialMetrics

            self.emitVisualOwnershipFlapReceipt(
                ok: ok,
                reason: ok ? nil : "state-changed",
                fields: [
                    "bytes": expectedBytes,
                    "samples": samples.count,
                    "p95Milliseconds": p95Milliseconds,
                    "sameView": sameView,
                    "sameCoordinator": sameCoordinator,
                    "sameTerminal": sameTerminal,
                    "mountedView": mountedViewStable,
                    "selectionStable": selectionStable,
                    "scrollStable": scrollStayedExact,
                    "cursorStable": cursorStayedExact,
                    "linkStable": linkPresent && linkStayedExact,
                    "liveFollowStable": liveFollowStayedExact,
                    "revokedPresentationObserved": revokedPresentationObserved,
                    "discardNoticeVisible": discardNoticeVisible,
                    "discardNoticeRedacted": discardNoticeRedacted,
                    "additionalReplayStarts": coordinator.replayMetrics.fullReplayStarts
                        - initialMetrics.fullReplayStarts,
                ]
            )
            self.visualOwnershipFlapTask = nil
            if !ok { self.requestVisualFixtureTermination() }
        }
    }

    private func waitForVisualTerminalAuthorization(
        _ expected: Bool,
        view: OwnedTerminalView,
        coordinator: NativeTerminalSurface.Coordinator,
        window: NSWindow
    ) async -> Bool {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while ContinuousClock().now < deadline, !Task.isCancelled {
            window.displayIfNeeded()
            if view.isInputAuthorized == expected,
               window.contentView.flatMap({ firstTerminalView(in: $0) }) === view,
               (view.terminalDelegate as? NativeTerminalSurface.Coordinator) === coordinator {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func visualOwnershipSurfaceState(
        view: OwnedTerminalView,
        coordinator: NativeTerminalSurface.Coordinator,
        linkPosition: Position
    ) -> VisualOwnershipSurfaceState {
        let terminal = view.getTerminal()
        let cursor = terminal.getCursorLocation()
        return VisualOwnershipSurfaceState(
            selectionRange: view.selectedRange(),
            topVisibleRow: terminal.getTopVisibleRow(),
            scrollPosition: view.scrollPosition,
            cursorX: cursor.x,
            cursorY: cursor.y,
            cursorStyle: String(describing: terminal.options.cursorStyle),
            linkMode: String(describing: view.linkHighlightMode),
            explicitLinkURL: terminal.link(
                at: .buffer(linkPosition),
                mode: .explicitOnly
            ),
            workingDirectory: coordinator.workingDirectory,
            followsLiveOutput: coordinator.isFollowingLiveOutput
        )
    }

    /// Resolve the OSC 8 fixture while it is still at live bottom, then retain
    /// its absolute buffer coordinate while the viewport scrolls away. Checking
    /// raw visible text is insufficient: a parser reset can preserve glyphs
    /// while discarding their hyperlink payload.
    private func visualOwnershipLinkAnchor(
        in terminal: Terminal
    ) -> (position: Position, url: String)? {
        let topVisibleRow = terminal.getTopVisibleRow()
        for row in stride(from: terminal.rows - 1, through: 0, by: -1) {
            for column in 0..<terminal.cols {
                let screenPosition = Position(col: column, row: row)
                guard let url = terminal.link(
                    at: .screen(screenPosition),
                    mode: .explicitOnly
                ) else { continue }
                return (
                    Position(col: column, row: topVisibleRow + row),
                    url
                )
            }
        }
        return nil
    }

    private func emitVisualOwnershipFlapReceipt(
        ok: Bool,
        reason: String?,
        fields: [String: Any] = [:]
    ) {
        var payload = fields
        payload["schemaVersion"] = 1
        payload["ok"] = ok
        if let reason { payload["reason"] = reason }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else { return }
        print(
            "KAISOLA_NATIVE_VISUAL_OWNERSHIP_FLAP="
                + String(decoding: data, as: UTF8.self)
        )
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

    /// Route Find from the visible workspace owner rather than trusting a
    /// retained hidden AppKit editor. File editors keep their native find bar,
    /// terminals keep SwiftTerm's bounded scrollback search, and ACP chats get
    /// a pane-scoped notification consumed only by that conversation view.
    @objc func routeWorkspaceFind(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let model = keyModel(),
              let window = commandWindow(for: model) else { return }
        let windowID = ObjectIdentifier(window)
        let target: WorkspaceFindSurfaceTarget
        if WorkspaceFindSurfaceResolver.isFindBarResponder(window.firstResponder, in: window),
           let continuing = lastWorkspaceFindTargets[windowID] {
            target = continuing
        } else {
            target = WorkspaceFindSurfaceResolver.resolve(
                focusedPaneID: model.focusedPaneID,
                chatIDs: Set(model.chats.map(\.id)),
                terminalIDs: Set(model.sessions.map(\.id)),
                hasVisibleFileResponder: WorkspaceFindSurfaceResolver.isVisibleFileResponder(
                    window.firstResponder,
                    in: window
                )
            )
        }

        let nativeAction = #selector(NSTextView.performFindPanelAction(_:))
        switch target {
        case .nativeFileResponder:
            _ = window.firstResponder?.tryToPerform(nativeAction, with: item)
            lastWorkspaceFindTargets[windowID] = target
        case let .chat(id):
            guard let conversation = model.chats.first(where: { $0.id == id })?.conversation else {
                return
            }
            NotificationCenter.default.post(
                name: .kaisolaTranscriptFindCommand,
                object: conversation,
                userInfo: [AcpTranscriptFindCommand.notificationActionKey: item.tag]
            )
            lastWorkspaceFindTargets[windowID] = target
        case let .terminal(id):
            guard let root = window.contentView,
                  let terminal = TerminalFocusResolver.terminal(in: root, paneID: id) else { return }
            if window.firstResponder !== terminal {
                _ = window.makeFirstResponder(terminal)
            }
            _ = terminal.tryToPerform(nativeAction, with: item)
            lastWorkspaceFindTargets[windowID] = target
        case .responderChain:
            _ = window.firstResponder?.tryToPerform(nativeAction, with: item)
            lastWorkspaceFindTargets[windowID] = nil
        }
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
        } else {
            nextAccountID = nil
        }

        // Combine delivery is wrapped in a MainActor task. A rapid A -> B
        // transition can therefore leave an older phase task queued behind the
        // newer value. Fence the captured phase against the live auth model
        // before it can reopen Account A's Companion authority.
        let currentAccountID: String?
        if case let .signedIn(account) = auth.phase {
            currentAccountID = account.uid
        } else {
            currentAccountID = nil
        }
        guard nextAccountID == currentAccountID else { return }
        if nextAccountID != nil, !visualFixture {
            UserDefaults.standard.set(
                true,
                forKey: NativeAccountKeychainMigration.completionDefaultsKey
            )
        }

        CompanionHost.shared.setActiveAccountID(nextAccountID)
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
                let accountScope = try CompanionAccountScope(
                    accountID: "native-browser-link-smoke"
                )
                let roster = try CompanionDeviceRosterStore(
                    fileURL: directory.appendingPathComponent("devices-v3.json"),
                    accountScope: accountScope
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
        if let checkForUpdatesObserver { NotificationCenter.default.removeObserver(checkForUpdatesObserver) }
        wakeObserver = nil
        agentsObserver = nil
        keymapObserver = nil
        commandPresentationObserver = nil
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
        UpdateCenter.shared.applicationTerminationDidReachDelegate()
        Self.endAttachedSheets(in: sender)
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

    /// Once AppKit has admitted a quit request, no attached sheet should be
    /// allowed to block Kaisola's prepared second request. Snapshot the pairs
    /// first because ending one sheet mutates the application's window list.
    static func endAttachedSheets(in application: NSApplication) {
        let attachedSheets = application.windows.compactMap { owner -> (NSWindow, NSWindow)? in
            guard let sheet = owner.attachedSheet else { return nil }
            return (owner, sheet)
        }
        for (owner, sheet) in attachedSheets {
            owner.endSheet(sheet)
        }
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
        preparedTerminationCoordinator.attempt()
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
        lastWorkspaceFindTargets.removeValue(forKey: id)
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
    /// The ⌥⌘K summon: bring Kaisola forward from any app and land in the
    /// last chat's composer. No panel of its own (that is a design
    /// conversation); the value is the zero-mouse arrival.
    static func summon() {
        NSApp.activate(ignoringOtherApps: true)
        guard let delegate = NSApp.delegate as? KaisolaMacAppDelegate else { return }
        let window = NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.canBecomeKey && !($0 is NSPanel) })
        guard let window else {
            _ = delegate.makeWindow()
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        guard let model = delegate.windowModels[ObjectIdentifier(window)] else { return }
        if let chatID = SummonPolicy.chatToFocus(
            selectedChatID: model.selectedChatID,
            chatIDs: model.chats.map(\.id)
        ) {
            model.selectChat(chatID)
        }
    }

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
        guard savedWindows.save(SavedWindowState(
            name: name,
            frame: NSStringFromRect(window.frame),
            projectName: model.selectedProjectName,
            projectPath: model.currentProjectDirectory?.standardizedFileURL.path
        )) else {
            ToastCenter.shared.show("Layout not saved: see Saved Windows", style: .error)
            return
        }
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
        if !savedWindows.remove(name: name) {
            ToastCenter.shared.show("Layout not deleted: see Saved Windows", style: .error)
        }
    }

    /// Explain a Saved Windows list that is short or empty, and hand back
    /// whatever this build kept aside. An unexplained gap where the user's
    /// layouts used to be is the failure this path exists to avoid, so the row
    /// that says so is always clickable.
    @objc private func showSavedWindowsNotice(_ sender: Any?) {
        guard let notice = savedWindows.load().notice else { return }
        let preservedCopy = savedWindows.preservedCopy()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = notice.title
        if let preservedCopy {
            let kept = preservedCopy.savedAt.formatted(date: .abbreviated, time: .shortened)
            alert.informativeText = notice.message
                + "\n\nKaisola kept the original data from \(kept). Export it to "
                + "recover the missing entries by hand."
            alert.addButton(withTitle: "Export Kept Copy…")
        } else {
            alert.informativeText = notice.message
        }
        alert.addButton(withTitle: "OK")
        guard let preservedCopy, alert.runModal() == .alertFirstButtonReturn else { return }
        exportSavedWindowsCopy(preservedCopy)
    }

    private func exportSavedWindowsCopy(_ copy: SavedWindowsPreservedCopy) {
        let panel = NSSavePanel()
        panel.title = "Export Kept Saved Windows"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "saved-windows-kept-copy.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try copy.payload.write(to: url, options: .atomic)
            ToastCenter.shared.show("Kept copy exported", style: .success)
        } catch {
            ToastCenter.shared.show("Export failed: \(error.localizedDescription)", style: .error)
        }
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
            let catalog = savedWindows.load()
            let states = catalog.windows
            if let notice = catalog.notice {
                // The warning replaces "No Saved Windows" when nothing decoded:
                // a damaged list must never read as a list the user emptied.
                let item = menu.addItem(
                    withTitle: notice.summary,
                    action: #selector(showSavedWindowsNotice(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                if !states.isEmpty { menu.addItem(.separator()) }
            } else if states.isEmpty {
                menu.addItem(NSMenuItem(title: "No Saved Windows", action: nil, keyEquivalent: ""))
            }
            for state in states {
                let item = menu.addItem(withTitle: state.name, action: #selector(openSavedWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = state.name
            }
            // Deleting is off while a newer build owns the list, so the submenu
            // stays out rather than offering an action that cannot land.
            if !states.isEmpty, catalog.notice?.blocksWrites != true {
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

    /// The composer's "Manage agents…" affordance lands on the exact registry
    /// inside Extensions, rather than on the built-in Agents overview.
    /// `openSettings` re-installs the content in both its branches, so setting
    /// the remembered section first is all the deep link needs.
    @objc func openAgentSettings(_ sender: Any?) {
        settingsSelectedSectionID = ExtensionsSettingsRoute(
            category: .customAgents,
            itemID: nil
        ).rawValue
        openSettings(sender)
    }

    @objc func openExtensionSettings(_ sender: Any?) {
        let candidate = sender as? String
            ?? (sender as? NSMenuItem)?.representedObject as? String
        settingsSelectedSectionID = ExtensionsSettingsRoute.parse(candidate)?.rawValue
            ?? ExtensionsSettingsRoute(category: nil, itemID: nil).rawValue
        openSettings(sender)
    }

    @objc func openMcpSettings(_ sender: Any?) {
        settingsSelectedSectionID = ExtensionsSettingsRoute(
            category: .mcpServers,
            itemID: nil
        ).rawValue
        openSettings(sender)
    }

    @objc func openTerminalThemeSettings(_ sender: Any?) {
        settingsSelectedSectionID = ExtensionsSettingsRoute(
            category: .terminalThemes,
            itemID: nil
        ).rawValue
        openSettings(sender)
    }

    @objc func openGrammarSettings(_ sender: Any?) {
        settingsSelectedSectionID = ExtensionsSettingsRoute(
            category: .languageGrammars,
            itemID: nil
        ).rawValue
        openSettings(sender)
    }

    @objc func openPreviewMappingSettings(_ sender: Any?) {
        settingsSelectedSectionID = ExtensionsSettingsRoute(
            category: .previewMappings,
            itemID: nil
        ).rawValue
        openSettings(sender)
    }

    @objc func openSettings(_ sender: Any?) {
        let model = activeSettingsModel()
        if let settingsWindow, settingsWindow.isVisible {
            bindSettingsWindow(settingsWindow, to: model)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        // Sized to the SettingsView's own contract (minWidth 820, ideal
        // 1100×800) — the old 810×540/min-760 window sat BELOW the view's
        // minimum, so first layout fought and the window opened cramped
        // (2026-08-06 spec §3a). Both sizes and the style mask now come from
        // `SettingsWindowChrome`, which is also what reserves the title-bar
        // band the traffic lights sit in and what adds the `.miniaturizable`
        // this window spent its whole life without (#306).
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: SettingsWindowChrome.idealContentSize
            ),
            styleMask: SettingsWindowChrome.styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = SettingsWindowChrome.minimumContentSize
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
            installPendingUpdate: { UpdateCenter.shared.installAndRelaunch() },
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
            findTarget: self,
            findAction: #selector(routeWorkspaceFind(_:)),
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
        findTarget: AnyObject? = nil,
        findAction: Selector? = nil,
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

        let effectiveFindAction = findAction ?? #selector(NSTextView.performFindPanelAction(_:))
        let find = editMenu.addItem(withTitle: "Find…", action: effectiveFindAction, keyEquivalent: "f")
        find.target = findTarget
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let findNext = editMenu.addItem(withTitle: "Find Next", action: effectiveFindAction, keyEquivalent: "g")
        findNext.target = findTarget
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        let findPrevious = editMenu.addItem(withTitle: "Find Previous", action: effectiveFindAction, keyEquivalent: "G")
        findPrevious.target = findTarget
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        findPrevious.tag = Int(NSFindPanelAction.previous.rawValue)
        let useSelection = editMenu.addItem(withTitle: "Use Selection for Find", action: effectiveFindAction, keyEquivalent: "e")
        useSelection.target = findTarget
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
                viewMenu.addItem(sectionHeader("Zoom"))
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

/// Mesh visual fixtures carry their own shape in the surface name:
/// `mesh-<agents>-<width>`, optionally suffixed `-large-text`. Bare `mesh`
/// stays the three-agent, typical-width fixture the workflow already captures.
/// Parsing it here keeps the capture matrix data in the workflow rather than
/// one Swift branch per cell.
struct NativeVisualMeshFixture: Equatable {
    enum Width: String, CaseIterable {
        case min
        case typical
        case full

        /// Content widths: the app's own minimum window, an ordinary laptop
        /// window, and a full-screen one on an external display. A hosted
        /// runner whose virtual display is narrower than these constrains the
        /// window to its own width.
        var points: CGFloat {
            switch self {
            case .min: 760
            case .typical: 1_360
            case .full: 1_920
            }
        }
    }

    var agentCount = 3
    var width = Width.typical
    var usesLargeText = false

    static let largeTextSuffix = "-large-text"
    static let supportedAgentCounts = 2...4

    static func parse(_ surface: String) -> NativeVisualMeshFixture? {
        if surface == "mesh" { return NativeVisualMeshFixture() }
        guard surface.hasPrefix("mesh-") else { return nil }
        var remainder = String(surface.dropFirst("mesh-".count))
        var fixture = NativeVisualMeshFixture()
        if remainder.hasSuffix(largeTextSuffix) {
            fixture.usesLargeText = true
            remainder = String(remainder.dropLast(largeTextSuffix.count))
        }
        let parts = remainder.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let agents = Int(parts[0]),
              supportedAgentCounts.contains(agents),
              let width = Width(rawValue: String(parts[1])) else { return nil }
        fixture.agentCount = agents
        fixture.width = width
        return fixture
    }
}

enum NativeVisualCaptureTarget {
    @MainActor
    static func window(rootedAt root: NSWindow, surface: String) -> NSWindow? {
        surface == "terminal-transcript" || surface == "account-picker"
            || surface == "workspace-rename" || surface == "workspace-new-file"
            || surface == "workspace-move"
            ? root.attachedSheet
            : root
    }
}

struct NativeVisualExtensionsSettingsReceipt: Codable, Equatable {
    let surface: String
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let categoryCount: Int
    let itemCount: Int
    let invalidCount: Int
    let accessibilityIdentifiers: [String]
    let accessibilityLabels: [String]
    let fixtureUpdaterDisabled: Bool
    let fixtureBrokerIsolated: Bool

    var failure: String? {
        guard surface == "settings-extensions" || surface == "settings-extensions-narrow" else {
            return "unexpected-surface"
        }
        guard categoryCount == ExtensionsSettingsCategory.allCases.count else {
            return "missing-registry-category-\(categoryCount)"
        }
        guard itemCount >= ExtensionsSettingsCategory.allCases.count else {
            return "missing-fixture-entry-\(itemCount)"
        }
        guard invalidCount == 1 else { return "wrong-invalid-count-\(invalidCount)" }
        guard fixtureUpdaterDisabled else { return "fixture-updater-started" }
        guard fixtureBrokerIsolated else { return "fixture-broker-route-live" }
        guard contentHeight >= 540 else { return "content-too-short-\(contentHeight)" }
        if surface == "settings-extensions" {
            // The hosted WindowServer constrains the declared 1,100-point
            // ideal Settings window to 1,024 points. Keep the receipt aligned
            // with the workflow's 1,000-pixel wide-surface floor.
            guard contentWidth >= 1_000 else { return "wide-content-too-narrow-\(contentWidth)" }
        } else {
            guard (800...900).contains(contentWidth) else {
                return "narrow-content-out-of-range-\(contentWidth)"
            }
        }

        let identifiers = Set(accessibilityIdentifiers)
        guard identifiers.contains("extensions.hub") else { return "missing-hub-ax" }
        guard accessibilityLabels.contains(where: {
            $0.localizedCaseInsensitiveContains("Search extensions")
        }) else { return "missing-search-label-ax" }
        if surface == "settings-extensions-narrow" {
            guard accessibilityLabels.contains(where: {
                $0.localizedCaseInsensitiveContains("Extension category")
            }) else { return "missing-compact-picker-label-ax" }
        }
        let joined = accessibilityLabels.joined(separator: " ").lowercased()
        guard !joined.contains("fixture-secret") else { return "secret-leaked-to-ax" }
        return nil
    }

    var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
enum NativeVisualAccessibilitySnapshot {
    struct Snapshot {
        var identifiers = Set<String>()
        var labels = Set<String>()
    }

    /// Read the mounted AppKit/SwiftUI AX graph, including SwiftUI's virtual
    /// `NSAccessibilityProtocol` descendants. SwiftUI's bridge vends private
    /// protocol-conforming objects rather than necessarily concrete
    /// `NSAccessibilityElement` instances, and navigation-order children are
    /// sometimes the first projection it materializes. The view hierarchy is a
    /// fallback only to reach hosting containers; acceptance still requires the
    /// identifiers and labels returned by mounted AX objects themselves.
    static func capture(from root: NSView) -> Snapshot {
        var snapshot = Snapshot()
        var visited = Set<ObjectIdentifier>()
        if let window = root.window {
            walk(window, depth: 0, visited: &visited, snapshot: &snapshot)
        }
        walk(root, depth: 0, visited: &visited, snapshot: &snapshot)
        if let descendant = NSAccessibility.unignoredDescendant(of: root) {
            walk(descendant, depth: 0, visited: &visited, snapshot: &snapshot)
        }
        return snapshot
    }

    private static func walk(
        _ value: Any,
        depth: Int,
        visited: inout Set<ObjectIdentifier>,
        snapshot: inout Snapshot
    ) {
        guard depth < 40, visited.count < 4_000 else { return }
        let object = value as AnyObject
        guard visited.insert(ObjectIdentifier(object)).inserted else { return }

        if let element = value as? any NSAccessibilityProtocol {
            record(
                identifier: element.accessibilityIdentifier(),
                label: element.accessibilityLabel(),
                in: &snapshot
            )
            let childGroups: [[Any]] = [
                element.accessibilityChildren() ?? [],
                element.accessibilityChildrenInNavigationOrder() ?? [],
                element.accessibilityContents() ?? [],
            ]
            for child in NSAccessibility.unignoredChildren(from: childGroups.flatMap { $0 }) {
                walk(child, depth: depth + 1, visited: &visited, snapshot: &snapshot)
            }
        }
        if let view = value as? NSView {
            for subview in view.subviews {
                walk(subview, depth: depth + 1, visited: &visited, snapshot: &snapshot)
            }
        }
    }

    private static func record(
        identifier: String?,
        label: String?,
        in snapshot: inout Snapshot
    ) {
        if let identifier, !identifier.isEmpty { snapshot.identifiers.insert(identifier) }
        if let label, !label.isEmpty { snapshot.labels.insert(label) }
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
        case "terminal-continuous-scroll":
            return ["continuous-anchor-"]
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

/// The three standard window buttons are the one part of a
/// `.fullSizeContentView` window AppKit still owns. Custom content drawn in that
/// corner renders on top of them, so a fixture can look perfectly composed while
/// minimize and zoom are buried under a 30pt mark — which is exactly what every
/// Settings capture showed until #306.
///
/// This gate runs before each Settings capture and fails it three ways: a
/// missing or disabled control, a rect the layout itself declares over a
/// control, and an accessibility element — the thing VoiceOver actually lands
/// on — whose frame meets one. A failure suppresses the PNG, so the visual
/// workflow fails rather than publishing the collision as a fixture.
@MainActor
enum NativeVisualWindowControlGate {
    /// A rectangle in window points measured from the content view's *top-left*
    /// corner, which is the corner the traffic lights sit in.
    struct Region: Equatable {
        let name: String
        let frame: CGRect
    }

    static let buttons: [(name: String, kind: NSWindow.ButtonType)] = [
        ("close", .closeButton),
        ("miniaturize", .miniaturizeButton),
        ("zoom", .zoomButton),
    ]

    static func applies(to surface: String) -> Bool {
        SettingsWindowChrome.visualSurfaces.contains(surface)
    }

    /// AppKit hands out window coordinates measured from the bottom-left. Flip
    /// them once, here, so every comparison below reads the way the layout does.
    static func topLeftFrame(_ frame: CGRect, in window: NSWindow) -> CGRect {
        let height = window.contentView?.bounds.height ?? window.frame.height
        return CGRect(
            x: frame.minX,
            y: height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func controlRegions(in window: NSWindow) -> [Region] {
        buttons.compactMap { name, kind in
            guard let button = window.standardWindowButton(kind) else { return nil }
            return Region(
                name: name,
                frame: topLeftFrame(button.convert(button.bounds, to: nil), in: window)
            )
        }
    }

    /// A control the user can see but not operate is the same failure as one
    /// they cannot see, so enablement is checked alongside presence.
    static func missingControl(in window: NSWindow) -> String? {
        for (name, kind) in buttons {
            guard let button = window.standardWindowButton(kind) else {
                return "absent-\(name)"
            }
            if button.isHidden { return "hidden-\(name)" }
            if !button.isEnabled { return "disabled-\(name)" }
        }
        return nil
    }

    /// The first custom region that meets a window button, named for the log.
    static func collision(controls: [Region], content: [Region]) -> String? {
        for control in controls {
            for region in content where region.frame.intersects(control.frame) {
                return "\(region.name)-over-\(control.name)"
            }
        }
        return nil
    }

    /// Every accessibility element under the content view, in the same top-left
    /// window points. Rooted at the content view on purpose: the window buttons
    /// are the *window's* accessibility children, never the content's, so
    /// nothing here can collide with itself.
    static func accessibilityRegions(in window: NSWindow, limit: Int = 600) -> [Region] {
        guard let root = window.contentView else { return [] }
        var regions: [Region] = []
        var queue = children(of: root)
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let element = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: children(of: element))
            let screenFrame = element.accessibilityFrame()
            guard screenFrame.width > 0, screenFrame.height > 0 else { continue }
            let name = element.accessibilityLabel()
                ?? element.accessibilityTitle()
                ?? String(describing: type(of: element))
            regions.append(Region(
                name: name,
                frame: topLeftFrame(window.convertFromScreen(screenFrame), in: window)
            ))
        }
        return regions
    }

    private static func children(
        of element: any NSAccessibilityProtocol
    ) -> [any NSAccessibilityProtocol] {
        (element.accessibilityChildren() ?? [])
            .compactMap { $0 as? any NSAccessibilityProtocol }
    }

    struct Report {
        let failure: String?
        let controls: Int
        let accessibilityElements: Int
    }

    static func inspect(_ window: NSWindow) -> Report {
        let controls = controlRegions(in: window)
        let accessibility = accessibilityRegions(in: window)
        let failure: String?
        if let missing = missingControl(in: window) {
            failure = missing
        } else if controls.count != buttons.count {
            failure = "controls-\(controls.count)"
        } else if let declared = collision(
            controls: controls,
            content: SettingsWindowChrome.topLeadingContentFrames().map {
                Region(name: $0.name, frame: $0.frame)
            }
        ) {
            failure = declared
        } else {
            failure = collision(controls: controls, content: accessibility)
        }
        return Report(
            failure: failure,
            controls: controls.count,
            accessibilityElements: accessibility.count
        )
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

    /// Redraw a capture at a requested pixels-per-point, or return nil when
    /// there is nothing to do: no scale was asked for, the size is unusable, or
    /// the image already has exactly those pixels.
    ///
    /// Resampling the finished capture rather than rendering the window offscreen
    /// keeps the non-Retina fixture on the same path as every other one. An
    /// offscreen redraw of a material-backed window is the case the visual
    /// workflow already warns about: it can come back transparent.
    static func rescaled(
        _ image: CGImage,
        pointSize: CGSize,
        pointPixelScale: CGFloat
    ) -> CGImage? {
        guard pointPixelScale > 0, pointSize.width > 0, pointSize.height > 0 else {
            return nil
        }
        let target = pixelSize(
            contentRect: CGRect(origin: .zero, size: pointSize),
            pointPixelScale: pointPixelScale
        )
        guard target.width != image.width || target.height != image.height else {
            return nil
        }
        guard let context = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: target.width, height: target.height)
        )
        return context.makeImage()
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
