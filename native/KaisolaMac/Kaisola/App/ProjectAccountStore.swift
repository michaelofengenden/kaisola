import Combine
import CryptoKit
import Foundation

/// A per-project account override: a CLAUDE_CONFIG_DIR / CODEX_HOME that a single
/// project's agent terminals, chats, and Mesh use instead of the app-wide
/// account. Either field may be nil (fall back to the app default for that CLI).
/// Values are stored as the user typed them (trimmed, empty collapsed to nil) and
/// only tilde-expanded when the process environment is built, so the settings
/// field can show "~/…" back to the user.
struct ProjectAccountOverride: Codable, Equatable, Sendable {
    var claudeConfigDir: String?
    var codexHome: String?

    /// A copy with each field trimmed and empty strings collapsed to nil.
    func normalized() -> ProjectAccountOverride {
        ProjectAccountOverride(
            claudeConfigDir: ProjectAccountOverride.clean(claudeConfigDir),
            codexHome: ProjectAccountOverride.clean(codexHome)
        )
    }

    /// True when neither field carries a usable (non-blank) value.
    var isEmpty: Bool {
        ProjectAccountOverride.clean(claudeConfigDir) == nil
            && ProjectAccountOverride.clean(codexHome) == nil
    }

    /// Trim whitespace/newlines; a blank result becomes nil ("no override").
    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// A durable, user-actionable account-store failure. The active file is never
/// rewritten by detection. When its bytes were readable, a byte-exact copy is
/// kept beside it before a launch consumer sees this issue.
struct ProjectAccountRecoveryIssue: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unreadable(reason: String)
        case corrupt
        case unsupportedVersion(found: Int)
    }

    let kind: Kind
    let sourceURL: URL
    let preservedCopyURL: URL?
    let preservationError: String?

    var revealURL: URL { preservedCopyURL ?? sourceURL }

    var title: String {
        switch kind {
        case .unreadable:
            "Project Accounts Couldn't Be Read"
        case .corrupt:
            "Project Accounts Need Recovery"
        case .unsupportedVersion:
            "Project Accounts Are From a Newer Kaisola"
        }
    }

    var summary: String { "Agent launches blocked by project-account recovery" }

    var message: String {
        let protection: String
        if let preservedCopyURL {
            protection = "Kaisola kept an exact copy as \(preservedCopyURL.lastPathComponent)."
        } else if let preservationError {
            protection = "The original file is untouched, but Kaisola could not create a preserved copy: \(preservationError)"
        } else {
            protection = "The original file is untouched."
        }
        let reason: String
        switch kind {
        case .unreadable(let detail):
            reason = "The project-account file is present but unreadable (\(detail))."
        case .corrupt:
            reason = "The project-account file is not valid account data."
        case .unsupportedVersion(let found):
            reason = "The project-account file uses unsupported data format \(found)."
        }
        return "\(reason) \(protection) Agent, chat, terminal, Mesh, and account-usage processes are blocked so they cannot fall back to app-wide credentials. Retry after repairing the file, or explicitly reset all project overrides."
    }
}

/// Persists per-project account overrides — `[projectID: ProjectAccountOverride]`
/// — in the native application-support directory (never Electron's).
///
/// Missing storage means the app-wide account is intentionally usable. Present
/// but unreadable, corrupt, or newer storage fails closed: every process launch
/// consumer receives a `ProjectAccountRecoveryIssue`, and ordinary edits cannot
/// reinterpret the file as an empty store.
struct ProjectAccountStore: Sendable {
    static let schemaVersion = 1

    struct Payload: Codable, Equatable, Sendable {
        let schemaVersion: Int?
        var projects: [String: ProjectAccountOverride]

        init(projects: [String: ProjectAccountOverride]) {
            schemaVersion = ProjectAccountStore.schemaVersion
            self.projects = projects
        }
    }

    private struct VersionHeader: Decodable {
        let schemaVersion: Int?
    }

    enum LoadStatus: Equatable, Sendable {
        case missing
        case loaded(Payload)
        case blocked(ProjectAccountRecoveryIssue)
    }

    enum StoreError: Error, LocalizedError, Equatable, Sendable {
        case recoveryRequired(ProjectAccountRecoveryIssue)
        case writeFailed(String)
        case resetRequiresRecovery
        case recoveryChanged

        var errorDescription: String? {
            switch self {
            case .recoveryRequired(let issue): issue.message
            case .writeFailed(let reason): "Kaisola couldn't save project accounts: \(reason)"
            case .resetRequiresRecovery: "Project accounts are readable, so a recovery reset is not available."
            case .recoveryChanged: "The project-account file changed after recovery was detected. Kaisola left it untouched; retry before resetting."
            }
        }
    }

    typealias DataReader = @Sendable (URL) throws -> Data
    typealias PreservationWriter = @Sendable (Data, URL) throws -> Void

    /// Serializes the read-modify-write in `set` per account file, process-wide.
    /// The store is a value type and every Settings window builds its own, so
    /// the lock has to live beside the file identity rather than beside an
    /// instance. Keyed by resolved path; production has exactly one entry.
    private static let lockRegistry = NSLock()
    private nonisolated(unsafe) static var fileLocks: [String: NSLock] = [:]

    private static func fileLock(for fileURL: URL) -> NSLock {
        let key = fileURL.standardizedFileURL.path
        lockRegistry.lock()
        defer { lockRegistry.unlock() }
        if let existing = fileLocks[key] { return existing }
        let created = NSLock()
        fileLocks[key] = created
        return created
    }
    let fileURL: URL
    private let dataReader: DataReader
    private let preservationWriter: PreservationWriter

    init(
        fileURL: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("project-accounts.json", isDirectory: false),
        dataReader: @escaping DataReader = { try Data(contentsOf: $0) },
        preservationWriter: @escaping PreservationWriter = { data, url in
            try ProjectAccountStore.writePreservedBytes(data, to: url)
        }
    ) {
        self.fileURL = fileURL
        self.dataReader = dataReader
        self.preservationWriter = preservationWriter
    }

    /// Explicitly distinguishes an intentionally absent file from every unsafe
    /// present-file outcome. Corrupt/future bytes are copied exactly once per
    /// content digest; the source stays in place until an explicit reset.
    func loadStatus() -> LoadStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }

        let data: Data
        do {
            data = try dataReader(fileURL)
        } catch {
            // A sibling reset can win the race between existence and read.
            guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
            return .blocked(ProjectAccountRecoveryIssue(
                kind: .unreadable(reason: (error as NSError).localizedDescription),
                sourceURL: fileURL,
                preservedCopyURL: nil,
                preservationError: nil
            ))
        }

        let header: VersionHeader
        do {
            header = try JSONDecoder().decode(VersionHeader.self, from: data)
        } catch {
            return .blocked(recoveryIssue(kind: .corrupt, data: data))
        }
        let foundVersion = header.schemaVersion ?? Self.schemaVersion
        guard foundVersion == Self.schemaVersion else {
            return .blocked(recoveryIssue(
                kind: .unsupportedVersion(found: foundVersion),
                data: data
            ))
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            return .loaded(payload)
        } catch {
            return .blocked(recoveryIssue(kind: .corrupt, data: data))
        }
    }

    /// The stored override for a project. A missing archive or missing entry is
    /// nil; a damaged archive throws instead of impersonating either state.
    func override(forProject projectID: String) throws -> ProjectAccountOverride? {
        switch loadStatus() {
        case .missing: nil
        case .loaded(let payload): payload.projects[projectID]
        case .blocked(let issue): throw issue
        }
    }

    /// The only account-store entry point process launchers should use. Its
    /// success case includes app defaults only when storage is truly missing or
    /// readable with no override; every unsafe present-file state is a failure.
    func launchOverlay(
        app: [String: String],
        forProject projectID: String
    ) -> Result<[String: String], ProjectAccountRecoveryIssue> {
        switch loadStatus() {
        case .missing:
            .success(app)
        case .loaded(let payload):
            .success(Self.mergedOverlay(app: app, project: payload.projects[projectID]))
        case .blocked(let issue):
            .failure(issue)
        }
    }

    /// Set (or clear) a project's override. Passing nil — or an override whose
    /// fields are all blank after trimming — removes the entry entirely. A
    /// recovery-required archive is never overwritten by this ordinary edit.
    /// The full read-modify-write runs under the per-file lock, so concurrent
    /// saves from separate Settings windows both survive.
    func set(_ override: ProjectAccountOverride?, forProject projectID: String) throws {
        let lock = ProjectAccountStore.fileLock(for: fileURL)
        lock.lock()
        defer { lock.unlock() }
        let normalized = override.flatMap { $0.isEmpty ? nil : $0.normalized() }
        var payload: Payload
        switch loadStatus() {
        case .missing:
            payload = Payload(projects: [:])
        case .loaded(let loaded):
            payload = loaded
        case .blocked(let issue):
            throw StoreError.recoveryRequired(issue)
        }
        guard payload.projects[projectID] != normalized else { return }
        if let normalized {
            payload.projects[projectID] = normalized
        } else {
            payload.projects.removeValue(forKey: projectID)
        }
        try write(payload)
    }

    /// Cross the destructive recovery boundary explicitly. Readable failure
    /// bytes already have a verified copy, so only the active source is removed.
    /// If they were unreadable, moving the source itself becomes the byte-exact
    /// preserved copy; a failed move leaves the active source untouched.
    @discardableResult
    func resetAfterFailure(expectedIssue: ProjectAccountRecoveryIssue) throws -> URL {
        guard case .blocked(let issue) = loadStatus() else {
            throw StoreError.resetRequiresRecovery
        }
        guard issue == expectedIssue else { throw StoreError.recoveryChanged }
        let fileManager = FileManager.default
        if let preserved = issue.preservedCopyURL {
            do {
                // Re-read at the destructive boundary. Another window may
                // have repaired or replaced the active file after the notice
                // preserved its earlier bytes; that newer file is not ours to
                // delete. The digest-derived path also binds this copy to the
                // exact bytes being removed.
                let sourceData = try dataReader(fileURL)
                let preservedData = try Data(contentsOf: preserved)
                guard sourceData == preservedData,
                      Self.preservedCopyURL(for: fileURL, data: sourceData) == preserved else {
                    throw StoreError.recoveryChanged
                }
                try fileManager.removeItem(at: fileURL)
                return preserved
            } catch {
                if let storeError = error as? StoreError { throw storeError }
                throw StoreError.writeFailed((error as NSError).localizedDescription)
            }
        }

        let destination = Self.unreadableResetCopyURL(
            for: fileURL,
            isTaken: { fileManager.fileExists(atPath: $0.path) }
        )
        do {
            try fileManager.moveItem(at: fileURL, to: destination)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        } catch {
            throw StoreError.writeFailed((error as NSError).localizedDescription)
        }
    }

    /// Merge a project's override onto the app-wide environment overlay. Pure and
    /// order-independent: the app overlay is the base, and each project value
    /// (tilde-expanded, trimmed, non-empty) WINS for its key. A nil, blank, or
    /// whitespace-only project value falls back to whatever the app overlay
    /// carries for that key.
    static func mergedOverlay(app: [String: String], project: ProjectAccountOverride?) -> [String: String] {
        var env = app
        if let value = expandedPath(project?.claudeConfigDir) { env["CLAUDE_CONFIG_DIR"] = value }
        if let value = expandedPath(project?.codexHome) { env["CODEX_HOME"] = value }
        return env
    }

    private func recoveryIssue(
        kind: ProjectAccountRecoveryIssue.Kind,
        data: Data
    ) -> ProjectAccountRecoveryIssue {
        let preserved = Self.preservedCopyURL(for: fileURL, data: data)
        do {
            try preservationWriter(data, preserved)
            return ProjectAccountRecoveryIssue(
                kind: kind,
                sourceURL: fileURL,
                preservedCopyURL: preserved,
                preservationError: nil
            )
        } catch {
            return ProjectAccountRecoveryIssue(
                kind: kind,
                sourceURL: fileURL,
                preservedCopyURL: nil,
                preservationError: (error as NSError).localizedDescription
            )
        }
    }

    static func preservedCopyURL(for sourceURL: URL, data: Data) -> URL {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension.isEmpty ? "json" : sourceURL.pathExtension
        return sourceURL.deletingLastPathComponent()
            .appendingPathComponent("\(base).preserved-\(digest)")
            .appendingPathExtension(fileExtension)
    }

    private static func unreadableResetCopyURL(
        for sourceURL: URL,
        isTaken: (URL) -> Bool
    ) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension.isEmpty ? "json" : sourceURL.pathExtension
        var attempt = 1
        while true {
            let candidate = sourceURL.deletingLastPathComponent()
                .appendingPathComponent("\(base).preserved-reset-\(attempt)")
                .appendingPathExtension(fileExtension)
            if !isTaken(candidate) { return candidate }
            attempt += 1
        }
    }

    private static func writePreservedBytes(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if fileManager.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else {
                throw StoreError.writeFailed("the preserved-copy name already contains different data")
            }
            return
        }
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        guard try Data(contentsOf: destination) == data else {
            throw StoreError.writeFailed("the preserved copy did not verify byte-for-byte")
        }
    }

    /// Trim, drop-if-blank, then expand a leading "~" to the home directory.
    private static func expandedPath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    private func write(_ payload: Payload) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: temporary, options: [])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw StoreError.writeFailed((error as NSError).localizedDescription)
        }
    }
}

/// Process-wide recovery authority shared by launch gates and both recovery
/// surfaces (workspace and Settings). A single observed issue prevents windows
/// or consumers from inventing conflicting ideas of whether launches are safe.
@MainActor
final class ProjectAccountRecoveryCenter: ObservableObject {
    static let shared = ProjectAccountRecoveryCenter()

    @Published private(set) var issue: ProjectAccountRecoveryIssue?
    private let store: ProjectAccountStore

    init(store: ProjectAccountStore = ProjectAccountStore()) {
        self.store = store
    }

    @discardableResult
    func loadStatus() -> ProjectAccountStore.LoadStatus {
        let status = store.loadStatus()
        observe(status)
        return status
    }

    func launchOverlay(
        app: [String: String],
        forProject projectID: String
    ) -> Result<[String: String], ProjectAccountRecoveryIssue> {
        let result = store.launchOverlay(app: app, forProject: projectID)
        switch result {
        case .success:
            issue = nil
        case .failure(let failure):
            issue = failure
        }
        return result
    }

    func set(_ override: ProjectAccountOverride?, forProject projectID: String) throws {
        do {
            try store.set(override, forProject: projectID)
            issue = nil
        } catch ProjectAccountStore.StoreError.recoveryRequired(let recovery) {
            issue = recovery
            throw ProjectAccountStore.StoreError.recoveryRequired(recovery)
        }
    }

    @discardableResult
    func retry() -> Bool {
        switch loadStatus() {
        case .missing, .loaded: true
        case .blocked: false
        }
    }

    @discardableResult
    func resetAfterFailure() throws -> URL {
        guard let expectedIssue = issue else {
            throw ProjectAccountStore.StoreError.resetRequiresRecovery
        }
        do {
            let preserved = try store.resetAfterFailure(expectedIssue: expectedIssue)
            issue = nil
            return preserved
        } catch {
            _ = loadStatus()
            throw error
        }
    }

    private func observe(_ status: ProjectAccountStore.LoadStatus) {
        switch status {
        case .missing, .loaded:
            issue = nil
        case .blocked(let failure):
            issue = failure
        }
    }
}
