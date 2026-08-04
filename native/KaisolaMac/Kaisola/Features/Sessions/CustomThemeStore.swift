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

/// Persists custom terminal themes to the native application-support
/// directory. Atomic writes, corrupt file → empty, capped — the same recipe as
/// `CustomAgentStore`/`PermissionRuleStore`. Invalid specs are *kept*: the
/// registry skips them, the settings row explains them, and removal stays one
/// click — which is what "degrade to disabled with an actionable explanation"
/// means for a store.
struct CustomThemeStore: Sendable {
    private struct Payload: Codable {
        var themes: [CustomThemeSpec]
    }

    let fileURL: URL
    /// A terminal has one theme at a time; a dozen candidates is a wardrobe.
    private let cap = 12

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("terminal-themes.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// Every stored spec, valid or not, in insertion order.
    func specs() -> [CustomThemeSpec] {
        read()?.themes ?? []
    }

    func save(_ specs: [CustomThemeSpec]) {
        let capped = specs.count > cap ? Array(specs.prefix(cap)) : specs
        write(Payload(themes: capped))
    }

    /// Add or replace by id. Returns the reason the spec cannot ever install
    /// when it is invalid — it is still stored, so the user sees it listed
    /// with that reason instead of wondering where their import went.
    @discardableResult
    func upsert(_ spec: CustomThemeSpec) -> String? {
        var current = specs()
        if let index = current.firstIndex(where: { $0.id == spec.id }) {
            current[index] = spec
        } else {
            current.append(spec)
        }
        save(current)
        return spec.validationError
    }

    @discardableResult
    func remove(id: String) -> Bool {
        let current = specs()
        let remaining = current.filter { $0.id != id }
        guard remaining.count != current.count else { return false }
        save(remaining)
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
