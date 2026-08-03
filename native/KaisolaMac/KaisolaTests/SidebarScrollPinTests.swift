import XCTest
@testable import Kaisola

/// The sidebar opened scrolled *past its own content*: the first project row
/// sat above the clip view and was clipped, and on a workspace whose sessions
/// arrive in several batches it went entirely.
///
/// Measured on a dev launch (`SCROLLPROBE`): the rail's scroll view carries no
/// content insets and no safe area (both zero) and its document view is exactly
/// as tall as its clip view — yet `clipBounds.origin.y` moved from 0 to 8
/// between 0.5s and 1.0s after launch. The stack at that moment:
///
///     -[NSClipView scrollToPoint:]
///     -[NSTableRowData _keepTopRowStableAtLeastOnce:andDoWorkUntilDone:]
///     -[NSTableRowData _updateVisibleViewsBasedOnUpdateItems]
///     -[NSTableView endUpdates]
///     SwiftUI.OutlineListCoordinator.diffRows(of:to:)
///
/// AppKit compensating for rows inserted above the current top row — correct
/// when there is a user scroll position to preserve, an artefact at launch when
/// there is not. These are the rules that decide when the rail is put back.
final class SidebarScrollPinTests: XCTestCase {
    // MARK: - The launch pin

    /// While pinned, the top is the only legal offset — including the exact 8pt
    /// that was measured, and including a whole row's worth.
    func testWhilePinnedAnyOffsetIsCorrectedToTheTop() {
        XCTAssertEqual(
            SidebarScrollPin.correction(
                currentY: 8,
                contentHeight: 398,
                visibleHeight: 398,
                pinnedToTop: true
            ),
            0
        )
        XCTAssertEqual(
            SidebarScrollPin.correction(
                currentY: 32,
                contentHeight: 2000,
                visibleHeight: 398,
                pinnedToTop: true
            ),
            0
        )
    }

    /// A list already at its top is left alone, so the pin never posts a scroll
    /// of its own and can never feed itself.
    func testAListAlreadyAtTheTopIsNotTouched() {
        XCTAssertNil(
            SidebarScrollPin.correction(
                currentY: 0,
                contentHeight: 398,
                visibleHeight: 398,
                pinnedToTop: true
            )
        )
        XCTAssertNil(
            SidebarScrollPin.correction(
                currentY: 0,
                contentHeight: 2000,
                visibleHeight: 398,
                pinnedToTop: false
            )
        )
    }

    // MARK: - The permanent clamp

    /// The reproduced defect, stated exactly as it was measured: content no
    /// taller than the clip view, so there is nothing to scroll and the only
    /// legal offset is zero — yet the list sat at 8.
    func testAListShorterThanItsClipViewCannotBeScrolledAtAll() {
        XCTAssertEqual(
            SidebarScrollPin.correction(
                currentY: 8,
                contentHeight: 398,
                visibleHeight: 398,
                pinnedToTop: false
            ),
            0
        )
        XCTAssertEqual(
            SidebarScrollPin.correction(
                currentY: 8,
                contentHeight: 160,
                visibleHeight: 398,
                pinnedToTop: false
            ),
            0
        )
    }

    /// Once the pin has lapsed the user owns the scroll position, and every
    /// offset inside the scrollable range is theirs to keep — the clamp must be
    /// silent for all of them, or it would fight the scroll wheel.
    func testAnyOffsetInsideTheScrollableRangeIsLeftAlone() {
        for offset in stride(from: CGFloat(0), through: 602, by: 43) {
            XCTAssertNil(
                SidebarScrollPin.correction(
                    currentY: offset,
                    contentHeight: 1000,
                    visibleHeight: 398,
                    pinnedToTop: false
                ),
                "offset \(offset) is a legal scroll position and must not be corrected"
            )
        }
    }

    /// Collapsing a project shortens the list under a scrolled rail. The offset
    /// that was legal a moment ago now points past the end, which is the same
    /// class of bug arriving from the other direction.
    func testAnOffsetPastTheEndIsPulledBackToTheEnd() {
        XCTAssertEqual(
            SidebarScrollPin.correction(
                currentY: 600,
                contentHeight: 1000,
                visibleHeight: 398,
                pinnedToTop: false
            ),
            nil
        )
        XCTAssertEqual(
            SidebarScrollPin.correction(
                currentY: 600,
                contentHeight: 500,
                visibleHeight: 398,
                pinnedToTop: false
            ),
            102
        )
    }

    /// Negative offsets are the same defect mirrored: nothing a gesture can
    /// produce, and a guaranteed gap above the first row.
    func testANegativeOffsetIsPulledBackToTheTop() {
        XCTAssertEqual(
            SidebarScrollPin.correction(
                currentY: -12,
                contentHeight: 1000,
                visibleHeight: 398,
                pinnedToTop: false
            ),
            0
        )
    }

    // MARK: - The settling window

    /// Long enough to cover the row-diff batches a restored workspace produces
    /// (the measured compensation lands between 0.5s and 1.0s, and a broker
    /// reconnect adds more), short enough that it can never be mistaken for
    /// owning the scroll position.
    func testThePinWindowCoversLaunchWithoutOwningTheScrollPosition() {
        XCTAssertGreaterThanOrEqual(SidebarScrollPin.pinDuration, 1.0)
        XCTAssertLessThanOrEqual(SidebarScrollPin.pinDuration, 5.0)
    }
}

/// A split shows two surfaces at once. The rail marked only the focused one, so
/// the companion pane sat beside it looking like a closed session — Michael:
/// "there is a bug with the double clicked/viewing multiple tabs".
final class QuietSplitSelectionTests: XCTestCase {
    /// Focus still decides which single row is *selected*; the rest of the
    /// visible set is what the rail was throwing away.
    func testTheFocusedPaneIsSelectedOutOfSeveralOnScreen() {
        XCTAssertEqual(
            QuietRowSelection.selectedID(visibleIDs: ["chat-1", "term-2"], focusedPaneID: "term-2"),
            "term-2"
        )
    }

    /// Focus can name a surface that has been hidden, or one belonging to
    /// another window. A stale id must fall back to a row that is really there.
    func testAStaleFocusFallsBackToARowThatIsActuallyOnScreen() {
        XCTAssertEqual(
            QuietRowSelection.selectedID(visibleIDs: ["chat-1", "term-2"], focusedPaneID: "gone"),
            "chat-1"
        )
        XCTAssertEqual(
            QuietRowSelection.selectedID(visibleIDs: ["chat-1"], focusedPaneID: nil),
            "chat-1"
        )
    }

    func testNothingOnScreenSelectsNothing() {
        XCTAssertNil(QuietRowSelection.selectedID(visibleIDs: [], focusedPaneID: "term-2"))
    }

    /// The companion treatment has to be visibly weaker than the selected one,
    /// or a split reads as two equally-focused rows.
    func testACompanionPaneIsMarkedButRanksBelowTheSelectedRow() {
        XCTAssertGreaterThan(QuietSelectionPill.companionOpacity, 0)
        XCTAssertLessThan(
            QuietSelectionPill.companionOpacity,
            1,
            "a companion pane must not wear the same pill as the focused row"
        )
    }
}
