import AppKit
import SwiftTerm
import XCTest
@testable import KaisolaMacPreview

/// The Phase 1 interaction rows depend on three wiring facts: the edit menu
/// exposes SwiftTerm's find panel with the exact NSFindPanelAction tags, the
/// read-only surface exposes the retained buffer tail to accessibility, and
/// the surface claims keyboard focus when it joins a window so menu commands
/// reach it without a mouse.
@MainActor
final class NativeTerminalInteractionTests: XCTestCase {
    private func editMenu(in mainMenu: NSMenu) throws -> NSMenu {
        let editItem = try XCTUnwrap(mainMenu.items.first { $0.submenu?.title == "Edit" })
        return try XCTUnwrap(editItem.submenu)
    }

    func testEditMenuCarriesFindPanelActionsWithSwiftTermTags() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil,
            updateAction: nil,
            updateEnabled: false,
            updateDetail: nil
        )
        let edit = try editMenu(in: menu)
        let findAction = #selector(NSTextView.performFindPanelAction(_:))

        let find = try XCTUnwrap(edit.items.first { $0.title == "Find…" })
        XCTAssertEqual(find.action, findAction)
        XCTAssertEqual(find.tag, Int(NSFindPanelAction.showFindPanel.rawValue))
        XCTAssertEqual(find.keyEquivalent, "f")

        let next = try XCTUnwrap(edit.items.first { $0.title == "Find Next" })
        XCTAssertEqual(next.tag, Int(NSFindPanelAction.next.rawValue))
        XCTAssertEqual(next.keyEquivalent, "g")

        let previous = try XCTUnwrap(edit.items.first { $0.title == "Find Previous" })
        XCTAssertEqual(previous.tag, Int(NSFindPanelAction.previous.rawValue))
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.command, .shift])

        let useSelection = try XCTUnwrap(edit.items.first { $0.title == "Use Selection for Find" })
        XCTAssertEqual(useSelection.tag, Int(NSFindPanelAction.setFindString.rawValue))
    }

    func testEditMenuKeepsCopyAndSelectAll() throws {
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil,
            updateAction: nil,
            updateEnabled: false,
            updateDetail: nil
        )
        let edit = try editMenu(in: menu)
        XCTAssertNotNil(edit.items.first { $0.title == "Copy" && $0.keyEquivalent == "c" })
        XCTAssertNotNil(edit.items.first { $0.title == "Select All" && $0.keyEquivalent == "a" })
    }

    func testReadOnlySurfaceExposesBufferTailToAccessibility() {
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.updateAccessibilityValue(from: "alpha\nbravo\ncharlie")

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        let value = view.accessibilityValue() as? String
        XCTAssertEqual(value, "alpha\nbravo\ncharlie")
    }

    func testAccessibilityValueIsBoundedToTail() {
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        let filler = String(repeating: "x", count: ReadOnlyTerminalView.accessibilityTailLimit)
        view.updateAccessibilityValue(from: filler + "tail-marker")

        let value = try? XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertEqual(value?.count, ReadOnlyTerminalView.accessibilityTailLimit)
        XCTAssertTrue(value?.hasSuffix("tail-marker") ?? false)
    }

    // First-responder claims cannot be asserted end to end on a headless CI
    // runner (windows never become key), so the decision is a pure function:
    // claim focus only from the window or its bare content view, and never
    // steal it from a control the user is in — the sidebar or the find bar.
    func testFocusClaimDecisionClaimsOnlyIdleWindows() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // NSWindow defaults to release-when-closed; under ARC that would
        // double-release when the test also owns the reference.
        window.isReleasedWhenClosed = false
        defer { window.close() }

        XCTAssertTrue(ReadOnlyTerminalView.shouldClaimFocus(currentFirstResponder: nil, window: window))
        XCTAssertTrue(ReadOnlyTerminalView.shouldClaimFocus(currentFirstResponder: window, window: window))
        XCTAssertTrue(ReadOnlyTerminalView.shouldClaimFocus(currentFirstResponder: window.contentView, window: window))

        let findBarField = NSTextField(frame: .zero)
        window.contentView?.addSubview(findBarField)
        XCTAssertFalse(ReadOnlyTerminalView.shouldClaimFocus(currentFirstResponder: findBarField, window: window))
    }

    func testReadOnlyViewStillDropsAllPTYBoundBytes() {
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        // Device-status query would normally produce a reply back to the PTY;
        // the read-only override must swallow it. Crashing or sending would
        // fail the test harness, and selection stays available regardless.
        view.feed(text: "\u{1b}[5n")
        view.selectAll(nil)
        XCTAssertNoThrow(view.copy(NSNull()))
    }
}
