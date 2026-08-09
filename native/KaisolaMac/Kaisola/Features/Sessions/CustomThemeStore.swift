import AppKit
import Foundation
import SwiftTerm

/// A user-supplied terminal theme, exactly as it sits in the store: colors as
/// hex strings, nothing pre-parsed. Data-capability only (PR 6): a theme can
/// name no command, no file, and no URL, so the worst an invalid one can do is
/// be refused — and refusal is always visible, never silent.
struct CustomThemeSpec: Codable, Equatable, Identifiable {
    struct PaletteSpec: Codable, Equatable {
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

/// Why the stored theme registry could not be read in full.
///
/// The store used to map every read failure to nil, which made "this file is
/// damaged" indistinguishable from "you have no themes yet" — and then the next
/// ordinary edit rebuilt the file from that empty view, destroying the bytes
/// that could have explained it. Each case names what happened and, just as
/// importantly, whether Kaisola is allowed to move the file aside.
enum CustomThemeStoreFailure: Equatable, Sendable {
    /// The bytes are not a theme registry this build can decode at all.
    case corruptFile
    /// The registry decoded, but some of the themes inside it did not.
    case damagedRecords(kept: Int, dropped: Int)
    /// Written by a newer Kaisola: good data this build must not reinterpret.
    case newerVersion(schemaVersion: Int)
    /// Present, but this process cannot read it — permissions, a directory in
    /// its place, a volume that went away.
    case unreadable(reason: String)

    /// Whether Kaisola may move this file aside on its own before writing.
    /// Only bytes this build cannot use qualify; a newer version's registry
    /// stays exactly where that version expects to find it.
    var allowsQuarantine: Bool {
        switch self {
        case .corruptFile, .damagedRecords: true
        case .newerVersion, .unreadable: false
        }
    }

    var title: String {
        switch self {
        case .corruptFile: "Saved Themes Couldn't Be Read"
        case .damagedRecords: "Some Saved Themes Couldn't Be Read"
        case .newerVersion: "Saved by a Newer Version of Kaisola"
        case .unreadable: "Saved Themes Couldn't Be Opened"
        }
    }

    var message: String {
        switch self {
        case .corruptFile:
            "Kaisola couldn't read your saved themes. The file is untouched — "
                + "repairing keeps a copy of it beside the original and saves a fresh one."
        case .damagedRecords(let kept, let dropped):
            "\(dropped) of \(kept + dropped) saved themes are damaged and can't be "
                + "listed. The file is untouched — repairing keeps a copy of it beside "
                + "the original and saves the \(kept) that still load."
        case .newerVersion(let schemaVersion):
            "These themes were saved by a newer version of Kaisola (data format "
                + "\(schemaVersion)). They're left untouched so that version can still "
                + "read them, which means theme changes here aren't being saved."
        case .unreadable(let reason):
            "Kaisola couldn't open your themes file because \(reason). It's untouched, "
                + "so theme changes here aren't being saved."
        }
    }
}

/// The last theme set this process read cleanly from each registry file.
///
/// `CustomThemeStore` is a value type that every consumer re-creates on the
/// spot, so the memory of a good read has to live beside it. Without this, a
/// file that goes unreadable mid-session empties the theme menu of a running
/// app that was rendering those themes a second ago — which is exactly the
/// "all my themes disappeared" report this whole path guards against.
final class LastGoodCustomThemes: @unchecked Sendable {
    static let shared = LastGoodCustomThemes()

    private let lock = NSLock()
    private var byPath: [String: [CustomThemeSpec]] = [:]

    func record(_ specs: [CustomThemeSpec], for fileURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        byPath[fileURL.standardizedFileURL.path] = specs
    }

    func specs(for fileURL: URL) -> [CustomThemeSpec]? {
        lock.lock()
        defer { lock.unlock() }
        return byPath[fileURL.standardizedFileURL.path]
    }

    /// Drop the memory of one file. Tests share this process with everything
    /// else in the suite, so a store that wants "nothing loaded yet" has to be
    /// able to say so.
    func forget(_ fileURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        byPath[fileURL.standardizedFileURL.path] = nil
    }
}

/// Persists custom terminal themes to the native application-support
/// directory. Atomic writes, capped, invalid specs *kept* so the settings row
/// can explain them — the same recipe as `CustomAgentStore`/`PermissionRuleStore`
/// with one deliberate difference: a file this build cannot read is never
/// silently replaced. It is quarantined beside the original first, and until
/// that happens the running app keeps showing the last themes it loaded.
struct CustomThemeStore: Sendable {
    /// Schema 1 is the original shape; files written before the version key
    /// existed have exactly that shape, so an absent key *is* schema 1. Older
    /// builds ignore the extra key, which keeps a downgrade readable.
    static let schemaVersion = 1

    private struct Payload: Codable {
        var schemaVersion: Int
        var themes: [CustomThemeSpec]
    }

    /// Decodes the registry one theme at a time so a single malformed record
    /// costs that record, not the whole wardrobe.
    private struct StoredRegistry: Decodable {
        let schemaVersion: Int
        let themes: [CustomThemeSpec]
        let droppedRecords: Int

        private struct Record: Decodable {
            let spec: CustomThemeSpec?
            init(from decoder: Decoder) throws {
                spec = try? CustomThemeSpec(from: decoder)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case themes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? CustomThemeStore.schemaVersion
            let records = try container.decode([Record].self, forKey: .themes)
            themes = records.compactMap(\.spec)
            droppedRecords = records.count - themes.count
        }
    }

    /// What a read produced: the themes the app should use, plus the reason the
    /// file could not be read in full when there is one.
    struct Load: Equatable, Sendable {
        /// Every usable stored spec, valid or not, in insertion order.
        var specs: [CustomThemeSpec]
        /// Why the file could not be read in full, or nil when it read cleanly.
        var failure: CustomThemeStoreFailure?
        /// True when `specs` are themes this process loaded earlier rather than
        /// what is on disk now.
        var isStale: Bool

        static let empty = Load(specs: [], failure: nil, isStale: false)
    }

    /// What a write did. "Nothing was written" is a named outcome rather than a
    /// silent return, because the settings card has to say so.
    enum SaveOutcome: Equatable, Sendable {
        case saved
        /// The unreadable file was preserved at this URL, then the save landed.
        case savedAfterQuarantine(preservedCopy: URL)
        /// Nothing was written; the stored file is untouched.
        case refused(CustomThemeStoreFailure)
        /// The write itself failed — a read-only volume, a full disk.
        case writeFailed(reason: String)

        var didSave: Bool {
            switch self {
            case .saved, .savedAfterQuarantine: true
            case .refused, .writeFailed: false
            }
        }
    }

    /// An upsert reports two independent things: whether the spec can ever
    /// install, and whether it reached disk. Collapsing them would hide a
    /// failed write behind a valid theme.
    struct UpsertResult: Equatable, Sendable {
        var outcome: SaveOutcome
        /// Why the spec cannot ever install, or nil when it can.
        var validationError: String?
    }

    let fileURL: URL
    /// A terminal has one theme at a time; a dozen candidates is a wardrobe.
    private let cap = 12

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("terminal-themes.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// Every stored spec, valid or not, in insertion order. An unreadable file
    /// yields the last set this process loaded, never an empty registry that a
    /// later save would make permanent.
    func specs() -> [CustomThemeSpec] {
        load().specs
    }

    func load() -> Load {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError {
            // No file yet is the ordinary first-launch state, not damage.
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
                return .empty
            }
            return degraded(.unreadable(reason: error.localizedDescription))
        }
        guard let stored = try? JSONDecoder().decode(StoredRegistry.self, from: data) else {
            return degraded(.corruptFile)
        }
        guard stored.schemaVersion <= Self.schemaVersion else {
            return degraded(.newerVersion(schemaVersion: stored.schemaVersion))
        }
        LastGoodCustomThemes.shared.record(stored.themes, for: fileURL)
        guard stored.droppedRecords == 0 else {
            return Load(
                specs: stored.themes,
                failure: .damagedRecords(kept: stored.themes.count, dropped: stored.droppedRecords),
                isStale: false
            )
        }
        return Load(specs: stored.themes, failure: nil, isStale: false)
    }

    @discardableResult
    func save(_ specs: [CustomThemeSpec]) -> SaveOutcome {
        let capped = specs.count > cap ? Array(specs.prefix(cap)) : specs
        var preservedCopy: URL?
        if let failure = load().failure {
            guard failure.allowsQuarantine else { return .refused(failure) }
            do {
                preservedCopy = try quarantine()
            } catch {
                return .writeFailed(reason: (error as NSError).localizedDescription)
            }
        }
        do {
            try write(Payload(schemaVersion: Self.schemaVersion, themes: capped))
        } catch {
            return .writeFailed(reason: (error as NSError).localizedDescription)
        }
        LastGoodCustomThemes.shared.record(capped, for: fileURL)
        guard let preservedCopy else { return .saved }
        return .savedAfterQuarantine(preservedCopy: preservedCopy)
    }

    /// Add or replace by id. An invalid spec is still stored, so the user sees
    /// it listed with its reason instead of wondering where the import went.
    @discardableResult
    func upsert(_ spec: CustomThemeSpec) -> UpsertResult {
        var current = specs()
        if let index = current.firstIndex(where: { $0.id == spec.id }) {
            current[index] = spec
        } else {
            current.append(spec)
        }
        return UpsertResult(outcome: save(current), validationError: spec.validationError)
    }

    /// Nil when no stored theme had that id — nothing was attempted, which is
    /// not the same thing as a write that failed.
    @discardableResult
    func remove(id: String) -> SaveOutcome? {
        let current = specs()
        let remaining = current.filter { $0.id != id }
        guard remaining.count != current.count else { return nil }
        return save(remaining)
    }

    /// Move a registry this build cannot read aside so a fresh one can be
    /// written. Nil means there was nothing left to move: a sibling window that
    /// hit the same damage first already preserved the bytes.
    ///
    /// This is only ever an explicit step on the way to a write. Reading keeps
    /// failing closed, so no menu render can quietly rename the user's file.
    @discardableResult
    func quarantine(at date: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return nil }
        // The workspace archive already solved "preserve these bytes beside the
        // original, never onto a name that is taken"; one naming rule for both
        // means one `.corrupt-<timestamp>` convention in the support folder.
        let destination = NativeWorkspaceStateStore.preservedCopyURL(
            for: fileURL,
            at: date,
            isTaken: { manager.fileExists(atPath: $0.path) }
        )
        try manager.moveItem(at: fileURL, to: destination)
        return destination
    }

    private func degraded(_ failure: CustomThemeStoreFailure) -> Load {
        // Staleness is about themes still on screen; remembering an empty
        // registry leaves the settings row nothing extra to explain.
        let lastGood = LastGoodCustomThemes.shared.specs(for: fileURL) ?? []
        return Load(specs: lastGood, failure: failure, isStale: !lastGood.isEmpty)
    }

    private func write(_ payload: Payload) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(payload)
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
