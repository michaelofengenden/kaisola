import XCTest
@testable import Kaisola

/// The incremental pass's range arithmetic: plain paragraphs pass through,
/// table-touching ranges widen to the whole table region, overlaps merge.
final class MarkdownIncrementalStyleTests: XCTestCase {
    func testRangesPassThroughWhenNoTableIntersects() {
        let source = "alpha\n\nbeta\n" as NSString
        let ranges = MarkdownIncrementalStyle.rangesToRestyle(
            changed: [NSRange(location: 0, length: 6)], tables: [], in: source
        )
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 6)])
    }

    func testTableIntersectionExtendsToWholeTableRegion() {
        let source = "| a | b |\n| - | - |\n| 1 | 2 |\ntail\n"
        let tables = MarkdownTableRegions.scan(source)
        XCTAssertFalse(tables.isEmpty, "fixture table was not recognized")
        let ranges = MarkdownIncrementalStyle.rangesToRestyle(
            changed: [NSRange(location: 10, length: 5)],
            tables: tables,
            in: source as NSString
        )
        XCTAssertEqual(ranges.first, tables.first?.range)
    }

    func testOverlappingChangedRangesMerge() {
        let source = "one two three four\n" as NSString
        let ranges = MarkdownIncrementalStyle.rangesToRestyle(
            changed: [NSRange(location: 0, length: 8), NSRange(location: 4, length: 10)],
            tables: [],
            in: source
        )
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 14)])
    }
}
