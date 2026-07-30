import XCTest
@testable import Kaisola

/// Dropping a screenshot on a terminal running Claude Code must actually attach
/// the image. Verified CLI behaviour this encodes:
///
/// - a bare or shell-quoted path attaches nothing — it is inert text;
/// - `@<path>` attaches, but is whitespace-delimited, so any space breaks it;
/// - backslash-escaping the space does not rescue it: the CLI proceeds and
///   describes an image it never received, which is worse than an error.
///
/// macOS names every screenshot with spaces, so sanitising the staged filename
/// (never escaping) is the load-bearing behaviour here.
final class TerminalImageDropTests: XCTestCase {
    private func screenshot(_ name: String = "Screenshot 2026-07-27 at 9.13.45 PM.png") -> URL {
        URL(fileURLWithPath: "/Users/m/Desktop/\(name)")
    }

    // MARK: - Staged names

    func testStagedNameStripsSpacesFromRealScreenshotNames() {
        let name = TerminalImageDrop.stagedName(
            for: screenshot(),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertFalse(name.contains(" "), "A space silently breaks Claude's @ mention.")
        XCTAssertTrue(name.hasPrefix("screenshot-2026-07-27-at-9-13-45-pm-"))
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    func testStagedNameRejectsEveryCharacterThatBreaksMentions() {
        let hostile = screenshot("we(ird) na<me> \"quoted\" 'x'.PNG")
        let name = TerminalImageDrop.stagedName(for: hostile, now: Date())
        for character in " ()<>\"'" {
            XCTAssertFalse(name.contains(character), "\(character) must not survive sanitising")
        }
    }

    func testStagedNameCollapsesRunsAndTrimsEdges() {
        let name = TerminalImageDrop.stagedName(
            for: URL(fileURLWithPath: "/x/---a   b---.png"),
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(name.hasPrefix("a-b-"), "got \(name)")
    }

    func testStagedNameSurvivesAFullyUnusableBaseName() {
        let name = TerminalImageDrop.stagedName(for: URL(fileURLWithPath: "/x/;;;.png"), now: Date())
        XCTAssertTrue(name.hasPrefix("image-"))
    }

    func testStagedNameNormalisesAnUnknownExtension() {
        // The staged copy must still look like an image to the CLI.
        let name = TerminalImageDrop.stagedName(for: URL(fileURLWithPath: "/x/shot.bmp"), now: Date())
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    // MARK: - Insertion text

    func testClaudeGetsAMentionOfTheStagedPath() {
        let staged = URL(fileURLWithPath: "/staged/screenshot-123.png")
        let text = TerminalImageDrop.insertionText(
            for: [screenshot()],
            syntax: .claudeMention,
            stage: { _ in staged }
        )
        XCTAssertEqual(text, "@/staged/screenshot-123.png ")
        XCTAssertFalse(text.contains("'"), "A quoted path attaches nothing to Claude.")
    }

    func testCodexKeepsTheQuotedPathBecauseClipboardAttachmentHasNoTextSyntax() {
        // Codex handles clipboard pixels through Control-V, not an inline path
        // token; dropped file paths therefore remain usable shell text.
        let text = TerminalImageDrop.insertionText(
            for: [screenshot()],
            syntax: .pathOnly,
            stage: { _ in XCTFail("Codex drops must not stage"); return nil }
        )
        XCTAssertEqual(text, "'/Users/m/Desktop/Screenshot 2026-07-27 at 9.13.45 PM.png' ")
    }

    func testPlainShellKeepsTheQuotedPath() {
        // `@path` would be a syntax error in a shell, so a non-agent pane must
        // keep receiving something it can actually use with cp/open.
        let text = TerminalImageDrop.insertionText(
            for: [URL(fileURLWithPath: "/tmp/a b.png")],
            syntax: .pathOnly,
            stage: { _ in nil }
        )
        XCTAssertEqual(text, "'/tmp/a b.png' ")
    }

    func testNonImagesAreNeverMentionedEvenForClaude() {
        let text = TerminalImageDrop.insertionText(
            for: [URL(fileURLWithPath: "/tmp/notes.txt")],
            syntax: .claudeMention,
            stage: { _ in XCTFail("Only images stage"); return nil }
        )
        XCTAssertEqual(text, "'/tmp/notes.txt' ")
    }

    func testFailedStagingFallsBackToAPathRatherThanADeadMention() {
        // A mention pointing at a space-bearing path would silently attach
        // nothing; a quoted path at least remains usable.
        let text = TerminalImageDrop.insertionText(
            for: [screenshot()],
            syntax: .claudeMention,
            stage: { _ in nil }
        )
        XCTAssertTrue(text.hasPrefix("'"), "got \(text)")
    }

    func testMixedDropMentionsOnlyTheImage() {
        let staged = URL(fileURLWithPath: "/staged/shot-1.png")
        let text = TerminalImageDrop.insertionText(
            for: [screenshot(), URL(fileURLWithPath: "/tmp/log.txt")],
            syntax: .claudeMention,
            stage: { _ in staged }
        )
        XCTAssertEqual(text, "@/staged/shot-1.png '/tmp/log.txt' ")
    }

    func testEmptyDropProducesNothing() {
        XCTAssertEqual(TerminalImageDrop.insertionText(for: [], syntax: .claudeMention), "")
    }

    // MARK: - Agent syntax selection

    func testSyntaxSelection() {
        XCTAssertEqual(TerminalImageDrop.syntax(forLaunchCommand: "claude"), .claudeMention)
        XCTAssertEqual(TerminalImageDrop.syntax(forLaunchCommand: "codex"), .pathOnly)
        XCTAssertEqual(TerminalImageDrop.syntax(forLaunchCommand: nil), .pathOnly)
        XCTAssertEqual(TerminalImageDrop.syntax(forLaunchCommand: "zsh"), .pathOnly)
    }

    func testImageDetectionIsCaseInsensitive() {
        XCTAssertTrue(TerminalImageDrop.isImage(URL(fileURLWithPath: "/x/a.PNG")))
        XCTAssertTrue(TerminalImageDrop.isImage(URL(fileURLWithPath: "/x/a.jpeg")))
        XCTAssertFalse(TerminalImageDrop.isImage(URL(fileURLWithPath: "/x/a.pdf")))
    }

    // MARK: - Staging and inline echo

    func testStagingCopiesAndRefusesOversizedFiles() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let small = directory.appendingPathComponent("a b.png")
        try Data(repeating: 0x41, count: 64).write(to: small)
        let staged = try XCTUnwrap(TerminalImageDrop.stageImage(small))
        XCTAssertFalse(staged.lastPathComponent.contains(" "))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        try? FileManager.default.removeItem(at: staged)

        let huge = directory.appendingPathComponent("huge.png")
        try Data(count: TerminalImageDrop.maximumImageBytes + 1).write(to: huge)
        XCTAssertNil(TerminalImageDrop.stageImage(huge), "Oversized images must not stage")

        XCTAssertNil(TerminalImageDrop.stageImage(directory.appendingPathComponent("missing.png")))
    }

}
