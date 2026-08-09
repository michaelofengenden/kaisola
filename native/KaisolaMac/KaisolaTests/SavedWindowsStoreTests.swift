import AppKit
import Foundation
import XCTest
@testable import Kaisola

/// SavedWindowsStore persistence: named window states with replace-on-save.
final class SavedWindowsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SavedWindowsStore!
    private let suite = "kaisola-saved-windows-tests"

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        store = SavedWindowsStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testSaveListRemove() {
        store.save(SavedWindowState(
            name: "Deep Work",
            frame: "{{100, 100}, {1200, 800}}",
            projectName: "Kaisola",
            projectPath: "/tmp/Kaisola"
        ))
        store.save(SavedWindowState(name: "Alpha", frame: "{{0, 0}, {900, 700}}", projectName: nil))
        XCTAssertEqual(store.all().map(\.name), ["Alpha", "Deep Work"])   // sorted
        store.remove(name: "Alpha")
        XCTAssertEqual(store.all().map(\.name), ["Deep Work"])
    }

    func testSaveUnderSameNameReplaces() {
        store.save(SavedWindowState(name: "Main", frame: "{{0, 0}, {900, 700}}", projectName: nil))
        store.save(SavedWindowState(name: "Main", frame: "{{50, 50}, {1000, 750}}", projectName: "Kaisola"))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.frame, "{{50, 50}, {1000, 750}}")
        XCTAssertEqual(store.all().first?.projectName, "Kaisola")
    }

    func testLegacyRecordWithoutProjectPathStillDecodes() throws {
        let data = Data(#"[{"name":"Legacy","frame":"{{0, 0}, {900, 700}}","projectName":"Kaisola"}]"#.utf8)
        defaults.set(data, forKey: "savedWindows")

        XCTAssertEqual(store.all(), [SavedWindowState(
            name: "Legacy",
            frame: "{{0, 0}, {900, 700}}",
            projectName: "Kaisola"
        )])
    }

    func testBadLegacyRecordKeepsGoodRecordsAndOriginalRecoveryCopy() throws {
        let data = Data(#"""
        [
          {"name":"Alpha","frame":"{{0, 0}, {900, 700}}","projectName":null},
          {"name":42,"frame":"not a frame","projectName":null},
          {"name":"Zulu","frame":"{{50, 50}, {1000, 750}}","projectName":"Kaisola"}
        ]
        """#.utf8)
        defaults.set(data, forKey: "savedWindows")

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.states.map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(snapshot.recovery, .malformedRecords(count: 1))
        XCTAssertEqual(defaults.data(forKey: "savedWindows.recovery"), data)
    }

    func testLegacyReadMigratesToVersionedPayloadAfterKeepingOriginalBytes() throws {
        let data = Data(#"[{"name":"Legacy","frame":"{{0, 0}, {900, 700}}","projectName":null}]"#.utf8)
        defaults.set(data, forKey: "savedWindows")

        XCTAssertEqual(store.all().map(\.name), ["Legacy"])
        XCTAssertEqual(defaults.data(forKey: "savedWindows.recovery"), data)

        let migrated = try XCTUnwrap(defaults.data(forKey: "savedWindows"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["records"] as? [[String: Any]])?.count, 1)
    }

    func testSaveAfterBadLegacyRecordPreservesGoodRecordsAndVersionsPayload() throws {
        let data = Data(#"""
        [
          {"name":"Alpha","frame":"{{0, 0}, {900, 700}}","projectName":null},
          {"name":false,"frame":"broken","projectName":null},
          {"name":"Zulu","frame":"{{50, 50}, {1000, 750}}","projectName":"Kaisola"}
        ]
        """#.utf8)
        defaults.set(data, forKey: "savedWindows")

        store.save(SavedWindowState(
            name: "Middle",
            frame: "{{25, 25}, {950, 725}}",
            projectName: nil
        ))

        XCTAssertEqual(store.all().map(\.name), ["Alpha", "Middle", "Zulu"])
        XCTAssertEqual(defaults.data(forKey: "savedWindows.recovery"), data)
        let persisted = try XCTUnwrap(defaults.data(forKey: "savedWindows"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persisted) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["records"] as? [[String: Any]])?.count, 3)
    }

    func testForwardVersionCannotBeOverwrittenBySaveOrRemove() throws {
        let data = Data(#"""
        {
          "schemaVersion":999,
          "records":[{"name":"Future","frame":"{{0, 0}, {900, 700}}","projectName":null}]
        }
        """#.utf8)
        defaults.set(data, forKey: "savedWindows")

        let saveResult = store.save(SavedWindowState(
            name: "Current",
            frame: "{{50, 50}, {1000, 750}}",
            projectName: nil
        ))
        XCTAssertEqual(saveResult, .blocked(.newerSchema(found: 999)))
        XCTAssertEqual(defaults.data(forKey: "savedWindows"), data)

        let removeResult = store.remove(name: "Future")
        XCTAssertEqual(removeResult, .blocked(.newerSchema(found: 999)))
        XCTAssertEqual(defaults.data(forKey: "savedWindows"), data)
        XCTAssertEqual(defaults.data(forKey: "savedWindows.recovery"), data)
    }

    func testVersionedArchiveDecodesRecordsIndependently() throws {
        let data = Data(#"""
        {
          "schemaVersion":1,
          "records":[
            {"name":"Alpha","frame":"{{0, 0}, {900, 700}}","projectName":null},
            {"frame":"missing name","projectName":null},
            {"name":"Zulu","frame":"{{50, 50}, {1000, 750}}","projectName":"Kaisola"}
          ]
        }
        """#.utf8)
        defaults.set(data, forKey: "savedWindows")

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.states.map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(snapshot.recovery, .malformedRecords(count: 1))
        XCTAssertEqual(defaults.data(forKey: "savedWindows.recovery"), data)
    }

    func testMalformedArchiveIsBackedUpBeforeStartingFreshCatalog() throws {
        let data = Data([0xFF, 0x00, 0x7B])
        defaults.set(data, forKey: "savedWindows")

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot, .init(states: [], recovery: .malformedArchive))
        XCTAssertEqual(defaults.data(forKey: "savedWindows.recovery"), data)
        XCTAssertEqual(
            store.save(SavedWindowState(
                name: "Fresh",
                frame: "{{0, 0}, {900, 700}}",
                projectName: nil
            )),
            .persisted
        )
        XCTAssertEqual(store.snapshot().states.map(\.name), ["Fresh"])
        XCTAssertEqual(store.snapshot().recovery, .malformedArchive)
    }

    @MainActor
    func testRecoveryMenuWarningIsActionableAndKeepsGoodRecordsVisible() throws {
        let recovery = SavedWindowsStore.RecoveryIssue.malformedRecords(count: 1)
        let snapshot = SavedWindowsStore.Snapshot(
            states: [
                SavedWindowState(
                    name: "Alpha",
                    frame: "{{0, 0}, {900, 700}}",
                    projectName: nil
                ),
                SavedWindowState(
                    name: "Zulu",
                    frame: "{{50, 50}, {1000, 750}}",
                    projectName: "Kaisola"
                )
            ],
            recovery: recovery
        )
        let menu = NSMenu(title: "Saved Windows")
        let action = #selector(NSResponder.doCommand(by:))

        KaisolaMacAppDelegate.populateSavedWindowsMenu(
            menu,
            snapshot: snapshot,
            target: nil,
            openAction: action,
            deleteAction: action,
            recoveryAction: action
        )

        let warning = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(warning.title, "Review 1 Unreadable Saved Window…")
        XCTAssertEqual(warning.action, action)
        XCTAssertEqual(warning.toolTip, recovery.message)
        XCTAssertNotNil(warning.image)
        XCTAssertNotNil(menu.item(withTitle: "Alpha"))
        XCTAssertNotNil(menu.item(withTitle: "Zulu"))
        XCTAssertNil(menu.item(withTitle: "No Saved Windows"))
        let deleteMenu = try XCTUnwrap(menu.item(withTitle: "Delete Saved Window")?.submenu)
        XCTAssertEqual(deleteMenu.items.map(\.title), ["Alpha", "Zulu"])
    }

    @MainActor
    func testForwardVersionMenuExplainsWhyCatalogIsUnavailable() throws {
        let recovery = SavedWindowsStore.RecoveryIssue.newerSchema(found: 9)
        let menu = NSMenu(title: "Saved Windows")
        let action = #selector(NSResponder.doCommand(by:))

        KaisolaMacAppDelegate.populateSavedWindowsMenu(
            menu,
            snapshot: .init(states: [], recovery: recovery),
            target: nil,
            openAction: action,
            deleteAction: action,
            recoveryAction: action
        )

        XCTAssertEqual(menu.items.first?.title, "Saved Windows Require a Newer Kaisola…")
        XCTAssertNotNil(menu.items.first?.action)
        XCTAssertNotNil(menu.item(withTitle: "Saved Windows Unavailable in This Version"))
        XCTAssertNil(menu.item(withTitle: "No Saved Windows"))
    }

    func testProjectDirectoryRequiresAnExistingAbsoluteDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-saved-window-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            SavedWindowState(
                name: "Real",
                frame: "{{0, 0}, {900, 700}}",
                projectName: "Project",
                projectPath: directory.path
            ).projectDirectory(),
            directory.standardizedFileURL
        )
        XCTAssertNil(SavedWindowState(
            name: "Relative",
            frame: "{{0, 0}, {900, 700}}",
            projectName: "Project",
            projectPath: "relative/project"
        ).projectDirectory())
        XCTAssertNil(SavedWindowState(
            name: "Missing",
            frame: "{{0, 0}, {900, 700}}",
            projectName: "Project",
            projectPath: directory.appendingPathComponent("missing").path
        ).projectDirectory())
    }
}
