import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Typed command identity and shortcuts

/// Stable command identity shared by AppKit menus, SwiftUI shortcuts, the
/// command palette, and user keymap overrides. Dynamic commands retain their
/// payload in the identifier instead of smuggling untyped values through a
/// menu item's `representedObject`.
struct AppCommandID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let newWindow = Self(rawValue: "window.new")
    static let openProject = Self(rawValue: "project.open")
    static let openProjectInNewWindow = Self(rawValue: "project.open-new-window")
    static let reopenClosedProject = Self(rawValue: "project.reopen-closed")
    static let reopenClosedSession = Self(rawValue: "session.reopen-closed")
    static let reopenClosedFileTab = Self(rawValue: "file.reopen-closed-tab")
    static let closeContext = Self(rawValue: "window.close-context")
    static let closeWindow = Self(rawValue: "window.close")
    static let newTerminal = Self(rawValue: "session.new-terminal")
    static let newMesh = Self(rawValue: "mesh.new")
    static let newStagedMesh = Self(rawValue: "mesh.new-staged")
    static let newIdeaMesh = Self(rawValue: "mesh.new-idea")
    static let commandPalette = Self(rawValue: "view.command-palette")
    static let messageCurrentAgent = Self(rawValue: "view.message-current-agent")
    static let toggleFiles = Self(rawValue: "view.toggle-files")
    static let toggleDocumentPreview = Self(rawValue: "view.toggle-document-preview")
    static let openExternalEditor = Self(rawValue: "file.open-external-editor")
    static let previousFileTab = Self(rawValue: "file.previous-tab")
    static let nextFileTab = Self(rawValue: "file.next-tab")
    static let increaseTerminalFont = Self(rawValue: "terminal.increase-font")
    static let decreaseTerminalFont = Self(rawValue: "terminal.decrease-font")
    static let resetTerminalFont = Self(rawValue: "terminal.reset-font")
    static let clearTerminal = Self(rawValue: "terminal.clear")
    static let scrollTerminalToLatest = Self(rawValue: "terminal.scroll-to-latest")
    static let focusPreviousPane = Self(rawValue: "pane.focus-previous")
    static let focusNextPane = Self(rawValue: "pane.focus-next")
    static let openSettings = Self(rawValue: "app.open-settings")
    static let checkForUpdates = Self(rawValue: "app.check-for-updates")
    static var readinessChecklist: Self { Self(rawValue: "app.readiness-checklist") }
    static let openHelp = Self(rawValue: "app.open-help")

    static func newAgent(_ agentID: String) -> Self {
        Self(rawValue: "session.new-agent.\(agentID)")
    }

    static func newChat(_ agentID: String) -> Self {
        Self(rawValue: "chat.new.\(agentID)")
    }

    static func navigationLayout(_ layout: NavigationLayout) -> Self {
        Self(rawValue: "view.navigation-layout.\(layout.rawValue)")
    }

    static func appearance(_ appearance: AppearanceMode) -> Self {
        Self(rawValue: "view.appearance.\(appearance.rawValue)")
    }

    var agentID: String? {
        suffix(after: "session.new-agent.")
    }

    var chatAgentID: String? {
        suffix(after: "chat.new.")
    }

    var navigationLayout: NavigationLayout? {
        suffix(after: "view.navigation-layout.").flatMap(NavigationLayout.init(rawValue:))
    }

    var appearance: AppearanceMode? {
        suffix(after: "view.appearance.").flatMap(AppearanceMode.init(rawValue:))
    }

    private func suffix(after prefix: String) -> String? {
        guard rawValue.hasPrefix(prefix) else { return nil }
        let value = String(rawValue.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}

enum AppCommandModifier: String, CaseIterable, Codable, Hashable, Sendable {
    case control
    case option
    case shift
    case command

    fileprivate var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }
}

/// A normalized shortcut which can feed both AppKit and SwiftUI. User-facing
/// JSON uses readable tokens such as `command+shift+b` and
/// `command+option+left`; only modified shortcuts are accepted so a keymap can
/// never steal ordinary typing from terminals and editors.
struct AppCommandShortcut: Codable, Hashable, Sendable {
    let key: String
    let modifiers: [AppCommandModifier]

    init?(specification: String) {
        let tokens = specification
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !tokens.contains(""), tokens.count >= 2 else { return nil }

        var parsedModifiers = Set<AppCommandModifier>()
        var parsedKey: String?
        for token in tokens {
            let modifier: AppCommandModifier?
            switch token {
            case "control", "ctrl": modifier = .control
            case "option", "alt": modifier = .option
            case "shift": modifier = .shift
            case "command", "cmd": modifier = .command
            default: modifier = nil
            }
            if let modifier {
                guard parsedModifiers.insert(modifier).inserted else { return nil }
            } else {
                guard parsedKey == nil, Self.isSupportedKey(token) else { return nil }
                parsedKey = token
            }
        }
        guard let parsedKey,
              parsedModifiers.contains(.command)
                || parsedModifiers.contains(.control)
                || parsedModifiers.contains(.option) else { return nil }
        key = parsedKey
        modifiers = AppCommandModifier.allCases.filter(parsedModifiers.contains)
    }

    var specification: String {
        let readableOrder: [AppCommandModifier] = [.command, .control, .option, .shift]
        return (readableOrder.filter(modifiers.contains).map(\.rawValue) + [key])
            .joined(separator: "+")
    }

    var display: String {
        modifiers.map(\.symbol).joined() + Self.displayKey(key)
    }

    var appKitKeyEquivalent: String {
        switch key {
        case "left": "\u{F702}"
        case "right": "\u{F703}"
        case "down": "\u{F701}"
        case "up": "\u{F700}"
        case "return": "\r"
        case "escape": "\u{1B}"
        case "space": " "
        case "comma": ","
        case "minus": "-"
        case "plus": "+"
        case "slash": "/"
        default: key
        }
    }

    var appKitModifiers: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { flags, modifier in
            switch modifier {
            case .control: flags.insert(.control)
            case .option: flags.insert(.option)
            case .shift: flags.insert(.shift)
            case .command: flags.insert(.command)
            }
        }
    }

    var swiftUIKeyEquivalent: KeyEquivalent {
        switch key {
        case "left": .leftArrow
        case "right": .rightArrow
        case "down": .downArrow
        case "up": .upArrow
        case "return": .return
        case "escape": .escape
        case "space": .space
        default: KeyEquivalent(Character(appKitKeyEquivalent))
        }
    }

    var swiftUIModifiers: EventModifiers {
        modifiers.reduce(into: EventModifiers()) { flags, modifier in
            switch modifier {
            case .control: flags.insert(.control)
            case .option: flags.insert(.option)
            case .shift: flags.insert(.shift)
            case .command: flags.insert(.command)
            }
        }
    }

    private static func isSupportedKey(_ key: String) -> Bool {
        if key.count == 1,
           let scalar = key.unicodeScalars.first,
           scalar.isASCII,
           (CharacterSet.alphanumerics.contains(scalar)
                || "[];'.`".unicodeScalars.contains(scalar)) {
            return true
        }
        return [
            "left", "right", "down", "up", "return", "escape", "space",
            "comma", "minus", "plus", "slash",
        ].contains(key)
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case "left": "←"
        case "right": "→"
        case "down": "↓"
        case "up": "↑"
        case "return": "↩"
        case "escape": "Esc"
        case "space": "Space"
        case "comma": ","
        case "minus": "−"
        case "plus": "+"
        case "slash": "/"
        default: key.uppercased()
        }
    }
}

struct AppCommandSurfaces: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let menu = Self(rawValue: 1 << 0)
    static let palette = Self(rawValue: 1 << 1)
    static let keymap = Self(rawValue: 1 << 2)
    static let all: Self = [.menu, .palette, .keymap]
}

enum AppCommandCategory: String, Sendable {
    case app = "Kaisola"
    case project = "Project"
    case session = "Session"
    case mesh = "Mesh"
    case file = "File"
    case view = "View"
    case terminal = "Terminal"
    case window = "Window"
    case help = "Help"
}

struct AppCommandDefinition: Identifiable, Hashable, Sendable {
    let id: AppCommandID
    let title: String
    let category: AppCommandCategory
    let systemImage: String
    let defaultShortcut: AppCommandShortcut?
    let surfaces: AppCommandSurfaces
}

struct AppCommandAvailability: Equatable, Sendable {
    let isEnabled: Bool
    let reason: String?

    static let available = Self(isEnabled: true, reason: nil)

    static func unavailable(_ reason: String) -> Self {
        Self(isEnabled: false, reason: reason)
    }
}

@MainActor
struct AppCommandContext {
    let model: AppModel?
    let settings: NativePreviewSettings

    init(model: AppModel?, settings: NativePreviewSettings = .shared) {
        self.model = model
        self.settings = settings
    }
}

extension Notification.Name {
    /// Commands that own window-local SwiftUI presentation are routed back to
    /// the exact RootShellView associated with the command's AppModel.
    static let kaisolaLocalCommand = Notification.Name("kaisola.localCommand")
    /// Reloading/resetting keymap.json rebuilds AppKit menus and SwiftUI
    /// shortcuts from the same effective snapshot.
    static let kaisolaKeymapChanged = Notification.Name("kaisola.keymapChanged")
    /// Layout/appearance commands update AppKit checkmarks even when invoked
    /// from the palette rather than the menu itself.
    static let kaisolaCommandPresentationChanged = Notification.Name("kaisola.commandPresentationChanged")
}

enum AppCommandNotificationKey {
    static let commandID = "commandID"
}

// MARK: - Registry and single execution path

enum AppCommandRegistry {
    private static func shortcut(_ specification: String) -> AppCommandShortcut {
        guard let shortcut = AppCommandShortcut(specification: specification) else {
            preconditionFailure("Invalid built-in shortcut: \(specification)")
        }
        return shortcut
    }

    static var definitions: [AppCommandDefinition] {
        var result: [AppCommandDefinition] = [
            definition(.newTerminal, "New Terminal Session", .session, "terminal", "command+t"),
            definition(.openProject, "Open Folder…", .project, "folder", "command+o"),
            definition(.newWindow, "New Window", .window, "macwindow.badge.plus", "command+shift+n"),
            definition(.openProjectInNewWindow, "Open Project in New Window…", .project, "macwindow.badge.plus", "command+option+o"),
            definition(.reopenClosedFileTab, "Reopen Closed File Tab", .file, "arrow.uturn.backward", "command+shift+t"),
            definition(.reopenClosedSession, "Reopen Closed Session", .session, "arrow.uturn.backward", "command+option+t"),
            definition(.reopenClosedProject, "Reopen Closed Project", .project, "arrow.uturn.backward", "command+option+shift+t"),
            definition(.closeContext, "Close", .window, "xmark", "command+w"),
            definition(.closeWindow, "Close Project Window", .window, "macwindow.badge.xmark", "command+shift+w", surfaces: [.menu, .keymap]),
        ]

        result += AgentRegistry.all.map { agent in
            definition(
                .newAgent(agent.id),
                "New \(agent.name) Session",
                .session,
                agent.symbol,
                nil
            )
        }
        result += AgentRegistry.all.compactMap { agent in
            guard AcpAdapter.forAgent(agent.id) != nil else { return nil }
            return definition(
                .newChat(agent.id),
                "Chat with \(agent.name)",
                .session,
                "bubble.left.and.bubble.right",
                nil
            )
        }

        result += [
            definition(.newMesh, "New Mesh (All Agents)", .mesh, "circle.hexagongrid.fill", nil),
            definition(.newStagedMesh, "New Staged Mesh (Scout → Execute)", .mesh, "arrow.triangle.branch", nil),
            definition(.newIdeaMesh, "New Idea Mesh (Brainstorm)", .mesh, "lightbulb", nil),
            definition(.commandPalette, "Command Palette", .view, "command", "command+k", surfaces: [.menu, .keymap]),
            definition(.messageCurrentAgent, "Message Current Agent", .view, "text.bubble", "command+l"),
            definition(.toggleFiles, "Show or Hide Files", .view, "sidebar.left", "command+b"),
            definition(.toggleDocumentPreview, "Show or Hide Document Preview", .view, "doc.text", "command+shift+b"),
            definition(.openExternalEditor, "Open in External Editor", .file, "arrow.up.forward.app", "command+shift+o"),
            definition(.previousFileTab, "Previous File Tab", .file, "arrow.left", "command+option+left"),
            definition(.nextFileTab, "Next File Tab", .file, "arrow.right", "command+option+right"),
            // Apple's own zoom vocabulary: these route contextually (chat
            // zoom when a chat pane is focused, terminal font otherwise), so
            // "Terminal Font › Bigger" lied to anyone with a chat in front.
            definition(.increaseTerminalFont, "Zoom In", .terminal, "plus.magnifyingglass", "command+plus"),
            definition(.decreaseTerminalFont, "Zoom Out", .terminal, "minus.magnifyingglass", "command+minus"),
            definition(.resetTerminalFont, "Actual Size", .terminal, "textformat.size", "command+0"),
            definition(.clearTerminal, "Clear Terminal", .terminal, "eraser", "command+option+k"),
            definition(.scrollTerminalToLatest, "Scroll to Latest Output", .terminal, "arrow.down.to.line", "command+option+down"),
            definition(.focusPreviousPane, "Focus Previous Pane", .view, "arrow.left.to.line", "command+control+left"),
            definition(.focusNextPane, "Focus Next Pane", .view, "arrow.right.to.line", "command+control+right"),
            definition(.openSettings, "Settings…", .app, "gearshape", "command+comma"),
            definition(.checkForUpdates, "Check for Updates…", .app, "arrow.triangle.2.circlepath", nil),
            definition(
                .readinessChecklist,
                "Readiness Checklist…",
                .help,
                "checklist.checked",
                nil,
                surfaces: [.palette]
            ),
            definition(.openHelp, "Kaisola Help", .help, "questionmark.circle", "command+shift+slash"),
        ]

        result += NavigationLayout.allCases.map { layout in
            definition(
                .navigationLayout(layout),
                "Navigation: \(layout.title)",
                .view,
                "sidebar.squares.left",
                nil
            )
        }
        result += AppearanceMode.allCases.map { appearance in
            definition(
                .appearance(appearance),
                "Appearance: \(appearance.title)",
                .view,
                "circle.lefthalf.filled",
                nil
            )
        }
        return result
    }

    static func definition(for id: AppCommandID) -> AppCommandDefinition? {
        definitions.first { $0.id == id }
    }

    static var keymapDefinitions: [AppCommandDefinition] {
        definitions.filter { $0.surfaces.contains(.keymap) }
    }

    static var paletteDefinitions: [AppCommandDefinition] {
        definitions.filter { $0.surfaces.contains(.palette) }
    }

    @MainActor
    static func presentationTitle(
        for id: AppCommandID,
        in context: AppCommandContext
    ) -> String {
        if id == .closeContext {
            return context.model?.previewedFileURL == nil ? "Close Window" : "Close File Tab"
        }
        return definition(for: id)?.title ?? id.rawValue
    }

    @MainActor
    static func availability(
        of id: AppCommandID,
        in context: AppCommandContext
    ) -> AppCommandAvailability {
        let model = context.model
        let delegate = NSApp.delegate as? KaisolaMacAppDelegate

        if id == .newWindow || id == .openProjectInNewWindow || id == .openSettings || id == .openHelp {
            return delegate == nil
                ? .unavailable("Kaisola is not ready to perform this app command.")
                : .available
        }
        if id == .openProject {
            return model == nil && delegate == nil
                ? .unavailable("Kaisola is not ready to open a project.")
                : .available
        }
        if id == .checkForUpdates {
            guard let delegate else {
                return .unavailable("Kaisola is not ready to check for updates.")
            }
            return delegate.commandCanCheckForUpdates
                ? .available
                : .unavailable(delegate.commandUpdateDetail ?? "Update checks are unavailable in this build.")
        }
        if id == .closeWindow {
            return delegate?.commandWindow(for: model) == nil
                ? .unavailable("There is no project window to close.")
                : .available
        }
        if id == .closeContext {
            return delegate?.commandWindow(for: model) == nil
                ? .unavailable("There is no file tab or project window to close.")
                : .available
        }
        if id.navigationLayout != nil || id.appearance != nil {
            return .available
        }

        guard let model else {
            return .unavailable("Open a project window to use this command.")
        }

        if id == .newTerminal || id.agentID != nil {
            return model.controlAvailable
                ? .available
                : .unavailable("Connecting the terminal engine. Try again in a moment.")
        }
        if id.chatAgentID != nil || id == .openProject || id == .toggleFiles
            || id == .commandPalette || id == .messageCurrentAgent {
            return .available
        }
        if id == .newMesh || id == .newStagedMesh || id == .newIdeaMesh {
            return model.currentProjectDirectory == nil
                ? .unavailable("Open or select a project before starting Mesh.")
                : .available
        }
        if id == .reopenClosedProject {
            return model.hasClosedProjects
                ? .available
                : .unavailable("There is no recently closed project to reopen.")
        }
        if id == .reopenClosedSession {
            return model.hasClosedSessions
                ? .available
                : .unavailable("There is no recently closed session to reopen.")
        }
        if id == .reopenClosedFileTab {
            return model.canReopenClosedFileTab
                ? .available
                : .unavailable("There is no recently closed file tab to reopen.")
        }
        if id == .toggleDocumentPreview {
            return (model.previewedFileURL ?? model.currentProjectDirectory) == nil
                ? .unavailable("Open a project or file first.")
                : .available
        }
        if id == .openExternalEditor {
            guard (model.previewedFileURL ?? model.currentProjectDirectory) != nil else {
                return .unavailable("Open a project or file first.")
            }
            return context.settings.externalEditorResolution.isAvailable
                ? .available
                : .unavailable("Choose a valid external editor in Settings first.")
        }
        if id == .previousFileTab || id == .nextFileTab {
            return model.fileTabs(for: model.selectedProjectID).count > 1
                ? .available
                : .unavailable("Open at least two file tabs to move between them.")
        }
        if id == .focusPreviousPane || id == .focusNextPane {
            return model.canCyclePaneFocus
                ? .available
                : .unavailable("Open at least two session panes to move focus.")
        }
        if id == .clearTerminal || id == .scrollTerminalToLatest {
            return delegate?.commandFocusedTerminal(for: model) == nil
                ? .unavailable("Focus a terminal pane first.")
                : .available
        }
        return .available
    }

    /// Whether the zoom shortcuts should speak to the focused agent chat
    /// rather than the terminal font: one Cmd+Plus, routed by what the user
    /// is looking at, the way Apple's own apps overload zoom.
    @MainActor
    private static func focusedPaneIsAgentChat(_ model: AppModel?) -> Bool {
        guard let model, let focused = model.focusedPaneID else { return false }
        return model.chats.contains { $0.id == focused }
    }

    /// The only semantic execution switch for registered commands. Menus,
    /// palette rows, hidden SwiftUI shortcuts, and feature buttons all call
    /// this same function; presentation-only commands are routed to the exact
    /// RootShellView by AppModel identity.
    @discardableResult
    @MainActor
    static func execute(_ id: AppCommandID, in context: AppCommandContext) -> Bool {
        let availability = availability(of: id, in: context)
        guard availability.isEnabled else {
            if let reason = availability.reason {
                ToastCenter.shared.show(reason, style: .info)
            }
            return false
        }

        let model = context.model
        let settings = context.settings
        let delegate = NSApp.delegate as? KaisolaMacAppDelegate

        switch id {
        case .newWindow:
            delegate?.performNewWindowCommand()
        case .openProject:
            if let model {
                RootShellView.promptForOpenFolder(model: model)
            } else {
                delegate?.performOpenProjectInNewWindowCommand()
            }
        case .openProjectInNewWindow:
            delegate?.performOpenProjectInNewWindowCommand()
        case .reopenClosedProject:
            model?.reopenLastClosedProject()
        case .reopenClosedSession:
            if let model { Task { await model.reopenLastClosedSession() } }
        case .reopenClosedFileTab:
            _ = model?.reopenClosedFileTab()
        case .closeContext:
            if let model, model.previewedFileURL != nil {
                NotificationCenter.default.post(name: .kaisolaCloseActiveFileTab, object: model)
            } else {
                delegate?.performCloseWindowCommand(for: model)
            }
        case .closeWindow:
            delegate?.performCloseWindowCommand(for: model)
        case .newTerminal:
            if let model { RootShellView.promptForNewTerminal(model: model) }
        case .newMesh:
            if let model { RootShellView.promptForNewMesh(model: model) }
        case .newStagedMesh:
            if let model { RootShellView.promptForNewMesh(model: model, staged: true) }
        case .newIdeaMesh:
            if let model { RootShellView.promptForNewMesh(model: model, idea: true) }
        case .toggleFiles:
            settings.workspaceRailVisible.toggle()
        case .openExternalEditor:
            if let target = model?.previewedFileURL ?? model?.currentProjectDirectory {
                settings.openInExternalEditor(target)
            }
        case .previousFileTab:
            model?.selectAdjacentFileTab(direction: -1)
        case .nextFileTab:
            model?.selectAdjacentFileTab(direction: 1)
        case .increaseTerminalFont:
            if focusedPaneIsAgentChat(model) {
                settings.stepAgentChatTextSize(by: 1)
            } else {
                settings.adjustTerminalFont(by: 1)
            }
        case .decreaseTerminalFont:
            if focusedPaneIsAgentChat(model) {
                settings.stepAgentChatTextSize(by: -1)
            } else {
                settings.adjustTerminalFont(by: -1)
            }
        case .resetTerminalFont:
            if focusedPaneIsAgentChat(model) {
                settings.resetAgentChatTextSize()
            } else {
                settings.resetTerminalFont()
            }
        case .clearTerminal:
            delegate?.commandFocusedTerminal(for: model)?.clearLiveScrollback()
        case .scrollTerminalToLatest:
            if let terminal = delegate?.commandFocusedTerminal(for: model) {
                terminal.resumeLiveFollow()
                terminal.scrollToLiveBottom()
            }
        case .focusPreviousPane:
            model?.cyclePaneFocus(forward: false)
        case .focusNextPane:
            model?.cyclePaneFocus(forward: true)
        case .openSettings:
            delegate?.performOpenSettingsCommand()
        case .checkForUpdates:
            delegate?.performCheckForUpdatesCommand()
        case .openHelp:
            delegate?.performOpenHelpCommand()
        case .commandPalette, .messageCurrentAgent, .toggleDocumentPreview, .readinessChecklist:
            NotificationCenter.default.post(
                name: .kaisolaLocalCommand,
                object: model,
                userInfo: [AppCommandNotificationKey.commandID: id.rawValue]
            )
        default:
            if let agentID = id.agentID,
               let agent = AgentRegistry.profile(id: agentID),
               let model {
                RootShellView.promptForNewAgent(agent, model: model)
            } else if let agentID = id.chatAgentID,
                      let agent = AgentRegistry.profile(id: agentID),
                      let model {
                RootShellView.promptForNewChat(agent, model: model)
            } else if let layout = id.navigationLayout {
                // Deferred, never same-stack: a layout switch tears down the
                // whole shell hierarchy, and doing that inside an AppKit
                // event-tracking pass is the v0.1.146 NSSplitView divider
                // crash. The settings model applies it on the next
                // default-mode run-loop turn and posts the presentation
                // notification after the switch has actually landed.
                settings.requestNavigationLayout(layout)
            } else if let appearance = id.appearance {
                settings.appearance = appearance
                NotificationCenter.default.post(name: .kaisolaCommandPresentationChanged, object: nil)
            } else {
                return false
            }
        }
        return true
    }

    private static func definition(
        _ id: AppCommandID,
        _ title: String,
        _ category: AppCommandCategory,
        _ systemImage: String,
        _ shortcutSpecification: String?,
        surfaces: AppCommandSurfaces = .all
    ) -> AppCommandDefinition {
        AppCommandDefinition(
            id: id,
            title: title,
            category: category,
            systemImage: systemImage,
            defaultShortcut: shortcutSpecification.map(shortcut),
            surfaces: surfaces
        )
    }
}

// MARK: - Fail-closed keymap.json overrides

struct AppCommandKeymapSnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case defaults
        case loaded(overrideCount: Int)
        case invalid(issues: [String])
    }

    let effectiveShortcuts: [AppCommandID: AppCommandShortcut]
    let status: Status
    let fileExists: Bool

    func shortcut(for id: AppCommandID) -> AppCommandShortcut? {
        effectiveShortcuts[id]
    }

    var title: String {
        switch status {
        case .defaults: "Default Shortcuts"
        case let .loaded(count): "Custom Shortcuts · \(count) Override\(count == 1 ? "" : "s")"
        case .invalid: "Keymap Needs Attention"
        }
    }

    var detail: String {
        switch status {
        case .defaults:
            "Kaisola is using its built-in shortcuts."
        case .loaded:
            "Validated keymap.json overrides are active in menus and the command palette."
        case .invalid:
            "Overrides were ignored; every built-in shortcut remains active."
        }
    }

    var issues: [String] {
        if case let .invalid(issues) = status { return issues }
        return []
    }
}

struct AppCommandKeymapStore: Sendable {
    private struct Payload: Codable {
        let version: Int
        let bindings: [String: String]
    }

    static let schemaVersion = 1
    static let maximumBytes = 64 * 1_024
    static let maximumBindings = 128

    let fileURL: URL

    init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load(definitions: [AppCommandDefinition]) -> AppCommandKeymapSnapshot {
        let defaults = Self.defaultShortcuts(definitions: definitions)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .init(effectiveShortcuts: defaults, status: .defaults, fileExists: false)
        }
        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                return invalid("keymap.json must be a regular file.", defaults: defaults)
            }
            guard let size = values.fileSize, size <= Self.maximumBytes else {
                return invalid("keymap.json is larger than 64 KiB.", defaults: defaults)
            }
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
            guard payload.version == Self.schemaVersion else {
                return invalid(
                    "Unsupported keymap version \(payload.version); expected version \(Self.schemaVersion).",
                    defaults: defaults
                )
            }
            guard payload.bindings.count <= Self.maximumBindings else {
                return invalid("keymap.json contains more than 128 bindings.", defaults: defaults)
            }

            let known = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id.rawValue, $0.id) })
            var overrides: [AppCommandID: AppCommandShortcut] = [:]
            var issues: [String] = []
            for (rawID, specification) in payload.bindings.sorted(by: { $0.key < $1.key }) {
                guard let id = known[rawID] else {
                    issues.append("Unknown command id: \(rawID).")
                    continue
                }
                guard let shortcut = AppCommandShortcut(specification: specification) else {
                    issues.append("Invalid shortcut for \(rawID): \(specification).")
                    continue
                }
                overrides[id] = shortcut
            }
            guard issues.isEmpty else { return invalid(issues, defaults: defaults) }

            var effective = defaults
            for (id, shortcut) in overrides { effective[id] = shortcut }
            issues = Self.conflicts(in: effective, definitions: definitions)
            guard issues.isEmpty else { return invalid(issues, defaults: defaults) }
            return .init(
                effectiveShortcuts: effective,
                status: .loaded(overrideCount: overrides.count),
                fileExists: true
            )
        } catch {
            return invalid("keymap.json is not valid versioned JSON.", defaults: defaults)
        }
    }

    func writeTemplate(definitions: [AppCommandDefinition]) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { return }
        let bindings = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            definition.defaultShortcut.map { (definition.id.rawValue, $0.specification) }
        })
        let payload = Payload(version: Self.schemaVersion, bindings: bindings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(payload)
        data.append(0x0A)
        try writeAtomically(data)
    }

    func reset() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> URL {
        let isXCTest = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        if NativePreviewSettings.isIsolatedFixture(environment: environment) || isXCTest {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("kaisola-keymap-\(processIdentifier)", isDirectory: true)
                .appendingPathComponent("keymap.json", isDirectory: false)
        }
        return NativePreviewPaths.applicationSupportDirectory
            .appendingPathComponent("keymap.json", isDirectory: false)
    }

    static func defaultShortcuts(
        definitions: [AppCommandDefinition]
    ) -> [AppCommandID: AppCommandShortcut] {
        Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            definition.defaultShortcut.map { (definition.id, $0) }
        })
    }

    /// Conflicts are evaluated after all overrides are applied, so swapping two
    /// shortcuts in one file is valid while claiming an unchanged default or a
    /// standard text-system shortcut is rejected atomically.
    static func conflicts(
        in shortcuts: [AppCommandID: AppCommandShortcut],
        definitions: [AppCommandDefinition]
    ) -> [String] {
        let titles = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.title) })
        var claims: [AppCommandShortcut: [String]] = [:]
        for (shortcut, title) in reservedShortcuts {
            claims[shortcut, default: []].append(title)
        }
        for (id, shortcut) in shortcuts {
            claims[shortcut, default: []].append(titles[id] ?? id.rawValue)
        }
        return claims
            .filter { $0.value.count > 1 }
            .map { shortcut, commands in
                "\(shortcut.display) is assigned to \(commands.sorted().joined(separator: " and "))."
            }
            .sorted()
    }

    private static var reservedShortcuts: [AppCommandShortcut: String] {
        let specifications: [(String, String)] = [
            ("command+z", "Undo"),
            ("command+shift+z", "Redo"),
            ("command+x", "Cut"),
            ("command+c", "Copy"),
            ("command+v", "Paste"),
            ("command+a", "Select All"),
            ("command+f", "Find"),
            ("command+g", "Find Next"),
            ("command+shift+g", "Find Previous"),
            ("command+e", "Use Selection for Find"),
            ("command+h", "Hide Kaisola"),
            ("command+q", "Quit Kaisola"),
            ("command+m", "Minimize"),
        ]
        return Dictionary(uniqueKeysWithValues: specifications.map { specification, title in
            (AppCommandShortcut(specification: specification)!, title)
        })
    }

    private func invalid(
        _ issue: String,
        defaults: [AppCommandID: AppCommandShortcut]
    ) -> AppCommandKeymapSnapshot {
        invalid([issue], defaults: defaults)
    }

    private func invalid(
        _ issues: [String],
        defaults: [AppCommandID: AppCommandShortcut]
    ) -> AppCommandKeymapSnapshot {
        .init(effectiveShortcuts: defaults, status: .invalid(issues: issues), fileExists: true)
    }

    private func writeAtomically(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }
}

@MainActor
final class AppCommandKeymapCenter: ObservableObject {
    static let shared = AppCommandKeymapCenter()

    @Published private(set) var snapshot: AppCommandKeymapSnapshot
    @Published private(set) var operationError: String?

    let store: AppCommandKeymapStore

    init(store: AppCommandKeymapStore = AppCommandKeymapStore()) {
        self.store = store
        snapshot = store.load(definitions: AppCommandRegistry.keymapDefinitions)
    }

    func shortcut(for id: AppCommandID) -> AppCommandShortcut? {
        snapshot.shortcut(for: id)
    }

    func reload() {
        operationError = nil
        snapshot = store.load(definitions: AppCommandRegistry.keymapDefinitions)
        NotificationCenter.default.post(name: .kaisolaKeymapChanged, object: self)
    }

    func createOrOpenKeymap() {
        do {
            try store.writeTemplate(definitions: AppCommandRegistry.keymapDefinitions)
            reload()
            NSWorkspace.shared.open(store.fileURL)
        } catch {
            operationError = "Kaisola could not create keymap.json."
        }
    }

    func reset() {
        do {
            try store.reset()
            reload()
        } catch {
            operationError = "Kaisola could not reset keymap.json."
        }
    }
}

// MARK: - Settings surface

struct CommandKeymapSettingsView: View {
    @ObservedObject private var center = AppCommandKeymapCenter.shared
    @State private var confirmsReset = false

    private var visibleDefinitions: [AppCommandDefinition] {
        AppCommandRegistry.keymapDefinitions.filter {
            center.shortcut(for: $0.id) != nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard(title: "Keyboard Shortcuts", symbol: "keyboard") {
                    SettingsRow(
                        title: center.snapshot.title,
                        detail: center.snapshot.detail,
                        symbol: center.snapshot.issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
                    ) {
                        HStack(spacing: 8) {
                            Button(center.snapshot.fileExists ? "Open Keymap…" : "Create Keymap…") {
                                center.createOrOpenKeymap()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("Reload") { center.reload() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Reset") { confirmsReset = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!center.snapshot.fileExists)
                        }
                    }
                    if !center.snapshot.issues.isEmpty || center.operationError != nil {
                        SettingsDivider()
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(center.snapshot.issues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle.fill")
                            }
                            if let operationError = center.operationError {
                                Label(operationError, systemImage: "xmark.circle.fill")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(center.store.fileURL.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("Use version 1 and a bindings object, for example: \"view.toggle-files\": \"command+option+b\".")
                            .font(.caption)
                            .foregroundStyle(.kaisolaSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                SettingsCard(title: "Active Bindings", symbol: "command") {
                    ForEach(Array(visibleDefinitions.enumerated()), id: \.element.id) { index, definition in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(
                            title: definition.title,
                            detail: definition.category.rawValue,
                            symbol: definition.systemImage
                        ) {
                            if let shortcut = center.shortcut(for: definition.id) {
                                Text(shortcut.display)
                                    .font(.body.monospaced().weight(.medium))
                                    .accessibilityLabel(shortcut.specification)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .confirmationDialog(
            "Reset Keyboard Shortcuts?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset to Defaults", role: .destructive) { center.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes keymap.json. You can create a fresh template at any time.")
        }
    }
}
