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
final class KaisolaMacAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = NativePreviewSettings.shared
    private let updateController = NativeUpdateController()
    // Each window is an independent workspace with its own AppModel and broker
    // observer connection — the broker's coexistence contract makes concurrent
    // observers safe. Keyed by the NSWindow so menu actions target the key one.
    private var windowModels: [ObjectIdentifier: AppModel] = [:]
    private var windowCounter = 0
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Preview-owned state stays separate from every historical Electron
        // profile. Broker discovery is explicitly read-only and lives elsewhere.
        try? NativePreviewPaths.prepareApplicationSupport()
        settings.applyAppearance()
        installMainMenu()
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
        window.title = "Kaisola Native Preview"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
        Task { await model.reload() }
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
        wakeObserver = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let model = windowModels.removeValue(forKey: ObjectIdentifier(window)) else { return }
        Task { await model.disconnect() }
    }

    @objc private func newWindow(_ sender: Any?) {
        makeWindow()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates(sender)
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
            newTerminalTarget: self,
            newTerminalAction: #selector(newTerminalSession(_:)),
            newAgentTarget: self,
            newAgentAction: #selector(newAgentSession(_:)),
            newChatTarget: self,
            newChatAction: #selector(newChatSession(_:)),
            viewTarget: self,
            layoutAction: #selector(setNavigationLayout(_:)),
            appearanceAction: #selector(setAppearanceMode(_:)),
            currentLayout: settings.navigationLayout.rawValue,
            currentAppearance: settings.appearance.rawValue
        )
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
        newTerminalTarget: AnyObject? = nil,
        newTerminalAction: Selector? = nil,
        newAgentTarget: AnyObject? = nil,
        newAgentAction: Selector? = nil,
        newChatTarget: AnyObject? = nil,
        newChatAction: Selector? = nil,
        viewTarget: AnyObject? = nil,
        layoutAction: Selector? = nil,
        appearanceAction: Selector? = nil,
        currentLayout: String = NavigationLayout.leftTree.rawValue,
        currentAppearance: String = AppearanceMode.system.rawValue
    ) -> NSMenu {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)

        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "About Kaisola Native Preview",
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
        applicationMenu.addItem(
            withTitle: "Hide Kaisola Native Preview",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Quit Kaisola Native Preview",
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
            viewItem.submenu = viewMenu
            mainMenu.addItem(viewItem)
        }
        return mainMenu
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
