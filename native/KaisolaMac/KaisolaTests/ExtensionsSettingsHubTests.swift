import XCTest
@testable import Kaisola

@MainActor
final class ExtensionsSettingsHubTests: XCTestCase {
    func testInstalledVisualFixtureUpdaterIsInert() {
        let controller = NativeUpdateController(isolatedFixture: true)
        XCTAssertFalse(controller.startedUpdater)
        XCTAssertEqual(
            controller.availability,
            .unavailable("Updates are disabled in isolated fixtures.")
        )
    }

    func testVisualFixtureBrokerPreparerCannotDiscoverOrLaunch() async {
        do {
            _ = try await BrokerFreeFixturePreparer().prepare()
            XCTFail("A broker-free fixture preparer must never return a broker")
        } catch {
            XCTAssertEqual(error as? BrokerDiscoveryError, .notRunning)
        }
    }

    func testExtensionsIsTheSingleRegistryDestinationAndLegacyMCPLinksMigrate() {
        XCTAssertTrue(SettingsSection.allCases.contains(.extensions))
        XCTAssertFalse(SettingsSection.allCases.map(\.rawValue).contains("mcp"))
        XCTAssertEqual(SettingsSection.extensions.group, .agents)
        XCTAssertEqual(SettingsSection.extensions.title, "Extensions")

        XCTAssertEqual(
            ExtensionsSettingsRoute.parse("extensions"),
            ExtensionsSettingsRoute(category: nil, itemID: nil)
        )
        XCTAssertEqual(
            ExtensionsSettingsRoute.parse("mcp"),
            ExtensionsSettingsRoute(category: .mcpServers, itemID: nil)
        )
        XCTAssertEqual(
            ExtensionsSettingsRoute.parse("extensions:language-grammars:broken-grammar"),
            ExtensionsSettingsRoute(category: .languageGrammars, itemID: "broken-grammar")
        )
        XCTAssertEqual(
            ExtensionsSettingsRoute(category: .terminalThemes, itemID: "nord").rawValue,
            "extensions:terminal-themes:nord"
        )
    }

    func testHubOwnsExactlyTheFiveShippedExtensionRegistries() {
        XCTAssertEqual(
            ExtensionsSettingsCategory.allCases,
            [.customAgents, .mcpServers, .terminalThemes, .languageGrammars, .previewMappings]
        )
        XCTAssertEqual(Set(ExtensionsSettingsCategory.allCases.map(\.title)).count, 5)
        XCTAssertTrue(ExtensionsSettingsCategory.allCases.allSatisfy { !$0.accessibilitySummary.isEmpty })
    }

    func testCustomAgentMetadataNamesEnablementSourcePinnedIntegrityScopeAndUpdates() {
        let spec = CustomAgentSpec(
            id: "custom-reviewer",
            name: "Reviewer",
            launchCommand: "reviewer",
            symbol: "terminal",
            acpPackage: "@example/reviewer@2.4.1",
            credentials: "none",
            chatEnabled: true
        )
        let record = InstalledAdapterRecord(
            agentID: spec.id,
            package: "@example/reviewer@2.4.1",
            resolvedVersion: "2.4.1",
            binRelativePath: "node_modules/.bin/reviewer",
            lockfileSHA256: String(repeating: "a", count: 64),
            treeSHA256: String(repeating: "b", count: 64),
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let item = ExtensionSettingsItem.customAgent(spec, install: record)

        XCTAssertEqual(item.category, .customAgents)
        XCTAssertEqual(item.status, .enabled("Chat enabled"))
        XCTAssertEqual(item.source, .user)
        XCTAssertEqual(item.scope, .appWide)
        XCTAssertEqual(item.versionIntegrity, "v2.4.1 · lock aaaaaaaa · files bbbbbbbb")
        XCTAssertEqual(item.updateState, .manual("Re-enable to approve an update"))
        XCTAssertNil(item.validationMessage)
    }

    func testInvalidAgentAndDataEntriesDegradeToNamedDisabledRows() {
        let invalidAgent = CustomAgentSpec(
            id: "custom-bad",
            name: "Bad adapter",
            launchCommand: "bad-agent",
            symbol: "terminal",
            acpPackage: "https://example.test/adapter",
            credentials: "none",
            chatEnabled: true
        )
        let invalidGrammar = CustomGrammarSpec(
            id: "broken-grammar",
            title: "Broken grammar",
            extensions: ["broken"],
            fences: nil,
            rules: [.init(pattern: "(", role: "keyword", context: nil, priority: nil, caseInsensitive: nil, anchorsMatchLines: nil)]
        )
        let invalidMapping = PreviewMappingSpec(
            id: "unsafe-preview",
            extensions: ["raw"],
            kind: "pdf"
        )

        for item in [
            ExtensionSettingsItem.customAgent(invalidAgent, install: nil),
            ExtensionSettingsItem.languageGrammar(invalidGrammar),
            ExtensionSettingsItem.previewMapping(invalidMapping),
        ] {
            guard case .disabled = item.status else {
                XCTFail("\(item.name) was not disabled")
                continue
            }
            XCTAssertNotNil(item.validationMessage)
            XCTAssertEqual(item.source, .user)
            XCTAssertEqual(item.scope, .appWide)
            XCTAssertFalse(item.versionIntegrity.isEmpty)
            XCTAssertFalse(item.updateState.label.isEmpty)
        }
    }

    func testMCPRowsStayProjectOwnedAndNeverExposeCredentialValues() {
        let server = McpServerConfig(
            name: "project-files",
            kind: .stdio,
            command: "filesystem-mcp",
            args: ["--workspace"],
            envPairs: [.init(name: "ACCESS_TOKEN", value: "super-secret")],
            enabled: false
        )

        let item = ExtensionSettingsItem.mcpServer(server, projectName: "Kaisola")

        XCTAssertEqual(item.status, .disabled("Disabled"))
        XCTAssertEqual(item.source, .projectConfiguration)
        XCTAssertEqual(item.scope, .project("Kaisola"))
        XCTAssertEqual(item.versionIntegrity, "Check server to verify version")
        XCTAssertEqual(item.updateState, .manual("Checked on demand"))
        XCTAssertFalse(item.searchableText.contains("super-secret"))
        XCTAssertFalse(item.accessibilityDescription.contains("super-secret"))
    }

    func testBuiltInAndCustomThemesHaveConsistentMetadataAndSelection() {
        let builtIn = ExtensionSettingsItem.builtInTheme(
            id: "native",
            title: "macOS Terminal",
            selected: true
        )
        XCTAssertEqual(builtIn.status, .enabled("Active"))
        XCTAssertEqual(builtIn.source, .builtIn)
        XCTAssertEqual(builtIn.scope, .appWide)
        XCTAssertEqual(builtIn.versionIntegrity, "Bundled with Kaisola")
        XCTAssertEqual(builtIn.updateState, .bundled)

        let invalid = CustomThemeSpec(
            id: "bad-theme",
            title: "Bad Theme",
            light: .init(background: "oops", foreground: "#ffffff", cursor: "#ffffff", selection: "#ffffff", ansi: Array(repeating: "#000000", count: 16)),
            dark: .init(background: "#000000", foreground: "#ffffff", cursor: "#ffffff", selection: "#ffffff", ansi: Array(repeating: "#000000", count: 16))
        )
        let custom = ExtensionSettingsItem.customTheme(invalid, selected: false)
        XCTAssertEqual(custom.source, .user)
        XCTAssertNotNil(custom.validationMessage)
        guard case .disabled = custom.status else { return XCTFail("Invalid theme was enabled") }
    }

    func testSearchIsCaseAndDiacriticInsensitiveAcrossNameCategoryAndMetadata() {
        let items = ExtensionsSettingsFixture.items
        XCTAssertEqual(
            ExtensionsSettingsCatalog.filtered(items, query: "MCP").map(\.category),
            [.mcpServers]
        )
        XCTAssertEqual(
            ExtensionsSettingsCatalog.filtered(items, query: "cafe").map(\.id),
            ["cafe-theme"]
        )
        XCTAssertEqual(
            ExtensionsSettingsCatalog.filtered(items, query: "project scoped").map(\.category),
            [.mcpServers]
        )
        XCTAssertEqual(
            ExtensionsSettingsCatalog.filtered(items, query: "stdio").map(\.category),
            [.mcpServers]
        )
        XCTAssertEqual(
            ExtensionsSettingsCatalog.filtered(items, query: ".notes").map(\.category),
            [.previewMappings]
        )
        XCTAssertEqual(ExtensionsSettingsCatalog.filtered(items, query: "does-not-exist"), [])
    }

    func testLoadingEmptyErrorAndNoResultsStatesAreDistinct() {
        XCTAssertEqual(
            ExtensionsSettingsCollectionState.resolve(isLoading: true, allItems: [], visibleItems: [], query: ""),
            .loading
        )
        XCTAssertEqual(
            ExtensionsSettingsCollectionState.resolve(isLoading: false, allItems: [], visibleItems: [], query: ""),
            .empty
        )
        XCTAssertEqual(
            ExtensionsSettingsCollectionState.resolve(isLoading: false, allItems: ExtensionsSettingsFixture.items, visibleItems: [], query: "missing"),
            .noResults("missing")
        )
        XCTAssertEqual(
            ExtensionsSettingsCollectionState.resolve(
                isLoading: false,
                allItems: ExtensionsSettingsFixture.items,
                visibleItems: ExtensionsSettingsFixture.items,
                query: ""
            ),
            .content(invalidCount: 1)
        )
    }

    func testKeyboardCategoryNavigationWrapsAndHonorsFilteredCategories() {
        let categories: [ExtensionsSettingsCategory] = [.customAgents, .terminalThemes, .previewMappings]
        XCTAssertEqual(
            ExtensionsSettingsNavigation.move(from: .customAgents, direction: .next, in: categories),
            .terminalThemes
        )
        XCTAssertEqual(
            ExtensionsSettingsNavigation.move(from: .previewMappings, direction: .next, in: categories),
            .customAgents
        )
        XCTAssertEqual(
            ExtensionsSettingsNavigation.move(from: .customAgents, direction: .previous, in: categories),
            .previewMappings
        )
    }

    func testCompactSettingsLayoutKeepsSidebarBrandClearOfWindowControls() {
        XCTAssertFalse(SettingsSidebarLayoutPolicy.showsBrand(contentWidth: 820))
        XCTAssertTrue(SettingsSidebarLayoutPolicy.showsBrand(contentWidth: 1_100))
    }

    func testOptimizedVisualFixtureCoversEveryRegistryWithoutPersistingSecrets() {
        let items = ExtensionsSettingsFixture.items
        XCTAssertEqual(Set(items.map(\.category)), Set(ExtensionsSettingsCategory.allCases))
        XCTAssertEqual(items.filter { $0.validationMessage != nil }.count, 1)
        XCTAssertEqual(items.first { $0.category == .customAgents }?.status, .enabled("Terminal only"))
        XCTAssertTrue(items.allSatisfy { !$0.accessibilityDescription.isEmpty })
        XCTAssertFalse(items.map(\.accessibilityDescription).joined().contains("fixture-secret"))
    }

    func testInstalledVisualReceiptFailsClosedOnIsolationGeometryAndAX() {
        func receipt(
            surface: String = "settings-extensions",
            width: CGFloat = 1_100,
            identifiers: [String] = ["extensions.hub"],
            labels: [String] = ["Search extensions"],
            updaterDisabled: Bool = true,
            brokerIsolated: Bool = true
        ) -> NativeVisualExtensionsSettingsReceipt {
            NativeVisualExtensionsSettingsReceipt(
                surface: surface,
                contentWidth: width,
                contentHeight: 800,
                categoryCount: 5,
                itemCount: 5,
                invalidCount: 1,
                accessibilityIdentifiers: identifiers,
                accessibilityLabels: labels,
                fixtureUpdaterDisabled: updaterDisabled,
                fixtureBrokerIsolated: brokerIsolated
            )
        }

        XCTAssertNil(receipt().failure)
        XCTAssertNil(receipt(
            surface: "settings-extensions-narrow",
            width: 820,
            labels: ["Search extensions", "Extension category"]
        ).failure)
        XCTAssertEqual(receipt(updaterDisabled: false).failure, "fixture-updater-started")
        XCTAssertEqual(receipt(brokerIsolated: false).failure, "fixture-broker-route-live")
        XCTAssertEqual(
            receipt(labels: []).failure,
            "missing-search-label-ax"
        )
        XCTAssertEqual(
            receipt(surface: "settings-extensions-narrow", width: 820).failure,
            "missing-compact-picker-label-ax"
        )
        XCTAssertEqual(receipt(width: 900).failure, "wide-content-too-narrow-900.0")
    }
}
