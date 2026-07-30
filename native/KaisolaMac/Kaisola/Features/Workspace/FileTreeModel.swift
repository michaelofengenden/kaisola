import Combine
import Darwin
import Foundation

/// One node in the workspace file tree.
struct FileNode: Identifiable, Equatable, Sendable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// The filesystem mutation boundary used by the workspace rail. File actions
/// are intentionally narrower than a general-purpose file manager: they may
/// only target the mounted workspace, existing-item actions never target its
/// root, creation is leaf-only, and a rename stays in the current directory.
enum WorkspaceFileOperations {
    struct Move: Equatable, Sendable {
        let source: URL
        let destination: URL
    }

    struct CreatedItem: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case file
            case folder
        }

        let url: URL
        let kind: Kind
    }

    struct TrashMove: Equatable, Sendable {
        let original: URL
        let trashed: URL
    }

    enum OperationError: LocalizedError, Equatable {
        case workspaceUnavailable
        case workspaceRoot
        case outsideWorkspace
        case symbolicLink
        case missingItem
        case notDirectory
        case invalidName
        case nameTooLong
        case unchangedName
        case destinationExists

        var errorDescription: String? {
            switch self {
            case .workspaceUnavailable:
                return "The workspace folder is unavailable."
            case .workspaceRoot:
                return "The workspace folder itself can't be changed here."
            case .outsideWorkspace:
                return "That item is outside the current workspace."
            case .symbolicLink:
                return "Kaisola won't change a symbolic link from the workspace rail."
            case .missingItem:
                return "That item no longer exists."
            case .notDirectory:
                return "Choose a folder inside the current workspace."
            case .invalidName:
                return "Enter a valid file or folder name."
            case .nameTooLong:
                return "That name is longer than macOS allows."
            case .unchangedName:
                return "The name hasn't changed."
            case .destinationExists:
                return "An item with that name already exists."
            }
        }
    }

    /// Validate and construct a same-directory rename without touching disk.
    /// Keeping this pure makes every rejection deterministic and testable.
    static func renameMove(item: URL, to proposedName: String, workspaceRoot: URL) throws -> Move {
        let source = try validatedItem(item, workspaceRoot: workspaceRoot)
        try validateLeafName(proposedName)
        guard proposedName != source.lastPathComponent else {
            throw OperationError.unchangedName
        }
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent(proposedName, isDirectory: source.hasDirectoryPath)
            .standardizedFileURL
        let resolvedRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedParent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        guard isDescendantOrSame(resolvedParent, of: resolvedRoot) else {
            throw OperationError.outsideWorkspace
        }
        if FileManager.default.fileExists(atPath: destination.path),
           !sameFilesystemItem(source, destination) {
            throw OperationError.destinationExists
        }
        return Move(source: source, destination: destination)
    }

    /// Performs the already-validated same-directory rename. `moveItem` keeps
    /// Finder/APFS collision behavior authoritative and never overwrites.
    static func rename(item: URL, to proposedName: String, workspaceRoot: URL) throws -> Move {
        let move = try renameMove(item: item, to: proposedName, workspaceRoot: workspaceRoot)
        try FileManager.default.moveItem(at: move.source, to: move.destination)
        return move
    }

    /// Creates a zero-byte file without replacing an item that appears between
    /// validation and the write. The parent may be the workspace root, but may
    /// not be a symlink or escape through an intermediate symlink.
    static func createFile(named proposedName: String, in parent: URL, workspaceRoot: URL) throws -> CreatedItem {
        let destination = try createDestination(
            named: proposedName,
            in: parent,
            workspaceRoot: workspaceRoot,
            isDirectory: false
        )
        let descriptor = destination.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw OperationError.destinationExists }
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.close(descriptor) == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw CocoaError(.fileWriteUnknown)
        }
        return CreatedItem(url: destination, kind: .file)
    }

    /// Creates exactly one directory. Intermediate directory creation is
    /// intentionally disabled so a single action cannot create an unchecked
    /// path hierarchy.
    static func createFolder(named proposedName: String, in parent: URL, workspaceRoot: URL) throws -> CreatedItem {
        let destination = try createDestination(
            named: proposedName,
            in: parent,
            workspaceRoot: workspaceRoot,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw OperationError.destinationExists
        }
        return CreatedItem(url: destination, kind: .folder)
    }

    /// Returns the normalized item that may be sent to the recoverable system
    /// Trash. Separating validation from the OS operation lets tests prove the
    /// safety boundary without depositing fixtures in the user's Trash.
    static func trashCandidate(item: URL, workspaceRoot: URL) throws -> URL {
        try validatedItem(item, workspaceRoot: workspaceRoot)
    }

    /// Moves one validated file or directory to Trash and returns its actual
    /// resulting URL. macOS can change the name to avoid a Trash collision.
    static func moveToTrash(item: URL, workspaceRoot: URL) throws -> TrashMove {
        let candidate = try trashCandidate(item: item, workspaceRoot: workspaceRoot)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: candidate, resultingItemURL: &resultingURL)
        guard let trashed = resultingURL as URL? else {
            throw CocoaError(.fileWriteUnknown)
        }
        return TrashMove(original: candidate, trashed: trashed.standardizedFileURL)
    }

    /// Restores only a Trash URL captured from `moveToTrash`. The destination
    /// parent is independently revalidated and collisions never overwrite a
    /// newer file that appeared after the original move.
    static func restoreFromTrash(_ move: TrashMove, workspaceRoot: URL) throws {
        guard FileManager.default.fileExists(atPath: move.trashed.path) else {
            throw OperationError.missingItem
        }
        let parent = move.original.deletingLastPathComponent()
        _ = try validatedDirectory(parent, workspaceRoot: workspaceRoot)
        guard !FileManager.default.fileExists(atPath: move.original.path) else {
            throw OperationError.destinationExists
        }
        try FileManager.default.moveItem(at: move.trashed, to: move.original)
    }

    /// Maps an open document beneath a renamed item onto the corresponding new
    /// path. Directory renames therefore update the entire document deck.
    static func replacingPrefix(of candidate: URL, from source: URL, to destination: URL) -> URL? {
        let candidatePath = candidate.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        guard candidatePath == sourcePath || candidatePath.hasPrefix(sourcePath + "/") else {
            return nil
        }
        let suffix = candidatePath.dropFirst(sourcePath.count)
        return URL(fileURLWithPath: destination.standardizedFileURL.path + suffix).standardizedFileURL
    }

    static func contains(_ candidate: URL, in item: URL) -> Bool {
        replacingPrefix(of: candidate, from: item, to: item) != nil
    }

    /// Filesystem NSError descriptions often include full local paths. Keep UI
    /// errors useful without leaking a workspace path into screenshots/logs.
    static func userFacingDescription(for error: Error, action: String) -> String {
        if let operationError = error as? OperationError {
            return operationError.localizedDescription
        }
        let cocoaError = error as? CocoaError
        switch cocoaError?.code {
        case .fileWriteFileExists:
            return OperationError.destinationExists.localizedDescription
        case .fileNoSuchFile:
            return OperationError.missingItem.localizedDescription
        case .fileReadNoPermission, .fileWriteNoPermission:
            return "Kaisola doesn't have permission to \(action) that item."
        default:
            return "Kaisola couldn't \(action) that item. Check its permissions and try again."
        }
    }

    private static func validatedItem(_ item: URL, workspaceRoot: URL) throws -> URL {
        let manager = FileManager.default
        let root = workspaceRoot.standardizedFileURL
        let source = item.standardizedFileURL
        guard manager.fileExists(atPath: root.path) else {
            throw OperationError.workspaceUnavailable
        }
        guard manager.fileExists(atPath: source.path) else {
            throw OperationError.missingItem
        }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedSource = source.resolvingSymlinksInPath()
        guard resolvedSource.path != resolvedRoot.path else {
            throw OperationError.workspaceRoot
        }
        guard isDescendantOrSame(resolvedSource, of: resolvedRoot) else {
            throw OperationError.outsideWorkspace
        }
        let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw OperationError.symbolicLink
        }
        // A contained final URL is insufficient when an intermediate path is a
        // link. Refuse those paths too, matching the tree enumerator's policy.
        var cursor = source.deletingLastPathComponent()
        while cursor.path != root.path {
            guard isDescendantOrSame(cursor, of: root) else {
                throw OperationError.outsideWorkspace
            }
            let parentValues = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard parentValues?.isSymbolicLink != true else {
                throw OperationError.symbolicLink
            }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else {
                throw OperationError.outsideWorkspace
            }
            cursor = parent
        }
        return source
    }

    private static func createDestination(
        named proposedName: String,
        in parent: URL,
        workspaceRoot: URL,
        isDirectory: Bool
    ) throws -> URL {
        try validateLeafName(proposedName)
        let parent = try validatedDirectory(parent, workspaceRoot: workspaceRoot)
        let destination = parent.appendingPathComponent(
            proposedName,
            isDirectory: isDirectory
        ).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw OperationError.destinationExists
        }
        return destination
    }

    private static func validatedDirectory(_ directory: URL, workspaceRoot: URL) throws -> URL {
        let manager = FileManager.default
        let root = workspaceRoot.standardizedFileURL
        let directory = directory.standardizedFileURL
        guard manager.fileExists(atPath: root.path) else {
            throw OperationError.workspaceUnavailable
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw OperationError.missingItem
        }
        guard isDirectory.boolValue else { throw OperationError.notDirectory }
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        guard isDescendantOrSame(resolvedDirectory, of: resolvedRoot) else {
            throw OperationError.outsideWorkspace
        }
        var cursor = directory
        while true {
            let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else {
                throw OperationError.symbolicLink
            }
            if cursor.path == root.path { break }
            guard isDescendantOrSame(cursor, of: root) else {
                throw OperationError.outsideWorkspace
            }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else {
                throw OperationError.outsideWorkspace
            }
            cursor = parent
        }
        return directory
    }

    private static func validateLeafName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.newlines.contains($0) }) else {
            throw OperationError.invalidName
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OperationError.invalidName
        }
        guard name.utf8.count <= 255 else {
            throw OperationError.nameTooLong
        }
    }

    private static func sameFilesystemItem(_ first: URL, _ second: URL) -> Bool {
        guard let firstID = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let secondID = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return String(describing: firstID) == String(describing: secondID)
    }

    private static func isDescendantOrSame(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

/// Directory listing + project file enumeration for the workspace rail and the
/// command palette's file search. Pure filesystem logic, testable directly.
enum ProjectFiles {
    /// Fuzzy search needs useful coverage, not an unbounded repository crawl.
    /// These limits are deliberately much larger than the result limit so a
    /// project with many folders still has a representative index while a
    /// generated or adversarial tree cannot monopolize a utility task.
    static let defaultDirectoryLimit = 2_000
    static let defaultVisitLimit = 20_000

    /// Directories that never belong in a tree or fuzzy index.
    static let ignoredNames: Set<String> = [
        ".git", "node_modules", ".build", "dist", "DerivedData", ".swiftpm",
        "__pycache__", ".venv", ".next", ".turbo", "build",
    ]

    /// Immediate children of a directory: folders first, then files, both
    /// alphabetical; hidden entries and ignored directories skipped.
    static func children(
        of directory: URL,
        limit: Int = .max,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [FileNode] {
        guard limit > 0, !isCancelled() else { return [] }
        guard let contents = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        var nodes: [FileNode] = []
        if limit != .max { nodes.reserveCapacity(min(limit, 256)) }
        var visited = 0
        while let url = contents.nextObject() as? URL {
            guard !isCancelled(), visited < limit else { break }
            visited += 1
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values?.isDirectory ?? false
            // Never recursively walk a directory symlink: a project can point
            // one at its parent, a vendor cache, or an entire home directory.
            if values?.isSymbolicLink == true { continue }
            if isDirectory, ignoredNames.contains(url.lastPathComponent) { continue }
            nodes.append(FileNode(url: url.standardizedFileURL, isDirectory: isDirectory))
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Recursively enumerate project files for fuzzy search, bounded so a huge
    /// tree cannot stall the palette. Returns project-relative paths.
    static func enumerate(
        root: URL,
        limit: Int = 3_000,
        directoryLimit: Int = defaultDirectoryLimit,
        visitLimit: Int = defaultVisitLimit,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [String] {
        guard limit > 0, directoryLimit > 0, visitLimit > 0, !isCancelled() else {
            return []
        }
        var results: [String] = []
        var queue: [URL] = [root]
        var queueIndex = 0
        var visitedEntries = 0
        let rootPath = root.standardizedFileURL.path
        while queueIndex < queue.count,
              queueIndex < directoryLimit,
              results.count < limit,
              visitedEntries < visitLimit,
              !isCancelled() {
            let directory = queue[queueIndex]
            queueIndex += 1
            for node in children(
                of: directory,
                limit: visitLimit - visitedEntries,
                isCancelled: isCancelled
            ) {
                guard !isCancelled(), visitedEntries < visitLimit else {
                    return results
                }
                visitedEntries += 1
                if node.isDirectory {
                    // Never enqueue more work than this traversal is allowed
                    // to visit. This also caps memory used by the BFS queue.
                    if queue.count < directoryLimit {
                        queue.append(node.url)
                    }
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

    private struct InFlightWalk {
        let id: UUID
        let task: Task<[String], Never>
    }

    private var cache: [String: (at: Date, files: [String])] = [:]
    private var inFlight: [String: InFlightWalk] = [:]
    /// A replacement walk waits for its canceled predecessor to finish. The
    /// production enumerator cooperates promptly, and the ordering guarantee
    /// ensures invalidation can never create overlapping crawls of one root.
    private var retiring: [String: Task<[String], Never>] = [:]
    private var generation = 0
    private let enumerateFiles: @Sendable (URL) -> [String]

    init(
        enumerateFiles: @escaping @Sendable (URL) -> [String] = {
            ProjectFiles.enumerate(root: $0)
        }
    ) {
        self.enumerateFiles = enumerateFiles
    }

    func files(for root: URL, now: Date = Date()) async -> [String] {
        let key = root.standardizedFileURL.path
        if let cached = cache[key], now.timeIntervalSince(cached.at) < 30 {
            return cached.files
        }
        if let existing = inFlight[key] {
            let joinedGeneration = generation
            let files = await existing.task.value
            if joinedGeneration == generation, !existing.task.isCancelled {
                return files
            }
            guard !Task.isCancelled else { return [] }
            return await self.files(for: root)
        }
        let currentGeneration = generation
        let predecessor = retiring.removeValue(forKey: key)
        let walkID = UUID()
        let enumerateFiles = self.enumerateFiles
        let task: Task<[String], Never> = Task.detached(priority: .utility) {
            if let predecessor {
                _ = await predecessor.value
            }
            guard !Task.isCancelled else { return [] }
            return enumerateFiles(root)
        }
        inFlight[key] = InFlightWalk(id: walkID, task: task)
        let files = await task.value
        // An invalidated caller may finish after a replacement has started.
        // Only the walk that still owns this slot may clear or populate it.
        let stillOwnsSlot = inFlight[key]?.id == walkID
        if stillOwnsSlot {
            inFlight[key] = nil
        }
        if stillOwnsSlot, generation == currentGeneration, !task.isCancelled {
            cache[key] = (now, files)
            return files
        }
        // An invalidated walk may contain a partial traversal. Join the current
        // generation instead of leaking that stale list to the palette.
        guard !Task.isCancelled else { return [] }
        return await self.files(for: root)
    }

    func invalidate() {
        generation &+= 1
        for (key, walk) in inFlight {
            walk.task.cancel()
            retiring[key] = walk.task
        }
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
            let worker = Task.detached(priority: .userInitiated) {
                ProjectFiles.children(of: normalized, isCancelled: { Task.isCancelled })
            }
            let nodes = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
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
