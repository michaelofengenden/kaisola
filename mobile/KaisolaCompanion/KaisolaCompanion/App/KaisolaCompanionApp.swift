import SwiftUI

@main
struct KaisolaCompanionApp: App {
    @StateObject private var store = CompanionStore.preview()

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environmentObject(store)
                .tint(KaisolaTheme.accent)
        }
    }
}
