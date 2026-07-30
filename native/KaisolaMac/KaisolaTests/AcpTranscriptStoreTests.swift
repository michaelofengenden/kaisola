import XCTest
@testable import Kaisola

final class AcpTranscriptStoreTests: XCTestCase {
    private func temporaryStore() -> (AcpTranscriptStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-\(UUID().uuidString)", isDirectory: true)
        return (AcpTranscriptStore(fileURL: directory.appendingPathComponent("transcripts.json")), directory)
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
}
