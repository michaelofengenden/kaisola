import AppKit
import SwiftTerm
import XCTest
@testable import Kaisola

/// Agent CLI output must never render duplicated.
///
/// Two independent defects produced the duplication:
///
/// 1. Incremental reconciliation bailed whenever the already-rendered byte
///    offset did not land on a Swift *grapheme cluster* boundary — and `\r\n` is
///    a single `Character`. Broker chunks split on codepoint boundaries and at
///    every raw PTY read, so a CRLF straddling a chunk boundary silently forced
///    a full clear-and-re-feed mid-session.
/// 2. That re-feed replays bytes carrying absolute cursor moves (`ESC[nA`) that
///    were computed against the width the PTY had when they were emitted. Replay
///    them into a narrower terminal and each redraw block wraps to more rows
///    than the cursor-up rewinds, leaving the top of the previous copy behind —
///    once per redraw. Panes only get narrower over a session, which is why the
///    artifact reads as duplication rather than loss.
@MainActor
final class TerminalReplayFidelityTests: XCTestCase {
    // MARK: - The boundary that used to force a re-feed

    /// Documents the exact Swift behaviour the old implementation depended on.
    /// If this ever starts passing at a grapheme boundary, the byte-slicing
    /// approach is still correct — but this records *why* it was needed.
    func testCRLFIsASingleCharacterSoByteOffsetsAreNotGraphemeBoundaries() {
        let transcript = "a\r\nb"
        XCTAssertEqual(transcript.count, 3, "\\r\\n is one Character in Swift")

        let utf8 = transcript.utf8
        let betweenCRandLF = utf8.index(utf8.startIndex, offsetBy: 2)
        XCTAssertNil(
            betweenCRandLF.samePosition(in: transcript),
            "A byte offset between CR and LF is not a Character boundary — this is what used to abort incremental reconciliation and trigger a full re-feed."
        )
    }

    func testEmojiWithVariationSelectorAlsoStraddles() {
        let transcript = "x⏺\u{FE0F}y"
        let utf8 = transcript.utf8
        // Between the glyph and its variation selector.
        let split = utf8.index(utf8.startIndex, offsetBy: 1 + 3)
        XCTAssertNil(split.samePosition(in: transcript))
    }

    // MARK: - Width-dependent replay

    private func feedTranscript(_ transcript: String, cols: Int, rows: Int = 40) -> Terminal {
        final class Sink: TerminalDelegate {
            func send(source: Terminal, data: ArraySlice<UInt8>) {}
        }
        let terminal = Terminal(delegate: Sink(), options: TerminalOptions(cols: cols, rows: rows))
        terminal.feed(text: transcript)
        return terminal
    }

    private func occurrences(of needle: String, in terminal: Terminal) -> Int {
        // `buffer.lines` is internal to SwiftTerm; `getBufferAsData` is the
        // public way to read what actually landed on screen.
        let data = terminal.getBufferAsData(kind: .active)
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: needle).count - 1
    }

    /// An agent-style in-place redraw: print a block, move the cursor back up,
    /// print it again. At the width it was produced for, the second copy
    /// overwrites the first.
    private func redrawTranscript(width: Int, redraws: Int) -> String {
        let body = String(repeating: "M", count: width - 10)
        var out = ""
        for _ in 0..<redraws {
            out += "MARKER \(body)\r\nline2\r\nline3\r\n"
            out += "\u{1B}[3A"
        }
        out += "MARKER \(body)\r\nline2\r\nline3\r\n"
        return out
    }

    func testReplayAtTheProducingWidthDoesNotDuplicate() {
        let transcript = redrawTranscript(width: 100, redraws: 3)
        let terminal = feedTranscript(transcript, cols: 100)
        XCTAssertEqual(
            occurrences(of: "MARKER", in: terminal), 1,
            "At the width the bytes were produced for, each redraw overwrites the last."
        )
    }

    func testReplayIntoANarrowerTerminalDuplicates() {
        // This is the regression this whole change exists to prevent. The same
        // bytes, replayed narrower, leave one surviving copy per redraw.
        let transcript = redrawTranscript(width: 100, redraws: 3)
        let terminal = feedTranscript(transcript, cols: 50)
        XCTAssertGreaterThan(
            occurrences(of: "MARKER", in: terminal), 1,
            "Replaying a wide transcript into a narrow terminal duplicates — which is why the parsed view must be retained across project switches instead of re-fed."
        )
    }

    // MARK: - Surface retention

    func testCacheHandsBackTheViewAndItsRenderStateTogether() {
        let cache = TerminalSurfaceCache.shared
        cache.removeAll()
        defer { cache.removeAll() }

        let view = ReadOnlyTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        let coordinator = NativeTerminalSurface.Coordinator()
        cache.store(sessionID: "t1", view: view, coordinator: coordinator)

        let claimed = cache.claim(sessionID: "t1")
        XCTAssertNotNil(claimed)
        XCTAssertTrue(claimed?.view === view)
        XCTAssertTrue(claimed?.coordinator === coordinator, "The pair must move together or the view is re-fed / left blank.")

        XCTAssertNil(cache.claim(sessionID: "t1"), "A claimed pair is removed, so two panes can't share one NSView.")
    }

    func testAViewStillInAWindowIsNotHandedOut() {
        let cache = TerminalSurfaceCache.shared
        cache.removeAll()
        defer { cache.removeAll() }

        let host = NSView(frame: .init(x: 0, y: 0, width: 100, height: 100))
        let view = ReadOnlyTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        host.addSubview(view)
        cache.store(sessionID: "t1", view: view, coordinator: NativeTerminalSurface.Coordinator())

        XCTAssertNil(
            cache.claim(sessionID: "t1"),
            "An NSView has one superview; reusing a mounted view would tear it out of the other pane."
        )
    }

    func testRetentionIsBounded() {
        let cache = TerminalSurfaceCache.shared
        cache.removeAll()
        defer { cache.removeAll() }

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let stored = TerminalSurfaceCache.maximumRetainedSurfaces + 4
        for index in 0..<stored {
            cache.store(
                sessionID: "t\(index)",
                view: ReadOnlyTerminalView(frame: .zero, font: font),
                coordinator: NativeTerminalSurface.Coordinator()
            )
        }
        XCTAssertEqual(cache.retainedSessionIDs.count, TerminalSurfaceCache.maximumRetainedSurfaces)
        XCTAssertNil(cache.claim(sessionID: "t0"), "Oldest surfaces are evicted first.")
        XCTAssertNotNil(cache.claim(sessionID: "t\(stored - 1)"), "Newest survives.")
    }

    func testEvictionDropsAnEndedSession() {
        let cache = TerminalSurfaceCache.shared
        cache.removeAll()
        defer { cache.removeAll() }

        cache.store(
            sessionID: "t1",
            view: ReadOnlyTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular)),
            coordinator: NativeTerminalSurface.Coordinator()
        )
        cache.evict(sessionID: "t1")
        XCTAssertNil(cache.claim(sessionID: "t1"))
    }
}
