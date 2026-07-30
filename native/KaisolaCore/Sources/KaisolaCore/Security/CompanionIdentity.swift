import CryptoKit
import Foundation

public struct CompanionIdentityPin: Codable, Hashable, Sendable {
    public let id: String
    public let identityPublic: String
    public let x25519StaticPublic: String

    public init(id: String, identityPublic: String, x25519StaticPublic: String) {
        self.id = id
        self.identityPublic = identityPublic
        self.x25519StaticPublic = x25519StaticPublic
    }
}

public struct CompanionSignedKeyRecord: Codable, Hashable, Sendable {
    public let desktopId: String?
    public let deviceId: String?
    public let role: CompanionPeerRole
    public let x25519StaticPublic: String
    public let signature: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case desktopId, deviceId, role, x25519StaticPublic, signature
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(id: String, role: CompanionPeerRole, x25519StaticPublic: String, signature: String) {
        desktopId = role == .desktop ? id : nil
        deviceId = role == .device ? id : nil
        self.role = role
        self.x25519StaticPublic = x25519StaticPublic
        self.signature = signature
    }

    public init(from decoder: Decoder) throws {
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

    public var id: String? { role == .desktop ? desktopId : deviceId }

    public var unsignedJSON: JSONValue {
        var fields: [String: JSONValue] = [
            "role": .string(role.rawValue),
            "x25519StaticPublic": .string(x25519StaticPublic),
        ]
        if let desktopId { fields["desktopId"] = .string(desktopId) }
        if let deviceId { fields["deviceId"] = .string(deviceId) }
        return .object(fields)
    }

    public var jsonValue: JSONValue {
        guard case var .object(fields) = unsignedJSON else { return .null }
        fields["signature"] = .string(signature)
        return .object(fields)
    }

    public func verify(
        identityPublic: String,
        expectedRole: CompanionPeerRole,
        expectedId: String? = nil
    ) throws {
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

public struct CompanionIdentity: Sendable {
    public let id: String
    public let role: CompanionPeerRole
    public let displayName: String
    public let signingPrivateKey: Curve25519.Signing.PrivateKey
    public let agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public let keyRecord: CompanionSignedKeyRecord

    public init(
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
        let unsigned = CompanionSignedKeyRecord(
            id: id,
            role: role,
            x25519StaticPublic: agreementPublic,
            signature: ""
        )
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

    public var identityPublic: String {
        signingPrivateKey.publicKey.rawRepresentation.base64URLEncodedString()
    }

    public var x25519StaticPublic: String {
        agreementPrivateKey.publicKey.rawRepresentation.base64URLEncodedString()
    }

    public static func testIdentity(
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
