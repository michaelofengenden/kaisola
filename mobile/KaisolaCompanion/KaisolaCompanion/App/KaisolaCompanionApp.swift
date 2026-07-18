import SwiftUI

@main
struct KaisolaCompanionApp: App {
    @StateObject private var store = CompanionStore.preview()
    @StateObject private var auth = KaisolaCompanionApp.makeAuth()

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environmentObject(store)
                .environmentObject(auth)
                .tint(KaisolaTheme.accent)
                .task { await auth.restore() }
        }
    }

    /// Production signs in through Firebase (Identity Toolkit REST). Launching
    /// with KAISOLA_UI_PREVIEW=1 uses a scripted signed-in backend so the whole
    /// experience is screenshottable without a live Google OAuth round trip.
    @MainActor private static func makeAuth() -> AuthModel {
        #if DEBUG
        if ProcessInfo.processInfo.environment["KAISOLA_UI_PREVIEW"] == "1" {
            return AuthModel.previewSignedIn()
        }
        #endif
        return AuthModel(backend: FirebaseAuthBackend())
    }
}
