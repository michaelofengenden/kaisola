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
    private static let nativeExpectation = BrokerHelperPackageExpectation(
        packageVersion: "2.0.0",
        appReleaseVersion: "0.1.123",
        appReleaseBuild: "1123000"
    )

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
        XCTAssertEqual(
            verified.launchPayload,
            .node(
                executable: root.appendingPathComponent("bin/node"),
                script: root.appendingPathComponent("lib/runtime/node-broker/session-broker.cjs")
            )
        )
        XCTAssertEqual(
            verified.manifest.contentDigest,
            "2513bf9a7edf22c7ea831c7188a05603e493ac52539e033657e61bd90751ce20"
        )
        XCTAssertEqual(
            verified.manifest.contentDigest,
            BrokerHelperPackageVerification.contentDigest(for: verified.manifest)
        )

        try Data("tampered".utf8).append(to: verified.brokerScript)
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

    func testUnsignedStructuralVerifierAcceptsSyntheticArm64NativeV2AndReturnsOrderedLaunchPayload() throws {
        let root = try makeNativePackage()

        let verified = try verifyNativePackage(root)

        XCTAssertEqual(verified.manifest.schemaVersion, 2)
        XCTAssertEqual(verified.manifest.packageVersion, "2.0.0")
        XCTAssertEqual(verified.manifest.brokerImplementationVersion, 2)
        XCTAssertEqual(
            verified.manifest.packageKind,
            .nativeV2(
                appRelease: .init(version: "0.1.123", build: "1123000"),
                launch: .init(
                    kind: .native,
                    executable: "bin/kaisola-session-broker",
                    arguments: ["--shadow"]
                )
            )
        )
        XCTAssertEqual(
            verified.launchPayload,
            .native(
                executable: root.appendingPathComponent("bin/kaisola-session-broker"),
                arguments: ["--shadow"]
            )
        )
        XCTAssertEqual(
            verified.manifest.contentDigest,
            "b1f6a8456e5d812502e2a04dd68871f8c24e8aea1232287caebfd51b0cdcb2e2"
        )

        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-native-helper-stage-\(UUID().uuidString)",
            isDirectory: true
        )
        roots.append(profile)
        let destination = profile
            .appendingPathComponent("broker-generations", isDirectory: true)
            .appendingPathComponent(verified.manifest.contentDigest, isDirectory: true)
        let staged = try BrokerHelperPackageStaging.stage(verified, at: destination)
        XCTAssertEqual(
            staged.launchPayload,
            .native(
                executable: destination.appendingPathComponent("bin/kaisola-session-broker"),
                arguments: ["--shadow"]
            )
        )
    }

    func testBundledNativeVerifierBindsPackageToTheContainingAppRelease() throws {
        let matchingBundle = try makeHelperBundle()

        let verified = try BrokerHelperPackageVerification.verifyBundledNative(
            bundle: matchingBundle,
            requireSignatures: false
        )

        XCTAssertEqual(verified.root.lastPathComponent, "BrokerSessionHelper")
        XCTAssertEqual(verified.manifest.packageVersion, "2.0.0")

        let staleBundle = try makeHelperBundle(appReleaseVersion: "0.1.124")
        XCTAssertThrowsError(
            try BrokerHelperPackageVerification.verifyBundledNative(
                bundle: staleBundle,
                requireSignatures: false
            )
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .incompatibleManifest)
        }
    }

    func testBundledNativeVerifierRequiresTheSealedArm64BootstrapItExecutes() throws {
        let incompleteBundle = try makeHelperBundle(includeNativeBootstrap: false)

        XCTAssertThrowsError(
            try BrokerHelperPackageVerification.verifyBundledNative(
                bundle: incompleteBundle,
                requireSignatures: false
            )
        ) { error in
            XCTAssertEqual(
                error as? BrokerHelperPackageError,
                .inventoryMismatch("sealed native bootstrap is missing")
            )
        }
    }

    func testDevelopmentRuntimeSelectorChoosesOnlyExactSwiftOptIn() async throws {
        let bundle = try makeHelperBundle()
        let unsignedEnvironment = ["KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER": "1"]

        let defaultManifest = try await BrokerBootstrapClient(
            bundle: bundle,
            environment: unsignedEnvironment
        ).packageManifest()
        let explicitNodeManifest = try await BrokerBootstrapClient(
            bundle: bundle,
            environment: unsignedEnvironment.merging([
                "KAISOLA_SESSION_BROKER_RUNTIME": "node",
            ]) { _, selected in selected }
        ).packageManifest()
        let invalidManifest = try await BrokerBootstrapClient(
            bundle: bundle,
            environment: unsignedEnvironment.merging([
                "KAISOLA_SESSION_BROKER_RUNTIME": "Swift",
            ]) { _, selected in selected }
        ).packageManifest()
        let swiftManifest = try await BrokerBootstrapClient(
            bundle: bundle,
            environment: unsignedEnvironment.merging([
                "KAISOLA_SESSION_BROKER_RUNTIME": "swift",
            ]) { _, selected in selected }
        ).packageManifest()

        // A misspelled or differently cased development selector stays on the
        // stable Node package. Only the exact opt-in may choose native code.
        XCTAssertEqual(defaultManifest.schemaVersion, 1)
        XCTAssertEqual(explicitNodeManifest.schemaVersion, 1)
        XCTAssertEqual(invalidManifest.schemaVersion, 1)
        XCTAssertEqual(swiftManifest.schemaVersion, 2)
        XCTAssertEqual(swiftManifest.packageVersion, "2.0.0")
    }

    func testNativeSelectorRevalidatesItsStagedSchema2Package() async throws {
        let bundle = try makeHelperBundle()
        let environment = [
            "KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER": "1",
            "KAISOLA_SESSION_BROKER_RUNTIME": "swift",
        ]
        let client = BrokerBootstrapClient(bundle: bundle, environment: environment)
        let expected = try await client.packageManifest()
        let bundled = try BrokerHelperPackageVerification.verifyBundledNative(
            bundle: bundle,
            requireSignatures: false
        )
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaisolaStagedNativeTests-\(UUID().uuidString)",
            isDirectory: true
        )
        roots.append(profile)
        let destination = profile
            .appendingPathComponent("broker-generations", isDirectory: true)
            .appendingPathComponent(expected.contentDigest, isDirectory: true)
        _ = try BrokerHelperPackageStaging.stage(bundled, at: destination)

        try await client.validateStagedPackage(at: destination, expected: expected)
        let reverified = try await client.verifiedStagedPackage(at: destination)
        XCTAssertEqual(reverified.manifest, expected)

        // Unsetting the opt-in selects Node for the next launch, but the
        // current app release must retain enough authority to inspect and
        // drain or roll back the already-staged Swift generation.
        let nodeDefaultClient = BrokerBootstrapClient(
            bundle: bundle,
            environment: ["KAISOLA_ALLOW_UNSIGNED_NATIVE_HELPER": "1"]
        )
        let rollbackReverified = try await nodeDefaultClient.verifiedStagedPackage(
            at: destination
        )
        XCTAssertEqual(rollbackReverified.manifest, expected)
    }

    func testNativeV2RequiresExplicitExactInitialExpectation() throws {
        let root = try makeNativePackage()

        XCTAssertThrowsError(
            try BrokerHelperPackageVerification.verify(
                root: root,
                requireSignatures: false
            )
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .incompatibleManifest)
        }
        XCTAssertThrowsError(
            try verifyNativePackage(
                root,
                expectation: .init(
                    packageVersion: "2.0.1",
                    appReleaseVersion: "0.1.123",
                    appReleaseBuild: "1123000"
                )
            )
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .incompatibleManifest)
        }
    }

    func testNativeV2ExpectationBindsPackageAndAppReleaseIdentity() throws {
        let wrongPackageVersion = try makeNativePackage()
        try rewriteManifestAndRefreshDigest(at: wrongPackageVersion) { manifest in
            manifest["packageVersion"] = "2.0.1"
        }
        XCTAssertThrowsError(try verifyNativePackage(wrongPackageVersion)) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .incompatibleManifest)
        }

        let wrongAppVersion = try makeNativePackage()
        try rewriteManifestAndRefreshDigest(at: wrongAppVersion) { manifest in
            var appRelease = manifest["appRelease"] as? [String: Any] ?? [:]
            appRelease["version"] = "0.1.124"
            manifest["appRelease"] = appRelease
        }
        XCTAssertThrowsError(try verifyNativePackage(wrongAppVersion)) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .incompatibleManifest)
        }

        let wrongAppBuild = try makeNativePackage()
        try rewriteManifestAndRefreshDigest(at: wrongAppBuild) { manifest in
            var appRelease = manifest["appRelease"] as? [String: Any] ?? [:]
            appRelease["build"] = "1124000"
            manifest["appRelease"] = appRelease
        }
        XCTAssertThrowsError(try verifyNativePackage(wrongAppBuild)) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .incompatibleManifest)
        }
    }

    func testNativeV2RequiresExactImplementationAndProtocolEnvelope() throws {
        let legacyImplementation = try makeNativePackage()
        try rewriteManifestAndRefreshDigest(at: legacyImplementation) { manifest in
            manifest["brokerImplementationVersion"] = 1
        }
        XCTAssertThrowsError(try verifyNativePackage(legacyImplementation)) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .incompatibleManifest)
        }

        let widenedProtocol = try makeNativePackage()
        try rewriteManifestAndRefreshDigest(at: widenedProtocol) { manifest in
            manifest["brokerProtocol"] = [
                "minimum": 1,
                "maximum": 3,
                "securityEpoch": 1,
            ]
        }
        XCTAssertThrowsError(try verifyNativePackage(widenedProtocol)) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .incompatibleManifest)
        }
    }

    func testVerifierRejectsAmbiguousNativeV2NodeMetadata() throws {
        let root = try makeNativePackage()
        try rewriteManifest(at: root) { manifest in
            manifest["node"] = ["version": "22.23.1", "abi": "127", "architectures": ["arm64"]]
            manifest["nodePty"] = ["version": "1.1.0"]
        }

        XCTAssertThrowsError(try verifyNativePackage(root)) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .invalidManifest)
        }
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

    func testVerifierRejectsNativeLaunchPathSubstitutionAndDuplicateExecutableRole() throws {
        let substituted = try makeNativePackage(launchExecutable: "bin/substituted-broker")
        XCTAssertThrowsError(
            try verifyNativePackage(substituted)
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .invalidManifest)
        }

        let duplicate = try makeNativePackage(includeDuplicateExecutableRole: true)
        XCTAssertThrowsError(
            try verifyNativePackage(duplicate)
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .invalidManifest)
        }
    }

    func testVerifierRejectsNativeHardLinksAndNonExecutableMode() throws {
        let linkedManifest = try makeNativePackage()
        let outsideManifestLink = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-native-helper-manifest-hardlink-\(UUID().uuidString)"
        )
        roots.append(outsideManifestLink)
        XCTAssertEqual(
            Darwin.link(
                linkedManifest.appendingPathComponent("manifest.json").path,
                outsideManifestLink.path
            ),
            0
        )
        XCTAssertThrowsError(
            try verifyNativePackage(linkedManifest)
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .invalidManifest)
        }

        let linked = try makeNativePackage()
        let linkedExecutable = linked.appendingPathComponent("bin/kaisola-session-broker")
        let outsideLink = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-native-helper-hardlink-\(UUID().uuidString)"
        )
        roots.append(outsideLink)
        XCTAssertEqual(Darwin.link(linkedExecutable.path, outsideLink.path), 0)
        XCTAssertThrowsError(
            try verifyNativePackage(linked)
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .fileMismatch("bin/kaisola-session-broker"))
        }

        let nonExecutable = try makeNativePackage(executableMode: 0o644)
        XCTAssertThrowsError(
            try verifyNativePackage(nonExecutable)
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .fileMismatch("bin/kaisola-session-broker"))
        }
    }

    func testVerifierRejectsNativeWrongActualArchitectureAndMissingRequirement() throws {
        let wrongArchitecture = try makeNativePackage(executableData: thinMachO(cpuType: 0x01000007))
        XCTAssertThrowsError(
            try verifyNativePackage(wrongArchitecture)
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .fileMismatch("bin/kaisola-session-broker"))
        }

        let missingRequirement = try makeNativePackage(designatedRequirement: "")
        XCTAssertThrowsError(
            try verifyNativePackage(missingRequirement)
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .invalidManifest)
        }
    }

    func testVerifierRejectsActualNativeMachODeclaredAsPlainResource() throws {
        let root = try makeNativePackage(includeUndeclaredMachOResource: true)

        XCTAssertThrowsError(try verifyNativePackage(root)) {
            XCTAssertEqual(
                $0 as? BrokerHelperPackageError,
                .fileMismatch("bin/undeclared-mach-o-resource")
            )
        }
    }

    func testVerifierRejectsReservedOrUnboundedNativeArguments() throws {
        for arguments in [
            ["--launch"],
            ["--pty-child"],
            Array(repeating: "argument", count: 33),
            [String(repeating: "x", count: 4_097)],
            ["embedded\0nul"],
        ] {
            let root = try makeNativePackage(arguments: arguments)
            XCTAssertThrowsError(
                try verifyNativePackage(root),
                "expected rejection for arguments \(arguments)"
            ) {
                XCTAssertEqual($0 as? BrokerHelperPackageError, .invalidManifest)
            }
        }
    }

    func testNativeV2DigestBindsAppReleaseAndOrderedArguments() throws {
        let root = try makeNativePackage()
        try rewriteManifest(at: root) { manifest in
            manifest["appRelease"] = ["version": "0.1.124", "build": "1099124"]
        }
        XCTAssertThrowsError(
            try verifyNativePackage(
                root,
                expectation: .init(
                    packageVersion: "2.0.0",
                    appReleaseVersion: "0.1.124",
                    appReleaseBuild: "1099124"
                )
            )
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .invalidManifest)
        }

        let reordered = try makeNativePackage(arguments: ["first", "second"])
        try rewriteManifest(at: reordered) { manifest in
            var launch = manifest["launch"] as? [String: Any] ?? [:]
            launch["arguments"] = ["second", "first"]
            manifest["launch"] = launch
        }
        XCTAssertThrowsError(
            try verifyNativePackage(reordered)
        ) {
            XCTAssertEqual($0 as? BrokerHelperPackageError, .invalidManifest)
        }
    }

    func testSwiftDigestMatchesSharedNodeSchemaOneAndNativeSchemaTwoVectors() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorsURL = repositoryRoot.appendingPathComponent(
            "protocol/broker/package-digest-vectors-v1.json"
        )
        let document = try JSONDecoder().decode(
            DigestVectorDocument.self,
            from: Data(contentsOf: vectorsURL)
        )

        XCTAssertEqual(document.vectors.map(\.manifest.schemaVersion).sorted(), [1, 2])
        for vector in document.vectors {
            XCTAssertEqual(
                BrokerHelperPackageVerification.contentDigest(for: vector.manifest),
                vector.expectedDigest,
                vector.name
            )
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

    private struct DigestVectorDocument: Decodable {
        struct Vector: Decodable {
            let name: String
            let expectedDigest: String
            let manifest: BrokerHelperManifest
        }

        let vectors: [Vector]
    }

    private func verifyNativePackage(
        _ root: URL
    ) throws -> VerifiedBrokerHelperPackage {
        try verifyNativePackage(root, expectation: Self.nativeExpectation)
    }

    private func verifyNativePackage(
        _ root: URL,
        expectation: BrokerHelperPackageExpectation
    ) throws -> VerifiedBrokerHelperPackage {
        try BrokerHelperPackageVerification.verify(
            root: root,
            requireSignatures: false,
            schema2Expectation: expectation
        )
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

    private func makeHelperBundle(
        appReleaseVersion: String = "0.1.123",
        appReleaseBuild: String = "1123000",
        includeNativeBootstrap: Bool = true
    ) throws -> Bundle {
        let bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaisolaHelperTests-\(UUID().uuidString).bundle", isDirectory: true)
        roots.append(bundleRoot)
        let contents = bundleRoot.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        _ = chmod(bundleRoot.path, 0o755)
        _ = chmod(contents.path, 0o755)
        _ = chmod(resources.path, 0o755)

        try FileManager.default.copyItem(
            at: makePackage(),
            to: resources.appendingPathComponent("BrokerHelper", isDirectory: true)
        )
        try FileManager.default.copyItem(
            at: makeNativePackage(includeBootstrap: includeNativeBootstrap),
            to: resources.appendingPathComponent("BrokerSessionHelper", isDirectory: true)
        )

        let information: [String: Any] = [
            "CFBundleIdentifier": "com.kaisola.tests.helper.\(UUID().uuidString)",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": appReleaseVersion,
            "CFBundleVersion": appReleaseBuild,
        ]
        let informationData = try PropertyListSerialization.data(
            fromPropertyList: information,
            format: .xml,
            options: 0
        )
        try informationData.write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: bundleRoot))
    }

    private func makeNativePackage(
        arguments: [String] = ["--shadow"],
        launchExecutable: String = "bin/kaisola-session-broker",
        executableData: Data? = nil,
        executableMode: Int = 0o755,
        designatedRequirement: String = "identifier \"com.kaisola.mac.session-broker\" and anchor apple generic",
        includeDuplicateExecutableRole: Bool = false,
        includeUndeclaredMachOResource: Bool = false,
        includeBootstrap: Bool = false
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-native-helper-test-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [root, bin] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            _ = chmod(directory.path, 0o755)
        }

        func writeRecord(
            path: String,
            role: String,
            data: Data,
            mode: Int
        ) throws -> [String: Any] {
            let url = root.appendingPathComponent(path)
            try data.write(to: url)
            _ = chmod(url.path, mode_t(mode))
            return [
                "path": path,
                "role": role,
                "size": data.count,
                "mode": String(format: "%04o", mode),
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "machO": [
                    "architectures": ["arm64"],
                    "designatedRequirement": designatedRequirement,
                ],
            ]
        }

        var records = [try writeRecord(
            path: "bin/kaisola-session-broker",
            role: "session-broker-executable",
            data: executableData ?? thinMachO(cpuType: 0x0100000C),
            mode: executableMode
        )]
        if includeBootstrap {
            records.append(try writeRecord(
                path: "bin/kaisola-broker-bootstrap",
                role: "launch-agent-bootstrap",
                data: thinMachO(cpuType: 0x0100000C),
                mode: 0o755
            ))
        }
        if includeDuplicateExecutableRole {
            records.append(try writeRecord(
                path: "bin/duplicate-session-broker",
                role: "session-broker-executable",
                data: thinMachO(cpuType: 0x0100000C),
                mode: 0o755
            ))
        }
        if includeUndeclaredMachOResource {
            let path = "bin/undeclared-mach-o-resource"
            let data = thinMachO(cpuType: 0x0100000C)
            let url = root.appendingPathComponent(path)
            try data.write(to: url)
            _ = chmod(url.path, 0o644)
            records.append([
                "path": path,
                "role": "resource",
                "size": data.count,
                "mode": "0644",
                "sha256": SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined(),
            ])
        }

        var manifest: [String: Any] = [
            "schemaVersion": 2,
            "packageVersion": "2.0.0",
            "contentDigest": String(repeating: "0", count: 64),
            "appRelease": ["version": "0.1.123", "build": "1123000"],
            "brokerImplementationVersion": 2,
            "brokerProtocol": ["minimum": 2, "maximum": 2, "securityEpoch": 1],
            "launch": [
                "kind": "native",
                "executable": launchExecutable,
                "arguments": arguments,
            ],
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

    private func rewriteManifestAndRefreshDigest(
        at root: URL,
        mutation: (inout [String: Any]) throws -> Void
    ) throws {
        let url = root.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        try mutation(&manifest)
        let provisional = try JSONDecoder().decode(
            BrokerHelperManifest.self,
            from: JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        )
        manifest["contentDigest"] = BrokerHelperPackageVerification.contentDigest(
            for: provisional
        )
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: url)
        _ = chmod(url.path, 0o644)
    }

    private static func thinMachO(cpuType: UInt32) -> Data {
        var bytes: [UInt8] = [
            0xCF, 0xFA, 0xED, 0xFE,
            UInt8(truncatingIfNeeded: cpuType),
            UInt8(truncatingIfNeeded: cpuType >> 8),
            UInt8(truncatingIfNeeded: cpuType >> 16),
            UInt8(truncatingIfNeeded: cpuType >> 24),
        ]
        bytes.append(contentsOf: [
            0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
        return Data(bytes)
    }

    private func thinMachO(cpuType: UInt32) -> Data {
        Self.thinMachO(cpuType: cpuType)
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
