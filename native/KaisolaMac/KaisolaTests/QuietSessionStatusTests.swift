import XCTest
@testable import Kaisola

final class QuietSessionStatusTests: XCTestCase {
    func testTerminalDerivation() {
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .working, exited: false, hasAttention: false, respondedAcknowledged: false), .working)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .working, exited: true, hasAttention: false, respondedAcknowledged: false), .ended)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .responded(at: 5), exited: false, hasAttention: false, respondedAcknowledged: false), .doneUnseen)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .responded(at: 5), exited: false, hasAttention: false, respondedAcknowledged: true), .idle)
        // attention (bell / permission) outranks everything on a live terminal
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .working, exited: false, hasAttention: true, respondedAcknowledged: false), .needsYou)
        XCTAssertEqual(QuietSessionStatus.terminal(activity: .idle, exited: false, hasAttention: false, respondedAcknowledged: false), .idle)
    }

    func testChatDerivation() {
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: true, isConnected: true, hasPendingPermission: false, hasAttention: false, statusMessage: nil), .working)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: true, isConnected: true, hasPendingPermission: true, hasAttention: false, statusMessage: nil), .needsYou)
        // Contract change: a disconnected chat is `.ended` regardless of the
        // status message. AcpConversation publishes a message on clean exits
        // too, so `statusMessage != nil` used to paint every finished chat red.
        // `.failed` is deliberately produced by no derivation today.
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: false, hasPendingPermission: false, hasAttention: false, statusMessage: "agent exited"), .ended)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: false, hasPendingPermission: false, hasAttention: false, statusMessage: nil), .ended)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: true, hasPendingPermission: false, hasAttention: true, statusMessage: nil), .needsYou)
        XCTAssertEqual(QuietSessionStatus.chat(isRunning: false, isConnected: true, hasPendingPermission: false, hasAttention: false, statusMessage: nil), .idle)
    }

    func testMeshDerivation() {
        XCTAssertEqual(QuietSessionStatus.mesh(stageIsIdle: false, hasAttention: false), .working)
        XCTAssertEqual(QuietSessionStatus.mesh(stageIsIdle: true, hasAttention: true), .needsYou)
        XCTAssertEqual(QuietSessionStatus.mesh(stageIsIdle: true, hasAttention: false), .idle)
    }

    func testDotPresence() {
        XCTAssertNil(QuietSessionStatus.idle.accessibilityWord)
        XCTAssertNil(QuietSessionStatus.ended.accessibilityWord)
        XCTAssertEqual(QuietSessionStatus.needsYou.accessibilityWord, "needs you")
        XCTAssertEqual(QuietSessionStatus.working.accessibilityWord, "working")
        XCTAssertEqual(QuietSessionStatus.doneUnseen.accessibilityWord, "done")
        XCTAssertEqual(QuietSessionStatus.failed.accessibilityWord, "failed")
        XCTAssertTrue(QuietSessionStatus.ended.isDimmed)
        XCTAssertFalse(QuietSessionStatus.idle.isDimmed)
    }

    func testSpeakingStatesHaveDistinctNonColourMarkers() {
        let speaking: [QuietSessionStatus] = [.working, .needsYou, .doneUnseen, .failed]
        let markers = speaking.compactMap(\.markerShape)
        XCTAssertEqual(markers.count, speaking.count)
        XCTAssertEqual(Set(markers.map(\.rawValue)).count, speaking.count)
        XCTAssertNil(QuietSessionStatus.idle.markerShape)
        XCTAssertNil(QuietSessionStatus.ended.markerShape)
    }

    // MARK: - Dot palette

    private func channels(_ hex: UInt32) -> (r: Int, g: Int, b: Int) {
        (Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF))
    }

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

    func testFilledStatusBadgesClearSmallTextContrastInBothAppearances() {
        for tone in KaisolaStatusTone.allCases {
            let palette = tone.palette
            XCTAssertGreaterThanOrEqual(
                contrastRatio(palette.foreground.light, palette.background.light),
                4.5,
                "\(tone) light badge is below WCAG AA"
            )
            XCTAssertGreaterThanOrEqual(
                contrastRatio(palette.foreground.dark, palette.background.dark),
                4.5,
                "\(tone) dark badge is below WCAG AA"
            )
        }
    }

    /// The v1.1.6 complaint: at 6pt, "still working" and "finished" were the
    /// same dot. Working was an olive one hue-step from done's green. It is now
    /// blue, and the two are asserted apart on the one axis that matters at
    /// that size — which channel dominates.
    func testWorkingIsBlueAndDoneIsGreen() {
        for hex in [QuietStatusPalette.working.light, QuietStatusPalette.working.dark] {
            let c = channels(hex)
            XCTAssertGreaterThan(c.b, c.r, "working is not blue-dominant")
            XCTAssertGreaterThan(c.b, c.g, "working is not blue-dominant")
            XCTAssertGreaterThan(c.b - max(c.r, c.g), 60, "working's blue is not decisive at 6pt")
        }
        for hex in [QuietStatusPalette.doneUnseen.light, QuietStatusPalette.doneUnseen.dark] {
            let c = channels(hex)
            XCTAssertGreaterThan(c.g, c.r, "done is not green-dominant")
            XCTAssertGreaterThan(c.g, c.b, "done is not green-dominant")
        }
    }

    /// The rest of the grammar is unchanged, and every state that draws a dot
    /// has to be distinguishable from every other one.
    func testTheFourSpeakingStatesKeepDistinctHues() {
        let needsYou = channels(QuietStatusPalette.needsYou.light)
        XCTAssertGreaterThan(needsYou.r, needsYou.b, "needs-you is not amber")
        XCTAssertGreaterThan(needsYou.g, needsYou.b, "needs-you is not amber")

        let failed = channels(QuietStatusPalette.failed.light)
        XCTAssertGreaterThan(failed.r, failed.g, "failed is not red")
        XCTAssertGreaterThan(failed.r, failed.b, "failed is not red")

        let speaking: [QuietSessionStatus] = [.working, .needsYou, .doneUnseen, .failed]
        let lights = speaking.compactMap { QuietStatusPalette.hexes(for: $0)?.light }
        XCTAssertEqual(Set(lights).count, speaking.count, "two states share a colour")
        for status in speaking {
            XCTAssertNotNil(status.dotColor, "\(status) must draw a dot")
        }
    }

    func testSilentStatesDrawNoDot() {
        XCTAssertNil(QuietStatusPalette.hexes(for: .idle))
        XCTAssertNil(QuietStatusPalette.hexes(for: .ended))
        XCTAssertNil(QuietSessionStatus.idle.dotColor)
        XCTAssertNil(QuietSessionStatus.ended.dotColor)
    }

    /// Dark-mode values are *lifted*, not merely the light ones: a dot tuned
    /// for a white sidebar loses its chroma on a dark one.
    func testDarkVariantsAreLighterThanTheirLightCounterparts() {
        for status in [QuietSessionStatus.working, .needsYou, .doneUnseen, .failed] {
            guard let hexes = QuietStatusPalette.hexes(for: status) else { return XCTFail("no palette") }
            let light = channels(hexes.light)
            let dark = channels(hexes.dark)
            let lightSum = light.r + light.g + light.b
            let darkSum = dark.r + dark.g + dark.b
            XCTAssertGreaterThan(darkSum, lightSum, "\(status)'s dark dot is not lifted")
        }
    }
}
