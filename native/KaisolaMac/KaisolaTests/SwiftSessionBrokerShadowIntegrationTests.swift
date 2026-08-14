import Darwin
import Foundation
import KaisolaBrokerProtocol
import XCTest
@testable import Kaisola
@testable import KaisolaSessionBrokerCore

final class SwiftSessionBrokerShadowIntegrationTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)
    private let digest = String(repeating: "b", count: 64)
    private let instanceID = "123e4567-e89b-42d3-a456-426614174000"

    func testAuthenticatedConnectionDispatchesInventoryAndCleansUpItsSocket() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let server = try BrokerServer(configuration: fixture.configuration)
        let running = Task { try await server.run() }
        try await fixture.waitForSocket()

        let client = try UnixTestClient(path: fixture.socketURL.path)
        try client.sendJSON([
            "type": "hello",
            "protocol": 2,
            "token": token,
            "instanceId": instanceID,
            "appVersion": "0.1.124",
            "access": "observer",
        ])
        let hello = try client.receiveJSON()
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["ok"] as? Bool, true)
        XCTAssertEqual(hello["access"] as? String, "observer")
        XCTAssertEqual(hello["protocol"] as? Int, 2)
        XCTAssertEqual(hello["securityEpoch"] as? Int, 1)
        XCTAssertEqual(hello["implementationVersion"] as? Int, 2)
        XCTAssertEqual(hello["packageSchema"] as? Int, 2)
        XCTAssertEqual(hello["contentDigest"] as? String, digest)

        try client.sendJSON([
            "type": "request",
            "id": "inventory-1",
            "method": "broker.inventory",
            "params": [:],
        ])
        let response = try client.receiveJSON()
        XCTAssertEqual(response["type"] as? String, "response")
        XCTAssertEqual(response["id"] as? String, "inventory-1")
        XCTAssertEqual(response["ok"] as? Bool, true)
        let inventory = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(inventory["ok"] as? Bool, true)
        XCTAssertEqual(inventory["state"] as? String, "stable")
        let epoch = try XCTUnwrap(inventory["activityEpoch"] as? Int)
        XCTAssertGreaterThan(epoch, 0)
        let status = try XCTUnwrap(inventory["status"] as? [String: Any])
        XCTAssertEqual(status["activityEpoch"] as? Int, epoch)
        XCTAssertEqual((inventory["diagnostics"] as? [Any])?.count, 0)
        XCTAssertEqual((inventory["live"] as? [Any])?.count, 0)

        client.close()
        await server.stop()
        _ = try await running.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    func testExistingObserveOnlyClientConnectsAndReadsAtomicInventory() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let startedAt: Int64 = 1_786_000_000_000
        let version = "kaisola-swift-shadow-test"
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid(),
            servicePID: getpid(),
            serviceStartedAt: startedAt,
            serviceVersion: version
        )
        let running = Task { try await server.run() }
        try await fixture.waitForSocket()
        let client = ObserveOnlyBrokerClient(operationTimeoutNanoseconds: 2_000_000_000)
        let info = BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: BrokerWire.nativeHelperPackageSchema,
            packageVersion: nil,
            contentDigest: digest,
            pid: getpid(),
            socketPath: fixture.socketURL.path,
            token: token,
            startedAt: startedAt,
            version: version
        )

        do {
            let hello = try await client.connect(to: info)
            XCTAssertTrue(hello.serverEnforcedObserver)
            XCTAssertEqual(hello.packageSchema, BrokerWire.nativeHelperPackageSchema)
            XCTAssertEqual(hello.contentDigest, digest)
            let inventory = try await client.inventory()
            XCTAssertEqual(inventory.activityEpoch, 1)
            XCTAssertEqual(inventory.terminals, [])
            await client.disconnect()
            await server.stop()
            _ = try await running.value
        } catch {
            await client.disconnect()
            await server.stop()
            _ = try? await running.value
            throw error
        }
    }

    func testPeerUIDIsRejectedBeforeTheServerReadsHello() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid() &+ 1
        )
        let running = Task { try await server.run() }
        try await fixture.waitForSocket()

        let client = try UnixTestClient(path: fixture.socketURL.path)
        XCTAssertTrue(try client.waitForEOF(timeoutMilliseconds: 1_000))

        await server.stop()
        _ = try await running.value
    }

    func testInvalidUTF8AndOversizedUnterminatedFramesFailClosedWithoutStoppingServer() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let server = try BrokerServer(configuration: fixture.configuration)
        let running = Task { try await server.run() }
        try await fixture.waitForSocket()

        let invalidUTF8 = try UnixTestClient(path: fixture.socketURL.path)
        try invalidUTF8.send(Data([0xff, 0xfe, 0x0a]))
        XCTAssertTrue(try invalidUTF8.waitForEOF(timeoutMilliseconds: 1_000))

        let oversized = try UnixTestClient(path: fixture.socketURL.path)
        try oversized.send(Data(repeating: 0x61, count: 64 * 1_024 + 1))
        XCTAssertTrue(try oversized.waitForEOF(timeoutMilliseconds: 1_000))

        let healthy = try UnixTestClient(path: fixture.socketURL.path)
        try healthy.sendJSON([
            "type": "hello",
            "protocol": 2,
            "token": token,
            "instanceId": instanceID,
            "access": "observer",
        ])
        XCTAssertEqual(try healthy.receiveJSON()["ok"] as? Bool, true)

        healthy.close()
        await server.stop()
        _ = try await running.value
    }

    func testSameUIDStaleSocketIsRecovered() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        try bindAndAbandonSocket(at: fixture.socketURL.path)
        let staleIdentity = try socketIdentity(at: fixture.socketURL.path)

        let server = try BrokerServer(configuration: fixture.configuration)
        let running = Task { try await server.run() }
        try await fixture.waitForSocket(differentFrom: staleIdentity)

        let client = try UnixTestClient(path: fixture.socketURL.path)
        try client.sendJSON([
            "type": "hello",
            "protocol": 2,
            "token": token,
            "instanceId": instanceID,
            "access": "observer",
        ])
        XCTAssertEqual(try client.receiveJSON()["ok"] as? Bool, true)

        client.close()
        await server.stop()
        _ = try await running.value
    }

    func testServerNeverUnlinksSymlinkRegularForeignOrLiveSocketPaths() async throws {
        try await assertRefusesAndPreservesPath(kind: .symlink)
        try await assertRefusesAndPreservesPath(kind: .regularFile)
        try await assertRefusesAndPreservesPath(kind: .foreignSocket)
        try await assertRefusesAndPreservesPath(kind: .liveSocket)
    }

    func testChangedStaleSocketIsNotUnlinked() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        try bindAndAbandonSocket(at: fixture.socketURL.path)
        let marker = Data("replacement".utf8)
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid(),
            beforeStaleSocketRemoval: {
                _ = Darwin.unlink(fixture.socketURL.path)
                FileManager.default.createFile(
                    atPath: fixture.socketURL.path,
                    contents: marker,
                    attributes: [.posixPermissions: 0o600]
                )
            }
        )

        await XCTAssertThrowsErrorAsync(try await server.run())
        XCTAssertEqual(try Data(contentsOf: fixture.socketURL), marker)
    }

    func testCleanupDoesNotUnlinkAReplacementAtTheCreatedSocketPath() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let server = try BrokerServer(configuration: fixture.configuration)
        let running = Task { try await server.run() }
        try await fixture.waitForSocket()

        _ = Darwin.unlink(fixture.socketURL.path)
        let marker = Data("replacement".utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: fixture.socketURL.path,
            contents: marker,
            attributes: [.posixPermissions: 0o600]
        ))

        await server.stop()
        _ = try await running.value
        XCTAssertEqual(try Data(contentsOf: fixture.socketURL), marker)
    }

    func testSocketReplacementAfterBindIsPreservedAndStartupFails() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let replacementIdentity = LockedBox<PathIdentity?>(nil)
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid(),
            afterSocketBind: {
                guard Darwin.unlink(fixture.socketURL.path) == 0 else {
                    throw currentPOSIXError()
                }
                try bindAndAbandonSocket(at: fixture.socketURL.path)
                replacementIdentity.set(try socketIdentity(at: fixture.socketURL.path))
            }
        )

        do {
            try await server.run()
            XCTFail("expected the replaced socket path to fail startup")
        } catch {
            XCTAssertEqual(error as? BrokerServerError, .socketChanged)
        }

        let injected = try XCTUnwrap(replacementIdentity.value)
        let preserved = try socketIdentity(at: fixture.socketURL.path)
        XCTAssertEqual(preserved.device, injected.device)
        XCTAssertEqual(preserved.inode, injected.inode)
    }

    func testFailureAfterSocketChmodRemovesExactCreatedSocket() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid(),
            afterSocketChmodValidation: {
                throw TestSocketError.injectedFailure
            }
        )

        do {
            try await server.run()
            XCTFail("expected the injected post-chmod failure")
        } catch {
            XCTAssertEqual(error as? TestSocketError, .injectedFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    func testStopDuringListenerPreparationReturnsNormallyAndCleansUpCreatedSocket() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let hookEntered = LockedBox(false)
        let releasePreparation = DispatchSemaphore(value: 0)
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid(),
            afterSocketBind: {
                hookEntered.set(true)
                releasePreparation.wait()
            }
        )
        let running = Task { try await server.run() }
        defer { releasePreparation.signal() }
        try await waitUntil { hookEntered.value }

        await server.stop()
        releasePreparation.signal()

        do {
            try await running.value
        } catch {
            XCTFail("an intentional stop during preparation must return normally: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
    }

    func testPreAuthenticationCapacityRejectsExcessSocketAndRecoversAfterClose() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let log = BrokerLog()
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid(),
            log: log,
            maximumPreAuthenticationConnections: 2,
            helloTimeoutMilliseconds: 5_000
        )
        let running = Task { try await server.run() }
        try await fixture.waitForSocket()

        let firstIdle = try UnixTestClient(path: fixture.socketURL.path)
        let secondIdle = try UnixTestClient(path: fixture.socketURL.path)
        try await waitUntil {
            log.snapshot().filter { $0 == "connection_accepted" }.count == 2
        }

        let excess = try UnixTestClient(path: fixture.socketURL.path)
        XCTAssertTrue(try excess.waitForEOF(timeoutMilliseconds: 1_000))

        firstIdle.close()
        let healthy = try await connectAuthenticatedClientEventually(to: fixture.socketURL.path)
        try assertStatusRequestSucceeds(on: healthy, id: "capacity-recovered")

        let postAuthenticationIdle = try UnixTestClient(path: fixture.socketURL.path)
        try await waitUntil {
            log.snapshot().filter { $0 == "connection_accepted" }.count == 4
        }

        postAuthenticationIdle.close()
        healthy.close()
        secondIdle.close()
        await server.stop()
        _ = try await running.value
    }

    func testIdleHelloDeadlineClosesSocketAndReleasesCapacityForHealthyClient() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let log = BrokerLog()
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid(),
            log: log,
            maximumPreAuthenticationConnections: 1,
            helloTimeoutMilliseconds: 200
        )
        let running = Task { try await server.run() }
        try await fixture.waitForSocket()

        let idle = try UnixTestClient(path: fixture.socketURL.path)
        try await waitUntil {
            log.snapshot().contains("connection_accepted")
        }
        XCTAssertTrue(try idle.waitForEOF(timeoutMilliseconds: 1_000))

        let healthy = try await connectAuthenticatedClientEventually(to: fixture.socketURL.path)
        try assertStatusRequestSucceeds(on: healthy, id: "timeout-recovered")

        healthy.close()
        await server.stop()
        _ = try await running.value
    }

    func testIncompleteHelloDripCannotExtendAbsoluteDeadline() async throws {
        let fixture = try ServerFixture(testName: #function, token: token, digest: digest)
        let log = BrokerLog()
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid(),
            log: log,
            maximumPreAuthenticationConnections: 1,
            helloTimeoutMilliseconds: 250
        )
        let running = Task { try await server.run() }
        try await fixture.waitForSocket()

        let drip = try UnixTestClient(path: fixture.socketURL.path)
        try await waitUntil {
            log.snapshot().contains("connection_accepted")
        }
        try drip.send(Data([0x7b]))
        try await Task.sleep(for: .milliseconds(80))
        try drip.send(Data([0x20]))
        try await Task.sleep(for: .milliseconds(80))
        try drip.send(Data([0x20]))

        XCTAssertTrue(try drip.waitForEOF(timeoutMilliseconds: 140))

        let healthy = try await connectAuthenticatedClientEventually(to: fixture.socketURL.path)
        try assertStatusRequestSucceeds(on: healthy, id: "drip-timeout-recovered")
        healthy.close()
        await server.stop()
        _ = try await running.value
    }

    func testBrokerLogIsBoundedAndNeverRecordsRawIdentityOrPayloads() {
        let secret = String(repeating: "f", count: 64)
        let log = BrokerLog(capacity: 3, maximumEntryBytes: 80)

        for index in 0..<12 {
            log.recordRequest(
                method: index == 11 ? secret : "broker.status",
                clientID: "client-\(secret)",
                paramsDescription: "{token:\(secret)}"
            )
        }

        let entries = log.snapshot()
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.allSatisfy { Data($0.utf8).count <= 80 })
        XCTAssertFalse(entries.joined(separator: "\n").contains(secret))
        XCTAssertFalse(entries.joined(separator: "\n").contains("token"))
    }

    private func connectAuthenticatedClientEventually(
        to path: String,
        timeoutMilliseconds: Int = 1_000
    ) async throws -> UnixTestClient {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            let candidate = try UnixTestClient(path: path)
            do {
                try candidate.sendJSON([
                    "type": "hello",
                    "protocol": 2,
                    "token": token,
                    "instanceId": instanceID,
                    "access": "observer",
                ])
                let response = try candidate.receiveJSON(timeoutMilliseconds: 100)
                if response["ok"] as? Bool == true { return candidate }
            } catch {
                candidate.close()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestSocketError.timeout
    }

    private func assertStatusRequestSucceeds(
        on client: UnixTestClient,
        id: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try client.sendJSON([
            "type": "request",
            "id": id,
            "method": "broker.status",
            "params": [:],
        ])
        let response = try client.receiveJSON()
        XCTAssertEqual(response["id"] as? String, id, file: file, line: line)
        XCTAssertEqual(response["ok"] as? Bool, true, file: file, line: line)
    }

    private enum ExistingPathKind {
        case symlink
        case regularFile
        case foreignSocket
        case liveSocket
    }

    private func assertRefusesAndPreservesPath(
        kind: ExistingPathKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try ServerFixture(
            testName: "\(#function)-\(String(describing: kind))",
            token: token,
            digest: digest
        )
        var liveDescriptor: Int32 = -1
        defer {
            if liveDescriptor >= 0 { Darwin.close(liveDescriptor) }
        }

        let expectedSocketOwnerUID: uid_t
        switch kind {
        case .symlink:
            let target = fixture.rootURL.appendingPathComponent("target")
            XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
            XCTAssertEqual(Darwin.symlink(target.path, fixture.socketURL.path), 0)
            expectedSocketOwnerUID = geteuid()
        case .regularFile:
            XCTAssertTrue(FileManager.default.createFile(
                atPath: fixture.socketURL.path,
                contents: Data("keep".utf8)
            ))
            expectedSocketOwnerUID = geteuid()
        case .foreignSocket:
            try bindAndAbandonSocket(at: fixture.socketURL.path)
            expectedSocketOwnerUID = geteuid() &+ 1
        case .liveSocket:
            liveDescriptor = try bindListeningSocket(at: fixture.socketURL.path)
            expectedSocketOwnerUID = geteuid()
        }
        let before = try pathIdentity(at: fixture.socketURL.path)
        let server = try BrokerServer(
            configuration: fixture.configuration,
            expectedPeerUID: geteuid(),
            expectedSocketOwnerUID: expectedSocketOwnerUID
        )

        await XCTAssertThrowsErrorAsync(try await server.run(), file: file, line: line)
        XCTAssertEqual(try pathIdentity(at: fixture.socketURL.path), before, file: file, line: line)
    }
}

private final class ServerFixture: @unchecked Sendable {
    let rootURL: URL
    let socketURL: URL
    let configuration: ShadowBrokerConfiguration

    init(testName: String, token: String, digest: String) throws {
        _ = testName
        rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("kss-\(UUID().uuidString.lowercased())", isDirectory: true)
        socketURL = rootURL.appendingPathComponent("broker.sock")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(rootURL.path, 0o700)
        configuration = try ShadowBrokerConfiguration(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 2,
            packageSchema: 2,
            contentDigest: digest,
            token: token,
            socketPath: socketURL.path
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func waitForSocket(
        differentFrom prior: PathIdentity? = nil,
        timeoutMilliseconds: Int = 3_000
    ) async throws {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
        while ContinuousClock.now < deadline {
            if let identity = try? socketIdentity(at: socketURL.path), identity != prior {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestSocketError.timeout
    }
}

private final class UnixTestClient {
    private var descriptor: Int32

    init(path: String) throws {
        descriptor = try connectSocket(at: path)
    }

    deinit { close() }

    func sendJSON(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0a)
        try send(data)
    }

    func send(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { throw currentPOSIXError() }
                offset += count
            }
        }
    }

    func receiveJSON(timeoutMilliseconds: Int = 2_000) throws -> [String: Any] {
        let data = try receiveLine(timeoutMilliseconds: timeoutMilliseconds)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func waitForEOF(timeoutMilliseconds: Int) throws -> Bool {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard Darwin.poll(&pollDescriptor, 1, Int32(timeoutMilliseconds)) > 0 else { return false }
        var byte: UInt8 = 0
        return Darwin.read(descriptor, &byte, 1) == 0
    }

    func close() {
        guard descriptor >= 0 else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }

    private func receiveLine(timeoutMilliseconds: Int) throws -> Data {
        var result = Data()
        while true {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            guard Darwin.poll(&pollDescriptor, 1, Int32(timeoutMilliseconds)) > 0 else {
                throw TestSocketError.timeout
            }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            guard count > 0 else { throw TestSocketError.unexpectedEOF }
            if byte == 0x0a { return result }
            result.append(byte)
        }
    }
}

private struct PathIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let owner: uid_t
}

private func pathIdentity(at path: String) throws -> PathIdentity {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw currentPOSIXError() }
    return PathIdentity(device: info.st_dev, inode: info.st_ino, mode: info.st_mode, owner: info.st_uid)
}

private func socketIdentity(at path: String) throws -> PathIdentity {
    let identity = try pathIdentity(at: path)
    guard identity.mode & S_IFMT == S_IFSOCK else { throw TestSocketError.notSocket }
    return identity
}

private func bindAndAbandonSocket(at path: String) throws {
    let descriptor = try bindListeningSocket(at: path)
    Darwin.close(descriptor)
}

private func bindListeningSocket(at path: String) throws -> Int32 {
    var address = try unixAddress(path: path)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw currentPOSIXError() }
    let addressLength = socklen_t(address.sun_len)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, addressLength)
        }
    }
    guard result == 0, Darwin.listen(descriptor, 4) == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return descriptor
}

private func connectSocket(at path: String) throws -> Int32 {
    var address = try unixAddress(path: path)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw currentPOSIXError() }
    var noSigPipe: Int32 = 1
    let noSigPipeResult = withUnsafePointer(to: &noSigPipe) {
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            $0,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
    guard noSigPipeResult == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    let addressLength = socklen_t(address.sun_len)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, addressLength)
        }
    }
    guard result == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return descriptor
}

private func unixAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8)
    var address = sockaddr_un()
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXError(.ENAMETOOLONG)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    return address
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private func waitUntil(
    timeoutMilliseconds: Int = 1_000,
    condition: @escaping @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMilliseconds)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestSocketError.timeout
}

private enum TestSocketError: Error, Equatable {
    case injectedFailure
    case notSocket
    case timeout
    case unexpectedEOF
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
