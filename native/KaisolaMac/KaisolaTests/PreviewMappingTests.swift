import XCTest
@testable import Kaisola

/// Custom preview mappings: text kinds only, built-ins always first, invalid
/// specs named and skipped.
final class PreviewMappingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "kaisola-previews-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> PreviewMappingStore {
        PreviewMappingStore(fileURL: directory.appending(path: "preview-mappings.json"))
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testAMappingRoutesAnUnknownExtensionToATextKind() throws {
        let store = store()
        XCTAssertNil(store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json")))
        let url = try write("map.geojson", "{\"type\":\"FeatureCollection\"}")
        guard case let .json(text) = FilePreviewContent.load(url: url, mappings: store) else {
            return XCTFail("the mapping did not route .geojson to the JSON preview")
        }
        XCTAssertTrue(text.contains("FeatureCollection"))
    }

    /// Built-in classifications run first, so a mapping cannot restyle a
    /// built-in text kind, an image, or a binary extension.
    func testBuiltInsAlwaysWin() throws {
        let store = store()
        store.upsert(PreviewMappingSpec(id: "greedy", extensions: ["json", "png", "zip"], kind: "markdown"))
        let json = try write("data.json", "{}")
        guard case .json = FilePreviewContent.load(url: json, mappings: store) else {
            return XCTFail(".json was restyled by a custom mapping")
        }
        let zip = try write("archive.zip", "not really a zip")
        guard case .binary = FilePreviewContent.load(url: zip, mappings: store) else {
            return XCTFail(".zip escaped the binary classification")
        }
    }

    /// The mapping runs after the decode, so it can only style real text —
    /// binary bytes under a mapped extension still classify as binary.
    func testAMappingCannotLaunderBinaryBytesIntoAPreview() throws {
        let store = store()
        store.upsert(PreviewMappingSpec(id: "logs", extensions: ["log"], kind: "markdown"))
        let url = directory.appending(path: "core.log")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x03]).write(to: url)
        guard case .binary = FilePreviewContent.load(url: url, mappings: store) else {
            return XCTFail("binary bytes reached a text preview through a mapping")
        }
    }

    func testInvalidMappingsNameTheirReasonAndAreSkipped() throws {
        let store = store()
        let reason = store.upsert(PreviewMappingSpec(id: "bad", extensions: ["toml"], kind: "pdf"))
        XCTAssertTrue(reason?.contains("not a preview kind") == true, String(describing: reason))
        XCTAssertEqual(store.specs().count, 1, "invalid specs stay listed")
        XCTAssertNil(store.kind(forExtension: "toml"), "…but are never consulted")

        XCTAssertEqual(
            PreviewMappingSpec(id: "empty", extensions: [], kind: "text").validationError,
            "The mapping claims no file extensions."
        )
    }

    func testRemovalIsExactAndReversible() throws {
        let store = store()
        store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json"))
        XCTAssertTrue(store.remove(id: "geo"))
        XCTAssertNil(store.kind(forExtension: "geojson"))
        XCTAssertFalse(store.remove(id: "geo"))
        store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json"))
        XCTAssertEqual(store.kind(forExtension: "geojson"), .json)
    }

    func testCorruptStoreReadsAsEmpty() throws {
        let store = store()
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.specs(), [])
        XCTAssertNil(store.kind(forExtension: "geojson"))
    }
}
