import AppKit
import SwiftTerm

/// Terminal palettes. The native mode keeps the white/near-black canvas of
/// macOS Terminal but uses contrast-safe ANSI roles for dense agent output.
/// The Kaisola mode retains the Electron renderer's richer ink/paper palette.
enum TerminalTheme {
    struct Palette {
        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor
        let selection: NSColor
        let ansi: [SwiftTerm.Color]
    }

    /// Opaque terminal-card chrome derived from the same palette installed in
    /// SwiftTerm. Header and rule opacities tint the palette background with
    /// its own foreground, preserving the active native/Kaisola character
    /// without letting window glass reduce terminal contrast.
    struct PaneChrome {
        let background: NSColor
        let foreground: NSColor
        let headerTintOpacity: Double
        let ruleOpacity: Double
    }

    /// A clean Terminal-like light canvas. Every text-bearing ANSI slot clears
    /// a 4.5:1 contrast target against white; cyan is deliberately a readable
    /// light blue because agent CLIs commonly use it for links and file paths.
    static var nativeLight: Palette {
        Palette(
            background: .textBackgroundColor,
            foreground: .textColor,
            cursor: .textColor,
            selection: .selectedTextBackgroundColor.withAlphaComponent(0.48),
            ansi: nativeANSI(dark: false)
        )
    }

    /// A clean dark terminal canvas, without the extra blue-gray cast of the
    /// product palette.
    static var nativeDark: Palette {
        Palette(
            background: color(0x1E1E1E),
            foreground: color(0xF2F2F2),
            cursor: color(0xF2F2F2),
            selection: color(0x6A8ACD, alpha: 0.38),
            ansi: nativeANSI(dark: true)
        )
    }

    /// DARK_THEME (ink). Values from Terminal.tsx / TERM_SURFACE.ink.
    static var dark: Palette {
        Palette(
            background: color(0x0D0F13),
            foreground: color(0xD6DAE2),
            cursor: color(0xD6DAE2),
            selection: color(0x95A456, alpha: 0.25),
            ansi: [
                term(0x14161C), term(0xE16A6A), term(0x54C08A), term(0xD8A44A),
                term(0x5AA9E6), term(0xA88752), term(0x5EC5C0), term(0xC4C8D2),
                term(0x5A5F6B), term(0xE16A6A), term(0x54C08A), term(0xD8A44A),
                term(0x5AA9E6), term(0xA88752), term(0x5EC5C0), term(0xF3F4F6),
            ]
        )
    }

    /// LIGHT_THEME (paper). ANSI black inverts to paper exactly as the
    /// Electron theme does, so TUIs that paint black panels stay readable.
    static var light: Palette {
        Palette(
            background: color(0xE9EBEF),
            foreground: color(0x21242B),
            cursor: color(0x21242B),
            selection: color(0x5E7030, alpha: 0.18),
            ansi: [
                term(0xEEF0F4), term(0xCF4F4F), term(0x2F9E6B), term(0x9A6B1F),
                term(0x2F86C9), term(0x8A713A), term(0x1F8F88), term(0x3B3F48),
                term(0x8B909D), term(0xCF4F4F), term(0x2F9E6B), term(0x9A6B1F),
                term(0x2F86C9), term(0x8A713A), term(0x1F8F88), term(0x16181D),
            ]
        )
    }

    static func palette(light: Bool, themeID: String) -> Palette {
        let definition = TerminalThemeRegistry.definition(id: themeID)
        return light ? definition.light : definition.dark
    }

    static func paneChrome(light: Bool, themeID: String) -> PaneChrome {
        let palette = palette(light: light, themeID: themeID)
        return PaneChrome(
            background: palette.background,
            foreground: palette.foreground,
            headerTintOpacity: light ? 0.055 : 0.075,
            ruleOpacity: light ? 0.16 : 0.20
        )
    }

    private static func nativeANSI(dark: Bool) -> [SwiftTerm.Color] {
        let values = dark
            ? [
                0x0D1117, 0xFF7B72, 0x7EE787, 0xE3B341,
                0x79C0FF, 0xD2A8FF, 0x7EE7FF, 0xB1BAC4,
                0x8B949E, 0xFFA198, 0xA7F3B6, 0xF2CC60,
                0xA5D6FF, 0xE2C5FF, 0xCFFAFE, 0xF0F6FC,
            ]
            : [
                0x1F2328, 0xCF222E, 0x116329, 0x7D4E00,
                0x0550AE, 0x8250DF, 0x0077B6, 0x57606A,
                0x6E7781, 0xB42318, 0x1A7F37, 0x8A6100,
                0x0969DA, 0xA40EAF, 0x006FAF, 0x24292F,
            ]
        return values.map(term)
    }

    private static func color(_ rgb: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// SwiftTerm's 16-bit-per-channel color.
    private static func term(_ rgb: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((rgb >> 16) & 0xFF) * 257,
            green: UInt16((rgb >> 8) & 0xFF) * 257,
            blue: UInt16(rgb & 0xFF) * 257
        )
    }
}

extension TerminalTheme.Palette {
    /// An ANSI slot as an `NSColor`, for settings previews — kept here so no
    /// UI file has to import SwiftTerm (whose `Color` collides with SwiftUI's).
    func ansiColor(_ index: Int) -> NSColor {
        guard ansi.indices.contains(index) else { return foreground }
        let slot = ansi[index]
        return NSColor(
            srgbRed: CGFloat(slot.red) / 65535,
            green: CGFloat(slot.green) / 65535,
            blue: CGFloat(slot.blue) / 65535,
            alpha: 1
        )
    }
}

/// One terminal theme the app can install: a stable id, a menu title, and a
/// palette per appearance. Shipped themes and validated custom themes meet in
/// this shape, so every consumer downstream of the registry is indifferent to
/// where a theme came from.
struct ThemeDefinition: Identifiable {
    let id: String
    let title: String
    let light: TerminalTheme.Palette
    let dark: TerminalTheme.Palette
}

/// The theme roster: the shipped pair plus every *valid* custom theme, in
/// menu order. PR 6's registry contract in one type — data only (a theme can
/// name no command, no file, no URL), invalid entries degrade to a disabled
/// row with the reason (`CustomThemeStore` reports those separately), and an
/// unknown or since-removed id resolves to the shipped default rather than a
/// crash or a blank terminal.
enum TerminalThemeRegistry {
    /// "native" and "kaisola" are the two historical `TerminalPaletteMode`
    /// raw values; keeping them as the shipped ids is what lets an existing
    /// install's persisted choice keep meaning the same thing with no
    /// migration step. Computed, not stored, for the same strict-concurrency
    /// reason every `TerminalTheme` palette is: `NSColor` is not `Sendable`.
    static var shipped: [ThemeDefinition] { [
        ThemeDefinition(
            id: "native",
            title: "macOS Terminal",
            light: TerminalTheme.nativeLight,
            dark: TerminalTheme.nativeDark
        ),
        ThemeDefinition(
            id: "kaisola",
            title: "Kaisola",
            light: TerminalTheme.light,
            dark: TerminalTheme.dark
        ),
    ] }

    static func all(store: CustomThemeStore = CustomThemeStore()) -> [ThemeDefinition] {
        shipped + store.specs().compactMap { $0.asDefinition() }
    }

    static func definition(
        id: String,
        store: CustomThemeStore = CustomThemeStore()
    ) -> ThemeDefinition {
        if let shipped = shipped.first(where: { $0.id == id }) { return shipped }
        if let custom = store.specs().first(where: { $0.id == id })?.asDefinition() {
            return custom
        }
        return shipped[0]
    }
}
