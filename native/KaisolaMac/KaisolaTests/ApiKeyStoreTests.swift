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
}
