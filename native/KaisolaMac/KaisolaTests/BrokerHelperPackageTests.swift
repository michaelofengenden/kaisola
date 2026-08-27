import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Kaisola

final class BrokerHelperPackageTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testVerifierAcceptsExactPrivateManifestAndDetectsTampering() throws {
        let root = try makePackage()
        let verified = try BrokerHelperPackageVerification.verify(root: root, requireSignatures: false)
        XCTAssertEqual(verified.manifest.packageVersion, "test-package")
        XCTAssertEqual(verified.manifest.brokerImplementationVersion, 1)
        XCTAssertEqual(
            verified.manifest.packageKind,
            .nodeV1(
                node: .init(version: "22.23.1", abi: "127", architectures: ["arm64"]),
                nodePty: .init(version: "1.1.0")
            )
        )
        XCTAssertEqual(verified.nodeExecutable, root.appendingPathComponent("bin/node"))
        XCTAssertEqual(
            verified.manifest.contentDigest,
            "2513bf9a7edf22c7ea831c7188a05603e493ac52539e033657e61bd90751ce20"
        )
        XCTAssertEqual(
            verified.manifest.contentDigest,
            BrokerHelperPackageVerification.contentDigest(for: verified.manifest)
        )

        let sealedScript = root.appendingPathComponent("lib/runtime/node-broker/session-broker.cjs")
        try Data("tampered".utf8).append(to: sealedScript)
        XCTAssertThrowsError(try BrokerHelperPackageVerification.verify(root: root, requireSignatures: false)) { error in
            XCTAssertEqual(error as? BrokerHelperPackageError, .fileMismatch("lib/runtime/node-broker/session-broker.cjs"))
        }
    }

    func testVerifierPreservesSchemaOneManifestHardLinkCompatibility() throws {
        let root = try makePackage()
        let outsideManifestLink = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-node-helper-manifest-hardlink-\(UUID().uuidString)"
        )
        roots.append(outsideManifestLink)
        XCTAssertEqual(
            Darwin.link(
                root.appendingPathComponent("manifest.json").path,
                outsideManifestLink.path
            ),
            0
        )

        let verified = try BrokerHelperPackageVerification.verify(
            root: root,
            requireSignatures: false
        )

        XCTAssertEqual(verified.manifest.schemaVersion, 1)
    }

    func testVerifierRejectsSchemaOneWithNativeLaunchMetadata() throws {
        let root = try makePackage()
        try rewriteManifest(at: root) { manifest in
            manifest["appRelease"] = ["version": "0.1.123", "build": "1123000"]
            manifest["launch"] = [
                "kind": "native",
                "executable": "bin/kaisola-session-broker",
                "arguments": ["--shadow"],
            ]
        }

        XCTAssertThrowsError(try BrokerHelperPackageVerification.verify(root: root, requireSignatures: false)) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .invalidManifest)
        }
    }

    func testSwiftDigestMatchesSharedNodeSchemaOneVector() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorsURL = repositoryRoot.appendingPathComponent(
            "protocol/broker/package-digest-vectors-v1.json"
        )
        // The shared fixture retains the retired schema-2 vector at index 1
        // for the node-side digest history, and this app can no longer decode
        // that manifest shape. Only vectors[0] is the Swift contract.
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: vectorsURL)
            ) as? [String: Any]
        )
        let rawVectors = try XCTUnwrap(document["vectors"] as? [[String: Any]])
        let rawVector = try XCTUnwrap(rawVectors.first)
        let vector = try JSONDecoder().decode(
            DigestVector.self,
            from: JSONSerialization.data(withJSONObject: rawVector)
        )

        XCTAssertEqual(vector.manifest.schemaVersion, 1)
        XCTAssertEqual(
            BrokerHelperPackageVerification.contentDigest(for: vector.manifest),
            vector.expectedDigest,
            vector.name
        )
    }

    func testVerifierRejectsSymlinksAndUnmanifestedFiles() throws {
        let linked = try makePackage()
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("linked"),
            withDestinationURL: linked.appendingPathComponent("bin/node")
        )
        XCTAssertThrowsError(try BrokerHelperPackageVerification.verify(root: linked, requireSignatures: false))

        let extra = try makePackage()
        try Data("extra".utf8).write(to: extra.appendingPathComponent("extra"))
        XCTAssertThrowsError(try BrokerHelperPackageVerification.verify(root: extra, requireSignatures: false)) { error in
            guard case .inventoryMismatch = error as? BrokerHelperPackageError else {
                return XCTFail("expected inventory mismatch, got \(error)")
            }
        }
    }

    func testSignatureRequiredVerificationNeverTrustsAStandaloneManifest() throws {
        let root = try makePackage()
        XCTAssertThrowsError(try BrokerHelperPackageVerification.verify(root: root, requireSignatures: true)) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .unsealedHostApplication)
        }
    }

    func testVerifierHashesFilesAcrossMultipleBoundedReadChunks() throws {
        let brokerData = Data(
            repeating: 0xA5,
            count: (BrokerHelperPackageVerification.digestReadChunkBytes * 2) + 317
        )
        let root = try makePackage(brokerData: brokerData)

        let verified = try BrokerHelperPackageVerification.verify(root: root, requireSignatures: false)

        let brokerRecord = try XCTUnwrap(
            verified.manifest.files.first { $0.path == "lib/runtime/node-broker/session-broker.cjs" }
        )
        XCTAssertEqual(brokerRecord.size, Int64(brokerData.count))
        XCTAssertEqual(
            brokerRecord.sha256,
            SHA256.hash(data: brokerData).map { String(format: "%02x", $0) }.joined()
        )
    }

    private struct DigestVector: Decodable {
        let name: String
        let expectedDigest: String
        let manifest: BrokerHelperManifest
    }

    private func makePackage(brokerData: Data = Data("broker".utf8)) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-helper-test-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        for directory in [
            root,
            root.appendingPathComponent("bin", isDirectory: true),
            root.appendingPathComponent("lib/runtime/node-broker", isDirectory: true),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            _ = chmod(directory.path, 0o755)
        }

        // The fixture inventory is frozen: the pinned content digest above
        // seals exactly these paths, sizes, and modes.
        let files: [(String, Data, Int)] = [
            ("bin/node", Data("node".utf8), 0o755),
            ("bin/kaisola-broker-bootstrap", Data("bootstrap".utf8), 0o755),
            ("lib/runtime/node-broker/session-broker.cjs", brokerData, 0o644),
        ]
        var records: [[String: Any]] = []
        for (relative, data, mode) in files {
            let url = root.appendingPathComponent(relative)
            try data.write(to: url)
            _ = chmod(url.path, mode_t(mode))
            records.append([
                "path": relative,
                "role": relative.hasSuffix(".cjs") ? "broker-javascript" : "resource",
                "size": data.count,
                "mode": String(format: "%04o", mode),
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            ])
        }
        var manifest: [String: Any] = [
            "schemaVersion": 1,
            "packageVersion": "test-package",
            "contentDigest": String(repeating: "0", count: 64),
            "brokerImplementationVersion": 1,
            "brokerProtocol": ["minimum": 2, "maximum": 2, "securityEpoch": 1],
            "node": ["version": "22.23.1", "abi": "127", "architectures": ["arm64"]],
            "nodePty": ["version": "1.1.0"],
            "files": records,
        ]
        let manifestURL = root.appendingPathComponent("manifest.json")
        let provisional = try JSONDecoder().decode(
            BrokerHelperManifest.self,
            from: JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        )
        manifest["contentDigest"] = BrokerHelperPackageVerification.contentDigest(for: provisional)
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        _ = chmod(manifestURL.path, 0o644)
        return root
    }

    private func rewriteManifest(
        at root: URL,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        let url = root.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        try mutation(&manifest)
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: url)
        _ = chmod(url.path, 0o644)
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
