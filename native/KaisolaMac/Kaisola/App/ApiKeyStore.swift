import Foundation
import Security

/// Direct-API credentials (Anthropic, OpenAI) stored as macOS Keychain generic
/// passwords and injected into agent terminals/chats. Electron parity: the
/// Electron app keeps the same two keys (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`)
/// and injects them into agent processes; here they live in the Keychain instead
/// of a safeStorage-encrypted file, keyed by service + provider-scoped account.
///
/// The store never surfaces a stored value to the UI beyond "is it set" — reads
/// are only used to build the process environment overlay and the set/not-set
/// state. Items are this-device-only and available after first unlock, written to
/// the data-protection keychain so the accessibility class actually applies on
/// macOS (the legacy file keychain ignores it).
struct ApiKeyStore {
    /// A named secret. The raw value is the environment variable the agent
    /// process expects. Older builds also used it as the Keychain account; new
    /// writes use the stable, provider-scoped account identifier below.
    enum Key: String, CaseIterable, Sendable {
        case anthropic = "ANTHROPIC_API_KEY"
        case openai = "OPENAI_API_KEY"

        /// Stable Keychain account tag. This is intentionally separate from the
        /// environment variable so process-facing names cannot silently become
        /// storage identities.
        var accountIdentifier: String {
            switch self {
            case .anthropic: "provider.anthropic.api-key"
            case .openai: "provider.openai.api-key"
            }
        }

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

    /// Keychain service/account identifiers are deliberately compact ASCII.
    /// This keeps identifiers inspectable and rejects Unicode lookalikes before
    /// they can create a second, visually indistinguishable credential record.
    static let maximumIdentifierBytes = 128

    struct LegacyMigration: Equatable, Sendable {
        let sourceService: String
        let sourceAccount: String
        let destinationService: String
        let destinationAccount: String
    }

    /// Injectable Keychain seam. Production uses Security.framework; unit tests
    /// use an in-memory implementation so rejection and migration races can be
    /// proved without touching any real credential store.
    struct KeychainAccess: Sendable {
        let read: @Sendable (_ service: String, _ account: String) -> (OSStatus, Data?)
        let insert: @Sendable (_ service: String, _ account: String, _ data: Data) -> OSStatus
        let upsert: @Sendable (_ service: String, _ account: String, _ data: Data) -> OSStatus
        let delete: @Sendable (_ service: String, _ account: String) -> OSStatus

        static let live = KeychainAccess(
            read: { service, account in
                var query = ApiKeyStore.baseQuery(service: service, account: account)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                return (status, item as? Data)
            },
            insert: { service, account, data in
                var query = ApiKeyStore.baseQuery(service: service, account: account)
                query[kSecValueData as String] = data
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                return SecItemAdd(query as CFDictionary, nil)
            },
            upsert: { service, account, data in
                let query = ApiKeyStore.baseQuery(service: service, account: account)
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                if status == errSecItemNotFound {
                    var addQuery = query
                    for (attribute, value) in attributes { addQuery[attribute] = value }
                    status = SecItemAdd(addQuery as CFDictionary, nil)
                    // A concurrent writer can win between update and add. In
                    // that case retry the intended overwrite rather than report
                    // a false failure or leave the older value in place.
                    if status == errSecDuplicateItem {
                        status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                    }
                }
                return status
            },
            delete: { service, account in
                SecItemDelete(ApiKeyStore.baseQuery(service: service, account: account) as CFDictionary)
            }
        )
    }

    private let service: String
    private let keychain: KeychainAccess

    /// - Parameter service: Keychain service to scope items under. Defaults to
    ///   the continuity service; tests pass a throwaway name so they never
    ///   touch the real credentials.
    init(
        service: String = ApiKeyStore.defaultService,
        keychain: KeychainAccess = .live
    ) {
        self.service = service
        self.keychain = keychain
    }

    // MARK: - Reads (never throw)

    /// The stored value for `key`, or nil if unset or on any Keychain error.
    /// Reads are best-effort by design: a missing item, a locked keychain, or a
    /// missing entitlement all read as "no key" rather than surfacing an error.
    func read(_ key: Key) -> String? {
        guard let migration = migration(for: key) else {
            return nil
        }

        let canonical = keychain.read(migration.destinationService, migration.destinationAccount)
        if canonical.0 == errSecSuccess {
            // A present canonical record is authoritative, even if corrupt. Do
            // not fall back to a legacy record and create ambiguous ownership.
            return Self.decodeCredential(canonical.1)
        }
        guard canonical.0 == errSecItemNotFound else { return nil }

        let legacy = keychain.read(migration.sourceService, migration.sourceAccount)
        guard legacy.0 == errSecSuccess,
              let legacyData = legacy.1,
              let legacyValue = Self.decodeCredential(legacyData)
        else {
            return nil
        }

        let migrationStatus = keychain.insert(
            migration.destinationService,
            migration.destinationAccount,
            legacyData
        )
        switch migrationStatus {
        case errSecSuccess:
            // Delete only after the canonical insert has durably succeeded.
            // A failed cleanup merely leaves a harmless legacy fallback record.
            _ = keychain.delete(migration.sourceService, migration.sourceAccount)
            return legacyValue
        case errSecDuplicateItem:
            // A concurrent canonical writer won. Its value is authoritative and
            // the legacy record stays intact until ownership is unambiguous.
            let winner = keychain.read(
                migration.destinationService,
                migration.destinationAccount
            )
            guard winner.0 == errSecSuccess else { return nil }
            return Self.decodeCredential(winner.1)
        default:
            // Migration is opportunistic: retain and return the last-known-good
            // legacy value rather than turning a write failure into key loss.
            return legacyValue
        }
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
        guard let migration = migration(for: key) else {
            throw Self.keychainError(
                errSecParam,
                message: "Could not save the \(key.title) key because its credential identifier is invalid."
            )
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(key)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw Self.keychainError(errSecParam, message: "Could not encode the \(key.title) key.")
        }

        let status = keychain.upsert(
            migration.destinationService,
            migration.destinationAccount,
            data
        )
        guard status == errSecSuccess else {
            throw Self.keychainError(
                status,
                message: "Could not save the \(key.title) key to the Keychain."
            )
        }

        // A canonical write has become the sole owner; legacy cleanup is safe
        // and intentionally best-effort.
        _ = keychain.delete(migration.sourceService, migration.sourceAccount)
    }

    /// Remove `key`. Idempotent: deleting an absent item is a no-op, and any
    /// Keychain error is swallowed (nothing the user can act on).
    func delete(_ key: Key) {
        guard let migration = migration(for: key) else { return }
        // Remove the fallback first. If a read overlaps deletion, it can never
        // resurrect the legacy value after the canonical record is gone.
        _ = keychain.delete(migration.sourceService, migration.sourceAccount)
        _ = keychain.delete(migration.destinationService, migration.destinationAccount)
    }

    // MARK: - Internals

    /// Returns a secret-free reason when an identifier is unsafe. Accepted
    /// identifiers are printable ASCII letters/digits plus `.`, `-`, and `_`,
    /// bounded in UTF-8 bytes and anchored by an alphanumeric character.
    static func identifierIssue(_ identifier: String) -> String? {
        let bytes = identifier.utf8
        guard !bytes.isEmpty else { return "Credential identifiers cannot be empty." }
        guard bytes.count <= maximumIdentifierBytes else {
            return "Credential identifiers are too long."
        }
        guard bytes.allSatisfy(Self.isAllowedIdentifierByte) else {
            return "Credential identifiers must use printable ASCII letters, digits, dots, dashes, or underscores."
        }
        guard let first = bytes.first,
              let last = bytes.last,
              Self.isASCIIAlphanumeric(first),
              Self.isASCIIAlphanumeric(last) else {
            return "Credential identifiers must begin and end with a letter or digit."
        }
        return nil
    }

    /// Reject identifiers that are individually malformed or collapse onto the
    /// same case/punctuation-insensitive identity. The latter prevents visually
    /// near-identical provider tags from silently owning different credentials.
    static func validateAccountIdentifiers(_ identifiers: [String]) throws {
        var identities: Set<String> = []
        for identifier in identifiers {
            if let issue = identifierIssue(identifier) {
                throw NSError(
                    domain: defaultService,
                    code: Int(errSecParam),
                    userInfo: [NSLocalizedDescriptionKey: issue]
                )
            }
            let identity = collisionIdentity(for: identifier)
            guard identities.insert(identity).inserted else {
                throw NSError(
                    domain: defaultService,
                    code: Int(errSecDuplicateItem),
                    userInfo: [NSLocalizedDescriptionKey: "Credential account identifiers collide."]
                )
            }
        }
    }

    /// Deterministic, value-blind mapping from the old environment-variable
    /// account names to canonical provider-scoped account names.
    static func legacyMigrationPlan(
        service: String = ApiKeyStore.defaultService
    ) throws -> [LegacyMigration] {
        if let issue = identifierIssue(service) {
            throw NSError(
                domain: defaultService,
                code: Int(errSecParam),
                userInfo: [NSLocalizedDescriptionKey: issue]
            )
        }

        let sourceAccounts = Key.allCases.map(\.rawValue)
        let destinationAccounts = Key.allCases.map(\.accountIdentifier)
        try validateAccountIdentifiers(sourceAccounts)
        try validateAccountIdentifiers(destinationAccounts)

        return zip(sourceAccounts, destinationAccounts).map { source, destination in
            LegacyMigration(
                sourceService: service,
                sourceAccount: source,
                destinationService: service,
                destinationAccount: destination
            )
        }
    }

    private func migration(for key: Key) -> LegacyMigration? {
        guard let index = Key.allCases.firstIndex(of: key),
              let plan = try? Self.legacyMigrationPlan(service: service),
              plan.indices.contains(index) else {
            return nil
        }
        return plan[index]
    }

    private static func decodeCredential(_ data: Data?) -> String? {
        guard let data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func collisionIdentity(for identifier: String) -> String {
        let normalized = identifier.utf8.compactMap { byte -> UInt8? in
            guard isASCIIAlphanumeric(byte) else { return nil }
            return (65...90).contains(byte) ? byte + 32 : byte
        }
        return String(decoding: normalized, as: UTF8.self)
    }

    private static func isAllowedIdentifierByte(_ byte: UInt8) -> Bool {
        isASCIIAlphanumeric(byte) || byte == 46 || byte == 45 || byte == 95
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Use the modern keychain so kSecAttrAccessible is honored on macOS
            // and no interactive ACL prompt appears for the app's own items.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Convert an OSStatus into the stable, secret-free error contract used by
    /// Settings and by the required signed Keychain boundary lane. The caller
    /// supplies only an operation/provider description, never the key value.
    static func keychainError(_ status: OSStatus, message: String) -> NSError {
        let detail = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return NSError(
            domain: ApiKeyStore.defaultService,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(message) (\(detail))"]
        )
    }
}
