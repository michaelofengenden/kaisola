import SwiftTerm
import XCTest

final class SwiftTermStressTests: XCTestCase {
    func testLargeSustainedUnicodeStreamSurvivesScrollbackTrimAndResize() throws {
        let headless = HeadlessTerminal(
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 4_096),
            onEnd: { _ in }
        )
        let terminal = try XCTUnwrap(headless.terminal)

        for batch in 0..<64 {
            var output = ""
            output.reserveCapacity(32 * 1_024)
            for row in 0..<128 {
                output += String(format: "batch=%02d row=%03d café 日本 🙂\r\n", batch, row)
            }
            terminal.feed(text: output)
        }

        XCTAssertGreaterThan(terminal.buffer.totalLinesTrimmed, 0)
        terminal.resize(cols: 132, rows: 40)
        XCTAssertEqual(terminal.getDims().cols, 132)
        XCTAssertEqual(terminal.getDims().rows, 40)
        terminal.resize(cols: 80, rows: 24)
        terminal.feed(text: "final-marker café 日本 🙂")

        let finalLine = visibleLine(terminal, row: terminal.rows - 1)
        XCTAssertTrue(finalLine.contains("final-marker"))
        XCTAssertTrue(finalLine.contains("café"))
        XCTAssertTrue(finalLine.contains("🙂"))
        // SwiftTerm's public character accessor omits continuation cells for
        // some double-width scripts. The cursor proves both CJK scalars and
        // the emoji retained their terminal widths across resize/reflow.
        XCTAssertEqual(terminal.buffer.x, 25)
    }

    func testSplitUTF8AndAnsiModesRemainCoherent() throws {
        let headless = HeadlessTerminal(
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 500),
            onEnd: { _ in }
        )
        let terminal = try XCTUnwrap(headless.terminal)

        terminal.feed(text: "\u{1B}[?2004h\u{1B}[?1h\u{1B}[?1000h")
        XCTAssertTrue(terminal.bracketedPasteMode)
        XCTAssertTrue(terminal.applicationCursor)
        XCTAssertNotEqual(terminal.mouseMode, .off)

        terminal.feed(text: "\u{1B}[?1049h")
        XCTAssertTrue(terminal.isCurrentBufferAlternate)
        terminal.feed(text: "alternate-screen")
        terminal.feed(text: "\u{1B}[?1049l")
        XCTAssertFalse(terminal.isCurrentBufferAlternate)

        let splitScalar = Array("🙂".utf8)
        terminal.feed(buffer: splitScalar[0..<2])
        terminal.feed(buffer: splitScalar[2..<splitScalar.count])
        XCTAssertEqual(terminal.buffer.x, 2)
        terminal.feed(text: " split-marker")
        let line = visibleLine(terminal, row: terminal.buffer.y)
        XCTAssertTrue(line.contains("split-marker"))

        terminal.feed(text: "\u{1B}[?2004l\u{1B}[?1l\u{1B}[?1000l")
        XCTAssertFalse(terminal.bracketedPasteMode)
        XCTAssertFalse(terminal.applicationCursor)
        XCTAssertEqual(terminal.mouseMode, .off)
    }

    private func visibleLine(_ terminal: Terminal, row: Int) -> String {
        (0..<terminal.cols)
            .compactMap { terminal.getCharacter(col: $0, row: row) }
            .map(String.init)
            .joined()
    }
}
