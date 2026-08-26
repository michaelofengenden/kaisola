import XCTest
@testable import Kaisola

/// The folding table for the quiet transcript: which rows collapse into a
/// work marker, how the live tail stays visible, and which message earns the
/// response chrome.
final class AcpTranscriptDisplayTests: XCTestCase {
    private func tool(
        _ id: String,
        kind: String = "execute",
        status: AcpToolCall.Status = .completed,
        title: String = "step",
        content: [AcpToolContent] = []
    ) -> AcpTranscriptRow {
        .tool(AcpToolCall(id: id, title: title, kind: kind, status: status, content: content))
    }

    func testConsecutivePlainToolCallsFoldIntoOneRunKeyedByTheFirstCall() {
        let rows: [AcpTranscriptRow] = [
            .user(id: "u", text: "go", failed: false),
            tool("a"), tool("b", kind: "read"), tool("c", kind: "read"),
            .message(id: "m", text: "done"),
            tool("d"),
        ]
        let items = AcpTranscriptDisplay.items(rows: rows, isRunning: false)
        XCTAssertEqual(items.map(\.id), ["user-u", "workrun-a", "msg-m", "workrun-d"])
        guard case let .workRun(_, calls) = items[1] else { return XCTFail("expected a run") }
        XCTAssertEqual(calls.map(\.id), ["a", "b", "c"])
        // The run's identity survives growth at the tail, so an expansion
        // stays open while the turn streams.
        let grown = AcpTranscriptDisplay.items(
            rows: rows + [tool("e")], isRunning: false
        )
        XCTAssertEqual(grown[3].id, "workrun-d")
    }

    func testSubagentAndCompactionRowsStayVisibleAndSplitRuns() {
        let spawn = AcpToolCall(id: "s", title: "Map the chrome", kind: "think", status: .completed)
        let compaction = AcpToolCall(id: "k", title: "Compact conversation", kind: "think", status: .completed)
        let rows: [AcpTranscriptRow] = [
            tool("a"), .tool(spawn), tool("b"), .tool(compaction), tool("c"),
        ]
        let items = AcpTranscriptDisplay.items(rows: rows, isRunning: false)
        XCTAssertEqual(items.map(\.id), ["workrun-a", "tool-s", "workrun-b", "tool-k", "workrun-c"])
    }

    func testRunningTailKeepsOpenCallsOutOfTheMarkerAsLiveRows() {
        let rows: [AcpTranscriptRow] = [
            tool("a"), tool("b"),
            tool("live1", status: .inProgress), tool("live2", status: .pending),
        ]
        let running = AcpTranscriptDisplay.items(rows: rows, isRunning: true)
        XCTAssertEqual(running.map(\.id), ["workrun-a", "tool-live1", "tool-live2"])
        // Once the turn ends the same calls fold back into the marker.
        let ended = AcpTranscriptDisplay.items(rows: rows, isRunning: false)
        XCTAssertEqual(ended.map(\.id), ["workrun-a"])
    }

    func testSearchCanFindTheRunHidingARow() {
        let items = AcpTranscriptDisplay.items(
            rows: [tool("a"), tool("b")], isRunning: false
        )
        XCTAssertEqual(AcpTranscriptDisplay.runID(containing: "b", in: items), "workrun-a")
        XCTAssertEqual(AcpTranscriptDisplay.runID(containing: "tool-b", in: items), "workrun-a")
        XCTAssertNil(AcpTranscriptDisplay.runID(containing: "zz", in: items))
    }

    func testOnlyTheTurnsFinalMessageEarnsResponseChrome() {
        let rows: [AcpTranscriptRow] = [
            .user(id: "u1", text: "go", failed: false),
            .message(id: "m1", text: "starting"),
            tool("a"),
            .message(id: "m2", text: "the answer"),
            .user(id: "u2", text: "next", failed: false),
            .message(id: "m3", text: "streaming now"),
        ]
        let finals = AcpTranscriptDisplay.finalResponseMessageIDs(rows: rows)
        XCTAssertEqual(finals, ["m2", "m3"], "interim narration is prose; the last word of each turn is the response")
    }

    func testWorkRunSummarySpeaksCountsAndAlwaysSaysFailures() {
        let calls = [
            AcpToolCall(id: "1", title: "b", kind: "execute", status: .completed),
            AcpToolCall(id: "2", title: "r", kind: "read", status: .completed),
            AcpToolCall(id: "3", title: "r", kind: "read", status: .failed),
            AcpToolCall(id: "4", title: "e", kind: "edit", status: .completed),
        ]
        let summary = AcpWorkRunSummary(calls: calls)
        XCTAssertEqual(summary.label, "Ran a command, read 2 files, edited a file")
        XCTAssertEqual(summary.failureLabel, "1 failed")
        XCTAssertNil(AcpWorkRunSummary(calls: Array(calls.prefix(2))).failureLabel)
        XCTAssertEqual(
            AcpWorkRunSummary(calls: [
                AcpToolCall(id: "5", title: "t", kind: "other", status: .completed),
            ]).label,
            "One more step"
        )
    }
}
