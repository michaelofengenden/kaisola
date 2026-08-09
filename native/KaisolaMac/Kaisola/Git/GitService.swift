import CryptoKit
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
    /// Maximum child output rendered into a single diagnostic. Capture budgets
    /// may be larger for successful protocol responses, but an error banner is
    /// always a small head/tail excerpt.
    static let diagnosticByteLimit = 16 * 1_024

    /// Maximum bytes retained from each child stream. The command may write more
    /// to its private spool file, but Kaisola never materializes more than this
    /// amount in memory. Commands that legitimately return tree-sized data get a
    /// larger stdout allowance than hooks, probes, or network diagnostics.
    struct Limits: Equatable, Sendable {
        let stdoutBytes: Int
        let stderrBytes: Int

        static let local = Limits(stdoutBytes: 8 * 1_024 * 1_024, stderrBytes: 2 * 1_024 * 1_024)
        static let bulk = Limits(stdoutBytes: 32 * 1_024 * 1_024, stderrBytes: 4 * 1_024 * 1_024)
        static let hooked = Limits(stdoutBytes: 2 * 1_024 * 1_024, stderrBytes: 2 * 1_024 * 1_024)
        static let network = Limits(stdoutBytes: 8 * 1_024 * 1_024, stderrBytes: 8 * 1_024 * 1_024)
        static let probe = Limits(stdoutBytes: 64 * 1_024, stderrBytes: 64 * 1_024)

        static func forGitArguments(_ arguments: [String]) -> Limits {
            switch GitDeadline.subcommand(of: arguments) {
            case "apply", "checkout", "diff", "log", "ls-files", "rev-list", "show", "stash", "status", "worktree": .bulk
            case "commit": .hooked
            case "clone", "fetch", "ls-remote", "pull", "push": .network
            default: .local
            }
        }
    }

    /// A bounded head/tail view of one output file. `totalByteCount` comes from
    /// the file itself, so diagnostics can state exactly how much was omitted
    /// without ever loading the omitted middle into memory.
    struct Stream: Equatable, Sendable {
        let head: Data
        let tail: Data
        let totalByteCount: UInt64

        var retainedByteCount: Int { head.count + tail.count }
        var isTruncated: Bool { UInt64(retainedByteCount) < totalByteCount }

        /// The complete bytes are available only when the operation stayed
        /// inside its capture limit. Successful commands are rejected by
        /// `run` before a caller could accidentally parse a truncated value.
        var completeData: Data? {
            guard !isTruncated else { return nil }
            return head
        }

        /// Render a bounded diagnostic, retaining both the start and end. The
        /// marker reports original and retained byte counts rather than merely
        /// saying "truncated".
        func diagnosticText(byteLimit: Int? = nil) -> String {
            let limit = max(0, byteLimit ?? retainedByteCount)
            let segments = diagnosticSegments(byteLimit: limit)
            let retained = segments.head.count + segments.tail.count
            guard UInt64(retained) < totalByteCount else {
                return String(decoding: segments.head, as: UTF8.self)
            }
            let marker = "\n… output truncated; retained \(retained) of \(totalByteCount) bytes "
                + "(\(segments.head.count) head + \(segments.tail.count) tail) …\n"
            return String(decoding: segments.head, as: UTF8.self)
                + marker
                + String(decoding: segments.tail, as: UTF8.self)
        }

        private func diagnosticSegments(byteLimit: Int) -> (head: Data, tail: Data) {
            guard totalByteCount > UInt64(byteLimit) else { return (head, Data()) }
            let headBudget = (byteLimit + 1) / 2
            let tailBudget = byteLimit - headBudget
            let retainedHead = Data(head.prefix(headBudget))
            let tailSource = tail.isEmpty ? head : tail
            return (retainedHead, Data(tailSource.suffix(tailBudget)))
        }
    }

    struct Result: Equatable, Sendable {
        let out: Stream
        let err: Stream
    }

    /// The child was stopped rather than allowed to finish. Callers map this
    /// onto `GitService.GitError` so the UI can tell "nothing responded" apart
    /// from a command that genuinely failed.
    enum Failure: Error, Equatable {
        case timedOut(seconds: TimeInterval)
        case cancelled
        case outputLimitExceeded(stream: String, totalBytes: UInt64, retainedBytes: Int)
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
    static func run(
        _ process: Process,
        standardInput: Data? = nil,
        deadline: GitDeadline = .local,
        limits: Limits = .local
    ) throws -> Result {
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
        var input: FileHandle?
        if let standardInput {
            let inputURL = directory.appendingPathComponent("stdin")
            try standardInput.write(to: inputURL)
            input = try FileHandle(forReadingFrom: inputURL)
            process.standardInput = input
        }
        defer {
            try? output.close()
            try? errors.close()
            try? input?.close()
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
        let result = Result(
            out: try boundedStream(at: outputURL, byteLimit: limits.stdoutBytes),
            err: try boundedStream(at: errorURL, byteLimit: limits.stderrBytes)
        )
        // A failed command may still return bounded diagnostics for the caller
        // to classify. A successful command must never be parsed as if its
        // truncated head and tail were the complete protocol response.
        if process.terminationStatus == 0 {
            if result.out.isTruncated {
                throw Failure.outputLimitExceeded(
                    stream: "stdout",
                    totalBytes: result.out.totalByteCount,
                    retainedBytes: result.out.retainedByteCount
                )
            }
            if result.err.isTruncated {
                throw Failure.outputLimitExceeded(
                    stream: "stderr",
                    totalBytes: result.err.totalByteCount,
                    retainedBytes: result.err.retainedByteCount
                )
            }
        }
        return result
    }

    private static func boundedStream(at url: URL, byteLimit: Int) throws -> Stream {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        let limit = max(0, byteLimit)
        guard total > UInt64(limit) else {
            try handle.seek(toOffset: 0)
            return Stream(
                head: try handle.read(upToCount: Int(total)) ?? Data(),
                tail: Data(),
                totalByteCount: total
            )
        }
        let headLimit = (limit + 1) / 2
        let tailLimit = limit - headLimit
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: headLimit) ?? Data()
        try handle.seek(toOffset: total - UInt64(tailLimit))
        let tail = try handle.read(upToCount: tailLimit) ?? Data()
        return Stream(head: head, tail: tail, totalByteCount: total)
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
    private let checkpointDate: String?

    /// Failure diagnostics are rendered in the Git panel, so a noisy hook must
    /// not turn one rejection into an unbounded banner. The allowance is shared
    /// fairly when Git gives us both streams, while a lone stream can use it all.
    private static let failureOutputByteLimit = GitProcessCapture.diagnosticByteLimit

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
        self.checkpointDate = nil
    }

    #if DEBUG
    /// Process-scoped determinism for collision tests. Unlike `setenv`, this
    /// cannot race Git subprocesses launched by another XCTest.
    init(repoRoot: URL, checkpointDate: String) {
        self.repoRoot = repoRoot
        self.checkpointDate = checkpointDate
    }
    #endif

    /// A restorable snapshot and the exact private ref that keeps it alive.
    /// The commit may be shared by several conversations, but the ref never is.
    struct Checkpoint: Equatable, Sendable {
        let commitHash: String
        let keepAliveRef: String

        /// Capabilities are minted only by GitService after constructing and
        /// validating the complete v2 ref; other app code cannot forge a token
        /// for an arbitrary ref such as a branch or legacy quarantine entry.
        fileprivate init(commitHash: String, keepAliveRef: String) {
            self.commitHash = commitHash
            self.keepAliveRef = keepAliveRef
        }
    }

    struct Status: Equatable, Sendable {
        var branch: String?
        var ahead: Int
        var behind: Int
        var staged: [Entry]
        var unstaged: [Entry]
        var untracked: [String]
        var stagedStats: ChangeStats = .empty
        var unstagedStats: ChangeStats = .empty
        var combinedStats: ChangeStats = .empty

        var isClean: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty }
    }

    /// Line counts from one `git diff --numstat` view. Binary entries are
    /// tracked separately because Git deliberately reports `-\t-`; turning
    /// those markers into zero lines would invent precision the diff lacks.
    struct ChangeStats: Equatable, Sendable {
        let additions: Int
        let deletions: Int
        let textFiles: Int
        let binaryFiles: Int

        init(additions: Int = 0, deletions: Int = 0, textFiles: Int = 0, binaryFiles: Int = 0) {
            self.additions = additions
            self.deletions = deletions
            self.textFiles = textFiles
            self.binaryFiles = binaryFiles
        }

        static let empty = ChangeStats()
    }

    struct Entry: Equatable, Identifiable, Sendable {
        let path: String
        let code: String
        let originalPath: String?

        init(path: String, code: String, originalPath: String? = nil) {
            self.path = path
            self.code = code
            self.originalPath = originalPath
        }

        var id: String { path }
    }

    enum ReviewKind: String, CaseIterable, Identifiable, Sendable {
        case staged
        case unstaged

        var id: String { rawValue }
        var title: String { self == .staged ? "Staged" : "Unstaged" }
    }

    enum ReviewFileState: Equatable, Sendable {
        case text
        case binary
        case renamed(from: String)
        case conflicted
        case submodule
        case untracked
        case noTextualChanges

        var summary: String {
            switch self {
            case .text: "Text changes"
            case .binary: "Binary file — review and act on the whole file"
            case let .renamed(from): "Renamed from \(from)"
            case .conflicted: "Resolve the conflict before reviewing hunks"
            case .submodule: "Submodule commit changed — review and act on the whole entry"
            case .untracked: "Untracked file — stage the whole file to review it"
            case .noTextualChanges: "No textual hunks — review and act on the whole file"
            }
        }
    }

    struct ReviewHunk: Equatable, Identifiable, Sendable {
        let id: String
        let path: String
        let kind: ReviewKind
        let header: String
        let oldStart: Int
        let newStart: Int
        let sectionHeading: String
        let lines: [String]
        fileprivate let patch: String

        var anchorID: String { "hunk:\(id)" }
        var displayPatch: String { ([header] + lines).joined(separator: "\n") }
    }

    struct ReviewFile: Equatable, Identifiable, Sendable {
        let path: String
        let code: String
        let originalPath: String?
        let state: ReviewFileState
        let hunks: [ReviewHunk]

        init(
            path: String,
            code: String,
            originalPath: String? = nil,
            state: ReviewFileState,
            hunks: [ReviewHunk]
        ) {
            self.path = path
            self.code = code
            self.originalPath = originalPath
            self.state = state
            self.hunks = hunks
        }

        var id: String { path }
        var anchorID: String { "file:\(path)" }
    }

    struct ReviewSurface: Equatable, Sendable {
        let repoName: String
        let kind: ReviewKind
        let files: [ReviewFile]

        var hunkCount: Int { files.reduce(0) { $0 + $1.hunks.count } }
    }

    struct ReviewSurfaces: Equatable, Sendable {
        let staged: ReviewSurface
        let unstaged: ReviewSurface

        subscript(kind: ReviewKind) -> ReviewSurface {
            kind == .staged ? staged : unstaged
        }
    }

    enum ReviewAction: String, Sendable {
        case stage
        case unstage
        case restore

        var operationVerb: String {
            switch self {
            case .stage: "Staging"
            case .unstage: "Unstaging"
            case .restore: "Discarding"
            }
        }
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
            case let .outputLimitExceeded(stream, totalBytes, retainedBytes):
                .commandFailed(
                    "\(command) produced \(totalBytes) \(stream) bytes; "
                        + "retained \(retainedBytes) bytes at its output limit. "
                        + "Narrow the operation and try again."
                )
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
        let statusArguments = [
            "--no-optional-locks", "status", "--porcelain=v2", "-z", "--branch", "--find-renames=50%"
        ]
        // Stats require three independent Git views. Fence them with the same
        // porcelain snapshot: if an external stage/commit lands between those
        // reads, retry instead of publishing counters from different index
        // generations together. The model then assigns this whole value once.
        for _ in 0 ..< 3 {
            let before = try run(statusArguments)
            let stagedStats = try numstat(staged: true)
            let unstagedStats = try numstat(staged: false)
            let combinedStats: ChangeStats
            do {
                combinedStats = try numstatAgainstHead()
            } catch let GitError.commandFailed(message)
                where message.contains("ambiguous argument 'HEAD'") || message.contains("bad revision 'HEAD'") {
                // `git diff HEAD` has no base in an unborn repository. Diff
                // against this repository's own empty-tree object so a file
                // split across index and worktree is still one combined entry.
                combinedStats = try numstatAgainstEmptyTree()
            }
            let after = try run(statusArguments)
            guard before == after else { continue }
            return Self.parseStatus(
                before,
                stagedStats: stagedStats,
                unstagedStats: unstagedStats,
                combinedStats: combinedStats
            )
        }
        throw GitError.commandFailed("Repository changed repeatedly while Git status was refreshing. Refresh again.")
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

    /// One repository-wide staged/unstaged review snapshot. Each side is
    /// derived from the same porcelain status value, so a rename, conflict, or
    /// untracked entry cannot disappear merely because Git emits no ordinary
    /// unified hunk for it.
    func reviewSurfaces(status suppliedStatus: Status? = nil) throws -> ReviewSurfaces {
        let snapshot = try suppliedStatus ?? status()
        let repoName = repoRoot.lastPathComponent.isEmpty ? repoRoot.path : repoRoot.lastPathComponent
        return ReviewSurfaces(
            staged: try reviewSurface(repoName: repoName, kind: .staged, status: snapshot),
            unstaged: try reviewSurface(repoName: repoName, kind: .unstaged, status: snapshot)
        )
    }

    private func reviewSurface(repoName: String, kind: ReviewKind, status: Status) throws -> ReviewSurface {
        var arguments = [
            "--no-optional-locks", "diff", "--no-ext-diff", "--no-textconv", "--no-color",
            "--find-renames=50%", "--submodule=short", "--unified=3",
        ]
        if kind == .staged { arguments.append("--cached") }
        let patch = try run(arguments)
        return Self.parseReviewSurface(
            repoName: repoName,
            kind: kind,
            patch: patch,
            entries: kind == .staged ? status.staged : status.unstaged,
            untracked: kind == .unstaged ? status.untracked : []
        )
    }

    /// Apply only the exact Git-produced hunk the reviewer selected. Context
    /// verification makes a stale hunk fail rather than touching newer bytes.
    /// The patch is generated internally and the path is separately confined
    /// before Git sees stdin.
    func applyReviewAction(_ action: ReviewAction, to hunk: ReviewHunk) throws {
        try guardPath(hunk.path)
        let valid: Bool
        switch (action, hunk.kind) {
        case (.stage, .unstaged), (.restore, .unstaged), (.unstage, .staged): valid = true
        default: valid = false
        }
        guard valid else {
            throw GitError.commandFailed("That hunk action is not valid in the \(hunk.kind.title.lowercased()) review.")
        }

        var arguments = ["apply", "--recount", "--whitespace=nowarn"]
        if action == .stage || action == .unstage { arguments.append("--cached") }
        if action == .unstage || action == .restore { arguments.append("--reverse") }
        arguments.append("--")
        _ = try run(arguments, standardInput: hunk.patch)
    }

    /// Whole-file fallback for entries that do not have truthful textual hunks.
    /// A rename is one logical row but two index paths; stage/unstage both in a
    /// single Git invocation so it can never become half-applied.
    func applyReviewAction(_ action: ReviewAction, to file: ReviewFile) throws {
        let paths = [file.originalPath, file.path].compactMap { $0 }
        for path in paths { try guardPath(path) }
        switch action {
        case .stage:
            _ = try run(["add", "--all", "--"] + paths)
        case .unstage:
            _ = try run(["restore", "--staged", "--"] + paths)
        case .restore:
            guard file.originalPath == nil, file.state != .untracked, file.state != .conflicted else {
                throw GitError.commandFailed("That file cannot be discarded safely from this review state.")
            }
            _ = try run(["restore", "--", file.path])
        }
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

    /// Snapshot the working tree without moving HEAD or touching the index.
    /// `git stash create` writes the stash commit and returns its hash but
    /// stores nothing, so the tree is untouched. Returns nil on a clean tree.
    ///
    /// Snapshot commits are content-addressed: two chats can legitimately get
    /// the same hash. Their keep-alive refs therefore include a stable owner
    /// digest, a per-live-conversation incarnation, and the turn rather than
    /// using the hash as the entire ref name.
    func checkpoint(ownerID: String, incarnationID: UUID, turn: Int) throws -> Checkpoint? {
        try validateCheckpointOwner(ownerID, turn: turn)
        // Old builds used one hash-only ref for every logical owner. Quarantine
        // those refs atomically before writing v2 state so migration is safe
        // even while another process still holds only the commit hash.
        try migrateLegacyCheckpointRefs()
        var environmentOverrides: [String: String] = [:]
        if let checkpointDate {
            environmentOverrides["GIT_AUTHOR_DATE"] = checkpointDate
            environmentOverrides["GIT_COMMITTER_DATE"] = checkpointDate
        }
        let hash = try run(
            ["stash", "create", "kaisola pre-turn checkpoint"],
            environmentOverrides: environmentOverrides
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return nil }
        return try retainCheckpoint(
            commitHash: hash,
            ownerID: ownerID,
            incarnationID: incarnationID,
            turn: turn
        )
    }

    private func retainCheckpoint(
        commitHash: String,
        ownerID: String,
        incarnationID: UUID,
        turn: Int
    ) throws -> Checkpoint {
        try validateCheckpointOwner(ownerID, turn: turn)

        let normalizedHash = commitHash.lowercased()
        try validateObjectID(normalizedHash)
        try requireCommitObject(normalizedHash)
        let ownerDigest = SHA256.hash(data: Data(ownerID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let incarnation = incarnationID.uuidString.lowercased()
        let keepAliveRef = "\(Self.checkpointV2Prefix)\(ownerDigest)/\(incarnation)/\(turn)-\(normalizedHash)"
        try createRefIfAbsent(keepAliveRef, target: normalizedHash)
        return Checkpoint(commitHash: normalizedHash, keepAliveRef: keepAliveRef)
    }

    /// Release only the aged-out logical owner's keep-alive ref. Supplying the
    /// expected object id makes deletion fail closed if another process moved
    /// or replaced the ref after it was read.
    func dropCheckpoint(_ checkpoint: Checkpoint) throws {
        try validate(checkpoint)
        try deleteRefIfMatching(checkpoint.keepAliveRef, expectedTarget: checkpoint.commitHash)
    }

    /// Restore the files recorded in a checkpoint over the current tree.
    func applyCheckpoint(_ checkpoint: Checkpoint) throws {
        try validate(checkpoint)
        try requireCommitObject(checkpoint.commitHash)
        _ = try run(["stash", "apply", checkpoint.commitHash])
    }

    /// Move unowned hash-only refs into a reserved keep-alive namespace. The
    /// original conversation and turn were never stored, so legacy copies are
    /// deliberately not garbage-collected automatically.
    func migrateLegacyCheckpointRefs() throws {
        let expectedObjectIDLength = try objectIDLength()
        let refs = try checkpointRefStates()
        for (ref, state) in refs.sorted(by: { $0.key < $1.key }) {
            guard ref.hasPrefix(Self.checkpointPrefix) else { continue }
            let suffix = String(ref.dropFirst(Self.checkpointPrefix.count))
            guard state.symbolicTarget == nil,
                  !suffix.contains("/"),
                  suffix.count == expectedObjectIDLength,
                  Self.isFullObjectID(suffix),
                  suffix == state.objectID else { continue }
            do { try requireCommitObject(suffix) }
            catch { continue }

            try migrateLegacyCheckpointRef(ref, objectID: suffix)
        }
    }

    private static let checkpointPrefix = "refs/kaisola/checkpoints/"
    private static let checkpointV2Prefix = "refs/kaisola/checkpoints/v2/"
    private static let checkpointLegacyPrefix = "refs/kaisola/checkpoints/legacy/"

    private static func isFullObjectID(_ value: String) -> Bool {
        value.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil
    }

    private func validateCheckpointOwner(_ ownerID: String, turn: Int) throws {
        guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.commandFailed("Checkpoint owner is required")
        }
        guard turn > 0 else {
            throw GitError.commandFailed("Checkpoint turn must be positive")
        }
    }

    private func validate(_ checkpoint: Checkpoint) throws {
        try validateObjectID(checkpoint.commitHash)
        guard checkpoint.keepAliveRef.hasPrefix(Self.checkpointV2Prefix) else {
            throw GitError.commandFailed("Invalid checkpoint id")
        }

        let relative = String(checkpoint.keepAliveRef.dropFirst(Self.checkpointV2Prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              UUID(uuidString: String(components[1]))?.uuidString.lowercased() == String(components[1]) else {
            throw GitError.commandFailed("Invalid checkpoint id")
        }

        let expectedSuffix = "-\(checkpoint.commitHash)"
        let checkpointName = String(components[2])
        guard checkpointName.hasSuffix(expectedSuffix) else {
            throw GitError.commandFailed("Checkpoint ref does not match its commit")
        }
        let turnText = String(checkpointName.dropLast(expectedSuffix.count))
        guard let turn = Int(turnText), turn > 0, String(turn) == turnText else {
            throw GitError.commandFailed("Invalid checkpoint turn")
        }
    }

    private func validateObjectID(_ value: String) throws {
        let expectedLength = try objectIDLength()
        guard value.count == expectedLength, Self.isFullObjectID(value) else {
            throw GitError.commandFailed("Invalid checkpoint id")
        }
    }

    private func objectIDLength() throws -> Int {
        let objectFormat = try run(["rev-parse", "--show-object-format"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch objectFormat {
        case "sha1": return 40
        case "sha256": return 64
        default: throw GitError.commandFailed("Unsupported Git object format: \(objectFormat)")
        }
    }

    private func requireCommitObject(_ objectID: String) throws {
        _ = try run(["cat-file", "-e", "\(objectID)^{commit}"])
    }

    /// Atomically establish/verify the quarantine ref and remove the old name.
    /// A separate copy then delete would leave a gap if another process removed
    /// the destination between those commands. The transaction either applies
    /// both updates or neither; bounded retries accept only a safely converged
    /// state produced by another migrator.
    private func migrateLegacyCheckpointRef(_ sourceRef: String, objectID: String) throws {
        let preservedRef = "\(Self.checkpointLegacyPrefix)\(objectID)"
        for _ in 0..<3 {
            let states = try checkpointRefStates()
            let source = states[sourceRef]
            let destination = states[preservedRef]

            if source == nil {
                guard destination?.symbolicTarget == nil,
                      destination?.objectID == objectID else {
                    throw GitError.commandFailed("Legacy checkpoint migration lost its keep-alive ref")
                }
                return
            }
            guard source?.symbolicTarget == nil, source?.objectID == objectID else {
                throw GitError.commandFailed("Legacy checkpoint ref changed during migration")
            }

            let destinationCommand: String
            if destination == nil {
                destinationCommand = "create \(preservedRef) \(objectID)"
            } else if destination?.symbolicTarget == nil, destination?.objectID == objectID {
                destinationCommand = "verify \(preservedRef) \(objectID)"
            } else {
                throw GitError.commandFailed("Legacy checkpoint destination conflicts with its object")
            }

            let transaction = """
            start
            \(destinationCommand)
            delete \(sourceRef) \(objectID)
            prepare
            commit

            """
            do {
                _ = try run(
                    ["update-ref", "--stdin", "--no-deref"],
                    standardInput: transaction
                )
                return
            } catch {
                let refreshed = try checkpointRefStates()
                if refreshed[sourceRef] == nil,
                   refreshed[preservedRef]?.symbolicTarget == nil,
                   refreshed[preservedRef]?.objectID == objectID {
                    return
                }
                // A competing migrator may have created the destination while
                // leaving this source for our next verify-and-delete attempt.
                continue
            }
        }
        throw GitError.commandFailed("Legacy checkpoint migration did not converge")
    }

    /// Create a ref without overwriting a concurrent owner. A retry that finds
    /// the exact desired target is idempotent; any other target is a collision.
    private func createRefIfAbsent(_ ref: String, target: String) throws {
        let zeroObjectID = String(repeating: "0", count: target.count)
        do {
            _ = try run(["update-ref", "--no-deref", ref, target, zeroObjectID])
        } catch {
            let current = try checkpointRefStates()[ref]
            guard current?.symbolicTarget == nil, current?.objectID == target else {
                throw GitError.commandFailed("Checkpoint ref already exists with a different target")
            }
        }
    }

    /// Idempotent compare-and-delete. A concurrent deletion is success; a
    /// changed target is never removed.
    private func deleteRefIfMatching(_ ref: String, expectedTarget: String) throws {
        guard let current = try checkpointRefStates()[ref] else { return }
        guard current.symbolicTarget == nil, current.objectID == expectedTarget else {
            throw GitError.commandFailed("Checkpoint ref changed before deletion")
        }
        do {
            _ = try run(["update-ref", "--no-deref", "-d", ref, expectedTarget])
        } catch {
            if try checkpointRefStates()[ref] == nil { return }
            throw error
        }
    }

    private struct CheckpointRefState {
        let objectID: String
        let symbolicTarget: String?
    }

    private func checkpointRefStates() throws -> [String: CheckpointRefState] {
        let output = try run([
            "for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(symref)",
            Self.checkpointPrefix,
        ])
        var refs: [String: CheckpointRefState] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let ref = String(fields[0])
            let target = String(fields[1]).lowercased()
            guard ref.hasPrefix(Self.checkpointPrefix), Self.isFullObjectID(target) else { continue }
            let symbolicTarget = fields[2].isEmpty ? nil : String(fields[2])
            refs[ref] = CheckpointRefState(objectID: target, symbolicTarget: symbolicTarget)
        }
        return refs
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

    private struct ReviewPatchSection {
        let lines: [String]

        var text: String { lines.joined(separator: "\n") }
    }

    static func parseReviewSurface(
        repoName: String,
        kind: ReviewKind,
        patch: String,
        entries: [Entry],
        untracked: [String] = []
    ) -> ReviewSurface {
        let sections = reviewPatchSections(patch)
        var unusedSections = Set(sections.indices)
        var files: [ReviewFile] = []

        for entry in entries {
            let sectionIndex = unusedSections.first(where: { index in
                let paths = reviewPaths(in: sections[index])
                return paths.contains(entry.path) || entry.originalPath.map(paths.contains) == true
            })
            let section = sectionIndex.map { sections[$0] }
            if let sectionIndex { unusedSections.remove(sectionIndex) }
            let state = reviewFileState(entry: entry, section: section)
            let hunks = state == .text
                ? reviewHunks(path: entry.path, kind: kind, section: section)
                : []
            files.append(ReviewFile(
                path: entry.path,
                code: entry.code,
                originalPath: entry.originalPath,
                state: state,
                hunks: hunks
            ))
        }
        if kind == .unstaged {
            files.append(contentsOf: untracked.map {
                ReviewFile(path: $0, code: "?", state: .untracked, hunks: [])
            })
        }
        return ReviewSurface(repoName: repoName, kind: kind, files: files)
    }

    private static func reviewPatchSections(_ patch: String) -> [ReviewPatchSection] {
        guard !patch.isEmpty else { return [] }
        var sections: [ReviewPatchSection] = []
        var current: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let beginsSection = line.hasPrefix("diff --git ")
                || line.hasPrefix("diff --cc ")
                || line.hasPrefix("diff --combined ")
            if beginsSection, !current.isEmpty {
                sections.append(ReviewPatchSection(lines: current))
                current = []
            }
            if beginsSection || !current.isEmpty { current.append(line) }
        }
        if !current.isEmpty { sections.append(ReviewPatchSection(lines: current)) }
        return sections
    }

    private static func reviewPaths(in section: ReviewPatchSection) -> Set<String> {
        var paths: Set<String> = []
        for line in section.lines {
            if line.hasPrefix("+++ "), let path = reviewPathField(String(line.dropFirst(4))) {
                paths.insert(path)
            } else if line.hasPrefix("--- "), let path = reviewPathField(String(line.dropFirst(4))) {
                paths.insert(path)
            } else if line.hasPrefix("rename to "),
                      let path = decodedGitQuotedPath(String(line.dropFirst("rename to ".count))) {
                paths.insert(path)
            } else if line.hasPrefix("rename from "),
                      let path = decodedGitQuotedPath(String(line.dropFirst("rename from ".count))) {
                paths.insert(path)
            } else if line.hasPrefix("diff --cc "),
                      let path = decodedGitQuotedPath(String(line.dropFirst("diff --cc ".count))) {
                paths.insert(path)
            } else if line.hasPrefix("diff --combined "),
                      let path = decodedGitQuotedPath(String(line.dropFirst("diff --combined ".count))) {
                paths.insert(path)
            } else if line.hasPrefix("diff --git "),
                      let destination = line.range(of: " b/", options: .backwards),
                      let path = reviewPathField(String(line[destination.lowerBound...].dropFirst())) {
                paths.insert(path)
            }
        }
        return paths
    }

    private static func reviewPathField(_ field: String) -> String? {
        let value: String
        if field.hasPrefix("\"") {
            value = field
        } else {
            value = field.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? field
        }
        guard let decoded = decodedGitQuotedPath(value), decoded != "/dev/null" else { return nil }
        if decoded.hasPrefix("a/") || decoded.hasPrefix("b/") { return String(decoded.dropFirst(2)) }
        return decoded
    }

    /// Git C-quotes paths containing control, tab, quote, backslash, or
    /// non-ASCII bytes. Decode the exact byte grammar instead of splitting a
    /// user-controlled filename on whitespace.
    private static func decodedGitQuotedPath(_ value: String) -> String? {
        guard value.hasPrefix("\"") else { return value }
        let bytes = Array(value.utf8)
        guard bytes.count >= 2, bytes.last == 34 else { return nil }
        var decoded: [UInt8] = []
        var index = 1
        while index < bytes.count - 1 {
            let byte = bytes[index]
            guard byte == 92 else {
                decoded.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count - 1 else { return nil }
            let escaped = bytes[index]
            switch escaped {
            case 110: decoded.append(0x0A); index += 1
            case 114: decoded.append(0x0D); index += 1
            case 116: decoded.append(0x09); index += 1
            case 92, 34:
                decoded.append(escaped); index += 1
            case 48 ... 55:
                var octal = 0
                var digits = 0
                while index < bytes.count - 1,
                      digits < 3,
                      bytes[index] >= 48,
                      bytes[index] <= 55 {
                    octal = (octal * 8) + Int(bytes[index] - 48)
                    index += 1
                    digits += 1
                }
                guard octal <= 255 else { return nil }
                decoded.append(UInt8(octal))
            default:
                decoded.append(escaped)
                index += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private static func reviewFileState(entry: Entry, section: ReviewPatchSection?) -> ReviewFileState {
        let text = section?.text ?? ""
        if entry.code == "U" || text.hasPrefix("diff --cc ") || text.hasPrefix("diff --combined ") {
            return .conflicted
        }
        if let originalPath = entry.originalPath {
            return .renamed(from: originalPath)
        }
        if entry.code == "R" || entry.code == "C" || text.contains("\nrename from ") {
            return .renamed(from: "another path")
        }
        if text.contains(" 160000\n") || text.contains("Subproject commit ") {
            return .submodule
        }
        if text.contains("Binary files ") || text.contains("GIT binary patch") {
            return .binary
        }
        guard let section else { return .noTextualChanges }
        return section.lines.contains(where: { $0.hasPrefix("@@ ") }) ? .text : .noTextualChanges
    }

    private static func reviewHunks(
        path: String,
        kind: ReviewKind,
        section: ReviewPatchSection?
    ) -> [ReviewHunk] {
        guard let section,
              let firstHunk = section.lines.firstIndex(where: { $0.hasPrefix("@@ ") }) else { return [] }
        let prefix = Array(section.lines[..<firstHunk])
        let starts = section.lines.indices.filter { section.lines[$0].hasPrefix("@@ ") }
        let regex = try! NSRegularExpression(
            pattern: #"^@@ -([0-9]+)(?:,[0-9]+)? \+([0-9]+)(?:,[0-9]+)? @@(?: ?(.*))?$"#
        )
        return starts.enumerated().compactMap { ordinal, start in
            let end = ordinal + 1 < starts.count ? starts[ordinal + 1] : section.lines.endIndex
            let header = section.lines[start]
            let range = NSRange(header.startIndex..., in: header)
            guard let match = regex.firstMatch(in: header, range: range),
                  let oldRange = Range(match.range(at: 1), in: header),
                  let newRange = Range(match.range(at: 2), in: header),
                  let oldStart = Int(header[oldRange]),
                  let newStart = Int(header[newRange]) else { return nil }
            let heading: String
            if match.range(at: 3).location != NSNotFound,
               let headingRange = Range(match.range(at: 3), in: header) {
                heading = header[headingRange].trimmingCharacters(in: .whitespaces)
            } else {
                heading = ""
            }
            let lines = Array(section.lines[section.lines.index(after: start) ..< end])
            var patch = (prefix + [header] + lines).joined(separator: "\n")
            if !patch.hasSuffix("\n") { patch.append("\n") }
            return ReviewHunk(
                id: "\(kind.rawValue):\(path):\(oldStart):\(newStart):\(ordinal)",
                path: path,
                kind: kind,
                header: header,
                oldStart: oldStart,
                newStart: newStart,
                sectionHeading: heading,
                lines: lines,
                patch: patch
            )
        }
    }

    static func parseStatus(
        _ output: String,
        stagedStats: ChangeStats = .empty,
        unstagedStats: ChangeStats = .empty,
        combinedStats: ChangeStats = .empty
    ) -> Status {
        var status = Status(
            branch: nil,
            ahead: 0,
            behind: 0,
            staged: [],
            unstaged: [],
            untracked: [],
            stagedStats: stagedStats,
            unstagedStats: unstagedStats,
            combinedStats: combinedStats
        )
        let records = output.split(separator: "\0", omittingEmptySubsequences: false)
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("# branch.head "),
               let (_, value) = statusFields(record, fixedFieldCount: 2) {
                status.branch = String(value)
            } else if record.hasPrefix("# branch.ab "),
                      let (fields, behind) = statusFields(record, fixedFieldCount: 3) {
                status.ahead = Int(fields[2].dropFirst()) ?? 0
                status.behind = Int(behind.dropFirst()) ?? 0
            } else if record.hasPrefix("1 "),
                      let (fields, path) = statusFields(record, fixedFieldCount: 8) {
                appendStatusEntries(
                    xy: fields[1],
                    path: String(path),
                    originalPath: nil,
                    to: &status
                )
            } else if record.hasPrefix("2 "),
                      let (fields, path) = statusFields(record, fixedFieldCount: 9),
                      index + 1 < records.count {
                let originalPath = String(records[index + 1])
                appendStatusEntries(
                    xy: fields[1],
                    path: String(path),
                    originalPath: originalPath,
                    to: &status
                )
                // With `-z`, Git writes the rename/copy source as the next NUL
                // record. Consume it even when it resembles another status row.
                index += 1
            } else if record.hasPrefix("u "),
                      let (fields, path) = statusFields(record, fixedFieldCount: 10) {
                appendStatusEntries(
                    xy: fields[1],
                    path: String(path),
                    originalPath: nil,
                    to: &status
                )
            } else if record.hasPrefix("? "),
                      let (_, path) = statusFields(record, fixedFieldCount: 1) {
                status.untracked.append(String(path))
            }
            // `!` records are ignored by design. This status command does not
            // request ignored files, but accepting them keeps parsing aligned
            // if the caller ever adds `--ignored`.
            index += 1
        }
        return status
    }

    /// Consume exactly the fixed ASCII-space-delimited fields at the front of
    /// a porcelain record and leave the decoded remainder unchanged as its
    /// path or value. Newlines, tabs, quotes, backslashes, and leading spaces
    /// in paths are data, never separators in `-z` mode.
    private static func statusFields(
        _ record: Substring,
        fixedFieldCount: Int
    ) -> (fields: [Substring], remainder: Substring)? {
        var fields: [Substring] = []
        var remainder = record
        for _ in 0 ..< fixedFieldCount {
            guard let separator = remainder.firstIndex(of: " ") else { return nil }
            let field = remainder[..<separator]
            guard !field.isEmpty else { return nil }
            fields.append(field)
            remainder = remainder[remainder.index(after: separator)...]
        }
        return (fields, remainder)
    }

    private static func appendStatusEntries(
        xy: Substring,
        path: String,
        originalPath: String?,
        to status: inout Status
    ) {
        let x = xy.first.map(String.init) ?? "."
        let y = xy.dropFirst().first.map(String.init) ?? "."
        if x != "." {
            status.staged.append(Entry(path: path, code: x, originalPath: originalPath))
        }
        if y != "." {
            status.unstaged.append(Entry(path: path, code: y, originalPath: originalPath))
        }
    }

    /// Parse NUL-delimited numstat records. A rename has an empty pathname in
    /// its stat record followed by separate old/new path records; skipping both
    /// keeps tabs inside filenames from ever being mistaken for another stat.
    static func parseNumstat(_ output: String) throws -> ChangeStats {
        let records = output.split(separator: "\0", omittingEmptySubsequences: false)
        var additions = 0
        var deletions = 0
        var textFiles = 0
        var binaryFiles = 0
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.isEmpty {
                index += 1
                continue
            }
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                throw GitError.commandFailed("Could not parse Git diff statistics.")
            }
            if fields[0] == "-", fields[1] == "-" {
                binaryFiles += 1
            } else {
                guard let added = Int(fields[0]), let deleted = Int(fields[1]) else {
                    throw GitError.commandFailed("Could not parse Git diff statistics.")
                }
                additions += added
                deletions += deleted
                textFiles += 1
            }
            index += fields[2].isEmpty ? 3 : 1
        }
        return ChangeStats(
            additions: additions,
            deletions: deletions,
            textFiles: textFiles,
            binaryFiles: binaryFiles
        )
    }

    // MARK: - Process

    private func numstat(staged: Bool) throws -> ChangeStats {
        var arguments = [
            "--no-optional-locks", "diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv",
            "--find-renames=50%"
        ]
        if staged { arguments.append("--cached") }
        return try Self.parseNumstat(run(arguments))
    }

    private func numstatAgainstHead() throws -> ChangeStats {
        try Self.parseNumstat(run([
            "--no-optional-locks", "diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv",
            "--find-renames=50%", "HEAD"
        ]))
    }

    private func numstatAgainstEmptyTree() throws -> ChangeStats {
        // Derive this rather than baking in SHA-1's well-known empty-tree OID;
        // repositories initialized with SHA-256 have a different object ID.
        let emptyTree = try run(["hash-object", "-t", "tree", "/dev/null"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try Self.parseNumstat(run([
            "--no-optional-locks", "diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv",
            "--find-renames=50%", emptyTree
        ]))
    }

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
    private func run(
        _ arguments: [String],
        environmentOverrides: [String: String] = [:],
        standardInput: String? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repoRoot
        GitProcessEnvironment.configureNonInteractive(process)
        if !environmentOverrides.isEmpty {
            var environment = process.environment ?? ProcessInfo.processInfo.environment
            for (key, value) in environmentOverrides { environment[key] = value }
            process.environment = environment
        }
        let capture: GitProcessCapture.Result
        do {
            capture = try GitProcessCapture.run(
                process,
                standardInput: standardInput.map { Data($0.utf8) },
                deadline: .forGitArguments(arguments),
                limits: .forGitArguments(arguments)
            )
        }
        catch let failure as GitProcessCapture.Failure {
            throw GitError.from(failure, command: Self.commandLabel(arguments))
        }
        catch { throw GitError.commandFailed(error.localizedDescription) }
        if process.terminationStatus != 0 {
            let stdout = capture.out.diagnosticText(byteLimit: GitProcessCapture.diagnosticByteLimit)
            let stderr = capture.err.diagnosticText(byteLimit: GitProcessCapture.diagnosticByteLimit)
            if stdout.contains("not a git repository") || stderr.contains("not a git repository") {
                throw GitError.notARepository
            }
            throw GitError.commandFailed(Self.commandFailureMessage(
                arguments: arguments,
                status: process.terminationStatus,
                stdout: capture.out,
                stderr: capture.err
            ))
        }
        return String(data: capture.out.completeData ?? Data(), encoding: .utf8) ?? ""
    }

    /// A stable, bounded explanation for a Git rejection. Both stdout and
    /// stderr are retained because hooks legitimately use either; the exit
    /// status distinguishes a policy rejection from an ordinary Git message.
    private static func commandFailureMessage(
        arguments: [String],
        status: Int32,
        stdout: GitProcessCapture.Stream,
        stderr: GitProcessCapture.Stream
    ) -> String {
        let budgets = failureOutputBudgets(
            stdoutBytes: Int(min(UInt64(Int.max), stdout.totalByteCount)),
            stderrBytes: Int(min(UInt64(Int.max), stderr.totalByteCount))
        )
        var sections = ["\(commandLabel(arguments)) exited with status \(status)."]
        if let rendered = boundedFailureOutput(stdout, byteLimit: budgets.stdout) {
            sections.append("stdout:\n\(rendered)")
        }
        if let rendered = boundedFailureOutput(stderr, byteLimit: budgets.stderr) {
            sections.append("stderr:\n\(rendered)")
        }
        if sections.count == 1 { sections.append("No output was produced.") }
        return sections.joined(separator: "\n\n")
    }

    private static func failureOutputBudgets(
        stdoutBytes: Int,
        stderrBytes: Int
    ) -> (stdout: Int, stderr: Int) {
        guard stdoutBytes > 0 else { return (0, min(stderrBytes, failureOutputByteLimit)) }
        guard stderrBytes > 0 else { return (min(stdoutBytes, failureOutputByteLimit), 0) }

        var stdoutBudget = min(stdoutBytes, failureOutputByteLimit / 2)
        var stderrBudget = min(stderrBytes, failureOutputByteLimit / 2)
        var spare = failureOutputByteLimit - stdoutBudget - stderrBudget
        let extraStdout = min(spare, stdoutBytes - stdoutBudget)
        stdoutBudget += extraStdout
        spare -= extraStdout
        stderrBudget += min(spare, stderrBytes - stderrBudget)
        return (stdoutBudget, stderrBudget)
    }

    private static func boundedFailureOutput(
        _ stream: GitProcessCapture.Stream,
        byteLimit: Int
    ) -> String? {
        guard stream.totalByteCount > 0, byteLimit > 0 else { return nil }
        let rendered = stream.diagnosticText(byteLimit: byteLimit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rendered.isEmpty else { return nil }
        return rendered
    }

    /// "git status", "git push" — what a stopped command is called in the UI.
    /// Only the subcommand is included: the arguments can carry paths, branch
    /// names, and commit messages that do not belong in an error banner.
    static func commandLabel(_ arguments: [String]) -> String {
        guard let subcommand = GitDeadline.subcommand(of: arguments) else { return "git" }
        return "git \(subcommand)"
    }
}
