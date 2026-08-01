import SwiftUI

/// The five-state "Quiet fleet" status grammar. Idle and ended draw no dot;
/// silence is information (spec: quiet-fleet v2.3).
enum QuietSessionStatus: Equatable {
    case needsYou, working, doneUnseen, failed, idle, ended

    static func terminal(activity: AgentActivity, exited: Bool, hasAttention: Bool, respondedAcknowledged: Bool) -> QuietSessionStatus {
        if exited { return .ended }
        if hasAttention { return .needsYou }
        switch activity {
        case .working: return .working
        case .responded: return respondedAcknowledged ? .idle : .doneUnseen
        case .idle: return .idle
        }
    }

    /// A disconnected chat is always `.ended`, never `.failed`.
    ///
    /// `AcpConversation` publishes a `statusMessage` on clean exits as well as
    /// crashes ("agent exited", "session ended", …), so a non-nil message
    /// cannot distinguish "the agent finished" from "the agent died" and every
    /// finished chat painted red. `.failed` therefore stays in the enum but is
    /// currently produced by no derivation: the published state carries no
    /// crash signal today. Revisit post-merge when the chat crash-recovery
    /// rework lands — `statusMessage` stays on this signature as the seam that
    /// will carry that signal.
    static func chat(isRunning: Bool, isConnected: Bool, hasPendingPermission: Bool, hasAttention: Bool, statusMessage: String?) -> QuietSessionStatus {
        if hasPendingPermission || hasAttention { return .needsYou }
        if !isConnected { return .ended }
        return isRunning ? .working : .idle
    }

    static func mesh(stageIsIdle: Bool, hasAttention: Bool) -> QuietSessionStatus {
        if hasAttention { return .needsYou }
        return stageIsIdle ? .idle : .working
    }

    /// nil for idle/ended — no dot is drawn.
    var dotColor: Color? {
        guard let hexes = QuietStatusPalette.hexes(for: self) else { return nil }
        return Color(light: hexes.light, dark: hexes.dark)
    }

    var accessibilityWord: String? {
        switch self {
        case .needsYou: return "needs you"
        case .working: return "working"
        case .doneUnseen: return "done"
        case .failed: return "failed"
        case .idle, .ended: return nil
        }
    }

    var isDimmed: Bool { self == .ended }
}

/// The status dot palette, as packed sRGB hexes.
///
/// Kept as numbers rather than as `Color`s so the exact values are one
/// greppable table and can be asserted in tests — a `Color` built from a
/// dynamic `NSColor` does not compare, so a palette expressed only as `Color`
/// is a palette no test can defend.
///
/// The v1.1.6 change is `working`: it was an olive (`0x8A9A46`) that sat one
/// hue-step from `doneUnseen`'s green, so at 6pt "still running" and "finished"
/// were the same dot. Working is now unmistakably blue and, unlike every other
/// state, it *pulses* (`QuietStatusDot`), which is the second, colour-blind-safe
/// channel that separates it from done. The rest of the grammar is unchanged:
/// green means done, amber means needs-you, red means failed, idle and ended
/// draw nothing.
///
/// Blue is free here: the rail's identity marks are Claude's coral, a near
/// mono OpenAI knot, and neutral grey tiles — including the ssh tile, which
/// carries no blue — so nothing else in a row can be mistaken for this dot.
enum QuietStatusPalette {
    /// Blue on light, lifted (not merely brightened) on dark so the dot keeps
    /// its chroma against the rail's dark backdrop.
    static let working: (light: UInt32, dark: UInt32) = (0x3478F6, 0x6FA8FF)
    static let needsYou: (light: UInt32, dark: UInt32) = (0xC7862A, 0xE0A046)
    static let doneUnseen: (light: UInt32, dark: UInt32) = (0x2E9E5B, 0x4FB878)
    static let failed: (light: UInt32, dark: UInt32) = (0xC64B40, 0xE0716A)

    /// `nil` for the two silent states.
    static func hexes(for status: QuietSessionStatus) -> (light: UInt32, dark: UInt32)? {
        switch status {
        case .working: return working
        case .needsYou: return needsYou
        case .doneUnseen: return doneUnseen
        case .failed: return failed
        case .idle, .ended: return nil
        }
    }
}

private extension Color {
    /// Appearance-adaptive color from packed RGB hex values.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
