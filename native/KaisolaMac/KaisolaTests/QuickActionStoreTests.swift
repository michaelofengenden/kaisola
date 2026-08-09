import Foundation
import XCTest
@testable import Kaisola

/// QuickActionStore persistence against a throwaway file — per-project
/// round-trip across instances, the cap-8 oldest-first eviction, corrupt-file
/// degradation, and cross-project isolation.
final class QuickActionStoreTests: XCTestCase {
    private struct FixturePayload: Codable {
        var actionsByProject: [String: [QuickAction]]
    }

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

    func testRoundTripPerProjectAcrossInstances() throws {
        let actions = [
            QuickAction(id: "1", title: "Build", command: "npm run build"),
            QuickAction(id: "2", title: "Test", command: "npm test"),
        ]
        try store.save(actions, forProject: "nproj_alpha")

        // A fresh instance reads the same actions back, order preserved.
        let reopened = QuickActionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.actions(forProject: "nproj_alpha"), actions)
    }

    func testSaveReplacesWholesaleAndCanClear() throws {
        try store.save([QuickAction(id: "1", title: "Build", command: "make")], forProject: "p")
        try store.save([QuickAction(id: "2", title: "Dev", command: "npm run dev")], forProject: "p")
        XCTAssertEqual(store.actions(forProject: "p").map(\.id), ["2"])

        // Saving an empty array clears the project's row.
        try store.save([], forProject: "p")
        XCTAssertTrue(store.actions(forProject: "p").isEmpty)
    }

    func testUnknownProjectIsEmpty() {
        XCTAssertTrue(store.actions(forProject: "never-saved").isEmpty)
    }

    // MARK: - Cap (8 per project, drop oldest)

    func testSaveCapsAtEightDroppingOldest() throws {
        let actions = (0..<12).map { QuickAction(id: "a\($0)", title: "t\($0)", command: "c\($0)") }
        try store.save(actions, forProject: "p")

        let stored = store.actions(forProject: "p")
        XCTAssertEqual(stored.count, 8)
        // The four oldest (a0…a3) are evicted; a4…a11 survive in order.
        XCTAssertEqual(stored.map(\.id), (4..<12).map { "a\($0)" })
    }

    func testSaveExactlyEightKeepsAll() throws {
        let actions = (0..<8).map { QuickAction(id: "a\($0)", title: "t\($0)", command: "c\($0)") }
        try store.save(actions, forProject: "p")
        XCTAssertEqual(store.actions(forProject: "p").count, 8)
    }

    // MARK: - Stable identifiers

    func testLoadNormalizesDuplicateAndWhitespaceOnlyIdentifiersDeterministically() throws {
        let imported = [
            QuickAction(id: " duplicate ", title: "Build", command: "make"),
            QuickAction(id: "duplicate", title: "Test", command: "make test"),
            QuickAction(id: " \n ", title: "Deploy", command: "make deploy"),
            QuickAction(id: "quick-action-2", title: "Reserved", command: "make reserved"),
        ]
        try writeFixture(imported, forProject: "p")

        let firstLoad = store.actions(forProject: "p")
        let secondLoad = store.actions(forProject: "p")
        let reopenedLoad = QuickActionStore(fileURL: fileURL).actions(forProject: "p")

        XCTAssertEqual(
            firstLoad.map(\.id),
            ["duplicate", "quick-action-1", "quick-action-3", "quick-action-2"]
        )
        XCTAssertEqual(firstLoad.map(\.title), imported.map(\.title), "normalization must preserve every row and its order")
        XCTAssertEqual(secondLoad, firstLoad, "repeated loads must not churn synthesized row identity")
        XCTAssertEqual(reopenedLoad, firstLoad, "synthesized identity must be stable across store instances")
    }

    func testSavePersistsNormalizedIdentifiers() throws {
        try store.save(
            [
                QuickAction(id: "same", title: "First", command: "first"),
                QuickAction(id: "same", title: "Second", command: "second"),
                QuickAction(id: "", title: "Third", command: "third"),
            ],
            forProject: "p"
        )

        let persisted = try readFixture().actionsByProject["p"]
        XCTAssertEqual(persisted?.map(\.id), ["same", "quick-action-1", "quick-action-2"])
        XCTAssertEqual(Set(persisted?.map(\.id) ?? []).count, 3)
    }

    func testNormalizedIdentifierScopesEditingToExactlyOneRow() throws {
        try writeFixture(
            [
                QuickAction(id: "same", title: "First", command: "first"),
                QuickAction(id: "same", title: "Second", command: "second"),
                QuickAction(id: "", title: "Third", command: "third"),
            ],
            forProject: "p"
        )
        var actions = store.actions(forProject: "p")
        let editedID = try XCTUnwrap(actions.dropFirst().first?.id)
        let matchingRows = actions.indices.filter { actions[$0].id == editedID }

        XCTAssertEqual(matchingRows.count, 1)
        actions[try XCTUnwrap(matchingRows.first)].title = "Edited second"
        try store.save(actions, forProject: "p")

        let reopened = QuickActionStore(fileURL: fileURL).actions(forProject: "p")
        XCTAssertEqual(reopened.map(\.id), actions.map(\.id), "editing and saving must retain normalized row identity")
        XCTAssertEqual(reopened.map(\.title), ["First", "Edited second", "Third"])
    }

    // MARK: - Field validation

    func testValidationMeasuresTitleAndCommandLimitsInUTF8Bytes() {
        let exactTitle = String(repeating: "é", count: 64)
        let exactCommand = String(repeating: "🧪", count: 1_024)

        XCTAssertEqual(exactTitle.utf8.count, QuickAction.maximumTitleBytes)
        XCTAssertEqual(exactCommand.utf8.count, QuickAction.maximumCommandBytes)
        XCTAssertEqual(
            QuickAction(id: "exact", title: exactTitle, command: exactCommand).validationIssues,
            []
        )
        XCTAssertEqual(
            QuickAction(id: "title", title: exactTitle + "é", command: "make").validationIssues,
            [.titleTooLong(maximumBytes: QuickAction.maximumTitleBytes)]
        )
        XCTAssertEqual(
            QuickAction(id: "command", title: "Test", command: exactCommand + "🧪").validationIssues,
            [.commandTooLong(maximumBytes: QuickAction.maximumCommandBytes)]
        )
    }

    func testValidationRejectsWhitespaceOnlyFieldsAndControlCharacters() {
        XCTAssertEqual(
            QuickAction(id: "blank-title", title: "   ", command: "make").validationIssues,
            [.titleRequired]
        )
        XCTAssertEqual(
            QuickAction(id: "blank-command", title: "Build", command: " \u{00A0} ").validationIssues,
            [.commandRequired]
        )
        XCTAssertEqual(
            QuickAction(id: "title-control", title: "Build\u{0007}", command: "make").validationIssues,
            [.titleContainsControlCharacters]
        )
        XCTAssertEqual(
            QuickAction(id: "command-control", title: "Build", command: "make\ninstall").validationIssues,
            [.commandContainsControlCharacters]
        )
        XCTAssertEqual(
            QuickAction(
                id: "multiple-command-issues",
                title: "Build",
                command: String(repeating: "x", count: QuickAction.maximumCommandBytes) + "\n"
            ).validationIssues,
            [
                .commandTooLong(maximumBytes: QuickAction.maximumCommandBytes),
                .commandContainsControlCharacters,
            ],
            "independent defects in one field should be reported together"
        )
    }

    func testValidationIssuesProvideTruthfulRowSpecificCopy() {
        XCTAssertEqual(QuickAction.ValidationIssue.titleRequired.errorDescription, "Enter a title.")
        XCTAssertEqual(
            QuickAction.ValidationIssue.titleTooLong(maximumBytes: 128).errorDescription,
            "Title must be 128 UTF-8 bytes or fewer."
        )
        XCTAssertEqual(
            QuickAction.ValidationIssue.titleContainsControlCharacters.errorDescription,
            "Title must stay on one line and cannot contain control characters."
        )
        XCTAssertEqual(QuickAction.ValidationIssue.commandRequired.errorDescription, "Enter a command.")
        XCTAssertEqual(
            QuickAction.ValidationIssue.commandTooLong(maximumBytes: 4_096).errorDescription,
            "Command must be 4096 UTF-8 bytes or fewer."
        )
        XCTAssertEqual(
            QuickAction.ValidationIssue.commandContainsControlCharacters.errorDescription,
            "Command must stay on one line and cannot contain control characters."
        )
    }

    func testInvalidSavePreservesTheLastValidRegistryByteForByte() throws {
        try store.save(
            [QuickAction(id: "valid", title: "Build", command: "make")],
            forProject: "p"
        )
        let original = try Data(contentsOf: fileURL)
        let invalid = QuickAction(id: "invalid", title: " ", command: "make\ninstall")

        XCTAssertThrowsError(try store.save([invalid], forProject: "p")) { error in
            XCTAssertEqual(
                error as? QuickActionStore.StoreError,
                .invalidActions([
                    .init(
                        index: 0,
                        actionID: "invalid",
                        issues: [.titleRequired, .commandContainsControlCharacters]
                    ),
                ])
            )
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(store.actions(forProject: "p").map(\.id), ["valid"])
    }

    func testLegacyInvalidRowsAreQuarantinedFromExecutionButRemainRepairable() throws {
        let imported = [
            QuickAction(id: "valid", title: "Build", command: "make"),
            QuickAction(id: "blank", title: "   ", command: "npm test"),
            QuickAction(id: "control", title: "Deploy", command: "make\rdeploy"),
            QuickAction(
                id: "oversized",
                title: "Run checks",
                command: String(repeating: "🧪", count: 1_025)
            ),
        ]
        try writeFixture(imported, forProject: "p")

        let loaded = store.load(forProject: "p")

        XCTAssertEqual(loaded.rows.map(\.action), imported)
        XCTAssertEqual(loaded.runnableActions.map(\.id), ["valid"])
        XCTAssertEqual(loaded.quarantinedRows.map(\.action.id), ["blank", "control", "oversized"])
        XCTAssertEqual(
            loaded.quarantinedRows.map(\.issues),
            [
                [.titleRequired],
                [.commandContainsControlCharacters],
                [.commandTooLong(maximumBytes: QuickAction.maximumCommandBytes)],
            ]
        )
        XCTAssertEqual(
            store.actions(forProject: "p").map(\.id),
            ["valid"],
            "legacy-invalid commands must never reach the bar, palette, or terminal"
        )

        var repaired = loaded.rows.map(\.action)
        repaired[1].title = "Test"
        repaired[2].command = "make deploy"
        repaired[3].command = "npm run checks"
        try store.save(repaired, forProject: "p")

        let reopened = QuickActionStore(fileURL: fileURL).load(forProject: "p")
        XCTAssertEqual(reopened.runnableActions, repaired)
        XCTAssertTrue(reopened.quarantinedRows.isEmpty)
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

    func testProjectsAreIsolated() throws {
        try store.save([QuickAction(id: "1", title: "A", command: "a")], forProject: "projA")
        try store.save([QuickAction(id: "2", title: "B", command: "b")], forProject: "projB")

        XCTAssertEqual(store.actions(forProject: "projA").map(\.id), ["1"])
        XCTAssertEqual(store.actions(forProject: "projB").map(\.id), ["2"])
        XCTAssertTrue(store.actions(forProject: "projC").isEmpty)

        // Overwriting one project leaves the other untouched.
        try store.save([QuickAction(id: "3", title: "A2", command: "a2")], forProject: "projA")
        XCTAssertEqual(store.actions(forProject: "projA").map(\.id), ["3"])
        XCTAssertEqual(store.actions(forProject: "projB").map(\.id), ["2"])

        // Clearing one project leaves the other untouched.
        try store.save([], forProject: "projA")
        XCTAssertTrue(store.actions(forProject: "projA").isEmpty)
        XCTAssertEqual(store.actions(forProject: "projB").map(\.id), ["2"])
    }

    private func writeFixture(_ actions: [QuickAction], forProject projectID: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = FixturePayload(actionsByProject: [projectID: actions])
        try JSONEncoder().encode(payload).write(to: fileURL)
    }

    private func readFixture() throws -> FixturePayload {
        try JSONDecoder().decode(FixturePayload.self, from: Data(contentsOf: fileURL))
    }
}
