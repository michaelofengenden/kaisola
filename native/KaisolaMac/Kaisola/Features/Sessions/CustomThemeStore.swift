import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftTerm

/// A user-supplied terminal theme, exactly as it sits in the store: colors as
/// hex strings, nothing pre-parsed. Data-capability only (PR 6): a theme can
/// name no command, no file, and no URL, so the worst an invalid one can do is
/// be refused — and refusal is always visible, never silent.
struct CustomThemeSpec: Codable, Equatable, Identifiable, Sendable {
    struct PaletteSpec: Codable, Equatable, Sendable {
        var background: String
        var foreground: String
        var cursor: String
        var selection: String
        /// Exactly the 16 ANSI slots, `#RRGGBB` or `#RRGGBBAA`.
        var ansi: [String]
    }

    var id: String
    var title: String
    var light: PaletteSpec
    var dark: PaletteSpec

    /// Why this spec cannot be installed, or nil when it can. The message is
    /// the settings row's explanation, so it names the field, not just the
    /// fact — "invalid" with no noun is exactly the degraded state PR 6's
    /// acceptance forbids.
    var validationError: String? {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanID.isEmpty { return "The theme has no id." }
        if cleanID.count > 64 { return "The id must be 64 characters or fewer." }
        if TerminalThemeRegistry.shipped.contains(where: { $0.id == cleanID }) {
            return "\"\(cleanID)\" is a built-in theme's id."
        }
        if cleanID.unicodeScalars.contains(where: { !CharacterSet.alphanumerics.contains($0) && $0 != "-" && $0 != "_" }) {
            return "The id may only use letters, numbers, dashes, and underscores."
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty { return "The theme has no title." }
        if cleanTitle.count > 60 { return "The title must be 60 characters or fewer." }
        for (appearance, palette) in [("light", light), ("dark", dark)] {
            if palette.ansi.count != 16 {
                return "The \(appearance) palette has \(palette.ansi.count) ANSI colors; exactly 16 are required."
            }
            for (name, value) in [
                ("background", palette.background),
                ("foreground", palette.foreground),
                ("cursor", palette.cursor),
                ("selection", palette.selection),
            ] where Self.parseHex(value) == nil {
                return "The \(appearance) \(name) color \"\(value)\" is not #RRGGBB or #RRGGBBAA."
            }
            for value in palette.ansi where Self.parseHex(value) == nil {
                return "The \(appearance) ANSI color \"\(value)\" is not #RRGGBB or #RRGGBBAA."
            }
        }
        return nil
    }

    /// The installable form, or nil when `validationError` is non-nil.
    func asDefinition() -> ThemeDefinition? {
        guard validationError == nil,
              let light = Self.palette(from: light),
              let dark = Self.palette(from: dark) else { return nil }
        return ThemeDefinition(
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            light: light,
            dark: dark
        )
    }

    private static func palette(from spec: PaletteSpec) -> TerminalTheme.Palette? {
        guard let background = color(spec.background),
              let foreground = color(spec.foreground),
              let cursor = color(spec.cursor),
              let selection = color(spec.selection),
              spec.ansi.count == 16 else { return nil }
        var ansi: [SwiftTerm.Color] = []
        for value in spec.ansi {
            guard let parsed = parseHex(value) else { return nil }
            ansi.append(SwiftTerm.Color(
                red: UInt16((parsed.red * 255).rounded()) * 257,
                green: UInt16((parsed.green * 255).rounded()) * 257,
                blue: UInt16((parsed.blue * 255).rounded()) * 257
            ))
        }
        return TerminalTheme.Palette(
            background: background,
            foreground: foreground,
            cursor: cursor,
            selection: selection,
            ansi: ansi
        )
    }

    private static func color(_ hex: String) -> NSColor? {
        guard let parsed = parseHex(hex) else { return nil }
        return NSColor(
            srgbRed: parsed.red,
            green: parsed.green,
            blue: parsed.blue,
            alpha: parsed.alpha
        )
    }

    /// `#RRGGBB` or `#RRGGBBAA`, case-insensitive, leading `#` required so a
    /// stray decimal cannot silently parse as a color.
    static func parseHex(_ value: String)
        -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = String(trimmed.dropFirst())
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy(\.isHexDigit),
              let packed = UInt64(digits, radix: 16) else { return nil }
        if digits.count == 6 {
            return (
                red: CGFloat((packed >> 16) & 0xFF) / 255,
                green: CGFloat((packed >> 8) & 0xFF) / 255,
                blue: CGFloat(packed & 0xFF) / 255,
                alpha: 1
            )
        }
        return (
            red: CGFloat((packed >> 24) & 0xFF) / 255,
            green: CGFloat((packed >> 16) & 0xFF) / 255,
            blue: CGFloat((packed >> 8) & 0xFF) / 255,
            alpha: CGFloat(packed & 0xFF) / 255
        )
    }
}

/// Persists custom terminal themes without ever interpreting unreadable bytes
/// as an empty catalog. Corrupt and forward-version registries are preserved
/// byte-for-byte before an explicit reset is offered, while a process-scoped
/// last-known-good snapshot keeps already-running terminals on their selected
/// palette. Semantically invalid but structurally decodable specs remain in the
/// catalog with their named validation error.
struct CustomThemeStore: Sendable {
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
        var specs: [CustomThemeSpec]
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
                "Terminal themes are read-only until the registry issue is resolved."
            case .resetRequiresPreservedCopy:
                "Kaisola cannot reset terminal themes without a verified recovery copy."
            case let .capacityExceeded(limit):
                "A maximum of \(limit) custom terminal themes is supported."
            case .writeFailed:
                "Kaisola could not save terminal themes. The existing registry was left unchanged."
            }
        }
    }

    private struct CurrentPayload: Codable {
        var version: Int
        var themes: [CustomThemeSpec]
    }

    private struct LegacyPayload: Codable {
        var themes: [CustomThemeSpec]
    }

    /// Store values are deliberately cheap and are constructed at several UI
    /// call sites. A cache keyed by the canonical registry path therefore has
    /// to be process-scoped, not attached to one ephemeral store value.
    private final class RuntimeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var valuesByPath: [String: [CustomThemeSpec]] = [:]

        func value(for path: String) -> [CustomThemeSpec] {
            lock.lock()
            defer { lock.unlock() }
            return valuesByPath[path] ?? []
        }

        func replace(_ specs: [CustomThemeSpec], for path: String) {
            lock.lock()
            defer { lock.unlock() }
            valuesByPath[path] = specs
        }

        func removeValue(for path: String) {
            lock.lock()
            defer { lock.unlock() }
            _ = valuesByPath.removeValue(forKey: path)
        }
    }

    static let schemaVersion = 1
    static let registryIssueID = "terminal-theme-registry"
    private static let runtimeCache = RuntimeCache()
    let fileURL: URL
    /// A terminal has one theme at a time; a dozen candidates is a wardrobe.
    private let cap = 12

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("terminal-themes.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// Every stored spec, valid or not, in insertion order.
    func specs() -> [CustomThemeSpec] {
        load().specs
    }

    func load() -> Snapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            Self.runtimeCache.removeValue(for: cacheKey)
            return Snapshot(specs: [], state: .missing)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            return Snapshot(
                specs: lastKnownGood,
                state: .ioFailure(Self.describe(error))
            )
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
                guard payload.themes.count <= cap else { return unreadableSnapshot(data: data) }
                remember(payload.themes)
                return Snapshot(specs: payload.themes, state: .ready(schemaVersion: 0))
            } catch {
                return unreadableSnapshot(data: data)
            }
        }
        guard let version = rawVersion as? Int, version >= 0 else {
            return unreadableSnapshot(data: data)
        }
        guard version <= Self.schemaVersion else {
            return Snapshot(
                specs: lastKnownGood,
                state: .newerVersion(version, preserve(data))
            )
        }

        do {
            let payload = try JSONDecoder().decode(CurrentPayload.self, from: data)
            guard payload.version == version, payload.themes.count <= cap else {
                return unreadableSnapshot(data: data)
            }
            remember(payload.themes)
            return Snapshot(specs: payload.themes, state: .ready(schemaVersion: version))
        } catch {
            return unreadableSnapshot(data: data)
        }
    }

    func save(_ specs: [CustomThemeSpec]) throws {
        let snapshot = load()
        guard snapshot.state.allowsMutations else { throw StoreError.mutationBlocked }
        guard specs.count <= cap else { throw StoreError.capacityExceeded(cap) }
        try write(specs)
    }

    /// Add or replace by id. Returns the reason the spec cannot ever install
    /// when it is invalid — it is still stored, so the user sees it listed
    /// with that reason instead of wondering where their import went.
    @discardableResult
    func upsert(_ spec: CustomThemeSpec) throws -> String? {
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

    private var cacheKey: String { fileURL.standardizedFileURL.path }

    private var lastKnownGood: [CustomThemeSpec] {
        Self.runtimeCache.value(for: cacheKey)
    }

    private func remember(_ specs: [CustomThemeSpec]) {
        Self.runtimeCache.replace(specs, for: cacheKey)
    }

    private func unreadableSnapshot(data: Data) -> Snapshot {
        Snapshot(specs: lastKnownGood, state: .corrupt(preserve(data)))
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

    private func write(_ specs: [CustomThemeSpec]) throws {
        let payload = CurrentPayload(version: Self.schemaVersion, themes: specs)
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
        remember(specs)
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
