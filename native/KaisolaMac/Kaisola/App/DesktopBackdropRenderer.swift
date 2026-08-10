import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Everything a rendered backdrop depends on, and nothing else.
///
/// The screen is not a component: two displays showing the same desktop render
/// the same picture, and keying on the file dedupes them instead of blurring it
/// twice. `modified` catches "set as desktop picture" over a path that never
/// changed, and `isDark` selects the frame of a dynamic desktop.
struct DesktopBackdropKey: Hashable, Sendable {
    let path: String
    let modified: Date?
    let isDark: Bool
    /// How wide the desktop is, in points — and the one thing about the
    /// *screen* the bake does have to know.
    ///
    /// The still is pinned to desktop coordinates now, so it is stretched
    /// across the whole display rather than across each surface. Its blur is
    /// therefore no longer measurable as a fraction of the picture: the same
    /// fraction is a different number of **points** on a 1512 pt laptop and a
    /// 3440 pt ultrawide, and points are what the eye and the contrast floors
    /// are stated in. See `DesktopBackdropRenderer.desktopBlurPoints`.
    ///
    /// Quantized to 128 pt so that a display which reports a slightly
    /// different width — or a second display close in size — reuses the cached
    /// bake instead of paying for another one.
    let screenPoints: Double

    static func quantized(screenPoints: Double) -> Double {
        max(512, (screenPoints / 128).rounded() * 128)
    }

    /// The two glass settings that change the *bake* rather than the veil over
    /// it, so switching either re-bakes once and then draws from cache like any
    /// other desktop change.
    let texture: GlassTexture
    let colour: GlassColour

    init(
        path: String,
        modified: Date?,
        isDark: Bool,
        screenPoints: Double = 1512,
        texture: GlassTexture = .balanced,
        colour: GlassColour = .balanced
    ) {
        self.path = path
        self.modified = modified
        self.isDark = isDark
        self.screenPoints = Self.quantized(screenPoints: screenPoints)
        self.texture = texture
        self.colour = colour
    }

    var url: URL { URL(fileURLWithPath: path) }
}

/// What a glass surface paints under its veil.
enum DesktopPainting: @unchecked Sendable {
    /// The pre-blurred desktop still, the pixel size of the wallpaper it was
    /// baked from, and the tint sampled from that same decode so a single pass
    /// produces every product.
    ///
    /// The full pixel size travels with the still because the still is a
    /// *thumbnail* — it keeps the wallpaper's aspect but not its size, and
    /// where macOS lays a desktop picture out on a screen depends on the size
    /// for the "Center" and "Tile" fill modes. See `DesktopBackdropGeometry`.
    case wallpaper(CGImage, tint: DesktopTintComponents, wallpaperPixels: CGSize)
    /// No readable still anywhere on the ladder.
    case flat(DesktopTintComponents)

    var tint: DesktopTintComponents {
        switch self {
        case let .wallpaper(_, tint, _): tint
        case let .flat(tint): tint
        }
    }
}

extension DesktopPainting: Equatable {
    static func == (lhs: DesktopPainting, rhs: DesktopPainting) -> Bool {
        switch (lhs, rhs) {
        case let (.wallpaper(lhsImage, lhsTint, lhsSize), .wallpaper(rhsImage, rhsTint, rhsSize)):
            lhsImage === rhsImage && lhsTint == rhsTint && lhsSize == rhsSize
        case let (.flat(lhsTint), .flat(rhsTint)):
            lhsTint == rhsTint
        default:
            false
        }
    }
}

/// Both products of one bake pass: the legibility still every washed surface
/// draws, and the clear still an idle canvas shows instead. They travel
/// together because they are made together — same decode, same working space,
/// same cache entry — so neither can go stale against the other.
struct DesktopBake: @unchecked Sendable {
    let painting: DesktopPainting
    /// `nil` whenever the painting is `.flat` — clear glass over no picture is
    /// the same flat, so there is nothing separate to show.
    let clearStill: CGImage?
}

// MARK: - Where the wallpaper actually is

/// The arithmetic that makes the glass *glass* rather than a picture of the
/// desktop painted onto a panel.
///
/// Until this round every glass surface drew the **whole** baked still
/// stretched to its own shape, so what the sidebar showed bore no relation to
/// the wallpaper actually behind the sidebar — a blurry photograph on a panel,
/// which is exactly why the surface never read as transparent however thin the
/// veil got. Round 2 skipped desktop pinning on the grounds that it would
/// "re-lay out on every window drag"; it does not, because the still is already
/// baked and cached and following a drag is a change of **sampling rectangle**,
/// not a change of pixels.
///
/// What is left is one piece of arithmetic: given where a surface is on a
/// screen, which part of the wallpaper image is under it? That depends on how
/// macOS laid the picture out, which `NSWorkspace.desktopImageOptions(for:)`
/// publishes as an `NSImageScaling` plus an `allowClipping` flag — the two
/// together spelling out aspect-fill, aspect-fit, stretch, centre or tile.
enum DesktopBackdropGeometry {
    /// The two option keys that decide the layout, read with the same defaults
    /// macOS uses when it does not publish them: fill the screen.
    static func layout(from options: [NSWorkspace.DesktopImageOptionKey: Any]?)
        -> (scaling: NSImageScaling, allowsClipping: Bool) {
        let raw = (options?[.imageScaling] as? NSNumber)?.uintValue
        let scaling = raw.flatMap { NSImageScaling(rawValue: $0) } ?? .scaleProportionallyUpOrDown
        let clipping = (options?[.allowClipping] as? NSNumber)?.boolValue ?? true
        return (scaling, clipping)
    }

    /// Where a wallpaper of `imagePixels` lands inside `screen`, in the
    /// screen's own (AppKit, y-up) coordinates.
    ///
    /// For the tiled desktop this is the *first* tile; `contentsRect` walks the
    /// grid from it.
    static func wallpaperFrame(
        imagePixels: CGSize,
        screen: CGRect,
        scaling: NSImageScaling,
        allowsClipping: Bool,
        backingScale: CGFloat
    ) -> CGRect {
        guard imagePixels.width > 0, imagePixels.height > 0,
              screen.width > 0, screen.height > 0
        else { return screen }
        let scale = max(backingScale, 1)
        let natural = CGSize(
            width: imagePixels.width / scale,
            height: imagePixels.height / scale
        )
        let widthRatio = screen.width / natural.width
        let heightRatio = screen.height / natural.height

        let size: CGSize = switch scaling {
        case .scaleAxesIndependently:
            screen.size
        case .scaleNone:
            natural
        case .scaleProportionallyDown:
            natural.scaled(by: min(1, min(widthRatio, heightRatio)))
        case .scaleProportionallyUpOrDown:
            // The pair that spells "Fill Screen" against "Fit to Screen".
            natural.scaled(by: allowsClipping
                ? max(widthRatio, heightRatio)
                : min(widthRatio, heightRatio))
        @unknown default:
            natural.scaled(by: max(widthRatio, heightRatio))
        }
        return CGRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The unit sub-rectangle of the wallpaper image lying behind `surface`.
    ///
    /// **Top-left origin**, because that is `CALayer.contentsRect`'s
    /// convention and a `CGImage`'s, while `surface` and `screen` arrive in
    /// AppKit's y-up coordinates — the flip happens here, once, rather than at
    /// each call site.
    ///
    /// A surface that runs off the wallpaper — a window dragged half off the
    /// screen, or sitting on the letterboxed margin of a "Fit to Screen"
    /// desktop — is **slid back inside at its full size** rather than being
    /// shrunk to the overlap. Shrinking would stretch the visible strip across
    /// the whole surface, which is the one artefact that would read as a bug;
    /// sliding shows the nearest real wallpaper at the correct scale, and the
    /// case only arises where there is no desktop under the glass to be honest
    /// about anyway.
    static func contentsRect(
        surface: CGRect,
        imagePixels: CGSize,
        screen: CGRect,
        scaling: NSImageScaling,
        allowsClipping: Bool,
        backingScale: CGFloat
    ) -> CGRect {
        var frame = wallpaperFrame(
            imagePixels: imagePixels,
            screen: screen,
            scaling: scaling,
            allowsClipping: allowsClipping,
            backingScale: backingScale
        )
        guard frame.width > 0, frame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        // "Tile": the picture repeats from the screen's own origin, so the
        // surface is mapped into whichever copy its centre falls in.
        if scaling == .scaleNone, allowsClipping {
            let column = ((surface.midX - screen.minX) / frame.width).rounded(.down)
            let row = ((surface.midY - screen.minY) / frame.height).rounded(.down)
            frame = CGRect(
                x: screen.minX + column * frame.width,
                y: screen.minY + row * frame.height,
                width: frame.width,
                height: frame.height
            )
        }

        let width = surface.width / frame.width
        let height = surface.height / frame.height
        // AppKit counts y up from the bottom; the image counts it down from the
        // top, so the surface's *top* edge is the sub-rect's origin.
        let left = (surface.minX - frame.minX) / frame.width
        let top = (frame.maxY - surface.maxY) / frame.height
        return CGRect(
            x: width >= 1 ? 0 : min(max(left, 0), 1 - width),
            y: height >= 1 ? 0 : min(max(top, 0), 1 - height),
            width: min(1, width),
            height: min(1, height)
        )
    }
}

private extension CGSize {
    func scaled(by factor: CGFloat) -> CGSize {
        CGSize(width: width * factor, height: height * factor)
    }
}

extension Array where Element == Double {
    /// Index of the first element not less than `value`, on an already-ascending
    /// array — i.e. where `value` has to go to keep it ascending.
    func partitionPoint(before value: Double) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// Turns a desktop still into the small blurred image the glass surfaces draw.
///
/// The blur is baked once, at thumbnail scale, and then stretched over a
/// surface many times wider — not applied live to the window. Blurring 176 px
/// is roughly two orders of magnitude less work than blurring the backing
/// store, and the upscale is a second, free smoothing pass.
enum DesktopBackdropRenderer {
    /// Working resolution of the bake, and the fix for "glass picks up the
    /// colour of the wallpaper but not the **vibe**".
    ///
    /// It was 176. That was ample while the blur was destroying every
    /// mid-frequency in the picture anyway — the still was a colour field, so
    /// how faithfully it sampled the wallpaper's *shapes* did not matter. Once
    /// `blurFraction` lets those shapes through it matters a great deal, and the
    /// measurement is unambiguous. Baking each of this Mac's aerial extremes at
    /// several widths and correlating the result against a 1024px reference,
    /// both reduced to a common 128×128 grid:
    ///
    ///     176 px → 0.841      384 px → 0.910      640 px → 0.975
    ///     256 px → 0.861      448 px → 0.932
    ///
    /// At 176 px **16% of the structure the surface shows is not the
    /// wallpaper's** — it is the thumbnail decode's own aliasing, promoted to
    /// visible texture the moment the blur stopped hiding it. 448 takes that to
    /// 7% for about +2 ms of decode, and the still it caches is 451 KB.
    ///
    /// Resolution is deliberately *not* the lever that produces detail — the
    /// detail metric is flat in it, because what the eye sees is set by the blur
    /// as a size on screen, not by the pixel count. Raising it only buys
    /// fidelity of the structure `desktopBlurPoints` chose to keep.
    ///
    /// 448 → **896** for desktop pinning, and this time the magnification is
    /// the argument rather than the decode. A stretched still was drawn about
    /// 1:2 into a 210 pt sidebar; a pinned one shows the eighth of the
    /// wallpaper behind that sidebar, which at 448 px is 62 source pixels
    /// blown up to 420 backing pixels — 6.8×, where the round-7 correlation
    /// ladder already put 448 px at 7% non-wallpaper structure. 896 halves the
    /// magnification and takes the correlation past the 640 px rung (0.975).
    static let stillWidth = 896

    /// The blur, **in screen points** — the scattering length of the material,
    /// and the constant that decides whether the surface is a colour field or
    /// frosted glass.
    ///
    /// It was a fraction of the still (`blurFraction` 0.05), which was the
    /// right way to state it while every surface showed the whole wallpaper
    /// stretched to its own width: the sidebar was the frame, so 5% of the
    /// frame was 5% of the sidebar. Desktop pinning breaks that identity. A
    /// 210 pt sidebar on a 1512 pt display shows about **an eighth** of the
    /// wallpaper, so 5% of the wallpaper is 36% of the sidebar — one soft wash
    /// end to end, with no texture in it at all. Measured: the structured
    /// fixtures' surface detail fell from 0.0038–0.0058 stretched to
    /// **0.0018–0.0022** pinned, which is below even the pre-round-7 figure the
    /// last round doubled.
    ///
    /// A real frosted material has a fixed scattering length in physical units,
    /// not one that scales with the picture behind it, so that is how it is
    /// stated here. 28 pt is also, not coincidentally, the neighbourhood
    /// AppKit's own behind-window blur works in, so the pinned wallpaper reads
    /// as the same kind of material as the Live source it sits beside.
    ///
    /// The old requirement — "no locatable shape" — is *deliberately* relaxed,
    /// because it was the requirement that made the surface a picture on a
    /// panel. What replaces it is the requirement a glass surface actually
    /// has: no *legible* shape, meaning nothing crisp enough to read text or an
    /// icon through. At 28 pt over a 210 pt sidebar that is about seven soft
    /// masses across — the horizon, the shoreline, the cloud bank — and every
    /// contrast floor in this file still holds on the worst of them.
    static let desktopBlurPoints: Double = 28

    /// Radius in still pixels, for a desktop `screenPoints` wide.
    ///
    /// The still spans the whole display, so still pixels per screen point is
    /// `stillPixels / screenPoints` and the conversion is that ratio.
    ///
    /// `stillPixels` is the width the decode actually produced, not
    /// `stillWidth`: `CGImageSourceCreateThumbnailAtIndex` treats its maximum
    /// as a **maximum**, so a wallpaper smaller than `stillWidth` comes back at
    /// its own size, and using the declared width there would blur a small
    /// picture by the wrong number of points.
    static func blurRadius(
        screenPoints: Double,
        stillPixels: Int = stillWidth,
        blurPoints: Double = desktopBlurPoints
    ) -> Double {
        Double(stillPixels) * blurPoints / max(screenPoints, 1)
    }

    /// The legacy fraction-of-the-frame statement of the same blur, kept
    /// because the "does it still blur past anything legible" test is naturally
    /// stated in it.
    ///
    /// It was 28 px on a 176 px still: **15.9%** of the frame. That is a blur
    /// wide enough to reduce any wallpaper to about six distinguishable masses
    /// across its whole width, which is why the shipped surface measured
    /// `spread ≈ gradient` on every fixture — *all* of its luminance range was
    /// the veil's own top-to-bottom gradient and none of it was the picture.
    /// Michael's note is exactly that distinction: "glass wallpaper should pick
    /// up the **vibe** of the wallpaper as well, like **washed details**".
    ///
    /// 5% leaves roughly twenty masses across the frame: a horizon, a shoreline,
    /// the shape of a cloud bank read as soft washes, with nothing identifiable.
    /// The old note's requirement — "no locatable shape" — is kept; what changes
    /// is that "no locatable shape" and "no shape at all" turn out to be two
    /// different radii, and the bake had been sitting on the second one.
    ///
    /// Lowering this alone would be the regression the previous three rounds
    /// each fixed a version of: more range reaching the veil is exactly what the
    /// contrast floors cannot afford. It is affordable here only because the cap
    /// underneath it moved from a *proxy* to the real quantity — see
    /// `tailHeadroom(isDark:)`.
    /// The share of a **surface** — not of the wallpaper — the blur covers, on
    /// the narrowest glass surface in the app (a 210 pt sidebar). This is the
    /// quantity "no legible shape" is really about, and it is now stated where
    /// it is true rather than where it happened to be equal to it.
    static var blurShareOfNarrowestSurface: Double { desktopBlurPoints / 210 }

    /// A local-contrast add-back, applied to the blurred still before the tone
    /// map — the "compress the global range, keep the local one" half of the
    /// change stated as one filter.
    ///
    /// An unsharp mask adds `intensity × (image − blur(image))`: a **zero-mean**
    /// mid-frequency residual. It therefore raises the contrast *within* a
    /// neighbourhood without moving the still's mean, and what it does move —
    /// the extremes — is measured immediately afterwards and paid for by the
    /// gain. So this cannot smuggle range past the legibility cap; it can only
    /// change how that range is spent, which is the whole point.
    ///
    /// The radius is set relative to the blur so the band restored is the one
    /// just above what the blur removed rather than a fixed pixel size that
    /// would mean something different at every `stillWidth`.
    ///
    /// **1.2**, doubled from 0.6.
    ///
    /// 0.6 left the composite's luminance spread at about 0.095 on a real
    /// desktop — structure that is mathematically present and invisible in
    /// practice, which is why the canvas read as flat paint even in Crisp.
    /// Michael: "the glass totally erases all the details/texture of the
    /// wallpaper, even on crisp/clear mode."
    ///
    /// The bound above is unchanged and still governs: past ~1.8 the upscale to
    /// the surface starts ringing, and the measured dark worst patch drops to
    /// 4.32 — *below* the 4.5 floor. Two things are worth stating plainly about
    /// that number. It is not what the still-side cap measures, because the
    /// overshoot is created by the interpolation rather than by the bake; and
    /// the 120-test suite passes at 1.8 for exactly that reason. Passing tests
    /// are therefore **not** evidence of safety here, so this sits at two
    /// thirds of the documented edge rather than against it.
    static let localContrastRadiusFactor: Double = 1.4
    static let localContrastIntensity: Double = 1.2
    /// A slight saturation *cut*.
    ///
    /// This was 1.3, from the era when a heavy veil ate most of the desktop's
    /// chroma and the bake had to shout to be heard through it. Under a 0.60
    /// veil it inverted: the sidebar measured a 0.53 peak channel spread
    /// against the raw desktop's 0.33 — Kaisola's "glass" was more saturated
    /// than the wallpaper it was imitating, which is precisely what made it
    /// read as a photograph. 1.0 was the correction, and it landed the
    /// composite at the wallpaper's own chroma.
    ///
    /// v1.1.8 takes one more step down, to 0.85. The remaining complaint was
    /// not that the surface was *bright* but that it was **colourful** —
    /// whatever hue the desktop happened to carry arrived at full strength and
    /// the chrome changed personality with the wallpaper. Damping the still's
    /// chroma by 15% keeps the desktop legibly present while moving the surface
    /// toward a material of its own, and the warmth it loses is put back
    /// deliberately and in one known hue by `GlassWarmth` rather than being
    /// borrowed from whatever picture is on the desktop.
    ///
    /// This is now the *ceiling* rather than the value: see
    /// `saturation(mean:isDark:)`, which is where the dark cast was.
    static let saturationCeiling: Double = 0.85

    /// The ceiling for **dark**, which is a different number for a reason that
    /// is not taste.
    ///
    /// Chroma and luminance are not independent to the eye at near-black. The
    /// dark still is normalized to 0.16 and sits under a veil that passes ~45%
    /// of it, so the composite's total luminance is ~0.10 — and against a mean
    /// that small, a channel difference the light surface would not notice is
    /// most of what the surface *is*. Measured against Michael's own desktop
    /// (a Lake Tahoe aerial, off-neutral 0.399) with the bake rendering
    /// correctly, the dark sidebar came back **0.221** off-neutral against
    /// light's 0.059 on the identical wallpaper. Same picture, same veil
    /// arithmetic, 3.7× the cast — which is what "still reads a little
    /// blue/purple" is.
    ///
    /// Damping the dark still's chroma to 0.50 takes that to **0.129** while
    /// leaving the surface's luminance spread untouched at 0.083 (0.0785 →
    /// 0.0785 across the sweep — chroma and structure are separable here even
    /// though chroma and *brightness* are not). That is the property that makes
    /// this the right lever for the cast rather than a lever that greys the
    /// wallpaper out: the wallpaper's light and shade all survive; only how
    /// loudly it is coloured moves. Across the five most extreme wallpapers on
    /// this machine the dark composite's off-neutrality drops from 0.003–1.181
    /// to 0.009–0.330 — the surface stops changing personality with the desktop.
    ///
    /// Light keeps 0.85. When light's turn came the ask was translucency rather
    /// than cast, and the light composite was measured at 0.057 off-neutral
    /// against dark's 0.165 — a light surface at 0.85 luminance has the headroom
    /// to carry the desktop's hue at full strength and does not read as coloured
    /// when it does. Thinning the light veil raises that to 0.083, which is
    /// still half of dark's, so the ceiling did not have to move with it.
    static let darkSaturationCeiling: Double = 0.50

    static func saturationCeiling(isDark: Bool) -> Double {
        isDark ? darkSaturationCeiling : saturationCeiling
    }

    /// The chroma that actually reaches a baked still — and the fix for
    /// "the background in dark mode looks… purple/blue".
    ///
    /// The bake normalized luminance and left chroma alone, and those two
    /// cannot be separated at near-black. `CIColorControls.brightness` is a
    /// straight per-channel offset (that is exactly why `luminanceShift` uses
    /// it), so it preserves the still's **absolute** channel differences while
    /// moving its mean. In light that is harmless: the still is lifted to 0.72
    /// and the same absolute spread is a small fraction of it. In dark the
    /// still is crushed to 0.16 and the identical spread becomes most of the
    /// surface.
    ///
    /// Measured end to end against the real desktop (an Aerial still, average
    /// rgb 0.263/0.476/0.576, so a genuinely blue picture), using the *same*
    /// relative measure `testDeclaredNeutralConstantsAreAchromatic` applies to
    /// anything this app calls neutral — the largest per-channel departure from
    /// the mean, over the mean:
    ///
    ///     light sidebar composite  0.834/0.898/0.927 → 0.059 off-neutral
    ///     dark  sidebar composite  0.055/0.114/0.143 → 0.473 off-neutral
    ///
    /// The dark surface was 8× further from neutral than the light one, and —
    /// the part that makes it a bug rather than a taste — **further from
    /// neutral than the desktop it was sampling** (0.400). That is the same
    /// failure the v1.1.8 note describes for the sidebar, surviving in dark
    /// only: glass more colourful than the wallpaper it imitates.
    ///
    /// So chroma is normalized the way luminance already is. Scaling the
    /// still's saturation by `target / mean` keeps its chroma the same
    /// *fraction* of its luminance that the desktop's chroma was of the
    /// desktop's, which makes the composite's off-neutrality a roughly fixed
    /// multiple of the desktop's own whatever the desktop is: **1.0–1.3×
    /// before, 0.5–0.7× after**. The measured dark composite becomes
    /// 0.078/0.106/0.119 — 0.229 off-neutral, cool but no longer coloured, and
    /// with red back at 65% of blue instead of 38%. Light is unchanged for
    /// every wallpaper dimmer than the 0.72 target, which is nearly all of them.
    /// `gain` is divided back out because `CIColorControls`' contrast scales
    /// channel *differences* along with the luminance range — see
    /// `rangeGain(spread:isDark:)`. Without this the range cap would damp the
    /// wallpaper's colour as a side effect of damping its dynamic range, which
    /// is the one thing the whole layer exists to show.
    /// **Round 8 note.** `saturation`, `luminanceShift` and `tailGain` are no
    /// longer on the bake's path: all three are now *solved* against the
    /// rendered structure in a perceptual space rather than computed from
    /// Rec. 709 luma — see `solveToneMap(probe:isDark:)`, and
    /// `Oklab` for why measuring lightness as luma is what produced
    /// "on blue wallpaper it becomes white and on green wallpaper it's very
    /// green". They are retained because they *are* the round-7 pipeline, which
    /// the hue-invariance test freezes and measures against, and because
    /// `targetLuminance` and `tailHeadroom` still define the targets the solve
    /// aims at. Nothing new should be built on them.
    static func saturation(mean: Double, isDark: Bool, gain: Double = 1) -> Double {
        let target = targetLuminance(isDark: isDark)
        return saturationCeiling(isDark: isDark)
            * min(1, target / max(mean, 0.02))
            / max(gain, 0.05)
    }

    /// The widest luminance range a **dark** baked still may carry, p5..p95 of
    /// the 16×16 box reduction — and the constant that lets the dark veil get
    /// out of the way.
    ///
    /// Michael's ask was "dark glass could look more glassy/translucent…
    /// especially on live and wallpaper". The veil is the obvious lever and it
    /// was already the binding one: at the shipped 0.52 base, the *worst patch*
    /// of the most extreme wallpaper in this Mac's aerial library (`AB7FC3C3`,
    /// luma 0.435 — a bright sky over dark ground, box spread **0.615**, 1.7×
    /// the next widest) measured **4.6:1** secondary contrast against a 4.5
    /// floor. There was no room to thin anything.
    ///
    /// The reason is that the bake normalized the still's *mean* and left its
    /// *range* alone, so how bright the brightest patch of the sidebar got was
    /// still a function of the user's desktop — the exact dependency
    /// `targetLuminance` exists to remove, surviving in the second moment.
    /// `CIColorControls`' contrast is a gain about 0.5, so solving it together
    /// with the brightness offset removes it: the still's range is capped, its
    /// mean still lands on target, and the surface's worst case stops depending
    /// on the picture.
    ///
    /// Dark sidebar, worst-patch (brightest 2% band) secondary contrast against
    /// a 4.5 floor, measured by rendering:
    ///
    ///     veil 0.52, no cap    4.6 : 1   ← shipped; already at the floor
    ///     veil 0.34, no cap    3.9 : 1   ← thinning the veil alone fails
    ///     veil 0.34, cap 0.30  4.9 : 1   ← shipped here
    ///
    /// The cap does more for the worst case than the veil it buys out, which is
    /// why the surface can be a third more transparent *and* better on its worst
    /// wallpaper at the same time.
    ///
    /// The gain is computed from the *unblurred* box, which over-states what
    /// actually reaches the veil — radius 28 on a 176px still smooths most of a
    /// photograph's range away, so the cap is deliberately conservative. What it
    /// does in practice, over the five extremes of this Mac's 156-still aerial
    /// library and with the thinner veil above: the composite's luminance spread
    /// **rises** on four of them (0.086 → 0.095 on Michael's own desktop, 0.064 →
    /// 0.081 on the brightest, 0.022 → 0.034 on the darkest) and **falls** on the
    /// one whose range was the problem (0.197 → 0.158). That asymmetry is the
    /// whole design: more wallpaper everywhere, less of the one thing that was
    /// making the worst case a function of the desktop.
    ///
    /// Light got the same cap one round later, for the same reason — see
    /// `lightStillSpreadCeiling`.
    static let darkStillSpreadCeiling: Double = 0.30

    /// The same bound for **light**, and the constant that lets the light veil
    /// get out of the way.
    ///
    /// Round 3 left light alone on the argument that a 0.72 surface has the
    /// headroom and light was never the complaint. It is the complaint now —
    /// "light mode should also be translucent to wallpaper much better" — and
    /// rendering the light surface says the headroom was never really there:
    /// with the shipped 0.60 veil the *worst patch* of an adversarial ramp
    /// measured **7.27:1** primary against a 7.0 floor, so thinning the light
    /// veil by even a step took primary below the floor. Light was closer to its
    /// limit than dark ever was; it merely had no test looking.
    ///
    /// The cap is the same lever and it does the same work, mirrored. In light
    /// the worst patch is the *darkest* pixel, and the bake's linear map is
    /// `out = (in - mean)·gain + target`, so a gain below 1 lifts the darkest
    /// patch toward the target — exactly the patch the floor is measured on.
    ///
    /// It also fixes a second thing that was wrong on its own terms. The light
    /// bake is the mirror of the dark black-crush `bakeColorSpace` describes,
    /// in a milder form: normalizing a dim wallpaper *up* to 0.72 pushes its
    /// highlights past 1. Rendered against this Mac's aerial library, the
    /// widest-range still arrived with **17.3%** of its pixels clipped, and an
    /// adversarial full-range ramp with **19.1% blown to flat white** — range
    /// the surface could not show however thin the veil got. With the cap both
    /// are **0.0%**.
    ///
    /// Light sidebar/workspace, worst-patch contrast over the five extremes of
    /// this Mac's aerial library plus four blur-invariant ramp fixtures:
    ///
    ///     veil 0.60, no cap    P 9.08 / 7.27   S 3.43 / 3.17   ← shipped
    ///     veil 0.45, no cap    P 7.49 / 5.9    S 3.20 / 2.9    ← veil alone fails
    ///     veil 0.45, cap 0.26  P 9.05 / 8.88   S 3.43 / 3.40   ← shipped here
    ///
    /// **0.26 rather than dark's 0.30** because light's contrast budget is far
    /// tighter: black ink on a near-white surface tops out at 3.98:1 for the
    /// secondary role whatever the surface does (see
    /// `GlassBackdropWash.sidebar(isDark:)`), so every point of transmission
    /// costs more of what little margin there is. 0.26 is the value at which the
    /// worst-patch secondary returns exactly to its pre-change figure at the
    /// chosen veil — the honest stopping point, not a round number.
    static let lightStillSpreadCeiling: Double = 0.26

    /// The widest luminance range a baked still may carry, per appearance.
    ///
    /// Retained as the *declared* bound the two veil ceilings are priced
    /// against; the gain is no longer solved from it. See
    /// `tailHeadroom(isDark:)` for what replaced it and why.
    static func stillSpreadCeiling(isDark: Bool) -> Double {
        isDark ? darkStillSpreadCeiling : lightStillSpreadCeiling
    }

    /// How far above (dark) or below (light) `targetLuminance` the baked still's
    /// **worst patch** may sit — and the constant that makes room for the
    /// texture without spending a point of legibility.
    ///
    /// The p5..p95 cap this replaces was a *proxy*. Every contrast floor in this
    /// file is measured on the worst patch — the mean of the brightest 2% of the
    /// surface in dark, the darkest 2% in light — and a percentile band by
    /// construction says nothing about the tail outside it. Rendering the
    /// shipped pipeline over this Mac's aerial extremes and the ramp fixtures
    /// shows how loose the proxy was: the still's tail excursion ranged from
    /// 0.027 to **0.151** while every one of those stills sat inside the 0.30
    /// p5..p95 ceiling. The worst wallpaper on the machine (`A92E4A3F`, box
    /// spread 0.856) landed at 4.52:1 secondary against the 4.5 floor — the
    /// margin was **0.02**, and nothing in the bake knew.
    ///
    /// Capping the tail instead is both exact and one division. The tone map is
    /// affine — `out = (in − mean)·gain + target` — so
    ///
    ///     out(tail) − target = (tail − mean) · gain
    ///
    /// and bounding the left side is solving for the gain directly:
    /// `gain = min(1, headroom / |tail − mean|)`. The quantity the floor is
    /// stated in is now the quantity the bake controls, for every wallpaper
    /// rather than for the p5..p95 of one.
    ///
    /// **0.145 dark / 0.124 light** are the shipped pipeline's own worst
    /// excursions (0.151 and 0.131), taken a step under. So the surface's worst
    /// case cannot be worse than the worst case that already shipped — and for
    /// every *other* wallpaper it is now bounded by the same number instead of
    /// being left wherever the picture happened to put it. Measured across the
    /// six real aerial extremes and the six ramp fixtures, on both surfaces, the
    /// worst patch improves in both appearances: dark 4.52 → **4.55**, light
    /// 3.43 → **3.44**, primary 8.29 → **8.38** and 9.05 → **9.16**.
    ///
    /// That is what pays for `blurFraction`. Three rounds in a row found that
    /// letting more of the wallpaper through costs contrast the floors do not
    /// have; this one tightens the cap onto the exact quantity at issue first,
    /// and spends the slack on structure.
    static let darkTailHeadroom: Double = 0.145
    static let lightTailHeadroom: Double = 0.124

    static func tailHeadroom(isDark: Bool) -> Double {
        isDark ? darkTailHeadroom : lightTailHeadroom
    }

    /// The gain `CIColorControls.contrast` is set to, from the distance between
    /// the baked structure's mean and its worst patch. Never above 1: a
    /// wallpaper whose worst patch is already inside the headroom is passed
    /// through exactly as it was, so this only ever *removes* an excess and can
    /// never manufacture contrast the desktop does not have.
    static func tailGain(excursion: Double, isDark: Bool) -> Double {
        min(1, tailHeadroom(isDark: isDark) / max(excursion, 0.001))
    }

    /// Mean luminance the baked still is moved to, per appearance.
    ///
    /// `NSVisualEffectView` normalized luminance for us; a raw wallpaper does
    /// not, so before this the legibility of every label in the app was a
    /// function of the user's desktop picture — a white wallpaper in dark mode
    /// put tertiary text on a pale surface. Normalizing here makes the veil's
    /// coverage arithmetic land on known ground for *any* desktop: the still
    /// always arrives at these luminances, so the composite always lands near
    /// 0.60·1.0 + 0.40·0.72 ≈ 0.89 in light and 0.60·0.05 + 0.40·0.16 ≈ 0.09 in
    /// dark. The wallpaper still supplies hue and its large-scale gradient; it
    /// no longer supplies brightness.
    static func targetLuminance(isDark: Bool) -> Double { isDark ? 0.16 : 0.72 }

    /// The additive shift that moves a still of mean luminance `mean` onto
    /// `targetLuminance`.
    ///
    /// Additive rather than multiplicative on purpose. `CIColorControls`'
    /// brightness is a straight per-channel offset, so it moves mean luminance
    /// by exactly this amount while leaving every channel *difference* — the
    /// hue and the chroma spread the frost exists to show — untouched. An
    /// exposure step would scale chroma along with brightness and make a dark
    /// wallpaper's tint vanish in light mode. Clamped only to keep a degenerate
    /// decode (a fully black or blown-out still) from inverting into a shift
    /// larger than the range it is correcting; inside the clamp the
    /// normalization is exact.
    ///
    /// `gain` is the range cap's contrast, and it has to be solved *with* the
    /// offset rather than before it. Measured on the real filter (see
    /// `rangeGain(spread:isDark:)`), `CIColorControls` evaluates saturation,
    /// then contrast about **0.5**, then brightness — so a gain below 1 has
    /// already moved the mean to `(mean - 0.5) · gain + 0.5` by the time this
    /// offset lands, and normalizing against the raw mean would miss by
    /// `(0.5 - mean) · (1 - gain)`. At gain 1 this is the identical expression
    /// it always was.
    static func luminanceShift(mean: Double, isDark: Bool, gain: Double = 1) -> Double {
        let pivoted = (mean - 0.5) * gain + 0.5
        return min(0.9, max(-0.9, targetLuminance(isDark: isDark) - pivoted))
    }

    /// Dynamic desktops pack every hour of the day into one HEIC with nothing
    /// in the container labelling the frames; the day frames lead and the night
    /// frames trail, so each appearance takes the end nearest to it.
    static func frameIndex(imageCount: Int, isDark: Bool) -> Int {
        guard imageCount > 1 else { return 0 }
        return isDark ? imageCount - 1 : 0
    }

    static func render(key: DesktopBackdropKey) -> DesktopPainting? {
        renderBake(key: key)?.painting
    }

    static func renderBake(key: DesktopBackdropKey) -> DesktopBake? {
        guard let source = CGImageSourceCreateWithURL(key.url as CFURL, nil) else { return nil }
        let index = frameIndex(imageCount: CGImageSourceGetCount(source), isDark: key.isDark)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: stillWidth,
        ]
        guard let still = CGImageSourceCreateThumbnailAtIndex(
            source,
            index,
            options as CFDictionary
        ) else { return nil }

        // The tint is the wallpaper's own average and so is read from the raw
        // thumbnail, unchanged.
        let tint = DesktopTintSampler.pixels(image: still)
            .flatMap { DesktopTintSampler.wallpaperAverage(rgba: $0) }
            ?? DesktopTintSampler.fallback
        guard let blurred = blur(
            still,
            isDark: key.isDark,
            screenPoints: key.screenPoints,
            texture: key.texture,
            colour: key.colour
        ) else { return DesktopBake(painting: .flat(tint), clearStill: nil) }
        // The wallpaper's own pixel size, not the thumbnail's — the layout the
        // glass is pinned to depends on it for the centred and tiled desktops.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let pixels = CGSize(
            width: (properties?[kCGImagePropertyPixelWidth] as? Int).map(CGFloat.init)
                ?? CGFloat(blurred.width),
            height: (properties?[kCGImagePropertyPixelHeight] as? Int).map(CGFloat.init)
                ?? CGFloat(blurred.height)
        )
        return DesktopBake(
            painting: .wallpaper(blurred, tint: tint, wallpaperPixels: pixels),
            clearStill: clearBlur(still, screenPoints: key.screenPoints, texture: key.texture)
        )
    }

    /// The wallpaper through *clear* glass: the same still, blurred at the
    /// texture's own scattering length — and nothing else.
    ///
    /// The legibility bake exists so labels can sit on the surface, and every
    /// stage of it trades fidelity for that: the tone map normalizes the
    /// still's brightness onto a target, the tail cap compresses its range, and
    /// the saturation ceiling damps its chroma. An **idle** canvas carries no
    /// labels, so it does not owe those guarantees — and paying for them anyway
    /// is exactly why "translucent to the wallpaper" was impossible before:
    /// however thin the veil got, what it revealed was a managed picture, not
    /// the desktop. Michael: "when nothing is on the canvas [it] should be
    /// transluscent to the wallpaper".
    ///
    /// No local-contrast add-back either: unsharp exists to restore what the
    /// legibility pipeline's compression takes away, and nothing here
    /// compressed. The blur still runs clamped-then-cropped so the corners do
    /// not vignette, and in the same working space as the main bake so the two
    /// stills a crossfade passes through are colour-managed identically.
    /// The clear still's one departure from raw: a declared chroma damp,
    /// linear about luma (the same `BakeToneMap` shape the legibility bake
    /// uses, saturation-only), so the idle canvas reads as glass over the
    /// wallpaper rather than the wallpaper at poster strength — "less
    /// saturated, still detailed". Structure is untouched: no tone map, no
    /// range cap, no local-contrast pass.
    static let clearStillSaturation: Double = 0.75

    private static func clearBlur(
        _ image: CGImage,
        screenPoints: Double,
        texture: GlassTexture
    ) -> CGImage? {
        let radius = blurRadius(
            screenPoints: screenPoints,
            stillPixels: image.width,
            blurPoints: texture.blurPoints
        )
        let input = CIImage(cgImage: image)
        var options: [CIContextOption: Any] = [.useSoftwareRenderer: false]
        if let bakeColorSpace { options[.workingColorSpace] = bakeColorSpace }
        let context = CIContext(options: options)
        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = input.clampedToExtent()
        gaussian.radius = Float(radius)
        guard let softened = gaussian.outputImage else { return nil }
        let vectors = BakeToneMap(
            saturation: clearStillSaturation,
            gain: 1,
            offset: 0
        ).matrix
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = softened
        matrix.rVector = vectors.red
        matrix.gVector = vectors.green
        matrix.bVector = vectors.blue
        matrix.aVector = vectors.alpha
        matrix.biasVector = vectors.bias
        guard let output = matrix.outputImage else { return nil }
        return context.createCGImage(output, from: input.extent)
    }

    /// The colour space the bake's arithmetic is done in, and the fix for
    /// "the dark glass still reads flat".
    ///
    /// `CIContext` colour-manages by default: its working space is **linear**
    /// sRGB, so every filter operates on linearized values. `luminanceShift` is
    /// measured in the opposite space — `DesktopTintSampler.meanLuminance` reads
    /// a `CGContext` raster in `DeviceRGB`, i.e. gamma-**encoded** bytes. The
    /// bake was therefore subtracting an encoded quantity from linear values.
    ///
    /// It is not a rounding error. For Michael's own desktop the encoded mean is
    /// 0.438 and the shift is −0.278, but that still's *linear* mean is 0.17, so
    /// the offset drove the whole image past zero: the rendered dark still came
    /// back **79.7% pure black**, mean luminance **0.0021** against the 0.16 it
    /// declares. The dark surface was a veil over black — a single flat colour
    /// with a 0.010 luminance spread across the entire sidebar. That is the
    /// flatness, and no amount of veil tuning could have reached it, because
    /// there was nothing underneath the veil to let through.
    ///
    /// (Light suffered the mirror version and got away with it. Adding 0.282 in
    /// linear space then re-encoding happens to land near the 0.72 target, so
    /// light merely lost structure — spread 0.039 where the same constants in
    /// the measured space give 0.063 — rather than losing the picture.)
    ///
    /// Doing the arithmetic where it was measured fixes both: the dark still
    /// arrives at mean 0.153 with 2.1% black and a 0.167 spread, and the
    /// composite lands on 0.089/0.105/0.112 — which is, to three decimals, the
    /// surface v1.1.9's constants were *designed* to produce and modelled as
    /// producing. The constants were right; they were being evaluated in the
    /// wrong space.
    ///
    /// sRGB rather than `NSNull` (which would disable colour management
    /// entirely): a Display P3 or HDR wallpaper must still be converted before
    /// its bytes are treated as sRGB, or a wide-gamut desktop would bake with
    /// the wrong primaries. This asks for management *into the space the
    /// measurement is taken in*, which is the actual requirement.
    ///
    /// The cost is that the Gaussian is no longer a physically linear blur.
    /// Blurring in the encoded space is slightly "darker" through high-contrast
    /// edges — irrelevant at radius 28 on a 176px still whose whole job is to
    /// stop being a picture, and the same trade every design tool makes by
    /// default.
    static var bakeColorSpace: CGColorSpace? {
        CGColorSpace(name: CGColorSpace.sRGB)
    }

    /// Structure first, then measure, then tone-map.
    ///
    /// The order is the change. The bake used to solve its gain and offset from
    /// a 16×16 box of the *source* thumbnail and then apply them blind, which
    /// meant every constant was stated about a picture the veil never actually
    /// saw — a proxy two blurs removed from the surface. It now builds the
    /// structure it intends to show, renders that once, measures the two
    /// quantities the guarantees are written in (its mean, and its worst patch),
    /// and solves the tone map against those. The normalization stops being an
    /// estimate and becomes arithmetic.
    ///
    /// `clampedToExtent` before the blur, cropped back after: without it the
    /// Gaussian averages in transparent black at every edge and the backdrop
    /// arrives with a dark vignette exactly where the window's corners are.
    private static func blur(
        _ image: CGImage,
        isDark: Bool,
        screenPoints: Double,
        texture: GlassTexture,
        colour: GlassColour
    ) -> CGImage? {
        let radius = blurRadius(
            screenPoints: screenPoints,
            stillPixels: image.width,
            blurPoints: texture.blurPoints
        )
        let input = CIImage(cgImage: image)
        let extent = input.extent

        var options: [CIContextOption: Any] = [.useSoftwareRenderer: false]
        // See `bakeColorSpace`. Falls through to the default working space only
        // if the system cannot vend sRGB, which is the pre-v1.1.10 behaviour —
        // degraded, not broken.
        if let bakeColorSpace { options[.workingColorSpace] = bakeColorSpace }
        let context = CIContext(options: options)

        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = input.clampedToExtent()
        gaussian.radius = Float(radius)
        guard let softened = gaussian.outputImage else { return nil }

        // The local-contrast add-back. Zero-mean by construction, so it changes
        // how the still's range is distributed and not how much of it there is —
        // and whatever it does to the extremes is measured on the very next
        // line and paid for by the gain.
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = softened
        unsharp.radius = Float(radius * localContrastRadiusFactor)
        unsharp.intensity = Float(localContrastIntensity)
        guard let structured = unsharp.outputImage,
              let probe = context.createCGImage(structured, from: extent),
              let sampled = DesktopTintSampler.pixels(image: probe, side: probeSide)
        else { return nil }

        // Lightness, range and chroma are solved together against the probe,
        // in a perceptual space, by applying the candidate map and measuring
        // what it did. All three still ride **one** filter pass — see
        // `BakeToneMap` for the map and `solveToneMap` for why it is solved by
        // measurement rather than by formula.
        let map = solveToneMap(probe: sampled, isDark: isDark, chromaScale: colour.chromaScale)
        let vectors = map.matrix
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = structured
        matrix.rVector = vectors.red
        matrix.gVector = vectors.green
        matrix.bVector = vectors.blue
        matrix.aVector = vectors.alpha
        matrix.biasVector = vectors.bias
        guard let output = matrix.outputImage else { return nil }
        return context.createCGImage(output, from: extent)
    }

    /// Side of the square reduction the bake measures its own structure on.
    ///
    /// 96 rather than the tint's 16: the worst patch is a 2% tail, and 256
    /// samples put only five pixels in it — enough for a mean but not for a
    /// stable one. 9216 samples put 184 there. It is also fine enough to still
    /// contain the mid-frequency band `blurFraction` keeps, which a 16×16
    /// reduction averages away completely — measuring the tail on that box would
    /// reintroduce exactly the proxy this replaced.
    static let probeSide = 96
}

// MARK: - A tone map that does not care which hue carries the light

/// Perceived lightness and colourfulness, and the fix for "the saturation is
/// bizarre — on blue wallpaper it becomes white and on green wallpaper it's
/// very green".
///
/// Every lightness in the bake used to be **Rec. 709 luma**, which weights
/// green 9.9× blue (`0.7152` against `0.0722`). Measured on a fixture family
/// that is identical in HSV value and saturation and differs only in hue, that
/// one choice reads four equally-bright pictures as:
///
///     blue 0.2415   red 0.2047   green 0.3932   neutral 0.5000
///
/// — a **2.4× spread in "brightness" from pictures that are equally bright by
/// construction**. Everything downstream then diverges: `luminanceShift` is a
/// per-channel *offset*, so the blue picture is handed +0.48 of flat grey and
/// the green one +0.33; and the offset is exactly the operation that destroys
/// saturation, because adding a constant to `(0.125, 0.29, 0.5)` walks it
/// toward white while adding a smaller constant to `(0.125, 0.5, 0.125)`
/// barely touches it. The rendered light sidebar over that family measured
/// Oklab saturation **0.036 blue against 0.083 green — 2.3×** — which is
/// "blue becomes white, green stays very green", in numbers.
///
/// Oklab is the replacement because it is a *perceptual* lightness: the same
/// family reads 0.384 / 0.400 / 0.525 / 0.598, and — the property that makes
/// the whole thing work — its **chroma-to-lightness ratio is very nearly
/// hue-invariant** for that family (0.298 / 0.326 / 0.300 / 0.000), where
/// Rec. 709 luma has no such property at all.
enum Oklab {
    /// Oklab `L*`, `a`, `b` from gamma-encoded sRGB — the space the bake's
    /// probe is read in (see `DesktopBackdropRenderer.bakeColorSpace`).
    static func components(red: Double, green: Double, blue: Double)
        -> (lightness: Double, a: Double, b: Double) {
        let r = linear(red)
        let g = linear(green)
        let b = linear(blue)
        let long = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let medium = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let short = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            lightness: 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            a: 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
            b: 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
        )
    }

    static func lightness(red: Double, green: Double, blue: Double) -> Double {
        components(red: red, green: green, blue: blue).lightness
    }

    /// Colourfulness relative to lightness — the perceptual analogue of HSV
    /// saturation, and the quantity "it becomes white" and "it is very green"
    /// are the two halves of.
    static func saturation(red: Double, green: Double, blue: Double) -> Double {
        let parts = components(red: red, green: green, blue: blue)
        return (parts.a * parts.a + parts.b * parts.b).squareRoot()
            / max(parts.lightness, 0.001)
    }

    /// The gamma-encoded grey that has a given `L*`.
    ///
    /// For a neutral colour the three cube roots are equal and the `L*`
    /// coefficients sum to 1, so `L* = cbrt(linear)` exactly — which makes the
    /// inverse a cube and one sRGB encode. This is what lets the solve state
    /// its lightness correction as an ordinary offset in the space the filter
    /// works in, while the quantity it is correcting is perceptual.
    static func grey(lightness: Double) -> Double {
        encoded(max(0, lightness) * max(0, lightness) * max(0, lightness))
    }

    static func linear(_ channel: Double) -> Double {
        let value = min(1, max(0, channel))
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// `linear(_:)` as a table, because the solve evaluates it a quarter of a
    /// million times and `pow` is most of what that costs.
    ///
    /// 4096 entries with linear interpolation between them: the transfer curve
    /// has no feature narrower than a table step, so the worst interpolation
    /// error is under 2×10⁻⁸ — five orders of magnitude below anything the
    /// solve's tolerances care about, and the exact function is what every
    /// *assertion* still uses.
    static func makeLinearTable() -> [Double] {
        (0...4096).map { linear(Double($0) / 4096) }
    }

    static func tabulatedLinear(_ channel: Double, table: [Double]) -> Double {
        let position = min(1, max(0, channel)) * 4096
        let index = Int(position)
        guard index < 4096 else { return table[4096] }
        let fraction = position - Double(index)
        return table[index] + (table[index + 1] - table[index]) * fraction
    }

    static func encoded(_ channel: Double) -> Double {
        let value = min(1, max(0, channel))
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}

/// The one linear map the bake applies to its structured still, stated in full.
///
/// `out = (luma + (in − luma) · saturation) · gain + offset`, per channel, in
/// the bake's working space. It replaces `CIColorControls` — not because that
/// filter was wrong, but because the solve below has to evaluate this map in
/// software thousands of times, and a map whose exact form is *declared here*
/// can be modelled exactly, where the filter's internal luma weights and
/// operation order could only be inferred. (Round 3 had to measure that order
/// on the real filter to get the offset right; this removes the need.)
///
/// One `CIColorMatrix` is the same single filter pass `CIColorControls` was, so
/// nothing about the bake's cost changes.
struct BakeToneMap: Equatable, Sendable {
    /// Chroma scale about each pixel's own luma.
    var saturation: Double
    /// Range gain — never above 1, so the map can only ever *remove* contrast.
    var gain: Double
    /// The flat offset that lands the still's mean on its target lightness.
    var offset: Double

    /// The luma the saturation term mixes about. Rec. 709 here is not the bug
    /// this round fixes: as a *chroma axis* it is standard and harmless, and
    /// the solve measures what it actually did to the result rather than
    /// assuming. The bug was using it as a **lightness**.
    static let lumaWeights = (red: 0.2126, green: 0.7152, blue: 0.0722)

    func apply(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let luma = Self.lumaWeights.red * red
            + Self.lumaWeights.green * green
            + Self.lumaWeights.blue * blue
        func channel(_ value: Double) -> Double {
            min(1, max(0, (luma + (value - luma) * saturation) * gain + offset))
        }
        return (channel(red), channel(green), channel(blue))
    }

    /// The same map as `CIColorMatrix`'s five vectors.
    var matrix: (
        red: CIVector, green: CIVector, blue: CIVector, alpha: CIVector, bias: CIVector
    ) {
        let mix = gain * (1 - saturation)
        let keep = gain * saturation
        let weights = Self.lumaWeights
        return (
            red: CIVector(
                x: CGFloat(keep + mix * weights.red),
                y: CGFloat(mix * weights.green),
                z: CGFloat(mix * weights.blue),
                w: 0
            ),
            green: CIVector(
                x: CGFloat(mix * weights.red),
                y: CGFloat(keep + mix * weights.green),
                z: CGFloat(mix * weights.blue),
                w: 0
            ),
            blue: CIVector(
                x: CGFloat(mix * weights.red),
                y: CGFloat(mix * weights.green),
                z: CGFloat(keep + mix * weights.blue),
                w: 0
            ),
            alpha: CIVector(x: 0, y: 0, z: 0, w: 1),
            bias: CIVector(x: CGFloat(offset), y: CGFloat(offset), z: CGFloat(offset), w: 0)
        )
    }
}

extension DesktopBackdropRenderer {
    /// The `L*` the baked still's mean is driven to, per appearance.
    ///
    /// Derived from `targetLuminance` rather than declared, so a *neutral*
    /// wallpaper lands on exactly the grey the veil arithmetic of rounds 2–4
    /// was priced against and every published composite figure still holds.
    /// What changes is only which pictures count as having reached it: a blue
    /// desktop now arrives at the same **perceived** lightness as a green one
    /// instead of being flooded with grey until its *luma* matched.
    static func targetLightness(isDark: Bool) -> Double {
        Oklab.lightness(
            red: targetLuminance(isDark: isDark),
            green: targetLuminance(isDark: isDark),
            blue: targetLuminance(isDark: isDark)
        )
    }

    /// `tailHeadroom` restated in `L*`, and derived from it for the same reason
    /// — the bound the previous round measured and shipped is preserved
    /// exactly for a neutral wallpaper and merely stops depending on hue.
    static func tailHeadroomLightness(isDark: Bool) -> Double {
        let target = targetLuminance(isDark: isDark)
        let headroom = tailHeadroom(isDark: isDark)
        let edge = isDark ? target + headroom : target - headroom
        return abs(Oklab.lightness(red: edge, green: edge, blue: edge)
            - targetLightness(isDark: isDark))
    }

    /// The share of the wallpaper's own colourfulness that reaches the still.
    ///
    /// This is `saturationCeiling` restated as a *perceptual* quantity, and the
    /// difference is the whole round. The old constant scaled the filter's
    /// saturation **input** and left the output wherever the picture's hue put
    /// it; this one is a target the solve drives the measured Oklab
    /// chroma-to-lightness of the finished still onto, so two wallpapers that
    /// are equally colourful arrive equally colourful whatever their hue.
    ///
    /// Both values are chosen so the *average* colourfulness over the hue
    /// family is what the shipped pipeline already delivered — surface Oklab
    /// saturation 0.128 in dark and 0.055 in light. **Nothing about how
    /// colourful the glass is has moved; only how evenly it is reached.** Dark
    /// keeps the larger share and still ends up the more damped surface, for
    /// the reason `darkSaturationCeiling` gives: at near-black the same
    /// absolute chroma is a far larger fraction of the surface, so a bigger
    /// number here is what *holds* dark where round 7 put it.
    /// Left at the shipped values deliberately.
    ///
    /// Halving these did make the surface calmer, and it also broke the
    /// hue-invariance property round 8 established: with the wallpaper's chroma
    /// cut, `GlassWarmth`'s fixed amber becomes proportionally larger and the
    /// invariance test's "amber removed" correction stops accounting for the
    /// difference (1.035× against a 1.03 tolerance). Rebalancing the two
    /// together is the right change and is worth doing on its own.
    ///
    /// It is also not urgent, because the over-saturation Michael saw was mostly
    /// the *wrong picture*: the shuffle heuristic was painting an autumn
    /// hillside, all yellows and greens, behind a desktop of grey basalt. With
    /// the desktop captured rather than guessed, the source is his own muted
    /// wallpaper and the share is being asked to colour something that is barely
    /// coloured to begin with.
    /// 2026-08-04: both shares (and `okSaturationCeiling`, and `GlassWarmth`)
    /// take a deliberate 27% step down together — "less saturated, still
    /// detailed". Scaling the amber WITH the chroma is what the earlier
    /// halving attempt missed: warmth left at full strength becomes
    /// proportionally larger against the cut chroma and the hue-invariance
    /// correction stops accounting for it. Texture is untouched — the blur
    /// and local-contrast constants do not move.
    static let desktopChromaShare: Double = 0.118
    static let darkDesktopChromaShare: Double = 0.166

    static func desktopChromaShare(isDark: Bool) -> Double {
        isDark ? darkDesktopChromaShare : desktopChromaShare
    }

    /// A hard ceiling on the still's perceived colourfulness, so an extreme
    /// desktop cannot ask the solve for a saturation that only gamut clipping
    /// could deliver.
    /// The saturation a wallpaper actually *reads* as, rather than its average.
    ///
    /// A plain mean asks "how colourful is the typical pixel", and for most real
    /// desktops the honest answer is "not at all". A photograph of near-black
    /// basalt with green moss along its ridges is ~95% dark grey rock, so the
    /// mean lands near 0.08 — times a 0.162 share, an effective chroma of 0.013
    /// — and the still comes out grey with the green averaged out of existence.
    /// The green is the only colour anyone would name if asked about that
    /// picture.
    ///
    /// This weights every pixel by its own saturation, so the measure answers
    /// "where is this picture's colour, and how strong is it there" (`Σs²/Σs`).
    /// Grey pixels contribute to neither numerator nor denominator, so they
    /// dilute nothing.
    ///
    /// Two properties make it safe rather than merely louder:
    ///
    /// * A genuinely grey desktop still measures **zero** and stays grey —
    ///   there is no colour to find, as opposed to a little colour being
    ///   drowned.
    /// * A *uniformly* coloured desktop measures exactly its own saturation, so
    ///   nothing that already worked is pushed further.
    ///
    /// It can therefore only raise the reading for a picture whose colour is
    /// concentrated rather than spread — which is precisely the case that was
    /// broken. Michael: "it doesn't need to be exactly 1:1 translucent, it could
    /// take peaks and move them."
    ///
    /// Pure, so the three properties above are tested rather than argued.
    /// How strongly concentrated colour outweighs spread colour.
    ///
    /// 0 is a plain mean. 1 squares the weight, which found the moss but
    /// amplified a residual hue dependence in the pixel distribution enough to
    /// break the invariance round 8 established — measured, the surface's
    /// colourfulness varied 1.156× across the hue family against a 1.12
    /// tolerance. That property is worth more than the extra lift, so the
    /// emphasis is softened rather than the tolerance widened.
    ///
    /// At 0.5 the moss fixture still reads roughly twice its mean, which is the
    /// difference between "grey" and "green".
    static let concentrationExponent: Double = 0.5

    static func characteristicSaturation(
        _ pixels: [(red: Double, green: Double, blue: Double)]
    ) -> Double {
        var weighted = 0.0
        var weight = 0.0
        for pixel in pixels {
            let peak = max(pixel.red, max(pixel.green, pixel.blue))
            guard peak > 0.004 else { continue }
            let base = min(pixel.red, min(pixel.green, pixel.blue))
            let saturation = (peak - base) / peak
            let emphasis = pow(saturation, concentrationExponent)
            weighted += saturation * emphasis
            weight += emphasis
        }
        guard weight > 0.0001 else { return 0 }
        return weighted / weight
    }

    static let okSaturationCeiling: Double = 0.20
    /// And a ceiling on the filter input itself, for the same reason from the
    /// other side.
    static let toneSaturationCeiling: Double = 3.0

    /// How much of the still the worst patch is.
    ///
    /// **0.25%, not the 2% every contrast floor is stated in** — and the reason
    /// is desktop pinning. A glass surface no longer shows the whole still: it
    /// shows the region of wallpaper actually behind it, and the smallest glass
    /// surface in the app (a 210 pt sidebar on a 1512 pt display) is about an
    /// eighth of the screen. Its own brightest 2% is therefore roughly the
    /// **brightest 0.25% of the wallpaper**, and that — not the whole picture's
    /// 2% — is the patch the floors have to survive. Bounding the looser
    /// quantity would leave every floor in this file stated about a surface
    /// that no longer exists.
    static let tailFraction: Double = 0.0025

    /// How many times the solve refines the map.
    ///
    /// Each knob is close to independent of the other two — the offset moves
    /// lightness, the gain moves the tail, the saturation moves chroma — and
    /// the offset is re-settled to convergence inside every pass, so the outer
    /// loop only has to let the gain walk down to its constraint. Four passes
    /// landed mean `L*` to four decimals; the 2026-08-04 chroma cut showed
    /// the SATURATION fixed point converging slower at lower targets (the
    /// hue-invariance spread crept from under 1.03 to 1.033 with nothing else
    /// hue-dependent in the pipeline), so the loop runs longer — each extra
    /// pass is one 96×96 probe measure on a rare off-thread bake.
    static let toneSolveIterations = 8

    /// Solve the tone map **against the structure the surface will actually
    /// show**, in the space the guarantee is stated in.
    ///
    /// Round 7 moved the bake from solving blind to measuring its own structure
    /// once and solving from that. This goes one step further because the
    /// quantities now being targeted — perceived lightness, perceived
    /// colourfulness — are not linear in the knobs that move them, so a single
    /// closed-form step lands near the target rather than on it. Applying the
    /// candidate map to the probe in software and re-measuring is a few hundred
    /// microseconds and removes the last place the bake was estimating.
    ///
    /// Three targets, three knobs:
    ///
    /// - **offset** → the mean `L*` lands on `targetLightness`.
    /// - **gain** → the worst patch's `L*` sits inside `tailHeadroomLightness`.
    /// - **saturation** → the mean Oklab saturation lands on the wallpaper's
    ///   own, scaled by `desktopChromaShare`.
    ///
    /// The saturation target being *proportional to the wallpaper's* is what
    /// keeps a grey desktop grey: a neutral picture has zero colourfulness, so
    /// its target is zero and no amount of solving can invent a hue.
    static func solveToneMap(
        probe rgba: [UInt8],
        isDark: Bool,
        chromaScale: Double = 1
    ) -> BakeToneMap {
        var pixels: [(red: Double, green: Double, blue: Double)] = []
        pixels.reserveCapacity(rgba.count / 4)
        var index = 0
        while index + 3 < rgba.count {
            if Double(rgba[index + 3]) / 255 > 0.05 {
                pixels.append((
                    Double(rgba[index]) / 255,
                    Double(rgba[index + 1]) / 255,
                    Double(rgba[index + 2]) / 255
                ))
            }
            index += 4
        }
        var map = BakeToneMap(saturation: 1, gain: 1, offset: 0)
        guard !pixels.isEmpty else { return map }
        // The table belongs to one rare off-main bake. Keeping it local avoids
        // a Swift 6.1 lazy-global initializer while preserving the solve's
        // quarter-million lookup fast path.
        let linearTable = Oklab.makeLinearTable()

        let target = targetLightness(isDark: isDark)
        let headroom = tailHeadroomLightness(isDark: isDark)
        let band = max(1, Int(Double(pixels.count) * tailFraction))
        // The wallpaper's own colourfulness, measured once and **exactly**
        // hue-neutrally: HSV saturation is invariant under a hue rotation by
        // construction, where even Oklab's chroma-to-lightness carries a
        // residual 9% hue dependence (0.298 blue / 0.300 green / 0.326 red on
        // the hue family). The *target* is perceptual and the *source* measure
        // is hue-blind, which is the pairing the invariance needs.
        let chromaTarget = min(
            okSaturationCeiling,
            characteristicSaturation(pixels)
                * desktopChromaShare(isDark: isDark)
                * max(0, chromaScale)
        )

        // The map is `(luma + delta·saturation)·gain + offset` per channel, and
        // `luma` and `delta` do not move between iterations — so they are
        // computed once and each pass is two multiplies per channel.
        let weights = BakeToneMap.lumaWeights
        let luma = pixels.map {
            weights.red * $0.red + weights.green * $0.green + weights.blue * $0.blue
        }
        let deltas = pixels.enumerated().map {
            ($0.element.red - luma[$0.offset],
             $0.element.green - luma[$0.offset],
             $0.element.blue - luma[$0.offset])
        }

        /// Mean and worst-patch `L*`, and mean Oklab saturation, of the probe
        /// under a candidate map.
        ///
        /// The worst patch is taken by keeping the running extreme `band`
        /// values rather than sorting all 9216 — the band is about twenty
        /// entries, so an insertion into a sorted twenty is cheaper than a sort
        /// of nine thousand, and this runs a dozen times per bake.
        func measure(_ candidate: BakeToneMap)
            -> (mean: Double, tail: Double, saturation: Double) {
            var mean = 0.0
            var saturation = 0.0
            var extremes: [Double] = []
            extremes.reserveCapacity(band + 1)
            for position in pixels.indices {
                let base = luma[position]
                let delta = deltas[position]
                func channel(_ value: Double) -> Double {
                    min(1, max(0, (base + value * candidate.saturation) * candidate.gain
                        + candidate.offset))
                }
                let red = Oklab.tabulatedLinear(channel(delta.0), table: linearTable)
                let green = Oklab.tabulatedLinear(channel(delta.1), table: linearTable)
                let blue = Oklab.tabulatedLinear(channel(delta.2), table: linearTable)
                let long = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
                let medium = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
                let short = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
                let lightness = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short
                let a = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short
                let b = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
                mean += lightness
                saturation += (a * a + b * b).squareRoot() / max(lightness, 0.001)

                // `extremes` is kept ascending; dark wants the top of it, light
                // the bottom, so each drops the opposite end.
                if extremes.count < band {
                    extremes.insert(lightness, at: extremes.partitionPoint(before: lightness))
                } else if isDark ? lightness > extremes[0] : lightness < extremes[band - 1] {
                    extremes.insert(lightness, at: extremes.partitionPoint(before: lightness))
                    extremes.remove(at: isDark ? 0 : band)
                }
            }
            let tail = extremes.reduce(0, +) / Double(max(extremes.count, 1))
            return (mean / Double(pixels.count), tail, saturation / Double(pixels.count))
        }

        // The offset is re-solved **to convergence** for whatever gain and
        // saturation are current, rather than nudged once per outer pass. That
        // separation is what makes the whole thing converge: mean `L*` is
        // strictly increasing in the offset, and `Oklab.grey` is its exact
        // inverse for a neutral pixel, so the fixed point is reached in two or
        // three steps from any starting point.
        func settleOffset(_ candidate: inout BakeToneMap)
            -> (mean: Double, tail: Double, saturation: Double) {
            var reading = measure(candidate)
            for _ in 0..<3 {
                let correction = Oklab.grey(lightness: target)
                    - Oklab.grey(lightness: reading.mean)
                if abs(correction) < 0.0005 { break }
                candidate.offset = min(1, max(-1, candidate.offset + correction))
                reading = measure(candidate)
            }
            return reading
        }

        for _ in 0..<toneSolveIterations {
            let reading = settleOffset(&map)
            // The gain only ever *shrinks*, from 1 toward whatever the tail
            // constraint needs. Letting it climb back would make the solve
            // chase its own last correction — the tail is small precisely
            // because the gain is small — and oscillate instead of settle.
            let excursion = abs(reading.tail - target)
            if excursion > headroom {
                map.gain = max(0.02, map.gain * headroom / excursion)
            }
            if chromaTarget <= 0 {
                map.saturation = 0
            } else if reading.saturation > 0.0005 {
                map.saturation = min(
                    toneSaturationCeiling,
                    max(0, map.saturation * chromaTarget / reading.saturation)
                )
            }
        }
        _ = settleOffset(&map)
        return map
    }
}

struct DesktopTintComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
}

enum DesktopTintSampler {
    /// The tint when there is no desktop to read: a plain grey at the same
    /// Rec. 709 luma the old slate fallback had (0.4237), but achromatic.
    ///
    /// It was 0.38/0.43/0.49 — a blue-grey — so the one case where Kaisola
    /// knows *nothing* about the wallpaper was also the case where it invented
    /// the most blue.
    static var fallback: DesktopTintComponents {
        DesktopTintComponents(red: 0.42, green: 0.42, blue: 0.42)
    }

    /// How much of the wallpaper's own chroma reaches the tint.
    ///
    /// This was 0.45 with a 0.18 slate mix, tuned back when the tint *was* the
    /// backdrop and a saturated desktop could shout through the whole sidebar.
    /// It no longer is: the painted wallpaper carries the desktop now, and the
    /// tint's remaining jobs — the last fallback rung and the Tinted canvas —
    /// both want the hue to be legible rather than damped. At the old values a
    /// magenta desktop resolved to a 0.18-wide channel spread, which is grey
    /// once a veil goes over it.
    static let chromaRetention = 0.70
    /// Floors low enough that a dark wallpaper stays dark, and achromatic, so
    /// clamping a very dark or very bright desktop cannot introduce a hue the
    /// wallpaper does not have. The blue floor used to sit 0.02 above the other
    /// two, which meant every near-black desktop resolved to a *blue*
    /// near-black. The veil above is what guarantees legibility; clamping here
    /// only prevents a degenerate tint.
    static let floors = (red: 0.07, green: 0.07, blue: 0.07)
    static let ceilings = (red: 0.91, green: 0.91, blue: 0.91)

    static func sample(image: CGImage) -> DesktopTintComponents {
        guard let pixels = pixels(image: image) else { return fallback }
        return wallpaperAverage(rgba: pixels) ?? fallback
    }

    /// The 16×16 box reduction both the tint and the bake's luminance
    /// normalization read, exposed so one decode produces both instead of
    /// drawing the same image twice.
    static func pixels(image: CGImage, side: Int = 16) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drew ? pixels : nil
    }

    /// Rec. 709 luma of the wallpaper's plain average — no chroma softening,
    /// no floors.
    /// This is what the bake normalizes against, so it has to describe the
    /// picture rather than the tint derived from it.
    static func meanLuminance(rgba: [UInt8]) -> Double? {
        guard let average = plainAverage(rgba: rgba) else { return nil }
        return average.0 * 0.2126 + average.1 * 0.7152 + average.2 * 0.0722
    }

    /// Mean luminance of the extreme 2% band — the brightest in dark, the
    /// darkest in light.
    ///
    /// This is the still-side twin of the worst patch every contrast floor in
    /// this app is measured on, and it is what the bake's cap is solved against.
    /// A percentile *band* (p5..p95) deliberately excludes the tail; the tail is
    /// precisely where white text on dark glass is hardest to read, so the
    /// quantity the guarantee is written in has to be the quantity the bake
    /// bounds. See `DesktopBackdropRenderer.tailHeadroom(isDark:)`.
    static func worstPatchLuminance(rgba: [UInt8], isDark: Bool) -> Double? {
        var lumas: [Double] = []
        lumas.reserveCapacity(rgba.count / 4)
        var index = 0
        while index + 3 < rgba.count {
            if Double(rgba[index + 3]) / 255 > 0.05 {
                lumas.append(
                    Double(rgba[index]) / 255 * 0.2126
                        + Double(rgba[index + 1]) / 255 * 0.7152
                        + Double(rgba[index + 2]) / 255 * 0.0722
                )
            }
            index += 4
        }
        guard lumas.count >= 50 else { return nil }
        lumas.sort()
        let count = max(1, lumas.count / 50)
        let band = isDark ? lumas.suffix(count) : lumas.prefix(count)
        return band.reduce(0, +) / Double(count)
    }

    /// The wallpaper's p5..p95 luminance range, read from the same box the mean
    /// is — the *second* moment the bake normalizes, and the one that decides
    /// how bright the brightest patch of a glass surface gets.
    ///
    /// Percentiles rather than min..max because a 16×16 box has 256 samples and
    /// one blown highlight in a corner should not set the gain for the whole
    /// picture. Two samples either end are trimmed, so a wallpaper needs a real
    /// bright *region* to be treated as high-range.
    static func luminanceSpread(rgba: [UInt8]) -> Double? {
        var lumas: [Double] = []
        var index = 0
        while index + 3 < rgba.count {
            if Double(rgba[index + 3]) / 255 > 0.05 {
                lumas.append(
                    Double(rgba[index]) / 255 * 0.2126
                        + Double(rgba[index + 1]) / 255 * 0.7152
                        + Double(rgba[index + 2]) / 255 * 0.0722
                )
            }
            index += 4
        }
        guard lumas.count >= 20 else { return nil }
        lumas.sort()
        let count = Double(lumas.count)
        return lumas[Int(count * 0.95)] - lumas[Int(count * 0.05)]
    }

    private static func plainAverage(rgba: [UInt8]) -> (Double, Double, Double)? {
        guard rgba.count >= 4 else { return nil }
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0
        var index = 0
        while index + 3 < rgba.count {
            let alpha = Double(rgba[index + 3]) / 255
            if alpha > 0.05 {
                red += Double(rgba[index]) / 255
                green += Double(rgba[index + 1]) / 255
                blue += Double(rgba[index + 2]) / 255
                count += 1
            }
            index += 4
        }
        guard count > 0 else { return nil }
        return (red / count, green / count, blue / count)
    }

    /// The wallpaper's average, with its chroma pulled toward luminance and
    /// clamped — and **nothing else mixed in**.
    ///
    /// This was `cooledAverage`, and it earned the name: it blended 10% of a
    /// cool slate (0.35/0.42/0.50) into every sampled tint. The intent was to
    /// keep a near-neutral desktop from picking up a random cast, but a
    /// constant blue-grey stop does not prevent a cast — it *is* one, applied
    /// unconditionally, and it is the second half of the blue-purple tone. A
    /// grey desktop now comes back grey because the wallpaper is grey, not
    /// because a slate was averaged into it, and the only hue in the result is
    /// the desktop's own. Renamed to match: it is the wallpaper's average, not
    /// a cooled one.
    /// The desktop's hue at a chosen value: the sampled tint scaled so its
    /// brightest channel lands on `peak`, hue and channel ratios untouched.
    ///
    /// This is what makes the Tinted canvas *tinted* rather than merely dimmer.
    /// Compositing the raw sample over the canvas moves brightness and hue
    /// together, and brightness dominates: at the coverage a canvas can afford,
    /// the surface reads as "slightly grey white" and not as "tinted". Michael's
    /// note is exactly that — "the tinted canvas settings should actually be
    /// tinted or a white solid" — and measured against the real desktop the old
    /// Tinted canvas sat **0.016** off-neutral in light, against Solid's 0.000.
    /// Nothing to see.
    ///
    /// Re-valuing first separates the two. In light the tint goes to full value
    /// (peak 1) so the composite keeps the canvas's brightness and takes only
    /// its hue; in dark it goes to a low value so it takes the hue without
    /// turning the canvas into a lamp.
    static func revalued(_ tint: DesktopTintComponents, peak: Double) -> DesktopTintComponents {
        let brightest = max(tint.red, max(tint.green, tint.blue))
        guard brightest > 0.001 else {
            return DesktopTintComponents(red: peak, green: peak, blue: peak)
        }
        let scale = peak / brightest
        return DesktopTintComponents(
            red: min(1, tint.red * scale),
            green: min(1, tint.green * scale),
            blue: min(1, tint.blue * scale)
        )
    }

    /// Value the Tinted canvas re-values the desktop's hue to, per appearance.
    /// Light takes it at full value (over white, that is pure hue and almost no
    /// dimming); dark takes it just above the canvas it sits on.
    static func canvasTintPeak(isDark: Bool) -> Double { isDark ? 0.34 : 1.0 }

    /// Coverage of the re-valued tint at the two ends of the canvas gradient.
    /// Same light-from-above language as the glass veil.
    static func canvasTintCoverage(isDark: Bool) -> (top: Double, bottom: Double) {
        isDark ? (top: 0.55, bottom: 0.38) : (top: 0.45, bottom: 0.30)
    }

    static func wallpaperAverage(rgba: [UInt8]) -> DesktopTintComponents? {
        guard let wallpaper = plainAverage(rgba: rgba) else { return nil }
        let luminance = wallpaper.0 * 0.2126 + wallpaper.1 * 0.7152 + wallpaper.2 * 0.0722
        let softened = (
            luminance + (wallpaper.0 - luminance) * chromaRetention,
            luminance + (wallpaper.1 - luminance) * chromaRetention,
            luminance + (wallpaper.2 - luminance) * chromaRetention
        )
        return DesktopTintComponents(
            red: min(ceilings.red, max(floors.red, softened.0)),
            green: min(ceilings.green, max(floors.green, softened.1)),
            blue: min(ceilings.blue, max(floors.blue, softened.2))
        )
    }
}
