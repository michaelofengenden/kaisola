import XCTest
@testable import Kaisola

/// The retained terminal deck was bounded by document *count* only.
///
/// Twelve documents, each free to grow to `TerminalDocument.maximumRetainedBytes`,
/// is 192 MiB of scrollback strings — reachable simply by touring long-lived
/// terminals. Count is the wrong unit for a memory budget: eleven idle shells
/// and one week-old agent log are not the same object.
///
/// The deck is therefore bounded in bytes as well, evicting least-recently-used
/// first. Mounted cards are exempt: a terminal card renders only while its feed
/// exists, so evicting a visible surface would replace live output with a
/// spinner.
@MainActor
final class AppModelTerminalRetentionTests: XCTestCase {
    private func evictions(
        _ order: [String],
        bytes: [String: Int] = [:],
        protected: Set<String> = [],
        maximumSurfaces: Int = AppModel.maximumRetainedTerminalSurfaces,
        maximumBytes: Int = AppModel.maximumRetainedTerminalBytes
    ) -> [String] {
        AppModel.retainedSurfaceEvictions(
            order: order,
            byteCount: { bytes[$0] ?? 0 },
            protected: protected,
            maximumSurfaces: maximumSurfaces,
            maximumBytes: maximumBytes
        )
    }

    private static let megabyte = 1_024 * 1_024

    func testTheBudgetIsStatedInBytesAndIsSmallerThanTheOldWorstCase() {
        XCTAssertEqual(AppModel.maximumRetainedTerminalBytes, 96 * Self.megabyte)
        let countOnlyWorstCase = AppModel.maximumRetainedTerminalSurfaces
            * TerminalDocument.maximumRetainedBytes
        XCTAssertEqual(countOnlyWorstCase, 192 * Self.megabyte, "This is what a count-only bound permitted.")
        XCTAssertLessThan(AppModel.maximumRetainedTerminalBytes, countOnlyWorstCase)
    }

    func testNothingIsEvictedWhileBothBoundsHold() {
        let order = ["a", "b", "c"]
        XCTAssertEqual(
            evictions(order, bytes: ["a": 8 * Self.megabyte, "b": 8 * Self.megabyte, "c": 8 * Self.megabyte]),
            []
        )
    }

    func testTheCountCapStillEvictsLeastRecentlyUsedFirst() {
        let order = (0..<(AppModel.maximumRetainedTerminalSurfaces + 2)).map { "t\($0)" }
        XCTAssertEqual(evictions(order), ["t0", "t1"])
    }

    func testTheByteBudgetEvictsUntilTheDeckFitsEvenUnderTheCountCap() {
        // Five documents, well under the count cap, 160 MiB between them.
        let order = ["a", "b", "c", "d", "e"]
        let bytes = Dictionary(uniqueKeysWithValues: order.map { ($0, 32 * Self.megabyte) })
        XCTAssertEqual(evictions(order, bytes: bytes), ["a", "b"])
    }

    func testEvictionStopsAsSoonAsTheDeckFits() {
        let order = ["a", "b", "c"]
        let bytes = ["a": 64 * Self.megabyte, "b": 32 * Self.megabyte, "c": 32 * Self.megabyte]
        XCTAssertEqual(evictions(order, bytes: bytes), ["a"])
    }

    func testMountedSurfacesAreNeverEvictedAndTheNextOldestGoesInstead() {
        let order = ["visible", "b", "c", "d"]
        let bytes = Dictionary(uniqueKeysWithValues: order.map { ($0, 40 * Self.megabyte) })
        XCTAssertEqual(evictions(order, bytes: bytes, protected: ["visible"]), ["b", "c"])
    }

    func testAProtectedDeckIsLeftAloneRatherThanBlankingACard() {
        let order = ["a", "b", "c"]
        let bytes = Dictionary(uniqueKeysWithValues: order.map { ($0, 64 * Self.megabyte) })
        XCTAssertEqual(
            evictions(order, bytes: bytes, protected: ["a", "b", "c"]),
            [],
            "A budget that blanks live terminals is worse than the memory it saves."
        )
    }

    func testTheNewestDocumentSurvivesEvenWhenItAloneExceedsTheBudget() {
        let order = ["a", "b"]
        let bytes = ["a": 8 * Self.megabyte, "b": 200 * Self.megabyte]
        XCTAssertEqual(
            evictions(order, bytes: bytes),
            ["a"],
            "The just-retained document is the one being published; dropping it would blank the selection."
        )
        XCTAssertEqual(evictions(["only"], bytes: ["only": 200 * Self.megabyte]), [])
    }

    func testTheCountCapAlsoRespectsMountedSurfaces() {
        var order = ["pinned"]
        order.append(contentsOf: (0..<AppModel.maximumRetainedTerminalSurfaces).map { "t\($0)" })
        XCTAssertEqual(evictions(order, protected: ["pinned"]), ["t0"])
    }

    // MARK: - protectedSurfaceIDs

    /// `focusTerminalSurface` unsubscribes the outgoing primary before
    /// re-subscribing it as a split, so mid-transition it is none of
    /// `selectedSessionID`, the primary document, a split document, or a
    /// pending split subscription — yet its card is still mounted in the
    /// active project's pane layout. It must be protected anyway.
    func testAnIDPresentOnlyInTheActivePaneLayoutIsProtected() {
        let protectedIDs = AppModel.protectedSurfaceIDs(
            splitDocumentIDs: [],
            pendingSplitSubscriptionIDs: [],
            selectedSessionID: "new-primary",
            primarySessionID: "new-primary",
            activePaneLayoutSessionIDs: ["new-primary", "mid-transition"]
        )
        XCTAssertTrue(protectedIDs.contains("mid-transition"))

        // And it survives an eviction pass that would otherwise take it as
        // the least-recently-used entry.
        let order = ["mid-transition", "b", "c", "d"]
        let bytes = Dictionary(uniqueKeysWithValues: order.map { ($0, 40 * Self.megabyte) })
        XCTAssertEqual(evictions(order, bytes: bytes, protected: protectedIDs), ["b", "c"])
    }

    /// An id that belongs to no active surface and sits outside the pane
    /// layout — e.g. a different project's terminal, or one the user closed
    /// — is not protected by the layout union.
    func testAnIDOutsideEveryMountedSetIsNotProtected() {
        let protectedIDs = AppModel.protectedSurfaceIDs(
            splitDocumentIDs: [],
            pendingSplitSubscriptionIDs: [],
            selectedSessionID: "new-primary",
            primarySessionID: "new-primary",
            activePaneLayoutSessionIDs: ["new-primary"]
        )
        XCTAssertFalse(protectedIDs.contains("elsewhere"))
    }
}
