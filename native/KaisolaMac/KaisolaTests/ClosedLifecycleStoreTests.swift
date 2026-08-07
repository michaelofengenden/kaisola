import Foundation
import XCTest
@testable import Kaisola

/// The durable closed-lifecycle schema (2026-08-06 spec §4a/§4a-1): closing a
/// terminal is one store mutation that removes the record, tombstones the id
/// permanently, pushes the undo entry, and queues the broker release. The
/// tombstone — not the bounded undo stack — is what enforces
/// closed-stays-closed against upserts, re-adoption, and resurrection.
final class ClosedLifecycleStoreTests: XCTestCase {
    private var store: NativeSessionStore!

    override func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("closed-lifecycle-\(UUID().uuidString)")
            .appendingPathComponent("native-sessions.json")
        store = NativeSessionStore(fileURL: url)
    }

    private func seedSession(_ id: String = "term-nproj_aaa-11112222") -> NativeOwnedSession {
        let session = NativeOwnedSession(
            id: id,
            projectID: "nproj_aaa",
            cwd: "/tmp/project-a",
            title: "shell",
            createdAt: 1_000
        )
        store.upsert(session)
        return session
    }

    func testCommitCloseRemovesTombstonesQueuesAndPushesUndo() {
        let session = seedSession()
        store.commitCloseTerminal(session.id)

        XCTAssertFalse(store.owns(terminalID: session.id))
        XCTAssertTrue(store.isTerminalTombstoned(session.id))
        XCTAssertEqual(store.pendingReleaseList().map(\.id), [session.id])
        XCTAssertEqual(store.closedSessions().last?.sourceTerminalID, session.id)
    }

    func testUpsertRefusesTombstonedID() {
        let session = seedSession()
        store.commitCloseTerminal(session.id)
        // A quiet refusal, not an assert: callers legitimately race (a
        // resurrection spawn returning after the user closed the id).
        store.upsert(session)
        XCTAssertFalse(store.owns(terminalID: session.id))
        XCTAssertTrue(store.isTerminalTombstoned(session.id))
    }

    func testAcknowledgeReleaseKeepsTheTombstone() {
        let session = seedSession()
        store.commitCloseTerminal(session.id)
        store.acknowledgeRelease(id: session.id)
        XCTAssertTrue(store.pendingReleaseList().isEmpty)
        // Permanent by design: the store cannot prove no archived pane still
        // references the id, and a dropped tombstone revives closed work.
        XCTAssertTrue(store.isTerminalTombstoned(session.id))
    }

    func testRecoverSkipsTombstonedAndExitedRecords() {
        let session = seedSession()
        _ = store.openProject(directory: "/tmp/project-a")
        store.commitCloseTerminal(session.id)

        let owner = store.ownerID()
        let lingering = BrokerTerminalRecord(
            id: session.id,
            projectID: NativeSessionStore.projectID(forDirectory: "/tmp/project-a"),
            pid: 42,
            exited: false,
            streamEpoch: "e1",
            endOffset: 0,
            currentOwnerID: owner
        )
        let exited = BrokerTerminalRecord(
            id: "term-nproj_aaa-33334444",
            projectID: NativeSessionStore.projectID(forDirectory: "/tmp/project-a"),
            pid: nil,
            exited: true,
            streamEpoch: "e2",
            endOffset: 0,
            currentOwnerID: owner
        )
        let recovered = store.recoverOwnedSessions(from: [lingering, exited])
        XCTAssertTrue(recovered.isEmpty, "closed and exited records must not be re-adopted")
        XCTAssertFalse(store.owns(terminalID: session.id))
    }

    func testEndedStampIsSetOnceAndSurvivesReload() {
        let session = seedSession()
        store.stampEnded(session.id, at: 5_000)
        store.stampEnded(session.id, at: 9_999)
        XCTAssertEqual(store.sessions().first?.endedAt, 5_000)
    }

    func testClosedProjectMarkerLifecycle() {
        _ = store.openProject(directory: "/tmp/project-a")
        let id = NativeSessionStore.projectID(forDirectory: "/tmp/project-a")
        XCTAssertFalse(store.isProjectClosed(id))
        store.closeProject(id: id)
        XCTAssertTrue(store.isProjectClosed(id))
        // The marker outlives undo-stack eviction by construction (separate
        // storage); reopening is the only thing that clears it.
        _ = store.openProject(directory: "/tmp/project-a")
        XCTAssertFalse(store.isProjectClosed(id))
    }

    func testLegacyPayloadWithoutNewFieldsDecodes() throws {
        let url = store.fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let legacy = #"{"ownerID":"native-legacy","sessions":[{"id":"t1","projectID":"p1","cwd":"/tmp","title":"old","createdAt":1}]}"#
        try Data(legacy.utf8).write(to: url)
        XCTAssertEqual(store.sessions().first?.id, "t1")
        XCTAssertNil(store.sessions().first?.endedAt)
        XCTAssertFalse(store.isTerminalTombstoned("t1"))
        XCTAssertTrue(store.pendingReleaseList().isEmpty)
    }
}
