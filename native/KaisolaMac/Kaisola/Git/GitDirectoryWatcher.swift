import Foundation

/// Filesystem watching for the half of a repository that `WorkspaceWatcher`
/// deliberately refuses to look at: the git directory itself.
///
/// `WorkspaceWatcher` ignores every `.git` component (it feeds the file tree,
/// which must never show git internals), so it reports working-tree edits but
/// never a stage, commit, checkout, or fetch. Those all move `git status`, and
/// they are exactly what an agent does. This watcher covers them:
///
/// - the git directory itself, so the atomic `index.lock` → `index` rename that
///   every `git add`/`commit`/`checkout` performs is observed, along with
///   `HEAD`, `ORIG_HEAD`, `MERGE_HEAD`, `FETCH_HEAD`, and `COMMIT_EDITMSG`;
/// - `HEAD` and `index` directly, for in-place writes to either.
///
/// `DispatchSource` (not a second FSEvents stream) because the watched set is
/// three fixed paths, not a subtree — no recursion, no per-directory descriptor
/// fan-out, and no 0.5s FSEvents coalescing latency in front of a panel the user
/// is looking at. Callers get raw events; the debounce and rate floor live in
/// `GitRefreshPolicy`.
@MainActor
final class GitDirectoryWatcher {
    /// Entries inside the git directory watched individually, on top of the
    /// directory itself.
    static let watchedEntries = ["HEAD", "index"]

    private let gitDirectory: URL
    private let onChange: @MainActor () -> Void

    /// Live sources. `nonisolated(unsafe)` so the nonisolated `deinit` can cancel
    /// them; every access is single-threaded by construction (created on the main
    /// actor, mutated only in `arm`/`cancelSources`), and `DispatchSource.cancel`
    /// is itself safe to call from anywhere.
    nonisolated(unsafe) private var sources: [DispatchSourceFileSystemObject] = []

    /// Pending re-open after a rename/delete burst. `nonisolated(unsafe)` so the
    /// nonisolated `deinit` can cancel it alongside `sources`; every access is
    /// otherwise single-threaded (created and cleared only from `scheduleRearm`
    /// and `stop`, both on the main actor), and `Task.cancel()` is itself safe
    /// to call from anywhere.
    nonisolated(unsafe) private var rearm: Task<Void, Never>?

    /// Delay before re-opening the watched entries after a burst. Git renames a
    /// fresh file over `index`/`HEAD`, so the descriptor we hold stops receiving
    /// events; the directory source keeps covering that gap.
    private static let rearmDelay: UInt64 = 250_000_000

    /// Fails when `repoRoot` has no resolvable git directory, or when none of the
    /// watched paths could be opened — the caller then simply has no live Git
    /// events rather than a watcher that silently never fires.
    init?(repoRoot: URL, onChange: @escaping @MainActor () -> Void) {
        guard let directory = Self.resolveGitDirectory(repoRoot: repoRoot) else { return nil }
        self.gitDirectory = directory
        self.onChange = onChange
        arm()
        guard !sources.isEmpty else { return nil }
    }

    deinit {
        // Nonisolated: only touches sources/rearm through their unsafe handles.
        // Cancelling the sources releases each one's handlers (breaking the
        // retain that the event handler would otherwise hold); cancelling
        // `rearm` stops a pending re-arm from firing `arm()` on a watcher that
        // is already gone, mirroring `stop()`.
        rearm?.cancel()
        cancelSources()
    }

    /// Stop watching. Idempotent and safe to call before `deinit`.
    func stop() {
        rearm?.cancel()
        rearm = nil
        cancelSources()
    }

    // MARK: - Git directory resolution (pure enough to test)

    /// The directory holding `HEAD`/`index` for `repoRoot`: `.git` for an
    /// ordinary clone, or the per-worktree directory a linked worktree's `.git`
    /// FILE points at. Kaisola Mesh creates linked worktrees (and Kaisola itself
    /// is developed in them), so assuming `.git` is a directory would leave the
    /// panel eventless in exactly the sessions that need it most.
    nonisolated static func resolveGitDirectory(repoRoot: URL) -> URL? {
        let candidate = repoRoot.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return candidate.standardizedFileURL }
        guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else { return nil }
        return gitDirectory(fromPointerFile: contents, repoRoot: repoRoot)
    }

    /// Parse a `.git` pointer file (`gitdir: <path>`). Relative targets resolve
    /// against the worktree root. Nil for anything that is not a usable pointer.
    nonisolated static func gitDirectory(fromPointerFile contents: String, repoRoot: URL) -> URL? {
        let marker = "gitdir:"
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(marker) else { continue }
            let target = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            let url = target.hasPrefix("/")
                ? URL(fileURLWithPath: target, isDirectory: true)
                : repoRoot.appendingPathComponent(target, isDirectory: true)
            return url.standardizedFileURL
        }
        return nil
    }

    // MARK: - Sources

    private func arm() {
        cancelSources()
        var built: [DispatchSourceFileSystemObject] = []
        let targets = [gitDirectory] + Self.watchedEntries.map { gitDirectory.appendingPathComponent($0) }
        for target in targets {
            if let source = makeSource(for: target) { built.append(source) }
        }
        sources = built
        for source in built { source.resume() }
    }

    private func makeSource(for url: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // The source is bound to the main queue, so this handler already runs
            // on the main thread — the actor is genuinely entered, not assumed.
            MainActor.assumeIsolated { self?.handleEvent() }
        }
        source.setCancelHandler { close(descriptor) }
        return source
    }

    private func handleEvent() {
        onChange()
        scheduleRearm()
    }

    /// Re-open the watched entries after a burst settles: git replaces `index`
    /// and `HEAD` by renaming a temporary file over them, so the descriptors we
    /// hold now refer to unlinked inodes nobody will write again. The directory
    /// source is unaffected by those renames and keeps covering the gap, so no
    /// change is missed while this is pending.
    private func scheduleRearm() {
        guard rearm == nil else { return }
        rearm = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.rearmDelay)
            guard let self, !Task.isCancelled else { return }
            self.rearm = nil
            self.arm()
        }
    }

    nonisolated private func cancelSources() {
        let live = sources
        sources = []
        for source in live { source.cancel() }
    }
}
