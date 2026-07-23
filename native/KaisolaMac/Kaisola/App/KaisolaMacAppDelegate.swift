import AppKit
import SwiftUI

@main
@MainActor
enum KaisolaMacMain {
    private static let appDelegate = KaisolaMacAppDelegate()

    static func main() {
        // This mode intentionally returns before touching user state or the
        // broker. dyld must still load every linked framework first, making it
        // a cheap packaging check for hardened-runtime/library-validation
        // failures in CI and release preflight.
        if ProcessInfo.processInfo.arguments.dropFirst().contains("--launch-probe") {
            print("KAISOLA_NATIVE_LAUNCH_PROBE=PASS")
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = appDelegate
        application.run()
    }
}

@MainActor
final class KaisolaMacAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let settings = NativePreviewSettings.shared
    private let updateController = NativeUpdateController()
    // Each window is an independent workspace with its own AppModel and broker
    // observer connection — the broker's coexistence contract makes concurrent
    // observers safe. Keyed by the NSWindow so menu actions target the key one.
    private var windowModels: [ObjectIdentifier: AppModel] = [:]
    private var windowCounter = 0
    private var wakeObserver: NSObjectProtocol?
    private var agentsObserver: NSObjectProtocol?
    private var runInTerminalObserver: NSObjectProtocol?
    private var checkForUpdatesObserver: NSObjectProtocol?
    private let runtimeSmoke = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_RUNTIME_SMOKE"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Preview-owned state stays separate from every historical Electron
        // profile. Broker discovery is explicitly read-only and lives elsewhere.
        try? NativePreviewPaths.prepareApplicationSupport()
        settings.applyAppearance()
        NotificationBridge.shared.requestAuthorizationIfNeeded()
        installMainMenu()
        // Custom agents added/removed in Settings rebuild the static AppKit
        // menus (SwiftUI surfaces re-read the registry on their own).
        agentsObserver = NotificationCenter.default.addObserver(
            forName: .kaisolaAgentsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installMainMenu() }
        }
        // The Settings sign-in card asks for a terminal via notification (it
        // has no AppModel). Handled here — not per-window — so exactly one
        // shell window spawns the terminal.
        runInTerminalObserver = NotificationCenter.default.addObserver(
            forName: .kaisolaRunInTerminal, object: nil, queue: .main
        ) { [weak self] note in
            let command = note.userInfo?[SignInCardView.commandUserInfoKey] as? String
            Task { @MainActor in
                guard let command, let model = self?.keyModel() else { return }
                await model.runCommandInNewTerminal(command)
            }
        }
        checkForUpdatesObserver = NotificationCenter.default.addObserver(
            forName: .kaisolaCheckForUpdates, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateController.checkForUpdates(nil) }
        }
        _ = makeWindow()
        NSApp.activate(ignoringOtherApps: true)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                for model in self?.windowModels.values ?? [:].values {
                    await model.recoverAfterWake()
                }
            }
        }
    }

    /// Create a fresh, independent workspace window.
    @discardableResult
    private func makeWindow() -> NSWindow {
        let model = AppModel()
        let content = RootShellView()
            .environmentObject(model)
            .environmentObject(settings)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Kaisola Preview"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        // Cascade extra windows so they do not stack exactly.
        if windowCounter == 0 {
            window.center()
            window.setFrameAutosaveName("KaisolaNativePreview.MainWindow")
        } else {
            window.cascadeTopLeft(from: NSPoint(x: 40 * CGFloat(windowCounter), y: 40 * CGFloat(windowCounter)))
        }
        windowCounter += 1
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        windowModels[ObjectIdentifier(window)] = model
        // The release pipeline's real-bundle smoke loads AppKit, SwiftUI,
        // notifications, settings, and every linked framework, but deliberately
        // skips broker discovery so it cannot leave a CI helper behind.
        if !runtimeSmoke {
            Task { await model.reload() }
        }
        return window
    }

    /// The AppModel for the frontmost window (menu-command target).
    private func keyModel() -> AppModel? {
        if let key = NSApp.keyWindow, let model = windowModels[ObjectIdentifier(key)] { return model }
        return windowModels.values.first
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for model in windowModels.values { model.resumeIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let agentsObserver { NotificationCenter.default.removeObserver(agentsObserver) }
        if let runInTerminalObserver { NotificationCenter.default.removeObserver(runInTerminalObserver) }
        if let checkForUpdatesObserver { NotificationCenter.default.removeObserver(checkForUpdatesObserver) }
        wakeObserver = nil
        agentsObserver = nil
        runInTerminalObserver = nil
        checkForUpdatesObserver = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let model = windowModels.removeValue(forKey: ObjectIdentifier(window)) else { return }
        Task { await model.teardown() }
    }

    @objc private func newWindow(_ sender: Any?) {
        makeWindow()
    }

    @objc private func openFolder(_ sender: Any?) {
        guard let model = keyModel() else { return }
        RootShellView.promptForOpenFolder(model: model)
    }

    @objc private func reopenClosedProject(_ sender: Any?) {
        keyModel()?.reopenLastClosedProject()
    }

    @objc private func reopenClosedSession(_ sender: Any?) {
        guard let model = keyModel() else { return }
        Task { await model.reopenLastClosedSession() }
    }

    /// Open a session in its own fresh window (the native "pop out"): the new
    /// window's independent AppModel selects the same broker session.
    static func popOut(sessionID: String) {
        guard let delegate = NSApp.delegate as? KaisolaMacAppDelegate else { return }
        let window = delegate.makeWindow()
        guard let model = delegate.windowModels[ObjectIdentifier(window)] else { return }
        Task {
            // Wait for the fresh model's broker connection before selecting.
            for _ in 0..<50 where !model.connectionState.isConnected {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            model.selectedSessionID = sessionID
            await model.select(sessionID)
        }
    }

    @objc private func increaseTerminalFont(_ sender: Any?) { settings.adjustTerminalFont(by: 1) }
    @objc private func decreaseTerminalFont(_ sender: Any?) { settings.adjustTerminalFont(by: -1) }
    @objc private func resetTerminalFont(_ sender: Any?) { settings.resetTerminalFont() }

    // MARK: - Recents & saved windows

    private let savedWindows = SavedWindowsStore()

    @objc private func openRecentFolder(_ sender: Any?) {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String,
              let model = keyModel() else { return }
        model.openProject(directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Save the key window's frame + active project under a user-chosen name.
    @objc private func saveWindowLayout(_ sender: Any?) {
        guard let window = NSApp.keyWindow, let model = windowModels[ObjectIdentifier(window)] else { return }
        let alert = NSAlert()
        alert.messageText = "Save Window Layout"
        alert.informativeText = "Name this window state; opening it later restores the frame and active project."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Layout name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        savedWindows.save(SavedWindowState(
            name: name,
            frame: NSStringFromRect(window.frame),
            projectName: model.selectedProjectName
        ))
        ToastCenter.shared.show("Layout saved", style: .success)
    }

    @objc private func openSavedWindow(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String,
              let state = savedWindows.all().first(where: { $0.name == name }) else { return }
        let window = makeWindow()
        let frame = NSRectFromString(state.frame)
        if frame.width > 200, frame.height > 200 { window.setFrame(frame, display: true) }
        if let projectName = state.projectName,
           let model = windowModels[ObjectIdentifier(window)] {
            model.selectedProjectName = projectName
        }
    }

    @objc private func deleteSavedWindow(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        savedWindows.remove(name: name)
    }

    /// Populates the dynamic submenus (Open Recent / Saved Windows) on open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu.title {
        case "Open Recent":
            let recents = NativeSessionStore().recentFolders()
            if recents.isEmpty {
                menu.addItem(NSMenuItem(title: "No Recent Folders", action: nil, keyEquivalent: ""))
            }
            for path in recents {
                let item = menu.addItem(
                    withTitle: (path as NSString).abbreviatingWithTildeInPath,
                    action: #selector(openRecentFolder(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = path
            }
        case "Saved Windows":
            let states = savedWindows.all()
            if states.isEmpty {
                menu.addItem(NSMenuItem(title: "No Saved Windows", action: nil, keyEquivalent: ""))
            }
            for state in states {
                let item = menu.addItem(withTitle: state.name, action: #selector(openSavedWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = state.name
            }
            if !states.isEmpty {
                menu.addItem(.separator())
                let deleteItem = menu.addItem(withTitle: "Delete Saved Window", action: nil, keyEquivalent: "")
                let deleteMenu = NSMenu(title: "Delete Saved Window")
                for state in states {
                    let item = deleteMenu.addItem(withTitle: state.name, action: #selector(deleteSavedWindow(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = state.name
                }
                deleteItem.submenu = deleteMenu
            }
        default:
            break
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates(sender)
    }

    private var settingsWindow: NSWindow?

    @objc func openSettings(_ sender: Any?) {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(
            settings: settings,
            checkForUpdates: { [weak self] in self?.updateController.checkForUpdates(nil) },
            updateDetail: updateController.availability.detail,
            workspace: keyModel()?.currentProjectDirectory
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 570),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    @objc private func newTerminalSession(_ sender: Any?) {
        guard let model = keyModel() else { return }
        RootShellView.promptForNewTerminal(model: model)
    }

    @objc private func newAgentSession(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let model = keyModel(),
              let agent = AgentRegistry.profile(id: item.representedObject as? String ?? "") else { return }
        RootShellView.promptForNewAgent(agent, model: model)
    }

    @objc private func newChatSession(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let model = keyModel(),
              let agent = AgentRegistry.profile(id: item.representedObject as? String ?? "") else { return }
        RootShellView.promptForNewChat(agent, model: model)
    }

    @objc private func setNavigationLayout(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let layout = (item.representedObject as? String).flatMap(NavigationLayout.init) else { return }
        settings.navigationLayout = layout
        refreshMenuStates()
    }

    @objc private func setAppearanceMode(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let mode = (item.representedObject as? String).flatMap(AppearanceMode.init) else { return }
        settings.appearance = mode
        refreshMenuStates()
    }

    /// Reflect the current layout/appearance selection as menu checkmarks.
    private func refreshMenuStates() {
        for item in NSApp.mainMenu?.item(withTitle: "View")?.submenu?.items ?? [] {
            if let raw = item.representedObject as? String {
                if NavigationLayout(rawValue: raw) != nil {
                    item.state = raw == settings.navigationLayout.rawValue ? .on : .off
                } else if AppearanceMode(rawValue: raw) != nil {
                    item.state = raw == settings.appearance.rawValue ? .on : .off
                }
            }
        }
    }

    private func installMainMenu() {
        NSApp.mainMenu = Self.makeMainMenu(
            updateTarget: self,
            updateAction: #selector(checkForUpdates(_:)),
            updateEnabled: updateController.availability.canCheck,
            updateDetail: updateController.availability.detail,
            newWindowTarget: self,
            newWindowAction: #selector(newWindow(_:)),
            openFolderTarget: self,
            openFolderAction: #selector(openFolder(_:)),
            reopenClosedProjectTarget: self,
            reopenClosedProjectAction: #selector(reopenClosedProject(_:)),
            reopenClosedSessionTarget: self,
            reopenClosedSessionAction: #selector(reopenClosedSession(_:)),
            newTerminalTarget: self,
            newTerminalAction: #selector(newTerminalSession(_:)),
            newAgentTarget: self,
            newAgentAction: #selector(newAgentSession(_:)),
            newChatTarget: self,
            newChatAction: #selector(newChatSession(_:)),
            viewTarget: self,
            layoutAction: #selector(setNavigationLayout(_:)),
            appearanceAction: #selector(setAppearanceMode(_:)),
            fontTarget: self,
            fontIncreaseAction: #selector(increaseTerminalFont(_:)),
            fontDecreaseAction: #selector(decreaseTerminalFont(_:)),
            fontResetAction: #selector(resetTerminalFont(_:)),
            dynamicMenusDelegate: self,
            saveWindowTarget: self,
            saveWindowAction: #selector(saveWindowLayout(_:)),
            currentLayout: settings.navigationLayout.rawValue,
            currentAppearance: settings.appearance.rawValue
        )
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = NSApp.mainMenu?.item(withTitle: "Help")?.submenu
    }

    /// Pure menu construction so tests can assert the exact edit/find wiring.
    /// SwiftTerm's `performFindPanelAction(_:)` requires NSMenuItem senders
    /// whose tags carry NSFindPanelAction raw values; anything else is ignored.
    static func makeMainMenu(
        updateTarget: AnyObject?,
        updateAction: Selector?,
        updateEnabled: Bool,
        updateDetail: String?,
        newWindowTarget: AnyObject? = nil,
        newWindowAction: Selector? = nil,
        openFolderTarget: AnyObject? = nil,
        openFolderAction: Selector? = nil,
        reopenClosedProjectTarget: AnyObject? = nil,
        reopenClosedProjectAction: Selector? = nil,
        reopenClosedSessionTarget: AnyObject? = nil,
        reopenClosedSessionAction: Selector? = nil,
        newTerminalTarget: AnyObject? = nil,
        newTerminalAction: Selector? = nil,
        newAgentTarget: AnyObject? = nil,
        newAgentAction: Selector? = nil,
        newChatTarget: AnyObject? = nil,
        newChatAction: Selector? = nil,
        viewTarget: AnyObject? = nil,
        layoutAction: Selector? = nil,
        appearanceAction: Selector? = nil,
        fontTarget: AnyObject? = nil,
        fontIncreaseAction: Selector? = nil,
        fontDecreaseAction: Selector? = nil,
        fontResetAction: Selector? = nil,
        dynamicMenusDelegate: NSMenuDelegate? = nil,
        saveWindowTarget: AnyObject? = nil,
        saveWindowAction: Selector? = nil,
        currentLayout: String = NavigationLayout.leftTree.rawValue,
        currentAppearance: String = AppearanceMode.system.rawValue
    ) -> NSMenu {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.title = "Kaisola Preview"
        mainMenu.addItem(applicationItem)

        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "About Kaisola Preview",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let updateItem = applicationMenu.addItem(
            withTitle: "Check for Updates…",
            action: updateAction,
            keyEquivalent: ""
        )
        updateItem.target = updateTarget
        updateItem.isEnabled = updateEnabled
        updateItem.toolTip = updateDetail
        applicationMenu.addItem(.separator())
        let settingsItem = applicationMenu.addItem(
            withTitle: "Settings…",
            action: #selector(KaisolaMacAppDelegate.openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = nil   // first responder → the app delegate
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Hide Kaisola Preview",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Quit Kaisola Preview",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu

        let fileItem = NSMenuItem()
        fileItem.title = "File"
        let fileMenu = NSMenu(title: "File")
        if let newWindowAction {
            let item = fileMenu.addItem(withTitle: "New Window", action: newWindowAction, keyEquivalent: "n")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = newWindowTarget
            fileMenu.addItem(.separator())
        }
        if let openFolderAction {
            let item = fileMenu.addItem(withTitle: "Open Folder…", action: openFolderAction, keyEquivalent: "o")
            item.target = openFolderTarget
        }
        if let dynamicMenusDelegate {
            let recentItem = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
            let recentMenu = NSMenu(title: "Open Recent")
            recentMenu.delegate = dynamicMenusDelegate
            recentItem.submenu = recentMenu
        }
        if let reopenClosedProjectAction {
            let item = fileMenu.addItem(withTitle: "Reopen Closed Project", action: reopenClosedProjectAction, keyEquivalent: "t")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = reopenClosedProjectTarget
        }
        if let reopenClosedSessionAction {
            let item = fileMenu.addItem(withTitle: "Reopen Closed Session", action: reopenClosedSessionAction, keyEquivalent: "t")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = reopenClosedSessionTarget
        }
        if openFolderAction != nil || reopenClosedProjectAction != nil || reopenClosedSessionAction != nil {
            fileMenu.addItem(.separator())
        }
        if let newChatAction {
            let chatItem = fileMenu.addItem(withTitle: "New Chat", action: nil, keyEquivalent: "")
            let chatMenu = NSMenu(title: "New Chat")
            for agent in AgentRegistry.all where AcpAdapter.forAgent(agent.id) != nil {
                let item = chatMenu.addItem(withTitle: "Chat with \(agent.name)", action: newChatAction, keyEquivalent: "")
                item.target = newChatTarget
                item.representedObject = agent.id
            }
            chatItem.submenu = chatMenu
            fileMenu.addItem(.separator())
        }
        let newTerminal = fileMenu.addItem(
            withTitle: "New Terminal Session…",
            action: newTerminalAction,
            keyEquivalent: "t"
        )
        newTerminal.target = newTerminalTarget
        if let newAgentAction {
            let agentItem = fileMenu.addItem(withTitle: "New Agent Session", action: nil, keyEquivalent: "")
            let agentMenu = NSMenu(title: "New Agent Session")
            for agent in AgentRegistry.all {
                let item = agentMenu.addItem(withTitle: agent.name, action: newAgentAction, keyEquivalent: "")
                item.target = newAgentTarget
                item.representedObject = agent.id
            }
            agentItem.submenu = agentMenu
        }
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())

        let findAction = #selector(NSTextView.performFindPanelAction(_:))
        let find = editMenu.addItem(withTitle: "Find…", action: findAction, keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let findNext = editMenu.addItem(withTitle: "Find Next", action: findAction, keyEquivalent: "g")
        findNext.tag = Int(NSFindPanelAction.next.rawValue)
        let findPrevious = editMenu.addItem(withTitle: "Find Previous", action: findAction, keyEquivalent: "G")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        findPrevious.tag = Int(NSFindPanelAction.previous.rawValue)
        let useSelection = editMenu.addItem(withTitle: "Use Selection for Find", action: findAction, keyEquivalent: "e")
        useSelection.tag = Int(NSFindPanelAction.setFindString.rawValue)

        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        if let layoutAction, let appearanceAction {
            let viewItem = NSMenuItem()
            viewItem.title = "View"
            let viewMenu = NSMenu(title: "View")
            viewMenu.addItem(sectionHeader("Navigation Layout"))
            for layout in NavigationLayout.allCases {
                let item = viewMenu.addItem(withTitle: layout.title, action: layoutAction, keyEquivalent: "")
                item.target = viewTarget
                item.representedObject = layout.rawValue
                item.state = layout.rawValue == currentLayout ? .on : .off
            }
            viewMenu.addItem(.separator())
            viewMenu.addItem(sectionHeader("Appearance"))
            for mode in AppearanceMode.allCases {
                let item = viewMenu.addItem(withTitle: mode.title, action: appearanceAction, keyEquivalent: "")
                item.target = viewTarget
                item.representedObject = mode.rawValue
                item.state = mode.rawValue == currentAppearance ? .on : .off
            }
            if let fontIncreaseAction, let fontDecreaseAction, let fontResetAction {
                viewMenu.addItem(.separator())
                viewMenu.addItem(sectionHeader("Terminal Font"))
                let bigger = viewMenu.addItem(withTitle: "Bigger", action: fontIncreaseAction, keyEquivalent: "+")
                bigger.target = fontTarget
                let smaller = viewMenu.addItem(withTitle: "Smaller", action: fontDecreaseAction, keyEquivalent: "-")
                smaller.target = fontTarget
                let reset = viewMenu.addItem(withTitle: "Reset Size", action: fontResetAction, keyEquivalent: "0")
                reset.target = fontTarget
            }
            viewItem.submenu = viewMenu
            mainMenu.addItem(viewItem)
        }

        // Standard Window menu (NSApp.windowsMenu appends the live window list).
        let windowItem = NSMenuItem()
        windowItem.title = "Window"
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        if let saveWindowAction {
            windowMenu.addItem(.separator())
            let save = windowMenu.addItem(withTitle: "Save Window Layout…", action: saveWindowAction, keyEquivalent: "")
            save.target = saveWindowTarget
            if let dynamicMenusDelegate {
                let savedItem = windowMenu.addItem(withTitle: "Saved Windows", action: nil, keyEquivalent: "")
                let savedMenu = NSMenu(title: "Saved Windows")
                savedMenu.delegate = dynamicMenusDelegate
                savedItem.submenu = savedMenu
            }
        }
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        // Help menu: the native preview's roadmap doubles as its manual.
        let helpItem = NSMenuItem()
        helpItem.title = "Help"
        let helpMenu = NSMenu(title: "Help")
        let help = helpMenu.addItem(withTitle: "Kaisola Preview Help", action: #selector(KaisolaMacAppDelegate.openHelp(_:)), keyEquivalent: "?")
        help.target = nil   // first responder → the app delegate
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        return mainMenu
    }

    @objc func openHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/michaelofengenden/kaisola/blob/main/docs/native-migration-roadmap.md") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
