import Foundation
import XCTest
@testable import KaisolaMacPreview

/// `AppModel.currentProjectDirectory` — the active-project inference that lets
/// New Terminal/Agent/Chat skip the folder picker (matching Electron).
@MainActor
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

    private func makeModel() -> (AppModel, NativeSessionStore) {
        let store = NativeSessionStore(fileURL: storeFile)
        return (AppModel(sessionStore: store), store)
    }

    func testNoProjectsReturnsNil() {
        let (model, _) = makeModel()
        XCTAssertNil(model.currentProjectDirectory)
    }

    func testSingleProjectIsUnambiguousContext() {
        let (model, store) = makeModel()
        _ = store.openProject(directory: "/tmp/ctx-solo")
        XCTAssertEqual(model.currentProjectDirectory?.lastPathComponent, "ctx-solo")
    }

    func testSelectedProjectNameWins() {
        let (model, store) = makeModel()
        _ = store.openProject(directory: "/tmp/ctx-alpha")
        _ = store.openProject(directory: "/tmp/ctx-beta")
        model.selectedProjectName = "ctx-beta"
        XCTAssertEqual(model.currentProjectDirectory?.lastPathComponent, "ctx-beta")
    }

    func testAmbiguousWithoutSelectionReturnsNil() {
        let (model, store) = makeModel()
        _ = store.openProject(directory: "/tmp/ctx-one")
        _ = store.openProject(directory: "/tmp/ctx-two")
        // Two projects, nothing selected → no unambiguous context.
        XCTAssertNil(model.currentProjectDirectory)
    }
}
