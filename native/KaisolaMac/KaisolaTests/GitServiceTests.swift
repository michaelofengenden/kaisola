import Foundation
import XCTest
@testable import KaisolaMacPreview

/// GitService against a real throwaway repo — the porcelain-v2 parse, stage,
/// and commit paths, mirroring the Node service Codex verified.
final class GitServiceTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("kaisola-git-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testStatusParsesStagedUnstagedUntracked() throws {
        try write("committed.txt", "one\n")
        try git(["add", "committed.txt"])
        try git(["commit", "-q", "-m", "init"])
        try write("committed.txt", "one\ntwo\n")   // unstaged modification
        try write("staged.txt", "new\n")
        try git(["add", "staged.txt"])              // staged add
        try write("untracked.txt", "loose\n")       // untracked

        let status = try GitService(repoRoot: repo).status()
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.staged.contains { $0.path == "staged.txt" })
        XCTAssertTrue(status.unstaged.contains { $0.path == "committed.txt" })
        XCTAssertTrue(status.untracked.contains("untracked.txt"))
        XCTAssertFalse(status.isClean)
    }

    func testStageThenCommitClearsTree() throws {
        try write("a.txt", "hello\n")
        let service = GitService(repoRoot: repo)
        try service.stage(path: "a.txt")
        XCTAssertTrue(try service.status().staged.contains { $0.path == "a.txt" })

        let hash = try service.commit(message: "add a")
        XCTAssertEqual(hash.count, 40)
        XCTAssertTrue(try service.status().isClean)
        XCTAssertEqual(try service.log(limit: 5).first?.subject, "add a")
    }

    func testCommitWithNothingStagedFails() throws {
        try write("committed.txt", "x\n")
        try git(["add", "."]); try git(["commit", "-q", "-m", "init"])
        XCTAssertThrowsError(try GitService(repoRoot: repo).commit(message: "empty"))
    }

    func testNonRepoThrows() {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("kaisola-not-a-repo-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(try GitService(repoRoot: outside).status()) { error in
            XCTAssertEqual(error as? GitService.GitError, .notARepository)
        }
    }

    func testPathTraversalRejected() {
        XCTAssertThrowsError(try GitService(repoRoot: repo).stage(path: "../../etc/hosts")) { error in
            XCTAssertEqual(error as? GitService.GitError, .unsafePath)
        }
    }

    // MARK: helpers

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = repo
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
}
