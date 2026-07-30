import Foundation

public struct CompanionSecureFrame: Codable, Hashable, Sendable {
    public let v: Int
    public let desktopId: String
    public let deviceId: String
    public let connectionId: String
    public let direction: String
    public let counter: String
    public let ciphertextLength: Int
    public var ciphertext: String

    public init(
        v: Int,
        desktopId: String,
        deviceId: String,
        connectionId: String,
        direction: String,
        counter: String,
        ciphertextLength: Int,
        ciphertext: String
    ) {
        self.v = v
        self.desktopId = desktopId
        self.deviceId = deviceId
        self.connectionId = connectionId
        self.direction = direction
        self.counter = counter
        self.ciphertextLength = ciphertextLength
        self.ciphertext = ciphertext
    }
}

public struct CompanionConnectionContext: Codable, Hashable, Sendable {
    public let desktopId: String
    public let deviceId: String
    public let connectionId: String

    public init(desktopId: String, deviceId: String, connectionId: String) {
        self.desktopId = desktopId
        self.deviceId = deviceId
        self.connectionId = connectionId
    }
}

public final class SecureFrameChannel: @unchecked Sendable {
    private let sendKey: Data
    private let receiveKey: Data
    private let context: CompanionConnectionContext
    private let sendDirection: String
    private let receiveDirection: String
    private let lock = NSLock()
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    public init(
        sendKey: Data,
        receiveKey: Data,
        context: CompanionConnectionContext,
        sendDirection: String,
        receiveDirection: String
    ) throws {
        guard sendKey.count == 32, receiveKey.count == 32,
              ["device-to-desktop", "desktop-to-device"].contains(sendDirection),
              ["device-to-desktop", "desktop-to-device"].contains(receiveDirection),
              sendDirection != receiveDirection else {
            throw CompanionCryptoError.invalidSecureFrame
        }
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.context = context
        self.sendDirection = sendDirection
        self.receiveDirection = receiveDirection
    }

    public convenience init(result: NoiseHandshakeResult, context: CompanionConnectionContext, role: CompanionPeerRole) throws {
        guard result.splitKeys.count == 2 else { throw CompanionCryptoError.invalidSecureFrame }
        let deviceToDesktop = CompanionCrypto.hkdf32(
            input: result.splitKeys[0],
            salt: result.handshakeHash,
            info: try Self.connectionInfo(context: context, direction: "device-to-desktop")
        )
        let desktopToDevice = CompanionCrypto.hkdf32(
            input: result.splitKeys[1],
            salt: result.handshakeHash,
            info: try Self.connectionInfo(context: context, direction: "desktop-to-device")
        )
        if role == .device {
            try self.init(
                sendKey: deviceToDesktop,
                receiveKey: desktopToDevice,
                context: context,
                sendDirection: "device-to-desktop",
                receiveDirection: "desktop-to-device"
            )
        } else {
            try self.init(
                sendKey: desktopToDevice,
                receiveKey: deviceToDesktop,
                context: context,
                sendDirection: "desktop-to-device",
                receiveDirection: "device-to-desktop"
            )
        }
    }

    public func encrypt(_ value: JSONValue) throws -> CompanionSecureFrame {
        try encrypt(try CanonicalJSON.data(from: value))
    }

    public func encrypt<T: Encodable>(_ value: T) throws -> CompanionSecureFrame {
        try encrypt(JSONValue.from(value))
    }

    public func encrypt(_ plaintext: Data) throws -> CompanionSecureFrame {
        lock.lock()
        defer { lock.unlock() }
        guard plaintext.count <= CompanionCrypto.maximumSecurePlaintextBytes else {
            throw CompanionCryptoError.frameTooLarge
        }
        let counter = sendCounter
        let header = Self.header(
            context: context,
            direction: sendDirection,
            counter: counter,
            ciphertextLength: plaintext.count
        )
        let aad = try CanonicalJSON.data(from: .object(header))
        let combined = try CompanionCrypto.aeadEncrypt(
            key: sendKey,
            counter: counter,
            aad: aad,
            plaintext: plaintext
        )
        guard sendCounter < UInt64.max else { throw CompanionCryptoError.counterExhausted }
        sendCounter += 1
        return CompanionSecureFrame(
            v: CompanionCrypto.protocolVersion,
            desktopId: context.desktopId,
            deviceId: context.deviceId,
            connectionId: context.connectionId,
            direction: sendDirection,
            counter: String(counter),
            ciphertextLength: plaintext.count,
            ciphertext: combined.base64URLEncodedString()
        )
    }

    public func decrypt(_ frame: CompanionSecureFrame) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard frame.v == CompanionCrypto.protocolVersion,
              frame.desktopId == context.desktopId,
              frame.deviceId == context.deviceId,
              frame.connectionId == context.connectionId,
              frame.direction == receiveDirection else { throw CompanionCryptoError.invalidSecureFrame }
        guard Self.isCanonicalCounter(frame.counter),
              let counter = UInt64(frame.counter) else { throw CompanionCryptoError.invalidSecureFrame }
        guard counter == receiveCounter else { throw CompanionCryptoError.replayOrOutOfOrder }
        guard frame.ciphertextLength >= 0,
              frame.ciphertextLength <= CompanionCrypto.maximumSecurePlaintextBytes,
              let combined = Data(base64URLString: frame.ciphertext),
              combined.count == frame.ciphertextLength + 16 else {
            throw CompanionCryptoError.invalidSecureFrame
        }
        let header = Self.header(
            context: context,
            direction: receiveDirection,
            counter: counter,
            ciphertextLength: frame.ciphertextLength
        )
        let plaintext = try CompanionCrypto.aeadDecrypt(
            key: receiveKey,
            counter: counter,
            aad: CanonicalJSON.data(from: .object(header)),
            combined: combined
        )
        guard receiveCounter < UInt64.max else { throw CompanionCryptoError.counterExhausted }
        receiveCounter += 1
        return plaintext
    }

    public func decryptJSON(_ frame: CompanionSecureFrame) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: decrypt(frame)) }
        catch let error as CompanionCryptoError { throw error }
        catch { throw CompanionCryptoError.invalidSecurePayload }
    }

    public var counters: (send: UInt64, receive: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (sendCounter, receiveCounter)
    }

    private static func header(
        context: CompanionConnectionContext,
        direction: String,
        counter: UInt64,
        ciphertextLength: Int
    ) -> [String: JSONValue] {
        [
            "v": .integer(Int64(CompanionCrypto.protocolVersion)),
            "desktopId": .string(context.desktopId),
            "deviceId": .string(context.deviceId),
            "connectionId": .string(context.connectionId),
            "direction": .string(direction),
            "counter": .string(String(counter)),
            "ciphertextLength": .integer(Int64(ciphertextLength)),
        ]
    }

    private static func connectionInfo(context: CompanionConnectionContext, direction: String) throws -> Data {
        try CanonicalJSON.data(from: .object([
            "v": .integer(Int64(CompanionCrypto.protocolVersion)),
            "protocol": .string(CompanionCrypto.noiseProtocol),
            "desktopId": .string(context.desktopId),
            "deviceId": .string(context.deviceId),
            "connectionId": .string(context.connectionId),
            "direction": .string(direction),
        ]))
    }

    private static func isCanonicalCounter(_ value: String) -> Bool {
        value.range(of: #"^(0|[1-9][0-9]{0,19})$"#, options: .regularExpression) != nil
    }
}

public struct CompanionSAS: Codable, Hashable, Sendable {
    public let phrase: String
    public let words: [String]
    public let entropyBits: Int
    public let bytes: String

    public static func derive(handshakeHash: Data) -> CompanionSAS {
        let adjectives = [
            "amber", "brisk", "calm", "clear", "coral", "dawn", "ember", "fair",
            "gentle", "green", "lunar", "merry", "quiet", "rapid", "silver", "warm",
        ]
        let nouns = [
            "anchor", "bird", "cedar", "cloud", "comet", "field", "harbor", "island",
            "maple", "meadow", "otter", "river", "stone", "trail", "willow", "wind",
        ]
        let salt = CompanionCrypto.sha256(Data("kaisola-companion-sas-v1".utf8))
        let derived = CompanionCrypto.hkdf32(
            input: handshakeHash,
            salt: salt,
            info: Data("transcript-authentication-phrase".utf8)
        ).prefix(4)
        let words = derived.map { byte in
            "\(adjectives[Int(byte >> 4)])-\(nouns[Int(byte & 15)])"
        }
        return CompanionSAS(
            phrase: words.joined(separator: " "),
            words: words,
            entropyBits: 32,
            bytes: Data(derived).base64URLEncodedString()
        )
    }
}

public enum CompanionKeyConfirmation {
    public static func payload(role: CompanionPeerRole, handshakeHash: Data) -> JSONValue {
        .object([
            "type": .string("key-confirm"),
            "role": .string(role.rawValue),
            "transcriptHash": .string(handshakeHash.base64URLEncodedString()),
        ])
    }

    public static func make(
        channel: SecureFrameChannel,
        role: CompanionPeerRole,
        handshakeHash: Data
    ) throws -> CompanionSecureFrame {
        try channel.encrypt(payload(role: role, handshakeHash: handshakeHash))
    }

    public static func verify(
        channel: SecureFrameChannel,
        frame: CompanionSecureFrame,
        expectedRole: CompanionPeerRole,
        handshakeHash: Data
    ) throws {
        let actual = try channel.decryptJSON(frame)
        guard actual == payload(role: expectedRole, handshakeHash: handshakeHash) else {
            throw CompanionCryptoError.keyConfirmationFailed
        }
    }
}
