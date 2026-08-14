import AppKit
import Foundation
import XCTest
@testable import Kaisola

/// The ghost row's recent-folders menu: only real directories, never a
/// project that is already open, no duplicates, capped.
final class AddableRecentFoldersTests: XCTestCase {
    func testFiltersOpenProjectsMissingDirectoriesAndDuplicates() {
        let recent = [
            "/tmp/alpha",
            "/tmp/already-open",
            "/tmp/deleted",
            "/tmp/alpha/",
            "/tmp/beta",
        ]
        let result = AddableRecentFolders.compute(
            recent: recent,
            openProjectPaths: ["/tmp/already-open"],
            isDirectory: { $0.path != "/tmp/deleted" }
        )
        XCTAssertEqual(result.map(\.path), ["/tmp/alpha", "/tmp/beta"])
    }

    func testCapsTheMenuAndKeepsRecencyOrder() {
        let recent = (0..<20).map { "/tmp/folder-\($0)" }
        let result = AddableRecentFolders.compute(
            recent: recent,
            openProjectPaths: [],
            isDirectory: { _ in true }
        )
        XCTAssertEqual(result.count, AddableRecentFolders.limit)
        XCTAssertEqual(result.first?.path, "/tmp/folder-0")
        XCTAssertEqual(result.last?.path, "/tmp/folder-\(AddableRecentFolders.limit - 1)")
    }

    func testEmptyRecentsProduceAnEmptyMenu() {
        XCTAssertEqual(
            AddableRecentFolders.compute(
                recent: [],
                openProjectPaths: [],
                isDirectory: { _ in true }
            ),
            []
        )
    }

    func testRunOnTargetsExposeDistinctScopedSectionsAndIcons() {
        let local = RunOnTarget(
            name: "Kaisola",
            path: "/tmp/kaisola",
            branch: "main",
            host: "This Mac",
            scope: .local,
            isRecent: false
        )
        let worktree = RunOnTarget(
            name: "Codex worktree",
            path: "/tmp/kaisola-codex",
            branch: "kaisola-mesh-codex",
            host: "This Mac",
            scope: .worktree,
            isRecent: false
        )
        let unavailable = RunOnTarget(
            name: "Archived project",
            path: "/Volumes/offline/project",
            branch: nil,
            host: "This Mac",
            scope: .unavailable,
            isRecent: true
        )

        XCTAssertEqual(RunOnScope.allCases.map(\.sectionTitle), [
            "This Computer", "Mesh Worktrees", "Unavailable",
        ])
        XCTAssertEqual(Set(RunOnScope.allCases.map(\.systemImage)).count, 3)
        XCTAssertTrue(local.canStart)
        XCTAssertTrue(worktree.canStart)
        XCTAssertFalse(unavailable.canStart)
    }

    func testRunOnSearchNeverLeaksAcrossTheSelectedScope() {
        let targets = [
            RunOnTarget(
                name: "Shared local",
                path: "/tmp/local-shared",
                branch: "main",
                host: "This Mac",
                scope: .local,
                isRecent: false
            ),
            RunOnTarget(
                name: "Shared worktree",
                path: "/tmp/worktree-shared",
                branch: "feature/shared",
                host: "This Mac",
                scope: .worktree,
                isRecent: false
            ),
        ]
        var picker = RunOnPickerModel(targets: targets, selectedScope: .local)
        picker.updateQuery("shared")
        XCTAssertEqual(picker.filteredTargets.map(\.scope), [.local])
        XCTAssertEqual(picker.filteredTargets.map(\.name), ["Shared local"])

        picker.selectScope(.worktree)
        picker.updateQuery("shared")
        XCTAssertEqual(picker.filteredTargets.map(\.scope), [.worktree])
        XCTAssertEqual(picker.filteredTargets.map(\.name), ["Shared worktree"])
    }

    func testRunOnConfirmationNamesEveryExecutionBoundary() {
        let target = RunOnTarget(
            name: "Review branch",
            path: "/private/tmp/review",
            branch: "codex/review",
            host: "Michaels-Mac",
            scope: .worktree,
            isRecent: false
        )
        XCTAssertEqual(
            target.confirmation(accountName: "Research"),
            "Filesystem: /private/tmp/review\nGit branch: codex/review\nAccount: Research\nExecution host: Michaels-Mac"
        )
    }

    func testRemovingARecentOnlyRemovesThatPickerEntry() {
        let recent = RunOnTarget(
            name: "Recent",
            path: "/tmp/recent",
            branch: nil,
            host: "This Mac",
            scope: .local,
            isRecent: true
        )
        let project = RunOnTarget(
            name: "Open project",
            path: "/tmp/open",
            branch: "main",
            host: "This Mac",
            scope: .local,
            isRecent: false
        )
        var picker = RunOnPickerModel(targets: [recent, project], selectedScope: .local)

        XCTAssertNil(picker.removeRecent(targetID: project.id))
        XCTAssertEqual(picker.removeRecent(targetID: recent.id), "/tmp/recent")
        XCTAssertEqual(picker.targets, [project])
    }

    func testRemovingTheLastTargetInAScopeMovesToTheRemainingScope() {
        let recent = RunOnTarget(
            name: "Recent",
            path: "/tmp/recent",
            branch: nil,
            host: "This Mac",
            scope: .local,
            isRecent: true
        )
        let worktree = RunOnTarget(
            name: "Worktree",
            path: "/tmp/worktree",
            branch: "feature",
            host: "This Mac",
            scope: .worktree,
            isRecent: false
        )
        var picker = RunOnPickerModel(targets: [recent, worktree], selectedScope: .local)

        XCTAssertEqual(picker.removeRecent(targetID: recent.id), recent.path)
        XCTAssertEqual(picker.selectedScope, .worktree)
        XCTAssertEqual(picker.selectedTarget, worktree)
    }

    func testTargetBuilderDedupeKeepsOpenProjectsAndPartitionsOfflineRecents() {
        let targets = RunOnTargetBuilder.build(
            projects: [
                .init(name: "Open", path: "/tmp/open"),
            ],
            recentPaths: ["/tmp/open", "/tmp/recent", "/tmp/offline"],
            worktrees: [
                .init(name: "Codex", path: "/tmp/worktree", branch: "mesh/codex"),
            ],
            host: "This Mac",
            isDirectory: { $0 != "/tmp/offline" },
            branch: { path in
                path == "/tmp/open" ? "main" : nil
            }
        )

        XCTAssertEqual(targets.map(\.path), [
            "/tmp/open", "/tmp/recent", "/tmp/worktree", "/tmp/offline",
        ])
        XCTAssertEqual(targets.map(\.scope), [.local, .local, .worktree, .unavailable])
        XCTAssertEqual(targets.map(\.isRecent), [false, true, false, true])
    }

    @MainActor
    func testRunOnPickerMakesLocationSubscriptionAndRunProfileReadableAtAGlance() throws {
        let target = RunOnTarget(
            name: "Kaisola",
            path: "/Users/example/Developer/Kaisola",
            branch: "main",
            host: "Michaels-Mac",
            scope: .local,
            isRecent: false
        )
        let controller = RunOnPickerController(
            model: RunOnPickerModel(targets: [target], selectedScope: .local),
            profiles: [
                UsageAccountProfile(
                    id: "research",
                    provider: .codex,
                    label: "Research",
                    directory: "/Users/example/.codex-research"
                ),
            ],
            provider: .codex,
            runProfiles: AcpRunProfile.builtIns,
            selectedRunProfileID: AcpRunProfile.write.id,
            preferNamedAccount: true,
            removeRecent: { _ in }
        )

        controller.refresh()
        controller.accessoryView.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.scopeControl.segmentCount, RunOnScope.allCases.count)
        XCTAssertEqual(controller.scopeControl.selectedSegment, 0)
        XCTAssertTrue(controller.scopeControl.isHidden, "one available location is not a choice")
        XCTAssertTrue(controller.searchField.isHidden, "two targets do not need a search box")
        XCTAssertGreaterThanOrEqual(controller.targetPopup.frame.width, 480)
        XCTAssertEqual(controller.accountPopup.accessibilityLabel(), "Subscription")
        XCTAssertGreaterThanOrEqual(controller.accountPopup.frame.width, 220)
        XCTAssertEqual(controller.runProfilePopup.accessibilityLabel(), "Run profile")
        XCTAssertEqual(controller.selectedRunProfile?.id, AcpRunProfile.write.id)
        XCTAssertTrue(controller.confirmationLabel.stringValue.contains("Kaisola"))
        XCTAssertTrue(controller.confirmationLabel.stringValue.contains("Research"))
        XCTAssertTrue(controller.confirmationLabel.stringValue.contains("Write"))
        XCTAssertTrue(controller.removeRecentButton.isHidden)
        XCTAssertEqual(controller.chooseFolderButton.title, "Choose another folder…")
        var choseAnotherFolder = false
        controller.chooseFolder = { choseAnotherFolder = true }
        controller.chooseFolderButton.performClick(nil)
        XCTAssertTrue(choseAnotherFolder, "the inline location action is visually present but inert")
    }

    func testRunProfileLaunchSummaryNamesModelAndHostAccess() {
        XCTAssertEqual(
            RunOnPickerPresentation.runProfileSummary(.write),
            "Provider default model · Read, write, terminal · All MCP servers"
        )
        XCTAssertEqual(
            RunOnPickerPresentation.runProfileSummary(.minimal),
            "Provider default model · No host tools · No MCP servers"
        )
    }

    @MainActor
    func testRunOnPickerRestoresSubscriptionAndRunProfileWhileChangingLocation() {
        let profile = UsageAccountProfile(
            id: "research",
            provider: .codex,
            label: "Research",
            directory: "/Users/example/.codex-research"
        )
        let selection = RunOnPickerSelection(
            accountProfileID: profile.id,
            runProfileID: AcpRunProfile.minimal.id
        )
        let controller = RunOnPickerController(
            model: RunOnPickerModel(targets: [
                RunOnTarget(
                    name: "Kaisola",
                    path: "/tmp/kaisola",
                    branch: "main",
                    host: "This Mac",
                    scope: .local,
                    isRecent: false
                ),
            ]),
            profiles: [profile],
            provider: .codex,
            runProfiles: AcpRunProfile.builtIns,
            selectedRunProfileID: AcpRunProfile.write.id,
            restoredSelection: selection,
            preferNamedAccount: false,
            removeRecent: { _ in }
        )

        XCTAssertEqual(controller.selectedProfile?.id, profile.id)
        XCTAssertEqual(controller.selectedRunProfile?.id, AcpRunProfile.minimal.id)
        XCTAssertEqual(controller.selection, selection)
    }
}
