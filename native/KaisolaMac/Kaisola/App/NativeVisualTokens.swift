import AppKit
import SwiftUI

/// Shared native visual grammar. Glass belongs to navigation and controls;
/// terminals, transcripts, and documents intentionally remain opaque.
enum KaisolaVisualSystem {
    /// The corner ladder, from the smallest control to the window itself.
    ///
    /// v1.1.8 bumps every rung one step (shell 16 → 20, chrome 15 → 18, and
    /// each nested radius proportionally). The numbers are only half the
    /// contract: what keeps the chrome coherent is that they stay *strictly
    /// increasing* outward, so a shape nested inside another is always the
    /// rounder one's junior. `testCornerLadderIsStrictlyIncreasingOutward`
    /// holds that, and it is the check a future "make it rounder" pass has to
    /// keep green rather than a list of literals to edit past.
    static let controlRadius: CGFloat = 8
    /// A session pane card, which sits *inside* the detail chrome panel. Was a
    /// bare `8` written inline in `RootShellView.unifiedSessionCard`; naming it
    /// is what puts it on the ladder at all.
    static let paneRadius: CGFloat = 10
    static let insetRadius: CGFloat = 12
    static let cardRadius: CGFloat = 14
    /// The document-preview and Files panels, which are nested one level inside
    /// the detail chrome panel and so stay a step under `chromeRadius`.
    static let panelRadius: CGFloat = 16
    static let shellRadius: CGFloat = 20
    /// Safari's inset floating-card chrome: the radius of the sidebar and
    /// detail panels that float over the window backdrop. Larger than
    /// `cardRadius` (which belongs to session cards *inside* a panel) and
    /// smaller than `shellRadius` (the window itself).
    static let chromeRadius: CGFloat = 18
    /// The gutter of window backdrop left visible around each chrome panel.
    static let chromeInset: CGFloat = 6
    static let hairline: CGFloat = 0.5
    static let focusStroke: CGFloat = 1
    // The three `rowIcon*` constants that used to sit here described the tiled
    // sidebar row glyph, and the v1.1.7 "every mark is naked" pass deleted the
    // tile without deleting them. `QuietIdentityMarkView` owns that geometry now
    // and documents its own optical sizes.
    static let hoverDuration = 0.09
    static let stateDuration = 0.14
    static let layoutDuration = 0.22
}

/// The light-appearance recipe shared by the two navigation rails, the
/// workspace canvas, and the inset detail panel.
///
/// The Safari reference is a white pane with the desktop present as softened
/// colour and movement, not a desktop-coloured pane with a little white haze.
/// Those are different materials. The old light bake normalized its underlay
/// to 0.72, then let 55–60% of that underlay through; before AppKit added its
/// own material the two large surfaces therefore landed at only 0.846 and
/// 0.832 luminance. That is grey by construction.
///
/// Whiteness is bought with one explicit, achromatic carrier between the
/// desktop and `GlassBackdropWash`. The previous light recipe preserved the
/// sampled desktop's RGB ratios, so a blue wallpaper was guaranteed to make a
/// blue pane even though every declared veil constant was white. The carrier
/// keeps blurred light and movement while making colour a property of the
/// explicit Tinted theme, not of light Glass.
enum LightGlassFrost {
    /// Neutral luminance of a painted wallpaper before the white veil.
    static let backdropLuminance: Double = 0.80

    /// White laid over the live or painted desktop before the surface veil.
    /// With the existing rail/canvas veils this leaves roughly 16-18% of the
    /// underlying luminance variation visible and lands both surfaces near
    /// sRGB 247 rather than grey. It is deliberately achromatic.
    static let carrierWhiteCoverage: Double = 0.70

    /// White over the already-frosted workspace canvas. Light deliberately
    /// gets no second semantic material: that layer re-greyed the canvas and
    /// attenuated the desktop twice. Forty percent keeps the inset plane bright
    /// while still passing sixty percent of the neutral glass below it.
    static let panelWhiteCoverage: Double = 0.40
    static var panelDesktopTransmission: Double { 1 - panelWhiteCoverage }

    /// The deterministic painted-source composite used by the visual tests.
    /// Live vibrancy has no stable pixels to measure offline, but it consumes
    /// the same achromatic carrier and wash.
    static func modeledBackdropLuminance(_ wash: GlassBackdropWash) -> Double {
        let carried = carrierWhiteCoverage
            + (1 - carrierWhiteCoverage) * backdropLuminance
        return wash.baseOpacity + wash.desktopTransmission * carried
    }
}

/// Kaisola's own text inks, and the one place a label's weight is decided.
///
/// **Why the app does not use `secondaryLabelColor`.** In Aqua that colour is
/// black at α 0.498 — measured from AppKit, not assumed — and black at α 0.498
/// over *pure white*, the brightest background that can exist, is **3.98:1**.
/// No light Mac app clears the 4.5 floor with it. On light glass, whose worst
/// patch renders as a 0.75 grey rather than white, the same ink measures
/// **3.43:1**, and `GlassBackdropWash.sidebar` records at length why no veil can
/// fix that: a light surface's worst patch is its *darkest* 2%, so thinning the
/// veil and thickening it move the number by hundredths in opposite directions.
///
/// What moves it is the ink. Measured on that same worst patch — the deeper
/// workspace surface under the widest wallpaper the fixtures carry:
///
///     α 0.498 (AppKit)   3.43:1
///     α 0.600 (Kaisola)  4.65:1
///
/// **The ladder.** Four rungs, stated as ink coverage, resolved per appearance
/// at draw time. Alpha is not the contract — contrast is — so each rung is
/// chosen against the worst patch of the surface it has to survive. Measured,
/// with the glass columns on the adversarial fixture and solid on white:
///
///                    light glass   light solid   dark glass
///     primary            9.2:1        15.1:1        9.0:1
///     secondary          4.7:1         4.8:1        4.8:1
///     tertiary           3.3:1         3.2:1        3.3:1
///     disabled           2.1:1         2.1:1        2.4:1
///
/// Over all six wallpaper fixtures, both surfaces and both clarities that do not
/// declare a trade, the tightest secondary is **4.65:1** in light and **4.57:1**
/// in dark, and the tightest tertiary is 3.18:1.
///
/// Secondary clears 4.5 (WCAG 1.4.3) everywhere. Tertiary clears 3.0 (1.4.11),
/// the floor an **icon-only control** is held to — the reason tertiary moves at
/// all, since AppKit's α 0.26 measures 1.79:1 on light glass and a glyph that is
/// the only affordance in a control cannot sit there. Disabled is the one rung
/// allowed under the floors, because 1.4.3 exempts inactive controls, and it is
/// deliberately *heavier* than AppKit's α 0.098, which on glass is 1.2:1 —
/// invisible rather than inactive.
///
/// The one place the floor is not met is **Clear** clarity, the app's only
/// declared contrast trade (`GlassClarity.veilScale`): a surface that is 92%
/// desktop cannot promise 4.5:1 at any ink. The ink still takes that case from
/// 3.08:1 to 3.99:1, and Clear already falls back to Balanced for anyone who has
/// asked the system for contrast.
///
/// **Three surfaces, because they are three different backgrounds.** Light glass
/// is the hard one and sets α 0.60. Light solid is white — `windowBackgroundColor`,
/// `controlBackgroundColor` and `textBackgroundColor` all resolve to #FFFFFF in
/// Aqua — where α 0.535 already reaches exactly 4.5, so it takes 0.55 and keeps
/// documents and terminals from reading heavier than they are. Dark keeps
/// AppKit's α 0.55 at secondary, so dark appearance changes at tertiary and
/// below only.
enum KaisolaInk {
    /// What the ink will land on. Glass is any surface with the desktop under
    /// it; solid is an opaque one — documents, terminals, transcripts, and
    /// every surface under Reduce Transparency.
    enum Surface: String, CaseIterable, Sendable {
        case glass
        case solid
    }

    /// The rungs, in order. `allCases` is the ladder, and
    /// `testTheInkLadderKeepsItsHierarchy` walks it.
    enum Level: String, CaseIterable, Sendable {
        case primary
        case secondary
        case tertiary
        case disabled
    }

    /// Ink coverage for a rung on a surface.
    ///
    /// Primary is AppKit's `labelColor` alpha unchanged, on purpose: it already
    /// clears 7:1 on the worst light patch with room to spare, and a token that
    /// moved it would restyle every title in the app for nothing.
    static func alpha(_ level: Level, isDark: Bool, on surface: Surface = .glass) -> Double {
        switch level {
        case .primary:
            0.85
        case .secondary:
            isDark ? 0.55 : (surface == .glass ? 0.60 : 0.55)
        case .tertiary:
            isDark ? 0.40 : (surface == .glass ? 0.48 : 0.44)
        case .disabled:
            isDark ? 0.28 : (surface == .glass ? 0.32 : 0.30)
        }
    }

    /// Placeholder text is text. WCAG 1.4.3 gives it no exemption — a hint the
    /// user has to read to know what the field wants is content — so it takes
    /// the secondary ink rather than a lighter rung of its own. AppKit's
    /// `placeholderTextColor` is α 0.25, which is 1.8:1 on white.
    static func placeholderAlpha(isDark: Bool, on surface: Surface = .glass) -> Double {
        alpha(.secondary, isDark: isDark, on: surface)
    }

    /// The rung as an appearance-adaptive `NSColor`: black in Aqua, white in
    /// Dark Aqua, resolved by the drawing appearance rather than by whatever
    /// the colour was created under. Text-view attributes and other AppKit
    /// call sites take this one.
    static func nsColor(_ level: Level, on surface: Surface = .glass) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let ink: CGFloat = isDark ? 1 : 0
            return NSColor(
                srgbRed: ink, green: ink, blue: ink,
                alpha: CGFloat(alpha(level, isDark: isDark, on: surface))
            )
        }
    }

    static func color(_ level: Level, on surface: Surface = .glass) -> Color {
        Color(nsColor: nsColor(level, on: surface))
    }

    /// The placeholder ink, which is the secondary ink under another name so
    /// the audit can see which call sites are placeholders.
    static func placeholder(on surface: Surface = .glass) -> Color {
        color(.secondary, on: surface)
    }
}

extension ShapeStyle where Self == Color {
    /// Primary label ink. The top rung, and the one the footer's icon-only
    /// controls take: the gear, the bell and the overflow sit level with a
    /// column of session names, and in secondary grey at 12pt they were the
    /// quietest things in the window while being three of the few that are
    /// actually clickable. Icon-only controls are held to 3:1 as a floor, not
    /// as a target.
    static var kaisolaPrimary: Color { KaisolaInk.color(.primary) }

    /// Secondary label ink. The glass value, because one view tree spans both
    /// kinds of surface and glass is the safe superset: α 0.60 on an opaque
    /// white surface is 5.7:1, still unmistakably junior to primary's 15:1.
    /// Surfaces that are opaque *by construction* — the document editors, the
    /// terminal — ask for `.solid` explicitly through `KaisolaInk`.
    static var kaisolaSecondary: Color { KaisolaInk.color(.secondary) }

    /// Tertiary ink: decorative glyphs, dimmed status, and icon-only controls,
    /// which is why it is held to 3:1 rather than left decorative.
    static var kaisolaTertiary: Color { KaisolaInk.color(.tertiary) }

    /// Inactive controls. The only rung under the contrast floors, and the only
    /// one WCAG exempts.
    static var kaisolaDisabled: Color { KaisolaInk.color(.disabled) }

    /// Placeholder and prompt text — the secondary ink, deliberately.
    static var kaisolaPlaceholder: Color { KaisolaInk.placeholder() }
}

/// One last-resort motion boundary for the two native view roots.
///
/// Individual surfaces can still choose a calmer replacement transition (the
/// toast, onboarding, restoration notice, palette, and rail already do), but
/// a new `withAnimation` must never become mandatory motion merely because its
/// author forgot to repeat that check. Applying this policy at `RootShellView`
/// and `SettingsView` strips animation from every descendant transaction while
/// the system Reduce Motion preference is enabled.
enum KaisolaMotionPolicy {
    static func apply(reduceMotion: Bool, to transaction: inout Transaction) {
        guard reduceMotion else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }
}

private struct KaisolaReduceMotionFallbackModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            KaisolaMotionPolicy.apply(reduceMotion: reduceMotion, to: &transaction)
        }
    }
}

/// The neutral veil laid over AppKit vibrancy — or over the sampled desktop
/// tint — for the two large backdrops.
///
/// Methodology: light mode is white-led (white at roughly a third coverage),
/// dark mode is a truly achromatic near-black (`#0D0D0D`). The recipe carries
/// no accent, mesh, or slate stop, so the only chroma that reaches the eye is
/// whatever the desktop itself contributes. The three opacities describe one
/// vertical gradient of the *same* color, so the top-light edge reads as light
/// direction rather than as a tint. Keeping the numbers separate from the
/// material makes the light/dark balance deterministic and gives appearance
/// tests a stable contract.
struct GlassBackdropWash: Equatable, Sendable {
    /// `#0D0D0D`: R = G = B, so the veil contributes no hue of its own at any
    /// coverage.
    ///
    /// It was `#0B0C12` — 11/12/18 — and that is where Michael's "blue-purple
    /// tone" came from. At 0.60 coverage a veil is most of the surface, and
    /// 18/255 against 11/255 is a **64% blue lead over red**; the eye reads
    /// that as a cool cast long before it reads it as black. The old guard
    /// missed it because it was stated in absolute terms (`blue - green ≤
    /// 0.03`), and 0.024 of absolute difference is nothing at mid-grey and
    /// everything at near-black. The invariant is relative now — see
    /// `testDeclaredNeutralConstantsAreAchromatic`.
    static let darkVeil = (red: 13.0 / 255, green: 13.0 / 255, blue: 13.0 / 255)

    let red: Double
    let green: Double
    let blue: Double
    /// Coverage at the top-leading corner (lit edge).
    let topOpacity: Double
    /// Coverage across the body of the backdrop — the headline value.
    let baseOpacity: Double
    /// Coverage at the bottom-trailing corner (settled edge).
    let bottomOpacity: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Every coverage scaled by the same factor, clamped so a setting can never
    /// produce a veil outside the range the constants are declared in. The hue
    /// is untouched — this moves how much veil there is, never what colour it
    /// is, so the neutrality invariant holds at every setting.
    func scaled(by factor: Double) -> GlassBackdropWash {
        func coverage(_ value: Double) -> Double { min(0.95, max(0, value * factor)) }
        return GlassBackdropWash(
            red: red,
            green: green,
            blue: blue,
            topOpacity: coverage(topOpacity),
            baseOpacity: coverage(baseOpacity),
            bottomOpacity: coverage(bottomOpacity)
        )
    }

    /// One neutral gradient. In light mode the top carries *more* white; in
    /// dark mode it carries *less* near-black. Both read as light from above.
    var veil: LinearGradient {
        LinearGradient(
            colors: [
                color.opacity(topOpacity),
                color.opacity(baseOpacity),
                color.opacity(bottomOpacity),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func dark(top: Double, base: Double, bottom: Double) -> GlassBackdropWash {
        GlassBackdropWash(
            red: darkVeil.red,
            green: darkVeil.green,
            blue: darkVeil.blue,
            topOpacity: top,
            baseOpacity: base,
            bottomOpacity: bottom
        )
    }

    private static func light(top: Double, base: Double, bottom: Double) -> GlassBackdropWash {
        GlassBackdropWash(
            red: 1,
            green: 1,
            blue: 1,
            topOpacity: top,
            baseOpacity: base,
            bottomOpacity: bottom
        )
    }

    /// The sidebar is frost, not a window.
    ///
    /// Three eras, and both of the first two overshot. The v1.1 values (light
    /// 0.42/0.32/0.26) sat over *vibrancy*, which is itself near-opaque, so the
    /// column rendered flat #EDEDED and no desktop colour survived. Halving
    /// them to 0.16 fixed that against vibrancy — but by then the layer
    /// underneath had become the painted wallpaper still, which passes 100% of
    /// the desktop instead of vibrancy's sliver. A 0.16 veil over a raw
    /// wallpaper is not glass; it is a blurred photograph with a haze on it,
    /// and that is exactly how it read: measured off the shipped build, the
    /// sidebar's average channel spread was 0.32 and its peak 0.53 — *more*
    /// saturated than the desktop beside the window, because the bake was also
    /// boosting saturation 1.3×.
    ///
    /// The reference is the Safari sidebar: a heavy near-white (light) or
    /// near-black (dark) surface that the wallpaper *tints* rather than fills.
    /// At 0.60 coverage the still contributes 40% — enough that the desktop's
    /// hue is unmistakably present (modelled composite spread 0.11, against
    /// 0.32 before) and its luminance structure is not (modelled top-to-bottom
    /// luminance range 0.019, against 0.218 before). The wallpaper bake now
    /// luminance-normalizes too, so that 40% arrives at a predictable
    /// brightness whatever the desktop is — see `DesktopBackdropRenderer`.
    /// v1.1.10 thins the **dark** veil and widens its gradient; light is
    /// untouched, because light was never the complaint.
    ///
    /// Dark was the least translucent surface in the app — 0.35–0.40
    /// transmission against light's 0.40–0.45 — and it read exactly as that:
    /// "the background in dark mode looks bad… needs to be really glass dark…
    /// glassy/smooth/translucent to the wallpaper". Modelled against the actual
    /// desktop (an Aerial still), the surface's luminance spread p5..p95 was
    /// 0.060 and the veil's own top-to-bottom range 0.0144 — half of light's
    /// 0.0283. Thinner veil, wider gradient: spread 0.072, gradient 0.0165, and
    /// primary/secondary label contrast still 12.8:1 / 6.0:1.
    ///
    /// v1.1.10 took dark one step down, 0.55 → 0.52, and said so was
    /// deliberately small because the flatness was a colour-space bug rather
    /// than a veil. With that fixed and the surface finally showing what its
    /// constants describe, Michael's next note is about the veil and only the
    /// veil: "dark glass mode could look more glassy/translucent if possible!
    /// especially on live and wallpaper (dark mode should be very translucent)".
    ///
    /// **0.52 → 0.34.** Transmission 0.48 → 0.66 — the veil now covers a third
    /// of the surface rather than half, the largest single move this constant
    /// has made. Measured through the real pipeline against Michael's own
    /// desktop (the Lake Tahoe aerial macOS resolves for his rotating category),
    /// dark sidebar at 210×900:
    ///
    ///     composite rgb   0.089/0.107/0.115  →  0.103/0.129/0.139
    ///     mean luminance              0.104  →  0.124
    ///     luminance spread p5..p95    0.086  →  0.095
    ///     off-neutral                 0.143  →  0.165
    ///     primary label contrast     12.7:1  →  12.1:1  (worst patch 10.9:1)
    ///     secondary label contrast    6.0:1  →   5.8:1  (worst patch  5.5:1)
    ///
    /// This is only available because `DesktopBackdropRenderer`
    /// `darkStillSpreadCeiling` bounds the still's dynamic range first. Thinning
    /// the veil this far *without* that cap put the worst patch of the widest
    /// wallpaper measured at **3.9:1** secondary — below the 4.5 floor. With it,
    /// the worst patch over the five extremes of this Mac's aerial library
    /// **improves** to 4.9:1 (from 4.6:1 at the thicker veil), because the cap
    /// removes more of the worst case than the veil it replaces did.
    ///
    /// The floor is what stopped this at 0.34 rather than lower, and the binding
    /// case is not a photograph: a wallpaper that *is* a linear gradient (macOS
    /// ships several) passes the Gaussian untouched, so its whole range reaches
    /// the veil. Against that fixture the worst patch measures 4.6:1 here, 4.4:1
    /// at a 0.26 base — so roughly 0.30 is the real limit and the margin between
    /// there and here is deliberate. Past that point extra transmission also
    /// stops buying *structure*: the cap has to tighten in step, and
    /// `(1 - base) × ceiling` is conserved. It keeps buying chroma, which is
    /// most of what reads as translucency at this luminance.
    ///
    /// **Light, 0.60 → 0.45.** The same request, one round later: "light mode
    /// should also be translucent to wallpaper much better". Transmission
    /// 0.40 → **0.55**. Light had been left alone twice on the argument that a
    /// 0.72 surface has headroom to spare; rendering it says otherwise, and this
    /// is the number that says so. Measured against Michael's own desktop, light
    /// sidebar at 210×900:
    ///
    ///     composite rgb   0.836/0.898/0.924  →  0.774/0.860/0.897
    ///     mean luminance              0.887  →  0.845
    ///     luminance spread p5..p95   0.0805  →  0.0803
    ///     veil gradient top→bottom   0.0385  →  0.0378
    ///     off-neutral                 0.057  →  0.083
    ///     absolute chroma            0.0501  →  0.0696
    ///     primary label contrast     12.3:1  →  11.4:1  (worst patch 9.5:1)
    ///     secondary label contrast    3.8:1  →   3.7:1  (worst patch 3.5:1)
    ///
    /// The wallpaper's colour arrives **39% stronger** and its light and shade
    /// arrive unchanged — the trade the range cap makes is chroma-for-structure
    /// at fixed contrast, and at these constants the structure comes out level.
    ///
    /// Like dark, this is only available because the bake bounds the still's
    /// range first (`DesktopBackdropRenderer.lightStillSpreadCeiling`). Thinning
    /// the light veil to 0.45 *without* the cap puts the worst patch of an
    /// adversarial ramp at **5.9:1 primary** — below the 7.0 floor — and the
    /// worst patch of the five aerial extremes at 3.20:1 secondary against a
    /// 3.43 baseline. With the cap the worst patch **improves** on every
    /// adversarial fixture (primary 7.27 → 8.88, secondary 3.17 → 3.40) and
    /// returns exactly to baseline on the aerials.
    ///
    /// What stopped light at 0.45 is **not** the same constraint that stopped
    /// dark, and it is worth being precise about which floor binds. Light's
    /// primary has room to spare (9.05:1 at the worst patch, against 7.0).
    /// Light's *secondary* cannot reach the stated 4.5 floor at any veil,
    /// because it is not a property of the veil: AppKit's `secondaryLabelColor`
    /// in Aqua is black at **α 0.498** (measured, not assumed), and black at
    /// α 0.498 over *pure white* is **3.98:1**. Every light surface in every
    /// Mac app is under that ceiling. So the honest constraint here is "do not
    /// make it worse", the worst-patch secondary is held at its pre-change 3.43,
    /// and 0.45 is exactly where that binds. Going to 0.40 costs 0.06 of it.
    ///
    /// The mechanism that lifts it is a **custom secondary ink** rather than
    /// the system semantic: on this surface, black at α 0.60 measures
    /// **4.60:1** at the worst patch (4.56:1 adversarial), clearing the floor.
    /// That is `KaisolaInk` now, adopted at the call sites rather than smuggled
    /// in through a glass constant — the veil still may not make text legible
    /// on its own, and the sentence above still binds this number. What changed
    /// is that the app no longer *asks* the veil to.
    static func sidebar(isDark: Bool, clarity: GlassClarity = .balanced) -> GlassBackdropWash {
        sidebarBase(isDark: isDark).scaled(by: clarity.veilScale)
    }

    private static func sidebarBase(isDark: Bool) -> GlassBackdropWash {
        isDark
            ? dark(top: 0.27, base: 0.34, bottom: 0.43)
            : light(top: 0.51, base: 0.45, bottom: 0.41)
    }

    /// How much of the composited backdrop is still the desktop's own colour
    /// rather than the veil — `1 - baseOpacity`, named so the appearance
    /// contract can be stated as "the desktop must survive", which is the
    /// property that actually regressed.
    var desktopTransmission: Double { 1 - baseOpacity }

    /// The workspace sits one step deeper than the sidebar so the inset chrome
    /// panels have something to float above: less white in light mode, more
    /// near-black in dark mode. Dark moves with the sidebar and keeps its three
    /// points of separation (0.55 → 0.37); measured composite 0.102/0.126/0.135,
    /// spread 0.094, primary 12.2:1 (worst 11.0:1), secondary 5.9:1 (worst 5.5:1).
    ///
    /// Light moves with the sidebar too and keeps its five points of separation
    /// (0.55 → 0.40, transmission 0.45 → **0.60**); measured composite
    /// 0.752/0.847/0.888, spread 0.088, chroma 0.0767, primary 11.0:1 (worst
    /// 9.1:1), secondary 3.7:1 (worst 3.4:1). The workspace is the deeper
    /// surface, so it is also the one the worst patch is always found on — every
    /// light figure quoted as a worst case in this file is a workspace figure.
    static func workspace(isDark: Bool, clarity: GlassClarity = .balanced) -> GlassBackdropWash {
        workspaceBase(isDark: isDark).scaled(by: clarity.veilScale)
    }

    private static func workspaceBase(isDark: Bool) -> GlassBackdropWash {
        isDark
            ? dark(top: 0.30, base: 0.37, bottom: 0.46)
            : light(top: 0.46, base: 0.40, bottom: 0.36)
    }

    /// How much of the workspace veil an **idle** canvas keeps.
    ///
    /// Every number above is solved against text that has to survive on the
    /// surface. An idle canvas has none — nothing mounted, nothing to read but
    /// the empty-state card, which carries its own material — so the veil's
    /// only remaining job is to seat the picture faintly into the app's
    /// appearance rather than to guard anything. 0.30 of the veil over the
    /// *clear* still (see `DesktopBackdropRenderer.renderBake`) leaves the
    /// canvas at ≥ 0.85 transmission in balanced clarity and ~0.97 in Clear,
    /// which is the "translucent to the wallpaper" Michael asked for. The
    /// moment anything mounts, the crossfade brings the full wash back and all
    /// of the guarantees with it.
    static let idleVeilFactor = 0.30

    static func workspaceIdle(isDark: Bool, clarity: GlassClarity = .balanced) -> GlassBackdropWash {
        workspaceBase(isDark: isDark).scaled(by: clarity.veilScale * idleVeilFactor)
    }

    /// The band a glass veil's transmission has to live in, per appearance.
    ///
    /// The contract is unchanged and still two-sided: too little transmission
    /// and the surface is the flat #EDEDED panel of v1.1; too much and it is a
    /// blurred photograph with a haze on it. What changed is *where the upper
    /// bound comes from in dark*.
    ///
    /// It used to be 0.50 for both appearances because the veil was the only
    /// thing keeping the desktop's brightness and dynamic range out of the
    /// surface. It no longer is, in either appearance: the bake normalizes the
    /// still's mean **and** caps its p5..p95 range at
    /// `DesktopBackdropRenderer.stillSpreadCeiling(isDark:)`, so "not a
    /// photograph" is now a property of the layer underneath rather than of the
    /// layer over it. A still cannot be brighter, and cannot have more range,
    /// than those two constants allow, whatever the desktop is — which is
    /// exactly the guarantee the 0.50 ceiling was standing in for.
    ///
    /// Both ceilings therefore sit one step above the veil they permit
    /// (dark 0.66 under 0.70, light 0.60 under 0.65) rather than at an
    /// historical number. Light stays the tighter of the two because its own
    /// contrast budget is tighter, not because it is unguarded: see
    /// `sidebar(isDark:)` for the 3.98:1 AppKit ceiling that is the real bound
    /// on the light surface.
    static func desktopTransmissionBand(isDark: Bool) -> (floor: Double, ceiling: Double) {
        isDark ? (floor: 0.30, ceiling: 0.70) : (floor: 0.30, ceiling: 0.65)
    }

    /// How much of a glass surface Increased Contrast must cover, counting the
    /// veil and the overlay together.
    ///
    /// This used to be expressed as a *restoration*: reproduce whatever
    /// coverage the pre-halving veil reached once a flat 0.18 overlay was
    /// stacked on it. That reference is now moot. The frost retune raised every
    /// base past the composite those old numbers produced (the highest was
    /// workspace dark at 0.59, below today's 0.65 base alone), so the
    /// restoration formula solved to a negative overlay on all four surfaces
    /// and collapsed onto its own 0.18 floor — an accessibility setting whose
    /// arithmetic had quietly stopped doing anything.
    ///
    /// Stating it as an absolute floor is both simpler and the thing that
    /// actually matters to a low-vision user: with Increased Contrast on, at
    /// most 20% of what reaches the eye is wallpaper. That is a property of the
    /// rendered surface, not of any previous release, so it cannot rot the next
    /// time the veil moves.
    static let increasedContrastCoverage = 0.80

    /// Two translucent layers stacked with standard "over" compositing cover
    /// `base + overlay * (1 - base)` in total — the overlay only paints the
    /// sliver the veil left uncovered. Solving for the overlay that lifts a
    /// given base to `increasedContrastCoverage`:
    ///
    ///     overlay = (coverage - base) / (1 - base)
    ///
    /// The overlay may not paint a glass surface into an opaque panel — that is
    /// what `SidebarAppearance.solid` and Reduce Transparency are for, and an
    /// overlay that reached 1 would make Increased Contrast silently a third
    /// opacity setting.
    ///
    /// It was 0.6, and 0.6 is exactly the overlay a 0.50 base needs to reach the
    /// 0.80 floor — so the moment the dark veil went below 0.50 the clamp would
    /// have started binding and the accessibility guarantee would have been met
    /// by a `min` rather than by arithmetic (0.34 + 0.6·0.66 = 0.74, not 0.80).
    /// Raised to 0.80, which leaves the exact solutions for today's four bases
    /// (0.45/0.40 light, 0.34/0.37 dark → 0.636/0.667/0.697/0.683) strictly
    /// inside it, and still keeps a fifth of the surface translucent at the
    /// extreme. The light veil's own retune moved its two solutions from
    /// 0.500/0.556 to those figures without touching this constant, which is the
    /// whole point of deriving them.
    static let increasedContrastOverlayCeiling = 0.80

    /// `base` is read live from `sidebar(isDark:)` / `workspace(isDark:)` so a
    /// future veil retune re-derives this instead of falling behind. Clamped to
    /// `[0, increasedContrastOverlayCeiling]`: a base that already meets the
    /// floor needs no overlay.
    private static func increasedContrastOverlay(base: Double) -> Double {
        guard base < 1 else { return 0 }
        return min(
            increasedContrastOverlayCeiling,
            max(0, (increasedContrastCoverage - base) / (1 - base))
        )
    }

    /// Increased Contrast overlay opacity for the sidebar veil.
    static func sidebarIncreasedContrastOverlay(isDark: Bool) -> Double {
        increasedContrastOverlay(base: sidebar(isDark: isDark).baseOpacity)
    }

    /// Increased Contrast overlay opacity for the workspace veil.
    static func workspaceIncreasedContrastOverlay(isDark: Bool) -> Double {
        increasedContrastOverlay(base: workspace(isDark: isDark).baseOpacity)
    }
}

private struct KaisolaControlSurfaceModifier: ViewModifier {
    let active: Bool
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: KaisolaVisualSystem.controlRadius,
            style: .continuous
        )
        let strokeOpacity = accessibilityContrast == .increased ? 0.22 : (active ? 0.12 : 0.07)

        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: KaisolaVisualSystem.hairline))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(
                        .regular
                            .tint(tint?.opacity(active ? 0.16 : 0.08))
                            .interactive(interactive),
                        in: shape
                    )
                    .overlay(shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: KaisolaVisualSystem.hairline))
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: KaisolaVisualSystem.hairline))
            }
            #else
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: KaisolaVisualSystem.hairline))
            #endif
        }
    }
}

extension View {
    /// Enforces Reduce Motion for a complete native presentation tree. Keep it
    /// on every independently hosted root rather than relying on each child to
    /// remember the preference.
    func kaisolaReduceMotionFallback() -> some View {
        modifier(KaisolaReduceMotionFallbackModifier())
    }

    /// Adaptive Liquid Glass on macOS 26, with a semantic material fallback on
    /// macOS 14/15 and a solid surface when Reduce Transparency is enabled.
    func kaisolaControlSurface(
        active: Bool = false,
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        modifier(KaisolaControlSurfaceModifier(active: active, tint: tint, interactive: interactive))
    }

    /// Safari's inset floating-card chrome. The window backdrop stays visible
    /// in a gutter around the panel; the content rides a rounded material with
    /// a hairline top-light edge. Reduce Transparency yields a clean solid.
    /// A floating inset card for content that must be isolated from whatever is
    /// behind the window — the detail canvas and its panels.
    ///
    /// Deliberately *not* used by the project sidebar: navigation chrome has
    /// nothing to isolate, and stacking this material over the sidebar backdrop
    /// hid the desktop that backdrop exists to show.
    func kaisolaChromePanel(
        inset: CGFloat = KaisolaVisualSystem.chromeInset,
        topInset: CGFloat? = nil
    ) -> some View {
        modifier(
            KaisolaChromePanelModifier(
                inset: inset,
                topInset: topInset ?? inset
            )
        )
    }
}

private struct KaisolaChromePanelModifier: ViewModifier {
    let inset: CGFloat
    let topInset: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = NativePreviewSettings.shared

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: KaisolaVisualSystem.chromeRadius,
            style: .continuous
        )
        return content
            .clipShape(shape)
            .background { panelFill(shape) }
            .overlay { panelEdge(shape) }
            .padding(.top, topInset)
            .padding(.leading, inset)
            .padding(.trailing, inset)
            .padding(.bottom, inset)
    }

    /// Dark appearance darkens the panel instead of lightening it.
    ///
    /// `.thinMaterial` is a *light-leaning* material: it lifts whatever is under
    /// it toward white in both appearances. Over the detail column — which is
    /// most of the window — that meant the one surface the glass work was solved
    /// for was covered by something pulling the opposite way, so dark mode read
    /// as washed grey rather than dark glass, and the composite the veil
    /// constants were measured against never actually reached the screen. It is
    /// a large part of why the glass did not look dark, and no amount of tuning
    /// the bake underneath it would have shown.
    ///
    /// The replacement keeps the panel's real job — isolating content from the
    /// backdrop so text keeps its floor — but does it with neutral black over a
    /// thinner material, so the surface moves down instead of up and the backdrop
    /// still shows through. Light appearance is unchanged: there `.thinMaterial`
    /// already moves the surface the way it should go.
    /// The panel isolates content from the backdrop, so what it should lay down
    /// depends on what the backdrop actually is. It used to lay a material down
    /// unconditionally, which is why Solid was never white: `windowBackgroundColor`
    /// really does resolve to #FFFFFF in light appearance, and then this covered
    /// it with a translucent grey. Solid promises "a flat opaque surface with no
    /// wallpaper in it at all" and Tinted promises the desktop's hue over that
    /// surface. Neither has a backdrop to be isolated from, so neither gets a
    /// material; only Glass, which genuinely shows the desktop, still needs one.
    @ViewBuilder
    private func panelFill(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape.fill(Color(nsColor: .controlBackgroundColor))
        } else {
            switch settings.workspaceBackdrop {
            case .system:
                // The white solid, stated here rather than left to show through,
                // so the panel keeps its own opacity contract.
                shape.fill(Color(nsColor: .windowBackgroundColor))
            case .tinted:
                // `WorkspaceBackdropView` already composites the solid surface
                // and the desktop's hue over it. Anything added here would only
                // grey down the tint this theme exists to show.
                Color.clear
            case .glass:
                if colorScheme == .dark {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.black.opacity(Self.darkPanelCoverage))
                    }
                } else {
                    // The global workspace layer already owns the blur. A
                    // second material here turned the otherwise-white canvas
                    // grey and nearly erased its remaining depth, so the panel
                    // is only an achromatic frost over that shared glass.
                    shape.fill(Color.white.opacity(LightGlassFrost.panelWhiteCoverage))
                }
            }
        }
    }

    /// How much neutral black the dark panel lays over its own thin material.
    /// Chosen so the panel is at least as isolating as `.thinMaterial` was —
    /// content legibility must not regress — while moving the surface down
    /// rather than up.
    static let darkPanelCoverage: Double = 0.34

    /// The lit top edge is what sells a floating card. Reduce Transparency
    /// swaps it for the flat semantic separator so nothing reads as glass.
    @ViewBuilder
    private func panelEdge(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape.strokeBorder(
                Color(nsColor: .separatorColor),
                lineWidth: KaisolaVisualSystem.hairline
            )
        } else {
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.15 : 0.52),
                        Color.white.opacity(colorScheme == .dark ? 0.03 : 0.10),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: KaisolaVisualSystem.hairline
            )
        }
    }
}

/// Groups nearby macOS 26 glass controls so the system can render and morph
/// them as one efficient material region. Older systems simply render the same
/// control hierarchy with the per-control semantic material fallback.
struct KaisolaGlassEffectGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(spacing: CGFloat = 4, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
