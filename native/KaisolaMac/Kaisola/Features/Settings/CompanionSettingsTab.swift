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

struct CompanionSettingsTab: View {
    @ObservedObject private var host = CompanionHost.shared
    @State private var allowsAgentControl = false
    @State private var allowsTerminalControl = false
    @State private var operationError: String?
    @State private var pendingRevocation: CompanionPairedDeviceRecord?
    @State private var capabilityUpdates: Set<String> = []

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
                            title: "Allow agent control",
                            detail: "Lets this phone message, stop, and approve agents",
                            symbol: "bubble.left.and.bubble.right"
                        ) {
                            Toggle("", isOn: $allowsAgentControl)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel("Allow agent control")
                        }
                        SettingsDivider()
                        SettingsRow(
                            title: "Allow terminal control",
                            detail: "Lets this phone type into shells running as you",
                            symbol: "keyboard"
                        ) {
                            Toggle("", isOn: $allowsTerminalControl)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel("Allow terminal control")
                        }
                        SettingsDivider()
                        VStack(spacing: 0) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(host.pairingCode == nil ? "Create a single-use code" : "Code expires after two minutes")
                                        .font(.callout.weight(.medium))
                                    Text("Scan on iPhone, or copy the code into kaisola.com/app.")
                                        .font(.caption)
                                        .foregroundStyle(.kaisolaSecondary)
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
                                        .accessibilityIdentifier(
                                            CompanionPairingOfferAccessibility.cancel
                                        )
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)

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
                            .foregroundStyle(.kaisolaSecondary)
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
            do {
                try await host.createPairingOffer(
                    allowsAgentControl: allowsAgentControl,
                    allowsTerminalControl: allowsTerminalControl
                )
            }
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

    private func toggle(
        _ capability: CompanionCapability,
        for device: CompanionPairedDeviceRecord
    ) {
        operationError = nil
        capabilityUpdates.insert(device.id)
        var capabilities = Set(device.capabilities)
        if capabilities.contains(capability) { capabilities.remove(capability) }
        else { capabilities.insert(capability) }
        let ordered = CompanionCapability.allCases.filter(capabilities.contains)
        Task {
            defer { capabilityUpdates.remove(device.id) }
            do {
                try await host.updateCapabilities(
                    deviceID: device.id,
                    capabilities: ordered
                )
            } catch {
                operationError = error.localizedDescription
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
