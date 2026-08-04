import Foundation
import XCTest
@testable import Kaisola

/// The adoption overlay: a terminal shown in another project while the broker
/// keeps addressing its real one. Reversibility is deleting one row.
final class SessionAdoptionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-adopt-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> SessionAdoptionStore {
        SessionAdoptionStore(fileURL: directory.appending(path: "session-adoptions.json"))
    }

    // MARK: - The store recipe

    func testAdoptClearRoundTrip() {
        let store = store()
        XCTAssertTrue(store.adopt(terminalID: "term-a-1", into: "nproj_b"))
        XCTAssertEqual(store.adoptions(), ["term-a-1": "nproj_b"])
        XCTAssertTrue(store.adopt(terminalID: "term-a-1", into: "nproj_c"), "re-adoption overwrites")
        XCTAssertEqual(store.adoptions(), ["term-a-1": "nproj_c"])
        XCTAssertTrue(store.clear(terminalID: "term-a-1"))
        XCTAssertEqual(store.adoptions(), [:])
        XCTAssertFalse(store.clear(terminalID: "term-a-1"), "clearing twice reports nothing happened")
    }

    /// The cap refuses the newcomer rather than silently evicting an older
    /// adoption — eviction would teleport some other terminal home.
    func testTheCapRefusesRatherThanEvicts() {
        let store = store()
        for index in 0..<64 {
            XCTAssertTrue(store.adopt(terminalID: "term-\(index)", into: "nproj_x"))
        }
        XCTAssertFalse(store.adopt(terminalID: "term-newcomer", into: "nproj_x"))
        XCTAssertEqual(store.adoptions().count, 64)
        XCTAssertTrue(
            store.adopt(terminalID: "term-3", into: "nproj_y"),
            "re-adopting an existing entry is not a new row and stays allowed"
        )
    }

    func testCorruptStoreReadsAsEmpty() throws {
        let store = store()
        store.adopt(terminalID: "t", into: "p")
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.adoptions(), [:])
    }

    // MARK: - The model overlay

    @MainActor
    private func makeModel() throws -> AppModel {
        // The fixture opens a secondary project when native/KaisolaMac exists
        // under the workspace root — that second project is the adopter.
        try FileManager.default.createDirectory(
            at: directory.appending(path: "native/KaisolaMac", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let model = AppModel(
            sessionStore: NativeSessionStore(
                fileURL: directory.appending(path: "native-sessions.json")
            ),
            workspaceStateStore: NativeWorkspaceStateStore(
                fileURL: directory.appending(path: "workspace-state-v1.json")
            ),
            adoptionStore: store()
        )
        model.loadVisualFixture(workspace: directory)
        return model
    }

    @MainActor
    func testMovingATerminalRegroupsItWithoutTouchingItsRealProject() throws {
        let model = try makeModel()
        let terminal = try XCTUnwrap(model.sessions.first(where: { $0.id == "visual-terminal" }))
        let home = terminal.projectID
        let adopter = try XCTUnwrap(
            model.projects.first(where: { $0.id != home })?.id,
            "the fixture should have opened a second project"
        )

        model.moveTerminal("visual-terminal", toProject: adopter)

        XCTAssertEqual(model.displayProjectID(terminal), adopter)
        XCTAssertEqual(terminal.projectID, home, "the broker-facing record never moves")
        let adopterGroup = try XCTUnwrap(model.projects.first(where: { $0.id == adopter }))
        XCTAssertTrue(adopterGroup.sessions.contains(where: { $0.id == "visual-terminal" }))
        let homeGroup = try XCTUnwrap(model.projects.first(where: { $0.id == home }))
        XCTAssertFalse(homeGroup.sessions.contains(where: { $0.id == "visual-terminal" }))
        XCTAssertTrue(model.paneLayouts[adopter]?.contains("visual-terminal") == true)
        XCTAssertFalse(model.paneLayouts[home]?.contains("visual-terminal") == true)
    }

    @MainActor
    func testReturningHomeIsExactlyOneRowRemoval() throws {
        let model = try makeModel()
        let terminal = try XCTUnwrap(model.sessions.first(where: { $0.id == "visual-terminal" }))
        let home = terminal.projectID
        let adopter = try XCTUnwrap(model.projects.first(where: { $0.id != home })?.id)

        model.moveTerminal("visual-terminal", toProject: adopter)
        model.moveTerminal("visual-terminal", toProject: home)

        XCTAssertEqual(model.displayProjectID(terminal), home)
        XCTAssertNil(model.sessionAdoptions["visual-terminal"])
        XCTAssertEqual(store().adoptions(), [:], "the persisted overlay is empty again")
        let homeGroup = try XCTUnwrap(model.projects.first(where: { $0.id == home }))
        XCTAssertTrue(homeGroup.sessions.contains(where: { $0.id == "visual-terminal" }))
    }

    /// The adopting project's snapshot enrolls the moved pane under its own
    /// id, which is what lets workspace persistence keep it (the
    /// `normalizedProject` guard drops any pane whose surface names another
    /// project).
    @MainActor
    func testTheAdopterPersistsTheMovedPaneUnderItsOwnID() throws {
        let model = try makeModel()
        let terminal = try XCTUnwrap(model.sessions.first(where: { $0.id == "visual-terminal" }))
        let home = terminal.projectID
        let adopter = try XCTUnwrap(model.projects.first(where: { $0.id != home })?.id)

        model.moveTerminal("visual-terminal", toProject: adopter)
        let snapshot = try XCTUnwrap(model.workspaceSnapshotForTesting(projectID: adopter))
        let pane = try XCTUnwrap(snapshot.panes.first(where: { $0.id == "visual-terminal" }))
        XCTAssertEqual(pane.surface.projectID, adopter)
        let homeSnapshot = model.workspaceSnapshotForTesting(projectID: home)
        XCTAssertNil(
            homeSnapshot?.panes.first(where: { $0.id == "visual-terminal" }),
            "the real project stops enrolling a pane it no longer shows"
        )
    }
}
