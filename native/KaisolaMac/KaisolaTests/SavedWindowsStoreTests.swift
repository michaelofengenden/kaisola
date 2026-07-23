import Foundation
import XCTest
@testable import KaisolaMacPreview

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
        store.save(SavedWindowState(name: "Deep Work", frame: "{{100, 100}, {1200, 800}}", projectName: "Kaisola"))
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
}
