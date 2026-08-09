import CryptoKit
import Darwin
import Foundation

/// One resolved, pinned ACP adapter install — the durable form of a user's
/// approval (adversarial review, finding 2: `npx <pkg>@latest` is mutable
/// code, so approving it approves nothing in particular).
///
/// The record freezes what the approval meant: the package as typed, the
/// version npm resolved it to, a SHA-256 over the lockfile that pins the
/// complete dependency graph, the executable's path inside the install, and
/// the exact credential/containment grant the user reviewed.
/// At spawn time `AdapterInstallManager.verify` recomputes the hash; any
/// drift — an edited lockfile, a swapped binary, a vanished install — refuses
/// the chat surface until the user approves again.
struct InstalledAdapterRecord: Codable, Equatable, Identifiable, Sendable {
    let agentID: String
    let package: String
    let resolvedVersion: String
    /// Relative to the agent's install root.
    let binRelativePath: String
    let lockfileSHA256: String
    /// A digest over the *installed code itself* — every file under the
    /// install, path and content. Symlinks, hard links, and special nodes are
    /// rejected before this is recorded. The lockfile pins what npm resolved;
    /// this pins what actually sits on disk, so editing `cli.js` or any
    /// dependency file after approval reads as drift.
    let treeSHA256: String
    /// Nil only for records written before containment approval shipped (or
    /// tests that exercise installation independently of custom-agent launch).
    /// A custom adapter resolver always supplies an expected approval, so a
    /// legacy nil record cannot launch.
    let approval: CustomAdapterApproval?
    let installedAt: Date

    var id: String { agentID }

    init(
        agentID: String,
        package: String,
        resolvedVersion: String,
        binRelativePath: String,
        lockfileSHA256: String,
        treeSHA256: String,
        approval: CustomAdapterApproval? = nil,
        installedAt: Date
    ) {
        self.agentID = agentID
        self.package = package
        self.resolvedVersion = resolvedVersion
        self.binRelativePath = binRelativePath
        self.lockfileSHA256 = lockfileSHA256
        self.treeSHA256 = treeSHA256
        self.approval = approval
        self.installedAt = installedAt
    }
}

/// Installs, verifies, and records custom-agent ACP adapters.
///
/// Install layout: `<application support>/acp-adapters/<agentID>/` holding a
/// plain npm prefix (`node_modules`, `package-lock.json`). Installation runs
/// with **scripts disabled** — a lifecycle script executing during
/// enablement would be arbitrary code before the user's approval finished
/// meaning anything. Runtime launch is a separate fail-closed step: a verified
/// install must also carry the current `CustomAdapterApproval` before it can
/// enter the Seatbelt boundary.
struct AdapterInstallManager: Sendable {
    struct Store: Sendable {
        let fileURL: URL

        init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("acp-adapter-installs.json", isDirectory: false)) {
            self.fileURL = fileURL
        }

        private struct Payload: Codable {
            var installs: [InstalledAdapterRecord]
        }

        func records() -> [InstalledAdapterRecord] {
            guard let data = try? AdapterInstallManager.readRegularFile(at: fileURL),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
            return payload.installs
        }

        func record(agentID: String) -> InstalledAdapterRecord? {
            records().first { $0.agentID == agentID }
        }

        func upsert(_ record: InstalledAdapterRecord) throws {
            var current = records().filter { $0.agentID != record.agentID }
            current.append(record)
            try write(Payload(installs: current))
        }

        @discardableResult
        func remove(agentID: String) throws -> Bool {
            let current = records()
            let remaining = current.filter { $0.agentID != agentID }
            guard remaining.count != current.count else { return false }
            try write(Payload(installs: remaining))
            return true
        }

        private func write(_ payload: Payload) throws {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(payload)
            let temporary = directory.appendingPathComponent(
                ".\(fileURL.lastPathComponent).\(UUID().uuidString)"
            )
            do {
                try data.write(to: temporary, options: [.withoutOverwriting])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                var target = stat()
                if lstat(fileURL.path, &target) == 0 {
                    guard target.st_uid == getuid(),
                          target.st_mode & S_IFMT == S_IFREG,
                          target.st_nlink == 1 else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
                } else if errno == ENOENT {
                    try FileManager.default.moveItem(at: temporary, to: fileURL)
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }

    enum VerifyResult: Equatable {
        case verified(binURL: URL, record: InstalledAdapterRecord)
        /// The named reason feeds the settings row and the refusal toast.
        case drifted(reason: String)
        case notInstalled
    }

    enum InstallError: LocalizedError, Equatable {
        case invalidPackage(String)
        case installFailed(String)
        case unresolvable(String)

        var errorDescription: String? {
            switch self {
            case let .invalidPackage(reason): reason
            case let .installFailed(reason): "The install failed: \(reason)"
            case let .unresolvable(reason): "The installed package could not be resolved: \(reason)"
            }
        }
    }

    let store: Store
    let installsRoot: URL

    private struct PathIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ metadata: stat) {
            device = UInt64(metadata.st_dev)
            inode = UInt64(metadata.st_ino)
        }
    }

    private struct TreeSnapshot: Equatable {
        let rootIdentity: PathIdentity
        let digest: String
    }

    /// One adapter tree atomically detached from its public agent name while a
    /// cross-store deletion commits. The already-open root descriptor keeps a
    /// parent-path replacement from redirecting either rollback or cleanup.
    private struct StagedPurge {
        let agentID: String
        let stagedName: String?
        let priorRecord: InstalledAdapterRecord?
        let rootDescriptor: Int32
        let rootIdentity: PathIdentity?
    }

    private enum TreeSafetyError: LocalizedError {
        case unsafeRoot
        case unsafePath(String)
        case symlink(String)
        case hardLink(String)
        case unsupported(String)
        case caseCollision(String, String)
        case changed(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsafeRoot:
                "the candidate root is not a private app-owned directory."
            case let .unsafePath(path):
                "the candidate contains an unsafe path: \(path)."
            case let .symlink(path):
                "the candidate contains a symbolic link: \(path)."
            case let .hardLink(path):
                "the candidate contains a hard-linked file: \(path)."
            case let .unsupported(path):
                "the candidate contains an unsupported filesystem entry: \(path)."
            case let .caseCollision(first, second):
                "the candidate contains case-colliding paths: \(first) and \(second)."
            case let .changed(path):
                "the candidate changed while it was being inspected: \(path)."
            case let .unreadable(path):
                "the candidate contains an unreadable entry: \(path)."
            }
        }
    }

    init(
        store: Store = Store(),
        installsRoot: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("acp-adapters", isDirectory: true)
    ) {
        self.store = store
        self.installsRoot = installsRoot
    }

    func installRoot(agentID: String) -> URL {
        installsRoot.appendingPathComponent(agentID, isDirectory: true)
    }

    /// Whether an agent's recorded install still is what the user approved:
    /// the lockfile hash (the resolved graph), the tree hash (the code
    /// actually on disk), and a canonically-contained executable. Every
    /// mismatch names itself. The residual gap is the instant between this
    /// check and the spawn — persistent tampering is always caught on the
    /// next verify, but a write that lands inside that window is not; closing
    /// it needs descriptor-based spawning, which is deliberately out of scope
    /// here and noted rather than pretended away.
    func verify(
        agentID: String,
        expectedPackage: String? = nil,
        expectedApproval: CustomAdapterApproval? = nil
    ) -> VerifyResult {
        guard let record = store.record(agentID: agentID) else { return .notInstalled }
        guard Self.isSafePathComponent(agentID) else {
            return .drifted(reason: "The adapter id is not filesystem-safe.")
        }
        guard (try? currentIdentity(of: installsRoot)) != nil else {
            return .drifted(reason: "The adapter cache root is unsafe.")
        }
        return Self.verify(
            record: record,
            installRoot: installRoot(agentID: agentID),
            expectedPackage: expectedPackage,
            expectedApproval: expectedApproval
        )
    }

    /// Verify one captured record against one exact root. Contained launches
    /// retain the record returned by the resolver and repeat this check on
    /// every start/restart, keeping the residual race to verify-to-spawn rather
    /// than the lifetime of the conversation.
    static func verify(
        record: InstalledAdapterRecord,
        installRoot root: URL,
        expectedPackage: String? = nil,
        expectedApproval: CustomAdapterApproval? = nil
    ) -> VerifyResult {
        if let expectedPackage, expectedPackage != record.package {
            return .drifted(reason: "The approved install is for \(record.package), not \(expectedPackage).")
        }
        if let expectedApproval,
           !expectedApproval.isCurrentAndValid || record.approval != expectedApproval {
            return .drifted(
                reason: "The adapter's requested credentials or contained access changed since it was approved."
            )
        }
        let lockfile = root.appendingPathComponent("package-lock.json")
        guard let lockData = try? Self.readRegularFile(at: lockfile) else {
            return .drifted(reason: "The install's lockfile is missing.")
        }
        guard Self.sha256(lockData) == record.lockfileSHA256 else {
            return .drifted(reason: "The install's dependency graph changed since it was approved.")
        }
        guard let tree = Self.treeDigest(root: root), tree == record.treeSHA256 else {
            return .drifted(reason: "The install's files changed since they were approved.")
        }
        let bin = root.appendingPathComponent(record.binRelativePath)
        // Canonical containment: the executable, symlinks resolved, must
        // still live inside this install — a symlinked escape is drift.
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalBin = bin.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalBin == canonicalRoot || canonicalBin.hasPrefix(canonicalRoot + "/") else {
            return .drifted(reason: "The adapter executable points outside its install.")
        }
        guard Self.isSafeExecutable(bin) else {
            return .drifted(reason: "The adapter executable is missing or not executable.")
        }
        return .verified(binURL: bin, record: record)
    }

    /// One digest over every file under `root`, deterministic: sorted
    /// relative paths, each contributing its path and content. Links and
    /// special nodes are refused, and regular-file bytes are read from an
    /// `O_NOFOLLOW` descriptor. Nil when the tree is unsafe or unreadable.
    static func treeDigest(root: URL) -> String? {
        try? inspectTree(root: root).digest
    }

    /// APFS is commonly case-insensitive and canonically normalizing. Refuse
    /// a tree whose logical paths alias under that comparison even when tests
    /// run on a case-sensitive volume where both entries can coexist.
    static func firstCaseCollision(in paths: [String]) -> (String, String)? {
        var originalsByFoldedPath: [String: String] = [:]
        for path in paths {
            let folded = path.precomposedStringWithCanonicalMapping
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
            if let original = originalsByFoldedPath[folded], original != path {
                return (original, path)
            }
            originalsByFoldedPath[folded] = path
        }
        return nil
    }

    /// Hash the same regular-file manifest used by existing approvals, while
    /// rejecting filesystem objects that could make that manifest ambiguous
    /// or point beyond it. Keeping the manifest format stable means safe
    /// installs approved by earlier builds retain their tree digest.
    private static func inspectTree(root: URL) throws -> TreeSnapshot {
        let fileManager = FileManager.default
        var rootBefore = stat()
        guard lstat(root.path, &rootBefore) == 0,
              rootBefore.st_uid == getuid(),
              rootBefore.st_mode & S_IFMT == S_IFDIR,
              rootBefore.st_mode & 0o077 == 0 else {
            throw TreeSafetyError.unsafeRoot
        }
        var enumerationFailure: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationFailure = error
                return false
            }
        ) else { throw TreeSafetyError.unsafeRoot }
        var entries: [(path: String, digest: String)] = []
        var relativePaths: [String] = []
        let rootPath = root.path
        for case let url as URL in enumerator {
            let path = url.path
            guard path.hasPrefix(rootPath + "/") else {
                throw TreeSafetyError.unsafePath(path)
            }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !relative.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw TreeSafetyError.unsafePath(relative)
            }
            relativePaths.append(relative)

            var before = stat()
            guard lstat(path, &before) == 0, before.st_uid == getuid() else {
                throw TreeSafetyError.unreadable(relative)
            }
            switch before.st_mode & S_IFMT {
            case S_IFLNK:
                enumerator.skipDescendants()
                throw TreeSafetyError.symlink(relative)
            case S_IFDIR:
                continue
            case S_IFREG:
                guard before.st_nlink == 1 else {
                    throw TreeSafetyError.hardLink(relative)
                }
                let data: Data
                do { data = try readRegularFile(at: url, expected: before) }
                catch { throw TreeSafetyError.changed(relative) }
                entries.append((relative, sha256(data)))
            default:
                enumerator.skipDescendants()
                throw TreeSafetyError.unsupported(relative)
            }
        }
        if enumerationFailure != nil {
            throw TreeSafetyError.unreadable("the candidate tree")
        }
        if let collision = firstCaseCollision(in: relativePaths) {
            throw TreeSafetyError.caseCollision(collision.0, collision.1)
        }
        var rootAfter = stat()
        guard lstat(root.path, &rootAfter) == 0,
              rootAfter.st_mode & S_IFMT == S_IFDIR,
              PathIdentity(rootBefore) == PathIdentity(rootAfter) else {
            throw TreeSafetyError.changed("the candidate root")
        }
        entries.sort { $0.path < $1.path }
        let manifest = entries.map { "\($0.path)\u{1F}\($0.digest)" }.joined(separator: "\u{1E}")
        return TreeSnapshot(
            rootIdentity: PathIdentity(rootAfter),
            digest: sha256(Data(manifest.utf8))
        )
    }

    /// Resolve a package into a pinned install and record it. `runner` is the
    /// process seam (tests fabricate installs instead of running npm): it
    /// receives the install root and the validated package, performs
    /// `npm install --ignore-scripts` into that prefix, and throws on failure.
    func install(
        agentID: String,
        package rawPackage: String,
        approval: CustomAdapterApproval? = nil,
        runner: @Sendable (URL, String) async throws -> Void = AdapterInstallManager.npmInstall,
        beforePublish: @Sendable (URL) async throws -> Void = { _ in },
        afterPublish: @Sendable (URL) async throws -> Void = { _ in },
        now: Date = Date()
    ) async throws -> InstalledAdapterRecord {
        let package = rawPackage.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = CustomAgentSpec.packageNameError(package) {
            throw InstallError.invalidPackage(reason)
        }
        guard Self.isSafePathComponent(agentID) else {
            throw InstallError.unresolvable("the adapter id is not filesystem-safe.")
        }
        let installsIdentity = try prepareInstallsRoot()
        let rootDescriptor = try openInstallsRoot(expectedIdentity: installsIdentity)
        defer { Darwin.close(rootDescriptor) }
        let root = installRoot(agentID: agentID)
        let candidateName = ".candidate-\(UUID().uuidString)"
        let candidate = installsRoot.appendingPathComponent(
            candidateName,
            isDirectory: true
        )
        guard mkdirat(rootDescriptor, candidateName, 0o700) == 0 else {
            throw InstallError.unresolvable("a private adapter candidate could not be created.")
        }
        defer {
            removeCandidate(
                named: candidateName,
                rootDescriptor: rootDescriptor,
                installsIdentity: installsIdentity
            )
        }
        do {
            try await runner(candidate, package)
        } catch {
            throw InstallError.installFailed(error.localizedDescription)
        }

        let firstSnapshot: TreeSnapshot
        do {
            firstSnapshot = try Self.inspectTree(root: candidate)
        } catch {
            throw InstallError.unresolvable(error.localizedDescription)
        }
        let lockfile = candidate.appendingPathComponent("package-lock.json")
        guard let lockData = try? Self.readRegularFile(at: lockfile) else {
            throw InstallError.unresolvable("npm produced no lockfile to pin.")
        }
        let bareName = Self.bareName(of: package)
        guard let resolved = Self.resolvedVersion(lockData: lockData, packageName: bareName) else {
            throw InstallError.unresolvable("the lockfile does not name \(bareName)'s version.")
        }
        guard let binRelative = Self.binRelativePath(root: candidate, packageName: bareName) else {
            throw InstallError.unresolvable("\(bareName) declares no executable.")
        }
        let candidateBin = candidate.appendingPathComponent(binRelative)
        guard Self.isSafeExecutable(candidateBin) else {
            throw InstallError.unresolvable("\(bareName)'s executable is not a safe executable file.")
        }

        // Deterministic fault-injection point: production supplies the no-op.
        // The second inspection makes a replacement after the first scan a
        // rejection rather than a trust-promotion race.
        try await beforePublish(candidate)
        let finalSnapshot: TreeSnapshot
        do {
            finalSnapshot = try Self.inspectTree(root: candidate)
        } catch {
            throw InstallError.unresolvable(error.localizedDescription)
        }
        guard finalSnapshot == firstSnapshot else {
            throw InstallError.unresolvable("the installed files changed before they could be pinned.")
        }
        guard Self.isSafeExecutable(candidateBin) else {
            throw InstallError.unresolvable("\(bareName)'s executable changed before it could be pinned.")
        }
        guard try currentIdentity(of: installsRoot) == installsIdentity else {
            throw InstallError.unresolvable("the adapter cache root changed during installation.")
        }
        let record = InstalledAdapterRecord(
            agentID: agentID,
            package: package,
            resolvedVersion: resolved,
            binRelativePath: binRelative,
            lockfileSHA256: Self.sha256(lockData),
            treeSHA256: finalSnapshot.digest,
            approval: approval,
            installedAt: now
        )

        let replacedPrior = try promote(
            candidateName: candidateName,
            finalName: agentID,
            rootDescriptor: rootDescriptor
        )
        do {
            // A second fault-injection point exercises record/write rollback.
            try await afterPublish(root)
            guard try currentIdentity(of: installsRoot) == installsIdentity else {
                throw InstallError.unresolvable("the adapter cache root changed after publication.")
            }
            let published = try Self.inspectTree(root: root)
            guard published == finalSnapshot else {
                throw InstallError.unresolvable("the installed files changed while they were published.")
            }
            guard Self.isSafeExecutable(root.appendingPathComponent(binRelative)) else {
                throw InstallError.unresolvable("the published adapter executable is unsafe.")
            }
            guard try currentIdentity(of: installsRoot) == installsIdentity else {
                throw InstallError.unresolvable("the adapter cache root changed before approval was recorded.")
            }
            try store.upsert(record)
        } catch {
            let restored = rollbackPromotion(
                candidateName: candidateName,
                finalName: agentID,
                rootDescriptor: rootDescriptor,
                replacedPrior: replacedPrior
            )
            guard restored else {
                throw InstallError.unresolvable(
                    "the install was rejected, but its previous cache could not be restored."
                )
            }
            throw error
        }
        return record
    }

    /// A deletion whose primary failure was followed by an incomplete rollback.
    /// The caller must not claim that nothing changed in this state.
    enum PurgeError: LocalizedError {
        case rollbackIncomplete(original: String, rollback: String)

        var errorDescription: String? {
            switch self {
            case let .rollbackIncomplete(original, rollback):
                "Adapter deletion failed (\(original)); rollback was incomplete (\(rollback))."
            }
        }
    }

    /// Remove an install and its durable record as a reversible transaction.
    ///
    /// The tree is first renamed to an unguessable sibling through an already-
    /// opened, identity-checked root descriptor. That makes a refused removal
    /// fail before `committingRegistry` can change the custom-agent roster. The
    /// install record is then removed durably, the caller commits its roster,
    /// and only then are the staged bytes destroyed. Any failure before that
    /// final destruction restores the exact tree and record; a failure during
    /// destruction also asks the caller to restore its committed roster before
    /// the same rollback. Missing trees and records are idempotent success.
    func purge(
        agentID: String,
        committingRegistry: () throws -> Void = {},
        rollingBackRegistry: () throws -> Void = {}
    ) throws {
        let staged = try stagePurge(agentID: agentID)
        defer {
            if staged.rootDescriptor >= 0 { Darwin.close(staged.rootDescriptor) }
        }

        var removedRecord = false
        var committedRegistry = false
        do {
            removedRecord = try store.remove(agentID: agentID)
            try committingRegistry()
            committedRegistry = true
            try finishPurge(staged)
        } catch {
            var rollbackFailures: [String] = []
            do { try restoreStagedTree(staged) }
            catch { rollbackFailures.append(error.localizedDescription) }
            if removedRecord, let priorRecord = staged.priorRecord {
                do { try store.upsert(priorRecord) }
                catch { rollbackFailures.append(error.localizedDescription) }
            }
            if committedRegistry {
                do { try rollingBackRegistry() }
                catch { rollbackFailures.append(error.localizedDescription) }
            }
            guard rollbackFailures.isEmpty else {
                throw PurgeError.rollbackIncomplete(
                    original: error.localizedDescription,
                    rollback: rollbackFailures.joined(separator: "; ")
                )
            }
            throw error
        }
    }

    /// Remove an install and its record — disabling is reversible and total.
    /// Best-effort: for callers with nowhere to report a failure.
    func uninstall(agentID: String) {
        try? purge(agentID: agentID)
    }

    /// Detach the exact install tree without following an unsafe id, a symlink,
    /// or a replaced cache root. The descriptor stays open for the transaction.
    private func stagePurge(agentID: String) throws -> StagedPurge {
        guard Self.isSafePathComponent(agentID) else {
            throw InstallError.unresolvable("the adapter id is not filesystem-safe.")
        }
        let priorRecord = store.record(agentID: agentID)
        var rootMetadata = stat()
        guard lstat(installsRoot.path, &rootMetadata) == 0 else {
            guard errno == ENOENT else {
                throw InstallError.unresolvable("the adapter cache root could not be inspected.")
            }
            return StagedPurge(
                agentID: agentID,
                stagedName: nil,
                priorRecord: priorRecord,
                rootDescriptor: -1,
                rootIdentity: nil
            )
        }

        let identity = try currentIdentity(of: installsRoot)
        let descriptor = try openInstallsRoot(expectedIdentity: identity)
        do {
            var installMetadata = stat()
            guard fstatat(descriptor, agentID, &installMetadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                guard errno == ENOENT else {
                    throw InstallError.unresolvable("the adapter install could not be inspected safely.")
                }
                return StagedPurge(
                    agentID: agentID,
                    stagedName: nil,
                    priorRecord: priorRecord,
                    rootDescriptor: descriptor,
                    rootIdentity: identity
                )
            }
            guard installMetadata.st_uid == getuid(),
                  installMetadata.st_mode & S_IFMT == S_IFDIR else {
                throw InstallError.unresolvable("the adapter install is not an app-owned directory.")
            }

            let stagedName = ".delete-\(UUID().uuidString)"
            guard renameat(descriptor, agentID, descriptor, stagedName) == 0 else {
                throw InstallError.unresolvable("the adapter install could not be staged for deletion.")
            }
            return StagedPurge(
                agentID: agentID,
                stagedName: stagedName,
                priorRecord: priorRecord,
                rootDescriptor: descriptor,
                rootIdentity: identity
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func restoreStagedTree(_ staged: StagedPurge) throws {
        guard let stagedName = staged.stagedName else { return }
        var existing = stat()
        guard fstatat(staged.rootDescriptor, staged.agentID, &existing, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT,
              renameat(staged.rootDescriptor, stagedName, staged.rootDescriptor, staged.agentID) == 0 else {
            throw InstallError.unresolvable("the staged adapter install could not be restored.")
        }
    }

    private func finishPurge(_ staged: StagedPurge) throws {
        guard let stagedName = staged.stagedName,
              let rootIdentity = staged.rootIdentity else { return }
        let root = try descriptorRootURL(
            staged.rootDescriptor,
            expectedIdentity: rootIdentity
        )
        let target = root.appendingPathComponent(stagedName, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: target)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        }
    }

    private func descriptorRootURL(
        _ descriptor: Int32,
        expectedIdentity: PathIdentity
    ) throws -> URL {
        var descriptorMetadata = stat()
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &descriptorMetadata) == 0,
              PathIdentity(descriptorMetadata) == expectedIdentity,
              fcntl(descriptor, F_GETPATH, &pathBuffer) == 0 else {
            throw InstallError.unresolvable("the adapter cache root changed during deletion.")
        }
        let pathLength = pathBuffer.firstIndex(of: 0) ?? pathBuffer.endIndex
        let root = URL(
            fileURLWithPath: String(
                decoding: pathBuffer[..<pathLength].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            ),
            isDirectory: true
        )
        var pathMetadata = stat()
        guard lstat(root.path, &pathMetadata) == 0,
              PathIdentity(pathMetadata) == expectedIdentity,
              pathMetadata.st_uid == getuid(),
              pathMetadata.st_mode & S_IFMT == S_IFDIR else {
            throw InstallError.unresolvable("the adapter cache root changed during deletion.")
        }
        return root
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    private func prepareInstallsRoot() throws -> PathIdentity {
        guard Self.hasNoSymlinkDirectoryComponents(installsRoot) else {
            throw InstallError.unresolvable("the adapter cache root has a symbolic-link path component.")
        }
        var metadata = stat()
        if lstat(installsRoot.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw InstallError.unresolvable("the adapter cache root could not be inspected.")
            }
            try FileManager.default.createDirectory(
                at: installsRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(installsRoot.path, 0o700)
        }
        guard Self.canonicalExistingPath(installsRoot) == installsRoot.path,
              Self.hasNoSymlinkDirectoryComponents(installsRoot) else {
            throw InstallError.unresolvable("the adapter cache root changed while it was created.")
        }
        guard lstat(installsRoot.path, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o077 == 0 else {
            throw InstallError.unresolvable("the adapter cache root is not a private app-owned directory.")
        }
        return PathIdentity(metadata)
    }

    private static func hasNoSymlinkDirectoryComponents(_ url: URL) -> Bool {
        guard url.path.hasPrefix("/") else { return false }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var metadata = stat()
            if lstat(current.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
            } else if errno == ENOENT {
                // Missing descendants will be created only after all existing
                // ancestors have passed this no-symlink walk, then rechecked.
                return true
            } else {
                return false
            }
        }
        return true
    }

    private static func canonicalExistingPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func currentIdentity(of url: URL) throws -> PathIdentity {
        var metadata = stat()
        guard Self.canonicalExistingPath(url) == url.path,
              Self.hasNoSymlinkDirectoryComponents(url),
              lstat(url.path, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw InstallError.unresolvable("the adapter cache root is unsafe.")
        }
        return PathIdentity(metadata)
    }

    private func removeCandidate(
        named candidateName: String,
        rootDescriptor: Int32,
        installsIdentity: PathIdentity
    ) {
        var metadata = stat()
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(rootDescriptor, &metadata) == 0,
              PathIdentity(metadata) == installsIdentity,
              fcntl(rootDescriptor, F_GETPATH, &pathBuffer) == 0 else {
            return
        }
        let pathLength = pathBuffer.firstIndex(of: 0) ?? pathBuffer.endIndex
        let currentRootPath = String(
            decoding: pathBuffer[..<pathLength].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let currentRoot = URL(fileURLWithPath: currentRootPath, isDirectory: true)
        var pathMetadata = stat()
        guard lstat(currentRoot.path, &pathMetadata) == 0,
              PathIdentity(pathMetadata) == installsIdentity,
              pathMetadata.st_mode & S_IFMT == S_IFDIR else {
            return
        }
        try? FileManager.default.removeItem(
            at: currentRoot.appendingPathComponent(candidateName, isDirectory: true)
        )
    }

    private func openInstallsRoot(expectedIdentity: PathIdentity) throws -> Int32 {
        let descriptor = open(installsRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw InstallError.unresolvable("the adapter cache root could not be opened safely.")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR,
              PathIdentity(metadata) == expectedIdentity else {
            Darwin.close(descriptor)
            throw InstallError.unresolvable("the adapter cache root changed before publication.")
        }
        return descriptor
    }

    /// Atomically publish a first install or exchange a replacement with the
    /// prior cache. Both names are resolved relative to the already-opened
    /// cache directory, so replacing a parent path cannot redirect the write.
    /// After a swap, `candidateName` names the old known-good tree, which
    /// remains available for record-write rollback.
    private func promote(
        candidateName: String,
        finalName: String,
        rootDescriptor: Int32
    ) throws -> Bool {
        var metadata = stat()
        if fstatat(rootDescriptor, finalName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            guard renameatx_np(
                rootDescriptor,
                candidateName,
                rootDescriptor,
                finalName,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw InstallError.unresolvable("the validated adapter could not replace its prior cache.")
            }
            return true
        }
        guard errno == ENOENT,
              renameat(rootDescriptor, candidateName, rootDescriptor, finalName) == 0 else {
            throw InstallError.unresolvable("the validated adapter could not be published.")
        }
        return false
    }

    private func rollbackPromotion(
        candidateName: String,
        finalName: String,
        rootDescriptor: Int32,
        replacedPrior: Bool
    ) -> Bool {
        if replacedPrior {
            return renameatx_np(
                rootDescriptor,
                finalName,
                rootDescriptor,
                candidateName,
                UInt32(RENAME_SWAP)
            ) == 0
        }
        return renameat(rootDescriptor, finalName, rootDescriptor, candidateName) == 0
    }

    /// The package name without its version suffix (scope-aware).
    static func bareName(of package: String) -> String {
        if package.hasPrefix("@") {
            guard let slash = package.firstIndex(of: "/") else { return package }
            let afterScope = package[package.index(after: slash)...]
            if let at = afterScope.firstIndex(of: "@") {
                return String(package[..<at])
            }
            return package
        }
        if let at = package.firstIndex(of: "@") {
            return String(package[..<at])
        }
        return package
    }

    /// The resolved version for `packageName` out of npm's v2/v3 lockfile.
    static func resolvedVersion(lockData: Data, packageName: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: lockData) as? [String: Any] else {
            return nil
        }
        if let packages = root["packages"] as? [String: Any],
           let entry = packages["node_modules/\(packageName)"] as? [String: Any],
           let version = entry["version"] as? String {
            return version
        }
        // npm v1 lockfiles nest under "dependencies".
        if let dependencies = root["dependencies"] as? [String: Any],
           let entry = dependencies[packageName] as? [String: Any],
           let version = entry["version"] as? String {
            return version
        }
        return nil
    }

    /// The executable's install-relative path, read from the installed
    /// package's own `bin` declaration (string or map; first map entry wins).
    static func binRelativePath(root: URL, packageName: String) -> String? {
        let packageDirectory = "node_modules/\(packageName)"
        let manifest = root
            .appendingPathComponent(packageDirectory, isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? readRegularFile(at: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let binPath: String?
        if let bin = json["bin"] as? String {
            binPath = bin
        } else if let bin = json["bin"] as? [String: Any] {
            binPath = bin.sorted { $0.key < $1.key }.first?.value as? String
        } else {
            binPath = nil
        }
        guard let binPath else { return nil }
        let normalized = binPath.hasPrefix("./") ? String(binPath.dropFirst(2)) : binPath
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.hasPrefix("/"),
              !normalized.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return "\(packageDirectory)/\(normalized)"
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Read a single stable regular inode without ever following a leaf
    /// symlink. When an earlier `lstat` supplied `expected`, swapping the path
    /// to a different regular file between enumeration and `open` is rejected
    /// by the descriptor identity comparison as well.
    private static func readRegularFile(at url: URL, expected: stat? = nil) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_uid == getuid(),
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1 else {
            throw TreeSafetyError.unreadable(url.lastPathComponent)
        }
        if let expected {
            guard PathIdentity(expected) == PathIdentity(before),
                  expected.st_mode == before.st_mode,
                  expected.st_nlink == before.st_nlink else {
                throw TreeSafetyError.changed(url.lastPathComponent)
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              PathIdentity(before) == PathIdentity(after),
              before.st_mode == after.st_mode,
              before.st_nlink == after.st_nlink,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw TreeSafetyError.changed(url.lastPathComponent)
        }
        return data
    }

    private static func isSafeExecutable(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0
            && metadata.st_uid == getuid()
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o111 != 0
    }

    /// The real installer: npm through a login shell (the user's PATH, the
    /// same resolution the adapters themselves get), scripts disabled.
    @Sendable
    static func npmInstall(root: URL, package: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // The package name passed here has survived `packageNameError`, whose
        // character set contains nothing a shell can interpret.
        process.arguments = [
            "-ilc",
            "npm install --prefix \(Self.shellQuote(root.path)) --ignore-scripts --no-fund --no-audit --loglevel=error \(Self.shellQuote(package))",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.installFailed(
                message?.isEmpty == false ? String(message!.suffix(300)) : "npm exited \(process.terminationStatus)"
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
