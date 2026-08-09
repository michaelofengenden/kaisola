import Darwin
import Foundation
import KaisolaBrokerProtocol
import KaisolaCore

/// Streaming events the chat surface consumes, decoded from ACP
/// `session/update` notifications and the agent's callbacks.
enum AcpEvent: Sendable {
    case turnItem(AcpTurnItem)
    /// A `tool_call_update`. Optional collections are nil when the update
    /// didn't carry that field, so the merge leaves existing disclosure intact.
    case toolCallUpdate(
        id: String,
        status: AcpToolCall.Status?,
        content: [AcpToolContent]?,
        locations: [String]?,
        title: String?
    )
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
enum AcpAttachment: Codable, Equatable, Sendable {
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
/// JSON-RPC 2.0 over stdio for native ACP adapters.
actor AcpClient {
    typealias EventHandler = @Sendable (AcpEvent) -> Void

    private let transport: any AcpByteTransport
    private var decoder = BrokerLineFrameDecoder(maximumFrameBytes: 64 * 1_024 * 1_024)
    private var eventHandler: EventHandler?
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextRequestID = 0
    private var readerTask: Task<Void, Never>?
    /// Invalidates callbacks that were awaiting a user decision when an adapter
    /// exits or a client is stopped/restarted. Without this guard, a resumed
    /// permission task could write its JSON-RPC response into the next adapter.
    private var connectionGeneration: UInt64 = 0
    private var sessionID: String?
    private var capabilities = AcpAgentCapabilities()
    private var permissionCounter = 0
    private enum PermissionResolution: Sendable {
        case selected(String)
        case cancelled
    }
    private var permissionWaiters: [Int: CheckedContinuation<PermissionResolution, Never>] = [:]
    /// A permission event is delivered synchronously, so a fast policy/UI can
    /// answer before the continuation task gets its first actor turn. Track the
    /// request first and retain that early resolution instead of dropping it.
    private var activePermissionIDs: Set<Int> = []
    private var earlyPermissionResolutions: [Int: PermissionResolution] = [:]
    /// Permission requests are partial ToolCallUpdates. Retain a bounded set of
    /// prior review fields so a later ask can disclose paths/raw input already
    /// streamed for the same tool-call id.
    private var toolCallReviewContexts: [String: AcpToolCallReviewContext] = [:]
    private var toolCallReviewOrder: [String] = []
    private static let maxToolCallReviewContexts = 512
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
        mcpServers: [JSONValue],
        resumeSessionID: String? = nil
    ) async throws -> AcpSessionInfo {
        connectionGeneration &+= 1
        decoder = BrokerLineFrameDecoder(maximumFrameBytes: 64 * 1_024 * 1_024)
        sessionID = nil
        cancelPermissionRequests()
        toolCallReviewContexts.removeAll(keepingCapacity: true)
        toolCallReviewOrder.removeAll(keepingCapacity: true)
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
            func openSession(_ method: String, priorID: String? = nil) async throws -> JSONValue {
                func parameters(servers: [JSONValue]) -> JSONValue {
                    var values: [String: JSONValue] = [
                        "cwd": .string(cwd),
                        "mcpServers": .array(servers),
                    ]
                    if let priorID { values["sessionId"] = .string(priorID) }
                    return .object(values)
                }
                do {
                    return try await request(method, params: parameters(servers: sessionServers))
                } catch let AcpClientError.requestFailed(message)
                    where !sessionServers.isEmpty
                        && message.localizedCaseInsensitiveContains("invalid params") {
                    // Match Electron: one malformed/rejected tool entry must
                    // degrade to a working tool-less chat, including resume.
                    return try await request(method, params: parameters(servers: []))
                }
            }

            var sessionResult: JSONValue?
            var resumedID: String?
            if let resumeSessionID {
                if capabilities.resumeSession,
                   let result = try? await openSession("session/resume", priorID: resumeSessionID) {
                    sessionResult = result
                    resumedID = resumeSessionID
                }
                if sessionResult == nil,
                   capabilities.loadSession,
                   let result = try? await openSession("session/load", priorID: resumeSessionID) {
                    sessionResult = result
                    resumedID = resumeSessionID
                }
            }
            if sessionResult == nil {
                sessionResult = try await openSession("session/new")
            }
            guard let object = sessionResult?.objectValue,
                  let sessionID = object["sessionId"]?.stringValue ?? resumedID else {
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
                configOptions: Self.parseConfigOptions(object["configOptions"]),
                supportsSteering: capabilities.steering
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
    /// pixels + mime, gated on the agent having
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

    /// Inject one message into the turn that is already running, via the
    /// `_session/steering` extension both adapters advertise. Unlike `prompt`,
    /// this returns as soon as the adapter has decided what it did with the
    /// message — the injected message's own output streams through the RUNNING
    /// turn's `session/update` notifications, not through this response.
    ///
    /// Never throws: every failure — no session, a JSON-RPC error, an outcome
    /// this client does not recognize — comes back as `.rejected`, because the
    /// caller's only safe response to "we do not know what happened" is to keep
    /// the message queued.
    func steer(_ text: String) async -> AcpSteerOutcome {
        guard let sessionID else { return .rejected(AcpClientError.notRunning.localizedDescription) }
        do {
            let result = try await request(
                AcpSteering.method,
                params: AcpSteering.requestParams(sessionID: sessionID, text: text)
            )
            return AcpSteering.parseOutcome(result)
        } catch {
            return .rejected(errorText(error))
        }
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
        guard activePermissionIDs.contains(id) else { return }
        let resolution = PermissionResolution.selected(optionID)
        if let waiter = permissionWaiters.removeValue(forKey: id) {
            waiter.resume(returning: resolution)
        } else {
            earlyPermissionResolutions[id] = resolution
        }
    }

    /// Decline an ask without selecting an adapter-owned `reject_always`
    /// option. ACP's cancelled outcome denies the pending operation without
    /// granting the adapter an undisclosed persistent decision.
    func cancelPermission(id: Int) {
        guard activePermissionIDs.contains(id) else { return }
        let resolution = PermissionResolution.cancelled
        if let waiter = permissionWaiters.removeValue(forKey: id) {
            waiter.resume(returning: resolution)
        } else {
            earlyPermissionResolutions[id] = resolution
        }
    }

    func stop() async {
        connectionGeneration &+= 1
        let reader = readerTask
        readerTask = nil
        reader?.cancel()
        cancelPermissionRequests()
        await transport.terminate()
        await reader?.value
        await terminalHost.releaseAll()
        for continuation in pending.values { continuation.resume(throwing: AcpClientError.notRunning) }
        pending.removeAll()
        sessionID = nil
        workspaceRoot = nil
        capabilities = AcpAgentCapabilities()
        toolCallReviewContexts.removeAll(keepingCapacity: true)
        toolCallReviewOrder.removeAll(keepingCapacity: true)
    }

    private func cancelPermissionRequests() {
        let ids = activePermissionIDs
        activePermissionIDs.removeAll()
        for id in ids {
            earlyPermissionResolutions.removeValue(forKey: id)
            if let waiter = permissionWaiters.removeValue(forKey: id) {
                waiter.resume(returning: .cancelled)
            }
        }
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
                    connectionGeneration &+= 1
                    cancelPermissionRequests()
                    sessionID = nil
                    workspaceRoot = nil
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
            guard !Task.isCancelled else { return }
            connectionGeneration &+= 1
            cancelPermissionRequests()
            sessionID = nil
            workspaceRoot = nil
            for continuation in pending.values { continuation.resume(throwing: error) }
            pending.removeAll()
            eventHandler?(.error(error.localizedDescription))
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
    /// the workspace cannot smuggle reads or terminal working directories
    /// outside it. Agent writes use `AcpWorkspaceFileWriter` instead because a
    /// resolved path cannot distinguish an ordinary file from a symlink leaf.
    private func workspacePath(_ path: String?, mustExist: Bool = false) throws -> String {
        guard let root = workspaceRoot else { throw AcpClientError.notRunning }
        let raw = path?.isEmpty == false ? path! : root
        let resolved = raw.hasPrefix("/")
            ? (raw as NSString).standardizingPath
            : ((root as NSString).appendingPathComponent(raw) as NSString).standardizingPath
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard Self.isContained(resolved, in: root) || Self.isContained(resolved, in: realRoot) else {
            throw AcpClientError.requestFailed("Path escapes the session project")
        }
        // Resolve symlinks through the NEAREST EXISTING ancestor, so neither an
        // existing symlinked file nor a not-yet-created file under a symlinked
        // parent (write path) can escape the workspace.
        let real = Self.realPathViaNearestExistingAncestor(resolved)
        guard Self.isContained(real, in: realRoot) else {
            throw AcpClientError.requestFailed("Path escapes the session project")
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
        case "user_message_chunk":
            // The user's OWN prompts. Adapters emit these when they replay a
            // loaded session's history, which is how a resumed chat gets back
            // the questions that produced the replies beside them; Claude also
            // echoes any prompt that carried more than a single text block.
            // Dropping them (the old `default: break`) is what made a resumed
            // conversation read as the agent talking to itself.
            if let text = object["content"]?.objectValue?["text"]?.stringValue {
                eventHandler?(.turnItem(.userMessage(
                    id: object["messageId"]?.stringValue,
                    text: text
                )))
            }
        case "tool_call":
            recordToolCallReviewContext(object)
            if let call = Self.parseToolCall(object) {
                eventHandler?(.turnItem(.toolCall(call)))
            }
        case "tool_call_update":
            recordToolCallReviewContext(object)
            if let id = object["toolCallId"]?.stringValue {
                let status = object["status"]?.stringValue.flatMap(AcpToolCall.Status.init)
                // Only treat content as present when the key exists — an absent
                // key must not clear artifacts an earlier update already set.
                let content = object["content"] != nil ? Self.parseToolContent(object["content"]) : nil
                let locations = object["locations"] != nil
                    ? Self.locationPaths(object["locations"])
                    : nil
                eventHandler?(.toolCallUpdate(
                    id: id,
                    status: status,
                    content: content,
                    locations: locations,
                    title: object["title"]?.stringValue
                ))
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
        guard let id, let sessionID else { return }
        permissionCounter += 1
        let localID = permissionCounter
        let toolCallID = params?.objectValue?["toolCall"]?.objectValue?["toolCallId"]?.stringValue
        let priorContext = toolCallID.flatMap { toolCallReviewContexts[$0] }
        guard let request = Self.parsePermissionRequest(
            localID: localID,
            sessionID: sessionID,
            params: params,
            priorContext: priorContext
        ) else { return }
        activePermissionIDs.insert(localID)
        let generation = connectionGeneration
        eventHandler?(.permission(request))
        Task {
            let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionResolution, Never>) in
                if let early = earlyPermissionResolutions.removeValue(forKey: localID) {
                    continuation.resume(returning: early)
                } else if activePermissionIDs.contains(localID) {
                    permissionWaiters[localID] = continuation
                } else {
                    continuation.resume(returning: .cancelled)
                }
            }
            activePermissionIDs.remove(localID)
            earlyPermissionResolutions.removeValue(forKey: localID)
            guard connectionGeneration == generation else { return }
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

    /// Decode the complete permission review payload, including ACP v1's
    /// arbitrary `rawInput`. Kept pure for wire-contract tests.
    static func parsePermissionRequest(
        localID: Int,
        sessionID: String,
        params value: JSONValue?,
        priorContext: AcpToolCallReviewContext? = nil
    ) -> AcpPermissionRequest? {
        guard let params = value?.objectValue else { return nil }
        let toolCall = params["toolCall"]?.objectValue
        let title = toolCall?["title"] != nil
            ? (toolCall?["title"]?.stringValue ?? "Permission requested")
            : (priorContext?.title ?? "Permission requested")
        let kind = toolCall?["kind"] != nil
            ? (toolCall?["kind"]?.stringValue ?? "other")
            : (priorContext?.kind ?? "other")
        let rawInput: JSONValue?
        if toolCall?["rawInput"] != nil {
            if let value = toolCall?["rawInput"], value != .null {
                rawInput = value
            } else {
                rawInput = nil
            }
        } else {
            rawInput = priorContext?.rawInput
        }
        let locationPaths = toolCall?["locations"] != nil
            ? Self.locationPaths(toolCall?["locations"])
            : (priorContext?.locationPaths ?? [])
        let diffPaths = toolCall?["content"] != nil
            ? Self.diffPaths(toolCall?["content"])
            : (priorContext?.diffPaths ?? [])
        let options = (params["options"]?.arrayValue ?? []).compactMap { value -> AcpPermissionRequest.Option? in
            guard let o = value.objectValue, let optionID = o["optionId"]?.stringValue else { return nil }
            return AcpPermissionRequest.Option(
                id: optionID,
                name: o["name"]?.stringValue ?? optionID,
                kind: o["kind"]?.stringValue ?? "other"
            )
        }
        var seenPaths = Set<String>()
        let paths = (locationPaths + diffPaths).filter {
            !$0.isEmpty && seenPaths.insert($0).inserted
        }
        return AcpPermissionRequest(
            id: localID, sessionID: sessionID, title: title, options: options,
            rawInput: rawInput, kind: kind, paths: paths
        )
    }

    private func recordToolCallReviewContext(_ update: [String: JSONValue]) {
        guard let id = update["toolCallId"]?.stringValue else { return }
        let isNew = toolCallReviewContexts[id] == nil
        toolCallReviewContexts[id] = Self.mergeToolCallReviewContext(
            toolCallReviewContexts[id],
            update: update
        )
        if isNew {
            toolCallReviewOrder.append(id)
            if toolCallReviewOrder.count > Self.maxToolCallReviewContexts {
                let overflow = toolCallReviewOrder.count - Self.maxToolCallReviewContexts
                let expired = toolCallReviewOrder.prefix(overflow)
                for expiredID in expired { toolCallReviewContexts.removeValue(forKey: expiredID) }
                toolCallReviewOrder.removeFirst(overflow)
            }
        }
    }

    /// Merge ACP's replace-when-present ToolCallUpdate semantics. Pure so the
    /// partial-request correlation contract can be tested without a process.
    static func mergeToolCallReviewContext(
        _ prior: AcpToolCallReviewContext?,
        update: [String: JSONValue]
    ) -> AcpToolCallReviewContext {
        var context = prior ?? AcpToolCallReviewContext()
        if update["title"] != nil { context.title = update["title"]?.stringValue }
        if update["kind"] != nil { context.kind = update["kind"]?.stringValue }
        if update["rawInput"] != nil {
            if let value = update["rawInput"], value != .null {
                context.rawInput = value
            } else {
                context.rawInput = nil
            }
        }
        if update["locations"] != nil {
            context.locationPaths = locationPaths(update["locations"])
        }
        if update["content"] != nil {
            context.diffPaths = diffPaths(update["content"])
        }
        return context
    }

    private static func locationPaths(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { $0.objectValue?["path"]?.stringValue }
    }

    private static func diffPaths(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).compactMap { item in
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "diff" else { return nil }
            return object["path"]?.stringValue
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
            guard let workspaceRoot else { throw AcpClientError.notRunning }
            let path = try AcpWorkspaceFileWriter.normalizedTargetPath(
                params?.objectValue?["path"]?.stringValue,
                workspaceRoot: workspaceRoot
            )
            guard !AcpPermissionRules.pathIsSensitive(globs: fsSensitiveGlobs, pathish: path) else {
                throw AcpClientError.requestFailed("Blocked: sensitive file (Kaisola guardrails)")
            }
            try AcpWorkspaceFileWriter.write(
                Data(content.utf8),
                to: path,
                workspaceRoot: workspaceRoot
            )
            respond(id: id, result: .object([:]))
        } catch {
            respondError(id: id, code: -32000, message: errorText(error))
        }
    }

    // MARK: - Parsing helpers

    static func parseCapabilities(_ result: JSONValue) -> AcpAgentCapabilities {
        var caps = AcpAgentCapabilities()
        // The steering extension is advertised on the response's OWN `_meta`,
        // beside `agentCapabilities` rather than inside it, so it is read before
        // (and independently of) the capability block — an adapter that offers
        // steering without an `agentCapabilities` object still counts.
        caps.steering = result.objectValue?["_meta"]?.objectValue?["steering"]?
            .objectValue?["supported"]?.boolValue ?? false
        guard let agent = result.objectValue?["agentCapabilities"]?.objectValue else { return caps }
        caps.loadSession = agent["loadSession"]?.boolValue ?? false
        let session = agent["sessionCapabilities"]?.objectValue
        caps.resumeSession = session?["resume"]?.boolValue ?? false
        caps.closeSession = session?["close"]?.boolValue ?? false
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
                category: o["category"]?.stringValue,
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

/// The Kaisola-owned mutation boundary for ACP `fs/write_text_file` requests.
/// Paths are reviewed and then walked from an open workspace descriptor one
/// component at a time. Final replacement is relative to the verified parent,
/// never a path that can be redirected through a symbolic link after review.
enum AcpWorkspaceFileWriter {
    typealias BeforeMutation = () throws -> Void

    enum ExtendedAttributeDisposition: Equatable {
        case preserve
        case remove
    }

    private struct ExtendedAttribute {
        let name: String
        let value: Data
    }

    private final class AccessControlList {
        let rawValue: acl_t

        init(_ rawValue: acl_t) {
            self.rawValue = rawValue
        }

        deinit {
            _ = acl_free(UnsafeMutableRawPointer(rawValue))
        }
    }

    private enum AccessControlListSnapshot {
        case unsupported
        case absent
        case value(AccessControlList)
    }

    private struct MetadataSnapshot {
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let extendedAttributes: [ExtendedAttribute]
        let accessControlList: AccessControlListSnapshot
    }

    private static let maximumExtendedAttributeCount = 128
    private static let maximumExtendedAttributeNameBytes = 64 * 1_024
    private static let maximumExtendedAttributeValueBytes = 1 * 1_024 * 1_024
    private static let maximumExtendedAttributeTotalBytes = 4 * 1_024 * 1_024

    private final class Descriptor {
        private(set) var rawValue: Int32

        init(_ rawValue: Int32) {
            self.rawValue = rawValue
        }

        deinit {
            if rawValue >= 0 { _ = Darwin.close(rawValue) }
        }
    }

    /// Resolve only lexical `.`/`..` components. Deliberately do not resolve
    /// symlinks: doing so would erase the distinction this boundary must reject.
    static func normalizedTargetPath(_ requestedPath: String?, workspaceRoot: String) throws -> String {
        let root = (workspaceRoot as NSString).standardizingPath
        guard root.hasPrefix("/") else {
            throw rejected("the session project is unavailable")
        }
        let raw = requestedPath?.isEmpty == false ? requestedPath! : root
        let target = raw.hasPrefix("/")
            ? (raw as NSString).standardizingPath
            : ((root as NSString).appendingPathComponent(raw) as NSString).standardizingPath
        guard target != root,
              target.hasPrefix(root + "/"),
              !target.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw rejected("the target escapes the session project")
        }
        return target
    }

    static func write(
        _ data: Data,
        to requestedPath: String,
        workspaceRoot: String,
        beforeMutation: BeforeMutation? = nil,
        beforeReplacementCommit: BeforeMutation? = nil
    ) throws {
        let rootPath = (workspaceRoot as NSString).standardizingPath
        let targetPath = try normalizedTargetPath(requestedPath, workspaceRoot: rootPath)
        let suffix = targetPath.dropFirst(rootPath.count + 1)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let leaf = components.last, !leaf.isEmpty else {
            throw rejected("the target is not a regular file")
        }

        let root = try openRoot(rootPath)
        let parentComponents = Array(components.dropLast())
        let parent = try openParent(
            components: parentComponents,
            root: root,
            createMissingDirectories: true
        )
        let reviewedParent = try descriptorMetadata(parent)
        let reviewedEntry = try entryMetadata(named: leaf, in: parent)
        var reviewedMetadata: MetadataSnapshot?
        if let reviewedEntry {
            guard !isSymbolicLink(reviewedEntry) else {
                throw rejected("symbolic-link targets are not writable")
            }
            guard isRegularFile(reviewedEntry) else {
                throw rejected("the target is not a regular file")
            }
            let reviewedDescriptor = try openReviewedEntry(
                named: leaf,
                in: parent,
                expected: reviewedEntry
            )
            reviewedMetadata = try captureMetadata(
                from: reviewedDescriptor,
                expected: reviewedEntry
            )
        }

        // Deterministic test seam: production has no callback. Re-open the
        // lexical parent afterwards and require it plus the leaf identity to
        // remain exactly what was reviewed before creating any temporary file.
        try beforeMutation?()
        let currentParent = try openParent(
            components: parentComponents,
            root: root,
            createMissingDirectories: false
        )
        guard sameIdentity(reviewedParent, try descriptorMetadata(currentParent)) else {
            throw rejected("the target changed after review")
        }
        try validateCurrentEntry(
            try entryMetadata(named: leaf, in: currentParent),
            matches: reviewedEntry
        )

        let mode = reviewedMetadata?.mode
            ?? mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        let temporary = try createTemporaryFile(in: parent, mode: mode)
        do {
            try writeAll(data, to: temporary.descriptor.rawValue)
            if let reviewedMetadata {
                try applyMetadata(reviewedMetadata, to: temporary.descriptor)
            }
            guard Darwin.fsync(temporary.descriptor.rawValue) == 0 else {
                throw rejected("the target metadata could not be preserved")
            }
            let installationParent = try openParent(
                components: parentComponents,
                root: root,
                createMissingDirectories: false
            )
            guard sameIdentity(
                reviewedParent,
                try descriptorMetadata(installationParent)
            ) else {
                throw rejected("the target changed after review")
            }
            try validateCurrentEntry(
                try entryMetadata(named: leaf, in: installationParent),
                matches: reviewedEntry
            )
            if let reviewedEntry {
                try replaceExisting(
                    leaf: leaf,
                    reviewedEntry: reviewedEntry,
                    temporaryLeaf: temporary.leaf,
                    parent: parent,
                    beforeCommit: beforeReplacementCommit
                )
            } else {
                try installNew(
                    leaf: leaf,
                    temporaryLeaf: temporary.leaf,
                    parent: parent
                )
            }
        } catch {
            unlinkIfOwned(
                named: temporary.leaf,
                descriptor: temporary.descriptor,
                in: parent
            )
            throw error
        }
    }

    /// Preserve ordinary metadata but deliberately discard attributes whose
    /// bytes describe the old file contents or duplicate policy restored via
    /// the ACL API. Quarantine, Finder tags, and application-defined metadata
    /// remain attached to the replacement.
    static func extendedAttributeDisposition(for name: String) -> ExtendedAttributeDisposition {
        if name == XATTR_RESOURCEFORK_NAME
            || name == "com.apple.decmpfs"
            || name == "com.apple.system.Security"
            || name.hasPrefix("com.apple.cs.") {
            return .remove
        }
        return .preserve
    }

    private static func openReviewedEntry(
        named leaf: String,
        in parent: Descriptor,
        expected: stat
    ) throws -> Descriptor {
        let raw = leaf.withCString { name in
            Darwin.openat(parent.rawValue, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard raw >= 0 else {
            if errno == ELOOP { throw rejected("symbolic-link targets are not writable") }
            throw rejected("the target metadata could not be read")
        }
        let descriptor = Descriptor(raw)
        let actual = try descriptorMetadata(descriptor)
        guard isRegularFile(actual), sameIdentity(expected, actual) else {
            throw rejected("the target changed after review")
        }
        return descriptor
    }

    private static func captureMetadata(
        from descriptor: Descriptor,
        expected: stat
    ) throws -> MetadataSnapshot {
        let actual = try descriptorMetadata(descriptor)
        guard isRegularFile(actual), sameIdentity(expected, actual) else {
            throw rejected("the target changed after review")
        }
        return MetadataSnapshot(
            mode: mode_t(actual.st_mode & 0o777),
            owner: actual.st_uid,
            group: actual.st_gid,
            extendedAttributes: try captureExtendedAttributes(from: descriptor),
            accessControlList: try captureAccessControlList(from: descriptor)
        )
    }

    private static func captureExtendedAttributes(
        from descriptor: Descriptor
    ) throws -> [ExtendedAttribute] {
        let listSize = Darwin.flistxattr(descriptor.rawValue, nil, 0, 0)
        if listSize < 0 {
            if errno == ENOTSUP { return [] }
            throw rejected("the target metadata could not be read")
        }
        guard listSize <= ssize_t(maximumExtendedAttributeNameBytes) else {
            throw rejected("the target metadata exceeds safe limits")
        }
        if listSize == 0 { return [] }

        var names = [CChar](repeating: 0, count: Int(listSize))
        let readSize = names.withUnsafeMutableBufferPointer { buffer in
            Darwin.flistxattr(descriptor.rawValue, buffer.baseAddress, buffer.count, 0)
        }
        guard readSize >= 0, readSize <= ssize_t(names.count) else {
            throw rejected("the target metadata changed during review")
        }

        var attributes: [ExtendedAttribute] = []
        var totalBytes = 0
        var start = 0
        let namesRead = Int(readSize)
        for index in 0..<namesRead where names[index] == 0 {
            guard index > start else {
                throw rejected("the target metadata could not be read")
            }
            let nameBytes = names[start..<index].map { UInt8(bitPattern: $0) }
            guard let name = String(bytes: nameBytes, encoding: .utf8),
                  name.utf8.count <= Int(XATTR_MAXNAMELEN) else {
                throw rejected("the target metadata could not be read")
            }
            start = index + 1
            guard extendedAttributeDisposition(for: name) == .preserve else { continue }
            guard attributes.count < maximumExtendedAttributeCount else {
                throw rejected("the target metadata exceeds safe limits")
            }
            guard let value = try readExtendedAttribute(named: name, from: descriptor) else {
                continue
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(value.count)
            guard !overflow, nextTotal <= maximumExtendedAttributeTotalBytes else {
                throw rejected("the target metadata exceeds safe limits")
            }
            totalBytes = nextTotal
            attributes.append(ExtendedAttribute(name: name, value: value))
        }
        guard start == namesRead else {
            throw rejected("the target metadata could not be read")
        }
        return attributes
    }

    private static func readExtendedAttribute(
        named name: String,
        from descriptor: Descriptor
    ) throws -> Data? {
        let size = name.withCString { attributeName in
            Darwin.fgetxattr(descriptor.rawValue, attributeName, nil, 0, 0, 0)
        }
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw rejected("the target metadata could not be read")
        }
        guard size <= ssize_t(maximumExtendedAttributeValueBytes) else {
            throw rejected("the target metadata exceeds safe limits")
        }
        if size == 0 { return Data() }

        var value = Data(count: Int(size))
        let readSize = value.withUnsafeMutableBytes { bytes in
            name.withCString { attributeName in
                Darwin.fgetxattr(
                    descriptor.rawValue,
                    attributeName,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        if readSize < 0, errno == ENOATTR { return nil }
        guard readSize == size else {
            throw rejected("the target metadata changed during review")
        }
        return value
    }

    private static func captureAccessControlList(
        from descriptor: Descriptor
    ) throws -> AccessControlListSnapshot {
        errno = 0
        if let accessControlList = Darwin.acl_get_fd_np(
            descriptor.rawValue,
            ACL_TYPE_EXTENDED
        ) {
            return .value(AccessControlList(accessControlList))
        }
        if errno == ENOENT { return .absent }
        if errno == ENOTSUP { return .unsupported }
        throw rejected("the target metadata could not be read")
    }

    private static func applyMetadata(
        _ metadata: MetadataSnapshot,
        to descriptor: Descriptor
    ) throws {
        let current = try descriptorMetadata(descriptor)
        if current.st_uid != metadata.owner || current.st_gid != metadata.group {
            guard Darwin.fchown(descriptor.rawValue, metadata.owner, metadata.group) == 0 else {
                throw rejected("the target ownership could not be preserved")
            }
        }

        for attribute in metadata.extendedAttributes {
            let result = attribute.value.withUnsafeBytes { bytes in
                attribute.name.withCString { name in
                    Darwin.fsetxattr(
                        descriptor.rawValue,
                        name,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        0
                    )
                }
            }
            guard result == 0 else {
                throw rejected("the target metadata could not be preserved")
            }
        }
        try applyAccessControlList(metadata.accessControlList, to: descriptor)
        guard Darwin.fchmod(descriptor.rawValue, metadata.mode) == 0 else {
            throw rejected("the target mode could not be preserved")
        }

        let applied = try descriptorMetadata(descriptor)
        guard applied.st_uid == metadata.owner,
              applied.st_gid == metadata.group,
              mode_t(applied.st_mode & 0o777) == metadata.mode else {
            throw rejected("the target metadata could not be preserved")
        }
    }

    private static func applyAccessControlList(
        _ snapshot: AccessControlListSnapshot,
        to descriptor: Descriptor
    ) throws {
        switch snapshot {
        case .unsupported:
            return
        case .absent:
            guard let empty = Darwin.acl_init(0) else {
                throw rejected("the target ACL could not be preserved")
            }
            defer { _ = acl_free(UnsafeMutableRawPointer(empty)) }
            guard Darwin.acl_set_fd_np(descriptor.rawValue, empty, ACL_TYPE_EXTENDED) == 0 else {
                throw rejected("the target ACL could not be preserved")
            }
        case let .value(accessControlList):
            guard Darwin.acl_set_fd_np(
                descriptor.rawValue,
                accessControlList.rawValue,
                ACL_TYPE_EXTENDED
            ) == 0 else {
                throw rejected("the target ACL could not be preserved")
            }
        }
    }

    private static func openRoot(_ rootPath: String) throws -> Descriptor {
        let raw = rootPath.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard raw >= 0 else {
            if errno == ELOOP { throw rejected("the session project is a symbolic link") }
            throw rejected("the session project is unavailable")
        }
        return Descriptor(raw)
    }

    private static func openParent(
        components: [String],
        root: Descriptor,
        createMissingDirectories: Bool
    ) throws -> Descriptor {
        var current = root
        for component in components {
            var raw = openDirectory(named: component, in: current)
            if raw < 0, errno == ENOENT, createMissingDirectories {
                let created = component.withCString { name in
                    Darwin.mkdirat(current.rawValue, name, 0o777)
                }
                if created != 0, errno != EEXIST {
                    throw descriptorFailure(errno, component: component, parent: current)
                }
                raw = openDirectory(named: component, in: current)
            }
            guard raw >= 0 else {
                throw descriptorFailure(errno, component: component, parent: current)
            }
            current = Descriptor(raw)
        }
        return current
    }

    private static func openDirectory(named component: String, in parent: Descriptor) -> Int32 {
        component.withCString { name in
            Darwin.openat(
                parent.rawValue,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
    }

    private static func descriptorFailure(
        _ code: Int32,
        component: String,
        parent: Descriptor
    ) -> AcpClientError {
        if code == ELOOP || entryIsSymbolicLink(named: component, in: parent) {
            return rejected("symbolic-link parents are not writable")
        }
        if code == ENOENT {
            return rejected("the target changed after review")
        }
        if code == ENOTDIR {
            return rejected("a target parent is not a directory")
        }
        if code == EACCES || code == EPERM {
            return rejected("the target is not writable")
        }
        return rejected("the target could not be safely opened")
    }

    private static func descriptorMetadata(_ descriptor: Descriptor) throws -> stat {
        var metadata = stat()
        guard Darwin.fstat(descriptor.rawValue, &metadata) == 0 else {
            throw rejected("the target changed after review")
        }
        return metadata
    }

    private static func entryMetadata(named leaf: String, in parent: Descriptor) throws -> stat? {
        var metadata = stat()
        let result = leaf.withCString { name in
            Darwin.fstatat(parent.rawValue, name, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return metadata }
        if errno == ENOENT { return nil }
        throw descriptorFailure(errno, component: leaf, parent: parent)
    }

    private static func entryIsSymbolicLink(named leaf: String, in parent: Descriptor) -> Bool {
        var metadata = stat()
        let result = leaf.withCString { name in
            Darwin.fstatat(parent.rawValue, name, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 && isSymbolicLink(metadata)
    }

    private static func validateCurrentEntry(_ current: stat?, matches reviewed: stat?) throws {
        if let current, isSymbolicLink(current) {
            throw rejected("symbolic-link targets are not writable")
        }
        switch (reviewed, current) {
        case (nil, nil):
            return
        case let (.some(expected), .some(actual))
            where isRegularFile(actual) && sameIdentity(expected, actual):
            return
        default:
            throw rejected("the target changed after review")
        }
    }

    private static func createTemporaryFile(
        in parent: Descriptor,
        mode: mode_t
    ) throws -> (leaf: String, descriptor: Descriptor) {
        for _ in 0..<128 {
            let leaf = ".kaisola-acp-write-\(UUID().uuidString)"
            let raw = leaf.withCString { name in
                Darwin.openat(
                    parent.rawValue,
                    name,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode
                )
            }
            if raw >= 0 {
                let descriptor = Descriptor(raw)
                guard Darwin.fchmod(raw, mode) == 0 else {
                    unlinkIfOwned(named: leaf, descriptor: descriptor, in: parent)
                    throw rejected("the target is not writable")
                }
                return (leaf, descriptor)
            }
            if errno != EEXIST {
                throw rejected("the target is not writable")
            }
        }
        throw rejected("the target is not writable")
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw rejected("the target could not be written") }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw rejected("the target could not be written")
        }
    }

    private static func installNew(
        leaf: String,
        temporaryLeaf: String,
        parent: Descriptor
    ) throws {
        let result = temporaryLeaf.withCString { temporaryName in
            leaf.withCString { destinationName in
                Darwin.renameatx_np(
                    parent.rawValue,
                    temporaryName,
                    parent.rawValue,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw rejected("the target changed after review") }
            throw rejected("the target could not be written")
        }
    }

    private static func replaceExisting(
        leaf: String,
        reviewedEntry: stat,
        temporaryLeaf: String,
        parent: Descriptor,
        beforeCommit: BeforeMutation?
    ) throws {
        guard exchange(temporaryLeaf, leaf, in: parent) == 0 else {
            if errno == ENOENT { throw rejected("the target changed after review") }
            throw rejected("the target could not be safely replaced")
        }

        do {
            let displaced = try entryMetadata(named: temporaryLeaf, in: parent)
            guard let displaced,
                  !isSymbolicLink(displaced),
                  sameIdentity(reviewedEntry, displaced) else {
                throw rejected("the target changed after review")
            }
            try beforeCommit?()
            let stillDisplaced = try entryMetadata(named: temporaryLeaf, in: parent)
            guard let stillDisplaced,
                  !isSymbolicLink(stillDisplaced),
                  sameIdentity(reviewedEntry, stillDisplaced) else {
                throw rejected("the target changed before replacement committed")
            }
            guard unlink(named: temporaryLeaf, in: parent) == 0 else {
                throw rejected("the target could not be safely replaced")
            }
        } catch {
            guard exchange(temporaryLeaf, leaf, in: parent) == 0 else {
                throw rejected("the target could not be safely restored")
            }
            throw error
        }
    }

    private static func exchange(_ first: String, _ second: String, in parent: Descriptor) -> Int32 {
        first.withCString { firstName in
            second.withCString { secondName in
                Darwin.renameatx_np(
                    parent.rawValue,
                    firstName,
                    parent.rawValue,
                    secondName,
                    UInt32(RENAME_SWAP)
                )
            }
        }
    }

    private static func unlink(named leaf: String, in parent: Descriptor) -> Int32 {
        leaf.withCString { name in Darwin.unlinkat(parent.rawValue, name, 0) }
    }

    /// After an exchange, the temporary *name* can refer to the displaced
    /// target while the temporary descriptor still refers to our new bytes.
    /// Cleanup only when both identities match, so a failed rollback can never
    /// turn error handling into deletion of somebody else's entry.
    private static func unlinkIfOwned(
        named leaf: String,
        descriptor: Descriptor,
        in parent: Descriptor
    ) {
        var owned = stat()
        guard Darwin.fstat(descriptor.rawValue, &owned) == 0,
              let named = try? entryMetadata(named: leaf, in: parent),
              sameIdentity(owned, named) else {
            return
        }
        _ = unlink(named: leaf, in: parent)
    }

    private static func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private static func isSymbolicLink(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFLNK
    }

    private static func isRegularFile(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
    }

    private static func rejected(_ reason: String) -> AcpClientError {
        .requestFailed("Blocked agent file write: \(reason).")
    }
}
