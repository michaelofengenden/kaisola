import Foundation
import XCTest
@testable import KaisolaMacPreview

/// `CsvTable` (RFC-4180-ish parsing + delimiter detection) and `JsonTree` (the
/// bounded display-tree builder) — the pure cores behind the CSV/JSON preview
/// views. No WKWebView / SwiftUI is exercised here.
final class DataPreviewsTests: XCTestCase {

    // MARK: - CSV parsing

    func testParsesSimpleRows() {
        let (rows, truncated) = CsvTable.parse("a,b,c\n1,2,3")
        XCTAssertEqual(rows, [["a", "b", "c"], ["1", "2", "3"]])
        XCTAssertFalse(truncated)
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
        let (rows, truncated) = CsvTable.parse("")
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(truncated)
    }

    func testSemicolonDelimiterParsing() {
        let (rows, _) = CsvTable.parse("a;b;c", delimiter: ";")
        XCTAssertEqual(rows, [["a", "b", "c"]])
    }

    // MARK: - CSV caps

    func testRowCapAndTruncatedFlag() {
        let text = (0..<(CsvTable.maxRows + 500)).map(String.init).joined(separator: "\n")
        let (rows, truncated) = CsvTable.parse(text)
        XCTAssertEqual(rows.count, CsvTable.maxRows)
        XCTAssertTrue(truncated)
    }

    func testColumnCapAndTruncatedFlag() {
        let wideRow = (0..<(CsvTable.maxCols + 30)).map { "c\($0)" }.joined(separator: ",")
        let (rows, truncated) = CsvTable.parse(wideRow)
        XCTAssertEqual(rows.first?.count, CsvTable.maxCols)
        XCTAssertTrue(truncated)
    }

    func testWithinCapsIsNotTruncated() {
        let text = (0..<10).map { "\($0),x,y" }.joined(separator: "\n")
        let (rows, truncated) = CsvTable.parse(text)
        XCTAssertEqual(rows.count, 10)
        XCTAssertFalse(truncated)
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
}
