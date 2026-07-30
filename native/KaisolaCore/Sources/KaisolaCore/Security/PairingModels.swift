import CryptoKit
import Foundation

private struct PairingCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct CompanionPairingTransportHint: Codable, Hashable, Sendable {
    public let service: String
    public let `protocol`: String
    public let host: String?
    public let port: Int?
    public let tailscaleHost: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case service, `protocol`, host, port, tailscaleHost
    }

    public init(
        service: String,
        protocol: String,
        host: String? = nil,
        port: Int? = nil,
        tailscaleHost: String? = nil
    ) {
        self.service = service
        self.protocol = `protocol`
        self.host = host
        self.port = port
        self.tailscaleHost = tailscaleHost
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: PairingCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard !dynamic.allKeys.contains(where: { !allowed.contains($0.stringValue) }) else {
            throw CompanionCryptoError.invalidIdentity("transportHint")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        service = try container.decode(String.self, forKey: .service)
        `protocol` = try container.decode(String.self, forKey: .protocol)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        tailscaleHost = try container.decodeIfPresent(String.self, forKey: .tailscaleHost)
    }

    public func validate() throws {
        let validHost: (String?) -> Bool = { value in
            value.map {
                !$0.isEmpty && $0.count <= 253 && !$0.contains(where: { "\0\r\n".contains($0) })
            } ?? true
        }
        guard service == "_kaisola._tcp",
              `protocol` == "tcp",
              validHost(host),
              validHost(tailscaleHost),
              port.map({ (1...65_535).contains($0) }) ?? true else {
            throw CompanionCryptoError.invalidIdentity("transportHint")
        }
    }
}

public struct CompanionPairingPayload: Codable, Hashable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let noiseProtocol: String
    public let desktopId: String
    public let identityPublic: String
    public let keyRecord: CompanionSignedKeyRecord
    public let pairingNonce: String
    public let requestedCapabilities: [CompanionCapability]
    public let transportHint: CompanionPairingTransportHint
    public let expiresAt: Int64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type, protocolVersion, noiseProtocol, desktopId, identityPublic, keyRecord
        case pairingNonce, requestedCapabilities, transportHint, expiresAt
    }

    public init(
        desktopId: String,
        identityPublic: String,
        keyRecord: CompanionSignedKeyRecord,
        pairingNonce: String,
        requestedCapabilities: [CompanionCapability],
        transportHint: CompanionPairingTransportHint,
        expiresAt: Int64
    ) {
        type = "kaisola-companion-pairing"
        protocolVersion = CompanionCrypto.protocolVersion
        noiseProtocol = CompanionCrypto.noiseProtocol
        self.desktopId = desktopId
        self.identityPublic = identityPublic
        self.keyRecord = keyRecord
        self.pairingNonce = pairingNonce
        self.requestedCapabilities = requestedCapabilities
        self.transportHint = transportHint
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: PairingCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard !dynamic.allKeys.contains(where: { !allowed.contains($0.stringValue) }) else {
            throw CompanionCryptoError.invalidIdentity("pairing payload")
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        noiseProtocol = try container.decode(String.self, forKey: .noiseProtocol)
        desktopId = try container.decode(String.self, forKey: .desktopId)
        identityPublic = try container.decode(String.self, forKey: .identityPublic)
        keyRecord = try container.decode(CompanionSignedKeyRecord.self, forKey: .keyRecord)
        pairingNonce = try container.decode(String.self, forKey: .pairingNonce)
        let requested = try container.decodeIfPresent(
            [CompanionCapability].self,
            forKey: .requestedCapabilities
        ) ?? [.observe]
        guard !requested.isEmpty,
              requested.count <= CompanionCapability.allCases.count,
              Set(requested).count == requested.count,
              requested.contains(.observe) else {
            throw CompanionCryptoError.invalidIdentity("requestedCapabilities")
        }
        requestedCapabilities = CompanionCapability.allCases.filter(requested.contains)
        transportHint = try container.decode(CompanionPairingTransportHint.self, forKey: .transportHint)
        expiresAt = try container.decode(Int64.self, forKey: .expiresAt)
    }

    public func validate(now: Date = .now, clockSkewMilliseconds: Int64 = 30_000) throws {
        guard type == "kaisola-companion-pairing",
              protocolVersion == CompanionCrypto.protocolVersion,
              noiseProtocol == CompanionCrypto.noiseProtocol else {
            throw CompanionProtocolError.protocolMismatch(protocolVersion)
        }
        _ = try CompanionCrypto.validateIdentifier(desktopId, label: "desktopId")
        _ = try CompanionCrypto.decodeBase64URL(identityPublic, bytes: 32, label: "identityPublic")
        try keyRecord.verify(identityPublic: identityPublic, expectedRole: .desktop, expectedId: desktopId)
        _ = try CompanionCrypto.decodeBase64URL(pairingNonce, bytes: 32, label: "pairingNonce")
        guard !requestedCapabilities.isEmpty,
              requestedCapabilities.contains(.observe),
              Set(requestedCapabilities).count == requestedCapabilities.count,
              requestedCapabilities.count <= CompanionCapability.allCases.count,
              expiresAt >= 0,
              expiresAt <= 9_007_199_254_740_991,
              clockSkewMilliseconds >= 0 else {
            throw CompanionCryptoError.invalidIdentity("pairing payload")
        }
        try transportHint.validate()
        guard try CanonicalJSON.data(from: self).count <= 16 * 1_024 else {
            throw CompanionCryptoError.frameTooLarge
        }
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        guard nowMilliseconds <= expiresAt + clockSkewMilliseconds else {
            throw CompanionCryptoError.authenticationFailed
        }
    }

    public var desktopPin: CompanionIdentityPin {
        CompanionIdentityPin(
            id: desktopId,
            identityPublic: identityPublic,
            x25519StaticPublic: keyRecord.x25519StaticPublic
        )
    }

    public func handshakeContext(connectionId: String) throws -> JSONValue {
        _ = try CompanionCrypto.validateIdentifier(connectionId, label: "connectionId")
        let hash = CompanionCrypto.sha256(try CanonicalJSON.data(from: self)).base64URLEncodedString()
        return .object([
            "v": .integer(Int64(CompanionCrypto.protocolVersion)),
            "mode": .string("pair"),
            "protocol": .string(CompanionCrypto.noiseProtocol),
            "desktopId": .string(desktopId),
            "connectionId": .string(connectionId),
            "qrHash": .string(hash),
        ])
    }
}

public struct CompanionPairedDesktop: Codable, Hashable, Sendable {
    public let desktopId: String
    public let identityPublic: String
    public let x25519StaticPublic: String
    public let capabilities: [CompanionCapability]
    public let transportHint: CompanionPairingTransportHint?

    public init(
        desktopId: String,
        identityPublic: String,
        x25519StaticPublic: String,
        capabilities: [CompanionCapability],
        transportHint: CompanionPairingTransportHint?
    ) {
        self.desktopId = desktopId
        self.identityPublic = identityPublic
        self.x25519StaticPublic = x25519StaticPublic
        self.capabilities = capabilities
        self.transportHint = transportHint
    }

    public var pin: CompanionIdentityPin {
        CompanionIdentityPin(
            id: desktopId,
            identityPublic: identityPublic,
            x25519StaticPublic: x25519StaticPublic
        )
    }

    public func resumeHandshakeContext(deviceId: String, connectionId: String) throws -> JSONValue {
        _ = try CompanionCrypto.validateIdentifier(desktopId, label: "desktopId")
        _ = try CompanionCrypto.validateIdentifier(deviceId, label: "deviceId")
        _ = try CompanionCrypto.validateIdentifier(connectionId, label: "connectionId")
        return .object([
            "v": .integer(Int64(CompanionCrypto.protocolVersion)),
            "mode": .string("resume"),
            "protocol": .string(CompanionCrypto.noiseProtocol),
            "desktopId": .string(desktopId),
            "deviceId": .string(deviceId),
            "connectionId": .string(connectionId),
        ])
    }
}
