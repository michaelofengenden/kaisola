import AppKit
import Foundation
import XCTest
@testable import Kaisola

/// ProjectFiles (tree listing + bounded enumeration) and FilePreviewContent
/// (what a file renders as) — the workspace rail's foundations.
final class WorkspaceFilesTests: XCTestCase {
    func testMarkdownListContinuationHandlesBulletsTasksAndOrderedLists() {
        XCTAssertEqual(MarkdownListContinuation.action(for: "- first"), .continueWith("- "))
        XCTAssertEqual(MarkdownListContinuation.action(for: "  * nested"), .continueWith("  * "))
        XCTAssertEqual(MarkdownListContinuation.action(for: "- [x] shipped"), .continueWith("- [ ] "))
        XCTAssertEqual(MarkdownListContinuation.action(for: "9. ninth"), .continueWith("10. "))
        XCTAssertEqual(MarkdownListContinuation.action(for: "3) third"), .continueWith("4) "))
        XCTAssertEqual(MarkdownListContinuation.action(for: "- "), .exitList)
        XCTAssertEqual(MarkdownListContinuation.action(for: "- [ ] "), .exitList)
        XCTAssertNil(MarkdownListContinuation.action(for: "ordinary paragraph"))
    }

    func testRenderedMarkdownCommandWheelZoomUsesTheSameClampedPolicyAsSourceEditing() throws {
        let zoomedIn = try XCTUnwrap(
            MarkdownWheelZoom.target(current: 1, scrollingDeltaY: 10, scrollingDeltaX: 0)
        )
        let zoomedOut = try XCTUnwrap(
            MarkdownWheelZoom.target(current: 1, scrollingDeltaY: 0, scrollingDeltaX: -10)
        )
        XCTAssertEqual(
            zoomedIn,
            1.1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            zoomedOut,
            0.9,
            accuracy: 0.0001
        )
        XCTAssertNil(MarkdownWheelZoom.target(current: 2, scrollingDeltaY: 20, scrollingDeltaX: 0))
        XCTAssertNil(MarkdownWheelZoom.target(current: 1, scrollingDeltaY: 0, scrollingDeltaX: 0))
    }

    @MainActor
    func testMarkdownEditorContinuesAndExitsListsWithoutChangingPriorText() {
        let textView = MarkdownNativeTextView.wholeFileSourceEditor()
        textView.string = "- first"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- first\n- ")

        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- first\n\n")

        textView.string = "7. item"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "7. item\n8. ")
    }

    @MainActor
    func testMarkdownWholeFileSourceEditorPreservesUnicodeSelectionUndoAndAccessibility() {
        _ = NSApplication.shared
        let textView = MarkdownNativeTextView.wholeFileSourceEditor()
        textView.isRichText = false
        textView.allowsUndo = true

        let source = "# Caf\u{00e9}\r\n\r\n🧑‍💻 e\u{301} [link](relative/file.md)\r\n"
        textView.string = source
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        XCTAssertTrue(window.makeFirstResponder(textView))

        let emojiRange = (source as NSString).range(of: "🧑‍💻")
        textView.setSelectedRange(emojiRange)

        XCTAssertNotNil(textView.textLayoutManager)
        XCTAssertNotNil(textView.textContentStorage)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange(), emojiRange)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertEqual(textView.accessibilityRole(), NSAccessibility.Role.textArea)

        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.insertText("final", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, source + "final")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, source)
        XCTAssertNotNil(textView.textLayoutManager, "undo must not downgrade the source editor to TextKit 1")

        let compositionRange = NSRange(location: (textView.string as NSString).length, length: 0)
        textView.setSelectedRange(compositionRange)
        textView.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: compositionRange
        )
        XCTAssertTrue(textView.hasMarkedText())
        textView.unmarkText()
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertTrue(textView.string.hasSuffix("かな"))
        XCTAssertNotNil(textView.textLayoutManager, "IME composition must remain on TextKit 2")
    }

    @MainActor
    func testMarkdownWholeFileSourceEditorLaysOutOneMiBWithTextKit2Viewport() throws {
        let textView = MarkdownNativeTextView.wholeFileSourceEditor()
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        let row = "0123456789abcdef\n"
        let source = String(repeating: row, count: FilePreviewContent.maxTextBytes / row.utf8.count)
        XCTAssertGreaterThan(source.utf8.count, 900_000)
        XCTAssertLessThanOrEqual(source.utf8.count, FilePreviewContent.maxTextBytes)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.documentView = textView
        let start = ContinuousClock.now
        textView.string = source
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.textViewportLayoutController.layoutViewport()
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(3.5))
        XCTAssertEqual(textView.string.utf8.count, source.utf8.count)
        XCTAssertNotNil(textView.textContentStorage)
    }

    @MainActor
    func testMarkdownWholeFileSourceEditorWrapsToZoomableViewportWithoutTextKitDowngrade() {
        let scrollView = MarkdownMagnifyingScrollView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 480)
        )
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.65
        scrollView.maxMagnification = 2

        let textView = MarkdownNativeTextView.wholeFileSourceEditor()
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = String(repeating: "A long Markdown sentence must wrap. ", count: 20)
        scrollView.documentView = textView

        scrollView.reflowDocumentWidth()
        XCTAssertEqual(textView.frame.width, scrollView.contentView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(
            textView.textContainer?.containerSize.width ?? -1,
            scrollView.contentView.bounds.width - 24,
            accuracy: 0.5
        )
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertNotNil(textView.textLayoutManager)
    }

    func testFileLineNavigationUsesOneBasedLinesAndClampsPastEOF() {
        let text = "alpha\nbeta\r\ngamma"
        XCTAssertEqual(FileLineNavigation.range(forOneBasedLine: 1, in: text), NSRange(location: 0, length: 6))
        XCTAssertEqual(FileLineNavigation.range(forOneBasedLine: 2, in: text), NSRange(location: 6, length: 6))
        XCTAssertEqual(FileLineNavigation.range(forOneBasedLine: 3, in: text), NSRange(location: 12, length: 5))
        XCTAssertEqual(FileLineNavigation.range(forOneBasedLine: 99, in: text), NSRange(location: 17, length: 0))
        XCTAssertEqual(FileLineNavigation.range(forOneBasedLine: 1, in: ""), NSRange(location: 0, length: 0))
    }

    func testMarkdownNavigationFlushesOrWaitsForAutosaveBeforeSwitchingFiles() {
        XCTAssertEqual(
            FilePreviewNavigationPolicy.requestDecision(
                isDirty: false,
                isMarkdown: true,
                isSaving: false,
                hasExternalConflict: false
            ),
            .navigate
        )
        XCTAssertEqual(
            FilePreviewNavigationPolicy.requestDecision(
                isDirty: true,
                isMarkdown: true,
                isSaving: false,
                hasExternalConflict: false
            ),
            .autosave
        )
        XCTAssertEqual(
            FilePreviewNavigationPolicy.requestDecision(
                isDirty: true,
                isMarkdown: true,
                isSaving: true,
                hasExternalConflict: false
            ),
            .awaitCurrentSave
        )
        XCTAssertEqual(
            FilePreviewNavigationPolicy.requestDecision(
                isDirty: true,
                isMarkdown: true,
                isSaving: false,
                hasExternalConflict: true
            ),
            .prompt
        )
        XCTAssertEqual(
            FilePreviewNavigationPolicy.requestDecision(
                isDirty: true,
                isMarkdown: false,
                isSaving: false,
                hasExternalConflict: false
            ),
            .prompt
        )
    }

    func testPendingNavigationSavesTheLatestDraftBeforeItCommits() {
        XCTAssertEqual(
            FilePreviewNavigationPolicy.saveCompletion(
                hasPendingAction: false,
                isDirty: true,
                isMarkdown: true
            ),
            .stay
        )
        XCTAssertEqual(
            FilePreviewNavigationPolicy.saveCompletion(
                hasPendingAction: true,
                isDirty: false,
                isMarkdown: true
            ),
            .completePendingAction
        )
        XCTAssertEqual(
            FilePreviewNavigationPolicy.saveCompletion(
                hasPendingAction: true,
                isDirty: true,
                isMarkdown: true
            ),
            .saveLatestDraft
        )
        XCTAssertEqual(
            FilePreviewNavigationPolicy.saveCompletion(
                hasPendingAction: true,
                isDirty: true,
                isMarkdown: false
            ),
            .prompt
        )

        XCTAssertTrue(FilePreviewNavigationPolicy.shouldRetrySupersededSave(
            taskCancelled: false,
            remainsOnLoadedFile: true,
            recoveryGenerationChanged: true,
            autosavePendingAction: true,
            hasPendingAction: true
        ))
        XCTAssertFalse(FilePreviewNavigationPolicy.shouldRetrySupersededSave(
            taskCancelled: true,
            remainsOnLoadedFile: true,
            recoveryGenerationChanged: true,
            autosavePendingAction: true,
            hasPendingAction: true
        ))
        XCTAssertFalse(FilePreviewNavigationPolicy.shouldRetrySupersededSave(
            taskCancelled: false,
            remainsOnLoadedFile: false,
            recoveryGenerationChanged: true,
            autosavePendingAction: true,
            hasPendingAction: true
        ))
        XCTAssertFalse(FilePreviewNavigationPolicy.shouldRetrySupersededSave(
            taskCancelled: false,
            remainsOnLoadedFile: true,
            recoveryGenerationChanged: true,
            autosavePendingAction: false,
            hasPendingAction: true
        ))
    }

    func testPreviewNoticesDistinguishRecoveryWarningsFromFailures() {
        let recovered = FilePreviewNotice.recoveredDraft(diskChanged: false)
        XCTAssertEqual(recovered.severity, .information)
        XCTAssertEqual(recovered.message, "Recovered an unsaved draft.")
        XCTAssertEqual(recovered.severity.systemImageName, "info.circle.fill")
        XCTAssertEqual(
            recovered.accessibilityLabel,
            "Information: Recovered an unsaved draft."
        )

        let conflicted = FilePreviewNotice.recoveredDraft(diskChanged: true)
        XCTAssertEqual(conflicted.severity, .warning)
        XCTAssertEqual(
            conflicted.message,
            "Recovered an unsaved draft; the file also changed on disk."
        )
        XCTAssertEqual(conflicted.severity.systemImageName, "exclamationmark.triangle.fill")
        XCTAssertEqual(conflicted.severity.accessibilityName, "Warning")

        let failure = FilePreviewNotice.error("Could not save the draft.")
        XCTAssertEqual(failure.severity, .error)
        XCTAssertEqual(failure.severity.systemImageName, "xmark.octagon.fill")
        XCTAssertEqual(failure.accessibilityLabel, "Error: Could not save the draft.")

        let warning = FilePreviewNotice.warning("The file changed on disk.")
        XCTAssertEqual(warning.severity, .warning)
        XCTAssertEqual(warning.message, "The file changed on disk.")
    }
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-ws-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/dep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "swift".write(to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try "junk".write(to: root.appendingPathComponent("node_modules/dep/index.js"), atomically: true, encoding: .utf8)
        try ".hidden".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAgentFileFollowResolvesOnlyExistingWorkspaceFiles() throws {
        let readme = root.appendingPathComponent("README.md").standardizedFileURL
        let source = root.appendingPathComponent("src/main.swift").standardizedFileURL
        XCTAssertEqual(
            WorkspaceAgentFileFollowPolicy.resolve(path: "README.md", workspaceRoot: root),
            readme
        )
        XCTAssertEqual(
            WorkspaceAgentFileFollowPolicy.resolve(path: source.path, workspaceRoot: root),
            source
        )
        XCTAssertNil(WorkspaceAgentFileFollowPolicy.resolve(path: "src", workspaceRoot: root))
        XCTAssertNil(WorkspaceAgentFileFollowPolicy.resolve(path: "missing.swift", workspaceRoot: root))
        XCTAssertNil(WorkspaceAgentFileFollowPolicy.resolve(path: "", workspaceRoot: root))
    }

    func testAgentFileFollowRejectsTraversalAndSymlinkEscapes() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("kaisola-follow-outside-\(UUID().uuidString).swift")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertNil(WorkspaceAgentFileFollowPolicy.resolve(
            path: "../\(outside.lastPathComponent)",
            workspaceRoot: root
        ))
        XCTAssertNil(WorkspaceAgentFileFollowPolicy.resolve(
            path: outside.path,
            workspaceRoot: root
        ))

        let link = root.appendingPathComponent("outside-link.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(WorkspaceAgentFileFollowPolicy.resolve(
            path: link.lastPathComponent,
            workspaceRoot: root
        ))
    }

    func testAgentFileFollowRequiresExplicitModeAndSelectedSurface() {
        let activity = WorkspaceAgentFileActivity(
            sequence: 1,
            projectID: "project-a",
            surfaceID: "chat-a",
            fileURL: root.appendingPathComponent("README.md")
        )
        XCTAssertTrue(WorkspaceAgentFileFollowPolicy.shouldOpen(
            activity,
            enabled: true,
            selectedProjectID: "project-a",
            selectedChatID: "chat-a",
            selectedMeshID: nil
        ))
        XCTAssertTrue(WorkspaceAgentFileFollowPolicy.shouldOpen(
            activity,
            enabled: true,
            selectedProjectID: "project-a",
            selectedChatID: nil,
            selectedMeshID: "chat-a"
        ))
        XCTAssertFalse(WorkspaceAgentFileFollowPolicy.shouldOpen(
            activity,
            enabled: false,
            selectedProjectID: "project-a",
            selectedChatID: "chat-a",
            selectedMeshID: nil
        ))
        XCTAssertFalse(WorkspaceAgentFileFollowPolicy.shouldOpen(
            activity,
            enabled: true,
            selectedProjectID: "project-b",
            selectedChatID: "chat-a",
            selectedMeshID: nil
        ))
        XCTAssertFalse(WorkspaceAgentFileFollowPolicy.shouldOpen(
            activity,
            enabled: true,
            selectedProjectID: "project-a",
            selectedChatID: "chat-b",
            selectedMeshID: nil
        ))
    }

    func testChildrenSkipsIgnoredAndHiddenAndSortsDirsFirst() {
        let children = ProjectFiles.children(of: root)
        XCTAssertEqual(children.map(\.name), ["src", "README.md"])
        XCTAssertTrue(children[0].isDirectory)
    }

    func testWorkspaceRenameMovesAnItemWithoutOverwriting() throws {
        let source = root.appendingPathComponent("README.md")
        let move = try WorkspaceFileOperations.rename(
            item: source,
            to: "GUIDE.md",
            workspaceRoot: root
        )

        XCTAssertEqual(move.source, source.standardizedFileURL)
        XCTAssertEqual(move.destination, root.appendingPathComponent("GUIDE.md").standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: move.destination, encoding: .utf8), "hello")

        try "occupied".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try WorkspaceFileOperations.rename(item: source, to: "GUIDE.md", workspaceRoot: root)
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .destinationExists)
        }
    }

    func testWorkspaceMoveCrossesDirectoriesWithoutOverwriting() throws {
        let source = root.appendingPathComponent("README.md")
        let destination = root.appendingPathComponent("src/README.md")
        let plan = try WorkspaceFileOperations.movePlan(
            item: source,
            to: destination,
            workspaceRoot: root
        )
        XCTAssertEqual(plan.source, source.standardizedFileURL)
        XCTAssertEqual(plan.destination, destination.standardizedFileURL)

        let move = try WorkspaceFileOperations.move(
            item: source,
            to: destination,
            workspaceRoot: root
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: move.destination, encoding: .utf8), "hello")

        let collidingSource = root.appendingPathComponent("main.swift")
        try "collision".write(to: collidingSource, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkspaceFileOperations.move(
            item: collidingSource,
            to: root.appendingPathComponent("src/main.swift"),
            workspaceRoot: root
        )) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .destinationExists)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: collidingSource.path))
    }

    func testWorkspaceMoveRejectsSameLocationDescendantsAndSymlinkParents() throws {
        let source = root.appendingPathComponent("src", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertThrowsError(try WorkspaceFileOperations.movePlan(
            item: source,
            to: source,
            workspaceRoot: root
        )) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .unchangedLocation)
        }
        XCTAssertThrowsError(try WorkspaceFileOperations.movePlan(
            item: source,
            to: nested.appendingPathComponent("src", isDirectory: true),
            workspaceRoot: root
        )) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .destinationInsideItem)
        }

        let linkedParent = root.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: root.appendingPathComponent("node_modules", isDirectory: true)
        )
        XCTAssertThrowsError(try WorkspaceFileOperations.movePlan(
            item: root.appendingPathComponent("README.md"),
            to: linkedParent.appendingPathComponent("README.md"),
            workspaceRoot: root
        )) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .symbolicLink)
        }
    }

    func testMoveDestinationListIsBoundedAndOmitsCurrentParentAndSourceSubtree() throws {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let nested = docs.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let fileDestinations = ProjectFiles.moveDestinationDirectories(
            root: root,
            movingItem: root.appendingPathComponent("README.md")
        )
        XCTAssertEqual(fileDestinations.map(\.path), [
            docs.path,
            nested.path,
            root.appendingPathComponent("src", isDirectory: true).path,
        ])

        let directoryDestinations = ProjectFiles.moveDestinationDirectories(
            root: root,
            movingItem: docs
        )
        XCTAssertEqual(directoryDestinations.map(\.path), [
            root.appendingPathComponent("src", isDirectory: true).path,
        ])
        XCTAssertTrue(ProjectFiles.moveDestinationDirectories(
            root: root,
            movingItem: root.appendingPathComponent("README.md"),
            limit: 1
        ).isEmpty)
        XCTAssertTrue(ProjectFiles.moveDestinationDirectories(
            root: root,
            movingItem: root.appendingPathComponent("README.md"),
            visitLimit: 1
        ).isEmpty)
    }

    /// The Move sheet used to dismiss the instant `performMove` accepted the
    /// request, which was before the move had run at all. A failure then landed
    /// as a toast with the destination list already gone, so the only way back
    /// was to rebuild the whole operation.
    @MainActor
    func testMoveSheetKeepsTheItemAndDestinationSelectedWhenTheMoveFails() async throws {
        let item = FileNode(
            url: root.appendingPathComponent("README.md").standardizedFileURL,
            isDirectory: false
        )
        let controller = WorkspaceMoveController(root: root, item: item)
        await controller.loadDestinations()
        let destination = try XCTUnwrap(
            controller.visibleDirectories.first { $0.lastPathComponent == "src" }
        )
        controller.select(destination)

        let refusal = "Could not move README.md: an item with that name is already there."
        await controller.submit { _ in .failed(refusal) }

        XCTAssertEqual(controller.phase, .failed(refusal))
        XCTAssertEqual(controller.failureMessage, refusal)
        XCTAssertFalse(
            controller.isFinished,
            "the sheet was allowed to close on a move that never succeeded"
        )
        XCTAssertEqual(controller.item.url, item.url)
        XCTAssertEqual(
            controller.selectedDirectory,
            destination,
            "the picked destination has to survive the failure for Retry to mean anything"
        )

        // Retry is the same operation again, not a rebuilt one.
        await controller.submit { attempted in
            XCTAssertEqual(attempted, destination)
            return .succeeded
        }
        XCTAssertTrue(controller.isFinished)
        XCTAssertNil(controller.failureMessage)
    }

    @MainActor
    func testMoveSheetReportsTheMoveInFlightAndFinishesOnlyOnConfirmedSuccess() async throws {
        let item = FileNode(
            url: root.appendingPathComponent("README.md").standardizedFileURL,
            isDirectory: false
        )
        let controller = WorkspaceMoveController(root: root, item: item)
        await controller.loadDestinations()
        XCTAssertEqual(controller.phase, .choosing)
        XCTAssertFalse(controller.isMoving)
        XCTAssertNotNil(controller.selectedDirectory)

        await controller.submit { _ in
            // While the filesystem work runs the sheet is still up, and says so.
            XCTAssertTrue(controller.isMoving, "the sheet showed no progress while moving")
            XCTAssertFalse(controller.isFinished, "the sheet closed before the move finished")
            await Task.yield()
            XCTAssertFalse(controller.isFinished)
            return .succeeded
        }

        XCTAssertEqual(controller.phase, .succeeded)
        XCTAssertTrue(controller.isFinished)
        XCTAssertNil(controller.failureMessage)
    }

    @MainActor
    func testMoveSheetSearchAndReselectionKeepAVisibleDestinationPicked() async throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("docs", isDirectory: true),
            withIntermediateDirectories: true
        )
        let item = FileNode(
            url: root.appendingPathComponent("README.md").standardizedFileURL,
            isDirectory: false
        )
        let controller = WorkspaceMoveController(root: root, item: item)
        await controller.loadDestinations()
        XCTAssertEqual(controller.selectedDirectory?.lastPathComponent, "docs")

        controller.searchText = "src"
        XCTAssertEqual(controller.selectedDirectory?.lastPathComponent, "src")
        controller.searchText = ""
        XCTAssertEqual(controller.selectedDirectory?.lastPathComponent, "src")

        await controller.submit { _ in .failed("Could not move README.md.") }
        XCTAssertNotNil(controller.failureMessage)

        // Choosing somewhere else retires the diagnostic it was about.
        let docs = try XCTUnwrap(
            controller.visibleDirectories.first { $0.lastPathComponent == "docs" }
        )
        controller.select(docs)
        XCTAssertNil(controller.failureMessage)
        XCTAssertEqual(controller.phase, .choosing)
        XCTAssertEqual(controller.selectedDirectory, docs)
    }

    func testWorkspaceCreateFileAndFolderAreExclusiveAndWorkspaceBounded() throws {
        let folder = try WorkspaceFileOperations.createFolder(
            named: "Notes",
            in: root,
            workspaceRoot: root
        )
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.path))

        let file = try WorkspaceFileOperations.createFile(
            named: "today.md",
            in: folder.url,
            workspaceRoot: root
        )
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(try Data(contentsOf: file.url), Data())

        XCTAssertThrowsError(
            try WorkspaceFileOperations.createFile(
                named: "today.md",
                in: folder.url,
                workspaceRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .destinationExists)
        }
        XCTAssertThrowsError(
            try WorkspaceFileOperations.createFile(
                named: "nested/escape.md",
                in: root,
                workspaceRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .invalidName)
        }

        let outside = root.deletingLastPathComponent()
        XCTAssertThrowsError(
            try WorkspaceFileOperations.createFolder(
                named: "escape-(UUID().uuidString)",
                in: outside,
                workspaceRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .outsideWorkspace)
        }
    }

    func testWorkspaceCreateRejectsSymlinkParent() throws {
        let linkedDirectory = root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: root.appendingPathComponent("src", isDirectory: true)
        )

        XCTAssertThrowsError(
            try WorkspaceFileOperations.createFile(
                named: "unsafe.md",
                in: linkedDirectory,
                workspaceRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .symbolicLink)
        }
    }

    func testWorkspaceTrashRestoreRefusesDestinationCollision() throws {
        let original = root.appendingPathComponent("restored.md")
        let stagedTrash = root.deletingLastPathComponent()
            .appendingPathComponent("kaisola-trash-stage-(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: stagedTrash) }
        try "recover me".write(to: stagedTrash, atomically: true, encoding: .utf8)
        let move = WorkspaceFileOperations.TrashMove(
            original: original.standardizedFileURL,
            trashed: stagedTrash.standardizedFileURL
        )

        try WorkspaceFileOperations.restoreFromTrash(move, workspaceRoot: root)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "recover me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedTrash.path))

        try "newer".write(to: stagedTrash, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try WorkspaceFileOperations.restoreFromTrash(move, workspaceRoot: root)
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .destinationExists)
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "recover me")
    }

    func testWorkspaceRenameRejectsInvalidNamesAndUnchangedName() {
        let source = root.appendingPathComponent("README.md")
        for name in ["", ".", "..", "nested/name", "line\nbreak", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(
                try WorkspaceFileOperations.renameMove(item: source, to: name, workspaceRoot: root),
                "expected rejection for \(name.debugDescription)"
            )
        }
        XCTAssertThrowsError(
            try WorkspaceFileOperations.renameMove(item: source, to: "README.md", workspaceRoot: root)
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .unchangedName)
        }
    }

    func testWorkspaceOperationsRejectRootOutsideAndSymlinkPaths() throws {
        XCTAssertThrowsError(
            try WorkspaceFileOperations.trashCandidate(item: root, workspaceRoot: root)
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .workspaceRoot)
        }

        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try WorkspaceFileOperations.trashCandidate(item: outside, workspaceRoot: root)
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .outsideWorkspace)
        }

        let linkedFile = root.appendingPathComponent("linked-file")
        try FileManager.default.createSymbolicLink(
            at: linkedFile,
            withDestinationURL: root.appendingPathComponent("README.md")
        )
        XCTAssertThrowsError(
            try WorkspaceFileOperations.renameMove(item: linkedFile, to: "other", workspaceRoot: root)
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .symbolicLink)
        }

        let linkedDirectory = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: root.appendingPathComponent("src", isDirectory: true)
        )
        XCTAssertThrowsError(
            try WorkspaceFileOperations.trashCandidate(
                item: linkedDirectory.appendingPathComponent("main.swift"),
                workspaceRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceFileOperations.OperationError, .symbolicLink)
        }
    }

    func testWorkspaceOperationSubtreeMappingUsesPathComponents() {
        let source = root.appendingPathComponent("src", isDirectory: true)
        let destination = root.appendingPathComponent("Sources", isDirectory: true)
        let child = source.appendingPathComponent("nested/main.swift")
        let siblingPrefix = root.appendingPathComponent("src-copy/main.swift")

        XCTAssertEqual(
            WorkspaceFileOperations.replacingPrefix(of: child, from: source, to: destination),
            destination.appendingPathComponent("nested/main.swift").standardizedFileURL
        )
        XCTAssertNil(
            WorkspaceFileOperations.replacingPrefix(of: siblingPrefix, from: source, to: destination)
        )
        XCTAssertTrue(WorkspaceFileOperations.contains(child, in: source))
        XCTAssertFalse(WorkspaceFileOperations.contains(siblingPrefix, in: source))
    }

    func testEnumerateReturnsRelativePathsExcludingIgnored() {
        let files = ProjectFiles.enumerate(root: root)
        XCTAssertEqual(Set(files), ["README.md", "src/main.swift"])
    }

    func testEnumerateHonorsTheLimit() throws {
        for index in 0..<20 {
            try "x".write(to: root.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(ProjectFiles.enumerate(root: root, limit: 5).count, 5)
    }

    func testEnumerateHonorsDirectoryAndVisitBounds() {
        let rootOnly = ProjectFiles.enumerate(
            root: root,
            directoryLimit: 1,
            visitLimit: 100
        )
        XCTAssertEqual(rootOnly, ["README.md"])

        let oneVisit = ProjectFiles.enumerate(
            root: root,
            directoryLimit: 100,
            visitLimit: 1
        )
        XCTAssertLessThanOrEqual(oneVisit.count, 1)
        XCTAssertLessThan(oneVisit.count, ProjectFiles.enumerate(root: root).count)
    }

    func testEnumerateCooperativelyStopsWhenCancelled() throws {
        for index in 0..<20 {
            try "x".write(
                to: root.appendingPathComponent("file\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        var cancellationChecks = 0
        let files = ProjectFiles.enumerate(root: root, isCancelled: {
            cancellationChecks += 1
            return cancellationChecks >= 5
        })

        XCTAssertGreaterThanOrEqual(cancellationChecks, 5)
        XCTAssertLessThan(files.count, 21)
    }

    func testDetailedChangesPatchOnlyAffectedIndexSubtrees() throws {
        let original = ProjectFiles.enumerate(root: root)
        let added = root.appendingPathComponent("src/new.swift")
        try "new".write(to: added, atomically: true, encoding: .utf8)
        let hidden = root.appendingPathComponent("src/.generated.swift")
        try "hidden".write(to: hidden, atomically: true, encoding: .utf8)

        let updated = try XCTUnwrap(ProjectFiles.updatingIndex(
            original,
            root: root,
            changedPaths: [root.appendingPathComponent("src", isDirectory: true)]
        ))
        XCTAssertEqual(Set(updated), ["README.md", "src/main.swift", "src/new.swift"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("README.md"))
        let afterRemoval = try XCTUnwrap(ProjectFiles.updatingIndex(
            updated,
            root: root,
            changedPaths: [root.appendingPathComponent("README.md")]
        ))
        XCTAssertEqual(Set(afterRemoval), ["src/main.swift", "src/new.swift"])
        XCTAssertNil(ProjectFiles.updatingIndex(
            afterRemoval,
            root: root,
            changedPaths: [root]
        ), "a root event must request a complete bounded walk")
    }

    @MainActor
    func testDetailedIndexInvalidationAvoidsASecondRepositoryWalk() async throws {
        let probe = ProjectFileIndexStaticProbe(files: ProjectFiles.enumerate(root: root))
        let index = ProjectFileIndex(enumerateFiles: probe.enumerate)
        _ = await index.files(for: root)
        XCTAssertEqual(probe.startedCount, 1)

        let added = root.appendingPathComponent("src/targeted.swift")
        try "targeted".write(to: added, atomically: true, encoding: .utf8)
        index.invalidate(
            root: root,
            changedPaths: [added],
            requiresFullRefresh: false
        )

        let updated = await index.files(for: root)
        XCTAssertTrue(updated.contains("src/targeted.swift"))
        XCTAssertEqual(probe.startedCount, 1, "an exact file event should patch the cached index")
    }

    @MainActor
    func testInvalidationSerializesReplacementWalkAndCachesOnlyReplacement() async {
        let probe = ProjectFileIndexProbe()
        let index = ProjectFileIndex(enumerateFiles: probe.enumerate)

        let first = Task { await index.files(for: root) }
        for _ in 0..<200 where probe.startedCount == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(probe.startedCount, 1)

        index.invalidate()
        let replacement = Task { await index.files(for: root) }
        _ = await first.value
        let replacementFiles = await replacement.value
        XCTAssertEqual(replacementFiles, ["walk-2"])
        XCTAssertEqual(probe.maximumConcurrentWalks, 1)

        let cachedFiles = await index.files(for: root)
        XCTAssertEqual(cachedFiles, ["walk-2"])
        XCTAssertEqual(probe.startedCount, 2, "the replacement result should be cached")
    }

    @MainActor
    func testWaiterThatJoinedBeforeInvalidationAlsoReceivesReplacementWalk() async {
        let probe = ProjectFileIndexProbe()
        let index = ProjectFileIndex(enumerateFiles: probe.enumerate)

        // The first walk is held open, so the waiter below cannot finish early
        // and the "has it joined yet" wait has no deadline to lose to.
        probe.holdFirstWalk()
        let owner = Task { await index.files(for: root) }
        for _ in 0..<200 where probe.startedCount == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(probe.startedCount, 1)

        let preInvalidationWaiter = Task { await index.files(for: root) }
        for _ in 0..<50 { await Task.yield() }
        index.invalidate()
        probe.releaseFirstWalk()

        let ownerFiles = await owner.value
        let waiterFiles = await preInvalidationWaiter.value
        XCTAssertEqual(ownerFiles, ["walk-2"])
        XCTAssertEqual(waiterFiles, ["walk-2"])
        XCTAssertEqual(probe.maximumConcurrentWalks, 1)
        XCTAssertEqual(probe.startedCount, 2)
    }

    @MainActor
    func testPreviewContentClassifiesFiles() throws {
        XCTAssertEqual(FilePreviewContent.load(url: root.appendingPathComponent("README.md")), .markdown("hello"))
        XCTAssertEqual(FilePreviewContent.load(url: root.appendingPathComponent("src/main.swift")), .text("swift"))

        let html = root.appendingPathComponent("preview.html")
        try "<h1>Hello</h1>".write(to: html, atomically: true, encoding: .utf8)
        XCTAssertEqual(FilePreviewContent.load(url: html), .html("<h1>Hello</h1>"))

        let binary = root.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x81]).write(to: binary)
        XCTAssertEqual(FilePreviewContent.load(url: binary), .binary)

        let image = root.appendingPathComponent("pic.png")
        try Data([0x89, 0x50]).write(to: image)
        XCTAssertEqual(FilePreviewContent.load(url: image), .image)

        let pdf = root.appendingPathComponent("review.pdf")
        let pdfSource = NSTextField(labelWithString: "Native PDF preview")
        pdfSource.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        try pdfSource.dataWithPDF(inside: pdfSource.bounds).write(to: pdf)
        XCTAssertEqual(FilePreviewContent.load(url: pdf), .pdf)
        XCTAssertEqual(PDFDocumentIO.load(url: pdf)?.value.pageCount, 1)

        XCTAssertEqual(FilePreviewContent.load(url: root.appendingPathComponent("missing.txt")), .unreadable)
    }

    func testPreviewContentDecodesUnicodeAndCommonExportEncodingsWithoutTreatingBinaryAsText() throws {
        let utf16 = root.appendingPathComponent("utf16.md")
        try "# Héllo".data(using: .utf16)!.write(to: utf16)
        XCTAssertEqual(FilePreviewContent.load(url: utf16), .markdown("# Héllo"))

        let latin1 = root.appendingPathComponent("latin1.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: latin1)
        XCTAssertEqual(FilePreviewContent.load(url: latin1), .text("café"))

        let nulBinary = root.appendingPathComponent("nul.bin")
        try Data([0x61, 0x00, 0x62, 0x03, 0x7F]).write(to: nulBinary)
        XCTAssertEqual(FilePreviewContent.load(url: nulBinary), .binary)

        let notebook = root.appendingPathComponent("analysis.ipynb")
        try #"{"cells":[]}"#.write(to: notebook, atomically: true, encoding: .utf8)
        XCTAssertEqual(FilePreviewContent.load(url: notebook), .json(#"{"cells":[]}"#))
    }

    func testWorkspaceFileClipboardCopiesMarkdownSourceAndRejectsBinary() throws {
        let markdown = root.appendingPathComponent("copy.md")
        try "# Copy me\n\n`exact`".write(to: markdown, atomically: true, encoding: .utf8)
        XCTAssertEqual(WorkspaceFileClipboard.contents(of: markdown), "# Copy me\n\n`exact`")

        let binary = root.appendingPathComponent("copy.bin")
        try Data([0x00, 0x01, 0x02]).write(to: binary)
        XCTAssertNil(WorkspaceFileClipboard.contents(of: binary))
    }

    func testDocxClassificationAndRichTextRoundTrip() throws {
        let file = root.appendingPathComponent("notes.docx")
        let source = NSAttributedString(string: "Editable native document")
        try RichDocumentIO.write(source, to: file)

        XCTAssertEqual(FilePreviewContent.load(url: file), .docx)
        XCTAssertEqual(
            RichDocumentIO.load(url: file)?.value.string.trimmingCharacters(in: .newlines),
            source.string
        )
    }

    func testFilePreviewRecoveryStoreRoundTripsLatestTextWithOwnerOnlyPermissions() throws {
        let recoveryDirectory = root.appendingPathComponent(".preview-recovery", isDirectory: true)
        let store = FilePreviewRecoveryStore(directoryURL: recoveryDirectory)
        let file = root.appendingPathComponent("README.md")
        let expectedDate = FilePreviewDiskState.modificationDate(of: file)

        _ = try store.saveText(
            "first unsaved draft",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: expectedDate,
            ownerID: "editor-a",
            revision: 1
        )
        let latestToken = try store.saveText(
            "latest unsaved draft",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: expectedDate,
            ownerID: "editor-a",
            revision: 2
        )

        let record = try XCTUnwrap(store.loadNewest(for: file, workspaceRoot: root))
        XCTAssertEqual(record.kind, .text)
        XCTAssertEqual(record.text, "latest unsaved draft")
        XCTAssertEqual(record.expectedModificationDate, expectedDate)

        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: recoveryDirectory.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        let files = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        )
        let records = files.filter { $0.pathExtension == "json" }
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(files.contains { $0.pathExtension == "tmp" })
        let recordMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: try XCTUnwrap(records.first).path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(recordMode & 0o777, 0o600)

        XCTAssertTrue(store.remove(latestToken, for: file, workspaceRoot: root))
        XCTAssertNil(try store.loadNewest(for: file, workspaceRoot: root))
    }

    func testFilePreviewRecoveryStoreKeepsOwnersIndependentAndRemovalConditional() throws {
        let store = FilePreviewRecoveryStore(
            directoryURL: root.appendingPathComponent(".preview-recovery", isDirectory: true)
        )
        let file = root.appendingPathComponent("README.md")
        let firstOwner = try store.saveText(
            "window A draft",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "window-a",
            revision: 1
        )
        let secondOwner = try store.saveText(
            "window B draft",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "window-b",
            revision: 1
        )

        XCTAssertEqual(try store.loadNewest(for: file, workspaceRoot: root)?.text, "window B draft")
        XCTAssertTrue(store.remove(firstOwner, for: file, workspaceRoot: root))
        XCTAssertEqual(try store.loadNewest(for: file, workspaceRoot: root)?.token, secondOwner)

        let staleToken = FilePreviewRecoveryToken(
            ownerID: secondOwner.ownerID,
            revision: 0,
            payloadDigest: secondOwner.payloadDigest
        )
        XCTAssertFalse(store.remove(staleToken, for: file, workspaceRoot: root))
        XCTAssertEqual(try store.loadNewest(for: file, workspaceRoot: root)?.text, "window B draft")
    }

    func testRecoveryViewPolicyExcludesLiveOwnersAndResolvesOnlyClaimedLineage() {
        func record(owner: String, revision: UInt64, digest: String, updatedAt: Date) -> FilePreviewRecoveryRecord {
            FilePreviewRecoveryRecord(
                version: 1,
                filePath: root.appendingPathComponent("README.md").path,
                workspacePath: root.path,
                ownerID: owner,
                revision: revision,
                payloadDigest: digest,
                kind: .text,
                text: digest,
                richDocumentData: nil,
                expectedModificationDate: nil,
                updatedAt: updatedAt,
                sourceTokens: nil,
                fenceProcessID: nil
            )
        }

        let orphan = record(owner: "prior-process", revision: 7, digest: "old-digest", updatedAt: .distantPast)
        let live = record(owner: "live-window", revision: 9, digest: "live-digest", updatedAt: .distantFuture)
        XCTAssertEqual(
            FilePreviewRecoveryViewPolicy.newestRestorable(
                in: [orphan, live],
                activeOwnerIDs: ["live-window", "new-window"]
            )?.token,
            orphan.token
        )

        let current = FilePreviewRecoveryToken(
            ownerID: "new-window",
            revision: 8,
            payloadDigest: "edited-digest"
        )
        let resolved = FilePreviewRecoveryViewPolicy.tokensToResolve(
            ownedToken: current,
            claimedSourceTokens: [orphan.token]
        )
        XCTAssertEqual(Set(resolved), [current, orphan.token])
        XCTAssertFalse(resolved.contains(live.token))
    }

    func testClaimedOrphanIsHiddenFromSecondLiveViewAndEditedSaveCannotResurrectIt() throws {
        let recoveryDirectory = root.appendingPathComponent(".preview-recovery", isDirectory: true)
        let store = FilePreviewRecoveryStore(directoryURL: recoveryDirectory)
        let file = root.appendingPathComponent("README.md")
        let orphan = try store.saveText(
            "prior-process draft",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "prior-process",
            revision: 1
        )
        let live = try store.saveText(
            "live draft",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "live-window",
            revision: 1
        )

        let registry = FilePreviewRecoveryOwnerRegistry()
        for owner in ["live-window", "claimant-a", "claimant-b"] { registry.register(owner) }
        defer {
            for owner in ["live-window", "claimant-a", "claimant-b"] { registry.unregister(owner) }
        }
        let claim = try XCTUnwrap(store.claimNewestOrphan(
            for: file,
            workspaceRoot: root,
            claimantID: "claimant-a",
            ownerRegistry: registry
        ))
        XCTAssertEqual(claim.record.text, "prior-process draft")
        XCTAssertEqual(claim.sourceTokens, [orphan])
        XCTAssertNil(try store.claimNewestOrphan(
            for: file,
            workspaceRoot: root,
            claimantID: "claimant-b",
            ownerRegistry: registry
        ))

        let edited = try store.saveText(
            "recovered and edited",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "claimant-a",
            revision: claim.record.revision + 1,
            sourceTokens: claim.sourceTokens
        )
        XCTAssertNotEqual(edited.payloadDigest, orphan.payloadDigest)
        for token in FilePreviewRecoveryViewPolicy.tokensToResolve(
            ownedToken: edited,
            claimedSourceTokens: claim.sourceTokens
        ) {
            XCTAssertTrue(store.remove(token, for: file, workspaceRoot: root))
        }
        store.releaseClaims(
            claim.sourceTokens,
            for: file,
            workspaceRoot: root,
            claimantID: "claimant-a"
        )
        XCTAssertEqual(try store.loadNewest(for: file, workspaceRoot: root)?.token, live)
        let records = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(records.count, 1)
    }

    func testRecoveryFenceRejectsLateWriteWithoutDependingOnCleanup() throws {
        let store = FilePreviewRecoveryStore(
            directoryURL: root.appendingPathComponent(".preview-recovery", isDirectory: true)
        )
        let file = root.appendingPathComponent("README.md")
        _ = try store.saveText(
            "accepted revision",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "window-a",
            revision: 1
        )

        let fenceToken = try store.fence(
            ownerID: "window-a",
            through: 2,
            for: file,
            workspaceRoot: root
        )
        XCTAssertEqual(fenceToken.revision, 3)
        XCTAssertThrowsError(try store.saveText(
            "cancelled revision that completed late",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "window-a",
            revision: 2
        )) { error in
            XCTAssertEqual(error as? FilePreviewRecoveryStore.RecoveryError, .staleRevision)
        }
        XCTAssertNil(try store.loadNewest(for: file, workspaceRoot: root))
    }

    func testRecoveryFenceDurablySuppressesClaimSourceBeforePhysicalDeletion() throws {
        let store = FilePreviewRecoveryStore(
            directoryURL: root.appendingPathComponent(".preview-recovery", isDirectory: true)
        )
        let file = root.appendingPathComponent("README.md")
        _ = try store.saveText(
            "orphaned draft",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "prior-process",
            revision: 1
        )
        let registry = FilePreviewRecoveryOwnerRegistry()
        registry.register("claimant")
        let claim = try XCTUnwrap(store.claimNewestOrphan(
            for: file,
            workspaceRoot: root,
            claimantID: "claimant",
            ownerRegistry: registry
        ))

        _ = try store.fence(
            ownerID: "claimant",
            through: claim.record.revision,
            for: file,
            workspaceRoot: root,
            resolving: claim.sourceTokens
        )
        // Simulate process death immediately after the fence: release only the
        // in-memory claim and deliberately leave the source JSON on disk.
        store.releaseClaims(
            claim.sourceTokens,
            for: file,
            workspaceRoot: root,
            claimantID: "claimant"
        )
        registry.unregister("claimant")
        XCTAssertNil(try store.claimNewestOrphan(
            for: file,
            workspaceRoot: root,
            claimantID: "next-process",
            ownerRegistry: FilePreviewRecoveryOwnerRegistry()
        ))
        XCTAssertNil(try store.loadNewest(for: file, workspaceRoot: root))
    }

    func testCompletedWritersRetireMoreThanEntryCapFencesWithoutEvictingLiveJournal() throws {
        let recoveryDirectory = root.appendingPathComponent(".preview-recovery", isDirectory: true)
        let store = FilePreviewRecoveryStore(directoryURL: recoveryDirectory)
        let liveFile = root.appendingPathComponent("live.md")
        let liveToken = try store.saveText(
            "live window draft",
            for: liveFile,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "live-window",
            revision: 1
        )

        var registrations: [FilePreviewRecoveryWriteRegistration] = []
        for index in 0...FilePreviewRecoveryStore.maxEntries {
            let file = root.appendingPathComponent("cleared-\(index).md")
            let owner = "cleared-window-\(index)"
            let source = try store.saveText(
                "claimed predecessor \(index)",
                for: file,
                workspaceRoot: root,
                expectedModificationDate: nil,
                ownerID: "source-window-\(index)",
                revision: 1
            )
            let registration = try store.beginInFlightWrite(
                ownerID: owner,
                revision: 2,
                for: file,
                workspaceRoot: root
            )
            let fence = try store.fence(
                ownerID: owner,
                through: 2,
                for: file,
                workspaceRoot: root,
                resolving: [source]
            )
            store.retireFenceWhenSafe(
                fence,
                through: 2,
                for: file,
                workspaceRoot: root
            )
            registrations.append(registration)
        }

        let firstClearedFile = root.appendingPathComponent("cleared-0.md")
        XCTAssertThrowsError(try store.saveText(
            "late pre-fence writer",
            for: firstClearedFile,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "cleared-window-0",
            revision: 2
        )) { error in
            XCTAssertEqual(error as? FilePreviewRecoveryStore.RecoveryError, .staleRevision)
        }
        let activeRecords = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertGreaterThan(activeRecords.count, FilePreviewRecoveryStore.maxEntries)

        // Trigger pruning while every fence is still actively protecting a
        // registered writer. Active fences do not consume journal capacity.
        _ = try store.saveText(
            "prune trigger",
            for: root.appendingPathComponent("trigger.md"),
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "trigger-window",
            revision: 1
        )
        XCTAssertEqual(try store.loadNewest(for: liveFile, workspaceRoot: root)?.token, liveToken)

        // Completion is the join point: each exact tombstone can now disappear
        // without allowing any pre-fence writer to arrive afterward.
        for registration in registrations {
            store.completeInFlightWrite(registration)
        }
        let records = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertLessThanOrEqual(records.count, FilePreviewRecoveryStore.maxEntries)
        XCTAssertEqual(try store.loadNewest(for: liveFile, workspaceRoot: root)?.token, liveToken)
        XCTAssertNil(try store.loadNewest(for: firstClearedFile, workspaceRoot: root))
    }

    func testDurableDescendantSuppressesSourceAfterItSupersedesPendingFence() throws {
        let recoveryDirectory = root.appendingPathComponent(".preview-recovery", isDirectory: true)
        let store = FilePreviewRecoveryStore(directoryURL: recoveryDirectory)
        let file = root.appendingPathComponent("README.md")
        let source = try store.saveText(
            "old orphan",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "prior-process",
            revision: 1
        )
        let registry = FilePreviewRecoveryOwnerRegistry()
        registry.register("claimant")
        let claim = try XCTUnwrap(store.claimNewestOrphan(
            for: file,
            workspaceRoot: root,
            claimantID: "claimant",
            ownerRegistry: registry
        ))
        XCTAssertEqual(claim.sourceTokens, [source])

        let oldWriter = try store.beginInFlightWrite(
            ownerID: "claimant",
            revision: 2,
            for: file,
            workspaceRoot: root
        )
        let fence = try store.fence(
            ownerID: "claimant",
            through: 2,
            for: file,
            workspaceRoot: root,
            resolving: claim.sourceTokens
        )
        store.retireFenceWhenSafe(
            fence,
            through: 2,
            for: file,
            workspaceRoot: root
        )

        let descendant = try store.saveText(
            "new descendant",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "claimant",
            revision: fence.revision + 1,
            sourceTokens: claim.sourceTokens
        )
        store.completeInFlightWrite(oldWriter)
        store.releaseClaims(
            claim.sourceTokens,
            for: file,
            workspaceRoot: root,
            claimantID: "claimant"
        )
        registry.unregister("claimant")

        XCTAssertEqual(try store.loadNewest(for: file, workspaceRoot: root)?.token, descendant)
        let nextClaim = try XCTUnwrap(store.claimNewestOrphan(
            for: file,
            workspaceRoot: root,
            claimantID: "next-process",
            ownerRegistry: FilePreviewRecoveryOwnerRegistry()
        ))
        XCTAssertEqual(nextClaim.record.text, "new descendant")
        XCTAssertEqual(nextClaim.sourceTokens.first, descendant)
        XCTAssertTrue(nextClaim.sourceTokens.contains(source))
    }

    func testByteCapPruningDurablyRetiresSourcesBeforeLineageDescendant() throws {
        let recoveryDirectory = root.appendingPathComponent(".preview-recovery", isDirectory: true)
        let file = root.appendingPathComponent("README.md")
        let probe = RecoveryDurabilityProbe()
        let store = FilePreviewRecoveryStore(
            directoryURL: recoveryDirectory,
            durabilityObserver: probe.record
        )
        let source = try store.saveText(
            "tiny orphan that must never resurface",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "source-window",
            revision: 1
        )
        let largePayload = Data(
            repeating: 0x61,
            count: FilePreviewContent.maxDocumentBytes
        )
        _ = try store.saveRichDocument(
            largePayload,
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "descendant-window",
            revision: 2,
            sourceTokens: [source]
        )

        // Eight newer maximum-sized records plus the descendant still fit
        // beneath 256 MiB. The ninth makes the older large descendant miss the
        // byte cap while its tiny source would fit in the remaining space.
        for index in 0..<8 {
            _ = try store.saveRichDocument(
                largePayload,
                for: root.appendingPathComponent("filler-\(index).docx"),
                workspaceRoot: root,
                expectedModificationDate: nil,
                ownerID: "filler-window-\(index)",
                revision: 1
            )
        }
        for url in try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "json" }) {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(FilePreviewRecoveryRecord.self, from: data)
            let modificationDate: Date?
            switch record.ownerID {
            case "source-window": modificationDate = Date(timeIntervalSince1970: 1)
            case "descendant-window": modificationDate = Date(timeIntervalSince1970: 2)
            default: modificationDate = nil
            }
            if let modificationDate {
                try FileManager.default.setAttributes(
                    [.modificationDate: modificationDate],
                    ofItemAtPath: url.path
                )
            }
        }

        _ = try store.saveRichDocument(
            largePayload,
            for: root.appendingPathComponent("filler-8.docx"),
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "filler-window-8",
            revision: 1
        )

        XCTAssertEqual(probe.events, [
            .removedSource,
            .synchronizedSourceDeletions,
            .removedLineageDescendant,
            .synchronizedLineageDescendantDeletion,
        ])
        XCTAssertNil(try store.loadNewest(for: file, workspaceRoot: root))
        let owners = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "json" }).map { url in
            try JSONDecoder().decode(
                FilePreviewRecoveryRecord.self,
                from: Data(contentsOf: url)
            ).ownerID
        }
        XCTAssertFalse(owners.contains("source-window"))
        XCTAssertFalse(owners.contains("descendant-window"))
    }

    func testTombstonePruningDurablyDeletesSourcesBeforeDeletingFence() throws {
        let recoveryDirectory = root.appendingPathComponent(".preview-recovery", isDirectory: true)
        let file = root.appendingPathComponent("README.md")
        let priorStore = FilePreviewRecoveryStore(
            directoryURL: recoveryDirectory,
            processID: "prior-process"
        )
        let source = try priorStore.saveText(
            "orphaned source",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "orphan-owner",
            revision: 1
        )
        _ = try priorStore.fence(
            ownerID: "claimant",
            through: 1,
            for: file,
            workspaceRoot: root,
            resolving: [source]
        )

        let probe = RecoveryDurabilityProbe()
        let currentStore = FilePreviewRecoveryStore(
            directoryURL: recoveryDirectory,
            processID: "current-process",
            durabilityObserver: probe.record
        )
        _ = try currentStore.saveText(
            "trigger pruning",
            for: root.appendingPathComponent("trigger.md"),
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "current-owner",
            revision: 1
        )

        XCTAssertEqual(probe.events, [
            .removedSource,
            .synchronizedSourceDeletions,
            .removedTombstone,
            .synchronizedTombstoneDeletion,
        ])
        XCTAssertNil(try currentStore.loadNewest(for: file, workspaceRoot: root))
    }

    func testClaimReadsOwnerLivenessAtSelectionTime() throws {
        let store = FilePreviewRecoveryStore(
            directoryURL: root.appendingPathComponent(".preview-recovery", isDirectory: true)
        )
        let file = root.appendingPathComponent("README.md")
        _ = try store.saveText(
            "journal becoming live",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "becoming-live",
            revision: 1
        )
        let registry = FilePreviewRecoveryOwnerRegistry()
        registry.register("claimant")
        defer {
            registry.unregister("claimant")
            registry.unregister("becoming-live")
        }

        let result = try store.claimNewestOrphan(
            for: file,
            workspaceRoot: root,
            claimantID: "claimant",
            ownerRegistry: registry,
            beforeSelection: { registry.register("becoming-live") }
        )
        XCTAssertNil(result)
        XCTAssertEqual(try store.loadNewest(for: file, workspaceRoot: root)?.ownerID, "becoming-live")
    }

    func testFilePreviewRecoveryStoreRejectsOutOfOrderSameOwnerRevision() throws {
        let store = FilePreviewRecoveryStore(
            directoryURL: root.appendingPathComponent(".preview-recovery", isDirectory: true)
        )
        let file = root.appendingPathComponent("README.md")
        let newest = try store.saveText(
            "revision two",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "one-window",
            revision: 2
        )

        XCTAssertThrowsError(try store.saveText(
            "late revision one",
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "one-window",
            revision: 1
        ))
        XCTAssertEqual(try store.loadNewest(for: file, workspaceRoot: root)?.token, newest)
        XCTAssertEqual(try store.loadNewest(for: file, workspaceRoot: root)?.text, "revision two")
    }

    func testFilePreviewRecoveryStoreCleansOrphanedAtomicTemporaryFiles() throws {
        let recoveryDirectory = root.appendingPathComponent(".preview-recovery", isDirectory: true)
        let store = FilePreviewRecoveryStore(directoryURL: recoveryDirectory)
        _ = try store.saveText(
            "draft",
            for: root.appendingPathComponent("README.md"),
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "window-a",
            revision: 1
        )
        let orphan = recoveryDirectory.appendingPathComponent(".orphan.json.dead.tmp")
        try Data("partial".utf8).write(to: orphan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        _ = try store.loadNewest(for: root.appendingPathComponent("README.md"), workspaceRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testFilePreviewDraftBoundsRejectOversizedUnicodeAndRichText() {
        XCTAssertTrue(FilePreviewDraftBounds.acceptsText(String(repeating: "a", count: 128)))
        XCTAssertFalse(FilePreviewDraftBounds.acceptsText(
            String(repeating: "é", count: (FilePreviewContent.maxTextBytes / 2) + 1)
        ))
        XCTAssertFalse(FilePreviewDraftBounds.acceptsRichText(NSAttributedString(
            string: String(repeating: "x", count: FilePreviewContent.maxTextBytes + 1)
        )))
    }

    func testRichDocumentBoundaryMeasuresSerializedAttachmentBytes() throws {
        let image = NSImage(size: NSSize(width: 96, height: 96))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 96, height: 96).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = NSTextAttachment(data: png, ofType: "public.png")
        let document = NSMutableAttributedString(string: "Image: ")
        document.append(NSAttributedString(attachment: attachment))

        XCTAssertTrue(FilePreviewDraftBounds.acceptsRichText(document))
        let serialized = try RichDocumentIO.data(document)
        XCTAssertGreaterThan(serialized.count, document.string.utf8.count)
        XCTAssertFalse(FilePreviewDraftBounds.acceptsSerializedRichDocumentData(
            serialized,
            maximumBytes: serialized.count - 1
        ))
    }

    func testFilePreviewRecoveryStoreRoundTripsRichDocumentData() throws {
        let store = FilePreviewRecoveryStore(
            directoryURL: root.appendingPathComponent(".preview-recovery", isDirectory: true)
        )
        let file = root.appendingPathComponent("notes.docx")
        let richText = NSAttributedString(string: "Recovered rich draft")
        let data = try RichDocumentIO.data(richText)

        _ = try store.saveRichDocument(
            data,
            for: file,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "editor-rich",
            revision: 1
        )

        let record = try XCTUnwrap(store.loadNewest(for: file, workspaceRoot: root))
        XCTAssertEqual(record.kind, .richDocument)
        XCTAssertNil(record.text)
        let restoredData = try XCTUnwrap(record.richDocumentData)
        let restored = try XCTUnwrap(RichDocumentIO.load(data: restoredData))
        XCTAssertEqual(
            restored.value.string.trimmingCharacters(in: .newlines),
            richText.string
        )
    }

    func testFilePreviewRecoveryStoreRejectsOutsideAndSymlinkEscapes() throws {
        let store = FilePreviewRecoveryStore(
            directoryURL: root.appendingPathComponent(".preview-recovery", isDirectory: true)
        )
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-recovery-outside-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("notes.md")
        try "outside".write(to: outsideFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.saveText(
            "draft",
            for: outsideFile,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "editor-a",
            revision: 1
        ))

        let linkedFile = root.appendingPathComponent("linked-notes.md")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: outsideFile)
        XCTAssertThrowsError(try store.saveText(
            "draft",
            for: linkedFile,
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "editor-a",
            revision: 1
        ))
        XCTAssertThrowsError(try store.loadNewest(for: linkedFile, workspaceRoot: root))
    }

    func testFilePreviewRecoveryStoreEnforcesPayloadAndGlobalEntryBounds() throws {
        let recoveryDirectory = root.appendingPathComponent(".preview-recovery", isDirectory: true)
        let store = FilePreviewRecoveryStore(directoryURL: recoveryDirectory)
        XCTAssertThrowsError(try store.saveText(
            String(repeating: "x", count: FilePreviewContent.maxTextBytes + 1),
            for: root.appendingPathComponent("oversized.md"),
            workspaceRoot: root,
            expectedModificationDate: nil,
            ownerID: "oversized",
            revision: 1
        ))

        for index in 0...FilePreviewRecoveryStore.maxEntries {
            _ = try store.saveText(
                "draft \(index)",
                for: root.appendingPathComponent("draft-\(index).md"),
                workspaceRoot: root,
                expectedModificationDate: nil,
                ownerID: "editor-\(index)",
                revision: 1
            )
        }
        let records = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertLessThanOrEqual(records.count, FilePreviewRecoveryStore.maxEntries)
    }

    func testOversizedFileReportsTooLarge() throws {
        let big = root.appendingPathComponent("big.txt")
        let bytes = FilePreviewContent.maxTextBytes + 1
        try Data(repeating: 0x61, count: bytes).write(to: big)
        XCTAssertEqual(FilePreviewContent.load(url: big), .tooLarge(bytes))

        let image = root.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: image.path, contents: nil))
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: UInt64(FilePreviewContent.maxImageBytes + 1))
        try handle.close()
        XCTAssertEqual(
            FilePreviewContent.load(url: image),
            .tooLarge(FilePreviewContent.maxImageBytes + 1)
        )

        let pdf = root.appendingPathComponent("oversized.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: pdf.path, contents: nil))
        let pdfHandle = try FileHandle(forWritingTo: pdf)
        try pdfHandle.truncate(atOffset: UInt64(FilePreviewContent.maxDocumentBytes + 1))
        try pdfHandle.close()
        XCTAssertEqual(
            FilePreviewContent.load(url: pdf),
            .tooLarge(FilePreviewContent.maxDocumentBytes + 1)
        )
    }

    func testPreviewDetectsAnExternalEditBeforeSaving() throws {
        let file = root.appendingPathComponent("external-edit.txt")
        try "first".write(to: file, atomically: true, encoding: .utf8)
        let openedAt = FilePreviewDiskState.modificationDate(of: file)
        XCTAssertFalse(FilePreviewDiskState.changed(onDisk: file, since: openedAt))

        try "agent edit".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: file.path
        )
        XCTAssertTrue(FilePreviewDiskState.changed(onDisk: file, since: openedAt))
    }

    func testMarkdownRenderFallsBackToPlainText() {
        // Even degenerate input must yield a string, never a blank preview.
        let rendered = FilePreviewView.renderMarkdown("plain **bold** text")
        XCTAssertFalse(String(rendered.characters).isEmpty)
    }

    func testMarkdownDocumentPreservesBlockStructure() {
        let document = MarkdownDocument.parse("""
        # Heading

        Paragraph with **bold** text.

        - first
        1. second

        > quoted

        ```swift
        let answer = 42
        ```

        | Name | Value |
        | --- | --- |
        | alpha | 1 |

        Setext heading
        --------------

        ![Architecture](docs/architecture.png)
        """)

        XCTAssertTrue(document.blocks.contains(.heading(
            level: 1,
            text: "Heading",
            alignment: nil
        )))
        XCTAssertTrue(document.blocks.contains(.listItem(indent: 0, marker: "•", text: "first")))
        XCTAssertTrue(document.blocks.contains(.listItem(indent: 0, marker: "1.", text: "second")))
        XCTAssertTrue(document.blocks.contains(.quote("quoted")))
        XCTAssertTrue(document.blocks.contains(.code(language: "swift", text: "let answer = 42")))
        XCTAssertTrue(document.blocks.contains(.table(
            headers: ["Name", "Value"],
            rows: [["alpha", "1"]],
            omittedRows: 0
        )))
        XCTAssertTrue(document.blocks.contains(.heading(
            level: 2,
            text: "Setext heading",
            alignment: nil
        )))
        XCTAssertTrue(document.blocks.contains(.image(
            source: "docs/architecture.png",
            alt: "Architecture",
            declaredWidth: nil,
            declaredHeight: nil,
            alignment: nil
        )))
    }

    func testMarkdownSourceBlocksPreserveExactRangesAndLineEndings() throws {
        let source = "# Héading\r\n\r\nParagraph **one**\r\ncontinues here\r\n\r\n```swift\r\nlet x = 1\r\n```\r\n\r\n<h2 align=\"center\">End</h2>\r\n"
        let blocks = MarkdownSourceDocument.blocks(in: source)

        XCTAssertEqual(blocks.count, 4)
        let nsSource = source as NSString
        for block in blocks {
            XCTAssertEqual(nsSource.substring(with: block.range), block.source)
        }
        for pair in zip(blocks, blocks.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(pair.0.range), pair.1.range.location)
        }
        XCTAssertEqual(blocks[0].block, .heading(level: 1, text: "Héading", alignment: nil))
        XCTAssertEqual(blocks[2].block, .code(language: "swift", text: "let x = 1"))
        XCTAssertEqual(blocks[3].block, .heading(level: 2, text: "End", alignment: .center))
    }

    func testMarkdownSourceBlockReplacementTouchesOnlyTheActiveBlock() throws {
        let source = "# Keep\n\nParagraph to edit.\n\n- Keep this too\n"
        let block = try XCTUnwrap(MarkdownSourceDocument.blocks(in: source).first {
            if case .paragraph = $0.block { return true }
            return false
        })
        let replaced = try XCTUnwrap(MarkdownSourceDocument.replacing(
            block.range,
            in: source,
            with: "Paragraph **edited**."
        ))

        XCTAssertEqual(replaced, "# Keep\n\nParagraph **edited**.\n\n- Keep this too\n")
        XCTAssertEqual(source, "# Keep\n\nParagraph to edit.\n\n- Keep this too\n")
    }

    func testMarkdownTableCellReplacementPreservesPaddingSeparatorCRLFAndNeighbors() throws {
        let source = "# Keep\r\n\r\n| Name  | Value |\r\n| :---- | ----: |\r\n| alpha | 1     |\r\n\r\nAfter\r\n"
        let block = try XCTUnwrap(MarkdownSourceDocument.blocks(in: source).first {
            if case .table = $0.block { return true }
            return false
        })
        let cells = MarkdownTableSource.cells(in: block)
        XCTAssertEqual(cells.map { "\($0.row):\($0.column)=\($0.text)" }, [
            "0:0=Name", "0:1=Value", "1:0=alpha", "1:1=1",
        ])

        let replaced = try XCTUnwrap(MarkdownTableSource.replacingCell(
            row: 1,
            column: 0,
            in: block,
            source: source,
            with: "beta"
        ))
        XCTAssertEqual(
            replaced,
            "# Keep\r\n\r\n| Name  | Value |\r\n| :---- | ----: |\r\n| beta | 1     |\r\n\r\nAfter\r\n"
        )
        XCTAssertTrue(replaced.contains("| :---- | ----: |\r\n"))
    }

    func testMarkdownTableCellsRoundTripLiteralPipesAndBackslashes() throws {
        let source = "| Name | Value |\n| --- | --- |\n| a\\|b | path\\\\leaf |\n"
        let block = try XCTUnwrap(MarkdownSourceDocument.blocks(in: source).first)
        XCTAssertEqual(
            MarkdownTableSource.cells(in: block).filter { $0.row == 1 }.map(\.text),
            ["a|b", "path\\leaf"]
        )
        let replaced = try XCTUnwrap(MarkdownTableSource.replacingCell(
            row: 1,
            column: 1,
            in: block,
            source: source,
            with: "left|right\\tail\nnext"
        ))
        XCTAssertEqual(
            replaced,
            "| Name | Value |\n| --- | --- |\n| a\\|b | left\\|right\\\\tail next |\n"
        )
        XCTAssertTrue(MarkdownDocument.parse(replaced).blocks.contains(
            .table(
                headers: ["Name", "Value"],
                rows: [["a|b", "left|right\\tail next"]],
                omittedRows: 0
            )
        ))
    }

    func testMarkdownTableTruncationReportsRowsThatAreNotRendered() throws {
        let rows = (1...102).map { "| row \($0) | value \($0) |" }
        let source = ([
            "| Name | Value |",
            "| --- | --- |",
        ] + rows).joined(separator: "\n")

        let document = MarkdownDocument.parse(source)
        guard case let .table(headers, visibleRows, omittedRows) = try XCTUnwrap(document.blocks.first) else {
            return XCTFail("Expected a Markdown table")
        }
        XCTAssertEqual(headers, ["Name", "Value"])
        XCTAssertEqual(visibleRows.count, 100)
        XCTAssertEqual(visibleRows.last, ["row 100", "value 100"])
        XCTAssertEqual(omittedRows, 2)
        XCTAssertEqual(
            MarkdownTableTruncation.message(omittedRows: omittedRows),
            "2 more rows not shown"
        )
        XCTAssertEqual(MarkdownTableTruncation.message(omittedRows: 1), "1 more row not shown")
    }

    func testWrappedListItemRendersAndEditsAsOneExactBlock() throws {
        let source = "- **Finish the editor.** The current\r\n  working tree keeps wrapped\r\n  continuation lines together.\r\n\r\n- Next item.\r\n"
        let document = MarkdownDocument.parse(source)
        XCTAssertEqual(document.blocks, [
            .listItem(
                indent: 0,
                marker: "•",
                text: "**Finish the editor.** The current working tree keeps wrapped continuation lines together."
            ),
            .listItem(indent: 0, marker: "•", text: "Next item."),
        ])

        let blocks = MarkdownSourceDocument.blocks(in: source)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(
            blocks[0].source,
            "- **Finish the editor.** The current\r\n  working tree keeps wrapped\r\n  continuation lines together."
        )
        XCTAssertEqual(
            (source as NSString).substring(with: blocks[0].range),
            blocks[0].source
        )
    }

    func testMarkdownSourceBlockCacheDoesNotReparseDuringLayoutOnlyUpdates() {
        let cache = MarkdownSourceBlockCache()
        let source = "# Heading\n\nParagraph\n"

        XCTAssertEqual(cache.blocks(for: source).count, 2)
        XCTAssertEqual(cache.blocks(for: source).count, 2)
        XCTAssertEqual(cache.parseCount, 1)
        XCTAssertEqual(cache.blocks(for: source + "\n- Item\n").count, 3)
        XCTAssertEqual(cache.parseCount, 2)
    }

    // MARK: - Read/edit scroll retention

    func testTextScrollMemoryRoundTripsTheViewportFraction() {
        let memory = FilePreviewTextScrollMemory()
        memory.record(0.42, for: "/tmp/a.swift")

        XCTAssertEqual(try XCTUnwrap(memory.fraction(for: "/tmp/a.swift")), 0.42, accuracy: 0.0001)
        // A document that was never scrolled must not fake a position, so the
        // reader and the editor both open at the natural top.
        XCTAssertNil(memory.fraction(for: "/tmp/b.swift"))
    }

    func testTextScrollMemoryClampsAndRejectsUnusablePositions() {
        let memory = FilePreviewTextScrollMemory()
        memory.record(4.5, for: "/tmp/a.swift")
        XCTAssertEqual(memory.fraction(for: "/tmp/a.swift"), 1)
        memory.record(-0.3, for: "/tmp/a.swift")
        XCTAssertEqual(memory.fraction(for: "/tmp/a.swift"), 0)

        // A view mid-teardown can report a degenerate geometry; that must not
        // overwrite a good position with a NaN one.
        memory.record(0.5, for: "/tmp/a.swift")
        memory.record(.nan, for: "/tmp/a.swift")
        XCTAssertEqual(memory.fraction(for: "/tmp/a.swift"), 0.5)
        memory.record(0.5, for: "")
        XCTAssertNil(memory.fraction(for: ""))
    }

    func testTextScrollMemoryForgetsAndStaysBounded() {
        let memory = FilePreviewTextScrollMemory()
        memory.record(0.1, for: "/tmp/a.swift")
        memory.forget("/tmp/a.swift")
        XCTAssertNil(memory.fraction(for: "/tmp/a.swift"))

        for index in 0..<(FilePreviewTextScrollMemory.capacity + 12) {
            memory.record(Double(index % 100) / 100, for: "/tmp/file\(index).swift")
        }
        XCTAssertEqual(memory.trackedDocumentCount, FilePreviewTextScrollMemory.capacity)
        // Oldest entries are evicted; the newest document survives.
        XCTAssertNil(memory.fraction(for: "/tmp/file0.swift"))
        let newest = FilePreviewTextScrollMemory.capacity + 11
        XCTAssertEqual(
            try XCTUnwrap(memory.fraction(for: "/tmp/file\(newest).swift")),
            Double(newest % 100) / 100,
            accuracy: 0.0001
        )
    }

    func testTextScrollMemoryRefreshesRecencyOnEveryRecord() {
        let memory = FilePreviewTextScrollMemory()
        for index in 0..<FilePreviewTextScrollMemory.capacity {
            memory.record(0.5, for: "/tmp/file\(index).swift")
        }
        // Re-recording the oldest document makes it the newest, so filling the
        // remaining slot evicts the *second* document instead of it.
        memory.record(0.99, for: "/tmp/file0.swift")
        memory.record(0.1, for: "/tmp/overflow.swift")

        XCTAssertEqual(try XCTUnwrap(memory.fraction(for: "/tmp/file0.swift")), 0.99, accuracy: 0.0001)
        XCTAssertNil(memory.fraction(for: "/tmp/file1.swift"))
    }

    // MARK: - Continuous Markdown editing

    /// The jump this surface exists to remove. Save, autosave, the recovery
    /// journal, and external reconciliation of identical bytes all re-run the
    /// SwiftUI body with the string the text view already holds; swapping the
    /// storage there collapses layout and throws the viewport to line 1.
    func testLiveMarkdownEditorNeverReplacesStorageForIdenticalText() {
        let source = "# Title\n\nA long document body.\n"

        XCTAssertEqual(
            MarkdownEditorTextSync.plan(
                current: source,
                incoming: source,
                selection: NSRange(location: 12, length: 4)
            ),
            .unchanged
        )
    }

    func testLiveMarkdownEditorClampsSelectionWhenExternalTextShrinks() {
        let plan = MarkdownEditorTextSync.plan(
            current: "# Title\n\nA long body that was truncated on disk.\n",
            incoming: "# Title\n",
            selection: NSRange(location: 40, length: 6)
        )

        XCTAssertEqual(plan, .replace(selection: NSRange(location: 8, length: 0)))
    }

    func testLiveMarkdownScrollRetentionKeepsPixelsWhenHeightBarelyMoves() {
        // Typing a character grows the document by a hair; the viewport must
        // not move at all.
        XCTAssertEqual(
            MarkdownEditorScrollRetention.restoredOrigin(
                previousOrigin: 4_200,
                previousContentHeight: 20_000,
                newContentHeight: 20_019,
                viewportHeight: 800
            ),
            4_200,
            accuracy: 0.0001
        )
    }

    func testLiveMarkdownScrollRetentionKeepsProportionAcrossRealReflows() {
        // An external reload or a zoom step changes the height materially, so
        // the old pixel offset no longer points at the same text.
        XCTAssertEqual(
            MarkdownEditorScrollRetention.restoredOrigin(
                previousOrigin: 9_600,
                previousContentHeight: 20_000,
                newContentHeight: 10_000,
                viewportHeight: 800
            ),
            4_600,
            accuracy: 0.5
        )
        XCTAssertEqual(
            MarkdownEditorScrollRetention.restoredOrigin(
                previousOrigin: 500,
                previousContentHeight: 20_000,
                newContentHeight: 400,
                viewportHeight: 800
            ),
            0,
            accuracy: 0.0001
        )
    }

    /// Inline images are drawn from these ranges, so a wrong range would paint
    /// a picture over live prose.
    func testLiveMarkdownFindsWholeLineImagesAndLeavesProseLinesAlone() throws {
        let source = """
        # Notes

        ![screenshot](assets/backlog/shot.png)

        See ![inline](a.png) in this sentence.

          <img src="assets/logo.png" width="120" height="40" alt="Logo">

        ![one](a.png) ![two](b.png)

        [not an image](page.md)
        """
        let nsSource = source as NSString
        let lines = MarkdownInlineImages.lines(in: source)

        XCTAssertEqual(lines.count, 3, "prose-with-image and plain links must not render")
        XCTAssertEqual(
            nsSource.substring(with: lines[0].references[0].range),
            "![screenshot](assets/backlog/shot.png)"
        )
        XCTAssertEqual(lines[0].references[0].source, "assets/backlog/shot.png")
        XCTAssertEqual(lines[0].references[0].alt, "screenshot")

        let html = lines[1].references[0]
        XCTAssertEqual(html.source, "assets/logo.png")
        XCTAssertEqual(html.declaredWidth, 120)
        XCTAssertEqual(html.declaredHeight, 40)
        XCTAssertEqual(html.alt, "Logo")

        XCTAssertEqual(lines[2].references.map(\.source), ["a.png", "b.png"])
        for line in lines {
            for reference in line.references {
                XCTAssertLessThanOrEqual(NSMaxRange(reference.range), nsSource.length)
            }
        }
    }

    /// Headings have to *look* like headings, or the continuous document reads
    /// as one undifferentiated wall of prose.
    func testLiveMarkdownHeadingsAreStyledLargerThanBody() throws {
        let source = "# Title\n\nBody prose.\n\n## Second\n\n### Third\n"
        let spans = MarkdownEditingStyle.spans(in: source)
        let nsSource = source as NSString

        let headings = spans.compactMap { span -> (Int, String)? in
            guard case let .heading(level) = span.role else { return nil }
            return (level, nsSource.substring(with: span.range))
        }
        XCTAssertEqual(headings.map(\.0), [1, 2, 3])
        XCTAssertEqual(headings.map(\.1), ["Title", "Second", "Third"])

        // The rendered size is what the reader actually perceives.
        let sizes = headings.map { level, _ -> CGFloat in
            let font = MarkdownEditingStyle.attributes(for: .heading(level))[.font] as? NSFont
            return font?.pointSize ?? 0
        }
        XCTAssertEqual(sizes, [28, 23, 20])
        XCTAssertTrue(sizes.allSatisfy { $0 > MarkdownEditingStyle.bodySize })

        // The `#` markers collapse, but the heading text itself never does.
        for span in spans where span.role == .syntax {
            XCTAssertFalse(
                nsSource.substring(with: span.range).contains("Title"),
                "heading text must not be hidden as syntax"
            )
        }
    }

    /// The regression that made block editing necessary in the first place: a
    /// styling pass must be able to restyle the whole document without altering
    /// a single character — relative image links most of all.
    func testLiveMarkdownStylingNeverAltersDocumentBytes() throws {
        let source = """
        # Release notes

        A paragraph with **bold**, *italic*, `code`, and a
        [relative link](docs/guide.md).

        ![screenshot](assets/backlog/shot.png)

        <img src="assets/logo.png" width="120">

        | Surface | State |
        | :------ | :---- |
        | Markdown | Editable |

        ```swift
        let untouched = "**not bold**"
        ```

        > A quote. Trailing spaces and CRLF must survive too.\r
        """
        let storage = NSTextStorage(string: source)
        let fullRange = NSRange(location: 0, length: storage.length)

        // Exactly what the editor's styling pass does.
        storage.beginEditing()
        storage.setAttributes(MarkdownEditingStyle.baseAttributes, range: fullRange)
        for span in MarkdownEditingStyle.spans(in: source)
        where NSMaxRange(span.range) <= fullRange.length {
            storage.addAttributes(MarkdownEditingStyle.attributes(for: span.role), range: span.range)
        }
        storage.endEditing()

        XCTAssertEqual(storage.string, source, "styling must not touch a single byte")
        XCTAssertEqual(storage.length, (source as NSString).length)
        XCTAssertTrue(storage.string.contains("![screenshot](assets/backlog/shot.png)"))
        XCTAssertTrue(storage.string.contains(#"<img src="assets/logo.png" width="120">"#))
        XCTAssertTrue(storage.string.contains("\r"))
        XCTAssertTrue(storage.string.contains(#"let untouched = "**not bold**""#))

        // And the styling really did happen.
        var headingFont: NSFont?
        headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertEqual(headingFont?.pointSize, 28)
    }

    /// A drawn image replaces its whole reference. Leaving the alt text visible
    /// prints a stray link caption underneath the picture it names.
    func testLiveMarkdownCollapsesWholeLineImageReferencesIncludingAltText() throws {
        let source = "# Title\n\n![Kaisola icon](assets/kaisola-icon.png)\n\nSee ![inline](a.png) here.\n"
        let nsSource = source as NSString
        let spans = MarkdownEditingStyle.spans(in: source)

        let reference = nsSource.range(of: "![Kaisola icon](assets/kaisola-icon.png)")
        XCTAssertTrue(
            spans.contains { $0.role == .syntax && $0.range == reference },
            "a whole-line image reference must collapse entirely"
        )

        // The last span wins, so the collapse has to outrank the link styling
        // the alt text also matched.
        let altRange = nsSource.range(of: "Kaisola icon")
        let altIndex = spans.lastIndex { NSIntersectionRange($0.range, altRange).length > 0 }
        XCTAssertEqual(spans[try XCTUnwrap(altIndex)].role, .syntax)

        // An image sharing a line with prose keeps its source visible, because
        // the picture is not drawn there.
        let inline = nsSource.range(of: "![inline](a.png)")
        XCTAssertFalse(spans.contains { $0.role == .syntax && $0.range == inline })
    }

    /// The styling pass runs 70 ms after the reader stops typing, so it has to
    /// finish well inside a frame budget even on the longest document the
    /// preview will open.
    func testLiveMarkdownStylingPassStaysWithinInteractionBudget() throws {
        let section = """
        ## Section heading

        A paragraph with **bold**, *italic*, `inline code`, and a
        [link](docs/guide.md) that wraps across more than one line of prose.

        - list item with **emphasis**
        - another item

        > a quoted line

        ```swift
        let value = 1
        ```

        """
        var source = ""
        while source.utf8.count < 100_000 { source += section }
        XCTAssertGreaterThan(source.utf8.count, 100_000)
        XCTAssertLessThan(source.utf8.count, FilePreviewContent.maxTextBytes)

        let spanStart = CFAbsoluteTimeGetCurrent()
        let spans = MarkdownEditingStyle.spans(in: source)
        let spanElapsed = CFAbsoluteTimeGetCurrent() - spanStart

        let storage = NSTextStorage(string: source)
        let fullRange = NSRange(location: 0, length: storage.length)
        let applyStart = CFAbsoluteTimeGetCurrent()
        storage.beginEditing()
        storage.setAttributes(MarkdownEditingStyle.baseAttributes, range: fullRange)
        for span in spans where NSMaxRange(span.range) <= fullRange.length {
            storage.addAttributes(MarkdownEditingStyle.attributes(for: span.role), range: span.range)
        }
        storage.endEditing()
        let applyElapsed = CFAbsoluteTimeGetCurrent() - applyStart

        XCTAssertEqual(storage.string, source)
        // Span computation runs off the main actor; only the apply blocks it.
        XCTAssertLessThan(spanElapsed, 0.35, "span scan took \(spanElapsed)s")
        XCTAssertLessThan(applyElapsed, 0.25, "main-actor styling took \(applyElapsed)s")
    }

    func testLiveMarkdownImageScanStaysWithinInteractionBudgetOnALongDocument() {
        let source = (0..<4_000).map { index in
            "## Section \(index)\n\nProse \(index) with no pictures at all.\n"
        }.joined()

        let startedAt = CFAbsoluteTimeGetCurrent()
        let lines = MarkdownInlineImages.lines(in: source)
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertTrue(lines.isEmpty)
        XCTAssertLessThan(elapsed, 0.5, "Image scan took \(elapsed)s")
    }

    func testLargeMarkdownStructuralProjectionStaysWithinInteractionBudget() {
        let sectionCount = 1_600
        let source = (0..<sectionCount).map { index in
            """
            # Section \(index)

            Paragraph \(index) keeps **rendered editing** responsive while the pane resizes.

            - Item \(index)

            | Key | Value |
            | --- | --- |
            | index | \(index) |
            """
        }.joined(separator: "\n\n")
        XCTAssertLessThan(source.utf8.count, FilePreviewContent.maxTextBytes)

        let startedAt = CFAbsoluteTimeGetCurrent()
        let blocks = MarkdownSourceDocument.blocks(in: source)
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertEqual(blocks.count, sectionCount * 4)
        XCTAssertLessThan(
            elapsed,
            3.5,
            "Structural projection took \(elapsed)s for \(blocks.count) blocks"
        )
    }

    func testMarkdownDocumentTranslatesCommonReadmeHTMLWithoutShowingTags() {
        let document = MarkdownDocument.parse("""
        <p align="center">
          <img src="icon.png" width="88" alt="Kaisola icon" />
        </p>

        <h1 align="center">Kaisola</h1>

        <p align="center">
          <strong>Your agents. One workspace.</strong><br />
          <a href="https://kaisola.com">Website</a> · Docs
        </p>
        """)

        XCTAssertEqual(document.blocks.first, .image(
            source: "icon.png",
            alt: "Kaisola icon",
            declaredWidth: 88,
            declaredHeight: nil,
            alignment: .center
        ))
        XCTAssertTrue(document.blocks.contains(.heading(
            level: 1,
            text: "Kaisola",
            alignment: .center
        )))
        XCTAssertTrue(document.blocks.contains(.paragraph(
            "**Your agents. One workspace.** [Website](https://kaisola.com) · Docs",
            alignment: .center
        )))
        XCTAssertFalse(document.blocks.contains { block in String(describing: block).contains("<") })
        XCTAssertTrue(MarkdownDocument.containsPresentationalHTML("<p align=\"center\">Hello</p>"))
        XCTAssertFalse(MarkdownDocument.containsPresentationalHTML("# Plain Markdown"))
    }

    func testMarkdownPreviewLayoutKeepsDocumentsReadableAcrossPaneWidths() {
        XCTAssertEqual(MarkdownPreviewLayout.contentWidth(viewportWidth: 320), 296)
        XCTAssertEqual(MarkdownPreviewLayout.contentWidth(viewportWidth: 480), 444)
        XCTAssertEqual(MarkdownPreviewLayout.contentWidth(viewportWidth: 1_200), 760)
    }

    func testMarkdownInlinePresentationKeepsSeparatorWithPreviousLink() {
        let source = "[Website](https://example.test) · [Docs](docs/README.md)"
        let rendered = MarkdownInlinePresentation.preventingOrphanedSeparators(source)

        XCTAssertEqual(
            rendered,
            "[Website](https://example.test)\u{00A0}· [Docs](docs/README.md)"
        )
        XCTAssertEqual(source, "[Website](https://example.test) · [Docs](docs/README.md)")
    }

    func testMarkdownLinkPolicyRoutesHTTPAndHTTPSPlusWorkspaceFiles() throws {
        let document = root.appendingPathComponent("docs/guide.md")
        try FileManager.default.createDirectory(
            at: document.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let expectedFile = root.appendingPathComponent("Sources/App.swift").standardizedFileURL

        XCTAssertEqual(
            WorkspacePreviewLinkPolicy.decision(
                for: try XCTUnwrap(URL(string: "https://example.test/docs")),
                documentURL: document,
                workspaceRoot: root
            ),
            .external(try XCTUnwrap(URL(string: "https://example.test/docs")))
        )
        XCTAssertEqual(
            WorkspacePreviewLinkPolicy.decision(
                for: try XCTUnwrap(URL(string: "http://localhost:8080/status")),
                documentURL: document,
                workspaceRoot: root
            ),
            .external(try XCTUnwrap(URL(string: "http://localhost:8080/status")))
        )
        XCTAssertEqual(
            WorkspacePreviewLinkPolicy.decision(
                for: try XCTUnwrap(URL(string: "../Sources/App.swift#L42")),
                documentURL: document,
                workspaceRoot: root
            ),
            .workspaceFile(expectedFile, line: 42)
        )
        XCTAssertEqual(
            WorkspacePreviewLinkPolicy.decision(
                for: expectedFile,
                documentURL: document,
                workspaceRoot: root
            ),
            .workspaceFile(expectedFile, line: nil)
        )
    }

    func testMarkdownLinkPolicyBlocksSchemesCredentialsAndWorkspaceEscapes() throws {
        let document = root.appendingPathComponent("docs/guide.md")
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.md")
        let blocked = [
            "mailto:agent@example.test",
            "kaisola-do-something://payload",
            "https://user:secret@example.test/private",
            "//example.test/scheme-relative",
            "#local-anchor",
            outside.absoluteString,
            "../../outside.md",
        ]

        for rawLink in blocked {
            XCTAssertEqual(
                WorkspacePreviewLinkPolicy.decision(
                    for: try XCTUnwrap(URL(string: rawLink)),
                    documentURL: document,
                    workspaceRoot: root
                ),
                .blocked,
                rawLink
            )
        }

        let outsideDirectory = root.deletingLastPathComponent()
            .appendingPathComponent("kaisola-link-outside-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let escape = root.appendingPathComponent("linked-outside", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outsideDirectory)
        XCTAssertFalse(WorkspacePreviewLinkPolicy.isContained(
            escape.appendingPathComponent("secret.md"),
            in: root
        ))
    }

    func testMarkdownPinchZoomScalesFromGestureStartAndStaysBounded() {
        XCTAssertEqual(MarkdownPreviewLayout.magnifiedZoom(start: 1, gestureScale: 1.25), 1.25)
        XCTAssertEqual(MarkdownPreviewLayout.magnifiedZoom(start: 1.5, gestureScale: 2), 2)
        XCTAssertEqual(MarkdownPreviewLayout.magnifiedZoom(start: 0.8, gestureScale: 0.5), 0.65)
    }

    func testMarkdownPreviewHonorsHTMLImageSizeAndScalesLargeImagesDown() {
        let icon = MarkdownPreviewLayout.imageSize(
            intrinsicSize: CGSize(width: 1_024, height: 1_024),
            declaredWidth: 88,
            declaredHeight: nil,
            availableWidth: 444,
            zoom: 1
        )
        XCTAssertEqual(icon.width, 88)
        XCTAssertEqual(icon.height, 88)

        let hero = MarkdownPreviewLayout.imageSize(
            intrinsicSize: CGSize(width: 1_600, height: 1_000),
            declaredWidth: 1_600,
            declaredHeight: 1_000,
            availableWidth: 444,
            zoom: 1
        )
        XCTAssertEqual(hero.width, 444)
        XCTAssertEqual(hero.height, 277.5, accuracy: 0.001)
    }

    func testMarkdownImageImportCreatesPortableAssetsWithoutOverwriting() throws {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let markdown = docs.appendingPathComponent("Design Notes.md")
        try "# Design".write(to: markdown, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("My Diagram.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        try bytes.write(to: source)

        let first = MarkdownAssetStore.importImages(
            [.file(source)],
            markdownURL: markdown,
            workspaceRoot: root
        )
        XCTAssertTrue(first.errors.isEmpty)
        XCTAssertEqual(first.insertions.map(\.markdown), [
            "![my-diagram](assets/design-notes/my-diagram.png)",
        ])
        XCTAssertEqual(try Data(contentsOf: first.insertions[0].fileURL), bytes)

        let second = MarkdownAssetStore.importImages(
            [.file(source)],
            markdownURL: markdown,
            workspaceRoot: root
        )
        XCTAssertTrue(second.errors.isEmpty)
        XCTAssertEqual(second.insertions.map(\.markdown), [
            "![my-diagram](assets/design-notes/my-diagram-2.png)",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.insertions[0].fileURL.path))
    }

    func testMarkdownImageImportRefusesDocumentsOutsideWorkspace() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-outside-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let markdown = outside.appendingPathComponent("notes.md")
        try "notes".write(to: markdown, atomically: true, encoding: .utf8)

        let batch = MarkdownAssetStore.importImages(
            [.data(Data([1, 2, 3]), suggestedName: "paste", fileExtension: "png")],
            markdownURL: markdown,
            workspaceRoot: root
        )

        XCTAssertTrue(batch.insertions.isEmpty)
        XCTAssertEqual(batch.errors.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("assets").path))
    }

    func testMarkdownImageImportDoesNotFollowAssetSymlinkOutsideWorkspace() throws {
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let markdown = docs.appendingPathComponent("notes.md")
        try "notes".write(to: markdown, atomically: true, encoding: .utf8)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-assets-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: docs.appendingPathComponent("assets", isDirectory: true),
            withDestinationURL: outside
        )

        let batch = MarkdownAssetStore.importImages(
            [.data(Data([1, 2, 3]), suggestedName: "paste", fileExtension: "png")],
            markdownURL: markdown,
            workspaceRoot: root
        )

        XCTAssertTrue(batch.insertions.isEmpty)
        XCTAssertEqual(batch.errors.count, 1)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    func testMarkdownImageInsertionSeparatesLinkFromAdjacentProse() {
        let source = "Before after"
        let range = NSRange(location: 7, length: 0)

        XCTAssertEqual(
            MarkdownImageInsertion.text(
                snippets: ["![diagram](assets/diagram.png)"],
                source: source,
                range: range
            ),
            "\n![diagram](assets/diagram.png)\n"
        )
    }

    func testMarkdownImageInsertionPreservesExistingLineBoundaries() {
        let source = "Before\n\nAfter"
        let range = NSRange(location: 7, length: 0)

        XCTAssertEqual(
            MarkdownImageInsertion.text(
                snippets: ["![one](assets/one.png)", "![two](assets/two.png)"],
                source: source,
                range: range
            ),
            "![one](assets/one.png)\n![two](assets/two.png)"
        )
    }

    func testMarkdownImageInsertionClampsStaleSelectionRange() {
        XCTAssertEqual(
            MarkdownImageInsertion.text(
                snippets: ["![late](assets/late.png)"],
                source: "Text",
                range: NSRange(location: 999, length: 99)
            ),
            "\n![late](assets/late.png)"
        )
    }

    func testMarkdownTableKeyboardNavigationHonorsRaggedRowsAndEdges() {
        let rows = [
            ["A", "B", "C"],
            ["1", "2"],
            ["x", "y", "z"],
        ]
        let center = MarkdownTableNavigation.Position(row: 1, column: 1)

        XCTAssertEqual(
            MarkdownTableNavigation.destination(from: center, direction: .left, rows: rows),
            .init(row: 1, column: 0)
        )
        XCTAssertEqual(
            MarkdownTableNavigation.destination(from: center, direction: .up, rows: rows),
            .init(row: 0, column: 1)
        )
        XCTAssertEqual(
            MarkdownTableNavigation.destination(from: center, direction: .down, rows: rows),
            .init(row: 2, column: 1)
        )
        XCTAssertNil(
            MarkdownTableNavigation.destination(
                from: .init(row: 1, column: 1),
                direction: .right,
                rows: rows
            )
        )
        XCTAssertNil(
            MarkdownTableNavigation.destination(
                from: .init(row: 0, column: 2),
                direction: .down,
                rows: rows
            )
        )
    }

    /// Replacing the string strips every attribute, so the height available at
    /// that instant is the *unstyled* height. Restoring a proportion of it
    /// threw a 90 KB document 15 000 points off its reading position when the
    /// file changed on disk. The character anchor is what has to survive.
    func testLiveMarkdownReplacementKeepsAnAnchorThatSurvivesTheIncomingText() {
        let text = "0123456789"
        XCTAssertTrue(
            MarkdownEditorScrollRetention.anchorSurvives(characterIndex: 9, in: text)
        )
        XCTAssertFalse(
            MarkdownEditorScrollRetention.anchorSurvives(characterIndex: 10, in: text)
        )
        XCTAssertFalse(
            MarkdownEditorScrollRetention.anchorSurvives(characterIndex: -1, in: text)
        )
        XCTAssertFalse(MarkdownEditorScrollRetention.anchorSurvives(characterIndex: 0, in: ""))
    }

    // MARK: - Tables rendered in place

    /// A table is only a table when GitHub says so. Re-aligning prose that
    /// merely contains a pipe, or a `---` that is really a Setext underline,
    /// would silently change what the document appears to say.
    func testMarkdownTableRegionsAcceptRealTablesAndRejectLookalikes() {
        let source = """
        | Surface | State |
        | :------ | ----: |
        | Markdown | Editable |
        | Terminal | Live |

        Prose with a | pipe in it, and a following line.
        --- not a delimiter

        ```
        | Fenced | Table |
        | ------ | ----- |
        ```

        | Ragged | Header | Row |
        | ------ | ------ |
        """
        let regions = MarkdownTableRegions.scan(source)

        XCTAssertEqual(regions.count, 1, "only the first block is a GitHub table")
        let table = try? XCTUnwrap(regions.first)
        XCTAssertEqual(table?.alignments, [.leading, .trailing])
        XCTAssertEqual(table?.rows.count, 4)
        XCTAssertEqual(table?.rows.map(\.kind), [.header, .delimiter, .body, .body])
        XCTAssertEqual(table?.rows.first?.cells.count, 2)
        XCTAssertTrue(table?.rows.allSatisfy { $0.hasLeadingPipe && $0.hasTrailingPipe } == true)

        let nsSource = source as NSString
        XCTAssertEqual(
            nsSource.substring(with: try! XCTUnwrap(table?.rows[2].cells[1])),
            "Editable"
        )
        XCTAssertEqual(
            MarkdownTableRegions.delimiterAlignments(in: "| :--- | :--: | ---: | --- |"),
            [.leading, .center, .trailing, .leading]
        )
        XCTAssertNil(MarkdownTableRegions.delimiterAlignments(in: "| a | b |"))
    }

    /// The heart of the grid: every row's pipes must land on the same x, and
    /// each column's text must start at the column origin. Proved by replaying
    /// the planner's own kern deltas across the row, character by character —
    /// the same advance arithmetic TextKit performs.
    func testMarkdownTableGeometryLandsEveryRowOnTheSameColumns() throws {
        let source = """
        | a | bb |
        | - | -- |
        | ccc | d |
        |x|yy|
        """
        let region = try XCTUnwrap(MarkdownTableRegions.scan(source).first)
        let characterWidth: CGFloat = 7
        let plan = MarkdownTableGeometry.plan(
            rows: measuredRows(in: region, characterWidth: characterWidth),
            alignments: region.alignments,
            pipeWidth: characterWidth,
            padding: 10
        )

        // 1 pipe + 10 pad + max("ccc") 21 + 10 pad + 1 pipe + 10 pad ...
        XCTAssertEqual(plan.columnWidths, [21, 14])
        XCTAssertEqual(plan.columnOrigins, [17, 65])
        XCTAssertEqual(plan.totalWidth, 96)

        var separatorsPerRow: [[CGFloat]] = []
        for (index, row) in region.rows.enumerated() where row.kind != .delimiter {
            let replay = replayTableRow(
                row,
                plan: plan.rows[index],
                characterWidth: characterWidth
            )
            XCTAssertEqual(
                replay.contentStarts,
                plan.columnOrigins,
                "row \(index) text must begin at the column origin"
            )
            XCTAssertEqual(
                replay.separators,
                plan.rows[index].separatorPositions,
                "row \(index) replay must match the planned separators"
            )
            separatorsPerRow.append(replay.separators)
        }
        XCTAssertEqual(separatorsPerRow.count, 3)
        XCTAssertEqual(separatorsPerRow[0], [0, 48, 89])
        for separators in separatorsPerRow {
            XCTAssertEqual(separators, separatorsPerRow[0], "every row draws the same grid")
        }
    }

    func testMarkdownTableGeometryPlacesSlackAheadOfRightAndCentreColumns() throws {
        let source = """
        | left | right | mid |
        | :--- | ----: | :-: |
        | a | b | c |
        """
        let region = try XCTUnwrap(MarkdownTableRegions.scan(source).first)
        XCTAssertEqual(region.alignments, [.leading, .trailing, .center])
        let characterWidth: CGFloat = 7
        let plan = MarkdownTableGeometry.plan(
            rows: measuredRows(in: region, characterWidth: characterWidth),
            alignments: region.alignments,
            pipeWidth: characterWidth,
            padding: 10
        )
        XCTAssertEqual(plan.columnWidths, [28, 35, 21])

        let body = region.rows[2]
        let replay = replayTableRow(body, plan: plan.rows[2], characterWidth: characterWidth)
        // "a" is left aligned, "b" is pushed to the right edge of a 35 pt
        // column, "c" is centred in a 21 pt one.
        XCTAssertEqual(replay.contentStarts[0], plan.columnOrigins[0])
        XCTAssertEqual(replay.contentStarts[1], plan.columnOrigins[1] + 28)
        XCTAssertEqual(replay.contentStarts[2], plan.columnOrigins[2] + 7)
        XCTAssertEqual(replay.separators, plan.rows[0].separatorPositions)
    }

    /// The whole reason this is styling rather than a widget: the grid must be
    /// producible without moving a single byte, including the delimiter row
    /// that is drawn as a rule.
    func testMarkdownTableStylingRendersAGridWithoutAlteringDocumentBytes() throws {
        let source = """
        # Notes

        | Surface | **State** |
        | :------ | --------: |
        | Markdown | Editable |

        ---

        ![shot](assets/backlog/shot.png)

        Trailing CRLF line.\r
        """
        let storage = NSTextStorage(string: source)
        let decorations = styleMarkdown(storage, source: source, availableWidth: 900)

        XCTAssertEqual(storage.string, source, "rendering a table must not touch a byte")
        XCTAssertTrue(storage.string.contains("| :------ | --------: |"))
        XCTAssertTrue(storage.string.contains("\r"))
        XCTAssertTrue(storage.string.contains("![shot](assets/backlog/shot.png)"))

        let nsSource = source as NSString
        // The pipes stay in the text and become the vertical rules.
        let pipe = nsSource.range(of: "| Markdown").location
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: pipe, effectiveRange: nil) as? NSColor,
            MarkdownTableStyle.pipeColor
        )
        // Columns were actually aligned: padding carries a kern correction.
        var kerned = false
        storage.enumerateAttribute(
            .kern,
            in: nsSource.range(of: "| Markdown | Editable |")
        ) { value, _, _ in
            if let value = value as? CGFloat, value != 0 { kerned = true }
        }
        XCTAssertTrue(kerned, "column alignment is applied as kern on the padding")

        // The delimiter row collapses to a blank strip with a hairline behind
        // it — but its dashes are still in the document.
        let delimiter = nsSource.range(of: "| :------ | --------: |").location
        let delimiterFont = storage.attribute(.font, at: delimiter, effectiveRange: nil) as? NSFont
        XCTAssertEqual(delimiterFont?.pointSize, MarkdownTableStyle.rulePointSize)
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: delimiter, effectiveRange: nil) as? NSColor,
            NSColor.clear
        )
        XCTAssertTrue(
            decorations.contains { $0.kind == .rule && $0.characterIndex == delimiter }
        )
        XCTAssertTrue(
            decorations.contains {
                $0.kind == .fill && $0.characterIndex == nsSource.range(of: "| Surface").location
            }
        )
        // ...and so does the thematic break.
        let rule = nsSource.range(of: "\n---\n").location + 1
        XCTAssertTrue(decorations.contains { $0.kind == .rule && $0.characterIndex == rule })
        XCTAssertTrue(storage.string.contains("\n---\n"))
    }

    /// A header cell carrying its own emphasis still lands on the column,
    /// because the grid is measured after the inline pass rather than from the
    /// raw characters.
    func testMarkdownTableStylingMeasuresCellsAfterInlineMarkupCollapses() throws {
        let source = """
        | Plain | **Bold** |
        | ----- | -------- |
        | a | b |
        """
        let storage = NSTextStorage(string: source)
        _ = styleMarkdown(storage, source: source, availableWidth: 900)
        let nsSource = source as NSString

        // The delimiters really are collapsed inside the cell...
        let asterisks = nsSource.range(of: "**Bold").location
        let collapsed = storage.attribute(.font, at: asterisks, effectiveRange: nil) as? NSFont
        XCTAssertEqual(collapsed?.pointSize, 0.1)
        // ...and the visible word is still semibold-ish rather than reset.
        let word = nsSource.range(of: "Bold**").location
        let bold = storage.attribute(.font, at: word, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(try XCTUnwrap(bold?.pointSize), 1)
        XCTAssertEqual(storage.string, source)
    }

    /// A table wider than the pane is left as plain source rather than clipped
    /// into unreachable columns. It still must not rewrite anything.
    func testMarkdownTableWiderThanThePaneFallsBackWithoutClippingOrRewriting() throws {
        let wide = String(repeating: "x", count: 400)
        let source = """
        | One | Two |
        | --- | --- |
        | \(wide) | \(wide) |
        """
        let storage = NSTextStorage(string: source)
        _ = styleMarkdown(storage, source: source, availableWidth: 320)

        XCTAssertEqual(storage.string, source)
        var kerned = false
        storage.enumerateAttribute(
            .kern,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let value = value as? CGFloat, value != 0 { kerned = true }
        }
        XCTAssertFalse(kerned, "an unfittable table is not forced onto a grid")
    }

    func testMarkdownThematicBreaksSkipSetextUnderlinesAndFrontMatter() {
        let source = """
        ---
        title: Front matter
        ---

        Heading underlined by dashes
        ---

        ***

        Real break below.

        ---
        """
        let nsSource = source as NSString
        let breaks = MarkdownThematicBreaks.scan(source)

        XCTAssertEqual(breaks.count, 2, "front matter and a Setext underline are not rules")
        XCTAssertEqual(nsSource.substring(with: breaks[0]), "***")
        XCTAssertEqual(breaks[1].location, nsSource.range(of: "---", options: .backwards).location)
    }

    /// Table scanning joins the same 70 ms debounce as everything else, so it
    /// has to stay far inside the budget on a table-heavy document.
    func testMarkdownTableScanAndStylingStayWithinInteractionBudget() throws {
        let block = """
        ## Section

        | Mechanism | Location | Notes |
        | :-------- | -------: | :---: |
        | One | file.swift:12 | kept |
        | Two | other.swift:44 | replaced |

        """
        var source = ""
        while source.utf8.count < 60_000 { source += block }

        let scanStart = CFAbsoluteTimeGetCurrent()
        let regions = MarkdownTableRegions.scan(source)
        let breaks = MarkdownThematicBreaks.scan(source)
        let scanElapsed = CFAbsoluteTimeGetCurrent() - scanStart
        XCTAssertGreaterThan(regions.count, 20)

        let storage = NSTextStorage(string: source)
        let applyStart = CFAbsoluteTimeGetCurrent()
        storage.beginEditing()
        storage.setAttributes(
            MarkdownEditingStyle.baseAttributes,
            range: NSRange(location: 0, length: storage.length)
        )
        MarkdownTableStyler.applyTypography(
            regions: regions,
            thematicBreaks: breaks,
            to: storage
        )
        _ = MarkdownTableStyler.applyGeometry(
            regions: regions,
            thematicBreaks: breaks,
            to: storage,
            availableWidth: 900
        )
        storage.endEditing()
        let applyElapsed = CFAbsoluteTimeGetCurrent() - applyStart

        XCTAssertEqual(storage.string, source)
        XCTAssertLessThan(scanElapsed, 0.35, "table scan took \(scanElapsed)s")
        XCTAssertLessThan(applyElapsed, 0.30, "table styling took \(applyElapsed)s")
    }

    // MARK: Table rendering helpers

    /// The production styling pass, minus the text view.
    private func styleMarkdown(
        _ storage: NSTextStorage,
        source: String,
        availableWidth: CGFloat
    ) -> [MarkdownInlineImageLayoutManager.Decoration] {
        let scan = MarkdownLiveStyleScan(source: source)
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(MarkdownEditingStyle.baseAttributes, range: fullRange)
        MarkdownTableStyler.applyTypography(
            regions: scan.tables,
            thematicBreaks: scan.thematicBreaks,
            to: storage
        )
        for span in scan.spans where NSMaxRange(span.range) <= fullRange.length {
            storage.addAttributes(MarkdownEditingStyle.attributes(for: span.role), range: span.range)
        }
        let decorations = MarkdownTableStyler.applyGeometry(
            regions: scan.tables,
            thematicBreaks: scan.thematicBreaks,
            to: storage,
            availableWidth: availableWidth
        )
        storage.endEditing()
        return decorations
    }

    /// Measured rows built from a synthetic monospaced metric, so the geometry
    /// can be asserted arithmetically instead of against a rendered font.
    private func measuredRows(
        in region: MarkdownTableRegion,
        characterWidth: CGFloat
    ) -> [MarkdownTableGeometry.MeasuredRow] {
        region.rows.map { row in
            guard row.kind != .delimiter else {
                return MarkdownTableGeometry.MeasuredRow(
                    isDelimiter: true,
                    hasLeadingPipe: row.hasLeadingPipe,
                    cells: [],
                    trailingPipe: nil
                )
            }
            let cells = row.cells.enumerated().map { index, content -> MarkdownTableGeometry.MeasuredCell in
                let preceding = row.precedingPipe(ofCell: index)
                let gapStart = preceding.map { $0 + 1 } ?? row.lineRange.location
                let leadingGap = NSRange(
                    location: gapStart,
                    length: max(0, content.location - gapStart)
                )
                let gapEnd = row.followingPipe(ofCell: index) ?? NSMaxRange(row.lineRange)
                let trailingGap = NSRange(
                    location: NSMaxRange(content),
                    length: max(0, gapEnd - NSMaxRange(content))
                )
                return MarkdownTableGeometry.MeasuredCell(
                    content: content,
                    contentWidth: CGFloat(content.length) * characterWidth,
                    leadingGap: leadingGap,
                    leadingGapWidth: CGFloat(leadingGap.length) * characterWidth,
                    trailingGap: trailingGap,
                    trailingGapWidth: CGFloat(trailingGap.length) * characterWidth,
                    precedingPipe: preceding
                )
            }
            return MarkdownTableGeometry.MeasuredRow(
                isDelimiter: false,
                hasLeadingPipe: row.hasLeadingPipe,
                cells: cells,
                trailingPipe: row.trailingPipe
            )
        }
    }

    /// Walk the row exactly as TextKit does — natural advance plus this
    /// character's kern — and report where the pipes and the cell text land.
    private func replayTableRow(
        _ row: MarkdownTableRow,
        plan: MarkdownTableGeometry.RowPlan,
        characterWidth: CGFloat
    ) -> (separators: [CGFloat], contentStarts: [CGFloat]) {
        var kern: [Int: CGFloat] = [:]
        for adjustment in plan.adjustments {
            for index in adjustment.range.location..<NSMaxRange(adjustment.range) {
                kern[index, default: 0] += adjustment.kern
            }
        }
        var starts: [Int: Int] = [:]
        for (column, cell) in row.cells.enumerated() where starts[cell.location] == nil {
            starts[cell.location] = column
        }
        let pipes = Set(row.pipes)

        var x = plan.headIndent
        var separators: [CGFloat] = []
        var contentStarts: [CGFloat] = []
        for index in row.lineRange.location..<NSMaxRange(row.lineRange) {
            if pipes.contains(index) { separators.append(x) }
            if starts[index] != nil { contentStarts.append(x) }
            x += characterWidth + (kern[index] ?? 0)
        }
        return (separators, contentStarts)
    }

    func testMarkdownEditingStyleFindsDocumentSemanticsWithoutRewritingSource() {
        let source = """
        # Heading

        **bold** and *italic* with `code` and [link](https://example.com).

        - first item

        > quoted

        ```swift
        let answer = 42
        ```
        """
        let spans = MarkdownEditingStyle.spans(in: source)

        XCTAssertTrue(spans.contains { $0.role == .heading(1) })
        XCTAssertTrue(spans.contains { $0.role == .bold })
        XCTAssertTrue(spans.contains { $0.role == .italic })
        XCTAssertTrue(spans.contains { $0.role == .inlineCode })
        XCTAssertTrue(spans.contains { $0.role == .link })
        XCTAssertTrue(spans.contains { $0.role == .listMarker })
        XCTAssertTrue(spans.contains { $0.role == .quote })
        XCTAssertTrue(spans.contains { $0.role == .codeBlock })
        XCTAssertEqual(source, """
        # Heading

        **bold** and *italic* with `code` and [link](https://example.com).

        - first item

        > quoted

        ```swift
        let answer = 42
        ```
        """)
    }

    func testMarkdownEditingStyleCollapsesReadmeHTMLButStylesItsText() {
        let source = #"<h1 align="center">Kaisola</h1> <strong>One workspace.</strong> <a href="https://kaisola.com">Website</a>"#
        let spans = MarkdownEditingStyle.spans(in: source)

        XCTAssertTrue(spans.contains { $0.role == .heading(1) })
        XCTAssertTrue(spans.contains { $0.role == .bold })
        XCTAssertTrue(spans.contains { $0.role == .link })
        XCTAssertTrue(spans.contains { $0.role == .centered })
        XCTAssertGreaterThanOrEqual(spans.filter { $0.role == .syntax }.count, 6)
        XCTAssertEqual(source, #"<h1 align="center">Kaisola</h1> <strong>One workspace.</strong> <a href="https://kaisola.com">Website</a>"#)
    }

    func testMarkdownEditingStyleDoesNotHideOrdinaryLessThanProseAcrossLines() {
        let source = "a < b and\nc > d"
        let spans = MarkdownEditingStyle.spans(in: source)
        XCTAssertFalse(spans.contains { $0.role == .syntax })

        let html = "before <em>visible</em> after"
        XCTAssertEqual(
            MarkdownEditingStyle.spans(in: html).filter { $0.role == .syntax }.count,
            2
        )
    }

    @MainActor
    func testMarkdownEditorReflowsSeedWidthToNarrowViewportAndZoom() {
        let scrollView = MarkdownMagnifyingScrollView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 480)
        )
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.65
        scrollView.maxMagnification = 2

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 18, height: 20)
        textView.string = String(
            repeating: "A long Markdown sentence must wrap inside the visible pane. ",
            count: 8
        )
        scrollView.documentView = textView

        // Recreate the stale seed width seen when SwiftUI installs the native
        // representable before the split pane has completed its first layout.
        textView.frame.size.width = 640
        textView.textContainer?.containerSize.width = 640
        scrollView.reflowDocumentWidth()

        XCTAssertEqual(textView.frame.width, scrollView.contentView.bounds.width, accuracy: 0.5)
        assertMarkdownGlyphsFit(textView, viewportWidth: scrollView.contentView.bounds.width)

        scrollView.frame.size.width = 240
        scrollView.tile()
        XCTAssertEqual(textView.frame.width, scrollView.contentView.bounds.width, accuracy: 0.5)
        assertMarkdownGlyphsFit(textView, viewportWidth: scrollView.contentView.bounds.width)

        scrollView.setMagnification(1.5, centeredAt: .zero)
        scrollView.reflowDocumentWidth()
        XCTAssertEqual(scrollView.magnification, 1.5, accuracy: 0.001)
        XCTAssertEqual(textView.frame.width, scrollView.contentView.bounds.width, accuracy: 0.5)
        assertMarkdownGlyphsFit(textView, viewportWidth: scrollView.contentView.bounds.width)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
    }

    @MainActor
    private func assertMarkdownGlyphsFit(_ textView: NSTextView, viewportWidth: CGFloat) {
        guard let container = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return XCTFail("Expected the Markdown text system")
        }
        let expectedContainerWidth = max(
            1,
            viewportWidth - (textView.textContainerInset.width * 2)
        )
        XCTAssertEqual(container.containerSize.width, expectedContainerWidth, accuracy: 0.5)

        layoutManager.ensureLayout(for: container)
        let glyphRange = layoutManager.glyphRange(for: container)
        var rightmostGlyph = CGFloat.zero
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            _, usedRect, _, _, _ in
            rightmostGlyph = max(
                rightmostGlyph,
                textView.textContainerInset.width + usedRect.maxX
            )
        }
        XCTAssertLessThanOrEqual(rightmostGlyph, viewportWidth + 0.5)
    }

    @MainActor
    func testEditedPreviewTabPromotesAndMarksOnlyTheLoadedDocument() {
        let previewURL = root.appendingPathComponent("README.md")
        let keptURL = root.appendingPathComponent("src/main.swift")
        let tabs = [
            AppModel.FileWorkbenchTab(url: keptURL, isPinned: true, line: nil),
            AppModel.FileWorkbenchTab(url: previewURL, isPinned: false, line: nil),
        ]

        XCTAssertFalse(FilePreviewTabPolicy.shouldPromoteEditedPreview(
            loadedURL: previewURL,
            isDirty: false,
            tabs: tabs
        ))
        XCTAssertTrue(FilePreviewTabPolicy.shouldPromoteEditedPreview(
            loadedURL: previewURL,
            isDirty: true,
            tabs: tabs
        ))
        XCTAssertFalse(FilePreviewTabPolicy.shouldPromoteEditedPreview(
            loadedURL: keptURL,
            isDirty: true,
            tabs: tabs
        ))
        XCTAssertTrue(FilePreviewTabPolicy.isModified(
            tabs[1],
            loadedURL: previewURL,
            isDirty: true
        ))
        XCTAssertFalse(FilePreviewTabPolicy.isModified(
            tabs[0],
            loadedURL: previewURL,
            isDirty: true
        ))

        let rootReadme = AppModel.FileWorkbenchTab(
            url: root.appendingPathComponent("README.md"),
            isPinned: true,
            line: nil
        )
        let docsReadme = AppModel.FileWorkbenchTab(
            url: root.appendingPathComponent("docs/README.md"),
            isPinned: true,
            line: nil
        )
        let sourceReadme = AppModel.FileWorkbenchTab(
            url: root.appendingPathComponent("Sources/App/README.md"),
            isPinned: true,
            line: nil
        )
        let duplicateTabs = [rootReadme, docsReadme, sourceReadme, tabs[0]]
        XCTAssertEqual(
            FilePreviewTabPolicy.displayTitle(
                for: rootReadme,
                among: duplicateTabs,
                workspaceRoot: root
            ),
            "README.md — \(root.lastPathComponent)"
        )
        XCTAssertEqual(
            FilePreviewTabPolicy.displayTitle(
                for: docsReadme,
                among: duplicateTabs,
                workspaceRoot: root
            ),
            "README.md — docs"
        )
        XCTAssertEqual(
            FilePreviewTabPolicy.displayTitle(
                for: sourceReadme,
                among: duplicateTabs,
                workspaceRoot: root
            ),
            "README.md — Sources/App"
        )
        XCTAssertEqual(
            FilePreviewTabPolicy.displayTitle(
                for: tabs[0],
                among: duplicateTabs,
                workspaceRoot: root
            ),
            "main.swift"
        )
    }

    func testHTMLPreviewPromptsForScriptOnlyAppShells() {
        XCTAssertTrue(HTMLPreviewReadiness.requiresJavaScriptPrompt("""
        <!doctype html><html><body><div id="root"></div><script src="app.js"></script></body></html>
        """))
        XCTAssertFalse(HTMLPreviewReadiness.requiresJavaScriptPrompt("""
        <!doctype html><html><body><h1>Static report</h1><script src="enhance.js"></script></body></html>
        """))
        XCTAssertFalse(HTMLPreviewReadiness.requiresJavaScriptPrompt("""
        <!doctype html><html><body><img src="chart.png"><script src="enhance.js"></script></body></html>
        """))
    }

    func testDirectorySymlinkIsNotRecursivelyIndexed() throws {
        let loop = root.appendingPathComponent("loop", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: root)
        XCTAssertFalse(ProjectFiles.children(of: root).contains { $0.name == "loop" })
        XCTAssertEqual(Set(ProjectFiles.enumerate(root: root)), ["README.md", "src/main.swift"])
    }

    func testSyntaxHighlighterAppKitPathClampsOutOfRangeSpanInsteadOfThrowing() {
        // `spans(in:language:)` can never itself produce a range past the text
        // it scanned, but the AppKit adapter must still defend against one —
        // matching the clamp the AttributedString path already applies —
        // since an unclamped `NSMutableAttributedString.addAttribute` would
        // trap with an out-of-range `NSRangeException` instead of degrading.
        let storage = NSMutableAttributedString(string: "let x = 1")
        let color = SyntaxHighlighter.nsColor(for: .keyword, dark: true)

        // Entirely past the end: a silent no-op, not a crash.
        SyntaxHighlighter.applyAppKitSpan(
            SyntaxHighlighter.Span(range: NSRange(location: 20, length: 5), role: .keyword),
            color: color,
            to: storage
        )
        var effective = NSRange(location: 0, length: 0)
        XCTAssertNil(storage.attribute(.foregroundColor, at: 0, effectiveRange: &effective))

        // Starts in range but overruns the end: colors only what exists.
        SyntaxHighlighter.applyAppKitSpan(
            SyntaxHighlighter.Span(range: NSRange(location: 4, length: 50), role: .keyword),
            color: color,
            to: storage
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: 4, effectiveRange: &effective) as? NSColor,
            color
        )
        XCTAssertEqual(effective, NSRange(location: 4, length: storage.length - 4))
    }
}

private final class ProjectFileIndexProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWalks = 0
    private var maximumActiveWalks = 0
    private var starts = 0

    var startedCount: Int {
        lock.withLock { starts }
    }

    var maximumConcurrentWalks: Int {
        lock.withLock { maximumActiveWalks }
    }

    /// Holds the first walk open until the test releases it.
    ///
    /// Without this the first walk simply slept 80 ms and every test racing it
    /// had to join inside that window. On a loaded CI runner the walk finished
    /// first, so a waiter got the cached result, `invalidate()` found nothing
    /// in flight, and no replacement walk ever ran — the test then read
    /// `["walk-1"]` and a start count of 1. A gate removes the deadline
    /// entirely rather than widening it and hoping.
    private let gate = DispatchSemaphore(value: 0)
    private var gated = false

    /// Make the first walk block until `releaseFirstWalk()` is called.
    func holdFirstWalk() {
        lock.withLock { gated = true }
    }

    func releaseFirstWalk() {
        gate.signal()
    }

    func enumerate(_ root: URL) -> [String] {
        let (sequence, isGated) = lock.withLock { () -> (Int, Bool) in
            starts += 1
            activeWalks += 1
            maximumActiveWalks = max(maximumActiveWalks, activeWalks)
            return (starts, gated)
        }
        // Deliberately ignore task cancellation long enough to expose an
        // overlapping replacement if ProjectFileIndex starts one eagerly.
        if sequence == 1 {
            if isGated {
                gate.wait()
            } else {
                Thread.sleep(forTimeInterval: 0.08)
            }
        }
        lock.withLock {
            activeWalks -= 1
        }
        return ["walk-\(sequence)"]
    }
}

private final class ProjectFileIndexStaticProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let files: [String]
    private var starts = 0

    init(files: [String]) {
        self.files = files
    }

    var startedCount: Int {
        lock.withLock { starts }
    }

    func enumerate(_ root: URL) -> [String] {
        lock.withLock { starts += 1 }
        return files
    }
}

private final class RecoveryDurabilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [FilePreviewRecoveryStore.DurabilityEvent] = []

    var events: [FilePreviewRecoveryStore.DurabilityEvent] {
        lock.withLock { recordedEvents }
    }

    func record(_ event: FilePreviewRecoveryStore.DurabilityEvent) {
        lock.withLock { recordedEvents.append(event) }
    }
}
