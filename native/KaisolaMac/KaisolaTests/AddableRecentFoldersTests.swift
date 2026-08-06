import Foundation
import XCTest
@testable import Kaisola

/// The ghost row's recent-folders menu: only real directories, never a
/// project that is already open, no duplicates, capped.
final class AddableRecentFoldersTests: XCTestCase {
    func testFiltersOpenProjectsMissingDirectoriesAndDuplicates() {
        let recent = [
            "/tmp/alpha",
            "/tmp/already-open",
            "/tmp/deleted",
            "/tmp/alpha/",
            "/tmp/beta",
        ]
        let result = AddableRecentFolders.compute(
            recent: recent,
            openProjectPaths: ["/tmp/already-open"],
            isDirectory: { $0.path != "/tmp/deleted" }
        )
        XCTAssertEqual(result.map(\.path), ["/tmp/alpha", "/tmp/beta"])
    }

    func testCapsTheMenuAndKeepsRecencyOrder() {
        let recent = (0..<20).map { "/tmp/folder-\($0)" }
        let result = AddableRecentFolders.compute(
            recent: recent,
            openProjectPaths: [],
            isDirectory: { _ in true }
        )
        XCTAssertEqual(result.count, AddableRecentFolders.limit)
        XCTAssertEqual(result.first?.path, "/tmp/folder-0")
        XCTAssertEqual(result.last?.path, "/tmp/folder-\(AddableRecentFolders.limit - 1)")
    }

    func testEmptyRecentsProduceAnEmptyMenu() {
        XCTAssertEqual(
            AddableRecentFolders.compute(
                recent: [],
                openProjectPaths: [],
                isDirectory: { _ in true }
            ),
            []
        )
    }
}
