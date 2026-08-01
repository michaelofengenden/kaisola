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
    /// Precedence: declared agent, then the *running* process, then the
    /// transport, then the initial fallback.
    ///
    /// The process check is what makes a plain terminal's mark dynamic. Type
    /// `claude` into a shell that was opened as a shell and the row's mark
    /// becomes Claude's; the row was never launched as an agent session, so
    /// nothing but the foreground process can say so. `ssh` describes how a
    /// session is *reached*, so it stays below both — a `claude` running on the
    /// far end of an ssh hop is a Claude row.
    ///
    /// Matching is `contains`, not equality, because
    /// `TerminalMetaService.processName(fromCommand:)` already normalizes a
    /// runtime-wrapped CLI (`node …/@openai/codex…`) down to the bare marker
    /// name, but a directly-installed binary can still arrive as `claude-code`
    /// or similar.
    static func identity(agentName: String?, processName: String?) -> QuietIdentity {
        let agent = (agentName ?? "").lowercased()
        if agent.contains("claude") { return .claude }
        if agent.contains("codex") || agent.contains("openai") { return .openai }
        if agent.contains("mesh") { return .mesh }
        let process = (processName ?? "").lowercased()
        if process.contains("claude") { return .claude }
        if process.contains("codex") || process.contains("openai") { return .openai }
        if process == "ssh" { return .ssh }
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
                QuietOpenAIKnotMark()
                    .stroke(
                        Color(light: 0x202123, dark: 0xF2F2F2),
                        style: StrokeStyle(lineWidth: QuietOpenAIKnot.strokeWidth(unit: unit))
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

/// The OpenAI/Codex knot, as geometry rather than as a picture.
///
/// The logo is six identical elongated loops arranged with six-fold rotational
/// symmetry, overlapping into a hexagonal knot. This reproduces that
/// construction: one stadium (a rounded rect whose corner radius is half its
/// width), placed with its centre on an orbit around the mark's centre and its
/// long axis nearly tangential, then repeated every 60°.
///
/// Two numbers carry the whole likeness, and both were picked by rendering the
/// mark at its shipping size rather than by eye at poster size:
///
/// * `lengthRatio` — each strand is longer than the arc it spans, so
///   consecutive strands cross rather than meet. Purely tangential strands of
///   exactly the right length draw a plain hexagonal ring with beads at the
///   vertices; it is the *overlap* that reads as a knot.
/// * `skew` — the strands lean off tangential, which is what gives the mark its
///   chirality. At 0° it is a symmetric ring and reads as a generic hexagon; far
///   past 14° the strands cross so much the interior fills in and at 16pt the
///   mark turns to mud. 14° is the point where the six lobes and the hexagonal
///   void in the middle both survive a 16pt rasterization.
///
/// Everything is expressed in the shared 24-unit viewbox, so the same geometry
/// serves any slot size.
enum QuietOpenAIKnot {
    static let strandCount = 6
    /// Distance from the mark's centre to each strand's centre.
    static let orbit: CGFloat = 5.7
    /// Strand length as a multiple of `orbit`. Above ~1.16 the strands overlap.
    static let lengthRatio: CGFloat = 1.70
    /// Strand length ÷ strand width.
    static let aspect: CGFloat = 2.6
    /// Outline weight as a fraction of strand width.
    static let strokeRatio: CGFloat = 0.48
    /// How far each strand's long axis is turned off tangential.
    static let skew = Angle(degrees: 14)

    static func unit(in rect: CGRect) -> CGFloat { min(rect.width, rect.height) / 24 }
    static func strandLength(unit: CGFloat) -> CGFloat { lengthRatio * orbit * unit }
    static func strandWidth(unit: CGFloat) -> CGFloat { strandLength(unit: unit) / aspect }
    static func strokeWidth(unit: CGFloat) -> CGFloat { strandWidth(unit: unit) * strokeRatio }

    /// Where each strand sits. Pure, so the mark's symmetry is testable without
    /// rasterizing anything.
    static func strandCenters(in rect: CGRect) -> [CGPoint] {
        let radius = orbit * unit(in: rect)
        return (0..<strandCount).map { index in
            let angle = (2 * .pi / CGFloat(strandCount)) * CGFloat(index)
            return CGPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
        }
    }

    /// The whole mark's outline. Lives on the geometry rather than inside the
    /// `Shape` so the knot's bounds and symmetry can be asserted directly.
    static func path(in rect: CGRect) -> Path {
        let unit = unit(in: rect)
        let length = strandLength(unit: unit)
        let width = strandWidth(unit: unit)
        // Built at the origin once and transformed into place: six copies of
        // ONE shape is the logo's actual construction, and building it that way
        // makes the six-fold symmetry structural rather than arithmetic that
        // could drift.
        let strand = Path(
            roundedRect: CGRect(x: -length / 2, y: -width / 2, width: length, height: width),
            cornerRadius: width / 2,
            style: .circular
        )
        var path = Path()
        for (index, center) in strandCenters(in: rect).enumerated() {
            let orbitAngle = (2 * .pi / CGFloat(strandCount)) * CGFloat(index)
            let axis = orbitAngle + .pi / 2 - CGFloat(skew.radians)
            path.addPath(
                strand,
                transform: CGAffineTransform(translationX: center.x, y: center.y).rotated(by: axis)
            )
        }
        return path
    }
}

private struct QuietOpenAIKnotMark: Shape {
    func path(in rect: CGRect) -> Path { QuietOpenAIKnot.path(in: rect) }
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
