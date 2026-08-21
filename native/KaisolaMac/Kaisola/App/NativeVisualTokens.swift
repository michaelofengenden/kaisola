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
    /// v0.1.127 climbs the whole ladder again ("let's make the edges of the
    /// app more rounded"): a point at the small end, four on the chrome, six
    /// on the shell. The strict ordering holds at 9 < 11 < 13 < 16 < 18 < 22
    /// < 26, and the perceived roundness lives in `chromeRadius` — the corner
    /// that sits mid-screen for the whole session, where the window's own
    /// 10pt system corner is only glanced at.
    static let controlRadius: CGFloat = 9
    /// A session pane card, which sits *inside* the detail chrome panel. Was a
    /// bare `8` written inline in `RootShellView.unifiedSessionCard`; naming it
    /// is what puts it on the ladder at all.
    static let paneRadius: CGFloat = 11
    static let insetRadius: CGFloat = 13
    static let cardRadius: CGFloat = 16
    /// The document-preview and Files panels, which are nested one level inside
    /// the detail chrome panel and so stay a step under `chromeRadius`.
    static let panelRadius: CGFloat = 18
    static let shellRadius: CGFloat = 26
    /// Safari's inset floating-card chrome: the radius of the sidebar and
    /// detail panels that float over the window backdrop. Larger than
    /// `cardRadius` (which belongs to session cards *inside* a panel) and
    /// smaller than `shellRadius` (the window itself).
    static let chromeRadius: CGFloat = 22
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

/// What makes the detail card read as floating rather than as a tinted region.
///
/// Safari's web-content card is separated from its sidebar by three things at
/// once: a gutter of ground, a continuous-corner clip, and a soft shadow.
/// Kaisola has had the first two since the flush-rail change, and none of the
/// third — the card's light-appearance bottom edge was a white 0.10 hairline
/// over a near-white ground, which is no edge at all.
enum ChromeCardElevation {
    /// Blur radius of the card's drop shadow. Sized against `chromeInset` (6):
    /// a shadow that never leaves its own gutter is not perceived as depth,
    /// and one wider than about twice the gutter smears onto the far rail.
    static let shadowRadius: CGFloat = 12
    static let shadowOffsetY: CGFloat = 3

    static func shadowOpacity(isDark: Bool) -> Double { isDark ? 0.30 : 0.10 }

    /// The containment hairline drawn *under* `panelEdge`'s top-light
    /// gradient. The gradient lights the top; nothing was closing the bottom
    /// and sides. Dark returns zero because dark already has the
    /// `darkPanelCoverage` luminance step doing that work.
    static func containmentOpacity(isDark: Bool) -> Double { isDark ? 0.0 : 0.07 }

    /// Reduce Transparency and Increased Contrast both asked for a flat,
    /// high-edge surface. Both get the existing `separatorColor` border and
    /// no shadow.
    static func engages(reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        !reduceTransparency && !increasedContrast
    }
}

/// The chat transcript's vertical rhythm. One uniform stack spacing gave a
/// user message, a tool chip, and a 400-word answer identical separation,
/// which reads as a list rather than a conversation: a turn boundary must be
/// a larger event than the next artifact inside the same reply. Mesh columns
/// are narrow and keep their own tighter literals on purpose.
enum AcpTranscriptMetrics {
    /// Across a turn boundary — before a user message, and before the reply
    /// that follows one.
    static let turnSpacing: CGFloat = 20
    /// Between consecutive assistant artifacts: message, tool call, plan.
    static let intraTurnSpacing: CGFloat = 8
    static let pagePadding: CGFloat = 20
    static let horizontalPadding: CGFloat = 22
    /// Between blocks inside one rendered assistant message.
    static let messageBlockSpacing: CGFloat = 12

    /// The only distinction the rhythm draws. Everything that is not the
    /// user's own message — audits and permission decisions included — sits
    /// on the assistant's side of the conversation.
    enum RowKind: Equatable, Sendable {
        case user
        case assistant
    }

    /// Top spacing for the row after the pair's boundary. Pure, so the pair
    /// table is a unit test rather than a scroll-through; `nil` means the row
    /// opens the transcript and the page padding owns that edge.
    static func spacing(before previous: RowKind?, after current: RowKind) -> CGFloat {
        guard let previous else { return 0 }
        if current == .user || previous == .user { return turnSpacing }
        return intraTurnSpacing
    }
}

/// The user bubble's surface. Achromatic on purpose: the Glass and Tinted
/// backdrops are deliberately near-achromatic, and the old accent wash was
/// the one tinted plate fighting them on every desktop. The accent survives
/// only on the failed state's border.
enum AcpBubble {
    /// Wider than this and a short prompt stops being a bubble and becomes
    /// the old full-width band; longer prompts wrap instead of stretching.
    static let maximumWidth: CGFloat = 560
    /// A bubble is wider than it is tall.
    static let horizontalPadding: CGFloat = 13
    static let verticalPadding: CGFloat = 9

    /// Light: a quiet ink wash, quaternary-weight. Dark: a near-black lift
    /// above the pane — opaque, like the composer card, so a pasted block
    /// stays readable over any backdrop. Resolved by the drawing appearance,
    /// the `KaisolaInk` idiom.
    static var userFill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1)
                : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.055)
        })
    }
}

/// Stroke coverage shared by the two horizontal tab families.
enum SurfaceTabChrome {
    static let projectSelectedStrokeOpacity = 0.38
    static let sessionSelectedStrokeOpacity = 0.30
    static let inactiveStrokeOpacity = 0.11
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
/// The center and rails now have deliberately different jobs. The workspace
/// carrier is opaque white, making the working canvas exact and stable. The
/// rails have no second carrier at all: their single white veil sits at about
/// twelve percent, so live material keeps its colour and movement. The rails
/// add their own named, tightly bounded cool-to-pearl edge tint.
enum LightGlassFrost {
    /// Neutral luminance of a painted wallpaper before the white veil.
    ///
    /// Went 0.72 → 0.80 when the shipped surface was reported grey, and
    /// 0.80 → 0.85 in the third round of the same report: raising the
    /// normalized underlay whitens every light-glass surface without
    /// spending a point of wallpaper transmission. The ceiling is ~0.87 —
    /// past it the dark warmth overlay (which divides by this value) falls
    /// through its measured floor.
    static let backdropLuminance: Double = 0.85

    /// The workspace is a white-led plane the desktop still shines through.
    ///
    /// This was 1.0 — an opaque white carrier, "the workspace is a white
    /// working plane" — and that made light Glass indistinguishable from the
    /// white Solid across the whole center of the window. Michael, 2026-08-14:
    /// "for glass … make sure they're actually translucent." At 0.45, with the
    /// workspace veil thinned in step, the canvas still white-leads (modeled
    /// luminance ≈ 0.93 against the normalized 0.80 still) but a third of the
    /// luminance-normalized, spread-capped desktop arrives — the same chroma
    /// presence the rail era measured as unmistakably tinted. The ink ladder
    /// was solved against the rails' deeper worst patch, so the brighter
    /// canvas stays inside every measured floor.
    static let carrierWhiteCoverage: Double = 0.45

    /// Rails get their frost from `GlassBackdropWash.sidebar` alone. A second
    /// white layer would composite with its twelve-percent veil and quietly
    /// turn the shared material back into an opaque-looking panel.
    static let railCarrierWhiteCoverage: Double = 0.0

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

    static func modeledRailLuminance(_ wash: GlassBackdropWash) -> Double {
        let carried = railCarrierWhiteCoverage
            + (1 - railCarrierWhiteCoverage) * backdropLuminance
        return wash.baseOpacity + wash.desktopTransmission * carried
    }

    static func modeledRailDesktopContribution(_ wash: GlassBackdropWash) -> Double {
        (1 - railCarrierWhiteCoverage) * wash.desktopTransmission
    }
}

/// The opaque themes' share of the shared material ground.
///
/// Safari's window ground is material in every mode; only the content card
/// changes. Solid and Tinted used to paint a flat plate instead, which is why
/// the window's edge read as a box in two of the three themes. They keep the
/// colour they already had — light #FFFFFF, dark #1E1E1E — and gain the
/// remainder as behind-window material.
enum OpaqueThemeGround {
    /// Dark Solid/Tinted keep `windowBackgroundColor`'s own value (30/255),
    /// NOT `GlassBackdropWash.darkVeil` (#0D0D0D): the point is that the
    /// surface does not change colour, only gains transmission.
    static let darkPlate = (red: 30.0 / 255, green: 30.0 / 255, blue: 30.0 / 255)

    /// Solid keeps almost all of its plate. A tenth of the material is enough
    /// for the window edge to read as a pane rather than a card, and no
    /// wallpaper feature survives 0.88 coverage over a 28pt blur.
    static let solidCoverage = (light: 0.88, dark: 0.90)

    /// Tinted is the living theme, so it gives up more: a fifth of the
    /// surface is material, and the flowing gradient composites over that.
    static let tintedCoverage = (light: 0.80, dark: 0.84)

    static func coverage(theme: WorkspaceBackdropMode, isDark: Bool) -> Double {
        switch theme {
        case .system: isDark ? solidCoverage.dark : solidCoverage.light
        case .tinted: isDark ? tintedCoverage.dark : tintedCoverage.light
        // Glass's ground is its own wash; named here only so the three
        // themes' coverages can be compared in one expression.
        case .glass: GlassBackdropWash.workspace(isDark: isDark).baseOpacity
        }
    }

    /// Modeled composite luminance over the normalized still, same method as
    /// `LightGlassFrost.modeledBackdropLuminance`, for the tests.
    static func modeledLuminance(theme: WorkspaceBackdropMode, isDark: Bool) -> Double {
        let plateCoverage = coverage(theme: theme, isDark: isDark)
        // Both plates are achromatic, so luminance is any channel.
        let plate = isDark ? darkPlate.red : 1.0
        let underlay = DesktopBackdropRenderer.targetLuminance(isDark: isDark)
        return plateCoverage * plate + (1 - plateCoverage) * underlay
    }
}

enum SidebarRailPlacement: Equatable, Sendable {
    case leading
    case trailing

    var tintStartPoint: UnitPoint {
        self == .leading ? .topLeading : .topTrailing
    }

    var tintEndPoint: UnitPoint {
        self == .leading ? .bottomTrailing : .bottomLeading
    }
}

/// A restrained cool-to-pearl cast at the two outside window edges.
enum LightRailTint {
    static let cool = (red: 90.0 / 255, green: 169.0 / 255, blue: 1.0)
    static let pearl = (red: 1.0, green: 201.0 / 255, blue: 133.0 / 255)
    /// Halved with the white-rail pass: over the brighter ground the old
    /// 0.035 cool edge read as a lavender-grey cast, which was most of what
    /// "gray" meant in practice.
    static let coolCoverage = 0.018
    static let midpointCoverage = 0.008
    static let pearlCoverage = 0.008
    static let midpointLocation = 0.62
    /// Was 0.12, which snuffed the rail's only warmth the moment focus left
    /// and stacked on top of the material's own inactive collapse. The rails
    /// are not a focus indicator; the traffic lights and the toolbar already
    /// are, so an unfocused window keeps nearly all of its edge cast.
    static let inactiveMultiplier = 0.85
    static let maximumCoverage = max(coolCoverage, midpointCoverage, pearlCoverage)
    static let minimumTransmission = 1 - maximumCoverage

    static var coolColor: Color {
        Color(red: cool.red, green: cool.green, blue: cool.blue)
    }

    static var pearlColor: Color {
        Color(red: pearl.red, green: pearl.green, blue: pearl.blue)
    }
}

/// One tint source colour. A struct rather than a `(red:green:blue:)` tuple
/// so palettes can be compared, iterated, and held in a table.
struct TintRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 8-bit convenience so the palette table reads as the hexes it documents.
    init(_ r: Int, _ g: Int, _ b: Int) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    var minimumChannel: Double { min(red, min(green, blue)) }
    var maximumChannel: Double { max(red, max(green, blue)) }
}

/// The light half of a palette: two coloured ends crossing a quiet midpoint.
struct TintPaletteLight: Equatable, Sendable {
    let cool: TintRGB
    let neutral: TintRGB
    let pearl: TintRGB
    let coolCoverage: Double
    let neutralCoverage: Double
    let pearlCoverage: Double
    let neutralLocation: Double
}

/// The Tinted theme's named colourways. The light Tinted surface is a
/// deliberate colour composition rather than a raw sampled desktop hue that
/// can turn every surface flat blue: every palette here was solved against
/// the composite-over-white box the visibility tests assert, not eyeballed.
/// Meadow is the shipped composition and stays the default.
enum TintPalette: String, CaseIterable, Identifiable, Sendable {
    case meadow, dusk, harbor, graphite, desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meadow: "Meadow"
        case .dusk: "Dusk"
        case .harbor: "Harbor"
        case .graphite: "Graphite"
        case .desktop: "Desktop"
        }
    }

    var detail: String {
        switch self {
        case .meadow: "Sage crossing a lilac pearl"
        case .dusk: "Warm sand crossing a dusty rose"
        case .harbor: "Powder blue crossing a seafoam"
        case .graphite: "Cool grey crossing a warm grey"
        case .desktop: "Your wallpaper's own hue, held to a pastel"
        }
    }
}

extension TintPalette {
    /// Graphite stands alone so `desktopLight(_:)` can fall back to it
    /// without force-unwrapping its own table.
    private static let graphiteLight = TintPaletteLight(
        cool: TintRGB(178, 186, 196),
        neutral: TintRGB(224, 219, 212),
        pearl: TintRGB(196, 189, 180),
        coolCoverage: 0.30, neutralCoverage: 0.22, pearlCoverage: 0.30,
        neutralLocation: 0.54
    )

    /// The constant light stops. `.desktop` has none — see `light(desktop:)`.
    ///
    /// Coverages are shared across the table: only the sources change per
    /// palette, so every palette's luminance envelope — and therefore the ink
    /// ladder measured against the worst patch — stays where Meadow put it.
    var fixedLight: TintPaletteLight? {
        switch self {
        case .meadow: TintPaletteLight(
            cool: TintRGB(165, 203, 178),
            neutral: TintRGB(233, 221, 207),
            pearl: TintRGB(203, 185, 226),
            coolCoverage: 0.30, neutralCoverage: 0.22, pearlCoverage: 0.30,
            neutralLocation: 0.54
        )
        case .dusk: TintPaletteLight(
            cool: TintRGB(216, 191, 172),
            neutral: TintRGB(233, 213, 198),
            pearl: TintRGB(217, 175, 192),
            coolCoverage: 0.30, neutralCoverage: 0.22, pearlCoverage: 0.30,
            neutralLocation: 0.54
        )
        case .harbor: TintPaletteLight(
            cool: TintRGB(171, 196, 218),
            neutral: TintRGB(230, 222, 208),
            pearl: TintRGB(175, 213, 203),
            coolCoverage: 0.30, neutralCoverage: 0.22, pearlCoverage: 0.30,
            neutralLocation: 0.54
        )
        case .graphite: Self.graphiteLight
        case .desktop: nil
        }
    }

    /// The light stops for a given desktop sample. Constant palettes ignore it.
    func light(desktop tint: DesktopTintComponents) -> TintPaletteLight {
        if let fixedLight { return fixedLight }
        return Self.desktopLight(tint)
    }

    /// Saturation/brightness that put *any* hue inside the composite box.
    /// The reason light never sampled the desktop before is that a saturated
    /// wallpaper turns every surface flat blue; fixing saturation and
    /// brightness and keeping only the hue removes that failure by
    /// construction.
    static let desktopSaturation: Double = 0.22
    static let desktopBrightness: Double = 0.80
    static let desktopNeutralSaturation: Double = 0.10
    static let desktopNeutralBrightness: Double = 0.90

    static func desktopLight(_ tint: DesktopTintComponents) -> TintPaletteLight {
        // A grey wallpaper has no hue to keep; Graphite is what "no hue,
        // pastel" already means, so it is the fallback rather than a
        // near-white nothing.
        guard let hue = TintFlowMotion.hue(red: tint.red, green: tint.green, blue: tint.blue)
        else { return graphiteLight }
        let companionHue = (hue + TintFlowMotion.companionHueRotation)
            .truncatingRemainder(dividingBy: 1)
        return TintPaletteLight(
            cool: TintFlowMotion.rgb(
                hue: hue,
                saturation: desktopSaturation,
                brightness: desktopBrightness
            ),
            neutral: TintFlowMotion.rgb(
                hue: hue,
                saturation: desktopNeutralSaturation,
                brightness: desktopNeutralBrightness
            ),
            pearl: TintFlowMotion.rgb(
                hue: companionHue,
                saturation: desktopSaturation,
                brightness: desktopBrightness
            ),
            coolCoverage: graphiteLight.coolCoverage,
            neutralCoverage: graphiteLight.neutralCoverage,
            pearlCoverage: graphiteLight.pearlCoverage,
            neutralLocation: graphiteLight.neutralLocation
        )
    }

    /// How much chroma the palette keeps in dark. Graphite is grey by
    /// definition and would stop being itself at the shared value.
    var darkSaturation: Double { self == .graphite ? 0.10 : 0.30 }

    /// The dark stop pair: the palette's two light ends taken to the dark
    /// canvas peak at the palette's own saturation. Hue is the only thing
    /// carried over, which is what keeps a dark Harbor recognisably Harbor.
    /// `.desktop` returns nil — its dark path stays the sampled one.
    func darkEnds() -> (anchor: TintRGB, companion: TintRGB)? {
        guard let light = fixedLight else { return nil }
        let peak = DesktopTintSampler.canvasTintPeak(isDark: true)
        func end(_ source: TintRGB) -> TintRGB {
            guard let hue = TintFlowMotion.hue(
                red: source.red,
                green: source.green,
                blue: source.blue
            ) else { return TintRGB(red: peak, green: peak, blue: peak) }
            return TintFlowMotion.rgb(hue: hue, saturation: darkSaturation, brightness: peak)
        }
        return (anchor: end(light.cool), companion: end(light.pearl))
    }
}

/// How loudly the Tinted theme speaks.
///
/// A runtime multiplier at composition time, applied where `railTintShare`
/// already multiplies — the palette *definitions* stay inside the pastel box
/// the visibility tests pin, and intensity is the user turning that
/// composition up. Standard is the shipped voice, so an existing install sees
/// no change until it chooses.
enum TintIntensity: String, CaseIterable, Identifiable, Sendable {
    case standard, vivid, bold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .vivid: "Vivid"
        case .bold: "Bold"
        }
    }

    var detail: String {
        switch self {
        case .standard: "The composition as designed"
        case .vivid: "The same palette, half again as present"
        case .bold: "The gradient at full voice"
        }
    }

    /// Multiplier on every stop's coverage. Bounded well under saturation:
    /// the heaviest shipped stop is 0.30, so even Bold's product (0.57)
    /// stays a translucent tint over the material ground, never a plate.
    var coverageMultiplier: Double {
        switch self {
        case .standard: 1.0
        case .vivid: 1.45
        case .bold: 1.9
        }
    }

    /// Multiplier on the living tint's breath — the opacity swing and the
    /// swell together, so the two halves stay one gesture. Bold's effective
    /// amplitude is 0.24: a breath one can find without hunting, still
    /// nowhere near a pulse.
    var breathDepthMultiplier: Double {
        switch self {
        case .standard: 1.0
        case .vivid: 1.25
        case .bold: 1.5
        }
    }
}

/// The Meadow palette's original name.
///
/// The stops tripled in 2026-08-14's pass. At eleven percent the whole
/// composition quantized to within a few counts of white — the Tinted fixture
/// was pixel-for-pixel the Glass fixture — and Michael asked for "a flowing
/// gradient tint", which first of all requires a gradient one can see. Thirty
/// percent keeps the sources pastel while the sweep finally reads as colour
/// crossing the surface. The numbers live in `TintPalette.meadow.fixedLight`
/// now; this shim only forwards them so long-standing call sites keep
/// compiling.
enum LightTintedGradient {
    private static var meadow: TintPaletteLight { TintPalette.meadow.fixedLight! }

    static var cool: TintRGB { meadow.cool }
    static var neutral: TintRGB { meadow.neutral }
    static var pearl: TintRGB { meadow.pearl }
    static var coolCoverage: Double { meadow.coolCoverage }
    static var neutralCoverage: Double { meadow.neutralCoverage }
    static var pearlCoverage: Double { meadow.pearlCoverage }
    static var neutralLocation: Double { meadow.neutralLocation }

    static var coolColor: Color { cool.color }
    static var pearlColor: Color { pearl.color }
    static var neutralColor: Color { neutral.color }
}

/// The Tinted surfaces' slow drift — what makes the gradient *flow*.
///
/// The motion is a Core Animation autoreversing drift of the gradient's
/// endpoints, chosen over any SwiftUI timeline because the render server owns
/// the whole animation: zero main-thread wakeups, zero invalidation traffic,
/// and the glass-era energy rules (painted stills, no per-frame app work)
/// unchanged.
/// The period is deliberately far below attention speed — the surface should
/// never be *seen moving*, only found elsewhere when the eye returns — and
/// Reduce Motion pins the endpoints outright.
enum TintFlowMotion {
    /// One full drift in each direction, in seconds. Twenty-six seconds is
    /// glacial on purpose: at this period the endpoint travels under a point
    /// per second on a full-height window.
    static let period: TimeInterval = 26
    /// How far each endpoint wanders, as a fraction of the unit square. The
    /// sweep stays diagonal throughout; only its anchoring breathes.
    static let drift: Double = 0.18

    /// Opt-in breath: the whole tint fading and returning. Nineteen seconds,
    /// and a sixth of the layer's opacity rather than a twelfth: at 0.08 the
    /// swing was two counts of 255 on the heaviest stop — under the threshold
    /// where anyone reported seeing it at all. At 0.16 it is four to five
    /// counts across nineteen seconds: found when the eye returns, still
    /// nowhere near a pulse. The period is deliberately not a harmonic of
    /// `period`, so the breath never phase-locks with the drift.
    static let breathPeriod: TimeInterval = 19
    static let breathAmplitude: Double = 0.16
    static var breathFloorOpacity: Double { 1 - breathAmplitude }

    /// The breath's second half: the gradient field swelling 2.8% about its
    /// centre on its own, longer period. Opacity alone reads as a dimmer;
    /// opacity plus a slow swell reads as a surface that is alive. The scale
    /// never goes below 1, so the layer only ever over-covers its bounds and
    /// no edge can be exposed. Drift 26, opacity 19, scale 23: no pair within
    /// 0.05 of an integer ratio, so nothing phase-locks into a metronome.
    static let breathScalePeriod: TimeInterval = 23
    static let breathScaleAmplitude: Double = 0.028

    /// A slightly sharper S than `easeInEaseOut`: more dwell at the extremes,
    /// a quicker transit between them, which is what makes a shallow change
    /// register at all without raising its depth.
    static let breathTimingControlPoints: (Float, Float, Float, Float) = (0.45, 0.05, 0.55, 0.95)

    /// A screenshot must never catch a mid-drift frame. Pinned in every
    /// isolated fixture process, exactly as `tintedBreathing` already is in
    /// the app delegate's fixture branch — but structural, so adding a tinted
    /// surface to CI cannot forget it.
    static func isPinned(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        NativePreviewSettings.isIsolatedFixture(environment: environment)
    }

    /// SwiftUI's `UnitPoint` puts (0,0) at the top-leading corner;
    /// `CAGradientLayer`'s unit space on an unflipped AppKit host puts (0,0)
    /// at the bottom-left. One explicit conversion, because the first build
    /// shipped the sweep upside down — sage measured at the bottom of the
    /// rail — and a flip is invisible in code review and obvious in a pixel.
    static func layerPoint(_ unit: UnitPoint) -> CGPoint {
        CGPoint(x: unit.x, y: 1 - unit.y)
    }

    /// Where the drifting endpoints travel between, for one placement.
    /// Pure, so the geometry is a test rather than a screenshot.
    static func endpoints(
        start: CGPoint,
        end: CGPoint
    ) -> (startFrom: CGPoint, startTo: CGPoint, endFrom: CGPoint, endTo: CGPoint) {
        let dx = (end.x - start.x) * drift
        let dy = (end.y - start.y) * drift
        // The start leads the drift and the end trails it, so the sweep's
        // length breathes a little as it moves and the midpoint truly travels.
        return (
            startFrom: start,
            startTo: CGPoint(x: start.x + dx, y: start.y + dy),
            endFrom: CGPoint(x: end.x - dx, y: end.y - dy),
            endTo: end
        )
    }

    /// The dark companion hue: the sampled desktop tint rotated far enough
    /// around the wheel that the two ends of the sweep read as different
    /// colours of one family, never as a second unrelated accent.
    static let companionHueRotation: Double = 0.09

    /// The full HSB reading, or nil for an achromatic sample. The guard is
    /// deliberately identical to `companion`'s original inline one so a grey
    /// keeps passing through untouched.
    static func hsb(
        red: Double,
        green: Double,
        blue: Double
    ) -> (hue: Double, saturation: Double, brightness: Double)? {
        let maximum = max(red, max(green, blue))
        let minimum = min(red, min(green, blue))
        let delta = maximum - minimum
        guard delta > 0.0001, maximum > 0.0001 else { return nil }
        var hue: Double
        if maximum == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue: hue, saturation: delta / maximum, brightness: maximum)
    }

    /// Hue in [0,1), or nil for an achromatic sample that has no hue to keep.
    static func hue(red: Double, green: Double, blue: Double) -> Double? {
        hsb(red: red, green: green, blue: blue)?.hue
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double) -> TintRGB {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: return TintRGB(red: brightness, green: t, blue: p)
        case 1: return TintRGB(red: q, green: brightness, blue: p)
        case 2: return TintRGB(red: p, green: brightness, blue: t)
        case 3: return TintRGB(red: p, green: q, blue: brightness)
        case 4: return TintRGB(red: t, green: p, blue: brightness)
        default: return TintRGB(red: brightness, green: p, blue: q)
        }
    }

    /// Pure HSB rotation of a sampled tint. Saturation and brightness are
    /// kept, so the companion stays exactly as quiet as its source.
    static func companion(
        red: Double,
        green: Double,
        blue: Double
    ) -> (red: Double, green: Double, blue: Double) {
        guard let source = hsb(red: red, green: green, blue: blue) else {
            return (red, green, blue)
        }
        let rotated = rgb(
            hue: (source.hue + companionHueRotation).truncatingRemainder(dividingBy: 1),
            saturation: source.saturation,
            brightness: source.brightness
        )
        return (rotated.red, rotated.green, rotated.blue)
    }
}

/// The thinking shimmer: a highlight sweeping the chat's status word while a
/// turn runs.
///
/// This is watchable motion in an app whose whole visual thesis is motion you
/// never catch moving. It is allowed because it is bounded — the label exists
/// only while a turn is running — and because it replaces a spinner, which was
/// also watchable motion saying less. The sweep itself is a Core Animation
/// `locations` interpolation owned by the render server, the same ownership as
/// `TintFlowMotion`: zero main-thread wakeups while it runs.
enum ThinkingShimmerMotion {
    /// One sweep, leading edge to trailing edge, in seconds. Below one second
    /// the sweep is a strobe; above two and a half it reads as a hang.
    static let period: TimeInterval = 1.6
    /// Half-width of the highlight ramp as a fraction of the label's width.
    static let highlightWidth: Double = 0.16
    /// How far past each edge the highlight starts and ends, so the sweep
    /// enters and leaves rather than materialising inside the word.
    static let overscan: Double = 0.25
    /// The highlight's lift over the resting ink, as an alpha delta. Sized so
    /// `highlightAlpha` always reaches its cap: the shimmer is the existing
    /// secondary ink briefly becoming the existing primary ink, never a new
    /// colour on the ladder.
    static let highlightLift: Double = 0.55

    /// The five gradient-stop locations at a phase of the sweep, 0 through 1.
    /// Pure: the geometry is a unit test rather than a screenshot.
    static func locations(phase: Double) -> [Double] {
        let center = -overscan + phase * (1 + 2 * overscan)
        return [
            center - highlightWidth,
            center - highlightWidth / 2,
            center,
            center + highlightWidth / 2,
            center + highlightWidth,
        ]
    }

    static var startLocations: [Double] { locations(phase: 0) }
    static var endLocations: [Double] { locations(phase: 1) }

    /// The highlight's ink coverage: the resting rung lifted by
    /// `highlightLift`, held at the primary rung so the peak of the sweep is
    /// exactly the primary ink.
    static func highlightAlpha(resting: Double, primary: Double) -> Double {
        min(primary, resting + highlightLift)
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
///     α 0.610 (Kaisola)  ≥4.5:1
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
/// is the hard one and sets α 0.61. Light solid is white — `windowBackgroundColor`,
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
            isDark ? 0.55 : (surface == .glass ? 0.61 : 0.55)
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
    /// kinds of surface and glass is the safe superset: α 0.61 on an opaque
    /// white surface is about 6:1, still unmistakably junior to primary's 15:1.
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
    /// the system semantic: on this surface, black at α 0.61 clears the
    /// **4.5:1** floor on the worst patch of the deliberately clearer rails.
    /// That is `KaisolaInk` now, adopted at the call sites rather than smuggled
    /// in through a glass constant — the veil still may not make text legible
    /// on its own, and the sentence above still binds this number. What changed
    /// is that the app no longer *asks* the veil to.
    static func sidebar(isDark: Bool, clarity: GlassClarity = .balanced) -> GlassBackdropWash {
        sidebarBase(isDark: isDark).scaled(by: clarity.veilScale)
    }

    private static func sidebarBase(isDark: Bool) -> GlassBackdropWash {
        // Third round of "the rails look gray", answered for real this time:
        // 0.30 lifted the rail to 0.86 modeled luminance and it still read
        // grey beside the 0.93 canvas. Forty-six percent (with the underlay
        // at 0.85) lands the rail at ≈0.92 — white-led like Safari's sidebar
        // — while transmission (0.54) stays above the hard 0.50 floor the
        // structure tests hold, so the desktop still moves through the glass.
        isDark
            ? dark(top: 0.27, base: 0.34, bottom: 0.43)
            : light(top: 0.50, base: 0.46, bottom: 0.42)
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
        // Light stepped 0.40 → 0.38 with the 2026-08-14 carrier drop; the two
        // move together so the canvas lands at modeled luminance ≈ 0.93,
        // white-led but no longer the flat plane the opaque carrier made it.
        isDark
            ? dark(top: 0.30, base: 0.37, bottom: 0.46)
            : light(top: 0.44, base: 0.38, bottom: 0.34)
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
    /// Dark retains its established 0.70 ceiling. Light rails deliberately
    /// move into a clearer 0.90 band; their normalized still, named twelve-point
    /// veil, and custom ink keep that extra transmission from becoming raw desktop.
    static func desktopTransmissionBand(isDark: Bool) -> (floor: Double, ceiling: Double) {
        isDark ? (floor: 0.30, ceiling: 0.70) : (floor: 0.30, ceiling: 0.90)
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

    /// Increased Contrast overlay for an opaque theme's ground. Solid's
    /// 0.88/0.90 plate already clears the 0.80 floor and derives zero, and
    /// Tinted's 0.80/0.84 sits exactly at or above it — the call is kept so a
    /// future coverage cut cannot silently fall below the floor.
    static func opaqueGroundIncreasedContrastOverlay(
        theme: WorkspaceBackdropMode,
        isDark: Bool
    ) -> Double {
        increasedContrastOverlay(
            base: OpaqueThemeGround.coverage(theme: theme, isDark: isDark)
        )
    }

    /// The centre ground for an opaque theme: the plate colour at
    /// `OpaqueThemeGround.coverage`, laid over the shared material. Gradient
    /// endpoints keep the ±0.04 light-from-above spread the glass washes use,
    /// so the ground still lights from the top-leading corner in every theme.
    ///
    /// Deliberately NOT routed through `desktopTransmissionBand(isDark:)`:
    /// that band is the *glass* contract and an opaque theme sits below its
    /// transmission floor on purpose — a tenth of material is a pane edge,
    /// not a glass surface. `GlassClarity` does not scale these either;
    /// clarity is a glass knob, and scaling the Solid ground would turn Solid
    /// into a fourth theme.
    static func opaqueGround(theme: WorkspaceBackdropMode, isDark: Bool) -> GlassBackdropWash {
        guard theme != .glass else { return workspace(isDark: isDark) }
        let coverage = OpaqueThemeGround.coverage(theme: theme, isDark: isDark)
        let spread = 0.04
        // Light carries more white at the lit corner; dark carries less
        // near-black there — both read as light from above.
        let plate = OpaqueThemeGround.darkPlate
        return isDark
            ? GlassBackdropWash(
                red: plate.red,
                green: plate.green,
                blue: plate.blue,
                topOpacity: max(0, coverage - spread),
                baseOpacity: coverage,
                bottomOpacity: min(1, coverage + spread)
            )
            : GlassBackdropWash(
                red: 1,
                green: 1,
                blue: 1,
                topOpacity: min(1, coverage + spread),
                baseOpacity: coverage,
                bottomOpacity: max(0, coverage - spread)
            )
    }

    /// The rails' half of the same ground. Identical coverage: the rails and
    /// the canvas are one surface in the opaque themes — there is no chrome
    /// panel between them — so a separation step here would draw a seam.
    static func opaqueRailGround(appearance: SidebarAppearance, isDark: Bool) -> GlassBackdropWash {
        switch appearance {
        case .glass: sidebar(isDark: isDark)
        case .solid: opaqueGround(theme: .system, isDark: isDark)
        case .tinted: opaqueGround(theme: .tinted, isDark: isDark)
        }
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
    /// Deliberately *not* used by the project sidebar or the Files rail: the
    /// two rails are the ground and the detail content column is the card,
    /// and nothing else is either. Navigation chrome has nothing to isolate,
    /// and stacking this material over a rail backdrop hid the desktop that
    /// backdrop exists to show — the exact box the flush-rail change removed.
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
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @ObservedObject private var settings = NativePreviewSettings.shared

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: KaisolaVisualSystem.chromeRadius,
            style: .continuous
        )
        return content
            .clipShape(shape)
            .background { panelFill(shape) }
            .background { cardShadow(shape) }
            .overlay { panelEdge(shape) }
            .padding(.top, topInset)
            .padding(.leading, inset)
            .padding(.trailing, inset)
            .padding(.bottom, inset)
    }

    /// The card's float, drawn as a shadow-ring: an opaque shape, shadowed,
    /// then masked out of its own interior. It composites once and the render
    /// server caches it — no per-frame work and no offscreen pass over the
    /// live material the `.glass` fill sits on. The spill into the 6pt gutter
    /// is the depth cue, not a bug; it must never be clipped away, never
    /// animated, and never allowed to eat clicks aimed at the divider
    /// corridors that share that gutter.
    @ViewBuilder
    private func cardShadow(_ shape: RoundedRectangle) -> some View {
        if ChromeCardElevation.engages(
            reduceTransparency: reduceTransparency,
            increasedContrast: accessibilityContrast == .increased
        ) {
            shape
                .fill(Color.black)
                .shadow(
                    color: .black.opacity(
                        ChromeCardElevation.shadowOpacity(isDark: colorScheme == .dark)
                    ),
                    radius: ChromeCardElevation.shadowRadius,
                    x: 0,
                    y: ChromeCardElevation.shadowOffsetY
                )
                .compositingGroup()
                .mask {
                    Rectangle()
                        .overlay { shape.fill(Color.black).blendMode(.destinationOut) }
                        .compositingGroup()
                }
                .allowsHitTesting(false)
        }
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
    /// The panel isolates content from the backdrop, so what it should lay
    /// down depends on what the card is asked to isolate. Every theme's
    /// ground is material now — Solid and Tinted included — so the question
    /// is no longer *whether* there is a backdrop but whether the card lets
    /// it through. Solid's card stays fully opaque: that opacity is what
    /// keeps Solid's promise ("nothing behind the window reaches the surface
    /// your work sits on") now that the ground around the card is material.
    /// Tinted's card stays clear so the tint-over-material shows through it,
    /// and Glass keeps its frost.
    @ViewBuilder
    private func panelFill(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape.fill(Color(nsColor: .controlBackgroundColor))
        } else {
            switch settings.workspaceBackdrop {
            case .system:
                // The opaque fill is what makes the Solid card read as a
                // *card* — its edge against the material gutter is the whole
                // visible delta of the glass-ground change in Solid.
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
    /// and Increased Contrast both swap it for the flat semantic separator so
    /// nothing reads as glass — the same `engages` decision that withholds
    /// the shadow, so the card's whole accessibility posture is one switch.
    @ViewBuilder
    private func panelEdge(_ shape: RoundedRectangle) -> some View {
        if !ChromeCardElevation.engages(
            reduceTransparency: reduceTransparency,
            increasedContrast: accessibilityContrast == .increased
        ) {
            shape.strokeBorder(
                Color(nsColor: .separatorColor),
                lineWidth: KaisolaVisualSystem.hairline
            )
        } else {
            ZStack {
                // The containment hairline closes the bottom and sides in
                // light appearance, where the top-light gradient fades to a
                // white 0.10 that vanishes against a near-white ground. Dark
                // contributes zero and stays byte-identical.
                shape.strokeBorder(
                    Color.black.opacity(
                        ChromeCardElevation.containmentOpacity(isDark: colorScheme == .dark)
                    ),
                    lineWidth: KaisolaVisualSystem.hairline
                )
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
