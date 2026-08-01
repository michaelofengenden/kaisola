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
    case toolCall(AcpToolCall)
    case plan(entries: [AcpPlanEntry])

    var id: String {
        switch self {
        case let .message(id, _): "msg-\(id)"
        case let .thought(id, _): "thought-\(id)"
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
    let id: String
    let name: String
    var currentValue: String?
    let choices: [Choice]

    struct Choice: Equatable, Sendable, Identifiable {
        let value: String
        let name: String
        var id: String { value }
    }
}

/// Capabilities the agent advertised at `initialize`.
struct AcpAgentCapabilities: Equatable, Sendable {
    var loadSession = false
    var resumeSession = false
    var closeSession = false
    var promptQueueing = false
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
