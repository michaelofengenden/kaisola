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
    private let updateController = NativeUpdateController()
    private var window: NSWindow?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Preview-owned state stays separate from every historical Electron
        // profile. Broker discovery is explicitly read-only and lives elsewhere.
        try? NativePreviewPaths.prepareApplicationSupport()
        installMainMenu()
        let content = RootShellView()
            .environmentObject(model)

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

    private func installMainMenu() {
        NSApp.mainMenu = Self.makeMainMenu(
            updateTarget: self,
            updateAction: #selector(checkForUpdates(_:)),
            updateEnabled: updateController.availability.canCheck,
            updateDetail: updateController.availability.detail,
            newTerminalTarget: self,
            newTerminalAction: #selector(newTerminalSession(_:)),
            newAgentTarget: self,
            newAgentAction: #selector(newAgentSession(_:))
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
        newAgentAction: Selector? = nil
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
        return mainMenu
    }
}
