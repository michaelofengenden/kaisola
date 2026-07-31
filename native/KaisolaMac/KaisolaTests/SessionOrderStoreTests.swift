import Foundation
import XCTest
@testable import Kaisola

final class SessionOrderStoreTests: XCTestCase {
    private func record(_ id: String, pid: Int32? = nil) -> BrokerTerminalRecord {
        BrokerTerminalRecord(
            id: id, projectID: "p", pid: pid, exited: false, streamEpoch: nil, endOffset: 0
        )
    }

    /// `apply` runs on every sidebar render, so a duplicate id (broker
    /// reconnect, observe-only merge) must not trap the app: the first record
    /// wins and the duplicate is dropped.
    func testApplyToleratesDuplicateIDs() {
        let sessions = [record("a", pid: 1), record("a", pid: 2), record("b")]
        let out = SessionOrderStore.apply(["a"], to: sessions)
        XCTAssertEqual(out.map(\.id), ["a", "b"])
        XCTAssertEqual(out.first?.pid, 1)
    }

    func testApplyWithoutStoredOrderToleratesDuplicateIDs() {
        let sessions = [record("a", pid: 1), record("a", pid: 2)]
        let out = SessionOrderStore.apply([], to: sessions)
        // Only the first record survives: ForEach requires unique ids, so the
        // unmatched tail is deduped exactly like the stored-order head.
        XCTAssertEqual(out.map(\.id), ["a"])
    }

    func testApplyOrdersKnownFirstThenAppendsNew() {
        let sessions = [record("a"), record("b"), record("c"), record("d")]
        let out = SessionOrderStore.apply(["c", "a"], to: sessions)
        XCTAssertEqual(out.map(\.id), ["c", "a", "b", "d"])
    }

    func testApplyIgnoresStaleIDs() {
        let sessions = [record("a"), record("b")]
        let out = SessionOrderStore.apply(["ghost", "b"], to: sessions)
        XCTAssertEqual(out.map(\.id), ["b", "a"])
    }

    func testRoundTripPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SessionOrderStore(directory: dir)
        store.setOrder(projectID: "p1", ids: ["x", "y"])
        XCTAssertEqual(SessionOrderStore(directory: dir).order(projectID: "p1"), ["x", "y"])
        XCTAssertEqual(SessionOrderStore(directory: dir).order(projectID: "missing"), [])
    }
}
