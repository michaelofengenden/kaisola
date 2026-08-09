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
        XCTAssertNil(store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json")).message)
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
        let mutation = store.upsert(PreviewMappingSpec(id: "bad", extensions: ["toml"], kind: "pdf"))
        let reason = mutation.validationError
        XCTAssertTrue(reason?.contains("not a preview kind") == true, String(describing: reason))
        XCTAssertEqual(mutation.message, reason, "a stored-but-invalid spec explains itself")
        XCTAssertTrue(mutation.save.didPersist, "…and is still stored")
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
        XCTAssertEqual(store.remove(id: "geo"), .saved)
        XCTAssertNil(store.kind(forExtension: "geojson"))
        XCTAssertEqual(store.remove(id: "geo"), .nothingToDo)
        store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json"))
        XCTAssertEqual(store.kind(forExtension: "geojson"), .json)
    }

    func testCorruptStoreReadsAsEmpty() throws {
        let store = store()
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.specs(), [])
        XCTAssertNil(store.kind(forExtension: "geojson"))
    }

    // MARK: - A file this build cannot read

    /// The four file problems are four different answers, so they are four
    /// different states rather than one empty array.
    func testEveryFileProblemIsItsOwnState() throws {
        let store = store()
        XCTAssertEqual(store.state(), .missing, "no file yet is not damage")

        store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json"))
        XCTAssertEqual(
            store.state(),
            .loaded([PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json")])
        )

        try Data("{\"mappings\": [".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.state(), .corrupt)

        try Data("{\"version\": 99, \"mappings\": []}".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.state(), .newerVersionData(formatVersion: 99))

        try Data("{\"mappings\": []}".utf8).write(to: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: store.fileURL.path
            )
        }
        guard case .unreadable = store.state() else {
            return XCTFail("a file that cannot be opened is not the same as a file with no mappings")
        }
    }

    /// The bug this replaces: a malformed registry read as "no mappings", so
    /// the next edit wrote a one-entry file over a catalog that was still
    /// recoverable. The damaged bytes now survive the repair.
    func testAMalformedFileIsKeptAsideRatherThanOverwritten() throws {
        let store = store()
        let damaged = "{\"mappings\": [{\"id\": \"geo\", \"extensi"
        try Data(damaged.utf8).write(to: store.fileURL)

        let mutation = store.upsert(PreviewMappingSpec(id: "logs", extensions: ["log"], kind: "markdown"))
        guard case .savedAfterPreserving(let keptURL) = mutation.save else {
            return XCTFail("the malformed registry was replaced without keeping it: \(mutation.save)")
        }
        XCTAssertTrue(
            keptURL.lastPathComponent.hasPrefix("preview-mappings.corrupt-"),
            keptURL.lastPathComponent
        )
        XCTAssertEqual(try String(contentsOf: keptURL, encoding: .utf8), damaged)
        XCTAssertEqual(store.kind(forExtension: "log"), .markdown, "the edit still landed")
        XCTAssertEqual(mutation.message?.contains(keptURL.lastPathComponent), true, "the editor is told where the bytes went")
    }

    /// A newer Kaisola's file is good data, not damage: it stays exactly where
    /// that version expects it, and the edit fails loudly instead.
    func testAFileFromANewerVersionIsNeverReplacedOrMovedAside() throws {
        let store = store()
        let newer = "{\"version\": 99, \"mappings\": [{\"id\": \"geo\", \"extensions\": [\"geojson\"], \"kind\": \"json\"}]}"
        try Data(newer.utf8).write(to: store.fileURL)

        let mutation = store.upsert(PreviewMappingSpec(id: "logs", extensions: ["log"], kind: "markdown"))
        XCTAssertFalse(mutation.save.didPersist)
        XCTAssertEqual(mutation.message?.contains("newer version of Kaisola"), true, String(describing: mutation.message))
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), newer)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["preview-mappings.json"],
            "good data from another build is never moved aside"
        )
        XCTAssertThrowsError(try store.preserveCorruptFile()) { error in
            XCTAssertEqual(error as? PreviewMappingStore.PreservationError, .fileIsNotCorrupt)
        }
    }

    /// A read that failed says nothing about the contents, so the write stops
    /// rather than replacing bytes that may be perfectly intact.
    func testAFileThatCannotBeReadStopsTheWrite() throws {
        let store = store()
        let existing = "{\"mappings\": [{\"id\": \"geo\", \"extensions\": [\"geojson\"], \"kind\": \"json\"}]}"
        try Data(existing.utf8).write(to: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: store.fileURL.path
            )
        }

        let mutation = store.upsert(PreviewMappingSpec(id: "logs", extensions: ["log"], kind: "markdown"))
        XCTAssertFalse(mutation.save.didPersist)
        XCTAssertEqual(mutation.message?.contains("couldn't read"), true, String(describing: mutation.message))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), existing)
    }

    /// Removing an entry we could never read cannot be reported as done — the
    /// entry may well still be in the file.
    func testRemovingFromAnUnreadableRegistryIsRefusedNotReportedDone() throws {
        let store = store()
        let damaged = "{\"mappings\": [{\"id\": \"geo\", \"extensi"
        try Data(damaged.utf8).write(to: store.fileURL)

        let result = store.remove(id: "geo")
        XCTAssertFalse(result.didPersist)
        XCTAssertEqual(result.message?.contains("wasn't removed"), true, String(describing: result.message))
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), damaged)
    }

    /// The pre-version file shipped without a `version` key. It is version 1 by
    /// definition: it loads unchanged, is never mistaken for damage, and gains
    /// the key on the next save.
    func testAFileWithoutAVersionLoadsAndGainsOneOnTheNextSave() throws {
        let store = store()
        try Data("{\"mappings\": [{\"id\": \"geo\", \"extensions\": [\"geojson\"], \"kind\": \"json\"}]}".utf8)
            .write(to: store.fileURL)
        XCTAssertEqual(store.kind(forExtension: "geojson"), .json)

        XCTAssertTrue(store.upsert(PreviewMappingSpec(id: "logs", extensions: ["log"], kind: "markdown")).save == .saved)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["preview-mappings.json"],
            "a legacy file is ordinary data, not something to keep aside"
        )
        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.fileURL)
        ) as? [String: Any]
        XCTAssertEqual(written?["version"] as? Int, PreviewMappingStore.formatVersion)
        XCTAssertEqual(store.specs().map(\.id), ["geo", "logs"])
    }

    /// A save that never reached disk used to look exactly like one that did.
    func testAFailedWriteIsReportedInsteadOfSwallowed() throws {
        let locked = directory.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let store = PreviewMappingStore(fileURL: locked.appending(path: "preview-mappings.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }

        let mutation = store.upsert(PreviewMappingSpec(id: "geo", extensions: ["geojson"], kind: "json"))
        guard case .failed = mutation.save else {
            return XCTFail("a write into a read-only directory reported success: \(mutation.save)")
        }
        XCTAssertEqual(mutation.message?.hasPrefix("This change wasn't saved:"), true, String(describing: mutation.message))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
