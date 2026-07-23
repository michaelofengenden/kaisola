import Foundation
import XCTest
@testable import KaisolaMacPreview

/// `AppModel.currentProjectDirectory` — the active-project inference that lets
/// New Terminal/Agent/Chat skip the folder picker (matching Electron).
final class AppModelProjectContextTests: XCTestCase {
    private var storeFile: URL!

    override func setUpWithError() throws {
        storeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-ctx-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("native-sessions.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeFile.deletingLastPathComponent())
    }

    @MainActor
    private func makeModel() -> (AppModel, NativeSessionStore) {
        let store = NativeSessionStore(fileURL: storeFile)
        return (AppModel(sessionStore: store), store)
    }

    @MainActor
    func testNoProjectsReturnsNil() {
        let (model, _) = makeModel()
        XCTAssertNil(model.currentProjectDirectory)
    }

    @MainActor
    func testSingleProjectIsUnambiguousContext() {
        let (model, store) = makeModel()
        _ = store.openProject(directory: "/tmp/ctx-solo")
        XCTAssertEqual(model.currentProjectDirectory?.lastPathComponent, "ctx-solo")
    }

    @MainActor
    func testSelectedProjectNameWins() {
        let (model, store) = makeModel()
        _ = store.openProject(directory: "/tmp/ctx-alpha")
        _ = store.openProject(directory: "/tmp/ctx-beta")
        model.selectedProjectName = "ctx-beta"
        XCTAssertEqual(model.currentProjectDirectory?.lastPathComponent, "ctx-beta")
    }

    @MainActor
    func testAmbiguousWithoutSelectionReturnsNil() {
        let (model, store) = makeModel()
        _ = store.openProject(directory: "/tmp/ctx-one")
        _ = store.openProject(directory: "/tmp/ctx-two")
        // Two projects, nothing selected → no unambiguous context.
        XCTAssertNil(model.currentProjectDirectory)
    }

    @MainActor
    func testChatIsPersistedAndGroupedUnderItsProject() throws {
        let (model, _) = makeModel()
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let directory = URL(fileURLWithPath: "/tmp/ctx-chat", isDirectory: true)

        model.openChat(agent, inDirectory: directory)

        let project = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(project.directory?.path, directory.path)
        XCTAssertEqual(model.chats(in: project.id).count, 1)
        XCTAssertEqual(model.chats.first?.projectID, project.id)
        XCTAssertEqual(model.selectedProjectName, project.name)

        if let chatID = model.chats.first?.id { model.closeChat(chatID) }
    }

    @MainActor
    func testSwitchingProjectDoesNotLeakAnotherProjectsChat() throws {
        let (model, _) = makeModel()
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let first = URL(fileURLWithPath: "/tmp/ctx-chat-a", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/ctx-chat-b", isDirectory: true)
        model.openChat(agent, inDirectory: first)
        let firstChat = try XCTUnwrap(model.chats.first)
        model.openChat(agent, inDirectory: second)
        let secondProject = try XCTUnwrap(model.projects.first { $0.directory?.path == second.path })

        model.selectChat(firstChat.id)
        XCTAssertEqual(model.selectedChatID, firstChat.id)
        model.activateProject(named: secondProject.name)
        XCTAssertNil(model.selectedChatID)

        for chat in model.chats { model.closeChat(chat.id) }
    }

    @MainActor
    func testMeshUsesTheSameStableProjectIdentity() {
        let directory = URL(fileURLWithPath: "/tmp/ctx-mesh", isDirectory: true)
        let mesh = MeshSession(baseDirectory: directory)
        XCTAssertEqual(
            mesh.projectID,
            NativeSessionStore.projectID(forDirectory: directory.path)
        )
    }

    @MainActor
    func testPlainShellTitlesAreReadableAndProjectLocal() {
        let projectID = NativeSessionStore.projectID(forDirectory: "/tmp/readable-shells")
        let first = BrokerTerminalRecord(
            id: "term-first", projectID: projectID, pid: 1, exited: false,
            streamEpoch: nil, endOffset: 0
        )
        let second = BrokerTerminalRecord(
            id: "term-second", projectID: projectID, pid: 2, exited: false,
            streamEpoch: nil, endOffset: 0
        )
        let stored = [
            NativeOwnedSession(
                id: first.id, projectID: projectID, cwd: "/tmp/readable-shells",
                title: "readable-shells", createdAt: 1
            ),
            NativeOwnedSession(
                id: second.id, projectID: projectID, cwd: "/tmp/readable-shells",
                title: "readable-shells", createdAt: 2
            ),
        ]

        XCTAssertEqual(
            AppModel.sessionDisplayTitle(
                for: first, visibleRecords: [first, second], storedSessions: stored
            ),
            "Terminal 1"
        )
        XCTAssertEqual(
            AppModel.sessionDisplayTitle(
                for: second, visibleRecords: [first, second], storedSessions: stored
            ),
            "Terminal 2"
        )
    }

    @MainActor
    func testCustomAndObservedSessionTitlesArePreserved() {
        let record = BrokerTerminalRecord(
            id: "terminal:build", projectID: "nproj_test", pid: 3, exited: false,
            streamEpoch: nil, endOffset: 0
        )
        let custom = NativeOwnedSession(
            id: record.id, projectID: record.projectID, cwd: "/tmp/test",
            title: "Release watcher", createdAt: 1
        )
        XCTAssertEqual(
            AppModel.sessionDisplayTitle(
                for: record, visibleRecords: [record], storedSessions: [custom]
            ),
            "Release watcher"
        )
        XCTAssertEqual(
            AppModel.sessionDisplayTitle(
                for: record, visibleRecords: [record], storedSessions: []
            ),
            "build"
        )
    }
}
