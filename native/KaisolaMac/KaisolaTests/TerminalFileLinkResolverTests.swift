import XCTest
@testable import Kaisola

/// Agents cite files by the name they used in prose, not by a path relative to
/// the session's directory. These cover what happens when that name does not
/// land where the terminal first looked.
final class TerminalFileLinkResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# hi".utf8).write(to: url)
        return url
    }

    /// A path that exists is used as-is; no search, no surprises.
    func testAnExistingPathResolvesToItself() throws {
        let file = try write("README.md")
        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(file, projectRoot: root),
            .found(file.standardizedFileURL)
        )
    }

    /// The reported bug. Claude cites `PILOT_REPORT.md`; the terminal resolves
    /// that against the project root, where no such file is; the real one is
    /// three directories down.
    func testACitationForANestedFileIsFoundByName() throws {
        let real = try write("pilot/prospective_yh/pilot/PILOT_REPORT.md")
        let guessed = root.appendingPathComponent("PILOT_REPORT.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: guessed.path))

        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(guessed, projectRoot: root),
            .found(real.standardizedFileURL)
        )
    }

    /// Two files of the same name is the common case in a real repository
    /// (every package has a README). Opening one at random would sometimes be
    /// right and silently wrong the rest of the time.
    func testTwoFilesOfTheSameNameAreReportedRatherThanGuessed() throws {
        _ = try write("packages/a/README.md")
        _ = try write("packages/b/README.md")
        let guessed = root.appendingPathComponent("README.md")

        guard case let .ambiguous(name, count) = TerminalFileLinkResolver.resolve(
            guessed, projectRoot: root
        ) else {
            return XCTFail("Two matches must not resolve to one file")
        }
        XCTAssertEqual(name, "README.md")
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    func testANameThatIsNowhereIsMissing() {
        let guessed = root.appendingPathComponent("NOPE.md")
        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(guessed, projectRoot: root),
            .missing(name: "NOPE.md")
        )
    }

    /// A build directory can hold tens of thousands of files with names that
    /// collide with real sources. Walking it would be slow and would turn a
    /// clean hit into a false ambiguity.
    func testNoiseDirectoriesAreNotSearched() throws {
        let real = try write("src/config.md")
        _ = try write("node_modules/pkg/config.md")
        _ = try write(".git/objects/config.md")

        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(
                root.appendingPathComponent("config.md"),
                projectRoot: root
            ),
            .found(real.standardizedFileURL)
        )
    }

    /// With no project to search, a missing file is simply missing — the
    /// resolver never wanders outside what it was given.
    func testWithoutAProjectRootNothingIsSearched() {
        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(
                root.appendingPathComponent("README.md"),
                projectRoot: nil
            ),
            .missing(name: "README.md")
        )
    }

    // MARK: - Git diff prefixes

    func testIndexAndWorktreeMnemonicPrefixesResolveTheExactProjectPath() throws {
        let target = try write("Sources/Unicode folder/同じ name.swift")
        _ = try write("Tests/同じ name.swift")

        for prefix in ["i", "w"] {
            let linked = root.appendingPathComponent(
                "\(prefix)/Sources/Unicode folder/同じ name.swift"
            )
            XCTAssertEqual(
                TerminalFileLinkResolver.resolve(linked, projectRoot: root),
                .found(target.standardizedFileURL),
                "Git's \(prefix)/ mnemonic must preserve the path after its semantic prefix"
            )
        }
    }

    func testNoIndexSidePrefixesResolveTheExactProjectPath() throws {
        let first = try write("fixtures/left/same name.txt")
        let second = try write("fixtures/right/same name.txt")

        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(
                root.appendingPathComponent("1/fixtures/left/same name.txt"),
                projectRoot: root
            ),
            .found(first.standardizedFileURL)
        )
        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(
                root.appendingPathComponent("2/fixtures/right/same name.txt"),
                projectRoot: root
            ),
            .found(second.standardizedFileURL)
        )
    }

    func testSymmetricallyQuotedMnemonicPathSupportsSpaces() throws {
        let target = try write("docs/Release Notes.md")
        _ = try write("archive/Release Notes.md")
        let linked = URL(
            fileURLWithPath: root.path + "/\"w/docs/Release Notes.md\""
        )

        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(linked, projectRoot: root),
            .found(target.standardizedFileURL)
        )
    }

    func testRealDirectoriesNamedLikeDiffPrefixesAlwaysWin() throws {
        for prefix in ["i", "w", "1", "2"] {
            let literal = try write("\(prefix)/docs/\(prefix)-guide.md")
            _ = try write("docs/\(prefix)-guide.md")

            XCTAssertEqual(
                TerminalFileLinkResolver.resolve(literal, projectRoot: root),
                .found(literal.standardizedFileURL),
                "an existing \(prefix)/ directory is ordinary project content, not a diff prefix"
            )
        }
    }

    func testExistingMnemonicDirectoryKeepsMissingChildrenLiteral() throws {
        _ = try write("docs/guide.md")
        _ = try write("other/guide.md")
        let literalDirectory = root.appendingPathComponent("i", isDirectory: true)
        try FileManager.default.createDirectory(at: literalDirectory, withIntermediateDirectories: true)
        let missingLiteral = literalDirectory.appendingPathComponent("docs/guide.md")

        guard case let .ambiguous(name, count) = TerminalFileLinkResolver.resolve(
            missingLiteral,
            projectRoot: root
        ) else {
            return XCTFail("a real i/ directory must suppress semantic prefix stripping")
        }
        XCTAssertEqual(name, "guide.md")
        XCTAssertGreaterThanOrEqual(count, 2)
    }

    func testTraversalOutsideTheProjectIsRejectedEvenWhenTheFileExists() throws {
        let external = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        let traversing = root.appendingPathComponent(
            "w/../../\(external.lastPathComponent)"
        )

        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(traversing, projectRoot: root),
            .missing(name: external.lastPathComponent)
        )
    }

    func testFallbackSearchDoesNotFollowAFileSymlinkOutsideTheProject() throws {
        let external = root.deletingLastPathComponent()
            .appendingPathComponent("external-\(UUID().uuidString).md")
        try Data("secret".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        let alias = root.appendingPathComponent("nested/\(external.lastPathComponent)")
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: external)

        XCTAssertEqual(
            TerminalFileLinkResolver.resolve(
                root.appendingPathComponent(external.lastPathComponent),
                projectRoot: root
            ),
            .missing(name: external.lastPathComponent)
        )
    }

    // MARK: - Reveal

    func testRevealFallsBackToTheNearestFolderThatExists() throws {
        let file = try write("docs/notes/deep.md")
        XCTAssertEqual(TerminalFileLinkResolver.revealTarget(for: file), file.standardizedFileURL)

        let deleted = root.appendingPathComponent("docs/notes/gone.md")
        XCTAssertEqual(
            TerminalFileLinkResolver.revealTarget(for: deleted),
            root.appendingPathComponent("docs/notes").standardizedFileURL,
            "Finder should land in the folder the file was supposed to be in"
        )

        let strayBranch = root.appendingPathComponent("no/such/place/at/all.md")
        XCTAssertEqual(TerminalFileLinkResolver.revealTarget(for: strayBranch), root.standardizedFileURL)
    }

    func testRevealGivesUpRatherThanLoopingOnAPathWithNoRoot() {
        XCTAssertNotNil(TerminalFileLinkResolver.revealTarget(for: URL(fileURLWithPath: "/")))
    }
}
