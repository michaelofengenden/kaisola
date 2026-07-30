import Foundation
import KaisolaBrokerProtocol
import XCTest
@testable import Kaisola

/// The controller lane's contract: its sealed method set is exactly the
/// mutations the native app needs, every request carries the owner identity,
/// and the connection refuses brokers that predate role enforcement.
final class BrokerControlClientTests: XCTestCase {
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
