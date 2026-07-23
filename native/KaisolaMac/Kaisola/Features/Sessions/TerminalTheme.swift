import AppKit
import SwiftTerm

/// Terminal palettes. The native mode uses the restrained white/near-black
/// canvas and familiar ANSI colors of macOS Terminal. The Kaisola mode retains
/// the Electron renderer's richer ink/paper palette.
enum TerminalTheme {
    struct Palette {
        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor
        let selection: NSColor
        let ansi: [SwiftTerm.Color]
    }

    /// A clean macOS Terminal-like light canvas. System semantic colors are
    /// resolved under the app's effective appearance at application time.
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

    static func palette(light: Bool, mode: TerminalPaletteMode) -> Palette {
        switch mode {
        case .native: light ? nativeLight : nativeDark
        case .kaisola: light ? Self.light : Self.dark
        }
    }

    private static func nativeANSI(dark: Bool) -> [SwiftTerm.Color] {
        let values = dark
            ? [
                0x000000, 0xC91B00, 0x00C200, 0xC7C400,
                0x0225C7, 0xCA30C7, 0x00C5C7, 0xC7C7C7,
                0x686868, 0xFF6E67, 0x5EFB6E, 0xFFFC67,
                0x6871FF, 0xFF77FF, 0x60FDFF, 0xFFFFFF,
            ]
            : [
                0x000000, 0xC23621, 0x25BC24, 0xADAD27,
                0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
                0x818383, 0xFC391F, 0x31E722, 0xEAEC23,
                0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB,
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
