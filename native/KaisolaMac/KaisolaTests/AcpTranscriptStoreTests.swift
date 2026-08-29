import Foundation
import SQLite3
import XCTest
@testable import Kaisola

/// Reaches the transcript database directly so a test can damage stored bytes
/// the way a bad page or a hand-edited file would, and can count the rows that
/// survived a write the store was supposed to refuse.
enum TranscriptDatabaseProbe {
    enum ProbeError: Error, Equatable {
        case open(String)
        case sql(String)
    }

    static func execute(_ sql: String, at databaseURL: URL) throws {
        let handle = try open(databaseURL)
        defer { sqlite3_close_v2(handle) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(message)
            throw ProbeError.sql(detail)
        }
    }

    static func rowCount(chatID: String, at databaseURL: URL) throws -> Int {
        let handle = try open(databaseURL)
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM transcript_rows WHERE chat_id = ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProbeError.sql(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, chatID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ProbeError.sql(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func open(_ databaseURL: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            if let handle { sqlite3_close_v2(handle) }
            throw ProbeError.open(detail)
        }
        return handle
    }
}

final class AcpTranscriptStoreTests: XCTestCase {
    private struct LegacyPayload: Encodable {
        let entries: [String: AcpTranscriptStore.Entry]
    }

    private enum ReadLockError: Error {
        case open
        case read
    }

    /// A second connection parked inside a read transaction. SQLite hands out
    /// the shared lock this holds only until a writer needs the exclusive one,
    /// so the store's tombstone COMMIT is rejected once its busy timeout ends.
    private final class SQLiteReadLock {
        private var handle: OpaquePointer?

        init(path: String) throws {
            var connection: OpaquePointer?
            guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let connection else {
                if let connection { sqlite3_close_v2(connection) }
                throw ReadLockError.open
            }
            handle = connection
            guard sqlite3_exec(connection, "BEGIN", nil, nil, nil) == SQLITE_OK else {
                throw ReadLockError.read
            }
            // The shared lock is taken by the read itself, not by BEGIN.
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "SELECT COUNT(*) FROM chats", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw ReadLockError.read }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw ReadLockError.read }
        }

        func release() {
            guard let handle else { return }
            sqlite3_exec(handle, "COMMIT", nil, nil, nil)
            sqlite3_close_v2(handle)
            self.handle = nil
        }

        deinit { release() }
    }

    private func temporaryStore() -> (AcpTranscriptStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-\(UUID().uuidString)", isDirectory: true)
        return (AcpTranscriptStore(fileURL: directory.appendingPathComponent("transcripts.json")), directory)
    }

    /// A second connection to the same file, used to hold locks and to damage
    /// the schema the way another process or a rolled-back build would.
    private func openSideConnection(to url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        return try XCTUnwrap(handle)
    }

    private func sqliteCount(_ sql: String, databaseURL: URL) throws -> Int {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw NSError(
                domain: "AcpTranscriptStoreTests.SQLite",
                code: Int(openResult),
                userInfo: [NSLocalizedDescriptionKey: "Could not open transcript database"]
            )
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(
                domain: "AcpTranscriptStoreTests.SQLite",
                code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(
                domain: "AcpTranscriptStoreTests.SQLite",
                code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
            )
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func testLiveStoreUsesAnXCTestIsolatedRoot() {
        XCTAssertNotEqual(
            AcpTranscriptStore.live.databaseURL.standardizedFileURL,
            NativePreviewPaths.agentChatTranscriptDatabase.standardizedFileURL
        )
        XCTAssertTrue(
            AcpTranscriptStore.live.databaseURL.path.contains("kaisola-xctest-transcripts-")
        )
    }

    func testTranscriptPersistsAcrossStoreInstances() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows: [AcpTranscriptRow] = [
            .user(id: "1", text: "hello", failed: false),
            .message(id: "1", text: "hi"),
        ]
        await store.scheduleSave(rows, for: "chat-one", now: 1)
        await store.flush()

        let reopened = AcpTranscriptStore(fileURL: directory.appendingPathComponent("transcripts.json"))
        let restoredRows = await reopened.rows(for: "chat-one")
        XCTAssertEqual(restoredRows, rows)
    }

    func testPerChatRowQuotaPreservesPinnedEvidenceAndNewestRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-quota-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AcpTranscriptStore(
            databaseURL: directory.appendingPathComponent("transcripts.sqlite3"),
            schedulesAutomaticFlush: false,
            retentionPolicy: .init(
                maximumRowCount: 5,
                maximumBytes: 1_048_576,
                recentRowCount: 2
            )
        )
        let rows: [AcpTranscriptRow] = [
            .message(id: "discard-message", text: "old narration"),
            .user(id: "pinned-user", text: "keep my prompt", failed: false),
            .thought(id: "discard-thought", text: "old thought"),
            .tool(AcpToolCall(
                id: "pinned-tool",
                title: "Read source",
                kind: "read",
                status: .completed
            )),
            .plan(id: "middle", entries: []),
            .message(id: "recent-one", text: "recent"),
            .message(id: "recent-two", text: "newest"),
        ]

        await store.scheduleSave(rows, for: "chat-row-quota", now: 1)
        await store.flush()

        let outcome = await store.restoration(for: "chat-row-quota", tailLimit: 2)
        let restoration = try XCTUnwrap(outcome.restoration)
        XCTAssertEqual(restoration.page.rows.map(\.id), ["msg-recent-one", "msg-recent-two"])
        let earlierPage = await store.page(
            for: "chat-row-quota",
            beforeOrdinal: restoration.page.startOrdinal,
            limit: 10
        )
        let earlier = try XCTUnwrap(earlierPage)
        XCTAssertEqual(earlier.endOrdinalExclusive, restoration.page.startOrdinal)
        XCTAssertEqual(earlier.rows.map(\.id) + restoration.page.rows.map(\.id), [
            "user-pinned-user",
            "tool-pinned-tool",
            "plan-middle",
            "msg-recent-one",
            "msg-recent-two",
        ])
        XCTAssertEqual(restoration.retentionStatus.truncatedRowCount, 2)
        XCTAssertGreaterThan(restoration.retentionStatus.truncatedByteCount, 0)
        XCTAssertTrue(restoration.retentionStatus.isTruncated)
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COUNT(*) FROM transcript_rows WHERE chat_id = 'chat-row-quota'",
                databaseURL: store.databaseURL
            ),
            5
        )
    }

    func testPerChatByteQuotaReportsExactTruncationAndSurvivesTailRewrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-byte-quota-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pinned = AcpTranscriptRow.user(
            id: "pinned",
            text: String(repeating: "p", count: 48),
            failed: false
        )
        let discarded = AcpTranscriptRow.message(
            id: "discarded",
            text: String(repeating: "d", count: 96)
        )
        let newest = AcpTranscriptRow.message(
            id: "newest",
            text: String(repeating: "n", count: 48)
        )
        let encoder = JSONEncoder()
        let retainedBytes = try encoder.encode(pinned).count + encoder.encode(newest).count
        let discardedBytes = try encoder.encode(discarded).count
        let store = AcpTranscriptStore(
            databaseURL: directory.appendingPathComponent("transcripts.sqlite3"),
            schedulesAutomaticFlush: false,
            retentionPolicy: .init(
                maximumRowCount: 10,
                maximumBytes: retainedBytes,
                recentRowCount: 1
            )
        )

        await store.scheduleSave([pinned, discarded, newest], for: "chat-byte-quota", now: 1)
        await store.flush()
        let firstOutcome = await store.restoration(for: "chat-byte-quota", tailLimit: 10)
        let first = try XCTUnwrap(firstOutcome.restoration)
        XCTAssertEqual(first.page.rows, [pinned, newest])
        XCTAssertEqual(first.retentionStatus.truncatedRowCount, 1)
        XCTAssertEqual(first.retentionStatus.truncatedByteCount, Int64(discardedBytes))
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COALESCE(SUM(length(row_json)), 0) FROM transcript_rows WHERE chat_id = 'chat-byte-quota'",
                databaseURL: store.databaseURL
            ),
            retainedBytes
        )

        let updatedNewest = AcpTranscriptRow.message(id: "newest", text: "updated")
        await store.scheduleSave(
            [updatedNewest],
            for: "chat-byte-quota",
            startOrdinal: 2,
            now: 2
        )
        await store.flush()
        let rewrittenOutcome = await store.restoration(for: "chat-byte-quota", tailLimit: 10)
        let rewritten = try XCTUnwrap(rewrittenOutcome.restoration)
        XCTAssertEqual(rewritten.page.rows, [pinned, updatedNewest])
        XCTAssertEqual(rewritten.retentionStatus.truncatedRowCount, 1)
        XCTAssertEqual(rewritten.retentionStatus.truncatedByteCount, Int64(discardedBytes))

        let reopened = AcpTranscriptStore(
            databaseURL: store.databaseURL,
            schedulesAutomaticFlush: false,
            retentionPolicy: .init(
                maximumRowCount: 10,
                maximumBytes: retainedBytes,
                recentRowCount: 1
            )
        )
        let reopenedOutcome = await reopened.restoration(for: "chat-byte-quota", tailLimit: 10)
        XCTAssertEqual(
            try XCTUnwrap(reopenedOutcome.restoration).retentionStatus,
            rewritten.retentionStatus
        )
    }

    func testSingleOversizedRowIsNeverInsertedAndItsTruncationStatusPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-single-quota-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = AcpTranscriptRow.message(
            id: "oversized",
            text: String(repeating: "x", count: 2_048)
        )
        let encodedBytes = try JSONEncoder().encode(row).count
        let store = AcpTranscriptStore(
            databaseURL: directory.appendingPathComponent("transcripts.sqlite3"),
            schedulesAutomaticFlush: false,
            retentionPolicy: .init(
                maximumRowCount: 10,
                maximumBytes: encodedBytes - 1,
                recentRowCount: 10
            )
        )

        await store.scheduleSave([row], for: "chat-oversized", now: 1)
        await store.flush()

        let outcome = await store.restoration(for: "chat-oversized", tailLimit: 10)
        let restoration = try XCTUnwrap(outcome.restoration)
        XCTAssertTrue(restoration.page.rows.isEmpty)
        XCTAssertEqual(restoration.retentionStatus.truncatedRowCount, 1)
        XCTAssertEqual(restoration.retentionStatus.truncatedByteCount, Int64(encodedBytes))
        XCTAssertEqual(
            try TranscriptDatabaseProbe.rowCount(chatID: "chat-oversized", at: store.databaseURL),
            0
        )
    }

    func testExistingSchemaBackfillsPinnedEvidenceBeforeApplyingQuota() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-quota-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        XCTAssertTrue(FileManager.default.createFile(atPath: databaseURL.path, contents: nil))
        let row = AcpTranscriptRow.user(id: "legacy-user", text: "keep", failed: false)
        let rowHex = try JSONEncoder().encode(row).map { String(format: "%02X", $0) }.joined()
        try TranscriptDatabaseProbe.execute(
            """
            CREATE TABLE store_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;
            CREATE TABLE chats (
                chat_id TEXT PRIMARY KEY NOT NULL,
                updated_at INTEGER NOT NULL,
                usage_json BLOB,
                draft TEXT,
                attachments_json BLOB,
                session_id TEXT
            ) WITHOUT ROWID;
            CREATE TABLE transcript_rows (
                chat_id TEXT NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
                row_json BLOB NOT NULL,
                PRIMARY KEY (chat_id, ordinal)
            ) WITHOUT ROWID;
            INSERT INTO chats(chat_id, updated_at) VALUES ('legacy-chat', 1);
            INSERT INTO transcript_rows(chat_id, ordinal, row_json)
            VALUES ('legacy-chat', 0, X'\(rowHex)');
            """,
            at: databaseURL
        )

        let store = AcpTranscriptStore(
            databaseURL: databaseURL,
            schedulesAutomaticFlush: false,
            retentionPolicy: .init(
                maximumRowCount: 1,
                maximumBytes: 1_048_576,
                recentRowCount: 0
            )
        )
        let outcome = await store.restoration(for: "legacy-chat", tailLimit: 10)

        XCTAssertEqual(try XCTUnwrap(outcome.restoration).page.rows, [row])
        XCTAssertEqual(
            try sqliteCount(
                "SELECT quota_pinned FROM transcript_rows WHERE chat_id = 'legacy-chat'",
                databaseURL: databaseURL
            ),
            1
        )
    }

    func testTranscriptKeepsTheFirstMessage() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = (0..<1_200).map {
            AcpTranscriptRow.message(id: "\($0)", text: "row \($0)")
        }
        await store.scheduleSave(rows, for: "chat-complete", now: 1)
        let restored = await store.rows(for: "chat-complete")
        XCTAssertEqual(restored.count, rows.count)
        XCTAssertEqual(restored.first?.id, rows.first?.id)
        XCTAssertEqual(restored.last?.id, rows.last?.id)
        XCTAssertEqual(restored.first?.id, "msg-0")
    }

    func testRemoveClearsDurableTranscriptAndReportsSuccessAcrossRelaunch() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.scheduleSave([.message(id: "1", text: "saved")], for: "chat-remove", now: 1)
        await store.flush()
        let result = await store.remove(chatID: "chat-remove")
        XCTAssertEqual(result, .removed)

        let reopened = AcpTranscriptStore(
            fileURL: directory.appendingPathComponent("transcripts.json")
        )
        let restoredRows = await reopened.rows(for: "chat-remove")
        XCTAssertTrue(restoredRows.isEmpty)
    }

    /// A committed delete consumes the coalesced write too: the queued rows
    /// must not come back when the next flush runs.
    func testCommittedRemoveDropsTheQueuedWrite() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.scheduleSave([.message(id: "1", text: "queued")], for: "chat-committed", now: 1)

        let outcome = await store.remove(chatID: "chat-committed")
        XCTAssertEqual(outcome, .removed)
        await store.flush()

        let reopened = AcpTranscriptStore(
            fileURL: directory.appendingPathComponent("transcripts.json")
        )
        let restoredRows = await reopened.rows(for: "chat-committed")
        XCTAssertTrue(restoredRows.isEmpty)
    }

    /// Preserve the canonical result helpers while using the deterministic
    /// failure seam only after this writer owns a valid generation fence.
    func testFailedRemoveReportsFailureAndKeepsTheQueuedWrite() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-transcript-canonical-remove-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let store = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "canonical-remove-failure",
            schedulesAutomaticFlush: false,
            injectedRemovalFailure: .open
        )
        let durableRows: [AcpTranscriptRow] = [.message(id: "1", text: "durable")]
        let newestRows = durableRows + [.message(id: "2", text: "newest tail")]
        await store.scheduleSave(durableRows, for: "chat-blocked", now: 1)
        await store.flush()
        await store.scheduleSave(newestRows, for: "chat-blocked", now: 2)

        let outcome = await store.remove(chatID: "chat-blocked")
        XCTAssertFalse(outcome.isRemoved, "a delete that never committed must not report success")
        XCTAssertNotNil(outcome.failureMessage)

        await store.flush()
        let reopened = AcpTranscriptStore(databaseURL: databaseURL)
        let restoredRows = await reopened.rows(for: "chat-blocked")
        XCTAssertEqual(restoredRows, newestRows)
    }

    func testInvalidDeletionIdentifiersFailClosed() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = AcpTranscriptStore.StoreError.database(
            "invalid transcript chat identifier"
        )

        let removal = await store.remove(chatID: "")
        let tombstone = await store.tombstone(chatID: "")
        let state = await store.tombstoneState(chatID: "")
        XCTAssertEqual(removal, .failed(expected))
        XCTAssertEqual(tombstone, .failed(expected))
        XCTAssertEqual(state, .unknown)
    }

    func testRemoveFailuresRestoreExactNewestPendingTailForRetry() async throws {
        for failure in [
            AcpTranscriptStore.RemovalFailurePoint.open,
            .delete,
            .commit,
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "kaisola-transcript-remove-failure-\(failure)-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
            let store = AcpTranscriptStore(
                databaseURL: databaseURL,
                writerID: "writer-\(failure)",
                schedulesAutomaticFlush: false,
                injectedRemovalFailure: failure
            )
            let chatID = "remove-failure-\(failure)"
            let durableRows: [AcpTranscriptRow] = [
                .message(id: "1", text: "previously durable"),
            ]
            let newestRows: [AcpTranscriptRow] = [
                .message(id: "1", text: "previously durable"),
                .message(id: "2", text: "newest buffered tail \(failure)"),
            ]

            await store.scheduleSave(durableRows, for: chatID, now: 1)
            await store.flush()
            await store.scheduleSave(newestRows, for: chatID, now: 2)
            await store.scheduleDraft("newest draft \(failure)", for: chatID, now: 3)

            let result = await store.remove(chatID: chatID)
            let label: String
            switch failure {
            case .open: label = "open"
            case .delete: label = "DELETE"
            case .commit: label = "commit"
            }
            XCTAssertEqual(
                result,
                .failed(.database("injected transcript removal \(label) failure"))
            )

            // The one-shot injection is consumed. Flushing now must persist
            // the exact rows and metadata that remove temporarily extracted.
            await store.flush()
            let reopened = AcpTranscriptStore(databaseURL: databaseURL)
            let restored = await reopened.entry(for: chatID)
            XCTAssertEqual(restored?.rows, newestRows, "failed at \(failure)")
            XCTAssertEqual(restored?.draft, "newest draft \(failure)", "failed at \(failure)")
        }
    }

    func testTombstoneFailuresPreserveExactPendingContentAndRetryAcrossRelaunch() async throws {
        for failure in [
            AcpTranscriptStore.TombstoneFailurePoint.open,
            .commit,
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "kaisola-transcript-tombstone-failure-\(failure)-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
            let store = AcpTranscriptStore(
                databaseURL: databaseURL,
                writerID: "writer-\(failure)",
                schedulesAutomaticFlush: false,
                injectedTombstoneFailure: failure
            )
            let chatID = "tombstone-failure-\(failure)"
            let durableRows: [AcpTranscriptRow] = [
                .message(id: "1", text: "previously durable"),
            ]
            let newestRows: [AcpTranscriptRow] = [
                .message(id: "1", text: "previously durable"),
                .message(id: "2", text: "newest buffered tail \(failure)"),
            ]

            await store.scheduleSave(durableRows, for: chatID, now: 1)
            await store.flush()
            await store.scheduleSave(newestRows, for: chatID, now: 2)
            await store.scheduleDraft("newest draft \(failure)", for: chatID, now: 3)

            let result = await store.tombstone(chatID: chatID)
            let label = failure == .open ? "open" : "commit"
            XCTAssertEqual(
                result,
                .failed(.database("injected transcript tombstone \(label) failure"))
            )
            let stateAfterFailure = await store.tombstoneState(chatID: chatID)
            XCTAssertEqual(stateAfterFailure, .absent)

            // The failed intent did not consume the pending snapshot. It can
            // still land exactly, and a later one-shot retry can then delete it.
            await store.flush()
            let preservedRelaunch = AcpTranscriptStore(databaseURL: databaseURL)
            let preserved = await preservedRelaunch.entry(for: chatID)
            XCTAssertEqual(preserved?.rows, newestRows, "failed at \(failure)")
            XCTAssertEqual(preserved?.draft, "newest draft \(failure)", "failed at \(failure)")

            let retry = await store.tombstone(chatID: chatID)
            let snapshot = try XCTUnwrap(retry.snapshot)
            let removal = await store.remove(
                chatID: chatID,
                verifiedDescriptorPruning: snapshot
            )
            XCTAssertEqual(removal, .removed)
            let deletedRelaunch = AcpTranscriptStore(databaseURL: databaseURL)
            let deleted = await deletedRelaunch.entry(for: chatID)
            XCTAssertNil(deleted)
        }
    }

    func testLaunchVacuumResumesPhysicalDeletionAfterCrashFollowingTombstone() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-crash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("transcripts.json")
        let chatID = "crash-after-tombstone"
        let secretMarker = "KAISOLA_TRANSCRIPT_SECRET_499_E7C6B3A1"
        let secretMarkerData = Data(secretMarker.utf8)
        let databaseURL: URL
        var crashReceipt: AcpTranscriptStore.TombstoneSnapshot?

        do {
            let store = AcpTranscriptStore(fileURL: legacyURL)
            databaseURL = store.databaseURL
            await store.scheduleSave(
                [
                    .user(id: "1", text: "sensitive prompt " + secretMarker, failed: false),
                    .message(id: "2", text: "sensitive response"),
                ],
                for: chatID,
                now: 1
            )
            await store.scheduleDraft("sensitive draft " + secretMarker, for: chatID, now: 2)
            await store.flush()
            XCTAssertNotNil(
                try Data(contentsOf: databaseURL).range(of: secretMarkerData),
                "The forensic fixture must prove the raw marker reached SQLite before deletion"
            )

            // Crash injection point: the durable intent landed, but the
            // normal queued remove(chatID:) phase never ran.
            let tombstoneResult = await store.tombstone(chatID: chatID)
            crashReceipt = try XCTUnwrap(tombstoneResult.snapshot)
            XCTAssertEqual(
                try sqliteCount("SELECT COUNT(*) FROM transcript_rows", databaseURL: databaseURL),
                2
            )
            XCTAssertEqual(
                try sqliteCount("SELECT COUNT(*) FROM deleted_chats", databaseURL: databaseURL),
                1
            )
        }

        let relaunched = AcpTranscriptStore(fileURL: legacyURL)
        await relaunched.vacuumTombstones(
            descriptorPruningVerified: [try XCTUnwrap(crashReceipt)]
        )

        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM transcript_rows", databaseURL: databaseURL),
            0,
            "Launch recovery must physically remove retained transcript rows"
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM chats", databaseURL: databaseURL),
            0,
            "Chat metadata and sensitive draft bytes must be removed with the transcript"
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM deleted_chats", databaseURL: databaseURL),
            1,
            "Physical deletion alone must retain the exact receipt until external plaintext cleanup"
        )
        XCTAssertNil(
            try Data(contentsOf: databaseURL).range(of: secretMarkerData),
            "Launch recovery must overwrite deleted transcript and draft content in SQLite pages"
        )
        let restored = await relaunched.entry(for: chatID)
        XCTAssertNil(restored)
        let launchCleanup = await relaunched.completeExternalCleanup(
            try XCTUnwrap(crashReceipt)
        )
        XCTAssertEqual(launchCleanup, .removed)
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM deleted_chats", databaseURL: databaseURL),
            0,
            "Only verified external cleanup may release the final receipt fence"
        )
    }

    func testRetainedTombstoneSurvivesOtherWriterReclamationUntilDescriptorPruningIsVerified() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kaisola-transcript-descriptor-fence-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let deletingWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "deleting-window",
            schedulesAutomaticFlush: false
        )
        let otherWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "other-window",
            schedulesAutomaticFlush: false
        )
        let deletedChatID = "descriptor-prune-failed"

        await deletingWindow.scheduleSave(
            [.message(id: "1", text: "must remain deleted")],
            for: deletedChatID,
            now: 1
        )
        await deletingWindow.flush()
        let tombstone = await deletingWindow.tombstone(chatID: deletedChatID)
        let removal = await deletingWindow.remove(chatID: deletedChatID)
        XCTAssertNotNil(tombstone.snapshot)
        XCTAssertEqual(removal, .removed)

        // A different window's ordinary write and vacuum both run the global
        // reclamation query. Neither is allowed to erase a fence whose stale
        // workspace descriptor has not yet been pruned.
        await otherWindow.scheduleSave(
            [.message(id: "1", text: "unrelated")],
            for: "unrelated-chat",
            now: 2
        )
        await otherWindow.flush()
        await otherWindow.vacuumTombstones()
        let retained = await otherWindow.tombstoneState(chatID: deletedChatID)
        XCTAssertEqual(retained, .present)

        let verified = await otherWindow.tombstoneSnapshot(chatID: deletedChatID)
        guard case let .present(snapshot) = verified else {
            return XCTFail("expected retained tombstone snapshot, got \(verified)")
        }
        await otherWindow.vacuumTombstones(descriptorPruningVerified: [snapshot])
        let externallyBlocked = await otherWindow.tombstoneState(chatID: deletedChatID)
        XCTAssertEqual(externallyBlocked, .present)
        let externalCleanup = await otherWindow.completeExternalCleanup(snapshot)
        XCTAssertEqual(externalCleanup, .removed)
        let reclaimed = await otherWindow.tombstoneState(chatID: deletedChatID)
        XCTAssertEqual(reclaimed, .absent)
        let restored = await otherWindow.entry(for: deletedChatID)
        XCTAssertNil(restored)
    }

    func testVerifiedVacuumCannotReclaimTombstoneCreatedAfterTheDescriptorScan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kaisola-transcript-vacuum-snapshot-race-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let scanningWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "scanning-window",
            schedulesAutomaticFlush: false
        )
        let deletingWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "deleting-window",
            schedulesAutomaticFlush: false
        )
        let scannedChatID = "descriptor-was-pruned"
        let racedChatID = "tombstoned-after-scan"

        for chatID in [scannedChatID, racedChatID] {
            await scanningWindow.scheduleSave(
                [.message(id: "row-\(chatID)", text: chatID)],
                for: chatID,
                now: 1
            )
        }
        await scanningWindow.flush()
        let scannedTombstone = await deletingWindow.tombstone(chatID: scannedChatID)
        XCTAssertNotNil(scannedTombstone.snapshot)
        let verified = await scanningWindow.tombstoneSnapshot(chatID: scannedChatID)
        guard case let .present(verifiedTombstone) = verified else {
            return XCTFail("expected a tombstone snapshot, got \(verified)")
        }

        // Deterministic TOCTOU: this deletion commits only after the scanning
        // window has captured the exact tombstone it is authorized to reclaim.
        let racedTombstone = await deletingWindow.tombstone(chatID: racedChatID)
        XCTAssertNotNil(racedTombstone.snapshot)

        await scanningWindow.vacuumTombstones(
            descriptorPruningVerified: [verifiedTombstone]
        )
        let externalCleanup = await scanningWindow.completeExternalCleanup(verifiedTombstone)
        XCTAssertEqual(externalCleanup, .removed)

        let scannedState = await scanningWindow.tombstoneState(chatID: scannedChatID)
        let racedState = await scanningWindow.tombstoneState(chatID: racedChatID)
        XCTAssertEqual(scannedState, .absent)
        XCTAssertEqual(
            racedState,
            .present,
            "a tombstone outside the verified snapshot must retain its descriptor fence"
        )
    }

    func testG1RemovalReceiptCannotAuthorizeRetombstonedG2() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chatID = "retombstoned-remove-generation"
        await store.scheduleSave(
            [.message(id: "1", text: "sensitive durable row")],
            for: chatID,
            now: 1
        )
        await store.flush()

        let g1Result = await store.tombstone(chatID: chatID)
        let g1 = try XCTUnwrap(g1Result.snapshot)
        let g2Result = await store.tombstone(chatID: chatID)
        let g2 = try XCTUnwrap(g2Result.snapshot)
        XCTAssertGreaterThan(g2.generation, g1.generation)

        let staleRemoval = await store.remove(
            chatID: chatID,
            verifiedDescriptorPruning: g1
        )
        XCTAssertEqual(
            staleRemoval,
            .failed(.database("transcript deletion receipt is stale or no longer present"))
        )
        let retainedG2 = await store.tombstoneSnapshot(chatID: chatID)
        XCTAssertEqual(retainedG2, .present(g2))
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM chats", databaseURL: store.databaseURL),
            1,
            "a stale receipt must roll back before transcript deletion"
        )
        XCTAssertEqual(
            try sqliteCount(
                "SELECT descriptor_reclaim_blocked FROM deleted_chats WHERE chat_id = '\(chatID)'",
                databaseURL: store.databaseURL
            ),
            1
        )

        let currentRemoval = await store.remove(
            chatID: chatID,
            verifiedDescriptorPruning: g2
        )
        XCTAssertEqual(currentRemoval, .removed)
        let externalCleanup = await store.completeExternalCleanup(g2)
        XCTAssertEqual(externalCleanup, .removed)
        let removedState = await store.tombstoneState(chatID: chatID)
        XCTAssertEqual(removedState, .absent)
    }

    func testG1VacuumReceiptCannotAuthorizeRetombstonedG2() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chatID = "retombstoned-vacuum-generation"
        await store.scheduleSave(
            [.message(id: "1", text: "sensitive durable row")],
            for: chatID,
            now: 1
        )
        await store.flush()

        let g1Result = await store.tombstone(chatID: chatID)
        let g1 = try XCTUnwrap(g1Result.snapshot)
        let g2Result = await store.tombstone(chatID: chatID)
        let g2 = try XCTUnwrap(g2Result.snapshot)
        await store.vacuumTombstones(descriptorPruningVerified: [g1])

        let retainedG2 = await store.tombstoneSnapshot(chatID: chatID)
        XCTAssertEqual(retainedG2, .present(g2))
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM chats", databaseURL: store.databaseURL),
            1
        )
        XCTAssertEqual(
            try sqliteCount(
                "SELECT descriptor_reclaim_blocked FROM deleted_chats WHERE chat_id = '\(chatID)'",
                databaseURL: store.databaseURL
            ),
            1
        )

        await store.vacuumTombstones(descriptorPruningVerified: [g2])
        let externalCleanup = await store.completeExternalCleanup(g2)
        XCTAssertEqual(externalCleanup, .removed)
        let removedState = await store.tombstoneState(chatID: chatID)
        XCTAssertEqual(removedState, .absent)
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM chats", databaseURL: store.databaseURL),
            0
        )
    }

    func testTombstoneVacuumWaitsForBufferedWriterAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-writer-fence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let writerA = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "writer-a",
            schedulesAutomaticFlush: false
        )
        let writerB = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "writer-b",
            schedulesAutomaticFlush: false
        )
        let chatID = "buffered-writer-delete"
        let staleMarker = "KAISOLA_BUFFERED_WRITER_SECRET_497_9B18C4"

        await writerA.scheduleSave([.message(id: "1", text: "persisted")], for: chatID, now: 1)
        await writerA.flush()
        await writerB.scheduleSave(
            [
                .message(id: "1", text: "persisted"),
                .message(id: "2", text: staleMarker),
            ],
            for: chatID,
            now: 2
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM transcript_writers", databaseURL: databaseURL),
            1,
            "Only the store holding a buffered snapshot should retain a writer lease"
        )

        let tombstoneResult = await writerA.tombstone(chatID: chatID)
        let tombstone = try XCTUnwrap(tombstoneResult.snapshot)
        await writerA.remove(
            chatID: chatID,
            verifiedDescriptorPruning: tombstone
        )
        let externalCleanup = await writerA.completeExternalCleanup(tombstone)
        XCTAssertEqual(externalCleanup, .removed)
        await writerA.vacuumTombstones()
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM chats", databaseURL: databaseURL),
            0
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM deleted_chats", databaseURL: databaseURL),
            1,
            "Vacuum must retain the marker while writer B can still flush its old generation"
        )

        await writerB.flush()
        let restored = await writerB.entry(for: chatID)
        XCTAssertNil(restored, "Writer B's delayed flush must not recreate the deleted chat")
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM transcript_rows", databaseURL: databaseURL),
            0
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM deleted_chats", databaseURL: databaseURL),
            0,
            "The acknowledged writer generation makes the tombstone reclaimable"
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM transcript_writers", databaseURL: databaseURL),
            0,
            "A writer with no buffered snapshots must retire its durable lease"
        )
    }

    func testExpiredWriterLeaseBoundsTombstonesWithoutAllowingStaleRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-expired-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let writerA = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "writer-a",
            schedulesAutomaticFlush: false
        )
        let writerB = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "writer-b",
            schedulesAutomaticFlush: false
        )
        let chatID = "expired-buffered-writer"

        await writerA.scheduleSave([.message(id: "1", text: "persisted")], for: chatID, now: 1)
        await writerA.flush()
        await writerB.scheduleSave(
            [.message(id: "2", text: "KAISOLA_EXPIRED_WRITER_SECRET_497_4D22A9")],
            for: chatID,
            now: 2
        )
        let tombstoneResult = await writerA.tombstone(chatID: chatID)
        let tombstone = try XCTUnwrap(tombstoneResult.snapshot)
        await writerA.remove(
            chatID: chatID,
            verifiedDescriptorPruning: tombstone
        )
        let externalCleanup = await writerA.completeExternalCleanup(tombstone)
        XCTAssertEqual(externalCleanup, .removed)

        // Deterministic crash/suspension simulation: advance reclamation past
        // every bounded lease without sleeping in the test process.
        await writerA.vacuumTombstones(now: Int64.max)
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM transcript_writers", databaseURL: databaseURL),
            0
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM deleted_chats", databaseURL: databaseURL),
            0,
            "An expired writer cannot make tombstones grow indefinitely"
        )

        await writerB.flush()
        let restored = await writerB.entry(for: chatID)
        XCTAssertNil(
            restored,
            "A writer resuming after lease expiry must reject its stale captured generation"
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM transcript_rows", databaseURL: databaseURL),
            0
        )
    }

    func testWriterScheduledAfterTombstoneCannotRecreateAnyChatPayloadAfterExactReclamation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kaisola-transcript-post-tombstone-writer-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let deletingWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "deleting-window",
            schedulesAutomaticFlush: false
        )
        let delayedWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "delayed-window",
            schedulesAutomaticFlush: false
        )
        let chatID = "post-tombstone-delayed-writer"
        await deletingWindow.scheduleSave(
            [.message(id: "1", text: "original")],
            for: chatID,
            now: 1
        )
        await deletingWindow.flush()
        let deletion = await deletingWindow.tombstone(chatID: chatID)
        let receipt = try XCTUnwrap(deletion.snapshot)

        // Window B has never registered a writer generation. Its first writes
        // therefore land strictly after g1 and used to acknowledge g1 itself,
        // allowing the exact removal below to reclaim the only deletion fence.
        await delayedWindow.scheduleSave(
            [.message(id: "late-row", text: "must never return")],
            for: chatID,
            now: 2
        )
        await delayedWindow.scheduleDraft("late plaintext draft", for: chatID, now: 3)
        await delayedWindow.scheduleAttachments(
            [.textFile(path: "/tmp/late.txt", contents: "late attachment", name: "late.txt")],
            for: chatID,
            now: 4
        )
        await delayedWindow.scheduleSessionID("late-provider-session", for: chatID, now: 5)

        let removal = await deletingWindow.remove(
            chatID: chatID,
            verifiedDescriptorPruning: receipt
        )
        XCTAssertEqual(removal, .removed)
        let externalCleanup = await deletingWindow.completeExternalCleanup(receipt)
        XCTAssertEqual(externalCleanup, .removed)
        await deletingWindow.vacuumTombstones()
        let reclaimed = await deletingWindow.tombstoneState(chatID: chatID)
        XCTAssertEqual(reclaimed, .absent)

        await delayedWindow.flush()
        let delayedEntry = await delayedWindow.entry(for: chatID)
        XCTAssertNil(
            delayedEntry,
            "rows, drafts, attachments, and provider identity must all stay missing"
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM chats WHERE chat_id = '\(chatID)'", databaseURL: databaseURL),
            0
        )
    }

    func testMeshColumnBatchTombstoneIsAtomicAndRejectsAnOldWriterAfterExplicitReuse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kaisola-transcript-mesh-batch-delete-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let creatingWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "mesh-creating-window",
            schedulesAutomaticFlush: false
        )
        let delayedOldWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "mesh-delayed-old-window",
            schedulesAutomaticFlush: false
        )
        let deletingWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "mesh-deleting-window",
            schedulesAutomaticFlush: false
        )
        let columnIDs = ["mesh-column-a", "mesh-column-b"]
        for columnID in columnIDs {
            let began = await creatingWindow.beginNewChatID(columnID)
            XCTAssertTrue(began)
            await creatingWindow.scheduleSave(
                [.message(id: "initial", text: "initial \(columnID)")],
                for: columnID,
                now: 1
            )
        }
        await creatingWindow.flush()
        for columnID in columnIDs {
            let established = await delayedOldWindow.establishRestorableChatID(columnID)
            XCTAssertTrue(established)
        }
        await delayedOldWindow.scheduleSave(
            [.message(id: "old", text: "old incarnation must never reach reuse")],
            for: columnIDs[0],
            now: 2
        )

        let invalidBatch = await deletingWindow.tombstone(chatIDs: [columnIDs[0], ""])
        guard case .failed = invalidBatch else {
            return XCTFail("one invalid column must reject the whole batch")
        }
        let stateAfterInvalidBatch = await deletingWindow.tombstoneState(chatID: columnIDs[0])
        XCTAssertEqual(
            stateAfterInvalidBatch,
            .absent,
            "a rejected batch must not leave a partial Mesh deletion"
        )

        let deletion = await deletingWindow.tombstone(chatIDs: columnIDs)
        guard case let .recorded(receipts) = deletion else {
            return XCTFail("expected an atomic Mesh tombstone batch, got \(deletion)")
        }
        XCTAssertEqual(Set(receipts.map(\.chatID)), Set(columnIDs))
        for receipt in receipts {
            let removal = await deletingWindow.remove(
                chatID: receipt.chatID,
                verifiedDescriptorPruning: receipt
            )
            XCTAssertEqual(
                removal,
                .removed
            )
            let cleanup = await deletingWindow.completeExternalCleanup(receipt)
            XCTAssertEqual(cleanup, .removed)
        }
        await deletingWindow.vacuumTombstones(now: Int64.max)

        let reusedWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "mesh-reused-window",
            schedulesAutomaticFlush: false
        )
        let reusedIdentity = await reusedWindow.beginNewChatID(columnIDs[0])
        XCTAssertTrue(reusedIdentity)
        await reusedWindow.scheduleSave(
            [.message(id: "new", text: "new incarnation wins")],
            for: columnIDs[0],
            now: 3
        )
        await reusedWindow.flush()
        await delayedOldWindow.flush()

        let reusedEntry = await reusedWindow.entry(for: columnIDs[0])
        let reused = try XCTUnwrap(reusedEntry)
        XCTAssertEqual(reused.rows, [.message(id: "new", text: "new incarnation wins")])
        let deletedSecondColumn = await reusedWindow.entry(for: columnIDs[1])
        XCTAssertNil(deletedSecondColumn)
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM chat_incarnations", databaseURL: databaseURL),
            1,
            "permanently deleted Mesh columns must not leak inactive incarnation rows"
        )
    }

    func testPhysicalTranscriptRemovalRetainsExactReceiptUntilExternalCleanupCompletes() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let chatID = "external-cleanup-receipt"
        await store.scheduleSave(
            [.message(id: "row", text: "sensitive")],
            for: chatID,
            now: 1
        )
        await store.flush()
        let deletion = await store.tombstone(chatID: chatID)
        let g1 = try XCTUnwrap(deletion.snapshot)

        let removal = await store.remove(
            chatID: chatID,
            verifiedDescriptorPruning: g1
        )
        XCTAssertEqual(removal, .removed)
        let transcriptAfterRemoval = await store.entry(for: chatID)
        let receiptAfterRemoval = await store.tombstoneSnapshot(chatID: chatID)
        XCTAssertNil(transcriptAfterRemoval)
        XCTAssertEqual(
            receiptAfterRemoval,
            .present(g1),
            "the exact receipt must survive the transcript-only crash boundary"
        )
        XCTAssertEqual(
            try sqliteCount(
                "SELECT external_cleanup_blocked FROM deleted_chats WHERE chat_id = '\(chatID)'",
                databaseURL: store.databaseURL
            ),
            1
        )

        let g2Result = await store.tombstone(chatID: chatID)
        let g2 = try XCTUnwrap(g2Result.snapshot)
        let defaultsName = "kaisola.stale-cleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let defaultsKey = "chatDraft.\(chatID)"
        defaults.set("g2 plaintext", forKey: defaultsKey)
        let staleCleanup = await store.completeExternalCleanup(
            g1,
            performExternalCleanup: {
                UserDefaults(suiteName: defaultsName)?.removeObject(forKey: defaultsKey)
            }
        )
        XCTAssertEqual(
            staleCleanup,
            .failed(.database("transcript deletion cleanup receipt is stale or no longer present"))
        )
        XCTAssertEqual(
            defaults.string(forKey: defaultsKey),
            "g2 plaintext",
            "a stale g1 receipt must not execute cleanup against a later incarnation"
        )
        let retainedG2 = await store.tombstoneSnapshot(chatID: chatID)
        XCTAssertEqual(retainedG2, .present(g2))

        let partialFailureKey = "chatBooleanConfig.\(chatID)"
        defaults.set("still needs cleanup", forKey: partialFailureKey)
        let partialFailure = await store.completeExternalCleanup(
            g2,
            performExternalCleanup: {
                UserDefaults(suiteName: defaultsName)?.removeObject(forKey: defaultsKey)
                throw AcpTranscriptStore.StoreError.database("injected partial cleanup failure")
            }
        )
        XCTAssertEqual(
            partialFailure,
            .failed(.database("injected partial cleanup failure"))
        )
        let retainedAfterPartialFailure = await store.tombstoneSnapshot(chatID: chatID)
        XCTAssertEqual(
            retainedAfterPartialFailure,
            .present(g2),
            "a throwing synchronous cleanup must leave the exact receipt retryable"
        )
        XCTAssertEqual(defaults.string(forKey: partialFailureKey), "still needs cleanup")

        // Complete g2's descriptor/transcript phase and then the separately
        // verified external plaintext phase. Only the latter may reclaim it.
        let g2Removal = await store.remove(
            chatID: chatID,
            verifiedDescriptorPruning: g2
        )
        XCTAssertEqual(g2Removal, .removed)
        let completed = await store.completeExternalCleanup(
            g2,
            performExternalCleanup: {
                UserDefaults(suiteName: defaultsName)?.removeObject(forKey: defaultsKey)
                UserDefaults(suiteName: defaultsName)?.removeObject(forKey: partialFailureKey)
            }
        )
        XCTAssertEqual(completed, .removed)
        XCTAssertNil(defaults.object(forKey: defaultsKey))
        let finalState = await store.tombstoneState(chatID: chatID)
        XCTAssertEqual(finalState, .absent)
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COUNT(*) FROM deletion_watermarks WHERE chat_id = '\(chatID)'",
                databaseURL: store.databaseURL
            ),
            1,
            "the anti-resurrection watermark outlives the one-shot cleanup receipt"
        )
    }

    func testWatermarkCompactionStaysBoundedAndRequiresDurableHigherIncarnationForReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-watermark-compaction-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let deletingWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "compaction-deleter",
            schedulesAutomaticFlush: false
        )
        let delayedWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "compaction-delayed",
            schedulesAutomaticFlush: false
        )
        let deletedChatID = "compacted-old-snapshot"
        await delayedWindow.scheduleSave(
            [.message(id: "late", text: "old incarnation")],
            for: deletedChatID,
            now: 1
        )
        let deletion = await deletingWindow.tombstone(chatID: deletedChatID)
        let g1 = try XCTUnwrap(deletion.snapshot)
        let removal = await deletingWindow.remove(
            chatID: deletedChatID,
            verifiedDescriptorPruning: g1
        )
        XCTAssertEqual(removal, .removed)
        let cleanup = await deletingWindow.completeExternalCleanup(g1)
        XCTAssertEqual(cleanup, .removed)

        // Seed more exact, already-finished watermarks than the hard bound.
        // All share a valid generation and have no chat/writer references.
        try TranscriptDatabaseProbe.execute(
            """
            WITH RECURSIVE sequence(value) AS (
                SELECT 0
                UNION ALL SELECT value + 1 FROM sequence WHERE value < 4096
            )
            INSERT INTO deletion_watermarks(chat_id, generation, deleted_at)
            SELECT printf('old-watermark-%04d', value), 1, value FROM sequence;
            """,
            at: databaseURL
        )
        await deletingWindow.vacuumTombstones(now: Int64.max)
        XCTAssertLessThanOrEqual(
            try sqliteCount("SELECT COUNT(*) FROM deletion_watermarks", databaseURL: databaseURL),
            AcpTranscriptStore.maximumDeletionWatermarks
        )
        XCTAssertEqual(
            try sqliteCount(
                "SELECT value FROM store_meta WHERE key = 'deletion_watermarks_require_explicit_creation'",
                databaseURL: databaseURL
            ),
            1
        )

        await delayedWindow.flush()
        let delayedResult = await delayedWindow.entry(for: deletedChatID)
        XCTAssertNil(delayedResult, "an old buffered incarnation must stay rejected after compaction")

        let unapproved = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "compaction-unapproved",
            schedulesAutomaticFlush: false
        )
        await unapproved.scheduleDraft("must not land", for: "unknown-after-compaction", now: 2)
        await unapproved.flush()
        let unapprovedEntry = await unapproved.entry(for: "unknown-after-compaction")
        XCTAssertNil(unapprovedEntry)

        // Reuse is explicit and durable: authorization survives this actor going
        // away, and its generation is strictly newer than the old deletion.
        do {
            let authorizer = AcpTranscriptStore(
                databaseURL: databaseURL,
                writerID: "compaction-authorizer",
                schedulesAutomaticFlush: false
            )
            let authorized = await authorizer.beginNewChatID(deletedChatID)
            XCTAssertTrue(authorized)
        }
        let reused = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "compaction-reused",
            schedulesAutomaticFlush: false
        )
        let joinedReuse = await reused.establishRestorableChatID(deletedChatID)
        XCTAssertTrue(joinedReuse)
        await reused.scheduleDraft("intentional new incarnation", for: deletedChatID, now: 3)
        await reused.flush()
        let reusedEntry = await reused.entry(for: deletedChatID)
        XCTAssertEqual(reusedEntry?.draft, "intentional new incarnation")
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COUNT(*) FROM chat_incarnations WHERE chat_id = '\(deletedChatID)'",
                databaseURL: databaseURL
            ),
            1,
            "the durable incarnation must outlive transcript pruning and later writers"
        )
        XCTAssertGreaterThan(
            try sqliteCount(
                "SELECT generation FROM deletion_watermarks WHERE chat_id = '\(deletedChatID)'",
                databaseURL: databaseURL
            ),
            0
        )

        // The independent incarnation bound rejects new identities; it never
        // compacts or evicts a still-active identity to make room.
        try TranscriptDatabaseProbe.execute(
            """
            WITH RECURSIVE sequence(value) AS (
                SELECT 0
                UNION ALL SELECT value + 1 FROM sequence WHERE value < 32766
            )
            INSERT INTO chat_incarnations(chat_id, generation, created_at)
            SELECT printf('active-incarnation-%05d', value), 2, value FROM sequence;
            """,
            at: databaseURL
        )
        XCTAssertEqual(
            try sqliteCount("SELECT COUNT(*) FROM chat_incarnations", databaseURL: databaseURL),
            AcpTranscriptStore.maximumChatIncarnations
        )
        let overflow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "compaction-overflow",
            schedulesAutomaticFlush: false
        )
        let overflowBegan = await overflow.beginNewChatID("must-not-evict-active")
        XCTAssertFalse(overflowBegan)
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COUNT(*) FROM chat_incarnations WHERE chat_id = '\(deletedChatID)'",
                databaseURL: databaseURL
            ),
            1
        )
    }

    func testOldWindowIncarnationCannotWriteIntoIntentionalReuseOfSameChatID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-incarnation-reuse-fence-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let chatID = "explicit-reuse-fence"
        let oldWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "reuse-old-window",
            schedulesAutomaticFlush: false
        )
        let oldIncarnationBegan = await oldWindow.beginNewChatID(chatID)
        XCTAssertTrue(oldIncarnationBegan)
        await oldWindow.scheduleSave(
            [.message(id: "old-row", text: "old incarnation")],
            for: chatID,
            now: 1
        )
        await oldWindow.scheduleDraft("old draft", for: chatID, now: 1)
        await oldWindow.scheduleAttachments(
            [.textFile(path: "/tmp/old.txt", contents: "old", name: "old.txt")],
            for: chatID,
            now: 1
        )
        await oldWindow.scheduleSessionID("old-session", for: chatID, now: 1)

        let deletingWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "reuse-deleting-window",
            schedulesAutomaticFlush: false
        )
        let deletion = await deletingWindow.tombstone(chatID: chatID)
        let g1 = try XCTUnwrap(deletion.snapshot)
        let removal = await deletingWindow.remove(
            chatID: chatID,
            verifiedDescriptorPruning: g1
        )
        XCTAssertEqual(removal, .removed)
        let externalCleanup = await deletingWindow.completeExternalCleanup(g1)
        XCTAssertEqual(externalCleanup, .removed)
        await deletingWindow.vacuumTombstones(now: Int64.max)
        let tombstoneState = await deletingWindow.tombstoneState(chatID: chatID)
        XCTAssertEqual(tombstoneState, .absent)

        let newWindow = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "reuse-new-window",
            schedulesAutomaticFlush: false
        )
        let newIncarnationBegan = await newWindow.beginNewChatID(chatID)
        XCTAssertTrue(newIncarnationBegan)
        await newWindow.scheduleSave(
            [.message(id: "new-row", text: "new incarnation")],
            for: chatID,
            now: 2
        )
        await newWindow.scheduleDraft("new draft", for: chatID, now: 2)
        await newWindow.scheduleAttachments(
            [.textFile(path: "/tmp/new.txt", contents: "new", name: "new.txt")],
            for: chatID,
            now: 2
        )
        await newWindow.scheduleSessionID("new-session", for: chatID, now: 2)
        await newWindow.flush()

        // Window A still owns its immutable pre-delete token. Its delayed
        // snapshot must not mutate any field of the explicitly reused chat.
        await oldWindow.flush()
        let restored = await newWindow.entry(for: chatID)
        XCTAssertEqual(restored?.rows, [.message(id: "new-row", text: "new incarnation")])
        XCTAssertEqual(restored?.draft, "new draft")
        XCTAssertEqual(restored?.attachments.map(\.name), ["new.txt"])
        XCTAssertEqual(restored?.sessionID, "new-session")
    }

    func testFailedNewChatProvisioningCanAbandonOnlyItsEmptyExactIncarnation() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let abandonedID = "failed-provisioning-incarnation"
        let retainedID = "payload-bearing-incarnation"

        let beganAbandoned = await store.beginNewChatID(abandonedID)
        XCTAssertTrue(beganAbandoned)
        let abandoned = await store.abandonNewChatID(abandonedID)
        XCTAssertTrue(abandoned)
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COUNT(*) FROM chat_incarnations WHERE chat_id = '\(abandonedID)'",
                databaseURL: store.databaseURL
            ),
            0
        )

        let beganRetained = await store.beginNewChatID(retainedID)
        XCTAssertTrue(beganRetained)
        await store.scheduleDraft("durable payload", for: retainedID, now: 1)
        await store.flush()
        let refused = await store.abandonNewChatID(retainedID)
        XCTAssertFalse(refused, "an incarnation with durable payload is never provisioning debris")
        let restored = await store.entry(for: retainedID)
        XCTAssertEqual(restored?.draft, "durable payload")
    }

    func testNewChatAuthorizationCannotAdoptAnotherActorsExistingIncarnation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-incarnation-collision-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let first = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "collision-first",
            schedulesAutomaticFlush: false
        )
        let second = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "collision-second",
            schedulesAutomaticFlush: false
        )
        let chatID = "fresh-generated-id-collision"

        let firstBegan = await first.beginNewChatID(chatID)
        XCTAssertTrue(firstBegan)
        let secondBegan = await second.beginNewChatID(chatID)
        XCTAssertFalse(
            secondBegan,
            "a generated-new collision must fail instead of adopting another actor's identity"
        )
        await second.scheduleDraft("must not attach", for: chatID, now: 1)
        await second.flush()
        let secondEntry = await second.entry(for: chatID)
        XCTAssertNil(secondEntry)

        await first.scheduleDraft("first incarnation", for: chatID, now: 2)
        await first.flush()
        let firstEntry = await first.entry(for: chatID)
        XCTAssertEqual(firstEntry?.draft, "first incarnation")
    }

    func testV6TombstonesMigrateToDurableWatermarksAndExternalCleanupReceipts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-v6-watermark-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        do {
            let original = AcpTranscriptStore(databaseURL: databaseURL)
            let deletion = await original.tombstone(chatID: "installed-v6-delete")
            XCTAssertNotNil(deletion.snapshot)
        }
        try TranscriptDatabaseProbe.execute(
            """
            DROP TABLE deletion_watermarks;
            DROP TABLE chat_incarnations;
            DELETE FROM store_meta WHERE key = 'chat_incarnation_backfill_complete';
            PRAGMA user_version = 6;
            """,
            at: databaseURL
        )

        let migrated = AcpTranscriptStore(databaseURL: databaseURL)
        let migratedState = await migrated.tombstoneState(chatID: "installed-v6-delete")
        XCTAssertEqual(migratedState, .present)
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COUNT(*) FROM deletion_watermarks WHERE chat_id = 'installed-v6-delete'",
                databaseURL: databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try sqliteCount(
                "SELECT external_cleanup_blocked FROM deleted_chats WHERE chat_id = 'installed-v6-delete'",
                databaseURL: databaseURL
            ),
            1
        )
        XCTAssertEqual(try sqliteCount("PRAGMA user_version", databaseURL: databaseURL), 9)
    }

    func testInstalledDatabaseBackfillsLiveChatsBeforeUnknownIDsFailClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-incarnation-installed-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        let liveChatID = "installed-live-chat"
        do {
            let installed = AcpTranscriptStore(
                databaseURL: databaseURL,
                schedulesAutomaticFlush: false
            )
            await installed.scheduleSave(
                [.message(id: "installed", text: "existing history")],
                for: liveChatID,
                now: 1
            )
            await installed.flush()
        }
        try TranscriptDatabaseProbe.execute(
            """
            DROP TABLE chat_incarnations;
            DELETE FROM store_meta WHERE key = 'chat_incarnation_backfill_complete';
            INSERT INTO store_meta(key, value)
            VALUES ('deletion_watermarks_require_explicit_creation', '1')
            ON CONFLICT(key) DO UPDATE SET value = '1';
            PRAGMA user_version = 6;
            """,
            at: databaseURL
        )

        let migrated = AcpTranscriptStore(
            databaseURL: databaseURL,
            schedulesAutomaticFlush: false
        )
        let joinedLiveChat = await migrated.establishRestorableChatID(liveChatID)
        XCTAssertTrue(joinedLiveChat)
        await migrated.scheduleDraft("post-migration draft", for: liveChatID, now: 2)
        await migrated.flush()
        let restored = await migrated.entry(for: liveChatID)
        XCTAssertEqual(restored?.rows, [.message(id: "installed", text: "existing history")])
        XCTAssertEqual(restored?.draft, "post-migration draft")
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COUNT(*) FROM chat_incarnations WHERE chat_id = '\(liveChatID)'",
                databaseURL: databaseURL
            ),
            1
        )

        let unknownRestore = await migrated.establishRestorableChatID(
            "unknown-installed-descriptor"
        )
        XCTAssertFalse(unknownRestore)
        XCTAssertEqual(try sqliteCount("PRAGMA user_version", databaseURL: databaseURL), 9)
    }

    func testUsagePersistsBesideRowsAndSurvivesLaterTranscriptSave() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let usage = AcpPersistedUsage(
            title: "Codex · Project",
            agentID: "codex",
            latestUsed: 1_200,
            latestMax: 16_000,
            peakUsed: 1_800,
            turns: 4,
            costAmount: 0.42,
            costCurrency: "USD"
        )
        await store.scheduleUsage(usage, for: "chat-usage", now: 1)
        await store.scheduleSave([.message(id: "1", text: "saved")], for: "chat-usage", now: 2)
        await store.flush()

        let reopened = AcpTranscriptStore(fileURL: directory.appendingPathComponent("transcripts.json"))
        let restored = await reopened.entry(for: "chat-usage")
        XCTAssertEqual(restored?.rows, [.message(id: "1", text: "saved")])
        XCTAssertEqual(restored?.usage, usage)
    }

    func testClearUsageKeepsDurableTranscript() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.scheduleSave([.message(id: "1", text: "saved")], for: "chat-clear", now: 1)
        await store.scheduleUsage(
            AcpPersistedUsage(
                title: "Chat", agentID: "claude-code", latestUsed: 10,
                latestMax: 100, peakUsed: 10, turns: 1,
                costAmount: nil, costCurrency: nil
            ),
            for: "chat-clear",
            now: 2
        )
        await store.flush()
        await store.clearUsage()

        let restored = await store.entry(for: "chat-clear")
        XCTAssertEqual(restored?.rows, [.message(id: "1", text: "saved")])
        XCTAssertNil(restored?.usage)
    }

    func testRemoveUsageKeepsDurableTranscript() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.scheduleSave([.message(id: "1", text: "saved")], for: "chat-remove-usage", now: 1)
        await store.scheduleUsage(
            AcpPersistedUsage(
                title: "Chat", agentID: "codex", latestUsed: 10,
                latestMax: 100, peakUsed: 10, turns: 1,
                costAmount: nil, costCurrency: nil
            ),
            for: "chat-remove-usage",
            now: 2
        )
        await store.flush()
        await store.removeUsage(chatID: "chat-remove-usage")

        let restored = await store.entry(for: "chat-remove-usage")
        XCTAssertEqual(restored?.rows, [.message(id: "1", text: "saved")])
        XCTAssertNil(restored?.usage)
    }

    func testRemoveUsagePrunesEmptyEntryCreatedAfterFullRemoval() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let usage = AcpPersistedUsage(
            title: "Closed", agentID: "codex", latestUsed: 100, latestMax: 1_000,
            peakUsed: 100, turns: 1, costAmount: nil, costCurrency: nil
        )

        _ = await store.remove(chatID: "closed")
        await store.scheduleUsage(usage, for: "closed", now: 2)
        await store.removeUsage(chatID: "closed")
        await store.flush()

        let entry = await store.entry(for: "closed")
        XCTAssertNil(entry)
    }

    func testTailAndEarlierReadsStayBoundedAndReachTheFirstRetainedRow() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var rows = (0..<1_200).map {
            AcpTranscriptRow.message(id: "\($0)", text: "row \($0)")
        }
        rows[600] = .tool(AcpToolCall(
            id: "tool-600",
            title: "Read source",
            kind: "read",
            status: .completed
        ))
        await store.scheduleSave(rows, for: "chat-pages", now: 1)
        await store.flush()

        let restoration = await store.restoration(for: "chat-pages", tailLimit: 120).restoration
        let restored = try XCTUnwrap(restoration)
        XCTAssertEqual(restored.page.rows.count, 120)
        XCTAssertEqual(restored.page.startOrdinal, 1_080)
        XCTAssertEqual(restored.page.earlierRowCount, 1_080)
        XCTAssertEqual(restored.page.totalRowCount, 1_200)

        var collected = restored.page.rows
        var boundary = restored.page.startOrdinal
        var pageCount = 0
        while boundary > 0 {
            let loadedPage = await store.page(
                for: "chat-pages",
                beforeOrdinal: boundary,
                limit: 200
            )
            let page = try XCTUnwrap(loadedPage)
            XCTAssertLessThanOrEqual(page.rows.count, 200)
            XCTAssertEqual(page.endOrdinalExclusive, boundary)
            collected.insert(contentsOf: page.rows, at: 0)
            boundary = page.startOrdinal
            pageCount += 1
            XCTAssertLessThan(pageCount, 20)
        }

        XCTAssertEqual(collected, rows)
        XCTAssertEqual(collected.first?.id, "msg-0")
        XCTAssertEqual(collected.last?.id, "msg-1199")
        guard case let .tool(tool) = collected[600] else {
            return XCTFail("Expected the migrated page sequence to preserve its tool card")
        }
        XCTAssertEqual(tool.id, "tool-600")
    }

    func testOversizedReadRequestIsClampedToMaximumPageSize() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = (0..<800).map { AcpTranscriptRow.message(id: "\($0)", text: "\($0)") }
        await store.scheduleSave(rows, for: "chat-clamp", now: 1)
        await store.flush()

        let restoration = await store.restoration(for: "chat-clamp", tailLimit: 50_000).restoration
        let restored = try XCTUnwrap(restoration)
        XCTAssertEqual(restored.page.rows.count, AcpTranscriptStore.maximumPageSize)
        XCTAssertEqual(restored.page.earlierRowCount, 300)
    }

    func testTailRewritePreservesUnloadedPrefixAndAppendsInStableOrder() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = (0..<1_000).map { AcpTranscriptRow.message(id: "\($0)", text: "row \($0)") }
        await store.scheduleSave(rows, for: "chat-tail", now: 1)
        await store.flush()
        let restoration = await store.restoration(for: "chat-tail", tailLimit: 120).restoration
        let restored = try XCTUnwrap(restoration)

        var changedTail = restored.page.rows
        changedTail[changedTail.count - 1] = .message(id: "999", text: "streamed completion")
        changedTail.append(.message(id: "1000", text: "new row"))
        await store.scheduleSave(
            changedTail,
            for: "chat-tail",
            startOrdinal: restored.page.startOrdinal,
            now: 2
        )
        await store.flush()

        let reopened = AcpTranscriptStore(fileURL: directory.appendingPathComponent("transcripts.json"))
        let allRows = await reopened.rows(for: "chat-tail")
        XCTAssertEqual(allRows.count, 1_001)
        XCTAssertEqual(allRows.first, rows.first)
        XCTAssertEqual(allRows[879], rows[879])
        XCTAssertEqual(allRows[999], .message(id: "999", text: "streamed completion"))
        XCTAssertEqual(allRows.last, .message(id: "1000", text: "new row"))
    }

    func testDraftAttachmentsUsageAndSessionIdentityRoundTripTogether() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let usage = AcpPersistedUsage(
            title: "Codex · Project",
            agentID: "codex",
            latestUsed: 3_000,
            latestMax: 32_000,
            peakUsed: 4_000,
            turns: 6,
            costAmount: 1.25,
            costCurrency: "USD"
        )
        let attachments: [AcpAttachment] = [
            .image(data: Data([1, 2, 3, 4]), mimeType: "image/png", name: "shot.png"),
            .textFile(path: "/tmp/notes.txt", contents: "remember this", name: "notes.txt"),
        ]
        await store.scheduleSave([.message(id: "1", text: "saved")], for: "chat-metadata", now: 1)
        await store.scheduleUsage(usage, for: "chat-metadata", now: 2)
        await store.scheduleDraft("unfinished thought", for: "chat-metadata", now: 3)
        await store.scheduleAttachments(attachments, for: "chat-metadata", now: 4)
        await store.scheduleSessionID("provider-session-42", for: "chat-metadata", now: 5)
        await store.flush()

        let reopened = AcpTranscriptStore(fileURL: directory.appendingPathComponent("transcripts.json"))
        let restoration = await reopened.restoration(for: "chat-metadata", tailLimit: 120).restoration
        let restored = try XCTUnwrap(restoration)
        XCTAssertEqual(restored.page.rows, [.message(id: "1", text: "saved")])
        XCTAssertEqual(restored.usage, usage)
        XCTAssertEqual(restored.draft, "unfinished thought")
        XCTAssertEqual(restored.attachments, attachments)
        XCTAssertEqual(restored.sessionID, "provider-session-42")

        await reopened.scheduleDraft("", for: "chat-metadata", now: 6)
        await reopened.scheduleAttachments([], for: "chat-metadata", now: 7)
        await reopened.scheduleSessionID(nil, for: "chat-metadata", now: 8)
        await reopened.flush()
        let clearedRestoration = await reopened.restoration(for: "chat-metadata", tailLimit: 120).restoration
        let cleared = try XCTUnwrap(clearedRestoration)
        XCTAssertNil(cleared.draft)
        XCTAssertTrue(cleared.attachments.isEmpty)
        XCTAssertNil(cleared.sessionID)
        XCTAssertEqual(cleared.usage, usage)
    }

    func testTombstoneLookupSeparatesDeletedChatsFromNeverDeletedOnes() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.scheduleSave([.message(id: "1", text: "live")], for: "chat-live", now: 1)
        await store.flush()
        let beforeDelete = await store.tombstoneState(chatID: "chat-live")
        XCTAssertEqual(beforeDelete, .absent)

        let tombstoneResult = await store.tombstone(chatID: "chat-live")
        XCTAssertNotNil(tombstoneResult.snapshot)
        let afterDelete = await store.tombstoneState(chatID: "chat-live")
        XCTAssertEqual(afterDelete, .present)
        let neverSeen = await store.tombstoneState(chatID: "chat-never-seen")
        XCTAssertEqual(neverSeen, .absent)

        // A buffered chunk landing after the delete still cannot re-materialize.
        await store.scheduleSave([.message(id: "2", text: "late chunk")], for: "chat-live", now: 3)
        await store.flush()
        let rows = await store.rows(for: "chat-live")
        XCTAssertEqual(rows, [.message(id: "1", text: "live")])
    }

    func testTombstoneLookupIsUnknownWhenTheDatabaseIsCorrupt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-corrupt-db-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        try Data(repeating: 0x7f, count: 8_192).write(to: databaseURL, options: .atomic)

        let store = AcpTranscriptStore(databaseURL: databaseURL)
        let state = await store.tombstoneState(chatID: "chat-corrupt")
        XCTAssertEqual(state, .unknown)
    }

    func testTombstoneLookupIsUnknownWhenTheDatabaseCannotBeRead() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tombstoneResult = await store.tombstone(chatID: "chat-denied")
        XCTAssertNotNil(tombstoneResult.snapshot)
        let readable = await store.tombstoneState(chatID: "chat-denied")
        XCTAssertEqual(readable, .present)

        // A relaunch that cannot open the file at all must not conclude the
        // chat survived: the deletion record is right there, unreadable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: store.databaseURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: store.databaseURL.path
            )
        }
        let reopened = AcpTranscriptStore(databaseURL: store.databaseURL)
        let state = await reopened.tombstoneState(chatID: "chat-denied")
        XCTAssertEqual(state, .unknown)
    }

    func testTombstoneLookupIsUnknownWhileAnotherWriterHoldsTheDatabase() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tombstoneResult = await store.tombstone(chatID: "chat-busy")
        XCTAssertNotNil(tombstoneResult.snapshot)

        let blocker = try openSideConnection(to: store.databaseURL)
        defer { sqlite3_close_v2(blocker) }
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)

        // The store's connection is already open, so this exercises a busy
        // lookup rather than a busy open.
        let state = await store.tombstoneState(chatID: "chat-busy")
        XCTAssertEqual(state, .unknown)
    }

    func testBufferedWritesAreWithheldWhileTheTombstoneProbeCannotComplete() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.scheduleSessionID("provider-session", for: "chat-probe", now: 1)
        await store.flush()

        // A rolled-back build or a hand-edited database can leave a
        // deleted_chats table this schema cannot query. The lookup then fails
        // to prepare, which must not be read as "never deleted".
        let side = try openSideConnection(to: store.databaseURL)
        XCTAssertEqual(
            sqlite3_exec(
                side,
                "ALTER TABLE deleted_chats RENAME TO deleted_chats_valid",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(
                side,
                "CREATE TABLE deleted_chats (id TEXT PRIMARY KEY NOT NULL)",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        let rows: [AcpTranscriptRow] = [.message(id: "1", text: "must not land unverified")]
        await store.scheduleSave(rows, for: "chat-probe", now: 2)
        await store.flush()
        let probe = await store.tombstoneState(chatID: "chat-probe")
        XCTAssertEqual(probe, .unknown)
        let withheld = await store.rows(for: "chat-probe")
        XCTAssertTrue(withheld.isEmpty)

        // Withheld, not lost: the coalesced snapshot lands once the probe can
        // answer again.
        XCTAssertEqual(sqlite3_exec(side, "DROP TABLE deleted_chats", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                side,
                "ALTER TABLE deleted_chats_valid RENAME TO deleted_chats",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close_v2(side)
        await store.flush()
        let restored = await store.rows(for: "chat-probe")
        XCTAssertEqual(restored, rows)
    }

    func testTwoColumnTombstonesMigrateToGenerationFencingWithoutDataLoss() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let liveRows: [AcpTranscriptRow] = [.message(id: "1", text: "still live")]
        await store.scheduleSave(liveRows, for: "chat-live", now: 1)
        await store.flush()

        let side = try openSideConnection(to: store.databaseURL)
        XCTAssertEqual(
            sqlite3_exec(
                side,
                """
                DROP TABLE IF EXISTS deleted_chats;
                CREATE TABLE deleted_chats (
                    chat_id TEXT PRIMARY KEY NOT NULL,
                    deleted_at INTEGER NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO deleted_chats(chat_id, deleted_at)
                VALUES ('legacy-deleted', 1);
                PRAGMA user_version = 2;
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close_v2(side)

        let reopened = AcpTranscriptStore(databaseURL: store.databaseURL)
        let legacyState = await reopened.tombstoneState(chatID: "legacy-deleted")
        let restoredRows = await reopened.rows(for: "chat-live")
        XCTAssertEqual(legacyState, .present)
        XCTAssertEqual(restoredRows, liveRows)
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COUNT(*) FROM pragma_table_info('deleted_chats') WHERE name = 'generation'",
                databaseURL: store.databaseURL
            ),
            1
        )
        XCTAssertGreaterThan(
            try sqliteCount(
                "SELECT generation FROM deleted_chats WHERE chat_id = 'legacy-deleted'",
                databaseURL: store.databaseURL
            ),
            0
        )
        XCTAssertEqual(
            try sqliteCount(
                "SELECT descriptor_reclaim_blocked FROM deleted_chats WHERE chat_id = 'legacy-deleted'",
                databaseURL: store.databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try sqliteCount("PRAGMA user_version", databaseURL: store.databaseURL),
            9
        )
    }

    func testV5MigrationReblocksExistingDescriptorFencesExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-transcript-v5-descriptor-fence-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("transcripts.sqlite3")
        var setup: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &setup, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        let database = try XCTUnwrap(setup)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                CREATE TABLE store_meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                INSERT INTO store_meta(key, value) VALUES ('deletion_generation', '7');
                CREATE TABLE deleted_chats (
                    chat_id TEXT PRIMARY KEY NOT NULL,
                    deleted_at INTEGER NOT NULL,
                    generation INTEGER NOT NULL,
                    descriptor_reclaim_blocked INTEGER NOT NULL DEFAULT 0
                ) WITHOUT ROWID;
                INSERT INTO deleted_chats(
                    chat_id, deleted_at, generation, descriptor_reclaim_blocked
                ) VALUES ('installed-v5-delete', 1, 7, 0);
                PRAGMA user_version = 5;
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close_v2(database)

        let migrated = AcpTranscriptStore(databaseURL: databaseURL)
        let migratedState = await migrated.tombstoneState(chatID: "installed-v5-delete")
        XCTAssertEqual(migratedState, .present)
        XCTAssertEqual(
            try sqliteCount(
                "SELECT descriptor_reclaim_blocked FROM deleted_chats WHERE chat_id = 'installed-v5-delete'",
                databaseURL: databaseURL
            ),
            1,
            "installed v5 rows whose old default was zero must be conservatively re-fenced"
        )
        XCTAssertEqual(
            try sqliteCount(
                "SELECT COUNT(*) FROM store_meta WHERE key = 'descriptor_fences_blocked' AND value = '1'",
                databaseURL: databaseURL
            ),
            1
        )
        XCTAssertEqual(try sqliteCount("PRAGMA user_version", databaseURL: databaseURL), 9)

        // The marker is one-shot. Zero is a legitimate state only after an
        // exact receipt release, and reopening v8 must not overwrite it.
        try TranscriptDatabaseProbe.execute(
            "UPDATE deleted_chats SET descriptor_reclaim_blocked = 0",
            at: databaseURL
        )
        let reopened = AcpTranscriptStore(databaseURL: databaseURL)
        let reopenedState = await reopened.tombstoneState(chatID: "installed-v5-delete")
        XCTAssertEqual(reopenedState, .present)
        XCTAssertEqual(
            try sqliteCount(
                "SELECT descriptor_reclaim_blocked FROM deleted_chats WHERE chat_id = 'installed-v5-delete'",
                databaseURL: databaseURL
            ),
            0,
            "the completed migration marker must preserve a later exact release"
        )
    }

    func testLegacyJSONMigrationIsAtomicBoundedAndLeavesTheSourceUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent("transcripts.json")
        let rows: [AcpTranscriptRow] = [
            .user(id: "1", text: "legacy prompt", failed: false),
            .tool(AcpToolCall(id: "legacy-tool", title: "Search", kind: "search", status: .completed)),
            .message(id: "2", text: "legacy answer"),
        ]
        let payload = LegacyPayload(entries: [
            "legacy-chat": AcpTranscriptStore.Entry(rows: rows, updatedAt: 42),
        ])
        let originalBytes = try JSONEncoder().encode(payload)
        try originalBytes.write(to: legacyURL, options: .atomic)

        let store = AcpTranscriptStore(fileURL: legacyURL)
        let restoration = await store.restoration(for: "legacy-chat", tailLimit: 2).restoration
        let restored = try XCTUnwrap(restoration)
        XCTAssertEqual(restored.page.rows, Array(rows.suffix(2)))
        XCTAssertEqual(restored.page.earlierRowCount, 1)
        XCTAssertEqual(try Data(contentsOf: legacyURL), originalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.databaseURL.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)

        // Once committed, a stale rollback copy cannot overwrite the v2 rows.
        let stale = LegacyPayload(entries: [
            "legacy-chat": AcpTranscriptStore.Entry(
                rows: [.message(id: "stale", text: "must not replace SQLite")],
                updatedAt: 99
            ),
        ])
        try JSONEncoder().encode(stale).write(to: legacyURL, options: .atomic)
        let reopened = AcpTranscriptStore(fileURL: legacyURL)
        let reopenedRows = await reopened.rows(for: "legacy-chat")
        XCTAssertEqual(reopenedRows, rows)
    }

    func testCorruptLegacyArchiveDoesNotPartiallyMigrateAndCanRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent("transcripts.json")
        let corruptBytes = Data("{not-json".utf8)
        try corruptBytes.write(to: legacyURL, options: .atomic)
        let store = AcpTranscriptStore(fileURL: legacyURL)

        let failedOutcome = await store.restoration(for: "retry-chat", tailLimit: 120)
        // A damaged import is reported as damage, never as an empty chat.
        XCTAssertEqual(try XCTUnwrap(failedOutcome.failure).fault, .corrupt)
        XCTAssertNil(failedOutcome.restoration)
        XCTAssertEqual(try Data(contentsOf: legacyURL), corruptBytes)

        let rows: [AcpTranscriptRow] = [.message(id: "1", text: "recovered source")]
        let repaired = LegacyPayload(entries: [
            "retry-chat": AcpTranscriptStore.Entry(rows: rows, updatedAt: 1),
        ])
        try JSONEncoder().encode(repaired).write(to: legacyURL, options: .atomic)
        let restoration = await store.restoration(for: "retry-chat", tailLimit: 120).restoration
        let restored = try XCTUnwrap(restoration)
        XCTAssertEqual(restored.page.rows, rows)
        let established = await store.establishRestorableChatID("retry-chat")
        XCTAssertTrue(
            established,
            "A migrated legacy descriptor must bind its durable incarnation before writing"
        )

        // The write refusal lifts with the fault: a chat that reads back is
        // durable again.
        await store.scheduleSave(
            rows + [.message(id: "2", text: "new turn")],
            for: "retry-chat",
            now: 2
        )
        await store.flush()
        let reread = await store.rows(for: "retry-chat")
        XCTAssertEqual(reread.count, 2)
    }

    func testLateLegacySourceImportsWhenV2WasOnlyPrecreatedAndNeverWritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-late-v1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent("transcripts.json")

        let precreated = AcpTranscriptStore(fileURL: legacyURL)
        let absent = await precreated.restoration(for: "late-chat", tailLimit: 120)
        XCTAssertEqual(absent, .missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: precreated.databaseURL.path))

        let rows: [AcpTranscriptRow] = [.message(id: "1", text: "final v1 write")]
        let payload = LegacyPayload(entries: [
            "late-chat": AcpTranscriptStore.Entry(rows: rows, updatedAt: 2),
        ])
        try JSONEncoder().encode(payload).write(to: legacyURL, options: .atomic)

        let relaunched = AcpTranscriptStore(fileURL: legacyURL)
        let restoration = await relaunched.restoration(for: "late-chat", tailLimit: 120).restoration
        XCTAssertEqual(try XCTUnwrap(restoration).page.rows, rows)
    }

    // MARK: - Deletion tombstones

    func testFailedTombstoneOpenKeepsTheChatAndItsBufferedTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-tombstone-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("transcripts-v2.sqlite3")
        let store = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "canonical-tombstone-open",
            schedulesAutomaticFlush: false,
            injectedTombstoneFailure: .open
        )
        let saved: [AcpTranscriptRow] = [
            .user(id: "1", text: "delete me", failed: false),
        ]
        let buffered = saved + [
            .message(id: "1", text: "newest buffered tail"),
        ]
        await store.scheduleSave(saved, for: "chat-open-failure", now: 1)
        await store.flush()
        await store.scheduleSave(buffered, for: "chat-open-failure", now: 2)

        let outcome = await store.tombstone(chatID: "chat-open-failure")
        XCTAssertEqual(
            outcome,
            .failed(.database("injected transcript tombstone open failure"))
        )
        let state = await store.tombstoneState(chatID: "chat-open-failure")
        XCTAssertEqual(state, .absent)
        await store.flush()

        let reopened = AcpTranscriptStore(databaseURL: databaseURL)
        let restored = await reopened.rows(for: "chat-open-failure")
        XCTAssertEqual(restored, buffered)
    }

    func testFailedTombstoneCommitKeepsTheChatAndItsBufferedTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-tombstone-commit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("transcripts-v2.sqlite3")

        let store = AcpTranscriptStore(databaseURL: databaseURL)
        let saved: [AcpTranscriptRow] = [.message(id: "1", text: "already durable")]
        await store.scheduleSave(saved, for: "chat-commit-failure", now: 1)
        await store.flush()

        let buffered = saved + [.message(id: "2", text: "newest buffered tail")]
        await store.scheduleSave(buffered, for: "chat-commit-failure", now: 2)
        // Establish the buffered write's valid generation fence before the
        // reader blocks the tombstone COMMIT. Acquiring the lock first would
        // correctly make captureWriterFence fail closed and drop that snapshot.
        let reader = try SQLiteReadLock(path: databaseURL.path)
        defer { reader.release() }
        let outcome = await store.tombstone(chatID: "chat-commit-failure")
        guard case .failed = outcome else {
            return XCTFail("a tombstone whose transaction cannot commit must fail")
        }
        reader.release()

        await store.flush()
        let reopened = AcpTranscriptStore(databaseURL: databaseURL)
        let tombstoneState = await reopened.tombstoneState(chatID: "chat-commit-failure")
        XCTAssertEqual(tombstoneState, .absent)
        let restored = await reopened.rows(for: "chat-commit-failure")
        XCTAssertEqual(restored, buffered)
    }

    func testCommittedTombstoneStillDiscardsTheBufferedTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-tombstone-commit-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("transcripts-v2.sqlite3")

        let store = AcpTranscriptStore(databaseURL: databaseURL)
        let saved: [AcpTranscriptRow] = [.message(id: "1", text: "already durable")]
        await store.scheduleSave(saved, for: "chat-deleted", now: 1)
        await store.flush()

        await store.scheduleSave(
            saved + [.message(id: "2", text: "chunk landing as the user deletes")],
            for: "chat-deleted",
            now: 2
        )
        let outcome = await store.tombstone(chatID: "chat-deleted")
        XCTAssertNotNil(outcome.snapshot)
        await store.flush()

        let reopened = AcpTranscriptStore(databaseURL: databaseURL)
        let tombstoneState = await reopened.tombstoneState(chatID: "chat-deleted")
        XCTAssertEqual(tombstoneState, .present)
        let restored = await reopened.rows(for: "chat-deleted")
        XCTAssertEqual(restored, saved)
    }

    // MARK: - Typed read failures

    func testAbsentChatReadsAsMissingAndKeepsAcceptingWrites() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = await store.restoration(for: "chat-fresh", tailLimit: 120)
        XCTAssertEqual(outcome, .missing)
        let unreadable = await store.hasUnreadableHistory(chatID: "chat-fresh")
        XCTAssertFalse(unreadable)

        await store.scheduleSave([.message(id: "1", text: "first")], for: "chat-fresh", now: 1)
        await store.flush()
        let saved = await store.rows(for: "chat-fresh")
        XCTAssertEqual(saved, [.message(id: "1", text: "first")])
    }

    func testUnopenableDatabaseReadsAsUnavailableRatherThanAnEmptyChat() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-blocked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AcpTranscriptStore(fileURL: directory.appendingPathComponent("transcripts.json"))
        // A directory standing where the database file belongs is the
        // deterministic stand-in for a database this process cannot open.
        try FileManager.default.createDirectory(at: store.databaseURL, withIntermediateDirectories: true)

        let outcome = await store.restoration(for: "chat-blocked", tailLimit: 120)
        let failure = try XCTUnwrap(outcome.failure)
        XCTAssertEqual(failure.fault, .unavailable)
        XCTAssertNil(outcome.restoration)
        XCTAssertNotEqual(outcome, .missing)
        XCTAssertTrue(failure.guidance.contains(store.databaseURL.path))
    }

    func testCorruptRowReadsAsCorruptAndNeverReplacesTheStoredHistory() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = (0..<3).map { AcpTranscriptRow.message(id: "\($0)", text: "row \($0)") }
        await store.scheduleSave(rows, for: "chat-damaged", now: 1)
        await store.flush()
        let databaseURL = store.databaseURL
        try TranscriptDatabaseProbe.execute(
            """
            UPDATE transcript_rows SET row_json = X'6E6F70'
            WHERE chat_id = 'chat-damaged' AND ordinal = 2
            """,
            at: databaseURL
        )

        let relaunched = AcpTranscriptStore(
            fileURL: directory.appendingPathComponent("transcripts.json")
        )
        let outcome = await relaunched.restoration(for: "chat-damaged", tailLimit: 120)
        let failure = try XCTUnwrap(outcome.failure)
        XCTAssertEqual(failure.fault, .corrupt)
        XCTAssertEqual(failure.databasePath, databaseURL.path)
        XCTAssertTrue(failure.guidance.contains(databaseURL.path))
        let unreadable = await relaunched.hasUnreadableHistory(chatID: "chat-damaged")
        XCTAssertTrue(unreadable)

        // The empty transcript that failed read produced must not come back as
        // a whole-history write over the three rows still on disk.
        await relaunched.scheduleSave(
            [.message(id: "replacement", text: "fresh turn")],
            for: "chat-damaged",
            now: 2
        )
        await relaunched.scheduleDraft("", for: "chat-damaged", now: 3)
        await relaunched.scheduleSessionID(nil, for: "chat-damaged", now: 4)
        await relaunched.flush()
        XCTAssertEqual(
            try TranscriptDatabaseProbe.rowCount(chatID: "chat-damaged", at: databaseURL),
            3
        )
    }

    func testExplicitRemovalStillAppliesToAnUnreadableChat() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.scheduleSave(
            [.message(id: "1", text: "row"), .message(id: "2", text: "row")],
            for: "chat-doomed",
            now: 1
        )
        await store.flush()
        let databaseURL = store.databaseURL
        try TranscriptDatabaseProbe.execute(
            "UPDATE transcript_rows SET row_json = X'6E6F70' WHERE chat_id = 'chat-doomed'",
            at: databaseURL
        )

        let relaunched = AcpTranscriptStore(
            fileURL: directory.appendingPathComponent("transcripts.json")
        )
        let outcome = await relaunched.restoration(for: "chat-doomed", tailLimit: 120)
        XCTAssertNotNil(outcome.failure)
        await relaunched.remove(chatID: "chat-doomed")
        XCTAssertEqual(
            try TranscriptDatabaseProbe.rowCount(chatID: "chat-doomed", at: databaseURL),
            0
        )
        let stillRefusing = await relaunched.hasUnreadableHistory(chatID: "chat-doomed")
        XCTAssertFalse(stillRefusing)
    }

    // MARK: - Persistent write health

    func testFlushPublishesBoundedFailureAndKeepsExactRecoverySnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-health-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AcpTranscriptStore(
            databaseURL: directory.appendingPathComponent("transcripts.sqlite3"),
            schedulesAutomaticFlush: false,
            injectedFlushFailureCount: AcpTranscriptStore.maximumPersistenceAttempts
        )
        let updates = await store.persistenceHealthUpdates()
        let recorder = Task { () -> [AcpTranscriptStore.PersistenceHealthUpdate] in
            var recorded: [AcpTranscriptStore.PersistenceHealthUpdate] = []
            for await update in updates {
                recorded.append(update)
                if recorded.count == 4 { return recorded }
            }
            return recorded
        }
        let first = AcpTranscriptRow.user(id: "1", text: "keep me", failed: false)
        let newest = AcpTranscriptRow.message(id: "2", text: "newest exact snapshot")

        await store.scheduleSave([first], for: "chat-health", startOrdinal: 0, now: 1)
        await store.flush()
        let firstHealth = await store.persistenceHealth(for: "chat-health")
        XCTAssertEqual(
            firstHealth,
            .retrying(attempt: 1, maximumAttempts: AcpTranscriptStore.maximumPersistenceAttempts)
        )

        // A stream update during the retry window must replace the older
        // snapshot without resetting the bounded failure count.
        await store.scheduleSave([first, newest], for: "chat-health", startOrdinal: 0, now: 2)
        await store.flush()
        let secondHealth = await store.persistenceHealth(for: "chat-health")
        XCTAssertEqual(
            secondHealth,
            .retrying(attempt: 2, maximumAttempts: AcpTranscriptStore.maximumPersistenceAttempts)
        )
        await store.flush()

        let terminalHealth = await store.persistenceHealth(for: "chat-health")
        let failure = try XCTUnwrap(terminalHealth.failure)
        XCTAssertEqual(failure.attemptCount, AcpTranscriptStore.maximumPersistenceAttempts)
        XCTAssertEqual(failure.maximumAttempts, AcpTranscriptStore.maximumPersistenceAttempts)
        XCTAssertTrue(failure.guidance.contains("Retry"))
        XCTAssertTrue(failure.guidance.contains("export"))
        let snapshot = await store.recoverySnapshot(for: "chat-health")
        XCTAssertEqual(
            snapshot,
            AcpTranscriptStore.RecoverySnapshot(
                chatID: "chat-health",
                startOrdinal: 0,
                rows: [first, newest]
            )
        )

        // A lifecycle flush is not a hidden fourth retry. Only the explicit
        // recovery action re-arms the bounded circuit.
        await store.flush()
        let healthAfterExtraFlush = await store.persistenceHealth(for: "chat-health")
        let rowsAfterExtraFlush = await store.rows(for: "chat-health")
        XCTAssertNotNil(healthAfterExtraFlush.failure)
        XCTAssertTrue(rowsAfterExtraFlush.isEmpty)

        await store.retryPersistence(chatID: "chat-health")
        let recoveredHealth = await store.persistenceHealth(for: "chat-health")
        let recoveredRows = await store.rows(for: "chat-health")
        let recoveredSnapshot = await store.recoverySnapshot(for: "chat-health")
        XCTAssertEqual(recoveredHealth, .healthy)
        XCTAssertEqual(recoveredRows, [first, newest])
        XCTAssertNil(recoveredSnapshot)

        let recorded = await recorder.value
        XCTAssertEqual(recorded.map(\.chatID), Array(repeating: "chat-health", count: 4))
        XCTAssertEqual(
            recorded.map(\.health),
            [
                .retrying(attempt: 1, maximumAttempts: 3),
                .retrying(attempt: 2, maximumAttempts: 3),
                .failed(failure),
                .healthy,
            ]
        )
    }

    func testRecoveryExportRoundTripsRowsAndDisclosesPartialSnapshot() throws {
        let rows: [AcpTranscriptRow] = [
            .user(id: "1", text: "question", failed: false),
            .message(id: "2", text: "answer"),
        ]
        let data = try AcpTranscriptRecoveryExport.data(
            title: "Agent / Project",
            startOrdinal: 75,
            rows: rows
        )
        let decoded = try JSONDecoder().decode(AcpTranscriptRecoveryExport.Document.self, from: data)

        XCTAssertEqual(decoded.title, "Agent / Project")
        XCTAssertEqual(decoded.startOrdinal, 75)
        XCTAssertEqual(decoded.rows, rows)
        XCTAssertFalse(decoded.isCompleteTranscript)
        XCTAssertEqual(
            AcpTranscriptRecoveryExport.suggestedFileName(for: "Agent / Project"),
            "agent-project-transcript-recovery.json"
        )
    }

    func testMarkdownFormatterPreservesVisibleMarkdownAndOmitsPrivateArtifacts() throws {
        let rows: [AcpTranscriptRow] = [
            .user(
                id: "1",
                text: "Please review:\n```swift\nlet answer = 42\n```\n📎 screenshot.png",
                failed: false
            ),
            .message(id: "2", text: "Done.\n\n```diff\n-old\n+new\n```"),
            .thought(id: "3", text: "HIDDEN_REASONING_SECRET"),
            .tool(AcpToolCall(
                id: "tool-1",
                title: "Read config",
                kind: "read",
                status: .completed,
                content: [
                    .text("API_KEY=TOOL_RESULT_SECRET"),
                    .diff(path: "secrets.env", oldText: "OLD_SECRET", newText: "NEW_SECRET"),
                    .terminal(id: "terminal-secret"),
                ],
                locations: ["/private/secret/path"]
            )),
            .plan(id: "plan-1", entries: [
                .init(id: "step-1", content: "Ship it", priority: "high", status: "completed"),
            ]),
            .permissionDecision(id: "permission-1", text: "EPHEMERAL_PERMISSION_SECRET"),
        ]
        let markdown = AcpTranscriptMarkdownExport.markdown(
            request: .init(
                title: "Agent / Project",
                agentID: "test-agent",
                agentName: "Test Agent",
                modelID: "model-1",
                exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            updatedAt: Date(timeIntervalSince1970: 1_690_000_000),
            startOrdinal: 0,
            rows: rows,
            attachments: [
                .image(
                    data: Data("BINARY_ATTACHMENT_SECRET".utf8),
                    mimeType: "image/png",
                    name: "screenshot.png"
                ),
                .textFile(
                    path: "/private/notes.txt",
                    contents: "TEXT_ATTACHMENT_SECRET",
                    name: "notes.txt"
                ),
            ],
            retentionStatus: .init(truncatedRowCount: 3, truncatedByteCount: 256)
        )

        XCTAssertTrue(markdown.contains("# Agent / Project"))
        XCTAssertTrue(markdown.contains("- Exported: 2023-11-14T22:13:20Z"))
        XCTAssertTrue(markdown.contains("- Agent: Test Agent (test-agent)"))
        XCTAssertTrue(markdown.contains("- Model: model-1"))
        XCTAssertTrue(markdown.contains("```swift\nlet answer = 42\n```"))
        XCTAssertTrue(markdown.contains("```diff\n-old\n+new\n```"))
        XCTAssertTrue(markdown.contains("- Tool: Read config"))
        XCTAssertTrue(markdown.contains("- Result artifacts omitted: 1 text block, 1 diff, 1 terminal"))
        XCTAssertTrue(markdown.contains("- [x] Ship it (high; completed)"))
        XCTAssertTrue(markdown.contains("[Binary image omitted: screenshot.png (image/png)]"))
        XCTAssertTrue(markdown.contains("[Embedded text attachment omitted: notes.txt]"))
        XCTAssertTrue(markdown.contains("[Attachment payload omitted; the transcript retains filename(s) only]"))
        XCTAssertTrue(markdown.contains("[1 hidden reasoning row omitted]"))
        XCTAssertTrue(markdown.contains("[Earlier retained history truncated: 3 rows, 256 bytes]"))
        XCTAssertFalse(markdown.contains("HIDDEN_REASONING_SECRET"))
        XCTAssertFalse(markdown.contains("TOOL_RESULT_SECRET"))
        XCTAssertFalse(markdown.contains("OLD_SECRET"))
        XCTAssertFalse(markdown.contains("NEW_SECRET"))
        XCTAssertFalse(markdown.contains("terminal-secret"))
        XCTAssertFalse(markdown.contains("/private/secret/path"))
        XCTAssertFalse(markdown.contains("BINARY_ATTACHMENT_SECRET"))
        XCTAssertFalse(markdown.contains("TEXT_ATTACHMENT_SECRET"))
        XCTAssertFalse(markdown.contains("EPHEMERAL_PERMISSION_SECRET"))
        XCTAssertEqual(
            AcpTranscriptMarkdownExport.lastAssistantResponse(in: rows),
            "Done.\n\n```diff\n-old\n+new\n```"
        )
        XCTAssertEqual(
            AcpTranscriptMarkdownExport.suggestedFileName(for: "Agent / Project"),
            "agent-project-transcript.md"
        )
    }

    func testMarkdownExportReadsTheCompletePagedTranscriptDirectlyToDisk() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = (0 ..< 250).map { AcpTranscriptRow.message(id: "\($0)", text: "response-\($0)") }
        await store.scheduleSave(rows, for: "chat-export", now: 1_700_000_000)
        await store.scheduleAttachments([
            .image(data: Data([0, 1, 2]), mimeType: "image/png", name: "diagram.png"),
        ], for: "chat-export", now: 1_700_000_001)
        await store.flush()

        let restorationOutcome = await store.restoration(for: "chat-export", tailLimit: 20)
        let restoration = try XCTUnwrap(restorationOutcome.restoration)
        XCTAssertEqual(restoration.page.rows.count, 20)
        XCTAssertEqual(restoration.page.earlierRowCount, 230)

        let destination = directory.appendingPathComponent("complete.md")
        let receipt = try await store.exportMarkdown(
            for: "chat-export",
            request: .init(
                title: "Paged chat",
                agentID: "codex",
                agentName: "Codex",
                modelID: "gpt-test",
                exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
            ),
            to: destination
        )
        let markdown = try String(contentsOf: destination, encoding: .utf8)
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int

        XCTAssertEqual(receipt.rowCount, 250)
        XCTAssertEqual(receipt.startOrdinal, 0)
        XCTAssertFalse(receipt.includedPendingChanges)
        XCTAssertTrue(markdown.contains("response-0"))
        XCTAssertTrue(markdown.contains("response-249"))
        XCTAssertTrue(markdown.contains("[Binary image omitted: diagram.png (image/png)]"))
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
    }

    func testMarkdownExportIncludesTheExactTerminalFailureSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-export-health-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AcpTranscriptStore(
            databaseURL: directory.appendingPathComponent("transcripts.sqlite3"),
            schedulesAutomaticFlush: false,
            injectedFlushFailureCount: AcpTranscriptStore.maximumPersistenceAttempts
        )
        let rows: [AcpTranscriptRow] = [
            .user(id: "1", text: "question", failed: false),
            .message(id: "2", text: "newest unsaved response"),
        ]
        await store.scheduleSave(rows, for: "chat-failed", startOrdinal: 0, now: 12)
        await store.flush()
        let retryingHealth = await store.persistenceHealth(for: "chat-failed")
        XCTAssertEqual(
            retryingHealth,
            .retrying(attempt: 1, maximumAttempts: AcpTranscriptStore.maximumPersistenceAttempts)
        )
        let retryingDestination = directory.appendingPathComponent("retrying.md")
        _ = try await store.exportMarkdown(
            for: "chat-failed",
            request: .init(
                title: "Unsaved chat",
                agentID: "claude",
                agentName: "Claude",
                modelID: nil,
                exportedAt: Date(timeIntervalSince1970: 19)
            ),
            to: retryingDestination
        )
        let healthAfterRetryingExport = await store.persistenceHealth(for: "chat-failed")
        XCTAssertEqual(
            healthAfterRetryingExport,
            retryingHealth,
            "export must not consume an automatic persistence retry"
        )
        for _ in 1 ..< AcpTranscriptStore.maximumPersistenceAttempts { await store.flush() }
        let failedHealth = await store.persistenceHealth(for: "chat-failed")
        XCTAssertNotNil(failedHealth.failure)

        let destination = directory.appendingPathComponent("recovery.md")
        let receipt = try await store.exportMarkdown(
            for: "chat-failed",
            request: .init(
                title: "Unsaved chat",
                agentID: "claude",
                agentName: "Claude",
                modelID: nil,
                exportedAt: Date(timeIntervalSince1970: 20)
            ),
            to: destination
        )
        let markdown = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertTrue(receipt.includedPendingChanges)
        XCTAssertEqual(receipt.rowCount, 2)
        XCTAssertTrue(markdown.contains("question"))
        XCTAssertTrue(markdown.contains("newest unsaved response"))
        let healthAfterExport = await store.persistenceHealth(for: "chat-failed")
        XCTAssertNotNil(healthAfterExport.failure)
    }
}

// MARK: - Copying a whole message (2026-08-28)

extension AcpTranscriptStoreTests {
    /// "Users should be able to highlight and copy text from agent chat
    /// sessions." Highlighting reaches one paragraph and stops — SwiftUI
    /// selection cannot cross two `Text` views, and a rendered answer is one
    /// per block — so every prose row also offers itself whole.
    func testProseRowsOfferTheirWholeTextAndEvidenceRowsDoNot() {
        XCTAssertEqual(
            AcpTranscriptRow.message(id: "1", text: "First.\n\nSecond.").copyableText,
            "First.\n\nSecond.",
            "an answer copies across the paragraph break highlighting cannot cross"
        )
        XCTAssertEqual(
            AcpTranscriptRow.thought(id: "2", text: "reasoning").copyableText,
            "reasoning"
        )
        XCTAssertEqual(
            AcpTranscriptRow.permissionDecision(id: "3", text: "denied").copyableText,
            "denied"
        )

        // The markdown is copied, not the rendered attributed text, so a
        // pasted code fence is still a code fence.
        let fenced = "Here:\n\n```swift\nlet x = 1\n```"
        XCTAssertEqual(AcpTranscriptRow.message(id: "4", text: fenced).copyableText, fenced)

        // A user prompt copies what the bubble showed: the pinned trailing
        // attachment line is parsed back out, not pasted.
        let prompted = AcpTranscriptRow.user(id: "5", text: "look at this", failed: false)
        XCTAssertEqual(prompted.copyableText, "look at this")

        // Evidence rows keep their own affordances; flattening them would
        // paste something that was never on screen.
        XCTAssertNil(AcpTranscriptRow.plan(id: "6", entries: []).copyableText)
        XCTAssertNil(
            AcpTranscriptRow.message(id: "7", text: "").copyableText,
            "an empty row offers nothing to copy"
        )
    }
}
