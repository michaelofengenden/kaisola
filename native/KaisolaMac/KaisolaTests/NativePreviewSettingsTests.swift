import AppKit
import XCTest
@testable import KaisolaMacPreview

/// The shell-spine settings: layout + appearance persist and drive the app,
/// and the View menu carries both toggle groups with the current selection
/// checked.
@MainActor
final class NativePreviewSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "kaisola-settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testLayoutAndAppearancePersist() {
        let defaults = makeDefaults()
        let settings = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(settings.navigationLayout, .leftTree)
        XCTAssertEqual(settings.appearance, .system)

        settings.navigationLayout = .topBar
        settings.appearance = .dark

        let reloaded = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(reloaded.navigationLayout, .topBar)
        XCTAssertEqual(reloaded.appearance, .dark)
    }

    func testAppearanceMapsToColorSchemeAndNSAppearance() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
    }

    func testFileMenuCarriesNewWindowWithShortcut() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            newWindowTarget: nil, newWindowAction: #selector(NSResponder.doCommand(by:))
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let newWindow = try XCTUnwrap(fileMenu.items.first { $0.title == "New Window" })
        XCTAssertEqual(newWindow.keyEquivalent, "n")
        XCTAssertEqual(newWindow.keyEquivalentModifierMask, [.command, .shift])
    }

    func testFileMenuCarriesOpenFolderWithShortcut() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            openFolderTarget: nil, openFolderAction: #selector(NSResponder.doCommand(by:))
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let openFolder = try XCTUnwrap(fileMenu.items.first { $0.title == "Open Folder…" })
        XCTAssertEqual(openFolder.keyEquivalent, "o")
        XCTAssertEqual(openFolder.keyEquivalentModifierMask, [.command])
    }

    func testFileMenuCarriesReopenClosedProjectWithShortcut() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            reopenClosedProjectTarget: nil, reopenClosedProjectAction: #selector(NSResponder.doCommand(by:))
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let reopen = try XCTUnwrap(fileMenu.items.first { $0.title == "Reopen Closed Project" })
        XCTAssertEqual(reopen.keyEquivalent, "t")
        XCTAssertEqual(reopen.keyEquivalentModifierMask, [.command, .shift])
    }

    func testMenuBarCarriesWindowAndHelpMenus() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil
        )
        let windowMenu = try XCTUnwrap(menu.item(withTitle: "Window")?.submenu)
        XCTAssertNotNil(windowMenu.items.first { $0.title == "Minimize" && $0.keyEquivalent == "m" })
        XCTAssertNotNil(windowMenu.items.first { $0.title == "Bring All to Front" })
        let helpMenu = try XCTUnwrap(menu.item(withTitle: "Help")?.submenu)
        XCTAssertNotNil(helpMenu.items.first { $0.title.contains("Help") })
    }

    func testFileMenuCarriesOpenRecentWhenDelegateProvided() throws {
        final class StubDelegate: NSObject, NSMenuDelegate {}
        let delegate = StubDelegate()
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            openFolderTarget: nil, openFolderAction: #selector(NSResponder.doCommand(by:)),
            dynamicMenusDelegate: delegate,
            saveWindowTarget: nil, saveWindowAction: #selector(NSResponder.doCommand(by:))
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let recent = try XCTUnwrap(fileMenu.items.first { $0.title == "Open Recent" })
        XCTAssertTrue(recent.submenu?.delegate === delegate)
        let windowMenu = try XCTUnwrap(menu.item(withTitle: "Window")?.submenu)
        XCTAssertNotNil(windowMenu.items.first { $0.title == "Save Window Layout…" })
        let saved = try XCTUnwrap(windowMenu.items.first { $0.title == "Saved Windows" })
        XCTAssertTrue(saved.submenu?.delegate === delegate)
    }

    func testViewMenuCarriesTerminalFontItems() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            viewTarget: nil,
            layoutAction: #selector(NSResponder.doCommand(by:)),
            appearanceAction: #selector(NSResponder.doCommand(by:)),
            fontTarget: nil,
            fontIncreaseAction: #selector(NSResponder.doCommand(by:)),
            fontDecreaseAction: #selector(NSResponder.doCommand(by:)),
            fontResetAction: #selector(NSResponder.doCommand(by:))
        )
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        XCTAssertNotNil(viewMenu.items.first { $0.title == "Bigger" && $0.keyEquivalent == "+" })
        XCTAssertNotNil(viewMenu.items.first { $0.title == "Smaller" && $0.keyEquivalent == "-" })
        XCTAssertNotNil(viewMenu.items.first { $0.title == "Reset Size" && $0.keyEquivalent == "0" })
    }

    @MainActor
    func testTerminalFontAdjustClampsToRange() {
        let suite = "kaisola-font-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = NativePreviewSettings(defaults: defaults)
        XCTAssertEqual(settings.terminalFontSize, NativePreviewSettings.terminalFontDefault)
        settings.adjustTerminalFont(by: 100)
        XCTAssertEqual(settings.terminalFontSize, NativePreviewSettings.terminalFontRange.upperBound)
        settings.adjustTerminalFont(by: -100)
        XCTAssertEqual(settings.terminalFontSize, NativePreviewSettings.terminalFontRange.lowerBound)
        settings.resetTerminalFont()
        XCTAssertEqual(settings.terminalFontSize, NativePreviewSettings.terminalFontDefault)
        defaults.removePersistentDomain(forName: suite)
    }

    func testViewMenuCarriesLayoutAndAppearanceToggles() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil, updateAction: nil, updateEnabled: false, updateDetail: nil,
            viewTarget: nil,
            layoutAction: #selector(NSResponder.doCommand(by:)),
            appearanceAction: #selector(NSResponder.doCommand(by:)),
            currentLayout: NavigationLayout.topBar.rawValue,
            currentAppearance: AppearanceMode.dark.rawValue
        )
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let items = viewMenu.items.compactMap { $0.representedObject as? String }
        XCTAssertTrue(items.contains(NavigationLayout.leftTree.rawValue))
        XCTAssertTrue(items.contains(NavigationLayout.topBar.rawValue))
        XCTAssertTrue(items.contains(AppearanceMode.light.rawValue))
        XCTAssertTrue(items.contains(AppearanceMode.dark.rawValue))

        // The current selections are checked.
        let topBarItem = try XCTUnwrap(viewMenu.items.first { ($0.representedObject as? String) == NavigationLayout.topBar.rawValue })
        XCTAssertEqual(topBarItem.state, .on)
        let darkItem = try XCTUnwrap(viewMenu.items.first { ($0.representedObject as? String) == AppearanceMode.dark.rawValue })
        XCTAssertEqual(darkItem.state, .on)
    }
}
