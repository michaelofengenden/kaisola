import SwiftUI

struct CompanionRootView: View {
    enum Tab: Hashable {
        case now
        case needsYou
        case sessions
        case devices
    }

    @EnvironmentObject private var store: CompanionStore
    @State private var selection: Tab = .now

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                NowView(
                    onOpenInbox: { selection = .needsYou },
                    onOpenSessions: { selection = .sessions }
                )
            }
                .tabItem { Label("Now", systemImage: "sparkle") }
                .tag(Tab.now)

            NavigationStack { NeedsYouView() }
                .tabItem { Label("Inbox", systemImage: "bell") }
                .badge(store.needsYouCount)
                .tag(Tab.needsYou)

            NavigationStack { SessionsView() }
                .tabItem { Label("Sessions", systemImage: "waveform.path.ecg") }
                .tag(Tab.sessions)

            NavigationStack { DevicesView() }
                .tabItem { Label("Link", systemImage: "link") }
                .tag(Tab.devices)
        }
        .tint(KaisolaTheme.accent)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .animation(.smooth(duration: 0.32), value: selection)
        .overlay(alignment: .bottom) {
            if let receipt = store.previewReceipt {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(KaisolaTheme.done)
                    Text(receipt)
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5) }
                .padding(.bottom, 62)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation(.smooth) { store.previewReceipt = nil }
                    }
                }
            }
        }
    }
}
