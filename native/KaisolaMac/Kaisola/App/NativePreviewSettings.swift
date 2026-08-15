import AppKit
import Combine
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

/// How much always-visible detail each tool-call card uses. Every level keeps
/// the same status, affected-file, failure, and disclosure evidence; density
/// changes only the card's spacing and how much summary text is visible before
/// the user expands bounded artifacts.
enum ToolCallDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case balanced
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .balanced: "Balanced"
        case .detailed: "Detailed"
        }
    }

    var detail: String {
        switch self {
        case .compact: "Tight cards with essential evidence"
        case .balanced: "Status, files, and artifact summary"
        case .detailed: "Roomier cards with wrapped file paths"
        }
    }
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
    /// The desktop's *hue* laid into the solid surface — the same recipe the
    /// canvas has had, now available to the two rails so a tinted workspace is
    /// tinted all the way across instead of only in the middle.
    case tinted

    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Glass"
        case .solid: "Solid"
        case .tinted: "Tinted"
        }
    }
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

/// The one theme control Settings offers: **Glass or Solid.**
///
/// Settings used to carry six separate glass rows — sidebar treatment, source,
/// pinned wallpaper, clarity, blur and colour — plus a seventh for the canvas.
/// Twenty-seven combinations of the middle three alone, every one measured and
/// defended in this file, and none of them a decision anybody should have to
/// make to open a terminal. Michael: "I'd make settings only have two options
/// for theme (glass/solid) makes things easier."
///
/// So the knobs stop being knobs. They keep their types, because the render path
/// and the whole measured corpus are written against them, but the values are a
/// *preset* this enum names rather than a grid the user has to navigate.
enum KaisolaTheme: String, CaseIterable, Identifiable, Sendable {
    case glass
    case solid
    /// Opaque like Solid, but carrying the desktop's colour across the canvas
    /// and both rails. Michael: "a tinted theme to the settings that makes the
    /// background and lhs and rhs tinted in a nice but slick manner."
    ///
    /// The canvas half already existed and was already measured — see
    /// `WorkspaceBackdropMode.tinted` — but it was reachable only from a picker
    /// this round deleted, and it tinted the middle of the window while the two
    /// rails stayed neutral grey, which is what made it read as a half-applied
    /// setting rather than a theme. Both surfaces move together now.
    case tinted

    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: "Glass"
        case .solid: "Solid"
        case .tinted: "Tinted"
        }
    }

    var sidebarAppearance: SidebarAppearance {
        switch self {
        case .glass: .glass
        case .solid: .solid
        case .tinted: .tinted
        }
    }

    var workspaceBackdrop: WorkspaceBackdropMode {
        switch self {
        case .glass: .glass
        case .solid: .system
        case .tinted: .tinted
        }
    }
}

/// The one glass recipe: **soft, muted, and live** — and deliberately NOT
/// frosted.
///
/// Michael asked for two things that pull against each other: "glass settings by
/// default should be darker and on soft, frosted, and muted, modes" and "ACTUALLY
/// reflect the live wallpaper/desktop/behind the screen", then, on seeing the
/// frosted build, "glass mode is not really glassy at all".
///
/// Frosted is what caused that. It multiplies every veil coverage by 1.16, so it
/// makes the surface *less* see-through — the opposite of showing the desktop.
/// Asked to choose, Michael picked transparency, so clarity ships at `balanced`
/// and the darkening is bought where it costs no transmission: the still's own
/// luminance target (`DesktopBackdropRenderer.targetLuminance`) and the chrome
/// panel that used to lighten dark mode.
///
/// `behindWindow` is the live half. The shipped default was a *painted* backdrop:
/// a blurred copy of a wallpaper file found by asking `NSWorkspace` which picture
/// the desktop shows — a question macOS refuses to answer for a rotating or
/// dynamic desktop, where it hands back a stand-in and the ladder falls through
/// to a thumbnail magnified many times over. Nothing in that path is live.
/// Behind-window vibrancy samples whatever is genuinely behind the window at
/// composite time, with no permission prompt, no bake and no guessing. What it
/// gives up is the painted path's one guarantee: other applications' windows do
/// show through when they are behind Kaisola. That is the trade, and it is the
/// one the request describes ("behind the screen").
///
/// `texture` and `colour` only feed the bake, so on the live path they are inert;
/// they are still set to the asked-for values so the painted fallback (Reduce
/// Transparency) looks like the rest of this.
enum GlassPreset {
    static let source: GlassBackdropSource = .behindWindow
    static let texture: GlassTexture = .soft
    static let colour: GlassColour = .muted
    static let clarity: GlassClarity = .balanced
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
        case .crisp: 5
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
    /// So Clear buys what its name promises, and measurement shows the price is
    /// far smaller than it looks. Transmission goes 0.65 → **0.92**, and across
    /// that whole range the worst-patch contrast barely moves: light secondary
    /// text runs 3.43:1 at the old veil and 3.24:1 with almost none, because
    /// the tone map's tail cap — not the veil — is what bounds how dark the
    /// surface can get. Primary text holds its full 7:1 floor throughout, and
    /// dark appearance holds everything.
    ///
    /// One number gives, by six percent, and only in light: that is the entire
    /// trade. Frosted and Balanced are unchanged, Balanced is still the default,
    /// and Michael asked for this twice — "full crisp and full clarity to be
    /// extremely clear and transparent of the background"
    ///
    /// Those figures are the *system* semantic's. Since `KaisolaInk`, the same
    /// adversarial worst patch reads 4.65:1 at Balanced and 3.99:1 here, so Clear
    /// is still the one setting that does not meet the 4.5 floor — it just gives
    /// up 0.66 of a ratio the app now has rather than 0.19 of one it never did.
    ///
    /// `resolved(for:)` is what keeps that from reaching anyone who has told
    /// the system they need contrast.
    var veilScale: Double {
        switch self {
        case .frosted: 1.16
        case .balanced: 1.0
        case .clear: 0.20
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

// Terminal color choices are a registry now — see `TerminalThemeRegistry`.
// The old `TerminalPaletteMode` raw values live on as the shipped theme ids
// ("native", "kaisola"), which is what keeps every persisted choice meaning
// the same thing without a migration.

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
              !value.contains("\\"),
              let components = URLComponents(string: value),
              components.url != nil,
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              // `URLComponents` percent-decodes `host`, so `%09` slips a
              // separator past the raw-text checks above and leaves this base URL
              // meaning one host here and another to a WHATWG parser. Same
              // host-confusion class as the backslash introducer.
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !host.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
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

struct ExternalEditorApplication: Equatable {
    let url: URL
    let displayName: String
    let bundleIdentifier: String?

    init?(url: URL, fileManager: FileManager = .default) {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard standardized.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let bundle = Bundle(url: standardized) else {
            return nil
        }
        let named = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? standardized.deletingPathExtension().lastPathComponent
        let trimmedName = named.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        self.url = standardized
        displayName = trimmedName
        bundleIdentifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ExternalEditorResolution: Equatable {
    case systemDefault
    case application(ExternalEditorApplication)
    case unresolved

    var isAvailable: Bool {
        if case .unresolved = self { return false }
        return true
    }

    var displayName: String {
        switch self {
        case .systemDefault: "System Default"
        case .application(let application): application.displayName
        case .unresolved: "Application Not Found"
        }
    }

    var detail: String {
        switch self {
        case .systemDefault:
            "Shift-Command-O uses the default app for each file"
        case .application(let application):
            "Shift-Command-O opens files in \(application.displayName)"
        case .unresolved:
            "The selected application cannot be resolved. Choose another app or use System Default."
        }
    }
}

enum ExternalEditorResolver {
    static let bundlePrefix = "bundle:"
    static let pathPrefix = "path:"

    @MainActor
    static func resolve(_ storedValue: String) -> ExternalEditorResolution {
        resolve(
            storedValue,
            applicationForBundleIdentifier: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
            applicationForLegacyName: { applicationURL(forLegacyName: $0) },
            inspectApplication: { ExternalEditorApplication(url: $0) }
        )
    }

    static func resolve(
        _ storedValue: String,
        applicationForBundleIdentifier: (String) -> URL?,
        applicationForLegacyName: (String) -> URL?,
        inspectApplication: (URL) -> ExternalEditorApplication?
    ) -> ExternalEditorResolution {
        let selection = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return .systemDefault }

        if selection.hasPrefix(bundlePrefix) {
            let identifier = String(selection.dropFirst(bundlePrefix.count))
            guard !identifier.isEmpty,
                  let url = applicationForBundleIdentifier(identifier),
                  let application = inspectApplication(url) else {
                return .unresolved
            }
            return .application(application)
        }

        if selection.hasPrefix(pathPrefix) {
            let path = String(selection.dropFirst(pathPrefix.count))
            guard path.hasPrefix("/"),
                  let application = inspectApplication(URL(fileURLWithPath: path)) else {
                return .unresolved
            }
            return .application(application)
        }

        if selection.hasPrefix("/"),
           let application = inspectApplication(URL(fileURLWithPath: selection)) {
            return .application(application)
        }
        if let url = applicationForBundleIdentifier(selection),
           let application = inspectApplication(url) {
            return .application(application)
        }
        if let url = applicationForLegacyName(selection),
           let application = inspectApplication(url) {
            return .application(application)
        }
        return .unresolved
    }

    static func storedValue(for application: ExternalEditorApplication) -> String {
        if let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundlePrefix + bundleIdentifier
        }
        return pathPrefix + application.url.standardizedFileURL.path
    }

    private static func applicationURL(
        forLegacyName name: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 128,
              !trimmed.contains("/"),
              !trimmed.contains(":") else {
            return nil
        }
        let fileName = trimmed.lowercased().hasSuffix(".app") ? trimmed : trimmed + ".app"
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        return roots.lazy
            .map { $0.appendingPathComponent(fileName, isDirectory: true) }
            .first { fileManager.fileExists(atPath: $0.path) }
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
            || environment["KAISOLA_NATIVE_PDF_PREVIEW_BUDGET"] != nil
    }

    nonisolated static func isolatedFixtureSuiteName(
        environment: [String: String],
        processIdentifier: Int32
    ) -> String? {
        guard isIsolatedFixture(environment: environment) else { return nil }
        let kind: String
        if environment["KAISOLA_NATIVE_RESOURCE_WORKLOAD"] != nil {
            kind = "resource-fixture"
        } else if environment["KAISOLA_NATIVE_PDF_PREVIEW_BUDGET"] != nil {
            kind = "pdf-preview-budget"
        } else {
            kind = "visual-fixture"
        }
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

    /// Opt-in "living tint": the Tinted surfaces breathe a few percent of
    /// opacity on the render server, alongside the always-on endpoint drift.
    /// Off is exactly the shipped Tinted composition.
    @Published var tintedBreathing: Bool {
        didSet { persist(tintedBreathing, forKey: Keys.tintedBreathing) }
    }

    /// Which named tint the Tinted theme paints. Meadow is the shipped
    /// composition, so an existing install sees no change until it chooses.
    @Published var tintPalette: TintPalette {
        didSet { persist(tintPalette.rawValue, forKey: Keys.tintPalette) }
    }

    /// The single theme control Settings vends, over the two properties above.
    ///
    /// Reads as Glass only when *both* surfaces are glass, so a workspace left on
    /// Solid by an older build reports Solid rather than claiming a state it is
    /// only half in. Writing sets both, which is the point: they were separate
    /// rows nobody wanted to reason about independently.
    var theme: KaisolaTheme {
        get {
            if sidebarAppearance == .glass && workspaceBackdrop == .glass { return .glass }
            if sidebarAppearance == .tinted || workspaceBackdrop == .tinted { return .tinted }
            return .solid
        }
        set {
            sidebarAppearance = newValue.sidebarAppearance
            workspaceBackdrop = newValue.workspaceBackdrop
        }
    }

    @Published var toolCallDensity: ToolCallDensity {
        didSet { persist(toolCallDensity.rawValue, forKey: Keys.toolCallDensity) }
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
    // 5,000 (was 20,000; 2026-08-06 spec §2b): the live view is a WINDOW.
    // The renderer's reachable tail is ~4 MiB ≈ 20k rows anyway, deep history
    // pages from the broker's append-only disk spool via the transcript
    // viewer — back to the session's first byte, across reboots — and
    // terminal cell buffers are the app's single largest memory consumer.
    // Users who customized the setting keep their value.
    static let terminalScrollbackDefault = 5_000
    static let terminalScrollbackPolicyVersion = 3

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

    /// The selected terminal theme's id — a `TerminalThemeRegistry` id, which
    /// may name a custom theme. An id whose theme has since been removed or
    /// invalidated resolves to the shipped default at install time rather
    /// than being rewritten here, so fixing the theme restores the choice.
    @Published var terminalThemeID: String {
        didSet { persist(terminalThemeID, forKey: Keys.terminalPalette) }
    }

    /// Retype a privately persisted, unsent CLI composer draft only after a
    /// provider continuation reaches a quiet prompt. The restore is cancelled
    /// as soon as the user starts interacting with that new terminal.
    @Published var restoreCLIDrafts: Bool {
        didSet { persist(restoreCLIDrafts, forKey: Keys.restoreCLIDrafts) }
    }

    /// The system-wide summon hotkey (⌥⌘K). Off by default — an app that
    /// silently claims a global combo on update has overstepped.
    @Published var summonHotkeyEnabled: Bool {
        didSet { persist(summonHotkeyEnabled, forKey: Keys.summonHotkeyEnabled) }
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

    /// Width of the LEFT project rail, written by the sidebar resize handle
    /// when the user lets go of a drag. Zero means "never dragged": nothing
    /// before v0.1.125 persisted this rail, so the sentinel keeps a fresh
    /// window on the chrome's compile-time ideal until the user has actually
    /// chosen a width — after which every new window opens at that choice.
    @Published var projectRailWidth: Double {
        didSet {
            if projectRailWidth != Self.projectRailWidthUnset {
                let clamped = Self.clampedProjectRailWidth(projectRailWidth)
                if clamped != projectRailWidth {
                    projectRailWidth = clamped
                    return
                }
            }
            persist(projectRailWidth, forKey: Keys.projectRailWidth)
        }
    }

    static let projectRailWidthUnset: Double = 0
    /// Derived from `NativeWorkspaceChrome`'s band for the same rail so the
    /// two can never drift — a hand-copied mirror of one band in one module
    /// already moved once inside this release.
    static let projectRailWidthRange: ClosedRange<Double> =
        Double(NativeWorkspaceChrome.projectSidebarMinimumWidth)
            ... Double(NativeWorkspaceChrome.projectSidebarMaximumWidth)

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

    /// Resolved application identity for "Open in External Editor" (⇧⌘O).
    /// Empty means the system default; new choices persist a bundle identifier
    /// (or an application path only when the bundle has no identifier). Legacy
    /// names remain readable, but never become an unchecked `open -a` argument.
    @Published var externalEditorApp: String {
        didSet { persist(externalEditorApp, forKey: Keys.externalEditorApp) }
    }

    var externalEditorResolution: ExternalEditorResolution {
        ExternalEditorResolver.resolve(externalEditorApp)
    }

    @discardableResult
    func selectExternalEditor(at applicationURL: URL) -> Bool {
        guard let application = ExternalEditorApplication(url: applicationURL) else { return false }
        externalEditorApp = ExternalEditorResolver.storedValue(for: application)
        return true
    }

    func useSystemDefaultExternalEditor() {
        externalEditorApp = ""
    }

    /// Open a file (or directory) only through a currently resolved choice.
    /// Invalid legacy text is rejected instead of being passed to a subprocess.
    @discardableResult
    func openInExternalEditor(_ url: URL) -> Bool {
        switch externalEditorResolution {
        case .systemDefault:
            return NSWorkspace.shared.open(url)
        case .application(let application):
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: application.url,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
            return true
        case .unresolved:
            return false
        }
    }

    static let externalEditorTestFileName = "Kaisola External Editor Test.txt"

    static func writeExternalEditorTestDocument(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = temporaryDirectory.appendingPathComponent(
            "Kaisola External Editor Test",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(externalEditorTestFileName, isDirectory: false)
        try Data(
            "This safe test file contains no project or account data.\n".utf8
        ).write(to: url, options: .atomic)
        return url
    }

    /// Exercise the configured route with a benign generated file, never an
    /// active project file or a user's draft.
    @discardableResult
    func testExternalEditor() -> Bool {
        guard externalEditorResolution.isAvailable,
              let url = try? Self.writeExternalEditorTestDocument() else {
            return false
        }
        return openInExternalEditor(url)
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
        static let tintedBreathing = "tintedBreathing"
        static let tintPalette = "tintPalette"
        static let toolCallDensity = "toolCallDensity"
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
        static let summonHotkeyEnabled = "summonHotkeyEnabled"
        static let semanticShellIntegration = "semanticShellIntegration"
        static let terminalClipboardWriteAllowed = "terminalClipboardWriteAllowed"
        static let workspaceRail = "workspaceRailVisible"
        static let workspaceRailWidth = "workspaceRailWidth"
        static let projectRailWidth = "projectRailWidth"
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
        tintedBreathing = defaults.object(forKey: Keys.tintedBreathing) as? Bool ?? false
        tintPalette = defaults.string(forKey: Keys.tintPalette).flatMap(TintPalette.init) ?? .meadow
        toolCallDensity = defaults.string(forKey: Keys.toolCallDensity)
            .flatMap(ToolCallDensity.init) ?? .balanced
        // The four glass knobs are a preset now, not preferences, so they are
        // NOT read back from defaults: a value stored by a build that still
        // offered the pickers would otherwise outlive the pickers themselves and
        // leave someone on a recipe they can no longer see or change. See
        // `GlassPreset`. They stay settable — the measured test corpus sweeps
        // them — and `Keys` still names them, so restoring a picker later needs
        // no migration.
        glassBackdropSource = GlassPreset.source
        glassTexture = GlassPreset.texture
        glassColour = GlassPreset.colour
        glassClarity = GlassPreset.clarity
        // Still a real preference: pinning a picture is the one glass choice
        // that is about *content* rather than about the material, and it stays
        // meaningful as the painted fallback's input.
        glassWallpaper = defaults.string(forKey: Keys.glassWallpaper) ?? ""
        let stored = defaults.double(forKey: Keys.terminalFontSize)
        terminalFontSize = stored > 0
            ? min(max(stored, Self.terminalFontRange.lowerBound), Self.terminalFontRange.upperBound)
            : Self.terminalFontDefault
        workspaceRailVisible = defaults.object(forKey: Keys.workspaceRail) as? Bool ?? true
        let storedRailWidth = defaults.double(forKey: Keys.workspaceRailWidth)
        workspaceRailWidth = storedRailWidth > 0
            ? Self.clampedWorkspaceRailWidth(storedRailWidth)
            : Self.workspaceRailWidthDefault
        let storedProjectRailWidth = defaults.double(forKey: Keys.projectRailWidth)
        projectRailWidth = storedProjectRailWidth > 0
            ? Self.clampedProjectRailWidth(storedProjectRailWidth)
            : Self.projectRailWidthUnset
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
        // Version 1 temporarily made 100 000 the implicit default; version 2
        // made it 20 000. Each policy step migrates the PREVIOUS implicit
        // default exactly once — after the marker is written, the same value
        // chosen explicitly is preserved, and custom depths are never
        // touched. Version 3 (2026-08-06 spec §2b) steps to the 5 000-line
        // window now that history pages losslessly from the broker spool.
        let previousImplicitDefaults = [Self.terminalScrollbackRange.upperBound, 20_000]
        let migratesLegacyMaximum = storedScrollbackPolicyVersion < Self.terminalScrollbackPolicyVersion
            && previousImplicitDefaults.contains(storedScrollback)
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
        terminalThemeID = defaults.string(forKey: Keys.terminalPalette) ?? "native"
        restoreCLIDrafts = defaults.object(forKey: Keys.restoreCLIDrafts) as? Bool ?? true
        summonHotkeyEnabled = defaults.object(forKey: Keys.summonHotkeyEnabled) as? Bool ?? false
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
        terminalThemeID = "native"
    }

    static func clampedWorkspaceRailWidth(_ width: Double) -> Double {
        min(max(width, workspaceRailWidthRange.lowerBound), workspaceRailWidthRange.upperBound)
    }

    static func clampedProjectRailWidth(_ width: Double) -> Double {
        min(max(width, projectRailWidthRange.lowerBound), projectRailWidthRange.upperBound)
    }

    static func clampedFilePreviewWidth(_ width: Double) -> Double {
        min(max(width, filePreviewWidthRange.lowerBound), filePreviewWidthRange.upperBound)
    }

    static func clampedTerminalLineSpacing(_ spacing: Double) -> Double {
        min(max(spacing, terminalLineSpacingRange.lowerBound), terminalLineSpacingRange.upperBound)
    }
}
