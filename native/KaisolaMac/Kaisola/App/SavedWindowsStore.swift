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

/// Why a Saved Windows list is shorter than the user left it. The two shapes
/// need opposite handling, so the catalog keeps them apart the way
/// `WorkspaceRestorationNotice` does for the workspace archive: damage this
/// build may prune once it has kept a copy, and data from a newer Kaisola that
/// it must leave exactly where the newer build expects to find it.
enum SavedWindowsNotice: Equatable, Sendable {
    /// Records that could not be decoded. The ones that did decode are listed.
    case damagedRecords(count: Int)
    /// The payload itself is not a list this build can read, so nothing decoded.
    case unreadableCatalog
    /// A newer schema than this build knows how to write.
    case newerVersionData(schemaVersion: Int)

    /// Whether saving and deleting are refused while this notice stands. Only
    /// a newer build's payload earns that: re-encoding it here would silently
    /// drop whatever that version added, while damaged records are already
    /// unreadable and a kept copy covers them.
    var blocksWrites: Bool {
        switch self {
        case .damagedRecords, .unreadableCatalog: false
        case .newerVersionData: true
        }
    }

    var title: String {
        switch self {
        case .damagedRecords: "Some Saved Windows Couldn't Be Read"
        case .unreadableCatalog: "Saved Windows Couldn't Be Read"
        case .newerVersionData: "Saved by a Newer Version of Kaisola"
        }
    }

    /// The compact form the menu row shows in place of an unexplained gap.
    var summary: String {
        switch self {
        case .damagedRecords(let count):
            count == 1
                ? "1 saved window couldn't be read"
                : "\(count) saved windows couldn't be read"
        case .unreadableCatalog: "Saved windows couldn't be read"
        case .newerVersionData: "Saved by a newer version of Kaisola"
        }
    }

    var message: String {
        switch self {
        case .damagedRecords(let count):
            "\(count) saved window\(count == 1 ? "" : "s") couldn't be read, so "
                + "\(count == 1 ? "it isn't" : "they aren't") listed. Every other "
                + "layout is intact and still opens normally."
        case .unreadableCatalog:
            "The saved windows list is damaged, so none of it could be read. "
                + "Saving a layout starts a fresh list."
        case .newerVersionData(let schemaVersion):
            "Your saved windows were written by a newer version of Kaisola (data "
                + "format \(schemaVersion)). They're left untouched so that version "
                + "can still read them, which means saving and deleting layouts is "
                + "off here. Open the newer version to manage them."
        }
    }
}

/// The catalog as this build could read it: the records that survived, plus the
/// notice that explains anything missing from them.
struct SavedWindowsCatalog: Equatable, Sendable {
    var windows: [SavedWindowState] = []
    var notice: SavedWindowsNotice?
}

/// Payload bytes kept aside before the rewrite that replaced them, so damaged
/// or pre-migration data stays recoverable by hand instead of being overwritten
/// by the next save.
struct SavedWindowsPreservedCopy: Codable, Equatable, Sendable {
    let savedAt: Date
    /// The exact bytes that were stored before the rewrite.
    let payload: Data

    /// The kept bytes as text, which is what an export writes to disk.
    var text: String { String(decoding: payload, as: UTF8.self) }
}

struct SavedWindowsStore {
    /// Version 1 wraps the records in `{"version":…,"windows":[…]}`. Version 0
    /// is the original bare array, which still decodes and is migrated on the
    /// next write.
    static let schemaVersion = 1
    private static let legacySchemaVersion = 0

    private let key: String
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, key: String = "savedWindows") {
        self.defaults = defaults
        self.key = key
    }

    /// Where the last payload this build could not use verbatim is kept.
    var preservedCopyKey: String { "\(key).preservedCopy" }

    /// Read the catalog, decoding records one at a time so a single damaged
    /// entry costs the user that entry rather than every named layout.
    func load() -> SavedWindowsCatalog {
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return SavedWindowsCatalog() }
        let parsed = Self.parse(data)
        return SavedWindowsCatalog(windows: parsed.windows, notice: parsed.notice)
    }

    func all() -> [SavedWindowState] { load().windows }

    /// Returns false when the write was refused (a newer build owns the list)
    /// or could not be encoded, so the caller can say so instead of implying a
    /// layout was stored.
    @discardableResult
    func save(_ state: SavedWindowState) -> Bool {
        let catalog = load()
        guard catalog.notice?.blocksWrites != true else { return false }
        var states = catalog.windows.filter { $0.name != state.name }
        states.append(state)
        states.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return persist(states)
    }

    @discardableResult
    func remove(name: String) -> Bool {
        let catalog = load()
        guard catalog.notice?.blocksWrites != true else { return false }
        return persist(catalog.windows.filter { $0.name != name })
    }

    /// The payload kept aside before the most recent migration or repair, if
    /// one is still waiting to be recovered.
    func preservedCopy() -> SavedWindowsPreservedCopy? {
        guard let data = defaults.data(forKey: preservedCopyKey) else { return nil }
        return try? JSONDecoder().decode(SavedWindowsPreservedCopy.self, from: data)
    }

    func discardPreservedCopy() {
        defaults.removeObject(forKey: preservedCopyKey)
    }

    @discardableResult
    private func persist(_ states: [SavedWindowState]) -> Bool {
        preserveStoredPayloadIfNeeded()
        guard let data = try? JSONEncoder().encode(
            Payload(version: Self.schemaVersion, windows: states)
        ) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    /// Keep the stored bytes before a rewrite replaces them, unless they are
    /// already a clean payload of this version — re-encoding good data has
    /// nothing to recover. Only the newest unusable payload is kept; by the
    /// time a second one could appear the first has already been merged into
    /// the live catalog.
    private func preserveStoredPayloadIfNeeded() {
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return }
        let parsed = Self.parse(data)
        let migrates = parsed.version != Self.schemaVersion && !parsed.windows.isEmpty
        guard parsed.notice != nil || migrates else { return }
        guard preservedCopy()?.payload != data else { return }
        guard let encoded = try? JSONEncoder().encode(
            SavedWindowsPreservedCopy(savedAt: Date(), payload: data)
        ) else { return }
        defaults.set(encoded, forKey: preservedCopyKey)
    }

    // MARK: - Decoding

    private struct Payload: Codable {
        var version: Int
        var windows: [SavedWindowState]
    }

    /// Just the version, read before the records so a payload whose record
    /// shape this build does not know is still recognizably a newer build's.
    private struct PayloadHeader: Decodable {
        let version: Int
    }

    private struct LenientPayload: Decodable {
        let windows: [LenientRecord]
    }

    /// One array element, decoded so damage stays local: a record this build
    /// cannot read becomes `nil` instead of failing its whole array.
    private struct LenientRecord: Decodable {
        let state: SavedWindowState?

        init(from decoder: any Decoder) throws {
            state = try? SavedWindowState(from: decoder)
        }
    }

    private struct ParsedPayload {
        var version: Int
        var windows: [SavedWindowState] = []
        var notice: SavedWindowsNotice?
    }

    private static func parse(_ data: Data) -> ParsedPayload {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(PayloadHeader.self, from: data) else {
            // No version key: either the original bare array or bytes that are
            // not this list at all.
            guard let records = try? decoder.decode([LenientRecord].self, from: data) else {
                return ParsedPayload(version: legacySchemaVersion, notice: .unreadableCatalog)
            }
            return parsed(records, version: legacySchemaVersion)
        }
        guard header.version <= schemaVersion else {
            // Decode what this build recognizes so the layouts still open, but
            // report the version: writes stay off until the newer build runs.
            let records = (try? decoder.decode(LenientPayload.self, from: data))?.windows ?? []
            return ParsedPayload(
                version: header.version,
                windows: records.compactMap(\.state),
                notice: .newerVersionData(schemaVersion: header.version)
            )
        }
        guard let payload = try? decoder.decode(LenientPayload.self, from: data) else {
            return ParsedPayload(version: header.version, notice: .unreadableCatalog)
        }
        return parsed(payload.windows, version: header.version)
    }

    private static func parsed(_ records: [LenientRecord], version: Int) -> ParsedPayload {
        let windows = records.compactMap(\.state)
        let damaged = records.count - windows.count
        return ParsedPayload(
            version: version,
            windows: windows,
            notice: damaged > 0 ? .damagedRecords(count: damaged) : nil
        )
    }
}
