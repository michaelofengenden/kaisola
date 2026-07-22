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

    private func installMainMenu() {
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
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        updateItem.isEnabled = updateController.availability.canCheck
        updateItem.toolTip = updateController.availability.detail
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

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}
