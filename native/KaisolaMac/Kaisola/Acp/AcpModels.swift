import Foundation
import KaisolaCore

/// The ACP wire protocol version this native client speaks.
enum AcpWire {
    static let protocolVersion = 1
}

/// A reusable, immutable-at-launch declaration of the model and host services
/// an ACP chat may use. String identifiers are retained deliberately: a tool
/// or MCP server removed after the profile was saved must remain visible as an
/// actionable warning, never disappear and silently broaden the profile.
struct AcpRunProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum ClientTool: String, CaseIterable, Codable, Sendable {
        case readTextFile
        case writeTextFile
        case terminal

        var title: String {
            switch self {
            case .readTextFile: "Read workspace files"
            case .writeTextFile: "Write workspace files"
            case .terminal: "Run host terminals"
            }
        }
    }

    static let allMCPServersID = "*"
    // Xcode 16.4 / Swift 6.1 can crash while lowering these value-only lazy
    // globals under whole-module compilation. Computed values are equivalent
    // here: profiles are immutable value snapshots with stable explicit IDs.
    static var write: AcpRunProfile {
        AcpRunProfile(
            id: "write",
            name: "Write",
            modelID: nil,
            enabledClientToolIDs: ClientTool.allCases.map(\.rawValue),
            enabledMCPServerNames: [allMCPServersID]
        )
    }

    static var ask: AcpRunProfile {
        AcpRunProfile(
            id: "ask",
            name: "Ask",
            modelID: nil,
            enabledClientToolIDs: [ClientTool.readTextFile.rawValue],
            enabledMCPServerNames: [allMCPServersID]
        )
    }

    static var minimal: AcpRunProfile {
        AcpRunProfile(
            id: "minimal",
            name: "Minimal",
            modelID: nil,
            enabledClientToolIDs: [],
            enabledMCPServerNames: []
        )
    }

    static var builtIns: [AcpRunProfile] { [write, ask, minimal] }

    let id: String
    var name: String
    var modelID: String?
    var enabledClientToolIDs: [String]
    var enabledMCPServerNames: [String]

    init(
        id: String,
        name: String,
        modelID: String?,
        enabledClientToolIDs: [String],
        enabledMCPServerNames: [String]
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = model?.isEmpty == false ? model : nil
        self.enabledClientToolIDs = Self.unique(enabledClientToolIDs)
        self.enabledMCPServerNames = Self.unique(enabledMCPServerNames)
    }

    var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    func allows(_ tool: ClientTool) -> Bool {
        enabledClientToolIDs.contains(tool.rawValue)
    }

    func restricting(_ access: AcpAdapterAccess) -> AcpAdapterAccess {
        AcpAdapterAccess(
            workspaceRead: access.workspaceRead && allows(.readTextFile),
            workspaceWrite: access.workspaceWrite && allows(.writeTextFile),
            network: access.network,
            childProcess: access.childProcess,
            hostTerminal: access.hostTerminal && allows(.terminal)
        )
    }

    func filterMCPServers(_ servers: [JSONValue]) -> [JSONValue] {
        guard !enabledMCPServerNames.contains(Self.allMCPServersID) else { return servers }
        let allowed = Set(enabledMCPServerNames)
        return servers.filter { value in
            guard let name = value.objectValue?["name"]?.stringValue else { return false }
            return allowed.contains(name)
        }
    }

    func availabilityWarnings(knownMCPServerNames: [String]) -> [String] {
        let tools = Set(ClientTool.allCases.map(\.rawValue))
        let knownServers = Set(knownMCPServerNames)
        let toolWarnings = enabledClientToolIDs
            .filter { !tools.contains($0) }
            .map { "Tool “\($0)” is unavailable." }
        let serverWarnings = enabledMCPServerNames
            .filter { $0 != Self.allMCPServersID && !knownServers.contains($0) }
            .map { "MCP server “\($0)” is unavailable." }
        return toolWarnings + serverWarnings
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }
}

/// UserDefaults-backed custom run profiles. Built-ins are immutable and kept
/// out of the payload so upgrades can safely improve their definitions.
final class AcpRunProfileStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "acpRunProfiles.v1") {
        self.defaults = defaults
        self.key = key
    }

    func all() -> [AcpRunProfile] { AcpRunProfile.builtIns + custom() }

    func profile(id: String) -> AcpRunProfile? {
        all().first { $0.id == id }
    }

    var defaultProfileID: String {
        get {
            let stored = defaults.string(forKey: "\(key).default") ?? AcpRunProfile.write.id
            return profile(id: stored) == nil ? AcpRunProfile.write.id : stored
        }
        set {
            guard profile(id: newValue) != nil else { return }
            defaults.set(newValue, forKey: "\(key).default")
        }
    }

    var defaultProfile: AcpRunProfile {
        profile(id: defaultProfileID) ?? .write
    }

    @discardableResult
    func create(
        name: String,
        modelID: String? = nil,
        enabledClientToolIDs: [String] = AcpRunProfile.write.enabledClientToolIDs,
        enabledMCPServerNames: [String] = AcpRunProfile.write.enabledMCPServerNames
    ) -> AcpRunProfile {
        var profiles = custom()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = Self.slug(trimmed.isEmpty ? "Profile" : trimmed)
        let existing = Set(all().map(\.id))
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        let profile = AcpRunProfile(
            id: candidate,
            name: trimmed.isEmpty ? "Profile" : trimmed,
            modelID: modelID,
            enabledClientToolIDs: enabledClientToolIDs,
            enabledMCPServerNames: enabledMCPServerNames
        )
        profiles.append(profile)
        save(profiles)
        return profile
    }

    @discardableResult
    func fork(_ id: String) -> AcpRunProfile? {
        guard let source = profile(id: id) else { return nil }
        return create(
            name: "\(source.name) Copy",
            modelID: source.modelID,
            enabledClientToolIDs: source.enabledClientToolIDs,
            enabledMCPServerNames: source.enabledMCPServerNames
        )
    }

    @discardableResult
    func rename(_ id: String, to name: String) -> Bool {
        guard !AcpRunProfile.builtIns.contains(where: { $0.id == id }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var profiles = custom()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].name = trimmed
        save(profiles)
        return true
    }

    @discardableResult
    func update(_ profile: AcpRunProfile) -> Bool {
        guard !profile.isBuiltIn else { return false }
        var profiles = custom()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        profiles[index] = profile
        save(profiles)
        return true
    }

    /// Apply the warning's explicit repair action without broadening the
    /// profile: valid selections remain enabled, while identifiers the current
    /// client or workspace cannot provide are removed from this custom profile.
    @discardableResult
    func removeUnavailableReferences(
        from id: String,
        knownMCPServerNames: [String]?
    ) -> Bool {
        guard !AcpRunProfile.builtIns.contains(where: { $0.id == id }) else { return false }
        var profiles = custom()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }

        let knownToolIDs = Set(AcpRunProfile.ClientTool.allCases.map(\.rawValue))
        var repaired = profiles[index]
        repaired.enabledClientToolIDs.removeAll { !knownToolIDs.contains($0) }
        if let knownMCPServerNames {
            let knownServerNames = Set(knownMCPServerNames)
            repaired.enabledMCPServerNames.removeAll {
                $0 != AcpRunProfile.allMCPServersID && !knownServerNames.contains($0)
            }
        }
        guard repaired != profiles[index] else { return false }

        profiles[index] = repaired
        save(profiles)
        return true
    }

    @discardableResult
    func delete(_ id: String) -> Bool {
        guard !AcpRunProfile.builtIns.contains(where: { $0.id == id }) else { return false }
        var profiles = custom()
        let oldCount = profiles.count
        profiles.removeAll { $0.id == id }
        guard profiles.count != oldCount else { return false }
        save(profiles)
        if defaults.string(forKey: "\(key).default") == id {
            defaults.set(AcpRunProfile.write.id, forKey: "\(key).default")
        }
        return true
    }

    private func custom() -> [AcpRunProfile] {
        guard let data = defaults.data(forKey: key),
              let profiles = try? JSONDecoder().decode([AcpRunProfile].self, from: data) else {
            return []
        }
        return profiles.filter { !$0.isBuiltIn }.prefix(32).map { $0 }
    }

    private func save(_ profiles: [AcpRunProfile]) {
        guard let data = try? JSONEncoder().encode(Array(profiles.prefix(32))) else { return }
        defaults.set(data, forKey: key)
    }

    private static func slug(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "profile" : collapsed
    }
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

/// Immutable provider/account identity captured before an adapter starts.
/// Failure and fallback UI must describe this launch context rather than
/// inferring credentials from whatever error text an adapter happens to emit.
struct AcpProviderLaunchContext: Equatable, Sendable {
    let providerName: String
    let accountLabel: String
    let defaultSettingsSectionID: String

    init(
        providerName: String,
        accountLabel: String,
        defaultSettingsSectionID: String
    ) {
        self.providerName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultSettingsSectionID = defaultSettingsSectionID
    }
}

/// A provider launch error with a deterministic recovery destination. The raw
/// detail remains visible, but it never supplies provider/account identity.
struct AcpProviderStartupFailure: Equatable, Sendable {
    let providerName: String
    let accountLabel: String
    let detail: String
    let settingsSectionID: String
    let settingsTitle: String

    init(context: AcpProviderLaunchContext, detail: String) {
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchable = normalizedDetail.lowercased()
        let modelOrKeyFailure = [
            "api key", "api_key", "apikey", "base url", "base_url", "model",
        ].contains { searchable.contains($0) }
        let accountFailure = [
            "account", "authentication", "authenticate", "credentials", "login",
            "sign in", "signed out", "401", "403",
        ].contains { searchable.contains($0) }

        providerName = context.providerName.isEmpty ? "Configured provider" : context.providerName
        accountLabel = context.accountLabel.isEmpty ? "Default account" : context.accountLabel
        self.detail = normalizedDetail.isEmpty ? "The adapter did not provide an error detail." : normalizedDetail
        if modelOrKeyFailure {
            settingsSectionID = "models"
            settingsTitle = "Models & Keys"
        } else if accountFailure {
            settingsSectionID = "accounts"
            settingsTitle = "Accounts"
        } else {
            settingsSectionID = context.defaultSettingsSectionID
            switch context.defaultSettingsSectionID {
            case "agents": settingsTitle = "Agents"
            case "models": settingsTitle = "Models & Keys"
            default: settingsTitle = "Accounts"
            }
        }
    }

    var summary: String {
        "\(providerName) account “\(accountLabel)” could not start. \(detail)"
    }
}

/// A requested model was not honored by the adapter. This is a pre-inference
/// gate: callers must explicitly accept the adapter's actual model or cancel.
struct AcpModelFallback: Equatable, Sendable {
    let requestedID: String
    let requestedLabel: String
    let actualID: String
    let actualLabel: String
    let providerName: String
    let accountLabel: String
}

extension Notification.Name {
    /// Window-scoped through `object: AppModel`; another window must not open
    /// Settings when this conversation requests provider recovery.
    static var kaisolaOpenProviderSettings: Notification.Name {
        Notification.Name("kaisola.openProviderSettings")
    }

    /// The app delegate's route into the in-workspace Settings takeover (⌘,
    /// and every Settings menu deep link). Window-scoped through
    /// `object: AppModel`; an optional
    /// `AcpProviderSettingsNotificationKey.sectionID` lands the page on a
    /// section.
    static var kaisolaOpenSettingsSurface: Notification.Name {
        Notification.Name("kaisola.openSettingsSurface")
    }
}

enum AcpProviderSettingsNotificationKey {
    static let sectionID = "sectionID"
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
    /// A frame that never reached the JSON-RPC layer: unparsable JSON, invalid
    /// UTF-8, a stream that ended mid-message. The payload is a short excerpt of
    /// the offending bytes (see `AcpClient.framePreview`), never the whole frame.
    case malformedFrame(String)
    case requestFailed(String)
    case frameTooLarge
    case unsupportedProtocol(Int)

    var errorDescription: String? {
        switch self {
        case .notRunning: "The agent is not running."
        case let .adapterExited(code): "The agent process exited (code \(code))."
        case let .spawnFailed(message): "Could not start the agent: \(message)"
        case .malformedResponse: "The agent sent a malformed message."
        case let .malformedFrame(detail): "The agent sent a malformed message: \(detail)"
        case let .requestFailed(message): message
        case .frameTooLarge: "The agent sent an oversized message."
        case let .unsupportedProtocol(version):
            "The agent negotiated unsupported ACP protocol version \(version)."
        }
    }
}
