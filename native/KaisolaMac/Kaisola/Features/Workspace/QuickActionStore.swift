import Foundation

/// A per-project one-click command: a labelled shell command (build/test/dev…)
/// the user runs in a fresh owned terminal from the Quick Actions bar.
struct QuickAction: Codable, Equatable, Identifiable, Sendable {
    static let maximumTitleBytes = 128
    static let maximumCommandBytes = 4_096

    enum ValidationIssue: Equatable, Sendable, LocalizedError {
        case titleRequired
        case titleTooLong(maximumBytes: Int)
        case titleContainsControlCharacters
        case commandRequired
        case commandTooLong(maximumBytes: Int)
        case commandContainsControlCharacters

        var errorDescription: String? {
            switch self {
            case .titleRequired:
                return "Enter a title."
            case .titleTooLong(let maximumBytes):
                return "Title must be \(maximumBytes) UTF-8 bytes or fewer."
            case .titleContainsControlCharacters:
                return "Title must stay on one line and cannot contain control characters."
            case .commandRequired:
                return "Enter a command."
            case .commandTooLong(let maximumBytes):
                return "Command must be \(maximumBytes) UTF-8 bytes or fewer."
            case .commandContainsControlCharacters:
                return "Command must stay on one line and cannot contain control characters."
            }
        }
    }

    var id: String
    var title: String
    var command: String

    var validationIssues: [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let forbiddenCharacters = CharacterSet.controlCharacters.union(.newlines)

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.titleRequired)
        } else {
            if title.utf8.count > Self.maximumTitleBytes {
                issues.append(.titleTooLong(maximumBytes: Self.maximumTitleBytes))
            }
            if title.unicodeScalars.contains(where: forbiddenCharacters.contains) {
                issues.append(.titleContainsControlCharacters)
            }
        }

        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.commandRequired)
        } else {
            if command.utf8.count > Self.maximumCommandBytes {
                issues.append(.commandTooLong(maximumBytes: Self.maximumCommandBytes))
            }
            if command.unicodeScalars.contains(where: forbiddenCharacters.contains) {
                issues.append(.commandContainsControlCharacters)
            }
        }

        return issues
    }
}

/// Persists each project's Quick Actions in the native application-support
/// directory (never Electron's). Keyed by broker projectID so the same folder
/// keeps its buttons across launches. Atomic writes, corrupt file → empty,
/// mirroring `SessionPinStore`. Actions per project are capped; saving past the
/// cap drops the oldest (front of the array) so a full row still accepts a new
/// button.
struct QuickActionStore: Sendable {
    struct RowValidation: Equatable, Sendable {
        let index: Int
        let actionID: String
        let issues: [QuickAction.ValidationIssue]
    }

    enum StoreError: Error, Equatable {
        case invalidActions([RowValidation])
    }

    struct LoadedRow: Equatable, Sendable {
        let action: QuickAction
        let issues: [QuickAction.ValidationIssue]

        var isQuarantined: Bool { !issues.isEmpty }
    }

    struct LoadResult: Equatable, Sendable {
        let rows: [LoadedRow]

        var runnableActions: [QuickAction] {
            rows.compactMap { $0.isQuarantined ? nil : $0.action }
        }

        var quarantinedRows: [LoadedRow] {
            rows.filter(\.isQuarantined)
        }
    }

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

    /// This project's validated actions in display order, or an empty array
    /// when the project has none (or the file is missing/corrupt). Invalid
    /// legacy rows stay available through `load(forProject:)` for repair, but
    /// never reach command execution surfaces.
    func actions(forProject projectID: String) -> [QuickAction] {
        load(forProject: projectID).runnableActions
    }

    /// Loads every persisted row for editing while marking invalid legacy rows
    /// as quarantined. Callers that can execute commands must use
    /// `actions(forProject:)` or `runnableActions`.
    func load(forProject projectID: String) -> LoadResult {
        let actions = read()?.actionsByProject[projectID] ?? []
        return LoadResult(rows: actions.map {
            LoadedRow(action: $0, issues: $0.validationIssues)
        })
    }

    /// Replace a project's actions wholesale. The cap is enforced here by
    /// dropping the oldest entries first, so an editor that appended past the
    /// cap still persists the most recent `capPerProject` buttons. Passing an
    /// empty array clears the project's row (and prunes the key).
    func save(_ actions: [QuickAction], forProject projectID: String) throws(StoreError) {
        var trimmed = actions
        if trimmed.count > capPerProject {
            trimmed.removeFirst(trimmed.count - capPerProject)
        }
        trimmed = Self.normalizingIdentifiers(in: trimmed)
        let invalidRows = trimmed.enumerated().compactMap { index, action -> RowValidation? in
            let issues = action.validationIssues
            guard !issues.isEmpty else { return nil }
            return RowValidation(index: index, actionID: action.id, issues: issues)
        }
        guard invalidRows.isEmpty else {
            throw StoreError.invalidActions(invalidRows)
        }

        // Validation happens before reading or writing the registry so a
        // rejected edit cannot replace the last valid persisted state.
        var payload = read() ?? Payload(actionsByProject: [:])
        if trimmed.isEmpty {
            payload.actionsByProject.removeValue(forKey: projectID)
        } else {
            payload.actionsByProject[projectID] = trimmed
        }
        write(payload)
    }

    private func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard var payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        payload.actionsByProject = payload.actionsByProject.mapValues {
            Self.normalizingIdentifiers(in: $0)
        }
        return payload
    }

    /// Canonicalizes row identity at the persistence boundary. The first
    /// occurrence of each nonempty identifier keeps that identifier; later
    /// duplicates and whitespace-only values receive deterministic fallback
    /// identifiers. Reserving every imported identifier before allocating a
    /// fallback means repair never steals a valid identifier from a later row.
    private static func normalizingIdentifiers(in actions: [QuickAction]) -> [QuickAction] {
        let canonicalIDs = actions.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let reservedIDs = Set(canonicalIDs.filter { !$0.isEmpty })
        var claimedIDs = Set<String>()
        var nextFallbackOrdinal = 1

        return actions.indices.map { index in
            var action = actions[index]
            let canonicalID = canonicalIDs[index]
            if !canonicalID.isEmpty, claimedIDs.insert(canonicalID).inserted {
                action.id = canonicalID
                return action
            }

            var fallbackID: String
            repeat {
                fallbackID = "quick-action-\(nextFallbackOrdinal)"
                nextFallbackOrdinal += 1
            } while reservedIDs.contains(fallbackID) || claimedIDs.contains(fallbackID)

            claimedIDs.insert(fallbackID)
            action.id = fallbackID
            return action
        }
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
