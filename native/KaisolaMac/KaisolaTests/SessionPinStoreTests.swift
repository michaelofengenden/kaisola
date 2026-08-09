import Foundation
import XCTest
@testable import Kaisola

/// SessionPinStore persistence against a throwaway file — set/unset round-trip,
/// durable corruption recovery, atomic-write failure, and cap eviction — plus
/// the pure `AppModel.pinnedOrder` ordering that drives `pinnedSort`.
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

    func testSetUnsetRoundTripAcrossInstances() throws {
        try store.setPinned("term-a", true)
        try store.setPinned("term-b", true)

        let reopened = SessionPinStore(fileURL: fileURL)
        XCTAssertTrue(reopened.isPinned("term-a"))
        XCTAssertTrue(reopened.isPinned("term-b"))
        XCTAssertEqual(reopened.pins(), ["term-a", "term-b"])

        // Unpinning is durable too.
        try reopened.setPinned("term-a", false)
        let again = SessionPinStore(fileURL: fileURL)
        XCTAssertFalse(again.isPinned("term-a"))
        XCTAssertEqual(again.pins(), ["term-b"])
    }

    func testPinIsIdempotent() throws {
        try store.setPinned("x", true)
        try store.setPinned("x", true)
        XCTAssertEqual(store.pins(), ["x"])
    }

    func testUnpinUnknownIsNoOp() throws {
        try store.setPinned("present", true)
        try store.setPinned("absent", false)   // never pinned
        XCTAssertEqual(store.pins(), ["present"])
    }

    func testLegacyPayloadLoadsAndUpgradesOnMutation() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"pins":["legacy"]}"#.utf8).write(to: fileURL)

        XCTAssertEqual(store.snapshot().state, .loaded)
        XCTAssertEqual(store.pins(), ["legacy"])
        try store.setPinned("current", true)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(SessionPinStore(fileURL: fileURL).pins(), ["legacy", "current"])
    }

    // MARK: - Cap

    func testCapEvictsOldestByInsertionOrder() throws {
        for index in 0..<105 { try store.setPinned("s\(index)", true) }
        XCTAssertEqual(store.pins().count, 100)
        // The five oldest pins (s0…s4) are evicted; s5…s104 survive.
        for index in 0..<5 { XCTAssertFalse(store.isPinned("s\(index)")) }
        for index in 5..<105 { XCTAssertTrue(store.isPinned("s\(index)")) }
    }

    // MARK: - Corrupt file

    func testMissingFileIsBenignAndDistinctFromCorruption() throws {
        XCTAssertEqual(store.snapshot().state, .missing)
        XCTAssertTrue(store.pins().isEmpty)

        try store.setPinned("created", true)

        let reopened = SessionPinStore(fileURL: fileURL)
        XCTAssertEqual(reopened.snapshot().state, .loaded)
        XCTAssertEqual(reopened.pins(), ["created"])
    }

    func testCorruptFileRecoversLastKnownGoodWithoutOverwritingBytes() throws {
        try store.setPinned("stable", true)
        try store.setPinned("latest", true)
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fileURL)

        let reopened = SessionPinStore(fileURL: fileURL)
        XCTAssertEqual(reopened.snapshot().state, .recoveredFromLastKnownGood)
        XCTAssertEqual(reopened.pins(), ["stable", "latest"])
        XCTAssertThrowsError(try reopened.setPinned("must-not-overwrite", true)) { error in
            XCTAssertEqual(error as? SessionPinStoreError, .unreadableCatalog)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
        XCTAssertEqual(
            SessionPinStore(fileURL: fileURL).pins(),
            ["stable", "latest"],
            "A relaunch must retain the durable last-known-good set"
        )
    }

    func testForwardVersionIsUnreadableAndPreserved() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let forward = Data(#"{"schemaVersion":2,"pins":["future"]}"#.utf8)
        try forward.write(to: fileURL)

        XCTAssertEqual(store.snapshot().state, .unreadable)
        XCTAssertThrowsError(try store.setPinned("blocked", true)) { error in
            XCTAssertEqual(error as? SessionPinStoreError, .unreadableCatalog)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), forward)
    }

    func testCorruptFileWithoutRecoveryIsUnreadableAndMutationFailsClosed() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fileURL)

        XCTAssertEqual(store.snapshot().state, .unreadable)
        XCTAssertTrue(store.pins().isEmpty)
        XCTAssertFalse(store.isPinned("anything"))
        XCTAssertThrowsError(try store.setPinned("blocked", true))
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    func testFailedWriteKeepsPriorPinsDurable() throws {
        try store.setPinned("stable", true)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }

        XCTAssertThrowsError(try store.setPinned("unsaved", true)) { error in
            XCTAssertEqual(error as? SessionPinStoreError, .writeFailed)
        }
        XCTAssertEqual(store.pins(), ["stable"])
        XCTAssertEqual(SessionPinStore(fileURL: fileURL).pins(), ["stable"])
    }

    func testPrimaryWriteFailureRollsBackRecoveryCopyAcrossRelaunch() throws {
        let root = fileURL.deletingLastPathComponent()
        let primaryDirectory = root.appendingPathComponent("primary", isDirectory: true)
        let recoveryDirectory = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let primary = primaryDirectory.appendingPathComponent("session-pins.json")
        let recovery = recoveryDirectory.appendingPathComponent("session-pins.last-known-good.json")
        let separated = SessionPinStore(fileURL: primary, lastKnownGoodURL: recovery)
        try separated.setPinned("stable", true)
        try FileManager.default.removeItem(at: recovery)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: primaryDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: primaryDirectory.path
            )
        }

        XCTAssertThrowsError(try separated.setPinned("unsaved", true)) { error in
            XCTAssertEqual(error as? SessionPinStoreError, .writeFailed)
        }
        XCTAssertEqual(separated.pins(), ["stable"])

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: primaryDirectory.path
        )
        try Data("corrupt after failed save".utf8).write(to: primary)
        let relaunched = SessionPinStore(fileURL: primary, lastKnownGoodURL: recovery)
        XCTAssertEqual(relaunched.snapshot().state, .recoveredFromLastKnownGood)
        XCTAssertEqual(relaunched.pins(), ["stable"])
    }

    func testInterruptedTemporaryWriteCannotReplaceCommittedPins() throws {
        try store.setPinned("stable", true)
        let abandoned = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".session-pins.json.interrupted.tmp")
        try Data(#"{"schemaVersion":1,"pins":["ghost"]}"#.utf8).write(to: abandoned)

        let reopened = SessionPinStore(fileURL: fileURL)
        XCTAssertEqual(reopened.pins(), ["stable"])
        XCTAssertEqual(reopened.snapshot().state, .loaded)

        try FileManager.default.removeItem(at: fileURL)
        let recovered = SessionPinStore(fileURL: fileURL)
        XCTAssertEqual(recovered.snapshot().state, .recoveredFromLastKnownGood)
        XCTAssertEqual(recovered.pins(), ["stable"])
    }

    func testExplicitResetPreservesCorruptBytesBeforeStartingFresh() throws {
        try store.setPinned("stable", true)
        let corrupt = Data("{\"pins\":".utf8)
        try corrupt.write(to: fileURL)

        let preserved = try XCTUnwrap(store.resetPreservingUnreadableCatalog())

        XCTAssertEqual(try Data(contentsOf: preserved), corrupt)
        XCTAssertEqual(store.snapshot().state, .loaded)
        XCTAssertTrue(store.pins().isEmpty)
        try store.setPinned("fresh", true)
        XCTAssertEqual(SessionPinStore(fileURL: fileURL).pins(), ["fresh"])
    }

    @MainActor
    func testAppModelBoundaryReportsWriteFailureAndRetainsMemoryState() throws {
        try store.setPinned("stable", true)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        var surfaced: [String] = []

        let failedPin = AppModel.persistPinChange(
            terminalID: "unsaved",
            currentPins: ["stable"],
            store: store,
            reportFailure: { surfaced.append($0) }
        )
        let failedUnpin = AppModel.persistPinChange(
            terminalID: "stable",
            currentPins: ["stable"],
            store: store,
            reportFailure: { surfaced.append($0) }
        )

        XCTAssertNil(failedPin)
        XCTAssertNil(failedUnpin)
        XCTAssertEqual(SessionPinStore(fileURL: fileURL).pins(), ["stable"])
        XCTAssertEqual(surfaced.count, 2)
        XCTAssertTrue(surfaced.allSatisfy { $0.contains("could not save") })
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
