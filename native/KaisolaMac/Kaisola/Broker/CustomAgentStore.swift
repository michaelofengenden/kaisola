import Foundation

/// A user-registered terminal agent — any CLI the user wants in the New menu
/// beyond the built-in roster (Electron Settings ▸ Agents parity).
///
/// Terminal-only by default. A spec may additionally declare an ACP adapter
/// package and a credential context, and — after the user explicitly enables
/// it and the adapter is resolved into a pinned, integrity-checked install
/// (`AdapterInstallManager`) — reach the chat surface. All three fields are
/// additive optionals: every legacy roster entry decodes with them absent,
/// which reads as terminal-only and chat-disabled (the adversarial review's
/// finding 4 — a missing enablement flag must never decode as enabled).
enum CustomAdapterPrivilege: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    /// Permit outbound IP connections. Unix-domain sockets, listeners, and
    /// inbound connections remain outside the boundary.
    case network
    /// Permit direct adapter reads in the current session workspace. The ACP
    /// fs bridge is gated by the same declaration.
    case workspaceRead
    /// Permit direct adapter writes in the current session workspace. The ACP
    /// fs bridge is gated separately from reads, so this does not imply read.
    case workspaceWrite
    /// Permit child processes inside the same Seatbelt profile. Kaisola's host
    /// terminal bridge remains unavailable to custom adapters because it would
    /// otherwise escape both the sandbox and the minimal environment.
    case childProcess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: "Outbound network"
        case .workspaceRead: "Read workspace"
        case .workspaceWrite: "Write workspace"
        case .childProcess: "Spawn child processes"
        }
    }

    var reviewDetail: String {
        switch self {
        case .network: "remote IP plus required macOS resolver/network services; forwards enabled HTTP/SSE MCP definitions and their configured headers"
        case .workspaceRead: "direct reads plus ACP read_text_file in this session's workspace"
        case .workspaceWrite: "direct writes plus ACP write_text_file in this session's workspace"
        case .childProcess: "subprocesses inherit the sandbox and allowlist; enabled stdio MCP definitions include their configured environment values"
        }
    }
}

/// The exact containment grant captured with an installed adapter. The policy
/// version makes a future boundary change an approval change rather than a
/// silent widening. Stored strings keep older readers and unknown future
/// values fail-closed instead of making the entire roster undecodable.
struct CustomAdapterApproval: Codable, Equatable, Hashable, Sendable {
    static let currentBoundaryVersion = 1

    let boundaryVersion: Int
    let credentials: String
    let privileges: [String]

    init(
        credentials: CustomAgentSpec.Credentials,
        privileges: Set<CustomAdapterPrivilege>,
        boundaryVersion: Int = currentBoundaryVersion
    ) {
        self.boundaryVersion = boundaryVersion
        self.credentials = credentials.rawValue
        self.privileges = CustomAdapterPrivilege.allCases
            .filter(privileges.contains)
            .map(\.rawValue)
    }

    var resolvedCredentials: CustomAgentSpec.Credentials? {
        CustomAgentSpec.Credentials(rawValue: credentials)
    }

    var resolvedPrivileges: Set<CustomAdapterPrivilege>? {
        let values = privileges.compactMap(CustomAdapterPrivilege.init(rawValue:))
        guard values.count == privileges.count,
              Set(privileges).count == privileges.count else { return nil }
        return Set(values)
    }

    var isCurrentAndValid: Bool {
        boundaryVersion == Self.currentBoundaryVersion
            && resolvedCredentials != nil
            && resolvedPrivileges != nil
    }

    var reviewSummary: String {
        let access = resolvedPrivileges.map { privileges in
            CustomAdapterPrivilege.allCases
                .filter(privileges.contains)
                .map(\.title)
                .joined(separator: ", ")
        } ?? "Invalid access declaration"
        let accessSummary = access.isEmpty ? "No workspace, network, or process access" : access
        let credentialSummary = resolvedCredentials?.title ?? "Unknown credential context"
        return "\(accessSummary) · \(credentialSummary)"
    }
}

struct CustomAgentSpec: Codable, Equatable, Identifiable, Sendable {
    /// Whose credentials a chat with this agent uses — declared data, never
    /// inferred from an id or a package name (review finding 3).
    enum Credentials: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The Claude account bindings (CLAUDE_CONFIG_DIR profiles).
        case claude
        /// The Codex account bindings (CODEX_HOME profiles).
        case codex
        /// No provider identity: chats open with no account binding and no
        /// resumable provider continuation.
        case none

        var id: String { rawValue }
        var title: String {
            switch self {
            case .claude: "Claude accounts"
            case .codex: "Codex accounts"
            case .none: "No provider account"
            }
        }
    }

    var id: String
    var name: String
    var launchCommand: String
    var symbol: String
    /// npm registry package (optionally `@version`) for this agent's ACP
    /// adapter. Registry names only — never a path, git ref, or URL.
    var acpPackage: String?
    /// Raw `Credentials` value; absent means `.none`.
    var credentials: String?
    /// Whether the user has explicitly enabled the chat surface for this
    /// agent. Enablement is only honored when a verified install exists.
    var chatEnabled: Bool?
    /// Closed, explicitly reviewed containment privileges. Missing means a
    /// legacy entry that has never reviewed the sandbox contract and therefore
    /// cannot launch chat. Empty is a valid explicit least-privilege grant.
    var acpPrivileges: [String]? = nil

    var resolvedCredentials: Credentials {
        credentials.flatMap(Credentials.init) ?? .none
    }

    /// The declaration used for containment approval. A missing legacy value
    /// still means credential-free, but an unknown non-nil value must not be
    /// silently collapsed to `.none`: a future credential kind could otherwise
    /// widen an old approval without another review.
    private var declaredCredentials: Credentials? {
        guard let credentials else { return Credentials.none }
        return Credentials(rawValue: credentials)
    }

    var containmentApproval: CustomAdapterApproval? {
        guard let acpPrivileges, let declaredCredentials else { return nil }
        let parsed = acpPrivileges.compactMap(CustomAdapterPrivilege.init(rawValue:))
        guard parsed.count == acpPrivileges.count,
              Set(acpPrivileges).count == acpPrivileges.count else { return nil }
        return CustomAdapterApproval(
            credentials: declaredCredentials,
            privileges: Set(parsed)
        )
    }

    var containmentIssue: String? {
        if let credentials, Credentials(rawValue: credentials) == nil {
            return "The credential context is unknown; choose it again before enabling chat."
        }
        guard let acpPrivileges else {
            return "Review this adapter's contained access before enabling chat."
        }
        if Set(acpPrivileges).count != acpPrivileges.count {
            return "The contained-access declaration repeats a privilege; review it again."
        }
        let unknown = acpPrivileges.filter { CustomAdapterPrivilege(rawValue: $0) == nil }
        if !unknown.isEmpty {
            return "The contained-access declaration has unknown privileges: \(unknown.joined(separator: ", "))."
        }
        return nil
    }

    /// Why the declared ACP package can never be installed, or nil when the
    /// declaration is usable (or absent).
    var acpPackageValidationError: String? {
        guard let package = acpPackage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !package.isEmpty else { return nil }
        return Self.packageNameError(package)
    }

    /// npm-registry package shape: optional scope, name, optional version tag.
    /// Anything path-like, URL-like, or shell-hostile is refused by name.
    static func packageNameError(_ package: String) -> String? {
        if package.count > 214 { return "The package name exceeds npm's 214-character limit." }
        if package.contains("://") || package.hasPrefix(".") || package.hasPrefix("/")
            || package.contains("..") {
            return "Only npm registry package names are allowed — no paths, URLs, or git references."
        }
        let pattern = #"^(@[a-z0-9~][a-z0-9-._~]*\/)?[a-z0-9~][a-z0-9-._~]*(@[A-Za-z0-9-._^~<>=]+)?$"#
        if package.range(of: pattern, options: .regularExpression) == nil {
            return "\"\(package)\" is not an npm registry package name."
        }
        return nil
    }
}

/// Persists the user's custom agents to the native application-support directory
/// (never Electron's). Atomic writes, corrupt file → empty, capped — mirroring
/// `SessionPinStore`/`PermissionRuleStore`.
struct CustomAgentStore: Sendable {
    private struct Payload: Codable {
        var agents: [CustomAgentSpec]
    }

    let fileURL: URL
    /// A deliberately small ceiling: the New menu is a launcher, not a registry.
    private let cap = 12

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("custom-agents.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// The stored custom agents, in insertion order. Corrupt file → empty.
    func all() -> [CustomAgentSpec] {
        read()?.agents ?? []
    }

    /// Replace the stored set. Keeps the first `cap` entries if handed more, so
    /// the file can never grow unbounded even if a caller ignores the ceiling.
    /// Duplicate ids keep only their first row: an id is a contract key, and
    /// a second row under it could cross packages and credentials.
    func save(_ specs: [CustomAgentSpec]) {
        var seen = Set<String>()
        let unique = specs.filter { seen.insert($0.id).inserted }
        let capped = unique.count > cap ? Array(unique.prefix(cap)) : unique
        write(Payload(agents: capped))
    }

    /// Map each spec into an `AgentProfile` for `AgentRegistry`. An empty symbol
    /// falls back to "terminal" so the session row always has a glyph.
    func asProfiles() -> [AgentProfile] {
        all().map { spec in
            AgentProfile(
                id: spec.id,
                name: spec.name,
                launchCommand: spec.launchCommand,
                symbol: spec.symbol.isEmpty ? "terminal" : spec.symbol
            )
        }
    }

    /// Derive a stable, filesystem-safe id from a display name: lowercased, ASCII
    /// alphanumerics kept, every other run collapsed to a single dash, leading and
    /// trailing dashes trimmed, then "custom-" prefixed. Empty input — or a name
    /// with no alphanumerics — falls back to "custom-agent".
    ///
    /// Collision suffixing IS applied when `existing` ids are handed in: an id
    /// is a credential and package contract now (chat enablement binds to it),
    /// so two agents sharing one silently cross those contracts — the
    /// adversarial review's finding 2.
    static func slugify(_ name: String, existing: Set<String> = []) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var slug = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if allowed.contains(character) {
                slug.append(character)
                lastWasDash = false
            } else if !slug.isEmpty && !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        let base = slug.isEmpty ? "custom-agent" : "custom-\(slug)"
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func write(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
