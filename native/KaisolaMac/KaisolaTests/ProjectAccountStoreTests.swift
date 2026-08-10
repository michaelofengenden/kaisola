import Foundation
import XCTest
@testable import Kaisola

/// ProjectAccountStore persistence + the pure `mergedOverlay` precedence rules.
/// Uses a throwaway file so it never touches the real per-project accounts:
/// set/read round-trip, remove-on-both-blank, cross-project isolation,
/// concurrent writers (two Settings windows), corrupt degradation, and the full
/// app-vs-project merge matrix (project wins per key, blank falls back, tilde
/// expands).
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

    // MARK: - Concurrent writers

    /// Two Settings windows saving different projects at the same moment. Both
    /// entries have to survive: an unlocked read-modify-write lets the later
    /// write publish a payload built from the pre-write file, silently dropping
    /// the other window's project. One round races rarely, so the test runs
    /// enough rounds on fresh files that a single lost entry fails it.
    func testConcurrentTwoWritersPreserveBothProjects() throws {
        for round in 0..<40 {
            let roundURL = try makeRoundFileURL(round)
            // Separate instances, the way two windows each build their own store.
            let first = ProjectAccountStore(fileURL: roundURL)
            let second = ProjectAccountStore(fileURL: roundURL)

            runConcurrently(count: 2) { index in
                let store = index == 0 ? first : second
                store.set(
                    ProjectAccountOverride(claudeConfigDir: "~/claude-\(index)", codexHome: nil),
                    forProject: "nproj_\(index)"
                )
            }

            let reopened = ProjectAccountStore(fileURL: roundURL)
            XCTAssertEqual(
                reopened.override(forProject: "nproj_0")?.claudeConfigDir, "~/claude-0",
                "round \(round) lost the first writer's project"
            )
            XCTAssertEqual(
                reopened.override(forProject: "nproj_1")?.claudeConfigDir, "~/claude-1",
                "round \(round) lost the second writer's project"
            )
        }
    }

    /// The same guarantee under a wider fan-out, which also covers the staging
    /// file: every writer must publish a complete payload, never a torn one.
    func testConcurrentFanOutPreservesEveryProject() throws {
        let writers = 8
        for round in 0..<10 {
            let roundURL = try makeRoundFileURL(round)

            runConcurrently(count: writers) { index in
                ProjectAccountStore(fileURL: roundURL).set(
                    ProjectAccountOverride(claudeConfigDir: "~/claude-\(index)", codexHome: "~/codex-\(index)"),
                    forProject: "nproj_\(index)"
                )
            }

            let reopened = ProjectAccountStore(fileURL: roundURL)
            for index in 0..<writers {
                XCTAssertEqual(
                    reopened.override(forProject: "nproj_\(index)"),
                    ProjectAccountOverride(claudeConfigDir: "~/claude-\(index)", codexHome: "~/codex-\(index)"),
                    "round \(round) lost or corrupted nproj_\(index)"
                )
            }
        }
    }

    /// Removal races the same way: clearing one project must not resurrect or
    /// erase a project another window is writing at the same moment.
    func testConcurrentRemovalKeepsTheOtherProject() throws {
        for round in 0..<40 {
            let roundURL = try makeRoundFileURL(round)
            let seed = ProjectAccountStore(fileURL: roundURL)
            seed.set(ProjectAccountOverride(claudeConfigDir: "~/old", codexHome: nil), forProject: "nproj_0")

            runConcurrently(count: 2) { index in
                let store = ProjectAccountStore(fileURL: roundURL)
                if index == 0 {
                    store.set(nil, forProject: "nproj_0")
                } else {
                    store.set(
                        ProjectAccountOverride(claudeConfigDir: "~/claude-1", codexHome: nil),
                        forProject: "nproj_1"
                    )
                }
            }

            let reopened = ProjectAccountStore(fileURL: roundURL)
            XCTAssertEqual(
                reopened.override(forProject: "nproj_1")?.claudeConfigDir, "~/claude-1",
                "round \(round) lost the writer that raced the removal"
            )
            XCTAssertNil(
                reopened.override(forProject: "nproj_0"),
                "round \(round) resurrected the removed project"
            )
        }
    }

    /// A fresh account file inside this test's temporary directory, so each race
    /// round starts from an empty store.
    private func makeRoundFileURL(_ round: Int) throws -> URL {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("project-accounts-\(round)-\(UUID().uuidString).json")
    }

    /// Runs `body` on `count` threads released together, so the read-modify-write
    /// windows genuinely overlap instead of queueing up behind each other.
    private func runConcurrently(count: Int, _ body: @escaping @Sendable (Int) -> Void) {
        let ready = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        for index in 0..<count {
            finished.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                ready.signal()
                go.wait()
                body(index)
                finished.leave()
            }
        }
        for _ in 0..<count { ready.wait() }
        for _ in 0..<count { go.signal() }
        finished.wait()
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
