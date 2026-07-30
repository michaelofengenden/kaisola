import Foundation
import XCTest
@testable import Kaisola

/// ProjectAccountStore persistence + the pure `mergedOverlay` precedence rules.
/// Uses a throwaway file so it never touches the real per-project accounts:
/// set/read round-trip, remove-on-both-blank, cross-project isolation, corrupt
/// degradation, and the full app-vs-project merge matrix (project wins per key,
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

    func testSetReadRoundTripAcrossInstances() {
        store.set(ProjectAccountOverride(claudeConfigDir: "~/claude-a", codexHome: "~/codex-a"),
                  forProject: "nproj_a")

        let reopened = ProjectAccountStore(fileURL: fileURL)
        XCTAssertEqual(
            reopened.override(forProject: "nproj_a"),
            ProjectAccountOverride(claudeConfigDir: "~/claude-a", codexHome: "~/codex-a")
        )
    }

    /// Only one field set persists as a partial override (the other stays nil),
    /// and the stored value is trimmed but NOT tilde-expanded (so the settings
    /// field can show "~/…" back to the user).
    func testPartialOverrideIsTrimmedNotExpanded() {
        store.set(ProjectAccountOverride(claudeConfigDir: "  ~/claude  ", codexHome: nil),
                  forProject: "nproj_a")

        XCTAssertEqual(
            store.override(forProject: "nproj_a"),
            ProjectAccountOverride(claudeConfigDir: "~/claude", codexHome: nil)
        )
    }

    // MARK: - Removal

    func testBothBlankRemovesEntry() {
        store.set(ProjectAccountOverride(claudeConfigDir: "~/x", codexHome: "~/y"), forProject: "nproj_a")
        XCTAssertNotNil(store.override(forProject: "nproj_a"))

        // Both fields blank (nil / whitespace) collapse to "no override" → removed.
        store.set(ProjectAccountOverride(claudeConfigDir: "   ", codexHome: nil), forProject: "nproj_a")
        XCTAssertNil(store.override(forProject: "nproj_a"))

        // The removal is durable.
        XCTAssertNil(ProjectAccountStore(fileURL: fileURL).override(forProject: "nproj_a"))
    }

    func testNilOverrideRemovesEntry() {
        store.set(ProjectAccountOverride(claudeConfigDir: "~/x", codexHome: nil), forProject: "nproj_a")
        store.set(nil, forProject: "nproj_a")
        XCTAssertNil(store.override(forProject: "nproj_a"))
    }

    func testRemovingUnknownIsHarmless() {
        store.set(nil, forProject: "never-set")
        XCTAssertNil(store.override(forProject: "never-set"))
    }

    // MARK: - Cross-project isolation

    func testOverridesAreScopedPerProjectAndIndependent() {
        store.set(ProjectAccountOverride(claudeConfigDir: "~/a", codexHome: nil), forProject: "nproj_a")
        store.set(ProjectAccountOverride(claudeConfigDir: nil, codexHome: "~/b"), forProject: "nproj_b")

        XCTAssertEqual(store.override(forProject: "nproj_a")?.claudeConfigDir, "~/a")
        XCTAssertNil(store.override(forProject: "nproj_a")?.codexHome)
        XCTAssertEqual(store.override(forProject: "nproj_b")?.codexHome, "~/b")
        XCTAssertNil(store.override(forProject: "nproj_b")?.claudeConfigDir)

        // Removing one leaves the other intact.
        store.set(nil, forProject: "nproj_a")
        XCTAssertNil(store.override(forProject: "nproj_a"))
        XCTAssertEqual(store.override(forProject: "nproj_b")?.codexHome, "~/b")
    }

    // MARK: - Corrupt file

    func testCorruptFileDegradesToNoOverride() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertNil(store.override(forProject: "anything"))
        // A subsequent set still works (write replaces the garbage).
        store.set(ProjectAccountOverride(claudeConfigDir: "~/ok", codexHome: nil), forProject: "nproj_a")
        XCTAssertEqual(store.override(forProject: "nproj_a")?.claudeConfigDir, "~/ok")
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
