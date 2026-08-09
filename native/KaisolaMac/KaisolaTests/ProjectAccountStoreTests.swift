import Foundation
import XCTest
@testable import Kaisola

/// ProjectAccountStore persistence + the pure `mergedOverlay` precedence rules.
/// Uses a throwaway file so it never touches the real per-project accounts:
/// set/read round-trip, remove-on-both-blank, cross-project isolation, fail-closed
/// recovery, and the full app-vs-project merge matrix (project wins per key,
/// blank falls back, tilde expands).
final class ProjectAccountStoreTests: XCTestCase {
    private var fileURL: URL!
    private var store: ProjectAccountStore!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-project-accounts-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("project-accounts.json")
        store = ProjectAccountStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    // MARK: - Persistence round-trip

    func testSetReadRoundTripAcrossInstances() throws {
        try store.set(ProjectAccountOverride(claudeConfigDir: "~/claude-a", codexHome: "~/codex-a"),
                      forProject: "nproj_a")

        let reopened = ProjectAccountStore(fileURL: fileURL)
        XCTAssertEqual(
            try reopened.override(forProject: "nproj_a"),
            ProjectAccountOverride(claudeConfigDir: "~/claude-a", codexHome: "~/codex-a")
        )
    }

    /// Only one field set persists as a partial override (the other stays nil),
    /// and the stored value is trimmed but NOT tilde-expanded (so the settings
    /// field can show "~/…" back to the user).
    func testPartialOverrideIsTrimmedNotExpanded() throws {
        try store.set(ProjectAccountOverride(claudeConfigDir: "  ~/claude  ", codexHome: nil),
                      forProject: "nproj_a")

        XCTAssertEqual(
            try store.override(forProject: "nproj_a"),
            ProjectAccountOverride(claudeConfigDir: "~/claude", codexHome: nil)
        )
    }

    // MARK: - Removal

    func testBothBlankRemovesEntry() throws {
        try store.set(ProjectAccountOverride(claudeConfigDir: "~/x", codexHome: "~/y"), forProject: "nproj_a")
        XCTAssertNotNil(try store.override(forProject: "nproj_a"))

        // Both fields blank (nil / whitespace) collapse to "no override" → removed.
        try store.set(ProjectAccountOverride(claudeConfigDir: "   ", codexHome: nil), forProject: "nproj_a")
        XCTAssertNil(try store.override(forProject: "nproj_a"))

        // The removal is durable.
        XCTAssertNil(try ProjectAccountStore(fileURL: fileURL).override(forProject: "nproj_a"))
    }

    func testNilOverrideRemovesEntry() throws {
        try store.set(ProjectAccountOverride(claudeConfigDir: "~/x", codexHome: nil), forProject: "nproj_a")
        try store.set(nil, forProject: "nproj_a")
        XCTAssertNil(try store.override(forProject: "nproj_a"))
    }

    func testRemovingUnknownIsHarmless() throws {
        try store.set(nil, forProject: "never-set")
        XCTAssertNil(try store.override(forProject: "never-set"))
    }

    // MARK: - Cross-project isolation

    func testOverridesAreScopedPerProjectAndIndependent() throws {
        try store.set(ProjectAccountOverride(claudeConfigDir: "~/a", codexHome: nil), forProject: "nproj_a")
        try store.set(ProjectAccountOverride(claudeConfigDir: nil, codexHome: "~/b"), forProject: "nproj_b")

        XCTAssertEqual(try store.override(forProject: "nproj_a")?.claudeConfigDir, "~/a")
        XCTAssertNil(try store.override(forProject: "nproj_a")?.codexHome)
        XCTAssertEqual(try store.override(forProject: "nproj_b")?.codexHome, "~/b")
        XCTAssertNil(try store.override(forProject: "nproj_b")?.claudeConfigDir)

        // Removing one leaves the other intact.
        try store.set(nil, forProject: "nproj_a")
        XCTAssertNil(try store.override(forProject: "nproj_a"))
        XCTAssertEqual(try store.override(forProject: "nproj_b")?.codexHome, "~/b")
    }

    // MARK: - Fail-closed recovery

    func testMissingFileIsDistinctAndAllowsAppDefaultLaunch() throws {
        XCTAssertEqual(store.loadStatus(), .missing)
        XCTAssertEqual(
            try store.launchOverlay(
                app: ["CLAUDE_CONFIG_DIR": "/app/claude"],
                forProject: "nproj_a"
            ).get(),
            ["CLAUDE_CONFIG_DIR": "/app/claude"]
        )
    }

    func testCorruptFileBlocksLaunchPreservesExactBytesAndRefusesOrdinarySet() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = Data("not json\nkeep every byte".utf8)
        try original.write(to: fileURL)

        guard case .blocked(let issue) = store.loadStatus() else {
            return XCTFail("Corrupt configured data must not become an empty store")
        }
        XCTAssertEqual(issue.kind, .corrupt)
        let preserved = try XCTUnwrap(issue.preservedCopyURL)
        XCTAssertEqual(try Data(contentsOf: preserved), original)
        XCTAssertEqual(try Data(contentsOf: fileURL), original, "ordinary reads never alter the source")

        guard case .failure(let launchIssue) = store.launchOverlay(
            app: ["CLAUDE_CONFIG_DIR": "/wrong/app-wide"],
            forProject: "nproj_a"
        ) else { return XCTFail("Corruption must block the launch overlay") }
        XCTAssertEqual(launchIssue.kind, .corrupt)

        XCTAssertThrowsError(
            try store.set(
                ProjectAccountOverride(claudeConfigDir: "~/replacement", codexHome: nil),
                forProject: "nproj_a"
            )
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testUnsupportedVersionBlocksLaunchAndLeavesSourceUntouched() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = Data(#"{"schemaVersion":999,"projects":{"nproj_a":{"claudeConfigDir":"/future"}}}"#.utf8)
        try original.write(to: fileURL)

        guard case .blocked(let issue) = store.loadStatus() else {
            return XCTFail("A newer account schema must fail closed")
        }
        XCTAssertEqual(issue.kind, .unsupportedVersion(found: 999))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(issue.preservedCopyURL)), original)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertThrowsError(
            try store.launchOverlay(app: ["CODEX_HOME": "/wrong/app-wide"], forProject: "nproj_a").get()
        )
    }

    func testUnreadableFileIsDistinctFromMissingAndCorrupt() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("opaque".utf8).write(to: fileURL)
        struct ExpectedReadFailure: Error {}
        let unreadable = ProjectAccountStore(
            fileURL: fileURL,
            dataReader: { _ in throw ExpectedReadFailure() }
        )

        guard case .blocked(let issue) = unreadable.loadStatus() else {
            return XCTFail("An existing unreadable file must not be reported missing")
        }
        guard case .unreadable = issue.kind else {
            return XCTFail("Expected unreadable, got \(issue.kind)")
        }
        XCTAssertNil(issue.preservedCopyURL)
        XCTAssertThrowsError(
            try unreadable.launchOverlay(app: ["CODEX_HOME": "/wrong/app-wide"], forProject: "nproj_a").get()
        )
    }

    func testPreservationDiskWriteFailureStillBlocksLaunchAndKeepsOriginal() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = Data("damaged bytes".utf8)
        try original.write(to: fileURL)
        struct ExpectedDiskFailure: Error {}
        let unwritableRecovery = ProjectAccountStore(
            fileURL: fileURL,
            preservationWriter: { _, _ in throw ExpectedDiskFailure() }
        )

        guard case .failure(let issue) = unwritableRecovery.launchOverlay(
            app: ["CLAUDE_CONFIG_DIR": "/wrong/app-wide"],
            forProject: "nproj_a"
        ) else { return XCTFail("A failed recovery write must still fail closed") }
        XCTAssertEqual(issue.kind, .corrupt)
        XCTAssertNil(issue.preservedCopyURL)
        XCTAssertNotNil(issue.preservationError)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testExplicitResetMovesUnreadableSourceIntactBeforeClearingActivePath() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = Data("bytes the injected reader cannot access".utf8)
        try original.write(to: fileURL)
        struct ExpectedReadFailure: Error {}
        let unreadable = ProjectAccountStore(
            fileURL: fileURL,
            dataReader: { _ in throw ExpectedReadFailure() }
        )
        guard case .blocked(let issue) = unreadable.loadStatus() else {
            return XCTFail("Expected unreadable recovery issue")
        }
        XCTAssertNil(issue.preservedCopyURL)

        let preserved = try unreadable.resetAfterFailure(expectedIssue: issue)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: preserved), original)
    }

    func testExplicitResetKeepsPreservedCopyAndOnlyThenAllowsAppDefault() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = Data("damaged bytes to retain".utf8)
        try original.write(to: fileURL)
        guard case .blocked(let issue) = store.loadStatus() else {
            return XCTFail("Expected recovery issue")
        }
        let firstPreserved = try XCTUnwrap(issue.preservedCopyURL)

        let resetCopy = try store.resetAfterFailure(expectedIssue: issue)

        XCTAssertEqual(resetCopy, firstPreserved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: firstPreserved), original)
        XCTAssertEqual(
            try store.launchOverlay(app: ["CODEX_HOME": "/app/codex"], forProject: "nproj_a").get(),
            ["CODEX_HOME": "/app/codex"]
        )
    }

    func testResetAbortsWhenAnotherProcessReplacesSourceAfterPreservation() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let original = Data("first corrupt bytes".utf8)
        try original.write(to: fileURL)
        guard case .blocked(let initialIssue) = store.loadStatus() else {
            return XCTFail("Expected initial recovery issue")
        }
        let initialCopy = try XCTUnwrap(initialIssue.preservedCopyURL)
        let replacement = Data("different corrupt bytes from another process".utf8)
        try replacement.write(to: fileURL)

        XCTAssertThrowsError(try store.resetAfterFailure(expectedIssue: initialIssue)) { error in
            XCTAssertEqual(error as? ProjectAccountStore.StoreError, .recoveryChanged)
        }

        XCTAssertEqual(try Data(contentsOf: fileURL), replacement)
        XCTAssertEqual(try Data(contentsOf: initialCopy), original)
    }

    // MARK: - mergedOverlay precedence matrix

    func testMergedOverlayNilProjectReturnsAppUnchanged() {
        let app = ["CLAUDE_CONFIG_DIR": "/app/claude", "CODEX_HOME": "/app/codex", "OTHER": "keep"]
        XCTAssertEqual(ProjectAccountStore.mergedOverlay(app: app, project: nil), app)
    }

    func testMergedOverlayEmptyProjectFallsBackToApp() {
        let app = ["CLAUDE_CONFIG_DIR": "/app/claude", "CODEX_HOME": "/app/codex"]
        // Both fields blank/whitespace → both keys fall back to the app values.
        let project = ProjectAccountOverride(claudeConfigDir: "   ", codexHome: nil)
        XCTAssertEqual(ProjectAccountStore.mergedOverlay(app: app, project: project), app)
    }

    func testMergedOverlayProjectWinsPerKeyIndependently() {
        let app = ["CLAUDE_CONFIG_DIR": "/app/claude", "CODEX_HOME": "/app/codex", "ANTHROPIC_API_KEY": "sk-x"]
        // Project overrides only Claude; Codex + the API key fall back to the app.
        let project = ProjectAccountOverride(claudeConfigDir: "/proj/claude", codexHome: "  ")
        let merged = ProjectAccountStore.mergedOverlay(app: app, project: project)

        XCTAssertEqual(merged["CLAUDE_CONFIG_DIR"], "/proj/claude")   // project wins
        XCTAssertEqual(merged["CODEX_HOME"], "/app/codex")           // blank → app
        XCTAssertEqual(merged["ANTHROPIC_API_KEY"], "sk-x")          // untouched
    }

    func testMergedOverlayIntoEmptyAppOnlyHasProjectKeys() {
        let project = ProjectAccountOverride(claudeConfigDir: "/proj/claude", codexHome: nil)
        let merged = ProjectAccountStore.mergedOverlay(app: [:], project: project)

        XCTAssertEqual(merged, ["CLAUDE_CONFIG_DIR": "/proj/claude"])
        XCTAssertNil(merged["CODEX_HOME"])
    }

    func testMergedOverlayExpandsTilde() {
        let project = ProjectAccountOverride(claudeConfigDir: "~/claude", codexHome: "~/codex")
        let merged = ProjectAccountStore.mergedOverlay(app: [:], project: project)

        XCTAssertEqual(merged["CLAUDE_CONFIG_DIR"], ("~/claude" as NSString).expandingTildeInPath)
        XCTAssertEqual(merged["CODEX_HOME"], ("~/codex" as NSString).expandingTildeInPath)
        // Expansion actually happened (no leading tilde survives).
        XCTAssertEqual(merged["CLAUDE_CONFIG_DIR"]?.hasPrefix("~"), false)
    }

    func testMergedOverlayTrimsProjectValueBeforeUse() {
        let merged = ProjectAccountStore.mergedOverlay(
            app: [:],
            project: ProjectAccountOverride(claudeConfigDir: "  /proj/claude  ", codexHome: nil)
        )
        XCTAssertEqual(merged["CLAUDE_CONFIG_DIR"], "/proj/claude")
    }
}
