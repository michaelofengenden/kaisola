import Foundation
import XCTest
@testable import Kaisola

/// Pointer drag-reorder persists through `NativeSessionStore.moveProject(id:toIndex:)`.
/// These lock the absolute-index move in both directions, the edge cases, the
/// out-of-range clamp, and the absent-id / empty-store no-ops across a
/// four-tab order. Temp-dir store pattern mirrors `NativeSessionStoreTests`.
final class ProjectReorderTests: XCTestCase {
    private var fileURL: URL!
    private var store: NativeSessionStore!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-reorder-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("native-sessions.json")
        store = NativeSessionStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// Four tabs a, b, c, d in open order (indices 0…3).
    @discardableResult
    private func openFour() -> (a: String, b: String, c: String, d: String) {
        let a = store.openProject(directory: "/tmp/reorder-a").id
        let b = store.openProject(directory: "/tmp/reorder-b").id
        let c = store.openProject(directory: "/tmp/reorder-c").id
        let d = store.openProject(directory: "/tmp/reorder-d").id
        return (a, b, c, d)
    }

    func testMoveEarlierToLaterShiftsInterveningTabsLeft() {
        let ids = openFour()
        // a,b,c,d → move a (index 0) to index 2 → b,c,a,d
        store.moveProject(id: ids.a, toIndex: 2)
        XCTAssertEqual(store.projects().map(\.id), [ids.b, ids.c, ids.a, ids.d])
    }

    func testMoveLaterToEarlierShiftsInterveningTabsRight() {
        let ids = openFour()
        // a,b,c,d → move d (index 3) to index 1 → a,d,b,c
        store.moveProject(id: ids.d, toIndex: 1)
        XCTAssertEqual(store.projects().map(\.id), [ids.a, ids.d, ids.b, ids.c])
    }

    func testMoveToFirstAndLastEdges() {
        let ids = openFour()
        store.moveProject(id: ids.c, toIndex: 0)          // c,a,b,d
        XCTAssertEqual(store.projects().map(\.id), [ids.c, ids.a, ids.b, ids.d])
        store.moveProject(id: ids.c, toIndex: 3)          // a,b,d,c
        XCTAssertEqual(store.projects().map(\.id), [ids.a, ids.b, ids.d, ids.c])
    }

    func testToIndexAboveRangeClampsToLast() {
        let ids = openFour()
        store.moveProject(id: ids.a, toIndex: 99)
        XCTAssertEqual(store.projects().map(\.id), [ids.b, ids.c, ids.d, ids.a])
    }

    func testToIndexBelowRangeClampsToFirst() {
        let ids = openFour()
        store.moveProject(id: ids.d, toIndex: -5)
        XCTAssertEqual(store.projects().map(\.id), [ids.d, ids.a, ids.b, ids.c])
    }

    func testSameIndexIsANoOp() {
        let ids = openFour()
        store.moveProject(id: ids.b, toIndex: 1)
        XCTAssertEqual(store.projects().map(\.id), [ids.a, ids.b, ids.c, ids.d])
    }

    func testUnknownIDIsANoOp() {
        let ids = openFour()
        store.moveProject(id: "nproj_missing", toIndex: 0)
        XCTAssertEqual(store.projects().map(\.id), [ids.a, ids.b, ids.c, ids.d])
    }

    func testMoveOnEmptyStoreIsANoOp() {
        store.moveProject(id: "nproj_missing", toIndex: 0)
        XCTAssertTrue(store.projects().isEmpty)
    }

    func testAccessibleStepPlansOnlyAvailableNeighborMoves() {
        XCTAssertEqual(
            ProjectTabReorder.availableDirections(index: 0, count: 3),
            [.right]
        )
        XCTAssertEqual(
            ProjectTabReorder.availableDirections(index: 1, count: 3),
            [.left, .right]
        )
        XCTAssertEqual(
            ProjectTabReorder.availableDirections(index: 2, count: 3),
            [.left]
        )
        XCTAssertEqual(ProjectTabReorder.availableDirections(index: 0, count: 1), [])
        XCTAssertEqual(ProjectTabReorder.availableDirections(index: -1, count: 3), [])
        XCTAssertEqual(ProjectTabReorder.positionDescription(index: 0, count: 3), "Position 1 of 3")
        XCTAssertEqual(ProjectTabReorder.positionDescription(index: 2, count: 3), "Position 3 of 3")
        XCTAssertNil(ProjectTabReorder.positionDescription(index: 3, count: 3))
    }

    func testAccessibleStepsUseThePointerPathAndAnnounceThePersistedPosition() {
        let ids = openFour()
        var announcements: [String] = []

        XCTAssertTrue(
            ProjectTabReorder.perform(
                projectID: ids.c,
                projectName: "Charlie",
                index: 2,
                count: 4,
                direction: .left,
                reorder: { store.moveProject(id: $0, toIndex: $1) },
                announce: { announcements.append($0) }
            )
        )
        XCTAssertEqual(store.projects().map(\.id), [ids.a, ids.c, ids.b, ids.d])
        XCTAssertEqual(announcements, ["Moved Charlie to position 2 of 4."])

        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.projects().map(\.id), [ids.a, ids.c, ids.b, ids.d])

        XCTAssertTrue(
            ProjectTabReorder.perform(
                projectID: ids.c,
                projectName: "Charlie",
                index: 1,
                count: 4,
                direction: .right,
                reorder: { store.moveProject(id: $0, toIndex: $1) },
                announce: { announcements.append($0) }
            )
        )
        XCTAssertEqual(store.projects().map(\.id), [ids.a, ids.b, ids.c, ids.d])
        XCTAssertEqual(
            announcements,
            [
                "Moved Charlie to position 2 of 4.",
                "Moved Charlie to position 3 of 4.",
            ]
        )
    }

    func testAccessibleBoundaryStepDoesNotReorderOrAnnounce() {
        let ids = openFour()
        var reorderCalls: [(String, Int)] = []
        var announcements: [String] = []

        XCTAssertFalse(
            ProjectTabReorder.perform(
                projectID: ids.a,
                projectName: "Alpha",
                index: 0,
                count: 4,
                direction: .left,
                reorder: { reorderCalls.append(($0, $1)) },
                announce: { announcements.append($0) }
            )
        )
        XCTAssertFalse(
            ProjectTabReorder.perform(
                projectID: ids.d,
                projectName: "Delta",
                index: 3,
                count: 4,
                direction: .right,
                reorder: { reorderCalls.append(($0, $1)) },
                announce: { announcements.append($0) }
            )
        )
        XCTAssertTrue(reorderCalls.isEmpty)
        XCTAssertTrue(announcements.isEmpty)
        XCTAssertEqual(store.projects().map(\.id), [ids.a, ids.b, ids.c, ids.d])
    }

}
