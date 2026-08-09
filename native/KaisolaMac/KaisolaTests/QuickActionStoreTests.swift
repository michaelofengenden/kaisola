import Foundation
import XCTest
@testable import Kaisola

/// QuickActionStore persistence against a throwaway file — per-project
/// round-trip across instances, the cap-8 oldest-first eviction, corrupt-file
/// degradation, cross-project isolation, and id normalization for hand-edited
/// or imported files that repeat (or blank) an action id.
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

    // MARK: - Id normalization (duplicate / blank ids)

    func testDuplicateIdsInFileAreMadeUniqueOnLoad() throws {
        try writeFixture(project: "p", rows: [
            ("row", "Build", "make"),
            ("row", "Test", "npm test"),
            ("row", "Dev", "npm run dev"),
        ])

        let loaded = store.actions(forProject: "p")
        // Every row survives, in order, with its title and command intact — the
        // first occurrence keeps the original id and the repeats get suffixes.
        XCTAssertEqual(loaded.map(\.id), ["row", "row-2", "row-3"])
        XCTAssertEqual(loaded.map(\.title), ["Build", "Test", "Dev"])
        XCTAssertEqual(loaded.map(\.command), ["make", "npm test", "npm run dev"])
    }

    func testSuffixedIdCollisionProbesPastAnExistingId() throws {
        try writeFixture(project: "p", rows: [
            ("row", "Build", "make"),
            ("row-2", "Test", "npm test"),
            ("row", "Dev", "npm run dev"),
        ])

        // "row" repeats, but "row-2" is already taken, so the repair probes on.
        XCTAssertEqual(store.actions(forProject: "p").map(\.id), ["row", "row-2", "row-3"])
    }

    func testBlankIdsInFileGetSlotDerivedIds() throws {
        try writeFixture(project: "p", rows: [
            ("", "Build", "make"),
            ("   ", "Test", "npm test"),
        ])

        let loaded = store.actions(forProject: "p")
        XCTAssertEqual(loaded.map(\.id), ["action-0", "action-1"])
        XCTAssertEqual(loaded.map(\.title), ["Build", "Test"])
    }

    func testWhitespacePaddedIdIsTrimmedAndStaysDistinct() throws {
        try writeFixture(project: "p", rows: [
            ("row", "Build", "make"),
            ("  row  ", "Test", "npm test"),
        ])

        // The padded id trims down to a repeat, so it is suffixed rather than
        // left to masquerade as a second identity for the same row.
        XCTAssertEqual(store.actions(forProject: "p").map(\.id), ["row", "row-2"])
    }

    func testNormalizationIsStableAcrossLoads() throws {
        try writeFixture(project: "p", rows: [
            ("row", "Build", "make"),
            ("row", "Test", "npm test"),
            ("", "Dev", "npm run dev"),
        ])

        let first = store.actions(forProject: "p").map(\.id)
        let second = QuickActionStore(fileURL: fileURL).actions(forProject: "p").map(\.id)
        XCTAssertEqual(first, second)
    }

    func testUniqueIdsAreLeftAlone() {
        let actions = [
            QuickAction(id: "b", title: "Build", command: "make"),
            QuickAction(id: "a", title: "Test", command: "npm test"),
        ]
        store.save(actions, forProject: "p")
        XCTAssertEqual(store.actions(forProject: "p"), actions)
    }

    // MARK: - Stable row editing over a duplicate-id fixture

    func testEditingOneRowLeavesItsDuplicateTwinAlone() throws {
        try writeFixture(project: "p", rows: [
            ("row", "Build", "make"),
            ("row", "Test", "npm test"),
        ])

        var rows = store.actions(forProject: "p")
        let secondRowID = rows[1].id
        rows = editingCommand(ofRow: secondRowID, to: "npm test -- --watch", in: rows)

        // The edit landed on the row the user pointed at, not on its twin.
        XCTAssertEqual(rows.map(\.command), ["make", "npm test -- --watch"])

        store.save(rows, forProject: "p")
        let reloaded = store.actions(forProject: "p")
        XCTAssertEqual(reloaded.map(\.title), ["Build", "Test"])
        XCTAssertEqual(reloaded.map(\.command), ["make", "npm test -- --watch"])
    }

    func testDeletingOneRowDoesNotTakeItsDuplicateTwinWithIt() throws {
        try writeFixture(project: "p", rows: [
            ("row", "Build", "make"),
            ("row", "Test", "npm test"),
        ])

        var rows = store.actions(forProject: "p")
        rows = deletingRow(id: rows[1].id, from: rows)

        XCTAssertEqual(rows.map(\.title), ["Build"])

        store.save(rows, forProject: "p")
        XCTAssertEqual(store.actions(forProject: "p").map(\.title), ["Build"])
    }

    // MARK: - Save repairs the file, not just the read

    func testSaveWritesUniqueIdsToDisk() throws {
        store.save([
            QuickAction(id: "dup", title: "Build", command: "make"),
            QuickAction(id: "dup", title: "Test", command: "npm test"),
            QuickAction(id: "", title: "Dev", command: "npm run dev"),
        ], forProject: "p")

        // Read the raw file: normalization has to reach the bytes on disk so a
        // repaired row stays repaired for anything else reading the file.
        XCTAssertEqual(try storedIDs(project: "p"), ["dup", "dup-2", "action-2"])
    }

    func testSaveNormalizesAfterTheCapSoEightRowsStayDistinct() throws {
        let actions = (0..<12).map { QuickAction(id: "same", title: "t\($0)", command: "c\($0)") }
        store.save(actions, forProject: "p")

        let stored = try storedIDs(project: "p")
        XCTAssertEqual(stored.count, 8)
        XCTAssertEqual(Set(stored).count, 8)
    }

    // MARK: - Helpers

    /// Writes a hand-edited-looking file straight to disk, the way an import or
    /// a text editor would, so the load path sees ids the app never minted.
    private func writeFixture(project: String, rows: [(id: String, title: String, command: String)]) throws {
        let encoded = rows.map { row in
            ["id": row.id, "title": row.title, "command": row.command]
        }
        let json = try JSONSerialization.data(withJSONObject: ["actionsByProject": [project: encoded]])
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try json.write(to: fileURL)
    }

    /// The ids as they sit in the file, bypassing the store's read-side repair.
    private func storedIDs(project: String) throws -> [String] {
        let data = try Data(contentsOf: fileURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let byProject = object?["actionsByProject"] as? [String: Any]
        let rows = byProject?[project] as? [[String: Any]] ?? []
        return rows.compactMap { $0["id"] as? String }
    }

    /// Mirrors `QuickActionsEditor`'s row binding: the edit is routed by id, so
    /// a repeated id sends it to whichever row matches first.
    private func editingCommand(ofRow id: String, to command: String, in actions: [QuickAction]) -> [QuickAction] {
        var edited = actions
        if let index = edited.firstIndex(where: { $0.id == id }) {
            edited[index].command = command
        }
        return edited
    }

    /// Mirrors `QuickActionsEditor.delete(_:)`.
    private func deletingRow(id: String, from actions: [QuickAction]) -> [QuickAction] {
        var remaining = actions
        remaining.removeAll { $0.id == id }
        return remaining
    }
}
