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
struct CustomAgentSpec: Codable, Equatable, Identifiable {
    /// Whose credentials a chat with this agent uses — declared data, never
    /// inferred from an id or a package name (review finding 3).
    enum Credentials: String, Codable, CaseIterable, Identifiable {
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

    var resolvedCredentials: Credentials {
        credentials.flatMap(Credentials.init) ?? .none
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
