import Foundation
import XCTest
@testable import KaisolaMacPreview

/// NativeSessionStore against a throwaway file — owner identity, owned-session
/// upsert/remove, and the opened-project-tab persistence added for the shell
/// spine's explicit open/rename/close.
final class NativeSessionStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: NativeSessionStore!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-store-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("native-sessions.json")
        store = NativeSessionStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testOwnerIDIsStableAcrossReads() {
        let first = store.ownerID()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, store.ownerID())
    }

    func testProjectIDIsDeterministicAndNamespaced() {
        let path = "/Users/example/Developer/Kaisola"
        let id = NativeSessionStore.projectID(forDirectory: path)
        XCTAssertTrue(id.hasPrefix("nproj_"))
        XCTAssertEqual(id, NativeSessionStore.projectID(forDirectory: path))
        // Distinct from Electron's proj_* namespace by construction.
        XCTAssertFalse(id.hasPrefix("proj_"))
    }

    func testOpenProjectIsIdempotentByDirectory() {
        let path = "/tmp/example-project"
        let a = store.openProject(directory: path)
        let b = store.openProject(directory: path)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(store.projects().count, 1)
        XCTAssertEqual(store.projects().first?.name, "example-project")
    }

    func testOpenProjectPersistsAcrossStoreInstances() {
        let opened = store.openProject(directory: "/tmp/persisted-project")
        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.projects().count, 1)
        // Same normalized path the store recorded survives the round-trip.
        XCTAssertEqual(reopened.projects().first?.path, opened.path)
        XCTAssertEqual(reopened.projects().first?.name, "persisted-project")
    }

    func testRenameProjectUpdatesNameOnly() {
        let project = store.openProject(directory: "/tmp/rename-me")
        store.renameProject(id: project.id, name: "Custom Name")
        let renamed = store.projects().first { $0.id == project.id }
        XCTAssertEqual(renamed?.name, "Custom Name")
        XCTAssertEqual(renamed?.path, project.path)
    }

    func testCloseProjectRemovesTabButLeavesOthers() {
        let keep = store.openProject(directory: "/tmp/keep")
        let drop = store.openProject(directory: "/tmp/drop")
        store.closeProject(id: drop.id)
        let ids = store.projects().map(\.id)
        XCTAssertTrue(ids.contains(keep.id))
        XCTAssertFalse(ids.contains(drop.id))
    }

    func testCloseThenReopenRestoresMostRecentProject() {
        let a = store.openProject(directory: "/tmp/alpha")
        let b = store.openProject(directory: "/tmp/beta")
        store.closeProject(id: a.id)
        store.closeProject(id: b.id)
        XCTAssertTrue(store.projects().isEmpty)

        // ⌘⇧T restores newest-first: beta, then alpha.
        let first = store.reopenLastClosedProject()
        XCTAssertEqual(first?.id, b.id)
        XCTAssertEqual(store.projects().map(\.id), [b.id])
        let second = store.reopenLastClosedProject()
        XCTAssertEqual(second?.id, a.id)
        XCTAssertNil(store.reopenLastClosedProject())   // stack drained
    }

    func testReopenPersistsClosedStackAcrossInstances() {
        let a = store.openProject(directory: "/tmp/persisted-closed")
        store.closeProject(id: a.id)
        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.closedProjects().map(\.id), [a.id])
        XCTAssertEqual(reopened.reopenLastClosedProject()?.id, a.id)
    }

    func testReopeningAFolderDirectlyRetiresItsClosedEntry() {
        let a = store.openProject(directory: "/tmp/gamma")
        store.closeProject(id: a.id)
        XCTAssertFalse(store.closedProjects().isEmpty)
        // Opening the same folder again should clear the stale closed entry.
        _ = store.openProject(directory: "/tmp/gamma")
        XCTAssertTrue(store.closedProjects().isEmpty)
    }

    func testClosedSessionStackPushesAndPopsNewestFirst() {
        store.pushClosedSession(ClosedSession(cwd: "/tmp/one", agentID: nil, title: "one"))
        store.pushClosedSession(ClosedSession(cwd: "/tmp/two", agentID: "claude-code", title: "two"))
        let first = store.popClosedSession()
        XCTAssertEqual(first?.cwd, "/tmp/two")
        XCTAssertEqual(first?.agentID, "claude-code")
        XCTAssertEqual(store.popClosedSession()?.cwd, "/tmp/one")
        XCTAssertNil(store.popClosedSession())
    }

    func testClosedSessionStackIsBounded() {
        for index in 0..<15 {
            store.pushClosedSession(ClosedSession(cwd: "/tmp/s\(index)", agentID: nil, title: "s\(index)"))
        }
        XCTAssertEqual(store.closedSessions().count, 10)
        XCTAssertEqual(store.closedSessions().first?.cwd, "/tmp/s5")   // oldest dropped
    }

    func testProjectColorPersistsAndClears() {
        let project = store.openProject(directory: "/tmp/tinted")
        store.setProjectColor(id: project.id, colorHex: "E16A6A")
        XCTAssertEqual(store.projects().first?.colorHex, "E16A6A")
        store.setProjectColor(id: project.id, colorHex: nil)
        XCTAssertNil(store.projects().first?.colorHex)
    }

    func testMoveProjectReordersWithinBounds() {
        let a = store.openProject(directory: "/tmp/order-a")
        let b = store.openProject(directory: "/tmp/order-b")
        _ = store.openProject(directory: "/tmp/order-c")
        store.moveProject(id: b.id, delta: -1)
        XCTAssertEqual(store.projects().map(\.path), ["/tmp/order-b", "/tmp/order-a", "/tmp/order-c"])
        // Out-of-bounds moves are no-ops.
        store.moveProject(id: b.id, delta: -1)
        XCTAssertEqual(store.projects().first?.id, b.id)
        store.moveProject(id: a.id, delta: 5)
        XCTAssertEqual(store.projects().map(\.path), ["/tmp/order-b", "/tmp/order-a", "/tmp/order-c"])
    }

    func testRelocateProjectCarriesNameAndColorToTheNewPath() {
        let project = store.openProject(directory: "/tmp/old-home")
        store.renameProject(id: project.id, name: "My Workspace")
        store.setProjectColor(id: project.id, colorHex: "5AA9E6")
        let relocated = store.relocateProject(id: project.id, toDirectory: "/tmp/new-home")
        XCTAssertEqual(relocated?.name, "My Workspace")
        XCTAssertEqual(relocated?.colorHex, "5AA9E6")
        XCTAssertEqual(store.projects().count, 1)
        XCTAssertEqual(store.projects().first?.path, "/tmp/new-home")
        XCTAssertEqual(store.projects().first?.name, "My Workspace")
        XCTAssertEqual(store.projects().first?.colorHex, "5AA9E6")
        // The old id's closed-stack entry must not resurrect the old path.
        XCTAssertNotEqual(store.projects().first?.id, project.id)
    }

    func testRecentFoldersAreMostRecentFirstDedupedAndBounded() {
        for index in 0..<10 {
            _ = store.openProject(directory: "/tmp/recent-\(index)")
        }
        _ = store.openProject(directory: "/tmp/recent-3")   // re-open moves to head
        let recents = store.recentFolders()
        XCTAssertEqual(recents.first, "/tmp/recent-3")
        XCTAssertEqual(recents.count, 8)
        XCTAssertEqual(recents.filter { $0 == "/tmp/recent-3" }.count, 1)
    }

    func testSelectedSessionPersistsAcrossInstances() {
        _ = store.openProject(directory: "/tmp/sel")   // ensures the file exists
        store.recordSelectedSession("term-abc")
        XCTAssertEqual(NativeSessionStore(fileURL: fileURL).lastSelectedSessionID(), "term-abc")
        store.recordSelectedSession(nil)
        XCTAssertNil(NativeSessionStore(fileURL: fileURL).lastSelectedSessionID())
    }

    func testOpenProjectDoesNotDisturbOwnedSessions() {
        let session = NativeOwnedSession(
            id: "term-1",
            projectID: NativeSessionStore.projectID(forDirectory: "/tmp/with-session"),
            cwd: "/tmp/with-session",
            title: "shell",
            createdAt: 1
        )
        store.upsert(session)
        _ = store.openProject(directory: "/tmp/with-session")
        XCTAssertEqual(store.sessions().count, 1)
        XCTAssertEqual(store.sessions().first?.id, "term-1")
        XCTAssertEqual(store.projects().count, 1)
    }

    func testRecoverOwnedSessionsRequiresExactStableOwnerAndKnownProject() throws {
        let project = store.openProject(directory: "/tmp/recover-owned")
        let stableOwnerID = store.ownerID()
        let record = BrokerTerminalRecord(
            id: "term-\(project.id)-recovered",
            projectID: project.id,
            pid: 4_321,
            exited: false,
            streamEpoch: "epoch",
            endOffset: 42,
            lastOwnerID: stableOwnerID
        )

        let recovered = store.recoverOwnedSessions(from: [record], now: 123_456)

        let session = try XCTUnwrap(recovered.first)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(session.id, record.id)
        XCTAssertEqual(session.projectID, project.id)
        XCTAssertEqual(session.cwd, project.path)
        XCTAssertEqual(session.title, project.name)
        XCTAssertEqual(session.createdAt, 123_456)
        XCTAssertEqual(store.sessions(), recovered)
        XCTAssertTrue(store.recoverOwnedSessions(from: [record]).isEmpty)
    }

    func testRecoverOwnedSessionsRejectsObservedExitedAndUnknownProjectRecords() {
        let project = store.openProject(directory: "/tmp/recover-guarded")
        let stableOwnerID = store.ownerID()
        let observed = BrokerTerminalRecord(
            id: "term-observed",
            projectID: project.id,
            pid: 1,
            exited: false,
            streamEpoch: nil,
            endOffset: 0,
            lastOwnerID: "another-install"
        )
        let exited = BrokerTerminalRecord(
            id: "term-exited",
            projectID: project.id,
            pid: nil,
            exited: true,
            streamEpoch: nil,
            endOffset: 0,
            lastOwnerID: stableOwnerID
        )
        let unknownProject = BrokerTerminalRecord(
            id: "term-unknown-project",
            projectID: "nproj_missing",
            pid: 2,
            exited: false,
            streamEpoch: nil,
            endOffset: 0,
            currentOwnerID: stableOwnerID
        )

        XCTAssertTrue(
            store.recoverOwnedSessions(from: [observed, exited, unknownProject]).isEmpty
        )
        XCTAssertTrue(store.sessions().isEmpty)
    }
}
