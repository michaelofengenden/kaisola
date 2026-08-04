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

/// How far past legibility the wallpaper under the glass is blurred, as the
/// **scattering length of the material in screen points**.
///
/// A knob rather than a constant because it is the one number in the glass
/// stack that is a taste call rather than a measurement: every contrast floor
/// in this app holds across the whole range (swept and rendered, 14 pt to
/// 56 pt), so what it decides is only how much of the desktop is recognisable
/// through the surface. `balanced` is the shipped 28 pt, which is also roughly
/// where AppKit's own behind-window blur sits.
enum GlassTexture: String, CaseIterable, Identifiable, Sendable {
    case soft
    case balanced
    case crisp

    var id: String { rawValue }
    var title: String {
        switch self {
        case .soft: "Soft"
        case .balanced: "Balanced"
        case .crisp: "Crisp"
        }
    }

    /// Blur radius in screen points.
    /// Blur radius in screen points.
    ///
    /// Crisp was 18, which over a 210pt sidebar is still a dozen soft masses —
    /// blurred enough that no wallpaper reads as itself. 10 keeps individual
    /// features legible as *shapes* while staying well past the point where
    /// text or an icon behind the window could be read through it, which is the
    /// requirement that actually matters.
    var blurPoints: Double {
        switch self {
        case .soft: 44
        case .balanced: 28
        case .crisp: 10
        }
    }
}

/// How much of the desktop's colour the glass carries.
///
/// Scales `DesktopBackdropRenderer.desktopChromaShare`, which is a *target* on
/// the finished still's measured Oklab colourfulness — so this moves how
/// colourful the surface is without touching how bright it is, and without
/// reintroducing any dependence on which hue the wallpaper happens to be.
/// A neutral desktop stays neutral at every setting, because the target is
/// proportional to the wallpaper's own colourfulness and a grey picture's is
/// zero.
enum GlassColour: String, CaseIterable, Identifiable, Sendable {
    case muted
    case balanced
    case vivid

    var id: String { rawValue }
    var title: String {
        switch self {
        case .muted: "Muted"
        case .balanced: "Balanced"
        case .vivid: "Vivid"
        }
    }

    var chromaScale: Double {
        switch self {
        case .muted: 0.45
        case .balanced: 1.0
        case .vivid: 1.8
        }
    }
}

/// How much of the wallpaper the veil lets through.
///
/// The only knob here with a real cost: thinning the veil is exactly what
/// rounds 3 and 4 found the contrast floors could not afford.
///
/// The floors turn out **not** to be what bounds it any more. Rendered across
/// all twenty-seven setting combinations, the worst patch of the worst fixture
/// barely moves — dark secondary 4.97 at 0.92 against 4.89 at 0.80, on a 4.5
/// floor — because the tail cap already bounds the still the veil is letting
/// through, so a thinner veil transmits a *bounded* picture rather than an
/// arbitrary one. That is round 7's cap paying out a second time.
///
/// So the bound is taken from the invariant that is still meaningful:
/// `GlassBackdropWash.desktopTransmissionBand(isDark:)`. **0.89** is the
/// largest step that keeps every surface inside the transmission ceiling those
/// two rounds declared and priced — dark's 0.66 goes to 0.70, exactly the
/// ceiling. Stopping at a declared invariant rather than at "where the test
/// starts failing" is deliberate: the fixtures here are the extremes of the
/// wallpapers we have, not of every desktop a user can choose.
/// `testEveryGlassSettingCombinationStaysLegible` renders the whole grid and
/// `testGlassSettingsPersistAndDefaultToWhatShipped` holds the band.
enum GlassClarity: String, CaseIterable, Identifiable, Sendable {
    case frosted
    case balanced
    case clear

    var id: String { rawValue }
    var title: String {
        switch self {
        case .frosted: "Frosted"
        case .balanced: "Balanced"
        case .clear: "Clear"
        }
    }

    /// Multiplier on every veil coverage. Above 1 is always safe — more veil is
    /// more contrast — so only the step below 1 is bounded by measurement.
    ///
    /// **Clear is a deliberate trade, and the only setting that makes one.**
    ///
    /// It was 0.89 — an 11% thinner veil, which is not a visible difference and
    /// certainly not "clear". It sat there because the same 7:1 / 3.43:1 text
    /// floors were enforced at every clarity, and in light appearance those
    /// floors are what a veil *is*: the worst patch is the darkest 2% of the
    /// surface, thinning the veil darkens it, and dark text on a dark patch
    /// fails no matter how opaque the ink. A transparent light surface over an
    /// arbitrary wallpaper cannot also guarantee 3.43:1 secondary text. That is
    /// physics, not a constant that was tuned badly.
    ///
    /// So Clear now buys what it says on the tin and pays for it honestly: much
    /// more wallpaper, and text contrast that meets a lower stated floor rather
    /// than the default one. Michael asked for this twice — "full crisp and
    /// full clarity to be extremely clear and transparent of the background" —
    /// and it is his setting to choose. Frosted and Balanced are unchanged and
    /// still meet the full floors, and Balanced is still the default.
    ///
    /// `resolved(for:)` is what keeps that from reaching anyone who has told
    /// the system they need contrast.
    var veilScale: Double {
        switch self {
        case .frosted: 1.16
        case .balanced: 1.0
        case .clear: 0.55
        }
    }

    /// Whether this clarity trades text contrast for transparency.
    var relaxesTextContrast: Bool { self == .clear }

    /// The clarity actually used, given the accessibility settings.
    ///
    /// Increase Contrast and Reduce Transparency are explicit statements that
    /// legibility outranks appearance, so Clear is not honoured for anyone who
    /// has set them — it falls back to Balanced, which meets the full floors.
    /// A preference the user typed into Settings must never override one they
    /// typed into System Settings.
    func resolved(increasedContrast: Bool, reduceTransparency: Bool) -> GlassClarity {
        guard self == .clear, increasedContrast || reduceTransparency else { return self }
        return .balanced
    }
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

    @Published var glassTexture: GlassTexture {
        didSet { persist(glassTexture.rawValue, forKey: Keys.glassTexture) }
    }

    @Published var glassColour: GlassColour {
        didSet { persist(glassColour.rawValue, forKey: Keys.glassColour) }
    }

    /// A picture pinned for the glass, independent of the desktop.
    ///
    /// macOS will not say which wallpaper a *rotating* desktop is showing —
    /// a shuffle records only `shuffle-all-aerials` and a cadence, and a
    /// dynamic desktop like Tahoe Day hands back the same stand-in path a
    /// shuffle does. Every automatic route therefore either guesses or needs
    /// the screen-recording permission.
    ///
    /// Naming a file sidesteps the question rather than answering it, which is
    /// what Michael asked for: "I want it to be able to pin a wallpaper even
    /// with a rotation." The desktop keeps rotating; the glass stops chasing
    /// it. Empty means automatic, exactly as before.
    @Published var glassWallpaper: String {
        didSet { persist(glassWallpaper, forKey: Keys.glassWallpaper) }
    }

    @Published var glassClarity: GlassClarity {
        didSet { persist(glassClarity.rawValue, forKey: Keys.glassClarity) }
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
        static let glassTexture = "glassTexture"
        static let glassColour = "glassColour"
        static let glassWallpaper = "glassWallpaper"
        static let glassClarity = "glassClarity"
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
        glassWallpaper = defaults.string(forKey: Keys.glassWallpaper) ?? ""
        glassTexture = defaults.string(forKey: Keys.glassTexture)
            .flatMap(GlassTexture.init) ?? .balanced
        glassColour = defaults.string(forKey: Keys.glassColour)
            .flatMap(GlassColour.init) ?? .balanced
        glassClarity = defaults.string(forKey: Keys.glassClarity)
            .flatMap(GlassClarity.init) ?? .balanced
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

    /// Every coverage scaled by the same factor, clamped so a setting can never
    /// produce a veil outside the range the constants are declared in. The hue
    /// is untouched — this moves how much veil there is, never what colour it
    /// is, so the neutrality invariant holds at every setting.
    func scaled(by factor: Double) -> GlassBackdropWash {
        func coverage(_ value: Double) -> Double { min(0.95, max(0, value * factor)) }
        return GlassBackdropWash(
            red: red,
            green: green,
            blue: blue,
            topOpacity: coverage(topOpacity),
            baseOpacity: coverage(baseOpacity),
            bottomOpacity: coverage(bottomOpacity)
        )
    }

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
    static func sidebar(isDark: Bool, clarity: GlassClarity = .balanced) -> GlassBackdropWash {
        sidebarBase(isDark: isDark).scaled(by: clarity.veilScale)
    }

    private static func sidebarBase(isDark: Bool) -> GlassBackdropWash {
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
    static func workspace(isDark: Bool, clarity: GlassClarity = .balanced) -> GlassBackdropWash {
        workspaceBase(isDark: isDark).scaled(by: clarity.veilScale)
    }

    private static func workspaceBase(isDark: Bool) -> GlassBackdropWash {
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
        aerialStill: () -> URL?,
        captured: URL? = nil
    ) -> DesktopWallpaperResolution {
        // A captured desktop is the picture actually on screen, so it outranks
        // every deduced one. Everything below this line is inference; this line
        // is observation.
        if let captured, readableStill(captured) { return .picture(captured) }
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
        supportDirectory: URL? = nil,
        pinnedWallpaperPath: String? = nil
    ) -> DesktopWallpaperResolution {
        let support = supportDirectory ?? defaultSupportDirectory
        // A picture the user pinned outranks everything: it is a statement of
        // intent, not an inference, so it is not second-guessed even when the
        // desktop could have been identified.
        //
        // `captured:` stays nil while desktop capture is disabled — see the
        // note in `DesktopBackdropProvider.resolve(isDark:)`. A stale file from
        // an earlier build must never be picked up.
        let pinned = (pinnedWallpaperPath ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return resolve(
            desktopImageURL: desktopImageURL,
            readableStill: { CGImageSourceCreateWithURL($0 as CFURL, nil) != nil },
            aerialStill: { currentAerialStill(supportDirectory: support) },
            captured: pinned.isEmpty ? nil : URL(fileURLWithPath: pinned)
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

    /// Whether the store names a *rotating* desktop rather than one picture.
    ///
    /// macOS 26's headline desktops are shuffles, and the store records the
    /// shuffle itself — `shuffle-all-aerials` — where a pinned wallpaper would
    /// record an asset UUID. It is neither a still's name nor a category in the
    /// manifest, whose categories are all UUIDs, so every lookup keyed on it
    /// found nothing and the backdrop fell all the way through to the flat grey
    /// fallback. Michael saw a featureless canvas and reasonably read it as the
    /// glass erasing his wallpaper; the glass had simply never been given one.
    static func isShuffleAssetID(_ id: String) -> Bool {
        id.hasPrefix("shuffle-")
    }

    /// Which aerial a shuffled desktop is currently showing.
    ///
    /// The pick lives in the wallpaper agent and is written nowhere readable —
    /// the store holds only the shuffle's name and its cadence. What the agent
    /// does leave behind is the file it plays, so the most recently *read*
    /// video is the strongest evidence available, and it beats the alternative
    /// (an arbitrary member of the set) decisively.
    ///
    /// It is a heuristic and is documented as one: a shuffle that rotates while
    /// the app sleeps can leave the previous pick as the newest read. That is a
    /// wrong aerial rather than no aerial, which is the trade being made.
    ///
    /// Pure, with the readings injected, so the ordering is testable without a
    /// wallpaper agent.
    static func shuffledAerialStill(
        videoAccess: [(id: String, accessedAt: Date)],
        cachedStillIDs: Set<String>
    ) -> String? {
        videoAccess
            .filter { cachedStillIDs.contains($0.id) }
            .max { $0.accessedAt < $1.accessedAt }?
            .id
    }

    /// Access times for every downloaded aerial video, newest last read first.
    private static func aerialVideoAccess(directory: URL) -> [(id: String, accessedAt: Date)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".mov") else { return nil }
            let url = directory.appending(path: name)
            guard let accessed = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                .modificationDate
            ] as? Date else { return nil }
            // `atime` is what actually tracks playback, and `URLResourceValues`
            // exposes it where `FileAttributeKey` does not.
            let access = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?
                .contentAccessDate ?? accessed
            return (String(name.dropLast(4)), access)
        }
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
        // A shuffle names no category, so ask which video is being played
        // before falling back to a representative member of the set.
        if isShuffleAssetID(assetID) {
            let access = aerialVideoAccess(
                directory: supportDirectory.appending(path: "aerials/videos", directoryHint: .isDirectory)
            )
            if let playing = shuffledAerialStill(videoAccess: access, cachedStillIDs: ids) {
                return thumbnails.appending(path: "\(playing).png")
            }
            // Nothing downloaded yet: any real aerial beats a flat grey panel.
            if let any = ids.sorted().first {
                return thumbnails.appending(path: "\(any).png")
            }
            return nil
        }
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
    /// How wide the desktop is, in points — and the one thing about the
    /// *screen* the bake does have to know.
    ///
    /// The still is pinned to desktop coordinates now, so it is stretched
    /// across the whole display rather than across each surface. Its blur is
    /// therefore no longer measurable as a fraction of the picture: the same
    /// fraction is a different number of **points** on a 1512 pt laptop and a
    /// 3440 pt ultrawide, and points are what the eye and the contrast floors
    /// are stated in. See `DesktopBackdropRenderer.desktopBlurPoints`.
    ///
    /// Quantized to 128 pt so that a display which reports a slightly
    /// different width — or a second display close in size — reuses the cached
    /// bake instead of paying for another one.
    let screenPoints: Double

    static func quantized(screenPoints: Double) -> Double {
        max(512, (screenPoints / 128).rounded() * 128)
    }

    /// The two glass settings that change the *bake* rather than the veil over
    /// it, so switching either re-bakes once and then draws from cache like any
    /// other desktop change.
    let texture: GlassTexture
    let colour: GlassColour

    init(
        path: String,
        modified: Date?,
        isDark: Bool,
        screenPoints: Double = 1512,
        texture: GlassTexture = .balanced,
        colour: GlassColour = .balanced
    ) {
        self.path = path
        self.modified = modified
        self.isDark = isDark
        self.screenPoints = Self.quantized(screenPoints: screenPoints)
        self.texture = texture
        self.colour = colour
    }

    var url: URL { URL(fileURLWithPath: path) }
}

/// What a glass surface paints under its veil.
enum DesktopPainting: @unchecked Sendable {
    /// The pre-blurred desktop still, the pixel size of the wallpaper it was
    /// baked from, and the tint sampled from that same decode so a single pass
    /// produces every product.
    ///
    /// The full pixel size travels with the still because the still is a
    /// *thumbnail* — it keeps the wallpaper's aspect but not its size, and
    /// where macOS lays a desktop picture out on a screen depends on the size
    /// for the "Center" and "Tile" fill modes. See `DesktopBackdropGeometry`.
    case wallpaper(CGImage, tint: DesktopTintComponents, wallpaperPixels: CGSize)
    /// No readable still anywhere on the ladder.
    case flat(DesktopTintComponents)

    var tint: DesktopTintComponents {
        switch self {
        case let .wallpaper(_, tint, _): tint
        case let .flat(tint): tint
        }
    }
}

extension DesktopPainting: Equatable {
    static func == (lhs: DesktopPainting, rhs: DesktopPainting) -> Bool {
        switch (lhs, rhs) {
        case let (.wallpaper(lhsImage, lhsTint, lhsSize), .wallpaper(rhsImage, rhsTint, rhsSize)):
            lhsImage === rhsImage && lhsTint == rhsTint && lhsSize == rhsSize
        case let (.flat(lhsTint), .flat(rhsTint)):
            lhsTint == rhsTint
        default:
            false
        }
    }
}

// MARK: - Where the wallpaper actually is

/// The arithmetic that makes the glass *glass* rather than a picture of the
/// desktop painted onto a panel.
///
/// Until this round every glass surface drew the **whole** baked still
/// stretched to its own shape, so what the sidebar showed bore no relation to
/// the wallpaper actually behind the sidebar — a blurry photograph on a panel,
/// which is exactly why the surface never read as transparent however thin the
/// veil got. Round 2 skipped desktop pinning on the grounds that it would
/// "re-lay out on every window drag"; it does not, because the still is already
/// baked and cached and following a drag is a change of **sampling rectangle**,
/// not a change of pixels.
///
/// What is left is one piece of arithmetic: given where a surface is on a
/// screen, which part of the wallpaper image is under it? That depends on how
/// macOS laid the picture out, which `NSWorkspace.desktopImageOptions(for:)`
/// publishes as an `NSImageScaling` plus an `allowClipping` flag — the two
/// together spelling out aspect-fill, aspect-fit, stretch, centre or tile.
enum DesktopBackdropGeometry {
    /// The two option keys that decide the layout, read with the same defaults
    /// macOS uses when it does not publish them: fill the screen.
    static func layout(from options: [NSWorkspace.DesktopImageOptionKey: Any]?)
        -> (scaling: NSImageScaling, allowsClipping: Bool) {
        let raw = (options?[.imageScaling] as? NSNumber)?.uintValue
        let scaling = raw.flatMap { NSImageScaling(rawValue: $0) } ?? .scaleProportionallyUpOrDown
        let clipping = (options?[.allowClipping] as? NSNumber)?.boolValue ?? true
        return (scaling, clipping)
    }

    /// Where a wallpaper of `imagePixels` lands inside `screen`, in the
    /// screen's own (AppKit, y-up) coordinates.
    ///
    /// For the tiled desktop this is the *first* tile; `contentsRect` walks the
    /// grid from it.
    static func wallpaperFrame(
        imagePixels: CGSize,
        screen: CGRect,
        scaling: NSImageScaling,
        allowsClipping: Bool,
        backingScale: CGFloat
    ) -> CGRect {
        guard imagePixels.width > 0, imagePixels.height > 0,
              screen.width > 0, screen.height > 0
        else { return screen }
        let scale = max(backingScale, 1)
        let natural = CGSize(
            width: imagePixels.width / scale,
            height: imagePixels.height / scale
        )
        let widthRatio = screen.width / natural.width
        let heightRatio = screen.height / natural.height

        let size: CGSize = switch scaling {
        case .scaleAxesIndependently:
            screen.size
        case .scaleNone:
            natural
        case .scaleProportionallyDown:
            natural.scaled(by: min(1, min(widthRatio, heightRatio)))
        case .scaleProportionallyUpOrDown:
            // The pair that spells "Fill Screen" against "Fit to Screen".
            natural.scaled(by: allowsClipping
                ? max(widthRatio, heightRatio)
                : min(widthRatio, heightRatio))
        @unknown default:
            natural.scaled(by: max(widthRatio, heightRatio))
        }
        return CGRect(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The unit sub-rectangle of the wallpaper image lying behind `surface`.
    ///
    /// **Top-left origin**, because that is `CALayer.contentsRect`'s
    /// convention and a `CGImage`'s, while `surface` and `screen` arrive in
    /// AppKit's y-up coordinates — the flip happens here, once, rather than at
    /// each call site.
    ///
    /// A surface that runs off the wallpaper — a window dragged half off the
    /// screen, or sitting on the letterboxed margin of a "Fit to Screen"
    /// desktop — is **slid back inside at its full size** rather than being
    /// shrunk to the overlap. Shrinking would stretch the visible strip across
    /// the whole surface, which is the one artefact that would read as a bug;
    /// sliding shows the nearest real wallpaper at the correct scale, and the
    /// case only arises where there is no desktop under the glass to be honest
    /// about anyway.
    static func contentsRect(
        surface: CGRect,
        imagePixels: CGSize,
        screen: CGRect,
        scaling: NSImageScaling,
        allowsClipping: Bool,
        backingScale: CGFloat
    ) -> CGRect {
        var frame = wallpaperFrame(
            imagePixels: imagePixels,
            screen: screen,
            scaling: scaling,
            allowsClipping: allowsClipping,
            backingScale: backingScale
        )
        guard frame.width > 0, frame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        // "Tile": the picture repeats from the screen's own origin, so the
        // surface is mapped into whichever copy its centre falls in.
        if scaling == .scaleNone, allowsClipping {
            let column = ((surface.midX - screen.minX) / frame.width).rounded(.down)
            let row = ((surface.midY - screen.minY) / frame.height).rounded(.down)
            frame = CGRect(
                x: screen.minX + column * frame.width,
                y: screen.minY + row * frame.height,
                width: frame.width,
                height: frame.height
            )
        }

        let width = surface.width / frame.width
        let height = surface.height / frame.height
        // AppKit counts y up from the bottom; the image counts it down from the
        // top, so the surface's *top* edge is the sub-rect's origin.
        let left = (surface.minX - frame.minX) / frame.width
        let top = (frame.maxY - surface.maxY) / frame.height
        return CGRect(
            x: width >= 1 ? 0 : min(max(left, 0), 1 - width),
            y: height >= 1 ? 0 : min(max(top, 0), 1 - height),
            width: min(1, width),
            height: min(1, height)
        )
    }
}

private extension CGSize {
    func scaled(by factor: CGFloat) -> CGSize {
        CGSize(width: width * factor, height: height * factor)
    }
}

extension Array where Element == Double {
    /// Index of the first element not less than `value`, on an already-ascending
    /// array — i.e. where `value` has to go to keep it ascending.
    func partitionPoint(before value: Double) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
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
    /// as a size on screen, not by the pixel count. Raising it only buys
    /// fidelity of the structure `desktopBlurPoints` chose to keep.
    ///
    /// 448 → **896** for desktop pinning, and this time the magnification is
    /// the argument rather than the decode. A stretched still was drawn about
    /// 1:2 into a 210 pt sidebar; a pinned one shows the eighth of the
    /// wallpaper behind that sidebar, which at 448 px is 62 source pixels
    /// blown up to 420 backing pixels — 6.8×, where the round-7 correlation
    /// ladder already put 448 px at 7% non-wallpaper structure. 896 halves the
    /// magnification and takes the correlation past the 640 px rung (0.975).
    static let stillWidth = 896

    /// The blur, **in screen points** — the scattering length of the material,
    /// and the constant that decides whether the surface is a colour field or
    /// frosted glass.
    ///
    /// It was a fraction of the still (`blurFraction` 0.05), which was the
    /// right way to state it while every surface showed the whole wallpaper
    /// stretched to its own width: the sidebar was the frame, so 5% of the
    /// frame was 5% of the sidebar. Desktop pinning breaks that identity. A
    /// 210 pt sidebar on a 1512 pt display shows about **an eighth** of the
    /// wallpaper, so 5% of the wallpaper is 36% of the sidebar — one soft wash
    /// end to end, with no texture in it at all. Measured: the structured
    /// fixtures' surface detail fell from 0.0038–0.0058 stretched to
    /// **0.0018–0.0022** pinned, which is below even the pre-round-7 figure the
    /// last round doubled.
    ///
    /// A real frosted material has a fixed scattering length in physical units,
    /// not one that scales with the picture behind it, so that is how it is
    /// stated here. 28 pt is also, not coincidentally, the neighbourhood
    /// AppKit's own behind-window blur works in, so the pinned wallpaper reads
    /// as the same kind of material as the Live source it sits beside.
    ///
    /// The old requirement — "no locatable shape" — is *deliberately* relaxed,
    /// because it was the requirement that made the surface a picture on a
    /// panel. What replaces it is the requirement a glass surface actually
    /// has: no *legible* shape, meaning nothing crisp enough to read text or an
    /// icon through. At 28 pt over a 210 pt sidebar that is about seven soft
    /// masses across — the horizon, the shoreline, the cloud bank — and every
    /// contrast floor in this file still holds on the worst of them.
    static let desktopBlurPoints: Double = 28

    /// Radius in still pixels, for a desktop `screenPoints` wide.
    ///
    /// The still spans the whole display, so still pixels per screen point is
    /// `stillPixels / screenPoints` and the conversion is that ratio.
    ///
    /// `stillPixels` is the width the decode actually produced, not
    /// `stillWidth`: `CGImageSourceCreateThumbnailAtIndex` treats its maximum
    /// as a **maximum**, so a wallpaper smaller than `stillWidth` comes back at
    /// its own size, and using the declared width there would blur a small
    /// picture by the wrong number of points.
    static func blurRadius(
        screenPoints: Double,
        stillPixels: Int = stillWidth,
        blurPoints: Double = desktopBlurPoints
    ) -> Double {
        Double(stillPixels) * blurPoints / max(screenPoints, 1)
    }

    /// The legacy fraction-of-the-frame statement of the same blur, kept
    /// because the "does it still blur past anything legible" test is naturally
    /// stated in it.
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
    /// The share of a **surface** — not of the wallpaper — the blur covers, on
    /// the narrowest glass surface in the app (a 210 pt sidebar). This is the
    /// quantity "no legible shape" is really about, and it is now stated where
    /// it is true rather than where it happened to be equal to it.
    static var blurShareOfNarrowestSurface: Double { desktopBlurPoints / 210 }

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
    /// **1.2**, doubled from 0.6.
    ///
    /// 0.6 left the composite's luminance spread at about 0.095 on a real
    /// desktop — structure that is mathematically present and invisible in
    /// practice, which is why the canvas read as flat paint even in Crisp.
    /// Michael: "the glass totally erases all the details/texture of the
    /// wallpaper, even on crisp/clear mode."
    ///
    /// The bound above is unchanged and still governs: past ~1.8 the upscale to
    /// the surface starts ringing, and the measured dark worst patch drops to
    /// 4.32 — *below* the 4.5 floor. Two things are worth stating plainly about
    /// that number. It is not what the still-side cap measures, because the
    /// overshoot is created by the interpolation rather than by the bake; and
    /// the 120-test suite passes at 1.8 for exactly that reason. Passing tests
    /// are therefore **not** evidence of safety here, so this sits at two
    /// thirds of the documented edge rather than against it.
    static let localContrastRadiusFactor: Double = 1.4
    static let localContrastIntensity: Double = 1.2
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
    /// **Round 8 note.** `saturation`, `luminanceShift` and `tailGain` are no
    /// longer on the bake's path: all three are now *solved* against the
    /// rendered structure in a perceptual space rather than computed from
    /// Rec. 709 luma — see `solveToneMap(probe:isDark:)`, and
    /// `Oklab` for why measuring lightness as luma is what produced
    /// "on blue wallpaper it becomes white and on green wallpaper it's very
    /// green". They are retained because they *are* the round-7 pipeline, which
    /// the hue-invariance test freezes and measures against, and because
    /// `targetLuminance` and `tailHeadroom` still define the targets the solve
    /// aims at. Nothing new should be built on them.
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
        guard let blurred = blur(
            still,
            isDark: key.isDark,
            screenPoints: key.screenPoints,
            texture: key.texture,
            colour: key.colour
        ) else { return .flat(tint) }
        // The wallpaper's own pixel size, not the thumbnail's — the layout the
        // glass is pinned to depends on it for the centred and tiled desktops.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let pixels = CGSize(
            width: (properties?[kCGImagePropertyPixelWidth] as? Int).map(CGFloat.init)
                ?? CGFloat(blurred.width),
            height: (properties?[kCGImagePropertyPixelHeight] as? Int).map(CGFloat.init)
                ?? CGFloat(blurred.height)
        )
        return .wallpaper(blurred, tint: tint, wallpaperPixels: pixels)
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
    private static func blur(
        _ image: CGImage,
        isDark: Bool,
        screenPoints: Double,
        texture: GlassTexture,
        colour: GlassColour
    ) -> CGImage? {
        let radius = blurRadius(
            screenPoints: screenPoints,
            stillPixels: image.width,
            blurPoints: texture.blurPoints
        )
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
        gaussian.radius = Float(radius)
        guard let softened = gaussian.outputImage else { return nil }

        // The local-contrast add-back. Zero-mean by construction, so it changes
        // how the still's range is distributed and not how much of it there is —
        // and whatever it does to the extremes is measured on the very next
        // line and paid for by the gain.
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = softened
        unsharp.radius = Float(radius * localContrastRadiusFactor)
        unsharp.intensity = Float(localContrastIntensity)
        guard let structured = unsharp.outputImage,
              let probe = context.createCGImage(structured, from: extent),
              let sampled = DesktopTintSampler.pixels(image: probe, side: probeSide)
        else { return nil }

        // Lightness, range and chroma are solved together against the probe,
        // in a perceptual space, by applying the candidate map and measuring
        // what it did. All three still ride **one** filter pass — see
        // `BakeToneMap` for the map and `solveToneMap` for why it is solved by
        // measurement rather than by formula.
        let map = solveToneMap(probe: sampled, isDark: isDark, chromaScale: colour.chromaScale)
        let vectors = map.matrix
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = structured
        matrix.rVector = vectors.red
        matrix.gVector = vectors.green
        matrix.bVector = vectors.blue
        matrix.aVector = vectors.alpha
        matrix.biasVector = vectors.bias
        guard let output = matrix.outputImage else { return nil }
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

// MARK: - A tone map that does not care which hue carries the light

/// Perceived lightness and colourfulness, and the fix for "the saturation is
/// bizarre — on blue wallpaper it becomes white and on green wallpaper it's
/// very green".
///
/// Every lightness in the bake used to be **Rec. 709 luma**, which weights
/// green 9.9× blue (`0.7152` against `0.0722`). Measured on a fixture family
/// that is identical in HSV value and saturation and differs only in hue, that
/// one choice reads four equally-bright pictures as:
///
///     blue 0.2415   red 0.2047   green 0.3932   neutral 0.5000
///
/// — a **2.4× spread in "brightness" from pictures that are equally bright by
/// construction**. Everything downstream then diverges: `luminanceShift` is a
/// per-channel *offset*, so the blue picture is handed +0.48 of flat grey and
/// the green one +0.33; and the offset is exactly the operation that destroys
/// saturation, because adding a constant to `(0.125, 0.29, 0.5)` walks it
/// toward white while adding a smaller constant to `(0.125, 0.5, 0.125)`
/// barely touches it. The rendered light sidebar over that family measured
/// Oklab saturation **0.036 blue against 0.083 green — 2.3×** — which is
/// "blue becomes white, green stays very green", in numbers.
///
/// Oklab is the replacement because it is a *perceptual* lightness: the same
/// family reads 0.384 / 0.400 / 0.525 / 0.598, and — the property that makes
/// the whole thing work — its **chroma-to-lightness ratio is very nearly
/// hue-invariant** for that family (0.298 / 0.326 / 0.300 / 0.000), where
/// Rec. 709 luma has no such property at all.
enum Oklab {
    /// Oklab `L*`, `a`, `b` from gamma-encoded sRGB — the space the bake's
    /// probe is read in (see `DesktopBackdropRenderer.bakeColorSpace`).
    static func components(red: Double, green: Double, blue: Double)
        -> (lightness: Double, a: Double, b: Double) {
        let r = linear(red)
        let g = linear(green)
        let b = linear(blue)
        let long = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let medium = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let short = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            lightness: 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            a: 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
            b: 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
        )
    }

    static func lightness(red: Double, green: Double, blue: Double) -> Double {
        components(red: red, green: green, blue: blue).lightness
    }

    /// Colourfulness relative to lightness — the perceptual analogue of HSV
    /// saturation, and the quantity "it becomes white" and "it is very green"
    /// are the two halves of.
    static func saturation(red: Double, green: Double, blue: Double) -> Double {
        let parts = components(red: red, green: green, blue: blue)
        return (parts.a * parts.a + parts.b * parts.b).squareRoot()
            / max(parts.lightness, 0.001)
    }

    /// The gamma-encoded grey that has a given `L*`.
    ///
    /// For a neutral colour the three cube roots are equal and the `L*`
    /// coefficients sum to 1, so `L* = cbrt(linear)` exactly — which makes the
    /// inverse a cube and one sRGB encode. This is what lets the solve state
    /// its lightness correction as an ordinary offset in the space the filter
    /// works in, while the quantity it is correcting is perceptual.
    static func grey(lightness: Double) -> Double {
        encoded(max(0, lightness) * max(0, lightness) * max(0, lightness))
    }

    static func linear(_ channel: Double) -> Double {
        let value = min(1, max(0, channel))
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// `linear(_:)` as a table, because the solve evaluates it a quarter of a
    /// million times and `pow` is most of what that costs.
    ///
    /// 4096 entries with linear interpolation between them: the transfer curve
    /// has no feature narrower than a table step, so the worst interpolation
    /// error is under 2×10⁻⁸ — five orders of magnitude below anything the
    /// solve's tolerances care about, and the exact function is what every
    /// *assertion* still uses.
    static let linearTable: [Double] = (0...4096).map {
        linear(Double($0) / 4096)
    }

    static func tabulatedLinear(_ channel: Double) -> Double {
        let position = min(1, max(0, channel)) * 4096
        let index = Int(position)
        guard index < 4096 else { return linearTable[4096] }
        let fraction = position - Double(index)
        return linearTable[index] + (linearTable[index + 1] - linearTable[index]) * fraction
    }

    static func encoded(_ channel: Double) -> Double {
        let value = min(1, max(0, channel))
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}

/// The one linear map the bake applies to its structured still, stated in full.
///
/// `out = (luma + (in − luma) · saturation) · gain + offset`, per channel, in
/// the bake's working space. It replaces `CIColorControls` — not because that
/// filter was wrong, but because the solve below has to evaluate this map in
/// software thousands of times, and a map whose exact form is *declared here*
/// can be modelled exactly, where the filter's internal luma weights and
/// operation order could only be inferred. (Round 3 had to measure that order
/// on the real filter to get the offset right; this removes the need.)
///
/// One `CIColorMatrix` is the same single filter pass `CIColorControls` was, so
/// nothing about the bake's cost changes.
struct BakeToneMap: Equatable, Sendable {
    /// Chroma scale about each pixel's own luma.
    var saturation: Double
    /// Range gain — never above 1, so the map can only ever *remove* contrast.
    var gain: Double
    /// The flat offset that lands the still's mean on its target lightness.
    var offset: Double

    /// The luma the saturation term mixes about. Rec. 709 here is not the bug
    /// this round fixes: as a *chroma axis* it is standard and harmless, and
    /// the solve measures what it actually did to the result rather than
    /// assuming. The bug was using it as a **lightness**.
    static let lumaWeights = (red: 0.2126, green: 0.7152, blue: 0.0722)

    func apply(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let luma = Self.lumaWeights.red * red
            + Self.lumaWeights.green * green
            + Self.lumaWeights.blue * blue
        func channel(_ value: Double) -> Double {
            min(1, max(0, (luma + (value - luma) * saturation) * gain + offset))
        }
        return (channel(red), channel(green), channel(blue))
    }

    /// The same map as `CIColorMatrix`'s five vectors.
    var matrix: (
        red: CIVector, green: CIVector, blue: CIVector, alpha: CIVector, bias: CIVector
    ) {
        let mix = gain * (1 - saturation)
        let keep = gain * saturation
        let weights = Self.lumaWeights
        return (
            red: CIVector(
                x: CGFloat(keep + mix * weights.red),
                y: CGFloat(mix * weights.green),
                z: CGFloat(mix * weights.blue),
                w: 0
            ),
            green: CIVector(
                x: CGFloat(mix * weights.red),
                y: CGFloat(keep + mix * weights.green),
                z: CGFloat(mix * weights.blue),
                w: 0
            ),
            blue: CIVector(
                x: CGFloat(mix * weights.red),
                y: CGFloat(mix * weights.green),
                z: CGFloat(keep + mix * weights.blue),
                w: 0
            ),
            alpha: CIVector(x: 0, y: 0, z: 0, w: 1),
            bias: CIVector(x: CGFloat(offset), y: CGFloat(offset), z: CGFloat(offset), w: 0)
        )
    }
}

extension DesktopBackdropRenderer {
    /// The `L*` the baked still's mean is driven to, per appearance.
    ///
    /// Derived from `targetLuminance` rather than declared, so a *neutral*
    /// wallpaper lands on exactly the grey the veil arithmetic of rounds 2–4
    /// was priced against and every published composite figure still holds.
    /// What changes is only which pictures count as having reached it: a blue
    /// desktop now arrives at the same **perceived** lightness as a green one
    /// instead of being flooded with grey until its *luma* matched.
    static func targetLightness(isDark: Bool) -> Double {
        Oklab.lightness(
            red: targetLuminance(isDark: isDark),
            green: targetLuminance(isDark: isDark),
            blue: targetLuminance(isDark: isDark)
        )
    }

    /// `tailHeadroom` restated in `L*`, and derived from it for the same reason
    /// — the bound the previous round measured and shipped is preserved
    /// exactly for a neutral wallpaper and merely stops depending on hue.
    static func tailHeadroomLightness(isDark: Bool) -> Double {
        let target = targetLuminance(isDark: isDark)
        let headroom = tailHeadroom(isDark: isDark)
        let edge = isDark ? target + headroom : target - headroom
        return abs(Oklab.lightness(red: edge, green: edge, blue: edge)
            - targetLightness(isDark: isDark))
    }

    /// The share of the wallpaper's own colourfulness that reaches the still.
    ///
    /// This is `saturationCeiling` restated as a *perceptual* quantity, and the
    /// difference is the whole round. The old constant scaled the filter's
    /// saturation **input** and left the output wherever the picture's hue put
    /// it; this one is a target the solve drives the measured Oklab
    /// chroma-to-lightness of the finished still onto, so two wallpapers that
    /// are equally colourful arrive equally colourful whatever their hue.
    ///
    /// Both values are chosen so the *average* colourfulness over the hue
    /// family is what the shipped pipeline already delivered — surface Oklab
    /// saturation 0.128 in dark and 0.055 in light. **Nothing about how
    /// colourful the glass is has moved; only how evenly it is reached.** Dark
    /// keeps the larger share and still ends up the more damped surface, for
    /// the reason `darkSaturationCeiling` gives: at near-black the same
    /// absolute chroma is a far larger fraction of the surface, so a bigger
    /// number here is what *holds* dark where round 7 put it.
    /// Left at the shipped values deliberately.
    ///
    /// Halving these did make the surface calmer, and it also broke the
    /// hue-invariance property round 8 established: with the wallpaper's chroma
    /// cut, `GlassWarmth`'s fixed amber becomes proportionally larger and the
    /// invariance test's "amber removed" correction stops accounting for the
    /// difference (1.035× against a 1.03 tolerance). Rebalancing the two
    /// together is the right change and is worth doing on its own.
    ///
    /// It is also not urgent, because the over-saturation Michael saw was mostly
    /// the *wrong picture*: the shuffle heuristic was painting an autumn
    /// hillside, all yellows and greens, behind a desktop of grey basalt. With
    /// the desktop captured rather than guessed, the source is his own muted
    /// wallpaper and the share is being asked to colour something that is barely
    /// coloured to begin with.
    static let desktopChromaShare: Double = 0.162
    static let darkDesktopChromaShare: Double = 0.228

    static func desktopChromaShare(isDark: Bool) -> Double {
        isDark ? darkDesktopChromaShare : desktopChromaShare
    }

    /// A hard ceiling on the still's perceived colourfulness, so an extreme
    /// desktop cannot ask the solve for a saturation that only gamut clipping
    /// could deliver.
    /// The saturation a wallpaper actually *reads* as, rather than its average.
    ///
    /// A plain mean asks "how colourful is the typical pixel", and for most real
    /// desktops the honest answer is "not at all". A photograph of near-black
    /// basalt with green moss along its ridges is ~95% dark grey rock, so the
    /// mean lands near 0.08 — times a 0.162 share, an effective chroma of 0.013
    /// — and the still comes out grey with the green averaged out of existence.
    /// The green is the only colour anyone would name if asked about that
    /// picture.
    ///
    /// This weights every pixel by its own saturation, so the measure answers
    /// "where is this picture's colour, and how strong is it there" (`Σs²/Σs`).
    /// Grey pixels contribute to neither numerator nor denominator, so they
    /// dilute nothing.
    ///
    /// Two properties make it safe rather than merely louder:
    ///
    /// * A genuinely grey desktop still measures **zero** and stays grey —
    ///   there is no colour to find, as opposed to a little colour being
    ///   drowned.
    /// * A *uniformly* coloured desktop measures exactly its own saturation, so
    ///   nothing that already worked is pushed further.
    ///
    /// It can therefore only raise the reading for a picture whose colour is
    /// concentrated rather than spread — which is precisely the case that was
    /// broken. Michael: "it doesn't need to be exactly 1:1 translucent, it could
    /// take peaks and move them."
    ///
    /// Pure, so the three properties above are tested rather than argued.
    /// How strongly concentrated colour outweighs spread colour.
    ///
    /// 0 is a plain mean. 1 squares the weight, which found the moss but
    /// amplified a residual hue dependence in the pixel distribution enough to
    /// break the invariance round 8 established — measured, the surface's
    /// colourfulness varied 1.156× across the hue family against a 1.12
    /// tolerance. That property is worth more than the extra lift, so the
    /// emphasis is softened rather than the tolerance widened.
    ///
    /// At 0.5 the moss fixture still reads roughly twice its mean, which is the
    /// difference between "grey" and "green".
    static let concentrationExponent: Double = 0.5

    static func characteristicSaturation(
        _ pixels: [(red: Double, green: Double, blue: Double)]
    ) -> Double {
        var weighted = 0.0
        var weight = 0.0
        for pixel in pixels {
            let peak = max(pixel.red, max(pixel.green, pixel.blue))
            guard peak > 0.004 else { continue }
            let base = min(pixel.red, min(pixel.green, pixel.blue))
            let saturation = (peak - base) / peak
            let emphasis = pow(saturation, concentrationExponent)
            weighted += saturation * emphasis
            weight += emphasis
        }
        guard weight > 0.0001 else { return 0 }
        return weighted / weight
    }

    static let okSaturationCeiling: Double = 0.24
    /// And a ceiling on the filter input itself, for the same reason from the
    /// other side.
    static let toneSaturationCeiling: Double = 3.0

    /// How much of the still the worst patch is.
    ///
    /// **0.25%, not the 2% every contrast floor is stated in** — and the reason
    /// is desktop pinning. A glass surface no longer shows the whole still: it
    /// shows the region of wallpaper actually behind it, and the smallest glass
    /// surface in the app (a 210 pt sidebar on a 1512 pt display) is about an
    /// eighth of the screen. Its own brightest 2% is therefore roughly the
    /// **brightest 0.25% of the wallpaper**, and that — not the whole picture's
    /// 2% — is the patch the floors have to survive. Bounding the looser
    /// quantity would leave every floor in this file stated about a surface
    /// that no longer exists.
    static let tailFraction: Double = 0.0025

    /// How many times the solve refines the map.
    ///
    /// Each knob is close to independent of the other two — the offset moves
    /// lightness, the gain moves the tail, the saturation moves chroma — and
    /// the offset is re-settled to convergence inside every pass, so the outer
    /// loop only has to let the gain walk down to its constraint. Four passes
    /// land the still's mean `L*` on target to four decimals on every fixture
    /// measured; a fifth moves nothing.
    static let toneSolveIterations = 4

    /// Solve the tone map **against the structure the surface will actually
    /// show**, in the space the guarantee is stated in.
    ///
    /// Round 7 moved the bake from solving blind to measuring its own structure
    /// once and solving from that. This goes one step further because the
    /// quantities now being targeted — perceived lightness, perceived
    /// colourfulness — are not linear in the knobs that move them, so a single
    /// closed-form step lands near the target rather than on it. Applying the
    /// candidate map to the probe in software and re-measuring is a few hundred
    /// microseconds and removes the last place the bake was estimating.
    ///
    /// Three targets, three knobs:
    ///
    /// - **offset** → the mean `L*` lands on `targetLightness`.
    /// - **gain** → the worst patch's `L*` sits inside `tailHeadroomLightness`.
    /// - **saturation** → the mean Oklab saturation lands on the wallpaper's
    ///   own, scaled by `desktopChromaShare`.
    ///
    /// The saturation target being *proportional to the wallpaper's* is what
    /// keeps a grey desktop grey: a neutral picture has zero colourfulness, so
    /// its target is zero and no amount of solving can invent a hue.
    static func solveToneMap(
        probe rgba: [UInt8],
        isDark: Bool,
        chromaScale: Double = 1
    ) -> BakeToneMap {
        var pixels: [(red: Double, green: Double, blue: Double)] = []
        pixels.reserveCapacity(rgba.count / 4)
        var index = 0
        while index + 3 < rgba.count {
            if Double(rgba[index + 3]) / 255 > 0.05 {
                pixels.append((
                    Double(rgba[index]) / 255,
                    Double(rgba[index + 1]) / 255,
                    Double(rgba[index + 2]) / 255
                ))
            }
            index += 4
        }
        var map = BakeToneMap(saturation: 1, gain: 1, offset: 0)
        guard !pixels.isEmpty else { return map }

        let target = targetLightness(isDark: isDark)
        let headroom = tailHeadroomLightness(isDark: isDark)
        let band = max(1, Int(Double(pixels.count) * tailFraction))
        // The wallpaper's own colourfulness, measured once and **exactly**
        // hue-neutrally: HSV saturation is invariant under a hue rotation by
        // construction, where even Oklab's chroma-to-lightness carries a
        // residual 9% hue dependence (0.298 blue / 0.300 green / 0.326 red on
        // the hue family). The *target* is perceptual and the *source* measure
        // is hue-blind, which is the pairing the invariance needs.
        let chromaTarget = min(
            okSaturationCeiling,
            characteristicSaturation(pixels)
                * desktopChromaShare(isDark: isDark)
                * max(0, chromaScale)
        )

        // The map is `(luma + delta·saturation)·gain + offset` per channel, and
        // `luma` and `delta` do not move between iterations — so they are
        // computed once and each pass is two multiplies per channel.
        let weights = BakeToneMap.lumaWeights
        let luma = pixels.map {
            weights.red * $0.red + weights.green * $0.green + weights.blue * $0.blue
        }
        let deltas = pixels.enumerated().map {
            ($0.element.red - luma[$0.offset],
             $0.element.green - luma[$0.offset],
             $0.element.blue - luma[$0.offset])
        }

        /// Mean and worst-patch `L*`, and mean Oklab saturation, of the probe
        /// under a candidate map.
        ///
        /// The worst patch is taken by keeping the running extreme `band`
        /// values rather than sorting all 9216 — the band is about twenty
        /// entries, so an insertion into a sorted twenty is cheaper than a sort
        /// of nine thousand, and this runs a dozen times per bake.
        func measure(_ candidate: BakeToneMap)
            -> (mean: Double, tail: Double, saturation: Double) {
            var mean = 0.0
            var saturation = 0.0
            var extremes: [Double] = []
            extremes.reserveCapacity(band + 1)
            for position in pixels.indices {
                let base = luma[position]
                let delta = deltas[position]
                func channel(_ value: Double) -> Double {
                    min(1, max(0, (base + value * candidate.saturation) * candidate.gain
                        + candidate.offset))
                }
                let red = Oklab.tabulatedLinear(channel(delta.0))
                let green = Oklab.tabulatedLinear(channel(delta.1))
                let blue = Oklab.tabulatedLinear(channel(delta.2))
                let long = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
                let medium = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
                let short = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
                let lightness = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short
                let a = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short
                let b = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
                mean += lightness
                saturation += (a * a + b * b).squareRoot() / max(lightness, 0.001)

                // `extremes` is kept ascending; dark wants the top of it, light
                // the bottom, so each drops the opposite end.
                if extremes.count < band {
                    extremes.insert(lightness, at: extremes.partitionPoint(before: lightness))
                } else if isDark ? lightness > extremes[0] : lightness < extremes[band - 1] {
                    extremes.insert(lightness, at: extremes.partitionPoint(before: lightness))
                    extremes.remove(at: isDark ? 0 : band)
                }
            }
            let tail = extremes.reduce(0, +) / Double(max(extremes.count, 1))
            return (mean / Double(pixels.count), tail, saturation / Double(pixels.count))
        }

        // The offset is re-solved **to convergence** for whatever gain and
        // saturation are current, rather than nudged once per outer pass. That
        // separation is what makes the whole thing converge: mean `L*` is
        // strictly increasing in the offset, and `Oklab.grey` is its exact
        // inverse for a neutral pixel, so the fixed point is reached in two or
        // three steps from any starting point.
        func settleOffset(_ candidate: inout BakeToneMap)
            -> (mean: Double, tail: Double, saturation: Double) {
            var reading = measure(candidate)
            for _ in 0..<3 {
                let correction = Oklab.grey(lightness: target)
                    - Oklab.grey(lightness: reading.mean)
                if abs(correction) < 0.0005 { break }
                candidate.offset = min(1, max(-1, candidate.offset + correction))
                reading = measure(candidate)
            }
            return reading
        }

        for _ in 0..<toneSolveIterations {
            let reading = settleOffset(&map)
            // The gain only ever *shrinks*, from 1 toward whatever the tail
            // constraint needs. Letting it climb back would make the solve
            // chase its own last correction — the tail is small precisely
            // because the gain is small — and oscillate instead of settle.
            let excursion = abs(reading.tail - target)
            if excursion > headroom {
                map.gain = max(0.02, map.gain * headroom / excursion)
            }
            if chromaTarget <= 0 {
                map.saturation = 0
            } else if reading.saturation > 0.0005 {
                map.saturation = min(
                    toneSaturationCeiling,
                    max(0, map.saturation * chromaTarget / reading.saturation)
                )
            }
        }
        _ = settleOffset(&map)
        return map
    }
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
            // A window dragged onto another display changes neither the
            // wallpaper file nor the Space, but it does change how wide the
            // desktop the still is stretched across is — which the bake's blur
            // is now stated against. Deliberately **not** funnelled straight
            // into `noteDesktopSignal`: this notification also fires the first
            // time any window acquires a screen, so an unconditional hint would
            // turn opening a window into a desktop re-resolve and reset the
            // watch's baseline in the process.
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.noteScreenWidthChange() } },
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
        let screen = Self.currentScreen()
        let desktopImageURL = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        // The blur is stated in screen points and the still now spans the whole
        // desktop, so how wide that desktop is belongs to the bake — and so to
        // the cache key. See `DesktopBackdropKey.screenPoints`.
        let screenPoints = Double(screen?.frame.width ?? 1512)
        // Resolved here, on the main actor: `NSScreen` is not `Sendable`, and
        // the capture below runs off it.
        let displayID = screen?.displayID
        let texture = NativePreviewSettings.shared.glassTexture
        let colour = NativePreviewSettings.shared.glassColour
        // Read on the main actor; the resolve below runs off it.
        let pinnedWallpaper = NativePreviewSettings.shared.glassWallpaper
        work?.cancel()
        work = Task { [weak self] in
            // Observe the desktop before deducing it. The capture writes a file
            // the ladder below prefers, so a shuffled or dynamic desktop bakes
            // the picture actually on screen rather than a guessed stand-in.
            // Desktop capture is OFF.
            //
            // It shipped twice and grabbed the wrong content both times: first
            // other applications' windows (`excludingWindows` can only exclude
            // what it was handed), then — after switching to naming the Dock's
            // `Wallpaper-<UUID>` window directly — a frame containing Kaisola's
            // own Settings popover on white. The identification is evidently
            // still wrong, and the failure mode of getting it wrong is putting
            // other people's screens inside this app's chrome.
            //
            // That is not a bug to iterate on in place. `DesktopCaptureSource`
            // is left intact and unreferenced so the work is not lost, and the
            // resolution ladder below runs exactly as it did before capture
            // existed. Re-enabling it needs a test that asserts what the
            // captured frame actually contains, which is the check that was
            // missing both times.
            _ = displayID
            let key = await Task.detached(priority: .utility) {
                Self.key(
                    desktopImageURL: desktopImageURL,
                    pinnedWallpaperPath: pinnedWallpaper,
                    isDark: isDark,
                    screenPoints: screenPoints,
                    texture: texture,
                    colour: colour
                )
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

    /// Waits for whatever resolve is in flight, and exists for one reason: a
    /// resolve deliberately clears the watch's baseline signature when it lands
    /// ("whatever this resolve concluded is the new baseline"), so a test that
    /// drives `probeDesktop` has to know the previous resolve has finished
    /// rather than race it. Without this the watch test passes or fails
    /// depending on how long a bake happens to take.
    func settleResolves() async { await work?.value }

    /// Hint only if the display the glass is on is a **different width** from
    /// the one the current backdrop was baked for. Everything else about the
    /// wallpaper is unchanged by a window moving between screens, and the
    /// quantization in `DesktopBackdropKey` means two similar displays do not
    /// count as different either.
    private func noteScreenWidthChange() {
        guard let baked = lastKey?.screenPoints,
              let width = Self.currentScreen()?.frame.width,
              baked != DesktopBackdropKey.quantized(screenPoints: Double(width))
        else { return }
        noteDesktopSignal()
    }

    private nonisolated static func key(
        desktopImageURL: URL?,
        pinnedWallpaperPath: String?,
        isDark: Bool,
        screenPoints: Double,
        texture: GlassTexture,
        colour: GlassColour
    ) -> DesktopBackdropKey? {
        guard let url = DesktopWallpaperLocator.resolveOnDisk(
            desktopImageURL: desktopImageURL,
            pinnedWallpaperPath: pinnedWallpaperPath
        ).url else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return DesktopBackdropKey(
            path: url.path,
            modified: modified,
            isDark: isDark,
            screenPoints: screenPoints,
            texture: texture,
            colour: colour
        )
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
            // Both of these change the bake rather than the veil, so the still
            // has to be re-rendered — once, through the same cached, coalesced,
            // off-thread path any desktop change takes.
            .onChange(of: settings.glassTexture) { desktop.refresh(isDark: colorScheme == .dark) }
            .onChange(of: settings.glassColour) { desktop.refresh(isDark: colorScheme == .dark) }
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

    /// The still is **pinned to desktop coordinates** — each surface shows the
    /// region of wallpaper actually behind it, at the wallpaper's own scale and
    /// at the window's own offset on its own screen.
    ///
    /// It used to be stretched: one still, spread across every surface
    /// whatever its shape and wherever the window was. The argument was that
    /// filling each surface to its own aspect would show each a different crop
    /// and read as a seam — true, and beside the point, because the fix for
    /// that is not to show every surface the *same wrong* crop but to show each
    /// the *right* one. What a stretched still cannot do at any blur radius or
    /// any veil opacity is read as transparent, because nothing in it moves
    /// when the window moves, and nothing in it corresponds to what is behind
    /// the window. Michael: "we don't get the translucence at all. I meant the
    /// glass wallpaper should be translucent to the wallpaper itself."
    @ViewBuilder
    private var paintedDesktop: some View {
        switch desktop.painting {
        case let .wallpaper(image, _, pixels):
            DesktopWallpaperPatch(still: image, wallpaperPixels: pixels)
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

/// A glass surface's window onto the wallpaper behind it.
///
/// One `CALayer` holding the cached still, with `contentsRect` set to the part
/// of the wallpaper this view covers. Following a drag is therefore **one
/// property assignment on an existing layer** — no decode, no blur, no
/// re-render of the still, no new texture upload; the same texture is sampled
/// from a different rectangle. That is what makes desktop pinning affordable
/// at drag cadence and is why round 2's "it would re-lay out on every drag"
/// worry does not apply to a *baked and cached* still.
struct DesktopWallpaperPatch: NSViewRepresentable {
    let still: CGImage
    let wallpaperPixels: CGSize

    func makeNSView(context: Context) -> DesktopWallpaperPatchView {
        let view = DesktopWallpaperPatchView()
        view.apply(still: still, wallpaperPixels: wallpaperPixels)
        return view
    }

    func updateNSView(_ view: DesktopWallpaperPatchView, context: Context) {
        view.apply(still: still, wallpaperPixels: wallpaperPixels)
    }
}

/// A value resolved at most once per key until something drops it.
///
/// Extracted from `DesktopLayoutCache` with no AppKit in it so the rule that
/// actually matters — *one* resolve per key, and a drop really does force the
/// next one — is a test rather than a claim about a call an assertion cannot
/// reach without a display attached.
struct ResolveOnceCache<Key: Hashable, Value> {
    private var entries: [Key: Value] = [:]

    /// Number of times `resolve` has actually run. Test-facing; the production
    /// path never reads it.
    private(set) var resolveCount = 0

    mutating func value(for key: Key, resolve: (Key) -> Value) -> Value {
        if let cached = entries[key] { return cached }
        resolveCount += 1
        let resolved = resolve(key)
        entries[key] = resolved
        return resolved
    }

    mutating func invalidate() { entries.removeAll(keepingCapacity: true) }
}

/// How macOS lays the desktop picture out on each display, cached.
///
/// `NSWorkspace.desktopImageOptions(for:)` reads like a property and is not
/// one: it is a hop into the desktop-picture store, measured on this machine at
/// **4.4 ms a call**. The patch needs the layout every time the window moves,
/// once per glass surface — and a 120 Hz frame is 8.3 ms in total, so asking
/// for it there spent more than a whole frame's budget per surface per frame.
/// That is the judder Michael saw dragging the window; the arithmetic around it
/// was already sub-microsecond.
///
/// A layout changes only when the desktop picture or the display arrangement
/// changes, and both announce themselves. So this drops on those signals and is
/// a dictionary lookup the rest of the time — including throughout a drag,
/// which posts none of them.
@MainActor
enum DesktopLayoutCache {
    typealias Layout = (scaling: NSImageScaling, allowsClipping: Bool)

    private static var cache = ResolveOnceCache<CGDirectDisplayID, Layout>()
    private static var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    static func layout(for screen: NSScreen) -> Layout {
        install()
        // A screen with no display number is not a display we can key on, so it
        // pays the read. It is also not a case that arises on a real desktop.
        guard let id = displayID(of: screen) else {
            return DesktopBackdropGeometry.layout(
                from: NSWorkspace.shared.desktopImageOptions(for: screen)
            )
        }
        return cache.value(for: id) { _ in
            DesktopBackdropGeometry.layout(
                from: NSWorkspace.shared.desktopImageOptions(for: screen)
            )
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Registered once, never torn down: the cache outlives every window and
    /// costs five observers for the life of the process.
    private static func install() {
        guard observers.isEmpty else { return }
        func watch(_ name: Notification.Name, on center: NotificationCenter) {
            observers.append((center, center.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { cache.invalidate() } }))
        }
        // The subset of `DesktopBackdropProvider`'s signals that can change a
        // *layout* rather than the picture's pixels: the displays were
        // rearranged, another Space with its own desktop came forward, the
        // machine woke, or the user was in System Settings while we were away.
        watch(NSApplication.didChangeScreenParametersNotification, on: .default)
        watch(NSApplication.didBecomeActiveNotification, on: .default)
        watch(NSWorkspace.activeSpaceDidChangeNotification, on: NSWorkspace.shared.notificationCenter)
        watch(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter)
        watch(DesktopBackdropProvider.desktopChangedNotification, on: DistributedNotificationCenter.default())
    }
}

/// The `NSView` half, and the app's only hook into where its windows are.
///
/// Everything it listens to is a *frame* signal — the window moved, the window
/// resized, the window landed on another display, the displays themselves were
/// reconfigured. The wallpaper's own change signals stay where they were, on
/// `DesktopBackdropProvider`; nothing here re-reads the desktop or re-bakes
/// anything.
final class DesktopWallpaperPatchView: NSView {
    /// Registrations, held so both the main actor and `deinit` can drop them.
    /// `NotificationCenter` is itself thread-safe, so the only thing the box
    /// buys is a home for the tokens that is not actor-isolated — and it
    /// remembers *which* centre each token came from, because one of them is
    /// `NSWorkspace`'s rather than the default one.
    private final class Registrations: @unchecked Sendable {
        var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

        func drop() {
            for entry in tokens { entry.center.removeObserver(entry.token) }
            tokens = []
        }
    }

    private let patch = CALayer()
    private var wallpaperPixels: CGSize = .zero
    private let registrations = Registrations()
    /// What the layer is already showing, so a repeated signal is free.
    private var appliedContentsRect: CGRect?
    private var appliedFrame: CGRect?
    /// Live only while the window is moving; see `setNeedsBackdropRefresh`.
    private var displayLink: CADisplayLink?
    private var backdropNeedsRefresh = false
    private var idleFrames = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        patch.contentsGravity = .resize
        // The still is magnified into the surface — a 210 pt sidebar is about
        // an eighth of a display — so the filter matters. Trilinear keeps the
        // upscale free of the faceting bilinear leaves on a smooth gradient.
        patch.magnificationFilter = .trilinear
        patch.minificationFilter = .trilinear
        patch.needsDisplayOnBoundsChange = false
        layer?.addSublayer(patch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { registrations.drop() }

    func apply(still: CGImage, wallpaperPixels: CGSize) {
        self.wallpaperPixels = wallpaperPixels
        if !(patch.contents as AnyObject? === still) {
            patch.contents = still
        }
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe()
        // A view with no window has nothing to pace against, and a display
        // link outliving its window is a retained timer firing at 120 Hz.
        if window == nil { stopDisplayLink() }
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }

    /// Every signal that can move the wallpaper *under* this view without
    /// changing the wallpaper itself.
    private func observe() {
        registrations.drop()
        guard let window else { return }
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, on center: NotificationCenter, object: Any?) {
            registrations.tokens.append((center, center.addObserver(
                forName: name, object: object, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }))
        }
        // `didMove` fires continuously through a live drag, which is exactly
        // the cadence the backdrop has to follow to read as glass.
        //
        // Delivered on `queue: nil` — synchronously, on the thread that posted
        // — rather than hopping through `OperationQueue.main`. These four are
        // AppKit window notifications and are always posted on the main thread,
        // so the isolation assumption below holds; what the hop cost was a
        // frame of latency, which during a drag is the backdrop trailing the
        // window. Trailing is the one thing a pane of glass never does.
        for name: Notification.Name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ] {
            registrations.tokens.append((center, center.addObserver(
                forName: name, object: window, queue: nil
            ) { [weak self] _ in MainActor.assumeIsolated { self?.setNeedsBackdropRefresh() } }))
        }
        watch(NSApplication.didChangeScreenParametersNotification, on: center, object: nil)
        watch(
            NSWorkspace.activeSpaceDidChangeNotification,
            on: NSWorkspace.shared.notificationCenter,
            object: nil
        )
    }

    /// Ask for one backdrop update on the next frame the display actually draws.
    ///
    /// A window drag posts `didMove` on the event stream, not the display's —
    /// so the events arrive in bursts that do not line up with frames, and
    /// several can land inside one refresh interval. Answering each of them
    /// individually does work the screen never shows and paces the backdrop by
    /// the mouse rather than by the display.
    ///
    /// A display link is the opposite: exactly one update per frame while the
    /// window is moving, at whatever the screen's real rate is (60 Hz, 120 Hz
    /// on ProMotion), and — because it stops itself once the moves stop —
    /// nothing at all while the window sits still. Michael: "60 fps for the
    /// background wallpaper, but only when moving the app."
    private func setNeedsBackdropRefresh() {
        backdropNeedsRefresh = true
        startDisplayLinkIfNeeded()
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        displayLink = link
        idleFrames = 0
    }

    /// Frames of no movement before the link stops. A drag pauses mid-gesture
    /// constantly; tearing the link down on the first still frame would spend
    /// more on starting and stopping than on drawing.
    private static let idleFramesBeforeStopping = 12

    @objc private func displayLinkFired() {
        guard backdropNeedsRefresh else {
            idleFrames += 1
            if idleFrames >= Self.idleFramesBeforeStopping { stopDisplayLink() }
            return
        }
        backdropNeedsRefresh = false
        idleFrames = 0
        refresh()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        idleFrames = 0
    }

    private func refresh() {
        guard patch.contents != nil, let window else { return }
        // `window.screen` is the display AppKit considers the window to be on
        // — the one it overlaps most — which is the display whose desktop
        // picture and whose fill mode apply.
        guard let screen = window.screen ?? NSScreen.main else { return }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        let layout = DesktopLayoutCache.layout(for: screen)
        let rect = DesktopBackdropGeometry.contentsRect(
            surface: onScreen,
            imagePixels: wallpaperPixels,
            screen: screen.frame,
            scaling: layout.scaling,
            allowsClipping: layout.allowsClipping,
            backingScale: screen.backingScaleFactor
        )
        // A drag posts `didMove` once per frame per surface, and a window
        // nudged inside one point produces the same rectangle twice. Committing
        // an identical transaction is not free at that cadence.
        guard rect != appliedContentsRect || bounds != appliedFrame else { return }
        appliedContentsRect = rect
        appliedFrame = bounds
        // No implicit animation: a drag would otherwise ease the backdrop
        // toward each new position a quarter-second behind the window, which
        // reads as the glass sliding rather than the desktop staying put.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        patch.frame = bounds
        patch.contentsRect = rect
        CATransaction.commit()
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
    @ObservedObject private var settings = NativePreviewSettings.shared
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
                    GlassBackdropWash
                        .sidebar(isDark: colorScheme == .dark, clarity: settings.glassClarity.resolved(
                            increasedContrast: accessibilityContrast == .increased,
                            reduceTransparency: reduceTransparency
                        ))
                        .veil
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
    @ObservedObject private var settings = NativePreviewSettings.shared
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
                    GlassBackdropWash
                        .workspace(isDark: colorScheme == .dark, clarity: settings.glassClarity.resolved(
                            increasedContrast: accessibilityContrast == .increased,
                            reduceTransparency: reduceTransparency
                        ))
                        .veil
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
