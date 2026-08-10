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
    func testDelimiterDetectionDoesNotReadTheWholeFile() throws {
        let text = csv(rows: 60_000, columns: 12)
        var measuredDetection: CsvTable.DelimiterDetection?
        let duration = elapsed { measuredDetection = CsvTable.delimiterSample(in: text) }
        let detection = try XCTUnwrap(measuredDetection)

        XCTAssertEqual(detection.delimiter, ",")
        XCTAssertLessThan(
            detection.inspectedByteCount,
            256,
            "the first record is short, so the multi-megabyte tail must remain unread"
        )
        XCTAssertLessThanOrEqual(
            detection.inspectedByteCount,
            CsvTable.delimiterSampleByteLimit
        )
        XCTAssertLessThan(
            duration, 0.25,
            "delimiter detection took \(duration)s — it should sample, not scan"
        )
    }

    /// Even a malformed export with no record separator must leave the main
    /// thread after one fixed-size sample instead of turning delimiter guessing
    /// into another whole-file parse.
    func testDelimiterDetectionCapsAPathologicalFirstRecord() {
        let text = String(repeating: "field;", count: 100_000)
        let detection = CsvTable.delimiterSample(in: text)

        XCTAssertEqual(detection.delimiter, ";")
        XCTAssertEqual(detection.inspectedByteCount, CsvTable.delimiterSampleByteLimit)
        XCTAssertLessThan(detection.inspectedByteCount, text.utf8.count)
    }

    // MARK: - Markdown

    /// An image-heavy Markdown document is the remaining surface PR 11 names.
    /// Parsing must stay bounded by the *document*, not by what its images
    /// would cost to decode — the decode is the renderer's job and is bounded
    /// separately.
    func testImageHeavyMarkdownParsesWithinBudget() {
        var lines: [String] = []
        for index in 0..<1_500 {
            lines.append("## Section \(index)")
            lines.append("")
            lines.append("![figure \(index)](assets/figure-\(index).png)")
            lines.append("")
            lines.append("Body text for section \(index), long enough to be a real paragraph "
                + "rather than a token, so the parser walks inline content as it would on a "
                + "genuine document.")
            lines.append("")
        }
        let source = lines.joined(separator: "\n")
        XCTAssertGreaterThan(source.utf8.count, 200_000)

        var document: MarkdownDocument?
        let duration = elapsed { document = MarkdownDocument.parse(source) }
        XCTAssertNotNil(document)
        XCTAssertLessThan(
            duration, 3.0,
            "image-heavy Markdown took \(duration)s to parse"
        )
    }

    /// Sizing an image is called per image per layout pass, so it has to be
    /// arithmetic rather than anything that touches the file.
    func testImageSizingIsPureArithmetic() {
        let duration = elapsed {
            for index in 0..<200_000 {
                _ = MarkdownPreviewLayout.imageSize(
                    intrinsicSize: CGSize(width: 1_600, height: 900),
                    declaredWidth: index.isMultiple(of: 2) ? 800 : nil,
                    declaredHeight: Double?.none,
                    availableWidth: 720,
                    zoom: 1
                )
            }
        }
        XCTAssertLessThan(duration, 1.0, "200k sizings took \(duration)s")
    }
}
