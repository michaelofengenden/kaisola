import XCTest
@testable import Kaisola

final class DetailShowDoorsTests: XCTestCase {
    func testDoorsAppearExactlyWhileTheirPaneIsHidden() {
        let bothOpen = DetailShowDoors.resolve(
            railVisible: true, previewVisible: true, hasProjectDirectory: true
        )
        XCTAssertTrue(bothOpen.isEmpty)

        let railHidden = DetailShowDoors.resolve(
            railVisible: false, previewVisible: true, hasProjectDirectory: true
        )
        XCTAssertEqual(railHidden, DetailShowDoors(showFiles: true, showDocument: false))

        let previewHidden = DetailShowDoors.resolve(
            railVisible: true, previewVisible: false, hasProjectDirectory: true
        )
        XCTAssertEqual(previewHidden, DetailShowDoors(showFiles: false, showDocument: true))

        let bothHidden = DetailShowDoors.resolve(
            railVisible: false, previewVisible: false, hasProjectDirectory: true
        )
        XCTAssertEqual(bothHidden, DetailShowDoors(showFiles: true, showDocument: true))
        XCTAssertFalse(bothHidden.isEmpty)
    }

    func testNoFilesDoorWithoutAProjectDirectory() {
        // Without a project directory the rail cannot render (see
        // RootShellView.detailRailPanelVisible), so a Files door would dead-end.
        let doors = DetailShowDoors.resolve(
            railVisible: false, previewVisible: false, hasProjectDirectory: false
        )
        XCTAssertEqual(doors, DetailShowDoors(showFiles: false, showDocument: true))
    }
}
