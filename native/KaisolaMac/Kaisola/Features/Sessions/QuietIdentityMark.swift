import SwiftUI

/// Who is on the other end of a rail row, as a *mark* rather than a word
/// (spec: quiet fleet v4.4 "Safari").
///
/// v1.1.7 grammar, taken from Codex's agent list: every mark is a **naked
/// monoline glyph** at one optical size — no tile, no chip, no fill behind
/// anything. The two first-class agents carry full ink (Claude's coral, the
/// knot in the label colour); every generic surface recedes to `.secondary`.
/// So the rail's only colour besides the status dot is still Claude's coral,
/// but nothing is boxed to say so.
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

/// The 16×16 identity slot every row's leading edge reserves. Drawn marks live
/// in a 24-unit viewbox and scale into the slot, so the same geometry serves
/// any future size without new constants; symbol marks are pinned to one point
/// size so a glyph and a drawn mark read as the same object at the same weight.
struct QuietIdentityMarkView: View {
    let identity: QuietIdentity
    var size: CGFloat = QuietIdentityMarkView.slot

    /// `nonisolated` so the rail's (nonisolated) metrics table can name the one
    /// slot size instead of repeating the literal.
    nonisolated static let slot: CGFloat = 16

    /// One optical size for every symbol mark, chosen to match the *drawn*
    /// marks rather than the slot: the starburst spans `2 × 9.6/24 × slot`
    /// = 12.8pt, so a 12.5pt glyph sits on the same optical circle. Making
    /// this a constant is what keeps a future SF Symbol from arriving a size
    /// larger than its neighbours, which is exactly what a tile used to hide.
    nonisolated static let symbolSize: CGFloat = 12.5
    /// The letter fallback, a shade smaller: a cap-height letter at the symbol
    /// size out-inks a monoline glyph.
    nonisolated static let letterSize: CGFloat = 11.5

    var body: some View {
        Group {
            switch identity {
            case .claude:
                QuietStarburstMark(rays: 12, innerRadius: 3.6, outerRadius: 9.6)
                    .stroke(
                        Color(light: 0xD97757, dark: 0xE58A6D),
                        style: StrokeStyle(lineWidth: unit * QuietIdentityMarkView.starburstStroke, lineCap: .round)
                    )
            case .openai:
                // Filled, non-zero: the official mark's white gaps are counters
                // in its own outline, not a stroke around a skeleton.
                QuietOpenAIKnotMark()
                    .fill(Color(light: 0x202123, dark: 0xF2F2F2), style: FillStyle(eoFill: false))
            case .shell:
                // The reference's Terminal mark: a rounded window outline with
                // a prompt inside it, no fill. SF's own `terminal` is that
                // drawing, so the rail does not maintain a second copy of it.
                symbol("terminal")
            case .ssh:
                symbol("arrow.up.arrow.down")
            case .mesh:
                glyph("⌗", size: QuietIdentityMarkView.symbolSize)
            case .letter(let character):
                glyph(String(character), size: QuietIdentityMarkView.letterSize)
            }
        }
        .frame(width: size, height: size)
        // The mark repeats what the row's title and tooltip already say.
        .accessibilityHidden(true)
    }

    /// Stroke weight of the Claude starburst in viewbox units. Sits where it
    /// does so the coral rays and an SF Symbol at `.regular` land within a few
    /// tenths of a point of each other, and so the burst's *ink* (0.314 of the
    /// slot, measured at 8× supersample) matches the filled knot's at
    /// `QuietOpenAIKnot.span` — the two first-class agent marks have to weigh
    /// the same as each other, whatever pen each is drawn with.
    nonisolated static let starburstStroke: CGFloat = 2.0

    private var unit: CGFloat { size / 24 }

    /// A naked SF Symbol at the shared optical size. `.regular` is the monoline
    /// weight; anything heavier reads as a filled badge next to the knot.
    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: QuietIdentityMarkView.symbolSize * (size / QuietIdentityMarkView.slot), weight: .regular))
            .foregroundStyle(.secondary)
    }

    /// A naked text glyph, for the marks SF has no monoline drawing of.
    private func glyph(_ text: String, size glyphSize: CGFloat) -> some View {
        Text(text)
            .font(.system(size: glyphSize * (size / QuietIdentityMarkView.slot), weight: .regular))
            .foregroundStyle(.secondary)
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

/// One straight-line/cubic segment of a vector outline, in the shared 24-unit
/// viewbox. `Sendable`, so a transcribed outline can be a `static let` under
/// Swift 6 strict concurrency (a `Path` cannot).
enum QuietOutlineSegment: Equatable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
    case close
}

/// A four-command reader for transcribed outlines: absolute `M`, `L`, `C`, `Z`.
///
/// Deliberately *not* an SVG path parser. Arcs, relative commands, and implicit
/// repeats are normalized away offline (see `QuietOpenAIKnot.outlineData`), so
/// the shipped reader has four cases and no elliptical-arc conversion in it.
enum QuietVectorOutline {
    /// Numbers each command consumes. A command that repeats its numbers —
    /// `L a b c d` — emits one segment per group, the way path data does.
    private static func arity(_ command: Character) -> Int? {
        switch command {
        case "M", "L": 2
        case "C": 6
        default: nil
        }
    }

    static func segments(_ data: String) -> [QuietOutlineSegment] {
        var segments: [QuietOutlineSegment] = []
        var command: Character = "Z"
        var numbers: [CGFloat] = []

        func drain() {
            guard let arity = arity(command) else { return }
            while numbers.count >= arity {
                let group = Array(numbers.prefix(arity))
                numbers.removeFirst(arity)
                let point = { (index: Int) in CGPoint(x: group[index], y: group[index + 1]) }
                switch command {
                case "M": segments.append(.move(point(0)))
                case "L": segments.append(.line(point(0)))
                default: segments.append(.curve(to: point(4), control1: point(0), control2: point(2)))
                }
            }
        }

        for token in data.split(whereSeparator: \.isWhitespace) {
            if let first = token.first, first.isLetter {
                drain()
                numbers = []
                command = first
                if first == "Z" { segments.append(.close) }
                if let value = Double(token.dropFirst()) { numbers.append(CGFloat(value)) }
            } else if let value = Double(token) {
                numbers.append(CGFloat(value))
            }
            drain()
        }
        return segments
    }

    /// Place a 24-unit outline into `rect`, scaled uniformly and centred.
    static func path(_ segments: [QuietOutlineSegment], in rect: CGRect, span: CGFloat) -> Path {
        let side = min(rect.width, rect.height) * span
        let scale = side / 24
        let originX = rect.midX - side / 2
        let originY = rect.midY - side / 2
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: originX + point.x * scale, y: originY + point.y * scale)
        }
        var path = Path()
        for segment in segments {
            switch segment {
            case let .move(point): path.move(to: place(point))
            case let .line(point): path.addLine(to: place(point))
            case let .curve(to, control1, control2):
                path.addCurve(to: place(to), control1: place(control1), control2: place(control2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// The OpenAI/ChatGPT knot — the **official outline**, not a reconstruction.
///
/// What it replaced, and why: v1.1.7–v1.1.9 drew six stroked stadiums on an
/// orbit and hoped the overlaps would read as the weave. They do not. Measured
/// against `assets/backlog/pasted-image.png` (the real mark, 1024²), both
/// rasterized and cropped to their own ink box, that construction scores an
/// intersection-over-union of **0.33** and covers 0.57 of its box against the
/// reference's 0.38 — it is a heavier, blunter object that happens to be
/// hexagonal. Michael's note — "please fix the codex icon to be the real
/// chatgpt icon" — is that number.
///
/// Route: the official logomark's outline, transcribed, its elliptical arcs
/// converted to cubics offline (a standard endpoint→centre parameterization,
/// ≤90° per segment), then translated and uniformly scaled so its **tight**
/// bounding box — `boundingBoxOfPath`, which is what SwiftUI's
/// `Path.boundingRect` reports, not the control-point-inclusive one — is
/// centred in the shared 24-unit viewbox. Result: 36 cubics, 32 lines, 8
/// subpaths, **IoU 0.983** against the reference with ink coverage 0.381 vs
/// 0.382. It is *filled* with the non-zero winding rule — the white gaps
/// between the strands are the reference's own counters, not a stroke.
enum QuietOpenAIKnot {
    /// The transcribed outline, in the 24-unit viewbox. Absolute `M`/`L`/`C`/`Z`
    /// only; see `QuietVectorOutline`.
    static let outlineData = """
        M22.282 9.821 C22.825 8.186 22.637 6.397 21.766 4.91 C20.457 2.632 17.826 1.46 15.256 2.01
        C13.808 0.4 11.611 -0.317 9.492 0.131 C7.373 0.579 5.653 2.123 4.981 4.182 C3.293 4.528
        1.836 5.585 0.983 7.082 C-0.34 9.357 -0.04 12.227 1.726 14.178 C1.181 15.812 1.367 17.602
        2.237 19.089 C3.548 21.369 6.18 22.541 8.751 21.989 C9.895 23.277 11.538 24.01 13.26 24
        C15.894 24.002 18.227 22.302 19.032 19.794 C20.719 19.447 22.176 18.391 23.029 16.894
        C24.337 14.623 24.035 11.769 22.282 9.821 Z M13.26 22.429 C12.209 22.431 11.19 22.062 10.384
        21.388 L10.525 21.308 L15.304 18.55 C15.546 18.408 15.695 18.149 15.696 17.868 L15.696
        11.132 L17.716 12.3 C17.737 12.31 17.751 12.33 17.754 12.352 L17.754 17.935 C17.749 20.415
        15.74 22.423 13.26 22.429 Z M3.599 18.304 C3.072 17.393 2.883 16.326 3.065 15.29 L3.207
        15.375 L7.99 18.133 C8.231 18.275 8.529 18.275 8.77 18.133 L14.613 14.765 L14.613 17.097
        C14.612 17.122 14.6 17.144 14.58 17.159 L9.74 19.95 C7.589 21.189 4.842 20.452 3.599 18.304
        Z M2.341 7.896 C2.872 6.979 3.71 6.281 4.706 5.923 L4.706 11.6 C4.703 11.879 4.851 12.139
        5.094 12.277 L10.909 15.631 L8.889 16.799 C8.866 16.811 8.84 16.811 8.818 16.799 L3.987
        14.013 C1.841 12.769 1.105 10.023 2.341 7.872 Z M18.937 11.751 L13.104 8.364 L15.119 7.2
        C15.141 7.188 15.168 7.188 15.19 7.2 L20.02 9.991 C21.528 10.861 22.398 12.523 22.253 14.258
        C22.108 15.993 20.975 17.488 19.344 18.095 L19.344 12.418 C19.335 12.14 19.181 11.886 18.937
        11.751 Z M20.948 8.728 L20.806 8.643 L16.032 5.861 C15.79 5.719 15.489 5.719 15.247 5.861
        L9.409 9.23 L9.409 6.897 C9.406 6.873 9.417 6.85 9.437 6.836 L14.268 4.049 C15.779 3.179
        17.657 3.26 19.088 4.258 C20.518 5.256 21.243 6.99 20.948 8.709 Z M8.307 12.863 L6.287
        11.699 C6.266 11.687 6.252 11.666 6.249 11.643 L6.249 6.074 C6.251 4.33 7.261 2.745 8.84
        2.006 C10.419 1.266 12.283 1.506 13.624 2.621 L13.482 2.701 L8.704 5.459 C8.462 5.601 8.313
        5.86 8.311 6.14 Z M9.404 10.498 L12.006 8.998 L14.613 10.498 L14.613 13.497 L12.016 14.997
        L9.409 13.497 Z
        """

    /// Read once. `[QuietOutlineSegment]` is `Sendable`; a `Path` is not, which
    /// is why the cache holds segments rather than the built path.
    static let outline: [QuietOutlineSegment] = QuietVectorOutline.segments(outlineData)

    /// How much of the 16pt slot the filled knot spans.
    ///
    /// Not 1.0, and the reason is optical mass rather than fit. Measured by
    /// rendering each mark into the slot at 8× and summing alpha: the SF
    /// `terminal` glyph at the shared 12.5pt size inks 0.208 of the slot,
    /// `arrow.up.arrow.down` 0.162, the coral starburst 0.314, and the filled
    /// knot 0.376 at full span. The rail's grammar puts the two first-class
    /// agents a step above the generic surfaces and level with *each other*;
    /// 14.5/16 is where the knot lands on 0.308 and matches the burst.
    static let span: CGFloat = 14.5 / 16

    static func path(in rect: CGRect) -> Path {
        QuietVectorOutline.path(outline, in: rect, span: span)
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
