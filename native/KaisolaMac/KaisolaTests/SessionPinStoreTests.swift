import Foundation
import XCTest
@testable import Kaisola

/// SessionPinStore persistence against a throwaway file — set/unset round-trip
/// across instances, insertion-order cap eviction, and what happens when the
/// file underneath it is missing, damaged, or half-written — plus the pure
/// `AppModel.pinnedOrder` ordering that drives `pinnedSort`.
final class SessionPinStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private var store: SessionPinStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-pins-\(UUID().uuidString.prefix(8))", isDirectory: true)
        fileURL = directory.appendingPathComponent("session-pins.json")
        store = SessionPinStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        // A permissions test may have left the directory unwritable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeRawFile(_ contents: String) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
    }

    // MARK: - Persistence

    func testSetUnsetRoundTripAcrossInstances() throws {
        try store.setPinned("term-a", true)
        try store.setPinned("term-b", true)

        let reopened = SessionPinStore(fileURL: fileURL)
        XCTAssertTrue(reopened.isPinned("term-a"))
        XCTAssertTrue(reopened.isPinned("term-b"))
        XCTAssertEqual(reopened.load().pins, ["term-a", "term-b"])

        // Unpinning is durable too.
        try reopened.setPinned("term-a", false)
        let again = SessionPinStore(fileURL: fileURL)
        XCTAssertFalse(again.isPinned("term-a"))
        XCTAssertEqual(again.load().pins, ["term-b"])
    }

    func testPinIsIdempotent() throws {
        try store.setPinned("x", true)
        try store.setPinned("x", true)
        XCTAssertEqual(store.load().pins, ["x"])
    }

    func testUnpinUnknownIsNoOp() throws {
        try store.setPinned("present", true)
        try store.setPinned("absent", false)   // never pinned
        XCTAssertEqual(store.load().pins, ["present"])
    }

    // MARK: - Cap

    func testCapEvictsOldestByInsertionOrder() throws {
        for index in 0..<105 { try store.setPinned("s\(index)", true) }
        XCTAssertEqual(store.load().pins?.count, 100)
        // The five oldest pins (s0…s4) are evicted; s5…s104 survive.
        for index in 0..<5 { XCTAssertFalse(store.isPinned("s\(index)")) }
        for index in 5..<105 { XCTAssertTrue(store.isPinned("s\(index)")) }
    }

    // MARK: - Missing file

    /// No file yet is a first launch, not damage: an empty set, no failure, and
    /// pinning works straight away.
    func testMissingFileIsBenignAndDistinctFromCorruption() throws {
        XCTAssertEqual(store.load(), .missing)
        XCTAssertEqual(store.load().pins, [])
        XCTAssertNil(store.load().failure)
        XCTAssertFalse(store.isPinned("anything"))

        try store.setPinned("term-a", true)
        XCTAssertEqual(store.load(), .loaded(["term-a"]))
    }

    // MARK: - Corrupt file

    func testCorruptFileIsReportedRatherThanReadAsEmpty() throws {
        try writeRawFile("not json")

        XCTAssertEqual(store.load(), .failed(.corrupt))
        // Nil, not []: the caller keeps whatever pins it already knew.
        XCTAssertNil(store.load().pins)
        XCTAssertEqual(store.load().failure, .corrupt)
    }

    func testPinningNeverOverwritesACorruptFile() throws {
        try writeRawFile("not json")

        XCTAssertThrowsError(try store.setPinned("term-a", true)) { error in
            XCTAssertEqual(
                error as? SessionPinStore.WriteFailure,
                .wouldOverwriteUnreadableFile(.corrupt)
            )
        }
        // Unpinning is a write too, and must not clear the file either.
        XCTAssertThrowsError(try store.setPinned("term-a", false))

        XCTAssertEqual(try Data(contentsOf: fileURL), Data("not json".utf8))
    }

    func testExplicitResetKeepsTheDamagedBytesBesideTheOriginal() throws {
        try writeRawFile("not json")

        let preserved = try store.resetPreservingUnreadableFile()
        guard case .movedAside(let keptURL) = preserved else {
            return XCTFail("expected the damaged file to be kept, got \(preserved)")
        }
        XCTAssertNotEqual(keptURL.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertTrue(keptURL.lastPathComponent.contains("corrupt"))
        XCTAssertEqual(try Data(contentsOf: keptURL), Data("not json".utf8))

        // The path is clear, so pinning works again from an empty base.
        XCTAssertEqual(store.load(), .missing)
        try store.setPinned("term-a", true)
        XCTAssertEqual(store.load().pins, ["term-a"])
    }

    func testResetWithNothingOnDiskSaysSo() throws {
        XCTAssertEqual(try store.resetPreservingUnreadableFile(), .nothingToPreserve)
    }

    // MARK: - Interrupted writes

    /// A write that cannot land leaves the previous pins byte-for-byte and says
    /// so, instead of reporting a pin that never happened.
    func testInterruptedWriteKeepsPreviousPinsAndReportsTheFailure() throws {
        try store.setPinned("term-a", true)
        let before = try Data(contentsOf: fileURL)

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

        XCTAssertThrowsError(try store.setPinned("term-b", true)) { error in
            guard let failure = error as? SessionPinStore.WriteFailure else {
                return XCTFail("expected a store failure, got \(error)")
            }
            switch failure {
            case .notPersisted(let reason):
                XCTAssertFalse(reason.isEmpty)
            case .wouldOverwriteUnreadableFile:
                XCTFail("the file is readable; the write itself is what failed")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        XCTAssertEqual(store.load().pins, ["term-a"])
    }

    /// The scratch file an interrupted write leaves behind is not pins: it must
    /// never be read as state, and the next write must still succeed.
    func testLeftoverScratchFileIsNotReadAsPins() throws {
        try store.setPinned("term-a", true)
        let scratch = SessionPinStore.scratchURL(
            for: fileURL,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        try Data("{\"pins\":[\"term-ghost\"".utf8).write(to: scratch)

        XCTAssertEqual(store.load(), .loaded(["term-a"]))

        try store.setPinned("term-b", true)
        XCTAssertEqual(store.load(), .loaded(["term-a", "term-b"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    // MARK: - AppModel: last-known-good pins and relaunch

    @MainActor
    private func makeModel() -> AppModel {
        AppModel(
            sessionStore: NativeSessionStore(
                fileURL: directory.appendingPathComponent("native-sessions.json")
            ),
            workspaceStateStore: NativeWorkspaceStateStore(
                fileURL: directory.appendingPathComponent("workspace-state-v1.json")
            ),
            pinStore: store
        )
    }

    /// Damage that appears while the app is running must not unpin the rows on
    /// screen, and the pin the user clicks next must not write that emptiness
    /// back over the file.
    @MainActor
    func testUnreadableFileKeepsTheLastKnownGoodPinsOnScreen() throws {
        try store.setPinned("term-a", true)
        let model = makeModel()
        XCTAssertEqual(model.persistedPinnedIDs, ["term-a"])
        XCTAssertNil(model.pinsUnreadable)

        try writeRawFile("not json")
        model.refreshPersistedNavigationState()

        XCTAssertEqual(model.persistedPinnedIDs, ["term-a"])
        XCTAssertEqual(model.pinsUnreadable, .corrupt)

        model.togglePin("term-b")
        XCTAssertEqual(model.persistedPinnedIDs, ["term-a"])
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("not json".utf8))
    }

    /// Relaunching against a damaged file: pins are gone from the window but
    /// not from disk, pinning stays blocked, and the explicit reset is what
    /// makes it work again.
    @MainActor
    func testRelaunchOnADamagedFileBlocksPinsUntilAnExplicitReset() throws {
        let firstLaunch = makeModel()
        firstLaunch.togglePin("term-a")
        XCTAssertEqual(firstLaunch.persistedPinnedIDs, ["term-a"])

        try writeRawFile("not json")

        let relaunch = makeModel()
        XCTAssertEqual(relaunch.pinsUnreadable, .corrupt)
        XCTAssertTrue(relaunch.persistedPinnedIDs.isEmpty)

        relaunch.togglePin("term-b")
        XCTAssertTrue(relaunch.persistedPinnedIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("not json".utf8))

        relaunch.resetUnreadablePins()
        XCTAssertNil(relaunch.pinsUnreadable)
        let kept = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("corrupt") }
        XCTAssertEqual(kept.count, 1, "the damaged bytes are kept beside the original")

        relaunch.togglePin("term-b")
        XCTAssertEqual(relaunch.persistedPinnedIDs, ["term-b"])
        XCTAssertEqual(store.load(), .loaded(["term-b"]))
    }

    func testPinFailureMessageNamesTheCause() {
        XCTAssertEqual(
            AppModel.pinFailureMessage(
                for: SessionPinStore.WriteFailure.wouldOverwriteUnreadableFile(.corrupt)
            ),
            "Pinned sessions can't be saved because the saved pins file is damaged."
        )
        XCTAssertTrue(
            AppModel.pinFailureMessage(
                for: SessionPinStore.WriteFailure.notPersisted(reason: "disk is full")
            ).contains("disk is full")
        )
        // An error from outside the store still reaches the user in words.
        XCTAssertFalse(
            AppModel.pinFailureMessage(for: CocoaError(.fileWriteUnknown)).isEmpty
        )
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
