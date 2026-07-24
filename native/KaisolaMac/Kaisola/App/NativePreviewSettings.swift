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

/// Sidebar treatment. Glass is the native-preview default; Solid is retained
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

/// Terminal color choices. Native is deliberately the default: a quiet
/// white/near-black macOS Terminal canvas. Kaisola preserves the richer
/// Electron-matched palette for users who prefer it.
enum TerminalPaletteMode: String, CaseIterable, Identifiable, Sendable {
    case native
    case kaisola

    var id: String { rawValue }
    var title: String { self == .native ? "macOS Terminal" : "Kaisola" }
}

/// App-wide preview settings, persisted in UserDefaults under the preview's own
/// suite so they never touch any Electron profile.
@MainActor
final class NativePreviewSettings: ObservableObject {
    static let shared = NativePreviewSettings()

    @Published var navigationLayout: NavigationLayout {
        didSet { defaults.set(navigationLayout.rawValue, forKey: Keys.layout) }
    }

    @Published var appearance: AppearanceMode {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    @Published var sidebarAppearance: SidebarAppearance {
        didSet { defaults.set(sidebarAppearance.rawValue, forKey: Keys.sidebarAppearance) }
    }

    @Published var workspaceBackdrop: WorkspaceBackdropMode {
        didSet { defaults.set(workspaceBackdrop.rawValue, forKey: Keys.workspaceBackdrop) }
    }

    /// Terminal font size (⌘+/⌘−/⌘0), clamped to a readable range.
    @Published var terminalFontSize: Double {
        didSet { defaults.set(terminalFontSize, forKey: Keys.terminalFontSize) }
    }

    static let terminalFontRange: ClosedRange<Double> = 9...22
    static let terminalFontDefault: Double = 13

    /// Terminal font family ("System Mono" sentinel = SF Mono) and weight.
    @Published var terminalFontFamily: String {
        didSet { defaults.set(terminalFontFamily, forKey: Keys.terminalFontFamily) }
    }

    @Published var terminalFontWeight: String {
        didSet { defaults.set(terminalFontWeight, forKey: Keys.terminalFontWeight) }
    }

    @Published var terminalPalette: TerminalPaletteMode {
        didSet { defaults.set(terminalPalette.rawValue, forKey: Keys.terminalPalette) }
    }

    /// Whether the workspace rail (file tree, ⌘B) is shown.
    @Published var workspaceRailVisible: Bool {
        didSet { defaults.set(workspaceRailVisible, forKey: Keys.workspaceRail) }
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
                defaults.set(clamped, forKey: Keys.workspaceRailWidth)
            }
        }
    }

    static let workspaceRailWidthRange: ClosedRange<Double> = 188...330
    static let workspaceRailWidthDefault: Double = 218

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
                defaults.set(clamped, forKey: Keys.filePreviewWidth)
            }
        }
    }

    static let filePreviewWidthRange: ClosedRange<Double> = 300...920
    static let filePreviewWidthDefault: Double = 480

    /// Sensitive-file globs the guardrails enforce (always prompt, never
    /// rule-coverable, fs bridge refuses them). Editable in Settings.
    @Published var sensitiveGlobs: [String] {
        didSet { defaults.set(sensitiveGlobs, forKey: Keys.sensitiveGlobs) }
    }

    /// Per-agent account isolation: a custom CLAUDE_CONFIG_DIR / CODEX_HOME
    /// applied to agent terminals and ACP adapters. Empty = the CLI default.
    @Published var claudeConfigDir: String {
        didSet { defaults.set(claudeConfigDir, forKey: Keys.claudeConfigDir) }
    }

    @Published var codexHome: String {
        didSet { defaults.set(codexHome, forKey: Keys.codexHome) }
    }

    /// Application name for "Open in External Editor" (⇧⌘O), e.g.
    /// "Visual Studio Code" / "Cursor" / "Zed". Empty = the system default
    /// app for the file's type.
    @Published var externalEditorApp: String {
        didSet { defaults.set(externalEditorApp, forKey: Keys.externalEditorApp) }
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
        let claude = claudeConfigDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !claude.isEmpty { env["CLAUDE_CONFIG_DIR"] = (claude as NSString).expandingTildeInPath }
        let codex = codexHome.trimmingCharacters(in: .whitespacesAndNewlines)
        if !codex.isEmpty { env["CODEX_HOME"] = (codex as NSString).expandingTildeInPath }
        return env
    }

    private let defaults: UserDefaults
    private var defersPanelPersistence = false

    /// Divider drags update SwiftUI continuously but persist only once at the
    /// end. This removes synchronous UserDefaults traffic from pointer tracking.
    func beginPanelResize() {
        defersPanelPersistence = true
    }

    func endPanelResize() {
        defersPanelPersistence = false
        defaults.set(workspaceRailWidth, forKey: Keys.workspaceRailWidth)
        defaults.set(filePreviewWidth, forKey: Keys.filePreviewWidth)
    }

    private enum Keys {
        static let layout = "navigationLayout"
        static let appearance = "appearanceMode"
        static let sidebarAppearance = "sidebarAppearance"
        static let workspaceBackdrop = "workspaceBackdrop"
        static let terminalFontSize = "terminalFontSize"
        static let terminalFontFamily = "terminalFontFamily"
        static let terminalFontWeight = "terminalFontWeight"
        static let terminalPalette = "terminalPalette"
        static let workspaceRail = "workspaceRailVisible"
        static let workspaceRailWidth = "workspaceRailWidth"
        static let filePreviewWidth = "filePreviewWidth"
        static let sensitiveGlobs = "sensitiveGlobs"
        static let claudeConfigDir = "claudeConfigDir"
        static let codexHome = "codexHome"
        static let externalEditorApp = "externalEditorApp"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        terminalPalette = defaults.string(forKey: Keys.terminalPalette).flatMap(TerminalPaletteMode.init) ?? .native
        sensitiveGlobs = defaults.stringArray(forKey: Keys.sensitiveGlobs) ?? AcpPermissionRules.defaultSensitiveGlobs
        claudeConfigDir = defaults.string(forKey: Keys.claudeConfigDir) ?? ""
        codexHome = defaults.string(forKey: Keys.codexHome) ?? ""
        externalEditorApp = defaults.string(forKey: Keys.externalEditorApp) ?? ""
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

    static func clampedWorkspaceRailWidth(_ width: Double) -> Double {
        min(max(width, workspaceRailWidthRange.lowerBound), workspaceRailWidthRange.upperBound)
    }

    static func clampedFilePreviewWidth(_ width: Double) -> Double {
        min(max(width, filePreviewWidthRange.lowerBound), filePreviewWidthRange.upperBound)
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
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
    }
}

/// Reusable material used by both the project sidebar and the workspace file
/// rail, keeping the two left-hand navigation surfaces visually coherent.
struct SidebarBackdropView: View {
    @Environment(\.colorScheme) private var colorScheme
    let appearance: SidebarAppearance

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .glass:
            ZStack {
                NativeVisualEffectView(material: .sidebar)
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.045 : 0.075),
                        Color.accentColor.opacity(colorScheme == .dark ? 0.065 : 0.025),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                LinearGradient(
                    colors: [Color.white.opacity(colorScheme == .dark ? 0.02 : 0.13), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.26)
                )
            }
        case .solid:
            Color(nsColor: .controlBackgroundColor)
        }
    }
}

struct WorkspaceBackdropView: View {
    let mode: WorkspaceBackdropMode

    @ViewBuilder
    var body: some View {
        switch mode {
        case .system:
            Color(nsColor: .windowBackgroundColor)
        case .glass:
            ZStack {
                NativeVisualEffectView(material: .underWindowBackground)
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.035),
                        Color.clear,
                        Color.purple.opacity(0.025),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        case .tinted:
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.11),
                        Color.purple.opacity(0.055),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}
