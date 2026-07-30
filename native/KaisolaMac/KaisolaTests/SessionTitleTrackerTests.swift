import Foundation
import XCTest
@testable import Kaisola

/// The pure OSC-title rules (`SessionTitleTracker`) plus the store extension
/// that lands a live title on disk (`NativeSessionStore.applyAutoTitle` /
/// `hasCustomTitle`), the latter over a throwaway file exactly like
/// `NativeSessionStoreTests`.
final class SessionTitleTrackerTests: XCTestCase {

    // MARK: - Sanitization

    func testSanitizeTrimsCollapsesAndStripsControlCharacters() {
        // Leading control bytes, an interior BEL/ESC, tabs and newlines: all
        // become single spaces, runs collapse, ends trim — words stay separate.
        let raw = "\u{01}\u{02}Build\u{07}  step\n\n\tdone\u{1b} "
        XCTAssertEqual(SessionTitleTracker.autoTitle(fromOSC: raw, agentName: nil, folder: "proj"),
                       "Build step done")
    }

    func testSanitizeCaps200CharacterTitleAt60() {
        let raw = String(repeating: "a", count: 200)
        let result = SessionTitleTracker.autoTitle(fromOSC: raw, agentName: nil, folder: "proj")
        XCTAssertEqual(result?.count, 60)
        XCTAssertEqual(result, String(repeating: "a", count: 60))
    }

    func testEmptyAndWhitespaceOnlyTitlesAreNil() {
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "", agentName: nil, folder: "proj"))
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "   \t\n ", agentName: nil, folder: "proj"))
        // Control characters with nothing printable also collapse to nothing.
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "\u{01}\u{07}\u{1b}", agentName: nil, folder: "proj"))
    }

    // MARK: - Generic titles

    func testGenericShellTitlesAreNil() {
        for generic in ["zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish"] {
            XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: generic, agentName: nil, folder: "proj"),
                         "\(generic) should be treated as a generic shell title")
        }
        // Case-insensitive, and even for an agent session (the agent's creation
        // default already covers a bare-shell title).
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "ZSH", agentName: "Claude", folder: "proj"))
    }

    func testFolderOnlyTitleIsNilCaseInsensitively() {
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "Kaisola", agentName: nil, folder: "Kaisola"))
        XCTAssertNil(SessionTitleTracker.autoTitle(fromOSC: "KAISOLA", agentName: nil, folder: "kaisola"))
    }

    func testBrailleActivitySpinnerDoesNotBecomeSessionIdentity() {
        XCTAssertNil(
            SessionTitleTracker.autoTitle(
                fromOSC: "⠹ Kaisola",
                agentName: nil,
                folder: "Kaisola"
            )
        )
        XCTAssertTrue(
            SessionTitleTracker.representsCreationDefault(
                fromOSC: "⠸ Kaisola",
                folder: "Kaisola"
            )
        )
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(
                fromOSC: "⠼ Building feature",
                agentName: "Claude",
                folder: "Kaisola"
            ),
            "Claude · Building feature"
        )
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(
                fromOSC: "⠼Kaisola",
                agentName: nil,
                folder: "Kaisola"
            ),
            "⠼Kaisola",
            "a Braille-leading title without a whitespace delimiter is content"
        )
    }

    @MainActor
    func testAppModelRepairsPersistedSpinnerTitleOnceThenStopsWriting() throws {
        let (store, fileURL) = makeStore()
        let workspace = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Kaisola", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        let model = AppModel(sessionStore: store, workspaceStateStore: workspaceStore)
        model.loadVisualFixture(workspace: workspace)

        store.applyAutoTitle("⠉ Kaisola", terminalID: "visual-terminal")
        model.refreshPersistedNavigationState(publish: false)
        XCTAssertEqual(
            store.sessions().first { $0.id == "visual-terminal" }?.title,
            "⠉ Kaisola"
        )

        model.applyAutoTitle("⠹ Kaisola", to: "visual-terminal")
        let repaired = try XCTUnwrap(
            store.sessions().first { $0.id == "visual-terminal" }
        )
        XCTAssertEqual(repaired.title, "Kaisola")
        XCTAssertEqual(repaired.lastAutoTitle, "Kaisola")
        let repairedInode = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.systemFileNumber]

        model.applyAutoTitle("⠸ Kaisola", to: "visual-terminal")
        let stableInode = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.systemFileNumber]
        XCTAssertEqual(repairedInode as? NSNumber, stableInode as? NSNumber)
        XCTAssertEqual(
            store.sessions().first { $0.id == "visual-terminal" }?.title,
            "Kaisola"
        )
    }

    @MainActor
    func testAppModelStartupRepairsLegacyAutomaticSpinnerTitlesOnly() throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let projectID = NativeSessionStore.projectID(forDirectory: "/tmp/Kaisola")
        store.upsert(NativeOwnedSession(
            id: "plain",
            projectID: projectID,
            cwd: "/tmp/Kaisola",
            title: "⠧ Kaisola",
            createdAt: 1,
            lastAutoTitle: "⠧ Kaisola"
        ))
        store.upsert(NativeOwnedSession(
            id: "agent",
            projectID: projectID,
            cwd: "/tmp/Kaisola",
            title: "Claude · ⠹ Kaisola",
            createdAt: 2,
            agentID: "claude-code",
            lastAutoTitle: "Claude · ⠹ Kaisola"
        ))
        store.upsert(NativeOwnedSession(
            id: "manual",
            projectID: projectID,
            cwd: "/tmp/Kaisola",
            title: "⠹ Kaisola notes",
            createdAt: 3
        ))

        _ = AppModel(sessionStore: store)

        let repaired = Dictionary(uniqueKeysWithValues: store.sessions().map { ($0.id, $0) })
        XCTAssertEqual(repaired["plain"]?.title, "Kaisola")
        XCTAssertEqual(repaired["plain"]?.lastAutoTitle, "Kaisola")
        XCTAssertEqual(repaired["agent"]?.title, "Claude · Kaisola")
        XCTAssertEqual(repaired["agent"]?.lastAutoTitle, "Claude · Kaisola")
        XCTAssertEqual(repaired["manual"]?.title, "⠹ Kaisola notes")
        XCTAssertNil(repaired["manual"]?.lastAutoTitle)

        let stableInode = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.systemFileNumber]
        _ = AppModel(sessionStore: store)
        let reopenedInode = try FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.systemFileNumber]
        XCTAssertEqual(stableInode as? NSNumber, reopenedInode as? NSNumber)
    }

    // MARK: - Agent prefixing

    func testAgentSessionGetsAgentPrefix() {
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromOSC: "building feature", agentName: "Claude", folder: "app"),
            "Claude \u{00B7} building feature"
        )
    }

    func testAgentPrefixSkippedWhenTitleAlreadyContainsAgentNameCaseInsensitively() {
        // Exact-case mention.
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromOSC: "Claude is reviewing", agentName: "Claude", folder: "app"),
            "Claude is reviewing"
        )
        // Lowercase mention still counts — no double-prefix.
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromOSC: "running claude now", agentName: "Claude", folder: "app"),
            "running claude now"
        )
    }

    func testPlainShellSessionHasNoPrefix() {
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromOSC: "npm test", agentName: nil, folder: "app"),
            "npm test"
        )
    }

    func testForegroundAgentAndDeveloperProcessesProduceProjectLocalTitles() {
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromProcess: "codex", agentName: nil, folder: "Kaisola"),
            "Codex · Kaisola"
        )
        XCTAssertEqual(
            SessionTitleTracker.autoTitle(fromProcess: "npm", agentName: nil, folder: "Kaisola"),
            "npm · Kaisola"
        )
        XCTAssertNil(
            SessionTitleTracker.autoTitle(fromProcess: "claude", agentName: "Claude", folder: "Kaisola"),
            "process polling must not flatten a richer OSC title from a prepared agent"
        )
        XCTAssertNil(SessionTitleTracker.autoTitle(fromProcess: "zsh", agentName: nil, folder: "Kaisola"))
        XCTAssertEqual(SessionTitleTracker.agentDisplayName(forProcess: "claude"), "Claude")
    }

    // MARK: - shouldApply matrix

    func testShouldApplyMatrix() {
        // Fresh, non-identical auto-title on an untouched name → apply.
        XCTAssertTrue(SessionTitleTracker.shouldApply(autoTitle: "A", currentTitle: "B", userRenamed: false))
        // Identical → skip (no churn).
        XCTAssertFalse(SessionTitleTracker.shouldApply(autoTitle: "A", currentTitle: "A", userRenamed: false))
        // User (or a prior live title) owns the name → never overwrite.
        XCTAssertFalse(SessionTitleTracker.shouldApply(autoTitle: "A", currentTitle: "B", userRenamed: true))
        XCTAssertFalse(SessionTitleTracker.shouldApply(autoTitle: "A", currentTitle: "A", userRenamed: true))
    }

    // MARK: - Store extension (temp-file round-trip)

    private func makeStore() -> (NativeSessionStore, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-title-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("native-sessions.json")
        return (NativeSessionStore(fileURL: fileURL), fileURL)
    }

    private func seed(_ store: NativeSessionStore, id: String, title: String) {
        store.upsert(NativeOwnedSession(
            id: id,
            projectID: NativeSessionStore.projectID(forDirectory: "/tmp/app"),
            cwd: "/tmp/app",
            title: title,
            createdAt: 1,
            agentID: "claude-code"
        ))
    }

    func testApplyAutoTitleUpdatesAndPersists() {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        seed(store, id: "term-1", title: "Claude \u{00B7} app")

        store.applyAutoTitle("Claude \u{00B7} building feature", terminalID: "term-1")
        XCTAssertEqual(store.sessions().first { $0.id == "term-1" }?.title, "Claude \u{00B7} building feature")

        // Survives a fresh store instance reading the same file.
        let reopened = NativeSessionStore(fileURL: fileURL)
        XCTAssertEqual(reopened.sessions().first { $0.id == "term-1" }?.title, "Claude \u{00B7} building feature")
    }

    func testApplyAutoTitleIsNoOpForUnknownTerminal() {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        seed(store, id: "term-1", title: "Claude \u{00B7} app")

        store.applyAutoTitle("ignored", terminalID: "term-does-not-exist")
        XCTAssertEqual(store.sessions().count, 1)
        XCTAssertEqual(store.sessions().first?.title, "Claude \u{00B7} app")
    }

    func testApplyAutoTitleDoesNotRewriteAnUnchangedAutomaticTitle() throws {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        seed(store, id: "term-1", title: "Claude \u{00B7} app")
        let title = "Claude \u{00B7} building feature"
        store.applyAutoTitle(title, terminalID: "term-1")
        let before = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.systemFileNumber]

        store.applyAutoTitle(title, terminalID: "term-1")

        let after = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.systemFileNumber]
        XCTAssertEqual(before as? NSNumber, after as? NSNumber)
        XCTAssertEqual(store.sessions().first?.lastAutoTitle, title)
    }

    func testHasCustomTitleTracksDivergenceFromCreationDefault() {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let defaultTitle = "Claude \u{00B7} app"
        seed(store, id: "term-1", title: defaultTitle)

        // Untouched creation default → not custom.
        XCTAssertFalse(store.hasCustomTitle("term-1", defaultTitle: defaultTitle))
        // Automatic titles remain eligible for later live improvements.
        store.applyAutoTitle("Claude \u{00B7} building", terminalID: "term-1")
        XCTAssertFalse(store.hasCustomTitle("term-1", defaultTitle: defaultTitle))
        var manuallyRenamed = try! XCTUnwrap(store.sessions().first)
        manuallyRenamed.title = "Release watcher"
        manuallyRenamed.lastAutoTitle = nil
        store.upsert(manuallyRenamed)
        XCTAssertTrue(store.hasCustomTitle("term-1", defaultTitle: defaultTitle))
        // Unknown session → nothing to protect.
        XCTAssertFalse(store.hasCustomTitle("term-nope", defaultTitle: defaultTitle))
    }

    /// The end-to-end gating an owned agent session sees on its first real OSC
    /// title: the tracker produces a prefixed name, the store reports the
    /// creation default as not-yet-custom, `shouldApply` says yes, and the new
    /// title lands.
    func testFirstLiveTitleAppliesOverCreationDefault() {
        let (store, fileURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let folder = "app"
        let defaultTitle = "Claude \u{00B7} \(folder)"
        seed(store, id: "term-1", title: defaultTitle)

        guard let auto = SessionTitleTracker.autoTitle(fromOSC: "building feature", agentName: "Claude", folder: folder) else {
            return XCTFail("expected an auto-title")
        }
        let userRenamed = store.hasCustomTitle("term-1", defaultTitle: defaultTitle)
        XCTAssertTrue(SessionTitleTracker.shouldApply(autoTitle: auto, currentTitle: defaultTitle, userRenamed: userRenamed))
        store.applyAutoTitle(auto, terminalID: "term-1")
        XCTAssertEqual(store.sessions().first?.title, "Claude \u{00B7} building feature")
    }
}
