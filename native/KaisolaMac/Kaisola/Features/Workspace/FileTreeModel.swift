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
/// root, creation is leaf-only, and moves never overwrite or traverse links.
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
        case unchangedLocation
        case destinationExists
        case destinationInsideItem
        case crossVolume

        var errorDescription: String? {
            switch self {
            case .workspaceUnavailable:
                return "The project folder is unavailable."
            case .workspaceRoot:
                return "The project folder itself can't be changed here."
            case .outsideWorkspace:
                return "That item is outside the current project."
            case .symbolicLink:
                return "Kaisola won't change a symbolic link from Files."
            case .missingItem:
                return "That item no longer exists."
            case .notDirectory:
                return "Choose a folder inside the current project."
            case .invalidName:
                return "Enter a valid file or folder name."
            case .nameTooLong:
                return "That name is longer than macOS allows."
            case .unchangedName:
                return "The name hasn't changed."
            case .unchangedLocation:
                return "That item is already in this folder."
            case .destinationExists:
                return "An item with that name already exists."
            case .destinationInsideItem:
                return "A folder can't be moved inside itself."
            case .crossVolume:
                return "That item can't be moved to another volume from here."
            }
        }
    }

    /// An open directory that the mutation syscalls anchor to. Every component
    /// from the workspace root is opened with `O_NOFOLLOW`, so the descriptor
    /// names the directory that was verified instead of a path another process
    /// can swap for a symbolic link in the window after validation.
    final class DirectoryHandle {
        let descriptor: Int32
        private var isOpen = true

        fileprivate init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            close()
        }

        func close() {
            guard isOpen else { return }
            isOpen = false
            Darwin.close(descriptor)
        }

        /// Opens one child directory, refusing a symlinked component. The child
        /// is resolved by the kernel relative to this descriptor, so nothing
        /// above it can be re-pointed once this handle exists.
        fileprivate func openChild(named name: String) throws -> DirectoryHandle {
            let child = openat(
                descriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard child >= 0 else {
                throw WorkspaceFileOperations.openFailure(errno, in: self, named: name)
            }
            return DirectoryHandle(descriptor: child)
        }

        /// The entry's own metadata, never following a final symbolic link.
        fileprivate func entry(named name: String) -> stat? {
            var entry = stat()
            guard fstatat(descriptor, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
                return nil
            }
            return entry
        }

        /// The path this directory occupies right now. Only for the one API
        /// that has no descriptor form; every other call anchors to `descriptor`.
        fileprivate func currentPath() throws -> URL {
            var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
            let result = buffer.withUnsafeMutableBufferPointer { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return fcntl(descriptor, F_GETPATH, base)
            }
            guard result == 0 else {
                throw OperationError.missingItem
            }
            return URL(
                fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self),
                isDirectory: true
            )
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
        return try validatedMove(
            source: source,
            destination: destination,
            workspaceRoot: workspaceRoot
        )
    }

    /// Performs the already-validated same-directory rename against an open
    /// descriptor for the parent that was verified, so an ancestor swapped for
    /// a symbolic link after validation cannot redirect the rename.
    static func rename(item: URL, to proposedName: String, workspaceRoot: URL) throws -> Move {
        let move = try renameMove(item: item, to: proposedName, workspaceRoot: workspaceRoot)
        let parent = try openDirectory(
            move.source.deletingLastPathComponent(),
            workspaceRoot: workspaceRoot
        )
        defer { parent.close() }
        try commitMove(move, from: parent, to: parent)
        return move
    }

    /// Validate an exact cross-directory destination without touching disk.
    /// The destination is a leaf path rather than just a folder so undo/redo
    /// can replay the same transaction even when the two parents differ.
    static func movePlan(item: URL, to destination: URL, workspaceRoot: URL) throws -> Move {
        let source = try validatedItem(item, workspaceRoot: workspaceRoot)
        let destination = destination.standardizedFileURL
        try validateLeafName(destination.lastPathComponent)
        guard destination.path != source.path else {
            throw OperationError.unchangedLocation
        }
        return try validatedMove(
            source: source,
            destination: destination,
            workspaceRoot: workspaceRoot
        )
    }

    /// Move one item to an exact validated destination. Both parents are held
    /// open across the mutation, and the kernel remains the final collision
    /// authority if the filesystem changes after planning.
    static func move(item: URL, to destination: URL, workspaceRoot: URL) throws -> Move {
        let move = try movePlan(item: item, to: destination, workspaceRoot: workspaceRoot)
        let sourceParent = try openDirectory(
            move.source.deletingLastPathComponent(),
            workspaceRoot: workspaceRoot
        )
        defer { sourceParent.close() }
        let destinationParent = try openDirectory(
            move.destination.deletingLastPathComponent(),
            workspaceRoot: workspaceRoot
        )
        defer { destinationParent.close() }
        try commitMove(move, from: sourceParent, to: destinationParent)
        return move
    }

    /// Opens a directory one path component at a time from the workspace root,
    /// refusing a symlinked component at every step. Callers hold the handle
    /// across the mutation itself: that, rather than the path check, is what
    /// closes the window between validating a path and acting on it.
    static func openDirectory(_ directory: URL, workspaceRoot: URL) throws -> DirectoryHandle {
        let root = workspaceRoot.standardizedFileURL
        // Only the root is opened by path. Real projects sit behind symlinked
        // ancestors nobody chose (`/tmp`, `/var`), and the root is the boundary
        // the user mounted rather than something an operation navigated to.
        let rootDescriptor = root.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard rootDescriptor >= 0 else {
            throw OperationError.workspaceUnavailable
        }
        var handle = DirectoryHandle(descriptor: rootDescriptor)
        for component in try relativeComponents(of: directory, under: root) {
            handle = try handle.openChild(named: component)
        }
        return handle
    }

    /// Performs a validated move through the two verified parent descriptors.
    /// `RENAME_EXCL` makes "never overwrite" a property of the syscall instead
    /// of an existence check followed by a separate path-based move.
    static func commitMove(
        _ move: Move,
        from sourceParent: DirectoryHandle,
        to destinationParent: DirectoryHandle
    ) throws {
        let sourceName = move.source.lastPathComponent
        let destinationName = move.destination.lastPathComponent
        var result = renameatx_np(
            sourceParent.descriptor,
            sourceName,
            destinationParent.descriptor,
            destinationName,
            UInt32(RENAME_EXCL)
        )
        var failure = errno
        if result != 0,
           failure == EEXIST,
           isSameEntry(sourceParent, sourceName, destinationParent, destinationName) {
            // A case-only rename collides with the very item being renamed on a
            // case-insensitive volume. Only a plain rename can express that one.
            result = renameat(
                sourceParent.descriptor,
                sourceName,
                destinationParent.descriptor,
                destinationName
            )
            failure = errno
        }
        guard result == 0 else { throw renameFailure(failure) }
    }

    /// The path `candidate` occupies right now as seen through its verified
    /// parent descriptor. `trashItem` has no descriptor form, so this is as
    /// narrow as the OS allows: the path comes from the descriptor that was
    /// opened component by component, and the entry it names is re-identified
    /// immediately before the Trash call instead of trusted from validation.
    static func trashTarget(for candidate: URL, in parent: DirectoryHandle) throws -> URL {
        let name = candidate.lastPathComponent
        guard let anchored = parent.entry(named: name) else {
            throw OperationError.missingItem
        }
        guard anchored.st_mode & S_IFMT != S_IFLNK else {
            throw OperationError.symbolicLink
        }
        let target = try parent.currentPath().appendingPathComponent(name)
        var resolved = stat()
        guard target.path.withCString({ lstat($0, &resolved) }) == 0,
              resolved.st_dev == anchored.st_dev,
              resolved.st_ino == anchored.st_ino else {
            throw OperationError.missingItem
        }
        return target
    }

    /// Creates a zero-byte file without replacing an item that appears between
    /// validation and the write. The parent may be the workspace root, but may
    /// not be a symlink or escape through an intermediate symlink.
    static func createFile(named proposedName: String, in parent: URL, workspaceRoot: URL) throws -> CreatedItem {
        let plan = try createDestination(
            named: proposedName,
            in: parent,
            workspaceRoot: workspaceRoot,
            isDirectory: false
        )
        defer { plan.parent.close() }
        let descriptor = openat(
            plan.parent.descriptor,
            proposedName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        )
        guard descriptor >= 0 else {
            if errno == EEXIST { throw OperationError.destinationExists }
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.close(descriptor) == 0 else {
            _ = unlinkat(plan.parent.descriptor, proposedName, 0)
            throw CocoaError(.fileWriteUnknown)
        }
        return CreatedItem(url: plan.destination, kind: .file)
    }

    /// Creates exactly one directory. Intermediate directory creation is
    /// intentionally disabled so a single action cannot create an unchecked
    /// path hierarchy.
    static func createFolder(named proposedName: String, in parent: URL, workspaceRoot: URL) throws -> CreatedItem {
        let plan = try createDestination(
            named: proposedName,
            in: parent,
            workspaceRoot: workspaceRoot,
            isDirectory: true
        )
        defer { plan.parent.close() }
        // 0o777 matches FileManager's own default; the process umask narrows it.
        guard mkdirat(plan.parent.descriptor, proposedName, 0o777) == 0 else {
            if errno == EEXIST { throw OperationError.destinationExists }
            throw CocoaError(.fileWriteUnknown)
        }
        return CreatedItem(url: plan.destination, kind: .folder)
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
        let parent = try openDirectory(
            candidate.deletingLastPathComponent(),
            workspaceRoot: workspaceRoot
        )
        defer { parent.close() }
        let target = try trashTarget(for: candidate, in: parent)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &resultingURL)
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

    private static func validatedMove(
        source: URL,
        destination: URL,
        workspaceRoot: URL
    ) throws -> Move {
        let destinationParent = try validatedDirectory(
            destination.deletingLastPathComponent(),
            workspaceRoot: workspaceRoot
        )
        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: source.path,
            isDirectory: &sourceIsDirectory
        ) else {
            throw OperationError.missingItem
        }
        if sourceIsDirectory.boolValue,
           contains(destinationParent, in: source) {
            throw OperationError.destinationInsideItem
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            let sameParent = source.deletingLastPathComponent().standardizedFileURL
                == destinationParent.standardizedFileURL
            let destinationValues = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard sameParent,
                  destinationValues?.isSymbolicLink != true,
                  sameFilesystemItem(source, destination) else {
                throw OperationError.destinationExists
            }
        }
        return Move(source: source, destination: destination)
    }

    private static func createDestination(
        named proposedName: String,
        in parent: URL,
        workspaceRoot: URL,
        isDirectory: Bool
    ) throws -> (destination: URL, parent: DirectoryHandle) {
        try validateLeafName(proposedName)
        let parent = try validatedDirectory(parent, workspaceRoot: workspaceRoot)
        let destination = parent.appendingPathComponent(
            proposedName,
            isDirectory: isDirectory
        ).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw OperationError.destinationExists
        }
        return (destination, try openDirectory(parent, workspaceRoot: workspaceRoot))
    }

    private static func relativeComponents(of item: URL, under root: URL) throws -> [String] {
        let rootPath = root.standardizedFileURL.path
        let itemPath = item.standardizedFileURL.path
        if itemPath == rootPath { return [] }
        guard itemPath.hasPrefix(rootPath + "/") else {
            throw OperationError.outsideWorkspace
        }
        let components = itemPath
            .dropFirst(rootPath.count + 1)
            .split(separator: "/")
            .map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw OperationError.outsideWorkspace
        }
        return components
    }

    /// Maps an `openat` failure onto this boundary's own vocabulary. macOS
    /// reports `O_DIRECTORY` plus `O_NOFOLLOW` on a link as `ENOTDIR`, so the
    /// entry itself has to separate "not a folder" from "symbolic link".
    private static func openFailure(
        _ code: Int32,
        in parent: DirectoryHandle,
        named name: String
    ) -> Error {
        switch code {
        case ENOENT:
            return OperationError.missingItem
        case ELOOP:
            return OperationError.symbolicLink
        case ENOTDIR:
            if let entry = parent.entry(named: name), entry.st_mode & S_IFMT == S_IFLNK {
                return OperationError.symbolicLink
            }
            return OperationError.notDirectory
        case EACCES, EPERM:
            return CocoaError(.fileReadNoPermission)
        default:
            return CocoaError(.fileReadUnknown)
        }
    }

    private static func renameFailure(_ code: Int32) -> Error {
        switch code {
        case EEXIST, ENOTEMPTY:
            return OperationError.destinationExists
        case ENOENT:
            return OperationError.missingItem
        case EINVAL:
            return OperationError.destinationInsideItem
        case EXDEV:
            return OperationError.crossVolume
        case EACCES, EPERM:
            return CocoaError(.fileWriteNoPermission)
        default:
            return CocoaError(.fileWriteUnknown)
        }
    }

    private static func isSameEntry(
        _ firstParent: DirectoryHandle,
        _ firstName: String,
        _ secondParent: DirectoryHandle,
        _ secondName: String
    ) -> Bool {
        guard let first = firstParent.entry(named: firstName),
              let second = secondParent.entry(named: secondName) else {
            return false
        }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
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
    static let defaultFileLimit = 3_000
    static let defaultMoveDirectoryLimit = 2_000
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
        scanChildren(
            of: directory,
            limit: limit,
            isCancelled: isCancelled
        ).nodes
    }

    private static func scanChildren(
        of directory: URL,
        limit: Int,
        isCancelled: () -> Bool
    ) -> (nodes: [FileNode], visited: Int) {
        guard limit > 0, !isCancelled() else { return ([], 0) }
        guard let contents = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return ([], 0) }
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
        let sorted = nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return (sorted, visited)
    }

    /// Recursively enumerate project files for fuzzy search, bounded so a huge
    /// tree cannot stall the palette. Returns project-relative paths.
    static func enumerate(
        root: URL,
        limit: Int = defaultFileLimit,
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

    /// Bounded, symlink-free project folders suitable for an in-app move
    /// chooser. The current parent and a directory's own subtree are omitted,
    /// so every displayed destination is meaningful before final validation.
    static func moveDestinationDirectories(
        root: URL,
        movingItem: URL,
        limit: Int = defaultMoveDirectoryLimit,
        visitLimit: Int = defaultVisitLimit,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [URL] {
        guard limit > 0, visitLimit > 0, !isCancelled() else { return [] }
        let root = root.standardizedFileURL
        let movingItem = movingItem.standardizedFileURL
        guard WorkspaceFileOperations.contains(movingItem, in: root) else { return [] }
        let currentParent = movingItem.deletingLastPathComponent()
        var queue: [URL] = [root]
        var queueIndex = 0
        var visitedEntries = 0
        var destinations: [URL] = []
        while queueIndex < queue.count,
              queueIndex < limit,
              visitedEntries < visitLimit,
              !isCancelled() {
            let directory = queue[queueIndex]
            queueIndex += 1
            if directory.path != currentParent.path,
               !WorkspaceFileOperations.contains(directory, in: movingItem) {
                destinations.append(directory)
            }
            let scan = scanChildren(
                of: directory,
                limit: visitLimit - visitedEntries,
                isCancelled: isCancelled
            )
            visitedEntries += scan.visited
            for node in scan.nodes
                where node.isDirectory && !WorkspaceFileOperations.contains(node.url, in: movingItem) {
                guard queue.count < limit else { break }
                queue.append(node.url)
            }
        }
        guard !isCancelled() else { return [] }
        return destinations.sorted { first, second in
            if first.path == root.path || second.path == root.path {
                return first.path == root.path && second.path != root.path
            }
            let firstRelative = String(first.path.dropFirst(root.path.count))
            let secondRelative = String(second.path.dropFirst(root.path.count))
            return firstRelative.localizedStandardCompare(secondRelative) == .orderedAscending
        }
    }

    /// Reconcile a cached project-relative file list against a bounded set of
    /// exact FSEvents paths. Only changed files/directories are inspected; an
    /// event for the root itself returns `nil` so the caller can fall back to a
    /// complete bounded walk. Removed paths prune their whole cached subtree,
    /// while a new/changed directory contributes only its own bounded subtree.
    static func updatingIndex(
        _ existing: [String],
        root: URL,
        changedPaths: [URL],
        limit: Int = defaultFileLimit,
        directoryLimit: Int = defaultDirectoryLimit,
        visitLimit: Int = defaultVisitLimit,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [String]? {
        guard limit > 0, !isCancelled() else { return [] }
        let normalizedRoot = root.standardizedFileURL
        let rootPath = normalizedRoot.path
        var relativeChanges: Set<String> = []
        for changedPath in changedPaths {
            guard !isCancelled() else { return [] }
            let path = changedPath.standardizedFileURL.path
            if path == rootPath { return nil }
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            guard isIndexableRelativePath(relative) else { continue }
            relativeChanges.insert(relative)
        }
        guard !relativeChanges.isEmpty else { return existing }

        var files = Set(existing)
        let orderedChanges = relativeChanges.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        for relative in orderedChanges {
            let prefix = relative + "/"
            files = Set(files.filter { $0 != relative && !$0.hasPrefix(prefix) })
        }

        var additions: [String] = []
        additions.reserveCapacity(min(limit, 256))
        for relative in orderedChanges where additions.count < limit {
            guard !isCancelled() else { return [] }
            let candidate = normalizedRoot.appendingPathComponent(relative).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isSafeIndexCandidate(candidate, root: normalizedRoot) else { continue }
            if isDirectory.boolValue {
                let remaining = limit - additions.count
                additions.append(contentsOf: enumerate(
                    root: candidate,
                    limit: remaining,
                    directoryLimit: directoryLimit,
                    visitLimit: visitLimit,
                    isCancelled: isCancelled
                ).map { relative + "/" + $0 })
            } else {
                additions.append(relative)
            }
        }
        files.formUnion(additions)
        return Array(files).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.prefix(limit).map { $0 }
    }

    private static func isIndexableRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.hasPrefix(".")
                && !ignoredNames.contains(String(component))
        }
    }

    private static func isSafeIndexCandidate(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath.hasPrefix(rootPath + "/") else { return false }
        var cursor = root
        for component in candidatePath.dropFirst(rootPath.count + 1).split(separator: "/") {
            cursor.appendPathComponent(String(component))
            let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true { return false }
        }
        return true
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

    private struct PendingInvalidation {
        var paths: Set<String> = []
        var requiresFullRefresh = false
    }

    private var cache: [String: (at: Date, files: [String])] = [:]

    /// Memory-pressure hook and closed-project eviction (spec §2g/§2i): the
    /// palette re-walks on demand, so residency is purely discretionary.
    func purge() {
        cache.removeAll()
    }

    func evict(root: URL) {
        cache.removeValue(forKey: root.standardizedFileURL.path)
    }
    private var inFlight: [String: InFlightWalk] = [:]
    /// A replacement walk waits for its canceled predecessor to finish. The
    /// production enumerator cooperates promptly, and the ordering guarantee
    /// ensures invalidation can never create overlapping crawls of one root.
    private var retiring: [String: Task<[String], Never>] = [:]
    private var generationByRoot: [String: Int] = [:]
    private var pendingInvalidations: [String: PendingInvalidation] = [:]
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
        if pendingInvalidations[key] == nil,
           let cached = cache[key], now.timeIntervalSince(cached.at) < 30 {
            return cached.files
        }
        if let existing = inFlight[key] {
            let joinedGeneration = generationByRoot[key, default: 0]
            let files = await existing.task.value
            if joinedGeneration == generationByRoot[key, default: 0], !existing.task.isCancelled {
                return files
            }
            guard !Task.isCancelled else { return [] }
            return await self.files(for: root)
        }
        let currentGeneration = generationByRoot[key, default: 0]
        let predecessor = retiring.removeValue(forKey: key)
        let invalidation = pendingInvalidations.removeValue(forKey: key)
        let cachedFiles = cache[key]?.files
        let walkID = UUID()
        let enumerateFiles = self.enumerateFiles
        let task: Task<[String], Never> = Task.detached(priority: .utility) {
            if let predecessor {
                _ = await predecessor.value
            }
            guard !Task.isCancelled else { return [] }
            if let invalidation,
               !invalidation.requiresFullRefresh,
               let cachedFiles {
                let paths = invalidation.paths.map { URL(fileURLWithPath: $0) }
                if let files = ProjectFiles.updatingIndex(
                    cachedFiles,
                    root: root,
                    changedPaths: paths
                ) {
                    return files
                }
            }
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
        if stillOwnsSlot,
           generationByRoot[key, default: 0] == currentGeneration,
           !task.isCancelled {
            cache[key] = (now, files)
            return files
        }
        // An invalidated walk may contain a partial traversal. Join the current
        // generation instead of leaking that stale list to the palette.
        guard !Task.isCancelled else { return [] }
        return await self.files(for: root)
    }

    func invalidate() {
        let keys = Set(cache.keys)
            .union(inFlight.keys)
            .union(pendingInvalidations.keys)
        for key in keys {
            invalidateKey(key, changedPaths: [], requiresFullRefresh: true)
        }
    }

    /// Invalidate one project only. Detailed watcher paths preserve a valid
    /// cached index and patch just those subtrees on its next read; overflow or
    /// root-level events deliberately request a complete bounded replacement.
    func invalidate(
        root: URL,
        changedPaths: [URL] = [],
        requiresFullRefresh: Bool = true
    ) {
        invalidateKey(
            root.standardizedFileURL.path,
            changedPaths: changedPaths.map { $0.standardizedFileURL.path },
            requiresFullRefresh: requiresFullRefresh
        )
    }

    private func invalidateKey(
        _ key: String,
        changedPaths: [String],
        requiresFullRefresh: Bool
    ) {
        generationByRoot[key, default: 0] &+= 1
        let replacedInFlightWork = inFlight[key] != nil
        if let walk = inFlight.removeValue(forKey: key) {
            walk.task.cancel()
            retiring[key] = walk.task
        }
        // The paths owned by a canceled patch have already been removed from
        // `pendingInvalidations`; a full replacement is the only safe way to
        // avoid losing them when another event arrives mid-patch.
        if requiresFullRefresh || replacedInFlightWork || cache[key] == nil {
            cache[key] = nil
            pendingInvalidations[key] = PendingInvalidation(requiresFullRefresh: true)
            return
        }
        var pending = pendingInvalidations[key] ?? PendingInvalidation()
        pending.paths.formUnion(changedPaths)
        pendingInvalidations[key] = pending
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

    /// Re-list only directories whose immediate contents may have changed.
    /// Unrelated expanded folders keep both their snapshot and any in-flight
    /// work, which prevents one source-file write from scaling with the number
    /// of open folders in a large repository.
    func refresh(
        changeBatch: WorkspaceChangeBatch,
        expandedDirectories: [URL]
    ) {
        guard !changeBatch.requiresFullRefresh, !changeBatch.paths.isEmpty else {
            refresh(expandedDirectories: expandedDirectories)
            return
        }
        let rootPath = root.path
        let loaded = Set(childrenByDirectory.keys)
        var affected: Set<String> = []
        var removedSubtrees: Set<String> = []
        for changedURL in changeBatch.paths {
            let changed = changedURL.standardizedFileURL
            let path = changed.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let parent = changed.deletingLastPathComponent().path
            if loaded.contains(parent) { affected.insert(parent) }
            if loaded.contains(path) { affected.insert(path) }
            if !FileManager.default.fileExists(atPath: path) {
                removedSubtrees.insert(path)
            }
        }

        for removed in removedSubtrees {
            let prefix = removed + "/"
            let staleKeys = childrenByDirectory.keys.filter {
                $0 == removed || $0.hasPrefix(prefix)
            }
            for key in staleKeys {
                childrenByDirectory[key] = nil
                directoryTasks[key]?.cancel()
                directoryTasks[key] = nil
                loadingDirectories.remove(key)
                affected.remove(key)
            }
        }
        for key in affected {
            directoryTasks[key]?.cancel()
            load(URL(fileURLWithPath: key, isDirectory: true), force: true)
        }
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
