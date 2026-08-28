import AppKit
import CoreImage
import SwiftUI

/// AppKit's real behind-window vibrancy. SwiftUI's Material samples only the
/// app's own backing surface in this full-size transparent window, which made
/// the previous "Glass" setting look indistinguishable from flat gray.
struct NativeVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// Optional post-vibrancy saturation control. Rails leave it disabled so
    /// the live desktop keeps its colour as well as its light and movement.
    var neutralizesChroma = false

    @MainActor
    private func configure(_ view: NSVisualEffectView) {
        // Kaisola's glass is the app's surface, not a focus indicator. With
        // `.followsWindowActiveState` AppKit discards the blur and fills with
        // the material's flat inactive gray the instant the window loses key,
        // which is what made every rail gray out behind any other app.
        // `.active` keeps the behind-window sample alive; compositing stays in
        // WindowServer either way, so nothing new is scheduled.
        view.state = Self.resolvedState
        view.material = material
        view.blendingMode = blendingMode
        view.wantsLayer = true
        if neutralizesChroma, let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(0, forKey: kCIInputSaturationKey)
            view.layer?.filters = [filter]
        } else {
            view.layer?.filters = []
        }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    nonisolated static func resolvedSaturation(neutralizesChroma: Bool) -> Double {
        neutralizesChroma ? 0 : 1
    }

    /// `.active`, always. See the comment in `configure`.
    nonisolated static let resolvedState: NSVisualEffectView.State = .active
}

/// The one **deliberately non-neutral** layer in the dark glass stack.
///
/// Everything else the app declares as a backdrop constant is achromatic, and
/// `testDeclaredNeutralConstantsAreAchromatic` enforces that per-channel — that
/// invariant is what caught the `#0B0C12` blue-purple cast, and it must not be
/// weakened. So the v1.1.8 warmth is *not* a warmer "neutral": it is a separate,
/// named, exempt constant with its own test (`testGlassWarmthIsADeclaredAmber`)
/// pinning its hue and its coverage. Anything that wants to be warm has to say
/// so here; anything that claims to be neutral still has to prove it there.
///
/// One flat amber laid over the dark baked still, before the veil. It is not a
/// gradient: the veil above already carries the light direction and a second
/// gradient under it only muddies both. The declared 2.9% reference is scaled
/// down to the dark carrier's luminance; light coverage is exactly zero.
enum GlassWarmth {
    /// `#FFB070`. A high-value amber rather than a saturated orange: the layer
    /// is applied at a few percent, so what matters is the direction it pulls
    /// the composite, and a dark or heavily saturated tint at this coverage
    /// pulls toward *grey-brown* instead of toward warm.
    static let red = 1.0
    static let green = 176.0 / 255
    static let blue = 112.0 / 255

    /// Reference coverage from which the dark value is derived.
    /// 0.04 → 0.029 with the 2026-08-04 chroma cut, 0.029 → 0.04 with the
    /// 2026-08-28 lively-tint re-raise: the amber scales WITH
    /// `DesktopBackdropRenderer.desktopChromaShare` in **both** directions so
    /// the declared warmth stays the same *proportion* of the surface's
    /// colour — the ratio the hue-invariance correction depends on. Bounded
    /// by `testGlassWarmthIsADeclaredAmber` (hard < 0.08 ceiling, > 0.02
    /// floor; the exact pin moves with this constant on purpose) and by the
    /// derived dark coverage's 0.004 floor, which 0.04 clears at 0.00565.
    static let opacity = 0.04

    /// Coverage per appearance. Light Glass is explicitly neutral white, so
    /// the amber is absent there; dark keeps the scaled warmth that prevents a
    /// cool near-black surface from turning purple.
    ///
    /// This used to be one number, on the argument that the still underneath is
    /// luminance-normalized so the same coverage lands on comparable ground in
    /// both appearances. That argument is wrong, and in the same way the
    /// saturation constant was wrong: the still is normalized onto very
    /// different light and dark grounds. The same amber coverage would be a
    /// much larger relative perturbation near black, in a hue directly opposite
    /// the cool cast the dark surface already had — which is what turned
    /// "blue" into "purple". Coverage therefore scales with the luminance of
    /// the surface it lands on rather than being copied between appearances.
    ///
    /// It is still a declared amber in dark and still not zero there — a warm
    /// hint that survives its own audit rather than a layer quietly deleted.
    static func opacity(isDark: Bool) -> Double {
        guard isDark else { return 0 }
        let light = DesktopBackdropRenderer.targetLuminance(isDark: false)
        let target = DesktopBackdropRenderer.targetLuminance(isDark: true)
        return opacity * (target / light)
    }

    static var color: Color { Color(red: red, green: green, blue: blue) }
}

/// The desktop layer beneath a glass veil.
///
/// This is the layer the wallpaper-only request is about: in `.wallpaper` mode
/// nothing behind the window is sampled at all, so another app's window can
/// never appear inside Kaisola's glass.
struct DesktopGlassLayer: View {
    let liveMaterial: NSVisualEffectView.Material
    let carrierWhiteCoverage: Double
    /// Ceiling for the light live-path white lift — see
    /// `LightGlassFrost.liveWhiteLift`. Zero opts a surface out entirely
    /// (the opaque themes' ground, which keeps its own declared coverage).
    let liveWhiteLiftCeiling: Double
    /// Tint coverage (dark, light) laid over *live* vibrancy only. Both
    /// halves are small sampled lifts — dark 0.15, light 0.12 since the
    /// 2026-08-28 lively-tint round (light spent a year at zero after the
    /// white-rail pass) — that reinforce the desktop's own hue over the
    /// material. The painted wallpaper already is the hue and must not be
    /// tinted twice, which is why this never applies in `.wallpaper` mode.
    ///
    /// See `SidebarBackdropView.liveTint` for the receipts on both values.
    var liveTint: (dark: Double, light: Double)?

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings: NativePreviewSettings
    @ObservedObject private var desktop = DesktopBackdropProvider.shared

    init(
        liveMaterial: NSVisualEffectView.Material,
        liveTint: (dark: Double, light: Double)? = nil,
        carrierWhiteCoverage: Double = LightGlassFrost.carrierWhiteCoverage,
        liveWhiteLiftCeiling: Double = LightGlassFrost.liveLiftCoverage.canvas,
        settings: NativePreviewSettings = .shared
    ) {
        self.liveMaterial = liveMaterial
        self.liveTint = liveTint
        self.carrierWhiteCoverage = carrierWhiteCoverage
        self.liveWhiteLiftCeiling = liveWhiteLiftCeiling
        self.settings = settings
    }

    /// `.underWindowBackground` is intentionally neutral and makes a large
    /// light canvas read grey. Safari's white navigation frost comes from the
    /// light `.sidebar` material, so every light Glass surface resolves to that
    /// same carrier; dark keeps the material selected by its surface.
    nonisolated static func resolvedLiveMaterial(
        _ requested: NSVisualEffectView.Material,
        isDark: Bool
    ) -> NSVisualEffectView.Material {
        isDark ? requested : .sidebar
    }

    /// Live Glass keeps the sampled RGB ratios in both appearances. Light's
    /// exact white belongs to the workspace carrier, not to a filter on the
    /// navigation rails.
    nonisolated static func resolvedLiveTint(
        _ tint: DesktopTintComponents,
        isDark: Bool
    ) -> DesktopTintComponents {
        tint
    }

    /// Both appearances preserve the live material's sampled colour. The
    /// light sampled overlay may still have zero coverage; this flag also
    /// keeps the vibrancy layer itself out of the chroma-neutralizing path.
    nonisolated static func appliesSampledLiveTint(isDark: Bool) -> Bool {
        true
    }

    /// Coverage for the no-wallpaper fallback. Zero in light makes a failed
    /// decode fail to neutral white instead of reviving the sampled cast.
    nonisolated static func flatTintCoverage(isDark: Bool) -> (top: Double, bottom: Double) {
        isDark ? (0.42, 0.26) : (0, 0)
    }

    var body: some View {
        layer
            .onAppear { desktop.refresh(isDark: colorScheme == .dark) }
            .onChange(of: colorScheme) { desktop.refresh(isDark: colorScheme == .dark) }
            // Both of these change the bake rather than the veil, so the still
            // has to be re-rendered — once, through the same cached, coalesced,
            // off-thread path any desktop change takes.
            .onChange(of: settings.glassTexture) { desktop.refresh(isDark: colorScheme == .dark) }
            .onChange(of: settings.glassColour) { desktop.refresh(isDark: colorScheme == .dark) }
    }

    @ViewBuilder
    private var layer: some View {
        let isDark = colorScheme == .dark
        ZStack {
            switch settings.glassBackdropSource {
            case .wallpaper:
                paintedDesktop
            case .behindWindow:
                NativeVisualEffectView(
                    material: Self.resolvedLiveMaterial(liveMaterial, isDark: isDark),
                    neutralizesChroma: !Self.appliesSampledLiveTint(isDark: isDark)
                )
                if let liveTint, Self.appliesSampledLiveTint(isDark: isDark) {
                    let tint = Self.resolvedLiveTint(desktop.painting.tint, isDark: isDark)
                    let tintColor = Color(red: tint.red, green: tint.green, blue: tint.blue)
                    // Light scales by the sample's colourful share: the tint
                    // exists to concentrate the desktop's hue, and a grey
                    // sample — a white desktop clamped at the sampler's 0.91
                    // ceiling, or the 0.42 fallback — has none, so painting
                    // it would only grey the material. Dark keeps its shipped
                    // coverage untouched (its transmission receipts are
                    // pinned by `testLiveGlassPassesFarMoreOfTheMaterialInDarkThanItDid`).
                    let coverage = isDark
                        ? liveTint.dark
                        : liveTint.light * LightGlassFrost.liveTintChromaShare(tint)
                    LinearGradient(
                        colors: [
                            tintColor.opacity(coverage),
                            tintColor.opacity(coverage * 0.55),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                if !isDark {
                    // The live path's white floor — see `LightGlassFrost
                    // .liveWhiteLift`. Sits under the carrier so the modeled
                    // algebra reads veil ∘ carrier ∘ lift ∘ material.
                    let lift = LightGlassFrost.liveWhiteLift(
                        ceiling: liveWhiteLiftCeiling,
                        tint: desktop.painting.tint
                    )
                    if lift > 0 {
                        Color.white.opacity(lift)
                            .allowsHitTesting(false)
                    }
                }
            }
            if !isDark {
                Color.white.opacity(carrierWhiteCoverage)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The still is **pinned to desktop coordinates** — each surface shows the
    /// region of wallpaper actually behind it, at the wallpaper's own scale and
    /// at the window's own offset on its own screen.
    ///
    /// It used to be stretched: one still, spread across every surface
    /// whatever its shape and wherever the window was. The argument was that
    /// filling each surface to its own aspect would show each a different crop
    /// and read as a seam — true, and beside the point, because the fix for
    /// that is not to show every surface the *same wrong* crop but to show each
    /// the *right* one. What a stretched still cannot do at any blur radius or
    /// any veil opacity is read as transparent, because nothing in it moves
    /// when the window moves, and nothing in it corresponds to what is behind
    /// the window. Michael: "we don't get the translucence at all. I meant the
    /// glass wallpaper should be translucent to the wallpaper itself."
    @ViewBuilder
    private var paintedDesktop: some View {
        switch desktop.painting {
        case let .wallpaper(image, _, pixels):
            DesktopWallpaperPatch(still: image, wallpaperPixels: pixels)
                // The declared warm layer (v1.1.8), over the still and under
                // the veil. Over, so the desaturated wallpaper is what it warms
                // rather than the other way round; under, because the veil is
                // what decides how much of this whole composite arrives.
                .overlay(GlassWarmth.color.opacity(GlassWarmth.opacity(isDark: colorScheme == .dark)))
                .allowsHitTesting(false)
        case let .flat(tint):
            let isDark = colorScheme == .dark
            let color = Color(red: tint.red, green: tint.green, blue: tint.blue)
            let coverage = Self.flatTintCoverage(isDark: isDark)
            LinearGradient(
                colors: [color.opacity(coverage.top), color.opacity(coverage.bottom)],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(Color(nsColor: .windowBackgroundColor))
            // Light coverage and light warmth are both zero. A failed decode
            // therefore falls back to neutral white, not a sampled colour.
            .overlay(GlassWarmth.color.opacity(GlassWarmth.opacity(isDark: isDark)))
        }
    }
}

/// A glass surface's window onto the wallpaper behind it.
///
/// One `CALayer` holding the cached still, with `contentsRect` set to the part
/// of the wallpaper this view covers. Following a drag is therefore **one
/// property assignment on an existing layer** — no decode, no blur, no
/// re-render of the still, no new texture upload; the same texture is sampled
/// from a different rectangle. That is what makes desktop pinning affordable
/// at drag cadence and is why round 2's "it would re-lay out on every drag"
/// worry does not apply to a *baked and cached* still.
struct DesktopWallpaperPatch: NSViewRepresentable {
    let still: CGImage
    let wallpaperPixels: CGSize

    func makeNSView(context: Context) -> DesktopWallpaperPatchView {
        let view = DesktopWallpaperPatchView()
        view.apply(still: still, wallpaperPixels: wallpaperPixels)
        return view
    }

    func updateNSView(_ view: DesktopWallpaperPatchView, context: Context) {
        view.apply(still: still, wallpaperPixels: wallpaperPixels)
    }
}

/// A value resolved at most once per key until something drops it.
///
/// Extracted from `DesktopLayoutCache` with no AppKit in it so the rule that
/// actually matters — *one* resolve per key, and a drop really does force the
/// next one — is a test rather than a claim about a call an assertion cannot
/// reach without a display attached.
struct ResolveOnceCache<Key: Hashable, Value> {
    private var entries: [Key: Value] = [:]

    /// Number of times `resolve` has actually run. Test-facing; the production
    /// path never reads it.
    private(set) var resolveCount = 0

    mutating func value(for key: Key, resolve: (Key) -> Value) -> Value {
        if let cached = entries[key] { return cached }
        resolveCount += 1
        let resolved = resolve(key)
        entries[key] = resolved
        return resolved
    }

    mutating func invalidate() { entries.removeAll(keepingCapacity: true) }
}

/// How macOS lays the desktop picture out on each display, cached.
///
/// `NSWorkspace.desktopImageOptions(for:)` reads like a property and is not
/// one: it is a hop into the desktop-picture store, measured on this machine at
/// **4.4 ms a call**. The patch needs the layout every time the window moves,
/// once per glass surface — and a 120 Hz frame is 8.3 ms in total, so asking
/// for it there spent more than a whole frame's budget per surface per frame.
/// That is the judder Michael saw dragging the window; the arithmetic around it
/// was already sub-microsecond.
///
/// A layout changes only when the desktop picture or the display arrangement
/// changes, and both announce themselves. So this drops on those signals and is
/// a dictionary lookup the rest of the time — including throughout a drag,
/// which posts none of them.
@MainActor
enum DesktopLayoutCache {
    typealias Layout = (scaling: NSImageScaling, allowsClipping: Bool)

    private static var cache = ResolveOnceCache<CGDirectDisplayID, Layout>()
    private static var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    static func layout(for screen: NSScreen) -> Layout {
        install()
        // A screen with no display number is not a display we can key on, so it
        // pays the read. It is also not a case that arises on a real desktop.
        guard let id = displayID(of: screen) else {
            return DesktopBackdropGeometry.layout(
                from: NSWorkspace.shared.desktopImageOptions(for: screen)
            )
        }
        return cache.value(for: id) { _ in
            DesktopBackdropGeometry.layout(
                from: NSWorkspace.shared.desktopImageOptions(for: screen)
            )
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Registered once, never torn down: the cache outlives every window and
    /// costs five observers for the life of the process.
    private static func install() {
        guard observers.isEmpty else { return }
        func watch(_ name: Notification.Name, on center: NotificationCenter) {
            observers.append((center, center.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { cache.invalidate() } }))
        }
        // The subset of `DesktopBackdropProvider`'s signals that can change a
        // *layout* rather than the picture's pixels: the displays were
        // rearranged, another Space with its own desktop came forward, the
        // machine woke, or the user was in System Settings while we were away.
        watch(NSApplication.didChangeScreenParametersNotification, on: .default)
        watch(NSApplication.didBecomeActiveNotification, on: .default)
        watch(NSWorkspace.activeSpaceDidChangeNotification, on: NSWorkspace.shared.notificationCenter)
        watch(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter)
        watch(DesktopBackdropProvider.desktopChangedNotification, on: DistributedNotificationCenter.default())
    }
}

/// The `NSView` half, and the app's only hook into where its windows are.
///
/// Everything it listens to is a *frame* signal — the window moved, the window
/// resized, the window landed on another display, the displays themselves were
/// reconfigured. The wallpaper's own change signals stay where they were, on
/// `DesktopBackdropProvider`; nothing here re-reads the desktop or re-bakes
/// anything.
final class DesktopWallpaperPatchView: NSView {
    /// Registrations, held so both the main actor and `deinit` can drop them.
    /// `NotificationCenter` is itself thread-safe, so the only thing the box
    /// buys is a home for the tokens that is not actor-isolated — and it
    /// remembers *which* centre each token came from, because one of them is
    /// `NSWorkspace`'s rather than the default one.
    private final class Registrations: @unchecked Sendable {
        var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

        func drop() {
            for entry in tokens { entry.center.removeObserver(entry.token) }
            tokens = []
        }
    }

    private let patch = CALayer()
    private var wallpaperPixels: CGSize = .zero
    private let registrations = Registrations()
    /// What the layer is already showing, so a repeated signal is free.
    private var appliedContentsRect: CGRect?
    private var appliedFrame: CGRect?
    /// Live only while the window is moving; see `setNeedsBackdropRefresh`.
    private var displayLink: CADisplayLink?
    private var backdropNeedsRefresh = false
    private var idleFrames = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        patch.contentsGravity = .resize
        // The still is magnified into the surface — a 210 pt sidebar is about
        // an eighth of a display — so the filter matters. Trilinear keeps the
        // upscale free of the faceting bilinear leaves on a smooth gradient.
        patch.magnificationFilter = .trilinear
        patch.minificationFilter = .trilinear
        patch.needsDisplayOnBoundsChange = false
        layer?.addSublayer(patch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { registrations.drop() }

    func apply(still: CGImage, wallpaperPixels: CGSize) {
        self.wallpaperPixels = wallpaperPixels
        if !(patch.contents as AnyObject? === still) {
            patch.contents = still
        }
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe()
        // A view with no window has nothing to pace against, and a display
        // link outliving its window is a retained timer firing at 120 Hz.
        if window == nil { stopDisplayLink() }
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    /// Every signal that can move the wallpaper *under* this view without
    /// changing the wallpaper itself.
    private func observe() {
        registrations.drop()
        guard let window else { return }
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, on center: NotificationCenter, object: Any?) {
            registrations.tokens.append((center, center.addObserver(
                forName: name, object: object, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }))
        }
        // `didMove` fires continuously through a live drag, which is exactly
        // the cadence the backdrop has to follow to read as glass.
        //
        // Delivered on `queue: nil` — synchronously, on the thread that posted
        // — rather than hopping through `OperationQueue.main`. These four are
        // AppKit window notifications and are always posted on the main thread,
        // so the isolation assumption below holds; what the hop cost was a
        // frame of latency, which during a drag is the backdrop trailing the
        // window. Trailing is the one thing a pane of glass never does.
        for name: Notification.Name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ] {
            registrations.tokens.append((center, center.addObserver(
                forName: name, object: window, queue: nil
            ) { [weak self] _ in MainActor.assumeIsolated { self?.setNeedsBackdropRefresh() } }))
        }
        watch(NSApplication.didChangeScreenParametersNotification, on: center, object: nil)
        watch(
            NSWorkspace.activeSpaceDidChangeNotification,
            on: NSWorkspace.shared.notificationCenter,
            object: nil
        )
    }

    /// Ask for one backdrop update on the next frame the display actually draws.
    ///
    /// A window drag posts `didMove` on the event stream, not the display's —
    /// so the events arrive in bursts that do not line up with frames, and
    /// several can land inside one refresh interval. Answering each of them
    /// individually does work the screen never shows and paces the backdrop by
    /// the mouse rather than by the display.
    ///
    /// A display link is the opposite: exactly one update per frame while the
    /// window is moving, at whatever the screen's real rate is (60 Hz, 120 Hz
    /// on ProMotion), and — because it stops itself once the moves stop —
    /// nothing at all while the window sits still. Michael: "60 fps for the
    /// background wallpaper, but only when moving the app."
    private func setNeedsBackdropRefresh() {
        backdropNeedsRefresh = true
        startDisplayLinkIfNeeded()
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        displayLink = link
        idleFrames = 0
    }

    /// Frames of no movement before the link stops. A drag pauses mid-gesture
    /// constantly; tearing the link down on the first still frame would spend
    /// more on starting and stopping than on drawing.
    private static let idleFramesBeforeStopping = 12

    @objc private func displayLinkFired() {
        guard backdropNeedsRefresh else {
            idleFrames += 1
            if idleFrames >= Self.idleFramesBeforeStopping { stopDisplayLink() }
            return
        }
        backdropNeedsRefresh = false
        idleFrames = 0
        refresh()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        idleFrames = 0
    }

    private func refresh() {
        guard patch.contents != nil, let window else { return }
        // `window.screen` is the display AppKit considers the window to be on
        // — the one it overlaps most — which is the display whose desktop
        // picture and whose fill mode apply.
        guard let screen = window.screen ?? NSScreen.main else { return }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        let layout = DesktopLayoutCache.layout(for: screen)
        let rect = DesktopBackdropGeometry.contentsRect(
            surface: onScreen,
            imagePixels: wallpaperPixels,
            screen: screen.frame,
            scaling: layout.scaling,
            allowsClipping: layout.allowsClipping,
            backingScale: screen.backingScaleFactor
        )
        // A drag posts `didMove` once per frame per surface, and a window
        // nudged inside one point produces the same rectangle twice. Committing
        // an identical transaction is not free at that cadence.
        guard rect != appliedContentsRect || bounds != appliedFrame else { return }
        appliedContentsRect = rect
        appliedFrame = bounds
        // No implicit animation: a drag would otherwise ease the backdrop
        // toward each new position a quarter-second behind the window, which
        // reads as the glass sliding rather than the desktop staying put.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        patch.frame = bounds
        patch.contentsRect = rect
        CATransaction.commit()
    }
}

/// One gradient stop the flowing tint hands to Core Animation.
struct TintFlowStop: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let opacity: Double
    let location: Double

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }
}

/// The stops each appearance feeds the flowing Tinted surface.
///
/// Pure and enumerated here rather than inline in the view so the composition
/// — which colours, at what coverage, in what order — is a unit test instead
/// of a screenshot diff.
enum TintFlowComposition {
    /// Light: the selected palette's two coloured ends crossing its quiet
    /// midpoint. Constant palettes ignore the desktop sample; `.desktop`
    /// resolves its stops from it, clamped to the pastel box.
    static func light(
        palette: TintPalette,
        desktop: DesktopTintComponents,
        coverageScale: Double
    ) -> [TintFlowStop] {
        // The scale may exceed 1 (a rail share times a Vivid/Bold intensity);
        // saturation is guarded per stop instead, so no stop can ever paint
        // past full coverage.
        let scale = max(0, coverageScale)
        let stops = palette.light(desktop: desktop)
        return [
            TintFlowStop(
                red: stops.cool.red,
                green: stops.cool.green,
                blue: stops.cool.blue,
                opacity: min(1, stops.coolCoverage * scale),
                location: 0
            ),
            TintFlowStop(
                red: stops.neutral.red,
                green: stops.neutral.green,
                blue: stops.neutral.blue,
                opacity: min(1, stops.neutralCoverage * scale),
                location: stops.neutralLocation
            ),
            TintFlowStop(
                red: stops.pearl.red,
                green: stops.pearl.green,
                blue: stops.pearl.blue,
                opacity: min(1, stops.pearlCoverage * scale),
                location: 1
            ),
        ]
    }

    /// Dark: an anchor at the lit end flowing *into* a companion at the
    /// settled end — a genuine A → B crossing, with the coverage pair kept
    /// monotonic so the sweep still reads as light from above rather than as
    /// a washed band in the middle. `.desktop` keeps the sampled path; every
    /// named palette carries its own light hues to the dark canvas peak.
    /// Dark's ceiling on any single stop. Dark's baseline coverage (0.55) is
    /// nearly double light's heaviest stop, so an intensity multiplier that is
    /// harmless in light would take the dark canvas's anchor fully opaque —
    /// the plate this theme explicitly disclaims. Ninety percent keeps a
    /// tenth of transmission at the deepest chosen intensity.
    static let maximumDarkStopCoverage: Double = 0.90

    static func dark(
        palette: TintPalette,
        tint: DesktopTintComponents,
        coverageScale: Double
    ) -> [TintFlowStop] {
        let coverage = DesktopTintSampler.canvasTintCoverage(isDark: true)
        let heaviest = max(coverage.top, coverage.bottom)
        let scale = min(
            max(0, coverageScale),
            heaviest > 0 ? maximumDarkStopCoverage / heaviest : 0
        )
        let anchor: TintRGB
        let companion: TintRGB
        if let ends = palette.darkEnds() {
            anchor = ends.anchor
            companion = ends.companion
        } else {
            let revalued = DesktopTintSampler.revalued(
                tint,
                peak: DesktopTintSampler.canvasTintPeak(isDark: true)
            )
            anchor = TintRGB(red: revalued.red, green: revalued.green, blue: revalued.blue)
            let rotated = TintFlowMotion.companion(
                red: revalued.red,
                green: revalued.green,
                blue: revalued.blue
            )
            companion = TintRGB(red: rotated.red, green: rotated.green, blue: rotated.blue)
        }
        return [
            TintFlowStop(
                red: anchor.red,
                green: anchor.green,
                blue: anchor.blue,
                opacity: min(1, coverage.top * scale),
                location: 0
            ),
            TintFlowStop(
                red: companion.red,
                green: companion.green,
                blue: companion.blue,
                opacity: min(1, coverage.bottom * scale),
                location: 1
            ),
        ]
    }
}

/// The Core Animation host for the flowing tint.
///
/// A `CAGradientLayer` whose endpoints drift on an autoreversing render-server
/// animation. The app's only work is configuring the layer; while the surface
/// sits on screen the process schedules nothing, which is what lets a
/// permanently-moving backdrop coexist with the painted-still energy rules.
struct FlowingTintGradientView: NSViewRepresentable {
    let stops: [TintFlowStop]
    let startPoint: CGPoint
    let endPoint: CGPoint
    let animated: Bool
    var breathing: Bool = false
    var breathDepth: Double = 1

    func makeNSView(context: Context) -> FlowingTintGradientHostView {
        let view = FlowingTintGradientHostView()
        view.apply(
            stops: stops,
            startPoint: startPoint,
            endPoint: endPoint,
            animated: animated,
            breathing: breathing,
            breathDepth: breathDepth
        )
        return view
    }

    func updateNSView(_ view: FlowingTintGradientHostView, context: Context) {
        view.apply(
            stops: stops,
            startPoint: startPoint,
            endPoint: endPoint,
            animated: animated,
            breathing: breathing,
            breathDepth: breathDepth
        )
    }
}

final class FlowingTintGradientHostView: NSView {
    private let gradient = CAGradientLayer()
    private var appliedStops: [TintFlowStop] = []
    private var appliedStart: CGPoint = .zero
    private var appliedEnd: CGPoint = .zero
    private var appliedAnimated: Bool?
    private var appliedBreathing: Bool?
    private var appliedBreathDepth: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.type = .axial
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    /// Re-arms the drift when the view lands in a window. An animation added
    /// while the layer was windowless is silently dropped by AppKit, and a
    /// Space switch can strip it the same way; re-applying on attach is what
    /// keeps a long-lived sidebar flowing after either. The same attach point
    /// follows the window's occlusion, so a fully covered or minimized Tinted
    /// window spends nothing on its drift. Selector-based observation so the
    /// registration dies with the view instead of needing a deinit.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        if let window {
            windowOcclusionChanged(visible: window.occlusionState.contains(.visible))
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionStateDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        guard window != nil, appliedAnimated == true || appliedBreathing == true else { return }
        let restoreBreathing = appliedBreathing == true
        let restoreBreathDepth = appliedBreathDepth ?? 1
        appliedAnimated = nil
        appliedBreathing = nil
        appliedBreathDepth = nil
        apply(
            stops: appliedStops,
            startPoint: appliedStart,
            endPoint: appliedEnd,
            animated: true,
            breathing: restoreBreathing,
            breathDepth: restoreBreathDepth
        )
    }

    func apply(
        stops: [TintFlowStop],
        startPoint: CGPoint,
        endPoint: CGPoint,
        animated: Bool,
        breathing: Bool = false,
        breathDepth: Double = 1
    ) {
        let colorsChanged = stops != appliedStops
        let geometryChanged = startPoint != appliedStart || endPoint != appliedEnd
        let motionChanged = animated != appliedAnimated
        // Depth only matters while the breath is actually running: an
        // intensity change with the living tint off is a colour-only change,
        // and treating it as a breathing change would restart the drift and
        // visibly snap its phase — exactly what the fast path below protects.
        let breathingChanged = breathing != appliedBreathing
            || (breathing && breathDepth != appliedBreathDepth)
        guard colorsChanged || geometryChanged || motionChanged || breathingChanged else { return }
        appliedStops = stops
        appliedStart = startPoint
        appliedEnd = endPoint
        appliedAnimated = animated
        appliedBreathing = breathing
        appliedBreathDepth = breathDepth

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = stops.map(\.cgColor)
        gradient.locations = stops.map { NSNumber(value: $0.location) }
        gradient.startPoint = startPoint
        gradient.endPoint = endPoint
        gradient.frame = bounds
        // Turning the breath off must restore the model values deterministically
        // — both the opacity it fades and the transform its swell scales.
        gradient.opacity = 1
        gradient.transform = CATransform3DIdentity
        CATransaction.commit()

        // A colour-only change (a wallpaper rotation resampling the dark tint)
        // updates the stops under the transaction above and leaves the drift
        // alone: removing and re-adding it would snap the endpoints back to
        // phase zero, visibly, every few minutes on a rotating desktop.
        guard geometryChanged || motionChanged || breathingChanged else { return }
        gradient.removeAnimation(forKey: Self.startAnimationKey)
        gradient.removeAnimation(forKey: Self.endAnimationKey)
        gradient.removeAnimation(forKey: Self.breathAnimationKey)
        gradient.removeAnimation(forKey: Self.swellAnimationKey)
        guard animated else { return }
        let travel = TintFlowMotion.endpoints(start: startPoint, end: endPoint)
        gradient.add(
            Self.drift(
                keyPath: "startPoint",
                from: travel.startFrom,
                to: travel.startTo
            ),
            forKey: Self.startAnimationKey
        )
        gradient.add(
            Self.drift(
                keyPath: "endPoint",
                from: travel.endFrom,
                to: travel.endTo
            ),
            forKey: Self.endAnimationKey
        )
        guard breathing else { return }
        gradient.add(Self.breath(depth: breathDepth), forKey: Self.breathAnimationKey)
        gradient.add(Self.swell(depth: breathDepth), forKey: Self.swellAnimationKey)
    }

    @objc private func windowOcclusionStateDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == self.window else {
            return
        }
        windowOcclusionChanged(visible: window.occlusionState.contains(.visible))
    }

    /// The drift pauses whenever its window is fully occluded, the way every
    /// other at-rest motion in the app stops when nothing can see it. Layer
    /// speed zero freezes the render-server animation in place; restoring
    /// speed resumes it from the same phase.
    func windowOcclusionChanged(visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.speed = visible ? 1 : 0
        CATransaction.commit()
    }

    private static let startAnimationKey = "kaisola.tint-flow.start"
    private static let endAnimationKey = "kaisola.tint-flow.end"
    private static let breathAnimationKey = "kaisola.tint-flow.breath"
    private static let swellAnimationKey = "kaisola.tint-flow.swell"

    /// The breath's sharper-than-`easeInEaseOut` S curve: more dwell at the
    /// extremes, a quicker transit between them, which is what lets a shallow
    /// change register at all without raising its depth.
    private static var breathTiming: CAMediaTimingFunction {
        let points = TintFlowMotion.breathTimingControlPoints
        return CAMediaTimingFunction(
            controlPoints: points.0, points.1, points.2, points.3
        )
    }

    /// The opt-in breath: whole-layer opacity easing between the floor and 1.
    /// Same render-server ownership, frame-rate cap, occlusion freeze
    /// (`gradient.speed`), and wall-clock phase lock as the drift. `depth`
    /// deepens the swing for the Vivid/Bold intensities; the floor can never
    /// drop below half opacity whatever the multiplier.
    private static func breath(depth: Double = 1) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = max(0.5, 1 - TintFlowMotion.breathAmplitude * max(0, depth))
        animation.toValue = 1
        animation.duration = TintFlowMotion.breathPeriod
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = breathTiming
        animation.isRemovedOnCompletion = false
        animation.timeOffset = CACurrentMediaTime()
            .truncatingRemainder(dividingBy: TintFlowMotion.breathPeriod * 2)
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: 5,
            maximum: 15,
            preferred: 10
        )
        return animation
    }

    /// The breath's paired swell: the whole field scaling a few percent about
    /// its centre on its own, longer period. The scale never goes below 1, so
    /// the layer only ever over-covers its bounds — clipping crops overflow
    /// rather than exposing a gap. Same discipline as the breath in every
    /// other respect.
    private static func swell(depth: Double = 1) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.0
        animation.toValue = 1.0 + TintFlowMotion.breathScaleAmplitude * max(0, depth)
        animation.duration = TintFlowMotion.breathScalePeriod
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = breathTiming
        animation.isRemovedOnCompletion = false
        animation.timeOffset = CACurrentMediaTime()
            .truncatingRemainder(dividingBy: TintFlowMotion.breathScalePeriod * 2)
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: 5,
            maximum: 15,
            preferred: 10
        )
        return animation
    }

    private static func drift(
        keyPath: String,
        from: CGPoint,
        to: CGPoint
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: to)
        animation.duration = TintFlowMotion.period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        // Every surface anchors its phase to the same wall clock, so the
        // project rail, file rail, and canvas — nearly identical gradients —
        // drift together instead of showing a slowly walking step at their
        // seams. The offset wraps at one full autoreverse round trip.
        animation.timeOffset = CACurrentMediaTime()
            .truncatingRemainder(dividingBy: TintFlowMotion.period * 2)
        // Motion this slow needs single-digit frame rates; an uncapped
        // animation would hold a ProMotion display off its idle refresh for
        // sub-pixel movement.
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: 5,
            maximum: 15,
            preferred: 10
        )
        return animation
    }
}

/// The Core Animation host for the thinking shimmer: a horizontal gradient
/// swept behind a `CATextLayer` mask, so the status word itself carries the
/// highlight.
///
/// Rejected alternatives, deliberately: `TimelineView(.animation)` wakes
/// SwiftUI every frame on the main thread, which the painted-still energy
/// rules forbid; a SwiftUI `.mask`/`.overlay`/`repeatForever` build is
/// CA-backed but SwiftUI silently drops and restarts the repeat whenever the
/// view's identity or any observed state changes — and this label sits under
/// a `contentVersion` churning at streaming rate, so it would stutter on
/// every token. A `locations` animation owned by the render server survives
/// both.
struct ShimmerTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let animated: Bool

    func makeNSView(context: Context) -> ShimmerTextHostView {
        let view = ShimmerTextHostView()
        view.apply(text: text, font: font, animated: animated)
        return view
    }

    func updateNSView(_ view: ShimmerTextHostView, context: Context) {
        view.apply(text: text, font: font, animated: animated)
    }
}

final class ShimmerTextHostView: NSView {
    private let contentLayer = CAGradientLayer()
    private let maskLayer = CATextLayer()
    private var appliedText: String?
    private var appliedFont: NSFont?
    private var appliedAnimated: Bool?
    private var attributed = NSAttributedString()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        contentLayer.type = .axial
        contentLayer.startPoint = CGPoint(x: 0, y: 0.5)
        contentLayer.endPoint = CGPoint(x: 1, y: 0.5)
        maskLayer.truncationMode = .none
        maskLayer.isWrapped = false
        contentLayer.mask = maskLayer
        layer?.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The label is not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The row lays out from the text alone, so SwiftUI never needs a
    /// `GeometryReader` around it.
    override var intrinsicContentSize: NSSize {
        let size = attributed.size()
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        maskLayer.frame = bounds
        CATransaction.commit()
    }

    /// A mask layer defaults to 1x and renders blurry glyphs on Retina; it has
    /// to follow the window's scale. Same hook as `DesktopWallpaperPatchView`.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        maskLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// The resting and highlight inks resolve against the effective
    /// appearance; without this a theme change keeps the old ink.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Re-arms the sweep when the view lands in a window: an animation added
    /// while the layer was windowless is silently dropped by AppKit, and this
    /// label mounts during a transcript update, which is precisely that
    /// window. The same attach point follows the window's occlusion, so a
    /// fully covered window spends nothing on the sweep.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        if let window {
            maskLayer.contentsScale = window.backingScaleFactor
            windowOcclusionChanged(visible: window.occlusionState.contains(.visible))
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionStateDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        guard window != nil,
              appliedAnimated == true,
              let text = appliedText,
              let font = appliedFont else { return }
        appliedAnimated = nil
        apply(text: text, font: font, animated: true)
    }

    func apply(text: String, font: NSFont, animated: Bool) {
        let textChanged = text != appliedText || font != appliedFont
        let motionChanged = animated != appliedAnimated
        guard textChanged || motionChanged else { return }
        appliedText = text
        appliedFont = font
        appliedAnimated = animated

        if textChanged {
            // Opaque white: a mask contributes alpha only, and the visible
            // ink comes from the gradient it clips.
            attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
            ])
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            maskLayer.string = attributed
            CATransaction.commit()
            invalidateIntrinsicContentSize()
        }
        applyColors()

        guard motionChanged else { return }
        contentLayer.removeAnimation(forKey: Self.sweepAnimationKey)
        guard animated else { return }
        contentLayer.add(Self.sweep(), forKey: Self.sweepAnimationKey)
    }

    /// Resting ink at both ends, the primary-ink highlight in the middle. The
    /// model value parks the highlight fully off the leading edge, so a
    /// non-animated shimmer is pixel-identical to the static secondary label.
    private func applyColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink: CGFloat = isDark ? 1 : 0
        let resting = KaisolaInk.alpha(.secondary, isDark: isDark)
        let highlight = ThinkingShimmerMotion.highlightAlpha(
            resting: resting,
            primary: KaisolaInk.alpha(.primary, isDark: isDark)
        )
        let restingColor = CGColor(srgbRed: ink, green: ink, blue: ink, alpha: resting)
        let highlightColor = CGColor(srgbRed: ink, green: ink, blue: ink, alpha: highlight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.colors = [
            restingColor, restingColor, highlightColor, restingColor, restingColor,
        ]
        contentLayer.locations = ThinkingShimmerMotion.startLocations
            .map { NSNumber(value: $0) }
        CATransaction.commit()
    }

    @objc private func windowOcclusionStateDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == self.window else {
            return
        }
        windowOcclusionChanged(visible: window.occlusionState.contains(.visible))
    }

    /// Layer speed zero freezes the render-server sweep in place; restoring
    /// speed resumes it from the same phase.
    private func windowOcclusionChanged(visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.speed = visible ? 1 : 0
        CATransaction.commit()
    }

    private static let sweepAnimationKey = "kaisola.thinking-shimmer.sweep"

    private static func sweep() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = ThinkingShimmerMotion.startLocations
            .map { NSNumber(value: $0) }
        animation.toValue = ThinkingShimmerMotion.endLocations
            .map { NSNumber(value: $0) }
        animation.duration = ThinkingShimmerMotion.period
        // A sweep that bounces reads as a scrubbing slider, not as progress.
        animation.autoreverses = false
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        // Two chats thinking at once sweep in phase rather than showing a
        // walking beat between panes.
        animation.timeOffset = CACurrentMediaTime()
            .truncatingRemainder(dividingBy: ThinkingShimmerMotion.period)
        // Watchable motion, unlike the tint drift's 5–15 range: a 1.6s sweep
        // at 10fps steps visibly.
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: 24,
            maximum: 60,
            preferred: 30
        )
        return animation
    }
}

/// The shared Tinted backdrop: an opaque base, the flowing gradient, and the
/// same increased-contrast overlay the other appearances honour.
struct FlowingTintedBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var desktop = DesktopBackdropProvider.shared
    // This view owns its own tint hooks (see the rail call sites), so the
    // opt-in breath is read here rather than threaded through both of them.
    @ObservedObject private var settings = NativePreviewSettings.shared
    /// Rails pass their share so one theme reads continuously across the
    /// window; the canvas passes 1.
    let coverageScale: Double
    let startPoint: UnitPoint
    let endPoint: UnitPoint

    init(
        coverageScale: Double = 1,
        startPoint: UnitPoint = .topLeading,
        endPoint: UnitPoint = .bottomTrailing
    ) {
        self.coverageScale = coverageScale
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    var body: some View {
        let isDark = colorScheme == .dark
        let palette = settings.tintPalette
        // Intensity multiplies at composition time, the same seam the rail
        // share already uses, so the palette definitions stay untouched.
        let intensity = settings.tintIntensity
        let scale = coverageScale * intensity.coverageMultiplier
        // A screenshot must never catch a mid-drift frame: fixture processes
        // pin the endpoints outright, which parks the layer at its given
        // start/end deterministically. Reduce Motion pins the same way.
        let pinned = TintFlowMotion.isPinned()
        FlowingTintGradientView(
            stops: isDark
                ? TintFlowComposition.dark(
                    palette: palette,
                    tint: desktop.painting.tint,
                    coverageScale: scale
                )
                : TintFlowComposition.light(
                    palette: palette,
                    desktop: desktop.painting.tint,
                    coverageScale: scale
                ),
            startPoint: TintFlowMotion.layerPoint(startPoint),
            endPoint: TintFlowMotion.layerPoint(endPoint),
            animated: !reduceMotion && !pinned,
            breathing: settings.tintedBreathing && !reduceMotion && !pinned,
            breathDepth: intensity.breathDepthMultiplier
        )
        .allowsHitTesting(false)
        .onAppear { refreshIfNeeded() }
        .onChange(of: colorScheme) { refreshIfNeeded() }
        .onChange(of: settings.tintPalette) { refreshIfNeeded() }
    }

    /// Dark always follows the wallpaper; light needs a sample only for the
    /// Desktop palette. Every other light palette is a constant table and
    /// spends nothing on the sampler.
    private func refreshIfNeeded() {
        if colorScheme == .dark || settings.tintPalette == .desktop {
            desktop.refresh(isDark: colorScheme == .dark)
        }
    }
}

/// Reusable material used by both the project sidebar and the workspace file
/// rail, keeping the two left-hand navigation surfaces visually coherent.
struct SidebarBackdropView: View {
    /// Both window-edge rails live inside this exact AppKit material. Placement
    /// mirrors only the small colour gradient; it never selects a different
    /// blur, carrier, or neutral wash for Projects and Files.
    static let sharedGlassMaterial: NSVisualEffectView.Material = .sidebar
    /// Coverage of the sampled desktop average laid over *live* vibrancy.
    ///
    /// Michael's translucency note names both glass sources — "especially on
    /// live and wallpaper" — and in Live the veil is not the only thing between
    /// the user and the desktop: this tint sits under it, so the two coverages
    /// multiply. At the shipped pair the dark Live sidebar passed
    /// `(1 - 0.30) · (1 - 0.52) = 0.336` of the material; the thinner veil alone
    /// takes that to 0.462, and halving the dark tint takes it to **0.561** —
    /// the material behind the window contributes 67% more than it did.
    ///
    /// Dark keeps the sampled tint at 0.15. Light was taken to exactly zero
    /// by the white-rail pass (its old 0.26 tinted the material twice, and
    /// the strict-neutrality contract wanted nothing the app adds); the
    /// 2026-08-28 lively-tint round gives it back a smaller half — **0.12**,
    /// deliberately junior to dark's 0.15 — for "make the live tint much
    /// more lively/active": on a colourful desktop the light rails visibly
    /// carry the desktop's own sampled hue again instead of white over bare
    /// vibrancy. The tint is the wallpaper's averaged colour, so this is
    /// still inside the white-rail contract's letter ("the only chroma on a
    /// rail is whatever the desktop itself contributes") — what returns is
    /// concentration, not a colour of the app's own.
    ///
    /// What bounds it: the veil above is untouched, so 0.54 of whatever sits
    /// beneath it still reaches the eye — the pre-change transmission figure
    /// exactly; within that, twelve percent is now the sampled hue laid over
    /// the material (moving material share 0.54 × 0.88 = 0.475). Worst case
    /// for ink is a near-black desktop, whose tint floors at 0.07
    /// (`DesktopTintSampler.floors`): the modelled rail stays near 0.85
    /// luminance, far above the 0.75 worst patch `KaisolaInk`'s light floors
    /// were solved on. Pinned, both halves, by
    /// `testLiveGlassPassesFarMoreOfTheMaterialInDarkThanItDid`.
    ///
    /// (Unlike the wallpaper source, this cannot be measured offline: it lands
    /// on live vibrancy, whose input is whatever is behind the window. The
    /// numbers above are compositing algebra over the two declared coverages,
    /// which is exactly as much as is knowable without a screenshot.)
    static let liveTint = (dark: 0.15, light: 0.12)

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @ObservedObject private var settings = NativePreviewSettings.shared
    let appearance: SidebarAppearance
    let placement: SidebarRailPlacement

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .glass:
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                ZStack {
                    DesktopGlassLayer(
                        liveMaterial: Self.sharedGlassMaterial,
                        liveTint: Self.liveTint,
                        carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage,
                        liveWhiteLiftCeiling: LightGlassFrost.liveLiftCoverage.rail
                    )
                    GlassBackdropWash
                        .sidebar(isDark: colorScheme == .dark, clarity: settings.glassClarity.resolved(
                            increasedContrast: accessibilityContrast == .increased,
                            reduceTransparency: reduceTransparency
                        ))
                        .veil
                    // No edge cast. The light rails used to carry a
                    // cool-to-pearl gradient here; the white/black pass
                    // removed it so a glass rail is white frost, black frost,
                    // and the desktop's own colour — nothing the app adds.
                    if accessibilityContrast == .increased {
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(GlassBackdropWash.sidebarIncreasedContrastOverlay(isDark: colorScheme == .dark))
                    }
                }
            }
        case .solid:
            // The rails are ground, and the Solid ground is a plate again —
            // Michael, 2026-08-28: "the background/canvas of the app should
            // always be either white or glass (never gray)." The tenth of
            // behind-window material greyed the white rail whenever the
            // desktop behind the window wasn't white, and it kept live
            // vibrancy compositing under an opaque theme. Same coverage as
            // the Solid canvas still: the rails and the canvas are one
            // surface in the opaque themes and a separation step here would
            // draw a seam at the divider. No edge cast, same as glass:
            // colour on a rail belongs to Tinted alone.
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                GlassBackdropWash
                    .opaqueRailGround(appearance: .solid, isDark: colorScheme == .dark)
                    .veil
            }
        case .tinted:
            // Both appearances mirror per placement now. Dark used to hardcode
            // topLeading → bottomTrailing on every rail; unifying on the
            // placement points means the trailing file rail sweeps from its own
            // outside edge inward, the same symmetry light has always had.
            // The opaque base became the shared material ground with the
            // Tinted plate over it — tint over material, same as the canvas.
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                ZStack {
                    DesktopGlassLayer(
                        liveMaterial: Self.sharedGlassMaterial,
                        carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage,
                        // The lift is a glass-surface floor; Tinted's rail is
                        // an opaque theme whose own coverage does the covering.
                        liveWhiteLiftCeiling: 0
                    )
                    GlassBackdropWash
                        .opaqueRailGround(appearance: .tinted, isDark: colorScheme == .dark)
                        .veil
                    FlowingTintedBackdrop(
                        coverageScale: Self.railTintShare,
                        startPoint: placement.tintStartPoint,
                        endPoint: placement.tintEndPoint
                    )
                    if accessibilityContrast == .increased {
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(GlassBackdropWash.sidebarIncreasedContrastOverlay(isDark: colorScheme == .dark))
                    }
                }
            }
        }
    }

    /// How much of the canvas's tint coverage the rails take.
    ///
    /// Ninety percent. The old three-quarter scaling pushed the already-gentle
    /// stops back into 254–255 quantization, so the rails read as plain white
    /// even when the center still carried a trace of colour.
    static let railTintShare: Double = 0.90
}

struct WorkspaceBackdropView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @ObservedObject private var desktop = DesktopBackdropProvider.shared
    @ObservedObject private var settings = NativePreviewSettings.shared
    let mode: WorkspaceBackdropMode
    /// True while the canvas holds nothing — see
    /// `NativeWorkspaceChrome.canvasIsIdle`. An idle glass canvas drops to the
    /// clear still and a whisper of veil; mounting anything crossfades the
    /// legibility wash back in.
    var idle: Bool = false

    init(mode: WorkspaceBackdropMode, idle: Bool = false) {
        self.mode = mode
        self.idle = idle
    }

    /// Whether the idle canvas may drop its wash, stated once so it is
    /// testable. Accessibility outranks idleness: Reduce Transparency and
    /// Increased Contrast users asked for *less* desktop, and an empty canvas
    /// does not change what they asked for. The painted source additionally
    /// needs its clear still baked — until it is, the washed branch mounts,
    /// its `DesktopGlassLayer` triggers the resolve, and the idle branch takes
    /// over when the bake lands. The live source has no still to wait for; its
    /// idleness is just the thinner veil over the same material.
    nonisolated static func idleGlassEngages(
        idle: Bool,
        isDark: Bool,
        reduceTransparency: Bool,
        increasedContrast: Bool,
        paintedSource: Bool,
        clearStillAvailable: Bool
    ) -> Bool {
        // The clear idle canvas was the one light surface outside the white
        // recipe: it bypassed the normalized underlay and reduced the veil to a
        // whisper, so the background became the grey/coloured desktop again.
        // Keep that intentional transparency in dark appearance only. Light
        // uses the same white frost whether content is mounted or not.
        guard isDark, idle, !reduceTransparency, !increasedContrast else { return false }
        return paintedSource ? clearStillAvailable : true
    }

    var body: some View {
        // The tinted branch's refresh hooks live inside FlowingTintedBackdrop,
        // which owns the sampled tint in both surfaces.
        backdrop
            // While idle glass is showing, `DesktopGlassLayer` — which owns
            // these hooks on the washed branch — is unmounted, so a texture or
            // colour change made from Settings over an empty canvas would
            // otherwise keep painting the stale bake until the next desktop
            // signal.
            .onChange(of: settings.glassTexture) {
                if mode == .glass { desktop.refresh(isDark: colorScheme == .dark) }
            }
            .onChange(of: settings.glassColour) {
                if mode == .glass { desktop.refresh(isDark: colorScheme == .dark) }
            }
    }

    /// Tinted's ground material — the same behind-window material Glass
    /// uses, honouring `glassBackdropSource` and the painted fallback through
    /// the one existing code path. Solid stopped sitting on it when it went
    /// back to a plate; Tinted keeps its fifth of material because Tinted is
    /// the living theme and its flowing gradient wants ground that moves.
    /// `carrierWhiteCoverage` and the live white lift are both zero: the
    /// theme's own declared coverage does all the covering, and the lift is
    /// a glass-surface floor, not an opaque-theme one.
    private var groundMaterial: some View {
        DesktopGlassLayer(
            liveMaterial: .underWindowBackground,
            carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage,
            liveWhiteLiftCeiling: 0
        )
    }

    @ViewBuilder
    private var backdrop: some View {
        switch mode {
        case .system:
            // Solid is a plate again: white #FFFFFF light, `windowBackground`'s
            // near-black dark, nothing else. The Safari-ground experiment laid
            // a tenth of behind-window material under the plate, and that
            // tenth is exactly what Michael reported — "the background/canvas
            // of the app should always be either white or glass (never
            // gray)": over any desktop that wasn't white, the material share
            // greyed the white ground. The plate also stops a live vibrancy
            // view compositing under an opaque theme. Reduce Transparency
            // keeps the system-resolved plate.
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                GlassBackdropWash
                    .opaqueGround(theme: .system, isDark: colorScheme == .dark)
                    .veil
            }
        case .glass:
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                let clarity = settings.glassClarity.resolved(
                    increasedContrast: accessibilityContrast == .increased,
                    reduceTransparency: reduceTransparency
                )
                let paintedSource = settings.glassBackdropSource == .wallpaper
                let idleActive = Self.idleGlassEngages(
                    idle: idle,
                    isDark: colorScheme == .dark,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: accessibilityContrast == .increased,
                    paintedSource: paintedSource,
                    clearStillAvailable: desktop.clearStill != nil
                )
                ZStack {
                    if idleActive,
                       paintedSource,
                       let clear = desktop.clearStill,
                       case let .wallpaper(_, _, pixels) = desktop.painting {
                        // The clear still, pinned exactly as the washed one is,
                        // under the idle whisper of veil. No `GlassWarmth`:
                        // warmth is the declared compensation for the bake's
                        // chroma damping, and this still was never damped.
                        DesktopWallpaperPatch(still: clear, wallpaperPixels: pixels)
                            .allowsHitTesting(false)
                        GlassBackdropWash
                            .workspaceIdle(isDark: colorScheme == .dark, clarity: clarity)
                            .veil
                    } else {
                        DesktopGlassLayer(liveMaterial: .underWindowBackground)
                        if idleActive {
                            // Live source: the material is the transmission, so
                            // idleness is only the thinner veil.
                            GlassBackdropWash
                                .workspaceIdle(isDark: colorScheme == .dark, clarity: clarity)
                                .veil
                        } else {
                            GlassBackdropWash
                                .workspace(isDark: colorScheme == .dark, clarity: clarity)
                                .veil
                        }
                        if accessibilityContrast == .increased {
                            Color(nsColor: .windowBackgroundColor)
                                .opacity(GlassBackdropWash.workspaceIncreasedContrastOverlay(isDark: colorScheme == .dark))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: idleActive)
            }
        case .tinted:
            // Tint over material now: the flowing gradient composites onto
            // the shared material ground instead of onto a flat plate, with a
            // fifth of the surface arriving as behind-window material.
            // Increased Contrast dims the canvas exactly as it dims the rails
            // — without this the tripled coverage left a
            // white-rail-on-tinted-canvas split at the seam railTintShare
            // exists to prevent. Reduce Transparency gets the plain plate:
            // it is a request for no material at all, and the gradient is
            // not material. (This branch had no guard before the ground
            // became material; the gap only mattered once it did.)
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    groundMaterial
                    GlassBackdropWash
                        .opaqueGround(theme: .tinted, isDark: colorScheme == .dark)
                        .veil
                    FlowingTintedBackdrop()
                    if accessibilityContrast == .increased {
                        Color(nsColor: .windowBackgroundColor)
                            .opacity(GlassBackdropWash.workspaceIncreasedContrastOverlay(isDark: colorScheme == .dark))
                    }
                }
            }
        }
    }
}
