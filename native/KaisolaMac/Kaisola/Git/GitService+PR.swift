import Foundation

/// One-click "committed work → pushed branch + opened pull request" for the Git
/// panel — the network-touching, branch-moving operations (push, `checkout -b`,
/// `gh`) that the read-safe core in GitService.swift deliberately excludes. Like
/// GitService+Apply.swift, it reuses only the public surface (`repoRoot`,
/// `GitError`) and models its own `git`/`gh` invocations on GitService's private
/// `run()` shape, confined to the repo root.
extension GitService {
    /// A snapshot of "can I open a PR from here, and what would it contain?"
    struct PRPrep: Equatable, Sendable {
        let branch: String
        let isDefaultBranch: Bool
        let hasUpstream: Bool
        let aheadCount: Int
    }

    /// Inspect the current branch: its name, whether it is the repo's default
    /// branch (so the PR flow must fork a new branch first), whether it already
    /// tracks an upstream (so push knows whether to set one), and how many
    /// commits it carries beyond its base — the commits a PR would contain.
    func prPrep() throws -> PRPrep {
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUpstream = (try? runGit(["rev-parse", "--abbrev-ref", "@{upstream}"])) != nil
        return PRPrep(
            branch: branch,
            isDefaultBranch: branch == resolveDefaultBranch(),
            hasUpstream: hasUpstream,
            aheadCount: computeAheadCount()
        )
    }

    /// Subjects of the commits this branch adds over its base, newest first — the
    /// PR body's bullet list. Measured against `@{upstream}` when set, else the
    /// remote/local default branch, so it is still meaningful on a freshly forked
    /// branch that has no upstream yet (the primary flow computes this *before*
    /// the push sets an upstream that would otherwise empty the range).
    func aheadSubjects() throws -> [String] {
        guard let base = aheadBaseRef() else { return [] }
        let output = try runGit(["log", "--format=%s", "\(base)..HEAD"])
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Push the current branch. Sets an upstream (`push -u origin HEAD`) the first
    /// time; a plain `push` afterwards.
    func pushCurrentBranch(setUpstream: Bool) throws {
        if setUpstream {
            _ = try runGit(["push", "-u", "origin", "HEAD"])
        } else {
            _ = try runGit(["push"])
        }
    }

    /// Fork a new branch off HEAD — run before a PR when sitting on the default
    /// branch, so committed work never turns into a PR *from* main. The name is
    /// guarded to a safe charset so it can never smuggle extra `git` arguments.
    func createBranchFromHead(named name: String) throws {
        guard name.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil else {
            throw GitError.commandFailed("Invalid branch name — use letters, digits, and . _ / - only.")
        }
        _ = try runGit(["checkout", "-b", name])
    }

    /// Open a pull request for the current branch via the GitHub CLI, returning
    /// the PR URL. Runs `gh` as its own child process (resolved absolute path,
    /// cwd = repoRoot, stderr surfaced on failure) exactly like GitService's
    /// `git` runner.
    func createPullRequest(title: String, body: String) throws -> String {
        guard let gh = Self.resolvedGhPath() else {
            throw GitError.commandFailed("GitHub CLI (gh) is not installed.")
        }
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["pr", "create", "--title", title, "--body", body, "--head", branch]
        process.currentDirectoryURL = repoRoot
        let capture: (out: Data, err: Data)
        do { capture = try GitProcessCapture.run(process) }
        catch { throw GitError.commandFailed(error.localizedDescription) }
        if process.terminationStatus != 0 {
            let message = String(data: capture.err, encoding: .utf8) ?? "gh pr create failed"
            throw GitError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // gh prints the PR URL on stdout; take the last http line to be safe.
        let stdout = String(data: capture.out, encoding: .utf8) ?? ""
        let lines = stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last(where: { $0.hasPrefix("http") })
            ?? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Is the GitHub CLI available? Chooses between opening a real PR and falling
    /// back to a browser compare page.
    static func ghAvailable() -> Bool {
        resolvedGhPath() != nil
    }

    /// A GitHub compare URL (`…/compare/<default>...<branch>`) built from the
    /// origin remote — the no-`gh` fallback. Nil when origin isn't a parseable
    /// remote.
    func compareURL() throws -> String? {
        let remote = try runGit(["remote", "get-url", "origin"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = Self.webURL(fromRemote: remote) else { return nil }
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(base)/compare/\(resolveDefaultBranch())...\(branch)"
    }

    /// Turn a git remote URL into its web base (`https://host/owner/repo`, no
    /// `.git`). Handles scp-style ssh (`git@github.com:owner/repo.git`) and url
    /// forms (`https://…`, `ssh://git@…`). Pure and static so it is unit testable
    /// without a repo.
    static func webURL(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        while s.hasSuffix("/") { s = String(s.dropLast()) }

        // scp-style ssh: [user@]host:owner/repo  (no scheme).
        if !s.contains("://"), let at = s.firstIndex(of: "@") {
            let afterAt = s[s.index(after: at)...]
            guard let colon = afterAt.firstIndex(of: ":") else { return nil }
            let host = String(afterAt[..<colon])
            let path = String(afterAt[afterAt.index(after: colon)...])
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return "https://\(host)/\(path)"
        }

        // url form: scheme://[user@]host/owner/repo.
        if let schemeRange = s.range(of: "://") {
            var rest = String(s[schemeRange.upperBound...])
            if let at = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let host = String(rest[..<slash])
            let path = String(rest[rest.index(after: slash)...])
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return "https://\(host)/\(path)"
        }

        return nil
    }

    // MARK: - Private

    /// The repo's default branch name ("main" when it can't be resolved from
    /// `origin/HEAD`).
    private func resolveDefaultBranch() -> String {
        if let ref = try? runGit(["symbolic-ref", "refs/remotes/origin/HEAD"]) {
            let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "refs/remotes/origin/"
            if trimmed.hasPrefix(prefix) {
                let name = String(trimmed.dropFirst(prefix.count))
                if !name.isEmpty { return name }
            }
        }
        return "main"
    }

    /// The ref the current branch's "ahead" is measured against: the tracked
    /// upstream if set, else the remote default branch, else the local default
    /// branch. Nil when none resolve.
    private func aheadBaseRef() -> String? {
        if (try? runGit(["rev-parse", "--abbrev-ref", "@{upstream}"])) != nil {
            return "@{upstream}"
        }
        let def = resolveDefaultBranch()
        if (try? runGit(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(def)"])) != nil {
            return "origin/\(def)"
        }
        if (try? runGit(["rev-parse", "--verify", "--quiet", "refs/heads/\(def)"])) != nil {
            return def
        }
        return nil
    }

    private func computeAheadCount() -> Int {
        guard let base = aheadBaseRef() else { return 0 }
        return (try? runGit(["rev-list", "--count", "\(base)..HEAD"]))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    /// Resolve an absolute path to `gh`: the common Homebrew locations first
    /// (reliable under a GUI app's minimal PATH), then `which gh`.
    private static func resolvedGhPath() -> String? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["gh"]
        guard let capture = try? GitProcessCapture.run(process) else { return nil }
        guard process.terminationStatus == 0 else { return nil }
        let path = (String(data: capture.out, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// A minimal `git` runner confined to `repoRoot`. GitService.run() is private
    /// to its own file, so this mirrors its shape (same executable, cwd, stderr →
    /// error mapping) rather than reaching into it — the same approach as
    /// GitService+Apply.swift.
    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repoRoot
        let capture: (out: Data, err: Data)
        do { capture = try GitProcessCapture.run(process) }
        catch { throw GitError.commandFailed(error.localizedDescription) }
        if process.terminationStatus != 0 {
            let message = String(data: capture.err, encoding: .utf8) ?? "git failed"
            if message.contains("not a git repository") { throw GitError.notARepository }
            throw GitError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: capture.out, encoding: .utf8) ?? ""
    }

}
