import XCTest
@testable import Kaisola

final class MarkdownListIndentTests: XCTestCase {
    func testIndentInsertsTabAtListLineStart() {
        let source = "- item\n" as NSString
        let edit = MarkdownListIndent.edit(
            for: source, paragraph: NSRange(location: 0, length: 7), direction: .indent
        )
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(edit?.replacement, "\t")
    }

    func testOutdentRemovesOneTab() {
        let source = "\t- item\n" as NSString
        let edit = MarkdownListIndent.edit(
            for: source, paragraph: NSRange(location: 0, length: 8), direction: .outdent
        )
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(edit?.replacement, "")
    }

    func testOutdentRemovesLeadingSpaces() {
        let source = "  - item\n" as NSString
        let edit = MarkdownListIndent.edit(
            for: source, paragraph: NSRange(location: 0, length: 9), direction: .outdent
        )
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 2))
    }

    func testNonListLineReturnsNil() {
        let source = "plain text\n" as NSString
        XCTAssertNil(MarkdownListIndent.edit(
            for: source, paragraph: NSRange(location: 0, length: 11), direction: .indent
        ))
    }

    func testOrderedItemsIndentToo() {
        let source = "3. item\n" as NSString
        let edit = MarkdownListIndent.edit(
            for: source, paragraph: NSRange(location: 0, length: 8), direction: .indent
        )
        XCTAssertEqual(edit?.replacement, "\t")
    }

    func testRenumberRewritesContiguousOrderedBlock() {
        let source = "1. a\n5. b\n9. c\n" as NSString
        let edits = MarkdownListIndent.renumber(block: NSRange(location: 0, length: 15), in: source)
        XCTAssertEqual(edits.count, 2)
        // Bottom-up: the "9" on line three becomes "3" first.
        XCTAssertEqual(edits.first?.range, NSRange(location: 10, length: 1))
        XCTAssertEqual(edits.first?.replacement, "3")
        XCTAssertEqual(edits.last?.range, NSRange(location: 5, length: 1))
        XCTAssertEqual(edits.last?.replacement, "2")
    }

    func testRenumberAppliedSequentiallyProducesCleanSequence() {
        var text = "1. a\n5. b\n9. c\n"
        for edit in MarkdownListIndent.renumber(
            block: NSRange(location: 0, length: 15), in: text as NSString
        ) {
            text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }
        XCTAssertEqual(text, "1. a\n2. b\n3. c\n")
    }

    func testAlreadySequencedBlockNeedsNoEdits() {
        let source = "1. a\n2. b\n" as NSString
        XCTAssertEqual(MarkdownListIndent.renumber(block: NSRange(location: 0, length: 10), in: source).count, 0)
    }
}
