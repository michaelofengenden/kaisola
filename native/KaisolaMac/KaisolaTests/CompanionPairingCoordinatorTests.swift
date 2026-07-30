import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

final class CompanionPairingCoordinatorTests: XCTestCase {
    func testPairingRequiresBothSASConfirmationsAndPersistsAuthenticatedDevice() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let now: Int64 = 1_800_000_000_000
        let nonce = Data((0..<32).map(UInt8.init))
        let offer = try await fixture.coordinator.createOffer(
            listenerPort: 49_321,
            requestedCapabilities: [.observe, .terminalControl],
            nowMilliseconds: now,
            nonce: nonce
        )
        let connectionID = "connection-pair-test"
        let initiator = try NoiseXXInitiator(
            identity: fixture.device,
            prologue: createNoisePrologue(try offer.handshakeContext(connectionId: connectionID)),
            peerPin: offer.desktopPin
        )

        let message1 = try initiator.writeMessage1()
        let started = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try encode(JSONValue.object([
                "v": .integer(Int64(1)),
                "type": .string("pair.start"),
                "qrPayload": try JSONValue.from(offer),
                "connectionId": .string(connectionID),
                "message1": .string(message1.base64URLEncodedString()),
            ])),
            nowMilliseconds: now + 1
        )
        let message2Frame = try object(try XCTUnwrap(started.frames.first))
        XCTAssertEqual(message2Frame["type"]?.stringValue, "pair.message2")
        let sessionID = try XCTUnwrap(message2Frame["sessionId"]?.stringValue)
        let message2 = try XCTUnwrap(
            message2Frame["message2"]?.stringValue.flatMap(Data.init(base64URLString:))
        )
        XCTAssertEqual(try initiator.readMessage2(message2), offer.desktopPin)

        let message3 = try initiator.writeMessage3()
        let confirmed = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try encode(JSONValue.object([
                "v": .integer(Int64(1)),
                "type": .string("pair.message3"),
                "sessionId": .string(sessionID),
                "message3": .string(message3.base64URLEncodedString()),
            ])),
            nowMilliseconds: now + 2
        )
        let confirmationObject = try object(try XCTUnwrap(confirmed.frames.first))
        XCTAssertEqual(confirmationObject["type"]?.stringValue, "pair.confirmation")
        let desktopConfirmation = try decodeSecureFrame(
            try XCTUnwrap(confirmationObject["confirmationFrame"])
        )
        let result = try initiator.result()
        let context = CompanionConnectionContext(
            desktopId: fixture.desktop.id,
            deviceId: fixture.device.id,
            connectionId: connectionID
        )
        let deviceChannel = try SecureFrameChannel(result: result, context: context, role: .device)
        try CompanionKeyConfirmation.verify(
            channel: deviceChannel,
            frame: desktopConfirmation,
            expectedRole: .desktop,
            handshakeHash: result.handshakeHash
        )

        let deviceConfirmation = try CompanionKeyConfirmation.make(
            channel: deviceChannel,
            role: .device,
            handshakeHash: result.handshakeHash
        )
        let phrase = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try encode(deviceConfirmation),
            nowMilliseconds: now + 3
        )
        guard case let .pairingPhrase(pairingID, receivedSessionID, deviceID, displayName, sas) = phrase.event else {
            return XCTFail("Expected a pairing phrase after reciprocal key confirmation")
        }
        XCTAssertEqual(pairingID, offer.pairingNonce)
        XCTAssertEqual(receivedSessionID, sessionID)
        XCTAssertEqual(deviceID, fixture.device.id)
        XCTAssertEqual(displayName, fixture.device.displayName)
        XCTAssertEqual(sas, CompanionSAS.derive(handshakeHash: result.handshakeHash))
        let rosterBeforeConfirmation = await fixture.roster.list()
        XCTAssertTrue(rosterBeforeConfirmation.isEmpty)

        let localSAS = try await fixture.coordinator.confirmPairing(
            pairingID: pairingID,
            nowMilliseconds: now + 4
        )
        XCTAssertEqual(localSAS.frames.count, 1)
        let localSASFrame = try decodeSecureFrameData(localSAS.frames[0])
        let localSASPayload = try deviceChannel.decryptJSON(localSASFrame)
        XCTAssertEqual(localSASPayload.objectValue?["type"]?.stringValue, "sas-confirm")
        let rosterBeforeRemoteSAS = await fixture.roster.list()
        XCTAssertTrue(rosterBeforeRemoteSAS.isEmpty)

        let remoteSAS = try deviceChannel.encrypt(JSONValue.object([
            "type": .string("sas-confirm"),
            "role": .string(CompanionPeerRole.device.rawValue),
            "transcriptHash": .string(result.handshakeHash.base64URLEncodedString()),
        ]))
        let paired = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try encode(remoteSAS),
            nowMilliseconds: now + 5
        )
        XCTAssertEqual(paired.frames.count, 1)
        let pairedPayload = try deviceChannel.decryptJSON(
            try decodeSecureFrameData(paired.frames[0])
        )
        XCTAssertEqual(pairedPayload.objectValue?["type"]?.stringValue, "paired")
        XCTAssertEqual(pairedPayload.objectValue?["deviceId"]?.stringValue, fixture.device.id)
        guard case let .authenticated(device, resumed) = paired.event else {
            return XCTFail("Expected authenticated event after paired frame")
        }
        XCTAssertFalse(resumed)
        XCTAssertEqual(device.deviceId, fixture.device.id)
        XCTAssertEqual(device.capabilities, [.observe, .terminalControl])
        let persistedDevices = await fixture.roster.list()
        let authenticatedConnection = await fixture.coordinator.authenticatedConnection(
            socketID: "socket-pair"
        )
        XCTAssertEqual(persistedDevices, [device])
        XCTAssertNotNil(authenticatedConnection)
    }

    func testResumeAuthenticatesPinnedDeviceWithoutSASAndMarksItSeen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let now: Int64 = 1_800_000_100_000
        _ = try await fixture.roster.pair(
            peer: fixture.devicePin,
            displayName: fixture.device.displayName,
            capabilities: [.observe],
            now: now
        )
        let connectionID = "connection-resume-test"
        let contextValue: JSONValue = .object([
            "v": .integer(Int64(1)),
            "mode": .string("resume"),
            "protocol": .string(CompanionCrypto.noiseProtocol),
            "desktopId": .string(fixture.desktop.id),
            "deviceId": .string(fixture.device.id),
            "connectionId": .string(connectionID),
        ])
        let initiator = try NoiseXXInitiator(
            identity: fixture.device,
            prologue: createNoisePrologue(contextValue),
            peerPin: fixture.desktopPin
        )
        let started = try await fixture.coordinator.receive(
            socketID: "socket-resume",
            payload: try encode(JSONValue.object([
                "v": .integer(Int64(1)),
                "type": .string("resume.start"),
                "deviceId": .string(fixture.device.id),
                "connectionId": .string(connectionID),
                "message1": .string(try initiator.writeMessage1().base64URLEncodedString()),
            ])),
            nowMilliseconds: now + 10
        )
        let message2Frame = try object(try XCTUnwrap(started.frames.first))
        let sessionID = try XCTUnwrap(message2Frame["sessionId"]?.stringValue)
        let message2 = try XCTUnwrap(
            message2Frame["message2"]?.stringValue.flatMap(Data.init(base64URLString:))
        )
        _ = try initiator.readMessage2(message2)
        let confirmed = try await fixture.coordinator.receive(
            socketID: "socket-resume",
            payload: try encode(JSONValue.object([
                "v": .integer(Int64(1)),
                "type": .string("resume.message3"),
                "sessionId": .string(sessionID),
                "message3": .string(try initiator.writeMessage3().base64URLEncodedString()),
            ])),
            nowMilliseconds: now + 11
        )
        let confirmation = try object(try XCTUnwrap(confirmed.frames.first))
        let result = try initiator.result()
        let deviceChannel = try SecureFrameChannel(
            result: result,
            context: CompanionConnectionContext(
                desktopId: fixture.desktop.id,
                deviceId: fixture.device.id,
                connectionId: connectionID
            ),
            role: .device
        )
        try CompanionKeyConfirmation.verify(
            channel: deviceChannel,
            frame: try decodeSecureFrame(try XCTUnwrap(confirmation["confirmationFrame"])),
            expectedRole: .desktop,
            handshakeHash: result.handshakeHash
        )
        let authenticated = try await fixture.coordinator.receive(
            socketID: "socket-resume",
            payload: try encode(CompanionKeyConfirmation.make(
                channel: deviceChannel,
                role: .device,
                handshakeHash: result.handshakeHash
            )),
            nowMilliseconds: now + 12
        )
        XCTAssertTrue(authenticated.frames.isEmpty)
        guard case let .authenticated(device, resumed) = authenticated.event else {
            return XCTFail("Expected resume authentication after key confirmation")
        }
        XCTAssertTrue(resumed)
        XCTAssertEqual(device.lastSeenAt, now + 12)
        let persistedLastSeenAt = await fixture.roster.device(fixture.device.id)?.lastSeenAt
        XCTAssertEqual(persistedLastSeenAt, now + 12)
    }

    func testOfferIsSingleUseEvenWhenPairStartIsMalformedAfterClaim() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let now: Int64 = 1_800_000_200_000
        let offer = try await fixture.coordinator.createOffer(
            listenerPort: 49_321,
            nowMilliseconds: now,
            nonce: Data(repeating: 7, count: 32)
        )
        let otherDevice = try CompanionIdentity(
            id: "device-other",
            role: .device,
            displayName: "Other iPhone"
        )
        let connectionID = "connection-single-use"
        let initiator = try NoiseXXInitiator(
            identity: otherDevice,
            prologue: createNoisePrologue(try offer.handshakeContext(connectionId: connectionID)),
            peerPin: offer.desktopPin
        )
        let start = try encode(JSONValue.object([
            "v": .integer(Int64(1)),
            "type": .string("pair.start"),
            "qrPayload": try JSONValue.from(offer),
            "connectionId": .string(connectionID),
            "message1": .string(try initiator.writeMessage1().base64URLEncodedString()),
        ]))
        _ = try await fixture.coordinator.receive(
            socketID: "socket-first",
            payload: start,
            nowMilliseconds: now + 1
        )
        do {
            _ = try await fixture.coordinator.receive(
                socketID: "socket-second",
                payload: start,
                nowMilliseconds: now + 2
            )
            XCTFail("A claimed pairing nonce must never be reusable")
        } catch {
            XCTAssertEqual(error as? CompanionPairingCoordinatorError, .offerUnavailable)
        }
    }

    private struct Fixture {
        let directory: URL
        let desktop: CompanionIdentity
        let device: CompanionIdentity
        let roster: CompanionDeviceRosterStore
        let coordinator: CompanionPairingCoordinator

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "kaisola-pairing-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            desktop = try CompanionIdentity(
                id: "desktop-pairing-test",
                role: .desktop,
                displayName: "Test Mac"
            )
            device = try CompanionIdentity(
                id: "device-pairing-test",
                role: .device,
                displayName: "Test iPhone"
            )
            roster = try CompanionDeviceRosterStore(
                fileURL: directory.appendingPathComponent("devices-v1.json")
            )
            coordinator = try CompanionPairingCoordinator(identity: desktop, roster: roster)
        }

        var desktopPin: CompanionIdentityPin {
            CompanionIdentityPin(
                id: desktop.id,
                identityPublic: desktop.identityPublic,
                x25519StaticPublic: desktop.x25519StaticPublic
            )
        }

        var devicePin: CompanionIdentityPin {
            CompanionIdentityPin(
                id: device.id,
                identityPublic: device.identityPublic,
                x25519StaticPublic: device.x25519StaticPublic
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try CanonicalJSON.data(from: value)
    }

    private func object(_ data: Data) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return try XCTUnwrap(value.objectValue)
    }

    private func decodeSecureFrame(_ value: JSONValue) throws -> CompanionSecureFrame {
        try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: CanonicalJSON.data(from: value)
        )
    }

    private func decodeSecureFrameData(_ data: Data) throws -> CompanionSecureFrame {
        try JSONDecoder().decode(CompanionSecureFrame.self, from: data)
    }
}
