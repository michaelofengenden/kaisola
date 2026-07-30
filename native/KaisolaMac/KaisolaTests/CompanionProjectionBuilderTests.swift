import Foundation
import XCTest
@testable import Kaisola

final class CompanionProjectionBuilderTests: XCTestCase {
    func testBuildUsesCanonicalKindAndNeverLeaksPathsOrCredentialValues() throws {
        let projection = CompanionProjectionBuilder.build(
            drafts: [draft(
                projectName: "/Users/test/SecretProject",
                title: "Run API_TOKEN=never-mobile in /Users/test/.ssh/config",
                agentID: "sk-super-secret-token-value",
                activity: .needsAttention,
                createdAt: 10,
                lastActivityAt: 20
            )],
            revision: 1,
            nowMilliseconds: 100
        )

        XCTAssertEqual(projection.projectionKind, "kaisola.companion.projection")
        XCTAssertEqual(projection.revision, 1)
        XCTAssertEqual(projection.sessions.first?.status, .waiting)
        XCTAssertEqual(projection.attention.first?.sessionId, "session-1")
        XCTAssertTrue(projection.board.columns.isEmpty)

        let encoded = try JSONEncoder().encode(projection)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("/Users/test"))
        XCTAssertFalse(json.contains("never-mobile"))
        XCTAssertFalse(json.contains("super-secret-token-value"))
        XCTAssertFalse(json.contains("workspacePath"))
        XCTAssertFalse(json.contains("terminalOutput"))
    }

    func testBuildDeduplicatesCapsAndKeepsIdleClockStable() {
        let older = draft(title: "Older", activity: .idle, createdAt: 10, lastActivityAt: 20)
        let newer = draft(title: "Newer", activity: .idle, createdAt: 10, lastActivityAt: 30)
        let projection = CompanionProjectionBuilder.build(
            drafts: [older, newer],
            revision: 1,
            nowMilliseconds: 100
        )
        XCTAssertEqual(projection.sessions.map(\.title), ["Newer"])
        XCTAssertEqual(projection.sessions.first?.updatedAt, 30)

        let undated = CompanionProjectionBuilder.build(
            drafts: [draft(activity: .idle, createdAt: nil, lastActivityAt: nil)],
            revision: 2,
            nowMilliseconds: 9_000
        )
        XCTAssertEqual(undated.sessions.first?.updatedAt, 0)
    }

    func testTerminalSnapshotCarriesOnlyBoundedStreamHead() throws {
        let projection = CompanionProjectionBuilder.build(
            drafts: [draft(activity: .working, createdAt: 10, lastActivityAt: nil)],
            terminalStreams: [
                "session-1": CompanionTerminalStreamHead(
                    streamEpoch: "epoch-safe",
                    endOffset: 42
                ),
            ],
            revision: 1,
            nowMilliseconds: 100
        )
        let session = try XCTUnwrap(projection.sessions.first)
        XCTAssertEqual(session.terminalStreamEpoch, "epoch-safe")
        XCTAssertEqual(session.terminalEndOffset, 42)
        XCTAssertNil(session.terminalOutput)
        XCTAssertNil(session.terminalLines)
    }

    func testRevisionsIgnoreRefreshTimeAndAdvanceOnMeaningfulState() {
        let revisions = CompanionProjectionRevisions()
        let idle = draft(activity: .idle, createdAt: 10, lastActivityAt: 20)
        XCTAssertEqual(revisions.next(drafts: [idle], nowMilliseconds: 100)?.revision, 1)
        XCTAssertNil(revisions.next(drafts: [idle], nowMilliseconds: 200))

        let working = draft(activity: .working, createdAt: 10, lastActivityAt: 20)
        XCTAssertEqual(revisions.next(drafts: [working], nowMilliseconds: 300)?.revision, 2)
        XCTAssertEqual(revisions.current?.generatedAt, 300)

        let advancedStream = [
            "session-1": CompanionTerminalStreamHead(streamEpoch: "epoch-safe", endOffset: 1),
        ]
        XCTAssertEqual(revisions.next(
            drafts: [working],
            terminalStreams: advancedStream,
            nowMilliseconds: 400
        )?.revision, 3)
    }

    private func draft(
        projectName: String = "Kaisola",
        title: String = "Session",
        agentID: String? = "Codex",
        activity: RememberedSessionActivity,
        createdAt: Int64?,
        lastActivityAt: Int64?
    ) -> RememberedSessionDraft {
        RememberedSessionDraft(
            id: "session-1",
            projectID: "project-1",
            projectName: projectName,
            title: title,
            kind: .terminal,
            agentID: agentID,
            activity: activity,
            resumeKind: .livePTY,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            hasLocalTranscript: true
        )
    }
}
