import Foundation

/// How to spawn an ACP adapter for a given agent. The native app runs the
/// adapter through `npx` so it always resolves the LATEST published package
/// unless a pinned path is provided — matching the "always current" policy the
/// version updater enforces. A login shell recovers the user's PATH exactly as
/// Electron does when spawning agents.
struct AcpAdapter: Equatable, Sendable {
    let command: String
    let arguments: [String]

    /// Resolve the adapter for an agent id (AgentRegistry ids). Returns nil for
    /// agents with no ACP adapter. `packageOverride` lets the version updater
    /// pin an exact resolved binary; otherwise `npx -y <pkg>@latest` is used.
    static func forAgent(
        _ agentID: String,
        packageOverride: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AcpAdapter? {
        // A dev/test override spawns an arbitrary adapter command (e.g. the mock
        // agent) instead of the published package, so chats can be exercised
        // offline. Format: "<executable>\t<arg>\t<arg>…".
        if let override = environment["KAISOLA_ACP_ADAPTER_OVERRIDE"], !override.isEmpty {
            let parts = override.split(separator: "\t").map(String.init)
            if let command = parts.first {
                return AcpAdapter(command: command, arguments: Array(parts.dropFirst()))
            }
        }
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let package: String
        switch agentID {
        case "claude-code": package = "@agentclientprotocol/claude-agent-acp@latest"
        case "codex": package = "@agentclientprotocol/codex-acp@latest"
        default:
            // Custom agents reach chat only through an explicitly enabled,
            // pinned, integrity-verified install — never through `npx` and a
            // mutable tag. Built-in ids never fall through to here, so the
            // shipped adapters above are untouched (review finding 4).
            return forCustomAgent(agentID, shell: shell)
        }
        let resolved = packageOverride ?? package
        // -ilc keeps the interactive login environment; the ACP adapter then
        // owns stdio for JSON-RPC.
        return AcpAdapter(command: shell, arguments: ["-ilc", "exec npx -y \(resolved)"])
    }

    /// The custom-agent path: the roster says chat is enabled, and the
    /// recorded install still verifies (review finding 2 — approval is
    /// durable because what runs is exactly what was approved). The spawned
    /// command is the resolved executable itself; the login shell is only for
    /// PATH, so a JS adapter's `node` shebang resolves.
    static func forCustomAgent(
        _ agentID: String,
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        store: CustomAgentStore = CustomAgentStore(),
        installs: AdapterInstallManager = AdapterInstallManager()
    ) -> AcpAdapter? {
        guard let spec = store.all().first(where: { $0.id == agentID }),
              spec.chatEnabled == true,
              spec.acpPackage?.isEmpty == false,
              spec.acpPackageValidationError == nil,
              case let .verified(binURL) = installs.verify(agentID: agentID) else {
            return nil
        }
        let quoted = "'" + binURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return AcpAdapter(command: shell, arguments: ["-ilc", "exec \(quoted)"])
    }
}
