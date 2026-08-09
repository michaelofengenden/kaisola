import Foundation
import XCTest
@testable import Kaisola

/// `CsvTable` (RFC-4180-ish parsing + delimiter detection) and `JsonTree` (the
/// bounded display-tree builder) — the pure cores behind the CSV/JSON preview
/// views. No WKWebView / SwiftUI is exercised here.
final class DataPreviewsTests: XCTestCase {

    // MARK: - CSV parsing

    func testParsesSimpleRows() {
        let (rows, truncation) = CsvTable.parse("a,b,c\n1,2,3")
        XCTAssertEqual(rows, [["a", "b", "c"], ["1", "2", "3"]])
        XCTAssertFalse(truncation.isTruncated)
    }

    func testQuotedFieldWithEmbeddedCommaAndNewline() {
        let (rows, _) = CsvTable.parse("name,note\n\"Doe, Jane\",\"line1\nline2\"")
        XCTAssertEqual(rows, [["name", "note"], ["Doe, Jane", "line1\nline2"]])
    }

    func testEscapedQuotesInsideQuotedField() {
        // Source field: "He said ""hi"""  ->  He said "hi"
        let (rows, _) = CsvTable.parse("q\n\"He said \"\"hi\"\"\"")
        XCTAssertEqual(rows, [["q"], ["He said \"hi\""]])
    }

    func testMidFieldQuoteIsLiteralAndDoesNotSwallowRest() {
        // A stray quote NOT at field start (3"5) is a literal character; it must
        // not open a quoted field that eats every later delimiter/newline.
        let (rows, _) = CsvTable.parse("a,b\n3\"5,tail\nx,y")
        XCTAssertEqual(rows, [["a", "b"], ["3\"5", "tail"], ["x", "y"]])
    }

    func testCRLFLineEndings() {
        let (rows, _) = CsvTable.parse("a,b\r\n1,2\r\n")
        XCTAssertEqual(rows, [["a", "b"], ["1", "2"]])
    }

    func testTrailingNewlineDoesNotAddEmptyRow() {
        let (rows, _) = CsvTable.parse("a\nb\n")
        XCTAssertEqual(rows, [["a"], ["b"]])
    }

    func testTrailingEmptyFieldIsPreserved() {
        let (rows, _) = CsvTable.parse("a,")
        XCTAssertEqual(rows, [["a", ""]])
    }

    func testEmptyInputYieldsNoRows() {
        let (rows, truncation) = CsvTable.parse("")
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(truncation.isTruncated)
        XCTAssertNil(truncation.noticeText)
    }

    func testSemicolonDelimiterParsing() {
        let (rows, _) = CsvTable.parse("a;b;c", delimiter: ";")
        XCTAssertEqual(rows, [["a", "b", "c"]])
    }

    // MARK: - CSV caps

    /// A `rows` × `columns` document with distinct cells, so a cap that fires
    /// shows up in the parsed shape instead of hiding behind repeated values.
    private func grid(rows: Int, columns: Int) -> String {
        (0..<rows)
            .map { row in (0..<columns).map { "r\(row)c\($0)" }.joined(separator: ",") }
            .joined(separator: "\n")
    }

    func testRowCapReportsRowCountsAndSaysNothingAboutColumns() {
        let (rows, truncation) = CsvTable.parse(grid(rows: CsvTable.maxRows + 500, columns: 3))
        XCTAssertEqual(rows.count, CsvTable.maxRows)
        XCTAssertTrue(truncation.rowsTruncated)
        XCTAssertFalse(truncation.columnsTruncated)
        XCTAssertEqual(truncation.totalRows, CsvTable.maxRows + 500)
        XCTAssertEqual(truncation.displayedRows, CsvTable.maxRows)
        XCTAssertEqual(truncation.totalColumns, 3)
        XCTAssertEqual(truncation.displayedColumns, 3)
        XCTAssertEqual(
            truncation.noticeText,
            "Showing the first \(CsvTable.maxRows) of \(CsvTable.maxRows + 500) rows "
                + "(preview caps at \(CsvTable.maxRows) rows)."
        )
    }

    func testColumnCapReportsColumnCountsAndNeverImpliesMissingRows() {
        let (rows, truncation) = CsvTable.parse(grid(rows: 4, columns: CsvTable.maxCols + 30))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first?.count, CsvTable.maxCols)
        XCTAssertFalse(truncation.rowsTruncated)
        XCTAssertTrue(truncation.columnsTruncated)
        XCTAssertEqual(truncation.totalRows, 4)
        XCTAssertEqual(truncation.displayedRows, 4)
        XCTAssertEqual(truncation.totalColumns, CsvTable.maxCols + 30)
        XCTAssertEqual(truncation.displayedColumns, CsvTable.maxCols)
        // Every row is on screen: the notice must not mention rows or the row
        // cap at all, which is what the old single-flag wording always did.
        XCTAssertEqual(
            truncation.noticeText,
            "Showing the first \(CsvTable.maxCols) of \(CsvTable.maxCols + 30) columns "
                + "(preview caps at \(CsvTable.maxCols) columns)."
        )
        XCTAssertFalse(truncation.noticeText?.contains("rows") ?? true)
    }

    func testBothCapsReportEachDimensionSeparately() {
        let (rows, truncation) = CsvTable.parse(
            grid(rows: CsvTable.maxRows + 7, columns: CsvTable.maxCols + 5)
        )
        XCTAssertEqual(rows.count, CsvTable.maxRows)
        XCTAssertEqual(rows.first?.count, CsvTable.maxCols)
        XCTAssertTrue(truncation.rowsTruncated)
        XCTAssertTrue(truncation.columnsTruncated)
        XCTAssertEqual(truncation.totalRows, CsvTable.maxRows + 7)
        XCTAssertEqual(truncation.totalColumns, CsvTable.maxCols + 5)
        XCTAssertEqual(
            truncation.noticeText,
            "Showing the first \(CsvTable.maxRows) of \(CsvTable.maxRows + 7) rows "
                + "and the first \(CsvTable.maxCols) of \(CsvTable.maxCols + 5) columns "
                + "(preview caps at \(CsvTable.maxRows) rows × \(CsvTable.maxCols) columns)."
        )
    }

    func testExactCapBoundaryIsNotTruncated() {
        let (rows, truncation) = CsvTable.parse(
            grid(rows: CsvTable.maxRows, columns: CsvTable.maxCols)
        )
        XCTAssertEqual(rows.count, CsvTable.maxRows)
        XCTAssertEqual(rows.first?.count, CsvTable.maxCols)
        XCTAssertFalse(truncation.isTruncated)
        XCTAssertEqual(truncation.totalRows, CsvTable.maxRows)
        XCTAssertEqual(truncation.totalColumns, CsvTable.maxCols)
        XCTAssertNil(truncation.noticeText)
    }

    func testWideRowPastTheRowCapDoesNotClaimMissingColumns() {
        // The wide record is dropped whole by the row cap, so the table really
        // does show every column it has; only the row count was cut.
        let wideTail = (0..<(CsvTable.maxCols + 10)).map { "w\($0)" }.joined(separator: ",")
        let (_, truncation) = CsvTable.parse(
            grid(rows: CsvTable.maxRows, columns: 3) + "\n" + wideTail
        )
        XCTAssertTrue(truncation.rowsTruncated)
        XCTAssertFalse(truncation.columnsTruncated)
        XCTAssertEqual(truncation.totalRows, CsvTable.maxRows + 1)
        XCTAssertEqual(truncation.totalColumns, 3)
        XCTAssertEqual(truncation.displayedColumns, 3)
    }

    func testWithinCapsIsNotTruncated() {
        let text = (0..<10).map { "\($0),x,y" }.joined(separator: "\n")
        let (rows, truncation) = CsvTable.parse(text)
        XCTAssertEqual(rows.count, 10)
        XCTAssertFalse(truncation.isTruncated)
        XCTAssertNil(truncation.noticeText)
    }

    func testRaggedRowsReportTheWidestRowAsTheColumnCount() {
        let (_, truncation) = CsvTable.parse("a\nb,c,d\ne,f")
        XCTAssertEqual(truncation.totalRows, 3)
        XCTAssertEqual(truncation.totalColumns, 3)
        XCTAssertEqual(truncation.displayedColumns, 3)
        XCTAssertFalse(truncation.isTruncated)
    }

    // MARK: - Delimiter detection

    func testDetectsSemicolonDelimiter() {
        XCTAssertEqual(CsvTable.detectDelimiter("a;b;c\n1;2;3"), ";")
    }

    func testDetectsTabDelimiter() {
        XCTAssertEqual(CsvTable.detectDelimiter("a\tb\tc"), "\t")
    }

    func testDefaultsToCommaWhenAmbiguous() {
        XCTAssertEqual(CsvTable.detectDelimiter("a,b,c"), ",")
        XCTAssertEqual(CsvTable.detectDelimiter("single-column"), ",")
    }

    func testDetectionIgnoresDelimitersInsideQuotes() {
        // The commas live inside a quoted field; the real delimiter is a semicolon.
        XCTAssertEqual(CsvTable.detectDelimiter("\"a,b,c,d\";x;y"), ";")
    }

    func testDetectionUsesFirstNonEmptyLine() {
        XCTAssertEqual(CsvTable.detectDelimiter("\n\na;b;c"), ";")
    }

    // MARK: - JSON tree building

    private func object(from json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    func testBuildsLabeledTreeForNestedFixture() throws {
        let root = JsonTree.build(try object(from: """
        {"name":"Kai","tags":["a","b"],"meta":{"n":1,"ok":true,"missing":null}}
        """))

        XCTAssertEqual(root.kind, .object)
        XCTAssertEqual(root.display, "{3}")   // object summary shows child count

        let byKey = Dictionary(uniqueKeysWithValues: root.children.map { ($0.key ?? "", $0) })

        // Object keys become node labels; scalar values keep their kind + text.
        XCTAssertEqual(byKey["name"]?.kind, .string)
        XCTAssertEqual(byKey["name"]?.display, "Kai")

        // Arrays are labeled `[n]` with `[index]`-keyed children.
        let tags = byKey["tags"]
        XCTAssertEqual(tags?.kind, .array)
        XCTAssertEqual(tags?.display, "[2]")
        XCTAssertEqual(tags?.children.map(\.key), ["[0]", "[1]"])
        XCTAssertEqual(tags?.children.map(\.display), ["a", "b"])

        // bool / number / null are distinguished.
        let meta = byKey["meta"]
        let metaByKey = Dictionary(uniqueKeysWithValues: (meta?.children ?? []).map { ($0.key ?? "", $0) })
        XCTAssertEqual(metaByKey["ok"]?.kind, .bool)
        XCTAssertEqual(metaByKey["ok"]?.display, "true")
        XCTAssertEqual(metaByKey["n"]?.kind, .number)
        XCTAssertEqual(metaByKey["n"]?.display, "1")
        XCTAssertEqual(metaByKey["missing"]?.kind, .null)
        XCTAssertEqual(metaByKey["missing"]?.display, "null")
    }

    func testTotalNodesCountsWholeTree() throws {
        // root(object) + a(number) + b(array) + b[0] + b[1] = 5
        let root = JsonTree.build(try object(from: #"{"a":1,"b":[10,20]}"#))
        XCTAssertEqual(root.totalNodes, 5)
        XCTAssertFalse(root.containsTruncation)
    }

    func testNodeCapTruncatesLargeTree() throws {
        let bigArray = "[" + (0..<(JsonTree.maxNodes + 3_000)).map(String.init).joined(separator: ",") + "]"
        let root = JsonTree.build(try object(from: bigArray))
        XCTAssertTrue(root.containsTruncation)
        // Real nodes are capped; only a handful of markers may spill past.
        XCTAssertLessThanOrEqual(root.totalNodes, JsonTree.maxNodes + 2)
        XCTAssertTrue(root.children.contains { $0.isTruncationMarker })
    }

    func testDepthCapInsertsMarker() throws {
        // 20 nested single-element arrays exceed the depth cap (12).
        let deep = String(repeating: "[", count: 20) + "0" + String(repeating: "]", count: 20)
        let root = JsonTree.build(try object(from: deep))
        XCTAssertTrue(root.containsTruncation)
        XCTAssertLessThan(root.totalNodes, 25)   // depth cap, not the node cap, fired
    }

    func testScalarRootIsSupported() throws {
        let root = JsonTree.build(try object(from: "\"hello\""))
        XCTAssertEqual(root.kind, .string)
        XCTAssertEqual(root.display, "hello")
        XCTAssertTrue(root.children.isEmpty)
    }

    // MARK: - JSON node identity

    private func identifiers(of node: JsonTree.Node) -> [String] {
        [node.id] + node.children.flatMap(identifiers(of:))
    }

    func testNodeIdentityIsTheDeterministicPathToTheValue() throws {
        let root = JsonTree.build(try object(from: #"{"tags":["a","b"],"meta":{"n":1}}"#))
        XCTAssertEqual(root.id, "$")

        let byKey = Dictionary(uniqueKeysWithValues: root.children.map { ($0.key ?? "", $0) })
        XCTAssertEqual(byKey["tags"]?.id, "$.tags")
        XCTAssertEqual(byKey["tags"]?.children.map(\.id), ["$.tags[0]", "$.tags[1]"])
        XCTAssertEqual(byKey["meta"]?.children.map(\.id), ["$.meta.n"])
    }

    func testNodeIdentityIsStableAcrossRebuilds() throws {
        // Disclosure state is keyed by node identity. A rebuilt tree — a
        // re-render, a reload, a returning tab — must reuse the same ids or
        // every expanded object silently snaps shut.
        let json = #"{"name":"Kai","tags":["a","b"],"meta":{"n":1,"ok":true}}"#
        XCTAssertEqual(
            identifiers(of: JsonTree.build(try object(from: json))),
            identifiers(of: JsonTree.build(try object(from: json)))
        )
    }

    func testNodeIdentitiesAreUniqueThroughoutTheTree() throws {
        let json = #"{"a":{"b":[{"c":1},{"c":2}]},"d":[[1,2],[3,4]],"e":"a.b"}"#
        let ids = identifiers(of: JsonTree.build(try object(from: json)))
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTruncationMarkersCarryDistinctIdentities() throws {
        let bigArray = "[" + (0..<(JsonTree.maxNodes + 50)).map(String.init).joined(separator: ",") + "]"
        let ids = identifiers(of: JsonTree.build(try object(from: bigArray)))
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains { $0.hasSuffix("|truncated") })
    }

    // MARK: - Content-identity parse caches

    func testParseCacheReusesTheResultForIdenticalContent() async {
        let cache = PreviewParseCache<Int>()
        let source = String(repeating: "a,b,c\n", count: 500)

        // Ten body evaluations — a tab-strip hover, a resize, a zoom step —
        // must cost exactly one parse.
        for _ in 0..<10 {
            _ = await cache.value(for: source) { $0.count }
        }
        let parseCount = await cache.parseCount
        XCTAssertEqual(parseCount, 1)
    }

    func testParseCacheReparsesOnlyWhenContentChanges() async {
        let cache = PreviewParseCache<String>()
        let uppercase: @Sendable (String) -> String = { $0.uppercased() }

        let first = await cache.value(for: "one", parse: uppercase)
        let repeated = await cache.value(for: "one", parse: uppercase)
        let firstCount = await cache.parseCount
        let changed = await cache.value(for: "two", parse: uppercase)
        let changedCount = await cache.parseCount
        XCTAssertEqual(first, "ONE")
        XCTAssertEqual(repeated, "ONE")
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(changed, "TWO")
        XCTAssertEqual(changedCount, 2)
    }

    func testCsvPreviewModelIsBuiltOncePerContentIdentity() async {
        let text = (0..<300).map { "row\($0),value,\($0)" }.joined(separator: "\n")
        let cache = PreviewParseCache<CsvPreviewModel>()

        let first = await cache.value(for: text, parse: CsvPreviewModel.make)
        let second = await cache.value(for: text, parse: CsvPreviewModel.make)
        let parseCount = await cache.parseCount
        XCTAssertEqual(parseCount, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.rows.count, 300)
        XCTAssertFalse(first.truncation.isTruncated)
    }

    func testCsvPreviewModelColumnWidthsFitTheLongestCellWithinBounds() {
        let model = CsvPreviewModel.make("id,label\n1,\(String(repeating: "x", count: 400))")
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.columnWidths.count, 2)
        // A short column collapses to the floor; a very long one is clamped at
        // the ceiling instead of realizing an unbounded row.
        XCTAssertEqual(model.columnWidths[0], CsvPreviewModel.minimumColumnWidth)
        XCTAssertEqual(model.columnWidths[1], CsvPreviewModel.maximumColumnWidth)
    }

    func testCsvPreviewModelCarriesPerDimensionTruncation() {
        let rowCapped = CsvPreviewModel.make(grid(rows: CsvTable.maxRows + 10, columns: 2))
        XCTAssertTrue(rowCapped.truncation.rowsTruncated)
        XCTAssertFalse(rowCapped.truncation.columnsTruncated)
        XCTAssertEqual(rowCapped.truncation.totalRows, CsvTable.maxRows + 10)

        let columnCapped = CsvPreviewModel.make(grid(rows: 3, columns: CsvTable.maxCols + 8))
        XCTAssertFalse(columnCapped.truncation.rowsTruncated)
        XCTAssertTrue(columnCapped.truncation.columnsTruncated)
        XCTAssertEqual(columnCapped.truncation.totalColumns, CsvTable.maxCols + 8)
        // The rendered grid is exactly as wide as the notice claims.
        XCTAssertEqual(columnCapped.columnWidths.count, columnCapped.truncation.displayedColumns)
    }

    func testJsonPreviewOutcomeIsBuiltOncePerContentIdentity() async {
        let text = #"{"a":[1,2,3],"b":{"c":true}}"#
        let cache = PreviewParseCache<JsonPreviewOutcome>()

        _ = await cache.value(for: text, parse: JsonPreviewOutcome.make)
        let outcome = await cache.value(for: text, parse: JsonPreviewOutcome.make)
        let parseCount = await cache.parseCount
        XCTAssertEqual(parseCount, 1)
        guard case let .tree(root, truncated) = outcome else {
            return XCTFail("expected a parsed tree")
        }
        XCTAssertEqual(root.children.count, 2)
        XCTAssertFalse(truncated)
    }

    func testJsonPreviewOutcomeReportsInvalidDocuments() {
        guard case .invalid = JsonPreviewOutcome.make("{oops") else {
            return XCTFail("expected an invalid outcome")
        }
    }

    func testPreviewParseIdentityTracksDiskSnapshotAndExplicitReload() {
        let first = PreviewParseIdentity(
            path: "/project/report.json",
            modificationDate: Date(timeIntervalSince1970: 10),
            revision: 0
        )
        XCTAssertEqual(first, first)
        XCTAssertNotEqual(
            first,
            PreviewParseIdentity(
                path: first.path,
                modificationDate: Date(timeIntervalSince1970: 11),
                revision: first.revision
            )
        )
        XCTAssertNotEqual(
            first,
            PreviewParseIdentity(
                path: first.path,
                modificationDate: first.modificationDate,
                revision: 1
            )
        )
    }

    func testNearLimitStructuredPreparationIsBoundedAndCached() async {
        let csvRow = "00000000,alpha,beta,gamma\n"
        let csv = String(
            repeating: csvRow,
            count: 900_000 / csvRow.utf8.count
        )
        XCTAssertGreaterThan(csv.utf8.count, 850_000)
        XCTAssertLessThan(csv.utf8.count, FilePreviewContent.maxTextBytes)

        let csvCache = PreviewParseCache<CsvPreviewModel>()
        let csvStart = ContinuousClock.now
        let csvModel = await csvCache.value(for: csv, parse: CsvPreviewModel.make)
        let csvElapsed = csvStart.duration(to: .now)
        _ = await csvCache.value(for: csv, parse: CsvPreviewModel.make)
        let csvParseCount = await csvCache.parseCount
        XCTAssertTrue(csvModel.truncation.rowsTruncated)
        XCTAssertEqual(csvParseCount, 1)
        XCTAssertLessThan(csvElapsed, .seconds(3.5))

        let jsonElement = #""0123456789abcdef","#
        let jsonBody = String(
            repeating: jsonElement,
            count: 900_000 / jsonElement.utf8.count
        )
        let json = "[" + String(jsonBody.dropLast()) + "]"
        XCTAssertGreaterThan(json.utf8.count, 850_000)
        XCTAssertLessThan(json.utf8.count, FilePreviewContent.maxTextBytes)

        let jsonCache = PreviewParseCache<JsonPreviewOutcome>()
        let jsonStart = ContinuousClock.now
        let outcome = await jsonCache.value(for: json, parse: JsonPreviewOutcome.make)
        let jsonElapsed = jsonStart.duration(to: .now)
        _ = await jsonCache.value(for: json, parse: JsonPreviewOutcome.make)
        let jsonParseCount = await jsonCache.parseCount
        guard case let .tree(root, truncated) = outcome else {
            return XCTFail("expected a parsed near-limit JSON tree")
        }
        XCTAssertFalse(root.children.isEmpty)
        XCTAssertTrue(truncated)
        XCTAssertEqual(jsonParseCount, 1)
        XCTAssertLessThan(jsonElapsed, .seconds(3.5))
    }
}
