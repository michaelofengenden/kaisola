import KaisolaCore
import CryptoKit
import XCTest
@testable import KaisolaCompanion

final class CryptoNoiseVectorTests: XCTestCase {
    private var vector: [String: JSONValue]!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "crypto-noise-xx-v1", withExtension: "json"))
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        vector = try XCTUnwrap(root.objectValue)
    }

    func testNoiseHandshakeInteroperatesWithNodeGoldenAndCompletesInBothRoles() throws {
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

        // CryptoKit intentionally does not promise deterministic Ed25519 signature bytes.
        // Verify the deterministic portion and consume Node's signed responder message to
        // prove that the Swift initiator accepts the exact desktop proof from the fixture.
        let goldenInitiator = try NoiseXXInitiator(
            identity: device,
            prologue: prologue,
            peerPin: try desktopPin(),
            ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: hex(ephemerals, "device")
            )
        )
        XCTAssertEqual(try goldenInitiator.writeMessage1(), try decoded(handshake, "message1"))
        XCTAssertEqual(try goldenInitiator.readMessage2(decoded(handshake, "message2")).id, desktop.id)
    }

    func testSecureFramesEncryptDecryptAndConfirmExactlyLikeNode() throws {
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

    func testDirectionalCounterRejectsReplay() throws {
        let result = try goldenHandshakeResult()
        let context = try connectionContext()
        let keyConfirmation = try XCTUnwrap(vector["keyConfirmation"]?.objectValue)
        let application = try XCTUnwrap(vector["application"]?.objectValue)
        let desktopChannel = try SecureFrameChannel(result: result, context: context, role: .desktop)
        try CompanionKeyConfirmation.verify(
            channel: desktopChannel,
            frame: try secureFrame(keyConfirmation, "deviceFrame"),
            expectedRole: .device,
            handshakeHash: result.handshakeHash
        )
        let frame = try secureFrame(application, "frame")
        _ = try desktopChannel.decrypt(frame)
        XCTAssertThrowsError(try desktopChannel.decrypt(frame)) { error in
            XCTAssertEqual(error as? CompanionCryptoError, .replayOrOutOfOrder)
        }
    }

    func testSecureFrameRejectsTamperingWithoutAdvancingCounter() throws {
        let result = try goldenHandshakeResult()
        let context = try connectionContext()
        let keyConfirmation = try XCTUnwrap(vector["keyConfirmation"]?.objectValue)
        let application = try XCTUnwrap(vector["application"]?.objectValue)
        let desktopChannel = try SecureFrameChannel(result: result, context: context, role: .desktop)
        try CompanionKeyConfirmation.verify(
            channel: desktopChannel,
            frame: try secureFrame(keyConfirmation, "deviceFrame"),
            expectedRole: .device,
            handshakeHash: result.handshakeHash
        )
        let valid = try secureFrame(application, "frame")
        var combined = try XCTUnwrap(Data(base64URLString: valid.ciphertext))
        combined[combined.startIndex] ^= 0x01
        var tampered = valid
        tampered.ciphertext = combined.base64URLEncodedString()
        XCTAssertThrowsError(try desktopChannel.decrypt(tampered)) { error in
            XCTAssertEqual(error as? CompanionCryptoError, .authenticationFailed)
        }
        XCTAssertNoThrow(try desktopChannel.decrypt(valid), "failed authentication must not consume the receive counter")
    }

    func testSASMatchesNodeVector() throws {
        let handshake = try XCTUnwrap(vector["handshake"]?.objectValue)
        let expected = try XCTUnwrap(vector["sas"])
        XCTAssertEqual(
            try JSONValue.from(CompanionSAS.derive(handshakeHash: decoded(handshake, "finalHash"))),
            expected
        )
    }

    func testPairingPayloadHashAndPrologueMatchNode() throws {
        let qrValue = try XCTUnwrap(vector["qrPayload"])
        let qr = try JSONDecoder().decode(
            CompanionPairingPayload.self,
            from: CanonicalJSON.data(from: qrValue)
        )
        let handshake = try XCTUnwrap(vector["handshake"]?.objectValue)
        let context = try XCTUnwrap(handshake["context"])
        XCTAssertEqual(try qr.handshakeContext(connectionId: "connection-vector-0001"), context)
        XCTAssertEqual(try createNoisePrologue(context), try decoded(handshake, "prologue"))
    }

    private func goldenHandshakeResult() throws -> NoiseHandshakeResult {
        let identities = try XCTUnwrap(vector["identities"]?.objectValue)
        let handshake = try XCTUnwrap(vector["handshake"]?.objectValue)
        let desktopVector = try XCTUnwrap(identities["desktop"]?.objectValue)
        return NoiseHandshakeResult(
            handshakeHash: try decoded(handshake, "finalHash"),
            splitKeys: try stringArray(handshake, "splitKeys").map(decode),
            peer: CompanionIdentityPin(
                id: try XCTUnwrap(desktopVector["id"]?.stringValue),
                identityPublic: try XCTUnwrap(desktopVector["identityPublic"]?.stringValue),
                x25519StaticPublic: try XCTUnwrap(desktopVector["x25519StaticPublic"]?.stringValue)
            )
        )
    }

    private func verifyGoldenKeyRecord(
        _ identity: [String: JSONValue],
        expectedRole: CompanionPeerRole
    ) throws {
        let value = try XCTUnwrap(identity["signedKeyRecord"])
        let record = try JSONDecoder().decode(
            CompanionSignedKeyRecord.self,
            from: CanonicalJSON.data(from: value)
        )
        try record.verify(
            identityPublic: try XCTUnwrap(identity["identityPublic"]?.stringValue),
            expectedRole: expectedRole,
            expectedId: try XCTUnwrap(identity["id"]?.stringValue)
        )
    }

    private func makeIdentity(_ object: [String: JSONValue], role: CompanionPeerRole) throws -> CompanionIdentity {
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
        let value = try XCTUnwrap(pins["desktop"])
        return try JSONDecoder().decode(CompanionIdentityPin.self, from: CanonicalJSON.data(from: value))
    }

    private func connectionContext() throws -> CompanionConnectionContext {
        let connection = try XCTUnwrap(vector["connection"]?.objectValue)
        return CompanionConnectionContext(
            desktopId: try XCTUnwrap(connection["desktopId"]?.stringValue),
            deviceId: try XCTUnwrap(connection["deviceId"]?.stringValue),
            connectionId: try XCTUnwrap(connection["connectionId"]?.stringValue)
        )
    }

    private func secureFrame(_ object: [String: JSONValue], _ key: String) throws -> CompanionSecureFrame {
        let value = try XCTUnwrap(object[key])
        return try JSONDecoder().decode(CompanionSecureFrame.self, from: CanonicalJSON.data(from: value))
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
