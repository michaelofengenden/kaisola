import AppKit
import ImageIO
import XCTest
@testable import Kaisola

/// The shell-spine settings: layout + appearance persist and drive the app,
/// and the View menu carries both toggle groups with the current selection
/// checked.
@MainActor
final class NativePreviewSettingsTests: XCTestCase {
    func testIsolatedFixturesNeverLaunchAutomaticProviderUsageProbes() {
        XCTAssertFalse(RootShellView.shouldAutomaticallyRefreshPlanUsage(
            environment: ["KAISOLA_NATIVE_VISUAL_FIXTURE": "1"]
        ))
        XCTAssertFalse(RootShellView.shouldAutomaticallyRefreshPlanUsage(
            environment: ["KAISOLA_NATIVE_RESOURCE_WORKLOAD": "one-window-streaming"]
        ))
        XCTAssertTrue(RootShellView.shouldAutomaticallyRefreshPlanUsage(environment: [:]))
    }

    func testApplicationTerminationDrainHasABoundedDeadline() {
        XCTAssertEqual(
            KaisolaMacAppDelegate.terminationDrainDeadlineNanoseconds,
            12_000_000_000
        )
    }

    @MainActor
    func testVisualTranscriptCaptureTargetsPresentedSheetInsteadOfDimmedParent() {
        _ = NSApplication.shared
        let root = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_360, height: 860),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        root.beginSheet(sheet)
        defer { root.endSheet(sheet) }

        XCTAssertTrue(NativeVisualCaptureTarget.window(rootedAt: root, surface: "terminal") === root)
        XCTAssertTrue(NativeVisualCaptureTarget.window(rootedAt: root, surface: "terminal-transcript") === sheet)
    }

    func testVisualCaptureRoundsPointGeometryUpToRetinaPixels() {
        XCTAssertEqual(
            NativeVisualCapture.pixelSize(
                contentRect: CGRect(x: 20, y: 30, width: 619.25, height: 659.1),
                pointPixelScale: 2
            ),
            NativeVisualCapture.PixelSize(width: 1_239, height: 1_319)
        )
        XCTAssertEqual(
            NativeVisualCapture.pixelSize(contentRect: .zero, pointPixelScale: 2),
            NativeVisualCapture.PixelSize(width: 1, height: 1)
        )
    }

    func testVisualCaptureMapsAndBoundsAttachedSheetCrop() {
        XCTAssertEqual(
            NativeVisualCapture.cropRect(
                imageSize: CGSize(width: 2_720, height: 1_720),
                parentFrame: CGRect(x: 100, y: 200, width: 1_360, height: 860),
                childFrame: CGRect(x: 594, y: 824, width: 372, height: 196)
            ),
            CGRect(x: 988, y: 80, width: 744, height: 392)
        )
        XCTAssertEqual(
            NativeVisualCapture.cropRect(
                imageSize: CGSize(width: 200, height: 100),
                parentFrame: CGRect(x: 0, y: 0, width: 100, height: 50),
                childFrame: CGRect(x: -10, y: 40, width: 30, height: 20)
            ),
            CGRect(x: 0, y: 0, width: 40, height: 20)
        )
        XCTAssertNil(
            NativeVisualCapture.cropRect(
                imageSize: .zero,
                parentFrame: CGRect(x: 0, y: 0, width: 100, height: 50),
                childFrame: CGRect(x: 10, y: 10, width: 20, height: 20)
            )
        )
    }

    func testVisualCaptureMapsAndBoundsRemoteViewOverlay() {
        XCTAssertEqual(
            NativeVisualCapture.overlayRect(
                imageSize: CGSize(width: 200, height: 100),
                baseScreenFrame: CGRect(x: 100, y: 200, width: 100, height: 50),
                overlayScreenFrame: CGRect(x: 125, y: 210, width: 20, height: 15)
            ),
            CGRect(x: 50, y: 20, width: 40, height: 30)
        )
        XCTAssertEqual(
            NativeVisualCapture.overlayRect(
                imageSize: CGSize(width: 200, height: 100),
                baseScreenFrame: CGRect(x: 100, y: 200, width: 100, height: 50),
                overlayScreenFrame: CGRect(x: 190, y: 240, width: 20, height: 20)
            ),
            CGRect(x: 180, y: 80, width: 20, height: 20)
        )
        XCTAssertNil(
            NativeVisualCapture.overlayRect(
                imageSize: .zero,
                baseScreenFrame: CGRect(x: 100, y: 200, width: 100, height: 50),
                overlayScreenFrame: CGRect(x: 125, y: 210, width: 20, height: 15)
            )
        )
    }

    func testVisualTerminalAccessibilityGateAcceptsRenderedSemanticFixture() throws {
        let value = """
        michael@kaisola Kaisola % swift test
        Test Suite 'KaisolaTests' passed at 08:18.
        michael@kaisola Kaisola % git status --short
        Unicode stays intact: café · 研究 · ✅
        """

        XCTAssertNil(NativeVisualTerminalAccessibilityGate.failure(
            in: value,
            expectedMarkers: try XCTUnwrap(
                NativeVisualTerminalAccessibilityGate.expectedMarkers(for: "terminal-semantic")
            )
        ))
        XCTAssertEqual(
            NativeVisualTerminalAccessibilityGate.expectedMarkers(for: "terminal-scroll-output"),
            ["historical-anchor-"]
        )
    }

    func testVisualTerminalAccessibilityGateRejectsRawControlsMissingTextAndOverflow() {
        let expected = ["swift test"]
        XCTAssertEqual(
            NativeVisualTerminalAccessibilityGate.failure(
                in: "swift test\u{1B}[31m",
                expectedMarkers: expected
            ),
            "terminal-control-scalar"
        )
        XCTAssertEqual(
            NativeVisualTerminalAccessibilityGate.failure(
                in: "git status --short",
                expectedMarkers: expected
            ),
            "missing-marker-swift_test"
        )
        XCTAssertEqual(
            NativeVisualTerminalAccessibilityGate.failure(
                in: String(
                    repeating: "x",
                    count: ReadOnlyTerminalView.accessibilityTailLimit + 1
                ),
                expectedMarkers: []
            ),
            "over-limit-8001"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "kaisola-settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testLayoutAndAppearancePersist() {
        let defaults = makeDefaults()
        let settings = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(settings.navigationLayout, .leftTree)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.sidebarAppearance, .glass)
        XCTAssertEqual(settings.workspaceBackdrop, .glass)
        XCTAssertEqual(settings.terminalPalette, .native)
        XCTAssertTrue(settings.restoreCLIDrafts)
        XCTAssertFalse(settings.semanticShellIntegration)
        XCTAssertEqual(settings.terminalLineSpacing, NativePreviewSettings.terminalLineSpacingDefault)
        XCTAssertEqual(settings.terminalHistoryWarningMiB, NativePreviewSettings.terminalHistoryWarningDefaultMiB)
        XCTAssertTrue(settings.workspaceRailVisible)
        XCTAssertEqual(settings.workspaceRailWidth, NativePreviewSettings.workspaceRailWidthDefault)
        XCTAssertEqual(settings.filePreviewWidth, NativePreviewSettings.filePreviewWidthDefault)

        settings.navigationLayout = .topBar
        settings.appearance = .dark
        settings.sidebarAppearance = .solid
        settings.workspaceBackdrop = .tinted
        settings.terminalPalette = .kaisola
        settings.restoreCLIDrafts = false
        settings.semanticShellIntegration = true
        settings.terminalLineSpacing = 1.18
        settings.terminalHistoryWarningMiB = 2_048
        settings.workspaceRailWidth = 300
        settings.filePreviewWidth = 640

        let reloaded = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(reloaded.navigationLayout, .topBar)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.sidebarAppearance, .solid)
        XCTAssertEqual(reloaded.workspaceBackdrop, .tinted)
        XCTAssertEqual(reloaded.terminalPalette, .kaisola)
        XCTAssertFalse(reloaded.restoreCLIDrafts)
        XCTAssertTrue(reloaded.semanticShellIntegration)
        XCTAssertEqual(reloaded.terminalLineSpacing, 1.18, accuracy: 0.001)
        XCTAssertEqual(reloaded.terminalHistoryWarningMiB, 2_048)
        XCTAssertEqual(reloaded.workspaceRailWidth, 300)
        XCTAssertEqual(reloaded.filePreviewWidth, 640)
    }

    func testProviderRoutingPersistsWithoutTouchingProviderDefaults() {
        let defaults = makeDefaults()
        let settings = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(settings.anthropicBaseURL, "")
        XCTAssertEqual(settings.anthropicModel, "")
        XCTAssertEqual(settings.openAIBaseURL, "")
        XCTAssertEqual(settings.openAIModel, "")

        settings.anthropicBaseURL = "https://claude-gateway.example.test/v1"
        settings.anthropicModel = "claude-sonnet"
        settings.openAIBaseURL = "https://openai-gateway.example.test/v1"
        settings.openAIModel = "gpt-custom"

        let reloaded = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(reloaded.anthropicBaseURL, "https://claude-gateway.example.test/v1")
        XCTAssertEqual(reloaded.anthropicModel, "claude-sonnet")
        XCTAssertEqual(reloaded.openAIBaseURL, "https://openai-gateway.example.test/v1")
        XCTAssertEqual(reloaded.openAIModel, "gpt-custom")
    }

    func testProviderRoutingValidatesAndNormalizesSafeURLs() {
        XCTAssertEqual(
            ProviderRouting.normalizedBaseURL("  https://gateway.example.test/v1///  "),
            "https://gateway.example.test/v1"
        )
        XCTAssertEqual(
            ProviderRouting.normalizedBaseURL("http://localhost:11434/v1/"),
            "http://localhost:11434/v1"
        )
        XCTAssertEqual(
            ProviderRouting.normalizedBaseURL("http://127.0.0.1:8080/v1"),
            "http://127.0.0.1:8080/v1"
        )
        XCTAssertNil(ProviderRouting.normalizedBaseURL("http://remote.example.test/v1"))
        XCTAssertNil(ProviderRouting.normalizedBaseURL("http://127.evil.test/v1"))
        XCTAssertNil(ProviderRouting.normalizedBaseURL("https://key@gateway.example.test/v1"))
        XCTAssertNil(ProviderRouting.normalizedBaseURL("https://gateway.example.test/v1?token=x"))
        XCTAssertNil(ProviderRouting.normalizedBaseURL("https://gateway.example.test/a path"))
        XCTAssertNotNil(ProviderRouting.baseURLIssue("not a URL"))
        XCTAssertNil(ProviderRouting.baseURLIssue(""))
    }

    func testProviderRoutingRejectsInvalidModelsButKeepsOrdinaryIDs() {
        XCTAssertEqual(ProviderRouting.normalizedModel("  gpt-custom-1  "), "gpt-custom-1")
        XCTAssertNil(ProviderRouting.normalizedModel("bad\nmodel"))
        XCTAssertNil(ProviderRouting.normalizedModel(String(repeating: "m", count: 201)))
        XCTAssertNil(ProviderRouting.modelIssue(""))
    }

    func testProviderRoutingBuildsDirectAndCodexACPEnvironment() throws {
        let overlay = ProviderRouting.environmentOverlay(
            anthropicBaseURL: "https://claude.example.test/",
            anthropicModel: "claude-custom",
            openAIBaseURL: "https://openai.example.test/v1/",
            openAIModel: "gpt-custom",
            baseEnvironment: ["CODEX_CONFIG": #"{"sandbox_mode":"read-only"}"#]
        )
        XCTAssertEqual(overlay["ANTHROPIC_BASE_URL"], "https://claude.example.test")
        XCTAssertEqual(overlay["ANTHROPIC_MODEL"], "claude-custom")
        XCTAssertEqual(overlay["OPENAI_BASE_URL"], "https://openai.example.test/v1")
        XCTAssertEqual(overlay["OPENAI_MODEL"], "gpt-custom")

        let data = try XCTUnwrap(overlay["CODEX_CONFIG"]?.data(using: .utf8))
        let config = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(config["sandbox_mode"], "read-only")
        XCTAssertEqual(config["openai_base_url"], "https://openai.example.test/v1")
        XCTAssertEqual(config["model"], "gpt-custom")
    }

    func testProviderRoutingInvalidDraftsNeverReachChildProcesses() {
        let overlay = ProviderRouting.environmentOverlay(
            anthropicBaseURL: "http://remote.example.test",
            anthropicModel: "bad\nmodel",
            openAIBaseURL: "file:///tmp/provider",
            openAIModel: String(repeating: "m", count: 201),
            baseEnvironment: [:]
        )
        XCTAssertTrue(overlay.isEmpty)
    }

    func testCodexTerminalCommandUsesDocumentedOneRunOverrides() {
        XCTAssertEqual(
            ProviderRouting.codexLaunchCommand(
                "codex",
                openAIBaseURL: "https://gateway.example.test/v1/",
                openAIModel: "gpt-custom"
            ),
            "codex --model 'gpt-custom' --config 'openai_base_url=\"https://gateway.example.test/v1\"'"
        )
        XCTAssertEqual(
            ProviderRouting.codexLaunchCommand(
                "codex",
                openAIBaseURL: "http://remote.example.test",
                openAIModel: "bad\nmodel"
            ),
            "codex"
        )
    }

    func testTerminalAppDefaultsRestoreNativeTypographyAndPalette() {
        let defaults = makeDefaults()
        let settings = NativePreviewSettings(defaults: defaults)
        settings.terminalFontSize = 19
        settings.terminalFontFamily = "Menlo"
        settings.terminalFontWeight = "bold"
        settings.terminalLineSpacing = 1.2
        settings.terminalPalette = .kaisola

        settings.applyTerminalAppDefaults()

        XCTAssertEqual(settings.terminalFontSize, 11)
        XCTAssertEqual(settings.terminalFontFamily, TerminalFontOptions.systemMonoSentinel)
        XCTAssertEqual(settings.terminalFontWeight, "regular")
        XCTAssertEqual(settings.terminalLineSpacing, 1)
        XCTAssertEqual(settings.terminalPalette, .native)
    }

    func testNonPersistentSettingsKeepVisualFixturesSideEffectFree() {
        let defaults = makeDefaults()
        let settings = NativePreviewSettings(defaults: defaults, persistsChanges: false)

        settings.navigationLayout = .topBar
        settings.appearance = .dark
        settings.workspaceRailWidth = 284

        let reloaded = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(reloaded.navigationLayout, .leftTree)
        XCTAssertEqual(reloaded.appearance, .system)
        XCTAssertEqual(reloaded.workspaceRailWidth, NativePreviewSettings.workspaceRailWidthDefault)
    }

    func testHostedFixtureEnvironmentsSelectIsolatedNonPersistentSharedSettings() {
        XCTAssertFalse(NativePreviewSettings.shouldPersistChanges(environment: [
            "KAISOLA_NATIVE_VISUAL_FIXTURE": "1",
        ]))
        XCTAssertFalse(NativePreviewSettings.shouldPersistChanges(environment: [
            "KAISOLA_NATIVE_RESOURCE_WORKLOAD": "one-window-streaming-terminal-fresh-broker",
        ]))
        XCTAssertEqual(
            NativePreviewSettings.isolatedFixtureSuiteName(
                environment: ["KAISOLA_NATIVE_VISUAL_FIXTURE": "1"],
                processIdentifier: 42
            ),
            "com.kaisola.mac.visual-fixture.42"
        )
        XCTAssertEqual(
            NativePreviewSettings.isolatedFixtureSuiteName(
                environment: ["KAISOLA_NATIVE_RESOURCE_WORKLOAD": "streaming"],
                processIdentifier: 42
            ),
            "com.kaisola.mac.resource-fixture.42"
        )
        XCTAssertTrue(NativePreviewSettings.shouldPersistChanges(environment: [:]))
        XCTAssertNil(NativePreviewSettings.isolatedFixtureSuiteName(
            environment: [:],
            processIdentifier: 42
        ))
        XCTAssertTrue(NativePreviewSettings.shouldPersistChanges(environment: [
            "KAISOLA_NATIVE_VISUAL_FIXTURE": "0",
        ]))
    }

    func testWorkspaceRailWidthStaysThinAndClamped() {
        XCTAssertEqual(NativePreviewSettings.clampedWorkspaceRailWidth(100), 164)
        XCTAssertEqual(NativePreviewSettings.clampedWorkspaceRailWidth(248), 248)
        XCTAssertEqual(NativePreviewSettings.clampedWorkspaceRailWidth(900), 300)
        XCTAssertEqual(NativePreviewSettings.clampedFilePreviewWidth(100), 300)
        XCTAssertEqual(NativePreviewSettings.clampedFilePreviewWidth(600), 600)
        XCTAssertEqual(NativePreviewSettings.clampedFilePreviewWidth(1_200), 920)
        XCTAssertEqual(NativePreviewSettings.clampedTerminalLineSpacing(0.5), 1.0)
        XCTAssertEqual(NativePreviewSettings.clampedTerminalLineSpacing(1.12), 1.12)
        XCTAssertEqual(NativePreviewSettings.clampedTerminalLineSpacing(2.0), 1.24)
    }

    func testDetailPaneSizingKeepsAllOpenSurfacesInsideNarrowCanvas() {
        let widths = NativeDetailPaneSizing.resolve(
            totalWidth: 602,
            preferredPreview: 480,
            preferredRail: 218
        )
        let occupied = widths.preview + widths.rail
            + 2 * NativeDetailPaneSizing.dividerWidth
            + NativeDetailPaneSizing.minimumContentWidth
        XCTAssertLessThanOrEqual(occupied, 602.001)
        XCTAssertGreaterThanOrEqual(widths.preview, 200)
        XCTAssertGreaterThanOrEqual(widths.rail, 120)
    }

    func testDetailPaneSizingPreservesPreferencesWhenSpaceAllows() {
        let widths = NativeDetailPaneSizing.resolve(
            totalWidth: 1_200,
            preferredPreview: 480,
            preferredRail: 218
        )
        XCTAssertEqual(widths.preview, 480)
        XCTAssertEqual(widths.rail, 218)
        XCTAssertEqual(NativeDetailPaneSizing.dividerWidth, 1)
        XCTAssertEqual(NativeDetailPaneSizing.dividerHitWidth, 17)
    }

    func testVisualChoiceTitlesRemainUserFacing() {
        XCTAssertEqual(SidebarAppearance.glass.title, "Glass")
        XCTAssertEqual(WorkspaceBackdropMode.tinted.title, "Tinted")
        XCTAssertEqual(TerminalPaletteMode.native.title, "macOS Terminal")
    }

    func testGlassBackdropWashIsWhiteLedInLightAndNearBlackInDark() {
        let lightRecipes = [
            GlassBackdropWash.sidebar(isDark: false),
            GlassBackdropWash.workspace(isDark: false),
        ]
        for recipe in lightRecipes {
            XCTAssertEqual(recipe.red, 1)
            XCTAssertEqual(recipe.green, 1)
            XCTAssertEqual(recipe.blue, 1)
        }

        let darkRecipes = [
            GlassBackdropWash.sidebar(isDark: true),
            GlassBackdropWash.workspace(isDark: true),
        ]
        for recipe in darkRecipes {
            // #0B0C12.
            XCTAssertEqual(recipe.red, 11.0 / 255, accuracy: 0.0001)
            XCTAssertEqual(recipe.green, 12.0 / 255, accuracy: 0.0001)
            XCTAssertEqual(recipe.blue, 18.0 / 255, accuracy: 0.0001)
        }

        // The headline coverage. 0.60 in both appearances: frost, not a pane.
        // Two earlier eras both missed, in opposite directions — 0.32/0.44 over
        // near-opaque vibrancy passed no desktop colour at all, and the 0.16
        // that replaced it was calibrated against vibrancy but ended up over a
        // *painted wallpaper*, which passes everything.
        XCTAssertEqual(GlassBackdropWash.sidebar(isDark: false).baseOpacity, 0.60, accuracy: 0.0001)
        XCTAssertEqual(GlassBackdropWash.sidebar(isDark: true).baseOpacity, 0.60, accuracy: 0.0001)
    }

    /// The contract the frost retune exists to hold, and it is two-sided.
    ///
    /// Too much transmission and the surface is a blurred photograph: that was
    /// the bug, a sidebar whose measured channel spread (0.32 average, 0.53
    /// peak) ran *higher* than the desktop beside the window. Too little and it
    /// is the flat #EDEDED panel of the release before that. Frost lives in
    /// between — the desktop's hue arrives, its brightness and its shapes do
    /// not — and only a band expresses that. A one-sided floor is what let the
    /// veil drift to 0.16 without a single test objecting.
    func testGlassVeilsFrostTheDesktopWithoutErasingIt() {
        for isDark in [false, true] {
            for (name, wash) in [
                ("sidebar", GlassBackdropWash.sidebar(isDark: isDark)),
                ("workspace", GlassBackdropWash.workspace(isDark: isDark)),
            ] {
                XCTAssertGreaterThanOrEqual(
                    wash.desktopTransmission,
                    0.30,
                    "\(name) veil (isDark: \(isDark)) hides the desktop it exists to tint"
                )
                XCTAssertLessThanOrEqual(
                    wash.desktopTransmission,
                    0.50,
                    "\(name) veil (isDark: \(isDark)) reads as a photograph, not as glass"
                )
            }
        }
    }


    /// Zero warm or lavender bias: the veil is neutral to the eye, so the only
    /// chroma in the backdrop is whatever the desktop itself contributes.
    func testGlassBackdropWashCarriesNoWarmOrLavenderBias() {
        let recipes = [
            GlassBackdropWash.sidebar(isDark: false),
            GlassBackdropWash.sidebar(isDark: true),
            GlassBackdropWash.workspace(isDark: false),
            GlassBackdropWash.workspace(isDark: true),
        ]

        for recipe in recipes {
            // Never warm: red must not lead blue.
            XCTAssertLessThanOrEqual(recipe.red, recipe.blue)
            // Never lavender: blue may only edge ahead of green by a hair, and
            // green must sit between the two rather than dipping below both.
            XCTAssertLessThanOrEqual(recipe.blue - recipe.green, 0.03)
            XCTAssertGreaterThanOrEqual(recipe.green, recipe.red)
        }
    }

    func testGlassBackdropWashLightsFromAboveAndSeatsTheWorkspaceDeeper() {
        let lightSidebar = GlassBackdropWash.sidebar(isDark: false)
        let darkSidebar = GlassBackdropWash.sidebar(isDark: true)
        let lightWorkspace = GlassBackdropWash.workspace(isDark: false)
        let darkWorkspace = GlassBackdropWash.workspace(isDark: true)

        // Light from above: more white at the top in light mode, less
        // near-black at the top in dark mode. Both lift the top edge.
        XCTAssertGreaterThan(lightSidebar.topOpacity, lightSidebar.baseOpacity)
        XCTAssertGreaterThan(lightSidebar.baseOpacity, lightSidebar.bottomOpacity)
        XCTAssertLessThan(darkSidebar.topOpacity, darkSidebar.baseOpacity)
        XCTAssertLessThan(darkSidebar.baseOpacity, darkSidebar.bottomOpacity)

        // The workspace reads one step deeper than the sidebar so the inset
        // chrome panels have something to float above.
        XCTAssertLessThan(lightWorkspace.baseOpacity, lightSidebar.baseOpacity)
        XCTAssertGreaterThan(darkWorkspace.baseOpacity, darkSidebar.baseOpacity)
    }

    /// Increased Contrast must leave at most 20% of any glass surface showing
    /// wallpaper, on every surface and in both appearances.
    ///
    /// Stated absolutely, because the previous statement — "reproduce the
    /// coverage the pre-halving veil reached with a flat 0.18 overlay on it" —
    /// stopped constraining anything the moment the frost retune raised each
    /// base past that historical composite. All four surfaces then solved to a
    /// negative overlay and collapsed onto the formula's own 0.18 floor, and
    /// the old test still passed, because a base of 0.60 clears a 0.44 floor
    /// with no overlay at all. A floor tied to a past release cannot notice
    /// that; a floor tied to the rendered surface can.
    func testIncreasedContrastCoversAtLeastFourFifthsOfEverySurface() {
        // Two translucent layers stacked with standard "over" compositing
        // combine to `base + overlay * (1 - base)`.
        func composite(base: Double, overlay: Double) -> Double {
            base + overlay * (1 - base)
        }
        let epsilon = 0.0001

        for isDark in [false, true] {
            let appearance = isDark ? "dark" : "light"
            XCTAssertGreaterThanOrEqual(
                composite(
                    base: GlassBackdropWash.sidebar(isDark: isDark).baseOpacity,
                    overlay: GlassBackdropWash.sidebarIncreasedContrastOverlay(isDark: isDark)
                ),
                GlassBackdropWash.increasedContrastCoverage - epsilon,
                "sidebar (\(appearance)) leaves too much wallpaper under Increased Contrast"
            )
            XCTAssertGreaterThanOrEqual(
                composite(
                    base: GlassBackdropWash.workspace(isDark: isDark).baseOpacity,
                    overlay: GlassBackdropWash.workspaceIncreasedContrastOverlay(isDark: isDark)
                ),
                GlassBackdropWash.increasedContrastCoverage - epsilon,
                "workspace (\(appearance)) leaves too much wallpaper under Increased Contrast"
            )
        }
    }

    /// Increased Contrast has to be a *visible* step up from the ordinary veil
    /// and still stop short of an opaque panel — and the exact solution has to
    /// land strictly inside the clamp, or the guarantee above is being met by
    /// the clamp rather than by the arithmetic.
    func testIncreasedContrastOverlayIsASubstantialStepThatNeverClamps() {
        let overlays = [
            GlassBackdropWash.sidebarIncreasedContrastOverlay(isDark: false),
            GlassBackdropWash.sidebarIncreasedContrastOverlay(isDark: true),
            GlassBackdropWash.workspaceIncreasedContrastOverlay(isDark: false),
            GlassBackdropWash.workspaceIncreasedContrastOverlay(isDark: true),
        ]
        for overlay in overlays {
            XCTAssertGreaterThan(overlay, 0.18, "no longer a step up from the old flat constant")
            XCTAssertLessThan(overlay, 0.6, "the 0.6 ceiling is binding, so the floor is not being met")
        }
    }

    /// The floor is a property of the surface, not of these particular
    /// constants: a future veil retune has to re-derive the overlay rather than
    /// inherit a stale one. Exercised at bases either side of today's.
    func testIncreasedContrastOverlayTracksWhateverTheVeilDoes() {
        // A thinner veil must be compensated by a heavier overlay, and the
        // composite must land on the floor either way.
        func requiredOverlay(base: Double) -> Double {
            (GlassBackdropWash.increasedContrastCoverage - base) / (1 - base)
        }
        XCTAssertGreaterThan(requiredOverlay(base: 0.40), requiredOverlay(base: 0.60))
        XCTAssertEqual(
            0.40 + requiredOverlay(base: 0.40) * (1 - 0.40),
            GlassBackdropWash.increasedContrastCoverage,
            accuracy: 0.0001
        )
        // A veil already past the floor needs nothing added.
        XCTAssertLessThanOrEqual(requiredOverlay(base: 0.85), 0)
    }

    // MARK: - Wallpaper-only glass

    /// Glass must read as the *desktop* seen through the window, never as the
    /// other apps stacked behind it, so the painted wallpaper is the default
    /// and live behind-window vibrancy survives only as an explicit choice.
    func testGlassBackdropDefaultsToThePaintedWallpaperSource() {
        let suite = "kaisola-backdrop-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(fresh.glassBackdropSource, .wallpaper)

        fresh.glassBackdropSource = .behindWindow
        XCTAssertEqual(
            NativePreviewSettings(defaults: defaults).glassBackdropSource,
            .behindWindow
        )
        XCTAssertEqual(GlassBackdropSource.wallpaper.title, "Wallpaper")
        XCTAssertEqual(GlassBackdropSource.behindWindow.title, "Live")
    }

    /// `desktopImageURL(for:)` does not fail for a dynamic desktop — it hands
    /// back one fixed stand-in path for every screen. Painting *that* would
    /// show the stock Big Sur picture to a user whose desktop is an aerial, so
    /// the sentinel has to be recognised before it is treated as a wallpaper.
    func testDynamicDesktopsAreRecognisedByTheirStandInPath() {
        XCTAssertTrue(DesktopWallpaperLocator.isDynamicDesktopSentinel(
            URL(fileURLWithPath: DesktopWallpaperLocator.dynamicDesktopSentinelPath)
        ))
        XCTAssertTrue(DesktopWallpaperLocator.isDynamicDesktopSentinel(
            URL(fileURLWithPath: "/System/Library/CoreServices/../CoreServices/DefaultDesktop.heic")
        ))
        XCTAssertFalse(DesktopWallpaperLocator.isDynamicDesktopSentinel(
            URL(fileURLWithPath: "/Users/test/Pictures/ridge.heic")
        ))
    }

    /// The ladder is ordered, and each rung is only paid for when the one above
    /// it came up empty — resolving an aerial reads two files off disk, so a
    /// plain picture desktop must never trigger it.
    func testWallpaperResolutionFallsBackOneRungAtATime() {
        var aerialLookups = 0
        let aerial = URL(fileURLWithPath: "/cache/aerial.png")
        func resolve(_ url: URL?, aerialAvailable: Bool) -> DesktopWallpaperResolution {
            DesktopWallpaperLocator.resolve(
                desktopImageURL: url,
                readableStill: { $0.pathExtension != "mov" },
                aerialStill: {
                    aerialLookups += 1
                    return aerialAvailable ? aerial : nil
                }
            )
        }

        let picture = URL(fileURLWithPath: "/Users/test/Pictures/ridge.heic")
        XCTAssertEqual(resolve(picture, aerialAvailable: true), .picture(picture))
        XCTAssertEqual(aerialLookups, 0, "a readable picture must not touch the wallpaper store")

        let sentinel = URL(fileURLWithPath: DesktopWallpaperLocator.dynamicDesktopSentinelPath)
        XCTAssertEqual(resolve(sentinel, aerialAvailable: true), .aerialStill(aerial))
        XCTAssertEqual(resolve(nil, aerialAvailable: true), .aerialStill(aerial))
        XCTAssertEqual(
            resolve(URL(fileURLWithPath: "/cache/aerial.mov"), aerialAvailable: true),
            .aerialStill(aerial)
        )

        // Last rung: no still anywhere, so the veil sits on the cooled average
        // rather than on whatever windows happen to be behind us.
        XCTAssertEqual(resolve(sentinel, aerialAvailable: false), .unavailable)
        XCTAssertEqual(resolve(nil, aerialAvailable: false), .unavailable)
    }

    /// The store nests a *second*, binary plist inside `Configuration`; the id
    /// only exists in there. `AllSpacesAndDisplays` is the live choice and must
    /// win over the `SystemDefault` copy that sits beside it.
    func testAerialAssetIdentifierIsReadFromTheNestedConfigurationPlist() throws {
        func configuration(_ assetID: String) throws -> Data {
            try PropertyListSerialization.data(
                fromPropertyList: ["assetID": assetID],
                format: .binary,
                options: 0
            )
        }
        func choice(_ assetID: String) throws -> [String: Any] {
            [
                "Linked": [
                    "Content": [
                        "Choices": [
                            [
                                "Provider": "com.apple.wallpaper.choice.aerials",
                                "Configuration": try configuration(assetID),
                            ],
                        ],
                    ],
                ],
            ]
        }
        let index = try PropertyListSerialization.data(
            fromPropertyList: [
                "SystemDefault": try choice("STALE"),
                "AllSpacesAndDisplays": try choice("LIVE"),
            ] as [String: Any],
            format: .binary,
            options: 0
        )
        XCTAssertEqual(DesktopWallpaperLocator.aerialAssetID(indexPlist: index), "LIVE")

        let pictureIndex = try PropertyListSerialization.data(
            fromPropertyList: ["AllSpacesAndDisplays": ["Type": "individual"]] as [String: Any],
            format: .binary,
            options: 0
        )
        XCTAssertNil(DesktopWallpaperLocator.aerialAssetID(indexPlist: pictureIndex))
        XCTAssertNil(DesktopWallpaperLocator.aerialAssetID(indexPlist: Data("not a plist".utf8)))
    }

    /// An aerial desktop is usually a *rotating category*, so no one file is
    /// "the" wallpaper. Pick deterministically — the cache key depends on it —
    /// and only ever from stills macOS has already downloaded, so resolving the
    /// backdrop never reaches the network.
    func testRotatingAerialCategoryResolvesToACachedRepresentativeStill() throws {
        let manifest = try JSONSerialization.data(withJSONObject: [
            "assets": [
                ["id": "first", "categories": ["landscapes"], "preferredOrder": 1],
                ["id": "second", "subcategories": ["landscapes"], "preferredOrder": 2],
                ["id": "third", "categories": ["landscapes"], "preferredOrder": 3],
                ["id": "elsewhere", "categories": ["cityscapes"], "preferredOrder": 0],
            ],
        ])

        XCTAssertEqual(
            DesktopWallpaperLocator.representativeAerialStill(
                assetID: "landscapes",
                manifest: manifest,
                cachedStillIDs: ["first", "second", "third"]
            ),
            "first"
        )
        // The lowest-ordered member is not always downloaded.
        XCTAssertEqual(
            DesktopWallpaperLocator.representativeAerialStill(
                assetID: "landscapes",
                manifest: manifest,
                cachedStillIDs: ["third", "second"]
            ),
            "second"
        )
        // A single pinned aerial resolves to itself without reading a category.
        XCTAssertEqual(
            DesktopWallpaperLocator.representativeAerialStill(
                assetID: "third",
                manifest: manifest,
                cachedStillIDs: ["third"]
            ),
            "third"
        )
        XCTAssertNil(
            DesktopWallpaperLocator.representativeAerialStill(
                assetID: "landscapes",
                manifest: manifest,
                cachedStillIDs: ["elsewhere"]
            )
        )
        XCTAssertNil(
            DesktopWallpaperLocator.representativeAerialStill(
                assetID: "landscapes",
                manifest: Data("{}".utf8),
                cachedStillIDs: ["first"]
            )
        )
    }

    /// Dynamic desktops pack every hour of the day into one HEIC with nothing
    /// labelling the frames; the day frames lead and the night frames trail.
    func testDynamicDesktopFramePicksTheEndMatchingTheAppearance() {
        XCTAssertEqual(DesktopBackdropRenderer.frameIndex(imageCount: 16, isDark: false), 0)
        XCTAssertEqual(DesktopBackdropRenderer.frameIndex(imageCount: 16, isDark: true), 15)
        // A plain picture has exactly one frame in both appearances.
        XCTAssertEqual(DesktopBackdropRenderer.frameIndex(imageCount: 1, isDark: true), 0)
        XCTAssertEqual(DesktopBackdropRenderer.frameIndex(imageCount: 0, isDark: true), 0)
        XCTAssertEqual(DesktopBackdropRenderer.frameIndex(imageCount: -3, isDark: false), 0)
    }

    /// The whole point of pre-rendering is that nothing re-blurs while the app
    /// is idle, so the key has to change on exactly the three things that alter
    /// the picture and on nothing else.
    func testBackdropCacheKeyChangesOnlyWithTheDesktopItDraws() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let key = DesktopBackdropKey(path: "/w.heic", modified: stamp, isDark: false)

        XCTAssertEqual(key, DesktopBackdropKey(path: "/w.heic", modified: stamp, isDark: false))
        XCTAssertNotEqual(key, DesktopBackdropKey(path: "/other.heic", modified: stamp, isDark: false))
        // Same path, replaced contents — "set as wallpaper" over the same file.
        XCTAssertNotEqual(
            key,
            DesktopBackdropKey(path: "/w.heic", modified: stamp.addingTimeInterval(1), isDark: false)
        )
        // Appearance selects a different frame of a dynamic desktop.
        XCTAssertNotEqual(key, DesktopBackdropKey(path: "/w.heic", modified: stamp, isDark: true))
        XCTAssertEqual(key.url.path, "/w.heic")
    }

    /// Every rung above the last produces a real still, so the renderer has to
    /// turn a file into a small blurred image plus the tint sampled from it.
    func testWallpaperStillRendersToASmallBlurredImageAndItsTint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-wallpaper-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A saturated orange field, large enough that downscaling is real work.
        let side = 512
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        ))
        for x in 0..<side {
            for y in 0..<side {
                bitmap.setColor(
                    NSColor(deviceRed: 0.92, green: 0.44, blue: 0.10, alpha: 1),
                    atX: x,
                    y: y
                )
            }
        }
        let url = directory.appending(path: "wallpaper.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)

        let painting = try XCTUnwrap(DesktopBackdropRenderer.render(
            key: DesktopBackdropKey(path: url.path, modified: nil, isDark: false)
        ))
        guard case let .wallpaper(image, tint) = painting else {
            return XCTFail("a readable still must render as a painted wallpaper, got \(painting)")
        }
        // Pre-rendered small: the surface it fills is many times wider.
        XCTAssertLessThanOrEqual(image.width, DesktopBackdropRenderer.stillWidth)
        XCTAssertGreaterThan(image.width, 0)
        // The tint keeps the wallpaper's identity: warm, and orange-ordered.
        XCTAssertGreaterThan(tint.red, tint.green)
        XCTAssertGreaterThan(tint.green, tint.blue)

        XCTAssertNil(DesktopBackdropRenderer.render(
            key: DesktopBackdropKey(
                path: directory.appending(path: "missing.png").path,
                modified: nil,
                isDark: false
            )
        ))
    }

    /// End to end against whatever desktop this Mac is actually showing. The
    /// one thing that must never happen is painting the stand-in picture: on a
    /// machine running an aerial that would put the stock Big Sur photo behind
    /// the glass. Vacuous — and passing — on a Mac with no readable desktop at
    /// all, which is the state a headless CI runner is in.
    func testLiveDesktopNeverResolvesToTheStandInPicture() throws {
        let desktopImageURL = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let resolution = DesktopWallpaperLocator.resolveOnDisk(desktopImageURL: desktopImageURL)
        guard let url = resolution.url else { return }

        XCTAssertFalse(
            DesktopWallpaperLocator.isDynamicDesktopSentinel(url),
            "the ladder handed back the dynamic-desktop stand-in: \(url.path)"
        )
        XCTAssertNotNil(
            CGImageSourceCreateWithURL(url as CFURL, nil),
            "resolved \(url.path), which is not a decodable still"
        )
        let painting = DesktopBackdropRenderer.render(
            key: DesktopBackdropKey(path: url.path, modified: nil, isDark: false)
        )
        guard case let .wallpaper(image, _) = painting else {
            return XCTFail("live desktop \(url.path) did not render a painted backdrop")
        }
        XCTAssertLessThanOrEqual(image.width, DesktopBackdropRenderer.stillWidth)
        print("[wallpaper-glass] resolved \(resolution) -> \(image.width)x\(image.height)")
    }

    /// With a real wallpaper *image* under the veil the tint no longer has to
    /// carry the desktop on its own, but it is still what the last fallback
    /// rung and the Tinted canvas paint — and the old 0.45 chroma with a 0.18
    /// slate mix compressed a saturated desktop into grey. Michael's ask is a
    /// tint you can actually see.
    func testDesktopTintKeepsEnoughWallpaperHueToBeSeen() throws {
        let tint = try XCTUnwrap(DesktopTintSampler.cooledAverage(rgba: [
            255, 0, 0, 255,
            0, 0, 255, 255,
        ]))
        XCTAssertEqual(tint.red, 0.3884, accuracy: 0.0001)
        XCTAssertEqual(tint.green, 0.0804, accuracy: 0.0001)
        XCTAssertEqual(tint.blue, 0.4034, accuracy: 0.0001)

        // The property the numbers exist for. The pre-retune recipe returned
        // 0.3117/0.16/0.3387 for this same magenta desktop: a 0.179 spread,
        // which is already grey before any veil goes over it.
        let spread = max(tint.red, tint.green, tint.blue) - min(tint.red, tint.green, tint.blue)
        XCTAssertGreaterThan(spread, 0.30)
        XCTAssertGreaterThan(DesktopTintSampler.chromaRetention, 0.45)
        XCTAssertLessThan(DesktopTintSampler.slateMix, 0.18)

        XCTAssertNil(DesktopTintSampler.cooledAverage(rgba: [0, 0, 0, 0]))
    }

    /// Retaining chroma must not invent it: a neutral desktop still has to come
    /// back neutral, or every grey wallpaper picks up the slate stop as a cast.
    func testDesktopTintLeavesANeutralWallpaperNeutral() throws {
        let tint = try XCTUnwrap(DesktopTintSampler.cooledAverage(rgba: [
            128, 128, 128, 255,
            128, 128, 128, 255,
        ]))
        let spread = max(tint.red, tint.green, tint.blue) - min(tint.red, tint.green, tint.blue)
        XCTAssertLessThan(spread, 0.02)
        XCTAssertEqual(tint.red, 0.4868, accuracy: 0.0001)
    }

    // MARK: - Frost

    /// The bake used to boost saturation 1.3×, from the era when a heavy veil
    /// ate the desktop's chroma and the still had to shout through it. Under
    /// the frost veil that inverted: measured off the shipped build, the
    /// sidebar's peak channel spread was 0.53 against the raw desktop's 0.33 —
    /// the "glass" was more colourful than the wallpaper it imitated. The veil
    /// decides how much desktop arrives; the bake must not put a thumb on it.
    func testWallpaperBakeCarriesNoSaturationBoost() {
        XCTAssertEqual(DesktopBackdropRenderer.saturation, 1.0, accuracy: 0.0001)
    }

    /// Gaussians compose by variance, so raising the radius from 12 to 28 adds
    /// `sqrt(28² − 12²) ≈ 25` still-pixels over the previous result — about a
    /// quarter of the 176×110 thumbnail's height. Enough that the wallpaper
    /// keeps a left-to-right colour story and loses every locatable shape.
    func testWallpaperBakeBlursPastAnyRecognisableShape() {
        XCTAssertGreaterThanOrEqual(DesktopBackdropRenderer.blurRadius, 24)
        let added = (DesktopBackdropRenderer.blurRadius * DesktopBackdropRenderer.blurRadius - 144)
            .squareRoot()
        XCTAssertGreaterThan(
            added,
            0.2 * Double(DesktopBackdropRenderer.stillWidth) * 10 / 16,
            "the extra blur is small against the thumbnail, so shapes still resolve"
        )
    }

    /// `NSVisualEffectView` normalized luminance; a raw wallpaper does not, so
    /// before this every label's legibility was a function of the user's
    /// desktop picture — a white wallpaper in dark mode put tertiary text on a
    /// pale surface. The normalization has to be *exact* across the entire
    /// range of possible wallpapers, not merely clamped somewhere sensible:
    /// the clamp exists for a degenerate decode, and if it ever binds for a
    /// real desktop the guarantee is only approximate.
    func testWallpaperBakeNormalizesLuminanceExactlyForEveryPossibleWallpaper() {
        for isDark in [false, true] {
            let target = DesktopBackdropRenderer.targetLuminance(isDark: isDark)
            for step in 0...20 {
                let mean = Double(step) / 20
                let shifted = mean + DesktopBackdropRenderer.luminanceShift(mean: mean, isDark: isDark)
                XCTAssertEqual(
                    shifted,
                    target,
                    accuracy: 0.0001,
                    "a wallpaper of mean luminance \(mean) missed the \(isDark ? "dark" : "light") target"
                )
            }
        }
        // Light lifts toward bright, dark crushes toward dark.
        XCTAssertGreaterThan(DesktopBackdropRenderer.targetLuminance(isDark: false), 0.6)
        XCTAssertLessThan(DesktopBackdropRenderer.targetLuminance(isDark: true), 0.25)
    }

    /// The mean the bake normalizes against is the picture's own average, with
    /// none of the tint's cooling, floors, or slate mix applied — those exist to
    /// make a *tint* legible and would misreport the wallpaper's brightness.
    func testMeanLuminanceReadsThePictureRatherThanTheTint() throws {
        let white = try XCTUnwrap(DesktopTintSampler.meanLuminance(rgba: [255, 255, 255, 255]))
        XCTAssertEqual(white, 1.0, accuracy: 0.0001)
        let black = try XCTUnwrap(DesktopTintSampler.meanLuminance(rgba: [0, 0, 0, 255]))
        XCTAssertEqual(black, 0.0, accuracy: 0.0001)
        // Rec. 709: green dominates, blue barely registers.
        let green = try XCTUnwrap(DesktopTintSampler.meanLuminance(rgba: [0, 255, 0, 255]))
        XCTAssertEqual(green, 0.7152, accuracy: 0.0001)
        // A black wallpaper's tint is floored at 0.07-ish so it never degenerates;
        // its *luminance* must still read as black, or the bake would under-lift it.
        let tint = try XCTUnwrap(DesktopTintSampler.cooledAverage(rgba: [0, 0, 0, 255]))
        XCTAssertGreaterThan(tint.red, 0.0)
        XCTAssertNil(DesktopTintSampler.meanLuminance(rgba: [0, 0, 0, 0]))
    }

    /// The whole point of normalizing: the composite the eye actually sees is
    /// the same brightness on every desktop, so "0.60 coverage" means one thing
    /// rather than one thing per wallpaper. Modelled end to end — normalize the
    /// still, then lay the veil over it — across the full range of wallpapers.
    func testFrostCompositeLandsOnTheSameGroundForEveryWallpaper() throws {
        func veilLuminance(isDark: Bool) -> Double {
            guard isDark else { return 1.0 }
            let veil = GlassBackdropWash.darkVeil
            return veil.red * 0.2126 + veil.green * 0.7152 + veil.blue * 0.0722
        }

        for isDark in [false, true] {
            let base = GlassBackdropWash.sidebar(isDark: isDark).baseOpacity
            var composites: [Double] = []
            for step in 0...20 {
                let mean = Double(step) / 20
                let still = mean + DesktopBackdropRenderer.luminanceShift(mean: mean, isDark: isDark)
                composites.append(base * veilLuminance(isDark: isDark) + (1 - base) * still)
            }
            let spread = (composites.max() ?? 0) - (composites.min() ?? 0)
            XCTAssertLessThan(
                spread,
                0.001,
                "sidebar brightness still depends on the wallpaper (isDark: \(isDark))"
            )
            let composite = try XCTUnwrap(composites.first)
            if isDark {
                // Near-black: white text has room, whatever the desktop is.
                XCTAssertLessThan(composite, 0.16)
            } else {
                // Near-white frost, the Safari sidebar reference.
                XCTAssertGreaterThan(composite, 0.85)
            }
        }
    }

    // MARK: - Desktop resolve coalescing

    /// The rate limit was inert. `invalidate` set `lastResolved = .distantPast`
    /// and then asked `refresh` whether enough time had passed *since
    /// lastResolved*, which it now always had — so every Space switch,
    /// activation, screen change, and key-window change paid for a full
    /// re-resolution: an `Index.plist` read, an `entries.json` parse, and a
    /// main-thread `desktopImageURL(for:)` call. Coalescing means a hint inside
    /// the floor is neither dropped nor duplicated.
    func testDesktopHintsCoalesceIntoOneDeferredResolve() {
        let floor = DesktopBackdropProvider.minimumResolveInterval
        let now = Date()

        // Past the floor: read it now.
        XCTAssertEqual(
            DesktopBackdropProvider.hintDecision(
                now: now,
                lastResolved: now.addingTimeInterval(-floor - 0.1),
                deferredResolveArmed: false
            ),
            .resolveNow
        )

        // Inside the floor with nothing armed: arm exactly one resolve, for the
        // moment the floor expires — never dropped.
        XCTAssertEqual(
            DesktopBackdropProvider.hintDecision(
                now: now,
                lastResolved: now.addingTimeInterval(-0.5),
                deferredResolveArmed: false
            ),
            .deferBy(floor - 0.5)
        )

        // The burst: every further hint rides the armed one — never duplicated.
        for elapsed in [0.0, 0.25, 1.0, 1.99] {
            XCTAssertEqual(
                DesktopBackdropProvider.hintDecision(
                    now: now,
                    lastResolved: now.addingTimeInterval(-elapsed),
                    deferredResolveArmed: true
                ),
                .alreadyScheduled,
                "a hint \(elapsed)s into the floor scheduled a second resolve"
            )
        }

        // An armed resolve does not suppress a hint that arrives after the floor
        // has already expired; that one is due on its own account.
        XCTAssertEqual(
            DesktopBackdropProvider.hintDecision(
                now: now,
                lastResolved: now.addingTimeInterval(-floor),
                deferredResolveArmed: true
            ),
            .resolveNow
        )

        // A cold start has never resolved, so the first hint is immediate.
        XCTAssertEqual(
            DesktopBackdropProvider.hintDecision(
                now: now,
                lastResolved: .distantPast,
                deferredResolveArmed: false
            ),
            .resolveNow
        )
    }

    // MARK: - Opening sidebar width

    /// macOS honours `navigationSplitViewColumnWidth`'s `min:`/`max:` but not
    /// its `ideal:` for the *opening* width, so Kaisola's 248pt rail opened at
    /// roughly 195 and truncated its titles. The override has to be narrow: it
    /// fires once, only on a column still sitting at AppKit's untouched
    /// default, and never against a width the user chose.
    func testSidebarIsWidenedOnlyOnceAndOnlyFromTheSystemDefault() {
        // The case the feature exists for.
        XCTAssertTrue(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 195, didForce: false)
        )
        // AppKit's default is undocumented, so it is matched with tolerance.
        XCTAssertTrue(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 186, didForce: false)
        )
        XCTAssertTrue(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 204, didForce: false)
        )

        // Never twice: a user who drags the rail back toward the default keeps
        // their width across relaunches.
        XCTAssertFalse(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 195, didForce: true)
        )

        // Never against a restored or user-chosen width — including the ideal
        // itself, so a second window does not re-run the override.
        for width in [168.0, 240.0, 248.0, 300.0, 340.0] {
            XCTAssertFalse(
                InitialSidebarWidth.shouldForceInitialWidth(
                    currentWidth: width,
                    didForce: false
                ),
                "\(width) is not AppKit's default and must be left alone"
            )
        }
    }

    /// The "we did this" flag is per window restoration id, and the id falls
    /// back through identifier → autosave name → a fixed key so a window that
    /// reports neither still gets a stable, non-empty bucket.
    func testInitialSidebarWidthLedgerIsScopedPerWindow() throws {
        let suite = "kaisola-sidebar-width-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(InitialSidebarWidth.hasApplied(restorationID: "main", defaults: defaults))
        InitialSidebarWidth.markApplied(restorationID: "main", defaults: defaults)
        XCTAssertTrue(InitialSidebarWidth.hasApplied(restorationID: "main", defaults: defaults))
        // A different window has its own answer.
        XCTAssertFalse(InitialSidebarWidth.hasApplied(restorationID: "second", defaults: defaults))

        XCTAssertEqual(
            InitialSidebarWidth.restorationID(identifier: "window-1", frameAutosaveName: "autosave"),
            "window-1"
        )
        XCTAssertEqual(
            InitialSidebarWidth.restorationID(identifier: nil, frameAutosaveName: "autosave"),
            "autosave"
        )
        XCTAssertEqual(
            InitialSidebarWidth.restorationID(identifier: "", frameAutosaveName: ""),
            "kaisola.window"
        )
    }

    /// A visual fixture runs the production hierarchy in a short-lived process.
    /// It must not leave a "we widened this window" flag in the real user's
    /// defaults, or QA taking a screenshot would silently opt that user out of
    /// the fix.
    func testInitialSidebarWidthFlagStaysOutOfRealDefaultsInFixtures() {
        XCTAssertEqual(
            InitialSidebarWidth.store(environment: [:], processIdentifier: 42),
            .standard
        )
        let fixture = InitialSidebarWidth.store(
            environment: ["KAISOLA_NATIVE_VISUAL_FIXTURE": "1"],
            processIdentifier: 42
        )
        XCTAssertNotEqual(fixture, .standard)
    }

    /// The width the override applies is the one the rest of the chrome is
    /// designed around, not a second literal that can drift away from it.
    func testSidebarOverrideTargetsTheIdealWidthTheChromeIsSizedFor() {
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarIdealWidth, 248)
        XCTAssertGreaterThan(
            NativeWorkspaceChrome.projectSidebarIdealWidth,
            InitialSidebarWidth.systemDefault + InitialSidebarWidth.tolerance,
            "the ideal is inside the default's tolerance, so the override would never fire"
        )
        XCTAssertGreaterThanOrEqual(
            NativeWorkspaceChrome.projectSidebarIdealWidth,
            NativeWorkspaceChrome.projectSidebarMinimumWidth
        )
        XCTAssertLessThanOrEqual(
            NativeWorkspaceChrome.projectSidebarIdealWidth,
            NativeWorkspaceChrome.projectSidebarMaximumWidth
        )
    }

    /// With no paired Mac the section was a permanent "No other Macs yet" plus
    /// a "Updated N seconds ago" line: two rows of chrome reporting nothing.
    func testOtherMacsSectionStaysHiddenUntilThereIsSomethingToReport() {
        XCTAssertFalse(
            RememberedSessionsSectionVisibility.shouldShow(remoteDeviceCount: 0, errorMessage: nil)
        )
        XCTAssertFalse(
            RememberedSessionsSectionVisibility.shouldShow(remoteDeviceCount: 0, errorMessage: "")
        )
        XCTAssertFalse(
            RememberedSessionsSectionVisibility.shouldShow(remoteDeviceCount: 0, errorMessage: "  \n ")
        )
        XCTAssertTrue(
            RememberedSessionsSectionVisibility.shouldShow(remoteDeviceCount: 1, errorMessage: nil)
        )
        // A failure must never be silent just because it left the catalog empty.
        XCTAssertTrue(
            RememberedSessionsSectionVisibility.shouldShow(
                remoteDeviceCount: 0,
                errorMessage: "Companion is offline"
            )
        )
    }

    func testNonActiveProjectsDefaultToCollapsed() {
        XCTAssertTrue(
            ProjectExpansionState.isExpanded(
                projectID: "active",
                isActive: true,
                expanded: [],
                collapsed: []
            )
        )
        XCTAssertFalse(
            ProjectExpansionState.isExpanded(
                projectID: "other",
                isActive: false,
                expanded: [],
                collapsed: []
            )
        )
    }

    func testProjectExpansionHonoursExplicitUserToggles() {
        // Peeking into a non-active project is opt-in and sticks.
        XCTAssertTrue(
            ProjectExpansionState.isExpanded(
                projectID: "other",
                isActive: false,
                expanded: ["other"],
                collapsed: []
            )
        )
        // Collapsing a non-active project sticks too, and outranks a stale
        // expansion entry for the same project.
        XCTAssertFalse(
            ProjectExpansionState.isExpanded(
                projectID: "other",
                isActive: false,
                expanded: ["other"],
                collapsed: ["other"]
            )
        )
    }

    /// The one rule no persisted state may override: the project being worked
    /// in always shows its sessions.
    func testTheActiveProjectIsAlwaysExpanded() {
        for collapsed in [Set<String>(), ["active"], ["active", "other"]] {
            for expanded in [Set<String>(), ["active"]] {
                XCTAssertTrue(
                    ProjectExpansionState.isExpanded(
                        projectID: "active",
                        isActive: true,
                        expanded: expanded,
                        collapsed: collapsed
                    ),
                    "expanded=\(expanded.sorted()) collapsed=\(collapsed.sorted())"
                )
            }
        }
    }

    /// An install made before the default flipped persisted only *collapsed*
    /// ids. Non-active ones keep their meaning instead of springing open, but
    /// the active project's entry must never hide the sessions the user is
    /// working in — an upgrade otherwise opens onto a nearly empty rail.
    func testProjectExpansionMigratesTheLegacyCollapsedKey() {
        let legacy = ProjectExpansionState.decode("alpha,beta")
        XCTAssertEqual(legacy, ["alpha", "beta"])
        XCTAssertTrue(
            ProjectExpansionState.isExpanded(
                projectID: "alpha",
                isActive: true,
                expanded: [],
                collapsed: legacy
            )
        )
        XCTAssertFalse(
            ProjectExpansionState.isExpanded(
                projectID: "beta",
                isActive: false,
                expanded: [],
                collapsed: legacy
            )
        )
        XCTAssertEqual(ProjectExpansionState.decode(""), [])
        XCTAssertEqual(ProjectExpansionState.encode(["beta", "alpha"]), "alpha,beta")
        XCTAssertEqual(ProjectExpansionState.encode([]), "")
    }

    /// Toggling the active project's disclosure cannot collapse it, and heals
    /// the legacy entry so the id stops lingering in the collapsed set.
    func testTogglingTheActiveProjectHealsItsLegacyCollapsedEntry() {
        let healed = ProjectExpansionState.toggled(
            expanded: false,
            projectID: "alpha",
            isActive: true,
            expanded: [],
            collapsed: ["alpha", "beta"]
        )
        XCTAssertEqual(healed.collapsed, ["beta"])
        XCTAssertEqual(healed.expanded, [])
        XCTAssertTrue(
            ProjectExpansionState.isExpanded(
                projectID: "alpha",
                isActive: true,
                expanded: healed.expanded,
                collapsed: healed.collapsed
            )
        )
        // Healing is idempotent: a second toggle is a no-op.
        let again = ProjectExpansionState.toggled(
            expanded: true,
            projectID: "alpha",
            isActive: true,
            expanded: healed.expanded,
            collapsed: healed.collapsed
        )
        XCTAssertEqual(again.collapsed, ["beta"])
        XCTAssertEqual(again.expanded, [])
    }

    func testTogglingANonActiveProjectRecordsBothDirections() {
        let opened = ProjectExpansionState.toggled(
            expanded: true,
            projectID: "other",
            isActive: false,
            expanded: [],
            collapsed: ["other"]
        )
        XCTAssertEqual(opened.expanded, ["other"])
        XCTAssertEqual(opened.collapsed, [])

        let closed = ProjectExpansionState.toggled(
            expanded: false,
            projectID: "other",
            isActive: false,
            expanded: opened.expanded,
            collapsed: opened.collapsed
        )
        XCTAssertEqual(closed.expanded, [])
        XCTAssertEqual(closed.collapsed, ["other"])
    }

    func testTopBarLayoutTightensTheDetailChromeBand() {
        let split = NativeWorkspaceChrome.detailChromeBandHeight(topBarLayout: false)
        let topBar = NativeWorkspaceChrome.detailChromeBandHeight(topBarLayout: true)
        // The split band is unchanged: it still lands the detail card on the
        // sidebar card's line.
        XCTAssertEqual(
            split,
            NativeWorkspaceChrome.chromePanelTopInset - KaisolaVisualSystem.chromeInset
        )
        XCTAssertEqual(split, 40)
        // Top bar has no toolbar band to clear, so the strip is a tight fit
        // around the Files control instead of an empty gutter.
        XCTAssertEqual(topBar, 32)
        XCTAssertLessThan(topBar, split)
        XCTAssertGreaterThan(topBar, NativeWorkspaceChrome.detailChromeControlHeight)
    }

    func testChromePanelTokensSitBetweenCardAndShell() {
        XCTAssertGreaterThan(KaisolaVisualSystem.chromeRadius, KaisolaVisualSystem.cardRadius)
        XCTAssertLessThan(KaisolaVisualSystem.chromeRadius, KaisolaVisualSystem.shellRadius)
        XCTAssertEqual(KaisolaVisualSystem.chromeInset, 6)
    }

    func testTerminalPaneGridKeepsSessionsReadable() {
        XCTAssertEqual(TerminalPaneGrid.columns(for: []), [])
        XCTAssertEqual(TerminalPaneGrid.columns(for: ["a"]), [["a"]])
        XCTAssertEqual(TerminalPaneGrid.columns(for: ["a", "b"]), [["a"], ["b"]])
        XCTAssertEqual(TerminalPaneGrid.columns(for: ["a", "b", "c"]), [["a", "b"], ["c"]])
        XCTAssertEqual(TerminalPaneGrid.columns(for: ["a", "b", "c", "d"]), [["a", "b"], ["c", "d"]])
    }

    func testTerminalPaneIdentityHeaderAppearsOnlyForARealSplit() {
        XCTAssertFalse(TerminalPaneGrid.showsIdentityHeader(paneCount: 0))
        XCTAssertFalse(TerminalPaneGrid.showsIdentityHeader(paneCount: 1))
        XCTAssertTrue(TerminalPaneGrid.showsIdentityHeader(paneCount: 2))
        XCTAssertTrue(TerminalPaneGrid.showsIdentityHeader(paneCount: 4))
    }

    func testTerminalPaneGridKeepsGlyphsInsideRoundedSurface() {
        XCTAssertEqual(TerminalPaneGrid.contentLeadingInset, 8)
        XCTAssertEqual(TerminalPaneGrid.contentTopInset, 7)
        XCTAssertEqual(TerminalPaneGrid.contentTrailingInset, 6)
        XCTAssertEqual(TerminalPaneGrid.contentBottomInset, 5)
    }

    func testUnifiedTerminalDocumentResolverNeverBlanksDuringFocusHandoff() {
        let primary = TerminalDocument(
            sessionID: "a",
            output: "primary",
            cursor: nil,
            truncated: false,
            exited: false,
            errorMessage: nil
        )
        let split = TerminalDocument(
            sessionID: "b",
            output: "split",
            cursor: nil,
            truncated: false,
            exited: false,
            errorMessage: nil
        )
        let retained = TerminalDocument(
            sessionID: "b",
            output: "retained",
            cursor: nil,
            truncated: false,
            exited: false,
            errorMessage: nil
        )

        XCTAssertEqual(
            UnifiedTerminalDocumentResolver.resolve(
                id: "a", primary: primary, splits: ["a": split], retained: [:]
            )?.output,
            "primary"
        )
        XCTAssertEqual(
            UnifiedTerminalDocumentResolver.resolve(
                id: "b", primary: primary, splits: ["b": split], retained: ["b": retained]
            )?.output,
            "split"
        )
        XCTAssertEqual(
            UnifiedTerminalDocumentResolver.resolve(
                id: "b", primary: primary, splits: [:], retained: ["b": retained]
            )?.output,
            "retained"
        )
    }

    func testFullHeightWorkspaceOnlyReservesTrafficLightClearanceInNavigation() {
        XCTAssertEqual(NativeWorkspaceChrome.sidebarTrafficLightClearance, 40)
        XCTAssertEqual(NativeWorkspaceChrome.topBarTrafficLightClearance, 76)
    }

    /// v1.1.6 widened the resting rail (200 → 248) and its ceiling (260 → 340)
    /// to pay for a visible hierarchy step between a project row and its
    /// sessions, and for a footer that can show a whole account name. The
    /// *minimum* is deliberately unchanged: nothing about the narrow rail moves.
    func testProjectSidebarHasComfortableResizableWidth() {
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarMinimumWidth, 168)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarIdealWidth, 248)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarMaximumWidth, 340)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerWidth, 1)
    }

    /// The pointer target is sized from the gap the eye aims at, not from the
    /// one-point rule: the inset chrome cards leave `chromeInset` of backdrop on
    /// each side, and the hit zone has to span that whole gap *plus* overlap
    /// onto both cards. A zone narrower than the gap leaves a dead band the
    /// pointer crosses on its way in, which is seen as the cursor flickering.
    func testSidebarDividerHitZoneSpansTheWholeVisibleGap() {
        let gap = KaisolaVisualSystem.chromeInset + NativeWorkspaceChrome.projectSidebarDividerWidth
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerHitWidth, 18)
        XCTAssertGreaterThan(NativeWorkspaceChrome.projectSidebarDividerHitWidth, gap)
        // Reach past the visible gutter, onto the content on each side, so the
        // pointer is never over a point that is neither content nor divider.
        XCTAssertGreaterThan(
            NativeWorkspaceChrome.projectSidebarDividerReach,
            KaisolaVisualSystem.chromeInset
        )
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerReach, 8.5)
    }

    func testClickingFocusedSurfaceStillSwitchesItsProject() {
        XCTAssertTrue(SurfaceSelectionPolicy.shouldRequestFocus(
            focusedPaneID: "terminal-a",
            targetID: "terminal-a",
            browserOpen: false,
            activeProjectID: "project-b",
            targetProjectID: "project-a"
        ))
        XCTAssertFalse(SurfaceSelectionPolicy.shouldRequestFocus(
            focusedPaneID: "terminal-a",
            targetID: "terminal-a",
            browserOpen: false,
            activeProjectID: "project-a",
            targetProjectID: "project-a"
        ))
    }

    func testFolderPickerStartsBesideCurrentProject() {
        let current = URL(fileURLWithPath: "/Users/test/Developer/Kaisola", isDirectory: true)
        XCTAssertEqual(
            NativeFolderPickerStartingPoint.preferred(currentProject: current)?.path,
            "/Users/test/Developer"
        )
        XCTAssertNil(NativeFolderPickerStartingPoint.preferred(currentProject: nil))
    }

    func testNativeGoogleAuthConfigurationParsesSecureURLs() throws {
        let data = Data(#"""
        {
          "projectId": "kaisola-preview",
          "apiKey": "abcdefghijklmnopqrstuvwx",
          "serverUrl": "https://account.example.test",
          "relayUrl": "https://relay.example.test"
        }
        """#.utf8)
        let configuration = try FirebaseAuthConfiguration.parse(data)
        XCTAssertEqual(configuration.projectId, "kaisola-preview")
        XCTAssertEqual(configuration.serverURL.absoluteString, "https://account.example.test")
        XCTAssertEqual(configuration.relayURL?.absoluteString, "https://relay.example.test")
    }

    func testNativeAccountAvatarInitialsMatchDesktopProfile() {
        let named = AuthAccount(
            uid: "one",
            email: "michael@example.test",
            displayName: "Michael Ofengenden",
            avatarURL: nil
        )
        let emailOnly = AuthAccount(
            uid: "two",
            email: "kaisola@example.test",
            displayName: nil,
            avatarURL: nil
        )
        XCTAssertEqual(named.initials, "MO")
        XCTAssertEqual(emailOnly.initials, "KE")
    }

    func testTerminalPaneMinimizeKeepsSessionsRunningAndChoosesAVisibleReplacement() {
        XCTAssertEqual(
            TerminalPaneGrid.minimizeAction(targetID: "b", primaryID: "a", splitOrder: ["b", "c"]),
            .closeSplit("b")
        )
        XCTAssertEqual(
            TerminalPaneGrid.minimizeAction(targetID: "a", primaryID: "a", splitOrder: ["b", "c"]),
            .promote("b")
        )
        XCTAssertEqual(
            TerminalPaneGrid.minimizeAction(targetID: "a", primaryID: "a", splitOrder: []),
            .clearPrimary
        )
        XCTAssertEqual(
            TerminalPaneGrid.minimizeAction(targetID: "missing", primaryID: "a", splitOrder: ["b"]),
            .none
        )
    }

    func testAppearanceMapsToColorSchemeAndNSAppearance() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
    }

    func testFileMenuCarriesNewWindowWithShortcut() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            newWindowTarget: nil, newWindowAction: #selector(NSResponder.doCommand(by:))
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let newWindow = try XCTUnwrap(fileMenu.items.first { $0.title == "New Window" })
        XCTAssertEqual(newWindow.keyEquivalent, "n")
        XCTAssertEqual(newWindow.keyEquivalentModifierMask, [.command, .shift])
    }

    func testFileMenuCarriesOpenFolderWithShortcut() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            openFolderTarget: nil, openFolderAction: #selector(NSResponder.doCommand(by:))
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let openFolder = try XCTUnwrap(fileMenu.items.first { $0.title == "Open Folder…" })
        XCTAssertEqual(openFolder.keyEquivalent, "o")
        XCTAssertEqual(openFolder.keyEquivalentModifierMask, [.command])
    }

    func testFileMenuCarriesOpenProjectInNewWindowWithShortcut() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            openFolderInNewWindowTarget: nil,
            openFolderInNewWindowAction: #selector(NSResponder.doCommand(by:))
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let openInWindow = try XCTUnwrap(
            fileMenu.items.first { $0.title == "Open Project in New Window…" }
        )
        XCTAssertEqual(openInWindow.keyEquivalent, "o")
        XCTAssertEqual(openInWindow.keyEquivalentModifierMask, [.command, .option])
    }

    func testFileMenuCarriesClosedFileAndProjectRecoveryShortcuts() throws {
        let action = #selector(NSResponder.doCommand(by:))
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            reopenClosedProjectTarget: nil, reopenClosedProjectAction: action,
            reopenClosedFileTabTarget: nil, reopenClosedFileTabAction: action,
            closeFileTabTarget: nil, closeFileTabAction: action
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let closeFile = try XCTUnwrap(fileMenu.items.first { $0.title == "Close File Tab" })
        XCTAssertEqual(closeFile.keyEquivalent, "w")
        XCTAssertEqual(closeFile.keyEquivalentModifierMask, [.command])
        let closeWindow = try XCTUnwrap(fileMenu.items.first { $0.title == "Close Window" })
        XCTAssertEqual(closeWindow.keyEquivalent, "w")
        XCTAssertEqual(closeWindow.keyEquivalentModifierMask, [.command, .shift])
        let reopenFile = try XCTUnwrap(fileMenu.items.first { $0.title == "Reopen Closed File Tab" })
        XCTAssertEqual(reopenFile.keyEquivalent, "t")
        XCTAssertEqual(reopenFile.keyEquivalentModifierMask, [.command, .shift])
        let reopenProject = try XCTUnwrap(fileMenu.items.first { $0.title == "Reopen Closed Project" })
        XCTAssertEqual(reopenProject.keyEquivalent, "t")
        XCTAssertEqual(reopenProject.keyEquivalentModifierMask, [.command, .option, .shift])
    }

    func testMenuBarCarriesWindowAndHelpMenus() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil
        )
        XCTAssertEqual(menu.items.first?.title, "Kaisola")
        let windowMenu = try XCTUnwrap(menu.item(withTitle: "Window")?.submenu)
        XCTAssertNotNil(windowMenu.items.first { $0.title == "Minimize" && $0.keyEquivalent == "m" })
        XCTAssertNotNil(windowMenu.items.first { $0.title == "Bring All to Front" })
        let helpMenu = try XCTUnwrap(menu.item(withTitle: "Help")?.submenu)
        XCTAssertNotNil(helpMenu.items.first { $0.title.contains("Help") })
    }

    func testFileMenuCarriesOpenRecentWhenDelegateProvided() throws {
        final class StubDelegate: NSObject, NSMenuDelegate {}
        let delegate = StubDelegate()
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            openFolderTarget: nil, openFolderAction: #selector(NSResponder.doCommand(by:)),
            dynamicMenusDelegate: delegate,
            saveWindowTarget: nil, saveWindowAction: #selector(NSResponder.doCommand(by:))
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let recent = try XCTUnwrap(fileMenu.items.first { $0.title == "Open Recent" })
        XCTAssertTrue(recent.submenu?.delegate === delegate)
        let windowMenu = try XCTUnwrap(menu.item(withTitle: "Window")?.submenu)
        XCTAssertNotNil(windowMenu.items.first { $0.title == "Save Window Layout…" })
        let saved = try XCTUnwrap(windowMenu.items.first { $0.title == "Saved Windows" })
        XCTAssertTrue(saved.submenu?.delegate === delegate)
    }

    func testViewMenuCarriesTerminalFontItems() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            viewTarget: nil,
            layoutAction: #selector(NSResponder.doCommand(by:)),
            appearanceAction: #selector(NSResponder.doCommand(by:)),
            fontTarget: nil,
            fontIncreaseAction: #selector(NSResponder.doCommand(by:)),
            fontDecreaseAction: #selector(NSResponder.doCommand(by:)),
            fontResetAction: #selector(NSResponder.doCommand(by:))
        )
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        XCTAssertNotNil(viewMenu.items.first { $0.title == "Bigger" && $0.keyEquivalent == "+" })
        XCTAssertNotNil(viewMenu.items.first { $0.title == "Smaller" && $0.keyEquivalent == "-" })
        XCTAssertNotNil(viewMenu.items.first { $0.title == "Reset Size" && $0.keyEquivalent == "0" })
    }

    func testViewMenuCarriesDiscoverableFileTabNavigation() throws {
        let action = #selector(NSResponder.doCommand(by:))
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            viewTarget: nil,
            layoutAction: action,
            appearanceAction: action,
            fileTabTarget: nil,
            previousFileTabAction: action,
            nextFileTabAction: action
        )
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let previous = try XCTUnwrap(viewMenu.items.first { $0.title == "Previous File Tab" })
        XCTAssertEqual(previous.keyEquivalent, "\u{F702}")
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.command, .option])
        let next = try XCTUnwrap(viewMenu.items.first { $0.title == "Next File Tab" })
        XCTAssertEqual(next.keyEquivalent, "\u{F703}")
        XCTAssertEqual(next.keyEquivalentModifierMask, [.command, .option])
    }

    @MainActor
    func testTerminalFontAdjustClampsToRange() {
        let suite = "kaisola-font-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(settings.terminalFontSize, NativePreviewSettings.terminalFontDefault)
        settings.adjustTerminalFont(by: 100)
        XCTAssertEqual(settings.terminalFontSize, NativePreviewSettings.terminalFontRange.upperBound)
        settings.adjustTerminalFont(by: -100)
        XCTAssertEqual(settings.terminalFontSize, NativePreviewSettings.terminalFontRange.lowerBound)
        settings.resetTerminalFont()
        XCTAssertEqual(settings.terminalFontSize, NativePreviewSettings.terminalFontDefault)
        defaults.removePersistentDomain(forName: suite)
    }

    func testViewMenuCarriesLayoutAndAppearanceToggles() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            viewTarget: nil,
            layoutAction: #selector(NSResponder.doCommand(by:)),
            appearanceAction: #selector(NSResponder.doCommand(by:)),
            currentLayout: NavigationLayout.topBar.rawValue,
            currentAppearance: AppearanceMode.dark.rawValue
        )
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let items = viewMenu.items.compactMap { $0.representedObject as? String }
        XCTAssertTrue(items.contains(NavigationLayout.leftTree.rawValue))
        XCTAssertTrue(items.contains(NavigationLayout.topBar.rawValue))
        XCTAssertTrue(items.contains(AppearanceMode.light.rawValue))
        XCTAssertTrue(items.contains(AppearanceMode.dark.rawValue))

        // The current selections are checked.
        let topBarItem = try XCTUnwrap(viewMenu.items.first { ($0.representedObject as? String) == NavigationLayout.topBar.rawValue })
        XCTAssertEqual(topBarItem.state, .on)
        let darkItem = try XCTUnwrap(viewMenu.items.first { ($0.representedObject as? String) == AppearanceMode.dark.rawValue })
        XCTAssertEqual(darkItem.state, .on)
    }
}
