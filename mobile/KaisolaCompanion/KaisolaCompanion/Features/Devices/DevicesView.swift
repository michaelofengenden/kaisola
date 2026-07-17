import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var store: CompanionStore
    @State private var showPairing = false

    var body: some View {
        ZStack {
            AmbientBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ConsoleHeader(
                        eyebrow: "Secure link",
                        title: "Your devices",
                        detail: "Observe first. Widen control deliberately.",
                        symbol: "point.3.connected.trianglepath.dotted"
                    )

                    deviceIdentity

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: "Capabilities", count: 3, color: KaisolaTheme.accent)
                        capabilityRow(symbol: "eye", title: "Observe", value: "Preview", color: KaisolaTheme.accent)
                        capabilityRow(symbol: "sparkle", title: "Agent control", value: "Locked", color: .secondary)
                        capabilityRow(symbol: "terminal", title: "Terminal control", value: "Locked", color: .secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: "Michael’s Mac", count: 0, color: KaisolaTheme.electric, subtitle: "Not paired")
                        Button { showPairing = true } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "viewfinder")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(KaisolaTheme.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Preview pairing flow")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("No service, socket, key, or secret exists yet.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.quaternary)
                            }
                            .kaisolaCard(padding: 14)
                        }
                        .buttonStyle(QuietPressStyle())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: "Privacy model", count: 3, color: KaisolaTheme.done)
                        privacyRow("Mac stays authoritative", symbol: "laptopcomputer")
                        privacyRow("Bounded local cache", symbol: "externaldrive.badge.checkmark")
                        privacyRow("No secrets in preview data", symbol: "key.slash")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPairing) {
            PairingPreviewView()
        }
    }

    private var deviceIdentity: some View {
        HStack(spacing: 15) {
            ZStack {
                Circle().stroke(KaisolaTheme.accent.opacity(0.22), lineWidth: 1)
                Image(systemName: "iphone.gen3")
                    .font(.title3.weight(.light))
                    .foregroundStyle(KaisolaTheme.accent)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text("Michael’s iPhone")
                    .font(.headline)
                HStack(spacing: 7) {
                    PulseDot(color: KaisolaTheme.electric, animated: false, size: 4)
                    Text("UNPAIRED PREVIEW")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("THIS DEVICE")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
        }
        .kaisolaCard(padding: 16)
    }

    private func capabilityRow(symbol: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(color)
            if value == "Locked" {
                Image(systemName: "lock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .kaisolaInset(radius: 13)
    }

    private func privacyRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(KaisolaTheme.done)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
            Spacer()
            Image(systemName: "checkmark")
                .font(.caption2.bold())
                .foregroundStyle(KaisolaTheme.done)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

private struct PairingPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    private let cells = Array(0..<121)

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackdrop()

                VStack(spacing: 22) {
                    Spacer()
                    OrbitalStatusMark()
                    VStack(spacing: 8) {
                        Text("SECURE HANDSHAKE")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(KaisolaTheme.accent)
                        Text("Pair with your Mac")
                            .font(.system(size: 27, weight: .medium, design: .rounded))
                        Text("Scan the expiring code in Kaisola Settings, then compare the short phrase on both devices.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 2), count: 11), spacing: 2) {
                        ForEach(cells, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(isFilled(index) ? Color.primary : Color.clear)
                                .frame(width: 12, height: 12)
                        }
                    }
                    .padding(15)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)

                    PreviewModePill()
                    Text("Decorative preview / not scannable")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Pairing preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func isFilled(_ index: Int) -> Bool {
        let row = index / 11
        let column = index % 11
        let finder = (row < 3 && column < 3) || (row < 3 && column > 7) || (row > 7 && column < 3)
        return finder || ((row * 7 + column * 11 + row * column) % 5 < 2)
    }
}
