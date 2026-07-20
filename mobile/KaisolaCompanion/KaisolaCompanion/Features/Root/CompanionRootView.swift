import SwiftUI

/// The app shell: gate on auth, then a three-tab structure (Home / Sessions /
/// Settings) with the agent transcript and terminal pushed onto the stack.
struct CompanionRootView: View {
    enum Tab: Hashable { case home, sessions, settings }

    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var auth: AuthModel
    @EnvironmentObject private var coordinator: CompanionConnectionCoordinator
    // KAISOLA_UI_TAB lets a screenshot launch open a specific tab (debug only).
    @State private var selection: Tab = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["KAISOLA_UI_TAB"] {
        case "settings": return .settings
        case "sessions": return .sessions
        default: return .home
        }
        #else
        return .home
        #endif
    }()
    @State private var homePath = NavigationPath()
    @State private var sessionsPath = NavigationPath()

    var body: some View {
        Group {
            switch auth.phase {
            case .restoring:
                SplashView()
            case .signedIn:
                signedInShell
                    .transition(.opacity)
            default:
                SignInView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: auth.phase)
    }

    private var signedInShell: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $homePath) {
                HomeView(
                    onOpenSession: { pushSession($0, into: .home) },
                    onOpenPermission: { openPermission($0) }
                )
                .navigationDestination(for: CompanionSession.self) { destination(for: $0) }
                .navigationDestination(for: CompanionPermission.self) { PermissionDetailView(permission: $0) }
            }
            .tabItem { Label("Home", systemImage: "square.grid.2x2") }
            .tag(Tab.home)
            .task { await deepLinkForScreenshots() }

            NavigationStack(path: $sessionsPath) {
                SessionsView()
                    .navigationDestination(for: CompanionSession.self) { destination(for: $0) }
            }
            .tabItem { Label("Sessions", systemImage: "list.bullet") }
            .tag(Tab.sessions)

            NavigationStack {
                CompanionSettingsView()
            }
            .tabItem { Label("Settings", systemImage: "person.crop.circle") }
            .badge(0)
            .tag(Tab.settings)
        }
        .tint(KaisolaTheme.accent)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .safeAreaInset(edge: .top, spacing: 0) { connectionRecoveryBar }
        .overlay(alignment: .bottom) { receiptToast }
        .sheet(isPresented: Binding(
            get: { coordinator.wantsPairing },
            set: { coordinator.wantsPairing = $0 }
        )) {
            PairingFlowView()
        }
    }

    @ViewBuilder private var connectionRecoveryBar: some View {
        if coordinator.isPaired, !store.isPreview, store.connection != .live {
            Button {
                Task { await coordinator.reconnect() }
            } label: {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(KaisolaTheme.accent)
                    Text(store.connection == .stale ? "Cached · reconnecting to Mac" : "Connecting to Mac")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KaisolaTheme.accent)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(.ultraThinMaterial)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reconnect to Mac")
            .accessibilityHint("Retries the secure connection now")
        }
    }

    private func pushSession(_ session: CompanionSession, into tab: Tab) {
        if tab == .home { homePath.append(session) } else { sessionsPath.append(session) }
    }

    /// Debug-only: push a session so a screenshot/E2E launch can reach the
    /// transcript or terminal without a tap. Polls briefly so it also works
    /// after a live pairing populates the store. Inert in release.
    private func deepLinkForScreenshots() async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KAISOLA_UI_PAIRING"] == "1" {
            coordinator.presentPairing()
            return
        }
        let kind = ProcessInfo.processInfo.environment["KAISOLA_UI_DEEPLINK"]
        let wantKind: CompanionSessionKind? = kind == "agent" ? .agent : kind == "terminal" ? .terminal : nil
        guard let wantKind else { return }
        for _ in 0..<30 {
            if homePath.isEmpty, let session = store.sessions.first(where: { $0.kind == wantKind }) {
                homePath.append(session)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        #endif
    }
    private func openPermission(_ permission: CompanionPermission) {
        homePath.append(permission)
    }

    @ViewBuilder private func destination(for session: CompanionSession) -> some View {
        switch session.kind {
        case .terminal: TerminalSessionView(sessionId: session.id)
        default: AgentSessionView(sessionId: session.id)
        }
    }

    @ViewBuilder private var receiptToast: some View {
        if let receipt = store.previewReceipt {
            HStack(spacing: 9) {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(KaisolaTheme.done)
                Text(receipt).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
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

/// Brief launch state while the Keychain refresh token is checked. Shows a
/// quiet progress cue after a beat so a slow network restore never reads as a
/// frozen logo.
struct SplashView: View {
    @State private var showProgress = false

    var body: some View {
        ZStack {
            AmbientBackdrop()
            VStack(spacing: 22) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [KaisolaTheme.electric, KaisolaTheme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                    .overlay { Image(systemName: "square.grid.2x2.fill").font(.system(size: 27, weight: .medium)).foregroundStyle(KaisolaTheme.darkFrame) }
                    .shadow(color: KaisolaTheme.accent.opacity(0.4), radius: 20, y: 8)
                ProgressView()
                    .tint(.secondary)
                    .opacity(showProgress ? 1 : 0)
                    .accessibilityLabel("Signing in")
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeIn) { showProgress = true }
        }
    }
}

#Preview("Signed in") {
    let store = CompanionStore.preview()
    let coordinator = CompanionConnectionCoordinator(store: store)
    return CompanionRootView()
        .environmentObject(store)
        .environmentObject(AuthModel.previewSignedIn())
        .environmentObject(coordinator)
}

#Preview("Signed out") {
    let store = CompanionStore.preview()
    let coordinator = CompanionConnectionCoordinator(store: store)
    return CompanionRootView()
        .environmentObject(store)
        .environmentObject(AuthModel.previewSignedOut())
        .environmentObject(coordinator)
}
