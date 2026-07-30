import Foundation
import XCTest
@testable import Kaisola

/// SessionPinStore persistence against a throwaway file — set/unset round-trip
/// across instances, insertion-order cap eviction, corrupt-file degradation —
/// plus the pure `AppModel.pinnedOrder` ordering that drives `pinnedSort`.
final class SessionPinStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: SessionPinStore!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-pins-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("session-pins.json")
        store = SessionPinStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    // MARK: - Persistence

    func testSetUnsetRoundTripAcrossInstances() {
        store.setPinned("term-a", true)
        store.setPinned("term-b", true)

        let reopened = SessionPinStore(fileURL: fileURL)
        XCTAssertTrue(reopened.isPinned("term-a"))
        XCTAssertTrue(reopened.isPinned("term-b"))
        XCTAssertEqual(reopened.pins(), ["term-a", "term-b"])

        // Unpinning is durable too.
        reopened.setPinned("term-a", false)
        let again = SessionPinStore(fileURL: fileURL)
        XCTAssertFalse(again.isPinned("term-a"))
        XCTAssertEqual(again.pins(), ["term-b"])
    }

    func testPinIsIdempotent() {
        store.setPinned("x", true)
        store.setPinned("x", true)
        XCTAssertEqual(store.pins(), ["x"])
    }

    func testUnpinUnknownIsNoOp() {
        store.setPinned("present", true)
        store.setPinned("absent", false)   // never pinned
        XCTAssertEqual(store.pins(), ["present"])
    }

    // MARK: - Cap

    func testCapEvictsOldestByInsertionOrder() {
        for index in 0..<105 { store.setPinned("s\(index)", true) }
        XCTAssertEqual(store.pins().count, 100)
        // The five oldest pins (s0…s4) are evicted; s5…s104 survive.
        for index in 0..<5 { XCTAssertFalse(store.isPinned("s\(index)")) }
        for index in 5..<105 { XCTAssertTrue(store.isPinned("s\(index)")) }
    }

    // MARK: - Corrupt file

    func testCorruptFileDegradesToEmpty() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(store.pins().isEmpty)
        XCTAssertFalse(store.isPinned("anything"))
    }

    // MARK: - pinnedSort ordering (AppModel.pinnedOrder)

    /// `BrokerTerminalRecord.title` is the substring after the last ":" in its
    /// id, so ids like "p:alpha" pin down a known, sortable title.
    private func record(_ id: String) -> BrokerTerminalRecord {
        BrokerTerminalRecord(
            id: id, projectID: "p", pid: nil, exited: false, streamEpoch: nil, endOffset: 0
        )
    }

    func testPinnedOrderFloatsPinnedFirstThenByTitle() {
        let alpha = record("p:alpha")
        let bravo = record("p:bravo")
        let charlie = record("p:charlie")
        let delta = record("p:delta")
        let input = [charlie, alpha, delta, bravo]   // scrambled input

        let sorted = AppModel.pinnedOrder(input, pinned: ["p:delta", "p:alpha"])

        // Pinned group first, sorted by title (alpha, delta); then the unpinned
        // group, sorted by title (bravo, charlie).
        XCTAssertEqual(sorted.map(\.id), ["p:alpha", "p:delta", "p:bravo", "p:charlie"])
    }

    func testPinnedOrderIsStableForEqualTitles() {
        let first = record("a:same")
        let second = record("b:same")   // identical title "same"
        let input = [second, first]     // both unpinned, same title

        let sorted = AppModel.pinnedOrder(input, pinned: [])

        // Equal titles keep their original relative order.
        XCTAssertEqual(sorted.map(\.id), ["b:same", "a:same"])
    }

    func testPinnedOrderWithNoPinsIsPureTitleSort() {
        let input = [record("p:c"), record("p:a"), record("p:b")]
        XCTAssertEqual(AppModel.pinnedOrder(input, pinned: []).map(\.title), ["a", "b", "c"])
    }
}
