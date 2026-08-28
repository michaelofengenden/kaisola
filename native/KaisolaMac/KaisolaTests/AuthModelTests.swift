import XCTest
@testable import Kaisola

@MainActor
final class AuthModelTests: XCTestCase {
    func testRestoreFailureRemainsVisibleForRecovery() async {
        let model = AuthModel(backend: RestoreFailureAuthBackend())

        await model.restore()

        XCTAssertEqual(
            model.phase,
            .failed("Kaisola could not access the saved sign-in.")
        )
    }

    func testRestoreCancellationReturnsToSignedOut() async {
        let model = AuthModel(backend: RestoreCancellationAuthBackend())

        await model.restore()

        XCTAssertEqual(model.phase, .signedOut)
    }

    func testHeadlessKeychainPolicyUsesFailWithoutInteraction() {
        let headlessContext = KeychainAuthInteractionPolicy
            .failIfInteractionRequired
            .makeAuthenticationContext()
        let interactiveContext = KeychainAuthInteractionPolicy
            .allowUserInteraction
            .makeAuthenticationContext()

        XCTAssertTrue(headlessContext.interactionNotAllowed)
        XCTAssertFalse(interactiveContext.interactionNotAllowed)
        XCTAssertNil(KeychainAuthInteractionPolicy.failIfInteractionRequired.operationPrompt)
        XCTAssertNotNil(KeychainAuthInteractionPolicy.allowUserInteraction.operationPrompt)
    }

    func testSessionVaultSerializesRoundTripOffTheAuthModel() async throws {
        let store = LockedAuthSecureStore()
        let vault = AuthSessionVault(store: store)
        let account = AuthAccount(
            uid: "account-1",
            email: "person@example.com",
            displayName: "Kaisola Person",
            avatarURL: nil
        )

        try await vault.save(refreshToken: "refresh-token", account: account)
        let restoredToken = try await vault.refreshToken()
        let restoredAccount = try await vault.account()
        XCTAssertEqual(restoredToken, "refresh-token")
        XCTAssertEqual(restoredAccount, account)

        try await vault.clear()
        let clearedToken = try await vault.refreshToken()
        let clearedAccount = try await vault.account()
        XCTAssertNil(clearedToken)
        XCTAssertNil(clearedAccount)
    }

    func testDeveloperIDSignedOutNoticeSurvivesEmptyRestoreAndClearsAfterSignIn() async {
        let backend = NoticeAuthBackend()
        let model = AuthModel(
            backend: backend,
            signedOutNotice: "Sign in once after the signed-app upgrade."
        )

        await model.restore()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(
            model.signedOutNotice,
            "Sign in once after the signed-app upgrade."
        )

        await model.signInWithGoogle()
        XCTAssertTrue(model.isSignedIn)
        XCTAssertNil(model.signedOutNotice)

        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.signedOutNotice)
    }

    func testMacProductionKeychainServiceDoesNotReusePreviewNamespace() {
        XCTAssertEqual(
            KeychainAuthSecureStore.defaultService(bundleIdentifier: "com.kaisola.mac"),
            "com.kaisola.mac.firebase-auth"
        )
        XCTAssertNotEqual(
            KeychainAuthSecureStore.defaultService(bundleIdentifier: "com.kaisola.mac"),
            "com.kaisola.mac.preview.firebase-auth"
        )
    }

    func testSignedOutPreviewStartsInItsDeclaredPhase() {
        let model = AuthModel.previewSignedOut(notice: "One-time sign-in required.")

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.signedOutNotice, "One-time sign-in required.")
    }
}

/// The relaunch contract of the real `FirebaseAuthBackend`, proven against a
/// fake secure store and a scripted Identity Toolkit: a saved refresh token is
/// silently exchanged for a fresh session at launch, transient network trouble
/// never destroys the saved session, terminal rejections and explicit
/// sign-out do.
final class FirebaseAuthRestoreTests: XCTestCase {
    private static let configuration = FirebaseAuthConfiguration(
        projectId: "kaisola-test",
        apiKey: "test-api-key-0123456789",
        serverURL: URL(string: "https://auth.kaisola.test/session")!
    )

    private static let savedAccount = AuthAccount(
        uid: "uid-1",
        email: "person@example.com",
        displayName: "Kaisola Person",
        avatarURL: nil
    )

    /// "header.{}.signature" — three JWT pieces whose claims decode to nil
    /// fields, standing in for any fresh ID token.
    private static let freshIDToken = "header.e30.signature"

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
    }

    private static func tokenExchange(rotatingTo refreshToken: String) -> Data {
        json(["id_token": freshIDToken, "refresh_token": refreshToken])
    }

    private static func serverVerification() -> Data {
        json([
            "ok": true,
            "user": ["uid": "uid-1", "email": "person@example.com", "name": "Kaisola Person"],
        ])
    }

    private static func seededStore() async throws -> LockedAuthSecureStore {
        let store = LockedAuthSecureStore()
        try await AuthSessionVault(store: store).save(
            refreshToken: "refresh-1", account: savedAccount
        )
        return store
    }

    @MainActor
    func testRestoreAfterRelaunchSignsBackInFromTheSharedSecureStore() async throws {
        let store = try await Self.seededStore()
        let log = AuthRequestLog()
        // A NEW backend on the same store is the relaunch: nothing survives
        // in memory, only what the secure store carries.
        let relaunched = FirebaseAuthBackend(
            configuration: Self.configuration,
            secureStore: store,
            httpClient: ScriptedAuthHTTPClient { request in
                log.append(request)
                if request.url?.host == "securetoken.googleapis.com" {
                    return (Self.tokenExchange(rotatingTo: "refresh-2"), Self.response(request, status: 200))
                }
                return (Self.serverVerification(), Self.response(request, status: 200))
            }
        )
        let model = AuthModel(backend: relaunched)

        await model.restore()

        XCTAssertEqual(model.phase, .signedIn(Self.savedAccount))
        XCTAssertNil(model.signedOutNotice)
        let vault = AuthSessionVault(store: store)
        let storedToken = try await vault.refreshToken()
        XCTAssertEqual(
            storedToken, "refresh-2",
            "the silent refresh rotates the persisted refresh token"
        )
        XCTAssertTrue(log.requestedHosts.contains("securetoken.googleapis.com"))
    }

    /// The ID token is never persisted, so a relaunch always holds an
    /// (effectively) expired one. Restore must silently exchange the refresh
    /// token for a fresh ID token and authenticate the server check with THAT
    /// token — never sign out, never reuse a stale credential.
    @MainActor
    func testRestoreSilentlyRefreshesTheExpiredIDTokenBeforeServerVerification() async throws {
        let store = try await Self.seededStore()
        let log = AuthRequestLog()
        let backend = FirebaseAuthBackend(
            configuration: Self.configuration,
            secureStore: store,
            httpClient: ScriptedAuthHTTPClient { request in
                log.append(request)
                if request.url?.host == "securetoken.googleapis.com" {
                    return (Self.tokenExchange(rotatingTo: "refresh-2"), Self.response(request, status: 200))
                }
                return (Self.serverVerification(), Self.response(request, status: 200))
            }
        )

        let restored = try await backend.restore()

        XCTAssertEqual(restored, Self.savedAccount)
        XCTAssertEqual(
            log.requests(toHost: "securetoken.googleapis.com").count, 1,
            "restore performs exactly one silent token refresh"
        )
        let verification = log.requests(toHost: "auth.kaisola.test")
        XCTAssertEqual(
            verification.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(Self.freshIDToken)",
            "server verification runs on the freshly refreshed ID token"
        )
    }

    @MainActor
    func testTransientRefreshFailureAtLaunchKeepsTheSavedSession() async throws {
        let store = try await Self.seededStore()
        let backend = FirebaseAuthBackend(
            configuration: Self.configuration,
            secureStore: store,
            httpClient: ScriptedAuthHTTPClient { _ in
                throw URLError(.notConnectedToInternet)
            }
        )
        let model = AuthModel(backend: backend)

        await model.restore()

        XCTAssertEqual(
            model.phase, .signedIn(Self.savedAccount),
            "an offline launch keeps the saved session instead of signing out"
        )
        let vault = AuthSessionVault(store: store)
        let storedToken = try await vault.refreshToken()
        XCTAssertEqual(
            storedToken, "refresh-1",
            "the untouched keychain lets the next launch retry cleanly"
        )
    }

    @MainActor
    func testTerminalRefreshRejectionSignsOutAndClearsTheStore() async throws {
        let store = try await Self.seededStore()
        let backend = FirebaseAuthBackend(
            configuration: Self.configuration,
            secureStore: store,
            httpClient: ScriptedAuthHTTPClient { request in
                (
                    Self.json(["error": ["message": "INVALID_REFRESH_TOKEN"]]),
                    Self.response(request, status: 400)
                )
            }
        )
        let model = AuthModel(backend: backend)

        await model.restore()

        XCTAssertEqual(model.phase, .signedOut)
        let vault = AuthSessionVault(store: store)
        let storedToken = try await vault.refreshToken()
        let storedAccount = try await vault.account()
        XCTAssertNil(storedToken)
        XCTAssertNil(storedAccount)
    }

    @MainActor
    func testExplicitSignOutClearsTheSecureStore() async throws {
        let store = try await Self.seededStore()
        let backend = FirebaseAuthBackend(
            configuration: Self.configuration,
            secureStore: store,
            httpClient: ScriptedAuthHTTPClient { request in
                (Self.serverVerification(), Self.response(request, status: 200))
            }
        )
        let model = AuthModel(backend: backend)

        await model.signOut()

        XCTAssertEqual(model.phase, .signedOut)
        let vault = AuthSessionVault(store: store)
        let storedToken = try await vault.refreshToken()
        let storedAccount = try await vault.account()
        XCTAssertNil(storedToken)
        XCTAssertNil(storedAccount)
    }
}

private struct ScriptedAuthHTTPClient: AuthHTTPClient {
    let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try handler(request)
    }
}

private final class AuthRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { recorded.append(request) }
    }

    var requestedHosts: Set<String> {
        lock.withLock { Set(recorded.compactMap { $0.url?.host }) }
    }

    func requests(toHost host: String) -> [URLRequest] {
        lock.withLock { recorded.filter { $0.url?.host == host } }
    }
}

private struct RestoreFailure: LocalizedError {
    var errorDescription: String? { "Kaisola could not access the saved sign-in." }
}

@MainActor
private final class RestoreFailureAuthBackend: AuthBackend {
    func restore() async throws -> AuthAccount? { throw RestoreFailure() }
    func signInWithGoogle() async throws -> AuthAccount { throw RestoreFailure() }
    func freshIDToken() async throws -> String { throw RestoreFailure() }
    func signOut() async {}
}

@MainActor
private final class RestoreCancellationAuthBackend: AuthBackend {
    func restore() async throws -> AuthAccount? { throw CancellationError() }
    func signInWithGoogle() async throws -> AuthAccount { throw CancellationError() }
    func freshIDToken() async throws -> String { throw CancellationError() }
    func signOut() async {}
}

private final class LockedAuthSecureStore: AuthSecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func set(_ data: Data, for key: String) throws {
        lock.withLock { values[key] = data }
    }

    func removeData(for key: String) throws {
        lock.withLock { _ = values.removeValue(forKey: key) }
    }
}

@MainActor
private final class NoticeAuthBackend: AuthBackend {
    private let account = AuthAccount(
        uid: "account-1",
        email: "person@example.com",
        displayName: "Kaisola Person",
        avatarURL: nil
    )

    func restore() async throws -> AuthAccount? { nil }
    func signInWithGoogle() async throws -> AuthAccount { account }
    func freshIDToken() async throws -> String { "fresh-token" }
    func signOut() async {}
}

/// The legacy-keychain migration must never destroy the only surviving copy
/// of a credential. On an unentitled build the data-protection write is
/// refused and the rewrite silently lands back in the legacy keychain — the
/// exact environment every shipping build runs in — and the old code then
/// deleted the legacy item it had just refreshed: signed in for one session,
/// signed out on the next launch, forever.
final class KeychainAuthMigrationTests: XCTestCase {
    /// Data-protection world empty and unwritable (entitlement refused on
    /// add); legacy world holds the token. The migration read must return the
    /// token AND leave the legacy item standing, because the rewrite landed
    /// legacy.
    func testUnentitledMigrationKeepsTheLegacyItemItRewrote() throws {
        final class World: @unchecked Sendable {
            var legacy: [String: Data] = ["firebase-refresh-token": Data("token".utf8)]
            var deletedLegacy = 0
        }
        let world = World()
        func isDataProtection(_ query: CFDictionary) -> Bool {
            (query as NSDictionary)[kSecUseDataProtectionKeychain as String] as? Bool == true
        }
        func account(_ query: CFDictionary) -> String {
            (query as NSDictionary)[kSecAttrAccount as String] as? String ?? ""
        }
        let operations = KeychainAuthSecurityOperations(
            copyMatching: { query, result in
                if isDataProtection(query) { return errSecItemNotFound }
                guard let data = world.legacy[account(query)] else { return errSecItemNotFound }
                result?.pointee = data as CFTypeRef
                return errSecSuccess
            },
            update: { query, attributes in
                if isDataProtection(query) { return errSecItemNotFound }
                guard world.legacy[account(query)] != nil else { return errSecItemNotFound }
                world.legacy[account(query)] =
                    (attributes as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            },
            add: { query, _ in
                if isDataProtection(query) { return errSecMissingEntitlement }
                world.legacy[account(query)] =
                    (query as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            },
            delete: { query in
                if isDataProtection(query) { return errSecItemNotFound }
                world.deletedLegacy += 1
                world.legacy[account(query)] = nil
                return errSecSuccess
            }
        )
        // The protection refresh is exercised by its own tests below; disabled
        // here so this test keeps pinning the 0.1.136 regression in isolation
        // (an unconditional migration delete with no re-add).
        let store = KeychainAuthSecureStore(
            service: "test.firebase-auth",
            securityOperations: operations,
            legacyRefreshMarker: .disabled
        )

        let data = try store.data(for: "firebase-refresh-token")
        XCTAssertEqual(data, Data("token".utf8))
        XCTAssertEqual(
            world.legacy["firebase-refresh-token"], Data("token".utf8),
            "the rewrite landed in the legacy keychain, so the legacy item is the only copy and must survive"
        )
        XCTAssertEqual(world.deletedLegacy, 0, "nothing may delete the surviving copy")

        // And the next launch still finds it.
        XCTAssertEqual(try store.data(for: "firebase-refresh-token"), Data("token".utf8))
    }

    /// The statuses measured on a real unentitled build (macOS 26): a
    /// data-protection READ answers `errSecItemNotFound` while data-protection
    /// WRITES answer `errSecMissingEntitlement`. A legacy item created by a
    /// pre-Developer-ID binary keeps that binary's ACL/partition forever under
    /// `SecItemUpdate` — the per-update keychain prompt. The one-time refresh
    /// must re-CREATE the item (delete + fresh add, current app as creator)
    /// exactly once, and later launches must not churn.
    func testLegacyProtectionRefreshRecreatesTheItemOnceAcrossLaunches() throws {
        final class World: @unchecked Sendable {
            var legacy: [String: Data] = ["firebase-refresh-token": Data("token".utf8)]
            var legacyDeletes = 0
            var legacyAdds = 0
        }
        final class Marker: @unchecked Sendable {
            var refreshed: Set<String> = []
        }
        let world = World()
        let marker = Marker()
        let markerFacade = KeychainAuthLegacyRefreshMarker(
            needsRefresh: { !marker.refreshed.contains($0) },
            markRefreshed: { marker.refreshed.insert($0) }
        )
        func isDataProtection(_ query: CFDictionary) -> Bool {
            (query as NSDictionary)[kSecUseDataProtectionKeychain as String] as? Bool == true
        }
        func account(_ query: CFDictionary) -> String {
            (query as NSDictionary)[kSecAttrAccount as String] as? String ?? ""
        }
        let operations = KeychainAuthSecurityOperations(
            copyMatching: { query, result in
                if isDataProtection(query) { return errSecItemNotFound }
                guard let data = world.legacy[account(query)] else { return errSecItemNotFound }
                result?.pointee = data as CFTypeRef
                return errSecSuccess
            },
            update: { query, attributes in
                if isDataProtection(query) { return errSecMissingEntitlement }
                guard world.legacy[account(query)] != nil else { return errSecItemNotFound }
                world.legacy[account(query)] =
                    (attributes as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            },
            add: { query, _ in
                if isDataProtection(query) { return errSecMissingEntitlement }
                world.legacyAdds += 1
                world.legacy[account(query)] =
                    (query as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            },
            delete: { query in
                if isDataProtection(query) { return errSecItemNotFound }
                guard world.legacy[account(query)] != nil else { return errSecItemNotFound }
                world.legacyDeletes += 1
                world.legacy[account(query)] = nil
                return errSecSuccess
            }
        )

        // Launch one: the read succeeds AND re-creates the item once.
        let store = KeychainAuthSecureStore(
            service: "test.firebase-auth",
            securityOperations: operations,
            legacyRefreshMarker: markerFacade
        )
        XCTAssertEqual(try store.data(for: "firebase-refresh-token"), Data("token".utf8))
        XCTAssertEqual(world.legacyDeletes, 1, "the stale item is deleted exactly once")
        XCTAssertEqual(world.legacyAdds, 1, "and re-created exactly once, fresh creator ACL")
        XCTAssertEqual(
            world.legacy["firebase-refresh-token"], Data("token".utf8),
            "the credential survives the re-creation byte for byte"
        )
        XCTAssertTrue(marker.refreshed.contains("firebase-refresh-token"))

        // Launch two (fresh store, fresh process fallback state): reads keep
        // working with zero further delete/add churn.
        let relaunched = KeychainAuthSecureStore(
            service: "test.firebase-auth",
            securityOperations: operations,
            legacyRefreshMarker: markerFacade
        )
        XCTAssertEqual(try relaunched.data(for: "firebase-refresh-token"), Data("token".utf8))
        XCTAssertEqual(world.legacyDeletes, 1, "the refresh is one-time")
        XCTAssertEqual(world.legacyAdds, 1)
    }

    /// A refresh whose re-add is refused must not cost the only copy: the
    /// credential goes back through the ordinary write path, the caller still
    /// gets its data, and the item stands afterwards.
    func testFailedRefreshReaddRestoresTheCredentialThroughTheWritePath() throws {
        final class World: @unchecked Sendable {
            var legacy: [String: Data] = ["firebase-refresh-token": Data("token".utf8)]
            var legacyAddAttempts = 0
            var failFirstLegacyAdd = true
        }
        final class Marker: @unchecked Sendable {
            var refreshed: Set<String> = []
        }
        let world = World()
        let marker = Marker()
        let markerFacade = KeychainAuthLegacyRefreshMarker(
            needsRefresh: { !marker.refreshed.contains($0) },
            markRefreshed: { marker.refreshed.insert($0) }
        )
        func isDataProtection(_ query: CFDictionary) -> Bool {
            (query as NSDictionary)[kSecUseDataProtectionKeychain as String] as? Bool == true
        }
        func account(_ query: CFDictionary) -> String {
            (query as NSDictionary)[kSecAttrAccount as String] as? String ?? ""
        }
        let operations = KeychainAuthSecurityOperations(
            copyMatching: { query, result in
                if isDataProtection(query) { return errSecItemNotFound }
                guard let data = world.legacy[account(query)] else { return errSecItemNotFound }
                result?.pointee = data as CFTypeRef
                return errSecSuccess
            },
            update: { query, attributes in
                if isDataProtection(query) { return errSecMissingEntitlement }
                guard world.legacy[account(query)] != nil else { return errSecItemNotFound }
                world.legacy[account(query)] =
                    (attributes as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            },
            add: { query, _ in
                if isDataProtection(query) { return errSecMissingEntitlement }
                world.legacyAddAttempts += 1
                if world.failFirstLegacyAdd {
                    world.failFirstLegacyAdd = false
                    return errSecInteractionNotAllowed
                }
                world.legacy[account(query)] =
                    (query as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            },
            delete: { query in
                if isDataProtection(query) { return errSecItemNotFound }
                world.legacy[account(query)] = nil
                return errSecSuccess
            }
        )

        let store = KeychainAuthSecureStore(
            service: "test.firebase-auth",
            securityOperations: operations,
            legacyRefreshMarker: markerFacade
        )
        XCTAssertEqual(try store.data(for: "firebase-refresh-token"), Data("token".utf8))
        XCTAssertEqual(
            world.legacy["firebase-refresh-token"], Data("token".utf8),
            "the refused re-add fell back through the write path; the credential survives"
        )
        XCTAssertEqual(world.legacyAddAttempts, 2, "refresh add refused, write-path add landed")
        XCTAssertTrue(
            marker.refreshed.contains("firebase-refresh-token"),
            "the write path's fresh add is itself the refreshed item"
        )
    }
}
