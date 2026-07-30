import Foundation
import KaisolaCore
import KaisolaTestSupport
import XCTest

final class CompanionProtocolContractTests: XCTestCase {
    private let validEnvelopeFixtures = [
        "hello",
        "agent-delta",
        "command-receipt",
        "permission-requested",
        "snapshot-board",
        "stale-revision-error",
        "terminal-output",
        "terminal-control-command",
        "terminal-control-receipt",
    ]

    func testCheckedInNodeFixturesRoundTripWithoutSemanticDrift() throws {
        for name in validEnvelopeFixtures {
            let original = try fixtureData(name)
            let envelope = try CompanionProtocolCodec.decode(original)
            let encoded = try CompanionProtocolCodec.encode(envelope)

            XCTAssertEqual(
                try JSONDecoder().decode(JSONValue.self, from: encoded),
                try JSONDecoder().decode(JSONValue.self, from: original),
                "\(name).json must preserve every cross-language wire field"
            )
        }
    }

    func testCheckedInFixturesDecodeToTypedBodies() throws {
        let hello = try decodeFixture("hello").body.decode(CompanionHelloBody.self)
        XCTAssertEqual(hello.role, .device)
        XCTAssertEqual(hello.capabilities, [.observe])

        let delta = try decodeFixture("agent-delta").body.decode(CompanionAgentTurnDeltaBody.self)
        XCTAssertEqual(delta.turnId, "turn-8")
        XCTAssertEqual(delta.delta, .string("Adding replay protection."))

        let permission = try decodeFixture("permission-requested")
            .body.decode(CompanionPermissionRequestedBody.self)
        XCTAssertEqual(permission.options.map(\.id), ["allow-once", "reject"])

        let terminal = try decodeFixture("terminal-output").body.decode(CompanionTerminalOutputBody.self)
        XCTAssertEqual(terminal.startOffset, 3)
        XCTAssertEqual(terminal.endOffset, 7)
        XCTAssertEqual(terminal.data, "🙂")
        XCTAssertEqual(terminal.data.lengthOfBytes(using: .utf8), 4)
    }

    func testProtocolMismatchAndUnknownTopLevelFieldFailClosed() throws {
        XCTAssertThrowsError(try decodeFixture("protocol-mismatch")) { error in
            XCTAssertEqual(error as? CompanionProtocolError, .protocolMismatch(99))
        }

        var hello = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData("hello")) as? [String: Any]
        )
        hello["unexpected"] = true
        let data = try JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys])
        XCTAssertThrowsError(try CompanionProtocolCodec.decode(data)) { error in
            XCTAssertEqual(error as? CompanionProtocolError, .unknownField("unexpected"))
        }
    }

    func testCommandIdentityCapabilityAndHelloCapabilitiesAreValidated() throws {
        let commandId = "command-1"
        let mismatchedCommand = CompanionCommandBody(
            type: "terminal.write",
            commandId: commandId,
            projectId: "project-kaisola",
            targetId: "terminal-codex",
            capability: .agentControl,
            expectedRevision: nil,
            payload: ["data": .string("status\n")]
        )
        XCTAssertThrowsError(try envelope(kind: .command, id: commandId, body: mismatchedCommand)) { error in
            XCTAssertEqual(
                error as? CompanionProtocolError,
                .invalidBody("body.commandId/capability")
            )
        }

        let wrongCommandID = CompanionCommandBody(
            type: "agent.prompt",
            commandId: "different-command",
            projectId: "project-kaisola",
            targetId: "session-codex",
            capability: .agentControl,
            expectedRevision: 3,
            payload: ["prompt": .string("Continue")]
        )
        XCTAssertThrowsError(try envelope(kind: .command, id: commandId, body: wrongCommandID)) { error in
            XCTAssertEqual(
                error as? CompanionProtocolError,
                .invalidBody("body.commandId/capability")
            )
        }

        let duplicateCapabilities = CompanionHelloBody(
            role: .device,
            capabilities: [.observe, .observe]
        )
        XCTAssertThrowsError(try envelope(kind: .hello, id: "hello-1", body: duplicateCapabilities)) { error in
            XCTAssertEqual(error as? CompanionProtocolError, .invalidBody("body.capabilities"))
        }
    }

    func testTerminalControlCommandAndReceiptRoundTrip() throws {
        let fixtureCommand = try decodeFixture("terminal-control-command")
            .body.decode(CompanionCommandBody.self)
        XCTAssertEqual(fixtureCommand.type, "terminal.acquire-control")
        XCTAssertEqual(fixtureCommand.capability, .terminalControl)

        let fixtureReceipt = try decodeFixture("terminal-control-receipt")
            .body.decode(CompanionReceiptBody.self)
        XCTAssertEqual(fixtureReceipt.payload?["leaseId"]?.stringValue, "lease-terminal-alpha")
        XCTAssertEqual(fixtureReceipt.payload?["resizeEnabled"]?.boolValue, true)

        let commandId = "command-terminal-write"
        let command = try envelope(
            kind: .command,
            id: commandId,
            body: CompanionCommandBody(
                type: "terminal.write",
                commandId: commandId,
                projectId: "project-kaisola",
                targetId: "terminal-codex",
                capability: .terminalControl,
                expectedRevision: 7,
                payload: ["data": .string("help\n")]
            )
        )
        XCTAssertEqual(
            try CompanionProtocolCodec.decode(CompanionProtocolCodec.encode(command)),
            command
        )
    }

    func testTerminalCursorFixtureUsesUTF8ByteOffsetsAndRoundTrips() throws {
        let original = try fixtureData("terminal-cursor")
        let cursor = try JSONDecoder().decode(CompanionTerminalCursorFixture.self, from: original)

        XCTAssertEqual(cursor.chunks.map(\.startOffset), [0, 3, 7])
        XCTAssertEqual(cursor.chunks.map(\.endOffset), [3, 7, 9])
        XCTAssertEqual(cursor.chunks[1].data.lengthOfBytes(using: .utf8), 4)
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(cursor)),
            try JSONDecoder().decode(JSONValue.self, from: original)
        )
    }

    func testAckCursorRequiresMonotonicEventsAndLetsSnapshotChangeEpoch() throws {
        var cursor = CompanionAckCursor(epoch: "epoch-1", seq: 4)

        XCTAssertFalse(cursor.accept(try event(epoch: "epoch-1", seq: 4)))
        XCTAssertFalse(cursor.accept(try event(epoch: "epoch-2", seq: 5)))
        XCTAssertTrue(cursor.accept(try event(epoch: "epoch-1", seq: 5)))
        XCTAssertEqual(cursor, CompanionAckCursor(epoch: "epoch-1", seq: 5))

        let snapshot = try CompanionEnvelope(
            kind: .snapshot,
            desktopId: "desktop-fixture",
            deviceId: "device-fixture",
            connectionId: "connection-fixture",
            epoch: "epoch-2",
            seq: 1,
            id: "snapshot-epoch-2",
            sentAt: 1_784_250_001_500,
            body: CompanionBody(fields: [
                "type": .string("snapshot.projects"),
                "revision": .integer(1),
            ])
        )
        XCTAssertTrue(cursor.accept(snapshot))
        XCTAssertEqual(cursor, CompanionAckCursor(epoch: "epoch-2", seq: 1))
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: RepositoryFixtures.companionFixture(named: name))
    }

    private func decodeFixture(_ name: String) throws -> CompanionEnvelope {
        try CompanionProtocolCodec.decode(fixtureData(name))
    }

    private func envelope<T: Encodable>(
        kind: CompanionEnvelopeKind,
        id: String,
        body: T
    ) throws -> CompanionEnvelope {
        try CompanionEnvelope(
            kind: kind,
            desktopId: "desktop-fixture",
            deviceId: "device-fixture",
            connectionId: "connection-fixture",
            epoch: "epoch-1",
            seq: 1,
            id: id,
            sentAt: 1_784_250_001_000,
            body: CompanionBody(body)
        )
    }

    private func event(epoch: String, seq: Int64) throws -> CompanionEnvelope {
        try CompanionEnvelope(
            kind: .event,
            desktopId: "desktop-fixture",
            deviceId: "device-fixture",
            connectionId: "connection-fixture",
            epoch: epoch,
            seq: seq,
            id: "event-\(epoch)-\(seq)",
            sentAt: 1_784_250_001_000 + seq,
            body: CompanionBody(fields: [
                "type": .string("desktop.status"),
                "online": .bool(true),
            ])
        )
    }
}
