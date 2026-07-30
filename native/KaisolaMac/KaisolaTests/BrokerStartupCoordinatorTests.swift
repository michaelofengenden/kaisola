import Darwin
import Foundation
import XCTest
@testable import Kaisola

final class BrokerStartupCoordinatorTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testMissingBrokerStartsPackagedHelperAndAdoptsPublishedIdentity() async throws {
        let home = try privateTemporaryDirectory()
        let profile = home.appendingPathComponent("Kaisola", isDirectory: true)
        let locator = BrokerInfoLocator(userDataCandidates: [profile])
        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test"
        )

        let info = try await coordinator.prepare()
        XCTAssertEqual(info.pid, getpid())
        XCTAssertEqual(info.implementationVersion, 1)
        XCTAssertEqual(info.packageVersion, "test-package")
        XCTAssertEqual(info.contentDigest, String(repeating: "d", count: 64))
        let launchCount = await launcher.launchCount
        XCTAssertEqual(launchCount, 1)
        await launcher.close()
    }

    func testLiveIncompatibleBrokerIsNeverReplaced() async throws {
        let home = try privateTemporaryDirectory()
        let profile = home.appendingPathComponent("Kaisola", isDirectory: true)
        let broker = profile.appendingPathComponent("session-broker", isDirectory: true)
        try FileManager.default.createDirectory(
            at: broker,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(profile.path, 0o700)
        _ = chmod(broker.path, 0o700)
        let socket = broker.appendingPathComponent("broker.sock")
        let descriptor = try bindUnixSocket(at: socket)
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: socket)
        }
        let metadata: [String: Any] = [
            "protocol": 99,
            "securityEpoch": 1,
            "pid": getpid(),
            "socketPath": socket.path,
            "token": String(repeating: "b", count: 64),
            "startedAt": 1,
            "version": "incompatible",
        ]
        let infoURL = broker.appendingPathComponent("broker.json")
        try JSONSerialization.data(withJSONObject: metadata).write(to: infoURL)
        _ = chmod(infoURL.path, 0o600)

        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [profile]),
            launcher: launcher,
            homeDirectory: home
        )
        do {
            _ = try await coordinator.prepare()
            XCTFail("expected incompatible live broker refusal")
        } catch {
            XCTAssertEqual(error as? BrokerDiscoveryError, .unsupportedProtocol(99))
        }
        let launchCount = await launcher.launchCount
        XCTAssertEqual(launchCount, 0)
    }

    func testDeadBrokerWithStaleSocketIsSafelyReplaced() async throws {
        let home = try privateTemporaryDirectory()
        let profile = home.appendingPathComponent("Kaisola", isDirectory: true)
        let broker = profile.appendingPathComponent("session-broker", isDirectory: true)
        try FileManager.default.createDirectory(
            at: broker,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(profile.path, 0o700)
        _ = chmod(broker.path, 0o700)

        let socket = broker.appendingPathComponent("broker.sock")
        let staleDescriptor = try bindUnixSocket(at: socket)
        Darwin.close(staleDescriptor)
        let metadata: [String: Any] = [
            "protocol": 2,
            "securityEpoch": 1,
            "implementationVersion": 1,
            "packageSchema": 1,
            "packageVersion": "stale-package",
            "pid": Int32.max,
            "socketPath": socket.path,
            "token": String(repeating: "c", count: 64),
            "startedAt": 1,
            "version": "stale",
        ]
        let infoURL = broker.appendingPathComponent("broker.json")
        try JSONSerialization.data(withJSONObject: metadata).write(to: infoURL)
        _ = chmod(infoURL.path, 0o600)

        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [profile]),
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test"
        )

        let info = try await coordinator.prepare()
        XCTAssertEqual(info.pid, getpid())
        XCTAssertEqual(info.packageVersion, "test-package")
        let launchCount = await launcher.launchCount
        XCTAssertEqual(launchCount, 1)
        await launcher.close()
    }

    func testStaleLiveBrokerDefersWithExactAuthoritativeBlockers() async throws {
        let home = try privateTemporaryDirectory()
        let blockers = BrokerUpgradeBlockers(
            liveTerminalCount: 2,
            liveTerminalIDs: ["claude", "codex"],
            busyAgentCount: 1,
            busyTerminalIDs: ["claude"],
            childTaskCount: 1
        )
        let live = try makeLiveBroker(home: home, contentDigest: String(repeating: "e", count: 64))
        defer { Darwin.close(live.descriptor) }
        let requester = FakeBrokerUpgradeRequester(decision: .deferred(blockers))
        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: launcher,
            homeDirectory: home,
            upgradeRequester: requester
        )

        let adopted = try await coordinator.prepare()
        let state = await coordinator.upgradeState()
        let requestCount = await requester.callCount
        let launchCount = await launcher.launchCount

        XCTAssertEqual(adopted.contentDigest, String(repeating: "e", count: 64))
        XCTAssertEqual(state, .pending(
            fromContentDigest: String(repeating: "e", count: 64),
            targetContentDigest: String(repeating: "d", count: 64),
            reason: .liveWork(blockers)
        ))
        XCTAssertTrue(state.detail.contains(String(repeating: "e", count: 64)))
        XCTAssertTrue(state.detail.contains(String(repeating: "d", count: 64)))
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(launchCount, 0)
    }

    func testLegacyLiveBrokerIsPreservedWithoutARacyClientSideShutdown() async throws {
        let home = try privateTemporaryDirectory()
        let live = try makeLiveBroker(home: home, contentDigest: nil)
        defer { Darwin.close(live.descriptor) }
        let requester = FakeBrokerUpgradeRequester(decision: .accepted)
        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: launcher,
            homeDirectory: home,
            upgradeRequester: requester
        )

        let adopted = try await coordinator.prepare()
        let state = await coordinator.upgradeState()
        let requestCount = await requester.callCount
        let launchCount = await launcher.launchCount

        XCTAssertNil(adopted.contentDigest)
        XCTAssertEqual(state, .pending(
            fromContentDigest: nil,
            targetContentDigest: String(repeating: "d", count: 64),
            reason: .legacyIdentityUnavailable
        ))
        XCTAssertTrue(state.detail.contains("legacy-unsealed"))
        XCTAssertTrue(state.detail.contains(String(repeating: "d", count: 64)))
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(launchCount, 0)
    }

    private func privateTemporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("kaisola-startup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(root.path, 0o700)
        roots.append(root)
        return root
    }

    private func makeLiveBroker(
        home: URL,
        contentDigest: String?
    ) throws -> (profile: URL, descriptor: Int32) {
        let profile = home.appendingPathComponent("Kaisola", isDirectory: true)
        let broker = profile.appendingPathComponent("session-broker", isDirectory: true)
        try FileManager.default.createDirectory(
            at: broker,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(profile.path, 0o700)
        _ = chmod(broker.path, 0o700)
        let socket = broker.appendingPathComponent("broker.sock")
        let descriptor = try bindUnixSocket(at: socket)
        var metadata: [String: Any] = [
            "protocol": 2,
            "securityEpoch": 1,
            "implementationVersion": 1,
            "packageSchema": 1,
            "packageVersion": "old-package",
            "pid": getpid(),
            "socketPath": socket.path,
            "token": String(repeating: "b", count: 64),
            "startedAt": 1,
            "version": "old-native",
        ]
        if let contentDigest { metadata["contentDigest"] = contentDigest }
        let infoURL = broker.appendingPathComponent("broker.json")
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: infoURL)
        _ = chmod(infoURL.path, 0o600)
        return (profile, descriptor)
    }
}

private actor FakeBrokerUpgradeRequester: BrokerUpgradeRequesting {
    let decision: BrokerUpgradeDecision
    private(set) var callCount = 0

    init(decision: BrokerUpgradeDecision) {
        self.decision = decision
    }

    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerUpgradeDecision {
        callCount += 1
        return decision
    }
}

private actor FakeBrokerHelperLauncher: BrokerHelperLaunching {
    private(set) var launchCount = 0
    private var descriptor: Int32 = -1
    private var socketURL: URL?

    func packageManifest() async throws -> BrokerHelperManifest {
        BrokerHelperManifest(
            schemaVersion: 1,
            packageVersion: "test-package",
            contentDigest: String(repeating: "d", count: 64),
            brokerImplementationVersion: 1,
            brokerProtocol: .init(minimum: 2, maximum: 2, securityEpoch: 1),
            node: .init(version: "22.23.1", abi: "127", architectures: ["arm64"]),
            nodePty: .init(version: "1.1.0"),
            files: []
        )
    }

    func launch(configurationURL: URL) async throws -> Int32 {
        launchCount += 1
        let configuration = try JSONDecoder().decode(
            BrokerLaunchConfiguration.self,
            from: Data(contentsOf: configurationURL)
        )
        let socket = URL(fileURLWithPath: configuration.socketPath)
        descriptor = try bindUnixSocket(at: socket)
        socketURL = socket
        let metadata: [String: Any] = [
            "protocol": configuration.protocolVersion,
            "securityEpoch": configuration.securityEpoch,
            "implementationVersion": configuration.implementationVersion,
            "packageSchema": configuration.packageSchema,
            "packageVersion": configuration.packageVersion,
            "contentDigest": configuration.contentDigest,
            "pid": getpid(),
            "socketPath": configuration.socketPath,
            "token": configuration.token,
            "startedAt": configuration.startedAt,
            "version": configuration.version,
        ]
        let infoURL = URL(fileURLWithPath: configuration.infoFile)
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: infoURL)
        _ = chmod(infoURL.path, 0o600)
        return getpid()
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        if let socketURL { try? FileManager.default.removeItem(at: socketURL) }
        socketURL = nil
    }
}

private func bindUnixSocket(at url: URL) throws -> Int32 {
    try? FileManager.default.removeItem(at: url)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_un()
    let bytes = Array(url.path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        Darwin.close(descriptor)
        throw POSIXError(.ENAMETOOLONG)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    let addressLength = socklen_t(address.sun_len)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, addressLength)
        }
    }
    guard result == 0, Darwin.listen(descriptor, 1) == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    _ = chmod(url.path, 0o600)
    return descriptor
}
