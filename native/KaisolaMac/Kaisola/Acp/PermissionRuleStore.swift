import Foundation

/// Persists standing ACP permission allow-rules to the native application-support
/// directory (never Electron's), atomic writes, corrupt-file → empty. Rules are
/// workspace-scoped and capped so a runaway agent can't grow the file unbounded.
struct PermissionRuleStore: Sendable {
    private struct Payload: Codable {
        var rules: [PermissionRule]
    }

    let fileURL: URL
    private let cap = 200

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("permission-rules.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    func rules() -> [PermissionRule] {
        read()?.rules ?? []
    }

    /// Add a rule (idempotent by workspace+action+resource). Returns the rule set
    /// after the add.
    @discardableResult
    func add(_ rule: PermissionRule) -> [PermissionRule] {
        var rules = self.rules()
        let exists = rules.contains {
            $0.workspace == rule.workspace && $0.action == rule.action && $0.resource == rule.resource
        }
        if !exists {
            rules.append(rule)
            if rules.count > cap { rules.removeFirst(rules.count - cap) }
            write(Payload(rules: rules))
        }
        return rules
    }

    func remove(id: String) {
        var rules = self.rules()
        rules.removeAll { $0.id == id }
        write(Payload(rules: rules))
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
