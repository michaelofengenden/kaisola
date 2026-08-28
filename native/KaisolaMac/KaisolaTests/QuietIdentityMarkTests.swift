import SwiftUI
import XCTest
@testable import Kaisola

/// How much of the identity slot a drawn mark actually inks.
///
/// The rail's "both first-class agent marks weigh the same" rule used to live in
/// a comment quoting numbers somebody measured once offline. It is cheap to
/// measure in-process instead: rasterize the mark's own `Path` into the 16pt
/// slot at 8× with CoreGraphics, fill it non-zero, and average the coverage.
/// Deterministic — no display, no appearance, no SF Symbol.
enum QuietIdentityMarkInk {
    static func fraction(
        slot: CGFloat = QuietIdentityMarkView.slot,
        scale: CGFloat = 8,
        of path: (CGRect) -> Path
    ) -> Double {
        let side = Int(slot * scale)
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return .nan }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(rect)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path(rect).cgPath)
        context.fillPath(using: .winding)
        guard let data = context.data else { return .nan }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        for index in 0 ..< side * side { total += Double(pixels[index]) / 255 }
        return total / Double(side * side)
    }
}

/// What a rail row's title lane actually shows, at a real width in the real
/// font.
///
/// The truncation is modelled rather than driven through CoreText: what these
/// fixtures have to settle is whether two rows end up drawing the *same
/// string*, and for that "the longest prefix that fits, plus an ellipsis" — and
/// its middle-truncating twin — is the answer AppKit arrives at too. The
/// measurement, the lane width and the font, is real.
enum QuietRailLaneFixture {
    /// Computed rather than stored: `NSFont` is not `Sendable`, and a stored
    /// static is a shared mutable global under Swift 6 checking.
    static var titleFont: NSFont { .systemFont(ofSize: QuietRailMetrics.titleText) }
    static var timeFont: NSFont {
        .monospacedDigitSystemFont(ofSize: QuietRailMetrics.secondaryText, weight: .regular)
    }

    /// The lane a session title gets at the rail's resting width, with a "now"
    /// time label and no hover control — the geometry the issue reported in.
    static var restingLane: CGFloat {
        QuietRowBudget.titleWidth(
            sidebarWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            timeLabelWidth: width(of: "now", in: timeFont),
            showsReveal: false
        )
    }

    static func width(of text: String, in font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// How many leading characters of a title survive tail truncation.
    static func tailCharacters(of title: String, in lane: CGFloat) -> Int {
        guard !title.isEmpty else { return 0 }
        var visible = 0
        for count in 1 ... title.count {
            guard width(of: String(title.prefix(count)) + "…", in: titleFont) <= lane else { break }
            visible = count
        }
        return visible
    }

    /// What the row draws: the whole text when it fits, otherwise the text cut
    /// the way this label says to cut it.
    static func drawn(_ label: QuietRailLabel, in lane: CGFloat) -> String {
        let text = label.text
        guard !text.isEmpty, width(of: text, in: titleFont) > lane else { return text }
        var drawn = "…"
        for count in 1 ... text.count {
            let candidate: String
            switch label.truncation {
            case .tail:
                candidate = String(text.prefix(count)) + "…"
            case .middle:
                candidate = String(text.prefix((count + 1) / 2)) + "…" + String(text.suffix(count / 2))
            }
            guard width(of: candidate, in: titleFont) <= lane else { break }
            drawn = candidate
        }
        return drawn
    }
}

/// The rail's three pure derivations: who a row belongs to (`QuietIdentity`),
/// what a row is called when its title carries no information
/// (`QuietRailTitle`) or carries the same thing the row beside it does
/// (`QuietRailLabels`), and where a compact-list drag lands in the persisted
/// project order once the active project is pinned out of that list
/// (`QuietRailOrder`).
final class QuietIdentityMarkTests: XCTestCase {

    // MARK: - Identity mapping

    func testClaudeAgentsMapToTheCoralBurst() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "Claude Code", processName: nil), .claude)
        XCTAssertEqual(QuietIdentity.identity(agentName: "claude", processName: "node"), .claude)
        XCTAssertEqual(QuietIdentity.identity(agentName: "CLAUDE", processName: nil), .claude)
    }

    func testCodexAndOpenAIMapToTheOpenAIMark() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "codex", processName: nil), .openai)
        XCTAssertEqual(QuietIdentity.identity(agentName: "Codex CLI", processName: nil), .openai)
        XCTAssertEqual(QuietIdentity.identity(agentName: "OpenAI", processName: nil), .openai)
    }

    func testMeshMapsToTheMeshMark() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "mesh", processName: nil), .mesh)
        XCTAssertEqual(QuietIdentity.identity(agentName: "Mesh", processName: "node"), .mesh)
    }

    func testSSHProcessMapsToTheTransferMark() {
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "ssh"), .ssh)
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "SSH"), .ssh)
    }

    func testPlainShellsAreTheDefault() {
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "zsh"), .shell)
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: nil), .shell)
        // An agent name that is only whitespace has no letter to fall back to.
        XCTAssertEqual(QuietIdentity.identity(agentName: "   ", processName: nil), .shell)
        XCTAssertEqual(QuietIdentity.identity(agentName: "", processName: nil), .shell)
    }

    // MARK: - Dynamic terminal identity (foreground process)

    /// The v1.1.6 addition: a terminal that was opened as a plain shell and
    /// then had `claude` typed into it must swap its mark. Nothing declares an
    /// agent for such a row, so the foreground process is the only signal.
    func testForegroundAgentProcessSwapsAPlainTerminalsMark() {
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "claude"), .claude)
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "codex"), .openai)
    }

    /// `TerminalMetaService.processName(fromCommand:)` is what feeds this, and
    /// it normalizes a runtime-wrapped CLI down to the bare marker name. These
    /// are the values it actually produces for the two agents.
    func testProcessNamesTerminalMetaServiceReallyReportsMapToTheirMarks() {
        let claudeCommands = [
            "/Users/m/.local/bin/claude",
            "node /Users/m/.nvm/versions/node/v22.3.0/lib/node_modules/@anthropic-ai/claude-code/cli.js",
        ]
        for command in claudeCommands {
            let reported = TerminalMetaService.processName(fromCommand: command)
            XCTAssertEqual(reported, "claude", "meta reported \(reported ?? "nil") for \(command)")
            XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: reported), .claude)
        }

        let codexCommands = [
            "/opt/homebrew/bin/codex",
            "node /Users/m/.npm/_npx/abc/node_modules/@openai/codex/bin/codex.js",
        ]
        for command in codexCommands {
            let reported = TerminalMetaService.processName(fromCommand: command)
            XCTAssertEqual(reported, "codex", "meta reported \(reported ?? "nil") for \(command)")
            XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: reported), .openai)
        }
    }

    func testProcessMatchingIsCaseInsensitiveAndSubstringTolerant() {
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "CLAUDE"), .claude)
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "claude-code"), .claude)
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "Codex"), .openai)
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "openai"), .openai)
    }

    /// Precedence: the running process outranks the transport, so an agent on
    /// the far end of an ssh hop is that agent's row, not an ssh row. It stays
    /// below a *declared* agent, which is a stronger statement than a probe.
    func testForegroundProcessOutranksTheTransportButNotADeclaredAgent() {
        XCTAssertEqual(QuietIdentity.identity(agentName: nil, processName: "ssh"), .ssh)
        XCTAssertEqual(QuietIdentity.identity(agentName: "Claude Code", processName: "zsh"), .claude)
        XCTAssertEqual(QuietIdentity.identity(agentName: "mesh", processName: "claude"), .mesh)
    }

    /// A shell whose foreground process is an ordinary command keeps the shell
    /// mark: the process check must not become a catch-all.
    func testOrdinaryForegroundProcessesStillReadAsShells() {
        for process in ["zsh", "node", "npm", "vim", "git", "python3"] {
            XCTAssertEqual(
                QuietIdentity.identity(agentName: nil, processName: process),
                .shell,
                "\(process) should not claim an agent mark"
            )
        }
    }

    // MARK: - Naked-mark grammar (v1.1.7)

    /// The tiles are gone. Every mark is now drawn naked at ONE optical size,
    /// the way Codex's agent list draws its row glyphs — a grey rounded tile is
    /// what let a 7.5pt `>_` and a 12.8pt starburst sit in the same rail and
    /// still look deliberate. Without the tile, the sizes themselves have to
    /// agree, so they are constants and this is their test.
    func testEveryMarkIsDrawnNakedAtOneOpticalSize() {
        let slot = QuietIdentityMarkView.slot

        // Symbol marks sit inside the slot but fill most of it: a glyph that
        // shrank to nothing would also "not overflow".
        XCTAssertLessThan(QuietIdentityMarkView.symbolSize, slot)
        XCTAssertGreaterThan(QuietIdentityMarkView.symbolSize, slot * 0.7)

        // The letter fallback is a shade smaller — cap-height ink out-weighs a
        // monoline glyph at the same point size — but only a shade.
        XCTAssertLessThan(QuietIdentityMarkView.letterSize, QuietIdentityMarkView.symbolSize)
        XCTAssertEqual(
            QuietIdentityMarkView.letterSize,
            QuietIdentityMarkView.symbolSize,
            accuracy: 2,
            "the letter mark drifted out of the row's optical size"
        )

        // …and the DRAWN marks land on the same optical circle as each other
        // first, and near the glyphs second. Both are traced silhouettes placed
        // by `span`, so this is one comparison rather than two constructions.
        XCTAssertEqual(
            QuietClaudeBurst.span,
            QuietOpenAIKnot.span,
            accuracy: 0.05,
            "the two drawn marks stopped spanning the slot alike"
        )
        XCTAssertEqual(
            QuietClaudeBurst.span * slot,
            QuietIdentityMarkView.symbolSize,
            accuracy: 2,
            "the coral mark no longer matches the glyph marks beside it"
        )
    }

    /// The two first-class agent marks have to weigh the same as each other and
    /// sit a deliberate step above the generic ones — that is the naked-mark
    /// grammar, and without a tile to hide behind it is the only thing keeping
    /// the rail from reading as one bold mark beside four thin ones.
    ///
    /// Both are filled now, so no stroke width can express this; ink can.
    /// Measured by rendering each mark into the 16pt slot at 8× and summing
    /// alpha: `terminal` 0.208, `arrow.up.arrow.down` 0.162, the filled knot
    /// 0.376 at full span and the traced coral burst 0.395 at full span — which
    /// is why each is inset to its own `span`, where they land on 0.308 and
    /// 0.311. The inks are *measured* here rather than restated, because both
    /// spans are otherwise just two constants nothing checks.
    func testTheTwoAgentMarksAreInkedAlikeAndBothAreInsetToGetThere() {
        let burst = QuietIdentityMarkInk.fraction { QuietClaudeBurst.path(in: $0) }
        let knot = QuietIdentityMarkInk.fraction { QuietOpenAIKnot.path(in: $0) }

        // Level with each other: that is the grammar, not a coincidence of two
        // hand-picked spans.
        XCTAssertEqual(
            burst, knot, accuracy: 0.015,
            "the agent marks stopped weighing the same: burst \(burst), knot \(knot)"
        )

        // …and a deliberate step above the generic `.secondary` glyphs, whose
        // measured inks are 0.208 and 0.162, without becoming badges.
        for ink in [burst, knot] {
            XCTAssertGreaterThan(ink, 0.24, "an agent mark receded to a generic surface's weight")
            XCTAssertLessThan(ink, 0.36, "an agent mark is inking like a filled tile")
        }

        // The pinned numbers, so a future edit that deforms the geometry but
        // keeps the spans still fails.
        XCTAssertEqual(burst, 0.311, accuracy: 0.012)
        XCTAssertEqual(knot, 0.308, accuracy: 0.012)

        // Each gives up a point or so of the slot. Less and it out-inks its
        // neighbour; much more and it stops reading at rail size.
        XCTAssertEqual(Double(QuietOpenAIKnot.span), 14.5 / 16, accuracy: 0.0001)
        XCTAssertEqual(Double(QuietClaudeBurst.span), 14.2 / 16, accuracy: 0.0001)
        for span in [QuietOpenAIKnot.span, QuietClaudeBurst.span] {
            XCTAssertLessThan(span, 1)
            XCTAssertGreaterThan(span, 0.85)
        }
    }

    // MARK: - Claude burst geometry

    /// The outline is the official mark's silhouette, traced — one closed
    /// subpath of 129 straight segments — not twelve strokes on an even pitch.
    /// The counts are asserted because the reader is what turns the trace into
    /// geometry, and a reader that dropped commands would still draw a blob.
    func testClaudeBurstOutlineIsTheTracedOfficialSilhouette() {
        var moves = 0, lines = 0, curves = 0, closes = 0
        for segment in QuietClaudeBurst.outline {
            switch segment {
            case .move: moves += 1
            case .line: lines += 1
            case .curve: curves += 1
            case .close: closes += 1
            }
        }
        XCTAssertEqual(moves, 1, "the burst is one closed contour — it has no counters")
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(lines, 129)
        XCTAssertEqual(curves, 0, "the mark's edges are straight; a cubic here is invented smoothness")

        // The trace is normalized to the viewbox: every point inside it, and the
        // tight bounds reaching both ends of it.
        let points = QuietClaudeBurst.outline.compactMap { segment -> CGPoint? in
            switch segment {
            case let .move(point), let .line(point): point
            default: nil
            }
        }
        XCTAssertEqual(points.count, 130)
        let xs = points.map(\.x), ys = points.map(\.y)
        XCTAssertGreaterThan(xs.min() ?? -99, -0.5)
        XCTAssertGreaterThan(ys.min() ?? -99, -0.5)
        XCTAssertLessThan(xs.max() ?? 99, 24.5)
        XCTAssertLessThan(ys.max() ?? 99, 24.5)
        XCTAssertGreaterThan(xs.max() ?? 0, 23.5)
        XCTAssertGreaterThan(ys.max() ?? 0, 23.5)

        // Shape invariant that no rasterizer can drift: the enclosed area of the
        // traced polygon, by the shoelace formula, in viewbox units. Signed, so
        // a reversed winding is caught too.
        var signed: CGFloat = 0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            signed += a.x * b.y - a.y * b.x
        }
        XCTAssertEqual(Double(signed / 2), -227.38, accuracy: 0.5, "the traced outline changed shape")
    }

    /// The complaint this release is FOR: "we should fix the claude symbol to be
    /// more precise." The old mark was twelve *uniform* strokes on an even 30°
    /// pitch; the real one is twelve **tapered petals of unequal length** at
    /// irregular angles around a solid hub. Those three properties are what the
    /// eye reads as this logo rather than as a generic sparkle, so they are
    /// measured off the shipped geometry rather than restated in a comment.
    func testTheBurstHasTwelveUnequalPetalsAroundASolidHub() {
        let points = QuietClaudeBurst.outline.compactMap { segment -> CGPoint? in
            switch segment {
            case let .move(point), let .line(point): point
            default: nil
            }
        }
        let centre = CGPoint(x: 12, y: 12)
        func radius(_ point: CGPoint) -> CGFloat { hypot(point.x - centre.x, point.y - centre.y) }

        // Petal tips: vertices that are local maxima of radius around the ring.
        var tips: [CGPoint] = []
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let next = points[(index + 1) % points.count]
            let here = radius(points[index])
            if here > 8, here >= radius(previous), here >= radius(next) {
                if let last = tips.last, radius(last) >= here, hypot(last.x - points[index].x, last.y - points[index].y) < 2 {
                    continue
                }
                tips.append(points[index])
            }
        }
        XCTAssertEqual(tips.count, 12, "the mark stopped having twelve petals")

        // Unequal LENGTH. Even spokes would put every tip on one circle.
        let radii = tips.map(radius).sorted()
        XCTAssertGreaterThan(
            (radii.last ?? 0) - (radii.first ?? 0), 1.0,
            "every petal reaches the same radius — that is the spoke burst again"
        )

        // Unequal ANGLE. Even spokes would sit on an exact 30° pitch.
        let angles = tips.map { atan2($0.y - centre.y, $0.x - centre.x) * 180 / .pi }.sorted()
        let gaps = angles.indices.map { index -> Double in
            let next = angles[(index + 1) % angles.count]
            return Double((next - angles[index] + 360).truncatingRemainder(dividingBy: 360))
        }
        XCTAssertGreaterThan(
            (gaps.max() ?? 0) - (gaps.min() ?? 0), 10,
            "the petals are back on an even pitch"
        )

        // A SOLID hub, not a hole the strokes radiate from: the centre is inked,
        // and stays inked well out from it.
        //
        // Asked of the CGPath with the winding rule rather than of
        // `Path.contains`, and the difference is not pedantry: SwiftUI's
        // containment test ray-casts horizontally and answers `false` for the
        // interior point (12, 10) of this outline, because the ray leaves
        // through the vertex that sits at exactly `19.66 10`. `.winding` is also
        // the rule `QuietIdentityMarkView` fills the burst with, so this asserts
        // the hub is solid in precisely the sense the view draws it.
        let rect = CGRect(x: 0, y: 0, width: 240, height: 240)
        let filled = QuietClaudeBurst.path(in: rect).cgPath
        let unit = rect.width * QuietClaudeBurst.span / 24
        for step in 0 ..< 24 {
            let angle = CGFloat(step) * .pi / 12
            for reach in [CGFloat(0), 1, 2] {
                let probe = CGPoint(
                    x: rect.midX + cos(angle) * reach * unit,
                    y: rect.midY + sin(angle) * reach * unit
                )
                XCTAssertTrue(
                    filled.contains(probe, using: .winding),
                    "the hub is hollow \(reach) units out at \(angle) rad"
                )
            }
        }
    }

    /// The negative control the petal test needs: the mark must NOT map onto
    /// itself under a 30° turn. On this exact sampling grid the twelve even
    /// spokes it replaced score **0.000** — they are perfectly 12-fold
    /// symmetric — and this outline scores **0.274**. That pair of numbers is
    /// the whole change in one measurement.
    func testTheBurstIsNotTheEvenTwelveFoldSparkleItReplaced() {
        let rect = CGRect(x: 0, y: 0, width: 96, height: 96)
        let path = QuietClaudeBurst.path(in: rect).cgPath
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        func disagreement(turnedBy degrees: Double) -> Double {
            let angle = degrees * .pi / 180
            var checked = 0.0, mismatched = 0.0
            for x in stride(from: 3.0, to: 96, by: 1.5) {
                for y in stride(from: 3.0, to: 96, by: 1.5) {
                    let dx = x - centre.x, dy = y - centre.y
                    guard hypot(dx, dy) < 44 else { continue }
                    let here = CGPoint(x: x, y: y)
                    let turned = CGPoint(
                        x: centre.x + dx * cos(angle) - dy * sin(angle),
                        y: centre.y + dx * sin(angle) + dy * cos(angle)
                    )
                    checked += 1
                    if path.contains(here, using: .winding) != path.contains(turned, using: .winding) {
                        mismatched += 1
                    }
                }
            }
            return checked == 0 ? 0 : mismatched / checked
        }

        XCTAssertGreaterThan(
            disagreement(turnedBy: 30), 0.15,
            "a mark this symmetric under 30° is the uniform sparkle, not Anthropic's asterisk"
        )
    }

    /// Same contract the knot is held to: inside the 16pt slot, centred in it,
    /// still filling it, and scaling.
    func testClaudeBurstFitsItsSlotAndStaysCentred() {
        let slot = QuietIdentityMarkView.slot
        let rect = CGRect(x: 0, y: 0, width: slot, height: slot)
        let bounds = QuietClaudeBurst.path(in: rect).boundingRect

        XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.02, "the burst is off-centre horizontally")
        XCTAssertEqual(bounds.midY, rect.midY, accuracy: 0.02, "the burst is off-centre vertically")
        XCTAssertTrue(rect.contains(bounds), "the burst overflows its \(slot)pt slot: \(bounds)")

        XCTAssertGreaterThan(bounds.width / slot, 0.85)
        XCTAssertGreaterThan(bounds.height / slot, 0.85)
        // Square to within the artwork's own tolerance: the reference's tight
        // bounds are 1278 × 1279, and a uniform scale has to keep that.
        XCTAssertEqual(bounds.width, bounds.height, accuracy: 0.05)

        let doubled = QuietClaudeBurst.path(in: CGRect(x: 0, y: 0, width: 2 * slot, height: 2 * slot))
            .boundingRect
        XCTAssertEqual(doubled.width, bounds.width * 2, accuracy: 0.01)
    }

    // MARK: - OpenAI knot geometry

    /// The outline is the official mark's, transcribed — 8 subpaths, 36 cubics,
    /// 32 lines — not a construction that hopes to resemble it. The counts are
    /// asserted because the reader is what turns the transcription into
    /// geometry, and a reader that silently dropped a command would still draw
    /// *something* knot-shaped.
    func testKnotOutlineIsTheTranscribedOfficialPath() {
        let outline = QuietOpenAIKnot.outline
        var moves = 0, lines = 0, curves = 0, closes = 0
        for segment in outline {
            switch segment {
            case .move: moves += 1
            case .line: lines += 1
            case .curve: curves += 1
            case .close: closes += 1
            }
        }
        XCTAssertEqual(moves, 8, "a subpath went missing — the knot loses a strand or a counter")
        XCTAssertEqual(closes, 8, "every subpath of a filled outline has to close")
        XCTAssertEqual(curves, 36)
        XCTAssertEqual(lines, 32)

        // The offline normalization centres the outline's *tight* bounds on
        // 12,12 and scales its long side to 24, so every on-curve point sits in
        // the viewbox and the control points stray only a fraction outside it.
        let points = outline.flatMap { segment -> [CGPoint] in
            switch segment {
            case let .move(point), let .line(point): [point]
            case let .curve(to, control1, control2): [to, control1, control2]
            case .close: []
            }
        }
        XCTAssertGreaterThan(points.count, 100)
        let coordinates = points.flatMap { [$0.x, $0.y] }
        XCTAssertGreaterThan(coordinates.min() ?? -99, -0.5)
        XCTAssertLessThan(coordinates.max() ?? 99, 24.5)
    }

    /// The four-command reader, exercised on its own. `Z` closes, `M`/`L` take
    /// pairs, `C` takes triples, and a command whose numbers repeat emits one
    /// segment per group.
    func testOutlineReaderHandlesItsFourCommands() {
        let segments = QuietVectorOutline.segments("M1 2 L3 4 5 6 C7 8 9 10 11 12 Z")
        XCTAssertEqual(segments, [
            .move(CGPoint(x: 1, y: 2)),
            .line(CGPoint(x: 3, y: 4)),
            .line(CGPoint(x: 5, y: 6)),
            .curve(
                to: CGPoint(x: 11, y: 12),
                control1: CGPoint(x: 7, y: 8),
                control2: CGPoint(x: 9, y: 10)
            ),
            .close,
        ])
        XCTAssertTrue(QuietVectorOutline.segments("").isEmpty)
    }

    /// The logo is a six-fold knot, and the transcription has to still be one.
    /// Sampled rather than asserted on constants, because there are no
    /// symmetry constants any more — the outline either maps onto itself under
    /// a 60° turn or it is not the mark.
    ///
    /// The tolerance is real: the official outline is hand-tuned, so a 60° turn
    /// disagrees on ~5.6% of the mark's own area (measured on a 1024² raster of
    /// the reference). The 30° control is what gives this teeth — an ordinary
    /// blob would pass a lax 60° check and fail nothing else.
    func testKnotIsSixFoldSymmetric() {
        let rect = CGRect(x: 0, y: 0, width: 96, height: 96)
        let path = QuietOpenAIKnot.path(in: rect)
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        func disagreement(turnedBy degrees: Double) -> Double {
            let angle = degrees * .pi / 180
            var checked = 0.0
            var mismatched = 0.0
            for step in stride(from: 3.0, to: 96, by: 1.5) {
                for other in stride(from: 3.0, to: 96, by: 1.5) {
                    let point = CGPoint(x: step, y: other)
                    let dx = point.x - centre.x
                    let dy = point.y - centre.y
                    guard hypot(dx, dy) < 44 else { continue }
                    let turned = CGPoint(
                        x: centre.x + dx * cos(angle) - dy * sin(angle),
                        y: centre.y + dx * sin(angle) + dy * cos(angle)
                    )
                    checked += 1
                    if path.contains(point) != path.contains(turned) { mismatched += 1 }
                }
            }
            return checked == 0 ? 1 : mismatched / checked
        }

        XCTAssertLessThan(disagreement(turnedBy: 60), 0.10, "the knot lost its six-fold symmetry")
        XCTAssertGreaterThan(
            disagreement(turnedBy: 30),
            0.30,
            "a shape this symmetric under 30° is a disc, not a knot"
        )
    }

    /// The mark has to stay inside its 16pt slot — a mark that overflows
    /// collides with the row's title column — and stay centred in it, and still
    /// fill it. Filled now, so there is no stroke to inset for.
    func testKnotFitsItsSlotAndStaysCentred() {
        let slot = QuietIdentityMarkView.slot
        let rect = CGRect(x: 0, y: 0, width: slot, height: slot)
        let bounds = QuietOpenAIKnot.path(in: rect).boundingRect

        XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.01, "the knot is off-centre horizontally")
        XCTAssertEqual(bounds.midY, rect.midY, accuracy: 0.05, "the knot is off-centre vertically")
        XCTAssertTrue(rect.contains(bounds), "the knot overflows its \(slot)pt slot: \(bounds)")

        // …but it still fills the slot: a mark that shrank to nothing would
        // also pass the containment check above.
        XCTAssertGreaterThan(bounds.width / slot, 0.85)
        XCTAssertGreaterThan(bounds.height / slot, 0.85)

        // And it scales: the same outline at 2× is the same mark twice the size.
        let doubled = QuietOpenAIKnot.path(in: CGRect(x: 0, y: 0, width: 2 * slot, height: 2 * slot))
            .boundingRect
        XCTAssertEqual(doubled.width, bounds.width * 2, accuracy: 0.01)
    }

    func testUnrecognizedAgentsFallBackToTheirInitial() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "Gemini", processName: "node"), .letter("G"))
        XCTAssertEqual(QuietIdentity.identity(agentName: "aider", processName: nil), .letter("A"))
        XCTAssertEqual(QuietIdentity.identity(agentName: "  opencode", processName: nil), .letter("O"))
    }

    /// Documents the precedence the spec lists: the transport is checked before
    /// the initial fallback, so an unrecognized agent reached over ssh still
    /// reads as an ssh row.
    func testSSHTransportWinsOverAnUnrecognizedAgentName() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "Gemini", processName: "ssh"), .ssh)
    }

    /// …but a recognized agent still wins over the transport.
    func testRecognizedAgentWinsOverTheSSHTransport() {
        XCTAssertEqual(QuietIdentity.identity(agentName: "Claude Code", processName: "ssh"), .claude)
    }

    // MARK: - Display-title fallback

    func testTitleThatSaysSomethingIsKeptVerbatim() {
        XCTAssertEqual(
            QuietRailTitle.displayTitle(rawTitle: "build the rail", projectName: "Kaisola", processName: "zsh", ordinal: 1),
            "build the rail"
        )
    }

    func testSessionsNamedAfterTheirProjectBecomeProcessOrdinals() {
        // Three same-named sessions must read as three different rows.
        let titles = (1...3).map { ordinal in
            QuietRailTitle.displayTitle(rawTitle: "Kaisola", projectName: "Kaisola", processName: "zsh", ordinal: ordinal)
        }
        XCTAssertEqual(titles, ["zsh · 1", "zsh · 2", "zsh · 3"])
        XCTAssertEqual(Set(titles).count, 3)
    }

    func testProjectNamedTitleWithoutAProcessFallsBackToTerminalOrdinal() {
        XCTAssertEqual(
            QuietRailTitle.displayTitle(rawTitle: "Kaisola", projectName: "Kaisola", processName: nil, ordinal: 2),
            "Terminal 2"
        )
    }

    func testTitleComparisonIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(
            QuietRailTitle.displayTitle(rawTitle: "  kaisola \n", projectName: "Kaisola", processName: "fish", ordinal: 4),
            "fish · 4"
        )
    }

    // MARK: - Repeated-prefix labels

    /// The complaint: a project full of agent sessions names them all the same
    /// way, the rail truncates from the tail, and the column that exists to
    /// tell rows apart renders three different sessions as "Codex · MAT…".
    func testRepeatedProviderPrefixesGiveWayToWhatTheRowsActuallySay() {
        let titles = [
            "Codex · MATLAB kernel bridge",
            "Codex · MATLAB plotting spike",
            "Codex · MATLAB solver notes",
        ]
        let labels = QuietRailLabels.labels(for: titles)

        XCTAssertEqual(
            labels.map(\.text),
            ["MATLAB kernel bridge", "MATLAB plotting spike", "MATLAB solver notes"]
        )
        XCTAssertEqual(labels.map(\.droppedLead), Array(repeating: "Codex · ", count: 3))
        // The lead was enough on its own — nothing here needs the middle.
        XCTAssertEqual(labels.map(\.truncation), Array(repeating: .tail, count: 3))
        // …and what the rows draw now differs inside the window the rail can
        // actually show, which is the whole point.
        XCTAssertEqual(Set(labels.map { visiblePrefix($0.text) }).count, 3)
    }

    /// "Handle many same-provider sessions in one project." Eight Codex rows
    /// whose subjects diverge early: none of them *collide* at the window, so a
    /// collision-only rule would leave all eight spending eight characters on
    /// the word their identity mark already draws.
    func testManySameProviderSessionsAllStopRepeatingTheProvider() {
        let subjects = [
            "sidebar width budget",
            "changelog generator",
            "release on push",
            "glass energy modes",
            "terminal image attach",
            "worktree session tooling",
            "markdown fidelity fix",
            "native paired capture",
        ]
        let labels = QuietRailLabels.labels(for: subjects.map { "Codex · " + $0 })

        XCTAssertEqual(labels.map(\.text), subjects)
        XCTAssertTrue(labels.allSatisfy { $0.droppedLead == "Codex · " })
        XCTAssertEqual(Set(labels.map { visiblePrefix($0.text) }).count, subjects.count)
    }

    /// The other half of the rule: a project whose rows share nothing gets its
    /// titles back untouched. No chip, no elision, no middle truncation — the
    /// resting rail is exactly what it was.
    func testTitlesThatShareNothingAreDrawnVerbatim() {
        let titles = ["build the rail", "Audit Kaisola Sidebar parity", "Ship the changelog generator"]
        let labels = QuietRailLabels.labels(for: titles)

        XCTAssertEqual(labels.map(\.text), titles)
        XCTAssertTrue(labels.allSatisfy { $0.droppedLead.isEmpty })
        XCTAssertTrue(labels.allSatisfy { $0.truncation == .tail })
        XCTAssertTrue(labels.allSatisfy { !$0.elidesTitle })
    }

    /// `QuietRailTitle`'s ordinals share a lead and must keep it: without the
    /// remainder floor these three rows would draw as "1", "2", "3".
    func testProcessOrdinalRowsKeepTheirProcessName() {
        let titles = (1...3).map { ordinal in
            QuietRailTitle.displayTitle(rawTitle: "Kaisola", projectName: "Kaisola", processName: "zsh", ordinal: ordinal)
        }
        let labels = QuietRailLabels.labels(for: titles)

        XCTAssertEqual(labels.map(\.text), ["zsh · 1", "zsh · 2", "zsh · 3"])
        XCTAssertTrue(labels.allSatisfy { $0.droppedLead.isEmpty })
    }

    /// A lead is a whole segment or it is nothing. Two titles opening with the
    /// same two words share no separator, so the rail keeps both words and
    /// truncates from the middle instead — dropping "MATLAB kernel " would
    /// delete the subject rather than a preamble.
    func testASharedRunOfPlainWordsIsNeverCutOffTheFront() {
        let titles = ["MATLAB kernel bridge alpha", "MATLAB kernel bridge beta"]
        let labels = QuietRailLabels.labels(for: titles)

        XCTAssertEqual(labels.map(\.text), titles)
        XCTAssertTrue(labels.allSatisfy { $0.droppedLead.isEmpty })
        XCTAssertEqual(labels.map(\.truncation), [.middle, .middle])
        XCTAssertTrue(labels.allSatisfy { $0.elidesTitle })
    }

    /// Both steps on one row: the lead goes, and what is left still reads the
    /// same for the first dozen characters, so the row keeps its tail too.
    func testWhatTheLeadCannotSeparateTruncatesFromTheMiddle() {
        let labels = QuietRailLabels.labels(for: [
            "Codex · MATLAB kernel bridge alpha",
            "Codex · MATLAB kernel bridge beta",
        ])

        XCTAssertEqual(labels.map(\.droppedLead), ["Codex · ", "Codex · "])
        XCTAssertEqual(labels.map(\.text), ["MATLAB kernel bridge alpha", "MATLAB kernel bridge beta"])
        XCTAssertEqual(labels.map(\.truncation), [.middle, .middle])
    }

    /// Nested segments collapse as far as they can, per sharing group rather
    /// than per project: the two MATLAB rows lose more than the row that only
    /// shares the provider.
    func testNestedSegmentsCollapseAsFarAsTheirOwnGroupAllows() {
        let labels = QuietRailLabels.labels(for: [
            "Codex · MATLAB: kernel bridge",
            "Codex · MATLAB: plotting spike",
            "Codex · sidebar width budget",
        ])

        XCTAssertEqual(labels.map(\.droppedLead), ["Codex · MATLAB: ", "Codex · MATLAB: ", "Codex · "])
        XCTAssertEqual(labels.map(\.text), ["kernel bridge", "plotting spike", "sidebar width budget"])
    }

    /// Rows that fit the lane whole are not paying for their repeated lead, so
    /// they keep it — the elision is a width economy, not a style rule.
    func testAShortRepeatedLeadIsLeftAloneWhenNobodyIsPayingForIt() {
        let labels = QuietRailLabels.labels(for: ["ops: up", "ops: down"])
        XCTAssertTrue(labels.allSatisfy { $0.droppedLead.isEmpty })
    }

    /// All-or-nothing per sharing group: one row that would be left holding
    /// almost nothing keeps the lead on the whole group, rather than the column
    /// acquiring two different leading edges.
    func testALeadStaysWhenAnyRowInItsGroupWouldBeLeftWithNothing() {
        let labels = QuietRailLabels.labels(for: [
            "Kaisola · a",
            "Kaisola · sidebar width budget rework",
        ])
        XCTAssertTrue(labels.allSatisfy { $0.droppedLead.isEmpty })
    }

    /// Two rows that genuinely say the same thing are `QuietRailTitle`'s
    /// problem, not this one, and no truncation strategy separates them — so
    /// they are left alone rather than both being middle-truncated for nothing.
    func testIdenticalTitlesAreLeftToTheOrdinalFallback() {
        let labels = QuietRailLabels.labels(for: ["Audit Kaisola Sidebar parity", "Audit Kaisola Sidebar parity"])
        XCTAssertTrue(labels.allSatisfy { $0.truncation == .tail })
        XCTAssertTrue(labels.allSatisfy { !$0.elidesTitle })
    }

    // MARK: - Repeated-prefix width fixtures

    /// The width-budget fixture the acceptance criteria ask for, with the
    /// issue's own titles: render each label into the *measured* title lane the
    /// way the row draws it, and compare the results the way the eye does.
    ///
    /// The first assertion is the bug, stated as a fixture rather than as prose:
    /// drawn verbatim with tail truncation — what the rail did — three distinct
    /// sessions collapse to one string.
    func testRepeatedPrefixTitlesStayApartInTheMeasuredTitleLane() {
        // The shared lead has to outlast the *current* resting lane for the
        // collapse to reproduce; the 12pt session title draws more characters
        // into the same lane than the 13pt one these titles were sampled at,
        // so the fixture carries the longer prefix real Codex sessions produce.
        let titles = [
            "Codex · MATLAB integration kernel bridge review",
            "Codex · MATLAB integration kernel bridge plotting",
            "Codex · MATLAB integration kernel bridge solver",
        ]

        let before = titles.map { QuietRailLaneFixture.drawn(.verbatim($0), in: QuietRailLaneFixture.restingLane) }
        XCTAssertEqual(
            Set(before).count,
            1,
            "the fixture stopped reproducing the bug it was written for: \(before)"
        )

        let after = QuietRailLabels.labels(for: titles)
            .map { QuietRailLaneFixture.drawn($0, in: QuietRailLaneFixture.restingLane) }
        XCTAssertEqual(
            Set(after).count,
            titles.count,
            "two rows still draw the same string: \(after)"
        )
    }

    /// …and the same fixture for the case a shared lead cannot fix, where the
    /// distinguishing word is at the *end* of the title.
    func testTitlesThatDifferOnlyAtTheirTailStayApartInTheMeasuredLane() {
        // Long enough that the v0.1.125 resting lane (290pt rail) still
        // truncates both to the same visible prefix.
        let titles = [
            "MATLAB kernel bridge integration alpha",
            "MATLAB kernel bridge integration beta",
        ]

        let before = titles.map { QuietRailLaneFixture.drawn(.verbatim($0), in: QuietRailLaneFixture.restingLane) }
        XCTAssertEqual(Set(before).count, 1, "the fixture no longer reproduces: \(before)")

        let after = QuietRailLabels.labels(for: titles)
            .map { QuietRailLaneFixture.drawn($0, in: QuietRailLaneFixture.restingLane) }
        XCTAssertEqual(Set(after).count, titles.count, "middle truncation lost the tail: \(after)")
        XCTAssertTrue(after.allSatisfy { $0.hasSuffix("alpha") || $0.hasSuffix("beta") })
    }

    /// The approximation this whole strategy rests on: the character window
    /// `QuietRailLabels` calls "the same at a glance" must not be wider than
    /// what the lane really draws, or a pair the rail renders identically slips
    /// past it. Held against the real font at the rail's resting width, and
    /// again at its narrowest, using the issue's own title.
    func testTheAmbiguityWindowIsNoWiderThanWhatTheLaneDraws() {
        let sample = "Codex · MATLAB kernel bridge"
        let resting = QuietRailLaneFixture.tailCharacters(of: sample, in: QuietRailLaneFixture.restingLane)
        XCTAssertLessThanOrEqual(
            QuietRowBudget.ambiguousTitleCharacters,
            resting,
            "the window is wider than the \(resting) characters the 210pt lane draws"
        )
        // Not so narrow that it flags titles the rail tells apart perfectly
        // well: half the lane would call every shared word a collision.
        XCTAssertGreaterThan(QuietRowBudget.ambiguousTitleCharacters, resting / 2)
    }

    /// What the eye gets off a row before it has to hover: the leading run the
    /// rail counts as "the same at a glance".
    private func visiblePrefix(_ text: String) -> String {
        String(text.prefix(QuietRowBudget.ambiguousTitleCharacters))
    }

    // MARK: - Row width budget

    /// The regression this covers: at the default sidebar width a session title
    /// must read as a title, not as an abbreviation. v1.1.4 left it 56pt —
    /// "Audit K…" — because the row's fixed tokens were charged against it and
    /// its trailing lane could still be compressed below its own first glyph.
    func testSessionTitleGetsMostOfTheRowAtTheDefaultSidebarWidth() {
        // The fixture's fonts read the live metrics; hardcoding 13/10.5 here
        // was the duplication that let the fonts drift from the assertion.
        let titleFont = QuietRailLaneFixture.titleFont
        let timeFont = QuietRailLaneFixture.timeFont
        let timeWidth = ("now" as NSString).size(withAttributes: [.font: timeFont]).width

        let available = QuietRowBudget.titleWidth(
            sidebarWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            timeLabelWidth: timeWidth,
            showsReveal: false
        )
        // 100 → 90 with the 2026-08-28 narrowing: 196pt draws a 92.5pt lane.
        XCTAssertGreaterThan(available, 80, "the title lane lost its share of the row again")

        // Stated the way the complaint was: how much of a real title is legible.
        let sample = "Audit Kaisola Sidebar parity"
        var visible = 0
        for count in 1...sample.count {
            let candidate = String(sample.prefix(count)) + "…"
            let width = (candidate as NSString).size(withAttributes: [.font: titleFont]).width
            if width <= available { visible = count } else { break }
        }
        // 20 → 13 across the 2026-08-28 narrowings (245 → 196 → 180, twice by
        // request). This is the price of the narrow rail, stated rather than
        // hidden: "Audit Kaisola Sidebar parity" reads as "Audit Kaisol…"
        // instead of "Audit Kaisola Sideba…". The floor stays a floor — it is
        // what stops a future density pass spending the lane again — it is
        // simply set at what the requested width actually draws.
        XCTAssertGreaterThanOrEqual(
            visible,
            13,
            "only \(visible) characters survive at "
                + "\(NativeWorkspaceChrome.projectSidebarIdealWidth)pt"
        )

        // The hover-only reveal control may cost the title, but never this much.
        XCTAssertGreaterThan(
            QuietRowBudget.titleWidth(
                sidebarWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
                timeLabelWidth: timeWidth,
                showsReveal: true
            ),
            // 80 → 60 across the two narrowings; the reveal lane is 63.5pt.
            60
        )
    }

    // MARK: - Hierarchy step

    /// The complaint this covers: after the v1.1.5 width-budget work a session
    /// sat 10pt in from its project row, which the eye read as a ragged edge
    /// rather than as nesting. The step is now paid for out of the wider
    /// default sidebar, so it does not come back out of the title.
    func testSessionsSitClearlyDeeperThanTheirProjectRow() {
        XCTAssertGreaterThan(
            QuietRowBudget.sessionIndent,
            QuietRowBudget.projectIndent,
            "sessions must not start on the same column as their project"
        )
        XCTAssertGreaterThanOrEqual(
            QuietRowBudget.indentStep,
            QuietIdentityMarkView.slot,
            "the hierarchy step is narrower than one identity mark — it reads as ragged, not nested"
        )
        // v1.1.7 pushed it to two full identity slots (32pt). v1.1.8 gives 4 of
        // those back, and the reason is worth stating rather than hiding in a
        // smaller literal: the rail narrows to 210, and at a 40pt indent the
        // title lane renders 14 characters — under the 15-character floor the
        // test above holds. Something had to pay, and the indent is the cheaper
        // of the two: at 28pt a session's mark still starts 12pt past where its
        // project's mark ends, so the row is still unambiguously nested, while
        // 14 characters of a title is the abbreviation problem the whole budget
        // exists to prevent.
        XCTAssertGreaterThanOrEqual(
            QuietRowBudget.indentStep,
            QuietIdentityMarkView.slot,
            "the hierarchy step is under one identity mark — that reads as ragged"
        )
        // The step was two full mark-widths while the rail could afford it.
        // The 2026-08-28 narrowings (245 → 196 → 180, twice by request) ended
        // that: at 180 a 28pt step is 15.5% of the whole column, so the
        // hierarchy would have been eating the title lane exactly as the title
        // lane ran out. The step gives 8pt back and the contract weakens from
        // "two marks" to "more than one mark", which is what actually makes
        // the nesting read — a session's mark still begins past where its
        // project's mark ends, with 6pt to spare.
        XCTAssertGreaterThan(
            QuietRowBudget.indentStep,
            QuietIdentityMarkView.slot,
            "the session indent went shallow again"
        )
        XCTAssertEqual(QuietRowBudget.sessionIndent, 28)
        XCTAssertEqual(QuietRowBudget.indentStep, 20)
        XCTAssertGreaterThan(
            CGFloat(QuietRowBudget.indentStep),
            QuietRailMetrics.mark,
            "a session's mark must still start past where its project's mark ends"
        )
    }

    /// The size step that makes session rows read as *contents of* the project
    /// row above them, encoded from the v0.1.127 request: smaller text and
    /// symbols in the session lane, project rows untouched.
    func testSessionRowsSitTighterThanTheProjectRowsTheyHangUnder() {
        XCTAssertLessThan(
            QuietRailMetrics.sessionRowHeight,
            QuietRailMetrics.rowHeight,
            "a session row is no smaller than the project row above it"
        )
        XCTAssertGreaterThanOrEqual(
            QuietRailMetrics.sessionRowHeight,
            24,
            "below 24pt the row stops being a comfortable pointer target"
        )
        XCTAssertLessThan(QuietRailMetrics.titleText, 13, "the session title did not shrink")
        XCTAssertGreaterThanOrEqual(
            QuietRailMetrics.titleText,
            11,
            "session titles must stay at or above the 11pt floor"
        )
        XCTAssertLessThan(
            QuietRailMetrics.mark,
            QuietIdentityMarkView.slot,
            "the rail draws marks at its own, smaller slot"
        )
        XCTAssertGreaterThan(
            QuietRailMetrics.mark,
            QuietRailMetrics.titleText,
            "a mark smaller than its own title reads as a bullet, not an identity"
        )
        // The row still holds its type: 12pt of text needs ~14.3pt of line.
        XCTAssertGreaterThan(
            QuietRailMetrics.sessionRowHeight,
            QuietRailMetrics.titleText * 1.8
        )
    }

    /// Guards the one soft spot of the smaller slot: glyphs drawn bare in a
    /// mark frame must scale with it, and the project glyph may overhang only
    /// into the mark gap.
    func testTheRailsGlyphsFitTheSlotTheyAreDrawnIn() {
        XCTAssertLessThanOrEqual(QuietRailMetrics.markSymbolText, QuietRailMetrics.mark)
        XCTAssertEqual(
            Double(QuietRailMetrics.markSymbolText),
            Double(
                QuietIdentityMarkView.symbolSize * QuietRailMetrics.mark
                    / QuietIdentityMarkView.slot
            ),
            accuracy: 0.0001,
            "the rail's bare symbols drifted off the mark view's optical size"
        )
        XCTAssertLessThanOrEqual(
            QuietRailMetrics.projectMarkText,
            QuietRailMetrics.mark,
            "the folder glyph now overhangs its slot by more than the mark gap"
        )
    }

    /// Three releases have now narrowed the rail, and each one has to survive
    /// the comparison that started the whole budget: the v1.1.4 row that shipped
    /// a 56pt title lane — "Audit K…", seven characters — at a 200pt sidebar.
    ///
    /// Deliberately measured against what v1.1.4 *shipped* rather than against a
    /// reconstruction of its arithmetic. The reconstruction is the tempting
    /// version and it is the wrong one: v1.1.4 also paid `.sidebar` list style's
    /// ~31pt of platform row inset, which v1.1.5 cancelled and no formula
    /// written from today's constants remembers. Comparing against a model that
    /// omits it would quietly hold this release to a standard the old release
    /// never actually met.
    func testTheNarrowerRailStillOutTitlesTheOldOne() {
        XCTAssertGreaterThan(
            NativeWorkspaceChrome.projectSidebarMaximumWidth,
            NativeWorkspaceChrome.projectSidebarIdealWidth
        )
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarMinimumWidth, 168, "the narrow rail must not move")

        let timeFont = QuietRailLaneFixture.timeFont
        let timeWidth = ("now" as NSString).size(withAttributes: [.font: timeFont]).width

        let now = QuietRowBudget.titleWidth(
            sidebarWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            timeLabelWidth: timeWidth,
            showsReveal: false
        )
        // The measured v1.1.4 lane, from the bug report this budget was built
        // for. Not derived — recorded.
        let shippedInV114: CGFloat = 56
        // 1.75× → 1.45×: the 180pt lane is 84.5pt, still half again the 56pt
        // that started this budget, but the two 2026-08-28 narrowings spend
        // most of the margin v0.1.125 had banked. What this still guards is
        // the original defect — the indent quietly eating the title lane —
        // which is why it is a ratio against the recorded bug and not a
        // literal that gets re-typed at every width.
        XCTAssertGreaterThan(
            now,
            shippedInV114 * 1.45,
            "the narrower rail handed the title back to the indent"
        )

        // …and the resting width sits at 196 as of 2026-08-28, by request —
        // "at least 20% less wide" than the 245 that 2026-08-26 set, which is
        // 196 on the nose and matches the Files rail's own default. What this
        // release still owes is that the rail stays inside its own bounds and
        // the title lane it buys is real.
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarIdealWidth, 180)
    }

    // MARK: - Header "+" containment

    /// The clipping bug: the pinned header's `+` rendered half outside the
    /// project row, because it was a bare sibling of a `maxWidth: .infinity`
    /// button and got laid out past the row's trailing edge. The fix is a
    /// reserved slot, so containment is arithmetic rather than luck.
    func testThePinnedHeaderPlusHasAReservedSlotInsideTheRow() {
        XCTAssertGreaterThan(QuietRowBudget.headerPlusSlot, 0)
        // The slot has to be wider than the glyph it holds, or the menu spills
        // out of it the same way it used to spill out of the row.
        XCTAssertGreaterThanOrEqual(QuietRowBudget.headerPlusSlot, 16)

        // …and it sits far enough in that it lands inside the active project's
        // tinted capsule, which is itself inset by `chromeInset`.
        XCTAssertGreaterThan(
            QuietRowBudget.headerPlusTrailingInset,
            KaisolaVisualSystem.chromeInset,
            "the + sits on the capsule's edge instead of inside it"
        )

        // The whole reservation still has to leave the project name most of the
        // row: a slot that fixes clipping by eating the header is not a fix.
        // 0.2 → 0.22: the reservation itself has not moved a point (38pt).
        // The rail shrank under it — 38 was 15.5% of the 245pt column and is
        // 21% of the 180pt one — so the fraction is restated at what still
        // means "the name keeps most of the row" rather than left where a
        // narrowing would trip it.
        XCTAssertLessThan(
            QuietRowBudget.headerPlusReserved,
            NativeWorkspaceChrome.projectSidebarIdealWidth * 0.22
        )
    }

    /// "Make it easier to open new sessions" (Michael, round 2).
    ///
    /// Before this, every door to creation was either hidden or remembered: the
    /// `+` appeared only under the pointer, the context menus need a
    /// right-click on the right row, and ⌘T / the palette have to be known.
    /// The active project's `+` is now simply *there*.
    func testTheActiveProjectsNewSessionControlIsThereWithoutHovering() {
        XCTAssertTrue(
            QuietProjectHeaderControls.showsLaunchControl(isActive: true, hovering: false),
            "the active project's + is hidden until the pointer finds it"
        )
        XCTAssertTrue(
            QuietProjectHeaderControls.showsLaunchControl(isActive: true, hovering: true)
        )
    }

    func testTheNewSessionControlOwnsAUsableHitTarget() {
        XCTAssertGreaterThanOrEqual(
            QuietProjectHeaderControls.launchHitTarget,
            26,
            "the visible + must not keep an intrinsic glyph-sized hit target"
        )
        XCTAssertGreaterThanOrEqual(
            QuietRowBudget.headerPlusSlot,
            QuietProjectHeaderControls.launchHitTarget,
            "the reserved header slot must contain the full button hit target"
        )
    }

    func testNewSessionDraftRowUsesItsDraftIdentityAndSelection() {
        let draft = NewSessionDraft(id: "new-session-123", projectID: "project-a")

        let selected = QuietNewSessionRowPresentation(
            draft: draft,
            selectedDraftID: draft.id,
            isActiveProject: true
        )
        let inactive = QuietNewSessionRowPresentation(
            draft: draft,
            selectedDraftID: draft.id,
            isActiveProject: false
        )
        let resting = QuietNewSessionRowPresentation(
            draft: draft,
            selectedDraftID: nil,
            isActiveProject: true
        )

        XCTAssertEqual(selected.accessibilityIdentifier, "new-session-123")
        XCTAssertEqual(selected.accessibilityLabel, "New Session")
        XCTAssertTrue(selected.isSelected)
        XCTAssertFalse(inactive.isSelected)
        XCTAssertFalse(resting.isSelected)
    }

    /// …and the rail does not become a toolbar to do it. Exactly one project is
    /// active, so exactly one `+` rests in the column; every other project's
    /// stays behind the pointer.
    func testOnlyTheActiveProjectRestsAControlInTheColumn() {
        XCTAssertFalse(
            QuietProjectHeaderControls.showsLaunchControl(isActive: false, hovering: false),
            "an inactive project would draw a resting + too — one per row is a toolbar"
        )
        XCTAssertTrue(
            QuietProjectHeaderControls.showsLaunchControl(isActive: false, hovering: true)
        )
        // The disclosure chevron is a hint on top of a row that is already the
        // disclosure control, so it stays hover-only in both placements.
        XCTAssertFalse(QuietProjectHeaderControls.showsDisclosureChevron(hovering: false))
        XCTAssertTrue(QuietProjectHeaderControls.showsDisclosureChevron(hovering: true))
    }

    /// A control that is only there under the pointer can share its edge with a
    /// drag handle; a permanent one cannot.
    ///
    /// The sidebar's resize corridor is an overlay on the trailing edge of the
    /// List and reaches `projectSidebarDividerReach` inward. At the old 10pt
    /// inset the corridor covered the last half-point of the `+` slot —
    /// documented in `RootShellView` as a known overlap and tolerated while the
    /// `+` was hover-only. Now that it is the app's main creation door, the slot
    /// has to start clear of the corridor by construction.
    func testTheRestingPlusDoesNotShareItsEdgeWithTheResizeCorridor() {
        XCTAssertGreaterThan(
            QuietRowBudget.headerPlusTrailingInset,
            NativeWorkspaceChrome.projectSidebarDividerReach,
            "the resize corridor overlaps the + the user is aiming at"
        )
    }

    // MARK: - Row emphasis and selection

    /// v1.1.9 gives the selected surface row a colour and a pill back, but the
    /// weight step stays: it is the cue that survives a user who cannot
    /// separate the accent from the surrounding grey, and it costs nothing.
    func testTheVisibleSessionKeepsItsWeightStepOnTopOfTheColour() {
        XCTAssertNotEqual(QuietRowEmphasis.selectedWeight, QuietRowEmphasis.restingWeight)
        XCTAssertEqual(QuietRowEmphasis.weight(isSelected: true), .semibold)
        XCTAssertEqual(QuietRowEmphasis.weight(isSelected: false), .regular)
    }

    /// The active project is signalled by weight and by weight only — the
    /// tinted glass capsule is gone. A table where the two collapsed would
    /// leave the rail with no "which project am I in" signal at all.
    func testTheActiveProjectIsSignalledByWeightAlone() {
        XCTAssertNotEqual(QuietProjectEmphasis.activeWeight, QuietProjectEmphasis.restingWeight)
        XCTAssertEqual(QuietProjectEmphasis.weight(isActive: true), .semibold)
        XCTAssertEqual(QuietProjectEmphasis.weight(isActive: false), .regular)
        // The heading no longer outranks the row it contains, and must not: a
        // project name is 11pt secondary while a session title is 12pt primary
        // on a visibly shorter row — size, ink, and height carry the step —
        // so the two are separated by size and ink instead of by weight. That is
        // the correction — the folder names used to be the loudest text in a
        // column whose job is to point at what is inside them.
        XCTAssertLessThan(
            QuietRailMetrics.headerText,
            QuietRailMetrics.titleText,
            "a project heading must read below the surfaces inside it"
        )
        // The weights are now allowed to match: size and ink carry the
        // heading/row distinction, so this no longer has to.
    }

    /// Exactly one row wears the pill, and which one is a rule rather than a
    /// rendering accident. Both ways it can break are invisible in a screenshot
    /// of the happy path.
    func testExactlyOneSurfaceRowIsSelected() {
        // Nothing on screen: no row is selected, and no row is invented.
        XCTAssertNil(QuietRowSelection.selectedID(visibleIDs: [], focusedPaneID: nil))
        XCTAssertNil(QuietRowSelection.selectedID(visibleIDs: [], focusedPaneID: "a"))

        // The ordinary case: one visible surface, with or without focus.
        XCTAssertEqual(QuietRowSelection.selectedID(visibleIDs: ["a"], focusedPaneID: nil), "a")
        XCTAssertEqual(QuietRowSelection.selectedID(visibleIDs: ["a"], focusedPaneID: "a"), "a")

        // A split shows two surfaces; the focused pane wins, so one pill.
        XCTAssertEqual(
            QuietRowSelection.selectedID(visibleIDs: ["a", "b"], focusedPaneID: "b"),
            "b"
        )

        // Focus naming a surface that is not on screen (another window, or one
        // just hidden) must fall back to a real row, never to no row.
        XCTAssertEqual(
            QuietRowSelection.selectedID(visibleIDs: ["a", "b"], focusedPaneID: "ghost"),
            "a"
        )
        XCTAssertEqual(
            QuietRowSelection.selectedID(visibleIDs: ["a", "b"], focusedPaneID: nil),
            "a"
        )
    }

    // MARK: - Footer budget

    /// The chip's width, as the footer actually renders it: text only, plus its
    /// own internal padding on each side.
    private var usageChipWidth: CGFloat {
        let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        return ("62%" as NSString).size(withAttributes: [.font: chipFont]).width
            + FooterAccountBudget.usageChipHorizontalPadding * 2
    }

    private var footerNameFont: NSFont { NSFont.systemFont(ofSize: 12, weight: .medium) }

    private func footerNameRenders(_ name: String) -> CGFloat {
        (name as NSString).size(withAttributes: [.font: footerNameFont]).width
    }

    /// The footer regression: the account chip was framed to a fixed 118pt and
    /// then `fixedSize`d, so "michael ofen…" stayed truncated no matter how far
    /// the sidebar was dragged. The name's width is now a function of the
    /// footer's, and it must still beat that old constant.
    func testAccountNameGetsMoreThanTheOldFixedChipAtTheDefaultWidth() {
        let width = FooterAccountBudget.nameWidth(
            footerWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            usageChipWidth: usageChipWidth
        )

        // v1.1.8 intentionally uses the first name at every width. The 210pt
        // rail must give that stable label room even with usage visible; the
        // whole display name remains in help text and the account menu.
        let full = "michael ofengenden"
        let displayed = FooterAccountName.displayed(full)
        XCTAssertEqual(displayed, "michael")
        XCTAssertGreaterThanOrEqual(
            width, footerNameRenders(displayed),
            "the first-name label takes an ellipsis at the default width"
        )

        // The margin is stated rather than assumed, because the footer was
        // deliberately enlarged after this test was written: the avatar went
        // 18 → 24, the three control slots 14 → 18, and the label 12 → 13pt,
        // which together spend 18pt of this lane and 3.3pt on the label.
        //
        // That trade is only affordable because the label is the *first name*.
        // Measured at the 210pt rail with the usage chip showing, the lane is
        // 80.0pt and "michael" needs 48.2pt. The contract this test exists to
        // defend is the one directly above — that the label never truncates at
        // the default width — so the margin below is a comfort floor, not the
        // contract, and it is asserted at a value the current sizes clear by
        // more than 10pt rather than at whatever they happen to produce.
        // 20 → 4 with the 2026-08-28 narrowing to 180. The CONTRACT above
        // still holds — "michael" renders without an ellipsis — but the
        // comfort margin is spent: a first name much longer than this one
        // will truncate at the default width, and only the help text and the
        // account menu will carry it in full. Recorded here so the next
        // person to look sees a deliberate trade rather than a near miss.
        XCTAssertGreaterThan(width - footerNameRenders(displayed), 4)

        // The rungs that are still load-free to keep, pinned so a later pass
        // cannot quietly take these points back as well.
        XCTAssertEqual(FooterAccountBudget.leadingPadding, 6)
        XCTAssertEqual(FooterAccountBudget.usageChipHorizontalPadding, 1)

        // And the lane must remain a *function* of the footer, which is the
        // original regression: the old chip was framed to a fixed 118pt and
        // then fixedSize'd, so dragging the sidebar wider changed nothing.
        let wider = FooterAccountBudget.nameWidth(
            footerWidth: NativeWorkspaceChrome.projectSidebarIdealWidth + 60,
            usageChipWidth: usageChipWidth
        )
        XCTAssertEqual(wider - width, 60, accuracy: 0.001)
    }

    /// The label is stable across sidebar widths: first token, account casing
    /// preserved. Single-token names and the email fallback stay intact.
    func testFooterAccountNameUsesOnlyTheFirstToken() {
        XCTAssertEqual(FooterAccountName.displayed("michael ofengenden"), "michael")
        XCTAssertEqual(FooterAccountName.displayed("Michael Ofengenden"), "Michael")
        XCTAssertEqual(FooterAccountName.displayed("Michael Ofengenden Jr."), "Michael")
        XCTAssertEqual(FooterAccountName.displayed("Ada Byron Lovelace"), "Ada")
        XCTAssertEqual(FooterAccountName.displayed("Kaisola"), "Kaisola")
        XCTAssertEqual(
            FooterAccountName.displayed("mofengenden@berkeley.edu"),
            "mofengenden@berkeley.edu"
        )
        XCTAssertEqual(FooterAccountName.displayed(""), "")
        XCTAssertEqual(FooterAccountName.displayed("michael   ofengenden  "), "michael")
    }

    /// The fix is in the slots and gaps shared by every control, not a
    /// special case for the quiet footer: charging for the attention bell too
    /// (its reserved control slot stands for the badge’s old footprint) still has
    /// to recover at least the same 18pt the quiet case does, compared against
    /// what the pre-fix arithmetic gave the name in that same busy state.
    func testTheRecoveryHoldsWithTheAttentionBellShowingToo() {
        let chip = usageChipWidth

        let width = FooterAccountBudget.nameWidth(
            footerWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            usageChipWidth: chip
        )

        // Pre-fix arithmetic (controlSlot 22, gap 5) for this same busy state,
        // written out rather than re-derived so the comparison can't drift with
        // the constants under test. The bell was a 30pt badge then; it is a
        // fixed control slot now, charged whether or not it is lit.
        let bellWidthBeforeTheFix: CGFloat = 30
        let brokenWidthWithBell: CGFloat = NativeWorkspaceChrome.projectSidebarIdealWidth
            - FooterAccountBudget.horizontalPadding
            - FooterAccountBudget.avatarSlot
            - (22 * 2 + 5 * 2 + (chip + 5) + (bellWidthBeforeTheFix + 5))

        XCTAssertGreaterThanOrEqual(
            width - brokenWidthWithBell, 18,
            "the recovery must hold even when the attention bell is also charged for"
        )
    }

    /// The bell's lane is constant, so nothing in the footer moves when the
    /// inbox fills or empties.
    ///
    /// This is the whole point of the change: the cluster is right-aligned as a
    /// unit, so a conditionally-present control slid the gear and the usage
    /// percentage sideways every time an agent finished a turn — a button that
    /// appeared from nowhere in the middle of the row and shoved its neighbours.
    /// There is now only ONE name width, whatever the inbox is doing.
    func testTheAttentionBellNeverMovesTheRestOfTheFooter() {
        let ideal = NativeWorkspaceChrome.projectSidebarIdealWidth
        // The signature no longer admits an "attention showing" variant, which is
        // the structural form of the guarantee: there is no second answer.
        let quiet = FooterAccountBudget.nameWidth(footerWidth: ideal, usageChipWidth: 0)
        let twoControlEquivalent = ideal
            - FooterAccountBudget.horizontalPadding
            - FooterAccountBudget.avatarSlot
            - (FooterAccountBudget.controlSlot * 2 + FooterAccountBudget.gap * 2)
        XCTAssertEqual(
            twoControlEquivalent - quiet,
            FooterAccountBudget.controlSlot + FooterAccountBudget.gap,
            accuracy: 0.001,
            "the reserved bell lane must be charged against the name"
        )
    }

    /// …and it really is a function of the footer: widening the sidebar has to
    /// move the number, which is precisely what the fixed frame prevented.
    func testAccountNameWidthGrowsWithTheSidebar() {
        func width(_ sidebar: CGFloat) -> CGFloat {
            FooterAccountBudget.nameWidth(footerWidth: sidebar, usageChipWidth: 34)
        }
        let ideal = NativeWorkspaceChrome.projectSidebarIdealWidth
        XCTAssertGreaterThan(width(NativeWorkspaceChrome.projectSidebarMaximumWidth), width(ideal))
        XCTAssertGreaterThan(width(ideal), width(NativeWorkspaceChrome.projectSidebarMinimumWidth))
    }

    /// Every optional control is charged for, so the arithmetic degrades the
    /// way the layout does rather than only describing the quiet case.
    func testOptionalFooterControlsAreChargedAgainstTheName() {
        let ideal = NativeWorkspaceChrome.projectSidebarIdealWidth
        let quiet = FooterAccountBudget.nameWidth(footerWidth: ideal, usageChipWidth: 0)
        let withChip = FooterAccountBudget.nameWidth(footerWidth: ideal, usageChipWidth: 34)
        // The usage chip is the only control left that is charged only when it is
        // showing — and it sits at the cluster's leading edge, so its arrival
        // moves nothing to its right. The bell used to be charged this way too,
        // which is exactly why it jumped.
        XCTAssertEqual(quiet - withChip, 34 + FooterAccountBudget.gap, accuracy: 0.001)
    }

    // MARK: - Selected row pill

    /// The pill is the rail's one fill, and it is the ACCENT — not grey.
    ///
    /// It was neutral (black at 6%, white at 10%) with the accent reserved for
    /// the label, which put the column's only colour on one line of 13pt type and
    /// its loudest painted object on a grey bar. Michael: "only highlight tabs
    /// with blue, get rid of the gray highlighting when tab is on." That is also
    /// Safari's grammar, which the v1.1.9 pass named and then applied backwards.
    ///
    /// The ceiling stays: above roughly 0.30 in light this stops being a tint and
    /// becomes the saturated chip v1.1.7 was right to delete.
    func testTheSelectionPillIsAccentAtLowCoverage() {
        XCTAssertGreaterThan(
            QuietSelectionPill.lightFillOpacity, 0.10,
            "below this the accent does not read as colour on white"
        )
        XCTAssertLessThan(
            QuietSelectionPill.lightFillOpacity, 0.30,
            "a pill this strong is a chip, and it will out-shout the label sitting on it"
        )
        // Dark mode swallows the same coverage, so it gets more — still short of
        // a chip's worth.
        XCTAssertGreaterThan(
            QuietSelectionPill.fillOpacity(dark: true),
            QuietSelectionPill.fillOpacity(dark: false)
        )
        XCTAssertLessThan(QuietSelectionPill.fillOpacity(dark: true), 0.35)

        // At most the control rung, and strictly inside the inset radius: the
        // pill sits at the bottom of the ladder but no longer *tracks* it —
        // the 0.1.134 rounder pass moved controls 9 → 10 while session rows
        // stayed 26pt, and a tracking pill silently crossed the lozenge bound
        // below. The pill answers to its row height first, the ladder second.
        XCTAssertLessThanOrEqual(QuietSelectionPill.cornerRadius, KaisolaVisualSystem.controlRadius)
        XCTAssertLessThan(QuietSelectionPill.cornerRadius, KaisolaVisualSystem.insetRadius)
        // "A 12pt radius on a 32pt row reads as a lozenge rather than a row"
        // — that 0.375 ratio is the documented failure, and the session lane
        // (26pt) is now the tighter of the two rows the pill draws in. Both
        // halves of the ratio moved independently in v0.1.127 (radius 8 → 9,
        // session rows 32 → 26), so the bound is held here rather than
        // re-derived by eye on the next pass.
        XCTAssertLessThan(
            QuietSelectionPill.cornerRadius / QuietRailMetrics.sessionRowHeight,
            0.375,
            "the selected session's pill turned into a lozenge"
        )
        XCTAssertGreaterThan(QuietSelectionPill.horizontalInset, 0)
        XCTAssertLessThan(
            QuietSelectionPill.horizontalInset,
            QuietRowBudget.projectIndent,
            "the pill must stay inside the row's own leading inset"
        )
        // A session's pill starts just before its identity mark rather than at
        // the column edge, so it cannot paint colour under nothing.
        XCTAssertGreaterThan(QuietRailMetrics.pillMarkLead, 0)
        XCTAssertLessThan(QuietRailMetrics.pillMarkLead, QuietRailMetrics.sessionIndent)
    }

    /// The Files rail selects with the sidebar's own pill — one grammar on
    /// both edges of the window (2026-08-26 panel review against Safari and
    /// the Landmarks Liquid Glass sample). This pins the borrowing itself:
    /// the rail may never redeclare its own radius or coverage, only forward
    /// the sidebar's, so the two rails cannot drift apart again.
    func testTheFilesRailSelectsWithTheSidebarsOwnPill() {
        XCTAssertEqual(
            WorkspaceRailRowGrammar.selectionCornerRadius,
            QuietSelectionPill.cornerRadius,
            "the rails select in two dialects again"
        )
        XCTAssertEqual(
            WorkspaceRailRowGrammar.selectionFillOpacity(dark: false),
            QuietSelectionPill.fillOpacity(dark: false)
        )
        XCTAssertEqual(
            WorkspaceRailRowGrammar.selectionFillOpacity(dark: true),
            QuietSelectionPill.fillOpacity(dark: true)
        )
        // Roomier than the old 2.5pt cram, but the rail's rows stay a step
        // tighter than the sidebar's 26pt session lane.
        XCTAssertGreaterThan(WorkspaceRailRowGrammar.rowVerticalPadding, 3)
        let approximateRowHeight = WorkspaceRailRowGrammar.rowVerticalPadding * 2 + 16
        XCTAssertLessThan(approximateRowHeight, QuietRailMetrics.sessionRowHeight + 0.5)
        // The documented lozenge bound holds on the rail's own rows too.
        XCTAssertLessThan(
            WorkspaceRailRowGrammar.selectionCornerRadius / approximateRowHeight,
            0.375,
            "the selected file's pill turned into a lozenge"
        )
    }

    // MARK: - Project drag mapping

    /// v1.1.8 deleted the pinned-on-top rail, and with it the pinned OFFSET the
    /// old mapping carried: the dragged list is now the persisted list, so the
    /// only translation left is SwiftUI's own before-the-move `toOffset` into
    /// the after-the-removal index `NativeSessionStore.moveProject` inserts at.
    ///
    /// The whole point of the simplification is that the active project no
    /// longer participates in the arithmetic at all, so these cases no longer
    /// mention it — which is exactly why the reorder can no longer depend on
    /// which project happens to be active.
    func testDragToTopLandsAtIndexZero() {
        XCTAssertEqual(
            QuietRailOrder.moveIndex(orderedIDs: ["A", "B", "C", "D"], from: 3, to: 0),
            QuietRailOrder.Move(id: "D", toIndex: 0)
        )
    }

    /// SwiftUI measures `toOffset` before the row leaves, so a downward drag
    /// lands one index lower once it does. Getting this backwards is the classic
    /// off-by-one, and it shows up as a row that refuses to move past its
    /// neighbour.
    func testDraggingDownAccountsForTheRowLeavingItsOwnSlot() {
        XCTAssertEqual(
            QuietRailOrder.moveIndex(orderedIDs: ["A", "B", "C", "D"], from: 0, to: 2),
            QuietRailOrder.Move(id: "A", toIndex: 1)
        )
        XCTAssertEqual(
            QuietRailOrder.moveIndex(orderedIDs: ["A", "B", "C", "D"], from: 0, to: 4),
            QuietRailOrder.Move(id: "A", toIndex: 3)
        )
    }

    func testDraggingUpUsesTheOffsetAsGiven() {
        XCTAssertEqual(
            QuietRailOrder.moveIndex(orderedIDs: ["A", "B", "C", "D"], from: 3, to: 1),
            QuietRailOrder.Move(id: "D", toIndex: 1)
        )
    }

    func testNoOpDragsAreIgnored() {
        XCTAssertNil(QuietRailOrder.moveIndex(orderedIDs: ["A", "B", "C"], from: 0, to: 0))
        XCTAssertNil(QuietRailOrder.moveIndex(orderedIDs: ["A", "B", "C"], from: 0, to: 1))
        XCTAssertNil(QuietRailOrder.moveIndex(orderedIDs: ["A", "B", "C"], from: 2, to: 3))
    }

    func testOutOfRangeDragsAreIgnored() {
        XCTAssertNil(QuietRailOrder.moveIndex(orderedIDs: ["A", "B"], from: 4, to: 0))
        XCTAssertNil(QuietRailOrder.moveIndex(orderedIDs: ["A", "B"], from: -1, to: 0))
        XCTAssertNil(QuietRailOrder.moveIndex(orderedIDs: [], from: 0, to: 0))
    }

    /// The mapping is only correct if the store's remove-then-insert reproduces
    /// the order the user dragged. Run every drag in a four-project rail through
    /// both, and require them to agree — which is the property, rather than a
    /// handful of cases that happen to be right.
    func testMappedIndexReproducesTheDraggedOrderForEveryDrag() {
        let ordered = ["A", "B", "C", "D"]
        for from in ordered.indices {
            for to in 0...ordered.count {
                // What SwiftUI's own list would show after the drop.
                var dragged = ordered
                dragged.move(fromOffsets: IndexSet(integer: from), toOffset: to)

                guard let move = QuietRailOrder.moveIndex(orderedIDs: ordered, from: from, to: to) else {
                    XCTAssertEqual(dragged, ordered, "a no-op mapping for a drag that moved something")
                    continue
                }
                // What the store does with the mapped index.
                var stored = ordered
                let index = stored.firstIndex(of: move.id)!
                let clamped = max(0, min(move.toIndex, stored.count - 1))
                stored.insert(stored.remove(at: index), at: clamped)

                XCTAssertEqual(stored, dragged, "drag \(from) → \(to) disagreed with the store")
            }
        }
    }

    /// The regression this release is FOR: activating a project must not move
    /// it. The rail renders `model.projects` in order and decides the tinted
    /// capsule per row, so the order the user sees cannot be a function of which
    /// project is active — there is no longer any code path by which it could
    /// be. `QuietRailOrder` no longer takes an `activeID` at all, and that
    /// signature is the guarantee.
    func testReorderingIsIndependentOfWhichProjectIsActive() {
        let ordered = ["A", "B", "C", "D"]
        // The same drag, and there is exactly one answer for it — not one per
        // possible active project, which is what the pinned rail had.
        let move = QuietRailOrder.moveIndex(orderedIDs: ordered, from: 3, to: 1)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "D", toIndex: 1))
    }
}
