import XCTest
@testable import Kaisola

final class CodeEditorViewTests: XCTestCase {
    func testLanguageDetectionUsesOnlyTheFileExtension() {
        XCTAssertEqual(CodeEditorLanguage.detect(for: URL(fileURLWithPath: "/tmp/App.swift")), .swift)
        XCTAssertEqual(CodeEditorLanguage.detect(for: URL(fileURLWithPath: "/tmp/view.TSX")), .tsx)
        XCTAssertEqual(CodeEditorLanguage.detect(for: URL(fileURLWithPath: "/tmp/config.yml")), .yaml)
        XCTAssertEqual(CodeEditorLanguage.detect(for: URL(fileURLWithPath: "/tmp/script.zsh")), .shell)
        XCTAssertEqual(CodeEditorLanguage.detect(for: URL(fileURLWithPath: "/tmp/notes.txt")), .plain)
    }

    func testLineSeparatorDetectionPreservesUniformAndMixedSource() {
        XCTAssertEqual(CodeEditorLineSeparator.detect(in: "one\ntwo\n"), .lf)
        XCTAssertEqual(CodeEditorLineSeparator.detect(in: "one\r\ntwo\r\n"), .crlf)
        XCTAssertEqual(CodeEditorLineSeparator.detect(in: "one\rtwo\r"), .cr)
        XCTAssertEqual(CodeEditorLineSeparator.detect(in: "one\r\ntwo\n"), .lf)
        XCTAssertEqual(CodeEditorLineSeparator.detect(in: "one"), .lf)
    }

    func testAssetPolicyAllowsOnlyTheTwoOpaqueBundledResources() throws {
        XCTAssertNotNil(CodeEditorAssetPolicy.resource(
            for: try XCTUnwrap(URL(string: "kaisola-editor://app/index.html"))
        ))
        XCTAssertNotNil(CodeEditorAssetPolicy.resource(
            for: try XCTUnwrap(URL(string: "kaisola-editor://app/editor.bundle.js"))
        ))

        for value in [
            "kaisola-editor://app/../Info.plist",
            "kaisola-editor://app/index.html?path=/tmp/secret",
            "kaisola-editor://other/index.html",
            "file:///tmp/secret",
            "https://example.com/editor.bundle.js",
            "data:text/html,hello",
        ] {
            let url = try XCTUnwrap(URL(string: value), value)
            XCTAssertNil(CodeEditorAssetPolicy.resource(for: url), value)
            XCTAssertFalse(CodeEditorAssetPolicy.allowsNavigation(to: url), value)
        }
    }

    func testUnicodeTransactionAndInversePreserveExactSource() throws {
        let source = "let café = \"👩🏽‍💻\"\r\n"
        let sourceNSString = source as NSString
        let nameRange = sourceNSString.range(of: "café")
        let emojiRange = sourceNSString.range(of: "👩🏽‍💻")
        let changes = [
            CodeEditorSourceChange(from: nameRange.location, to: NSMaxRange(nameRange), insert: "answer"),
            CodeEditorSourceChange(from: emojiRange.location, to: NSMaxRange(emojiRange), insert: "✨"),
        ]

        let mutation = try XCTUnwrap(CodeEditorSourceTransaction.applyAndInvert(changes, to: source))
        XCTAssertEqual(mutation.text, "let answer = \"✨\"\r\n")
        XCTAssertEqual((mutation.text as NSString).length, 18)

        let restored = try XCTUnwrap(CodeEditorSourceTransaction.applyAndInvert(
            mutation.inverse,
            to: mutation.text
        ))
        XCTAssertEqual(restored.text, source)
        XCTAssertEqual(Array(restored.text.utf8), Array(source.utf8))
    }

    func testMultiRangeTransactionUsesPreEditOffsets() throws {
        let source = "alpha beta gamma"
        let mutation = try XCTUnwrap(CodeEditorSourceTransaction.applyAndInvert([
            CodeEditorSourceChange(from: 0, to: 5, insert: "A"),
            CodeEditorSourceChange(from: 11, to: 16, insert: "GAMMA!"),
        ], to: source))
        XCTAssertEqual(mutation.text, "A beta GAMMA!")
        XCTAssertEqual(
            CodeEditorSourceTransaction.applyAndInvert(mutation.inverse, to: mutation.text)?.text,
            source
        )
    }

    func testTransactionRejectsOverlapReorderingAndOutOfBoundsRanges() {
        let source = "abcdef"
        let invalidChanges: [[CodeEditorSourceChange]] = [
            [.init(from: 4, to: 7, insert: "x")],
            [.init(from: -1, to: 1, insert: "x")],
            [.init(from: 3, to: 2, insert: "x")],
            [.init(from: 2, to: 4, insert: "x"), .init(from: 3, to: 5, insert: "y")],
            [.init(from: 4, to: 5, insert: "x"), .init(from: 1, to: 2, insert: "y")],
        ]
        for changes in invalidChanges {
            XCTAssertNil(CodeEditorSourceTransaction.applyAndInvert(changes, to: source))
        }
    }
}
