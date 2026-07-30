import AppKit

/// Terminal font family + weight resolution for the native surface, mirroring
/// Electron's Settings → Terminal font controls (`termFontFamily` /
/// `termFontWeight`). Font *size* already flows through
/// `NativePreviewSettings.terminalFontSize`; this adds the family and weight.
///
/// The "System Mono" sentinel maps to `NSFont.monospacedSystemFont` (the SF
/// Mono system face), matching Electron's `ui-monospace` choice. Every other
/// entry is a fixed-pitch family the OS actually has installed. Resolution
/// NEVER fails: an unknown family or weight always degrades to the system mono
/// face so a terminal can always be drawn.
enum TerminalFontOptions {
    /// Sentinel family standing in for `NSFont.monospacedSystemFont`. Always the
    /// first entry in `availableMonospaceFamilies()` and the persisted default.
    static let systemMonoSentinel = "System Mono"

    /// Weight choices offered in Settings, in ascending order. `raw` is the
    /// persisted token; `title` is the human label for the picker.
    static let weightChoices: [(raw: String, title: String)] = [
        ("regular", "Regular"),
        ("medium", "Medium"),
        ("semibold", "Semibold"),
        ("bold", "Bold"),
    ]

    /// Size used only to instantiate probe fonts while classifying families.
    private static let probeSize: CGFloat = 12

    /// The installed monospace (fixed-pitch) font families, sentinel first.
    ///
    /// Starts from `NSFontManager.availableFontFamilies` and keeps only families
    /// whose first face reports `isFixedPitch`, so proportional families (Arial,
    /// Helvetica, …) are excluded. Sorted case-insensitively for a stable menu.
    static func availableMonospaceFamilies() -> [String] {
        let manager = NSFontManager.shared
        let monospace = manager.availableFontFamilies
            .filter { isFixedPitchFamily($0, manager: manager) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [systemMonoSentinel] + monospace
    }

    /// Resolve a concrete `NSFont` for the given family/size/weight.
    ///
    /// - The sentinel, an empty family, or a family the OS can't realize all map
    ///   to `NSFont.monospacedSystemFont(ofSize:weight:)`.
    /// - Otherwise a face is looked up in the family via `NSFontManager` at the
    ///   requested weight (nudged with `convertWeight` when the exact face is
    ///   missing), falling back to the plain face and finally to system mono.
    ///
    /// Guaranteed non-nil: there is always a system mono fallback.
    static func resolveFont(family: String, size: Double, weightRaw: String) -> NSFont {
        let pointSize = CGFloat(size)
        let nsWeight = weight(forRaw: weightRaw)
        let systemFallback = NSFont.monospacedSystemFont(ofSize: pointSize, weight: nsWeight)

        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != systemMonoSentinel else {
            return systemFallback
        }

        let manager = NSFontManager.shared
        let traits: NSFontTraitMask = weightRaw == "bold" ? .boldFontMask : []

        // Primary: direct face lookup in the family at an AppKit weight class.
        if let face = manager.font(
            withFamily: trimmed,
            traits: traits,
            weight: appKitWeight(forRaw: weightRaw),
            size: pointSize
        ) {
            return face
        }

        // Secondary: the family's plain face, nudged toward the requested weight
        // when a heavier one was asked for. `convertWeight` is non-optional — it
        // returns the input font unchanged when it can't go further.
        if let base = NSFont(name: trimmed, size: pointSize) {
            let wantsHeavier = weightRaw == "bold" || weightRaw == "semibold" || weightRaw == "medium"
            return wantsHeavier ? manager.convertWeight(true, of: base) : base
        }

        // Final: unknown/unrealizable family degrades to the system mono face.
        return systemFallback
    }

    /// Map a persisted weight token to an `NSFont.Weight`. Unknown tokens (and
    /// the "regular" default) resolve to `.regular`.
    static func weight(forRaw raw: String) -> NSFont.Weight {
        switch raw {
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        default: return .regular
        }
    }

    /// Map a persisted weight token to AppKit's coarse 0–15 weight class used by
    /// `NSFontManager.font(withFamily:traits:weight:size:)` (5 == regular,
    /// 9 == bold). Unknown tokens resolve to the regular class.
    private static func appKitWeight(forRaw raw: String) -> Int {
        switch raw {
        case "medium": return 6
        case "semibold": return 8
        case "bold": return 9
        default: return 5
        }
    }

    /// Whether a family's first available face is fixed-pitch.
    private static func isFixedPitchFamily(_ family: String, manager: NSFontManager) -> Bool {
        if let members = manager.availableMembers(ofFontFamily: family),
           let firstFaceName = members.first?.first as? String,
           let font = NSFont(name: firstFaceName, size: probeSize) {
            return font.isFixedPitch
        }
        // Some families expose no members array; probe the family name directly.
        if let font = NSFont(name: family, size: probeSize) {
            return font.isFixedPitch
        }
        return false
    }
}
