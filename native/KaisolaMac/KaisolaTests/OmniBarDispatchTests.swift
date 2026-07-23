import Foundation
import XCTest
@testable import KaisolaMacPreview

/// `OmniBarDispatch` — the ⌘L omnibar's target resolution (where a one-off
/// message lands) and its no-op safety when there is nowhere to send. Sending
/// into a real conversation spawns an adapter process, so end-to-end send is
/// deliberately NOT exercised here — only `targetDescription` and the
/// no-target no-op, which touch no process boundary.
final class OmniBarDispatchTests: XCTestCase {
    private var storeFile: URL!

    override func setUpWithError() throws {
        storeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-omnibar-\(UUID().uuidString.prefix(8))")
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

    /// No chats and no project → the caption says there is nothing to send to.
    @MainActor
    func testTargetDescriptionWithNothingAvailable() {
        let (model, _) = makeModel()
        let description = OmniBarDispatch.targetDescription(model: model)
        XCTAssertTrue(
            description.localizedCaseInsensitiveContains("available"),
            "Expected an unavailable-target caption, got: \(description)"
        )
    }

    /// A single open project is unambiguous context → the caption names a new
    /// chat in that project.
    @MainActor
    func testTargetDescriptionNamesNewChatInSingleProject() {
        let (model, _) = makeModel()
        model.openProject(directory: URL(fileURLWithPath: "/tmp/omnibar-solo", isDirectory: true))
        let description = OmniBarDispatch.targetDescription(model: model)
        XCTAssertTrue(
            description.contains("omnibar-solo"),
            "Expected the project name in the caption, got: \(description)"
        )
        XCTAssertTrue(
            description.localizedCaseInsensitiveContains("new"),
            "Expected a 'new chat' caption, got: \(description)"
        )
    }

    /// Sending with no selection, no project, and no chats must be a safe no-op:
    /// it creates nothing and does not crash.
    @MainActor
    func testSendWithNoTargetIsSafeNoOp() {
        let (model, _) = makeModel()
        OmniBarDispatch.send("hello there", model: model)
        XCTAssertTrue(model.chats.isEmpty, "send with no target must not create a chat")
        XCTAssertNil(model.selectedChatID)
    }
}
