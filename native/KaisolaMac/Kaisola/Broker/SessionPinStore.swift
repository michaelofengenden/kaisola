import Foundation

/// Persists the set of "pinned" session ids — favorites the user floats to the
/// top of their project group (Electron parity) — in the native
/// application-support directory (never Electron's). Atomic writes, an ordered
/// array so the cap can evict the oldest pin first, and callers observe a `Set`.
///
/// A file this build cannot read is preserved, never reinterpreted. The store
/// used to answer every read failure with nil and swallow every write error,
/// which read as "nothing is pinned": the sidebar quietly unpinned everything
/// and the next ordinary pin wrote that emptiness over the only record of the
/// user's choices. Reads now say which of the three things happened (no file
/// yet, a readable set, damage), and writes refuse to land on bytes this build
/// could not decode until the user explicitly resets.
struct SessionPinStore: Sendable {
    private struct Payload: Codable {
        var pins: [String]
    }

    /// Why a pin file that exists could not be turned into a pin set.
    enum LoadFailure: Error, Equatable, Sendable {
        /// The bytes are there but this build cannot decode them.
        case corrupt
        /// Present and possibly intact, but unreadable here (permissions, a
        /// directory in its place, an I/O error).
        case unreadable(reason: String)

        /// The clause that finishes "Pinned sessions can't be saved because …".
        var message: String {
            switch self {
            case .corrupt:
                "the saved pins file is damaged"
            case .unreadable(let reason):
                "the saved pins file couldn't be read (\(reason))"
            }
        }

        /// What the user is told, whether the damage turned up on launch or
        /// under a pin they just clicked. Both mean the same thing: pins stay
        /// as they are until the file is reset.
        var notice: String {
            "Pinned sessions can't be saved because \(message)."
        }
    }

    /// What a read found. A missing file is a first launch, not damage, so it
    /// is its own case and never reaches the user as a failure.
    enum Load: Equatable, Sendable {
        /// Nothing has been written yet — an empty pin set, benignly.
        case missing
        /// Pins in stored order, oldest first. Ordering is an eviction detail.
        case loaded([String])
        case failed(LoadFailure)

        /// Pin membership, or nil when the file could not be read at all. nil
        /// is not "no pins": callers keep whatever they last knew rather than
        /// degrade the sidebar to unpinned.
        var pins: Set<String>? {
            switch self {
            case .missing: []
            case .loaded(let ids): Set(ids)
            case .failed: nil
            }
        }

        var failure: LoadFailure? {
            guard case .failed(let failure) = self else { return nil }
            return failure
        }
    }

    /// Why a pin or unpin did not reach disk.
    enum WriteFailure: Error, Equatable, Sendable {
        /// The file on disk could not be read, so writing would replace pins
        /// this build never saw. Clearing it takes an explicit reset.
        case wouldOverwriteUnreadableFile(LoadFailure)
        /// Encoding, the scratch write, or the atomic replace failed. The file
        /// on disk is exactly as it was.
        case notPersisted(reason: String)

        /// What the user is told the moment their pin did not stick.
        var message: String {
            switch self {
            case .wouldOverwriteUnreadableFile(let failure):
                failure.notice
            case .notPersisted(let reason):
                "Pinned sessions couldn't be saved: \(reason)."
            }
        }
    }

    /// What became of a pin file this build could not read.
    enum Preservation: Equatable, Sendable {
        /// This call moved the unreadable bytes to the given URL.
        case movedAside(URL)
        /// There was nothing on disk left to move — another window reset first,
        /// or the file was already gone. The path is clear either way.
        case nothingToPreserve
    }

    let fileURL: URL
    private let cap = 100

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("session-pins.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// What is on disk right now, damage included.
    func load() -> Load {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // No file (or no directory) yet: a first launch, not damage.
            return .missing
        } catch {
            return .failed(.unreadable(reason: (error as NSError).localizedDescription))
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .failed(.corrupt)
        }
        return .loaded(payload.pins)
    }

    /// Membership as last written. An unreadable file answers false here, which
    /// is fine for a menu title and never enough for persistence — `setPinned`
    /// consults `load()` itself rather than trusting this.
    func isPinned(_ id: String) -> Bool {
        load().pins?.contains(id) ?? false
    }

    /// Pin or unpin a session id. Pinning is idempotent and keeps the id's
    /// original insertion position; adding past the cap evicts the oldest pin.
    /// Unpinning an id that isn't pinned is a no-op (no write).
    ///
    /// Throws instead of failing quietly: a pin the user asked for either lands
    /// on disk or is reported, and a file this build cannot read is left exactly
    /// where it is rather than replaced from an empty base.
    func setPinned(_ id: String, _ pinned: Bool) throws {
        var ids: [String]
        switch load() {
        case .missing:
            ids = []
        case .loaded(let stored):
            ids = stored
        case .failed(let failure):
            throw WriteFailure.wouldOverwriteUnreadableFile(failure)
        }
        if pinned {
            guard !ids.contains(id) else { return }
            ids.append(id)
            if ids.count > cap { ids.removeFirst(ids.count - cap) }
        } else {
            let before = ids.count
            ids.removeAll { $0 == id }
            guard ids.count != before else { return }
        }
        try write(Payload(pins: ids))
    }

    /// Move a pin file this build cannot read aside so pinning works again,
    /// leaving a fresh, empty set behind.
    ///
    /// Reading never does this on its own: an ordinary pin must not be able to
    /// destroy pins the app failed to decode, so clearing the way is always the
    /// user's decision. The kept copy uses the same naming as a preserved
    /// workspace archive, so one convention explains every kept file in that
    /// folder.
    @discardableResult
    func resetPreservingUnreadableFile(at date: Date = Date()) throws -> Preservation {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .nothingToPreserve
        }
        let destination = NativeWorkspaceStateStore.preservedCopyURL(
            for: fileURL,
            at: date,
            isTaken: { FileManager.default.fileExists(atPath: $0.path) }
        )
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
        } catch {
            throw WriteFailure.notPersisted(reason: (error as NSError).localizedDescription)
        }
        return .movedAside(destination)
    }

    /// The scratch file an atomic write lands in before it replaces the real
    /// one. Named per process so two windows never share a half-written file.
    static func scratchURL(for fileURL: URL, processID: Int32) -> URL {
        fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(processID)")
    }

    private func write(_ payload: Payload) throws {
        let directory = fileURL.deletingLastPathComponent()
        let temporary = Self.scratchURL(
            for: fileURL,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            // A write interrupted anywhere in there leaves the previous pins
            // untouched; drop the scratch file so the next attempt starts clean,
            // then say so rather than pretending the pin stuck.
            try? FileManager.default.removeItem(at: temporary)
            throw WriteFailure.notPersisted(reason: (error as NSError).localizedDescription)
        }
    }
}
