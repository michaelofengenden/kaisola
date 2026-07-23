import Foundation
import KaisolaCore
import XCTest
@testable import KaisolaMacPreview

/// Drives the ACP client through a scripted in-memory transport so the wire
/// protocol (initialize → session/new → session/prompt → session/update
/// stream, plus a permission callback) is verified without spawning a process.
final class AcpClientTests: XCTestCase {
    func testHandshakeAndStreamedTurn() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { event in collector.append(event) }

        let info = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: []
        )
        XCTAssertEqual(info.sessionID, "sess-1")
        XCTAssertEqual(info.models.map(\.id), ["opus", "sonnet"])
        // Nested SessionModeState parses; current mode carried through.
        XCTAssertEqual(info.modes.map(\.id), ["default", "plan"])
        XCTAssertEqual(info.currentModeID, "default")
        // Config options (effort levels) parse with their choices.
        XCTAssertEqual(info.configOptions.map(\.id), ["reasoning_effort"])
        XCTAssertEqual(info.configOptions.first?.currentValue, "low")
        XCTAssertEqual(info.configOptions.first?.choices.map(\.value), ["low", "high"])

        // The scripted transport streams a thought, a plan, two message chunks,
        // a tool call + completion, and a usage update when it sees the prompt.
        try await client.prompt("hello")

        let events = collector.events
        XCTAssertTrue(events.contains { if case .turnItem(.thought) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .turnItem(.plan) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case let .turnItem(.toolCall(c)) = $0 { return c.id == "t1" } else { return false } })
        XCTAssertTrue(events.contains { if case let .toolCallUpdate(id, status, _, _) = $0 { return id == "t1" && status == .completed } else { return false } })
        XCTAssertTrue(events.contains { if case let .usage(u) = $0 { return u.used == 5000 } else { return false } })
        XCTAssertTrue(events.contains { if case .turnEnded = $0 { return true } else { return false } })
        // Slash commands stream in via available_commands_update.
        XCTAssertTrue(events.contains { event in
            if case let .commands(list) = event { return list.map(\.name) == ["compact", "review"] }
            return false
        })

        // set_config_option round-trips the adapter's normalized option set.
        await client.setConfigOption(id: "reasoning_effort", value: "high")
        XCTAssertTrue(collector.events.contains { event in
            if case let .configOptions(options) = event { return options.first?.currentValue == "high" }
            return false
        })
    }

    @MainActor
    func testConversationAccumulatesStreamingChunks() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        XCTAssertTrue(conversation.isConnected)

        conversation.send("hello")
        // Generous deadline: dispatch awaits a pre-turn git checkpoint before the
        // prompt is even sent, and a loaded CI runner can make that first git
        // spawn slow. A too-tight bound flakes on latency, not on a real stall.
        let deadline = Date().addingTimeInterval(15)
        while conversation.isRunning || !conversation.rows.contains(where: { if case .message = $0 { return true } else { return false } }) {
            if Date() > deadline { XCTFail("stream did not complete"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // The two "Hello" / " world" chunks accumulate into ONE message row.
        let messages = conversation.rows.compactMap { row -> String? in
            if case let .message(_, text) = row { return text } else { return nil }
        }
        XCTAssertEqual(messages, ["Hello world"])
        XCTAssertTrue(conversation.rows.contains { if case .user = $0 { return true } else { return false } })
        XCTAssertTrue(conversation.rows.contains { if case .tool = $0 { return true } else { return false } })
    }

    @MainActor
    func testFollowUpQueuedWhileRunningDispatchesAfterTurn() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let ruleFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-q-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("rules.json")
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client, ruleStore: PermissionRuleStore(fileURL: ruleFile)
        )
        defer { try? FileManager.default.removeItem(at: ruleFile.deletingLastPathComponent()) }
        await conversation.start()

        conversation.send("first")
        conversation.send("second")   // a turn is running → this queues
        XCTAssertTrue(conversation.isRunning)
        XCTAssertEqual(conversation.queued.map(\.text), ["second"])

        // Both turns complete: "second" dispatches when "first" ends, and the
        // queue drains.
        let deadline = Date().addingTimeInterval(5)
        while conversation.isRunning || !conversation.queued.isEmpty
            || conversation.rows.filter({ if case .user = $0 { return true } else { return false } }).count < 2 {
            if Date() > deadline { XCTFail("queued follow-up did not dispatch"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "second"])
        XCTAssertTrue(conversation.queued.isEmpty)
    }

    @MainActor
    func testSteerPromotesQueuedMessageToFront() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("second")
        conversation.send("third")
        XCTAssertEqual(conversation.queued.map(\.text), ["second", "third"])

        // Steering "third" promotes it ahead of "second" and interrupts the
        // current turn; the flush then dispatches in promoted order.
        let steerID = try XCTUnwrap(conversation.queued.last?.id)
        conversation.steerQueued(steerID)
        XCTAssertEqual(conversation.queued.first?.text, "third")

        let deadline = Date().addingTimeInterval(5)
        while conversation.isRunning || !conversation.queued.isEmpty {
            if Date() > deadline { XCTFail("steered queue did not drain"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "third", "second"])
    }

    @MainActor
    func testRemoveQueuedDropsPendingFollowUp() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("drop me")
        let id = try XCTUnwrap(conversation.queued.first?.id)
        conversation.removeQueued(id)
        XCTAssertTrue(conversation.queued.isEmpty)
    }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AcpEvent] = []
    func append(_ event: AcpEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [AcpEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// A transport that answers the ACP handshake and, on a prompt, streams a
/// scripted `session/update` sequence, a permission request, then resolves.
private actor ScriptedAcpTransport: AcpByteTransport {
    private var outbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var started = false

    func start(command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        started = true
    }

    func send(_ data: Data) async throws {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: trimmed(data)).objectValue else { return }
        let id = object["id"]
        switch object["method"]?.stringValue {
        case "initialize":
            reply(id: id, result: .object([
                "protocolVersion": .integer(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "mcpCapabilities": .object(["http": .bool(true)]),
                ]),
            ]))
        case "session/new":
            reply(id: id, result: .object([
                "sessionId": .string("sess-1"),
                // Flat models shape (exercises the fallback parse path).
                "models": .array([
                    .object(["modelId": .string("opus"), "name": .string("Opus")]),
                    .object(["modelId": .string("sonnet"), "name": .string("Sonnet")]),
                ]),
                // Nested modes shape (the ACP standard SessionModeState).
                "modes": .object([
                    "currentModeId": .string("default"),
                    "availableModes": .array([
                        .object(["id": .string("default"), "name": .string("Default")]),
                        .object(["id": .string("plan"), "name": .string("Plan")]),
                    ]),
                ]),
                "configOptions": .array([
                    .object([
                        "id": .string("reasoning_effort"),
                        "name": .string("Reasoning effort"),
                        "type": .string("select"),
                        "currentValue": .string("low"),
                        "options": .array([
                            .object(["value": .string("low"), "name": .string("Low")]),
                            .object(["value": .string("high"), "name": .string("High")]),
                        ]),
                    ]),
                ]),
            ]))
        case "session/set_config_option":
            reply(id: id, result: .object([
                "configOptions": .array([
                    .object([
                        "id": .string("reasoning_effort"),
                        "name": .string("Reasoning effort"),
                        "currentValue": .string("high"),
                        "options": .array([
                            .object(["value": .string("low"), "name": .string("Low")]),
                            .object(["value": .string("high"), "name": .string("High")]),
                        ]),
                    ]),
                ]),
            ]))
        case "session/prompt":
            streamTurn()
            reply(id: id, result: .object(["stopReason": .string("end_turn")]))
        default:
            if let id { reply(id: id, result: .null) }
        }
    }

    private func streamTurn() {
        notify(update: .object(["sessionUpdate": .string("agent_thought_chunk"), "content": .object(["type": .string("text"), "text": .string("thinking…")])]))
        notify(update: .object(["sessionUpdate": .string("plan"), "entries": .array([
            .object(["content": .string("step one"), "priority": .string("high"), "status": .string("pending")]),
        ])]))
        notify(update: .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Hello")])]))
        notify(update: .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string(" world")])]))
        notify(update: .object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("t1"), "title": .string("run echo"), "kind": .string("execute"), "status": .string("pending")]))
        notify(update: .object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("t1"), "status": .string("completed")]))
        notify(update: .object(["sessionUpdate": .string("available_commands_update"), "availableCommands": .array([
            .object(["name": .string("compact"), "description": .string("Compact the conversation")]),
            .object(["name": .string("review"), "description": .string("Review changes")]),
        ])]))
        notify(update: .object(["sessionUpdate": .string("usage_update"), "usedTokens": .integer(5000), "maxTokens": .integer(200000)]))
    }

    private func reply(id: JSONValue?, result: JSONValue) {
        guard let id else { return }
        enqueue(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func notify(update: JSONValue) {
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object(["sessionId": .string("sess-1"), "update": update]),
        ]))
    }

    private func enqueue(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbound.append(data)
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !outbound.isEmpty { return outbound.removeFirst() }
        return await withCheckedContinuation { continuation in waiter = continuation }
    }

    func terminate() async {
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { 0 }

    private func trimmed(_ data: Data) -> Data {
        data.last == 0x0A ? data.dropLast() : data
    }
}
