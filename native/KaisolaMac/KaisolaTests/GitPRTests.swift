import Foundation
import XCTest
@testable import Kaisola

/// GitService+PR against real throwaway repos: branch/upstream inspection, the
/// safe branch fork, remote-URL parsing, and ahead-subject listing. Never
/// invokes `gh` — only local git and a bare "origin".
final class GitPRTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-gitpr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testPRPrepOnFreshRepoWithCommit() throws {
        try write("a.txt", "hello\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "init"])

        let prep = try GitService(repoRoot: repo).prPrep()
        XCTAssertEqual(prep.branch, "main")
        XCTAssertTrue(prep.isDefaultBranch)      // resolves to "main" (no origin/HEAD)
        XCTAssertFalse(prep.hasUpstream)
        XCTAssertEqual(prep.aheadCount, 0)
    }

    func testCreateBranchFromHeadReflectedInPRPrep() throws {
        try write("a.txt", "hello\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "init"])

        let service = GitService(repoRoot: repo)
        try service.createBranchFromHead(named: "kaisola/pr-branch")

        let prep = try service.prPrep()
        XCTAssertEqual(prep.branch, "kaisola/pr-branch")
        XCTAssertFalse(prep.isDefaultBranch)
    }

    func testCreateBranchFromHeadRejectsUnsafeName() throws {
        try write("a.txt", "hello\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "init"])
        XCTAssertThrowsError(try GitService(repoRoot: repo).createBranchFromHead(named: "bad name;rm"))
    }

    func testWebURLParsesSshAndHttpsRemotes() {
        XCTAssertEqual(
            GitService.webURL(fromRemote: "git@github.com:owner/repo.git"),
            "https://github.com/owner/repo"
        )
        XCTAssertEqual(
            GitService.webURL(fromRemote: "https://github.com/owner/repo.git"),
            "https://github.com/owner/repo"
        )
        // Robustness: no .git suffix, and an ssh:// url form, resolve the same base.
        XCTAssertEqual(
            GitService.webURL(fromRemote: "https://github.com/owner/repo"),
            "https://github.com/owner/repo"
        )
        XCTAssertEqual(
            GitService.webURL(fromRemote: "ssh://git@github.com/owner/repo.git"),
            "https://github.com/owner/repo"
        )
        XCTAssertEqual(
            GitService.webURL(fromRemote: "github.com:owner/repo.git"),
            "https://github.com/owner/repo"
        )
        XCTAssertEqual(
            GitService.webURL(fromRemote: "git@github.com:owner/repo.git?token=hidden"),
            "https://github.com/owner/repo"
        )
        XCTAssertEqual(
            GitService.webURL(fromRemote: "https://user:secret@github.com/owner/repo.git?token=hidden#fragment"),
            "https://github.com/owner/repo"
        )
        XCTAssertNil(GitService.webURL(fromRemote: "file://server/private/repo.git"))
        XCTAssertNil(GitService.webURL(fromRemote: "ftp://user:secret@example.com/private/repo.git"))
        XCTAssertNil(GitService.webURL(fromRemote: ""))
    }

    func testPRDestinationDisclosesTargetWithoutCredentialsAndTracksExactRemoteIdentity() throws {
        try git(["remote", "add", "origin", "https://user:secret@github.com/acme/widget.git?token=hidden"])
        let service = GitService(repoRoot: repo)
        let first = service.prDestination()

        XCTAssertTrue(first.isConfigured)
        XCTAssertTrue(first.isReadyForPullRequest)
        XCTAssertEqual(first.remoteName, "origin")
        XCTAssertEqual(first.remoteDisplayURL, "https://github.com/acme/widget")
        XCTAssertEqual(first.webURL, "https://github.com/acme/widget")
        XCTAssertEqual(first.baseBranch, "main")
        XCTAssertFalse(first.remoteDisplayURL.contains("secret"))
        XCTAssertFalse(first.remoteDisplayURL.contains("hidden"))

        try git(["remote", "set-url", "origin", "git@github.com:acme/other.git"])
        let changed = service.prDestination()
        XCTAssertNotEqual(changed.remoteIdentity, first.remoteIdentity)
        XCTAssertEqual(changed.remoteDisplayURL, "ssh://github.com/acme/other")
    }

    func testMissingAndLocalRemotesStayExplicitButCannotCreateAWebPullRequest() throws {
        let service = GitService(repoRoot: repo)
        let missing = service.prDestination()
        XCTAssertFalse(missing.isConfigured)
        XCTAssertFalse(missing.isReadyForPullRequest)
        XCTAssertEqual(missing.remoteDisplayURL, "Not configured")

        try git(["remote", "add", "origin", "/Users/private/work/secret-repository.git"])
        let local = service.prDestination()
        XCTAssertTrue(local.isConfigured)
        XCTAssertFalse(local.isReadyForPullRequest)
        XCTAssertEqual(local.remoteDisplayURL, "Local · secret-repository.git")
        XCTAssertFalse(local.remoteDisplayURL.contains("/Users/private"))
    }

    func testReviewedDestinationBuildsCompareURLAndPinsEveryGhArgument() throws {
        try git(["remote", "add", "origin", "git@github.com:acme/widget.git"])
        let service = GitService(repoRoot: repo)
        let destination = service.prDestination()
        XCTAssertEqual(
            service.compareURL(destination: destination, headBranch: "feature/review"),
            "https://github.com/acme/widget/compare/main...feature/review"
        )
        XCTAssertEqual(
            GitService.pullRequestArguments(
                title: "Reviewed title",
                body: "Reviewed body",
                baseBranch: "main",
                headBranch: "feature/review",
                repositoryURL: "https://github.com/acme/widget"
            ),
            [
                "pr", "create",
                "--title", "Reviewed title",
                "--body", "Reviewed body",
                "--base", "main",
                "--head", "feature/review",
                "--repo", "https://github.com/acme/widget",
            ]
        )
    }

    func testPushUsesTheReviewedRemoteNameInsteadOfAnImplicitUpstream() throws {
        try write("a.txt", "hello\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "init"])
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-reviewed-\(UUID().uuidString.prefix(8)).git")
        try git(["init", "-q", "--bare", bare.path])
        defer { try? FileManager.default.removeItem(at: bare) }
        try git(["remote", "add", "reviewed", bare.path])

        try GitService(repoRoot: repo).pushCurrentBranch(
            setUpstream: true,
            remoteName: "reviewed"
        )
        XCTAssertEqual(
            try gitOutput(["--git-dir", bare.path, "rev-parse", "refs/heads/main"])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            try GitService(repoRoot: repo).headOID()
        )
    }

    func testAheadSubjectsCountsCommitsPastUpstream() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "first subject"])

        // A bare "origin" so the branch gets a real upstream after push -u.
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-origin-\(UUID().uuidString.prefix(8)).git")
        try git(["init", "-q", "--bare", bare.path])
        defer { try? FileManager.default.removeItem(at: bare) }
        try git(["remote", "add", "origin", bare.path])
        try git(["push", "-q", "-u", "origin", "main"])

        // One more local commit — exactly one ahead of the upstream.
        try write("b.txt", "two\n")
        try git(["add", "b.txt"])
        try git(["commit", "-q", "-m", "second subject"])

        let service = GitService(repoRoot: repo)
        XCTAssertEqual(try service.aheadSubjects(), ["second subject"])

        let prep = try service.prPrep()
        XCTAssertTrue(prep.hasUpstream)
        XCTAssertEqual(prep.aheadCount, 1)
    }

    func testAlreadyPushedFeatureBranchStillShowsCompletePullRequestContents() throws {
        try write("base.txt", "base\n")
        try git(["add", "base.txt"])
        try git(["commit", "-q", "-m", "base"])
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-origin-\(UUID().uuidString.prefix(8)).git")
        try git(["init", "-q", "--bare", bare.path])
        defer { try? FileManager.default.removeItem(at: bare) }
        try git(["remote", "add", "origin", bare.path])
        try git(["push", "-q", "-u", "origin", "main"])
        try git(["remote", "set-head", "origin", "main"])

        try git(["checkout", "-q", "-b", "feature/already-pushed"])
        try write("feature.txt", "feature\n")
        try git(["add", "feature.txt"])
        try git(["commit", "-q", "-m", "feature work"])
        try git(["push", "-q", "-u", "origin", "feature/already-pushed"])

        let service = GitService(repoRoot: repo)
        let prep = try service.prPrep()
        XCTAssertTrue(prep.hasUpstream)
        XCTAssertEqual(prep.aheadCount, 1)
        XCTAssertEqual(try service.aheadSubjects(), ["feature work"])
        XCTAssertEqual(try service.aheadChangedFiles(), ["feature.txt"])
    }

    /// The two reads the PR review needs on top of the ahead subjects: the base
    /// branch it will target and how many files the pull request would touch.
    func testDefaultBranchAndChangedFilesDescribeThePullRequest() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])

        let service = GitService(repoRoot: repo)
        XCTAssertEqual(service.defaultBranchName(), "main")   // no origin/HEAD → main
        // On the default branch with no upstream there is no ahead range at all.
        XCTAssertEqual(try service.aheadChangedFiles(), [])

        try git(["checkout", "-q", "-b", "feature/files"])
        try write("b.txt", "two\n")
        try write("c.txt", "three\n")
        try git(["add", "b.txt", "c.txt"])
        try git(["commit", "-q", "-m", "add two files"])
        try write("b.txt", "two changed\n")
        try git(["add", "b.txt"])
        try git(["commit", "-q", "-m", "touch b again"])

        // Measured against the local default branch: two commits, but b.txt is
        // counted once — the review shows files changed, not file-touch events.
        XCTAssertEqual(try service.aheadChangedFiles().sorted(), ["b.txt", "c.txt"])
        XCTAssertEqual(try service.aheadSubjects(), ["touch b again", "add two files"])
    }

    func testChangedFileInventoryPreservesWhitespaceAndNewlinePathsExactly() throws {
        try write("base.txt", "base\n")
        try git(["add", "base.txt"])
        try git(["commit", "-q", "-m", "base"])
        try git(["checkout", "-q", "-b", "feature/paths"])
        try write("space name.txt", "space\n")
        try write("line\nbreak.txt", "newline\n")
        try git(["add", "space name.txt", "line\nbreak.txt"])
        try git(["commit", "-q", "-m", "unusual paths"])

        XCTAssertEqual(
            Set(try GitService(repoRoot: repo).aheadChangedFiles()),
            ["space name.txt", "line\nbreak.txt"]
        )
    }

    /// `gh` shares stdout between the pull request URL and whatever else it feels
    /// like printing, so only a URL on the reviewed repository's own host and
    /// `<owner>/<repo>/pull/<number>` path may become a destination.
    func testOnlyAPullRequestURLOnTheReviewedRepositoryIsAccepted() {
        let repository = "https://github.com/acme/widget"

        XCTAssertEqual(
            GitService.pullRequestURL(
                inGhOutput: "https://github.com/acme/widget/pull/42\n",
                repositoryURL: repository
            ),
            "https://github.com/acme/widget/pull/42"
        )
        // The PR URL is not always the last http line: upgrade notices follow it.
        XCTAssertEqual(
            GitService.pullRequestURL(
                inGhOutput: """
                Warning: 2 uncommitted changes
                https://github.com/acme/widget/pull/42

                A new release of gh is available: 2.40.0 → 2.42.0
                https://github.com/cli/cli/releases/tag/v2.42.0

                """,
                repositoryURL: repository
            ),
            "https://github.com/acme/widget/pull/42"
        )
        // Prose around the URL, and a differently cased owner/repo, still resolve.
        XCTAssertEqual(
            GitService.pullRequestURL(
                inGhOutput: "Opened (https://github.com/Acme/Widget/pull/7).",
                repositoryURL: repository
            ),
            "https://github.com/acme/widget/pull/7"
        )

        // Nothing usable: silence, prose, another host, another repo, a look-alike
        // host, plain http, a non-numeric id, or a path that is not a PR.
        for output in [
            "",
            "\n\n",
            "Creating pull request for feature/review into main\n",
            "https://evil.example.com/acme/widget/pull/42\n",
            "https://github.com/other/repo/pull/42\n",
            "https://github.com.evil.example.com/acme/widget/pull/42\n",
            "http://github.com/acme/widget/pull/42\n",
            "https://github.com/acme/widget/pull/not-a-number\n",
            "https://github.com/acme/widget/pulls\n",
            "https://github.com/acme/widget/pull/42/files\n",
            "javascript:alert(1)\n",
        ] {
            XCTAssertNil(
                GitService.pullRequestURL(inGhOutput: output, repositoryURL: repository),
                "accepted an unusable gh output: \(output.debugDescription)"
            )
        }

        // Two different pull requests in one run: we cannot tell which was opened.
        XCTAssertNil(GitService.pullRequestURL(
            inGhOutput: "https://github.com/acme/widget/pull/42\nhttps://github.com/acme/widget/pull/43\n",
            repositoryURL: repository
        ))
        // The same one twice is not ambiguous.
        XCTAssertEqual(
            GitService.pullRequestURL(
                inGhOutput: "https://github.com/acme/widget/pull/42\nhttps://github.com/acme/widget/pull/42\n",
                repositoryURL: repository
            ),
            "https://github.com/acme/widget/pull/42"
        )
    }

    /// A `gh` that exits 0 after printing the PR URL amid noise still yields one
    /// exact destination, rebuilt from the reviewed repository.
    func testCreatePullRequestKeepsOnlyTheReviewedRepositoryURL() throws {
        try write("a.txt", "hello\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "init"])

        // The shape gh actually prints: the PR URL, then an upgrade notice whose
        // own release URL is the last http line in the run.
        let gh = try stubGh(stdout: """
        Warning: 2 uncommitted changes
        https://github.com/acme/widget/pull/42

        A new release of gh is available: 2.40.0 → 2.42.0
        https://github.com/cli/cli/releases/tag/v2.42.0
        """)

        XCTAssertEqual(
            try GitService(repoRoot: repo).createPullRequest(
                title: "Reviewed title",
                body: "Reviewed body",
                baseBranch: "main",
                headBranch: "feature/review",
                repositoryURL: "https://github.com/acme/widget",
                ghPath: gh
            ),
            .opened(url: "https://github.com/acme/widget/pull/42")
        )
    }

    /// `gh` exiting 0 means the pull request exists, so silence or a URL we cannot
    /// pin to the reviewed repository is a partial success with a place to look —
    /// never an unvalidated destination and never a swallowed pull request.
    func testCreatePullRequestReportsPartialSuccessWhenNoTrustworthyURLComesBack() throws {
        try write("a.txt", "hello\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "init"])

        let service = GitService(repoRoot: repo)
        let recovery = "https://github.com/acme/widget/pulls?q=is:pr%20head:feature/review"
        for stdout in [
            "",
            "Creating pull request for feature/review into main in acme/widget",
            "https://phish.example.com/acme/widget/pull/42",
            "https://github.com/acme/widget/pull/42\nhttps://github.com/acme/widget/pull/43",
        ] {
            let outcome = try service.createPullRequest(
                title: "Reviewed title",
                body: "Reviewed body",
                baseBranch: "main",
                headBranch: "feature/review",
                repositoryURL: "https://github.com/acme/widget",
                ghPath: try stubGh(stdout: stdout)
            )
            XCTAssertEqual(
                outcome,
                .openedWithoutURL(recoveryURL: recovery),
                "unexpected outcome for gh output \(stdout.debugDescription)"
            )
            // Recovery has to be somewhere a browser can actually go.
            if case let .openedWithoutURL(url) = outcome {
                XCTAssertNotNil(URL(string: url))
            }
        }
    }

    /// A failing `gh` is still an error, not a partial success: nothing was opened.
    func testCreatePullRequestStillThrowsWhenGhFails() throws {
        try write("a.txt", "hello\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "init"])

        XCTAssertThrowsError(
            try GitService(repoRoot: repo).createPullRequest(
                title: "Reviewed title",
                body: "Reviewed body",
                baseBranch: "main",
                headBranch: "feature/review",
                repositoryURL: "https://github.com/acme/widget",
                ghPath: try stubGh(stdout: "", status: 1)
            )
        )
    }

    // MARK: helpers

    /// A stand-in for the GitHub CLI that prints `stdout` verbatim and exits with
    /// `status`, so the PR flow can be exercised end to end without a real `gh`,
    /// an account, or a network.
    private func stubGh(stdout: String, status: Int32 = 0) throws -> String {
        let script = repo.appendingPathComponent("stub-gh-\(UUID().uuidString.prefix(8))")
        try """
        #!/bin/sh
        cat <<'KAISOLA_STUB_EOF'
        \(stdout)
        KAISOLA_STUB_EOF
        exit \(status)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

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

    private func gitOutput(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
