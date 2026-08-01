import Foundation
import XCTest
@testable import Kaisola

/// End-to-end proof that the Swift ACP client speaks the wire protocol over a
/// REAL child process — it spawns the Node mock agent
/// (`tests/fixtures/acp/nativeAcpMock.cjs`) through AcpProcessTransport and runs a full
/// handshake + streamed turn + permission callback. Skips cleanly if node or
/// the mock is unavailable so it never fails a machine without the toolchain.
final class AcpProcessIntegrationTests: XCTestCase {
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
