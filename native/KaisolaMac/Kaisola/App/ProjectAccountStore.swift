import Foundation

/// A per-project account override: a CLAUDE_CONFIG_DIR / CODEX_HOME that a single
/// project's agent terminals, chats, and Mesh use instead of the app-wide
/// account. Either field may be nil (fall back to the app default for that CLI).
/// Values are stored as the user typed them (trimmed, empty collapsed to nil) and
/// only tilde-expanded when the process environment is built, so the settings
/// field can show "~/…" back to the user.
struct ProjectAccountOverride: Codable, Equatable {
    var claudeConfigDir: String?
    var codexHome: String?

    /// A copy with each field trimmed and empty strings collapsed to nil.
    func normalized() -> ProjectAccountOverride {
        ProjectAccountOverride(
            claudeConfigDir: ProjectAccountOverride.clean(claudeConfigDir),
            codexHome: ProjectAccountOverride.clean(codexHome)
        )
    }

    /// True when neither field carries a usable (non-blank) value.
    var isEmpty: Bool {
        ProjectAccountOverride.clean(claudeConfigDir) == nil
            && ProjectAccountOverride.clean(codexHome) == nil
    }

    /// Trim whitespace/newlines; a blank result becomes nil ("no override").
    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Persists per-project account overrides — `[projectID: ProjectAccountOverride]`
/// — in the native application-support directory (never Electron's). Atomic
/// writes, corrupt file → empty, mirroring `SessionPinStore` / `PermissionRuleStore`.
/// This is the native analog of Electron's per-project CLAUDE_CONFIG_DIR /
/// CODEX_HOME isolation: the app-wide account (NativePreviewSettings) is the
/// default, and a project may pin its own account directories on top.
struct ProjectAccountStore: Sendable {
    private struct Payload: Codable {
        var projects: [String: ProjectAccountOverride]
    }

    let fileURL: URL

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("project-accounts.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// The stored override for a project, or nil when the project has none.
    func override(forProject projectID: String) -> ProjectAccountOverride? {
        read()?.projects[projectID]
    }

    /// Set (or clear) a project's override. Passing nil — or an override whose
    /// fields are all blank after trimming — removes the entry entirely. Stored
    /// values are normalized (trimmed, empty → nil). Idempotent: nothing is
    /// written when the persisted value already matches.
    func set(_ override: ProjectAccountOverride?, forProject projectID: String) {
        let normalized = override.flatMap { $0.isEmpty ? nil : $0.normalized() }
        var payload = read() ?? Payload(projects: [:])
        guard payload.projects[projectID] != normalized else { return }
        if let normalized {
            payload.projects[projectID] = normalized
        } else {
            payload.projects.removeValue(forKey: projectID)
        }
        write(payload)
    }

    /// Merge a project's override onto the app-wide environment overlay. Pure and
    /// order-independent: the app overlay is the base, and each project value
    /// (tilde-expanded, trimmed, non-empty) WINS for its key. A nil, blank, or
    /// whitespace-only project value falls back to whatever the app overlay
    /// carries for that key.
    static func mergedOverlay(app: [String: String], project: ProjectAccountOverride?) -> [String: String] {
        var env = app
        if let value = expandedPath(project?.claudeConfigDir) { env["CLAUDE_CONFIG_DIR"] = value }
        if let value = expandedPath(project?.codexHome) { env["CODEX_HOME"] = value }
        return env
    }

    /// Trim, drop-if-blank, then expand a leading "~" to the home directory.
    private static func expandedPath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
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
