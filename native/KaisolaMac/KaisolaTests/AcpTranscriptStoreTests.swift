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
            XCTAssertEqual(retry, .recorded)
            let removal = await store.remove(chatID: chatID)
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
            XCTAssertEqual(tombstoneResult, .recorded)
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
        await relaunched.vacuumTombstones()

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
            0,
            "Only a completed physical deletion may vacuum its tombstone"
        )
        XCTAssertNil(
            try Data(contentsOf: databaseURL).range(of: secretMarkerData),
            "Launch recovery must overwrite deleted transcript and draft content in SQLite pages"
        )
        let restored = await relaunched.entry(for: chatID)
        XCTAssertNil(restored)
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
        XCTAssertEqual(tombstoneResult, .recorded)
        await writerA.remove(chatID: chatID)
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
        XCTAssertEqual(tombstoneResult, .recorded)
        await writerA.remove(chatID: chatID)

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

        await store.remove(chatID: "closed")
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
        XCTAssertEqual(tombstoneResult, .recorded)
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
        XCTAssertEqual(tombstoneResult, .recorded)
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
        XCTAssertEqual(tombstoneResult, .recorded)

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
        sqlite3_close_v2(side)
        await store.flush()
        let restored = await store.rows(for: "chat-probe")
        XCTAssertEqual(restored, rows)
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
}
