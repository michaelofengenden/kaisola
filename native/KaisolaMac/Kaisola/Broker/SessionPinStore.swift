import Foundation

/// Persists the set of "pinned" session ids — favorites the user floats to the
/// top of their project group (Electron parity) — in the native
/// application-support directory (never Electron's). Atomic writes, corrupt
/// file → empty, mirroring `PermissionRuleStore`. Pins are stored as an ordered
/// array so the cap can evict the oldest pin first; callers observe a `Set`.
struct SessionPinStore: Sendable {
    private struct Payload: Codable {
        var pins: [String]
    }

    let fileURL: URL
    private let cap = 100

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("session-pins.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// The pinned session ids (membership only; ordering is an internal
    /// eviction detail, not exposed).
    func pins() -> Set<String> {
        Set(read()?.pins ?? [])
    }

    func isPinned(_ id: String) -> Bool {
        read()?.pins.contains(id) ?? false
    }

    /// Pin or unpin a session id. Pinning is idempotent and keeps the id's
    /// original insertion position; adding past the cap evicts the oldest pin.
    /// Unpinning an id that isn't pinned is a no-op (no write).
    func setPinned(_ id: String, _ pinned: Bool) {
        var ids = read()?.pins ?? []
        if pinned {
            guard !ids.contains(id) else { return }
            ids.append(id)
            if ids.count > cap { ids.removeFirst(ids.count - cap) }
        } else {
            let before = ids.count
            ids.removeAll { $0 == id }
            guard ids.count != before else { return }
        }
        write(Payload(pins: ids))
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
