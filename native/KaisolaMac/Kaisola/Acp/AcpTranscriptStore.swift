import CryptoKit
import Darwin
import Foundation
import SQLite3

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

/// Mode-0600, actor-serialized transcript persistence for native ACP cards.
/// Provider `session/resume` restores the agent's internal context; this store
/// restores what the user can see immediately without decoding an unbounded
/// transcript at launch. Rows have stable per-chat ordinals and are read from
/// the tail backwards in bounded pages.
actor AcpTranscriptStore {
    struct Entry: Codable, Equatable, Sendable {
        var rows: [AcpTranscriptRow]
        var updatedAt: Int64
        var usage: AcpPersistedUsage?
        var draft: String?
        var attachments: [AcpAttachment]
        var sessionID: String?

        init(
            rows: [AcpTranscriptRow],
            updatedAt: Int64,
            usage: AcpPersistedUsage? = nil,
            draft: String? = nil,
            attachments: [AcpAttachment] = [],
            sessionID: String? = nil
        ) {
            self.rows = rows
            self.updatedAt = updatedAt
            self.usage = usage
            self.draft = draft
            self.attachments = attachments
            self.sessionID = sessionID
        }
    }

    struct Page: Equatable, Sendable {
        var rows: [AcpTranscriptRow]
        /// Ordinal of `rows.first`, or the requested boundary for an empty page.
        var startOrdinal: Int64
        /// One past the final ordinal in this page.
        var endOrdinalExclusive: Int64
        /// Exact number of retained rows before this page, independent of any
        /// accidental ordinal gaps in a damaged or hand-edited database.
        var earlierRowCount: Int
        var totalRowCount: Int

        static let empty = Page(
            rows: [],
            startOrdinal: 0,
            endOrdinalExclusive: 0,
            earlierRowCount: 0,
            totalRowCount: 0
        )
    }

    struct Restoration: Equatable, Sendable {
        var page: Page
        var updatedAt: Int64
        var usage: AcpPersistedUsage?
        var draft: String?
        var attachments: [AcpAttachment]
        var sessionID: String?
    }

    enum StoreError: Error, Equatable {
        case database(String)
        case corruptLegacyArchive
        case legacyArchiveTooLarge(maxBytes: Int)
        case invalidSnapshot
    }

    /// Disk is deliberately cheap to spend (2026-08-06 spec): retention is
    /// generous, and eviction stays oldest-first purely as a sanity bound.
    static let maximumChatCount = 1_000
    static let maximumPageSize = 500
    static let maximumDraftBytes = 256 * 1_024
    static let maximumAttachmentCount = 8
    static let maximumAttachmentBytes = 20 * 1_048_576
    static let maximumLegacyArchiveBytes = 512 * 1_048_576
    static let live: AcpTranscriptStore = {
        let environment = ProcessInfo.processInfo.environment
        let isXCTest = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        guard isXCTest else {
            return AcpTranscriptStore(
                databaseURL: NativePreviewPaths.agentChatTranscriptDatabase,
                legacyJSONURL: NativePreviewPaths.agentChatTranscriptStore
            )
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-xctest-transcripts-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
            isDirectory: true
        )
        return AcpTranscriptStore(
            databaseURL: directory.appendingPathComponent("transcripts-v2.sqlite3"),
            legacyJSONURL: directory.appendingPathComponent("transcripts-v1.json")
        )
    }()

    private struct LegacyEntry: Decodable {
        var rows: [AcpTranscriptRow]
        var updatedAt: Int64
        var usage: AcpPersistedUsage?
    }

    private struct LegacyPayload: Decodable {
        var entries: [String: LegacyEntry]
    }

    private struct RowWrite: Sendable {
        var rows: [AcpTranscriptRow]
        var startOrdinal: Int64
    }

    private enum FieldChange<Value: Sendable>: Sendable {
        case unchanged
        case set(Value?)
    }

    private struct PendingWrite: Sendable {
        var rows: RowWrite?
        var usage: FieldChange<AcpPersistedUsage> = .unchanged
        var draft: FieldChange<String> = .unchanged
        var attachments: FieldChange<[AcpAttachment]> = .unchanged
        var sessionID: FieldChange<String> = .unchanged
        var updatedAt: Int64

        init(updatedAt: Int64) {
            self.updatedAt = updatedAt
        }
    }

    private struct StoredMetadata: Sendable {
        var updatedAt: Int64
        var usage: AcpPersistedUsage?
        var draft: String?
        var attachments: [AcpAttachment]
        var sessionID: String?
    }

    /// SQLite exposes its connection as an `OpaquePointer`, which older Swift 6
    /// region-based isolation checking cannot safely follow through our nested,
    /// synchronous transaction closures. Keep the pointer in one explicitly
    /// owned, unchecked-sendable box. The box never leaves this actor and every
    /// database operation remains actor-serialized; the annotation only makes
    /// that lifetime and synchronization boundary visible to the compiler.
    private final class SQLiteHandle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(_ pointer: OpaquePointer) { self.pointer = pointer }

        deinit { sqlite3_close_v2(pointer) }
    }

    nonisolated let databaseURL: URL
    nonisolated let legacyJSONURL: URL?

    private var databaseHandle: SQLiteHandle?
    private var pending: [String: PendingWrite] = [:]
    private var flushTask: Task<Void, Never>?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Compatibility initializer: callers hand us the v1 JSON path and the v2
    /// database is created beside it. The JSON remains untouched after a
    /// successful migration so rollback and manual recovery retain the source.
    init(fileURL: URL) {
        let legacy = fileURL.standardizedFileURL
        self.databaseURL = legacy.deletingPathExtension().appendingPathExtension("sqlite3")
        self.legacyJSONURL = legacy
    }

    init(databaseURL: URL, legacyJSONURL: URL? = nil) {
        self.databaseURL = databaseURL.standardizedFileURL
        self.legacyJSONURL = legacyJSONURL?.standardizedFileURL
    }

    /// Explicit full-history compatibility read. Product restoration uses
    /// `restoration(for:tailLimit:)`; this API is reserved for bounded tests,
    /// export, and diagnostics that intentionally ask for every row.
    func rows(for chatID: String) -> [AcpTranscriptRow] {
        entry(for: chatID)?.rows ?? []
    }

    func entry(for chatID: String) -> Entry? {
        guard Self.validChatID(chatID) else { return nil }
        flush()
        guard let database = try? openDatabase(),
              let metadata = try? readMetadata(chatID: chatID, database: database) else { return nil }
        let allRows = (try? readAllRows(chatID: chatID, database: database)) ?? []
        return Entry(
            rows: allRows,
            updatedAt: metadata.updatedAt,
            usage: metadata.usage,
            draft: metadata.draft,
            attachments: metadata.attachments,
            sessionID: metadata.sessionID
        )
    }

    /// Restore only the newest bounded page plus compact per-chat metadata.
    /// The returned `earlierRowCount` drives repeated top-edge reads without
    /// materializing the rest of the session in memory.
    func restoration(for chatID: String, tailLimit: Int) -> Restoration? {
        guard Self.validChatID(chatID) else { return nil }
        flush()
        guard let database = try? openDatabase(),
              let metadata = try? readMetadata(chatID: chatID, database: database),
              let page = try? readTailPage(
                  chatID: chatID,
                  limit: Self.boundedPageLimit(tailLimit),
                  database: database
              ) else { return nil }
        return Restoration(
            page: page,
            updatedAt: metadata.updatedAt,
            usage: metadata.usage,
            draft: metadata.draft,
            attachments: metadata.attachments,
            sessionID: metadata.sessionID
        )
    }

    /// Read the bounded page immediately before an already loaded ordinal.
    func page(for chatID: String, beforeOrdinal: Int64, limit: Int) -> Page? {
        guard Self.validChatID(chatID), beforeOrdinal >= 0,
              let database = try? openDatabase() else { return nil }
        return try? readPage(
            chatID: chatID,
            beforeOrdinal: beforeOrdinal,
            limit: Self.boundedPageLimit(limit),
            database: database
        )
    }

    /// Coalesce streaming chunks into one SQLite transaction. `startOrdinal`
    /// identifies the first loaded row, allowing a restored tail to update
    /// without deleting retained pages that have not been read this launch.
    func scheduleSave(
        _ rows: [AcpTranscriptRow],
        for chatID: String,
        startOrdinal: Int64 = 0,
        now: Int64? = nil
    ) {
        guard Self.validChatID(chatID), startOrdinal >= 0,
              startOrdinal <= Int64.max - Int64(rows.count) else { return }
        let timestamp = Self.timestamp(now)
        var write = pending[chatID] ?? PendingWrite(updatedAt: timestamp)
        write.rows = RowWrite(rows: rows, startOrdinal: startOrdinal)
        write.updatedAt = max(write.updatedAt, timestamp)
        pending[chatID] = write
        scheduleFlush()
    }

    func scheduleUsage(_ usage: AcpPersistedUsage, for chatID: String, now: Int64? = nil) {
        guard Self.validChatID(chatID) else { return }
        let timestamp = Self.timestamp(now)
        var write = pending[chatID] ?? PendingWrite(updatedAt: timestamp)
        write.usage = .set(usage)
        write.updatedAt = max(write.updatedAt, timestamp)
        pending[chatID] = write
        scheduleFlush()
    }

    func scheduleDraft(_ draft: String, for chatID: String, now: Int64? = nil) {
        guard Self.validChatID(chatID),
              draft.lengthOfBytes(using: .utf8) <= Self.maximumDraftBytes else { return }
        let timestamp = Self.timestamp(now)
        var write = pending[chatID] ?? PendingWrite(updatedAt: timestamp)
        write.draft = .set(draft.isEmpty ? nil : draft)
        write.updatedAt = max(write.updatedAt, timestamp)
        pending[chatID] = write
        scheduleFlush()
    }

    func scheduleAttachments(
        _ attachments: [AcpAttachment],
        for chatID: String,
        now: Int64? = nil
    ) {
        guard Self.validChatID(chatID), Self.attachmentsAreBounded(attachments) else { return }
        let timestamp = Self.timestamp(now)
        var write = pending[chatID] ?? PendingWrite(updatedAt: timestamp)
        write.attachments = .set(attachments.isEmpty ? nil : attachments)
        write.updatedAt = max(write.updatedAt, timestamp)
        pending[chatID] = write
        scheduleFlush()
    }

    func scheduleSessionID(_ sessionID: String?, for chatID: String, now: Int64? = nil) {
        guard Self.validChatID(chatID) else { return }
        let normalized = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized?.lengthOfBytes(using: .utf8) ?? 0 <= 4_096 else { return }
        let timestamp = Self.timestamp(now)
        var write = pending[chatID] ?? PendingWrite(updatedAt: timestamp)
        write.sessionID = .set(normalized?.isEmpty == false ? normalized : nil)
        write.updatedAt = max(write.updatedAt, timestamp)
        pending[chatID] = write
        scheduleFlush()
    }

    func clearUsage() {
        flush()
        for chatID in pending.keys {
            pending[chatID]?.usage = .set(nil)
        }
        guard let database = try? openDatabase() else { return }
        do {
            try transaction(database) {
                try execute("UPDATE chats SET usage_json = NULL", database: database)
                try pruneEmptyChats(database)
                try setMetadataValue("1", for: "v2_has_written", database: database)
            }
        } catch {
            // A failed reset must not mutate the actor's in-memory queue.
        }
    }

    func removeUsage(chatID: String) {
        guard Self.validChatID(chatID) else { return }
        flush()
        pending[chatID]?.usage = .set(nil)
        guard let database = try? openDatabase() else { return }
        do {
            try transaction(database) {
                try withStatement("UPDATE chats SET usage_json = NULL WHERE chat_id = ?", database: database) {
                    try bind(chatID, at: 1, statement: $0, database: database)
                    try stepDone($0, database: database)
                }
                try pruneEmptyChats(database)
                try setMetadataValue("1", for: "v2_has_written", database: database)
            }
        } catch {
            // Usage removal is best-effort and never interrupts a live chat.
        }
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
        guard Self.validChatID(chatID) else { return }
        pending.removeValue(forKey: chatID)
        guard let database = try? openDatabase() else { return }
        do {
            try transaction(database) {
                try withStatement("DELETE FROM chats WHERE chat_id = ?", database: database) {
                    try bind(chatID, at: 1, statement: $0, database: database)
                    try stepDone($0, database: database)
                }
                try setMetadataValue("1", for: "v2_has_written", database: database)
            }
        } catch {
            // Explicit removal remains retryable by the caller's durable model.
        }
    }

    // MARK: - Deletion tombstones (closed-stays-closed §4e)

    /// Written FIRST when a chat is deleted, before any in-memory removal, so
    /// every phase after it — and every other window sharing this database —
    /// converges on "gone" even across a crash. Throws so the caller can
    /// surface a failed delete instead of reporting success.
    func tombstone(chatID: String) throws {
        guard Self.validChatID(chatID) else { return }
        pending.removeValue(forKey: chatID)
        let database = try openDatabase()
        try transaction(database) {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS deleted_chats (
                    chat_id TEXT PRIMARY KEY NOT NULL,
                    deleted_at INTEGER NOT NULL
                ) WITHOUT ROWID
                """,
                database: database
            )
            try withStatement(
                "INSERT OR REPLACE INTO deleted_chats(chat_id, deleted_at) VALUES (?, ?)",
                database: database
            ) {
                try bind(chatID, at: 1, statement: $0, database: database)
                try bind(Int64(Date().timeIntervalSince1970 * 1_000), at: 2, statement: $0, database: database)
                try stepDone($0, database: database)
            }
        }
    }

    func isTombstoned(chatID: String) -> Bool {
        guard Self.validChatID(chatID),
              let database = try? openDatabase(),
              tableExists("deleted_chats", database: database) else { return false }
        var found = false
        try? withStatement(
            "SELECT 1 FROM deleted_chats WHERE chat_id = ? LIMIT 1",
            database: database
        ) {
            try bind(chatID, at: 1, statement: $0, database: database)
            found = try stepRow($0, database: database)
        }
        return found
    }

    /// Resume any deletion interrupted after its durable tombstone commit,
    /// then drain tombstones whose chat rows are fully gone. Both statements
    /// share one transaction so a failed launch cleanup retains the fence for
    /// the next retry instead of stranding transcript bytes without intent.
    func vacuumTombstones() {
        guard let database = try? openDatabase(),
              tableExists("deleted_chats", database: database) else { return }
        try? transaction(database) {
            // `transcript_rows` follows through its ON DELETE CASCADE. This is
            // the idempotent restart path for a crash before remove(chatID:).
            try execute(
                """
                DELETE FROM chats
                WHERE chat_id IN (SELECT chat_id FROM deleted_chats)
                """,
                database: database
            )
            try execute(
                """
                DELETE FROM deleted_chats
                WHERE chat_id NOT IN (SELECT chat_id FROM chats)
                """,
                database: database
            )
        }
    }

    private func tableExists(_ name: String, database: SQLiteHandle) -> Bool {
        var exists = false
        try? withStatement(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            database: database
        ) {
            try bind(name, at: 1, statement: $0, database: database)
            exists = try stepRow($0, database: database)
        }
        return exists
    }

    func flush() {
        flushTask = nil
        guard !pending.isEmpty else { return }
        let writes = pending
        pending.removeAll()
        do {
            let database = try openDatabase()
            try transaction(database) {
                for chatID in writes.keys.sorted() {
                    guard let write = writes[chatID] else { continue }
                    // A buffered write racing a deletion (a final stream chunk
                    // landing as the user hits delete) must not re-materialize
                    // tombstoned content 350ms later (§4e).
                    guard !isTombstoned(chatID: chatID) else { continue }
                    try apply(write, chatID: chatID, database: database)
                }
                try pruneEmptyChats(database)
                try pruneOldChats(database)
                try setMetadataValue("1", for: "v2_has_written", database: database)
            }
            try secureDatabaseFile()
        } catch {
            // Retain the exact coalesced snapshots. A later stream update or an
            // explicit lifecycle flush retries them instead of silently losing
            // the newest durable tail after an incidental I/O failure.
            for (chatID, write) in writes where pending[chatID] == nil {
                pending[chatID] = write
            }
        }
    }

    // MARK: - SQLite lifecycle and migration

    private func openDatabase() throws -> SQLiteHandle {
        if let databaseHandle { return databaseHandle }
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Self.validateDatabaseLeaf(databaseURL)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map(Self.errorMessage) ?? "could not open database"
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError.database(message)
        }

        let database = SQLiteHandle(handle)
        do {
            // Close the brief create-to-chmod window before schema or legacy
            // bytes enter the file. SQLite's rollback journal inherits this
            // private database ownership contract.
            try secureDatabaseFile()
            try execute("PRAGMA foreign_keys = ON", database: database)
            try execute("PRAGMA trusted_schema = OFF", database: database)
            try execute("PRAGMA journal_mode = DELETE", database: database)
            try execute("PRAGMA synchronous = FULL", database: database)
            _ = sqlite3_busy_timeout(database.pointer, 3_000)
            try transaction(database) {
                try createSchema(database)
                try migrateLegacyArchiveIfNeeded(database)
            }
            try secureDatabaseFile()
            databaseHandle = database
            return database
        } catch {
            throw error
        }
    }

    private func createSchema(_ database: SQLiteHandle) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS store_meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            ) WITHOUT ROWID
            """,
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chats (
                chat_id TEXT PRIMARY KEY NOT NULL,
                updated_at INTEGER NOT NULL,
                usage_json BLOB,
                draft TEXT,
                attachments_json BLOB,
                session_id TEXT
            ) WITHOUT ROWID
            """,
            database: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS transcript_rows (
                chat_id TEXT NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
                row_json BLOB NOT NULL,
                PRIMARY KEY (chat_id, ordinal)
            ) WITHOUT ROWID
            """,
            database: database
        )
        try execute(
            "CREATE INDEX IF NOT EXISTS chats_by_recency ON chats(updated_at DESC, chat_id ASC)",
            database: database
        )
        try execute("PRAGMA user_version = 2", database: database)
    }

    /// Import the v1 monolithic JSON inside the same immediate transaction that
    /// creates the schema. The source file is never renamed or deleted. A
    /// decode/insert failure rolls every destination row back and leaves the
    /// marker absent, so the next launch can retry the exact source bytes.
    private func migrateLegacyArchiveIfNeeded(_ database: SQLiteHandle) throws {
        let previousFingerprint = try metadataValue(for: "legacy_v1_import", database: database)
        guard let legacyJSONURL,
              FileManager.default.fileExists(atPath: legacyJSONURL.path) else {
            if previousFingerprint == nil {
                try setMetadataValue("absent", for: "legacy_v1_import", database: database)
            }
            return
        }
        try Self.validateLegacyLeaf(legacyJSONURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: legacyJSONURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= Self.maximumLegacyArchiveBytes else {
            throw StoreError.legacyArchiveTooLarge(maxBytes: Self.maximumLegacyArchiveBytes)
        }
        let data = try Data(contentsOf: legacyJSONURL, options: [.mappedIfSafe])
        let fingerprint = "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        if previousFingerprint == fingerprint { return }
        // A rollback build may write the preserved JSON after v2 has become
        // authoritative. Never merge two independently advancing histories.
        // The only retry exception is an empty, never-written v2 database (for
        // example one pre-created by a launch probe before the final v1 save).
        let hasV2Writes = try metadataValue(for: "v2_has_written", database: database) == "1"
        let existingChatCount = try chatCount(database)
        if hasV2Writes || existingChatCount > 0 {
            return
        }
        guard let payload = try? decoder.decode(LegacyPayload.self, from: data) else {
            throw StoreError.corruptLegacyArchive
        }
        for chatID in payload.entries.keys.sorted() {
            guard Self.validChatID(chatID), let entry = payload.entries[chatID] else {
                throw StoreError.corruptLegacyArchive
            }
            try ensureChat(chatID, updatedAt: max(0, entry.updatedAt), database: database)
            if let usage = entry.usage {
                try updateBlob(
                    column: "usage_json",
                    data: try encoder.encode(usage),
                    chatID: chatID,
                    database: database
                )
            }
            for (index, row) in entry.rows.enumerated() {
                try insertRow(
                    row,
                    chatID: chatID,
                    ordinal: Int64(index),
                    database: database
                )
            }
        }
        try pruneOldChats(database)
        try setMetadataValue(fingerprint, for: "legacy_v1_import", database: database)
    }

    private func secureDatabaseFile() throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    // MARK: - Writes

    private func apply(_ write: PendingWrite, chatID: String, database: SQLiteHandle) throws {
        try ensureChat(chatID, updatedAt: write.updatedAt, database: database)
        if let rowWrite = write.rows {
            let prefixCount = try rowCount(
                chatID: chatID,
                beforeOrdinal: rowWrite.startOrdinal,
                database: database
            )
            guard rowWrite.startOrdinal == 0 || prefixCount == Int(rowWrite.startOrdinal) else {
                throw StoreError.invalidSnapshot
            }
            try withStatement(
                "DELETE FROM transcript_rows WHERE chat_id = ? AND ordinal >= ?",
                database: database
            ) {
                try bind(chatID, at: 1, statement: $0, database: database)
                sqlite3_bind_int64($0, 2, rowWrite.startOrdinal)
                try stepDone($0, database: database)
            }
            for (offset, row) in rowWrite.rows.enumerated() {
                try insertRow(
                    row,
                    chatID: chatID,
                    ordinal: rowWrite.startOrdinal + Int64(offset),
                    database: database
                )
            }
        }
        switch write.usage {
        case .unchanged: break
        case let .set(value):
            try updateBlob(
                column: "usage_json",
                data: try value.map(encoder.encode),
                chatID: chatID,
                database: database
            )
        }
        switch write.draft {
        case .unchanged: break
        case let .set(value):
            try updateText(column: "draft", value: value, chatID: chatID, database: database)
        }
        switch write.attachments {
        case .unchanged: break
        case let .set(value):
            try updateBlob(
                column: "attachments_json",
                data: try value.map(encoder.encode),
                chatID: chatID,
                database: database
            )
        }
        switch write.sessionID {
        case .unchanged: break
        case let .set(value):
            try updateText(column: "session_id", value: value, chatID: chatID, database: database)
        }
    }

    private func ensureChat(_ chatID: String, updatedAt: Int64, database: SQLiteHandle) throws {
        try withStatement(
            """
            INSERT INTO chats(chat_id, updated_at) VALUES (?, ?)
            ON CONFLICT(chat_id) DO UPDATE SET updated_at = MAX(chats.updated_at, excluded.updated_at)
            """,
            database: database
        ) {
            try bind(chatID, at: 1, statement: $0, database: database)
            sqlite3_bind_int64($0, 2, max(0, updatedAt))
            try stepDone($0, database: database)
        }
    }

    private func insertRow(
        _ row: AcpTranscriptRow,
        chatID: String,
        ordinal: Int64,
        database: SQLiteHandle
    ) throws {
        let data = try encoder.encode(row)
        try withStatement(
            "INSERT INTO transcript_rows(chat_id, ordinal, row_json) VALUES (?, ?, ?)",
            database: database
        ) {
            try bind(chatID, at: 1, statement: $0, database: database)
            sqlite3_bind_int64($0, 2, ordinal)
            try bind(data, at: 3, statement: $0, database: database)
            try stepDone($0, database: database)
        }
    }

    private func updateBlob(
        column: String,
        data: Data?,
        chatID: String,
        database: SQLiteHandle
    ) throws {
        try withStatement("UPDATE chats SET \(column) = ? WHERE chat_id = ?", database: database) {
            if let data { try bind(data, at: 1, statement: $0, database: database) }
            else { sqlite3_bind_null($0, 1) }
            try bind(chatID, at: 2, statement: $0, database: database)
            try stepDone($0, database: database)
        }
    }

    private func updateText(
        column: String,
        value: String?,
        chatID: String,
        database: SQLiteHandle
    ) throws {
        try withStatement("UPDATE chats SET \(column) = ? WHERE chat_id = ?", database: database) {
            if let value { try bind(value, at: 1, statement: $0, database: database) }
            else { sqlite3_bind_null($0, 1) }
            try bind(chatID, at: 2, statement: $0, database: database)
            try stepDone($0, database: database)
        }
    }

    private func pruneEmptyChats(_ database: SQLiteHandle) throws {
        try execute(
            """
            DELETE FROM chats
            WHERE usage_json IS NULL AND draft IS NULL AND attachments_json IS NULL AND session_id IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM transcript_rows WHERE transcript_rows.chat_id = chats.chat_id
              )
            """,
            database: database
        )
    }

    private func pruneOldChats(_ database: SQLiteHandle) throws {
        try execute(
            """
            DELETE FROM chats WHERE chat_id IN (
                SELECT chat_id FROM chats
                ORDER BY updated_at DESC, chat_id ASC
                LIMIT -1 OFFSET \(Self.maximumChatCount)
            )
            """,
            database: database
        )
    }

    // MARK: - Reads

    private func readMetadata(chatID: String, database: SQLiteHandle) throws -> StoredMetadata? {
        try withStatement(
            """
            SELECT updated_at, usage_json, draft, attachments_json, session_id
            FROM chats WHERE chat_id = ?
            """,
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw databaseError(database) }
            let usage: AcpPersistedUsage? = try decodedBlob(
                AcpPersistedUsage.self,
                column: 1,
                statement: statement
            )
            let attachments = try decodedBlob(
                [AcpAttachment].self,
                column: 3,
                statement: statement
            ) ?? []
            let draft = Self.columnString(statement, column: 2)
            let sessionID = Self.columnString(statement, column: 4)
            guard Self.attachmentsAreBounded(attachments) else {
                throw StoreError.database("stored attachments exceed the bounded contract")
            }
            guard draft?.lengthOfBytes(using: .utf8) ?? 0 <= Self.maximumDraftBytes,
                  sessionID?.lengthOfBytes(using: .utf8) ?? 0 <= 4_096 else {
                throw StoreError.database("stored transcript metadata exceeds the bounded contract")
            }
            return StoredMetadata(
                updatedAt: sqlite3_column_int64(statement, 0),
                usage: usage,
                draft: draft,
                attachments: attachments,
                sessionID: sessionID
            )
        }
    }

    private func readAllRows(chatID: String, database: SQLiteHandle) throws -> [AcpTranscriptRow] {
        try withStatement(
            "SELECT row_json FROM transcript_rows WHERE chat_id = ? ORDER BY ordinal ASC",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            var rows: [AcpTranscriptRow] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW,
                      let data = Self.columnData(statement, column: 0),
                      let row = try? decoder.decode(AcpTranscriptRow.self, from: data) else {
                    throw StoreError.database("stored transcript row could not be decoded")
                }
                rows.append(row)
            }
        }
    }

    private func readTailPage(chatID: String, limit: Int, database: SQLiteHandle) throws -> Page {
        let total = try rowCount(chatID: chatID, beforeOrdinal: nil, database: database)
        guard total > 0 else { return .empty }
        return try readDescendingPage(
            chatID: chatID,
            predicate: "",
            boundary: nil,
            limit: limit,
            total: total,
            database: database
        )
    }

    private func readPage(
        chatID: String,
        beforeOrdinal: Int64,
        limit: Int,
        database: SQLiteHandle
    ) throws -> Page {
        let total = try rowCount(chatID: chatID, beforeOrdinal: nil, database: database)
        let available = try rowCount(
            chatID: chatID,
            beforeOrdinal: beforeOrdinal,
            database: database
        )
        guard available > 0 else {
            return Page(
                rows: [],
                startOrdinal: beforeOrdinal,
                endOrdinalExclusive: beforeOrdinal,
                earlierRowCount: 0,
                totalRowCount: total
            )
        }
        return try readDescendingPage(
            chatID: chatID,
            predicate: "AND ordinal < ?",
            boundary: beforeOrdinal,
            limit: min(limit, available),
            total: total,
            database: database
        )
    }

    private func readDescendingPage(
        chatID: String,
        predicate: String,
        boundary: Int64?,
        limit: Int,
        total: Int,
        database: SQLiteHandle
    ) throws -> Page {
        try withStatement(
            """
            SELECT ordinal, row_json FROM transcript_rows
            WHERE chat_id = ? \(predicate)
            ORDER BY ordinal DESC LIMIT ?
            """,
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            var limitIndex: Int32 = 2
            if let boundary {
                sqlite3_bind_int64(statement, 2, boundary)
                limitIndex = 3
            }
            sqlite3_bind_int(statement, limitIndex, Int32(limit))
            var decoded: [(Int64, AcpTranscriptRow)] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      let data = Self.columnData(statement, column: 1),
                      let row = try? decoder.decode(AcpTranscriptRow.self, from: data) else {
                    throw StoreError.database("stored transcript row could not be decoded")
                }
                decoded.append((sqlite3_column_int64(statement, 0), row))
            }
            decoded.reverse()
            guard let first = decoded.first, let last = decoded.last else { return .empty }
            let earlier = try rowCount(
                chatID: chatID,
                beforeOrdinal: first.0,
                database: database
            )
            return Page(
                rows: decoded.map(\.1),
                startOrdinal: first.0,
                endOrdinalExclusive: last.0 + 1,
                earlierRowCount: earlier,
                totalRowCount: total
            )
        }
    }

    private func rowCount(
        chatID: String,
        beforeOrdinal: Int64?,
        database: SQLiteHandle
    ) throws -> Int {
        let predicate = beforeOrdinal == nil ? "" : " AND ordinal < ?"
        return try withStatement(
            "SELECT COUNT(*) FROM transcript_rows WHERE chat_id = ?\(predicate)",
            database: database
        ) { statement in
            try bind(chatID, at: 1, statement: statement, database: database)
            if let beforeOrdinal { sqlite3_bind_int64(statement, 2, beforeOrdinal) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(database) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func chatCount(_ database: SQLiteHandle) throws -> Int {
        try withStatement("SELECT COUNT(*) FROM chats", database: database) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(database) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - SQLite helpers

    private func transaction(_ database: SQLiteHandle, body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            try body()
            try execute("COMMIT", database: database)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    private func execute(_ sql: String, database: SQLiteHandle) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database.pointer, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? Self.errorMessage(database.pointer)
            sqlite3_free(message)
            throw StoreError.database(detail)
        }
    }

    private func withStatement<Result>(
        _ sql: String,
        database: SQLiteHandle,
        body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database.pointer, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError(database) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer, database: SQLiteHandle) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }

    /// True when the statement yields a row; DONE means no match.
    private func stepRow(_ statement: OpaquePointer, database: SQLiteHandle) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError(database)
        }
    }

    private func bind(
        _ value: Int64,
        at index: Int32,
        statement: OpaquePointer,
        database: SQLiteHandle
    ) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func bind(
        _ value: String,
        at index: Int32,
        statement: OpaquePointer,
        database: SQLiteHandle
    ) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func bind(
        _ data: Data,
        at index: Int32,
        statement: OpaquePointer,
        database: SQLiteHandle
    ) throws {
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
        guard result == SQLITE_OK else { throw databaseError(database) }
    }

    private func decodedBlob<Value: Decodable>(
        _ type: Value.Type,
        column: Int32,
        statement: OpaquePointer
    ) throws -> Value? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        guard let data = Self.columnData(statement, column: column) else {
            throw StoreError.database("stored metadata blob is missing")
        }
        do { return try decoder.decode(type, from: data) }
        catch { throw StoreError.database("stored metadata blob could not be decoded") }
    }

    private func metadataValue(for key: String, database: SQLiteHandle) throws -> String? {
        try withStatement("SELECT value FROM store_meta WHERE key = ?", database: database) { statement in
            try bind(key, at: 1, statement: statement, database: database)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw databaseError(database) }
            return Self.columnString(statement, column: 0)
        }
    }

    private func setMetadataValue(_ value: String, for key: String, database: SQLiteHandle) throws {
        try withStatement(
            "INSERT OR REPLACE INTO store_meta(key, value) VALUES (?, ?)",
            database: database
        ) {
            try bind(key, at: 1, statement: $0, database: database)
            try bind(value, at: 2, statement: $0, database: database)
            try stepDone($0, database: database)
        }
    }

    private func databaseError(_ database: SQLiteHandle) -> StoreError {
        .database(Self.errorMessage(database.pointer))
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
    }

    private static func columnData(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private static func columnString(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func boundedPageLimit(_ requested: Int) -> Int {
        min(max(1, requested), maximumPageSize)
    }

    private static func validChatID(_ chatID: String) -> Bool {
        !chatID.isEmpty && chatID.lengthOfBytes(using: .utf8) <= 1_024
    }

    private static func timestamp(_ supplied: Int64?) -> Int64 {
        max(0, supplied ?? Int64(Date().timeIntervalSince1970 * 1_000))
    }

    private static func attachmentsAreBounded(_ attachments: [AcpAttachment]) -> Bool {
        guard attachments.count <= maximumAttachmentCount else { return false }
        var total = 0
        for attachment in attachments {
            let bytes: Int
            switch attachment {
            case let .image(data, _, _): bytes = data.count
            case let .textFile(path, contents, name):
                bytes = path.lengthOfBytes(using: .utf8)
                    + contents.lengthOfBytes(using: .utf8)
                    + name.lengthOfBytes(using: .utf8)
            }
            guard bytes <= maximumAttachmentBytes - total else { return false }
            total += bytes
        }
        return true
    }

    private static func validateDatabaseLeaf(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw StoreError.database("transcript database path could not be inspected")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw StoreError.database("transcript database path is not a regular file")
        }
    }

    private static func validateLegacyLeaf(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw StoreError.corruptLegacyArchive
        }
    }
}
