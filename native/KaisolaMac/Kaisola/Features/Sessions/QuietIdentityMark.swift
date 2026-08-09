import SwiftUI

/// Who is on the other end of a rail row, as a *mark* rather than a word
/// (spec: quiet fleet v4.4 "Safari").
///
/// v1.1.7 grammar, taken from Codex's agent list: every mark is **naked** at one
/// optical size — no tile, no chip, no fill behind anything. The generic
/// surfaces are monoline glyphs that recede to `.secondary`; the two first-class
/// agents are each their vendor's real logomark, traced and *filled* (Claude's
/// coral burst, the knot in the label colour), and carry full ink. So the rail's
/// only colour besides the status dot is still Claude's coral, but nothing is
/// boxed to say so. The two filled marks are held level with each other by ink
/// rather than by span — see each one's `span`.
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
    /// marks rather than the slot: both drawn marks span a shade over 14pt of
    /// the 16pt slot (`QuietClaudeBurst.span`, `QuietOpenAIKnot.span`), and a
    /// 12.5pt glyph sits on the same optical circle — an SF Symbol's box carries
    /// more air than a traced silhouette's does, so equal boxes would not be
    /// equal marks. Making this a constant is what keeps a future SF Symbol from
    /// arriving a size larger than its neighbours, which is exactly what a tile
    /// used to hide.
    nonisolated static let symbolSize: CGFloat = 12.5
    /// The letter fallback, a shade smaller: a cap-height letter at the symbol
    /// size out-inks a monoline glyph.
    nonisolated static let letterSize: CGFloat = 11.5

    var body: some View {
        Group {
            switch identity {
            case .claude:
                // Filled, non-zero: the official mark is a solid asterisk of
                // tapered petals around a solid hub, not twelve strokes.
                QuietClaudeBurstMark()
                    .fill(Color(light: 0xD97757, dark: 0xE58A6D), style: FillStyle(eoFill: false))
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

/// Claude's mark — the **official silhouette**, traced, not a construction.
///
/// What it replaced, and why: v1.1.7–v1.1.9 drew twelve uniform straight
/// round-capped strokes on an even 30° pitch. The real Anthropic mark is not
/// that. It is a filled asterisk of twelve **tapered petals of unequal length**
/// around a solid hub, each petal wide where it leaves the hub and narrowing to
/// a blunt point, and the petals sit at irregular angles — that irregularity is
/// the mark's whole character, and even spokes read as a generic sparkle
/// instead. Measured against `assets/backlog/pasted-image-2.png` (the real mark,
/// 1280²), rasterized and cropped to its own ink box, the spoke construction
/// scores an intersection-over-union of **0.40**. Michael's note — "we should
/// fix the claude symbol to be more precise" — is that number.
///
/// Route: the reference's own alpha silhouette, thresholded at 50%, its single
/// closed contour traced and simplified (Ramer–Douglas–Peucker, ε = 1.5px at
/// 1280², which is where the fidelity curve flattens), then translated and
/// uniformly scaled so its **tight** bounding box centres in the shared 24-unit
/// viewbox — the same normalization `QuietOpenAIKnot` uses, and the same one the
/// artwork itself was exported with (the reference's ink reaches all four of its
/// own edges). Result: one subpath, 129 lines, **IoU 0.989** against the
/// reference; the measurement floor at that raster size is 0.992, so the trace
/// is within three thousandths of exact. Straight segments rather than cubics
/// because the mark's edges genuinely are straight — a curve fit here would be
/// inventing smoothness the artwork does not have.
///
/// It is *filled* with the non-zero winding rule, so the taper and the solid
/// centre are real geometry rather than a stroke width pretending to be them.
enum QuietClaudeBurst {
    /// The traced outline, in the 24-unit viewbox. Absolute `M`/`L`/`Z`; see
    /// `QuietVectorOutline`.
    static let outlineData = """
        M6.78 0 L 6.3 0.11 5.58 1.11 5.62 1.63 5.85 2.48 6.52 3.53 7.93 5.97 9.24 8.48
        9.41 8.73 9.41 8.82 9.24 8.93 3.57 4.6 2.52 4.48 1.87 5.2 2 6.21 2.37 6.7 3.07 7.15
        4.33 8.09 9.32 11.39 9.56 11.62 9.52 11.77 8.98 11.78 6.73 11.5 2.81 11.28
        0.55 11.09 0.05 11.41 0.01 11.77 0.52 12.48 1.04 12.59 5.62 12.84 9.43 12.95
        9.52 13.1 9.43 13.34 4.74 15.95 2.84 17.26 2.58 17.53 2.52 18.24 2.99 18.71
        4.12 18.58 10.46 14.45 10.56 14.47 10.57 14.58 9.6 15.69 8.19 17.56 5.77 20.64
        5.39 21.19 5.32 21.86 6.05 22.22 6.43 22.07 8.17 20.23 11.77 15.27 11.92 15.27
        11.94 15.37 11.74 16.18 11.49 17.88 10.8 21.34 10.46 22.84 10.78 23.51 11.38 24
        12.09 23.72 12.41 23.36 13.11 16.1 13.22 16.01 14.36 17.98 15.83 20.17 17.22 22.07
        17.85 22.2 18.47 21.95 18.62 21.65 18.51 20.55 15.73 16.4 15.73 16.19 15.88 16.21
        18.64 18.56 20.84 20.23 21.18 20.28 21.48 19.83 21.36 19.23 16.97 15.24 15.72 14
        15.75 13.9 15.92 13.9 22.66 15.52 23.92 14.9 23.99 14.43 23.56 13.81 22.75 13.3
        19.75 13.06 17.89 13.06 15.98 12.89 15.83 12.82 15.92 12.74 19.34 11.95 21.66 11.48
        23.58 11.01 23.92 10.21 23.82 9.81 23 9.44 19.66 10 16.78 10.64 16.58 10.64
        16.5 10.55 17.27 9.14 18.55 7.43 20.48 4.99 20.82 3.81 20.09 2.7 19.06 2.68
        18.57 3.06 17.55 4.09 16.9 4.86 15.23 6.94 14.29 8.2 14.03 8.48 13.82 8.48
        14.16 6.47 14.8 3.58 15.11 1.29 14.65 0.62 14.03 0.36 13.29 0.86 12.92 1.78
        12.64 5.09 12.38 7.24 12.26 9.14 12.09 9.16 11.77 8.11 9.71 4.15 8.12 0.49 7.7 0.13
        Z
        """

    /// Read once. `[QuietOutlineSegment]` is `Sendable`; a `Path` is not, which
    /// is why the cache holds segments rather than the built path.
    static let outline: [QuietOutlineSegment] = QuietVectorOutline.segments(outlineData)

    /// How much of the 16pt slot the filled burst spans.
    ///
    /// Chosen for optical mass, exactly as `QuietOpenAIKnot.span` was. Measured
    /// by rendering each mark into the slot at 8× and summing alpha: the SF
    /// `terminal` glyph at the shared 12.5pt size inks 0.208 of the slot,
    /// `arrow.up.arrow.down` 0.162, the filled knot 0.308 at its own span, and
    /// this burst 0.395 at full span — a filled asterisk is a much heavier
    /// object than the twelve hairlines it replaces, so left alone it would have
    /// made Claude's row the loudest thing in the rail. 14.2/16 is where it
    /// inks **0.311**, between the knot's 0.308 and the 0.314 the old stroked
    /// burst carried: the rail's weight does not change, only its drawing.
    static let span: CGFloat = 14.2 / 16

    static func path(in rect: CGRect) -> Path {
        QuietVectorOutline.path(outline, in: rect, span: span)
    }
}

private struct QuietClaudeBurstMark: Shape {
    func path(in rect: CGRect) -> Path { QuietClaudeBurst.path(in: rect) }
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

/// What one rail row actually draws, decided with its siblings in view.
///
/// `QuietRailTitle` already handles the row whose title says *nothing*. This
/// handles the row whose title says something the row next to it also says: a
/// project full of agent sessions tends to name them all the same way —
/// "Codex · MATLAB kernel bridge", "Codex · MATLAB plotting spike",
/// "Codex · MATLAB solver notes". The rail budgets about fifteen characters
/// (`QuietRowBudget`) and truncates from the tail, so all three render
/// "Codex · MAT…". The column that exists to tell rows apart then tells you
/// only which agent they belong to, which the identity mark said already, and
/// reading the rail means hovering rows one at a time.
struct QuietRailLabel: Equatable {
    enum Truncation: Equatable {
        /// The default. A title that already reads apart from its siblings
        /// keeps it.
        case tail
        /// Keeps the head *and* the tail, losing the middle — for rows whose
        /// text still collides once the shared lead is gone.
        case middle

        /// SwiftUI's spelling of the same choice.
        var textMode: Text.TruncationMode {
            switch self {
            case .tail: return .tail
            case .middle: return .middle
            }
        }
    }

    /// What the row draws.
    let text: String
    let truncation: Truncation
    /// The shared lead the row stopped drawing, or empty. Kept so the row can
    /// still say the whole title on hover and to VoiceOver: the elision is a
    /// scanning economy, never a loss of the value.
    let droppedLead: String

    init(text: String, truncation: Truncation = .tail, droppedLead: String = "") {
        self.text = text
        self.truncation = truncation
        self.droppedLead = droppedLead
    }

    /// A title nothing had to be done to.
    static func verbatim(_ title: String) -> QuietRailLabel { QuietRailLabel(text: title) }

    /// Whether the row is drawing less than the whole title, so hover has to
    /// carry the rest.
    var elidesTitle: Bool { !droppedLead.isEmpty || truncation == .middle }
}

/// Decides what a project's rows draw, given every title drawn beside them.
///
/// Two steps, in this order.
///
/// 1. **Drop the shared lead.** When two or more rows in the same project open
///    with the same whole segment — one ending on a separator the user typed,
///    `Codex · `, `kaisola: `, `src/` — the rail stops drawing it and the part
///    of the title that differs moves to the front, where a scan finds it. This
///    is the adaptive provider chip the issue asks for, except the chip already
///    exists: it is the row's identity mark, which has been saying "Codex" in
///    its 16pt slot the whole time.
/// 2. **Truncate from the middle.** For what step 1 cannot fix — titles that
///    differ only past the visible window with no segment boundary to cut on —
///    the row keeps its head *and* its tail and gives up the middle instead.
///
/// Both steps are conditional. A project whose titles already read apart, and
/// whose rows share no repeated lead, gets every title back verbatim: no chip,
/// no second line, no taller row, nothing added to the resting rail.
///
/// Pure, and counted in characters rather than measured in points, because this
/// runs on every body pass; see `QuietRowBudget.ambiguousTitleCharacters` for
/// where the count comes from and how it is held to the real lane.
enum QuietRailLabels {
    /// Separators a lead may end on: the marks people actually type between a
    /// title's segments. A run of plain words is NOT a boundary — dropping
    /// "MATLAB kernel " off the front of a title because two rows happen to
    /// start with it would delete the subject rather than the preamble.
    static let leadSeparators = [" · ", " — ", " – ", " - ", " | ", " / ", ": ", "/"]

    /// Shortest lead worth dropping. Two characters off the front is not what
    /// made the rows hard to tell apart, and losing them only makes the column
    /// ragged.
    static let minimumLead = 3

    /// Shortest thing a row may be left holding. This is the guard that keeps
    /// `QuietRailTitle`'s ordinals intact: "zsh · 1", "zsh · 2", "zsh · 3" do
    /// share a lead, and without it they would draw as "1", "2", "3".
    static let minimumRemainder = 3

    /// - Parameters:
    ///   - titles: every surface title the project draws, in draw order.
    ///   - window: how many leading characters count as the same at a glance.
    /// - Returns: one label per title, in the same order.
    static func labels(
        for titles: [String],
        window: Int = QuietRowBudget.ambiguousTitleCharacters
    ) -> [QuietRailLabel] {
        var labels = zip(titles, leads(for: titles, window: window)).map { title, lead -> QuietRailLabel in
            guard let lead else { return .verbatim(title) }
            return QuietRailLabel(text: remainder(of: title, after: lead), droppedLead: lead)
        }
        // Whatever a lead could not separate — and the rows that never had one
        // to drop — truncate from the middle instead, which is what keeps the
        // end of the title on screen.
        for group in collisions(in: labels.map(\.text), window: window) {
            for index in group {
                labels[index] = QuietRailLabel(
                    text: labels[index].text,
                    truncation: .middle,
                    droppedLead: labels[index].droppedLead
                )
            }
        }
        return labels
    }

    /// The lead each row gives up, or `nil` for a row that keeps its title
    /// whole: the longest leading segment it shares with at least one other row
    /// and that the whole sharing group can afford to lose.
    ///
    /// Longest wins so nested segments collapse as far as they can: given
    /// "Codex · MATLAB: kernel", "Codex · MATLAB: plots" and "Codex · sidebar",
    /// the first two drop "Codex · MATLAB: " while the third drops "Codex · ".
    ///
    /// One pass over the group builds the sharing table, so a project's rows
    /// cost this once between them rather than once each.
    static func leads(for titles: [String], window: Int) -> [String?] {
        let segments = titles.map { leadingSegments(of: $0) }
        var sharers: [String: [Int]] = [:]
        for (index, candidates) in segments.enumerated() {
            for segment in candidates { sharers[segment, default: []].append(index) }
        }
        return segments.map { candidates in
            candidates.first { segment in
                guard let group = sharers[segment], group.count > 1 else { return false }
                return isWorthDropping(segment, from: group.map { titles[$0] }, window: window)
            }
        }
    }

    /// Every leading segment a title has, longest first:
    /// "Codex · MATLAB: kernel" yields ["Codex · MATLAB: ", "Codex · "].
    static func leadingSegments(of title: String) -> [String] {
        var segments: [String] = []
        var index = title.startIndex
        while index < title.endIndex {
            for separator in leadSeparators where title[index...].hasPrefix(separator) {
                let segment = String(title[title.startIndex ..< title.index(index, offsetBy: separator.count)])
                if segment.count >= minimumLead { segments.append(segment) }
                break
            }
            index = title.index(after: index)
        }
        return segments.sorted { $0.count > $1.count }
    }

    /// Whether a group of rows is better off without the lead they share.
    ///
    /// All-or-nothing per group on purpose: dropping the lead from the long
    /// titles and leaving it on the short ones gives the column two different
    /// leading columns of text, which reads worse than the repetition did.
    static func isWorthDropping(_ lead: String, from titles: [String], window: Int) -> Bool {
        // Somebody has to actually be paying for it. Rows that fit the lane
        // whole lose nothing to a repeated prefix, so the prefix stays.
        guard titles.contains(where: { $0.count > window }) else { return false }
        // …and every row has to still say something without it.
        return titles.allSatisfy { remainder(of: $0, after: lead).count >= minimumRemainder }
    }

    /// What a title reads as once its lead is gone. The leading space a
    /// separator like "/" leaves behind goes with it.
    static func remainder(of title: String, after lead: String) -> String {
        String(title.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Index groups whose visible prefixes are equal while their full texts are
    /// not — precisely the rows a sighted scan cannot tell apart.
    ///
    /// Rows saying *exactly* the same thing are a different problem, the one
    /// `QuietRailTitle`'s ordinals exist for, and no truncation strategy
    /// separates them; a group of those is left alone.
    static func collisions(in texts: [String], window: Int) -> [[Int]] {
        var buckets: [String: [Int]] = [:]
        var order: [String] = []
        for (index, text) in texts.enumerated() {
            let key = String(text.prefix(window))
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(index)
        }
        return order.compactMap { key in
            guard let group = buckets[key], group.count > 1 else { return nil }
            guard Set(group.map { texts[$0] }).count > 1 else { return nil }
            return group
        }
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
