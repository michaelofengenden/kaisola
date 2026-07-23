import CryptoKit
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

    init(id: String, projectID: String, cwd: String, title: String, createdAt: Int64, agentID: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.cwd = cwd
        self.title = title
        self.createdAt = createdAt
        self.agentID = agentID
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
}

/// Persists the app's broker owner identity and its owned-terminal registry in
/// the native application-support directory (never Electron's). Writes are
/// atomic; a corrupt file degrades to an empty registry rather than a crash.
struct NativeSessionStore: Sendable {
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
    }

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
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func write(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
