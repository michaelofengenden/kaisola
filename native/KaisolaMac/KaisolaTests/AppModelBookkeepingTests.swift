import Foundation
import XCTest
@testable import Kaisola

/// Per-surface bookkeeping AppModel keeps for the life of a window: shutdown
/// tasks, split intent tokens, and closed-chat tombstones. Each one used to
/// grow monotonically — an entry per close, per split, per lifetime — even
/// though every entry becomes meaningless the moment its surface is gone.
final class AppModelBookkeepingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kaisola-bookkeeping-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testBoundedIdentifierSetKeepsTheNewestWithinItsLimit() {
        var ids = BoundedIdentifierSet(limit: 3)
        for index in 0..<5 { ids.insert("chat-\(index)") }

        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids.identifiers, ["chat-2", "chat-3", "chat-4"])
        XCTAssertFalse(ids.contains("chat-1"))
        XCTAssertTrue(ids.contains("chat-4"))

        // Reinserting refreshes recency instead of growing the store.
        ids.insert("chat-2")
        XCTAssertEqual(ids.identifiers, ["chat-3", "chat-4", "chat-2"])
        XCTAssertTrue(ids.remove("chat-3"))
        XCTAssertFalse(ids.remove("chat-3"))
        XCTAssertEqual(ids.identifiers, ["chat-4", "chat-2"])
    }

    func testSurfacePruningDropsBookkeepingForVanishedSurfaces() {
        let tokens = ["term-a": UUID(), "term-b": UUID()]
        let pruned = SurfaceBookkeeping.pruned(tokens, keeping: ["term-b"])
        XCTAssertEqual(Array(pruned.keys), ["term-b"])
        XCTAssertTrue(SurfaceBookkeeping.pruned(tokens, keeping: []).isEmpty)
        XCTAssertEqual(
            SurfaceBookkeeping.pruned(tokens, keeping: ["term-a", "term-b"]),
            tokens
        )
    }

    @MainActor
    func testShutdownRegistryPrunesFinishedWorkAndReplacesSupersededWork() async {
        let registry = ShutdownTaskRegistry()
        let finished = registry.start("chat-1") { }
        XCTAssertEqual(registry.count, 1)
        await finished.value
        XCTAssertEqual(registry.count, 0, "A completed shutdown must not be retained")

        let superseded = registry.start("chat-2") {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        let replacement = registry.start("chat-2") { }
        XCTAssertTrue(superseded.isCancelled)
        await superseded.value
        await replacement.value
        XCTAssertEqual(
            registry.count,
            0,
            "A superseded shutdown must not remove the entry that replaced it"
        )

        let pending = registry.start("chat-3") { }
        await registry.drain()
        XCTAssertEqual(registry.count, 0)
        XCTAssertFalse(pending.isCancelled)
    }

    @MainActor
    func testClosedChatTombstonesStayBoundedAcrossManyCloses() {
        let model = AppModel(
            sessionStore: NativeSessionStore(
                fileURL: directory.appendingPathComponent("native-sessions.json")
            ),
            workspaceStateStore: NativeWorkspaceStateStore(
                fileURL: directory.appendingPathComponent("workspace-state-v1.json")
            )
        )

        for index in 0..<(AppModel.closedChatTombstoneLimit + 40) {
            model.enqueueTranscriptRemoval(chatID: "chat-\(index)")
        }

        XCTAssertEqual(
            model.explicitlyClosedChatIDs.count,
            AppModel.closedChatTombstoneLimit
        )
        XCTAssertTrue(model.explicitlyClosedChatIDs.contains(
            "chat-\(AppModel.closedChatTombstoneLimit + 39)"
        ))
        XCTAssertFalse(model.explicitlyClosedChatIDs.contains("chat-0"))
    }

    @MainActor
    func testFailedPopOutTargetRetainsExplicitRecoveryUntilDismissed() async {
        let model = AppModel(
            sessionStore: NativeSessionStore(
                fileURL: directory.appendingPathComponent("popout-sessions.json")
            ),
            workspaceStateStore: NativeWorkspaceStateStore(
                fileURL: directory.appendingPathComponent("popout-workspace.json")
            )
        )

        await model.openPopOutTarget("terminal:missing")

        XCTAssertEqual(model.missingSessionRecovery?.sessionID, "terminal:missing")
        XCTAssertTrue(model.missingSessionRecovery?.message.contains("could not connect") == true)
        XCTAssertNil(model.selectedSessionID)
        model.dismissMissingSessionRecovery()
        XCTAssertNil(model.missingSessionRecovery)
    }
}
