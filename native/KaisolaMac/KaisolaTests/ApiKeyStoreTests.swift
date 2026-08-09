import XCTest
@testable import Kaisola

/// The Keychain-backed API key store: write/read round-trips, overwrite,
/// empty-write-deletes, idempotent delete, and an environment overlay that only
/// carries keys that are actually set.
///
/// Every test runs under a unique throwaway service so it never touches the real
/// `com.kaisola.mac.preview.api-keys` credentials, and tearDown wipes it. On a
/// signing-free CI test host the data-protection keychain can refuse writes with
/// errSecMissingEntitlement — those runs skip rather than fail.
final class ApiKeyStoreTests: XCTestCase {
    private var service = ""
    private var store = ApiKeyStore()

    override func setUp() {
        super.setUp()
        service = "com.kaisola.mac.preview.api-keys.test-\(UUID().uuidString)"
        store = ApiKeyStore(service: service)
    }

    override func tearDown() {
        for key in ApiKeyStore.Key.allCases { store.delete(key) }
        super.tearDown()
    }

    /// Probe a write/delete round-trip; skip the whole test when the keychain is
    /// unavailable in this host (errSecMissingEntitlement on unsigned CI runners).
    private func requireKeychain() throws {
        do {
            try store.write(.anthropic, value: "probe")
            store.delete(.anthropic)
        } catch let error as NSError where error.code == Int(errSecMissingEntitlement) {
            throw XCTSkip("Keychain generic passwords unavailable in this test host (errSecMissingEntitlement).")
        }
    }

    func testWriteReadRoundTrip() throws {
        try requireKeychain()
        XCTAssertNil(store.read(.anthropic))
        try store.write(.anthropic, value: "sk-ant-abc123")
        XCTAssertEqual(store.read(.anthropic), "sk-ant-abc123")
    }

    func testWriteTrimsWhitespace() throws {
        try requireKeychain()
        try store.write(.openai, value: "  sk-openai-xyz\n")
        XCTAssertEqual(store.read(.openai), "sk-openai-xyz")
    }

    func testOverwriteReplacesValue() throws {
        try requireKeychain()
        try store.write(.openai, value: "sk-first")
        try store.write(.openai, value: "sk-second")
        XCTAssertEqual(store.read(.openai), "sk-second")
    }

    func testEmptyWriteDeletes() throws {
        try requireKeychain()
        try store.write(.anthropic, value: "sk-ant-abc123")
        XCTAssertNotNil(store.read(.anthropic))
        // A blank field means "no key" — writing it removes the stored item.
        try store.write(.anthropic, value: "   ")
        XCTAssertNil(store.read(.anthropic))
    }

    func testDeleteIsIdempotent() throws {
        try requireKeychain()
        // Deleting an absent key is a no-op.
        store.delete(.openai)
        store.delete(.openai)
        XCTAssertNil(store.read(.openai))
        // And deleting twice after a write leaves it absent, no error.
        try store.write(.openai, value: "sk-openai")
        store.delete(.openai)
        store.delete(.openai)
        XCTAssertNil(store.read(.openai))
    }

    func testEnvironmentOverlayContainsOnlySetKeys() throws {
        try requireKeychain()
        XCTAssertTrue(store.environmentOverlay().isEmpty)

        try store.write(.anthropic, value: "sk-ant")
        XCTAssertEqual(store.environmentOverlay(), ["ANTHROPIC_API_KEY": "sk-ant"])

        try store.write(.openai, value: "sk-oa")
        XCTAssertEqual(
            store.environmentOverlay(),
            ["ANTHROPIC_API_KEY": "sk-ant", "OPENAI_API_KEY": "sk-oa"]
        )

        try store.write(.anthropic, value: "")
        XCTAssertEqual(store.environmentOverlay(), ["OPENAI_API_KEY": "sk-oa"])
    }

    func testKeyRawValuesAreTheAgentEnvVars() {
        // These raw values are the environment variables injected into agents;
        // they must not drift.
        XCTAssertEqual(ApiKeyStore.Key.anthropic.rawValue, "ANTHROPIC_API_KEY")
        XCTAssertEqual(ApiKeyStore.Key.openai.rawValue, "OPENAI_API_KEY")
        XCTAssertEqual(ApiKeyStore.Key.allCases.count, 2)
    }

    func testSettingsKeyFormatWarningsAreSoftAndProviderSpecific() {
        XCTAssertNil(ApiKeyFormatPolicy.warning(
            for: .anthropic,
            value: "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
        ))
        XCTAssertNil(ApiKeyFormatPolicy.warning(
            for: .openai,
            value: "sk-proj-abcdefghijklmnopqrstuvwxyz"
        ))
        XCTAssertEqual(
            ApiKeyFormatPolicy.warning(for: .anthropic, value: "sk-wrong-abcdefghijklmnopqrstuvwxyz"),
            "Anthropic API keys usually begin with sk-ant-."
        )
        XCTAssertEqual(
            ApiKeyFormatPolicy.warning(for: .openai, value: "not-an-openai-key"),
            "OpenAI API keys usually begin with sk-."
        )
        XCTAssertEqual(
            ApiKeyFormatPolicy.warning(for: .openai, value: "sk-short"),
            "This API key looks unusually short."
        )
        XCTAssertEqual(
            ApiKeyFormatPolicy.warning(for: .anthropic, value: "sk-ant-api03-has a-space"),
            "API keys normally do not contain spaces or line breaks."
        )
    }

    func testOpenAIProbeUsesNoPromptModelsEndpointAndBearerAuthentication() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ApiKeyProbeURLProtocol.self]
        ApiKeyProbeURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-openai")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            XCTAssertNil(request.httpBody, "a credential check must never send a prompt body")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"object":"list","data":[{"id":"fixture"}]}"#.utf8)
            )
        }
        defer { ApiKeyProbeURLProtocol.handler = nil }
        let service = ApiKeyProbeService(session: URLSession(configuration: configuration))

        let result = await service.probe(
            key: .openai,
            value: "sk-test-openai",
            configuredBaseURL: ""
        )

        XCTAssertEqual(result, .init(status: .ready, message: "Verified with OpenAI."))
    }

    func testAnthropicProbeUsesVersionedBoundedModelsRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ApiKeyProbeURLProtocol.self]
        ApiKeyProbeURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://gateway.example.test/v1/models?limit=1"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"data":[{"id":"claude-fixture","type":"model"}],"has_more":false}"#.utf8)
            )
        }
        defer { ApiKeyProbeURLProtocol.handler = nil }
        let service = ApiKeyProbeService(session: URLSession(configuration: configuration))

        let result = await service.probe(
            key: .anthropic,
            value: "sk-ant-test",
            configuredBaseURL: "https://gateway.example.test/v1/"
        )

        XCTAssertEqual(result, .init(status: .ready, message: "Verified with Anthropic."))
    }

    func testRejectedKeyDoesNotEchoProviderBodyOrCredential() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ApiKeyProbeURLProtocol.self]
        ApiKeyProbeURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"error":{"message":"secret-bearing upstream diagnostic"}}"#.utf8)
            )
        }
        defer { ApiKeyProbeURLProtocol.handler = nil }
        let service = ApiKeyProbeService(session: URLSession(configuration: configuration))

        let result = await service.probe(
            key: .openai,
            value: "sk-never-echo-this",
            configuredBaseURL: ""
        )

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.message, "OpenAI rejected this API key.")
        XCTAssertFalse(result.message.contains("secret-bearing"))
        XCTAssertFalse(result.message.contains("sk-never"))
    }

    func testInvalidCustomBaseURLFailsBeforeNetwork() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ApiKeyProbeURLProtocol.self]
        ApiKeyProbeURLProtocol.handler = { _ in
            XCTFail("an invalid route must fail before opening a connection")
            throw URLError(.badURL)
        }
        defer { ApiKeyProbeURLProtocol.handler = nil }
        let service = ApiKeyProbeService(session: URLSession(configuration: configuration))

        let result = await service.probe(
            key: .anthropic,
            value: "sk-ant-test",
            configuredBaseURL: "http://remote.example.test"
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.message, "Fix the provider Base URL before testing.")
    }
}

/// Required-host coverage for the data-protection Keychain boundaries that the
/// ordinary unsigned test lane deliberately skips. The dedicated workflow sets
/// `KAISOLA_REQUIRE_KEYCHAIN_BOUNDARIES=1`; without it the two physical tests
/// remain an explicit lightweight-lane skip rather than touching a developer's
/// login Keychain.
final class KeychainBoundaryTests: XCTestCase {
    private static let requiredEnvironment = "KAISOLA_REQUIRE_KEYCHAIN_BOUNDARIES"
    private static let isolationEnvironment = "KAISOLA_KEYCHAIN_BOUNDARY_ISOLATION"
    private static let requiredIsolation = "github-hosted-ephemeral-vm"

    func testAPIKeyRoundTripOverwriteTrimDeleteAndServiceIsolation() throws {
        try requireEntitledBoundaryLane()
        let firstService = "com.kaisola.mac.api-key-boundary.first-\(UUID().uuidString)"
        let secondService = "com.kaisola.mac.api-key-boundary.second-\(UUID().uuidString)"
        let first = ApiKeyStore(service: firstService)
        let second = ApiKeyStore(service: secondService)
        defer {
            for key in ApiKeyStore.Key.allCases {
                first.delete(key)
                second.delete(key)
            }
        }

        try first.write(.anthropic, value: "  fixture-first  \n")
        try second.write(.anthropic, value: "fixture-second")
        XCTAssertEqual(first.read(.anthropic), "fixture-first")
        XCTAssertEqual(second.read(.anthropic), "fixture-second")

        try first.write(.anthropic, value: "fixture-overwrite")
        XCTAssertEqual(first.read(.anthropic), "fixture-overwrite")
        XCTAssertEqual(second.read(.anthropic), "fixture-second")

        try first.write(.openai, value: "fixture-provider-switch")
        XCTAssertEqual(
            first.environmentOverlay(),
            [
                "ANTHROPIC_API_KEY": "fixture-overwrite",
                "OPENAI_API_KEY": "fixture-provider-switch",
            ]
        )

        try first.write(.anthropic, value: "  \n")
        XCTAssertNil(first.read(.anthropic))
        XCTAssertEqual(first.read(.openai), "fixture-provider-switch")
        XCTAssertEqual(second.read(.anthropic), "fixture-second")

        first.delete(.openai)
        second.delete(.anthropic)
        XCTAssertEqual(
            keychainStatus(service: firstService, account: ApiKeyStore.Key.openai.rawValue),
            errSecItemNotFound
        )
        XCTAssertEqual(
            keychainStatus(service: secondService, account: ApiKeyStore.Key.anthropic.rawValue),
            errSecItemNotFound
        )
    }

    func testAPIKeyErrorMappingIsActionableAndSecretFree() {
        let error = ApiKeyStore.keychainError(
            errSecInteractionNotAllowed,
            message: "Could not save the OpenAI key to the Keychain."
        )

        XCTAssertEqual(error.domain, ApiKeyStore.defaultService)
        XCTAssertEqual(error.code, Int(errSecInteractionNotAllowed))
        XCTAssertTrue(error.localizedDescription.contains("Could not save the OpenAI key"))
        XCTAssertTrue(error.localizedDescription.contains("interaction"))
        XCTAssertFalse(error.localizedDescription.contains("fixture-secret-value"))
    }

    func testCompanionIdentityIsStableAndPrivateItemsNeverSynchronize() throws {
        try requireEntitledBoundaryLane()
        let service = "com.kaisola.mac.companion-boundary-\(UUID().uuidString)"
        let store = CompanionIdentityStore(service: service)
        defer { store.deleteAll() }

        let first = try store.loadOrCreate(displayName: "Boundary Mac")
        let reopened = try store.loadOrCreate(displayName: "Renamed Boundary Mac")
        XCTAssertEqual(first.id, reopened.id)
        XCTAssertEqual(first.identityPublic, reopened.identityPublic)
        XCTAssertEqual(first.x25519StaticPublic, reopened.x25519StaticPublic)

        for account in CompanionIdentityStore.Account.allCases {
            let attributes = try keychainAttributes(service: service, account: account.rawValue)
            XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(
                attributes[kSecAttrAccessible as String] as? String,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
        }

        store.deleteAll()
        for account in CompanionIdentityStore.Account.allCases {
            XCTAssertEqual(
                keychainStatus(service: service, account: account.rawValue),
                errSecItemNotFound
            )
        }
    }

    private func requireEntitledBoundaryLane() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[Self.requiredEnvironment] == "1",
              environment[Self.isolationEnvironment] == Self.requiredIsolation
        else {
            throw XCTSkip("Entitled Keychain boundaries run only in the dedicated signed lane.")
        }
    }

    private func keychainStatus(service: String, account: String) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    private func keychainAttributes(service: String, account: String) throws -> [String: Any] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let attributes = item as? [String: Any] else {
            throw NSError(
                domain: ApiKeyStore.defaultService,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not inspect throwaway Keychain attributes."]
            )
        }
        return attributes
    }
}

private final class ApiKeyProbeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.resourceUnavailable) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
