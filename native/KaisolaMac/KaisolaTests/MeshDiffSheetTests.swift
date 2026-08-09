import XCTest
@testable import Kaisola

/// The Mesh diff sheet used to share one patch string across every column, so a
/// newly opened column showed the previous agent's edits — or announced "No
/// changes yet." — until its own request landed, and a slow diff could still be
/// applied after the user switched or closed the sheet. These pin the keyed,
/// fenced replacement.
final class MeshDiffSheetTests: XCTestCase {

    func testOpeningAnotherColumnDropsThePreviousColumnsPatch() {
        var sheet = MeshDiffSheetState()
        let alpha = sheet.open(columnID: "alpha")
        XCTAssertTrue(sheet.apply(patch: "alpha patch", from: "alpha", token: alpha))
        XCTAssertEqual(sheet.patch, "alpha patch")

        sheet.close()
        _ = sheet.open(columnID: "beta")

        XCTAssertEqual(sheet.columnID, "beta")
        XCTAssertTrue(sheet.isLoading)
        XCTAssertNil(sheet.patch, "beta must not inherit alpha's diff while its own is loading")
    }

    func testAColumnOnlyClaimsNoChangesAfterItsOwnRequestCompletes() {
        var sheet = MeshDiffSheetState()
        let token = sheet.open(columnID: "alpha")

        // Nil, not "" — an empty patch is what the sheet renders as "No changes
        // yet.", and nothing may claim that before the diff actually returns.
        XCTAssertNil(sheet.patch)
        XCTAssertTrue(sheet.isLoading)

        XCTAssertTrue(sheet.apply(patch: "", from: "alpha", token: token))
        XCTAssertEqual(sheet.patch, "")
        XCTAssertFalse(sheet.isLoading)
    }

    func testALateResultFromThePreviousColumnIsDropped() {
        var sheet = MeshDiffSheetState()
        let alpha = sheet.open(columnID: "alpha")
        sheet.close()
        let beta = sheet.open(columnID: "beta")

        XCTAssertFalse(sheet.apply(patch: "alpha patch", from: "alpha", token: alpha))
        XCTAssertNil(sheet.patch)
        XCTAssertEqual(sheet.columnID, "beta")

        XCTAssertTrue(sheet.apply(patch: "beta patch", from: "beta", token: beta))
        XCTAssertEqual(sheet.patch, "beta patch")
    }

    func testAResultArrivingAfterDismissalIsDropped() {
        var sheet = MeshDiffSheetState()
        let token = sheet.open(columnID: "alpha")
        sheet.close()

        XCTAssertFalse(sheet.isPresented)
        XCTAssertFalse(sheet.apply(patch: "alpha patch", from: "alpha", token: token))
        XCTAssertNil(sheet.columnID)
        XCTAssertNil(sheet.patch)
    }

    func testReopeningTheSameColumnReloadsInsteadOfShowingTheStalePatch() {
        var sheet = MeshDiffSheetState()
        let first = sheet.open(columnID: "alpha")
        XCTAssertTrue(sheet.apply(patch: "old patch", from: "alpha", token: first))

        sheet.close()
        let second = sheet.open(columnID: "alpha")

        XCTAssertNotEqual(first, second, "each open must get its own token")
        XCTAssertTrue(sheet.isLoading)
        XCTAssertNil(sheet.patch)
        XCTAssertFalse(sheet.apply(patch: "old patch", from: "alpha", token: first))
        XCTAssertTrue(sheet.apply(patch: "new patch", from: "alpha", token: second))
        XCTAssertEqual(sheet.patch, "new patch")
    }

    func testAFreshSheetIsDismissedAndEmpty() {
        let sheet = MeshDiffSheetState()
        XCTAssertFalse(sheet.isPresented)
        XCTAssertNil(sheet.columnID)
        XCTAssertNil(sheet.patch)
    }
}
