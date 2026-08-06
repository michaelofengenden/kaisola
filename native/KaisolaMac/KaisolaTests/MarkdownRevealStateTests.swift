import XCTest
@testable import Kaisola

/// Reveal-state diffing: a cursor move repaints only the paragraphs it left
/// and entered — the enforcement point for the "no work proportional to
/// document size on cursor moves" constraint in the 2026-08-06 spec.
final class MarkdownRevealStateTests: XCTestCase {
    private let source = "# Title\n\nBody one.\n\n## Second\n" as NSString

    func testCaretProducesItsParagraph() {
        let state = MarkdownRevealState.compute(selection: NSRange(location: 2, length: 0), in: source)
        XCTAssertEqual(state.activeParagraphs, [NSRange(location: 0, length: 8)])
    }

    func testSelectionSpanningParagraphsProducesAll() {
        let state = MarkdownRevealState.compute(selection: NSRange(location: 2, length: 12), in: source)
        XCTAssertEqual(state.activeParagraphs, [NSRange(location: 0, length: 19)])
    }

    func testChangedRangesIsSymmetricDifference() {
        let old = MarkdownRevealState.compute(selection: NSRange(location: 2, length: 0), in: source)
        let new = MarkdownRevealState.compute(selection: NSRange(location: 21, length: 0), in: source)
        XCTAssertEqual(
            MarkdownRevealState.changedRanges(from: old, to: new),
            [NSRange(location: 0, length: 8), NSRange(location: 20, length: 10)]
        )
    }

    func testNoMoveMeansNoChange() {
        let state = MarkdownRevealState.compute(selection: NSRange(location: 2, length: 0), in: source)
        XCTAssertEqual(MarkdownRevealState.changedRanges(from: state, to: state), [])
    }

    func testEmptySourceProducesNoActiveParagraphs() {
        let state = MarkdownRevealState.compute(selection: NSRange(location: 0, length: 0), in: "" as NSString)
        XCTAssertEqual(state, .none)
    }

    func testSelectionBeyondEndClampsToFinalParagraph() {
        // A stale selection past the end lands in the empty final paragraph
        // (after the trailing newline) — zero length, nothing to reveal.
        let state = MarkdownRevealState.compute(selection: NSRange(location: 999, length: 5), in: source)
        XCTAssertEqual(state.activeParagraphs, [NSRange(location: 30, length: 0)])
    }
}
