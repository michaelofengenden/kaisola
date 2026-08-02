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
        // "System" described where the colour came from, not what you get, and
        // what you get is the point: a flat opaque surface with no wallpaper in
        // it at all. Michael asked for the canvas to "actually be tinted or a
        // white solid"; this is the white solid, and it now says so. The raw
        // value stays `system` so nobody's stored preference moves.
        case .system: "Solid"
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
    /// The corner ladder, from the smallest control to the window itself.
    ///
    /// v1.1.8 bumps every rung one step (shell 16 → 20, chrome 15 → 18, and
    /// each nested radius proportionally). The numbers are only half the
    /// contract: what keeps the chrome coherent is that they stay *strictly
    /// increasing* outward, so a shape nested inside another is always the
    /// rounder one's junior. `testCornerLadderIsStrictlyIncreasingOutward`
    /// holds that, and it is the check a future "make it rounder" pass has to
    /// keep green rather than a list of literals to edit past.
    static let controlRadius: CGFloat = 8
    /// A session pane card, which sits *inside* the detail chrome panel. Was a
    /// bare `8` written inline in `RootShellView.unifiedSessionCard`; naming it
    /// is what puts it on the ladder at all.
    static let paneRadius: CGFloat = 10
    static let insetRadius: CGFloat = 12
    static let cardRadius: CGFloat = 14
    /// The document-preview and Files panels, which are nested one level inside
    /// the detail chrome panel and so stay a step under `chromeRadius`.
    static let panelRadius: CGFloat = 16
    static let shellRadius: CGFloat = 20
    /// Safari's inset floating-card chrome: the radius of the sidebar and
    /// detail panels that float over the window backdrop. Larger than
    /// `cardRadius` (which belongs to session cards *inside* a panel) and
    /// smaller than `shellRadius` (the window itself).
    static let chromeRadius: CGFloat = 18
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

/// One last-resort motion boundary for the two native view roots.
///
/// Individual surfaces can still choose a calmer replacement transition (the
/// toast, onboarding, restoration notice, palette, and rail already do), but
/// a new `withAnimation` must never become mandatory motion merely because its
/// author forgot to repeat that check. Applying this policy at `RootShellView`
/// and `SettingsView` strips animation from every descendant transaction while
/// the system Reduce Motion preference is enabled.
enum KaisolaMotionPolicy {
    static func apply(reduceMotion: Bool, to transaction: inout Transaction) {
        guard reduceMotion else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }
}

private struct KaisolaReduceMotionFallbackModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            KaisolaMotionPolicy.apply(reduceMotion: reduceMotion, to: &transaction)
        }
    }
}

/// The neutral veil laid over AppKit vibrancy — or over the sampled desktop
/// tint — for the two large backdrops.
///
/// Methodology: light mode is white-led (white at roughly a third coverage),
/// dark mode is a truly achromatic near-black (`#0D0D0D`). The recipe carries
/// no accent, mesh, or slate stop, so the only chroma that reaches the eye is
/// whatever the desktop itself contributes. The three opacities describe one
/// vertical gradient of the *same* color, so the top-light edge reads as light
/// direction rather than as a tint. Keeping the numbers separate from the
/// material makes the light/dark balance deterministic and gives appearance
/// tests a stable contract.
struct GlassBackdropWash: Equatable, Sendable {
    /// `#0D0D0D`: R = G = B, so the veil contributes no hue of its own at any
    /// coverage.
    ///
    /// It was `#0B0C12` — 11/12/18 — and that is where Michael's "blue-purple
    /// tone" came from. At 0.60 coverage a veil is most of the surface, and
    /// 18/255 against 11/255 is a **64% blue lead over red**; the eye reads
    /// that as a cool cast long before it reads it as black. The old guard
    /// missed it because it was stated in absolute terms (`blue - green ≤
    /// 0.03`), and 0.024 of absolute difference is nothing at mid-grey and
    /// everything at near-black. The invariant is relative now — see
    /// `testDeclaredNeutralConstantsAreAchromatic`.
    static let darkVeil = (red: 13.0 / 255, green: 13.0 / 255, blue: 13.0 / 255)

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

    /// The sidebar is frost, not a window.
    ///
    /// Three eras, and both of the first two overshot. The v1.1 values (light
    /// 0.42/0.32/0.26) sat over *vibrancy*, which is itself near-opaque, so the
    /// column rendered flat #EDEDED and no desktop colour survived. Halving
    /// them to 0.16 fixed that against vibrancy — but by then the layer
    /// underneath had become the painted wallpaper still, which passes 100% of
    /// the desktop instead of vibrancy's sliver. A 0.16 veil over a raw
    /// wallpaper is not glass; it is a blurred photograph with a haze on it,
    /// and that is exactly how it read: measured off the shipped build, the
    /// sidebar's average channel spread was 0.32 and its peak 0.53 — *more*
    /// saturated than the desktop beside the window, because the bake was also
    /// boosting saturation 1.3×.
    ///
    /// The reference is the Safari sidebar: a heavy near-white (light) or
    /// near-black (dark) surface that the wallpaper *tints* rather than fills.
    /// At 0.60 coverage the still contributes 40% — enough that the desktop's
    /// hue is unmistakably present (modelled composite spread 0.11, against
    /// 0.32 before) and its luminance structure is not (modelled top-to-bottom
    /// luminance range 0.019, against 0.218 before). The wallpaper bake now
    /// luminance-normalizes too, so that 40% arrives at a predictable
    /// brightness whatever the desktop is — see `DesktopBackdropRenderer`.
    /// v1.1.10 thins the **dark** veil and widens its gradient; light is
    /// untouched, because light was never the complaint.
    ///
    /// Dark was the least translucent surface in the app — 0.35–0.40
    /// transmission against light's 0.40–0.45 — and it read exactly as that:
    /// "the background in dark mode looks bad… needs to be really glass dark…
    /// glassy/smooth/translucent to the wallpaper". Modelled against the actual
    /// desktop (an Aerial still), the surface's luminance spread p5..p95 was
    /// 0.060 and the veil's own top-to-bottom range 0.0144 — half of light's
    /// 0.0283. Thinner veil, wider gradient: spread 0.072, gradient 0.0165, and
    /// primary/secondary label contrast still 12.8:1 / 6.0:1.
    ///
    /// v1.1.10 took dark one step down, 0.55 → 0.52, and said so was
    /// deliberately small because the flatness was a colour-space bug rather
    /// than a veil. With that fixed and the surface finally showing what its
    /// constants describe, Michael's next note is about the veil and only the
    /// veil: "dark glass mode could look more glassy/translucent if possible!
    /// especially on live and wallpaper (dark mode should be very translucent)".
    ///
    /// **0.52 → 0.34.** Transmission 0.48 → 0.66 — the veil now covers a third
    /// of the surface rather than half, the largest single move this constant
    /// has made. Measured through the real pipeline against Michael's own
    /// desktop (the Lake Tahoe aerial macOS resolves for his rotating category),
    /// dark sidebar at 210×900:
    ///
    ///     composite rgb   0.089/0.107/0.115  →  0.103/0.129/0.139
    ///     mean luminance              0.104  →  0.124
    ///     luminance spread p5..p95    0.086  →  0.095
    ///     off-neutral                 0.143  →  0.165
    ///     primary label contrast     12.7:1  →  12.1:1  (worst patch 10.9:1)
    ///     secondary label contrast    6.0:1  →   5.8:1  (worst patch  5.5:1)
    ///
    /// This is only available because `DesktopBackdropRenderer`
    /// `darkStillSpreadCeiling` bounds the still's dynamic range first. Thinning
    /// the veil this far *without* that cap put the worst patch of the widest
    /// wallpaper measured at **3.9:1** secondary — below the 4.5 floor. With it,
    /// the worst patch over the five extremes of this Mac's aerial library
    /// **improves** to 4.9:1 (from 4.6:1 at the thicker veil), because the cap
    /// removes more of the worst case than the veil it replaces did.
    ///
    /// The floor is what stopped this at 0.34 rather than lower, and the binding
    /// case is not a photograph: a wallpaper that *is* a linear gradient (macOS
    /// ships several) passes the Gaussian untouched, so its whole range reaches
    /// the veil. Against that fixture the worst patch measures 4.6:1 here, 4.4:1
    /// at a 0.26 base — so roughly 0.30 is the real limit and the margin between
    /// there and here is deliberate. Past that point extra transmission also
    /// stops buying *structure*: the cap has to tighten in step, and
    /// `(1 - base) × ceiling` is conserved. It keeps buying chroma, which is
    /// most of what reads as translucency at this luminance.
    ///
    /// **Light, 0.60 → 0.45.** The same request, one round later: "light mode
    /// should also be translucent to wallpaper much better". Transmission
    /// 0.40 → **0.55**. Light had been left alone twice on the argument that a
    /// 0.72 surface has headroom to spare; rendering it says otherwise, and this
    /// is the number that says so. Measured against Michael's own desktop, light
    /// sidebar at 210×900:
    ///
    ///     composite rgb   0.836/0.898/0.924  →  0.774/0.860/0.897
    ///     mean luminance              0.887  →  0.845
    ///     luminance spread p5..p95   0.0805  →  0.0803
    ///     veil gradient top→bottom   0.0385  →  0.0378
    ///     off-neutral                 0.057  →  0.083
    ///     absolute chroma            0.0501  →  0.0696
    ///     primary label contrast     12.3:1  →  11.4:1  (worst patch 9.5:1)
    ///     secondary label contrast    3.8:1  →   3.7:1  (worst patch 3.5:1)
    ///
    /// The wallpaper's colour arrives **39% stronger** and its light and shade
    /// arrive unchanged — the trade the range cap makes is chroma-for-structure
    /// at fixed contrast, and at these constants the structure comes out level.
    ///
    /// Like dark, this is only available because the bake bounds the still's
    /// range first (`DesktopBackdropRenderer.lightStillSpreadCeiling`). Thinning
    /// the light veil to 0.45 *without* the cap puts the worst patch of an
    /// adversarial ramp at **5.9:1 primary** — below the 7.0 floor — and the
    /// worst patch of the five aerial extremes at 3.20:1 secondary against a
    /// 3.43 baseline. With the cap the worst patch **improves** on every
    /// adversarial fixture (primary 7.27 → 8.88, secondary 3.17 → 3.40) and
    /// returns exactly to baseline on the aerials.
    ///
    /// What stopped light at 0.45 is **not** the same constraint that stopped
    /// dark, and it is worth being precise about which floor binds. Light's
    /// primary has room to spare (9.05:1 at the worst patch, against 7.0).
    /// Light's *secondary* cannot reach the stated 4.5 floor at any veil,
    /// because it is not a property of the veil: AppKit's `secondaryLabelColor`
    /// in Aqua is black at **α 0.498** (measured, not assumed), and black at
    /// α 0.498 over *pure white* is **3.98:1**. Every light surface in every
    /// Mac app is under that ceiling. So the honest constraint here is "do not
    /// make it worse", the worst-patch secondary is held at its pre-change 3.43,
    /// and 0.45 is exactly where that binds. Going to 0.40 costs 0.06 of it.
    ///
    /// The mechanism that would lift it is a **custom secondary ink** rather
    /// than the system semantic: on this surface, black at α 0.60 measures
    /// **4.60:1** at the worst patch (4.56:1 adversarial), clearing the floor.
    /// It is not done here because the 207 `.secondary` call sites all live in
    /// `Features/*` and `Acp/*`, and a glass constant that silently restyles
    /// every label in the app is a change that should be made on purpose.
    static func sidebar(isDark: Bool) -> GlassBackdropWash {
        isDark
            ? dark(top: 0.27, base: 0.34, bottom: 0.43)
            : light(top: 0.51, base: 0.45, bottom: 0.41)
    }

    /// How much of the composited backdrop is still the desktop's own colour
    /// rather than the veil — `1 - baseOpacity`, named so the appearance
    /// contract can be stated as "the desktop must survive", which is the
    /// property that actually regressed.
    var desktopTransmission: Double { 1 - baseOpacity }

    /// The workspace sits one step deeper than the sidebar so the inset chrome
    /// panels have something to float above: less white in light mode, more
    /// near-black in dark mode. Dark moves with the sidebar and keeps its three
    /// points of separation (0.55 → 0.37); measured composite 0.102/0.126/0.135,
    /// spread 0.094, primary 12.2:1 (worst 11.0:1), secondary 5.9:1 (worst 5.5:1).
    ///
    /// Light moves with the sidebar too and keeps its five points of separation
    /// (0.55 → 0.40, transmission 0.45 → **0.60**); measured composite
    /// 0.752/0.847/0.888, spread 0.088, chroma 0.0767, primary 11.0:1 (worst
    /// 9.1:1), secondary 3.7:1 (worst 3.4:1). The workspace is the deeper
    /// surface, so it is also the one the worst patch is always found on — every
    /// light figure quoted as a worst case in this file is a workspace figure.
    static func workspace(isDark: Bool) -> GlassBackdropWash {
        isDark
            ? dark(top: 0.30, base: 0.37, bottom: 0.46)
            : light(top: 0.46, base: 0.40, bottom: 0.36)
    }

    /// The band a glass veil's transmission has to live in, per appearance.
    ///
    /// The contract is unchanged and still two-sided: too little transmission
    /// and the surface is the flat #EDEDED panel of v1.1; too much and it is a
    /// blurred photograph with a haze on it. What changed is *where the upper
    /// bound comes from in dark*.
    ///
    /// It used to be 0.50 for both appearances because the veil was the only
    /// thing keeping the desktop's brightness and dynamic range out of the
    /// surface. It no longer is, in either appearance: the bake normalizes the
    /// still's mean **and** caps its p5..p95 range at
    /// `DesktopBackdropRenderer.stillSpreadCeiling(isDark:)`, so "not a
    /// photograph" is now a property of the layer underneath rather than of the
    /// layer over it. A still cannot be brighter, and cannot have more range,
    /// than those two constants allow, whatever the desktop is — which is
    /// exactly the guarantee the 0.50 ceiling was standing in for.
    ///
    /// Both ceilings therefore sit one step above the veil they permit
    /// (dark 0.66 under 0.70, light 0.60 under 0.65) rather than at an
    /// historical number. Light stays the tighter of the two because its own
    /// contrast budget is tighter, not because it is unguarded: see
    /// `sidebar(isDark:)` for the 3.98:1 AppKit ceiling that is the real bound
    /// on the light surface.
    static func desktopTransmissionBand(isDark: Bool) -> (floor: Double, ceiling: Double) {
        isDark ? (floor: 0.30, ceiling: 0.70) : (floor: 0.30, ceiling: 0.65)
    }

    /// How much of a glass surface Increased Contrast must cover, counting the
    /// veil and the overlay together.
    ///
    /// This used to be expressed as a *restoration*: reproduce whatever
    /// coverage the pre-halving veil reached once a flat 0.18 overlay was
    /// stacked on it. That reference is now moot. The frost retune raised every
    /// base past the composite those old numbers produced (the highest was
    /// workspace dark at 0.59, below today's 0.65 base alone), so the
    /// restoration formula solved to a negative overlay on all four surfaces
    /// and collapsed onto its own 0.18 floor — an accessibility setting whose
    /// arithmetic had quietly stopped doing anything.
    ///
    /// Stating it as an absolute floor is both simpler and the thing that
    /// actually matters to a low-vision user: with Increased Contrast on, at
    /// most 20% of what reaches the eye is wallpaper. That is a property of the
    /// rendered surface, not of any previous release, so it cannot rot the next
    /// time the veil moves.
    static let increasedContrastCoverage = 0.80

    /// Two translucent layers stacked with standard "over" compositing cover
    /// `base + overlay * (1 - base)` in total — the overlay only paints the
    /// sliver the veil left uncovered. Solving for the overlay that lifts a
    /// given base to `increasedContrastCoverage`:
    ///
    ///     overlay = (coverage - base) / (1 - base)
    ///
    /// The overlay may not paint a glass surface into an opaque panel — that is
    /// what `SidebarAppearance.solid` and Reduce Transparency are for, and an
    /// overlay that reached 1 would make Increased Contrast silently a third
    /// opacity setting.
    ///
    /// It was 0.6, and 0.6 is exactly the overlay a 0.50 base needs to reach the
    /// 0.80 floor — so the moment the dark veil went below 0.50 the clamp would
    /// have started binding and the accessibility guarantee would have been met
    /// by a `min` rather than by arithmetic (0.34 + 0.6·0.66 = 0.74, not 0.80).
    /// Raised to 0.80, which leaves the exact solutions for today's four bases
    /// (0.45/0.40 light, 0.34/0.37 dark → 0.636/0.667/0.697/0.683) strictly
    /// inside it, and still keeps a fifth of the surface translucent at the
    /// extreme. The light veil's own retune moved its two solutions from
    /// 0.500/0.556 to those figures without touching this constant, which is the
    /// whole point of deriving them.
    static let increasedContrastOverlayCeiling = 0.80

    /// `base` is read live from `sidebar(isDark:)` / `workspace(isDark:)` so a
    /// future veil retune re-derives this instead of falling behind. Clamped to
    /// `[0, increasedContrastOverlayCeiling]`: a base that already meets the
    /// floor needs no overlay.
    private static func increasedContrastOverlay(base: Double) -> Double {
        guard base < 1 else { return 0 }
        return min(
            increasedContrastOverlayCeiling,
            max(0, (increasedContrastCoverage - base) / (1 - base))
        )
    }

    /// Increased Contrast overlay opacity for the sidebar veil.
    static func sidebarIncreasedContrastOverlay(isDark: Bool) -> Double {
        increasedContrastOverlay(base: sidebar(isDark: isDark).baseOpacity)
    }

    /// Increased Contrast overlay opacity for the workspace veil.
    static func workspaceIncreasedContrastOverlay(isDark: Bool) -> Double {
        increasedContrastOverlay(base: workspace(isDark: isDark).baseOpacity)
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
    /// Enforces Reduce Motion for a complete native presentation tree. Keep it
    /// on every independently hosted root rather than relying on each child to
    /// remember the preference.
    func kaisolaReduceMotionFallback() -> some View {
        modifier(KaisolaReduceMotionFallbackModifier())
    }

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
    /// Nothing readable: the veil sits on the wallpaper's average colour instead.
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
            // Sorted, not `.values`: dictionary iteration order is seeded per
            // process, so a plist holding two asset IDs would pick a different
            // one on some launches — and the asset ID is part of the backdrop
            // cache key, so that is a wallpaper that changes when you restart.
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key], let found = nestedAssetID(value) { return found }
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
    /// Working resolution of the bake, and the fix for "glass picks up the
    /// colour of the wallpaper but not the **vibe**".
    ///
    /// It was 176. That was ample while the blur was destroying every
    /// mid-frequency in the picture anyway — the still was a colour field, so
    /// how faithfully it sampled the wallpaper's *shapes* did not matter. Once
    /// `blurFraction` lets those shapes through it matters a great deal, and the
    /// measurement is unambiguous. Baking each of this Mac's aerial extremes at
    /// several widths and correlating the result against a 1024px reference,
    /// both reduced to a common 128×128 grid:
    ///
    ///     176 px → 0.841      384 px → 0.910      640 px → 0.975
    ///     256 px → 0.861      448 px → 0.932
    ///
    /// At 176 px **16% of the structure the surface shows is not the
    /// wallpaper's** — it is the thumbnail decode's own aliasing, promoted to
    /// visible texture the moment the blur stopped hiding it. 448 takes that to
    /// 7% for about +2 ms of decode, and the still it caches is 451 KB.
    ///
    /// Resolution is deliberately *not* the lever that produces detail — the
    /// detail metric is flat in it, because what the eye sees is set by the blur
    /// as a **fraction of the frame**, not by the pixel count. Raising it only
    /// buys fidelity of the structure `blurFraction` chose to keep.
    static let stillWidth = 448

    /// The blur, as a fraction of `stillWidth` — the constant that actually
    /// decides whether the surface is a colour field or frosted glass.
    ///
    /// It was 28 px on a 176 px still: **15.9%** of the frame. That is a blur
    /// wide enough to reduce any wallpaper to about six distinguishable masses
    /// across its whole width, which is why the shipped surface measured
    /// `spread ≈ gradient` on every fixture — *all* of its luminance range was
    /// the veil's own top-to-bottom gradient and none of it was the picture.
    /// Michael's note is exactly that distinction: "glass wallpaper should pick
    /// up the **vibe** of the wallpaper as well, like **washed details**".
    ///
    /// 5% leaves roughly twenty masses across the frame: a horizon, a shoreline,
    /// the shape of a cloud bank read as soft washes, with nothing identifiable.
    /// The old note's requirement — "no locatable shape" — is kept; what changes
    /// is that "no locatable shape" and "no shape at all" turn out to be two
    /// different radii, and the bake had been sitting on the second one.
    ///
    /// Lowering this alone would be the regression the previous three rounds
    /// each fixed a version of: more range reaching the veil is exactly what the
    /// contrast floors cannot afford. It is affordable here only because the cap
    /// underneath it moved from a *proxy* to the real quantity — see
    /// `tailHeadroom(isDark:)`.
    static let blurFraction: Double = 0.05

    /// Radius in `stillWidth` pixels.
    static var blurRadius: Double { Double(stillWidth) * blurFraction }

    /// A local-contrast add-back, applied to the blurred still before the tone
    /// map — the "compress the global range, keep the local one" half of the
    /// change stated as one filter.
    ///
    /// An unsharp mask adds `intensity × (image − blur(image))`: a **zero-mean**
    /// mid-frequency residual. It therefore raises the contrast *within* a
    /// neighbourhood without moving the still's mean, and what it does move —
    /// the extremes — is measured immediately afterwards and paid for by the
    /// gain. So this cannot smuggle range past the legibility cap; it can only
    /// change how that range is spent, which is the whole point.
    ///
    /// The radius is set relative to the blur so the band restored is the one
    /// just above what the blur removed rather than a fixed pixel size that
    /// would mean something different at every `stillWidth`.
    ///
    /// 0.6 rather than more: at 1.0 the worst-patch secondary in dark falls back
    /// to the shipped 4.51 and stops improving, and past ~1.8 the upscale to the
    /// surface starts ringing — measured, the dark worst patch drops to 4.32,
    /// *below* the 4.5 floor, which the still-side cap cannot see because the
    /// overshoot is created by the interpolation and not by the bake.
    static let localContrastRadiusFactor: Double = 1.4
    static let localContrastIntensity: Double = 0.6
    /// A slight saturation *cut*.
    ///
    /// This was 1.3, from the era when a heavy veil ate most of the desktop's
    /// chroma and the bake had to shout to be heard through it. Under a 0.60
    /// veil it inverted: the sidebar measured a 0.53 peak channel spread
    /// against the raw desktop's 0.33 — Kaisola's "glass" was more saturated
    /// than the wallpaper it was imitating, which is precisely what made it
    /// read as a photograph. 1.0 was the correction, and it landed the
    /// composite at the wallpaper's own chroma.
    ///
    /// v1.1.8 takes one more step down, to 0.85. The remaining complaint was
    /// not that the surface was *bright* but that it was **colourful** —
    /// whatever hue the desktop happened to carry arrived at full strength and
    /// the chrome changed personality with the wallpaper. Damping the still's
    /// chroma by 15% keeps the desktop legibly present while moving the surface
    /// toward a material of its own, and the warmth it loses is put back
    /// deliberately and in one known hue by `GlassWarmth` rather than being
    /// borrowed from whatever picture is on the desktop.
    ///
    /// This is now the *ceiling* rather than the value: see
    /// `saturation(mean:isDark:)`, which is where the dark cast was.
    static let saturationCeiling: Double = 0.85

    /// The ceiling for **dark**, which is a different number for a reason that
    /// is not taste.
    ///
    /// Chroma and luminance are not independent to the eye at near-black. The
    /// dark still is normalized to 0.16 and sits under a veil that passes ~45%
    /// of it, so the composite's total luminance is ~0.10 — and against a mean
    /// that small, a channel difference the light surface would not notice is
    /// most of what the surface *is*. Measured against Michael's own desktop
    /// (a Lake Tahoe aerial, off-neutral 0.399) with the bake rendering
    /// correctly, the dark sidebar came back **0.221** off-neutral against
    /// light's 0.059 on the identical wallpaper. Same picture, same veil
    /// arithmetic, 3.7× the cast — which is what "still reads a little
    /// blue/purple" is.
    ///
    /// Damping the dark still's chroma to 0.50 takes that to **0.129** while
    /// leaving the surface's luminance spread untouched at 0.083 (0.0785 →
    /// 0.0785 across the sweep — chroma and structure are separable here even
    /// though chroma and *brightness* are not). That is the property that makes
    /// this the right lever for the cast rather than a lever that greys the
    /// wallpaper out: the wallpaper's light and shade all survive; only how
    /// loudly it is coloured moves. Across the five most extreme wallpapers on
    /// this machine the dark composite's off-neutrality drops from 0.003–1.181
    /// to 0.009–0.330 — the surface stops changing personality with the desktop.
    ///
    /// Light keeps 0.85. When light's turn came the ask was translucency rather
    /// than cast, and the light composite was measured at 0.057 off-neutral
    /// against dark's 0.165 — a light surface at 0.85 luminance has the headroom
    /// to carry the desktop's hue at full strength and does not read as coloured
    /// when it does. Thinning the light veil raises that to 0.083, which is
    /// still half of dark's, so the ceiling did not have to move with it.
    static let darkSaturationCeiling: Double = 0.50

    static func saturationCeiling(isDark: Bool) -> Double {
        isDark ? darkSaturationCeiling : saturationCeiling
    }

    /// The chroma that actually reaches a baked still — and the fix for
    /// "the background in dark mode looks… purple/blue".
    ///
    /// The bake normalized luminance and left chroma alone, and those two
    /// cannot be separated at near-black. `CIColorControls.brightness` is a
    /// straight per-channel offset (that is exactly why `luminanceShift` uses
    /// it), so it preserves the still's **absolute** channel differences while
    /// moving its mean. In light that is harmless: the still is lifted to 0.72
    /// and the same absolute spread is a small fraction of it. In dark the
    /// still is crushed to 0.16 and the identical spread becomes most of the
    /// surface.
    ///
    /// Measured end to end against the real desktop (an Aerial still, average
    /// rgb 0.263/0.476/0.576, so a genuinely blue picture), using the *same*
    /// relative measure `testDeclaredNeutralConstantsAreAchromatic` applies to
    /// anything this app calls neutral — the largest per-channel departure from
    /// the mean, over the mean:
    ///
    ///     light sidebar composite  0.834/0.898/0.927 → 0.059 off-neutral
    ///     dark  sidebar composite  0.055/0.114/0.143 → 0.473 off-neutral
    ///
    /// The dark surface was 8× further from neutral than the light one, and —
    /// the part that makes it a bug rather than a taste — **further from
    /// neutral than the desktop it was sampling** (0.400). That is the same
    /// failure the v1.1.8 note describes for the sidebar, surviving in dark
    /// only: glass more colourful than the wallpaper it imitates.
    ///
    /// So chroma is normalized the way luminance already is. Scaling the
    /// still's saturation by `target / mean` keeps its chroma the same
    /// *fraction* of its luminance that the desktop's chroma was of the
    /// desktop's, which makes the composite's off-neutrality a roughly fixed
    /// multiple of the desktop's own whatever the desktop is: **1.0–1.3×
    /// before, 0.5–0.7× after**. The measured dark composite becomes
    /// 0.078/0.106/0.119 — 0.229 off-neutral, cool but no longer coloured, and
    /// with red back at 65% of blue instead of 38%. Light is unchanged for
    /// every wallpaper dimmer than the 0.72 target, which is nearly all of them.
    /// `gain` is divided back out because `CIColorControls`' contrast scales
    /// channel *differences* along with the luminance range — see
    /// `rangeGain(spread:isDark:)`. Without this the range cap would damp the
    /// wallpaper's colour as a side effect of damping its dynamic range, which
    /// is the one thing the whole layer exists to show.
    static func saturation(mean: Double, isDark: Bool, gain: Double = 1) -> Double {
        let target = targetLuminance(isDark: isDark)
        return saturationCeiling(isDark: isDark)
            * min(1, target / max(mean, 0.02))
            / max(gain, 0.05)
    }

    /// The widest luminance range a **dark** baked still may carry, p5..p95 of
    /// the 16×16 box reduction — and the constant that lets the dark veil get
    /// out of the way.
    ///
    /// Michael's ask was "dark glass could look more glassy/translucent…
    /// especially on live and wallpaper". The veil is the obvious lever and it
    /// was already the binding one: at the shipped 0.52 base, the *worst patch*
    /// of the most extreme wallpaper in this Mac's aerial library (`AB7FC3C3`,
    /// luma 0.435 — a bright sky over dark ground, box spread **0.615**, 1.7×
    /// the next widest) measured **4.6:1** secondary contrast against a 4.5
    /// floor. There was no room to thin anything.
    ///
    /// The reason is that the bake normalized the still's *mean* and left its
    /// *range* alone, so how bright the brightest patch of the sidebar got was
    /// still a function of the user's desktop — the exact dependency
    /// `targetLuminance` exists to remove, surviving in the second moment.
    /// `CIColorControls`' contrast is a gain about 0.5, so solving it together
    /// with the brightness offset removes it: the still's range is capped, its
    /// mean still lands on target, and the surface's worst case stops depending
    /// on the picture.
    ///
    /// Dark sidebar, worst-patch (brightest 2% band) secondary contrast against
    /// a 4.5 floor, measured by rendering:
    ///
    ///     veil 0.52, no cap    4.6 : 1   ← shipped; already at the floor
    ///     veil 0.34, no cap    3.9 : 1   ← thinning the veil alone fails
    ///     veil 0.34, cap 0.30  4.9 : 1   ← shipped here
    ///
    /// The cap does more for the worst case than the veil it buys out, which is
    /// why the surface can be a third more transparent *and* better on its worst
    /// wallpaper at the same time.
    ///
    /// The gain is computed from the *unblurred* box, which over-states what
    /// actually reaches the veil — radius 28 on a 176px still smooths most of a
    /// photograph's range away, so the cap is deliberately conservative. What it
    /// does in practice, over the five extremes of this Mac's 156-still aerial
    /// library and with the thinner veil above: the composite's luminance spread
    /// **rises** on four of them (0.086 → 0.095 on Michael's own desktop, 0.064 →
    /// 0.081 on the brightest, 0.022 → 0.034 on the darkest) and **falls** on the
    /// one whose range was the problem (0.197 → 0.158). That asymmetry is the
    /// whole design: more wallpaper everywhere, less of the one thing that was
    /// making the worst case a function of the desktop.
    ///
    /// Light got the same cap one round later, for the same reason — see
    /// `lightStillSpreadCeiling`.
    static let darkStillSpreadCeiling: Double = 0.30

    /// The same bound for **light**, and the constant that lets the light veil
    /// get out of the way.
    ///
    /// Round 3 left light alone on the argument that a 0.72 surface has the
    /// headroom and light was never the complaint. It is the complaint now —
    /// "light mode should also be translucent to wallpaper much better" — and
    /// rendering the light surface says the headroom was never really there:
    /// with the shipped 0.60 veil the *worst patch* of an adversarial ramp
    /// measured **7.27:1** primary against a 7.0 floor, so thinning the light
    /// veil by even a step took primary below the floor. Light was closer to its
    /// limit than dark ever was; it merely had no test looking.
    ///
    /// The cap is the same lever and it does the same work, mirrored. In light
    /// the worst patch is the *darkest* pixel, and the bake's linear map is
    /// `out = (in - mean)·gain + target`, so a gain below 1 lifts the darkest
    /// patch toward the target — exactly the patch the floor is measured on.
    ///
    /// It also fixes a second thing that was wrong on its own terms. The light
    /// bake is the mirror of the dark black-crush `bakeColorSpace` describes,
    /// in a milder form: normalizing a dim wallpaper *up* to 0.72 pushes its
    /// highlights past 1. Rendered against this Mac's aerial library, the
    /// widest-range still arrived with **17.3%** of its pixels clipped, and an
    /// adversarial full-range ramp with **19.1% blown to flat white** — range
    /// the surface could not show however thin the veil got. With the cap both
    /// are **0.0%**.
    ///
    /// Light sidebar/workspace, worst-patch contrast over the five extremes of
    /// this Mac's aerial library plus four blur-invariant ramp fixtures:
    ///
    ///     veil 0.60, no cap    P 9.08 / 7.27   S 3.43 / 3.17   ← shipped
    ///     veil 0.45, no cap    P 7.49 / 5.9    S 3.20 / 2.9    ← veil alone fails
    ///     veil 0.45, cap 0.26  P 9.05 / 8.88   S 3.43 / 3.40   ← shipped here
    ///
    /// **0.26 rather than dark's 0.30** because light's contrast budget is far
    /// tighter: black ink on a near-white surface tops out at 3.98:1 for the
    /// secondary role whatever the surface does (see
    /// `GlassBackdropWash.sidebar(isDark:)`), so every point of transmission
    /// costs more of what little margin there is. 0.26 is the value at which the
    /// worst-patch secondary returns exactly to its pre-change figure at the
    /// chosen veil — the honest stopping point, not a round number.
    static let lightStillSpreadCeiling: Double = 0.26

    /// The widest luminance range a baked still may carry, per appearance.
    ///
    /// Retained as the *declared* bound the two veil ceilings are priced
    /// against; the gain is no longer solved from it. See
    /// `tailHeadroom(isDark:)` for what replaced it and why.
    static func stillSpreadCeiling(isDark: Bool) -> Double {
        isDark ? darkStillSpreadCeiling : lightStillSpreadCeiling
    }

    /// How far above (dark) or below (light) `targetLuminance` the baked still's
    /// **worst patch** may sit — and the constant that makes room for the
    /// texture without spending a point of legibility.
    ///
    /// The p5..p95 cap this replaces was a *proxy*. Every contrast floor in this
    /// file is measured on the worst patch — the mean of the brightest 2% of the
    /// surface in dark, the darkest 2% in light — and a percentile band by
    /// construction says nothing about the tail outside it. Rendering the
    /// shipped pipeline over this Mac's aerial extremes and the ramp fixtures
    /// shows how loose the proxy was: the still's tail excursion ranged from
    /// 0.027 to **0.151** while every one of those stills sat inside the 0.30
    /// p5..p95 ceiling. The worst wallpaper on the machine (`A92E4A3F`, box
    /// spread 0.856) landed at 4.52:1 secondary against the 4.5 floor — the
    /// margin was **0.02**, and nothing in the bake knew.
    ///
    /// Capping the tail instead is both exact and one division. The tone map is
    /// affine — `out = (in − mean)·gain + target` — so
    ///
    ///     out(tail) − target = (tail − mean) · gain
    ///
    /// and bounding the left side is solving for the gain directly:
    /// `gain = min(1, headroom / |tail − mean|)`. The quantity the floor is
    /// stated in is now the quantity the bake controls, for every wallpaper
    /// rather than for the p5..p95 of one.
    ///
    /// **0.145 dark / 0.124 light** are the shipped pipeline's own worst
    /// excursions (0.151 and 0.131), taken a step under. So the surface's worst
    /// case cannot be worse than the worst case that already shipped — and for
    /// every *other* wallpaper it is now bounded by the same number instead of
    /// being left wherever the picture happened to put it. Measured across the
    /// six real aerial extremes and the six ramp fixtures, on both surfaces, the
    /// worst patch improves in both appearances: dark 4.52 → **4.55**, light
    /// 3.43 → **3.44**, primary 8.29 → **8.38** and 9.05 → **9.16**.
    ///
    /// That is what pays for `blurFraction`. Three rounds in a row found that
    /// letting more of the wallpaper through costs contrast the floors do not
    /// have; this one tightens the cap onto the exact quantity at issue first,
    /// and spends the slack on structure.
    static let darkTailHeadroom: Double = 0.145
    static let lightTailHeadroom: Double = 0.124

    static func tailHeadroom(isDark: Bool) -> Double {
        isDark ? darkTailHeadroom : lightTailHeadroom
    }

    /// The gain `CIColorControls.contrast` is set to, from the distance between
    /// the baked structure's mean and its worst patch. Never above 1: a
    /// wallpaper whose worst patch is already inside the headroom is passed
    /// through exactly as it was, so this only ever *removes* an excess and can
    /// never manufacture contrast the desktop does not have.
    static func tailGain(excursion: Double, isDark: Bool) -> Double {
        min(1, tailHeadroom(isDark: isDark) / max(excursion, 0.001))
    }

    /// Mean luminance the baked still is moved to, per appearance.
    ///
    /// `NSVisualEffectView` normalized luminance for us; a raw wallpaper does
    /// not, so before this the legibility of every label in the app was a
    /// function of the user's desktop picture — a white wallpaper in dark mode
    /// put tertiary text on a pale surface. Normalizing here makes the veil's
    /// coverage arithmetic land on known ground for *any* desktop: the still
    /// always arrives at these luminances, so the composite always lands near
    /// 0.60·1.0 + 0.40·0.72 ≈ 0.89 in light and 0.60·0.05 + 0.40·0.16 ≈ 0.09 in
    /// dark. The wallpaper still supplies hue and its large-scale gradient; it
    /// no longer supplies brightness.
    static func targetLuminance(isDark: Bool) -> Double { isDark ? 0.16 : 0.72 }

    /// The additive shift that moves a still of mean luminance `mean` onto
    /// `targetLuminance`.
    ///
    /// Additive rather than multiplicative on purpose. `CIColorControls`'
    /// brightness is a straight per-channel offset, so it moves mean luminance
    /// by exactly this amount while leaving every channel *difference* — the
    /// hue and the chroma spread the frost exists to show — untouched. An
    /// exposure step would scale chroma along with brightness and make a dark
    /// wallpaper's tint vanish in light mode. Clamped only to keep a degenerate
    /// decode (a fully black or blown-out still) from inverting into a shift
    /// larger than the range it is correcting; inside the clamp the
    /// normalization is exact.
    ///
    /// `gain` is the range cap's contrast, and it has to be solved *with* the
    /// offset rather than before it. Measured on the real filter (see
    /// `rangeGain(spread:isDark:)`), `CIColorControls` evaluates saturation,
    /// then contrast about **0.5**, then brightness — so a gain below 1 has
    /// already moved the mean to `(mean - 0.5) · gain + 0.5` by the time this
    /// offset lands, and normalizing against the raw mean would miss by
    /// `(0.5 - mean) · (1 - gain)`. At gain 1 this is the identical expression
    /// it always was.
    static func luminanceShift(mean: Double, isDark: Bool, gain: Double = 1) -> Double {
        let pivoted = (mean - 0.5) * gain + 0.5
        return min(0.9, max(-0.9, targetLuminance(isDark: isDark) - pivoted))
    }

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

        // The tint is the wallpaper's own average and so is read from the raw
        // thumbnail, unchanged.
        let tint = DesktopTintSampler.pixels(image: still)
            .flatMap { DesktopTintSampler.wallpaperAverage(rgba: $0) }
            ?? DesktopTintSampler.fallback
        guard let blurred = blur(still, isDark: key.isDark) else { return .flat(tint) }
        return .wallpaper(blurred, tint: tint)
    }

    /// The colour space the bake's arithmetic is done in, and the fix for
    /// "the dark glass still reads flat".
    ///
    /// `CIContext` colour-manages by default: its working space is **linear**
    /// sRGB, so every filter operates on linearized values. `luminanceShift` is
    /// measured in the opposite space — `DesktopTintSampler.meanLuminance` reads
    /// a `CGContext` raster in `DeviceRGB`, i.e. gamma-**encoded** bytes. The
    /// bake was therefore subtracting an encoded quantity from linear values.
    ///
    /// It is not a rounding error. For Michael's own desktop the encoded mean is
    /// 0.438 and the shift is −0.278, but that still's *linear* mean is 0.17, so
    /// the offset drove the whole image past zero: the rendered dark still came
    /// back **79.7% pure black**, mean luminance **0.0021** against the 0.16 it
    /// declares. The dark surface was a veil over black — a single flat colour
    /// with a 0.010 luminance spread across the entire sidebar. That is the
    /// flatness, and no amount of veil tuning could have reached it, because
    /// there was nothing underneath the veil to let through.
    ///
    /// (Light suffered the mirror version and got away with it. Adding 0.282 in
    /// linear space then re-encoding happens to land near the 0.72 target, so
    /// light merely lost structure — spread 0.039 where the same constants in
    /// the measured space give 0.063 — rather than losing the picture.)
    ///
    /// Doing the arithmetic where it was measured fixes both: the dark still
    /// arrives at mean 0.153 with 2.1% black and a 0.167 spread, and the
    /// composite lands on 0.089/0.105/0.112 — which is, to three decimals, the
    /// surface v1.1.9's constants were *designed* to produce and modelled as
    /// producing. The constants were right; they were being evaluated in the
    /// wrong space.
    ///
    /// sRGB rather than `NSNull` (which would disable colour management
    /// entirely): a Display P3 or HDR wallpaper must still be converted before
    /// its bytes are treated as sRGB, or a wide-gamut desktop would bake with
    /// the wrong primaries. This asks for management *into the space the
    /// measurement is taken in*, which is the actual requirement.
    ///
    /// The cost is that the Gaussian is no longer a physically linear blur.
    /// Blurring in the encoded space is slightly "darker" through high-contrast
    /// edges — irrelevant at radius 28 on a 176px still whose whole job is to
    /// stop being a picture, and the same trade every design tool makes by
    /// default.
    static let bakeColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    /// Structure first, then measure, then tone-map.
    ///
    /// The order is the change. The bake used to solve its gain and offset from
    /// a 16×16 box of the *source* thumbnail and then apply them blind, which
    /// meant every constant was stated about a picture the veil never actually
    /// saw — a proxy two blurs removed from the surface. It now builds the
    /// structure it intends to show, renders that once, measures the two
    /// quantities the guarantees are written in (its mean, and its worst patch),
    /// and solves the tone map against those. The normalization stops being an
    /// estimate and becomes arithmetic.
    ///
    /// `clampedToExtent` before the blur, cropped back after: without it the
    /// Gaussian averages in transparent black at every edge and the backdrop
    /// arrives with a dark vignette exactly where the window's corners are.
    private static func blur(_ image: CGImage, isDark: Bool) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent

        var options: [CIContextOption: Any] = [.useSoftwareRenderer: false]
        // See `bakeColorSpace`. Falls through to the default working space only
        // if the system cannot vend sRGB, which is the pre-v1.1.10 behaviour —
        // degraded, not broken.
        if let bakeColorSpace { options[.workingColorSpace] = bakeColorSpace }
        let context = CIContext(options: options)

        let gaussian = CIFilter.gaussianBlur()
        gaussian.inputImage = input.clampedToExtent()
        gaussian.radius = Float(blurRadius)
        guard let softened = gaussian.outputImage else { return nil }

        // The local-contrast add-back. Zero-mean by construction, so it changes
        // how the still's range is distributed and not how much of it there is —
        // and whatever it does to the extremes is measured on the very next
        // line and paid for by the gain.
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = softened
        unsharp.radius = Float(blurRadius * localContrastRadiusFactor)
        unsharp.intensity = Float(localContrastIntensity)
        guard let structured = unsharp.outputImage,
              let probe = context.createCGImage(structured, from: extent),
              let sampled = DesktopTintSampler.pixels(image: probe, side: probeSide)
        else { return nil }

        let mean = DesktopTintSampler.meanLuminance(rgba: sampled)
            ?? targetLuminance(isDark: isDark)
        let tail = DesktopTintSampler.worstPatchLuminance(rgba: sampled, isDark: isDark) ?? mean
        let gain = tailGain(excursion: abs(tail - mean), isDark: isDark)
        let brightness = luminanceShift(mean: mean, isDark: isDark, gain: gain)
        let saturation = saturation(mean: mean, isDark: isDark, gain: gain)

        // All three normalizations ride the one `CIColorControls` pass already
        // in the chain, so none costs an extra filter. The filter evaluates
        // saturation, then contrast about 0.5, then brightness — measured, not
        // assumed — which is why chroma, range and mean have to be solved
        // together rather than treated as three independent constants. See
        // `saturation(mean:isDark:gain:)`, `tailGain(excursion:isDark:)` and
        // `luminanceShift(mean:isDark:gain:)`.
        let controls = CIFilter.colorControls()
        controls.inputImage = structured
        controls.saturation = Float(saturation)
        controls.contrast = Float(gain)
        controls.brightness = Float(brightness)
        guard let output = controls.outputImage else { return nil }
        return context.createCGImage(output, from: extent)
    }

    /// Side of the square reduction the bake measures its own structure on.
    ///
    /// 96 rather than the tint's 16: the worst patch is a 2% tail, and 256
    /// samples put only five pixels in it — enough for a mean but not for a
    /// stable one. 9216 samples put 184 there. It is also fine enough to still
    /// contain the mid-frequency band `blurFraction` keeps, which a 16×16
    /// reduction averages away completely — measuring the tail on that box would
    /// reintroduce exactly the proxy this replaced.
    static let probeSide = 96
}

struct DesktopTintComponents: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
}

enum DesktopTintSampler {
    /// The tint when there is no desktop to read: a plain grey at the same
    /// Rec. 709 luma the old slate fallback had (0.4237), but achromatic.
    ///
    /// It was 0.38/0.43/0.49 — a blue-grey — so the one case where Kaisola
    /// knows *nothing* about the wallpaper was also the case where it invented
    /// the most blue.
    static let fallback = DesktopTintComponents(red: 0.42, green: 0.42, blue: 0.42)

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
    /// Floors low enough that a dark wallpaper stays dark, and achromatic, so
    /// clamping a very dark or very bright desktop cannot introduce a hue the
    /// wallpaper does not have. The blue floor used to sit 0.02 above the other
    /// two, which meant every near-black desktop resolved to a *blue*
    /// near-black. The veil above is what guarantees legibility; clamping here
    /// only prevents a degenerate tint.
    static let floors = (red: 0.07, green: 0.07, blue: 0.07)
    static let ceilings = (red: 0.91, green: 0.91, blue: 0.91)

    static func sample(image: CGImage) -> DesktopTintComponents {
        guard let pixels = pixels(image: image) else { return fallback }
        return wallpaperAverage(rgba: pixels) ?? fallback
    }

    /// The 16×16 box reduction both the tint and the bake's luminance
    /// normalization read, exposed so one decode produces both instead of
    /// drawing the same image twice.
    static func pixels(image: CGImage, side: Int = 16) -> [UInt8]? {
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
        return drew ? pixels : nil
    }

    /// Rec. 709 luma of the wallpaper's plain average — no chroma softening,
    /// no floors.
    /// This is what the bake normalizes against, so it has to describe the
    /// picture rather than the tint derived from it.
    static func meanLuminance(rgba: [UInt8]) -> Double? {
        guard let average = plainAverage(rgba: rgba) else { return nil }
        return average.0 * 0.2126 + average.1 * 0.7152 + average.2 * 0.0722
    }

    /// Mean luminance of the extreme 2% band — the brightest in dark, the
    /// darkest in light.
    ///
    /// This is the still-side twin of the worst patch every contrast floor in
    /// this app is measured on, and it is what the bake's cap is solved against.
    /// A percentile *band* (p5..p95) deliberately excludes the tail; the tail is
    /// precisely where white text on dark glass is hardest to read, so the
    /// quantity the guarantee is written in has to be the quantity the bake
    /// bounds. See `DesktopBackdropRenderer.tailHeadroom(isDark:)`.
    static func worstPatchLuminance(rgba: [UInt8], isDark: Bool) -> Double? {
        var lumas: [Double] = []
        lumas.reserveCapacity(rgba.count / 4)
        var index = 0
        while index + 3 < rgba.count {
            if Double(rgba[index + 3]) / 255 > 0.05 {
                lumas.append(
                    Double(rgba[index]) / 255 * 0.2126
                        + Double(rgba[index + 1]) / 255 * 0.7152
                        + Double(rgba[index + 2]) / 255 * 0.0722
                )
            }
            index += 4
        }
        guard lumas.count >= 50 else { return nil }
        lumas.sort()
        let count = max(1, lumas.count / 50)
        let band = isDark ? lumas.suffix(count) : lumas.prefix(count)
        return band.reduce(0, +) / Double(count)
    }

    /// The wallpaper's p5..p95 luminance range, read from the same box the mean
    /// is — the *second* moment the bake normalizes, and the one that decides
    /// how bright the brightest patch of a glass surface gets.
    ///
    /// Percentiles rather than min..max because a 16×16 box has 256 samples and
    /// one blown highlight in a corner should not set the gain for the whole
    /// picture. Two samples either end are trimmed, so a wallpaper needs a real
    /// bright *region* to be treated as high-range.
    static func luminanceSpread(rgba: [UInt8]) -> Double? {
        var lumas: [Double] = []
        var index = 0
        while index + 3 < rgba.count {
            if Double(rgba[index + 3]) / 255 > 0.05 {
                lumas.append(
                    Double(rgba[index]) / 255 * 0.2126
                        + Double(rgba[index + 1]) / 255 * 0.7152
                        + Double(rgba[index + 2]) / 255 * 0.0722
                )
            }
            index += 4
        }
        guard lumas.count >= 20 else { return nil }
        lumas.sort()
        let count = Double(lumas.count)
        return lumas[Int(count * 0.95)] - lumas[Int(count * 0.05)]
    }

    private static func plainAverage(rgba: [UInt8]) -> (Double, Double, Double)? {
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
        return (red / count, green / count, blue / count)
    }

    /// The wallpaper's average, with its chroma pulled toward luminance and
    /// clamped — and **nothing else mixed in**.
    ///
    /// This was `cooledAverage`, and it earned the name: it blended 10% of a
    /// cool slate (0.35/0.42/0.50) into every sampled tint. The intent was to
    /// keep a near-neutral desktop from picking up a random cast, but a
    /// constant blue-grey stop does not prevent a cast — it *is* one, applied
    /// unconditionally, and it is the second half of the blue-purple tone. A
    /// grey desktop now comes back grey because the wallpaper is grey, not
    /// because a slate was averaged into it, and the only hue in the result is
    /// the desktop's own. Renamed to match: it is the wallpaper's average, not
    /// a cooled one.
    /// The desktop's hue at a chosen value: the sampled tint scaled so its
    /// brightest channel lands on `peak`, hue and channel ratios untouched.
    ///
    /// This is what makes the Tinted canvas *tinted* rather than merely dimmer.
    /// Compositing the raw sample over the canvas moves brightness and hue
    /// together, and brightness dominates: at the coverage a canvas can afford,
    /// the surface reads as "slightly grey white" and not as "tinted". Michael's
    /// note is exactly that — "the tinted canvas settings should actually be
    /// tinted or a white solid" — and measured against the real desktop the old
    /// Tinted canvas sat **0.016** off-neutral in light, against Solid's 0.000.
    /// Nothing to see.
    ///
    /// Re-valuing first separates the two. In light the tint goes to full value
    /// (peak 1) so the composite keeps the canvas's brightness and takes only
    /// its hue; in dark it goes to a low value so it takes the hue without
    /// turning the canvas into a lamp.
    static func revalued(_ tint: DesktopTintComponents, peak: Double) -> DesktopTintComponents {
        let brightest = max(tint.red, max(tint.green, tint.blue))
        guard brightest > 0.001 else {
            return DesktopTintComponents(red: peak, green: peak, blue: peak)
        }
        let scale = peak / brightest
        return DesktopTintComponents(
            red: min(1, tint.red * scale),
            green: min(1, tint.green * scale),
            blue: min(1, tint.blue * scale)
        )
    }

    /// Value the Tinted canvas re-values the desktop's hue to, per appearance.
    /// Light takes it at full value (over white, that is pure hue and almost no
    /// dimming); dark takes it just above the canvas it sits on.
    static func canvasTintPeak(isDark: Bool) -> Double { isDark ? 0.34 : 1.0 }

    /// Coverage of the re-valued tint at the two ends of the canvas gradient.
    /// Same light-from-above language as the glass veil.
    static func canvasTintCoverage(isDark: Bool) -> (top: Double, bottom: Double) {
        isDark ? (top: 0.55, bottom: 0.38) : (top: 0.45, bottom: 0.30)
    }

    static func wallpaperAverage(rgba: [UInt8]) -> DesktopTintComponents? {
        guard let wallpaper = plainAverage(rgba: rgba) else { return nil }
        let luminance = wallpaper.0 * 0.2126 + wallpaper.1 * 0.7152 + wallpaper.2 * 0.0722
        let softened = (
            luminance + (wallpaper.0 - luminance) * chromaRetention,
            luminance + (wallpaper.1 - luminance) * chromaRetention,
            luminance + (wallpaper.2 - luminance) * chromaRetention
        )
        return DesktopTintComponents(
            red: min(ceilings.red, max(floors.red, softened.0)),
            green: min(ceilings.green, max(floors.green, softened.1)),
            blue: min(ceilings.blue, max(floors.blue, softened.2))
        )
    }
}

/// How much of the desktop one watch tick is allowed to read.
///
/// The two rungs are two orders of magnitude apart, measured on this machine:
/// three `stat`s cost **0.045 ms**, and `NSWorkspace.desktopImageURL(for:)`
/// costs **4.1 ms** — and the latter has to run on the main actor, because
/// `NSScreen` is not `Sendable`. A 4 ms main-thread stall is a dropped frame,
/// so it cannot be what a five-second timer does.
enum DesktopProbeDepth: Equatable, Sendable {
    /// `stat` only: the painted file, the wallpaper store's index, and the
    /// aerial thumbnail cache. Catches every desktop change that goes through
    /// the wallpaper store, which on macOS 26 is every change made from System
    /// Settings, Finder's "Set Desktop Picture", or the Wallpaper API.
    case shallow
    /// The above plus `desktopImageURL(for:)`. The only thing this adds is a
    /// desktop whose *path* moved without the store being rewritten — a
    /// rotating picture folder advancing — so it is taken on a slow cadence
    /// rather than every tick.
    case deep
}

/// The cheap fingerprint of "which picture the desktop is showing".
///
/// Nothing in AppKit publishes a wallpaper-changed event that can be relied on
/// (see `DesktopBackdropProvider.desktopChangedNotification` for what is
/// observed and what that is worth), so the backstop is this: a handful of
/// modification dates that a change cannot avoid moving, compared on a timer.
/// It is deliberately *not* the backdrop cache key — building that key reads
/// and parses two files, and this has to be affordable every few seconds.
struct DesktopWallpaperSignature: Equatable, Sendable {
    /// What `NSWorkspace` reports, on a `deep` probe only; `nil` on a shallow
    /// one, and a `nil` on either side is not evidence of a change.
    let desktopImagePath: String?
    /// The file the current backdrop was baked from — "set as desktop picture"
    /// over a path that never changed lands here.
    let paintedModified: Date?
    /// `Store/Index.plist`, which the wallpaper agent rewrites for every
    /// desktop choice, including picking a different aerial *category*.
    let storeModified: Date?
    /// The aerial thumbnail cache directory. A rotating category has no
    /// published pointer at the clip playing right now, so the backdrop picks a
    /// deterministic representative from the stills macOS has downloaded — and
    /// this directory's mtime is what moves when that set grows.
    let thumbnailsModified: Date?
}

/// What a watch tick found, against the previous one.
enum DesktopSignalDecision: Equatable {
    /// Nothing moved, or there is no baseline yet — either way, no hint.
    case unchanged
    /// Something the desktop is made of moved. Hint the provider.
    case changed
}

/// What a "the desktop may have changed" hint should do about it.
enum DesktopResolveDecision: Equatable {
    /// The rate-limit floor has expired; read the desktop now.
    case resolveNow
    /// Inside the floor with nothing armed yet: arm one resolve for when the
    /// floor expires, in `after` seconds.
    case deferBy(TimeInterval)
    /// Inside the floor and a deferred resolve is already armed. Doing nothing
    /// is correct — the armed resolve will pick up whatever this hint saw.
    case alreadyScheduled
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

    /// The floor between two disk reads. Every hint — notification, watch tick,
    /// or activation — is funnelled through it.
    static let minimumResolveInterval: TimeInterval = 2
    /// Enough for a light/dark pair on each of two recently seen desktops.
    private static let cacheLimit = 4

    /// The distributed notification the wallpaper agent posts when the desktop
    /// changes, and an honest account of what observing it is worth.
    ///
    /// `WallpaperAgent` links `NSDistributedNotificationCenter` and carries the
    /// string `com.apple.desktop`, so the long-standing notification is very
    /// likely still posted on macOS 26 — but that is inference from `nm` and
    /// `strings`, not a measurement: confirming it needs an actual desktop
    /// change, and changing the developer's desktop to find out is not a thing
    /// this code is allowed to do. So it is observed as a *fast path* and
    /// nothing depends on it. `desktopWatchInterval` below is the guarantee.
    static let desktopChangedNotification = Notification.Name("com.apple.desktop")

    /// How often the shallow watch tick runs while Kaisola is the active app.
    ///
    /// Three `stat`s, 0.045 ms — 0.001% duty at this cadence, and the timer
    /// carries a wide tolerance so the wakeups coalesce with whatever else the
    /// process is doing. It is suspended entirely when the app is not active,
    /// because `didBecomeActive` already forces a resolve on the way back in,
    /// which makes an unattended app cost exactly nothing.
    static let desktopWatchInterval: TimeInterval = 5
    /// How often a tick is allowed to be `deep` — see `DesktopProbeDepth`.
    static let desktopDeepProbeInterval: TimeInterval = 30

    private var cache: [DesktopBackdropKey: DesktopPainting] = [:]
    private var cacheOrder: [DesktopBackdropKey] = []
    private var work: Task<Void, Never>?
    private var deferredResolve: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    /// Bumped on every resolve so a detached stage that finishes after a newer
    /// resolve started cannot publish its stale painting. `Task.cancel()` is not
    /// enough on its own: `Task.detached` deliberately does not inherit
    /// cancellation, so the decode and the bake always run to completion once
    /// started and the only safe thing to do with a superseded result is to
    /// drop it here.
    private var generation = 0
    private var lastResolved = Date.distantPast
    private var lastAppearanceIsDark: Bool?
    private var observers: [any NSObjectProtocol] = []
    private var lastKey: DesktopBackdropKey?
    private var lastDeepProbe = Date.distantPast

    /// The last fingerprint a watch tick read, and the number of times anything
    /// has said "the desktop may have changed".
    ///
    /// Deliberately not `@Published`: a hint is not a repaint, and publishing
    /// one would invalidate every glass surface in the app on a timer. They are
    /// observable so the watch can be *proved* to fire rather than asserted to —
    /// see `testTheWallpaperWatchFiresOnADistributedDesktopNotification`.
    private(set) var wallpaperSignature: DesktopWallpaperSignature?
    private(set) var wallpaperSignals = 0

    var tintColor: Color {
        let tint = painting.tint
        return Color(red: tint.red, green: tint.green, blue: tint.blue)
    }

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        // Space switches and screen reconfiguration can both change which
        // desktop picture applies; becoming key is when a wallpaper the user
        // changed in System Settings first matters to us; waking is when a
        // desktop set to rotate "on wake" has already rotated.
        observers = [
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.noteDesktopSignal()
                    self?.startWatching()
                }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stopWatching() } },
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
            // The fast path. `object: nil` because the agent's object string is
            // not documented and has changed across releases; the name alone is
            // specific enough, and a spurious hint costs one coalesced resolve.
            distributed.addObserver(
                forName: Self.desktopChangedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteDesktopSignal() } },
        ]
    }

    /// Whether a hint should resolve now, arm a deferred resolve, or defer to
    /// one that is already armed.
    ///
    /// Pure so the coalescing rule is testable without a clock, a desktop, or a
    /// run loop — the previous rule looked correct in the source and was inert
    /// in fact, which is the failure mode a unit test catches and a reading
    /// does not.
    static func hintDecision(
        now: Date,
        lastResolved: Date,
        deferredResolveArmed: Bool,
        floor: TimeInterval = minimumResolveInterval
    ) -> DesktopResolveDecision {
        let elapsed = now.timeIntervalSince(lastResolved)
        if elapsed >= floor { return .resolveNow }
        if deferredResolveArmed { return .alreadyScheduled }
        return .deferBy(floor - elapsed)
    }

    /// How much a watch tick at `now` is allowed to read.
    ///
    /// Pure, so the "4 ms call is not on the 5-second path" rule is a test
    /// rather than a comment that a later edit can quietly break.
    static func probeDepth(
        now: Date,
        lastDeepProbe: Date,
        interval: TimeInterval = desktopDeepProbeInterval
    ) -> DesktopProbeDepth {
        now.timeIntervalSince(lastDeepProbe) >= interval ? .deep : .shallow
    }

    /// Whether a fingerprint that just came back means the desktop moved.
    ///
    /// Two rules that are easy to get wrong and impossible to see in a reading:
    ///
    /// * **No baseline is not a change.** The first tick after a resolve exists
    ///   to record what "unchanged" looks like. Treating it as a change would
    ///   make the watch re-resolve every time it started.
    /// * **A field only one side has proves nothing.** A shallow tick does not
    ///   pay for `desktopImageURL`, so its `desktopImagePath` is `nil`; if a
    ///   missing value counted as different, every shallow tick after a deep one
    ///   would fire, and the whole point of the two rungs would be lost.
    static func signalDecision(
        previous: DesktopWallpaperSignature?,
        current: DesktopWallpaperSignature
    ) -> DesktopSignalDecision {
        guard let previous else { return .unchanged }
        if previous.paintedModified != current.paintedModified { return .changed }
        if previous.storeModified != current.storeModified { return .changed }
        if previous.thumbnailsModified != current.thumbnailsModified { return .changed }
        if let old = previous.desktopImagePath,
           let new = current.desktopImagePath,
           old != new { return .changed }
        return .unchanged
    }

    /// The fingerprint itself. `modificationDate` is injected so the whole rule
    /// — which files are read, and which of them a `deep` probe adds — is
    /// testable against a fixture directory rather than against the developer's
    /// own desktop.
    nonisolated static func signature(
        depth: DesktopProbeDepth,
        desktopImagePath: String?,
        paintedPath: String?,
        supportDirectory: URL,
        modificationDate: (URL) -> Date?
    ) -> DesktopWallpaperSignature {
        DesktopWallpaperSignature(
            desktopImagePath: depth == .deep ? desktopImagePath : nil,
            paintedModified: paintedPath.flatMap { modificationDate(URL(fileURLWithPath: $0)) },
            storeModified: modificationDate(supportDirectory.appending(path: "Store/Index.plist")),
            thumbnailsModified: modificationDate(
                supportDirectory.appending(path: "aerials/thumbnails", directoryHint: .isDirectory)
            )
        )
    }

    nonisolated static func modificationDateOnDisk(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Whether the watch is currently armed. Observable so "an app with no
    /// glass surface never starts a timer" is a test rather than a claim.
    var isWatchingDesktop: Bool { watch != nil }

    /// Start the watch. Idempotent, and a no-op until a glass surface has
    /// actually asked for a backdrop — an app whose windows are all solid
    /// never starts a timer.
    private func startWatching() {
        guard watch == nil, lastAppearanceIsDark != nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(Self.desktopWatchInterval),
                    tolerance: .seconds(Self.desktopWatchInterval / 2)
                )
                guard !Task.isCancelled, let self else { return }
                await self.probeDesktop()
            }
        }
    }

    private func stopWatching() {
        watch?.cancel()
        watch = nil
    }

    /// One watch tick.
    ///
    /// The main actor pays only for `desktopImageURL`, and only on a deep tick;
    /// the `stat`s run detached. A tick that finds nothing does not touch the
    /// backdrop at all, so the steady state is three `stat`s every five seconds
    /// and no allocation, no decode, and no repaint.
    ///
    /// `supportDirectory` is a parameter only so the whole chain — filesystem
    /// change, fingerprint, decision, coalescing door — can be driven end to end
    /// against a fixture. There is no way to test it against the real store: it
    /// would mean changing the developer's desktop.
    func probeDesktop(
        supportDirectory: URL = DesktopWallpaperLocator.defaultSupportDirectory
    ) async {
        guard lastAppearanceIsDark != nil else { return }
        let depth = Self.probeDepth(now: Date(), lastDeepProbe: lastDeepProbe)
        var desktopImagePath: String?
        if depth == .deep {
            lastDeepProbe = Date()
            desktopImagePath = Self.currentScreen()
                .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }?.path
        }
        let paintedPath = lastKey?.path
        let support = supportDirectory
        let current = await Task.detached(priority: .utility) {
            Self.signature(
                depth: depth,
                desktopImagePath: desktopImagePath,
                paintedPath: paintedPath,
                supportDirectory: support,
                modificationDate: Self.modificationDateOnDisk
            )
        }.value
        let decision = Self.signalDecision(previous: wallpaperSignature, current: current)
        wallpaperSignature = current
        guard decision == .changed else { return }
        noteDesktopSignal()
    }

    /// The one door every "the desktop may have changed" signal goes through —
    /// the distributed notification, a watch tick that found something, a Space
    /// switch, a wake, an activation, a screen change, a new key window.
    ///
    /// It records the signal and then defers entirely to `invalidate`, so the
    /// coalescing contract is unchanged: a burst still arms exactly one
    /// deferred resolve, and the generation counter still drops stale bakes.
    private func noteDesktopSignal() {
        wallpaperSignals += 1
        invalidate()
    }

    /// Ask for the backdrop that matches `isDark`. Cheap and idempotent: an
    /// appearance flip always re-resolves, anything else waits out the
    /// rate limit.
    func refresh(isDark: Bool) {
        let appearanceChanged = isDark != lastAppearanceIsDark
        lastAppearanceIsDark = isDark
        // The first surface to ask for a backdrop is what arms the watch; an
        // app with nothing but solid chrome never starts a timer at all.
        startWatching()
        guard appearanceChanged
            || Date().timeIntervalSince(lastResolved) >= Self.minimumResolveInterval else { return }
        // An appearance flip supersedes any armed hint: it is about to do the
        // read that hint was waiting for, and for the newer appearance.
        deferredResolve?.cancel()
        deferredResolve = nil
        lastResolved = Date()
        resolve(isDark: isDark)
    }

    /// A hint arrived that the desktop may have changed.
    ///
    /// The floor exists because these hints are cheap to emit and expensive to
    /// honour: each resolve is an `Index.plist` read, an `entries.json` parse,
    /// and a main-thread `desktopImageURL(for:)` call. It used to be inert —
    /// this method reset `lastResolved` to `.distantPast` and then asked
    /// `refresh` whether enough time had passed since `lastResolved`, which it
    /// always had. Every Space switch, activation, screen change, and key-window
    /// change therefore paid for a full re-resolution.
    ///
    /// Coalescing properly means a hint inside the floor is neither dropped nor
    /// duplicated: it arms exactly one resolve for the moment the floor expires,
    /// and every further hint before then rides on that one.
    private func invalidate() {
        guard lastAppearanceIsDark != nil else { return }
        switch Self.hintDecision(
            now: Date(),
            lastResolved: lastResolved,
            deferredResolveArmed: deferredResolve != nil
        ) {
        case .alreadyScheduled:
            return
        case .resolveNow:
            guard let isDark = lastAppearanceIsDark else { return }
            lastResolved = Date()
            resolve(isDark: isDark)
        case let .deferBy(delay):
            deferredResolve = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.deferredResolve = nil
                guard let isDark = self.lastAppearanceIsDark else { return }
                self.lastResolved = Date()
                self.resolve(isDark: isDark)
            }
        }
    }

    /// Reading the wallpaper URL stays on the main actor — `NSScreen` is not
    /// `Sendable`, so the alternative is smuggling one into a detached task —
    /// but it now runs only on a resolve, and `invalidate` guarantees at most
    /// one of those per `minimumResolveInterval`. The hot path a burst of hints
    /// travels no longer touches it at all.
    private func resolve(isDark: Bool) {
        generation &+= 1
        let generation = generation
        let desktopImageURL = Self.currentScreen()
            .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        work?.cancel()
        work = Task { [weak self] in
            let key = await Task.detached(priority: .utility) {
                Self.key(desktopImageURL: desktopImageURL, isDark: isDark)
            }.value
            guard let self, generation == self.generation else { return }
            // Whatever this resolve concluded is the new baseline: the file it
            // painted has just been read, so the next watch tick must compare
            // against *that* rather than fire a second time on the change this
            // resolve already honoured.
            self.lastKey = key
            self.wallpaperSignature = nil
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
            guard generation == self.generation else { return }
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

/// The one **deliberately non-neutral** layer in the glass stack.
///
/// Everything else the app declares as a backdrop constant is achromatic, and
/// `testDeclaredNeutralConstantsAreAchromatic` enforces that per-channel — that
/// invariant is what caught the `#0B0C12` blue-purple cast, and it must not be
/// weakened. So the v1.1.8 warmth is *not* a warmer "neutral": it is a separate,
/// named, exempt constant with its own test (`testGlassWarmthIsADeclaredAmber`)
/// pinning its hue and its coverage. Anything that wants to be warm has to say
/// so here; anything that claims to be neutral still has to prove it there.
///
/// One flat amber laid over the baked still, before the veil. It is not a
/// gradient and not appearance-dependent: the veil above already carries the
/// light direction and the light/dark balance, and a second gradient under it
/// only muddies both. At 4% over a luminance-normalized still it moves the
/// composite by roughly one step of chroma — the surface reads *slightly
/// warmer*, the way a warm-white room does, rather than orange.
enum GlassWarmth {
    /// `#FFB070`. A high-value amber rather than a saturated orange: the layer
    /// is applied at a few percent, so what matters is the direction it pulls
    /// the composite, and a dark or heavily saturated tint at this coverage
    /// pulls toward *grey-brown* instead of toward warm.
    static let red = 1.0
    static let green = 176.0 / 255
    static let blue = 112.0 / 255

    /// Coverage in light, and the number the dark one is derived from.
    static let opacity = 0.04

    /// Coverage per appearance.
    ///
    /// This used to be one number, on the argument that the still underneath is
    /// luminance-normalized so the same coverage lands on comparable ground in
    /// both appearances. That argument is wrong, and in the same way the
    /// saturation constant was wrong: the still is normalized to 0.72 in light
    /// and 0.16 in dark, a 4.5× difference, and this amber's own luminance is
    /// 0.738. At 4% it lifts a light still by ~0.001 of its luminance and a
    /// dark still by ~0.019 — nineteen times the relative perturbation, in a
    /// hue directly opposite the cool cast the dark surface already had, which
    /// is what turned "blue" into "purple". Coverage therefore scales with the
    /// luminance of the surface it lands on: 4% at 0.72, 0.89% at 0.16.
    ///
    /// It is still a declared amber and still not zero — a warm hint that
    /// survives its own neutrality audit rather than a layer quietly deleted.
    static func opacity(isDark: Bool) -> Double {
        let light = DesktopBackdropRenderer.targetLuminance(isDark: false)
        let target = DesktopBackdropRenderer.targetLuminance(isDark: isDark)
        return opacity * (target / light)
    }

    static var color: Color { Color(red: red, green: green, blue: blue) }
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
    ///
    /// See `SidebarBackdropView` for why the dark half of the pair is so much
    /// smaller than the light one.
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
                // The declared warm layer (v1.1.8), over the still and under
                // the veil. Over, so the desaturated wallpaper is what it warms
                // rather than the other way round; under, because the veil is
                // what decides how much of this whole composite arrives.
                .overlay(GlassWarmth.color.opacity(GlassWarmth.opacity(isDark: colorScheme == .dark)))
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
            // The no-wallpaper rung gets the same warmth, so the two paths do
            // not read as two different materials.
            .overlay(GlassWarmth.color.opacity(GlassWarmth.opacity(isDark: colorScheme == .dark)))
        }
    }
}

/// Reusable material used by both the project sidebar and the workspace file
/// rail, keeping the two left-hand navigation surfaces visually coherent.
struct SidebarBackdropView: View {
    /// Coverage of the sampled desktop average laid over *live* vibrancy.
    ///
    /// Michael's translucency note names both glass sources — "especially on
    /// live and wallpaper" — and in Live the veil is not the only thing between
    /// the user and the desktop: this tint sits under it, so the two coverages
    /// multiply. At the shipped pair the dark Live sidebar passed
    /// `(1 - 0.30) · (1 - 0.52) = 0.336` of the material; the thinner veil alone
    /// takes that to 0.462, and halving the dark tint takes it to **0.561** —
    /// the material behind the window contributes 67% more than it did.
    ///
    /// Halving *dark* specifically, and leaving light at 0.26, is the same
    /// argument this layer was introduced with rather than a new one: the tint
    /// exists because AppKit's light materials are near-white and eat the
    /// desktop's hue, which is a light-appearance problem. A dark `.sidebar`
    /// material is already dark and already carries the desktop's colour, so
    /// most of what a 0.30 tint did there was dim it — the very complaint.
    ///
    /// Light's own translucency ask is answered by the veil rather than here,
    /// and it reaches Live for free: `(1 - 0.26) · (1 - 0.60) = 0.296` of the
    /// material before, `(1 - 0.26) · (1 - 0.45) = 0.407` after — **+38%**,
    /// the same factor the painted source gained, without cutting the one layer
    /// that is carrying the desktop's hue into a near-white material.
    ///
    /// (Unlike the wallpaper source, this cannot be measured offline: it lands
    /// on live vibrancy, whose input is whatever is behind the window. The
    /// numbers above are compositing algebra over the two declared coverages,
    /// which is exactly as much as is knowable without a screenshot.)
    static let liveTint = (dark: 0.15, light: 0.26)

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
                    DesktopGlassLayer(liveMaterial: .sidebar, liveTint: Self.liveTint)
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
            // The white solid. One flat opaque colour, no sampling, no
            // gradient: whatever is on the desktop contributes exactly nothing.
            // `windowBackgroundColor` resolves to #FFFFFF in light and #1E1E1E
            // in dark, so this already *is* the "white solid" — what it lacked
            // was a name that said so and a Tinted option distinct enough for
            // the difference to be visible.
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
            // The desktop's *hue*, laid into the solid canvas — see
            // `DesktopTintSampler.revalued(_:peak:)` for why the sample is
            // re-valued before it is composited. Same neutrality contract as
            // the glass veil: the sampled desktop colour is the only chroma in
            // the stack, no mesh (lavender) stop.
            //
            // Measured against the real desktop, light: Solid 1.000/1.000/1.000
            // (0.000 off-neutral) against Tinted 0.816/0.941/1.000 at the top
            // (0.113 off-neutral, luminance 0.919). Dark: Solid 0.118 flat
            // against Tinted 0.163/0.216/0.240 (0.209 off-neutral). Nobody has
            // to squint to tell which one is on.
            let isDark = colorScheme == .dark
            let tint = DesktopTintSampler.revalued(
                desktop.painting.tint,
                peak: DesktopTintSampler.canvasTintPeak(isDark: isDark)
            )
            let coverage = DesktopTintSampler.canvasTintCoverage(isDark: isDark)
            let color = Color(red: tint.red, green: tint.green, blue: tint.blue)
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [color.opacity(coverage.top), color.opacity(coverage.bottom)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}
