import Foundation

/// Which project *shows* a terminal, when that differs from the project that
/// owns it — `[terminalID: adoptedProjectID]`.
///
/// The broker bakes the owning project into a terminal's identity twice over:
/// the `owner` capability string and the `terminalID` itself
/// (`term-<projectID>-<uuid>`), so a true reparent is not safely doable
/// client-side. Adoption is therefore an overlay: presentation reads it,
/// every broker RPC keeps addressing the real `projectID`, and removing the
/// entry returns the terminal home — reversibility is deleting one row.
///
/// Standard store recipe: capped, atomic replace, corrupt → empty.
struct SessionAdoptionStore: Sendable {
    private struct Payload: Codable {
        var adoptions: [String: String]
    }

    let fileURL: URL
    /// More adopted terminals than this is a workspace nobody can read.
    private let cap = 64

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("session-adoptions.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    func adoptions() -> [String: String] {
        read()?.adoptions ?? [:]
    }

    /// Record that `terminalID` is shown in `projectID`. Overwrites any prior
    /// adoption; capped by dropping the newcomer when full (a silent eviction
    /// of an older adoption would teleport some other terminal).
    @discardableResult
    func adopt(terminalID: String, into projectID: String) -> Bool {
        var current = adoptions()
        if current[terminalID] == nil, current.count >= cap { return false }
        guard current[terminalID] != projectID else { return true }
        current[terminalID] = projectID
        write(Payload(adoptions: current))
        return true
    }

    /// Return a terminal to its real project.
    @discardableResult
    func clear(terminalID: String) -> Bool {
        var current = adoptions()
        guard current.removeValue(forKey: terminalID) != nil else { return false }
        write(Payload(adoptions: current))
        return true
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
