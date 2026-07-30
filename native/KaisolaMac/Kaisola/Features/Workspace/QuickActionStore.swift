import Foundation

/// A per-project one-click command: a labelled shell command (build/test/dev…)
/// the user runs in a fresh owned terminal from the Quick Actions bar.
struct QuickAction: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var command: String
}

/// Persists each project's Quick Actions in the native application-support
/// directory (never Electron's). Keyed by broker projectID so the same folder
/// keeps its buttons across launches. Atomic writes, corrupt file → empty,
/// mirroring `SessionPinStore`. Actions per project are capped; saving past the
/// cap drops the oldest (front of the array) so a full row still accepts a new
/// button.
struct QuickActionStore: Sendable {
    private struct Payload: Codable {
        /// projectID → its ordered Quick Actions (display order = array order).
        var actionsByProject: [String: [QuickAction]]
    }

    let fileURL: URL
    /// Electron parity keeps a small, glanceable strip; more than this many
    /// buttons stops being a quick action and wants the palette instead.
    private let capPerProject = 8

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("quick-actions.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// This project's actions in display order, or an empty array when the
    /// project has none (or the file is missing/corrupt).
    func actions(forProject projectID: String) -> [QuickAction] {
        read()?.actionsByProject[projectID] ?? []
    }

    /// Replace a project's actions wholesale. The cap is enforced here by
    /// dropping the oldest entries first, so an editor that appended past the
    /// cap still persists the most recent `capPerProject` buttons. Passing an
    /// empty array clears the project's row (and prunes the key).
    func save(_ actions: [QuickAction], forProject projectID: String) {
        var payload = read() ?? Payload(actionsByProject: [:])
        var trimmed = actions
        if trimmed.count > capPerProject {
            trimmed.removeFirst(trimmed.count - capPerProject)
        }
        if trimmed.isEmpty {
            payload.actionsByProject.removeValue(forKey: projectID)
        } else {
            payload.actionsByProject[projectID] = trimmed
        }
        write(payload)
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
