import AppKit
import Foundation
import XCTest
@testable import Kaisola

/// `CsvTable` (RFC-4180-ish parsing + delimiter detection) and `JsonTree` (the
/// bounded display-tree builder) — the pure cores behind the CSV/JSON preview
/// views. No WKWebView / SwiftUI is exercised here.
final class DataPreviewsTests: XCTestCase {

    // MARK: - CSV parsing

    func testCsvHeaderModesResolveHeaderSemanticsAndDataRowNumbers() {
        let labeled = [["name", "age"], ["Ada", "36"], ["Grace", "37"]]
        let headerless = [["Ada", "36"], ["Grace", "37"]]

        let automatic = CsvHeaderResolution(mode: .automatic, rows: labeled)
        XCTAssertTrue(automatic.hasHeader)
        XCTAssertTrue(automatic.isHeader(rowIndex: 0))
        XCTAssertNil(automatic.dataRowNumber(rowIndex: 0))
        XCTAssertEqual(automatic.dataRowNumber(rowIndex: 1), 1)
        XCTAssertEqual(automatic.accessibilityLabel(rowIndex: 0, columnIndex: 1), "Header, column 2")
        XCTAssertEqual(automatic.accessibilityLabel(rowIndex: 1, columnIndex: 1), "Row 1, column 2")

        let conservativeAuto = CsvHeaderResolution(mode: .automatic, rows: headerless)
        XCTAssertFalse(conservativeAuto.hasHeader)
        XCTAssertEqual(conservativeAuto.dataRowNumber(rowIndex: 0), 1)

        let forcedHeader = CsvHeaderResolution(mode: .firstRowIsHeader, rows: headerless)
        XCTAssertTrue(forcedHeader.hasHeader)
        XCTAssertEqual(forcedHeader.dataRowNumber(rowIndex: 1), 1)
        XCTAssertEqual(
            CsvCellInspection(
                rowIndex: 0,
                columnIndex: 1,
                value: "36",
                rowAccessibilityLabel: "Header"
            ).accessibilityLabel,
            "Header, column 2"
        )

        let forcedData = CsvHeaderResolution(mode: .noHeader, rows: labeled)
        XCTAssertFalse(forcedData.hasHeader)
        XCTAssertEqual(forcedData.dataRowNumber(rowIndex: 0), 1)
        XCTAssertEqual(forcedData.accessibilityLabel(rowIndex: 0, columnIndex: 0), "Row 1, column 1")
    }

    func testCsvHeaderModeChoicesUseExactUserFacingNames() {
        XCTAssertEqual(CsvHeaderMode.allCases.map(\.title), [
            "Auto",
            "First Row Is Header",
            "No Header",
        ])
    }

    func testCsvHeaderPreferencePersistsPerPreviewWithoutStoringThePath() {
        let suite = "CsvHeaderPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstPath = "/private/tmp/Customer exports/people.csv"
        let secondPath = "/private/tmp/Customer exports/events.csv"

        var store = CsvHeaderPreferenceStore(defaults: defaults)
        XCTAssertEqual(store.mode(forPath: firstPath), .automatic)
        store.set(.noHeader, forPath: firstPath)
        store.set(.firstRowIsHeader, forPath: secondPath)

        store = CsvHeaderPreferenceStore(defaults: defaults)
        XCTAssertEqual(store.mode(forPath: firstPath), .noHeader)
        XCTAssertEqual(
            store.mode(forPath: "/private/tmp/Customer exports/archive/../people.csv"),
            .noHeader,
            "standardized aliases of the same preview must share one preference"
        )
        XCTAssertEqual(store.mode(forPath: secondPath), .firstRowIsHeader)
        XCTAssertFalse(
            defaults.dictionaryRepresentation().keys.contains { $0.contains(firstPath) },
            "the persisted key must not expose an absolute preview path"
        )

        store.set(.automatic, forPath: firstPath)
        XCTAssertEqual(CsvHeaderPreferenceStore(defaults: defaults).mode(forPath: firstPath), .automatic)
    }

    func testParsesSimpleRows() {
        let result = CsvTable.parse("a,b,c\n1,2,3")
        XCTAssertEqual(result.rows, [["a", "b", "c"], ["1", "2", "3"]])
        XCTAssertFalse(result.truncated)
    }

    func testQuotedFieldWithEmbeddedCommaAndNewline() {
        let result = CsvTable.parse("name,note\n\"Doe, Jane\",\"line1\nline2\"")
        XCTAssertEqual(result.rows, [["name", "note"], ["Doe, Jane", "line1\nline2"]])
    }

    func testEscapedQuotesInsideQuotedField() {
        // Source field: "He said ""hi"""  ->  He said "hi"
        let result = CsvTable.parse("q\n\"He said \"\"hi\"\"\"")
        XCTAssertEqual(result.rows, [["q"], ["He said \"hi\""]])
    }

    func testMidFieldQuoteIsLiteralAndDoesNotSwallowRest() {
        // A stray quote NOT at field start (3"5) is a literal character; it must
        // not open a quoted field that eats every later delimiter/newline.
        let result = CsvTable.parse("a,b\n3\"5,tail\nx,y")
        XCTAssertEqual(result.rows, [["a", "b"], ["3\"5", "tail"], ["x", "y"]])
    }

    func testCRLFLineEndings() {
        let result = CsvTable.parse("a,b\r\n1,2\r\n")
        XCTAssertEqual(result.rows, [["a", "b"], ["1", "2"]])
    }

    func testTrailingNewlineDoesNotAddEmptyRow() {
        let result = CsvTable.parse("a\nb\n")
        XCTAssertEqual(result.rows, [["a"], ["b"]])
    }

    func testTrailingEmptyFieldIsPreserved() {
        let result = CsvTable.parse("a,")
        XCTAssertEqual(result.rows, [["a", ""]])
    }

    func testEmptyInputYieldsNoRows() {
        let result = CsvTable.parse("")
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.truncation, .empty)
    }

    func testSemicolonDelimiterParsing() {
        let result = CsvTable.parse("a;b;c", delimiter: ";")
        XCTAssertEqual(result.rows, [["a", "b", "c"]])
    }

    // MARK: - CSV caps

    func testRowCapAndTruncatedFlag() {
        let text = (0..<(CsvTable.maxRows + 500)).map(String.init).joined(separator: "\n")
        let result = CsvTable.parse(text)
        XCTAssertEqual(result.rows.count, CsvTable.maxRows)
        XCTAssertTrue(result.truncated)
    }

    func testColumnCapAndTruncatedFlag() {
        let wideRow = (0..<(CsvTable.maxCols + 30)).map { "c\($0)" }.joined(separator: ",")
        let result = CsvTable.parse(wideRow)
        XCTAssertEqual(result.rows.first?.count, CsvTable.maxCols)
        XCTAssertTrue(result.truncated)
    }

    func testWithinCapsIsNotTruncated() {
        let text = (0..<10).map { "\($0),x,y" }.joined(separator: "\n")
        let result = CsvTable.parse(text)
        XCTAssertEqual(result.rows.count, 10)
        XCTAssertFalse(result.truncated)
    }

    func testRowOnlyTruncationReportsActualAndDisplayedCounts() {
        let text = (0...CsvTable.maxRows).map(String.init).joined(separator: "\n")
        let result = CsvTable.parse(text)

        XCTAssertEqual(result.truncation.actualRowCount, CsvTable.maxRows + 1)
        XCTAssertEqual(result.truncation.displayedRowCount, CsvTable.maxRows)
        XCTAssertEqual(result.truncation.actualColumnCount, 1)
        XCTAssertEqual(result.truncation.displayedColumnCount, 1)
        XCTAssertTrue(result.truncation.rowsWereTruncated)
        XCTAssertFalse(result.truncation.columnsWereTruncated)
        XCTAssertEqual(result.truncation.notice, "Showing 2000 of 2001 rows.")
    }

    func testColumnOnlyTruncationReportsActualAndDisplayedCounts() {
        let text = (0...CsvTable.maxCols).map { "c\($0)" }.joined(separator: ",")
        let result = CsvTable.parse(text)

        XCTAssertEqual(result.truncation.actualRowCount, 1)
        XCTAssertEqual(result.truncation.displayedRowCount, 1)
        XCTAssertEqual(result.truncation.actualColumnCount, CsvTable.maxCols + 1)
        XCTAssertEqual(result.truncation.displayedColumnCount, CsvTable.maxCols)
        XCTAssertFalse(result.truncation.rowsWereTruncated)
        XCTAssertTrue(result.truncation.columnsWereTruncated)
        XCTAssertEqual(result.truncation.notice, "Showing 64 of 65 columns.")
    }

    func testRowAndColumnTruncationReportsBothDimensions() {
        let row = (0...CsvTable.maxCols).map { "c\($0)" }.joined(separator: ",")
        let text = Array(repeating: row, count: CsvTable.maxRows + 1).joined(separator: "\n")
        let result = CsvTable.parse(text)

        XCTAssertEqual(result.truncation.actualRowCount, CsvTable.maxRows + 1)
        XCTAssertEqual(result.truncation.displayedRowCount, CsvTable.maxRows)
        XCTAssertEqual(result.truncation.actualColumnCount, CsvTable.maxCols + 1)
        XCTAssertEqual(result.truncation.displayedColumnCount, CsvTable.maxCols)
        XCTAssertTrue(result.truncation.rowsWereTruncated)
        XCTAssertTrue(result.truncation.columnsWereTruncated)
        XCTAssertEqual(
            result.truncation.notice,
            "Showing 2000 of 2001 rows and 64 of 65 columns."
        )
    }

    func testExactRowAndColumnBoundariesDoNotReportTruncation() {
        let row = (0..<CsvTable.maxCols).map { "c\($0)" }.joined(separator: ",")
        let text = Array(repeating: row, count: CsvTable.maxRows).joined(separator: "\n")
        let result = CsvTable.parse(text)

        XCTAssertEqual(result.truncation.actualRowCount, CsvTable.maxRows)
        XCTAssertEqual(result.truncation.displayedRowCount, CsvTable.maxRows)
        XCTAssertEqual(result.truncation.actualColumnCount, CsvTable.maxCols)
        XCTAssertEqual(result.truncation.displayedColumnCount, CsvTable.maxCols)
        XCTAssertFalse(result.truncation.rowsWereTruncated)
        XCTAssertFalse(result.truncation.columnsWereTruncated)
        XCTAssertNil(result.truncation.notice)
    }

    // MARK: - CSV cell inspection

    func testCsvCellInspectionPreservesTheCompleteAccessibleValue() {
        let value = String(repeating: "long-value-", count: 100) + "終"
        let inspection = CsvCellInspection(rowIndex: 7, columnIndex: 3, value: value)

        XCTAssertEqual(inspection.value, value)
        XCTAssertEqual(inspection.accessibilityLabel, "Row 8, column 4")
        XCTAssertEqual(inspection.accessibilityValue, value)
        XCTAssertEqual(
            inspection.accessibilityHint,
            "Press Return to inspect the complete value and copy it."
        )
        XCTAssertEqual(
            CsvCellInspection(rowIndex: 8, columnIndex: 4, value: "").accessibilityValue,
            "Empty cell"
        )
    }

    func testCsvCellInspectionIdentityUsesCoordinatesRatherThanTruncatedText() {
        let original = CsvCellInspection(rowIndex: 2, columnIndex: 5, value: "before")
        let updated = CsvCellInspection(rowIndex: 2, columnIndex: 5, value: "after")
        let neighbor = CsvCellInspection(rowIndex: 2, columnIndex: 6, value: "before")

        XCTAssertEqual(original.id, updated.id)
        XCTAssertNotEqual(original.id, neighbor.id)
    }

    func testCsvCellClipboardCopiesTheCompleteValueToAnIsolatedPasteboard() {
        let pasteboard = NSPasteboard(name: .init("kaisola-csv-cell-inspection-tests"))
        defer { pasteboard.clearContents() }
        let value = "first line\nsecond\tcolumn\nUnicode: café 終"

        XCTAssertTrue(CsvCellClipboard.copy(value, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), value)
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
        XCTAssertFalse(first.truncated)
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

    func testCsvPreviewModelCarriesTheTruncationSummary() {
        let text = (0..<(CsvTable.maxRows + 10)).map(String.init).joined(separator: "\n")
        let model = CsvPreviewModel.make(text)

        XCTAssertTrue(model.truncated)
        XCTAssertEqual(model.truncation.actualRowCount, CsvTable.maxRows + 10)
        XCTAssertEqual(model.truncation.displayedRowCount, CsvTable.maxRows)
        XCTAssertEqual(model.truncation.notice, "Showing 2000 of 2010 rows.")
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
        XCTAssertTrue(csvModel.truncated)
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
