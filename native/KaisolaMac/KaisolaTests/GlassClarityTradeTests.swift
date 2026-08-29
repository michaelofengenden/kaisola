import XCTest
@testable import Kaisola

/// Clear is the one glass setting that trades text contrast for transparency,
/// and the trade has to be bounded in both directions: it must actually buy
/// transparency, and it must never reach someone who has told the system they
/// need contrast.
final class GlassClarityTradeTests: XCTestCase {
    /// It has to be a real step, not the 11% it used to be — an 0.89 multiplier
    /// is not a visible difference and is why "Clear" did not look clear.
    func testClearIsSubstantiallyThinnerThanBalanced() {
        let clear = GlassClarity.clear.veilScale
        let balanced = GlassClarity.balanced.veilScale
        XCTAssertLessThan(clear, balanced * 0.3, "Clear must be a real step, not a nudge")
        XCTAssertGreaterThan(clear, 0, "…and still a veil, not nothing")
        XCTAssertGreaterThan(GlassClarity.frosted.veilScale, balanced)
    }

    /// Only Clear makes the trade; the other two still meet the full floors.
    func testOnlyClearRelaxesContrast() {
        XCTAssertTrue(GlassClarity.clear.relaxesTextContrast)
        XCTAssertFalse(GlassClarity.balanced.relaxesTextContrast)
        XCTAssertFalse(GlassClarity.frosted.relaxesTextContrast)
    }

    /// Increase Contrast and Reduce Transparency are the user telling the
    /// system that legibility outranks appearance. A preference typed into
    /// Kaisola must never override one typed into System Settings.
    func testAccessibilitySettingsOverrideClear() {
        XCTAssertEqual(
            GlassClarity.clear.resolved(increasedContrast: true, reduceTransparency: false),
            .balanced
        )
        XCTAssertEqual(
            GlassClarity.clear.resolved(increasedContrast: false, reduceTransparency: true),
            .balanced
        )
        XCTAssertEqual(
            GlassClarity.clear.resolved(increasedContrast: true, reduceTransparency: true),
            .balanced
        )
    }

    /// With neither set, the choice stands — the guard must not quietly disable
    /// the feature for everyone.
    func testClearSurvivesWhenNoAccessibilitySettingAsksOtherwise() {
        XCTAssertEqual(
            GlassClarity.clear.resolved(increasedContrast: false, reduceTransparency: false),
            .clear
        )
    }

    /// The other clarities are never rewritten, in either direction.
    func testTheGuardOnlyTouchesClear() {
        for clarity in [GlassClarity.frosted, .balanced] {
            XCTAssertEqual(
                clarity.resolved(increasedContrast: true, reduceTransparency: true),
                clarity
            )
        }
    }

    /// Crisp has to be a real step too: at 18pt over a 210pt sidebar nothing
    /// read as itself, which is why "crisp" changed nothing visible.
    func testCrispIsMeaningfullySharperThanBalanced() {
        XCTAssertLessThan(GlassTexture.crisp.blurPoints, GlassTexture.balanced.blurPoints * 0.25)
        XCTAssertGreaterThan(
            GlassTexture.crisp.blurPoints, 0,
            "still a blur — text behind the window must never be readable through it"
        )
        XCTAssertGreaterThan(GlassTexture.soft.blurPoints, GlassTexture.balanced.blurPoints)
    }

    // MARK: - The idle canvas

    /// A dark idle canvas keeps a whisper of veil — enough to seat the picture in
    /// the app's appearance, and nowhere near enough to be a wash. The floor
    /// side matters too: at every clarity the idle veil must be a real
    /// reduction against the full one, or "translucent when nothing is
    /// mounted" quietly stops being true the way "Clear" once did.
    func testTheDarkIdleVeilIsAWhisperButStillAVeil() {
        for clarity in GlassClarity.allCases {
            let idle = GlassBackdropWash.workspaceIdle(isDark: true, clarity: clarity)
            let full = GlassBackdropWash.workspace(isDark: true, clarity: clarity)
            XCTAssertLessThan(
                idle.baseOpacity, full.baseOpacity * 0.5,
                "dark idle \(clarity) must be a real reduction"
            )
            XCTAssertGreaterThan(idle.baseOpacity, 0, "…and still a veil, not nothing")
        }
        let balanced = GlassBackdropWash.workspaceIdle(isDark: true, clarity: .balanced)
        XCTAssertGreaterThanOrEqual(
            balanced.desktopTransmission, 0.85,
            "an idle balanced dark canvas must pass at least 85% of the desktop"
        )
    }

    /// Accessibility outranks idleness, and the painted source must wait for
    /// its clear still rather than show a washed one under a whisper veil.
    func testIdleGlassNeverReachesAccessibilityUsers() {
        XCTAssertFalse(WorkspaceBackdropView.idleGlassEngages(
            idle: true, isDark: true, reduceTransparency: true, increasedContrast: false,
            paintedSource: true, clearStillAvailable: true
        ))
        XCTAssertFalse(WorkspaceBackdropView.idleGlassEngages(
            idle: true, isDark: true, reduceTransparency: false, increasedContrast: true,
            paintedSource: true, clearStillAvailable: true
        ))
        XCTAssertFalse(WorkspaceBackdropView.idleGlassEngages(
            idle: false, isDark: true, reduceTransparency: false, increasedContrast: false,
            paintedSource: true, clearStillAvailable: true
        ))
        XCTAssertFalse(
            WorkspaceBackdropView.idleGlassEngages(
                idle: true, isDark: true, reduceTransparency: false, increasedContrast: false,
                paintedSource: true, clearStillAvailable: false
            ),
            "no clear still yet — the washed branch must mount so its glass layer triggers the bake"
        )
        XCTAssertTrue(WorkspaceBackdropView.idleGlassEngages(
            idle: true, isDark: true, reduceTransparency: false, increasedContrast: false,
            paintedSource: true, clearStillAvailable: true
        ))
        XCTAssertTrue(
            WorkspaceBackdropView.idleGlassEngages(
                idle: true, isDark: true, reduceTransparency: false, increasedContrast: false,
                paintedSource: false, clearStillAvailable: false
            ),
            "the live source has no still to wait for"
        )
        XCTAssertFalse(
            WorkspaceBackdropView.idleGlassEngages(
                idle: true, isDark: false, reduceTransparency: false, increasedContrast: false,
                paintedSource: false, clearStillAvailable: false
            ),
            "light idle canvas must keep the same white frost as the occupied canvas"
        )
    }

    /// Idle means *nothing* is over the canvas. Every mounted surface puts
    /// text over the backdrop the wash's floors are solved for, so every one
    /// of them disqualifies.
    func testTheCanvasIsIdleOnlyWhenNothingIsMounted() {
        XCTAssertTrue(NativeWorkspaceChrome.canvasIsIdle(
            layoutIsEmpty: true, hasRecovery: false, browserMounted: false,
            previewMounted: false, filesRailVisible: false
        ))
        XCTAssertFalse(NativeWorkspaceChrome.canvasIsIdle(
            layoutIsEmpty: false, hasRecovery: false, browserMounted: false,
            previewMounted: false, filesRailVisible: false
        ))
        XCTAssertFalse(NativeWorkspaceChrome.canvasIsIdle(
            layoutIsEmpty: true, hasRecovery: true, browserMounted: false,
            previewMounted: false, filesRailVisible: false
        ))
        XCTAssertFalse(NativeWorkspaceChrome.canvasIsIdle(
            layoutIsEmpty: true, hasRecovery: false, browserMounted: true,
            previewMounted: false, filesRailVisible: false
        ))
        XCTAssertFalse(NativeWorkspaceChrome.canvasIsIdle(
            layoutIsEmpty: true, hasRecovery: false, browserMounted: false,
            previewMounted: true, filesRailVisible: false
        ))
        XCTAssertFalse(NativeWorkspaceChrome.canvasIsIdle(
            layoutIsEmpty: true, hasRecovery: false, browserMounted: false,
            previewMounted: false, filesRailVisible: true
        ))

        // The "Start a session" chooser counts as mounted (2026-08-28). It
        // brings its own material, so this was never a legibility question —
        // it is that the graduated rails carry the CANVAS recipe, so an idle
        // middle went flat between two tinted rails exactly when the chooser
        // was up.
        XCTAssertFalse(NativeWorkspaceChrome.canvasIsIdle(
            layoutIsEmpty: true, hasRecovery: false, browserMounted: false,
            previewMounted: false, filesRailVisible: false,
            sessionChooserMounted: true
        ))
        // …and the genuinely empty canvas — no project, nothing offered — is
        // still idle, which is what the state was always describing.
        XCTAssertTrue(NativeWorkspaceChrome.canvasIsIdle(
            layoutIsEmpty: true, hasRecovery: false, browserMounted: false,
            previewMounted: false, filesRailVisible: false,
            sessionChooserMounted: false
        ))
    }

    /// The clear still has to be the wallpaper, not the bake: same brightness
    /// as the picture, same chroma as the picture. If either drifts toward the
    /// legibility pipeline's targets, the idle canvas is showing a managed
    /// surface again — which is the exact regression this feature exists to
    /// end.
    func testTheClearStillIsTheWallpaperNotTheBake() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-clear-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A saturated blue gradient: bright enough that the dark bake must move
        // it a long way, and coloured enough that the chroma damping is visible.
        let side = 256
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in 0..<side {
            let ramp = 0.55 + 0.9 * Double(y) / Double(side - 1)
            context.setFillColor(
                red: min(1, 0.263 * ramp), green: min(1, 0.476 * ramp),
                blue: min(1, 0.575 * ramp), alpha: 1
            )
            context.fill(CGRect(x: 0, y: y, width: side, height: 1))
        }
        let source = try XCTUnwrap(context.makeImage())
        let url = directory.appending(path: "wallpaper.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        func channels(_ image: CGImage) -> (red: Double, green: Double, blue: Double) {
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            var sums = (red: 0.0, green: 0.0, blue: 0.0)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                sums.red += Double(pixels[index]) / 255
                sums.green += Double(pixels[index + 1]) / 255
                sums.blue += Double(pixels[index + 2]) / 255
            }
            let count = Double(width * height)
            return (sums.red / count, sums.green / count, sums.blue / count)
        }
        func luma(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
            rgb.red * 0.2126 + rgb.green * 0.7152 + rgb.blue * 0.0722
        }
        func spread(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
            max(rgb.red, rgb.green, rgb.blue) - min(rgb.red, rgb.green, rgb.blue)
        }

        let sourceChannels = channels(source)
        let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: true)
        let bake = try XCTUnwrap(DesktopBackdropRenderer.renderBake(key: key))
        guard case .wallpaper = bake.painting else {
            return XCTFail("the fixture produced no wallpaper painting")
        }
        let clear = try XCTUnwrap(bake.clearStill, "a wallpaper painting must carry its clear still")
        let clearChannels = channels(clear)
        let baked: CGImage
        guard case let .wallpaper(image, _, _) = bake.painting else { return }
        baked = image
        let bakedChannels = channels(baked)

        // Brightness: the clear still stays at the picture's own level; the
        // dark bake, by design, does not.
        XCTAssertEqual(
            luma(clearChannels), luma(sourceChannels), accuracy: 0.05,
            "the clear still moved the wallpaper's brightness"
        )
        XCTAssertLessThan(
            luma(bakedChannels), luma(sourceChannels) - 0.15,
            "sanity: the dark bake should be normalizing this bright fixture down"
        )
        // Chroma: the clear still carries exactly its declared damp — less
        // saturated than the wallpaper by `clearStillSaturation`, and still
        // meaningfully more colourful than the washed dark bake.
        XCTAssertEqual(
            spread(clearChannels),
            spread(sourceChannels) * DesktopBackdropRenderer.clearStillSaturation,
            accuracy: spread(sourceChannels) * 0.08,
            "the clear still's chroma departed from its declared damp"
        )
        XCTAssertGreaterThan(
            spread(clearChannels), spread(sourceChannels) * 0.6,
            "…and must never slide toward the washed bake's half-chroma"
        )
    }
}
