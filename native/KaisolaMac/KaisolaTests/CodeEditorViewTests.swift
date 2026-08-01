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

    func testLineTargetRevisionMakesRepeatedOutlineSelectionDistinct() {
        let first = FileEditorLineTarget.key(documentID: "/project/App.swift", line: 12, navigationRevision: 1)
        let repeated = FileEditorLineTarget.key(documentID: "/project/App.swift", line: 12, navigationRevision: 2)
        XCTAssertNotEqual(first, repeated)
        XCTAssertEqual(
            first,
            FileEditorLineTarget.key(documentID: "/project/App.swift", line: 12, navigationRevision: 1)
        )
    }

    func testOutlinePreservesCRLFHeadingLinesAndHierarchy() {
        let source = "# Overview\r\nbody\r\n\r\nDetails\r\n-------\r\n### Deep ###\r\n"
        let items = SourceOutline.items(
            in: source,
            fileURL: URL(fileURLWithPath: "/project/README.md")
        )
        XCTAssertEqual(items.map(\.title), ["Overview", "Details", "Deep"])
        XCTAssertEqual(items.map(\.line), [1, 4, 6])
        XCTAssertEqual(items.map(\.depth), [1, 2, 3])
        XCTAssertTrue(items.allSatisfy { $0.kind == .section })
    }

    func testOutlineRecognizesCommonSourceDeclarationsWithoutScalarNoise() {
        let swiftItems = SourceOutline.items(
            in: "private struct Worker {\n    func run() {}\n    let count = 1\n}\n",
            fileURL: URL(fileURLWithPath: "/project/Worker.swift")
        )
        XCTAssertEqual(swiftItems.map(\.title), ["struct Worker", "func run"])
        XCTAssertEqual(swiftItems.map(\.line), [1, 2])
        XCTAssertEqual(swiftItems.map(\.kind), [.type, .function])

        let javascriptItems = SourceOutline.items(
            in: "export class Card {}\nconst render = (value) => value\nconst scalar = 3\n",
            fileURL: URL(fileURLWithPath: "/project/card.ts")
        )
        XCTAssertEqual(javascriptItems.map(\.title), ["class Card", "render"])

        let jsonItems = SourceOutline.items(
            in: "{\n  \"scripts\": {\n    \"test\": \"npm test\"\n  },\n  \"files\": [\n  ]\n}\n",
            fileURL: URL(fileURLWithPath: "/project/package.json")
        )
        XCTAssertEqual(jsonItems.map(\.title), ["scripts", "files"])
    }

    func testOutlineIsBoundedForGeneratedSources() {
        let source = (0..<500).map { "func generated\($0)() {}" }.joined(separator: "\n")
        let items = SourceOutline.items(
            in: source,
            fileURL: URL(fileURLWithPath: "/project/Generated.swift")
        )
        XCTAssertEqual(items.count, SourceOutline.maximumItems)
        XCTAssertEqual(items.first?.line, 1)
        XCTAssertEqual(items.last?.line, SourceOutline.maximumItems)
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
