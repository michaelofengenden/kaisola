import Foundation

enum SessionPinStoreError: Error, Equatable, LocalizedError, Sendable {
    case unreadableCatalog
    case writeFailed
    case resetFailed

    var errorDescription: String? {
        switch self {
        case .unreadableCatalog:
            "Kaisola could not update session pins because the saved pin catalog is unreadable. The original file was kept; reset the catalog before trying again."
        case .writeFailed:
            "Kaisola could not save the session pin change. Your previous pins are still intact."
        case .resetFailed:
            "Kaisola could not reset the session pin catalog. Its recoverable files were kept."
        }
    }
}

struct SessionPinSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case missing
        case loaded
        case recoveredFromLastKnownGood
        case unreadable
    }

    let pins: Set<String>
    let state: State
}

/// Persists the set of "pinned" session ids — favorites the user floats to the
/// top of their project group (Electron parity) — in the native
/// application-support directory (never Electron's). The primary catalog and
/// a last-known-good recovery copy are replaced atomically. An unreadable
/// primary is never used as an empty mutation base and is only moved aside by
/// the explicit reset API.
struct SessionPinStore: Sendable {
    private struct Payload: Codable, Equatable, Sendable {
        var schemaVersion: Int?
        var pins: [String]

        init(pins: [String]) {
            schemaVersion = SessionPinStore.currentSchemaVersion
            self.pins = pins
        }
    }

    private enum ReadResult {
        case missing
        case loaded(Payload)
        case unreadable
    }

    private static let currentSchemaVersion = 1
    private static let cap = 100

    let fileURL: URL
    private let lastKnownGoodURL: URL

    init(
        fileURL: URL = NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("session-pins.json", isDirectory: false),
        lastKnownGoodURL: URL? = nil
    ) {
        self.fileURL = fileURL
        let extensionSuffix = fileURL.pathExtension.isEmpty ? "" : ".\(fileURL.pathExtension)"
        let stem = fileURL.deletingPathExtension().lastPathComponent
        self.lastKnownGoodURL = lastKnownGoodURL ?? fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).last-known-good\(extensionSuffix)", isDirectory: false)
    }

    /// The current catalog together with its recovery state. A valid primary
    /// always wins. If the primary is missing or unreadable, a valid recovery
    /// copy preserves the last successfully saved pins across relaunches.
    func snapshot() -> SessionPinSnapshot {
        switch read(from: fileURL) {
        case let .loaded(payload):
            return SessionPinSnapshot(pins: Set(payload.pins), state: .loaded)
        case .missing, .unreadable:
            switch read(from: lastKnownGoodURL) {
            case let .loaded(payload):
                return SessionPinSnapshot(
                    pins: Set(payload.pins),
                    state: .recoveredFromLastKnownGood
                )
            case .missing:
                let state: SessionPinSnapshot.State = fileExists(at: fileURL)
                    ? .unreadable
                    : .missing
                return SessionPinSnapshot(pins: [], state: state)
            case .unreadable:
                return SessionPinSnapshot(pins: [], state: .unreadable)
            }
        }
    }

    /// The pinned session ids (membership only; ordering is an internal
    /// eviction detail, not exposed).
    func pins() -> Set<String> {
        snapshot().pins
    }

    func isPinned(_ id: String) -> Bool {
        snapshot().pins.contains(id)
    }

    /// Pin or unpin a session id. Pinning is idempotent and keeps the id's
    /// original insertion position; adding past the cap evicts the oldest pin.
    /// Unpinning an id that isn't pinned is a no-op (no write).
    ///
    /// Mutations fail closed if either the primary catalog or the only recovery
    /// copy is unreadable. The recovery copy is committed before the primary,
    /// so a reported success is durable in both locations; a primary-write
    /// failure attempts to restore the previous recovery copy.
    @discardableResult
    func setPinned(_ id: String, _ pinned: Bool) throws -> Set<String> {
        let primary = read(from: fileURL)
        let recovery = read(from: lastKnownGoodURL)
        let current: Payload

        switch primary {
        case let .loaded(payload):
            current = payload
        case .unreadable:
            throw SessionPinStoreError.unreadableCatalog
        case .missing:
            switch recovery {
            case let .loaded(payload):
                current = payload
            case .missing:
                current = Payload(pins: [])
            case .unreadable:
                throw SessionPinStoreError.unreadableCatalog
            }
        }

        var ids = current.pins
        if pinned {
            guard !ids.contains(id) else { return Set(ids) }
            ids.append(id)
            if ids.count > Self.cap { ids.removeFirst(ids.count - Self.cap) }
        } else {
            let before = ids.count
            ids.removeAll { $0 == id }
            guard ids.count != before else { return Set(ids) }
        }

        let updated = Payload(pins: ids)
        var preservedUnreadableRecoveryURL: URL?

        do {
            if case .unreadable = recovery {
                // The valid primary is authoritative, but never destroy an
                // unreadable sidecar while repairing it.
                preservedUnreadableRecoveryURL = try preserveUnreadableFile(
                    at: lastKnownGoodURL
                )
            }
            try write(updated, to: lastKnownGoodURL)
        } catch {
            throw SessionPinStoreError.writeFailed
        }

        do {
            try write(updated, to: fileURL)
        } catch {
            // Keep the primary authoritative after a failed mutation. Restore
            // the old recovery payload (or remove the newly-created sidecar)
            // so a later primary failure cannot resurrect an unsaved change.
            switch recovery {
            case .missing:
                if case .loaded = primary {
                    try? write(current, to: lastKnownGoodURL)
                } else {
                    try? FileManager.default.removeItem(at: lastKnownGoodURL)
                }
            case .loaded:
                // The primary is authoritative even if a stale recovery copy
                // existed before this mutation.
                try? write(current, to: lastKnownGoodURL)
            case .unreadable:
                try? FileManager.default.removeItem(at: lastKnownGoodURL)
                if let preservedUnreadableRecoveryURL {
                    try? FileManager.default.moveItem(
                        at: preservedUnreadableRecoveryURL,
                        to: lastKnownGoodURL
                    )
                }
            }
            throw SessionPinStoreError.writeFailed
        }

        return Set(ids)
    }

    /// Explicitly start a fresh catalog. Any unreadable primary or recovery
    /// file is moved to a uniquely named sibling first so its exact bytes remain
    /// available for manual recovery. Returns the first preserved URL, if any.
    @discardableResult
    func resetPreservingUnreadableCatalog() throws -> URL? {
        let primary = read(from: fileURL)
        let recovery = read(from: lastKnownGoodURL)
        var firstPreservedURL: URL?

        do {
            if case .unreadable = primary {
                firstPreservedURL = try preserveUnreadableFile(at: fileURL)
            }
            if case .unreadable = recovery {
                let preserved = try preserveUnreadableFile(at: lastKnownGoodURL)
                if firstPreservedURL == nil { firstPreservedURL = preserved }
            }

            let empty = Payload(pins: [])
            try write(empty, to: lastKnownGoodURL)
            try write(empty, to: fileURL)
            return firstPreservedURL
        } catch {
            throw SessionPinStoreError.resetFailed
        }
    }

    private func read(from url: URL) -> ReadResult {
        guard fileExists(at: url) else { return .missing }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return .unreadable
            }
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.schemaVersion == nil || payload.schemaVersion == Self.currentSchemaVersion,
                  payload.pins.count <= Self.cap,
                  Set(payload.pins).count == payload.pins.count
            else {
                return .unreadable
            }
            return .loaded(payload)
        } catch {
            return fileExists(at: url) ? .unreadable : .missing
        }
    }

    private func write(_ payload: Payload, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try JSONEncoder().encode(payload)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if fileExists(at: destination) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func preserveUnreadableFile(at url: URL) throws -> URL {
        let preserved = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).corrupt-\(UUID().uuidString)",
            isDirectory: false
        )
        try FileManager.default.moveItem(at: url, to: preserved)
        return preserved
    }

    private func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
