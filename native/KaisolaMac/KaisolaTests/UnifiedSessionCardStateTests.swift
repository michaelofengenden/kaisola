import XCTest
@testable import Kaisola

final class UnifiedSessionCardStateTests: XCTestCase {
    func testFocusAndRevealTransitionsOwnLayoutSelectionAndPresentation() {
        var state = UnifiedSessionCardState(
            layouts: ["project": SessionPaneLayout(columns: [
                .init(sessionIDs: ["one", "two"])
            ])],
            focusedPaneID: "one",
            maximizedPaneID: "one"
        )

        state.focus("three", in: "project")

        XCTAssertEqual(state.layout(for: "project").sessionIDs, ["three", "two"])
        XCTAssertEqual(state.focusedPaneID, "three")
        XCTAssertNil(state.maximizedPaneID)

        state.revealBeside("four", in: "project")

        XCTAssertEqual(Set(state.layout(for: "project").sessionIDs), ["three", "two", "four"])
        XCTAssertEqual(state.focusedPaneID, "four")
    }

    func testRemovalClearsStalePresentationAndSelectsAVisibleFallback() {
        var state = UnifiedSessionCardState(
            layouts: ["project": SessionPaneLayout(columns: [
                .init(sessionIDs: ["one", "two"])
            ])],
            focusedPaneID: "two",
            maximizedPaneID: "two"
        )

        let layout = state.remove("two", from: "project")

        XCTAssertEqual(layout?.sessionIDs, ["one"])
        XCTAssertEqual(state.focusedPaneID, "one")
        XCTAssertNil(state.maximizedPaneID)
    }

    func testMoveAndReconcileStayProjectScoped() {
        var state = UnifiedSessionCardState(
            layouts: [
                "source": SessionPaneLayout(columns: [.init(sessionIDs: ["one", "two"])]),
                "target": SessionPaneLayout(sessionID: "three")
            ],
            focusedPaneID: "two",
            maximizedPaneID: "two"
        )

        state.move("two", from: "source", to: "target")

        XCTAssertEqual(state.layout(for: "source").sessionIDs, ["one"])
        XCTAssertEqual(Set(state.layout(for: "target").sessionIDs), ["two", "three"])
        XCTAssertEqual(state.focusedPaneID, "two")
        XCTAssertNil(state.maximizedPaneID)

        XCTAssertTrue(state.reconcile("target", availableSurfaceIDs: ["three"]))
        XCTAssertEqual(state.layout(for: "target").sessionIDs, ["three"])
        XCTAssertEqual(state.focusedPaneID, "three")
    }

    func testKeyboardFocusRequestsAdvanceEvenForTheSameSurface() {
        var state = UnifiedSessionCardState()

        let first = state.requestKeyboardFocus(for: "chat")
        let second = state.requestKeyboardFocus(for: "chat")

        XCTAssertEqual(first.targetID, "chat")
        XCTAssertEqual(second.targetID, "chat")
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertEqual(state.keyboardFocusRequest, second)
    }

    func testReplacingAVisibleSurfacePreservesItsMaximizedPresentation() {
        let original = SessionPaneLayout(columns: [
            .init(sessionIDs: ["old", "neighbor"])
        ])
        var state = UnifiedSessionCardState(
            layouts: ["project": original],
            focusedPaneID: "old",
            maximizedPaneID: "old"
        )

        XCTAssertTrue(state.replace("old", with: "new", in: "project", fallback: original))
        XCTAssertEqual(state.layout(for: "project").sessionIDs, ["new", "neighbor"])
        XCTAssertEqual(state.focusedPaneID, "new")
        XCTAssertEqual(state.maximizedPaneID, "new")
    }
}
