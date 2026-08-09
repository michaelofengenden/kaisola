import AppKit
import SwiftUI
import XCTest
@testable import Kaisola

/// The account row's signed-out migration notice. It used to be raw `.orange`
/// caption text on the light Settings card, which reads at about 2:1 — the
/// copy that explains why a saved session disappeared was the least legible
/// text on the surface.
final class AppAccountRecoveryNoticeTests: XCTestCase {
    private let notice = AppAccountRecoveryNotice(
        title: "Sign in again to finish the upgrade",
        message: "Kaisola is now Developer ID signed. Sign in once to create a stable saved session for this and future updates."
    )

    // MARK: - Contrast

    private func relativeLuminance(_ hex: UInt32) -> Double {
        let channels = [16, 8, 0].map { shift -> Double in
            let channel = Double((hex >> UInt32(shift)) & 0xFF) / 255
            return channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private func contrastRatio(_ foreground: UInt32, _ background: UInt32) -> Double {
        let first = relativeLuminance(foreground)
        let second = relativeLuminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    func testNoticeUsesTheSharedWarningToneRatherThanRawSystemOrange() {
        XCTAssertEqual(notice.tone, .needsYou)
        XCTAssertEqual(notice.palette, KaisolaStatusTone.needsYou.palette)
    }

    func testNoticeClearsSmallTextContrastInBothAppearances() {
        XCTAssertGreaterThanOrEqual(
            contrastRatio(notice.palette.foreground.light, notice.palette.background.light),
            4.5,
            "the light recovery notice is below WCAG AA for small text"
        )
        XCTAssertGreaterThanOrEqual(
            contrastRatio(notice.palette.foreground.dark, notice.palette.background.dark),
            4.5,
            "the dark recovery notice is below WCAG AA for small text"
        )

        // The measurement is only worth having if it rejects what shipped.
        // System orange on the light Settings card is the case the fixture
        // caught, at roughly 2:1. (Its dark counterpart passes on ratio alone,
        // which is why ratio is not the only assertion in this file.)
        XCTAssertLessThan(contrastRatio(0xFF9500, 0xF2F2F7), 3)
    }

    /// Every supported material and wallpaper combination comes down to one
    /// question: can anything behind the window reach the text? It cannot. The
    /// strip paints its own fully opaque fill, so the ratio asserted above is
    /// the ratio on screen rather than a best case over clear glass.
    func testNoticeFillIsOpaqueInBothAppearancesSoTheWallpaperCannotReachTheText() {
        let cases: [(NSAppearance.Name, UInt32, UInt32)] = [
            (.aqua, notice.palette.foreground.light, notice.palette.background.light),
            (.darkAqua, notice.palette.foreground.dark, notice.palette.background.dark),
        ]
        for (name, expectedForeground, expectedBackground) in cases {
            guard let appearance = NSAppearance(named: name) else {
                return XCTFail("no \(name.rawValue) appearance")
            }
            appearance.performAsCurrentDrawingAppearance {
                let background = NSColor(notice.tone.backgroundColor).usingColorSpace(.sRGB)
                let foreground = NSColor(notice.tone.foregroundColor).usingColorSpace(.sRGB)
                XCTAssertEqual(background?.alphaComponent ?? 0, 1, accuracy: 0.001, "\(name.rawValue) fill is translucent")
                XCTAssertEqual(foreground?.alphaComponent ?? 0, 1, accuracy: 0.001, "\(name.rawValue) text is translucent")
                assertMatches(background, expectedBackground, "\(name.rawValue) fill")
                assertMatches(foreground, expectedForeground, "\(name.rawValue) text")
            }
        }
    }

    private func assertMatches(_ color: NSColor?, _ hex: UInt32, _ label: String) {
        guard let color else { return XCTFail("\(label) did not resolve to sRGB") }
        let expected = [16, 8, 0].map { CGFloat((hex >> UInt32($0)) & 0xFF) / 255 }
        XCTAssertEqual(color.redComponent, expected[0], accuracy: 0.02, "\(label) red")
        XCTAssertEqual(color.greenComponent, expected[1], accuracy: 0.02, "\(label) green")
        XCTAssertEqual(color.blueComponent, expected[2], accuracy: 0.02, "\(label) blue")
    }

    // MARK: - Non-colour cue

    func testNoticeCarriesANonColourCue() {
        XCTAssertFalse(notice.systemImage.isEmpty, "the notice has no non-colour cue")
        XCTAssertNotNil(
            NSImage(systemSymbolName: notice.systemImage, accessibilityDescription: nil),
            "\(notice.systemImage) is not a resolvable SF Symbol"
        )
    }

    func testIncreaseContrastStrengthensTheNoticeBorderRatherThanItsFill() {
        XCTAssertGreaterThan(
            notice.borderOpacity(increasedContrast: true),
            notice.borderOpacity(increasedContrast: false),
            "Increase Contrast does not harden the notice edge"
        )
        XCTAssertGreaterThan(
            notice.borderWidth(increasedContrast: true),
            notice.borderWidth(increasedContrast: false)
        )
        XCTAssertEqual(notice.borderWidth(increasedContrast: false), KaisolaVisualSystem.hairline)
        // The fill is what carries the 4.5:1, so it must not move with the
        // setting — otherwise the ratios asserted above stop describing it.
        XCTAssertEqual(notice.palette, KaisolaStatusTone.needsYou.palette)
    }

    // MARK: - VoiceOver

    func testNoticeSpeaksAsOneCoherentSentence() {
        let label = notice.accessibilityLabel
        XCTAssertTrue(
            label.hasPrefix("Kaisola account needs you."),
            "the label does not lead with the shared status word: \(label)"
        )
        XCTAssertTrue(label.contains(notice.title), "the label drops the headline")
        XCTAssertTrue(label.contains(notice.message), "the label drops the explanation")
        XCTAssertFalse(label.contains("\n"), "the label is not a single spoken run")
        XCTAssertFalse(label.contains(".."), "the label double-punctuates a sentence")
        // The headline carries no terminal punctuation of its own, so the
        // label has to supply one or VoiceOver runs it into the explanation.
        XCTAssertTrue(label.contains("\(notice.title). "), "the headline runs into the explanation")
    }

    func testNoticeLabelToleratesCopyThatAlreadyEndsInPunctuation() {
        let punctuated = AppAccountRecoveryNotice(
            title: "Sign in again to finish the upgrade.",
            message: "Sign in once to create a stable saved session."
        )
        XCTAssertFalse(punctuated.accessibilityLabel.contains(".."))
        XCTAssertTrue(punctuated.accessibilityLabel.hasSuffix("stable saved session."))
    }
}
