import Foundation
import KaisolaBrokerProtocol
import KaisolaCore

/// Streaming events the chat surface consumes, decoded from ACP
/// `session/update` notifications and the agent's callbacks.
enum AcpEvent: Sendable {
    case turnItem(AcpTurnItem)
    /// A `tool_call_update`. `status`/`content` are nil when the update didn't
    /// carry that field, so the merge leaves the existing value untouched.
    case toolCallUpdate(id: String, status: AcpToolCall.Status?, content: [AcpToolContent]?, title: String?)
    case usage(AcpUsage)
    case modelChanged(id: String)
    case permission(AcpPermissionRequest)
    case turnEnded
    case error(String)
    case exited(code: Int32)
}

/// A native ACP client: spawns the adapter, runs the JSON-RPC handshake
/// (initialize → session/new), sends prompts, and streams the agent's
/// `session/update` notifications plus permission callbacks. Newline-delimited
/// JSON-RPC 2.0 over stdio, mirroring electron/ipc/acp.cjs.
actor AcpClient {
    typealias EventHandler = @Sendable (AcpEvent) -> Void

    private let transport: any AcpByteTransport
    private var decoder = BrokerLineFrameDecoder(maximumFrameBytes: 64 * 1_024 * 1_024)
    private var eventHandler: EventHandler?
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextRequestID = 0
    private var readerTask: Task<Void, Never>?
    private var sessionID: String?
    private var capabilities = AcpAgentCapabilities()
    private var permissionCounter = 0
    private var permissionWaiters: [Int: CheckedContinuation<String, Never>] = [:]

    init(transport: any AcpByteTransport = AcpProcessTransport()) {
        self.transport = transport
    }

    func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    /// Spawn the adapter and complete the ACP handshake, returning the new
    /// session. `mcpServers` is the array produced by the MCP registry.
    func start(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        mcpServers: [JSONValue]
    ) async throws -> AcpSessionInfo {
        try await transport.start(command: command, arguments: arguments, environment: environment, cwd: cwd)
        readerTask = Task { await readLoop() }

        let initResult = try await request("initialize", params: .object([
            "protocolVersion": .integer(Int64(AcpWire.protocolVersion)),
            "clientCapabilities": .object([
                "fs": .object(["readTextFile": .bool(true), "writeTextFile": .bool(true)]),
                "terminal": .bool(true),
                "auth": .object(["terminal": .bool(true)]),
                "_meta": .object(["terminal-auth": .bool(true)]),
            ]),
        ]))
        capabilities = Self.parseCapabilities(initResult)

        let newResult = try await request("session/new", params: .object([
            "cwd": .string(cwd),
            "mcpServers": .array(sessionMcpServers(mcpServers)),
        ]))
        guard let object = newResult.objectValue, let sessionID = object["sessionId"]?.stringValue else {
            throw AcpClientError.malformedResponse
        }
        self.sessionID = sessionID
        let models = (object["models"]?.arrayValue ?? []).compactMap { value -> AcpSessionInfo.Model? in
            guard let m = value.objectValue,
                  let id = (m["modelId"] ?? m["id"])?.stringValue else { return nil }
            return AcpSessionInfo.Model(id: id, name: m["name"]?.stringValue ?? id)
        }
        return AcpSessionInfo(
            sessionID: sessionID,
            models: models,
            currentModelID: object["currentModelId"]?.stringValue
        )
    }

    /// Send a user prompt; the turn's updates arrive on the event handler and
    /// this returns when the turn fully ends.
    func prompt(_ text: String) async throws {
        guard let sessionID else { throw AcpClientError.notRunning }
        _ = try await request("session/prompt", params: .object([
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]), timeoutNanoseconds: 0)
        eventHandler?(.turnEnded)
    }

    func cancel() async {
        guard let sessionID else { return }
        notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
    }

    func setModel(_ modelID: String) async {
        guard let sessionID else { return }
        notify("session/set_model", params: .object([
            "sessionId": .string(sessionID),
            "modelId": .string(modelID),
        ]))
    }

    /// Resolve a pending permission request with the user's chosen option.
    func resolvePermission(id: Int, optionID: String) {
        permissionWaiters.removeValue(forKey: id)?.resume(returning: optionID)
    }

    func stop() async {
        readerTask?.cancel()
        readerTask = nil
        await transport.terminate()
        for waiter in permissionWaiters.values { waiter.resume(returning: "cancel") }
        permissionWaiters.removeAll()
        for continuation in pending.values { continuation.resume(throwing: AcpClientError.notRunning) }
        pending.removeAll()
    }

    // MARK: - MCP filtering (mirrors acp.cjs sessionMcpServers)

    private func sessionMcpServers(_ servers: [JSONValue]) -> [JSONValue] {
        servers.filter { entry in
            switch entry.objectValue?["type"]?.stringValue {
            case "http": capabilities.mcpHTTP
            case "sse": capabilities.mcpSSE
            default: true
            }
        }
    }

    // MARK: - JSON-RPC

    private func request(
        _ method: String,
        params: JSONValue,
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) async throws -> JSONValue {
        nextRequestID += 1
        let id = nextRequestID
        let frame = try encode(.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(Int64(id)),
            "method": .string(method),
            "params": params,
        ]))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if timeoutNanoseconds > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    failRequest(id, error: AcpClientError.requestFailed("\(method) timed out"))
                }
            }
            Task {
                do { try await transport.send(frame) }
                catch { failRequest(id, error: error) }
            }
        }
    }

    private func notify(_ method: String, params: JSONValue) {
        guard let frame = try? encode(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])) else { return }
        Task { try? await transport.send(frame) }
    }

    private func respond(id: JSONValue, result: JSONValue) {
        guard let frame = try? encode(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ])) else { return }
        Task { try? await transport.send(frame) }
    }

    private func encode(_ value: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    private func failRequest(_ id: Int, error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: - Read loop

    private func readLoop() async {
        do {
            while !Task.isCancelled {
                guard let data = try await transport.receive(maximumBytes: 256 * 1_024) else {
                    let code = await transport.exitCode() ?? 0
                    eventHandler?(.exited(code: code))
                    for continuation in pending.values { continuation.resume(throwing: AcpClientError.adapterExited(code: code)) }
                    pending.removeAll()
                    return
                }
                if data.isEmpty { continue }
                var active = decoder
                try active.consume(data) { frame in
                    if let value = try? JSONDecoder().decode(JSONValue.self, from: frame) {
                        handle(value)
                    }
                }
                decoder = active
            }
        } catch {
            if !Task.isCancelled { eventHandler?(.error(error.localizedDescription)) }
        }
    }

    private func handle(_ message: JSONValue) {
        guard let object = message.objectValue else { return }
        // Response to one of our requests.
        if let id = object["id"]?.intValue.flatMap(Int.init(exactly:)), object["method"] == nil {
            let continuation = pending.removeValue(forKey: id)
            if let error = object["error"]?.objectValue {
                continuation?.resume(throwing: AcpClientError.requestFailed(error["message"]?.stringValue ?? "request failed"))
            } else {
                continuation?.resume(returning: object["result"] ?? .null)
            }
            return
        }
        // A request or notification from the agent.
        guard let method = object["method"]?.stringValue else { return }
        switch method {
        case "session/update":
            if let update = object["params"]?.objectValue?["update"] {
                handleSessionUpdate(update)
            }
        case "session/request_permission":
            handlePermissionRequest(id: object["id"], params: object["params"])
        case "fs/read_text_file":
            // Read-only helper: return the file the agent asked for.
            handleReadTextFile(id: object["id"], params: object["params"])
        default:
            break
        }
    }

    private func handleSessionUpdate(_ update: JSONValue) {
        guard let object = update.objectValue, let kind = object["sessionUpdate"]?.stringValue else { return }
        switch kind {
        case "agent_message_chunk":
            if let text = object["content"]?.objectValue?["text"]?.stringValue {
                eventHandler?(.turnItem(.message(id: "live", text: text)))
            }
        case "agent_thought_chunk":
            if let text = object["content"]?.objectValue?["text"]?.stringValue {
                eventHandler?(.turnItem(.thought(id: "live", text: text)))
            }
        case "tool_call":
            if let call = Self.parseToolCall(object) {
                eventHandler?(.turnItem(.toolCall(call)))
            }
        case "tool_call_update":
            if let id = object["toolCallId"]?.stringValue {
                let status = object["status"]?.stringValue.flatMap(AcpToolCall.Status.init)
                // Only treat content as present when the key exists — an absent
                // key must not clear artifacts an earlier update already set.
                let content = object["content"] != nil ? Self.parseToolContent(object["content"]) : nil
                eventHandler?(.toolCallUpdate(id: id, status: status, content: content, title: object["title"]?.stringValue))
            }
        case "plan":
            let entries = (object["entries"]?.arrayValue ?? []).enumerated().compactMap { index, value -> AcpPlanEntry? in
                guard let e = value.objectValue, let content = e["content"]?.stringValue else { return nil }
                return AcpPlanEntry(
                    id: "\(index)",
                    content: content,
                    priority: e["priority"]?.stringValue ?? "medium",
                    status: e["status"]?.stringValue ?? "pending"
                )
            }
            eventHandler?(.turnItem(.plan(entries: entries)))
        case "usage_update":
            if let used = object["usedTokens"]?.intValue, let max = object["maxTokens"]?.intValue {
                eventHandler?(.usage(AcpUsage(used: Int(used), max: Int(max))))
            }
        case "current_model_update":
            if let id = object["currentModelId"]?.stringValue {
                eventHandler?(.modelChanged(id: id))
            }
        default:
            break
        }
    }

    private func handlePermissionRequest(id: JSONValue?, params: JSONValue?) {
        guard let id, let params = params?.objectValue, let sessionID else { return }
        permissionCounter += 1
        let localID = permissionCounter
        let title = params["toolCall"]?.objectValue?["title"]?.stringValue ?? "Permission requested"
        let options = (params["options"]?.arrayValue ?? []).compactMap { value -> AcpPermissionRequest.Option? in
            guard let o = value.objectValue, let optionID = o["optionId"]?.stringValue else { return nil }
            return AcpPermissionRequest.Option(
                id: optionID,
                name: o["name"]?.stringValue ?? optionID,
                kind: o["kind"]?.stringValue ?? "allow"
            )
        }
        eventHandler?(.permission(AcpPermissionRequest(id: localID, sessionID: sessionID, title: title, options: options)))
        Task {
            let chosen = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                permissionWaiters[localID] = continuation
            }
            respond(id: id, result: .object([
                "outcome": .object(["outcome": .string("selected"), "optionId": .string(chosen)]),
            ]))
        }
    }

    private func handleReadTextFile(id: JSONValue?, params: JSONValue?) {
        guard let id else { return }
        let path = params?.objectValue?["path"]?.stringValue
        let content = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        respond(id: id, result: .object(["content": .string(content)]))
    }

    // MARK: - Parsing helpers

    private static func parseCapabilities(_ result: JSONValue) -> AcpAgentCapabilities {
        var caps = AcpAgentCapabilities()
        guard let agent = result.objectValue?["agentCapabilities"]?.objectValue else { return caps }
        caps.loadSession = agent["loadSession"]?.boolValue ?? false
        caps.promptQueueing = agent["_meta"]?.objectValue?["claudeCode"]?.objectValue?["promptQueueing"]?.boolValue ?? false
        let mcp = agent["mcpCapabilities"]?.objectValue
        caps.mcpHTTP = mcp?["http"]?.boolValue ?? false
        caps.mcpSSE = mcp?["sse"]?.boolValue ?? false
        caps.promptImage = agent["promptCapabilities"]?.objectValue?["image"]?.boolValue ?? false
        return caps
    }

    private static func parseToolCall(_ object: [String: JSONValue]) -> AcpToolCall? {
        guard let id = object["toolCallId"]?.stringValue else { return nil }
        let locations = (object["locations"]?.arrayValue ?? []).compactMap {
            $0.objectValue?["path"]?.stringValue
        }
        return AcpToolCall(
            id: id,
            title: object["title"]?.stringValue ?? id,
            kind: object["kind"]?.stringValue ?? "other",
            status: object["status"]?.stringValue.flatMap(AcpToolCall.Status.init) ?? .pending,
            content: parseToolContent(object["content"]),
            locations: locations
        )
    }

    /// Parse an ACP `ToolCallContent[]` into our display artifacts. Recognizes
    /// `{type:"diff", path, oldText, newText}` and `{type:"content", content:{...}}`
    /// (text / resource blocks); a `{type:"terminal"}` reference degrades to a
    /// short text placeholder.
    static func parseToolContent(_ value: JSONValue?) -> [AcpToolContent] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { item -> AcpToolContent? in
            guard let object = item.objectValue else { return nil }
            switch object["type"]?.stringValue {
            case "diff":
                guard let path = object["path"]?.stringValue,
                      let newText = object["newText"]?.stringValue else { return nil }
                return .diff(path: path, oldText: object["oldText"]?.stringValue, newText: newText)
            case "content":
                let block = object["content"]?.objectValue
                if let text = block?["text"]?.stringValue { return .text(text) }
                if let resource = block?["resource"]?.objectValue?["text"]?.stringValue { return .text(resource) }
                if block?["type"]?.stringValue == "image" { return .text("[image]") }
                return nil
            case "terminal":
                let terminalID = object["terminalId"]?.stringValue ?? ""
                return .text("[terminal \(terminalID)]")
            default:
                // Bare content block (no wrapper type) with inline text.
                if let text = object["text"]?.stringValue { return .text(text) }
                return nil
            }
        }
    }
}
