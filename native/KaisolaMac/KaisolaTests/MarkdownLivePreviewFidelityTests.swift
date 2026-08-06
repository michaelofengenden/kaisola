import XCTest
@testable import Kaisola

/// Byte-level regression net over every new Live Preview edit, plus the
/// bounded-restyle guarantee for cursor moves in large documents.
final class MarkdownLivePreviewFidelityTests: XCTestCase {
    func testEveryNewEditProducesExactBytes() {
        var text = "- [ ] task\n- item\n1. a\n5. b\nbold word\n"
        func apply(_ edit: (range: NSRange, replacement: String)?) {
            guard let edit else { return }
            text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }

        apply(MarkdownTaskToggle.toggleRange(at: 3, in: text as NSString))
        XCTAssertEqual(text, "- [x] task\n- item\n1. a\n5. b\nbold word\n")

        let itemParagraph = (text as NSString).paragraphRange(for: NSRange(location: 12, length: 0))
        apply(MarkdownListIndent.edit(
            for: text as NSString, paragraph: itemParagraph, direction: .indent
        ))
        XCTAssertEqual(text, "- [x] task\n\t- item\n1. a\n5. b\nbold word\n")

        if let block = MarkdownListIndent.orderedBlock(containing: 20, in: text as NSString) {
            for edit in MarkdownListIndent.renumber(block: block, in: text as NSString) {
                apply(edit)
            }
        }
        XCTAssertEqual(text, "- [x] task\n\t- item\n1. a\n2. b\nbold word\n")

        let boldRange = ((text as NSString).range(of: "bold"))
        if let wrap = MarkdownInlineFormatting.toggleWrap("**", selection: boldRange, in: text as NSString) {
            for edit in wrap.edits { apply((edit.0, edit.1)) }
        }
        XCTAssertEqual(text, "- [x] task\n\t- item\n1. a\n2. b\n**bold** word\n")
    }

    func testRevealRestyleIsBoundedByParagraph() {
        let big = String(repeating: "paragraph body line\n\n", count: 5_000) as NSString
        let old = MarkdownRevealState.compute(selection: NSRange(location: 0, length: 0), in: big)
        let new = MarkdownRevealState.compute(selection: NSRange(location: 42, length: 0), in: big)
        let changed = MarkdownRevealState.changedRanges(from: old, to: new)
        let total = changed.reduce(0) { $0 + $1.length }
        XCTAssertLessThan(total, 200, "cursor move restyle must not scale with document size")
    }

    func testWikilinkDestinationRoundTripsThroughTheScheme() {
        let source = "see [[My Note]] for detail\n"
        let destination = MarkdownLinkTargets.destination(at: 8, in: source)
        XCTAssertEqual(destination, "kaisola-wiki:/My%20Note")
        let url = URL(string: destination ?? "")
        XCTAssertEqual(url?.scheme, "kaisola-wiki")
        XCTAssertEqual(String(url?.path.dropFirst() ?? "").removingPercentEncoding, "My Note")
    }
}
