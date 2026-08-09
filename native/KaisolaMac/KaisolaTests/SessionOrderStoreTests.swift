import Foundation
import XCTest
@testable import Kaisola

final class SessionOrderStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-session-order-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Permission drills leave the directory read-only; put it back or the
        // temporary tree cannot be torn down.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ id: String, pid: Int32? = nil) -> BrokerTerminalRecord {
        BrokerTerminalRecord(
            id: id, projectID: "p", pid: pid, exited: false, streamEpoch: nil, endOffset: 0
        )
    }

    private var orderFile: URL {
        directory.appendingPathComponent("session-order.json", isDirectory: false)
    }

    private func writeRawCatalog(_ text: String) throws {
        try Data(text.utf8).write(to: orderFile)
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
        let store = SessionOrderStore(directory: directory)
        XCTAssertEqual(store.setOrder(projectID: "p1", ids: ["x", "y"]), .saved(preservedCopy: nil))
        XCTAssertEqual(SessionOrderStore(directory: directory).order(projectID: "p1"), ["x", "y"])
        XCTAssertEqual(SessionOrderStore(directory: directory).order(projectID: "missing"), [])
    }

    /// Nothing stored yet is not damage: the first drag of a fresh install
    /// writes without asking anybody anything.
    func testAbsentCatalogSavesWithoutConfirmation() {
        let store = SessionOrderStore(directory: directory)
        XCTAssertEqual(store.catalog(), .absent)
        XCTAssertEqual(store.setOrder(projectID: "p1", ids: ["a"]), .saved(preservedCopy: nil))
    }

    // MARK: Rapid reorder

    /// A drag can be followed immediately by another. Every one of them has to
    /// report durably saved, the last one has to win, and a relaunch has to
    /// agree — the whole point of reporting a status is that it is true.
    func testRapidReordersEachReportSavedAndTheLastOneWins() {
        let store = SessionOrderStore(directory: directory)
        var last: [String] = []
        for step in 0..<25 {
            let ids = step.isMultiple(of: 2) ? ["a", "b", "c"] : ["c", "b", "a"]
            last = ids
            XCTAssertEqual(
                store.setOrder(projectID: "p1", ids: ids),
                .saved(preservedCopy: nil),
                "reorder \(step) reported something other than a durable save"
            )
        }
        XCTAssertEqual(SessionOrderStore(directory: directory).order(projectID: "p1"), last)
    }

    /// Reordering one project must not disturb another's stored order, across
    /// a relaunch.
    func testReorderKeepsOtherProjectsAcrossRelaunch() {
        SessionOrderStore(directory: directory).setOrder(projectID: "p1", ids: ["a", "b"])
        SessionOrderStore(directory: directory).setOrder(projectID: "p2", ids: ["m", "n"])
        SessionOrderStore(directory: directory).setOrder(projectID: "p1", ids: ["b", "a"])

        let relaunched = SessionOrderStore(directory: directory)
        XCTAssertEqual(relaunched.order(projectID: "p1"), ["b", "a"])
        XCTAssertEqual(relaunched.order(projectID: "p2"), ["m", "n"])
    }

    // MARK: Damaged catalog

    func testMalformedCatalogIsNotOverwrittenWithoutConfirmation() throws {
        try writeRawCatalog("{ this is not the order file }")
        let store = SessionOrderStore(directory: directory)
        XCTAssertEqual(store.catalog(), .unreadable(.malformed))
        XCTAssertEqual(store.setOrder(projectID: "p1", ids: ["a"]), .needsConfirmation(.malformed))
        // The bytes are still there: the refusal is what makes them recoverable.
        XCTAssertEqual(
            try String(contentsOf: orderFile, encoding: .utf8),
            "{ this is not the order file }"
        )
    }

    /// A second drag used to be all it took to lose the file: the read failed
    /// to nil, the write rebuilt the payload from empty, and the recoverable
    /// bytes went with it.
    func testRepeatedDragsNeverReplaceAMalformedCatalog() throws {
        try writeRawCatalog("{\"p1\": \"not-a-list\"}")
        let store = SessionOrderStore(directory: directory)
        for _ in 0..<5 {
            XCTAssertEqual(store.setOrder(projectID: "p1", ids: ["a", "b"]), .needsConfirmation(.malformed))
        }
        XCTAssertEqual(try String(contentsOf: orderFile, encoding: .utf8), "{\"p1\": \"not-a-list\"}")
    }

    /// A file a newer Kaisola wrote is not garbage, and it is named as its own
    /// case so the confirmation can say what replacing it costs.
    func testForwardVersionCatalogIsRecognisedAndHeldBack() throws {
        try writeRawCatalog("{\"version\":99,\"orders\":{\"p1\":[\"a\"]}}")
        let store = SessionOrderStore(directory: directory)
        XCTAssertEqual(store.catalog(), .unreadable(.forwardVersion(99)))
        XCTAssertEqual(store.setOrder(projectID: "p1", ids: ["b"]), .needsConfirmation(.forwardVersion(99)))
    }

    /// Confirming the replacement writes the new order and keeps the old bytes
    /// beside it, under the same `.corrupt-<stamp>` name the workspace archive
    /// uses.
    func testConfirmedReplacementPreservesTheUnreadableBytes() throws {
        try writeRawCatalog("{ this is not the order file }")
        let store = SessionOrderStore(directory: directory)

        let outcome = store.setOrder(projectID: "p1", ids: ["a", "b"], replacingUnreadableCatalog: true)
        guard case let .saved(preservedCopy) = outcome else {
            return XCTFail("confirmed replacement reported \(outcome)")
        }
        let preserved = try XCTUnwrap(preservedCopy)
        XCTAssertTrue(preserved.lastPathComponent.hasPrefix("session-order.corrupt-"))
        XCTAssertEqual(
            try String(contentsOf: preserved, encoding: .utf8),
            "{ this is not the order file }"
        )
        XCTAssertEqual(SessionOrderStore(directory: directory).order(projectID: "p1"), ["a", "b"])
    }

    /// A file that cannot be opened at all is damage, not emptiness. Reading it
    /// as empty is what let a drag replace a perfectly readable order the
    /// process had merely been denied.
    func testUnopenableCatalogIsNotTreatedAsEmpty() throws {
        try XCTSkipIf(getuid() == 0, "root ignores the permission bits this drill depends on")
        try writeRawCatalog("{\"p1\":[\"a\",\"b\"]}")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: orderFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: orderFile.path)
        }

        let store = SessionOrderStore(directory: directory)
        XCTAssertEqual(store.catalog(), .unreadable(.unreadableFile))
        XCTAssertEqual(store.setOrder(projectID: "p1", ids: ["b", "a"]), .needsConfirmation(.unreadableFile))
    }

    // MARK: Unwritable storage

    /// Disk full, read-only volume, a sandbox that lost the folder: the store
    /// says the save failed instead of pretending it worked, and what was
    /// stored before is still what a relaunch reads.
    func testUnwritableDirectoryReportsFailureAndKeepsTheStoredOrder() throws {
        try XCTSkipIf(getuid() == 0, "root ignores the permission bits this drill depends on")
        let store = SessionOrderStore(directory: directory)
        XCTAssertEqual(store.setOrder(projectID: "p1", ids: ["a", "b"]), .saved(preservedCopy: nil))

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let outcome = store.setOrder(projectID: "p1", ids: ["b", "a"])
        guard case let .writeFailed(reason) = outcome else {
            return XCTFail("an unwritable directory reported \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(store.order(projectID: "p1"), ["a", "b"], "the last durable order must survive")
    }

    /// The failed write must not leave its scratch file behind either — a
    /// directory that fills with `.session-order.json.*` is the same bug in a
    /// slower form.
    func testFailedWriteLeavesNoTemporaryFile() throws {
        try XCTSkipIf(getuid() == 0, "root ignores the permission bits this drill depends on")
        let store = SessionOrderStore(directory: directory)
        store.setOrder(projectID: "p1", ids: ["a"])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        _ = store.setOrder(projectID: "p1", ids: ["b"])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".session-order.json.") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: What the rail does with the answer

    func testCommitKeepsTheDraggedOrderWhenItIsDurable() {
        let resolution = QuietSessionOrderCommit.resolve(
            previous: ["a", "b", "c"],
            attempted: ["c", "a", "b"],
            outcome: .saved(preservedCopy: nil)
        )
        XCTAssertEqual(resolution, .init(order: ["c", "a", "b"], notice: nil))
    }

    /// The regression this issue is about: a drag that did not reach disk used
    /// to stay on screen until a relaunch silently undid it.
    func testCommitPutsTheOrderBackWhenTheWriteFailed() {
        let resolution = QuietSessionOrderCommit.resolve(
            previous: ["a", "b", "c"],
            attempted: ["c", "a", "b"],
            outcome: .writeFailed("the disk is full")
        )
        XCTAssertEqual(resolution.order, ["a", "b", "c"])
        XCTAssertEqual(resolution.notice, .failed("the disk is full"))
        let message = QuietSessionOrderCommit.failureMessage("the disk is full")
        XCTAssertTrue(message.contains("the disk is full"))
        XCTAssertTrue(message.contains("last saved order"))
    }

    func testCommitAsksBeforeReplacingAnUnreadableCatalog() {
        let resolution = QuietSessionOrderCommit.resolve(
            previous: ["a", "b"],
            attempted: ["b", "a"],
            outcome: .needsConfirmation(.forwardVersion(7))
        )
        XCTAssertEqual(resolution.order, ["a", "b"], "nothing was written, so nothing may move")
        XCTAssertEqual(resolution.notice, .confirmReplace(.forwardVersion(7)))
        XCTAssertTrue(
            QuietSessionOrderCommit.confirmationMessage(for: .forwardVersion(7)).contains("newer version")
        )
    }

    func testCommitNamesThePreservedFileAfterAConfirmedReplacement() {
        let preserved = URL(fileURLWithPath: "/tmp/session-order.corrupt-20260808T101112Z.json")
        let resolution = QuietSessionOrderCommit.resolve(
            previous: ["a", "b"],
            attempted: ["b", "a"],
            outcome: .saved(preservedCopy: preserved)
        )
        XCTAssertEqual(resolution.order, ["b", "a"])
        XCTAssertEqual(resolution.notice, .preserved(preserved))
        XCTAssertTrue(
            QuietSessionOrderCommit.preservedMessage(preserved)
                .contains("session-order.corrupt-20260808T101112Z.json")
        )
    }
}
