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
    func testExternalEditorResolverDefaultsAndFailsClosed() {
        let resolve: (String) -> ExternalEditorResolution = { selection in
            ExternalEditorResolver.resolve(
                selection,
                applicationForBundleIdentifier: { _ in nil },
                applicationForLegacyName: { _ in nil },
                inspectApplication: { _ in nil }
            )
        }

        XCTAssertEqual(resolve(""), .systemDefault)
        XCTAssertEqual(resolve("  \n"), .systemDefault)
        XCTAssertEqual(resolve("bundle:"), .unresolved)
        XCTAssertEqual(resolve("path:relative.app"), .unresolved)
        XCTAssertEqual(resolve("An App That Is Not Installed"), .unresolved)
        XCTAssertFalse(resolve("bundle:missing.example").isAvailable)
    }

    func testExternalEditorResolverUsesStableBundleIdentityAndReadsLegacyChoices() throws {
        let applicationURL = try makeApplicationBundle(
            displayName: "Kaisola Test Editor",
            bundleIdentifier: "test.kaisola.editor"
        )
        let application = try XCTUnwrap(ExternalEditorApplication(url: applicationURL))
        XCTAssertEqual(application.displayName, "Kaisola Test Editor")
        XCTAssertEqual(
            ExternalEditorResolver.storedValue(for: application),
            "bundle:test.kaisola.editor"
        )

        let resolve: (String) -> ExternalEditorResolution = { selection in
            ExternalEditorResolver.resolve(
                selection,
                applicationForBundleIdentifier: { identifier in
                    identifier == "test.kaisola.editor" ? applicationURL : nil
                },
                applicationForLegacyName: { name in
                    name == "Kaisola Test Editor" ? applicationURL : nil
                },
                inspectApplication: { ExternalEditorApplication(url: $0) }
            )
        }
        XCTAssertEqual(resolve("bundle:test.kaisola.editor"), .application(application))
        XCTAssertEqual(resolve("test.kaisola.editor"), .application(application))
        XCTAssertEqual(resolve("Kaisola Test Editor"), .application(application))
        XCTAssertEqual(resolve(applicationURL.path), .application(application))
    }

    func testExternalEditorResolverFallsBackToValidatedApplicationPath() throws {
        let applicationURL = try makeApplicationBundle(
            displayName: "Unidentified Editor",
            bundleIdentifier: nil
        )
        let application = try XCTUnwrap(ExternalEditorApplication(url: applicationURL))
        XCTAssertNil(application.bundleIdentifier)
        XCTAssertEqual(
            ExternalEditorResolver.storedValue(for: application),
            "path:\(applicationURL.standardizedFileURL.path)"
        )
    }

    /// Cmd+Plus / Cmd+Minus walk the chat zoom ladder one rung at a time and
    /// stop at the ends; Cmd+0 returns to standard. The rungs must be far
    /// enough apart on macOS to be visible — `.large` is the system default,
    /// so a ladder clustered around it is a zoom control that does nothing.
    func testAgentChatZoomStepsClampAndReset() {
        let defaults = makeDefaults()
        let settings = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(settings.agentChatTextSize, .standard)
        XCTAssertEqual(AgentChatTextSize.standard.dynamicTypeSize, .large)

        settings.stepAgentChatTextSize(by: 1)
        XCTAssertEqual(settings.agentChatTextSize, .large)
        settings.stepAgentChatTextSize(by: 1)
        XCTAssertEqual(settings.agentChatTextSize, .extraLarge)
        settings.stepAgentChatTextSize(by: 1)
        XCTAssertEqual(settings.agentChatTextSize, .extraLarge, "the top rung clamps")

        settings.resetAgentChatTextSize()
        XCTAssertEqual(settings.agentChatTextSize, .standard)

        settings.stepAgentChatTextSize(by: -1)
        XCTAssertEqual(settings.agentChatTextSize, .compact)
        settings.stepAgentChatTextSize(by: -1)
        XCTAssertEqual(settings.agentChatTextSize, .compact, "the bottom rung clamps")

        let rungs = AgentChatTextSize.allCases.map(\.dynamicTypeSize)
        XCTAssertEqual(rungs, rungs.sorted(), "the ladder ascends")
        XCTAssertTrue(
            AgentChatTextSize.extraLarge.dynamicTypeSize.isAccessibilitySize,
            "the top rung is a real magnification, not a point of body text"
        )
    }

    func testExternalEditorSelectionRejectsNonApplicationsWithoutChangingTheDraft() throws {
        let defaults = makeDefaults()
        let settings = NativePreviewSettings(defaults: defaults)
        settings.externalEditorApp = "bundle:existing.example"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-not-an-application-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(settings.selectExternalEditor(at: directory))
        XCTAssertEqual(settings.externalEditorApp, "bundle:existing.example")
        XCTAssertFalse(settings.openInExternalEditor(directory))
        XCTAssertEqual(
            NativePreviewSettings(defaults: defaults).externalEditorApp,
            "bundle:existing.example"
        )

        settings.useSystemDefaultExternalEditor()
        XCTAssertEqual(settings.externalEditorResolution, .systemDefault)
        XCTAssertEqual(NativePreviewSettings(defaults: defaults).externalEditorApp, "")
    }

    func testExternalEditorSelectionPersistsTheStableApplicationIdentity() throws {
        let defaults = makeDefaults()
        let settings = NativePreviewSettings(defaults: defaults)
        let applicationURL = try makeApplicationBundle(
            displayName: "Persistent Editor",
            bundleIdentifier: "test.kaisola.persistent-editor"
        )

        XCTAssertTrue(settings.selectExternalEditor(at: applicationURL))
        XCTAssertEqual(settings.externalEditorApp, "bundle:test.kaisola.persistent-editor")
        XCTAssertEqual(
            NativePreviewSettings(defaults: defaults).externalEditorApp,
            "bundle:test.kaisola.persistent-editor"
        )
    }

    func testExternalEditorTestDocumentContainsOnlyBenignFixedText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-external-editor-test-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = try NativePreviewSettings.writeExternalEditorTestDocument(in: directory)

        XCTAssertEqual(url.lastPathComponent, NativePreviewSettings.externalEditorTestFileName)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "This safe test file contains no project or account data.\n"
        )
    }

    func testTerminalPaletteAccessibilitySummaryNamesThemeAndEveryVisualRole() {
        let summary = TerminalPalettePreviewAccessibility(themeTitle: "Kaisola")

        XCTAssertEqual(
            summary.label,
            "Terminal palette preview, Kaisola theme. "
                + "Foreground text: home path. "
                + "Background: terminal canvas. "
                + "Cursor: block cursor. "
                + "ANSI green: percent prompt. "
                + "ANSI blue: codex command."
        )
        XCTAssertEqual(
            TerminalPalettePreviewAccessibility.identifier,
            "settings.terminal.palette-preview"
        )
    }

    func testTerminalPaletteAccessibilitySummaryUsesTheSelectedThemeTitle() {
        XCTAssertTrue(
            TerminalPalettePreviewAccessibility(themeTitle: "Solar Echo")
                .label
                .hasPrefix("Terminal palette preview, Solar Echo theme.")
        )
    }

    func testIsolatedFixtureUpdaterNeverStartsSparkle() {
        let controller = NativeUpdateController(isolatedFixture: true)
        XCTAssertFalse(controller.startedUpdater)
        XCTAssertEqual(
            controller.availability,
            .unavailable("Updates are disabled in isolated fixtures.")
        )
    }

    func testBrokerFreeFixturePreparerCannotDiscoverOrLaunchABroker() async {
        do {
            _ = try await BrokerFreeFixturePreparer().prepare()
            XCTFail("A broker-free fixture preparer must never return a broker.")
        } catch {
            XCTAssertEqual(error as? BrokerDiscoveryError, .notRunning)
        }
    }

    func testIsolatedFixturesNeverLaunchAutomaticProviderUsageProbes() {
        XCTAssertFalse(RootShellView.shouldAutomaticallyRefreshPlanUsage(
            environment: ["KAISOLA_NATIVE_VISUAL_FIXTURE": "1"]
        ))
        XCTAssertFalse(RootShellView.shouldAutomaticallyRefreshPlanUsage(
            environment: ["KAISOLA_NATIVE_RESOURCE_WORKLOAD": "one-window-streaming"]
        ))
        XCTAssertTrue(RootShellView.shouldAutomaticallyRefreshPlanUsage(environment: [:]))
    }

    func testConnectionFooterPresentationKeepsSignedInAccountDestinationsAndDiagnostics() {
        let presentation = ConnectionFooterPresentation(
            accountName: "Michael Ofengenden",
            appVersion: "0.1.142"
        )

        XCTAssertEqual(
            presentation.sections,
            [
                .init(
                    id: .authentication,
                    title: "Michael Ofengenden",
                    rows: [.action(.signOut)]
                ),
                .init(
                    id: .destinations,
                    title: nil,
                    rows: [.action(.settings), .action(.usage)]
                ),
                .init(
                    id: .about,
                    title: "Kaisola v0.1.142",
                    rows: [.action(.copyDiagnostics)]
                ),
            ]
        )
        XCTAssertEqual(presentation.diagnosticLines, ["Kaisola 0.1.142"])
    }

    func testConnectionFooterPresentationKeepsSignedOutAuthenticationAndDestinations() {
        let presentation = ConnectionFooterPresentation(
            accountName: nil,
            appVersion: "Dev"
        )

        XCTAssertEqual(
            presentation.sections,
            [
                .init(
                    id: .authentication,
                    title: nil,
                    rows: [.action(.signInWithGoogle)]
                ),
                .init(
                    id: .destinations,
                    title: nil,
                    rows: [.action(.settings), .action(.usage)]
                ),
                .init(
                    id: .about,
                    title: "Kaisola vDev",
                    rows: [.action(.copyDiagnostics)]
                ),
            ]
        )
        XCTAssertEqual(presentation.diagnosticLines, ["Kaisola Dev"])
    }

    func testConnectionFooterNotificationsControlStillTogglesItsInbox() {
        XCTAssertTrue(ConnectionFooterPresentation.attentionInboxIsPresented(afterActivating: false))
        XCTAssertFalse(ConnectionFooterPresentation.attentionInboxIsPresented(afterActivating: true))
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
        XCTAssertEqual(
            NativeVisualTerminalAccessibilityGate.expectedMarkers(for: "terminal-continuous-scroll"),
            ["continuous-anchor-"]
        )
    }

    func testOptimizedContinuousScrollReceiptIsMachineReadableAndFailClosed() throws {
        let receipt = VisualTerminalContinuousScrollReceipt(
            optimizedBuild: true,
            scheduledHertz: 120,
            measuredHertz: 120,
            sampleCount: 120,
            sampleIntervalCount: 119,
            sampleTimestampsMilliseconds: (0..<120).map { Double($0) * 1_000 / 120 },
            sampleDurationMilliseconds: Double(119) * 1_000 / 120,
            cadenceP95Milliseconds: 9.2,
            handledSampleCount: 120,
            momentumSampleCount: 48,
            distinctOriginCount: 120,
            maximumAnchorStep: 1,
            maximumContinuityError: 0,
            processingP95Milliseconds: 2.5,
            scrollbarMaximumError: 0,
            topRubberBand: true,
            bottomRubberBand: true,
            edgesSettled: true,
            selectionPreserved: true,
            linkPreserved: true,
            semanticPromptPreserved: true,
            promptNavigationCoherent: true,
            keyboardPagingCoherent: true,
            accessibilityPagingCoherent: true,
            accessibilityActionsExposed: true,
            scrollerFramePreserved: true,
            alternateScreenPreserved: true,
            appMouseRoutingPreserved: true,
            liveBottomCoherent: true,
            viewIdentityPreserved: true,
            coordinatorIdentityPreserved: true,
            terminalEngineIdentityPreserved: true,
            finalFractionalViewport: true,
            fixtureUpdaterDisabled: true,
            fixtureBrokerIsolated: true,
            fixtureBuildNumber: 900_000_001,
            feedBuildFloor: 900_000_000,
            cursorBefore: 1_000,
            cursorAfter: 2_000,
            expectedCursorAfter: 2_000,
            finalMarkerPresent: true
        )

        XCTAssertNil(receipt.failure)
        let json = try XCTUnwrap(receipt.json)
        XCTAssertEqual(
            try JSONDecoder().decode(
                VisualTerminalContinuousScrollReceipt.self,
                from: Data(json.utf8)
            ),
            receipt
        )

        func mutated(_ key: String, to value: Any) throws -> VisualTerminalContinuousScrollReceipt {
            var object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            )
            object[key] = value
            return try JSONDecoder().decode(
                VisualTerminalContinuousScrollReceipt.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        XCTAssertEqual(
            try mutated("measuredHertz", to: 60).failure,
            "measured-cadence-out-of-range-60.0"
        )
        XCTAssertNil(try mutated("cadenceP95Milliseconds", to: 25).failure)
        XCTAssertEqual(
            try mutated("cadenceP95Milliseconds", to: 25.1).failure,
            "cadence-p95-out-of-range-25.1"
        )
        XCTAssertEqual(
            try mutated("maximumContinuityError", to: 0.5).failure,
            "continuity-error-0.5"
        )
        XCTAssertNil(try mutated("processingP95Milliseconds", to: 25).failure)
        XCTAssertEqual(
            try mutated("processingP95Milliseconds", to: 25.1).failure,
            "processing-over-budget-25.1"
        )
        XCTAssertEqual(
            try mutated("viewIdentityPreserved", to: false).failure,
            "view-identity-changed"
        )
        XCTAssertEqual(
            try mutated("fixtureUpdaterDisabled", to: false).failure,
            "fixture-updater-started"
        )
        XCTAssertEqual(
            try mutated("fixtureBrokerIsolated", to: false).failure,
            "fixture-broker-route-live"
        )
        XCTAssertEqual(
            try mutated("fixtureBuildNumber", to: receipt.feedBuildFloor).failure,
            "fixture-build-not-above-feed-900000000-900000000"
        )

        let debugReceipt = VisualTerminalContinuousScrollReceipt(
            optimizedBuild: false,
            scheduledHertz: receipt.scheduledHertz,
            measuredHertz: receipt.measuredHertz,
            sampleCount: receipt.sampleCount,
            sampleIntervalCount: receipt.sampleIntervalCount,
            sampleTimestampsMilliseconds: receipt.sampleTimestampsMilliseconds,
            sampleDurationMilliseconds: receipt.sampleDurationMilliseconds,
            cadenceP95Milliseconds: receipt.cadenceP95Milliseconds,
            handledSampleCount: receipt.handledSampleCount,
            momentumSampleCount: receipt.momentumSampleCount,
            distinctOriginCount: receipt.distinctOriginCount,
            maximumAnchorStep: receipt.maximumAnchorStep,
            maximumContinuityError: receipt.maximumContinuityError,
            processingP95Milliseconds: receipt.processingP95Milliseconds,
            scrollbarMaximumError: receipt.scrollbarMaximumError,
            topRubberBand: receipt.topRubberBand,
            bottomRubberBand: receipt.bottomRubberBand,
            edgesSettled: receipt.edgesSettled,
            selectionPreserved: receipt.selectionPreserved,
            linkPreserved: receipt.linkPreserved,
            semanticPromptPreserved: receipt.semanticPromptPreserved,
            promptNavigationCoherent: receipt.promptNavigationCoherent,
            keyboardPagingCoherent: receipt.keyboardPagingCoherent,
            accessibilityPagingCoherent: receipt.accessibilityPagingCoherent,
            accessibilityActionsExposed: receipt.accessibilityActionsExposed,
            scrollerFramePreserved: receipt.scrollerFramePreserved,
            alternateScreenPreserved: receipt.alternateScreenPreserved,
            appMouseRoutingPreserved: receipt.appMouseRoutingPreserved,
            liveBottomCoherent: receipt.liveBottomCoherent,
            viewIdentityPreserved: receipt.viewIdentityPreserved,
            coordinatorIdentityPreserved: receipt.coordinatorIdentityPreserved,
            terminalEngineIdentityPreserved: receipt.terminalEngineIdentityPreserved,
            finalFractionalViewport: receipt.finalFractionalViewport,
            fixtureUpdaterDisabled: receipt.fixtureUpdaterDisabled,
            fixtureBrokerIsolated: receipt.fixtureBrokerIsolated,
            fixtureBuildNumber: receipt.fixtureBuildNumber,
            feedBuildFloor: receipt.feedBuildFloor,
            cursorBefore: receipt.cursorBefore,
            cursorAfter: receipt.cursorAfter,
            expectedCursorAfter: receipt.expectedCursorAfter,
            finalMarkerPresent: receipt.finalMarkerPresent
        )
        XCTAssertEqual(debugReceipt.failure, "not-optimized")
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

    private func makeApplicationBundle(
        displayName: String,
        bundleIdentifier: String?
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-editor-app-\(UUID().uuidString)",
            isDirectory: true
        )
        let applicationURL = root.appendingPathComponent("Test Editor.app", isDirectory: true)
        let contents = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": "TestEditor",
            "CFBundlePackageType": "APPL",
        ]
        if let bundleIdentifier { info["CFBundleIdentifier"] = bundleIdentifier }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        let executable = executableDirectory.appendingPathComponent("TestEditor", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return applicationURL
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
        XCTAssertTrue(settings.workspaceRailVisible)
        XCTAssertEqual(settings.workspaceRailWidth, NativePreviewSettings.workspaceRailWidthDefault)
        XCTAssertEqual(settings.filePreviewWidth, NativePreviewSettings.filePreviewWidthDefault)
        XCTAssertEqual(settings.toolCallDensity, .balanced)
        XCTAssertEqual(settings.agentChatTextSize, .standard)
        XCTAssertFalse(settings.tintedBreathing)
        XCTAssertEqual(settings.tintPalette, .meadow)
        XCTAssertEqual(settings.tintIntensity, .standard)
        XCTAssertEqual(settings.projectRailWidth, NativePreviewSettings.projectRailWidthUnset)

        settings.navigationLayout = .topBar
        settings.appearance = .dark
        settings.sidebarAppearance = .solid
        settings.workspaceBackdrop = .tinted
        settings.tintedBreathing = true
        settings.tintPalette = .harbor
        settings.tintIntensity = .vivid
        settings.terminalThemeID = "kaisola"
        settings.restoreCLIDrafts = false
        settings.semanticShellIntegration = true
        settings.terminalLineSpacing = 1.18
        settings.workspaceRailWidth = 300
        settings.filePreviewWidth = 640
        settings.toolCallDensity = .detailed
        settings.agentChatTextSize = .extraLarge
        settings.projectRailWidth = 290.5

        let reloaded = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(reloaded.navigationLayout, .topBar)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertEqual(reloaded.sidebarAppearance, .solid)
        XCTAssertEqual(reloaded.workspaceBackdrop, .tinted)
        XCTAssertEqual(reloaded.terminalThemeID, "kaisola")
        XCTAssertFalse(reloaded.restoreCLIDrafts)
        XCTAssertTrue(reloaded.semanticShellIntegration)
        XCTAssertEqual(reloaded.terminalLineSpacing, 1.18, accuracy: 0.001)
        XCTAssertEqual(reloaded.workspaceRailWidth, 300)
        XCTAssertEqual(reloaded.filePreviewWidth, 640)
        XCTAssertEqual(reloaded.toolCallDensity, .detailed)
        XCTAssertEqual(reloaded.agentChatTextSize, .extraLarge)
        XCTAssertTrue(reloaded.tintedBreathing)
        XCTAssertEqual(reloaded.tintPalette, .harbor)
        XCTAssertEqual(reloaded.tintIntensity, .vivid)
        XCTAssertEqual(reloaded.projectRailWidth, 290.5)
    }

    func testTintPaletteRejectsUnknownPersistedValues() {
        let defaults = makeDefaults()
        defaults.set("chartreuse", forKey: "tintPalette")

        XCTAssertEqual(NativePreviewSettings(defaults: defaults).tintPalette, .meadow)
        XCTAssertEqual(TintPalette.allCases.map(\.title), [
            "Meadow", "Dusk", "Harbor", "Graphite", "Desktop",
        ])
        // Desktop is the only palette whose stops are not constants — it reads
        // as the escape hatch, so it stays last in the menu.
        XCTAssertEqual(TintPalette.allCases.last, .desktop)
    }

    func testToolCallDensityRejectsUnknownPersistedValues() {
        let defaults = makeDefaults()
        defaults.set("exhaustive", forKey: "toolCallDensity")

        XCTAssertEqual(NativePreviewSettings(defaults: defaults).toolCallDensity, .balanced)
        XCTAssertEqual(ToolCallDensity.allCases.map(\.title), [
            "Compact", "Balanced", "Detailed",
        ])
    }

    func testAgentChatTextSizeRejectsUnknownPersistedValues() {
        let defaults = makeDefaults()
        defaults.set("enormous", forKey: "agentChatTextSize")

        XCTAssertEqual(NativePreviewSettings(defaults: defaults).agentChatTextSize, .standard)
        XCTAssertEqual(AgentChatTextSize.allCases.map(\.title), ["85%", "100%", "130%", "170%"])
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

    /// GHSA-7p8r-x3mc-p8w7, applied to the provider boundary. A base URL is
    /// handed to a child process as text, so a spelling that `URLComponents` and
    /// a WHATWG parser read as different hosts would route API traffic somewhere
    /// the user never typed. The private-CA shape (internal name, own port) has
    /// to keep working.
    func testProviderRoutingRejectsAmbiguousAuthoritiesAndKeepsInternalHosts() {
        for ambiguous in [
            "https:\\\\evil.test/v1",
            "https:/\\evil.test/v1",
            "https:\\/evil.test/v1",
            "https://gateway.example.test\\@evil.test/v1",
            "https://gateway.example.test\\.evil.test/v1",
            "https://gateway.example.test%09.evil.test/v1",
        ] {
            XCTAssertEqual(
                ProviderRouting.baseURLIssue(ambiguous),
                "Enter a complete http:// or https:// URL.",
                "accepted \(ambiguous)"
            )
            XCTAssertNil(ProviderRouting.normalizedBaseURL(ambiguous))
        }
        XCTAssertEqual(
            ProviderRouting.normalizedBaseURL("https://gateway.internal.corp.test:8443/v1"),
            "https://gateway.internal.corp.test:8443/v1"
        )
        XCTAssertEqual(
            ProviderRouting.normalizedBaseURL("https://[::1]:8443/v1"),
            "https://[::1]:8443/v1"
        )
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

        // With the rail flush to the window edge (v0.1.125), the preview
        // stays inside the chrome card, so its corridor alone shifts inward
        // by the card's trailing gutter; the rail corridor is unmoved.
        let inset = NativeDetailPaneSizing.corridors(
            widths: widths,
            previewVisible: true,
            railVisible: true,
            trailingPanelInset: 6
        )
        XCTAssertEqual(inset[0].centerFromTrailing, 218.5, accuracy: 0.001)
        XCTAssertEqual(inset[1].centerFromTrailing, 705.5, accuracy: 0.001)
        let insetPreviewOnly = NativeDetailPaneSizing.corridors(
            widths: NativeDetailPaneSizing.Widths(preview: 480, rail: 0),
            previewVisible: true,
            railVisible: false,
            trailingPanelInset: 6
        )
        XCTAssertEqual(insetPreviewOnly[0].centerFromTrailing, 486.5, accuracy: 0.001)
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

    /// Light Glass deliberately separates the center from the rails: the
    /// workspace stays the brightest, white-led surface, but the desktop must
    /// arrive there too. The opaque carrier era (carrier 1.0, canvas modeled
    /// at exactly 1) made Glass indistinguishable from the white Solid across
    /// the whole center of the window — "make sure they're actually
    /// translucent" (2026-08-14) is the contract now.
    func testLightGlassCanvasIsBrightButTranslucent() {
        let canvas = GlassBackdropWash.workspace(isDark: false)
        let canvasLuminance = LightGlassFrost.modeledBackdropLuminance(canvas)

        XCTAssertEqual(
            DesktopBackdropRenderer.targetLuminance(isDark: false),
            LightGlassFrost.backdropLuminance,
            accuracy: 0.0001
        )
        XCTAssertGreaterThanOrEqual(
            canvasLuminance,
            0.93,
            "the canvas stopped white-leading the window"
        )
        XCTAssertLessThan(
            canvasLuminance,
            0.99,
            "the workspace canvas collapsed back into exact white"
        )
        XCTAssertLessThanOrEqual(
            LightGlassFrost.carrierWhiteCoverage,
            0.60,
            "an opaque carrier shuts the desktop out of the canvas entirely"
        )
        XCTAssertGreaterThanOrEqual(
            (1 - LightGlassFrost.carrierWhiteCoverage) * canvas.desktopTransmission,
            0.25,
            "less than a quarter of the normalized desktop reaches the canvas"
        )

        // The detail panel is the last layer over the canvas. Its white frost
        // must be visible but must not become an opaque white card.
        XCTAssertGreaterThanOrEqual(LightGlassFrost.panelWhiteCoverage, 0.35)
        XCTAssertLessThan(LightGlassFrost.panelWhiteCoverage, 0.50)
        XCTAssertGreaterThanOrEqual(
            LightGlassFrost.panelDesktopTransmission,
            0.50,
            "the inset panel became an opaque white card"
        )

        // One theme choice moves both surface families together. The RHS file
        // rail consumes `SidebarBackdropView` just like the LHS project rail.
        XCTAssertEqual(KaisolaTheme.glass.sidebarAppearance, .glass)
        XCTAssertEqual(KaisolaTheme.glass.workspaceBackdrop, .glass)
    }

    /// The placement points survive the `LightRailTint` removal because the
    /// Tinted theme still mirrors its sweep per rail; the glass rails
    /// themselves now carry no app-added chroma at all — white frost, black
    /// frost, and whatever the desktop contributes through the material.
    func testRailPlacementMirrorsTintSweepAtWindowEdges() {
        XCTAssertEqual(SidebarRailPlacement.leading.tintStartPoint, .topLeading)
        XCTAssertEqual(SidebarRailPlacement.leading.tintEndPoint, .bottomTrailing)
        XCTAssertEqual(SidebarRailPlacement.trailing.tintStartPoint, .topTrailing)
        XCTAssertEqual(SidebarRailPlacement.trailing.tintEndPoint, .bottomLeading)
    }

    func testGlassRailsDeclareNearlyHalfWhiteAndStillExposeTheDesktop() {
        let rail = GlassBackdropWash.sidebar(isDark: false)
        let canvas = GlassBackdropWash.workspace(isDark: false)
        let declaredWhiteCoverage = 1
            - (1 - LightGlassFrost.railCarrierWhiteCoverage) * (1 - rail.baseOpacity)

        // Twelve percent read gray, thirty still read gray beside the canvas
        // (the third round of the same report); forty-six is where the rail
        // finally reads white-led, and the desktop keeps a majority share of
        // the composite.
        XCTAssertGreaterThanOrEqual(declaredWhiteCoverage, 0.42)
        XCTAssertLessThanOrEqual(
            declaredWhiteCoverage,
            0.50,
            "past half white the shared rail material stops reading as glass at all"
        )
        XCTAssertLessThanOrEqual(
            LightGlassFrost.railCarrierWhiteCoverage,
            0.02,
            "a second white carrier is stacking on top of the rail veil"
        )
        XCTAssertGreaterThanOrEqual(
            LightGlassFrost.modeledRailDesktopContribution(rail),
            0.50,
            "Glass still paints over most of the wallpaper"
        )
        XCTAssertGreaterThanOrEqual(
            LightGlassFrost.modeledBackdropLuminance(canvas),
            0.93,
            "the separate workspace canvas must stay the brighter surface"
        )
        XCTAssertLessThan(
            LightGlassFrost.modeledBackdropLuminance(canvas),
            0.99,
            "the workspace canvas collapsed back into exact white"
        )
    }

    func testEveryTintPaletteIsATwoEndedPastelCrossing() {
        for palette in TintPalette.allCases {
            // Constant palettes ignore the sample; `.desktop` resolves
            // against a saturated blue, its historical failure input.
            let light = palette.light(
                desktop: DesktopTintComponents(red: 0.1, green: 0.3, blue: 0.9)
            )

            // Eleven-percent stops quantized to within a few counts of white
            // and Tinted rendered pixel-identical to Glass. "A flowing
            // gradient tint" (2026-08-14) needs stops one can actually see;
            // the ceiling keeps the sources pastel rather than letting the
            // sweep become a poster.
            let maximumCoverage = max(
                light.coolCoverage,
                max(light.neutralCoverage, light.pearlCoverage)
            )
            XCTAssertGreaterThanOrEqual(
                maximumCoverage, 0.22,
                "\(palette.title): the light tint disappeared"
            )
            XCTAssertLessThanOrEqual(
                maximumCoverage, 0.34,
                "\(palette.title): the light tint is no longer pastel"
            )
            XCTAssertGreaterThanOrEqual(
                light.neutralCoverage, 0.18,
                "\(palette.title): the midpoint falls back to an exact-white band"
            )
            XCTAssertLessThanOrEqual(light.neutralCoverage, 0.26, palette.title)
            XCTAssertGreaterThan(light.neutralLocation, 0.35, palette.title)
            XCTAssertLessThan(light.neutralLocation, 0.70, palette.title)

            // The two coloured ends genuinely cross rather than washing the
            // whole surface in one hue.
            if palette == .graphite {
                // Achromatic on purpose: at spread this small a hue distance
                // means nothing, so the crossing is the reversed channel
                // ordering — cool is blue-led, pearl is red-led.
                XCTAssertGreaterThan(light.cool.blue, light.cool.red, palette.title)
                XCTAssertGreaterThan(light.pearl.red, light.pearl.blue, palette.title)
            } else {
                guard
                    let coolHue = TintFlowMotion.hue(
                        red: light.cool.red, green: light.cool.green, blue: light.cool.blue
                    ),
                    let pearlHue = TintFlowMotion.hue(
                        red: light.pearl.red, green: light.pearl.green, blue: light.pearl.blue
                    )
                else {
                    XCTFail("\(palette.title): a coloured end has no hue")
                    continue
                }
                let distance = abs(coolHue - pearlHue)
                XCTAssertGreaterThanOrEqual(
                    min(distance, 1 - distance), 0.03,
                    "\(palette.title): the sweep is one hue and reads as a wash"
                )
            }
        }

        // The shipped composition stays pinned exactly: Meadow is a gentle
        // sage crossing a lilac pearl through a warm midpoint, and the tinted
        // fixture baseline depends on these numbers byte for byte.
        guard let meadow = TintPalette.meadow.fixedLight else {
            return XCTFail("Meadow lost its fixed light table")
        }
        XCTAssertGreaterThan(meadow.cool.green, meadow.cool.blue)
        XCTAssertGreaterThan(meadow.cool.blue, meadow.cool.red)
        XCTAssertLessThanOrEqual(meadow.cool.green - meadow.cool.red, 0.18)
        XCTAssertGreaterThan(meadow.pearl.blue, meadow.pearl.red)
        XCTAssertGreaterThan(meadow.pearl.red, meadow.pearl.green)
        XCTAssertLessThanOrEqual(meadow.pearl.blue - meadow.pearl.green, 0.18)
        XCTAssertGreaterThan(meadow.neutral.red, meadow.neutral.green)
        XCTAssertGreaterThan(meadow.neutral.green, meadow.neutral.blue)
        XCTAssertEqual(meadow, TintPaletteLight(
            cool: TintRGB(165, 203, 178),
            neutral: TintRGB(233, 221, 207),
            pearl: TintRGB(203, 185, 226),
            coolCoverage: 0.30, neutralCoverage: 0.22, pearlCoverage: 0.30,
            neutralLocation: 0.54
        ))
    }

    func testLightTintedStopsRemainVisibleAfterCompositingOverWhite() {
        func composite(_ colour: TintRGB, coverage: Double) -> [Double] {
            [colour.red, colour.green, colour.blue].map {
                (1 - coverage + $0 * coverage) * 255
            }
        }

        func metrics(_ channels: [Double]) -> (departure: Double, spread: Double) {
            let maximum = channels.max() ?? 255
            let minimum = channels.min() ?? 255
            return (departure: 255 - minimum, spread: maximum - minimum)
        }

        // `.desktop` has no fixed stops and must hold the box for any
        // wallpaper, so it is asserted against a saturated blue and a
        // saturated red. Its grey fallback resolves to exactly Graphite
        // (asserted in the clamp test below), whose own row covers that box.
        let desktopSamples = [
            DesktopTintComponents(red: 0.05, green: 0.20, blue: 0.95),
            DesktopTintComponents(red: 0.95, green: 0.10, blue: 0.10),
        ]

        for palette in TintPalette.allCases {
            // A palette may quiet its spread floor, never abandon it.
            XCTAssertGreaterThan(palette.minimumCanvasSpread, 0, palette.title)

            let lights: [TintPaletteLight]
            if let fixed = palette.fixedLight {
                lights = [fixed]
            } else {
                lights = desktopSamples.map { palette.light(desktop: $0) }
            }
            for light in lights {
                let colouredStops: [(name: String, colour: TintRGB, coverage: Double)] = [
                    ("\(palette.title) cool", light.cool, light.coolCoverage),
                    ("\(palette.title) pearl", light.pearl, light.pearlCoverage),
                ]
                for stop in colouredStops {
                    let canvas = metrics(composite(stop.colour, coverage: stop.coverage))
                    XCTAssertGreaterThanOrEqual(
                        canvas.departure,
                        18,
                        "\(stop.name) composites to near-white and disappears on the canvas"
                    )
                    XCTAssertLessThanOrEqual(canvas.departure, 34, "\(stop.name) is no longer pastel")
                    XCTAssertGreaterThanOrEqual(
                        canvas.spread,
                        palette.minimumCanvasSpread,
                        "\(stop.name) has too little channel separation to read as a tint"
                    )
                    XCTAssertLessThanOrEqual(canvas.spread, 16, "\(stop.name) is too saturated")

                    let rail = metrics(composite(
                        stop.colour,
                        coverage: stop.coverage * SidebarBackdropView.railTintShare
                    ))
                    XCTAssertGreaterThanOrEqual(
                        rail.departure,
                        16,
                        "\(stop.name) disappears after the rail's coverage scaling"
                    )
                    XCTAssertLessThanOrEqual(rail.departure, 31, "\(stop.name) is too heavy on the rail")
                    XCTAssertGreaterThanOrEqual(
                        rail.spread,
                        palette.minimumCanvasSpread * 0.875,
                        "\(stop.name) rail is effectively neutral"
                    )
                    XCTAssertLessThanOrEqual(rail.spread, 15, "\(stop.name) rail is too saturated")
                }

                let neutral = metrics(composite(light.neutral, coverage: light.neutralCoverage))
                XCTAssertGreaterThanOrEqual(
                    neutral.departure,
                    8,
                    "\(palette.title): the midpoint still disappears into the white canvas"
                )
                XCTAssertLessThanOrEqual(
                    neutral.departure, 16,
                    "\(palette.title): the midpoint is too heavy"
                )
                XCTAssertGreaterThanOrEqual(
                    neutral.spread,
                    palette.minimumCanvasSpread * 0.5,
                    "\(palette.title): the midpoint is effectively neutral"
                )
                XCTAssertLessThanOrEqual(
                    neutral.spread, 9,
                    "\(palette.title): the midpoint is too saturated"
                )
            }
        }
    }

    func testDesktopPaletteClampsEveryWallpaperHueIntoThePastelBox() {
        func composite(_ colour: TintRGB, coverage: Double) -> [Double] {
            [colour.red, colour.green, colour.blue].map {
                (1 - coverage + $0 * coverage) * 255
            }
        }

        func metrics(_ channels: [Double]) -> (departure: Double, spread: Double) {
            let maximum = channels.max() ?? 255
            let minimum = channels.min() ?? 255
            return (departure: 255 - minimum, spread: maximum - minimum)
        }

        // The clamp fixes saturation and brightness and keeps only the hue,
        // so the box metrics are the same constants for *every* wallpaper —
        // which is the whole reason light is finally allowed to sample it.
        for degrees in 0..<360 {
            let source = TintFlowMotion.rgb(
                hue: Double(degrees) / 360,
                saturation: 1,
                brightness: 1
            )
            let light = TintPalette.desktop.light(desktop: DesktopTintComponents(
                red: source.red, green: source.green, blue: source.blue
            ))
            for (colour, coverage) in [
                (light.cool, light.coolCoverage),
                (light.pearl, light.pearlCoverage),
            ] {
                let canvas = metrics(composite(colour, coverage: coverage))
                XCTAssertEqual(canvas.departure, 28.8, accuracy: 1.0, "hue \(degrees)°")
                XCTAssertEqual(canvas.spread, 13.5, accuracy: 1.0, "hue \(degrees)°")
            }
            let neutral = metrics(composite(light.neutral, coverage: light.neutralCoverage))
            XCTAssertEqual(neutral.departure, 10.7, accuracy: 1.0, "hue \(degrees)°")
            XCTAssertEqual(neutral.spread, 5.0, accuracy: 1.0, "hue \(degrees)°")
        }

        // A grey wallpaper has no hue to keep: Graphite is what "no hue,
        // pastel" already means, so the sampler's fallback resolves to it
        // exactly rather than to a near-white nothing.
        XCTAssertEqual(
            TintPalette.desktop.light(desktop: DesktopTintSampler.fallback),
            TintPalette.graphite.fixedLight
        )
    }

    func testEveryPaletteHasADarkCounterpartAtTheCanvasPeak() {
        let peak = DesktopTintSampler.canvasTintPeak(isDark: true)
        for palette in TintPalette.allCases where palette != .desktop {
            guard let ends = palette.darkEnds(), let light = palette.fixedLight else {
                XCTFail("\(palette.title) lost its dark pair")
                continue
            }
            // Both ends sit exactly at the dark canvas peak, so the dark
            // surface's luminance envelope — and the dark ink ladder measured
            // against it — does not move with the palette.
            XCTAssertEqual(ends.anchor.maximumChannel, peak, accuracy: 0.0001, palette.title)
            XCTAssertEqual(ends.companion.maximumChannel, peak, accuracy: 0.0001, palette.title)

            let separation = abs(ends.anchor.red - ends.companion.red)
                + abs(ends.anchor.green - ends.companion.green)
                + abs(ends.anchor.blue - ends.companion.blue)
            XCTAssertGreaterThanOrEqual(
                separation, 0.05,
                "\(palette.title): both dark ends carry the same colour, so nothing visibly flows"
            )

            // Hue family preserved: the dark anchor leads with the same
            // channel its light cool does, so a dark Harbor is still Harbor.
            func dominant(_ colour: TintRGB) -> Int {
                if colour.red >= colour.green && colour.red >= colour.blue { return 0 }
                return colour.green >= colour.blue ? 1 : 2
            }
            XCTAssertEqual(
                dominant(ends.anchor),
                dominant(light.cool),
                "\(palette.title): dark lost its light hue family"
            )
        }

        // `.desktop` alone keeps the sampled dark path; its composition is
        // pinned in `testTintFlowMotionIsGlacialAndItsCompanionKeepsTheSampledFamily`.
        XCTAssertNil(TintPalette.desktop.darkEnds())
    }

    func testCompositionsUseTheSelectedPaletteAndKeepTheirShape() {
        let desktop = DesktopTintComponents(red: 0.3, green: 0.5, blue: 0.7)

        for palette in TintPalette.allCases {
            let light = TintFlowComposition.light(
                palette: palette,
                desktop: desktop,
                coverageScale: 0.5
            )
            let declared = palette.light(desktop: desktop)
            XCTAssertEqual(light.map(\.location), [0, declared.neutralLocation, 1], palette.title)
            XCTAssertEqual(light[0].opacity, declared.coolCoverage * 0.5, accuracy: 0.0001, palette.title)
            XCTAssertEqual(light[1].opacity, declared.neutralCoverage * 0.5, accuracy: 0.0001, palette.title)
            XCTAssertEqual(light[2].opacity, declared.pearlCoverage * 0.5, accuracy: 0.0001, palette.title)

            let dark = TintFlowComposition.dark(palette: palette, tint: desktop, coverageScale: 1)
            XCTAssertEqual(dark.map(\.location), [0, 1], palette.title)
            let coverage = DesktopTintSampler.canvasTintCoverage(isDark: true)
            XCTAssertEqual(dark[0].opacity, coverage.top, accuracy: 0.0001, palette.title)
            XCTAssertEqual(dark[1].opacity, coverage.bottom, accuracy: 0.0001, palette.title)
        }

        let meadow = TintFlowComposition.light(palette: .meadow, desktop: desktop, coverageScale: 1)
        let dusk = TintFlowComposition.light(palette: .dusk, desktop: desktop, coverageScale: 1)
        XCTAssertNotEqual(meadow, dusk, "choosing a palette changed nothing on the surface")
    }

    /// Intensity is a user choice layered at composition time, never a
    /// different palette: the definitions stay inside the pastel box the
    /// tests above pin, and every rung is a real, bounded step up from the
    /// shipped voice.
    func testTintIntensityLaddersUpFromTheShippedVoice() {
        XCTAssertEqual(TintIntensity.standard.coverageMultiplier, 1)
        XCTAssertEqual(TintIntensity.standard.breathDepthMultiplier, 1)
        let coverages = TintIntensity.allCases.map(\.coverageMultiplier)
        XCTAssertEqual(coverages, coverages.sorted())
        XCTAssertEqual(Set(coverages).count, coverages.count, "a rung that changes nothing is not a rung")
        let depths = TintIntensity.allCases.map(\.breathDepthMultiplier)
        XCTAssertEqual(depths, depths.sorted())
        XCTAssertEqual(Set(depths).count, depths.count)
        let heaviestStop = TintPalette.allCases
            .compactMap(\.fixedLight)
            .map { max($0.coolCoverage, max($0.neutralCoverage, $0.pearlCoverage)) }
            .max() ?? 0
        for intensity in TintIntensity.allCases {
            XCTAssertLessThanOrEqual(
                heaviestStop * intensity.coverageMultiplier, 0.6,
                "even Bold stays a translucent tint over the material ground, never a plate"
            )
            XCTAssertLessThanOrEqual(
                TintFlowMotion.breathAmplitude * intensity.breathDepthMultiplier, 0.24,
                """
                the deepest chosen breath tops out at 0.24 — past the Standard \
                voice's 0.20 resting line by deliberate user choice (see \
                testTintBreathIsSlowShallowAndNotAHarmonicOfTheDrift), still \
                nowhere near a strobe
                """
            )
        }
    }

    /// The composition multiplies intensity linearly and saturates per stop:
    /// no scale, however absurd, can ask a gradient stop to paint past full
    /// coverage.
    func testCompositionsScaleWithIntensityAndSaturatePerStop() {
        let desktop = DesktopTintSampler.fallback
        let base = TintFlowComposition.light(palette: .meadow, desktop: desktop, coverageScale: 1)
        let vivid = TintFlowComposition.light(
            palette: .meadow,
            desktop: desktop,
            coverageScale: TintIntensity.vivid.coverageMultiplier
        )
        for (baseStop, vividStop) in zip(base, vivid) {
            XCTAssertEqual(
                vividStop.opacity,
                baseStop.opacity * TintIntensity.vivid.coverageMultiplier,
                accuracy: 0.0001
            )
            XCTAssertEqual(vividStop.location, baseStop.location)
        }
        let saturatedLight = TintFlowComposition.light(palette: .meadow, desktop: desktop, coverageScale: 50)
        for stop in saturatedLight {
            XCTAssertEqual(stop.opacity, 1)
        }
        // Dark refuses the plate outright: its baseline coverage is nearly
        // double light's, so the composition caps the scale where the
        // heaviest stop would stop transmitting, whatever the multiplier.
        let boldDark = TintFlowComposition.dark(
            palette: .meadow,
            tint: desktop,
            coverageScale: TintIntensity.bold.coverageMultiplier
        )
        let saturatedDark = TintFlowComposition.dark(palette: .meadow, tint: desktop, coverageScale: 50)
        for stops in [boldDark, saturatedDark] {
            let heaviest = stops.map(\.opacity).max() ?? 0
            XCTAssertLessThanOrEqual(heaviest, TintFlowComposition.maximumDarkStopCoverage + 0.0001)
            XCTAssertGreaterThan(
                stops[0].opacity, stops[1].opacity,
                "the capped sweep still reads as light from above, not a washed band"
            )
        }
        XCTAssertEqual(
            saturatedDark.map(\.opacity),
            boldDark.map(\.opacity),
            "past the cap, more scale changes nothing — the ceiling is the ceiling"
        )
    }

    /// The Tinted drift is glacial, bounded, and purely geometric — and the
    /// dark companion is the sampled hue rotated, never a second accent.
    /// The opt-in breath must stay as quiet as the drift it joins: slow,
    /// shallow, and never phase-locked with the endpoint period into a
    /// visible pulse.
    func testTintBreathIsSlowShallowAndNotAHarmonicOfTheDrift() {
        XCTAssertGreaterThanOrEqual(TintFlowMotion.breathPeriod, 12)
        XCTAssertGreaterThan(
            TintFlowMotion.breathAmplitude, 0.10,
            "under a tenth of opacity the breath was never once seen — 0.08 shipped and read as off"
        )
        XCTAssertLessThanOrEqual(
            TintFlowMotion.breathAmplitude, 0.20,
            """
            over a fifth the breath is a pulse, not a breath — this bounds \
            the resting Standard voice; a chosen TintIntensity may deepen the \
            effective swing to 0.24, and that ceiling lives in \
            testTintIntensityLaddersUpFromTheShippedVoice
            """
        )
        XCTAssertEqual(
            TintFlowMotion.breathFloorOpacity,
            1 - TintFlowMotion.breathAmplitude,
            accuracy: 0.0001
        )

        // No pair of the three periods — drift, opacity breath, scale swell —
        // may sit near an integer ratio, or two of them phase-lock into a
        // visible metronome.
        let ratios: [(String, Double)] = [
            ("drift/breath", TintFlowMotion.period / TintFlowMotion.breathPeriod),
            ("drift/swell", TintFlowMotion.period / TintFlowMotion.breathScalePeriod),
            ("swell/breath", TintFlowMotion.breathScalePeriod / TintFlowMotion.breathPeriod),
        ]
        for (name, ratio) in ratios {
            XCTAssertGreaterThan(
                abs(ratio - ratio.rounded()), 0.05,
                "an integer \(name) period ratio phase-locks into a visible pulse"
            )
        }

        // The swell must only ever grow — a scale below 1 would uncover the
        // layer's own edge — and stays a few percent: enough to read as a
        // living surface, never as watchable motion.
        XCTAssertGreaterThan(TintFlowMotion.breathScaleAmplitude, 0.01)
        XCTAssertLessThanOrEqual(TintFlowMotion.breathScaleAmplitude, 0.035)

        // The dimmest breath phase multiplies every stop's coverage; even the
        // heaviest stop of every palette stays far above the point where
        // Tinted could quantize back into Glass or Solid.
        for palette in TintPalette.allCases {
            let light = palette.light(desktop: DesktopTintSampler.fallback)
            let heaviest = max(
                light.coolCoverage,
                max(light.neutralCoverage, light.pearlCoverage)
            )
            XCTAssertGreaterThan(
                heaviest * TintFlowMotion.breathFloorOpacity, 0.20, palette.title
            )
        }

        // The timing curve is a valid monotone S — both control points inside
        // the unit square, the second genuinely to the right of the first —
        // not a linear ramp and not an overshoot.
        let points = TintFlowMotion.breathTimingControlPoints
        for x in [points.0, points.1, points.2, points.3] {
            XCTAssertGreaterThanOrEqual(x, 0)
            XCTAssertLessThanOrEqual(x, 1)
        }
        XCTAssertLessThan(points.0, points.2, "the ease collapsed into a ramp")
    }

    func testTintFlowMotionIsGlacialAndItsCompanionKeepsTheSampledFamily() {
        XCTAssertGreaterThanOrEqual(TintFlowMotion.period, 20, "the flow became watchable motion")
        XCTAssertGreaterThan(TintFlowMotion.drift, 0.05, "the drift is too small to ever notice")
        XCTAssertLessThanOrEqual(TintFlowMotion.drift, 0.25, "the drift swings the whole sweep")

        // SwiftUI's top-leading (0,0) must land at the layer's top — which an
        // unflipped AppKit host addresses as y = 1. This is the conversion
        // whose absence rendered the first build's sweep upside down.
        XCTAssertEqual(TintFlowMotion.layerPoint(.topLeading), CGPoint(x: 0, y: 1))
        XCTAssertEqual(TintFlowMotion.layerPoint(.bottomTrailing), CGPoint(x: 1, y: 0))
        XCTAssertEqual(TintFlowMotion.layerPoint(.topTrailing), CGPoint(x: 1, y: 1))

        let travel = TintFlowMotion.endpoints(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 1, y: 1)
        )
        XCTAssertEqual(travel.startFrom, CGPoint(x: 0, y: 0))
        XCTAssertEqual(travel.startTo.x, TintFlowMotion.drift, accuracy: 0.0001)
        XCTAssertEqual(travel.endTo, CGPoint(x: 1, y: 1))
        XCTAssertEqual(travel.endFrom.x, 1 - TintFlowMotion.drift, accuracy: 0.0001)

        // A saturated blue rotates toward violet: hue moves, peak brightness
        // stays, so the companion is exactly as quiet as its source.
        let companion = TintFlowMotion.companion(red: 0.10, green: 0.35, blue: 0.60)
        XCTAssertEqual(
            max(companion.red, max(companion.green, companion.blue)),
            0.60,
            accuracy: 0.0001,
            "rotation changed the companion's brightness"
        )
        XCTAssertGreaterThan(
            abs(companion.green - 0.35) + abs(companion.red - 0.10),
            0.02,
            "the companion did not actually rotate away from the sampled hue"
        )
        // A grey sample has no hue to rotate and must come back unchanged.
        let grey = TintFlowMotion.companion(red: 0.5, green: 0.5, blue: 0.5)
        XCTAssertEqual(grey.red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(grey.green, 0.5, accuracy: 0.0001)
        XCTAssertEqual(grey.blue, 0.5, accuracy: 0.0001)

        // The composed stop lists stay ordered and inside declared coverage.
        let light = TintFlowComposition.light(
            palette: .meadow,
            desktop: DesktopTintSampler.fallback,
            coverageScale: 1
        )
        XCTAssertEqual(light.map(\.location), [0, LightTintedGradient.neutralLocation, 1])
        XCTAssertEqual(light[0].opacity, LightTintedGradient.coolCoverage, accuracy: 0.0001)
        XCTAssertEqual(light[2].opacity, LightTintedGradient.pearlCoverage, accuracy: 0.0001)

        let sampled = DesktopTintComponents(red: 0.2, green: 0.4, blue: 0.8)
        let dark = TintFlowComposition.dark(palette: .desktop, tint: sampled, coverageScale: 1)
        // Two stops, sampled anchor to rotated companion: a mid-stop of the
        // anchor's own colour flattened the crossing into a single-hue wash.
        XCTAssertEqual(dark.count, 2)
        XCTAssertEqual(dark.map(\.location), [0, 1])
        let darkCoverage = DesktopTintSampler.canvasTintCoverage(isDark: true)
        XCTAssertEqual(dark[0].opacity, darkCoverage.top, accuracy: 0.0001)
        XCTAssertEqual(dark[1].opacity, darkCoverage.bottom, accuracy: 0.0001)
        let revalued = DesktopTintSampler.revalued(
            sampled,
            peak: DesktopTintSampler.canvasTintPeak(isDark: true)
        )
        XCTAssertEqual(dark[0].red, revalued.red, accuracy: 0.0001)
        XCTAssertEqual(dark[0].green, revalued.green, accuracy: 0.0001)
        XCTAssertEqual(dark[0].blue, revalued.blue, accuracy: 0.0001)
        let anchorEnd = TintFlowMotion.companion(
            red: revalued.red,
            green: revalued.green,
            blue: revalued.blue
        )
        XCTAssertEqual(dark[1].red, anchorEnd.red, accuracy: 0.0001)
        XCTAssertEqual(dark[1].green, anchorEnd.green, accuracy: 0.0001)
        XCTAssertEqual(dark[1].blue, anchorEnd.blue, accuracy: 0.0001)
        XCTAssertGreaterThan(
            abs(dark[1].red - dark[0].red) + abs(dark[1].green - dark[0].green)
                + abs(dark[1].blue - dark[0].blue),
            0.01,
            "both ends carry the same colour, so nothing visibly flows"
        )
    }

    /// The transcript's rhythm pair table: a turn boundary is a larger event
    /// than the next artifact inside the same reply, a run of work rows is a
    /// tighter event than either, and the opening row leaves the top edge to
    /// the page padding.
    func testTranscriptRhythmSeparatesTurnsMoreThanArtifacts() {
        XCTAssertGreaterThan(
            AcpTranscriptMetrics.turnSpacing,
            AcpTranscriptMetrics.intraTurnSpacing
        )
        XCTAssertGreaterThan(
            AcpTranscriptMetrics.intraTurnSpacing,
            AcpTranscriptMetrics.workRunSpacing
        )
        XCTAssertEqual(AcpTranscriptMetrics.spacing(before: nil, after: .user), 0)
        XCTAssertEqual(AcpTranscriptMetrics.spacing(before: nil, after: .assistant), 0)
        XCTAssertEqual(AcpTranscriptMetrics.spacing(before: nil, after: .work), 0)
        XCTAssertEqual(
            AcpTranscriptMetrics.spacing(before: .user, after: .assistant),
            AcpTranscriptMetrics.turnSpacing
        )
        XCTAssertEqual(
            AcpTranscriptMetrics.spacing(before: .assistant, after: .user),
            AcpTranscriptMetrics.turnSpacing
        )
        XCTAssertEqual(
            AcpTranscriptMetrics.spacing(before: .work, after: .user),
            AcpTranscriptMetrics.turnSpacing
        )
        XCTAssertEqual(
            AcpTranscriptMetrics.spacing(before: .user, after: .work),
            AcpTranscriptMetrics.turnSpacing
        )
        XCTAssertEqual(
            AcpTranscriptMetrics.spacing(before: .user, after: .user),
            AcpTranscriptMetrics.turnSpacing
        )
        XCTAssertEqual(
            AcpTranscriptMetrics.spacing(before: .assistant, after: .assistant),
            AcpTranscriptMetrics.intraTurnSpacing
        )
        // Work beside prose keeps the artifact gap; only work beside work
        // tightens into a run, so a tool log reads as one block between
        // paragraphs rather than a stack of separated cards.
        XCTAssertEqual(
            AcpTranscriptMetrics.spacing(before: .assistant, after: .work),
            AcpTranscriptMetrics.intraTurnSpacing
        )
        XCTAssertEqual(
            AcpTranscriptMetrics.spacing(before: .work, after: .assistant),
            AcpTranscriptMetrics.intraTurnSpacing
        )
        XCTAssertEqual(
            AcpTranscriptMetrics.spacing(before: .work, after: .work),
            AcpTranscriptMetrics.workRunSpacing
        )
        // Only the user's own rows sit on the user side of the table, and the
        // rhythm's work voice matches the "Agent work" section exactly.
        XCTAssertEqual(AcpTranscriptRow.user(id: "1", text: "go", failed: false).rhythmKind, .user)
        XCTAssertEqual(AcpTranscriptRow.message(id: "1", text: "on it").rhythmKind, .assistant)
        XCTAssertEqual(AcpTranscriptRow.thought(id: "1", text: "…").rhythmKind, .work)
        XCTAssertEqual(
            AcpTranscriptRow.tool(AcpToolCall(
                id: "t", title: "Build", kind: "execute", status: .completed
            )).rhythmKind,
            .work
        )
    }

    func testSurfaceTabOutlinesAreVisibleButRemainHairlines() {
        XCTAssertEqual(SurfaceTabChrome.projectSelectedStrokeOpacity, 0.38, accuracy: 0.0001)
        XCTAssertEqual(SurfaceTabChrome.sessionSelectedStrokeOpacity, 0.30, accuracy: 0.0001)
        XCTAssertEqual(SurfaceTabChrome.inactiveStrokeOpacity, 0.11, accuracy: 0.0001)
        XCTAssertEqual(KaisolaVisualSystem.hairline, 0.5)
    }

    /// Live vibrancy cannot be pixel-tested offline because its input is the
    /// actual desktop behind the test window. Its deterministic choices can be:
    /// the rail keeps the sampled RGB ratios and leaves vibrancy saturation on;
    /// the exact-white canvas is supplied by its separate opaque carrier.
    func testLiveLightGlassPreservesDesktopChromaInTheRails() {
        XCTAssertEqual(
            DesktopGlassLayer.resolvedLiveMaterial(.sidebar, isDark: false),
            .sidebar
        )
        XCTAssertEqual(
            DesktopGlassLayer.resolvedLiveMaterial(.underWindowBackground, isDark: false),
            .sidebar,
            "the light canvas is using a greyer material than the rails"
        )
        XCTAssertEqual(
            DesktopGlassLayer.resolvedLiveMaterial(.underWindowBackground, isDark: true),
            .underWindowBackground,
            "the light-only correction changed dark glass"
        )

        let sampled = DesktopTintComponents(red: 0.3152, green: 0.4646, blue: 0.5343)
        let light = DesktopGlassLayer.resolvedLiveTint(sampled, isDark: false)
        XCTAssertEqual(light, sampled, "light Glass is replacing the live desktop hue with white")
        XCTAssertEqual(NativeVisualEffectView.resolvedSaturation(neutralizesChroma: false), 1)
        XCTAssertTrue(
            DesktopGlassLayer.appliesSampledLiveTint(isDark: false),
            "light Glass still opts into chroma neutralization"
        )
        XCTAssertTrue(DesktopGlassLayer.appliesSampledLiveTint(isDark: true))
        XCTAssertEqual(DesktopGlassLayer.resolvedLiveTint(sampled, isDark: true), sampled)

        let fallback = DesktopGlassLayer.flatTintCoverage(isDark: false)
        XCTAssertEqual(fallback.top, 0)
        XCTAssertEqual(fallback.bottom, 0)
        XCTAssertEqual(DesktopGlassLayer.flatTintCoverage(isDark: true).top, 0.42)

        for requested in [GlassColour.muted, .balanced, .vivid].map(\.chromaScale) {
            XCTAssertEqual(
                DesktopBackdropRenderer.resolvedGlassChromaScale(requested, isDark: false),
                0,
                "a painted light wallpaper can reintroduce a colour cast"
            )
            XCTAssertEqual(
                DesktopBackdropRenderer.resolvedGlassChromaScale(requested, isDark: true),
                requested,
                "the light-only correction changed dark Glass"
            )
        }
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
        // Light rails now use one white veil centered on forty-six percent —
        // twelve and then thirty both read gray next to the canvas. There is
        // still no second carrier stacked beneath it; the exact white
        // workspace has its own opaque recipe.
        let lightSidebar = GlassBackdropWash.sidebar(isDark: false)
        XCTAssertEqual(lightSidebar.topOpacity, 0.50, accuracy: 0.0001)
        XCTAssertEqual(lightSidebar.baseOpacity, 0.46, accuracy: 0.0001)
        XCTAssertEqual(lightSidebar.bottomOpacity, 0.42, accuracy: 0.0001)
        // 0.40 → 0.38 with the 2026-08-14 carrier drop, so the canvas stays
        // white-led while a third of the normalized desktop reaches it.
        XCTAssertEqual(GlassBackdropWash.workspace(isDark: false).baseOpacity, 0.38, accuracy: 0.0001)
        // Dark remains at its previously verified values. Light now passes
        // more of the desktop through the rails while the light workspace
        // stays unchanged.
        // It used to be
        // the least translucent surface in the app (0.40 transmission against
        // light's 0.40 on the sidebar and 0.45 on the workspace), which is what
        // "the background in dark mode looks bad… needs to be glassy/smooth/
        // translucent to the wallpaper" was describing. 0.55 → 0.52 in v1.1.10,
        // and 0.52 → 0.33 here for "dark mode should be very translucent" —
        // which only became available once the bake started bounding the
        // still's dynamic range as well as its mean.
        XCTAssertEqual(GlassBackdropWash.sidebar(isDark: true).baseOpacity, 0.34, accuracy: 0.0001)
        XCTAssertEqual(GlassBackdropWash.workspace(isDark: true).baseOpacity, 0.37, accuracy: 0.0001)
        // The white-rail pass deliberately inverted the old light-passes-more
        // relation: dark stays the translucency champion (0.66), and light
        // spends veil on reading white the way Safari's light sidebar does,
        // while holding its own majority-transmission floor below.
        // The headline, stated the way Michael asked for it: dark now passes
        // half again as much desktop as it did, on both surfaces.
        XCTAssertGreaterThan(GlassBackdropWash.sidebar(isDark: true).desktopTransmission, 0.65)
        XCTAssertGreaterThan(GlassBackdropWash.workspace(isDark: true).desktopTransmission, 0.60)
        // Light rail transmission is now twice its original 0.40 floor.
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
            GlassBackdropWash.desktopTransmissionBand(isDark: false).ceiling,
            GlassBackdropWash.desktopTransmissionBand(isDark: true).ceiling
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
        } + [("opaque dark plate", [
            OpaqueThemeGround.darkPlate.red,
            OpaqueThemeGround.darkPlate.green,
            OpaqueThemeGround.darkPlate.blue,
        ])] + [
            (WorkspaceBackdropMode.system, false), (.system, true),
            (.tinted, false), (.tinted, true),
        ].map { theme, isDark -> (String, [Double]) in
            let wash = GlassBackdropWash.opaqueGround(theme: theme, isDark: isDark)
            return ("opaque \(theme.rawValue) ground (isDark: \(isDark))", [wash.red, wash.green, wash.blue])
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

        // The canvas keeps more white carrier than the rails, so it remains
        // the brighter surface even though the rail veil itself is thinner.
        XCTAssertGreaterThan(
            LightGlassFrost.modeledBackdropLuminance(lightWorkspace),
            LightGlassFrost.modeledRailLuminance(lightSidebar)
        )
        XCTAssertGreaterThan(
            LightGlassFrost.modeledRailDesktopContribution(lightSidebar),
            (1 - LightGlassFrost.carrierWhiteCoverage) * lightWorkspace.desktopTransmission
        )
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
            // The opaque themes' grounds sit at or above the floor on their
            // own, so their derived overlays clamp to zero — the assertions
            // exist so a future coverage cut cannot fall below it silently.
            for theme in [WorkspaceBackdropMode.system, .tinted] {
                XCTAssertGreaterThanOrEqual(
                    composite(
                        base: OpaqueThemeGround.coverage(theme: theme, isDark: isDark),
                        overlay: GlassBackdropWash.opaqueGroundIncreasedContrastOverlay(
                            theme: theme,
                            isDark: isDark
                        )
                    ),
                    GlassBackdropWash.increasedContrastCoverage - epsilon,
                    "\(theme.rawValue) ground (\(appearance)) leaves too much wallpaper under Increased Contrast"
                )
            }
        }
    }

    /// The window ground is material in every theme, the way Safari's is: no
    /// theme's ground is fully opaque, and the three stay strictly ordered —
    /// Glass shows the most desktop, Tinted gives up a fifth, Solid a tenth.
    func testEveryThemeSitsOnTheSameMaterialGround() {
        for isDark in [false, true] {
            let glass = OpaqueThemeGround.coverage(theme: .glass, isDark: isDark)
            let tinted = OpaqueThemeGround.coverage(theme: .tinted, isDark: isDark)
            let solid = OpaqueThemeGround.coverage(theme: .system, isDark: isDark)
            XCTAssertLessThan(glass, tinted, "isDark \(isDark): the themes lost their ordering")
            XCTAssertLessThan(tinted, solid, "isDark \(isDark): the themes lost their ordering")
            XCTAssertLessThan(solid, 1.0, "isDark \(isDark): Solid went back to a flat plate")
        }
    }

    /// The opaque themes keep the colour they always had — light #FFFFFF,
    /// dark `windowBackgroundColor`'s #1E1E1E (which `controlBackgroundColor`
    /// matches in Dark Aqua, so one plate covers rails and canvas). Fails
    /// loudly if AppKit ever moves the dark value. The dark ground also must
    /// not pick up `GlassWarmth`'s amber: at a tenth of transmission the
    /// declared amber contributes under a count of 255.
    func testTheOpaqueThemesKeepTheColourTheyAlwaysHad() {
        let lightGround = GlassBackdropWash.opaqueGround(theme: .system, isDark: false)
        XCTAssertEqual(lightGround.red, 1)
        XCTAssertEqual(lightGround.green, 1)
        XCTAssertEqual(lightGround.blue, 1)

        let darkGround = GlassBackdropWash.opaqueGround(theme: .system, isDark: true)
        XCTAssertEqual(darkGround.red, OpaqueThemeGround.darkPlate.red)

        guard let darkAqua = NSAppearance(named: .darkAqua) else {
            return XCTFail("no darkAqua appearance to resolve against")
        }
        var window: NSColor?
        var control: NSColor?
        darkAqua.performAsCurrentDrawingAppearance {
            window = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            control = NSColor.controlBackgroundColor.usingColorSpace(.sRGB)
        }
        // The exact byte is environment-dependent: a windowed session resolves
        // #1E1E1E while CI's headless resolver hands back #323232 for the same
        // appearance, so asserting the constant against AppKit byte-for-byte
        // just measures the test host. What the dark grounds actually depend
        // on is the *family*: an achromatic near-black in the same band as the
        // plate, so a mismatched card still reads as one surface a step apart.
        let plateBand = 0.10...0.22
        XCTAssertTrue(
            plateBand.contains(OpaqueThemeGround.darkPlate.red),
            "the declared plate left the dark window-background family"
        )
        for (name, resolved) in [("windowBackgroundColor", window), ("controlBackgroundColor", control)] {
            guard let resolved else { return XCTFail("\(name) did not resolve to sRGB") }
            let channels = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
                .map(Double.init)
            for channel in channels {
                XCTAssertEqual(
                    channel,
                    channels[0],
                    accuracy: 1.0 / 255,
                    "\(name) is no longer achromatic in dark"
                )
                XCTAssertTrue(
                    plateBand.contains(channel),
                    "\(name) moved out of the near-black band the dark grounds are built on"
                )
            }
        }

        let warmthShare = GlassWarmth.opacity(isDark: true)
            * (1 - OpaqueThemeGround.solidCoverage.dark)
        XCTAssertLessThan(warmthShare, 1.0 / 255, "the dark Solid ground picked up a visible amber")
    }

    /// The glass transmission band is the *glass* contract — its floor exists
    /// so a glass surface never becomes an opaque panel. The opaque themes sit
    /// below that floor on purpose: a tenth to a fifth of material is a pane
    /// edge, not a glass surface. This test is here so nobody "fixes" the
    /// band violation by pushing the opaque grounds into it.
    func testOpaqueGroundsAreOutsideTheGlassTransmissionBandOnPurpose() {
        for isDark in [false, true] {
            let floor = GlassBackdropWash.desktopTransmissionBand(isDark: isDark).floor
            for theme in [WorkspaceBackdropMode.system, .tinted] {
                XCTAssertLessThan(
                    1 - OpaqueThemeGround.coverage(theme: theme, isDark: isDark),
                    floor,
                    "\(theme.rawValue) (isDark \(isDark)) drifted into the glass band and stopped being an opaque theme"
                )
            }
        }
    }

    /// Clarity is a glass knob. Scaling the Solid ground by a clarity's veil
    /// scale would turn Solid into a fourth theme, so `opaqueGround` takes no
    /// clarity at all — and this test pins that scaling *would* change the
    /// wash, so routing clarity through cannot pass unnoticed.
    func testClarityDoesNotScaleTheOpaqueGrounds() {
        for isDark in [false, true] {
            let ground = GlassBackdropWash.opaqueGround(theme: .system, isDark: isDark)
            for clarity in GlassClarity.allCases where clarity.veilScale != 1 {
                XCTAssertNotEqual(
                    ground.scaled(by: clarity.veilScale),
                    ground,
                    "the sentinel lost its teeth: scaling no longer changes the wash"
                )
            }
            XCTAssertEqual(GlassBackdropWash.opaqueGround(theme: .system, isDark: isDark), ground)
        }
    }

    /// The tinted stops were solved against pure white; the material ground
    /// under them must stay within a few counts of it, or the palette table
    /// silently re-solves. Dark is the mirror guard: a dark canvas that glows
    /// is not a canvas.
    func testTintedGroundStaysWhiteLedEnoughForItsStops() {
        XCTAssertGreaterThanOrEqual(
            OpaqueThemeGround.modeledLuminance(theme: .tinted, isDark: false),
            0.94,
            "the light tinted ground darkened past what the stop table was solved against"
        )
        XCTAssertLessThanOrEqual(
            OpaqueThemeGround.modeledLuminance(theme: .tinted, isDark: true),
            0.16
        )
        XCTAssertLessThanOrEqual(
            OpaqueThemeGround.modeledLuminance(theme: .system, isDark: true),
            0.16
        )
    }

    /// A screenshot must never catch a mid-drift frame: every isolated
    /// fixture process pins the tint's endpoint drift, structurally rather
    /// than per surface. Pure, no view.
    func testFixtureProcessesPinTheTintDrift() {
        XCTAssertTrue(TintFlowMotion.isPinned(environment: ["KAISOLA_NATIVE_VISUAL_FIXTURE": "1"]))
        XCTAssertTrue(TintFlowMotion.isPinned(environment: ["KAISOLA_NATIVE_RESOURCE_WORKLOAD": "x"]))
        XCTAssertFalse(TintFlowMotion.isPinned(environment: [:]))
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
    /// SUPERSEDED by the request itself. The painted source was the default for
    /// as long as it was the only one that could promise other applications never
    /// showed through. What it could never be is *live*: `NSWorkspace` refuses to
    /// name the current picture of a rotating or dynamic desktop, so the ladder
    /// fell through to a stand-in or a thumbnail, and neither a playing aerial nor
    /// anything behind the window ever moved the surface. Michael asked for glass
    /// that "ACTUALLY reflect[s] the live wallpaper/desktop/behind the screen",
    /// and behind-window vibrancy is that by construction — at the cost, accepted
    /// deliberately, of other apps' windows showing through when behind Kaisola.
    func testGlassBackdropDefaultsToTheLiveBehindWindowSource() {
        let suite = "kaisola-backdrop-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(NativePreviewSettings(defaults: defaults).glassBackdropSource, .behindWindow)
        XCTAssertEqual(GlassPreset.source, .behindWindow)

        // The source is a preset, not a preference: a value stored by a build
        // that still offered the picker must not outlive the picker.
        defaults.set(GlassBackdropSource.wallpaper.rawValue, forKey: "glassBackdropSource")
        XCTAssertEqual(NativePreviewSettings(defaults: defaults).glassBackdropSource, .behindWindow)

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
    /// surface, appearance-specific warmth, the light white carrier, then the
    /// veil gradient. Exactly the layers `DesktopGlassLayer` and the backdrop
    /// views compose, in the same order, with the same constants.
    private func renderGlassSurface(
        still: CGImage,
        wash: GlassBackdropWash,
        isDark: Bool,
        width: Int,
        height: Int,
        crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        warmth: Double? = nil,
        carrierWhiteCoverage: Double = LightGlassFrost.carrierWhiteCoverage
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
            if !isDark {
                context.setFillColor(
                    red: 1, green: 1, blue: 1,
                    alpha: carrierWhiteCoverage
                )
                context.fill(rect)
            }

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
    /// The twelve-point rail intentionally exposes more of the desktop than the
    /// previous twenty-point veil, so the system semantic is now only a
    /// regression sentinel. The ink the app actually ships is held separately
    /// to the full 4.5:1 floor below; 3.3 keeps this inherited semantic from
    /// collapsing while leaving the appearance contract honest.
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
                    still: still, wash: wash, isDark: false, width: width, height: height,
                    carrierWhiteCoverage: surface == "sidebar"
                        ? LightGlassFrost.railCarrierWhiteCoverage
                        : LightGlassFrost.carrierWhiteCoverage
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
                    worst.secondary, 3.3,
                    """
                    \(name) \(surface): secondary label on the worst patch is \
                    \(worst.secondary):1, below the clear-rail regression floor
                    """
                )
            }
        }
    }

    /// The mechanism that lifts light's secondary over the floor, kept as a live
    /// measurement rather than a note: a custom ink instead of the system
    /// semantic. It now reads the *shipped* alpha out of `KaisolaInk` rather
    /// than a literal, so the number here cannot drift away from the ink the app
    /// actually draws with.
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
        let shipped = KaisolaInk.alpha(.secondary, isDark: false, on: .glass)
        print(String(
            format: "[light-glass] worst-patch secondary: AppKit α0.498 %.2f:1, Kaisola α%.3f %.2f:1",
            inked(0.498), shipped, inked(shipped)
        ))
        XCTAssertLessThan(inked(0.498), 4.5, "the system semantic clears the floor after all")
        XCTAssertGreaterThanOrEqual(
            inked(shipped), 4.5,
            "the shipped secondary ink no longer buys the floor on the adversarial fixture"
        )
    }

    // MARK: - The ink ladder

    /// Contrast of one rung of `KaisolaInk` against a rendered patch. The ink is
    /// black in light and white in dark, which is exactly what
    /// `KaisolaInk.nsColor` resolves to, so this measures the shipped constant
    /// rather than a copy of it.
    private func inkContrast(
        alpha: Double,
        over patch: (Double, Double, Double),
        isDark: Bool
    ) -> Double {
        let ink = isDark ? 1.0 : 0.0
        return contrastRatio(
            text: (
                ink * alpha + patch.0 * (1 - alpha),
                ink * alpha + patch.1 * (1 - alpha),
                ink * alpha + patch.2 * (1 - alpha)
            ),
            over: patch
        )
    }

    private func inkContrast(
        _ level: KaisolaInk.Level,
        over patch: (Double, Double, Double),
        isDark: Bool,
        on surface: KaisolaInk.Surface = .glass
    ) -> Double {
        inkContrast(
            alpha: KaisolaInk.alpha(level, isDark: isDark, on: surface),
            over: patch,
            isDark: isDark
        )
    }

    /// A colour as the given appearance actually draws it, in sRGB.
    private func resolved(_ color: NSColor, in appearance: NSAppearance)
        -> (red: Double, green: Double, blue: Double, alpha: Double) {
        var components = (red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            components = (
                Double(srgb.redComponent), Double(srgb.greenComponent),
                Double(srgb.blueComponent), Double(srgb.alphaComponent)
            )
        }
        return components
    }

    /// The six wallpapers the light and dark worst-patch tests already hold the
    /// veil to. The ink is held to the same ones so the two constraints cannot
    /// be measured on different ground.
    private static let inkFixtures: [(name: String, base: (Double, Double, Double), range: Double)] = [
        ("aerial", (0.263, 0.476, 0.575), 0.9),     // Michael's own desktop
        ("dim", (0.06, 0.07, 0.09), 0.9),
        ("bright", (0.82, 0.80, 0.76), 0.7),
        ("saturated", (0.42, 0.20, 0.08), 0.8),
        ("neutral-wide", (0.435, 0.435, 0.435), 1.6),
        ("adversarial", (0.5, 0.5, 0.5), 1.95),
    ]

    /// **The criterion this whole change exists for.** Kaisola's secondary ink
    /// clears 4.5:1 on the worst patch of every light-glass fixture, on both
    /// surfaces, at every clarity that does not declare a contrast trade.
    ///
    /// The same loop measures AppKit's `secondaryLabelColor` alongside, and
    /// asserts it *fails* somewhere — without that, a future veil change that
    /// happened to lift the system semantic over the floor would leave this test
    /// green while proving nothing about the ink.
    func testTheSecondaryInkClearsTheFloorOnEveryLightGlassFixture() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-inkfloor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clarities = GlassClarity.allCases.filter { !$0.relaxesTextContrast }
        XCTAssertEqual(clarities.count, 2, "a clarity was added without deciding its text floor")
        var systemSemanticFailedSomewhere = false

        for (name, base, range) in Self.inkFixtures {
            let url = try writeRampWallpaper(base: base, range: range, into: directory, named: name)
            let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: false)
            guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key) else {
                return XCTFail("\(name) produced no painting")
            }
            for clarity in clarities {
                for (surface, wash, width, height) in [
                    ("sidebar", GlassBackdropWash.sidebar(isDark: false, clarity: clarity), 210, 900),
                    ("workspace", GlassBackdropWash.workspace(isDark: false, clarity: clarity), 900, 900),
                ] {
                    let pixels = try renderGlassSurface(
                        still: still, wash: wash, isDark: false, width: width, height: height,
                        carrierWhiteCoverage: surface == "sidebar"
                            ? LightGlassFrost.railCarrierWhiteCoverage
                            : LightGlassFrost.carrierWhiteCoverage
                    )
                    let patch = worstPatchContrast(pixels, isDark: false).patch
                    let kaisola = inkContrast(.secondary, over: patch, isDark: false)
                    let appKit = inkContrast(alpha: 0.498, over: patch, isDark: false)
                    systemSemanticFailedSomewhere = systemSemanticFailedSomewhere || appKit < 4.5
                    print(String(
                        format: "[ink] light %@ %@ %@ secondary: AppKit %.2f:1  Kaisola %.2f:1",
                        clarity.rawValue, name, surface, appKit, kaisola
                    ))
                    XCTAssertGreaterThanOrEqual(
                        kaisola, 4.5,
                        """
                        \(clarity.rawValue) \(name) \(surface): the secondary ink measures \
                        \(kaisola):1 on the worst patch, under the 4.5 floor
                        """
                    )
                    XCTAssertGreaterThanOrEqual(
                        inkContrast(.primary, over: patch, isDark: false), 7,
                        "\(clarity.rawValue) \(name) \(surface): primary fell under 7:1"
                    )
                }
            }
        }

        XCTAssertTrue(
            systemSemanticFailedSomewhere,
            "AppKit's secondary now clears 4.5 everywhere, so this test no longer proves the ink"
        )
    }

    /// The dark half, which the ink deliberately leaves where AppKit had it —
    /// asserted so "unchanged" stays a measured claim rather than a memory.
    func testTheSecondaryInkHoldsDarkGlassWhereTheSystemSemanticAlreadyDid() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-inkdark-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            KaisolaInk.alpha(.secondary, isDark: true), 0.55, accuracy: 0.001,
            "dark secondary moved off AppKit's alpha; the dark measurements below were not re-derived"
        )

        for (name, base, range) in Self.inkFixtures {
            let url = try writeRampWallpaper(base: base, range: range, into: directory, named: name)
            let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: true)
            guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key) else {
                return XCTFail("\(name) produced no painting")
            }
            for (surface, wash, width, height) in [
                ("sidebar", GlassBackdropWash.sidebar(isDark: true), 210, 900),
                ("workspace", GlassBackdropWash.workspace(isDark: true), 900, 900),
            ] {
                let pixels = try renderGlassSurface(
                    still: still, wash: wash, isDark: true, width: width, height: height
                )
                let patch = worstPatchContrast(pixels, isDark: true).patch
                let secondary = inkContrast(.secondary, over: patch, isDark: true)
                let tertiary = inkContrast(.tertiary, over: patch, isDark: true)
                print(String(
                    format: "[ink] dark %@ %@ secondary %.2f:1  tertiary %.2f:1",
                    name, surface, secondary, tertiary
                ))
                XCTAssertGreaterThanOrEqual(
                    secondary, 4.5, "\(name) \(surface): dark secondary is \(secondary):1"
                )
                XCTAssertGreaterThanOrEqual(
                    tertiary, 3, "\(name) \(surface): dark tertiary is \(tertiary):1"
                )
            }
        }
    }

    /// The other two surfaces of the token set: the opaque ones. Light solid is
    /// white in Aqua — `windowBackgroundColor`, `controlBackgroundColor` and
    /// `textBackgroundColor` all resolve there — so the solid ink is measured
    /// against whatever AppKit actually returns rather than against an assumed
    /// #FFFFFF.
    func testTheSecondaryInkClearsTheFloorOnEverySolidSurface() throws {
        let surfaces: [(String, NSColor)] = [
            ("window", .windowBackgroundColor),
            ("control", .controlBackgroundColor),
            ("text", .textBackgroundColor),
        ]
        for (isDark, appearanceName) in [(false, NSAppearance.Name.aqua), (true, .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for (name, color) in surfaces {
                let resolvedColour = resolved(color, in: appearance)
                let patch = (resolvedColour.red, resolvedColour.green, resolvedColour.blue)
                let secondary = inkContrast(.secondary, over: patch, isDark: isDark, on: .solid)
                let tertiary = inkContrast(.tertiary, over: patch, isDark: isDark, on: .solid)
                print(String(
                    format: "[ink] %@ solid %@ (%.3f) secondary %.2f:1  tertiary %.2f:1",
                    isDark ? "dark" : "light", name, patch.1, secondary, tertiary
                ))
                XCTAssertGreaterThanOrEqual(
                    secondary, 4.5,
                    "\(name) in \(appearanceName.rawValue): solid secondary is \(secondary):1"
                )
                XCTAssertGreaterThanOrEqual(
                    tertiary, 3,
                    "\(name) in \(appearanceName.rawValue): solid tertiary is \(tertiary):1"
                )
            }
        }
    }

    /// Hierarchy, which is the constraint a contrast floor on its own would
    /// happily destroy: four rungs, each strictly lighter than the one above it
    /// by a real step, on every surface the tokens name.
    ///
    /// The floors each rung is held to are not the same floor, and that is the
    /// point of having rungs at all:
    ///
    ///   * primary — 7:1, and AppKit's own `labelColor` alpha, unchanged.
    ///   * secondary — 4.5:1, WCAG 1.4.3 for body text.
    ///   * tertiary — 3:1, WCAG 1.4.11, because an **icon-only control** is a
    ///     non-text UI component and tertiary is the rung its glyph sits on.
    ///   * disabled — no floor. 1.4.3 exempts inactive controls, and this is the
    ///     only rung that takes the exemption.
    func testTheInkLadderKeepsItsHierarchy() throws {
        // Primary is AppKit's, read from AppKit, so a platform change shows up
        // here rather than in a screenshot.
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertEqual(
            KaisolaInk.alpha(.primary, isDark: false),
            resolved(.labelColor, in: aqua).alpha,
            accuracy: 0.01,
            "primary drifted off `labelColor`; it is meant to be the system's, untouched"
        )

        for surface in KaisolaInk.Surface.allCases {
            for isDark in [false, true] {
                let alphas = KaisolaInk.Level.allCases.map {
                    KaisolaInk.alpha($0, isDark: isDark, on: surface)
                }
                XCTAssertEqual(
                    alphas, alphas.sorted(by: >),
                    "\(surface.rawValue) \(isDark ? "dark" : "light"): the ladder is not monotone"
                )
                XCTAssertEqual(
                    KaisolaInk.placeholderAlpha(isDark: isDark, on: surface),
                    KaisolaInk.alpha(.secondary, isDark: isDark, on: surface),
                    accuracy: 0.0001,
                    "placeholder text is text; it takes the secondary ink, not a lighter rung"
                )
            }
        }

        // And in contrast, on the two glass worst patches, which is where the
        // rungs are closest together and so where a collapse would show first.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-inkladder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for isDark in [false, true] {
            let url = try writeRampWallpaper(
                base: (0.5, 0.5, 0.5), range: 1.95, into: directory,
                named: "adversarial-\(isDark ? "dark" : "light")"
            )
            let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: isDark)
            guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key) else {
                return XCTFail("the adversarial fixture produced no painting")
            }
            let pixels = try renderGlassSurface(
                still: still, wash: GlassBackdropWash.workspace(isDark: isDark),
                isDark: isDark, width: 900, height: 900
            )
            let patch = worstPatchContrast(pixels, isDark: isDark).patch
            let ladder = KaisolaInk.Level.allCases.map {
                inkContrast($0, over: patch, isDark: isDark)
            }
            print(String(
                format: "[ink] %@ glass ladder  primary %.2f:1  secondary %.2f:1"
                    + "  tertiary %.2f:1  disabled %.2f:1",
                isDark ? "dark" : "light", ladder[0], ladder[1], ladder[2], ladder[3]
            ))
            for (index, level) in KaisolaInk.Level.allCases.enumerated() where index > 0 {
                XCTAssertGreaterThanOrEqual(
                    ladder[index - 1] / ladder[index], 1.3,
                    """
                    \(isDark ? "dark" : "light"): \(level.rawValue) is within \
                    \(ladder[index - 1] / ladder[index])× of the rung above it, \
                    which is not a visible step
                    """
                )
            }
            XCTAssertGreaterThanOrEqual(ladder[0], 7, "primary")
            XCTAssertGreaterThanOrEqual(ladder[1], 4.5, "secondary")
            XCTAssertGreaterThanOrEqual(
                ladder[2], 3,
                "tertiary carries icon-only controls, which WCAG 1.4.11 holds to 3:1"
            )
        }
    }

    /// Clear clarity is the one setting that declares a contrast trade, and the
    /// ink does not repeal it: a surface that is 92% desktop cannot also promise
    /// 4.5:1. What the ink does buy there is measured — **3.08:1 → 3.99:1** on
    /// the worst patch of the adversarial fixture — so the trade stays a number
    /// rather than a shrug. Clear still falls back to Balanced, which meets the
    /// full floor, for anyone who asked the system for contrast; that is
    /// `GlassClarityTradeTests.testAccessibilitySettingsOverrideClear`.
    func testClearClarityKeepsItsTradeButTheInkStillBuysIntoIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-inkclear-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try writeRampWallpaper(
            base: (0.5, 0.5, 0.5), range: 1.95, into: directory, named: "adversarial"
        )
        let key = DesktopBackdropKey(path: url.path, modified: nil, isDark: false)
        guard case let .wallpaper(still, _, _)? = DesktopBackdropRenderer.render(key: key) else {
            return XCTFail("the adversarial fixture produced no painting")
        }
        let pixels = try renderGlassSurface(
            still: still,
            wash: GlassBackdropWash.workspace(isDark: false, clarity: .clear),
            isDark: false, width: 900, height: 900
        )
        let patch = worstPatchContrast(pixels, isDark: false).patch
        let kaisola = inkContrast(.secondary, over: patch, isDark: false)
        let appKit = inkContrast(alpha: 0.498, over: patch, isDark: false)
        print(String(
            format: "[ink] light clear adversarial workspace secondary: AppKit %.2f:1  Kaisola %.2f:1",
            appKit, kaisola
        ))
        XCTAssertGreaterThan(
            kaisola, appKit,
            "the ink stopped helping at Clear, where it is the only thing that can"
        )
        XCTAssertGreaterThanOrEqual(
            kaisola, 3.9,
            "Clear's relaxed secondary floor moved; re-derive it or re-tune the ink"
        )
    }

    /// The ink is one colour that resolves per appearance at draw time, not two
    /// colours a view has to choose between — the property every AppKit call
    /// site depends on, since a text-view attribute is baked once and drawn
    /// under whatever appearance is current later.
    func testTheInkResolvesPerAppearanceAtDrawTime() throws {
        for level in KaisolaInk.Level.allCases {
            for surface in KaisolaInk.Surface.allCases {
                let colour = KaisolaInk.nsColor(level, on: surface)
                let light = resolved(colour, in: try XCTUnwrap(NSAppearance(named: .aqua)))
                let dark = resolved(colour, in: try XCTUnwrap(NSAppearance(named: .darkAqua)))
                XCTAssertEqual(light.red, 0, accuracy: 0.001, "\(level.rawValue) is not black in Aqua")
                XCTAssertEqual(dark.red, 1, accuracy: 0.001, "\(level.rawValue) is not white in Dark Aqua")
                XCTAssertEqual(
                    light.alpha, KaisolaInk.alpha(level, isDark: false, on: surface), accuracy: 0.001
                )
                XCTAssertEqual(
                    dark.alpha, KaisolaInk.alpha(level, isDark: true, on: surface), accuracy: 0.001
                )
            }
        }
    }

    /// One audited call site, kept honest: the Markdown editor's missing-image
    /// placeholder draws its label on a `quaternaryLabelColor` plate rather than
    /// on the document's white, so it takes the *glass* weight of the secondary
    /// ink. This asserts the composite it actually lands on.
    func testTheDocumentPlaceholderPlateClearsTheFloor() throws {
        for (isDark, appearanceName) in [(false, NSAppearance.Name.aqua), (true, .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let page = resolved(.textBackgroundColor, in: appearance)
            let plate = resolved(.quaternaryLabelColor, in: appearance)
            // The plate is a translucent ink over the page, exactly as drawn.
            let composite = (
                plate.red * plate.alpha + page.red * (1 - plate.alpha),
                plate.green * plate.alpha + page.green * (1 - plate.alpha),
                plate.blue * plate.alpha + page.blue * (1 - plate.alpha)
            )
            let label = inkContrast(.secondary, over: composite, isDark: isDark)
            let solid = inkContrast(.secondary, over: composite, isDark: isDark, on: .solid)
            print(String(
                format: "[ink] %@ document placeholder plate %.3f  glass %.2f:1  solid %.2f:1",
                isDark ? "dark" : "light", composite.1, label, solid
            ))
            XCTAssertGreaterThanOrEqual(
                label, 4.5,
                "the missing-image placeholder label measures \(label):1 on its own plate"
            )
        }
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
                    isDark: isDark, width: 210, height: 900, crop: crop,
                    carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage
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
                                    width: width, height: height, crop: crop,
                                    carrierWhiteCoverage: label == "sidebar"
                                        ? LightGlassFrost.railCarrierWhiteCoverage
                                        : LightGlassFrost.carrierWhiteCoverage
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
        // The shipped recipe is soft / muted / clear, and it is a PRESET
        // rather than three preferences: Settings offers Glass or Solid and
        // nothing else, so there is no picker left for these to disagree with.
        //
        // Clarity went balanced → clear on 2026-08-26, the third round of
        // "extremely more translucent": Clear is the tier built for exactly
        // that request, and `resolved(for:)` still hands anyone with Increase
        // Contrast or Reduce Transparency the Balanced floors.
        XCTAssertEqual(fresh.glassTexture, .soft)
        XCTAssertEqual(fresh.glassColour, .muted)
        XCTAssertEqual(fresh.glassClarity, .clear)
        XCTAssertEqual(fresh.glassTexture, GlassPreset.texture)
        XCTAssertEqual(fresh.glassColour, GlassPreset.colour)
        XCTAssertEqual(fresh.glassClarity, GlassPreset.clarity)
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

        // Stored values from a build that still had the pickers must not
        // resurrect a recipe the user can no longer see or change.
        defaults.set(GlassTexture.crisp.rawValue, forKey: "glassTexture")
        defaults.set(GlassColour.vivid.rawValue, forKey: "glassColour")
        defaults.set(GlassClarity.balanced.rawValue, forKey: "glassClarity")
        let reopened = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(reopened.glassTexture, .soft)
        XCTAssertEqual(reopened.glassColour, .muted)
        XCTAssertEqual(reopened.glassClarity, .clear)

        // They remain settable in-process, which is what the sweep tests need.
        fresh.glassTexture = .crisp
        fresh.glassColour = .vivid
        fresh.glassClarity = .clear
        XCTAssertEqual(fresh.glassTexture, .crisp)
        XCTAssertEqual(fresh.glassColour, .vivid)
        XCTAssertEqual(fresh.glassClarity, .clear)

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
                    width: 210, height: 900, crop: crop,
                    carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage
                )
                let perceived = perceivedSurface(surface)
                surfaceLightness.append(perceived.lightness)
                surfaceSaturation.append(perceived.saturation)
                bareSaturation.append(perceivedSurface(try renderGlassSurface(
                    still: still, wash: wash, isDark: isDark,
                    width: 210, height: 900, crop: crop, warmth: 0,
                    carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage
                )).saturation)
                frozenSaturation.append(perceivedSurface(try renderGlassSurface(
                    still: frozen, wash: wash, isDark: isDark,
                    width: 210, height: 900,
                    carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage
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
                spread(surfaceLightness), 1.01,
                "the surface's perceived lightness depends on hue: \(surfaceLightness)"
            )
            if isDark {
                XCTAssertLessThan(
                    spread(stillSaturation), 1.01,
                    "the dark baked still's colourfulness depends on hue: \(stillSaturation)"
                )
                XCTAssertLessThan(
                    spread(surfaceSaturation), 1.12,
                    "the dark surface's colourfulness depends on hue: \(surfaceSaturation)"
                )
                XCTAssertLessThan(
                    spread(bareSaturation), 1.09,
                    "dark surfaces no longer share one hue-neutral material: \(bareSaturation)"
                )
                // Dark Glass still carries muted desktop colour.
                XCTAssertGreaterThan(
                    surfaceSaturation.prefix(3).min()!, neutralSurface * 4,
                    "dark Glass no longer carries the desktop's hue at all"
                )
            } else {
                // Light Glass is now explicitly white. Every coloured member
                // must collapse to the same achromatic material while retaining
                // the luminance structure checked above.
                XCTAssertLessThan(
                    stillSaturation.max()!, 0.002,
                    "the painted light carrier retained wallpaper hue: \(stillSaturation)"
                )
                XCTAssertLessThan(
                    surfaceSaturation.max()!, 0.002,
                    "the finished light Glass retained wallpaper hue: \(surfaceSaturation)"
                )
            }

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
                    still: legacy, wash: wash, isDark: isDark, width: 210, height: 900,
                    carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage
                )
                let after = try renderGlassSurface(
                    still: still, wash: wash, isDark: isDark, width: 210, height: 900,
                    carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage
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
                    worst.secondary, isDark ? 4.5 : 3.3,
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

    /// Light Glass retains the wallpaper's light and shade, never its hue.
    /// The carrier makes the result white; the remaining luminance spread is
    /// the depth cue that keeps it recognisably glass rather than a flat fill.
    func testLightGlassPreservesWallpaperStructureWithoutColour() throws {
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
            still: still, wash: before, isDark: false, width: 210, height: 900,
            carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage
        )
        let nowPixels = try renderGlassSurface(
            still: still, wash: now, isDark: false, width: 210, height: 900,
            carrierWhiteCoverage: LightGlassFrost.railCarrierWhiteCoverage
        )
        print(String(
            format: "[light-glass] sidebar chroma %.4f -> %.4f  spread %.4f -> %.4f  (transmission %.2f -> %.2f)",
            chroma(beforePixels), chroma(nowPixels),
            luminanceSpread(beforePixels), luminanceSpread(nowPixels),
            before.desktopTransmission, now.desktopTransmission
        ))
        XCTAssertLessThanOrEqual(chroma(nowPixels), 1.0 / 255)
        // The white carrier does not flatten the wallpaper's structure away.
        XCTAssertGreaterThan(
            luminanceSpread(nowPixels), 0.02,
            "white Glass became a flat opaque fill"
        )
        XCTAssertGreaterThan(now.desktopTransmission, 0.5)
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

        // Light keeps the live material's chroma and uses only the single
        // white veil to frost it. No second carrier consumes the
        // transmission; the white-rail pass moved the pin from 0.70 to 0.54,
        // still a majority share for the desktop.
        XCTAssertEqual(SidebarBackdropView.liveTint.light, 0, accuracy: 0.0001)
        let lightAfterCarrier = transmission(
            tint: SidebarBackdropView.liveTint.light,
            veil: GlassBackdropWash.sidebar(isDark: false).baseOpacity
        ) * (1 - LightGlassFrost.railCarrierWhiteCoverage)
        XCTAssertEqual(lightAfterCarrier, 0.54, accuracy: 0.0001)
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

    /// The light normalization is a floor, not a destination. A dim desktop is
    /// still lifted onto the receipted grey so ink never lands on a dark
    /// surface, but a white desktop passes through at its own lightness —
    /// dragging it down to the floor is exactly the "glass is grey when the
    /// background is white" report. Dark keeps the symmetric map: a white
    /// desktop must still arrive dark, or light ink dies.
    func testAWhiteDesktopReadsWhiteInLightAndStillArrivesDarkInDark() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-white-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func stillMean(_ url: URL, isDark: Bool) throws -> Double {
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
            var total = 0.0
            var count = 0.0
            var index = 0
            while index + 3 < pixels.count {
                total += Double(pixels[index]) / 255 * 0.2126
                    + Double(pixels[index + 1]) / 255 * 0.7152
                    + Double(pixels[index + 2]) / 255 * 0.0722
                count += 1
                index += 4
            }
            return total / max(count, 1)
        }

        // Near-white with a whisper of ramp, like a plain light workspace.
        let white = try writeRampWallpaper(
            base: (0.96, 0.96, 0.96), range: 0.04, into: directory, named: "white"
        )
        let lightMean = try stillMean(white, isDark: false)
        XCTAssertGreaterThan(
            lightMean,
            DesktopBackdropRenderer.targetLuminance(isDark: false) + 0.05,
            "a white desktop was dragged down to the grey floor instead of passing through"
        )
        XCTAssertGreaterThan(lightMean, 0.90, "the pane should read white, not pale grey")

        let darkMean = try stillMean(white, isDark: true)
        XCTAssertEqual(
            darkMean, DesktopBackdropRenderer.targetLuminance(isDark: true), accuracy: 0.06,
            "dark must keep normalizing a white desktop down"
        )

        // A dim desktop still gets the lift the floor exists for.
        let dim = try writeRampWallpaper(
            base: (0.30, 0.30, 0.30), range: 0.3, into: directory, named: "dim"
        )
        let dimMean = try stillMean(dim, isDark: false)
        XCTAssertEqual(
            dimMean, DesktopBackdropRenderer.targetLuminance(isDark: false), accuracy: 0.06,
            "the floor stopped lifting dim desktops"
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
    /// point: fixed amber coverage is a much larger relative perturbation on a
    /// near-black still than on the bright light still, in a hue opposite the
    /// cool cast — which is how "blue" became "purple".
    func testGlassWarmthCoverageTracksTheSurfaceItLandsOn() {
        XCTAssertEqual(GlassWarmth.opacity(isDark: false), 0, accuracy: 0.0001)
        let ratio = DesktopBackdropRenderer.targetLuminance(isDark: true)
            / DesktopBackdropRenderer.targetLuminance(isDark: false)
        XCTAssertEqual(
            GlassWarmth.opacity(isDark: true),
            GlassWarmth.opacity * ratio,
            accuracy: 0.0001
        )
        // Still there. A layer scaled to zero is a layer deleted, and the whole
        // argument for a declared amber is that it says out loud that it exists.
        // Floor 0.005 -> 0.004 when the dark target went 0.16 -> 0.12 for
        // "darker by default". This number is *derived* from that target, by
        // design — the amber has to stay the same proportion of the surface's
        // colour or it reintroduces the purple cast the derivation removed — so
        // a darker surface necessarily gets a smaller amber. The divisor is
        // LightGlassFrost.backdropLuminance, so every white-glass round eats
        // this margin: 0.00483 at 0.72, 0.00435 at 0.80, 0.00409 at 0.85. The
        // floor exists to catch a layer scaled to nothing, not to pin the
        // target — but the underlay's ~0.87 ceiling is where the two collide,
        // so that ceiling is asserted here, next to the floor it protects.
        XCTAssertGreaterThan(GlassWarmth.opacity(isDark: true), 0.004)
        XCTAssertLessThanOrEqual(
            LightGlassFrost.backdropLuminance,
            0.87,
            "past 0.87 the dark amber (0.029 × 0.12 / backdropLuminance) falls through its 0.004 floor — whiten the rails another way"
        )
        XCTAssertLessThan(GlassWarmth.opacity(isDark: true), GlassWarmth.opacity)
    }

    // MARK: - The three workspace canvases

    /// Light Tinted is a visible pastel flow over white — the whisper era
    /// rendered pixel-identical to Glass — while Dark Tinted keeps the
    /// stronger sampled-desktop treatment that already works there.
    func testSolidAndTintedCanvasesStayDistinctWithoutAHeavyLightWash() {
        func offNeutral(_ channels: [Double]) -> Double {
            let mean = channels.reduce(0, +) / Double(channels.count)
            guard mean > 0 else { return 0 }
            return channels.map { abs($0 - mean) / mean }.max() ?? 0
        }
        func luminance(_ channels: [Double]) -> Double {
            channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }

        let lightSolid = [1.0, 1.0, 1.0]
        let lightStops = [
            (LightTintedGradient.cool, LightTintedGradient.coolCoverage),
            (LightTintedGradient.neutral, LightTintedGradient.neutralCoverage),
            (LightTintedGradient.pearl, LightTintedGradient.pearlCoverage),
        ]
        XCTAssertEqual(offNeutral(lightSolid), 0, accuracy: 0.0001)
        for (colour, coverage) in lightStops {
            let tinted = [colour.red, colour.green, colour.blue].map {
                1 * (1 - coverage) + $0 * coverage
            }
            // Coarse luminance/chroma guard. The precise visible-but-pastel
            // bounds live in `testLightTintedStopsRemainVisibleAfterCompositingOverWhite`.
            XCTAssertGreaterThan(
                luminance(tinted),
                0.90,
                "light Tinted is no longer a white-led pastel surface"
            )
            XCTAssertLessThan(
                offNeutral(tinted),
                0.05,
                "a light Tinted stop is a colour field instead of a gentle wash"
            )
        }

        // Dark stays on the established sampled tint and coverage.
        let sampled = DesktopTintComponents(red: 0.3152, green: 0.4646, blue: 0.5343)
        let darkSolid = [0.1176, 0.1176, 0.1176]
        let tint = DesktopTintSampler.revalued(
            sampled,
            peak: DesktopTintSampler.canvasTintPeak(isDark: true)
        )
        let coverage = DesktopTintSampler.canvasTintCoverage(isDark: true)
        let channels = [tint.red, tint.green, tint.blue]
        let darkTinted = zip(darkSolid, channels).map {
            $0 * (1 - coverage.top) + $1 * coverage.top
        }
        XCTAssertGreaterThan(offNeutral(darkTinted), 0.10, "dark Tinted lost its sampled hue")
        XCTAssertGreaterThan(luminance(darkTinted), luminance(darkSolid))
        XCTAssertLessThan(luminance(darkTinted), 0.30, "a dark canvas that glows is not a canvas")
        XCTAssertGreaterThan(coverage.top, coverage.bottom)
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
        // the neutrality invariant exists to prevent. Stated on the reference
        // coverage from which the dark one is derived; see
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
    /// light one moves with both the veil and the normalized carrier. At 0.45
    /// coverage over the white-frost carrier it now sits at 0.89 — the desktop
    /// still supplies colour and structure without turning the surface grey.
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
                XCTAssertGreaterThan(composite, 0.82)
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

        // A width this feature itself placed in an earlier release (the
        // v1.1.8 210) is the feature's to move again — once, under the new
        // key generation — or the widening could never reach the windows the
        // request was about.
        XCTAssertTrue(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 210, didForce: false)
        )
        XCTAssertTrue(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 211.5, didForce: false)
        )
        XCTAssertFalse(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 210, didForce: true)
        )
        // The band is exact: a nearby width the user dragged to stays theirs.
        XCTAssertFalse(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 207, didForce: false)
        )
        XCTAssertFalse(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 214, didForce: false)
        )
        // 248 and 290 are previously-forced ideals now (the v0.1.124 and
        // v0.1.125 resting widths), so windows the app parked there move once
        // to the current 245.
        XCTAssertTrue(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 248, didForce: false)
        )
        XCTAssertFalse(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 248, didForce: true)
        )
        XCTAssertTrue(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 290, didForce: false)
        )
        XCTAssertFalse(
            InitialSidebarWidth.shouldForceInitialWidth(currentWidth: 290, didForce: true)
        )

        // The new key generation is what re-arms previously-forced windows;
        // it must actually be new.
        XCTAssertTrue(
            InitialSidebarWidth.defaultsKey(restorationID: "main").contains(".v4.")
        )

        // Never against a restored or user-chosen width — including the ideal
        // itself, so a second window does not re-run the override.
        for width in [168.0, 240.0, 245.0, 300.0, 340.0] {
            XCTAssertFalse(
                InitialSidebarWidth.shouldForceInitialWidth(
                    currentWidth: width,
                    didForce: false
                ),
                "\(width) is neither AppKit's default nor a width this feature placed"
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
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarIdealWidth, 245)
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

    /// A dragged rail width persists and outranks the resting ideal for every
    /// new window; the unset sentinel keeps fresh installs on the constant.
    func testPersistedProjectRailWidthWinsOverTheRestingIdeal() {
        XCTAssertEqual(
            NativeWorkspaceChrome.resolvedProjectRailIdealWidth(
                storedWidth: NativePreviewSettings.projectRailWidthUnset
            ),
            NativeWorkspaceChrome.projectSidebarIdealWidth
        )
        XCTAssertEqual(
            NativeWorkspaceChrome.resolvedProjectRailIdealWidth(storedWidth: 275),
            275
        )
        // Stored values clamp to the rail's own band, and the settings clamp
        // mirrors the chrome band exactly so the two can never disagree.
        XCTAssertEqual(
            NativeWorkspaceChrome.resolvedProjectRailIdealWidth(storedWidth: 80),
            NativeWorkspaceChrome.projectSidebarMinimumWidth
        )
        XCTAssertEqual(
            NativeWorkspaceChrome.resolvedProjectRailIdealWidth(storedWidth: 900),
            NativeWorkspaceChrome.projectSidebarMaximumWidth
        )
        XCTAssertEqual(
            NativePreviewSettings.projectRailWidthRange.lowerBound,
            Double(NativeWorkspaceChrome.projectSidebarMinimumWidth)
        )
        XCTAssertEqual(
            NativePreviewSettings.projectRailWidthRange.upperBound,
            Double(NativeWorkspaceChrome.projectSidebarMaximumWidth)
        )
        XCTAssertEqual(NativePreviewSettings.clampedProjectRailWidth(80), 168)
        XCTAssertEqual(NativePreviewSettings.clampedProjectRailWidth(900), 340)
    }

    /// With no paired Mac the section was a permanent "No other Macs yet" plus
    /// a "Updated N seconds ago" line: two rows of chrome reporting nothing.
    func testOtherMacsSectionStaysHiddenUntilThereIsSomethingToReport() {
        XCTAssertFalse(
            RememberedSessionsSectionVisibility.shouldShow(
                remoteDeviceCount: 0, errorMessage: nil, hasEverSeenRemoteDevice: false
            )
        )
        XCTAssertFalse(
            RememberedSessionsSectionVisibility.shouldShow(
                remoteDeviceCount: 0, errorMessage: "", hasEverSeenRemoteDevice: true
            )
        )
        XCTAssertFalse(
            RememberedSessionsSectionVisibility.shouldShow(
                remoteDeviceCount: 0, errorMessage: "  \n ", hasEverSeenRemoteDevice: true
            )
        )
        XCTAssertTrue(
            RememberedSessionsSectionVisibility.shouldShow(
                remoteDeviceCount: 1, errorMessage: nil, hasEverSeenRemoteDevice: false
            )
        )
        // A failure must never be silent just because it left the catalog
        // empty — but only about a fleet that has actually been seen.
        XCTAssertTrue(
            RememberedSessionsSectionVisibility.shouldShow(
                remoteDeviceCount: 0,
                errorMessage: "Companion is offline",
                hasEverSeenRemoteDevice: true
            )
        )
        // A never-paired install stays silent even when the saved-session
        // refresh fails; there is no fleet to report on.
        XCTAssertFalse(
            RememberedSessionsSectionVisibility.shouldShow(
                remoteDeviceCount: 0,
                errorMessage: "The saved Firebase session is unavailable.",
                hasEverSeenRemoteDevice: false
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

    /// The top-bar toggles moved into the content overlay, so their retired
    /// reveal strip must not survive as an empty band above the detail card.
    func testTheTopBarLayoutUsesTheSharedGutterWithoutAnEmptyStrip() {
        XCTAssertEqual(
            NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar),
            KaisolaVisualSystem.chromeInset
        )
        XCTAssertEqual(NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar), 6)
        XCTAssertEqual(
            NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar),
            NativeWorkspaceChrome.detailPanelTopInset(layout: .leftTree)
        )
        XCTAssertLessThan(
            NativeWorkspaceChrome.detailPanelTopInset(layout: .topBar),
            NativeWorkspaceChrome.detailToggleStripHeight,
            "the retired 28pt toggle strip is still reserving an empty band"
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
        XCTAssertEqual(KaisolaVisualSystem.shellRadius, 30)
        XCTAssertEqual(KaisolaVisualSystem.chromeRadius, 26)

        // The rail's active-project capsule uses `insetRadius` inside a 32pt
        // row, so it has to stay under half the row height or the capsule turns
        // into a stadium and stops reading as a rectangle at all.
        XCTAssertLessThan(KaisolaVisualSystem.insetRadius, 16)
    }

    /// A shadow narrower than the gutter is invisible; wider than about twice
    /// it smears onto the far rail. The offset stays inside the blur so the
    /// card floats rather than sliding.
    func testTheChromeCardShadowStaysInsideItsOwnGutterNeighbourhood() {
        XCTAssertGreaterThan(
            ChromeCardElevation.shadowRadius,
            KaisolaVisualSystem.chromeInset
        )
        XCTAssertLessThanOrEqual(
            ChromeCardElevation.shadowRadius,
            KaisolaVisualSystem.chromeInset * 2
        )
        XCTAssertLessThan(
            ChromeCardElevation.shadowOffsetY,
            ChromeCardElevation.shadowRadius
        )
    }

    /// `engages` is the card's whole accessibility posture: when it is false
    /// the card drops its shadow AND swaps the lit gradient edge for the flat
    /// `separatorColor` border — both `cardShadow` and `panelEdge` branch on
    /// this one function, so the truth table below governs both.
    func testAccessibilitySurfacesGetNoCardShadow() {
        XCTAssertFalse(ChromeCardElevation.engages(reduceTransparency: true, increasedContrast: false))
        XCTAssertFalse(ChromeCardElevation.engages(reduceTransparency: false, increasedContrast: true))
        XCTAssertTrue(ChromeCardElevation.engages(reduceTransparency: false, increasedContrast: false))
    }

    /// Dark already separates the card with its `darkPanelCoverage` luminance
    /// step, so its containment hairline is zero and its appearance stays
    /// byte-identical; light is where the closing edge was missing. The dark
    /// shadow is heavier because a dark ground swallows a light one's opacity.
    func testDarkAppearanceKeepsItsExistingCardEdge() {
        XCTAssertEqual(ChromeCardElevation.containmentOpacity(isDark: true), 0)
        XCTAssertGreaterThan(ChromeCardElevation.containmentOpacity(isDark: false), 0)
        XCTAssertGreaterThan(
            ChromeCardElevation.shadowOpacity(isDark: true),
            ChromeCardElevation.shadowOpacity(isDark: false)
        )
    }

    /// The regression the flush-rail change fixed by hand: the two rails are
    /// the ground and the detail content column is the card, and nothing else
    /// is either. A source-level count, because nothing structural prevents a
    /// future pass from quietly re-carding a rail.
    func testOnlyTheDetailColumnWearsTheChromeCard() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Kaisola", isDirectory: true)
        let expectations = [
            ("Features/Sessions/RootShellView.swift", 1),
            ("Features/Workspace/WorkspaceRailView.swift", 0),
            ("Features/Sessions/QuietProjectRail.swift", 0),
        ]
        for (path, expected) in expectations {
            let source = try String(
                contentsOf: sources.appendingPathComponent(path),
                encoding: .utf8
            )
            let calls = source.components(separatedBy: ".kaisolaChromePanel(").count - 1
            XCTAssertEqual(
                calls,
                expected,
                "\(path): only the detail column may wear the chrome card"
            )
        }
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
        // 210 → 248 in v0.1.124, 248 → 290 in v0.1.125, 290 → 245 on
        // 2026-08-26: the double-click reset should land "1-2cm less wide",
        // by request.
        XCTAssertEqual(NativeWorkspaceChrome.projectSidebarIdealWidth, 245)
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
        XCTAssertNotNil(viewMenu.items.first { $0.title == "Zoom In" && $0.keyEquivalent == "+" })
        XCTAssertNotNil(viewMenu.items.first { $0.title == "Zoom Out" && $0.keyEquivalent == "-" })
        XCTAssertNotNil(viewMenu.items.first { $0.title == "Actual Size" && $0.keyEquivalent == "0" })
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

    // MARK: - Settings catalog search (#423)

    func testSettingsCatalogSearchFindsSectionTitlesRowsAndUsefulSynonyms() {
        XCTAssertEqual(SettingsCatalogSearch.matches(query: "Terminal"), [.terminal])
        for section in SettingsSection.allCases {
            XCTAssertTrue(
                SettingsCatalogSearch.matches(query: section.title).contains(section),
                "Section title did not find \(section.rawValue)"
            )
        }
        XCTAssertEqual(SettingsCatalogSearch.matches(query: "external editor"), [.general])
        XCTAssertEqual(SettingsCatalogSearch.matches(query: "account directory"), [.accounts])
        XCTAssertEqual(SettingsCatalogSearch.matches(query: "MCP server"), [.extensions])
        XCTAssertEqual(SettingsCatalogSearch.matches(query: "safety approvals"), [.guardrails])
    }

    func testSettingsCatalogSearchRequiresEveryQueryToken() {
        XCTAssertEqual(SettingsCatalogSearch.matches(query: "background downloads"), [.updates])
        XCTAssertEqual(SettingsCatalogSearch.matches(query: "provider credentials"), [.models])
        XCTAssertEqual(SettingsCatalogSearch.matches(query: "project overrides"), [.accounts])
        XCTAssertTrue(SettingsCatalogSearch.matches(query: "provider downloads").isEmpty)
    }

    func testSettingsCatalogSearchPreservesGroupedBrowseAndHasATruthfulEmptyState() {
        XCTAssertFalse(SettingsCatalogSearch.isFiltering("   \n"))
        XCTAssertTrue(SettingsCatalogSearch.isFiltering("terminal"))
        XCTAssertTrue(SettingsCatalogSearch.matches(query: "no such preference").isEmpty)
        XCTAssertTrue(SettingsSection.allCases.allSatisfy { !$0.searchTerms.isEmpty })
    }

    func testSettingsCatalogSearchExposesVoiceOverResultCounts() {
        XCTAssertEqual(SettingsCatalogSearch.resultCountLabel(0), "No results")
        XCTAssertEqual(SettingsCatalogSearch.resultCountLabel(1), "1 result")
        XCTAssertEqual(SettingsCatalogSearch.resultCountLabel(3), "3 results")
        XCTAssertEqual(
            SettingsCatalogSearch.accessibilityValue(query: "MCP", resultCount: 1),
            "MCP. 1 result."
        )
    }

    // MARK: - Settings window controls (#306)

    /// A Settings window built the way the product builds it.
    private func makeSettingsWindow(
        styleMask: NSWindow.StyleMask = SettingsWindowChrome.styleMask,
        size: NSSize = SettingsWindowChrome.minimumContentSize
    ) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        return window
    }

    /// The reserved band is measured against AppKit's own title bar rather than
    /// pinned to a literal, so a future macOS that grows that bar fails here
    /// instead of quietly putting the mark back over the buttons.
    func testSettingsReservesTheTitleBarBandAppKitOwns() {
        let window = makeSettingsWindow()
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titleBarHeight, 0)
        XCTAssertGreaterThanOrEqual(SettingsWindowChrome.titleBarSafeArea, titleBarHeight)
    }

    /// The bug itself: the 30pt Settings mark sat 14pt below the top of a
    /// full-size content view, which is on top of the minimize and zoom
    /// controls. Both halves are asserted — the old geometry still collides, the
    /// shipped one does not — so this cannot pass by measuring nothing.
    func testSettingsMarkClearsEveryStandardWindowButton() throws {
        let window = makeSettingsWindow()
        let controls = NativeVisualWindowControlGate.controlRegions(in: window)
        XCTAssertEqual(controls.count, 3)

        let unreserved = SettingsWindowChrome.topLeadingContentFrames(titleBarSafeArea: 0)
            .map { NativeVisualWindowControlGate.Region(name: $0.name, frame: $0.frame) }
        let collision = try XCTUnwrap(NativeVisualWindowControlGate.collision(
            controls: controls,
            content: unreserved
        ))
        XCTAssertTrue(collision.hasPrefix("settings-identity-mark-over-"), collision)

        let shipped = SettingsWindowChrome.topLeadingContentFrames()
            .map { NativeVisualWindowControlGate.Region(name: $0.name, frame: $0.frame) }
        XCTAssertNil(NativeVisualWindowControlGate.collision(
            controls: controls,
            content: shipped
        ))

        // Clearance, not a tie: the mark starts below the lowest button edge.
        let lowestButtonEdge = controls.map(\.frame.maxY).max() ?? 0
        XCTAssertGreaterThan(
            SettingsWindowChrome.identityMarkFrame().minY,
            lowestButtonEdge
        )
    }

    /// The whole laid-out window rather than the one rect the layout declares:
    /// this is the check each Settings fixture runs before writing its PNG.
    func testSettingsWindowControlGatePassesTheShippedLayout() throws {
        let suite = "kaisola.tests.settings-chrome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = makeSettingsWindow(size: SettingsWindowChrome.idealContentSize)
        window.contentView = NSHostingView(
            rootView: SettingsView(settings: NativePreviewSettings(defaults: defaults))
                .environmentObject(AuthModel.previewSignedIn())
        )
        window.contentView?.layoutSubtreeIfNeeded()
        let report = NativeVisualWindowControlGate.inspect(window)
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.controls, 3)
    }

    /// Every fixture surface that opens Settings is gated; workspace surfaces
    /// keep their own chrome and are left alone.
    func testWindowControlGateAppliesToSettingsSurfacesOnly() {
        XCTAssertTrue(NativeVisualWindowControlGate.applies(to: "settings"))
        XCTAssertTrue(NativeVisualWindowControlGate.applies(to: "settings-minimum"))
        XCTAssertTrue(NativeVisualWindowControlGate.applies(to: "settings-ideal"))
        XCTAssertTrue(NativeVisualWindowControlGate.applies(to: "usage"))
        XCTAssertFalse(NativeVisualWindowControlGate.applies(to: "terminal"))
        XCTAssertFalse(NativeVisualWindowControlGate.applies(to: "mesh"))
    }

    /// A control you can see but cannot use is the same failure as one you
    /// cannot see. Settings shipped without `.miniaturizable` for its whole
    /// life, so the gate is also held against a window that still does.
    func testSettingsWindowKeepsAllThreeControlsOperable() throws {
        let window = makeSettingsWindow()
        XCTAssertNil(NativeVisualWindowControlGate.missingControl(in: window))
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            XCTAssertFalse(button.isHidden)
            XCTAssertTrue(button.isEnabled)
        }

        let withoutMinimize = makeSettingsWindow(
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView]
        )
        XCTAssertEqual(
            NativeVisualWindowControlGate.missingControl(in: withoutMinimize),
            "disabled-miniaturize"
        )
    }

    /// AppKit measures from the bottom-left corner and the layout from the
    /// top-left one. Everything the gate compares goes through this flip.
    func testWindowControlGateFlipsAppKitCoordinates() {
        let window = makeSettingsWindow()
        let height = window.contentView?.bounds.height ?? window.frame.height
        XCTAssertEqual(
            NativeVisualWindowControlGate.topLeftFrame(
                CGRect(x: 7, y: height - 22, width: 14, height: 16),
                in: window
            ),
            CGRect(x: 7, y: 6, width: 14, height: 16)
        )
    }

    func testWindowControlGateOnlyReportsRegionsThatMeetAButton() {
        let control = NativeVisualWindowControlGate.Region(
            name: "zoom",
            frame: CGRect(x: 47, y: 6, width: 14, height: 16)
        )
        let below = NativeVisualWindowControlGate.Region(
            name: "sidebar-row",
            frame: CGRect(x: 8, y: 42, width: 160, height: 34)
        )
        let over = NativeVisualWindowControlGate.Region(
            name: "mark",
            frame: CGRect(x: 22, y: 14, width: 30, height: 30)
        )
        XCTAssertNil(NativeVisualWindowControlGate.collision(
            controls: [control],
            content: [below]
        ))
        XCTAssertEqual(
            NativeVisualWindowControlGate.collision(controls: [control], content: [below, over]),
            "mark-over-zoom"
        )
    }

    /// The two ends of the size contract the fixtures inspect. The old 810×540
    /// fixture sat below the window's own minimum, so CI was reading a Settings
    /// window the product cannot be resized to.
    func testSettingsFixturesCaptureBothEndsOfTheSizeContract() {
        XCTAssertEqual(
            SettingsWindowChrome.visualContentSize(surface: "settings-minimum"),
            SettingsWindowChrome.minimumContentSize
        )
        XCTAssertEqual(
            SettingsWindowChrome.visualContentSize(surface: "settings-ideal"),
            SettingsWindowChrome.idealContentSize
        )
        XCTAssertEqual(
            SettingsWindowChrome.visualContentSize(surface: "settings"),
            SettingsWindowChrome.minimumContentSize
        )
        XCTAssertGreaterThan(
            SettingsWindowChrome.idealContentSize.height,
            SettingsWindowChrome.minimumContentSize.height
        )
        XCTAssertTrue(SettingsWindowChrome.visualSurfaces.contains("settings-minimum"))
        XCTAssertTrue(SettingsWindowChrome.visualSurfaces.contains("settings-ideal"))
    }

    /// The non-Retina fixture resamples the finished capture to one pixel per
    /// point, and does nothing at all when it is not asked to.
    func testNonRetinaCaptureRedrawsAtOnePixelPerPoint() throws {
        let points = SettingsWindowChrome.minimumContentSize
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(points.width) * 2,
            height: Int(points.height) * 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: points.width * 2, height: points.height * 2))
        let retina = try XCTUnwrap(context.makeImage())

        let onePoint = try XCTUnwrap(NativeVisualCapture.rescaled(
            retina,
            pointSize: points,
            pointPixelScale: 1
        ))
        XCTAssertEqual(onePoint.width, Int(points.width))
        XCTAssertEqual(onePoint.height, Int(points.height))

        // An unset scale, and an image that is already 1×, are both no-ops.
        XCTAssertNil(NativeVisualCapture.rescaled(retina, pointSize: points, pointPixelScale: 0))
        XCTAssertNil(NativeVisualCapture.rescaled(onePoint, pointSize: points, pointPixelScale: 1))
    }
}

extension TintPalette {
    /// The smallest channel separation this palette promises after
    /// compositing on the canvas. Graphite is grey on purpose and declares a
    /// lower floor than the coloured palettes; nothing may declare zero.
    /// A test-side declaration: the shipped constant floor of 8 became
    /// per-palette the day Graphite joined, which is a real loosening of an
    /// invariant — mitigated by the floor never being zero and the ceiling
    /// staying global.
    var minimumCanvasSpread: Double { self == .graphite ? 4 : 8 }
}
