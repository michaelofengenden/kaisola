import XCTest
@testable import KaisolaMacPreview

/// Word-level diff refinement: token math, pairing, and reconstruction.
final class AcpWordDiffTests: XCTestCase {
    func testWordTokensReconstructInput() {
        let samples = [
            "let x = 1",
            "  indented\tmixed  spacing ",
            "",
            "single",
            "trailing space ",
        ]
        for sample in samples {
            XCTAssertEqual(AcpDiff.wordTokens(sample).joined(), sample)
        }
    }

    func testSingleWordChangeIsIsolated() {
        let (removed, added) = AcpDiff.wordSegments(
            removed: "let count = 1",
            added: "let count = 2"
        )
        XCTAssertEqual(removed.map(\.text).joined(), "let count = 1")
        XCTAssertEqual(added.map(\.text).joined(), "let count = 2")
        XCTAssertEqual(removed.filter(\.changed).map(\.text), ["1"])
        XCTAssertEqual(added.filter(\.changed).map(\.text), ["2"])
    }

    func testIdenticalLinesHaveNoChangedSegments() {
        let (removed, added) = AcpDiff.wordSegments(removed: "same line", added: "same line")
        XCTAssertTrue(removed.allSatisfy { !$0.changed })
        XCTAssertTrue(added.allSatisfy { !$0.changed })
    }

    func testOversizedLineDiffSkipsQuadraticLCS() {
        // Beyond the line cap the diff must NOT build the O(m×n) table (which
        // would allocate ~GBs and freeze the UI); it returns every old line
        // removed then every new line added — bounded and non-freezing.
        let n = AcpDiff.lineDiffCap + 50
        let old = (0..<n).map { "old\($0)" }.joined(separator: "\n")
        let new = (0..<n).map { "new\($0)" }.joined(separator: "\n")
        let lines = AcpDiff.lines(old: old, new: new)
        XCTAssertEqual(lines.count, n * 2)
        XCTAssertEqual(lines.prefix(n).filter { $0.kind == .removed }.count, n)
        XCTAssertEqual(lines.suffix(n).filter { $0.kind == .added }.count, n)
    }

    func testOversizedLinesFallBackToWholeLineChange() {
        let long = Array(repeating: "word", count: AcpDiff.wordTokenCap + 1).joined(separator: " ")
        let (removed, added) = AcpDiff.wordSegments(removed: long, added: long + " extra")
        XCTAssertEqual(removed, [AcpDiff.Segment(text: long, changed: true)])
        XCTAssertEqual(added, [AcpDiff.Segment(text: long + " extra", changed: true)])
    }

    func testRowsPairRemovedWithFollowingAdded() {
        let rows = AcpDiff.rows(
            old: "alpha\nbeta one\ngamma",
            new: "alpha\nbeta two\ngamma"
        )
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].old, rows[0].new)
        XCTAssertNotNil(rows[1].old)
        XCTAssertNotNil(rows[1].new)
        XCTAssertEqual(rows[1].old?.filter(\.changed).map(\.text), ["one"])
        XCTAssertEqual(rows[1].new?.filter(\.changed).map(\.text), ["two"])
        XCTAssertEqual(rows[2].old, rows[2].new)
    }

    func testRowsLeftoverRemovalsAndAdditionsStayUnpaired() {
        // Two removals, one addition: first pair word-diffs, second removal
        // stands alone with no right side.
        let rows = AcpDiff.rows(old: "one\ntwo", new: "uno")
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotNil(rows[0].old)
        XCTAssertNotNil(rows[0].new)
        XCTAssertNotNil(rows[1].old)
        XCTAssertNil(rows[1].new)
    }

    func testRowsPureAdditionForFreshFile() {
        let rows = AcpDiff.rows(old: "", new: "a\nb")
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNil(row.old)
            XCTAssertEqual(row.new?.count, 1)
            XCTAssertEqual(row.new?.first?.changed, true)
        }
    }

    func testSegmentsCoalesceAdjacentRuns() {
        let (removed, _) = AcpDiff.wordSegments(
            removed: "totally different words here",
            added: "nothing shared at all!"
        )
        // Fully-changed line collapses into one segment, not one per token.
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.changed, true)
    }
}
