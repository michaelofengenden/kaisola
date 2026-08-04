import XCTest
@testable import Kaisola

/// PR 12's remaining bullet: "history search remains responsive under streaming
/// output".
///
/// The retained deck's *memory* ceiling is covered by
/// `RetainedTerminalDeckAtScaleTests`. This is the other half — that searching
/// a deep history stays fast enough to type into, at the sizes the retention
/// policy actually permits.
///
/// `AppModel.maximumRetainedTerminalBytes` is 96 MiB across at most twelve
/// surfaces, and `TerminalDocument.maximumRetainedBytes` caps one document at
/// 16 MiB. A search that is fine on a short buffer and quadratic on a long one
/// passes casual use and stalls exactly when the history is worth searching, so
/// the shape is asserted as well as the time.
final class TranscriptSearchBudgetTests: XCTestCase {
    /// Pages of plausible terminal output — mixed lengths, occasional matches,
    /// so the search cannot win by rejecting every page on length alone.
    private func pages(count: Int, matchEvery: Int = 50) -> [String] {
        (0..<count).map { index in
            let body = (0..<12).map { line in
                "line \(index)-\(line) some ordinary terminal output with a few words on it"
            }.joined(separator: "\n")
            return index.isMultiple(of: matchEvery) ? body + "\nNEEDLE marker here" : body
        }
    }

    private func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    /// A deep retained history must still answer a query fast enough that the
    /// count can update while the user is typing.
    func testSearchingADeepHistoryStaysResponsive() {
        let corpus = pages(count: 12_000)
        let bytes = corpus.reduce(0) { $0 + $1.utf8.count }
        XCTAssertGreaterThan(bytes, 8_000_000, "fixture should be a genuinely deep history")

        var matches = 0
        let duration = elapsed {
            matches = TerminalTranscriptSearch.matchCount(in: corpus, query: "NEEDLE")
        }
        XCTAssertEqual(matches, 240)
        XCTAssertLessThan(duration, 1.5, "searching ~8 MB took \(duration)s")
    }

    /// Streaming means the query is re-run as pages arrive, so the per-keystroke
    /// cost matters more than any single search: typing six characters must not
    /// cost six full-speed scans' worth of stall.
    func testTypingAQueryAcrossAStreamingBufferStaysWithinBudget() {
        let corpus = pages(count: 6_000)
        let typed = ["N", "NE", "NEE", "NEED", "NEEDL", "NEEDLE"]
        let duration = elapsed {
            for query in typed {
                _ = TerminalTranscriptSearch.matchCount(in: corpus, query: query)
            }
        }
        XCTAssertLessThan(duration, 2.0, "six keystrokes over ~4 MB took \(duration)s")
    }

    /// Linear in the corpus, not quadratic — the difference between a search
    /// that scales to a saturated 16 MiB document and one that does not.
    func testSearchScalesRoughlyLinearly() {
        let small = pages(count: 2_000)
        let large = pages(count: 8_000)
        _ = TerminalTranscriptSearch.matchCount(in: pages(count: 100), query: "NEEDLE")

        let smallDuration = elapsed {
            _ = TerminalTranscriptSearch.matchCount(in: small, query: "NEEDLE")
        }
        let largeDuration = elapsed {
            _ = TerminalTranscriptSearch.matchCount(in: large, query: "NEEDLE")
        }
        guard smallDuration > 0.002 else { return }
        XCTAssertLessThan(
            largeDuration / smallDuration, 10,
            "4× the history cost \(largeDuration / smallDuration)× the time"
        )
    }

    /// An empty query is what the field holds most of the time — while closed,
    /// and between searches — so it must cost nothing rather than scanning.
    func testAnEmptyQueryIsFree() {
        let corpus = pages(count: 12_000)
        let duration = elapsed {
            _ = TerminalTranscriptSearch.matchCount(in: corpus, query: "")
        }
        XCTAssertLessThan(duration, 0.05, "an empty query scanned the buffer: \(duration)s")
    }
}
