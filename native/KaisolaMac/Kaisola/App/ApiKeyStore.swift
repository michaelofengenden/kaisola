import Foundation
import Security

/// Direct-API credentials (Anthropic, OpenAI) stored as macOS Keychain generic
/// passwords and injected into agent terminals/chats. Electron parity: the
/// Electron app keeps the same two keys (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`)
/// and injects them into agent processes; here they live in the Keychain instead
/// of a safeStorage-encrypted file, keyed by service + key name.
///
/// The store never surfaces a stored value to the UI beyond "is it set" — reads
/// are only used to build the process environment overlay and the set/not-set
/// state. Items are this-device-only and available after first unlock, written to
/// the data-protection keychain so the accessibility class actually applies on
/// macOS (the legacy file keychain ignores it).
struct ApiKeyStore {
    /// A named secret. The raw value is the environment variable the agent
    /// process expects, and also the Keychain account under the shared service.
    enum Key: String, CaseIterable, Sendable {
        case anthropic = "ANTHROPIC_API_KEY"
        case openai = "OPENAI_API_KEY"

        /// Human-readable provider name for the settings row.
        var title: String {
            switch self {
            case .anthropic: "Anthropic"
            case .openai: "OpenAI"
            }
        }
    }

    /// Default Keychain service. The legacy namespace is retained so existing
    /// native installs keep their credentials through the production cutover.
    static let defaultService = "com.kaisola.mac.preview.api-keys"

    private let service: String

    /// - Parameter service: Keychain service to scope items under. Defaults to
    ///   the continuity service; tests pass a throwaway name so they never
    ///   touch the real credentials.
    init(service: String = ApiKeyStore.defaultService) {
        self.service = service
    }

    // MARK: - Reads (never throw)

    /// The stored value for `key`, or nil if unset or on any Keychain error.
    /// Reads are best-effort by design: a missing item, a locked keychain, or a
    /// missing entitlement all read as "no key" rather than surfacing an error.
    func read(_ key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    /// Environment overlay contributed by these credentials — only keys that are
    /// actually set (non-empty). Merged into agent process environments.
    func environmentOverlay() -> [String: String] {
        var env: [String: String] = [:]
        for key in Key.allCases {
            if let value = read(key) {
                env[key.rawValue] = value
            }
        }
        return env
    }

    // MARK: - Writes (throw a readable NSError)

    /// Store (or replace) `value` for `key`. A blank value (after trimming)
    /// deletes the item — an empty field means "no key", matching the UI. Throws
    /// an NSError with a human-readable message when the Keychain refuses.
    func write(_ key: Key, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(key)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw error(errSecParam, "Could not encode the \(key.title) key.")
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Update in place if present, otherwise add — keeps a single item per key.
        var status = SecItemUpdate(baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery(for: key)
            for (attribute, attributeValue) in attributes { addQuery[attribute] = attributeValue }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw error(status, "Could not save the \(key.title) key to the Keychain.")
        }
    }

    /// Remove `key`. Idempotent: deleting an absent item is a no-op, and any
    /// Keychain error is swallowed (nothing the user can act on).
    func delete(_ key: Key) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    // MARK: - Internals

    private func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            // Use the modern keychain so kSecAttrAccessible is honored on macOS
            // and no interactive ACL prompt appears for the app's own items.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func error(_ status: OSStatus, _ message: String) -> NSError {
        let detail = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return NSError(
            domain: ApiKeyStore.defaultService,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(message) (\(detail))"]
        )
    }
}
