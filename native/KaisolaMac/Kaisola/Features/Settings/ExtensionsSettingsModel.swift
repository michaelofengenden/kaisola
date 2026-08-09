import Foundation

/// The five registries that share the consolidated Extensions destination.
/// These are presentation categories only: each underlying store keeps its
/// existing ownership and persistence contract.
enum ExtensionsSettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case customAgents = "custom-agents"
    case mcpServers = "mcp-servers"
    case terminalThemes = "terminal-themes"
    case languageGrammars = "language-grammars"
    case previewMappings = "preview-mappings"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .customAgents: "Custom Agents"
        case .mcpServers: "MCP Servers"
        case .terminalThemes: "Terminal Themes"
        case .languageGrammars: "Language Grammars"
        case .previewMappings: "Preview Mappings"
        }
    }

    var shortTitle: String {
        switch self {
        case .customAgents: "Agents"
        case .mcpServers: "MCP"
        case .terminalThemes: "Themes"
        case .languageGrammars: "Grammars"
        case .previewMappings: "Previews"
        }
    }

    var symbol: String {
        switch self {
        case .customAgents: "person.badge.plus"
        case .mcpServers: "server.rack"
        case .terminalThemes: "paintpalette"
        case .languageGrammars: "curlybraces.square"
        case .previewMappings: "doc.text.magnifyingglass"
        }
    }

    var accessibilitySummary: String {
        switch self {
        case .customAgents: "App-wide terminal agents and approved chat adapters"
        case .mcpServers: "Tool servers owned by the current project"
        case .terminalThemes: "App-wide terminal color palettes"
        case .languageGrammars: "App-wide syntax highlighting rules"
        case .previewMappings: "App-wide file extension to text preview mappings"
        }
    }
}

/// A Settings deep link can land on the hub, one registry, or one exact row.
/// The old `mcp` section remains accepted so saved/restored Settings state does
/// not strand a user after consolidation.
struct ExtensionsSettingsRoute: Equatable, Sendable {
    var category: ExtensionsSettingsCategory?
    var itemID: String?

    static func parse(_ value: String?) -> Self? {
        guard let value, !value.isEmpty else { return nil }
        if value == "mcp" {
            return Self(category: .mcpServers, itemID: nil)
        }
        guard value == "extensions" || value.hasPrefix("extensions:") else {
            return nil
        }
        let components = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count > 1 else { return Self(category: nil, itemID: nil) }
        guard let category = ExtensionsSettingsCategory(rawValue: String(components[1])) else {
            return Self(category: nil, itemID: nil)
        }
        let itemID = components.count > 2 && !components[2].isEmpty
            ? String(components[2])
            : nil
        return Self(category: category, itemID: itemID)
    }

    var rawValue: String {
        guard let category else { return "extensions" }
        guard let itemID, !itemID.isEmpty else { return "extensions:\(category.rawValue)" }
        return "extensions:\(category.rawValue):\(itemID)"
    }
}

enum ExtensionSettingsStatus: Equatable, Sendable {
    case enabled(String)
    case disabled(String)

    var label: String {
        switch self {
        case let .enabled(label), let .disabled(label): label
        }
    }

    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

enum ExtensionSettingsSource: Equatable, Sendable {
    case builtIn
    case user
    case projectConfiguration

    var label: String {
        switch self {
        case .builtIn: "Built in"
        case .user: "Added by you"
        case .projectConfiguration: "Project configuration"
        }
    }
}

enum ExtensionSettingsScope: Equatable, Sendable {
    case appWide
    case project(String)

    var label: String {
        switch self {
        case .appWide: "App-wide"
        case let .project(name): "Project · \(name)"
        }
    }

    var searchableLabel: String {
        switch self {
        case .appWide: "app wide global user scoped"
        case let .project(name): "project scoped workspace \(name)"
        }
    }
}

enum ExtensionSettingsUpdateState: Equatable, Sendable {
    case bundled
    case local
    case manual(String)

    var label: String {
        switch self {
        case .bundled: "Updates with Kaisola"
        case .local: "Local · no remote updates"
        case let .manual(label): label
        }
    }
}

/// Common presentation metadata across registries. Commands, environment
/// values, headers, and credential material are deliberately absent from the
/// searchable and accessibility projections.
struct ExtensionSettingsItem: Equatable, Sendable {
    let id: String
    let category: ExtensionsSettingsCategory
    let name: String
    let detail: String
    let status: ExtensionSettingsStatus
    let source: ExtensionSettingsSource
    let versionIntegrity: String
    let scope: ExtensionSettingsScope
    let updateState: ExtensionSettingsUpdateState
    let validationMessage: String?

    var stableID: String { "\(category.rawValue):\(id)" }

    var searchableText: String {
        [
            name,
            id,
            detail,
            category.title,
            category.shortTitle,
            status.label,
            source.label,
            versionIntegrity,
            scope.label,
            scope.searchableLabel,
            updateState.label,
            validationMessage ?? "",
        ]
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
    }

    var accessibilityDescription: String {
        var values = [
            name,
            category.title,
            status.label,
            "Source: \(source.label)",
            "Version and integrity: \(versionIntegrity)",
            "Scope: \(scope.label)",
            "Updates: \(updateState.label)",
        ]
        if let validationMessage { values.append("Validation: \(validationMessage)") }
        return values.joined(separator: ", ")
    }

    static func customAgent(
        _ spec: CustomAgentSpec,
        install: InstalledAdapterRecord?
    ) -> Self {
        let validation = spec.acpPackageValidationError
        let status: ExtensionSettingsStatus
        if validation != nil {
            status = .disabled("Needs attention")
        } else if spec.chatEnabled == true, install != nil {
            status = .enabled("Chat enabled")
        } else if spec.chatEnabled == true {
            status = .disabled("Chat unavailable")
        } else {
            status = .enabled("Terminal only")
        }
        let integrity: String
        if let install {
            integrity = "v\(install.resolvedVersion) · lock \(install.lockfileSHA256.prefix(8)) · files \(install.treeSHA256.prefix(8))"
        } else if spec.acpPackage?.isEmpty == false {
            integrity = "No pinned adapter"
        } else {
            integrity = "Terminal command only"
        }
        return Self(
            id: spec.id,
            category: .customAgents,
            name: spec.name.isEmpty ? spec.id : spec.name,
            detail: spec.acpPackage ?? "Terminal only",
            status: status,
            source: .user,
            versionIntegrity: integrity,
            scope: .appWide,
            updateState: install == nil
                ? .manual("Enable chat to install")
                : .manual("Re-enable to approve an update"),
            validationMessage: validation
        )
    }

    static func mcpServer(_ server: McpServerConfig, projectName: String?) -> Self {
        let validation = server.validationError
        let status: ExtensionSettingsStatus = validation == nil
            ? (server.enabled ? .enabled("Enabled") : .disabled("Disabled"))
            : .disabled("Needs attention")
        return Self(
            id: server.id,
            category: .mcpServers,
            name: server.name,
            detail: server.kind.rawValue.uppercased(),
            status: status,
            source: .projectConfiguration,
            versionIntegrity: "Check server to verify version",
            scope: .project(projectName ?? "Current project"),
            updateState: .manual("Checked on demand"),
            validationMessage: validation
        )
    }

    static func builtInTheme(id: String, title: String, selected: Bool) -> Self {
        Self(
            id: id,
            category: .terminalThemes,
            name: title,
            detail: "Bundled terminal palette",
            status: .enabled(selected ? "Active" : "Enabled"),
            source: .builtIn,
            versionIntegrity: "Bundled with Kaisola",
            scope: .appWide,
            updateState: .bundled,
            validationMessage: nil
        )
    }

    static func customTheme(_ spec: CustomThemeSpec, selected: Bool) -> Self {
        let validation = spec.validationError
        return Self(
            id: spec.id,
            category: .terminalThemes,
            name: spec.title.isEmpty ? spec.id : spec.title,
            detail: "Custom light and dark palettes",
            status: validation == nil
                ? .enabled(selected ? "Active" : "Enabled")
                : .disabled("Needs attention"),
            source: .user,
            versionIntegrity: validation == nil ? "Validated palette · 16 ANSI colors" : "Invalid local data",
            scope: .appWide,
            updateState: .local,
            validationMessage: validation
        )
    }

    static func languageGrammar(_ spec: CustomGrammarSpec) -> Self {
        let validation = spec.validationError
        return Self(
            id: spec.id,
            category: .languageGrammars,
            name: spec.title.isEmpty ? spec.id : spec.title,
            detail: spec.normalizedExtensions.map { ".\($0)" }.joined(separator: ", "),
            status: validation == nil ? .enabled("Enabled") : .disabled("Needs attention"),
            source: .user,
            versionIntegrity: validation == nil
                ? "Validated regex · \(spec.rules.count) rule\(spec.rules.count == 1 ? "" : "s")"
                : "Invalid local data",
            scope: .appWide,
            updateState: .local,
            validationMessage: validation
        )
    }

    static func previewMapping(_ spec: PreviewMappingSpec) -> Self {
        let validation = spec.validationError
        return Self(
            id: spec.id,
            category: .previewMappings,
            name: spec.id,
            detail: "\(spec.normalizedExtensions.map { ".\($0)" }.joined(separator: ", ")) → \(spec.kind)",
            status: validation == nil ? .enabled("Enabled") : .disabled("Needs attention"),
            source: .user,
            versionIntegrity: validation == nil ? "Validated text-only mapping" : "Invalid local data",
            scope: .appWide,
            updateState: .local,
            validationMessage: validation
        )
    }

    static func previewMappingRegistryIssue(_ state: PreviewMappingStore.LoadState) -> Self {
        let integrity: String
        let updates: String
        let message: String
        switch state {
        case let .corrupt(.preserved(url)):
            integrity = "Unreadable registry preserved"
            updates = "Reset explicitly to repair"
            message = "Kaisola preserved the unreadable registry as \(url.lastPathComponent). Review that recovery copy, then reset explicitly to repair mappings."
        case .corrupt(.failed):
            integrity = "Unreadable registry not preserved"
            updates = "Resolve storage access before reset"
            message = "Kaisola could not preserve the unreadable registry. Resolve storage access before attempting recovery."
        case let .newerVersion(version, .preserved(url)):
            integrity = "Newer registry v\(version) preserved"
            updates = "Reset explicitly to replace"
            message = "This registry uses schema v\(version), which is newer than Kaisola supports. It was preserved as \(url.lastPathComponent)."
        case let .newerVersion(version, .failed):
            integrity = "Newer registry v\(version) not preserved"
            updates = "Resolve storage access before reset"
            message = "This registry uses unsupported schema v\(version), and Kaisola could not create a recovery copy."
        case .ioFailure:
            integrity = "Registry unavailable"
            updates = "Resolve storage access to continue"
            message = "Kaisola could not read the preview-mapping registry. The file was not changed; resolve storage access and try again."
        case .missing, .ready:
            integrity = "Registry ready"
            updates = "Local · no remote updates"
            message = "The preview-mapping registry is ready."
        }

        return Self(
            id: PreviewMappingStore.registryIssueID,
            category: .previewMappings,
            name: "Preview mapping registry",
            detail: "Recovery required before mappings can change",
            status: .disabled("Needs attention"),
            source: .user,
            versionIntegrity: integrity,
            scope: .appWide,
            updateState: .manual(updates),
            validationMessage: message
        )
    }
}

enum ExtensionsSettingsCatalog {
    static func load(workspace: URL?, selectedThemeID: String) -> [ExtensionSettingsItem] {
        let installRecords = Dictionary(
            uniqueKeysWithValues: AdapterInstallManager.Store().records().map { ($0.agentID, $0) }
        )
        let agents = CustomAgentStore().all().map {
            ExtensionSettingsItem.customAgent($0, install: installRecords[$0.id])
        }
        let projectName = workspace?.lastPathComponent
        let servers = workspace.map { workspace in
            McpConfigStore(workspace: workspace).servers().map {
                ExtensionSettingsItem.mcpServer($0, projectName: projectName)
            }
        } ?? []
        let shippedThemes = TerminalThemeRegistry.shipped.map {
            ExtensionSettingsItem.builtInTheme(
                id: $0.id,
                title: $0.title,
                selected: selectedThemeID == $0.id
            )
        }
        let customThemes = CustomThemeStore().specs().map {
            ExtensionSettingsItem.customTheme($0, selected: selectedThemeID == $0.id)
        }
        let grammars = CustomGrammarStore().specs().map(ExtensionSettingsItem.languageGrammar)
        let mappingSnapshot = PreviewMappingStore().load()
        var mappings = mappingSnapshot.specs.map(ExtensionSettingsItem.previewMapping)
        if !mappingSnapshot.state.allowsMutations {
            mappings.append(.previewMappingRegistryIssue(mappingSnapshot.state))
        }
        return agents + servers + shippedThemes + customThemes + grammars + mappings
    }

    static func filtered(
        _ items: [ExtensionSettingsItem],
        query: String
    ) -> [ExtensionSettingsItem] {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { $0.searchableText.contains(needle) }
    }
}

enum ExtensionsSettingsCollectionState: Equatable, Sendable {
    case loading
    case empty
    case noResults(String)
    case content(invalidCount: Int)

    static func resolve(
        isLoading: Bool,
        allItems: [ExtensionSettingsItem],
        visibleItems: [ExtensionSettingsItem],
        query: String
    ) -> Self {
        if isLoading { return .loading }
        if allItems.isEmpty { return .empty }
        if visibleItems.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .noResults(query)
        }
        return .content(invalidCount: visibleItems.filter { $0.validationMessage != nil }.count)
    }
}

enum ExtensionsSettingsNavigation {
    enum Direction: Sendable { case previous, next }

    static func move(
        from current: ExtensionsSettingsCategory,
        direction: Direction,
        in categories: [ExtensionsSettingsCategory]
    ) -> ExtensionsSettingsCategory {
        guard !categories.isEmpty,
              let index = categories.firstIndex(of: current) else {
            return categories.first ?? current
        }
        switch direction {
        case .next: return categories[(index + 1) % categories.count]
        case .previous: return categories[(index - 1 + categories.count) % categories.count]
        }
    }
}

enum ExtensionsSettingsDraftPolicy {
    static func identifier(_ title: String, existing: Set<String>) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var value = ""
        var lastWasDash = false
        for character in title.lowercased() {
            if allowed.contains(character) {
                value.append(character)
                lastWasDash = false
            } else if !value.isEmpty, !lastWasDash {
                value.append("-")
                lastWasDash = true
            }
        }
        while value.hasSuffix("-") { value.removeLast() }
        let base = value.isEmpty ? "custom-extension" : value
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    static func extensions(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0.isWhitespace }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// No file reads and no writes: visual fixtures and model contracts use the
/// same deterministic, secret-free catalog.
enum ExtensionsSettingsFixture {
    static var items: [ExtensionSettingsItem] {
        let palette = CustomThemeSpec.PaletteSpec(
            background: "#10131A",
            foreground: "#E8ECF3",
            cursor: "#8CB4FF",
            selection: "#34415A",
            ansi: [
                "#171A21", "#E06C75", "#98C379", "#E5C07B",
                "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
                "#5C6370", "#E06C75", "#98C379", "#E5C07B",
                "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF",
            ]
        )
        let agent = CustomAgentSpec(
            id: "custom-reviewer",
            name: "Reviewer",
            launchCommand: "reviewer",
            symbol: "terminal",
            acpPackage: "@example/reviewer@2.4.1",
            credentials: "none",
            chatEnabled: false
        )
        let server = McpServerConfig(
            name: "project-files",
            kind: .stdio,
            command: "filesystem-mcp",
            args: ["--workspace"],
            envPairs: [.init(name: "TOKEN", value: "fixture-secret")],
            enabled: true
        )
        let theme = CustomThemeSpec(
            id: "cafe-theme",
            title: "Café Noir",
            light: palette,
            dark: palette
        )
        let grammar = CustomGrammarSpec(
            id: "broken-grammar",
            title: "Broken grammar",
            extensions: ["task"],
            fences: nil,
            rules: [.init(
                pattern: "(",
                role: "keyword",
                context: nil,
                priority: nil,
                caseInsensitive: nil,
                anchorsMatchLines: nil
            )]
        )
        let mapping = PreviewMappingSpec(
            id: "notes-preview",
            extensions: ["notes"],
            kind: PreviewMappingSpec.Kind.markdown.rawValue
        )
        return [
            .customAgent(agent, install: nil),
            .mcpServer(server, projectName: "Kaisola"),
            .customTheme(theme, selected: true),
            .languageGrammar(grammar),
            .previewMapping(mapping),
        ]
    }
}
