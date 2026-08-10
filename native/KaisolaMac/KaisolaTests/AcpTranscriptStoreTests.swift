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

    func testRemoveClearsDurableTranscript() async {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.scheduleSave([.message(id: "1", text: "saved")], for: "chat-remove", now: 1)
        await store.flush()
        await store.remove(chatID: "chat-remove")
        let restoredRows = await store.rows(for: "chat-remove")
        XCTAssertTrue(restoredRows.isEmpty)
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("transcripts-v2.sqlite3")
        // A directory standing where the database file belongs fails the leaf
        // check on every open, so the tombstone throws before it writes.
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)

        let store = AcpTranscriptStore(databaseURL: databaseURL)
        let buffered: [AcpTranscriptRow] = [
            .user(id: "1", text: "delete me", failed: false),
            .message(id: "1", text: "newest buffered tail"),
        ]
        await store.scheduleSave(buffered, for: "chat-open-failure", now: 1)

        do {
            try await store.tombstone(chatID: "chat-open-failure")
            XCTFail("a tombstone that cannot open the database must throw")
        } catch {}

        try FileManager.default.removeItem(at: databaseURL)
        await store.flush()

        let reopened = AcpTranscriptStore(databaseURL: databaseURL)
        let tombstoned = await reopened.isTombstoned(chatID: "chat-open-failure")
        XCTAssertFalse(tombstoned)
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

        let reader = try SQLiteReadLock(path: databaseURL.path)
        defer { reader.release() }

        let buffered = saved + [.message(id: "2", text: "newest buffered tail")]
        await store.scheduleSave(buffered, for: "chat-commit-failure", now: 2)
        do {
            try await store.tombstone(chatID: "chat-commit-failure")
            XCTFail("a tombstone whose transaction cannot commit must throw")
        } catch {}
        reader.release()

        await store.flush()
        let reopened = AcpTranscriptStore(databaseURL: databaseURL)
        let tombstoned = await reopened.isTombstoned(chatID: "chat-commit-failure")
        XCTAssertFalse(tombstoned)
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
        try await store.tombstone(chatID: "chat-deleted")
        await store.flush()

        let reopened = AcpTranscriptStore(databaseURL: databaseURL)
        let tombstoned = await reopened.isTombstoned(chatID: "chat-deleted")
        XCTAssertTrue(tombstoned)
        let restored = await reopened.rows(for: "chat-deleted")
        XCTAssertEqual(restored, saved)
    }
}
