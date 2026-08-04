import XCTest
@testable import Kaisola

/// How much colour a wallpaper is judged to have.
///
/// The measure used to be a plain mean of per-pixel saturation, which answers
/// "how colourful is the typical pixel". For real desktops that is usually "not
/// at all", and the one colour a person would actually name gets averaged away.
final class DesktopChromaMeasureTests: XCTestCase {
    private typealias Pixel = (red: Double, green: Double, blue: Double)

    private func mean(_ pixels: [Pixel]) -> Double {
        pixels.reduce(0.0) { total, pixel in
            let peak = max(pixel.red, max(pixel.green, pixel.blue))
            let base = min(pixel.red, min(pixel.green, pixel.blue))
            return total + (peak > 0.004 ? (peak - base) / peak : 0)
        } / Double(max(pixels.count, 1))
    }

    /// A grey desktop has no colour to find, so it must still measure zero —
    /// otherwise the weighting would be inventing a hue rather than locating
    /// one, and every neutral wallpaper would acquire a tint.
    func testAGreyDesktopMeasuresZero() {
        let grey: [Pixel] = (0..<100).map { index in
            let value = Double(index) / 100
            return (value, value, value)
        }
        XCTAssertEqual(DesktopBackdropRenderer.characteristicSaturation(grey), 0, accuracy: 1e-9)
    }

    /// A uniformly coloured desktop measures exactly its own saturation, so
    /// wallpapers that already worked are not pushed further.
    func testAUniformlyColouredDesktopIsUnchanged() {
        // HSV saturation 0.5: peak 1.0, base 0.5.
        let uniform: [Pixel] = Array(repeating: (1.0, 0.5, 0.5), count: 50)
        XCTAssertEqual(
            DesktopBackdropRenderer.characteristicSaturation(uniform),
            0.5,
            accuracy: 1e-9
        )
        XCTAssertEqual(mean(uniform), 0.5, accuracy: 1e-9, "the mean agrees when colour is spread evenly")
    }

    /// Michael's wallpaper, in miniature: near-black basalt with green moss on
    /// a small share of its ridges. The mean calls this picture grey; a person
    /// asked to describe it says "green".
    ///
    /// The thresholds below are derived from this fixture, not guessed — rock
    /// sits at 0.048 saturation and moss at 0.778, so a 95/5 split averages to
    /// 0.084 while the weighted measure finds 0.176.
    ///
    /// That was 0.385 when the weight was squared. Squaring found more of the
    /// moss and also amplified a residual hue dependence enough to break the
    /// invariance round 8 established, so `concentrationExponent` was softened
    /// to 0.5 — see its own note. Twice the mean is still the difference
    /// between reading this picture as grey and reading it as green.
    func testMossOnBasaltIsFoundRatherThanAveragedAway() {
        var pixels: [Pixel] = Array(repeating: (0.100, 0.102, 0.105), count: 95)  // basalt
        pixels.append(contentsOf: Array(repeating: (0.35, 0.72, 0.16), count: 5))  // moss

        let averaged = mean(pixels)
        let characteristic = DesktopBackdropRenderer.characteristicSaturation(pixels)

        XCTAssertEqual(averaged, 0.084, accuracy: 0.002, "the mean genuinely reads this as grey")
        XCTAssertEqual(characteristic, 0.176, accuracy: 0.002, "the green survives the measure")
        XCTAssertGreaterThan(
            characteristic / averaged,
            2,
            "a concentrated colour must read markedly stronger than its average"
        )
    }

    /// The weighting can only ever raise a reading, never lower one — so no
    /// wallpaper loses colour it previously had.
    func testTheMeasureNeverFallsBelowTheMean() {
        let cases: [[Pixel]] = [
            [(0.9, 0.2, 0.2), (0.2, 0.2, 0.2), (0.5, 0.5, 0.1)],
            [(0.4, 0.4, 0.42), (0.02, 0.9, 0.4)],
            Array(repeating: (0.6, 0.3, 0.9), count: 7),
        ]
        for pixels in cases {
            XCTAssertGreaterThanOrEqual(
                DesktopBackdropRenderer.characteristicSaturation(pixels) + 1e-9,
                mean(pixels)
            )
        }
    }

    /// Black pixels carry no hue at any saturation, so they must not be counted
    /// as evidence either way.
    func testBlackPixelsAreIgnoredRatherThanCountedAsGrey() {
        let withBlack: [Pixel] = Array(repeating: (0, 0, 0), count: 90)
            + Array(repeating: (1.0, 0.4, 0.4), count: 10)
        let withoutBlack: [Pixel] = Array(repeating: (1.0, 0.4, 0.4), count: 10)
        XCTAssertEqual(
            DesktopBackdropRenderer.characteristicSaturation(withBlack),
            DesktopBackdropRenderer.characteristicSaturation(withoutBlack),
            accuracy: 1e-9
        )
    }

    func testAnEmptyProbeMeasuresZero() {
        XCTAssertEqual(DesktopBackdropRenderer.characteristicSaturation([]), 0)
    }
}
