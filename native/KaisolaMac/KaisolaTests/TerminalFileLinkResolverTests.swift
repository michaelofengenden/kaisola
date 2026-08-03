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
