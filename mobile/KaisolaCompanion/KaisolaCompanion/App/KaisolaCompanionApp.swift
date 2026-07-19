import SwiftUI

@main
struct KaisolaCompanionApp: App {
    @StateObject private var auth = KaisolaCompanionApp.makeAuth()
    @StateObject private var coordinator = CompanionConnectionCoordinator()
    @StateObject private var previewStore = CompanionStore.preview()

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environmentObject(Self.usePreviewStore ? previewStore : coordinator.store)
                .environmentObject(auth)
                .environmentObject(coordinator)
                .tint(KaisolaTheme.accent)
                .task {
                    await auth.restore()
                    guard !Self.usePreviewStore else { return }
                    await coordinator.connectIfPaired()
                    await Self.autoPairIfRequested(coordinator)
                }
        }
    }

    /// Screenshot/dev path uses canned data everywhere.
    static var usePreviewStore: Bool { flag("KAISOLA_UI_PREVIEW") }

    /// Bypass the sign-in gate. True for screenshots and for the pairing E2E,
    /// which needs a signed-in session over the *live* store (not preview data).
    static var previewAuth: Bool { usePreviewStore || flag("KAISOLA_PREVIEW_AUTH") }

    private static func flag(_ name: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment[name] == "1"
        #else
        return false
        #endif
    }

    /// DEBUG-only: pair automatically from a QR payload passed in the launch
    /// environment, so an automated harness can drive pairing without taps.
    @MainActor private static func autoPairIfRequested(_ coordinator: CompanionConnectionCoordinator) async {
        #if DEBUG
        guard let payloadString = ProcessInfo.processInfo.environment["KAISOLA_AUTOPAIR"],
              let data = payloadString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CompanionPairingPayload.self, from: data) else { return }
        await coordinator.pair(with: payload)
        #endif
    }

    @MainActor private static func makeAuth() -> AuthModel {
        #if DEBUG
        if previewAuth { return AuthModel.previewSignedIn() }
        #endif
        return AuthModel(backend: FirebaseAuthBackend())
    }
}
