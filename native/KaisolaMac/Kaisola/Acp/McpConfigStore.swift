import Foundation
import KaisolaCore

/// One configured MCP server, scoped to a workspace. `id` is the `name`, so a
/// workspace can hold at most one server per name (mirroring the Node registry's
/// unique-id contract). `command`/`args`/`envPairs` describe a `stdio` server;
/// `url`/`headerPairs` describe an `http`/`sse` server. Only the fields relevant
/// to `kind` are consumed by `McpConfigStore.jsonValues`.
struct McpServerConfig: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case stdio, http, sse
    }

    /// A `{name,value}` pair — an environment variable for a stdio server, or an
    /// HTTP header for an http/sse server. Matches the Node registry's `toPairs`
    /// output shape exactly.
    struct Pair: Codable, Equatable {
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
        guard Self.safeRequired(cleanName) else { return "Name is required and cannot contain line breaks." }
        guard envPairs.allSatisfy(Self.safePair), headerPairs.allSatisfy(Self.safePair) else {
            return "Environment and header names cannot be empty or contain line breaks."
        }
        switch kind {
        case .stdio:
            guard let command, Self.safeRequired(command.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return "A valid command is required."
            }
        case .http, .sse:
            guard let url, let components = URLComponents(string: url),
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

    private static func safePair(_ pair: Pair) -> Bool {
        safeRequired(pair.name.trimmingCharacters(in: .whitespacesAndNewlines))
            && !pair.value.contains("\0")
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
        return payload.servers.filter { $0.validationError == nil }
    }

    func save(_ servers: [McpServerConfig]) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let validated = servers.filter { $0.validationError == nil }
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
}
