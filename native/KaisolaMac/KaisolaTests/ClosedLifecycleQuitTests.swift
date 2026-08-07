import Foundation
import XCTest
@testable import Kaisola

/// The close-then-⌘Q race (2026-08-06 spec §4a/§4f): `commitClose` mutates the
/// store and the layouts synchronously in the caller's turn, so a workspace
/// snapshot taken immediately afterwards — teardown, quit, anything — already
/// excludes the pane and the record with no task turn in between.
final class ClosedLifecycleQuitTests: XCTestCase {
    @MainActor
    func testCommitCloseIsVisibleToSnapshotInTheSameTurn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("closed-quit-\(UUID().uuidString.prefix(8))")
        let store = NativeSessionStore(
            fileURL: root.appendingPathComponent("native-sessions.json")
        )
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json")
        )
        let model = AppModel(sessionStore: store, workspaceStateStore: workspaceStore)

        let directory = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let projectID = NativeSessionStore.projectID(forDirectory: directory.path)
        let terminalID = NativeSessionStore.terminalID(projectID: projectID)
        store.upsert(NativeOwnedSession(
            id: terminalID,
            projectID: projectID,
            cwd: directory.path,
            title: "shell",
            createdAt: 1
        ))
        // openProject refreshes the model's persisted-navigation cache, so the
        // record above becomes visible to the snapshot builder.
        model.openProject(directory: directory)
        var layout = model.paneLayout(for: projectID)
        layout.add(terminalID)
        model.setPaneLayoutForTesting(layout, projectID: projectID)
        // Dormant, exactly like a post-reboot restore — the state whose panes
        // the snapshot deliberately preserves, and therefore the state where
        // a close used to be able to race the quit-time save.
        model.markDormantForTesting(terminalID)
        let dormantSnapshot = model.workspaceSnapshotForTesting(projectID: projectID)
        XCTAssertEqual(
            dormantSnapshot?.panes.contains { $0.id == terminalID }, true,
            "precondition: the dormant pane persists before the close"
        )

        // Synchronous commit; NO awaits before the snapshot.
        model.commitClose(terminalID)

        XCTAssertFalse(store.owns(terminalID: terminalID))
        XCTAssertTrue(store.isTerminalTombstoned(terminalID))
        let snapshot = model.workspaceSnapshotForTesting(projectID: projectID)
        XCTAssertEqual(
            snapshot?.panes.contains { $0.id == terminalID } ?? false, false,
            "a closed pane must be gone from the very next snapshot"
        )
        XCTAssertFalse(model.paneLayout(for: projectID).contains(terminalID))
    }
}
