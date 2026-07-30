import AppKit
import CryptoKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Synchronous lifecycle barrier posted before AppKit hides windows for
    /// termination. File editors own their drafts locally, so they flush while
    /// those views are still mounted and only then does model teardown begin.
    static let kaisolaFlushFilePreviews = Notification.Name("kaisolaFlushFilePreviews")
    /// Synchronous request posted immediately before a workspace file rename
    /// or Trash operation. A mounted editor gets one chance to save its draft;
    /// an unresolved conflict vetoes the mutation.
    static let kaisolaPrepareWorkspaceFileMutation = Notification.Name("kaisolaPrepareWorkspaceFileMutation")
    /// App-menu request scoped to one AppModel/window. The mounted editor owns
    /// the dirty-state prompt, so Command-W must enter here rather than having
    /// the menu mutate the model directly.
    static let kaisolaCloseActiveFileTab = Notification.Name("kaisolaCloseActiveFileTab")
}

/// Mutable by design: NotificationCenter delivery is synchronous on the
/// posting thread, so the mounted preview can veto a filesystem mutation before
/// the rail starts its detached operation.
@MainActor
final class WorkspaceFileMutationBarrierRequest {
    let item: URL
    private(set) var mayProceed = true

    init(item: URL) {
        self.item = item.standardizedFileURL
    }

    func block() {
        mayProceed = false
    }
}

/// What a file resolves to for previewing/editing. Pure so tests can drive it.
enum FilePreviewContent: Equatable, Sendable {
    case text(String)
    case markdown(String)
    case csv(String)
    case json(String)
    case html(String)
    case docx
    case image
    case tooLarge(Int)
    case binary
    case unreadable

    static let maxTextBytes = 1_048_576
    static let maxImageBytes = 25 * 1_048_576
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "svg", "icns"]

    static func load(url: URL) -> FilePreviewContent {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int else { return .unreadable }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return size <= maxImageBytes ? .image : .tooLarge(size)
        }
        if ext == "docx" { return size <= maxDocumentBytes ? .docx : .tooLarge(size) }
        guard size <= maxTextBytes else { return .tooLarge(size) }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        guard let text = String(data: data, encoding: .utf8) else { return .binary }
        if ext == "html" || ext == "htm" { return .html(text) }
        if ext == "csv" || ext == "tsv" { return .csv(text) }
        if ext == "json" { return .json(text) }
        return ext == "md" || ext == "markdown" ? .markdown(text) : .text(text)
    }

    static let maxDocumentBytes = 20 * 1_048_576
}

/// AppKit's Office Open XML reader/writer is synchronous and the attributed
/// string classes predate Sendable. Keep that work off the main actor and move
/// the immutable result across the boundary in this explicit wrapper.
struct RichDocumentPayload: @unchecked Sendable {
    let value: NSAttributedString
}

enum RichDocumentIO {
    static func load(url: URL) -> RichDocumentPayload? {
        guard let value = try? NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        ) else { return nil }
        return RichDocumentPayload(value: value)
    }

    static func write(_ value: NSAttributedString, to url: URL) throws {
        try data(value).write(to: url, options: .atomic)
    }

    static func data(_ value: NSAttributedString) throws -> Data {
        try value.data(
            from: NSRange(location: 0, length: value.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
    }

    static func load(data: Data) -> RichDocumentPayload? {
        guard let value = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        ) else { return nil }
        return RichDocumentPayload(value: value)
    }
}

struct FilePreviewRecoveryToken: Codable, Equatable, Hashable, Sendable {
    let ownerID: String
    let revision: UInt64
    let payloadDigest: String
}

struct FilePreviewRecoveryRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case richDocument
        case tombstone
    }

    let version: Int
    let filePath: String
    let workspacePath: String
    let ownerID: String
    let revision: UInt64
    let payloadDigest: String
    let kind: Kind
    let text: String?
    let richDocumentData: Data?
    let expectedModificationDate: Date?
    let updatedAt: Date
    /// Exact predecessor records inherited while an orphan is claimed. Keeping
    /// this lineage in the durable record prevents an older draft from
    /// resurfacing if the app crashes again before the recovered edit is saved.
    let sourceTokens: [FilePreviewRecoveryToken]?
    /// Present only for high-water tombstones. It lets pruning distinguish a
    /// current-process fence and retain it exactly while the in-flight write
    /// registry still contains a revision at or below its high-water mark.
    let fenceProcessID: String?

    var token: FilePreviewRecoveryToken {
        FilePreviewRecoveryToken(
            ownerID: ownerID,
            revision: revision,
            payloadDigest: payloadDigest
        )
    }
}

struct FilePreviewRecoveryClaim: Equatable, Sendable {
    let record: FilePreviewRecoveryRecord
    let sourceTokens: [FilePreviewRecoveryToken]
}

/// A process-local registration created before an off-main recovery write is
/// launched. Fences can be retired as soon as every registration at or below
/// their high-water revision completes, rather than pinning tombstones for the
/// lifetime of the process.
struct FilePreviewRecoveryWriteRegistration: Hashable, Sendable {
    fileprivate let slotKey: String
    fileprivate let identifier: UUID
    let revision: UInt64
}

/// Pure view policy shared by the recovery store and focused tests. A live
/// editor's record is never a restore candidate; only an owner absent from the
/// process registry can be claimed by a newly opened preview.
enum FilePreviewRecoveryViewPolicy {
    static func newestRestorable(
        in records: [FilePreviewRecoveryRecord],
        activeOwnerIDs: Set<String>,
        alreadyClaimed: Set<FilePreviewRecoveryToken> = []
    ) -> FilePreviewRecoveryRecord? {
        records.filter {
            $0.kind != .tombstone
                && !activeOwnerIDs.contains($0.ownerID)
                && !alreadyClaimed.contains($0.token)
        }.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
            return lhs.ownerID < rhs.ownerID
        }
    }

    static func tokensToResolve(
        ownedToken: FilePreviewRecoveryToken?,
        claimedSourceTokens: [FilePreviewRecoveryToken]
    ) -> [FilePreviewRecoveryToken] {
        var seen = Set<FilePreviewRecoveryToken>()
        return ([ownedToken].compactMap { $0 } + claimedSourceTokens).filter { seen.insert($0).inserted }
    }
}

/// Process-local liveness is intentionally separate from the on-disk journal.
/// Owner UUIDs from a prior process are absent and therefore recoverable; UUIDs
/// belonging to currently mounted windows are protected from other windows.
final class FilePreviewRecoveryOwnerRegistry: @unchecked Sendable {
    static let shared = FilePreviewRecoveryOwnerRegistry()

    private let lock = NSLock()
    private var activeOwnerIDs: Set<String> = []

    func register(_ ownerID: String) {
        lock.lock()
        activeOwnerIDs.insert(ownerID)
        lock.unlock()
    }

    func unregister(_ ownerID: String) {
        lock.lock()
        activeOwnerIDs.remove(ownerID)
        lock.unlock()
    }

    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return activeOwnerIDs
    }

    /// Keeps registration and recovery selection in one linear order. A view
    /// that registers first is visible to the selection; a view whose register
    /// waits until afterward cannot yet have begun loading or journaling.
    func withActiveOwnerIDs<T>(_ operation: (Set<String>) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation(activeOwnerIDs)
    }
}

/// A small crash/restart journal for editable previews. Each record is scoped
/// to one canonical project/file pair, written atomically with owner-only
/// permissions, and capped both per-entry and globally. The journal is not an
/// alternate document store: callers remove a record as soon as its draft is
/// confirmed on disk.
struct FilePreviewRecoveryStore: Sendable {
    enum DurabilityEvent: Equatable, Sendable {
        case removedSource
        case synchronizedSourceDeletions
        case removedTombstone
        case synchronizedTombstoneDeletion
        case removedLineageDescendant
        case synchronizedLineageDescendantDeletion
    }

    static let maxEntries = 64
    static let maxStoredBytes = 256 * 1_048_576
    static let maxEncodedRecordBytes = 32 * 1_048_576
    private static let mutationLock = NSLock()
    private nonisolated(unsafe) static var claimedRecords: [String: String] = [:]
    private nonisolated(unsafe) static var inFlightWrites: [String: [UUID: UInt64]] = [:]
    private nonisolated(unsafe) static var pendingFenceRetirements: [String: FenceRetirement] = [:]
    private static let currentProcessID = UUID().uuidString.lowercased()

    private struct FenceRetirement: Sendable {
        let token: FilePreviewRecoveryToken
        let throughRevision: UInt64
    }

    let directoryURL: URL
    private let processID: String
    private let durabilityObserver: (@Sendable (DurabilityEvent) -> Void)?

    init(
        directoryURL: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("file-preview-recovery-v1", isDirectory: true),
        processID: String = FilePreviewRecoveryStore.currentProcessID,
        durabilityObserver: (@Sendable (DurabilityEvent) -> Void)? = nil
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.processID = processID
        self.durabilityObserver = durabilityObserver
    }

    func saveText(
        _ text: String,
        for fileURL: URL,
        workspaceRoot: URL?,
        expectedModificationDate: Date?,
        ownerID: String,
        revision: UInt64,
        sourceTokens: [FilePreviewRecoveryToken] = []
    ) throws -> FilePreviewRecoveryToken {
        guard text.utf8.count <= FilePreviewContent.maxTextBytes else {
            throw RecoveryError.payloadTooLarge
        }
        let paths = try canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot)
        let digest = payloadDigest(kind: .text, data: Data(text.utf8))
        let record = FilePreviewRecoveryRecord(
            version: 1,
            filePath: paths.file,
            workspacePath: paths.workspace,
            ownerID: ownerID,
            revision: revision,
            payloadDigest: digest,
            kind: .text,
            text: text,
            richDocumentData: nil,
            expectedModificationDate: expectedModificationDate,
            updatedAt: Date(),
            sourceTokens: sourceTokens.isEmpty ? nil : sourceTokens,
            fenceProcessID: nil
        )
        try write(record)
        return record.token
    }

    func saveRichDocument(
        _ data: Data,
        for fileURL: URL,
        workspaceRoot: URL?,
        expectedModificationDate: Date?,
        ownerID: String,
        revision: UInt64,
        sourceTokens: [FilePreviewRecoveryToken] = []
    ) throws -> FilePreviewRecoveryToken {
        guard data.count <= FilePreviewContent.maxDocumentBytes else {
            throw RecoveryError.payloadTooLarge
        }
        let paths = try canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot)
        let digest = payloadDigest(kind: .richDocument, data: data)
        let record = FilePreviewRecoveryRecord(
            version: 1,
            filePath: paths.file,
            workspacePath: paths.workspace,
            ownerID: ownerID,
            revision: revision,
            payloadDigest: digest,
            kind: .richDocument,
            text: nil,
            richDocumentData: data,
            expectedModificationDate: expectedModificationDate,
            updatedAt: Date(),
            sourceTokens: sourceTokens.isEmpty ? nil : sourceTokens,
            fenceProcessID: nil
        )
        try write(record)
        return record.token
    }

    func loadNewest(for fileURL: URL, workspaceRoot: URL?) throws -> FilePreviewRecoveryRecord? {
        let paths = try canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot)
        return try withMutationLock {
            try prepareDirectory()
            let records = recoveryRecordURLs().compactMap { url -> FilePreviewRecoveryRecord? in
                guard let record = readRecord(at: url) else { return nil }
                guard record.filePath == paths.file,
                      record.workspacePath == paths.workspace else { return nil }
                return record
            }
            // Every durable descendant carries its exact predecessor lineage.
            // A legitimate journal may supersede a fence in the same owner
            // slot, so suppression cannot depend on tombstones alone.
            let resolvedTokens = Set(records.flatMap { $0.sourceTokens ?? [] })
            return records.filter {
                $0.kind != .tombstone && !resolvedTokens.contains($0.token)
            }.max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
                return lhs.ownerID < rhs.ownerID
            }
        }
    }

    /// Atomically selects an orphaned record and copies it to the claimant's
    /// owner-scoped slot. Source records remain until the recovered draft is
    /// resolved; their exact tokens are carried as durable lineage and marked
    /// claimed in-process so a second live window cannot restore them.
    func claimNewestOrphan(
        for fileURL: URL,
        workspaceRoot: URL?,
        claimantID: String,
        ownerRegistry: FilePreviewRecoveryOwnerRegistry = .shared,
        beforeSelection: (() -> Void)? = nil
    ) throws -> FilePreviewRecoveryClaim? {
        let paths = try canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot)
        beforeSelection?()
        return try ownerRegistry.withActiveOwnerIDs { activeOwnerIDs in
            try withMutationLock {
                try prepareDirectory()
                let records = recoveryRecordURLs().compactMap { url -> FilePreviewRecoveryRecord? in
                    guard let record = readRecord(at: url),
                          record.filePath == paths.file,
                          record.workspacePath == paths.workspace else { return nil }
                    return record
                }
                var claimed = Set(records.compactMap { record -> FilePreviewRecoveryToken? in
                    let key = claimKey(paths: paths, token: record.token)
                    return Self.claimedRecords[key] == nil ? nil : record.token
                })
                claimed.formUnion(records.flatMap { $0.sourceTokens ?? [] })
                guard let source = FilePreviewRecoveryViewPolicy.newestRestorable(
                    in: records,
                    activeOwnerIDs: activeOwnerIDs.union([claimantID]),
                    alreadyClaimed: claimed
                ) else { return nil }

                let lineage = FilePreviewRecoveryViewPolicy.tokensToResolve(
                    ownedToken: source.token,
                    claimedSourceTokens: source.sourceTokens ?? []
                )
                for token in lineage {
                    Self.claimedRecords[claimKey(paths: paths, token: token)] = claimantID
                }
                let claimedRecord = FilePreviewRecoveryRecord(
                    version: source.version,
                    filePath: source.filePath,
                    workspacePath: source.workspacePath,
                    ownerID: claimantID,
                    revision: source.revision,
                    payloadDigest: source.payloadDigest,
                    kind: source.kind,
                    text: source.text,
                    richDocumentData: source.richDocumentData,
                    expectedModificationDate: source.expectedModificationDate,
                    updatedAt: Date(),
                    sourceTokens: lineage,
                    fenceProcessID: nil
                )
                do {
                    try writePrepared(claimedRecord)
                } catch {
                    for token in lineage {
                        let key = claimKey(paths: paths, token: token)
                        if Self.claimedRecords[key] == claimantID { Self.claimedRecords[key] = nil }
                    }
                    throw error
                }
                return FilePreviewRecoveryClaim(record: claimedRecord, sourceTokens: lineage)
            }
        }
    }

    /// Installs a durable high-water mark in the same owner-scoped slot as the
    /// journal. Once this bounded tombstone is fsynced, every cancelled write
    /// at or below `revision` is rejected even if the process dies before any
    /// best-effort cleanup can run.
    func fence(
        ownerID: String,
        through revision: UInt64,
        for fileURL: URL,
        workspaceRoot: URL?,
        resolving sourceTokens: [FilePreviewRecoveryToken] = []
    ) throws -> FilePreviewRecoveryToken {
        guard revision < UInt64.max else { throw RecoveryError.staleRevision }
        let paths = try canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot)
        let fencedRevision = revision + 1
        let deduplicatedSources = FilePreviewRecoveryViewPolicy.tokensToResolve(
            ownedToken: nil,
            claimedSourceTokens: sourceTokens
        )
        let digest = tombstoneDigest(sourceTokens: deduplicatedSources)
        let record = FilePreviewRecoveryRecord(
            version: 1,
            filePath: paths.file,
            workspacePath: paths.workspace,
            ownerID: ownerID,
            revision: fencedRevision,
            payloadDigest: digest,
            kind: .tombstone,
            text: nil,
            richDocumentData: nil,
            expectedModificationDate: nil,
            updatedAt: Date(),
            sourceTokens: deduplicatedSources.isEmpty ? nil : deduplicatedSources,
            fenceProcessID: processID
        )
        // The view installs fences synchronously as a UI/lifecycle ordering
        // barrier. This path writes only a tiny bounded record and deliberately
        // leaves global pruning to ordinary off-main journal writes.
        try write(record, pruneAfterWrite: false)
        return record.token
    }

    /// Registers an off-main write before its task is launched. Registration
    /// and fence installation share `mutationLock`, so retirement can never
    /// overlook a writer that may still reach the owner slot.
    func beginInFlightWrite(
        ownerID: String,
        revision: UInt64,
        for fileURL: URL,
        workspaceRoot: URL?
    ) throws -> FilePreviewRecoveryWriteRegistration {
        let paths = try canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot)
        let slotKey = recoverySlotKey(for: recordURL(
            filePath: paths.file,
            workspacePath: paths.workspace,
            ownerID: ownerID
        ))
        let registration = FilePreviewRecoveryWriteRegistration(
            slotKey: slotKey,
            identifier: UUID(),
            revision: revision
        )
        withMutationLock {
            Self.inFlightWrites[slotKey, default: [:]][registration.identifier] = revision
        }
        return registration
    }

    /// Marks a registered writer complete and opportunistically retires the
    /// exact fence it was keeping alive. This normally runs on the detached
    /// writer's executor, so deletion/fsync work never expands the MainActor
    /// cleanup barrier.
    func completeInFlightWrite(_ registration: FilePreviewRecoveryWriteRegistration) {
        withMutationLock {
            Self.inFlightWrites[registration.slotKey]?[registration.identifier] = nil
            if Self.inFlightWrites[registration.slotKey]?.isEmpty == true {
                Self.inFlightWrites[registration.slotKey] = nil
            }
            attemptPendingFenceRetirementPrepared(slotKey: registration.slotKey)
        }
    }

    /// Requests physical retirement of an exact fence. The request remains
    /// pending while any registered writer at or below the fenced revision is
    /// running. Source records are durably unlinked before the tombstone is
    /// unlinked, preserving crash recovery at every point in the sequence.
    func retireFenceWhenSafe(
        _ token: FilePreviewRecoveryToken,
        through revision: UInt64,
        for fileURL: URL,
        workspaceRoot: URL?
    ) {
        guard let paths = try? canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot) else { return }
        let slotKey = recoverySlotKey(for: recordURL(
            filePath: paths.file,
            workspacePath: paths.workspace,
            ownerID: token.ownerID
        ))
        let retirement = FenceRetirement(
            token: token,
            throughRevision: revision
        )
        withMutationLock {
            Self.pendingFenceRetirements[slotKey] = retirement
            attemptPendingFenceRetirementPrepared(slotKey: slotKey)
        }
    }

    func releaseClaims(
        _ tokens: [FilePreviewRecoveryToken],
        for fileURL: URL,
        workspaceRoot: URL?,
        claimantID: String
    ) {
        guard let paths = try? canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot) else { return }
        withMutationLock {
            for token in tokens {
                let key = claimKey(paths: paths, token: token)
                if Self.claimedRecords[key] == claimantID { Self.claimedRecords[key] = nil }
            }
        }
    }

    /// Removes only the exact record a caller observed or wrote. A newer
    /// revision from the same editor, and every record from another window,
    /// remain untouched.
    @discardableResult
    func remove(
        _ token: FilePreviewRecoveryToken,
        for fileURL: URL,
        workspaceRoot: URL?
    ) -> Bool {
        guard let paths = try? canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot) else { return false }
        return withMutationLock {
            do { try prepareDirectory() } catch { return false }
            let url = recordURL(
                filePath: paths.file,
                workspacePath: paths.workspace,
                ownerID: token.ownerID
            )
            guard let record = readRecord(at: url),
                  record.filePath == paths.file,
                  record.workspacePath == paths.workspace,
                  record.token == token else { return false }
            do {
                try FileManager.default.removeItem(at: url)
                synchronizeDirectory()
                return true
            } catch {
                return false
            }
        }
    }

    private func write(
        _ record: FilePreviewRecoveryRecord,
        pruneAfterWrite: Bool = true
    ) throws {
        try withMutationLock {
            try prepareDirectory()
            try writePrepared(record, pruneAfterWrite: pruneAfterWrite)
        }
    }

    private func writePrepared(
        _ record: FilePreviewRecoveryRecord,
        pruneAfterWrite: Bool = true
    ) throws {
        let encoded = try JSONEncoder().encode(record)
        guard encoded.count <= Self.maxEncodedRecordBytes else {
            throw RecoveryError.payloadTooLarge
        }
        let destination = recordURL(
            filePath: record.filePath,
            workspacePath: record.workspacePath,
            ownerID: record.ownerID
        )
        if let existing = readRecord(at: destination) {
            guard existing.revision <= record.revision else {
                throw RecoveryError.staleRevision
            }
            if existing.revision == record.revision {
                guard existing.payloadDigest == record.payloadDigest else {
                    throw RecoveryError.staleRevision
                }
                return
            }
        }
        let temporary = directoryURL.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try encoded.write(to: temporary, options: .withoutOverwriting)
        guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else {
            throw RecoveryError.storageUnavailable
        }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else {
            throw RecoveryError.storageUnavailable
        }
        synchronizeDirectory()
        if pruneAfterWrite { prune(protecting: destination) }
    }

    private func withMutationLock<T>(_ operation: () throws -> T) rethrows -> T {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        return try operation()
    }

    private func prepareDirectory() throws {
        if directoryURL.deletingLastPathComponent().standardizedFileURL
            == NativePreviewPaths.applicationSupportDirectory.standardizedFileURL {
            try NativePreviewPaths.prepareApplicationSupport()
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard lstat(directoryURL.path, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR,
              chmod(directoryURL.path, S_IRWXU) == 0 else {
            throw RecoveryError.storageUnavailable
        }
        cleanupOrphanedTemporaryFiles()
    }

    private func secureRegularFile(at url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG else { return false }
        return chmod(url.path, S_IRUSR | S_IWUSR) == 0
    }

    private func validPayload(_ record: FilePreviewRecoveryRecord) -> Bool {
        guard record.version == 1,
              !record.ownerID.isEmpty,
              record.ownerID.utf8.count <= 128 else { return false }
        let sourceTokens = record.sourceTokens ?? []
        guard sourceTokens.count <= Self.maxEntries,
              Set(sourceTokens).count == sourceTokens.count,
              sourceTokens.allSatisfy({
                  !$0.ownerID.isEmpty
                      && $0.ownerID.utf8.count <= 128
                      && !$0.payloadDigest.isEmpty
                      && $0.payloadDigest.utf8.count <= 128
              }) else { return false }
        switch record.kind {
        case .text:
            guard let text = record.text,
                  record.richDocumentData == nil,
                  record.fenceProcessID == nil else { return false }
            let data = Data(text.utf8)
            return data.count <= FilePreviewContent.maxTextBytes
                && record.payloadDigest == payloadDigest(kind: .text, data: data)
        case .richDocument:
            guard record.text == nil,
                  let data = record.richDocumentData,
                  record.fenceProcessID == nil else { return false }
            return data.count <= FilePreviewContent.maxDocumentBytes
                && record.payloadDigest == payloadDigest(kind: .richDocument, data: data)
        case .tombstone:
            guard record.text == nil,
                  record.richDocumentData == nil,
                  let fenceProcessID = record.fenceProcessID,
                  !fenceProcessID.isEmpty,
                  fenceProcessID.utf8.count <= 128 else { return false }
            return record.payloadDigest == tombstoneDigest(sourceTokens: sourceTokens)
        }
    }

    private func readRecord(at url: URL) -> FilePreviewRecoveryRecord? {
        guard secureRegularFile(at: url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard byteCount > 0, byteCount <= Self.maxEncodedRecordBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= Self.maxEncodedRecordBytes,
              let record = try? JSONDecoder().decode(FilePreviewRecoveryRecord.self, from: data),
              validPayload(record) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return record
    }

    private func recoveryRecordURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }) ?? []
    }

    private func canonicalPaths(fileURL: URL, workspaceRoot: URL?) throws -> (file: String, workspace: String) {
        guard let workspaceRoot else { throw RecoveryError.outsideWorkspace }
        let workspace = resolvedURLIncludingExistingAncestors(workspaceRoot).path
        let file = resolvedURLIncludingExistingAncestors(fileURL).path
        guard file == workspace || file.hasPrefix(workspace + "/") else {
            throw RecoveryError.outsideWorkspace
        }
        return (file, workspace)
    }

    private func resolvedURLIncludingExistingAncestors(_ url: URL) -> URL {
        let manager = FileManager.default
        var existing = url.standardizedFileURL
        var suffix: [String] = []
        while !manager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            suffix.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in suffix { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }

    private func recordURL(filePath: String, workspacePath: String, ownerID: String) -> URL {
        let material = Data("\(workspacePath)\n\(filePath)\n\(ownerID)".utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(digest).appendingPathExtension("json")
    }

    /// Directory enumeration may return `/private/var/...` even when the same
    /// store was initialized through `/var/...`. Registry keys must use one
    /// canonical spelling or pruning can overlook a writer that still owns an
    /// active fence.
    private func recoverySlotKey(for url: URL) -> String {
        resolvedURLIncludingExistingAncestors(url).path
    }

    private func claimKey(
        paths: (file: String, workspace: String),
        token: FilePreviewRecoveryToken
    ) -> String {
        "\(directoryURL.path)\n\(paths.workspace)\n\(paths.file)\n\(token.ownerID)\n\(token.revision)\n\(token.payloadDigest)"
    }

    private func payloadDigest(kind: FilePreviewRecoveryRecord.Kind, data: Data) -> String {
        var material = Data(kind.rawValue.utf8)
        material.append(0)
        material.append(data)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    private func tombstoneDigest(sourceTokens: [FilePreviewRecoveryToken]) -> String {
        // JSONEncoder's default dictionary-key order is intentionally
        // unspecified. Stable output is required because validation recomputes
        // this digest in a later read (and often in a later process).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = (try? encoder.encode(sourceTokens)) ?? Data()
        return payloadDigest(kind: .tombstone, data: encoded)
    }

    private func cleanupOrphanedTemporaryFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        var removed = false
        for url in files where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "tmp" {
            guard secureRegularFile(at: url) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed = true }
        }
        if removed { synchronizeDirectory() }
    }

    private func hasInFlightWrite(slotKey: String, through revision: UInt64) -> Bool {
        Self.inFlightWrites[slotKey]?.values.contains(where: { $0 <= revision }) == true
    }

    private func attemptPendingFenceRetirementPrepared(slotKey: String) {
        guard let retirement = Self.pendingFenceRetirements[slotKey],
              !hasInFlightWrite(slotKey: slotKey, through: retirement.throughRevision) else { return }
        let tombstoneURL = URL(fileURLWithPath: slotKey)
        guard let record = readRecord(at: tombstoneURL),
              record.kind == .tombstone,
              record.token == retirement.token else {
            // A newer legitimate journal or fence already superseded this
            // exact tombstone, so this retirement can no longer unlink it.
            Self.pendingFenceRetirements[slotKey] = nil
            return
        }
        if retireTombstonePrepared(record, at: tombstoneURL) {
            Self.pendingFenceRetirements[slotKey] = nil
        }
    }

    /// Removes source records and the tombstone in two separately durable
    /// phases. A crash before the first fsync leaves the tombstone available;
    /// a crash after it leaves no source for the tombstone to suppress.
    private func retireTombstonePrepared(
        _ tombstone: FilePreviewRecoveryRecord,
        at tombstoneURL: URL
    ) -> Bool {
        retireLineageRecordPrepared(
            tombstone,
            at: tombstoneURL,
            removedRecordEvent: .removedTombstone,
            synchronizedRecordDeletionEvent: .synchronizedTombstoneDeletion
        )
    }

    /// Durably retires a record and every exact predecessor it suppresses.
    /// Sources are unlinked and fsynced first; only then may the descendant be
    /// unlinked and fsynced. Thus no crash point can leave a stale source on
    /// disk without the durable descendant that suppresses it.
    private func retireLineageRecordPrepared(
        _ record: FilePreviewRecoveryRecord,
        at descendantURL: URL,
        removedRecordEvent: DurabilityEvent,
        synchronizedRecordDeletionEvent: DurabilityEvent
    ) -> Bool {
        var removedSource = false
        for token in record.sourceTokens ?? [] {
            let sourceURL = recordURL(
                filePath: record.filePath,
                workspacePath: record.workspacePath,
                ownerID: token.ownerID
            )
            guard let source = readRecord(at: sourceURL), source.token == token else { continue }
            do {
                try FileManager.default.removeItem(at: sourceURL)
                removedSource = true
                durabilityObserver?(.removedSource)
            } catch {
                return false
            }
        }
        if removedSource,
           !synchronizeDirectory(event: .synchronizedSourceDeletions) {
            return false
        }
        guard let current = readRecord(at: descendantURL), current.token == record.token else {
            return true
        }
        do {
            try FileManager.default.removeItem(at: descendantURL)
            durabilityObserver?(removedRecordEvent)
        } catch {
            return false
        }
        return synchronizeDirectory(event: synchronizedRecordDeletionEvent)
    }

    private func prune(protecting current: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard var records = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter({ $0.pathExtension == "json" }) else { return }
        records.sort { lhs, rhs in
            if lhs == current { return true }
            if rhs == current { return false }
            let left = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return left > right
        }
        let decodedRecords = Dictionary(uniqueKeysWithValues: records.compactMap { url in
            readRecord(at: url).map { (url, $0) }
        })
        let activeFenceSourceTokens = Set(decodedRecords.compactMap { url, record -> [FilePreviewRecoveryToken]? in
            guard record.kind == .tombstone,
                  record.fenceProcessID == processID else { return nil }
            let throughRevision = record.revision == 0 ? 0 : record.revision - 1
            return hasInFlightWrite(
                slotKey: recoverySlotKey(for: url),
                through: throughRevision
            )
                ? (record.sourceTokens ?? [])
                : nil
        }.flatMap { $0 })
        var count = 0
        var bytes = 0
        var removedAny = false
        for url in records {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                if (try? FileManager.default.removeItem(at: url)) != nil { removedAny = true }
                continue
            }
            let size = values.fileSize ?? 0
            let decodedRecord = decodedRecords[url]
            if let decodedRecord,
               activeFenceSourceTokens.contains(decodedRecord.token) {
                // This exact predecessor is part of the active fence's safety
                // unit. It remains on disk until two-phase retirement, but it
                // must not consume capacity and evict an unrelated live draft.
                continue
            }
            if let decodedRecord, decodedRecord.kind == .tombstone {
                let throughRevision = decodedRecord.revision == 0 ? 0 : decodedRecord.revision - 1
                let slotKey = recoverySlotKey(for: url)
                let isActiveFence = decodedRecord.fenceProcessID == processID
                    && hasInFlightWrite(slotKey: slotKey, through: throughRevision)
                if isActiveFence {
                    // Active fences are transient safety barriers, not journal
                    // entries. Excluding them from logical caps prevents them
                    // from evicting another live window's recoverable draft.
                    continue
                }
                if retireTombstonePrepared(decodedRecord, at: url) {
                    Self.pendingFenceRetirements[slotKey] = nil
                }
                continue
            }
            if count >= Self.maxEntries || bytes + size > Self.maxStoredBytes {
                if let decodedRecord,
                   decodedRecord.sourceTokens?.isEmpty == false {
                    if !retireLineageRecordPrepared(
                        decodedRecord,
                        at: url,
                        removedRecordEvent: .removedLineageDescendant,
                        synchronizedRecordDeletionEvent: .synchronizedLineageDescendantDeletion
                    ) {
                        // Durability beats the storage cap. Keep the suppressor
                        // counted if either phase cannot be completed safely.
                        count += 1
                        bytes += size
                    }
                } else if (try? FileManager.default.removeItem(at: url)) != nil {
                    removedAny = true
                }
            } else {
                count += 1
                bytes += size
            }
        }
        if removedAny { synchronizeDirectory() }
    }

    @discardableResult
    private func synchronizeDirectory(event: DurabilityEvent? = nil) -> Bool {
        let descriptor = open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        let result = fsync(descriptor)
        _ = close(descriptor)
        guard result == 0 else { return false }
        if let event { durabilityObserver?(event) }
        return true
    }

    enum RecoveryError: LocalizedError, Equatable, Sendable {
        case outsideWorkspace
        case payloadTooLarge
        case storageUnavailable
        case staleRevision

        var errorDescription: String? {
            switch self {
            case .outsideWorkspace:
                "Recovery drafts are only stored for files inside the open project."
            case .payloadTooLarge:
                "The draft is too large for bounded recovery storage."
            case .storageUnavailable:
                "Kaisola could not securely store the recovery draft."
            case .staleRevision:
                "A newer recovery revision is already stored for this editor."
            }
        }
    }
}

enum FilePreviewDraftBounds {
    static func acceptsText(_ text: String) -> Bool {
        text.utf8.count <= FilePreviewContent.maxTextBytes
    }

    /// Rich text is additionally checked against its exact serialized DOCX
    /// size whenever it is journaled. This cheap input-boundary guard prevents
    /// a giant paste from making even the coalesced validation pathological.
    static func acceptsRichText(_ value: NSAttributedString) -> Bool {
        value.string.utf8.count <= FilePreviewContent.maxTextBytes
    }

    static func acceptsSerializedRichDocumentData(
        _ data: Data,
        maximumBytes: Int = FilePreviewContent.maxDocumentBytes
    ) -> Bool {
        data.count <= maximumBytes
    }
}

private struct FilePreviewSnapshot: Sendable {
    let content: FilePreviewContent
    let modificationDate: Date?
    let recoveryClaim: FilePreviewRecoveryClaim?
}

private enum FilePreviewRecoveryWorkResult: Sendable {
    case saved(FilePreviewRecoveryToken)
    case failed(message: String, payloadTooLarge: Bool)
}

private enum FilePreviewRecoveryWork {
    nonisolated static func persist(
        store: FilePreviewRecoveryStore,
        target: URL,
        workspaceRoot: URL?,
        expectedModificationDate: Date?,
        ownerID: String,
        revision: UInt64,
        sourceTokens: [FilePreviewRecoveryToken],
        text: String,
        richPayload: RichDocumentPayload?
    ) -> FilePreviewRecoveryWorkResult {
        do {
            let token: FilePreviewRecoveryToken
            if let richPayload {
                let data = try RichDocumentIO.data(richPayload.value)
                guard FilePreviewDraftBounds.acceptsSerializedRichDocumentData(data) else {
                    throw FilePreviewRecoveryStore.RecoveryError.payloadTooLarge
                }
                token = try store.saveRichDocument(
                    data,
                    for: target,
                    workspaceRoot: workspaceRoot,
                    expectedModificationDate: expectedModificationDate,
                    ownerID: ownerID,
                    revision: revision,
                    sourceTokens: sourceTokens
                )
            } else {
                token = try store.saveText(
                    text,
                    for: target,
                    workspaceRoot: workspaceRoot,
                    expectedModificationDate: expectedModificationDate,
                    ownerID: ownerID,
                    revision: revision,
                    sourceTokens: sourceTokens
                )
            }
            return .saved(token)
        } catch {
            let oversized = (error as? FilePreviewRecoveryStore.RecoveryError) == .payloadTooLarge
            return .failed(message: error.localizedDescription, payloadTooLarge: oversized)
        }
    }
}

private enum FilePreviewSaveResult: Sendable {
    case saved(Date?)
    case changedOnDisk
    case failed(String)
}

/// Disk reads/writes used by the preview are deliberately actor-independent so
/// they can run on a utility executor. The modification-date guard prevents an
/// agent edit that lands after the preview opened from being silently replaced.
enum FilePreviewDiskState {
    nonisolated static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    nonisolated static func changed(onDisk url: URL, since expected: Date?) -> Bool {
        modificationDate(of: url) != expected
    }

    fileprivate nonisolated static func writeText(
        _ text: String,
        to url: URL,
        expectedModificationDate: Date?,
        force: Bool
    ) -> FilePreviewSaveResult {
        guard force || !changed(onDisk: url, since: expectedModificationDate) else {
            return .changedOnDisk
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return .saved(modificationDate(of: url))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// A paste/drop payload already reduced to Sendable filesystem bytes. AppKit
/// objects never cross the actor boundary: clipboard images become PNG data on
/// the main actor, while file drops carry only their URL.
enum MarkdownImageImport: Sendable {
    case file(URL)
    case data(Data, suggestedName: String, fileExtension: String)
}

struct MarkdownAssetInsertion: Equatable, Sendable {
    let fileURL: URL
    let markdown: String
}

struct MarkdownAssetImportBatch: Sendable {
    let insertions: [MarkdownAssetInsertion]
    let errors: [String]
}

/// Places one or more portable image links at a source selection without
/// joining them to adjacent prose. Shared by the whole-file source editor and
/// the exact block-local editor so paste/drop behavior does not depend on the
/// current Markdown editing mode.
enum MarkdownImageInsertion {
    static func text(snippets: [String], source: String, range: NSRange) -> String {
        let nsSource = source as NSString
        let safeLocation = min(max(0, range.location), nsSource.length)
        let safeLength = min(max(0, range.length), nsSource.length - safeLocation)
        let safeRange = NSRange(location: safeLocation, length: safeLength)
        var insertion = snippets.joined(separator: "\n")
        if safeRange.location > 0,
           nsSource.substring(with: NSRange(location: safeRange.location - 1, length: 1)) != "\n" {
            insertion = "\n" + insertion
        }
        let end = NSMaxRange(safeRange)
        if end < nsSource.length,
           nsSource.substring(with: NSRange(location: end, length: 1)) != "\n" {
            insertion += "\n"
        }
        return insertion
    }
}

/// Copies pasted/dropped images into a portable folder beside the Markdown
/// document: `assets/<document-name>/image.png`. Keeping assets relative to the
/// document makes the inserted links work in GitHub, static-site generators,
/// and the Electron app without an app-specific URL scheme.
enum MarkdownAssetStore {
    static let maxImageBytes = 25 * 1_048_576
    private static let rasterExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff",
    ]

    nonisolated static func importImages(
        _ imports: [MarkdownImageImport],
        markdownURL: URL,
        workspaceRoot: URL?
    ) -> MarkdownAssetImportBatch {
        var insertions: [MarkdownAssetInsertion] = []
        var errors: [String] = []
        for item in imports.prefix(20) {
            do {
                insertions.append(try importImage(
                    item,
                    markdownURL: markdownURL,
                    workspaceRoot: workspaceRoot
                ))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if imports.count > 20 {
            errors.append("Paste or drop at most 20 images at a time.")
        }
        return MarkdownAssetImportBatch(insertions: insertions, errors: errors)
    }

    private nonisolated static func importImage(
        _ item: MarkdownImageImport,
        markdownURL: URL,
        workspaceRoot: URL?
    ) throws -> MarkdownAssetInsertion {
        let document = markdownURL.standardizedFileURL
        let documentDirectory = document.deletingLastPathComponent()
        if let workspaceRoot {
            guard isContained(document, in: workspaceRoot) else {
                throw MarkdownAssetError.documentOutsideWorkspace
            }
        }

        let documentName = sanitizedName(
            document.deletingPathExtension().lastPathComponent,
            fallback: "document"
        )
        let assetDirectory = documentDirectory
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(documentName, isDirectory: true)
        // An existing `assets` symlink must not turn an innocent paste into a
        // write outside the open project.
        if let workspaceRoot {
            guard isContained(assetDirectory, in: workspaceRoot) else {
                throw MarkdownAssetError.assetDirectoryOutsideWorkspace
            }
        }
        try FileManager.default.createDirectory(
            at: assetDirectory,
            withIntermediateDirectories: true
        )

        let data: Data
        let sourceName: String
        let fileExtension: String
        switch item {
        case let .file(source):
            let ext = source.pathExtension.lowercased()
            guard rasterExtensions.contains(ext) else {
                throw MarkdownAssetError.unsupportedImage(source.lastPathComponent)
            }
            let byteCount = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard byteCount <= maxImageBytes else {
                throw MarkdownAssetError.imageTooLarge(source.lastPathComponent)
            }
            data = try Data(contentsOf: source, options: .mappedIfSafe)
            guard data.count <= maxImageBytes else {
                throw MarkdownAssetError.imageTooLarge(source.lastPathComponent)
            }
            sourceName = source.deletingPathExtension().lastPathComponent
            fileExtension = ext
        case let .data(bytes, suggestedName, ext):
            guard bytes.count <= maxImageBytes else {
                throw MarkdownAssetError.imageTooLarge(suggestedName)
            }
            let normalizedExtension = ext.lowercased()
            guard rasterExtensions.contains(normalizedExtension) else {
                throw MarkdownAssetError.unsupportedImage(suggestedName)
            }
            data = bytes
            sourceName = suggestedName
            fileExtension = normalizedExtension
        }

        guard !data.isEmpty else { throw MarkdownAssetError.emptyImage(sourceName) }
        let baseName = sanitizedName(sourceName, fallback: "image")
        let destination = uniqueDestination(
            directory: assetDirectory,
            baseName: baseName,
            fileExtension: fileExtension
        )
        // `Data` deliberately forbids combining `.atomic` with
        // `.withoutOverwriting`; exclusive creation is the important property
        // here because a paste must never replace an existing project asset.
        try data.write(to: destination, options: .withoutOverwriting)

        let relativePath = "assets/\(documentName)/\(destination.lastPathComponent)"
        let alt = baseName.replacingOccurrences(of: "]", with: "\\]")
        return MarkdownAssetInsertion(
            fileURL: destination,
            markdown: "![\(alt)](\(relativePath))"
        )
    }

    private nonisolated static func uniqueDestination(
        directory: URL,
        baseName: String,
        fileExtension: String
    ) -> URL {
        let manager = FileManager.default
        for suffix in 0..<10_000 {
            let name = suffix == 0 ? baseName : "\(baseName)-\(suffix + 1)"
            let candidate = directory
                .appendingPathComponent(name, isDirectory: false)
                .appendingPathExtension(fileExtension)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory
            .appendingPathComponent("\(baseName)-\(UUID().uuidString.lowercased())")
            .appendingPathExtension(fileExtension)
    }

    private nonisolated static func sanitizedName(_ raw: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String((collapsed.isEmpty ? fallback : collapsed).prefix(64))
    }

    private nonisolated static func isContained(_ url: URL, in directory: URL) -> Bool {
        let base = resolvedURLIncludingExistingAncestors(directory).path
        let candidate = resolvedURLIncludingExistingAncestors(url).path
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    /// `resolvingSymlinksInPath()` does not reliably resolve an existing
    /// symlink when a later path component has not been created yet. Resolve
    /// the closest existing ancestor first, then restore the missing suffix.
    private nonisolated static func resolvedURLIncludingExistingAncestors(_ url: URL) -> URL {
        let manager = FileManager.default
        var existing = url.standardizedFileURL
        var missingComponents: [String] = []
        while !manager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    private enum MarkdownAssetError: LocalizedError {
        case documentOutsideWorkspace
        case assetDirectoryOutsideWorkspace
        case unsupportedImage(String)
        case imageTooLarge(String)
        case emptyImage(String)

        var errorDescription: String? {
            switch self {
            case .documentOutsideWorkspace:
                "Images can only be added to Markdown files inside the open project."
            case .assetDirectoryOutsideWorkspace:
                "The Markdown asset folder resolves outside the open project."
            case let .unsupportedImage(name):
                "\(name) is not a supported raster image."
            case let .imageTooLarge(name):
                "\(name) is larger than \(maxImageBytes / 1_048_576) MB."
            case let .emptyImage(name):
                "\(name) contains no image data."
            }
        }
    }
}

/// NSAttributedString's DOCX importer/exporter is synchronous. A dedicated
/// actor serializes rich-document work off the MainActor, so rapid file switches
/// cannot pile up AppKit parses or freeze terminal rendering.
private actor RichDocumentWorker {
    static let shared = RichDocumentWorker()

    func load(url: URL) -> RichDocumentPayload? {
        RichDocumentIO.load(url: url)
    }

    func load(data: Data) -> RichDocumentPayload? {
        RichDocumentIO.load(data: data)
    }

    func write(
        _ payload: RichDocumentPayload,
        to url: URL,
        expectedModificationDate: Date?,
        force: Bool
    ) -> FilePreviewSaveResult {
        guard force || !FilePreviewDiskState.changed(onDisk: url, since: expectedModificationDate) else {
            return .changedOnDisk
        }
        do {
            try RichDocumentIO.write(payload.value, to: url)
            return .saved(FilePreviewDiskState.modificationDate(of: url))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

private struct RichDocumentCommand: Equatable {
    enum Kind: Equatable { case bold, italic, underline, heading, bulletList }
    let id = UUID()
    let kind: Kind
}

/// Preview tabs are disposable only while they are clean. Both VS Code and
/// JetBrains promote a preview as soon as editing begins; keeping this policy
/// pure makes the loss-prevention boundary independently testable.
enum FilePreviewTabPolicy {
    static func shouldPromoteEditedPreview(
        loadedURL: URL?,
        isDirty: Bool,
        tabs: [AppModel.FileWorkbenchTab]
    ) -> Bool {
        guard isDirty, let loadedURL else { return false }
        return tabs.contains {
            $0.url.standardizedFileURL == loadedURL.standardizedFileURL && !$0.isPinned
        }
    }

    static func isModified(
        _ tab: AppModel.FileWorkbenchTab,
        loadedURL: URL?,
        isDirty: Bool
    ) -> Bool {
        isDirty && tab.url.standardizedFileURL == loadedURL?.standardizedFileURL
    }

    /// Duplicate leaf names are common in source trees. Keep ordinary tabs
    /// compact, but append the workspace-relative parent whenever a filename
    /// alone would be ambiguous (for example `README.md — docs`).
    static func displayTitle(
        for tab: AppModel.FileWorkbenchTab,
        among tabs: [AppModel.FileWorkbenchTab],
        workspaceRoot: URL?
    ) -> String {
        let url = tab.url.standardizedFileURL
        let filename = url.lastPathComponent
        let duplicateCount = tabs.reduce(into: 0) { count, candidate in
            if candidate.url.lastPathComponent == filename { count += 1 }
        }
        guard duplicateCount > 1 else { return filename }

        let parent = url.deletingLastPathComponent().standardizedFileURL
        if let root = workspaceRoot?.standardizedFileURL {
            if parent == root {
                let rootName = root.lastPathComponent
                return "\(filename) — \(rootName.isEmpty ? "workspace" : rootName)"
            }
            let rootPath = root.path
            let parentPath = parent.path
            if parentPath.hasPrefix(rootPath + "/") {
                let relativeParent = String(parentPath.dropFirst(rootPath.count + 1))
                if !relativeParent.isEmpty { return "\(filename) — \(relativeParent)" }
            }
        }
        let parentName = parent.lastPathComponent
        return "\(filename) — \(parentName.isEmpty ? parent.path : parentName)"
    }
}

/// File preview/editor pane: UTF-8 text is editable with ⌘S save + revert,
/// markdown renders styled (with a raw-source toggle), images display, and
/// binary/oversized files degrade to a clear notice.
struct FilePreviewView: View {
    let url: URL
    /// Project root grants HTML previews access to their own relative assets
    /// (styles, scripts, images) without granting the rest of the filesystem.
    let workspaceRoot: URL?
    /// One-based line target from terminal/chat file links and restored tabs.
    let targetLine: Int?
    let tabs: [AppModel.FileWorkbenchTab]
    let selectTab: (URL) -> Void
    let setTabPinned: (URL, Bool) -> Void
    let closeTab: (URL) -> Void
    let canReopenClosedTab: Bool
    let reopenClosedTab: () -> Void
    let commandScopeID: ObjectIdentifier?
    let navigationCommitted: (URL) -> Void
    /// Restores AppModel's selection when a pending file switch is cancelled.
    let restoreSelection: (URL) -> Void
    let close: () -> Void
    private let recoveryStore: FilePreviewRecoveryStore

    init(
        url: URL,
        workspaceRoot: URL?,
        targetLine: Int? = nil,
        tabs: [AppModel.FileWorkbenchTab] = [],
        selectTab: @escaping (URL) -> Void = { _ in },
        setTabPinned: @escaping (URL, Bool) -> Void = { _, _ in },
        closeTab: @escaping (URL) -> Void = { _ in },
        canReopenClosedTab: Bool = false,
        reopenClosedTab: @escaping () -> Void = {},
        commandScopeID: ObjectIdentifier? = nil,
        navigationCommitted: @escaping (URL) -> Void = { _ in },
        restoreSelection: @escaping (URL) -> Void,
        close: @escaping () -> Void,
        recoveryStore: FilePreviewRecoveryStore = FilePreviewRecoveryStore()
    ) {
        self.url = url
        self.workspaceRoot = workspaceRoot
        self.targetLine = targetLine
        self.tabs = tabs
        self.selectTab = selectTab
        self.setTabPinned = setTabPinned
        self.closeTab = closeTab
        self.canReopenClosedTab = canReopenClosedTab
        self.reopenClosedTab = reopenClosedTab
        self.commandScopeID = commandScopeID
        self.navigationCommitted = navigationCommitted
        self.restoreSelection = restoreSelection
        self.close = close
        self.recoveryStore = recoveryStore
    }

    @Environment(\.colorScheme) private var colorScheme

    @State private var content: FilePreviewContent = .unreadable
    @State private var draft = ""
    @State private var savedText = ""
    @State private var richDraft = NSAttributedString(string: "")
    @State private var savedRichText = NSAttributedString(string: "")
    @State private var showMarkdownSource = false
    /// Text (non-markdown) files default to a read-only, syntax-highlighted
    /// view; this toggle drops into the plain `TextEditor` for editing.
    @State private var isEditingText = false
    /// Cached highlighted rendering of `draft`, recomputed only when the source,
    /// language, or appearance changes (never on every keystroke).
    @State private var highlighted = AttributedString("")
    @State private var saveError: String?
    /// The URL that produced the currently rendered draft. It deliberately
    /// stays unchanged while another URL loads, so Save can never target the
    /// incoming file with the outgoing file's contents.
    @State private var loadedURL: URL?
    @State private var loadingURL: URL?
    @State private var loadedModificationDate: Date?
    /// A navigation/close blocked on unsaved changes, awaiting the user.
    @State private var pendingAction: PendingAction?
    @State private var showUnsavedPrompt = false
    @State private var showExternalChangePrompt = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var markdownAutosaveTask: Task<Void, Never>?
    @State private var highlightTask: Task<Void, Never>?
    @State private var recoveryJournalTask: Task<Void, Never>?
    @State private var documentZoom: CGFloat = 1
    @State private var previewRevision = 0
    @State private var richDocumentCommand: RichDocumentCommand?
    /// A recovered draft may equal an empty fallback baseline when the disk
    /// file is temporarily unreadable. Keep it dirty until an explicit save or
    /// discard even in that edge case.
    @State private var recoveredDraftPending = false
    @State private var recoveryOwnerID = UUID().uuidString.lowercased()
    @State private var recoveryRevision: UInt64 = 0
    @State private var recoveryFencedRevision: UInt64 = 0
    @State private var recoveryFencedSourceTokens: [FilePreviewRecoveryToken] = []
    @State private var recoveryFenceToken: FilePreviewRecoveryToken?
    @State private var recoveryGeneration: UInt64 = 0
    @State private var pendingEditedPreviewPromotion: URL?
    @State private var hoveredTabURL: URL?
    @State private var ownedRecoveryToken: FilePreviewRecoveryToken?
    @State private var claimedRecoverySourceTokens: [FilePreviewRecoveryToken] = []
    @State private var lastRecoverableRichDraft = NSAttributedString(string: "")

    private enum PendingAction: Equatable {
        case navigate(URL)
        case close
    }

    private var isDirty: Bool {
        if recoveredDraftPending { return true }
        if case .docx = content { return !richDraft.isEqual(to: savedRichText) }
        return draft != savedText
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                body(for: content)
                    .allowsHitTesting(!isLoading && !isSaving)
                if isLoading {
                    ZStack {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Opening \((loadingURL ?? url).lastPathComponent)…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
        }
        .onAppear {
            FilePreviewRecoveryOwnerRegistry.shared.register(recoveryOwnerID)
            beginLoad(url)
        }
        .onChange(of: url) { _, newURL in
            guard newURL != loadedURL, newURL != loadingURL else { return }
            // Never silently drop unsaved edits: block the switch behind a
            // Save / Discard / Cancel prompt.
            if isDirty {
                pendingAction = .navigate(newURL)
                showUnsavedPrompt = true
            } else {
                beginLoad(newURL)
            }
        }
        .onChange(of: targetLine) { _, newLine in
            guard newLine != nil else { return }
            if case .text = content { isEditingText = true }
            if case .html = content { isEditingText = true }
            if case .markdown = content { showMarkdownSource = false }
        }
        // Re-highlight when appearance flips or when returning to read mode with
        // edited (or reverted/discarded) text. Skipped while editing so typing
        // never pays the highlight cost.
        .onChange(of: colorScheme) { _, _ in refreshHighlight() }
        .onChange(of: isEditingText) { _, editing in if !editing { refreshHighlight() } }
        .onChange(of: draft) { oldValue, newValue in
            guard FilePreviewDraftBounds.acceptsText(newValue) else {
                draft = oldValue
                reportOversizedDraft()
                return
            }
            if !isEditingText { refreshHighlight() }
            if draft == savedText, !recoveredDraftPending, let loadedURL {
                clearRecoveryTokens(for: loadedURL)
            }
            scheduleRecoveryJournal()
            scheduleMarkdownAutosave()
            promoteEditedPreviewIfNeeded()
        }
        .onChange(of: richDraft) { oldValue, newValue in
            guard FilePreviewDraftBounds.acceptsRichText(newValue) else {
                richDraft = oldValue
                reportOversizedDraft()
                return
            }
            scheduleRecoveryJournal()
            promoteEditedPreviewIfNeeded()
        }
        .onChange(of: recoveredDraftPending) { _, _ in promoteEditedPreviewIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaFlushFilePreviews)) { _ in
            flushPendingPreviewSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaCloseActiveFileTab)) { notification in
            guard let commandScopeID,
                  let requestOwner = notification.object as AnyObject?,
                  ObjectIdentifier(requestOwner) == commandScopeID else { return }
            requestClose()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaPrepareWorkspaceFileMutation)) { notification in
            guard let request = notification.object as? WorkspaceFileMutationBarrierRequest,
                  let loadedURL,
                  WorkspaceFileOperations.contains(loadedURL, in: request.item) else { return }
            flushPendingPreviewSave()
            if isDirty || isSaving || showExternalChangePrompt {
                request.block()
            }
        }
        .onDisappear {
            flushPendingPreviewSave()
            loadTask?.cancel()
            markdownAutosaveTask?.cancel()
            highlightTask?.cancel()
            recoveryJournalTask?.cancel()
            releaseRecoveryClaims()
            FilePreviewRecoveryOwnerRegistry.shared.unregister(recoveryOwnerID)
        }
        .confirmationDialog(
            "Unsaved changes",
            isPresented: $showUnsavedPrompt
        ) {
            Button("Save") {
                save(advancePendingAction: true)
            }
            Button("Discard Changes", role: .destructive) {
                if let loadedURL, !clearRecoveryTokens(for: loadedURL) { return }
                draft = savedText
                richDraft = savedRichText
                recoveredDraftPending = false
                completePendingAction()
            }
            Button("Cancel", role: .cancel) {
                pendingAction = nil
                if let loadedURL { restoreSelection(loadedURL) }
            }
        } message: {
            Text("\(loadedURL?.lastPathComponent ?? "This file") has unsaved changes.")
        }
        .confirmationDialog("File changed on disk", isPresented: $showExternalChangePrompt) {
            Button("Reload from Disk") {
                pendingAction = nil
                if let loadedURL {
                    guard clearRecoveryTokens(for: loadedURL) else { return }
                    beginLoad(loadedURL)
                }
            }
            Button("Overwrite", role: .destructive) {
                save(force: true, advancePendingAction: pendingAction != nil)
            }
            Button("Cancel", role: .cancel) {
                if let loadedURL { restoreSelection(loadedURL) }
                pendingAction = nil
            }
        } message: {
            Text("An agent or another app edited this file after it was opened. Reload it or explicitly overwrite the newer version.")
        }
    }

    private func completePendingAction() {
        switch pendingAction {
        case let .navigate(next):
            beginLoad(next)
        case .close:
            close()
        case nil:
            break
        }
        pendingAction = nil
    }

    private func requestClose() {
        if isDirty {
            pendingAction = .close
            showUnsavedPrompt = true
        } else {
            close()
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            documentTabs
            if tabs.isEmpty, isDirty {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .accessibilityLabel("Unsaved changes")
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
            if isLoading || isSaving { ProgressView().controlSize(.mini) }
            if case .markdown = content {
                Button { showMarkdownSource.toggle() } label: {
                    Image(systemName: showMarkdownSource ? "doc.richtext.fill" : "pencil")
                }
                .buttonStyle(.borderless)
                .help(showMarkdownSource ? "Show formatted Markdown" : "Edit Markdown")
            } else if case .text = content {
                editModeButton(help: "Edit text")
            } else if case .html = content {
                editModeButton(help: "Edit HTML source")
            }
            if isEditable {
                Button { save() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || isLoading || isSaving)
                .help("Save")
            }
            previewOptionsMenu
            if tabs.isEmpty {
                Button {
                    requestClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close document")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var documentTabs: some View {
        if tabs.isEmpty {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text((loadingURL ?? loadedURL ?? url).lastPathComponent)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        } else {
            ScrollViewReader { tabScroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            let normalizedURL = tab.url.standardizedFileURL
                            let selected = normalizedURL == url.standardizedFileURL
                            let modified = FilePreviewTabPolicy.isModified(
                                tab,
                                loadedURL: loadedURL,
                                isDirty: isDirty
                            )
                            let displayTitle = FilePreviewTabPolicy.displayTitle(
                                for: tab,
                                among: tabs,
                                workspaceRoot: workspaceRoot
                            )
                            let closeVisible = selected
                                || hoveredTabURL?.standardizedFileURL == normalizedURL
                            HStack(spacing: 0) {
                                Button {
                                    selectTab(tab.url)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: tab.isPinned ? "doc.fill" : "doc")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                                        Text(displayTitle)
                                            .font(.caption.weight(selected ? .semibold : .regular))
                                            .italic(!tab.isPinned)
                                            .lineLimit(1)
                                        if modified {
                                            Circle()
                                                .fill(Color.accentColor)
                                                .frame(width: 6, height: 6)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .padding(.leading, 8)
                                    .padding(.trailing, 3)
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        setTabPinned(tab.url, true)
                                    }
                                )
                                .accessibilityLabel(
                                    "\(displayTitle), \(tab.isPinned ? "kept open" : "preview")"
                                        + "\(modified ? ", modified" : "")"
                                )

                                Button {
                                    if selected { requestClose() }
                                    else { closeTab(tab.url) }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .semibold))
                                        .frame(width: 18, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .opacity(closeVisible ? 1 : 0)
                                .allowsHitTesting(closeVisible)
                                .accessibilityHidden(!closeVisible)
                                .accessibilityLabel("Close \(displayTitle)")
                            }
                            .frame(height: 26)
                            .background(
                                selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                                        lineWidth: 0.7
                                    )
                            }
                            .onHover { hovering in
                                if hovering {
                                    hoveredTabURL = normalizedURL
                                } else if hoveredTabURL?.standardizedFileURL == normalizedURL {
                                    hoveredTabURL = nil
                                }
                            }
                            .contextMenu {
                                Button(tab.isPinned ? "Make Transient" : "Keep Open") {
                                    setTabPinned(tab.url, !tab.isPinned)
                                }
                                .disabled(selected && modified && tab.isPinned)
                                Button("Close") {
                                    if selected { requestClose() }
                                    else { closeTab(tab.url) }
                                }
                                Divider()
                                Button("Reopen Closed Tab") {
                                    reopenClosedTab()
                                }
                                .disabled(!canReopenClosedTab)
                            }
                            .help(tab.isPinned ? tab.url.path : "Preview — double-click to keep open\n\(tab.url.path)")
                            .id(normalizedURL)
                        }
                    }
                }
                .onAppear {
                    tabScroll.scrollTo(url.standardizedFileURL, anchor: .center)
                }
                .onChange(of: url.standardizedFileURL) { _, selectedURL in
                    withAnimation(.easeOut(duration: 0.16)) {
                        tabScroll.scrollTo(selectedURL, anchor: .center)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func editModeButton(help: String) -> some View {
        Button { isEditingText.toggle() } label: {
            Image(systemName: isEditingText ? "eye" : "pencil")
        }
        .buttonStyle(.borderless)
        .help(isEditingText ? "Show preview" : help)
    }

    private var previewOptionsMenu: some View {
        Menu {
            if case .docx = content {
                Section("Format") {
                    Button("Bold") { richDocumentCommand = RichDocumentCommand(kind: .bold) }
                    Button("Italic") { richDocumentCommand = RichDocumentCommand(kind: .italic) }
                    Button("Underline") { richDocumentCommand = RichDocumentCommand(kind: .underline) }
                    Button("Heading") { richDocumentCommand = RichDocumentCommand(kind: .heading) }
                    Button("Bulleted list") { richDocumentCommand = RichDocumentCommand(kind: .bulletList) }
                }
            }
            if supportsZoom {
                Section("Zoom — \(Int((documentZoom * 100).rounded()))%") {
                    Button("Zoom In") { adjustZoom(0.1) }.disabled(documentZoom >= 2)
                    Button("Zoom Out") { adjustZoom(-0.1) }.disabled(documentZoom <= 0.65)
                    Button("Actual Size") { documentZoom = 1 }.disabled(documentZoom == 1)
                }
            }
            if isEditable {
                Divider()
                Button("Revert Changes") {
                    if let loadedURL, !clearRecoveryTokens(for: loadedURL) { return }
                    if case .docx = content { richDraft = savedRichText }
                    else { draft = savedText }
                    recoveredDraftPending = false
                }
                .disabled(!isDirty)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Document options")
    }

    private var supportsZoom: Bool {
        switch content {
        case .text, .markdown, .html, .docx, .image: true
        default: false
        }
    }

    private var isEditable: Bool {
        switch content {
        case .text, .markdown, .html, .docx: true
        default: false
        }
    }

    @ViewBuilder
    private func body(for content: FilePreviewContent) -> some View {
        switch content {
        case .text:
            if isEditingText {
                editor
            } else {
                ScrollView {
                    Text(highlighted)
                        .font(.system(size: 13 * documentZoom, design: .monospaced))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        case .markdown:
            if showMarkdownSource {
                editor
            } else {
                // Keep the structurally rendered document as the default.
                // Hiding Markdown delimiters inside NSTextView left their
                // newline/indent geometry behind, which produced the enormous
                // gaps and clipped lists seen in narrow panes. Editing remains
                // source-faithful: the pencil or a double-click enters the raw
                // Markdown editor, so tables, task lists and relative images
                // are never round-tripped through a lossy rich-text serializer.
                MarkdownDocumentView(
                    source: $draft,
                    documentURL: loadedURL ?? url,
                    workspaceRoot: workspaceRoot,
                    zoom: $documentZoom,
                    onError: { saveError = $0 },
                    automaticallyEditFirstBlock: ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
                        && (ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "preview-edit"
                            || ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "preview-dirty-tab"),
                    automaticallyEditFirstTableCell: ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
                        && ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "preview-table-edit"
                )
            }
        case .image:
            if let image = NSImage(contentsOf: loadedURL ?? url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1200 * documentZoom)
                        .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ContentUnavailableView("Could not load image", systemImage: "photo")
            }
        case let .csv(text):
            CsvPreview(text: text)
        case let .json(text):
            JsonPreview(text: text)
        case let .html(source):
            if isEditingText {
                editor
            } else {
                HtmlFilePreview(
                    fileURL: loadedURL ?? url,
                    readAccessRoot: workspaceRoot,
                    source: source,
                    zoom: documentZoom,
                    contentRevision: previewRevision
                )
            }
        case .docx:
            RichDocumentEditor(text: $richDraft, zoom: documentZoom, command: richDocumentCommand)
                .background(Color(nsColor: .underPageBackgroundColor))
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor))
        case let .tooLarge(size):
            ContentUnavailableView(
                "File too large to preview",
                systemImage: "doc.zipper",
                description: Text("\(size / 1024) KB — bounded previews keep the workspace responsive.")
            )
        case .binary:
            ContentUnavailableView("Binary file", systemImage: "doc", description: Text("No text preview available."))
        case .unreadable:
            ContentUnavailableView("Could not read file", systemImage: "exclamationmark.triangle")
        }
    }

    private var editor: some View {
        LineTargetTextEditor(
            text: $draft,
            fontSize: editableMarkdownURL == nil ? 13 * documentZoom : 13,
            targetLine: targetLine,
            documentID: (loadedURL ?? url).path,
            markdownURL: editableMarkdownURL,
            workspaceRoot: workspaceRoot,
            onError: { saveError = $0 },
            magnification: editableMarkdownURL == nil ? nil : documentZoom,
            onMagnificationChanged: editableMarkdownURL == nil ? nil : { documentZoom = $0 }
        )
    }

    private var editableMarkdownURL: URL? {
        guard case .markdown = content else { return nil }
        return loadedURL ?? url
    }

    private func beginLoad(_ target: URL) {
        loadTask?.cancel()
        markdownAutosaveTask?.cancel()
        highlightTask?.cancel()
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        releaseRecoveryClaims()
        loadingURL = target
        isLoading = true
        saveError = nil
        recoveredDraftPending = false
        ownedRecoveryToken = nil
        claimedRecoverySourceTokens = []
        recoveryRevision = 0
        recoveryFencedRevision = 0
        recoveryFencedSourceTokens = []
        recoveryFenceToken = nil
        pendingEditedPreviewPromotion = nil
        let root = workspaceRoot
        let store = recoveryStore
        let ownerID = recoveryOwnerID
        loadTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                FilePreviewSnapshot(
                    content: FilePreviewContent.load(url: target),
                    modificationDate: FilePreviewDiskState.modificationDate(of: target),
                    recoveryClaim: try? store.claimNewestOrphan(
                        for: target,
                        workspaceRoot: root,
                        claimantID: ownerID
                    )
                )
            }.value
            let recovery = snapshot.recoveryClaim?.record
            let rich: RichDocumentPayload?
            if case .docx = snapshot.content {
                rich = await RichDocumentWorker.shared.load(url: target)
            } else {
                rich = nil
            }
            let recoveredRich: RichDocumentPayload?
            if recovery?.kind == .richDocument,
               let data = recovery?.richDocumentData {
                recoveredRich = await RichDocumentWorker.shared.load(data: data)
            } else {
                recoveredRich = nil
            }
            guard !Task.isCancelled, loadingURL == target else {
                abandonRecoveryClaim(snapshot.recoveryClaim, target: target)
                return
            }
            var restoredRecovery = false
            var recoveryMatchesDisk = false
            switch snapshot.content {
            case let .text(text), let .markdown(text), let .html(text):
                content = snapshot.content
                savedText = text
                if recovery?.kind == .text,
                   let recovered = recovery?.text {
                    if recovered == text {
                        draft = text
                        recoveryMatchesDisk = true
                    } else {
                        draft = recovered
                        restoredRecovery = true
                    }
                } else {
                    draft = text
                }
            case .docx:
                savedRichText = rich?.value.copy() as? NSAttributedString ?? NSAttributedString(string: "")
                if let recoveredRich {
                    content = .docx
                    if let rich, recoveredRich.value.isEqual(to: rich.value) {
                        richDraft = rich.value
                        recoveryMatchesDisk = true
                    } else {
                        richDraft = recoveredRich.value
                        restoredRecovery = true
                    }
                } else if let rich {
                    content = .docx
                    richDraft = rich.value
                } else {
                    content = .unreadable
                    richDraft = NSAttributedString(string: "")
                }
            default:
                savedText = ""
                savedRichText = NSAttributedString(string: "")
                if recovery?.kind == .text,
                   let recovered = recovery?.text {
                    let ext = target.pathExtension.lowercased()
                    if ext == "md" || ext == "markdown" { content = .markdown(recovered) }
                    else if ext == "html" || ext == "htm" { content = .html(recovered) }
                    else { content = .text(recovered) }
                    draft = recovered
                    restoredRecovery = true
                } else if let recoveredRich {
                    content = .docx
                    richDraft = recoveredRich.value
                    restoredRecovery = true
                } else {
                    content = snapshot.content
                    draft = ""
                }
            }
            if let recovery {
                ownedRecoveryToken = recovery.token
                claimedRecoverySourceTokens = snapshot.recoveryClaim?.sourceTokens ?? []
                recoveryRevision = max(recoveryRevision, recovery.revision)
                recoveryFencedRevision = 0
                if recoveryMatchesDisk || !restoredRecovery {
                    clearRecoveryTokens(for: target)
                }
            }
            // A path:line target opens editable source at the exact location;
            // ordinary file browsing keeps the calmer read-first presentation.
            switch snapshot.content {
            case .text, .html:
                isEditingText = targetLine != nil
            default:
                isEditingText = false
            }
            showMarkdownSource = false
            documentZoom = 1
            loadedURL = target
            loadingURL = nil
            recoveredDraftPending = restoredRecovery
            if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
               ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "preview-dirty-tab",
               !restoredRecovery {
                draft += "\n\nUnsaved preview edit"
            }
            lastRecoverableRichDraft = richDraft.copy() as? NSAttributedString ?? richDraft
            loadedModificationDate = restoredRecovery
                ? recovery?.expectedModificationDate
                : snapshot.modificationDate
            if restoredRecovery {
                let diskChanged = snapshot.modificationDate != recovery?.expectedModificationDate
                saveError = diskChanged
                    ? "Recovered an unsaved draft; the file also changed on disk."
                    : "Recovered an unsaved draft."
            } else {
                saveError = nil
            }
            isLoading = false
            refreshHighlight()
            navigationCommitted(target)
        }
    }

    private func promoteEditedPreviewIfNeeded() {
        guard FilePreviewTabPolicy.shouldPromoteEditedPreview(
            loadedURL: loadedURL,
            isDirty: isDirty,
            tabs: tabs
        ), let loadedURL else { return }
        let normalized = loadedURL.standardizedFileURL
        guard pendingEditedPreviewPromotion != normalized else { return }
        pendingEditedPreviewPromotion = normalized
        // `draft` changes arrive during SwiftUI's update transaction. Defer the
        // AppModel publication one turn to avoid publish-during-view-update
        // warnings under fast typing and Markdown autosave.
        Task { @MainActor in
            await Task.yield()
            setTabPinned(normalized, true)
            if pendingEditedPreviewPromotion == normalized {
                pendingEditedPreviewPromotion = nil
            }
        }
    }

    /// Rebuild the syntax-highlighted rendering of `draft` for the current file
    /// and appearance. Non-highlightable extensions (and non-text content) fall
    /// back to a plain monospaced rendering. Pure and cheap — the highlighter
    /// caps and degrades on its own.
    private func refreshHighlight() {
        highlightTask?.cancel()
        guard case .text = content else {
            highlighted = AttributedString(draft)
            return
        }
        let ext = (loadedURL ?? url).pathExtension
        guard let language = SyntaxHighlighter.language(forExtension: ext) else {
            highlighted = AttributedString(draft)
            return
        }
        let theme: SyntaxHighlighter.Theme = colorScheme == .dark ? .dark : .light
        let source = draft
        highlightTask = Task {
            let result = await Task.detached(priority: .utility) {
                SyntaxHighlighter.highlight(source, language: language, theme: theme)
            }.value
            guard !Task.isCancelled, source == draft else { return }
            highlighted = result
        }
    }

    /// Save exactly the snapshot currently displayed. `loadedURL` never moves
    /// until a load finishes, eliminating the old wrong-file race during fast
    /// tree navigation. The mtime check makes concurrent agent edits explicit.
    private func save(
        force: Bool = false,
        advancePendingAction: Bool = false,
        silently: Bool = false
    ) {
        guard let target = loadedURL, !isSaving else { return }
        let expectedDate = loadedModificationDate
        let textSnapshot = draft
        let richSnapshot = RichDocumentPayload(
            value: richDraft.copy() as? NSAttributedString ?? richDraft
        )
        let savingRichDocument: Bool = {
            if case .docx = content { return true }
            return false
        }()
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        recoveryRevision &+= 1
        let revision = recoveryRevision
        let store = recoveryStore
        let root = workspaceRoot
        let ownerID = recoveryOwnerID
        let sourceTokens = claimedRecoverySourceTokens
        let writeRegistration: FilePreviewRecoveryWriteRegistration
        do {
            writeRegistration = try store.beginInFlightWrite(
                ownerID: ownerID,
                revision: revision,
                for: target,
                workspaceRoot: root
            )
        } catch {
            handleRecoveryFailure(error, richDocument: savingRichDocument)
            return
        }
        isSaving = true
        saveTask?.cancel()
        saveTask = Task {
            let recoveryResult = await Task.detached(priority: .userInitiated) {
                defer { store.completeInFlightWrite(writeRegistration) }
                return FilePreviewRecoveryWork.persist(
                    store: store,
                    target: target,
                    workspaceRoot: root,
                    expectedModificationDate: expectedDate,
                    ownerID: ownerID,
                    revision: revision,
                    sourceTokens: sourceTokens,
                    text: textSnapshot,
                    richPayload: savingRichDocument ? richSnapshot : nil
                )
            }.value
            guard !Task.isCancelled,
                  loadedURL == target,
                  recoveryGeneration == generation else {
                if case let .saved(token) = recoveryResult {
                    Task.detached(priority: .utility) {
                        store.remove(token, for: target, workspaceRoot: root)
                    }
                }
                if loadedURL == target { isSaving = false }
                return
            }
            switch recoveryResult {
            case let .saved(token):
                didPersistRecovery(token, richText: richSnapshot.value, richDocument: savingRichDocument)
            case let .failed(message, payloadTooLarge):
                isSaving = false
                saveTask = nil
                handleRecoveryFailure(
                    message: message,
                    payloadTooLarge: payloadTooLarge,
                    richDocument: savingRichDocument
                )
                return
            }

            let result: FilePreviewSaveResult
            if savingRichDocument {
                result = await RichDocumentWorker.shared.write(
                    richSnapshot,
                    to: target,
                    expectedModificationDate: expectedDate,
                    force: force
                )
            } else {
                result = await Task.detached(priority: .userInitiated) {
                    FilePreviewDiskState.writeText(
                        textSnapshot,
                        to: target,
                        expectedModificationDate: expectedDate,
                        force: force
                    )
                }.value
            }
            guard !Task.isCancelled, loadedURL == target else { return }
            isSaving = false
            saveTask = nil
            switch result {
            case let .saved(modificationDate):
                loadedModificationDate = modificationDate
                recoveredDraftPending = false
                if savingRichDocument { savedRichText = richSnapshot.value }
                else { savedText = textSnapshot }
                guard clearRecoveryTokens(for: target) else { return }
                if case .html = content { previewRevision &+= 1 }
                saveError = nil
                if !silently {
                    ToastCenter.shared.show("Saved \(target.lastPathComponent)", style: .success)
                }
                if advancePendingAction { completePendingAction() }
                if case .markdown = content, draft != savedText {
                    scheduleMarkdownAutosave()
                }
            case .changedOnDisk:
                showExternalChangePrompt = true
            case let .failed(message):
                saveError = message
                ToastCenter.shared.show(message, style: .error)
            }
        }
    }

    /// Rendered Markdown is a direct editor rather than a preview/source
    /// toggle. Save after a short quiet period so the document behaves like a
    /// modern notes surface while retaining the existing mtime conflict guard.
    private func scheduleMarkdownAutosave() {
        markdownAutosaveTask?.cancel()
        // The disposable dirty-tab fixture must survive long enough to prove
        // the modified marker. Its document lives in the fixture-only 0700
        // store, and every production surface keeps normal autosave behavior.
        if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
           ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "preview-dirty-tab" {
            return
        }
        guard case .markdown = content,
              loadedURL != nil,
              !isLoading,
              draft != savedText,
              !showExternalChangePrompt else { return }
        markdownAutosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            if isSaving {
                scheduleMarkdownAutosave()
            } else {
                save(silently: true)
            }
        }
    }

    /// A short recovery-only debounce protects ordinary text, Markdown, HTML,
    /// and DOCX editing from hard crashes without touching the project file or
    /// turning each keystroke into a filesystem sync.
    private func scheduleRecoveryJournal() {
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        guard let target = loadedURL,
              !isLoading,
              isEditable,
              isDirty else { return }
        recoveryJournalTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  loadedURL == target,
                  recoveryGeneration == generation,
                  isDirty else { return }
            let savingRichDocument: Bool = {
                if case .docx = content { return true }
                return false
            }()
            let textSnapshot = draft
            let richSnapshot = RichDocumentPayload(
                value: richDraft.copy() as? NSAttributedString ?? richDraft
            )
            recoveryRevision &+= 1
            let revision = recoveryRevision
            let store = recoveryStore
            let root = workspaceRoot
            let ownerID = recoveryOwnerID
            let expectedDate = loadedModificationDate
            let sourceTokens = claimedRecoverySourceTokens
            let writeRegistration: FilePreviewRecoveryWriteRegistration
            do {
                writeRegistration = try store.beginInFlightWrite(
                    ownerID: ownerID,
                    revision: revision,
                    for: target,
                    workspaceRoot: root
                )
            } catch {
                handleRecoveryFailure(error, richDocument: savingRichDocument)
                recoveryJournalTask = nil
                return
            }
            let result = await Task.detached(priority: .utility) {
                defer { store.completeInFlightWrite(writeRegistration) }
                return FilePreviewRecoveryWork.persist(
                    store: store,
                    target: target,
                    workspaceRoot: root,
                    expectedModificationDate: expectedDate,
                    ownerID: ownerID,
                    revision: revision,
                    sourceTokens: sourceTokens,
                    text: textSnapshot,
                    richPayload: savingRichDocument ? richSnapshot : nil
                )
            }.value
            guard !Task.isCancelled,
                  loadedURL == target,
                  recoveryGeneration == generation else {
                if case let .saved(token) = result {
                    Task.detached(priority: .utility) {
                        store.remove(token, for: target, workspaceRoot: root)
                    }
                }
                return
            }
            switch result {
            case let .saved(token):
                didPersistRecovery(
                    token,
                    richText: richSnapshot.value,
                    richDocument: savingRichDocument
                )
            case let .failed(message, payloadTooLarge):
                handleRecoveryFailure(
                    message: message,
                    payloadTooLarge: payloadTooLarge,
                    richDocument: savingRichDocument
                )
            }
            recoveryJournalTask = nil
        }
    }

    /// Used only by the app-termination/view-dismissal barrier. Normal editing
    /// and explicit saves use `FilePreviewRecoveryWork` on a utility executor.
    private func persistRecoverySynchronously(
        target: URL,
        text: String,
        richText: NSAttributedString,
        richDocument: Bool
    ) throws -> FilePreviewRecoveryToken {
        recoveryRevision &+= 1
        if richDocument {
            let data = try RichDocumentIO.data(richText)
            guard FilePreviewDraftBounds.acceptsSerializedRichDocumentData(data) else {
                throw FilePreviewRecoveryStore.RecoveryError.payloadTooLarge
            }
            return try recoveryStore.saveRichDocument(
                data,
                for: target,
                workspaceRoot: workspaceRoot,
                expectedModificationDate: loadedModificationDate,
                ownerID: recoveryOwnerID,
                revision: recoveryRevision,
                sourceTokens: claimedRecoverySourceTokens
            )
        } else {
            return try recoveryStore.saveText(
                text,
                for: target,
                workspaceRoot: workspaceRoot,
                expectedModificationDate: loadedModificationDate,
                ownerID: recoveryOwnerID,
                revision: recoveryRevision,
                sourceTokens: claimedRecoverySourceTokens
            )
        }
    }

    private func didPersistRecovery(
        _ token: FilePreviewRecoveryToken,
        richText: NSAttributedString,
        richDocument: Bool
    ) {
        ownedRecoveryToken = token
        recoveryFencedRevision = 0
        recoveryFencedSourceTokens = []
        recoveryFenceToken = nil
        if richDocument {
            lastRecoverableRichDraft = richText.copy() as? NSAttributedString ?? richText
        }
    }

    @discardableResult
    private func clearRecoveryTokens(for target: URL) -> Bool {
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        let sourceTokens = claimedRecoverySourceTokens
        let uncoveredSources = Set(sourceTokens).subtracting(recoveryFencedSourceTokens)
        if recoveryRevision > recoveryFencedRevision || !uncoveredSources.isEmpty {
            do {
                let fenceToken = try recoveryStore.fence(
                    ownerID: recoveryOwnerID,
                    through: recoveryRevision,
                    for: target,
                    workspaceRoot: workspaceRoot,
                    resolving: sourceTokens
                )
                recoveryRevision = fenceToken.revision
                recoveryFencedRevision = fenceToken.revision
                recoveryFencedSourceTokens = sourceTokens
                recoveryFenceToken = fenceToken
            } catch {
                handleRecoveryFailure(error, richDocument: false)
                return false
            }
        }
        // Physical deletion is now an optimization. The durable tombstone
        // already suppresses these exact sources if the process dies here.
        let store = recoveryStore
        let root = workspaceRoot
        let ownerID = recoveryOwnerID
        let fenceToken = recoveryFenceToken
        Task.detached(priority: .utility) {
            if let fenceToken {
                store.retireFenceWhenSafe(
                    fenceToken,
                    through: fenceToken.revision - 1,
                    for: target,
                    workspaceRoot: root
                )
            }
            store.releaseClaims(
                sourceTokens,
                for: target,
                workspaceRoot: root,
                claimantID: ownerID
            )
        }
        ownedRecoveryToken = nil
        return true
    }

    /// A cancelled load must remove only the claimant copy. Its orphan source
    /// is left intact and made available to the next view.
    private func abandonRecoveryClaim(_ claim: FilePreviewRecoveryClaim?, target: URL) {
        guard let claim else { return }
        recoveryStore.remove(claim.record.token, for: target, workspaceRoot: workspaceRoot)
        recoveryStore.releaseClaims(
            claim.sourceTokens,
            for: target,
            workspaceRoot: workspaceRoot,
            claimantID: recoveryOwnerID
        )
    }

    private func releaseRecoveryClaims() {
        guard let target = loadedURL, !claimedRecoverySourceTokens.isEmpty else { return }
        recoveryStore.releaseClaims(
            claimedRecoverySourceTokens,
            for: target,
            workspaceRoot: workspaceRoot,
            claimantID: recoveryOwnerID
        )
    }

    private func handleRecoveryFailure(_ error: Error, richDocument: Bool) {
        handleRecoveryFailure(
            message: error.localizedDescription,
            payloadTooLarge: (error as? FilePreviewRecoveryStore.RecoveryError) == .payloadTooLarge,
            richDocument: richDocument
        )
    }

    private func handleRecoveryFailure(
        message: String,
        payloadTooLarge: Bool,
        richDocument: Bool
    ) {
        saveError = message
        if richDocument, payloadTooLarge {
            richDraft = lastRecoverableRichDraft
            recoveredDraftPending = !richDraft.isEqual(to: savedRichText)
        }
        ToastCenter.shared.show(message, style: .error)
    }

    private func reportOversizedDraft() {
        let message = "This edit is too large for safe preview recovery."
        saveError = message
        ToastCenter.shared.show(message, style: .error)
    }

    /// A preview dismissal or app quit must never discard the only copy of a
    /// draft. Text previews are capped at 1 MB and rich documents at 20 MB, so
    /// this rare lifecycle barrier performs one bounded atomic write before the
    /// view leaves the hierarchy. A save already in flight owns the same latest
    /// immutable snapshot (editing is disabled while saving) and is allowed to
    /// finish instead of being cancelled by teardown.
    private func flushPendingPreviewSave() {
        markdownAutosaveTask?.cancel()
        recoveryJournalTask?.cancel()
        recoveryGeneration &+= 1
        guard let target = loadedURL else { return }
        guard isDirty else {
            clearRecoveryTokens(for: target)
            return
        }

        let textSnapshot = draft
        let richSnapshot = richDraft.copy() as? NSAttributedString ?? richDraft
        let savingRichDocument: Bool = {
            if case .docx = content { return true }
            return false
        }()
        let recoveryToken: FilePreviewRecoveryToken
        do {
            recoveryToken = try persistRecoverySynchronously(
                target: target,
                text: textSnapshot,
                richText: richSnapshot,
                richDocument: savingRichDocument
            )
            didPersistRecovery(recoveryToken, richText: richSnapshot, richDocument: savingRichDocument)
        } catch {
            handleRecoveryFailure(error, richDocument: savingRichDocument)
            return
        }
        // The durable snapshot above is the lifecycle guarantee. Avoid racing
        // an in-flight writer or bypassing an unresolved external-edit choice.
        guard !isSaving, !showExternalChangePrompt else { return }

        let result: FilePreviewSaveResult
        if savingRichDocument {
            guard !FilePreviewDiskState.changed(onDisk: target, since: loadedModificationDate) else {
                saveError = "The file changed on disk. Your open draft was not overwritten."
                return
            }
            do {
                try RichDocumentIO.write(richSnapshot, to: target)
                result = .saved(FilePreviewDiskState.modificationDate(of: target))
            } catch {
                result = .failed(error.localizedDescription)
            }
        } else {
            result = FilePreviewDiskState.writeText(
                textSnapshot,
                to: target,
                expectedModificationDate: loadedModificationDate,
                force: false
            )
        }

        switch result {
        case let .saved(modificationDate):
            recoveredDraftPending = false
            if savingRichDocument { savedRichText = richSnapshot }
            else { savedText = textSnapshot }
            loadedModificationDate = modificationDate
            guard clearRecoveryTokens(for: target) else { return }
            saveError = nil
        case .changedOnDisk:
            saveError = "The file changed on disk. Your open draft was not overwritten."
        case let .failed(message):
            saveError = message
        }
    }

    private func adjustZoom(_ delta: CGFloat) {
        documentZoom = min(2, max(0.65, ((documentZoom + delta) * 10).rounded() / 10))
    }

    /// Markdown → AttributedString with a plain-text fallback so a parse
    /// failure can never blank the preview. Pure, hence nonisolated (CI's
    /// stricter inference otherwise pins View statics to the main actor).
    nonisolated static func renderMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(text)
    }
}

/// Lightweight syntax roles for the rendered Markdown editor. The spans are
/// computed off the main actor and applied as TextKit temporary attributes, so
/// the file remains exact Markdown source even though it reads like a document.
struct MarkdownEditingStyle: Sendable {
    enum Role: Equatable, Sendable {
        case heading(Int)
        case quote
        case codeBlock
        case bold
        case italic
        case inlineCode
        case link
        case listMarker
        case centered
        case syntax
    }

    struct Span: Equatable, Sendable {
        let range: NSRange
        let role: Role
    }

    nonisolated static func spans(in source: String) -> [Span] {
        guard !source.isEmpty else { return [] }
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        var result: [Span] = []

        func collect(
            _ pattern: String,
            options: NSRegularExpression.Options = [],
            role: (NSTextCheckingResult) -> Role?,
            contentGroup: Int = 0,
            syntaxGroups: [Int] = []
        ) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            expression.enumerateMatches(in: source, range: fullRange) { match, _, _ in
                guard let match,
                      let resolvedRole = role(match),
                      contentGroup < match.numberOfRanges else { return }
                let range = match.range(at: contentGroup)
                if range.location != NSNotFound, range.length > 0 {
                    result.append(Span(range: range, role: resolvedRole))
                }
                for group in syntaxGroups where group < match.numberOfRanges {
                    let syntaxRange = match.range(at: group)
                    if syntaxRange.location != NSNotFound, syntaxRange.length > 0 {
                        result.append(Span(range: syntaxRange, role: .syntax))
                    }
                }
            }
        }

        // Inline roles are applied first. Block roles that overlap them are
        // appended later and therefore remain visually dominant.
        collect(#"(?<!\*)(\*\*)([^*\n]+)(\*\*)(?!\*)"#, role: { _ in .bold }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?<!_)(__)([^_\n]+)(__)(?!_)"#, role: { _ in .bold }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?<!\*)(\*)([^*\n]+)(\*)(?!\*)"#, role: { _ in .italic }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?<!_)(_)([^_\n]+)(_)(?!_)"#, role: { _ in .italic }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(`)([^`\n]+)(`)"#, role: { _ in .inlineCode }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(
            #"(!?\[)([^]\r\n]+)(\]\()([^)\r\n]+)(\))"#,
            role: { _ in .link },
            contentGroup: 2,
            syntaxGroups: [1, 3, 4, 5]
        )
        // README files commonly mix a small, presentational HTML subset into
        // Markdown. Keep the exact source editable, but style the human text
        // and collapse the tags just like Markdown delimiters. The raw-source
        // toggle remains available for changing attributes/URLs explicitly.
        collect(#"(?is)(<h([1-6])\b[^>]*>)(.*?)(</h\2\s*>)"#, role: { match in
            let levelRange = match.range(at: 2)
            guard levelRange.location != NSNotFound else { return nil }
            return .heading(Int((source as NSString).substring(with: levelRange)) ?? 1)
        }, contentGroup: 3, syntaxGroups: [1, 4])
        collect(#"(?is)(<strong\b[^>]*>)(.*?)(</strong\s*>)"#, role: { _ in .bold }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?is)(<(?:em|i)\b[^>]*>)(.*?)(</(?:em|i)\s*>)"#, role: { _ in .italic }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?is)(<code\b[^>]*>)(.*?)(</code\s*>)"#, role: { _ in .inlineCode }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(#"(?is)(<a\b[^>]*>)(.*?)(</a\s*>)"#, role: { _ in .link }, contentGroup: 2, syntaxGroups: [1, 3])
        collect(
            #"(?is)(<(?:h[1-6]|p)\b[^>]*\balign\s*=\s*[\"']?center[\"']?[^>]*>)(.*?)(</(?:h[1-6]|p)\s*>)"#,
            role: { _ in .centered },
            contentGroup: 2
        )
        collect(#"(?is)<[^>]+>"#, role: { _ in .syntax })
        collect(#"(?m)^(#{1,6})(?:[ \t]+)(.+)$"#, role: { match in
            .heading(min(6, match.range(at: 1).length))
        }, contentGroup: 2, syntaxGroups: [1])
        collect(#"(?m)^([ \t]*>[ \t]?)(.*)$"#, role: { _ in .quote }, contentGroup: 2, syntaxGroups: [1])
        // Keep list markers visible while editing. Unlike emphasis and link
        // delimiters, the marker is meaningful document chrome: showing it
        // makes Return-driven list continuation feel immediate and keeps the
        // current nesting level obvious without exposing the rest of the raw
        // Markdown syntax.
        collect(#"(?m)^([ \t]*(?:[-+*]|[0-9]+\.)[ \t]+)"#, role: { _ in .listMarker })
        collect(
            #"(?ms)^([ \t]*(?:```|~~~)[^\n]*\n).*?^([ \t]*(?:```|~~~)[ \t]*$)"#,
            role: { _ in .codeBlock }
        )
        return Array(result.prefix(20_000))
    }
}

/// Plain source editor used when a terminal/chat opens `path:line`. TextKit
/// gives us exact one-based line navigation while retaining native selection,
/// undo, find, and a lightweight editing surface.
enum FileLineNavigation {
    static func range(forOneBasedLine line: Int, in text: String) -> NSRange {
        let source = text as NSString
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        var location = 0
        var current = 1
        while current < line, location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        guard current == line else { return NSRange(location: source.length, length: 0) }
        return source.lineRange(for: NSRange(location: location, length: 0))
    }
}

private struct LineTargetTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let targetLine: Int?
    let documentID: String
    var markdownURL: URL? = nil
    var workspaceRoot: URL? = nil
    var onError: ((String) -> Void)? = nil
    var autoFocus = false
    var magnification: CGFloat? = nil
    var onMagnificationChanged: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView: NSScrollView
        if markdownURL != nil, let magnification {
            let markdownScrollView = MarkdownMagnifyingScrollView()
            markdownScrollView.allowsMagnification = true
            markdownScrollView.minMagnification = 0.65
            markdownScrollView.maxMagnification = 2
            markdownScrollView.magnification = magnification
            markdownScrollView.onMagnificationChanged = onMagnificationChanged
            scrollView = markdownScrollView
        } else {
            scrollView = NSScrollView()
        }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = markdownURL == nil
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView: NSTextView
        if markdownURL != nil {
            // The whole-file Markdown source surface is the deliberately
            // narrow TextKit 2 pilot.  Constructing with `frame:` silently
            // selects TextKit 1; opting in here keeps exact source editing
            // while allowing viewport-based layout for large documents.  The
            // rendered editor stays on TextKit 1 for now because its
            // presentation-only syntax hiding uses temporary NSLayoutManager
            // attributes and must not mutate document bytes.
            let markdownTextView = MarkdownNativeTextView.wholeFileSourceEditor()
            markdownTextView.registerForDraggedTypes([.fileURL, .png, .tiff])
            markdownTextView.onImageImports = { [weak coordinator = context.coordinator] imports, range in
                coordinator?.importImages(imports, at: range)
            }
            markdownTextView.onChooseImages = { [weak coordinator = context.coordinator] range in
                coordinator?.chooseImages(at: range)
            }
            textView = markdownTextView
        } else {
            textView = NSTextView(frame: .zero)
        }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = markdownURL == nil
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: markdownURL == nil ? CGFloat.greatestFiniteMagnitude : 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = markdownURL != nil
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.string = text
        scrollView.documentView = textView
        (scrollView as? MarkdownMagnifyingScrollView)?.reflowDocumentWidth()
        context.coordinator.textView = textView
        context.coordinator.markdownURL = markdownURL
        context.coordinator.workspaceRoot = workspaceRoot
        context.coordinator.onError = onError
        context.coordinator.scrollIfNeeded(to: targetLine, documentID: documentID)
        if autoFocus {
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.markdownURL = markdownURL
        context.coordinator.workspaceRoot = workspaceRoot
        context.coordinator.onError = onError
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingExternalValue = true
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
            context.coordinator.isApplyingExternalValue = false
        }
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if let markdownScrollView = scrollView as? MarkdownMagnifyingScrollView {
            markdownScrollView.onMagnificationChanged = onMagnificationChanged
            if let magnification, abs(markdownScrollView.magnification - magnification) > 0.001 {
                let center = NSPoint(
                    x: markdownScrollView.contentView.bounds.midX,
                    y: markdownScrollView.contentView.bounds.midY
                )
                markdownScrollView.setMagnification(magnification, centeredAt: center)
            }
            markdownScrollView.reflowDocumentWidth()
        }
        context.coordinator.scrollIfNeeded(to: targetLine, documentID: documentID)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        var markdownURL: URL?
        var workspaceRoot: URL?
        var onError: ((String) -> Void)?
        var isApplyingExternalValue = false
        private var lastScrollKey: String?
        private var importTask: Task<Void, Never>?

        init(text: Binding<String>) { _text = text }

        deinit { importTask?.cancel() }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func scrollIfNeeded(to oneBasedLine: Int?, documentID: String) {
            guard let oneBasedLine, oneBasedLine > 0, let textView else { return }
            let key = "\(documentID)|\(oneBasedLine)|\(textView.string.utf8.count)"
            guard key != lastScrollKey else { return }
            lastScrollKey = key
            let range = FileLineNavigation.range(forOneBasedLine: oneBasedLine, in: textView.string)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollRangeToVisible(range)
                textView?.showFindIndicator(for: range)
            }
        }

        func importImages(_ imports: [MarkdownImageImport], at requestedRange: NSRange) {
            guard let markdownURL else { return }
            let workspaceRoot = workspaceRoot
            let previousImport = importTask
            importTask = Task { [weak self] in
                if let previousImport { await previousImport.value }
                guard !Task.isCancelled else { return }
                let batch = await Task.detached(priority: .userInitiated) {
                    MarkdownAssetStore.importImages(
                        imports,
                        markdownURL: markdownURL,
                        workspaceRoot: workspaceRoot
                    )
                }.value
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                if !batch.insertions.isEmpty {
                    let source = textView.string
                    let nsSource = source as NSString
                    let location = min(max(0, requestedRange.location), nsSource.length)
                    let length = min(max(0, requestedRange.length), nsSource.length - location)
                    let range = NSRange(location: location, length: length)
                    let insertion = MarkdownImageInsertion.text(
                        snippets: batch.insertions.map(\.markdown),
                        source: source,
                        range: range
                    )
                    textView.insertText(insertion, replacementRange: range)
                }
                if !batch.errors.isEmpty {
                    self.onError?(batch.errors.joined(separator: " "))
                }
            }
        }

        func chooseImages(at range: NSRange) {
            let panel = NSOpenPanel()
            panel.title = "Add images to Markdown"
            panel.prompt = "Add"
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK else { return }
            importImages(panel.urls.map(MarkdownImageImport.file), at: range)
        }

    }
}

/// Editable, styled Markdown with native selection, undo, find, contextual
/// editing, image paste/drop, and trackpad/Command-scroll magnification.
private struct MarkdownRenderedEditor: NSViewRepresentable {
    @Binding var text: String
    let markdownURL: URL
    let workspaceRoot: URL?
    @Binding var zoom: CGFloat
    let targetLine: Int?
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, zoom: $zoom)
    }

    func makeNSView(context: Context) -> MarkdownMagnifyingScrollView {
        let scrollView = MarkdownMagnifyingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.65
        scrollView.maxMagnification = 2

        let textView = MarkdownNativeTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        // Autocorrect is the one AppKit affordance here that mutates text
        // storage rather than presentation, so it can silently rewrite the
        // document — inside fenced code blocks especially. The plain source
        // editor leaves it off; this view must match, or the byte-identity
        // guarantee that makes rendered editing safe no longer holds.
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 18, height: 20)
        textView.backgroundColor = .textBackgroundColor
        textView.font = .systemFont(ofSize: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 5
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        textView.string = text
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.onImageImports = { [weak coordinator = context.coordinator] imports, range in
            coordinator?.importImages(imports, at: range)
        }
        textView.onChooseImages = { [weak coordinator = context.coordinator] range in
            coordinator?.chooseImages(at: range)
        }

        scrollView.documentView = textView
        scrollView.magnification = zoom
        scrollView.onMagnificationChanged = { [weak coordinator = context.coordinator] value in
            coordinator?.zoom = value
        }
        context.coordinator.textView = textView
        context.coordinator.markdownURL = markdownURL
        context.coordinator.workspaceRoot = workspaceRoot
        context.coordinator.onError = onError
        context.coordinator.scheduleStyling(immediately: true)
        context.coordinator.scrollIfNeeded(to: targetLine)
        return scrollView
    }

    func updateNSView(_ scrollView: MarkdownMagnifyingScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.markdownURL = markdownURL
        coordinator.workspaceRoot = workspaceRoot
        coordinator.onError = onError
        guard let textView = coordinator.textView else { return }

        if textView.string != text {
            let selection = textView.selectedRange()
            coordinator.isApplyingExternalValue = true
            textView.string = text
            let location = min(selection.location, (text as NSString).length)
            let length = min(selection.length, (text as NSString).length - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            coordinator.isApplyingExternalValue = false
            coordinator.scheduleStyling(immediately: true)
        }
        if abs(scrollView.magnification - zoom) > 0.001 {
            let center = textView.convert(
                NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY),
                from: scrollView.contentView
            )
            scrollView.setMagnification(zoom, centeredAt: center)
        }
        // SwiftUI can install the representable after NSTextView has already
        // kept its 640-point seed frame. Width tracking then follows that stale
        // document width rather than the live pane, so source lines paint past
        // the clip view. Reconcile here as well as during NSScrollView tiling so
        // external zoom changes and the first representable update both reflow.
        scrollView.reflowDocumentWidth()
        coordinator.scrollIfNeeded(to: targetLine)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var zoom: CGFloat
        weak var textView: MarkdownNativeTextView?
        var markdownURL: URL?
        var workspaceRoot: URL?
        var onError: ((String) -> Void)?
        var isApplyingExternalValue = false
        private var styleTask: Task<Void, Never>?
        private var importTask: Task<Void, Never>?
        private var lastScrollKey: String?

        init(text: Binding<String>, zoom: Binding<CGFloat>) {
            _text = text
            _zoom = zoom
        }

        deinit {
            styleTask?.cancel()
            importTask?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView = notification.object as? MarkdownNativeTextView else { return }
            text = textView.string
            scheduleStyling(immediately: false)
        }

        func scrollIfNeeded(to oneBasedLine: Int?) {
            guard let oneBasedLine, oneBasedLine > 0, let textView else { return }
            let key = "\(markdownURL?.path ?? "")|\(oneBasedLine)|\(textView.string.utf8.count)"
            guard key != lastScrollKey else { return }
            lastScrollKey = key
            let range = FileLineNavigation.range(forOneBasedLine: oneBasedLine, in: textView.string)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            DispatchQueue.main.async { [weak textView] in
                textView?.scrollRangeToVisible(range)
                textView?.showFindIndicator(for: range)
            }
        }

        func scheduleStyling(immediately: Bool) {
            styleTask?.cancel()
            guard let textView else { return }
            let source = textView.string
            styleTask = Task { [weak self, weak textView] in
                if !immediately {
                    try? await Task.sleep(for: .milliseconds(70))
                }
                guard !Task.isCancelled else { return }
                let spans = await Task.detached(priority: .utility) {
                    MarkdownEditingStyle.spans(in: source)
                }.value
                guard !Task.isCancelled,
                      let self,
                      let textView,
                      textView.string == source else { return }
                self.apply(spans, to: textView)
            }
        }

        func importImages(_ imports: [MarkdownImageImport], at requestedRange: NSRange) {
            guard let markdownURL else { return }
            let workspaceRoot = workspaceRoot
            // Preserve every paste/drop and serialize writes so rapid imports
            // cannot race for the same unique filename.
            let previousImport = importTask
            importTask = Task { [weak self] in
                if let previousImport { await previousImport.value }
                guard !Task.isCancelled else { return }
                let batch = await Task.detached(priority: .userInitiated) {
                    MarkdownAssetStore.importImages(
                        imports,
                        markdownURL: markdownURL,
                        workspaceRoot: workspaceRoot
                    )
                }.value
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                if !batch.insertions.isEmpty {
                    let safeLocation = min(requestedRange.location, (textView.string as NSString).length)
                    let safeLength = min(
                        requestedRange.length,
                        (textView.string as NSString).length - safeLocation
                    )
                    let range = NSRange(location: safeLocation, length: safeLength)
                    let insertion = MarkdownImageInsertion.text(
                        snippets: batch.insertions.map(\.markdown),
                        source: textView.string,
                        range: range
                    )
                    textView.insertText(insertion, replacementRange: range)
                }
                if !batch.errors.isEmpty {
                    self.onError?(batch.errors.joined(separator: " "))
                }
            }
        }

        func chooseImages(at range: NSRange) {
            let panel = NSOpenPanel()
            panel.title = "Add images to Markdown"
            panel.prompt = "Add"
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK else { return }
            importImages(panel.urls.map(MarkdownImageImport.file), at: range)
        }

        private func apply(_ spans: [MarkdownEditingStyle.Span], to textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            for key in [
                NSAttributedString.Key.font,
                .foregroundColor,
                .backgroundColor,
                .underlineStyle,
                .obliqueness,
                .paragraphStyle,
            ] {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: fullRange)
            }

            let bodySize: CGFloat = 15
            for span in spans where NSMaxRange(span.range) <= fullRange.length {
                switch span.role {
                case let .heading(level):
                    let sizes: [CGFloat] = [0, 30, 25, 21, 18, 16, 15]
                    layoutManager.addTemporaryAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: sizes[min(6, level)], weight: level <= 2 ? .bold : .semibold),
                        forCharacterRange: span.range
                    )
                case .quote:
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.obliqueness, value: 0.12, forCharacterRange: span.range)
                case .codeBlock:
                    layoutManager.addTemporaryAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.labelColor, forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.controlBackgroundColor, forCharacterRange: span.range)
                case .bold:
                    layoutManager.addTemporaryAttribute(.font, value: NSFont.systemFont(ofSize: bodySize, weight: .semibold), forCharacterRange: span.range)
                case .italic:
                    layoutManager.addTemporaryAttribute(.obliqueness, value: 0.16, forCharacterRange: span.range)
                case .inlineCode:
                    layoutManager.addTemporaryAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.controlBackgroundColor, forCharacterRange: span.range)
                case .link:
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.linkColor, forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: span.range)
                case .listMarker:
                    layoutManager.addTemporaryAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: bodySize, weight: .semibold),
                        forCharacterRange: span.range
                    )
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor,
                        value: NSColor.controlAccentColor,
                        forCharacterRange: span.range
                    )
                case .centered:
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    paragraph.lineSpacing = 3
                    paragraph.paragraphSpacing = 5
                    layoutManager.addTemporaryAttribute(.paragraphStyle, value: paragraph, forCharacterRange: span.range)
                case .syntax:
                    // Default mode reads like a document: syntax occupies an
                    // effectively zero-width run while the source stays exact
                    // underneath. The toolbar's source toggle is the explicit
                    // escape hatch for editing delimiters and HTML attributes.
                    layoutManager.addTemporaryAttribute(.font, value: NSFont.systemFont(ofSize: 0.1), forCharacterRange: span.range)
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: span.range)
                }
            }
            // Temporary font attributes affect glyph metrics only after the
            // layout pass is invalidated. Without this, invisible delimiters
            // can still wrap visible text at narrow panel widths.
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            if let container = textView.textContainer {
                layoutManager.ensureLayout(for: container)
            }
        }
    }
}

final class MarkdownMagnifyingScrollView: NSScrollView {
    var onMagnificationChanged: ((CGFloat) -> Void)?

    override func tile() {
        super.tile()
        reflowDocumentWidth()
    }

    /// Keep the editable Markdown document exactly as wide as the visible
    /// viewport in document coordinates. `contentView.bounds` already accounts
    /// for NSScrollView magnification, so this preserves zoom while ensuring
    /// paragraphs rewrap instead of disappearing beyond a narrow split pane.
    func reflowDocumentWidth() {
        guard let textView = documentView as? NSTextView else { return }
        let width = contentView.bounds.width
        guard width.isFinite, width > 0 else { return }

        if abs(textView.frame.width - width) > 0.5 {
            var frame = textView.frame
            frame.size.width = width
            textView.frame = frame
        }

        guard let container = textView.textContainer else { return }
        let containerWidth = max(1, width - (textView.textContainerInset.width * 2))
        guard abs(container.containerSize.width - containerWidth) > 0.5 else { return }
        container.containerSize = NSSize(
            width: containerWidth,
            height: container.containerSize.height
        )
        if let textLayoutManager = textView.textLayoutManager {
            // Keep the whole-file source editor on TextKit 2. Asking a TextKit
            // 2 view for its legacy layout manager silently downgrades it.
            textLayoutManager.textViewportLayoutController.layoutViewport()
        } else if let layoutManager = textView.layoutManager {
            let range = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.ensureLayout(for: container)
        }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        reflowDocumentWidth()
        onMagnificationChanged?(magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        guard let target = MarkdownWheelZoom.target(
            current: magnification,
            scrollingDeltaY: event.scrollingDeltaY,
            scrollingDeltaX: event.scrollingDeltaX
        ) else { return }
        let center = documentView?.convert(event.locationInWindow, from: nil)
            ?? NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(target, centeredAt: center)
        reflowDocumentWidth()
        onMagnificationChanged?(target)
    }
}

enum MarkdownWheelZoom {
    static func target(
        current: CGFloat,
        scrollingDeltaY: CGFloat,
        scrollingDeltaX: CGFloat
    ) -> CGFloat? {
        let delta = scrollingDeltaY == 0 ? scrollingDeltaX : scrollingDeltaY
        guard delta.isFinite, delta != 0 else { return nil }
        let target = MarkdownPreviewLayout.clampedZoom(current + delta * 0.01)
        return abs(target - current) > 0.001 ? target : nil
    }
}

/// SwiftUI's `MagnificationGesture` handles trackpad pinches but does not see a
/// Command-mouse-wheel gesture. This transparent AppKit bridge observes only
/// Command-scroll events whose pointer is inside the rendered Markdown pane;
/// every ordinary scroll continues through the enclosing SwiftUI ScrollView.
private struct MarkdownCommandScrollZoomBridge: NSViewRepresentable {
    @Binding var zoom: CGFloat

    func makeNSView(context: Context) -> MarkdownCommandScrollMonitorView {
        MarkdownCommandScrollMonitorView()
    }

    func updateNSView(_ view: MarkdownCommandScrollMonitorView, context: Context) {
        view.currentZoom = zoom
        view.onZoom = { zoom = $0 }
    }
}

@MainActor
private final class MarkdownCommandScrollMonitorView: NSView {
    var currentZoom: CGFloat = 1
    var onZoom: (CGFloat) -> Void = { _ in }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                  let target = MarkdownWheelZoom.target(
                      current: self.currentZoom,
                      scrollingDeltaY: event.scrollingDeltaY,
                      scrollingDeltaX: event.scrollingDeltaX
                  ) else { return event }
            self.currentZoom = target
            self.onZoom(target)
            return nil
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

enum MarkdownListContinuation: Equatable, Sendable {
    case continueWith(String)
    case exitList

    static func action(for line: String) -> MarkdownListContinuation? {
        let range = NSRange(location: 0, length: (line as NSString).length)
        if let expression = try? NSRegularExpression(
            pattern: #"^([ \t]*)([-+*])([ \t]+)(?:\[([ xX])\]([ \t]+))?(.*)$"#
        ), let match = expression.firstMatch(in: line, range: range) {
            let body = substring(match.range(at: 6), in: line)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .exitList
            }
            let indent = substring(match.range(at: 1), in: line)
            let marker = substring(match.range(at: 2), in: line)
            let spacing = substring(match.range(at: 3), in: line)
            if match.range(at: 4).location != NSNotFound {
                return .continueWith(
                    indent + marker + spacing + "[ ]" + substring(match.range(at: 5), in: line)
                )
            }
            return .continueWith(indent + marker + spacing)
        }

        if let expression = try? NSRegularExpression(
            pattern: #"^([ \t]*)([0-9]+)([.)])([ \t]+)(.*)$"#
        ), let match = expression.firstMatch(in: line, range: range) {
            let body = substring(match.range(at: 5), in: line)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .exitList
            }
            let current = Int(substring(match.range(at: 2), in: line)) ?? 0
            return .continueWith(
                substring(match.range(at: 1), in: line)
                    + String(current + 1)
                    + substring(match.range(at: 3), in: line)
                    + substring(match.range(at: 4), in: line)
            )
        }
        return nil
    }

    private static func substring(_ range: NSRange, in value: String) -> String {
        guard range.location != NSNotFound else { return "" }
        return (value as NSString).substring(with: range)
    }
}

@MainActor
final class MarkdownNativeTextView: NSTextView {
    var onImageImports: (([MarkdownImageImport], NSRange) -> Void)?
    var onChooseImages: ((NSRange) -> Void)?

    static func wholeFileSourceEditor() -> MarkdownNativeTextView {
        MarkdownNativeTextView(usingTextLayoutManager: true)
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0 else {
            super.insertNewline(sender)
            return
        }
        let source = string as NSString
        let paragraph = source.paragraphRange(for: selection)
        let contentEnd = paragraph.location + paragraph.length
            - lineTerminatorLength(in: source, paragraph: paragraph)
        guard selection.location <= contentEnd else {
            super.insertNewline(sender)
            return
        }
        let prefixRange = NSRange(
            location: paragraph.location,
            length: selection.location - paragraph.location
        )
        let lineBeforeCaret = source.substring(with: prefixRange)
        switch MarkdownListContinuation.action(for: lineBeforeCaret) {
        case let .continueWith(prefix):
            insertText("\n" + prefix, replacementRange: selection)
        case .exitList where selection.location == contentEnd:
            insertText("\n", replacementRange: paragraph)
        case .exitList, .none:
            super.insertNewline(sender)
        }
    }

    private func lineTerminatorLength(in source: NSString, paragraph: NSRange) -> Int {
        guard paragraph.length > 0 else { return 0 }
        let last = source.character(at: NSMaxRange(paragraph) - 1)
        guard last == 0x0A || last == 0x0D else { return 0 }
        if paragraph.length > 1, last == 0x0A,
           source.character(at: NSMaxRange(paragraph) - 2) == 0x0D {
            return 2
        }
        return 1
    }

    override func paste(_ sender: Any?) {
        let imports = MarkdownPasteboardReader.imports(from: .general)
        guard !imports.isEmpty else {
            super.paste(sender)
            return
        }
        onImageImports?(imports, selectedRange())
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        MarkdownPasteboardReader.containsImages(sender.draggingPasteboard)
            ? .copy
            : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let imports = MarkdownPasteboardReader.imports(from: sender.draggingPasteboard)
        guard !imports.isEmpty else { return super.performDragOperation(sender) }
        onImageImports?(imports, insertionRange(for: sender))
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        addItem("Bold", action: #selector(formatBold(_:)), to: menu)
        addItem("Italic", action: #selector(formatItalic(_:)), to: menu)
        addItem("Inline Code", action: #selector(formatInlineCode(_:)), to: menu)
        addItem("Link", action: #selector(formatLink(_:)), to: menu)
        addItem("Heading", action: #selector(formatHeading(_:)), to: menu)
        addItem("Bulleted List", action: #selector(formatBulletedList(_:)), to: menu)
        menu.addItem(.separator())
        addItem("Insert Image…", action: #selector(chooseImage(_:)), to: menu)
        return menu
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func formatBold(_ sender: Any?) {
        wrapSelection(prefix: "**", suffix: "**", placeholder: "bold text")
    }

    @objc private func formatItalic(_ sender: Any?) {
        wrapSelection(prefix: "*", suffix: "*", placeholder: "italic text")
    }

    @objc private func formatInlineCode(_ sender: Any?) {
        wrapSelection(prefix: "`", suffix: "`", placeholder: "code")
    }

    @objc private func formatLink(_ sender: Any?) {
        let range = selectedRange()
        let selected = range.length > 0 ? (string as NSString).substring(with: range) : "link text"
        let replacement = "[\(selected)](https://)"
        insertText(replacement, replacementRange: range)
        if range.length == 0 {
            setSelectedRange(NSRange(location: range.location + 1, length: selected.utf16.count))
        } else {
            setSelectedRange(NSRange(location: range.location + selected.utf16.count + 3, length: 8))
        }
    }

    @objc private func formatHeading(_ sender: Any?) {
        transformSelectedLines { line in
            let expression = try? NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
            let range = NSRange(location: 0, length: (line as NSString).length)
            if expression?.firstMatch(in: line, range: range) != nil {
                return expression?.stringByReplacingMatches(in: line, range: range, withTemplate: "") ?? line
            }
            return line.isEmpty ? line : "## \(line)"
        }
    }

    @objc private func formatBulletedList(_ sender: Any?) {
        let paragraphRange = (string as NSString).paragraphRange(for: selectedRange())
        let source = (string as NSString).substring(with: paragraphRange)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let alreadyBulleted = !nonempty.isEmpty && nonempty.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
        }
        transformSelectedLines { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if alreadyBulleted,
               let marker = line.range(of: "- ") {
                return String(line[..<marker.lowerBound]) + line[marker.upperBound...]
            }
            return "- \(line)"
        }
    }

    @objc private func chooseImage(_ sender: Any?) {
        onChooseImages?(selectedRange())
    }

    private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
        let range = selectedRange()
        let selected = range.length > 0 ? (string as NSString).substring(with: range) : placeholder
        insertText(prefix + selected + suffix, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + prefix.utf16.count, length: selected.utf16.count))
    }

    private func transformSelectedLines(_ transform: (String) -> String) {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        let source = (string as NSString).substring(with: range)
        let replacement = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { transform(String($0)) }
            .joined(separator: "\n")
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: replacement.utf16.count))
    }

    private func insertionRange(for sender: any NSDraggingInfo) -> NSRange {
        let local = convert(sender.draggingLocation, from: nil)
        // NSTextView owns the TextKit-version-specific hit testing. Accessing
        // the legacy `layoutManager` from a TextKit 2 view forces AppKit to
        // fall back to TextKit 1, so keep image-drop positioning on this
        // version-neutral API.
        let character = min(characterIndexForInsertion(at: local), (string as NSString).length)
        return NSRange(location: character, length: 0)
    }
}

@MainActor
private enum MarkdownPasteboardReader {
    static func containsImages(_ pasteboard: NSPasteboard) -> Bool {
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff"])
        if let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], values.contains(where: { imageExtensions.contains($0.pathExtension.lowercased()) }) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    static func imports(from pasteboard: NSPasteboard) -> [MarkdownImageImport] {
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tif", "tiff"])
        if let values = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            let files = values.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            if !files.isEmpty { return files.map(MarkdownImageImport.file) }
        }

        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return [.data(png, suggestedName: "pasted-image", fileExtension: "png")]
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return [] }
        return [.data(png, suggestedName: "pasted-image", fileExtension: "png")]
    }
}

/// Native rich-text editor for Office Open XML documents. NSTextView preserves
/// formatting and provides undo, find, selection, spell checking, and familiar
/// macOS editing semantics; the surrounding neutral canvas gives the document
/// a quiet page-like surface rather than another dense application toolbar.
private struct RichDocumentEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    let zoom: CGFloat
    let command: RichDocumentCommand?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.65
        scrollView.maxMagnification = 2

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 34, height: 30)
        textView.backgroundColor = .textBackgroundColor
        textView.textStorage?.setAttributedString(text)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.magnification = zoom
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if !textView.attributedString().isEqual(to: text) {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingExternalValue = true
            textView.textStorage?.setAttributedString(text)
            textView.setSelectedRange(NSIntersectionRange(
                selection,
                NSRange(location: 0, length: text.length)
            ))
            context.coordinator.isApplyingExternalValue = false
        }
        if abs(scrollView.magnification - zoom) > 0.001 {
            scrollView.setMagnification(zoom, centeredAt: NSPoint(
                x: scrollView.contentView.bounds.midX,
                y: scrollView.contentView.bounds.midY
            ))
        }
        if let command, context.coordinator.lastCommandID != command.id {
            context.coordinator.lastCommandID = command.id
            context.coordinator.apply(command.kind)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: NSAttributedString
        weak var textView: NSTextView?
        var isApplyingExternalValue = false
        var lastCommandID: UUID?

        init(text: Binding<NSAttributedString>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView = notification.object as? NSTextView else { return }
            publish(textView)
        }

        func apply(_ command: RichDocumentCommand.Kind) {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            switch command {
            case .bold:
                applyFontTrait(.boldFontMask, to: textView, storage: storage, selection: selection)
            case .italic:
                applyFontTrait(.italicFontMask, to: textView, storage: storage, selection: selection)
            case .underline:
                if selection.length > 0 {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: selection)
                } else {
                    textView.typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            case .heading:
                let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
                if selection.length > 0 { storage.addAttribute(.font, value: font, range: selection) }
                else { textView.typingAttributes[.font] = font }
            case .bulletList:
                let paragraphRange = (textView.string as NSString).paragraphRange(for: selection)
                let source = (textView.string as NSString).substring(with: paragraphRange)
                let bulleted = source.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? "" : "• \($0)" }
                    .joined(separator: "\n")
                textView.insertText(bulleted, replacementRange: paragraphRange)
            }
            publish(textView)
        }

        private func applyFontTrait(
            _ trait: NSFontTraitMask,
            to textView: NSTextView,
            storage: NSTextStorage,
            selection: NSRange
        ) {
            let manager = NSFontManager.shared
            if selection.length == 0 {
                let current = textView.typingAttributes[.font] as? NSFont
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                textView.typingAttributes[.font] = manager.convert(current, toHaveTrait: trait)
                return
            }
            storage.enumerateAttribute(.font, in: selection) { value, range, _ in
                let current = value as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                storage.addAttribute(.font, value: manager.convert(current, toHaveTrait: trait), range: range)
            }
        }

        private func publish(_ textView: NSTextView) {
            text = textView.attributedString().copy() as? NSAttributedString
                ?? NSAttributedString(string: textView.string)
        }
    }
}

/// Small native Markdown document model. `Text(AttributedString(markdown:))`
/// renders inline emphasis but ignores most block presentation intents, which
/// is why headings, lists, quotes, tables, and fenced code previously collapsed
/// into an almost-plain paragraph. This parser preserves those structural
/// blocks while still delegating inline Markdown to Foundation.
struct MarkdownDocument: Equatable, Sendable {
    enum ContentAlignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String, alignment: ContentAlignment?)
        case paragraph(String, alignment: ContentAlignment?)
        case image(
            source: String,
            alt: String?,
            declaredWidth: Double?,
            declaredHeight: Double?,
            alignment: ContentAlignment?
        )
        case listItem(indent: Int, marker: String, text: String)
        case quote(String)
        case code(language: String?, text: String)
        case table(headers: [String], rows: [[String]])
        case rule
    }

    let blocks: [Block]

    static func containsPresentationalHTML(_ source: String) -> Bool {
        source.range(
            of: #"(?is)<(?:p|h[1-6]|picture|img)\b"#,
            options: .regularExpression
        ) != nil
    }

    static func parse(_ source: String) -> MarkdownDocument {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [Block] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " "), alignment: nil))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let html = htmlBlock(in: lines, at: index) {
                flushParagraph()
                if let block = html.block { blocks.append(block) }
                index = html.nextIndex
                continue
            }
            if index + 1 < lines.count,
               let level = setextHeadingLevel(lines[index + 1]) {
                flushParagraph()
                blocks.append(.heading(level: level, text: trimmed, alignment: nil))
                index += 2
                continue
            }
            if let image = markdownImage(trimmed) {
                flushParagraph()
                blocks.append(image)
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let languageToken = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(
                    language: languageToken.isEmpty ? nil : languageToken,
                    text: code.joined(separator: "\n")
                ))
                continue
            }
            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text, alignment: nil))
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if let item = listItem(in: line) {
                flushParagraph()
                index += 1
                var text = [item.text]
                while index < lines.count {
                    let continuation = lines[index]
                    let continuationTrimmed = continuation.trimmingCharacters(in: .whitespaces)
                    guard !continuationTrimmed.isEmpty,
                          listItem(in: continuation) == nil,
                          leadingWhitespaceWidth(in: continuation) >= (item.indent * 2) + 2 else {
                        break
                    }
                    text.append(continuationTrimmed)
                    index += 1
                }
                blocks.append(.listItem(
                    indent: item.indent,
                    marker: item.marker,
                    text: text.joined(separator: " ")
                ))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if index + 1 < lines.count,
               line.contains("|"),
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let headers = tableCells(line)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: Array(rows.prefix(100))))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return MarkdownDocument(blocks: blocks)
    }

    /// GitHub READMEs often use a small amount of presentational HTML for
    /// centered logos, headings, and link rows. Showing those tags verbatim is
    /// worse than ignoring their alignment, so translate the safe textual
    /// subset into the same native blocks used for Markdown. Common alignment
    /// and image dimensions are retained so a README logo does not expand into
    /// a full-width hero merely because it was authored with an HTML `<img>`.
    private static func htmlBlock(
        in lines: [String],
        at index: Int
    ) -> (block: Block?, nextIndex: Int)? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        for level in 1...6 where lower.hasPrefix("<h\(level)") {
            let closing = "</h\(level)>"
            let collected = collectHTML(lines: lines, from: index, closingTag: closing)
            let text = markdownFromHTML(collected.source)
            return (
                text.isEmpty ? nil : .heading(
                    level: level,
                    text: text,
                    alignment: alignmentFromHTML(collected.source)
                ),
                collected.nextIndex
            )
        }

        if lower.hasPrefix("<p") {
            let collected = collectHTML(lines: lines, from: index, closingTag: "</p>")
            let text = markdownFromHTML(collected.source)
            let alignment = alignmentFromHTML(collected.source)
            if !text.isEmpty {
                return (.paragraph(text, alignment: alignment), collected.nextIndex)
            }
            return (imageFromHTML(collected.source, inheritedAlignment: alignment), collected.nextIndex)
        }

        if lower.hasPrefix("<img") {
            return (imageFromHTML(trimmed, inheritedAlignment: nil), index + 1)
        }
        return nil
    }

    private static func imageFromHTML(
        _ html: String,
        inheritedAlignment: ContentAlignment?
    ) -> Block? {
        guard let expression = try? NSRegularExpression(
            pattern: #"<img\b[^>]*\bsrc=[\"']([^\"']+)[\"'][^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: full),
              let sourceRange = Range(match.range(at: 1), in: html) else { return nil }
        let source = String(html[sourceRange])
        let alt: String? = {
            guard let altExpression = try? NSRegularExpression(
                pattern: #"\balt=[\"']([^\"']*)[\"']"#,
                options: .caseInsensitive
            ),
            let altMatch = altExpression.firstMatch(in: html, range: full),
            let altRange = Range(altMatch.range(at: 1), in: html) else { return nil }
            let value = String(html[altRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }()
        return .image(
            source: source,
            alt: alt,
            declaredWidth: numericHTMLAttribute("width", in: html),
            declaredHeight: numericHTMLAttribute("height", in: html),
            alignment: inheritedAlignment ?? alignmentFromHTML(html)
        )
    }

    private static func numericHTMLAttribute(_ name: String, in html: String) -> Double? {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b\#(name)\s*=\s*(?:[\"']\s*)?([0-9]+(?:\.[0-9]+)?)(?:\s*[\"'])?"#,
            options: .caseInsensitive
        ) else { return nil }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: full),
              let valueRange = Range(match.range(at: 1), in: html),
              let value = Double(html[valueRange]),
              value.isFinite,
              value > 0 else { return nil }
        return min(value, 20_000)
    }

    private static func alignmentFromHTML(_ html: String) -> ContentAlignment? {
        guard let expression = try? NSRegularExpression(
            pattern: #"\balign\s*=\s*[\"']?(left|center|right)[\"']?"#,
            options: .caseInsensitive
        ) else { return nil }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: full),
              let valueRange = Range(match.range(at: 1), in: html) else { return nil }
        switch html[valueRange].lowercased() {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private static func collectHTML(
        lines: [String],
        from start: Int,
        closingTag: String
    ) -> (source: String, nextIndex: Int) {
        var fragments: [String] = []
        var cursor = start
        while cursor < lines.count {
            fragments.append(lines[cursor].trimmingCharacters(in: .whitespaces))
            cursor += 1
            if fragments.last?.lowercased().contains(closingTag) == true { break }
        }
        return (fragments.joined(separator: " "), cursor)
    }

    private static func markdownFromHTML(_ html: String) -> String {
        var value = html
        value = replacingHTML(value, pattern: #"<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#, with: "[$2]($1)")
        value = replacingHTML(value, pattern: #"<strong\b[^>]*>(.*?)</strong>"#, with: "**$1**")
        value = replacingHTML(value, pattern: #"<b\b[^>]*>(.*?)</b>"#, with: "**$1**")
        value = replacingHTML(value, pattern: #"<em\b[^>]*>(.*?)</em>"#, with: "*$1*")
        value = replacingHTML(value, pattern: #"<i\b[^>]*>(.*?)</i>"#, with: "*$1*")
        value = replacingHTML(value, pattern: #"<code\b[^>]*>(.*?)</code>"#, with: "`$1`")
        value = replacingHTML(value, pattern: #"<img\b[^>]*>"#, with: "")
        value = replacingHTML(value, pattern: #"<br\s*/?>"#, with: " ")
        value = replacingHTML(value, pattern: #"<[^>]+>"#, with: "")
        value = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        value = replacingHTML(value, pattern: #"\s+"#, with: " ")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingHTML(_ value: String, pattern: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func setextHeadingLevel(_ line: String) -> Int? {
        let compact = line.trimmingCharacters(in: .whitespaces)
        guard compact.count >= 3, let marker = compact.first,
              marker == "=" || marker == "-",
              compact.allSatisfy({ $0 == marker }) else { return nil }
        return marker == "=" ? 1 : 2
    }

    private static func markdownImage(_ line: String) -> Block? {
        guard let expression = try? NSRegularExpression(
            pattern: #"^!\[([^\]]*)\]\((<?[^\s>]+>?)(?:\s+[\"'][^\"']*[\"'])?\)$"#
        ) else { return nil }
        let full = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: full),
              let altRange = Range(match.range(at: 1), in: line),
              let sourceRange = Range(match.range(at: 2), in: line) else { return nil }
        let altValue = String(line[altRange]).trimmingCharacters(in: .whitespaces)
        let source = String(line[sourceRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !source.isEmpty else { return nil }
        return .image(
            source: source,
            alt: altValue.isEmpty ? nil : altValue,
            declaredWidth: nil,
            declaredHeight: nil,
            alignment: nil
        )
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(in line: String) -> (indent: Int, marker: String, text: String)? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leadingWhitespaceWidth(in: String(leading)) / 2
        let body = line.dropFirst(leading.count)
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return (indent, "•", String(body.dropFirst(2)))
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (indent, "\(digits).", String(body.dropFirst(digits.count + 2)))
    }

    private static func leadingWhitespaceWidth(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
    }

    private static func tableCells(_ line: String) -> [String] {
        MarkdownTableSource.values(in: line)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }
}

struct MarkdownTableSourceCell: Equatable, Sendable {
    let row: Int
    let column: Int
    let range: NSRange
    let text: String
}

/// Exact cell ranges for a GitHub-style Markdown table. Separator syntax and
/// cosmetic padding are not part of the editable range, so changing one cell
/// cannot reformat the table or normalize the document's line endings.
enum MarkdownTableSource {
    static func values(in line: String) -> [String] {
        localCellRanges(in: line).map { range in
            decodeCell((line as NSString).substring(with: range))
        }
    }

    static func cells(in block: MarkdownSourceBlock) -> [MarkdownTableSourceCell] {
        guard case .table = block.block else { return [] }
        let source = block.source as NSString
        var result: [MarkdownTableSourceCell] = []
        var lineLocation = 0
        var physicalRow = 0
        while lineLocation < source.length {
            let fullRange = source.lineRange(for: NSRange(location: lineLocation, length: 0))
            var contentEnd = NSMaxRange(fullRange)
            while contentEnd > fullRange.location {
                let character = source.character(at: contentEnd - 1)
                guard character == 0x0A || character == 0x0D else { break }
                contentEnd -= 1
            }
            let lineRange = NSRange(
                location: fullRange.location,
                length: contentEnd - fullRange.location
            )
            if physicalRow != 1 {
                let line = source.substring(with: lineRange)
                let logicalRow = physicalRow == 0 ? 0 : physicalRow - 1
                for (column, localRange) in localCellRanges(in: line).enumerated() {
                    result.append(MarkdownTableSourceCell(
                        row: logicalRow,
                        column: column,
                        range: NSRange(
                            location: block.range.location + lineRange.location + localRange.location,
                            length: localRange.length
                        ),
                        text: decodeCell((line as NSString).substring(with: localRange))
                    ))
                }
            }
            physicalRow += 1
            lineLocation = NSMaxRange(fullRange)
        }
        return result
    }

    static func replacingCell(
        row: Int,
        column: Int,
        in block: MarkdownSourceBlock,
        source: String,
        with replacement: String
    ) -> String? {
        guard let cell = cells(in: block).first(where: {
            $0.row == row && $0.column == column
        }) else { return nil }
        let normalized = replacement
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return MarkdownSourceDocument.replacing(
            cell.range,
            in: source,
            with: encodeCell(normalized)
        )
    }

    private static func localCellRanges(in line: String) -> [NSRange] {
        let value = line as NSString
        guard value.length > 0 else { return [] }
        var delimiters: [Int] = []
        var backslashes = 0
        for index in 0..<value.length {
            let character = value.character(at: index)
            if character == 0x5C {
                backslashes += 1
                continue
            }
            if character == 0x7C, backslashes.isMultiple(of: 2) {
                delimiters.append(index)
            }
            backslashes = 0
        }

        func isWhitespace(_ character: unichar) -> Bool {
            character == 0x20 || character == 0x09
        }
        var firstContent = 0
        while firstContent < value.length, isWhitespace(value.character(at: firstContent)) {
            firstContent += 1
        }
        var lastContent = value.length
        while lastContent > firstContent, isWhitespace(value.character(at: lastContent - 1)) {
            lastContent -= 1
        }
        let hasLeadingPipe = delimiters.first == firstContent
        let hasTrailingPipe = delimiters.last == lastContent - 1
        var separators = delimiters
        var cellStart = 0
        if hasLeadingPipe, let leading = separators.first {
            cellStart = leading + 1
            separators.removeFirst()
        }
        let cellEnd = hasTrailingPipe ? (separators.last ?? value.length) : value.length
        if hasTrailingPipe, !separators.isEmpty { separators.removeLast() }

        var ranges: [NSRange] = []
        for separator in separators + [cellEnd] {
            guard separator >= cellStart else { continue }
            var start = cellStart
            var end = separator
            while start < end, isWhitespace(value.character(at: start)) { start += 1 }
            while end > start, isWhitespace(value.character(at: end - 1)) { end -= 1 }
            ranges.append(NSRange(location: start, length: end - start))
            cellStart = separator + 1
        }
        return ranges
    }

    private static func decodeCell(_ source: String) -> String {
        var result = ""
        var escaped = false
        for character in source {
            if escaped {
                if character == "|" || character == "\\" { result.append(character) }
                else {
                    result.append("\\")
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func encodeCell(_ value: String) -> String {
        var result = ""
        for character in value {
            if character == "\\" || character == "|" { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// Exact UTF-16 source ranges paired with the structural blocks shown by the
/// native Markdown reader. A block editor replaces only this range in the
/// original string, so line endings, unsupported syntax, comments, and every
/// byte outside the active block remain untouched.
struct MarkdownSourceBlock: Equatable, Identifiable, Sendable {
    let range: NSRange
    let source: String
    let block: MarkdownDocument.Block

    var id: Int { range.location }
}

enum MarkdownSourceDocument {
    private struct Line {
        let text: String
        let contentRange: NSRange
    }

    static func blocks(in source: String) -> [MarkdownSourceBlock] {
        let nsSource = source as NSString
        let lines = sourceLines(in: nsSource)
        guard !lines.isEmpty else { return [] }
        var result: [MarkdownSourceBlock] = []
        var index = 0

        func append(_ start: Int, _ endExclusive: Int) {
            guard start < endExclusive else { return }
            let startLocation = lines[start].contentRange.location
            let endLocation = NSMaxRange(lines[endExclusive - 1].contentRange)
            guard endLocation >= startLocation else { return }
            let range = NSRange(location: startLocation, length: endLocation - startLocation)
            let fragment = nsSource.substring(with: range)
            let parsed = MarkdownDocument.parse(fragment).blocks
            let block = parsed.first ?? .paragraph(
                fragment.trimmingCharacters(in: .whitespacesAndNewlines),
                alignment: nil
            )
            result.append(MarkdownSourceBlock(range: range, source: fragment, block: block))
        }

        while index < lines.count {
            if isBlank(lines[index].text) {
                index += 1
                continue
            }
            let start = index
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)

            if let closing = htmlClosingTag(for: trimmed) {
                index += 1
                if !trimmed.lowercased().contains(closing) {
                    while index < lines.count {
                        let found = lines[index].text.lowercased().contains(closing)
                        index += 1
                        if found { break }
                    }
                }
                append(start, index)
                continue
            }
            if isFence(trimmed) {
                let fence = String(trimmed.prefix(3))
                index += 1
                while index < lines.count {
                    let closed = lines[index].text
                        .trimmingCharacters(in: .whitespaces)
                        .hasPrefix(fence)
                    index += 1
                    if closed { break }
                }
                append(start, index)
                continue
            }
            if index + 1 < lines.count, isSetextRule(lines[index + 1].text) {
                index += 2
                append(start, index)
                continue
            }
            if index + 1 < lines.count,
               lines[index].text.contains("|"),
               isTableSeparator(lines[index + 1].text) {
                index += 2
                while index < lines.count,
                      !isBlank(lines[index].text),
                      lines[index].text.contains("|") {
                    index += 1
                }
                append(start, index)
                continue
            }
            if trimmed.hasPrefix(">") {
                index += 1
                while index < lines.count,
                      lines[index].text.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    index += 1
                }
                append(start, index)
                continue
            }
            if let listIndent = listItemIndent(lines[index].text) {
                index += 1
                while index < lines.count {
                    let candidate = lines[index].text
                    guard !isBlank(candidate),
                          listItemIndent(candidate) == nil,
                          leadingWhitespaceWidth(in: candidate) >= listIndent + 2 else {
                        break
                    }
                    index += 1
                }
                append(start, index)
                continue
            }
            if isSingleLineBlock(trimmed) {
                index += 1
                append(start, index)
                continue
            }

            index += 1
            while index < lines.count,
                  !isBlank(lines[index].text),
                  !startsStructuralBlock(lines: lines, at: index) {
                index += 1
            }
            append(start, index)
        }
        return result
    }

    static func replacing(_ range: NSRange, in source: String, with replacement: String) -> String? {
        let nsSource = source as NSString
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= nsSource.length else { return nil }
        return nsSource.replacingCharacters(in: range, with: replacement)
    }

    private static func sourceLines(in source: NSString) -> [Line] {
        guard source.length > 0 else { return [] }
        var result: [Line] = []
        var location = 0
        while location < source.length {
            let full = source.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(full)
            while contentEnd > full.location {
                let value = source.character(at: contentEnd - 1)
                guard value == 0x0A || value == 0x0D else { break }
                contentEnd -= 1
            }
            let contentRange = NSRange(
                location: full.location,
                length: contentEnd - full.location
            )
            result.append(Line(
                text: source.substring(with: contentRange),
                contentRange: contentRange
            ))
            location = NSMaxRange(full)
        }
        return result
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func htmlClosingTag(for trimmed: String) -> String? {
        let lower = trimmed.lowercased()
        for level in 1...6 where lower.hasPrefix("<h\(level)") {
            return "</h\(level)>"
        }
        return lower.hasPrefix("<p") ? "</p>" : nil
    }

    private static func startsStructuralBlock(lines: [Line], at index: Int) -> Bool {
        let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
        if htmlClosingTag(for: trimmed) != nil || isFence(trimmed)
            || isSingleLineBlock(trimmed) || trimmed.hasPrefix(">") {
            return true
        }
        if index + 1 < lines.count, isSetextRule(lines[index + 1].text) { return true }
        return index + 1 < lines.count
            && lines[index].text.contains("|")
            && isTableSeparator(lines[index + 1].text)
    }

    private static func isSingleLineBlock(_ trimmed: String) -> Bool {
        if trimmed.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"^!\[[^\]]*\]\("#, options: .regularExpression) != nil { return true }
        if trimmed.lowercased().hasPrefix("<img") { return true }
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func listItemIndent(_ line: String) -> Int? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(leading.count)
        let isBullet = ["- ", "* ", "+ "].contains { body.hasPrefix($0) }
        let digits = body.prefix { $0.isNumber }
        let isOrdered = !digits.isEmpty && body.dropFirst(digits.count).hasPrefix(". ")
        return isBullet || isOrdered ? leadingWhitespaceWidth(in: line) : nil
    }

    private static func leadingWhitespaceWidth(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
    }

    private static func isSetextRule(_ line: String) -> Bool {
        let compact = line.trimmingCharacters(in: .whitespaces)
        guard compact.count >= 3, let marker = compact.first,
              marker == "=" || marker == "-" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        let cells = value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }
}

/// A view-lifetime cache for the exact structural projection. SwiftUI can
/// recompute `body` many times during a pinch or panel resize; reparsing the
/// same large Markdown string on every frame turns an otherwise linear parser
/// into visible interaction jank.
final class MarkdownSourceBlockCache {
    private var source: String?
    private var cachedBlocks: [MarkdownSourceBlock] = []
    private(set) var parseCount = 0

    func blocks(for source: String) -> [MarkdownSourceBlock] {
        guard self.source != source else { return cachedBlocks }
        self.source = source
        cachedBlocks = MarkdownSourceDocument.blocks(in: source)
        parseCount += 1
        return cachedBlocks
    }
}

/// Responsive measurements shared by the rendered Markdown surface and its
/// tests. The document keeps a comfortable reading measure on a wide canvas,
/// but yields every point needed by a narrow split instead of creating a
/// hidden horizontal overflow. HTML image dimensions are treated as preferred
/// sizes, then scaled down to the live content width while preserving aspect.
enum MarkdownPreviewLayout {
    static let maximumReadableWidth: CGFloat = 760
    static let minimumZoom: CGFloat = 0.65
    static let maximumZoom: CGFloat = 2

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, zoom))
    }

    static func magnifiedZoom(start: CGFloat, gestureScale: CGFloat) -> CGFloat {
        clampedZoom(start * gestureScale)
    }

    static func horizontalInset(viewportWidth: CGFloat) -> CGFloat {
        switch viewportWidth {
        case ..<360: 12
        case ..<560: 18
        default: 28
        }
    }

    static func contentWidth(viewportWidth: CGFloat) -> CGFloat {
        let viewport = max(1, viewportWidth)
        let inset = horizontalInset(viewportWidth: viewport)
        return max(1, min(maximumReadableWidth, viewport - inset * 2))
    }

    static func imageSize(
        intrinsicSize: CGSize,
        declaredWidth: Double?,
        declaredHeight: Double?,
        availableWidth: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        let intrinsicWidth = max(1, intrinsicSize.width)
        let intrinsicHeight = max(1, intrinsicSize.height)
        let safeZoom = max(0.01, zoom)
        let preferredWidth: CGFloat
        let aspectRatio: CGFloat

        if let declaredWidth, let declaredHeight {
            preferredWidth = CGFloat(declaredWidth) * safeZoom
            aspectRatio = CGFloat(declaredHeight / declaredWidth)
        } else if let declaredWidth {
            preferredWidth = CGFloat(declaredWidth) * safeZoom
            aspectRatio = intrinsicHeight / intrinsicWidth
        } else if let declaredHeight {
            aspectRatio = intrinsicHeight / intrinsicWidth
            preferredWidth = CGFloat(declaredHeight) * safeZoom / aspectRatio
        } else {
            preferredWidth = intrinsicWidth * safeZoom
            aspectRatio = intrinsicHeight / intrinsicWidth
        }

        let width = max(1, min(max(1, availableWidth), preferredWidth))
        return CGSize(width: width, height: max(1, width * aspectRatio))
    }
}

/// Presentation-only typography for rendered inline Markdown. Source remains
/// byte-for-byte untouched; this merely prevents separator punctuation from
/// becoming the first glyph on a wrapped line in narrow document panes.
enum MarkdownInlinePresentation {
    static func preventingOrphanedSeparators(_ source: String) -> String {
        source.replacingOccurrences(of: " · ", with: "\u{00A0}· ")
    }
}

enum MarkdownTableNavigation {
    enum Direction { case left, right, up, down }

    struct Position: Equatable {
        let row: Int
        let column: Int
    }

    static func destination(
        from position: Position,
        direction: Direction,
        rows: [[String]]
    ) -> Position? {
        guard rows.indices.contains(position.row),
              rows[position.row].indices.contains(position.column) else { return nil }
        let candidate: Position
        switch direction {
        case .left:
            candidate = Position(row: position.row, column: position.column - 1)
        case .right:
            candidate = Position(row: position.row, column: position.column + 1)
        case .up:
            candidate = Position(row: position.row - 1, column: position.column)
        case .down:
            candidate = Position(row: position.row + 1, column: position.column)
        }
        guard rows.indices.contains(candidate.row),
              rows[candidate.row].indices.contains(candidate.column) else { return nil }
        return candidate
    }
}

private struct MarkdownTableCellID: Hashable {
    let blockLocation: Int
    let row: Int
    let column: Int
}

private struct MarkdownDocumentView: View {
    @Binding var source: String
    let documentURL: URL
    let workspaceRoot: URL?
    @Binding var zoom: CGFloat
    let onError: (String) -> Void
    let automaticallyEditFirstBlock: Bool
    let automaticallyEditFirstTableCell: Bool
    @State private var pinchStartZoom: CGFloat?
    @State private var activeEdit: ActiveEdit?
    @State private var activeTableCell: (id: MarkdownTableCellID, text: String)?
    @State private var hoveredBlockID: Int?
    @State private var appliedAutomaticEdit = false
    @State private var blockCache = MarkdownSourceBlockCache()

    private struct ActiveEdit {
        var range: NSRange
        var text: String
        var before: [MarkdownSourceBlock]
        var after: [MarkdownSourceBlock]
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = MarkdownPreviewLayout.contentWidth(
                viewportWidth: geometry.size.width
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let activeEdit {
                        sourceBlocks(activeEdit.before, availableWidth: contentWidth)
                        activeEditor(activeEdit, availableWidth: contentWidth)
                        sourceBlocks(activeEdit.after, availableWidth: contentWidth)
                    } else {
                        let blocks = blockCache.blocks(for: source)
                        if blocks.isEmpty {
                            Button {
                                beginEditingEmptyDocument()
                            } label: {
                                ContentUnavailableView(
                                    "Empty Markdown document",
                                    systemImage: "text.badge.plus",
                                    description: Text("Click to start writing in place.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 220)
                            }
                            .buttonStyle(.plain)
                        } else {
                            sourceBlocks(blocks, availableWidth: contentWidth)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .frame(width: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            MarkdownCommandScrollZoomBridge(zoom: $zoom)
        }
        .onAppear { beginAutomaticEditIfReady() }
        .onChange(of: source) { _, _ in beginAutomaticEditIfReady() }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    let start = pinchStartZoom ?? zoom
                    if pinchStartZoom == nil { pinchStartZoom = zoom }
                    zoom = MarkdownPreviewLayout.magnifiedZoom(
                        start: start,
                        gestureScale: scale
                    )
                }
                .onEnded { scale in
                    zoom = MarkdownPreviewLayout.magnifiedZoom(
                        start: pinchStartZoom ?? zoom,
                        gestureScale: scale
                    )
                    pinchStartZoom = nil
                }
        )
    }

    @ViewBuilder
    private func sourceBlocks(
        _ blocks: [MarkdownSourceBlock],
        availableWidth: CGFloat
    ) -> some View {
        let renderedBlocks = blocks.map(\.block)
        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, sourceBlock in
            let renderedBlock = ZStack(alignment: .topTrailing) {
                blockView(sourceBlock, availableWidth: availableWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hoveredBlockID == sourceBlock.id {
                    Button {
                        beginEditing(sourceBlock)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 25, height: 23)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("Edit this block in place")
                }
            }

            if case .table = sourceBlock.block {
                interactiveTableBlock(
                    renderedBlock.accessibilityElement(children: .contain),
                    sourceBlock: sourceBlock,
                    index: index,
                    renderedBlocks: renderedBlocks
                )
            } else {
                interactiveBlock(
                    renderedBlock
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine),
                    sourceBlock: sourceBlock,
                    index: index,
                    renderedBlocks: renderedBlocks
                )
            }
        }
    }

    private func interactiveBlock<Content: View>(
        _ content: Content,
        sourceBlock: MarkdownSourceBlock,
        index: Int,
        renderedBlocks: [MarkdownDocument.Block]
    ) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hoveredBlockID = sourceBlock.id }
                else if hoveredBlockID == sourceBlock.id { hoveredBlockID = nil }
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    // Tables own double-click at cell granularity. The hover
                    // pencil remains available for exact whole-block source.
                    if case .table = sourceBlock.block { return }
                    beginEditing(sourceBlock)
                }
            )
            .focusable()
            .onKeyPress(.return) {
                beginEditing(sourceBlock)
                return .handled
            }
            .accessibilityAction(named: "Edit Markdown source") {
                beginEditing(sourceBlock)
            }
            .accessibilityHint("Press Return to edit this block's exact Markdown source")
            .help("Double-click, focus and press Return, or use the pencil to edit this block in place")
            .padding(.bottom, spacing(after: index, in: renderedBlocks))
    }

    private func interactiveTableBlock<Content: View>(
        _ content: Content,
        sourceBlock: MarkdownSourceBlock,
        index: Int,
        renderedBlocks: [MarkdownDocument.Block]
    ) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hoveredBlockID = sourceBlock.id }
                else if hoveredBlockID == sourceBlock.id { hoveredBlockID = nil }
            }
            // Individual table cells own Return and arrow-key handling. A
            // focusable whole-table Return handler receives the bubbled key
            // first on macOS and incorrectly opens raw block source instead.
            .accessibilityAction(named: "Edit Markdown source") {
                beginEditing(sourceBlock)
            }
            .accessibilityHint("Navigate individual cells to edit them, or use this action to edit exact table source")
            .help("Double-click a cell to edit it, or use the pencil to edit exact table source")
            .padding(.bottom, spacing(after: index, in: renderedBlocks))
    }

    private func activeEditor(
        _ edit: ActiveEdit,
        availableWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "pencil.line")
                    .foregroundStyle(.tint)
                Text("Editing this Markdown block directly")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("Done") { activeEdit = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            MarkdownRenderedEditor(
                text: activeTextBinding,
                markdownURL: documentURL,
                workspaceRoot: workspaceRoot,
                zoom: $zoom,
                targetLine: nil,
                onError: onError
            )
            .frame(width: availableWidth)
            .frame(
                minHeight: editorHeight(for: edit.text),
                maxHeight: min(420, editorHeight(for: edit.text))
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.48), lineWidth: 1)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .padding(.bottom, 16 * zoom)
    }

    private var activeTextBinding: Binding<String> {
        Binding(
            get: { activeEdit?.text ?? "" },
            set: { replacement in updateActiveText(replacement) }
        )
    }

    private var activeTableTextBinding: Binding<String> {
        Binding(
            get: { activeTableCell?.text ?? "" },
            set: { replacement in
                guard var edit = activeTableCell else { return }
                edit.text = replacement
                activeTableCell = edit
            }
        )
    }

    private func beginEditing(_ block: MarkdownSourceBlock) {
        let blocks = MarkdownSourceDocument.blocks(in: source)
        guard let exact = blocks.first(where: { $0.range == block.range })
            ?? blocks.first(where: { $0.range.location == block.range.location }) else { return }
        activeTableCell = nil
        activeEdit = ActiveEdit(
            range: exact.range,
            text: exact.source,
            before: blocks.filter { NSMaxRange($0.range) <= exact.range.location },
            after: blocks.filter { $0.range.location >= NSMaxRange(exact.range) }
        )
        hoveredBlockID = nil
    }

    private func beginEditingEmptyDocument() {
        activeTableCell = nil
        activeEdit = ActiveEdit(
            range: NSRange(location: 0, length: 0),
            text: "",
            before: [],
            after: []
        )
    }

    private func beginAutomaticEditIfReady() {
        guard !appliedAutomaticEdit else { return }
        let blocks = MarkdownSourceDocument.blocks(in: source)
        let tableAndCell: (MarkdownSourceBlock, MarkdownTableSourceCell)? = blocks
            .compactMap { block -> (MarkdownSourceBlock, MarkdownTableSourceCell)? in
                guard case .table = block.block else { return nil }
                let cells = MarkdownTableSource.cells(in: block)
                let cell = cells.first(where: { $0.row == 1 && $0.column == 1 })
                    ?? cells.first(where: { $0.row > 0 })
                return cell.map { (block, $0) }
            }
            .first
        if automaticallyEditFirstTableCell,
           let (table, cell) = tableAndCell {
            appliedAutomaticEdit = true
            beginEditingTableCell(
                blockLocation: table.range.location,
                row: cell.row,
                column: cell.column,
                text: cell.text
            )
            return
        }
        guard automaticallyEditFirstBlock, let first = blocks.first else { return }
        appliedAutomaticEdit = true
        beginEditing(first)
    }

    private func updateActiveText(_ replacement: String) {
        guard var edit = activeEdit,
              let updatedSource = MarkdownSourceDocument.replacing(
                edit.range,
                in: source,
                with: replacement
              ) else { return }
        let delta = replacement.utf16.count - edit.range.length
        edit.range.length = replacement.utf16.count
        edit.text = replacement
        if delta != 0 {
            edit.after = edit.after.map { block in
                MarkdownSourceBlock(
                    range: NSRange(
                        location: block.range.location + delta,
                        length: block.range.length
                    ),
                    source: block.source,
                    block: block.block
                )
            }
        }
        activeEdit = edit
        source = updatedSource
    }

    private func beginEditingTableCell(
        blockLocation: Int,
        row: Int,
        column: Int,
        text: String
    ) {
        activeEdit = nil
        activeTableCell = (
            MarkdownTableCellID(
                blockLocation: blockLocation,
                row: row,
                column: column
            ),
            text
        )
    }

    private func commitTableCellEdit() {
        guard let edit = activeTableCell else { return }
        let blocks = MarkdownSourceDocument.blocks(in: source)
        guard let block = blocks.first(where: { block in
            guard block.range.location == edit.id.blockLocation else { return false }
            if case .table = block.block { return true }
            return false
        }), let updatedSource = MarkdownTableSource.replacingCell(
            row: edit.id.row,
            column: edit.id.column,
            in: block,
            source: source,
            with: edit.text
        ) else {
            activeTableCell = nil
            return
        }
        activeTableCell = nil
        source = updatedSource
    }

    private func editorHeight(for text: String) -> CGFloat {
        let lines = max(1, text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })
        return min(420, max(76, CGFloat(lines) * max(18, 19 * zoom) + 28))
    }

    @ViewBuilder
    private func blockView(
        _ sourceBlock: MarkdownSourceBlock,
        availableWidth: CGFloat
    ) -> some View {
        switch sourceBlock.block {
        case let .heading(level, text, alignment):
            VStack(alignment: .leading, spacing: 7 * zoom) {
                Text(inline(text))
                    .font(headingFont(level))
                    .multilineTextAlignment(textAlignment(alignment))
                    .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
                if level <= 2 {
                    Divider()
                }
            }
            .padding(.top, level <= 2 ? 8 : 2)
        case let .paragraph(text, alignment):
            Text(inline(text))
                .font(.system(size: 14 * zoom))
                .lineSpacing(4 * zoom)
                .multilineTextAlignment(textAlignment(alignment))
                .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
        case let .image(source, alt, declaredWidth, declaredHeight, alignment):
            if let image = localImage(source: source) {
                let renderedSize = MarkdownPreviewLayout.imageSize(
                    intrinsicSize: image.size,
                    declaredWidth: declaredWidth,
                    declaredHeight: declaredHeight,
                    availableWidth: availableWidth,
                    zoom: zoom
                )
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: renderedSize.width, height: renderedSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12 * zoom, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
                    .accessibilityLabel(alt ?? "Markdown image")
            } else if let alt {
                Label(alt, systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
            }
        case let .listItem(indent, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(marker)
                    .font(.system(size: 14 * zoom, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inline(text)).font(.system(size: 14 * zoom)).lineSpacing(3 * zoom)
            }
            .padding(.leading, CGFloat(indent) * 20 * zoom)
        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: 3)
                Text(inline(text))
                    .font(.system(size: 14 * zoom))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
            .padding(.vertical, 4)
        case let .code(language, text):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: text)
                        .font(.system(size: 13 * zoom, design: .monospaced))
                        .lineSpacing(3 * zoom)
                        .padding(12 * zoom)
                }
            }
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        case let .table(headers, rows):
            MarkdownTable(
                headers: headers,
                rows: rows,
                zoom: zoom,
                blockLocation: sourceBlock.range.location,
                activeCell: activeTableCell?.id,
                activeText: activeTableTextBinding,
                onBeginEdit: { row, column, text in
                    beginEditingTableCell(
                        blockLocation: sourceBlock.range.location,
                        row: row,
                        column: column,
                        text: text
                    )
                },
                onCommit: commitTableCellEdit,
                onCancel: { activeTableCell = nil }
            )
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func spacing(after index: Int, in blocks: [MarkdownDocument.Block]) -> CGFloat {
        guard index + 1 < blocks.count else { return 0 }
        let current = blocks[index]
        let next = blocks[index + 1]
        if case .listItem = current, case .listItem = next { return 5 * zoom }
        if case .heading = current { return 10 * zoom }
        if case .heading = next { return 20 * zoom }
        return 16 * zoom
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: MarkdownInlinePresentation.preventingOrphanedSeparators(text),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 30 * zoom, weight: .bold)
        case 2: .system(size: 24 * zoom, weight: .bold)
        case 3: .system(size: 20 * zoom, weight: .semibold)
        case 4: .system(size: 17 * zoom, weight: .semibold)
        default: .system(size: 15 * zoom, weight: .semibold)
        }
    }

    private func textAlignment(_ alignment: MarkdownDocument.ContentAlignment?) -> TextAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    private func frameAlignment(_ alignment: MarkdownDocument.ContentAlignment?) -> Alignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    /// Resolve only local descendants of the open workspace/document folder.
    /// Remote HTML image sources remain inert in the native Markdown reader.
    private func localImage(source: String) -> NSImage? {
        guard !source.contains("://"), !source.hasPrefix("data:") else { return nil }
        let decoded = source.removingPercentEncoding ?? source
        let base = documentURL.deletingLastPathComponent().standardizedFileURL
        let candidate = URL(fileURLWithPath: decoded, relativeTo: base)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let boundary = (workspaceRoot ?? base).standardizedFileURL.resolvingSymlinksInPath()
        let boundaryPath = boundary.path.hasSuffix("/") ? boundary.path : boundary.path + "/"
        guard candidate.path == boundary.path || candidate.path.hasPrefix(boundaryPath) else { return nil }
        return NSImage(contentsOf: candidate)
    }
}

private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]
    let zoom: CGFloat
    let blockLocation: Int
    let activeCell: MarkdownTableCellID?
    @Binding var activeText: String
    let onBeginEdit: (_ row: Int, _ column: Int, _ text: String) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedCell: MarkdownTableCellID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { cells(headers, row: 0, header: true) }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow { cells(row, row: index + 1, header: false) }
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                }
            }
            .accessibilityElement(children: .contain)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func cells(_ values: [String], row: Int, header: Bool) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { column, value in
            let id = MarkdownTableCellID(
                blockLocation: blockLocation,
                row: row,
                column: column
            )
            Group {
                if activeCell == id {
                    TextField("Cell", text: $activeText)
                        .textFieldStyle(.plain)
                        .focused($focusedCell, equals: id)
                        .onSubmit(onCommit)
                        .onExitCommand(perform: onCancel)
                        .onAppear {
                            DispatchQueue.main.async { focusedCell = id }
                        }
                        .onChange(of: focusedCell) { oldValue, newValue in
                            if oldValue == id, newValue != id { onCommit() }
                        }
                        .accessibilityLabel("Editing table cell")
                } else {
                    Button {
                        onBeginEdit(row, column, value)
                    } label: {
                        Text(inline(value))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .focused($focusedCell, equals: id)
                        .onKeyPress(.leftArrow) {
                            moveFocus(from: id, direction: .left)
                        }
                        .onKeyPress(.rightArrow) {
                            moveFocus(from: id, direction: .right)
                        }
                        .onKeyPress(.upArrow) {
                            moveFocus(from: id, direction: .up)
                        }
                        .onKeyPress(.downArrow) {
                            moveFocus(from: id, direction: .down)
                        }
                        .help("Click or focus and press Return to edit this table cell")
                        .accessibilityLabel(
                            "\(header ? "Header" : "Row \(row)") column \(column + 1): \(value)"
                        )
                        .accessibilityHint("Press Return to edit; use arrow keys to move between cells")
                        .accessibilityAction(named: "Edit table cell") {
                            onBeginEdit(row, column, value)
                        }
                }
            }
                .font(.system(size: 13 * zoom, weight: header ? .semibold : .regular))
                .frame(minWidth: 100 * zoom, maxWidth: 280 * zoom, alignment: .leading)
                .padding(.horizontal, 10 * zoom)
                .padding(.vertical, 8 * zoom)
                .background(
                    activeCell == id
                        ? Color.accentColor.opacity(0.12)
                        : (header ? Color.primary.opacity(0.07) : .clear)
                )
                .overlay {
                    ZStack(alignment: .trailing) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.55))
                            .frame(width: 1)
                        if activeCell == id {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: 1.5)
                                .padding(2)
                        }
                    }
                }
        }
    }

    private func moveFocus(
        from id: MarkdownTableCellID,
        direction: MarkdownTableNavigation.Direction
    ) -> KeyPress.Result {
        let matrix = [headers] + rows
        guard let destination = MarkdownTableNavigation.destination(
            from: .init(row: id.row, column: id.column),
            direction: direction,
            rows: matrix
        ) else { return .ignored }
        focusedCell = MarkdownTableCellID(
            blockLocation: blockLocation,
            row: destination.row,
            column: destination.column
        )
        return .handled
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: MarkdownInlinePresentation.preventingOrphanedSeparators(text),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
