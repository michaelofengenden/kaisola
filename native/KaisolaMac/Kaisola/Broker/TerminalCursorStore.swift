import CryptoKit
import Darwin
import Foundation

struct TerminalCursorScope: Equatable, Hashable, Sendable {
    let brokerIdentity: String
    let projectID: String
    let terminalID: String

    init(brokerIdentity: String, projectID: String, terminalID: String) {
        self.brokerIdentity = brokerIdentity
        self.projectID = projectID
        self.terminalID = terminalID
    }

    fileprivate var isValid: Bool {
        brokerIdentity.count == 64
            && brokerIdentity.allSatisfy(\.isHexDigit)
            && projectID.range(of: #"^[a-zA-Z0-9_.:-]{1,160}$"#, options: .regularExpression) != nil
            && !terminalID.isEmpty
            && terminalID.count <= 240
            && !terminalID.contains("\u{0}")
    }

    fileprivate var storageKey: String {
        let material = [brokerIdentity, projectID, terminalID].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

actor TerminalCursorStore {
    private static let schemaVersion = 1
    private static let maximumEntries = 4_096
    private static let maximumArchiveBytes: off_t = 4 * 1_024 * 1_024

    private struct Archive: Codable {
        var schemaVersion: Int
        var entries: [String: Entry]

        static let empty = Archive(schemaVersion: TerminalCursorStore.schemaVersion, entries: [:])
    }

    private struct Entry: Codable {
        let brokerIdentity: String
        let projectID: String
        let terminalID: String
        let streamEpoch: String
        let offset: Int64
        let updatedAtMilliseconds: Int64

        var scope: TerminalCursorScope {
            TerminalCursorScope(
                brokerIdentity: brokerIdentity,
                projectID: projectID,
                terminalID: terminalID
            )
        }

        var cursor: TerminalCursor? {
            guard scope.isValid,
                  !streamEpoch.isEmpty,
                  streamEpoch.count <= 160,
                  !streamEpoch.contains("\u{0}"),
                  offset >= 0 else { return nil }
            return TerminalCursor(streamEpoch: streamEpoch, offset: offset)
        }
    }

    enum StoreError: Error, Equatable {
        case invalidScope
        case unsafePath
        case oversizedArchive
        case unsupportedSchema
    }

    private let fileURL: URL
    private let currentUserID: uid_t

    init(fileURL: URL, currentUserID: uid_t = getuid()) {
        self.fileURL = fileURL
        self.currentUserID = currentUserID
    }

    func cursor(for scope: TerminalCursorScope) throws -> TerminalCursor? {
        guard scope.isValid else { throw StoreError.invalidScope }
        let archive = try loadArchive()
        guard let entry = archive.entries[scope.storageKey], entry.scope == scope else { return nil }
        return entry.cursor
    }

    func save(_ cursor: TerminalCursor, for scope: TerminalCursorScope) throws {
        guard scope.isValid,
              !cursor.streamEpoch.isEmpty,
              cursor.streamEpoch.count <= 160,
              !cursor.streamEpoch.contains("\u{0}"),
              cursor.offset >= 0 else { throw StoreError.invalidScope }

        var archive = try loadArchive()
        let key = scope.storageKey
        if let existing = archive.entries[key],
           existing.scope == scope,
           existing.streamEpoch == cursor.streamEpoch,
           existing.offset >= cursor.offset {
            return
        }
        archive.entries[key] = Entry(
            brokerIdentity: scope.brokerIdentity,
            projectID: scope.projectID,
            terminalID: scope.terminalID,
            streamEpoch: cursor.streamEpoch,
            offset: cursor.offset,
            updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        if archive.entries.count > Self.maximumEntries {
            let excess = archive.entries.count - Self.maximumEntries
            for staleKey in archive.entries
                .sorted(by: { $0.value.updatedAtMilliseconds < $1.value.updatedAtMilliseconds })
                .prefix(excess)
                .map(\.key) {
                archive.entries.removeValue(forKey: staleKey)
            }
        }
        try writeArchive(archive)
    }

    private func loadArchive() throws -> Archive {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let metadata = try validatePrivatePath(fileURL, expectedKind: S_IFREG)
        guard metadata.st_size <= Self.maximumArchiveBytes else { throw StoreError.oversizedArchive }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.schemaVersion == Self.schemaVersion else { throw StoreError.unsupportedSchema }
        guard archive.entries.count <= Self.maximumEntries else { throw StoreError.oversizedArchive }
        return archive
    }

    private func writeArchive(_ archive: Archive) throws {
        let directory = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            // Validate before chmod: chmod follows symlinks and must never
            // mutate a path an attacker substituted for native app state.
            _ = try validatePrivatePath(directory, expectedKind: S_IFDIR)
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(directory.path, 0o700)
        }
        _ = try validatePrivatePath(directory, expectedKind: S_IFDIR)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try validatePrivatePath(fileURL, expectedKind: S_IFREG)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= Self.maximumArchiveBytes else { throw StoreError.oversizedArchive }

        let temporaryURL = directory.appendingPathComponent(".terminal-cursors-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        _ = chmod(temporaryURL.path, 0o600)
        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = chmod(fileURL.path, 0o600)
    }

    @discardableResult
    private func validatePrivatePath(_ url: URL, expectedKind: mode_t) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_uid == currentUserID,
              value.st_mode & S_IFMT == expectedKind,
              value.st_mode & 0o077 == 0 else {
            throw StoreError.unsafePath
        }
        return value
    }
}
