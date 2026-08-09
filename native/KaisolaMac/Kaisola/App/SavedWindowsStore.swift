import AppKit
import Foundation

/// Named window states (frame + selected project), persisted in UserDefaults —
/// the native counterpart of Electron's SavedWindows. Saving under an existing
/// name replaces it.
struct SavedWindowState: Codable, Equatable, Identifiable, Sendable {
    let name: String
    /// NSWindow frame descriptor string (NSStringFromRect form).
    let frame: String
    let projectName: String?
    /// Stable local identity for new records. Older builds stored only the
    /// display name; keeping this optional preserves their decoding while new
    /// saved windows can restore a real project instead of painting a label
    /// with no matching project id.
    let projectPath: String?

    init(name: String, frame: String, projectName: String?, projectPath: String? = nil) {
        self.name = name
        self.frame = frame
        self.projectName = projectName
        self.projectPath = projectPath
    }

    var id: String { name }

    func projectDirectory(fileManager: FileManager = .default) -> URL? {
        guard let projectPath, projectPath.hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return directory
    }
}

struct SavedWindowsStore {
    static let schemaVersion = 1

    struct Snapshot: Equatable, Sendable {
        let states: [SavedWindowState]
        let recovery: RecoveryIssue?
    }

    enum RecoveryIssue: Equatable, Sendable {
        case malformedRecords(count: Int)
        case malformedArchive
        case newerSchema(found: Int)

        var blocksWrites: Bool {
            if case .newerSchema = self { return true }
            return false
        }

        var menuTitle: String {
            switch self {
            case .malformedRecords(let count):
                count == 1
                    ? "Review 1 Unreadable Saved Window…"
                    : "Review \(count) Unreadable Saved Windows…"
            case .malformedArchive:
                "Review Saved Windows Recovery…"
            case .newerSchema:
                "Saved Windows Require a Newer Kaisola…"
            }
        }

        var alertTitle: String {
            switch self {
            case .malformedRecords:
                "Some Saved Windows Couldn't Be Read"
            case .malformedArchive:
                "Saved Windows Couldn't Be Read"
            case .newerSchema:
                "Saved Windows Came From a Newer Kaisola"
            }
        }

        var message: String {
            switch self {
            case .malformedRecords(let count):
                let noun = count == 1 ? "entry was" : "entries were"
                return "Kaisola kept every readable saved window. \(count) \(noun) isolated, "
                    + "and an exact copy of the original catalog is available below."
            case .malformedArchive:
                return "Kaisola couldn't decode this catalog, so it kept an exact copy before "
                    + "starting a fresh one. You can copy the original data below."
            case .newerSchema(let found):
                return "This catalog uses data format \(found), which this Kaisola doesn't "
                    + "understand. The original catalog is untouched and changes are blocked. "
                    + "Open it with the newer Kaisola, or copy the original data below."
            }
        }
    }

    enum MutationResult: Equatable, Sendable {
        case persisted
        case blocked(RecoveryIssue)
    }

    private struct PersistedArchive: Encodable {
        let schemaVersion: Int
        let records: [SavedWindowState]
        let recovery: PersistedRecovery?
    }

    private struct ArchiveHeader: Decodable {
        let schemaVersion: Int
    }

    private struct RecordBox: Decodable {
        let record: SavedWindowState
    }

    private struct PersistedRecovery: Codable {
        enum Kind: String, Codable {
            case malformedRecords
            case malformedArchive
        }

        let kind: Kind
        let rejectedRecordCount: Int?

        init(_ issue: RecoveryIssue?) {
            switch issue {
            case .malformedRecords(let count):
                kind = .malformedRecords
                rejectedRecordCount = count
            case .malformedArchive:
                kind = .malformedArchive
                rejectedRecordCount = nil
            case .newerSchema, nil:
                kind = .malformedArchive
                rejectedRecordCount = nil
            }
        }

        var issue: RecoveryIssue {
            switch kind {
            case .malformedRecords:
                .malformedRecords(count: max(1, rejectedRecordCount ?? 1))
            case .malformedArchive:
                .malformedArchive
            }
        }
    }

    private struct DecodedRecords {
        let states: [SavedWindowState]
        let rejectedCount: Int
    }

    private let key: String
    private let recoveryKey: String
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        key: String = "savedWindows",
        recoveryKey: String? = nil
    ) {
        self.defaults = defaults
        self.key = key
        self.recoveryKey = recoveryKey ?? "\(key).recovery"
    }

    func all() -> [SavedWindowState] {
        snapshot().states
    }

    func snapshot() -> Snapshot {
        guard let data = defaults.data(forKey: key) else {
            return Snapshot(states: [], recovery: nil)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return recoverMalformedArchive(data)
        }

        if let legacyRecords = root as? [Any] {
            let decoded = decodeRecords(legacyRecords)
            let recovery: RecoveryIssue? = decoded.rejectedCount == 0
                ? nil
                : .malformedRecords(count: decoded.rejectedCount)
            keepRecoveryCopy(data)
            persist(decoded.states, recovery: recovery)
            return Snapshot(states: decoded.states, recovery: recovery)
        }

        guard let object = root as? [String: Any],
              let header = try? JSONDecoder().decode(ArchiveHeader.self, from: data) else {
            return recoverMalformedArchive(data)
        }
        guard header.schemaVersion <= Self.schemaVersion else {
            keepRecoveryCopy(data)
            return Snapshot(states: [], recovery: .newerSchema(found: header.schemaVersion))
        }
        guard header.schemaVersion == Self.schemaVersion,
              let recordObjects = object["records"] as? [Any] else {
            return recoverMalformedArchive(data)
        }

        let decoded = decodeRecords(recordObjects)
        let persistedRecovery = decodeRecovery(object["recovery"])
        if decoded.rejectedCount > 0 {
            let totalRejected: Int
            if case .malformedRecords(let previousCount) = persistedRecovery {
                totalRejected = previousCount + decoded.rejectedCount
            } else {
                totalRejected = decoded.rejectedCount
            }
            let recovery = RecoveryIssue.malformedRecords(count: totalRejected)
            keepRecoveryCopy(data)
            persist(decoded.states, recovery: recovery)
            return Snapshot(states: decoded.states, recovery: recovery)
        }
        return Snapshot(states: decoded.states, recovery: persistedRecovery)
    }

    @discardableResult
    func save(_ state: SavedWindowState) -> MutationResult {
        let current = snapshot()
        if let recovery = current.recovery, recovery.blocksWrites {
            return .blocked(recovery)
        }
        var states = current.states.filter { $0.name != state.name }
        states.append(state)
        states.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist(states, recovery: current.recovery)
        return .persisted
    }

    @discardableResult
    func remove(name: String) -> MutationResult {
        let current = snapshot()
        if let recovery = current.recovery, recovery.blocksWrites {
            return .blocked(recovery)
        }
        persist(current.states.filter { $0.name != name }, recovery: current.recovery)
        return .persisted
    }

    func recoveryData() -> Data? {
        defaults.data(forKey: recoveryKey)
    }

    func recoveryExportText() -> String? {
        guard let data = recoveryData() else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        return "Base64-encoded Saved Windows recovery data:\n\(data.base64EncodedString())"
    }

    private func decodeRecords(_ objects: [Any]) -> DecodedRecords {
        let decoder = JSONDecoder()
        var states: [SavedWindowState] = []
        var rejectedCount = 0
        for object in objects {
            guard JSONSerialization.isValidJSONObject(["record": object]),
                  let data = try? JSONSerialization.data(withJSONObject: ["record": object]),
                  let state = try? decoder.decode(RecordBox.self, from: data).record else {
                rejectedCount += 1
                continue
            }
            states.append(state)
        }
        return DecodedRecords(states: states, rejectedCount: rejectedCount)
    }

    private func decodeRecovery(_ object: Any?) -> RecoveryIssue? {
        guard let object,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let recovery = try? JSONDecoder().decode(PersistedRecovery.self, from: data) else {
            return nil
        }
        return recovery.issue
    }

    private func recoverMalformedArchive(_ data: Data) -> Snapshot {
        keepRecoveryCopy(data)
        let recovery = RecoveryIssue.malformedArchive
        persist([], recovery: recovery)
        return Snapshot(states: [], recovery: recovery)
    }

    private func keepRecoveryCopy(_ data: Data) {
        defaults.set(data, forKey: recoveryKey)
    }

    private func persist(_ states: [SavedWindowState], recovery: RecoveryIssue?) {
        let marker = recovery.flatMap { issue -> PersistedRecovery? in
            issue.blocksWrites ? nil : PersistedRecovery(issue)
        }
        let archive = PersistedArchive(
            schemaVersion: Self.schemaVersion,
            records: states,
            recovery: marker
        )
        if let data = try? JSONEncoder().encode(archive) {
            defaults.set(data, forKey: key)
        }
    }
}
