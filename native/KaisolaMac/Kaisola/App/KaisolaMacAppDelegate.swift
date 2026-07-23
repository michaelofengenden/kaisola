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
    private let model = AppModel()
    private let settings = NativePreviewSettings.shared
    private let updateController = NativeUpdateController()
    private var window: NSWindow?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Preview-owned state stays separate from every historical Electron
        // profile. Broker discovery is explicitly read-only and lives elsewhere.
        try? NativePreviewPaths.prepareApplicationSupport()
        settings.applyAppearance()
        installMainMenu()
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
        window.center()
        window.setFrameAutosaveName("KaisolaNativePreview.MainWindow")
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.model.recoverAfterWake() }
        }

        Task { await model.reload() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.resumeIfNeeded()
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
        Task { await model.disconnect() }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates(sender)
    }

    @objc private func newTerminalSession(_ sender: Any?) {
        RootShellView.promptForNewTerminal(model: model)
    }

    @objc private func newAgentSession(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let agent = AgentRegistry.profile(id: item.representedObject as? String ?? "") else { return }
        RootShellView.promptForNewAgent(agent, model: model)
    }

    @objc private func newChatSession(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
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
        let fileMenu = NSMenu(title: "File")
        if let newChatAction {
            let chatItem = fileMenu.addItem(withTitle: "New Chat", action: nil, keyEquivalent: "n")
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
