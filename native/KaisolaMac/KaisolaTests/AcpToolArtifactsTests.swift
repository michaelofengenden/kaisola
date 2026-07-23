import Foundation
import KaisolaCore
import XCTest
@testable import KaisolaMacPreview

/// The rich tool-artifact path: AcpDiff line diffing and AcpClient's ToolCallContent
/// parsing (diff / content / terminal), which feed the chat's inline diff cards.
final class AcpToolArtifactsTests: XCTestCase {

    // MARK: - AcpDiff

    func testFreshFileIsAllAdditions() {
        let lines = AcpDiff.lines(old: "", new: "alpha\nbeta\n")
        XCTAssertEqual(lines.map(\.kind), [.added, .added])
        XCTAssertEqual(lines.map(\.text), ["alpha", "beta"])
    }

    func testDeletedFileIsAllRemovals() {
        let lines = AcpDiff.lines(old: "gone\n", new: "")
        XCTAssertEqual(lines.map(\.kind), [.removed])
    }

    func testSingleLineChangeKeepsContext() {
        let old = "one\ntwo\nthree\n"
        let new = "one\nTWO\nthree\n"
        let lines = AcpDiff.lines(old: old, new: new)
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(lines.first(where: { $0.kind == .removed })?.text, "two")
        XCTAssertEqual(lines.first(where: { $0.kind == .added })?.text, "TWO")
    }

    func testInsertionInMiddle() {
        let lines = AcpDiff.lines(old: "a\nc\n", new: "a\nb\nc\n")
        XCTAssertEqual(lines.map(\.kind), [.context, .added, .context])
        XCTAssertEqual(lines.first(where: { $0.kind == .added })?.text, "b")
    }

    func testIdenticalTextIsAllContext() {
        let lines = AcpDiff.lines(old: "same\nlines\n", new: "same\nlines\n")
        XCTAssertEqual(lines.map(\.kind), [.context, .context])
    }

    func testLinePrefixes() {
        XCTAssertEqual(AcpDiff.LineKind.context.prefix, "  ")
        XCTAssertEqual(AcpDiff.LineKind.removed.prefix, "- ")
        XCTAssertEqual(AcpDiff.LineKind.added.prefix, "+ ")
    }

    // MARK: - Tool content parsing

    func testParsesDiffContent() {
        let value = JSONValue.array([
            .object([
                "type": .string("diff"),
                "path": .string("/src/app.ts"),
                "oldText": .string("old"),
                "newText": .string("new"),
            ]),
        ])
        let content = AcpClient.parseToolContent(value)
        XCTAssertEqual(content.count, 1)
        guard case let .diff(path, oldText, newText) = content[0] else {
            return XCTFail("expected diff")
        }
        XCTAssertEqual(path, "/src/app.ts")
        XCTAssertEqual(oldText, "old")
        XCTAssertEqual(newText, "new")
    }

    func testParsesTextContentBlock() {
        let value = JSONValue.array([
            .object([
                "type": .string("content"),
                "content": .object(["type": .string("text"), "text": .string("output line")]),
            ]),
        ])
        let content = AcpClient.parseToolContent(value)
        XCTAssertEqual(content, [.text("output line")])
    }

    func testTerminalReferenceDegradesToText() {
        let value = JSONValue.array([
            .object(["type": .string("terminal"), "terminalId": .string("term-9")]),
        ])
        let content = AcpClient.parseToolContent(value)
        XCTAssertEqual(content, [.text("[terminal term-9]")])
    }

    func testNilOrEmptyContentYieldsNoArtifacts() {
        XCTAssertTrue(AcpClient.parseToolContent(nil).isEmpty)
        XCTAssertTrue(AcpClient.parseToolContent(.array([])).isEmpty)
    }
}
