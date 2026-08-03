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

    func testFailedClaudeAttachmentCarriesVisibleFallbackWarning() {
        let plan = TerminalImageDrop.insertionPlan(
            for: [screenshot()],
            syntax: .claudeMention,
            stage: { _ in nil }
        )

        XCTAssertEqual(plan.unattachedClaudeImageCount, 1)
        XCTAssertEqual(
            plan.warningMessage,
            "Image wasn’t attached to Claude — the file path was pasted instead."
        )
        XCTAssertTrue(plan.text.hasPrefix("'"))
    }

    func testIntentionalPathInsertionNeverClaimsAttachmentFailure() {
        let plan = TerminalImageDrop.insertionPlan(
            for: [screenshot()],
            syntax: .pathOnly,
            stage: { _ in XCTFail("Path-only syntax must not stage"); return nil }
        )

        XCTAssertEqual(plan.unattachedClaudeImageCount, 0)
        XCTAssertNil(plan.warningMessage)
    }

    func testMixedClaudeDropCountsOnlyImagesThatFailedToStage() {
        let staged = URL(fileURLWithPath: "/staged/attached.png")
        let failed = screenshot("failed.png")
        let attached = screenshot("attached.png")
        let plan = TerminalImageDrop.insertionPlan(
            for: [failed, attached, URL(fileURLWithPath: "/tmp/notes.txt")],
            syntax: .claudeMention,
            stage: { $0 == failed ? nil : staged }
        )

        XCTAssertEqual(plan.unattachedClaudeImageCount, 1)
        XCTAssertNotNil(plan.warningMessage)
        XCTAssertTrue(plan.text.contains("@/staged/attached.png"))
        XCTAssertTrue(plan.text.contains("'/Users/m/Desktop/failed.png'"))
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

    // MARK: - The clipboard's file beats the clipboard's icon

    /// The bug Michael kept hitting, as an assertion.
    ///
    /// Copying a file in Finder puts a file URL *and* an image on the
    /// clipboard, and that image is the file's icon. Whatever asks the
    /// pasteboard for pixels — including Claude Code's own Control-V — gets a
    /// generic document icon, writes it to its image cache, and attaches a
    /// picture of an icon while nothing anywhere reports an error.
    ///
    /// So when both are present, the file has to win.
    func testAFileOnTheClipboardBeatsTheIconTheClipboardCarriesWithIt() throws {
        let pasteboard = NSPasteboard(name: .init("drop-test-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Screenshot 2026-08-02 at 9.17.36 PM.png")
        try Data(repeating: 0x42, count: 128).write(to: file)

        // Exactly what Finder leaves behind: the file, and an icon for it.
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setData(Data(repeating: 0x00, count: 64), forType: .png)

        let stagedDestination = directory.appendingPathComponent("staged.png")
        var stagedFiles: [URL] = []
        var stagedPixelPayloads: [Data] = []
        let plan = try XCTUnwrap(TerminalImageDrop.pastePlan(
            from: pasteboard,
            syntax: .claudeMention,
            stage: { url in stagedFiles.append(url); return stagedDestination },
            stageData: { data, _ in stagedPixelPayloads.append(data); return nil }
        ))

        XCTAssertEqual(stagedFiles.map(\.lastPathComponent), [file.lastPathComponent])
        XCTAssertTrue(
            stagedPixelPayloads.isEmpty,
            "The icon riding along with the file must never be what gets staged"
        )
        XCTAssertEqual(plan.text, "@" + stagedDestination.path + " ")
        XCTAssertEqual(plan.unattachedClaudeImageCount, 0)
    }

    /// With no file behind them the clipboard's pixels are the real image —
    /// a screenshot taken straight to the clipboard — so they stage.
    func testClipboardPixelsStageWhenNoFileStandsBehindThem() throws {
        let pasteboard = NSPasteboard(name: .init("drop-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data(repeating: 0x7F, count: 32), forType: .png)

        let staged = URL(fileURLWithPath: "/tmp/pasted-image-1.png")
        var seen: [Data] = []
        let plan = try XCTUnwrap(TerminalImageDrop.pastePlan(
            from: pasteboard,
            syntax: .claudeMention,
            stage: { _ in XCTFail("No file is on this clipboard"); return nil },
            stageData: { data, _ in seen.append(data); return staged }
        ))

        XCTAssertEqual(seen, [Data(repeating: 0x7F, count: 32)])
        XCTAssertEqual(plan.text, "@/tmp/pasted-image-1.png ")
    }

    /// An empty clipboard, and a clipboard aimed at something with no mention
    /// syntax, both decline — which is what tells the terminal to fall through
    /// to an ordinary paste instead of swallowing the keystroke.
    func testPastePlanDeclinesWhenThereIsNothingToAttach() {
        let empty = NSPasteboard(name: .init("drop-test-\(UUID().uuidString)"))
        empty.clearContents()
        empty.setString("just text", forType: .string)
        XCTAssertNil(TerminalImageDrop.pastePlan(from: empty, syntax: .claudeMention))

        let withImage = NSPasteboard(name: .init("drop-test-\(UUID().uuidString)"))
        withImage.clearContents()
        withImage.setData(Data(repeating: 0x7F, count: 32), forType: .png)
        XCTAssertNil(
            TerminalImageDrop.pastePlan(from: withImage, syntax: .pathOnly),
            "A plain shell has no @ syntax, so Control-V must keep its own meaning"
        )
    }
}
