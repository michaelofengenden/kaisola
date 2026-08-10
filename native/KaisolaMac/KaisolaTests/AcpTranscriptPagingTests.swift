import AppKit
import Foundation
import KaisolaCore
import SwiftUI
import XCTest
@testable import Kaisola

private actor TranscriptPageFixture {
    let rows: [AcpTranscriptRow]
    private(set) var requests: [(before: Int64, limit: Int)] = []

    init(rows: [AcpTranscriptRow]) { self.rows = rows }

    func page(before: Int64, limit: Int) -> AcpTranscriptStore.Page {
        requests.append((before, limit))
        let end = max(0, min(rows.count, Int(before)))
        let start = max(0, end - limit)
        return AcpTranscriptStore.Page(
            rows: Array(rows[start..<end]),
            startOrdinal: Int64(start),
            endOrdinalExclusive: Int64(end),
            earlierRowCount: start,
            totalRowCount: rows.count
        )
    }

    func requestCount() -> Int { requests.count }
}

@MainActor
private final class TranscriptViewportFixtureModel: ObservableObject {
    @Published var rowIDs: [String]
    @Published var rowHeight: CGFloat = 72

    init(rowIDs: [String]) {
        self.rowIDs = rowIDs
    }
}

@MainActor
private struct TranscriptViewportFixtureView: View {
    @ObservedObject var model: TranscriptViewportFixtureModel
    let anchor: AcpTranscriptViewportAnchor

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.rowIDs, id: \.self) { rowID in
                    Text(rowID)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: model.rowHeight,
                            maxHeight: model.rowHeight
                        )
                        .background {
                            AcpTranscriptViewportMarker(rowID: rowID, anchor: anchor)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .accessibilityIdentifier("fixture.\(rowID)")
                }
            }
            .padding(12)
        }
    }
}

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

    private func makePermissionConversation() -> AcpConversation {
        AcpConversation(
            title: "Permission test",
            command: "mock",
            arguments: [],
            cwd: "/tmp",
            ruleStore: PermissionRuleStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("kaisola-permission-\(UUID().uuidString).json")),
            sensitiveGlobs: []
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

    func testExpandEarlierGrowsWindowByStep() async {
        let conversation = makeConversation()
        conversation.seedRowsForTesting(Self.messageRows(count: 500))

        await conversation.expandEarlier()   // +200
        XCTAssertEqual(conversation.visibleRows.count, 320)
        XCTAssertEqual(conversation.hiddenEarlierCount, 180)

        await conversation.expandEarlier()   // +200 more, clamps to all rows
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

    func testRepeatedTopPagingReachesTheLiteralFirstMessage() async {
        let conversation = makeConversation()
        conversation.seedRowsForTesting(Self.messageRows(count: 10_003))

        var pageCount = 0
        while conversation.hiddenEarlierCount > 0 {
            let previousHidden = conversation.hiddenEarlierCount
            await conversation.expandEarlier()
            XCTAssertLessThan(conversation.hiddenEarlierCount, previousHidden)
            pageCount += 1
            XCTAssertLessThan(pageCount, 100, "Paging must make bounded forward progress")
        }

        XCTAssertEqual(conversation.visibleRows.count, 10_003)
        XCTAssertEqual(conversation.visibleRows.first?.id, "msg-m0")
        XCTAssertEqual(conversation.visibleRows.last?.id, "msg-m10002")
    }

    func testPageBackedExpansionLoadsToTheFirstRowWithoutRepersistingHistory() async throws {
        let allRows = Self.messageRows(count: 1_003)
        let fixture = TranscriptPageFixture(rows: allRows)
        let tailStart = allRows.count - AcpConversation.defaultVisibleLimit
        let conversation = AcpConversation(
            title: "Paged",
            command: "mock",
            arguments: [],
            cwd: "/tmp",
            initialRows: Array(allRows[tailStart...]),
            initialRowStartOrdinal: Int64(tailStart),
            initialEarlierRowCount: tailStart,
            initialTotalRowCount: allRows.count
        )
        var persistenceEvents = 0
        conversation.onTranscriptChanged = { _, _ in persistenceEvents += 1 }
        conversation.loadEarlierRows = { before, limit in
            await fixture.page(before: before, limit: limit)
        }

        while conversation.hiddenEarlierCount > 0 {
            let anchor = try XCTUnwrap(conversation.visibleRows.first?.id)
            let previousCount = conversation.rows.count
            await conversation.expandEarlier()
            XCTAssertGreaterThan(conversation.rows.count, previousCount)
            XCTAssertTrue(conversation.visibleRows.contains(where: { $0.id == anchor }))
            XCTAssertEqual(
                conversation.lastHistoryInsertionContentVersion,
                conversation.contentVersion,
                "A durable prepend must bypass live-output bottom following"
            )
        }

        XCTAssertEqual(conversation.rows, allRows)
        XCTAssertEqual(conversation.loadedRowStartOrdinal, 0)
        XCTAssertEqual(conversation.unloadedEarlierRowCount, 0)
        XCTAssertEqual(persistenceEvents, 0, "Reading durable pages must not schedule redundant writes")
        let requestCount = await fixture.requestCount()
        XCTAssertEqual(requestCount, 5)
    }

    func testTranscriptSearchCountsVisibleOccurrencesAndNavigatesInOrder() {
        let rows: [AcpTranscriptRow] = [
            .user(id: "u", text: "Needle once", failed: false),
            .message(id: "m", text: "needle twice NEEDLE"),
            .plan(id: "p", entries: [
                AcpPlanEntry(id: "e", content: "No match", priority: "medium", status: "pending"),
            ]),
        ]
        var state = AcpTranscriptSearchState()

        state.updateQuery("needle", rows: rows)

        XCTAssertEqual(state.matchCount, 3)
        XCTAssertNil(state.currentRowID, "typing must not jump the reading anchor")
        XCTAssertEqual(state.statusText(hasHiddenEarlierRows: false), "3 matches")
        XCTAssertEqual(state.move(.next), "user-u")
        XCTAssertEqual(state.statusText(hasHiddenEarlierRows: false), "1 of 3")
        XCTAssertEqual(state.move(.next), "msg-m")
        XCTAssertEqual(state.move(.next), "msg-m")
        XCTAssertEqual(state.move(.next), "user-u", "next wraps")
        XCTAssertEqual(state.move(.previous), "msg-m", "previous wraps")
    }

    func testTranscriptSearchRefreshPreservesSelectionDuringStreaming() {
        var state = AcpTranscriptSearchState()
        state.updateQuery("ship", rows: [
            .message(id: "one", text: "ship it"),
            .message(id: "two", text: "waiting"),
        ])
        XCTAssertEqual(state.move(.next), "msg-one")

        state.refresh(rows: [
            .message(id: "one", text: "ship it"),
            .message(id: "two", text: "waiting, then ship"),
        ])

        XCTAssertEqual(state.matchCount, 2)
        XCTAssertEqual(state.currentRowID, "msg-one")
        XCTAssertEqual(state.statusText(hasHiddenEarlierRows: false), "1 of 2")
    }

    func testPagedTranscriptSearchFindsOlderRowsWithoutDiscardingReadingAnchor() async throws {
        var rows = Self.messageRows(count: 500)
        rows[0] = .message(id: "oldest", text: "the buried needle")
        let conversation = makeConversation()
        conversation.seedRowsForTesting(rows)
        let readingAnchor = try XCTUnwrap(conversation.visibleRows.first?.id)
        var search = AcpTranscriptSearchState()
        search.updateQuery("needle", rows: conversation.visibleRows)
        XCTAssertEqual(search.matchCount, 0)
        XCTAssertEqual(search.statusText(hasHiddenEarlierRows: true), "No matches loaded")

        while search.matchCount == 0, conversation.hiddenEarlierCount > 0 {
            await conversation.expandEarlier()
            search.refresh(rows: conversation.visibleRows)
            XCTAssertTrue(
                conversation.visibleRows.contains(where: { $0.id == readingAnchor }),
                "prepending a search page must keep the prior reading anchor addressable"
            )
        }

        XCTAssertEqual(search.matchCount, 1)
        XCTAssertEqual(search.statusText(hasHiddenEarlierRows: false), "1 match")
        XCTAssertNil(search.currentRowID, "fetching older matches does not move the viewport")
        XCTAssertEqual(search.move(.next), "msg-oldest")
    }

    func testMountedViewportAnchorPreservesExactReadingOffsetAcrossPrepend() throws {
        let originalRows = (0..<18).map { "row-\($0)" }
        let model = TranscriptViewportFixtureModel(rowIDs: originalRows)
        let anchor = AcpTranscriptViewportAnchor()
        let host = NSHostingView(
            rootView: TranscriptViewportFixtureView(model: model, anchor: anchor)
                .frame(width: 360, height: 240)
        )
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let positioned = try XCTUnwrap(anchor.restore(.init(
            rowID: "row-2",
            offsetFromViewportTop: -17.25
        )))
        XCTAssertEqual(positioned.restoredOffset, -17.25, accuracy: 0.75)
        let captured = try XCTUnwrap(anchor.capture())
        XCTAssertEqual(captured.rowID, "row-2")
        XCTAssertEqual(captured.offsetFromViewportTop, -17.25, accuracy: 0.75)

        let scrollView = try XCTUnwrap(Self.firstScrollView(in: host))
        model.rowIDs = (0..<200).map { "earlier-\($0)" } + originalRows
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let originBeforeFallback = scrollView.contentView.bounds.origin.y
        var restored = anchor.restore(captured)
        let originAfterFallback = scrollView.contentView.bounds.origin.y
        if restored == nil {
            // The first call applies the captured clip-geometry fallback when
            // LazyVStack evicts the row; the next mounted pass must validate
            // the same row's real intra-row offset.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            restored = anchor.restore(captured)
        }
        guard let finalRestoration = restored else {
            XCTFail(
                "clip origin \(originBeforeFallback) -> \(originAfterFallback); "
                    + "document=\(String(describing: scrollView.documentView?.bounds)) "
                    + "viewport=\(scrollView.documentVisibleRect)"
            )
            return
        }
        XCTAssertEqual(finalRestoration.rowID, "row-2")
        XCTAssertEqual(
            finalRestoration.restoredOffset,
            captured.offsetFromViewportTop,
            accuracy: 0.75
        )
        XCTAssertLessThanOrEqual(finalRestoration.error, 0.75)
    }

    func testMountedViewportAnchorPreservesExactReadingOffsetAcrossRowHeightChange() throws {
        let model = TranscriptViewportFixtureModel(
            rowIDs: (0..<18).map { "density-row-\($0)" }
        )
        let anchor = AcpTranscriptViewportAnchor()
        let host = NSHostingView(
            rootView: TranscriptViewportFixtureView(model: model, anchor: anchor)
                .frame(width: 360, height: 240)
        )
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let positioned = try XCTUnwrap(anchor.restore(.init(
            rowID: "density-row-2",
            offsetFromViewportTop: -13.5
        )))
        XCTAssertEqual(positioned.restoredOffset, -13.5, accuracy: 0.75)
        let captured = try XCTUnwrap(anchor.capture())
        XCTAssertEqual(captured.rowID, "density-row-2")

        let scrollView = try XCTUnwrap(Self.firstScrollView(in: host))
        let documentHeightBefore = try XCTUnwrap(scrollView.documentView).bounds.height
        model.rowHeight = 118
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        XCTAssertGreaterThan(
            try XCTUnwrap(scrollView.documentView).bounds.height,
            documentHeightBefore,
            "the mounted contract must exercise a real document-height change"
        )

        var restoration = anchor.restore(captured)
        if restoration == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            restoration = anchor.restore(captured)
        }
        let finalRestoration = try XCTUnwrap(restoration)
        XCTAssertEqual(finalRestoration.rowID, "density-row-2")
        XCTAssertEqual(
            finalRestoration.restoredOffset,
            captured.offsetFromViewportTop,
            accuracy: 0.75
        )
        XCTAssertLessThanOrEqual(finalRestoration.error, 0.75)
    }

    func testTranscriptSearchIsBoundedAndDismissalRetainsNoActiveMatch() {
        let text = Array(repeating: "needle", count: AcpTranscriptSearchIndex.maximumMatches + 10)
            .joined(separator: " ")
        var state = AcpTranscriptSearchState()
        state.present()
        state.updateQuery("needle", rows: [.message(id: "many", text: text)])

        XCTAssertEqual(state.matchCount, AcpTranscriptSearchIndex.maximumMatches)
        XCTAssertTrue(state.hasAdditionalMatches)
        XCTAssertEqual(
            state.statusText(hasHiddenEarlierRows: false),
            "\(AcpTranscriptSearchIndex.maximumMatches)+ matches"
        )
        XCTAssertEqual(state.move(.next), "msg-many")

        state.dismiss()
        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.currentRowID)
        XCTAssertEqual(state.query, "needle", "reopening Find should retain the last query")
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }

    /// Chunks after the first are held for `chunkFlushInterval` and published
    /// together, so this flushes rather than reading mid-buffer. The accumulated
    /// result is unchanged — one row, one growing string.
    func testStreamingContentVersionAdvancesWithoutGrowingRowCount() {
        let conversation = makeConversation()
        conversation.receiveTurnItemForTesting(.message(id: "wire-1", text: "Hello"))
        let rowCount = conversation.rows.count
        let version = conversation.contentVersion

        conversation.receiveTurnItemForTesting(.message(id: "wire-2", text: " world"))
        conversation.flushPendingChunk()

        XCTAssertEqual(conversation.rows.count, rowCount)
        XCTAssertGreaterThan(conversation.contentVersion, version)
        guard case let .message(_, text) = conversation.rows.first else {
            return XCTFail("Expected one accumulated assistant row")
        }
        XCTAssertEqual(text, "Hello world")
    }

    /// The reason the buffer exists: a burst of chunks becomes one publish.
    ///
    /// Every chunk used to rewrite the trailing row and republish the whole
    /// `rows` array, so SwiftUI re-diffed the entire transcript per chunk and
    /// text arrived in lurches. Twenty chunks must now cost one update, not
    /// twenty.
    func testABurstOfChunksPublishesOnce() {
        let conversation = makeConversation()
        conversation.receiveTurnItemForTesting(.message(id: "wire-0", text: "start"))
        let version = conversation.contentVersion

        for index in 1...20 {
            conversation.receiveTurnItemForTesting(.message(id: "wire-\(index)", text: " \(index)"))
        }
        XCTAssertEqual(
            conversation.contentVersion,
            version,
            "Buffered chunks must not republish the transcript one at a time"
        )

        conversation.flushPendingChunk()
        XCTAssertGreaterThan(conversation.contentVersion, version)
        guard case let .message(_, text) = conversation.rows.first else {
            return XCTFail("Expected one accumulated assistant row")
        }
        XCTAssertTrue(text.hasPrefix("start 1 2"), text)
        XCTAssertTrue(text.hasSuffix(" 20"), text)
        XCTAssertEqual(conversation.rows.count, 1)
    }

    /// A tool call arriving mid-sentence must not jump ahead of the text that
    /// introduced it — buffered text lands before any other row is appended.
    func testBufferedTextLandsBeforeAToolCallIsAppended() {
        let conversation = makeConversation()
        conversation.receiveTurnItemForTesting(.message(id: "w1", text: "Reading "))
        conversation.receiveTurnItemForTesting(.message(id: "w2", text: "the file"))
        conversation.receiveTurnItemForTesting(
            .toolCall(AcpToolCall(id: "t1", title: "read", kind: "read", status: .pending))
        )

        guard case let .message(_, text) = conversation.rows.first else {
            return XCTFail("Expected the assistant row first")
        }
        XCTAssertEqual(text, "Reading the file", "The tool call must not outrun its sentence")
        guard case .tool = conversation.rows.last else {
            return XCTFail("Expected the tool row last")
        }
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

    func testPermissionQueueAcceptsDeclaredCountLimitAndDeniesNextAsk() {
        let conversation = makePermissionConversation()
        for id in 1...AcpConversation.maximumOutstandingPermissionCount {
            conversation.receivePermissionForTesting(Self.permission(id: id))
        }

        XCTAssertEqual(
            conversation.pendingPermissionCount,
            AcpConversation.maximumOutstandingPermissionCount
        )
        XCTAssertLessThanOrEqual(
            conversation.pendingPermissionRetainedBytes,
            AcpConversation.maximumRetainedPermissionBytes
        )

        conversation.receivePermissionForTesting(Self.permission(id: 10_000, title: "Overflow"))

        XCTAssertEqual(
            conversation.pendingPermissionCount,
            AcpConversation.maximumOutstandingPermissionCount,
            "the overflowing ask must never enter the retained FIFO"
        )
        XCTAssertTrue(conversation.rows.contains { row in
            guard case let .permissionDecision(_, text) = row else { return false }
            return text.contains("Overflow") && text.contains("32-prompt limit")
        })
    }

    func testPermissionQueueBoundsAggregateEncodedPayloadBytes() {
        let conversation = makePermissionConversation()
        let first = Self.permission(
            id: 1,
            title: "First payload",
            rawInput: .string(String(repeating: "a", count: 500_000))
        )
        let second = Self.permission(
            id: 2,
            title: "Second payload",
            rawInput: .string(String(repeating: "b", count: 500_000))
        )
        let overflow = Self.permission(
            id: 3,
            title: "Byte overflow",
            rawInput: .string(String(repeating: "c", count: 100_000))
        )
        let acceptedBytes = AcpConversation.retainedPermissionPayloadBytes(first)
            + AcpConversation.retainedPermissionPayloadBytes(second)
        XCTAssertLessThan(acceptedBytes, AcpConversation.maximumRetainedPermissionBytes)
        XCTAssertGreaterThan(
            acceptedBytes + AcpConversation.retainedPermissionPayloadBytes(overflow),
            AcpConversation.maximumRetainedPermissionBytes
        )

        conversation.receivePermissionForTesting(first)
        conversation.receivePermissionForTesting(second)
        conversation.receivePermissionForTesting(overflow)

        XCTAssertEqual(conversation.pendingPermissionCount, 2)
        XCTAssertEqual(conversation.pendingPermissionRetainedBytes, acceptedBytes)
        XCTAssertTrue(conversation.rows.contains { row in
            guard case let .permissionDecision(_, text) = row else { return false }
            return text.contains("Byte overflow") && text.contains("retained-payload limit")
        })
    }

    func testStalePresentedAndQueuedPermissionsExpireInArrivalOrder() {
        let conversation = makePermissionConversation()
        let receivedAt = Date()
        conversation.receivePermissionForTesting(
            Self.permission(id: 1, title: "Oldest"),
            receivedAt: receivedAt
        )
        conversation.receivePermissionForTesting(
            Self.permission(id: 2, title: "Next"),
            receivedAt: receivedAt.addingTimeInterval(1)
        )

        conversation.expirePermissionsForTesting(
            at: receivedAt.addingTimeInterval(AcpConversation.permissionPromptLifetime + 2)
        )

        XCTAssertNil(conversation.pendingPermission)
        XCTAssertEqual(conversation.pendingPermissionCount, 0)
        XCTAssertEqual(conversation.pendingPermissionRetainedBytes, 0)
        let events = conversation.rows.compactMap { row -> String? in
            guard case let .permissionDecision(_, text) = row else { return nil }
            return text
        }
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0].contains("Oldest"))
        XCTAssertTrue(events[1].contains("Next"))
        XCTAssertTrue(events.allSatisfy { $0.contains("expired after 5 minutes") })
    }

    func testAutomaticPermissionEvidencePublishesEveryEventButRetainsABoundedTail() {
        let conversation = makePermissionConversation()
        var persistenceSnapshotCount = 0
        var persistenceReceivedDecision = false
        conversation.onTranscriptChanged = { rows, _ in
            persistenceSnapshotCount += 1
            persistenceReceivedDecision = rows.contains {
                if case .permissionDecision = $0 { return true }
                return false
            }
        }
        var observedEventIDs: Set<String> = []
        var maximumResolutionBacklog = 0
        let eventCount = AcpConversation.maximumRetainedPermissionDecisionRows + 5
        let oversizedPayload = String(
            repeating: "x",
            count: AcpConversation.maximumRetainedPermissionBytes
        )
        for id in 1...eventCount {
            conversation.receivePermissionForTesting(Self.permission(
                id: id,
                title: "Oversized \(id)",
                rawInput: .string(oversizedPayload)
            ))
            if let last = conversation.rows.last, case .permissionDecision = last {
                observedEventIDs.insert(last.id)
            }
            maximumResolutionBacklog = max(
                maximumResolutionBacklog,
                conversation.pendingAutomaticPermissionResolutionCount
            )
        }

        let retainedEvents = conversation.rows.filter {
            if case .permissionDecision = $0 { return true }
            return false
        }
        XCTAssertEqual(observedEventIDs.count, eventCount)
        XCTAssertEqual(
            retainedEvents.count,
            AcpConversation.maximumRetainedPermissionDecisionRows
        )
        XCTAssertLessThanOrEqual(
            maximumResolutionBacklog,
            AcpConversation.maximumPendingAutomaticPermissionResolutions
        )
        XCTAssertFalse(
            persistenceReceivedDecision,
            "live automatic-denial evidence must not accumulate in durable transcript pages"
        )
        XCTAssertEqual(
            persistenceSnapshotCount,
            0,
            "ephemeral evidence must not enqueue redundant durable snapshots"
        )
        XCTAssertTrue(retainedEvents.last?.id.contains("\(eventCount)") == true)
    }

    func testPermissionVisualFixtureIsOptInAndDecisionGrade() throws {
        let ordinary = makeConversation()
        ordinary.loadVisualFixture()
        XCTAssertNil(ordinary.pendingPermission)
        let renderedBlocks = ordinary.rows.compactMap { row -> [MarkdownSourceBlock]? in
            guard case let .message(_, text) = row else { return nil }
            return AcpTranscriptBlockCache().blocks(for: text)
        }.flatMap { $0 }
        XCTAssertTrue(renderedBlocks.contains { if case .table = $0.block { return true }; return false })
        XCTAssertTrue(renderedBlocks.contains { if case .code = $0.block { return true }; return false })

        let permission = makeConversation()
        permission.loadVisualFixture(includePermission: true)
        let review = try XCTUnwrap(permission.pendingPermissionReview)
        XCTAssertFalse(review.rawInputIsTitleFallback)
        XCTAssertEqual(review.paths.count, 3)
        XCTAssertEqual(review.ruleScope.workspace, permission.workspaceURL.path)
        XCTAssertEqual(review.allowOnceOptionID, "allow-once")
        XCTAssertEqual(review.denyOnceOptionID, "reject-once")
        XCTAssertEqual(review.omittedOptions.map(\.kind), ["allow_always"])
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

    func testTranscriptBlockCacheReparsesOnlyTheGrowingTail() {
        let cache = AcpTranscriptBlockCache()
        let initial = "# Result\n\nStable paragraph.\n\nGrowing"
        let originalBlocks = cache.blocks(for: initial)
        XCTAssertEqual(originalBlocks.count, 3)
        XCTAssertEqual(cache.lastParsedUTF16Count, (initial as NSString).length)

        let appended = initial + " answer with `inline code`."
        let updatedBlocks = cache.blocks(for: appended)

        XCTAssertEqual(updatedBlocks.count, 3)
        XCTAssertEqual(Array(updatedBlocks.prefix(2)), Array(originalBlocks.prefix(2)))
        XCTAssertLessThan(cache.lastParsedUTF16Count, (appended as NSString).length)
        XCTAssertEqual(cache.parseCount, 2)
    }

    func testTranscriptBlockCacheWorkStaysBoundedAcrossManyStreamingChunks() {
        let cache = AcpTranscriptBlockCache()
        let stable = (0..<120).map { "Stable paragraph \($0)." }.joined(separator: "\n\n")
        var stream = stable + "\n\nGrowing"
        _ = cache.blocks(for: stream)
        var naiveWholeSourceUnits = (stream as NSString).length
        for index in 0..<100 {
            stream += " token\(index)"
            _ = cache.blocks(for: stream)
            naiveWholeSourceUnits += (stream as NSString).length
        }

        // Reusing stable blocks keeps aggregate parser input far below the
        // exact whole-source-on-every-chunk baseline.
        XCTAssertLessThan(
            cache.totalParsedUTF16Count,
            naiveWholeSourceUnits / 5
        )
    }

    func testTranscriptBlockCacheReparsesAChangedSourceAndCanPromoteTailToTable() {
        let cache = AcpTranscriptBlockCache()
        _ = cache.blocks(for: "Intro\n\nName | Result")
        let tableSource = "Intro\n\nName | Result\n--- | ---\nBuild | Passed"
        let blocks = cache.blocks(for: tableSource)

        guard case let .table(headers, rows, _) = blocks.last?.block else {
            return XCTFail("Expected the growing final paragraph to become a table")
        }
        XCTAssertEqual(headers, ["Name", "Result"])
        XCTAssertEqual(rows, [["Build", "Passed"]])

        let replacement = "Entirely different response"
        _ = cache.blocks(for: replacement)
        XCTAssertEqual(cache.lastParsedUTF16Count, (replacement as NSString).length)
    }

    func testTranscriptMarkdownPreservesFencedCodeAndTablesAsBlocks() {
        let source = """
        ```swift
        let answer = 42
        ```

        File | Line
        --- | ---
        App.swift | 42
        """
        let blocks = AcpTranscriptBlockCache().blocks(for: source)
        XCTAssertEqual(blocks.count, 2)
        guard case let .code(language, code) = blocks[0].block else {
            return XCTFail("Expected fenced code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let answer = 42")
        guard case .table = blocks[1].block else {
            return XCTFail("Expected native table block")
        }
        XCTAssertEqual(AcpTranscriptCodeLanguage.grammar(for: "typescript"), .shipped(.javascript))
        XCTAssertEqual(AcpTranscriptCodeLanguage.grammar(for: "py"), .shipped(.python))
        XCTAssertFalse(SyntaxHighlighter.spans(in: code, language: .swift).isEmpty)
    }

    func testTranscriptFileReferencesResolveInsideWorkspaceWithLineAndColumn() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-links-\(UUID().uuidString)", isDirectory: true)
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("App.swift")
        try "let answer = 42\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let references = AcpTranscriptInlineRendering.fileReferences(
            in: "See Sources/App.swift:42:7 and missing.swift:9.",
            workspaceURL: workspace
        )

        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references[0].fileURL, file.standardizedFileURL)
        XCTAssertEqual(references[0].line, 42)
        XCTAssertEqual(references[0].linkURL.fragment, "L42")

        let attributed = AcpTranscriptInlineRendering.attributed(
            "Open `Sources/App.swift:42:7`.",
            workspaceURL: workspace
        )
        XCTAssertEqual(attributed.runs.compactMap { $0.link }.first?.fragment, "L42")
    }

    func testTranscriptExpansionBudgetDoublesAndSaturates() {
        XCTAssertEqual(AcpChatRendering.expandedLimit(120_000), 240_000)
        XCTAssertEqual(AcpChatRendering.expandedLimit(Int.max), Int.max)
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

    func testForgettingTheDraftErasesItAndDisarmsLaterSaves() {
        let key = "unit-\(UUID().uuidString)"
        let defaultsKey = "chatDraft.\(key)"
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let conversation = makeConversation(draftKey: key)
        conversation.saveDraft("unsent secret")
        XCTAssertEqual(UserDefaults.standard.string(forKey: defaultsKey), "unsent secret")

        conversation.forgetPersistentDraft()
        XCTAssertNil(
            UserDefaults.standard.string(forKey: defaultsKey),
            "a permanent delete must erase the legacy defaults draft"
        )

        // The composer can still emit one last change as it tears down.
        conversation.saveDraft("late write after delete")
        XCTAssertNil(
            UserDefaults.standard.string(forKey: defaultsKey),
            "a save after the delete boundary must not resurrect the draft"
        )
        XCTAssertEqual(makeConversation(draftKey: key).loadDraft(), "")
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

    private static func permission(
        id: Int,
        title: String? = nil,
        rawInput: JSONValue? = nil
    ) -> AcpPermissionRequest {
        AcpPermissionRequest(
            id: id,
            sessionID: "session",
            title: title ?? "Permission \(id)",
            options: [
                .init(id: "allow", name: "Allow", kind: "allow_once"),
                .init(id: "reject", name: "Reject", kind: "reject_once"),
            ],
            rawInput: rawInput
        )
    }
}
