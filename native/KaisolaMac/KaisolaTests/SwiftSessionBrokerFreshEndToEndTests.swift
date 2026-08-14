import Darwin
import Foundation
import KaisolaBrokerProtocol
import XCTest
@testable import Kaisola
@testable import KaisolaSessionBrokerCore

final class SwiftSessionBrokerFreshEndToEndTests: XCTestCase {
    func testExistingClientsDriveARealFreshZshLifecycleEndToEnd() async throws {
        let fixture = try FreshEndToEndBrokerFixture(
            executablePath: try brokerExecutablePath()
        )
        let controller = BrokerControlClient(operationTimeoutNanoseconds: 5_000_000_000)
        let observer = ObserveOnlyBrokerClient(operationTimeoutNanoseconds: 5_000_000_000)
        var createdShellPID: pid_t?
        var createdDescendantPID: pid_t?

        do {
            let info = try await fixture.start()
            try await controller.connect(to: info, ownerID: fixture.ownerID)
            let observerHello = try await observer.connect(to: info)
            XCTAssertTrue(observerHello.serverEnforcedObserver)
            XCTAssertEqual(observerHello.contentDigest, fixture.digest)

            let creation = try await controller.createTerminal(
                projectID: fixture.projectID,
                terminalID: fixture.terminalID,
                command: "/bin/zsh",
                arguments: ["-f", "-i"],
                cwd: fixture.rootURL.path,
                columns: 90,
                rows: 28,
                restore: false
            )
            let shellPID = try XCTUnwrap(creation.pid)
            createdShellPID = shellPID
            XCTAssertFalse(creation.exited)
            XCTAssertNotNil(creation.streamEpoch)

            let readinessSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let readiness = "__KAISOLA_E2E_READY_\(readinessSuffix)__"
            try await controller.write(
                projectID: fixture.projectID,
                terminalID: fixture.terminalID,
                data: "PS1='kaisola-e2e> '; PROMPT='kaisola-e2e> '; printf '__KAISOLA_E2E_READY_%s__\\n' '\(readinessSuffix)'\n"
            )
            _ = try await waitForSnapshot(
                observer: observer,
                ownerID: fixture.ownerID,
                terminalID: fixture.terminalID,
                containing: readiness
            )

            let markerSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let marker = "__KAISOLA_E2E_\(markerSuffix)__"
            // The complete marker is absent from the terminal-echoed command;
            // only executed zsh output can satisfy the observer assertion.
            try await controller.write(
                projectID: fixture.projectID,
                terminalID: fixture.terminalID,
                data: "printf '__KAISOLA_E2E_%s__\\n' '\(markerSuffix)'\n"
            )
            let markerSnapshot = try await waitForSnapshot(
                observer: observer,
                ownerID: fixture.ownerID,
                terminalID: fixture.terminalID,
                containing: marker
            )
            XCTAssertFalse(markerSnapshot.exited)

            try await controller.resize(
                projectID: fixture.projectID,
                terminalID: fixture.terminalID,
                columns: 132,
                rows: 41
            )
            let resized = try await waitForTerminal(
                observer: observer,
                terminalID: fixture.terminalID
            ) { terminal in
                terminal.columns == 132 && terminal.rows == 41 && !terminal.exited
            }
            XCTAssertEqual(resized.pid, shellPID)

            try await controller.write(
                projectID: fixture.projectID,
                terminalID: fixture.terminalID,
                data: "zsh -f -c 'trap \"\" HUP TERM; printf \"__E2E_DESCENDANT__:%d\\n\" $$; while :; do sleep 30; done'\n"
            )
            let descendantPID = try await waitForDescendantPID(
                observer: observer,
                ownerID: fixture.ownerID,
                terminalID: fixture.terminalID
            )
            createdDescendantPID = descendantPID
            XCTAssertTrue(isProcessAlive(descendantPID))

            try await controller.kill(
                projectID: fixture.projectID,
                terminalID: fixture.terminalID
            )
            let ended = try await waitForTerminal(
                observer: observer,
                terminalID: fixture.terminalID
            ) { $0.exited }
            XCTAssertEqual(ended.pid, shellPID)
            XCTAssertFalse(isProcessAlive(shellPID), "shell leader survived terminal.kill")
            XCTAssertFalse(isProcessAlive(descendantPID), "descendant survived terminal.kill")

            // Kill retains a finished diagnostic and its final output until
            // the stronger release operation explicitly removes the record.
            let endedSnapshot = try await waitForSnapshot(
                observer: observer,
                ownerID: fixture.ownerID,
                terminalID: fixture.terminalID,
                containing: marker
            )
            XCTAssertTrue(endedSnapshot.exited)
            let retainedInventory = try await observer.inventory()
            XCTAssertEqual(retainedInventory.terminals.map(\.id), [fixture.terminalID])

            try await controller.release(
                projectID: fixture.projectID,
                terminalID: fixture.terminalID
            )
            try await waitForNoTerminals(observer: observer)

            await controller.disconnect()
            await observer.disconnect()
            try await fixture.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
            fixture.removeRoot()
        } catch {
            if createdShellPID != nil {
                try? await controller.kill(
                    projectID: fixture.projectID,
                    terminalID: fixture.terminalID
                )
                try? await controller.release(
                    projectID: fixture.projectID,
                    terminalID: fixture.terminalID
                )
            }
            await controller.disconnect()
            await observer.disconnect()
            fixture.forceStop()
            forceKillIfAlive(createdDescendantPID)
            forceKillIfAlive(createdShellPID)
            fixture.removeRoot()
            throw error
        }
    }

    private func brokerExecutablePath() throws -> String {
        var candidate = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let executable = candidate.appendingPathComponent("KaisolaSessionBroker")
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                return executable.path
            }
            candidate.deleteLastPathComponent()
        }
        throw FreshEndToEndTestError.missingBrokerExecutable
    }

    private func waitForTerminal(
        observer: ObserveOnlyBrokerClient,
        terminalID: String,
        predicate: @escaping (BrokerTerminalRecord) -> Bool
    ) async throws -> BrokerTerminalRecord {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let inventory = try await observer.inventory()
            if let terminal = inventory.terminals.first(where: { $0.id == terminalID }),
               predicate(terminal) {
                return terminal
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FreshEndToEndTestError.timedOut("terminal state \(terminalID)")
    }

    private func waitForSnapshot(
        observer: ObserveOnlyBrokerClient,
        ownerID: String,
        terminalID: String,
        containing marker: String
    ) async throws -> TerminalSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let inventory = try await observer.inventory()
            if let terminal = inventory.terminals.first(where: { $0.id == terminalID }) {
                let result = try await observer.subscribe(
                    to: terminal,
                    ownerID: ownerID,
                    cursor: nil
                )
                if case let .snapshot(snapshot, _) = result,
                   snapshot.output.contains(marker) {
                    return snapshot
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FreshEndToEndTestError.timedOut("snapshot marker \(marker)")
    }

    private func waitForNoTerminals(
        observer: ObserveOnlyBrokerClient
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let inventory = try await observer.inventory()
            if inventory.terminals.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FreshEndToEndTestError.timedOut("released terminal removal")
    }

    private func waitForDescendantPID(
        observer: ObserveOnlyBrokerClient,
        ownerID: String,
        terminalID: String
    ) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let inventory = try await observer.inventory()
            if let terminal = inventory.terminals.first(where: { $0.id == terminalID }) {
                let result = try await observer.subscribe(
                    to: terminal,
                    ownerID: ownerID,
                    cursor: nil
                )
                if case let .snapshot(snapshot, _) = result,
                   let pid = try? descendantPID(from: snapshot.output) {
                    return pid
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FreshEndToEndTestError.timedOut("executed descendant PID")
    }

    private func descendantPID(from output: String) throws -> pid_t {
        let expression = try NSRegularExpression(pattern: "__E2E_DESCENDANT__:([0-9]+)")
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              let pidRange = Range(match.range(at: 1), in: output),
              let pid = pid_t(output[pidRange]),
              pid > 1 else {
            throw FreshEndToEndTestError.missingDescendantPID
        }
        return pid
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func forceKillIfAlive(_ pid: pid_t?) {
        guard let pid, pid > 1, isProcessAlive(pid) else { return }
        _ = Darwin.kill(-pid, SIGKILL)
        _ = Darwin.kill(pid, SIGKILL)
    }
}

private final class FreshEndToEndBrokerFixture: @unchecked Sendable {
    let token = String(repeating: "a", count: 64)
    let digest = String(repeating: "b", count: 64)
    let ownerID = "fresh-e2e-owner"
    let projectID = "nproj_fresh_e2e"
    let terminalID = "term-nproj_fresh_e2e-1234abcd"
    let rootURL: URL
    let socketURL: URL

    private let executablePath: String
    private let configurationURL: URL
    private let process = Process()
    private let standardError = Pipe()
    private var started = false

    init(executablePath: String) throws {
        self.executablePath = executablePath
        rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("kfe-\(UUID().uuidString.lowercased())", isDirectory: true)
        socketURL = rootURL.appendingPathComponent("broker.sock")
        configurationURL = rootURL.appendingPathComponent("fresh.json")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(rootURL.path, 0o700) == 0 else {
            throw FreshEndToEndTestError.posix(errno)
        }
        let configuration: [String: Any] = [
            "protocol": 2,
            "securityEpoch": 1,
            "implementationVersion": 2,
            "packageSchema": 2,
            "contentDigest": digest,
            "token": token,
            "socketPath": socketURL.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        try data.write(to: configurationURL, options: .atomic)
        guard chmod(configurationURL.path, 0o600) == 0 else {
            throw FreshEndToEndTestError.posix(errno)
        }
    }

    func start() async throws -> BrokerInfo {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--fresh-pty-config", configurationURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KAISOLA_SWIFT_BROKER_SHADOW")
        environment["KAISOLA_SWIFT_BROKER_FRESH_PTY"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        started = true
        try await waitForSocket()

        let hello = try probeHello()
        let pid = try requiredInt32(hello, key: "pid")
        guard pid == process.processIdentifier else {
            throw FreshEndToEndTestError.invalidHello("pid")
        }
        return BrokerInfo(
            protocolVersion: try requiredInt(hello, key: "protocol"),
            securityEpoch: try requiredInt(hello, key: "securityEpoch"),
            implementationVersion: try requiredInt(hello, key: "implementationVersion"),
            packageSchema: try requiredInt(hello, key: "packageSchema"),
            packageVersion: hello["packageVersion"] as? String,
            contentDigest: try requiredString(hello, key: "contentDigest"),
            pid: pid,
            socketPath: socketURL.path,
            token: token,
            startedAt: try requiredInt64(hello, key: "startedAt"),
            version: try requiredString(hello, key: "version")
        )
    }

    func stop() async throws {
        guard started else { return }
        if process.isRunning {
            guard Darwin.kill(process.processIdentifier, SIGTERM) == 0 else {
                throw FreshEndToEndTestError.posix(errno)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !process.isRunning else {
            throw FreshEndToEndTestError.timedOut("broker SIGTERM")
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS else {
            throw FreshEndToEndTestError.brokerFailed(errorOutput())
        }
        started = false
    }

    func forceStop() {
        guard started else { return }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        started = false
    }

    func removeRoot() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func waitForSocket() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            var metadata = stat()
            if lstat(socketURL.path, &metadata) == 0,
               metadata.st_mode & S_IFMT == S_IFSOCK {
                return
            }
            if !process.isRunning {
                process.waitUntilExit()
                throw FreshEndToEndTestError.brokerFailed(errorOutput())
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FreshEndToEndTestError.timedOut("broker socket")
    }

    private func probeHello() throws -> [String: Any] {
        let socket = try FreshEndToEndSocket(path: socketURL.path)
        defer { socket.close() }
        try socket.sendJSON([
            "type": "hello",
            "protocol": 2,
            "token": token,
            "instanceId": UUID().uuidString.lowercased(),
            "appVersion": "fresh-e2e-probe",
            "access": "observer",
        ])
        let response = try socket.receiveJSON()
        guard response["ok"] as? Bool == true else {
            throw FreshEndToEndTestError.invalidHello("rejected")
        }
        return response
    }

    private func requiredString(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String else {
            throw FreshEndToEndTestError.invalidHello(key)
        }
        return value
    }

    private func requiredInt(_ object: [String: Any], key: String) throws -> Int {
        guard let value = (object[key] as? NSNumber)?.intValue else {
            throw FreshEndToEndTestError.invalidHello(key)
        }
        return value
    }

    private func requiredInt32(_ object: [String: Any], key: String) throws -> Int32 {
        guard let value = (object[key] as? NSNumber)?.int32Value else {
            throw FreshEndToEndTestError.invalidHello(key)
        }
        return value
    }

    private func requiredInt64(_ object: [String: Any], key: String) throws -> Int64 {
        guard let value = (object[key] as? NSNumber)?.int64Value else {
            throw FreshEndToEndTestError.invalidHello(key)
        }
        return value
    }

    private func errorOutput() -> String {
        String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    }
}

private final class FreshEndToEndSocket {
    private var descriptor: Int32

    init(path: String) throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw FreshEndToEndTestError.posix(ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }

        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FreshEndToEndTestError.posix(errno) }
        let addressLength = socklen_t(address.sun_len)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            descriptor = -1
            throw FreshEndToEndTestError.posix(code)
        }
    }

    deinit { close() }

    func sendJSON(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { throw FreshEndToEndTestError.posix(errno) }
                offset += count
            }
        }
    }

    func receiveJSON() throws -> [String: Any] {
        var data = Data()
        while true {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            guard Darwin.poll(&pollDescriptor, 1, 2_000) > 0 else {
                throw FreshEndToEndTestError.timedOut("hello probe")
            }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            guard count > 0 else { throw FreshEndToEndTestError.unexpectedEOF }
            if byte == 0x0a { break }
            data.append(byte)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FreshEndToEndTestError.invalidHello("json")
        }
        return object
    }

    func close() {
        guard descriptor >= 0 else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }
}

private enum FreshEndToEndTestError: Error, LocalizedError {
    case brokerFailed(String)
    case invalidHello(String)
    case missingBrokerExecutable
    case missingDescendantPID
    case posix(Int32)
    case timedOut(String)
    case unexpectedEOF

    var errorDescription: String? {
        switch self {
        case let .brokerFailed(output): "broker process failed: \(output)"
        case let .invalidHello(field): "invalid broker hello field: \(field)"
        case .missingBrokerExecutable: "could not locate KaisolaSessionBroker"
        case .missingDescendantPID: "real descendant PID was not present in PTY output"
        case let .posix(code): String(cString: strerror(code))
        case let .timedOut(operation): "timed out waiting for \(operation)"
        case .unexpectedEOF: "broker closed the hello probe unexpectedly"
        }
    }
}
