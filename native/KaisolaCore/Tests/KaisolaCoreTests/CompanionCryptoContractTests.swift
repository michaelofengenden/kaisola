import CryptoKit
import Foundation
import KaisolaCore
import KaisolaTestSupport
import XCTest

final class CompanionCryptoContractTests: XCTestCase {
    private var vector: [String: JSONValue] = [:]

    override func setUpWithError() throws {
        let url = try RepositoryFixtures.companionFixture(named: "crypto-noise-xx-v1")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        vector = try XCTUnwrap(root.objectValue)
    }

    func testNoiseXXHandshakeConsumesNodeGoldenAndCompletesInBothRoles() throws {
        let identities = try XCTUnwrap(vector["identities"]?.objectValue)
        let desktopVector = try XCTUnwrap(identities["desktop"]?.objectValue)
        let deviceVector = try XCTUnwrap(identities["device"]?.objectValue)
        let ephemerals = try XCTUnwrap(vector["ephemeralSeeds"]?.objectValue)
        let handshake = try XCTUnwrap(vector["handshake"]?.objectValue)

        let desktop = try makeIdentity(desktopVector, role: .desktop)
        let device = try makeIdentity(deviceVector, role: .device)
        XCTAssertEqual(desktop.identityPublic, desktopVector["identityPublic"]?.stringValue)
        XCTAssertEqual(desktop.x25519StaticPublic, desktopVector["x25519StaticPublic"]?.stringValue)
        XCTAssertEqual(device.identityPublic, deviceVector["identityPublic"]?.stringValue)
        XCTAssertEqual(device.x25519StaticPublic, deviceVector["x25519StaticPublic"]?.stringValue)
        try verifyGoldenKeyRecord(desktopVector, expectedRole: .desktop)
        try verifyGoldenKeyRecord(deviceVector, expectedRole: .device)

        let prologue = try decoded(handshake, "prologue")
        let initiator = try NoiseXXInitiator(
            identity: device,
            prologue: prologue,
            peerPin: try desktopPin(),
            ephemeralPrivateKey: try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: hex(ephemerals, "device")
            )
        )
        let responder = try NoiseXXResponder(
            identity: desktop,
            prologue: prologue,
            peerPin: CompanionIdentityPin(
                id: device.id,
                identityPublic: device.identityPublic,
                x25519StaticPublic: device.x25519StaticPublic
            ),
            ephemeralPrivateKey: try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: hex(ephemerals, "desktop")
            )
        )

        let message1 = try initiator.writeMessage1()
        XCTAssertEqual(message1, try decoded(handshake, "message1"))
        try responder.readMessage1(message1)
        let message2 = try responder.writeMessage2()
        XCTAssertEqual(try initiator.readMessage2(message2).id, desktop.id)
        let message3 = try initiator.writeMessage3()
        XCTAssertEqual(try responder.readMessage3(message3).id, device.id)

        let initiatorResult = try initiator.result()
        let responderResult = try responder.result()
        XCTAssertEqual(responderResult.handshakeHash, initiatorResult.handshakeHash)
        XCTAssertEqual(responderResult.splitKeys, initiatorResult.splitKeys)
        XCTAssertEqual(initiatorResult.peerDisplayName, desktop.displayName)
        XCTAssertEqual(responderResult.peerDisplayName, device.displayName)

        // Swift signatures are valid but not promised to be byte-deterministic. Consume
        // Node's exact responder frame separately to prove cross-language verification.
        let goldenInitiator = try NoiseXXInitiator(
            identity: device,
            prologue: prologue,
            peerPin: try desktopPin(),
            ephemeralPrivateKey: try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: hex(ephemerals, "device")
            )
        )
        XCTAssertEqual(try goldenInitiator.writeMessage1(), try decoded(handshake, "message1"))
        XCTAssertEqual(
            try goldenInitiator.readMessage2(decoded(handshake, "message2")).id,
            desktop.id
        )
    }

    func testSecureFramesAndKeyConfirmationMatchNodeGolden() throws {
        let result = try goldenHandshakeResult()
        let context = try connectionContext()
        let keyConfirmation = try XCTUnwrap(vector["keyConfirmation"]?.objectValue)
        let application = try XCTUnwrap(vector["application"]?.objectValue)
        let expectedDesktopFrame = try secureFrame(keyConfirmation, "desktopFrame")
        let expectedDeviceFrame = try secureFrame(keyConfirmation, "deviceFrame")
        let expectedApplicationFrame = try secureFrame(application, "frame")

        let deviceChannel = try SecureFrameChannel(result: result, context: context, role: .device)
        let desktopChannel = try SecureFrameChannel(result: result, context: context, role: .desktop)

        XCTAssertEqual(
            try CompanionKeyConfirmation.make(
                channel: desktopChannel,
                role: .desktop,
                handshakeHash: result.handshakeHash
            ),
            expectedDesktopFrame
        )
        XCTAssertEqual(
            try CompanionKeyConfirmation.make(
                channel: deviceChannel,
                role: .device,
                handshakeHash: result.handshakeHash
            ),
            expectedDeviceFrame
        )
        try CompanionKeyConfirmation.verify(
            channel: deviceChannel,
            frame: expectedDesktopFrame,
            expectedRole: .desktop,
            handshakeHash: result.handshakeHash
        )
        try CompanionKeyConfirmation.verify(
            channel: desktopChannel,
            frame: expectedDeviceFrame,
            expectedRole: .device,
            handshakeHash: result.handshakeHash
        )

        let plaintext = try XCTUnwrap(application["plaintext"])
        let encrypted = try deviceChannel.encrypt(plaintext)
        XCTAssertEqual(encrypted, expectedApplicationFrame)
        XCTAssertEqual(try desktopChannel.decryptJSON(encrypted), plaintext)
    }

    func testSecureChannelRejectsReplayAndOutOfOrderFrames() throws {
        let result = try goldenHandshakeResult()
        let context = try connectionContext()
        let sender = try SecureFrameChannel(result: result, context: context, role: .device)
        let receiver = try SecureFrameChannel(result: result, context: context, role: .desktop)
        let first = try sender.encrypt(JSONValue.string("first"))
        let second = try sender.encrypt(JSONValue.string("second"))

        XCTAssertThrowsError(try receiver.decrypt(second)) { error in
            XCTAssertEqual(error as? CompanionCryptoError, .replayOrOutOfOrder)
        }
        XCTAssertEqual(try receiver.decryptJSON(first), .string("first"))
        XCTAssertEqual(try receiver.decryptJSON(second), .string("second"))
        XCTAssertThrowsError(try receiver.decrypt(second)) { error in
            XCTAssertEqual(error as? CompanionCryptoError, .replayOrOutOfOrder)
        }
        XCTAssertEqual(receiver.counters.receive, 2)
    }

    func testAuthenticationFailureDoesNotConsumeReceiveCounter() throws {
        let result = try goldenHandshakeResult()
        let context = try connectionContext()
        let sender = try SecureFrameChannel(result: result, context: context, role: .device)
        let receiver = try SecureFrameChannel(result: result, context: context, role: .desktop)
        let valid = try sender.encrypt(JSONValue.object(["type": .string("ping")]))
        var combined = try XCTUnwrap(Data(base64URLString: valid.ciphertext))
        combined[combined.startIndex] ^= 0x01
        var tampered = valid
        tampered.ciphertext = combined.base64URLEncodedString()

        XCTAssertThrowsError(try receiver.decrypt(tampered)) { error in
            XCTAssertEqual(error as? CompanionCryptoError, .authenticationFailed)
        }
        XCTAssertEqual(receiver.counters.receive, 0)
        XCTAssertEqual(
            try receiver.decryptJSON(valid),
            .object(["type": .string("ping")])
        )
        XCTAssertEqual(receiver.counters.receive, 1)
    }

    func testSASPairingHashAndPrologueMatchNodeGolden() throws {
        let handshake = try XCTUnwrap(vector["handshake"]?.objectValue)
        XCTAssertEqual(
            try JSONValue.from(CompanionSAS.derive(handshakeHash: decoded(handshake, "finalHash"))),
            try XCTUnwrap(vector["sas"])
        )

        let pairingValue = try XCTUnwrap(vector["qrPayload"])
        let pairing = try JSONDecoder().decode(
            CompanionPairingPayload.self,
            from: CanonicalJSON.data(from: pairingValue)
        )
        let context = try XCTUnwrap(handshake["context"])
        XCTAssertEqual(try pairing.handshakeContext(connectionId: "connection-vector-0001"), context)
        XCTAssertEqual(try createNoisePrologue(context), try decoded(handshake, "prologue"))
    }

    private func goldenHandshakeResult() throws -> NoiseHandshakeResult {
        let identities = try XCTUnwrap(vector["identities"]?.objectValue)
        let handshake = try XCTUnwrap(vector["handshake"]?.objectValue)
        let desktop = try XCTUnwrap(identities["desktop"]?.objectValue)
        return NoiseHandshakeResult(
            handshakeHash: try decoded(handshake, "finalHash"),
            splitKeys: try stringArray(handshake, "splitKeys").map(decode),
            peer: CompanionIdentityPin(
                id: try XCTUnwrap(desktop["id"]?.stringValue),
                identityPublic: try XCTUnwrap(desktop["identityPublic"]?.stringValue),
                x25519StaticPublic: try XCTUnwrap(desktop["x25519StaticPublic"]?.stringValue)
            )
        )
    }

    private func verifyGoldenKeyRecord(
        _ identity: [String: JSONValue],
        expectedRole: CompanionPeerRole
    ) throws {
        let record = try JSONDecoder().decode(
            CompanionSignedKeyRecord.self,
            from: CanonicalJSON.data(from: XCTUnwrap(identity["signedKeyRecord"]))
        )
        try record.verify(
            identityPublic: try XCTUnwrap(identity["identityPublic"]?.stringValue),
            expectedRole: expectedRole,
            expectedId: try XCTUnwrap(identity["id"]?.stringValue)
        )
    }

    private func makeIdentity(
        _ object: [String: JSONValue],
        role: CompanionPeerRole
    ) throws -> CompanionIdentity {
        try CompanionIdentity.testIdentity(
            id: try XCTUnwrap(object["id"]?.stringValue),
            role: role,
            displayName: try XCTUnwrap(object["displayName"]?.stringValue),
            signingSeed: hex(object, "ed25519Seed"),
            agreementSeed: hex(object, "x25519StaticSeed")
        )
    }

    private func desktopPin() throws -> CompanionIdentityPin {
        let pins = try XCTUnwrap(vector["pins"]?.objectValue)
        return try JSONDecoder().decode(
            CompanionIdentityPin.self,
            from: CanonicalJSON.data(from: XCTUnwrap(pins["desktop"]))
        )
    }

    private func connectionContext() throws -> CompanionConnectionContext {
        let connection = try XCTUnwrap(vector["connection"]?.objectValue)
        return CompanionConnectionContext(
            desktopId: try XCTUnwrap(connection["desktopId"]?.stringValue),
            deviceId: try XCTUnwrap(connection["deviceId"]?.stringValue),
            connectionId: try XCTUnwrap(connection["connectionId"]?.stringValue)
        )
    }

    private func secureFrame(
        _ object: [String: JSONValue],
        _ key: String
    ) throws -> CompanionSecureFrame {
        try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: CanonicalJSON.data(from: XCTUnwrap(object[key]))
        )
    }

    private func decoded(_ object: [String: JSONValue], _ key: String) throws -> Data {
        try decode(XCTUnwrap(object[key]?.stringValue))
    }

    private func decode(_ value: String) throws -> Data {
        try XCTUnwrap(Data(base64URLString: value))
    }

    private func hex(_ object: [String: JSONValue], _ key: String) throws -> Data {
        try XCTUnwrap(Data(hexString: XCTUnwrap(object[key]?.stringValue)))
    }

    private func stringArray(_ object: [String: JSONValue], _ key: String) throws -> [String] {
        try XCTUnwrap(object[key]?.arrayValue).map { try XCTUnwrap($0.stringValue) }
    }
}
