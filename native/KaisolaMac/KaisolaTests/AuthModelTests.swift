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
        let store = KeychainAuthSecureStore(
            service: "test.firebase-auth",
            securityOperations: operations
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
}
