import XCTest
@testable import KaisolaCompanion

final class ProjectionFixtureTests: XCTestCase {
    func testCanonicalBoardFixtureDecodes() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "snapshot-board", withExtension: "json"))
        let envelope = try JSONDecoder().decode(CompanionSnapshotEnvelope.self, from: Data(contentsOf: url))

        XCTAssertEqual(envelope.v, 1)
        XCTAssertEqual(envelope.body.type, "snapshot.projects")
        XCTAssertEqual(envelope.body.projection.projects.map(\.name), ["Kaisola"])
        XCTAssertEqual(envelope.body.projection.board.columns.map(\.id), ["running", "waiting", "done"])
        XCTAssertEqual(envelope.body.projection.board.columns.map(\.count), [1, 1, 1])
    }

    func testStructuredTurnUsesTheDesktopWireKeys() throws {
        let data = Data(#"{"kind":"assistant","text":"Streaming safely","status":"streaming","at":1784250001400}"#.utf8)
        let turn = try JSONDecoder().decode(CompanionTurn.self, from: data)

        XCTAssertEqual(turn.role, .assistant)
        XCTAssertEqual(turn.text, "Streaming safely")
        XCTAssertEqual(turn.at, 1_784_250_001_400)
    }

    @MainActor
    func testPreviewStartsObserveOnlyAndMatchesSessionCounts() {
        let store = CompanionStore.preview(now: Date(timeIntervalSince1970: 1_784_250_001))
        let counts = store.counts(for: "project-kaisola")

        XCTAssertTrue(store.isPreview)
        XCTAssertFalse(store.canControlAgents)
        XCTAssertFalse(store.canControlTerminals)
        XCTAssertEqual(counts.running, 2)
        XCTAssertEqual(counts.waiting, 1)
        XCTAssertEqual(counts.done, 1)
        XCTAssertEqual(store.permissions.count, 1)
        XCTAssertEqual(store.needsYouCount, 2, "a permission and its waiting session must be one attention item")
    }

    @MainActor
    func testPreviewPermissionDecisionIsLocalAndExactlyRemovesOneCard() {
        let store = CompanionStore.preview(now: Date(timeIntervalSince1970: 1_784_250_001))
        store.resolvePermission("permission-1", decision: "Reject")

        XCTAssertTrue(store.permissions.isEmpty)
        XCTAssertEqual(store.previewReceipt, "Preview only: reject")
        XCTAssertEqual(store.session(for: "session-review")?.status, .done)
    }
}
