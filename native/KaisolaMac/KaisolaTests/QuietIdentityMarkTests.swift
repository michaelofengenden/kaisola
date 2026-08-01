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
