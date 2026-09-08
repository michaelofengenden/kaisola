import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Kaisola

/// Pure routing test for the terminal `file:` OSC 8 link parser
/// (`NativeTerminalSurface.Coordinator.parseFileLink`): a bare file URL carries
/// no line, a trailing `:LINE` (literal or percent-encoded `%3A`) becomes an
/// `Int` line, and directory / non-numeric-colon URLs pass through untouched.
final class TerminalLinkRoutingTests: XCTestCase {
    private struct TranscriptLinkTrigger: View {
        let link: URL
        @Environment(\.openURL) private var openURL

        var body: some View {
            Text("Mounted transcript link")
                .onAppear {
                    DispatchQueue.main.async { openURL(link) }
                }
        }
    }

    @MainActor
    func testScopedLinkReachesOnlyItsSourceWindow() {
        let source = NSWindow()
        let other = NSWindow()
        let notification = Notification(
            name: .kaisolaOpenFileLink,
            userInfo: [TerminalLinkNotificationRouting.sourceWindowKey: source]
        )
        XCTAssertTrue(TerminalLinkNotificationRouting.shouldHandle(notification, receivingWindow: source))
        XCTAssertFalse(TerminalLinkNotificationRouting.shouldHandle(notification, receivingWindow: other))
        XCTAssertFalse(TerminalLinkNotificationRouting.shouldHandle(notification, receivingWindow: nil))
    }

    @MainActor
    func testLegacyUnscopedLinkNotificationsKeepTheirRouting() {
        let notification = Notification(
            name: .kaisolaOpenFileLink,
            userInfo: ["url": URL(fileURLWithPath: "/tmp/example.swift")]
        )
        XCTAssertTrue(TerminalLinkNotificationRouting.shouldHandle(notification, receivingWindow: NSWindow()))
    }

    @MainActor
    func testTranscriptFileLinkPublishesItsSourceWindowAndRoutesOnlyThere() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-transcript-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("Example.swift")
        try Data("// fixture".utf8).write(to: file)
        let source = NSWindow()
        let other = NSWindow()
        var received: Notification?
        let observation = NotificationCenter.default.publisher(for: .kaisolaOpenFileLink).sink { received = $0 }
        defer { observation.cancel() }

        var components = URLComponents(url: file, resolvingAgainstBaseURL: false)
        components?.fragment = "L9"
        let citedFile = try XCTUnwrap(components?.url)
        AcpTranscriptLinkRouting.open(
            citedFile,
            workspaceURL: workspace,
            sourceWindow: source
        )

        let notification = try XCTUnwrap(received)
        XCTAssertTrue(notification.userInfo?[TerminalLinkNotificationRouting.sourceWindowKey] as? NSWindow === source)
        XCTAssertEqual(notification.userInfo?["url"] as? URL, file)
        XCTAssertEqual(notification.userInfo?["line"] as? Int, 9)
        XCTAssertTrue(TerminalLinkNotificationRouting.shouldHandle(notification, receivingWindow: source))
        XCTAssertFalse(TerminalLinkNotificationRouting.shouldHandle(notification, receivingWindow: other))
    }

    @MainActor
    func testDetachedTranscriptFileLinkIsDiscardedWithoutPublishingNavigation() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-detached-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("Example.swift")
        try Data("// fixture".utf8).write(to: file)
        var received: Notification?
        let observation = NotificationCenter.default.publisher(for: .kaisolaOpenFileLink).sink { received = $0 }
        defer { observation.cancel() }

        AcpTranscriptLinkRouting.open(
            file,
            workspaceURL: workspace,
            sourceWindow: nil
        )

        XCTAssertNil(received)
    }

    @MainActor
    func testMarkdownEditorLinkCallbackCarriesOwningWindow() throws {
        let source = NSWindow()
        let textView = MarkdownNativeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        textView.string = "[Example](Example.swift)"
        source.contentView = textView
        let coordinator = MarkdownRenderedEditor.Coordinator(
            text: .constant(textView.string),
            zoom: .constant(1)
        )
        coordinator.textView = textView
        var callbackWindow: NSWindow?
        coordinator.onOpenLink = { _, window in callbackWindow = window }

        coordinator.followLink(at: 2)

        XCTAssertTrue(callbackWindow === source)
    }

    @MainActor
    func testHostedTranscriptLinkEnvironmentCapturesOwningWindow() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-hosted-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("Hosted.swift")
        try Data("// fixture".utf8).write(to: file)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: TranscriptLinkTrigger(link: file)
                .acpTranscriptLinkRouting(workspaceURL: workspace)
        )
        var received: Notification?
        let observation = NotificationCenter.default.publisher(for: .kaisolaOpenFileLink).sink { received = $0 }
        defer {
            observation.cancel()
            window.close()
        }

        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let notification = try XCTUnwrap(received)
        XCTAssertTrue(notification.userInfo?[TerminalLinkNotificationRouting.sourceWindowKey] as? NSWindow === window)
    }

    @MainActor
    func testTerminalFileLinkPublishesSourceWindowAndPreservesLocation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kaisola-link-\(UUID().uuidString).swift")
        try Data("// fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = NSWindow()
        let terminal = ReadOnlyTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        source.contentView = terminal
        var received: Notification?
        let observation = NotificationCenter.default.publisher(for: .kaisolaOpenFileLink).sink { received = $0 }
        defer { observation.cancel() }
        NativeTerminalSurface.Coordinator().requestOpenLink(
            source: terminal,
            link: file.absoluteString + "#L7",
            params: [:]
        )
        let notification = try XCTUnwrap(received)
        XCTAssertTrue(notification.userInfo?[TerminalLinkNotificationRouting.sourceWindowKey] as? NSWindow === source)
        XCTAssertEqual(notification.userInfo?["url"] as? URL, file)
        XCTAssertEqual(notification.userInfo?["line"] as? Int, 7)
    }

    @MainActor
    func testTerminalLocalhostLinkPublishesSourceWindowAndPreservesURL() throws {
        let source = NSWindow()
        let terminal = ReadOnlyTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        source.contentView = terminal
        var received: Notification?
        let observation = NotificationCenter.default.publisher(for: .kaisolaOpenBrowserCard).sink { received = $0 }
        defer { observation.cancel() }
        let url = try XCTUnwrap(URL(string: "http://localhost:5173/path?preview=1"))
        NativeTerminalSurface.Coordinator().requestOpenLink(source: terminal, link: url.absoluteString, params: [:])
        let notification = try XCTUnwrap(received)
        XCTAssertTrue(notification.userInfo?[TerminalLinkNotificationRouting.sourceWindowKey] as? NSWindow === source)
        XCTAssertEqual(notification.object as? URL, url)
    }

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
