import Foundation
import XCTest
@testable import Kaisola

/// What the per-project Accounts row says a stored directory points at, and
/// what it offers when nothing points back. The regression this pins: a
/// directory no named account claims used to be printed where an account name
/// belongs, so a deleted or externally edited assignment looked exactly like a
/// deliberate selection.
final class ProjectAccountSelectionTests: XCTestCase {
    private let work = UsageAccountProfile(
        id: "acct_work", provider: .claude, label: "Work", directory: "~/.claude-work"
    )
    private let personal = UsageAccountProfile(
        id: "acct_personal", provider: .claude, label: "Personal", directory: "~/.claude-personal"
    )
    private let codex = UsageAccountProfile(
        id: "acct_codex", provider: .codex, label: "Codex Work", directory: "~/.codex-work"
    )

    private var profiles: [UsageAccountProfile] { [work, personal, codex] }

    func testNewAccountProviderPickerNamesItsPurposeAndEverySegment() {
        XCTAssertEqual(NewAccountProviderAccessibility.label, "New account provider")
        XCTAssertEqual(
            UsageAccountProfile.Provider.allCases.map(NewAccountProviderAccessibility.value),
            ["Claude", "Codex"]
        )
        XCTAssertEqual(NewAccountProviderAccessibility.value(.claude), "Claude")
        XCTAssertEqual(NewAccountProviderAccessibility.value(.codex), "Codex")
    }

    func testStoreRecoveryTakesPrecedenceOverProjectAssignmentRows() {
        XCTAssertEqual(
            ProjectAccountCardMode.resolve(hasRecoveryIssue: true, projectID: "project-1"),
            .recovery
        )
        XCTAssertEqual(
            ProjectAccountCardMode.resolve(hasRecoveryIssue: false, projectID: "project-1"),
            .project
        )
        XCTAssertEqual(
            ProjectAccountCardMode.resolve(hasRecoveryIssue: false, projectID: nil),
            .noProject
        )
        XCTAssertEqual(
            ProjectAccountCardMode.resolve(hasRecoveryIssue: true, projectID: nil),
            .recovery
        )
    }

    func testNamedAccountRemovalConfirmationListsProjectsAndOffersAppDefault() {
        let impact = NamedAccountRemovalConfirmation(
            accountLabel: "Work",
            projectLabels: ["Kaisola", "Research"]
        )

        XCTAssertEqual(impact.actionTitle, "Use App Default and Remove Account")
        XCTAssertEqual(
            impact.message,
            "Work is assigned to 2 projects: Kaisola and Research. Those projects will use App Default. The provider files and sign-in stay on disk."
        )
    }

    func testUnassignedAccountRemovalKeepsTheSimpleConfirmation() {
        let impact = NamedAccountRemovalConfirmation(
            accountLabel: "Personal",
            projectLabels: []
        )

        XCTAssertEqual(impact.actionTitle, "Remove Account")
        XCTAssertEqual(
            impact.message,
            "Kaisola will forget Personal. Its provider files and sign-in stay on disk."
        )
    }

    // MARK: - Healthy assignments

    func testBlankOverrideIsAppDefault() {
        for stored in ["", "   "] {
            let selection = ProjectAccountSelection.resolve(
                storedDirectory: stored, provider: .claude, profiles: profiles
            )
            XCTAssertEqual(selection, .appDefault)
            XCTAssertEqual(selection.menuTitle, "App Default")
            XCTAssertFalse(selection.isMissing)
        }
    }

    func testMatchedDirectoryReadsAsItsAccountName() {
        let selection = ProjectAccountSelection.resolve(
            storedDirectory: "~/.claude-work", provider: .claude, profiles: profiles
        )
        XCTAssertEqual(selection, .account(work))
        XCTAssertEqual(selection.menuTitle, "Work")
        XCTAssertFalse(selection.isMissing)
        XCTAssertNil(selection.repairHeader)
        XCTAssertEqual(
            selection.detail(provider: .claude, projectName: "Kaisola"),
            "Used by Claude sessions in Kaisola"
        )
    }

    /// One directory written three ways is still one account, so "missing"
    /// keeps meaning missing rather than "spelled differently".
    func testExpandedAndTrailingSlashFormsStillMatchTheirAccount() {
        let expanded = ("~/.claude-work" as NSString).expandingTildeInPath
        for stored in [expanded, expanded + "/", "  ~/.claude-work  ", "~/.claude-work/./"] {
            XCTAssertEqual(
                ProjectAccountSelection.resolve(
                    storedDirectory: stored, provider: .claude, profiles: profiles
                ),
                .account(work),
                "expected \(stored) to resolve to Work"
            )
        }
    }

    // MARK: - Broken assignments

    /// The bug: the raw path used to be the menu's title. It is now a state
    /// with the path demoted to diagnostic detail.
    func testUnmatchedDirectoryIsMarkedMissingInsteadOfShownAsAValue() {
        let gone = "~/.claude-deleted"
        let selection = ProjectAccountSelection.resolve(
            storedDirectory: gone, provider: .claude, profiles: profiles
        )

        XCTAssertEqual(selection, .missing(gone))
        XCTAssertTrue(selection.isMissing)
        XCTAssertEqual(selection.menuTitle, "Missing account")
        XCTAssertNotEqual(selection.menuTitle, gone)
        XCTAssertFalse(
            selection.menuTitle.contains("/"),
            "the menu button must not read as a path"
        )
    }

    func testMissingAssignmentShowsThePathAsDiagnosticDetail() {
        let gone = "~/.claude-deleted"
        let selection = ProjectAccountSelection.resolve(
            storedDirectory: gone, provider: .claude, profiles: profiles
        )

        XCTAssertEqual(selection.missingDirectory, gone)
        XCTAssertEqual(
            selection.detail(provider: .claude, projectName: "Kaisola"),
            "No named account uses \(gone)"
        )
        // The caption is the diagnostic even when the project has no name.
        XCTAssertEqual(
            selection.detail(provider: .claude, projectName: nil),
            "No named account uses \(gone)"
        )
        XCTAssertEqual(selection.repairHeader, "Missing: \(gone)")
        XCTAssertEqual(selection.accessibilityValue, "Missing account, \(gone)")
    }

    /// A Claude row pinned to a Codex account's directory is broken too: the
    /// provider has to match, not just the path.
    func testDirectoryOwnedByTheOtherProviderIsMissing() {
        XCTAssertEqual(
            ProjectAccountSelection.resolve(
                storedDirectory: "~/.codex-work", provider: .claude, profiles: profiles
            ),
            .missing("~/.codex-work")
        )
        XCTAssertEqual(
            ProjectAccountSelection.resolve(
                storedDirectory: "~/.codex-work", provider: .codex, profiles: profiles
            ),
            .account(codex)
        )
    }

    func testEveryAccountRemovedLeavesTheAssignmentMissingNotDefaulted() {
        let selection = ProjectAccountSelection.resolve(
            storedDirectory: "~/.claude-work", provider: .claude, profiles: []
        )
        XCTAssertEqual(selection, .missing("~/.claude-work"))
        XCTAssertNotEqual(selection, .appDefault)
    }

    /// Resolving is a read. The broken directory survives it verbatim, so the
    /// stored override is still there to repair (or to recognise) later.
    func testResolvingABrokenAssignmentKeepsTheStoredValueVerbatim() {
        let gone = "~/.claude-deleted"
        let first = ProjectAccountSelection.resolve(
            storedDirectory: gone, provider: .claude, profiles: profiles
        )
        XCTAssertEqual(first.missingDirectory, gone)
        XCTAssertEqual(
            first,
            ProjectAccountSelection.resolve(
                storedDirectory: first.missingDirectory ?? "", provider: .claude, profiles: profiles
            )
        )
    }

    // MARK: - Repairs

    func testRepairsOfferAppDefaultAndOnlyCompatibleAccounts() {
        let repairs = ProjectAccountSelection.repairs(provider: .claude, profiles: profiles)

        XCTAssertEqual(repairs, [.appDefault, .account(work), .account(personal)])
        XCTAssertEqual(repairs.map(\.title), ["App Default", "Work", "Personal"])
        XCTAssertFalse(
            repairs.contains(.account(codex)),
            "a Codex account is not a repair for a Claude row"
        )
    }

    /// Each repair is one click and writes exactly one value: App Default
    /// clears the override, a named account stores its own directory.
    func testEachRepairStoresOneValue() {
        let repairs = ProjectAccountSelection.repairs(provider: .claude, profiles: profiles)

        XCTAssertEqual(repairs.map(\.storedDirectory), ["", "~/.claude-work", "~/.claude-personal"])
        // Applying a repair lands on a healthy selection.
        for repair in repairs {
            let repaired = ProjectAccountSelection.resolve(
                storedDirectory: repair.storedDirectory, provider: .claude, profiles: profiles
            )
            XCTAssertFalse(repaired.isMissing, "\(repair.title) should repair the row")
        }
    }

    func testRepairsAreOfferedEvenWithNoNamedAccounts() {
        XCTAssertEqual(
            ProjectAccountSelection.repairs(provider: .claude, profiles: [codex]),
            [.appDefault]
        )
    }
}
