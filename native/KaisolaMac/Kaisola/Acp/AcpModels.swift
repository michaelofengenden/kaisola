import Foundation
import KaisolaCore

/// The ACP wire protocol version this native client speaks.
enum AcpWire {
    static let protocolVersion = 1
}

/// A streamed conversation turn item, mirroring the ACP `session/update`
/// variants the Electron renderer consumes (agent_message_chunk,
/// agent_thought_chunk, tool_call, plan, …).
enum AcpTurnItem: Equatable, Sendable, Identifiable {
    case message(id: String, text: String)
    case thought(id: String, text: String)
    /// A user message the AGENT reported (`user_message_chunk`), as opposed to
    /// one this client sent. Adapters emit these when they replay a resumed
    /// session's history, and some echo the live turn's user input. `id` is the
    /// adapter's `messageId` when it sent one — the only stable identity a
    /// replayed row has — and `nil` otherwise.
    case userMessage(id: String?, text: String)
    case toolCall(AcpToolCall)
    case plan(entries: [AcpPlanEntry])

    var id: String {
        switch self {
        case let .message(id, _): "msg-\(id)"
        case let .thought(id, _): "thought-\(id)"
        case let .userMessage(id, text): "user-\(id ?? "live-\(text.count)")"
        case let .toolCall(call): "tool-\(call.id)"
        case .plan: "plan"
        }
    }
}

struct AcpToolCall: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var kind: String
    var status: Status
    /// Rich artifacts the agent attached to the call: file diffs and text/output
    /// blocks. Empty until a `tool_call`/`tool_call_update` carries `content`.
    var content: [AcpToolContent] = []
    /// File paths the tool touched (ACP `locations`), for a compact affected-files line.
    var locations: [String] = []

    enum Status: String, Codable, Equatable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
    }
}

struct AcpFileActivity: Equatable, Sendable {
    let toolCallID: String
    let kind: String
    let path: String
}

extension AcpToolCall {
    /// Ordered, deduplicated ACP-declared paths only. Display text and tool
    /// titles are intentionally excluded: follow mode must never infer a local
    /// file from prose that merely looks path-like.
    var declaredFilePaths: [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for path in locations + content.compactMap({ artifact in
            guard case let .diff(path, _, _) = artifact else { return nil }
            return path
        }) where !path.isEmpty && seen.insert(path).inserted {
            paths.append(path)
            if paths.count == 64 { break }
        }
        return paths
    }
}

/// A single artifact inside a tool call. Mirrors ACP `ToolCallContent`:
/// a file diff, a generic text/output content block, or a reference to an
/// agent-spawned terminal (rendered live from `AcpTerminalHost`).
enum AcpToolContent: Codable, Equatable, Sendable, Identifiable {
    case diff(path: String, oldText: String?, newText: String)
    case text(String)
    case terminal(id: String)

    var id: String {
        switch self {
        case let .diff(path, _, newText): "diff-\(path)-\(newText.count)"
        case let .text(text): "text-\(text.hashValue)"
        case let .terminal(id): "terminal-\(id)"
        }
    }
}

struct AcpPlanEntry: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let content: String
    let priority: String
    var status: String
}

/// A permission the agent is asking the user to grant mid-turn.
struct AcpPermissionRequest: Equatable, Sendable, Identifiable {
    let id: Int
    let sessionID: String
    let title: String
    let options: [Option]
    /// ACP's untyped `toolCall.rawInput`. Keeping the decoded JSON intact lets
    /// the review card disclose the command/resource payload without guessing
    /// at adapter-specific keys or flattening away structure.
    var rawInput: JSONValue? = nil
    /// The tool-call kind (execute/edit/read/delete/fetch/other), used to derive
    /// and match standing allow-rules.
    var kind: String = "other"
    /// File paths the request touches (ACP tool-call `locations` + diff paths),
    /// scanned against sensitive globs.
    var paths: [String] = []

    struct Option: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let kind: String
    }
}

/// Review-relevant fields retained from the latest updates for one tool call.
/// A permission request carries a `ToolCallUpdate`, so it may omit values the
/// agent already declared in an earlier `session/update` event.
struct AcpToolCallReviewContext: Equatable, Sendable {
    var title: String?
    var kind: String?
    var rawInput: JSONValue?
    var locationPaths: [String]
    var diffPaths: [String]

    init(
        title: String? = nil,
        kind: String? = nil,
        rawInput: JSONValue? = nil,
        locationPaths: [String] = [],
        diffPaths: [String] = []
    ) {
        self.title = title
        self.kind = kind
        self.rawInput = rawInput
        self.locationPaths = locationPaths
        self.diffPaths = diffPaths
    }
}

/// Live context-window usage from `usage_update`.
struct AcpUsage: Equatable, Sendable {
    let used: Int
    let max: Int
    /// Optional cumulative session cost from ACP's standard `usage_update`.
    /// Adapters that do not report cost leave both fields nil.
    var costAmount: Double? = nil
    var costCurrency: String? = nil
}

/// The result of `session/new`.
struct AcpSessionInfo: Equatable, Sendable {
    let sessionID: String
    let models: [Model]
    let currentModelID: String?
    /// ACP session permission modes (plan/default/acceptEdits/bypassPermissions,
    /// or an adapter's own set), and the one currently selected.
    var modes: [Mode] = []
    var currentModeID: String?
    /// Adapter configuration options (effort levels etc.).
    var configOptions: [AcpConfigOption] = []
    /// Whether the adapter advertised the `_session/steering` extension, so a
    /// queued follow-up may be injected into a turn that is already running.
    var supportsSteering = false

    struct Model: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    struct Mode: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
    }
}

/// A slash command the agent advertises via `available_commands_update`.
struct AcpCommand: Equatable, Sendable, Identifiable {
    let name: String
    let description: String
    var id: String { name }
}

/// An adapter configuration option (reasoning effort, approval preset, …) from
/// `session/new`'s `configOptions` and `session/set_config_option` responses.
struct AcpConfigOption: Equatable, Sendable, Identifiable {
    enum Value: Equatable, Sendable {
        case select(String)
        case boolean(Bool)
    }

    let id: String
    let name: String
    /// Adapter-provided explanatory copy. Boolean rows use it as both help and
    /// an accessibility hint; it is never inferred from the identifier.
    let description: String?
    /// ACP's own classification of what this option *is* (`mode`, `model`,
    /// `thought_level`, …). Adapters name the same setting differently — Codex
    /// says "Reasoning effort", our mock says the same, a third could say
    /// "Thinking" — so the category is the only non-guessing way to know that
    /// two surfaces are describing one setting. `nil` when the adapter omits it,
    /// which is why the name heuristics survive alongside it.
    var category: String?
    let value: Value?
    let choices: [Choice]

    /// Compatibility accessor for select options. A boolean never degrades to
    /// the strings "true"/"false", which keeps wire typing fail closed.
    var currentValue: String? {
        guard case let .select(current)? = value else { return nil }
        return current
    }

    var booleanValue: Bool? {
        guard case let .boolean(current)? = value else { return nil }
        return current
    }

    init(
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        currentValue: String?,
        choices: [Choice]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.value = currentValue.map(Value.select)
        self.choices = choices
    }

    init(
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        currentBooleanValue: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.value = .boolean(currentBooleanValue)
        self.choices = []
    }

    struct Choice: Equatable, Sendable, Identifiable {
        let value: String
        let name: String
        var id: String { value }
    }
}

/// ACP v1 boolean session configuration is optional and separately negotiated.
/// Keeping its additive wire contract here leaves the established select-option
/// parser and mutation path unchanged for adapters that do not support it.
enum AcpBooleanConfigWire {
    static func advertise(in parameters: JSONValue) -> JSONValue {
        guard var root = parameters.objectValue,
              var capabilities = root["clientCapabilities"]?.objectValue else {
            return parameters
        }
        capabilities["session"] = .object([
            "configOptions": .object([
                "boolean": .object([:]),
            ]),
        ])
        root["clientCapabilities"] = .object(capabilities)
        return .object(root)
    }

    /// Unknown option types and type/value mismatches are ignored rather than
    /// coerced into a control that could send a differently typed mutation.
    static func parseOptions(_ value: JSONValue?) -> [AcpConfigOption] {
        (value?.arrayValue ?? []).compactMap { item -> AcpConfigOption? in
            guard let object = item.objectValue,
                  let id = object["id"]?.stringValue else { return nil }
            let name = object["name"]?.stringValue ?? id
            let description = object["description"]?.stringValue
            let category = object["category"]?.stringValue
            switch object["type"]?.stringValue {
            case "boolean":
                guard let currentValue = object["currentValue"]?.boolValue else { return nil }
                return AcpConfigOption(
                    id: id,
                    name: name,
                    description: description,
                    category: category,
                    currentBooleanValue: currentValue
                )
            case "select", nil:
                let choices = (object["options"]?.arrayValue ?? []).compactMap { choice -> AcpConfigOption.Choice? in
                    guard let fields = choice.objectValue,
                          let value = fields["value"]?.stringValue else { return nil }
                    return AcpConfigOption.Choice(
                        value: value,
                        name: fields["name"]?.stringValue ?? value
                    )
                }
                return AcpConfigOption(
                    id: id,
                    name: name,
                    description: description,
                    category: category,
                    currentValue: object["currentValue"]?.stringValue,
                    choices: choices
                )
            default:
                return nil
            }
        }
    }
}

/// Capabilities the agent advertised at `initialize`.
struct AcpAgentCapabilities: Equatable, Sendable {
    var loadSession = false
    var resumeSession = false
    var closeSession = false
    var promptQueueing = false
    /// `InitializeResponse._meta.steering.supported`. Deliberately read from the
    /// TOP-LEVEL `_meta` (a sibling of `agentCapabilities`, not a member of it),
    /// which is where both shipping adapters put it.
    var steering = false
    var mcpHTTP = false
    var mcpSSE = false
    var promptImage = false
    var promptEmbeddedContext = false
}

enum AcpClientError: Error, Equatable, LocalizedError {
    case notRunning
    case adapterExited(code: Int32)
    case spawnFailed(String)
    case malformedResponse
    case requestFailed(String)
    case frameTooLarge
    case unsupportedProtocol(Int)

    var errorDescription: String? {
        switch self {
        case .notRunning: "The agent is not running."
        case let .adapterExited(code): "The agent process exited (code \(code))."
        case let .spawnFailed(message): "Could not start the agent: \(message)"
        case .malformedResponse: "The agent sent a malformed message."
        case let .requestFailed(message): message
        case .frameTooLarge: "The agent sent an oversized message."
        case let .unsupportedProtocol(version):
            "The agent negotiated unsupported ACP protocol version \(version)."
        }
    }
}
