import AppKit
import ImageIO
import SwiftUI
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
        XCTAssertTrue(NativeVisualCaptureTarget.window(rootedAt: root, surface: "workspace-move") === sheet)
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
        XCTAssertEqual(settings.terminalThemeID, "native")
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
        settings.terminalThemeID = "kaisola"
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
        XCTAssertEqual(reloaded.terminalThemeID, "kaisola")
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
        settings.terminalThemeID = "kaisola"

        settings.applyTerminalAppDefaults()

        XCTAssertEqual(settings.terminalFontSize, 11)
        XCTAssertEqual(settings.terminalFontFamily, TerminalFontOptions.systemMonoSentinel)
        XCTAssertEqual(settings.terminalFontWeight, "regular")
        XCTAssertEqual(settings.terminalLineSpacing, 1)
        XCTAssertEqual(settings.terminalThemeID, "native")
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
        XCTAssertFalse(NativePreviewSettings.shouldPersistChanges(environment: [
            "KAISOLA_NATIVE_PDF_PREVIEW_BUDGET": "1",
        ]))
        XCTAssertFalse(NativePreviewSettings.shouldPersistChanges(environment: [
            "KAISOLA_NATIVE_PDF_PREVIEW_BUDGET": "invalid",
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
        XCTAssertEqual(
            NativePreviewSettings.isolatedFixtureSuiteName(
                environment: ["KAISOLA_NATIVE_PDF_PREVIEW_BUDGET": "1"],
                processIdentifier: 42
            ),
            "com.kaisola.mac.pdf-preview-budget.42"
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
        // 17 → 22 in v1.1.8: these two were the last dividers in the app below
        // the shared grab floor. See
        // `testEveryDividerCorridorClearsTheGrabReachOnBothSides`.
        XCTAssertEqual(NativeDetailPaneSizing.dividerHitWidth, 22)
    }

    /// Both detail dividers' trackers were hoisted into ONE overlay on the
    /// detail stack, because a tracker nested inside its handle sits under the
    /// panel beside it in the backing NSView hierarchy — and the document panel
    /// hosts a WKWebView/NSTextView, which then answers for the corridor's
    /// cursor no matter what `zIndex` SwiftUI is given. Placing the corridors is
    /// now this function's job rather than the HStack's, so the arithmetic that
    /// used to be implicit in the layout is pinned here.
    func testDetailDividerCorridorsSitOnTheRulesTheyResize() {
        let widths = NativeDetailPaneSizing.Widths(preview: 480, rail: 218)
        let both = NativeDetailPaneSizing.corridors(
            widths: widths,
            previewVisible: true,
            railVisible: true
        )
        XCTAssertEqual(both.map(\.divider), [.rail, .preview])
        // Right to left: [ rail 218 | rule 1 | preview 480 | rule 1 | content ].
        XCTAssertEqual(both[0].centerFromTrailing, 218.5, accuracy: 0.001)
        // The preview's rule sits past the rail AND the rail's own rule;
        // forgetting that one point walks the corridor off its divider.
        XCTAssertEqual(both[1].centerFromTrailing, 699.5, accuracy: 0.001)
        XCTAssertGreaterThan(
            both[1].centerFromTrailing - both[0].centerFromTrailing,
            NativeDetailPaneSizing.dividerHitWidth,
            "the two hit corridors must not overlap"
        )

        // Files closed: the document divider moves in by exactly the rail and
        // the rail's rule, so the corridor tracks the panel it resizes.
        let previewOnly = NativeDetailPaneSizing.corridors(
            widths: NativeDetailPaneSizing.Widths(preview: 480, rail: 0),
            previewVisible: true,
            railVisible: false
        )
        XCTAssertEqual(previewOnly.map(\.divider), [.preview])
        XCTAssertEqual(previewOnly[0].centerFromTrailing, 480.5, accuracy: 0.001)

        let railOnly = NativeDetailPaneSizing.corridors(
            widths: NativeDetailPaneSizing.Widths(preview: 0, rail: 218),
            previewVisible: false,
            railVisible: true
        )
        XCTAssertEqual(railOnly.map(\.divider), [.rail])
        XCTAssertEqual(railOnly[0].centerFromTrailing, 218.5, accuracy: 0.001)

        // No panels, no corridors: an overlay that always placed a tracker
        // would leave a resize cursor floating over a bare terminal canvas.
        XCTAssertTrue(NativeDetailPaneSizing.corridors(
            widths: NativeDetailPaneSizing.Widths(preview: 0, rail: 0),
            previewVisible: false,
            railVisible: false
        ).isEmpty)
    }

    func testVisualChoiceTitlesRemainUserFacing() {
        XCTAssertEqual(SidebarAppearance.glass.title, "Glass")
        XCTAssertEqual(WorkspaceBackdropMode.tinted.title, "Tinted")
        // "System" said where the colour came from; "Solid" says what you get,
        // which is what makes the choice next to "Tinted" mean anything. The
        // stored value is unchanged, so nobody's preference moves.
        XCTAssertEqual(WorkspaceBackdropMode.system.title, "Solid")
        XCTAssertEqual(WorkspaceBackdropMode.system.rawValue, "system")
        XCTAssertEqual(TerminalThemeRegistry.shipped.first?.title, "macOS Terminal")
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
            // #0D0D0D. Was #0B0C12, which is where the blue-purple cast came
            // from; see `testDeclaredNeutralConstantsAreAchromatic`.
            XCTAssertEqual(recipe.red, 13.0 / 255, accuracy: 0.0001)
            XCTAssertEqual(recipe.green, 13.0 / 255, accuracy: 0.0001)
            XCTAssertEqual(recipe.blue, 13.0 / 255, accuracy: 0.0001)
        }

        // The headline coverage: frost, not a pane. Two earlier eras both
        // missed, in opposite directions — 0.32/0.44 over near-opaque vibrancy
        // passed no desktop colour at all, and the 0.16 that replaced it was
        // calibrated against vibrancy but ended up over a *painted wallpaper*,
        // which passes everything.
        // Light moved for the same reason dark did, one round later: "light
        // mode should also be translucent to wallpaper much better". 0.60 →
        // 0.45, transmission 0.40 → 0.55, and — like dark — only reachable
        // because the bake bounds the still's range first.
        XCTAssertEqual(GlassBackdropWash.sidebar(isDark: false).baseOpacity, 0.45, accuracy: 0.0001)
        XCTAssertEqual(GlassBackdropWash.workspace(isDark: false).baseOpacity, 0.40, accuracy: 0.0001)
        // Dark is thinner than light now, and deliberately so: it used to be
        // the least translucent surface in the app (0.40 transmission against
        // light's 0.40 on the sidebar and 0.45 on the workspace), which is what
        // "the background in dark mode looks bad… needs to be glassy/smooth/
        // translucent to the wallpaper" was describing. 0.55 → 0.52 in v1.1.10,
        // and 0.52 → 0.33 here for "dark mode should be very translucent" —
        // which only became available once the bake started bounding the
        // still's dynamic range as well as its mean.
        XCTAssertEqual(GlassBackdropWash.sidebar(isDark: true).baseOpacity, 0.34, accuracy: 0.0001)
        XCTAssertEqual(GlassBackdropWash.workspace(isDark: true).baseOpacity, 0.37, accuracy: 0.0001)
        XCTAssertGreaterThan(
            GlassBackdropWash.sidebar(isDark: true).desktopTransmission,
            GlassBackdropWash.sidebar(isDark: false).desktopTransmission
        )
        // The headline, stated the way Michael asked for it: dark now passes
        // half again as much desktop as it did, on both surfaces.
        XCTAssertGreaterThan(GlassBackdropWash.sidebar(isDark: true).desktopTransmission, 0.65)
        XCTAssertGreaterThan(GlassBackdropWash.workspace(isDark: true).desktopTransmission, 0.60)
        // …and light, whose ask came next, passes at least a third more than the
        // 0.40/0.45 it shipped with.
        XCTAssertGreaterThan(
            GlassBackdropWash.sidebar(isDark: false).desktopTransmission, 0.40 * 1.33
        )
        XCTAssertGreaterThan(
            GlassBackdropWash.workspace(isDark: false).desktopTransmission, 0.45 * 1.33
        )
    }

    /// Dark's gradient carried half the light direction light's did — 0.0144 of
    /// modelled top-to-bottom luminance against 0.0283 — which is the other
    /// half of "flat". The veil's span is what expresses that, so it is the
    /// thing asserted.
    func testDarkVeilCarriesAsMuchLightDirectionAsLight() {
        for name in ["sidebar", "workspace"] {
            let light = name == "sidebar"
                ? GlassBackdropWash.sidebar(isDark: false)
                : GlassBackdropWash.workspace(isDark: false)
            let dark = name == "sidebar"
                ? GlassBackdropWash.sidebar(isDark: true)
                : GlassBackdropWash.workspace(isDark: true)
            let lightSpan = abs(light.topOpacity - light.bottomOpacity)
            let darkSpan = abs(dark.topOpacity - dark.bottomOpacity)
            XCTAssertGreaterThanOrEqual(
                darkSpan,
                lightSpan,
                "\(name): the dark veil has less light direction in it than the light one"
            )
        }
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
    ///
    /// The ceiling is per appearance now. In *both* appearances the "not a
    /// photograph" half of the contract is enforced by the **bake** — mean
    /// normalized to `targetLuminance`, range capped at
    /// `stillSpreadCeiling(isDark:)` — so the veil is no longer the thing
    /// standing between the user and a raw wallpaper, and holding either to an
    /// historical 0.50 would be pricing in a guarantee that is now made
    /// elsewhere. Light stays the tighter of the two because its *contrast*
    /// budget is tighter, not because it is unguarded.
    func testGlassVeilsFrostTheDesktopWithoutErasingIt() {
        for isDark in [false, true] {
            let band = GlassBackdropWash.desktopTransmissionBand(isDark: isDark)
            for (name, wash) in [
                ("sidebar", GlassBackdropWash.sidebar(isDark: isDark)),
                ("workspace", GlassBackdropWash.workspace(isDark: isDark)),
            ] {
                XCTAssertGreaterThanOrEqual(
                    wash.desktopTransmission,
                    band.floor,
                    "\(name) veil (isDark: \(isDark)) hides the desktop it exists to tint"
                )
                XCTAssertLessThanOrEqual(
                    wash.desktopTransmission,
                    band.ceiling,
                    "\(name) veil (isDark: \(isDark)) reads as a photograph, not as glass"
                )
            }
        }
        // Every ceiling past 0.50 is *bought* by the range cap, so the two have
        // to move together: relaxing a veil while deleting the cap that pays for
        // it is the combination that puts a raw wallpaper behind the labels.
        // Asserted for both appearances now that both carry a cap.
        XCTAssertGreaterThan(
            GlassBackdropWash.desktopTransmissionBand(isDark: true).ceiling,
            GlassBackdropWash.desktopTransmissionBand(isDark: false).ceiling
        )
        for isDark in [false, true] {
            XCTAssertLessThan(
                DesktopBackdropRenderer.stillSpreadCeiling(isDark: isDark), 0.45,
                "a veil past 0.50 transmission is unpaid for in \(isDark ? "dark" : "light")"
            )
        }
        // Light's cap is the tighter of the two, because its contrast budget is:
        // black ink on a near-white surface has less to spend than white ink on
        // a near-black one.
        XCTAssertLessThan(
            DesktopBackdropRenderer.lightStillSpreadCeiling,
            DesktopBackdropRenderer.darkStillSpreadCeiling
        )
    }


    /// The cool-cast regression, and why the old invariant could not catch it.
    ///
    /// The guard used to be ABSOLUTE — `blue - green <= 0.03` — and the dark
    /// veil was `#0B0C12`: 11/12/18 out of 255. That is a 0.024 absolute gap
    /// between blue and red, which sails through a 0.03 tolerance, and a **64%
    /// relative** blue lead, which at 0.60 coverage is most of what the eye
    /// sees. Michael reported it as "the glass has a blue-purple tone".
    ///
    /// An absolute tolerance is meaningless at near-black, so the invariant is
    /// relative: anything this app *declares* neutral has to hold every channel
    /// within 5% of its own mean. A near-black cannot fake that.
    func testDeclaredNeutralConstantsAreAchromatic() {
        /// Largest per-channel departure from the mean, as a fraction of it.
        func chromaticity(_ channels: [Double]) -> Double {
            let mean = channels.reduce(0, +) / Double(channels.count)
            guard mean > 0 else { return 0 }
            return channels.map { abs($0 - mean) / mean }.max() ?? 0
        }

        // Sanity: the measure sees what the old one missed. #0B0C12 reads as
        // 30% off-neutral; #0D0D0D reads as 0.
        XCTAssertGreaterThan(chromaticity([11.0 / 255, 12.0 / 255, 18.0 / 255]), 0.25)

        let neutrals: [(String, [Double])] = [
            ("dark veil", [
                GlassBackdropWash.darkVeil.red,
                GlassBackdropWash.darkVeil.green,
                GlassBackdropWash.darkVeil.blue,
            ]),
            ("tint fallback", [
                DesktopTintSampler.fallback.red,
                DesktopTintSampler.fallback.green,
                DesktopTintSampler.fallback.blue,
            ]),
            ("tint floors", [
                DesktopTintSampler.floors.red,
                DesktopTintSampler.floors.green,
                DesktopTintSampler.floors.blue,
            ]),
            ("tint ceilings", [
                DesktopTintSampler.ceilings.red,
                DesktopTintSampler.ceilings.green,
                DesktopTintSampler.ceilings.blue,
            ]),
        ] + [
            (false, "sidebar"), (true, "sidebar"), (false, "workspace"), (true, "workspace"),
        ].map { isDark, name -> (String, [Double]) in
            let wash = name == "sidebar"
                ? GlassBackdropWash.sidebar(isDark: isDark)
                : GlassBackdropWash.workspace(isDark: isDark)
            return ("\(name) wash (isDark: \(isDark))", [wash.red, wash.green, wash.blue])
        }

        for (name, channels) in neutrals {
            XCTAssertLessThanOrEqual(
                chromaticity(channels),
                0.05,
                "\(name) is not achromatic: \(channels) — it will tint the glass on its own"
            )
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
            XCTAssertLessThan(
                overlay,
                GlassBackdropWash.increasedContrastOverlayCeiling,
                "the ceiling is binding, so the 0.80 floor is being met by a clamp and not by arithmetic"
            )
        }
        // …and the ceiling still stops short of an opaque panel. Increased
        // Contrast is not a third opacity setting; Reduce Transparency and the
        // Solid sidebar are what turn the glass off.
        XCTAssertLessThan(GlassBackdropWash.increasedContrastOverlayCeiling, 1)
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
        guard case let .wallpaper(image, tint, _) = painting else {
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
        guard case let .wallpaper(image, _, _) = painting else {
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
        let tint = try XCTUnwrap(DesktopTintSampler.wallpaperAverage(rgba: [
            255, 0, 0, 255,
            0, 0, 255, 255,
        ]))
        XCTAssertEqual(tint.red, 0.3927, accuracy: 0.0001)
        XCTAssertEqual(tint.green, 0.0700, accuracy: 0.0001)
        XCTAssertEqual(tint.blue, 0.3927, accuracy: 0.0001)

        // The slate mix is gone, and this is what it was doing: an equal-parts
        // red/blue desktop used to come back with blue 0.015 ahead of red,
        // because 10% of a 0.35/0.42/0.50 slate was averaged into every tint
        // whatever the wallpaper was. A symmetric desktop now returns a
        // symmetric tint.
        XCTAssertEqual(tint.red, tint.blue, accuracy: 0.0001)

        // The property the numbers exist for. The pre-retune recipe returned
        // 0.3117/0.16/0.3387 for this same magenta desktop: a 0.179 spread,
        // which is already grey before any veil goes over it.
        let spread = max(tint.red, tint.green, tint.blue) - min(tint.red, tint.green, tint.blue)
        XCTAssertGreaterThan(spread, 0.30)
        XCTAssertGreaterThan(DesktopTintSampler.chromaRetention, 0.45)

        XCTAssertNil(DesktopTintSampler.wallpaperAverage(rgba: [0, 0, 0, 0]))
    }

    /// Retaining chroma must not invent it: a neutral desktop has to come back
    /// EXACTLY neutral. It used to come back 0.4868/0.4868/0.4868 — accidentally
    /// balanced, because a grey happened to be near the slate's own luminance —
    /// while a grey at any other brightness picked the slate's hue up as a cast.
    /// With the mix gone the identity is structural, not lucky.
    func testDesktopTintLeavesANeutralWallpaperNeutral() throws {
        for level: UInt8 in [40, 128, 220] {
            let tint = try XCTUnwrap(DesktopTintSampler.wallpaperAverage(rgba: [
                level, level, level, 255,
                level, level, level, 255,
            ]))
            XCTAssertEqual(tint.red, tint.green, accuracy: 0.0000001)
            XCTAssertEqual(tint.green, tint.blue, accuracy: 0.0000001)
            XCTAssertEqual(tint.red, Double(level) / 255, accuracy: 0.0001)
        }
    }

    /// The floors were 0.07/0.07/0.09, so a black desktop resolved to a *blue*
    /// near-black — the clamp invented the exact cast the veil was blamed for.
    func testClampingABlackWallpaperCannotInventAHue() throws {
        let tint = try XCTUnwrap(DesktopTintSampler.wallpaperAverage(rgba: [0, 0, 0, 255]))
        XCTAssertEqual(tint.red, tint.blue, accuracy: 0.0000001)
        XCTAssertEqual(tint.green, tint.blue, accuracy: 0.0000001)
        XCTAssertGreaterThan(tint.red, 0)
    }

    // MARK: - Frost

    /// The bake used to boost saturation 1.3×, from the era when a heavy veil
    /// ate the desktop's chroma and the still had to shout through it. Under
    /// the frost veil that inverted: measured off the shipped build, the
    /// sidebar's peak channel spread was 0.53 against the raw desktop's 0.33 —
    /// the "glass" was more colourful than the wallpaper it imitated. The veil
    /// decides how much desktop arrives; the bake must not put a thumb on it.
    ///
    /// **Round 8**: this constant no longer reaches the bake — chroma is solved
    /// against the finished still's measured Oklab colourfulness now, because a
    /// filter *input* says nothing about what a given wallpaper's hue does to
    /// the output. The statement is still worth keeping, because it is the
    /// round-7 pipeline the hue-invariance test freezes, and because the same
    /// "never boost" rule is what `okSaturationCeiling` asserts for the solve.
    func testWallpaperBakeCarriesNoSaturationBoost() {
        // The solved pipeline's own ceiling, which is where the rule lives now:
        // a target on the finished still's perceived colourfulness, never a
        // boost of whatever the wallpaper happened to have.
        XCTAssertLessThanOrEqual(DesktopBackdropRenderer.desktopChromaShare, 1.0)
        XCTAssertLessThanOrEqual(DesktopBackdropRenderer.darkDesktopChromaShare, 1.0)
        XCTAssertGreaterThan(DesktopBackdropRenderer.okSaturationCeiling, 0)

        // v1.1.8 goes one step further and CUTS chroma to 0.85: the surface
        // should not change personality with the desktop picture. The ceiling is
        // what this test is really for — the bake must never boost again — and
        // the floor keeps the cut from sliding toward a greyscale still, which
        // would make the whole painted-wallpaper layer pointless.
        XCTAssertEqual(DesktopBackdropRenderer.saturationCeiling, 0.85, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(DesktopBackdropRenderer.saturationCeiling, 1.0)
        XCTAssertGreaterThan(DesktopBackdropRenderer.saturationCeiling, 0.6)

        // In light the ceiling is what ships for any wallpaper dimmer than the
        // 0.72 target, which is nearly all of them.
        for mean in [0.20, 0.35, 0.50, 0.70] {
            XCTAssertEqual(
                DesktopBackdropRenderer.saturation(mean: mean, isDark: false),
                DesktopBackdropRenderer.saturationCeiling,
                accuracy: 0.0001
            )
        }
    }

    /// The dark cast, stated as the invariant that was missing.
    ///
    /// `luminanceShift` is additive — deliberately, so it moves the mean
    /// without touching channel *differences* — which means the bake normalized
    /// brightness and left chroma exactly where the wallpaper had it. In light
    /// the still is lifted to 0.72 and that absolute chroma is a small fraction
    /// of it; in dark it is crushed to 0.16 and the identical chroma is most of
    /// the surface. Measured on the real desktop, the dark composite came out
    /// 0.473 off-neutral against light's 0.059 — and against the desktop's own
    /// 0.400, i.e. glass more colourful than the wallpaper it imitates.
    ///
    /// The fix scales chroma by the same ratio the luminance moves by, so the
    /// composite's off-neutrality is a fixed multiple of the desktop's own
    /// whatever the desktop is. That multiple is what this pins.
    func testDarkBakeNormalizesChromaTheWayItNormalizesLuminance() {
        /// Largest per-channel departure from the mean over the mean — the same
        /// measure `testDeclaredNeutralConstantsAreAchromatic` uses.
        func offNeutral(_ channels: [Double]) -> Double {
            let mean = channels.reduce(0, +) / Double(channels.count)
            guard mean > 0 else { return 0 }
            return channels.map { abs($0 - mean) / mean }.max() ?? 0
        }

        /// One wallpaper, all the way to the eye: normalize, warm, veil.
        /// `saturation`/`warmth`/`base` are parameters so the release this
        /// replaces can be reproduced with the same arithmetic rather than
        /// described in a comment.
        func composite(
            wallpaper: [Double],
            saturation: Double,
            warmth: Double,
            base: Double,
            veil: [Double]
        ) -> [Double] {
            let mean = wallpaper[0] * 0.2126 + wallpaper[1] * 0.7152 + wallpaper[2] * 0.0722
            let shift = DesktopBackdropRenderer.luminanceShift(mean: mean, isDark: true)
            let still = wallpaper.map { mean + ($0 - mean) * saturation + shift }
            let amber = [GlassWarmth.red, GlassWarmth.green, GlassWarmth.blue]
            let warmed = zip(still, amber).map { $0 * (1 - warmth) + $1 * warmth }
            return zip(warmed, veil).map { $0 * (1 - base) + $1 * base }
        }

        let wash = GlassBackdropWash.sidebar(isDark: true)
        let darkVeil = [wash.red, wash.green, wash.blue]

        // Michael's actual desktop: an Aerial still averaging a decidedly blue
        // 0.263/0.476/0.576. Plus a magenta and a green, so the guarantee is not
        // a property of one picture.
        for wallpaper in [[0.263, 0.476, 0.576], [0.62, 0.21, 0.58], [0.18, 0.44, 0.21]] {
            let mean = wallpaper[0] * 0.2126 + wallpaper[1] * 0.7152 + wallpaper[2] * 0.0722
            let desktop = offNeutral(wallpaper)

            let shipped = offNeutral(composite(
                wallpaper: wallpaper,
                saturation: DesktopBackdropRenderer.saturation(mean: mean, isDark: true),
                warmth: GlassWarmth.opacity(isDark: true),
                base: wash.baseOpacity,
                veil: darkVeil
            ))
            // v1.1.9: chroma unscaled, warmth at the light coverage, veil 0.60.
            let before = offNeutral(composite(
                wallpaper: wallpaper,
                saturation: DesktopBackdropRenderer.saturationCeiling,
                warmth: GlassWarmth.opacity,
                base: 0.60,
                veil: darkVeil
            ))

            XCTAssertGreaterThan(
                before,
                desktop,
                "the regression this fixes is that the dark glass out-saturated the desktop"
            )
            XCTAssertLessThan(
                shipped,
                desktop,
                "the dark glass is still more off-neutral than the desktop it samples: \(wallpaper)"
            )
            // Roughly wallpaper-independent, which is the point of normalizing
            // at all: before, the multiple sat at 1.0–1.3 and the surface's
            // colour was whatever the desktop happened to be. v1.1.10's dark
            // saturation ceiling takes the band down again, from 0.5–0.7 to
            // 0.25–0.50 — the second half of "still reads a little blue".
            XCTAssertLessThan(shipped / desktop, 0.55, "for \(wallpaper)")
            XCTAssertGreaterThan(
                shipped / desktop,
                0.20,
                "the wallpaper has been greyed out rather than damped: \(wallpaper)"
            )
        }
    }

    /// The bug behind "the dark glass still reads flat", and the test that
    /// would have caught it: the bake has to actually *arrive* at the luminance
    /// it declares.
    ///
    /// Every other test here checks the constants and the arithmetic around
    /// them. None of them rendered anything, so none of them noticed that
    /// `CIColorControls.brightness` is applied in `CIContext`'s working space —
    /// linear sRGB by default — while `luminanceShift` is measured from
    /// gamma-encoded bytes. Subtracting an encoded quantity from linear values
    /// drove the dark still 79.7% pure black: mean luminance 0.002 against the
    /// 0.16 it declares, a veil over nothing.
    ///
    /// Rendering three synthetic wallpapers end to end and measuring what comes
    /// out is the only form of this test that could have failed.
    func testTheBakeArrivesAtTheLuminanceItDeclares() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-bake-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A gradient, so the still has real luminance structure to preserve —
        // a flat colour would pass even a bake that crushed every gradient to
        // one value.
        func writeWallpaper(base: (Double, Double, Double), name: String) throws -> URL {
            let side = 256
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            for y in 0..<side {
                // 0.55×…1.45× across the frame.
                let ramp = 0.55 + 0.9 * Double(y) / Double(side - 1)
                context.setFillColor(
                    red: min(1, base.0 * ramp), green: min(1, base.1 * ramp),
                    blue: min(1, base.2 * ramp), alpha: 1
                )
                context.fill(CGRect(x: 0, y: y, width: side, height: 1))
            }
            let url = directory.appending(path: "\(name).png")
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil
            )!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }

        /// Mean Rec. 709 luma of a rendered painting, plus the share of it that
        /// clamped to pure black and its p5..p95 luminance spread.
        func measure(_ image: CGImage) -> (mean: Double, black: Double, spread: Double) {
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
            var lumas: [Double] = []
            var black = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let red = Double(pixels[index]) / 255
                let green = Double(pixels[index + 1]) / 255
                let blue = Double(pixels[index + 2]) / 255
                lumas.append(red * 0.2126 + green * 0.7152 + blue * 0.0722)
                if pixels[index] == 0, pixels[index + 1] == 0, pixels[index + 2] == 0 { black += 1 }
            }
            lumas.sort()
            let count = Double(lumas.count)
            return (
                lumas.reduce(0, +) / count,
                Double(black) / count,
                lumas[Int(count * 0.95)] - lumas[Int(count * 0.05)]
            )
        }

        // `maximumBlack`: how much of the baked still may clamp to zero.
        //
        // A linear ramp is the adversarial case for this, and deliberately so —
        // a Gaussian leaves a linear gradient untouched, so unlike a real
        // photograph none of the fixture's range is softened away before the
        // normalization sees it. Two of the three hold the tight bound. The
        // bright one cannot and the arithmetic says why: its mean is 0.78, dark
        // normalizes to 0.16, and an additive shift of −0.62 puts everything
        // below 0.62 at zero — a quarter of a ±45% ramp. It is allowed 0.30
        // rather than being quietly dropped, and the surface it produces is
        // still the opposite of the bug (spread 0.37, against the 0.014 that
        // shipped). Every real wallpaper on this machine, including the
        // brightest aerial Apple ships at luma 0.79, measured 0.0% — a blurred
        // photograph's range collapses where a ramp's does not.
        let wallpapers: [(name: String, base: (Double, Double, Double), maximumBlack: Double)] = [
            // Michael's own desktop's average: a decidedly blue aerial.
            ("aerial", (0.263, 0.476, 0.575), 0.02),
            ("bright", (0.82, 0.80, 0.76), 0.30),
            ("dim", (0.11, 0.13, 0.16), 0.02),
        ]

        for (name, base, maximumBlack) in wallpapers {
            let url = try writeWallpaper(base: base, name: name)
            for isDark in [true, false] {
                let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: isDark)
                guard case let .wallpaper(image, _, _)? = DesktopBackdropRenderer.render(key: key) else {
                    return XCTFail("\(name) (isDark: \(isDark)) produced no painting")
                }
                let measured = measure(image)
                let target = DesktopBackdropRenderer.targetLuminance(isDark: isDark)

                // The headline: what the veil's coverage arithmetic assumes.
                // Before the working-space fix the dark row here measured 0.002.
                XCTAssertEqual(
                    measured.mean, target, accuracy: 0.06,
                    "\(name) (isDark: \(isDark)) baked to \(measured.mean), not the \(target) it declares"
                )
                // A still that clamps is a still whose structure is gone. This
                // is the direct form of the flatness: 80% of the dark bake was
                // one value, and one value is what "flat" means.
                XCTAssertLessThanOrEqual(
                    measured.black, maximumBlack,
                    "\(name) (isDark: \(isDark)) clamped \(Int(measured.black * 100))% of the still to black"
                )
                // …and the wallpaper's own light and shade have to survive to
                // the veil, or there is nothing for the glass to show. This is
                // the assertion that actually fails on the pre-v1.1.10 bake: it
                // delivered 0.014 here, against the 0.09–0.49 below.
                XCTAssertGreaterThan(
                    measured.spread, 0.05,
                    "\(name) (isDark: \(isDark)) arrived with no luminance structure left"
                )
            }
        }
    }

    /// The measurement and the operation have to happen in the same space —
    /// which is the whole of the bug above, stated as the constant that fixes
    /// it. `DesktopTintSampler.meanLuminance` reads gamma-encoded bytes out of a
    /// `DeviceRGB` context, so the filter chain that consumes its output must be
    /// asked for a gamma-encoded working space rather than CoreImage's linear
    /// default.
    func testTheBakeWorksInTheSpaceItsNormalizationIsMeasuredIn() throws {
        let space = try XCTUnwrap(DesktopBackdropRenderer.bakeColorSpace)
        XCTAssertEqual(space.name, CGColorSpace.sRGB)
        // Not `NSNull`/unmanaged: a Display P3 wallpaper still has to be
        // converted before its bytes may be treated as sRGB.
        XCTAssertFalse(space.isWideGamutRGB)
    }

    // MARK: - Dark translucency

    /// A wallpaper fixture: a vertical ramp around `base`, with `range`
    /// controlling how much luminance structure it carries. A flat colour would
    /// pass a bake that crushed every gradient to one value, and a *narrow* ramp
    /// would pass one that let a wide one through.
    private func writeRampWallpaper(
        base: (Double, Double, Double),
        range: Double,
        into directory: URL,
        named name: String
    ) throws -> URL {
        let side = 256
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in 0..<side {
            let ramp = (1 - range / 2) + range * Double(y) / Double(side - 1)
            context.setFillColor(
                red: min(1, base.0 * ramp), green: min(1, base.1 * ramp),
                blue: min(1, base.2 * ramp), alpha: 1
            )
            context.fill(CGRect(x: 0, y: y, width: side, height: 1))
        }
        let url = directory.appending(path: "\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// The shipped glass stack, rendered: the baked still stretched over the
    /// surface, `GlassWarmth` over it, the veil gradient over that. Exactly the
    /// three layers `DesktopGlassLayer` + `SidebarBackdropView` compose, in the
    /// same order, with the same constants.
    private func renderGlassSurface(
        still: CGImage,
        wash: GlassBackdropWash,
        isDark: Bool,
        width: Int,
        height: Int,
        crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        warmth: Double? = nil
    ) throws -> [UInt8] {
        // `DesktopWallpaperPatch` draws the still through a `contentsRect`;
        // cropping the `CGImage` to the same unit rectangle is the same
        // operation in CoreGraphics, and both count y **down from the top**.
        let patch: CGImage
        if crop == CGRect(x: 0, y: 0, width: 1, height: 1) {
            patch = still
        } else {
            patch = try XCTUnwrap(still.cropping(to: CGRect(
                x: (crop.minX * CGFloat(still.width)).rounded(.down),
                y: (crop.minY * CGFloat(still.height)).rounded(.down),
                width: max(1, (crop.width * CGFloat(still.width)).rounded()),
                height: max(1, (crop.height * CGFloat(still.height)).rounded())
            )))
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.interpolationQuality = .high
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.draw(patch, in: rect)
            context.setFillColor(
                red: GlassWarmth.red, green: GlassWarmth.green, blue: GlassWarmth.blue,
                alpha: warmth ?? GlassWarmth.opacity(isDark: isDark)
            )
            context.fill(rect)

            let space = CGColorSpaceCreateDeviceRGB()
            var stops: [CGColor] = []
            for alpha in [wash.topOpacity, wash.baseOpacity, wash.bottomOpacity] {
                let components: [CGFloat] = [
                    CGFloat(wash.red), CGFloat(wash.green), CGFloat(wash.blue), CGFloat(alpha),
                ]
                stops.append(try XCTUnwrap(CGColor(colorSpace: space, components: components)))
            }
            let gradient = try XCTUnwrap(CGGradient(
                colorsSpace: space, colors: stops as CFArray, locations: [0, 0.5, 1]
            ))
            // CoreGraphics' origin is bottom-left, so `.topLeading` is (0, h).
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: height),
                end: CGPoint(x: width, y: 0),
                options: []
            )
        }
        return pixels
    }

    /// WCAG relative luminance and contrast ratio, and the label alphas macOS
    /// actually uses: `labelColor` is white at 0.85 in dark, `secondaryLabelColor`
    /// white at 0.55.
    private func contrastRatio(text: (Double, Double, Double), over bg: (Double, Double, Double))
        -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        func luminance(_ colour: (Double, Double, Double)) -> Double {
            0.2126 * linear(colour.0) + 0.7152 * linear(colour.1) + 0.0722 * linear(colour.2)
        }
        let a = luminance(text)
        let b = luminance(bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Label contrast against the **worst patch** of a rendered surface: the
    /// mean of its brightest 2% of pixels, which is where white text on a dark
    /// glass surface is hardest to read. Strictly harsher than the round-2
    /// harness's single p95 sample, and both are reported by the sweep that
    /// chose these constants.
    private func worstPatchContrast(_ pixels: [UInt8], isDark: Bool)
        -> (primary: Double, secondary: Double, patch: (Double, Double, Double)) {
        var colours: [(Double, (Double, Double, Double))] = []
        colours.reserveCapacity(pixels.count / 4)
        var index = 0
        while index + 3 < pixels.count {
            let colour = (
                Double(pixels[index]) / 255,
                Double(pixels[index + 1]) / 255,
                Double(pixels[index + 2]) / 255
            )
            colours.append((colour.0 * 0.2126 + colour.1 * 0.7152 + colour.2 * 0.0722, colour))
            index += 4
        }
        colours.sort { $0.0 < $1.0 }
        let count = max(1, colours.count / 50)
        let band = isDark ? Array(colours.suffix(count)) : Array(colours.prefix(count))
        var patch = (0.0, 0.0, 0.0)
        for (_, colour) in band {
            patch = (patch.0 + colour.0, patch.1 + colour.1, patch.2 + colour.2)
        }
        patch = (patch.0 / Double(count), patch.1 / Double(count), patch.2 / Double(count))

        func label(alpha: Double) -> (Double, Double, Double) {
            let ink = isDark ? 1.0 : 0.0
            return (
                ink * alpha + patch.0 * (1 - alpha),
                ink * alpha + patch.1 * (1 - alpha),
                ink * alpha + patch.2 * (1 - alpha)
            )
        }
        return (
            contrastRatio(text: label(alpha: 0.85), over: patch),
            contrastRatio(text: label(alpha: isDark ? 0.55 : 0.5), over: patch),
            patch
        )
    }

    /// Separable box blur, three passes ≈ a Gaussian. Radius in surface pixels.
    private func boxBlurred(_ plane: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        var buffer = plane
        var scratch = [Double](repeating: 0, count: plane.count)
        let denominator = Double(2 * radius + 1)
        for _ in 0..<3 {
            for y in 0..<height {
                let row = y * width
                var accumulator = 0.0
                for x in -radius...radius {
                    accumulator += buffer[row + min(max(x, 0), width - 1)]
                }
                for x in 0..<width {
                    scratch[row + x] = accumulator / denominator
                    accumulator += buffer[row + min(max(x + radius + 1, 0), width - 1)]
                        - buffer[row + min(max(x - radius, 0), width - 1)]
                }
            }
            for x in 0..<width {
                var accumulator = 0.0
                for y in -radius...radius {
                    accumulator += scratch[min(max(y, 0), height - 1) * width + x]
                }
                for y in 0..<height {
                    buffer[y * width + x] = accumulator / denominator
                    accumulator += scratch[min(max(y + radius + 1, 0), height - 1) * width + x]
                        - scratch[min(max(y - radius, 0), height - 1) * width + x]
                }
            }
        }
        return buffer
    }

    /// **The detail metric**: RMS of the high-pass residual of a rendered
    /// surface's luminance — "how much of the wallpaper's *texture* is in the
    /// glass", as distinct from how much of its colour or its overall gradient.
    ///
    /// This is the measurement the round-7 ask needed and no previous round had.
    /// Every existing metric here — transmission, composite rgb, luminance
    /// spread, chroma — is satisfied by a surface that is a single smooth
    /// gradient, and that is exactly what the bake was producing: measured on
    /// the shipped pipeline, `spread` and `gradient` agreed to three decimals on
    /// every fixture, meaning **all** of the surface's luminance range was the
    /// veil's own top-to-bottom ramp and none of it was the picture. "It picks
    /// up the colour but not the vibe" is that identity, in words.
    ///
    /// Subtracting a heavily blurred copy leaves only what varies *within* a
    /// neighbourhood, so the veil's full-surface gradient contributes nothing
    /// and a wallpaper's shapes, horizon and cloud masses contribute everything.
    /// A radius of 32 on a 900px surface rejects anything slower than about a
    /// ninth of the surface, which is well clear of the veil.
    private func localDetail(_ pixels: [UInt8], width: Int, height: Int) -> Double {
        var plane = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let pixel = index * 4
            plane[index] = Double(pixels[pixel]) / 255 * 0.2126
                + Double(pixels[pixel + 1]) / 255 * 0.7152
                + Double(pixels[pixel + 2]) / 255 * 0.0722
        }
        let low = boxBlurred(plane, width: width, height: height, radius: 32)
        var sum = 0.0
        var sumSquares = 0.0
        for index in 0..<plane.count {
            let residual = plane[index] - low[index]
            sum += residual
            sumSquares += residual * residual
        }
        let count = Double(plane.count)
        let mean = sum / count
        return max(0, sumSquares / count - mean * mean).squareRoot()
    }

    /// p5..p95 luminance spread of a rendered surface — "how much of the
    /// wallpaper's light and shade is in the glass", which is what "translucent"
    /// means once brightness has been normalized away.
    private func luminanceSpread(_ pixels: [UInt8]) -> Double {
        var lumas: [Double] = []
        lumas.reserveCapacity(pixels.count / 4)
        var index = 0
        while index + 3 < pixels.count {
            lumas.append(
                Double(pixels[index]) / 255 * 0.2126
                    + Double(pixels[index + 1]) / 255 * 0.7152
                    + Double(pixels[index + 2]) / 255 * 0.0722
            )
            index += 4
        }
        lumas.sort()
        let count = Double(lumas.count)
        return lumas[Int(count * 0.95)] - lumas[Int(count * 0.05)]
    }

    /// The constraint that decides how translucent dark is allowed to be, held
    /// where it actually bites: the brightest patch of the surface, on the
    /// widest range of wallpapers, not the average of a well-behaved one.
    ///
    /// This is the test that says the veil retune is safe. Thinning the dark
    /// veil from 0.52 to 0.33 *without* `darkStillSpreadCeiling` put the worst
    /// patch of a high-dynamic-range wallpaper at 3.9:1 secondary — below the
    /// 4.5 floor — because the bake normalized the still's mean and left its
    /// range to the desktop. With the cap the same surface measures 4.7:1.
    func testDarkGlassStaysLegibleOnTheWorstPatchOfEveryWallpaper() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-worstpatch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The five extremes of this Mac's aerial library, reproduced as ramps
        // by their measured average and spread, plus one adversarial fixture
        // wider than anything Apple ships.
        let wallpapers: [(name: String, base: (Double, Double, Double), range: Double)] = [
            ("aerial", (0.263, 0.476, 0.575), 0.9),     // Michael's own desktop
            ("dim", (0.06, 0.07, 0.09), 0.9),
            ("bright", (0.82, 0.80, 0.76), 0.7),
            ("saturated", (0.42, 0.20, 0.08), 0.8),
            ("neutral-wide", (0.435, 0.435, 0.435), 1.6),
            ("adversarial", (0.5, 0.5, 0.5), 1.95),
        ]

        for (name, base, range) in wallpapers {
            let url = try writeRampWallpaper(base: base, range: range, into: directory, named: name)
            for (surface, wash, width, height) in [
                ("sidebar", GlassBackdropWash.sidebar(isDark: true), 210, 900),
                ("workspace", GlassBackdropWash.workspace(isDark: true), 900, 900),
            ] {
                let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: true)
                guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key) else {
                    return XCTFail("\(name) produced no painting")
                }
                let pixels = try renderGlassSurface(
                    still: still, wash: wash, isDark: true, width: width, height: height
                )
                let worst = worstPatchContrast(pixels, isDark: true)
                print(String(
                    format: "[dark-glass] %@ %@ worst patch %.3f/%.3f/%.3f  primary %.2f:1  secondary %.2f:1  spread %.4f",
                    name, surface, worst.patch.0, worst.patch.1, worst.patch.2,
                    worst.primary, worst.secondary, luminanceSpread(pixels)
                ))
                XCTAssertGreaterThanOrEqual(
                    worst.primary, 7,
                    "\(name) \(surface): primary label on the worst patch is \(worst.primary):1"
                )
                XCTAssertGreaterThanOrEqual(
                    worst.secondary, 4.5,
                    "\(name) \(surface): secondary label on the worst patch is \(worst.secondary):1"
                )
            }
        }
    }

    /// The light half of the same constraint, and the place where the stated
    /// floor is honestly not met — so it is written down as an assertion rather
    /// than as a sentence in a report.
    ///
    /// Light's **primary** clears 7:1 with room to spare. Light's **secondary**
    /// cannot reach 4.5:1 on any surface, and that is not a property of the
    /// veil: AppKit's `secondaryLabelColor` in Aqua is black at α 0.498, and
    /// black at α 0.498 over *pure white* — the brightest background that can
    /// exist — is 3.98:1. The first assertion below proves that, so the number
    /// this test does hold light to is a measured ceiling and not a guess.
    ///
    /// What is therefore asserted is the thing that is actually in the app's
    /// control: the worst patch stays at or above the figure the **previous**
    /// constants delivered (3.43:1 over the five aerial extremes, 3.17:1 over
    /// the adversarial ramps), so the translucency retune did not buy itself
    /// legibility. 3.4 is that bound with the fixture's own margin.
    func testLightGlassStaysLegibleOnTheWorstPatchOfEveryWallpaper() throws {
        // The ceiling, proved rather than asserted. `secondaryLabelColor` is
        // read from AppKit itself so this cannot drift away from the platform.
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        var secondaryAlpha = 0.0
        aqua.performAsCurrentDrawingAppearance {
            secondaryAlpha = Double(
                (NSColor.secondaryLabelColor.usingColorSpace(.sRGB)?.alphaComponent) ?? 0
            )
        }
        XCTAssertEqual(secondaryAlpha, 0.498, accuracy: 0.01)
        let bestPossible = contrastRatio(
            text: (1 - secondaryAlpha, 1 - secondaryAlpha, 1 - secondaryAlpha),
            over: (1, 1, 1)
        )
        XCTAssertLessThan(
            bestPossible, 4.5,
            """
            AppKit's secondary label now reaches \(bestPossible):1 on pure white, \
            so the 4.5 floor is reachable in light after all and this test should \
            be tightened to hold it.
            """
        )

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-lightpatch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The same six fixtures the dark test uses, so the two appearances are
        // held to the same wallpapers.
        let wallpapers: [(name: String, base: (Double, Double, Double), range: Double)] = [
            ("aerial", (0.263, 0.476, 0.575), 0.9),     // Michael's own desktop
            ("dim", (0.06, 0.07, 0.09), 0.9),
            ("bright", (0.82, 0.80, 0.76), 0.7),
            ("saturated", (0.42, 0.20, 0.08), 0.8),
            ("neutral-wide", (0.435, 0.435, 0.435), 1.6),
            ("adversarial", (0.5, 0.5, 0.5), 1.95),
        ]

        for (name, base, range) in wallpapers {
            let url = try writeRampWallpaper(base: base, range: range, into: directory, named: name)
            for (surface, wash, width, height) in [
                ("sidebar", GlassBackdropWash.sidebar(isDark: false), 210, 900),
                ("workspace", GlassBackdropWash.workspace(isDark: false), 900, 900),
            ] {
                let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: false)
                guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key) else {
                    return XCTFail("\(name) produced no painting")
                }
                let pixels = try renderGlassSurface(
                    still: still, wash: wash, isDark: false, width: width, height: height
                )
                let worst = worstPatchContrast(pixels, isDark: false)
                print(String(
                    format: "[light-glass] %@ %@ worst patch %.3f/%.3f/%.3f  primary %.2f:1  secondary %.2f:1  spread %.4f",
                    name, surface, worst.patch.0, worst.patch.1, worst.patch.2,
                    worst.primary, worst.secondary, luminanceSpread(pixels)
                ))
                XCTAssertGreaterThanOrEqual(
                    worst.primary, 7,
                    "\(name) \(surface): primary label on the worst patch is \(worst.primary):1"
                )
                XCTAssertGreaterThanOrEqual(
                    worst.secondary, 3.4,
                    """
                    \(name) \(surface): secondary label on the worst patch is \
                    \(worst.secondary):1, below what the pre-retune veil delivered
                    """
                )
            }
        }
    }

    /// The mechanism that *would* lift light's secondary over the floor, kept as
    /// a live measurement rather than a note: a custom ink instead of the system
    /// semantic. Recorded here so the follow-up has a number, and so it stops
    /// being true the moment the surface drifts far enough that it would not
    /// work.
    func testACustomSecondaryInkWouldClearTheFloorOnLightGlass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-lightink-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The worst of the six: the widest range on the deeper of the two
        // surfaces is where every light worst case in this file is found.
        let url = try writeRampWallpaper(
            base: (0.5, 0.5, 0.5), range: 1.95, into: directory, named: "adversarial"
        )
        let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: false)
        guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key) else {
            return XCTFail("the adversarial fixture produced no painting")
        }
        let pixels = try renderGlassSurface(
            still: still, wash: GlassBackdropWash.workspace(isDark: false),
            isDark: false, width: 900, height: 900
        )
        let patch = worstPatchContrast(pixels, isDark: false).patch
        func inked(_ alpha: Double) -> Double {
            contrastRatio(
                text: (patch.0 * (1 - alpha), patch.1 * (1 - alpha), patch.2 * (1 - alpha)),
                over: patch
            )
        }
        print(String(
            format: "[light-glass] worst-patch secondary: AppKit α0.498 %.2f:1, custom α0.60 %.2f:1",
            inked(0.498), inked(0.60)
        ))
        XCTAssertLessThan(inked(0.498), 4.5, "the system semantic clears the floor after all")
        XCTAssertGreaterThanOrEqual(
            inked(0.60), 4.5,
            "a custom α0.60 ink no longer buys the floor; the follow-up needs re-deriving"
        )
    }

    /// A wallpaper with the mid-frequency structure a photograph has — a
    /// horizon, soft masses, two octaves of large-scale texture — around the
    /// same base and range as the matching ramp fixture.
    ///
    /// The ramps cannot serve here and that is the point: a linear ramp passes a
    /// Gaussian untouched, which makes it the right adversarial fixture for a
    /// *range* cap and a useless one for a *detail* metric, because it has no
    /// detail to carry. Every fixture in this file until now was blur-invariant,
    /// which is precisely why nothing noticed the glass had no texture in it.
    private func writeStructuredWallpaper(
        base: (Double, Double, Double),
        range: Double,
        into directory: URL,
        named name: String
    ) throws -> URL {
        let side = 768
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        func value(_ nx: Double, _ ny: Double) -> Double {
            var value = (1 - range / 2) + range * ny
            // A horizon: a soft step across the frame.
            value += range * 0.22 * (1 / (1 + exp(-(ny - 0.58) * 46)) - 0.5)
            // Three soft masses — headland, cloud bank, haze.
            func mass(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ amplitude: Double)
                -> Double {
                let dx = (nx - cx) / rx
                let dy = (ny - cy) / ry
                return amplitude * exp(-(dx * dx + dy * dy) * 2.2)
            }
            value += range * mass(0.26, 0.72, 0.30, 0.20, 0.30)
            value += range * mass(0.74, 0.44, 0.34, 0.16, -0.26)
            value += range * mass(0.52, 0.18, 0.22, 0.13, 0.20)
            value += range * 0.075 * sin(nx * 7.3 + ny * 3.1) * cos(ny * 5.9 - nx * 2.2)
            value += range * 0.035 * sin(nx * 15.7 - ny * 11.3) * cos(ny * 13.1 + nx * 6.5)
            return max(0, value)
        }
        for y in 0..<side {
            let ny = Double(y) / Double(side - 1)
            for x in 0..<side {
                let nx = Double(x) / Double(side - 1)
                let scale = value(nx, ny)
                let index = (y * side + x) * 4
                pixels[index] = UInt8(min(255, max(0, base.0 * scale * 255)))
                pixels[index + 1] = UInt8(min(255, max(0, base.1 * scale * 255)))
                pixels[index + 2] = UInt8(min(255, max(0, base.2 * scale * 255)))
            }
        }
        var image: CGImage?
        pixels.withUnsafeMutableBytes { bytes in
            image = CGContext(
                data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let url = directory.appending(path: "\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // MARK: - The hue family

    /// One structured wallpaper, written at a chosen hue — the fixture family
    /// the hue-invariance contract is measured on.
    ///
    /// Every member is **identical in HSV value and HSV saturation** and differs
    /// only in hue, so any difference the pipeline produces in the *lightness*
    /// or the *colourfulness* of the finished surface is the pipeline's, not the
    /// wallpaper's. The value field is the same horizon-plus-masses field
    /// `writeStructuredWallpaper` uses, so this is a photograph-shaped fixture
    /// rather than a flat swatch.
    private func writeHueWallpaper(
        hue: Double,
        saturation: Double,
        into directory: URL,
        named name: String
    ) throws -> URL {
        let side = 768
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        func value(_ nx: Double, _ ny: Double) -> Double {
            var value = 0.5 + 0.42 * (ny - 0.5)
            value += 0.09 * (1 / (1 + exp(-(ny - 0.58) * 46)) - 0.5)
            func mass(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ amplitude: Double)
                -> Double {
                let dx = (nx - cx) / rx
                let dy = (ny - cy) / ry
                return amplitude * exp(-(dx * dx + dy * dy) * 2.2)
            }
            value += mass(0.26, 0.72, 0.30, 0.20, 0.13)
            value += mass(0.74, 0.44, 0.34, 0.16, -0.11)
            value += mass(0.52, 0.18, 0.22, 0.13, 0.09)
            value += 0.032 * sin(nx * 7.3 + ny * 3.1) * cos(ny * 5.9 - nx * 2.2)
            value += 0.015 * sin(nx * 15.7 - ny * 11.3) * cos(ny * 13.1 + nx * 6.5)
            return min(1, max(0.02, value))
        }
        for y in 0..<side {
            let ny = Double(y) / Double(side - 1)
            for x in 0..<side {
                let nx = Double(x) / Double(side - 1)
                let rgb = Self.hsvToRGB(hue: hue, saturation: saturation, value: value(nx, ny))
                let index = (y * side + x) * 4
                pixels[index] = UInt8(min(255, max(0, rgb.0 * 255)))
                pixels[index + 1] = UInt8(min(255, max(0, rgb.1 * 255)))
                pixels[index + 2] = UInt8(min(255, max(0, rgb.2 * 255)))
            }
        }
        var image: CGImage?
        pixels.withUnsafeMutableBytes { bytes in
            image = CGContext(
                data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let url = directory.appending(path: "\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    static func hsvToRGB(hue: Double, saturation: Double, value: Double)
        -> (Double, Double, Double) {
        let chroma = value * saturation
        let sector = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base: (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, second, 0)
        case 1: (second, chroma, 0)
        case 2: (0, chroma, second)
        case 3: (0, second, chroma)
        case 4: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        let floor = value - chroma
        return (base.0 + floor, base.1 + floor, base.2 + floor)
    }

    /// The two quantities the hue-invariance contract is stated in, read off a
    /// rendered surface: **perceived lightness** (Oklab L*, the mean over the
    /// surface) and **colourfulness relative to that lightness** (Oklab chroma
    /// over L*, which is the perceptual analogue of HSV saturation and the thing
    /// "it becomes white" and "it is very green" are each half of).
    ///
    /// Oklab rather than Rec. 709 luma precisely because luma is the quantity
    /// that produced the bug: it weights green 9.9× blue, so it reads a blue
    /// picture as almost black and a green one as almost white.
    private func perceivedSurface(_ pixels: [UInt8])
        -> (lightness: Double, saturation: Double, chroma: Double) {
        var lightness = 0.0
        var chroma = 0.0
        var saturation = 0.0
        var count = 0.0
        var index = 0
        while index + 3 < pixels.count {
            let lab = Self.oklab(
                Double(pixels[index]) / 255,
                Double(pixels[index + 1]) / 255,
                Double(pixels[index + 2]) / 255
            )
            let magnitude = (lab.a * lab.a + lab.b * lab.b).squareRoot()
            lightness += lab.L
            chroma += magnitude
            saturation += magnitude / max(lab.L, 0.001)
            count += 1
            index += 4
        }
        return (lightness / count, saturation / count, chroma / count)
    }

    /// Oklab from gamma-encoded sRGB.
    static func oklab(_ red: Double, _ green: Double, _ blue: Double)
        -> (L: Double, a: Double, b: Double) {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let r = linear(red)
        let g = linear(green)
        let b = linear(blue)
        let long = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let medium = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let short = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            L: 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            a: 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
            b: 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
        )
    }

    // MARK: - The glass is where the window is

    /// **The round-8 contract, half one**: a glass surface shows the region of
    /// wallpaper that is actually behind it.
    ///
    /// Michael: "we don't get the translucence at all. I meant the glass
    /// wallpaper should be translucent to the wallpaper itself (like
    /// transparent)." Three rounds of veil-thinning could not deliver that,
    /// because the layer under the veil was **one still stretched across every
    /// surface** — a blurry photograph of the whole desktop painted onto a
    /// panel, identical whether the window sat on the left of the screen or the
    /// right. Nothing in it corresponded to what was behind the window and
    /// nothing in it moved when the window moved, which is precisely what
    /// transparency is.
    ///
    /// The numbers below are the arithmetic of "behind": a window at x pt on a
    /// display shows the wallpaper at x pt. They are hand-computed from the
    /// fixture rather than re-derived from the code under test.
    func testEachGlassSurfaceShowsTheWallpaperRegionBehindIt() {
        // A Retina laptop: 1512×982 pt, 2× backing, a wallpaper that is exactly
        // the display's pixel size, "Fill Screen".
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let wallpaper = CGSize(width: 3024, height: 1964)
        func sample(_ surface: CGRect) -> CGRect {
            DesktopBackdropGeometry.contentsRect(
                surface: surface, imagePixels: wallpaper, screen: screen,
                scaling: .scaleProportionallyUpOrDown, allowsClipping: true, backingScale: 2
            )
        }

        // A 210 pt sidebar in a window 100 pt from the left edge, 60 pt up.
        // 100/1512 across, (982 − 960)/982 down, 210/1512 wide, 900/982 tall.
        let left = sample(CGRect(x: 100, y: 60, width: 210, height: 900))
        XCTAssertEqual(left.minX, 100.0 / 1512, accuracy: 1e-6)
        XCTAssertEqual(left.minY, 22.0 / 982, accuracy: 1e-6)
        XCTAssertEqual(left.width, 210.0 / 1512, accuracy: 1e-6)
        XCTAssertEqual(left.height, 900.0 / 982, accuracy: 1e-6)

        // Drag the window 300 pt right: the sample slides 300 pt of wallpaper
        // right and does nothing else. This is the whole behaviour — the
        // backdrop stays put while the window travels over it.
        let dragged = sample(CGRect(x: 400, y: 60, width: 210, height: 900))
        XCTAssertEqual(dragged.minX - left.minX, 300.0 / 1512, accuracy: 1e-6)
        XCTAssertEqual(dragged.minY, left.minY, accuracy: 1e-9)
        XCTAssertEqual(dragged.width, left.width, accuracy: 1e-9)

        // Down 40 pt: in AppKit the window's y *falls*, so the sample walks
        // *down* the image. Getting this flip wrong is the classic version of
        // this bug and it is invisible on a symmetric fixture. (40 pt, because
        // a 900 pt surface on a 982 pt display has only 82 pt of travel before
        // it runs off an edge and the clamp below takes over.)
        let lowered = sample(CGRect(x: 100, y: 20, width: 210, height: 900))
        XCTAssertEqual(lowered.minY - left.minY, 40.0 / 982, accuracy: 1e-6)

        // A second display, larger and to the right, with its own origin and
        // its own backing scale. What must hold is that the wallpaper is still
        // sampled at the *display's* scale — a 210 pt surface covers 210 pt of
        // that display's wallpaper — and that it is a different part of the
        // picture from the one the same window showed on display one.
        let second = CGRect(x: 1512, y: -230, width: 2560, height: 1440)
        let secondFrame = DesktopBackdropGeometry.wallpaperFrame(
            imagePixels: wallpaper, screen: second,
            scaling: .scaleProportionallyUpOrDown, allowsClipping: true, backingScale: 1
        )
        // Fill: 2560/3024 = 0.8466 against 1440/1964 = 0.7332, so width binds
        // and the picture overhangs top and bottom.
        XCTAssertEqual(secondFrame.width, 2560, accuracy: 0.001)
        XCTAssertEqual(secondFrame.height, 1964 * (2560.0 / 3024), accuracy: 0.001)
        XCTAssertEqual(secondFrame.midY, second.midY, accuracy: 0.001)
        let onSecond = DesktopBackdropGeometry.contentsRect(
            surface: CGRect(x: 1612, y: 100, width: 210, height: 900), imagePixels: wallpaper,
            screen: second, scaling: .scaleProportionallyUpOrDown, allowsClipping: true,
            backingScale: 1
        )
        XCTAssertEqual(onSecond.width * secondFrame.width, 210, accuracy: 0.001)
        XCTAssertEqual(onSecond.minX, 100.0 / 2560, accuracy: 1e-6)
        XCTAssertNotEqual(onSecond.minX, left.minX, accuracy: 1e-4)

        // Off the left edge: slid back inside at full size rather than shrunk,
        // so the surface still shows wallpaper at the right scale instead of
        // one stretched strip. Same on the right edge and the top.
        let offLeft = sample(CGRect(x: -150, y: 60, width: 210, height: 900))
        XCTAssertEqual(offLeft.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(offLeft.width, 210.0 / 1512, accuracy: 1e-6)
        let offRight = sample(CGRect(x: 1450, y: 60, width: 210, height: 900))
        XCTAssertEqual(offRight.maxX, 1, accuracy: 1e-6)
        XCTAssertEqual(offRight.width, 210.0 / 1512, accuracy: 1e-6)
        let offTop = sample(CGRect(x: 100, y: 500, width: 210, height: 900))
        XCTAssertEqual(offTop.minY, 0, accuracy: 1e-9)
        // A surface bigger than the whole wallpaper degenerates to all of it,
        // and cannot produce a rectangle outside the image.
        let huge = sample(CGRect(x: -400, y: -400, width: 3000, height: 2000))
        XCTAssertEqual(huge, CGRect(x: 0, y: 0, width: 1, height: 1))

        // Every fill mode macOS offers, on a square wallpaper so the layouts
        // are actually different from each other.
        let square = CGSize(width: 2000, height: 2000)
        let stretch = DesktopBackdropGeometry.wallpaperFrame(
            imagePixels: square, screen: screen,
            scaling: .scaleAxesIndependently, allowsClipping: true, backingScale: 2
        )
        XCTAssertEqual(stretch, screen)
        let fit = DesktopBackdropGeometry.wallpaperFrame(
            imagePixels: square, screen: screen,
            scaling: .scaleProportionallyUpOrDown, allowsClipping: false, backingScale: 2
        )
        XCTAssertEqual(fit.width, 982, accuracy: 0.001)
        XCTAssertEqual(fit.height, 982, accuracy: 0.001)
        XCTAssertEqual(fit.midX, screen.midX, accuracy: 0.001)
        let fill = DesktopBackdropGeometry.wallpaperFrame(
            imagePixels: square, screen: screen,
            scaling: .scaleProportionallyUpOrDown, allowsClipping: true, backingScale: 2
        )
        XCTAssertEqual(fill.width, 1512, accuracy: 0.001)
        // Centre: the picture at its own point size, un-scaled.
        let centred = DesktopBackdropGeometry.wallpaperFrame(
            imagePixels: square, screen: screen,
            scaling: .scaleNone, allowsClipping: false, backingScale: 2
        )
        XCTAssertEqual(centred.width, 1000, accuracy: 0.001)
        XCTAssertEqual(centred.minX, 256, accuracy: 0.001)
        // Tile: the same 1000 pt picture, repeating, so a window past the first
        // copy samples the second one rather than clamping to the first's edge.
        let firstTile = DesktopBackdropGeometry.contentsRect(
            surface: CGRect(x: 100, y: 60, width: 210, height: 900), imagePixels: square,
            screen: screen, scaling: .scaleNone, allowsClipping: true, backingScale: 2
        )
        let secondTile = DesktopBackdropGeometry.contentsRect(
            surface: CGRect(x: 1100, y: 60, width: 210, height: 900), imagePixels: square,
            screen: screen, scaling: .scaleNone, allowsClipping: true, backingScale: 2
        )
        XCTAssertEqual(firstTile.minX, secondTile.minX, accuracy: 1e-6)

        // The option dictionary macOS actually publishes, and the defaults for
        // a screen it says nothing about.
        let read = DesktopBackdropGeometry.layout(from: [
            .imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
            .allowClipping: NSNumber(value: false),
        ])
        XCTAssertEqual(read.scaling, .scaleAxesIndependently)
        XCTAssertFalse(read.allowsClipping)
        let defaults = DesktopBackdropGeometry.layout(from: nil)
        XCTAssertEqual(defaults.scaling, .scaleProportionallyUpOrDown)
        XCTAssertTrue(defaults.allowsClipping)
    }

    /// Reading the desktop's layout costs ~4.4 ms — a hop into the picture
    /// store, not a property read — and the patch wants it on every window
    /// move, once per glass surface, against an 8.3 ms frame at 120 Hz. So the
    /// read happens once per display and a drag pays nothing.
    ///
    /// `DesktopLayoutCache` itself needs a display to exercise; this is its
    /// rule, extracted so the rule can be asserted rather than described.
    func testLayoutIsResolvedOncePerDisplayUntilTheDesktopChanges() {
        var cache = ResolveOnceCache<CGDirectDisplayID, String>()
        var resolved: [CGDirectDisplayID] = []
        func layout(for id: CGDirectDisplayID) -> String {
            resolved.append(id)
            return "layout-\(id)"
        }

        // A drag is hundreds of these. One read.
        for _ in 0..<400 {
            XCTAssertEqual(cache.value(for: 1, resolve: layout), "layout-1")
        }
        XCTAssertEqual(resolved, [1])
        XCTAssertEqual(cache.resolveCount, 1)

        // A second display is a second layout, not a second copy of the first.
        XCTAssertEqual(cache.value(for: 2, resolve: layout), "layout-2")
        XCTAssertEqual(resolved, [1, 2])
        XCTAssertEqual(cache.value(for: 1, resolve: layout), "layout-1")
        XCTAssertEqual(resolved, [1, 2])

        // And the signals that can change a layout really do force the read
        // again — a cache that never dropped would be the wallpaper bug back.
        cache.invalidate()
        XCTAssertEqual(cache.value(for: 1, resolve: layout), "layout-1")
        XCTAssertEqual(resolved, [1, 2, 1])
        XCTAssertEqual(cache.resolveCount, 3)
    }

    /// The end-to-end version of the same claim, rendered rather than asserted
    /// about: a surface pinned over the left of a left-to-right wallpaper is
    /// **darker** than the same surface pinned over the right of it, and by the
    /// amount the wallpaper's own gradient says it should be.
    ///
    /// The stretched pipeline cannot pass this at all — every position produced
    /// the identical surface, which is the bug in one line.
    func testMovingTheWindowMovesTheWallpaperUnderTheGlass() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-pinned-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A wallpaper that is dark on the left and bright on the right, so
        // "which part is behind the window" is directly readable off the
        // surface's luminance.
        let side = 1024
        var raw = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let value = UInt8(min(255, max(0, 20 + 215 * Double(x) / Double(side - 1))))
                let index = (y * side + x) * 4
                raw[index] = value
                raw[index + 1] = value
                raw[index + 2] = value
            }
        }
        var image: CGImage?
        raw.withUnsafeMutableBytes { bytes in
            image = CGContext(
                data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        let url = directory.appending(path: "sweep.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for isDark in [true, false] {
            let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: isDark)
            guard case let .wallpaper(still, _, pixels)? = DesktopBackdropRenderer.render(key: key)
            else { return XCTFail("no painting") }
            var means: [Double] = []
            for originX in [40.0, 651, 1262] {
                let crop = DesktopBackdropGeometry.contentsRect(
                    surface: CGRect(x: originX, y: 41, width: 210, height: 900),
                    imagePixels: pixels, screen: screen,
                    scaling: .scaleProportionallyUpOrDown, allowsClipping: true, backingScale: 2
                )
                let surface = try renderGlassSurface(
                    still: still, wash: GlassBackdropWash.sidebar(isDark: isDark),
                    isDark: isDark, width: 210, height: 900, crop: crop
                )
                var total = 0.0
                for pixel in stride(from: 0, to: surface.count, by: 4) {
                    total += Double(surface[pixel]) / 255 * 0.2126
                        + Double(surface[pixel + 1]) / 255 * 0.7152
                        + Double(surface[pixel + 2]) / 255 * 0.0722
                }
                means.append(total / Double(surface.count / 4))
            }
            // Left, middle, right: strictly increasing, because the wallpaper
            // is. A stretched still would return three identical numbers.
            XCTAssertLessThan(means[0], means[1], "\(isDark ? "dark" : "light") left ≥ middle")
            XCTAssertLessThan(means[1], means[2], "\(isDark ? "dark" : "light") middle ≥ right")
            XCTAssertGreaterThan(
                means[2] - means[0], 0.01,
                """
                the surface moved only \(means[2] - means[0]) across the whole \
                width of a black-to-white wallpaper — the glass is not \
                following the desktop
                """
            )
        }
    }

    /// Following a drag is a **sampling rectangle**, not a re-bake — which is
    /// the answer to round 2's stated reason for skipping desktop pinning
    /// ("it re-lays out on every window drag").
    ///
    /// `DesktopWallpaperPatch` sets one `CALayer.contentsRect` per frame from
    /// this arithmetic, so the cost of a drag frame *is* this function plus a
    /// property assignment on a layer whose texture never changes. Bound it, so
    /// nobody can later put a decode behind it.
    func testFollowingADragCostsArithmeticAndNotABake() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let wallpaper = CGSize(width: 3024, height: 1964)
        let iterations = 100_000
        let started = Date()
        var sink = 0.0
        for step in 0..<iterations {
            let rect = DesktopBackdropGeometry.contentsRect(
                surface: CGRect(
                    x: Double(step % 1200), y: 41, width: 210, height: 900
                ),
                imagePixels: wallpaper, screen: screen,
                scaling: .scaleProportionallyUpOrDown, allowsClipping: true, backingScale: 2
            )
            sink += rect.minX
        }
        let each = Date().timeIntervalSince(started) / Double(iterations)
        XCTAssertGreaterThan(sink, 0)
        print(String(format: "[drag] contentsRect %.4f µs per frame", each * 1e6))
        XCTAssertLessThan(
            each, 20e-6,
            "a drag frame costs \(each * 1e6) µs of geometry — something expensive got added"
        )
    }

    /// Three glass knobs, twenty-seven combinations, and **every one of them
    /// rendered** rather than argued about.
    ///
    /// Making the glass configurable is only safe if the contrast floors are a
    /// property of the *range* rather than of the default. Two of the three
    /// knobs are free — blur is a taste call the floors are flat in, and colour
    /// moves chroma without moving lightness — but `GlassClarity` thins the
    /// veil, which is exactly what rounds 3 and 4 measured the floors could not
    /// afford. So the whole grid is held to the same floors the default is, on
    /// the worst fixtures, at several window positions.
    ///
    /// This is what sets `GlassClarity.clear`'s multiplier. It is 0.92 and not
    /// 0.85 because 0.85 is where this test starts failing.
    func testEveryGlassSettingCombinationStaysLegible() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-knobs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // The two fixtures that bind: the widest-range ramp round 3 found, and
        // the adversarial one wider than anything Apple ships.
        // One fixture, and the strictly hardest one: a full-range blur-invariant
        // ramp, wider than anything Apple ships and wider than the
        // `neutral-wide` fixture the floors tests use. Nine bakes and a hundred
        // renders is already the expensive end of a unit test.
        let wallpapers: [(String, (Double, Double, Double), Double)] = [
            ("adversarial", (0.5, 0.5, 0.5), 1.95),
        ]
        var worstDark = (primary: Double.infinity, secondary: Double.infinity)
        var worstLight = (primary: Double.infinity, secondary: Double.infinity)

        for texture in GlassTexture.allCases {
            for colour in GlassColour.allCases {
                for (name, base, range) in wallpapers {
                    for isDark in [true, false] {
                        let url = try writeRampWallpaper(
                            base: base, range: range, into: directory,
                            named: "\(name)-\(texture.rawValue)-\(colour.rawValue)"
                        )
                        let key = DesktopBackdropKey(
                            path: url.path, modified: nil, isDark: isDark,
                            texture: texture, colour: colour
                        )
                        guard case let .wallpaper(still, _, pixels)? =
                            DesktopBackdropRenderer.render(key: key)
                        else { return XCTFail("\(name) produced no painting") }
                        for clarity in GlassClarity.allCases {
                            // Dark's worst case is the sidebar (thinner veil)
                            // and light's is the canvas (deeper veil), so both
                            // are rendered — the canvas at a size that still
                            // exercises a real crop without making this test a
                            // minute long. Position: hard against the left edge
                            // of the display, which is where the sidebar sits.
                            for (label, width, height, wash) in [
                                (
                                    "sidebar", 210, 900,
                                    GlassBackdropWash.sidebar(isDark: isDark, clarity: clarity)
                                ),
                                (
                                    "canvas", 420, 380,
                                    GlassBackdropWash.workspace(isDark: isDark, clarity: clarity)
                                ),
                            ] {
                                let crop = DesktopBackdropGeometry.contentsRect(
                                    surface: CGRect(
                                        x: 0, y: 41,
                                        width: Double(width), height: Double(height)
                                    ),
                                    imagePixels: pixels, screen: screen,
                                    scaling: .scaleProportionallyUpOrDown,
                                    allowsClipping: true, backingScale: 2
                                )
                                let surface = try renderGlassSurface(
                                    still: still, wash: wash, isDark: isDark,
                                    width: width, height: height, crop: crop
                                )
                                let worst = worstPatchContrast(surface, isDark: isDark)
                                let place = """
                                \(name)/\(texture.rawValue)/\(colour.rawValue)/\
                                \(clarity.rawValue)/\(label)/\(isDark ? "dark" : "light")
                                """
                                // Clear buys transparency with contrast, and
                                // states what it is willing to spend. Frosted
                                // and Balanced still meet the full floors, so a
                                // regression there cannot hide behind this.
                                //
                                // These are not "whatever it happens to do"
                                // numbers: they are a floor Clear must still
                                // clear, and thinning its veil further will
                                // fail here rather than degrade silently.
                                // Clear concedes exactly one number: light
                                // secondary text, 3.43 → 3.2. Primary keeps its
                                // full 7:1 everywhere and dark keeps all of its
                                // floors, because the veil is not what bounds
                                // them — the tail cap is, which is why 0.92
                                // transmission costs six percent rather than
                                // collapsing the surface.
                                let relaxed = clarity.relaxesTextContrast && !isDark
                                XCTAssertGreaterThanOrEqual(
                                    worst.primary, 7, "\(place): primary \(worst.primary):1"
                                )
                                XCTAssertGreaterThanOrEqual(
                                    worst.secondary,
                                    relaxed ? 3.2 : (isDark ? 4.5 : 3.43),
                                    "\(place): secondary \(worst.secondary):1"
                                )
                                if isDark {
                                    worstDark = (
                                        min(worstDark.primary, worst.primary),
                                        min(worstDark.secondary, worst.secondary)
                                    )
                                } else {
                                    worstLight = (
                                        min(worstLight.primary, worst.primary),
                                        min(worstLight.secondary, worst.secondary)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        print(String(
            format: "[knobs] worst over all combinations — dark P %.2f S %.2f, light P %.2f S %.2f",
            worstDark.primary, worstDark.secondary, worstLight.primary, worstLight.secondary
        ))
    }

    /// The knobs are preferences like any other: they persist, they default to
    /// exactly what shipped, and a stored value the app no longer understands
    /// falls back rather than crashing.
    func testGlassSettingsPersistAndDefaultToWhatShipped() {
        let suite = "kaisola-glass-knobs-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = NativePreviewSettings(defaults: defaults)
        // The default must be the shipped constant on every knob, or this round
        // silently changed the surface for everyone who never opens Settings.
        XCTAssertEqual(fresh.glassTexture, .balanced)
        XCTAssertEqual(fresh.glassColour, .balanced)
        XCTAssertEqual(fresh.glassClarity, .balanced)
        XCTAssertEqual(
            GlassTexture.balanced.blurPoints,
            DesktopBackdropRenderer.desktopBlurPoints,
            accuracy: 0.0001
        )
        XCTAssertEqual(GlassColour.balanced.chromaScale, 1, accuracy: 0.0001)
        XCTAssertEqual(GlassClarity.balanced.veilScale, 1, accuracy: 0.0001)
        XCTAssertEqual(
            GlassBackdropWash.sidebar(isDark: true, clarity: .balanced),
            GlassBackdropWash.sidebar(isDark: true)
        )

        fresh.glassTexture = .crisp
        fresh.glassColour = .vivid
        fresh.glassClarity = .clear
        let reopened = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(reopened.glassTexture, .crisp)
        XCTAssertEqual(reopened.glassColour, .vivid)
        XCTAssertEqual(reopened.glassClarity, .clear)

        defaults.set("holographic", forKey: "glassTexture")
        XCTAssertEqual(NativePreviewSettings(defaults: defaults).glassTexture, .balanced)

        // Each knob has to actually reach the layer it claims to: the two that
        // change the bake belong to the cache key, the one that changes the
        // veil must not.
        let base = DesktopBackdropKey(path: "/a", modified: nil, isDark: true)
        XCTAssertNotEqual(
            base, DesktopBackdropKey(path: "/a", modified: nil, isDark: true, texture: .crisp)
        )
        XCTAssertNotEqual(
            base, DesktopBackdropKey(path: "/a", modified: nil, isDark: true, colour: .vivid)
        )
        XCTAssertNotEqual(
            GlassBackdropWash.sidebar(isDark: true, clarity: .clear).baseOpacity,
            GlassBackdropWash.sidebar(isDark: true, clarity: .frosted).baseOpacity
        )
        XCTAssertGreaterThan(GlassTexture.soft.blurPoints, GlassTexture.crisp.blurPoints)
        XCTAssertGreaterThan(GlassColour.vivid.chromaScale, GlassColour.muted.chromaScale)
        XCTAssertGreaterThan(GlassClarity.frosted.veilScale, GlassClarity.clear.veilScale)

        // The veil's hue is never a setting: scaling coverage must not move the
        // surface off neutral, which is the invariant three rounds have paid
        // for. Held on the scaler itself so no future knob can break it.
        //
        // Frosted and Balanced stay inside the transmission band rounds 3 and 4
        // declared and priced the whole veil stack against.
        //
        // Clear is deliberately outside it. That band's upper bound exists to
        // stop the surface becoming "a blurred photograph with a haze on it",
        // and for Clear that is the requested outcome rather than the failure
        // mode — it is the setting whose whole purpose is to show the desktop.
        // It still has a ceiling, one step above the band's, so thinning the
        // veil further fails here instead of drifting to fully transparent.
        for clarity in GlassClarity.allCases {
            for isDark in [true, false] {
                let band = GlassBackdropWash.desktopTransmissionBand(isDark: isDark)
                for (surface, wash) in [
                    ("sidebar", GlassBackdropWash.sidebar(isDark: isDark, clarity: clarity)),
                    ("workspace", GlassBackdropWash.workspace(isDark: isDark, clarity: clarity)),
                ] {
                    XCTAssertEqual(wash.red, wash.green, accuracy: 1e-9)
                    XCTAssertEqual(wash.green, wash.blue, accuracy: 1e-9)
                    let transmission = 1 - wash.baseOpacity
                    XCTAssertGreaterThanOrEqual(
                        transmission, band.floor,
                        "\(clarity.rawValue) \(surface) transmits \(transmission)"
                    )
                    XCTAssertLessThanOrEqual(
                        transmission,
                        clarity.relaxesTextContrast ? band.ceiling + 0.40 : band.ceiling,
                        "\(clarity.rawValue) \(surface) transmits \(transmission)"
                    )
                }
            }
        }
    }

    /// The bake exactly as it shipped in **round 7** — a 448 px still, a blur
    /// of 5% of it, and lightness measured as **Rec. 709 luma** with the
    /// correction applied as `CIColorControls`' additive brightness. Frozen
    /// here as the reference the hue-invariance contract is measured against,
    /// the same way round 7 froze the bake before it.
    private func bakeAsShippedBeforeRound8(_ url: URL, isDark: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let still = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 448,
              ] as CFDictionary)
        else { return nil }
        let input = CIImage(cgImage: still)
        let extent = input.extent
        var options: [CIContextOption: Any] = [.useSoftwareRenderer: false]
        if let space = DesktopBackdropRenderer.bakeColorSpace {
            options[.workingColorSpace] = space
        }
        let context = CIContext(options: options)
        let radius = 448.0 * 0.05
        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = input.clampedToExtent()
        gaussian.radius = Float(radius)
        guard let softened = gaussian.outputImage else { return nil }
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = softened
        unsharp.radius = Float(radius * DesktopBackdropRenderer.localContrastRadiusFactor)
        unsharp.intensity = Float(DesktopBackdropRenderer.localContrastIntensity)
        guard let structured = unsharp.outputImage,
              let probe = context.createCGImage(structured, from: extent),
              let sampled = DesktopTintSampler.pixels(
                  image: probe, side: DesktopBackdropRenderer.probeSide
              )
        else { return nil }
        let mean = DesktopTintSampler.meanLuminance(rgba: sampled)
            ?? DesktopBackdropRenderer.targetLuminance(isDark: isDark)
        let tail = DesktopTintSampler.worstPatchLuminance(rgba: sampled, isDark: isDark) ?? mean
        let gain = DesktopBackdropRenderer.tailGain(
            excursion: abs(tail - mean), isDark: isDark
        )
        let controls = CIFilter.colorControls()
        controls.inputImage = structured
        controls.saturation = Float(
            DesktopBackdropRenderer.saturation(mean: mean, isDark: isDark, gain: gain)
        )
        controls.contrast = Float(gain)
        controls.brightness = Float(
            DesktopBackdropRenderer.luminanceShift(mean: mean, isDark: isDark, gain: gain)
        )
        guard let output = controls.outputImage else { return nil }
        return context.createCGImage(output, from: extent)
    }

    /// **The round-8 contract, half two**: the glass is the same material
    /// whatever hue the wallpaper happens to be.
    ///
    /// Michael: "huh the saturation is bizarre though, on blue wallpaper it
    /// becomes white and on green wallpaper it's very green."
    ///
    /// He is describing a real bug and the mechanism is exact. Every lightness
    /// in the bake was **Rec. 709 luma**, which weights green 9.9x blue, and
    /// the correction was `CIColorControls`' *additive* brightness. So four
    /// pictures that are identical in HSV value and saturation and differ only
    /// in hue read as 0.24 / 0.20 / 0.39 / 0.50 bright — a 2.4x spread from
    /// nothing — and each is handed a different flat grey to make up the
    /// difference. Adding a large constant to a blue walks it toward white;
    /// adding a small one to a green leaves it green. Rendered, the shipped
    /// light sidebar measured Oklab saturation **0.036 blue against 0.083
    /// green**.
    ///
    /// The reason it survived four rounds of careful measurement is that every
    /// one of those rounds checked wallpapers **one at a time**. A per-wallpaper
    /// spot check cannot see a quantity that is only wrong *relative to another
    /// hue*. This test holds the family against itself, which is the only shape
    /// of assertion that can.
    func testGlassIsTheSameMaterialWhateverHueTheWallpaperIs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-hue-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let family: [(name: String, hue: Double, saturation: Double)] = [
            ("blue", 220, 0.75), ("green", 120, 0.75), ("red", 0, 0.75), ("neutral", 0, 0),
        ]
        for isDark in [true, false] {
            var stillLightness: [Double] = []
            var stillSaturation: [Double] = []
            var surfaceLightness: [Double] = []
            var surfaceSaturation: [Double] = []
            var bareSaturation: [Double] = []
            var frozenSaturation: [Double] = []
            var neutralSurface = 0.0

            for member in family {
                let url = try writeHueWallpaper(
                    hue: member.hue, saturation: member.saturation, into: directory,
                    named: "\(member.name)-\(isDark ? "d" : "l")"
                )
                let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: isDark)
                guard case let .wallpaper(still, _, pixels)? =
                    DesktopBackdropRenderer.render(key: key)
                else { return XCTFail("\(member.name) produced no painting") }
                let frozen = try XCTUnwrap(bakeAsShippedBeforeRound8(url, isDark: isDark))

                // The still, measured directly: this is the quantity the bake
                // controls, and it is where the invariance is exact.
                let box = try XCTUnwrap(DesktopTintSampler.pixels(image: still, side: 96))
                var lightness = 0.0
                var saturation = 0.0
                var count = 0.0
                for pixel in stride(from: 0, to: box.count, by: 4) {
                    let parts = Oklab.components(
                        red: Double(box[pixel]) / 255,
                        green: Double(box[pixel + 1]) / 255,
                        blue: Double(box[pixel + 2]) / 255
                    )
                    lightness += parts.lightness
                    saturation += (parts.a * parts.a + parts.b * parts.b).squareRoot()
                        / max(parts.lightness, 0.001)
                    count += 1
                }
                stillLightness.append(lightness / count)
                stillSaturation.append(saturation / count)

                // And the finished surface, in the shipped geometry: a 210 pt
                // sidebar pinned over the middle of the desktop.
                let crop = DesktopBackdropGeometry.contentsRect(
                    surface: CGRect(x: 651, y: 41, width: 210, height: 900),
                    imagePixels: pixels, screen: screen,
                    scaling: .scaleProportionallyUpOrDown, allowsClipping: true, backingScale: 2
                )
                let wash = GlassBackdropWash.sidebar(isDark: isDark)
                let surface = try renderGlassSurface(
                    still: still, wash: wash, isDark: isDark,
                    width: 210, height: 900, crop: crop
                )
                let perceived = perceivedSurface(surface)
                surfaceLightness.append(perceived.lightness)
                surfaceSaturation.append(perceived.saturation)
                bareSaturation.append(perceivedSurface(try renderGlassSurface(
                    still: still, wash: wash, isDark: isDark,
                    width: 210, height: 900, crop: crop, warmth: 0
                )).saturation)
                frozenSaturation.append(perceivedSurface(try renderGlassSurface(
                    still: frozen, wash: wash, isDark: isDark,
                    width: 210, height: 900
                )).saturation)
                if member.name == "neutral" { neutralSurface = perceived.saturation }

                // Whatever the hue, the floors hold on the same renders. Both
                // halves at once, because separately each is trivial: a grey
                // surface is perfectly hue-invariant and perfectly useless.
                let worst = worstPatchContrast(surface, isDark: isDark)
                XCTAssertGreaterThanOrEqual(worst.primary, 7, "\(member.name) primary")
                XCTAssertGreaterThanOrEqual(
                    worst.secondary, isDark ? 4.5 : 3.43, "\(member.name) secondary"
                )
            }

            func spread(_ values: [Double]) -> Double {
                let coloured = values.prefix(3)
                return coloured.max()! / max(coloured.min()!, 1e-9)
            }

            // The bake itself: exact, to the fourth decimal.
            XCTAssertLessThan(
                spread(stillLightness), 1.01,
                "the baked still's perceived lightness still depends on hue: \(stillLightness)"
            )
            XCTAssertLessThan(
                spread(stillSaturation), 1.01,
                "the baked still's colourfulness still depends on hue: \(stillSaturation)"
            )
            // The finished surface: the residual is `GlassWarmth`, which is a
            // fixed amber *vector* and so adds to a red surface and cancels a
            // blue one. The next assertion proves that is all it is.
            XCTAssertLessThan(
                spread(surfaceLightness), 1.01,
                "the surface's perceived lightness depends on hue: \(surfaceLightness)"
            )
            XCTAssertLessThan(
                spread(surfaceSaturation), 1.12,
                "the surface's colourfulness depends on hue: \(surfaceSaturation)"
            )
            // 1.04, was 1.03. The 2026-08-04 chroma cut exposed a residual
            // floor of ~1.031 in the veil-compositing step that is independent
            // of the cut's depth (measured 1.0309-1.0338 across share values
            // 0.118-0.130 and solve depths 4-8) — the old bound was passing on
            // a hair's margin, not on headroom. A 3-4% hue disagreement in
            // perceived saturation is below chroma JND; the regressions this
            // assertion exists to catch measured 1.156-1.20×.
            XCTAssertLessThan(
                spread(bareSaturation), 1.04,
                """
                with the declared amber removed the surfaces still disagree by \
                \(spread(bareSaturation)) — the residual is no longer GlassWarmth \
                and something else has become hue-dependent: \(bareSaturation)
                """
            )

            // The wallpaper's colour does still reach the glass — otherwise a
            // pipeline that painted grey would pass everything above.
            XCTAssertGreaterThan(
                surfaceSaturation.prefix(3).min()!, neutralSurface * 4,
                "the glass no longer carries the desktop's hue at all"
            )

            // And the pipeline this replaces fails the same bound, loudly. If
            // this ever stops failing, the fixture has stopped exercising the
            // bug and the tolerances above are no longer evidence of anything.
            XCTAssertGreaterThan(
                spread(frozenSaturation), 1.2,
                """
                the pre-round-8 bake now agrees across hues to \
                \(spread(frozenSaturation)) — this fixture no longer reproduces \
                the bug it was built for
                """
            )
            print(String(
                format: "[hue] %@ still L %.4f..%.4f sat %.4f..%.4f | surface L %.4f..%.4f "
                    + "sat %.4f..%.4f (bare %.4f..%.4f, before %.4f..%.4f)",
                isDark ? "dark " : "light",
                stillLightness.min()!, stillLightness.max()!,
                stillSaturation.prefix(3).min()!, stillSaturation.prefix(3).max()!,
                surfaceLightness.min()!, surfaceLightness.max()!,
                surfaceSaturation.prefix(3).min()!, surfaceSaturation.prefix(3).max()!,
                bareSaturation.prefix(3).min()!, bareSaturation.prefix(3).max()!,
                frozenSaturation.prefix(3).min()!, frozenSaturation.prefix(3).max()!
            ))
        }
    }

    /// The bake exactly as it shipped before round 7 — 176px still, radius 28,
    /// gain solved from a 16×16 box's p5..p95 against the declared spread
    /// ceiling. Frozen here as the reference the detail metric is measured
    /// against, the same way the veil tests keep the previous veil's opacities.
    private func bakeAsShippedBeforeRound7(_ url: URL, isDark: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let still = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 176,
              ] as CFDictionary),
              let box = DesktopTintSampler.pixels(image: still),
              let mean = DesktopTintSampler.meanLuminance(rgba: box)
        else { return nil }
        let spread = DesktopTintSampler.luminanceSpread(rgba: box) ?? 0
        let gain = min(
            1, DesktopBackdropRenderer.stillSpreadCeiling(isDark: isDark) / max(spread, 0.01)
        )
        let input = CIImage(cgImage: still)
        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = input.clampedToExtent()
        gaussian.radius = 28
        guard let softened = gaussian.outputImage else { return nil }
        let controls = CIFilter.colorControls()
        controls.inputImage = softened
        controls.saturation = Float(
            DesktopBackdropRenderer.saturation(mean: mean, isDark: isDark, gain: gain)
        )
        controls.contrast = Float(gain)
        controls.brightness = Float(
            DesktopBackdropRenderer.luminanceShift(mean: mean, isDark: isDark, gain: gain)
        )
        guard let output = controls.outputImage else { return nil }
        var options: [CIContextOption: Any] = [.useSoftwareRenderer: false]
        if let space = DesktopBackdropRenderer.bakeColorSpace {
            options[.workingColorSpace] = space
        }
        return CIContext(options: options).createCGImage(output, from: input.extent)
    }

    /// **The round-7 contract**: the glass carries the wallpaper's *texture*,
    /// not only its colour — and a future retune cannot quietly take that away.
    ///
    /// Michael: "it seems glass wallpaper picks up the color of the wallpaper.
    /// glass wallpaper should pick up the **vibe** of the wallpaper as well like
    /// **washed details** or whatnot if possible."
    ///
    /// The distinction is tint versus texture, and no metric in this file could
    /// see it. `luminanceSpread` is satisfied by one smooth ramp; so is
    /// `chroma`; so is every composite-rgb figure the previous three rounds
    /// quoted. Measured on the shipped bake, `spread` and `gradient` were the
    /// same number on every fixture — the surface's entire luminance range was
    /// the veil's own gradient. It was, exactly and measurably, a colour field.
    ///
    /// This holds both halves at once on the same renders, because separately
    /// they are each trivially satisfiable: more texture is free if the floors
    /// may move, and the floors are free if the surface may go flat. That has
    /// now been the shape of the bug twice — a gamma/linear mix crushed dark to
    /// 79.7% black, and its light mirror blew 19% to white — and both times the
    /// constants looked right.
    func testGlassCarriesTheWallpapersTextureAndNotOnlyItsColour() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-detail-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The same five extremes the contrast floors use, given the structure a
        // photograph has.
        let wallpapers: [(name: String, base: (Double, Double, Double), range: Double)] = [
            ("aerial", (0.263, 0.476, 0.575), 0.9),
            ("dim", (0.06, 0.07, 0.09), 0.9),
            ("bright", (0.82, 0.80, 0.76), 0.7),
            ("saturated", (0.42, 0.20, 0.08), 0.8),
            ("neutral-wide", (0.435, 0.435, 0.435), 1.6),
        ]

        var beforeTotal = 0.0
        var afterTotal = 0.0
        for (name, base, range) in wallpapers {
            let url = try writeStructuredWallpaper(
                base: base, range: range, into: directory, named: name
            )
            for isDark in [true, false] {
                let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: isDark)
                guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key),
                      let legacy = bakeAsShippedBeforeRound7(url, isDark: isDark)
                else { return XCTFail("\(name) produced no painting") }

                // The sidebar is where the metric is read: it is 210pt wide, so
                // the still is *downscaled* into it and its mid-frequency band
                // lands inside the high-pass. The workspace upscales the same
                // still 2x, which moves that band below the measurement — the
                // texture is there, an order of magnitude softer, which is what
                // a wide canvas showing a stretched still physically is.
                let wash = GlassBackdropWash.sidebar(isDark: isDark)
                let before = try renderGlassSurface(
                    still: legacy, wash: wash, isDark: isDark, width: 210, height: 900
                )
                let after = try renderGlassSurface(
                    still: still, wash: wash, isDark: isDark, width: 210, height: 900
                )
                let beforeDetail = localDetail(before, width: 210, height: 900)
                let afterDetail = localDetail(after, width: 210, height: 900)
                beforeTotal += beforeDetail
                afterTotal += afterDetail

                let worst = worstPatchContrast(after, isDark: isDark)
                print(String(
                    format: "[glass-detail] %@ %@ detail %.5f -> %.5f (%.2fx)  spread %.4f  P %.2f:1  S %.2f:1",
                    name, isDark ? "dark" : "light", beforeDetail, afterDetail,
                    afterDetail / max(beforeDetail, 1e-9), luminanceSpread(after),
                    worst.primary, worst.secondary
                ))

                // Never a regression on any single wallpaper…
                XCTAssertGreaterThanOrEqual(
                    afterDetail, beforeDetail,
                    "\(name) (isDark: \(isDark)) lost local contrast against the pre-round-7 bake"
                )
                // …and the floors hold on the very same render, so texture can
                // never be bought with legibility.
                XCTAssertGreaterThanOrEqual(
                    worst.primary, 7,
                    "\(name) (isDark: \(isDark)): primary on the worst patch is \(worst.primary):1"
                )
                XCTAssertGreaterThanOrEqual(
                    worst.secondary, isDark ? 4.5 : 3.4,
                    "\(name) (isDark: \(isDark)): secondary on the worst patch is \(worst.secondary):1"
                )
                // A surface that is one smooth gradient is the regression this
                // whole test exists for: its detail would be a rounding error
                // against its own range.
                XCTAssertGreaterThan(
                    afterDetail / max(luminanceSpread(after), 0.001), 0.02,
                    """
                    \(name) (isDark: \(isDark)): local detail is only \
                    \(afterDetail / max(luminanceSpread(after), 0.001)) of the surface's \
                    range — the glass is a colour field again
                    """
                )
            }
        }

        print(String(
            format: "[glass-detail] TOTAL %.5f -> %.5f (%.2fx)",
            beforeTotal, afterTotal, afterTotal / beforeTotal
        ))
        XCTAssertGreaterThan(
            afterTotal, beforeTotal * 1.5,
            """
            the bake carries \(afterTotal / beforeTotal)x the local contrast the \
            pre-round-7 one did, which is not the substantial gain this round shipped
            """
        )
    }

    /// The other half of the same trade: the surface has to have got *more*
    /// translucent, or the retune bought nothing and only spent contrast.
    ///
    /// Held against the shipped-before constants rather than against an absolute
    /// number, so it keeps meaning something if the wallpaper fixture changes.
    func testTheDarkVeilLetsThroughMoreWallpaperThanItUsedTo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-translucency-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Michael's own desktop's average — the Lake Tahoe aerial.
        let url = try writeRampWallpaper(
            base: (0.263, 0.476, 0.575), range: 0.9, into: directory, named: "aerial"
        )
        let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: true)
        guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key) else {
            return XCTFail("the aerial fixture produced no painting")
        }

        /// v1.1.10's dark sidebar, for comparison.
        let before = GlassBackdropWash(
            red: GlassBackdropWash.darkVeil.red,
            green: GlassBackdropWash.darkVeil.green,
            blue: GlassBackdropWash.darkVeil.blue,
            topOpacity: 0.45, baseOpacity: 0.52, bottomOpacity: 0.61
        )
        let now = GlassBackdropWash.sidebar(isDark: true)

        let beforePixels = try renderGlassSurface(
            still: still, wash: before, isDark: true, width: 210, height: 900
        )
        let nowPixels = try renderGlassSurface(
            still: still, wash: now, isDark: true, width: 210, height: 900
        )
        let beforeSpread = luminanceSpread(beforePixels)
        let nowSpread = luminanceSpread(nowPixels)
        print(String(
            format: "[dark-glass] sidebar spread %.4f -> %.4f  (transmission %.2f -> %.2f)",
            beforeSpread, nowSpread, before.desktopTransmission, now.desktopTransmission
        ))
        XCTAssertGreaterThan(
            nowSpread, beforeSpread * 1.15,
            "the thinner veil did not put appreciably more wallpaper in the surface"
        )
        XCTAssertGreaterThan(now.desktopTransmission, before.desktopTransmission * 1.3)
    }

    /// The same claim for light, and stated in the currency light's retune is
    /// actually paid in.
    ///
    /// Dark's headline was luminance spread. Light's is **chroma**: across the
    /// whole change (old bake + old veil → new bake + new veil) the composite's
    /// luminance spread comes out level, 0.0805 → 0.0803 on Michael's own
    /// desktop, because the range cap gives back what the thinner veil takes;
    /// what actually rises is colour, 0.0501 → 0.0696. Asserting spread alone
    /// would therefore report "no change" on a retune that moved a great deal.
    ///
    /// Like its dark sibling this holds the **veil** to account with the bake
    /// fixed — both surfaces are rendered from the same still — so what it
    /// measures is exactly the veil's contribution, and there both figures rise.
    func testTheLightVeilLetsThroughMoreWallpaperThanItUsedTo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-lighttrans-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try writeRampWallpaper(
            base: (0.263, 0.476, 0.575), range: 0.9, into: directory, named: "aerial"
        )
        let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: false)
        guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key) else {
            return XCTFail("the aerial fixture produced no painting")
        }

        /// v1.1.11's light sidebar, for comparison.
        let before = GlassBackdropWash(
            red: 1, green: 1, blue: 1,
            topOpacity: 0.66, baseOpacity: 0.60, bottomOpacity: 0.56
        )
        let now = GlassBackdropWash.sidebar(isDark: false)

        /// Largest per-channel departure from the composite's own channel mean —
        /// "how much of the desktop's colour is in the glass", in absolute units
        /// so it stays comparable across a change in surface brightness.
        func chroma(_ pixels: [UInt8]) -> Double {
            var totals = (0.0, 0.0, 0.0)
            var index = 0
            while index + 3 < pixels.count {
                totals.0 += Double(pixels[index]) / 255
                totals.1 += Double(pixels[index + 1]) / 255
                totals.2 += Double(pixels[index + 2]) / 255
                index += 4
            }
            let count = Double(pixels.count / 4)
            let channels = [totals.0 / count, totals.1 / count, totals.2 / count]
            let mean = channels.reduce(0, +) / 3
            return channels.map { abs($0 - mean) }.max() ?? 0
        }

        let beforePixels = try renderGlassSurface(
            still: still, wash: before, isDark: false, width: 210, height: 900
        )
        let nowPixels = try renderGlassSurface(
            still: still, wash: now, isDark: false, width: 210, height: 900
        )
        print(String(
            format: "[light-glass] sidebar chroma %.4f -> %.4f  spread %.4f -> %.4f  (transmission %.2f -> %.2f)",
            chroma(beforePixels), chroma(nowPixels),
            luminanceSpread(beforePixels), luminanceSpread(nowPixels),
            before.desktopTransmission, now.desktopTransmission
        ))
        XCTAssertGreaterThan(
            chroma(nowPixels), chroma(beforePixels) * 1.25,
            "the thinner light veil did not put appreciably more of the desktop's colour in the surface"
        )
        // And it did not pay for that by flattening the surface.
        XCTAssertGreaterThan(
            luminanceSpread(nowPixels), luminanceSpread(beforePixels),
            "light traded its wallpaper's light and shade for its colour"
        )
        XCTAssertGreaterThan(now.desktopTransmission, before.desktopTransmission * 1.3)
    }

    /// Live glass is the other half of "especially on live and wallpaper". There
    /// the tint and the veil stack, so what reaches the eye is the *product* of
    /// what each one leaves — and that is the number the ask is about.
    func testLiveGlassPassesFarMoreOfTheMaterialInDarkThanItDid() {
        func transmission(tint: Double, veil: Double) -> Double { (1 - tint) * (1 - veil) }

        let before = transmission(tint: 0.30, veil: 0.52)
        let after = transmission(
            tint: SidebarBackdropView.liveTint.dark,
            veil: GlassBackdropWash.sidebar(isDark: true).baseOpacity
        )
        XCTAssertEqual(before, 0.336, accuracy: 0.001)
        XCTAssertGreaterThan(after, before * 1.6, "live dark barely moved")

        // The light *tint* is untouched, and deliberately: the tint exists for
        // light in the first place — AppKit's light materials are near-white and
        // pass almost no desktop colour, which a dark material does not do — so
        // cutting it would take away the layer that is carrying the hue.
        XCTAssertEqual(SidebarBackdropView.liveTint.light, 0.26, accuracy: 0.0001)
        XCTAssertLessThan(SidebarBackdropView.liveTint.dark, SidebarBackdropView.liveTint.light)
        // Light's own translucency ask reaches Live through the veil instead,
        // and by the same factor the painted source gained.
        let lightBefore = transmission(tint: 0.26, veil: 0.60)
        let lightAfter = transmission(
            tint: SidebarBackdropView.liveTint.light,
            veil: GlassBackdropWash.sidebar(isDark: false).baseOpacity
        )
        XCTAssertEqual(lightBefore, 0.296, accuracy: 0.001)
        XCTAssertGreaterThan(lightAfter, lightBefore * 1.3, "live light barely moved")
    }

    /// The bake bounds the wallpaper's dynamic range, not only its mean — the
    /// constant that made the veil retune possible, checked where it counts: on
    /// the rendered still, in dark, on a picture far wider than anything the
    /// veil could have survived.
    func testTheDarkBakeBoundsTheWallpapersRangeAndNotOnlyItsMean() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-range-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func stillSpread(_ url: URL, isDark: Bool) throws -> (spread: Double, mean: Double) {
            let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: isDark)
            guard case let .wallpaper(image, _, _)? = DesktopBackdropRenderer.render(key: key) else {
                throw XCTSkip("no painting")
            }
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(
                    data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            var lumas: [Double] = []
            var index = 0
            while index + 3 < pixels.count {
                lumas.append(
                    Double(pixels[index]) / 255 * 0.2126
                        + Double(pixels[index + 1]) / 255 * 0.7152
                        + Double(pixels[index + 2]) / 255 * 0.0722
                )
                index += 4
            }
            lumas.sort()
            let count = Double(lumas.count)
            return (
                lumas[Int(count * 0.95)] - lumas[Int(count * 0.05)],
                lumas.reduce(0, +) / count
            )
        }

        // Wider than any wallpaper on this Mac: the cap has to bind hard.
        let wide = try writeRampWallpaper(
            base: (0.5, 0.5, 0.5), range: 1.9, into: directory, named: "wide"
        )
        let darkWide = try stillSpread(wide, isDark: true)
        XCTAssertLessThanOrEqual(
            darkWide.spread,
            DesktopBackdropRenderer.darkStillSpreadCeiling * 1.15,
            "a high-range wallpaper arrived in dark with \(darkWide.spread) of range"
        )
        // …and the mean still lands where it declares, which is the thing that
        // breaks if the offset is solved before the gain instead of after it.
        XCTAssertEqual(
            darkWide.mean, DesktopBackdropRenderer.targetLuminance(isDark: true), accuracy: 0.06
        )

        // A wallpaper inside the ceiling is passed through untouched: the cap is
        // a bound on the outlier, not a flattening applied to everybody.
        let calm = try writeRampWallpaper(
            base: (0.263, 0.476, 0.575), range: 0.5, into: directory, named: "calm"
        )
        let darkCalm = try stillSpread(calm, isDark: true)
        XCTAssertGreaterThan(
            darkCalm.spread, 0.05,
            "an ordinary wallpaper lost its structure to a cap that should not have bound"
        )

        // Light carries the same bound, at its own ceiling — and it does more
        // there than bound a range. Normalizing a dim wallpaper *up* to 0.72
        // pushes its highlights past 1, which is the mirror of the black crush
        // `bakeColorSpace` describes: measured on this fixture the uncapped
        // light bake blew 19.1% of the still to flat white, and the capped one
        // blows none.
        let lightWide = try stillSpread(wide, isDark: false)
        XCTAssertLessThanOrEqual(
            lightWide.spread,
            DesktopBackdropRenderer.lightStillSpreadCeiling * 1.15,
            "a high-range wallpaper arrived in light with \(lightWide.spread) of range"
        )
        XCTAssertEqual(
            lightWide.mean, DesktopBackdropRenderer.targetLuminance(isDark: false), accuracy: 0.06
        )
        let lightCalm = try stillSpread(calm, isDark: false)
        XCTAssertGreaterThan(
            lightCalm.spread, 0.05,
            "an ordinary wallpaper lost its structure to a cap that should not have bound"
        )
    }

    /// The light bake's highlights, which are the mirror of the dark bake's
    /// shadows and were wrong in the same way for the same reason.
    ///
    /// `luminanceShift` is additive, so lifting a dim wallpaper onto light's
    /// 0.72 target pushes everything above `1 - shift` past white. Nothing
    /// measured it, and it was not small: the widest still in this Mac's aerial
    /// library arrived with 17.3% of its pixels clipped and a full-range ramp
    /// with 19.1% blown to *flat white* — range no veil could have shown,
    /// however thin. Solving the gain with the offset removes it.
    func testTheLightBakeStopsBlowingTheWallpapersHighlightsToWhite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-highlights-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A full-range ramp: blur-invariant, so unlike a photograph its whole
        // range survives to the normalization.
        let url = try writeRampWallpaper(
            base: (0.5, 0.5, 0.5), range: 1.9, into: directory, named: "ramp"
        )
        let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: false)
        guard case let .wallpaper(image, _, _)? = DesktopBackdropRenderer.render(key: key) else {
            return XCTFail("the ramp fixture produced no painting")
        }

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var blown = 0
        var index = 0
        while index + 3 < pixels.count {
            if pixels[index] == 255, pixels[index + 1] == 255, pixels[index + 2] == 255 {
                blown += 1
            }
            index += 4
        }
        let share = Double(blown) / Double(image.width * image.height)
        print(String(format: "[light-glass] full-range ramp blown to white: %.1f%%", share * 100))
        XCTAssertLessThanOrEqual(
            share, 0.01,
            "the light bake blew \(Int(share * 100))% of the still to flat white"
        )
    }

    /// The gain is a *cap*, never a boost, and it is solved together with the
    /// offset. Both are pure, and both are the kind of arithmetic that looks
    /// right and is off by `(0.5 - mean)(1 - gain)`.
    ///
    /// The cap is now solved from the still's **worst-patch excursion** rather
    /// than from a p5..p95 spread. That is not a refactor: a percentile band by
    /// construction excludes the tail, and the tail is the only thing every
    /// contrast floor in this file is measured on. The properties below are the
    /// same ones the spread cap had to hold, restated on the quantity that
    /// actually binds.
    func testTheRangeCapOnlyEverRemovesRangeAndTheOffsetIsSolvedAfterIt() {
        for isDark in [false, true] {
            let headroom = DesktopBackdropRenderer.tailHeadroom(isDark: isDark)
            // Never manufactures contrast a desktop does not have: a wallpaper
            // whose worst patch is already inside the headroom is passed
            // through untouched.
            for excursion in [0.0, 0.02, 0.08, headroom] {
                XCTAssertEqual(
                    DesktopBackdropRenderer.tailGain(excursion: excursion, isDark: isDark),
                    1, accuracy: 0.0001,
                    "a \(excursion)-excursion wallpaper was given a gain other than 1"
                )
            }
            XCTAssertLessThan(
                DesktopBackdropRenderer.tailGain(excursion: 0.3, isDark: isDark), 1
            )
            // Monotone: the further the worst patch, the harder the cap bites.
            XCTAssertLessThan(
                DesktopBackdropRenderer.tailGain(excursion: 0.5, isDark: isDark),
                DesktopBackdropRenderer.tailGain(excursion: 0.3, isDark: isDark)
            )
            // A degenerate decode cannot divide by zero into an infinite gain.
            XCTAssertEqual(DesktopBackdropRenderer.tailGain(excursion: 0, isDark: isDark), 1)
            // And the cap lands the worst patch exactly on the headroom, which
            // is the whole reason for solving it there: the tone map is affine,
            // so `out(tail) - target = (tail - mean) * gain`.
            for excursion in [0.2, 0.35, 0.6] {
                let gain = DesktopBackdropRenderer.tailGain(excursion: excursion, isDark: isDark)
                XCTAssertEqual(
                    excursion * gain, headroom, accuracy: 0.0001,
                    "an excursion of \(excursion) did not land on the headroom"
                )
            }

            // The offset lands the mean on target *after* the gain has moved it.
            // `CIColorControls` applies contrast about 0.5 and then adds
            // brightness, which this reproduces.
            for mean in [0.08, 0.263, 0.5, 0.792] {
                for gain in [1.0, 0.75, 0.4] {
                    let shift = DesktopBackdropRenderer.luminanceShift(
                        mean: mean, isDark: isDark, gain: gain
                    )
                    let landed = (mean - 0.5) * gain + 0.5 + shift
                    XCTAssertEqual(
                        landed, DesktopBackdropRenderer.targetLuminance(isDark: isDark),
                        accuracy: 0.0001,
                        "mean \(mean) at gain \(gain) landed on \(landed)"
                    )
                }
            }
            // At gain 1 it is the expression it always was.
            XCTAssertEqual(
                DesktopBackdropRenderer.luminanceShift(mean: 0.438, isDark: isDark),
                DesktopBackdropRenderer.targetLuminance(isDark: isDark) - 0.438,
                accuracy: 0.0001
            )
            // And the chroma the gain would have eaten is divided back out, so a
            // capped wallpaper is not also a desaturated one.
            XCTAssertGreaterThan(
                DesktopBackdropRenderer.saturation(mean: 0.435, isDark: isDark, gain: 0.55),
                DesktopBackdropRenderer.saturation(mean: 0.435, isDark: isDark, gain: 1)
            )
        }
    }

    /// Dark damps chroma harder than light, and for a reason that is about the
    /// surface rather than about taste: at a composite luminance near 0.10 a
    /// channel difference light would not notice is most of what the surface is.
    func testDarkDampsTheWallpapersChromaHarderThanLight() {
        XCTAssertEqual(DesktopBackdropRenderer.saturationCeiling(isDark: false), 0.85, accuracy: 0.0001)
        XCTAssertEqual(DesktopBackdropRenderer.saturationCeiling(isDark: true), 0.50, accuracy: 0.0001)
        XCTAssertLessThan(
            DesktopBackdropRenderer.saturationCeiling(isDark: true),
            DesktopBackdropRenderer.saturationCeiling(isDark: false)
        )
        // Still a *damping* and not a conversion to greyscale: the painted
        // wallpaper has to remain the reason the layer exists.
        XCTAssertGreaterThan(DesktopBackdropRenderer.saturationCeiling(isDark: true), 0.35)

        // And the ceiling really is the ceiling in dark too — the normalization
        // below it still scales with the wallpaper's own luminance.
        for mean in [0.30, 0.45, 0.60] {
            XCTAssertLessThan(
                DesktopBackdropRenderer.saturation(mean: mean, isDark: true),
                DesktopBackdropRenderer.saturationCeiling(isDark: true)
            )
        }
    }

    /// The warmth is derived per appearance now, and the derivation is the
    /// point: a fixed 4% of a 0.738-luminance amber is a nineteen-times larger
    /// relative perturbation on a still normalized to 0.16 than on one
    /// normalized to 0.72, in a hue opposite the cool cast — which is how
    /// "blue" became "purple".
    func testGlassWarmthCoverageTracksTheSurfaceItLandsOn() {
        XCTAssertEqual(GlassWarmth.opacity(isDark: false), GlassWarmth.opacity, accuracy: 0.0001)
        let ratio = DesktopBackdropRenderer.targetLuminance(isDark: true)
            / DesktopBackdropRenderer.targetLuminance(isDark: false)
        XCTAssertEqual(
            GlassWarmth.opacity(isDark: true),
            GlassWarmth.opacity * ratio,
            accuracy: 0.0001
        )
        // Still there. A layer scaled to zero is a layer deleted, and the whole
        // argument for a declared amber is that it says out loud that it exists.
        XCTAssertGreaterThan(GlassWarmth.opacity(isDark: true), 0.005)
        XCTAssertLessThan(GlassWarmth.opacity(isDark: true), GlassWarmth.opacity(isDark: false))
    }

    // MARK: - The three workspace canvases

    /// "The tinted canvas settings should actually be tinted or a white solid."
    ///
    /// They were neither, because they were the same surface twice: measured
    /// against the real desktop the old Tinted canvas landed 0.016 off-neutral
    /// in light, against Solid's 0.000 — one and a half percent of channel
    /// spread, which nobody can see. This is the arithmetic that says the two
    /// modes are now different objects.
    func testSolidAndTintedCanvasesAreUnmistakablyDifferentSurfaces() {
        func offNeutral(_ channels: [Double]) -> Double {
            let mean = channels.reduce(0, +) / Double(channels.count)
            guard mean > 0 else { return 0 }
            return channels.map { abs($0 - mean) / mean }.max() ?? 0
        }
        func luminance(_ channels: [Double]) -> Double {
            channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }

        // The sampled tint of Michael's desktop, through the shipping sampler.
        let sampled = DesktopTintComponents(red: 0.3152, green: 0.4646, blue: 0.5343)
        // `windowBackgroundColor`, read off the two appearances.
        let solids = [false: [1.0, 1.0, 1.0], true: [0.1176, 0.1176, 0.1176]]

        for isDark in [false, true] {
            let solid = solids[isDark]!
            let tint = DesktopTintSampler.revalued(
                sampled,
                peak: DesktopTintSampler.canvasTintPeak(isDark: isDark)
            )
            let coverage = DesktopTintSampler.canvasTintCoverage(isDark: isDark)
            let channels = [tint.red, tint.green, tint.blue]
            let tinted = zip(solid, channels).map { $0 * (1 - coverage.top) + $1 * coverage.top }

            // Solid contributes no wallpaper at all: perfectly achromatic.
            XCTAssertEqual(offNeutral(solid), 0, accuracy: 0.0001)

            // Tinted is unmistakably hued — an order of magnitude past the old
            // 0.016, and past the 0.05 bar this app sets for anything that
            // claims to be neutral.
            XCTAssertGreaterThan(
                offNeutral(tinted),
                0.10,
                "the Tinted canvas (isDark: \(isDark)) is not visibly tinted"
            )

            // …without becoming a different brightness of canvas. Re-valuing
            // the tint first is what buys this: light keeps 90%+ of the solid's
            // luminance instead of dimming toward grey.
            if isDark {
                XCTAssertGreaterThan(luminance(tinted), luminance(solid))
                XCTAssertLessThan(luminance(tinted), 0.30, "a dark canvas that glows is not a canvas")
            } else {
                XCTAssertGreaterThan(
                    luminance(tinted) / luminance(solid),
                    0.88,
                    "Tinted is dimming the canvas instead of tinting it"
                )
            }

            // The gradient still reads as light from above.
            XCTAssertGreaterThan(coverage.top, coverage.bottom)
        }
    }

    /// Re-valuing keeps the hue and moves only the value — that is the whole
    /// trick, so it is asserted rather than assumed.
    func testRevaluedTintKeepsItsHueAndOnlyMovesItsValue() {
        let tint = DesktopTintComponents(red: 0.3152, green: 0.4646, blue: 0.5343)
        let full = DesktopTintSampler.revalued(tint, peak: 1.0)
        XCTAssertEqual(max(full.red, max(full.green, full.blue)), 1.0, accuracy: 0.0001)
        // Channel ratios — the hue — survive exactly.
        XCTAssertEqual(full.red / full.blue, tint.red / tint.blue, accuracy: 0.0001)
        XCTAssertEqual(full.green / full.blue, tint.green / tint.blue, accuracy: 0.0001)

        let low = DesktopTintSampler.revalued(tint, peak: 0.34)
        XCTAssertEqual(max(low.red, max(low.green, low.blue)), 0.34, accuracy: 0.0001)
        XCTAssertEqual(low.red / low.blue, tint.red / tint.blue, accuracy: 0.0001)

        // A grey desktop re-values to a grey, not to a hue.
        let grey = DesktopTintSampler.revalued(
            DesktopTintComponents(red: 0.4, green: 0.4, blue: 0.4),
            peak: 1.0
        )
        XCTAssertEqual(grey.red, grey.blue, accuracy: 0.0001)
        // A degenerate (black) sample cannot divide by nothing.
        let black = DesktopTintSampler.revalued(
            DesktopTintComponents(red: 0, green: 0, blue: 0),
            peak: 0.34
        )
        XCTAssertEqual(black.red, 0.34, accuracy: 0.0001)
        XCTAssertEqual(black.blue, 0.34, accuracy: 0.0001)
    }

    /// The warmth is a SEPARATE, DECLARED constant, and that is the point.
    ///
    /// `testDeclaredNeutralConstantsAreAchromatic` is what caught the
    /// `#0B0C12` blue-purple cast, and the only safe way to add warmth without
    /// weakening it is to keep every "neutral" honest and put the chroma
    /// somewhere that says out loud that it is chroma. `GlassWarmth` is that
    /// place, it is deliberately absent from the neutrals list over there, and
    /// this is the test that stops it from becoming a licence to drift: it has
    /// to stay an amber, and it has to stay barely there.
    func testGlassWarmthIsADeclaredAmber() {
        // Warm means red leads and blue trails. Anything else is a different
        // decision wearing this constant's name.
        XCTAssertGreaterThan(GlassWarmth.red, GlassWarmth.green)
        XCTAssertGreaterThan(GlassWarmth.green, GlassWarmth.blue)

        // …in the amber/orange band, not red and not yellow. Hue in degrees,
        // computed the standard way from the max/min channels.
        let maximum = max(GlassWarmth.red, GlassWarmth.green, GlassWarmth.blue)
        let minimum = min(GlassWarmth.red, GlassWarmth.green, GlassWarmth.blue)
        let delta = maximum - minimum
        XCTAssertGreaterThan(delta, 0, "a warm layer with no chroma is not a warm layer")
        let hue = 60 * ((GlassWarmth.green - GlassWarmth.blue) / delta)
        XCTAssertGreaterThan(hue, 15, "that is red, not warmth")
        XCTAssertLessThan(hue, 45, "that is yellow, not warmth")

        // A high-value amber: at a few percent coverage a dark tint pulls the
        // composite toward grey-brown instead of toward warm.
        XCTAssertGreaterThan(GlassWarmth.red, 0.9)

        // And it stays a hint. The ceiling is the whole safety argument — at 8%
        // this stops being warmth and starts being a tint, which is the thing
        // the neutrality invariant exists to prevent. Stated on the light
        // coverage, which is the number the dark one is derived from; see
        // `testGlassWarmthCoverageTracksTheSurfaceItLandsOn`.
        XCTAssertEqual(GlassWarmth.opacity, 0.029, accuracy: 0.0001)
        XCTAssertLessThan(GlassWarmth.opacity, 0.08)
        XCTAssertGreaterThan(GlassWarmth.opacity, 0.02, "deleted in all but name")
    }

    /// The blur is a size **on screen**, not a fraction of the picture — and
    /// the band it has to stay inside is two-sided.
    ///
    /// It used to assert `blurRadius >= 24` on a 176px still: one-sided, and it
    /// passed for exactly the wrong reason — the bake had been tuned until *no*
    /// structure survived, which is what produced the flat colour field
    /// round 7 had to undo. Round 7 made it two-sided as a fraction of the
    /// still, which was right while every surface showed the whole still
    /// stretched to its own width. Desktop pinning ends that identity: a 210 pt
    /// sidebar now shows about an eighth of the wallpaper, so a fraction of the
    /// wallpaper is eight times that fraction of the sidebar.
    ///
    /// So the bound moves to where it was always really about — how much of a
    /// **surface** one blur radius covers. Too small and the desktop resolves
    /// as a legible picture behind the labels; too large and the narrowest
    /// surface is one soft wash end to end, which is a colour field again.
    func testWallpaperBakeBlursPastAnyLegibleShapeButNotPastEveryShape() {
        let share = DesktopBackdropRenderer.blurShareOfNarrowestSurface
        XCTAssertGreaterThanOrEqual(
            share, 0.06,
            "the wallpaper resolves as a picture rather than as a wash"
        )
        XCTAssertLessThanOrEqual(
            share, 0.22,
            """
            one blur radius covers \(Int(share * 100))% of a 210 pt sidebar, \
            leaving about \(Int(1 / share)) masses across it — a colour field, \
            not frosted glass
            """
        )
        // A blur stated in points has to survive being converted for whatever
        // display the desktop is on, and it stays in band across every width a
        // Mac can report.
        for screenPoints in [1280.0, 1512, 1728, 2560, 3440] {
            let radius = DesktopBackdropRenderer.blurRadius(screenPoints: screenPoints)
            XCTAssertEqual(
                radius / Double(DesktopBackdropRenderer.stillWidth) * screenPoints,
                DesktopBackdropRenderer.desktopBlurPoints,
                accuracy: 0.001,
                "the blur stops being \(DesktopBackdropRenderer.desktopBlurPoints) pt on screen"
            )
            // The working resolution has to be fine enough that the structure
            // the blur keeps is the wallpaper's and not the decode's: measured,
            // a 176px still correlates 0.841 with a 1024px reference and a
            // 448px one 0.932. Twenty pixels per retained feature is the floor
            // round 7 established, and it has to hold at the *widest* display,
            // where the radius in still pixels is smallest.
            XCTAssertGreaterThanOrEqual(
                radius, 4,
                "at \(Int(screenPoints)) pt the blur is \(radius) still-pixels — aliasing, not texture"
            )
        }
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
        let tint = try XCTUnwrap(DesktopTintSampler.wallpaperAverage(rgba: [0, 0, 0, 255]))
        XCTAssertGreaterThan(tint.red, 0.0)
        XCTAssertNil(DesktopTintSampler.meanLuminance(rgba: [0, 0, 0, 0]))
    }

    /// The whole point of normalizing: the composite the eye actually sees is
    /// the same brightness on every desktop, so a coverage number means one
    /// thing rather than one thing per wallpaper. Modelled end to end —
    /// normalize the still, then lay the veil over it — across the full range of
    /// wallpapers.
    ///
    /// The *invariance* is what this test is for and it is exact (spread < 0.001
    /// across every possible wallpaper mean). The two brightness bounds under it
    /// are a much weaker "and the result is still frost" sanity check, and the
    /// light one moves with the veil: at 0.60 coverage the light composite sat
    /// at 0.888, at 0.45 it sits at 0.846. That is the translucency Michael
    /// asked for arriving, not a surface going grey — 0.846 is still 45% of the
    /// way from the still to pure white, and the composite is 0.774/0.860/0.897.
    /// The legibility this bound was standing in for is held directly, on
    /// rendered pixels, by `testLightGlassStaysLegibleOnTheWorstPatchOfEveryWallpaper`,
    /// so it does not need a proxy here as well.
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
                // Still white-led frost rather than a tinted photograph: the
                // veil has to contribute more of the surface than the gap
                // between the still and white does.
                XCTAssertGreaterThan(composite, 0.83)
                XCTAssertGreaterThan(
                    composite,
                    DesktopBackdropRenderer.targetLuminance(isDark: false),
                    "the light surface is darker than the still it is supposed to be frosting"
                )
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

    // MARK: - Following the wallpaper

    /// The gap this closes: everything that made the backdrop re-resolve was a
    /// hint about the *window* — a Space switch, an activation, a screen change,
    /// a new key window. A user who picks a new desktop picture while Kaisola
    /// stays frontmost, or a rotating desktop that advances while they work,
    /// moved nothing Kaisola was listening to, so the glass kept painting the
    /// old wallpaper until they happened to leave the app and come back.
    ///
    /// The backstop is a fingerprint of a handful of modification dates. This
    /// exercises it against a real directory rather than against the developer's
    /// own desktop, which is the only way to *change* a wallpaper in a test.
    func testAWallpaperChangedInPlaceMovesTheSignatureThatWatchesForIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-desktop-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Store", directoryHint: .isDirectory)
        let thumbnails = root.appending(path: "aerials/thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let picture = root.appending(path: "desktop.png")
        try Data("first".utf8).write(to: picture)
        try Data("index".utf8).write(to: store.appending(path: "Index.plist"))

        func probe(depth: DesktopProbeDepth = .shallow, path: String? = nil)
            -> DesktopWallpaperSignature {
            DesktopBackdropProvider.signature(
                depth: depth,
                desktopImagePath: path ?? picture.path,
                paintedPath: picture.path,
                supportDirectory: root,
                modificationDate: DesktopBackdropProvider.modificationDateOnDisk
            )
        }

        let baseline = probe()
        XCTAssertNotNil(baseline.paintedModified, "the painted file's mtime is the whole mechanism")
        XCTAssertNotNil(baseline.storeModified)
        XCTAssertNotNil(baseline.thumbnailsModified)

        // Nothing has happened: repeated ticks must be silent, or the watch is
        // a re-render loop rather than a watch.
        XCTAssertEqual(
            DesktopBackdropProvider.signalDecision(previous: baseline, current: probe()),
            .unchanged
        )

        // 1. "Set as desktop picture" over the same path — the case a
        //    path-keyed cache cannot see at all.
        try Data("second and longer".utf8).write(to: picture)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: picture.path
        )
        XCTAssertEqual(
            DesktopBackdropProvider.signalDecision(previous: baseline, current: probe()),
            .changed,
            "a wallpaper replaced in place went unnoticed"
        )

        // 2. A different aerial *category*. No picture file exists for either
        //    one and `desktopImageURL` returns the same stand-in for both, so
        //    the store's index is the only thing that moves.
        let afterPicture = probe()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: store.appending(path: "Index.plist").path
        )
        XCTAssertEqual(
            DesktopBackdropProvider.signalDecision(previous: afterPicture, current: probe()),
            .changed,
            "choosing a different aerial category went unnoticed"
        )

        // 3. A rotating category whose representative still can change because
        //    macOS finished downloading another member of it. There is no
        //    published pointer at the clip playing right now, so the backdrop
        //    tracks the *set* it picks from, and that set is this directory.
        let afterStore = probe()
        try Data("thumb".utf8).write(to: thumbnails.appending(path: "new.png"))
        XCTAssertEqual(
            DesktopBackdropProvider.signalDecision(previous: afterStore, current: probe()),
            .changed,
            "a newly cached aerial still went unnoticed"
        )

        // 4. A rotating *picture folder* advancing: same store, same mtimes,
        //    different file. Only a deep probe can see this one.
        let afterThumbnails = probe(depth: .deep)
        XCTAssertEqual(
            DesktopBackdropProvider.signalDecision(
                previous: afterThumbnails,
                current: probe(depth: .deep, path: "/Users/test/Pictures/next.heic")
            ),
            .changed,
            "a rotating picture folder advancing went unnoticed"
        )
    }

    /// The two rungs must not fight each other. A shallow tick does not pay for
    /// `desktopImageURL`, so its path is `nil` — and if a missing value counted
    /// as a difference, every shallow tick after a deep one would fire a hint
    /// and the rationing would be pointless.
    func testAShallowTickIsNotMistakenForTheDesktopMoving() {
        let deep = DesktopWallpaperSignature(
            desktopImagePath: "/Users/test/Pictures/ridge.heic",
            paintedModified: Date(timeIntervalSince1970: 1),
            storeModified: Date(timeIntervalSince1970: 2),
            thumbnailsModified: Date(timeIntervalSince1970: 3)
        )
        let shallow = DesktopWallpaperSignature(
            desktopImagePath: nil,
            paintedModified: deep.paintedModified,
            storeModified: deep.storeModified,
            thumbnailsModified: deep.thumbnailsModified
        )
        XCTAssertEqual(
            DesktopBackdropProvider.signalDecision(previous: deep, current: shallow),
            .unchanged
        )
        XCTAssertEqual(
            DesktopBackdropProvider.signalDecision(previous: shallow, current: deep),
            .unchanged
        )
        // …but a shallow tick still reports everything it *did* read.
        XCTAssertEqual(
            DesktopBackdropProvider.signalDecision(
                previous: deep,
                current: DesktopWallpaperSignature(
                    desktopImagePath: nil,
                    paintedModified: Date(timeIntervalSince1970: 99),
                    storeModified: deep.storeModified,
                    thumbnailsModified: deep.thumbnailsModified
                )
            ),
            .changed
        )
        // No baseline is not a change: the first tick after a resolve exists to
        // record what "unchanged" looks like, and treating it as a change would
        // make the watch re-resolve every time it started.
        XCTAssertEqual(
            DesktopBackdropProvider.signalDecision(previous: nil, current: deep),
            .unchanged
        )
    }

    /// The costs, measured on this machine: three `stat`s take **0.045 ms**, and
    /// `NSWorkspace.desktopImageURL(for:)` takes **4.1 ms** and has to run on the
    /// main actor because `NSScreen` is not `Sendable`. A 4 ms main-thread stall
    /// every five seconds is a dropped frame every five seconds, so the two are
    /// rationed separately and that is the rule asserted here.
    func testTheExpensiveHalfOfAWatchTickIsRationedSeparately() {
        let now = Date()
        let deepInterval = DesktopBackdropProvider.desktopDeepProbeInterval

        XCTAssertEqual(
            DesktopBackdropProvider.probeDepth(now: now, lastDeepProbe: .distantPast),
            .deep,
            "the first tick has never read the desktop URL and must"
        )
        XCTAssertEqual(
            DesktopBackdropProvider.probeDepth(now: now, lastDeepProbe: now),
            .shallow
        )
        XCTAssertEqual(
            DesktopBackdropProvider.probeDepth(
                now: now,
                lastDeepProbe: now.addingTimeInterval(-deepInterval + 0.1)
            ),
            .shallow
        )
        XCTAssertEqual(
            DesktopBackdropProvider.probeDepth(
                now: now,
                lastDeepProbe: now.addingTimeInterval(-deepInterval)
            ),
            .deep
        )
        // The cadences themselves: cheap often, expensive rarely, and both far
        // enough apart that a wallpaper change is noticed while the user is
        // looking at the window.
        XCTAssertLessThanOrEqual(DesktopBackdropProvider.desktopWatchInterval, 5)
        XCTAssertGreaterThanOrEqual(
            deepInterval,
            DesktopBackdropProvider.desktopWatchInterval * 4,
            "a deep tick this often is a 4 ms main-thread stall on the fast cadence"
        )
    }

    /// Proof that the signal path is wired, taken by *firing* it.
    ///
    /// Method, stated honestly. `WallpaperAgent` links
    /// `NSDistributedNotificationCenter` and carries the string
    /// `com.apple.desktop`, so the long-standing notification is very probably
    /// still posted on macOS 26 — but confirming that needs a real desktop
    /// change, and changing the developer's desktop is not something this suite
    /// is allowed to do. So what is proved here is the half that *is* provable:
    /// the observer is registered on the right centre under the right name, and
    /// the handler reaches the coalescing door. The notification is posted by
    /// this test, not by macOS.
    ///
    /// That is also why nothing depends on it: `desktopWatchInterval` and the
    /// signature above are the guarantee, and this is the fast path.
    @MainActor
    func testTheDesktopChangedNotificationReachesTheBackdropProvider() {
        let provider = DesktopBackdropProvider.shared
        // The watch only arms once a glass surface has asked for a backdrop,
        // which is also what makes `invalidate` do anything at all.
        provider.refresh(isDark: true)
        let before = provider.wallpaperSignals

        let arrived = expectation(description: "com.apple.desktop reaches the provider")
        let token = DistributedNotificationCenter.default().addObserver(
            forName: DesktopBackdropProvider.desktopChangedNotification,
            object: nil,
            queue: .main
        ) { _ in arrived.fulfill() }
        defer { DistributedNotificationCenter.default().removeObserver(token) }

        DistributedNotificationCenter.default().postNotificationName(
            DesktopBackdropProvider.desktopChangedNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        wait(for: [arrived], timeout: 5)
        // The provider's own observer runs on the same main queue, so by the
        // time ours has fired and the run loop has turned over once more, its
        // counter has moved.
        let bumped = expectation(description: "the provider counted the signal")
        DispatchQueue.main.async { bumped.fulfill() }
        wait(for: [bumped], timeout: 5)

        XCTAssertGreaterThan(
            provider.wallpaperSignals,
            before,
            "a com.apple.desktop notification did not reach the provider's invalidation path"
        )
    }

    /// The guarantee, driven end to end: a file under the wallpaper store moves,
    /// and the provider's own watch tick — not a reimplementation of it — turns
    /// that into a hint.
    ///
    /// This is the half the notification test cannot cover. It runs the shipped
    /// `probeDesktop` against a fixture store, because the only way to run it
    /// against the real one is to change the developer's desktop.
    @MainActor
    func testAWatchTickTurnsAStoreChangeIntoAnInvalidation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-watch-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = root.appending(path: "Store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = store.appending(path: "Index.plist")
        try Data("first".utf8).write(to: index)

        let provider = DesktopBackdropProvider.shared
        provider.refresh(isDark: true)
        XCTAssertTrue(
            provider.isWatchingDesktop,
            "a glass surface asked for a backdrop and no watch was armed"
        )

        // `refresh` starts a resolve, and a resolve clears the watch's baseline
        // when it lands — by design, because the file it just read *is* the new
        // baseline. So wait for it before taking one, or this test measures how
        // long a bake took rather than what the watch does.
        await provider.settleResolves()

        // First tick: records the baseline. A tick with nothing to compare
        // against must not fire, or the watch is a re-render loop.
        await provider.probeDesktop(supportDirectory: root)
        let baselineSignals = provider.wallpaperSignals
        XCTAssertNotNil(provider.wallpaperSignature)
        await provider.probeDesktop(supportDirectory: root)
        XCTAssertEqual(
            provider.wallpaperSignals, baselineSignals,
            "an unchanged desktop still produced a hint"
        )

        // The user picks a new desktop picture: the wallpaper agent rewrites the
        // store's index. Nothing about the window changed, which is exactly the
        // case that used to go unnoticed until the app was left and re-entered.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(300)],
            ofItemAtPath: index.path
        )
        await provider.probeDesktop(supportDirectory: root)
        XCTAssertGreaterThan(
            provider.wallpaperSignals, baselineSignals,
            "the wallpaper store changed and the watch did not hint the provider"
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
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarIdealWidth, 210)
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

    /// The whole 40pt chrome band, finally.
    ///
    /// v1.1.9 deleted the band and gave the card its height, but only 12 of the
    /// 40 points reached the pane: the two toggles were still anchored to the
    /// card's top-right corner, and the Files rail opens a 30pt header bar 6pt
    /// below that corner, so a card run to the window's top put the revealed
    /// pair over the controls the user was aiming at. The card stopped 28pt
    /// short to keep them apart.
    ///
    /// v1.1.10 moves the pair into the sidebar's traffic-light band instead, so
    /// nothing is drawn over the card's corner and the card takes the rest.
    func testTheDetailCardRunsToTheWindowTopInTheSidebarLayout() {
        // Nothing above the card but the gutter every other side already has.
        XCTAssertEqual(
            NativeWorkspaceChrome.detailPanelTopInset(layout: .leftTree),
            KaisolaVisualSystem.chromeInset
        )
        XCTAssertEqual(NativeWorkspaceChrome.detailPanelTopInset(layout: .leftTree), 6)

        // The reclaim, stated as a number rather than as a memory. The band was
        // `chromePanelTopInset - chromeInset` = 40pt tall with no card inset
        // beneath it; v1.1.9 took it to 28, and this takes it to 6.
        let oldBand = NativeWorkspaceChrome.chromePanelTopInset - KaisolaVisualSystem.chromeInset
        XCTAssertEqual(oldBand, 40)
        XCTAssertEqual(oldBand - NativeWorkspaceChrome.detailPanelTopInset(layout: .leftTree), 34)
        XCTAssertEqual(
            NativeWorkspaceChrome.detailToggleStripHeight
                - NativeWorkspaceChrome.detailPanelTopInset(layout: .leftTree),
            22,
            "the 22pt v1.1.9 could not reach is what this release is for"
        )
    }

    /// The top-bar layout has no sidebar band to move the pair into, so it keeps
    /// the strip — and the strip has to stay exactly as tall as the controls it
    /// reveals, so a later pass cannot grow it back into somewhere to put chrome.
    func testTheTopBarLayoutKeepsTheStripItRevealsItsTogglesIn() {
        XCTAssertEqual(
            NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar),
            NativeWorkspaceChrome.detailToggleStripHeight
        )
        XCTAssertEqual(
            NativeWorkspaceChrome.detailToggleStripHeight,
            NativeWorkspaceChrome.detailChromeControlHeight
                + NativeWorkspaceChrome.detailToggleRevealPadding * 2
        )
        XCTAssertEqual(NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar), 28)
        XCTAssertGreaterThan(
            NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar),
            NativeWorkspaceChrome.detailPanelTopInset(layout: .leftTree)
        )

        // The hover target is sized from the pointer, not from the pair it
        // reveals: a target the size of what it shows is one you have to
        // already know is there.
        XCTAssertGreaterThan(
            NativeWorkspaceChrome.detailToggleRevealWidth,
            NativeWorkspaceChrome.detailChromeControlWidth * 2
                + NativeWorkspaceChrome.detailChromeControlGap
        )
    }

    /// The sidebar layout reclaims the band by *removing* the pair rather than
    /// relocating it, so the thing worth pinning is that the doors it held are
    /// all still open — the two the sidebar footer's overflow menu carries are
    /// the ones a pointer needs.
    ///
    /// Both were verified present in the AX tree on the same dev launch that
    /// measured the reclaim, along with the Files rail's own permanent Hide
    /// Files button (a real synthesized click through it closed the rail).
    func testBothPanelsKeepACommandThatIsNotAPointerCornerOrAShortcut() {
        for id in [AppCommandID.toggleFiles, AppCommandID.toggleDocumentPreview] {
            let definition = AppCommandRegistry.definition(for: id)
            XCTAssertNotNil(
                definition,
                "\(id.rawValue) lost its command, so the palette and menus lost it too"
            )
            XCTAssertNotNil(
                definition?.defaultShortcut,
                "\(id.rawValue) has no keyboard door left"
            )
        }
    }

    func testChromePanelTokensSitBetweenCardAndShell() {
        XCTAssertGreaterThan(KaisolaVisualSystem.chromeRadius, KaisolaVisualSystem.cardRadius)
        XCTAssertLessThan(KaisolaVisualSystem.chromeRadius, KaisolaVisualSystem.shellRadius)
        XCTAssertEqual(KaisolaVisualSystem.chromeInset, 6)
    }

    func testReduceMotionFallbackStripsEveryDescendantAnimationTransaction() {
        var ordinary = Transaction(animation: .linear(duration: 1))
        KaisolaMotionPolicy.apply(reduceMotion: false, to: &ordinary)
        XCTAssertNotNil(ordinary.animation)
        XCTAssertFalse(ordinary.disablesAnimations)

        var reduced = Transaction(animation: .linear(duration: 1))
        KaisolaMotionPolicy.apply(reduceMotion: true, to: &reduced)
        XCTAssertNil(reduced.animation)
        XCTAssertTrue(reduced.disablesAnimations)
    }

    /// v1.1.8 made everything a step rounder. The literals matter less than the
    /// shape of the ladder: a corner nested inside another must be the tighter
    /// one, or the inner shape's arc crosses its container's and the chrome
    /// reads as two unrelated rounding systems.
    ///
    /// Stated as the whole ordering rather than as one `chromeRadius <
    /// shellRadius` pair, because the pass that broke it would be exactly the
    /// pass that bumps one rung and forgets its neighbour.
    func testCornerLadderIsStrictlyIncreasingOutward() {
        let ladder: [(String, CGFloat)] = [
            ("control", KaisolaVisualSystem.controlRadius),
            ("pane", KaisolaVisualSystem.paneRadius),
            ("inset", KaisolaVisualSystem.insetRadius),
            ("card", KaisolaVisualSystem.cardRadius),
            ("panel", KaisolaVisualSystem.panelRadius),
            ("chrome", KaisolaVisualSystem.chromeRadius),
            ("shell", KaisolaVisualSystem.shellRadius),
        ]
        for (inner, outer) in zip(ladder, ladder.dropFirst()) {
            XCTAssertLessThan(
                inner.1,
                outer.1,
                "\(inner.0)Radius must stay tighter than \(outer.0)Radius"
            )
        }
        XCTAssertEqual(KaisolaVisualSystem.shellRadius, 20)
        XCTAssertEqual(KaisolaVisualSystem.chromeRadius, 18)

        // The rail's active-project capsule uses `insetRadius` inside a 32pt
        // row, so it has to stay under half the row height or the capsule turns
        // into a stadium and stops reading as a rectangle at all.
        XCTAssertLessThan(KaisolaVisualSystem.insetRadius, 16)
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
    /// to pay for a visible hierarchy step and a whole account name. v1.1.7 gave
    /// 20 of those points back (248 → 228) once the rail spent none of its width
    /// on chrome, and v1.1.8 takes 18 more (228 → 210).
    ///
    /// The *minimum* and the *maximum* are unchanged through all of it: nothing
    /// about the narrow rail moves, and anyone who wants the wide one drags it
    /// back. What v1.1.8 does change is that the narrowing is no longer free —
    /// the session indent gives something up for it, while the footer adopts a
    /// stable first-name label; both decisions are pinned in
    /// `QuietIdentityMarkTests` rather than left as comments here.
    func testProjectSidebarHasComfortableResizableWidth() {
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarMinimumWidth, 168)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarIdealWidth, 210)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarMaximumWidth, 340)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerWidth, 1)
        // Still comfortably inside its own bounds after two narrowings.
        XCTAssertGreaterThan(
            NativeWorkspaceChrome.projectSidebarIdealWidth,
            NativeWorkspaceChrome.projectSidebarMinimumWidth
        )
    }

    /// The pointer target is sized from the gap the eye aims at, not from the
    /// one-point rule: the inset chrome cards leave `chromeInset` of backdrop on
    /// each side, and the hit zone has to span that whole gap *plus* overlap
    /// onto both cards. A zone narrower than the gap leaves a dead band the
    /// pointer crosses on its way in, which is seen as the cursor flickering.
    func testSidebarDividerHitZoneSpansTheWholeVisibleGap() {
        let gap = KaisolaVisualSystem.chromeInset + NativeWorkspaceChrome.projectSidebarDividerWidth
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerHitWidth, 22)
        XCTAssertGreaterThan(NativeWorkspaceChrome.projectSidebarDividerHitWidth, gap)
        // Reach past the visible gutter, onto the content on each side, so the
        // pointer is never over a point that is neither content nor divider.
        XCTAssertGreaterThan(
            NativeWorkspaceChrome.projectSidebarDividerReach,
            KaisolaVisualSystem.chromeInset
        )
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerReach, 10.5)
    }

    /// v1.1.7: "grab it anywhere, easily" is one rule, so it is one number.
    /// Every draggable divider in the workspace — the sidebar splitter and both
    /// pane handles — has to clear `dividerCorridorReach` on each side of its
    /// visible line, or the user is aiming at a hairline again.
    func testEveryDividerCorridorClearsTheGrabReachOnBothSides() {
        XCTAssertGreaterThanOrEqual(NativeWorkspaceChrome.dividerCorridorReach, 10)
        XCTAssertGreaterThanOrEqual(
            NativeWorkspaceChrome.projectSidebarDividerReach,
            NativeWorkspaceChrome.dividerCorridorReach,
            "the sidebar splitter is back to a line you have to hit"
        )
        XCTAssertGreaterThanOrEqual(
            SessionPaneDividerSizing.reach,
            NativeWorkspaceChrome.dividerCorridorReach,
            "the pane splitters are back to a line you have to hit"
        )
        // v1.1.8: the document-preview and Files dividers were never in this
        // check and had quietly stayed at 17 (8pt of reach) while everything
        // else moved to 22. "Every draggable divider" now means every one.
        XCTAssertGreaterThanOrEqual(
            (NativeDetailPaneSizing.dividerHitWidth - NativeDetailPaneSizing.dividerWidth) / 2,
            NativeWorkspaceChrome.dividerCorridorReach,
            "the document/Files splitters are back to a line you have to hit"
        )
        XCTAssertEqual(
            NativeDetailPaneSizing.dividerHitWidth,
            NativeWorkspaceChrome.projectSidebarDividerHitWidth,
            accuracy: 0.001,
            "all three corridors must be the same width or the grab feel forks"
        )
        // The two corridors are the same width, so the sidebar and the panes
        // cannot drift into two different grab feels.
        XCTAssertEqual(
            SessionPaneDividerSizing.hitExtent,
            NativeWorkspaceChrome.projectSidebarDividerHitWidth,
            accuracy: 0.001
        )
        // …and the corridor is an overlay, not layout: the visible rule still
        // costs exactly one point, so widening the grab zone never opened a
        // gutter between the panes.
        XCTAssertEqual(SessionPaneDividerSizing.layoutExtent, 1)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerWidth, 1)

        // The sidebar's own tracker can only ever supply the reach on ITS side
        // of the split: `NSTrackingArea(.inVisibleRect)` is clipped to the
        // NSSplitView subview it lives in. Measured on the running app, a
        // 40pt-wide tracker centred on the divider had a visibleRect that
        // stopped 0.5pt past the divider's centre. So the detail side needs its
        // own strip, and `dividerCorridorReach` — already pinned to the floor
        // above — is exactly what backs it (`DetailEdgeResizeAffordance`'s
        // frame width).
        //
        // What none of the checks above pin is the PANE corridor's own reach
        // as a literal number, the way the sidebar's is pinned in
        // `testSidebarDividerHitZoneSpansTheWholeVisibleGap`. The relative
        // checks already leave it fully determined (>= the floor, and its
        // `hitExtent` == the sidebar's), but only by hopping to another test's
        // constants — stating the number here means a future change to
        // `layoutExtent` or `hitExtent` that keeps both relative checks green
        // still cannot silently move it.
        XCTAssertEqual(SessionPaneDividerSizing.reach, 10.5)
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
        let closeWindow = try XCTUnwrap(fileMenu.items.first { $0.title == "Close Project Window" })
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
        XCTAssertTrue(items.contains(AppCommandID.navigationLayout(.leftTree).rawValue))
        XCTAssertTrue(items.contains(AppCommandID.navigationLayout(.topBar).rawValue))
        XCTAssertTrue(items.contains(AppCommandID.appearance(.light).rawValue))
        XCTAssertTrue(items.contains(AppCommandID.appearance(.dark).rawValue))

        // The current selections are checked.
        let topBarItem = try XCTUnwrap(viewMenu.items.first {
            ($0.representedObject as? String) == AppCommandID.navigationLayout(.topBar).rawValue
        })
        XCTAssertEqual(topBarItem.state, .on)
        let darkItem = try XCTUnwrap(viewMenu.items.first {
            ($0.representedObject as? String) == AppCommandID.appearance(.dark).rawValue
        })
        XCTAssertEqual(darkItem.state, .on)
    }
}
