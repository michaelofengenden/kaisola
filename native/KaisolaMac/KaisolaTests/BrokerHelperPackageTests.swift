import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import KaisolaMacPreview

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

        try Data("tampered".utf8).append(to: verified.brokerScript)
        XCTAssertThrowsError(try BrokerHelperPackageVerification.verify(root: root, requireSignatures: false)) { error in
            XCTAssertEqual(error as? BrokerHelperPackageError, .fileMismatch("lib/electron/session-broker.cjs"))
        }
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

    private func makePackage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-helper-test-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        for directory in [
            root,
            root.appendingPathComponent("bin", isDirectory: true),
            root.appendingPathComponent("lib/electron", isDirectory: true),
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            _ = chmod(directory.path, 0o755)
        }

        let files: [(String, Data, Int)] = [
            ("bin/node", Data("node".utf8), 0o755),
            ("bin/kaisola-broker-bootstrap", Data("bootstrap".utf8), 0o755),
            ("lib/electron/session-broker.cjs", Data("broker".utf8), 0o644),
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
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "packageVersion": "test-package",
            "brokerImplementationVersion": 1,
            "brokerProtocol": ["minimum": 2, "maximum": 2, "securityEpoch": 1],
            "node": ["version": "22.23.1", "abi": "127", "architectures": ["arm64"]],
            "nodePty": ["version": "1.1.0"],
            "files": records,
        ]
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        _ = chmod(manifestURL.path, 0o644)
        return root
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
