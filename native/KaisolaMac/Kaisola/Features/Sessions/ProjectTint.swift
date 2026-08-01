import SwiftUI

/// Project tab tint palette (mirrors the Electron tab colors) and hex↔Color
/// conversion for the persisted `colorHex`.
enum ProjectTint {
    struct Choice {
        let name: String
        let hex: String
    }

    static let choices: [Choice] = [
        Choice(name: "Coral", hex: "C96B6B"),
        Choice(name: "Sage", hex: "5B9A7D"),
        Choice(name: "Amber", hex: "C09155"),
        Choice(name: "Slate", hex: "668DB3"),
        Choice(name: "Teal", hex: "4F948F"),
        Choice(name: "Plum", hex: "806F9D"),
    ]

    static func color(_ hex: String?) -> Color? {
        guard let hex, let value = Int(hex, radix: 16), hex.count == 6 else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Restrained semantic accents for workspace activity: a surface's kind is
/// carried by its own hue rather than by one accent colour standing in for
/// every selected-or-running state. Blue is spoken for elsewhere — it is the
/// working dot in the rail — so nothing here reaches for it.
enum WorkspacePalette {
    static let project = Color(red: 0.50, green: 0.42, blue: 0.60)
    static let terminal = Color(red: 0.25, green: 0.52, blue: 0.48)
    static let chat = Color(red: 0.68, green: 0.46, blue: 0.28)
    static let mesh = Color(red: 0.52, green: 0.39, blue: 0.62)
    static let active = Color(red: 0.31, green: 0.57, blue: 0.43)
}
