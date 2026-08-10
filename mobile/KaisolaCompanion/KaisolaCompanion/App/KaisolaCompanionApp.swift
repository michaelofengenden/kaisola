import KaisolaCore
import Combine
import Foundation
import SwiftUI

@main
struct KaisolaCompanionApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var auth: AuthModel
    @StateObject private var coordinator: CompanionConnectionCoordinator
    @StateObject private var rememberedSessions: RememberedSessionCatalogCenter
    private let rememberedSessionCatalog: RememberedSessionCatalogClient?
    private let rememberedSessionCache: RememberedSessionCatalogSnapshotStore?

    init() {
        _auth = StateObject(wrappedValue: Self.makeAuth())
        let store = Self.usePreviewStore ? CompanionStore.preview() : nil
        _coordinator = StateObject(wrappedValue: CompanionConnectionCoordinator(store: store))
        _rememberedSessions = StateObject(wrappedValue: Self.usePreviewStore
            ? RememberedSessionCatalogCenter.preview(localDeviceID: "companion-viewer")
            : RememberedSessionCatalogCenter(localDeviceID: "companion-viewer"))
        let configuration = try? FirebaseAuthConfiguration.load()
        rememberedSessionCatalog = configuration.flatMap {
            try? RememberedSessionCatalogClient(sessionURL: $0.serverURL)
        }
        rememberedSessionCache = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first.map {
            RememberedSessionCatalogSnapshotStore(
                directory: $0.appendingPathComponent(
                    "remembered-session-catalog-v1",
                    isDirectory: true
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environmentObject(coordinator.store)
                .environmentObject(auth)
                .environmentObject(coordinator)
                .environmentObject(rememberedSessions)
                .tint(KaisolaTheme.accent)
                .task {
                    await auth.restore()
                    guard !Self.usePreviewStore else { return }
                    let relayURL = (try? FirebaseAuthConfiguration.load())?.relayURL
                    coordinator.configureKaisolaLink(
                        baseURL: relayURL,
                        tokenProvider: { try await auth.freshIDToken() }
                    )
                    coordinator.activateAccount(accountID: auth.account?.uid)
                    await coordinator.connectIfPaired()
                    await Self.autoPairIfRequested(coordinator)
                }
                .task(id: auth.account?.uid) {
                    if !Self.usePreviewStore {
                        coordinator.activateAccount(accountID: auth.account?.uid)
                    }
                    // A UID transition owns a fresh presentation scope even if
                    // the previous account still has a suspended network call.
                    // Deactivate before clearing so sign-out also advances the
                    // client's epoch when no replacement account will issue a
                    // request of its own.
                    await rememberedSessionCatalog?.deactivate()
                    rememberedSessions.clear()
                    guard let accountID = auth.account?.uid else { return }
                    await coordinator.connectIfPaired()
                    if let rememberedSessionCache,
                       let snapshot = try? await rememberedSessionCache.load(
                            accountID: accountID
                       ),
                       !Task.isCancelled,
                       auth.account?.uid == accountID {
                        rememberedSessions.apply(
                            snapshot.devices,
                            now: snapshot.savedAt,
                            source: .savedSnapshot
                        )
                    }
                    await refreshRememberedSessions()
                }
                .onReceive(NotificationCenter.default.publisher(for: .kaisolaRefreshRememberedSessions)) { _ in
                    Task { await refreshRememberedSessions() }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard !Self.usePreviewStore else { return }
                    switch phase {
                    case .active:
                        Task {
                            await coordinator.connectIfPaired()
                            await refreshRememberedSessions()
                        }
                    case .background:
                        Task { await coordinator.suspend() }
                    case .inactive:
                        break
                    @unknown default:
                        Task { await coordinator.suspend() }
                    }
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

    /// Fetch account-owned metadata independently of the live Companion
    /// transport. These records remain useful when a Mac is asleep or not
    /// paired, but never grant terminal control by themselves.
    @MainActor private func refreshRememberedSessions() async {
        guard !Self.usePreviewStore,
              let accountID = auth.account?.uid,
              !rememberedSessions.isRefreshing,
              let rememberedSessionCatalog else { return }
        rememberedSessions.beginRefresh()
        do {
            let token = try await auth.freshIDToken()
            guard !Task.isCancelled, auth.account?.uid == accountID else { return }
            let devices = try await rememberedSessionCatalog.list(
                idToken: token,
                accountID: accountID
            )
            guard !Task.isCancelled, auth.account?.uid == accountID else { return }
            rememberedSessions.apply(
                devices,
                now: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            try? await rememberedSessionCache?.save(
                accountID: accountID,
                devices: devices
            )
        } catch is CancellationError {
            if auth.account?.uid == nil {
                rememberedSessions.clear()
            } else if auth.account?.uid == accountID {
                rememberedSessions.cancelRefresh()
            }
        } catch {
            guard auth.account?.uid == accountID else { return }
            rememberedSessions.fail(error)
        }
    }
}
