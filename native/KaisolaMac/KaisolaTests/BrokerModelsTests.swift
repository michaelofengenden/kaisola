import KaisolaCore
import XCTest
@testable import KaisolaMacPreview

final class BrokerModelsTests: XCTestCase {
    func testStatusExtractsExactProjectCapabilityFromOwner() throws {
        let status = try BrokerStatus(
            status: validStatus,
            diagnostics: .array([
                .object([
                    "id": .string("terminal:codex-7"),
                    "owner": .string("instance-uuid|42|kaisola.project-1"),
                    "lastOwner": .string(""),
                    "pid": .integer(1234),
                    "exited": .bool(false),
                    "streamEpoch": .string("epoch-1"),
                    "endOffset": .integer(99),
                ]),
            ]),
            live: .array([]),
            expectedHello: hello
        )

        XCTAssertEqual(status.terminals.count, 1)
        XCTAssertEqual(status.terminals[0].projectID, "kaisola.project-1")
        XCTAssertEqual(status.terminals[0].title, "codex-7")
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
