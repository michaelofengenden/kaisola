import Foundation
import KaisolaCore

/// One configured MCP server, scoped to a workspace. `id` is the `name`, so a
/// workspace can hold at most one server per name (mirroring the Node registry's
/// unique-id contract). `command`/`args`/`envPairs` describe a `stdio` server;
/// `url`/`headerPairs` describe an `http`/`sse` server. Only the fields relevant
/// to `kind` are consumed by `McpConfigStore.jsonValues`.
struct McpServerConfig: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case stdio, http, sse
    }

    /// A `{name,value}` pair — an environment variable for a stdio server, or an
    /// HTTP header for an http/sse server. Matches the Node registry's `toPairs`
    /// output shape exactly.
    struct Pair: Codable, Equatable, Sendable {
        var name: String
        var value: String
    }

    var name: String
    var kind: Kind
    var command: String?
    var args: [String]
    var url: String?
    var envPairs: [Pair]
    var headerPairs: [Pair]
    var enabled: Bool

    var id: String { name }

    /// Mirrors `scripts/native-mcp-registry.cjs` validation. Invalid persisted
    /// records are never forwarded into `session/new`, so a damaged setting
    /// cannot turn into a surprising process spawn or credential-bearing URL.
    var validationError: String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.safeName(cleanName) else { return "Name is required, must be under 128 bytes, and cannot contain line breaks." }
        guard args.count <= 64,
              args.allSatisfy({ $0.utf8.count <= 4_096 && !$0.contains("\0") }) else {
            return "A server can have at most 64 bounded arguments."
        }
        guard envPairs.count <= 32,
              headerPairs.count <= 32,
              envPairs.allSatisfy(Self.safePair),
              headerPairs.allSatisfy(Self.safePair) else {
            return "Environment and headers are limited to 32 bounded, single-line pairs."
        }
        switch kind {
        case .stdio:
            guard let command,
                  command.utf8.count <= 512,
                  Self.safeRequired(command.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return "A valid command is required."
            }
        case .http, .sse:
            guard let url, url.utf8.count <= 4_096,
                  let components = URLComponents(string: url),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false else {
                return "Remote MCP servers must use a valid HTTPS URL."
            }
            guard components.user == nil, components.password == nil else {
                return "Put credentials in headers, not the URL."
            }
        }
        return nil
    }

    private static func safeRequired(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096
            && !value.contains("\0") && !value.contains("\r") && !value.contains("\n")
    }

    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func safePair(_ pair: Pair) -> Bool {
        pair.name.utf8.count <= 128
            && safeRequired(pair.name.trimmingCharacters(in: .whitespacesAndNewlines))
            && pair.name.rangeOfCharacter(from: .controlCharacters) == nil
            && pair.value.utf8.count <= 4_096
            && !pair.value.contains("\0")
            && !pair.value.contains("\r")
            && !pair.value.contains("\n")
    }

    init(
        name: String,
        kind: Kind,
        command: String? = nil,
        args: [String] = [],
        url: String? = nil,
        envPairs: [Pair] = [],
        headerPairs: [Pair] = [],
        enabled: Bool = true
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.url = url
        self.envPairs = envPairs
        self.headerPairs = headerPairs
        self.enabled = enabled
    }
}

/// Persists a workspace's MCP servers USER-GLOBALLY, keyed by the workspace's
/// stable project digest — never inside the workspace itself. A repo-local
/// config file would let any cloned repository ship `.kaisola/mcp.json` whose
/// stdio `command` auto-runs when a chat or Mesh opens there (the agent spawns
/// MCP servers at session start, before any permission prompt). Electron's
/// registry made the same call (`native-mcp-registry.cjs` keys by workspace
/// sha256 under userData); only the user's own app-support data is trusted.
/// Atomic-write discipline matches `PermissionRuleStore` (0700 dir / 0600 file,
/// temp-file + `replaceItemAt`, corrupt file → empty). Wire shapes handed to
/// `session/new` are produced by `jsonValues` and mirror
/// `scripts/native-mcp-registry.cjs` exactly.
struct McpConfigStore: Sendable {
    static let maximumServerCount = 24

    /// Wrapper so the on-disk root is an object (room for a schema field later),
    /// matching PermissionRuleStore's `{rules:[...]}` layout.
    private struct Payload: Codable {
        var servers: [McpServerConfig]
    }

    let fileURL: URL

    init(
        workspace: URL,
        rootDirectory: URL = NativePreviewPaths.applicationSupportDirectory
    ) {
        // Same digest the session store uses for project identity, so one
        // workspace ⇒ one config file regardless of how it was opened.
        let digest = NativeSessionStore.projectID(forDirectory: workspace.path)
        fileURL = rootDirectory
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("\(digest).json", isDirectory: false)
    }

    func servers() -> [McpServerConfig] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return []
        }
        return Array(payload.servers.filter { $0.validationError == nil }.prefix(Self.maximumServerCount))
    }

    func save(_ servers: [McpServerConfig]) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let validated = Array(servers.filter { $0.validationError == nil }.prefix(Self.maximumServerCount))
        guard let data = try? JSONEncoder().encode(Payload(servers: validated)) else { return }
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)"
        )
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    // MARK: - Session wire shapes

    /// Build the `mcpServers` array for ACP `session/new`, emitting EXACTLY the
    /// shapes `native-mcp-registry.cjs` `buildSessionServers` produces:
    ///   - stdio → `{name, command, args, env:[{name,value}]}` (NO `type` key)
    ///   - http/sse → `{type, name, url, headers:[{name,value}]}`
    /// `args`/`env`/`headers` are always present, even when empty. Only enabled
    /// servers are emitted. Capability filtering (dropping http/sse an agent can't
    /// reach) is NOT applied here — `AcpClient.sessionMcpServers` does it later,
    /// client-side, keyed off the `type` field this method stamps.
    static func jsonValues(_ servers: [McpServerConfig]) -> [JSONValue] {
        servers.compactMap { server in
            guard server.enabled, server.validationError == nil else { return nil }
            switch server.kind {
            case .stdio:
                return .object([
                    "name": .string(server.name),
                    "command": .string(server.command ?? ""),
                    "args": .array(server.args.map(JSONValue.string)),
                    "env": .array(server.envPairs.map(Self.pairObject)),
                ])
            case .http, .sse:
                return .object([
                    "type": .string(server.kind.rawValue),
                    "name": .string(server.name),
                    "url": .string(server.url ?? ""),
                    "headers": .array(server.headerPairs.map(Self.pairObject)),
                ])
            }
        }
    }

    private static func pairObject(_ pair: McpServerConfig.Pair) -> JSONValue {
        .object(["name": .string(pair.name), "value": .string(pair.value)])
    }

    /// Imports only the explicit discoveries selected by the user. New entries
    /// always arrive disabled: reading a sibling config must never spawn a
    /// process or contact a remote endpoint. Existing names win and the
    /// workspace catalog remains bounded.
    @discardableResult
    func importDiscovered(_ discoveries: [McpDiscoveredServer]) -> Int {
        var current = servers()
        var names = Set(current.map(\.name))
        var imported = 0
        for discovery in discoveries {
            guard current.count < Self.maximumServerCount,
                  !names.contains(discovery.config.name) else { continue }
            var config = discovery.config
            config.enabled = false
            guard config.validationError == nil else { continue }
            current.append(config)
            names.insert(config.name)
            imported += 1
        }
        if imported > 0 { save(current) }
        return imported
    }
}

// MARK: - Safe sibling-config discovery

struct McpDiscoveredServer: Equatable, Identifiable, Sendable {
    let origin: String
    let config: McpServerConfig

    var id: String { "\(origin)\u{1F}\(config.name)" }
}

/// Reads the MCP shapes already used by common local clients. Discovery is a
/// read-only, bounded operation: it never expands `${VAR}`, follows no custom
/// paths, imports no literal credentials, and does not arm anything.
enum McpConfigDiscovery {
    private struct Source {
        let origin: String
        let relativePath: String
        let mapKeys: [String]
        let isCodexTOML: Bool

        init(_ origin: String, _ relativePath: String, mapKeys: [String] = ["mcpServers"], isCodexTOML: Bool = false) {
            self.origin = origin
            self.relativePath = relativePath
            self.mapKeys = mapKeys
            self.isCodexTOML = isCodexTOML
        }
    }

    private static let maximumFileBytes = 1_000_000
    private static let maximumEntriesPerSource = 24
    private static let sources = [
        Source("Cursor", ".cursor/mcp.json"),
        Source("Claude Desktop", "Library/Application Support/Claude/claude_desktop_config.json"),
        Source("Claude CLI", ".claude.json"),
        Source("Codex CLI", ".codex/config.toml", isCodexTOML: true),
        Source("Gemini CLI", ".gemini/settings.json"),
        Source("VS Code", "Library/Application Support/Code/User/mcp.json", mapKeys: ["servers", "mcpServers"]),
        Source("Windsurf", ".codeium/windsurf/mcp_config.json"),
    ]

    static func scan(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [McpDiscoveredServer] {
        var result: [McpDiscoveredServer] = []
        var seenNames = Set<String>()
        for source in sources {
            let url = homeDirectory.appendingPathComponent(source.relativePath, isDirectory: false)
            guard let data = boundedData(at: url) else { continue }
            let root: [String: Any]?
            if source.isCodexTOML {
                root = parseCodexMcpTOML(String(decoding: data, as: UTF8.self))
            } else {
                root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            guard let root,
                  let rawMap = source.mapKeys.lazy.compactMap({ root[$0] as? [String: Any] }).first else { continue }
            for name in rawMap.keys.sorted().prefix(maximumEntriesPerSource) {
                guard !seenNames.contains(name),
                      let raw = rawMap[name] as? [String: Any],
                      let config = sanitizedConfig(name: name, raw: raw) else { continue }
                seenNames.insert(name)
                result.append(McpDiscoveredServer(origin: source.origin, config: config))
            }
        }
        return result
    }

    private static func boundedData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0,
              size <= maximumFileBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= maximumFileBytes else { return nil }
        return data
    }

    private static func sanitizedConfig(name: String, raw: [String: Any]) -> McpServerConfig? {
        guard isSafeName(name), name != "kaisola", !containsLiteralSecret(raw) else { return nil }
        if let rawURL = raw["url"] as? String, !rawURL.isEmpty {
            let kind: McpServerConfig.Kind = (raw["type"] as? String) == "sse" ? .sse : .http
            let pairs = sanitizedPairs(raw["headers"], namesAreEnvironment: false)
            let config = McpServerConfig(name: name, kind: kind, url: rawURL, headerPairs: pairs, enabled: false)
            return config.validationError == nil ? config : nil
        }
        guard let command = raw["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= 512 else { return nil }
        let args = (raw["args"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .filter { $0.utf8.count <= 4_096 && !$0.contains("\0") }
            .prefix(64)
        let config = McpServerConfig(
            name: name,
            kind: .stdio,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines),
            args: Array(args),
            envPairs: sanitizedPairs(raw["env"], namesAreEnvironment: true),
            enabled: false
        )
        return config.validationError == nil ? config : nil
    }

    private static func sanitizedPairs(_ raw: Any?, namesAreEnvironment: Bool) -> [McpServerConfig.Pair] {
        guard let map = raw as? [String: Any] else { return [] }
        return map.keys.sorted().compactMap { name in
            guard let value = map[name] as? String,
                  value.utf8.count <= 4_096,
                  !value.contains("\0"),
                  validPairName(name, environment: namesAreEnvironment) else { return nil }
            return McpServerConfig.Pair(name: name, value: value)
        }.prefix(32).map { $0 }
    }

    private static func isSafeName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
    }

    private static func validPairName(_ value: String, environment: Bool) -> Bool {
        let pattern = environment
            ? #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#
            : #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsLiteralSecret(_ raw: [String: Any]) -> Bool {
        let sensitive = #"(?i)(authorization|api[-_]?key|token|secret|password|credential)"#
        let placeholder = #"(?i)^(Bearer\s+)?\$\{[A-Z_][A-Z0-9_]*\}$"#
        for field in ["env", "headers"] {
            guard let map = raw[field] as? [String: Any] else { continue }
            for (name, anyValue) in map {
                guard name.range(of: sensitive, options: .regularExpression) != nil,
                      let value = anyValue as? String,
                      !value.isEmpty else { continue }
                if value.range(of: placeholder, options: .regularExpression) == nil { return true }
            }
        }
        if let rawURL = raw["url"] as? String,
           let components = URLComponents(string: rawURL),
           components.user != nil || components.password != nil { return true }
        return false
    }

    /// Minimal bounded parser for Codex's documented `[mcp_servers.*]` shape.
    /// Unsupported TOML is ignored rather than guessed.
    private static func parseCodexMcpTOML(_ text: String) -> [String: Any] {
        struct Draft {
            var top: [String: Any] = [:]
            var env: [String: Any] = [:]
            var headers: [String: Any] = [:]
        }

        var drafts: [String: Draft] = [:]
        var activeName: String?
        var activeSection: String?
        let lines = text.prefix(maximumFileBytes).split(separator: "\n", maxSplits: 19_999, omittingEmptySubsequences: false)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let body = String(line.dropFirst().dropLast())
                guard body.hasPrefix("mcp_servers.") else {
                    activeName = nil
                    activeSection = nil
                    continue
                }
                var tail = String(body.dropFirst("mcp_servers.".count))
                activeSection = nil
                for suffix in [".env_http_headers", ".http_headers", ".env"] where tail.hasSuffix(suffix) {
                    tail.removeLast(suffix.count)
                    activeSection = String(suffix.dropFirst())
                    break
                }
                let name = tomlString(tail) ?? tail
                guard isSafeName(name) else {
                    activeName = nil
                    continue
                }
                activeName = name
                drafts[name, default: Draft()] = drafts[name, default: Draft()]
                continue
            }
            guard let activeName, let separator = line.firstIndex(of: "=") else { continue }
            let rawKey = line[..<separator].trimmingCharacters(in: .whitespaces)
            let key = tomlString(rawKey) ?? rawKey
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard let value = tomlValue(rawValue) else { continue }
            var draft = drafts[activeName, default: Draft()]
            switch activeSection {
            case "env":
                if value is String { draft.env[key] = value }
            case "http_headers":
                if value is String { draft.headers[key] = value }
            case "env_http_headers":
                if let variable = value as? String,
                   validPairName(variable, environment: true) {
                    draft.headers[key] = "${\(variable)}"
                }
            default:
                if ["command", "url", "type", "args", "bearer_token_env_var"].contains(key) {
                    draft.top[key] = value
                }
            }
            drafts[activeName] = draft
        }
        var servers: [String: Any] = [:]
        for (name, draft) in drafts {
            var raw = draft.top
            var headers = draft.headers
            if let variable = raw.removeValue(forKey: "bearer_token_env_var") as? String,
               validPairName(variable, environment: true) {
                headers["Authorization"] = "Bearer ${\(variable)}"
            }
            if !draft.env.isEmpty { raw["env"] = draft.env }
            if !headers.isEmpty { raw["headers"] = headers }
            servers[name] = raw
        }
        return ["mcpServers": servers]
    }

    private static func tomlString<S: StringProtocol>(_ raw: S) -> String? {
        let value = String(raw).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        }
        if value.hasPrefix("'"), value.hasSuffix("'") { return String(value.dropFirst().dropLast()) }
        return nil
    }

    private static func tomlValue<S: StringProtocol>(_ raw: S) -> Any? {
        let value = String(raw).trimmingCharacters(in: .whitespaces)
        if let string = tomlString(value) { return string }
        if value.hasPrefix("["), value.hasSuffix("]"),
           let array = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String] {
            return array
        }
        return nil
    }
}

// MARK: - Provider-facing MCP tool schemas

/// A tool rejected at the MCP -> provider boundary. The reason is deliberately
/// short and free of server payloads so Settings can surface it without letting
/// an untrusted schema flood the row or disclose arbitrary schema contents.
struct McpDisabledTool: Equatable, Sendable {
    let name: String
    let reason: String
}

/// Resolves the local-reference subset emitted by Zod, Pydantic, and similar
/// schema generators at Kaisola's owned `tools/list` boundary. The resulting
/// provider-facing subset is explicit: every assertion we accept is preserved,
/// while an unknown keyword, an unsafe reference, or an exhausted budget rejects
/// only that tool. This is intentionally not a permissive JSON Schema converter;
/// silently dropping an assertion would widen the tool's accepted input.
enum McpToolSchemaNormalizer {
    struct Limits: Equatable, Sendable {
        var maximumInputBytes = 128 * 1_024
        var maximumOutputBytes = 192 * 1_024
        var maximumDepth = 48
        var maximumNodes = 4_096
    }

    struct Result {
        let usable: [[String: Any]]
        let disabled: [McpDisabledTool]
    }

    private struct Rejection: Error {
        let reason: String
    }

    private struct Context {
        let root: [String: Any]
        let limits: Limits
        var visitedNodes = 0
        var activeReferences: Set<String> = []

        mutating func visit(depth: Int) throws {
            guard depth <= limits.maximumDepth else {
                throw Rejection(reason: "Schema depth budget exceeded.")
            }
            visitedNodes += 1
            guard visitedNodes <= limits.maximumNodes else {
                throw Rejection(reason: "Schema node budget exceeded.")
            }
        }

        mutating func normalize(_ schema: [String: Any], depth: Int) throws -> [String: Any] {
            try visit(depth: depth)
            if let rawReference = schema["$ref"] {
                guard let reference = rawReference as? String else {
                    throw Rejection(reason: "Schema reference must be a string.")
                }
                let permittedSiblings: Set<String> = [
                    "$ref", "$defs", "definitions", "$schema", "$comment",
                    "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly",
                ]
                if let unsupported = schema.keys.sorted().first(where: { !permittedSiblings.contains($0) }) {
                    throw Rejection(reason: boundedReason("Unsupported sibling of schema reference: \(unsupported)."))
                }
                let (target, canonicalReference) = try resolve(reference)
                guard activeReferences.insert(canonicalReference).inserted else {
                    throw Rejection(reason: "Schema reference cycle detected.")
                }
                defer { activeReferences.remove(canonicalReference) }
                guard let targetSchema = target as? [String: Any] else {
                    throw Rejection(reason: "Local schema reference must resolve to an object.")
                }
                var output = try normalize(targetSchema, depth: depth + 1)
                for key in schema.keys.sorted() where McpToolSchemaNormalizer.annotationKeys.contains(key) {
                    output[key] = try normalizeAnnotation(schema[key] as Any, key: key)
                }
                return output
            }

            var output: [String: Any] = [:]
            for key in schema.keys.sorted() {
                let value = schema[key] as Any
                switch key {
                case "$defs", "definitions", "$comment":
                    // Definitions are non-assertive after all local references
                    // have been inlined. Provider payloads do not need them.
                    continue
                case "$schema":
                    guard let dialect = value as? String,
                          McpToolSchemaNormalizer.acceptedDialects.contains(dialect) else {
                        throw Rejection(reason: "Unsupported JSON Schema dialect.")
                    }
                case "title", "description", "format", "pattern", "contentEncoding", "contentMediaType":
                    guard value is String else { throw invalidValue(key) }
                    output[key] = value
                case "default", "const":
                    guard JSONSerialization.isValidJSONObject([value]) else { throw invalidValue(key) }
                    output[key] = value
                case "examples", "enum":
                    guard let values = value as? [Any], !values.isEmpty,
                          JSONSerialization.isValidJSONObject(values) else { throw invalidValue(key) }
                    output[key] = values
                case "deprecated", "readOnly", "writeOnly", "uniqueItems":
                    guard value is Bool else { throw invalidValue(key) }
                    output[key] = value
                case "multipleOf", "maximum", "exclusiveMaximum", "minimum", "exclusiveMinimum",
                     "maxLength", "minLength", "maxItems", "minItems", "maxProperties", "minProperties":
                    guard McpToolSchemaNormalizer.isJSONNumber(value) else { throw invalidValue(key) }
                    output[key] = value
                case "type":
                    output[key] = try normalizeType(value)
                case "required":
                    guard let names = value as? [String], Set(names).count == names.count else {
                        throw invalidValue(key)
                    }
                    output[key] = names
                case "properties":
                    guard let properties = value as? [String: Any] else { throw invalidValue(key) }
                    var normalized: [String: Any] = [:]
                    for name in properties.keys.sorted() {
                        guard let property = properties[name] as? [String: Any] else { throw invalidValue(key) }
                        normalized[name] = try normalize(property, depth: depth + 1)
                    }
                    output[key] = normalized
                case "additionalProperties":
                    if value is Bool {
                        output[key] = value
                    } else if let nested = value as? [String: Any] {
                        output[key] = try normalize(nested, depth: depth + 1)
                    } else {
                        throw invalidValue(key)
                    }
                case "items", "not":
                    guard let nested = value as? [String: Any] else { throw invalidValue(key) }
                    output[key] = try normalize(nested, depth: depth + 1)
                case "anyOf", "oneOf", "allOf":
                    guard let alternatives = value as? [Any], !alternatives.isEmpty else { throw invalidValue(key) }
                    output[key] = try alternatives.map { alternative in
                        guard let nested = alternative as? [String: Any] else { throw invalidValue(key) }
                        return try normalize(nested, depth: depth + 1)
                    }
                default:
                    throw Rejection(reason: boundedReason("Unsupported schema keyword: \(key)."))
                }
            }
            return output
        }

        private mutating func normalizeAnnotation(_ value: Any, key: String) throws -> Any {
            switch key {
            case "title", "description":
                guard value is String else { throw invalidValue(key) }
            case "deprecated", "readOnly", "writeOnly":
                guard value is Bool else { throw invalidValue(key) }
            case "examples":
                guard let examples = value as? [Any], JSONSerialization.isValidJSONObject(examples) else {
                    throw invalidValue(key)
                }
            case "default":
                guard JSONSerialization.isValidJSONObject([value]) else { throw invalidValue(key) }
            default:
                throw invalidValue(key)
            }
            return value
        }

        private mutating func normalizeType(_ value: Any) throws -> Any {
            let accepted = McpToolSchemaNormalizer.acceptedTypes
            if let type = value as? String, accepted.contains(type) { return type }
            if let types = value as? [String], !types.isEmpty,
               Set(types).count == types.count,
               types.allSatisfy(accepted.contains) {
                return types
            }
            throw invalidValue("type")
        }

        private func resolve(_ reference: String) throws -> (Any, String) {
            guard reference == "#" || reference.hasPrefix("#/") else {
                throw Rejection(reason: "Only local schema references are supported.")
            }
            guard let fragment = String(reference.dropFirst()).removingPercentEncoding else {
                throw Rejection(reason: "Schema reference has invalid escaping.")
            }
            let rawTokens = fragment.isEmpty ? [] : fragment.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let tokens = try rawTokens.map(McpToolSchemaNormalizer.decodePointerToken)
            var value: Any = root
            for token in tokens {
                if let object = value as? [String: Any], let next = object[token] {
                    value = next
                } else if let array = value as? [Any],
                          token == "0" || (!token.hasPrefix("0") && token.allSatisfy(\.isNumber)),
                          let index = Int(token), array.indices.contains(index) {
                    value = array[index]
                } else {
                    throw Rejection(reason: "Missing local schema reference.")
                }
            }
            let canonicalData = try? JSONSerialization.data(withJSONObject: tokens, options: [.sortedKeys])
            return (value, canonicalData?.base64EncodedString() ?? reference)
        }
    }

    private static let annotationKeys: Set<String> = [
        "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly",
    ]
    private static let acceptedTypes: Set<String> = [
        "array", "boolean", "integer", "null", "number", "object", "string",
    ]
    private static let acceptedDialects: Set<String> = [
        "https://json-schema.org/draft/2020-12/schema",
        "https://json-schema.org/draft/2019-09/schema",
        "http://json-schema.org/draft-07/schema#",
        "https://json-schema.org/draft-07/schema",
    ]

    static func normalizeTools(_ tools: [Any], limits: Limits = Limits()) -> Result {
        var usable: [[String: Any]] = []
        var disabled: [McpDisabledTool] = []
        for (index, rawTool) in tools.enumerated() {
            let fallbackName = "Tool \(index + 1)"
            guard var tool = rawTool as? [String: Any] else {
                disabled.append(.init(name: fallbackName, reason: "Tool definition must be an object."))
                continue
            }
            let name = boundedToolName(tool["name"] as? String, fallback: fallbackName)
            do {
                guard let rawName = tool["name"] as? String,
                      !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      rawName.count <= 128,
                      !rawName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                    throw Rejection(reason: "Tool name is invalid.")
                }
                if let description = tool["description"], !(description is String) {
                    throw Rejection(reason: "Tool description must be a string.")
                }
                guard let schema = tool["inputSchema"] as? [String: Any] else {
                    throw Rejection(reason: "Tool input schema must be an object.")
                }
                let input = try stableData(schema)
                guard input.count <= limits.maximumInputBytes else {
                    throw Rejection(reason: "Schema byte budget exceeded.")
                }
                var context = Context(root: schema, limits: limits)
                let normalized = try context.normalize(schema, depth: 0)
                let output = try stableData(normalized)
                guard output.count <= limits.maximumOutputBytes else {
                    throw Rejection(reason: "Normalized schema byte budget exceeded.")
                }
                tool["inputSchema"] = normalized
                usable.append(tool)
            } catch let rejection as Rejection {
                disabled.append(.init(name: name, reason: boundedReason(rejection.reason)))
            } catch {
                disabled.append(.init(name: name, reason: "Invalid tool input schema."))
            }
        }
        return Result(usable: usable, disabled: disabled)
    }

    static func stableData(_ schema: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(schema) else {
            throw Rejection(reason: "Tool input schema is not valid JSON.")
        }
        return try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
    }

    private static func decodePointerToken(_ token: String) throws -> String {
        var output = ""
        var index = token.startIndex
        while index < token.endIndex {
            if token[index] != "~" {
                output.append(token[index])
                index = token.index(after: index)
                continue
            }
            let escape = token.index(after: index)
            guard escape < token.endIndex else {
                throw Rejection(reason: "Schema reference has invalid JSON Pointer escaping.")
            }
            switch token[escape] {
            case "0": output.append("~")
            case "1": output.append("/")
            default: throw Rejection(reason: "Schema reference has invalid JSON Pointer escaping.")
            }
            index = token.index(after: escape)
        }
        return output
    }

    private static func invalidValue(_ key: String) -> Rejection {
        Rejection(reason: boundedReason("Invalid value for schema keyword: \(key)."))
    }

    private static func isJSONNumber(_ value: Any) -> Bool {
        guard value is NSNumber else { return false }
        return !(value is Bool)
    }

    private static func boundedToolName(_ candidate: String?, fallback: String) -> String {
        let clean = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String((clean.isEmpty ? fallback : clean).prefix(80))
    }

    private static func boundedReason(_ reason: String) -> String {
        let singleLine = reason.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(singleLine.prefix(160))
    }
}

// MARK: - Non-executing health probe

struct McpProbeResult: Equatable, Sendable {
    enum Status: String, Sendable {
        case configured
        case ready
        case failed
    }

    let status: Status
    let verified: Bool
    let message: String
    var serverName: String?
    var serverVersion: String?
    var toolCount: Int?
    var hasMoreTools = false
    var disabledTools: [McpDisabledTool] = []
}

/// Pure MCP `initialize` revision negotiation: given the server's reply,
/// decide whether this probe can speak that revision. Per the MCP spec a
/// server may legitimately answer with an older revision it supports
/// instead of the one requested — the client should accept any revision
/// it can itself speak rather than demanding an exact echo of what it
/// asked for. Kept free of the actor's networking so it's a synchronous,
/// directly testable function; the previous exact-match check pinned to
/// `2025-06-18` and rejected the `2025-11-25` reply every SDK ≥1.19
/// server sends, surfacing "Unsupported protocol version" for servers
/// that work fine (real traffic goes through the ACP adapter's bundled
/// MCP SDK 1.30.0, which already speaks both revisions).
enum McpProtocolRevision {
    /// Requested in the probe's `initialize` call — the newest revision
    /// current servers and the ACP adapter's bundled MCP SDK speak.
    static let requested = "2025-11-25"

    /// Every revision this probe can correctly speak, most-preferred
    /// first. A reply outside this set is genuinely unsupported.
    static let accepted: [String] = ["2025-11-25", "2025-06-18"]

    /// Whether `reply` (the server's `initialize` `result.protocolVersion`)
    /// is a revision this probe can speak.
    static func isAccepted(_ reply: String?) -> Bool {
        guard let reply, !reply.isEmpty else { return false }
        return accepted.contains(reply)
    }
}

/// Settings health checks intentionally never launch stdio servers. Remote
/// Streamable HTTP endpoints are verified against the MCP lifecycle with tight
/// request/response bounds; legacy SSE remains agent-session verified.
actor McpProbeService {
    static let shared = McpProbeService(session: URLSession(
        configuration: .ephemeral,
        delegate: McpNoRedirectSessionDelegate(),
        delegateQueue: nil
    ))

    private struct RPCReply {
        let object: [String: Any]?
        let sessionID: String?
    }

    private enum ProbeFailure: Error {
        case message(String)
    }

    private static let maximumResponseBytes = 200_000
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func probe(_ server: McpServerConfig) async -> McpProbeResult {
        guard server.validationError == nil else {
            return .init(status: .failed, verified: true, message: "Invalid server configuration")
        }
        switch server.kind {
        case .stdio:
            return .init(
                status: .configured,
                verified: false,
                message: "Configured · verified when a new agent session starts"
            )
        case .sse:
            return .init(
                status: .configured,
                verified: false,
                message: "Legacy SSE · verified when an agent session connects"
            )
        case .http:
            return await probeHTTP(server)
        }
    }

    private func probeHTTP(_ server: McpServerConfig) async -> McpProbeResult {
        guard let rawURL = server.url, let url = URL(string: rawURL) else {
            return .init(status: .failed, verified: true, message: "Invalid server URL")
        }
        do {
            let initialize = try await post(
                url: url,
                configuredHeaders: server.headerPairs,
                payload: [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "protocolVersion": McpProtocolRevision.requested,
                        "capabilities": [:],
                        "clientInfo": [
                            "name": "kaisola",
                            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                        ],
                    ],
                ],
                sessionID: nil,
                negotiatedVersion: nil,
                allowEmpty: false
            )
            guard let response = initialize.object else { throw ProbeFailure.message("Empty initialize response") }
            if let error = response["error"] as? [String: Any] {
                throw ProbeFailure.message("Initialize failed: \(safeServerMessage(error["message"]))")
            }
            guard let result = response["result"] as? [String: Any],
                  let negotiated = result["protocolVersion"] as? String else {
                throw ProbeFailure.message("Malformed initialize response")
            }
            guard McpProtocolRevision.isAccepted(negotiated) else {
                throw ProbeFailure.message("Unsupported protocol version \(safeInline(negotiated))")
            }
            let info = result["serverInfo"] as? [String: Any]
            let serverName = safeOptionalInline(info?["name"] as? String)
            let serverVersion = safeOptionalInline(info?["version"] as? String)
            let capabilities = result["capabilities"] as? [String: Any]
            let supportsTools = capabilities?["tools"] is [String: Any]

            _ = try await post(
                url: url,
                configuredHeaders: server.headerPairs,
                payload: [
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                    "params": [:],
                ],
                sessionID: initialize.sessionID,
                negotiatedVersion: negotiated,
                allowEmpty: true
            )

            guard supportsTools else {
                return .init(
                    status: .ready,
                    verified: true,
                    message: "Ready · server declares no tools capability",
                    serverName: serverName,
                    serverVersion: serverVersion
                )
            }
            let tools = try await post(
                url: url,
                configuredHeaders: server.headerPairs,
                payload: [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/list",
                    "params": [:],
                ],
                sessionID: initialize.sessionID,
                negotiatedVersion: negotiated,
                allowEmpty: false
            )
            guard let toolsResponse = tools.object else { throw ProbeFailure.message("Empty tools response") }
            if let error = toolsResponse["error"] as? [String: Any] {
                throw ProbeFailure.message("Tool listing failed: \(safeServerMessage(error["message"]))")
            }
            guard let toolsResult = toolsResponse["result"] as? [String: Any],
                  let listedTools = toolsResult["tools"] as? [Any] else {
                throw ProbeFailure.message("Malformed tools response")
            }
            let hasMore = toolsResult["nextCursor"] is String
            let normalized = McpToolSchemaNormalizer.normalizeTools(listedTools)
            return .init(
                status: .ready,
                verified: true,
                message: toolSummary(
                    usable: normalized.usable.count,
                    advertised: listedTools.count,
                    disabled: normalized.disabled,
                    hasMore: hasMore
                ),
                serverName: serverName,
                serverVersion: serverVersion,
                toolCount: normalized.usable.count,
                hasMoreTools: hasMore,
                disabledTools: normalized.disabled
            )
        } catch let ProbeFailure.message(message) {
            return .init(status: .failed, verified: true, message: message)
        } catch let error as URLError where error.code == .timedOut {
            return .init(status: .failed, verified: true, message: "Timed out after 3.5 seconds")
        } catch {
            return .init(status: .failed, verified: true, message: "Connection failed")
        }
    }

    private func post(
        url: URL,
        configuredHeaders: [McpServerConfig.Pair],
        payload: [String: Any],
        sessionID: String?,
        negotiatedVersion: String?,
        allowEmpty: Bool
    ) async throws -> RPCReply {
        var request = URLRequest(url: url, timeoutInterval: 3.5)
        request.httpMethod = "POST"
        let reserved = Set(["content-type", "accept", "mcp-session-id", "mcp-protocol-version"])
        for header in configuredHeaders where !reserved.contains(header.name.lowercased()) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProbeFailure.message("Non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw ProbeFailure.message("Server returned HTTP \(http.statusCode)")
        }
        guard data.count <= Self.maximumResponseBytes else { throw ProbeFailure.message("Response exceeded 200 KB") }
        let sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID
        guard !data.isEmpty else {
            if allowEmpty { return RPCReply(object: nil, sessionID: sessionID) }
            throw ProbeFailure.message("Empty server response")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let object: Any
        if contentType.localizedCaseInsensitiveContains("text/event-stream") {
            guard let eventData = lastSSEData(in: data) else { throw ProbeFailure.message("Invalid SSE response") }
            object = try JSONSerialization.jsonObject(with: eventData)
        } else {
            object = try JSONSerialization.jsonObject(with: data)
        }
        guard let dictionary = object as? [String: Any] else { throw ProbeFailure.message("Non-object JSON response") }
        return RPCReply(object: dictionary, sessionID: sessionID)
    }

    private func lastSSEData(in data: Data) -> Data? {
        let body = String(decoding: data, as: UTF8.self)
        let events = body.components(separatedBy: "\n\n")
        for event in events.reversed() {
            let payload = event.split(whereSeparator: \.isNewline)
                .compactMap { line -> String? in
                    guard line.hasPrefix("data:") else { return nil }
                    return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
                .joined(separator: "\n")
            if !payload.isEmpty, payload != "[DONE]" { return Data(payload.utf8) }
        }
        return nil
    }

    private func safeServerMessage(_ value: Any?) -> String {
        guard let value = value as? String else { return "server error" }
        return safeInline(value)
    }

    private func safeOptionalInline(_ value: String?) -> String? {
        guard let value else { return nil }
        let safe = safeInline(value)
        return safe.isEmpty ? nil : safe
    }

    private func safeInline(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(160))
    }

    private func toolSummary(
        usable: Int,
        advertised: Int,
        disabled: [McpDisabledTool],
        hasMore: Bool
    ) -> String {
        guard let first = disabled.first else {
            return hasMore ? "Ready · \(usable)+ tools" : "Ready · \(usable) tools"
        }
        let moreDisabled = disabled.count > 1 ? " +\(disabled.count - 1) more" : ""
        let advertisedText = hasMore ? "\(advertised)+" : "\(advertised)"
        let message = "Ready · \(usable) usable of \(advertisedText) tools · \(disabled.count) disabled (\(first.name): \(first.reason)\(moreDisabled))"
        return String(message.prefix(240))
    }
}

/// A configured authorization header must never ride an HTTP redirect to a
/// different endpoint. Users can review and save the new canonical URL instead.
private final class McpNoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
