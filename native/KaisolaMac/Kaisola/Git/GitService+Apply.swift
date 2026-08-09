import Foundation

/// Integrate a Mesh column's diff into the base workspace. Split from
/// GitService.swift because it is the one WRITE that grafts external edits onto
/// the tree; it reuses only GitService's public surface (`repoRoot`,
/// `PatchApplyFailure`) and models its own `git` invocation on GitService's
/// private `run()` shape, confined to the repo root as its working directory.
extension GitService {
    /// Why an integration attempt ended the way it did. The case is decided from
    /// structural facts about the attempt — git's exit status, whether the index
    /// holds unmerged entries, whether the destination is a repository at all,
    /// whether it is writable — and never from the wording of git's stderr. The
    /// Mesh status line reads severity and recovery off this case, so a
    /// permission, repository, patch, or I/O failure can no longer be shown as
    /// quiet secondary text just because its message lacks the word "conflict".
    enum PatchApplyFailure: Error, LocalizedError, Equatable {
        /// The column had nothing to graft.
        case emptyPatch
        /// `--3way` grafted what it could and left git markers in these paths.
        case conflicted(paths: [String], detail: String)
        /// The destination is not a git repository (or its worktree is gone).
        case notARepository
        /// The destination directory refuses writes from this process.
        case permissionDenied(detail: String)
        /// git read the patch and refused it; the tree is untouched.
        case patchRejected(detail: String)
        /// The patch could not be staged on disk, or git never ran.
        case io(detail: String)
        /// git failed some other way; the exit status carries what it reported.
        case gitFailed(status: Int32, detail: String)

        var errorDescription: String? {
            switch self {
            case .emptyPatch:
                "Nothing to apply — the diff is empty."
            case let .conflicted(paths, _):
                "Applied with conflicts in \(Self.naming(paths)) — resolve the git markers (<<<<<<< / ======= / >>>>>>>) left in those files."
            case .notARepository:
                "The destination folder is not a git repository."
            case let .permissionDenied(detail):
                "The destination folder is not writable.\(Self.tail(detail))"
            case let .patchRejected(detail):
                "git refused this diff and left the project unchanged.\(Self.tail(detail))"
            case let .io(detail):
                "Could not run the integration.\(Self.tail(detail))"
            case let .gitFailed(status, detail):
                "git apply failed (exit \(status)).\(Self.tail(detail))"
            }
        }

        /// The conflicted paths, or an empty list for every other case. Callers
        /// that want to name the files never have to scrape the message.
        var conflictedPaths: [String] {
            if case let .conflicted(paths, _) = self { return paths }
            return []
        }

        /// Name at most two paths and count the rest, so a wide graft still fits
        /// one status line. Shared with the Mesh status line rather than being
        /// written twice.
        static func naming(_ paths: [String]) -> String {
            switch paths.count {
            case 0: "the affected files"
            case 1: paths[0]
            case 2: "\(paths[0]) and \(paths[1])"
            default: "\(paths[0]) and \(paths.count - 1) other files"
            }
        }

        private static func tail(_ detail: String) -> String {
            detail.isEmpty ? "" : "\n\(detail)"
        }
    }

    /// Apply a unified diff to the working tree with a 3-way merge, so another
    /// Mesh column's edits can be grafted onto the base workspace. The patch is
    /// written to a temp file and applied with `git apply --3way <file>`; on a
    /// partial application the conflicted files carry the usual git markers and
    /// the caller gets `.conflicted` with their paths. The git process runs with
    /// `repoRoot` as its cwd, and `git apply` refuses paths outside the working
    /// tree by default — so a patch cannot escape the repo.
    func applyPatch(_ patch: String) throws {
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PatchApplyFailure.emptyPatch
        }
        // git apply is strict about the final newline; ensure one.
        let contents = patch.hasSuffix("\n") ? patch : patch + "\n"
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mesh-apply-\(UUID().uuidString).patch")
        do {
            try contents.write(to: tempFile, atomically: true, encoding: .utf8)
        } catch {
            throw PatchApplyFailure.io(detail: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try runApply(["apply", "--3way", tempFile.path])
    }

    /// The one place an apply failure gets its kind. Every input is a structural
    /// fact about the attempt; none of them is git's prose, which is why a bland
    /// permission message and a chatty one classify the same.
    ///
    /// Order matters: unmerged index entries are the fingerprint of a 3-way
    /// graft that landed with markers, and that reading beats every other
    /// signal. `git apply` reserves exit 1 for "I read the patch and would not
    /// apply it"; anything else is git failing for its own reasons.
    static func classifyApplyFailure(
        status: Int32,
        unmergedPaths: [String],
        isRepository: Bool,
        destinationIsWritable: Bool,
        detail: String
    ) -> PatchApplyFailure {
        if !unmergedPaths.isEmpty {
            return .conflicted(paths: unmergedPaths, detail: detail)
        }
        if !isRepository { return .notARepository }
        if !destinationIsWritable { return .permissionDenied(detail: detail) }
        if status == 1 { return .patchRejected(detail: detail) }
        return .gitFailed(status: status, detail: detail)
    }

    /// A minimal `git` invocation confined to `repoRoot`. GitService.run() is
    /// private, so this mirrors its shape (same executable, cwd, capture)
    /// rather than reaching into it.
    private func runApply(_ arguments: [String]) throws {
        let result: (status: Int32, out: String, err: String)
        do { result = try runGitInRepo(arguments) } catch {
            throw PatchApplyFailure.io(detail: error.localizedDescription)
        }
        guard result.status != 0 else { return }
        let raw = result.err.isEmpty ? result.out : result.err
        throw Self.classifyApplyFailure(
            status: result.status,
            unmergedPaths: unmergedIndexPaths(),
            isRepository: isRepository(),
            destinationIsWritable: FileManager.default.isWritableFile(atPath: repoRoot.path),
            detail: raw.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Paths git left in an unmerged index stage. `git apply --3way` implies
    /// `--index`, so a graft that produced conflict markers always shows up
    /// here — a fact about the index rather than a phrase in stderr.
    private func unmergedIndexPaths() -> [String] {
        guard let result = try? runGitInRepo(["--no-optional-locks", "diff", "--name-only", "--diff-filter=U"]),
              result.status == 0 else { return [] }
        return result.out
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func isRepository() -> Bool {
        guard let result = try? runGitInRepo(["--no-optional-locks", "rev-parse", "--git-dir"]) else { return false }
        return result.status == 0
    }

    private func runGitInRepo(_ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repoRoot
        let capture = try GitProcessCapture.run(process)
        return (
            process.terminationStatus,
            String(data: capture.out, encoding: .utf8) ?? "",
            String(data: capture.err, encoding: .utf8) ?? ""
        )
    }
}
