import XCTest
@testable import Kaisola

final class MarkdownTaskToggleTests: XCTestCase {
    func testTogglesUncheckedToChecked() {
        let source = "- [ ] write tests\n" as NSString
        let edit = MarkdownTaskToggle.toggleRange(at: 3, in: source)
        XCTAssertEqual(edit?.range, NSRange(location: 3, length: 1))
        XCTAssertEqual(edit?.replacement, "x")
    }

    func testTogglesCheckedToUnchecked() {
        let source = "  - [x] done\n" as NSString
        let edit = MarkdownTaskToggle.toggleRange(at: 5, in: source)
        XCTAssertEqual(edit?.range, NSRange(location: 5, length: 1))
        XCTAssertEqual(edit?.replacement, " ")
    }

    func testUppercaseXTogglesOff() {
        let source = "- [X] shouty\n" as NSString
        let edit = MarkdownTaskToggle.toggleRange(at: 3, in: source)
        XCTAssertEqual(edit?.replacement, " ")
    }

    func testNonTaskLineReturnsNil() {
        XCTAssertNil(MarkdownTaskToggle.toggleRange(at: 2, in: "- plain bullet\n" as NSString))
    }

    func testSecondLineTaskResolvesAgainstItsOwnParagraph() {
        let source = "intro\n- [ ] second line task\n" as NSString
        let edit = MarkdownTaskToggle.toggleRange(at: 12, in: source)
        XCTAssertEqual(edit?.range, NSRange(location: 9, length: 1))
        XCTAssertEqual(edit?.replacement, "x")
    }

    func testBracketGroupHitTesting() {
        let source = "- [ ] item\n" as NSString
        XCTAssertTrue(MarkdownTaskToggle.bracketGroupContains(3, in: source))
        XCTAssertTrue(MarkdownTaskToggle.bracketGroupContains(2, in: source))
        XCTAssertFalse(MarkdownTaskToggle.bracketGroupContains(7, in: source))
        XCTAssertFalse(MarkdownTaskToggle.bracketGroupContains(0, in: source))
    }
}
