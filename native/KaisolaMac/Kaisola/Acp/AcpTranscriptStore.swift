import Foundation

/// Durable usage rollup stored beside a chat's visible transcript. Keeping the
/// latest context window, peak, turns, and cumulative cost together means a
/// restored ACP card and Settings > Usage agree immediately after relaunch.
struct AcpPersistedUsage: Codable, Equatable, Sendable {
    var title: String
    var agentID: String
    var latestUsed: Int
    var latestMax: Int
    var peakUsed: Int
    var turns: Int
    var costAmount: Double?
    var costCurrency: String?
}

/// Mode-0600 transcript persistence for native ACP cards. Provider
/// `session/resume` restores the agent's internal context; this store restores
/// what the user can see immediately, without waiting for an adapter replay.
actor AcpTranscriptStore {
    struct Entry: Codable, Equatable, Sendable {
        var rows: [AcpTranscriptRow]
        var updatedAt: Int64
        var usage: AcpPersistedUsage?

        init(rows: [AcpTranscriptRow], updatedAt: Int64, usage: AcpPersistedUsage? = nil) {
            self.rows = rows
            self.updatedAt = updatedAt
            self.usage = usage
        }
    }

    private struct Payload: Codable {
        var entries: [String: Entry]
    }

    static let maximumChatCount = 40
    static let live = AcpTranscriptStore(fileURL: NativePreviewPaths.agentChatTranscriptStore)

    private let fileURL: URL
    private var pending: [String: Entry] = [:]
    private var flushTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func rows(for chatID: String) -> [AcpTranscriptRow] {
        entry(for: chatID)?.rows ?? []
    }

    func entry(for chatID: String) -> Entry? {
        pending[chatID] ?? read()?.entries[chatID]
    }

    /// Coalesce streaming chunks into one disk write. The visible model remains
    /// live in memory; the durable tail trails it by at most 350 milliseconds.
    func scheduleSave(_ rows: [AcpTranscriptRow], for chatID: String, now: Int64? = nil) {
        guard !chatID.isEmpty else { return }
        let existing = entry(for: chatID)
        pending[chatID] = Entry(
            rows: rows,
            updatedAt: now ?? Int64(Date().timeIntervalSince1970 * 1_000),
            usage: existing?.usage
        )
        scheduleFlush()
    }

    func scheduleUsage(_ usage: AcpPersistedUsage, for chatID: String, now: Int64? = nil) {
        guard !chatID.isEmpty else { return }
        let existing = entry(for: chatID)
        pending[chatID] = Entry(
            rows: existing?.rows ?? [],
            updatedAt: now ?? Int64(Date().timeIntervalSince1970 * 1_000),
            usage: usage
        )
        scheduleFlush()
    }

    func clearUsage() {
        var payload = read() ?? Payload(entries: [:])
        for id in Array(payload.entries.keys) {
            if payload.entries[id]?.rows.isEmpty == true {
                payload.entries.removeValue(forKey: id)
            } else {
                payload.entries[id]?.usage = nil
            }
        }
        for id in Array(pending.keys) {
            if pending[id]?.rows.isEmpty == true {
                pending.removeValue(forKey: id)
            } else {
                pending[id]?.usage = nil
            }
        }
        write(payload)
    }

    func removeUsage(chatID: String) {
        if pending[chatID]?.rows.isEmpty == true {
            pending.removeValue(forKey: chatID)
        } else if pending[chatID] != nil {
            pending[chatID]?.usage = nil
        }
        var payload = read() ?? Payload(entries: [:])
        if payload.entries[chatID]?.rows.isEmpty == true {
            payload.entries.removeValue(forKey: chatID)
        } else {
            payload.entries[chatID]?.usage = nil
        }
        write(payload)
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func remove(chatID: String) {
        pending.removeValue(forKey: chatID)
        var payload = read() ?? Payload(entries: [:])
        payload.entries.removeValue(forKey: chatID)
        write(payload)
    }

    func flush() {
        guard !pending.isEmpty else { return }
        var payload = read() ?? Payload(entries: [:])
        for (id, entry) in pending { payload.entries[id] = entry }
        pending.removeAll()
        if payload.entries.count > Self.maximumChatCount {
            let keep = payload.entries
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(Self.maximumChatCount)
                .map(\.key)
            payload.entries = payload.entries.filter { Set(keep).contains($0.key) }
        }
        write(payload)
    }

    private func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func write(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(payload)
            let temporary = directory.appendingPathComponent(
                ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)"
            )
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            // Persistence is best-effort; a write failure must never stop a chat.
        }
    }
}
