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
    case modeChanged(id: String)
    case commands([AcpCommand])
    case configOptions([AcpConfigOption])
    case permission(AcpPermissionRequest)
    case turnEnded
    case error(String)
    case exited(code: Int32)
}

/// A file or image the user attached to a prompt, carried into the ACP prompt
/// as a real content block (never merely a path). `image` becomes an ACP
/// `image` block (base64 pixels + mime); `textFile` becomes an embedded
/// `resource` block when the adapter advertises embedded context, otherwise the
/// ACP-baseline `resource_link` form.
enum AcpAttachment: Equatable, Sendable {
    case image(data: Data, mimeType: String, name: String)
    case textFile(path: String, contents: String, name: String)

    /// The display filename used for chips and the prompt's "📎 …" suffix line.
    var name: String {
        switch self {
        case let .image(_, _, name): name
        case let .textFile(_, _, name): name
        }
    }
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
    private enum PermissionResolution: Sendable {
        case selected(String)
        case cancelled
    }
    private var permissionWaiters: [Int: CheckedContinuation<PermissionResolution, Never>] = [:]
    /// Host for agent-requested terminals (`terminal/create` …).
    private let terminalHost = AcpTerminalHost()
    /// The session workspace; fs/terminal callbacks are confined inside it.
    private var workspaceRoot: String?
    /// Sensitive globs the fs bridge refuses to read or write (set by the
    /// conversation from the user's guardrails; defaults applied otherwise).
    private var fsSensitiveGlobs = AcpPermissionRules.defaultSensitiveGlobs
    /// Mirrors Electron's MAX_TEXT_FILE_BYTES ACP fs limit.
    static let maxTextFileBytes = 8 * 1024 * 1024

    init(transport: any AcpByteTransport = AcpProcessTransport()) {
        self.transport = transport
    }

    func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    func configureFsGuard(sensitiveGlobs: [String]) {
        fsSensitiveGlobs = sensitiveGlobs
    }

    /// Live output snapshot for an agent-spawned terminal (tool-card rendering).
    func terminalSnapshot(_ id: String) async -> AcpTerminalHost.Snapshot? {
        await terminalHost.output(id)
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
        workspaceRoot = (cwd as NSString).standardizingPath
        do {
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
        // ACP requires the client to disconnect when the negotiated protocol is
        // not one it speaks. Silently continuing here can make a newer adapter
        // look connected while every later request is subtly malformed.
            guard initResult.objectValue?["protocolVersion"]?.intValue == Int64(AcpWire.protocolVersion) else {
                throw AcpClientError.unsupportedProtocol(
                    initResult.objectValue?["protocolVersion"]?.intValue.map(Int.init) ?? -1
                )
            }
            capabilities = Self.parseCapabilities(initResult)

            let sessionServers = sessionMcpServers(mcpServers)
            let newResult: JSONValue
            do {
                newResult = try await request("session/new", params: .object([
                    "cwd": .string(cwd),
                    "mcpServers": .array(sessionServers),
                ]))
            } catch let AcpClientError.requestFailed(message)
                where !sessionServers.isEmpty
                    && message.localizedCaseInsensitiveContains("invalid params") {
                // Match Electron: one malformed/rejected tool entry must degrade
                // to a working tool-less chat instead of killing the session.
                newResult = try await request("session/new", params: .object([
                    "cwd": .string(cwd),
                    "mcpServers": .array([]),
                ]))
            }
            guard let object = newResult.objectValue, let sessionID = object["sessionId"]?.stringValue else {
                throw AcpClientError.malformedResponse
            }
            self.sessionID = sessionID
        // Adapters vary: some return a flat `models: [...]` + top-level
        // `currentModelId`; the standard (and our mock) nests them under
        // `models: { availableModels, currentModelId }`. Handle both.
        let modelsNode = object["models"]?.objectValue
        let modelArray = modelsNode?["availableModels"]?.arrayValue ?? object["models"]?.arrayValue ?? []
        let models = modelArray.compactMap { value -> AcpSessionInfo.Model? in
            guard let m = value.objectValue,
                  let id = (m["modelId"] ?? m["id"])?.stringValue else { return nil }
            return AcpSessionInfo.Model(id: id, name: m["name"]?.stringValue ?? id)
        }
        let modesNode = object["modes"]?.objectValue
        let modeArray = modesNode?["availableModes"]?.arrayValue ?? object["modes"]?.arrayValue ?? []
        let modes = modeArray.compactMap { value -> AcpSessionInfo.Mode? in
            guard let m = value.objectValue,
                  let id = (m["id"] ?? m["modeId"])?.stringValue else { return nil }
            return AcpSessionInfo.Mode(id: id, name: m["name"]?.stringValue ?? id)
        }
            return AcpSessionInfo(
                sessionID: sessionID,
                models: models,
                currentModelID: modelsNode?["currentModelId"]?.stringValue ?? object["currentModelId"]?.stringValue,
                modes: modes,
                currentModeID: modesNode?["currentModeId"]?.stringValue ?? object["currentModeId"]?.stringValue,
                configOptions: Self.parseConfigOptions(object["configOptions"])
            )
        } catch {
            // A failed initialize/session-new must not leave a live adapter or a
            // reader task behind. This is especially important while users swap
            // agent profiles rapidly from the project menu.
            await stop()
            throw error
        }
    }

    /// Send a user prompt; the turn's updates arrive on the event handler and
    /// this returns when the turn fully ends. `attachments` ride as real ACP
    /// content blocks alongside the text (see `promptBlocks`). The no-attachment
    /// call stays source-compatible via the default.
    func prompt(_ text: String, attachments: [AcpAttachment] = []) async throws {
        guard let sessionID else { throw AcpClientError.notRunning }
        _ = try await request("session/prompt", params: .object([
            "sessionId": .string(sessionID),
            "prompt": .array(Self.promptBlocks(
                text: text,
                attachments: attachments,
                promptImageOk: capabilities.promptImage,
                promptEmbeddedContextOk: capabilities.promptEmbeddedContext
            )),
        ]), timeoutNanoseconds: 0)
        eventHandler?(.turnEnded)
    }

    /// Build the ACP `session/prompt` content-block array for a user turn: the
    /// text block first, then a real `image` block per image attachment (base64
    /// pixels + mime, mirroring electron/ipc/acp.cjs — gated on the agent having
    /// advertised `promptCapabilities.image`, exactly like Electron's
    /// `promptImageOk`), then either an embedded `resource` or baseline
    /// `resource_link` per text-file attachment according to negotiated prompt
    /// capabilities. Pure and static so wire encoding stays unit-testable.
    static func promptBlocks(
        text: String,
        attachments: [AcpAttachment],
        promptImageOk: Bool,
        promptEmbeddedContextOk: Bool = true
    ) -> [JSONValue] {
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        for attachment in attachments {
            switch attachment {
            case let .image(data, mimeType, _):
                // Image blocks only reach agents that take them; a text-only
                // agent still learns the filename from the prompt text (the
                // caller appends a "📎 <name>" line), never a rejected block.
                guard promptImageOk else { continue }
                blocks.append(.object([
                    "type": .string("image"),
                    "mimeType": .string(mimeType),
                    "data": .string(data.base64EncodedString()),
                ]))
            case let .textFile(path, contents, name):
                if promptEmbeddedContextOk {
                    blocks.append(.object([
                        "type": .string("resource"),
                        "resource": .object([
                            "uri": .string(fileURI(path)),
                            "mimeType": .string("text/plain"),
                            "text": .string(contents),
                        ]),
                    ]))
                } else {
                    // Resource links are ACP baseline prompt content. Agents that
                    // did not advertise embeddedContext receive a standards-safe
                    // link instead of an unsupported inline resource block.
                    blocks.append(.object([
                        "type": .string("resource_link"),
                        "name": .string(name),
                        "uri": .string(fileURI(path)),
                        "mimeType": .string("text/plain"),
                        "size": .integer(Int64(contents.utf8.count)),
                    ]))
                }
            }
        }
        return blocks
    }

    /// A `file://` URI for an attachment path, percent-encoding only bytes that
    /// aren't URL-path-legal (spaces etc.); an encoding-free absolute path
    /// becomes `file://` + path verbatim (e.g. `file:///tmp/notes.txt`).
    static func fileURI(_ path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file://" + encoded
    }

    func cancel() async {
        guard let sessionID else { return }
        notify("session/cancel", params: .object(["sessionId": .string(sessionID)]))
        cancelPermissionRequests()
    }

    func setModel(_ modelID: String) async {
        guard let sessionID else { return }
        do {
            _ = try await request("session/set_model", params: .object([
                "sessionId": .string(sessionID),
                "modelId": .string(modelID),
            ]))
        } catch {
            eventHandler?(.error(errorText(error)))
        }
    }

    func setMode(_ modeID: String) async {
        guard let sessionID else { return }
        do {
            _ = try await request("session/set_mode", params: .object([
                "sessionId": .string(sessionID),
                "modeId": .string(modeID),
            ]))
        } catch {
            eventHandler?(.error(errorText(error)))
        }
    }

    /// Set an adapter config option (e.g. reasoning effort). The response echoes
    /// the full option set, which is re-emitted so the UI reflects adapter-side
    /// normalization.
    func setConfigOption(id: String, value: String) async {
        guard let sessionID else { return }
        let result = try? await request("session/set_config_option", params: .object([
            "sessionId": .string(sessionID),
            "configId": .string(id),
            "value": .string(value),
        ]))
        if let options = result?.objectValue?["configOptions"] {
            eventHandler?(.configOptions(Self.parseConfigOptions(options)))
        }
    }

    /// Resolve a pending permission request with the user's chosen option.
    func resolvePermission(id: Int, optionID: String) {
        permissionWaiters.removeValue(forKey: id)?.resume(returning: .selected(optionID))
    }

    func stop() async {
        readerTask?.cancel()
        readerTask = nil
        await transport.terminate()
        await terminalHost.releaseAll()
        cancelPermissionRequests()
        for continuation in pending.values { continuation.resume(throwing: AcpClientError.notRunning) }
        pending.removeAll()
    }

    private func cancelPermissionRequests() {
        for waiter in permissionWaiters.values { waiter.resume(returning: .cancelled) }
        permissionWaiters.removeAll()
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

    private func respondError(id: JSONValue, code: Int, message: String) {
        guard let frame = try? encode(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .integer(Int64(code)), "message": .string(message)]),
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
            handleReadTextFile(id: object["id"], params: object["params"])
        case "fs/write_text_file":
            handleWriteTextFile(id: object["id"], params: object["params"])
        case "terminal/create", "terminal/output", "terminal/wait_for_exit", "terminal/kill", "terminal/release":
            handleTerminalMethod(method, id: object["id"], params: object["params"])
        default:
            // An unanswered request would hang the agent — fail it explicitly.
            if let id = object["id"] {
                respondError(id: id, code: -32601, message: "Method not handled: \(method)")
            }
        }
    }

    // MARK: - Agent-requested terminals

    private func handleTerminalMethod(_ method: String, id: JSONValue?, params: JSONValue?) {
        guard let id else { return }
        let object = params?.objectValue ?? [:]
        Task {
            do {
                switch method {
                case "terminal/create":
                    guard let command = object["command"]?.stringValue, !command.isEmpty else {
                        throw AcpClientError.requestFailed("terminal/create requires a command")
                    }
                    let args = (object["args"]?.arrayValue ?? []).compactMap(\.stringValue)
                    let env = Dictionary(
                        (object["env"]?.arrayValue ?? []).compactMap { pair -> (String, String)? in
                            guard let p = pair.objectValue, let name = p["name"]?.stringValue else { return nil }
                            return (name, p["value"]?.stringValue ?? "")
                        },
                        uniquingKeysWith: { _, last in last }
                    )
                    let cwd = try workspacePath(object["cwd"]?.stringValue, mustExist: true)
                    let limit = object["outputByteLimit"]?.intValue.map { Int($0) }
                    let terminalID = try await terminalHost.create(
                        command: command, args: args, env: env, cwd: cwd, outputByteLimit: limit
                    )
                    respond(id: id, result: .object(["terminalId": .string(terminalID)]))
                case "terminal/output":
                    guard let terminalID = object["terminalId"]?.stringValue,
                          let snapshot = await terminalHost.output(terminalID) else {
                        throw AcpClientError.requestFailed("unknown terminal")
                    }
                    var result: [String: JSONValue] = [
                        "output": .string(snapshot.output),
                        "truncated": .bool(snapshot.truncated),
                    ]
                    if let status = snapshot.exitStatus { result["exitStatus"] = Self.encode(status) }
                    respond(id: id, result: .object(result))
                case "terminal/wait_for_exit":
                    guard let terminalID = object["terminalId"]?.stringValue,
                          let status = await terminalHost.waitForExit(terminalID) else {
                        throw AcpClientError.requestFailed("unknown terminal")
                    }
                    respond(id: id, result: .object(["exitStatus": Self.encode(status)]))
                case "terminal/kill":
                    guard let terminalID = object["terminalId"]?.stringValue else {
                        throw AcpClientError.requestFailed("terminal/kill requires terminalId")
                    }
                    await terminalHost.kill(terminalID)
                    respond(id: id, result: .object([:]))
                case "terminal/release":
                    guard let terminalID = object["terminalId"]?.stringValue else {
                        throw AcpClientError.requestFailed("terminal/release requires terminalId")
                    }
                    await terminalHost.release(terminalID)
                    respond(id: id, result: .object([:]))
                default:
                    respondError(id: id, code: -32601, message: "Method not handled: \(method)")
                }
            } catch {
                respondError(id: id, code: -32000, message: errorText(error))
            }
        }
    }

    private static func encode(_ status: AcpTerminalHost.ExitStatus) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let code = status.exitCode { fields["exitCode"] = .integer(Int64(code)) }
        if let signal = status.signal { fields["signal"] = .string(signal) }
        return .object(fields)
    }

    /// Resolve a path inside the session workspace, refusing escapes — the
    /// same confinement Electron's `_workspacePath` applies. Symlinks are
    /// resolved on both sides before the containment check, so a link inside
    /// the workspace cannot smuggle reads/writes outside it.
    private func workspacePath(_ path: String?, mustExist: Bool = false) throws -> String {
        guard let root = workspaceRoot else { throw AcpClientError.notRunning }
        let raw = path?.isEmpty == false ? path! : root
        let resolved = raw.hasPrefix("/")
            ? (raw as NSString).standardizingPath
            : ((root as NSString).appendingPathComponent(raw) as NSString).standardizingPath
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard Self.isContained(resolved, in: root) || Self.isContained(resolved, in: realRoot) else {
            throw AcpClientError.requestFailed("Path escapes the session workspace")
        }
        // Resolve symlinks through the NEAREST EXISTING ancestor, so neither an
        // existing symlinked file nor a not-yet-created file under a symlinked
        // parent (write path) can escape the workspace.
        let real = Self.realPathViaNearestExistingAncestor(resolved)
        guard Self.isContained(real, in: realRoot) else {
            throw AcpClientError.requestFailed("Path escapes the session workspace")
        }
        if mustExist, !FileManager.default.fileExists(atPath: real) {
            throw AcpClientError.requestFailed("No such path: \(resolved)")
        }
        // Return the symlink-RESOLVED path: callers run the sensitive-glob
        // guard against it and then read/write it, so an in-workspace symlink
        // with an innocuous name (link.txt → ./.env) can't slip past the
        // guardrail on its lexical name and be read through the link.
        return real
    }

    /// Resolve symlinks in the deepest existing ancestor and re-append the
    /// not-yet-existing suffix, mirroring Electron's real-parent check.
    static func realPathViaNearestExistingAncestor(_ path: String) -> String {
        var existing = path
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            suffix.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var real = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        for component in suffix.reversed() {
            real = (real as NSString).appendingPathComponent(component)
        }
        return real
    }

    private static func isContained(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func errorText(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
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
            // ACP 1.x standardized these fields as `used` + `size`. Older
            // adapters (and Kaisola's original mock) emitted
            // `usedTokens` + `maxTokens`, so accept both without making the
            // modern wire path depend on a legacy alias. This mismatch was why
            // real SDK usage stayed blank while the mock looked healthy.
            let used = (object["used"] ?? object["usedTokens"])?.intValue
            let size = (object["size"] ?? object["maxTokens"])?.intValue
            if let used, let size {
                let cost = object["cost"]?.objectValue
                eventHandler?(.usage(AcpUsage(
                    used: Int(used),
                    max: Int(size),
                    costAmount: Self.finiteDouble(cost?["amount"]),
                    costCurrency: cost?["currency"]?.stringValue
                )))
            }
        case "current_model_update":
            if let id = object["currentModelId"]?.stringValue {
                eventHandler?(.modelChanged(id: id))
            }
        case "current_mode_update":
            if let id = (object["currentModeId"] ?? object["modeId"])?.stringValue {
                eventHandler?(.modeChanged(id: id))
            }
        case "available_commands_update":
            let commands = (object["availableCommands"]?.arrayValue ?? []).compactMap { value -> AcpCommand? in
                guard let c = value.objectValue, let name = c["name"]?.stringValue else { return nil }
                return AcpCommand(name: name, description: c["description"]?.stringValue ?? "")
            }
            eventHandler?(.commands(commands))
        case "config_option_update":
            if let options = object["configOptions"] {
                eventHandler?(.configOptions(Self.parseConfigOptions(options)))
            }
        default:
            break
        }
    }

    private func handlePermissionRequest(id: JSONValue?, params: JSONValue?) {
        guard let id, let params = params?.objectValue, let sessionID else { return }
        permissionCounter += 1
        let localID = permissionCounter
        let toolCall = params["toolCall"]?.objectValue
        let title = toolCall?["title"]?.stringValue ?? "Permission requested"
        let kind = toolCall?["kind"]?.stringValue ?? "other"
        let locationPaths = (toolCall?["locations"]?.arrayValue ?? []).compactMap {
            $0.objectValue?["path"]?.stringValue
        }
        let diffPaths = Self.parseToolContent(toolCall?["content"]).compactMap { artifact -> String? in
            if case let .diff(path, _, _) = artifact { return path } else { return nil }
        }
        let options = (params["options"]?.arrayValue ?? []).compactMap { value -> AcpPermissionRequest.Option? in
            guard let o = value.objectValue, let optionID = o["optionId"]?.stringValue else { return nil }
            return AcpPermissionRequest.Option(
                id: optionID,
                name: o["name"]?.stringValue ?? optionID,
                kind: o["kind"]?.stringValue ?? "allow"
            )
        }
        eventHandler?(.permission(AcpPermissionRequest(
            id: localID, sessionID: sessionID, title: title, options: options,
            kind: kind, paths: locationPaths + diffPaths
        )))
        Task {
            let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionResolution, Never>) in
                permissionWaiters[localID] = continuation
            }
            let outcome: JSONValue
            switch resolution {
            case let .selected(optionID):
                outcome = .object(["outcome": .string("selected"), "optionId": .string(optionID)])
            case .cancelled:
                outcome = .object(["outcome": .string("cancelled")])
            }
            respond(id: id, result: .object(["outcome": outcome]))
        }
    }

    private func handleReadTextFile(id: JSONValue?, params: JSONValue?) {
        guard let id else { return }
        do {
            let path = try workspacePath(params?.objectValue?["path"]?.stringValue, mustExist: true)
            guard !AcpPermissionRules.pathIsSensitive(globs: fsSensitiveGlobs, pathish: path) else {
                throw AcpClientError.requestFailed("Blocked: sensitive file (Kaisola guardrails)")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let size = attributes[.size] as? Int, size > Self.maxTextFileBytes {
                throw AcpClientError.requestFailed("Text file exceeds the \(Self.maxTextFileBytes)-byte ACP limit")
            }
            let content = try String(contentsOfFile: path, encoding: .utf8)
            respond(id: id, result: .object(["content": .string(content)]))
        } catch {
            respondError(id: id, code: -32000, message: errorText(error))
        }
    }

    private func handleWriteTextFile(id: JSONValue?, params: JSONValue?) {
        guard let id else { return }
        do {
            let content = params?.objectValue?["content"]?.stringValue ?? ""
            guard content.utf8.count <= Self.maxTextFileBytes else {
                throw AcpClientError.requestFailed("Text file exceeds the \(Self.maxTextFileBytes)-byte ACP limit")
            }
            let path = try workspacePath(params?.objectValue?["path"]?.stringValue)
            guard !AcpPermissionRules.pathIsSensitive(globs: fsSensitiveGlobs, pathish: path) else {
                throw AcpClientError.requestFailed("Blocked: sensitive file (Kaisola guardrails)")
            }
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Re-check after mkdir so a concurrently swapped parent symlink
            // cannot turn the write into an escape (mirrors acp.cjs).
            let checked = try workspacePath(path)
            try content.write(toFile: checked, atomically: true, encoding: .utf8)
            respond(id: id, result: .object([:]))
        } catch {
            respondError(id: id, code: -32000, message: errorText(error))
        }
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
        let prompt = agent["promptCapabilities"]?.objectValue
        caps.promptImage = prompt?["image"]?.boolValue ?? false
        caps.promptEmbeddedContext = prompt?["embeddedContext"]?.boolValue ?? false
        return caps
    }

    /// JSON numbers decode as either `.integer` or `.number`; ACP cost accepts
    /// both. Keep non-finite values out of UI/accounting state.
    private static func finiteDouble(_ value: JSONValue?) -> Double? {
        let number: Double?
        switch value {
        case let .integer(integer): number = Double(integer)
        case let .number(double): number = double
        default: number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
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

    /// Parse the adapter's `configOptions` array (select-type options only —
    /// the only kind current adapters emit).
    static func parseConfigOptions(_ value: JSONValue?) -> [AcpConfigOption] {
        (value?.arrayValue ?? []).compactMap { item -> AcpConfigOption? in
            guard let o = item.objectValue, let id = o["id"]?.stringValue else { return nil }
            let choices = (o["options"]?.arrayValue ?? []).compactMap { choice -> AcpConfigOption.Choice? in
                guard let c = choice.objectValue, let value = c["value"]?.stringValue else { return nil }
                return AcpConfigOption.Choice(value: value, name: c["name"]?.stringValue ?? value)
            }
            return AcpConfigOption(
                id: id,
                name: o["name"]?.stringValue ?? id,
                currentValue: o["currentValue"]?.stringValue,
                choices: choices
            )
        }
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
                guard let terminalID = object["terminalId"]?.stringValue else { return nil }
                return .terminal(id: terminalID)
            default:
                // Bare content block (no wrapper type) with inline text.
                if let text = object["text"]?.stringValue { return .text(text) }
                return nil
            }
        }
    }
}
