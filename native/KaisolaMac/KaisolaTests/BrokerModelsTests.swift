import KaisolaCore
import XCTest
@testable import Kaisola

final class BrokerModelsTests: XCTestCase {
    func testStatusParsesPositiveBrokerActivityEpoch() throws {
        let status = try BrokerStatus(
            status: .object([
                "ok": .bool(true),
                "protocol": .integer(2),
                "securityEpoch": .integer(1),
                "activityEpoch": .integer(42),
            ]),
            diagnostics: .array([]),
            live: .array([]),
            expectedHello: hello
        )

        XCTAssertEqual(status.activityEpoch, 42)
    }

    func testStatusRejectsInvalidBrokerActivityEpoch() {
        for invalid in [JSONValue.integer(0), .integer(-1), .string("42")] {
            var object = validStatus.objectValue!
            object["activityEpoch"] = invalid
            XCTAssertThrowsError(try BrokerStatus(
                status: .object(object),
                diagnostics: .array([]),
                live: .array([]),
                expectedHello: hello
            )) { error in
                XCTAssertEqual(error as? BrokerClientError, .malformedResponse)
            }
        }
    }

    func testStatusExtractsExactProjectCapabilityFromOwner() throws {
        let status = try BrokerStatus(
            status: validStatus,
            diagnostics: .array([
                .object([
                    "id": .string("terminal:codex-7"),
                    "owner": .string("instance-uuid|42|kaisola.project-1"),
                    "lastOwner": .string(""),
                    "pid": .integer(1234),
                    "cols": .integer(132),
                    "rows": .integer(38),
                    "exited": .bool(false),
                    "streamEpoch": .string("epoch-1"),
                    "endOffset": .integer(99),
                    "diskBytes": .integer(67_108_864),
                ]),
            ]),
            live: .array([]),
            expectedHello: hello
        )

        XCTAssertEqual(status.terminals.count, 1)
        XCTAssertEqual(status.terminals[0].projectID, "kaisola.project-1")
        XCTAssertEqual(status.terminals[0].currentOwnerID, "42")
        XCTAssertEqual(status.terminals[0].currentOwnerInstanceID, "instance-uuid")
        XCTAssertEqual(status.terminals[0].columns, 132)
        XCTAssertEqual(status.terminals[0].rows, 38)
        XCTAssertEqual(status.terminals[0].diskBytes, 67_108_864)
        XCTAssertNil(status.terminals[0].lastOwnerID)
        XCTAssertTrue(status.terminals[0].wasOwned(by: "42"))
        XCTAssertEqual(status.terminals[0].title, "codex-7")
    }

    func testStatusExtractsStableOwnerFromLastOwnerOnly() throws {
        let status = try BrokerStatus(
            status: validStatus,
            diagnostics: .array([
                .object([
                    "id": .string("terminal:zsh"),
                    "owner": .string(""),
                    "lastOwner": .string("old-instance|native-install-7|nproj_example"),
                    "exited": .bool(false),
                ]),
            ]),
            live: .array([]),
            expectedHello: hello
        )

        let terminal = try XCTUnwrap(status.terminals.first)
        XCTAssertEqual(terminal.projectID, "nproj_example")
        XCTAssertNil(terminal.currentOwnerID)
        XCTAssertNil(terminal.currentOwnerInstanceID)
        XCTAssertEqual(terminal.lastOwnerID, "native-install-7")
        XCTAssertEqual(terminal.lastOwnerInstanceID, "old-instance")
        XCTAssertTrue(terminal.wasOwned(by: "native-install-7"))
        XCTAssertFalse(terminal.wasOwned(by: "another-install"))
    }

    func testLegacyCapabilityDoesNotClaimAStableOwner() throws {
        let status = try BrokerStatus(
            status: validStatus,
            diagnostics: .array([
                .object([
                    "id": .string("terminal:legacy"),
                    "owner": .string("old-instance|legacy-project"),
                ]),
            ]),
            live: .array([]),
            expectedHello: hello
        )

        let terminal = try XCTUnwrap(status.terminals.first)
        XCTAssertEqual(terminal.projectID, "legacy")
        XCTAssertNil(terminal.currentOwnerID)
        XCTAssertFalse(terminal.wasOwned(by: "legacy-project"))
    }

    func testStatusDropsTerminalWithoutExactProjectCapability() throws {
        let status = try BrokerStatus(
            status: validStatus,
            diagnostics: .array([
                .object(["id": .string("orphan"), "owner": .string("")]),
            ]),
            live: .array([]),
            expectedHello: hello
        )
        XCTAssertTrue(status.terminals.isEmpty)
    }

    func testSnapshotRequiresByteExactOffsets() {
        let invalid: JSONValue = .object([
            "streamEpoch": .string("epoch"),
            "output": .string("é"),
            "startOffset": .integer(0),
            "endOffset": .integer(1),
        ])
        XCTAssertThrowsError(try TerminalSnapshot(value: invalid))
    }

    func testHistoryPageRequiresContiguousByteExactOffsets() throws {
        let valid: JSONValue = .object([
            "ok": .bool(true),
            "streamEpoch": .string("epoch"),
            "output": .string("hé"),
            "startOffset": .integer(7),
            "endOffset": .integer(10),
            "hasMore": .bool(true),
            "truncated": .bool(false),
        ])
        let page = try TerminalHistoryPage(
            value: valid,
            expectedEpoch: "epoch",
            beforeOffset: 10
        )
        XCTAssertEqual(page.output, "hé")
        XCTAssertEqual(page.id, 7)
        XCTAssertTrue(page.hasMore)

        XCTAssertThrowsError(try TerminalHistoryPage(
            value: valid,
            expectedEpoch: "epoch",
            beforeOffset: 11
        ))
    }

    func testStatusRejectsAProtocolDriftBeforeUsingInventory() {
        let drifted: JSONValue = .object([
            "ok": .bool(true),
            "protocol": .integer(99),
            "securityEpoch": .integer(1),
        ])
        XCTAssertThrowsError(
            try BrokerStatus(
                status: drifted,
                diagnostics: .array([]),
                live: .array([]),
                expectedHello: hello
            )
        ) { error in
            XCTAssertEqual(error as? BrokerClientError, .malformedResponse)
        }
    }

    func testStatusRequiresTheHelloContentIdentityToRemainPresentAndExact() {
        let sealedHello = BrokerHello(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: 1,
            packageVersion: "1.0.0",
            contentDigest: String(repeating: "a", count: 64),
            features: [],
            pid: 1_234,
            startedAt: 1_784_250_001_000,
            version: "test",
            serverEnforcedObserver: true
        )
        XCTAssertThrowsError(try BrokerStatus(
            status: .object([
                "ok": .bool(true),
                "protocol": .integer(2),
                "securityEpoch": .integer(1),
                "implementationVersion": .integer(1),
                "packageSchema": .integer(1),
                "packageVersion": .string("1.0.0"),
            ]),
            diagnostics: .array([]),
            live: .array([]),
            expectedHello: sealedHello
        )) { error in
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
    }

    private var validStatus: JSONValue {
        .object([
            "ok": .bool(true),
            "protocol": .integer(2),
            "securityEpoch": .integer(1),
        ])
    }

    private var hello: BrokerHello {
        BrokerHello(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: nil,
            packageVersion: nil,
            features: [],
            pid: 1_234,
            startedAt: 1_784_250_001_000,
            version: "test",
            serverEnforcedObserver: true
        )
    }
}
