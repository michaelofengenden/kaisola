import AppKit
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

        // The headline coverage: white at roughly a third in light, near-black
        // at roughly 44% in dark.
        XCTAssertEqual(GlassBackdropWash.sidebar(isDark: false).baseOpacity, 0.32, accuracy: 0.0001)
        XCTAssertEqual(GlassBackdropWash.sidebar(isDark: true).baseOpacity, 0.44, accuracy: 0.0001)
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

    func testProjectSidebarHasComfortableResizableWidth() {
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarMinimumWidth, 168)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarIdealWidth, 200)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarMaximumWidth, 260)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerWidth, 1)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerHitWidth, 17)
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarDividerReach, 8)
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

    func testDesktopTintSamplerKeepsWallpaperIdentityButCoolsIt() throws {
        let tint = try XCTUnwrap(DesktopTintSampler.cooledAverage(rgba: [
            255, 0, 0, 255,
            0, 0, 255, 255,
        ]))
        XCTAssertEqual(tint.red, 0.3117, accuracy: 0.0001)
        XCTAssertEqual(tint.green, 0.16, accuracy: 0.0001)
        XCTAssertEqual(tint.blue, 0.3387, accuracy: 0.0001)
        XCTAssertNil(DesktopTintSampler.cooledAverage(rgba: [0, 0, 0, 0]))
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
