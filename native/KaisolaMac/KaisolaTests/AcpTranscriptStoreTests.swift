import Foundation
import SQLite3
import XCTest
@testable import Kaisola

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

        let restoration = await store.restoration(for: "chat-pages", tailLimit: 120)
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

        let restoration = await store.restoration(for: "chat-clamp", tailLimit: 50_000)
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
        let restoration = await store.restoration(for: "chat-tail", tailLimit: 120)
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
        let restoration = await reopened.restoration(for: "chat-metadata", tailLimit: 120)
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
        let clearedRestoration = await reopened.restoration(for: "chat-metadata", tailLimit: 120)
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
        let restoration = await store.restoration(for: "legacy-chat", tailLimit: 2)
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

        let failedRestoration = await store.restoration(for: "retry-chat", tailLimit: 120)
        XCTAssertNil(failedRestoration)
        XCTAssertEqual(try Data(contentsOf: legacyURL), corruptBytes)

        let rows: [AcpTranscriptRow] = [.message(id: "1", text: "recovered source")]
        let repaired = LegacyPayload(entries: [
            "retry-chat": AcpTranscriptStore.Entry(rows: rows, updatedAt: 1),
        ])
        try JSONEncoder().encode(repaired).write(to: legacyURL, options: .atomic)
        let restoration = await store.restoration(for: "retry-chat", tailLimit: 120)
        let restored = try XCTUnwrap(restoration)
        XCTAssertEqual(restored.page.rows, rows)
    }

    func testLateLegacySourceImportsWhenV2WasOnlyPrecreatedAndNeverWritten() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-late-v1-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appendingPathComponent("transcripts.json")

        let precreated = AcpTranscriptStore(fileURL: legacyURL)
        let absent = await precreated.restoration(for: "late-chat", tailLimit: 120)
        XCTAssertNil(absent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: precreated.databaseURL.path))

        let rows: [AcpTranscriptRow] = [.message(id: "1", text: "final v1 write")]
        let payload = LegacyPayload(entries: [
            "late-chat": AcpTranscriptStore.Entry(rows: rows, updatedAt: 2),
        ])
        try JSONEncoder().encode(payload).write(to: legacyURL, options: .atomic)

        let relaunched = AcpTranscriptStore(fileURL: legacyURL)
        let restoration = await relaunched.restoration(for: "late-chat", tailLimit: 120)
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
        XCTAssertEqual(outcome, .recorded)
        await store.flush()

        let reopened = AcpTranscriptStore(databaseURL: databaseURL)
        let tombstoneState = await reopened.tombstoneState(chatID: "chat-deleted")
        XCTAssertEqual(tombstoneState, .present)
        let restored = await reopened.rows(for: "chat-deleted")
        XCTAssertEqual(restored, saved)
    }
}
