import Foundation

/// Persists standing ACP permission allow-rules to the native application-support
/// directory (never Electron's), atomic writes, corrupt-file → empty. Rules are
/// workspace-scoped and capped so a runaway agent can't grow the file unbounded.
/// Mutations take an exclusive file lock so two windows — or two processes —
/// answering permission asks at once can't lose one another's rule.
struct PermissionRuleStore: Sendable {
    private struct Payload: Codable {
        var rules: [PermissionRule]
    }

    let fileURL: URL
    private let cap = 200
    /// How long a mutation waits for another holder before giving up on the lock
    /// and mutating anyway. A holder keeps it for one read-modify-write, so the
    /// wait is normally invisible; the ceiling is here because callers mutate
    /// from the main thread and a foreign holder must never wedge the UI.
    private let lockTimeout: TimeInterval = 2

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
        withMutationLock {
            // Re-read under the lock: the generation this decision was rendered
            // against may be several windows out of date by now.
            var rules = read()?.rules ?? []
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
    }

    func remove(id: String) {
        withMutationLock {
            var rules = read()?.rules ?? []
            rules.removeAll { $0.id == id }
            write(Payload(rules: rules))
        }
    }

    /// Serializes read-modify-write mutations across threads, windows and
    /// processes. The lock lives on a sidecar file because the atomic write
    /// swaps the rules file's inode, which would strand a lock taken on the
    /// file itself. Best-effort: when no descriptor is available, or a holder
    /// outlasts `lockTimeout`, the mutation still runs rather than being lost.
    private func withMutationLock<T>(_ body: () -> T) -> T {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockPath = directory.appendingPathComponent(".\(fileURL.lastPathComponent).lock").path
        let descriptor = open(lockPath, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return body() }
        var locked = false
        let deadline = Date().addingTimeInterval(lockTimeout)
        while !locked {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                locked = true
            } else if (errno == EWOULDBLOCK || errno == EINTR) && Date() < deadline {
                usleep(2_000)
            } else {
                break
            }
        }
        defer {
            if locked { flock(descriptor, LOCK_UN) }
            close(descriptor)
        }
        return body()
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
        // Unique per write: two writers that skipped the lock must not share a
        // scratch path and interleave into one another's bytes.
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString.prefix(8))"
        )
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
