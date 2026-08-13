import Foundation
import KaisolaBrokerProtocol
import KaisolaCore
import SQLite3
import XCTest
@testable import Kaisola

/// `AppModel.currentProjectDirectory` — the active-project inference that lets
/// New Terminal/Agent/Chat skip the folder picker (matching Electron).
final class AppModelProjectContextTests: XCTestCase {
    private actor DeterministicSuspensionGate {
        private var entered = false
        private var released = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func suspend() async {
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private var storeFile: URL!

    override func setUpWithError() throws {
        storeFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-ctx-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("native-sessions.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeFile.deletingLastPathComponent())
    }

    @MainActor
    private func makeModel() -> (AppModel, NativeSessionStore) {
        let store = NativeSessionStore(fileURL: storeFile)
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: storeFile.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        return (AppModel(sessionStore: store, workspaceStateStore: workspaceStore), store)
    }

    @MainActor
    func testNoProjectsReturnsNil() {
        let (model, _) = makeModel()
        XCTAssertNil(model.currentProjectDirectory)
    }

    func testTerminalLaunchEnvironmentRejectsInvalidShellAndPrefersPackageManagerBins() {
        let shell = NativeTerminalLaunchEnvironment.resolvedShell(
            environment: ["SHELL": "/usr/bin/not-a-shell"],
            isExecutable: { $0 == "/bin/zsh" }
        )
        XCTAssertEqual(shell, "/bin/zsh")
        XCTAssertEqual(
            NativeTerminalLaunchEnvironment.preferredPathPrelude(
                existingDirectories: ["/opt/homebrew/bin", "/usr/local/bin"]
            ),
            "export PATH='/opt/homebrew/bin:/usr/local/bin':\"$PATH\"; hash -r 2>/dev/null || true; "
        )
    }

    @MainActor
    func testSingleProjectIsUnambiguousContext() {
        let (model, _) = makeModel()
        model.openProject(directory: URL(fileURLWithPath: "/tmp/ctx-solo", isDirectory: true))
        XCTAssertEqual(model.currentProjectDirectory?.lastPathComponent, "ctx-solo")
    }

    @MainActor
    func testSelectedProjectNameWins() {
        let (model, _) = makeModel()
        model.openProject(directory: URL(fileURLWithPath: "/tmp/ctx-alpha", isDirectory: true))
        model.openProject(directory: URL(fileURLWithPath: "/tmp/ctx-beta", isDirectory: true))
        model.selectedProjectName = "ctx-beta"
        XCTAssertEqual(model.currentProjectDirectory?.lastPathComponent, "ctx-beta")
    }

    @MainActor
    func testAmbiguousWithoutSelectionReturnsNil() {
        let (model, _) = makeModel()
        model.openProject(directory: URL(fileURLWithPath: "/tmp/ctx-one", isDirectory: true))
        model.openProject(directory: URL(fileURLWithPath: "/tmp/ctx-two", isDirectory: true))
        model.activateProject(id: nil)
        // Two projects, nothing selected → no unambiguous context.
        XCTAssertNil(model.currentProjectDirectory)
    }

    @MainActor
    func testOpeningAnotherProjectKeepsExistingProjectsAdditively() {
        let (model, _) = makeModel()
        model.openProject(directory: URL(fileURLWithPath: "/tmp/additive-alpha", isDirectory: true))
        let alphaID = model.selectedProjectID
        model.openProject(directory: URL(fileURLWithPath: "/tmp/additive-beta", isDirectory: true))
        let betaID = model.selectedProjectID

        XCTAssertNotEqual(alphaID, betaID)
        XCTAssertEqual(model.projects.map(\.name), ["additive-alpha", "additive-beta"])
        model.activateProject(id: alphaID)
        XCTAssertEqual(model.selectedProjectID, alphaID)
        XCTAssertEqual(model.projects.map(\.name), ["additive-alpha", "additive-beta"])
    }

    @MainActor
    func testInventoryRemovalPrunesStalePaneBeforeProjectRenders() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent("stale-pane-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let terminalID = "term-stale-pane"
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json")
        )
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectID,
                projects: [
                    NativeProjectWorkspaceState(
                        projectID: projectID,
                        layout: SessionPaneLayout(sessionID: terminalID),
                        panes: [
                            NativeRestorablePaneState(
                                id: terminalID,
                                surface: NativeRestorableSurfaceState(
                                    kind: .terminal,
                                    id: terminalID,
                                    projectID: projectID,
                                    title: "Terminal"
                                )
                            ),
                        ],
                        focusedPaneID: terminalID
                    ),
                ]
            )
        )
        let sessionStore = NativeSessionStore(fileURL: storeFile)
        _ = sessionStore.openProject(directory: projectDirectory.path)
        let broker = ProjectContextChangingInventoryBrokerClient(
            terminalID: terminalID,
            projectID: projectID
        )
        let model = AppModel(
            brokerPreparer: ProjectContextBrokerPreparer(),
            fallbackPreparer: nil,
            client: broker,
            sessionStore: sessionStore,
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            workspaceStateStore: workspaceStore,
            reconnectBackoff: BrokerReconnectBackoff(
                baseNanoseconds: 10_000_000_000,
                maximumNanoseconds: 10_000_000_000,
                jitterFraction: 0
            ),
            sleep: { _ in try await Task.sleep(for: .seconds(60)) },
            jitter: { 0 }
        )

        await model.reload()
        XCTAssertEqual(model.paneLayout(for: projectID).sessionIDs, [terminalID])

        await broker.hideTerminal()
        await model.refreshInventory()

        XCTAssertTrue(model.paneLayout(for: projectID).isEmpty)
        XCTAssertNil(model.focusedPaneID)
        model.activateProject(id: projectID)
        XCTAssertTrue(model.paneLayout(for: projectID).isEmpty)
        await model.teardown()
    }

    @MainActor
    func testFileWorkbenchKeepsPinnedTabsAndReplacesOnlyTransientPreview() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("file-tabs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "# First".write(to: first, atomically: true, encoding: .utf8)
        try "# Second".write(to: second, atomically: true, encoding: .utf8)
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)

        model.openFilePreview(first)
        model.commitFileNavigation(first)
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [first.standardizedFileURL])
        model.openFilePreview(second)
        model.commitFileNavigation(second)
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [second.standardizedFileURL])

        model.setFileTabPinned(second, pinned: true)
        model.openFilePreview(first, line: 12)
        model.commitFileNavigation(first)
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [
            second.standardizedFileURL,
            first.standardizedFileURL,
        ])
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.isPinned), [true, false])

        model.selectFileTab(second)
        model.commitFileNavigation(second)
        model.closeFilePreview()
        XCTAssertEqual(model.previewedFileURL, first.standardizedFileURL)
        XCTAssertEqual(model.previewedFileLine, 12)
    }

    @MainActor
    func testFileWorkbenchCyclesOrderedTabsInBothDirectionsAndWraps() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("file-tab-cycle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = (1...3).map { root.appendingPathComponent("file-\($0).md") }
        model.openProject(directory: root)
        for (index, file) in files.enumerated() {
            try "# \(index + 1)".write(to: file, atomically: true, encoding: .utf8)
            model.openFilePreview(file, line: index + 1, pinned: true)
            model.commitFileNavigation(file)
        }

        XCTAssertEqual(model.previewedFileURL, files[2].standardizedFileURL)
        XCTAssertTrue(model.selectAdjacentFileTab(direction: -1))
        XCTAssertEqual(model.previewedFileURL, files[1].standardizedFileURL)
        XCTAssertEqual(model.previewedFileLine, 2)
        model.commitFileNavigation(files[1])
        XCTAssertTrue(model.selectAdjacentFileTab(direction: -1))
        XCTAssertEqual(model.previewedFileURL, files[0].standardizedFileURL)
        model.commitFileNavigation(files[0])
        XCTAssertTrue(model.selectAdjacentFileTab(direction: -1))
        XCTAssertEqual(model.previewedFileURL, files[2].standardizedFileURL)
        model.commitFileNavigation(files[2])
        XCTAssertTrue(model.selectAdjacentFileTab(direction: 1))
        XCTAssertEqual(model.previewedFileURL, files[0].standardizedFileURL)

        model.closeFileTab(files[1])
        model.closeFileTab(files[2])
        XCTAssertFalse(model.selectAdjacentFileTab(direction: 1))
    }

    @MainActor
    func testFileWorkbenchReopensNewestValidClosedTabAndRebasesItsPath() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("file-tab-reopen")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = (1...3).map { root.appendingPathComponent("file-\($0).md") }
        model.openProject(directory: root)
        for (index, file) in files.enumerated() {
            try "# \(index + 1)".write(to: file, atomically: true, encoding: .utf8)
            model.openFilePreview(file, line: index + 1, pinned: true)
            model.commitFileNavigation(file)
        }

        model.closeFileTab(files[1])
        model.closeFileTab(files[2])
        try FileManager.default.removeItem(at: files[2])
        XCTAssertTrue(model.canReopenClosedFileTab)
        XCTAssertTrue(model.reopenClosedFileTab())
        XCTAssertEqual(model.previewedFileURL, files[1].standardizedFileURL)
        XCTAssertEqual(model.previewedFileLine, 2)
        XCTAssertTrue(model.fileTabs(for: model.selectedProjectID).last?.isPinned == true)
        XCTAssertFalse(model.canReopenClosedFileTab)

        model.closeFileTab(files[1])
        let move = try WorkspaceFileOperations.rename(
            item: files[1],
            to: "renamed.md",
            workspaceRoot: root
        )
        model.reconcileWorkspaceFileMove(from: move.source, to: move.destination)
        XCTAssertTrue(model.reopenClosedFileTab())
        XCTAssertEqual(model.previewedFileURL, move.destination.standardizedFileURL)
        XCTAssertEqual(model.previewedFileLine, 2)
        XCTAssertFalse(model.canReopenClosedFileTab)
    }

    @MainActor
    func testWorkspaceDirectoryRenameRebasesOpenDocumentDeck() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("rename-deck")
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let first = docs.appendingPathComponent("first.md")
        let second = docs.appendingPathComponent("second.md")
        try "First".write(to: first, atomically: true, encoding: .utf8)
        try "Second".write(to: second, atomically: true, encoding: .utf8)
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        model.openFilePreview(first, pinned: true)
        model.commitFileNavigation(first)
        model.openFilePreview(second, pinned: true)
        model.commitFileNavigation(second)

        let move = try WorkspaceFileOperations.rename(item: docs, to: "notes", workspaceRoot: root)
        model.reconcileWorkspaceFileMove(from: move.source, to: move.destination)

        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [
            move.destination.appendingPathComponent("first.md").standardizedFileURL,
            move.destination.appendingPathComponent("second.md").standardizedFileURL,
        ])
        XCTAssertEqual(
            model.previewedFileURL,
            move.destination.appendingPathComponent("second.md").standardizedFileURL
        )
        XCTAssertTrue(model.fileTabs(for: projectID).allSatisfy(\.isPinned))
    }

    @MainActor
    func testWorkspaceRemovalClosesDescendantsAndSelectsNearestSurvivingTab() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("trash-deck")
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let before = root.appendingPathComponent("before.md")
        let removed = docs.appendingPathComponent("removed.md")
        let after = root.appendingPathComponent("after.md")
        for file in [before, removed, after] {
            try file.lastPathComponent.write(to: file, atomically: true, encoding: .utf8)
        }
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        for file in [before, removed, after] {
            model.openFilePreview(file, pinned: true)
            model.commitFileNavigation(file)
        }
        model.selectFileTab(removed)
        model.commitFileNavigation(removed)

        try FileManager.default.removeItem(at: docs)
        model.reconcileWorkspaceFileRemoval(docs)

        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [
            before.standardizedFileURL,
            after.standardizedFileURL,
        ])
        XCTAssertEqual(model.previewedFileURL, after.standardizedFileURL)
        XCTAssertEqual(model.selectedFilePathByProject[projectID], after.standardizedFileURL.path)
    }

    @MainActor
    func testWorkspaceRemovalSnapshotRestoresTabsWithoutDiscardingNewWork() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("restore-deck")
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let first = docs.appendingPathComponent("first.md")
        let second = docs.appendingPathComponent("second.md")
        let meanwhile = root.appendingPathComponent("meanwhile.md")
        for file in [first, second, meanwhile] {
            try file.lastPathComponent.write(to: file, atomically: true, encoding: .utf8)
        }
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        for file in [first, second] {
            model.openFilePreview(file, pinned: true)
            model.commitFileNavigation(file)
        }
        model.selectFileTab(second)
        model.commitFileNavigation(second)

        let snapshot = try XCTUnwrap(model.reconcileWorkspaceFileRemoval(docs))
        model.openFilePreview(meanwhile, pinned: true)
        model.commitFileNavigation(meanwhile)
        model.restoreWorkspaceFileRemoval(snapshot)

        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [
            first.standardizedFileURL,
            second.standardizedFileURL,
            meanwhile.standardizedFileURL,
        ])
        XCTAssertEqual(model.previewedFileURL, second.standardizedFileURL)
        XCTAssertEqual(model.selectedFilePathByProject[projectID], second.standardizedFileURL.path)
    }

    @MainActor
    func testWorkspaceRenameUndoAndRedoMoveDiskAndOpenDeckTogether() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("undo-rename")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("before.md")
        try "draft".write(to: original, atomically: true, encoding: .utf8)
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        model.openFilePreview(original, pinned: true)
        model.commitFileNavigation(original)

        let move = try WorkspaceFileOperations.rename(
            item: original,
            to: "after.md",
            workspaceRoot: root
        )
        model.reconcileWorkspaceFileMove(from: move.source, to: move.destination)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        model.registerWorkspaceMoveUndo(
            move,
            workspaceRoot: root,
            undoManager: undoManager
        )
        undoManager.endUndoGrouping()

        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(undoManager.undoActionName, "Rename")
        undoManager.undo()
        let undoDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: original.path), Date() < undoDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [original.standardizedFileURL])

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        let redoDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: move.destination.path), Date() < redoDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: move.destination.path))
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [move.destination])
    }

    @MainActor
    func testWorkspaceCrossDirectoryMoveUndoAndRedoUseExactPaths() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("undo-move")
        let destinationDirectory = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let original = root.appendingPathComponent("draft.md")
        let destination = destinationDirectory.appendingPathComponent("draft.md")
        try "draft".write(to: original, atomically: true, encoding: .utf8)
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        model.openFilePreview(original, pinned: true)
        model.commitFileNavigation(original)

        let move = try WorkspaceFileOperations.move(
            item: original,
            to: destination,
            workspaceRoot: root
        )
        model.reconcileWorkspaceFileMove(from: move.source, to: move.destination)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        model.registerWorkspaceMoveUndo(
            move,
            workspaceRoot: root,
            undoManager: undoManager
        )
        undoManager.endUndoGrouping()

        XCTAssertEqual(undoManager.undoActionName, "Move")
        undoManager.undo()
        let undoDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: original.path), Date() < undoDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [original.standardizedFileURL])

        XCTAssertEqual(undoManager.redoActionName, "Move")
        undoManager.redo()
        let redoDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: destination.path), Date() < redoDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [destination.standardizedFileURL])
    }

    @MainActor
    func testFileWorkbenchIsProjectScopedAcrossProjectSwitches() throws {
        let (model, _) = makeModel()
        let parent = storeFile.deletingLastPathComponent()
        let firstRoot = parent.appendingPathComponent("deck-a")
        let secondRoot = parent.appendingPathComponent("deck-b")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let first = firstRoot.appendingPathComponent("README.md")
        let second = secondRoot.appendingPathComponent("README.md")
        try "A".write(to: first, atomically: true, encoding: .utf8)
        try "B".write(to: second, atomically: true, encoding: .utf8)

        model.openProject(directory: firstRoot)
        let firstProject = try XCTUnwrap(model.selectedProjectID)
        model.openFilePreview(first, pinned: true)
        model.commitFileNavigation(first)
        model.openProject(directory: secondRoot)
        let secondProject = try XCTUnwrap(model.selectedProjectID)
        model.openFilePreview(second, pinned: true)
        model.commitFileNavigation(second)

        model.activateProject(id: firstProject)
        XCTAssertEqual(model.previewedFileURL, first.standardizedFileURL)
        XCTAssertEqual(model.fileTabs(for: firstProject).map(\.url), [first.standardizedFileURL])
        XCTAssertEqual(model.fileTabs(for: secondProject).map(\.url), [second.standardizedFileURL])
    }

    @MainActor
    func testOpeningAFileFromAnotherProjectActivatesThatWorkspace() throws {
        let (model, _) = makeModel()
        let parent = storeFile.deletingLastPathComponent()
        let firstRoot = parent.appendingPathComponent("cross-a")
        let secondRoot = parent.appendingPathComponent("cross-b")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let second = secondRoot.appendingPathComponent("README.md")
        try "B".write(to: second, atomically: true, encoding: .utf8)

        model.openProject(directory: secondRoot)
        let secondProject = try XCTUnwrap(model.selectedProjectID)
        model.openProject(directory: firstRoot)
        XCTAssertNotEqual(model.selectedProjectID, secondProject)

        model.openFilePreview(second, pinned: true)
        model.commitFileNavigation(second)

        XCTAssertEqual(model.selectedProjectID, secondProject)
        XCTAssertEqual(model.currentProjectDirectory, secondRoot.standardizedFileURL)
        XCTAssertEqual(model.previewedFileURL, second.standardizedFileURL)
    }

    @MainActor
    func testOpeningTerminalFileFromUnopenedRepositoryAdoptsAndHighlightsItsWorkspace() throws {
        let (model, _) = makeModel()
        let repository = storeFile.deletingLastPathComponent()
            .appendingPathComponent("linked-repository", isDirectory: true)
        let nested = repository.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("Panel.swift")
        try "let panel = true\n".write(to: file, atomically: true, encoding: .utf8)

        model.openFilePreview(file, line: 18, workspaceHint: nested)

        let projectID = try XCTUnwrap(model.selectedProjectID)
        XCTAssertEqual(model.currentProjectDirectory, repository.standardizedFileURL)
        XCTAssertEqual(model.previewedFileURL, file.standardizedFileURL)
        XCTAssertEqual(model.previewedFileLine, 18)
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [file.standardizedFileURL])
    }

    @MainActor
    func testClosingAndReopeningProjectRetainsItsFileDeck() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("reopen-deck")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("notes.md")
        try "Notes".write(to: file, atomically: true, encoding: .utf8)
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        model.openFilePreview(file, pinned: true)
        model.commitFileNavigation(file)

        model.closeProject(id: projectID)
        XCTAssertNil(model.previewedFileURL)
        model.reopenLastClosedProject()

        XCTAssertEqual(model.selectedProjectID, projectID)
        XCTAssertEqual(model.previewedFileURL, file.standardizedFileURL)
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [file.standardizedFileURL])
    }

    @MainActor
    func testClosedProjectFileDeckSurvivesTeardownPersistence() async throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("cold-deck")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("draft.md")
        try "Draft".write(to: file, atomically: true, encoding: .utf8)
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        model.openFilePreview(file, pinned: true)
        model.commitFileNavigation(file)
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        model.openChat(agent, inDirectory: root)
        model.closeProject(id: projectID)

        await model.teardown()

        let persisted = try await NativeWorkspaceStateStore(
            fileURL: storeFile.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        ).restorationState()
        XCTAssertEqual(persisted.projects.first { $0.projectID == projectID }?.fileTabs, [
            NativeRestorableFileTabState(relativePath: "draft.md", isPinned: true),
        ])
    }

    @MainActor
    func testOrdinaryOpenConsumesDeferredDeckAndClosingLastTabTombstonesIt() async throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("ordinary-reopen")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("draft.md")
        try "Draft".write(to: file, atomically: true, encoding: .utf8)
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        model.openFilePreview(file, pinned: true)
        model.commitFileNavigation(file)

        model.closeProject(id: projectID)
        XCTAssertTrue(model.fileTabs(for: projectID).isEmpty)

        // File > Open Folder is a valid reopen path too; it must consume the
        // same deferred deck used by Reopen Closed Project.
        model.openProject(directory: root)
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [file.standardizedFileURL])
        XCTAssertEqual(model.previewedFileURL, file.standardizedFileURL)

        model.closeFileTab(file)
        XCTAssertTrue(model.fileTabs(for: projectID).isEmpty)
        XCTAssertNil(model.previewedFileURL)
        await model.teardown()

        let persisted = try await NativeWorkspaceStateStore(
            fileURL: storeFile.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        ).restorationState()
        XCTAssertNil(persisted.projects.first { $0.projectID == projectID })
    }

    @MainActor
    func testCancellingDirtyNavigationRestoresTheExactPriorDeck() throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("rollback")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "First".write(to: first, atomically: true, encoding: .utf8)
        try "Second".write(to: second, atomically: true, encoding: .utf8)
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        model.openFilePreview(first, pinned: true)
        model.commitFileNavigation(first)

        model.openFilePreview(second)
        XCTAssertEqual(model.fileTabs(for: projectID).count, 2)
        model.cancelFileNavigation(restoring: first)

        XCTAssertEqual(model.previewedFileURL, first.standardizedFileURL)
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.url), [first.standardizedFileURL])
        XCTAssertEqual(model.fileTabs(for: projectID).map(\.isPinned), [true])
    }

    @MainActor
    func testFileWorkbenchNeverSilentlyEvictsPinnedTabsAtCapacity() async throws {
        let (model, _) = makeModel()
        let root = storeFile.deletingLastPathComponent().appendingPathComponent("tab-cap")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        model.openProject(directory: root)
        let projectID = try XCTUnwrap(model.selectedProjectID)
        for index in 0...NativeWorkspaceStateStore.maximumFileTabsPerProject {
            let file = root.appendingPathComponent("file-\(index).md")
            try "\(index)".write(to: file, atomically: true, encoding: .utf8)
            model.openFilePreview(file, pinned: true)
            model.commitFileNavigation(file)
        }
        let tabs = model.fileTabs(for: projectID)
        XCTAssertEqual(tabs.count, NativeWorkspaceStateStore.maximumFileTabsPerProject)
        XCTAssertTrue(tabs.allSatisfy(\.isPinned))
        XCTAssertEqual(tabs.first?.url.lastPathComponent, "file-0.md")
        XCTAssertEqual(tabs.last?.url.lastPathComponent, "file-23.md")
    }

    /// A streaming turn publishes on its conversation for every chunk, and
    /// several conversations can stream at once. The shell renders a title, a
    /// running dot and a permission badge — never a transcript — so almost all
    /// of that announced a change no observer outside the chat surface could
    /// see. AppModel now re-broadcasts only when one of the rendered fields
    /// actually moved.
    @MainActor
    func testConversationChurnDoesNotInvalidateTheShellButDisplayedChangesDo() async throws {
        let (model, _) = makeModel()
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        model.openChat(agent, inDirectory: URL(fileURLWithPath: "/tmp/ctx-churn", isDirectory: true))
        let chat = try XCTUnwrap(model.chats.first)
        // Let the open itself settle so the baseline is quiet.
        try await Task.sleep(for: .milliseconds(60))

        var publications = 0
        let watcher = model.objectWillChange.sink { _ in publications += 1 }
        defer { watcher.cancel() }

        // A conversation publishing without any rendered field moving is what a
        // token arriving looks like from the shell's point of view.
        for _ in 0..<20 {
            chat.conversation.objectWillChange.send()
        }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(publications, 0, "conversation churn must not invalidate the shell")

        // A field the shell actually renders still gets through, or this would
        // be hiding changes rather than filtering noise.
        chat.conversation.title = "renamed while running"
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(publications, 0, "a rendered change still invalidates the shell")

        if let chatID = model.chats.first?.id { await model.deleteChat(chatID) }
    }

    @MainActor
    func testChatIsPersistedAndGroupedUnderItsProject() async throws {
        let (model, _) = makeModel()
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let directory = URL(fileURLWithPath: "/tmp/ctx-chat", isDirectory: true)

        model.openChat(agent, inDirectory: directory)

        let project = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(project.directory?.path, directory.path)
        XCTAssertEqual(model.chats(in: project.id).count, 1)
        XCTAssertEqual(model.chats.first?.projectID, project.id)
        XCTAssertEqual(model.selectedProjectID, project.id)
        XCTAssertEqual(model.selectedProjectName, project.name)

        if let chatID = model.chats.first?.id { await model.deleteChat(chatID) }
    }

    /// Quit/update teardown persists more than once: first before stopping ACP
    /// children, then once more after Mesh suspension. That last snapshot must
    /// still contain stopped chats, or their SQLite transcript survives while
    /// the only descriptor capable of reopening it is erased.
    @MainActor
    func testCleanTeardownKeepsActiveChatDescriptorForRelaunch() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent("chat-relaunch-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json")
        )
        let transcriptURL = root.appendingPathComponent("transcripts.json")
        let transcriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let sessionStore = NativeSessionStore(fileURL: storeFile)
        let model = AppModel(
            brokerPreparer: ProjectContextBrokerPreparer(),
            fallbackPreparer: nil,
            client: ProjectContextBrokerClient(),
            sessionStore: sessionStore,
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore),
            reconnectBackoff: BrokerReconnectBackoff(
                baseNanoseconds: 1,
                maximumNanoseconds: 2,
                jitterFraction: 0
            ),
            sleep: { _ in await Task.yield() },
            jitter: { 0 }
        )
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        model.openChat(agent, inDirectory: projectDirectory)
        let original = try XCTUnwrap(model.chats.first)
        let rows: [AcpTranscriptRow] = [
            .user(id: "user-1", text: "survive the update", failed: false),
            .message(id: "assistant-1", text: "still here"),
        ]
        original.conversation.seedRowsForTesting(rows)
        original.conversation.onTranscriptChanged?(rows, 0)

        await model.teardown()
        await workspaceStore.invalidateCache()

        let persisted = try await workspaceStore.projectState(for: original.projectID)
        XCTAssertEqual(
            persisted?.panes.compactMap(\.surface.agentChatDescriptor).map(\.id),
            [original.id]
        )

        let reopenedTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let reopened = AppModel(
            brokerPreparer: ProjectContextBrokerPreparer(),
            fallbackPreparer: nil,
            client: ProjectContextBrokerClient(),
            sessionStore: NativeSessionStore(fileURL: storeFile),
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("reopened-cursors.json")),
            workspaceStateStore: NativeWorkspaceStateStore(
                fileURL: root.appendingPathComponent("workspace-state-v1.json")
            ),
            transcriptStore: reopenedTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: reopenedTranscriptStore),
            reconnectBackoff: BrokerReconnectBackoff(
                baseNanoseconds: 1,
                maximumNanoseconds: 2,
                jitterFraction: 0
            ),
            sleep: { _ in await Task.yield() },
            jitter: { 0 }
        )
        await reopened.restoreWorkspaceStateIfNeeded()

        let restored = try XCTUnwrap(reopened.chats.first { $0.id == original.id })
        XCTAssertEqual(restored.conversation.rows, rows)
        await reopened.teardown()
    }

    @MainActor
    func testPermanentDeleteRemovesActiveChatDescriptorWithoutMergeResurrection() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent("active-chat-delete-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json")
        )
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("transcripts.json")
        )
        let model = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        model.openChat(agent, inDirectory: projectDirectory)
        let chat = try XCTUnwrap(model.chats.first)
        let snapshot = try XCTUnwrap(model.workspaceSnapshotForTesting(projectID: chat.projectID))
        try await workspaceStore.saveProjectState(snapshot)

        let result = await model.deleteChat(chat.id)
        XCTAssertEqual(result, .removed)
        XCTAssertTrue(model.chats.isEmpty)

        await workspaceStore.invalidateCache()
        let afterDelete = try await workspaceStore.projectState(for: chat.projectID)
        XCTAssertFalse(afterDelete?.panes.contains { $0.id == chat.id } == true)

        // Teardown submits another ordinary full snapshot. Its merge path must
        // honor the explicit removal fence rather than reviving the stale id.
        await model.teardown()
        let reopened = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json")
        )
        let afterTeardown = try await reopened.projectState(for: chat.projectID)
        XCTAssertFalse(afterTeardown?.panes.contains { $0.id == chat.id } == true)
    }

    /// The transcript row and the workspace descriptor are two independent
    /// durable records. If the descriptor write fails after deletion intent is
    /// tombstoned, physically erasing the transcript must not also erase that
    /// fence: the stale descriptor would otherwise look undeleted and reopen on
    /// the next launch.
    @MainActor
    func testDescriptorWriteFailureKeepsTombstoneUntilRelaunchPrunesStaleChat() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "descriptor-delete-failure-project",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceURL = root.appendingPathComponent("workspace-state-v1.json")
        let parkedWorkspaceURL = root.appendingPathComponent("workspace-state-before-delete.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        let transcriptURL = root.appendingPathComponent("transcripts.json")
        let transcriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let sessionStore = NativeSessionStore(fileURL: storeFile)
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        model.openChat(agent, inDirectory: projectDirectory)
        let chat = try XCTUnwrap(model.chats.first)
        let snapshot = try XCTUnwrap(model.workspaceSnapshotForTesting(projectID: chat.projectID))
        try await workspaceStore.saveProjectState(snapshot)
        await transcriptStore.scheduleSave(
            [.message(id: "row-1", text: "must remain deleted")],
            for: chat.id,
            now: 1
        )
        await transcriptStore.flush()

        // Keep the exact stale archive bytes but make the canonical path a
        // symlink. The store rejects that unsafe target before replacing it,
        // deterministically reproducing descriptor persistence failure without
        // mocking any of the write or validation behavior.
        try FileManager.default.moveItem(at: workspaceURL, to: parkedWorkspaceURL)
        try FileManager.default.createSymbolicLink(
            at: workspaceURL,
            withDestinationURL: parkedWorkspaceURL
        )

        let deletion = await model.deleteChat(chat.id)
        guard case .failed = deletion else {
            return XCTFail("descriptor persistence failure reported \(deletion)")
        }
        XCTAssertTrue(model.chats.isEmpty)
        let removedEntry = await transcriptStore.entry(for: chat.id)
        let retainedTombstone = await transcriptStore.tombstoneState(chatID: chat.id)
        XCTAssertNil(removedEntry)
        XCTAssertEqual(
            retainedTombstone,
            .present,
            "a stale workspace descriptor still exists, so its deletion fence is not reclaimable"
        )

        // Simulate the next launch after the workspace volume becomes writable
        // again. Recovery must use the retained fence to prune the stale
        // descriptor, then and only then reclaim the tombstone.
        try FileManager.default.removeItem(at: workspaceURL)
        try FileManager.default.moveItem(at: parkedWorkspaceURL, to: workspaceURL)
        let reopenedSessionStore = NativeSessionStore(fileURL: storeFile)
        _ = reopenedSessionStore.openProject(directory: projectDirectory.path)
        let reopenedTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let reopenedWorkspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        let reopened = AppModel(
            sessionStore: reopenedSessionStore,
            workspaceStateStore: reopenedWorkspaceStore,
            transcriptStore: reopenedTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: reopenedTranscriptStore)
        )
        await reopened.restoreWorkspaceStateIfNeeded()

        XCTAssertFalse(reopened.chats.contains { $0.id == chat.id })
        await reopenedWorkspaceStore.invalidateCache()
        let recoveredState = try await reopenedWorkspaceStore.projectState(for: chat.projectID)
        XCTAssertFalse(recoveredState?.panes.contains { $0.id == chat.id } == true)
        let reclaimedTombstone = await reopenedTranscriptStore.tombstoneState(chatID: chat.id)
        XCTAssertEqual(reclaimedTombstone, .absent)
        await reopened.teardown()
    }

    @MainActor
    func testRelaunchPrunesTombstonedDescriptorBeforeReclaimingTranscript() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent("tombstoned-chat-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let chatID = "chat-interrupted-delete"
        let descriptor = NativeRestorableAgentChatDescriptor(
            id: chatID,
            projectID: projectID,
            agentID: "codex",
            workspacePath: projectDirectory.path,
            acpSessionID: "provider-interrupted-delete",
            title: "Must stay deleted"
        )
        let workspaceURL = root.appendingPathComponent("workspace-state-v1.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        try await workspaceStore.saveRestorationState(NativeWorkspaceRestorationState(
            selectedProjectID: projectID,
            projects: [NativeProjectWorkspaceState(
                projectID: projectID,
                layout: SessionPaneLayout(sessionID: chatID),
                panes: [NativeRestorablePaneState(
                    id: chatID,
                    surface: NativeRestorableSurfaceState(agentChat: descriptor)
                )],
                focusedPaneID: chatID
            )]
        ))
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("transcripts.json")
        )
        await transcriptStore.scheduleSave(
            [.message(id: "row-1", text: "delete me")],
            for: chatID,
            now: 1
        )
        await transcriptStore.flush()
        let tombstoneResult = await transcriptStore.tombstone(chatID: chatID)
        XCTAssertNotNil(tombstoneResult.snapshot)

        // Simulate termination immediately after the transcript tombstone but
        // before deleteChat could remove the workspace descriptor.
        let sessionStore = NativeSessionStore(fileURL: storeFile)
        _ = sessionStore.openProject(directory: projectDirectory.path)
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        await model.restoreWorkspaceStateIfNeeded()

        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertTrue(
            model.paneLayout(for: projectID).isEmpty,
            "a pruned chat descriptor must not leave a dead card in the restored layout"
        )
        await workspaceStore.invalidateCache()
        let pruned = try await workspaceStore.projectState(for: projectID)
        XCTAssertFalse(pruned?.panes.contains { $0.id == chatID } == true)
        let removedTranscript = await transcriptStore.entry(for: chatID)
        let reclaimedTombstone = await transcriptStore.tombstoneState(chatID: chatID)
        XCTAssertNil(removedTranscript)
        XCTAssertEqual(reclaimedTombstone, .absent)
        await model.teardown()
    }

    /// Closing a project hides its complete archived workspace until an
    /// explicit reopen. Relaunch cleanup must still visit that archive to
    /// finish an interrupted permanent chat deletion, but it must not turn the
    /// project's other chats, Meshes, layout, files, or Recently Closed rows
    /// back into live window state.
    @MainActor
    func testClosedProjectRelaunchOnlyPrunesTombstonesWithoutRestoringWorkspaceState() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "closed-project-restoration",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let document = projectDirectory.appendingPathComponent("notes.md")
        try "kept on disk".write(to: document, atomically: true, encoding: .utf8)

        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let activeChatID = "closed-project-active-chat"
        let deletedChatID = "closed-project-deleted-chat"
        let recentlyClosedChatID = "closed-project-recent-chat"
        let deletedRecentlyClosedChatID = "closed-project-deleted-recent-chat"
        func chatPane(
            id: String,
            recentlyClosed: Bool = false
        ) -> NativeRestorablePaneState {
            NativeRestorablePaneState(
                id: id,
                surface: NativeRestorableSurfaceState(agentChat: .init(
                    id: id,
                    projectID: projectID,
                    agentID: "codex",
                    workspacePath: projectDirectory.path,
                    acpSessionID: "provider-\(id)",
                    title: id
                )),
                isRecentlyClosed: recentlyClosed,
                closedAt: recentlyClosed ? 42 : nil
            )
        }
        let activeChat = chatPane(id: activeChatID)
        let deletedChat = chatPane(id: deletedChatID)
        let recentlyClosedChat = chatPane(id: recentlyClosedChatID, recentlyClosed: true)
        let deletedRecentlyClosedChat = chatPane(
            id: deletedRecentlyClosedChatID,
            recentlyClosed: true
        )
        let mesh = Self.meshPane(id: "closed-project-mesh", basePath: projectDirectory.path)

        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json"),
            meshWorktreeRoot: root.appendingPathComponent("mesh-worktrees", isDirectory: true)
        )
        try await workspaceStore.saveRestorationState(NativeWorkspaceRestorationState(
            selectedProjectID: projectID,
            projects: [NativeProjectWorkspaceState(
                projectID: projectID,
                layout: SessionPaneLayout(columns: [
                    .init(sessionIDs: [activeChat.id, mesh.id, deletedChat.id]),
                ]),
                panes: [
                    activeChat,
                    mesh,
                    deletedChat,
                    recentlyClosedChat,
                    deletedRecentlyClosedChat,
                ],
                focusedPaneID: activeChat.id,
                fileTabs: [.init(relativePath: "notes.md", isPinned: true, line: 3)],
                selectedFilePath: "notes.md"
            )]
        ))

        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("transcripts.json")
        )
        await transcriptStore.scheduleSave(
            [.message(id: "row-1", text: "must stay deleted")],
            for: deletedChatID,
            now: 1
        )
        await transcriptStore.scheduleSave(
            [.message(id: "row-2", text: "closed row must stay deleted")],
            for: deletedRecentlyClosedChatID,
            now: 2
        )
        await transcriptStore.flush()
        let tombstoneResult = await transcriptStore.tombstone(chatID: deletedChatID)
        XCTAssertNotNil(tombstoneResult.snapshot)
        let recentlyClosedTombstoneResult = await transcriptStore.tombstone(
            chatID: deletedRecentlyClosedChatID
        )
        XCTAssertNotNil(recentlyClosedTombstoneResult.snapshot)

        let sessionStore = NativeSessionStore(fileURL: storeFile)
        _ = sessionStore.openProject(directory: projectDirectory.path)
        sessionStore.closeProject(id: projectID)
        XCTAssertTrue(sessionStore.isProjectClosed(projectID))

        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        await model.restoreWorkspaceStateIfNeeded()

        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertTrue(model.meshes.isEmpty)
        XCTAssertTrue(model.paneLayout(for: projectID).isEmpty)
        XCTAssertTrue(model.fileTabs(for: projectID).isEmpty)
        XCTAssertTrue(model.recentlyClosedSurfaces(in: projectID).isEmpty)

        await workspaceStore.invalidateCache()
        let restoredProjectState = try await workspaceStore.projectState(for: projectID)
        let pruned = try XCTUnwrap(restoredProjectState)
        XCTAssertEqual(
            Set(pruned.panes.map(\.id)),
            Set([activeChat.id, mesh.id, recentlyClosedChat.id])
        )
        let reclaimedTombstone = await transcriptStore.tombstoneState(chatID: deletedChatID)
        XCTAssertEqual(reclaimedTombstone, .absent)
        let reclaimedRecentlyClosedTombstone = await transcriptStore.tombstoneState(
            chatID: deletedRecentlyClosedChatID
        )
        XCTAssertEqual(reclaimedRecentlyClosedTombstone, .absent)
        await model.teardown()
    }

    /// Recently Closed is a recovery surface, not an exception to permanent
    /// deletion. A retained entry still returns after relaunch, while a
    /// tombstoned neighbor is pruned before either the in-memory recovery list
    /// or the durable workspace can expose it.
    @MainActor
    func testOpenProjectRelaunchKeepsOnlyNonTombstonedRecentlyClosedChat() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "open-project-recent-chat-pruning",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        func recentlyClosedChat(id: String, closedAt: Int64) -> NativeRestorablePaneState {
            NativeRestorablePaneState(
                id: id,
                surface: NativeRestorableSurfaceState(agentChat: .init(
                    id: id,
                    projectID: projectID,
                    agentID: "codex",
                    workspacePath: projectDirectory.path,
                    acpSessionID: "provider-\(id)",
                    title: id
                )),
                isRecentlyClosed: true,
                closedAt: closedAt
            )
        }
        let retained = recentlyClosedChat(id: "retained-recent-chat", closedAt: 1)
        let deleted = recentlyClosedChat(id: "deleted-recent-chat", closedAt: 2)
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json")
        )
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            panes: [retained, deleted]
        ))
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("transcripts.json")
        )
        await transcriptStore.scheduleSave(
            [.message(id: "row-1", text: "must stay deleted")],
            for: deleted.id,
            now: 1
        )
        await transcriptStore.flush()
        let tombstoneResult = await transcriptStore.tombstone(chatID: deleted.id)
        XCTAssertNotNil(tombstoneResult.snapshot)

        let sessionStore = NativeSessionStore(fileURL: storeFile)
        _ = sessionStore.openProject(directory: projectDirectory.path)
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        await model.restoreWorkspaceStateIfNeeded()

        XCTAssertEqual(
            model.recentlyClosedSurfaces(in: projectID).map(\.id),
            [retained.id]
        )
        await workspaceStore.invalidateCache()
        let restoredProjectState = try await workspaceStore.projectState(for: projectID)
        XCTAssertEqual(restoredProjectState?.panes.map(\.id), [retained.id])
        let reclaimedTombstone = await transcriptStore.tombstoneState(chatID: deleted.id)
        XCTAssertEqual(reclaimedTombstone, .absent)
        await model.teardown()
    }

    /// A restoration retry can run after this window already has live chats.
    /// The descriptor and tombstone must both stay fenced while that live
    /// handle could submit another descriptor during teardown; only visual
    /// materialization/layout is suppressed in this window.
    @MainActor
    func testRestorationKeepsDeletionFenceForTombstonedChatAlreadyInMemory() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "in-memory-chat-tombstone",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json")
        )
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("transcripts.json")
        )
        let sessionStore = NativeSessionStore(fileURL: storeFile)
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))
        model.openChat(agent, inDirectory: projectDirectory)
        let chat = try XCTUnwrap(model.chats.first)
        let descriptor = NativeRestorableAgentChatDescriptor(
            id: chat.id,
            projectID: chat.projectID,
            agentID: chat.agentID,
            workspacePath: chat.workspaceDirectory.path,
            acpSessionID: nil,
            title: "Must remain fenced"
        )
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: chat.projectID,
            layout: SessionPaneLayout(sessionID: chat.id),
            panes: [NativeRestorablePaneState(
                id: chat.id,
                surface: NativeRestorableSurfaceState(agentChat: descriptor)
            )],
            focusedPaneID: chat.id
        ))
        await transcriptStore.scheduleSave(
            [.message(id: "row-1", text: "must stay deleted")],
            for: chat.id,
            now: 1
        )
        await transcriptStore.flush()
        let tombstoneResult = await transcriptStore.tombstone(chatID: chat.id)
        XCTAssertNotNil(tombstoneResult.snapshot)

        await model.restoreWorkspaceStateIfNeeded()

        await workspaceStore.invalidateCache()
        let fencedState = try await workspaceStore.projectState(for: chat.projectID)
        XCTAssertTrue(fencedState?.panes.contains(where: { $0.id == chat.id }) == true)
        XCTAssertTrue(model.paneLayout(for: chat.projectID).isEmpty)
        let retainedTombstone = await transcriptStore.tombstoneState(chatID: chat.id)
        XCTAssertEqual(retainedTombstone, .present)

        await model.teardown()
        let retainedAfterTeardown = await transcriptStore.tombstoneState(chatID: chat.id)
        XCTAssertEqual(retainedAfterTeardown, .present)
    }

    /// One window can durably close a chat while another completes permanent
    /// deletion and crashes after recording transcript deletion intent but
    /// before pruning the shared workspace descriptor. A relaunch must apply
    /// that tombstone to the archived descriptor too; otherwise vacuuming the
    /// tombstone turns Recently Closed into a resurrection path.
    @MainActor
    func testRelaunchPrunesTombstonedRecentlyClosedChatBeforeVacuumOrRestore() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "tombstoned-recent-chat-project",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let chatID = "chat-interrupted-recent-delete"
        let descriptor = NativeRestorableAgentChatDescriptor(
            id: chatID,
            projectID: projectID,
            agentID: "codex",
            workspacePath: projectDirectory.path,
            acpSessionID: "provider-interrupted-recent-delete",
            title: "Must stay permanently deleted"
        )
        let workspaceURL = root.appendingPathComponent("workspace-state-v1.json")

        // Window A has already archived the chat in Recently Closed.
        let firstWindowWorkspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        try await firstWindowWorkspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectID,
                projects: [NativeProjectWorkspaceState(
                    projectID: projectID,
                    layout: SessionPaneLayout(),
                    panes: [NativeRestorablePaneState(
                        id: chatID,
                        surface: NativeRestorableSurfaceState(agentChat: descriptor),
                        isRecentlyClosed: true,
                        closedAt: 42
                    )]
                )]
            )
        )

        // Window B records permanent deletion, then terminates before it can
        // remove Window A's archived descriptor.
        let transcriptURL = root.appendingPathComponent("transcripts.json")
        let deletingWindowTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        await deletingWindowTranscriptStore.scheduleSave(
            [.message(id: "row-1", text: "must not come back")],
            for: chatID,
            now: 1
        )
        await deletingWindowTranscriptStore.flush()
        let tombstoneResult = await deletingWindowTranscriptStore.tombstone(chatID: chatID)
        XCTAssertNotNil(tombstoneResult.snapshot)

        let sessionStore = NativeSessionStore(fileURL: storeFile)
        _ = sessionStore.openProject(directory: projectDirectory.path)
        let relaunchedWorkspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        let relaunchedTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let relaunched = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: relaunchedWorkspaceStore,
            transcriptStore: relaunchedTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: relaunchedTranscriptStore)
        )
        await relaunched.restoreWorkspaceStateIfNeeded()

        XCTAssertTrue(relaunched.chats.isEmpty)
        XCTAssertTrue(relaunched.recentlyClosedSurfaces(in: projectID).isEmpty)
        let restoreResult = await relaunched.restoreRecentlyClosedSurface(chatID)
        XCTAssertEqual(restoreResult, .unavailable)

        await relaunchedWorkspaceStore.invalidateCache()
        let pruned = try await relaunchedWorkspaceStore.projectState(for: projectID)
        XCTAssertFalse(pruned?.panes.contains { $0.id == chatID } == true)
        let removedTranscript = await relaunchedTranscriptStore.entry(for: chatID)
        let reclaimedTombstone = await relaunchedTranscriptStore.tombstoneState(chatID: chatID)
        XCTAssertNil(removedTranscript)
        XCTAssertEqual(reclaimedTombstone, .absent)
        await relaunched.teardown()
    }

    @MainActor
    func testLaunchReclaimsPreScanTombstoneWhoseDescriptorWasAlreadyRemoved() async throws {
        let root = storeFile.deletingLastPathComponent()
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("orphaned-delete-transcripts.json")
        )
        let chatID = "crash-after-descriptor-prune"
        await transcriptStore.scheduleSave(
            [.message(id: "row-1", text: "must be physically removed")],
            for: chatID,
            now: 1
        )
        await transcriptStore.flush()
        let tombstone = await transcriptStore.tombstone(chatID: chatID)
        XCTAssertNotNil(tombstone.snapshot)
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("orphaned-delete-workspace.json")
        )
        try await workspaceStore.saveRestorationState(NativeWorkspaceRestorationState())

        let model = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        await model.restoreWorkspaceStateIfNeeded()

        let entry = await transcriptStore.entry(for: chatID)
        let state = await transcriptStore.tombstoneState(chatID: chatID)
        XCTAssertNil(entry)
        XCTAssertEqual(state, .absent)
        await model.teardown()
    }

    @MainActor
    func testDuplicateChatDescriptorsNeverReleaseReceiptAfterAnyProjectPruneFails() async throws {
        for failureSortsFirst in [true, false] {
            let root = storeFile.deletingLastPathComponent().appendingPathComponent(
                failureSortsFirst ? "duplicate-failure-first" : "duplicate-failure-last",
                isDirectory: true
            )
            let directoryA = root.appendingPathComponent("project-a", isDirectory: true)
            let directoryB = root.appendingPathComponent("project-z", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryA,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: directoryB,
                withIntermediateDirectories: true
            )
            let projects = [directoryA, directoryB].map { directory in
                (id: NativeSessionStore.projectID(forDirectory: directory.path), directory: directory)
            }.sorted { $0.id < $1.id }
            let failed = failureSortsFirst ? projects[0] : projects[1]
            let succeeded = failureSortsFirst ? projects[1] : projects[0]
            let chatID = "duplicate-deleted-chat"
            let pane: ((id: String, directory: URL)) -> NativeRestorablePaneState = { project in
                NativeRestorablePaneState(
                    id: chatID,
                    surface: NativeRestorableSurfaceState(agentChat: .init(
                        id: chatID,
                        projectID: project.id,
                        agentID: "codex",
                        workspacePath: project.directory.path,
                        acpSessionID: nil,
                        title: "Duplicate stale descriptor"
                    )),
                    isRecentlyClosed: true,
                    closedAt: 1
                )
            }
            let workspaceStore = NativeWorkspaceStateStore(
                fileURL: root.appendingPathComponent("workspace-state-v1.json"),
                injectedAgentChatRemovalFailureProjectIDs: [failed.id]
            )
            try await workspaceStore.saveRestorationState(
                NativeWorkspaceRestorationState(projects: projects.map { project in
                    NativeProjectWorkspaceState(
                        projectID: project.id,
                        panes: [pane(project)]
                    )
                })
            )
            let transcriptStore = AcpTranscriptStore(
                fileURL: root.appendingPathComponent("transcripts.json")
            )
            await transcriptStore.scheduleSave(
                [.message(id: "row-1", text: "must remain fenced")],
                for: chatID,
                now: 1
            )
            await transcriptStore.flush()
            let tombstone = await transcriptStore.tombstone(chatID: chatID)
            XCTAssertNotNil(tombstone.snapshot)
            let model = AppModel(
                sessionStore: NativeSessionStore(
                    fileURL: root.appendingPathComponent("native-sessions.json")
                ),
                workspaceStateStore: workspaceStore,
                transcriptStore: transcriptStore,
                usageCenter: UsageCenter(persistenceStore: transcriptStore)
            )

            await model.restoreWorkspaceStateIfNeeded()
            XCTAssertTrue(model.chats.isEmpty)
            XCTAssertTrue(model.recentlyClosedSurfaces(in: failed.id).isEmpty)
            XCTAssertTrue(model.recentlyClosedSurfaces(in: succeeded.id).isEmpty)
            await workspaceStore.invalidateCache()
            let failedState = try await workspaceStore.projectState(for: failed.id)
            let succeededState = try await workspaceStore.projectState(for: succeeded.id)
            XCTAssertTrue(failedState?.panes.contains { $0.id == chatID } == true)
            XCTAssertTrue(
                succeededState?.panes.contains { $0.id == chatID } == true,
                "archive-wide pruning must be atomic when any duplicate cannot be removed"
            )
            let retained = await transcriptStore.tombstoneState(chatID: chatID)
            XCTAssertEqual(
                retained,
                .present,
                "one failed duplicate must retain the receipt regardless of project order"
            )
            await model.teardown()
        }
    }

    @MainActor
    func testPreArchiveReceiptBlocksStaleSnapshotAfterAnotherWindowPrunesAndVacuums() async throws {
        let root = storeFile.deletingLastPathComponent()
        let directories = ["stale-snapshot-active", "stale-snapshot-recent"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let projects = directories.map { directory in
            (id: NativeSessionStore.projectID(forDirectory: directory.path), directory: directory)
        }
        let chatID = "stale-snapshot-after-exact-vacuum"
        func pane(
            project: (id: String, directory: URL),
            recentlyClosed: Bool
        ) -> NativeRestorablePaneState {
            NativeRestorablePaneState(
                id: chatID,
                surface: NativeRestorableSurfaceState(agentChat: .init(
                    id: chatID,
                    projectID: project.id,
                    agentID: "codex",
                    workspacePath: project.directory.path,
                    acpSessionID: nil,
                    title: "Must remain deleted"
                )),
                isRecentlyClosed: recentlyClosed,
                closedAt: recentlyClosed ? 1 : nil
            )
        }
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("stale-snapshot-workspace.json")
        )
        try await workspaceStore.saveRestorationState(.init(projects: [
            .init(
                projectID: projects[0].id,
                layout: SessionPaneLayout(sessionID: chatID),
                panes: [pane(project: projects[0], recentlyClosed: false)],
                focusedPaneID: chatID
            ),
            .init(
                projectID: projects[1].id,
                panes: [pane(project: projects[1], recentlyClosed: true)]
            ),
        ]))
        let transcriptURL = root.appendingPathComponent("stale-snapshot-transcripts.json")
        let firstTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        await firstTranscriptStore.scheduleSave(
            [.message(id: "row-1", text: "must not be restored")],
            for: chatID,
            now: 1
        )
        await firstTranscriptStore.flush()
        let deletion = await firstTranscriptStore.tombstone(chatID: chatID)
        let g1 = try XCTUnwrap(deletion.snapshot)
        let sessionStore = NativeSessionStore(fileURL: storeFile)
        for directory in directories { _ = sessionStore.openProject(directory: directory.path) }
        let gate = DeterministicSuspensionGate()
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: firstTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: firstTranscriptStore),
            afterWorkspaceRestorationRead: {
                await gate.suspend()
            }
        )

        let restoreTask = Task { await model.restoreWorkspaceStateIfNeeded() }
        await gate.waitUntilEntered()
        // Window B uses the same archive authority to atomically remove every
        // descriptor, then consumes the exact g1 receipt while Window A still
        // holds its pre-prune restoration value in memory.
        let pruned = try await workspaceStore.removeAgentChatStateEverywhere(chatID: chatID)
        XCTAssertTrue(pruned)
        let secondTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        await secondTranscriptStore.vacuumTombstones(descriptorPruningVerified: [g1])
        let completedExternalCleanup = await secondTranscriptStore.completeExternalCleanup(g1)
        XCTAssertEqual(completedExternalCleanup, .removed)
        let vacuumed = await secondTranscriptStore.tombstoneState(chatID: chatID)
        XCTAssertEqual(vacuumed, .absent)
        await gate.release()
        await restoreTask.value

        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertTrue(model.recentlyClosedSurfaces(in: projects[1].id).isEmpty)
        XCTAssertFalse(model.paneLayout(for: projects[0].id).contains(chatID))
        await model.teardown()
    }

    @MainActor
    func testLaunchReceiptPrunesDuplicateInsertedAfterRestorationSnapshotFromLatestArchive() async throws {
        let root = storeFile.deletingLastPathComponent()
        let directories = ["launch-latest-original", "launch-latest-raced"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let projects = directories.map { directory in
            (id: NativeSessionStore.projectID(forDirectory: directory.path), directory: directory)
        }
        let chatID = "launch-receipt-latest-archive"
        @Sendable func pane(
            _ project: (id: String, directory: URL)
        ) -> NativeRestorablePaneState {
            NativeRestorablePaneState(
                id: chatID,
                surface: NativeRestorableSurfaceState(agentChat: .init(
                    id: chatID,
                    projectID: project.id,
                    agentID: "codex",
                    workspacePath: project.directory.path,
                    acpSessionID: nil,
                    title: "Deleted duplicate"
                )),
                isRecentlyClosed: true,
                closedAt: 1
            )
        }
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("launch-latest-workspace.json")
        )
        try await workspaceStore.saveRestorationState(.init(projects: [
            .init(projectID: projects[0].id, panes: [pane(projects[0])]),
        ]))
        try await workspaceStore.saveDraft(
            "workspace plaintext must go",
            stableKey: "chat|\(chatID)",
            projectID: projects[0].id,
            agentID: "codex",
            workspacePath: projects[0].directory.path,
            updatedAt: 1
        )
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("launch-latest-transcripts.json")
        )
        await transcriptStore.scheduleSave(
            [.message(id: "row", text: "deleted")],
            for: chatID,
            now: 1
        )
        await transcriptStore.flush()
        let tombstone = await transcriptStore.tombstone(chatID: chatID)
        XCTAssertNotNil(tombstone.snapshot)

        let sessionStore = NativeSessionStore(fileURL: storeFile)
        for directory in directories { _ = sessionStore.openProject(directory: directory.path) }
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore),
            afterWorkspaceRestorationRead: {
                // Same archive authority, after AppModel captured its stale
                // project-id map but before it authorizes the exact receipt.
                try? await workspaceStore.saveProjectState(.init(
                    projectID: projects[1].id,
                    layout: SessionPaneLayout(sessionID: chatID),
                    panes: [pane(projects[1])],
                    focusedPaneID: chatID
                ))
            }
        )
        await model.restoreWorkspaceStateIfNeeded()

        await workspaceStore.invalidateCache()
        for project in projects {
            let state = try await workspaceStore.projectState(for: project.id)
            XCTAssertFalse(state?.panes.contains { $0.id == chatID } == true)
            XCTAssertFalse(state?.layout.contains(chatID) == true)
            XCTAssertNotEqual(state?.focusedPaneID, chatID)
        }
        let survivingDraft = try await workspaceStore.draft(for: "chat|\(chatID)")
        let survivingTranscript = await transcriptStore.entry(for: chatID)
        let survivingReceipt = await transcriptStore.tombstoneState(chatID: chatID)
        XCTAssertNil(survivingDraft)
        XCTAssertNil(survivingTranscript)
        XCTAssertEqual(survivingReceipt, .absent)
        await model.teardown()
    }

    @MainActor
    func testLaunchNeverAuthorizesUnknownArchivedChatOrMeshColumnAfterWatermarkCompaction() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "explicit-incarnation-restore-project",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let chatID = "unknown-archived-agent-chat"
        let meshID = "unknown-archived-mesh"
        let meshColumnID = "unknown-archived-mesh-column"
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("explicit-incarnation-workspace.json")
        )
        let agentPane = NativeRestorablePaneState(
            id: chatID,
            surface: NativeRestorableSurfaceState(agentChat: .init(
                id: chatID,
                projectID: projectID,
                agentID: "codex",
                workspacePath: projectDirectory.path,
                acpSessionID: nil,
                title: "Must fail closed"
            ))
        )
        let meshPane = NativeRestorablePaneState(
            id: meshID,
            surface: NativeRestorableSurfaceState(mesh: .init(
                id: meshID,
                projectID: projectID,
                basePath: projectDirectory.path,
                title: "Must fail closed",
                mode: .flat,
                purpose: .idea,
                lifecycle: .suspended,
                columns: [.init(
                    id: meshColumnID,
                    agentID: "codex",
                    role: .peer,
                    worktreePath: nil,
                    branch: nil,
                    createdBaseOID: nil,
                    acpSessionID: nil,
                    provisioning: .attached,
                    workspaceKind: .base
                )]
            )),
            isRecentlyClosed: true,
            closedAt: 1
        )
        try await workspaceStore.saveRestorationState(.init(
            selectedProjectID: projectID,
            projects: [.init(
                projectID: projectID,
                layout: SessionPaneLayout(sessionID: chatID),
                panes: [agentPane, meshPane],
                focusedPaneID: chatID
            )]
        ))

        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("explicit-incarnation-transcripts.json")
        )
        _ = await transcriptStore.tombstoneState(chatID: "schema-probe")
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                transcriptStore.databaseURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ),
            SQLITE_OK
        )
        let openedDatabase = try XCTUnwrap(database)
        defer { sqlite3_close_v2(openedDatabase) }
        XCTAssertEqual(
            sqlite3_exec(
                openedDatabase,
                "INSERT INTO store_meta(key, value) VALUES ('deletion_watermarks_require_explicit_creation', '1') ON CONFLICT(key) DO UPDATE SET value = '1'",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        let sessionStore = NativeSessionStore(fileURL: storeFile)
        _ = sessionStore.openProject(directory: projectDirectory.path)
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        await model.restoreWorkspaceStateIfNeeded()

        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertTrue(
            model.recentlyClosedSurfaces(in: projectID).isEmpty,
            "an unknown Mesh column must fail the whole archived Mesh closed"
        )
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                openedDatabase,
                "SELECT COUNT(*) FROM chat_incarnations WHERE chat_id IN ('unknown-archived-agent-chat', 'unknown-archived-mesh-column')",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        let countStatement = try XCTUnwrap(statement)
        defer { sqlite3_finalize(countStatement) }
        XCTAssertEqual(sqlite3_step(countStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(countStatement, 0), 0)
        await model.teardown()
    }

    @MainActor
    func testActiveArchiveRestoreReprobesDeletionImmediatelyBeforeMaterialization() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "post-probe-active-chat-delete-race",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let chatID = "active-chat-deleted-after-global-probe"
        let descriptor = NativeRestorableAgentChatDescriptor(
            id: chatID,
            projectID: projectID,
            agentID: "codex",
            workspacePath: projectDirectory.path,
            acpSessionID: nil,
            title: "Must not materialize"
        )
        let workspaceURL = root.appendingPathComponent("active-race-workspace.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        try await workspaceStore.saveRestorationState(.init(
            selectedProjectID: projectID,
            projects: [.init(
                projectID: projectID,
                layout: SessionPaneLayout(sessionID: chatID),
                panes: [.init(
                    id: chatID,
                    surface: NativeRestorableSurfaceState(agentChat: descriptor)
                )],
                focusedPaneID: chatID
            )]
        ))
        let transcriptURL = root.appendingPathComponent("active-race-transcripts.json")
        let initialTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        await initialTranscriptStore.scheduleSave(
            [.message(id: "row-1", text: "must stay deleted")],
            for: chatID,
            now: 1
        )
        await initialTranscriptStore.flush()

        let sessionStore = NativeSessionStore(fileURL: storeFile)
        _ = sessionStore.openProject(directory: projectDirectory.path)
        let gate = DeterministicSuspensionGate()
        let restoringTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: restoringTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: restoringTranscriptStore),
            beforeRestoredChatMaterialization: { id in
                guard id == chatID else { return }
                await gate.suspend()
            }
        )

        let restorationTask = Task { await model.restoreWorkspaceStateIfNeeded() }
        await gate.waitUntilEntered()
        let deletingWindow = AcpTranscriptStore(fileURL: transcriptURL)
        let deletion = await deletingWindow.tombstone(chatID: chatID)
        XCTAssertNotNil(deletion.snapshot)
        await gate.release()
        await restorationTask.value

        XCTAssertFalse(
            model.chats.contains { $0.id == chatID },
            "a delete committed after the global scan must still win the final materialization race"
        )
        XCTAssertFalse(model.paneLayout(for: projectID).contains(chatID))
        await workspaceStore.invalidateCache()
        let pruned = try await workspaceStore.projectState(for: projectID)
        XCTAssertFalse(pruned?.panes.contains { $0.id == chatID } == true)
        let restoredTranscript = await restoringTranscriptStore.restoration(
            for: chatID,
            tailLimit: 120
        )
        let tombstoneState = await restoringTranscriptStore.tombstoneState(chatID: chatID)
        XCTAssertEqual(restoredTranscript, .missing)
        XCTAssertEqual(tombstoneState, .absent)
        await model.teardown()
    }

    @MainActor
    func testRelaunchHidesRecentlyClosedChatWhenTombstoneProbeIsUnknown() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "unverified-recent-chat-project",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let chatID = "chat-unverified-recent-delete"
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json")
        )
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectID,
                projects: [NativeProjectWorkspaceState(
                    projectID: projectID,
                    layout: SessionPaneLayout(),
                    panes: [NativeRestorablePaneState(
                        id: chatID,
                        surface: NativeRestorableSurfaceState(agentChat:
                            NativeRestorableAgentChatDescriptor(
                                id: chatID,
                                projectID: projectID,
                                agentID: "codex",
                                workspacePath: projectDirectory.path,
                                acpSessionID: nil,
                                title: "Unverified deletion state"
                            )
                        ),
                        isRecentlyClosed: true,
                        closedAt: 42
                    )]
                )]
            )
        )

        // A damaged database deterministically makes the deletion probe
        // unknown. That is not permission to expose a restore action, but it
        // is also not proof that the durable descriptor may be deleted.
        let transcriptURL = root.appendingPathComponent("transcripts.sqlite3")
        try Data(repeating: 0x7f, count: 8_192).write(to: transcriptURL, options: .atomic)
        let transcriptStore = AcpTranscriptStore(databaseURL: transcriptURL)
        let initialProbe = await transcriptStore.tombstoneState(chatID: chatID)
        XCTAssertEqual(initialProbe, .unknown)

        let sessionStore = NativeSessionStore(fileURL: storeFile)
        _ = sessionStore.openProject(directory: projectDirectory.path)
        let relaunched = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        await relaunched.restoreWorkspaceStateIfNeeded()

        XCTAssertTrue(relaunched.chats.isEmpty)
        XCTAssertTrue(relaunched.recentlyClosedSurfaces(in: projectID).isEmpty)
        let restoreResult = await relaunched.restoreRecentlyClosedSurface(chatID)
        XCTAssertEqual(restoreResult, .unavailable)

        await workspaceStore.invalidateCache()
        let retained = try await workspaceStore.projectState(for: projectID)
        XCTAssertTrue(retained?.panes.contains { $0.id == chatID } == true)
        let retainedProbe = await transcriptStore.tombstoneState(chatID: chatID)
        XCTAssertEqual(retainedProbe, .unknown)
        await relaunched.teardown()
    }

    @MainActor
    func testCachedRecentlyClosedChatCannotRestoreAfterAnotherWindowTombstonesIt() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "cached-recent-chat-delete-race",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceURL = root.appendingPathComponent("workspace-state-v1.json")
        let transcriptURL = root.appendingPathComponent("transcripts.json")
        let firstWindowWorkspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        let firstWindowTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let firstWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: firstWindowWorkspaceStore,
            transcriptStore: firstWindowTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: firstWindowTranscriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))
        firstWindow.openChat(agent, inDirectory: projectDirectory)
        let chat = try XCTUnwrap(firstWindow.chats.first)
        XCTAssertTrue(firstWindow.closeChat(chat.id))
        await firstWindow.teardown()

        // Relaunch Window A so the archived row is already cached in memory.
        let cachedWorkspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        let cachedTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let cachedWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: cachedWorkspaceStore,
            transcriptStore: cachedTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: cachedTranscriptStore)
        )
        await cachedWindow.restoreWorkspaceStateIfNeeded()
        XCTAssertEqual(
            cachedWindow.recentlyClosedSurfaces(in: chat.projectID).map(\.id),
            [chat.id]
        )

        // Window B commits permanent deletion intent. Its descriptor cleanup
        // is deliberately omitted, matching a failed write or crash boundary.
        let deletingWindowStore = AcpTranscriptStore(fileURL: transcriptURL)
        let tombstone = await deletingWindowStore.tombstone(chatID: chat.id)
        XCTAssertNotNil(tombstone.snapshot)

        let restoreResult = await cachedWindow.restoreRecentlyClosedSurface(chat.id)
        XCTAssertEqual(restoreResult, .unavailable)
        XCTAssertFalse(cachedWindow.chats.contains { $0.id == chat.id })
        XCTAssertTrue(cachedWindow.recentlyClosedSurfaces(in: chat.projectID).isEmpty)

        await cachedWorkspaceStore.invalidateCache()
        let pruned = try await cachedWorkspaceStore.projectState(for: chat.projectID)
        XCTAssertFalse(
            pruned?.panes.contains { $0.id == chat.id && $0.isRecentlyClosed } == true,
            "a present exact receipt authorizes durable descriptor pruning"
        )
        let reclaimedTombstone = await cachedTranscriptStore.tombstoneState(chatID: chat.id)
        XCTAssertEqual(reclaimedTombstone, .absent)
        await cachedWindow.teardown()
    }

    @MainActor
    func testRecentlyClosedRestoreReprobesAfterFinalAwaitBeforeMaterializingChat() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "post-await-recent-chat-delete-race",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceURL = root.appendingPathComponent("workspace-state-v1.json")
        let transcriptURL = root.appendingPathComponent("transcripts.json")
        let firstWorkspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        let firstTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let firstWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: firstWorkspaceStore,
            transcriptStore: firstTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: firstTranscriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))
        firstWindow.openChat(agent, inDirectory: projectDirectory)
        let chat = try XCTUnwrap(firstWindow.chats.first)
        XCTAssertTrue(firstWindow.closeChat(chat.id))
        await firstWindow.teardown()

        let gate = DeterministicSuspensionGate()
        let cachedWorkspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        let cachedTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let cachedWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: cachedWorkspaceStore,
            transcriptStore: cachedTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: cachedTranscriptStore),
            beforeRecentlyClosedChatMaterialization: { _ in
                await gate.suspend()
            }
        )
        await cachedWindow.restoreWorkspaceStateIfNeeded()
        XCTAssertEqual(
            cachedWindow.recentlyClosedSurfaces(in: chat.projectID).map(\.id),
            [chat.id]
        )

        let restoreTask = Task {
            await cachedWindow.restoreRecentlyClosedSurface(chat.id)
        }
        await gate.waitUntilEntered()
        let deletingWindow = AcpTranscriptStore(fileURL: transcriptURL)
        let deletion = await deletingWindow.tombstone(chatID: chat.id)
        XCTAssertNotNil(deletion.snapshot)
        await gate.release()

        let result = await restoreTask.value
        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(cachedWindow.chats.contains { $0.id == chat.id })
        XCTAssertTrue(cachedWindow.recentlyClosedSurfaces(in: chat.projectID).isEmpty)
        await cachedWorkspaceStore.invalidateCache()
        let pruned = try await cachedWorkspaceStore.projectState(for: chat.projectID)
        XCTAssertFalse(pruned?.panes.contains { $0.id == chat.id } == true)
        let reclaimed = await cachedTranscriptStore.tombstoneState(chatID: chat.id)
        XCTAssertEqual(reclaimed, .absent)
        await cachedWindow.teardown()
    }

    @MainActor
    func testRecentlyClosedDeleteBeforeLegacyMigrationCannotRecreateDraftAfterDelayedFlush() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "recent-chat-delete-before-legacy-migration",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let chatID = "recent-chat-delete-before-migration"
        let descriptor = NativeRestorableAgentChatDescriptor(
            id: chatID,
            projectID: projectID,
            agentID: "codex",
            workspacePath: projectDirectory.path,
            acpSessionID: nil,
            title: "Deleted before migration"
        )
        let workspaceURL = root.appendingPathComponent("recent-migration-workspace.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        try await workspaceStore.saveRestorationState(.init(
            selectedProjectID: projectID,
            projects: [.init(
                projectID: projectID,
                panes: [.init(
                    id: chatID,
                    surface: NativeRestorableSurfaceState(agentChat: descriptor),
                    isMinimized: true,
                    isRecentlyClosed: true,
                    closedAt: 1
                )]
            )]
        ))
        let legacyDraft = "legacy draft must not return"
        try await workspaceStore.saveDraft(
            legacyDraft,
            stableKey: "chat|\(chatID)",
            projectID: projectID,
            agentID: "codex",
            workspacePath: projectDirectory.path,
            updatedAt: 1
        )
        let transcriptURL = root.appendingPathComponent("recent-migration-transcripts.json")
        let initialTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        await initialTranscriptStore.scheduleSave(
            [.message(id: "row-1", text: "must stay deleted")],
            for: chatID,
            now: 1
        )
        await initialTranscriptStore.flush()

        let sessionStore = NativeSessionStore(fileURL: storeFile)
        _ = sessionStore.openProject(directory: projectDirectory.path)
        let gate = DeterministicSuspensionGate()
        let restoringTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: restoringTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: restoringTranscriptStore),
            beforeRecentlyClosedLegacyDraftMigration: { id in
                guard id == chatID else { return }
                await gate.suspend()
            }
        )
        await model.restoreWorkspaceStateIfNeeded()
        XCTAssertEqual(model.recentlyClosedSurfaces(in: projectID).map(\.id), [chatID])

        let restoreTask = Task { await model.restoreRecentlyClosedSurface(chatID) }
        await gate.waitUntilEntered()
        let deletingWindow = AcpTranscriptStore(fileURL: transcriptURL)
        let deletion = await deletingWindow.tombstone(chatID: chatID)
        XCTAssertNotNil(deletion.snapshot)
        // Model an already-enqueued legacy migration from a stale window. The
        // exact deletion completion must clear it, not merely vacuum its fence.
        await restoringTranscriptStore.scheduleDraft(legacyDraft, for: chatID, now: 2)
        await gate.release()

        let result = await restoreTask.value
        XCTAssertEqual(result, .unavailable)
        try await Task.sleep(for: .milliseconds(450))
        let restoredTranscript = await restoringTranscriptStore.restoration(
            for: chatID,
            tailLimit: 120
        )
        let tombstoneState = await restoringTranscriptStore.tombstoneState(chatID: chatID)
        let retainedLegacyDraft = try await workspaceStore.draft(for: "chat|\(chatID)")
        XCTAssertEqual(
            restoredTranscript,
            .missing,
            "a delayed pending draft flush must not recreate a permanently deleted chat"
        )
        XCTAssertEqual(tombstoneState, .absent)
        XCTAssertNil(retainedLegacyDraft)
        XCTAssertTrue(model.recentlyClosedSurfaces(in: projectID).isEmpty)
        XCTAssertTrue(model.chats.isEmpty)
        await model.teardown()
    }

    @MainActor
    func testCachedRecentlyClosedRestoreBlocksOnUnknownProbeWithoutPruningDurableRow() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "cached-recent-chat-unknown-probe",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceURL = root.appendingPathComponent("workspace-state-v1.json")
        let transcriptURL = root.appendingPathComponent("transcripts.json")
        let firstTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let firstWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: NativeWorkspaceStateStore(fileURL: workspaceURL),
            transcriptStore: firstTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: firstTranscriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))
        firstWindow.openChat(agent, inDirectory: projectDirectory)
        let chat = try XCTUnwrap(firstWindow.chats.first)
        XCTAssertTrue(firstWindow.closeChat(chat.id))
        await firstWindow.teardown()

        let cachedWorkspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        let cachedTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let cachedWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: cachedWorkspaceStore,
            transcriptStore: cachedTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: cachedTranscriptStore)
        )
        await cachedWindow.restoreWorkspaceStateIfNeeded()
        XCTAssertEqual(
            cachedWindow.recentlyClosedSurfaces(in: chat.projectID).map(\.id),
            [chat.id]
        )

        var blocker: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                cachedTranscriptStore.databaseURL.path,
                &blocker,
                SQLITE_OPEN_READWRITE,
                nil
            ),
            SQLITE_OK
        )
        let database = try XCTUnwrap(blocker)
        XCTAssertEqual(sqlite3_exec(database, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        let result = await cachedWindow.restoreRecentlyClosedSurface(chat.id)
        XCTAssertEqual(sqlite3_exec(database, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(database)

        guard case .blocked = result else {
            return XCTFail("an unknown deletion probe must return blocked, got \(result)")
        }
        XCTAssertFalse(cachedWindow.chats.contains { $0.id == chat.id })
        XCTAssertTrue(cachedWindow.recentlyClosedSurfaces(in: chat.projectID).isEmpty)
        await cachedWorkspaceStore.invalidateCache()
        let retained = try await cachedWorkspaceStore.projectState(for: chat.projectID)
        XCTAssertTrue(
            retained?.panes.contains { $0.id == chat.id && $0.isRecentlyClosed } == true
        )
        let healthyProbe = await cachedTranscriptStore.tombstoneState(chatID: chat.id)
        XCTAssertEqual(healthyProbe, .absent)
        await cachedWindow.teardown()
    }

    @MainActor
    func testCachedRecentlyClosedDeletionRetainsFenceWhenDescriptorPruningFails() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "cached-recent-chat-prune-failure",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let workspaceURL = root.appendingPathComponent("workspace-state-v1.json")
        let transcriptURL = root.appendingPathComponent("transcripts.json")
        let firstTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let firstWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: NativeWorkspaceStateStore(fileURL: workspaceURL),
            transcriptStore: firstTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: firstTranscriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))
        firstWindow.openChat(agent, inDirectory: projectDirectory)
        let chat = try XCTUnwrap(firstWindow.chats.first)
        XCTAssertTrue(firstWindow.closeChat(chat.id))
        await firstWindow.teardown()

        let failingWorkspaceStore = NativeWorkspaceStateStore(
            fileURL: workspaceURL,
            injectedAgentChatRemovalFailureProjectIDs: [projectID]
        )
        let cachedTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let cachedWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: failingWorkspaceStore,
            transcriptStore: cachedTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: cachedTranscriptStore)
        )
        await cachedWindow.restoreWorkspaceStateIfNeeded()
        XCTAssertEqual(cachedWindow.recentlyClosedSurfaces(in: projectID).map(\.id), [chat.id])
        let deletion = await AcpTranscriptStore(fileURL: transcriptURL).tombstone(chatID: chat.id)
        XCTAssertNotNil(deletion.snapshot)

        let result = await cachedWindow.restoreRecentlyClosedSurface(chat.id)
        guard case .blocked = result else {
            return XCTFail("descriptor prune failure must remain blocked, got \(result)")
        }
        XCTAssertTrue(cachedWindow.recentlyClosedSurfaces(in: projectID).isEmpty)
        await failingWorkspaceStore.invalidateCache()
        let retained = try await failingWorkspaceStore.projectState(for: projectID)
        XCTAssertTrue(retained?.panes.contains { $0.id == chat.id } == true)
        let retainedTombstone = await cachedTranscriptStore.tombstoneState(chatID: chat.id)
        XCTAssertEqual(retainedTombstone, .present)
        await cachedWindow.teardown()
    }

    @MainActor
    func testChatCloseRestoreAndPermanentDeleteKeepClearDurabilityBoundaries() async throws {
        let (model, _) = makeModel()
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let directory = storeFile.deletingLastPathComponent()
            .appendingPathComponent("recent-chat-project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.openChat(agent, inDirectory: directory)
        let chat = try XCTUnwrap(model.chats.first)
        let defaultsKeys = AcpConversation.persistedDraftDefaultsKeys(for: chat.id)
        defer {
            for key in defaultsKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let rows: [AcpTranscriptRow] = [
            .user(id: "user-1", text: "keep this question", failed: false),
            .message(id: "agent-1", text: "keep this answer"),
        ]
        chat.conversation.seedRowsForTesting(rows)
        chat.conversation.seedQueuedPromptsForTesting([
            "oldest pending follow-up",
            "newest pending follow-up",
        ])
        chat.conversation.onTranscriptChanged?(rows, 0)
        chat.conversation.saveDraft("keep this draft")

        XCTAssertTrue(model.closeChat(chat.id))
        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertEqual(model.recentlyClosedSurfaces(in: chat.projectID).map(\.id), [chat.id])
        model.closeProject(id: chat.projectID)
        // Deliberately inverted (2026-08-06 spec §4d): closed stays closed.
        // Recently Closed work no longer forces the tab back — reopening the
        // project (⌘⇧T / Open Folder) is the recovery path, and it restores
        // the rail with everything intact.
        XCTAssertFalse(
            model.projects.contains(where: { $0.id == chat.projectID }),
            "a closed project must stay out of the rail even with Recently Closed work"
        )
        model.reopenLastClosedProject()
        XCTAssertTrue(
            model.projects.contains(where: { $0.id == chat.projectID }),
            "reopening restores the project's recovery controls"
        )

        let restoreResult = await model.restoreRecentlyClosedSurface(chat.id)
        XCTAssertEqual(restoreResult, .completed)
        let restored = try XCTUnwrap(model.chats.first { $0.id == chat.id })
        XCTAssertEqual(restored.conversation.rows, rows)
        XCTAssertEqual(restored.conversation.loadDraft(), "keep this draft")
        XCTAssertEqual(
            restored.conversation.queued.map(\.text),
            ["oldest pending follow-up", "newest pending follow-up"]
        )
        XCTAssertTrue(model.recentlyClosedSurfaces(in: chat.projectID).isEmpty)

        XCTAssertTrue(model.closeChat(chat.id))
        for key in defaultsKeys {
            XCTAssertNotNil(UserDefaults.standard.string(forKey: key))
        }
        let deleteResult = await model.deleteRecentlyClosedSurface(
            chat.id,
            allowRecoverableWork: true
        )
        XCTAssertEqual(deleteResult, .completed)
        for key in defaultsKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key))
        }
        XCTAssertTrue(model.recentlyClosedSurfaces(in: chat.projectID).isEmpty)
        let missingResult = await model.restoreRecentlyClosedSurface(chat.id)
        XCTAssertEqual(missingResult, .unavailable)
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: storeFile.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        let persisted = try await workspaceStore.projectState(for: chat.projectID)
        XCTAssertFalse(persisted?.panes.contains(where: { $0.id == chat.id }) == true)
    }

    /// A permanent delete may not announce itself while the transcript is
    /// still on disk: an unwritable store has to come back as blocked.
    @MainActor
    func testPermanentChatDeleteReportsATranscriptItCouldNotErase() async throws {
        let root = storeFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcriptStore = AcpTranscriptStore(
            databaseURL: root.appendingPathComponent("transcripts.sqlite3"),
            writerID: "project-context-removal-failure",
            schedulesAutomaticFlush: false,
            injectedRemovalFailure: .open
        )
        let model = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: NativeWorkspaceStateStore(
                fileURL: root.appendingPathComponent("workspace-state-v1.json")
            ),
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let directory = root.appendingPathComponent("unerasable-chat-project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.openChat(agent, inDirectory: directory)
        let chat = try XCTUnwrap(model.chats.first)
        XCTAssertTrue(model.closeChat(chat.id))

        let deleteResult = await model.deleteRecentlyClosedSurface(
            chat.id,
            allowRecoverableWork: true
        )
        guard case let .blocked(message) = deleteResult else {
            return XCTFail("expected a blocked delete, got \(deleteResult)")
        }
        XCTAssertTrue(message.contains("could not be erased"), message)
    }

    @MainActor
    func testArchivedDeleteRecordsIntentBeforeDescriptorFailureAndRelaunchFinishesIt() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent(
            "archived-delete-crash-boundary",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let workspaceURL = root.appendingPathComponent("workspace-state-v1.json")
        let transcriptURL = root.appendingPathComponent("transcripts.json")
        let firstTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let firstWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: NativeWorkspaceStateStore(fileURL: workspaceURL),
            transcriptStore: firstTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: firstTranscriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))
        firstWindow.openChat(agent, inDirectory: projectDirectory)
        let chat = try XCTUnwrap(firstWindow.chats.first)
        await firstTranscriptStore.scheduleSave(
            [.message(id: "row-1", text: "must be erased after relaunch")],
            for: chat.id,
            now: 1
        )
        await firstTranscriptStore.flush()
        XCTAssertTrue(firstWindow.closeChat(chat.id))
        await firstWindow.teardown()

        // Deterministic crash boundary: transcript deletion intent commits,
        // but descriptor pruning fails. The cached row is hidden and neither
        // transcript bytes nor the resurrection fence may be reclaimed yet.
        let failingWorkspaceStore = NativeWorkspaceStateStore(
            fileURL: workspaceURL,
            injectedAgentChatRemovalFailureProjectIDs: [projectID]
        )
        let deletingTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let deletingWindow = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: failingWorkspaceStore,
            transcriptStore: deletingTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: deletingTranscriptStore)
        )
        await deletingWindow.restoreWorkspaceStateIfNeeded()
        XCTAssertEqual(deletingWindow.recentlyClosedSurfaces(in: projectID).map(\.id), [chat.id])
        let delete = await deletingWindow.deleteRecentlyClosedSurface(
            chat.id,
            allowRecoverableWork: true
        )
        guard case .blocked = delete else {
            return XCTFail("descriptor failure must report blocked, got \(delete)")
        }
        XCTAssertTrue(deletingWindow.recentlyClosedSurfaces(in: projectID).isEmpty)
        let fenced = await deletingTranscriptStore.tombstoneState(chatID: chat.id)
        let retainedEntry = await deletingTranscriptStore.entry(for: chat.id)
        XCTAssertEqual(fenced, .present)
        XCTAssertNotNil(retainedEntry)
        await deletingWindow.teardown()

        // Healthy relaunch sees the durable intent, prunes the still-archived
        // descriptor, and consumes that exact receipt to finish deletion.
        let relaunchedWorkspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        let relaunchedTranscriptStore = AcpTranscriptStore(fileURL: transcriptURL)
        let relaunched = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: relaunchedWorkspaceStore,
            transcriptStore: relaunchedTranscriptStore,
            usageCenter: UsageCenter(persistenceStore: relaunchedTranscriptStore)
        )
        await relaunched.restoreWorkspaceStateIfNeeded()
        XCTAssertTrue(relaunched.recentlyClosedSurfaces(in: projectID).isEmpty)
        await relaunchedWorkspaceStore.invalidateCache()
        let pruned = try await relaunchedWorkspaceStore.projectState(for: projectID)
        XCTAssertFalse(pruned?.panes.contains { $0.id == chat.id } == true)
        let erasedEntry = await relaunchedTranscriptStore.entry(for: chat.id)
        let reclaimed = await relaunchedTranscriptStore.tombstoneState(chatID: chat.id)
        XCTAssertNil(erasedEntry)
        XCTAssertEqual(reclaimed, .absent)
        await relaunched.teardown()
    }

    @MainActor
    func testActiveDeletePrunesDuplicateDescriptorWhenOwningProjectIsAlreadyAbsent() async throws {
        let root = storeFile.deletingLastPathComponent()
        let owningDirectory = root.appendingPathComponent("active-owner", isDirectory: true)
        let duplicateDirectory = root.appendingPathComponent("active-duplicate", isDirectory: true)
        try FileManager.default.createDirectory(at: owningDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: duplicateDirectory, withIntermediateDirectories: true)
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("active-duplicate-workspace.json")
        )
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("active-duplicate-transcripts.json")
        )
        let model = AppModel(
            sessionStore: NativeSessionStore(fileURL: storeFile),
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))
        model.openChat(agent, inDirectory: owningDirectory)
        let chat = try XCTUnwrap(model.chats.first)
        let duplicateProjectID = NativeSessionStore.projectID(
            forDirectory: duplicateDirectory.path
        )
        let duplicate = NativeRestorablePaneState(
            id: chat.id,
            surface: NativeRestorableSurfaceState(agentChat: .init(
                id: chat.id,
                projectID: duplicateProjectID,
                agentID: chat.agentID,
                workspacePath: duplicateDirectory.path,
                acpSessionID: nil,
                title: "Cross-project duplicate"
            ))
        )
        // The live chat's owning project is deliberately absent while another
        // project holds its duplicate descriptor.
        try await workspaceStore.saveRestorationState(.init(projects: [
            .init(
                projectID: duplicateProjectID,
                layout: SessionPaneLayout(sessionID: chat.id),
                panes: [duplicate],
                focusedPaneID: chat.id
            ),
        ]))

        let result = await model.deleteChat(chat.id)
        XCTAssertEqual(result, .removed)
        await workspaceStore.invalidateCache()
        let duplicateState = try await workspaceStore.projectState(for: duplicateProjectID)
        XCTAssertFalse(duplicateState?.panes.contains { $0.id == chat.id } == true)
        XCTAssertFalse(
            duplicateState?.layout.columns.contains {
                $0.sessionIDs.contains(chat.id)
            } == true
        )
        XCTAssertNotEqual(duplicateState?.focusedPaneID, chat.id)
        let reclaimed = await transcriptStore.tombstoneState(chatID: chat.id)
        XCTAssertEqual(reclaimed, .absent)
        await model.teardown()
    }

    @MainActor
    func testCachedRestorePrunesDuplicateRecentlyClosedDescriptorsBeforeReceiptRelease() async throws {
        let root = storeFile.deletingLastPathComponent()
        let directories = ["cached-duplicate-a", "cached-duplicate-b"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let projects = directories.map { directory in
            (id: NativeSessionStore.projectID(forDirectory: directory.path), directory: directory)
        }
        let chatID = "cached-cross-project-duplicate"
        let workspaceURL = root.appendingPathComponent("cached-duplicate-workspace.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        try await workspaceStore.saveRestorationState(.init(projects: projects.map { project in
            .init(projectID: project.id, panes: [NativeRestorablePaneState(
                id: chatID,
                surface: NativeRestorableSurfaceState(agentChat: .init(
                    id: chatID,
                    projectID: project.id,
                    agentID: "codex",
                    workspacePath: project.directory.path,
                    acpSessionID: nil,
                    title: "Cached duplicate"
                )),
                isRecentlyClosed: true,
                closedAt: 1
            )])
        }))
        let sessionStore = NativeSessionStore(fileURL: storeFile)
        for directory in directories { _ = sessionStore.openProject(directory: directory.path) }
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("cached-duplicate-transcripts.json")
        )
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        await model.restoreWorkspaceStateIfNeeded()
        XCTAssertEqual(
            projects.map { model.recentlyClosedSurfaces(in: $0.id).map(\.id) },
            [[chatID], [chatID]]
        )
        let deletion = await AcpTranscriptStore(
            fileURL: root.appendingPathComponent("cached-duplicate-transcripts.json")
        ).tombstone(chatID: chatID)
        XCTAssertNotNil(deletion.snapshot)

        let result = await model.restoreRecentlyClosedSurface(chatID)
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertTrue(projects.allSatisfy {
            model.recentlyClosedSurfaces(in: $0.id).isEmpty
        })
        await workspaceStore.invalidateCache()
        for project in projects {
            let state = try await workspaceStore.projectState(for: project.id)
            XCTAssertFalse(state?.panes.contains { $0.id == chatID } == true)
        }
        let reclaimed = await transcriptStore.tombstoneState(chatID: chatID)
        XCTAssertEqual(reclaimed, .absent)
        await model.teardown()
    }

    @MainActor
    func testArchivedDeletePrunesAllCrossProjectDuplicatesBeforeReceiptRelease() async throws {
        let root = storeFile.deletingLastPathComponent()
        let directories = ["archive-duplicate-a", "archive-duplicate-b"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let projects = directories.map { directory in
            (id: NativeSessionStore.projectID(forDirectory: directory.path), directory: directory)
        }
        let chatID = "archived-cross-project-duplicate"
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("archive-duplicate-workspace.json")
        )
        try await workspaceStore.saveRestorationState(.init(projects: projects.map { project in
            .init(projectID: project.id, panes: [NativeRestorablePaneState(
                id: chatID,
                surface: NativeRestorableSurfaceState(agentChat: .init(
                    id: chatID,
                    projectID: project.id,
                    agentID: "codex",
                    workspacePath: project.directory.path,
                    acpSessionID: nil,
                    title: "Archived duplicate"
                )),
                isRecentlyClosed: true,
                closedAt: 1
            )])
        }))
        let sessionStore = NativeSessionStore(fileURL: storeFile)
        for directory in directories { _ = sessionStore.openProject(directory: directory.path) }
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("archive-duplicate-transcripts.json")
        )
        await transcriptStore.scheduleSave(
            [.message(id: "row-1", text: "delete across every project")],
            for: chatID,
            now: 1
        )
        await transcriptStore.flush()
        let model = AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore)
        )
        await model.restoreWorkspaceStateIfNeeded()

        let result = await model.deleteRecentlyClosedSurface(
            chatID,
            allowRecoverableWork: true
        )
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(projects.allSatisfy {
            model.recentlyClosedSurfaces(in: $0.id).isEmpty
        })
        await workspaceStore.invalidateCache()
        for project in projects {
            let state = try await workspaceStore.projectState(for: project.id)
            XCTAssertFalse(state?.panes.contains { $0.id == chatID } == true)
        }
        let erased = await transcriptStore.entry(for: chatID)
        let reclaimed = await transcriptStore.tombstoneState(chatID: chatID)
        XCTAssertNil(erased)
        XCTAssertEqual(reclaimed, .absent)
        await model.teardown()
    }

    /// A composer draft lives in two places: the workspace draft store, and the
    /// legacy `chatDraft.<id>` defaults key that `loadDraft` still reads. A
    /// permanent delete that clears only the first leaves the unsent text
    /// readable in preferences for the life of the install.
    @MainActor
    func testPermanentDeleteErasesTheLegacyAndCurrentDraftStores() async throws {
        let (model, _) = makeModel()
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let directory = storeFile.deletingLastPathComponent()
            .appendingPathComponent("deleted-draft-project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.openChat(agent, inDirectory: directory)
        let chat = try XCTUnwrap(model.chats.first)
        let legacyKey = "chatDraft.\(chat.id)"
        let stableKey = "chat|\(chat.id)"
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

        // Seed both stores: `saveDraft` writes the defaults mirror inline, and
        // the draft hook is what the composer's debounce eventually calls.
        let secret = "unsent recovery phrase 8f21-tttp"
        chat.conversation.saveDraft(secret)
        chat.conversation.onDraftChanged?(secret)
        await model.flushDraftPersistence()

        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: storeFile.deletingLastPathComponent()
                .appendingPathComponent("workspace-state-v1.json")
        )
        let seededDraft = try await workspaceStore.draft(for: stableKey)
        XCTAssertEqual(UserDefaults.standard.string(forKey: legacyKey), secret)
        XCTAssertEqual(seededDraft, secret)

        await model.deleteChat(chat.id)
        await model.flushDraftPersistence()
        await model.teardown()

        XCTAssertNil(
            UserDefaults.standard.string(forKey: legacyKey),
            "the legacy defaults draft survived a permanent delete"
        )
        await workspaceStore.invalidateCache()
        let survivingDraft = try await workspaceStore.draft(for: stableKey)
        XCTAssertNil(survivingDraft, "the workspace draft survived a permanent delete")

        // Relaunch: a fresh conversation on the same key finds no plaintext.
        let relaunched = AcpConversation(
            title: "Relaunched",
            command: "mock",
            arguments: [],
            cwd: directory.path,
            draftKey: chat.id
        )
        XCTAssertEqual(relaunched.loadDraft(), "")
    }

    @MainActor
    func testLaunchReconcilesEveryDeletionCleanupCrashBoundaryWithoutOrphanPlaintext() async throws {
        enum Boundary: String, CaseIterable {
            case afterTombstone
            case afterWorkspaceCleanup
            case afterTranscriptCleanup
            case afterDefaultsCleanup
        }

        for boundary in Boundary.allCases {
            let root = storeFile.deletingLastPathComponent().appendingPathComponent(
                "cleanup-boundary-\(boundary.rawValue)",
                isDirectory: true
            )
            let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(
                at: projectDirectory,
                withIntermediateDirectories: true
            )
            let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
            let chatID = "cleanup-\(boundary.rawValue)"
            let secret = "KAISOLA_CLEANUP_SECRET_\(boundary.rawValue)_B71F"
            let secretData = Data(secret.utf8)
            let workspaceURL = root.appendingPathComponent("workspace.json")
            let workspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
            let descriptor = NativeRestorableAgentChatDescriptor(
                id: chatID,
                projectID: projectID,
                agentID: "codex",
                workspacePath: projectDirectory.path,
                acpSessionID: nil,
                title: "Deleted"
            )
            try await workspaceStore.saveRestorationState(.init(projects: [.init(
                projectID: projectID,
                panes: [.init(
                    id: chatID,
                    surface: NativeRestorableSurfaceState(agentChat: descriptor),
                    isRecentlyClosed: true,
                    closedAt: 1
                )]
            )]))
            try await workspaceStore.saveDraft(
                secret,
                stableKey: "chat|\(chatID)",
                projectID: projectID,
                agentID: "codex",
                workspacePath: projectDirectory.path,
                updatedAt: 1
            )
            let transcriptStore = AcpTranscriptStore(
                databaseURL: root.appendingPathComponent("transcripts.sqlite3"),
                writerID: "cleanup-writer-\(boundary.rawValue)",
                schedulesAutomaticFlush: false
            )
            await transcriptStore.scheduleSave(
                [.message(id: "row", text: secret)],
                for: chatID,
                now: 1
            )
            await transcriptStore.scheduleDraft(secret, for: chatID, now: 2)
            await transcriptStore.flush()

            let currentSuiteName = "kaisola.cleanup.current.\(UUID().uuidString)"
            let migratedSuiteName = "kaisola.cleanup.migrated.\(UUID().uuidString)"
            let currentDefaults = try XCTUnwrap(UserDefaults(suiteName: currentSuiteName))
            let migratedDefaults = try XCTUnwrap(UserDefaults(suiteName: migratedSuiteName))
            defer {
                currentDefaults.removePersistentDomain(forName: currentSuiteName)
                migratedDefaults.removePersistentDomain(forName: migratedSuiteName)
            }
            let defaultsKeys = AcpConversation.persistedDraftDefaultsKeys(for: chatID)
                + AcpConversation.persistedBooleanConfigDefaultsKeys(for: chatID)
            for key in defaultsKeys {
                currentDefaults.set(secret, forKey: key)
                migratedDefaults.set(secret, forKey: key)
            }

            let deletion = await transcriptStore.tombstone(chatID: chatID)
            let receipt = try XCTUnwrap(deletion.snapshot)
            if boundary != .afterTombstone {
                _ = try await workspaceStore.removeAgentChatStateEverywhere(chatID: chatID)
            }
            if boundary == .afterTranscriptCleanup || boundary == .afterDefaultsCleanup {
                let removal = await transcriptStore.remove(
                    chatID: chatID,
                    verifiedDescriptorPruning: receipt
                )
                XCTAssertEqual(removal, .removed, "boundary \(boundary.rawValue)")
            }
            if boundary == .afterDefaultsCleanup {
                AcpConversation.removePersistedDraft(
                    for: chatID,
                    currentDefaults: currentDefaults,
                    migratedDefaults: migratedDefaults
                )
            }

            let sessionStore = NativeSessionStore(
                fileURL: root.appendingPathComponent("sessions.json")
            )
            _ = sessionStore.openProject(directory: projectDirectory.path)
            let model = AppModel(
                sessionStore: sessionStore,
                workspaceStateStore: workspaceStore,
                transcriptStore: transcriptStore,
                usageCenter: UsageCenter(persistenceStore: transcriptStore),
                chatDraftDefaults: currentDefaults,
                migratedChatDraftDefaults: migratedDefaults
            )
            await model.restoreWorkspaceStateIfNeeded()

            await workspaceStore.invalidateCache()
            let restoredProject = try await workspaceStore.projectState(for: projectID)
            let restoredDraft = try await workspaceStore.draft(for: "chat|\(chatID)")
            let restoredTranscript = await transcriptStore.entry(for: chatID)
            let receiptState = await transcriptStore.tombstoneState(chatID: chatID)
            XCTAssertFalse(
                restoredProject?.panes.contains { $0.id == chatID } == true,
                "boundary \(boundary.rawValue)"
            )
            XCTAssertNil(restoredDraft, "boundary \(boundary.rawValue)")
            XCTAssertNil(restoredTranscript, "boundary \(boundary.rawValue)")
            XCTAssertEqual(receiptState, .absent, "boundary \(boundary.rawValue)")
            for key in defaultsKeys {
                XCTAssertNil(currentDefaults.object(forKey: key), "boundary \(boundary.rawValue)")
                XCTAssertNil(migratedDefaults.object(forKey: key), "boundary \(boundary.rawValue)")
            }
            XCTAssertNil(
                try Data(contentsOf: transcriptStore.databaseURL).range(of: secretData),
                "SQLite retained plaintext after \(boundary.rawValue)"
            )
            XCTAssertNil(
                try Data(contentsOf: workspaceURL).range(of: secretData),
                "workspace archive retained plaintext after \(boundary.rawValue)"
            )
            await model.teardown()
        }
    }

    @MainActor
    func testSwitchingProjectRestoresASurfaceInsideThatProject() async throws {
        let (model, _) = makeModel()
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let first = URL(fileURLWithPath: "/tmp/ctx-chat-a", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/ctx-chat-b", isDirectory: true)
        model.openChat(agent, inDirectory: first)
        let firstChat = try XCTUnwrap(model.chats.first)
        model.openChat(agent, inDirectory: second)
        let secondChat = try XCTUnwrap(model.chats.last)
        let secondProject = try XCTUnwrap(model.projects.first { $0.directory?.path == second.path })

        model.selectChat(firstChat.id)
        XCTAssertEqual(model.selectedChatID, firstChat.id)
        model.activateProject(id: secondProject.id)
        XCTAssertEqual(model.selectedProjectID, secondProject.id)
        XCTAssertEqual(model.selectedChatID, secondChat.id)
        XCTAssertNotEqual(model.selectedChatID, firstChat.id)

        for chat in model.chats { await model.deleteChat(chat.id) }
    }

    @MainActor
    func testMeshUsesTheSameStableProjectIdentity() {
        let directory = URL(fileURLWithPath: "/tmp/ctx-mesh", isDirectory: true)
        let mesh = MeshSession(baseDirectory: directory)
        XCTAssertEqual(
            mesh.projectID,
            NativeSessionStore.projectID(forDirectory: directory.path)
        )
    }

    @MainActor
    func testNonOwnerWindowTeardownDoesNotEraseMeshOwnedByAnotherAppModel() async throws {
        let root = storeFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectDirectory = root.appendingPathComponent("shared-mesh-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json"),
            meshWorktreeRoot: root.appendingPathComponent("mesh-worktrees", isDirectory: true)
        )
        let meshPane = Self.meshPane(id: "mesh-shared-window", basePath: projectDirectory.path)
        let projectID = meshPane.surface.projectID
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectID,
                projects: [
                    NativeProjectWorkspaceState(
                        projectID: projectID,
                        layout: SessionPaneLayout(sessionID: meshPane.id),
                        panes: [meshPane],
                        focusedPaneID: meshPane.id
                    ),
                ]
            )
        )

        let owner = makeRestoringModel(
            workspaceStore: workspaceStore,
            root: root,
            identity: "owner",
            projectDirectory: projectDirectory
        )
        let nonOwner = makeRestoringModel(
            workspaceStore: workspaceStore,
            root: root,
            identity: "non-owner",
            projectDirectory: projectDirectory
        )
        await owner.reload()
        await nonOwner.reload()

        let ownerMeshIDs = owner.meshes.map(\.id)
        let nonOwnerMeshIDs = nonOwner.meshes.map(\.id)
        await nonOwner.teardown()
        let stateAfterNonOwnerTeardown = try? await workspaceStore.restorationState()
        await owner.teardown()

        XCTAssertEqual(ownerMeshIDs, [meshPane.id])
        XCTAssertTrue(nonOwnerMeshIDs.isEmpty)
        XCTAssertEqual(
            stateAfterNonOwnerTeardown?.projects
                .first { $0.projectID == projectID }?
                .panes.filter { $0.surface.kind == .mesh }
                .map(\.id),
            [meshPane.id]
        )
    }

    @MainActor
    func testMeshRestorationKeepsQueuedPromptOrderPaused() async throws {
        let root = storeFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectDirectory = root.appendingPathComponent("queued-mesh-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json"),
            meshWorktreeRoot: root.appendingPathComponent("mesh-worktrees", isDirectory: true)
        )
        let meshPane = Self.meshPane(
            id: "mesh-queued-restoration",
            basePath: projectDirectory.path,
            mode: .staged,
            purpose: .build,
            stagedPrompts: ["inspect first", "dispatch second"]
        )
        let projectID = meshPane.surface.projectID
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectID,
                projects: [
                    NativeProjectWorkspaceState(
                        projectID: projectID,
                        layout: SessionPaneLayout(sessionID: meshPane.id),
                        panes: [meshPane],
                        focusedPaneID: meshPane.id
                    ),
                ]
            )
        )

        let model = makeRestoringModel(
            workspaceStore: workspaceStore,
            root: root,
            identity: "queued-prompts",
            projectDirectory: projectDirectory
        )
        await model.reload()
        let mesh = try XCTUnwrap(model.meshes.first { $0.id == meshPane.id })

        XCTAssertEqual(mesh.stagedPrompts, ["inspect first", "dispatch second"])
        XCTAssertEqual(mesh.stagedQueuedPromptCount, 2)
        XCTAssertFalse(mesh.stagedQueueIsRunning)
        XCTAssertEqual(mesh.stage, "Idle")

        await model.teardown()
    }

    @MainActor
    func testMeshCloseRestoreAndPermanentDeletePreserveThenTombstoneQueue() async throws {
        let root = storeFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectDirectory = root.appendingPathComponent("recent-mesh-project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json"),
            meshWorktreeRoot: root.appendingPathComponent("mesh-worktrees", isDirectory: true)
        )
        let pane = Self.meshPane(
            id: "mesh-recent-lifecycle",
            basePath: projectDirectory.path,
            mode: .staged,
            purpose: .build,
            stagedPrompts: ["first queued", "second queued"]
        )
        let projectID = pane.surface.projectID
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            layout: SessionPaneLayout(sessionID: pane.id),
            panes: [pane],
            focusedPaneID: pane.id
        ))
        let model = makeRestoringModel(
            workspaceStore: workspaceStore,
            root: root,
            identity: "recent-mesh",
            projectDirectory: projectDirectory
        )
        await model.reload()

        let firstClose = await model.closeMesh(pane.id)
        XCTAssertEqual(firstClose, .completed)
        XCTAssertTrue(model.meshes.isEmpty)
        XCTAssertEqual(model.recentlyClosedSurfaces(in: projectID).map(\.id), [pane.id])
        let closedState = try await workspaceStore.projectState(for: projectID)
        let closedPane = try XCTUnwrap(closedState?.panes.first { $0.id == pane.id })
        XCTAssertTrue(closedPane.isRecentlyClosed)
        XCTAssertEqual(
            closedPane.surface.meshDescriptor?.stagedPrompts,
            ["first queued", "second queued"]
        )

        await model.teardown()
        let reopened = makeRestoringModel(
            workspaceStore: workspaceStore,
            root: root,
            identity: "recent-mesh-reopened",
            projectDirectory: projectDirectory
        )
        await reopened.reload()
        XCTAssertTrue(reopened.meshes.isEmpty)
        XCTAssertEqual(reopened.recentlyClosedSurfaces(in: projectID).map(\.id), [pane.id])

        let restore = await reopened.restoreRecentlyClosedSurface(pane.id)
        XCTAssertEqual(restore, .completed)
        let restored = try XCTUnwrap(reopened.meshes.first { $0.id == pane.id })
        XCTAssertEqual(restored.stagedPrompts, ["first queued", "second queued"])
        XCTAssertFalse(restored.stagedQueueIsRunning)

        let secondClose = await reopened.closeMesh(pane.id)
        XCTAssertEqual(secondClose, .completed)
        let delete = await reopened.deleteRecentlyClosedSurface(
            pane.id,
            allowRecoverableWork: true
        )
        XCTAssertEqual(delete, .completed)
        XCTAssertTrue(reopened.recentlyClosedSurfaces(in: projectID).isEmpty)
        let deletedState = try await workspaceStore.projectState(for: projectID)
        XCTAssertFalse(deletedState?.panes.contains(where: { $0.id == pane.id }) == true)

        await reopened.teardown()
    }

    func testPreparedMeshTranscriptDeletionSurvivesStaleSnapshotsAndPrunesDraftAtomically() async throws {
        let root = storeFile.deletingLastPathComponent()
        let stateURL = root.appendingPathComponent("prepared-mesh-workspace.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: stateURL)
        let basePath = root.appendingPathComponent("prepared-mesh-project").path
        let projectID = NativeSessionStore.projectID(forDirectory: basePath)
        let meshID = "mesh-transcript-cleanup"
        let columnIDs = ["mesh-cleanup-column-a", "mesh-cleanup-column-b"]
        let columns = columnIDs.enumerated().map { index, columnID in
            NativeRestorableMeshColumnDescriptor(
                id: columnID,
                agentID: index == 0 ? "codex" : "claude",
                role: .ideator,
                worktreePath: nil,
                branch: nil,
                createdBaseOID: nil,
                acpSessionID: nil,
                provisioning: .attached,
                workspaceKind: .base
            )
        }
        let descriptor = NativeRestorableMeshDescriptor(
            id: meshID,
            projectID: projectID,
            basePath: basePath,
            title: "Mesh cleanup",
            mode: .flat,
            purpose: .idea,
            lifecycle: .suspended,
            columns: columns
        )
        let pane = NativeRestorablePaneState(
            id: meshID,
            surface: NativeRestorableSurfaceState(mesh: descriptor)
        )
        let staleSnapshot = NativeWorkspaceRestorationState(projects: [
            NativeProjectWorkspaceState(
                projectID: projectID,
                layout: SessionPaneLayout(sessionID: meshID),
                panes: [pane],
                focusedPaneID: meshID
            ),
        ])
        try await workspaceStore.saveRestorationState(staleSnapshot)
        try await workspaceStore.saveDraft(
            "mesh plaintext draft",
            stableKey: "mesh|\(meshID)",
            projectID: projectID,
            agentID: "mesh",
            workspacePath: basePath
        )

        try await workspaceStore.prepareMeshTranscriptDeletion(
            projectID: projectID,
            meshID: meshID,
            columnIDs: columnIDs
        )
        let preparedState = try await workspaceStore.projectState(for: projectID)
        XCTAssertEqual(
            preparedState?.panes.first?.surface.meshDescriptor?.deletionColumnIDs,
            columnIDs
        )
        let preparedJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        XCTAssertEqual(
            preparedJSON["schemaVersion"] as? Int,
            NativeWorkspaceStateStore.schemaVersion,
            "a downgrade must reject an archive while its deletion bridge is live"
        )

        // MeshSession lifecycle snapshots do not know about the archive-owned
        // bridge. A stale snapshot can update the descriptor, but not clear it.
        try await workspaceStore.saveRestorationState(staleSnapshot)
        let carriedState = try await workspaceStore.projectState(for: projectID)
        XCTAssertEqual(
            carriedState?.panes.first?.surface.meshDescriptor?.deletionColumnIDs,
            columnIDs
        )

        let removed = try await workspaceStore.removeMeshStateEverywhere(meshID: meshID)
        XCTAssertTrue(removed)
        let removedDraft = try await workspaceStore.draft(for: "mesh|\(meshID)")
        XCTAssertNil(removedDraft)

        // A window that sampled the descriptor before deletion cannot merge it
        // back after the explicit process-wide Mesh fence was installed.
        try await workspaceStore.saveRestorationState(staleSnapshot)
        let reopened = NativeWorkspaceStateStore(fileURL: stateURL)
        let restored = try await reopened.restorationState()
        XCTAssertFalse(restored.projects.flatMap(\.panes).contains { $0.id == meshID })
        let reopenedDraft = try await reopened.draft(for: "mesh|\(meshID)")
        XCTAssertNil(reopenedDraft)
        let cleanedJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        XCTAssertEqual(
            cleanedJSON["schemaVersion"] as? Int,
            2,
            "once the critical bridge is gone, ordinary schema-2 compatibility may resume"
        )
    }

    @MainActor
    func testRelaunchFinishesPreparedMeshColumnDeletionWithoutOrphanPlaintext() async throws {
        enum CrashBoundary: CaseIterable {
            case pendingLifecycleWithColumns
            case preparedManifest
            case tombstonedColumns
            case prunedWorkspace
            case removedTranscripts
            case erasedDefaults
        }

        for boundary in CrashBoundary.allCases {
            let root = storeFile.deletingLastPathComponent()
                .appendingPathComponent("mesh-delete-\(String(describing: boundary))", isDirectory: true)
            let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(
                at: projectDirectory,
                withIntermediateDirectories: true
            )
            let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
            let meshID = "mesh-crash-cleanup-\(String(describing: boundary))"
            let columnIDs = [
                "mesh-crash-a-\(String(describing: boundary))",
                "mesh-crash-b-\(String(describing: boundary))",
            ]
            let columns = columnIDs.enumerated().map { index, columnID in
                NativeRestorableMeshColumnDescriptor(
                    id: columnID,
                    agentID: index == 0 ? "codex" : "claude-code",
                    role: .ideator,
                    worktreePath: nil,
                    branch: nil,
                    createdBaseOID: nil,
                    acpSessionID: nil,
                    provisioning: .attached,
                    workspaceKind: .base
                )
            }
            let descriptor = NativeRestorableMeshDescriptor(
                id: meshID,
                projectID: projectID,
                basePath: projectDirectory.path,
                title: "Deleted Mesh",
                mode: .flat,
                purpose: .idea,
                lifecycle: .pendingDeletion,
                columns: boundary == .pendingLifecycleWithColumns ? columns : [],
                deletionColumnIDs: columnIDs
            )
            let workspaceURL = root.appendingPathComponent("workspace.json")
            let workspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
            try await workspaceStore.saveRestorationState(.init(projects: [
                .init(
                    projectID: projectID,
                    layout: SessionPaneLayout(sessionID: meshID),
                    panes: [.init(
                        id: meshID,
                        surface: NativeRestorableSurfaceState(mesh: descriptor)
                    )],
                    focusedPaneID: meshID
                ),
            ]))
            let secret = "MESH_DELETE_SECRET_\(String(describing: boundary))"
            try await workspaceStore.saveDraft(
                secret,
                stableKey: "mesh|\(meshID)",
                projectID: projectID,
                agentID: "mesh",
                workspacePath: projectDirectory.path
            )

            let transcriptStore = AcpTranscriptStore(
                fileURL: root.appendingPathComponent("transcripts.json")
            )
            for columnID in columnIDs {
                let began = await transcriptStore.beginNewChatID(columnID)
                XCTAssertTrue(began)
                await transcriptStore.scheduleSave(
                    [.message(id: "secret", text: secret)],
                    for: columnID,
                    now: 1
                )
            }
            await transcriptStore.flush()

            let currentSuite = "kaisola.mesh.cleanup.current.\(UUID().uuidString)"
            let migratedSuite = "kaisola.mesh.cleanup.migrated.\(UUID().uuidString)"
            let currentDefaults = try XCTUnwrap(UserDefaults(suiteName: currentSuite))
            let migratedDefaults = try XCTUnwrap(UserDefaults(suiteName: migratedSuite))
            defer {
                currentDefaults.removePersistentDomain(forName: currentSuite)
                migratedDefaults.removePersistentDomain(forName: migratedSuite)
            }
            let defaultsKeys = columnIDs.flatMap {
                AcpConversation.persistedDraftDefaultsKeys(for: $0)
                    + AcpConversation.persistedBooleanConfigDefaultsKeys(for: $0)
            }
            for key in defaultsKeys {
                currentDefaults.set(secret, forKey: key)
                migratedDefaults.set(secret, forKey: key)
            }

            var receipts: [AcpTranscriptStore.TombstoneSnapshot] = []
            if boundary != .pendingLifecycleWithColumns && boundary != .preparedManifest {
                let result = await transcriptStore.tombstone(chatIDs: columnIDs)
                guard case let .recorded(recorded) = result else {
                    return XCTFail("expected Mesh tombstones at \(boundary)")
                }
                receipts = recorded
            }
            if boundary == .prunedWorkspace
                || boundary == .removedTranscripts
                || boundary == .erasedDefaults {
                _ = try await workspaceStore.removeMeshStateEverywhere(meshID: meshID)
            }
            if boundary == .removedTranscripts || boundary == .erasedDefaults {
                for receipt in receipts {
                    let removal = await transcriptStore.remove(
                        chatID: receipt.chatID,
                        verifiedDescriptorPruning: receipt
                    )
                    XCTAssertEqual(
                        removal,
                        .removed
                    )
                }
            }
            if boundary == .erasedDefaults {
                for columnID in columnIDs {
                    AcpConversation.removePersistedDraft(
                        for: columnID,
                        currentDefaults: currentDefaults,
                        migratedDefaults: migratedDefaults
                    )
                }
            }

            let sessionStore = NativeSessionStore(fileURL: root.appendingPathComponent("sessions.json"))
            _ = sessionStore.openProject(directory: projectDirectory.path)
            let model = AppModel(
                sessionStore: sessionStore,
                workspaceStateStore: workspaceStore,
                transcriptStore: transcriptStore,
                usageCenter: UsageCenter(persistenceStore: transcriptStore),
                chatDraftDefaults: currentDefaults,
                migratedChatDraftDefaults: migratedDefaults
            )
            await model.restoreWorkspaceStateIfNeeded()

            await workspaceStore.invalidateCache()
            let restored = try await workspaceStore.restorationState()
            XCTAssertFalse(
                restored.projects.flatMap(\.panes).contains { $0.id == meshID },
                "boundary \(boundary)"
            )
            let removedMeshDraft = try await workspaceStore.draft(for: "mesh|\(meshID)")
            XCTAssertNil(removedMeshDraft)
            for columnID in columnIDs {
                let removedEntry = await transcriptStore.entry(for: columnID)
                XCTAssertNil(removedEntry, "boundary \(boundary)")
                let tombstoneState = await transcriptStore.tombstoneState(chatID: columnID)
                XCTAssertEqual(
                    tombstoneState,
                    .absent,
                    "boundary \(boundary)"
                )
            }
            for key in defaultsKeys {
                XCTAssertNil(currentDefaults.object(forKey: key), "boundary \(boundary)")
                XCTAssertNil(migratedDefaults.object(forKey: key), "boundary \(boundary)")
            }
            let secretData = Data(secret.utf8)
            XCTAssertNil(try Data(contentsOf: workspaceURL).range(of: secretData))
            XCTAssertNil(try Data(contentsOf: transcriptStore.databaseURL).range(of: secretData))
            await model.teardown()
        }
    }

    /// Older builds could crash after tombstoning the first member of a Mesh
    /// but before recording the rest of the batch. Launch must treat that one
    /// durable receipt as deletion intent for the complete archived Mesh, bind
    /// every column atomically, and then erase every plaintext location.
    @MainActor
    func testRelaunchReconcilesLegacyPartialMeshTombstoneAcrossEveryColumn() async throws {
        let fixture = try await makeLegacyPartialMeshTombstoneFixture(
            name: "legacy-partial-mesh-success"
        )
        defer {
            fixture.currentDefaults.removePersistentDomain(forName: fixture.currentSuite)
            fixture.migratedDefaults.removePersistentDomain(forName: fixture.migratedSuite)
        }
        let relaunchedStore = AcpTranscriptStore(
            databaseURL: fixture.databaseURL,
            writerID: "legacy-partial-mesh-relaunch",
            schedulesAutomaticFlush: false
        )
        let model = makeLegacyPartialMeshRestoringModel(
            fixture: fixture,
            transcriptStore: relaunchedStore,
            identity: "success"
        )

        await model.restoreWorkspaceStateIfNeeded()

        XCTAssertTrue(model.meshes.isEmpty)
        await fixture.workspaceStore.invalidateCache()
        let restored = try await fixture.workspaceStore.restorationState()
        XCTAssertFalse(restored.projects.flatMap(\.panes).contains { $0.id == fixture.meshID })
        let meshDraft = try await fixture.workspaceStore.draft(for: "mesh|\(fixture.meshID)")
        XCTAssertNil(meshDraft)
        for columnID in fixture.columnIDs {
            let workspaceDraft = try await fixture.workspaceStore.draft(for: "chat|\(columnID)")
            let entry = await relaunchedStore.entry(for: columnID)
            let tombstoneState = await relaunchedStore.tombstoneState(chatID: columnID)
            XCTAssertNil(workspaceDraft)
            XCTAssertNil(entry)
            XCTAssertEqual(tombstoneState, .absent)
        }
        for key in fixture.defaultsKeys {
            XCTAssertNil(fixture.currentDefaults.object(forKey: key))
            XCTAssertNil(fixture.migratedDefaults.object(forKey: key))
        }
        XCTAssertEqual(
            try Self.chatIncarnationCount(at: fixture.databaseURL),
            0,
            "both legacy Mesh column incarnations must be retired"
        )
        let secretData = Data(fixture.secret.utf8)
        XCTAssertNil(try Data(contentsOf: fixture.workspaceURL).range(of: secretData))
        XCTAssertNil(try Data(contentsOf: fixture.databaseURL).range(of: secretData))
        await model.teardown()
    }

    /// The pre-scan must not fall back to the old per-column pruning path when
    /// the all-column tombstone transaction fails. The whole Mesh and every
    /// plaintext location remain fenced and retryable for a healthy relaunch.
    @MainActor
    func testLegacyPartialMeshTombstoneBatchFailureRetainsWholeMesh() async throws {
        let fixture = try await makeLegacyPartialMeshTombstoneFixture(
            name: "legacy-partial-mesh-batch-failure"
        )
        defer {
            fixture.currentDefaults.removePersistentDomain(forName: fixture.currentSuite)
            fixture.migratedDefaults.removePersistentDomain(forName: fixture.migratedSuite)
        }
        let failingStore = AcpTranscriptStore(
            databaseURL: fixture.databaseURL,
            writerID: "legacy-partial-mesh-failing-relaunch",
            schedulesAutomaticFlush: false,
            injectedTombstoneFailure: .open
        )
        let model = makeLegacyPartialMeshRestoringModel(
            fixture: fixture,
            transcriptStore: failingStore,
            identity: "failure"
        )

        await model.restoreWorkspaceStateIfNeeded()

        XCTAssertTrue(model.meshes.isEmpty, "a partially tombstoned Mesh must fail closed")
        await fixture.workspaceStore.invalidateCache()
        let restored = try await fixture.workspaceStore.restorationState()
        XCTAssertTrue(restored.projects.flatMap(\.panes).contains { $0.id == fixture.meshID })
        let meshDraft = try await fixture.workspaceStore.draft(for: "mesh|\(fixture.meshID)")
        XCTAssertEqual(meshDraft, fixture.secret)
        for columnID in fixture.columnIDs {
            let workspaceDraft = try await fixture.workspaceStore.draft(for: "chat|\(columnID)")
            let storedEntry = await failingStore.entry(for: columnID)
            XCTAssertEqual(workspaceDraft, fixture.secret)
            let entry = try XCTUnwrap(storedEntry)
            XCTAssertEqual(entry.draft, fixture.secret)
            XCTAssertEqual(entry.rows, [.message(id: "secret", text: fixture.secret)])
        }
        let firstTombstoneState = await failingStore.tombstoneState(
            chatID: fixture.columnIDs[0]
        )
        let secondTombstoneState = await failingStore.tombstoneState(
            chatID: fixture.columnIDs[1]
        )
        XCTAssertEqual(firstTombstoneState, .present)
        XCTAssertEqual(secondTombstoneState, .absent)
        for key in fixture.defaultsKeys {
            XCTAssertEqual(fixture.currentDefaults.object(forKey: key) as? String, fixture.secret)
            XCTAssertEqual(fixture.migratedDefaults.object(forKey: key) as? String, fixture.secret)
        }
        XCTAssertEqual(
            try Self.chatIncarnationCount(at: fixture.databaseURL),
            1,
            "the failed batch must not retire the untouched sibling incarnation"
        )
        let secretData = Data(fixture.secret.utf8)
        XCTAssertNotNil(try Data(contentsOf: fixture.workspaceURL).range(of: secretData))
        XCTAssertNotNil(try Data(contentsOf: fixture.databaseURL).range(of: secretData))
        await model.teardown()
    }

    @MainActor
    func testUnavailableMeshBaseFolderSurvivesRestoreSaveAndTeardown() async throws {
        let root = storeFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unavailableDirectory = root.appendingPathComponent(
            "temporarily-unmounted-project",
            isDirectory: true
        )
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-state-v1.json"),
            meshWorktreeRoot: root.appendingPathComponent("mesh-worktrees", isDirectory: true)
        )
        let meshPane = Self.meshPane(
            id: "mesh-temporarily-unavailable",
            basePath: unavailableDirectory.path
        )
        let projectID = meshPane.surface.projectID
        try await workspaceStore.saveRestorationState(
            NativeWorkspaceRestorationState(
                selectedProjectID: projectID,
                projects: [
                    NativeProjectWorkspaceState(
                        projectID: projectID,
                        layout: SessionPaneLayout(sessionID: meshPane.id),
                        panes: [meshPane],
                        focusedPaneID: meshPane.id
                    ),
                ]
            )
        )

        let model = makeRestoringModel(
            workspaceStore: workspaceStore,
            root: root,
            identity: "unavailable",
            projectDirectory: unavailableDirectory
        )
        await model.reload()
        let restoredMeshIDs = model.meshes.map(\.id)
        await model.teardown()
        let persisted = try await workspaceStore.restorationState()

        XCTAssertTrue(restoredMeshIDs.isEmpty)
        XCTAssertEqual(
            persisted.projects
                .first { $0.projectID == projectID }?
                .panes.filter { $0.surface.kind == .mesh }
                .map(\.id),
            [meshPane.id]
        )
    }

    @MainActor
    func testPlainShellTitlesUseTheirProjectFolderUntilActivityNamesThem() {
        let projectID = NativeSessionStore.projectID(forDirectory: "/tmp/readable-shells")
        let first = BrokerTerminalRecord(
            id: "term-first", projectID: projectID, pid: 1, exited: false,
            streamEpoch: nil, endOffset: 0
        )
        let second = BrokerTerminalRecord(
            id: "term-second", projectID: projectID, pid: 2, exited: false,
            streamEpoch: nil, endOffset: 0
        )
        let stored = [
            NativeOwnedSession(
                id: first.id, projectID: projectID, cwd: "/tmp/readable-shells",
                title: "readable-shells", createdAt: 1
            ),
            NativeOwnedSession(
                id: second.id, projectID: projectID, cwd: "/tmp/readable-shells",
                title: "readable-shells", createdAt: 2
            ),
        ]

        XCTAssertEqual(
            AppModel.sessionDisplayTitle(
                for: first, visibleRecords: [first, second], storedSessions: stored
            ),
            "readable-shells"
        )
        XCTAssertEqual(
            AppModel.sessionDisplayTitle(
                for: second, visibleRecords: [first, second], storedSessions: stored
            ),
            "readable-shells"
        )
    }

    @MainActor
    func testCustomAndObservedSessionTitlesArePreserved() {
        let record = BrokerTerminalRecord(
            id: "terminal:build", projectID: "nproj_test", pid: 3, exited: false,
            streamEpoch: nil, endOffset: 0
        )
        let custom = NativeOwnedSession(
            id: record.id, projectID: record.projectID, cwd: "/tmp/test",
            title: "Release watcher", createdAt: 1
        )
        XCTAssertEqual(
            AppModel.sessionDisplayTitle(
                for: record, visibleRecords: [record], storedSessions: [custom]
            ),
            "Release watcher"
        )
        XCTAssertEqual(
            AppModel.sessionDisplayTitle(
                for: record, visibleRecords: [record], storedSessions: []
            ),
            "build"
        )
        XCTAssertEqual(
            AppModel.sessionDisplayTitle(
                for: record,
                visibleRecords: [record],
                storedSessions: [],
                aliases: [record.id: "Deploy console"]
            ),
            "Deploy console"
        )
    }

    @MainActor
    func testColdRestoreWithRemovedNamedAccountStopsAtActionableState() throws {
        let (profile, binding) = try restoredChatAccountFixture()
        let now = Date(timeIntervalSince1970: 10)
        let access = ChatAccountAccess(
            binding: binding,
            requiresResolution: true,
            now: now
        )

        let transition = access.reconcile(.init(
            profiles: [],
            readings: [],
            isRefreshing: false,
            now: now
        ))

        XCTAssertEqual(transition, .requiresResumeInvalidation)
        XCTAssertEqual(access.phase, .actionRequired(.accountRemoved))
        XCTAssertFalse(access.allowsAdapterStart)
        let presentation = try XCTUnwrap(access.presentation)
        XCTAssertEqual(presentation.provider, profile.provider.displayName)
        XCTAssertEqual(presentation.account, profile.label)
        XCTAssertFalse(presentation.showsActivityIndicator)
        XCTAssertEqual(presentation.actions, [.signIn, .chooseAccount, .preserveTranscript])
        XCTAssertTrue(presentation.detail.contains("Claude account “Work”"))
        XCTAssertTrue(presentation.detail.contains("transcript and draft are still here"))
    }

    @MainActor
    func testDelayedAccountResolutionUnlocksBeforeBoundedDeadline() throws {
        let (profile, binding) = try restoredChatAccountFixture()
        let now = Date(timeIntervalSince1970: 20)
        let access = ChatAccountAccess(
            binding: binding,
            requiresResolution: true,
            now: now
        )

        _ = access.reconcile(.init(
            profiles: [profile],
            readings: [],
            isRefreshing: true,
            now: now
        ))
        XCTAssertEqual(access.phase, .resolving)
        XCTAssertEqual(access.presentation?.showsActivityIndicator, true)
        XCTAssertTrue(access.presentation?.actions.isEmpty == true)

        let transition = access.reconcile(.init(
            profiles: [profile],
            readings: [signedInReading(profile)],
            isRefreshing: false,
            now: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(transition, .changed)
        XCTAssertEqual(access.phase, .ready)
        XCTAssertTrue(access.allowsAdapterStart)
        XCTAssertNil(access.presentation)
    }

    @MainActor
    func testLogoutInvalidatesResumeAndExposesAllRecoveryActions() throws {
        let (profile, binding) = try restoredChatAccountFixture()
        let access = ChatAccountAccess(binding: binding, requiresResolution: false)
        let signedOut = UsageCenter.ProviderPlanUsage(
            provider: profile.provider.rawValue,
            displayName: profile.provider.displayName,
            profileID: profile.id,
            profileLabel: profile.label,
            ok: false,
            sourceLabel: "fixture",
            windows: [],
            message: "Sign in required"
        )

        let transition = access.reconcile(.init(
            profiles: [profile],
            readings: [signedOut],
            isRefreshing: false,
            now: Date()
        ))

        XCTAssertEqual(transition, .requiresResumeInvalidation)
        XCTAssertEqual(access.phase, .actionRequired(.signedOut))
        XCTAssertEqual(access.presentation?.actions, [.signIn, .chooseAccount, .preserveTranscript])
        XCTAssertEqual(access.presentation?.showsActivityIndicator, false)
    }

    @MainActor
    func testAccountRemovalInvalidatesPreviouslyReadyChatWithoutDeletingItsContract() throws {
        let (_, binding) = try restoredChatAccountFixture()
        let access = ChatAccountAccess(binding: binding, requiresResolution: false)

        let transition = access.reconcile(.init(
            profiles: [],
            readings: [],
            isRefreshing: false,
            now: Date()
        ))

        XCTAssertEqual(transition, .requiresResumeInvalidation)
        XCTAssertEqual(access.phase, .actionRequired(.accountRemoved))
        XCTAssertEqual(access.binding, binding)
        XCTAssertTrue(access.presentation?.detail.contains("transcript and draft are still here") == true)
    }

    @MainActor
    func testOrdinarySignedInRestorationStartsWithoutRecoveryUI() throws {
        let (profile, binding) = try restoredChatAccountFixture()
        let access = ChatAccountAccess(binding: binding, requiresResolution: true)

        let transition = access.reconcile(.init(
            profiles: [profile],
            readings: [signedInReading(profile)],
            isRefreshing: false,
            now: Date()
        ))

        XCTAssertEqual(transition, .changed)
        XCTAssertEqual(access.phase, .ready)
        XCTAssertTrue(access.allowsAdapterStart)
        XCTAssertNil(access.presentation)
    }

    @MainActor
    func testUnresolvedAccountStopsSpinnerAtDeadline() throws {
        let (profile, binding) = try restoredChatAccountFixture()
        let now = Date(timeIntervalSince1970: 30)
        let access = ChatAccountAccess(
            binding: binding,
            requiresResolution: true,
            now: now,
            timeout: 5
        )

        let transition = access.reconcile(.init(
            profiles: [profile],
            readings: [],
            isRefreshing: false,
            now: now.addingTimeInterval(5)
        ))

        XCTAssertEqual(transition, .requiresResumeInvalidation)
        XCTAssertEqual(access.phase, .actionRequired(.resolutionTimedOut))
        XCTAssertFalse(try XCTUnwrap(access.presentation).showsActivityIndicator)
    }

    private func restoredChatAccountFixture() throws -> (
        UsageAccountProfile,
        SessionAccountBinding
    ) {
        let profile = UsageAccountProfile(
            id: "restored-work",
            provider: .claude,
            label: "Work",
            directory: storeFile.deletingLastPathComponent()
                .appendingPathComponent("claude-work", isDirectory: true).path
        )
        let binding = try XCTUnwrap(SessionAccountBinding.resolve(
            provider: profile.provider,
            profile: profile,
            fallbackEnvironment: [:]
        ))
        return (profile, binding)
    }

    private func signedInReading(
        _ profile: UsageAccountProfile
    ) -> UsageCenter.ProviderPlanUsage {
        UsageCenter.ProviderPlanUsage(
            provider: profile.provider.rawValue,
            displayName: profile.provider.displayName,
            profileID: profile.id,
            profileLabel: profile.label,
            ok: true,
            sourceLabel: "fixture",
            account: "ready@example.test",
            windows: []
        )
    }

    @MainActor
    func testChatRestorationLoadsOnlyTailThenFetchesEarlierSQLitePage() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent("paged-chat-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let chatID = "paged-chat"
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-paged-restore.json")
        )
        let descriptor = NativeRestorableAgentChatDescriptor(
            id: chatID,
            projectID: projectID,
            agentID: agent.id,
            workspacePath: projectDirectory.path,
            acpSessionID: nil,
            accountBinding: nil,
            title: "Paged chat"
        )
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            layout: SessionPaneLayout(sessionID: chatID),
            panes: [NativeRestorablePaneState(
                id: chatID,
                surface: NativeRestorableSurfaceState(agentChat: descriptor)
            )],
            focusedPaneID: chatID
        ))

        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("transcripts-paged-restore.json")
        )
        let rows = (0..<1_000).map {
            AcpTranscriptRow.message(id: "\($0)", text: "row \($0)")
        }
        let attachments: [AcpAttachment] = [
            .textFile(path: "/tmp/context.txt", contents: "context", name: "context.txt"),
        ]
        await transcriptStore.scheduleSave(rows, for: chatID, now: 1)
        await transcriptStore.scheduleDraft("restored composer", for: chatID, now: 2)
        await transcriptStore.scheduleAttachments(attachments, for: chatID, now: 3)
        await transcriptStore.flush()

        let model = makeRestoringModel(
            workspaceStore: workspaceStore,
            root: root,
            identity: "paged-restore",
            projectDirectory: projectDirectory
        )
        await model.restoreWorkspaceStateIfNeeded()
        let conversation = try XCTUnwrap(model.chats.first { $0.id == chatID }?.conversation)

        XCTAssertEqual(conversation.rows.count, AcpConversation.defaultVisibleLimit)
        XCTAssertEqual(conversation.rows.first?.id, "msg-880")
        XCTAssertEqual(conversation.loadedRowStartOrdinal, 880)
        XCTAssertEqual(conversation.hiddenEarlierCount, 880)
        XCTAssertEqual(conversation.loadDraft(), "restored composer")
        XCTAssertEqual(conversation.pendingAttachments.map(\.attachment), attachments)

        await conversation.expandEarlier()
        XCTAssertEqual(conversation.rows.count, 320)
        XCTAssertEqual(conversation.rows.first?.id, "msg-680")
        XCTAssertEqual(conversation.loadedRowStartOrdinal, 680)
        XCTAssertEqual(conversation.hiddenEarlierCount, 680)
        await model.teardown()
    }

    /// A chat whose stored rows cannot be decoded keeps its surface, says so,
    /// and does not have its damaged history overwritten by the empty
    /// transcript restoration produced.
    @MainActor
    func testDamagedTranscriptRestoresWithGuidanceAndKeepsTheStoredRows() async throws {
        let root = storeFile.deletingLastPathComponent()
        let projectDirectory = root.appendingPathComponent("damaged-chat-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let chatID = "damaged-chat"
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let workspaceStore = NativeWorkspaceStateStore(
            fileURL: root.appendingPathComponent("workspace-damaged-restore.json")
        )
        try await workspaceStore.saveProjectState(NativeProjectWorkspaceState(
            projectID: projectID,
            layout: SessionPaneLayout(sessionID: chatID),
            panes: [NativeRestorablePaneState(
                id: chatID,
                surface: NativeRestorableSurfaceState(agentChat: NativeRestorableAgentChatDescriptor(
                    id: chatID,
                    projectID: projectID,
                    agentID: agent.id,
                    workspacePath: projectDirectory.path,
                    acpSessionID: nil,
                    accountBinding: nil,
                    title: "Damaged chat"
                ))
            )],
            focusedPaneID: chatID
        ))

        let transcriptURL = root.appendingPathComponent("transcripts-damaged-restore.json")
        let seed = AcpTranscriptStore(fileURL: transcriptURL)
        let rows = (0..<3).map { AcpTranscriptRow.message(id: "\($0)", text: "row \($0)") }
        await seed.scheduleSave(rows, for: chatID, now: 1)
        await seed.flush()
        let databaseURL = seed.databaseURL
        try TranscriptDatabaseProbe.execute(
            "UPDATE transcript_rows SET row_json = X'6E6F70' WHERE chat_id = '\(chatID)'",
            at: databaseURL
        )

        for toast in ToastCenter.shared.toasts { ToastCenter.shared.dismiss(toast.id) }
        let model = makeRestoringModel(
            workspaceStore: workspaceStore,
            root: root,
            identity: "damaged-restore",
            projectDirectory: projectDirectory
        )
        await model.restoreWorkspaceStateIfNeeded()

        let conversation = try XCTUnwrap(model.chats.first { $0.id == chatID }?.conversation)
        XCTAssertTrue(conversation.rows.isEmpty)
        XCTAssertTrue(ToastCenter.shared.toasts.contains {
            $0.message.contains("saved history is damaged")
                && $0.message.contains(databaseURL.path)
        })

        // The chat keeps streaming into a surface whose history we could not
        // read; none of that may reach the rows still on disk.
        model.enqueueTranscriptSave([.message(id: "new", text: "post-damage turn")], chatID: chatID)
        await model.flushTranscriptPersistence()
        XCTAssertEqual(try TranscriptDatabaseProbe.rowCount(chatID: chatID, at: databaseURL), 3)
        await model.teardown()
    }

    @MainActor
    func testAppModelUsesUsageCentersExactRecoveryAuthorityAndState() async throws {
        let root = storeFile.deletingLastPathComponent()
            .appendingPathComponent("shared-project-account-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let accountURL = root.appendingPathComponent("project-accounts.json")
        let recoveryCenter = ProjectAccountRecoveryCenter(
            store: ProjectAccountStore(fileURL: accountURL)
        )
        let transcriptStore = AcpTranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        let usageCenter = UsageCenter(
            persistenceStore: transcriptStore,
            projectAccountRecoveryCenter: recoveryCenter
        )
        let model = AppModel(
            brokerPreparer: ProjectContextBrokerPreparer(),
            fallbackPreparer: nil,
            client: ProjectContextBrokerClient(),
            sessionStore: NativeSessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            workspaceStateStore: NativeWorkspaceStateStore(fileURL: root.appendingPathComponent("workspace.json")),
            transcriptStore: transcriptStore,
            usageCenter: usageCenter
        )

        XCTAssertTrue(model.projectAccountRecoveryCenter === recoveryCenter)
        XCTAssertTrue(usageCenter.projectAccountRecoveryCenter === recoveryCenter)

        try Data("corrupt account mapping".utf8).write(to: accountURL)
        _ = model.projectAccountRecoveryCenter.loadStatus()

        XCTAssertEqual(recoveryCenter.issue?.kind, .corrupt)
        XCTAssertEqual(usageCenter.projectAccountRecoveryCenter.issue?.kind, .corrupt)
        await model.teardown()
    }

    @MainActor
    func testCorruptProjectAccountsBlockChatMeshAndTerminalCreationFunnels() async throws {
        let root = storeFile.deletingLastPathComponent()
            .appendingPathComponent("corrupt-project-account-launches", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let accountURL = root.appendingPathComponent("project-accounts.json")
        let corruptBytes = Data("corrupt account mapping".utf8)
        try corruptBytes.write(to: accountURL)
        let recoveryCenter = ProjectAccountRecoveryCenter(
            store: ProjectAccountStore(fileURL: accountURL)
        )
        let control = ProjectAccountNoLaunchBrokerControlClient()
        let transcriptStore = AcpTranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        let model = AppModel(
            controlClient: control,
            sessionStore: NativeSessionStore(fileURL: root.appendingPathComponent("sessions.json")),
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            workspaceStateStore: NativeWorkspaceStateStore(fileURL: root.appendingPathComponent("workspace.json")),
            transcriptStore: transcriptStore,
            projectAccountRecoveryCenter: recoveryCenter,
            usageCenter: UsageCenter(
                persistenceStore: transcriptStore,
                projectAccountRecoveryCenter: recoveryCenter
            )
        )
        model.loadVisualFixture(workspace: root)
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))

        model.openChat(agent, inDirectory: root)
        model.openMesh(inDirectory: root)
        await model.createAgentSession(agent, inDirectory: root)
        let terminalCreationCount = await control.createCount()

        XCTAssertTrue(model.chats.isEmpty, "the ACP child-process funnel must not materialize a chat")
        XCTAssertTrue(model.meshes.isEmpty, "the Mesh funnel must not schedule any columns")
        XCTAssertEqual(terminalCreationCount, 0, "terminal.create must never reach the broker")
        XCTAssertEqual(recoveryCenter.issue?.kind, .corrupt)
        XCTAssertEqual(try Data(contentsOf: accountURL), corruptBytes)
    }

    @MainActor
    func testCorruptProjectAccountsBlockWorkspaceChatAndMeshRestorationFunnels() async throws {
        let root = storeFile.deletingLastPathComponent()
            .appendingPathComponent("corrupt-project-account-restore", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let agent = try XCTUnwrap(AgentRegistry.profile(id: "codex"))
        let chatID = "blocked-restored-chat"
        let chatDescriptor = NativeRestorableAgentChatDescriptor(
            id: chatID,
            projectID: projectID,
            agentID: agent.id,
            workspacePath: projectDirectory.path,
            acpSessionID: "must-not-resume",
            accountBinding: nil,
            title: "Blocked restored chat"
        )
        let chatPane = NativeRestorablePaneState(
            id: chatID,
            surface: NativeRestorableSurfaceState(agentChat: chatDescriptor)
        )
        let meshPane = Self.meshPane(id: "blocked-restored-mesh", basePath: projectDirectory.path)
        let workspaceStore = NativeWorkspaceStateStore(fileURL: root.appendingPathComponent("workspace.json"))
        try await workspaceStore.saveRestorationState(NativeWorkspaceRestorationState(
            selectedProjectID: projectID,
            projects: [NativeProjectWorkspaceState(
                projectID: projectID,
                layout: SessionPaneLayout(columns: [
                    .init(sessionIDs: [chatPane.id, meshPane.id]),
                ]),
                panes: [chatPane, meshPane],
                focusedPaneID: chatPane.id
            )]
        ))
        let accountURL = root.appendingPathComponent("project-accounts.json")
        try Data("corrupt restored mapping".utf8).write(to: accountURL)
        let recoveryCenter = ProjectAccountRecoveryCenter(
            store: ProjectAccountStore(fileURL: accountURL)
        )
        let model = makeRestoringModel(
            workspaceStore: workspaceStore,
            root: root,
            identity: "blocked-restore",
            projectDirectory: projectDirectory,
            projectAccountRecoveryCenter: recoveryCenter
        )

        await model.restoreWorkspaceStateIfNeeded()

        XCTAssertTrue(model.chats.isEmpty)
        XCTAssertTrue(model.meshes.isEmpty)
        XCTAssertEqual(recoveryCenter.issue?.kind, .corrupt)
    }

    @MainActor
    private func makeRestoringModel(
        workspaceStore: NativeWorkspaceStateStore,
        root: URL,
        identity: String,
        projectDirectory: URL,
        projectAccountRecoveryCenter: ProjectAccountRecoveryCenter = ProjectAccountRecoveryCenter()
    ) -> AppModel {
        let sessionStore = NativeSessionStore(
            fileURL: root.appendingPathComponent("native-sessions-\(identity).json")
        )
        _ = sessionStore.openProject(directory: projectDirectory.path)
        let transcriptStore = AcpTranscriptStore(
            fileURL: root.appendingPathComponent("transcripts-\(identity).json")
        )
        return AppModel(
            brokerPreparer: ProjectContextBrokerPreparer(),
            fallbackPreparer: nil,
            client: ProjectContextBrokerClient(),
            sessionStore: sessionStore,
            cursorStore: TerminalCursorStore(
                fileURL: root.appendingPathComponent("cursors-\(identity).json")
            ),
            workspaceStateStore: workspaceStore,
            transcriptStore: transcriptStore,
            projectAccountRecoveryCenter: projectAccountRecoveryCenter,
            usageCenter: UsageCenter(
                persistenceStore: transcriptStore,
                projectAccountRecoveryCenter: projectAccountRecoveryCenter
            ),
            reconnectBackoff: BrokerReconnectBackoff(
                baseNanoseconds: 1,
                maximumNanoseconds: 2,
                jitterFraction: 0
            ),
            sleep: { _ in await Task.yield() },
            jitter: { 0 }
        )
    }

    private struct LegacyPartialMeshTombstoneFixture {
        let root: URL
        let projectDirectory: URL
        let projectID: String
        let meshID: String
        let columnIDs: [String]
        let secret: String
        let workspaceURL: URL
        let workspaceStore: NativeWorkspaceStateStore
        let databaseURL: URL
        let currentSuite: String
        let migratedSuite: String
        let currentDefaults: UserDefaults
        let migratedDefaults: UserDefaults
        let defaultsKeys: [String]
    }

    @MainActor
    private func makeLegacyPartialMeshTombstoneFixture(
        name: String
    ) async throws -> LegacyPartialMeshTombstoneFixture {
        let root = storeFile.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        let projectID = NativeSessionStore.projectID(forDirectory: projectDirectory.path)
        let meshID = "\(name)-mesh"
        let columnIDs = ["\(name)-a", "\(name)-b"]
        let secret = "KAISOLA_LEGACY_PARTIAL_MESH_SECRET_91D2"
        let columns = columnIDs.enumerated().map { index, columnID in
            NativeRestorableMeshColumnDescriptor(
                id: columnID,
                agentID: index == 0 ? "codex" : "claude-code",
                role: .ideator,
                worktreePath: nil,
                branch: nil,
                createdBaseOID: nil,
                acpSessionID: nil,
                provisioning: .attached,
                workspaceKind: .base
            )
        }
        let descriptor = NativeRestorableMeshDescriptor(
            id: meshID,
            projectID: projectID,
            basePath: projectDirectory.path,
            title: "Legacy partial Mesh",
            mode: .flat,
            purpose: .idea,
            lifecycle: .suspended,
            columns: columns
        )
        let workspaceURL = root.appendingPathComponent("workspace.json")
        let workspaceStore = NativeWorkspaceStateStore(fileURL: workspaceURL)
        try await workspaceStore.saveRestorationState(.init(projects: [
            .init(
                projectID: projectID,
                layout: SessionPaneLayout(sessionID: meshID),
                panes: [.init(
                    id: meshID,
                    surface: NativeRestorableSurfaceState(mesh: descriptor)
                )],
                focusedPaneID: meshID
            ),
        ]))
        try await workspaceStore.saveDraft(
            secret,
            stableKey: "mesh|\(meshID)",
            projectID: projectID,
            agentID: "mesh",
            workspacePath: projectDirectory.path
        )
        for (index, columnID) in columnIDs.enumerated() {
            try await workspaceStore.saveDraft(
                secret,
                stableKey: "chat|\(columnID)",
                projectID: projectID,
                agentID: columns[index].agentID,
                workspacePath: projectDirectory.path
            )
        }

        let databaseURL = root.appendingPathComponent("transcripts.sqlite3")
        let seedStore = AcpTranscriptStore(
            databaseURL: databaseURL,
            writerID: "\(name)-seed",
            schedulesAutomaticFlush: false
        )
        for columnID in columnIDs {
            let began = await seedStore.beginNewChatID(columnID)
            XCTAssertTrue(began)
            await seedStore.scheduleSave(
                [.message(id: "secret", text: secret)],
                for: columnID,
                now: 1
            )
            await seedStore.scheduleDraft(secret, for: columnID, now: 2)
        }
        await seedStore.flush()

        let currentSuite = "kaisola.legacy-mesh.current.\(UUID().uuidString)"
        let migratedSuite = "kaisola.legacy-mesh.migrated.\(UUID().uuidString)"
        let currentDefaults = try XCTUnwrap(UserDefaults(suiteName: currentSuite))
        let migratedDefaults = try XCTUnwrap(UserDefaults(suiteName: migratedSuite))
        let defaultsKeys = columnIDs.flatMap {
            AcpConversation.persistedDraftDefaultsKeys(for: $0)
                + AcpConversation.persistedBooleanConfigDefaultsKeys(for: $0)
        }
        for key in defaultsKeys {
            currentDefaults.set(secret, forKey: key)
            migratedDefaults.set(secret, forKey: key)
        }

        // Simulate the legacy sequential-delete crash: A committed, B did not.
        let partialTombstone = await seedStore.tombstone(chatID: columnIDs[0])
        XCTAssertNotNil(partialTombstone.snapshot)
        return LegacyPartialMeshTombstoneFixture(
            root: root,
            projectDirectory: projectDirectory,
            projectID: projectID,
            meshID: meshID,
            columnIDs: columnIDs,
            secret: secret,
            workspaceURL: workspaceURL,
            workspaceStore: workspaceStore,
            databaseURL: databaseURL,
            currentSuite: currentSuite,
            migratedSuite: migratedSuite,
            currentDefaults: currentDefaults,
            migratedDefaults: migratedDefaults,
            defaultsKeys: defaultsKeys
        )
    }

    @MainActor
    private func makeLegacyPartialMeshRestoringModel(
        fixture: LegacyPartialMeshTombstoneFixture,
        transcriptStore: AcpTranscriptStore,
        identity: String
    ) -> AppModel {
        let sessionStore = NativeSessionStore(
            fileURL: fixture.root.appendingPathComponent("sessions-\(identity).json")
        )
        _ = sessionStore.openProject(directory: fixture.projectDirectory.path)
        return AppModel(
            sessionStore: sessionStore,
            workspaceStateStore: fixture.workspaceStore,
            transcriptStore: transcriptStore,
            usageCenter: UsageCenter(persistenceStore: transcriptStore),
            chatDraftDefaults: fixture.currentDefaults,
            migratedChatDraftDefaults: fixture.migratedDefaults
        )
    }

    private static func chatIncarnationCount(at databaseURL: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "AppModelProjectContextTests.SQLite", code: 1)
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM chat_incarnations",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(domain: "AppModelProjectContextTests.SQLite", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "AppModelProjectContextTests.SQLite", code: 3)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func meshPane(
        id: String,
        basePath: String,
        mode: MeshMode = .flat,
        purpose: MeshPurpose = .idea,
        stagedPrompts: [String] = []
    ) -> NativeRestorablePaneState {
        let descriptor = NativeRestorableMeshDescriptor(
            id: id,
            projectID: NativeSessionStore.projectID(forDirectory: basePath),
            basePath: basePath,
            title: "Mesh · \(id)",
            mode: mode,
            purpose: purpose,
            lifecycle: .suspended,
            columns: [],
            stagedPrompts: stagedPrompts
        )
        return NativeRestorablePaneState(
            id: id,
            surface: NativeRestorableSurfaceState(mesh: descriptor)
        )
    }
}

private actor ProjectAccountNoLaunchBrokerControlClient: BrokerControlServing {
    private var creations = 0

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {}
    func connect(to info: BrokerInfo, ownerID: String) async throws {}

    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int,
        restore: Bool
    ) async throws -> TerminalCreation {
        creations += 1
        return TerminalCreation(
            terminalID: terminalID,
            projectID: projectID,
            pid: 1,
            streamEpoch: "unexpected"
        )
    }

    func attach(projectID: String, terminalID: String) async throws {}
    func write(projectID: String, terminalID: String, data: String) async throws {}
    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws {}
    func kill(projectID: String, terminalID: String) async throws {}
    func release(projectID: String, terminalID: String) async throws {}
    func detachOwner(projectID: String, terminalID: String) async throws {}
    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws {}
    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws {}
    func disconnect() async {}

    func createCount() -> Int { creations }
}

private struct ProjectContextBrokerPreparer: BrokerInfoPreparing {
    func prepare() async throws -> BrokerInfo { Self.info }

    static let info = BrokerInfo(
        protocolVersion: BrokerWire.protocolVersion,
        securityEpoch: BrokerWire.securityEpoch,
        pid: 41_241,
        socketPath: "/tmp/kaisola-project-context-tests.sock",
        token: String(repeating: "c", count: 64),
        startedAt: 1_784_250_003_000,
        version: "test"
    )
}

private actor ProjectContextBrokerClient: ObserveOnlyBrokerServing {
    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async {}
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {}

    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        Self.hello
    }

    func inventory() async throws -> BrokerStatus {
        try BrokerStatus(
            status: .object([
                "ok": .bool(true),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
            ]),
            diagnostics: .array([]),
            live: .array([]),
            expectedHello: Self.hello
        )
    }

    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        throw BrokerClientError.connectionClosed
    }

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {}
    func disconnect() async {}

    private static let hello = BrokerHello(
        protocolVersion: BrokerWire.protocolVersion,
        securityEpoch: BrokerWire.securityEpoch,
        implementationVersion: BrokerWire.implementationVersion,
        packageSchema: nil,
        packageVersion: nil,
        features: [BrokerWire.terminalObserveFeature, BrokerWire.observerRoleFeature],
        pid: ProjectContextBrokerPreparer.info.pid,
        startedAt: ProjectContextBrokerPreparer.info.startedAt,
        version: ProjectContextBrokerPreparer.info.version,
        serverEnforcedObserver: true
    )
}

private actor ProjectContextChangingInventoryBrokerClient: ObserveOnlyBrokerServing {
    private let terminalID: String
    private let projectID: String
    private var terminalIsVisible = true

    init(terminalID: String, projectID: String) {
        self.terminalID = terminalID
        self.projectID = projectID
    }

    func hideTerminal() {
        terminalIsVisible = false
    }

    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async {}
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {}

    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        Self.hello
    }

    func inventory() async throws -> BrokerStatus {
        let diagnostics: JSONValue = terminalIsVisible
            ? .array([
                .object([
                    "id": .string(terminalID),
                    "owner": .string("instance|42|\(projectID)"),
                    "pid": .integer(123),
                    "streamEpoch": .string("epoch"),
                    "endOffset": .integer(0),
                ]),
            ])
            : .array([])
        let live: JSONValue = terminalIsVisible
            ? .array([.object(["id": .string(terminalID), "pid": .integer(123)])])
            : .array([])
        return try BrokerStatus(
            status: .object([
                "ok": .bool(true),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
            ]),
            diagnostics: diagnostics,
            live: live,
            expectedHello: Self.hello
        )
    }

    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        .current(TerminalCursor(streamEpoch: "epoch", offset: 0))
    }

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {}
    func disconnect() async {}

    private static let hello = BrokerHello(
        protocolVersion: BrokerWire.protocolVersion,
        securityEpoch: BrokerWire.securityEpoch,
        implementationVersion: BrokerWire.implementationVersion,
        packageSchema: nil,
        packageVersion: nil,
        features: [BrokerWire.terminalObserveFeature, BrokerWire.observerRoleFeature],
        pid: ProjectContextBrokerPreparer.info.pid,
        startedAt: ProjectContextBrokerPreparer.info.startedAt,
        version: ProjectContextBrokerPreparer.info.version,
        serverEnforcedObserver: true
    )
}
