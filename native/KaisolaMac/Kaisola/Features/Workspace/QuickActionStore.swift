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
/// button. Ids are repaired on both read and write, so a hand-edited or imported
/// file with repeated or blank ids cannot reach the UI's row identity.
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
    /// project has none (or the file is missing/corrupt). Ids are normalized on
    /// the way out so a hand-edited or imported file can never hand SwiftUI two
    /// rows with the same identity.
    func actions(forProject projectID: String) -> [QuickAction] {
        Self.normalizedIdentifiers(read()?.actionsByProject[projectID] ?? [])
    }

    /// Replace a project's actions wholesale. The cap is enforced here by
    /// dropping the oldest entries first, so an editor that appended past the
    /// cap still persists the most recent `capPerProject` buttons. Ids are
    /// normalized before the write so the file on disk is repaired, not just the
    /// copy this session read. Passing an empty array clears the project's row
    /// (and prunes the key).
    func save(_ actions: [QuickAction], forProject projectID: String) {
        var payload = read() ?? Payload(actionsByProject: [:])
        var trimmed = actions
        if trimmed.count > capPerProject {
            trimmed.removeFirst(trimmed.count - capPerProject)
        }
        trimmed = Self.normalizedIdentifiers(trimmed)
        if trimmed.isEmpty {
            payload.actionsByProject.removeValue(forKey: projectID)
        } else {
            payload.actionsByProject[projectID] = trimmed
        }
        write(payload)
    }

    /// Repairs identifiers so every action in a row carries a nonempty id that
    /// is unique within that project — `ForEach` identity, "edit this row" and
    /// "delete this row" all key off the id, so a repeated one edits or deletes
    /// the wrong button. Ids are trimmed; a blank one takes a slot-derived name
    /// and a repeat takes a numbered suffix, both probed until they collide with
    /// nothing else in the row. Deliberately deterministic rather than a fresh
    /// UUID: the same file normalizes to the same ids on every load, so a row
    /// the user never edits keeps its identity across reads.
    private static func normalizedIdentifiers(_ actions: [QuickAction]) -> [QuickAction] {
        var used = Set<String>()
        var normalized: [QuickAction] = []
        normalized.reserveCapacity(actions.count)
        for (slot, action) in actions.enumerated() {
            var identifier = action.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if identifier.isEmpty { identifier = "action-\(slot)" }
            if used.contains(identifier) {
                var suffix = 2
                while used.contains("\(identifier)-\(suffix)") { suffix += 1 }
                identifier = "\(identifier)-\(suffix)"
            }
            used.insert(identifier)
            var repaired = action
            repaired.id = identifier
            normalized.append(repaired)
        }
        return normalized
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
