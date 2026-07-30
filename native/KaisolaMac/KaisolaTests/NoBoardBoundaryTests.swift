import Foundation
import XCTest

final class NoBoardBoundaryTests: XCTestCase {
    func testNativeMacSourceCannotReferenceRetiredBoardDTOs() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Kaisola", isDirectory: true)
        let forbidden = [
            "CompanionBoard",
            "CompanionBoardCard",
            "CompanionBoardColumn",
            "BoardDTO",
            "BoardCardDTO",
            "BoardColumnDTO",
        ]
        let files = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )?.allObjects as? [URL]
        ).filter { $0.pathExtension == "swift" }

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for symbol in forbidden {
                XCTAssertFalse(
                    source.contains(symbol),
                    "Retired Board boundary leaked into native macOS source: \(symbol) in \(file.lastPathComponent)"
                )
            }
        }
    }
}
