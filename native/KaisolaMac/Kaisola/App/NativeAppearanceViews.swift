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
        view.state = .followsWindowActiveState
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
    /// 0.029 (was 0.04): scaled down with the 2026-08-04 chroma cut so the
    /// declared amber stays the same *proportion* of the surface's colour —
    /// the ratio the hue-invariance correction depends on.
    static let opacity = 0.029

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
    /// Tint coverage (dark, light) laid over *live* vibrancy only. The light
    /// half may be zero because live vibrancy already carries the desktop hue;
    /// dark retains its small sampled lift. The painted wallpaper already is
    /// the hue and must not be tinted twice.
    ///
    /// See `SidebarBackdropView` for why the dark half of the pair is so much
    /// smaller than the light one.
    var liveTint: (dark: Double, light: Double)?

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings: NativePreviewSettings
    @ObservedObject private var desktop = DesktopBackdropProvider.shared

    init(
        liveMaterial: NSVisualEffectView.Material,
        liveTint: (dark: Double, light: Double)? = nil,
        carrierWhiteCoverage: Double = LightGlassFrost.carrierWhiteCoverage,
        settings: NativePreviewSettings = .shared
    ) {
        self.liveMaterial = liveMaterial
        self.liveTint = liveTint
        self.carrierWhiteCoverage = carrierWhiteCoverage
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
                    let coverage = isDark ? liveTint.dark : liveTint.light
                    LinearGradient(
                        colors: [
                            tintColor.opacity(coverage),
                            tintColor.opacity(coverage * 0.55),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
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
    /// Light: the declared sage → warm pearl → lilac composition.
    static func light(coverageScale: Double) -> [TintFlowStop] {
        let scale = min(1, max(0, coverageScale))
        return [
            TintFlowStop(
                red: LightTintedGradient.cool.red,
                green: LightTintedGradient.cool.green,
                blue: LightTintedGradient.cool.blue,
                opacity: LightTintedGradient.coolCoverage * scale,
                location: 0
            ),
            TintFlowStop(
                red: LightTintedGradient.neutral.red,
                green: LightTintedGradient.neutral.green,
                blue: LightTintedGradient.neutral.blue,
                opacity: LightTintedGradient.neutralCoverage * scale,
                location: LightTintedGradient.neutralLocation
            ),
            TintFlowStop(
                red: LightTintedGradient.pearl.red,
                green: LightTintedGradient.pearl.green,
                blue: LightTintedGradient.pearl.blue,
                opacity: LightTintedGradient.pearlCoverage * scale,
                location: 1
            ),
        ]
    }

    /// Dark: the sampled desktop hue anchors the lit end and flows *into* its
    /// rotated companion at the settled end — a genuine A → B crossing, with
    /// the coverage pair kept monotonic so the sweep still reads as light from
    /// above rather than as a washed band in the middle.
    static func dark(
        tint: DesktopTintComponents,
        coverageScale: Double
    ) -> [TintFlowStop] {
        let scale = min(1, max(0, coverageScale))
        let revalued = DesktopTintSampler.revalued(
            tint,
            peak: DesktopTintSampler.canvasTintPeak(isDark: true)
        )
        let coverage = DesktopTintSampler.canvasTintCoverage(isDark: true)
        let companion = TintFlowMotion.companion(
            red: revalued.red,
            green: revalued.green,
            blue: revalued.blue
        )
        return [
            TintFlowStop(
                red: revalued.red,
                green: revalued.green,
                blue: revalued.blue,
                opacity: coverage.top * scale,
                location: 0
            ),
            TintFlowStop(
                red: companion.red,
                green: companion.green,
                blue: companion.blue,
                opacity: coverage.bottom * scale,
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

    func makeNSView(context: Context) -> FlowingTintGradientHostView {
        let view = FlowingTintGradientHostView()
        view.apply(
            stops: stops,
            startPoint: startPoint,
            endPoint: endPoint,
            animated: animated
        )
        return view
    }

    func updateNSView(_ view: FlowingTintGradientHostView, context: Context) {
        view.apply(
            stops: stops,
            startPoint: startPoint,
            endPoint: endPoint,
            animated: animated
        )
    }
}

final class FlowingTintGradientHostView: NSView {
    private let gradient = CAGradientLayer()
    private var appliedStops: [TintFlowStop] = []
    private var appliedStart: CGPoint = .zero
    private var appliedEnd: CGPoint = .zero
    private var appliedAnimated: Bool?

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
        guard window != nil, appliedAnimated == true else { return }
        appliedAnimated = nil
        apply(
            stops: appliedStops,
            startPoint: appliedStart,
            endPoint: appliedEnd,
            animated: true
        )
    }

    func apply(
        stops: [TintFlowStop],
        startPoint: CGPoint,
        endPoint: CGPoint,
        animated: Bool
    ) {
        let colorsChanged = stops != appliedStops
        let geometryChanged = startPoint != appliedStart || endPoint != appliedEnd
        let motionChanged = animated != appliedAnimated
        guard colorsChanged || geometryChanged || motionChanged else { return }
        appliedStops = stops
        appliedStart = startPoint
        appliedEnd = endPoint
        appliedAnimated = animated

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = stops.map(\.cgColor)
        gradient.locations = stops.map { NSNumber(value: $0.location) }
        gradient.startPoint = startPoint
        gradient.endPoint = endPoint
        gradient.frame = bounds
        CATransaction.commit()

        // A colour-only change (a wallpaper rotation resampling the dark tint)
        // updates the stops under the transaction above and leaves the drift
        // alone: removing and re-adding it would snap the endpoints back to
        // phase zero, visibly, every few minutes on a rotating desktop.
        guard geometryChanged || motionChanged else { return }
        gradient.removeAnimation(forKey: Self.startAnimationKey)
        gradient.removeAnimation(forKey: Self.endAnimationKey)
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

/// The shared Tinted backdrop: an opaque base, the flowing gradient, and the
/// same increased-contrast overlay the other appearances honour.
struct FlowingTintedBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var desktop = DesktopBackdropProvider.shared
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
        FlowingTintGradientView(
            stops: isDark
                ? TintFlowComposition.dark(
                    tint: desktop.painting.tint,
                    coverageScale: coverageScale
                )
                : TintFlowComposition.light(coverageScale: coverageScale),
            startPoint: TintFlowMotion.layerPoint(startPoint),
            endPoint: TintFlowMotion.layerPoint(endPoint),
            animated: !reduceMotion
        )
        .allowsHitTesting(false)
        .onAppear {
            if isDark { desktop.refresh(isDark: true) }
        }
        .onChange(of: colorScheme) {
            if colorScheme == .dark { desktop.refresh(isDark: true) }
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
    /// Dark keeps the sampled tint at 0.15. Light's explicit overlay is zero
    /// because AppKit vibrancy now preserves the live desktop's own chroma;
    /// adding its average again would tint the material twice.
    ///
    /// (Unlike the wallpaper source, this cannot be measured offline: it lands
    /// on live vibrancy, whose input is whatever is behind the window. The
    /// numbers above are compositing algebra over the two declared coverages,
    /// which is exactly as much as is knowable without a screenshot.)
    static let liveTint = (dark: 0.15, light: 0.0)

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
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
                        carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage
                    )
                    GlassBackdropWash
                        .sidebar(isDark: colorScheme == .dark, clarity: settings.glassClarity.resolved(
                            increasedContrast: accessibilityContrast == .increased,
                            reduceTransparency: reduceTransparency
                        ))
                        .veil
                    if colorScheme == .light {
                        let visibility = controlActiveState == .key
                            ? 1.0
                            : LightRailTint.inactiveMultiplier
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(
                                    color: LightRailTint.coolColor.opacity(
                                        LightRailTint.coolCoverage * visibility
                                    ),
                                    location: 0
                                ),
                                .init(
                                    color: Color.white.opacity(
                                        LightRailTint.midpointCoverage * visibility
                                    ),
                                    location: LightRailTint.midpointLocation
                                ),
                                .init(
                                    color: LightRailTint.pearlColor.opacity(
                                        LightRailTint.pearlCoverage * visibility
                                    ),
                                    location: 1
                                ),
                            ]),
                            startPoint: placement.tintStartPoint,
                            endPoint: placement.tintEndPoint
                        )
                        .allowsHitTesting(false)
                    }
                    if accessibilityContrast == .increased {
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(GlassBackdropWash.sidebarIncreasedContrastOverlay(isDark: colorScheme == .dark))
                    }
                }
            }
        case .solid:
            Color(nsColor: .controlBackgroundColor)
        case .tinted:
            // Both appearances mirror per placement now. Dark used to hardcode
            // topLeading → bottomTrailing on every rail; unifying on the
            // placement points means the trailing file rail sweeps from its own
            // outside edge inward, the same symmetry light has always had.
            ZStack {
                Color(nsColor: .controlBackgroundColor)
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

    @ViewBuilder
    private var backdrop: some View {
        switch mode {
        case .system:
            // The white solid. One flat opaque colour, no sampling, no
            // gradient: whatever is on the desktop contributes exactly nothing.
            // `windowBackgroundColor` resolves to #FFFFFF in light and #1E1E1E
            // in dark, so this already *is* the "white solid" — what it lacked
            // was a name that said so and a Tinted option distinct enough for
            // the difference to be visible.
            Color(nsColor: .windowBackgroundColor)
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
            // Light flows the stable cool-to-white-to-pearl composition so a
            // blue desktop cannot turn the whole window flat blue; dark flows
            // the sampled desktop hue into its rotated companion. Increased
            // Contrast dims the canvas exactly as it dims the rails — without
            // this the tripled coverage left a white-rail-on-tinted-canvas
            // split at the seam railTintShare exists to prevent.
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                FlowingTintedBackdrop()
                if accessibilityContrast == .increased {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(GlassBackdropWash.workspaceIncreasedContrastOverlay(isDark: colorScheme == .dark))
                }
            }
        }
    }
}
