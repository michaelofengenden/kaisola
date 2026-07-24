import Foundation
import XCTest
@testable import KaisolaMacPreview

/// ProjectFiles (tree listing + bounded enumeration) and FilePreviewContent
/// (what a file renders as) — the workspace rail's foundations.
final class WorkspaceFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-ws-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/dep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "swift".write(to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try "junk".write(to: root.appendingPathComponent("node_modules/dep/index.js"), atomically: true, encoding: .utf8)
        try ".hidden".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testChildrenSkipsIgnoredAndHiddenAndSortsDirsFirst() {
        let children = ProjectFiles.children(of: root)
        XCTAssertEqual(children.map(\.name), ["src", "README.md"])
        XCTAssertTrue(children[0].isDirectory)
    }

    func testEnumerateReturnsRelativePathsExcludingIgnored() {
        let files = ProjectFiles.enumerate(root: root)
        XCTAssertEqual(Set(files), ["README.md", "src/main.swift"])
    }

    func testEnumerateHonorsTheLimit() throws {
        for index in 0..<20 {
            try "x".write(to: root.appendingPathComponent("file\(index).txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(ProjectFiles.enumerate(root: root, limit: 5).count, 5)
    }

    func testPreviewContentClassifiesFiles() throws {
        XCTAssertEqual(FilePreviewContent.load(url: root.appendingPathComponent("README.md")), .markdown("hello"))
        XCTAssertEqual(FilePreviewContent.load(url: root.appendingPathComponent("src/main.swift")), .text("swift"))

        let html = root.appendingPathComponent("preview.html")
        try "<h1>Hello</h1>".write(to: html, atomically: true, encoding: .utf8)
        XCTAssertEqual(FilePreviewContent.load(url: html), .html("<h1>Hello</h1>"))

        let binary = root.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x81]).write(to: binary)
        XCTAssertEqual(FilePreviewContent.load(url: binary), .binary)

        let image = root.appendingPathComponent("pic.png")
        try Data([0x89, 0x50]).write(to: image)
        XCTAssertEqual(FilePreviewContent.load(url: image), .image)

        XCTAssertEqual(FilePreviewContent.load(url: root.appendingPathComponent("missing.txt")), .unreadable)
    }

    func testDocxClassificationAndRichTextRoundTrip() throws {
        let file = root.appendingPathComponent("notes.docx")
        let source = NSAttributedString(string: "Editable native document")
        try RichDocumentIO.write(source, to: file)

        XCTAssertEqual(FilePreviewContent.load(url: file), .docx)
        XCTAssertEqual(
            RichDocumentIO.load(url: file)?.value.string.trimmingCharacters(in: .newlines),
            source.string
        )
    }

    func testOversizedFileReportsTooLarge() throws {
        let big = root.appendingPathComponent("big.txt")
        let bytes = FilePreviewContent.maxTextBytes + 1
        try Data(repeating: 0x61, count: bytes).write(to: big)
        XCTAssertEqual(FilePreviewContent.load(url: big), .tooLarge(bytes))
    }

    func testPreviewDetectsAnExternalEditBeforeSaving() throws {
        let file = root.appendingPathComponent("external-edit.txt")
        try "first".write(to: file, atomically: true, encoding: .utf8)
        let openedAt = FilePreviewDiskState.modificationDate(of: file)
        XCTAssertFalse(FilePreviewDiskState.changed(onDisk: file, since: openedAt))

        try "agent edit".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: file.path
        )
        XCTAssertTrue(FilePreviewDiskState.changed(onDisk: file, since: openedAt))
    }

    func testMarkdownRenderFallsBackToPlainText() {
        // Even degenerate input must yield a string, never a blank preview.
        let rendered = FilePreviewView.renderMarkdown("plain **bold** text")
        XCTAssertFalse(String(rendered.characters).isEmpty)
    }

    func testMarkdownDocumentPreservesBlockStructure() {
        let document = MarkdownDocument.parse("""
        # Heading

        Paragraph with **bold** text.

        - first
        1. second

        > quoted

        ```swift
        let answer = 42
        ```

        | Name | Value |
        | --- | --- |
        | alpha | 1 |
        """)

        XCTAssertTrue(document.blocks.contains(.heading(level: 1, text: "Heading")))
        XCTAssertTrue(document.blocks.contains(.listItem(indent: 0, marker: "•", text: "first")))
        XCTAssertTrue(document.blocks.contains(.listItem(indent: 0, marker: "1.", text: "second")))
        XCTAssertTrue(document.blocks.contains(.quote("quoted")))
        XCTAssertTrue(document.blocks.contains(.code(language: "swift", text: "let answer = 42")))
        XCTAssertTrue(document.blocks.contains(.table(headers: ["Name", "Value"], rows: [["alpha", "1"]])))
    }

    func testMarkdownDocumentTranslatesCommonReadmeHTMLWithoutShowingTags() {
        let document = MarkdownDocument.parse("""
        <p align="center">
          <img src="icon.png" alt="Kaisola icon" />
        </p>

        <h1 align="center">Kaisola</h1>

        <p align="center">
          <strong>Your agents. One workspace.</strong><br />
          <a href="https://kaisola.com">Website</a> · Docs
        </p>
        """)

        XCTAssertEqual(document.blocks.first, .heading(level: 1, text: "Kaisola"))
        XCTAssertTrue(document.blocks.contains(.paragraph(
            "**Your agents. One workspace.** [Website](https://kaisola.com) · Docs"
        )))
        XCTAssertFalse(document.blocks.contains { block in String(describing: block).contains("<") })
    }

    func testDirectorySymlinkIsNotRecursivelyIndexed() throws {
        let loop = root.appendingPathComponent("loop", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: root)
        XCTAssertFalse(ProjectFiles.children(of: root).contains { $0.name == "loop" })
        XCTAssertEqual(Set(ProjectFiles.enumerate(root: root)), ["README.md", "src/main.swift"])
    }
}
