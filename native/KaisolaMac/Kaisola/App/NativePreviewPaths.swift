import Darwin
import Foundation

enum NativePreviewPaths {
    static let applicationSupportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.kaisola.mac.preview", isDirectory: true)

    static let terminalCursorStore = applicationSupportDirectory
        .appendingPathComponent("terminal-cursors-v1.json", isDirectory: false)

    static let helperRegistrationRecord = applicationSupportDirectory
        .appendingPathComponent("broker-helper-registration-v1", isDirectory: false)

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
}

enum NativePreviewPathError: Error, Equatable {
    case unsafeApplicationSupport
}
