import AppKit
import XCTest
@testable import Kaisola

@MainActor
final class CommandRegistryTests: XCTestCase {
    /// XCTest invokes lifecycle overrides outside the class's MainActor even
    /// though every test method is isolated there. The runner serializes this
    /// instance, so this one fixture URL is safe to bridge across that boundary.
    nonisolated(unsafe) private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testShortcutParserNormalizesOneContractForAppKitAndSwiftUI() throws {
        let shortcut = try XCTUnwrap(AppCommandShortcut(specification: " Shift + Command + B "))

        XCTAssertEqual(shortcut.specification, "command+shift+b")
        XCTAssertEqual(shortcut.display, "⇧⌘B")
        XCTAssertEqual(shortcut.appKitKeyEquivalent, "b")
        XCTAssertEqual(shortcut.appKitModifiers, [.command, .shift])
        XCTAssertEqual(shortcut.swiftUIKeyEquivalent, .init("b"))
        XCTAssertEqual(shortcut.swiftUIModifiers, [.command, .shift])
    }

    func testShortcutParserRejectsTypingTheftAndAmbiguousSpecifications() {
        XCTAssertNil(AppCommandShortcut(specification: "b"))
        XCTAssertNil(AppCommandShortcut(specification: "shift+b"))
        XCTAssertNil(AppCommandShortcut(specification: "command+command+b"))
        XCTAssertNil(AppCommandShortcut(specification: "command+b+c"))
        XCTAssertNil(AppCommandShortcut(specification: "command+f12"))
    }

    func testRegistryIDsAndBuiltInShortcutsAreConflictFree() {
        let definitions = AppCommandRegistry.definitions
        XCTAssertEqual(Set(definitions.map(\.id)).count, definitions.count)
        XCTAssertTrue(AppCommandRegistry.paletteDefinitions.contains { $0.id == .openSettings })
        XCTAssertTrue(AppCommandRegistry.paletteDefinitions.contains { $0.id == .newMesh })
        XCTAssertTrue(AppCommandRegistry.paletteDefinitions.contains { $0.id == .increaseTerminalFont })

        let defaults = AppCommandKeymapStore.defaultShortcuts(
            definitions: AppCommandRegistry.keymapDefinitions
        )
        XCTAssertTrue(
            AppCommandKeymapStore.conflicts(
                in: defaults,
                definitions: AppCommandRegistry.keymapDefinitions
            ).isEmpty
        )
    }

    func testReadinessChecklistCommandIsPaletteOnlyAndMapsToPresentation() throws {
        let definition = try XCTUnwrap(
            AppCommandRegistry.definition(for: .readinessChecklist)
        )

        XCTAssertEqual(definition.title, "Readiness Checklist…")
        XCTAssertEqual(definition.category, .help)
        XCTAssertEqual(definition.systemImage, "checklist.checked")
        XCTAssertEqual(definition.surfaces, [.palette])
        XCTAssertNil(definition.defaultShortcut)
        XCTAssertTrue(
            AppCommandRegistry.paletteDefinitions.contains { $0.id == .readinessChecklist }
        )
        XCTAssertFalse(
            AppCommandRegistry.keymapDefinitions.contains { $0.id == .readinessChecklist }
        )
        XCTAssertEqual(
            RootShellLocalCommand(commandID: .readinessChecklist),
            .presentReadinessChecklist
        )
    }

    func testReadinessChecklistCommandTargetsExactWindowAndPreservesReadiness() throws {
        let sessionStore = NativeSessionStore(
            fileURL: temporaryDirectory.appendingPathComponent("native-sessions.json")
        )
        let model = AppModel(
            brokerPreparer: BrokerFreeFixturePreparer(),
            sessionStore: sessionStore,
            workspaceStateStore: NativeWorkspaceStateStore(
                fileURL: temporaryDirectory.appendingPathComponent("workspace-state.json")
            )
        )
        let defaultsSuite = "kaisola-readiness-command-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        OnboardingState.markSeen(defaults: defaults)
        let projectStatusBefore = OnboardingReadiness.project(
            directory: model.currentProjectDirectory
        )
        let terminalStatusBefore = OnboardingReadiness.terminalService(
            connectionState: model.connectionState,
            controlAvailable: model.controlAvailable
        )
        let routed = expectation(
            forNotification: .kaisolaLocalCommand,
            object: model
        ) { note in
            note.userInfo?[AppCommandNotificationKey.commandID] as? String
                == AppCommandID.readinessChecklist.rawValue
        }

        XCTAssertTrue(
            AppCommandRegistry.execute(
                .readinessChecklist,
                in: AppCommandContext(model: model)
            )
        )
        wait(for: [routed], timeout: 1)

        XCTAssertFalse(
            OnboardingState.shouldShow(defaults: defaults),
            "manual reopen must not reset the persisted first-run gate"
        )
        XCTAssertEqual(
            OnboardingReadiness.project(directory: model.currentProjectDirectory),
            projectStatusBefore
        )
        XCTAssertEqual(
            OnboardingReadiness.terminalService(
                connectionState: model.connectionState,
                controlAvailable: model.controlAvailable
            ),
            terminalStatusBefore,
            "presenting the checklist must not mutate the live readiness inputs"
        )
    }

    func testPaletteSelectionIdentityFollowsFilteredItemInsteadOfReusedIndex() {
        let original = PaletteItem(
            id: "command.session.new-terminal",
            title: "New Terminal Session",
            subtitle: "Session",
            systemImage: "terminal"
        ) {}
        let filtered = PaletteItem(
            id: "command.app.readiness-checklist",
            title: "Readiness Checklist…",
            subtitle: "Help",
            systemImage: "checklist.checked"
        ) {}

        XCTAssertEqual(
            CommandPaletteResultIdentity.itemID(at: 0, in: [original]),
            original.id
        )
        XCTAssertEqual(
            CommandPaletteResultIdentity.itemID(at: 0, in: [filtered]),
            filtered.id,
            "result identity must change when filtering replaces index zero"
        )
        XCTAssertNotEqual(original.id, filtered.id)
        XCTAssertNil(CommandPaletteResultIdentity.itemID(at: 1, in: [filtered]))
    }

    func testDynamicIdentifiersRoundTripTheirTypedPayloads() {
        XCTAssertEqual(AppCommandID.newAgent("codex").agentID, "codex")
        XCTAssertEqual(AppCommandID.newChat("claude").chatAgentID, "claude")
        XCTAssertEqual(AppCommandID.navigationLayout(.topBar).navigationLayout, .topBar)
        XCTAssertEqual(AppCommandID.appearance(.dark).appearance, .dark)
        XCTAssertNil(AppCommandID(rawValue: "session.new-agent.").agentID)
    }

    func testMenuKeepsStandardContextualCloseAndExplicitProjectWindowClose() throws {
        let action = #selector(NSResponder.doCommand(by:))
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil,
            updateAction: nil,
            updateEnabled: false,
            updateDetail: nil,
            commandTarget: nil,
            commandAction: action
        )
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let contextual = try XCTUnwrap(fileMenu.items.first {
            ($0.representedObject as? String) == AppCommandID.closeContext.rawValue
        })
        XCTAssertEqual(contextual.title, "Close File Tab")
        XCTAssertEqual(contextual.keyEquivalent, "w")
        XCTAssertEqual(contextual.keyEquivalentModifierMask, [.command])

        let projectWindow = try XCTUnwrap(fileMenu.items.first {
            ($0.representedObject as? String) == AppCommandID.closeWindow.rawValue
        })
        XCTAssertEqual(projectWindow.title, "Close Project Window")
        XCTAssertEqual(projectWindow.keyEquivalent, "w")
        XCTAssertEqual(projectWindow.keyEquivalentModifierMask, [.command, .shift])
    }

    func testMissingKeymapUsesDefaults() throws {
        let store = AppCommandKeymapStore(fileURL: keymapURL)
        let snapshot = store.load(definitions: AppCommandRegistry.keymapDefinitions)

        XCTAssertEqual(snapshot.status, .defaults)
        XCTAssertFalse(snapshot.fileExists)
        XCTAssertEqual(snapshot.shortcut(for: .toggleFiles)?.specification, "command+b")
    }

    func testValidOverrideFeedsMenuAndPaletteHintFromTheSameSnapshot() throws {
        try writeKeymap("""
        {
          "version": 1,
          "bindings": {
            "view.toggle-files": "command+option+g"
          }
        }
        """)
        let store = AppCommandKeymapStore(fileURL: keymapURL)
        let snapshot = store.load(definitions: AppCommandRegistry.keymapDefinitions)
        let shortcut = try XCTUnwrap(snapshot.shortcut(for: .toggleFiles))

        XCTAssertEqual(snapshot.status, .loaded(overrideCount: 1))
        XCTAssertEqual(shortcut.specification, "command+option+g")
        XCTAssertEqual(shortcut.display, "⌥⌘G")

        let action = #selector(NSResponder.doCommand(by:))
        let menu = KaisolaMacAppDelegate.makeMainMenu(
            updateTarget: nil,
            updateAction: nil,
            updateEnabled: false,
            updateDetail: nil,
            commandTarget: nil,
            commandAction: action,
            keymap: snapshot,
            layoutAction: action,
            appearanceAction: action
        )
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let item = try XCTUnwrap(viewMenu.items.first {
            ($0.representedObject as? String) == AppCommandID.toggleFiles.rawValue
        })
        XCTAssertEqual(item.keyEquivalent, shortcut.appKitKeyEquivalent)
        XCTAssertEqual(item.keyEquivalentModifierMask, shortcut.appKitModifiers)
    }

    func testUnknownMalformedConflictingAndReservedOverridesFailClosed() throws {
        let cases: [(String, String)] = [
            ("{ definitely not json", "versioned JSON"),
            ("""
            {"version":1,"bindings":{"unknown.command":"command+u"}}
            """, "Unknown command id"),
            ("""
            {"version":1,"bindings":{"view.toggle-files":"command+t"}}
            """, "is assigned to"),
            ("""
            {"version":1,"bindings":{"view.toggle-files":"command+c"}}
            """, "Copy"),
        ]

        for (contents, expectedIssue) in cases {
            try writeKeymap(contents)
            let snapshot = AppCommandKeymapStore(fileURL: keymapURL)
                .load(definitions: AppCommandRegistry.keymapDefinitions)
            guard case let .invalid(issues) = snapshot.status else {
                return XCTFail("Expected invalid keymap for \(contents)")
            }
            XCTAssertTrue(issues.joined(separator: "\n").contains(expectedIssue))
            XCTAssertEqual(
                snapshot.shortcut(for: .toggleFiles)?.specification,
                "command+b",
                "A bad file must preserve every built-in default"
            )
        }
    }

    func testTemplateIsPrivateRoundTripsAndResetRestoresMissingFileDefaults() throws {
        let store = AppCommandKeymapStore(fileURL: keymapURL)
        try store.writeTemplate(definitions: AppCommandRegistry.keymapDefinitions)

        let attributes = try FileManager.default.attributesOfItem(atPath: keymapURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let loaded = store.load(definitions: AppCommandRegistry.keymapDefinitions)
        XCTAssertTrue(loaded.fileExists)
        XCTAssertTrue(loaded.issues.isEmpty)

        try store.reset()
        let reset = store.load(definitions: AppCommandRegistry.keymapDefinitions)
        XCTAssertEqual(reset.status, .defaults)
        XCTAssertFalse(reset.fileExists)
    }

    private var keymapURL: URL {
        temporaryDirectory.appendingPathComponent("keymap.json", isDirectory: false)
    }

    private func writeKeymap(_ contents: String) throws {
        try Data(contents.utf8).write(to: keymapURL, options: .atomic)
    }
}
