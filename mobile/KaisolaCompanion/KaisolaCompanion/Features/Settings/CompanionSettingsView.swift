import SwiftUI

/// Settings: you, your Mac, one clear exit. Identity up top, the paired Mac
/// with live state and capabilities, then Sign out.
struct CompanionSettingsView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var coordinator: CompanionConnectionCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmSignOut = false
    @State private var confirmUnpair = false
    @State private var showMacDetails = false
    @State private var showAccessDetails = false

    var body: some View {
        ZStack {
            AmbientBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let account = auth.account {
                        identityCard(account)
                    }

                    pairedMacSection

                    section(title: "Account") {
                        SettingsRow(icon: "rectangle.portrait.and.arrow.right", label: "Sign out", tint: KaisolaTheme.failed, destructive: true) {
                            confirmSignOut = true
                        }
                    }

                    Text("Kaisola Companion · encrypted private connection")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out of Kaisola?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    await coordinator.suspend()
                    await auth.signOut()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears your account and cached sessions from this phone.")
        }
        .confirmationDialog("Unpair this Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { coordinator.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to scan the pairing code again to reconnect.")
        }
        .navigationDestination(isPresented: $showMacDetails) {
            CompanionMacDetailView(
                name: macName,
                connected: store.connection == .live,
                connectionTitle: store.connection.title,
                route: coordinator.activeRoute,
                onReconnect: { Task { await coordinator.reconnect() } },
                onUnpair: { confirmUnpair = true }
            )
        }
        .navigationDestination(isPresented: $showAccessDetails) {
            CompanionAccessDetailView(
                agentControl: store.canControlAgents,
                terminalControl: store.canControlTerminals
            )
        }
    }

    private func identityCard(_ account: AuthAccount) -> some View {
        HStack(spacing: 13) {
            Circle()
                .fill(LinearGradient(colors: [KaisolaTheme.electric, KaisolaTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 46, height: 46)
                .overlay { Text(account.initials).font(.headline.weight(.bold)).foregroundStyle(KaisolaTheme.darkFrame) }
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName ?? account.email)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(15)
        .frame(maxWidth: .infinity)
        .background(KaisolaTheme.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
    }

    @ViewBuilder private var pairedMacSection: some View {
        if coordinator.isPaired || store.isPreview {
            let connected = store.connection == .live
            section(title: "Paired Mac") {
                SettingsRow(icon: "laptopcomputer", label: macName, action: { showMacDetails = true }) {
                    HStack(spacing: 6) {
                        Circle().fill(connected ? KaisolaTheme.done : Color.secondary).frame(width: 7, height: 7)
                        Text(connected ? coordinator.activeRoute.title : store.connection.title)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SettingsRow(icon: "link", label: "Kaisola Link", action: { showMacDetails = true }) {
                    Text("Automatic").font(.caption).foregroundStyle(.secondary)
                }
                SettingsRow(icon: "eye", label: "Access", action: { showAccessDetails = true }) {
                    Text(accessLabel).font(.caption).foregroundStyle(.secondary)
                }
                if !connected {
                    SettingsRow(icon: "arrow.clockwise", label: "Reconnect", tint: KaisolaTheme.accent) {
                        Task { await coordinator.reconnect() }
                    }
                }
                SettingsRow(icon: "trash", label: "Unpair this Mac", destructive: false) {
                    confirmUnpair = true
                }
            }
        } else {
            section(title: "Your Mac") {
                SettingsRow(icon: "qrcode.viewfinder", label: "Pair your Mac", tint: KaisolaTheme.accent) {
                    coordinator.presentPairing()
                }
            }
        }
    }

    // Neutral label until a real paired-device name arrives from the desktop
    // (pairing is wired in a later task). Never a hardcoded personal name.
    private let macName = "Your Mac"
    private var accessLabel: String {
        if store.canControlTerminals { return "Full control" }
        if store.canControlAgents { return "Agent control" }
        return "Observe only"
    }

    @ViewBuilder private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(KaisolaTheme.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let icon: String
    let label: String
    var tint: Color?
    var destructive: Bool = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.colorScheme) private var colorScheme

    init(icon: String, label: String, tint: Color? = nil, destructive: Bool = false,
         action: (() -> Void)? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.icon = icon; self.label = label; self.tint = tint
        self.destructive = destructive; self.action = action; self.trailing = trailing
    }

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint ?? (destructive ? KaisolaTheme.failed : KaisolaTheme.accent))
                    .frame(width: 26, height: 26)
                    .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(destructive ? KaisolaTheme.failed : .primary)
                Spacer(minLength: 6)
                trailing()
                if action != nil {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .overlay(alignment: .bottom) {
            Rectangle().fill(KaisolaTheme.border(for: colorScheme)).frame(height: 0.5).padding(.leading, 52)
        }
    }
}

private struct CompanionMacDetailView: View {
    let name: String
    let connected: Bool
    let connectionTitle: String
    let route: CompanionTransportRoute
    let onReconnect: () -> Void
    let onUnpair: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AmbientBackdrop()
            VStack(spacing: 18) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(KaisolaTheme.accent)
                    .frame(width: 70, height: 70)
                    .background(KaisolaTheme.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(name).font(.title3.weight(.semibold))
                Label(connected ? route.title : connectionTitle, systemImage: connected ? "checkmark.circle.fill" : "wifi.slash")
                    .font(.subheadline)
                    .foregroundStyle(connected ? KaisolaTheme.done : .secondary)
                Text("Kaisola chooses nearby Wi-Fi first, then your private route, then encrypted Kaisola Link. Your Mac remains authoritative for every session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)
                Button(action: onReconnect) {
                    Label("Reconnect now", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                Link(destination: URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!) {
                    Label("Install Tailscale", systemImage: "network.badge.shield.half.filled")
                        .font(.subheadline.weight(.semibold))
                }
                Link("Use a Headscale server", destination: URL(string: "https://tailscale.com/docs/how-to/set-up-custom-control-server")!)
                    .font(.caption.weight(.medium))
                Text("Both are optional. Once the Tailscale app is connected on this iPhone and Mac, Kaisola detects the private route automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 26)
                Spacer()
                Button("Unpair this Mac", role: .destructive, action: onUnpair)
                    .font(.subheadline.weight(.semibold))
                    .padding(.bottom, 18)
            }
            .padding(.top, 28)
        }
        .navigationTitle("Paired Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CompanionAccessDetailView: View {
    let agentControl: Bool
    let terminalControl: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AmbientBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    accessRow("Live viewing", detail: "Projects, agent turns, permissions, and terminal output", enabled: true)
                    accessRow("Agent control", detail: "Send, steer, stop, and answer complete permission requests", enabled: agentControl)
                    accessRow("Terminal control", detail: "Type through an expiring per-terminal lease; no terminal ownership transfer", enabled: terminalControl)
                    Label("Control unlocks with Face ID or your device passcode after inactivity. Change grants in Kaisola → Settings → Companion on your Mac.", systemImage: "faceid")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .background(KaisolaTheme.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(18)
            }
        }
        .navigationTitle("Access")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func accessRow(_ title: String, detail: String, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(enabled ? KaisolaTheme.done : Color.secondary.opacity(0.55))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(KaisolaTheme.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    let store = CompanionStore.preview()
    let coordinator = CompanionConnectionCoordinator(store: store)
    return NavigationStack { CompanionSettingsView() }
        .environmentObject(store)
        .environmentObject(AuthModel.previewSignedIn())
        .environmentObject(coordinator)
}
