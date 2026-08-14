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
            ["KaisolaSessionBroker", "--launch", fixture.configurationURL.path],
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

    func testBuiltKaisolaApplicationDoesNotEmbedTheShadowBrokerExecutable() throws {
        let products = try builtProductsURL()
        let application = products.appendingPathComponent("Kaisola.app", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: application.path))

        let embeddedNames = try XCTUnwrap(
            FileManager.default.enumerator(
                at: application,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        ).compactMap { ($0 as? URL)?.lastPathComponent }
        XCTAssertFalse(embeddedNames.contains("KaisolaSessionBroker"))
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
