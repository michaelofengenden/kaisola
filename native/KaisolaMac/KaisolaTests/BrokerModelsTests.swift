import KaisolaCore
import XCTest
@testable import Kaisola

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

    func testStatusRejectsDuplicateLiveTerminalIdentifiers() {
        XCTAssertThrowsError(try BrokerStatus(
            status: validStatus,
            diagnostics: .array([diagnosticEntry(id: "terminal:codex-7")]),
            live: .array([
                liveEntry(id: "terminal:codex-7", pid: 11),
                liveEntry(id: "terminal:codex-7", pid: 12),
            ]),
            expectedHello: hello
        )) { error in
            XCTAssertEqual(error as? BrokerClientError, .malformedResponse)
        }
    }

    func testStatusRejectsDuplicateDiagnosticTerminalIdentifiers() {
        XCTAssertThrowsError(try BrokerStatus(
            status: validStatus,
            diagnostics: .array([
                diagnosticEntry(id: "terminal:zsh"),
                diagnosticEntry(id: "terminal:zsh"),
            ]),
            live: .array([]),
            expectedHello: hello
        )) { error in
            XCTAssertEqual(error as? BrokerClientError, .malformedResponse)
        }
    }

    func testStatusStillPairsLiveValuesWhenEveryIdentifierIsDistinct() throws {
        let status = try BrokerStatus(
            status: validStatus,
            diagnostics: .array([
                diagnosticEntry(id: "terminal:one"),
                diagnosticEntry(id: "terminal:two"),
            ]),
            live: .array([liveEntry(id: "terminal:two", pid: 4_242)]),
            expectedHello: hello
        )
        XCTAssertEqual(status.terminals.map(\.id), ["terminal:one", "terminal:two"])
        XCTAssertNil(status.terminals[0].pid)
        XCTAssertEqual(status.terminals[1].pid, 4_242)
    }

    /// Duplicate ids used to reach `Dictionary(uniqueKeysWithValues:)`, which
    /// traps. Reaching the assertions below at all is the coverage: a trap
    /// would take the whole test process down instead of failing a case.
    func testDuplicateIdentifierFuzzNeverTrapsTheProcess() {
        var generator = SeededGenerator(seed: 0x5EED_0467)
        let pool = ["terminal:a", "terminal:b", "terminal:c", ""]
        for iteration in 0 ..< 500 {
            let diagnostics = (0 ..< Int.random(in: 0 ... 6, using: &generator)).map { _ in
                fuzzEntry(pool: pool, generator: &generator) { id in
                    self.diagnosticEntry(id: id)
                }
            }
            let live = (0 ..< Int.random(in: 0 ... 6, using: &generator)).map { _ in
                fuzzEntry(pool: pool, generator: &generator) { id in
                    self.liveEntry(id: id, pid: 4_000)
                }
            }
            do {
                let status = try BrokerStatus(
                    status: validStatus,
                    diagnostics: .array(diagnostics),
                    live: .array(live),
                    expectedHello: hello
                )
                XCTAssertEqual(
                    Set(status.terminals.map(\.id)).count,
                    status.terminals.count,
                    "iteration \(iteration) decoded a duplicate terminal id"
                )
            } catch let error as BrokerClientError {
                XCTAssertEqual(error, .malformedResponse, "iteration \(iteration)")
            } catch {
                XCTFail("iteration \(iteration) threw an unexpected error: \(error)")
            }
        }
    }

    private func diagnosticEntry(id: String) -> JSONValue {
        .object([
            "id": .string(id),
            "owner": .string("instance-uuid|42|kaisola.project-1"),
            "exited": .bool(false),
        ])
    }

    private func liveEntry(id: String, pid: Int64) -> JSONValue {
        .object([
            "id": .string(id),
            "pid": .integer(pid),
        ])
    }

    /// One fuzz element: usually a well-formed entry drawn from a tiny id pool
    /// so duplicates are common, occasionally shaped junk the decoder skips.
    private func fuzzEntry(
        pool: [String],
        generator: inout SeededGenerator,
        make: (String) -> JSONValue
    ) -> JSONValue {
        switch Int.random(in: 0 ... 9, using: &generator) {
        case 0: .string("not-an-object")
        case 1: .object(["owner": .string("instance-uuid|42|kaisola.project-1")])
        default: make(pool.randomElement(using: &generator) ?? "")
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

/// SplitMix64. Deterministic so a fuzz failure reproduces from the seed alone.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
