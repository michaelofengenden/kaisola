import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct CompanionIdentityPin: Codable, Hashable, Sendable {
    let id: String
    let identityPublic: String
    let x25519StaticPublic: String
}

struct CompanionSignedKeyRecord: Codable, Hashable, Sendable {
    let desktopId: String?
    let deviceId: String?
    let role: CompanionPeerRole
    let x25519StaticPublic: String
    let signature: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case desktopId, deviceId, role, x25519StaticPublic, signature
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(id: String, role: CompanionPeerRole, x25519StaticPublic: String, signature: String) {
        desktopId = role == .desktop ? id : nil
        deviceId = role == .device ? id : nil
        self.role = role
        self.x25519StaticPublic = x25519StaticPublic
        self.signature = signature
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard !dynamic.allKeys.contains(where: { !allowed.contains($0.stringValue) }) else {
            throw CompanionCryptoError.invalidKeyRecord
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        desktopId = try container.decodeIfPresent(String.self, forKey: .desktopId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        role = try container.decode(CompanionPeerRole.self, forKey: .role)
        x25519StaticPublic = try container.decode(String.self, forKey: .x25519StaticPublic)
        signature = try container.decode(String.self, forKey: .signature)
        guard role == .desktop
                ? container.contains(.desktopId) && !container.contains(.deviceId)
                : container.contains(.deviceId) && !container.contains(.desktopId) else {
            throw CompanionCryptoError.invalidKeyRecord
        }
    }

    var id: String? { role == .desktop ? desktopId : deviceId }

    var unsignedJSON: JSONValue {
        var fields: [String: JSONValue] = [
            "role": .string(role.rawValue),
            "x25519StaticPublic": .string(x25519StaticPublic),
        ]
        if let desktopId { fields["desktopId"] = .string(desktopId) }
        if let deviceId { fields["deviceId"] = .string(deviceId) }
        return .object(fields)
    }

    var jsonValue: JSONValue {
        guard case var .object(fields) = unsignedJSON else { return .null }
        fields["signature"] = .string(signature)
        return .object(fields)
    }

    func verify(identityPublic: String, expectedRole: CompanionPeerRole, expectedId: String? = nil) throws {
        guard role == expectedRole,
              let id,
              expectedId == nil || id == expectedId,
              (role == .desktop ? deviceId == nil : desktopId == nil) else {
            throw CompanionCryptoError.roleMismatch
        }
        _ = try CompanionCrypto.validateIdentifier(id, label: role == .desktop ? "desktopId" : "deviceId")
        _ = try CompanionCrypto.decodeBase64URL(x25519StaticPublic, bytes: 32, label: "x25519StaticPublic")
        let publicData = try CompanionCrypto.decodeBase64URL(identityPublic, bytes: 32, label: "identityPublic")
        let signatureData = try CompanionCrypto.decodeBase64URL(signature, bytes: 64, label: "key record signature")
        var signed = CompanionCrypto.keyRecordDomain
        signed.append(try CanonicalJSON.data(from: unsignedJSON))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        guard publicKey.isValidSignature(signatureData, for: signed) else {
            throw CompanionCryptoError.identityProofFailed
        }
    }
}

struct CompanionIdentity: Sendable {
    let id: String
    let role: CompanionPeerRole
    let displayName: String
    let signingPrivateKey: Curve25519.Signing.PrivateKey
    let agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let keyRecord: CompanionSignedKeyRecord

    init(
        id: String,
        role: CompanionPeerRole,
        displayName: String,
        signingPrivateKey: Curve25519.Signing.PrivateKey = .init(),
        agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey = .init()
    ) throws {
        _ = try CompanionCrypto.validateIdentifier(id, label: role == .desktop ? "desktopId" : "deviceId")
        self.id = id
        self.role = role
        self.displayName = String(displayName.prefix(80))
        self.signingPrivateKey = signingPrivateKey
        self.agreementPrivateKey = agreementPrivateKey

        let agreementPublic = agreementPrivateKey.publicKey.rawRepresentation.base64URLEncodedString()
        let unsigned = CompanionSignedKeyRecord(id: id, role: role, x25519StaticPublic: agreementPublic, signature: "")
        var signingBytes = CompanionCrypto.keyRecordDomain
        signingBytes.append(try CanonicalJSON.data(from: unsigned.unsignedJSON))
        let signature = try signingPrivateKey.signature(for: signingBytes).base64URLEncodedString()
        keyRecord = CompanionSignedKeyRecord(
            id: id,
            role: role,
            x25519StaticPublic: agreementPublic,
            signature: signature
        )
    }

    var identityPublic: String { signingPrivateKey.publicKey.rawRepresentation.base64URLEncodedString() }
    var x25519StaticPublic: String { agreementPrivateKey.publicKey.rawRepresentation.base64URLEncodedString() }

    static func testIdentity(
        id: String,
        role: CompanionPeerRole,
        displayName: String,
        signingSeed: Data,
        agreementSeed: Data
    ) throws -> CompanionIdentity {
        try CompanionIdentity(
            id: id,
            role: role,
            displayName: displayName,
            signingPrivateKey: Curve25519.Signing.PrivateKey(rawRepresentation: signingSeed),
            agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementSeed)
        )
    }
}

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
        guard present.allSatisfy({ $0 }) else { throw CompanionCryptoError.invalidIdentity("partial Keychain identity") }

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
