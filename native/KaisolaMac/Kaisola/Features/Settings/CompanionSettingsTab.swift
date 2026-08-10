import AppKit
import CoreImage.CIFilterBuiltins
import KaisolaCore
import SwiftUI

struct CompanionPairingCodePresentation: Equatable, Sendable {
    let code: String

    var title: String { "Single-use pairing code" }
    var displayValue: String { code }
    var copyValue: String { code }
    var accessibilityValue: String { code }

    func qrFallbackMessage(qrCodeAvailable: Bool) -> String? {
        qrCodeAvailable
            ? nil
            : "QR code unavailable. Copy or select the pairing code instead."
    }
}

enum CompanionPairingOfferAccessibility {
    static let group = "companion.pairing-offer"
    static let code = group + ".code"
    static let qrCode = group + ".qr-code"
    static let qrFallback = group + ".qr-fallback"
    static let copy = group + ".copy"
    static let cancel = group + ".cancel"
    static let allControlIdentifiers = [code, qrCode, copy, cancel]
}

struct CompanionPairingGrantSelection: Equatable, Sendable {
    let allowsAgentControl: Bool
    let allowsTerminalControl: Bool
}

/// Holds only the explicit grants for the next single-use offer. Every way an
/// offer can end erases both elevated capabilities, so a later phone always
/// starts from view-only rather than inheriting a previous decision.
struct CompanionPairingGrantDraft: Equatable, Sendable {
    enum ResetReason: CaseIterable, Hashable, Sendable {
        case offerCreationFailed
        case cancelled
        case confirmed
        case expired
    }

    var allowsAgentControl = false
    var allowsTerminalControl = false

    var selection: CompanionPairingGrantSelection {
        CompanionPairingGrantSelection(
            allowsAgentControl: allowsAgentControl,
            allowsTerminalControl: allowsTerminalControl
        )
    }

    mutating func reset(after _: ResetReason) {
        allowsAgentControl = false
        allowsTerminalControl = false
    }
}

/// Fences the delayed expiry reset to the exact offer and expiry generation.
/// A cancelled sleep or a late wake-up cannot erase choices made for a newer
/// offer, even if stale work survives a SwiftUI task replacement.
struct CompanionPairingOfferExpiryFence: Equatable, Sendable {
    let pairingNonce: String
    let expiresAt: Int64

    init(pairingNonce: String, expiresAt: Int64) {
        self.pairingNonce = pairingNonce
        self.expiresAt = expiresAt
    }

    init(payload: CompanionPairingPayload) {
        self.init(pairingNonce: payload.pairingNonce, expiresAt: payload.expiresAt)
    }

    func matches(pairingNonce: String?, expiresAt: Int64?) -> Bool {
        pairingNonce == self.pairingNonce && expiresAt == self.expiresAt
    }
}

enum CompanionSettingsFailureTarget: Hashable, Sendable {
    case offer
    case confirmation
    case device(String)

    var anchorID: String {
        switch self {
        case .offer: "companion.error.offer.anchor"
        case .confirmation: "companion.error.confirmation.anchor"
        case .device(let deviceID): "companion.error.device.\(deviceID).anchor"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .offer: "companion.error.offer"
        case .confirmation: "companion.error.confirmation"
        case .device(let deviceID): "companion.error.device.\(deviceID)"
        }
    }
}

enum CompanionSettingsRetry: Equatable, Sendable {
    case createOffer
    case createReplacementOffer
    case revoke(deviceID: String)
    case updateCapabilities(deviceID: String, capabilities: [CompanionCapability])
}

struct CompanionSettingsFailure: Equatable, Sendable {
    static let maximumMessageCharacters = 512

    let message: String
    let retryTitle: String
    let retry: CompanionSettingsRetry

    init(message: String, retryTitle: String, retry: CompanionSettingsRetry) {
        self.message = String(message.prefix(Self.maximumMessageCharacters))
        self.retryTitle = retryTitle
        self.retry = retry
    }
}

struct CompanionSettingsFailureStore: Equatable, Sendable {
    private var offer: CompanionSettingsFailure?
    private var confirmation: CompanionSettingsFailure?
    private var devices: [String: CompanionSettingsFailure] = [:]

    mutating func record(
        _ failure: CompanionSettingsFailure,
        for target: CompanionSettingsFailureTarget
    ) {
        switch target {
        case .offer: offer = failure
        case .confirmation: confirmation = failure
        case .device(let deviceID): devices[deviceID] = failure
        }
    }

    mutating func clear(_ target: CompanionSettingsFailureTarget) {
        switch target {
        case .offer: offer = nil
        case .confirmation: confirmation = nil
        case .device(let deviceID): devices.removeValue(forKey: deviceID)
        }
    }

    mutating func retainDeviceFailures(for deviceIDs: Set<String>) {
        devices = devices.filter { deviceIDs.contains($0.key) }
    }

    func failure(for target: CompanionSettingsFailureTarget) -> CompanionSettingsFailure? {
        switch target {
        case .offer: offer
        case .confirmation: confirmation
        case .device(let deviceID): devices[deviceID]
        }
    }
}

struct CompanionSettingsTab: View {
    @ObservedObject private var host = CompanionHost.shared
    @StateObject private var offerActivation = CompanionPairingOfferActivation()
    @StateObject private var confirmationActivation = CompanionPairingConfirmationActivation()
    @State private var pairingGrantDraft = CompanionPairingGrantDraft()
    @State private var failures = CompanionSettingsFailureStore()
    @State private var failureFocusRequest: CompanionSettingsFailureTarget?
    @FocusState private var focusedFailure: CompanionSettingsFailureTarget?
    @State private var pendingRevocation: CompanionPairedDeviceRecord?
    @State private var capabilityUpdates: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                SettingsCard(title: "Nearby Access", symbol: "iphone.and.arrow.forward") {
                    SettingsRow(
                        title: "Kaisola Companion",
                        detail: "Available only while Kaisola is open",
                        symbol: "network"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { host.isEnabled },
                            set: { host.setEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Kaisola Companion nearby access")
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Status",
                        detail: host.lastError ?? "Encrypted local-network connection",
                        symbol: statusSymbol
                    ) {
                        Text(host.state.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusColor)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Kaisola Link",
                        detail: "Encrypted remote access for this signed-in account",
                        symbol: linkStatusSymbol
                    ) {
                        HStack(spacing: 5) {
                            Text(host.linkPhase.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(linkStatusColor)
                            if host.linkChannelCount > 0 {
                                Text("\(host.linkChannelCount) active")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(linkStatusColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        linkStatusColor.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                        }
                    }
                }

                if case .ready = host.state {
                    SettingsCard(title: "Pair a Device", symbol: "qrcode") {
                        SettingsRow(
                            title: "Allow agent control",
                            detail: "Lets this phone message, stop, and approve agents",
                            symbol: "bubble.left.and.bubble.right"
                        ) {
                            Toggle("", isOn: $pairingGrantDraft.allowsAgentControl)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel("Allow agent control")
                                .disabled(pairingGrantControlsDisabled)
                        }
                        SettingsDivider()
                        SettingsRow(
                            title: "Allow terminal control",
                            detail: "Lets this phone type into shells running as you",
                            symbol: "keyboard"
                        ) {
                            Toggle("", isOn: $pairingGrantDraft.allowsTerminalControl)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel("Allow terminal control")
                                .disabled(pairingGrantControlsDisabled)
                        }
                        SettingsDivider()
                        VStack(spacing: 0) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(offerTitle)
                                        .font(.callout.weight(.medium))
                                    Text("Scan on iPhone, or copy the code into kaisola.com/app.")
                                        .font(.caption)
                                        .foregroundStyle(.kaisolaSecondary)
                                }
                                Spacer()
                                if host.pairingCode == nil {
                                    Button { createOffer() } label: {
                                        if offerActivation.isCreating {
                                            HStack(spacing: 5) {
                                                ProgressView().controlSize(.mini)
                                                Text("Creating…")
                                            }
                                        } else {
                                            Text("Pair New Device")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(offerActivation.isCreating)
                                    .accessibilityLabel(
                                        offerActivation.isCreating
                                            ? CompanionPairingOfferActivation.progressLabel
                                            : "Pair New Device"
                                    )
                                } else {
                                    Button("Cancel", action: cancelPairing)
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .accessibilityIdentifier(
                                            CompanionPairingOfferAccessibility.cancel
                                        )
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)

                            inlineFailure(for: .offer)

                            if let code = host.pairingCode {
                                let presentation = CompanionPairingCodePresentation(code: code)
                                let qrCodeImage = CompanionQRCode.image(for: code)
                                Divider().opacity(0.45)
                                VStack(spacing: 12) {
                                    if let image = qrCodeImage {
                                        Image(nsImage: image)
                                            .interpolation(.none)
                                            .resizable()
                                            .frame(width: 220, height: 220)
                                            .accessibilityLabel("Companion pairing QR code")
                                            .accessibilityIdentifier(
                                                CompanionPairingOfferAccessibility.qrCode
                                            )
                                    }

                                    if let message = presentation.qrFallbackMessage(
                                        qrCodeAvailable: qrCodeImage != nil
                                    ) {
                                        Text(message)
                                            .font(.caption)
                                            .multilineTextAlignment(.center)
                                            .accessibilityIdentifier(
                                                CompanionPairingOfferAccessibility.qrFallback
                                            )
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(presentation.title)
                                            .font(.caption.weight(.semibold))
                                        Text(presentation.displayValue)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.primary)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(10)
                                            .background(
                                                Color(nsColor: .textBackgroundColor),
                                                in: RoundedRectangle(cornerRadius: 8)
                                            )
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color(nsColor: .separatorColor))
                                            }
                                            .accessibilityLabel(presentation.title)
                                            .accessibilityValue(presentation.accessibilityValue)
                                            .accessibilityIdentifier(
                                                CompanionPairingOfferAccessibility.code
                                            )
                                    }
                                    .frame(maxWidth: 360, alignment: .leading)

                                    Button("Copy Pairing Code") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(
                                            presentation.copyValue,
                                            forType: .string
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityIdentifier(
                                        CompanionPairingOfferAccessibility.copy
                                    )
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(CompanionPairingOfferAccessibility.group)

                        if let phrase = host.pairingPhrase {
                            Divider().opacity(0.45)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Confirm \(phrase.displayName)")
                                    .font(.headline)
                                Text("The same four phrases must appear on both devices.")
                                    .font(.caption)
                                    .foregroundStyle(.kaisolaSecondary)
                                Text(phrase.sas.words.joined(separator: "   "))
                                    .font(.body.monospaced().weight(.semibold))
                                    .textSelection(.enabled)
                                HStack {
                                    Button("They Differ", action: cancelPairing)
                                        .buttonStyle(.bordered)
                                        .disabled(confirmationActivation.isConfirming)
                                    Spacer()
                                    Button { confirmPairing() } label: {
                                        if confirmationActivation.isConfirming {
                                            HStack(spacing: 5) {
                                                ProgressView().controlSize(.mini)
                                                Text(CompanionPairingConfirmationActivation.progressLabel)
                                            }
                                        } else {
                                            Text("They Match")
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(confirmationActivation.isConfirming)
                                    .accessibilityLabel(
                                        confirmationActivation.isConfirming
                                            ? CompanionPairingConfirmationActivation.progressLabel
                                            : "They Match"
                                    )
                                }
                            }
                            .padding(14)
                        }
                        inlineFailure(for: .confirmation)
                    }
                }

                SettingsCard(title: "Paired Devices", symbol: "checkmark.shield") {
                    if host.pairedDevices.isEmpty {
                        Text("No devices are paired with this Mac.")
                            .font(.callout)
                            .foregroundStyle(.kaisolaSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        ForEach(Array(host.pairedDevices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { SettingsDivider() }
                            let connected = host.connectedDeviceIDs.contains(device.deviceId)
                            VStack(spacing: 0) {
                                SettingsRow(
                                    title: device.displayName,
                                    detail: "\(capabilityDetail(device.capabilities)) · \(connected ? "Connected" : "Waiting to reconnect")",
                                    symbol: "laptopcomputer.and.iphone"
                                ) {
                                    HStack(spacing: 6) {
                                        Menu("Access") {
                                            Label("View status and output", systemImage: "checkmark")
                                            Divider()
                                            Button {
                                                toggle(.agentControl, for: device)
                                            } label: {
                                                Label(
                                                    "Control agents",
                                                    systemImage: device.capabilities.contains(.agentControl)
                                                        ? "checkmark" : "circle"
                                                )
                                            }
                                            Button {
                                                toggle(.terminalControl, for: device)
                                            } label: {
                                                Label(
                                                    "Control terminals",
                                                    systemImage: device.capabilities.contains(.terminalControl)
                                                        ? "checkmark" : "circle"
                                                )
                                            }
                                        }
                                        .menuStyle(.borderlessButton)
                                        .fixedSize()
                                        .disabled(capabilityUpdates.contains(device.id))
                                        .accessibilityLabel("Change access for \(device.displayName)")

                                        if !connected {
                                            Button("Refresh") {
                                                host.refreshReconnectAvailability()
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .accessibilityLabel("Refresh reconnect routes for \(device.displayName)")
                                            .accessibilityHint("Keeps this device paired and retries available Nearby and Link routes")
                                        }
                                        Button("Revoke", role: .destructive) {
                                            pendingRevocation = device
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                inlineFailure(for: .device(device.id))
                            }
                        }
                    }
                }

                }
                .padding(18)
            }
            .onChange(of: failureFocusRequest) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(target.anchorID, anchor: .center)
                }
                focusedFailure = target
                failureFocusRequest = nil
            }
            .onChange(of: host.state) { _, state in
                // Companion leaving ready tears this card down. An offer request
                // that is still outstanding must not come back to a button the
                // user can no longer press.
                if case .ready = state { return }
                offerActivation.discard()
                confirmationActivation.discard()
                pairingGrantDraft.reset(after: .cancelled)
            }
            .onChange(of: host.pairingPhrase?.pairingID) { _, pairingID in
                confirmationActivation.reconcile(pairingID: pairingID)
            }
            .onChange(of: host.pairingPayload?.pairingNonce) { previous, current in
                guard previous != nil, current == nil else { return }
                pairingGrantDraft.reset(after: .confirmed)
            }
            .onChange(of: host.pairedDevices.map(\.id)) { _, deviceIDs in
                failures.retainDeviceFailures(for: Set(deviceIDs))
            }
            .task(id: host.pairingPayload) {
                guard let payload = host.pairingPayload else { return }
                await resetPairingGrantDraft(atExpiryOf: payload)
            }
            .confirmationDialog(
                "Revoke \(pendingRevocation?.displayName ?? "Device")?",
                isPresented: Binding(
                    get: { pendingRevocation != nil },
                    set: { if !$0 { pendingRevocation = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Revoke Device", role: .destructive) {
                    guard let device = pendingRevocation else { return }
                    pendingRevocation = nil
                    revoke(deviceID: device.id)
                }
                Button("Cancel", role: .cancel) { pendingRevocation = nil }
            } message: {
                Text("This device will immediately lose access. Pairing it again requires a new single-use code and confirmation on both devices.")
            }
        }
    }

    @ViewBuilder
    private func inlineFailure(for target: CompanionSettingsFailureTarget) -> some View {
        if let failure = failures.failure(for: target) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(failure.retryTitle) {
                    retry(failure.retry, at: target)
                }
                .controlSize(.small)
                .focused($focusedFailure, equals: target)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(KaisolaStatusTone.failed.foregroundColor.opacity(0.08))
            .id(target.anchorID)
            .accessibilityIdentifier(target.accessibilityIdentifier)
        }
    }

    private func beginAction(at target: CompanionSettingsFailureTarget) {
        failures.clear(target)
        if focusedFailure == target { focusedFailure = nil }
        if failureFocusRequest == target { failureFocusRequest = nil }
    }

    private func recordFailure(
        _ failure: CompanionSettingsFailure,
        at target: CompanionSettingsFailureTarget
    ) {
        failures.record(failure, for: target)
        failureFocusRequest = target
    }

    private func retry(
        _ retry: CompanionSettingsRetry,
        at target: CompanionSettingsFailureTarget
    ) {
        beginAction(at: target)
        switch retry {
        case .createOffer, .createReplacementOffer:
            createOffer()
        case .revoke(let deviceID):
            revoke(deviceID: deviceID)
        case let .updateCapabilities(deviceID, capabilities):
            updateCapabilities(deviceID: deviceID, capabilities: capabilities)
        }
    }

    private var statusSymbol: String {
        switch host.state {
        case .disabled: "circle"
        case .starting: "ellipsis.circle"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch host.state {
        case .ready: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var linkStatusSymbol: String {
        switch host.linkPhase {
        case .ready: "network.badge.shield.half.filled"
        case .connecting, .reconnecting: "network"
        case .authenticationRequired: "person.crop.circle.badge.exclamationmark"
        case .unavailable: "exclamationmark.icloud"
        case .off: "icloud.slash"
        }
    }

    private var linkStatusColor: Color {
        switch host.linkPhase {
        case .ready: .green
        case .authenticationRequired, .unavailable: .orange
        default: .secondary
        }
    }

    private var offerTitle: String {
        if host.pairingCode != nil { return "Code expires after two minutes" }
        return offerActivation.isCreating
            ? CompanionPairingOfferActivation.progressLabel
            : "Create a single-use code"
    }

    private var pairingGrantControlsDisabled: Bool {
        offerActivation.isCreating || host.pairingCode != nil
    }

    private func createOffer() {
        guard let attempt = offerActivation.begin() else { return }
        beginAction(at: .offer)
        beginAction(at: .confirmation)
        let selection = pairingGrantDraft.selection
        Task {
            do {
                try await host.createPairingOffer(
                    allowsAgentControl: selection.allowsAgentControl,
                    allowsTerminalControl: selection.allowsTerminalControl
                )
                offerActivation.finish(attempt)
            } catch {
                guard offerActivation.finish(attempt) else { return }
                pairingGrantDraft.reset(after: .offerCreationFailed)
                recordFailure(
                    CompanionSettingsFailure(
                        message: "Pairing code creation failed: \(error.localizedDescription)",
                        retryTitle: "Try Again",
                        retry: .createOffer
                    ),
                    at: .offer
                )
            }
        }
    }

    private func cancelPairing() {
        offerActivation.discard()
        confirmationActivation.discard()
        pairingGrantDraft.reset(after: .cancelled)
        beginAction(at: .offer)
        beginAction(at: .confirmation)
        host.cancelPairing()
    }

    private func resetPairingGrantDraft(
        atExpiryOf payload: CompanionPairingPayload
    ) async {
        let fence = CompanionPairingOfferExpiryFence(payload: payload)
        let expiry = Date(timeIntervalSince1970: Double(fence.expiresAt) / 1_000)
        let delay = max(0, expiry.timeIntervalSinceNow)
        if delay > 0 {
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
        }
        guard !Task.isCancelled,
              fence.matches(
                  pairingNonce: host.pairingPayload?.pairingNonce,
                  expiresAt: host.pairingPayload?.expiresAt
              ) else { return }
        pairingGrantDraft.reset(after: .expired)
    }

    private func confirmPairing() {
        guard let phrase = host.pairingPhrase,
              let attempt = confirmationActivation.begin(pairingID: phrase.pairingID)
        else { return }
        beginAction(at: .confirmation)
        Task {
            do {
                try await host.confirmPairing()
                confirmationActivation.submitted(
                    attempt,
                    currentPairingID: host.pairingPhrase?.pairingID
                )
            } catch {
                guard confirmationActivation.fail(attempt) else { return }
                host.cancelPairing()
                recordFailure(
                    CompanionSettingsFailure(
                        message: CompanionPairingConfirmationActivation.failureMessage(error),
                        retryTitle: "Create New Code",
                        retry: .createReplacementOffer
                    ),
                    at: .confirmation
                )
                pairingGrantDraft.reset(after: .cancelled)
            }
        }
    }

    private func revoke(deviceID: String) {
        let target = CompanionSettingsFailureTarget.device(deviceID)
        beginAction(at: target)
        Task {
            do { try await host.revoke(deviceID: deviceID) }
            catch {
                recordFailure(
                    CompanionSettingsFailure(
                        message: "Device revocation failed: \(error.localizedDescription)",
                        retryTitle: "Retry Revoke",
                        retry: .revoke(deviceID: deviceID)
                    ),
                    at: target
                )
            }
        }
    }

    private func toggle(
        _ capability: CompanionCapability,
        for device: CompanionPairedDeviceRecord
    ) {
        var capabilities = Set(device.capabilities)
        if capabilities.contains(capability) { capabilities.remove(capability) }
        else { capabilities.insert(capability) }
        let ordered = CompanionCapability.allCases.filter(capabilities.contains)
        updateCapabilities(deviceID: device.id, capabilities: ordered)
    }

    private func updateCapabilities(
        deviceID: String,
        capabilities: [CompanionCapability]
    ) {
        let target = CompanionSettingsFailureTarget.device(deviceID)
        beginAction(at: target)
        capabilityUpdates.insert(deviceID)
        Task {
            defer { capabilityUpdates.remove(deviceID) }
            do {
                try await host.updateCapabilities(
                    deviceID: deviceID,
                    capabilities: capabilities
                )
            } catch {
                recordFailure(
                    CompanionSettingsFailure(
                        message: "Device access update failed: \(error.localizedDescription)",
                        retryTitle: "Retry Access Change",
                        retry: .updateCapabilities(
                            deviceID: deviceID,
                            capabilities: capabilities
                        )
                    ),
                    at: target
                )
            }
        }
    }

    private func capabilityDetail(_ values: [CompanionCapability]) -> String {
        switch (values.contains(.agentControl), values.contains(.terminalControl)) {
        case (true, true): "View; control agents and terminals"
        case (true, false): "View and control agents"
        case (false, true): "View and control terminals"
        case (false, false): "View only"
        }
    }
}

/// Serializes Pair New Device activations.
///
/// Creating an offer is asynchronous, so an ordinary enabled button lets
/// repeated presses launch overlapping requests whose code and error land in
/// an unpredictable order. Exactly one activation holds the slot at a time,
/// and it hands back a token so only the newest request may apply its result.
@MainActor
final class CompanionPairingOfferActivation: ObservableObject {
    /// The words the row and the accessibility label both use while a request
    /// is outstanding, so assistive tech hears the visible progress state.
    static let progressLabel = "Creating pairing code"

    @Published private(set) var isCreating = false

    private var attempt: UUID?

    /// Claims the single in-flight slot, or returns nil when a request is
    /// already outstanding and this activation must be ignored.
    func begin() -> UUID? {
        guard !isCreating else { return nil }
        let token = UUID()
        attempt = token
        isCreating = true
        return token
    }

    /// Releases the slot and reports whether `token` still owns it. A false
    /// result means the request was superseded or discarded, so its code and
    /// error are stale and the caller must drop them.
    @discardableResult
    func finish(_ token: UUID) -> Bool {
        guard attempt == token else { return false }
        attempt = nil
        isCreating = false
        return true
    }

    /// Abandons the outstanding request and restores an actionable button. A
    /// result that arrives afterwards no longer owns the slot.
    func discard() {
        attempt = nil
        isCreating = false
    }
}

/// Serializes the local SAS decision and keeps both phrase controls inert until
/// that exact pairing either authenticates, disappears, or fails.
///
/// Sending the Mac's confirmation is not the same as completing the handshake:
/// the phone may not have submitted its decision yet. The pairing identity is
/// therefore part of the in-flight token, preventing a late task from clearing
/// or cancelling a newer phrase.
@MainActor
final class CompanionPairingConfirmationActivation: ObservableObject {
    static let progressLabel = "Confirming pairing"

    struct Attempt: Equatable, Sendable {
        let id: UUID
        let pairingID: String
    }

    private enum Phase {
        case idle
        case submitting(Attempt)
        case awaitingPeer(Attempt)
    }

    @Published private(set) var isConfirming = false

    private var phase = Phase.idle

    func begin(pairingID: String) -> Attempt? {
        guard !isConfirming, !pairingID.isEmpty else { return nil }
        let attempt = Attempt(id: UUID(), pairingID: pairingID)
        phase = .submitting(attempt)
        isConfirming = true
        return attempt
    }

    /// Records that the local decision was sent. The controls stay gated while
    /// the same phrase awaits its peer; an already-settled phrase releases them.
    @discardableResult
    func submitted(_ attempt: Attempt, currentPairingID: String?) -> Bool {
        guard case let .submitting(current) = phase, current == attempt else { return false }
        guard currentPairingID == attempt.pairingID else {
            reset()
            return false
        }
        phase = .awaitingPeer(attempt)
        return true
    }

    /// Releases only the attempt that still owns the failure. A stale task can
    /// never cancel a replacement pairing that has claimed a different token.
    @discardableResult
    func fail(_ attempt: Attempt) -> Bool {
        guard activeAttempt == attempt else { return false }
        reset()
        return true
    }

    /// Pairing identity can disappear before an awaited task reports failure.
    /// Keep a submitting attempt until that task settles, but release a
    /// peer-waiting attempt as soon as its exact phrase completes or vanishes.
    func reconcile(pairingID: String?) {
        switch phase {
        case .idle:
            return
        case let .submitting(attempt):
            if let pairingID, pairingID != attempt.pairingID { reset() }
        case let .awaitingPeer(attempt):
            if pairingID != attempt.pairingID { reset() }
        }
    }

    func discard() {
        reset()
    }

    static func failureMessage(_ error: any Error) -> String {
        "Pairing confirmation failed: \(error.localizedDescription) "
            + "Create a new pairing code to try again."
    }

    private var activeAttempt: Attempt? {
        switch phase {
        case .idle: nil
        case let .submitting(attempt), let .awaitingPeer(attempt): attempt
        }
    }

    private func reset() {
        phase = .idle
        isConfirming = false
    }
}

enum CompanionQRCode {
    static func image(for payload: String) -> NSImage? {
        guard let data = payload.data(using: .utf8), !data.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
