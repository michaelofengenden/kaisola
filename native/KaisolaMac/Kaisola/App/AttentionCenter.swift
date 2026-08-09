import AppKit
import Foundation

/// The cross-project needs-you inbox: one place where background events
/// (permission asks, finished agent turns, responded terminal agents) land when
/// their surface isn't focused. Drives the dock badge and the bell popover.
@MainActor
final class AttentionCenter: ObservableObject {
    static let shared: AttentionCenter = {
        if NativePreviewSettings.isIsolatedFixture(
            environment: ProcessInfo.processInfo.environment
        ) {
            // Hosted captures and resource probes must neither post real
            // notifications nor mutate the signed app's durable inbox.
            return AttentionCenter(
                defaults: nil,
                postsNotifications: false,
                updatesDockBadge: false
            )
        }
        return AttentionCenter()
    }()

    /// `CaseIterable` so mapping tests (notification categories, inbox glyphs)
    /// can enumerate every kind instead of hand-listing the ones they remember.
    enum Kind: String, Codable, Equatable, CaseIterable {
        case permission
        case turnCompleted
        case sessionResponded
        /// A terminal BEL (\u{7}): the PTY is asking for attention outside any
        /// broker-modeled completion. Unlike `.turnCompleted`, this reads as
        /// needs-you (amber) in the quiet-fleet sidebar — see
        /// `QuietStatusDerivation.needsAttention`.
        case bell
    }

    struct Entry: Identifiable, Codable, Equatable {
        let id: String
        let kind: Kind
        /// The chat id or terminal session id to jump to.
        let targetID: String
        let title: String
        let detail: String
        let at: Date
    }

    enum PersistenceNotice: Equatable {
        case recovered(discardedEntries: Int, discardedAcknowledgements: Int)
        case corruptStatePreserved
        case writeFailed

        var message: String {
            switch self {
            case let .recovered(discardedEntries, discardedAcknowledgements):
                let discarded = discardedEntries + discardedAcknowledgements
                return "Kaisola recovered your valid attention state and preserved the original data (\(discarded) malformed record\(discarded == 1 ? "" : "s"))."
            case .corruptStatePreserved:
                return "Kaisola could not read all attention state. The original data was preserved; reset it only after reviewing the recovery copy."
            case .writeFailed:
                return "Kaisola could not save the attention change, so pending items were not cleared."
            }
        }

        var offersReset: Bool {
            if case .corruptStatePreserved = self { return true }
            return false
        }
    }

    typealias PersistenceWriter = (UserDefaults, String, Data) -> Bool

    private struct EncodedState: Encodable {
        let schemaVersion: Int
        let entries: EncodedEntries
        let acknowledgements: EncodedAcknowledgements
    }

    private struct EncodedEntries: Encodable {
        let schemaVersion: Int
        let values: [Entry]
    }

    private struct EncodedAcknowledgements: Encodable {
        let schemaVersion: Int
        let values: [String: Int64]
    }

    private struct DecodedState: Decodable {
        let schemaVersion: Int
        let entries: DecodedEntries
        let acknowledgements: DecodedAcknowledgements
    }

    private struct DecodedEntries: Decodable {
        let schemaVersion: Int
        let values: [Lossy<Entry>]
    }

    private struct DecodedAcknowledgements: Decodable {
        let schemaVersion: Int
        let values: [String: Lossy<Int64>]
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct LoadedState {
        var entries: [Entry]
        var acknowledgements: [String: Int64]
        var notice: PersistenceNotice?
        var pendingRecoveryData: Data?
        var persistenceLocked: Bool

        static let empty = LoadedState(
            entries: [],
            acknowledgements: [:],
            notice: nil,
            pendingRecoveryData: nil,
            persistenceLocked: false
        )
    }

    private struct LoadedSection<Value> {
        var value: Value
        var discarded: Int
        var isCorrupt: Bool
    }

    @Published private(set) var entries: [Entry] = []
    /// Non-nil when durable state was repaired, preserved for reset, or could
    /// not be updated. Settings/the inbox may present `message` and offer the
    /// explicit reset action only when `offersReset` is true.
    @Published private(set) var persistenceNotice: PersistenceNotice?
    /// Highest terminal completion the user has visited, keyed by durable
    /// broker session id. Unlike an inbox entry this survives clearing, so a
    /// relaunch can recover genuinely new responses without resurrecting old
    /// ones merely because the new process missed their working -> responded
    /// transition.
    private var acknowledgedSessionCompletions: [String: Int64] = [:]
    private let defaults: UserDefaults?
    private let postsNotifications: Bool
    private let updatesDockBadge: Bool
    private let persistenceWriter: PersistenceWriter
    private var pendingRecoveryData: Data?
    private var persistenceLocked = false

    private static let legacyStorageKey = "attention.entries.v1"
    private static let legacyAcknowledgementStorageKey = "attention.acknowledged-session-completions.v1"
    private static let stateStorageKey = "attention.state.v2"
    private static let recoveryStorageKey = "attention.state.recovery.v2"
    private static let stateSchemaVersion = 1
    private static let entriesSchemaVersion = 1
    private static let acknowledgementsSchemaVersion = 1
    private static let maximumEntries = 50
    private static let maximumAcknowledgements = 200
    private static let maximumStoredBytes = 256 * 1_024

    var count: Int { entries.count }

    init(
        defaults: UserDefaults? = .standard,
        postsNotifications: Bool = true,
        updatesDockBadge: Bool = true,
        persistenceWriter: PersistenceWriter? = nil
    ) {
        self.defaults = defaults
        self.postsNotifications = postsNotifications
        self.updatesDockBadge = updatesDockBadge
        self.persistenceWriter = persistenceWriter ?? Self.confirmedWrite
        let loaded = Self.loadState(from: defaults)
        entries = loaded.entries
        acknowledgedSessionCompletions = loaded.acknowledgements
        persistenceNotice = loaded.notice
        pendingRecoveryData = loaded.pendingRecoveryData
        persistenceLocked = loaded.persistenceLocked
        updateBadge()
    }

    func notify(kind: Kind, targetID: String, title: String, detail: String) {
        addEntry(kind: kind, targetID: targetID, title: title, detail: detail, at: Date())
    }

    /// Recover or deliver one broker-authored terminal completion. The broker
    /// timestamp is the event identity: reconnecting may replay the same row,
    /// but a later completion on the same durable PTY must open a fresh entry.
    @discardableResult
    func notifySessionResponded(
        targetID: String,
        title: String,
        detail: String,
        completedAt: Int64
    ) -> Bool {
        guard completedAt >= 0 else { return false }
        guard acknowledgedSessionCompletions[targetID, default: .min] < completedAt else {
            return false
        }
        let at = Date(timeIntervalSince1970: Double(completedAt) / 1_000)
        guard Self.acknowledgementTimestamp(for: at) != nil else { return false }
        if let existing = entries.first(where: {
            $0.targetID == targetID && $0.kind == .sessionResponded
        }), let existingCompletedAt = Self.acknowledgementTimestamp(for: existing.at),
           existingCompletedAt >= completedAt {
            return false
        }
        addEntry(
            kind: .sessionResponded,
            targetID: targetID,
            title: title,
            detail: detail,
            at: at
        )
        return true
    }

    func hasAcknowledgedSessionResponse(targetID: String, completedAt: Int64) -> Bool {
        acknowledgedSessionCompletions[targetID, default: .min] >= completedAt
    }

    /// Mark a broker completion visited even when this process did not already
    /// have an inbox entry (the important cold-launch/replacement case).
    func acknowledgeSessionResponse(targetID: String, completedAt: Int64) {
        guard completedAt >= 0 else { return }
        var nextAcknowledgements = acknowledgedSessionCompletions
        nextAcknowledgements[targetID] = max(
            nextAcknowledgements[targetID, default: .min],
            completedAt
        )
        nextAcknowledgements = Self.trimmedAcknowledgements(nextAcknowledgements)
        let nextEntries = entries.filter { $0.targetID != targetID }
        guard persist(entries: nextEntries, acknowledgements: nextAcknowledgements) else { return }
        acknowledgedSessionCompletions = nextAcknowledgements
        entries = nextEntries
        updateBadge()
    }

    private func addEntry(kind: Kind, targetID: String, title: String, detail: String, at: Date) {
        // One live entry per target+kind; a newer event replaces the older.
        var nextEntries = entries.filter { $0.targetID != targetID || $0.kind != kind }
        nextEntries.append(Entry(
            id: "\(targetID)-\(kind.rawValue)-\(Int(at.timeIntervalSince1970 * 1000))",
            kind: kind,
            targetID: targetID,
            title: title,
            detail: detail,
            at: at
        ))
        if nextEntries.count > Self.maximumEntries {
            nextEntries.removeFirst(nextEntries.count - Self.maximumEntries)
        }
        // Delivery remains visible in-memory even when persistence fails; the
        // notice makes the lack of durability explicit. Destructive clears,
        // by contrast, do not mutate the UI until this same write is confirmed.
        _ = persist(entries: nextEntries, acknowledgements: acknowledgedSessionCompletions)
        entries = nextEntries
        updateBadge()
        if postsNotifications {
            NotificationBridge.shared.post(kind: kind, title: title, detail: detail, targetID: targetID)
        }
    }

    /// Clear every entry pointing at a target (called when the user visits it).
    func clear(targetID: String) {
        guard entries.contains(where: { $0.targetID == targetID }) else { return }
        let candidates = entries.filter { $0.targetID == targetID }
        let nextAcknowledgements = Self.acknowledging(
            candidates,
            in: acknowledgedSessionCompletions
        )
        let nextEntries = entries.filter { $0.targetID != targetID }
        guard persist(entries: nextEntries, acknowledgements: nextAcknowledgements) else { return }
        acknowledgedSessionCompletions = nextAcknowledgements
        entries = nextEntries
        updateBadge()
    }

    func clearAll() {
        guard !entries.isEmpty else { return }
        let nextAcknowledgements = Self.acknowledging(
            entries,
            in: acknowledgedSessionCompletions
        )
        guard persist(entries: [], acknowledgements: nextAcknowledgements) else { return }
        acknowledgedSessionCompletions = nextAcknowledgements
        entries = []
        updateBadge()
    }

    func dismissPersistenceNotice() {
        persistenceNotice = nil
    }

    /// Explicitly replace an unreadable v2 state only after its exact bytes
    /// have been copied to the recovery key. UI must ask the user before
    /// invoking this; ordinary notifications and clears never call it.
    @discardableResult
    func resetCorruptPersistence() -> Bool {
        guard let defaults else {
            persistenceLocked = false
            pendingRecoveryData = nil
            persistenceNotice = nil
            return true
        }
        if let rawValue = defaults.object(forKey: Self.stateStorageKey) {
            let copied: Bool
            if let rawData = rawValue as? Data {
                copied = persistenceWriter(defaults, Self.recoveryStorageKey, rawData)
            } else {
                copied = Self.confirmedRecoveryWrite(
                    defaults,
                    Self.recoveryStorageKey,
                    rawValue
                )
            }
            guard copied else {
                persistenceNotice = .writeFailed
                return false
            }
        } else if let pendingRecoveryData {
            guard persistenceWriter(
                defaults,
                Self.recoveryStorageKey,
                pendingRecoveryData
            ) else {
                persistenceNotice = .writeFailed
                return false
            }
        }
        defaults.removeObject(forKey: Self.stateStorageKey)
        guard defaults.synchronize(), defaults.object(forKey: Self.stateStorageKey) == nil else {
            persistenceNotice = .writeFailed
            return false
        }
        persistenceLocked = false
        pendingRecoveryData = nil
        guard persist(
            entries: entries,
            acknowledgements: acknowledgedSessionCompletions
        ) else { return false }
        persistenceNotice = nil
        return true
    }

    private func updateBadge() {
        guard updatesDockBadge else { return }
        NSApp?.dockTile.badgeLabel = entries.isEmpty ? nil : "\(entries.count)"
    }

    private static func acknowledging(
        _ candidates: [Entry],
        in acknowledgements: [String: Int64]
    ) -> [String: Int64] {
        var updated = acknowledgements
        for entry in candidates where entry.kind == .sessionResponded {
            guard let completedAt = acknowledgementTimestamp(for: entry.at) else { continue }
            updated[entry.targetID] = max(
                updated[entry.targetID, default: .min],
                completedAt
            )
        }
        return trimmedAcknowledgements(updated)
    }

    private static func trimmedAcknowledgements(
        _ acknowledgements: [String: Int64]
    ) -> [String: Int64] {
        guard acknowledgements.count > maximumAcknowledgements else { return acknowledgements }
        return Dictionary(
            uniqueKeysWithValues: acknowledgements
                .sorted { lhs, rhs in lhs.value > rhs.value }
                .prefix(maximumAcknowledgements)
                .map { ($0.key, $0.value) }
        )
    }

    private func persist(
        entries: [Entry],
        acknowledgements: [String: Int64]
    ) -> Bool {
        guard !persistenceLocked else {
            if persistenceNotice == nil { persistenceNotice = .corruptStatePreserved }
            return false
        }
        guard let defaults else { return true }

        // A lossy v2 repair may replace the active payload only after its exact
        // original bytes have a confirmed recovery copy.
        if let pendingRecoveryData {
            guard persistenceWriter(
                defaults,
                Self.recoveryStorageKey,
                pendingRecoveryData
            ) else {
                persistenceNotice = .writeFailed
                return false
            }
            self.pendingRecoveryData = nil
        }

        let payload = EncodedState(
            schemaVersion: Self.stateSchemaVersion,
            entries: EncodedEntries(
                schemaVersion: Self.entriesSchemaVersion,
                values: entries
            ),
            acknowledgements: EncodedAcknowledgements(
                schemaVersion: Self.acknowledgementsSchemaVersion,
                values: acknowledgements
            )
        )
        guard let data = try? JSONEncoder().encode(payload),
              data.count <= Self.maximumStoredBytes,
              persistenceWriter(defaults, Self.stateStorageKey, data) else {
            persistenceNotice = .writeFailed
            return false
        }
        if persistenceNotice == .writeFailed { persistenceNotice = nil }
        return true
    }

    private static func confirmedWrite(
        _ defaults: UserDefaults,
        _ key: String,
        _ data: Data
    ) -> Bool {
        defaults.set(data, forKey: key)
        guard defaults.synchronize() else { return false }
        return defaults.data(forKey: key) == data
    }

    private static func confirmedRecoveryWrite(
        _ defaults: UserDefaults,
        _ key: String,
        _ value: Any
    ) -> Bool {
        defaults.set(value, forKey: key)
        guard defaults.synchronize(),
              let stored = defaults.object(forKey: key) as? NSObject else { return false }
        return stored.isEqual(value)
    }

    private static func loadState(from defaults: UserDefaults?) -> LoadedState {
        guard let defaults else { return .empty }
        if defaults.object(forKey: stateStorageKey) != nil {
            guard let data = defaults.data(forKey: stateStorageKey) else {
                return LoadedState(
                    entries: [],
                    acknowledgements: [:],
                    notice: .corruptStatePreserved,
                    pendingRecoveryData: nil,
                    persistenceLocked: true
                )
            }
            return loadVersionedState(data)
        }

        // v1 used two unversioned values. Read them lossily, but deliberately
        // leave their exact bytes in place: v2 writes use a new atomic key, so
        // migration never needs to destroy the only recovery source.
        let legacyEntries = loadLegacyEntries(from: defaults)
        let legacyAcknowledgements = loadLegacyAcknowledgements(from: defaults)
        let notice: PersistenceNotice?
        if legacyEntries.isCorrupt || legacyAcknowledgements.isCorrupt {
            notice = .corruptStatePreserved
        } else if legacyEntries.discarded > 0 || legacyAcknowledgements.discarded > 0 {
            notice = .recovered(
                discardedEntries: legacyEntries.discarded,
                discardedAcknowledgements: legacyAcknowledgements.discarded
            )
        } else {
            notice = nil
        }
        return LoadedState(
            entries: legacyEntries.value,
            acknowledgements: legacyAcknowledgements.value,
            notice: notice,
            pendingRecoveryData: nil,
            persistenceLocked: false
        )
    }

    private static func loadVersionedState(_ data: Data) -> LoadedState {
        guard data.count <= maximumStoredBytes,
              let decoded = try? JSONDecoder().decode(DecodedState.self, from: data),
              decoded.schemaVersion == stateSchemaVersion,
              decoded.entries.schemaVersion == entriesSchemaVersion,
              decoded.acknowledgements.schemaVersion == acknowledgementsSchemaVersion else {
            return LoadedState(
                entries: [],
                acknowledgements: [:],
                notice: .corruptStatePreserved,
                pendingRecoveryData: data,
                persistenceLocked: true
            )
        }

        let decodedEntries = decoded.entries.values.compactMap(\.value)
        let entries = normalizedEntries(decodedEntries)
        let decodedAcknowledgements = decoded.acknowledgements.values.compactMapValues(\.value)
        let acknowledgements = normalizedAcknowledgements(decodedAcknowledgements)
        let discardedEntries = decoded.entries.values.count - entries.count
        let discardedAcknowledgements = decoded.acknowledgements.values.count - acknowledgements.count
        let repaired = discardedEntries > 0 || discardedAcknowledgements > 0
        return LoadedState(
            entries: entries,
            acknowledgements: acknowledgements,
            notice: repaired
                ? .recovered(
                    discardedEntries: discardedEntries,
                    discardedAcknowledgements: discardedAcknowledgements
                )
                : nil,
            pendingRecoveryData: repaired ? data : nil,
            persistenceLocked: false
        )
    }

    private static func loadLegacyEntries(
        from defaults: UserDefaults
    ) -> LoadedSection<[Entry]> {
        guard defaults.object(forKey: legacyStorageKey) != nil else {
            return LoadedSection(value: [], discarded: 0, isCorrupt: false)
        }
        guard let data = defaults.data(forKey: legacyStorageKey),
              data.count <= maximumStoredBytes,
              let decoded = try? JSONDecoder().decode([Lossy<Entry>].self, from: data) else {
            return LoadedSection(value: [], discarded: 0, isCorrupt: true)
        }
        let normalized = normalizedEntries(decoded.compactMap(\.value))
        return LoadedSection(
            value: normalized,
            discarded: decoded.count - normalized.count,
            isCorrupt: false
        )
    }

    private static func loadLegacyAcknowledgements(
        from defaults: UserDefaults
    ) -> LoadedSection<[String: Int64]> {
        guard defaults.object(forKey: legacyAcknowledgementStorageKey) != nil else {
            return LoadedSection(value: [:], discarded: 0, isCorrupt: false)
        }
        guard let data = defaults.data(forKey: legacyAcknowledgementStorageKey),
              data.count <= maximumStoredBytes,
              let decoded = try? JSONDecoder().decode([String: Lossy<Int64>].self, from: data) else {
            return LoadedSection(value: [:], discarded: 0, isCorrupt: true)
        }
        let normalized = normalizedAcknowledgements(decoded.compactMapValues(\.value))
        return LoadedSection(
            value: normalized,
            discarded: decoded.count - normalized.count,
            isCorrupt: false
        )
    }

    /// Defaults are user-writable. Bound every restored field before it can
    /// enter SwiftUI, then restore only the newest target/kind event.
    private static func normalizedEntries(_ decoded: [Entry]) -> [Entry] {
        let valid = decoded.filter { entry in
            !entry.id.isEmpty && entry.id.utf8.count <= 1_024
                && !entry.targetID.isEmpty && entry.targetID.utf8.count <= 512
                && entry.title.utf8.count <= 512
                && entry.detail.utf8.count <= 2_048
                && entry.at.timeIntervalSince1970.isFinite
                && (entry.kind != .sessionResponded
                    || acknowledgementTimestamp(for: entry.at) != nil)
        }
        var seen: Set<String> = []
        let newestUnique = valid.reversed().filter { entry in
            seen.insert("\(entry.targetID)\u{0}\(entry.kind.rawValue)").inserted
        }.reversed()
        return Array(newestUnique.suffix(maximumEntries))
    }

    /// Conversion from user-writable dates must be checked before any
    /// acknowledgement path reaches Swift's trapping floating-point-to-Int
    /// initializer. Positive `Int64.max` rounds up when represented as a
    /// `Double`, so the upper bound is deliberately strict.
    private static func acknowledgementTimestamp(for date: Date) -> Int64? {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds < Double(Int64.max) else { return nil }
        return Int64(milliseconds)
    }

    private static func normalizedAcknowledgements(
        _ decoded: [String: Int64]
    ) -> [String: Int64] {
        let valid = decoded.filter { targetID, completedAt in
            !targetID.isEmpty && targetID.utf8.count <= 512 && completedAt >= 0
        }
        return Dictionary(
            uniqueKeysWithValues: valid
                .sorted { lhs, rhs in lhs.value > rhs.value }
                .prefix(maximumAcknowledgements)
                .map { ($0.key, $0.value) }
        )
    }
}
