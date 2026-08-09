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
}
