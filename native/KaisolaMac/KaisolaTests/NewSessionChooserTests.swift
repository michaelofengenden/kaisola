import XCTest
@testable import Kaisola

@MainActor
final class NewSessionChooserTests: XCTestCase {
    func testTerminalChoicesDisableWithoutControlButChatAndMeshStayEnabled() {
        let catalog = NewSessionChoiceCatalog(
            terminalAgents: [.init(id: "claude", name: "Claude", symbol: "sparkles")],
            chatAgents: [.init(id: "claude", name: "Claude", symbol: "sparkles")]
        )

        let options = NewSessionChooserPresentation.primaryOptions(
            catalog: catalog,
            terminalControlAvailable: false
        )

        XCTAssertEqual(
            options.map(\.choice),
            [.terminal, .agentTerminalCategory, .chatCategory, .mesh]
        )
        XCTAssertFalse(options[0].isEnabled)
        XCTAssertFalse(options[1].isEnabled)
        XCTAssertTrue(options[2].isEnabled)
        XCTAssertTrue(options[3].isEnabled)
        XCTAssertEqual(options[0].disabledReason, "Terminals are preparing. Try again in a moment.")
    }

    func testAvailableTerminalChoicesEnableWhenControlReturns() {
        let catalog = NewSessionChoiceCatalog(
            terminalAgents: [.init(id: "codex", name: "Codex", symbol: "terminal")],
            chatAgents: []
        )

        let options = NewSessionChooserPresentation.primaryOptions(
            catalog: catalog,
            terminalControlAvailable: true
        )

        XCTAssertEqual(options.map(\.choice), [.terminal, .agentTerminalCategory, .mesh])
        XCTAssertTrue(options.allSatisfy(\.isEnabled))
        XCTAssertTrue(options.allSatisfy { $0.disabledReason == nil })
    }

    func testEmptyAgentCategoriesAreOmitted() {
        let options = NewSessionChooserPresentation.primaryOptions(
            catalog: .init(terminalAgents: [], chatAgents: []),
            terminalControlAvailable: true
        )

        XCTAssertEqual(options.map(\.choice), [.terminal, .mesh])
    }

    func testPrimaryChoiceCopyNamesWhatEachSessionBecomes() {
        let catalog = NewSessionChoiceCatalog(
            terminalAgents: [.init(id: "codex", name: "Codex", symbol: "terminal")],
            chatAgents: [.init(id: "claude", name: "Claude", symbol: "sparkles")]
        )

        let options = NewSessionChooserPresentation.primaryOptions(
            catalog: catalog,
            terminalControlAvailable: true
        )

        XCTAssertEqual(options.map(\.title), ["Terminal", "Agent Terminal", "Chat", "Mesh"])
        XCTAssertEqual(options.map(\.symbol), [
            "terminal",
            "chevron.left.forwardslash.chevron.right",
            "bubble.left.and.text.bubble.right",
            "circle.hexagongrid.fill",
        ])
    }

    func testTerminalRowsDisableWhenControlDropsOrALaunchIsAlreadyRunning() {
        XCTAssertTrue(NewSessionChooserPresentation.terminalRowsEnabled(
            terminalControlAvailable: true,
            isLaunching: false
        ))
        XCTAssertFalse(NewSessionChooserPresentation.terminalRowsEnabled(
            terminalControlAvailable: false,
            isLaunching: false
        ))
        XCTAssertFalse(NewSessionChooserPresentation.terminalRowsEnabled(
            terminalControlAvailable: true,
            isLaunching: true
        ))
    }

    func testLaunchFailureCopyDoesNotInventAFolderDiagnosis() {
        XCTAssertEqual(
            NewSessionChooserPresentation.launchFailureMessage,
            "Session did not start. Review the error and try again."
        )
        XCTAssertEqual(
            NewSessionChooserPresentation.launchFailureMessage(
                detail: "Terminal limit reached. Close a terminal and try again."
            ),
            "Terminal limit reached. Close a terminal and try again."
        )
        XCTAssertEqual(
            NewSessionChooserPresentation.launchFailureMessage(detail: "  "),
            "Session did not start. Review the error and try again."
        )
    }

    /// The choice cards answer the pointer: rest, hover, and press are three
    /// distinct steps, and the hover stroke brightens with the fill so the
    /// card reads as raised rather than merely darker.
    func testChoiceCardInteractionLadderStepsUpFromRestThroughHoverToPress() {
        XCTAssertLessThan(
            NewSessionChoiceButtonStyle.restFill,
            NewSessionChoiceButtonStyle.hoverFill
        )
        XCTAssertLessThan(
            NewSessionChoiceButtonStyle.hoverFill,
            NewSessionChoiceButtonStyle.pressFill
        )
        XCTAssertLessThan(
            NewSessionChoiceButtonStyle.restStroke,
            NewSessionChoiceButtonStyle.hoverStroke
        )
        // The whole ladder stays a wash, never a filled chip.
        XCTAssertLessThanOrEqual(NewSessionChoiceButtonStyle.pressFill, 0.12)
        XCTAssertLessThanOrEqual(NewSessionChoiceButtonStyle.hoverStroke, 0.25)
        // Keyboard focus is a rung of its own: the style defaults unfocused
        // and a focused card must at least reach the hover fill, or the
        // programmatically focused first card is indistinguishable from the
        // other three.
        XCTAssertFalse(NewSessionChoiceButtonStyle().isFocused)
        XCTAssertTrue(NewSessionChoiceButtonStyle(isFocused: true).isFocused)
        XCTAssertGreaterThan(KaisolaVisualSystem.focusStroke, 0)
    }
}
