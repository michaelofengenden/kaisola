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
        switch self {
        case .working:   return Color(light: 0x8A9A46, dark: 0xA6B85E)
        case .needsYou:  return Color(light: 0xC7862A, dark: 0xE0A046)
        case .doneUnseen: return Color(light: 0x2E9E5B, dark: 0x4FB878)
        case .failed:    return Color(light: 0xC64B40, dark: 0xE0716A)
        case .idle, .ended: return nil
        }
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
