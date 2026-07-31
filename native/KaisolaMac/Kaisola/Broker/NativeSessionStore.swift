import CryptoKit
import Darwin
import Foundation

/// A terminal the native app created and owns. Electron-observed terminals
/// never appear here; membership in this store is the sole gate for enabling
/// input and mutation on a session.
struct NativeOwnedSession: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let projectID: String
    let cwd: String
    var title: String
    let createdAt: Int64
    /// The agent CLI this session boots (AgentRegistry id), or nil for a plain
    /// shell. Persisted so a relaunched session keeps its agent identity.
    var agentID: String?
    /// Account chosen when this agent process was created. The optional
    /// profile id is exposed as `accountID`; continuation authority is the
    /// binding's provider + resolved config directory.
    var accountBinding: SessionAccountBinding?
    var accountID: String? { accountBinding?.normalized?.accountID }
    /// Last title inferred from live terminal activity. Keeping this separate
    /// from the visible title lets later process/OSC updates keep improving an
    /// automatic name without ever overwriting a manual rename.
    var lastAutoTitle: String?

    init(
        id: String,
        projectID: String,
        cwd: String,
        title: String,
        createdAt: Int64,
        agentID: String? = nil,
        accountBinding: SessionAccountBinding? = nil,
        lastAutoTitle: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.cwd = cwd
        self.title = title
        self.createdAt = createdAt
        self.agentID = agentID
        self.accountBinding = accountBinding?.normalized
        self.lastAutoTitle = lastAutoTitle
    }
}

/// An explicitly-opened project tab: a folder the user opened as a workspace,
/// which persists even with no live sessions and carries a custom name and
/// optional tint color.
struct OpenProject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    var name: String
    let createdAt: Int64
    /// Tab tint (hex RGB like "E16A6A"); nil = default chrome.
    var colorHex: String?

    init(id: String, path: String, name: String, createdAt: Int64, colorHex: String? = nil) {
        self.id = id
        self.path = path
        self.name = name
        self.createdAt = createdAt
        self.colorHex = colorHex
    }
}

/// What Reopen Closed Session (⌘⌥T) needs to recreate an ended session: the
/// folder, the agent (if any), and the title it had. The PTY itself is gone —
/// reopening starts a fresh shell in the same place.
struct ClosedSession: Codable, Equatable, Sendable {
    let cwd: String
    let agentID: String?
    let title: String
    let accountBinding: SessionAccountBinding?
    /// Previous PTY identity used only to locate its private composer draft.
    /// Optional keeps closed-session archives from older builds readable.
    let sourceTerminalID: String?

    init(
        cwd: String,
        agentID: String?,
        title: String,
        accountBinding: SessionAccountBinding? = nil,
        sourceTerminalID: String? = nil
    ) {
        self.cwd = cwd
        self.agentID = agentID
        self.title = title
        self.accountBinding = accountBinding?.normalized
        self.sourceTerminalID = sourceTerminalID
    }
}

/// Persists the app's broker owner identity and its owned-terminal registry in
/// the native application-support directory (never Electron's). Writes are
/// atomic; a corrupt file degrades to an empty registry rather than a crash.
struct NativeSessionStore: Sendable {
    /// One coherent read of the navigation fields AppModel renders together.
    /// Keeping this as a value also prevents a project-open interaction from
    /// synchronously decoding the same JSON archive three times on MainActor.
    struct NavigationSnapshot: Equatable, Sendable {
        var sessions: [NativeOwnedSession]
        var projects: [OpenProject]
        var sessionAliases: [String: String]
    }

    private struct Payload: Codable {
        var ownerID: String
        var sessions: [NativeOwnedSession]
        var projects: [OpenProject]?
        /// Recently closed project tabs, newest last, bounded — powers
        /// Reopen Closed Project (⌘⇧T).
        var closedProjects: [OpenProject]?
        /// Recently ended sessions, newest last, bounded — powers
        /// Reopen Closed Session (⌘⌥T).
        var closedSessions: [ClosedSession]?
        /// Recently opened folders, most recent first — File ▸ Open Recent.
        var recentFolders: [String]?
        /// The session selected when the app last ran, restored on relaunch.
        var lastSelectedSessionID: String?
        /// User-facing aliases for sessions that this native install does not
        /// own (for example an Electron-created terminal).  Ownership still
        /// gates every broker mutation; aliases are local navigation metadata.
        var sessionAliases: [String: String]?
    }

    /// Process-wide decoded-payload cache, keyed by archive URL.
    ///
    /// `NativeSessionStore` is a value type that callers construct ad hoc —
    /// `AppModel` holds one, but `refreshPersistedNavigationState` alone runs
    /// from seventeen call sites including a 2.5s inventory tick, and every
    /// read previously meant `Data(contentsOf:)` + a full `JSONDecode` on the
    /// main actor. A per-instance cache would never hit, so the cache lives
    /// beside the file identity instead. Only this process writes
    /// `native-sessions.json` (the broker does not), so a write-through cache
    /// cannot go stale behind our back.
    private final class PayloadCache: @unchecked Sendable {
        static let shared = PayloadCache()

        private let lock = NSLock()
        private var entries: [URL: Payload] = [:]
        /// URLs already read from disk, so a genuinely absent archive is
        /// remembered as absent rather than re-probed on every read.
        private var loaded: Set<URL> = []

        func cached(_ url: URL) -> Payload?? {
            lock.lock()
            defer { lock.unlock() }
            guard loaded.contains(url) else { return nil }
            return .some(entries[url])
        }

        func store(_ payload: Payload?, for url: URL) {
            lock.lock()
            defer { lock.unlock() }
            loaded.insert(url)
            entries[url] = payload
        }
    }

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    private let closedStackCap = 10

    let fileURL: URL

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("native-sessions.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// Stable per-install controller identity: the broker's ownership and
    /// stale-write rules key on it, so reattach after relaunch must present
    /// the same value.
    func ownerID() -> String {
        if let payload = read(), !payload.ownerID.isEmpty { return payload.ownerID }
        let fresh = "native-" + UUID().uuidString.lowercased()
        var payload = read() ?? Payload(ownerID: fresh, sessions: [])
        payload.ownerID = fresh
        write(payload)
        return fresh
    }

    func sessions() -> [NativeOwnedSession] {
        read()?.sessions ?? []
    }

    func navigationSnapshot() -> NavigationSnapshot {
        guard let payload = read() else {
            return NavigationSnapshot(sessions: [], projects: [], sessionAliases: [:])
        }
        return NavigationSnapshot(
            sessions: payload.sessions,
            projects: payload.projects ?? [],
            sessionAliases: payload.sessionAliases ?? [:]
        )
    }

    func sessionAliases() -> [String: String] {
        read()?.sessionAliases ?? [:]
    }

    /// Persist or clear a local display alias without touching the PTY or its
    /// broker-owned title. This makes observed sessions safely renameable.
    func setSessionAlias(_ title: String?, for terminalID: String) {
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [])
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var aliases = payload.sessionAliases ?? [:]
        if trimmed.isEmpty {
            aliases.removeValue(forKey: terminalID)
        } else {
            aliases[terminalID] = trimmed
        }
        payload.sessionAliases = aliases.isEmpty ? nil : aliases
        write(payload)
    }

    /// Repair a lost/stale local registry only from the broker's authenticated
    /// stable-owner capability. This is intentionally narrower than matching
    /// the `nproj_` namespace: unrelated native installs remain observed.
    /// A persisted open project supplies the cwd because broker diagnostics do
    /// not expose it. Existing records (including titles/agent ids) win.
    @discardableResult
    func recoverOwnedSessions(
        from records: [BrokerTerminalRecord],
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [NativeOwnedSession] {
        guard var payload = read(), !payload.ownerID.isEmpty else { return [] }
        let projectsByID = Dictionary(uniqueKeysWithValues: (payload.projects ?? []).map { ($0.id, $0) })
        var known = Set(payload.sessions.map(\.id))
        var recovered: [NativeOwnedSession] = []

        for record in records where !record.exited && !known.contains(record.id) {
            guard record.wasOwned(by: payload.ownerID),
                  let project = projectsByID[record.projectID] else { continue }
            let session = NativeOwnedSession(
                id: record.id,
                projectID: record.projectID,
                cwd: project.path,
                title: project.name,
                createdAt: now
            )
            payload.sessions.append(session)
            known.insert(record.id)
            recovered.append(session)
        }
        if !recovered.isEmpty { write(payload) }
        return recovered
    }

    // MARK: - Opened project tabs

    func projects() -> [OpenProject] {
        read()?.projects ?? []
    }

    /// Add a project tab for a directory (idempotent by projectID). Returns the
    /// project so the caller can select it.
    @discardableResult
    func openProject(directory path: String) -> OpenProject {
        let id = Self.projectID(forDirectory: path)
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [], projects: [])
        // Re-opening a folder retires any stale closed-stack entry for it.
        payload.closedProjects?.removeAll { $0.id == id }
        // Every open lands at the head of File ▸ Open Recent.
        let normalized = (path as NSString).standardizingPath
        var recents = payload.recentFolders ?? []
        recents.removeAll { $0 == normalized }
        recents.insert(normalized, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        payload.recentFolders = recents
        var projects = payload.projects ?? []
        if let existing = projects.first(where: { $0.id == id }) {
            write(payload)
            return existing
        }
        let project = OpenProject(
            id: id,
            path: (path as NSString).standardizingPath,
            name: (path as NSString).lastPathComponent,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        projects.append(project)
        payload.projects = projects
        write(payload)
        return project
    }

    func renameProject(id: String, name: String) {
        guard var payload = read(), var projects = payload.projects,
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name
        payload.projects = projects
        write(payload)
    }

    /// Set (or clear) a project tab's tint color.
    func setProjectColor(id: String, colorHex: String?) {
        guard var payload = read(), var projects = payload.projects,
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].colorHex = colorHex
        payload.projects = projects
        write(payload)
    }

    /// Move a project tab one position left/right in the persisted order.
    func moveProject(id: String, delta: Int) {
        guard var payload = read(), var projects = payload.projects,
              let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard target >= 0, target < projects.count else { return }
        projects.swapAt(index, target)
        payload.projects = projects
        write(payload)
    }

    /// Move a project tab to an absolute `toIndex` — the destination of a
    /// pointer drag-reorder. `toIndex` is clamped; a no-op when `id` is absent
    /// or already in place.
    ///
    /// This is a single remove-and-insert against one decoded payload. It
    /// deliberately does *not* loop `moveProject(id:delta:)`: the drop delegate
    /// fires on every hover crossing during a live drag, and one adjacent swap
    /// per call meant a full decode plus an atomic file replacement per
    /// intervening tab.
    func moveProject(id: String, toIndex: Int) {
        guard var payload = read(), var projects = payload.projects,
              let from = projects.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(toIndex, projects.count - 1))
        guard clamped != from else { return }
        let moved = projects.remove(at: from)
        projects.insert(moved, at: clamped)
        payload.projects = projects
        write(payload)
    }

    /// Point a project tab at a folder that moved on disk. Identity follows the
    /// path, so this closes the old tab and opens the new folder carrying the
    /// custom name/color across.
    @discardableResult
    func relocateProject(id: String, toDirectory newPath: String) -> OpenProject? {
        guard let existing = projects().first(where: { $0.id == id }) else { return nil }
        closeProject(id: id)
        var replacement = openProject(directory: newPath)
        // Carry look & feel over to the relocated tab.
        renameProject(id: replacement.id, name: existing.name)
        setProjectColor(id: replacement.id, colorHex: existing.colorHex)
        replacement.name = existing.name
        replacement.colorHex = existing.colorHex
        return replacement
    }

    // MARK: - Recents & selection restore

    func recentFolders() -> [String] {
        read()?.recentFolders ?? []
    }

    func recordRecentFolder(_ path: String) {
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [])
        var recents = payload.recentFolders ?? []
        let normalized = (path as NSString).standardizingPath
        recents.removeAll { $0 == normalized }
        recents.insert(normalized, at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        payload.recentFolders = recents
        write(payload)
    }

    func lastSelectedSessionID() -> String? {
        read()?.lastSelectedSessionID
    }

    func recordSelectedSession(_ id: String?) {
        guard var payload = read() else { return }
        payload.lastSelectedSessionID = id
        write(payload)
    }

    func closeProject(id: String) {
        guard var payload = read() else { return }
        if let closed = payload.projects?.first(where: { $0.id == id }) {
            var stack = payload.closedProjects ?? []
            stack.removeAll { $0.id == id }   // no duplicates; most-recent wins
            stack.append(closed)
            if stack.count > closedStackCap { stack.removeFirst(stack.count - closedStackCap) }
            payload.closedProjects = stack
        }
        payload.projects?.removeAll { $0.id == id }
        write(payload)
    }

    /// Restore the most recently closed project tab, removing it from the stack.
    /// Returns the restored project, or nil if the stack is empty.
    @discardableResult
    func reopenLastClosedProject() -> OpenProject? {
        guard var payload = read(), var stack = payload.closedProjects, let restored = stack.popLast() else { return nil }
        var projects = payload.projects ?? []
        if !projects.contains(where: { $0.id == restored.id }) {
            projects.append(restored)
        }
        payload.projects = projects
        payload.closedProjects = stack
        write(payload)
        return restored
    }

    func closedProjects() -> [OpenProject] {
        read()?.closedProjects ?? []
    }

    // MARK: - Closed sessions (⌘⌥T)

    /// Record an ended session so it can be recreated.
    func pushClosedSession(_ closed: ClosedSession) {
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [])
        var stack = payload.closedSessions ?? []
        stack.append(closed)
        if stack.count > closedStackCap { stack.removeFirst(stack.count - closedStackCap) }
        payload.closedSessions = stack
        write(payload)
    }

    /// Pop the most recently ended session for recreation.
    func popClosedSession() -> ClosedSession? {
        guard var payload = read(), var stack = payload.closedSessions, let last = stack.popLast() else { return nil }
        payload.closedSessions = stack
        write(payload)
        return last
    }

    func closedSessions() -> [ClosedSession] {
        read()?.closedSessions ?? []
    }

    func owns(terminalID: String) -> Bool {
        sessions().contains { $0.id == terminalID }
    }

    func upsert(_ session: NativeOwnedSession) {
        var payload = read() ?? Payload(ownerID: ownerID(), sessions: [])
        payload.sessions.removeAll { $0.id == session.id }
        payload.sessions.append(session)
        payload.sessions.sort { $0.createdAt < $1.createdAt }
        write(payload)
    }

    func remove(terminalID: String) {
        guard var payload = read() else { return }
        payload.sessions.removeAll { $0.id == terminalID }
        payload.sessionAliases?.removeValue(forKey: terminalID)
        write(payload)
    }

    /// Deterministic project identity for a working directory so the same
    /// folder maps to the same broker project across launches. Distinct from
    /// Electron's `proj_*` namespace by construction.
    static func projectID(forDirectory path: String) -> String {
        let normalized = (path as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "nproj_\(hex)"
    }

    static func terminalID(projectID: String) -> String {
        "term-\(projectID)-\(UUID().uuidString.lowercased().prefix(8))"
    }

    private func read() -> Payload? {
        if let cached = PayloadCache.shared.cached(fileURL) { return cached }
        let payload: Payload? = (try? Data(contentsOf: fileURL))
            .flatMap { try? Self.decoder.decode(Payload.self, from: $0) }
        PayloadCache.shared.store(payload, for: fileURL)
        return payload
    }

    private func write(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? Self.encoder.encode(payload) else { return }
        // Write through before touching disk: an in-process reader must never
        // observe the pre-write payload, and a failed disk write still leaves
        // the live app coherent with what it just chose to persist.
        PayloadCache.shared.store(payload, for: fileURL)
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            // The cache above already accepted this payload, so the live app
            // stays coherent — but the durable copy is gone. Left unsaid, a
            // full or read-only volume looks like nothing at all until the next
            // launch quietly reverts every session the user created.
            SessionStoreWriteFailureMonitor.shared.record(
                SessionStoreWriteFailure(path: fileURL.path, error: error)
            )
        }
    }
}

/// A session-store write that reached the in-memory cache but not the disk.
struct SessionStoreWriteFailure: Equatable, Sendable {
    let path: String
    let reason: String

    init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    init(path: String, error: Error) {
        self.init(path: path, reason: Self.reason(for: error))
    }

    /// One sentence naming the problem and the thing the user can change.
    var message: String {
        "Couldn't save session state to disk. \(reason)"
    }

    private static func reason(for error: Error) -> String {
        let cocoa = error as NSError
        let posix = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError ?? cocoa
        switch (posix.domain, Int32(posix.code)) {
        case (NSPOSIXErrorDomain, ENOSPC), (NSCocoaErrorDomain, Int32(NSFileWriteOutOfSpaceError)):
            return "The disk is full."
        case (NSPOSIXErrorDomain, EACCES), (NSPOSIXErrorDomain, EPERM),
             (NSCocoaErrorDomain, Int32(NSFileWriteNoPermissionError)):
            return "The disk is not writable by Kaisola right now."
        case (NSPOSIXErrorDomain, EROFS), (NSCocoaErrorDomain, Int32(NSFileWriteVolumeReadOnlyError)):
            return "The disk is read-only."
        default:
            return "The disk write failed: \(cocoa.localizedDescription)"
        }
    }
}

/// Surfaces at most one session-store write failure per window of time.
///
/// A failing volume fails every write, and the store writes on ordinary
/// activity (session create, rename, close, selection). Without a throttle the
/// first bad write becomes an unbroken wall of identical toasts.
struct SessionStoreWriteFailureThrottle: Equatable, Sendable {
    let minimumInterval: TimeInterval
    private var lastSurfacedAt: Date?
    /// Failures swallowed since the last surfaced one.
    private(set) var suppressedCount = 0
    /// Every failure this throttle has seen, surfaced or not.
    private(set) var totalCount = 0

    init(minimumInterval: TimeInterval = 300) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func shouldSurface(at now: Date) -> Bool {
        totalCount += 1
        if let lastSurfacedAt, now.timeIntervalSince(lastSurfacedAt) < minimumInterval {
            suppressedCount += 1
            return false
        }
        lastSurfacedAt = now
        suppressedCount = 0
        return true
    }

    mutating func reset() {
        lastSurfacedAt = nil
        suppressedCount = 0
        totalCount = 0
    }
}

/// Process-wide reporting for session-store write failures. The store is a
/// value type used from several actors, so the throttle lives here rather than
/// in any one instance.
final class SessionStoreWriteFailureMonitor: @unchecked Sendable {
    static let shared = SessionStoreWriteFailureMonitor()

    private let lock = NSLock()
    private var throttle: SessionStoreWriteFailureThrottle
    private var observer: (@Sendable (SessionStoreWriteFailure) -> Void)?

    init(minimumInterval: TimeInterval = 300) {
        throttle = SessionStoreWriteFailureThrottle(minimumInterval: minimumInterval)
    }

    /// Replaces the default toast presentation. Tests use it to observe the
    /// exact failure without a window.
    func setObserver(_ observer: (@Sendable (SessionStoreWriteFailure) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.observer = observer
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        throttle.reset()
        observer = nil
    }

    /// Returns whether this failure was surfaced rather than throttled.
    @discardableResult
    func record(_ failure: SessionStoreWriteFailure, now: Date = Date()) -> Bool {
        lock.lock()
        let surfaced = throttle.shouldSurface(at: now)
        let observer = self.observer
        lock.unlock()

        guard surfaced else { return false }
        FileHandle.standardError.write(Data(
            "KAISOLA_SESSION_STORE_WRITE_FAILED path=\(failure.path) reason=\(failure.reason)\n".utf8
        ))
        if let observer {
            observer(failure)
        } else {
            let message = failure.message
            Task { @MainActor in
                ToastCenter.shared.show(message, style: .error, duration: 6)
            }
        }
        return true
    }
}

// MARK: - Workspace restoration

/// The persisted surface type is deliberately smaller than the live AppModel surface.
/// In particular, terminal entries are only broker-session references: restoring this
/// state must never synthesize ownership or launch a replacement terminal. Callers must
/// intersect terminal IDs with the broker's live session inventory before attaching.
enum NativeRestorableSurfaceKind: String, Codable, CaseIterable, Sendable {
    case terminal
    case agentChat
    case mesh
}

enum NativeMeshLifecycle: String, Codable, CaseIterable, Sendable {
    case provisioning
    case active
    case suspended
    case pendingDeletion
    case recoveryRequired
}

enum NativeMeshColumnProvisioning: String, Codable, CaseIterable, Sendable {
    case provisioning
    case attached
    case recoveryRequired
}

enum NativeMeshWorkspaceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case base
    case worktree
}

struct NativeRestorableMeshColumnDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let agentID: String
    let role: MeshRole
    let worktreePath: String?
    let branch: String?
    /// The base commit from which this editing branch was created. Destructive
    /// close compares HEAD against this OID so clean-but-unintegrated commits
    /// cannot be mistaken for disposable work.
    let createdBaseOID: String?
    let acpSessionID: String?
    /// Immutable account context for this provider continuation.
    let accountBinding: SessionAccountBinding?
    let provisioning: NativeMeshColumnProvisioning
    /// Explicit because an editing role may intentionally use the base folder
    /// when that folder is not a Git repository. Nil is accepted only for
    /// schema migration and is never used to infer an unsafe shared workspace.
    let workspaceKind: NativeMeshWorkspaceKind?

    init(
        id: String,
        agentID: String,
        role: MeshRole,
        worktreePath: String?,
        branch: String?,
        createdBaseOID: String?,
        acpSessionID: String?,
        accountBinding: SessionAccountBinding? = nil,
        provisioning: NativeMeshColumnProvisioning,
        workspaceKind: NativeMeshWorkspaceKind? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.role = role
        self.worktreePath = worktreePath
        self.branch = branch
        self.createdBaseOID = createdBaseOID
        self.acpSessionID = acpSessionID
        self.accountBinding = accountBinding?.normalized
        self.provisioning = provisioning
        self.workspaceKind = workspaceKind
    }
}

struct NativeRestorableMeshDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let projectID: String
    let basePath: String
    let title: String
    let mode: MeshMode
    let purpose: MeshPurpose
    let lifecycle: NativeMeshLifecycle
    let columns: [NativeRestorableMeshColumnDescriptor]
}

struct NativeRestorableSurfaceState: Codable, Equatable, Hashable, Sendable {
    let kind: NativeRestorableSurfaceKind
    let id: String
    let projectID: String
    let agentID: String?
    let workspacePath: String?
    /// Adapter-issued ACP session identity. It is a resume candidate only:
    /// callers must negotiate `loadSession` and fall back to `session/new`.
    let acpSessionID: String?
    let accountBinding: SessionAccountBinding?
    let title: String?
    let mesh: NativeRestorableMeshDescriptor?

    init(
        kind: NativeRestorableSurfaceKind,
        id: String,
        projectID: String,
        agentID: String? = nil,
        workspacePath: String? = nil,
        acpSessionID: String? = nil,
        accountBinding: SessionAccountBinding? = nil,
        title: String? = nil,
        mesh: NativeRestorableMeshDescriptor? = nil
    ) {
        self.kind = kind
        self.id = id
        self.projectID = projectID
        self.agentID = agentID
        self.workspacePath = workspacePath
        self.acpSessionID = acpSessionID
        self.accountBinding = accountBinding?.normalized
        self.title = title
        self.mesh = mesh
    }
}

struct NativeRestorableAgentChatDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let projectID: String
    let agentID: String
    let workspacePath: String
    let acpSessionID: String?
    let accountBinding: SessionAccountBinding?
    let title: String?

    init(
        id: String,
        projectID: String,
        agentID: String,
        workspacePath: String,
        acpSessionID: String?,
        accountBinding: SessionAccountBinding? = nil,
        title: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.agentID = agentID
        self.workspacePath = workspacePath
        self.acpSessionID = acpSessionID
        self.accountBinding = accountBinding?.normalized
        self.title = title
    }
}

extension NativeRestorableSurfaceState {
    init(agentChat descriptor: NativeRestorableAgentChatDescriptor) {
        self.init(
            kind: .agentChat,
            id: descriptor.id,
            projectID: descriptor.projectID,
            agentID: descriptor.agentID,
            workspacePath: descriptor.workspacePath,
            acpSessionID: descriptor.acpSessionID,
            accountBinding: descriptor.accountBinding,
            title: descriptor.title
        )
    }

    var agentChatDescriptor: NativeRestorableAgentChatDescriptor? {
        guard kind == .agentChat,
              let agentID,
              let workspacePath else {
            return nil
        }
        return NativeRestorableAgentChatDescriptor(
            id: id,
            projectID: projectID,
            agentID: agentID,
            workspacePath: workspacePath,
            acpSessionID: acpSessionID,
            accountBinding: accountBinding,
            title: title
        )
    }


    init(mesh descriptor: NativeRestorableMeshDescriptor) {
        self.init(
            kind: .mesh,
            id: descriptor.id,
            projectID: descriptor.projectID,
            workspacePath: descriptor.basePath,
            title: descriptor.title,
            mesh: descriptor
        )
    }

    var meshDescriptor: NativeRestorableMeshDescriptor? {
        guard kind == .mesh,
              let mesh,
              mesh.id == id,
              mesh.projectID == projectID else {
            return nil
        }
        return mesh
    }
}

struct NativeRestorablePaneState: Codable, Equatable, Identifiable, Sendable {
    /// Stable session/chat ID used by `SessionPaneLayout`.
    let id: String
    let surface: NativeRestorableSurfaceState
    var sizeWeight: Double
    var isMinimized: Bool

    init(
        id: String,
        surface: NativeRestorableSurfaceState,
        sizeWeight: Double = 1,
        isMinimized: Bool = false
    ) {
        self.id = id
        self.surface = surface
        self.sizeWeight = sizeWeight
        self.isMinimized = isMinimized
    }
}

/// One durable document tab. Paths are workspace-relative so moving or
/// renaming the project root cannot grant the restoration archive access to an
/// unrelated absolute location.
struct NativeRestorableFileTabState: Codable, Equatable, Identifiable, Sendable {
    var id: String { relativePath }
    let relativePath: String
    var isPinned: Bool
    var line: Int?

    init(relativePath: String, isPinned: Bool = false, line: Int? = nil) {
        self.relativePath = relativePath
        self.isPinned = isPinned
        self.line = line
    }
}

enum NativePaneArrangement: String, Codable, CaseIterable, Sendable {
    case columns
    case rows
    case grid
}

struct NativeProjectWorkspaceState: Codable, Equatable, Identifiable, Sendable {
    var id: String { projectID }

    let projectID: String
    /// Exact two-dimensional pane ordering and geometry. IDs address entries
    /// in `panes`; the descriptors remain the source of terminal/chat identity.
    var layout: SessionPaneLayout
    /// Retained for schema-v1 snapshots and as a coarse fallback when decoding
    /// an archive written before `layout` existed.
    var arrangement: NativePaneArrangement
    var panes: [NativeRestorablePaneState]
    var focusedPaneID: String?
    var fileTabs: [NativeRestorableFileTabState]
    var selectedFilePath: String?
    var updatedAt: Int64

    init(
        projectID: String,
        layout: SessionPaneLayout? = nil,
        arrangement: NativePaneArrangement = .columns,
        panes: [NativeRestorablePaneState] = [],
        focusedPaneID: String? = nil,
        fileTabs: [NativeRestorableFileTabState] = [],
        selectedFilePath: String? = nil,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        self.projectID = projectID
        self.layout = layout ?? Self.fallbackLayout(for: panes, arrangement: arrangement)
        self.arrangement = arrangement
        self.panes = panes
        self.focusedPaneID = focusedPaneID
        self.fileTabs = fileTabs
        self.selectedFilePath = selectedFilePath
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case layout
        case arrangement
        case panes
        case focusedPaneID
        case fileTabs
        case selectedFilePath
        case updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        arrangement = try container.decodeIfPresent(NativePaneArrangement.self, forKey: .arrangement) ?? .columns
        panes = try container.decodeIfPresent([NativeRestorablePaneState].self, forKey: .panes) ?? []
        layout = try container.decodeIfPresent(SessionPaneLayout.self, forKey: .layout)
            ?? Self.fallbackLayout(for: panes, arrangement: arrangement)
        focusedPaneID = try container.decodeIfPresent(String.self, forKey: .focusedPaneID)
        fileTabs = try container.decodeIfPresent(
            [NativeRestorableFileTabState].self,
            forKey: .fileTabs
        ) ?? []
        selectedFilePath = try container.decodeIfPresent(String.self, forKey: .selectedFilePath)
        updatedAt = try container.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(layout, forKey: .layout)
        try container.encode(arrangement, forKey: .arrangement)
        try container.encode(panes, forKey: .panes)
        try container.encodeIfPresent(focusedPaneID, forKey: .focusedPaneID)
        try container.encode(fileTabs, forKey: .fileTabs)
        try container.encodeIfPresent(selectedFilePath, forKey: .selectedFilePath)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    fileprivate static func fallbackLayout(
        for panes: [NativeRestorablePaneState],
        arrangement: NativePaneArrangement
    ) -> SessionPaneLayout {
        let visibleIDs = panes.filter { !$0.isMinimized }.map(\.id)
        guard !visibleIDs.isEmpty else { return SessionPaneLayout() }
        switch arrangement {
        case .rows:
            return SessionPaneLayout(columns: [.init(sessionIDs: visibleIDs)])
        case .columns:
            return SessionPaneLayout(columns: visibleIDs.map { .init(sessionIDs: [$0]) })
        case .grid:
            var layout = SessionPaneLayout()
            for id in visibleIDs { layout.add(id) }
            return layout
        }
    }
}

struct NativeWorkspaceRestorationState: Codable, Equatable, Sendable {
    var selectedProjectID: String?
    var projects: [NativeProjectWorkspaceState]

    init(
        selectedProjectID: String? = nil,
        projects: [NativeProjectWorkspaceState] = []
    ) {
        self.selectedProjectID = selectedProjectID
        self.projects = projects
    }
}

struct NativeAgentChatDraft: Codable, Equatable, Identifiable, Sendable {
    /// A SHA-256 identifier derived from the caller's stable conversation key.
    /// The raw key is intentionally not persisted.
    let id: String
    let projectID: String
    let agentID: String
    let workspacePath: String
    let text: String
    let updatedAt: Int64
}

/// A private, bounded archive for UI restoration and unsent composer text.
///
/// This is separate from `NativeSessionStore` so frequent draft saves cannot rewrite
/// broker ownership records. Actor isolation serializes reads and atomic replacements,
/// while the UI can call it from a detached task instead of blocking AppKit rendering.
actor NativeWorkspaceStateStore {
    enum StoreError: Error, Equatable {
        case invalidIdentifier
        case invalidWorkspacePath
        case draftTooLarge(maxBytes: Int)
        case archiveTooLarge(maxBytes: Int)
        case unsupportedSchema(found: Int)
        case corruptArchive
        case criticalDescriptorNotPersisted
        case unsafePath
    }

    /// Schema 2 adds durable Mesh manifests. Readers still decode schema 1 and
    /// migrate it in memory, while older app versions reject schema 2 before
    /// decoding and therefore cannot overwrite Mesh state on downgrade.
    static let schemaVersion = 2
    static let minimumReadableSchemaVersion = 1
    static let maximumProjects = 64
    static let maximumPanesPerProject = 8
    static let maximumFileTabsPerProject = 24
    static let maximumDrafts = 128
    static let maximumDraftBytes = 256 * 1_024
    static let maximumTotalDraftBytes = 2 * 1_024 * 1_024
    static let maximumArchiveBytes = 3 * 1_024 * 1_024
    /// Process-wide production instance. Using one actor avoids lost updates
    /// between independently rendered chat/pane views.
    static let live = NativeWorkspaceStateStore()

    private static let maximumIdentifierCharacters = 240
    private static let maximumTitleCharacters = 512
    private static let minimumPaneWeight = 0.05
    private static let maximumPaneWeight = 20.0

    private struct Archive: Codable, Equatable {
        var schemaVersion: Int
        var restoration: NativeWorkspaceRestorationState
        var drafts: [NativeAgentChatDraft]

        static var empty: Archive {
            Archive(
                schemaVersion: NativeWorkspaceStateStore.schemaVersion,
                restoration: NativeWorkspaceRestorationState(),
                drafts: []
            )
        }
    }

    private struct ArchiveHeader: Decodable {
        let schemaVersion: Int
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let meshWorktreeRoot: URL
    private var cachedArchive: Archive?

    init(
        fileURL: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("workspace-state-v1.json"),
        fileManager: FileManager = .default,
        meshWorktreeRoot: URL = NativePreviewPaths.meshWorktreesDirectory
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.meshWorktreeRoot = meshWorktreeRoot.standardizedFileURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// The archive this store protects. Exposed so a degraded-state notice can
    /// name and reveal it without awaiting the actor.
    nonisolated var archiveURL: URL { fileURL }

    static func agentChatStableKey(agentID: String, workspacePath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        return "\(agentID)|\(standardizedPath)"
    }

    /// Where an unreadable archive is preserved: beside the original, named for
    /// the instant it failed, and never a name that is already taken. Recovery
    /// depends on those bytes, so this deliberately cannot resolve to the
    /// archive itself or to an earlier preserved copy.
    static func preservedCopyURL(
        for archiveURL: URL,
        at date: Date,
        isTaken: (URL) -> Bool
    ) -> URL {
        let directory = archiveURL.deletingLastPathComponent()
        let base = archiveURL.deletingPathExtension().lastPathComponent
        let fileExtension = archiveURL.pathExtension.isEmpty ? "json" : archiveURL.pathExtension
        let stamp = preservedCopyTimestampFormatter.string(from: date)

        var attempt = 0
        while true {
            let suffix = attempt == 0 ? "" : "-\(attempt + 1)"
            let candidate = directory
                .appendingPathComponent("\(base).corrupt-\(stamp)\(suffix)")
                .appendingPathExtension(fileExtension)
            if candidate.standardizedFileURL != archiveURL.standardizedFileURL,
               !isTaken(candidate) {
                return candidate
            }
            attempt += 1
        }
    }

    private static let preservedCopyTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    /// The outcome of moving an unreadable archive aside.
    ///
    /// Both cases mean the same thing to the caller's *state*: the archive path
    /// is clear, so the next save can land. They differ only in what the caller
    /// can honestly say about it, which is why "nothing was there" is a named
    /// success rather than a nil that reads like a failure.
    enum ArchivePreservation: Equatable, Sendable {
        /// This call moved the unreadable bytes to the given URL.
        case movedAside(URL)
        /// There was nothing on disk left to move. When several windows launch
        /// against the same damaged archive they all reach this code, and every
        /// window after the first finds the file already gone — preserved by a
        /// sibling, not lost.
        case nothingToPreserve
    }

    /// Move an archive this build cannot decode aside so a fresh one can be
    /// written.
    ///
    /// This is an explicit app-level decision, never a side effect of reading:
    /// `loadArchive` must keep failing closed so an ordinary save can never
    /// overwrite state it did not understand. Only an unreadable archive
    /// qualifies — a newer schema is good data this build must leave exactly
    /// where the newer version expects to find it.
    @discardableResult
    func preserveUnreadableArchive(at date: Date = Date()) throws -> ArchivePreservation {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedArchive = nil
            return .nothingToPreserve
        }
        let destination = Self.preservedCopyURL(
            for: fileURL,
            at: date,
            isTaken: { fileManager.fileExists(atPath: $0.path) }
        )
        try fileManager.moveItem(at: fileURL, to: destination)
        // The next read finds no archive and starts an empty one, which is
        // only safe because the original bytes still exist beside it.
        cachedArchive = nil
        return .movedAside(destination)
    }

    func restorationState() throws -> NativeWorkspaceRestorationState {
        try loadArchive().restoration
    }

    func projectState(for projectID: String) throws -> NativeProjectWorkspaceState? {
        try loadArchive().restoration.projects.first { $0.projectID == projectID }
    }

    func saveRestorationState(_ state: NativeWorkspaceRestorationState) throws {
        var archive = try loadArchive()
        archive.restoration = Self.normalized(
            Self.preservingExistingMeshes(from: archive.restoration, in: state),
            meshWorktreeRoot: meshWorktreeRoot
        )
        try persist(archive)
    }

    func saveProjectState(_ state: NativeProjectWorkspaceState, makeSelected: Bool = false) throws {
        guard Self.isValidIdentifier(state.projectID) else {
            throw StoreError.invalidIdentifier
        }

        var archive = try loadArchive()
        var restoration = archive.restoration
        let existing = restoration.projects.first { $0.projectID == state.projectID }
        restoration.projects.removeAll { $0.projectID == state.projectID }
        restoration.projects.append(Self.preservingExistingMeshes(from: existing, in: state))
        if makeSelected {
            restoration.selectedProjectID = state.projectID
        }
        archive.restoration = Self.normalized(restoration, meshWorktreeRoot: meshWorktreeRoot)
        try persist(archive)
    }

    func setSelectedProjectID(_ projectID: String?) throws {
        if let projectID, !Self.isValidIdentifier(projectID) {
            throw StoreError.invalidIdentifier
        }
        var archive = try loadArchive()
        archive.restoration.selectedProjectID = projectID
        archive.restoration = Self.normalized(archive.restoration, meshWorktreeRoot: meshWorktreeRoot)
        try persist(archive)
    }

    func removeProjectState(projectID: String) throws {
        var archive = try loadArchive()
        if let existing = archive.restoration.projects.first(where: { $0.projectID == projectID }) {
            let meshes = existing.panes.filter { $0.surface.kind == .mesh }
            archive.restoration.projects.removeAll { $0.projectID == projectID }
            if !meshes.isEmpty {
                archive.restoration.projects.append(NativeProjectWorkspaceState(
                    projectID: projectID,
                    panes: meshes.map { pane in
                        var pane = pane
                        pane.isMinimized = true
                        return pane
                    }
                ))
            }
        }
        if archive.restoration.selectedProjectID == projectID {
            archive.restoration.selectedProjectID = nil
        }
        try persist(archive)
    }

    /// Explicit Mesh close is the sole operation allowed to tombstone a Mesh
    /// descriptor. Ordinary window/project snapshots always preserve Meshes
    /// they do not own, preventing last-writer data loss across windows.
    func removeMeshState(projectID: String, meshID: String) throws {
        guard Self.isValidIdentifier(projectID), Self.isValidIdentifier(meshID) else {
            throw StoreError.invalidIdentifier
        }
        var archive = try loadArchive()
        guard let index = archive.restoration.projects.firstIndex(where: { $0.projectID == projectID }) else {
            return
        }
        var project = archive.restoration.projects[index]
        project.panes.removeAll { $0.surface.kind == .mesh && $0.id == meshID }
        project.layout.remove(meshID)
        if project.focusedPaneID == meshID { project.focusedPaneID = nil }
        project.updatedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        archive.restoration.projects[index] = project
        try persist(archive)
    }

    func draft(for stableKey: String) throws -> String? {
        let id = Self.storageID(for: stableKey)
        return try loadArchive().drafts.first { $0.id == id }?.text
    }

    func allDrafts() throws -> [NativeAgentChatDraft] {
        try loadArchive().drafts.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveDraft(
        _ text: String,
        stableKey: String,
        projectID: String,
        agentID: String,
        workspacePath: String,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws {
        guard Self.isValidIdentifier(projectID), Self.isValidIdentifier(agentID), !stableKey.isEmpty else {
            throw StoreError.invalidIdentifier
        }

        guard workspacePath.hasPrefix("/") else {
            throw StoreError.invalidWorkspacePath
        }
        let standardizedPath = URL(fileURLWithPath: workspacePath).standardizedFileURL.path

        let textBytes = text.lengthOfBytes(using: .utf8)
        guard textBytes <= Self.maximumDraftBytes else {
            throw StoreError.draftTooLarge(maxBytes: Self.maximumDraftBytes)
        }

        var archive = try loadArchive()
        let id = Self.storageID(for: stableKey)
        archive.drafts.removeAll { $0.id == id }

        if !text.isEmpty {
            archive.drafts.append(
                NativeAgentChatDraft(
                    id: id,
                    projectID: projectID,
                    agentID: agentID,
                    workspacePath: standardizedPath,
                    text: text,
                    updatedAt: max(0, updatedAt)
                )
            )
        }

        archive.drafts = Self.boundedDrafts(archive.drafts, preservingID: text.isEmpty ? nil : id)
        try persist(archive)
    }

    func removeDraft(stableKey: String) throws {
        var archive = try loadArchive()
        let id = Self.storageID(for: stableKey)
        archive.drafts.removeAll { $0.id == id }
        try persist(archive)
    }

    func removeDrafts(projectID: String) throws {
        var archive = try loadArchive()
        archive.drafts.removeAll { $0.projectID == projectID }
        try persist(archive)
    }

    /// Forces the next read to come from disk. Primarily useful after an external app
    /// update or in tests; normal callers should benefit from the actor-local cache.
    func invalidateCache() {
        cachedArchive = nil
    }

    private func loadArchive() throws -> Archive {
        if let cachedArchive {
            return cachedArchive
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            let archive = Archive.empty
            cachedArchive = archive
            return archive
        }

        try validateRegularFile(at: fileURL)
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumArchiveBytes {
            throw StoreError.archiveTooLarge(maxBytes: Self.maximumArchiveBytes)
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let header: ArchiveHeader
        do {
            header = try decoder.decode(ArchiveHeader.self, from: data)
        } catch {
            // Schema 2 contains the only durable path/branch identity for
            // potentially unintegrated Mesh work. Never reinterpret corruption
            // as an empty archive that a later save may overwrite.
            throw StoreError.corruptArchive
        }
        guard header.schemaVersion >= Self.minimumReadableSchemaVersion,
              header.schemaVersion <= Self.schemaVersion else {
            // Do not interpret or overwrite a newer app's state after downgrade.
            throw StoreError.unsupportedSchema(found: header.schemaVersion)
        }

        let decoded: Archive
        do {
            decoded = try decoder.decode(Archive.self, from: data)
        } catch {
            throw StoreError.corruptArchive
        }

        var archive = decoded
        archive.schemaVersion = Self.schemaVersion
        archive.restoration = Self.normalized(decoded.restoration, meshWorktreeRoot: meshWorktreeRoot)
        archive.drafts = Self.boundedDrafts(decoded.drafts, preservingID: nil)
        cachedArchive = archive
        return archive
    }

    private func persist(_ candidate: Archive) throws {
        var archive = candidate
        archive.schemaVersion = Self.schemaVersion
        archive.restoration = Self.normalized(candidate.restoration, meshWorktreeRoot: meshWorktreeRoot)
        archive.drafts = Self.boundedDrafts(candidate.drafts, preservingID: nil)

        let data = try encoder.encode(archive)
        guard data.count <= Self.maximumArchiveBytes else {
            throw StoreError.archiveTooLarge(maxBytes: Self.maximumArchiveBytes)
        }

        try ensurePrivateParentDirectory()
        if fileManager.fileExists(atPath: fileURL.path) {
            try validateRegularFile(at: fileURL)
        }

        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            if chmod(temporaryURL.path, mode_t(0o600)) != 0 {
                throw CocoaError(.fileWriteNoPermission)
            }
            if rename(temporaryURL.path, fileURL.path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
            cachedArchive = archive
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func ensurePrivateParentDirectory() throws {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw StoreError.unsafePath }
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() else {
                throw StoreError.unsafePath
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }

        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func validateRegularFile(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & mode_t(0o077)) == 0 else {
            throw StoreError.unsafePath
        }
    }

    private static func normalized(
        _ state: NativeWorkspaceRestorationState,
        meshWorktreeRoot: URL
    ) -> NativeWorkspaceRestorationState {
        var seenProjects = Set<String>()
        let deduplicated = state.projects
            .filter { isValidIdentifier($0.projectID) }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.projectID < rhs.projectID }
                return lhs.updatedAt > rhs.updatedAt
            }
            .filter { seenProjects.insert($0.projectID).inserted }
        // Mesh-bearing projects are recovery manifests, not disposable UI
        // history. Retain all of them within the archive byte cap; only plain
        // UI projects participate in the ordinary 64-project bound.
        let ordinaryIDs = Set(deduplicated
            .filter { !$0.panes.contains(where: { $0.surface.kind == .mesh }) }
            .prefix(maximumProjects)
            .map(\.projectID))
        let candidates = deduplicated.filter {
            $0.panes.contains(where: { $0.surface.kind == .mesh }) || ordinaryIDs.contains($0.projectID)
        }
        var claimedMeshWorktrees = Set<String>()
        var normalizedProjects: [NativeProjectWorkspaceState] = []
        for project in candidates {
            normalizedProjects.append(normalizedProject(
                project,
                meshWorktreeRoot: meshWorktreeRoot,
                claimedMeshWorktrees: &claimedMeshWorktrees
            ))
        }

        let selectedProjectID = state.selectedProjectID.flatMap {
            isValidIdentifier($0) ? $0 : nil
        }
        return NativeWorkspaceRestorationState(
            selectedProjectID: selectedProjectID,
            projects: normalizedProjects
        )
    }

    /// Merge panes by Mesh identity, preferring the incoming descriptor when
    /// its owning window supplied one and retaining the archive's descriptor
    /// otherwise. Preserved panes are hidden from the incoming window layout.
    private static func preservingExistingMeshes(
        from existing: NativeProjectWorkspaceState?,
        in incoming: NativeProjectWorkspaceState
    ) -> NativeProjectWorkspaceState {
        guard let existing else { return incoming }
        var merged = incoming
        var known = Set(merged.panes.filter { $0.surface.kind == .mesh }.map(\.id))
        for oldPane in existing.panes where oldPane.surface.kind == .mesh && known.insert(oldPane.id).inserted {
            var preserved = oldPane
            preserved.isMinimized = true
            merged.panes.append(preserved)
        }
        return merged
    }

    private static func preservingExistingMeshes(
        from existing: NativeWorkspaceRestorationState,
        in incoming: NativeWorkspaceRestorationState
    ) -> NativeWorkspaceRestorationState {
        var merged = incoming
        var incomingMeshIDs = Set(
            merged.projects.flatMap { project in
                project.panes.filter { $0.surface.kind == .mesh }.map(\.id)
            }
        )
        for oldProject in existing.projects {
            let missing = oldProject.panes.filter {
                $0.surface.kind == .mesh && incomingMeshIDs.insert($0.id).inserted
            }
            guard !missing.isEmpty else { continue }
            if let index = merged.projects.firstIndex(where: { $0.projectID == oldProject.projectID }) {
                merged.projects[index].panes.append(contentsOf: missing.map { pane in
                    var preserved = pane
                    preserved.isMinimized = true
                    return preserved
                })
            } else {
                merged.projects.append(NativeProjectWorkspaceState(
                    projectID: oldProject.projectID,
                    panes: missing.map { pane in
                        var preserved = pane
                        preserved.isMinimized = true
                        return preserved
                    }
                ))
            }
        }
        return merged
    }

    private static func normalizedProject(
        _ state: NativeProjectWorkspaceState,
        meshWorktreeRoot: URL,
        claimedMeshWorktrees: inout Set<String>
    ) -> NativeProjectWorkspaceState {
        var seenPaneIDs = Set<String>()
        var seenSurfaceIDs = Set<String>()
        var panes: [NativeRestorablePaneState] = []

        var ordinaryPaneCount = 0
        // Mesh first: an ordinary window snapshot at its visual pane cap must
        // never push a preserved recovery manifest out of the archive.
        let orderedPanes = state.panes.filter { $0.surface.kind == .mesh }
            + state.panes.filter { $0.surface.kind != .mesh }
        for pane in orderedPanes {
            let isMesh = pane.surface.kind == .mesh
            guard (isMesh || ordinaryPaneCount < maximumPanesPerProject),
                  isValidIdentifier(pane.id),
                  pane.surface.projectID == state.projectID,
                  let surface = normalizedSurface(
                    pane.surface,
                    meshWorktreeRoot: meshWorktreeRoot,
                    claimedMeshWorktrees: &claimedMeshWorktrees
                  ),
                  pane.id == surface.id else {
                continue
            }

            let surfaceKey = "\(surface.kind.rawValue)|\(surface.id)"
            guard seenPaneIDs.insert(pane.id).inserted,
                  seenSurfaceIDs.insert(surfaceKey).inserted else {
                continue
            }

            let weight = pane.sizeWeight.isFinite
                ? min(maximumPaneWeight, max(minimumPaneWeight, pane.sizeWeight))
                : 1
            panes.append(
                NativeRestorablePaneState(
                    id: pane.id,
                    surface: surface,
                    sizeWeight: weight,
                    isMinimized: pane.isMinimized
                )
            )
            if !isMesh { ordinaryPaneCount += 1 }
        }

        let focusedPaneID = state.focusedPaneID.flatMap { focused in
            panes.contains { $0.id == focused && !$0.isMinimized } ? focused : nil
        }
        let visiblePaneIDs = Set(panes.lazy.filter { !$0.isMinimized }.map(\.id))
        var layout = state.layout
        layout.normalize(availableSessionIDs: visiblePaneIDs)
        for id in panes.lazy.filter({ !$0.isMinimized }).map(\.id) where !layout.contains(id) {
            layout.add(id)
        }
        if layout.isEmpty, !visiblePaneIDs.isEmpty {
            layout = NativeProjectWorkspaceState.fallbackLayout(
                for: panes,
                arrangement: state.arrangement
            )
        }
        var seenFilePaths = Set<String>()
        var fileTabs = state.fileTabs.compactMap { tab -> NativeRestorableFileTabState? in
            guard seenFilePaths.count < maximumFileTabsPerProject,
                  let path = normalizedRelativePath(tab.relativePath),
                  seenFilePaths.insert(path).inserted else { return nil }
            let line = tab.line.flatMap { $0 > 0 ? min($0, 10_000_000) : nil }
            return NativeRestorableFileTabState(
                relativePath: path,
                isPinned: tab.isPinned,
                line: line
            )
        }
        let transientIndices = fileTabs.indices.filter { !fileTabs[$0].isPinned }
        for index in transientIndices.dropLast() { fileTabs[index].isPinned = true }
        let selectedFilePath = state.selectedFilePath.flatMap(normalizedRelativePath).flatMap { selected in
            fileTabs.contains(where: { $0.relativePath == selected }) ? selected : nil
        }
        return NativeProjectWorkspaceState(
            projectID: state.projectID,
            layout: layout,
            arrangement: state.arrangement,
            panes: panes,
            focusedPaneID: focusedPaneID,
            fileTabs: fileTabs,
            selectedFilePath: selectedFilePath,
            updatedAt: max(0, state.updatedAt)
        )
    }

    private static func normalizedRelativePath(_ raw: String) -> String? {
        guard !raw.isEmpty,
              raw.utf8.count <= 4_096,
              !raw.hasPrefix("/"),
              !raw.hasPrefix("~") else { return nil }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    private static func normalizedSurface(
        _ surface: NativeRestorableSurfaceState,
        meshWorktreeRoot: URL,
        claimedMeshWorktrees: inout Set<String>
    ) -> NativeRestorableSurfaceState? {
        guard isValidIdentifier(surface.id),
              isValidIdentifier(surface.projectID) else {
            return nil
        }

        let title = surface.title.map { String($0.prefix(maximumTitleCharacters)) }
        switch surface.kind {
        case .terminal:
            return NativeRestorableSurfaceState(
                kind: .terminal,
                id: surface.id,
                projectID: surface.projectID,
                title: title
            )
        case .agentChat:
            guard let agentID = surface.agentID,
                  isValidIdentifier(agentID),
                  let workspacePath = surface.workspacePath else {
                return nil
            }
            guard workspacePath.hasPrefix("/") else { return nil }
            let standardizedPath = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
            let accountBinding = surface.accountBinding?.normalized.flatMap { binding in
                SessionAccountBinding.provider(forAgentID: agentID) == binding.provider
                    ? binding
                    : nil
            }
            // A malformed or cross-provider binding invalidates the provider
            // continuation id as well. The transcript can still be restored,
            // but the adapter must begin a fresh thread under current context.
            let canResume = surface.accountBinding == nil || accountBinding != nil
            return NativeRestorableSurfaceState(
                kind: .agentChat,
                id: surface.id,
                projectID: surface.projectID,
                agentID: agentID,
                workspacePath: standardizedPath,
                acpSessionID: canResume ? surface.acpSessionID.flatMap {
                    isValidIdentifier($0) ? $0 : nil
                } : nil,
                accountBinding: accountBinding,
                title: title
            )
        case .mesh:
            guard let descriptor = surface.meshDescriptor,
                  descriptor.id == surface.id,
                  descriptor.projectID == surface.projectID,
                  descriptor.basePath.hasPrefix("/"),
                  NativeSessionStore.projectID(forDirectory: descriptor.basePath) == descriptor.projectID else {
                return nil
            }
            let basePath = URL(fileURLWithPath: descriptor.basePath, isDirectory: true)
                .standardizedFileURL.path
            var seenColumns = Set<String>()
            var seenAgents = Set<String>()
            var columns: [NativeRestorableMeshColumnDescriptor] = []
            for column in descriptor.columns {
                guard isValidIdentifier(column.id),
                      isValidIdentifier(column.agentID),
                      seenColumns.insert(column.id).inserted,
                      seenAgents.insert(column.agentID).inserted else { continue }

                let providerID = column.acpSessionID.flatMap {
                    isValidIdentifier($0) ? $0 : nil
                }
                let accountBinding = column.accountBinding?.normalized.flatMap { binding in
                    SessionAccountBinding.provider(forAgentID: column.agentID) == binding.provider
                        ? binding
                        : nil
                }
                let safeProviderID = column.accountBinding == nil || accountBinding != nil
                    ? providerID
                    : nil
                let baseOID = column.createdBaseOID?.lowercased()
                if let baseOID,
                   baseOID.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) == nil {
                    continue
                }

                let path: String?
                let branch: String?
                let workspaceKind: NativeMeshWorkspaceKind
                if let rawPath = column.worktreePath, let rawBranch = column.branch {
                    let standardized = URL(fileURLWithPath: rawPath, isDirectory: true)
                        .standardizedFileURL.path
                    let expectedPath = meshWorktreeRoot
                        .appendingPathComponent("\(descriptor.id)-\(column.agentID)", isDirectory: true)
                        .standardizedFileURL.path
                    let expectedBranch = "\(GitService.meshBranchPrefix)\(descriptor.id.suffix(6))-\(column.agentID)"
                    guard rawPath.hasPrefix("/"),
                          standardized == expectedPath,
                          rawBranch == expectedBranch,
                          column.role.usesWorktree,
                          baseOID != nil,
                          isDescendant(standardized, of: meshWorktreeRoot.path) else {
                        continue
                    }
                    let pathClaim = "path|\(standardized)"
                    let branchClaim = "branch|\(rawBranch)"
                    guard !claimedMeshWorktrees.contains(pathClaim),
                          !claimedMeshWorktrees.contains(branchClaim) else { continue }
                    claimedMeshWorktrees.insert(pathClaim)
                    claimedMeshWorktrees.insert(branchClaim)
                    path = standardized
                    branch = rawBranch
                    workspaceKind = .worktree
                } else if column.worktreePath == nil, column.branch == nil,
                          baseOID == nil,
                          (!column.role.usesWorktree || column.workspaceKind == .base) {
                    path = nil
                    branch = nil
                    workspaceKind = .base
                } else {
                    continue
                }
                columns.append(NativeRestorableMeshColumnDescriptor(
                    id: column.id,
                    agentID: column.agentID,
                    role: column.role,
                    worktreePath: path,
                    branch: branch,
                    createdBaseOID: baseOID,
                    acpSessionID: safeProviderID,
                    accountBinding: accountBinding,
                    provisioning: column.provisioning,
                    workspaceKind: workspaceKind
                ))
            }
            let normalizedDescriptor = NativeRestorableMeshDescriptor(
                id: descriptor.id,
                projectID: descriptor.projectID,
                basePath: basePath,
                title: String(descriptor.title.prefix(maximumTitleCharacters)),
                mode: descriptor.mode,
                purpose: descriptor.purpose,
                lifecycle: descriptor.lifecycle,
                columns: columns
            )
            return NativeRestorableSurfaceState(mesh: normalizedDescriptor)
        }
    }

    private static func isDescendant(_ path: String, of rootPath: String) -> Bool {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        return candidate.hasPrefix(root + "/")
    }

    private static func boundedDrafts(
        _ drafts: [NativeAgentChatDraft],
        preservingID: String?
    ) -> [NativeAgentChatDraft] {
        var seen = Set<String>()
        var totalBytes = 0
        var result: [NativeAgentChatDraft] = []
        let ordered = drafts.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
            return lhs.updatedAt > rhs.updatedAt
        }

        for draft in ordered {
            guard result.count < maximumDrafts,
                  seen.insert(draft.id).inserted,
                  isValidIdentifier(draft.projectID),
                  isValidIdentifier(draft.agentID),
                  draft.workspacePath.hasPrefix("/"),
                  !draft.text.isEmpty else {
                continue
            }

            let bytes = draft.text.lengthOfBytes(using: .utf8)
            guard bytes <= maximumDraftBytes else { continue }
            if totalBytes + bytes > maximumTotalDraftBytes {
                if draft.id == preservingID {
                    // The newly saved draft has priority over older entries. Make room
                    // from the oldest end without ever truncating the user's text.
                    while totalBytes + bytes > maximumTotalDraftBytes,
                          let removed = result.popLast() {
                        totalBytes -= removed.text.lengthOfBytes(using: .utf8)
                    }
                } else {
                    continue
                }
            }

            guard totalBytes + bytes <= maximumTotalDraftBytes else { continue }
            result.append(draft)
            totalBytes += bytes
        }
        return result
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumIdentifierCharacters
            && !value.contains("\0")
            && !value.contains("\n")
            && !value.contains("\r")
    }

    private static func storageID(for stableKey: String) -> String {
        let digest = SHA256.hash(data: Data(stableKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
