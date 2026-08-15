import Darwin
import Foundation
import XCTest
@testable import Kaisola
@testable import KaisolaSessionBrokerCore

final class SwiftSessionBrokerConfigurationTests: XCTestCase {
    func testLoadRequiresExplicitShadowMarkerAndOnlyShadowConfigArguments() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--shadow-config", fixture.configurationURL.path],
            environment: [:]
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .shadowModeDisabled)
        }
        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--shadow-config", fixture.configurationURL.path],
            environment: ["KAISOLA_SWIFT_BROKER_SHADOW": "true"]
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .shadowModeDisabled)
        }

        for arguments in [
            ["KaisolaSessionBroker", "--pty-child"],
            [
                "KaisolaSessionBroker", "--shadow-config", fixture.configurationURL.path,
                "--launch", fixture.configurationURL.path,
            ],
            ["KaisolaSessionBroker", "--shadow-config", fixture.configurationURL.path, "extra"],
        ] {
            XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
                arguments: arguments,
                environment: shadowEnvironment
            )) { error in
                XCTAssertEqual(error as? ShadowBrokerConfigurationError, .invalidArguments)
            }
        }
    }

    func testLoadAcceptsAnAbsolutePrivateConfigurationOwnedByTheCurrentUser() throws {
        let fixture = try makeFixture(token: String(repeating: "A", count: 64))
        defer { fixture.cleanup() }

        let configuration = try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--shadow-config", fixture.configurationURL.path],
            environment: shadowEnvironment
        )

        XCTAssertEqual(configuration.protocolVersion, 2)
        XCTAssertEqual(configuration.securityEpoch, 1)
        XCTAssertEqual(configuration.implementationVersion, 2)
        XCTAssertEqual(configuration.packageSchema, 2)
        XCTAssertEqual(configuration.contentDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(configuration.token, String(repeating: "A", count: 64))
        XCTAssertEqual(configuration.socketPath, fixture.socketURL.path)
        XCTAssertEqual(configuration.privateRootURL, fixture.rootURL)
        XCTAssertEqual(configuration.runtimeMode, .shadow)
    }

    func testFreshPTYModeRequiresItsOwnExactMarkerAndArgument() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--fresh-pty-config", fixture.configurationURL.path],
            environment: shadowEnvironment
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .freshPTYModeDisabled)
        }
        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--shadow-config", fixture.configurationURL.path],
            environment: freshPTYEnvironment
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .shadowModeDisabled)
        }
        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--fresh-pty-config", fixture.configurationURL.path],
            environment: shadowEnvironment.merging(freshPTYEnvironment) { _, fresh in fresh }
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .ambiguousRuntimeMode)
        }

        let configuration = try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--fresh-pty-config", fixture.configurationURL.path],
            environment: freshPTYEnvironment
        )
        XCTAssertEqual(configuration.runtimeMode, .freshPTY)
        XCTAssertEqual(configuration.socketURL, fixture.socketURL)
    }

    func testLaunchModeRequiresItsOwnMarkerAndDecodesTheProductionContract() throws {
        let fixture = try makeLaunchFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--launch", fixture.configurationURL.path],
            environment: [:]
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .launchModeDisabled)
        }
        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--launch", fixture.configurationURL.path],
            environment: launchEnvironment.merging(shadowEnvironment) { _, launch in launch }
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .ambiguousRuntimeMode)
        }

        let configuration = try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--launch", fixture.configurationURL.path],
            environment: launchEnvironment
        )
        XCTAssertEqual(configuration.runtimeMode, .launch)
        XCTAssertEqual(configuration.packageSchema, 2)
        XCTAssertEqual(configuration.packageVersion, fixture.packageVersion)
        XCTAssertEqual(configuration.appReleaseVersion, fixture.appReleaseVersion)
        XCTAssertEqual(configuration.appReleaseBuild, fixture.appReleaseBuild)
        XCTAssertEqual(configuration.packageRoot, fixture.packageRoot.path)
        XCTAssertEqual(configuration.infoFile, fixture.infoURL.path)
        XCTAssertEqual(configuration.lockFile, fixture.lockURL.path)
        XCTAssertEqual(configuration.storageDir, fixture.storageURL.path)
        XCTAssertEqual(configuration.logFile, fixture.logURL.path)
        XCTAssertEqual(configuration.maximumLiveTerminals, 3)
        XCTAssertEqual(configuration.startedAt, fixture.startedAt)
        XCTAssertEqual(configuration.version, fixture.version)
        XCTAssertEqual(configuration.smoke, false)
    }

    func testLoadRejectsRelativeSymlinkOrNonPrivateConfigurationFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--shadow-config", "shadow.json"],
            environment: shadowEnvironment
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .unsafePath)
        }

        XCTAssertEqual(chmod(fixture.configurationURL.path, 0o640), 0)
        XCTAssertThrowsError(try load(fixture)) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .unsafePermissions)
        }
        XCTAssertEqual(chmod(fixture.configurationURL.path, 0o600), 0)

        XCTAssertEqual(chmod(fixture.rootURL.path, 0o750), 0)
        XCTAssertThrowsError(try load(fixture)) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .unsafePermissions)
        }
        XCTAssertEqual(chmod(fixture.rootURL.path, 0o700), 0)

        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--shadow-config", fixture.configurationURL.path],
            environment: shadowEnvironment,
            currentUserID: geteuid() &+ 1
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .unsafePermissions)
        }

        let linkURL = fixture.rootURL.appendingPathComponent("linked.json")
        XCTAssertEqual(symlink(fixture.configurationURL.path, linkURL.path), 0)
        XCTAssertThrowsError(try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--shadow-config", linkURL.path],
            environment: shadowEnvironment
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .unsafePermissions)
        }
    }

    func testLoadRequiresExactProtocolTwoShadowIdentity() throws {
        for (key, invalidValue) in [
            ("protocol", 1),
            ("securityEpoch", 2),
            ("implementationVersion", 1),
            ("packageSchema", 1),
        ] {
            let fixture = try makeFixture(overrides: [key: invalidValue])
            defer { fixture.cleanup() }
            XCTAssertThrowsError(try load(fixture), "accepted invalid \(key)") { error in
                XCTAssertEqual(error as? ShadowBrokerConfigurationError, .invalidConfiguration)
            }
        }
    }

    func testLoadRequiresLowercaseSHA256DigestAndExactly64HexToken() throws {
        let invalidValues: [(String, Any)] = [
            ("contentDigest", String(repeating: "A", count: 64)),
            ("contentDigest", String(repeating: "g", count: 64)),
            ("contentDigest", String(repeating: "a", count: 63)),
            ("token", String(repeating: "a", count: 63)),
            ("token", String(repeating: "z", count: 64)),
        ]
        for (key, invalidValue) in invalidValues {
            let fixture = try makeFixture(overrides: [key: invalidValue])
            defer { fixture.cleanup() }
            XCTAssertThrowsError(try load(fixture), "accepted invalid \(key)") { error in
                XCTAssertEqual(error as? ShadowBrokerConfigurationError, .invalidConfiguration)
            }
        }
    }

    func testLoadConfinesTheSocketToTheConfigurationPrivateRoot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        for invalidSocket in [
            "relative.sock",
            fixture.rootURL.deletingLastPathComponent().appendingPathComponent("escaped.sock").path,
            fixture.rootURL.appendingPathComponent("nested/broker.sock").path,
        ] {
            try writeConfiguration(
                to: fixture.configurationURL,
                object: validObject(socketPath: invalidSocket)
            )
            XCTAssertThrowsError(try load(fixture), "accepted \(invalidSocket)") { error in
                XCTAssertEqual(error as? ShadowBrokerConfigurationError, .unsafePath)
            }
        }
    }

    func testDirectConstructionCannotBypassIdentityOrSocketValidation() throws {
        let root = URL(fileURLWithPath: "/tmp/kaisola-shadow-direct", isDirectory: true)
        XCTAssertThrowsError(try ShadowBrokerConfiguration(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: 2,
            contentDigest: String(repeating: "a", count: 64),
            token: String(repeating: "b", count: 64),
            socketPath: root.appendingPathComponent("broker.sock").path
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .invalidConfiguration)
        }
        XCTAssertThrowsError(try ShadowBrokerConfiguration(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 2,
            packageSchema: 2,
            contentDigest: String(repeating: "a", count: 64),
            token: String(repeating: "b", count: 64),
            socketPath: "relative.sock"
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerConfigurationError, .unsafePath)
        }
    }

    func testBuiltKaisolaApplicationPlacesPackagedBrokerOnlyInNativeHelperRoot() throws {
        let products = try builtProductsURL()
        let application = products.appendingPathComponent("Kaisola.app", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: application.path))

        let nativeHelperRoot = application
            .appendingPathComponent("Contents/Resources/BrokerSessionHelper", isDirectory: true)
        let expectedExecutable = nativeHelperRoot
            .appendingPathComponent("bin/kaisola-session-broker")
            .standardizedFileURL

        let brokerExecutables = try XCTUnwrap(
            FileManager.default.enumerator(
                at: application,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        ).compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  ["KaisolaSessionBroker", "kaisola-session-broker"].contains(url.lastPathComponent)
            else {
                return nil
            }
            return url.standardizedFileURL
        }

        if FileManager.default.fileExists(atPath: expectedExecutable.path) {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: expectedExecutable.path))
            XCTAssertEqual(brokerExecutables, [expectedExecutable])
            return
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: nativeHelperRoot.path),
            "native helper root exists without its sealed broker executable"
        )

        XCTAssertTrue(
            brokerExecutables.isEmpty,
            "a loose Swift broker executable must never be embedded in the application"
        )
#if DEBUG
        // The focused Debug test lane deliberately sets
        // KAISOLA_PACKAGE_BROKER_HELPER=0. A Debug app may therefore omit both
        // sealed helpers; setting the packaging override exercises the exact
        // placement assertion above.
#else
        XCTFail("production application is missing the sealed native broker helper")
#endif
    }

    func testBrokerProcessRemovesItsSocketOnSIGTERMAndSIGINT() throws {
        let products = try builtProductsURL()
        let executable = products.appendingPathComponent("KaisolaSessionBroker")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))

        for terminationSignal in [SIGTERM, SIGINT] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["--shadow-config", fixture.configurationURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["KAISOLA_SWIFT_BROKER_SHADOW"] = "1"
            process.environment = environment
            let standardError = Pipe()
            process.standardError = standardError

            try process.run()
            defer {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }

            guard waitUntil(timeout: 5, condition: {
                FileManager.default.fileExists(atPath: fixture.socketURL.path)
            }) else {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                let errorOutput = String(
                    decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
                XCTFail(
                    "broker did not create its socket for signal \(terminationSignal): \(errorOutput)"
                )
                continue
            }

            XCTAssertEqual(Darwin.kill(process.processIdentifier, terminationSignal), 0)
            guard waitUntil(timeout: 5, condition: { !process.isRunning }) else {
                XCTFail("broker did not exit after signal \(terminationSignal)")
                continue
            }
            process.waitUntilExit()
            let errorOutput = String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            XCTAssertEqual(process.terminationReason, .exit, errorOutput)
            XCTAssertEqual(process.terminationStatus, EXIT_SUCCESS, errorOutput)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        }
    }

    func testBrokerProcessHandlesSIGTERMAndSIGINTBeforeSocketCreation() throws {
        let products = try builtProductsURL()
        let executable = products.appendingPathComponent("KaisolaSessionBroker")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))

        for terminationSignal in [SIGTERM, SIGINT] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["--shadow-config", fixture.configurationURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["KAISOLA_SWIFT_BROKER_SHADOW"] = "1"
            environment["KAISOLA_SWIFT_BROKER_TEST_SIGNAL_READY"] = "1"
            process.environment = environment
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.standardOutput = standardOutput
            process.standardError = standardError

            try process.run()
            defer {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }

            guard readWithTimeout(
                from: standardOutput,
                timeoutMilliseconds: 2_000
            ) == "signal-ready\n" else {
                XCTFail("broker did not announce early signal readiness")
                continue
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
            XCTAssertEqual(Darwin.kill(process.processIdentifier, terminationSignal), 0)

            guard waitUntil(timeout: 5, condition: { !process.isRunning }) else {
                XCTFail("broker did not exit after early signal \(terminationSignal)")
                continue
            }
            process.waitUntilExit()
            let errorOutput = String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            XCTAssertEqual(process.terminationReason, .exit, errorOutput)
            XCTAssertEqual(process.terminationStatus, EXIT_SUCCESS, errorOutput)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        }
    }

    func testLaunchModePublishesExactGenerationMetadataAndCleansUpOnSIGTERM() async throws {
        let executable = try builtProductsURL().appendingPathComponent("KaisolaSessionBroker")
        let fixture = try makeLaunchFixture()
        defer { fixture.cleanup() }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--launch", fixture.configurationURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(launchEnvironment) {
            _, launch in launch
        }
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let hello = try await awaitHelloReadiness(
            socketPath: fixture.socketURL.path,
            token: fixture.token,
            process: process,
            standardError: standardError
        )
        XCTAssertEqual(hello["packageVersion"] as? String, fixture.packageVersion)
        XCTAssertEqual(hello["version"] as? String, fixture.version)

        guard waitUntil(timeout: 5, condition: {
            FileManager.default.fileExists(atPath: fixture.infoURL.path)
                && FileManager.default.fileExists(atPath: fixture.lockURL.path)
        }) else {
            return XCTFail("launch broker did not publish its rendezvous files")
        }
        let info = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.infoURL))
                as? [String: Any]
        )
        XCTAssertEqual(Set(info.keys), [
            "protocol", "securityEpoch", "implementationVersion", "packageSchema",
            "packageVersion", "contentDigest", "pid", "socketPath", "token",
            "startedAt", "version",
        ])
        XCTAssertEqual((info["pid"] as? NSNumber)?.int32Value, process.processIdentifier)
        XCTAssertEqual(info["packageVersion"] as? String, fixture.packageVersion)
        XCTAssertEqual(info["version"] as? String, fixture.version)
        XCTAssertEqual(info["socketPath"] as? String, fixture.socketURL.path)
        XCTAssertEqual(info["token"] as? String, fixture.token)
        XCTAssertEqual(
            try String(contentsOf: fixture.lockURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            String(process.processIdentifier)
        )
        var lockMetadata = stat()
        XCTAssertEqual(lstat(fixture.lockURL.path, &lockMetadata), 0)
        XCTAssertEqual(lockMetadata.st_mode & 0o777, 0o600)

        XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGTERM), 0)
        guard waitUntil(timeout: 5, condition: { !process.isRunning }) else {
            return XCTFail("launch broker did not exit after SIGTERM")
        }
        process.waitUntilExit()
        let output = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, EXIT_SUCCESS, output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.infoURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.lockURL.path))
    }

    func testLaunchModeMirrorsNodeStaleGenerationLockRecovery() async throws {
        let executable = try builtProductsURL().appendingPathComponent("KaisolaSessionBroker")

        do {
            let fixture = try makeLaunchFixture()
            defer { fixture.cleanup() }
            try Data("99999998\n".utf8).write(to: fixture.lockURL)
            XCTAssertEqual(chmod(fixture.lockURL.path, 0o600), 0)
            try writeJSON(["pid": 99999997], to: fixture.infoURL)

            let process = try startLaunchBroker(executable: executable, fixture: fixture)
            defer { terminateIfRunning(process.process) }
            _ = try await awaitHelloReadiness(
                socketPath: fixture.socketURL.path,
                token: fixture.token,
                process: process.process,
                standardError: process.standardError
            )
            XCTAssertEqual(
                try String(contentsOf: fixture.lockURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                String(process.process.processIdentifier)
            )
            guard waitUntil(timeout: 2, condition: {
                (try? String(contentsOf: fixture.logURL, encoding: .utf8))?
                    .contains("recovered stale generation lock deadOwner=99999998,99999997") == true
            }) else {
                return XCTFail("stale-lock takeover did not log both dead owners")
            }
            XCTAssertEqual(Darwin.kill(process.process.processIdentifier, SIGTERM), 0)
            XCTAssertTrue(waitUntil(timeout: 5, condition: { !process.process.isRunning }))
            process.process.waitUntilExit()
        }

        for liveOwnerSource in [
            "lock",
            "lock decimal prefix",
            "rendezvous",
            "rendezvous string",
        ] {
            let fixture = try makeLaunchFixture()
            defer { fixture.cleanup() }
            if liveOwnerSource.hasPrefix("lock") {
                let suffix = liveOwnerSource == "lock decimal prefix" ? " trailing-data" : ""
                try Data("\(getpid())\(suffix)\n".utf8).write(to: fixture.lockURL)
                XCTAssertEqual(chmod(fixture.lockURL.path, 0o600), 0)
            } else {
                try Data().write(to: fixture.lockURL)
                XCTAssertEqual(chmod(fixture.lockURL.path, 0o600), 0)
                let rendezvousPID: Any = liveOwnerSource == "rendezvous string"
                    ? String(getpid())
                    : Int(getpid())
                try writeJSON(["pid": rendezvousPID], to: fixture.infoURL)
            }

            let launched = try startLaunchBroker(executable: executable, fixture: fixture)
            defer { terminateIfRunning(launched.process) }
            guard waitUntil(timeout: 5, condition: { !launched.process.isRunning }) else {
                XCTFail("broker took over a lock with a live \(liveOwnerSource) owner")
                continue
            }
            launched.process.waitUntilExit()
            XCTAssertEqual(launched.process.terminationStatus, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
            let lockContents = try String(contentsOf: fixture.lockURL, encoding: .utf8)
            if liveOwnerSource.hasPrefix("lock") {
                XCTAssertEqual(
                    lockContents.trimmingCharacters(in: .whitespacesAndNewlines),
                    String(getpid())
                        + (liveOwnerSource == "lock decimal prefix" ? " trailing-data" : "")
                )
            } else {
                XCTAssertTrue(lockContents.isEmpty)
                let info = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: fixture.infoURL))
                        as? [String: Any]
                )
                if liveOwnerSource == "rendezvous string" {
                    XCTAssertEqual(info["pid"] as? String, String(getpid()))
                } else {
                    XCTAssertEqual((info["pid"] as? NSNumber)?.int32Value, getpid())
                }
            }
        }

        do {
            let fixture = try makeLaunchFixture()
            defer { fixture.cleanup() }
            try Data().write(to: fixture.lockURL)
            XCTAssertEqual(chmod(fixture.lockURL.path, 0o600), 0)
            let alias = fixture.lockURL.deletingLastPathComponent()
                .appendingPathComponent("hard-linked-generation-lock")
            XCTAssertEqual(Darwin.link(fixture.lockURL.path, alias.path), 0)

            let launched = try startLaunchBroker(executable: executable, fixture: fixture)
            defer { terminateIfRunning(launched.process) }
            XCTAssertTrue(waitUntil(timeout: 5, condition: { !launched.process.isRunning }))
            launched.process.waitUntilExit()
            XCTAssertEqual(launched.process.terminationStatus, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
            var lockMetadata = stat()
            XCTAssertEqual(lstat(fixture.lockURL.path, &lockMetadata), 0)
            XCTAssertEqual(lockMetadata.st_nlink, 2)
        }
    }

    func testRealBrokerExecutableSupportsObserveOnlyHelloAndInventory() async throws {
        let executable = try builtProductsURL().appendingPathComponent("KaisolaSessionBroker")
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--shadow-config", fixture.configurationURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["KAISOLA_SWIFT_BROKER_SHADOW"] = "1"
        process.environment = environment
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let metadata = try await awaitHelloReadiness(
            socketPath: fixture.socketURL.path,
            token: String(repeating: "b", count: 64),
            process: process,
            standardError: standardError
        )
        let pid = try XCTUnwrap((metadata["pid"] as? NSNumber)?.int32Value)
        let startedAt = try XCTUnwrap((metadata["startedAt"] as? NSNumber)?.int64Value)
        let version = try XCTUnwrap(metadata["version"] as? String)
        XCTAssertEqual(pid, process.processIdentifier)

        let client = ObserveOnlyBrokerClient(operationTimeoutNanoseconds: 2_000_000_000)
        let info = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 2,
            packageSchema: 2,
            packageVersion: nil,
            contentDigest: String(repeating: "a", count: 64),
            pid: pid,
            socketPath: fixture.socketURL.path,
            token: String(repeating: "b", count: 64),
            startedAt: startedAt,
            version: version
        )

        do {
            let hello = try await client.connect(to: info)
            XCTAssertEqual(hello.implementationVersion, 2)
            XCTAssertEqual(hello.packageSchema, 2)
            XCTAssertTrue(hello.serverEnforcedObserver)
            let inventory = try await client.inventory()
            XCTAssertEqual(inventory.activityEpoch, 1)
            XCTAssertEqual(inventory.terminals, [])
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }

        XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGTERM), 0)
        guard waitUntil(timeout: 5, condition: { !process.isRunning }) else {
            return XCTFail("real broker did not exit after SIGTERM")
        }
        process.waitUntilExit()
        let output = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationReason, .exit, output)
        XCTAssertEqual(process.terminationStatus, EXIT_SUCCESS, output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    private let shadowEnvironment = ["KAISOLA_SWIFT_BROKER_SHADOW": "1"]
    private let freshPTYEnvironment = ["KAISOLA_SWIFT_BROKER_FRESH_PTY": "1"]
    private let launchEnvironment = ["KAISOLA_SWIFT_BROKER_LAUNCH": "1"]

    private func builtProductsURL() throws -> URL {
        var candidate = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let application = candidate.appendingPathComponent("Kaisola.app", isDirectory: true)
            let executable = candidate.appendingPathComponent("KaisolaSessionBroker")
            if FileManager.default.fileExists(atPath: application.path),
               FileManager.default.isExecutableFile(atPath: executable.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(
            domain: "SwiftSessionBrokerConfigurationTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate the Xcode built-products directory"]
        )
    }

    private func load(_ fixture: Fixture) throws -> ShadowBrokerConfiguration {
        try ShadowBrokerConfiguration.load(
            arguments: ["KaisolaSessionBroker", "--shadow-config", fixture.configurationURL.path],
            environment: shadowEnvironment
        )
    }

    private func makeFixture(
        token: String = String(repeating: "b", count: 64),
        overrides: [String: Any] = [:]
    ) throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "ksb-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        let configurationURL = root.appendingPathComponent("shadow.json")
        let socketURL = root.appendingPathComponent("broker.sock")
        var object = validObject(socketPath: socketURL.path)
        object["token"] = token
        for (key, value) in overrides { object[key] = value }
        try writeConfiguration(to: configurationURL, object: object)
        return Fixture(rootURL: root, configurationURL: configurationURL, socketURL: socketURL)
    }

    private func makeLaunchFixture() throws -> LaunchFixture {
        let userData = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "ksb-launch-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let broker = userData.appendingPathComponent("session-broker", isDirectory: true)
        let metadata = broker.appendingPathComponent("generations", isDirectory: true)
        for directory in [userData, broker, metadata] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
        }
        let digest = String(repeating: "c", count: 64)
        let configurationURL = broker.appendingPathComponent(
            "launch-native-\(UUID().uuidString.lowercased()).json"
        )
        let fixture = LaunchFixture(
            userDataURL: userData,
            configurationURL: configurationURL,
            packageRoot: userData
                .appendingPathComponent("broker-generations", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true),
            socketURL: broker.appendingPathComponent(
                BrokerLaunchConfiguration.generationSocketLeaf(
                    userData: userData,
                    contentDigest: digest
                )
            ),
            infoURL: metadata.appendingPathComponent("\(digest).json"),
            lockURL: metadata.appendingPathComponent("\(digest).lock"),
            storageURL: userData.appendingPathComponent("terminal-cache", isDirectory: true),
            logURL: metadata.appendingPathComponent("\(digest).log"),
            contentDigest: digest,
            token: String(repeating: "d", count: 64),
            packageVersion: "2.0.0",
            appReleaseVersion: "0.1.125",
            appReleaseBuild: "1125000",
            startedAt: 1_765_000_000_000,
            version: "0.1.125"
        )
        try writeJSON([
            "protocol": 2,
            "securityEpoch": 1,
            "implementationVersion": 2,
            "packageSchema": 2,
            "packageVersion": fixture.packageVersion,
            "appReleaseVersion": fixture.appReleaseVersion,
            "appReleaseBuild": fixture.appReleaseBuild,
            "contentDigest": fixture.contentDigest,
            "packageRoot": fixture.packageRoot.path,
            "token": fixture.token,
            "socketPath": fixture.socketURL.path,
            "infoFile": fixture.infoURL.path,
            "lockFile": fixture.lockURL.path,
            "storageDir": fixture.storageURL.path,
            "logFile": fixture.logURL.path,
            "maximumLiveTerminals": 3,
            "startedAt": fixture.startedAt,
            "version": fixture.version,
            "smoke": false,
        ], to: configurationURL)
        return fixture
    }

    private func validObject(socketPath: String) -> [String: Any] {
        [
            "protocol": 2,
            "securityEpoch": 1,
            "implementationVersion": 2,
            "packageSchema": 2,
            "contentDigest": String(repeating: "a", count: 64),
            "token": String(repeating: "b", count: 64),
            "socketPath": socketPath,
        ]
    }

    private func writeConfiguration(to url: URL, object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try writeConfiguration(to: url, object: object)
    }

    private func startLaunchBroker(
        executable: URL,
        fixture: LaunchFixture
    ) throws -> (process: Process, standardError: Pipe) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--launch", fixture.configurationURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(launchEnvironment) {
            _, launch in launch
        }
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        return (process, standardError)
    }

    private func terminateIfRunning(_ process: Process) {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private func readWithTimeout(
        from pipe: Pipe,
        timeoutMilliseconds: Int32
    ) -> String? {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds) > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return nil }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
    }

    private func awaitHelloReadiness(
        socketPath: String,
        token: String,
        process: Process,
        standardError: Pipe,
        timeout: Duration = .seconds(5)
    ) async throws -> [String: Any] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: (any Error)?

        while clock.now < deadline {
            if !process.isRunning {
                process.waitUntilExit()
                let output = String(
                    decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
                throw ProbeError.processExited(
                    status: process.terminationStatus,
                    standardError: output
                )
            }
            do {
                return try await probeHello(
                    socketPath: socketPath,
                    token: token,
                    attemptTimeout: .milliseconds(500)
                )
            } catch {
                lastError = error
            }
            if clock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        throw ProbeError.readinessTimedOut(
            lastError: lastError.map(String.init(describing:)) ?? "none"
        )
    }

    private func probeHello(
        socketPath: String,
        token: String,
        attemptTimeout: Duration
    ) async throws -> [String: Any] {
        let transport = UnixBrokerTransport()
        do {
            try await transport.connect(path: socketPath)
            var request = try JSONSerialization.data(withJSONObject: [
                "type": "hello",
                "protocol": 2,
                "token": token,
                "instanceId": UUID().uuidString.lowercased(),
                "access": "observer",
            ], options: [.sortedKeys])
            request.append(0x0a)
            try await transport.send(request)

            let response = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var response = Data()
                    while response.firstIndex(of: 0x0a) == nil {
                        guard let chunk = try await transport.receive(maximumBytes: 64 * 1_024) else {
                            throw ProbeError.unexpectedEOF
                        }
                        response.append(chunk)
                    }
                    return response
                }
                group.addTask {
                    try await Task.sleep(for: attemptTimeout)
                    throw ProbeError.attemptTimedOut
                }
                do {
                    let first = try await group.next() ?? Data()
                    group.cancelAll()
                    await transport.close()
                    return first
                } catch {
                    group.cancelAll()
                    await transport.close()
                    throw error
                }
            }
            let newline = try XCTUnwrap(response.firstIndex(of: 0x0a))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: response[..<newline]) as? [String: Any]
            )
            await transport.close()
            return object
        } catch {
            await transport.close()
            throw error
        }
    }
}

private enum ProbeError: Error, LocalizedError {
    case attemptTimedOut
    case processExited(status: Int32, standardError: String)
    case readinessTimedOut(lastError: String)
    case unexpectedEOF

    var errorDescription: String? {
        switch self {
        case .attemptTimedOut:
            "broker hello attempt timed out"
        case let .processExited(status, standardError):
            "broker exited before hello readiness (status \(status)): \(standardError)"
        case let .readinessTimedOut(lastError):
            "broker hello readiness timed out; last error: \(lastError)"
        case .unexpectedEOF:
            "broker closed before its hello response"
        }
    }
}

private struct Fixture {
    let rootURL: URL
    let configurationURL: URL
    let socketURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct LaunchFixture {
    let userDataURL: URL
    let configurationURL: URL
    let packageRoot: URL
    let socketURL: URL
    let infoURL: URL
    let lockURL: URL
    let storageURL: URL
    let logURL: URL
    let contentDigest: String
    let token: String
    let packageVersion: String
    let appReleaseVersion: String
    let appReleaseBuild: String
    let startedAt: Int64
    let version: String

    func cleanup() {
        try? FileManager.default.removeItem(at: userDataURL)
    }
}
