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

    enum Kind: String, Codable, Equatable {
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
    /// Highest terminal completion the user has visited, keyed by durable
    /// broker session id. Unlike an inbox entry this survives clearing, so a
    /// relaunch can recover genuinely new responses without resurrecting old
    /// ones merely because the new process missed their working -> responded
    /// transition.
    private var acknowledgedSessionCompletions: [String: Int64] = [:]
    private let defaults: UserDefaults?
    private let postsNotifications: Bool
    private let updatesDockBadge: Bool

    private static let storageKey = "attention.entries.v1"
    private static let acknowledgementStorageKey = "attention.acknowledged-session-completions.v1"
    private static let maximumEntries = 50
    private static let maximumAcknowledgements = 200
    private static let maximumStoredBytes = 256 * 1_024

    var count: Int { entries.count }

    init(
        defaults: UserDefaults? = .standard,
        postsNotifications: Bool = true,
        updatesDockBadge: Bool = true
    ) {
        self.defaults = defaults
        self.postsNotifications = postsNotifications
        self.updatesDockBadge = updatesDockBadge
        entries = Self.loadEntries(from: defaults)
        acknowledgedSessionCompletions = Self.loadAcknowledgements(from: defaults)
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
        acknowledgedSessionCompletions[targetID] = max(
            acknowledgedSessionCompletions[targetID, default: .min],
            completedAt
        )
        trimAcknowledgements()
        entries.removeAll { $0.targetID == targetID }
        persistAcknowledgements()
        persistEntries()
        updateBadge()
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
        persistEntries()
        updateBadge()
        if postsNotifications {
            NotificationBridge.shared.post(kind: kind, title: title, detail: detail, targetID: targetID)
        }
    }

    /// Clear every entry pointing at a target (called when the user visits it).
    func clear(targetID: String) {
        guard entries.contains(where: { $0.targetID == targetID }) else { return }
        acknowledgeSessionEntries(entries.filter { $0.targetID == targetID })
        entries.removeAll { $0.targetID == targetID }
        persistAcknowledgements()
        persistEntries()
        updateBadge()
    }

    func clearAll() {
        acknowledgeSessionEntries(entries)
        entries.removeAll()
        persistAcknowledgements()
        persistEntries()
        updateBadge()
    }

    private func updateBadge() {
        guard updatesDockBadge else { return }
        NSApp?.dockTile.badgeLabel = entries.isEmpty ? nil : "\(entries.count)"
    }

    private func persistEntries() {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(entries),
              data.count <= Self.maximumStoredBytes else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func acknowledgeSessionEntries(_ candidates: [Entry]) {
        for entry in candidates where entry.kind == .sessionResponded {
            let completedAt = Int64(entry.at.timeIntervalSince1970 * 1_000)
            acknowledgedSessionCompletions[entry.targetID] = max(
                acknowledgedSessionCompletions[entry.targetID, default: .min],
                completedAt
            )
        }
        trimAcknowledgements()
    }

    private func trimAcknowledgements() {
        guard acknowledgedSessionCompletions.count > Self.maximumAcknowledgements else { return }
        acknowledgedSessionCompletions = Dictionary(
            uniqueKeysWithValues: acknowledgedSessionCompletions
                .sorted { lhs, rhs in lhs.value > rhs.value }
                .prefix(Self.maximumAcknowledgements)
                .map { ($0.key, $0.value) }
        )
    }

    private func persistAcknowledgements() {
        guard let defaults else { return }
        guard let data = try? JSONEncoder().encode(acknowledgedSessionCompletions),
              data.count <= Self.maximumStoredBytes else { return }
        defaults.set(data, forKey: Self.acknowledgementStorageKey)
    }

    private static func loadEntries(from defaults: UserDefaults?) -> [Entry] {
        guard let defaults,
              let data = defaults.data(forKey: storageKey) else { return [] }
        guard data.count <= maximumStoredBytes,
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            defaults.removeObject(forKey: storageKey)
            return []
        }

        // Defaults are user-writable. Bound every restored field before it can
        // enter SwiftUI, then restore only the newest target/kind event.
        let valid = decoded.filter { entry in
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
        return Array(newestUnique.suffix(maximumEntries))
    }

    private static func loadAcknowledgements(from defaults: UserDefaults?) -> [String: Int64] {
        guard let defaults,
              let data = defaults.data(forKey: acknowledgementStorageKey) else { return [:] }
        guard data.count <= maximumStoredBytes,
              let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) else {
            defaults.removeObject(forKey: acknowledgementStorageKey)
            return [:]
        }
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
