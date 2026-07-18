import SwiftUI

/// Settings: you, your Mac, one clear exit. Identity up top, the paired Mac
/// with live state and capabilities, then Sign out.
struct CompanionSettingsView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var auth: AuthModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmSignOut = false
    @State private var confirmUnpair = false

    var onPairNewMac: () -> Void = {}

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

                    Text("Kaisola Companion · read-only alpha\nControl ships in a later update.")
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
            Button("Sign out", role: .destructive) { Task { await auth.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears your account and cached sessions from this phone.")
        }
        .confirmationDialog("Unpair this Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to scan the pairing code again to reconnect.")
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
        let connected = store.connection == .live
        section(title: "Paired Mac") {
            SettingsRow(icon: "laptopcomputer", label: macName) {
                HStack(spacing: 6) {
                    Circle().fill(connected ? KaisolaTheme.done : Color.secondary).frame(width: 7, height: 7)
                    Text(connected ? "Connected" : store.connection.title)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsRow(icon: "eye", label: "Access") {
                Text(accessLabel).font(.caption).foregroundStyle(.secondary)
            }
            SettingsRow(icon: "plus.viewfinder", label: "Pair another Mac", tint: KaisolaTheme.accent) {
                onPairNewMac()
            }
            SettingsRow(icon: "trash", label: "Unpair this Mac", destructive: false) {
                confirmUnpair = true
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
                if action != nil && Trailing.self == EmptyView.self {
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

#Preview {
    NavigationStack { CompanionSettingsView() }
        .environmentObject(CompanionStore.preview())
        .environmentObject(AuthModel.previewSignedIn())
}
