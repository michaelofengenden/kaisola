import Foundation
import KaisolaBrokerProtocol
import KaisolaSessionBrokerCore
import XCTest

@testable import Kaisola

/// The in-process engine owns agent-turn settlement the way the broker's
/// terminal manager did: the shell's OSC 133;D command-end mark closes a turn,
/// a pty exit closes it, and sustained quiet only relaxes the busy indicator
/// while leaving the turn open for a later mark to confirm.
final class InProcessTerminalServiceTests: XCTestCase {
    func testShellCommandEndMarkSplitAcrossChunksSettlesTheTurn() async throws {
        let harness = try await Harness(agentQuietInterval: 600)
        try await harness.openAgentTurn()

        harness.emit("build output without any mark\n")
        var activity = harness.core.activity(for: Harness.terminalID)
        XCTAssertEqual(activity, .working)

        // The mark split across two pty reads must still match via the carry.
        harness.emit("\u{1B}]133;")
        harness.emit("D\u{1B}\\prompt$ ")

        activity = harness.core.activity(for: Harness.terminalID)
        guard case .responded = activity else {
            return XCTFail("The split command-end mark did not settle the turn: \(activity)")
        }

        let settles = harness.events.settles()
        XCTAssertEqual(settles.count, 1)
        // The frame carries the observer's identity, not the control owner's;
        // the app authenticates events against its observer owner and would
        // silently drop a copy addressed any other way.
        XCTAssertEqual(settles.first?.ownerID, Harness.observerOwnerID)
        XCTAssertEqual(settles.first?.projectID, Harness.projectID)
    }

    func testQuietRelaxesBusyAndALaterMarkKeepsTheQuietTimestamp() async throws {
        let harness = try await Harness(agentQuietInterval: 0.08)
        try await harness.openAgentTurn()

        // Wait for the relax FRAME, not just the state flip: the quiet task
        // publishes state before it broadcasts, and racing past it here would
        // read one frame where two eventually land.
        let relaxFrames = await harness.events.waitForSettles(count: 1)
        guard let quietAt = relaxFrames.first?.completedAt else {
            return XCTFail("Quiet never relaxed the busy indicator")
        }
        XCTAssertEqual(harness.core.activity(for: Harness.terminalID), .responded(at: quietAt))

        // The turn stayed open, so the mark confirms it without moving the
        // timestamp the UI already showed for the quiet edge.
        harness.emit("\u{1B}]133;D")
        let confirmed = harness.core.activity(for: Harness.terminalID)
        XCTAssertEqual(confirmed, .responded(at: quietAt))

        let settles = await harness.events.waitForSettles(count: 2)
        XCTAssertEqual(settles.count, 2)
        XCTAssertTrue(settles.allSatisfy { $0.completedAt == quietAt })
    }

    func testOutputKeepsAQuietTurnBusyPastTheInterval() async throws {
        let harness = try await Harness(agentQuietInterval: 0.5)
        try await harness.openAgentTurn()

        // Markless output at 0.3s re-arms the window: without it the turn
        // would relax at 0.5s, with it nothing can relax before 0.8s, so the
        // 0.6s check reads working with slack on both sides.
        try await Task.sleep(nanoseconds: 300_000_000)
        harness.emit("still compiling...\n")
        try await Task.sleep(nanoseconds: 300_000_000)
        let activity = harness.core.activity(for: Harness.terminalID)
        XCTAssertEqual(activity, .working)
    }

    func testPtyExitSettlesTheOpenTurn() async throws {
        let harness = try await Harness(agentQuietInterval: 600)
        try await harness.openAgentTurn()

        harness.finishProcess(status: 0)

        let settled = await harness.waitForResponded()
        guard case .responded = settled else {
            return XCTFail("The pty exit did not settle the turn: \(settled)")
        }
    }

    func testHelloDoesNotAdvertiseObserverCoalescing() async throws {
        let harness = try await Harness(agentQuietInterval: 600)
        let hello = try await harness.facade.connect(to: harness.info)
        // The engine publishes each pty read as it lands; claiming the
        // broker's frame batching would switch off the app's own window.
        XCTAssertFalse(hello.features.contains(BrokerWire.terminalObserverCoalescingFeature))
        XCTAssertTrue(hello.features.contains(BrokerWire.terminalHistoryFeature))
    }
}

// MARK: - Harness

private final class Harness: @unchecked Sendable {
    static let projectID = "proj-inprocess"
    static let terminalID = "term-inprocess-1"
    static let observerOwnerID = "kaisola-native"

    let core: InProcessTerminalCore
    let facade: InProcessTerminalService
    let events = RecordedEvents()
    let info: BrokerInfo
    private let factory: ScriptedPTYFactory

    init(agentQuietInterval: TimeInterval) async throws {
        factory = ScriptedPTYFactory()
        core = InProcessTerminalCore(factory: factory, agentQuietInterval: agentQuietInterval)
        facade = InProcessTerminalService(core: core)
        info = try await facade.prepare()
        let events = events
        await facade.setEventHandler { events.append($0) }
        try await facade.connect(to: info, ownerID: "native-control-owner")
        _ = try await facade.createTerminal(
            projectID: Self.projectID,
            terminalID: Self.terminalID,
            command: "/bin/zsh",
            arguments: [],
            cwd: "/tmp",
            columns: 80,
            rows: 24,
            restore: false
        )
        guard let record = try await facade.inventory().terminals.first else {
            throw HarnessError.terminalMissing
        }
        _ = try await facade.subscribeBounded(
            to: record,
            ownerID: Self.observerOwnerID,
            cursor: nil,
            maximumSnapshotBytes: 1 << 20
        )
    }

    func openAgentTurn() async throws {
        try await facade.setAgentTurn(
            projectID: Self.projectID,
            terminalID: Self.terminalID,
            busy: true
        )
    }

    func emit(_ text: String) {
        factory.emit(Data(text.utf8))
    }

    func finishProcess(status: Int32) {
        factory.finish(status: status)
    }

    func waitForResponded() async -> AgentActivity {
        for _ in 0..<200 {
            let activity = core.activity(for: Self.terminalID)
            if case .responded = activity { return activity }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return core.activity(for: Self.terminalID)
    }

    enum HarnessError: Error {
        case terminalMissing
    }
}

private struct SettleFrame {
    let ownerID: String
    let projectID: String
    let completedAt: Int64?
}

private final class RecordedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BrokerEvent] = []

    func append(_ event: BrokerEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func settles() -> [SettleFrame] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event in
            guard case let .activity(busy, completedAt) = event.kind, !busy else { return nil }
            return SettleFrame(
                ownerID: event.ownerID,
                projectID: event.projectID,
                completedAt: completedAt
            )
        }
    }

    func waitForSettles(count: Int) async -> [SettleFrame] {
        for _ in 0..<200 {
            let frames = settles()
            if frames.count >= count { return frames }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return settles()
    }
}

// MARK: - Scripted PTY

private final class ScriptedPTYFactory: FreshTerminalProcessFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [@Sendable (Data) -> Void] = []
    private var processes: [ScriptedPTYProcess] = []

    func spawn(
        request: FreshTerminalSpawnRequest,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> any FreshTerminalProcess {
        let process = ScriptedPTYProcess(pid: 41_000)
        record(onOutput, process)
        return process
    }

    private func record(
        _ onOutput: @escaping @Sendable (Data) -> Void,
        _ process: ScriptedPTYProcess
    ) {
        lock.lock()
        defer { lock.unlock() }
        outputs.append(onOutput)
        processes.append(process)
    }

    /// Drives the single test terminal's output through the same closure the
    /// store handed the factory, tap included.
    func emit(_ data: Data) {
        lock.lock()
        let sink = outputs.last
        lock.unlock()
        sink?(data)
    }

    func finish(status: Int32) {
        lock.lock()
        let process = processes.last
        lock.unlock()
        process?.finish(status: status)
    }
}

private final class ScriptedPTYProcess: FreshTerminalProcess, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private var exited = false
    private var status: Int32 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(pid: Int32) {
        self.pid = pid
    }

    func write(_ data: Data) throws {}

    func resize(columns: Int, rows: Int) throws {}

    func send(signal: Int32) throws {}

    func waitForFreshTerminalExit() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func terminateFreshTerminal(graceNanoseconds: UInt64) async throws {
        finish(status: 143)
    }

    func freshTerminalExitStatus() async -> FreshTerminalExitStatus? {
        currentStatus()
    }

    private func currentStatus() -> FreshTerminalExitStatus? {
        lock.lock()
        defer { lock.unlock() }
        return exited ? FreshTerminalExitStatus(exitCode: Int64(status)) : nil
    }

    func finish(status: Int32) {
        lock.lock()
        if exited {
            lock.unlock()
            return
        }
        exited = true
        self.status = status
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}
