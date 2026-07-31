import SwiftUI

/// Who is on the other end of a rail row, as a *mark* rather than a word
/// (spec: quiet fleet v4.4 "Safari"). The two first-class agents get their own
/// drawn marks; everything else gets a neutral tile, so the rail's only colour
/// besides the status dot is Claude's coral.
enum QuietIdentity: Equatable {
    case claude
    case openai
    case shell
    case ssh
    case mesh
    /// An agent Kaisola has no mark for yet, shown as its initial.
    case letter(Character)

    /// Pure mapping from what the model knows about a surface to its mark.
    ///
    /// Precedence is agent first, then transport, then the initial fallback:
    /// `ssh` describes how a session is reached, so it only labels a row whose
    /// agent Kaisola does not recognize, and a plain shell is the default.
    static func identity(agentName: String?, processName: String?) -> QuietIdentity {
        let agent = (agentName ?? "").lowercased()
        if agent.contains("claude") { return .claude }
        if agent.contains("codex") || agent.contains("openai") { return .openai }
        if agent.contains("mesh") { return .mesh }
        if (processName ?? "").lowercased() == "ssh" { return .ssh }
        if let first = agentName?.trimmingCharacters(in: .whitespacesAndNewlines).first,
           let uppercased = first.uppercased().first {
            return .letter(uppercased)
        }
        return .shell
    }

    /// Spoken form for tooltips and accessibility labels that want to name the
    /// mark; the mark itself is decorative and stays hidden from VoiceOver.
    var accessibilityWord: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "Codex"
        case .shell: return "shell"
        case .ssh: return "ssh"
        case .mesh: return "mesh"
        case .letter(let character): return String(character)
        }
    }
}

/// The 16×16 identity slot every row's leading edge reserves. Marks are drawn
/// in a 24-unit viewbox and scaled into the slot, so the same geometry serves
/// any future size without new constants.
struct QuietIdentityMarkView: View {
    let identity: QuietIdentity
    var size: CGFloat = QuietIdentityMarkView.slot

    /// `nonisolated` so the rail's (nonisolated) metrics table can name the one
    /// slot size instead of repeating the literal.
    nonisolated static let slot: CGFloat = 16

    var body: some View {
        Group {
            switch identity {
            case .claude:
                QuietStarburstMark(rays: 12, innerRadius: 3.6, outerRadius: 9.6)
                    .stroke(
                        Color(light: 0xD97757, dark: 0xE58A6D),
                        style: StrokeStyle(lineWidth: unit * 2.3, lineCap: .round)
                    )
            case .openai:
                QuietRosetteMark(arcs: 6, radius: 8.2, sweep: 85)
                    .stroke(
                        Color(light: 0x202123, dark: 0xF2F2F2),
                        style: StrokeStyle(lineWidth: unit * 2.2, lineCap: .round)
                    )
            case .shell:
                tile(">_", size: 7.5, monospaced: true)
            case .ssh:
                tile("⇅", size: 9.5)
            case .mesh:
                tile("⌗", size: 9.5)
            case .letter(let character):
                tile(String(character), size: 9)
            }
        }
        .frame(width: size, height: size)
        // The mark repeats what the row's title and tooltip already say.
        .accessibilityHidden(true)
    }

    private var unit: CGFloat { size / 24 }

    private func tile(_ glyph: String, size glyphSize: CGFloat, monospaced: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(light: 0x8E8E93, dark: 0x6C6C72))
            .overlay {
                Text(glyph)
                    .font(.system(size: glyphSize, weight: .semibold, design: monospaced ? .monospaced : .default))
                    .foregroundStyle(.white)
            }
    }
}

/// Claude's mark: evenly spaced rays from an inner to an outer radius.
private struct QuietStarburstMark: Shape {
    let rays: Int
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inner = innerRadius * unit
        let outer = outerRadius * unit
        var path = Path()
        for index in 0..<max(rays, 1) {
            let angle = (2 * .pi / CGFloat(max(rays, 1))) * CGFloat(index)
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        return path
    }
}

/// The OpenAI/Codex mark: identical arc segments on one radius, rotated evenly
/// around the centre.
private struct QuietRosetteMark: Shape {
    let arcs: Int
    let radius: CGFloat
    /// Sweep of each arc in degrees.
    let sweep: CGFloat

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let r = radius * unit
        let step = 360 / CGFloat(max(arcs, 1))
        var path = Path()
        for index in 0..<max(arcs, 1) {
            let middle = step * CGFloat(index)
            let start = Angle(degrees: Double(middle - sweep / 2))
            let end = Angle(degrees: Double(middle + sweep / 2))
            path.move(to: CGPoint(
                x: center.x + cos(CGFloat(start.radians)) * r,
                y: center.y + sin(CGFloat(start.radians)) * r
            ))
            path.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: false)
        }
        return path
    }
}

/// A row's title when the raw title carries nothing the project name has not
/// already said. Broker terminals inherit their project's name, so three
/// shells in "Kaisola" all read "Kaisola" until this replaces them with
/// "zsh · 1", "zsh · 2", "zsh · 3".
enum QuietRailTitle {
    static func displayTitle(rawTitle: String, projectName: String, processName: String?, ordinal: Int) -> String {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, title.caseInsensitiveCompare(project) == .orderedSame else { return rawTitle }
        guard let processName, !processName.isEmpty else { return "Terminal \(ordinal)" }
        return "\(processName) · \(ordinal)"
    }
}

private extension Color {
    /// Appearance-adaptive color from packed RGB hex values. Deliberately a
    /// local copy of `QuietSessionStatus`'s helper: both stay private to their
    /// file so the pattern is visible where it is used.
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
