import Foundation
import KaisolaBrokerProtocol
import KaisolaCore
import XCTest
@testable import Kaisola

/// `AppModel.currentProjectDirectory` — the active-project inference that lets
/// New Terminal/Agent/Chat skip the folder picker (matching Electron).
final class AppModelProjectContextTests: XCTestCase {
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

    @MainActor
    func testChatCloseRestoreAndPermanentDeleteKeepClearDurabilityBoundaries() async throws {
        let (model, _) = makeModel()
        let agent = try XCTUnwrap(AgentRegistry.all.first { AcpAdapter.forAgent($0.id) != nil })
        let directory = storeFile.deletingLastPathComponent()
            .appendingPathComponent("recent-chat-project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.openChat(agent, inDirectory: directory)
        let chat = try XCTUnwrap(model.chats.first)
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
        let deleteResult = await model.deleteRecentlyClosedSurface(
            chat.id,
            allowRecoverableWork: true
        )
        XCTAssertEqual(deleteResult, .completed)
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
    private func makeRestoringModel(
        workspaceStore: NativeWorkspaceStateStore,
        root: URL,
        identity: String,
        projectDirectory: URL
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
            usageCenter: UsageCenter(persistenceStore: transcriptStore),
            reconnectBackoff: BrokerReconnectBackoff(
                baseNanoseconds: 1,
                maximumNanoseconds: 2,
                jitterFraction: 0
            ),
            sleep: { _ in await Task.yield() },
            jitter: { 0 }
        )
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
