import XCTest
@testable import Kaisola

/// PR 11's remaining acceptance, as a gate rather than a claim.
///
/// The implementation shipped in v1.1.9 — TextKit 2 read mode, off-main
/// structured-data preparation, bounded Markdown images. What was still open is
/// evidence: that these surfaces "retain native momentum without main-thread
/// parse or decode spikes" at the sizes the PR names.
///
/// The parsers are `nonisolated` by design, so the property that matters is not
/// *where* they run but *how long* they take: a preparation that blows its
/// budget stalls the surface whichever thread it is on, and one that silently
/// grows quadratically will pass at fixture size and stall on a real file.
/// Both are checked here.
///
/// The budgets are deliberately loose — several times the measured cost on this
/// machine — because a CI runner is slower and a flaky performance gate gets
/// deleted rather than fixed. They still catch the failure that matters: an
/// order-of-magnitude regression.
final class PreviewPreparationBudgetTests: XCTestCase {
    /// PR 11 names 1 MiB text as the size to hold.
    private static let megabyte = 1_024 * 1_024

    private func elapsed(_ work: () -> Void) -> TimeInterval {
        let start = Date()
        work()
        return Date().timeIntervalSince(start)
    }

    private func csv(rows: Int, columns: Int) -> String {
        (0..<rows).map { row in
            (0..<columns).map { "r\(row)c\($0)" }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    /// A wide, deep CSV — the shape that made the old synchronous path stutter.
    func testALargeCsvPreparesWithinBudget() {
        let text = csv(rows: 20_000, columns: 12)
        XCTAssertGreaterThan(text.utf8.count, Self.megabyte, "fixture must exceed PR 11's 1 MiB")

        var model: CsvPreviewModel?
        let duration = elapsed { model = CsvPreviewModel.make(text) }
        XCTAssertNotNil(model)
        XCTAssertLessThan(duration, 3.0, "1 MiB CSV took \(duration)s to prepare")
    }

    /// Cost must stay roughly proportional to input. A parser that is quadratic
    /// passes any single-size budget and then stalls on a real file, so the
    /// shape is asserted rather than one point on it.
    func testCsvPreparationScalesRoughlyLinearly() {
        let small = csv(rows: 4_000, columns: 12)
        let large = csv(rows: 16_000, columns: 12)

        // Warm any one-time cost so it is not charged to the small case.
        _ = CsvPreviewModel.make(csv(rows: 200, columns: 12))

        let smallDuration = elapsed { _ = CsvPreviewModel.make(small) }
        let largeDuration = elapsed { _ = CsvPreviewModel.make(large) }
        guard smallDuration > 0.002 else {
            return  // Too fast to measure meaningfully; the budget test covers it.
        }
        // 4× the input should cost well under 16× the time — that is the gap
        // between linear and quadratic, which is what this is looking for.
        XCTAssertLessThan(
            largeDuration / smallDuration,
            10,
            "4× the rows cost \(largeDuration / smallDuration)× the time — parsing may be superlinear"
        )
    }

    /// Deeply nested JSON is the structured-data case PR 11 names, and the one
    /// where a naive builder recurses per node.
    func testALargeJsonPreparesWithinBudget() throws {
        var value: [String: Any] = [:]
        for index in 0..<6_000 {
            value["key-\(index)"] = [
                "id": index,
                "name": "entry \(index)",
                "tags": ["alpha", "beta", "gamma"],
                "nested": ["a": ["b": ["c": index]]],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertGreaterThan(text.utf8.count, 500_000)

        var outcome: JsonPreviewOutcome?
        let duration = elapsed { outcome = JsonPreviewOutcome.make(text) }
        XCTAssertNotNil(outcome)
        XCTAssertLessThan(duration, 3.0, "large JSON took \(duration)s to prepare")
    }

    /// Malformed input must fail fast rather than degrading into a long parse —
    /// a preview that hangs on a bad file is worse than one that refuses it.
    func testMalformedJsonFailsFast() {
        let text = String(repeating: "{\"a\": [1, 2, ", count: 20_000)
        var outcome: JsonPreviewOutcome?
        let duration = elapsed { outcome = JsonPreviewOutcome.make(text) }
        XCTAssertNotNil(outcome)
        XCTAssertLessThan(duration, 1.0, "malformed JSON took \(duration)s to reject")
    }

    /// Delimiter detection reads the head of a file and must not scale with the
    /// whole of it — it runs before the parse, on the main thread's critical
    /// path to first paint.
    func testDelimiterDetectionDoesNotReadTheWholeFile() {
        let text = csv(rows: 60_000, columns: 12)
        let duration = elapsed { _ = CsvTable.detectDelimiter(text) }
        XCTAssertLessThan(
            duration, 0.25,
            "delimiter detection took \(duration)s — it should sample, not scan"
        )
    }
}
