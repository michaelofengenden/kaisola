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
