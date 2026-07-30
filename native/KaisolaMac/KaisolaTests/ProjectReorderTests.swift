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
}
