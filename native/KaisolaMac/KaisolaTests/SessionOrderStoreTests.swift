import Foundation
import XCTest
@testable import Kaisola

final class SessionOrderStoreTests: XCTestCase {
    private func record(_ id: String) -> BrokerTerminalRecord {
        BrokerTerminalRecord(
            id: id, projectID: "p", pid: nil, exited: false, streamEpoch: nil, endOffset: 0
        )
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
