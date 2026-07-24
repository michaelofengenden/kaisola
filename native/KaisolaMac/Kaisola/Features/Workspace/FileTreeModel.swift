import Combine
import Foundation

/// One node in the workspace file tree.
struct FileNode: Identifiable, Equatable, Sendable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// Directory listing + project file enumeration for the workspace rail and the
/// command palette's file search. Pure filesystem logic, testable directly.
enum ProjectFiles {
    /// Directories that never belong in a tree or fuzzy index.
    static let ignoredNames: Set<String> = [
        ".git", "node_modules", ".build", "dist", "DerivedData", ".swiftpm",
        "__pycache__", ".venv", ".next", ".turbo", "build",
    ]

    /// Immediate children of a directory: folders first, then files, both
    /// alphabetical; hidden entries and ignored directories skipped.
    static func children(of directory: URL) -> [FileNode] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let nodes = contents.compactMap { url -> FileNode? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values?.isDirectory ?? false
            // Never recursively walk a directory symlink: a project can point
            // one at its parent, a vendor cache, or an entire home directory.
            if values?.isSymbolicLink == true { return nil }
            if isDirectory, ignoredNames.contains(url.lastPathComponent) { return nil }
            return FileNode(url: url.standardizedFileURL, isDirectory: isDirectory)
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Recursively enumerate project files for fuzzy search, bounded so a huge
    /// tree cannot stall the palette. Returns project-relative paths.
    static func enumerate(root: URL, limit: Int = 3_000) -> [String] {
        var results: [String] = []
        var queue: [URL] = [root]
        var queueIndex = 0
        let rootPath = root.standardizedFileURL.path
        while queueIndex < queue.count, results.count < limit {
            let directory = queue[queueIndex]
            queueIndex += 1
            for node in children(of: directory) {
                if node.isDirectory {
                    queue.append(node.url)
                } else {
                    let path = node.url.path
                    if path.hasPrefix(rootPath + "/") {
                        results.append(String(path.dropFirst(rootPath.count + 1)))
                        if results.count >= limit { break }
                    }
                }
            }
        }
        return results
    }
}

/// A small TTL cache of project file lists so the palette doesn't re-walk the
/// tree on every keystroke.
@MainActor
final class ProjectFileIndex {
    static let shared = ProjectFileIndex()
    private var cache: [String: (at: Date, files: [String])] = [:]
    private var inFlight: [String: Task<[String], Never>] = [:]
    private var generation = 0

    func files(for root: URL, now: Date = Date()) async -> [String] {
        let key = root.standardizedFileURL.path
        if let cached = cache[key], now.timeIntervalSince(cached.at) < 30 {
            return cached.files
        }
        if let existing = inFlight[key] { return await existing.value }
        let currentGeneration = generation
        let task = Task.detached(priority: .utility) {
            ProjectFiles.enumerate(root: root)
        }
        inFlight[key] = task
        let files = await task.value
        inFlight[key] = nil
        if generation == currentGeneration {
            cache[key] = (now, files)
        }
        return files
    }

    func invalidate() {
        generation &+= 1
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
    }
}

/// Async, cached presentation state for one workspace rail. Filesystem calls
/// never run on the MainActor; SwiftUI reads only the published snapshots.
@MainActor
final class WorkspaceTreeModel: ObservableObject {
    let root: URL
    @Published private(set) var childrenByDirectory: [String: [FileNode]] = [:]
    @Published private(set) var loadingDirectories: Set<String> = []
    @Published private(set) var searchResults: [String] = []
    @Published private(set) var isSearching = false

    private var directoryTasks: [String: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    deinit {
        for task in directoryTasks.values { task.cancel() }
        searchTask?.cancel()
    }

    func children(of directory: URL) -> [FileNode]? {
        childrenByDirectory[directory.standardizedFileURL.path]
    }

    func load(_ directory: URL, force: Bool = false) {
        let normalized = directory.standardizedFileURL
        let key = normalized.path
        if !force, childrenByDirectory[key] != nil { return }
        directoryTasks[key]?.cancel()
        loadingDirectories.insert(key)
        directoryTasks[key] = Task { [weak self] in
            let nodes = await Task.detached(priority: .userInitiated) {
                ProjectFiles.children(of: normalized)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.childrenByDirectory[key] = nodes
            self.loadingDirectories.remove(key)
            self.directoryTasks[key] = nil
        }
    }

    func refresh(expandedDirectories: [URL]) {
        for task in directoryTasks.values { task.cancel() }
        directoryTasks.removeAll()
        // Keep the last complete snapshot visible while refreshed directories
        // load. Clearing it caused an avoidable blank-frame flicker on every
        // agent filesystem event.
        loadingDirectories.removeAll()
        for directory in [root] + expandedDirectories { load(directory, force: true) }
    }

    func search(_ rawQuery: String) {
        searchTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        let root = self.root
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            let files = await ProjectFileIndex.shared.files(for: root)
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                Array(files.lazy.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(200))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.searchResults = matches
            self.isSearching = false
        }
    }
}
