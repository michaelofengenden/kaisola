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

    /// "Monoline weight matched across marks": the coral rays, the knot's
    /// outline and an SF Symbol at `.regular` all have to land within a few
    /// tenths of a point of each other, or the rail reads as one bold mark and
    /// four thin ones.
    func testDrawnMarksShareOneMonolineStrokeWeight() {
        let unit = QuietIdentityMarkView.slot / 24
        let starburst = unit * QuietIdentityMarkView.starburstStroke
        let knot = QuietOpenAIKnot.strokeWidth(unit: unit)

        // Monoline: a hairline, not a rule.
        XCTAssertGreaterThan(starburst, 0.9)
        XCTAssertLessThan(starburst, 1.8)
        XCTAssertEqual(
            starburst,
            knot,
            accuracy: 0.35,
            "the starburst and the knot no longer read as the same pen"
        )
    }

    // MARK: - OpenAI knot geometry

    /// The mark is six copies of ONE strand at 60°, which is the logo's actual
    /// construction. If that ever stops being true the mark stops being the
    /// logo, so the symmetry is asserted rather than eyeballed.
    func testKnotIsSixStrandsEvenlySpacedOnOneOrbit() {
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let centers = QuietOpenAIKnot.strandCenters(in: rect)
        XCTAssertEqual(centers.count, 6)

        let middle = CGPoint(x: rect.midX, y: rect.midY)
        let radii = centers.map { hypot($0.x - middle.x, $0.y - middle.y) }
        let expected = QuietOpenAIKnot.orbit * QuietOpenAIKnot.unit(in: rect)
        for radius in radii {
            XCTAssertEqual(radius, expected, accuracy: 0.001, "a strand left the orbit")
        }

        // Consecutive strands are exactly 60° apart.
        let angles = centers.map { atan2($0.y - middle.y, $0.x - middle.x) }
        for index in 1 ..< angles.count {
            var delta = angles[index] - angles[index - 1]
            if delta < 0 { delta += 2 * .pi }
            XCTAssertEqual(delta, .pi / 3, accuracy: 0.001)
        }
    }

    /// The two numbers that carry the likeness. `lengthRatio` above ~1.16 is
    /// what makes consecutive strands *cross* instead of merely meeting — that
    /// overlap is the knot; without it the mark is a plain hexagonal ring. The
    /// skew is what gives it chirality, and past roughly 20° the interior fills
    /// in and the mark turns to mud at 16pt.
    func testKnotStrandsOverlapAndLeanOffTangential() {
        let neighbourGapRatio = 2 * tan(Double.pi / 6) // 1.1547
        XCTAssertGreaterThan(
            Double(QuietOpenAIKnot.lengthRatio),
            neighbourGapRatio,
            "strands no longer overlap — the mark is a hexagon, not a knot"
        )
        XCTAssertGreaterThan(QuietOpenAIKnot.skew.degrees, 0, "a skew of 0 draws a symmetric ring")
        XCTAssertLessThan(QuietOpenAIKnot.skew.degrees, 20, "past ~20° the knot fills in at 16pt")

        // Elongated, not round: a stadium at aspect 1 is a circle.
        XCTAssertGreaterThan(QuietOpenAIKnot.aspect, 2)
        // Michael's spec: outline weight ≈ strand width × 0.35, give or take.
        XCTAssertEqual(Double(QuietOpenAIKnot.strokeRatio), 0.45, accuracy: 0.15)
    }

    /// Six-fold symmetry means the union's bounding box is centred on the slot,
    /// and the whole mark has to stay inside its 16pt slot once the outline
    /// weight is added — a mark that overflows its slot collides with the row's
    /// title column.
    func testKnotFitsItsSlotAndStaysCentred() {
        let slot = QuietIdentityMarkView.slot
        let rect = CGRect(x: 0, y: 0, width: slot, height: slot)
        let unit = QuietOpenAIKnot.unit(in: rect)
        let bounds = QuietOpenAIKnot.path(in: rect).boundingRect
            .insetBy(dx: -QuietOpenAIKnot.strokeWidth(unit: unit) / 2,
                     dy: -QuietOpenAIKnot.strokeWidth(unit: unit) / 2)

        XCTAssertEqual(bounds.midX, rect.midX, accuracy: 0.01, "the knot is off-centre horizontally")
        XCTAssertEqual(bounds.midY, rect.midY, accuracy: 0.01, "the knot is off-centre vertically")
        XCTAssertTrue(rect.contains(bounds), "the knot overflows its \(slot)pt slot: \(bounds)")

        // …but it still fills the slot: a mark that shrank to nothing would
        // also pass the containment check above.
        XCTAssertGreaterThan(bounds.width / slot, 0.75)
        XCTAssertGreaterThan(bounds.height / slot, 0.75)
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
        // v1.1.7 pushed it to two full identity slots. 22pt still read as a
        // nudge next to a 16pt mark; a session's mark now starts past where
        // its project's mark ENDS, which is what "nested" actually looks like.
        XCTAssertGreaterThanOrEqual(
            QuietRowBudget.indentStep,
            QuietIdentityMarkView.slot * 2,
            "the session indent went shallow again"
        )
        XCTAssertEqual(QuietRowBudget.sessionIndent, 40)
    }

    /// v1.1.7 does the opposite trade to v1.1.6's and has to survive it: the
    /// rail NARROWS by 20 and the indent DEEPENS by 10 in the same pass. Assert
    /// the outcome — that a title at the new resting width still beats the one
    /// the v1.1.4 rail shipped — so neither number can be pushed further
    /// without this failing.
    func testTheNarrowerRailStillOutTitlesTheOldOne() {
        XCTAssertGreaterThan(NativeWorkspaceChrome.projectSidebarIdealWidth, 200)
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
        // The v1.1.4 row: 200pt sidebar, 18pt indent, same tokens.
        let before = 200 - 18 - 10 - QuietIdentityMarkView.slot - 8 - 5 - (timeWidth + 5 + 6)
        XCTAssertGreaterThan(now, before, "the narrower rail gave the title back to the indent")
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

    // MARK: - Row emphasis (no wash)

    /// v1.1.7 deleted the rounded grey wash from surface rows entirely. The
    /// only thing left that says "this is the session on screen" is the title's
    /// own weight, so the two weights have to actually differ — a table where
    /// selected and resting collapsed to the same value would render the rail
    /// with no selection signal at all.
    func testTheVisibleSessionIsSignalledByWeightAlone() {
        XCTAssertNotEqual(QuietRowEmphasis.selectedWeight, QuietRowEmphasis.restingWeight)
        XCTAssertEqual(QuietRowEmphasis.weight(isSelected: true), .semibold)
        XCTAssertEqual(QuietRowEmphasis.weight(isSelected: false), .regular)
    }

    // MARK: - Footer budget

    /// The footer regression: the account chip was framed to a fixed 118pt and
    /// then `fixedSize`d, so "michael ofen…" stayed truncated no matter how far
    /// the sidebar was dragged. The name's width is now a function of the
    /// footer's, and at the default sidebar it must beat that old constant even
    /// with both new controls present.
    func testAccountNameGetsMoreThanTheOldFixedChipAtTheDefaultWidth() {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        // The chip is text only, so its width is the percentage's own.
        let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let chip = ("62%" as NSString).size(withAttributes: [.font: chipFont]).width + 4

        let width = FooterAccountBudget.nameWidth(
            footerWidth: NativeWorkspaceChrome.projectSidebarIdealWidth,
            usageChipWidth: chip,
            attentionWidth: 0
        )
        // The old chip framed avatar + name into 118pt total.
        XCTAssertGreaterThan(width, 118 - FooterAccountBudget.avatarSlot)

        // The name from the bug report is 117.3pt at this font. It fit whole at
        // v1.1.6's 248pt rail; v1.1.7's 228pt rail is 20pt narrower and the
        // footer is where those 20 points come out, so at the *resting* width a
        // long name now takes an ellipsis again. That is a real cost of item 1
        // and it is written down rather than asserted away: what the footer
        // still guarantees is that widening the rail *at all* recovers it, and
        // that the name never falls back to the fixed 118pt chip it was pinned
        // to before v1.1.6.
        let rendered = ("michael ofengenden" as NSString).size(withAttributes: [.font: font]).width
        let whole = FooterAccountBudget.nameWidth(footerWidth: 248, usageChipWidth: chip, attentionWidth: 0)
        XCTAssertGreaterThan(whole, rendered, "the whole name no longer fits at any reachable width")
        XCTAssertLessThanOrEqual(
            248,
            NativeWorkspaceChrome.projectSidebarMaximumWidth,
            "the width that shows the whole name is no longer reachable by dragging"
        )

        // The margin at the default width is thin by construction, so widening
        // the sidebar has to open it up properly rather than merely a little.
        let roomy = FooterAccountBudget.nameWidth(footerWidth: 300, usageChipWidth: chip, attentionWidth: 0)
        XCTAssertGreaterThan(roomy - rendered, 40, "widening the sidebar barely helps the name")
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

    // MARK: - Active project glass

    /// The whole risk of a tinted row is drift toward candy. These are the
    /// ceilings the mock approved; the relationships between them are what keep
    /// it reading as glass.
    func testActiveProjectGlassStaysRestrained() {
        XCTAssertGreaterThan(QuietActiveGlass.topFillOpacity, QuietActiveGlass.bottomFillOpacity,
                             "a flat fill is a coloured chip, not glass")
        XCTAssertLessThan(QuietActiveGlass.topFillOpacity, 0.25, "the tint is a wash, not a fill")
        XCTAssertGreaterThan(QuietActiveGlass.strokeOpacity, QuietActiveGlass.topFillOpacity,
                             "the edge must read against the fill")
        XCTAssertLessThan(QuietActiveGlass.strokeOpacity, 0.4, "that is an outline, not a hairline")

        // The lit top edge: bright in light mode, barely there in dark, where
        // white at light-mode strength reads as a seam.
        XCTAssertGreaterThan(
            QuietActiveGlass.highlightOpacity(dark: false),
            QuietActiveGlass.highlightOpacity(dark: true)
        )
        XCTAssertLessThan(QuietActiveGlass.highlightOpacity(dark: true), 0.2)
        XCTAssertLessThan(QuietActiveGlass.highlightOpacity(dark: false), 0.5)

        // It is a *top* highlight: it has to be gone before the row's bottom
        // edge, or it is a second fill.
        XCTAssertLessThanOrEqual(QuietActiveGlass.highlightFalloff, 0.6)
        XCTAssertGreaterThan(QuietActiveGlass.highlightFalloff, 0)
    }

    // MARK: - Compact-list drag mapping

    func testDragToTopOfTheCompactListLandsBelowThePinnedProject() {
        // Rail shows: A (pinned, store index 0) then B, C, D. Dragging D to the
        // top of the compact list must leave the compact order D, B, C without
        // displacing A from the slot it holds in the persisted order.
        let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B", "C", "D"], from: 2, to: 0)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "D", toIndex: 1))
    }

    func testDragToTopTakesSlotZeroWhenThePinnedProjectIsNotThere() {
        // Store order B, A, C, D with A active: the first compact slot *is*
        // store index 0, so a compact-top drop lands there.
        let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["B", "A", "C", "D"], from: 2, to: 0)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "D", toIndex: 0))
    }

    /// The mapping is only correct if the store's remove-then-insert really
    /// reproduces the dragged compact order *and* leaves the pinned project put.
    func testDragToTopKeepsThePinnedProjectAtItsStoredIndex() {
        let ordered = ["A", "B", "C", "D"]
        guard let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ordered, from: 2, to: 0) else {
            return XCTFail("expected a move")
        }
        var stored = ordered
        let from = stored.firstIndex(of: move.id)!
        let clamped = max(0, min(move.toIndex, stored.count - 1))
        stored.insert(stored.remove(at: from), at: clamped)
        XCTAssertEqual(stored, ["A", "D", "B", "C"])
        XCTAssertEqual(stored.firstIndex(of: "A"), 0)
        XCTAssertEqual(stored.filter { $0 != "A" }, ["D", "B", "C"])
    }

    func testDragMapsThroughAnActiveProjectHeldInTheMiddleOfTheStoreOrder() {
        // Store order B, A, C, D with A active: the compact list is B, C, D.
        // Dragging B to the end must land B last in the store order too.
        let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["B", "A", "C", "D"], from: 0, to: 3)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "B", toIndex: 3))
    }

    func testDragOneStepDownSkipsThePinnedProject() {
        // Compact list B, C, D; move B below C.
        let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B", "C", "D"], from: 0, to: 2)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "B", toIndex: 2))
    }

    func testNoOpDragsAreIgnored() {
        XCTAssertNil(QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B", "C"], from: 0, to: 0))
        XCTAssertNil(QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B", "C"], from: 0, to: 1))
    }

    func testOutOfRangeDragsAreIgnored() {
        XCTAssertNil(QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ["A", "B"], from: 4, to: 0))
        XCTAssertNil(QuietRailOrder.moveIndex(activeID: "A", orderedIDs: [], from: 0, to: 0))
    }

    func testWithoutAnActiveProjectTheCompactListIsTheStoreOrder() {
        let move = QuietRailOrder.moveIndex(activeID: nil, orderedIDs: ["A", "B", "C"], from: 2, to: 0)
        XCTAssertEqual(move, QuietRailOrder.Move(id: "C", toIndex: 0))
    }

    /// The rail's mapping must agree with `NativeSessionStore.moveProject`'s
    /// remove-then-insert, so the resulting compact list is what was dragged.
    func testMappedIndexReproducesTheDraggedCompactOrder() {
        let ordered = ["B", "A", "C", "D"]
        guard let move = QuietRailOrder.moveIndex(activeID: "A", orderedIDs: ordered, from: 0, to: 3) else {
            return XCTFail("expected a move")
        }
        var stored = ordered
        let from = stored.firstIndex(of: move.id)!
        let clamped = max(0, min(move.toIndex, stored.count - 1))
        stored.insert(stored.remove(at: from), at: clamped)
        XCTAssertEqual(stored.filter { $0 != "A" }, ["C", "D", "B"])
    }
}
