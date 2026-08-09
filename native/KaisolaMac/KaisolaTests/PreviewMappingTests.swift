import Darwin
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
        XCTAssertNil(try store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json")))
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
        try store.upsert(PreviewMappingSpec(id: "greedy", extensions: ["json", "png", "zip"], kind: "markdown"))
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
        try store.upsert(PreviewMappingSpec(id: "logs", extensions: ["log"], kind: "markdown"))
        let url = directory.appending(path: "core.log")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x03]).write(to: url)
        guard case .binary = FilePreviewContent.load(url: url, mappings: store) else {
            return XCTFail("binary bytes reached a text preview through a mapping")
        }
    }

    func testInvalidMappingsNameTheirReasonAndAreSkipped() throws {
        let store = store()
        let reason = try store.upsert(PreviewMappingSpec(id: "bad", extensions: ["toml"], kind: "pdf"))
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
        try store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json"))
        XCTAssertTrue(try store.remove(id: "geo"))
        XCTAssertNil(store.kind(forExtension: "geojson"))
        XCTAssertFalse(try store.remove(id: "geo"))
        try store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json"))
        XCTAssertEqual(store.kind(forExtension: "geojson"), .json)
    }

    func testMissingVersionedAndLegacyStatesAreDistinctAndMigrateOnSave() throws {
        let store = store()
        XCTAssertEqual(store.load(), .init(specs: [], state: .missing))

        let legacy = Data(#"{"mappings":[{"id":"notes","extensions":["note"],"kind":"markdown"}]}"#.utf8)
        try legacy.write(to: store.fileURL)
        XCTAssertEqual(
            store.load(),
            .init(
                specs: [PreviewMappingSpec(id: "notes", extensions: ["note"], kind: "markdown")],
                state: .ready(schemaVersion: 0)
            )
        )

        try store.upsert(PreviewMappingSpec(id: "logs", extensions: ["log"], kind: "text"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, PreviewMappingStore.schemaVersion)
        XCTAssertEqual((object["mappings"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(store.load().state, .ready(schemaVersion: PreviewMappingStore.schemaVersion))
    }

    func testMalformedPartialRegistryIsPreservedAndMutationsBlockUntilExplicitReset() throws {
        let store = store()
        let malformed = Data(#"{"version":1,"mappings":[{"id":"good","extensions":["note"],"kind":"text"},{"id":7}]}"#.utf8)
        try malformed.write(to: store.fileURL)

        let first = store.load()
        guard case let .corrupt(.preserved(copyURL)) = first.state else {
            return XCTFail("Expected corrupt preserved state, got \(first.state)")
        }
        XCTAssertEqual(first.specs, [])
        XCTAssertEqual(try Data(contentsOf: copyURL), malformed)
        let recoveryMode = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: copyURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(recoveryMode.intValue & 0o777, 0o600)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)
        XCTAssertEqual(store.load().state, first.state, "preservation must be idempotent")

        XCTAssertThrowsError(
            try store.upsert(PreviewMappingSpec(id: "replacement", extensions: ["new"], kind: "text"))
        )
        XCTAssertThrowsError(try store.remove(id: "good"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)

        let reset = try store.resetUnreadableRegistry()
        XCTAssertEqual(reset, .init(specs: [], state: .ready(schemaVersion: 1)))
        XCTAssertEqual(try Data(contentsOf: copyURL), malformed, "reset must keep the recovery copy")
        XCTAssertNil(
            try store.upsert(PreviewMappingSpec(id: "replacement", extensions: ["new"], kind: "text"))
        )
    }

    func testDamagedRecoveryCopyFailsClosedAndCannotAuthorizeReset() throws {
        let store = store()
        let malformed = Data("not-json".utf8)
        try malformed.write(to: store.fileURL)
        let first = store.load()
        let copyURL = try XCTUnwrap(first.state.preservedCopyURL)
        try Data("different".utf8).write(to: copyURL)

        let second = store.load()
        guard case .corrupt(.failed) = second.state else {
            return XCTFail("A mismatched recovery copy must fail closed, got \(second.state)")
        }
        XCTAssertFalse(second.state.canReset)
        XCTAssertThrowsError(try store.resetUnreadableRegistry())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)
    }

    func testFutureSchemaIsPreservedAndNeverDowngradedImplicitly() throws {
        let store = store()
        let future = Data(#"{"version":42,"mappings":[],"futurePolicy":{"mode":"sealed"}}"#.utf8)
        try future.write(to: store.fileURL)

        let snapshot = store.load()
        guard case let .newerVersion(version, .preserved(copyURL)) = snapshot.state else {
            return XCTFail("Expected newer-version preserved state, got \(snapshot.state)")
        }
        XCTAssertEqual(version, 42)
        XCTAssertEqual(try Data(contentsOf: copyURL), future)
        XCTAssertThrowsError(
            try store.upsert(PreviewMappingSpec(id: "downgrade", extensions: ["old"], kind: "text"))
        )
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
    }

    func testIOReadFailureIsSeparateAndCannotBeResetWithoutPreservedBytes() throws {
        let badURL = directory.appending(path: "registry-directory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: false)
        let store = PreviewMappingStore(fileURL: badURL)

        guard case .ioFailure = store.load().state else {
            return XCTFail("A directory at the registry path must be an I/O failure")
        }
        XCTAssertThrowsError(try store.resetUnreadableRegistry())
        XCTAssertThrowsError(
            try store.upsert(PreviewMappingSpec(id: "blocked", extensions: ["x"], kind: "text"))
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: badURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testDurableWriteFailureIsThrownAndLeavesReadyRegistryUntouched() throws {
        let store = store()
        let baseline = PreviewMappingSpec(id: "baseline", extensions: ["base"], kind: "text")
        try store.upsert(baseline)
        let before = try Data(contentsOf: store.fileURL)

        XCTAssertEqual(chmod(directory.path, 0o500), 0)
        defer { _ = chmod(directory.path, 0o700) }
        XCTAssertThrowsError(
            try store.upsert(PreviewMappingSpec(id: "lost", extensions: ["lost"], kind: "markdown"))
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Kaisola could not save preview mappings. The existing registry was left unchanged."
            )
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(store.specs(), [baseline])
    }
}
