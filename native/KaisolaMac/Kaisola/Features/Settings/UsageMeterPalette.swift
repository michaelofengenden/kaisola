import SwiftUI

/// The colour a usage meter takes at a given fill.
///
/// This replaced three flat buckets — system green, system orange, system red —
/// which is the stoplight every dashboard has used since about 2012 and reads
/// as a warning light rather than an instrument. Michael: "I'd like usage not
/// to have those generic 2022 color scheme… this should reflect [modern
/// systems]."
///
/// Two changes carry that. The hue is **continuous** rather than bucketed, so a
/// meter at 61% and one at 59% no longer look like different categories of
/// problem — the bar moves through the ramp as the number does, which is how a
/// gauge behaves and how a traffic light does not. And the ramp itself runs
/// cool to warm — teal, lime, amber, rose — so "plenty left" reads as calm
/// rather than as a green pass mark, and "nearly gone" reads as heat rather
/// than as an error.
///
/// Deliberately not the system semantic colours: those are tuned to shout, and
/// carry an alert's meaning. A limit at 90% is a fact, not a failure.
enum UsageMeterPalette {
    /// The ramp, as (fill, colour) stops. Lightness is held close across the
    /// stops so the bar's *brightness* does not read as a second signal
    /// competing with its length.
    static let stops: [(at: Double, color: RGB)] = [
        (0.00, RGB(0.18, 0.83, 0.75)),  // teal
        (0.50, RGB(0.55, 0.86, 0.35)),  // lime
        (0.78, RGB(0.98, 0.75, 0.16)),  // amber
        (1.00, RGB(0.98, 0.36, 0.48)),  // rose
    ]

    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    /// The colour at `fraction`, interpolated between the two stops it lies
    /// between. Pure, so the ramp is testable without rendering.
    static func rgb(for fraction: Double) -> RGB {
        let value = min(max(fraction, 0), 1)
        guard let last = stops.last else { return RGB(0.5, 0.5, 0.5) }
        if value <= stops[0].at { return stops[0].color }
        if value >= last.at { return last.color }

        for index in 1..<stops.count {
            let upper = stops[index]
            guard value <= upper.at else { continue }
            let lower = stops[index - 1]
            let span = upper.at - lower.at
            let t = span > 0 ? (value - lower.at) / span : 0
            return RGB(
                lower.color.red + (upper.color.red - lower.color.red) * t,
                lower.color.green + (upper.color.green - lower.color.green) * t,
                lower.color.blue + (upper.color.blue - lower.color.blue) * t
            )
        }
        return last.color
    }

    static func color(for fraction: Double) -> Color { rgb(for: fraction).color }

    /// The fill itself carries a gradient from slightly deeper at the origin to
    /// the full colour at the tip, which gives the bar a light source and stops
    /// it reading as a flat block of paint.
    static func fill(for fraction: Double) -> LinearGradient {
        let tip = rgb(for: fraction)
        let origin = RGB(tip.red * 0.72, tip.green * 0.72, tip.blue * 0.72)
        return LinearGradient(
            colors: [origin.color, tip.color],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
