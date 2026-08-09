import Foundation
import XCTest
@testable import Kaisola

/// Bounded Git and GitHub CLI subprocesses. A stuck filesystem, hook, SSH
/// helper, or credential prompt used to hold a Git panel operation open with no
/// deadline and no way out; these cover the three halves of the fix — the
/// per-operation budget, stopping the whole process group rather than just the
/// direct child, and reporting a stopped command as a retryable timeout instead
/// of an ordinary failure.
final class GitProcessDeadlineTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-deadline-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Budgets (pure)

    func testDeadlinesMatchWhatEachCommandCanWaitOn() {
        XCTAssertEqual(GitDeadline.forGitArguments(["--no-optional-locks", "status", "--porcelain=v2", "--branch"]), .local)
        XCTAssertEqual(GitDeadline.forGitArguments(["--no-optional-locks", "diff", "--staged", "--", "a.txt"]), .local)
        XCTAssertEqual(GitDeadline.forGitArguments(["add", "--", "a.txt"]), .local)
        // Network commands: a slow link is not a wedge.
        XCTAssertEqual(GitDeadline.forGitArguments(["pull", "--ff-only"]), .network)
        XCTAssertEqual(GitDeadline.forGitArguments(["push", "-u", "origin", "HEAD"]), .network)
        // Commit runs arbitrary user hooks, so its backstop is the longest.
        XCTAssertEqual(GitDeadline.forGitArguments(["commit", "-m", "subject"]), .hooked)
        XCTAssertEqual(GitDeadline.forGitArguments(["worktree", "add", "-b", "kaisola-mesh-a", "/tmp/a", "abc"]), .bulk)
        XCTAssertEqual(GitDeadline.forGitArguments(["apply", "--3way", "/tmp/p.patch"]), .bulk)
        // An unclassified command gets the shortest budget, not an unbounded one.
        XCTAssertEqual(GitDeadline.forGitArguments(["definitely-not-a-subcommand"]), .local)
        XCTAssertEqual(GitDeadline.forGitArguments([]), .local)

        XCTAssertGreaterThan(GitDeadline.network.seconds, GitDeadline.local.seconds)
        XCTAssertGreaterThan(GitDeadline.hooked.seconds, GitDeadline.bulk.seconds)
        XCTAssertEqual(GitDeadline.custom(2).seconds, 2, accuracy: 0.001)
    }

    func testTheStoppedCommandIsNamedWithoutLeakingItsArguments() {
        XCTAssertEqual(GitService.commandLabel(["--no-optional-locks", "status", "--branch"]), "git status")
        XCTAssertEqual(GitService.commandLabel(["commit", "-m", "secret work in progress"]), "git commit")
        XCTAssertEqual(GitService.commandLabel([]), "git")
    }

    func testOutputLimitsMatchTheOperationRatherThanOneGlobalAllowance() {
        let diff = GitProcessCapture.Limits.forGitArguments(["--no-optional-locks", "diff", "HEAD"])
        let commit = GitProcessCapture.Limits.forGitArguments(["commit", "-m", "subject"])
        let push = GitProcessCapture.Limits.forGitArguments(["push", "origin", "HEAD"])
        let status = GitProcessCapture.Limits.forGitArguments(["status", "--porcelain=v2"])

        XCTAssertEqual(diff, .bulk)
        XCTAssertEqual(status, .bulk)
        XCTAssertEqual(commit, .hooked)
        XCTAssertEqual(push, .network)
        XCTAssertLessThan(GitProcessCapture.Limits.probe.stdoutBytes, commit.stdoutBytes)
        XCTAssertLessThan(commit.stdoutBytes, diff.stdoutBytes)
    }

    func testFailedCommandRetainsBoundedHeadAndTailWithExactByteCounts() throws {
        let process = shellProcess(
            "printf 'BEGIN-'; i=0; while [ \"$i\" -lt 100 ]; do printf x; i=$((i + 1)); done; printf '%s' '-END'; exit 7"
        )
        let capture = try GitProcessCapture.run(
            process,
            deadline: .custom(5),
            limits: .init(stdoutBytes: 20, stderrBytes: 8)
        )

        XCTAssertEqual(process.terminationStatus, 7)
        XCTAssertEqual(capture.out.totalByteCount, 110)
        XCTAssertEqual(capture.out.retainedByteCount, 20)
        XCTAssertTrue(capture.out.isTruncated)
        XCTAssertNil(capture.out.completeData)
        let diagnostic = capture.out.diagnosticText()
        XCTAssertTrue(diagnostic.hasPrefix("BEGIN-"), diagnostic)
        XCTAssertTrue(diagnostic.hasSuffix("-END"), diagnostic)
        XCTAssertTrue(diagnostic.contains("output truncated"), diagnostic)
        XCTAssertTrue(diagnostic.contains("retained 20 of 110 bytes"), diagnostic)
        XCTAssertTrue(diagnostic.contains("10 head + 10 tail"), diagnostic)
    }

    func testSuccessfulCommandOverItsLimitFailsWithExactRetainedCounts() {
        let process = shellProcess("i=0; while [ \"$i\" -lt 100 ]; do printf x; i=$((i + 1)); done")
        XCTAssertThrowsError(
            try GitProcessCapture.run(
                process,
                deadline: .custom(5),
                limits: .init(stdoutBytes: 16, stderrBytes: 8)
            )
        ) { error in
            XCTAssertEqual(
                error as? GitProcessCapture.Failure,
                .outputLimitExceeded(stream: "stdout", totalBytes: 100, retainedBytes: 16)
            )
        }
    }

    // MARK: - A timeout is retryable, a failure is not

    func testATimeoutReadsAsRetryableAndDistinctFromAFailure() throws {
        let timeout = GitService.GitError.timedOut(command: "git status", seconds: 30)
        let failure = GitService.GitError.commandFailed("fatal: bad object HEAD")

        XCTAssertTrue(timeout.isRetryable)
        XCTAssertFalse(failure.isRetryable)
        XCTAssertFalse(GitService.GitError.cancelled.isRetryable)
        XCTAssertNotEqual(timeout.errorDescription, failure.errorDescription)

        let text = try XCTUnwrap(timeout.errorDescription)
        XCTAssertTrue(text.contains("git status"), "the banner must name what was stopped: \(text)")
        XCTAssertTrue(text.contains("30"), "the banner must say how long it waited: \(text)")

        // The panel's Retry affordance keys off exactly this decision.
        XCTAssertTrue(GitPanelModel.isRetryable(timeout))
        XCTAssertFalse(GitPanelModel.isRetryable(failure))
        XCTAssertFalse(GitPanelModel.isRetryable(GitService.GitError.notARepository))
    }

    func testStoppedChildrenMapOntoTheirPanelFacingError() {
        XCTAssertEqual(
            GitService.GitError.from(.timedOut(seconds: 30), command: "git push"),
            .timedOut(command: "git push", seconds: 30)
        )
        XCTAssertEqual(GitService.GitError.from(.cancelled, command: "git push"), .cancelled)
        XCTAssertEqual(
            GitService.GitError.from(
                .outputLimitExceeded(stream: "stdout", totalBytes: 1_000, retainedBytes: 64),
                command: "git status"
            ),
            .commandFailed(
                "git status produced 1000 stdout bytes; retained 64 bytes at its output limit. "
                    + "Narrow the operation and try again."
            )
        )
    }

    // MARK: - Stopping a wedged child

    func testAWedgedChildIsStoppedOnItsDeadline() throws {
        let marker = scratch.appendingPathComponent("child.pid")
        let started = Date()
        XCTAssertThrowsError(
            try GitProcessCapture.run(shellProcess("echo $$ > '\(marker.path)'; sleep 30"), deadline: .custom(1))
        ) { error in
            XCTAssertEqual(error as? GitProcessCapture.Failure, .timedOut(seconds: 1))
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 15,
            "the deadline must stop the child rather than wait it out"
        )
        XCTAssertTrue(waitUntilGone(try readPID(at: marker)))
    }

    func testTheDeadlineStopsTheWholeProcessGroup() throws {
        // The backgrounded `sleep` stands in for what git actually spawns — ssh,
        // a credential helper, a hook — a grandchild that survives a signal
        // aimed only at the direct child.
        let marker = scratch.appendingPathComponent("grandchild.pid")
        XCTAssertThrowsError(
            try GitProcessCapture.run(shellProcess("sleep 30 & echo $! > '\(marker.path)'; wait"), deadline: .custom(1))
        )
        let grandchild = try readPID(at: marker)
        XCTAssertTrue(
            waitUntilGone(grandchild),
            "pid \(grandchild) outlived the command that spawned it"
        )
    }

    /// Uses the default deadline deliberately: this is the cancellation half of
    /// the fix, and it must hold for any caller that never picked a budget.
    func testCancellingTheSurroundingTaskStopsTheChild() async throws {
        let marker = scratch.appendingPathComponent("cancelled.pid")
        let script = "echo $$ > '\(marker.path)'; sleep 30"
        let capture = Task.detached { () throws -> Int in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            return try GitProcessCapture.run(process).out.completeData?.count ?? 0
        }
        let child = try await waitForPID(at: marker)

        capture.cancel()
        let started = Date()
        let result = await capture.result
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 15,
            "cancelling must stop the child rather than wait it out"
        )
        XCTAssertThrowsError(try result.get())
        XCTAssertTrue(waitUntilGone(child), "pid \(child) survived the cancellation")
    }

    // MARK: - Through GitService

    /// A `pre-commit` hook that never returns is the realistic wedge: git itself
    /// is healthy and waiting on a grandchild. Cancelling must stop the whole
    /// chain and report a stopped command, not hang until the hook gives up.
    func testCancellingAGitOperationStopsTheHookItIsWaitingOn() async throws {
        let marker = scratch.appendingPathComponent("hook.pid")
        let repo = try makeRepositoryWithBlockingPreCommitHook(marker: marker)
        let service = GitService(repoRoot: repo)
        let commit = Task.detached { try service.commit(message: "wedged by a hook") }
        let hook = try await waitForPID(at: marker)

        commit.cancel()
        let started = Date()
        let result = await commit.result
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 15,
            "a cancelled commit must not wait for its hook"
        )
        XCTAssertThrowsError(try result.get()) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                text.localizedCaseInsensitiveContains("cancel"),
                "a stopped command must read as stopped, not as a git failure: \(text)"
            )
        }
        XCTAssertTrue(waitUntilGone(hook), "the hook (pid \(hook)) outlived the commit")
    }

    // MARK: - Helpers

    private func makeRepositoryWithBlockingPreCommitHook(marker: URL) throws -> URL {
        let repo = scratch.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: repo)
        try runGit(["config", "user.email", "test@example.com"], in: repo)
        try runGit(["config", "user.name", "Test"], in: repo)
        // A developer-wide core.hooksPath would otherwise silently skip the hook
        // this test depends on.
        try runGit(["config", "core.hooksPath", ".git/hooks"], in: repo)
        try "content\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "file.txt"], in: repo)

        let hook = repo.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho $$ > '\(marker.path)'\nsleep 30\n"
            .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        return repo
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }

}

private func shellProcess(_ script: String) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    return process
}

private struct NeverStarted: Error {}

private func readPID(at url: URL) throws -> Int32 {
    let text = try String(contentsOf: url, encoding: .utf8)
    guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw NeverStarted()
    }
    return pid
}

/// Wait for the pid a spawned script recorded, so a test only cancels once the
/// process it means to stop actually exists.
private func waitForPID(at url: URL, timeout: TimeInterval = 15) async throws -> Int32 {
    let expiry = Date().addingTimeInterval(timeout)
    while Date() < expiry {
        if let pid = try? readPID(at: url) { return pid }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw NeverStarted()
}

/// True once the pid is gone. A stopped grandchild is reparented to launchd and
/// reaped there, so its disappearance is quick but not instantaneous.
private func waitUntilGone(_ pid: Int32, timeout: TimeInterval = 10) -> Bool {
    let expiry = Date().addingTimeInterval(timeout)
    while Date() < expiry {
        if kill(pid, 0) != 0 { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return false
}
