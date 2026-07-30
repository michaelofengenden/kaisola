import Foundation

/// A user-registered terminal agent — any CLI the user wants in the New menu
/// beyond the built-in roster (Electron Settings ▸ Agents parity). Terminal-only
/// by construction: it carries no ACP adapter, so it always launches into an
/// owned terminal rather than the chat surface.
struct CustomAgentSpec: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var launchCommand: String
    var symbol: String
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
    func save(_ specs: [CustomAgentSpec]) {
        let capped = specs.count > cap ? Array(specs.prefix(cap)) : specs
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
    /// with no alphanumerics — falls back to "custom-agent". Collision suffixing is
    /// intentionally not applied, so two identically named agents share an id.
    static func slugify(_ name: String) -> String {
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
        return slug.isEmpty ? "custom-agent" : "custom-\(slug)"
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
