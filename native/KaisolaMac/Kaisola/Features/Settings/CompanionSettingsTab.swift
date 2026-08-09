import AppKit
import CoreImage.CIFilterBuiltins
import KaisolaCore
import SwiftUI

struct CompanionSettingsTab: View {
    @ObservedObject private var host = CompanionHost.shared
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
                                Text(host.pairingCode == nil ? "Create a single-use code" : "Code expires after two minutes")
                                    .font(.callout.weight(.medium))
                                Text("Scan on iPhone, or copy the code into kaisola.com/app.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if host.pairingCode == nil {
                                Button("Pair New Device") { createOffer() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            } else {
                                Button("Cancel", action: host.cancelPairing)
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
                            let connected = host.connectedDeviceIDs.contains(device.deviceId)
                            SettingsRow(
                                title: device.displayName,
                                detail: "\(capabilityDetail(device.capabilities)) · \(connected ? "Connected" : "Waiting to reconnect")",
                                symbol: "laptopcomputer.and.iphone"
                            ) {
                                HStack(spacing: 6) {
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

    private func createOffer() {
        operationError = nil
        Task {
            do { try await host.createPairingOffer(allowsTerminalControl: allowsTerminalControl) }
            catch { operationError = error.localizedDescription }
        }
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
