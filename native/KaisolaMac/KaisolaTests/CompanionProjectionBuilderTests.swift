import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

final class CompanionProjectionBuilderTests: XCTestCase {
    func testScopedBuildFailsClosedWithoutObserveAndExcludesUnrelatedSessions() throws {
        let accountSession = draft(
            id: "account-session",
            projectID: "account-project",
            title: "Visible account session",
            activity: .working,
            createdAt: 10,
            lastActivityAt: 20
        )
        let unrelatedSession = draft(
            id: "unrelated-session",
            projectID: "unrelated-project",
            title: "Other account /Users/other/private",
            activity: .needsAttention,
            createdAt: 10,
            lastActivityAt: 30
        )
        let terminalStreams = [
            accountSession.id: CompanionTerminalStreamHead(streamEpoch: "account-epoch", endOffset: 10),
            unrelatedSession.id: CompanionTerminalStreamHead(streamEpoch: "other-epoch", endOffset: 99),
        ]

        let denied = CompanionProjectionBuilder.build(
            drafts: [accountSession, unrelatedSession],
            terminalStreams: terminalStreams,
            scope: CompanionProjectionScope(
                capabilities: [],
                visibleSessionIDs: [accountSession.id, unrelatedSession.id]
            ),
            revision: 1,
            nowMilliseconds: 100
        )
        XCTAssertTrue(denied.projects.isEmpty)
        XCTAssertTrue(denied.sessions.isEmpty)
        XCTAssertTrue(denied.attention.isEmpty)

        let scoped = CompanionProjectionBuilder.build(
            drafts: [accountSession, unrelatedSession],
            terminalStreams: terminalStreams,
            scope: CompanionProjectionScope(
                capabilities: [.observe],
                visibleSessionIDs: [accountSession.id]
            ),
            revision: 2,
            nowMilliseconds: 100
        )
        XCTAssertEqual(scoped.projects.map(\.id), ["account-project"])
        XCTAssertEqual(scoped.sessions.map(\.id), ["account-session"])
        XCTAssertEqual(scoped.sessions.first?.terminalStreamEpoch, "account-epoch")
        XCTAssertTrue(scoped.attention.isEmpty)

        let encoded = try JSONEncoder().encode(scoped)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("unrelated"))
        XCTAssertFalse(json.contains("other-epoch"))
        XCTAssertFalse(json.contains("/Users/other"))
    }

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

    func testBuildScrubsEnvironmentBearerURLCredentialsAndAdditionalLocalPaths() throws {
        let projection = CompanionProjectionBuilder.build(
            drafts: [draft(
                projectName: "file:///opt/private/client-project",
                title: "export DATABASE_URL='postgres://alice:hunter2@db.internal/app' "
                    + "Authorization: Bearer bearer-secret-123456 "
                    + "/Volumes/Client/plan.txt ~/private/key.pem /etc/hosts",
                agentID: "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
                activity: .working,
                createdAt: 10,
                lastActivityAt: 20
            )],
            revision: 1,
            nowMilliseconds: 100
        )

        let encoded = try JSONEncoder().encode(projection)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in [
            "alice", "hunter2", "bearer-secret-123456", "AKIAIOSFODNN7EXAMPLE",
            "/Volumes/Client", "~/private", "/etc/hosts", "/opt/private",
        ] {
            XCTAssertFalse(json.contains(forbidden), "Projection leaked \(forbidden)")
        }
        XCTAssertTrue(json.contains("[redacted]"))
        XCTAssertTrue(json.contains("[local path]"))
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

    func testRepresentativeSessionsEncodeOnlyTheExplicitProjectionAllowlist() throws {
        let drafts = [
            draft(
                id: "terminal-1",
                projectID: "project-terminal",
                projectName: "Terminal project",
                title: "Terminal session",
                kind: .terminal,
                activity: .working,
                createdAt: 10,
                lastActivityAt: 20
            ),
            draft(
                id: "agent-1",
                projectID: "project-agent",
                projectName: "Agent project",
                title: "Agent session",
                kind: .agentChat,
                activity: .needsAttention,
                createdAt: 30,
                lastActivityAt: 40
            ),
            draft(
                id: "mesh-1",
                projectID: "project-mesh",
                projectName: "Mesh project",
                title: "Mesh session",
                kind: .mesh,
                agentID: nil,
                activity: .ended,
                createdAt: 50,
                lastActivityAt: 60
            ),
        ]
        let projection = CompanionProjectionBuilder.build(
            drafts: drafts,
            terminalStreams: [
                "terminal-1": CompanionTerminalStreamHead(streamEpoch: "stream-1", endOffset: 64),
            ],
            scope: CompanionProjectionScope(
                capabilities: [.observe],
                visibleSessionIDs: Set(drafts.map(\.id))
            ),
            revision: 7,
            nowMilliseconds: 100
        )

        let data = try JSONEncoder().encode(projection)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), [
            "projectionKind", "revision", "generatedAt", "freshness", "projects",
            "sessions", "attention", "permissions", "board",
        ])
        let projects = try XCTUnwrap(root["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 3)
        for project in projects {
            XCTAssertEqual(Set(project.keys), ["id", "name", "connection", "lastContactAt", "counts"])
            let counts = try XCTUnwrap(project["counts"] as? [String: Any])
            XCTAssertEqual(Set(counts.keys), ["running", "waiting", "done", "failed"])
        }
        let sessions = try XCTUnwrap(root["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 3)
        let allowedSessionKeys: Set<String> = [
            "id", "projectId", "kind", "title", "status", "needsYou", "unread",
            "updatedAt", "completedAt", "provider", "startedAt", "terminalStreamEpoch",
            "terminalEndOffset",
        ]
        for session in sessions {
            XCTAssertTrue(
                Set(session.keys).isSubset(of: allowedSessionKeys),
                "Unexpected session keys: \(session.keys)"
            )
        }
        let attention = try XCTUnwrap(root["attention"] as? [[String: Any]])
        XCTAssertEqual(attention.count, 1)
        let firstAttention = try XCTUnwrap(attention.first)
        XCTAssertEqual(Set(firstAttention.keys), [
            "id", "projectId", "sessionId", "kind", "title", "detail", "createdAt", "severity",
        ])
        XCTAssertTrue(try XCTUnwrap(root["permissions"] as? [Any]).isEmpty)
        let board = try XCTUnwrap(root["board"] as? [String: Any])
        XCTAssertEqual(Set(board.keys), ["columns"])
        XCTAssertTrue(try XCTUnwrap(board["columns"] as? [Any]).isEmpty)

        let forbiddenKeys: Set<String> = [
            "account", "branch", "credential", "cwd", "diffs", "directory", "env",
            "environment", "model", "mode", "path", "prompt", "repo", "summary",
            "terminalLines", "terminalOutput", "turns", "windowId",
        ]
        XCTAssertTrue(allKeys(in: root).isDisjoint(with: forbiddenKeys))
    }

    func testWorstCaseProjectionRemainsWithinSerializedBudget() throws {
        // Backslashes consume one input byte but two JSON bytes, so they are a
        // stricter serialization fixture than ordinary ASCII or multibyte text.
        let longTitle = String(repeating: "\\", count: 320)
        let longProvider = String(repeating: "\\", count: 160)
        let drafts = (0..<CompanionProjectionBuilder.maximumSessions).map { index in
            draft(
                id: String(repeating: "s", count: 230) + String(format: "%010d", index),
                projectID: String(repeating: "p", count: 150)
                    + String(format: "%010d", index % CompanionProjectionBuilder.maximumProjects),
                projectName: longTitle,
                title: longTitle,
                kind: .terminal,
                agentID: longProvider,
                activity: .needsAttention,
                createdAt: Int64(index),
                lastActivityAt: Int64(index + 1)
            )
        }
        let streams = Dictionary(uniqueKeysWithValues: drafts.map {
            ($0.id, CompanionTerminalStreamHead(
                streamEpoch: String(repeating: "e", count: 150)
                    + String(format: "%010d", Int($0.lastActivityAt ?? 0)),
                endOffset: 9_007_199_254_740_991
            ))
        })
        let projection = CompanionProjectionBuilder.build(
            drafts: drafts,
            terminalStreams: streams,
            revision: .max,
            nowMilliseconds: 9_007_199_254_740_991
        )
        let encoded = try JSONEncoder().encode(projection)

        XCTAssertEqual(projection.projects.count, CompanionProjectionBuilder.maximumProjects)
        XCTAssertEqual(projection.sessions.count, CompanionProjectionBuilder.maximumSessions)
        XCTAssertEqual(projection.attention.count, CompanionProjectionBuilder.maximumSessions)
        XCTAssertGreaterThan(encoded.count, 400 * 1_024, "Fixture must continue exercising the byte ceiling")
        XCTAssertLessThanOrEqual(encoded.count, CompanionProjectionBuilder.maximumEncodedBytes)
        XCTAssertLessThan(CompanionProjectionBuilder.maximumEncodedBytes, CompanionEnvelope.maximumBytes)
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
        id: String = "session-1",
        projectID: String = "project-1",
        projectName: String = "Kaisola",
        title: String = "Session",
        kind: RememberedSessionKind = .terminal,
        agentID: String? = "Codex",
        activity: RememberedSessionActivity,
        createdAt: Int64?,
        lastActivityAt: Int64?
    ) -> RememberedSessionDraft {
        RememberedSessionDraft(
            id: id,
            projectID: projectID,
            projectName: projectName,
            title: title,
            kind: kind,
            agentID: agentID,
            activity: activity,
            resumeKind: .livePTY,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            hasLocalTranscript: true
        )
    }

    private func allKeys(in value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { result, element in
                result.formUnion(allKeys(in: element.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: []) { result, element in
                result.formUnion(allKeys(in: element))
            }
        }
        return []
    }
}
