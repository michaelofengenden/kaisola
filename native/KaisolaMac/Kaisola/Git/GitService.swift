import Foundation

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

        var errorDescription: String? {
            switch self {
            case .notARepository: "This folder is not a git repository."
            case let .commandFailed(message): message
            case .unsafePath: "Refused an unsafe path argument."
            }
        }
    }

    // MARK: - Reads

    func status() throws -> Status {
        let output = try run(["status", "--porcelain=v2", "--branch"])
        return Self.parseStatus(output)
    }

    func diff(path: String, staged: Bool) throws -> String {
        try guardPath(path)
        var args = ["diff"]
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

    @discardableResult
    func commit(message: String) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitError.commandFailed("Enter a commit message.") }
        _ = try run(["commit", "-m", trimmed])
        return try run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { throw GitError.commandFailed(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8) ?? "git failed"
            if message.contains("not a git repository") { throw GitError.notARepository }
            throw GitError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
