import AppKit
import SwiftTerm
import XCTest
@testable import Kaisola

/// ⌥-click must move the cursor to the click, the way iTerm2 and Terminal.app
/// do — that is how you reposition inside an agent CLI's composer.
///
/// It was never implemented anywhere in the stack: SwiftTerm consults `.shift`
/// on its mouse paths and never `.option`, so the click fell into a branch that
/// does nothing. It was not merely inert either — link activation ignores
/// modifiers, so ⌥-clicking a path in the composer opened a file preview.
@MainActor
final class TerminalOptionClickTests: XCTestCase {
    /// Captures what the view sends to the PTY. `OwnedTerminalView.send`
    /// forwards to its terminal delegate, so a real coordinator is the seam —
    /// no production test hook required.
    @MainActor
    private final class Capture {
        let coordinator = NativeTerminalSurface.Coordinator()
        var sent: [UInt8] = []

        init() {
            coordinator.onInput = { [weak self] text in
                self?.sent.append(contentsOf: Array(text.utf8))
            }
        }
    }

    private func makeView(_ capture: Capture) -> OwnedTerminalView {
        let view = OwnedTerminalView(
            frame: .init(x: 0, y: 0, width: 800, height: 400),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        view.terminalDelegate = capture.coordinator
        view.getTerminal().resize(cols: 80, rows: 24)
        return view
    }

    private func oscPayload(_ value: String) -> ArraySlice<UInt8> {
        Array(value.utf8)[...]
    }

    private func osc133(_ value: String) -> String {
        "\u{1B}]133;\(value)\u{1B}\\"
    }

    private func osc633(_ value: String) -> String {
        "\u{1B}]633;\(value)\u{1B}\\"
    }

    private func optionClick(at point: NSPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: .option,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    func testCellMathRecoversTheClickedColumn() {
        let view = makeView(Capture())
        let dims = view.getTerminal().getDims()
        let optimal = view.getOptimalFrameSize().size
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: view.scrollerStyle)
        let cellWidth = (optimal.width - scroller) / CGFloat(dims.cols)

        // Sample the middle of column 10 so rounding cannot straddle a boundary.
        let point = NSPoint(x: cellWidth * 10.5, y: view.bounds.height - 1)
        let cell = view.terminalCell(at: point)
        XCTAssertEqual(cell?.column, 10)
        XCTAssertEqual(cell?.row, 0)
    }

    func testCellMathRejectsPointsOutsideTheView() {
        let view = makeView(Capture())
        XCTAssertNil(view.terminalCell(at: NSPoint(x: -5, y: 5)))
        XCTAssertNil(view.terminalCell(at: NSPoint(x: 10_000, y: 5)))
    }

    func testViewportGateIsOpenOnAFreshTerminal() {
        // With no scrollback accumulated the viewport is live, so a screen row
        // equals the cursor's row.
        XCTAssertTrue(makeView(Capture()).isViewportAtLiveBottom)
    }

    func testOptionClickSendsRightArrowsTowardTheClick() {
        let capture = Capture()
        let view = makeView(capture)

        let dims = view.getTerminal().getDims()
        let optimal = view.getOptimalFrameSize().size
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: view.scrollerStyle)
        let cellWidth = (optimal.width - scroller) / CGFloat(dims.cols)

        // Cursor starts at column 0, row 0. Click column 6 on the same row.
        view.mouseUp(with: optionClick(at: NSPoint(x: cellWidth * 6.5, y: view.bounds.height - 1)))

        let right = Array(EscapeSequences.moveRightNormal)
        XCTAssertEqual(capture.sent.count, right.count * 6, "one arrow per column of delta")
        XCTAssertEqual(Array(capture.sent.prefix(right.count)), right)
    }

    func testOptionClickOnTheCursorSendsNothing() {
        let capture = Capture()
        let view = makeView(capture)
        view.mouseUp(with: optionClick(at: NSPoint(x: 1, y: view.bounds.height - 1)))
        XCTAssertTrue(capture.sent.isEmpty, "Clicking the cursor's own cell is a no-op")
    }

    func testOptionClickOnAnotherRowIsConsumedRatherThanSendingVerticalArrows() {
        // Up/Down at a composer's first or last line recalls history in both
        // Claude Code and Codex — destructive. A vertical option-click must be
        // swallowed, never translated.
        let capture = Capture()
        let view = makeView(capture)

        let dims = view.getTerminal().getDims()
        let cellHeight = view.getOptimalFrameSize().size.height / CGFloat(dims.rows)
        // Row 5, well away from the cursor's row 0.
        view.mouseUp(with: optionClick(at: NSPoint(x: 4, y: view.bounds.height - (cellHeight * 5.5))))

        XCTAssertTrue(capture.sent.isEmpty)
    }

    func testOSC133ParserAcceptsFinalTermMarkersAndBoundsExitStatus() {
        XCTAssertEqual(TerminalSemanticEvent.parse(oscPayload("A")), .promptStart(isSecondary: false))
        XCTAssertEqual(TerminalSemanticEvent.parse(oscPayload("A;k=s")), .promptStart(isSecondary: true))
        XCTAssertEqual(TerminalSemanticEvent.parse(oscPayload("B")), .commandStart)
        XCTAssertEqual(TerminalSemanticEvent.parse(oscPayload("C;cmdline_url=git%20status")), .commandExecuted)
        XCTAssertEqual(TerminalSemanticEvent.parse(oscPayload("D")), .commandFinished(exitCode: nil))
        XCTAssertEqual(TerminalSemanticEvent.parse(oscPayload("D;17")), .commandFinished(exitCode: 17))

        XCTAssertNil(TerminalSemanticEvent.parse(oscPayload("B;spoof")))
        XCTAssertNil(TerminalSemanticEvent.parse(oscPayload("D;-1")))
        XCTAssertNil(TerminalSemanticEvent.parse(oscPayload("D;99999999999")))
        XCTAssertNil(TerminalSemanticEvent.parse(oscPayload("unknown")))
        XCTAssertNil(TerminalSemanticEvent.parse(oscPayload(String(repeating: "A", count: 1_025))))
        XCTAssertNil(TerminalSemanticEvent.parse(ArraySlice([0xFF])))
    }

    func testSemanticTrackerBuildsCommandBoundsAndExitStatus() {
        var tracker = TerminalSemanticTracker()
        tracker.receive(.promptStart(isSecondary: false), at: .init(row: 4, column: 0))
        tracker.receive(.commandStart, at: .init(row: 4, column: 9))
        tracker.observeCursor(at: .init(row: 6, column: 3))
        XCTAssertEqual(tracker.activeInputRows, 4...6)

        tracker.receive(.promptStart(isSecondary: true), at: .init(row: 6, column: 0))
        tracker.receive(.commandExecuted, at: .init(row: 7, column: 0))
        XCTAssertNil(tracker.activeInputRows)
        tracker.receive(.commandFinished(exitCode: 23), at: .init(row: 9, column: 0))

        XCTAssertEqual(tracker.commands.count, 1)
        XCTAssertEqual(tracker.commands[0].secondaryPromptRows, [6])
        XCTAssertEqual(tracker.commands[0].exitCode, 23)
        XCTAssertEqual(tracker.commands[0].finishedAt?.row, 9)
    }

    func testSemanticDecorationsClipToViewportAndReflectCommandStatus() {
        var tracker = TerminalSemanticTracker()
        tracker.receive(.promptStart(isSecondary: false), at: .init(row: 4, column: 0))
        tracker.receive(.commandStart, at: .init(row: 4, column: 2))
        tracker.receive(.commandExecuted, at: .init(row: 4, column: 7))
        tracker.receive(.commandFinished(exitCode: 0), at: .init(row: 8, column: 0))
        tracker.receive(.promptStart(isSecondary: false), at: .init(row: 9, column: 0))
        tracker.receive(.commandStart, at: .init(row: 9, column: 2))
        tracker.receive(.commandExecuted, at: .init(row: 9, column: 6))

        XCTAssertEqual(
            tracker.decorations(viewportTop: 6, rowCount: 4),
            [
                TerminalSemanticDecoration(
                    startViewportRow: 0,
                    endViewportRow: 2,
                    phase: .succeeded
                ),
                TerminalSemanticDecoration(
                    startViewportRow: 3,
                    endViewportRow: 3,
                    phase: .running
                ),
            ]
        )
        XCTAssertTrue(tracker.decorations(viewportTop: 20, rowCount: 4).isEmpty)
        XCTAssertTrue(tracker.decorations(viewportTop: 0, rowCount: 0).isEmpty)
    }

    func testSemanticTrackerDropsAbortedInputAndPrunesBoundedHistory() {
        var tracker = TerminalSemanticTracker()
        tracker.receive(.promptStart(isSecondary: false), at: .init(row: 1, column: 0))
        tracker.receive(.commandStart, at: .init(row: 1, column: 2))
        tracker.receive(.commandFinished(exitCode: nil), at: .init(row: 1, column: 5))
        XCTAssertTrue(tracker.commands.isEmpty, "D before C is an aborted edit, not a command")

        for row in 0..<(TerminalSemanticTracker.maximumCommands + 20) {
            let position = TerminalSemanticPosition(row: row, column: 0)
            tracker.receive(.promptStart(isSecondary: false), at: position)
            tracker.receive(.commandExecuted, at: position)
            tracker.receive(.commandFinished(exitCode: 0), at: position)
        }
        XCTAssertEqual(tracker.commands.count, TerminalSemanticTracker.maximumCommands)
        tracker.prune(before: 100)
        XCTAssertTrue(tracker.commands.allSatisfy { ($0.finishedAt?.row ?? -1) >= 100 })
    }

    func testSwiftTermCustomHandlerReconstructsSemanticMarksFromStream() {
        let view = makeView(Capture())
        view.configureSemanticPromptMarks()
        view.getTerminal().feed(text:
            osc133("A") + "$ " + osc133("B") + "printf hi" + osc133("C")
                + "\r\nhi\r\n" + osc133("D;0")
        )

        XCTAssertEqual(view.semanticTracker.commands.count, 1)
        XCTAssertEqual(view.semanticTracker.commands[0].exitCode, 0)
        XCTAssertNotNil(view.semanticTracker.commands[0].inputStart)
        XCTAssertNotNil(view.semanticTracker.commands[0].executedAt)
    }

    func testVSCodeOSC633LifecycleUsesTheSameBoundedSemanticIndex() {
        let view = makeView(Capture())
        view.configureSemanticPromptMarks()
        view.getTerminal().feed(text:
            osc633("A") + "$ " + osc633("B") + "printf hi" + osc633("C")
                + "\r\nhi\r\n" + osc633("D;0")
        )

        XCTAssertEqual(view.semanticTracker.commands.count, 1)
        XCTAssertEqual(view.semanticTracker.commands[0].exitCode, 0)
        XCTAssertNotNil(view.semanticTracker.commands[0].inputStart)
        XCTAssertNotNil(view.semanticTracker.commands[0].executedAt)
    }

    func testScrollInvariantCursorIgnoresScrolledBackViewport() {
        let view = makeView(Capture())
        view.changeScrollback(100)
        view.getTerminal().resize(cols: 20, rows: 5)
        view.getTerminal().feed(text: (0..<20).map { "line-\($0)\r\n" }.joined())
        view.scrollTo(row: 0, notifyAccessibility: false)

        let position = view.scrollInvariantCursorPosition()
        let viewportTop = view.getTerminal().buffer.totalLinesTrimmed
            + view.getTerminal().getTopVisibleRow()
        XCTAssertNotNil(position)
        XCTAssertGreaterThan(position?.row ?? 0, viewportTop)
    }

    func testSemanticPromptNavigationMovesViewportWithoutPTYInput() {
        let capture = Capture()
        let view = makeView(capture)
        view.changeScrollback(100)
        view.getTerminal().resize(cols: 40, rows: 5)
        view.configureSemanticPromptMarks()
        for index in 0..<3 {
            view.getTerminal().feed(text:
                osc133("A") + "$ " + osc133("B") + "command-\(index)" + osc133("C")
                    + "\r\n" + (0..<6).map { "output-\(index)-\($0)\r\n" }.joined()
                    + osc133("D;0")
            )
        }
        view.scrollToLiveBottom()

        let terminal = view.getTerminal()
        let first = terminal.buffer.totalLinesTrimmed
        let viewportTop = first + terminal.getTopVisibleRow()
        let expected = view.semanticTracker.previousPrompt(before: viewportTop + 1)
        XCTAssertNotNil(expected)
        XCTAssertTrue(view.navigateSemanticPrompt(backward: true))
        XCTAssertEqual(terminal.getTopVisibleRow(), (expected?.row ?? first) - first)

        let firstDestination = expected?.row ?? first
        let earlier = view.semanticTracker.previousPrompt(before: firstDestination)
        XCTAssertNotNil(earlier)
        XCTAssertTrue(view.navigateSemanticPrompt(backward: true))
        XCTAssertEqual(terminal.getTopVisibleRow(), (earlier?.row ?? first) - first)
        XCTAssertLessThan(earlier?.row ?? firstDestination, firstDestination)
        XCTAssertTrue(capture.sent.isEmpty, "semantic navigation must never write to the PTY")
    }

    func testSemanticMarksAreDiscardedWhenGridReflowChangesCoordinates() {
        let view = makeView(Capture())
        view.configureSemanticPromptMarks()
        view.getTerminal().feed(text:
            osc133("A") + "$ " + osc133("B") + "true" + osc133("C")
                + "\r\n" + osc133("D;0")
        )
        XCTAssertEqual(view.semanticTracker.commands.count, 1)

        let dimensions = view.getTerminal().getDims()
        view.getTerminal().resize(cols: dimensions.cols + 1, rows: dimensions.rows)
        view.reconcileSemanticPromptGrid()

        XCTAssertTrue(view.semanticTracker.commands.isEmpty)
    }

    func testSemanticHandlerSurvivesTerminalStateReset() {
        let view = makeView(Capture())
        view.configureSemanticPromptMarks()
        view.getTerminal().feed(text:
            osc133("A") + "$ " + osc133("B") + "first" + osc133("C")
                + "\r\n" + osc133("D;0")
        )
        XCTAssertEqual(view.semanticTracker.commands.count, 1)

        view.resetSemanticPromptMarks()
        view.getTerminal().resetToInitialState()
        view.getTerminal().feed(text:
            osc133("A") + "$ " + osc133("B") + "second" + osc133("C")
                + "\r\n" + osc133("D;0")
        )

        XCTAssertEqual(view.semanticTracker.commands.count, 1)
        XCTAssertEqual(view.semanticTracker.commands[0].exitCode, 0)
    }

    func testSemanticVerticalOptionClickMovesOnlyInsideActiveInputRows() {
        let capture = Capture()
        let view = makeView(capture)
        view.configureSemanticPromptMarks()
        view.getTerminal().feed(text: osc133("A") + "$ " + osc133("B") + "first\r\nsecond")
        view.observeSemanticPromptCursor()
        XCTAssertEqual(view.semanticTracker.activeInputRows?.count, 2)

        let dims = view.getTerminal().getDims()
        let optimal = view.getOptimalFrameSize().size
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: view.scrollerStyle)
        let cellWidth = (optimal.width - scroller) / CGFloat(dims.cols)
        let cellHeight = optimal.height / CGFloat(dims.rows)
        view.mouseUp(with: optionClick(at: NSPoint(
            x: cellWidth * 2.5,
            y: view.bounds.height - cellHeight * 0.5
        )))

        let up = Array(EscapeSequences.moveUpNormal)
        XCTAssertEqual(Array(capture.sent.prefix(up.count)), up)
        XCTAssertGreaterThan(capture.sent.count, up.count)
    }

    func testPlainClickIsLeftToSwiftTerm() {
        let capture = Capture()
        let view = makeView(capture)

        let plain = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 60, y: view.bounds.height - 1),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseUp(with: plain)
        XCTAssertTrue(capture.sent.isEmpty, "Only Option claims the click")
    }

    func testOptionWithAnotherModifierIsNotClaimed() {
        // ⌘⌥-click must keep whatever meaning the base emulator gives it.
        let capture = Capture()
        let view = makeView(capture)

        let combo = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 60, y: view.bounds.height - 1),
            modifierFlags: [.option, .command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        view.mouseUp(with: combo)
        XCTAssertTrue(capture.sent.isEmpty)
    }

    func testDoubleClickIsLeftToSelection() {
        let capture = Capture()
        let view = makeView(capture)
        view.mouseUp(with: optionClick(at: NSPoint(x: 60, y: view.bounds.height - 1), clickCount: 2))
        XCTAssertTrue(capture.sent.isEmpty, "Word selection must survive")
    }

    func testApplicationCursorModeUsesTheApplicationSequences() {
        let capture = Capture()
        let view = makeView(capture)
        // DECCKM — agent TUIs commonly enable it.
        view.getTerminal().feed(text: "\u{1B}[?1h")
        XCTAssertTrue(view.getTerminal().applicationCursor)

        let dims = view.getTerminal().getDims()
        let optimal = view.getOptimalFrameSize().size
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: view.scrollerStyle)
        let cellWidth = (optimal.width - scroller) / CGFloat(dims.cols)
        view.mouseUp(with: optionClick(at: NSPoint(x: cellWidth * 3.5, y: view.bounds.height - 1)))

        let expected = Array(EscapeSequences.moveRightApp)
        XCTAssertEqual(Array(capture.sent.prefix(expected.count)), expected)
    }
}
