import Foundation
import XCTest
@testable import Kaisola

/// QuickActionStore persistence against a throwaway file — per-project
/// round-trip across instances, the cap-8 oldest-first eviction, corrupt-file
/// degradation, and cross-project isolation.
final class QuickActionStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: QuickActionStore!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-quick-actions-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("quick-actions.json")
        store = QuickActionStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    // MARK: - Round-trip per project

    func testRoundTripPerProjectAcrossInstances() {
        let actions = [
            QuickAction(id: "1", title: "Build", command: "npm run build"),
            QuickAction(id: "2", title: "Test", command: "npm test"),
        ]
        store.save(actions, forProject: "nproj_alpha")

        // A fresh instance reads the same actions back, order preserved.
        let reopened = QuickActionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.actions(forProject: "nproj_alpha"), actions)
    }

    func testSaveReplacesWholesaleAndCanClear() {
        store.save([QuickAction(id: "1", title: "Build", command: "make")], forProject: "p")
        store.save([QuickAction(id: "2", title: "Dev", command: "npm run dev")], forProject: "p")
        XCTAssertEqual(store.actions(forProject: "p").map(\.id), ["2"])

        // Saving an empty array clears the project's row.
        store.save([], forProject: "p")
        XCTAssertTrue(store.actions(forProject: "p").isEmpty)
    }

    func testUnknownProjectIsEmpty() {
        XCTAssertTrue(store.actions(forProject: "never-saved").isEmpty)
    }

    // MARK: - Cap (8 per project, drop oldest)

    func testSaveCapsAtEightDroppingOldest() {
        let actions = (0..<12).map { QuickAction(id: "a\($0)", title: "t\($0)", command: "c\($0)") }
        store.save(actions, forProject: "p")

        let stored = store.actions(forProject: "p")
        XCTAssertEqual(stored.count, 8)
        // The four oldest (a0…a3) are evicted; a4…a11 survive in order.
        XCTAssertEqual(stored.map(\.id), (4..<12).map { "a\($0)" })
    }

    func testSaveExactlyEightKeepsAll() {
        let actions = (0..<8).map { QuickAction(id: "a\($0)", title: "t\($0)", command: "c\($0)") }
        store.save(actions, forProject: "p")
        XCTAssertEqual(store.actions(forProject: "p").count, 8)
    }

    // MARK: - Corrupt file

    func testCorruptFileDegradesToEmpty() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(store.actions(forProject: "anything").isEmpty)
    }

    // MARK: - Cross-project isolation

    func testProjectsAreIsolated() {
        store.save([QuickAction(id: "1", title: "A", command: "a")], forProject: "projA")
        store.save([QuickAction(id: "2", title: "B", command: "b")], forProject: "projB")

        XCTAssertEqual(store.actions(forProject: "projA").map(\.id), ["1"])
        XCTAssertEqual(store.actions(forProject: "projB").map(\.id), ["2"])
        XCTAssertTrue(store.actions(forProject: "projC").isEmpty)

        // Overwriting one project leaves the other untouched.
        store.save([QuickAction(id: "3", title: "A2", command: "a2")], forProject: "projA")
        XCTAssertEqual(store.actions(forProject: "projA").map(\.id), ["3"])
        XCTAssertEqual(store.actions(forProject: "projB").map(\.id), ["2"])

        // Clearing one project leaves the other untouched.
        store.save([], forProject: "projA")
        XCTAssertTrue(store.actions(forProject: "projA").isEmpty)
        XCTAssertEqual(store.actions(forProject: "projB").map(\.id), ["2"])
    }
}
