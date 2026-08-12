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

    @MainActor
    func testPendingReleaseCapturesGenerationRetriesErrorsAndDrainsImpossibleGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("closed-release-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NativeSessionStore(fileURL: root.appendingPathComponent("sessions.json"))
        let control = ClosedLifecycleReleaseControl()
        let model = AppModel(
            controlClient: control,
            sessionStore: store,
            workspaceStateStore: NativeWorkspaceStateStore(
                fileURL: root.appendingPathComponent("workspace.json")
            )
        )
        model.loadVisualFixture(workspace: root)
        await control.setError(.connectionClosed)

        model.commitClose("visual-terminal")
        let queued = try XCTUnwrap(store.pendingReleaseList().first)
        XCTAssertEqual(queued.brokerGenerationID, AppModel.visualFixtureBrokerGenerationID)

        await model.drainPendingReleases()
        XCTAssertEqual(store.pendingReleaseList().map(\.id), ["visual-terminal"])

        await control.setError(nil)
        await control.setDisposition(.generationAbsent)
        await model.drainPendingReleases()

        XCTAssertTrue(store.pendingReleaseList().isEmpty)
        XCTAssertTrue(store.isTerminalTombstoned("visual-terminal"))
        let releases = await control.releases()
        XCTAssertEqual(releases, [
            .init(terminalID: "visual-terminal", generationID: AppModel.visualFixtureBrokerGenerationID),
            .init(terminalID: "visual-terminal", generationID: AppModel.visualFixtureBrokerGenerationID),
        ])
    }
}

private struct ClosedLifecycleReleaseCall: Equatable, Sendable {
    let terminalID: String
    let generationID: String?
}

private actor ClosedLifecycleReleaseControl: BrokerControlServing {
    private var disposition: BrokerTerminalReleaseDisposition = .released
    private var error: BrokerClientError?
    private var calls: [ClosedLifecycleReleaseCall] = []

    func connect(to info: BrokerInfo, ownerID: String) async throws {}

    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int,
        restore: Bool
    ) async throws -> TerminalCreation {
        TerminalCreation(
            terminalID: terminalID,
            projectID: projectID,
            pid: nil,
            streamEpoch: nil
        )
    }

    func attach(projectID: String, terminalID: String) async throws {}
    func write(projectID: String, terminalID: String, data: String) async throws {}
    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws {}
    func kill(projectID: String, terminalID: String) async throws {}
    func release(projectID: String, terminalID: String) async throws {}

    func release(
        projectID: String,
        terminalID: String,
        brokerGenerationID: String?
    ) async throws -> BrokerTerminalReleaseDisposition {
        calls.append(.init(terminalID: terminalID, generationID: brokerGenerationID))
        if let error { throw error }
        return disposition
    }

    func detachOwner(projectID: String, terminalID: String) async throws {}
    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws {}
    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws {}
    func disconnect() async {}

    func setDisposition(_ disposition: BrokerTerminalReleaseDisposition) {
        self.disposition = disposition
    }

    func setError(_ error: BrokerClientError?) { self.error = error }
    func releases() -> [ClosedLifecycleReleaseCall] { calls }
}
