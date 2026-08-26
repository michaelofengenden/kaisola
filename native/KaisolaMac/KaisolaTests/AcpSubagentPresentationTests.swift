import XCTest
@testable import Kaisola

/// The subagent chip and summary logic is pure over transcript rows, so its
/// contract — what counts as a subagent, which phase a spawn is in, and what
/// the live status row says — is a table here rather than a screenshot.
final class AcpSubagentPresentationTests: XCTestCase {
    private func spawn(
        id: String = "t1",
        title: String = "Map window chrome",
        status: AcpToolCall.Status,
        content: [AcpToolContent] = []
    ) -> AcpToolCall {
        AcpToolCall(id: id, title: title, kind: "think", status: status, content: content)
    }

    func testThinkCallsClassifyBySpawnLifecycleAndCompactionByTitle() {
        XCTAssertEqual(
            AcpDelegatedWork.classify(spawn(status: .pending)),
            .subagent(.working)
        )
        XCTAssertEqual(
            AcpDelegatedWork.classify(spawn(status: .inProgress)),
            .subagent(.working)
        )
        XCTAssertEqual(
            AcpDelegatedWork.classify(spawn(status: .failed)),
            .subagent(.failed)
        )
        // A completed spawn carrying the detach acknowledgement is an agent
        // still working out of sight, never "finished".
        XCTAssertEqual(
            AcpDelegatedWork.classify(spawn(
                status: .completed,
                content: [.text("Async agent launched successfully. The agent is working in the background.")]
            )),
            .subagent(.backgrounded)
        )
        // A completed spawn whose artifact is a real report finished in the
        // foreground.
        XCTAssertEqual(
            AcpDelegatedWork.classify(spawn(
                status: .completed,
                content: [.text("Here is the styling inventory…")]
            )),
            .subagent(.finished)
        )
        XCTAssertEqual(
            AcpDelegatedWork.classify(spawn(title: "Compact conversation", status: .inProgress)),
            .compaction
        )
        XCTAssertNil(AcpDelegatedWork.classify(
            AcpToolCall(id: "t2", title: "Build", kind: "execute", status: .completed)
        ))
    }

    func testSummaryCountsOnlyTheCurrentTurnAndSpeaksWhatMoves() {
        let rows: [AcpTranscriptRow] = [
            .tool(spawn(id: "old", status: .completed, content: [.text("stale report")])),
            .user(id: "u1", text: "go", failed: false),
            .message(id: "m1", text: "on it"),
            .tool(spawn(id: "a", status: .inProgress)),
            .tool(spawn(
                id: "b",
                status: .completed,
                content: [.text("Async agent launched successfully.")]
            )),
            .tool(AcpToolCall(id: "c", title: "Build", kind: "execute", status: .completed)),
        ]
        let summary = AcpSubagentSummary.derive(rows: rows)
        XCTAssertEqual(summary?.total, 2, "the spawn before the user turn is not this turn's")
        XCTAssertEqual(summary?.working, 1)
        XCTAssertEqual(summary?.backgrounded, 1)
        XCTAssertEqual(summary?.label, "2 subagents, 1 working")

        XCTAssertNil(
            AcpSubagentSummary.derive(rows: [
                .user(id: "u1", text: "go", failed: false),
                .message(id: "m1", text: "plain reply"),
            ]),
            "a turn without subagents says nothing rather than \"0 subagents\""
        )

        XCTAssertEqual(
            AcpSubagentSummary.derive(rows: [
                .user(id: "u", text: "go", failed: false),
                .tool(spawn(id: "only", status: .inProgress)),
            ])?.label,
            "1 subagent working"
        )

        XCTAssertEqual(
            AcpSubagentSummary.derive(rows: [
                .user(id: "u", text: "go", failed: false),
                .tool(spawn(id: "f", status: .failed)),
                .tool(spawn(id: "d", status: .completed, content: [.text("report")])),
            ])?.label,
            "2 subagents, 1 failed",
            "a mixed outcome never claims the whole set finished"
        )
        XCTAssertEqual(
            AcpSubagentSummary.derive(rows: [
                .user(id: "u", text: "go", failed: false),
                .tool(spawn(id: "f", status: .failed)),
            ])?.label,
            "1 subagent failed"
        )
    }

    func testTailFollowReengagesOnlyWithinTheDeclaredDistance() {
        XCTAssertTrue(AcpTranscriptFollowPolicy.follows(afterUserScrollDistance: 0))
        XCTAssertTrue(AcpTranscriptFollowPolicy.follows(
            afterUserScrollDistance: AcpTranscriptFollowPolicy.reengageDistance
        ))
        XCTAssertFalse(AcpTranscriptFollowPolicy.follows(
            afterUserScrollDistance: AcpTranscriptFollowPolicy.reengageDistance + 1
        ))
    }
}
