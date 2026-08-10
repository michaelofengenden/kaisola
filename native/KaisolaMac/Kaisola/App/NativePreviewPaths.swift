import Darwin
import Foundation
import KaisolaCore

enum NativePreviewPaths {
    static let applicationSupportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.kaisola.mac.preview", isDirectory: true)

    static let terminalCursorStore = applicationSupportDirectory
        .appendingPathComponent("terminal-cursors-v1.json", isDirectory: false)

    static let agentChatTranscriptStore = applicationSupportDirectory
        .appendingPathComponent("agent-chat-transcripts-v1.json", isDirectory: false)

    /// Page-oriented v2 transcript storage. The adjacent v1 JSON remains the
    /// immutable migration source and rollback copy after first successful use.
    static let agentChatTranscriptDatabase = applicationSupportDirectory
        .appendingPathComponent("agent-chat-transcripts-v2.sqlite3", isDirectory: false)

    static let helperRegistrationRecord = applicationSupportDirectory
        .appendingPathComponent("broker-helper-registration-v1", isDirectory: false)

    static let companionDirectory = applicationSupportDirectory
        .appendingPathComponent("companion", isDirectory: true)

    static let companionDevices = companionDirectory
        .appendingPathComponent("devices-v1.json", isDirectory: false)

    static func companionDevices(
        accountScope: CompanionAccountScope,
        directory: URL = companionDirectory
    ) -> URL {
        directory.appendingPathComponent(
            "devices-v3-\(accountScope.rawValue).json",
            isDirectory: false
        )
    }

    /// Durable, app-owned Git worktrees for Mesh editing columns. These must
    /// not live in `/tmp`: macOS may purge temporary files across a reboot,
    /// which would discard unintegrated agent work even when the registered
    /// branch still exists.
    static let meshWorktreesDirectory = applicationSupportDirectory
        .appendingPathComponent("mesh-worktrees", isDirectory: true)

    static func prepareApplicationSupport(at directory: URL = applicationSupportDirectory) throws {
        var metadata = stat()
        if lstat(directory.path, &metadata) == 0 {
            guard metadata.st_uid == getuid(),
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_mode & 0o077 == 0 else {
                throw NativePreviewPathError.unsafeApplicationSupport
            }
            return
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, 0o700)
        guard lstat(directory.path, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o077 == 0 else {
            throw NativePreviewPathError.unsafeApplicationSupport
        }
    }

    static func prepareMeshWorktrees(at directory: URL = meshWorktreesDirectory) throws {
        if directory.standardizedFileURL == meshWorktreesDirectory.standardizedFileURL {
            try prepareApplicationSupport()
        }
        var metadata = stat()
        if lstat(directory.path, &metadata) == 0 {
            guard metadata.st_uid == getuid(),
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_mode & 0o077 == 0 else {
                throw NativePreviewPathError.unsafeMeshWorktrees
            }
            return
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, 0o700)
        guard lstat(directory.path, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o077 == 0 else {
            throw NativePreviewPathError.unsafeMeshWorktrees
        }
    }

    static func prepareCompanionDirectory(at directory: URL = companionDirectory) throws {
        if directory.standardizedFileURL == companionDirectory.standardizedFileURL {
            try prepareApplicationSupport()
        }
        var metadata = stat()
        if lstat(directory.path, &metadata) == 0 {
            guard metadata.st_uid == getuid(),
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_mode & 0o077 == 0 else {
                throw NativePreviewPathError.unsafeCompanionDirectory
            }
            return
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(directory.path, 0o700)
        guard lstat(directory.path, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o077 == 0 else {
            throw NativePreviewPathError.unsafeCompanionDirectory
        }
    }
}

enum NativePreviewPathError: Error, Equatable {
    case unsafeApplicationSupport
    case unsafeMeshWorktrees
    case unsafeCompanionDirectory
}
