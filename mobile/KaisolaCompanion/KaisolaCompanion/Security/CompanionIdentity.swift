import CryptoKit
import Foundation
import KaisolaCore
import LocalAuthentication
import Security

actor CompanionIdentityKeychain {
    private let service: String
    private let accessGroup: String?

    private enum Account: String, CaseIterable {
        case deviceId = "identity-device-id"
        case signing = "identity-ed25519"
        case agreement = "identity-x25519"
    }

    init(service: String = "com.kaisola.companion.identity", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func loadOrCreateDeviceIdentity(
        displayName: String,
        reason: String = "Unlock your Kaisola device identity"
    ) async throws -> CompanionIdentity {
        let present = try Account.allCases.map(hasItem)
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        #if DEBUG
        // The passcode-less pairing simulator can't satisfy device auth; the
        // automated pairing harness skips it. Never compiled into release.
        let skipDeviceAuth = ProcessInfo.processInfo.environment["KAISOLA_SKIP_LA"] == "1"
        #else
        let skipDeviceAuth = false
        #endif
        if !skipDeviceAuth {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        }
        if present.allSatisfy({ !$0 }) {
            let identity = try CompanionIdentity(
                id: "device-\(UUID().uuidString.lowercased())",
                role: .device,
                displayName: displayName
            )
            do {
                try add(Data(identity.id.utf8), account: .deviceId)
                try add(identity.signingPrivateKey.rawRepresentation, account: .signing)
                try add(identity.agreementPrivateKey.rawRepresentation, account: .agreement)
            } catch {
                for account in Account.allCases {
                    _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
                }
                throw error
            }
            return identity
        }
        guard present.allSatisfy({ $0 }) else {
            throw CompanionCryptoError.invalidIdentity("partial Keychain identity")
        }

        let idData = try copy(account: .deviceId, context: context)
        let signing = try copy(account: .signing, context: context)
        let agreement = try copy(account: .agreement, context: context)
        guard let id = String(data: idData, encoding: .utf8) else {
            throw CompanionCryptoError.invalidIdentity("deviceId")
        }
        return try CompanionIdentity(
            id: id,
            role: .device,
            displayName: displayName,
            signingPrivateKey: Curve25519.Signing.PrivateKey(rawRepresentation: signing),
            agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreement)
        )
    }

    func deleteIdentity(reason: String = "Authenticate to remove your Kaisola device identity") async throws {
        if Account.allCases.contains(where: { (try? hasItem($0)) == true }) {
            let context = LAContext()
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        }
        for account in Account.allCases {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
        }
    }

    private func hasItem(_ account: Account) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
        if status == errSecItemNotFound { return false }
        throw KeychainError(status)
    }

    private func add(_ data: Data, account: Account) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],
            &error
        ) else {
            throw error?.takeRetainedValue() ?? KeychainError(errSecParam)
        }
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    private func copy(account: Account, context: LAContext) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
        return data
    }

    private func baseQuery(account: Account) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private struct KeychainError: Error {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
    }
}
