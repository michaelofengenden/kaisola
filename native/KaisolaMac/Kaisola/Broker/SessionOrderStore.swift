import Foundation

/// Persists per-project manual session ordering (drag-reorder) in the native
/// application-support directory (never Electron's). Atomic writes, and — since
/// v1.1.11 — a *reported* result: a drag is only durable once the file has
/// actually landed, so `setOrder` answers with what happened rather than
/// swallowing it.
///
/// The old contract mapped every failure to silence. `read()` turned "nothing
/// stored yet", "cannot open the file" and "these bytes are not this format"
/// all into `nil`, and `write` dropped I/O errors on the floor. Two things
/// followed. A carefully arranged list snapped back on the next launch with
/// nothing on screen ever having said the drag was lost. And the *next* drag
/// rebuilt its payload from that `nil`, so it replaced a file whose bytes were
/// still recoverable — including every other project's order.
///
/// Each project's stored list is capped at 500 ids on write to bound file
/// growth; the pure `apply` places stored ids first (in stored order) and
/// appends any unknown/new sessions in their incoming order, ignoring stale
/// stored ids that no longer exist.
struct SessionOrderStore: Sendable {
    private typealias Payload = [String: [String]]

    /// Why a stored catalog cannot be used. Separate from `Catalog` so a save
    /// can carry the reason into the confirmation the user is shown.
    enum Damage: Equatable, Sendable {
        /// The bytes are readable but are not this format.
        case malformed
        /// The file declares a schema this build does not know, so a newer
        /// Kaisola wrote it. Overwriting it silently downgrades that install.
        case forwardVersion(Int)
        /// The file is there and could not be read at all (permissions, I/O).
        case unreadableFile
    }

    /// What is actually on disk.
    enum Catalog: Equatable, Sendable {
        /// Nothing stored yet — the ordinary first-run state, and the only
        /// state a write may start an empty payload from.
        case absent
        case loaded([String: [String]])
        case unreadable(Damage)
    }

    /// What a save did.
    ///
    /// Returned rather than logged: the rail is what draws the manual order, so
    /// it is the only place that can put a failed drag back where it was.
    enum SaveOutcome: Equatable, Sendable {
        /// The order is on disk. `preservedCopy` names the damaged file this
        /// save set aside first, on the path where the user confirmed one.
        case saved(preservedCopy: URL?)
        /// The write failed; the stored order is unchanged. Carries a short
        /// reason in the user's words ("the disk is full").
        case writeFailed(String)
        /// Nothing was written. The stored catalog cannot be read, so saving
        /// would take every other project's order down with it along with
        /// whatever is recoverable in those bytes. Ask, then call again with
        /// `replacingUnreadableCatalog: true`.
        case needsConfirmation(Damage)
    }

    /// The highest on-disk schema this build understands.
    ///
    /// Deliberately *not* written into the file: the payload is still a bare
    /// `{project: [ids]}` map, which every shipped Kaisola can already read, and
    /// adding a version key would make this file unreadable to the build the
    /// user might downgrade to. The key is only looked *for* on the way in, so
    /// a future format that adds one is recognised as newer and preserved
    /// rather than read as garbage.
    static let readableSchemaVersion = 1

    let fileURL: URL
    private let cap = 500

    init(directory: URL = NativePreviewPaths.applicationSupportDirectory) {
        self.fileURL = directory.appendingPathComponent("session-order.json", isDirectory: false)
    }

    /// The stored manual order for a project, or empty if none is stored.
    ///
    /// A damaged catalog reads as empty here on purpose: the sidebar falls back
    /// to the incoming order, which is a fine list to look at. The damage is
    /// reported at the moment it costs the user something — the next drag,
    /// which is when Kaisola would otherwise overwrite it.
    func order(projectID: String) -> [String] {
        guard case let .loaded(payload) = catalog() else { return [] }
        return payload[projectID] ?? []
    }

    /// What the stored file turned out to be. Exposed so a caller can tell
    /// "nothing stored" apart from "stored and unreadable" before writing.
    func catalog() -> Catalog {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return Self.isMissingFile(error) ? .absent : .unreadable(.unreadableFile)
        }
        // Zero bytes is what an interrupted write leaves behind and carries no
        // order to recover, so it is treated as "nothing stored" rather than as
        // damage the user has to answer a dialog about.
        guard !data.isEmpty else { return .absent }
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return .loaded(payload)
        }
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data),
           let declared = probe.declaredVersion,
           declared > Self.readableSchemaVersion {
            return .unreadable(.forwardVersion(declared))
        }
        return .unreadable(.malformed)
    }

    /// Replace the stored order for a project, reporting whether it is durable.
    /// Lists longer than the cap are truncated to the first `cap` ids on write.
    ///
    /// - Parameter replacingUnreadableCatalog: pass `true` only after the user
    ///   has answered the `needsConfirmation` a previous call returned. The
    ///   damaged bytes are moved aside before the new file is written, and if
    ///   they cannot be moved the save fails rather than overwriting the only
    ///   copy of them.
    @discardableResult
    func setOrder(
        projectID: String,
        ids: [String],
        replacingUnreadableCatalog: Bool = false
    ) -> SaveOutcome {
        var payload: Payload
        var preservedCopy: URL?
        switch catalog() {
        case .absent:
            payload = [:]
        case let .loaded(stored):
            payload = stored
        case let .unreadable(damage):
            guard replacingUnreadableCatalog else { return .needsConfirmation(damage) }
            switch preserveUnreadableCatalog() {
            case let .movedAside(destination):
                preservedCopy = destination
            case .nothingToPreserve:
                break
            case .failed:
                return .writeFailed("the unreadable order file could not be set aside")
            }
            payload = [:]
        }
        payload[projectID] = ids.count > cap ? Array(ids.prefix(cap)) : ids
        return write(payload, preservedCopy: preservedCopy)
    }

    /// Reorders `sessions` per the stored `ids`: known ids first in stored
    /// order, then any sessions not present in `ids` appended in their
    /// incoming order. Stale ids (no matching session) are ignored.
    ///
    /// Duplicate ids in `sessions` keep the first record rather than trapping:
    /// this runs on every sidebar render, and a transient duplicate from a
    /// broker reconnect or an observe-only merge must not crash the app.
    nonisolated static func apply(_ ids: [String], to sessions: [BrokerTerminalRecord]) -> [BrokerTerminalRecord] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [BrokerTerminalRecord] = ids.compactMap { byID[$0] }
        // SwiftUI's ForEach requires unique ids, so the unmatched tail must be
        // deduped too, not just the stored-order head: a duplicate incoming id
        // here would otherwise reach ForEach twice (undefined behavior).
        var seen = Set(out.map(\.id))
        for session in sessions where seen.insert(session.id).inserted {
            out.append(session)
        }
        return out
    }

    // MARK: - Disk

    /// Looks only for a declared schema version, so a payload this build cannot
    /// decode can still say whether it is *newer* rather than merely broken.
    /// Every field is optional: the current bare-map format decodes as this
    /// probe with nothing set, which is exactly the "no version declared" case.
    private struct SchemaProbe: Decodable {
        let version: Int?
        let schemaVersion: Int?

        var declaredVersion: Int? { version ?? schemaVersion }
    }

    private enum Preservation {
        case movedAside(URL)
        /// Another window got there first, so there is nothing left to lose.
        case nothingToPreserve
        case failed
    }

    /// Moves an unreadable catalog aside so its bytes survive the replacement.
    ///
    /// Naming is shared with the workspace archive (`preservedCopyURL`) so a
    /// user hunting for recoverable state finds one convention in the folder
    /// rather than two.
    private func preserveUnreadableCatalog(at date: Date = Date()) -> Preservation {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .nothingToPreserve }
        let destination = NativeWorkspaceStateStore.preservedCopyURL(
            for: fileURL,
            at: date,
            isTaken: { FileManager.default.fileExists(atPath: $0.path) }
        )
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            return .movedAside(destination)
        } catch {
            return .failed
        }
    }

    private func write(_ payload: Payload, preservedCopy: URL?) -> SaveOutcome {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .writeFailed(Self.reason(error))
        }
        guard let data = try? JSONEncoder().encode(payload) else {
            return .writeFailed("the order could not be encoded")
        }
        // The temporary name carries a UUID as well as the pid: two writes in
        // flight at once in the same process would otherwise share one scratch
        // path and one could replace the file with the other's half-written
        // bytes.
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        )
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            return .saved(preservedCopy: preservedCopy)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return .writeFailed(Self.reason(error))
        }
    }

    /// A failed write in the user's words. `localizedDescription` is the
    /// fallback rather than the answer: the three failures a sidebar drag
    /// actually meets say what to do about them, and the rest are rare enough
    /// that the system's sentence is better than a guess.
    private static func reason(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError: return "the disk is full"
            case NSFileWriteNoPermissionError: return "Kaisola is not allowed to write there"
            case NSFileWriteVolumeReadOnlyError: return "the volume is read-only"
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ENOSPC): return "the disk is full"
            case Int(EACCES), Int(EPERM): return "Kaisola is not allowed to write there"
            case Int(EROFS): return "the volume is read-only"
            default: break
            }
        }
        return nsError.localizedDescription
    }

    /// "There is no file" — the one read failure that means the store is empty
    /// rather than damaged. Everything else (permissions, I/O) is damage, and
    /// treating it as empty is what let a drag replace a readable file it had
    /// merely failed to open.
    private static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
        }
        return false
    }
}
