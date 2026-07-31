import Foundation

/// Persists per-project manual session ordering (drag-reorder) in the native
/// application-support directory (never Electron's). Atomic writes, corrupt
/// file → empty, mirroring `SessionPinStore`. Each project's stored list is
/// capped at 500 ids on write to bound file growth; the pure `apply` places
/// stored ids first (in stored order) and appends any unknown/new sessions in
/// their incoming order, ignoring stale stored ids that no longer exist.
struct SessionOrderStore: Sendable {
    private typealias Payload = [String: [String]]

    let fileURL: URL
    private let cap = 500

    init(directory: URL = NativePreviewPaths.applicationSupportDirectory) {
        self.fileURL = directory.appendingPathComponent("session-order.json", isDirectory: false)
    }

    /// The stored manual order for a project, or empty if none is stored.
    func order(projectID: String) -> [String] {
        read()?[projectID] ?? []
    }

    /// Replace the stored order for a project. Lists longer than the cap are
    /// truncated to the first `cap` ids on write.
    func setOrder(projectID: String, ids: [String]) {
        var payload = read() ?? [:]
        payload[projectID] = ids.count > cap ? Array(ids.prefix(cap)) : ids
        write(payload)
    }

    /// Reorders `sessions` per the stored `ids`: known ids first in stored
    /// order, then any sessions not present in `ids` appended in their
    /// incoming order. Stale ids (no matching session) are ignored.
    nonisolated static func apply(_ ids: [String], to sessions: [BrokerTerminalRecord]) -> [BrokerTerminalRecord] {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var out: [BrokerTerminalRecord] = ids.compactMap { byID[$0] }
        let placed = Set(out.map(\.id))
        out.append(contentsOf: sessions.filter { !placed.contains($0.id) })
        return out
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
