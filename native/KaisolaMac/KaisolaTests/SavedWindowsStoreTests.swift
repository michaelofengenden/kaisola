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

    // MARK: - Damaged and forward-version payloads

    /// One unreadable record used to take the whole catalog down with it, and
    /// the next save then overwrote the survivors.
    func testOneDamagedRecordDoesNotHideTheOtherSavedWindows() throws {
        defaults.set(Self.payload(records: [
            #"{"name":"Alpha","frame":"{{0, 0}, {900, 700}}","projectName":null}"#,
            #"{"name":"Broken"}"#,
            #"{"name":"Zulu","frame":"{{20, 20}, {900, 700}}","projectName":"Kaisola"}"#,
        ]), forKey: "savedWindows")

        XCTAssertEqual(store.all().map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(store.load().notice, .damagedRecords(count: 1))
    }

    func testSavingAfterDamageKeepsTheOriginalPayloadRecoverable() throws {
        let original = Self.payload(records: [
            #"{"name":"Alpha","frame":"{{0, 0}, {900, 700}}","projectName":null}"#,
            #"{"name":"Broken","frame":42}"#,
        ])
        defaults.set(original, forKey: "savedWindows")

        XCTAssertTrue(store.save(SavedWindowState(name: "Mid", frame: "{{5, 5}, {900, 700}}", projectName: nil)))
        XCTAssertEqual(store.all().map(\.name), ["Alpha", "Mid"])
        XCTAssertNil(store.load().notice)   // the damage is isolated, not carried forward
        let kept = try XCTUnwrap(store.preservedCopy())
        XCTAssertEqual(kept.payload, original)
        XCTAssertTrue(kept.text.contains("Broken"))
    }

    /// The pre-migration bare array is recoverable too: the rewrite that
    /// versions it is exactly the kind of change that needs a copy behind it.
    func testLegacyPayloadIsVersionedOnWriteAndKeptAside() throws {
        let legacy = Data(#"[{"name":"Legacy","frame":"{{0, 0}, {900, 700}}","projectName":"Kaisola"}]"#.utf8)
        defaults.set(legacy, forKey: "savedWindows")

        XCTAssertTrue(store.save(SavedWindowState(name: "New", frame: "{{9, 9}, {900, 700}}", projectName: nil)))
        XCTAssertEqual(store.all().map(\.name), ["Legacy", "New"])
        XCTAssertEqual(store.preservedCopy()?.payload, legacy)

        let stored = try XCTUnwrap(defaults.data(forKey: "savedWindows"))
        let versioned = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertEqual(versioned["version"] as? Int, SavedWindowsStore.schemaVersion)
        XCTAssertEqual((versioned["windows"] as? [[String: Any]])?.count, 2)
    }

    func testUnreadablePayloadWarnsInsteadOfLookingEmpty() throws {
        let garbage = Data("this is not the saved windows list".utf8)
        defaults.set(garbage, forKey: "savedWindows")

        XCTAssertEqual(store.load(), SavedWindowsCatalog(windows: [], notice: .unreadableCatalog))
        XCTAssertTrue(store.save(SavedWindowState(name: "Fresh", frame: "{{0, 0}, {900, 700}}", projectName: nil)))
        XCTAssertEqual(store.preservedCopy()?.payload, garbage)
    }

    /// Data from a newer Kaisola stays byte-for-byte where that build left it:
    /// re-encoding it here would drop whatever the newer format added.
    func testForwardVersionDataIsListedButNeverRewritten() throws {
        let forward = Data(#"""
        {"version":99,"windows":[
          {"name":"Future","frame":"{{0, 0}, {900, 700}}","projectName":null,"spaces":[1,2]},
          {"name":"Alien","frame":{"x":0}}
        ],"workspaces":[]}
        """#.utf8)
        defaults.set(forward, forKey: "savedWindows")

        let catalog = store.load()
        XCTAssertEqual(catalog.windows.map(\.name), ["Future"])
        XCTAssertEqual(catalog.notice, .newerVersionData(schemaVersion: 99))
        XCTAssertEqual(catalog.notice?.blocksWrites, true)

        XCTAssertFalse(store.save(SavedWindowState(name: "Mine", frame: "{{0, 0}, {900, 700}}", projectName: nil)))
        XCTAssertFalse(store.remove(name: "Future"))
        XCTAssertEqual(defaults.data(forKey: "savedWindows"), forward)
    }

    func testHealthyCatalogKeepsNoCopyAndRaisesNoNotice() {
        store.save(SavedWindowState(name: "Alpha", frame: "{{0, 0}, {900, 700}}", projectName: nil))
        store.save(SavedWindowState(name: "Beta", frame: "{{0, 0}, {900, 700}}", projectName: nil))
        store.remove(name: "Alpha")

        XCTAssertEqual(store.load(), SavedWindowsCatalog(windows: [
            SavedWindowState(name: "Beta", frame: "{{0, 0}, {900, 700}}", projectName: nil),
        ], notice: nil))
        XCTAssertNil(store.preservedCopy())
    }

    /// A current-version payload built from raw record JSON, so a test can pin
    /// exactly which record is damaged.
    private static func payload(records: [String]) -> Data {
        Data(#"{"version":\#(SavedWindowsStore.schemaVersion),"windows":[\#(records.joined(separator: ","))]}"#.utf8)
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
