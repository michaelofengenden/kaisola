import CryptoKit
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

    /// The exact reviewed push/PR target. `remoteIdentity` fingerprints the raw
    /// configured URL so credentials never enter the UI while a remote change
    /// between review and confirm still invalidates the plan.
    struct PRDestination: Equatable, Sendable {
        let remoteName: String
        let remoteDisplayURL: String
        let webURL: String?
        let remoteIdentity: String
        let baseBranch: String
        let isConfigured: Bool

        var isReadyForPullRequest: Bool { isConfigured && webURL != nil }

        static func unavailable(baseBranch: String) -> PRDestination {
            PRDestination(
                remoteName: "origin",
                remoteDisplayURL: "Not configured",
                webURL: nil,
                remoteIdentity: "missing",
                baseBranch: baseBranch,
                isConfigured: false
            )
        }
    }

    /// What a successful `gh pr create` produced. Exit zero means the pull
    /// request exists, but `gh`'s stdout is not a contract — warnings and upgrade
    /// notices ride the same stream — so a run that opened a PR without naming it
    /// is a partial success with somewhere to go, not a URL nobody validated.
    enum PullRequestOutcome: Equatable, Sendable {
        /// `gh` printed exactly one pull request URL on the reviewed repository.
        case opened(url: String)
        /// The pull request was created, but no trustworthy URL came back.
        /// `recoveryURL` is the repository's pull request list, filtered to the
        /// branch that was pushed, so the reviewer can still reach it.
        case openedWithoutURL(recoveryURL: String)
    }

    /// Inspect the current branch: its name, whether it is the repo's default
    /// branch (so the PR flow must fork a new branch first), whether it already
    /// tracks an upstream (so push knows whether to set one), and how many
    /// commits it carries beyond the target default branch — the commits a PR
    /// would contain, whether or not the feature branch was already pushed.
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

    /// Subjects of the commits this branch adds over the target default branch,
    /// newest first. A feature branch's own upstream is deliberately not the
    /// base: an already-pushed branch still needs a truthful PR review.
    func aheadSubjects() throws -> [String] {
        guard let base = aheadBaseRef() else { return [] }
        let output = try runGit(["log", "--format=%s", "\(base)..HEAD"])
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The branch a pull request from here would target — shown in the review
    /// before anything is pushed.
    func defaultBranchName() -> String {
        resolveDefaultBranch()
    }

    /// Resolve the `origin` target before review. A missing or non-web remote is
    /// represented explicitly instead of letting `gh` infer a hidden target.
    /// The raw URL is fingerprinted, never displayed or persisted in the plan.
    func prDestination(remoteName: String = "origin") -> PRDestination {
        let baseBranch = resolveDefaultBranch()
        guard remoteName.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              let raw = try? runGit(["remote", "get-url", remoteName]) else {
            return .unavailable(baseBranch: baseBranch)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable(baseBranch: baseBranch) }
        let webURL = Self.webURL(fromRemote: trimmed)
        return PRDestination(
            remoteName: remoteName,
            remoteDisplayURL: Self.redactedRemoteDisplay(fromRemote: trimmed),
            webURL: webURL,
            remoteIdentity: Self.remoteIdentity(fromRemote: trimmed),
            baseBranch: baseBranch,
            isConfigured: true
        )
    }

    /// The files the ahead commits touch, measured against the same base as
    /// `aheadSubjects`. Empty when no base resolves.
    func aheadChangedFiles() throws -> [String] {
        guard let base = aheadBaseRef() else { return [] }
        let output = try runGit(["--no-optional-locks", "diff", "--name-only", "-z", "\(base)..HEAD"])
        return output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// Push the current branch. Sets an upstream (`push -u origin HEAD`) the first
    /// time; a plain `push` afterwards.
    func pushCurrentBranch(setUpstream: Bool, remoteName: String = "origin") throws {
        guard remoteName.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw GitError.commandFailed("The reviewed Git remote name is invalid.")
        }
        if setUpstream {
            _ = try runGit(["push", "-u", remoteName, "HEAD"])
        } else {
            _ = try runGit(["push", remoteName, "HEAD"])
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

    /// Open a pull request for the current branch via the GitHub CLI. Runs `gh`
    /// as its own child process (resolved absolute path, cwd = repoRoot, stderr
    /// surfaced on failure) exactly like GitService's `git` runner. `ghPath`
    /// names the executable to run; the default resolves the installed CLI and
    /// tests substitute a stub.
    ///
    /// A zero exit means the pull request exists, so a URL we cannot pin to the
    /// reviewed repository is reported as a partial success rather than thrown
    /// away or handed to the UI unchecked.
    func createPullRequest(
        title: String,
        body: String,
        baseBranch: String,
        headBranch: String,
        repositoryURL: String,
        ghPath: String? = nil
    ) throws -> PullRequestOutcome {
        guard let gh = ghPath ?? Self.resolvedGhPath() else {
            throw GitError.commandFailed("GitHub CLI (gh) is not installed.")
        }
        guard repositoryURL.hasPrefix("https://") else {
            throw GitError.commandFailed("The reviewed pull request destination is not a web repository.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = Self.pullRequestArguments(
            title: title,
            body: body,
            baseBranch: baseBranch,
            headBranch: headBranch,
            repositoryURL: repositoryURL
        )
        process.currentDirectoryURL = repoRoot
        GitProcessEnvironment.configureNonInteractive(process)
        let capture: (out: Data, err: Data)
        do { capture = try GitProcessCapture.run(process) }
        catch { throw GitError.commandFailed(error.localizedDescription) }
        if process.terminationStatus != 0 {
            let message = String(data: capture.err, encoding: .utf8) ?? "gh pr create failed"
            throw GitError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let stdout = String(data: capture.out, encoding: .utf8) ?? ""
        if let url = Self.pullRequestURL(inGhOutput: stdout, repositoryURL: repositoryURL) {
            return .opened(url: url)
        }
        return .openedWithoutURL(
            recoveryURL: Self.pullRequestListURL(repositoryURL: repositoryURL, headBranch: headBranch)
        )
    }

    /// The one pull request URL in `gh pr create`'s stdout, or nil when that
    /// output is silent, unparseable, or ambiguous. `gh` prints the PR URL there,
    /// but upgrade notices and warnings share the stream, so a token only counts
    /// as the destination when it is an `https` URL on the reviewed repository's
    /// own host, port, and `<owner>/<repo>/pull/<number>` path. Two different
    /// pull request numbers mean we cannot tell which one was opened, so neither
    /// is used. The result is rebuilt from the reviewed repository URL, never
    /// echoed from stdout. Pure and static so it is unit testable without `gh`.
    static func pullRequestURL(inGhOutput output: String, repositoryURL: String) -> String? {
        var base = repositoryURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let repo = URLComponents(string: base),
              repo.scheme?.lowercased() == "https",
              let repoHost = repo.host?.lowercased() else { return nil }
        let repoPath = repo.path.split(separator: "/").map(String.init)
        guard repoPath.count == 2 else { return nil }

        let noise = CharacterSet(charactersIn: "()[]{}<>\"'`.,;:!?")
        var number: String?
        for token in output.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = String(token).trimmingCharacters(in: noise)
            guard let url = URLComponents(string: candidate),
                  url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  url.host?.lowercased() == repoHost,
                  url.port == repo.port else { continue }
            let path = url.path.split(separator: "/").map(String.init)
            guard path.count == 4,
                  path[0].caseInsensitiveCompare(repoPath[0]) == .orderedSame,
                  path[1].caseInsensitiveCompare(repoPath[1]) == .orderedSame,
                  path[2] == "pull",
                  !path[3].isEmpty, path[3].allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            if let seen = number, seen != path[3] { return nil }
            number = path[3]
        }
        return number.map { "\(base)/pull/\($0)" }
    }

    /// Where to look when `gh` opened a pull request but never named it: the
    /// reviewed repository's pull request list, filtered to the branch that was
    /// just pushed.
    static func pullRequestListURL(repositoryURL: String, headBranch: String) -> String {
        var base = repositoryURL
        while base.hasSuffix("/") { base.removeLast() }
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "q", value: "is:pr head:\(headBranch)")]
        guard let encoded = query.percentEncodedQuery, !encoded.isEmpty else { return "\(base)/pulls" }
        return "\(base)/pulls?\(encoded)"
    }

    static func pullRequestArguments(
        title: String,
        body: String,
        baseBranch: String,
        headBranch: String,
        repositoryURL: String
    ) -> [String] {
        [
            "pr", "create",
            "--title", title,
            "--body", body,
            "--base", baseBranch,
            "--head", headBranch,
            "--repo", repositoryURL,
        ]
    }

    /// Is the GitHub CLI available? Chooses between opening a real PR and falling
    /// back to a browser compare page.
    static func ghAvailable() -> Bool {
        resolvedGhPath() != nil
    }

    /// A GitHub compare URL (`…/compare/<default>...<branch>`) built from the
    /// origin remote — the no-`gh` fallback. Nil when origin isn't a parseable
    /// remote.
    func compareURL(destination: PRDestination, headBranch: String) -> String? {
        guard destination.isReadyForPullRequest,
              let base = destination.webURL else { return nil }
        return "\(base)/compare/\(destination.baseBranch)...\(headBranch)"
    }

    /// Turn a git remote URL into its web base (`https://host/owner/repo`, no
    /// `.git`). Handles scp-style ssh (`git@github.com:owner/repo.git`) and url
    /// forms (`https://…`, `ssh://git@…`). Pure and static so it is unit testable
    /// without a repo.
    static func webURL(fromRemote remote: String) -> String? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s = String(s.dropLast()) }

        // scp-style ssh: [user@]host:owner/repo  (no scheme).
        if !s.contains("://"), let colon = s.firstIndex(of: ":") {
            let authority = String(s[..<colon])
            let host = authority.split(separator: "@").last.map(String.init) ?? ""
            var path = String(s[s.index(after: colon)...])
            if let marker = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                path = String(path[..<marker])
            }
            while path.hasSuffix("/") { path.removeLast() }
            if path.hasSuffix(".git") { path.removeLast(4) }
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return "https://\(host)/\(path)"
        }

        // URL form: discard userinfo, query, and fragment so credentials can
        // never enter the review card. Preserve an explicit host port.
        if s.contains("://"),
           let components = URLComponents(string: s),
           let scheme = components.scheme?.lowercased(),
           ["http", "https", "ssh", "git"].contains(scheme),
           let host = components.host, !host.isEmpty {
            var path = components.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            if path.hasSuffix(".git") { path.removeLast(4) }
            while path.hasPrefix("/") { path.removeFirst() }
            guard !path.isEmpty else { return nil }
            let port = components.port.map { ":\($0)" } ?? ""
            return "https://\(host)\(port)/\(path)"
        }

        return nil
    }

    /// Show the push transport without userinfo, query credentials, fragments,
    /// or private local path prefixes. The separate `webURL` is the PR target.
    static func redactedRemoteDisplay(fromRemote remote: String) -> String {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("file://") || !trimmed.contains(":") {
            let path = trimmed.hasPrefix("file://")
                ? URL(string: trimmed)?.path ?? trimmed
                : trimmed
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? "Local repository" : "Local · \(name)"
        }

        if !trimmed.contains("://"), let colon = trimmed.firstIndex(of: ":") {
            let authority = String(trimmed[..<colon])
            let host = authority.split(separator: "@").last.map(String.init) ?? ""
            var path = String(trimmed[trimmed.index(after: colon)...])
            if let marker = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                path = String(path[..<marker])
            }
            while path.hasSuffix("/") { path.removeLast() }
            if path.hasSuffix(".git") { path.removeLast(4) }
            if !host.isEmpty, !path.isEmpty { return "ssh://\(host)/\(path)" }
        }

        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           ["http", "https", "ssh", "git"].contains(scheme),
           let host = components.host, !host.isEmpty {
            var path = components.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            if path.hasSuffix(".git") { path.removeLast(4) }
            guard !path.isEmpty else { return "\(scheme)://\(host)" }
            let port = components.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)\(path)"
        }
        return "Configured non-web remote"
    }

    static func remoteIdentity(fromRemote remote: String) -> String {
        SHA256.hash(data: Data(remote.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

    /// The target default-branch ref used for PR commits and files. Never use a
    /// feature branch's own upstream: after its first push that range is empty
    /// even though the pull request still contains every feature commit.
    private func aheadBaseRef() -> String? {
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
        GitProcessEnvironment.configureNonInteractive(process)
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
