import Foundation

/// Integrate a Mesh column's diff into the base workspace. Split from
/// GitService.swift because it is the one WRITE that grafts external edits onto
/// the tree; it reuses only GitService's public surface (`repoRoot`, `GitError`)
/// and models its own `git` invocation on GitService's private `run()` shape,
/// confined to the repo root as its working directory.
extension GitService {
    /// Apply a unified diff to the working tree with a 3-way merge, so another
    /// Mesh column's edits can be grafted onto the base workspace. The patch is
    /// written to a temp file and applied with `git apply --3way <file>`; on a
    /// partial application the conflicted files carry the usual git markers,
    /// surfaced to the caller via a `.commandFailed` message. The git process
    /// runs with `repoRoot` as its cwd, and `git apply` refuses paths outside the
    /// working tree by default — so a patch cannot escape the repo.
    func applyPatch(_ patch: String) throws {
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.commandFailed("Nothing to apply — the diff is empty.")
        }
        // git apply is strict about the final newline; ensure one.
        let contents = patch.hasSuffix("\n") ? patch : patch + "\n"
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-mesh-apply-\(UUID().uuidString).patch")
        try contents.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try runApply(["apply", "--3way", tempFile.path])
    }

    /// A minimal `git` invocation confined to `repoRoot`. GitService.run() is
    /// private, so this mirrors its shape (same executable, cwd, stderr → error
    /// mapping) rather than reaching into it.
    private func runApply(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repoRoot
        let capture: (out: Data, err: Data)
        do { capture = try GitProcessCapture.run(process) } catch {
            throw GitError.commandFailed(error.localizedDescription)
        }
        guard process.terminationStatus != 0 else { return }
        let raw = String(data: capture.err, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            ?? String(data: capture.out, encoding: .utf8)
            ?? "git apply failed"
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.range(of: "conflict", options: .caseInsensitive) != nil {
            // --3way applied what it could and left conflict markers in the tree.
            throw GitError.commandFailed("Applied with conflicts — resolve the git markers (<<<<<<< / =======  / >>>>>>>) left in the affected files.\n\(message)")
        }
        throw GitError.commandFailed(message.isEmpty ? "git apply failed" : message)
    }
}
