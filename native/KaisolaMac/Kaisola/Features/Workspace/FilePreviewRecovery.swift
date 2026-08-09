import AppKit
import CryptoKit
import Darwin
import Foundation

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

/// A claim the store refused to complete. Storage and ownership failures used
/// to be swallowed at the load site, so a draft that was still on disk simply
/// never appeared and the user had nothing to diagnose or retry.
struct FilePreviewRecoveryClaimFailure: Equatable, Sendable {
    /// Set whenever the store itself rejected the claim. Foundation failures
    /// (an unwritable directory, an interrupted rename) leave this `nil` and are
    /// still described by `message`.
    let reason: FilePreviewRecoveryStore.RecoveryError?
    let message: String

    init(_ error: Error) {
        let typed = error as? FilePreviewRecoveryStore.RecoveryError
        reason = typed
        message = typed?.errorDescription ?? error.localizedDescription
    }
}

/// The typed result of the claim a preview attempts while it loads. "No draft
/// was journaled" and "the journal could not be read" are different answers and
/// the view renders a different surface for each.
enum FilePreviewRecoveryClaimOutcome: Equatable, Sendable {
    case claimed(FilePreviewRecoveryClaim)
    case noDraft
    case failed(FilePreviewRecoveryClaimFailure)

    var claim: FilePreviewRecoveryClaim? {
        guard case let .claimed(claim) = self else { return nil }
        return claim
    }

    var failure: FilePreviewRecoveryClaimFailure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }
}

/// Pure policy for the failed-claim banner.
enum FilePreviewRecoveryFailurePolicy {
    /// A file the journal never covers can hold no record, so that refusal is
    /// the ordinary "recovery does not apply here" that every file opened
    /// without a project root reports. Every other failure hides a draft that is
    /// still on disk and is worth a banner.
    static func shouldSurface(_ failure: FilePreviewRecoveryClaimFailure) -> Bool {
        failure.reason != .outsideWorkspace
    }

    /// Retry re-runs the whole load, so it waits until this editor has nothing
    /// of its own to lose. Inspect and discard never read or replace the open
    /// draft and stay available throughout.
    static func canRetry(isDirty: Bool, isLoading: Bool, isSaving: Bool) -> Bool {
        !isDirty && !isLoading && !isSaving
    }
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
            let records = recordsPrepared(for: paths)
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
                let records = recordsPrepared(for: paths)
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

    /// Claims without throwing and keeps the exact failure. Preview loading has
    /// to tell "nothing was journaled" apart from "the journal could not be
    /// read": only the second one hides a draft that is still on disk.
    func claimOutcome(
        for fileURL: URL,
        workspaceRoot: URL?,
        claimantID: String,
        ownerRegistry: FilePreviewRecoveryOwnerRegistry = .shared
    ) -> FilePreviewRecoveryClaimOutcome {
        do {
            guard let claim = try claimNewestOrphan(
                for: fileURL,
                workspaceRoot: workspaceRoot,
                claimantID: claimantID,
                ownerRegistry: ownerRegistry
            ) else { return .noDraft }
            return .claimed(claim)
        } catch {
            return .failed(FilePreviewRecoveryClaimFailure(error))
        }
    }

    /// The journal file behind the newest draft this window could restore, for
    /// the inspect action. Strictly read-only: a draft the user is still
    /// deciding about must survive being looked at.
    func newestOrphanRecordURL(
        for fileURL: URL,
        workspaceRoot: URL?,
        ownerRegistry: FilePreviewRecoveryOwnerRegistry = .shared
    ) -> URL? {
        guard let paths = try? canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot) else { return nil }
        return ownerRegistry.withActiveOwnerIDs { activeOwnerIDs in
            withMutationLock { () -> URL? in
                guard let record = FilePreviewRecoveryViewPolicy.newestRestorable(
                    in: recordsPrepared(for: paths),
                    activeOwnerIDs: activeOwnerIDs
                ) else { return nil }
                return recordURL(
                    filePath: record.filePath,
                    workspacePath: record.workspacePath,
                    ownerID: record.ownerID
                )
            }
        }
    }

    /// Explicit discard of the drafts a window could not claim. Only restorable
    /// records for this exact project/file pair are unlinked; tombstones, other
    /// files, and anything owned or claimed by a live window stay, so answering
    /// one failed claim can never overwrite the rest of the journal.
    @discardableResult
    func discardOrphans(
        for fileURL: URL,
        workspaceRoot: URL?,
        ownerRegistry: FilePreviewRecoveryOwnerRegistry = .shared
    ) throws -> Int {
        let paths = try canonicalPaths(fileURL: fileURL, workspaceRoot: workspaceRoot)
        return try ownerRegistry.withActiveOwnerIDs { activeOwnerIDs in
            try withMutationLock { () -> Int in
                try prepareDirectory()
                let records = recordsPrepared(for: paths)
                let discardable = records.filter { record in
                    record.kind != .tombstone
                        && !activeOwnerIDs.contains(record.ownerID)
                        && Self.claimedRecords[claimKey(paths: paths, token: record.token)] == nil
                }
                var removed = 0
                for record in discardable {
                    let url = recordURL(
                        filePath: record.filePath,
                        workspacePath: record.workspacePath,
                        ownerID: record.ownerID
                    )
                    guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
                    removed += 1
                }
                if removed > 0 { synchronizeDirectory() }
                return removed
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

    /// Every stored record for one canonical project/file pair. Callers already
    /// hold `mutationLock` and, except for read-only lookups, have prepared the
    /// directory.
    private func recordsPrepared(
        for paths: (file: String, workspace: String)
    ) -> [FilePreviewRecoveryRecord] {
        recoveryRecordURLs().compactMap { url -> FilePreviewRecoveryRecord? in
            guard let record = readRecord(at: url),
                  record.filePath == paths.file,
                  record.workspacePath == paths.workspace else { return nil }
            return record
        }
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

struct FilePreviewSnapshot: Sendable {
    let content: FilePreviewContent
    let modificationDate: Date?
    /// The typed recovery result travels with the loaded content. Flattening a
    /// failed claim into "no draft" here is what made a recoverable draft vanish
    /// with nothing for the user to act on.
    let recoveryOutcome: FilePreviewRecoveryClaimOutcome

    var recoveryClaim: FilePreviewRecoveryClaim? { recoveryOutcome.claim }
    var recoveryFailure: FilePreviewRecoveryClaimFailure? { recoveryOutcome.failure }
}

enum FilePreviewRecoveryWorkResult: Sendable {
    case saved(FilePreviewRecoveryToken)
    case failed(message: String, payloadTooLarge: Bool)
}

enum FilePreviewRecoveryWork {
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
