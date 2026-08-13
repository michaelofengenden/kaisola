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
        XCTAssertEqual(options[0].disabledReason, "Saved terminals are view-only right now.")
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
}
