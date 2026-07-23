import SwiftUI

/// Project tab tint palette (mirrors the Electron tab colors) and hex↔Color
/// conversion for the persisted `colorHex`.
enum ProjectTint {
    struct Choice {
        let name: String
        let hex: String
    }

    static let choices: [Choice] = [
        Choice(name: "Red", hex: "E16A6A"),
        Choice(name: "Green", hex: "54C08A"),
        Choice(name: "Yellow", hex: "D8A44A"),
        Choice(name: "Blue", hex: "5AA9E6"),
        Choice(name: "Teal", hex: "5EC5C0"),
        Choice(name: "Purple", hex: "A88752"),
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
