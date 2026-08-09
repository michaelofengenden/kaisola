import Foundation

/// How to spawn an ACP adapter for a given agent. The native app runs the
/// adapter through `npx` so it always resolves the LATEST published package
/// unless a pinned path is provided — matching the "always current" policy the
/// version updater enforces. A login shell recovers the user's PATH exactly as
/// Electron does when spawning agents.
struct AcpAdapter: Equatable, Sendable {
    let command: String
    let arguments: [String]
    /// Present only for user-installed adapters. Built-ins keep their shipped
    /// launch behavior; custom code must cross this boundary as one atomic
    /// command/environment/access plan.
    let containment: CustomAdapterContainment?

    init(
        command: String,
        arguments: [String],
        containment: CustomAdapterContainment? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.containment = containment
    }

    func prepare(environment: [String: String], cwd: String) throws -> AcpAdapterLaunch {
        if let containment {
            return try containment.prepare(environment: environment, cwd: cwd)
        }
        return AcpAdapterLaunch(
            command: command,
            arguments: arguments,
            environment: environment,
            cwd: cwd,
            access: .unrestricted,
            sandboxProfile: nil
        )
    }

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
        //
        // Honored ONLY inside a test or fixture process: an inherited
        // production environment variable must never be able to make every
        // agent chat-capable and run an arbitrary command (adversarial
        // review, finding 4).
        if let override = environment["KAISOLA_ACP_ADAPTER_OVERRIDE"], !override.isEmpty,
           environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
               || environment["XCTestConfigurationFilePath"] != nil
               || environment["XCTestBundlePath"] != nil {
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
            return forCustomAgent(agentID)
        }
        let resolved = packageOverride ?? package
        // -ilc keeps the interactive login environment; the ACP adapter then
        // owns stdio for JSON-RPC.
        return AcpAdapter(command: shell, arguments: ["-ilc", "exec npx -y \(resolved)"])
    }

    /// The custom-agent path: the roster says chat is enabled, and the
    /// recorded install still verifies (review finding 2 — approval is
    /// durable because what runs is exactly what was approved). The spawned
    /// command is the integrity-verified executable under Kaisola's sealed Node
    /// runtime. No login shell or inherited PATH participates in the launch.
    static func forCustomAgent(
        _ agentID: String,
        store: CustomAgentStore = CustomAgentStore(),
        installs: AdapterInstallManager = AdapterInstallManager()
    ) -> AcpAdapter? {
        guard case let .success(specs) = store.load(),
              let spec = specs.first(where: { $0.id == agentID }),
              spec.chatEnabled == true,
              let package = spec.acpPackage, !package.isEmpty,
              spec.acpPackageValidationError == nil,
              let approval = spec.containmentApproval,
              // `expectedPackage` binds the install record to *this* spec's
              // declaration — an approval recorded for a different package
              // (or a duplicate-id sibling) never satisfies it.
              case let .verified(binURL, installRecord) = installs.verify(
                  agentID: agentID,
                  expectedPackage: package.trimmingCharacters(in: .whitespacesAndNewlines),
                  expectedApproval: approval
              ) else {
            return nil
        }
        let containment = CustomAdapterContainment(
            agentID: agentID,
            executableURL: binURL,
            installRoot: installs.installRoot(agentID: agentID),
            approval: approval,
            installRecord: installRecord
        )
        return AcpAdapter(
            command: "/usr/bin/sandbox-exec",
            arguments: ["<sealed-node>", binURL.path],
            containment: containment
        )
    }
}
