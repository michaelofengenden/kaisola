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
}

/// Persists the app's broker owner identity and its owned-terminal registry in
/// the native application-support directory (never Electron's). Writes are
/// atomic; a corrupt file degrades to an empty registry rather than a crash.
struct NativeSessionStore: Sendable {
    private struct Payload: Codable {
        var ownerID: String
        var sessions: [NativeOwnedSession]
    }

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
