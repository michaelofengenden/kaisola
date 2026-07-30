import AppKit
import XCTest
@testable import Kaisola

/// Sticky-scroll pinning must survive a project tab switch.
///
/// SwiftTerm emits `scrolled(source:position:)` from paths that involve no user
/// at all — `Terminal.resize` (run by every pane geometry change), a one-second
/// synchronized-output timeout that agent TUIs arm constantly via DECSET 2026,
/// and `resetToInitialState`. Each of those used to latch "the user scrolled
/// away", after which nothing re-pinned the surface, so a terminal returned from
/// a tab switch stranded mid-scrollback. The pin state may now only change while
/// a real gesture is in flight.
@MainActor
final class TerminalScrollPinTests: XCTestCase {
    private func terminalView() -> ReadOnlyTerminalView {
        ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
    }

    /// Reset from inside the test body rather than `setUp`/`tearDown`.
    /// Those are nonisolated overrides, so calling a main-actor method from them
    /// is only accepted by some toolchains; a test method on a `@MainActor`
    /// class is unambiguously isolated.
    private func freshMonitor() {
        TerminalScrollGestureMonitor.resetForTesting()
    }

    func testNoGestureMeansScrollCallbacksAreNotUserIntent() {
        freshMonitor()
        let view = terminalView()
        XCTAssertFalse(
            TerminalScrollGestureMonitor.isActive(for: view),
            "A resize- or timer-driven scroll callback must never read as a user scroll."
        )
    }

    func testGestureIsAttributedForTheRecencyWindow() {
        freshMonitor()
        let view = terminalView()
        TerminalScrollGestureMonitor.noteGestureForTesting(view: view)
        XCTAssertTrue(TerminalScrollGestureMonitor.isActive(for: view))
    }

    func testGestureIsScopedToTheTerminalUnderThePointer() {
        freshMonitor()
        let target = terminalView()
        let neighbor = terminalView()
        TerminalScrollGestureMonitor.noteGestureForTesting(view: target)
        XCTAssertTrue(TerminalScrollGestureMonitor.isActive(for: target))
        XCTAssertFalse(TerminalScrollGestureMonitor.isActive(for: neighbor))
    }

    func testGestureAttributionExpires() {
        freshMonitor()
        // A gesture older than the window must not license a later callback —
        // otherwise the 1s synchronized-output timeout would inherit intent
        // from a scroll the user made a second earlier.
        let stale = ProcessInfo.processInfo.systemUptime
            - TerminalScrollGestureMonitor.recencyWindow
            - 0.05
        let view = terminalView()
        TerminalScrollGestureMonitor.noteGestureForTesting(view: view, at: stale)
        XCTAssertFalse(TerminalScrollGestureMonitor.isActive(for: view))
    }

    func testRecencyWindowStaysClearOfTheSynchronizedOutputTimeout() {
        freshMonitor()
        // SwiftTerm's synchronized-output timer fires 1s after it is armed. The
        // attribution window has to be comfortably shorter or that timer's
        // callback lands inside it.
        XCTAssertLessThan(TerminalScrollGestureMonitor.recencyWindow, 1.0)
    }

    func testInstallIsIdempotent() {
        freshMonitor()
        TerminalScrollGestureMonitor.install()
        TerminalScrollGestureMonitor.install()
        // Installing twice must not stack monitors; reaching here without a
        // duplicate-registration crash plus a still-sane state is the contract.
        XCTAssertFalse(TerminalScrollGestureMonitor.isActive(for: terminalView()))
    }

    func testContinuedUpwardScrollAtOldestRenderedRowRequestsHistoryOnce() {
        freshMonitor()
        let view = terminalView()
        view.changeScrollback(500)
        for index in 0..<160 {
            view.feed(text: "history-line-\(index)\r\n")
        }
        XCTAssertTrue(view.canScroll)
        view.scroll(toPosition: 0)
        XCTAssertEqual(view.getTerminal().getTopVisibleRow(), 0)

        var requests = 0
        view.onHistoryBoundary = { requests += 1 }
        XCTAssertFalse(view.requestHistoryBeyondTop(scrollingDeltaY: -4, now: 10))
        XCTAssertTrue(view.requestHistoryBeyondTop(scrollingDeltaY: 4, now: 10))
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(view.requestHistoryBeyondTop(scrollingDeltaY: 4, now: 10.1))
        XCTAssertEqual(requests, 1, "Trackpad momentum must not stack transcript sheets")
        XCTAssertTrue(view.requestHistoryBeyondTop(
            scrollingDeltaY: 4,
            now: 10 + ReadOnlyTerminalView.historyBoundaryRequestCooldown
        ))
        XCTAssertEqual(requests, 2)
    }

    func testHistoryBoundaryRequiresRealScrollbackAndAHostAction() {
        freshMonitor()
        let empty = terminalView()
        empty.onHistoryBoundary = {}
        XCTAssertFalse(empty.requestHistoryBeyondTop(scrollingDeltaY: 3, now: 1))

        let scrollable = terminalView()
        for index in 0..<100 {
            scrollable.feed(text: "line-\(index)\r\n")
        }
        scrollable.scroll(toPosition: 0)
        XCTAssertTrue(scrollable.canScroll)
        XCTAssertNil(scrollable.onHistoryBoundary)
        XCTAssertFalse(scrollable.requestHistoryBeyondTop(
            scrollingDeltaY: 3,
            now: 1
        ))
    }
}
