import KaisolaCore
import Foundation
import XCTest
@testable import KaisolaCompanion

final class FirebaseAuthBackendTests: XCTestCase {
    func testMissingEntitlementRetriesDataProtectionOnceThenFailsClosedOnLegacy() {
        let fallback = KeychainAuthFallbackState()

        XCTAssertEqual(fallback.queryMode, .dataProtection)
        XCTAssertEqual(
            fallback.retryMode(afterMissingEntitlementIn: .dataProtection),
            .legacy
        )
        XCTAssertEqual(fallback.queryMode, .legacy)
        XCTAssertNil(fallback.retryMode(afterMissingEntitlementIn: .legacy))
    }

    func testStaleDataProtectionAttemptCanJoinAnActivatedLegacyFallback() {
        let fallback = KeychainAuthFallbackState()

        XCTAssertEqual(
            fallback.retryMode(afterMissingEntitlementIn: .dataProtection),
            .legacy
        )
        XCTAssertEqual(
            fallback.retryMode(afterMissingEntitlementIn: .dataProtection),
            .legacy
        )
        XCTAssertEqual(fallback.queryMode, .legacy)
    }

    func testKeychainReadStopsAfterDataProtectionAndLegacyBothLackEntitlement() {
        let security = MissingEntitlementSecurityOperations()
        let store = KeychainAuthSecureStore(
            service: "test.read",
            securityOperations: security.operations
        )

        XCTAssertThrowsError(try store.data(for: "account"))
        XCTAssertEqual(security.copyMatchingCount, 2)
    }

    func testKeychainWriteStopsAfterDataProtectionAndLegacyBothLackEntitlement() {
        let security = MissingEntitlementSecurityOperations()
        let store = KeychainAuthSecureStore(
            service: "test.write",
            securityOperations: security.operations
        )

        XCTAssertThrowsError(try store.set(Data("value".utf8), for: "account"))
        XCTAssertEqual(security.updateCount, 2)
        XCTAssertEqual(security.addCount, 0)
    }

    func testKeychainDeleteStopsAfterDataProtectionAndLegacyBothLackEntitlement() {
        let security = MissingEntitlementSecurityOperations()
        let store = KeychainAuthSecureStore(
            service: "test.delete",
            securityOperations: security.operations
        )

        XCTAssertThrowsError(try store.removeData(for: "account"))
        XCTAssertEqual(security.deleteCount, 2)
    }

    func testConfigurationParsesBundledShape() throws {
        let data = Data(#"""
        {
          "projectId": "kaisola-a9ab7",
          "apiKey": "AIzaSyAiqyY5bzsa7j5E1rP-iKYXaQFH8iFUJwY",
          "serverUrl": "https://us-central1-kaisola-a9ab7.cloudfunctions.net/session",
          "relayUrl": "https://kaisola-link.example.workers.dev"
        }
        """#.utf8)

        let configuration = try FirebaseAuthConfiguration.parse(data)

        XCTAssertEqual(configuration.projectId, "kaisola-a9ab7")
        XCTAssertEqual(configuration.apiKey, "AIzaSyAiqyY5bzsa7j5E1rP-iKYXaQFH8iFUJwY")
        XCTAssertEqual(
            configuration.serverURL,
            URL(string: "https://us-central1-kaisola-a9ab7.cloudfunctions.net/session")
        )
        XCTAssertEqual(configuration.relayURL, URL(string: "https://kaisola-link.example.workers.dev"))
    }

    func testConfigurationRejectsNonHTTPSVerificationServer() {
        let data = Data(#"""
        {
          "projectId": "kaisola-a9ab7",
          "apiKey": "AIzaSyAiqyY5bzsa7j5E1rP-iKYXaQFH8iFUJwY",
          "serverUrl": "http://localhost/session"
        }
        """#.utf8)

        XCTAssertThrowsError(try FirebaseAuthConfiguration.parse(data))
    }

    func testConfigurationRejectsNonHTTPSRelay() {
        let data = Data(#"""
        {
          "projectId": "kaisola-a9ab7",
          "apiKey": "AIzaSyAiqyY5bzsa7j5E1rP-iKYXaQFH8iFUJwY",
          "serverUrl": "https://us-central1-kaisola-a9ab7.cloudfunctions.net/session",
          "relayUrl": "http://link.example"
        }
        """#.utf8)

        XCTAssertThrowsError(try FirebaseAuthConfiguration.parse(data))
    }

    private let callbackURI = URL(string: "kaisola://auth")!
    private let continueURI = URL(string: "https://kaisola-a9ab7.web.app/companion-auth")!

    func testCallbackParsesRawPostBodyForIdentityToolkit() throws {
        let callback = try FirebaseAuthCallback.parse(
            try XCTUnwrap(URL(string: "kaisola://auth?code=a%2Bb%3D&state=state-123")),
            expectedCallback: callbackURI,
            continueURI: continueURI
        )

        // signInWithIdp keys on the https continue URI Firebase redirected to.
        XCTAssertEqual(callback.requestURI, "https://kaisola-a9ab7.web.app/companion-auth")
        XCTAssertEqual(callback.postBody, "code=a%2Bb%3D&state=state-123")
    }

    func testCallbackRejectsAURLOutsideTheRegisteredScheme() throws {
        XCTAssertThrowsError(
            try FirebaseAuthCallback.parse(
                try XCTUnwrap(URL(string: "attacker://auth?code=stolen")),
                expectedCallback: callbackURI,
                continueURI: continueURI
            )
        )
    }

    func testCallbackMapsGoogleAccessDeniedToCancellation() throws {
        XCTAssertThrowsError(
            try FirebaseAuthCallback.parse(
                try XCTUnwrap(URL(string: "kaisola://auth?error=access_denied")),
                expectedCallback: callbackURI,
                continueURI: continueURI
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSessionVaultRoundTripsAndClearsThroughMockSecureStore() async throws {
        let store = InMemoryAuthSecureStore()
        let vault = AuthSessionVault(store: store)
        let account = AuthAccount(
            uid: "firebase-uid",
            email: "person@example.com",
            displayName: "Kaisola Person",
            avatarURL: URL(string: "https://example.com/avatar.png")
        )

        try await vault.save(refreshToken: "refresh-token-only", account: account)

        let restoredToken = try await vault.refreshToken()
        let restoredAccount = try await vault.account()
        XCTAssertEqual(restoredToken, "refresh-token-only")
        XCTAssertEqual(restoredAccount, account)
        XCTAssertEqual(store.values.count, 2)

        try await vault.clear()

        let clearedToken = try await vault.refreshToken()
        let clearedAccount = try await vault.account()
        XCTAssertNil(clearedToken)
        XCTAssertNil(clearedAccount)
        XCTAssertTrue(store.values.isEmpty)
    }
}

private final class MissingEntitlementSecurityOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = ["copy": 0, "update": 0, "add": 0, "delete": 0]

    lazy var operations = KeychainAuthSecurityOperations(
        copyMatching: { [weak self] _, _ in
            self?.increment("copy")
            return errSecMissingEntitlement
        },
        update: { [weak self] _, _ in
            self?.increment("update")
            return errSecMissingEntitlement
        },
        add: { [weak self] _, _ in
            self?.increment("add")
            return errSecMissingEntitlement
        },
        delete: { [weak self] _ in
            self?.increment("delete")
            return errSecMissingEntitlement
        }
    )

    var copyMatchingCount: Int { count("copy") }
    var updateCount: Int { count("update") }
    var addCount: Int { count("add") }
    var deleteCount: Int { count("delete") }

    private func increment(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[key, default: 0] += 1
    }

    private func count(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key, default: 0]
    }
}

private final class InMemoryAuthSecureStore: AuthSecureStoring, @unchecked Sendable {
    var values: [String: Data] = [:]

    func data(for key: String) throws -> Data? {
        values[key]
    }

    func set(_ data: Data, for key: String) throws {
        values[key] = data
    }

    func removeData(for key: String) throws {
        values.removeValue(forKey: key)
    }
}
