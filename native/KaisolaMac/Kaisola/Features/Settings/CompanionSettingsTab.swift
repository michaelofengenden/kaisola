import AppKit
import CoreImage.CIFilterBuiltins
import KaisolaCore
import SwiftUI

struct CompanionSettingsTab: View {
    @ObservedObject private var host = CompanionHost.shared
    @StateObject private var offerActivation = CompanionPairingOfferActivation()
    @State private var allowsTerminalControl = false
    @State private var operationError: String?
    @State private var pendingRevocation: CompanionPairedDeviceRecord?

    var body: some View {
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
                            title: "Allow terminal control",
                            detail: "Off gives this phone view-only access",
                            symbol: "keyboard"
                        ) {
                            Toggle("", isOn: $allowsTerminalControl)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel("Allow terminal control")
                        }
                        SettingsDivider()
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(offerTitle)
                                    .font(.callout.weight(.medium))
                                Text("Scan on iPhone, or copy the code into kaisola.com/app.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        if let code = host.pairingCode,
                           let image = CompanionQRCode.image(for: code) {
                            Divider().opacity(0.45)
                            VStack(spacing: 10) {
                                Image(nsImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 220, height: 220)
                                    .accessibilityLabel("Companion pairing QR code")
                                Button("Copy Pairing Code") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }

                        if let phrase = host.pairingPhrase {
                            Divider().opacity(0.45)
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Confirm \(phrase.displayName)")
                                    .font(.headline)
                                Text("The same four phrases must appear on both devices.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(phrase.sas.words.joined(separator: "   "))
                                    .font(.body.monospaced().weight(.semibold))
                                    .textSelection(.enabled)
                                HStack {
                                    Button("They Differ") { host.cancelPairing() }
                                        .buttonStyle(.bordered)
                                    Spacer()
                                    Button("They Match") { confirmPairing() }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(14)
                        }
                    }
                }

                SettingsCard(title: "Paired Devices", symbol: "checkmark.shield") {
                    if host.pairedDevices.isEmpty {
                        Text("No devices are paired with this Mac.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        ForEach(Array(host.pairedDevices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { SettingsDivider() }
                            SettingsRow(
                                title: device.displayName,
                                detail: capabilityDetail(device.capabilities),
                                symbol: "laptopcomputer.and.iphone"
                            ) {
                                Button("Revoke", role: .destructive) {
                                    pendingRevocation = device
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                if let error = operationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(18)
        }
        .onChange(of: host.state) { _, state in
            // Companion leaving ready tears this card down. An offer request
            // that is still outstanding must not come back to a button the
            // user can no longer press.
            if case .ready = state { return }
            offerActivation.discard()
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
                revoke(device.id)
            }
            Button("Cancel", role: .cancel) { pendingRevocation = nil }
        } message: {
            Text("This device will immediately lose access. Pairing it again requires a new single-use code and confirmation on both devices.")
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

    private func createOffer() {
        guard let attempt = offerActivation.begin() else { return }
        operationError = nil
        Task {
            do {
                try await host.createPairingOffer(allowsTerminalControl: allowsTerminalControl)
                offerActivation.finish(attempt)
            } catch {
                guard offerActivation.finish(attempt) else { return }
                operationError = error.localizedDescription
            }
        }
    }

    private func cancelPairing() {
        offerActivation.discard()
        host.cancelPairing()
    }

    private func confirmPairing() {
        operationError = nil
        Task {
            do { try await host.confirmPairing() }
            catch { operationError = error.localizedDescription }
        }
    }

    private func revoke(_ deviceID: String) {
        operationError = nil
        Task {
            do { try await host.revoke(deviceID: deviceID) }
            catch { operationError = error.localizedDescription }
        }
    }

    private func capabilityDetail(_ values: [CompanionCapability]) -> String {
        values.contains(.terminalControl) ? "View and control terminals" : "View only"
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
