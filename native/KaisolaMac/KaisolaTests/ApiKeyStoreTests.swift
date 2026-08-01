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
