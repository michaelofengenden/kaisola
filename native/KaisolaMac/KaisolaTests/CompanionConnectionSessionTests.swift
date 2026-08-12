import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

final class CompanionConnectionSessionTests: XCTestCase {
    func testChunkedResumeTransitionsThroughDesktopAndDeviceHelloBeforeApplicationFrames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-connection-session-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let desktop = try CompanionIdentity(
            id: "desktop-session-test",
            role: .desktop,
            displayName: "Test Mac"
        )
        let device = try CompanionIdentity(
            id: "device-session-test",
            role: .device,
            displayName: "Test iPhone"
        )
        let roster = try CompanionDeviceRosterStore(
            fileURL: directory.appendingPathComponent("devices-v3.json"),
            accountScope: try CompanionAccountScope(accountID: "connection-session-test-account")
        )
        _ = try await roster.pair(
            peer: CompanionIdentityPin(
                id: device.id,
                identityPublic: device.identityPublic,
                x25519StaticPublic: device.x25519StaticPublic
            ),
            displayName: device.displayName,
            capabilities: [.observe, .terminalControl],
            now: 1_800_000_000_000
        )
        let coordinator = try CompanionPairingCoordinator(identity: desktop, roster: roster)
        let wire = WireCapture()
        let events = EventCapture()
        let session = try CompanionConnectionSession(
            socketID: "socket-session-test",
            coordinator: coordinator,
            epoch: "epoch-session-test",
            transportHint: CompanionPairingTransportHint(
                service: "_kaisola._tcp",
                protocol: "tcp",
                port: 49_321
            ),
            writer: { data in await wire.append(data) },
            closer: { await wire.markClosed() },
            eventSink: { events.append($0) },
            now: { 1_800_000_000_100 }
        )
        let connectionID = "connection-session-test"
        let context = CompanionConnectionContext(
            desktopId: desktop.id,
            deviceId: device.id,
            connectionId: connectionID
        )
        let resumeContext: JSONValue = .object([
            "v": .integer(Int64(1)),
            "mode": .string("resume"),
            "protocol": .string(CompanionCrypto.noiseProtocol),
            "desktopId": .string(desktop.id),
            "deviceId": .string(device.id),
            "connectionId": .string(connectionID),
            "accountScope": .string(roster.accountScope.rawValue),
        ])
        let initiator = try NoiseXXInitiator(
            identity: device,
            prologue: createNoisePrologue(resumeContext),
            peerPin: CompanionIdentityPin(
                id: desktop.id,
                identityPublic: desktop.identityPublic,
                x25519StaticPublic: desktop.x25519StaticPublic
            )
        )
        let startPayload = try CanonicalJSON.data(from: JSONValue.object([
            "v": .integer(Int64(1)),
            "type": .string("resume.start"),
            "deviceId": .string(device.id),
            "connectionId": .string(connectionID),
            "accountScope": .string(roster.accountScope.rawValue),
            "message1": .string(try initiator.writeMessage1().base64URLEncodedString()),
        ]))
        let startWire = try CompanionLengthFrameDecoder.encode(startPayload)
        await session.receive(Data(startWire.prefix(7)))
        let writesAfterPartialFrame = await wire.all()
        XCTAssertTrue(writesAfterPartialFrame.isEmpty)
        await session.receive(Data(startWire.dropFirst(7)))

        var writes = await wire.all()
        XCTAssertEqual(writes.count, 1)
        let message2 = try object(payload(from: writes[0]))
        let sessionID = try XCTUnwrap(message2["sessionId"]?.stringValue)
        let message2Data = try XCTUnwrap(
            message2["message2"]?.stringValue.flatMap(Data.init(base64URLString:))
        )
        _ = try initiator.readMessage2(message2Data)
        let message3 = try initiator.writeMessage3()
        await session.receive(try frame(JSONValue.object([
            "v": .integer(Int64(1)),
            "type": .string("resume.message3"),
            "sessionId": .string(sessionID),
            "message3": .string(message3.base64URLEncodedString()),
        ])))

        writes = await wire.all()
        XCTAssertEqual(writes.count, 2)
        let confirmation = try object(payload(from: writes[1]))
        let result = try initiator.result()
        let deviceChannel = try SecureFrameChannel(result: result, context: context, role: .device)
        try CompanionKeyConfirmation.verify(
            channel: deviceChannel,
            frame: try secureFrame(try XCTUnwrap(confirmation["confirmationFrame"])),
            expectedRole: .desktop,
            handshakeHash: result.handshakeHash
        )
        await session.receive(try frame(CompanionKeyConfirmation.make(
            channel: deviceChannel,
            role: .device,
            handshakeHash: result.handshakeHash
        )))

        writes = await wire.all()
        XCTAssertEqual(writes.count, 3)
        let desktopHelloSecure = try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: payload(from: writes[2])
        )
        let desktopHello = try CompanionProtocolCodec.decode(
            deviceChannel.decrypt(desktopHelloSecure)
        )
        XCTAssertEqual(desktopHello.kind, .hello)
        XCTAssertEqual(desktopHello.epoch, "epoch-session-test")
        let desktopHelloBody = try desktopHello.body.decode(CompanionHelloBody.self)
        XCTAssertEqual(desktopHelloBody.role, .desktop)
        XCTAssertEqual(desktopHelloBody.capabilities, [.observe, .terminalControl])
        XCTAssertEqual(events.snapshot(), ["authenticated:device-session-test:true"])

        let deviceHello = try CompanionEnvelope(
            kind: .hello,
            desktopId: desktop.id,
            deviceId: device.id,
            connectionId: connectionID,
            epoch: "epoch-session-test",
            seq: 0,
            id: "hello-device-session-test",
            sentAt: 1_800_000_000_101,
            body: CompanionBody(CompanionHelloBody(
                role: .device,
                capabilities: CompanionCapability.allCases,
                lastAck: 7
            ))
        )
        await session.receive(try frame(deviceChannel.encrypt(
            CompanionProtocolCodec.encode(deviceHello)
        )))
        XCTAssertEqual(events.snapshot(), [
            "authenticated:device-session-test:true",
            "live:device-session-test:observe,terminal-control:epoch-session-test:7",
        ])

        var projection = CompanionProjectionBuilder.build(
            drafts: [RememberedSessionDraft(
                id: "terminal-test",
                projectID: "project-test",
                projectName: "Kaisola",
                title: "Codex",
                kind: .terminal,
                agentID: "Codex",
                activity: .working,
                resumeKind: .livePTY,
                createdAt: 1_800_000_000_000,
                lastActivityAt: nil,
                hasLocalTranscript: true
            )],
            terminalStreams: [
                "terminal-test": CompanionTerminalStreamHead(
                    streamEpoch: "stream-session-test",
                    endOffset: 42
                ),
            ],
            revision: 7,
            nowMilliseconds: 1_800_000_000_102
        )
        projection.projects[0].repo = "/Users/private/secret"
        projection.projects[0].branch = "private-branch"
        projection.sessions[0].summary = "private-summary"
        projection.sessions[0].terminalOutput = "private-output"
        try await session.sendProjection(projection)
        writes = await wire.all()
        XCTAssertEqual(writes.count, 4)
        let snapshotSecure = try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: payload(from: writes[3])
        )
        let snapshotEnvelope = try CompanionProtocolCodec.decode(
            deviceChannel.decrypt(snapshotSecure)
        )
        XCTAssertEqual(snapshotEnvelope.kind, .snapshot)
        XCTAssertEqual(snapshotEnvelope.epoch, "epoch-session-test")
        let snapshotBody = try snapshotEnvelope.body.decode(CompanionSnapshotBody.self)
        XCTAssertEqual(snapshotBody.revision, 7)
        XCTAssertEqual(
            snapshotBody.projection.projectionKind,
            "kaisola.companion.projection"
        )
        XCTAssertEqual(snapshotBody.projection.sessions.first?.terminalEndOffset, 42)
        XCTAssertNil(snapshotBody.projection.projects.first?.repo)
        XCTAssertNil(snapshotBody.projection.projects.first?.branch)
        XCTAssertNil(snapshotBody.projection.sessions.first?.summary)
        XCTAssertNil(snapshotBody.projection.sessions.first?.terminalOutput)
        try await session.sendProjection(projection)
        let writesAfterDuplicateProjection = await wire.all()
        XCTAssertEqual(writesAfterDuplicateProjection.count, 4)

        let ack = try CompanionEnvelope(
            kind: .ack,
            desktopId: desktop.id,
            deviceId: device.id,
            connectionId: connectionID,
            epoch: "epoch-session-test",
            seq: 1,
            id: "ack-device-session-test",
            sentAt: 1_800_000_000_102,
            body: CompanionBody(CompanionAckBody(ackSeq: 0))
        )
        await session.receive(try frame(deviceChannel.encrypt(
            CompanionProtocolCodec.encode(ack)
        )))
        XCTAssertEqual(events.snapshot().last, "envelope:ack:ack")
        let closedAfterValidEnvelope = await wire.isClosed()
        XCTAssertFalse(closedAfterValidEnvelope)

        let observeCommandID = "command-attention-ack-test"
        let observeCommand = try CompanionEnvelope(
            kind: .command,
            desktopId: desktop.id,
            deviceId: device.id,
            connectionId: connectionID,
            epoch: "epoch-session-test",
            seq: 2,
            id: observeCommandID,
            sentAt: 1_800_000_000_103,
            body: CompanionBody(CompanionCommandBody(
                type: "attention.ack",
                commandId: observeCommandID,
                projectId: "project-test",
                targetId: "attention-test",
                capability: .observe,
                expectedRevision: 7,
                payload: nil
            ))
        )
        await session.receive(try frame(deviceChannel.encrypt(
            CompanionProtocolCodec.encode(observeCommand)
        )))
        XCTAssertEqual(events.snapshot().last, "envelope:command:attention.ack")
        try await session.sendUnavailableReceipt(for: observeCommand)
        writes = await wire.all()
        XCTAssertEqual(writes.count, 5)
        let receiptSecure = try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: payload(from: writes[4])
        )
        let receiptEnvelope = try CompanionProtocolCodec.decode(
            deviceChannel.decrypt(receiptSecure)
        )
        XCTAssertEqual(receiptEnvelope.kind, .receipt)
        XCTAssertEqual(receiptEnvelope.seq, 2)
        let receipt = try receiptEnvelope.body.decode(CompanionReceiptBody.self)
        XCTAssertEqual(receipt.commandId, observeCommandID)
        XCTAssertEqual(receipt.status, .unavailable)

        let downgraded = try await session.updateCapabilities([.observe])
        XCTAssertEqual(downgraded, [.observe])
        writes = await wire.all()
        XCTAssertEqual(writes.count, 6)
        let downgradeHelloSecure = try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: payload(from: writes[5])
        )
        let downgradeHello = try CompanionProtocolCodec.decode(
            deviceChannel.decrypt(downgradeHelloSecure)
        )
        XCTAssertEqual(downgradeHello.kind, .hello)
        XCTAssertEqual(
            try downgradeHello.body.decode(CompanionHelloBody.self).capabilities,
            [.observe]
        )

        let unauthorizedCommandID = "command-terminal-write-test"
        let unauthorizedCommand = try CompanionEnvelope(
            kind: .command,
            desktopId: desktop.id,
            deviceId: device.id,
            connectionId: connectionID,
            epoch: "epoch-session-test",
            seq: 3,
            id: unauthorizedCommandID,
            sentAt: 1_800_000_000_103,
            body: CompanionBody(CompanionCommandBody(
                type: "terminal.write",
                commandId: unauthorizedCommandID,
                projectId: "project-test",
                targetId: "terminal-test",
                capability: .terminalControl,
                expectedRevision: nil,
                payload: ["data": .string("whoami\n")]
            ))
        )
        await session.receive(try frame(deviceChannel.encrypt(
            CompanionProtocolCodec.encode(unauthorizedCommand)
        )))
        let closedAfterUnauthorizedCommand = await wire.isClosed()
        XCTAssertTrue(closedAfterUnauthorizedCommand)
        XCTAssertEqual(events.snapshot().last, "closed:invalid_secure_frame")
    }

    func testHandshakeFrameAbove64KiBClosesBeforeCoordinatorParsing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-connection-limit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let desktop = try CompanionIdentity(
            id: "desktop-limit-test",
            role: .desktop,
            displayName: "Test Mac"
        )
        let roster = try CompanionDeviceRosterStore(
            fileURL: directory.appendingPathComponent("devices-v3.json"),
            accountScope: try CompanionAccountScope(accountID: "connection-session-revoked-account")
        )
        let coordinator = try CompanionPairingCoordinator(identity: desktop, roster: roster)
        let wire = WireCapture()
        let events = EventCapture()
        let session = try CompanionConnectionSession(
            socketID: "socket-limit-test",
            coordinator: coordinator,
            epoch: "epoch-limit-test",
            transportHint: nil,
            writer: { data in await wire.append(data) },
            closer: { await wire.markClosed() },
            eventSink: { events.append($0) }
        )
        let oversized = Data([
            0x00, 0x01, 0x00, 0x01,
        ]) + Data(repeating: 0x7b, count: 16)
        await session.receive(oversized)
        let closedAfterOversizedFrame = await wire.isClosed()
        XCTAssertTrue(closedAfterOversizedFrame)
        XCTAssertEqual(events.snapshot(), ["closed:authentication_failed"])
    }

    private actor WireCapture {
        private var writes: [Data] = []
        private var closed = false
        func append(_ data: Data) { writes.append(data) }
        func all() -> [Data] { writes }
        func markClosed() { closed = true }
        func isClosed() -> Bool { closed }
    }

    private final class EventCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ event: CompanionConnectionEvent) {
            let value: String
            switch event {
            case let .pairingPhrase(pairingID, _, _, _): value = "pairing:\(pairingID)"
            case let .authenticated(device, resumed): value = "authenticated:\(device.deviceId):\(resumed)"
            case let .live(device, capabilities, resumeCursor):
                let cursor = resumeCursor.map { "\($0.epoch):\($0.seq)" } ?? "fresh"
                value = "live:\(device.deviceId):\(capabilities.map(\.rawValue).joined(separator: ",")):\(cursor)"
            case let .envelope(envelope, _): value = "envelope:\(envelope.kind.rawValue):\(envelope.body.type)"
            case let .closed(reason): value = "closed:\(reason)"
            }
            lock.withLock { values.append(value) }
        }

        func snapshot() -> [String] { lock.withLock { values } }
    }

    private func frame<T: Encodable>(_ value: T) throws -> Data {
        try CompanionLengthFrameDecoder.encode(CanonicalJSON.data(from: value))
    }

    private func payload(from wire: Data) throws -> Data {
        var decoder = CompanionLengthFrameDecoder()
        let values = try decoder.push(wire)
        XCTAssertTrue(decoder.buffer.isEmpty)
        return try XCTUnwrap(values.count == 1 ? values.first : nil)
    }

    private func object(_ data: Data) throws -> [String: JSONValue] {
        try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }

    private func secureFrame(_ value: JSONValue) throws -> CompanionSecureFrame {
        try JSONDecoder().decode(
            CompanionSecureFrame.self,
            from: CanonicalJSON.data(from: value)
        )
    }
}
