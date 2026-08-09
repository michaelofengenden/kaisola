import Darwin
import Foundation
import XCTest
@testable import Kaisola

/// End-to-end proof that the Swift ACP client speaks the wire protocol over a
/// REAL child process — it spawns the Node mock agent
/// (`tests/fixtures/acp/nativeAcpMock.cjs`) through AcpProcessTransport and runs a full
/// handshake + streamed turn + permission callback. Skips cleanly if node or
/// the mock is unavailable so it never fails a machine without the toolchain.
final class AcpProcessIntegrationTests: XCTestCase {
    func testStdinQueueWritesFramesInFIFOOrderWithEnqueueTimeDeadlines() async throws {
        let clock = LockedMonotonicClock(1_000)
        let writer = SuspendedStdinWriter()
        let queue = AcpStdinWriteQueue(
            descriptor: -1,
            frameDeadlineNanoseconds: 100,
            maximumQueuedFrames: 4,
            maximumQueuedBytes: 64,
            writeOperation: { try await writer.write(data: $1, deadline: $2) },
            monotonicNow: { clock.value }
        )

        let first = Task { try await queue.send(Data("first".utf8)) }
        await writer.waitForCallCount(1)
        clock.value = 2_000
        let second = Task { try await queue.send(Data("second".utf8)) }
        await waitForQueuedFrames(2, in: queue)

        let activeCallCount = await writer.callCount
        XCTAssertEqual(activeCallCount, 1, "only one descriptor write may be active")
        await writer.succeedNext()
        await writer.waitForCallCount(2)
        await writer.succeedNext()
        try await first.value
        try await second.value

        let calls = await writer.calls
        XCTAssertEqual(calls.map(\.payload), ["first", "second"])
        XCTAssertEqual(calls.map(\.deadline), [1_100, 2_100])
        let drainedSnapshot = await queue.snapshotForTesting()
        XCTAssertEqual(
            drainedSnapshot,
            .init(queuedFrameCount: 0, queuedBytes: 0, isWriting: false, isClosed: false)
        )
        await queue.close()
    }

    func testStdinQueueOverflowFailsEveryFrameWithoutUnboundedRetention() async throws {
        let writer = SuspendedStdinWriter()
        let queue = AcpStdinWriteQueue(
            descriptor: -1,
            frameDeadlineNanoseconds: 1_000,
            maximumQueuedFrames: 2,
            maximumQueuedBytes: 9,
            writeOperation: { try await writer.write(data: $1, deadline: $2) },
            monotonicNow: { 10 }
        )
        let first = Task { try await queue.send(Data("1234".utf8)) }
        await writer.waitForCallCount(1)
        let second = Task { try await queue.send(Data("5678".utf8)) }
        await waitForQueuedFrames(2, in: queue)

        let overflowMessage: String
        do {
            try await queue.send(Data("9".utf8))
            XCTFail("the third frame must exceed the two-frame bound")
            overflowMessage = ""
        } catch let AcpClientError.requestFailed(message) {
            overflowMessage = message
        } catch {
            throw error
        }
        XCTAssertTrue(overflowMessage.contains("bounded capacity"))
        await assertFailed(first, message: overflowMessage)
        await assertFailed(second, message: overflowMessage)
        let failedSnapshot = await queue.snapshotForTesting()
        XCTAssertEqual(
            failedSnapshot,
            .init(queuedFrameCount: 0, queuedBytes: 0, isWriting: false, isClosed: true)
        )

        // The scripted operation intentionally ignores task cancellation until
        // the test releases it. Production poll slices observe cancellation.
        await writer.failNext(CancellationError())
        await queue.close()
    }

    func testAdapterThatNeverReadsStdinFailsAtTheFrameDeadlineAndClosesItsTree() async throws {
        let fixture = try OwnedProcessFixture()
        defer { fixture.forceCleanup() }
        let transport = AcpProcessTransport(stdinFrameDeadlineNanoseconds: 150_000_000)
        try await transport.start(
            command: "/bin/sh",
            arguments: ["-c", Self.termIgnoringTreeScript],
            environment: fixture.environment,
            cwd: fixture.directory.path
        )
        let pids = try await fixture.waitForPIDs()
        let startedAt = ContinuousClock.now

        do {
            try await transport.send(Data(repeating: 0x78, count: 2 * 1_024 * 1_024))
            XCTFail("a non-consuming adapter must not accept an unbounded frame")
        } catch let AcpClientError.requestFailed(message) {
            XCTAssertTrue(message.contains("stopped reading requests"))
        } catch {
            XCTFail("unexpected stdin failure: \(error)")
        }

        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(1),
            "the descriptor write must return at its own deadline, before process-group teardown"
        )
        let stopped = await fixture.waitUntilStopped(pids, timeout: .seconds(4))
        XCTAssertTrue(stopped, "stdin timeout must close and reap the owned adapter group")
    }

    @MainActor
    func testAdapterThatStopsReadingStdinFailsConnectionAndPreservesRetryablePrompt() async throws {
        let fixture = try OwnedProcessFixture()
        defer { fixture.forceCleanup() }
        let transport = AcpProcessTransport(stdinFrameDeadlineNanoseconds: 150_000_000)
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Backpressure",
            command: "/bin/sh",
            arguments: ["-c", Self.handshakeThenStopReadingStdinScript],
            environment: fixture.environment,
            cwd: fixture.directory.path,
            client: client
        )
        await conversation.start()
        XCTAssertTrue(conversation.isConnected)
        let pids = try await fixture.waitForPIDs()
        let prompt = String(repeating: "backpressure-payload-", count: 100_000)

        XCTAssertTrue(conversation.send(prompt))
        try await waitUntil(timeout: .seconds(2)) {
            !conversation.isRunning && conversation.rows.contains { row in
                if case let .user(_, text, failed) = row { return failed && text == prompt }
                return false
            }
        }

        let failedRow = try XCTUnwrap(conversation.rows.last)
        guard case let .user(rowID, retainedText, failed) = failedRow else {
            return XCTFail("the failed prompt must remain a user row")
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(retainedText, prompt)
        XCTAssertTrue(conversation.statusMessage?.contains("stopped reading requests") == true)

        let stopped = await fixture.waitUntilStopped(pids, timeout: .seconds(4))
        XCTAssertTrue(stopped, "write timeout must close and reap the owned adapter group")
        try await waitUntil(timeout: .seconds(1)) { !conversation.isConnected }

        // The failed row itself and its exact original payload survive the
        // dead connection. Exercising Retry proves it is not display-only.
        conversation.retryFailed("user-\(rowID)")
        try await waitUntil(timeout: .seconds(1)) { !conversation.isRunning }
        guard case let .user(_, retriedText, retryFailed)? = conversation.rows.last else {
            return XCTFail("retry must re-dispatch the retained user payload")
        }
        XCTAssertTrue(retryFailed)
        XCTAssertEqual(retriedText, prompt)
        _ = await conversation.stop()
    }

    func testTransportStopTerminatesItsAdapterAndAppServerChild() async throws {
        let fixture = try OwnedProcessFixture()
        defer { fixture.forceCleanup() }
        let transport = AcpProcessTransport()

        try await transport.start(
            command: "/bin/sh",
            arguments: ["-c", Self.ownedTreeScript],
            environment: fixture.environment,
            cwd: fixture.directory.path
        )
        let pids = try await fixture.waitForPIDs()
        let startedAt = ContinuousClock.now

        await transport.terminate()

        XCTAssertLessThan(
            startedAt.duration(to: .now),
            .seconds(1),
            "ordinary SIGTERM cleanup must not wait for the SIGKILL grace"
        )
        let stopped = await fixture.waitUntilStopped(pids)
        XCTAssertTrue(stopped, "adapter and app-server child must both stop")
    }

    func testStdoutEOFClosesTheOwningConnectionAndTerminatesTheProcessTree() async throws {
        let fixture = try OwnedProcessFixture()
        defer { fixture.forceCleanup() }
        let client = AcpClient()
        let collector = IntegrationCollector()
        await client.setEventHandler { event in collector.append(event) }

        _ = try await client.start(
            command: "/bin/sh",
            arguments: ["-c", Self.handshakeThenCloseStdoutScript],
            environment: fixture.environment,
            cwd: fixture.directory.path,
            mcpServers: []
        )
        let pids = try await fixture.waitForPIDs()

        let stopped = await fixture.waitUntilStopped(pids)
        XCTAssertTrue(stopped, "stdout EOF must tear down the adapter tree even when the adapter remains alive")
        XCTAssertTrue(collector.events.contains { if case .exited = $0 { return true } else { return false } })
        await client.stop()
    }

    func testAdapterExitReapsTheAppServerChildItLeavesBehind() async throws {
        let fixture = try OwnedProcessFixture()
        defer { fixture.forceCleanup() }
        let transport = AcpProcessTransport()
        try await transport.start(
            command: "/bin/sh",
            arguments: ["-c", Self.exitLeavingChildScript],
            environment: fixture.environment,
            cwd: fixture.directory.path
        )
        let pids = try await fixture.waitForPIDs()
        let eof = try await transport.receive(maximumBytes: 1_024)
        XCTAssertNil(eof)

        await transport.terminate()

        let stopped = await fixture.waitUntilStopped(pids)
        XCTAssertTrue(stopped, "an exited adapter must not orphan its surviving app-server child")
    }

    func testCancellingGUIStartupTaskTerminatesThePartiallyStartedProcessTree() async throws {
        let fixture = try OwnedProcessFixture()
        defer { fixture.forceCleanup() }
        let client = AcpClient()
        let environment = fixture.environment
        let cwd = fixture.directory.path
        let startup = Task { @Sendable in
            try await client.start(
                command: "/bin/sh",
                arguments: ["-c", Self.ownedTreeScript],
                environment: environment,
                cwd: cwd,
                mcpServers: []
            )
        }
        let pids = try await fixture.waitForPIDs()

        startup.cancel()

        let stopped = await fixture.waitUntilStopped(pids)
        XCTAssertTrue(stopped, "task cancellation must close startup ownership")
        await client.stop()
        switch await startup.result {
        case let .failure(error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("cancelled startup must finish with CancellationError")
        }
    }

    func testStartupProtocolFailureTerminatesThePartiallyStartedProcessTree() async throws {
        let fixture = try OwnedProcessFixture()
        defer { fixture.forceCleanup() }
        let client = AcpClient()

        do {
            _ = try await client.start(
                command: "/bin/sh",
                arguments: ["-c", Self.unsupportedHandshakeScript],
                environment: fixture.environment,
                cwd: fixture.directory.path,
                mcpServers: []
            )
            XCTFail("expected unsupported protocol")
        } catch let AcpClientError.unsupportedProtocol(version) {
            XCTAssertEqual(version, 2)
        } catch {
            XCTFail("unexpected startup error: \(error)")
        }
        let pids = try await fixture.waitForPIDs()
        let stopped = await fixture.waitUntilStopped(pids)
        XCTAssertTrue(stopped, "failed startup must leave no owned children")
    }

    func testTransportCanRepeatedlyOpenAndCloseWithoutLeakingChildren() async throws {
        let transport = AcpProcessTransport()
        var fixtures: [OwnedProcessFixture] = []
        defer { fixtures.forEach { $0.forceCleanup() } }

        for _ in 0..<3 {
            let fixture = try OwnedProcessFixture()
            fixtures.append(fixture)
            try await transport.start(
                command: "/bin/sh",
                arguments: ["-c", Self.ownedTreeScript],
                environment: fixture.environment,
                cwd: fixture.directory.path
            )
            let pids = try await fixture.waitForPIDs()
            await transport.terminate()
            let stopped = await fixture.waitUntilStopped(pids)
            XCTAssertTrue(stopped)
        }
    }

    func testTerminationEscalatesWithinABoundWhenOwnedChildrenIgnoreSIGTERM() async throws {
        let fixture = try OwnedProcessFixture()
        defer { fixture.forceCleanup() }
        let transport = AcpProcessTransport()
        try await transport.start(
            command: "/bin/sh",
            arguments: ["-c", Self.termIgnoringTreeScript],
            environment: fixture.environment,
            cwd: fixture.directory.path
        )
        let pids = try await fixture.waitForPIDs()
        let startedAt = ContinuousClock.now

        await transport.terminate()

        XCTAssertLessThan(startedAt.duration(to: .now), .seconds(4))
        let stopped = await fixture.waitUntilStopped(pids)
        XCTAssertTrue(stopped, "SIGKILL escalation must reap a stubborn tree")
    }

    func testTransportTeardownDoesNotTouchAnUnownedDurableProcess() async throws {
        let durable = try DetachedProcessFixture()
        defer { _ = durable.forceCleanup() }
        let fixture = try OwnedProcessFixture()
        defer { fixture.forceCleanup() }
        let transport = AcpProcessTransport()
        try await transport.start(
            command: "/bin/sh",
            arguments: ["-c", Self.ownedTreeScript],
            environment: fixture.environment,
            cwd: fixture.directory.path
        )
        let pids = try await fixture.waitForPIDs()

        await transport.terminate()

        let stopped = await fixture.waitUntilStopped(pids)
        XCTAssertTrue(stopped)
        XCTAssertTrue(durable.isRunning, "detached broker PTYs are outside ACP process ownership")
        let cleanupStartedAt = ContinuousClock.now
        XCTAssertTrue(durable.forceCleanup(), "durable fixture cleanup must be bounded and reap its child")
        XCTAssertLessThan(cleanupStartedAt.duration(to: .now), .seconds(2))
    }

    func testSpawnsMockAgentAndStreamsARealTurn() async throws {
        guard let node = Self.resolveNode(), let mock = Self.resolveMock() else {
            throw XCTSkip("node or the ACP mock agent is unavailable")
        }
        let client = AcpClient()
        let collector = IntegrationCollector()
        await client.setEventHandler { event in collector.append(event) }

        let info: AcpSessionInfo
        do {
            info = try await client.start(
                command: node,
                arguments: [mock],
                environment: ProcessInfo.processInfo.environment,
                cwd: FileManager.default.temporaryDirectory.path,
                mcpServers: []
            )
        } catch {
            throw XCTSkip("could not spawn the mock agent: \(error.localizedDescription)")
        }
        XCTAssertFalse(info.sessionID.isEmpty)
        // The real mock nests models/modes under SessionModeState-style objects;
        // this asserts the client parses that shape end-to-end (not just the
        // scripted flat fallback).
        XCTAssertFalse(info.models.isEmpty, "expected models from the mock's nested shape")
        XCTAssertFalse(info.modes.isEmpty, "expected modes from the mock's nested shape")

        // Answer the permission request the mock issues mid-turn.
        collector.onPermission = { request in
            let allow = request.options.first { $0.kind.contains("allow") } ?? request.options.first
            if let allow { Task { await client.resolvePermission(id: request.id, optionID: allow.id) } }
        }

        try await client.prompt("please make a change that needs permission")
        await client.stop()

        let events = collector.events
        XCTAssertTrue(events.contains { if case .turnItem(.message) = $0 { return true } else { return false } },
                      "expected at least one agent message")
        XCTAssertTrue(events.contains { if case .permission = $0 { return true } else { return false } },
                      "expected the permission callback")
        XCTAssertTrue(events.contains { if case .turnEnded = $0 { return true } else { return false } },
                      "expected the turn to end")

        // The mock attaches a diff artifact to its tool_call_update; assert it
        // streams through as parsed content (end-to-end proof of the inline-diff path).
        let diffArrived = events.contains { event in
            guard case let .toolCallUpdate(_, _, content, _, _) = event, let content else { return false }
            return content.contains { artifact in
                if case let .diff(path, _, _) = artifact { return path == "fixture/notes.txt" }
                return false
            }
        }
        XCTAssertTrue(diffArrived, "expected the tool_call_update's diff artifact to parse through")

        // The mock's config options (approval preset + reasoning effort) parse.
        XCTAssertFalse(info.configOptions.isEmpty, "expected configOptions from the mock")
        // Slash commands stream via available_commands_update mid-turn.
        XCTAssertTrue(events.contains { if case .commands = $0 { return true } else { return false } },
                      "expected available_commands_update from the mock")
    }

    /// The full agent-driven terminal loop against the REAL mock: with
    /// KAISOLA_MOCK_TERMINAL=1 the mock issues terminal/create → wait_for_exit →
    /// output → release; our client runs /bin/echo through AcpTerminalHost and
    /// the mock reports the exit back in a final tool_call_update. This proves
    /// the whole bridge, not just the host in isolation.
    func testAgentDrivenTerminalRoundTripAgainstRealMock() async throws {
        guard let node = Self.resolveNode(), let mock = Self.resolveMock() else {
            throw XCTSkip("node or the ACP mock agent is unavailable")
        }
        let client = AcpClient()
        let collector = IntegrationCollector()
        await client.setEventHandler { event in collector.append(event) }
        collector.onPermission = { request in
            let allow = request.options.first { $0.kind.contains("allow") } ?? request.options.first
            if let allow { Task { await client.resolvePermission(id: request.id, optionID: allow.id) } }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["KAISOLA_MOCK_TERMINAL"] = "1"
        do {
            _ = try await client.start(
                command: node,
                arguments: [mock],
                environment: environment,
                cwd: FileManager.default.temporaryDirectory.path,
                mcpServers: []
            )
        } catch {
            throw XCTSkip("could not spawn the mock agent: \(error.localizedDescription)")
        }
        try await client.prompt("run the terminal fixture")
        await client.stop()

        let events = collector.events
        // The mock's final update for term-tool-1 carries the exit report our
        // host produced: /bin/echo exits 0.
        let sawExitReport = events.contains { event in
            guard case let .toolCallUpdate(id, _, content, _, _) = event, id == "term-tool-1", let content else { return false }
            return content.contains { artifact in
                if case let .text(text) = artifact { return text.contains("terminal-exit:") && text.contains("\"exitCode\":0") }
                return false
            }
        }
        XCTAssertTrue(sawExitReport, "expected the mock to report our terminal host's exit status")
        // And the terminal reference itself streamed as live terminal content.
        let sawTerminalRef = events.contains { event in
            guard case let .toolCallUpdate(_, _, content, _, _) = event, let content else { return false }
            return content.contains { if case .terminal = $0 { return true } else { return false } }
        }
        XCTAssertTrue(sawTerminalRef, "expected a terminal content reference in the tool card")
    }

    private static func resolveNode() -> String? {
        for candidate in [
            ProcessInfo.processInfo.environment["HOME"].map { $0 + "/miniforge3/bin/node" },
            "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
        ].compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private static func resolveMock() -> String? {
        // Walk up from the test bundle to the repo root, then to the mock.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("tests/fixtures/acp/nativeAcpMock.cjs")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    private static let ownedTreeScript = #"""
    printf '%s\n' "$$" > "$KAISOLA_FIXTURE_PARENT_PID"
    /bin/sh -c 'trap "" HUP; exec /bin/sleep 60' \
      </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$KAISOLA_FIXTURE_CHILD_PID"
    while :; do /bin/sleep 1; done
    """#

    private static let termIgnoringTreeScript = #"""
    trap '' TERM
    printf '%s\n' "$$" > "$KAISOLA_FIXTURE_PARENT_PID"
    /bin/sh -c 'trap "" TERM; printf "%s\n" "$$" > "$KAISOLA_FIXTURE_CHILD_PID"; while :; do /bin/sleep 1; done' \
      </dev/null >/dev/null 2>&1 &
    while :; do /bin/sleep 1; done
    """#

    private static let exitLeavingChildScript = #"""
    printf '%s\n' "$$" > "$KAISOLA_FIXTURE_PARENT_PID"
    /bin/sh -c 'trap "" HUP TERM; printf "%s\n" "$$" > "$KAISOLA_FIXTURE_CHILD_PID"; while :; do /bin/sleep 1; done' \
      </dev/null >/dev/null 2>&1 &
    while [ ! -s "$KAISOLA_FIXTURE_CHILD_PID" ]; do /bin/sleep 0.01; done
    exit 23
    """#

    private static let unsupportedHandshakeScript = #"""
    trap '' TERM
    printf '%s\n' "$$" > "$KAISOLA_FIXTURE_PARENT_PID"
    /bin/sh -c 'trap "" TERM; printf "%s\n" "$$" > "$KAISOLA_FIXTURE_CHILD_PID"; while :; do /bin/sleep 1; done' \
      </dev/null >/dev/null 2>&1 &
    IFS= read -r _
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":2,"agentCapabilities":{}}}'
    while :; do /bin/sleep 1; done
    """#

    private static let handshakeThenCloseStdoutScript = #"""
    trap '' TERM
    printf '%s\n' "$$" > "$KAISOLA_FIXTURE_PARENT_PID"
    /bin/sh -c 'trap "" TERM; printf "%s\n" "$$" > "$KAISOLA_FIXTURE_CHILD_PID"; while :; do /bin/sleep 1; done' \
      </dev/null >/dev/null 2>&1 &
    IFS= read -r _
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}'
    IFS= read -r _
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"fixture-session"}}'
    exec 1>&-
    while :; do /bin/sleep 1; done
    """#

    private static let handshakeThenStopReadingStdinScript = #"""
    trap '' TERM
    printf '%s\n' "$$" > "$KAISOLA_FIXTURE_PARENT_PID"
    /bin/sh -c 'trap "" TERM; printf "%s\n" "$$" > "$KAISOLA_FIXTURE_CHILD_PID"; while :; do /bin/sleep 1; done' \
      </dev/null >/dev/null 2>&1 &
    IFS= read -r _
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}'
    IFS= read -r _
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"fixture-session"}}'
    while :; do /bin/sleep 1; done
    """#

    private func waitForQueuedFrames(_ count: Int, in queue: AcpStdinWriteQueue) async {
        for _ in 0..<1_000 {
            if await queue.snapshotForTesting().queuedFrameCount == count { return }
            await Task.yield()
        }
        XCTFail("stdin queue did not reach \(count) frames")
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition did not become true within \(timeout)")
    }

    private func assertFailed(
        _ task: Task<Void, any Error>,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("expected queued write to fail", file: file, line: line)
        } catch let AcpClientError.requestFailed(actual) {
            XCTAssertEqual(actual, message, file: file, line: line)
        } catch {
            XCTFail("unexpected write error: \(error)", file: file, line: line)
        }
    }
}

private final class LockedMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt64

    init(_ value: UInt64) { storage = value }

    var value: UInt64 {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private actor SuspendedStdinWriter {
    struct Call: Equatable, Sendable {
        let payload: String
        let deadline: UInt64
    }

    private(set) var calls: [Call] = []
    private var pending: [CheckedContinuation<Void, any Error>] = []
    private var callWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var callCount: Int { calls.count }

    func write(data: Data, deadline: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            calls.append(Call(payload: String(decoding: data, as: UTF8.self), deadline: deadline))
            pending.append(continuation)
            let ready = callWaiters.filter { calls.count >= $0.target }
            callWaiters.removeAll { calls.count >= $0.target }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func waitForCallCount(_ target: Int) async {
        if calls.count >= target { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((target, continuation))
        }
    }

    func succeedNext() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }

    func failNext(_ error: any Error) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(throwing: error)
    }
}

private struct OwnedProcessFixture: @unchecked Sendable {
    let directory: URL
    private let parentPIDFile: URL
    private let childPIDFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-acp-owned-\(UUID().uuidString)", isDirectory: true)
        parentPIDFile = directory.appendingPathComponent("adapter.pid")
        childPIDFile = directory.appendingPathComponent("app-server.pid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging([
            "KAISOLA_FIXTURE_PARENT_PID": parentPIDFile.path,
            "KAISOLA_FIXTURE_CHILD_PID": childPIDFile.path,
        ]) { _, fixture in fixture }
    }

    func waitForPIDs(timeout: Duration = .seconds(3)) async throws -> (pid_t, pid_t) {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let parent = pid(from: parentPIDFile), let child = pid(from: childPIDFile) {
                return (parent, child)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw OwnedProcessFixtureError.didNotPublishPIDs
    }

    func waitUntilStopped(_ pids: (pid_t, pid_t), timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !Self.isAlive(pids.0), !Self.isAlive(pids.1) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !Self.isAlive(pids.0) && !Self.isAlive(pids.1)
    }

    func forceCleanup() {
        let parent = pid(from: parentPIDFile)
        let child = pid(from: childPIDFile)
        let verifiedGroup = parent.flatMap { group in
            if Darwin.getpgid(group) == group || child.map({ Darwin.getpgid($0) == group }) == true {
                return group
            }
            return nil
        }
        if let group = verifiedGroup {
            _ = Darwin.kill(-group, SIGKILL)
        } else {
            // Pre-fix/failed-spawn fallback: never group-signal unless the
            // fixture parent is still the group leader we expect.
            for file in [parentPIDFile, childPIDFile] {
                if let process = pid(from: file), Self.isAlive(process) {
                    _ = Darwin.kill(process, SIGKILL)
                }
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func pid(from file: URL) -> pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 1 else { return nil }
        return value
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}

private enum OwnedProcessFixtureError: Error {
    case didNotPublishPIDs
}

/// A deliberately independent process group that models broker-owned durable
/// work without relying on Foundation.Process's run-loop-based waitUntilExit().
/// The test owns this fixture directly and always reaps it within a fixed bound.
private final class DetachedProcessFixture: @unchecked Sendable {
    let pid: pid_t

    init() throws {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setflags(&attributes, flags) == 0 else {
            throw POSIXError(.EIO)
        }

        let argv = [strdup("/bin/sleep"), strdup("30"), nil]
        let environment = [UnsafeMutablePointer<CChar>?](arrayLiteral: nil)
        defer { argv.dropLast().forEach { free($0) } }
        var spawnedPID: pid_t = 0
        let result = argv.withUnsafeBufferPointer { arguments in
            environment.withUnsafeBufferPointer { variables in
                posix_spawn(
                    &spawnedPID,
                    "/bin/sleep",
                    nil,
                    &attributes,
                    UnsafeMutablePointer(mutating: arguments.baseAddress),
                    UnsafeMutablePointer(mutating: variables.baseAddress)
                )
            }
        }
        guard result == 0, spawnedPID > 1 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        pid = spawnedPID
    }

    var isRunning: Bool {
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)
        if result == 0 { return Darwin.kill(pid, 0) == 0 || errno == EPERM }
        return false
    }

    @discardableResult
    func forceCleanup() -> Bool {
        if reapWithin(.zero) { return true }
        signalOwnedGroup(SIGTERM)
        if reapWithin(.milliseconds(300)) { return true }
        signalOwnedGroup(SIGKILL)
        return reapWithin(.milliseconds(500))
    }

    private func signalOwnedGroup(_ signal: Int32) {
        // The unreaped leader keeps this PID from being reused. Group-signal
        // only while it remains the independent group leader we spawned.
        if Darwin.getpgid(pid) == pid {
            _ = Darwin.kill(-pid, signal)
        } else if Darwin.kill(pid, 0) == 0 || errno == EPERM {
            _ = Darwin.kill(pid, signal)
        }
    }

    private func reapWithin(_ timeout: Duration) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { return true }
            if result < 0 && errno != EINTR { return false }
            if ContinuousClock.now >= deadline { return false }
            usleep(10_000)
        } while true
    }
}

private final class IntegrationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AcpEvent] = []
    var onPermission: (@Sendable (AcpPermissionRequest) -> Void)?

    func append(_ event: AcpEvent) {
        lock.lock(); storage.append(event); lock.unlock()
        if case let .permission(request) = event { onPermission?(request) }
    }

    var events: [AcpEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}
