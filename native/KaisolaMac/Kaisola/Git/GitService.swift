import Foundation

/// How long a Git or GitHub CLI child may run before Kaisola stops it. A stuck
/// filesystem, hook, credential helper, or SSH connection otherwise holds the
/// operation open forever, and the Git panel serializes on `isBusy` — so one
/// wedged read freezes every later Git action in that panel.
///
/// The budget is per operation class rather than one global number: a `git
/// status` that has not answered in 30s is broken, while a push over a slow
/// link or a `pre-commit` hook running a test suite is merely slow.
enum GitDeadline: Equatable, Sendable {
    /// Reads and index writes that touch only local disk.
    case local
    /// Local work that walks whole-history or whole-tree state, or that creates
    /// and removes worktrees. Slow on a large repository, never on the network.
    case bulk
    /// Commands that run arbitrary user hooks (`pre-commit`, `commit-msg`). The
    /// deadline here is a last-resort backstop, not a policy on hook length.
    case hooked
    /// Anything that can open a connection: fetch, pull, push, `gh`.
    case network
    /// An explicit budget in seconds, for a caller with its own policy.
    case custom(TimeInterval)

    var seconds: TimeInterval {
        switch self {
        case .local: 30
        case .bulk: 120
        case .hooked: 600
        case .network: 300
        case let .custom(value): value
        }
    }

    /// The `git` subcommand inside an argument list, skipping the leading global
    /// flags (`--no-optional-locks`). Also the label the panel shows when a
    /// command is stopped, so the banner can name what timed out.
    static func subcommand(of arguments: [String]) -> String? {
        arguments.drop(while: { $0.hasPrefix("-") }).first
    }

    /// Classify a `git` invocation by its subcommand so a new call site gets a
    /// sensible budget without having to remember to pass one. Unknown
    /// subcommands fall back to `.local`: the shortest budget is the safe
    /// default for a runner that only ever runs local reads and index writes.
    static func forGitArguments(_ arguments: [String]) -> GitDeadline {
        switch subcommand(of: arguments) {
        case "fetch", "pull", "push", "clone", "ls-remote": .network
        case "commit": .hooked
        case "apply", "checkout", "ls-files", "rev-list", "stash", "worktree": .bulk
        default: .local
        }
    }
}

/// Subprocess output capture that cannot deadlock when several Mesh columns
/// launch git concurrently. Anonymous pipe descriptors can be inherited by a
/// sibling child, preventing EOF forever; private regular files have no such
/// lifetime coupling and also absorb verbose failures without back-pressure.
///
/// The wait is bounded on both sides: the child is stopped when it outlives its
/// deadline, and when the surrounding Task is cancelled.
enum GitProcessCapture {
    /// The child was stopped rather than allowed to finish. Callers map this
    /// onto `GitService.GitError` so the UI can tell "nothing responded" apart
    /// from a command that genuinely failed.
    enum Failure: Error, Equatable {
        case timedOut(seconds: TimeInterval)
        case cancelled
    }

    /// How often the wait wakes to notice cancellation and the deadline. Git
    /// commands usually finish well inside one slice, so this costs nothing on
    /// the normal path.
    private static let pollInterval: TimeInterval = 0.05

    /// The grace period between asking the process group to quit and killing it.
    private static let terminationGrace: TimeInterval = 2

    /// `deadline` defaults to the *shortest* budget: a caller that forgets to
    /// classify its command fails fast instead of hanging, which is the failure
    /// mode this whole type exists to prevent.
    static func run(_ process: Process, deadline: GitDeadline = .local) throws -> (out: Data, err: Data) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? errors.close()
        }
        process.standardOutput = output
        process.standardError = errors
        if Task.isCancelled { throw Failure.cancelled }
        // waitUntilExit() has no deadline, so exit is observed through the
        // termination handler instead and the wait below owns the timing.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        try wait(for: process, exited: exited, budget: deadline.seconds)
        try? output.synchronize()
        try? errors.synchronize()
        return (
            (try? Data(contentsOf: outputURL)) ?? Data(),
            (try? Data(contentsOf: errorURL)) ?? Data()
        )
    }

    /// Block until the child exits, its budget runs out, or the surrounding Task
    /// is cancelled. Polling in short slices is what makes the last two
    /// observable at all while the child is still running.
    private static func wait(for process: Process, exited: DispatchSemaphore, budget: TimeInterval) throws {
        let expiry = Date().addingTimeInterval(budget)
        while true {
            if exited.wait(timeout: .now() + pollInterval) == .success { return }
            if Task.isCancelled {
                stop(process, exited: exited)
                throw Failure.cancelled
            }
            if Date() >= expiry {
                stop(process, exited: exited)
                throw Failure.timedOut(seconds: budget)
            }
        }
    }

    /// Stop the child and everything it spawned. Git delegates to ssh, credential
    /// helpers, pagers, and hooks; signalling only the direct child leaves those
    /// running and still holding whatever wedged the command. Foundation gives
    /// each child its own process group, so the group id is exactly "this
    /// command's subtree" — the identity check below keeps a child that somehow
    /// shares our group from turning this into a signal to Kaisola itself.
    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let group = getpgid(pid)
        let isOwnGroup = group <= 0 || group == getpgid(0)
        if isOwnGroup { kill(pid, SIGTERM) } else { killpg(group, SIGTERM) }
        if exited.wait(timeout: .now() + terminationGrace) == .success { return }
        if isOwnGroup { kill(pid, SIGKILL) } else { killpg(group, SIGKILL) }
        _ = exited.wait(timeout: .now() + terminationGrace)
    }
}

enum GitProcessEnvironment {
    /// Configure a GUI-launched Git or GitHub CLI process to fail instead of
    /// waiting on an invisible terminal, credential, or host-key prompt.
    static func configureNonInteractive(_ process: Process) {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "Never"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
    }
}

/// A read-safe git status/stage/commit service over `git` as a child process.
/// Mirrors the porcelain-v2 parsing validated by scripts/native-git-service.cjs
/// (Codex). Never runs destructive commands (no reset --hard, clean, checkout,
/// push); path arguments are guarded against escaping the repo root.
struct GitService: Sendable {
    let repoRoot: URL

    struct Status: Equatable, Sendable {
        var branch: String?
        var ahead: Int
        var behind: Int
        var staged: [Entry]
        var unstaged: [Entry]
        var untracked: [String]

        var isClean: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty }
    }

    struct Entry: Equatable, Identifiable, Sendable {
        let path: String
        let code: String
        var id: String { path }
    }

    enum GitError: Error, LocalizedError, Equatable {
        case notARepository
        case commandFailed(String)
        case unsafePath
        /// The command outlived its deadline and was stopped along with its
        /// process group. Distinct from `commandFailed` because git never got to
        /// say anything about the repository.
        case timedOut(command: String, seconds: Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notARepository: "This folder is not a git repository."
            case let .commandFailed(message): message
            case .unsafePath: "Refused an unsafe path argument."
            case let .timedOut(command, seconds):
                "\(command) did not respond within \(seconds)s and was stopped. Nothing was reported about the repository — try again."
            case .cancelled: "The Git operation was cancelled."
            }
        }

        /// A timeout says nothing about the repository, so running the same
        /// command again is a reasonable next move. An ordinary failure has
        /// already told the user what is wrong, and repeating it just repeats
        /// the message.
        var isRetryable: Bool {
            if case .timedOut = self { return true }
            return false
        }

        /// Map a stopped child onto the panel-facing error, tagging it with the
        /// command so the banner can name what was stopped.
        static func from(_ failure: GitProcessCapture.Failure, command: String) -> GitError {
            switch failure {
            case let .timedOut(seconds): .timedOut(command: command, seconds: Int(seconds.rounded()))
            case .cancelled: .cancelled
            }
        }
    }

    // MARK: - Reads

    /// `--no-optional-locks` keeps a read from taking `index.lock` and rewriting
    /// the index just to refresh stat data. Without it, the panel's own status
    /// read is itself a git-directory write — which the live watcher would report
    /// back as a change, refreshing again. Git ships this flag for exactly this
    /// class of caller.
    func status() throws -> Status {
        let output = try run(["--no-optional-locks", "status", "--porcelain=v2", "--branch"])
        return Self.parseStatus(output)
    }

    func diff(path: String, staged: Bool) throws -> String {
        try guardPath(path)
        var args = ["--no-optional-locks", "diff"]
        if staged { args.append("--staged") }
        args.append(contentsOf: ["--", path])
        let text = try run(args)
        let limit = 200_000
        return text.count > limit ? String(text.prefix(limit)) + "\n… (diff truncated)" : text
    }

    func log(limit: Int = 20) throws -> [Commit] {
        let sep = "\u{1f}"
        let output = try run(["log", "-n", String(limit), "--pretty=format:%H\(sep)%h\(sep)%an\(sep)%ad\(sep)%s", "--date=short"])
        return output.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: sep)
            guard parts.count == 5 else { return nil }
            return Commit(hash: parts[0], shortHash: parts[1], author: parts[2], date: parts[3], subject: parts[4])
        }
    }

    struct Commit: Equatable, Identifiable, Sendable {
        let hash: String
        let shortHash: String
        let author: String
        let date: String
        let subject: String
        var id: String { hash }
    }

    // MARK: - Writes (non-destructive)

    func stage(path: String) throws {
        try guardPath(path)
        _ = try run(["add", "--", path])
    }

    func unstage(path: String) throws {
        try guardPath(path)
        _ = try run(["restore", "--staged", "--", path])
    }

    /// Stage every tracked change, deletion, and untracked file under the
    /// repository root. This changes only the index and is fully reversible by
    /// `unstageAll()`.
    func stageAll() throws {
        _ = try run(["add", "--all", "--", "."])
    }

    /// Return the whole index to HEAD without touching working-tree bytes. An
    /// unborn repository has no HEAD for `git restore --staged`; removing the
    /// cached entries is the equivalent index-only operation there.
    func unstageAll() throws {
        do {
            _ = try run(["restore", "--staged", "--", "."])
        } catch let GitError.commandFailed(message) where message.contains("could not resolve HEAD") {
            _ = try run(["rm", "--cached", "-r", "--", "."])
        }
    }

    /// Fetch and update the checked-out branch only when Git can fast-forward.
    /// The panel additionally requires a clean tree and configured upstream;
    /// this service guard ensures no implicit merge commit is created even if
    /// another caller invokes it directly. Returns whether HEAD moved.
    @discardableResult
    func pullFastForward() throws -> Bool {
        let before = try headOID()
        _ = try run(["pull", "--ff-only"])
        return try headOID() != before
    }

    @discardableResult
    func commit(message: String) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.commandFailed("Enter a commit message.") }
        _ = try run(["commit", "-m", trimmed])
        return try run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Discard unstaged changes to one file (user-confirmed in the panel).
    func restoreFile(path: String) throws {
        try guardPath(path)
        _ = try run(["restore", "--", path])
    }

    /// Snapshot the working tree without moving HEAD or touching the index:
    /// `git stash create` writes the stash commit and returns its hash but
    /// stores nothing, so the tree is untouched. Returns nil on a clean tree.
    /// The snapshot is kept alive under a PRIVATE ref namespace
    /// (`refs/kaisola/checkpoints/*`) — never the user's stash list.
    func checkpoint() throws -> String? {
        let hash = try run(["stash", "create", "kaisola pre-turn checkpoint"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return nil }
        _ = try run(["update-ref", "refs/kaisola/checkpoints/\(hash)", hash])
        return hash
    }

    /// Release an aged-out checkpoint's keep-alive ref.
    func dropCheckpoint(_ hash: String) throws {
        guard hash.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil else {
            throw GitError.commandFailed("Invalid checkpoint id")
        }
        _ = try run(["update-ref", "-d", "refs/kaisola/checkpoints/\(hash)"])
    }

    /// Restore the files recorded in a checkpoint over the current tree.
    func applyCheckpoint(_ hash: String) throws {
        guard hash.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil else {
            throw GitError.commandFailed("Invalid checkpoint id")
        }
        _ = try run(["stash", "apply", hash])
    }

    // MARK: - Worktrees (Kaisola Mesh)

    /// Branch prefix for Mesh worktrees; removal APIs refuse anything else so
    /// no user branch can ever be deleted by Mesh cleanup.
    static let meshBranchPrefix = "kaisola-mesh-"

    struct RegisteredWorktree: Equatable, Sendable {
        let path: String
        let branch: String?
    }

    struct MeshDiscardInventory: Equatable, Sendable {
        let status: Status
        let commitsSinceBase: Int
        /// Ignored output is normally invisible to `git status`, but an agent
        /// may still have created valuable artifacts under an ignored path.
        /// Keep a bounded sample for confirmation UI/debugging; deletion only
        /// needs to know that at least one entry exists.
        let ignoredUntracked: [String]

        var hasRecoverableWork: Bool {
            !status.isClean || commitsSinceBase > 0 || !ignoredUntracked.isEmpty
        }
    }

    func headOID() throws -> String {
        let oid = try run(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oid.range(of: "^[0-9a-fA-F]{40,64}$", options: .regularExpression) != nil else {
            throw GitError.commandFailed("Git returned an invalid HEAD identifier")
        }
        return oid.lowercased()
    }

    func branchExists(_ branch: String) throws -> Bool {
        guard branch.hasPrefix(Self.meshBranchPrefix) else {
            throw GitError.commandFailed("Mesh branches must use the \(Self.meshBranchPrefix)* namespace")
        }
        // `git branch --list` exits zero for both present and absent refs, so
        // an empty result means genuinely missing while process/permission
        // failures still throw. `show-ref --quiet` cannot make that distinction
        // through the generic command runner because its not-found exit is 1.
        let output = try run(["branch", "--list", "--format=%(refname:short)", branch])
        return output.split(separator: "\n").contains { $0 == Substring(branch) }
    }

    /// Registered worktree truth from Git itself. Persisted Mesh paths are
    /// adopted or removed only after their exact path/branch pair appears here.
    func registeredWorktrees() throws -> [RegisteredWorktree] {
        let output = try run(["worktree", "list", "--porcelain"])
        var result: [RegisteredWorktree] = []
        var path: String?
        var branch: String?
        func flush() {
            if let path {
                result.append(RegisteredWorktree(path: path, branch: branch))
            }
            path = nil
            branch = nil
        }
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        flush()
        return result
    }

    func isRegisteredWorktree(path: String, branch: String) throws -> Bool {
        let expectedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return try registeredWorktrees().contains { entry in
            URL(fileURLWithPath: entry.path, isDirectory: true).standardizedFileURL.path == expectedPath
                && entry.branch == branch
        }
    }

    /// Inventory every recoverable form of Mesh work. A clean worktree can
    /// still contain unique committed work, so status alone is insufficient.
    func meshDiscardInventory(createdBaseOID: String) throws -> MeshDiscardInventory {
        guard createdBaseOID.range(of: "^[0-9a-fA-F]{40,64}$", options: .regularExpression) != nil else {
            throw GitError.commandFailed("Mesh base commit is invalid")
        }
        let countText = try run(["rev-list", "--count", "\(createdBaseOID)..HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commits = Int(countText), commits >= 0 else {
            throw GitError.commandFailed("Git returned an invalid Mesh commit count")
        }
        let ignored = try run([
            "ls-files", "--others", "--ignored", "--exclude-standard",
            "--directory", "--no-empty-directory", "-z",
        ])
        let ignoredUntracked = ignored
            .split(separator: "\0", omittingEmptySubsequences: true)
            .prefix(256)
            .map(String.init)
        return MeshDiscardInventory(
            status: try status(),
            commitsSinceBase: commits,
            ignoredUntracked: ignoredUntracked
        )
    }

    /// Create an isolated worktree at `path` on a fresh branch from the exact
    /// commit captured in its durable manifest. Using implicit HEAD here would
    /// let concurrent base-branch movement corrupt diff/discard semantics.
    func worktreeAdd(path: String, branch: String, startPoint: String) throws {
        guard branch.hasPrefix(Self.meshBranchPrefix) else {
            throw GitError.commandFailed("Mesh worktrees must use the \(Self.meshBranchPrefix)* namespace")
        }
        guard startPoint.range(of: "^[0-9a-fA-F]{40,64}$", options: .regularExpression) != nil else {
            throw GitError.commandFailed("Mesh worktree start point is invalid")
        }
        _ = try run(["worktree", "add", "-b", branch, path, startPoint])
    }

    /// Remove a Mesh worktree and its branch. Refuses non-Mesh branches.
    func worktreeRemove(path: String, branch: String) throws {
        guard branch.hasPrefix(Self.meshBranchPrefix) else {
            throw GitError.commandFailed("Refusing to remove a non-Mesh worktree branch")
        }
        guard try isRegisteredWorktree(path: path, branch: branch) else {
            throw GitError.commandFailed("Refusing to remove an unverified Mesh worktree")
        }
        _ = try run(["worktree", "remove", "--force", path])
        _ = try run(["branch", "-D", branch])
    }

    /// The full working-tree diff against HEAD (Mesh column review).
    func diffAgainstHead() throws -> String {
        try run(["diff", "HEAD"])
    }

    /// Full tracked delta from the Mesh fork point through committed and
    /// uncommitted work. This keeps an agent commit visible/reviewable instead
    /// of making the card look empty after `git commit`.
    func diffAgainstBase(_ createdBaseOID: String) throws -> String {
        guard createdBaseOID.range(of: "^[0-9a-fA-F]{40,64}$", options: .regularExpression) != nil else {
            throw GitError.commandFailed("Mesh base commit is invalid")
        }
        return try run(["diff", createdBaseOID])
    }

    // MARK: - Parsing

    static func parseStatus(_ output: String) -> Status {
        var status = Status(branch: nil, ahead: 0, behind: 0, staged: [], unstaged: [], untracked: [])
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# branch.head ") {
                status.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let fields = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for field in fields {
                    if field.hasPrefix("+") { status.ahead = Int(field.dropFirst()) ?? 0 }
                    if field.hasPrefix("-") { status.behind = Int(field.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // "1 XY ... path"  or renamed "2 XY ... path\tsrc"
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count >= 9 else { continue }
                let xy = String(fields[1])
                let pathField = fields[8...].joined(separator: " ")
                let path = String(pathField.split(separator: "\t").first ?? Substring(pathField))
                let x = xy.first.map(String.init) ?? "."
                let y = xy.dropFirst().first.map(String.init) ?? "."
                if x != "." { status.staged.append(Entry(path: path, code: x)) }
                if y != "." { status.unstaged.append(Entry(path: path, code: y)) }
            } else if line.hasPrefix("? ") {
                status.untracked.append(String(line.dropFirst(2)))
            }
        }
        return status
    }

    // MARK: - Process

    private func guardPath(_ path: String) throws {
        // Join under the repo root, then standardize (resolves any ".." in the
        // argument) and confirm the result stays inside the root.
        let resolved = repoRoot.appendingPathComponent(path).standardizedFileURL
        let root = repoRoot.standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw GitError.unsafePath
        }
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repoRoot
        GitProcessEnvironment.configureNonInteractive(process)
        let capture: (out: Data, err: Data)
        do { capture = try GitProcessCapture.run(process, deadline: .forGitArguments(arguments)) }
        catch let failure as GitProcessCapture.Failure {
            throw GitError.from(failure, command: Self.commandLabel(arguments))
        }
        catch { throw GitError.commandFailed(error.localizedDescription) }
        if process.terminationStatus != 0 {
            let message = String(data: capture.err, encoding: .utf8) ?? "git failed"
            if message.contains("not a git repository") { throw GitError.notARepository }
            throw GitError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: capture.out, encoding: .utf8) ?? ""
    }

    /// "git status", "git push" — what a stopped command is called in the UI.
    /// Only the subcommand is included: the arguments can carry paths, branch
    /// names, and commit messages that do not belong in an error banner.
    static func commandLabel(_ arguments: [String]) -> String {
        guard let subcommand = GitDeadline.subcommand(of: arguments) else { return "git" }
        return "git \(subcommand)"
    }
}
