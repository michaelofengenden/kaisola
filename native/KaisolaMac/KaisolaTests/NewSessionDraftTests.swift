import XCTest
@testable import Kaisola

@MainActor
final class NewSessionDraftTests: XCTestCase {
    func testBeginCreatesOneSelectedDraftAndReusesItForTheProject() {
        var state = NewSessionDraftState()

        let first = state.begin(projectID: "project-a")
        let second = state.begin(projectID: "project-a")

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.id.hasPrefix("new-session-"))
        XCTAssertEqual(state.draft(for: "project-a"), first)
        XCTAssertEqual(state.selectedDraft, first)
        XCTAssertEqual(state.selectedDraftID, first.id)
    }

    func testProjectsKeepIndependentDraftsAndRealSelectionOnlyDeselects() {
        var state = NewSessionDraftState()
        let first = state.begin(projectID: "project-a")
        let second = state.begin(projectID: "project-b")

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(state.selectedDraft, second)

        state.selectRealSurface()

        XCTAssertNil(state.selectedDraftID)
        XCTAssertEqual(state.draft(for: "project-a"), first)
        XCTAssertEqual(state.draft(for: "project-b"), second)

        state.selectDraft(first.id)

        XCTAssertEqual(state.selectedDraft, first)
    }

    func testSelectingAnUnknownDraftDoesNotLoseTheCurrentSelection() {
        var state = NewSessionDraftState()
        let draft = state.begin(projectID: "project-a")

        state.selectDraft("new-session-missing")

        XCTAssertEqual(state.selectedDraft, draft)
    }

    func testCancelCompleteAndRetainRemoveOnlyTheIntendedDrafts() {
        var state = NewSessionDraftState()
        _ = state.begin(projectID: "project-a")
        _ = state.begin(projectID: "project-b")
        let retained = state.begin(projectID: "project-c")

        state.cancel(projectID: "project-a")
        state.complete(projectID: "project-b")
        state.retainProjects(["project-c"])

        XCTAssertNil(state.draft(for: "project-a"))
        XCTAssertNil(state.draft(for: "project-b"))
        XCTAssertEqual(state.draft(for: "project-c"), retained)
        XCTAssertEqual(state.selectedDraft, retained)
    }

    func testPruningTheSelectedProjectClearsOnlyTheSelectionAndRemovedDraft() {
        var state = NewSessionDraftState()
        let retained = state.begin(projectID: "project-a")
        _ = state.begin(projectID: "project-b")

        state.retainProjects(["project-a"])

        XCTAssertEqual(state.draft(for: "project-a"), retained)
        XCTAssertNil(state.draft(for: "project-b"))
        XCTAssertNil(state.selectedDraftID)
    }

    func testTerminalLaunchKeepsTheDraftRetryableUntilCreationSucceeds() throws {
        var state = NewSessionDraftState()
        let draft = state.begin(projectID: "project-a")

        let failedLaunchID = try XCTUnwrap(state.beginLaunch(projectID: "project-a"))
        XCTAssertNil(state.beginLaunch(projectID: "project-a"), "one draft may start only once")
        XCTAssertTrue(state.isLaunching(projectID: "project-a"))
        XCTAssertEqual(state.selectedDraft, draft, "starting is not the same as succeeding")

        state.finishLaunch(projectID: "project-a", launchID: failedLaunchID, succeeded: false)

        XCTAssertFalse(state.isLaunching(projectID: "project-a"))
        XCTAssertTrue(state.didLastLaunchFail(projectID: "project-a"))
        XCTAssertEqual(state.selectedDraft, draft, "a failed launch must remain retryable")

        let successfulLaunchID = try XCTUnwrap(state.beginLaunch(projectID: "project-a"))
        XCTAssertFalse(state.didLastLaunchFail(projectID: "project-a"))
        state.finishLaunch(
            projectID: "project-a",
            launchID: successfulLaunchID,
            succeeded: true
        )

        XCTAssertFalse(state.isLaunching(projectID: "project-a"))
        XCTAssertNil(state.draft(for: "project-a"))
        XCTAssertNil(state.selectedDraftID)
    }

    func testInFlightLaunchCannotBeCancelledButProjectPruningStillClearsIt() {
        var state = NewSessionDraftState()
        let draft = state.begin(projectID: "project-a")
        _ = state.beginLaunch(projectID: "project-a")

        state.cancel(projectID: "project-a")

        XCTAssertTrue(state.isLaunching(projectID: "project-a"))
        XCTAssertEqual(state.draft(for: "project-a"), draft)

        state.retainProjects([])

        XCTAssertFalse(state.isLaunching(projectID: "project-a"))
        XCTAssertNil(state.draft(for: "project-a"))
    }

    func testCancellingRunOnChoiceReturnsTheDraftToIdleWithoutReportingFailure() throws {
        var state = NewSessionDraftState()
        let draft = state.begin(projectID: "project-a")
        let launchID = try XCTUnwrap(state.beginLaunch(projectID: "project-a"))

        state.cancelLaunch(projectID: "project-a", launchID: launchID)

        XCTAssertFalse(state.isLaunching(projectID: "project-a"))
        XCTAssertFalse(state.didLastLaunchFail(projectID: "project-a"))
        XCTAssertEqual(state.selectedDraft, draft)
    }

    func testStaleLaunchCallbacksCannotMutateAReplacementDraftWithTheSameProjectID() throws {
        var state = NewSessionDraftState()
        _ = state.begin(projectID: "project-a")
        let staleLaunchID = try XCTUnwrap(state.beginLaunch(projectID: "project-a"))
        state.retainProjects([])

        let replacement = state.begin(projectID: "project-a")
        let replacementLaunchID = try XCTUnwrap(state.beginLaunch(projectID: "project-a"))

        state.cancelLaunch(projectID: "project-a", launchID: staleLaunchID)
        XCTAssertFalse(state.finishLaunch(
            projectID: "project-a",
            launchID: staleLaunchID,
            succeeded: true
        ))

        XCTAssertTrue(state.isLaunching(projectID: "project-a"))
        XCTAssertEqual(state.selectedDraft, replacement)

        XCTAssertTrue(state.finishLaunch(
            projectID: "project-a",
            launchID: replacementLaunchID,
            succeeded: false
        ))

        XCTAssertFalse(state.isLaunching(projectID: "project-a"))
        XCTAssertTrue(state.didLastLaunchFail(projectID: "project-a"))
        XCTAssertEqual(state.selectedDraft, replacement)
    }

    func testCatalogSeparatesTerminalAgentsFromChatCapableAgents() {
        let catalog = NewSessionChoiceCatalog.make(
            agents: [
                .init(id: "claude", name: "Claude", symbol: "sparkles"),
                .init(id: "shell-only", name: "Shell Only", symbol: "terminal"),
            ],
            supportsChat: { $0 == "claude" }
        )

        XCTAssertEqual(catalog.terminalAgents.map(\.id), ["claude", "shell-only"])
        XCTAssertEqual(catalog.chatAgents.map(\.id), ["claude"])
    }

    func testSessionChoicesCarryTheSelectedAgentIdentity() {
        XCTAssertEqual(NewSessionChoice.agentTerminal("codex"), .agentTerminal("codex"))
        XCTAssertEqual(NewSessionChoice.chat("claude"), .chat("claude"))
        XCTAssertNotEqual(NewSessionChoice.terminal, .mesh)
    }
}
