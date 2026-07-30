import CryptoKit
import Foundation

public struct NoiseHandshakeResult: Sendable {
    public let handshakeHash: Data
    public let splitKeys: [Data]
    public let peer: CompanionIdentityPin
    /// The display name authenticated inside the Noise identity proof. It is
    /// presentation metadata rather than part of the long-lived key pin.
    public let peerDisplayName: String?

    public init(
        handshakeHash: Data,
        splitKeys: [Data],
        peer: CompanionIdentityPin,
        peerDisplayName: String? = nil
    ) {
        self.handshakeHash = handshakeHash
        self.splitKeys = splitKeys
        self.peer = peer
        self.peerDisplayName = peerDisplayName
    }
}

private final class NoiseSymmetricState {
    private(set) var handshakeHash: Data
    private(set) var chainingKey: Data
    private var key: Data?
    private var counter: UInt64 = 0

    init(prologue: Data) {
        let name = Data(CompanionCrypto.noiseProtocol.utf8)
        if name.count <= 32 {
            handshakeHash = name + Data(repeating: 0, count: 32 - name.count)
        } else {
            handshakeHash = CompanionCrypto.sha256(name)
        }
        chainingKey = handshakeHash
        mixHash(prologue)
    }

    func mixHash(_ data: Data) {
        handshakeHash = CompanionCrypto.sha256(handshakeHash, data)
    }

    func mixKey(_ inputKeyMaterial: Data) {
        let output = CompanionCrypto.noiseHKDF(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial)
        chainingKey = output.0
        key = output.1
        counter = 0
    }

    func encryptAndHash(_ plaintext: Data) throws -> Data {
        let output: Data
        if let key {
            output = try CompanionCrypto.aeadEncrypt(
                key: key,
                counter: counter,
                aad: handshakeHash,
                plaintext: plaintext
            )
            counter += 1
        } else {
            output = plaintext
        }
        mixHash(output)
        return output
    }

    func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let output: Data
        if let key {
            output = try CompanionCrypto.aeadDecrypt(
                key: key,
                counter: counter,
                aad: handshakeHash,
                combined: ciphertext
            )
            counter += 1
        } else {
            output = ciphertext
        }
        mixHash(ciphertext)
        return output
    }

    func split() -> [Data] {
        let output = CompanionCrypto.noiseHKDF(chainingKey: chainingKey, inputKeyMaterial: Data())
        return [output.0, output.1]
    }
}

private enum NoiseIdentityProof {
    struct ParsedPeer {
        let pin: CompanionIdentityPin
        let displayName: String
    }

    static func signingBytes(role: CompanionPeerRole, handshakeHash: Data) -> Data {
        var data = CompanionCrypto.handshakeSignatureDomain
        data.append(contentsOf: role.rawValue.utf8)
        data.append(0)
        data.append(handshakeHash)
        return data
    }

    static func make(identity: CompanionIdentity, handshakeHash: Data) throws -> Data {
        let signature = try identity.signingPrivateKey.signature(
            for: signingBytes(role: identity.role, handshakeHash: handshakeHash)
        )
        let value: JSONValue = .object([
            "v": .integer(Int64(CompanionCrypto.protocolVersion)),
            "role": .string(identity.role.rawValue),
            "identityPublic": .string(identity.identityPublic),
            "keyRecord": identity.keyRecord.jsonValue,
            "displayName": .string(identity.displayName),
            "handshakeSignature": .string(signature.base64URLEncodedString()),
        ])
        let encoded = try CanonicalJSON.data(from: value)
        guard encoded.count <= 8 * 1_024 else { throw CompanionCryptoError.frameTooLarge }
        return encoded
    }

    static func parse(
        _ encoded: Data,
        handshakeHash: Data,
        staticPublic: Data,
        expectedRole: CompanionPeerRole,
        pin: CompanionIdentityPin?
    ) throws -> ParsedPeer {
        guard encoded.count <= 8 * 1_024,
              let value = try? JSONDecoder().decode(JSONValue.self, from: encoded),
              let proof = value.objectValue,
              Set(proof.keys).isSubset(of: ["v", "role", "identityPublic", "keyRecord", "displayName", "handshakeSignature"]),
              proof["v"]?.intValue == Int64(CompanionCrypto.protocolVersion),
              proof["role"]?.stringValue == expectedRole.rawValue,
              let identityPublic = proof["identityPublic"]?.stringValue,
              let keyRecordValue = proof["keyRecord"],
              let signatureString = proof["handshakeSignature"]?.stringValue else {
            throw CompanionCryptoError.identityProofFailed
        }

        let fallbackName = expectedRole == .desktop ? "Kaisola Desktop" : "Kaisola Device"
        let rawName = (proof["displayName"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawName.isEmpty ? fallbackName : String(rawName.prefix(80))

        let keyRecordData = try CanonicalJSON.data(from: keyRecordValue)
        let record = try JSONDecoder().decode(CompanionSignedKeyRecord.self, from: keyRecordData)
        try record.verify(identityPublic: identityPublic, expectedRole: expectedRole, expectedId: pin?.id)
        guard record.x25519StaticPublic == staticPublic.base64URLEncodedString() else {
            throw CompanionCryptoError.identityProofFailed
        }
        if let pin {
            guard pin.identityPublic == identityPublic,
                  pin.x25519StaticPublic == record.x25519StaticPublic else {
                throw CompanionCryptoError.identityMismatch
            }
        }
        let publicData = try CompanionCrypto.decodeBase64URL(identityPublic, bytes: 32, label: "identityPublic")
        let signature = try CompanionCrypto.decodeBase64URL(signatureString, bytes: 64, label: "handshake signature")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
        guard publicKey.isValidSignature(
            signature,
            for: signingBytes(role: expectedRole, handshakeHash: handshakeHash)
        ), let id = record.id else {
            throw CompanionCryptoError.identityProofFailed
        }
        return ParsedPeer(
            pin: CompanionIdentityPin(
                id: id,
                identityPublic: identityPublic,
                x25519StaticPublic: record.x25519StaticPublic
            ),
            displayName: displayName
        )
    }
}

public final class NoiseXXInitiator {
    private enum State { case writeMessage1, readMessage2, writeMessage3, complete }

    private let identity: CompanionIdentity
    private let peerPin: CompanionIdentityPin?
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let symmetric: NoiseSymmetricState
    private var state = State.writeMessage1
    private var remoteEphemeral: Data?
    private var remoteStatic: Data?
    private var peer: CompanionIdentityPin?
    private var peerDisplayName: String?

    public init(
        identity: CompanionIdentity,
        prologue: Data,
        peerPin: CompanionIdentityPin? = nil,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey = .init()
    ) throws {
        guard identity.role == .device else { throw CompanionCryptoError.roleMismatch }
        self.identity = identity
        self.peerPin = peerPin
        ephemeral = ephemeralPrivateKey
        symmetric = NoiseSymmetricState(prologue: prologue)
    }

    public func writeMessage1() throws -> Data {
        guard state == .writeMessage1 else { throw CompanionCryptoError.handshakeOrder }
        let message = ephemeral.publicKey.rawRepresentation
        symmetric.mixHash(message)
        state = .readMessage2
        return message
    }

    @discardableResult
    public func readMessage2(_ message: Data) throws -> CompanionIdentityPin {
        guard state == .readMessage2 else { throw CompanionCryptoError.handshakeOrder }
        guard message.count >= 96, message.count <= CompanionCrypto.maximumHandshakeMessageBytes else {
            throw CompanionCryptoError.invalidHandshakeMessage
        }
        let remoteEphemeral = Data(message.prefix(32))
        self.remoteEphemeral = remoteEphemeral
        symmetric.mixHash(remoteEphemeral)
        symmetric.mixKey(try CompanionCrypto.sharedSecret(privateKey: ephemeral, remotePublic: remoteEphemeral))

        let remoteStatic = try symmetric.decryptAndHash(Data(message.dropFirst(32).prefix(48)))
        self.remoteStatic = remoteStatic
        symmetric.mixKey(try CompanionCrypto.sharedSecret(privateKey: ephemeral, remotePublic: remoteStatic))
        let beforePayload = symmetric.handshakeHash
        let proof = try symmetric.decryptAndHash(Data(message.dropFirst(80)))
        let parsed = try NoiseIdentityProof.parse(
            proof,
            handshakeHash: beforePayload,
            staticPublic: remoteStatic,
            expectedRole: .desktop,
            pin: peerPin
        )
        peer = parsed.pin
        peerDisplayName = parsed.displayName
        state = .writeMessage3
        return parsed.pin
    }

    public func writeMessage3() throws -> Data {
        guard state == .writeMessage3, let remoteEphemeral else { throw CompanionCryptoError.handshakeOrder }
        let encryptedStatic = try symmetric.encryptAndHash(identity.agreementPrivateKey.publicKey.rawRepresentation)
        symmetric.mixKey(try CompanionCrypto.sharedSecret(
            privateKey: identity.agreementPrivateKey,
            remotePublic: remoteEphemeral
        ))
        let beforePayload = symmetric.handshakeHash
        let encryptedPayload = try symmetric.encryptAndHash(
            NoiseIdentityProof.make(identity: identity, handshakeHash: beforePayload)
        )
        state = .complete
        var message = Data()
        message.append(encryptedStatic)
        message.append(encryptedPayload)
        return message
    }

    public func result() throws -> NoiseHandshakeResult {
        guard state == .complete, let peer else { throw CompanionCryptoError.handshakeOrder }
        return NoiseHandshakeResult(
            handshakeHash: symmetric.handshakeHash,
            splitKeys: symmetric.split(),
            peer: peer,
            peerDisplayName: peerDisplayName
        )
    }
}

public final class NoiseXXResponder {
    private enum State { case readMessage1, writeMessage2, readMessage3, complete }

    private let identity: CompanionIdentity
    private let peerPin: CompanionIdentityPin?
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let symmetric: NoiseSymmetricState
    private var state = State.readMessage1
    private var remoteEphemeral: Data?
    private var peer: CompanionIdentityPin?
    private var peerDisplayName: String?

    public init(
        identity: CompanionIdentity,
        prologue: Data,
        peerPin: CompanionIdentityPin? = nil,
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey = .init()
    ) throws {
        guard identity.role == .desktop else { throw CompanionCryptoError.roleMismatch }
        self.identity = identity
        self.peerPin = peerPin
        ephemeral = ephemeralPrivateKey
        symmetric = NoiseSymmetricState(prologue: prologue)
    }

    public func readMessage1(_ message: Data) throws {
        guard state == .readMessage1 else { throw CompanionCryptoError.handshakeOrder }
        guard message.count == 32 else { throw CompanionCryptoError.invalidHandshakeMessage }
        remoteEphemeral = message
        symmetric.mixHash(message)
        state = .writeMessage2
    }

    public func writeMessage2() throws -> Data {
        guard state == .writeMessage2, let remoteEphemeral else { throw CompanionCryptoError.handshakeOrder }
        let localEphemeral = ephemeral.publicKey.rawRepresentation
        symmetric.mixHash(localEphemeral)
        symmetric.mixKey(try CompanionCrypto.sharedSecret(privateKey: ephemeral, remotePublic: remoteEphemeral))
        let encryptedStatic = try symmetric.encryptAndHash(identity.agreementPrivateKey.publicKey.rawRepresentation)
        symmetric.mixKey(try CompanionCrypto.sharedSecret(
            privateKey: identity.agreementPrivateKey,
            remotePublic: remoteEphemeral
        ))
        let beforePayload = symmetric.handshakeHash
        let encryptedPayload = try symmetric.encryptAndHash(
            NoiseIdentityProof.make(identity: identity, handshakeHash: beforePayload)
        )
        state = .readMessage3
        var message = Data()
        message.append(localEphemeral)
        message.append(encryptedStatic)
        message.append(encryptedPayload)
        return message
    }

    @discardableResult
    public func readMessage3(_ message: Data) throws -> CompanionIdentityPin {
        guard state == .readMessage3 else { throw CompanionCryptoError.handshakeOrder }
        guard message.count >= 64, message.count <= CompanionCrypto.maximumHandshakeMessageBytes else {
            throw CompanionCryptoError.invalidHandshakeMessage
        }
        let remoteStatic = try symmetric.decryptAndHash(Data(message.prefix(48)))
        symmetric.mixKey(try CompanionCrypto.sharedSecret(privateKey: ephemeral, remotePublic: remoteStatic))
        let beforePayload = symmetric.handshakeHash
        let proof = try symmetric.decryptAndHash(Data(message.dropFirst(48)))
        let parsed = try NoiseIdentityProof.parse(
            proof,
            handshakeHash: beforePayload,
            staticPublic: remoteStatic,
            expectedRole: .device,
            pin: peerPin
        )
        peer = parsed.pin
        peerDisplayName = parsed.displayName
        state = .complete
        return parsed.pin
    }

    public func result() throws -> NoiseHandshakeResult {
        guard state == .complete, let peer else { throw CompanionCryptoError.handshakeOrder }
        return NoiseHandshakeResult(
            handshakeHash: symmetric.handshakeHash,
            splitKeys: symmetric.split(),
            peer: peer,
            peerDisplayName: peerDisplayName
        )
    }
}

public func createNoisePrologue(_ context: JSONValue) throws -> Data {
    var prologue = CompanionCrypto.prologueDomain
    prologue.append(try CanonicalJSON.data(from: context))
    return prologue
}
