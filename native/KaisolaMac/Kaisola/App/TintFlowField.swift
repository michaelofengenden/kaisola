import AppKit
import SwiftUI

/// The Core Animation host for the Tinted theme's flowing field.
///
/// Three gradient layers stacked in one container — the ground swell (the
/// palette sweep, drifting its endpoints and folding its midpoint), the
/// cross-current (a broad band of the settled hue travelling the opposite
/// diagonal), and the ripple (a radial bloom wandering on two glide
/// periods). Every period is different and mutually non-harmonic, so the
/// superposition reads as water moving under wind rather than a gradient
/// ping-ponging: bands emerge, fold and dissolve instead of shuttling.
///
/// The app's only work is configuring the layers; while the surface sits on
/// screen the process schedules nothing. Rejected alternatives, deliberately:
/// `TimelineView(.animation)` wakes SwiftUI every frame on the main thread,
/// which the painted-still energy rules forbid, and a Canvas/shader field
/// would re-rasterize on the CPU or hold a display link open for motion that
/// is capped at ten frames a second anyway. Autoreversing render-server
/// animations on `CAGradientLayer` are the one construction that gives
/// permanent, layered motion with zero app-side wakeups — the same ownership
/// the single-sweep era had, grown to a field.
struct TintFlowFieldView: NSViewRepresentable {
    let swellStops: [TintFlowStop]
    let currentStops: [TintFlowStop]
    let rippleStops: [TintFlowStop]
    let startPoint: CGPoint
    let endPoint: CGPoint
    let animated: Bool
    var breathing: Bool = false
    var breathDepth: Double = 1

    func makeNSView(context: Context) -> TintFlowFieldHostView {
        let view = TintFlowFieldHostView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: TintFlowFieldHostView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: TintFlowFieldHostView) {
        view.apply(
            swellStops: swellStops,
            currentStops: currentStops,
            rippleStops: rippleStops,
            startPoint: startPoint,
            endPoint: endPoint,
            animated: animated,
            breathing: breathing,
            breathDepth: breathDepth
        )
    }
}

final class TintFlowFieldHostView: NSView {
    /// The container that owns the field's shared clock: the occlusion freeze
    /// and the opt-in breath act here, so all three layers stop, resume and
    /// breathe as one surface. Core Animation time is hierarchical — speed
    /// zero on this layer freezes every sublayer's animation in place.
    private let field = CALayer()
    private let swell = CAGradientLayer()
    private let current = CAGradientLayer()
    private let ripple = CAGradientLayer()

    private var appliedSwellStops: [TintFlowStop] = []
    private var appliedCurrentStops: [TintFlowStop] = []
    private var appliedRippleStops: [TintFlowStop] = []
    private var appliedStart: CGPoint = .zero
    private var appliedEnd: CGPoint = .zero
    private var appliedAnimated: Bool?
    private var appliedBreathing: Bool?
    private var appliedBreathDepth: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        swell.type = .axial
        current.type = .axial
        // The ripple is the field's fine scale: a bloom, not a sweep.
        ripple.type = .radial
        field.addSublayer(swell)
        field.addSublayer(current)
        field.addSublayer(ripple)
        layer?.addSublayer(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // No implicit animation: a resize would otherwise ease the field a
        // quarter-second behind the window. Geometry is points; the gradient
        // endpoints, band locations and bloom travels are all unit-space, so
        // nothing else needs re-arming on resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.frame = bounds
        swell.frame = field.bounds
        current.frame = field.bounds
        ripple.frame = field.bounds
        CATransaction.commit()
    }

    /// Re-arms the field when the view lands in a window. An animation added
    /// while the layer was windowless is silently dropped by AppKit, and a
    /// Space switch can strip it the same way; re-applying on attach is what
    /// keeps a long-lived sidebar flowing after either. The same attach point
    /// follows the window's occlusion, so a fully covered or minimized Tinted
    /// window spends nothing on its field. Selector-based observation so the
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
            swellStops: appliedSwellStops,
            currentStops: appliedCurrentStops,
            rippleStops: appliedRippleStops,
            startPoint: appliedStart,
            endPoint: appliedEnd,
            animated: true,
            breathing: restoreBreathing,
            breathDepth: restoreBreathDepth
        )
    }

    func apply(
        swellStops: [TintFlowStop],
        currentStops: [TintFlowStop],
        rippleStops: [TintFlowStop],
        startPoint: CGPoint,
        endPoint: CGPoint,
        animated: Bool,
        breathing: Bool = false,
        breathDepth: Double = 1
    ) {
        let colorsChanged = swellStops != appliedSwellStops
            || currentStops != appliedCurrentStops
            || rippleStops != appliedRippleStops
        let geometryChanged = startPoint != appliedStart || endPoint != appliedEnd
        // The fold animates the swell's `locations`, so a *shape* change —
        // the appearance flipping between light's three stops and dark's two
        // — must re-arm it: a stale three-element locations animation on a
        // two-stop model is undefined interpolation. A palette change that
        // keeps the stop layout stays on the colour-only fast path.
        let shapeChanged = swellStops.map(\.location) != appliedSwellStops.map(\.location)
            || currentStops.map(\.location) != appliedCurrentStops.map(\.location)
            || rippleStops.map(\.location) != appliedRippleStops.map(\.location)
        let motionChanged = animated != appliedAnimated
        // Depth only matters while the breath is actually running: an
        // intensity change with the living tint off is a colour-only change,
        // and treating it as a breathing change would restart the field and
        // visibly snap its phase — exactly what the fast path below protects.
        let breathingChanged = breathing != appliedBreathing
            || (breathing && breathDepth != appliedBreathDepth)
        guard colorsChanged || geometryChanged || motionChanged || breathingChanged else { return }
        appliedSwellStops = swellStops
        appliedCurrentStops = currentStops
        appliedRippleStops = rippleStops
        appliedStart = startPoint
        appliedEnd = endPoint
        appliedAnimated = animated
        appliedBreathing = breathing
        appliedBreathDepth = breathDepth

        // The model values are the park: with Reduce Motion or a fixture pin
        // no animation is ever added, and what these transactions compose is
        // exactly what renders — the sweep on its placement points, the band
        // held mid-surface, the bloom at the centre of its travel.
        let cross = TintFlowMotion.crossAxis(start: startPoint, end: endPoint)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swell.colors = swellStops.map(\.cgColor)
        swell.locations = swellStops.map { NSNumber(value: $0.location) }
        swell.startPoint = startPoint
        swell.endPoint = endPoint
        current.colors = currentStops.map(\.cgColor)
        current.locations = TintFlowMotion.currentLocations(phase: 0)
            .map { NSNumber(value: $0) }
        current.startPoint = cross.start
        current.endPoint = cross.end
        ripple.colors = rippleStops.map(\.cgColor)
        ripple.locations = rippleStops.map { NSNumber(value: $0.location) }
        ripple.startPoint = TintFlowMotion.midpoint(
            TintFlowMotion.rippleCenterFrom,
            TintFlowMotion.rippleCenterTo
        )
        ripple.endPoint = TintFlowMotion.midpoint(
            TintFlowMotion.rippleRadiusFrom,
            TintFlowMotion.rippleRadiusTo
        )
        field.frame = bounds
        swell.frame = field.bounds
        current.frame = field.bounds
        ripple.frame = field.bounds
        // Turning the breath off must restore the model values
        // deterministically — both the opacity it fades and the transform its
        // swell scales.
        field.opacity = 1
        field.transform = CATransform3DIdentity
        CATransaction.commit()

        // A colour-only change (a wallpaper rotation resampling the dark
        // tint, an intensity change) updates the stops under the transaction
        // above and leaves the motion alone: removing and re-adding it would
        // snap every layer back to phase zero, visibly, every few minutes on
        // a rotating desktop. (The wall-clock time offset means even a full
        // re-arm resumes at the shared phase, but only shape, geometry,
        // motion and breathing changes are worth the churn.)
        guard geometryChanged || shapeChanged || motionChanged || breathingChanged else { return }
        for (layer, keys) in [
            (swell, [Self.swellStartKey, Self.swellEndKey, Self.swellFoldKey]),
            (current, [Self.currentStartKey, Self.currentEndKey, Self.currentTravelKey]),
            (ripple, [Self.rippleCenterKey, Self.rippleRadiusKey]),
        ] as [(CALayer, [String])] {
            for key in keys { layer.removeAnimation(forKey: key) }
        }
        field.removeAnimation(forKey: Self.breathKey)
        field.removeAnimation(forKey: Self.breathSwellKey)
        guard animated else { return }

        // The ground swell: endpoint drift plus the midpoint fold.
        let travel = TintFlowMotion.endpoints(start: startPoint, end: endPoint)
        swell.add(
            Self.pointDrift(
                keyPath: "startPoint",
                from: travel.startFrom,
                to: travel.startTo,
                period: TintFlowMotion.period
            ),
            forKey: Self.swellStartKey
        )
        swell.add(
            Self.pointDrift(
                keyPath: "endPoint",
                from: travel.endFrom,
                to: travel.endTo,
                period: TintFlowMotion.period
            ),
            forKey: Self.swellEndKey
        )
        let swellLocations = swellStops.map(\.location)
        swell.add(
            Self.locationsDrift(
                from: TintFlowMotion.foldedLocations(swellLocations, phase: -1),
                to: TintFlowMotion.foldedLocations(swellLocations, phase: 1),
                period: TintFlowMotion.foldPeriod
            ),
            forKey: Self.swellFoldKey
        )

        // The cross-current: the band travelling its axis while the axis
        // itself shears a little on a separate period.
        let shear = TintFlowMotion.endpoints(
            start: cross.start,
            end: cross.end,
            drift: TintFlowMotion.currentShearDrift
        )
        current.add(
            Self.pointDrift(
                keyPath: "startPoint",
                from: shear.startFrom,
                to: shear.startTo,
                period: TintFlowMotion.currentShearPeriod
            ),
            forKey: Self.currentStartKey
        )
        current.add(
            Self.pointDrift(
                keyPath: "endPoint",
                from: shear.endFrom,
                to: shear.endTo,
                period: TintFlowMotion.currentShearPeriod
            ),
            forKey: Self.currentEndKey
        )
        current.add(
            Self.locationsDrift(
                from: TintFlowMotion.currentLocations(phase: -1),
                to: TintFlowMotion.currentLocations(phase: 1),
                period: TintFlowMotion.currentPeriod
            ),
            forKey: Self.currentTravelKey
        )

        // The ripple: centre and radius handle gliding on two periods, which
        // is what turns two straight autoreversing lines into a crossing,
        // effectively non-repeating wander.
        ripple.add(
            Self.pointDrift(
                keyPath: "startPoint",
                from: TintFlowMotion.rippleCenterFrom,
                to: TintFlowMotion.rippleCenterTo,
                period: TintFlowMotion.ripplePeriod
            ),
            forKey: Self.rippleCenterKey
        )
        ripple.add(
            Self.pointDrift(
                keyPath: "endPoint",
                from: TintFlowMotion.rippleRadiusFrom,
                to: TintFlowMotion.rippleRadiusTo,
                period: TintFlowMotion.rippleRadiusPeriod
            ),
            forKey: Self.rippleRadiusKey
        )

        guard breathing else { return }
        // The opt-in breath acts on the container, so the three layers
        // breathe as one surface rather than three surfaces flickering
        // against each other.
        field.add(Self.breath(depth: breathDepth), forKey: Self.breathKey)
        field.add(Self.breathSwell(depth: breathDepth), forKey: Self.breathSwellKey)
    }

    @objc private func windowOcclusionStateDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == self.window else {
            return
        }
        windowOcclusionChanged(visible: window.occlusionState.contains(.visible))
    }

    /// The field pauses whenever its window is fully occluded, the way every
    /// other at-rest motion in the app stops when nothing can see it. Layer
    /// speed zero freezes the render-server animations in place — time is
    /// hierarchical, so one speed on the container stops all three layers —
    /// and restoring speed resumes them from the same phase.
    func windowOcclusionChanged(visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.speed = Self.layerSpeed(visible: visible)
        CATransaction.commit()
    }

    /// The occlusion gate, stated as a pure function so it is a test.
    nonisolated static func layerSpeed(visible: Bool) -> Float {
        visible ? 1 : 0
    }

    // MARK: - Test seams

    /// The container's current clock speed — the occlusion receipt.
    var fieldSpeedForTesting: Float { field.speed }

    /// The animation keys currently armed, per layer, for the receipts that
    /// pin what runs, at what period, under which cap.
    func animationsForTesting() -> [String: CAAnimation] {
        var found: [String: CAAnimation] = [:]
        for (layer, keys) in [
            (swell, [Self.swellStartKey, Self.swellEndKey, Self.swellFoldKey]),
            (current, [Self.currentStartKey, Self.currentEndKey, Self.currentTravelKey]),
            (ripple, [Self.rippleCenterKey, Self.rippleRadiusKey]),
            (field, [Self.breathKey, Self.breathSwellKey]),
        ] as [(CALayer, [String])] {
            for key in keys {
                if let animation = layer.animation(forKey: key) {
                    found[key] = animation
                }
            }
        }
        return found
    }

    static let swellStartKey = "kaisola.tint-field.swell.start"
    static let swellEndKey = "kaisola.tint-field.swell.end"
    static let swellFoldKey = "kaisola.tint-field.swell.fold"
    static let currentStartKey = "kaisola.tint-field.current.start"
    static let currentEndKey = "kaisola.tint-field.current.end"
    static let currentTravelKey = "kaisola.tint-field.current.travel"
    static let rippleCenterKey = "kaisola.tint-field.ripple.center"
    static let rippleRadiusKey = "kaisola.tint-field.ripple.radius"
    static let breathKey = "kaisola.tint-flow.breath"
    static let breathSwellKey = "kaisola.tint-flow.swell"

    /// Every field animation runs at the same watch-hand calm: autoreversing,
    /// eased, phase-anchored to the wall clock so the project rail, file rail
    /// and canvas — three instances of this field — move together instead of
    /// showing a slowly walking step at their seams. Motion this slow needs
    /// single-digit frame rates; an uncapped animation would hold a ProMotion
    /// display off its idle refresh for sub-pixel movement.
    private static func calm(
        _ animation: CABasicAnimation,
        period: TimeInterval
    ) -> CABasicAnimation {
        animation.duration = period
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        animation.timeOffset = CACurrentMediaTime()
            .truncatingRemainder(dividingBy: period * 2)
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: 5,
            maximum: 15,
            preferred: 10
        )
        return animation
    }

    private static func pointDrift(
        keyPath: String,
        from: CGPoint,
        to: CGPoint,
        period: TimeInterval
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = NSValue(point: from)
        animation.toValue = NSValue(point: to)
        return calm(animation, period: period)
    }

    private static func locationsDrift(
        from: [Double],
        to: [Double],
        period: TimeInterval
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = from.map { NSNumber(value: $0) }
        animation.toValue = to.map { NSNumber(value: $0) }
        return calm(animation, period: period)
    }

    /// The breath's sharper-than-`easeInEaseOut` S curve: more dwell at the
    /// extremes, a quicker transit between them, which is what lets a shallow
    /// change register at all without raising its depth.
    private static var breathTiming: CAMediaTimingFunction {
        let points = TintFlowMotion.breathTimingControlPoints
        return CAMediaTimingFunction(
            controlPoints: points.0, points.1, points.2, points.3
        )
    }

    /// The opt-in breath: whole-field opacity easing between the floor and 1.
    /// Same render-server ownership, frame-rate cap, occlusion freeze and
    /// wall-clock phase lock as the field. `depth` deepens the swing for the
    /// Vivid/Bold intensities; the floor can never drop below half opacity
    /// whatever the multiplier.
    private static func breath(depth: Double = 1) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = max(0.5, 1 - TintFlowMotion.breathAmplitude * max(0, depth))
        animation.toValue = 1
        _ = calm(animation, period: TintFlowMotion.breathPeriod)
        animation.timingFunction = breathTiming
        return animation
    }

    /// The breath's paired swell: the whole field scaling a few percent about
    /// its centre on its own, longer period. Opacity alone reads as a dimmer;
    /// opacity plus a slow swell reads as a surface that is alive. The scale
    /// never goes below 1, so the field only ever over-covers its bounds —
    /// clipping crops overflow rather than exposing a gap.
    private static func breathSwell(depth: Double = 1) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.0
        animation.toValue = 1.0 + TintFlowMotion.breathScaleAmplitude * max(0, depth)
        _ = calm(animation, period: TintFlowMotion.breathScalePeriod)
        animation.timingFunction = breathTiming
        return animation
    }
}
