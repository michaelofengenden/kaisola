import AppKit
import XCTest
@testable import Kaisola

/// Pure routing test for the terminal `file:` OSC 8 link parser
/// (`NativeTerminalSurface.Coordinator.parseFileLink`): a bare file URL carries
/// no line, a trailing `:LINE` (literal or percent-encoded `%3A`) becomes an
/// `Int` line, and directory / non-numeric-colon URLs pass through untouched.
final class TerminalLinkRoutingTests: XCTestCase {
    private func parse(_ string: String) throws -> (path: String, line: Int?) {
        let url = try XCTUnwrap(URL(string: string))
        return NativeTerminalSurface.Coordinator.parseFileLink(url)
    }

    func testPlainFileURLHasNoLine() throws {
        let result = try parse("file:///a/b.swift")
        XCTAssertEqual(result.path, "/a/b.swift")
        XCTAssertNil(result.line)
    }

    func testPercentEncodedColonYieldsLine() throws {
        // The colon in `path:line` frequently arrives percent-encoded as %3A.
        let result = try parse("file:///a/b.swift%3A42")
        XCTAssertEqual(result.path, "/a/b.swift")
        XCTAssertEqual(result.line, 42)
    }

    func testLiteralColonSuffixYieldsLine() throws {
        let result = try parse("file:///a/b.swift:42")
        XCTAssertEqual(result.path, "/a/b.swift")
        XCTAssertEqual(result.line, 42)
    }

    func testDeepPathWithLine() throws {
        let result = try parse("file:///Users/x/Developer/app/src/main.swift%3A128")
        XCTAssertEqual(result.path, "/Users/x/Developer/app/src/main.swift")
        XCTAssertEqual(result.line, 128)
    }

    func testFileURLWithLineAndColumnNavigatesToLine() throws {
        let result = try parse("file:///Users/x/Developer/app/src/main.swift%3A128%3A17")
        XCTAssertEqual(result.path, "/Users/x/Developer/app/src/main.swift")
        XCTAssertEqual(result.line, 128)
    }

    func testFileURLFragmentNavigatesToLine() throws {
        let result = try parse("file:///Users/x/Developer/app/src/main.swift#L33")
        XCTAssertEqual(result.path, "/Users/x/Developer/app/src/main.swift")
        XCTAssertEqual(result.line, 33)
    }

    func testDirectoryURLUntouched() throws {
        // A directory has no line citation: the line is nil and no `:` was
        // split out of the path (asserted robustly to tolerate whether
        // `URL.path` keeps the trailing separator).
        let result = try parse("file:///a/b/")
        XCTAssertNil(result.line)
        XCTAssertFalse(result.path.contains(":"))
        XCTAssertTrue(result.path.hasPrefix("/a/b"))
    }

    func testNonNumericColonKeptInPath() throws {
        // A colon that is not followed by digits is part of the path, not a
        // citation — the parser must not split on it.
        let result = try parse("file:///a/notes:draft")
        XCTAssertEqual(result.path, "/a/notes:draft")
        XCTAssertNil(result.line)
    }

    func testTrailingColonWithoutDigitsKeptInPath() throws {
        let result = try parse("file:///a/b.swift:")
        XCTAssertEqual(result.path, "/a/b.swift:")
        XCTAssertNil(result.line)
    }

    func testRelativeAgentCitationResolvesAgainstWorkingDirectory() throws {
        let root = URL(fileURLWithPath: "/Users/x/Developer/app", isDirectory: true)
        let target = try XCTUnwrap(NativeTerminalSurface.Coordinator.linkTarget(
            for: "Sources/Feature/Panel.swift:82:14",
            workingDirectory: root
        ))
        guard case .file(let url, let line) = target else {
            return XCTFail("Expected a file target")
        }
        XCTAssertEqual(url.path, "/Users/x/Developer/app/Sources/Feature/Panel.swift")
        XCTAssertEqual(line, 82)
    }

    func testRelativeCitationDropsTrailingProseSemicolon() throws {
        let root = URL(fileURLWithPath: "/Users/x/Developer/MATSMichael", isDirectory: true)
        let target = try XCTUnwrap(NativeTerminalSurface.Coordinator.linkTarget(
            for: "durationbench/pilot/JUDGE_SCORING_STATUS_20260727.md;",
            workingDirectory: root
        ))
        guard case .file(let url, let line) = target else {
            return XCTFail("Expected a file target")
        }
        XCTAssertEqual(
            url.path,
            "/Users/x/Developer/MATSMichael/durationbench/pilot/JUDGE_SCORING_STATUS_20260727.md"
        )
        XCTAssertNil(line)
    }

    func testPunctuatedJudgeStatusCitationLoadsTheRealMarkdownFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-terminal-link-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("durationbench/pilot", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent("JUDGE_SCORING_STATUS_20260727.md")
        let markdown = "# Judge scoring status\n\nReadable from the terminal citation.\n"
        try Data(markdown.utf8).write(to: file, options: .atomic)

        let target = try XCTUnwrap(NativeTerminalSurface.Coordinator.linkTarget(
            for: "durationbench/pilot/JUDGE_SCORING_STATUS_20260727.md;",
            workingDirectory: root
        ))
        guard case .file(let url, let line) = target else {
            return XCTFail("Expected a file target")
        }
        XCTAssertEqual(url.standardizedFileURL, file.standardizedFileURL)
        XCTAssertNil(line)
        guard case .markdown(let loaded) = FilePreviewContent.load(url: url) else {
            return XCTFail("Expected readable Markdown, not the unreadable placeholder")
        }
        XCTAssertEqual(loaded, markdown)
    }

    func testLineCitationDropsTrailingProseComma() throws {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let target = try XCTUnwrap(NativeTerminalSurface.Coordinator.linkTarget(
            for: "Sources/App.swift:42,",
            workingDirectory: root
        ))
        guard case .file(let url, let line) = target else {
            return XCTFail("Expected a file target")
        }
        XCTAssertEqual(url.path, "/tmp/project/Sources/App.swift")
        XCTAssertEqual(line, 42)
    }

    func testAbsoluteAgentCitationNeedsNoWorkingDirectory() throws {
        let target = try XCTUnwrap(NativeTerminalSurface.Coordinator.linkTarget(
            for: "/tmp/project/Test.swift:19",
            workingDirectory: nil
        ))
        guard case .file(let url, let line) = target else {
            return XCTFail("Expected a file target")
        }
        XCTAssertEqual(url.path, "/tmp/project/Test.swift")
        XCTAssertEqual(line, 19)
    }

    func testRelativeCitationWithoutDirectoryFailsClosed() {
        XCTAssertNil(NativeTerminalSurface.Coordinator.linkTarget(
            for: "Sources/Feature/Panel.swift:82",
            workingDirectory: nil
        ))
    }

    func testWebLinkRemainsAWebTarget() throws {
        let target = try XCTUnwrap(NativeTerminalSurface.Coordinator.linkTarget(
            for: "https://github.com/openai/codex/issues/123?tab=details#note",
            workingDirectory: URL(fileURLWithPath: "/tmp")
        ))
        guard case .web(let url) = target else {
            return XCTFail("Expected a web target")
        }
        XCTAssertEqual(url.absoluteString, "https://github.com/openai/codex/issues/123?tab=details#note")
    }

    func testOSCWorkingDirectoryAcceptsFileURLAndAbsolutePath() throws {
        XCTAssertEqual(
            NativeTerminalSurface.Coordinator.parseWorkingDirectory("file://localhost/Users/x/Developer/app")?.path,
            "/Users/x/Developer/app"
        )
        XCTAssertEqual(
            NativeTerminalSurface.Coordinator.parseWorkingDirectory("/tmp/project")?.path,
            "/tmp/project"
        )
        XCTAssertNil(NativeTerminalSurface.Coordinator.parseWorkingDirectory("relative/project"))
    }

    @MainActor
    func testOSCWorkingDirectorySurvivesOrdinarySurfaceUpdates() {
        let base = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let coordinator = NativeTerminalSurface.Coordinator()
        coordinator.setBaseWorkingDirectory(base)
        let view = ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        coordinator.hostCurrentDirectoryUpdate(
            source: view,
            directory: "file://localhost/tmp/project/Sources"
        )
        coordinator.setBaseWorkingDirectory(base)

        XCTAssertEqual(coordinator.workingDirectory?.path, "/tmp/project/Sources")
    }
}
