import AppKit
import Combine
import ImageIO
import SwiftUI

/// Navigation layout, mirroring Electron's two modes: a nested project→session
/// tree in a left sidebar, or a top bar with a project tab strip over a session
/// row.
enum NavigationLayout: String, CaseIterable, Identifiable, Sendable {
    case leftTree
    case topBar

    var id: String { rawValue }
    var title: String { self == .leftTree ? "Left Tree" : "Top Bar" }
}

/// Appearance mode. Follows the system by default; shell chrome and the chosen
/// terminal palette both resolve against it.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Sidebar treatment. Glass is the native default; Solid is retained
/// for maximum contrast and Reduce Transparency-style preferences.
enum SidebarAppearance: String, CaseIterable, Identifiable, Sendable {
    case glass
    case solid

    var id: String { rawValue }
    var title: String { self == .glass ? "Glass" : "Solid" }
}

/// The canvas behind workspace surfaces. Terminals keep an opaque, legible
/// palette; this backdrop is visible through navigation chrome, empty states,
/// chats, and lightweight utilities.
enum WorkspaceBackdropMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case glass
    case tinted

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .glass: "Glass"
        case .tinted: "Tinted"
        }
    }
}

/// Terminal color choices. Native is deliberately the default: a high-contrast
/// white/near-black terminal canvas with clear semantic ANSI accents. Kaisola
/// preserves the richer Electron-matched palette for users who prefer it.
enum TerminalPaletteMode: String, CaseIterable, Identifiable, Sendable {
    case native
    case kaisola

    var id: String { rawValue }
    var title: String { self == .native ? "macOS Terminal" : "Kaisola" }
}

/// Provider whose direct-API routing is edited in Settings ▸ Models & Keys.
/// Secrets remain in `ApiKeyStore`; these non-secret values are ordinary app
/// preferences and are safe to show back to the user.
enum DirectAPIProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAI

    var id: String { rawValue }
    var title: String { self == .anthropic ? "Anthropic" : "OpenAI" }
}

/// Validation and process-boundary conversion for custom provider routing.
/// Invalid drafts remain visible in Settings but never reach a child process.
enum ProviderRouting {
    static let maximumBaseURLLength = 2_048
    static let maximumModelLength = 200

    static func baseURLIssue(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= maximumBaseURLLength,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              let components = URLComponents(string: value),
              components.url != nil,
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return "Enter a complete http:// or https:// URL."
        }
        guard components.user == nil, components.password == nil else {
            return "Keep credentials in Keychain, not in the URL."
        }
        guard components.query == nil, components.fragment == nil else {
            return "Base URLs cannot include a query or fragment."
        }
        if scheme == "http", !isLoopback(host) {
            return "Use HTTPS unless the provider runs on this Mac."
        }
        return nil
    }

    static func normalizedBaseURL(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, baseURLIssue(value) == nil else { return nil }
        while value.count > 1, value.hasSuffix("/") {
            return normalizedBaseURL(String(value.dropLast()))
        }
        return value
    }

    static func modelIssue(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= maximumModelLength else {
            return "Model names must be at most \(maximumModelLength) characters."
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return "Model names must fit on one line."
        }
        return nil
    }

    static func normalizedModel(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, modelIssue(value) == nil else { return nil }
        return value
    }

    /// Non-secret routing for direct API tools and the native ACP adapters.
    /// `CODEX_CONFIG` is the adapter's documented JSON session-config seam; a
    /// valid caller-provided object is preserved and the explicit Kaisola
    /// choices win. Malformed inherited JSON is ignored because the adapter
    /// would otherwise terminate while parsing it before initialization.
    static func environmentOverlay(
        anthropicBaseURL: String,
        anthropicModel: String,
        openAIBaseURL: String,
        openAIModel: String,
        baseEnvironment: [String: String]
    ) -> [String: String] {
        var overlay: [String: String] = [:]
        if let value = normalizedBaseURL(anthropicBaseURL) {
            overlay["ANTHROPIC_BASE_URL"] = value
        }
        if let value = normalizedModel(anthropicModel) {
            overlay["ANTHROPIC_MODEL"] = value
        }

        let openAIURL = normalizedBaseURL(openAIBaseURL)
        let openAIModel = normalizedModel(openAIModel)
        if let openAIURL { overlay["OPENAI_BASE_URL"] = openAIURL }
        if let openAIModel { overlay["OPENAI_MODEL"] = openAIModel }

        guard openAIURL != nil || openAIModel != nil else { return overlay }
        var config: [String: Any] = [:]
        if let inherited = baseEnvironment["CODEX_CONFIG"],
           let data = inherited.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any] {
            config = dictionary
        }
        if let openAIURL { config["openai_base_url"] = openAIURL }
        if let openAIModel { config["model"] = openAIModel }
        if JSONSerialization.isValidJSONObject(config),
           let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            overlay["CODEX_CONFIG"] = json
        }
        return overlay
    }

    /// Codex CLI does not read `CODEX_CONFIG`; its documented one-run surface
    /// is `--model` plus `--config key=value`. ACP receives the equivalent JSON
    /// above. This keeps both native surfaces aligned without touching a user's
    /// own `config.toml` or selected `CODEX_HOME`.
    static func codexLaunchCommand(
        _ baseCommand: String,
        openAIBaseURL: String,
        openAIModel: String
    ) -> String {
        var command = baseCommand
        if let model = normalizedModel(openAIModel) {
            command += " --model \(shellQuote(model))"
        }
        if let baseURL = normalizedBaseURL(openAIBaseURL) {
            let override = "openai_base_url=\(tomlString(baseURL))"
            command += " --config \(shellQuote(override))"
        }
        return command
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { octet in
            guard let value = Int(octet) else { return false }
            return (0...255).contains(value)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// App-wide preview settings, persisted in UserDefaults under the preview's own
/// suite so they never touch any Electron profile.
@MainActor
final class NativePreviewSettings: ObservableObject {
    /// Visual fixtures run the complete production view hierarchy in their own
    /// short-lived process. They must not rewrite the real user's layout,
    /// appearance, or terminal preferences merely because QA needs a
    /// deterministic screenshot.
    static let shared: NativePreviewSettings = {
        let environment = ProcessInfo.processInfo.environment
        guard let suite = isolatedFixtureSuiteName(
            environment: environment,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        ) else {
            return NativePreviewSettings()
        }
        let defaults = UserDefaults(suiteName: suite)!
        let settings = NativePreviewSettings(defaults: defaults, persistsChanges: false)
        if environment["KAISOLA_NATIVE_RESOURCE_WORKLOAD"] != nil {
            settings.terminalScrollbackLines = 5_000
            settings.appearance = .light
            settings.sidebarAppearance = .solid
            settings.workspaceBackdrop = .system
            settings.semanticShellIntegration = false
        }
        return settings
    }()

    nonisolated static func isIsolatedFixture(environment: [String: String]) -> Bool {
        environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
            || environment["KAISOLA_NATIVE_RESOURCE_WORKLOAD"] != nil
    }

    nonisolated static func isolatedFixtureSuiteName(
        environment: [String: String],
        processIdentifier: Int32
    ) -> String? {
        guard isIsolatedFixture(environment: environment) else { return nil }
        let kind = environment["KAISOLA_NATIVE_RESOURCE_WORKLOAD"] == nil
            ? "visual-fixture"
            : "resource-fixture"
        return "com.kaisola.mac.\(kind).\(processIdentifier)"
    }

    nonisolated static func shouldPersistChanges(environment: [String: String]) -> Bool {
        !isIsolatedFixture(environment: environment)
    }

    @Published var navigationLayout: NavigationLayout {
        didSet { persist(navigationLayout.rawValue, forKey: Keys.layout) }
    }

    @Published var appearance: AppearanceMode {
        didSet {
            persist(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    @Published var sidebarAppearance: SidebarAppearance {
        didSet { persist(sidebarAppearance.rawValue, forKey: Keys.sidebarAppearance) }
    }

    @Published var workspaceBackdrop: WorkspaceBackdropMode {
        didSet { persist(workspaceBackdrop.rawValue, forKey: Keys.workspaceBackdrop) }
    }

    /// Terminal font size (⌘+/⌘−/⌘0), clamped to a readable range.
    @Published var terminalFontSize: Double {
        didSet { persist(terminalFontSize, forKey: Keys.terminalFontSize) }
    }

    static let terminalFontRange: ClosedRange<Double> = 9...22
    /// macOS Terminal's current Basic profile uses 11 pt regular text.
    static let terminalFontDefault: Double = 11

    /// Terminal font family ("System Mono" sentinel = SF Mono) and weight.
    @Published var terminalFontFamily: String {
        didSet { persist(terminalFontFamily, forKey: Keys.terminalFontFamily) }
    }

    @Published var terminalFontWeight: String {
        didSet { persist(terminalFontWeight, forKey: Keys.terminalFontWeight) }
    }

    /// Terminal row-height multiplier. Keeping this in SwiftTerm's renderer
    /// preserves cursor, selection, and resize geometry while letting users
    /// choose between a compact shell and slightly more breathable output.
    @Published var terminalLineSpacing: Double {
        didSet {
            let clamped = Self.clampedTerminalLineSpacing(terminalLineSpacing)
            if clamped != terminalLineSpacing {
                terminalLineSpacing = clamped
                return
            }
            persist(clamped, forKey: Keys.terminalLineSpacing)
        }
    }

    static let terminalLineSpacingRange: ClosedRange<Double> = 1.0...1.24
    /// Match Terminal.app's 1.00 row-height multiplier by default.
    static let terminalLineSpacingDefault: Double = 1.0

    /// How many lines of scrollback each terminal keeps.
    ///
    /// SwiftTerm's `TerminalOptions` default is **500**, and the native app
    /// never overrode it — so scrolling up stopped after roughly a dozen
    /// screens. The Electron terminal it replaced ran 5000, which is the number
    /// users are actually comparing against.
    ///
    /// This is applied with `TerminalView.changeScrollback(_:)` at view
    /// construction. That is durable: SwiftTerm's resize, font change, theme
    /// flip, and `resetToInitialState` all rebuild from `options.scrollback`,
    /// which this call has already updated — only `setup()` at init rebuilds the
    /// options wholesale.
    @Published var terminalScrollbackLines: Int {
        didSet {
            let clamped = Self.clampedTerminalScrollback(terminalScrollbackLines)
            if clamped != terminalScrollbackLines {
                terminalScrollbackLines = clamped
                return
            }
            persist(clamped, forKey: Keys.terminalScrollbackLines)
        }
    }

    /// SwiftTerm materialises a full-width `BufferLine` for every retained row.
    /// A measured 64 MiB / 100 000-row fixture therefore reached 432.6 MiB p95;
    /// the same bytes at 20 000 live rows reached 297.2 MiB. The broker remains
    /// the lossless history owner, and continued upward scrolling at row zero
    /// opens its paged transcript, so bounding the interactive renderer does
    /// not bound how far back the user can read.
    ///
    /// Keep 100 000 available as an explicit high-memory choice, but use the
    /// measured 20 000-row tier for fresh and legacy-default installations.
    static let terminalScrollbackRange: ClosedRange<Int> = 500...100_000
    static let terminalScrollbackDefault = 20_000
    static let terminalScrollbackPolicyVersion = 2

    static func clampedTerminalScrollback(_ lines: Int) -> Int {
        min(max(lines, terminalScrollbackRange.lowerBound), terminalScrollbackRange.upperBound)
    }

    /// A soft per-terminal disk threshold. Interactive history remains
    /// append-only until the terminal is explicitly closed; crossing this
    /// value surfaces a warning instead of silently deleting the first byte.
    @Published var terminalHistoryWarningMiB: Int {
        didSet {
            let clamped = Self.clampedTerminalHistoryWarning(terminalHistoryWarningMiB)
            if clamped != terminalHistoryWarningMiB {
                terminalHistoryWarningMiB = clamped
                return
            }
            persist(clamped, forKey: Keys.terminalHistoryWarningMiB)
        }
    }

    nonisolated static let terminalHistoryWarningChoicesMiB = [256, 512, 1_024, 2_048, 4_096]
    nonisolated static let terminalHistoryWarningDefaultMiB = 1_024

    nonisolated static func clampedTerminalHistoryWarning(_ value: Int) -> Int {
        terminalHistoryWarningChoicesMiB.min {
            abs($0 - value) < abs($1 - value)
        } ?? terminalHistoryWarningDefaultMiB
    }

    @Published var terminalPalette: TerminalPaletteMode {
        didSet { persist(terminalPalette.rawValue, forKey: Keys.terminalPalette) }
    }

    /// Retype a privately persisted, unsent CLI composer draft only after a
    /// provider continuation reaches a quiet prompt. The restore is cancelled
    /// as soon as the user starts interacting with that new terminal.
    @Published var restoreCLIDrafts: Bool {
        didSet { persist(restoreCLIDrafts, forKey: Keys.restoreCLIDrafts) }
    }

    /// Opt-in while the shell-injection compatibility matrix is still being
    /// proven. New zsh sessions use app-owned startup files that source (but do
    /// not edit) the user's configuration and emit semantic command marks.
    @Published var semanticShellIntegration: Bool {
        didSet { persist(semanticShellIntegration, forKey: Keys.semanticShellIntegration) }
    }

    /// Whether the workspace rail (file tree, ⌘B) is shown.
    @Published var workspaceRailVisible: Bool {
        didSet { persist(workspaceRailVisible, forKey: Keys.workspaceRail) }
    }

    /// Width of the right-hand file rail. This is app-owned instead of an
    /// `HSplitView` autosave so a stale AppKit divider can never reopen Files at
    /// half the window. The deliberately narrow default keeps the terminal the
    /// primary canvas while still leaving the rail smoothly resizable.
    @Published var workspaceRailWidth: Double {
        didSet {
            let clamped = Self.clampedWorkspaceRailWidth(workspaceRailWidth)
            if clamped != workspaceRailWidth {
                workspaceRailWidth = clamped
                return
            }
            if !defersPanelPersistence {
                persist(clamped, forKey: Keys.workspaceRailWidth)
            }
        }
    }

    static let workspaceRailWidthRange: ClosedRange<Double> = 164...300
    static let workspaceRailWidthDefault: Double = 196

    /// Width of the document preview beside the active terminal/chat. App-owned
    /// sizing avoids HSplitView's stale autosaved dividers and gives us a broad,
    /// discoverable hit target without drawing a heavy separator.
    @Published var filePreviewWidth: Double {
        didSet {
            let clamped = Self.clampedFilePreviewWidth(filePreviewWidth)
            if clamped != filePreviewWidth {
                filePreviewWidth = clamped
                return
            }
            if !defersPanelPersistence {
                persist(clamped, forKey: Keys.filePreviewWidth)
            }
        }
    }

    static let filePreviewWidthRange: ClosedRange<Double> = 300...920
    static let filePreviewWidthDefault: Double = 480

    /// Sensitive-file globs the guardrails enforce (always prompt, never
    /// rule-coverable, fs bridge refuses them). Editable in Settings.
    @Published var sensitiveGlobs: [String] {
        didSet { persist(sensitiveGlobs, forKey: Keys.sensitiveGlobs) }
    }

    /// Per-agent account isolation: a custom CLAUDE_CONFIG_DIR / CODEX_HOME
    /// applied to agent terminals and ACP adapters. Empty = the CLI default.
    @Published var claudeConfigDir: String {
        didSet { persist(claudeConfigDir, forKey: Keys.claudeConfigDir) }
    }

    @Published var codexHome: String {
        didSet { persist(codexHome, forKey: Keys.codexHome) }
    }

    /// Non-secret direct-provider routing. Blank values retain each provider's
    /// own default. Invalid drafts are persisted so the user can correct them,
    /// but `ProviderRouting` refuses to inject them into child processes.
    @Published var anthropicBaseURL: String {
        didSet { persist(anthropicBaseURL, forKey: Keys.anthropicBaseURL) }
    }

    @Published var anthropicModel: String {
        didSet { persist(anthropicModel, forKey: Keys.anthropicModel) }
    }

    @Published var openAIBaseURL: String {
        didSet { persist(openAIBaseURL, forKey: Keys.openAIBaseURL) }
    }

    @Published var openAIModel: String {
        didSet { persist(openAIModel, forKey: Keys.openAIModel) }
    }

    /// Application name for "Open in External Editor" (⇧⌘O), e.g.
    /// "Visual Studio Code" / "Cursor" / "Zed". Empty = the system default
    /// app for the file's type.
    @Published var externalEditorApp: String {
        didSet { persist(externalEditorApp, forKey: Keys.externalEditorApp) }
    }

    /// Open a file (or directory) in the chosen external editor.
    func openInExternalEditor(_ url: URL) {
        let app = externalEditorApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app, url.path]
        try? process.run()
    }

    /// Environment overlay for agent processes from the account settings.
    var agentEnvironmentOverlay: [String: String] {
        // API keys join first; the explicit account vars below always win.
        var env = ApiKeyStore().environmentOverlay()
        env.merge(ProviderRouting.environmentOverlay(
            anthropicBaseURL: anthropicBaseURL,
            anthropicModel: anthropicModel,
            openAIBaseURL: openAIBaseURL,
            openAIModel: openAIModel,
            baseEnvironment: ProcessInfo.processInfo.environment
        )) { _, routing in routing }
        let claude = claudeConfigDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !claude.isEmpty { env["CLAUDE_CONFIG_DIR"] = (claude as NSString).expandingTildeInPath }
        let codex = codexHome.trimmingCharacters(in: .whitespacesAndNewlines)
        if !codex.isEmpty { env["CODEX_HOME"] = (codex as NSString).expandingTildeInPath }
        return env
    }

    private let defaults: UserDefaults
    private let persistsChanges: Bool
    private var defersPanelPersistence = false

    /// Divider drags update SwiftUI continuously but persist only once at the
    /// end. This removes synchronous UserDefaults traffic from pointer tracking.
    func beginPanelResize() {
        defersPanelPersistence = true
    }

    func endPanelResize() {
        defersPanelPersistence = false
        persist(workspaceRailWidth, forKey: Keys.workspaceRailWidth)
        persist(filePreviewWidth, forKey: Keys.filePreviewWidth)
    }

    private enum Keys {
        static let layout = "navigationLayout"
        static let appearance = "appearanceMode"
        static let sidebarAppearance = "sidebarAppearance"
        static let workspaceBackdrop = "workspaceBackdrop"
        static let terminalFontSize = "terminalFontSize"
        static let terminalFontFamily = "terminalFontFamily"
        static let terminalFontWeight = "terminalFontWeight"
        static let terminalLineSpacing = "terminalLineSpacing"
        static let terminalScrollbackLines = "terminalScrollbackLines"
        static let terminalScrollbackPolicyVersion = "terminalScrollbackPolicyVersion"
        static let terminalHistoryWarningMiB = "terminalHistoryWarningMiB"
        static let terminalPalette = "terminalPalette"
        static let restoreCLIDrafts = "restoreCLIDrafts"
        static let semanticShellIntegration = "semanticShellIntegration"
        static let workspaceRail = "workspaceRailVisible"
        static let workspaceRailWidth = "workspaceRailWidth"
        static let filePreviewWidth = "filePreviewWidth"
        static let sensitiveGlobs = "sensitiveGlobs"
        static let claudeConfigDir = "claudeConfigDir"
        static let codexHome = "codexHome"
        static let anthropicBaseURL = "anthropicBaseURL"
        static let anthropicModel = "anthropicModel"
        static let openAIBaseURL = "openAIBaseURL"
        static let openAIModel = "openAIModel"
        static let externalEditorApp = "externalEditorApp"
    }

    init(defaults: UserDefaults = .standard, persistsChanges: Bool = true) {
        self.defaults = defaults
        self.persistsChanges = persistsChanges
        navigationLayout = defaults.string(forKey: Keys.layout).flatMap(NavigationLayout.init) ?? .leftTree
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init) ?? .system
        sidebarAppearance = defaults.string(forKey: Keys.sidebarAppearance).flatMap(SidebarAppearance.init) ?? .glass
        workspaceBackdrop = defaults.string(forKey: Keys.workspaceBackdrop).flatMap(WorkspaceBackdropMode.init) ?? .glass
        let stored = defaults.double(forKey: Keys.terminalFontSize)
        terminalFontSize = stored > 0
            ? min(max(stored, Self.terminalFontRange.lowerBound), Self.terminalFontRange.upperBound)
            : Self.terminalFontDefault
        workspaceRailVisible = defaults.object(forKey: Keys.workspaceRail) as? Bool ?? true
        let storedRailWidth = defaults.double(forKey: Keys.workspaceRailWidth)
        workspaceRailWidth = storedRailWidth > 0
            ? Self.clampedWorkspaceRailWidth(storedRailWidth)
            : Self.workspaceRailWidthDefault
        let storedPreviewWidth = defaults.double(forKey: Keys.filePreviewWidth)
        filePreviewWidth = storedPreviewWidth > 0
            ? Self.clampedFilePreviewWidth(storedPreviewWidth)
            : Self.filePreviewWidthDefault
        terminalFontFamily = defaults.string(forKey: Keys.terminalFontFamily) ?? TerminalFontOptions.systemMonoSentinel
        terminalFontWeight = defaults.string(forKey: Keys.terminalFontWeight) ?? "regular"
        let storedLineSpacing = defaults.double(forKey: Keys.terminalLineSpacing)
        terminalLineSpacing = storedLineSpacing > 0
            ? Self.clampedTerminalLineSpacing(storedLineSpacing)
            : Self.terminalLineSpacingDefault
        let storedScrollback = defaults.integer(forKey: Keys.terminalScrollbackLines)
        let storedScrollbackPolicyVersion = defaults.integer(
            forKey: Keys.terminalScrollbackPolicyVersion
        )
        // Version 1 temporarily made 100 000 the implicit default. Migrate that
        // exact value once now that lossless broker paging is the continuation
        // path; after the marker is written, an explicit 100 000-row choice is
        // preserved. Older custom depths remain untouched.
        let migratesLegacyMaximum = storedScrollbackPolicyVersion < Self.terminalScrollbackPolicyVersion
            && storedScrollback == Self.terminalScrollbackRange.upperBound
        let resolvedScrollback = migratesLegacyMaximum
            ? Self.terminalScrollbackDefault
            : storedScrollback > 0
            ? Self.clampedTerminalScrollback(storedScrollback)
            : Self.terminalScrollbackDefault
        terminalScrollbackLines = resolvedScrollback
        if persistsChanges, storedScrollbackPolicyVersion < Self.terminalScrollbackPolicyVersion {
            defaults.set(resolvedScrollback, forKey: Keys.terminalScrollbackLines)
            defaults.set(
                Self.terminalScrollbackPolicyVersion,
                forKey: Keys.terminalScrollbackPolicyVersion
            )
        }
        let storedHistoryWarning = defaults.integer(forKey: Keys.terminalHistoryWarningMiB)
        terminalHistoryWarningMiB = storedHistoryWarning > 0
            ? Self.clampedTerminalHistoryWarning(storedHistoryWarning)
            : Self.terminalHistoryWarningDefaultMiB
        terminalPalette = defaults.string(forKey: Keys.terminalPalette).flatMap(TerminalPaletteMode.init) ?? .native
        restoreCLIDrafts = defaults.object(forKey: Keys.restoreCLIDrafts) as? Bool ?? true
        semanticShellIntegration = defaults.object(forKey: Keys.semanticShellIntegration) as? Bool ?? false
        sensitiveGlobs = defaults.stringArray(forKey: Keys.sensitiveGlobs) ?? AcpPermissionRules.defaultSensitiveGlobs
        claudeConfigDir = defaults.string(forKey: Keys.claudeConfigDir) ?? ""
        codexHome = defaults.string(forKey: Keys.codexHome) ?? ""
        anthropicBaseURL = defaults.string(forKey: Keys.anthropicBaseURL) ?? ""
        anthropicModel = defaults.string(forKey: Keys.anthropicModel) ?? ""
        openAIBaseURL = defaults.string(forKey: Keys.openAIBaseURL) ?? ""
        openAIModel = defaults.string(forKey: Keys.openAIModel) ?? ""
        externalEditorApp = defaults.string(forKey: Keys.externalEditorApp) ?? ""
    }

    private func persist(_ value: Any?, forKey key: String) {
        guard persistsChanges else { return }
        defaults.set(value, forKey: key)
    }

    /// Push the chosen appearance to the running application.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    func adjustTerminalFont(by delta: Double) {
        terminalFontSize = min(
            max(terminalFontSize + delta, Self.terminalFontRange.lowerBound),
            Self.terminalFontRange.upperBound
        )
    }

    func resetTerminalFont() {
        terminalFontSize = Self.terminalFontDefault
    }

    /// Restore the stable, public-facing aspects of Terminal.app's Basic
    /// profile. Apple does not expose its private renderer as an embeddable
    /// view, so Kaisola mirrors its typography and native ANSI palette while
    /// retaining a fixed-pitch font required for correct terminal geometry.
    func applyTerminalAppDefaults() {
        terminalFontSize = Self.terminalFontDefault
        terminalFontFamily = TerminalFontOptions.systemMonoSentinel
        terminalFontWeight = "regular"
        terminalLineSpacing = Self.terminalLineSpacingDefault
        terminalPalette = .native
    }

    static func clampedWorkspaceRailWidth(_ width: Double) -> Double {
        min(max(width, workspaceRailWidthRange.lowerBound), workspaceRailWidthRange.upperBound)
    }

    static func clampedFilePreviewWidth(_ width: Double) -> Double {
        min(max(width, filePreviewWidthRange.lowerBound), filePreviewWidthRange.upperBound)
    }

    static func clampedTerminalLineSpacing(_ spacing: Double) -> Double {
        min(max(spacing, terminalLineSpacingRange.lowerBound), terminalLineSpacingRange.upperBound)
    }
}

/// Shared native visual grammar. Glass belongs to navigation and controls;
/// terminals, transcripts, and documents intentionally remain opaque.
enum KaisolaVisualSystem {
    static let controlRadius: CGFloat = 7
    static let insetRadius: CGFloat = 10
    static let cardRadius: CGFloat = 12
    static let shellRadius: CGFloat = 16
    static let hairline: CGFloat = 0.5
    static let focusStroke: CGFloat = 1
    /// Sidebar row leading glyphs (terminal, chat, mesh). Deliberately small:
    /// the row's scarce resource is horizontal space for the session title, and
    /// the agent name is already the title's prefix, so the glyph is a texture
    /// cue rather than the identifying signal.
    static let rowIconSize: CGFloat = 15
    static let rowIconGlyph: CGFloat = 10
    static let rowIconRadius: CGFloat = 4
    static let hoverDuration = 0.09
    static let stateDuration = 0.14
    static let layoutDuration = 0.22
}

private struct KaisolaControlSurfaceModifier: ViewModifier {
    let active: Bool
    let tint: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var accessibilityContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: KaisolaVisualSystem.controlRadius,
            style: .continuous
        )
        let strokeOpacity = accessibilityContrast == .increased ? 0.22 : (active ? 0.12 : 0.07)

        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: KaisolaVisualSystem.hairline))
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content
                    .glassEffect(
                        .regular
                            .tint(tint?.opacity(active ? 0.16 : 0.08))
                            .interactive(interactive),
                        in: shape
                    )
                    .overlay(shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: KaisolaVisualSystem.hairline))
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: KaisolaVisualSystem.hairline))
            }
            #else
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: KaisolaVisualSystem.hairline))
            #endif
        }
    }
}

extension View {
    /// Adaptive Liquid Glass on macOS 26, with a semantic material fallback on
    /// macOS 14/15 and a solid surface when Reduce Transparency is enabled.
    func kaisolaControlSurface(
        active: Bool = false,
        tint: Color? = nil,
        interactive: Bool = true
    ) -> some View {
        modifier(KaisolaControlSurfaceModifier(active: active, tint: tint, interactive: interactive))
    }
}

/// Groups nearby macOS 26 glass controls so the system can render and morph
/// them as one efficient material region. Older systems simply render the same
/// control hierarchy with the per-control semantic material fallback.
struct KaisolaGlassEffectGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(spacing: CGFloat = 4, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// AppKit's real behind-window vibrancy. SwiftUI's Material samples only the
/// app's own backing surface in this full-size transparent window, which made
/// the previous "Glass" setting look indistinguishable from flat gray.
struct NativeVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .followsWindowActiveState
        view.material = material
        view.blendingMode = blendingMode
    }
}

/// Reusable material used by both the project sidebar and the workspace file
/// rail, keeping the two left-hand navigation surfaces visually coherent.
struct SidebarBackdropView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    let appearance: SidebarAppearance

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .glass:
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                ZStack {
                    NativeVisualEffectView(material: .sidebar)
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.035 : 0.065),
                            Color.accentColor.opacity(colorScheme == .dark ? 0.05 : 0.02),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if accessibilityContrast == .increased {
                        Color(nsColor: .controlBackgroundColor).opacity(0.18)
                    }
                }
            }
        case .solid:
            Color(nsColor: .controlBackgroundColor)
        }
    }
}

struct DesktopTintComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
}

enum DesktopTintSampler {
    private static let fallback = DesktopTintComponents(red: 0.38, green: 0.43, blue: 0.49)

    static func sample(url: URL?) -> DesktopTintComponents {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return fallback
        }

        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return fallback }
        return cooledAverage(rgba: pixels) ?? fallback
    }

    /// Wallpaper color remains recognizable, with chroma compressed and mixed
    /// toward a cool slate. This keeps tinted mode adaptive without turning a
    /// blue desktop into a blue-on-blue application chrome.
    static func cooledAverage(rgba: [UInt8]) -> DesktopTintComponents? {
        guard rgba.count >= 4 else { return nil }
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0
        var index = 0
        while index + 3 < rgba.count {
            let alpha = Double(rgba[index + 3]) / 255
            if alpha > 0.05 {
                red += Double(rgba[index]) / 255
                green += Double(rgba[index + 1]) / 255
                blue += Double(rgba[index + 2]) / 255
                count += 1
            }
            index += 4
        }
        guard count > 0 else { return nil }
        let wallpaper = (red / count, green / count, blue / count)
        let luminance = wallpaper.0 * 0.2126 + wallpaper.1 * 0.7152 + wallpaper.2 * 0.0722
        let chroma = 0.45
        let softened = (
            luminance + (wallpaper.0 - luminance) * chroma,
            luminance + (wallpaper.1 - luminance) * chroma,
            luminance + (wallpaper.2 - luminance) * chroma
        )
        let slate = (0.35, 0.42, 0.50)
        let mix = 0.18
        return DesktopTintComponents(
            red: min(0.82, max(0.14, softened.0 * (1 - mix) + slate.0 * mix)),
            green: min(0.84, max(0.16, softened.1 * (1 - mix) + slate.1 * mix)),
            blue: min(0.86, max(0.20, softened.2 * (1 - mix) + slate.2 * mix))
        )
    }
}

@MainActor
final class DesktopTintProvider: ObservableObject {
    @Published private(set) var components = DesktopTintComponents(
        red: 0.38,
        green: 0.43,
        blue: 0.49
    )
    private var refreshTask: Task<Void, Never>?
    private var lastURL: URL?

    var color: Color {
        Color(red: components.red, green: components.green, blue: components.blue)
    }

    func refresh() {
        let url = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        guard url != lastURL else { return }
        lastURL = url
        refreshTask?.cancel()
        refreshTask = Task {
            let sampled = await Task.detached(priority: .utility) {
                DesktopTintSampler.sample(url: url)
            }.value
            guard !Task.isCancelled else { return }
            components = sampled
        }
    }
}

struct WorkspaceBackdropView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var desktopTint = DesktopTintProvider()
    let mode: WorkspaceBackdropMode

    var body: some View {
        backdrop
            .onAppear { if mode == .tinted { desktopTint.refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if mode == .tinted { desktopTint.refresh() }
            }
    }

    @ViewBuilder
    private var backdrop: some View {
        switch mode {
        case .system:
            Color(nsColor: .windowBackgroundColor)
        case .glass:
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    NativeVisualEffectView(material: .underWindowBackground)
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.028),
                            Color.clear,
                            Color.purple.opacity(0.018),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
        case .tinted:
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        desktopTint.color.opacity(colorScheme == .dark ? 0.15 : 0.10),
                        desktopTint.color.opacity(colorScheme == .dark ? 0.08 : 0.045),
                        WorkspacePalette.mesh.opacity(colorScheme == .dark ? 0.025 : 0.014),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}
