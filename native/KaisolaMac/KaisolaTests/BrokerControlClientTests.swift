import Darwin
import Foundation
import KaisolaBrokerProtocol
import KaisolaCore
import XCTest
@testable import Kaisola

/// The controller lane's contract: its sealed method set is exactly the
/// mutations the native app needs, every request carries the owner identity,
/// and the connection refuses brokers that predate role enforcement.
final class BrokerControlClientTests: XCTestCase {
    func testResizeRequiresPositiveBrokerAcknowledgement() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: false)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        do {
            try await client.resize(
                projectID: "project.one",
                terminalID: "terminal-one",
                columns: 120,
                rows: 40
            )
            XCTFail("An inner {ok:false} result must not be cached as applied geometry.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .requestFailed("terminal.resize"))
        }
        await client.disconnect()
    }

    func testResizeAcceptsExplicitPositiveBrokerAcknowledgement() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        try await client.resize(
            projectID: "project.one",
            terminalID: "terminal-one",
            columns: 132,
            rows: 44
        )
        let frames = await transport.sentFrames()
        let request = try XCTUnwrap(frames.last?.objectValue)
        XCTAssertEqual(request["method"]?.stringValue, "terminal.resize")
        XCTAssertEqual(request["params"]?.objectValue?["cols"]?.intValue, 132)
        XCTAssertEqual(request["params"]?.objectValue?["rows"]?.intValue, 44)
        await client.disconnect()
    }

    func testAgentTurnRequiresPositiveBrokerAcknowledgement() async throws {
        let transport = ScriptedControlBrokerTransport(
            resizeAccepted: true,
            agentTurnAccepted: false
        )
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        do {
            try await client.setAgentTurn(
                projectID: "project.one",
                terminalID: "terminal-one",
                busy: true
            )
            XCTFail("A refused turn leaves the broker eligible for rolling cutover.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .requestFailed("terminal.agentTurn"))
        }
        await client.disconnect()
    }

    func testAgentTurnAcceptsExplicitPositiveBrokerAcknowledgement() async throws {
        let transport = ScriptedControlBrokerTransport(
            resizeAccepted: true,
            agentTurnAccepted: true
        )
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        try await client.setAgentTurn(
            projectID: "project.one",
            terminalID: "terminal-one",
            busy: true
        )
        let frames = await transport.sentFrames()
        let request = try XCTUnwrap(frames.last?.objectValue)
        XCTAssertEqual(request["method"]?.stringValue, "terminal.agentTurn")
        XCTAssertEqual(request["params"]?.objectValue?["busy"]?.boolValue, true)
        await client.disconnect()
    }

    func testControllerLaneReportsUnexpectedPeerDisconnect() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        let signal = DisconnectSignal()
        await client.setDisconnectHandler { error in
            Task { await signal.record(error) }
        }
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        await transport.disconnectPeer()
        for _ in 0..<100 {
            if await signal.count > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let disconnectCount = await signal.count
        let disconnectDescription = await signal.lastDescription
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(disconnectDescription, BrokerClientError.connectionClosed.localizedDescription)
        await client.disconnect()
    }

    func testExplicitControllerDisconnectDoesNotReportConnectionLoss() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        let signal = DisconnectSignal()
        await client.setDisconnectHandler { error in
            Task { await signal.record(error) }
        }
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        await client.disconnect()
        try await Task.sleep(nanoseconds: 10_000_000)
        let disconnectCount = await signal.count
        XCTAssertEqual(disconnectCount, 0, "App quit/reload must not schedule a recovery reconnect.")
    }

    func testUnixTransportShutdownWakesBlockedReceive() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let transport = UnixBrokerTransport(connectedFileDescriptor: descriptors[0])
        defer { Darwin.close(descriptors[1]) }

        let receive = Task {
            do {
                _ = try await transport.receive(maximumBytes: 64)
                return true
            } catch {
                // shutdown may surface as EOF or a socket error; both prove the
                // blocked system call was released.
                return true
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        await transport.close()
        let didUnblock = await receive.value
        XCTAssertTrue(didUnblock)
    }

    private var controlBrokerInfo: BrokerInfo {
        BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            pid: 12_345,
            socketPath: "/tmp/kaisola-controller-test.sock",
            token: String(repeating: "a", count: 64),
            startedAt: 1_784_250_001_000,
            version: "test"
        )
    }

    func testControlMethodSetIsExactlyTheNativeMutationSurface() {
        XCTAssertEqual(
            Set(ControlBrokerMethod.allCases.map(\.rawValue)),
            [
                "terminal.create",
                "terminal.attach",
                "terminal.write",
                "terminal.resize",
                "terminal.kill",
                "terminal.release",
                "terminal.detachOwner",
                "terminal.agentTurn",
                "terminal.controlLease",
            ]
        )
    }

    func testControlMethodsNeverOverlapObserverPolicyReads() {
        let controlMethods = Set(ControlBrokerMethod.allCases.map(\.rawValue))
        let observerMethods = Set(ObserveOnlyBrokerMethod.allCases.map(\.rawValue))
        XCTAssertTrue(controlMethods.isDisjoint(with: observerMethods))
        // Every control method is one the observer policy explicitly forbids,
        // proving the two lanes partition the wire surface.
        XCTAssertTrue(controlMethods.isSubset(of: ObserveOnlyBrokerPolicy.forbiddenTerminalMethods))
    }

    func testNewTerminalsNeutralizeOuterCLILauncherColorState() {
        XCTAssertEqual(BrokerControlClient.cleanTerminalEnvironment, [
            "PROMPT_EOL_MARK": .string(""),
            "NO_COLOR": .string(""),
            "FORCE_COLOR": .string("1"),
            "CODEX_CI": .string(""),
            "CODEX_MANAGED_BY_NPM": .string(""),
            "CODEX_MANAGED_PACKAGE_ROOT": .string(""),
            "CODEX_THREAD_ID": .string(""),
        ])
    }

    func testUpgradeDecisionPreservesBrokerAuthoritativeBlockersExactly() throws {
        let decision = try BrokerControlClient.upgradeDecision(.object([
            "ok": .bool(false),
            "state": .string("pending"),
            "liveTerminalCount": .integer(2),
            "liveTerminalIds": .array([.string("claude"), .string("codex")]),
            "busyAgentCount": .integer(1),
            "busyTerminalIds": .array([.string("claude")]),
            "childTaskCount": .integer(3),
        ]))
        XCTAssertEqual(decision, .deferred(BrokerUpgradeBlockers(
            liveTerminalCount: 2,
            liveTerminalIDs: ["claude", "codex"],
            busyAgentCount: 1,
            busyTerminalIDs: ["claude"],
            childTaskCount: 3
        )))
    }

    func testUpgradeDecisionRejectsCountAndIdentityDrift() {
        XCTAssertThrowsError(try BrokerControlClient.upgradeDecision(.object([
            "ok": .bool(false),
            "state": .string("pending"),
            "liveTerminalCount": .integer(2),
            "liveTerminalIds": .array([.string("only-one")]),
            "busyAgentCount": .integer(0),
            "busyTerminalIds": .array([]),
            "childTaskCount": .integer(0),
        ]))) { error in
            XCTAssertEqual(error as? BrokerClientError, .malformedResponse)
        }
    }

    func testUpgradePreflightRequiresExactStatusIdentityAndAdvertisedCapability() throws {
        let info = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: 1,
            packageVersion: "1.0.0",
            contentDigest: String(repeating: "a", count: 64),
            pid: 7_777,
            socketPath: "/tmp/broker.sock",
            token: String(repeating: "b", count: 64),
            startedAt: 123_456,
            version: "test"
        )
        let valid: JSONValue = .object([
            "ok": .bool(true),
            "pid": .integer(7_777),
            "startedAt": .integer(123_456),
            "implementationVersion": .integer(1),
            "packageSchema": .integer(1),
            "packageVersion": .string("1.0.0"),
            "contentDigest": .string(String(repeating: "a", count: 64)),
            "features": .array([.string(BrokerWire.brokerUpdateFeature)]),
        ])
        XCTAssertNoThrow(try BrokerControlClient.validateUpgradeStatus(valid, expected: info))

        guard var unsupported = valid.objectValue else { return XCTFail("expected object") }
        unsupported["features"] = .array([])
        XCTAssertThrowsError(
            try BrokerControlClient.validateUpgradeStatus(.object(unsupported), expected: info)
        ) { error in
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
    }

    func testSessionStorePersistsOwnershipAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-session-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("native-sessions.json")

        let first = NativeSessionStore(fileURL: file)
        let owner = first.ownerID()
        XCTAssertTrue(owner.hasPrefix("native-"))
        first.upsert(NativeOwnedSession(
            id: "term-nproj_abc-1",
            projectID: "nproj_abc",
            cwd: "/tmp/example",
            title: "example",
            createdAt: 1
        ))

        let second = NativeSessionStore(fileURL: file)
        XCTAssertEqual(second.ownerID(), owner)
        XCTAssertTrue(second.owns(terminalID: "term-nproj_abc-1"))
        XCTAssertFalse(second.owns(terminalID: "term-proj_electron"))

        second.remove(terminalID: "term-nproj_abc-1")
        XCTAssertFalse(NativeSessionStore(fileURL: file).owns(terminalID: "term-nproj_abc-1"))
    }

    func testProjectIdentityIsDeterministicAndNamespaced() {
        let one = NativeSessionStore.projectID(forDirectory: "/Users/example/code/app")
        let two = NativeSessionStore.projectID(forDirectory: "/Users/example/code/app/")
        let other = NativeSessionStore.projectID(forDirectory: "/Users/example/code/other")
        XCTAssertEqual(one, two)
        XCTAssertNotEqual(one, other)
        XCTAssertTrue(one.hasPrefix("nproj_"))
        XCTAssertFalse(one.hasPrefix("proj_"))
    }

    func testControlSurfaceIncludesAgentTurnAndStaysSealed() {
        XCTAssertTrue(ControlBrokerMethod.allCases.map(\.rawValue).contains("terminal.agentTurn"))
        // Still disjoint from the observer reads and still a strict subset of
        // the methods the observer policy forbids — the two lanes never blur.
        let controlMethods = Set(ControlBrokerMethod.allCases.map(\.rawValue))
        XCTAssertTrue(controlMethods.isDisjoint(with: Set(ObserveOnlyBrokerMethod.allCases.map(\.rawValue))))
        XCTAssertTrue(controlMethods.isSubset(of: ObserveOnlyBrokerPolicy.forbiddenTerminalMethods))
    }

    func testAgentRegistryRecognizesClaudeAndCodexByCommand() {
        XCTAssertEqual(AgentRegistry.profile(id: "claude-code")?.name, "Claude")
        XCTAssertEqual(AgentRegistry.profile(id: "codex")?.name, "Codex")
        XCTAssertEqual(AgentRegistry.profile(forCommand: "claude")?.id, "claude-code")
        XCTAssertEqual(AgentRegistry.profile(forCommand: "/opt/homebrew/bin/codex")?.id, "codex")
        XCTAssertEqual(AgentRegistry.profile(displayName: "Claude")?.id, "claude-code")
        XCTAssertEqual(AgentRegistry.profile(displayName: "codex")?.id, "codex")
        XCTAssertNil(AgentRegistry.profile(displayName: "npm"))
        XCTAssertNil(AgentRegistry.profile(forCommand: "/bin/zsh"))
        XCTAssertNil(AgentRegistry.profile(forCommand: ""))
    }

    func testSessionStorePersistsAgentIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-agent-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("native-sessions.json")

        let store = NativeSessionStore(fileURL: file)
        store.upsert(NativeOwnedSession(
            id: "term-nproj_x-1", projectID: "nproj_x", cwd: "/tmp/x",
            title: "Claude · x", createdAt: 1, agentID: "claude-code"
        ))
        let reread = NativeSessionStore(fileURL: file).sessions().first
        XCTAssertEqual(reread?.agentID, "claude-code")
    }

    func testAgentActivityParsesFromBrokerRecord() {
        let working = BrokerTerminalRecord(
            value: .object([
                "id": .string("term-nproj_a-1"),
                "owner": .string("native-1|1|nproj_a"),
                "agentBusy": .bool(true),
            ])
        )
        XCTAssertEqual(working?.agentActivity, .working)

        let responded = BrokerTerminalRecord(
            value: .object([
                "id": .string("term-nproj_a-2"),
                "owner": .string("native-1|1|nproj_a"),
                "agentBusy": .bool(false),
                "agentCompletedAt": .integer(1_700_000_000_000),
            ])
        )
        XCTAssertEqual(responded?.agentActivity, .responded(at: 1_700_000_000_000))

        let idle = BrokerTerminalRecord(
            value: .object([
                "id": .string("term-nproj_a-3"),
                "owner": .string("native-1|1|nproj_a"),
            ])
        )
        XCTAssertEqual(idle?.agentActivity, .idle)
    }

    func testCorruptStoreDegradesToEmptyRegistry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-session-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("native-sessions.json")
        try Data("not json".utf8).write(to: file)

        let store = NativeSessionStore(fileURL: file)
        XCTAssertEqual(store.sessions(), [])
        XCTAssertTrue(store.ownerID().hasPrefix("native-"))
    }
}

private actor DisconnectSignal {
    private(set) var count = 0
    private(set) var lastDescription: String?

    func record(_ error: any Error) {
        count += 1
        lastDescription = error.localizedDescription
    }
}

private actor ScriptedControlBrokerTransport: BrokerByteTransport {
    private let resizeAccepted: Bool
    private let agentTurnAccepted: Bool
    private var frames: [JSONValue] = []
    private var incoming: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?

    init(resizeAccepted: Bool, agentTurnAccepted: Bool = true) {
        self.resizeAccepted = resizeAccepted
        self.agentTurnAccepted = agentTurnAccepted
    }

    func connect(path: String) async throws {}

    func send(_ data: Data) async throws {
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw BrokerClientError.malformedResponse
        }
        let frame = try JSONDecoder().decode(JSONValue.self, from: data[..<newline])
        frames.append(frame)
        guard let object = frame.objectValue,
              let type = object["type"]?.stringValue else { return }
        if type == "hello" {
            deliver(try encoded(.object([
                "type": .string("hello"),
                "ok": .bool(true),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
                "features": .array([.string(BrokerWire.terminalObserveFeature)]),
            ])))
            return
        }
        guard type == "request", let id = object["id"]?.stringValue else { return }
        let result: JSONValue
        switch object["method"]?.stringValue {
        case "terminal.resize":
            result = .object(["ok": .bool(resizeAccepted)])
        case "terminal.agentTurn":
            result = .object(["ok": .bool(agentTurnAccepted)])
        default:
            result = .object(["ok": .bool(true)])
        }
        deliver(try encoded(.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ])))
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func close() async {
        deliver(nil)
    }

    func disconnectPeer() {
        deliver(nil)
    }

    func sentFrames() -> [JSONValue] { frames }

    private func encoded(_ frame: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        return data
    }

    private func deliver(_ data: Data?) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            incoming.append(data)
        }
    }
}
