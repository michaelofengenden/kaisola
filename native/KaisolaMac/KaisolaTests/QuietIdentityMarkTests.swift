import SwiftUI
import XCTest
@testable import Kaisola

/// The rail's three pure derivations: who a row belongs to (`QuietIdentity`),
/// what a row is called when its title carries no information
/// (`QuietRailTitle`), and where a compact-list drag lands in the persisted
/// project order once the active project is pinned out of that list
/// (`QuietRailOrder`).
final class QuietIdentityMarkTests: XCTestCase {

    // MARK: - Identity mapping

    func testClaudeAgentsMapToTheStarburst() {
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

        // …and the DRAWN marks land on the same optical circle. The starburst
        // spans 2 × outerRadius in the 24-unit viewbox.
        let starburstDiameter = 2 * 9.6 * (slot / 24)
        XCTAssertEqual(
            starburstDiameter,
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
    /// The knot is filled now, so a stroke width cannot express this; ink can.
    /// Measured by rendering each mark into the 16pt slot at 8× and summing
    /// alpha: `terminal` 0.208, `arrow.up.arrow.down` 0.162, the coral starburst
    /// 0.314, and the filled knot 0.376 at full span — which is why the knot is
    /// inset to `span` (0.308 there, level with the starburst).
    func testTheTwoAgentMarksAreInkedAlikeAndTheKnotIsInsetToGetThere() {
        let starburstStroke = (QuietIdentityMarkView.slot / 24) * QuietIdentityMarkView.starburstStroke
        // Monoline: a hairline, not a rule.
        XCTAssertGreaterThan(starburstStroke, 0.9)
        XCTAssertLessThan(starburstStroke, 1.8)

        // The knot gives up one and a half points of the slot. Less and it
        // out-inks the burst; much more and it stops reading at rail size.
        XCTAssertEqual(Double(QuietOpenAIKnot.span), 14.5 / 16, accuracy: 0.0001)
        XCTAssertLessThan(QuietOpenAIKnot.span, 1)
        XCTAssertGreaterThan(QuietOpenAIKnot.span, 0.85)
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

    // MARK: - Row width budget

    /// The regression this covers: at the default sidebar width a session title
    /// must read as a title, not as an abbreviation. v1.1.4 left it 56pt —
    /// "Audit K…" — because the row's fixed tokens were charged against it and
    /// its trailing lane could still be compressed below its own first glyph.
    func testSessionTitleGetsMostOfTheRowAtTheDefaultSidebarWidth() {
        let titleFont = NSFont.systemFont(ofSize: 13)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let timeWidth = ("now" as NSString).size(withAttributes: [.font: timeFont]).width

        let available = QuietRowBudget.titleWidth(
            sidebarWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            timeLabelWidth: timeWidth,
            showsReveal: false
        )
        XCTAssertGreaterThan(available, 100, "the title lane lost its share of the row again")

        // Stated the way the complaint was: how much of a real title is legible.
        let sample = "Audit Kaisola Sidebar parity"
        var visible = 0
        for count in 1...sample.count {
            let candidate = String(sample.prefix(count)) + "…"
            let width = (candidate as NSString).size(withAttributes: [.font: titleFont]).width
            if width <= available { visible = count } else { break }
        }
        XCTAssertGreaterThanOrEqual(
            visible,
            15,
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
            80
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
        XCTAssertGreaterThan(
            QuietRowBudget.indentStep,
            QuietIdentityMarkView.slot * 1.5,
            "the session indent went shallow again"
        )
        XCTAssertEqual(QuietRowBudget.sessionIndent, 36)
        XCTAssertEqual(QuietRowBudget.indentStep, 28)
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

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let timeWidth = ("now" as NSString).size(withAttributes: [.font: timeFont]).width

        let now = QuietRowBudget.titleWidth(
            sidebarWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            timeLabelWidth: timeWidth,
            showsReveal: false
        )
        // The measured v1.1.4 lane, from the bug report this budget was built
        // for. Not derived — recorded.
        let shippedInV114: CGFloat = 56
        XCTAssertGreaterThan(
            now,
            shippedInV114 * 1.75,
            "the narrower rail handed the title back to the indent"
        )

        // …and the narrowing really is a narrowing: the rail is now under every
        // resting width it has had since v1.1.5, which is what makes the two
        // trades this release pays for (the 4pt of indent above, and the
        // footer's compact first-name label below) real rather than decorative.
        XCTAssertLessThan(NativeWorkspaceChrome.projectSidebarIdealWidth, 228)
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
        XCTAssertLessThan(
            QuietRowBudget.headerPlusReserved,
            NativeWorkspaceChrome.projectSidebarIdealWidth * 0.2
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
        XCTAssertEqual(QuietProjectEmphasis.weight(isActive: true), .bold)
        XCTAssertEqual(QuietProjectEmphasis.weight(isActive: false), .regular)
        // Bolder than the selected *session*: a heading outranks a row, and the
        // two signals have to stay legible in the same column.
        XCTAssertNotEqual(QuietProjectEmphasis.activeWeight, QuietRowEmphasis.selectedWeight)
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
            usageChipWidth: usageChipWidth,
            attentionWidth: 0
        )
        // The old chip framed avatar + name into 118pt total.
        XCTAssertGreaterThan(width, 118 - FooterAccountBudget.avatarSlot)

        // v1.1.8 intentionally uses the first name at every width. The 210pt
        // rail must give that stable label ample room even with usage visible;
        // the whole display name remains in help text and the account menu.
        let full = "michael ofengenden"
        let displayed = FooterAccountName.displayed(full)
        XCTAssertEqual(displayed, "michael")
        XCTAssertGreaterThanOrEqual(
            width, footerNameRenders(displayed),
            "the first-name label takes an ellipsis at the default width"
        )
        XCTAssertGreaterThan(width - footerNameRenders(displayed), 50)

        // The ladder still has to have been climbed. These are the three rungs;
        // pinned so a later pass cannot restore the points it took and leave the
        // rail narrow anyway.
        XCTAssertEqual(FooterAccountBudget.leadingPadding, 6)
        XCTAssertEqual(FooterAccountBudget.avatarSize, 18)
        XCTAssertEqual(FooterAccountBudget.usageChipHorizontalPadding, 1)
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
    /// (its `attentionWidth` stands for the badge's own footprint) still has
    /// to recover at least the same 18pt the quiet case does, compared against
    /// what the pre-fix arithmetic gave the name in that same busy state.
    func testTheRecoveryHoldsWithTheAttentionBellShowingToo() {
        let chip = usageChipWidth
        let bellWidth: CGFloat = 30

        let width = FooterAccountBudget.nameWidth(
            footerWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            usageChipWidth: chip,
            attentionWidth: bellWidth
        )

        // Pre-fix arithmetic (controlSlot 22, gap 5) for this same busy state,
        // written out rather than re-derived so the comparison can't drift
        // with the constants under test.
        let brokenWidthWithBell: CGFloat = NativeWorkspaceChrome.projectSidebarIdealWidth
            - FooterAccountBudget.horizontalPadding
            - FooterAccountBudget.avatarSlot
            - (22 * 2 + 5 * 2 + (chip + 5) + (bellWidth + 5))

        XCTAssertGreaterThanOrEqual(
            width - brokenWidthWithBell, 18,
            "the recovery must hold even when the attention bell is also charged for"
        )
    }

    /// …and it really is a function of the footer: widening the sidebar has to
    /// move the number, which is precisely what the fixed frame prevented.
    func testAccountNameWidthGrowsWithTheSidebar() {
        func width(_ sidebar: CGFloat) -> CGFloat {
            FooterAccountBudget.nameWidth(footerWidth: sidebar, usageChipWidth: 34, attentionWidth: 0)
        }
        let ideal = NativeWorkspaceChrome.projectSidebarIdealWidth
        XCTAssertGreaterThan(width(NativeWorkspaceChrome.projectSidebarMaximumWidth), width(ideal))
        XCTAssertGreaterThan(width(ideal), width(NativeWorkspaceChrome.projectSidebarMinimumWidth))
    }

    /// Every optional control is charged for, so the arithmetic degrades the
    /// way the layout does rather than only describing the quiet case.
    func testOptionalFooterControlsAreChargedAgainstTheName() {
        let ideal = NativeWorkspaceChrome.projectSidebarIdealWidth
        let quiet = FooterAccountBudget.nameWidth(footerWidth: ideal, usageChipWidth: 0, attentionWidth: 0)
        let withChip = FooterAccountBudget.nameWidth(footerWidth: ideal, usageChipWidth: 34, attentionWidth: 0)
        let withBoth = FooterAccountBudget.nameWidth(footerWidth: ideal, usageChipWidth: 34, attentionWidth: 30)
        XCTAssertEqual(quiet - withChip, 34 + FooterAccountBudget.gap, accuracy: 0.001)
        XCTAssertEqual(withChip - withBoth, 30 + FooterAccountBudget.gap, accuracy: 0.001)
    }

    // MARK: - Selected row pill

    /// The tinted glass capsule is deleted, not relocated: the pill under the
    /// selected surface row is NEUTRAL, and the only colour in the row is the
    /// label, in the user's own accent. A tinted pill under tinted text is the
    /// coloured chip v1.1.7 was right to remove.
    func testTheSelectionPillStaysANeutralWhisper() {
        XCTAssertGreaterThan(QuietSelectionPill.lightFillOpacity, 0)
        XCTAssertLessThan(
            QuietSelectionPill.lightFillOpacity, 0.12,
            "a pill this strong is a chip, and it will out-shout the label sitting on it"
        )
        // Dark mode swallows the same recipe, so it gets more — but still less
        // than a chip's worth.
        XCTAssertGreaterThan(
            QuietSelectionPill.fillOpacity(dark: true),
            QuietSelectionPill.fillOpacity(dark: false)
        )
        XCTAssertLessThan(QuietSelectionPill.fillOpacity(dark: true), 0.16)

        // Same corner as every other rounded surface in the window, and inset
        // from the column edge rather than reaching it.
        XCTAssertEqual(QuietSelectionPill.cornerRadius, KaisolaVisualSystem.insetRadius)
        XCTAssertGreaterThan(QuietSelectionPill.horizontalInset, 0)
        XCTAssertLessThan(
            QuietSelectionPill.horizontalInset,
            QuietRowBudget.projectIndent,
            "the pill must stay inside the row's own leading inset"
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
