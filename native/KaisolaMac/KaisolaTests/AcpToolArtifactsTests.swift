import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

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

    func testTerminalReferenceParsesToLiveTerminalContent() {
        let value = JSONValue.array([
            .object(["type": .string("terminal"), "terminalId": .string("term-9")]),
        ])
        let content = AcpClient.parseToolContent(value)
        XCTAssertEqual(content, [.terminal(id: "term-9")])
    }

    func testNilOrEmptyContentYieldsNoArtifacts() {
        XCTAssertTrue(AcpClient.parseToolContent(nil).isEmpty)
        XCTAssertTrue(AcpClient.parseToolContent(.array([])).isEmpty)
    }

    func testPermissionWireParserKeepsRawInputAndEveryDeclaredPath() throws {
        let rawInput = JSONValue.object([
            "command": .string("swift test"),
            "cwd": .string("/work/project"),
        ])
        let params = JSONValue.object([
            "toolCall": .object([
                "toolCallId": .string("tool-1"),
                "title": .string("Run tests"),
                "kind": .string("execute"),
                "rawInput": rawInput,
                "locations": .array([
                    .object(["path": .string("/work/project/Package.swift")]),
                    .object(["path": .string("/work/project/Package.swift")]),
                    .object(["path": .string("/work/project/Tests/Odd\nName.swift")]),
                ]),
                "content": .array([
                    .object([
                        "type": .string("diff"),
                        "path": .string("/work/project/Sources/App.swift"),
                        "oldText": .string("old"),
                        "newText": .string("new"),
                    ]),
                ]),
            ]),
            "options": .array([
                .object([
                    "optionId": .string("allow"),
                    "name": .string("Proceed once"),
                    "kind": .string("allow_once"),
                ]),
                .object([
                    "optionId": .string("extension"),
                    "name": .string("Adapter extension"),
                ]),
            ]),
        ])

        let request = try XCTUnwrap(AcpClient.parsePermissionRequest(
            localID: 42,
            sessionID: "session-1",
            params: params
        ))

        XCTAssertEqual(request.id, 42)
        XCTAssertEqual(request.sessionID, "session-1")
        XCTAssertEqual(request.rawInput, rawInput)
        XCTAssertEqual(request.kind, "execute")
        XCTAssertEqual(request.paths, [
            "/work/project/Package.swift",
            "/work/project/Tests/Odd\nName.swift",
            "/work/project/Sources/App.swift",
        ])
        XCTAssertEqual(request.options.map(\.kind), ["allow_once", "other"])
    }

    func testPartialPermissionRequestMergesPriorToolCallDisclosure() throws {
        let rawInput = JSONValue.object(["operation": .string("replace")])
        let initial = AcpClient.mergeToolCallReviewContext(nil, update: [
            "toolCallId": .string("file-change-1"),
            "title": .string("Editing files"),
            "kind": .string("edit"),
            "rawInput": rawInput,
            "locations": .array([
                .object(["path": .string("/work/Sources/App.swift")]),
            ]),
            "content": .array([
                .object([
                    "type": .string("diff"),
                    "path": .string("/work/Sources/App.swift"),
                    "oldText": .string("old"),
                    "newText": .string("new"),
                ]),
                .object([
                    "type": .string("diff"),
                    "path": .string("/work/Tests/AppTests.swift"),
                    // Path disclosure must survive even if artifact rendering
                    // cannot parse an incomplete diff body.
                ]),
            ]),
        ])
        let updated = AcpClient.mergeToolCallReviewContext(initial, update: [
            "toolCallId": .string("file-change-1"),
            "status": .string("pending"),
        ])
        let params = JSONValue.object([
            "toolCall": .object([
                "toolCallId": .string("file-change-1"),
                "status": .string("pending"),
            ]),
            "options": .array([
                .object([
                    "optionId": .string("allow"),
                    "name": .string("Allow once"),
                    "kind": .string("allow_once"),
                ]),
                .object([
                    "optionId": .string("deny"),
                    "name": .string("Reject"),
                    "kind": .string("reject_once"),
                ]),
            ]),
        ])

        let request = try XCTUnwrap(AcpClient.parsePermissionRequest(
            localID: 9,
            sessionID: "session",
            params: params,
            priorContext: updated
        ))

        XCTAssertEqual(request.title, "Editing files")
        XCTAssertEqual(request.kind, "edit")
        XCTAssertEqual(request.rawInput, rawInput)
        XCTAssertEqual(request.paths, [
            "/work/Sources/App.swift",
            "/work/Tests/AppTests.swift",
        ])
    }

    func testPresentToolCallFieldsReplaceCachedDisclosureCollections() {
        let prior = AcpToolCallReviewContext(
            title: "Old title",
            kind: "edit",
            rawInput: .string("old"),
            locationPaths: ["/old/location"],
            diffPaths: ["/old/diff"]
        )

        let replaced = AcpClient.mergeToolCallReviewContext(prior, update: [
            "toolCallId": .string("tool"),
            "rawInput": .null,
            "locations": .array([]),
            "content": .array([
                .object(["type": .string("diff"), "path": .string("/new/diff")]),
            ]),
        ])

        XCTAssertEqual(replaced.title, "Old title")
        XCTAssertEqual(replaced.kind, "edit")
        XCTAssertNil(replaced.rawInput)
        XCTAssertTrue(replaced.locationPaths.isEmpty)
        XCTAssertEqual(replaced.diffPaths, ["/new/diff"])
    }

    // MARK: - Workspace confinement (symlink resolution)

    func testNearestExistingAncestorResolvesSymlinksForUncreatedPaths() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-sym-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let workspace = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // workspace/link → outside. A write target under the link must resolve
        // to the OUTSIDE real path even though the file doesn't exist yet.
        let link = workspace.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escape = link.appendingPathComponent("new-dir/secret.txt").path
        let real = AcpClient.realPathViaNearestExistingAncestor(escape)
        let realOutside = outside.resolvingSymlinksInPath().path
        XCTAssertTrue(real.hasPrefix(realOutside + "/"),
                      "resolution must surface the symlink's real target: \(real)")
        let realWorkspace = workspace.resolvingSymlinksInPath().path
        XCTAssertFalse(real.hasPrefix(realWorkspace + "/"),
                       "the escape must not still look workspace-contained")
    }

    func testNearestExistingAncestorKeepsHonestPathsInPlace() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-honest-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = workspace.appendingPathComponent("sub/new.txt").path
        let real = AcpClient.realPathViaNearestExistingAncestor(target)
        XCTAssertTrue(real.hasPrefix(workspace.resolvingSymlinksInPath().path + "/"))
        XCTAssertTrue(real.hasSuffix("/sub/new.txt"))
    }
}
