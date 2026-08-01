import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Kaisola

final class BrokerBootstrapProcessDrainerTests: XCTestCase {
    func testDrainsNoisyStdoutAndStderrWithoutPipeDeadlockAndBoundsRetention() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "/usr/bin/yes O | /usr/bin/head -c 262144; "
                + "/usr/bin/yes E | /usr/bin/head -c 262144 >&2",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let collected = BrokerBootstrapProcessDrainer.waitForExit(
            process,
            stdout: stdout,
            stderr: stderr
        )

        XCTAssertEqual(collected.terminationStatus, 0)
        XCTAssertEqual(collected.stdout.utf8.count, BrokerBootstrapProcessDrainer.retainedBytesPerStream)
        XCTAssertEqual(collected.stderr.utf8.count, BrokerBootstrapProcessDrainer.retainedBytesPerStream)
        XCTAssertTrue(collected.stdout.hasPrefix("O\nO\n"))
        XCTAssertTrue(collected.stderr.hasPrefix("E\nE\n"))
    }
}

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
            verified.manifest.contentDigest,
            BrokerHelperPackageVerification.contentDigest(for: verified.manifest)
        )

        try Data("tampered".utf8).append(to: verified.brokerScript)
        XCTAssertThrowsError(try BrokerHelperPackageVerification.verify(root: root, requireSignatures: false)) { error in
            XCTAssertEqual(error as? BrokerHelperPackageError, .fileMismatch("lib/runtime/node-broker/session-broker.cjs"))
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

    func testStagerPublishesOnePrivateDigestAddressedCopyIndependentOfTheApp() throws {
        let sourceRoot = try makePackage()
        let source = try BrokerHelperPackageVerification.verify(
            root: sourceRoot,
            requireSignatures: false
        )
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-helper-stage-\(UUID().uuidString)",
            isDirectory: true
        )
        roots.append(profile)
        let destination = profile
            .appendingPathComponent("broker-generations", isDirectory: true)
            .appendingPathComponent(source.manifest.contentDigest, isDirectory: true)

        let staged = try BrokerHelperPackageStaging.stage(source, at: destination)

        XCTAssertEqual(staged.root, destination.standardizedFileURL)
        XCTAssertEqual(staged.manifest, source.manifest)
        let generationPermissions = try FileManager.default.attributesOfItem(
            atPath: destination.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual((generationPermissions?.intValue ?? 0) & 0o777, 0o700)

        // The running generation no longer depends on its replaceable source.
        try FileManager.default.removeItem(at: sourceRoot)
        let reopened = try BrokerHelperPackageVerification.verify(
            root: destination,
            requireSignatures: false
        )
        XCTAssertEqual(reopened.manifest.contentDigest, source.manifest.contentDigest)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: reopened.nodeExecutable.path))
    }

    func testStagerReusesExactBytesAndFailsClosedOnAChangedGeneration() throws {
        let sourceRoot = try makePackage()
        let source = try BrokerHelperPackageVerification.verify(
            root: sourceRoot,
            requireSignatures: false
        )
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-helper-stage-tamper-\(UUID().uuidString)",
            isDirectory: true
        )
        roots.append(profile)
        let destination = profile
            .appendingPathComponent("broker-generations", isDirectory: true)
            .appendingPathComponent(source.manifest.contentDigest, isDirectory: true)

        let first = try BrokerHelperPackageStaging.stage(source, at: destination)
        let second = try BrokerHelperPackageStaging.stage(source, at: destination)
        XCTAssertEqual(first, second)

        try Data("changed".utf8).append(to: second.brokerScript)
        XCTAssertThrowsError(try BrokerHelperPackageStaging.stage(source, at: destination)) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .stagedPackageMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: source.brokerScript), Data("broker".utf8))
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
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
