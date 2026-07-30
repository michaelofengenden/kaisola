import AppKit
import XCTest
@testable import Kaisola

/// Terminal font family/weight resolution: the resolver must never fail, the
/// sentinel must yield a fixed-pitch system face, the family list must be
/// sentinel-first and fixed-pitch only, and every weight choice must map.
@MainActor
final class TerminalFontOptionsTests: XCTestCase {

    // MARK: - resolveFont never fails

    func testResolveFontNeverNilForGarbageFamilyAndWeight() {
        // Return type is non-optional, so "never nil" means: a real, usable font
        // even for nonsense inputs — the system mono fallback, at the given size.
        let font = TerminalFontOptions.resolveFont(
            family: "!!! no such family &&&",
            size: 15,
            weightRaw: "ultra-mega-bold"
        )
        XCTAssertTrue(font.isFixedPitch, "Fallback face must be monospaced")
        XCTAssertEqual(font.pointSize, 15, accuracy: 0.001)
    }

    func testResolveFontHonorsSizeForKnownFamily() {
        let font = TerminalFontOptions.resolveFont(family: "Menlo", size: 17, weightRaw: "regular")
        XCTAssertEqual(font.pointSize, 17, accuracy: 0.001)
        XCTAssertTrue(font.isFixedPitch)
        XCTAssertEqual(font.familyName, "Menlo")
    }

    // MARK: - Sentinel

    func testSentinelResolvesToFixedPitchSystemFace() {
        let font = TerminalFontOptions.resolveFont(
            family: TerminalFontOptions.systemMonoSentinel,
            size: 13,
            weightRaw: "regular"
        )
        XCTAssertTrue(font.isFixedPitch, "System Mono sentinel must be fixed-pitch")
        XCTAssertEqual(font.pointSize, 13, accuracy: 0.001)
    }

    func testEmptyFamilyFallsBackToSystemMono() {
        let font = TerminalFontOptions.resolveFont(family: "   ", size: 13, weightRaw: "regular")
        XCTAssertTrue(font.isFixedPitch)
    }

    // MARK: - Families list

    func testFamiliesListSentinelFirst() {
        let families = TerminalFontOptions.availableMonospaceFamilies()
        XCTAssertEqual(families.first, TerminalFontOptions.systemMonoSentinel)
        // Sentinel appears exactly once (it is prepended, never a real family).
        XCTAssertEqual(families.filter { $0 == TerminalFontOptions.systemMonoSentinel }.count, 1)
    }

    func testFamiliesListContainsMenloAndOnlyFixedPitch() {
        let families = TerminalFontOptions.availableMonospaceFamilies()
        // Menlo ships with every macOS and is monospaced — it must be present.
        XCTAssertTrue(families.contains("Menlo"), "Menlo should be listed")
        // Helvetica ships with every macOS and is proportional — the fixed-pitch
        // filter must exclude it.
        XCTAssertFalse(families.contains("Helvetica"), "Proportional families must be filtered out")

        // Spot-check the filter invariant: every real (non-sentinel) family
        // resolves to a fixed-pitch face.
        for family in families.dropFirst() {
            let font = TerminalFontOptions.resolveFont(family: family, size: 12, weightRaw: "regular")
            XCTAssertTrue(font.isFixedPitch, "\(family) should resolve to a fixed-pitch face")
        }
    }

    // MARK: - Weight mapping

    func testWeightChoicesCoverKnownRaws() {
        XCTAssertEqual(TerminalFontOptions.weightChoices.map(\.raw), ["regular", "medium", "semibold", "bold"])
    }

    func testWeightMappingCoversAllChoices() {
        XCTAssertEqual(TerminalFontOptions.weight(forRaw: "regular"), .regular)
        XCTAssertEqual(TerminalFontOptions.weight(forRaw: "medium"), .medium)
        XCTAssertEqual(TerminalFontOptions.weight(forRaw: "semibold"), .semibold)
        XCTAssertEqual(TerminalFontOptions.weight(forRaw: "bold"), .bold)
        // Unknown tokens degrade to regular so resolution stays total.
        XCTAssertEqual(TerminalFontOptions.weight(forRaw: "nonsense"), .regular)
    }

    func testEveryWeightChoiceResolvesForSentinelAndFamily() {
        for choice in TerminalFontOptions.weightChoices {
            let sentinel = TerminalFontOptions.resolveFont(
                family: TerminalFontOptions.systemMonoSentinel, size: 13, weightRaw: choice.raw
            )
            XCTAssertTrue(sentinel.isFixedPitch, "sentinel @ \(choice.raw) must resolve")
            let menlo = TerminalFontOptions.resolveFont(family: "Menlo", size: 13, weightRaw: choice.raw)
            XCTAssertTrue(menlo.isFixedPitch, "Menlo @ \(choice.raw) must resolve")
        }
    }
}
