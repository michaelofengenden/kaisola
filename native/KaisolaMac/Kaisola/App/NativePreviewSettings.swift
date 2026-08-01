import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
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

/// Where the glass surfaces get the desktop they show through themselves.
///
/// The two settings map onto the same live/painted/eco split the Electron shell
/// used, now that the native app has a painted mode worth defaulting to:
///
/// - **`wallpaper` (painted, the default)** — a heavily blurred copy of the
///   desktop picture, pre-rendered once per desktop and reused. This is the
///   only mode that answers the actual request: glass that shows the *desktop*
///   and never the app windows stacked behind Kaisola. It is also the cheapest,
///   because nothing samples or re-composites while the app is idle.
/// - **`behindWindow` (live)** — AppKit's `NSVisualEffectView` behind-window
///   vibrancy, which is a genuine live sample and therefore genuinely shows
///   Safari, Xcode, and everything else that happens to be underneath. Kept as
///   an explicit choice for people who *want* that classic macOS depth.
/// - *eco* has no separate setting here: `SidebarAppearance.solid` and
///   `WorkspaceBackdropMode.system` already are the flat, still, zero-sampling
///   surfaces that mode described, and Reduce Transparency selects them
///   automatically.
enum GlassBackdropSource: String, CaseIterable, Identifiable, Sendable {
    case wallpaper
    case behindWindow

    var id: String { rawValue }
    var title: String { self == .wallpaper ? "Wallpaper" : "Live" }
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

    @Published var glassBackdropSource: GlassBackdropSource {
        didSet { persist(glassBackdropSource.rawValue, forKey: Keys.glassBackdropSource) }
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

    /// Whether OSC 52 may put text on the user's system clipboard.
    ///
    /// Off by default: anything running in a terminal — an agent CLI, a build
    /// script, something on the far end of an SSH session — can emit OSC 52,
    /// and silently replacing what the user is about to paste into a shell is
    /// a real attack, not a hypothetical one. Reading the clipboard is never
    /// granted by this setting. See `TerminalClipboardWriteRequest`.
    @Published var terminalClipboardWriteAllowed: Bool {
        didSet { persist(terminalClipboardWriteAllowed, forKey: Keys.terminalClipboardWriteAllowed) }
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
        static let glassBackdropSource = "glassBackdropSource"
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
        static let terminalClipboardWriteAllowed = "terminalClipboardWriteAllowed"
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
        glassBackdropSource = defaults.string(forKey: Keys.glassBackdropSource)
            .flatMap(GlassBackdropSource.init) ?? .wallpaper
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
        terminalClipboardWriteAllowed = defaults.object(forKey: Keys.terminalClipboardWriteAllowed) as? Bool ?? false
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
    /// Safari's inset floating-card chrome: the radius of the sidebar and
    /// detail panels that float over the window backdrop. Larger than
    /// `cardRadius` (which belongs to session cards *inside* a panel) and
    /// smaller than `shellRadius` (the window itself).
    static let chromeRadius: CGFloat = 15
    /// The gutter of window backdrop left visible around each chrome panel.
    static let chromeInset: CGFloat = 6
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

/// The neutral veil laid over AppKit vibrancy — or over the sampled desktop
/// tint — for the two large backdrops.
///
/// Methodology: light mode is white-led (white at roughly a third coverage),
/// dark mode is a near-black neutral (`#0B0C12`). The recipe carries no accent,
/// mesh, or slate stop, so the only chroma that reaches the eye is whatever the
/// desktop itself contributes: saturation-forward, with zero warm or lavender
/// bias. The three opacities describe one vertical gradient of the *same*
/// color, so the top-light edge reads as light direction rather than as a tint.
/// Keeping the numbers separate from the material makes the light/dark balance
/// deterministic and gives appearance tests a stable contract.
struct GlassBackdropWash: Equatable, Sendable {
    /// `#0B0C12`: a near-black that still reads neutral at high coverage.
    static let darkVeil = (red: 11.0 / 255, green: 12.0 / 255, blue: 18.0 / 255)

    let red: Double
    let green: Double
    let blue: Double
    /// Coverage at the top-leading corner (lit edge).
    let topOpacity: Double
    /// Coverage across the body of the backdrop — the headline value.
    let baseOpacity: Double
    /// Coverage at the bottom-trailing corner (settled edge).
    let bottomOpacity: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// One neutral gradient. In light mode the top carries *more* white; in
    /// dark mode it carries *less* near-black. Both read as light from above.
    var veil: LinearGradient {
        LinearGradient(
            colors: [
                color.opacity(topOpacity),
                color.opacity(baseOpacity),
                color.opacity(bottomOpacity),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func dark(top: Double, base: Double, bottom: Double) -> GlassBackdropWash {
        GlassBackdropWash(
            red: darkVeil.red,
            green: darkVeil.green,
            blue: darkVeil.blue,
            topOpacity: top,
            baseOpacity: base,
            bottomOpacity: bottom
        )
    }

    private static func light(top: Double, base: Double, bottom: Double) -> GlassBackdropWash {
        GlassBackdropWash(
            red: 1,
            green: 1,
            blue: 1,
            topOpacity: top,
            baseOpacity: base,
            bottomOpacity: bottom
        )
    }

    /// The sidebar's veil is the *thinnest* surface in the app on purpose: it
    /// is the one large area whose whole job is to read as the desktop seen
    /// through glass. The retuned v1.1 values (light 0.42/0.32/0.26, dark
    /// 0.38/0.44/0.52) covered the vibrancy layer so completely that a
    /// saturated desktop reached the eye with no measurable chroma at all —
    /// the column rendered as flat #EDEDED over a blue desktop. These halve
    /// that coverage; the sidebar chrome panel above them no longer adds a
    /// second opaque material, so the two changes compound.
    static func sidebar(isDark: Bool) -> GlassBackdropWash {
        isDark
            ? dark(top: 0.20, base: 0.26, bottom: 0.34)
            : light(top: 0.24, base: 0.16, bottom: 0.12)
    }

    /// How much of the composited backdrop is still the desktop's own colour
    /// rather than the veil — `1 - baseOpacity`, named so the appearance
    /// contract can be stated as "the desktop must survive", which is the
    /// property that actually regressed.
    var desktopTransmission: Double { 1 - baseOpacity }

    /// The workspace sits one step deeper than the sidebar so the inset chrome
    /// panels have something to float above: less white in light mode, more
    /// near-black in dark mode.
    static func workspace(isDark: Bool) -> GlassBackdropWash {
        isDark
            ? dark(top: 0.26, base: 0.32, bottom: 0.40)
            : light(top: 0.18, base: 0.11, bottom: 0.08)
    }

    /// Increased Contrast lays a flat neutral overlay on top of the veil so
    /// low-vision users get a more opaque, more legible backdrop. Before the
    /// halving above, that overlay was a single constant (0.18) sized for the
    /// *pre-halving* base coverage — sidebar light 0.32 / dark 0.44,
    /// workspace light 0.26 / dark 0.50. Halving the veil's own coverage
    /// without re-deriving this compensation left Increased Contrast mode
    /// proportionally *less* opaque than it was before the retune: exactly
    /// backwards for an accessibility setting.
    ///
    /// Two translucent layers stacked with standard "over" compositing
    /// combine to a total coverage of `base + overlay * (1 - base)` — the
    /// overlay only paints the sliver of the surface the base veil left
    /// uncovered. Solving that for `overlay` so today's thinner `newBase`
    /// still reaches the coverage the old `oldBase` used to reach once the
    /// old flat overlay was stacked on top of it:
    ///
    ///     oldComposite = oldBase + priorOverlay * (1 - oldBase)
    ///     overlay      = (oldComposite - newBase) / (1 - newBase)
    ///
    /// gives the exact per-surface replacement for the flat constant.
    /// `newBase` is read live from `sidebar(isDark:)` / `workspace(isDark:)`
    /// rather than duplicated as a literal, so a future veil retune that
    /// thins the base further automatically raises this compensation instead
    /// of silently falling behind again. Clamped to `[priorOverlay, 0.6]` so
    /// the result can only be *more* protective than the historical flat
    /// value, never less, and never runs away toward an opaque panel.
    private static func increasedContrastOverlay(
        oldBase: Double,
        newBase: Double,
        priorOverlay: Double = 0.18
    ) -> Double {
        let oldComposite = oldBase + priorOverlay * (1 - oldBase)
        let required = (oldComposite - newBase) / (1 - newBase)
        return min(0.6, max(priorOverlay, required))
    }

    /// Increased Contrast overlay opacity for the sidebar veil, scaled to
    /// restore the pre-halving (0.32 light / 0.44 dark) composite coverage
    /// over whatever the current base opacity is.
    static func sidebarIncreasedContrastOverlay(isDark: Bool) -> Double {
        let oldBase = isDark ? 0.44 : 0.32
        return increasedContrastOverlay(oldBase: oldBase, newBase: sidebar(isDark: isDark).baseOpacity)
    }

    /// Increased Contrast overlay opacity for the workspace veil, scaled to
    /// restore the pre-halving (0.26 light / 0.50 dark) composite coverage
    /// over whatever the current base opacity is.
    static func workspaceIncreasedContrastOverlay(isDark: Bool) -> Double {
        let oldBase = isDark ? 0.50 : 0.26
        return increasedContrastOverlay(oldBase: oldBase, newBase: workspace(isDark: isDark).baseOpacity)
    }
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

    /// Safari's inset floating-card chrome. The window backdrop stays visible
    /// in a gutter around the panel; the content rides a rounded material with
    /// a hairline top-light edge. Reduce Transparency yields a clean solid.
    /// A floating inset card for content that must be isolated from whatever is
    /// behind the window — the detail canvas and its panels.
    ///
    /// Deliberately *not* used by the project sidebar: navigation chrome has
    /// nothing to isolate, and stacking this material over the sidebar backdrop
    /// hid the desktop that backdrop exists to show.
    func kaisolaChromePanel(
        inset: CGFloat = KaisolaVisualSystem.chromeInset,
        topInset: CGFloat? = nil
    ) -> some View {
        modifier(
            KaisolaChromePanelModifier(
                inset: inset,
                topInset: topInset ?? inset
            )
        )
    }
}

private struct KaisolaChromePanelModifier: ViewModifier {
    let inset: CGFloat
    let topInset: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: KaisolaVisualSystem.chromeRadius,
            style: .continuous
        )
        return content
            .clipShape(shape)
            .background { panelFill(shape) }
            .overlay { panelEdge(shape) }
            .padding(.top, topInset)
            .padding(.leading, inset)
            .padding(.trailing, inset)
            .padding(.bottom, inset)
    }

    @ViewBuilder
    private func panelFill(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape.fill(Color(nsColor: .controlBackgroundColor))
        } else {
            shape.fill(.thinMaterial)
        }
    }

    /// The lit top edge is what sells a floating card. Reduce Transparency
    /// swaps it for the flat semantic separator so nothing reads as glass.
    @ViewBuilder
    private func panelEdge(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape.strokeBorder(
                Color(nsColor: .separatorColor),
                lineWidth: KaisolaVisualSystem.hairline
            )
        } else {
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.15 : 0.52),
                        Color.white.opacity(colorScheme == .dark ? 0.03 : 0.10),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: KaisolaVisualSystem.hairline
            )
        }
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

// MARK: - Wallpaper-only glass

/// Which file, if any, is currently painting the desktop.
enum DesktopWallpaperResolution: Equatable, Sendable {
    /// A picture file the user actually chose — the common case.
    case picture(URL)
    /// A still standing in for a dynamic aerial, which has no picture file.
    case aerialStill(URL)
    /// Nothing readable: the veil sits on the cooled average colour instead.
    case unavailable

    var url: URL? {
        switch self {
        case let .picture(url), let .aerialStill(url): url
        case .unavailable: nil
        }
    }
}

/// Finds the image that the desktop is actually showing.
///
/// `NSWorkspace.desktopImageURL(for:)` is only half an answer. For a picture
/// desktop it returns the file, but for a dynamic aerial — including the
/// *rotating categories* that macOS 26 ships as its headline desktops — it
/// returns one fixed stand-in path for every screen rather than failing. Taking
/// that at face value paints the stock Big Sur picture behind a user whose
/// desktop is a moving Tahoe drone shot, which looks like a bug, so the
/// sentinel is recognised and the wallpaper store is consulted instead.
enum DesktopWallpaperLocator {
    /// macOS hands this back for every screen whenever the desktop cannot be
    /// expressed as a picture file.
    static let dynamicDesktopSentinelPath = "/System/Library/CoreServices/DefaultDesktop.heic"

    static var defaultSupportDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/com.apple.wallpaper", directoryHint: .isDirectory)
    }

    static func isDynamicDesktopSentinel(_ url: URL) -> Bool {
        let candidate = url.standardized
        let sentinel = URL(fileURLWithPath: dynamicDesktopSentinelPath)
        if candidate.path == sentinel.path { return true }
        // The stand-in is itself a symlink — on macOS 26 it lands on
        // `/System/Library/Wallpapers/.default/DefaultAerial.heic` — and the
        // name it points at has moved between releases. Compare after
        // resolving both sides rather than hardcoding this release's target.
        return candidate.resolvingSymlinksInPath().path
            == sentinel.resolvingSymlinksInPath().path
    }

    /// The ladder, with its two disk-touching rungs injected so the ordering
    /// itself is testable. `aerialStill` reads two files, so it is deliberately
    /// a closure that a picture desktop never calls.
    static func resolve(
        desktopImageURL: URL?,
        readableStill: (URL) -> Bool,
        aerialStill: () -> URL?
    ) -> DesktopWallpaperResolution {
        if let desktopImageURL,
           !isDynamicDesktopSentinel(desktopImageURL),
           readableStill(desktopImageURL) {
            return .picture(desktopImageURL)
        }
        if let still = aerialStill() { return .aerialStill(still) }
        return .unavailable
    }

    /// Live wiring for `resolve(desktopImageURL:readableStill:aerialStill:)`.
    static func resolveOnDisk(
        desktopImageURL: URL?,
        supportDirectory: URL? = nil
    ) -> DesktopWallpaperResolution {
        let support = supportDirectory ?? defaultSupportDirectory
        return resolve(
            desktopImageURL: desktopImageURL,
            readableStill: { CGImageSourceCreateWithURL($0 as CFURL, nil) != nil },
            aerialStill: { currentAerialStill(supportDirectory: support) }
        )
    }

    /// The store's `Index.plist` nests a *second*, binary plist inside each
    /// choice's `Configuration` value; the identifier only exists in there.
    /// `AllSpacesAndDisplays` is the live selection and outranks the
    /// `SystemDefault` copy that sits beside it.
    static func aerialAssetID(indexPlist data: Data) -> String? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else { return nil }
        for scope in ["AllSpacesAndDisplays", "Displays", "Spaces", "SystemDefault"] {
            if let dictionary = root as? [String: Any],
               let branch = dictionary[scope],
               let found = nestedAssetID(branch) {
                return found
            }
        }
        return nestedAssetID(root)
    }

    private static func nestedAssetID(_ node: Any) -> String? {
        switch node {
        case let data as Data:
            guard let inner = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else { return nil }
            return inner["assetID"] as? String
        case let dictionary as [String: Any]:
            for value in dictionary.values {
                if let found = nestedAssetID(value) { return found }
            }
            return nil
        case let array as [Any]:
            for value in array {
                if let found = nestedAssetID(value) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    /// An aerial desktop is normally a rotating *category*, so no single file is
    /// "the" wallpaper and there is no published pointer at whichever clip is
    /// on screen right now. Pick the category's lowest-ordered member whose
    /// still macOS has already downloaded: deterministic — the backdrop cache
    /// key depends on it — never a network fetch, and colour-coherent, because
    /// Apple groups a category by look in the first place.
    static func representativeAerialStill(
        assetID: String,
        manifest data: Data,
        cachedStillIDs: Set<String>
    ) -> String? {
        // A single pinned aerial names its own still; no category to read.
        if cachedStillIDs.contains(assetID) { return assetID }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { return nil }
        let members = assets.compactMap { asset -> (order: Int, id: String)? in
            guard let id = asset["id"] as? String, cachedStillIDs.contains(id) else { return nil }
            let categories = (asset["categories"] as? [String] ?? [])
                + (asset["subcategories"] as? [String] ?? [])
            guard categories.contains(assetID) else { return nil }
            return (asset["preferredOrder"] as? Int ?? .max, id)
        }
        return members.min { lhs, rhs in
            lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
        }?.id
    }

    private static func currentAerialStill(supportDirectory: URL) -> URL? {
        let thumbnails = supportDirectory
            .appending(path: "aerials/thumbnails", directoryHint: .isDirectory)
        guard let index = try? Data(
            contentsOf: supportDirectory.appending(path: "Store/Index.plist")
        ), let assetID = aerialAssetID(indexPlist: index) else { return nil }

        let pinned = thumbnails.appending(path: "\(assetID).png")
        if FileManager.default.fileExists(atPath: pinned.path) { return pinned }

        guard let manifest = try? Data(
            contentsOf: supportDirectory.appending(path: "aerials/manifest/entries.json")
        ), let cached = try? FileManager.default.contentsOfDirectory(atPath: thumbnails.path)
        else { return nil }
        let ids = Set(cached.lazy.filter { $0.hasSuffix(".png") }.map { String($0.dropLast(4)) })
        guard let pick = representativeAerialStill(
            assetID: assetID,
            manifest: manifest,
            cachedStillIDs: ids
        ) else { return nil }
        return thumbnails.appending(path: "\(pick).png")
    }
}

/// Everything a rendered backdrop depends on, and nothing else.
///
/// The screen is not a component: two displays showing the same desktop render
/// the same picture, and keying on the file dedupes them instead of blurring it
/// twice. `modified` catches "set as desktop picture" over a path that never
/// changed, and `isDark` selects the frame of a dynamic desktop.
struct DesktopBackdropKey: Hashable, Sendable {
    let path: String
    let modified: Date?
    let isDark: Bool

    var url: URL { URL(fileURLWithPath: path) }
}

/// What a glass surface paints under its veil.
enum DesktopPainting: @unchecked Sendable {
    /// The pre-blurred desktop still, plus the tint sampled from that same
    /// decode so a single pass produces both products.
    case wallpaper(CGImage, tint: DesktopTintComponents)
    /// No readable still anywhere on the ladder.
    case flat(DesktopTintComponents)

    var tint: DesktopTintComponents {
        switch self {
        case let .wallpaper(_, tint): tint
        case let .flat(tint): tint
        }
    }
}

extension DesktopPainting: Equatable {
    static func == (lhs: DesktopPainting, rhs: DesktopPainting) -> Bool {
        switch (lhs, rhs) {
        case let (.wallpaper(lhsImage, lhsTint), .wallpaper(rhsImage, rhsTint)):
            lhsImage === rhsImage && lhsTint == rhsTint
        case let (.flat(lhsTint), .flat(rhsTint)):
            lhsTint == rhsTint
        default:
            false
        }
    }
}

/// Turns a desktop still into the small blurred image the glass surfaces draw.
///
/// The blur is baked once, at thumbnail scale, and then stretched over a
/// surface many times wider — not applied live to the window. Blurring 176 px
/// is roughly two orders of magnitude less work than blurring the backing
/// store, and the upscale is a second, free smoothing pass.
enum DesktopBackdropRenderer {
    static let stillWidth = 176
    /// Radius in `stillWidth` pixels. Enough that no wallpaper detail survives
    /// as a recognisable shape — this has to read as light, not as a picture.
    static let blurRadius: Double = 12
    /// A Gaussian average of a whole wallpaper is always less colourful than
    /// the wallpaper. Lift it back so the desktop's hue survives the veil.
    static let saturation: Double = 1.3

    /// Dynamic desktops pack every hour of the day into one HEIC with nothing
    /// in the container labelling the frames; the day frames lead and the night
    /// frames trail, so each appearance takes the end nearest to it.
    static func frameIndex(imageCount: Int, isDark: Bool) -> Int {
        guard imageCount > 1 else { return 0 }
        return isDark ? imageCount - 1 : 0
    }

    static func render(key: DesktopBackdropKey) -> DesktopPainting? {
        guard let source = CGImageSourceCreateWithURL(key.url as CFURL, nil) else { return nil }
        let index = frameIndex(imageCount: CGImageSourceGetCount(source), isDark: key.isDark)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: stillWidth,
        ]
        guard let still = CGImageSourceCreateThumbnailAtIndex(
            source,
            index,
            options as CFDictionary
        ) else { return nil }

        let tint = DesktopTintSampler.sample(image: still)
        guard let blurred = blur(still) else { return .flat(tint) }
        return .wallpaper(blurred, tint: tint)
    }

    /// `clampedToExtent` before the blur, cropped back after: without it the
    /// Gaussian averages in transparent black at every edge and the backdrop
    /// arrives with a dark vignette exactly where the window's corners are.
    private static func blur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent

        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = input.clampedToExtent()
        gaussian.radius = Float(blurRadius)
        guard let softened = gaussian.outputImage else { return nil }

        let controls = CIFilter.colorControls()
        controls.inputImage = softened
        controls.saturation = Float(saturation)
        guard let output = controls.outputImage else { return nil }

        return CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(output, from: extent)
    }
}

struct DesktopTintComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
}

enum DesktopTintSampler {
    static let fallback = DesktopTintComponents(red: 0.38, green: 0.43, blue: 0.49)

    /// How much of the wallpaper's own chroma reaches the tint.
    ///
    /// This was 0.45 with a 0.18 slate mix, tuned back when the tint *was* the
    /// backdrop and a saturated desktop could shout through the whole sidebar.
    /// It no longer is: the painted wallpaper carries the desktop now, and the
    /// tint's remaining jobs — the last fallback rung and the Tinted canvas —
    /// both want the hue to be legible rather than damped. At the old values a
    /// magenta desktop resolved to a 0.18-wide channel spread, which is grey
    /// once a veil goes over it.
    static let chromaRetention = 0.70
    /// A small pull toward a cool slate keeps a *near*-neutral desktop from
    /// picking up a random cast, without flattening a colourful one.
    static let slateMix = 0.10
    private static let slate = (red: 0.35, green: 0.42, blue: 0.50)
    /// Floors low enough that a dark wallpaper stays dark. The veil above is
    /// what guarantees legibility; clamping here only prevents a fully black or
    /// blown-out desktop from producing a degenerate tint.
    private static let floors = (red: 0.07, green: 0.07, blue: 0.09)
    private static let ceilings = (red: 0.90, green: 0.91, blue: 0.92)

    static func sample(url: URL?) -> DesktopTintComponents {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return fallback
        }
        return sample(image: image)
    }

    static func sample(image: CGImage) -> DesktopTintComponents {
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

    /// The wallpaper's average, with its chroma pulled toward luminance and
    /// then nudged toward a cool slate — enough to stay recognisably the
    /// desktop's colour, not enough to turn a blue desktop into blue-on-blue
    /// application chrome.
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
        let softened = (
            luminance + (wallpaper.0 - luminance) * chromaRetention,
            luminance + (wallpaper.1 - luminance) * chromaRetention,
            luminance + (wallpaper.2 - luminance) * chromaRetention
        )
        return DesktopTintComponents(
            red: min(ceilings.red, max(floors.red, softened.0 * (1 - slateMix) + slate.red * slateMix)),
            green: min(ceilings.green, max(floors.green, softened.1 * (1 - slateMix) + slate.green * slateMix)),
            blue: min(ceilings.blue, max(floors.blue, softened.2 * (1 - slateMix) + slate.blue * slateMix))
        )
    }
}

/// Owns the one rendered desktop backdrop the whole app shares.
///
/// Every glass surface reads the same published painting, so a window with a
/// sidebar and a canvas decodes and blurs the wallpaper once, not twice. There
/// is no per-frame and no idle work: rendering happens only when the resolved
/// key changes, and re-*resolution* is rate-limited because a focus change or a
/// Space switch is a hint that the desktop may have changed, not proof.
@MainActor
final class DesktopBackdropProvider: ObservableObject {
    static let shared = DesktopBackdropProvider()

    @Published private(set) var painting: DesktopPainting = .flat(DesktopTintSampler.fallback)

    /// Wallpaper changes are not observable; they are polled off the hints
    /// below. This is the floor between two disk reads.
    static let minimumResolveInterval: TimeInterval = 2
    /// Enough for a light/dark pair on each of two recently seen desktops.
    private static let cacheLimit = 4

    private var cache: [DesktopBackdropKey: DesktopPainting] = [:]
    private var cacheOrder: [DesktopBackdropKey] = []
    private var work: Task<Void, Never>?
    private var lastResolved = Date.distantPast
    private var lastAppearanceIsDark: Bool?
    private var observers: [any NSObjectProtocol] = []

    var tintColor: Color {
        let tint = painting.tint
        return Color(red: tint.red, green: tint.green, blue: tint.blue)
    }

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        // Space switches and screen reconfiguration can both change which
        // desktop picture applies; becoming key is when a wallpaper the user
        // changed in System Settings first matters to us.
        observers = [
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } },
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } },
        ]
    }

    /// Ask for the backdrop that matches `isDark`. Cheap and idempotent: an
    /// appearance flip always re-resolves, anything else waits out the
    /// rate limit.
    func refresh(isDark: Bool) {
        let appearanceChanged = isDark != lastAppearanceIsDark
        let due = Date().timeIntervalSince(lastResolved) >= Self.minimumResolveInterval
        guard appearanceChanged || due else { return }
        lastAppearanceIsDark = isDark
        lastResolved = Date()
        resolve(isDark: isDark)
    }

    /// A hint arrived that the desktop may have changed. Re-resolution is
    /// re-armed rather than performed, so a burst of notifications costs one
    /// disk read at most.
    private func invalidate() {
        lastResolved = .distantPast
        guard let isDark = lastAppearanceIsDark else { return }
        refresh(isDark: isDark)
    }

    private func resolve(isDark: Bool) {
        let desktopImageURL = Self.currentScreen()
            .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        work?.cancel()
        work = Task { [weak self] in
            let key = await Task.detached(priority: .utility) {
                Self.key(desktopImageURL: desktopImageURL, isDark: isDark)
            }.value
            guard !Task.isCancelled, let self else { return }
            guard let key else {
                painting = .flat(DesktopTintSampler.fallback)
                return
            }
            if let cached = cache[key] {
                painting = cached
                return
            }
            let rendered = await Task.detached(priority: .utility) {
                DesktopBackdropRenderer.render(key: key)
            }.value
            guard !Task.isCancelled else { return }
            let resolved = rendered ?? .flat(DesktopTintSampler.fallback)
            self.store(resolved, for: key)
            self.painting = resolved
        }
    }

    private func store(_ painting: DesktopPainting, for key: DesktopBackdropKey) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = painting
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private nonisolated static func key(
        desktopImageURL: URL?,
        isDark: Bool
    ) -> DesktopBackdropKey? {
        guard let url = DesktopWallpaperLocator
            .resolveOnDisk(desktopImageURL: desktopImageURL).url else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return DesktopBackdropKey(path: url.path, modified: modified, isDark: isDark)
    }

    /// The desktop under *this* window, falling back to the primary display.
    private static func currentScreen() -> NSScreen? {
        NSApp?.keyWindow?.screen ?? NSApp?.mainWindow?.screen ?? NSScreen.main
    }
}

/// The desktop layer beneath a glass veil.
///
/// This is the layer the wallpaper-only request is about: in `.wallpaper` mode
/// nothing behind the window is sampled at all, so another app's window can
/// never appear inside Kaisola's glass.
struct DesktopGlassLayer: View {
    let liveMaterial: NSVisualEffectView.Material
    /// Tint coverage (dark, light) laid over *live* vibrancy only. In light
    /// appearance AppKit's materials are near-white and pass almost no desktop
    /// colour through, so live mode needs the sampled average to carry the hue.
    /// The painted wallpaper already is the hue and must not be tinted twice.
    var liveTint: (dark: Double, light: Double)?

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings: NativePreviewSettings
    @ObservedObject private var desktop = DesktopBackdropProvider.shared

    init(
        liveMaterial: NSVisualEffectView.Material,
        liveTint: (dark: Double, light: Double)? = nil,
        settings: NativePreviewSettings = .shared
    ) {
        self.liveMaterial = liveMaterial
        self.liveTint = liveTint
        self.settings = settings
    }

    var body: some View {
        layer
            .onAppear { desktop.refresh(isDark: colorScheme == .dark) }
            .onChange(of: colorScheme) { desktop.refresh(isDark: colorScheme == .dark) }
    }

    @ViewBuilder
    private var layer: some View {
        switch settings.glassBackdropSource {
        case .wallpaper:
            paintedDesktop
        case .behindWindow:
            ZStack {
                NativeVisualEffectView(material: liveMaterial)
                if let liveTint {
                    LinearGradient(
                        colors: [
                            desktop.tintColor.opacity(colorScheme == .dark ? liveTint.dark : liveTint.light),
                            desktop.tintColor.opacity(
                                (colorScheme == .dark ? liveTint.dark : liveTint.light) * 0.55
                            ),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
    }

    /// The still is stretched, not aspect-filled. Every glass surface is a
    /// different shape — a tall narrow sidebar beside a wide canvas — and
    /// filling each one to its own aspect shows each a *different* crop of the
    /// wallpaper, which reads as a seam between them. Stretching gives them all
    /// the same left-to-right colour story, and at this blur radius the
    /// distortion has nothing recognisable left to distort.
    @ViewBuilder
    private var paintedDesktop: some View {
        switch desktop.painting {
        case let .wallpaper(image, _):
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .allowsHitTesting(false)
        case let .flat(tint):
            let color = Color(red: tint.red, green: tint.green, blue: tint.blue)
            LinearGradient(
                colors: [
                    color.opacity(colorScheme == .dark ? 0.42 : 0.34),
                    color.opacity(colorScheme == .dark ? 0.26 : 0.20),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(Color(nsColor: .windowBackgroundColor))
        }
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
                    DesktopGlassLayer(liveMaterial: .sidebar, liveTint: (dark: 0.30, light: 0.26))
                    GlassBackdropWash.sidebar(isDark: colorScheme == .dark).veil
                    if accessibilityContrast == .increased {
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(GlassBackdropWash.sidebarIncreasedContrastOverlay(isDark: colorScheme == .dark))
                    }
                }
            }
        case .solid:
            Color(nsColor: .controlBackgroundColor)
        }
    }
}

struct WorkspaceBackdropView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @ObservedObject private var desktop = DesktopBackdropProvider.shared
    let mode: WorkspaceBackdropMode

    var body: some View {
        backdrop
            .onAppear { if mode == .tinted { desktop.refresh(isDark: colorScheme == .dark) } }
            .onChange(of: colorScheme) {
                if mode == .tinted { desktop.refresh(isDark: colorScheme == .dark) }
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
                    DesktopGlassLayer(liveMaterial: .underWindowBackground)
                    GlassBackdropWash.workspace(isDark: colorScheme == .dark).veil
                    if accessibilityContrast == .increased {
                        Color(nsColor: .windowBackgroundColor)
                            .opacity(GlassBackdropWash.workspaceIncreasedContrastOverlay(isDark: colorScheme == .dark))
                    }
                }
            }
        case .tinted:
            // Same neutrality contract as the glass veil: the sampled desktop
            // color is the only chroma in the stack — no mesh (lavender) stop.
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        desktop.tintColor.opacity(colorScheme == .dark ? 0.16 : 0.12),
                        desktop.tintColor.opacity(colorScheme == .dark ? 0.09 : 0.055),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}
