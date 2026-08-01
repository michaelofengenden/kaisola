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

    /// A second, non-colour channel for every speaking state. Six-point rail
    /// marks cannot carry readable letters, but a circle, triangle, square,
    /// and cross remain distinct in peripheral vision and under common colour
    /// deficiencies. Silent states intentionally have no marker.
    var markerShape: QuietStatusMarkerShape? {
        switch self {
        case .working: .circle
        case .needsYou: .triangle
        case .doneUnseen: .square
        case .failed: .cross
        case .idle, .ended: nil
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

enum QuietStatusMarkerShape: String, CaseIterable, Equatable {
    case circle, triangle, square, cross
}

/// Packed sRGB values for a filled semantic badge. The foreground/background
/// pair is deliberate: status text and glyphs never sit directly on unknown
/// glass, and every pair clears WCAG AA for small text in both appearances.
struct KaisolaStatusColorPair: Equatable {
    let light: UInt32
    let dark: UInt32
}

struct KaisolaStatusBadgePalette: Equatable {
    let foreground: KaisolaStatusColorPair
    let background: KaisolaStatusColorPair
}

enum KaisolaStatusTone: CaseIterable, Equatable {
    case needsYou, working, done, failed

    var palette: KaisolaStatusBadgePalette {
        switch self {
        case .needsYou:
            KaisolaStatusBadgePalette(
                foreground: .init(light: 0x6D3B00, dark: 0xFFD589),
                background: .init(light: 0xFFE4B5, dark: 0x4A2B00)
            )
        case .working:
            KaisolaStatusBadgePalette(
                foreground: .init(light: 0x164A9C, dark: 0xB9D2FF),
                background: .init(light: 0xDCEAFF, dark: 0x173461)
            )
        case .done:
            KaisolaStatusBadgePalette(
                foreground: .init(light: 0x145C2F, dark: 0xA8E6BC),
                background: .init(light: 0xD9F4E2, dark: 0x174229)
            )
        case .failed:
            KaisolaStatusBadgePalette(
                foreground: .init(light: 0x8A261F, dark: 0xFFC0BA),
                background: .init(light: 0xFDE1DE, dark: 0x5B211D)
            )
        }
    }

    var foregroundColor: Color {
        Color(light: palette.foreground.light, dark: palette.foreground.dark)
    }

    var backgroundColor: Color {
        Color(light: palette.background.light, dark: palette.background.dark)
    }
}

/// A compact, labelled status pill used by project and footer chrome. The icon
/// makes the state independent of colour; the text/count keeps it explicit.
struct KaisolaStatusBadge: View {
    let text: String
    let systemImage: String
    let tone: KaisolaStatusTone

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tone.foregroundColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tone.backgroundColor, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tone.foregroundColor.opacity(0.24), lineWidth: KaisolaVisualSystem.hairline)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
    }
}

/// The icon-only companion for rows whose adjacent title/detail already names
/// the item. It retains the same high-contrast fill and an unambiguous symbol.
struct KaisolaStatusGlyph: View {
    let systemImage: String
    let tone: KaisolaStatusTone
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: max(7, size * 0.52), weight: .bold))
            .foregroundStyle(tone.foregroundColor)
            .frame(width: size, height: size)
            .background(tone.backgroundColor, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(tone.foregroundColor.opacity(0.24), lineWidth: KaisolaVisualSystem.hairline)
            }
            .accessibilityHidden(true)
    }
}

/// The shared colour-blind-safe marker for the compact rail and its collapsed
/// project rollups. Accessibility text lives on the enclosing row/rollup.
struct QuietStatusMark: View {
    let status: QuietSessionStatus
    let size: CGFloat

    @ViewBuilder
    var body: some View {
        if let color = status.dotColor, let shape = status.markerShape {
            switch shape {
            case .circle:
                Circle().fill(color)
                    .frame(width: size, height: size)
            case .triangle:
                QuietTriangle().fill(color)
                    .frame(width: size, height: size)
            case .square:
                RoundedRectangle(cornerRadius: max(1, size * 0.18), style: .continuous)
                    .fill(color)
                    .frame(width: size, height: size)
            case .cross:
                QuietCross()
                    .stroke(
                        color,
                        style: StrokeStyle(
                            lineWidth: max(1.2, size * 0.25),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: size, height: size)
            }
        }
    }
}

private struct QuietTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct QuietCross: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
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
