import CryptoKit
import Foundation
import KaisolaCore
import Security
import XCTest
@testable import Kaisola

final class CompanionHostFoundationTests: XCTestCase {
    private let desktopSigningSeed = Data((0..<32).map { UInt8($0) })
    private let desktopAgreementSeed = Data((32..<64).map { UInt8($0) })
    private let phoneSigningSeed = Data((64..<96).map { UInt8($0) })
    private let phoneAgreementSeed = Data((96..<128).map { UInt8($0) })

    func testDesktopIdentityIsStableAndPrivateKeysNeverSynchronize() throws {
        let service = "com.kaisola.mac.companion-identity.test-\(UUID().uuidString)"
        let store = CompanionIdentityStore(service: service)
        defer { store.deleteAll() }
        do {
            let first = try store.loadOrCreate(displayName: "Test Mac")
            let second = try store.loadOrCreate(displayName: "Renamed Mac")
            XCTAssertEqual(first.role, .desktop)
            XCTAssertEqual(first.id, second.id)
            XCTAssertEqual(first.identityPublic, second.identityPublic)
            XCTAssertEqual(first.x25519StaticPublic, second.x25519StaticPublic)
            XCTAssertEqual(second.displayName, "Renamed Mac")
            try second.keyRecord.verify(
                identityPublic: second.identityPublic,
                expectedRole: .desktop,
                expectedId: second.id
            )
        } catch CompanionIdentityStoreError.keychain(let status)
            where status == errSecMissingEntitlement {
            throw XCTSkip("Test host lacks the data-protection Keychain entitlement.")
        }
    }

    func testRosterRoundTripsValidatedPublicMetadataAtMode0600() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-companion-roster-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("devices-v1.json")
        let store = try CompanionDeviceRosterStore(fileURL: file)
        let device = try CompanionIdentity(
            id: "device-test",
            role: .device,
            displayName: "Test iPhone"
        )

        let paired = try await store.pair(
            peer: CompanionIdentityPin(
                id: device.id,
                identityPublic: device.identityPublic,
                x25519StaticPublic: device.x25519StaticPublic
            ),
            displayName: "  Test iPhone  ",
            capabilities: [.observe],
            now: 100
        )
        XCTAssertEqual(paired.displayName, "Test iPhone")
        var attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reopened = try CompanionDeviceRosterStore(fileURL: file)
        let reopenedDevices = await reopened.list()
        XCTAssertEqual(reopenedDevices, [paired])
        try await reopened.markSeen(device.id, now: 200)
        let lastSeenAt = await reopened.device(device.id)?.lastSeenAt
        XCTAssertEqual(lastSeenAt, 200)
        let revoked = try await reopened.revoke(device.id)
        XCTAssertTrue(revoked)
        let remainingDevices = await reopened.list()
        XCTAssertTrue(remainingDevices.isEmpty)

        attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRosterRejectsOverlyPermissiveOrSymlinkedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-companion-roster-unsafe-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("devices-v1.json")
        try Data(#"{"version":1,"devices":[]}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try CompanionDeviceRosterStore(fileURL: file)) { error in
            XCTAssertEqual(error as? CompanionDeviceRosterError, .unsafePath)
        }
    }

    func testBonjourAdvertisementMatchesShippingPhoneContract() throws {
        let desktopID = "desktop-12345678-90ab-cdef-1234-567890abcdef"
        let advertisement = try CompanionListenerAdvertisement(desktopID: desktopID)
        XCTAssertEqual(advertisement.instanceName, "Kaisola-234-567890abcdef")
        XCTAssertEqual(CompanionListenerAdvertisement.serviceType, "_kaisola._tcp")
        let txt = NetService.dictionary(fromTXTRecord: advertisement.txtRecord)
        XCTAssertEqual(txt["v"].flatMap { String(data: $0, encoding: .utf8) }, "1")
        XCTAssertEqual(txt["id"].flatMap { String(data: $0, encoding: .utf8) }, desktopID)
    }

    func testAppDeclaresLocalNetworkAndBonjourUsage() throws {
        let infoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Kaisola/App/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["NSBonjourServices"] as? [String], ["_kaisola._tcp"])
        XCTAssertFalse((plist["NSLocalNetworkUsageDescription"] as? String)?.isEmpty ?? true)
    }

    func testPairingCodeRendersAsAReadableBitmap() throws {
        let image = try XCTUnwrap(CompanionQRCode.image(for: #"{"type":"kaisola-companion-pairing"}"#))
        XCTAssertGreaterThan(image.size.width, 100)
        XCTAssertEqual(image.size.width, image.size.height)
        XCTAssertNil(CompanionQRCode.image(for: ""))
    }

    @MainActor
    func testPairNewDeviceIgnoresRepeatActivationWhileAnOfferIsInFlight() throws {
        let activation = CompanionPairingOfferActivation()
        let first = try XCTUnwrap(activation.begin())
        XCTAssertTrue(activation.isCreating)
        XCTAssertNil(activation.begin())
        XCTAssertNil(activation.begin())
        XCTAssertTrue(activation.finish(first))
        XCTAssertFalse(activation.isCreating)
        let second = try XCTUnwrap(activation.begin())
        XCTAssertNotEqual(second, first)
    }

    @MainActor
    func testOnlyTheNewestOfferActivationMayApplyItsResult() throws {
        let activation = CompanionPairingOfferActivation()
        let abandoned = try XCTUnwrap(activation.begin())
        activation.discard()
        XCTAssertFalse(activation.isCreating)
        let newest = try XCTUnwrap(activation.begin())
        XCTAssertFalse(activation.finish(abandoned))
        XCTAssertTrue(activation.isCreating)
        XCTAssertTrue(activation.finish(newest))
        XCTAssertFalse(activation.isCreating)
        XCTAssertFalse(activation.finish(newest))
    }

    func testPairNewDeviceButtonRendersTheGatedProgressState() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Kaisola/Features/Settings/CompanionSettingsTab.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(".disabled(offerActivation.isCreating)"))
        XCTAssertTrue(source.contains("ProgressView().controlSize(.mini)"))
        XCTAssertTrue(source.contains("CompanionPairingOfferActivation.progressLabel"))
    }

    func testPairingCoordinatorCompletesMutualProofSASAndSecureResume() async throws {
        let fixture = try makePairingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let now: Int64 = 1_000_000
        let offer = try await fixture.coordinator.createOffer(
            listenerPort: 49_321,
            requestedCapabilities: [.observe, .terminalControl],
            nowMilliseconds: now,
            nonce: Data(repeating: 9, count: 32)
        )
        let connectionID = "connection-pairing-test"
        let initiator = try NoiseXXInitiator(
            identity: fixture.phone,
            prologue: createNoisePrologue(try offer.handshakeContext(connectionId: connectionID)),
            peerPin: offer.desktopPin
        )
        let message1 = try initiator.writeMessage1()
        let started = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try wire([
                "v": .integer(1),
                "type": .string("pair.start"),
                "qrPayload": try JSONValue.from(offer),
                "connectionId": .string(connectionID),
                "message1": .string(message1.base64URLEncodedString()),
            ]),
            nowMilliseconds: now + 1
        )
        let message2Object = try object(try XCTUnwrap(started.frames.first))
        let sessionID = try XCTUnwrap(message2Object["sessionId"]?.stringValue)
        let message2 = try XCTUnwrap(
            message2Object["message2"]?.stringValue.flatMap(Data.init(base64URLString:))
        )
        XCTAssertEqual(message2Object["type"]?.stringValue, "pair.message2")
        try initiator.readMessage2(message2)
        let message3 = try initiator.writeMessage3()
        let phoneResult = try initiator.result()
        let context = CompanionConnectionContext(
            desktopId: fixture.desktop.id,
            deviceId: fixture.phone.id,
            connectionId: connectionID
        )
        let phoneChannel = try SecureFrameChannel(
            result: phoneResult,
            context: context,
            role: .device
        )

        let completed = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try wire([
                "v": .integer(1),
                "type": .string("pair.message3"),
                "sessionId": .string(sessionID),
                "message3": .string(message3.base64URLEncodedString()),
            ]),
            nowMilliseconds: now + 2
        )
        let confirmationObject = try object(try XCTUnwrap(completed.frames.first))
        XCTAssertEqual(confirmationObject["type"]?.stringValue, "pair.confirmation")
        let desktopConfirmation = try decodeSecureFrame(
            try XCTUnwrap(confirmationObject["confirmationFrame"])
        )
        try CompanionKeyConfirmation.verify(
            channel: phoneChannel,
            frame: desktopConfirmation,
            expectedRole: .desktop,
            handshakeHash: phoneResult.handshakeHash
        )
        let phoneConfirmation = try CompanionKeyConfirmation.make(
            channel: phoneChannel,
            role: .device,
            handshakeHash: phoneResult.handshakeHash
        )
        let phrase = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try CanonicalJSON.data(from: phoneConfirmation),
            nowMilliseconds: now + 3
        )
        guard case let .pairingPhrase(pairingID, _, deviceID, displayName, sas) = phrase.event else {
            return XCTFail("Expected the authenticated SAS event")
        }
        XCTAssertEqual(pairingID, offer.pairingNonce)
        XCTAssertEqual(deviceID, fixture.phone.id)
        XCTAssertEqual(displayName, "Michael's iPhone")
        XCTAssertEqual(sas, CompanionSAS.derive(handshakeHash: phoneResult.handshakeHash))

        let locallyConfirmed = try await fixture.coordinator.confirmPairing(
            pairingID: pairingID,
            nowMilliseconds: now + 4
        )
        XCTAssertEqual(locallyConfirmed.frames.count, 1)
        let desktopSAS = try phoneChannel.decryptJSON(
            try decodeSecureFrameData(locallyConfirmed.frames[0])
        )
        XCTAssertEqual(desktopSAS.objectValue?["type"]?.stringValue, "sas-confirm")
        XCTAssertEqual(desktopSAS.objectValue?["role"]?.stringValue, "desktop")

        let phoneSAS: JSONValue = .object([
            "type": .string("sas-confirm"),
            "role": .string("device"),
            "transcriptHash": .string(phoneResult.handshakeHash.base64URLEncodedString()),
        ])
        let paired = try await fixture.coordinator.receive(
            socketID: "socket-pair",
            payload: try CanonicalJSON.data(from: phoneChannel.encrypt(phoneSAS)),
            nowMilliseconds: now + 5
        )
        XCTAssertEqual(paired.frames.count, 1)
        let pairedPayload = try phoneChannel.decryptJSON(
            try decodeSecureFrameData(paired.frames[0])
        )
        XCTAssertEqual(pairedPayload.objectValue?["type"]?.stringValue, "paired")
        XCTAssertEqual(pairedPayload.objectValue?["deviceId"]?.stringValue, fixture.phone.id)
        let storedPairedRecord = await fixture.roster.device(fixture.phone.id)
        let pairedRecord = try XCTUnwrap(storedPairedRecord)
        XCTAssertEqual(pairedRecord.displayName, "Michael's iPhone")
        XCTAssertEqual(pairedRecord.capabilities, [.observe, .terminalControl])
        let pairedConnection = await fixture.coordinator.authenticatedConnection(socketID: "socket-pair")
        XCTAssertEqual(pairedConnection?.device, pairedRecord)
        XCTAssertEqual(pairedConnection?.resumed, false)

        let resumeConnectionID = "connection-resume-test"
        let resumeContext: JSONValue = .object([
            "v": .integer(1),
            "mode": .string("resume"),
            "protocol": .string(CompanionCrypto.noiseProtocol),
            "desktopId": .string(fixture.desktop.id),
            "deviceId": .string(fixture.phone.id),
            "connectionId": .string(resumeConnectionID),
        ])
        let resumeInitiator = try NoiseXXInitiator(
            identity: fixture.phone,
            prologue: createNoisePrologue(resumeContext),
            peerPin: CompanionIdentityPin(
                id: fixture.desktop.id,
                identityPublic: fixture.desktop.identityPublic,
                x25519StaticPublic: fixture.desktop.x25519StaticPublic
            )
        )
        let resumeStarted = try await fixture.coordinator.receive(
            socketID: "socket-resume",
            payload: try wire([
                "v": .integer(1),
                "type": .string("resume.start"),
                "deviceId": .string(fixture.phone.id),
                "connectionId": .string(resumeConnectionID),
                "message1": .string(try resumeInitiator.writeMessage1().base64URLEncodedString()),
            ]),
            nowMilliseconds: now + 10
        )
        let resumeMessage2Object = try object(try XCTUnwrap(resumeStarted.frames.first))
        let resumeSessionID = try XCTUnwrap(resumeMessage2Object["sessionId"]?.stringValue)
        let resumeMessage2 = try XCTUnwrap(
            resumeMessage2Object["message2"]?.stringValue.flatMap(Data.init(base64URLString:))
        )
        try resumeInitiator.readMessage2(resumeMessage2)
        let resumeMessage3 = try resumeInitiator.writeMessage3()
        let resumeResult = try resumeInitiator.result()
        let resumePhoneChannel = try SecureFrameChannel(
            result: resumeResult,
            context: CompanionConnectionContext(
                desktopId: fixture.desktop.id,
                deviceId: fixture.phone.id,
                connectionId: resumeConnectionID
            ),
            role: .device
        )
        let resumeCompleted = try await fixture.coordinator.receive(
            socketID: "socket-resume",
            payload: try wire([
                "v": .integer(1),
                "type": .string("resume.message3"),
                "sessionId": .string(resumeSessionID),
                "message3": .string(resumeMessage3.base64URLEncodedString()),
            ]),
            nowMilliseconds: now + 11
        )
        let resumeConfirmationObject = try object(try XCTUnwrap(resumeCompleted.frames.first))
        try CompanionKeyConfirmation.verify(
            channel: resumePhoneChannel,
            frame: try decodeSecureFrame(
                try XCTUnwrap(resumeConfirmationObject["confirmationFrame"])
            ),
            expectedRole: .desktop,
            handshakeHash: resumeResult.handshakeHash
        )
        let resumeAuthenticated = try await fixture.coordinator.receive(
            socketID: "socket-resume",
            payload: try CanonicalJSON.data(from: CompanionKeyConfirmation.make(
                channel: resumePhoneChannel,
                role: .device,
                handshakeHash: resumeResult.handshakeHash
            )),
            nowMilliseconds: now + 12
        )
        guard case let .authenticated(device, resumed) = resumeAuthenticated.event else {
            return XCTFail("Expected authenticated resume")
        }
        XCTAssertEqual(device.deviceId, fixture.phone.id)
        XCTAssertTrue(resumed)
        let resumedConnection = await fixture.coordinator.authenticatedConnection(socketID: "socket-resume")
        XCTAssertEqual(resumedConnection?.resumed, true)
    }

    func testPairingOfferIsSingleUseEvenWhenClaimingHandshakeIsMalformed() async throws {
        let fixture = try makePairingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let offer = try await fixture.coordinator.createOffer(
            listenerPort: 49_321,
            nowMilliseconds: 1_000,
            nonce: Data(repeating: 7, count: 32)
        )
        let malformed = try wire([
            "v": .integer(1),
            "type": .string("pair.start"),
            "qrPayload": try JSONValue.from(offer),
            "connectionId": .string("connection-single-use"),
            "message1": .string(Data([1]).base64URLEncodedString()),
        ])
        do {
            _ = try await fixture.coordinator.receive(
                socketID: "socket-malformed",
                payload: malformed,
                nowMilliseconds: 1_001
            )
            XCTFail("Expected malformed Noise message to fail")
        } catch {
            XCTAssertNotEqual(error as? CompanionPairingCoordinatorError, .offerUnavailable)
        }
        do {
            _ = try await fixture.coordinator.receive(
                socketID: "socket-replay",
                payload: malformed,
                nowMilliseconds: 1_002
            )
            XCTFail("Expected the claimed QR offer to be unavailable")
        } catch {
            XCTAssertEqual(error as? CompanionPairingCoordinatorError, .offerUnavailable)
        }
    }

    private struct PairingFixture {
        let directory: URL
        let desktop: CompanionIdentity
        let phone: CompanionIdentity
        let roster: CompanionDeviceRosterStore
        let coordinator: CompanionPairingCoordinator
    }

    private func makePairingFixture() throws -> PairingFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-companion-pairing-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let desktop = try CompanionIdentity.testIdentity(
            id: "desktop-pairing-test",
            role: .desktop,
            displayName: "Test Mac",
            signingSeed: desktopSigningSeed,
            agreementSeed: desktopAgreementSeed
        )
        let phone = try CompanionIdentity.testIdentity(
            id: "device-pairing-test",
            role: .device,
            displayName: "Michael's iPhone",
            signingSeed: phoneSigningSeed,
            agreementSeed: phoneAgreementSeed
        )
        let roster = try CompanionDeviceRosterStore(
            fileURL: directory.appendingPathComponent("devices-v1.json")
        )
        return PairingFixture(
            directory: directory,
            desktop: desktop,
            phone: phone,
            roster: roster,
            coordinator: try CompanionPairingCoordinator(identity: desktop, roster: roster)
        )
    }

    private func wire(_ fields: [String: JSONValue]) throws -> Data {
        try CanonicalJSON.data(from: .object(fields))
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
