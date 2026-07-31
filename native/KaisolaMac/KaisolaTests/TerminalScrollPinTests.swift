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
    private struct ScrollFixture {
        let coordinator: NativeTerminalSurface.Coordinator
        let view: ReadOnlyTerminalView
        var output: String
    }

    private func terminalView() -> ReadOnlyTerminalView {
        ReadOnlyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        )
    }

    private func scrollFixture(lineCount: Int = 240) -> ScrollFixture {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = terminalView()
        view.changeScrollback(500)
        view.terminalDelegate = coordinator
        let output = (0..<lineCount)
            .map { "claude-history-\($0)\r\n" }
            .joined()
        coordinator.apply(
            output: output,
            epoch: "scroll-pin-epoch",
            endOffset: Int64(output.utf8.count),
            to: view
        )
        return ScrollFixture(coordinator: coordinator, view: view, output: output)
    }

    private func deepScrollFixture() -> ScrollFixture {
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = terminalView()
        view.changeScrollback(20_000)
        view.terminalDelegate = coordinator
        // Keep the byte count below progressive-replay territory while making
        // a single row smaller than 0.001 of the available scroll range.
        let output = String(repeating: "x\r\n", count: 20_100)
        coordinator.apply(
            output: output,
            epoch: "scroll-pin-epoch",
            endOffset: Int64(output.utf8.count),
            to: view
        )
        return ScrollFixture(coordinator: coordinator, view: view, output: output)
    }

    /// Simulates the visible-row variant of the race: AppKit's local event
    /// monitor observes an upward gesture, SwiftTerm moves its viewport,
    /// and a PTY packet arrives before SwiftTerm delivers its delegate callback.
    /// Temporarily removing the delegate is intentional — if the pre-feed latch
    /// regresses, the subsequent output feed will win and snap this view to 1.0.
    private func beginUpwardGestureBeforeDelegateCallback(
        in fixture: ScrollFixture,
        position: Double = 0.98
    ) {
        TerminalScrollGestureMonitor.noteGestureForTesting(view: fixture.view)
        fixture.view.terminalDelegate = nil
        fixture.view.scroll(toPosition: position)
        fixture.view.terminalDelegate = fixture.coordinator
        XCTAssertTrue(fixture.view.canScroll)
        XCTAssertLessThan(fixture.view.scrollPosition, 0.999)
    }

    private func appendClaudeRepaint(
        _ index: Int,
        to fixture: inout ScrollFixture
    ) {
        // Claude-style TUIs repaint the current row rapidly and frequently use
        // synchronized-output mode. No linefeed is needed to reproduce the bug:
        // a mistaken follow-to-bottom after this feed is directly observable.
        fixture.output += "\u{1B}[?2026h\r\u{1B}[2KClaude repaint \(index)\u{1B}[?2026l"
        fixture.coordinator.apply(
            output: fixture.output,
            epoch: "scroll-pin-epoch",
            endOffset: Int64(fixture.output.utf8.count),
            to: fixture.view
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

    func testVisibleUpwardGestureLatchesBeforeRapidOutputCanSnapToBottom() {
        freshMonitor()
        var fixture = scrollFixture()
        XCTAssertEqual(fixture.view.scrollPosition, 1, accuracy: 0.001)

        beginUpwardGestureBeforeDelegateCallback(in: fixture)
        let positionBeforeOutput = fixture.view.scrollPosition
        let topRowBeforeOutput = fixture.view.getTerminal().getTopVisibleRow()

        appendClaudeRepaint(0, to: &fixture)

        XCTAssertLessThan(
            fixture.view.scrollPosition,
            0.999,
            "The gesture must latch synchronously before the feed gets a chance to follow output."
        )
        XCTAssertEqual(fixture.view.scrollPosition, positionBeforeOutput, accuracy: 0.01)
        XCTAssertEqual(
            fixture.view.getTerminal().getTopVisibleRow(),
            topRowBeforeOutput,
            "An in-place agent repaint must not move the viewport after the user starts scrolling."
        )
    }

    func testSubCellUpwardGestureAtLiveBottomLatchesBeforeFirstOutputPacket() {
        freshMonitor()
        var fixture = scrollFixture()
        let liveBottomRow = fixture.view.getTerminal().getTopVisibleRow()
        XCTAssertEqual(fixture.view.scrollPosition, 1, accuracy: 0.001)

        // AppKit observes this upward gesture while SwiftTerm's private
        // precise-delta accumulator still reports exactly the live bottom.
        // The first repaint must latch that direction without manufacturing a
        // row, consuming the event, or changing SwiftTerm's momentum routing.
        TerminalScrollGestureMonitor.noteGestureForTesting(
            view: fixture.view,
            scrollingUpward: true
        )
        // Claude can publish several synchronized repaint packets before the
        // trackpad accumulator reaches one cell. Every packet must preserve the
        // same pending upward intent; the second packet cannot reinterpret the
        // still-1.0 viewport as a request to follow again.
        for repaint in 0..<3 {
            appendClaudeRepaint(repaint, to: &fixture)
            XCTAssertEqual(fixture.view.scrollPosition, 1, accuracy: 0.001)
            XCTAssertEqual(fixture.view.getTerminal().getTopVisibleRow(), liveBottomRow)
        }

        // SwiftTerm later accumulates enough native delta to cross one row.
        // Suppress only the delegate callback to preserve the original race,
        // then expire gesture attribution: the next repaint reveals whether
        // the first packet latched intent synchronously at position 1.0.
        fixture.view.terminalDelegate = nil
        fixture.view.scrollUp(lines: 1)
        fixture.view.terminalDelegate = fixture.coordinator
        let firstVisibleScrolledRow = fixture.view.getTerminal().getTopVisibleRow()
        XCTAssertEqual(firstVisibleScrolledRow, liveBottomRow - 1)
        XCTAssertLessThan(fixture.view.scrollPosition, 1)
        TerminalScrollGestureMonitor.resetForTesting()

        appendClaudeRepaint(3, to: &fixture)

        XCTAssertLessThan(
            fixture.view.scrollPosition,
            1,
            "The first sub-cell upward gesture was not latched before output reached the live bottom."
        )
        XCTAssertEqual(
            fixture.view.getTerminal().getTopVisibleRow(),
            firstVisibleScrolledRow,
            "Rapid repaint output must not erase the first accumulated row of user scrollback."
        )
    }

    func testExpiredSubCellGestureWithoutRowMovementRecoversLiveFollowing() {
        freshMonitor()
        var fixture = scrollFixture()
        XCTAssertEqual(fixture.view.scrollPosition, 1, accuracy: 0.001)

        TerminalScrollGestureMonitor.noteGestureForTesting(
            view: fixture.view,
            scrollingUpward: true
        )
        appendClaudeRepaint(0, to: &fixture)
        XCTAssertEqual(fixture.view.scrollPosition, 1, accuracy: 0.001)

        // The microscopic gesture ends without SwiftTerm ever crossing a row.
        // Its next output packet must resolve the provisional latch back to
        // live-follow rather than leaving an invisible permanent unpin.
        let stale = ProcessInfo.processInfo.systemUptime
            - TerminalScrollGestureMonitor.recencyWindow
            - 0.05
        TerminalScrollGestureMonitor.noteGestureForTesting(
            view: fixture.view,
            at: stale,
            scrollingUpward: true
        )
        XCTAssertFalse(TerminalScrollGestureMonitor.isActive(for: fixture.view))
        appendClaudeRepaint(1, to: &fixture)
        XCTAssertEqual(fixture.view.scrollPosition, 1, accuracy: 0.001)

        // Observe the private follow state through its production layout seam:
        // a pinned terminal repairs a one-row reflow displacement next turn.
        fixture.view.terminalDelegate = nil
        fixture.view.scrollUp(lines: 1)
        fixture.view.terminalDelegate = fixture.coordinator
        XCTAssertLessThan(fixture.view.scrollPosition, 1)
        fixture.coordinator.repinAfterLayout(fixture.view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))

        XCTAssertEqual(
            fixture.view.scrollPosition,
            1,
            accuracy: 0.001,
            "An expired sub-cell gesture with no row movement must recover live-follow."
        )
    }

    func testOneRowUpInDeepScrollbackIsNotRoundedBackToPinned() {
        freshMonitor()
        var fixture = deepScrollFixture()
        let liveBottomRow = fixture.view.getTerminal().getTopVisibleRow()
        XCTAssertEqual(fixture.view.scrollPosition, 1, accuracy: 0.000_001)

        TerminalScrollGestureMonitor.noteGestureForTesting(
            view: fixture.view,
            scrollingUpward: true
        )
        fixture.view.terminalDelegate = nil
        fixture.view.scrollUp(lines: 1)
        fixture.view.terminalDelegate = fixture.coordinator
        let oneRowUpPosition = fixture.view.scrollPosition
        let oneRowUp = fixture.view.getTerminal().getTopVisibleRow()
        XCTAssertEqual(oneRowUp, liveBottomRow - 1)
        XCTAssertLessThan(oneRowUpPosition, 1)
        XCTAssertGreaterThanOrEqual(
            oneRowUpPosition,
            0.999,
            "The fixture must cover the range the former rounded threshold misclassified."
        )

        fixture.coordinator.scrolled(source: fixture.view, position: oneRowUpPosition)
        TerminalScrollGestureMonitor.resetForTesting()
        appendClaudeRepaint(0, to: &fixture)

        XCTAssertLessThan(
            fixture.view.scrollPosition,
            1,
            "Only exactly 1.0 is live-bottom; a real one-row scroll must remain unpinned."
        )
        XCTAssertEqual(fixture.view.getTerminal().getTopVisibleRow(), oneRowUp)
    }

    func testRepeatedClaudeRepaintsKeepUserUnpinned() {
        freshMonitor()
        var fixture = scrollFixture()
        beginUpwardGestureBeforeDelegateCallback(in: fixture)

        for index in 0..<12 {
            appendClaudeRepaint(index, to: &fixture)
            XCTAssertLessThan(
                fixture.view.scrollPosition,
                0.999,
                "Repaint \(index) incorrectly resumed live-output following."
            )
        }
    }

    func testUserReturningToBottomReenablesOutputFollowing() {
        freshMonitor()
        var fixture = scrollFixture()
        beginUpwardGestureBeforeDelegateCallback(in: fixture)
        appendClaudeRepaint(0, to: &fixture)
        XCTAssertLessThan(fixture.view.scrollPosition, 0.999)

        TerminalScrollGestureMonitor.noteGestureForTesting(view: fixture.view)
        fixture.view.scroll(toPosition: 1)
        // Keep the policy assertion independent of whether this SwiftTerm build
        // reports a programmatic relative scroll through its delegate.
        fixture.coordinator.scrolled(source: fixture.view, position: 1)
        XCTAssertEqual(fixture.view.scrollPosition, 1, accuracy: 0.001)

        fixture.output += "new-live-line\r\n"
        fixture.coordinator.apply(
            output: fixture.output,
            epoch: "scroll-pin-epoch",
            endOffset: Int64(fixture.output.utf8.count),
            to: fixture.view
        )

        XCTAssertEqual(
            fixture.view.scrollPosition,
            1,
            accuracy: 0.001,
            "Returning to the bottom must restore follow mode for subsequent output."
        )
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
