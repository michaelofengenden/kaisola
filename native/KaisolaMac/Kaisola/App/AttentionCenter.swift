import AppKit
import Foundation

/// What became of the durable needs-you inbox when this build could not read or
/// write it whole.
///
/// None of this is fatal — the app keeps running on whatever it could salvage —
/// but silence was the wrong answer. Unreadable bytes used to be deleted on
/// sight, which quietly threw away every pending permission ask, and a failed
/// write used to look exactly like a successful one, so clearing the badge
/// "worked" until the next launch brought all of it back.
struct AttentionStorageNotice: Identifiable, Equatable {
    /// Which of the two stored payloads the problem is about.
    enum Payload: String, Equatable, CaseIterable {
        case entries
        case acknowledgements

        /// How to name the payload to a person who has never heard of it.
        var noun: String {
            switch self {
            case .entries: "needs-you list"
            case .acknowledgements: "record of responses you've already seen"
            }
        }
    }

    enum Kind: Equatable {
        /// The payload was read, but individual records inside it were not.
        case recordsDropped(count: Int)
        /// Nothing in the payload could be read, so this build started empty.
        case unreadable
        /// Written by a newer Kaisola: good data this build must not
        /// reinterpret, so it is left exactly where it is and saving stops.
        case newerVersion(schemaVersion: Int)
        /// A save could not be confirmed, so the screen is ahead of the disk.
        case saveNotConfirmed
    }

    let payload: Payload
    let kind: Kind
    /// The defaults key holding the bytes this build could not read, when it
    /// was able to keep them.
    let preservedCopyKey: String?

    var id: String { "\(payload.rawValue)-\(String(describing: kind))" }

    /// True while this build refuses to write the payload, which is exactly
    /// when the user has to choose between the kept bytes and saving again.
    var blocksSaving: Bool {
        if case .newerVersion = kind { return true }
        return false
    }

    var title: String {
        switch kind {
        case .recordsDropped: "Some Saved Items Couldn't Be Read"
        case .unreadable: "Saved Inbox Couldn't Be Read"
        case .newerVersion: "Saved by a Newer Version of Kaisola"
        case .saveNotConfirmed: "Inbox Changes Aren't Being Saved"
        }
    }

    var message: String {
        switch kind {
        case .recordsDropped(let count):
            "\(count) damaged \(count == 1 ? "item" : "items") in your saved \(payload.noun) "
                + "couldn't be read and were left out. Everything else was restored."
        case .unreadable:
            preservedCopyKey == nil
                ? "Kaisola couldn't read your saved \(payload.noun) and started a fresh one. "
                    + "The damaged data was too large to keep."
                : "Kaisola couldn't read your saved \(payload.noun), so it kept the damaged data "
                    + "aside and started a fresh one. New changes are being saved normally."
        case .newerVersion(let schemaVersion):
            "Your saved \(payload.noun) was written by a newer version of Kaisola (data format "
                + "\(schemaVersion)). It's left untouched so that version can still read it, "
                + "which means changes here aren't being saved. Reset to start fresh."
        case .saveNotConfirmed:
            "Kaisola couldn't save your \(payload.noun), so anything you clear here will come "
                + "back the next time you open the app."
        }
    }
}

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

    @Published private(set) var entries: [Entry] = []
    /// What the durable inbox could not read or write, in the words the bell
    /// popover shows. Empty is the ordinary case.
    @Published private(set) var storageNotices: [AttentionStorageNotice] = []
    /// Highest terminal completion the user has visited, keyed by durable
    /// broker session id. Unlike an inbox entry this survives clearing, so a
    /// relaunch can recover genuinely new responses without resurrecting old
    /// ones merely because the new process missed their working -> responded
    /// transition.
    private var acknowledgedSessionCompletions: [String: Int64] = [:]
    /// Payloads written by a newer Kaisola. This build leaves those bytes
    /// exactly as it found them, which means it cannot save over them either,
    /// until the user asks for a reset.
    private var protectedPayloads: Set<AttentionStorageNotice.Payload> = []
    private let defaults: UserDefaults?
    private let postsNotifications: Bool
    private let updatesDockBadge: Bool

    /// The keys keep their original `.v1` suffix — that names the key
    /// generation, not the payload — while the payload itself now carries a
    /// schema version, so a shape this build does not know can be recognised
    /// rather than guessed at. Schema 1 wrote the bare array and dictionary and
    /// is still read.
    private static let storageKey = "attention.entries.v1"
    private static let acknowledgementStorageKey = "attention.acknowledged-session-completions.v1"
    /// Where unreadable bytes are kept instead of deleted, so a later build (or
    /// a support session) can still look at the work this one lost.
    private static let entriesQuarantineKey = "attention.entries.unreadable.v1"
    private static let acknowledgementQuarantineKey =
        "attention.acknowledged-session-completions.unreadable.v1"
    private static let storageSchemaVersion = 2
    private static let maximumEntries = 50
    private static let maximumAcknowledgements = 200
    private static let maximumStoredBytes = 256 * 1_024
    /// Keeping damaged bytes is for recovery, not for letting an arbitrarily
    /// large blob squat in defaults forever.
    private static let maximumQuarantinedBytes = 1_024 * 1_024

    var count: Int { entries.count }

    init(
        defaults: UserDefaults? = .standard,
        postsNotifications: Bool = true,
        updatesDockBadge: Bool = true
    ) {
        self.defaults = defaults
        self.postsNotifications = postsNotifications
        self.updatesDockBadge = updatesDockBadge
        let storedEntries = Self.loadEntries(from: defaults)
        let storedAcknowledgements = Self.loadAcknowledgements(from: defaults)
        entries = storedEntries.value
        acknowledgedSessionCompletions = storedAcknowledgements.value
        storageNotices = [storedEntries.notice, storedAcknowledgements.notice].compactMap { $0 }
        if storedEntries.isProtected { protectedPayloads.insert(.entries) }
        if storedAcknowledgements.isProtected { protectedPayloads.insert(.acknowledgements) }
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
        guard acknowledgedSessionCompletions[targetID, default: .min] < completedAt else {
            return false
        }
        let at = Date(timeIntervalSince1970: Double(completedAt) / 1_000)
        guard at.timeIntervalSince1970.isFinite else { return false }
        if let existing = entries.first(where: {
            $0.targetID == targetID && $0.kind == .sessionResponded
        }), Int64(existing.at.timeIntervalSince1970 * 1_000) >= completedAt {
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
        var updated = acknowledgedSessionCompletions
        updated[targetID] = max(updated[targetID, default: .min], completedAt)
        commit(
            entries: entries.filter { $0.targetID != targetID },
            acknowledgements: Self.trimmed(updated)
        )
    }

    private func addEntry(kind: Kind, targetID: String, title: String, detail: String, at: Date) {
        // One live entry per target+kind; a newer event replaces the older.
        entries.removeAll { $0.targetID == targetID && $0.kind == kind }
        entries.append(Entry(
            id: "\(targetID)-\(kind.rawValue)-\(Int(at.timeIntervalSince1970 * 1000))",
            kind: kind,
            targetID: targetID,
            title: title,
            detail: detail,
            at: at
        ))
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        // Arriving work shows up whether or not it can be saved: a notification
        // nobody sees is worse than one that cannot survive a relaunch.
        if !persistEntries(entries) { note(.saveNotConfirmed, for: .entries) }
        updateBadge()
        if postsNotifications {
            NotificationBridge.shared.post(kind: kind, title: title, detail: detail, targetID: targetID)
        }
    }

    /// Clear every entry pointing at a target (called when the user visits it).
    func clear(targetID: String) {
        guard entries.contains(where: { $0.targetID == targetID }) else { return }
        commit(
            entries: entries.filter { $0.targetID != targetID },
            acknowledgements: acknowledgements(visiting: entries.filter { $0.targetID == targetID })
        )
    }

    func clearAll() {
        commit(entries: [], acknowledgements: acknowledgements(visiting: entries))
    }

    /// Throw away the kept damaged copy and start saving again from what is on
    /// screen. The only repair this build can offer for bytes it cannot read,
    /// and the user has to ask for it because it discards those bytes.
    func resetStorage() {
        protectedPayloads.removeAll()
        storageNotices.removeAll()
        defaults?.removeObject(forKey: Self.entriesQuarantineKey)
        defaults?.removeObject(forKey: Self.acknowledgementQuarantineKey)
        if !persistAcknowledgements(acknowledgedSessionCompletions) {
            note(.saveNotConfirmed, for: .acknowledgements)
        }
        if !persistEntries(entries) { note(.saveNotConfirmed, for: .entries) }
    }

    /// Hide the notices the user has read. One that is still blocking saves
    /// stays: dismissing it would hide the only explanation for why nothing is
    /// being saved.
    func dismissStorageNotices() {
        storageNotices = storageNotices.filter(\.blocksSaving)
    }

    private func updateBadge() {
        guard updatesDockBadge else { return }
        NSApp?.dockTile.badgeLabel = entries.isEmpty ? nil : "\(entries.count)"
    }

    /// Clearing is only honest once it survives a relaunch, so both payloads
    /// are written before either becomes the state the UI trusts. If a write
    /// cannot be confirmed nothing changes on screen: a badge that empties and
    /// refills on the next launch is worse than one that stays put and says so.
    @discardableResult
    private func commit(
        entries newEntries: [Entry],
        acknowledgements newAcknowledgements: [String: Int64]
    ) -> Bool {
        let acknowledged = persistAcknowledgements(newAcknowledgements)
        let stored = persistEntries(newEntries)
        guard acknowledged, stored else {
            // Put whichever half did land back in step with the live state.
            if acknowledged { persistAcknowledgements(acknowledgedSessionCompletions) }
            if stored { persistEntries(entries) }
            note(.saveNotConfirmed, for: stored ? .acknowledgements : .entries)
            return false
        }
        entries = newEntries
        acknowledgedSessionCompletions = newAcknowledgements
        updateBadge()
        return true
    }

    private func note(_ kind: AttentionStorageNotice.Kind, for payload: AttentionStorageNotice.Payload) {
        let notice = AttentionStorageNotice(payload: payload, kind: kind, preservedCopyKey: nil)
        guard !storageNotices.contains(notice) else { return }
        storageNotices.append(notice)
    }

    /// The acknowledgement map that results from the user visiting these
    /// entries. Pure, so the caller can persist it before it becomes state.
    private func acknowledgements(visiting candidates: [Entry]) -> [String: Int64] {
        var updated = acknowledgedSessionCompletions
        for entry in candidates where entry.kind == .sessionResponded {
            let completedAt = Int64(entry.at.timeIntervalSince1970 * 1_000)
            updated[entry.targetID] = max(updated[entry.targetID, default: .min], completedAt)
        }
        return Self.trimmed(updated)
    }

    private static func trimmed(_ acknowledgements: [String: Int64]) -> [String: Int64] {
        guard acknowledgements.count > maximumAcknowledgements else { return acknowledgements }
        return Dictionary(
            uniqueKeysWithValues: acknowledgements
                .sorted { lhs, rhs in lhs.value > rhs.value }
                .prefix(maximumAcknowledgements)
                .map { ($0.key, $0.value) }
        )
    }

    // MARK: - Durable storage

    private struct StoredEntries: Encodable {
        let schemaVersion: Int
        let entries: [Entry]
    }

    private struct StoredAcknowledgements: Encodable {
        let schemaVersion: Int
        let acknowledgements: [String: Int64]
    }

    /// Every write is confirmed by reading the bytes back. A defaults store
    /// that drops the write — full container, revoked sandbox extension — is
    /// otherwise indistinguishable from one that accepted it.
    @discardableResult
    private func persistEntries(_ value: [Entry]) -> Bool {
        guard let defaults else { return true }
        guard !protectedPayloads.contains(.entries) else { return false }
        guard let data = try? JSONEncoder().encode(
            StoredEntries(schemaVersion: Self.storageSchemaVersion, entries: value)
        ), data.count <= Self.maximumStoredBytes else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return defaults.data(forKey: Self.storageKey) == data
    }

    @discardableResult
    private func persistAcknowledgements(_ value: [String: Int64]) -> Bool {
        guard let defaults else { return true }
        guard !protectedPayloads.contains(.acknowledgements) else { return false }
        guard let data = try? JSONEncoder().encode(
            StoredAcknowledgements(
                schemaVersion: Self.storageSchemaVersion,
                acknowledgements: value
            )
        ), data.count <= Self.maximumStoredBytes else { return false }
        defaults.set(data, forKey: Self.acknowledgementStorageKey)
        return defaults.data(forKey: Self.acknowledgementStorageKey) == data
    }

    /// What one stored payload yielded: the part that survived, what the user
    /// needs told about the rest, and whether the bytes must be left alone.
    private struct StorageLoad<Value> {
        let value: Value
        let notice: AttentionStorageNotice?
        let isProtected: Bool

        init(value: Value, notice: AttentionStorageNotice? = nil, isProtected: Bool = false) {
            self.value = value
            self.notice = notice
            self.isProtected = isProtected
        }
    }

    /// Steps over one array element without caring what it holds.
    private struct SkippedRecord: Decodable {
        init(from _: Decoder) throws {}
    }

    /// Decodes the entry array one record at a time so a single malformed row
    /// costs only itself. Pending work is the whole point of this file: losing
    /// every permission ask because one entry was truncated is the failure this
    /// exists to prevent.
    private struct SalvagedEntryList: Decodable {
        var entries: [Entry] = []
        var droppedRecords = 0

        init() {}

        init(from decoder: Decoder) throws {
            var records = try decoder.unkeyedContainer()
            while !records.isAtEnd {
                let index = records.currentIndex
                if let entry = try? records.decode(Entry.self) {
                    entries.append(entry)
                } else {
                    _ = try? records.decode(SkippedRecord.self)
                    droppedRecords += 1
                }
                // A container that will not advance would spin forever.
                guard records.currentIndex > index else { break }
            }
        }
    }

    private struct SalvagedEntriesEnvelope: Decodable {
        let schemaVersion: Int
        let list: SalvagedEntryList

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case entries
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            // A newer schema may not hold an array here at all; the version
            // alone decides what happens next.
            list = (try? container.decode(SalvagedEntryList.self, forKey: .entries))
                ?? SalvagedEntryList()
        }
    }

    /// The same one-record-at-a-time read for the acknowledgement map: a single
    /// unreadable value must not re-notify every terminal the user has visited.
    private struct SalvagedAcknowledgementMap: Decodable {
        var acknowledgements: [String: Int64] = [:]
        var droppedRecords = 0

        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }

            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue _: Int) { return nil }
        }

        init() {}

        init(from decoder: Decoder) throws {
            let records = try decoder.container(keyedBy: AnyKey.self)
            for key in records.allKeys {
                if let completedAt = try? records.decode(Int64.self, forKey: key) {
                    acknowledgements[key.stringValue] = completedAt
                } else {
                    droppedRecords += 1
                }
            }
        }
    }

    private struct SalvagedAcknowledgementsEnvelope: Decodable {
        let schemaVersion: Int
        let map: SalvagedAcknowledgementMap

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case acknowledgements
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            map = (try? container.decode(SalvagedAcknowledgementMap.self, forKey: .acknowledgements))
                ?? SalvagedAcknowledgementMap()
        }
    }

    private static func loadEntries(from defaults: UserDefaults?) -> StorageLoad<[Entry]> {
        guard let defaults, let data = defaults.data(forKey: storageKey) else {
            // Absent is not corrupt: a first launch has nothing to explain.
            return StorageLoad(value: [])
        }
        if data.count <= maximumStoredBytes,
           let envelope = try? JSONDecoder().decode(SalvagedEntriesEnvelope.self, from: data) {
            guard envelope.schemaVersion <= storageSchemaVersion else {
                return StorageLoad(
                    value: [],
                    notice: AttentionStorageNotice(
                        payload: .entries,
                        kind: .newerVersion(schemaVersion: envelope.schemaVersion),
                        preservedCopyKey: nil
                    ),
                    isProtected: true
                )
            }
            return sanitized(envelope.list)
        }
        if data.count <= maximumStoredBytes,
           let legacy = try? JSONDecoder().decode(SalvagedEntryList.self, from: data) {
            // Schema 1 wrote the bare array. The next save re-envelopes it.
            return sanitized(legacy)
        }
        return StorageLoad(
            value: [],
            notice: preserveUnreadable(
                data,
                payload: .entries,
                key: storageKey,
                quarantineKey: entriesQuarantineKey,
                in: defaults
            )
        )
    }

    /// Defaults are user-writable. Bound every restored field before it can
    /// enter SwiftUI, then restore only the newest target/kind event. A record
    /// the bounds reject counts as lost work too — from the badge's point of
    /// view it is exactly that.
    private static func sanitized(_ list: SalvagedEntryList) -> StorageLoad<[Entry]> {
        let valid = list.entries.filter { entry in
            !entry.id.isEmpty && entry.id.utf8.count <= 1_024
                && !entry.targetID.isEmpty && entry.targetID.utf8.count <= 512
                && entry.title.utf8.count <= 512
                && entry.detail.utf8.count <= 2_048
                && entry.at.timeIntervalSince1970.isFinite
        }
        var seen: Set<String> = []
        let newestUnique = valid.reversed().filter { entry in
            seen.insert("\(entry.targetID)\u{0}\(entry.kind.rawValue)").inserted
        }.reversed()
        let dropped = list.droppedRecords + (list.entries.count - valid.count)
        return StorageLoad(
            value: Array(newestUnique.suffix(maximumEntries)),
            notice: dropped > 0
                ? AttentionStorageNotice(
                    payload: .entries,
                    kind: .recordsDropped(count: dropped),
                    preservedCopyKey: nil
                )
                : nil
        )
    }

    private static func loadAcknowledgements(from defaults: UserDefaults?) -> StorageLoad<[String: Int64]> {
        guard let defaults, let data = defaults.data(forKey: acknowledgementStorageKey) else {
            return StorageLoad(value: [:])
        }
        if data.count <= maximumStoredBytes,
           let envelope = try? JSONDecoder().decode(SalvagedAcknowledgementsEnvelope.self, from: data) {
            guard envelope.schemaVersion <= storageSchemaVersion else {
                return StorageLoad(
                    value: [:],
                    notice: AttentionStorageNotice(
                        payload: .acknowledgements,
                        kind: .newerVersion(schemaVersion: envelope.schemaVersion),
                        preservedCopyKey: nil
                    ),
                    isProtected: true
                )
            }
            return sanitized(envelope.map)
        }
        if data.count <= maximumStoredBytes,
           let legacy = try? JSONDecoder().decode(SalvagedAcknowledgementMap.self, from: data) {
            return sanitized(legacy)
        }
        return StorageLoad(
            value: [:],
            notice: preserveUnreadable(
                data,
                payload: .acknowledgements,
                key: acknowledgementStorageKey,
                quarantineKey: acknowledgementQuarantineKey,
                in: defaults
            )
        )
    }

    private static func sanitized(_ map: SalvagedAcknowledgementMap) -> StorageLoad<[String: Int64]> {
        let valid = map.acknowledgements.filter { targetID, completedAt in
            !targetID.isEmpty && targetID.utf8.count <= 512 && completedAt >= 0
        }
        let dropped = map.droppedRecords + (map.acknowledgements.count - valid.count)
        return StorageLoad(
            value: trimmed(valid),
            notice: dropped > 0
                ? AttentionStorageNotice(
                    payload: .acknowledgements,
                    kind: .recordsDropped(count: dropped),
                    preservedCopyKey: nil
                )
                : nil
        )
    }

    /// Keep bytes this build cannot read beside the live key rather than
    /// deleting them: the user's pending work is in there somewhere, and the
    /// build that can read it may not be this one.
    private static func preserveUnreadable(
        _ data: Data,
        payload: AttentionStorageNotice.Payload,
        key: String,
        quarantineKey: String,
        in defaults: UserDefaults
    ) -> AttentionStorageNotice {
        // Write the kept copy before clearing the original, so a defaults store
        // that refuses the write does not also lose the bytes.
        var preserved = false
        if data.count <= maximumQuarantinedBytes {
            defaults.set(data, forKey: quarantineKey)
            preserved = defaults.data(forKey: quarantineKey) == data
        }
        if !preserved { defaults.removeObject(forKey: quarantineKey) }
        defaults.removeObject(forKey: key)
        return AttentionStorageNotice(
            payload: payload,
            kind: .unreadable,
            preservedCopyKey: preserved ? quarantineKey : nil
        )
    }
}
