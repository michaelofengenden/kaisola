import CryptoKit
import Foundation
import KaisolaCore
import Security

enum CompanionIdentityStoreError: LocalizedError, Equatable {
    case partialIdentity
    case invalidIdentity
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .partialIdentity:
            "Kaisola found an incomplete Companion identity in the Keychain."
        case .invalidIdentity:
            "Kaisola could not validate its Companion identity."
        case let .keychain(status):
            "Kaisola could not access its Companion identity in the Keychain (\(status))."
        }
    }
}

/// Stable desktop Noise identity. Private Ed25519/X25519 material never enters
/// app-support JSON and is non-synchronizable, this-device-only Keychain data.
struct CompanionIdentityStore {
    static let defaultService = "com.kaisola.mac.preview.companion-identity"

    enum Account: String, CaseIterable {
        case desktopID = "identity-desktop-id"
        case signing = "identity-ed25519"
        case agreement = "identity-x25519"
    }

    private let service: String

    init(service: String = Self.defaultService) {
        self.service = service
    }

    func loadOrCreate(displayName: String) throws -> CompanionIdentity {
        let present = try Account.allCases.map(hasItem)
        if present.allSatisfy({ !$0 }) {
            let identity = try CompanionIdentity(
                id: "desktop-\(UUID().uuidString.lowercased())",
                role: .desktop,
                displayName: normalizedDisplayName(displayName)
            )
            do {
                try add(Data(identity.id.utf8), account: .desktopID)
                try add(identity.signingPrivateKey.rawRepresentation, account: .signing)
                try add(identity.agreementPrivateKey.rawRepresentation, account: .agreement)
            } catch {
                deleteAll()
                throw error
            }
            return identity
        }
        guard present.allSatisfy({ $0 }) else {
            throw CompanionIdentityStoreError.partialIdentity
        }
        guard let id = String(data: try copy(.desktopID), encoding: .utf8) else {
            throw CompanionIdentityStoreError.invalidIdentity
        }
        do {
            return try CompanionIdentity(
                id: id,
                role: .desktop,
                displayName: normalizedDisplayName(displayName),
                signingPrivateKey: Curve25519.Signing.PrivateKey(
                    rawRepresentation: try copy(.signing)
                ),
                agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey(
                    rawRepresentation: try copy(.agreement)
                )
            )
        } catch let error as CompanionIdentityStoreError {
            throw error
        } catch {
            throw CompanionIdentityStoreError.invalidIdentity
        }
    }

    func deleteAll() {
        for account in Account.allCases {
            SecItemDelete(baseQuery(account) as CFDictionary)
        }
    }

    private func normalizedDisplayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Kaisola Desktop" : String(trimmed.prefix(80))
    }

    private func hasItem(_ account: Account) throws -> Bool {
        var query = baseQuery(account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw CompanionIdentityStoreError.keychain(status)
    }

    private func copy(_ account: Account) throws -> Data {
        var query = baseQuery(account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw CompanionIdentityStoreError.keychain(status)
        }
        return data
    }

    private func add(_ data: Data, account: Account) throws {
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CompanionIdentityStoreError.keychain(status)
        }
    }

    private func baseQuery(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
