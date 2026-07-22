import AppKit
import SwiftUI

@main
@MainActor
enum KaisolaMacMain {
    private static let appDelegate = KaisolaMacAppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = appDelegate
        application.run()
    }
}

@MainActor
final class KaisolaMacAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var window: NSWindow?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Preview-owned state stays separate from every historical Electron
        // profile. Broker discovery is explicitly read-only and lives elsewhere.
        try? NativePreviewPaths.prepareApplicationSupport()
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
}
