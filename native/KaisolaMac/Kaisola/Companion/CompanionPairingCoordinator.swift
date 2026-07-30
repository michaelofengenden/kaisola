import Foundation
import KaisolaCore
import Security

enum CompanionPairingCoordinatorError: LocalizedError, Equatable {
    case invalidFrame
    case invalidOffer
    case offerUnavailable
    case expired
    case serverBusy
    case handshakeOrder
    case authenticationFailed
    case duplicateDevice

    var errorDescription: String? {
        switch self {
        case .invalidFrame: "Kaisola received an invalid Companion handshake frame."
        case .invalidOffer: "This Companion pairing offer is invalid."
        case .offerUnavailable: "This Companion pairing offer was already used or cancelled."
        case .expired: "This Companion pairing offer expired."
        case .serverBusy: "Kaisola is already handling too many Companion handshakes."
        case .handshakeOrder: "Companion handshake messages arrived out of order."
        case .authenticationFailed: "Kaisola could not authenticate this Companion connection."
        case .duplicateDevice: "This device is already paired. Revoke it before pairing again."
        }
    }
}

struct CompanionPairingCoordinatorOutput: Sendable {
    enum Event: Sendable {
        case pairingPhrase(
            pairingID: String,
            sessionID: String,
            deviceID: String,
            displayName: String,
            sas: CompanionSAS
        )
        case authenticated(device: CompanionPairedDeviceRecord, resumed: Bool)
    }

    var frames: [Data] = []
    var event: Event?
}

struct CompanionAuthenticatedConnection: Sendable {
    let device: CompanionPairedDeviceRecord
    let channel: SecureFrameChannel
    let context: CompanionConnectionContext
    let resumed: Bool
}

/// Owns single-use offers and the strict pre-auth Noise state machines. Socket
/// framing lives one layer below this actor; application envelopes live above
/// it, so neither can accidentally bypass authentication.
actor CompanionPairingCoordinator {
    static let defaultOfferTTL: Int64 = 2 * 60 * 1_000
    static let maximumOfferTTL: Int64 = 5 * 60 * 1_000
    static let handshakeTTL: Int64 = 30 * 1_000
    static let maximumActiveHandshakes = 8

    private struct Offer {
        let payload: CompanionPairingPayload
        let expiresAt: Int64
    }

    private enum Kind: Equatable { case pair, resume }
    private enum Phase: Equatable {
        case awaitingMessage3
        case awaitingKeyConfirmation
        case awaitingSAS
        case finalizing
        case authenticated
    }

    private final class Session {
        let kind: Kind
        let sessionID: String
        let connectionID: String
        let pairingID: String?
        let responder: NoiseXXResponder
        let expiresAt: Int64
        let requestedCapabilities: [CompanionCapability]
        let knownResumeDevice: CompanionPairedDeviceRecord?
        var phase: Phase = .awaitingMessage3
        var result: NoiseHandshakeResult?
        var channel: SecureFrameChannel?
        var context: CompanionConnectionContext?
        var sas: CompanionSAS?
        var remoteKeyConfirmed = false
        var localSASConfirmed = false
        var remoteSASConfirmed = false
        var authenticatedDevice: CompanionPairedDeviceRecord?

        init(
            kind: Kind,
            sessionID: String,
            connectionID: String,
            pairingID: String?,
            responder: NoiseXXResponder,
            expiresAt: Int64,
            requestedCapabilities: [CompanionCapability],
            knownResumeDevice: CompanionPairedDeviceRecord?
        ) {
            self.kind = kind
            self.sessionID = sessionID
            self.connectionID = connectionID
            self.pairingID = pairingID
            self.responder = responder
            self.expiresAt = expiresAt
            self.requestedCapabilities = requestedCapabilities
            self.knownResumeDevice = knownResumeDevice
        }
    }

    private let identity: CompanionIdentity
    private let roster: CompanionDeviceRosterStore
    private var offers: [String: Offer] = [:]
    private var sessionsBySocket: [String: Session] = [:]

    init(identity: CompanionIdentity, roster: CompanionDeviceRosterStore) throws {
        guard identity.role == .desktop else { throw CompanionCryptoError.roleMismatch }
        self.identity = identity
        self.roster = roster
    }

    func createOffer(
        listenerPort: UInt16,
        requestedCapabilities: [CompanionCapability] = [.observe],
        nowMilliseconds: Int64,
        ttlMilliseconds: Int64 = defaultOfferTTL,
        nonce: Data? = nil
    ) throws -> CompanionPairingPayload {
        prune(nowMilliseconds: nowMilliseconds)
        guard ttlMilliseconds > 0, ttlMilliseconds <= Self.maximumOfferTTL,
              nowMilliseconds >= 0,
              nowMilliseconds <= 9_007_199_254_740_991 - ttlMilliseconds else {
            throw CompanionPairingCoordinatorError.invalidOffer
        }
        let capabilities = try Self.normalizedCapabilities(requestedCapabilities)
        let randomNonce = try nonce ?? Self.secureRandomBytes(count: 32)
        guard randomNonce.count == 32 else { throw CompanionPairingCoordinatorError.invalidOffer }
        let payload = CompanionPairingPayload(
            desktopId: identity.id,
            identityPublic: identity.identityPublic,
            keyRecord: identity.keyRecord,
            pairingNonce: randomNonce.base64URLEncodedString(),
            requestedCapabilities: capabilities,
            transportHint: CompanionPairingTransportHint(
                service: CompanionListenerAdvertisement.serviceType,
                protocol: "tcp",
                port: Int(listenerPort)
            ),
            expiresAt: nowMilliseconds + ttlMilliseconds
        )
        try payload.validate(
            now: Date(timeIntervalSince1970: TimeInterval(nowMilliseconds) / 1_000),
            clockSkewMilliseconds: 0
        )
        offers[payload.pairingNonce] = Offer(payload: payload, expiresAt: payload.expiresAt)
        return payload
    }

    func cancelOffer(pairingID: String) -> Bool {
        offers.removeValue(forKey: pairingID) != nil
    }

    func receive(
        socketID: String,
        payload: Data,
        nowMilliseconds: Int64
    ) async throws -> CompanionPairingCoordinatorOutput {
        prune(nowMilliseconds: nowMilliseconds)
        guard !payload.isEmpty,
              payload.count <= CompanionLengthFrameDecoder.defaultMaximumFrameBytes,
              let value = try? JSONDecoder().decode(JSONValue.self, from: payload) else {
            throw CompanionPairingCoordinatorError.invalidFrame
        }
        guard let session = sessionsBySocket[socketID] else {
            guard sessionsBySocket.count < Self.maximumActiveHandshakes else {
                throw CompanionPairingCoordinatorError.serverBusy
            }
            return try await begin(socketID: socketID, value: value, nowMilliseconds: nowMilliseconds)
        }
        guard nowMilliseconds <= session.expiresAt else {
            sessionsBySocket.removeValue(forKey: socketID)
            throw CompanionPairingCoordinatorError.expired
        }
        switch session.phase {
        case .awaitingMessage3:
            return try await completeMessage3(session: session, value: value, nowMilliseconds: nowMilliseconds)
        case .awaitingKeyConfirmation:
            return try await receiveKeyConfirmation(session: session, value: value, nowMilliseconds: nowMilliseconds)
        case .awaitingSAS:
            return try await receiveRemoteSAS(session: session, value: value, nowMilliseconds: nowMilliseconds)
        case .finalizing, .authenticated:
            throw CompanionPairingCoordinatorError.handshakeOrder
        }
    }

    func confirmPairing(
        pairingID: String,
        nowMilliseconds: Int64
    ) async throws -> CompanionPairingCoordinatorOutput {
        prune(nowMilliseconds: nowMilliseconds)
        guard let session = sessionsBySocket.values.first(where: {
            $0.pairingID == pairingID && $0.kind == .pair
        }), session.phase == .awaitingSAS,
              session.remoteKeyConfirmed,
              !session.localSASConfirmed,
              let channel = session.channel,
              let result = session.result else {
            throw CompanionPairingCoordinatorError.handshakeOrder
        }
        let sasPayload: JSONValue = .object([
            "type": .string("sas-confirm"),
            "role": .string(CompanionPeerRole.desktop.rawValue),
            "transcriptHash": .string(result.handshakeHash.base64URLEncodedString()),
        ])
        let sasFrame = try channel.encrypt(sasPayload)
        session.localSASConfirmed = true
        var output = CompanionPairingCoordinatorOutput(frames: [try Self.encode(sasFrame)])
        if session.remoteSASConfirmed {
            output.frames.append(try await finalizePairing(session: session, nowMilliseconds: nowMilliseconds))
            if let device = session.authenticatedDevice {
                output.event = .authenticated(device: device, resumed: false)
            }
        }
        return output
    }

    func authenticatedConnection(socketID: String) -> CompanionAuthenticatedConnection? {
        guard let session = sessionsBySocket[socketID],
              session.phase == .authenticated,
              let device = session.authenticatedDevice,
              let channel = session.channel,
              let context = session.context else { return nil }
        return CompanionAuthenticatedConnection(
            device: device,
            channel: channel,
            context: context,
            resumed: session.kind == .resume
        )
    }

    func release(socketID: String) {
        sessionsBySocket.removeValue(forKey: socketID)
    }

    private func begin(
        socketID: String,
        value: JSONValue,
        nowMilliseconds: Int64
    ) async throws -> CompanionPairingCoordinatorOutput {
        let object = try Self.strictObject(value, allowed: [
            "v", "type", "qrPayload", "deviceId", "connectionId", "message1",
        ])
        guard object["v"]?.intValue == Int64(CompanionCrypto.protocolVersion),
              let type = object["type"]?.stringValue,
              let connectionID = object["connectionId"]?.stringValue,
              let message1Text = object["message1"]?.stringValue,
              let message1 = Data(base64URLString: message1Text) else {
            throw CompanionPairingCoordinatorError.invalidFrame
        }
        _ = try CompanionCrypto.validateIdentifier(connectionID, label: "connectionId")

        switch type {
        case "pair.start":
            guard object["deviceId"] == nil, let qrValue = object["qrPayload"],
                  let qrPayload = try? JSONDecoder().decode(
                    CompanionPairingPayload.self,
                    from: CanonicalJSON.data(from: qrValue)
                  ) else { throw CompanionPairingCoordinatorError.invalidFrame }
            do {
                try qrPayload.validate(
                    now: Date(timeIntervalSince1970: TimeInterval(nowMilliseconds) / 1_000),
                    clockSkewMilliseconds: 0
                )
            } catch {
                throw CompanionPairingCoordinatorError.invalidOffer
            }
            guard let offer = offers.removeValue(forKey: qrPayload.pairingNonce) else {
                throw CompanionPairingCoordinatorError.offerUnavailable
            }
            // Claim the nonce before any DH work: malformed starts consume the
            // QR exactly as the reference host does.
            guard offer.payload == qrPayload, offer.expiresAt >= nowMilliseconds else {
                throw CompanionPairingCoordinatorError.invalidOffer
            }
            let responder = try NoiseXXResponder(
                identity: identity,
                prologue: createNoisePrologue(try qrPayload.handshakeContext(connectionId: connectionID))
            )
            try responder.readMessage1(message1)
            let sessionID = "pair-\(UUID().uuidString.lowercased())"
            let session = Session(
                kind: .pair,
                sessionID: sessionID,
                connectionID: connectionID,
                pairingID: qrPayload.pairingNonce,
                responder: responder,
                expiresAt: min(qrPayload.expiresAt, nowMilliseconds + Self.handshakeTTL),
                requestedCapabilities: qrPayload.requestedCapabilities,
                knownResumeDevice: nil
            )
            sessionsBySocket[socketID] = session
            return CompanionPairingCoordinatorOutput(frames: [try Self.encode(JSONValue.object([
                "v": .integer(Int64(CompanionCrypto.protocolVersion)),
                "type": .string("pair.message2"),
                "sessionId": .string(sessionID),
                "pairingId": .string(qrPayload.pairingNonce),
                "message2": .string(try responder.writeMessage2().base64URLEncodedString()),
            ]))])

        case "resume.start":
            guard object["qrPayload"] == nil,
                  let deviceID = object["deviceId"]?.stringValue else {
                throw CompanionPairingCoordinatorError.invalidFrame
            }
            _ = try CompanionCrypto.validateIdentifier(deviceID, label: "deviceId")
            let known = await roster.device(deviceID)
            let pin: CompanionIdentityPin
            if let known {
                pin = known.pin
            } else {
                pin = CompanionIdentityPin(
                    id: deviceID,
                    identityPublic: try Self.secureRandomBytes(count: 32).base64URLEncodedString(),
                    x25519StaticPublic: try Self.secureRandomBytes(count: 32).base64URLEncodedString()
                )
            }
            let contextValue: JSONValue = .object([
                "v": .integer(Int64(CompanionCrypto.protocolVersion)),
                "mode": .string("resume"),
                "protocol": .string(CompanionCrypto.noiseProtocol),
                "desktopId": .string(identity.id),
                "deviceId": .string(deviceID),
                "connectionId": .string(connectionID),
            ])
            let responder = try NoiseXXResponder(
                identity: identity,
                prologue: createNoisePrologue(contextValue),
                peerPin: pin
            )
            try responder.readMessage1(message1)
            let sessionID = "resume-\(UUID().uuidString.lowercased())"
            let session = Session(
                kind: .resume,
                sessionID: sessionID,
                connectionID: connectionID,
                pairingID: nil,
                responder: responder,
                expiresAt: nowMilliseconds + Self.handshakeTTL,
                requestedCapabilities: known?.capabilities ?? [.observe],
                knownResumeDevice: known
            )
            sessionsBySocket[socketID] = session
            return CompanionPairingCoordinatorOutput(frames: [try Self.encode(JSONValue.object([
                "v": .integer(Int64(CompanionCrypto.protocolVersion)),
                "type": .string("resume.message2"),
                "sessionId": .string(sessionID),
                "message2": .string(try responder.writeMessage2().base64URLEncodedString()),
            ]))])

        default:
            throw CompanionPairingCoordinatorError.invalidFrame
        }
    }

    private func completeMessage3(
        session: Session,
        value: JSONValue,
        nowMilliseconds: Int64
    ) async throws -> CompanionPairingCoordinatorOutput {
        let object = try Self.strictObject(value, allowed: ["v", "type", "sessionId", "message3"])
        let expectedType = session.kind == .pair ? "pair.message3" : "resume.message3"
        guard object["v"]?.intValue == Int64(CompanionCrypto.protocolVersion),
              object["type"]?.stringValue == expectedType,
              object["sessionId"]?.stringValue == session.sessionID,
              let messageText = object["message3"]?.stringValue,
              let message = Data(base64URLString: messageText) else {
            throw CompanionPairingCoordinatorError.invalidFrame
        }
        let peer: CompanionIdentityPin
        let result: NoiseHandshakeResult
        do {
            peer = try session.responder.readMessage3(message)
            result = try session.responder.result()
        } catch {
            throw CompanionPairingCoordinatorError.authenticationFailed
        }
        if session.kind == .pair {
            guard await roster.device(peer.id) == nil else {
                throw CompanionPairingCoordinatorError.duplicateDevice
            }
        } else {
            guard let known = session.knownResumeDevice, peer == known.pin else {
                throw CompanionPairingCoordinatorError.authenticationFailed
            }
        }
        let context = CompanionConnectionContext(
            desktopId: identity.id,
            deviceId: peer.id,
            connectionId: session.connectionID
        )
        let channel = try SecureFrameChannel(result: result, context: context, role: .desktop)
        let confirmation = try CompanionKeyConfirmation.make(
            channel: channel,
            role: .desktop,
            handshakeHash: result.handshakeHash
        )
        session.result = result
        session.channel = channel
        session.context = context
        session.sas = session.kind == .pair ? CompanionSAS.derive(handshakeHash: result.handshakeHash) : nil
        session.phase = .awaitingKeyConfirmation
        var fields: [String: JSONValue] = [
            "v": .integer(Int64(CompanionCrypto.protocolVersion)),
            "type": .string(session.kind == .pair ? "pair.confirmation" : "resume.confirmation"),
            "sessionId": .string(session.sessionID),
            "confirmationFrame": try JSONValue.from(confirmation),
        ]
        if let sas = session.sas { fields["sas"] = try JSONValue.from(sas) }
        return CompanionPairingCoordinatorOutput(frames: [try Self.encode(JSONValue.object(fields))])
    }

    private func receiveKeyConfirmation(
        session: Session,
        value: JSONValue,
        nowMilliseconds: Int64
    ) async throws -> CompanionPairingCoordinatorOutput {
        guard !session.remoteKeyConfirmed, let channel = session.channel, let result = session.result else {
            throw CompanionPairingCoordinatorError.handshakeOrder
        }
        let frame = try Self.decodeSecureFrame(value)
        do {
            try CompanionKeyConfirmation.verify(
                channel: channel,
                frame: frame,
                expectedRole: .device,
                handshakeHash: result.handshakeHash
            )
        } catch {
            throw CompanionPairingCoordinatorError.authenticationFailed
        }
        session.remoteKeyConfirmed = true
        if session.kind == .resume {
            guard let known = session.knownResumeDevice else {
                throw CompanionPairingCoordinatorError.authenticationFailed
            }
            try await roster.markSeen(known.deviceId, now: nowMilliseconds)
            let refreshed = await roster.device(known.deviceId) ?? known
            session.authenticatedDevice = refreshed
            session.phase = .authenticated
            return CompanionPairingCoordinatorOutput(
                event: .authenticated(device: refreshed, resumed: true)
            )
        }
        guard let pairingID = session.pairingID,
              let sas = session.sas,
              let peer = session.result?.peer else {
            throw CompanionPairingCoordinatorError.authenticationFailed
        }
        session.phase = .awaitingSAS
        return CompanionPairingCoordinatorOutput(event: .pairingPhrase(
            pairingID: pairingID,
            sessionID: session.sessionID,
            deviceID: peer.id,
            displayName: result.peerDisplayName ?? "Kaisola Device",
            sas: sas
        ))
    }

    private func receiveRemoteSAS(
        session: Session,
        value: JSONValue,
        nowMilliseconds: Int64
    ) async throws -> CompanionPairingCoordinatorOutput {
        guard session.kind == .pair,
              session.remoteKeyConfirmed,
              !session.remoteSASConfirmed,
              let channel = session.channel,
              let result = session.result else {
            throw CompanionPairingCoordinatorError.handshakeOrder
        }
        let frame = try Self.decodeSecureFrame(value)
        let decrypted: JSONValue
        do { decrypted = try channel.decryptJSON(frame) }
        catch { throw CompanionPairingCoordinatorError.authenticationFailed }
        let object = try Self.strictObject(
            decrypted,
            allowed: ["type", "role", "transcriptHash"]
        )
        guard object["type"]?.stringValue == "sas-confirm",
              object["role"]?.stringValue == CompanionPeerRole.device.rawValue,
              object["transcriptHash"]?.stringValue == result.handshakeHash.base64URLEncodedString() else {
            throw CompanionPairingCoordinatorError.authenticationFailed
        }
        session.remoteSASConfirmed = true
        guard session.localSASConfirmed else { return CompanionPairingCoordinatorOutput() }
        let paired = try await finalizePairing(session: session, nowMilliseconds: nowMilliseconds)
        return CompanionPairingCoordinatorOutput(
            frames: [paired],
            event: session.authenticatedDevice.map {
                .authenticated(device: $0, resumed: false)
            }
        )
    }

    private func finalizePairing(session: Session, nowMilliseconds: Int64) async throws -> Data {
        guard session.phase == .awaitingSAS,
              session.localSASConfirmed,
              session.remoteSASConfirmed,
              session.remoteKeyConfirmed,
              let result = session.result,
              let channel = session.channel else {
            throw CompanionPairingCoordinatorError.handshakeOrder
        }
        session.phase = .finalizing
        do {
            let record = try await roster.pair(
                peer: result.peer,
                displayName: result.peerDisplayName ?? "Kaisola Device",
                capabilities: session.requestedCapabilities,
                now: nowMilliseconds
            )
            let payload: JSONValue = .object([
                "type": .string("paired"),
                "deviceId": .string(record.deviceId),
                "capabilities": try JSONValue.from(record.capabilities),
                "transcriptHash": .string(result.handshakeHash.base64URLEncodedString()),
            ])
            let pairedFrame = try channel.encrypt(payload)
            session.authenticatedDevice = record
            session.phase = .authenticated
            return try Self.encode(pairedFrame)
        } catch {
            session.phase = .awaitingSAS
            throw error
        }
    }

    private func prune(nowMilliseconds: Int64) {
        offers = offers.filter { nowMilliseconds <= $0.value.expiresAt }
        sessionsBySocket = sessionsBySocket.filter {
            $0.value.phase == .authenticated || nowMilliseconds <= $0.value.expiresAt
        }
    }

    private static func normalizedCapabilities(
        _ values: [CompanionCapability]
    ) throws -> [CompanionCapability] {
        guard !values.isEmpty,
              values.contains(.observe),
              Set(values).count == values.count,
              values.count <= CompanionCapability.allCases.count else {
            throw CompanionPairingCoordinatorError.invalidOffer
        }
        return CompanionCapability.allCases.filter(values.contains)
    }

    private static func strictObject(
        _ value: JSONValue,
        allowed: Set<String>
    ) throws -> [String: JSONValue] {
        guard let object = value.objectValue,
              Set(object.keys).isSubset(of: allowed) else {
            throw CompanionPairingCoordinatorError.invalidFrame
        }
        return object
    }

    private static func decodeSecureFrame(_ value: JSONValue) throws -> CompanionSecureFrame {
        _ = try strictObject(value, allowed: [
            "v", "desktopId", "deviceId", "connectionId", "direction",
            "counter", "ciphertextLength", "ciphertext",
        ])
        do {
            return try JSONDecoder().decode(
                CompanionSecureFrame.self,
                from: CanonicalJSON.data(from: value)
            )
        } catch {
            throw CompanionPairingCoordinatorError.invalidFrame
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try CanonicalJSON.data(from: value)
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CompanionPairingCoordinatorError.authenticationFailed
        }
        return data
    }
}
