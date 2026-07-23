import Darwin
import Foundation
import XCTest
@testable import KaisolaMacPreview

final class BrokerDiscoveryTests: XCTestCase {
    private var root: URL!
    private var socketDescriptors: [Int32] = []

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/kaisola-native-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(root.path, 0o700)
    }

    override func tearDownWithError() throws {
        for descriptor in socketDescriptors { Darwin.close(descriptor) }
        try? FileManager.default.removeItem(at: root)
    }

    func testProfileNamesMatchShippingElectronPrecedence() {
        XCTAssertEqual(
            BrokerInfoLocator.installedProfileNames,
            ["pasola", "Pasola", "Kiasola", "Kaisola"]
        )
        XCTAssertEqual(BrokerInfoLocator.developmentProfileName, "Kaisola Dev")
        XCTAssertFalse(BrokerInfoLocator.installedProfileNames.contains("com.kaisola.mac.preview"))
    }

    func testDebugPreviewDefaultsToItsNativeOnlyProfile() {
        #if DEBUG
        XCTAssertEqual(BrokerInfoLocator.defaultPreviewProfile, .native)
        XCTAssertEqual(
            BrokerInfoLocator.preview().userDataCandidates.map(\.lastPathComponent),
            [BrokerInfoLocator.nativeOwnProfileName]
        )
        #endif
    }

    func testCleanDevelopmentRouteRemainsExplicitlyAvailable() {
        XCTAssertEqual(
            BrokerInfoLocator.preview(profile: .development)
                .userDataCandidates.map(\.lastPathComponent),
            [BrokerInfoLocator.developmentProfileName]
        )
    }

    func testReleaseRouteCanStillSelectInstalledProfilesExplicitly() {
        XCTAssertEqual(
            BrokerInfoLocator.live(developmentProfile: false)
                .userDataCandidates.map(\.lastPathComponent),
            BrokerInfoLocator.installedProfileNames
        )
    }

    func testEachHistoricalAndCurrentProfileCanResolveTheLiveBroker() throws {
        for (index, name) in BrokerInfoLocator.installedProfileNames.enumerated() {
            // The shipping profile names intentionally differ only by case for
            // two migrations. Use distinct test directories because the
            // default macOS volume is case-insensitive; the profile-name order
            // itself is asserted separately above.
            let profile = try makeProfile("candidate-\(index)")
            let expected = try makeBroker(in: profile, version: "profile-\(index)")
            let actual = try BrokerInfoLocator(userDataCandidates: [profile]).locate()
            XCTAssertEqual(actual, expected, name)
        }
    }

    func testOldestExistingProfileWinsEvenWhenItHasNoBroker() throws {
        let oldest = try makeProfile("candidate-0")
        let newer = try makeProfile("candidate-1")
        _ = try makeBroker(in: newer, version: "must-not-be-adopted")

        XCTAssertThrowsError(
            try BrokerInfoLocator(userDataCandidates: [oldest, newer]).locate()
        ) { error in
            XCTAssertEqual(error as? BrokerDiscoveryError, .notRunning)
        }
    }

    func testMultipleBrokersStillChooseTheOldestProfile() throws {
        let oldest = try makeProfile("candidate-0")
        let newer = try makeProfile("candidate-1")
        _ = try makeBroker(in: oldest, version: "oldest")
        _ = try makeBroker(in: newer, version: "newer")

        XCTAssertEqual(
            try BrokerInfoLocator(userDataCandidates: [oldest, newer]).locate().version,
            "oldest"
        )
    }

    func testSymlinkedMetadataAndPublicModesFailClosed() throws {
        let symlinkProfile = try makeProfile("symlink")
        _ = try makeBroker(in: symlinkProfile, version: "symlink")
        let infoURL = symlinkProfile.appendingPathComponent("session-broker/broker.json")
        let external = root.appendingPathComponent("external.json")
        try FileManager.default.copyItem(at: infoURL, to: external)
        try FileManager.default.removeItem(at: infoURL)
        try FileManager.default.createSymbolicLink(at: infoURL, withDestinationURL: external)
        XCTAssertThrowsError(try BrokerInfoLocator(userDataCandidates: [symlinkProfile]).locate()) { error in
            XCTAssertEqual(error as? BrokerDiscoveryError, .unsafePermissions)
        }

        let publicProfile = try makeProfile("public")
        _ = try makeBroker(in: publicProfile, version: "public")
        let publicInfo = publicProfile.appendingPathComponent("session-broker/broker.json")
        _ = chmod(publicInfo.path, 0o644)
        XCTAssertThrowsError(try BrokerInfoLocator(userDataCandidates: [publicProfile]).locate()) { error in
            XCTAssertEqual(error as? BrokerDiscoveryError, .unsafePermissions)
        }
    }

    func testMissingSocketAndOversizedMetadataFailClosed() throws {
        let staleProfile = try makeProfile("stale")
        let stale = try makeBroker(in: staleProfile, version: "stale")
        try FileManager.default.removeItem(atPath: stale.socketPath)
        XCTAssertThrowsError(try BrokerInfoLocator(userDataCandidates: [staleProfile]).locate()) { error in
            XCTAssertEqual(error as? BrokerDiscoveryError, .privateEndpointUnavailable)
        }

        let oversizedProfile = try makeProfile("oversized")
        _ = try makeBroker(in: oversizedProfile, version: "oversized")
        let info = oversizedProfile.appendingPathComponent("session-broker/broker.json")
        try Data(repeating: 0x61, count: Int(BrokerInfoLocator.maximumMetadataBytes + 1)).write(to: info)
        _ = chmod(info.path, 0o600)
        XCTAssertThrowsError(try BrokerInfoLocator(userDataCandidates: [oversizedProfile]).locate()) { error in
            XCTAssertEqual(error as? BrokerDiscoveryError, .invalidMetadata)
        }
    }

    func testNativeStateUsesItsDistinctBundleDirectory() {
        XCTAssertTrue(NativePreviewPaths.applicationSupportDirectory.path.hasSuffix("/com.kaisola.mac.preview"))
        XCTAssertFalse(NativePreviewPaths.applicationSupportDirectory.path.hasSuffix("/Kaisola"))
        XCTAssertEqual(
            NativePreviewPaths.terminalCursorStore.deletingLastPathComponent(),
            NativePreviewPaths.applicationSupportDirectory
        )
    }

    func testCursorIdentityIsStableForOneBrokerAndChangesWithItsSecret() {
        let first = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            pid: 123,
            socketPath: "/tmp/broker.sock",
            token: String(repeating: "a", count: 64),
            startedAt: 456,
            version: "one"
        )
        let renamed = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            pid: 123,
            socketPath: "/tmp/broker.sock",
            token: String(repeating: "a", count: 64),
            startedAt: 456,
            version: "two"
        )
        let replacement = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            pid: 123,
            socketPath: "/tmp/broker.sock",
            token: String(repeating: "b", count: 64),
            startedAt: 456,
            version: "two"
        )

        XCTAssertEqual(first.persistenceIdentity, renamed.persistenceIdentity)
        XCTAssertNotEqual(first.persistenceIdentity, replacement.persistenceIdentity)
        XCTAssertEqual(first.persistenceIdentity.count, 64)
    }

    func testNativeStatePreparationRejectsSymlinkWithoutChmoddingItsTarget() throws {
        let target = root.appendingPathComponent("external-native-state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        _ = chmod(target.path, 0o755)
        let link = root.appendingPathComponent("native-state-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try NativePreviewPaths.prepareApplicationSupport(at: link)) { error in
            XCTAssertEqual(error as? NativePreviewPathError, .unsafeApplicationSupport)
        }
        var metadata = stat()
        XCTAssertEqual(lstat(target.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o755)
    }

    private func makeProfile(_ name: String) throws -> URL {
        let profile = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: profile,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(profile.path, 0o700)
        return profile
    }

    private func makeBroker(in profile: URL, version: String) throws -> BrokerInfo {
        let brokerDirectory = profile.appendingPathComponent("session-broker", isDirectory: true)
        try FileManager.default.createDirectory(
            at: brokerDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(brokerDirectory.path, 0o700)
        let socketURL = brokerDirectory.appendingPathComponent("broker.sock")
        try bindSocket(at: socketURL)

        let info = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            pid: getpid(),
            socketPath: socketURL.path,
            token: String(repeating: "a", count: 64),
            startedAt: 1_784_250_001_000,
            version: version
        )
        let object: [String: Any] = [
            "protocol": info.protocolVersion,
            "securityEpoch": info.securityEpoch,
            "pid": info.pid,
            "socketPath": info.socketPath,
            "token": info.token,
            "startedAt": info.startedAt,
            "version": info.version,
        ]
        let infoURL = brokerDirectory.appendingPathComponent("broker.json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: infoURL)
        _ = chmod(infoURL.path, 0o600)
        return info
    }

    private func bindSocket(at url: URL) throws {
        var address = sockaddr_un()
        let pathBytes = Array(url.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw BrokerDiscoveryError.invalidMetadata
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrokerDiscoveryError.privateEndpointUnavailable }

        address.sun_family = sa_family_t(AF_UNIX)
        let addressLength = MemoryLayout<sa_family_t>.size + pathBytes.count + 1
        address.sun_len = UInt8(addressLength)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: pathBytes)
            bytes[pathBytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(addressLength))
            }
        }
        guard result == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw BrokerDiscoveryError.privateEndpointUnavailable
        }
        _ = chmod(url.path, 0o600)
        socketDescriptors.append(descriptor)
    }
}
