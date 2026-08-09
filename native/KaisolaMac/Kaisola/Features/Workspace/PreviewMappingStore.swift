import CryptoKit
import Darwin
import Foundation

/// A user mapping from file extensions to one of the preview's *text* kinds.
/// Deliberately narrower than the preview itself: image, PDF, and docx run
/// dedicated loaders with their own size caps and parsers, and letting a
/// mapping route arbitrary bytes into those loaders would be new attack
/// surface. Every mappable kind flows through the same size cap, binary
/// sniff, and text decode as plain text — a wrong mapping can only ever
/// mis-*style* a file, never mis-parse it.
struct PreviewMappingSpec: Codable, Equatable, Identifiable, Sendable {
    /// The kinds a mapping may choose. Raw values are what the JSON says.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case text, markdown, csv, json, html
    }

    var id: String
    var extensions: [String]
    var kind: String

    static let maximumExtensions = 16

    var validationError: String? {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanID.isEmpty { return "The mapping has no id." }
        if cleanID.count > 64 { return "The id must be 64 characters or fewer." }
        if cleanID.unicodeScalars.contains(where: { !CharacterSet.alphanumerics.contains($0) && $0 != "-" && $0 != "_" }) {
            return "The id may only use letters, numbers, dashes, and underscores."
        }
        if Kind(rawValue: kind) == nil {
            let names = Kind.allCases.map(\.rawValue).joined(separator: ", ")
            return "\"\(kind)\" is not a preview kind (\(names))."
        }
        if extensions.isEmpty { return "The mapping claims no file extensions." }
        if extensions.count > Self.maximumExtensions {
            return "A mapping may claim at most \(Self.maximumExtensions) extensions."
        }
        for ext in extensions {
            let clean = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if clean.isEmpty || clean.count > 12
                || clean.unicodeScalars.contains(where: { !CharacterSet.alphanumerics.contains($0) }) {
                return "\"\(ext)\" is not a usable file extension (letters and numbers, 12 characters or fewer, no dot)."
            }
        }
        return nil
    }

    var normalizedExtensions: [String] {
        extensions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}

/// Persists preview mappings without interpreting an unreadable registry as an
/// empty one. Corrupt and forward-version files are copied byte-for-byte before
/// the store offers an explicit reset; ordinary mutations stay fenced until
/// then. Built-in classifications always win before a mapping is consulted, so
/// a mapping can never take over `.json`, an image, or the binary sniff.
struct PreviewMappingStore: Sendable {
    enum Preservation: Equatable, Sendable {
        case preserved(URL)
        case failed(String)
    }

    enum LoadState: Equatable, Sendable {
        case missing
        case ready(schemaVersion: Int)
        case corrupt(Preservation)
        case newerVersion(Int, Preservation)
        case ioFailure(String)

        var allowsMutations: Bool {
            switch self {
            case .missing, .ready: true
            case .corrupt, .newerVersion, .ioFailure: false
            }
        }

        var canReset: Bool {
            switch self {
            case .corrupt(.preserved), .newerVersion(_, .preserved): true
            case .missing, .ready, .corrupt(.failed), .newerVersion(_, .failed), .ioFailure: false
            }
        }

        var preservedCopyURL: URL? {
            switch self {
            case let .corrupt(.preserved(url)), let .newerVersion(_, .preserved(url)): url
            case .missing, .ready, .corrupt(.failed), .newerVersion(_, .failed), .ioFailure: nil
            }
        }
    }

    struct Snapshot: Equatable, Sendable {
        var specs: [PreviewMappingSpec]
        var state: LoadState
    }

    enum StoreError: LocalizedError, Equatable, Sendable {
        case mutationBlocked
        case resetRequiresPreservedCopy
        case capacityExceeded(Int)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .mutationBlocked:
                "Preview mappings are read-only until the registry issue is resolved."
            case .resetRequiresPreservedCopy:
                "Kaisola cannot reset preview mappings without a verified recovery copy."
            case let .capacityExceeded(limit):
                "A maximum of \(limit) preview mappings is supported."
            case .writeFailed:
                "Kaisola could not save preview mappings. The existing registry was left unchanged."
            }
        }
    }

    private struct CurrentPayload: Codable {
        var version: Int
        var mappings: [PreviewMappingSpec]
    }

    private struct LegacyPayload: Codable {
        var mappings: [PreviewMappingSpec]
    }

    static let schemaVersion = 1
    static let registryIssueID = "preview-mapping-registry"
    let fileURL: URL
    private let cap = 32

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("preview-mappings.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    func specs() -> [PreviewMappingSpec] {
        load().specs
    }

    func load() -> Snapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return Snapshot(specs: [], state: .missing)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            return Snapshot(specs: [], state: .ioFailure(Self.describe(error)))
        }

        let object: [String: Any]
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return unreadableSnapshot(data: data)
            }
            object = dictionary
        } catch {
            return unreadableSnapshot(data: data)
        }

        guard let rawVersion = object["version"] else {
            do {
                let payload = try JSONDecoder().decode(LegacyPayload.self, from: data)
                guard payload.mappings.count <= cap else { return unreadableSnapshot(data: data) }
                return Snapshot(specs: payload.mappings, state: .ready(schemaVersion: 0))
            } catch {
                return unreadableSnapshot(data: data)
            }
        }
        guard let version = rawVersion as? Int, version >= 0 else {
            return unreadableSnapshot(data: data)
        }
        guard version <= Self.schemaVersion else {
            return Snapshot(
                specs: [],
                state: .newerVersion(version, preserve(data))
            )
        }

        do {
            let payload = try JSONDecoder().decode(CurrentPayload.self, from: data)
            guard payload.version == version, payload.mappings.count <= cap else {
                return unreadableSnapshot(data: data)
            }
            return Snapshot(specs: payload.mappings, state: .ready(schemaVersion: version))
        } catch {
            return unreadableSnapshot(data: data)
        }
    }

    @discardableResult
    func upsert(_ spec: PreviewMappingSpec) throws -> String? {
        let snapshot = load()
        guard snapshot.state.allowsMutations else { throw StoreError.mutationBlocked }
        var current = snapshot.specs
        if let index = current.firstIndex(where: { $0.id == spec.id }) {
            current[index] = spec
        } else {
            current.append(spec)
        }
        guard current.count <= cap else { throw StoreError.capacityExceeded(cap) }
        try write(current)
        return spec.validationError
    }

    @discardableResult
    func remove(id: String) throws -> Bool {
        let snapshot = load()
        guard snapshot.state.allowsMutations else { throw StoreError.mutationBlocked }
        let current = snapshot.specs
        let remaining = current.filter { $0.id != id }
        guard remaining.count != current.count else { return false }
        try write(remaining)
        return true
    }

    @discardableResult
    func resetUnreadableRegistry() throws -> Snapshot {
        let snapshot = load()
        guard snapshot.state.canReset else { throw StoreError.resetRequiresPreservedCopy }
        try write([])
        return Snapshot(specs: [], state: .ready(schemaVersion: Self.schemaVersion))
    }

    /// The kind for an extension, or nil. First valid claim wins, in
    /// insertion order; invalid specs are kept for the settings roster and
    /// skipped here.
    func kind(forExtension ext: String) -> PreviewMappingSpec.Kind? {
        let clean = ext.lowercased()
        for spec in specs() where spec.validationError == nil {
            guard let kind = PreviewMappingSpec.Kind(rawValue: spec.kind) else { continue }
            if spec.normalizedExtensions.contains(clean) { return kind }
        }
        return nil
    }

    private func unreadableSnapshot(data: Data) -> Snapshot {
        Snapshot(specs: [], state: .corrupt(preserve(data)))
    }

    private func preserve(_ data: Data) -> Preservation {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let preservedURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).preserved-\(digest).json", isDirectory: false)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: preservedURL.path) {
            do {
                return try Data(contentsOf: preservedURL) == data
                    ? .preserved(preservedURL)
                    : .failed("A recovery copy with the same fingerprint does not match.")
            } catch {
                return .failed(Self.describe(error))
            }
        }

        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(preservedURL.lastPathComponent).\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: temporary, options: [.withoutOverwriting])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try Self.synchronizeFile(at: temporary)
            do {
                try fileManager.moveItem(at: temporary, to: preservedURL)
            } catch {
                try? fileManager.removeItem(at: temporary)
                guard fileManager.fileExists(atPath: preservedURL.path),
                      try Data(contentsOf: preservedURL) == data else {
                    throw error
                }
            }
            return .preserved(preservedURL)
        } catch {
            try? fileManager.removeItem(at: temporary)
            return .failed(Self.describe(error))
        }
    }

    private func write(_ specs: [PreviewMappingSpec]) throws {
        let payload = CurrentPayload(version: Self.schemaVersion, mappings: specs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw StoreError.writeFailed(Self.describe(error))
        }

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: temporary, options: [.withoutOverwriting])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try Self.synchronizeFile(at: temporary)
            guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw StoreError.writeFailed(Self.describe(error))
        }
    }

    private static func synchronizeFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}
