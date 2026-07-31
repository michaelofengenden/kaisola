import Foundation
import XCTest
@testable import Kaisola

/// Unit tests for two Electron-parity behaviors on `AcpConversation` that need
/// no live agent: transcript render-window paging (`visibleRows`/`expandEarlier`)
/// and per-chat persistent composer drafts (`loadDraft`/`saveDraft` round-trip).
/// Both exercise pure logic through the conversation's public API plus the
/// `seedRowsForTesting` hook — no scripted transport or spawned process.
@MainActor
final class AcpTranscriptPagingTests: XCTestCase {

    private func makeConversation(draftKey: String? = nil) -> AcpConversation {
        AcpConversation(
            title: "Test",
            command: "mock",
            arguments: [],
            cwd: "/tmp",
            draftKey: draftKey
        )
    }

    // MARK: - Transcript paging

    func testRendersOnlyTailByDefault() {
        let conversation = makeConversation()
        conversation.seedRowsForTesting(Self.messageRows(count: 500))

        // Full history is retained; only the last N=120 rows render.
        XCTAssertEqual(conversation.rows.count, 500)
        XCTAssertEqual(conversation.visibleLimit, AcpConversation.defaultVisibleLimit)
        XCTAssertEqual(conversation.visibleRows.count, 120)
        XCTAssertEqual(conversation.hiddenEarlierCount, 380)

        // The rendered rows are the TAIL of history (last 120), in order.
        XCTAssertEqual(conversation.visibleRows.first?.id, conversation.rows[380].id)
        XCTAssertEqual(conversation.visibleRows.last?.id, conversation.rows.last?.id)
    }

    func testExpandEarlierGrowsWindowByStep() {
        let conversation = makeConversation()
        conversation.seedRowsForTesting(Self.messageRows(count: 500))

        conversation.expandEarlier()   // +200
        XCTAssertEqual(conversation.visibleRows.count, 320)
        XCTAssertEqual(conversation.hiddenEarlierCount, 180)

        conversation.expandEarlier()   // +200 more, clamps to all rows
        XCTAssertEqual(conversation.visibleRows.count, 500)
        XCTAssertEqual(conversation.hiddenEarlierCount, 0, "no hidden rows ⇒ the button disappears")
    }

    func testShortTranscriptShowsEverythingAndHidesButton() {
        let conversation = makeConversation()
        conversation.seedRowsForTesting(Self.messageRows(count: 40))

        XCTAssertEqual(conversation.visibleRows.count, 40)
        XCTAssertEqual(conversation.hiddenEarlierCount, 0)
    }

    func testVisibleLimitIsSettableToDriveTheView() {
        let conversation = makeConversation()
        conversation.seedRowsForTesting(Self.messageRows(count: 500))

        conversation.visibleLimit = 200
        XCTAssertEqual(conversation.visibleRows.count, 200)
        XCTAssertEqual(conversation.hiddenEarlierCount, 300)
    }

    func testRepeatedTopPagingReachesTheLiteralFirstMessage() {
        let conversation = makeConversation()
        conversation.seedRowsForTesting(Self.messageRows(count: 10_003))

        var pageCount = 0
        while conversation.hiddenEarlierCount > 0 {
            let previousHidden = conversation.hiddenEarlierCount
            conversation.expandEarlier()
            XCTAssertLessThan(conversation.hiddenEarlierCount, previousHidden)
            pageCount += 1
            XCTAssertLessThan(pageCount, 100, "Paging must make bounded forward progress")
        }

        XCTAssertEqual(conversation.visibleRows.count, 10_003)
        XCTAssertEqual(conversation.visibleRows.first?.id, "msg-m0")
        XCTAssertEqual(conversation.visibleRows.last?.id, "msg-m10002")
    }

    func testStreamingContentVersionAdvancesWithoutGrowingRowCount() {
        let conversation = makeConversation()
        conversation.receiveTurnItemForTesting(.message(id: "wire-1", text: "Hello"))
        let rowCount = conversation.rows.count
        let version = conversation.contentVersion

        conversation.receiveTurnItemForTesting(.message(id: "wire-2", text: " world"))

        XCTAssertEqual(conversation.rows.count, rowCount)
        XCTAssertGreaterThan(conversation.contentVersion, version)
        guard case let .message(_, text) = conversation.rows.first else {
            return XCTFail("Expected one accumulated assistant row")
        }
        XCTAssertEqual(text, "Hello world")
    }

    func testNonContiguousSegmentsWithinOneTurnHaveUniqueRowIDs() {
        let conversation = makeConversation()
        conversation.receiveTurnItemForTesting(.message(id: "wire-1", text: "Before"))
        conversation.receiveTurnItemForTesting(.toolCall(AcpToolCall(
            id: "tool-1",
            title: "Read file",
            kind: "read",
            status: .completed
        )))
        conversation.receiveTurnItemForTesting(.message(id: "wire-2", text: "After"))

        let ids = conversation.rows.map(\.id)
        XCTAssertEqual(conversation.rows.count, 3)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(conversation.rows.compactMap {
            if case let .message(_, text) = $0 { return text }
            return nil
        }, ["Before", "After"])
    }

    func testPermissionRequestsArePresentedFIFO() {
        let ruleDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-permission-fifo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ruleDirectory) }
        let conversation = AcpConversation(
            title: "Test",
            command: "mock",
            arguments: [],
            cwd: "/tmp",
            ruleStore: PermissionRuleStore(fileURL: ruleDirectory.appendingPathComponent("rules.json")),
            sensitiveGlobs: []
        )
        let options = [
            AcpPermissionRequest.Option(id: "allow", name: "Allow", kind: "allow_once"),
            AcpPermissionRequest.Option(id: "reject", name: "Reject", kind: "reject_once"),
        ]
        let first = AcpPermissionRequest(
            id: 1, sessionID: "session", title: "First", options: options
        )
        let second = AcpPermissionRequest(
            id: 2, sessionID: "session", title: "Second", options: options
        )

        conversation.receivePermissionForTesting(first)
        conversation.receivePermissionForTesting(second)
        XCTAssertEqual(conversation.pendingPermission?.id, first.id)
        XCTAssertEqual(conversation.pendingPermissionCount, 2)

        conversation.answerPermission("allow")
        XCTAssertEqual(conversation.pendingPermission?.id, second.id)
        XCTAssertEqual(conversation.pendingPermissionCount, 1)

        conversation.answerPermission("reject")
        XCTAssertNil(conversation.pendingPermission)
        XCTAssertEqual(conversation.pendingPermissionCount, 0)
    }

    func testDisconnectedSendDoesNotConsumeAuthoredText() {
        let conversation = makeConversation()

        XCTAssertFalse(conversation.send("keep this draft"))
        XCTAssertTrue(conversation.rows.isEmpty)
    }

    func testVisibleRenderingBudgetsBoundCharactersAndLines() {
        let characterBound = AcpChatRendering.bounded(
            "0123456789",
            characterLimit: 5,
            lineLimit: 10
        )
        XCTAssertEqual(characterBound.text, "01234")
        XCTAssertTrue(characterBound.isTruncated)

        let lineBound = AcpChatRendering.bounded(
            "one\ntwo\nthree\nfour",
            characterLimit: 100,
            lineLimit: 2
        )
        XCTAssertEqual(lineBound.text, "one\ntwo")
        XCTAssertTrue(lineBound.isTruncated)

        let untouched = AcpChatRendering.bounded(
            "short",
            characterLimit: 100,
            lineLimit: 10
        )
        XCTAssertEqual(untouched, AcpBoundedText(text: "short", isTruncated: false))
    }

    // MARK: - Persistent drafts

    func testDraftRoundTripsThroughUserDefaults() {
        let key = "unit-\(UUID().uuidString)"
        let defaultsKey = "chatDraft.\(key)"
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let conversation = makeConversation(draftKey: key)
        XCTAssertEqual(conversation.loadDraft(), "", "no draft persisted yet")

        conversation.saveDraft("half-written thought")
        XCTAssertEqual(UserDefaults.standard.string(forKey: defaultsKey), "half-written thought")

        // A fresh conversation with the same key recovers the draft (relaunch).
        let reopened = makeConversation(draftKey: key)
        XCTAssertEqual(reopened.loadDraft(), "half-written thought")
    }

    func testEmptyDraftRemovesTheStoredKey() {
        let key = "unit-\(UUID().uuidString)"
        let defaultsKey = "chatDraft.\(key)"
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let conversation = makeConversation(draftKey: key)
        conversation.saveDraft("something")
        XCTAssertNotNil(UserDefaults.standard.string(forKey: defaultsKey))

        conversation.saveDraft("")
        XCTAssertNil(UserDefaults.standard.string(forKey: defaultsKey), "clearing the draft deletes the key")
    }

    func testDraftIsNoOpWithoutAKey() {
        let conversation = makeConversation(draftKey: nil)
        conversation.saveDraft("orphan")   // no key ⇒ nothing persisted
        XCTAssertEqual(conversation.loadDraft(), "", "unkeyed chats never persist a draft")
    }

    // MARK: - Fixtures

    private static func messageRows(count: Int) -> [AcpTranscriptRow] {
        (0..<count).map { .message(id: "m\($0)", text: "row \($0)") }
    }
}
