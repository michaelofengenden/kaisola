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
        return try validatedMove(
            source: source,
            destination: destination,
            workspaceRoot: workspaceRoot
        )
    }

    /// Performs the already-validated same-directory rename. `moveItem` keeps
    /// Finder/APFS collision behavior authoritative and never overwrites.
    static func rename(item: URL, to proposedName: String, workspaceRoot: URL) throws -> Move {
        let move = try renameMove(item: item, to: proposedName, workspaceRoot: workspaceRoot)
        try FileManager.default.moveItem(at: move.source, to: move.destination)
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

    /// Move one item to an exact validated destination. FileManager remains the
    /// final collision authority if the filesystem changes after planning.
    static func move(item: URL, to destination: URL, workspaceRoot: URL) throws -> Move {
        let move = try movePlan(item: item, to: destination, workspaceRoot: workspaceRoot)
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
    static let defaultFileLimit = 3_000
    static let defaultMoveDirectoryLimit = 2_000
    /// Fuzzy search needs useful coverage, not an unbounded repository crawl.
    /// These limits are deliberately much larger than the result limit so a
    /// project with many folders still has a representative index while a
    /// generated or adversarial tree cannot monopolize a utility task.
    static let defaultDirectoryLimit = 2_000
    static let defaultVisitLimit = 20_000

    /// One traversal budget that stopped an otherwise valid project index.
    /// Keeping the concrete maximum beside the kind lets the UI say what was
    /// searched without duplicating the crawler's constants.
    struct TraversalLimit: Equatable, Hashable, Sendable {
        enum Kind: Int, CaseIterable, Sendable {
            case files
            case directories
            case visitedEntries
        }

        let kind: Kind
        let maximum: Int
    }

    /// Whether an enumeration covered its whole reachable tree. Cancellation
    /// is separate from deterministic caps because a superseded query should
    /// be retried, while a capped query should tell the user its exact scope.
    struct EnumerationCompletion: Equatable, Sendable {
        let limits: [TraversalLimit]
        let wasCancelled: Bool

        init(limits: [TraversalLimit] = [], wasCancelled: Bool = false) {
            var limitsByKind: [TraversalLimit.Kind: TraversalLimit] = [:]
            for limit in limits {
                let normalized = TraversalLimit(
                    kind: limit.kind,
                    maximum: max(0, limit.maximum)
                )
                if let existing = limitsByKind[normalized.kind] {
                    limitsByKind[limit.kind] = TraversalLimit(
                        kind: normalized.kind,
                        maximum: min(existing.maximum, normalized.maximum)
                    )
                } else {
                    limitsByKind[normalized.kind] = normalized
                }
            }
            self.limits = TraversalLimit.Kind.allCases.compactMap { limitsByKind[$0] }
            self.wasCancelled = wasCancelled
        }

        static let complete = EnumerationCompletion()
        var isComplete: Bool { limits.isEmpty && !wasCancelled }

        func merging(_ other: EnumerationCompletion) -> EnumerationCompletion {
            EnumerationCompletion(
                limits: limits + other.limits,
                wasCancelled: wasCancelled || other.wasCancelled
            )
        }
    }

    /// Project-relative paths plus the evidence needed to interpret omissions.
    /// Collection conformance keeps existing path-only consumers lightweight;
    /// new callers can inspect `completion` instead of guessing from count.
    struct Enumeration: Equatable, Sendable, RandomAccessCollection {
        typealias Element = String
        typealias Index = Int

        let paths: [String]
        let completion: EnumerationCompletion

        init(paths: [String], completion: EnumerationCompletion = .complete) {
            self.paths = paths
            self.completion = completion
        }

        var startIndex: Int { paths.startIndex }
        var endIndex: Int { paths.endIndex }
        subscript(position: Int) -> String { paths[position] }
        func index(after index: Int) -> Int { paths.index(after: index) }
        func index(before index: Int) -> Int { paths.index(before: index) }
        func index(_ index: Int, offsetBy distance: Int) -> Int {
            paths.index(index, offsetBy: distance)
        }
        func distance(from start: Int, to end: Int) -> Int {
            paths.distance(from: start, to: end)
        }
    }

    /// Directories that never belong in a tree or fuzzy index.
    static let ignoredNames: Set<String> = [
        ".git", "node_modules", ".build", "dist", "DerivedData", ".swiftpm",
        "__pycache__", ".venv", ".next", ".turbo", "build",
    ]

    /// Why a directory listing came back short. `FileManager` reports every one
    /// of these the same way — an enumerator that yields nothing — so a folder
    /// Kaisola can't read is indistinguishable from a genuinely empty one
    /// unless the scan keeps the error the filesystem handed it.
    enum DirectoryLoadFailure: Equatable, Sendable {
        case permissionDenied
        case missing
        case notDirectory
        case cancelled
        /// A POSIX errno when the filesystem supplied one, otherwise 0.
        case ioFailure(code: Int32)

        /// Short enough for one row at the rail's narrowest width.
        var summary: String {
            switch self {
            case .permissionDenied:
                return "Can't read this folder"
            case .missing:
                return "This folder is gone"
            case .notDirectory:
                return "No longer a folder"
            case .cancelled:
                return "Listing was interrupted"
            case .ioFailure:
                return "Couldn't list this folder"
            }
        }

        /// The actionable half: what the filesystem said, and where to look.
        var diagnostic: String {
            switch self {
            case .permissionDenied:
                return """
                Kaisola doesn't have permission to list this folder. Check its \
                permissions, or grant access under System Settings > Privacy & \
                Security > Files and Folders.
                """
            case .missing:
                return "This folder no longer exists on disk. It may have been moved, renamed, or deleted."
            case .notDirectory:
                return "Something replaced this folder with a file."
            case .cancelled:
                return "Listing this folder stopped before it finished, so its contents may be incomplete."
            case .ioFailure(let code):
                guard code != 0, let reason = strerror(code) else {
                    return "The filesystem reported an error while listing this folder."
                }
                return "The filesystem reported an error while listing this folder: \(String(cString: reason))."
            }
        }
    }

    /// A directory's immediate children together with the reason the list may
    /// be short. No nodes and no failure is a real, quiet empty folder.
    struct DirectoryListing: Equatable, Sendable {
        var nodes: [FileNode]
        var failure: DirectoryLoadFailure?

        static let empty = DirectoryListing(nodes: [], failure: nil)

        /// A legitimately empty folder — nothing for the rail to report.
        var isEmptyAndReadable: Bool { nodes.isEmpty && failure == nil }
    }

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

    /// The same listing as `children(of:)`, keeping why an unreadable, deleted,
    /// or failing folder came back empty so the rail can say so.
    static func listing(
        of directory: URL,
        limit: Int = .max,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> DirectoryListing {
        let scan = scanChildren(of: directory, limit: limit, isCancelled: isCancelled)
        return DirectoryListing(nodes: scan.nodes, failure: scan.failure)
    }

    private static func scanChildren(
        of directory: URL,
        limit: Int,
        isCancelled: () -> Bool
    ) -> (nodes: [FileNode], failure: DirectoryLoadFailure?, visited: Int, reachedLimit: Bool) {
        guard limit > 0 else { return ([], nil, 0, false) }
        guard !isCancelled() else { return ([], .cancelled, 0, false) }
        // The error-handling enumerator is the only way to learn *why* a
        // directory refused to list. The plain one hands back an empty
        // sequence for permission denied, a deleted folder, and an I/O fault
        // alike, which is exactly the confusion this scan has to remove.
        let directoryPath = resolvedPath(directory)
        var failure: DirectoryLoadFailure?
        guard let contents = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                // A single child Kaisola can't stat is not a reason to fail the
                // whole folder; only an error about the folder itself stops it.
                guard resolvedPath(url) == directoryPath else { return true }
                failure = loadFailure(for: error as NSError)
                return false
            }
        ) else { return ([], probedFailure(for: directory) ?? .ioFailure(code: 0), 0, false) }
        var nodes: [FileNode] = []
        if limit != .max { nodes.reserveCapacity(min(limit, 256)) }
        var visited = 0
        var reachedLimit = false
        while let url = contents.nextObject() as? URL {
            // Hitting the caller's limit is deliberate bounding, not a failure;
            // being cancelled mid-walk leaves a truncated list that is.
            if isCancelled() {
                failure = .cancelled
                break
            }
            guard visited < limit else {
                reachedLimit = true
                break
            }
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
        return (sorted, failure, visited, reachedLimit)
    }

    /// Map what `FileManager` reported onto the five outcomes the rail knows
    /// how to explain. The POSIX errno is the precise one; the Cocoa code is
    /// the fallback for errors that arrive without an underlying error.
    private static func loadFailure(for error: NSError) -> DirectoryLoadFailure {
        var posixCode: Int32 = 0
        if error.domain == NSPOSIXErrorDomain {
            posixCode = Int32(exactly: error.code) ?? 0
        } else if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying.domain == NSPOSIXErrorDomain {
            posixCode = Int32(exactly: underlying.code) ?? 0
        }
        switch posixCode {
        case EACCES, EPERM:
            return .permissionDenied
        case ENOENT:
            return .missing
        case ENOTDIR:
            return .notDirectory
        default:
            break
        }
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoPermissionError:
                return .permissionDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .missing
            default:
                break
            }
        }
        return .ioFailure(code: posixCode)
    }

    /// Last resort for the rare case where `FileManager` refuses to hand back
    /// an enumerator at all and so never reports an error: ask the filesystem.
    private static func probedFailure(for directory: URL) -> DirectoryLoadFailure? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else { return .notDirectory }
        guard FileManager.default.isReadableFile(atPath: directory.path) else {
            return .permissionDenied
        }
        return nil
    }

    /// `/var` and `/private/var` name the same folder, and the enumerator's
    /// error handler is free to report either spelling.
    private static func resolvedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Recursively enumerate project files for fuzzy search, bounded so a huge
    /// tree cannot stall the palette. Returns project-relative paths together
    /// with the exact traversal budget or cancellation that made them partial.
    static func enumerate(
        root: URL,
        limit: Int = defaultFileLimit,
        directoryLimit: Int = defaultDirectoryLimit,
        visitLimit: Int = defaultVisitLimit,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> Enumeration {
        let initiallyCancelled = isCancelled()
        var invalidLimits: [TraversalLimit] = []
        if limit <= 0 { invalidLimits.append(.init(kind: .files, maximum: 0)) }
        if directoryLimit <= 0 { invalidLimits.append(.init(kind: .directories, maximum: 0)) }
        if visitLimit <= 0 { invalidLimits.append(.init(kind: .visitedEntries, maximum: 0)) }
        guard invalidLimits.isEmpty, !initiallyCancelled else {
            return Enumeration(
                paths: [],
                completion: EnumerationCompletion(
                    limits: invalidLimits,
                    wasCancelled: initiallyCancelled
                )
            )
        }
        var results: [String] = []
        var queue: [URL] = [root]
        var queueIndex = 0
        var visitedEntries = 0
        var reachedLimits: [TraversalLimit] = []
        var wasCancelled = false
        let rootPath = root.standardizedFileURL.path
        while queueIndex < queue.count {
            if isCancelled() {
                wasCancelled = true
                break
            }
            if visitedEntries >= visitLimit {
                reachedLimits.append(.init(kind: .visitedEntries, maximum: visitLimit))
                break
            }
            let directory = queue[queueIndex]
            queueIndex += 1
            let scan = scanChildren(
                of: directory,
                limit: visitLimit - visitedEntries,
                isCancelled: isCancelled
            )
            visitedEntries += scan.visited
            if scan.failure == .cancelled {
                return Enumeration(
                    paths: results,
                    completion: EnumerationCompletion(
                        limits: reachedLimits,
                        wasCancelled: true
                    )
                )
            }
            if scan.reachedLimit {
                reachedLimits.append(.init(kind: .visitedEntries, maximum: visitLimit))
            }
            for node in scan.nodes {
                guard !isCancelled() else {
                    return Enumeration(
                        paths: results,
                        completion: EnumerationCompletion(
                            limits: reachedLimits,
                            wasCancelled: true
                        )
                    )
                }
                if node.isDirectory {
                    // Never enqueue more work than this traversal is allowed
                    // to visit. This also caps memory used by the BFS queue.
                    if queue.count < directoryLimit {
                        queue.append(node.url)
                    } else {
                        reachedLimits.append(.init(kind: .directories, maximum: directoryLimit))
                    }
                } else {
                    let path = node.url.path
                    if path.hasPrefix(rootPath + "/") {
                        guard results.count < limit else {
                            return Enumeration(
                                paths: results,
                                completion: EnumerationCompletion(
                                    limits: reachedLimits + [.init(kind: .files, maximum: limit)]
                                )
                            )
                        }
                        results.append(String(path.dropFirst(rootPath.count + 1)))
                    }
                }
            }
            if scan.reachedLimit { break }
        }
        return Enumeration(
            paths: results,
            completion: EnumerationCompletion(
                limits: reachedLimits,
                wasCancelled: wasCancelled
            )
        )
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
        updatingEnumeration(
            Enumeration(paths: existing),
            root: root,
            changedPaths: changedPaths,
            limit: limit,
            directoryLimit: directoryLimit,
            visitLimit: visitLimit,
            isCancelled: isCancelled
        )?.paths
    }

    /// Metadata-preserving counterpart used by the cached search index. A
    /// partial prior walk stays partial after a targeted patch: adding one
    /// known file cannot prove that previously omitted subtrees are complete.
    static func updatingIndex(
        _ existing: Enumeration,
        root: URL,
        changedPaths: [URL],
        limit: Int = defaultFileLimit,
        directoryLimit: Int = defaultDirectoryLimit,
        visitLimit: Int = defaultVisitLimit,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> Enumeration? {
        updatingEnumeration(
            existing,
            root: root,
            changedPaths: changedPaths,
            limit: limit,
            directoryLimit: directoryLimit,
            visitLimit: visitLimit,
            isCancelled: isCancelled
        )
    }

    static func updatingEnumeration(
        _ existing: Enumeration,
        root: URL,
        changedPaths: [URL],
        limit: Int = defaultFileLimit,
        directoryLimit: Int = defaultDirectoryLimit,
        visitLimit: Int = defaultVisitLimit,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> Enumeration? {
        guard limit > 0 else {
            return Enumeration(
                paths: [],
                completion: .init(limits: [.init(kind: .files, maximum: 0)])
            )
        }
        guard !isCancelled() else {
            return Enumeration(paths: [], completion: .init(wasCancelled: true))
        }
        let normalizedRoot = root.standardizedFileURL
        let rootPath = normalizedRoot.path
        var relativeChanges: Set<String> = []
        for changedPath in changedPaths {
            guard !isCancelled() else {
                return Enumeration(paths: [], completion: .init(wasCancelled: true))
            }
            let path = changedPath.standardizedFileURL.path
            if path == rootPath { return nil }
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            guard isIndexableRelativePath(relative) else { continue }
            relativeChanges.insert(relative)
        }
        guard !relativeChanges.isEmpty else { return existing }

        var files = Set(existing.paths)
        let orderedChanges = relativeChanges.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        for relative in orderedChanges {
            let prefix = relative + "/"
            files = Set(files.filter { $0 != relative && !$0.hasPrefix(prefix) })
        }

        var additions: [String] = []
        var completion = existing.completion
        additions.reserveCapacity(min(limit, 256))
        for relative in orderedChanges where additions.count < limit {
            guard !isCancelled() else {
                return Enumeration(
                    paths: [],
                    completion: completion.merging(.init(wasCancelled: true))
                )
            }
            let candidate = normalizedRoot.appendingPathComponent(relative).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isSafeIndexCandidate(candidate, root: normalizedRoot) else { continue }
            if isDirectory.boolValue {
                let remaining = limit - additions.count
                let enumeration = enumerate(
                    root: candidate,
                    limit: remaining,
                    directoryLimit: directoryLimit,
                    visitLimit: visitLimit,
                    isCancelled: isCancelled
                )
                additions.append(contentsOf: enumeration.paths.map { relative + "/" + $0 })
                completion = completion.merging(enumeration.completion)
            } else {
                additions.append(relative)
            }
        }
        files.formUnion(additions)
        let ordered = Array(files).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        if ordered.count > limit {
            completion = completion.merging(.init(
                limits: [.init(kind: .files, maximum: limit)]
            ))
        }
        return Enumeration(
            paths: Array(ordered.prefix(limit)),
            completion: completion
        )
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

/// Copy shared by the file rail's partial-result states. The crawler supplies
/// the numbers; this formatter only turns them into a concise, inspectable
/// explanation and a route back to folder-by-folder browsing.
enum ProjectFileSearchPresentation {
    struct Notice: Equatable, Sendable {
        let title: String
        let detail: String
        let actionTitle: String
    }

    static func notice(for completion: ProjectFiles.EnumerationCompletion) -> Notice? {
        guard !completion.isComplete else { return nil }
        let scopes = completion.limits.map { limit -> String in
            let amount = grouped(limit.maximum)
            switch limit.kind {
            case .files:
                return "\(amount) files"
            case .directories:
                return "\(amount) folders"
            case .visitedEntries:
                return "\(amount) items"
            }
        }
        let detail: String
        if scopes.isEmpty {
            detail = "Indexing was interrupted before it finished."
        } else {
            let scope = list(scopes)
            detail = completion.wasCancelled
                ? "Search stopped at \(scope) and was interrupted."
                : "Search stopped at \(scope)."
        }
        return Notice(
            title: "Partial results",
            detail: detail,
            actionTitle: "Browse folders"
        )
    }

    private static func list(_ values: [String]) -> String {
        switch values.count {
        case 0:
            return ""
        case 1:
            return values[0]
        case 2:
            return values.joined(separator: " and ")
        default:
            return values.dropLast().joined(separator: ", ") + ", and " + values.last!
        }
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }
}

/// A small TTL cache of project file lists so the palette doesn't re-walk the
/// tree on every keystroke.
@MainActor
final class ProjectFileIndex {
    static let shared = ProjectFileIndex()

    private struct InFlightWalk {
        let id: UUID
        let task: Task<ProjectFiles.Enumeration, Never>
    }

    private struct PendingInvalidation {
        var paths: Set<String> = []
        var requiresFullRefresh = false
    }

    private var cache: [String: (at: Date, result: ProjectFiles.Enumeration)] = [:]

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
    private var retiring: [String: Task<ProjectFiles.Enumeration, Never>] = [:]
    private var generationByRoot: [String: Int] = [:]
    private var pendingInvalidations: [String: PendingInvalidation] = [:]
    private let enumerateResult: @Sendable (URL) -> ProjectFiles.Enumeration

    init(
        enumerateResult: @escaping @Sendable (URL) -> ProjectFiles.Enumeration = {
            ProjectFiles.enumerate(root: $0)
        }
    ) {
        self.enumerateResult = enumerateResult
    }

    /// Compatibility for path-only consumers such as link completion. Search
    /// surfaces call `snapshot` so they cannot lose the traversal receipt.
    convenience init(enumerateFiles: @escaping @Sendable (URL) -> [String]) {
        self.init(enumerateResult: { root in
            ProjectFiles.Enumeration(paths: enumerateFiles(root))
        })
    }

    func files(for root: URL, now: Date = Date()) async -> [String] {
        await snapshot(for: root, now: now).paths
    }

    func snapshot(for root: URL, now: Date = Date()) async -> ProjectFiles.Enumeration {
        let key = root.standardizedFileURL.path
        if pendingInvalidations[key] == nil,
           let cached = cache[key], now.timeIntervalSince(cached.at) < 30 {
            return cached.result
        }
        if let existing = inFlight[key] {
            let joinedGeneration = generationByRoot[key, default: 0]
            let result = await existing.task.value
            if joinedGeneration == generationByRoot[key, default: 0], !existing.task.isCancelled {
                return result
            }
            guard !Task.isCancelled else {
                return ProjectFiles.Enumeration(
                    paths: [],
                    completion: .init(wasCancelled: true)
                )
            }
            return await self.snapshot(for: root)
        }
        let currentGeneration = generationByRoot[key, default: 0]
        let predecessor = retiring.removeValue(forKey: key)
        let invalidation = pendingInvalidations.removeValue(forKey: key)
        let cachedResult = cache[key]?.result
        let walkID = UUID()
        let enumerateResult = self.enumerateResult
        let task: Task<ProjectFiles.Enumeration, Never> = Task.detached(priority: .utility) {
            if let predecessor {
                _ = await predecessor.value
            }
            guard !Task.isCancelled else {
                return ProjectFiles.Enumeration(
                    paths: [],
                    completion: .init(wasCancelled: true)
                )
            }
            if let invalidation,
               !invalidation.requiresFullRefresh,
               let cachedResult {
                let paths = invalidation.paths.map { URL(fileURLWithPath: $0) }
                if let result = ProjectFiles.updatingEnumeration(
                    cachedResult,
                    root: root,
                    changedPaths: paths
                ) {
                    return result
                }
            }
            return enumerateResult(root)
        }
        inFlight[key] = InFlightWalk(id: walkID, task: task)
        let result = await task.value
        // An invalidated caller may finish after a replacement has started.
        // Only the walk that still owns this slot may clear or populate it.
        let stillOwnsSlot = inFlight[key]?.id == walkID
        if stillOwnsSlot {
            inFlight[key] = nil
        }
        if stillOwnsSlot,
           generationByRoot[key, default: 0] == currentGeneration,
           !task.isCancelled {
            cache[key] = (now, result)
            return result
        }
        // An invalidated walk may contain a partial traversal. Join the current
        // generation instead of leaking that stale list to the palette.
        guard !Task.isCancelled else {
            return ProjectFiles.Enumeration(
                paths: [],
                completion: .init(wasCancelled: true)
            )
        }
        return await self.snapshot(for: root)
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
    @Published private(set) var listingsByDirectory: [String: ProjectFiles.DirectoryListing] = [:]
    @Published private(set) var loadingDirectories: Set<String> = []
    @Published private(set) var searchResults: [String] = []
    @Published private(set) var searchCompletion: ProjectFiles.EnumerationCompletion = .complete
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
        listingsByDirectory[directory.standardizedFileURL.path]?.nodes
    }

    /// Why a loaded directory's list is short, if it is. `nil` covers healthy
    /// folders, including the ones that are legitimately empty.
    func loadFailure(for directory: URL) -> ProjectFiles.DirectoryLoadFailure? {
        listingsByDirectory[directory.standardizedFileURL.path]?.failure
    }

    func load(_ directory: URL, force: Bool = false) {
        let normalized = directory.standardizedFileURL
        let key = normalized.path
        if !force, listingsByDirectory[key] != nil { return }
        directoryTasks[key]?.cancel()
        loadingDirectories.insert(key)
        directoryTasks[key] = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                ProjectFiles.listing(of: normalized, isCancelled: { Task.isCancelled })
            }
            let listing = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.listingsByDirectory[key] = listing
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
        let loaded = Set(listingsByDirectory.keys)
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
            let staleKeys = listingsByDirectory.keys.filter {
                $0 == removed || $0.hasPrefix(prefix)
            }
            for key in staleKeys {
                listingsByDirectory[key] = nil
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
            searchCompletion = .complete
            isSearching = false
            return
        }
        isSearching = true
        let root = self.root
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            let enumeration = await ProjectFileIndex.shared.snapshot(for: root)
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                Array(enumeration.paths.lazy.filter {
                    $0.localizedCaseInsensitiveContains(query)
                }.prefix(200))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.searchResults = matches
            self.searchCompletion = enumeration.completion
            self.isSearching = false
        }
    }
}
