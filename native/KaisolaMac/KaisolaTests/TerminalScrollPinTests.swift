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

    /// One batch of ordinary streamed output, appended the way the broker
    /// delivers it: same epoch, extended byte range, incremental feed.
    private func appendStreamedLine(
        _ index: Int,
        to fixture: inout ScrollFixture
    ) {
        fixture.output += "claude-history-\(index)\r\n"
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

    func testContinuousScrollPhysicsPreservesEverySubRowSampleAt120Hertz() {
        let rowHeight: CGFloat = 20
        var state = TerminalContinuousScrollState(
            anchorRow: 100,
            fractionalOffset: 0,
            rowHeight: rowHeight,
            maximumRow: 100,
            viewportExtent: 320
        )
        var previous = state.projection.presentedPosition

        // A deterministic one-second 120 Hz gesture whose individual samples
        // are all smaller than one terminal cell. The old SwiftTerm path would
        // leave the viewport frozen for many samples, then jump a whole row.
        for sample in 0..<120 {
            state.apply(scrollingDeltaY: 0.375)
            let projection = state.projection
            XCTAssertEqual(
                previous - projection.presentedPosition,
                0.375,
                accuracy: 0.000_001,
                "Sample \(sample) was quantized or dropped."
            )
            XCTAssertEqual(
                CGFloat(projection.anchorRow) * rowHeight + projection.offsetWithinAnchor,
                projection.presentedPosition,
                accuracy: 0.000_001,
                "Crossing an integer row must not create a visual discontinuity."
            )
            previous = projection.presentedPosition
        }

        XCTAssertEqual(state.projection.anchorRow, 97)
        XCTAssertEqual(state.projection.offsetWithinAnchor, 15, accuracy: 0.000_001)
        XCTAssertEqual(state.projection.scrollbarPosition, 0.9775, accuracy: 0.000_001)
    }

    func testContinuousScrollPhysicsRubberBandsAndSettlesAtBothEdges() {
        var oldest = TerminalContinuousScrollState(
            anchorRow: 0,
            fractionalOffset: 0,
            rowHeight: 20,
            maximumRow: 100,
            viewportExtent: 320
        )
        oldest.apply(scrollingDeltaY: 120)
        XCTAssertTrue(oldest.projection.isRubberBanding)
        XCTAssertLessThan(oldest.projection.presentedPosition, 0)
        XCTAssertGreaterThan(oldest.projection.presentedPosition, -120)
        oldest.settle()
        XCTAssertEqual(oldest.projection.presentedPosition, 0, accuracy: 0.000_001)
        XCTAssertFalse(oldest.projection.isRubberBanding)

        var newest = TerminalContinuousScrollState(
            anchorRow: 100,
            fractionalOffset: 0,
            rowHeight: 20,
            maximumRow: 100,
            viewportExtent: 320
        )
        newest.apply(scrollingDeltaY: -120)
        XCTAssertTrue(newest.projection.isRubberBanding)
        XCTAssertGreaterThan(newest.projection.presentedPosition, 2_000)
        XCTAssertLessThan(newest.projection.presentedPosition, 2_120)
        newest.settle()
        XCTAssertEqual(newest.projection.presentedPosition, 2_000, accuracy: 0.000_001)
        XCTAssertFalse(newest.projection.isRubberBanding)
    }

    func testRubberBandWaitsForZeroDeltaGestureEndBeforeSettling() {
        let fixture = scrollFixture()
        fixture.view.scroll(toPosition: 0)
        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: 32,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))
        XCTAssertTrue(fixture.view.continuousScrollSnapshot?.isRubberBanding == true)
        let heldOrigin = fixture.view.bounds.origin.y

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(fixture.view.bounds.origin.y, heldOrigin, accuracy: 0.000_001)

        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: 0,
            hasPreciseScrollingDeltas: true,
            phase: .ended,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(fixture.view.continuousScrollSnapshot?.isRubberBanding == true)
        XCTAssertEqual(fixture.view.bounds.origin.y, 0, accuracy: 0.000_001)
    }

    /// Streamed output moves the live bottom. A rubber band measured against
    /// that edge must move with it, not be discarded: `reconfigure` treated the
    /// band as a sub-row fraction, and dropping fractions while banding zeroed
    /// the whole displacement on every batch an agent emitted.
    func testReconfigureCarriesRubberBandDisplacementAcrossStreamedGrowth() {
        var state = TerminalContinuousScrollState(
            anchorRow: 100,
            fractionalOffset: 0,
            rowHeight: 20,
            maximumRow: 100,
            viewportExtent: 320
        )
        state.apply(scrollingDeltaY: -120)
        let band = state.projection.presentedPosition - 100 * 20
        XCTAssertTrue(state.projection.isRubberBanding)
        XCTAssertGreaterThan(band, 0)

        // One more line of agent output: the live bottom is now a row lower.
        state.reconfigure(
            anchorRow: 101,
            rowHeight: 20,
            maximumRow: 101,
            viewportExtent: 320
        )

        XCTAssertTrue(
            state.projection.isRubberBanding,
            "Output growth collapsed a band the user is still holding."
        )
        XCTAssertEqual(
            state.projection.presentedPosition - 101 * 20,
            band,
            accuracy: 0.000_001,
            "The band must follow the edge it is measured against."
        )
    }

    /// The shake: an agent streaming output while the user holds an overscroll
    /// past the newest row. Every batch ran the live-bottom pin, which routed
    /// through `prepareForDiscreteScrollInput` and dropped the continuous state
    /// outright, snapping the viewport back to zero; the next trackpad sample
    /// rebuilt it from nothing and pushed it out again. At an agent's output
    /// rate that reads as vibration rather than a rubber band.
    func testStreamedOutputDoesNotCollapseAnOverscrollHeldPastTheLiveBottom() {
        var fixture = scrollFixture()
        fixture.view.scroll(toPosition: 1)
        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: -32,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))
        XCTAssertTrue(fixture.view.continuousScrollSnapshot?.isRubberBanding == true)
        let held = fixture.view.bounds.origin.y
        XCTAssertLessThan(held, -1, "The overscroll must displace the viewport.")

        appendStreamedLine(240, to: &fixture)

        XCTAssertTrue(
            fixture.view.continuousScrollSnapshot?.isRubberBanding == true,
            "An output batch cancelled a gesture the user is still holding."
        )
        XCTAssertEqual(
            fixture.view.bounds.origin.y,
            held,
            accuracy: 0.000_001,
            "The held overscroll must not snap back while output streams."
        )
    }

    /// The same batch must still follow the newest output. Preserving the band
    /// is only correct if the rows underneath it keep advancing.
    func testStreamedOutputStillFollowsTheLiveBottomUnderneathAHeldOverscroll() {
        var fixture = scrollFixture()
        fixture.view.scroll(toPosition: 1)
        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: -32,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))
        let anchorBefore = fixture.view.getTerminal().getTopVisibleRow()

        appendStreamedLine(240, to: &fixture)

        XCTAssertGreaterThan(
            fixture.view.getTerminal().getTopVisibleRow(),
            anchorBefore,
            "Holding an overscroll must not stop the terminal following output."
        )
    }

    /// `layout()` re-pins on every usable pass, so a shell redraw landing mid
    /// gesture was a second route to the same collapse as a streamed batch.
    func testLayoutRepinDoesNotCollapseAnOverscrollHeldPastTheLiveBottom() {
        let fixture = scrollFixture()
        fixture.view.scroll(toPosition: 1)
        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: -32,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))
        let held = fixture.view.bounds.origin.y
        XCTAssertLessThan(held, -1)

        fixture.coordinator.repinAfterLayout(fixture.view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            fixture.view.bounds.origin.y,
            held,
            accuracy: 0.000_001,
            "A layout pass cancelled a gesture the user is still holding."
        )
    }

    func testPreciseTrackpadSamplesMoveRealViewportContinuouslyAndUpdateScroller() throws {
        freshMonitor()
        let fixture = scrollFixture()
        fixture.view.selectAll(nil)
        let selection = fixture.view.selectedRange()
        let liveBottomRow = fixture.view.getTerminal().getTopVisibleRow()

        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: 2.5,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))

        let first = try XCTUnwrap(fixture.view.continuousScrollSnapshot)
        XCTAssertEqual(first.anchorRow, liveBottomRow - 1)
        XCTAssertGreaterThan(first.offsetWithinAnchor, 0)
        XCTAssertLessThan(first.offsetWithinAnchor, first.rowHeight)
        XCTAssertEqual(fixture.view.bounds.origin.y, -first.offsetWithinAnchor, accuracy: 0.000_001)
        XCTAssertEqual(fixture.view.nativeScrollerValue, first.scrollbarPosition, accuracy: 0.000_001)
        XCTAssertFalse(fixture.view.isViewportAtLiveBottom)
        XCTAssertEqual(fixture.view.selectedRange(), selection)

        var origins = [fixture.view.bounds.origin.y]
        for _ in 0..<12 {
            XCTAssertTrue(fixture.view.handleContinuousScroll(
                scrollingDeltaY: 0.25,
                hasPreciseScrollingDeltas: true,
                phase: .changed,
                momentumPhase: .changed,
                routesToNativeScrollback: true
            ))
            origins.append(fixture.view.bounds.origin.y)
        }
        XCTAssertEqual(Set(origins.map { ($0 * 1_000).rounded() }).count, origins.count)
        XCTAssertEqual(fixture.view.selectedRange(), selection)
    }

    func testMountedNativeScrollerRemainsFixedWhileTerminalContentMovesFractionally() throws {
        freshMonitor()
        let fixture = scrollFixture()
        let host = NSView(frame: fixture.view.frame)
        host.addSubview(fixture.view)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        fixture.view.layoutSubtreeIfNeeded()

        let scroller = try XCTUnwrap(
            fixture.view.subviews.compactMap { $0 as? NSScroller }.first
        )
        let before = try XCTUnwrap(fixture.view.nativeScrollerWindowFrame)

        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: 2.5,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))
        fixture.view.layoutSubtreeIfNeeded()

        let after = try XCTUnwrap(fixture.view.nativeScrollerWindowFrame)
        XCTAssertEqual(after.origin.x, before.origin.x, accuracy: 0.000_001)
        XCTAssertEqual(after.origin.y, before.origin.y, accuracy: 0.000_001)
        XCTAssertEqual(after.size.width, before.size.width, accuracy: 0.000_001)
        XCTAssertEqual(after.size.height, before.size.height, accuracy: 0.000_001)
    }

    func testFractionalHitTestingPreservesExplicitLinkAcrossAgentRepaint() throws {
        freshMonitor()
        let coordinator = NativeTerminalSurface.Coordinator()
        let view = terminalView()
        view.changeScrollback(500)
        view.terminalDelegate = coordinator
        let href = "https://kaisola.app/continuous-scroll-contract"
        var output = "Open \u{1B}]8;;\(href)\u{7}linked-anchor\u{1B}]8;;\u{7}\r\n"
            + (0..<240).map { "history-\($0)\r\n" }.joined()
        coordinator.apply(
            output: output,
            epoch: "continuous-link-epoch",
            endOffset: Int64(output.utf8.count),
            to: view
        )
        view.scroll(toPosition: 0)
        TerminalScrollGestureMonitor.noteGestureForTesting(
            view: view,
            scrollingUpward: false
        )
        XCTAssertTrue(view.handleContinuousScroll(
            scrollingDeltaY: -3.25,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))

        output += "\u{1B}[?2026h\r\u{1B}[2KClaude repaint\u{1B}[?2026l"
        coordinator.apply(
            output: output,
            epoch: "continuous-link-epoch",
            endOffset: Int64(output.utf8.count),
            to: view
        )

        let projection = try XCTUnwrap(view.continuousScrollSnapshot)
        let dimensions = view.getTerminal().getDims()
        let optimal = view.getOptimalFrameSize().size
        let scrollerWidth = NSScroller.scrollerWidth(
            for: .regular,
            scrollerStyle: view.scrollerStyle
        )
        let cellWidth = (optimal.width - scrollerWidth) / CGFloat(dimensions.cols)
        let point = NSPoint(
            x: cellWidth * 8,
            y: view.frame.height - projection.rowHeight / 2
        )
        XCTAssertEqual(view.terminalCell(at: point)?.row, 0)
        XCTAssertEqual(view.terminalLink(at: point), href)
    }

    func testFractionalViewportSurvivesAgentRepaintResizeHitTestingAndSurfaceCache() throws {
        freshMonitor()
        var fixture = deepScrollFixture()
        fixture.view.configureJumpToLiveBottomAffordance()
        // Production's local event monitor attributes the sample before the
        // renderer moves. Mirror that ordering so the following PTY repaint is
        // testing continuous-scroll retention, not an impossible unowned feed.
        TerminalScrollGestureMonitor.noteGestureForTesting(view: fixture.view)
        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: 2.5,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: .changed,
            routesToNativeScrollback: true
        ))
        let beforeRepaint = try XCTUnwrap(fixture.view.continuousScrollSnapshot)
        let topBeforeRepaint = fixture.view.getTerminal().getTopVisibleRow()

        appendClaudeRepaint(0, to: &fixture)

        let afterRepaint = try XCTUnwrap(fixture.view.continuousScrollSnapshot)
        XCTAssertEqual(afterRepaint.presentedPosition, beforeRepaint.presentedPosition, accuracy: 0.001)
        XCTAssertEqual(fixture.view.getTerminal().getTopVisibleRow(), topBeforeRepaint)
        XCTAssertTrue(fixture.view.jumpToLiveBottomIsVisible)

        // The fractional origin participates in the same mouse-cell transform
        // as SwiftTerm selection and links: the clipped tail of anchor row zero
        // ends before the next full row begins.
        let remainingAnchorHeight = afterRepaint.rowHeight - afterRepaint.offsetWithinAnchor
        let anchorPoint = NSPoint(
            x: 4,
            y: fixture.view.bounds.maxY - remainingAnchorHeight / 2
        )
        let nextPoint = NSPoint(
            x: 4,
            y: fixture.view.bounds.maxY - remainingAnchorHeight - 1
        )
        XCTAssertEqual(fixture.view.terminalCell(at: anchorPoint)?.row, 0)
        XCTAssertEqual(fixture.view.terminalCell(at: nextPoint)?.row, 1)

        fixture.view.setFrameSize(NSSize(width: 700, height: 360))
        let afterResize = try XCTUnwrap(fixture.view.continuousScrollSnapshot)
        XCTAssertEqual(
            afterResize.offsetWithinAnchor / afterResize.rowHeight,
            beforeRepaint.offsetWithinAnchor / beforeRepaint.rowHeight,
            accuracy: 0.001
        )

        let cache = TerminalSurfaceCache.shared
        cache.removeAll()
        defer { cache.removeAll() }
        let identity = ObjectIdentifier(fixture.view)
        cache.store(
            sessionID: "continuous-scroll-cache",
            view: fixture.view,
            coordinator: fixture.coordinator
        )
        let claimed = try XCTUnwrap(cache.claim(
            sessionID: "continuous-scroll-cache",
            controllerCapable: false
        ))
        XCTAssertEqual(ObjectIdentifier(claimed.view), identity)
        XCTAssertEqual(claimed.view.continuousScrollSnapshot, afterResize)
        XCTAssertEqual(claimed.view.getTerminal().options.scrollback, 20_000)
    }

    func testJumpToLiveBottomClearsFractionAndRestoresExactFollow() {
        freshMonitor()
        let fixture = scrollFixture()
        fixture.view.configureJumpToLiveBottomAffordance()
        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: 1,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))
        XCTAssertFalse(fixture.view.isViewportAtLiveBottom)
        XCTAssertTrue(fixture.view.jumpToLiveBottomIsVisible)

        XCTAssertTrue(fixture.view.performJumpToLiveBottom())

        XCTAssertTrue(fixture.view.isViewportAtLiveBottom)
        XCTAssertEqual(fixture.view.scrollPosition, 1, accuracy: 0.000_001)
        XCTAssertNil(fixture.view.continuousScrollSnapshot)
        XCTAssertEqual(fixture.view.bounds.origin.y, 0, accuracy: 0.000_001)
        XCTAssertFalse(fixture.view.jumpToLiveBottomIsVisible)
        XCTAssertTrue(fixture.coordinator.isFollowingLiveOutput)
    }

    func testDiscreteKeyboardAndAccessibilityPagingReconcileFractionalViewport() throws {
        freshMonitor()
        let fixture = scrollFixture()
        XCTAssertTrue(fixture.view.handleContinuousScroll(
            scrollingDeltaY: 3,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))
        XCTAssertNotEqual(fixture.view.bounds.origin.y, 0)

        fixture.view.prepareForDiscreteScrollInput()
        XCTAssertNil(fixture.view.continuousScrollSnapshot)
        XCTAssertEqual(fixture.view.bounds.origin.y, 0, accuracy: 0.000_001)

        let accessibilityActionNames = fixture.view.accessibilityCustomActions()?.map(\.name) ?? []
        XCTAssertTrue(accessibilityActionNames.contains("Scroll one page up"))
        XCTAssertTrue(accessibilityActionNames.contains("Scroll one page down"))
        let beforeAX = fixture.view.getTerminal().getTopVisibleRow()
        XCTAssertTrue(fixture.view.accessibilityPerformDecrement())
        XCTAssertLessThan(fixture.view.getTerminal().getTopVisibleRow(), beforeAX)
        XCTAssertNil(fixture.view.continuousScrollSnapshot)
        XCTAssertEqual(fixture.view.bounds.origin.y, 0, accuracy: 0.000_001)
        XCTAssertTrue(fixture.view.accessibilityPerformIncrement())
    }

    func testContinuousScrollNeverConsumesAlternateScreenOrAppOwnedMouseRouting() {
        freshMonitor()
        let fixture = scrollFixture()

        XCTAssertFalse(fixture.view.handleContinuousScroll(
            scrollingDeltaY: 4,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: false
        ))
        XCTAssertNil(fixture.view.continuousScrollSnapshot)

        fixture.view.feed(text: "\u{1B}[?1049h")
        XCTAssertTrue(fixture.view.getTerminal().isCurrentBufferAlternate)
        XCTAssertFalse(fixture.view.handleContinuousScroll(
            scrollingDeltaY: 4,
            hasPreciseScrollingDeltas: true,
            phase: .changed,
            momentumPhase: [],
            routesToNativeScrollback: true
        ))
        XCTAssertNil(fixture.view.continuousScrollSnapshot)
        XCTAssertEqual(fixture.view.bounds.origin.y, 0, accuracy: 0.000_001)
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
