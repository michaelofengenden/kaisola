import XCTest
@testable import Kaisola

final class MarkdownInlineFormattingTests: XCTestCase {
    func testWrapAddsDelimiters() {
        let result = MarkdownInlineFormatting.toggleWrap(
            "**", selection: NSRange(location: 0, length: 4), in: "bold text" as NSString
        )
        XCTAssertEqual(result?.edits.map(\.1), ["**", "**"])
        XCTAssertEqual(result?.edits.first?.0, NSRange(location: 4, length: 0))
        XCTAssertEqual(result?.newSelection, NSRange(location: 2, length: 4))
    }

    func testWrapOnWrappedSelectionUnwraps() {
        let result = MarkdownInlineFormatting.toggleWrap(
            "**", selection: NSRange(location: 2, length: 4), in: "**bold** text" as NSString
        )
        XCTAssertEqual(result?.edits.map(\.1), ["", ""])
        XCTAssertEqual(result?.newSelection, NSRange(location: 0, length: 4))
    }

    func testSequentialApplicationRoundTrips() {
        var text = "make this bold"
        let selection = NSRange(location: 10, length: 4)
        let wrap = MarkdownInlineFormatting.toggleWrap("**", selection: selection, in: text as NSString)!
        for edit in wrap.edits {
            text = (text as NSString).replacingCharacters(in: edit.0, with: edit.1)
        }
        XCTAssertEqual(text, "make this **bold**")
        let unwrap = MarkdownInlineFormatting.toggleWrap("**", selection: wrap.newSelection, in: text as NSString)!
        for edit in unwrap.edits {
            text = (text as NSString).replacingCharacters(in: edit.0, with: edit.1)
        }
        XCTAssertEqual(text, "make this bold")
    }

    func testCollapsedSelectionReturnsNilForWrap() {
        XCTAssertNil(MarkdownInlineFormatting.toggleWrap(
            "**", selection: NSRange(location: 0, length: 0), in: "text" as NSString
        ))
    }

    func testLinkEditWithPastedURL() {
        let result = MarkdownInlineFormatting.linkEdit(
            selection: NSRange(location: 0, length: 4), url: "https://kaisola.dev", in: "docs here" as NSString
        )
        XCTAssertEqual(result?.edits.map(\.1), ["](https://kaisola.dev)", "["])
        var text = "docs here"
        for edit in result!.edits {
            text = (text as NSString).replacingCharacters(in: edit.0, with: edit.1)
        }
        XCTAssertEqual(text, "[docs](https://kaisola.dev) here")
    }

    func testLinkEditWithoutURLPlacesCaretInParens() {
        let result = MarkdownInlineFormatting.linkEdit(
            selection: NSRange(location: 0, length: 4), url: nil, in: "docs here" as NSString
        )
        XCTAssertEqual(result?.newSelection, NSRange(location: 7, length: 0))
    }

    func testPastedURLAcceptsOnlyBareHTTPURLs() {
        XCTAssertEqual(
            MarkdownInlineFormatting.pastedURL(from: " https://kaisola.dev/a?b=1 "),
            "https://kaisola.dev/a?b=1"
        )
        XCTAssertNil(MarkdownInlineFormatting.pastedURL(from: "not a url"))
        XCTAssertNil(MarkdownInlineFormatting.pastedURL(from: "file:///etc/passwd"))
        XCTAssertNil(MarkdownInlineFormatting.pastedURL(from: "https://a.dev and more"))
    }
}

final class WikilinkResolverTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/project")

    func testResolvesCaseInsensitiveBaseName() {
        let files = ["notes/Harvest-Blueprint.md", "docs/other.txt", "README.md"]
        XCTAssertEqual(
            WikilinkResolver.resolve("harvest-blueprint", inFiles: files, root: root)?.path,
            "/tmp/project/notes/Harvest-Blueprint.md"
        )
    }

    func testIgnoresNonMarkdownAndMisses() {
        let files = ["docs/other.txt"]
        XCTAssertNil(WikilinkResolver.resolve("other", inFiles: files, root: root))
        XCTAssertNil(WikilinkResolver.resolve("missing", inFiles: files, root: root))
        XCTAssertNil(WikilinkResolver.resolve("  ", inFiles: files, root: root))
    }
}
