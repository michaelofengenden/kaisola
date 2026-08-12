import Darwin
import Foundation
import XCTest
@testable import Kaisola

final class BrokerGenerationRegistryTests: XCTestCase {
    private var roots: [URL] = []
    private var socketDescriptors: [Int32] = []
    private var socketURLs: [URL] = []

    override func tearDownWithError() throws {
        for descriptor in socketDescriptors { Darwin.close(descriptor) }
        socketDescriptors.removeAll()
        for socketURL in socketURLs { try? FileManager.default.removeItem(at: socketURL) }
        socketURLs.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testRegistryPublishesCanonicalPrivateTopologyWithRevisionCAS() throws {
        let profile = try makePrivateProfile()
        let store = BrokerGenerationRegistryStore(profileRoot: profile)
        let oldDigest = String(repeating: "a", count: 64)
        let newDigest = String(repeating: "b", count: 64)
        let old = generation(digest: oldDigest, role: .current, profile: profile, package: true)

        let first = try store.save(
            currentGenerationID: oldDigest,
            generations: [old],
            expectedRevision: nil,
            now: 10
        )
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.topology?.registryTopologyVersion, first.revision)
        XCTAssertEqual(first.topology?.current.id, oldDigest)
        XCTAssertTrue(first.topology?.draining.isEmpty == true)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: store.registryURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o600)
        XCTAssertEqual(try store.load(), first)

        XCTAssertThrowsError(try store.save(
            currentGenerationID: oldDigest,
            generations: [old],
            expectedRevision: nil,
            now: 11
        )) { XCTAssertEqual($0 as? BrokerGenerationRegistryError, .revisionChanged) }

        let current = generation(digest: newDigest, role: .current, profile: profile, package: true)
        let draining = BrokerGenerationRecord(
            id: old.id,
            role: .draining,
            info: old.info,
            packageRoot: nil,
            registeredAt: old.registeredAt
        )
        let second = try store.save(
            currentGenerationID: newDigest,
            generations: [draining, current],
            expectedRevision: first.revision,
            now: 12
        )
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(second.topology?.registryTopologyVersion, second.revision)
        XCTAssertEqual(second.generations.map(\.id), [newDigest, oldDigest])
        XCTAssertEqual(second.topology?.current.role, .current)
        XCTAssertEqual(second.topology?.draining.map(\.role), [.draining])
    }

    func testRegistryRejectsTamperedIdentityAndSymlinkLeaves() throws {
        let profile = try makePrivateProfile()
        let store = BrokerGenerationRegistryStore(profileRoot: profile)
        let digest = String(repeating: "c", count: 64)
        _ = try store.save(
            currentGenerationID: digest,
            generations: [generation(digest: digest, role: .current, profile: profile, package: true)],
            expectedRevision: nil,
            now: 1
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.registryURL)) as? [String: Any]
        )
        object["currentGenerationID"] = String(repeating: "d", count: 64)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: store.registryURL, options: .atomic)
        _ = chmod(store.registryURL.path, 0o600)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? BrokerGenerationRegistryError, .invalidRegistry)
        }

        try FileManager.default.removeItem(at: store.registryURL)
        let target = profile.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.registryURL, withDestinationURL: target)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? BrokerGenerationRegistryError, .unsafeRegistry)
        }
    }

    func testExplicitSelectionIsBoundToCurrentGenerationAndSelectingAppDigest() throws {
        let profile = try makePrivateProfile()
        let store = BrokerGenerationRegistryStore(profileRoot: profile)
        let digest = String(repeating: "a", count: 64)
        let current = generation(digest: digest, role: .current, profile: profile, package: true)
        let selection = BrokerGenerationSelection(
            generationID: digest,
            selectingAppContentDigest: String(repeating: "b", count: 64),
            selectedAt: 10
        )
        let saved = try store.save(
            currentGenerationID: digest,
            generations: [current],
            expectedRevision: nil,
            selection: selection,
            now: 10
        )
        XCTAssertEqual(saved.selection, selection)
        XCTAssertEqual(try store.load().selection, selection)

        XCTAssertThrowsError(try store.save(
            currentGenerationID: digest,
            generations: [current],
            expectedRevision: saved.revision,
            selection: BrokerGenerationSelection(
                generationID: String(repeating: "c", count: 64),
                selectingAppContentDigest: selection.selectingAppContentDigest,
                selectedAt: 11
            ),
            now: 11
        )) { error in
            XCTAssertEqual(error as? BrokerGenerationRegistryError, .invalidRegistry)
        }
        XCTAssertEqual(try store.load(), saved)
    }

    /// Absent metadata and *wrong* metadata are different failures, and the
    /// difference decides whether the app can ever recover.
    ///
    /// Both used to raise `invalidRegistry`, which made one missing file
    /// terminal: `BrokerStartupCoordinator` relaunches on `notRunning` but
    /// rethrows `invalidRegistry`, so every terminal became permanently
    /// unreachable — including the healthy generations in the same registry —
    /// with Reconnect reporting "the saved terminal-generation registry is
    /// invalid" forever. Observed on 0.1.118 with five draining generations
    /// published and matching and the current one's metadata gone.
    ///
    /// The registry is written *after* generation metadata, so a record with no
    /// metadata never finished announcing itself. Unpublished is not tampered.
    func testUnpublishedGenerationsAreDroppedWhileSwappedIdentitiesFailClosed() throws {
        let profile = try makePrivateProfile()
        let store = BrokerGenerationRegistryStore(profileRoot: profile)
        let current = generation(
            digest: String(repeating: "a", count: 64),
            role: .current,
            profile: profile,
            package: true
        )
        let drain = generation(
            digest: String(repeating: "b", count: 64),
            role: .draining,
            profile: profile,
            package: true
        )
        try publish(current, store: store)
        try bindSocket(at: URL(fileURLWithPath: drain.info.socketPath))
        _ = try store.save(
            currentGenerationID: current.id,
            generations: [current, drain],
            expectedRevision: nil,
            now: 1
        )
        let locator = BrokerInfoLocator(userDataCandidates: [profile])

        // The draining generation was never published. It is dropped, and the
        // current generation — which *is* published — stays discoverable.
        let topology = try locator.locateTopology()
        XCTAssertEqual(topology.current.id, current.id)
        XCTAssertTrue(topology.draining.isEmpty, "an unpublished generation must not be vended")

        // Present but disagreeing with the registry is a swapped identity, and
        // is still never adopted.
        let drainMetadata = store.metadataURL(for: drain)
        try JSONEncoder().encode(current.info).write(to: drainMetadata)
        _ = chmod(drainMetadata.path, 0o600)
        XCTAssertThrowsError(try locator.locateTopology()) { error in
            XCTAssertEqual(error as? BrokerDiscoveryError, .invalidRegistry)
        }

        XCTAssertTrue(current.info.isProcessAlive)
        XCTAssertTrue(drain.info.isProcessAlive)
    }

    /// The case that actually stranded a user: the *current* generation has no
    /// metadata. Nothing is adoptable, which is what `notRunning` means — and it
    /// is the one error `BrokerStartupCoordinator` recovers from by launching a
    /// fresh broker instead of rethrowing.
    func testAnUnpublishedCurrentGenerationReadsAsNotRunning() throws {
        let profile = try makePrivateProfile()
        let store = BrokerGenerationRegistryStore(profileRoot: profile)
        let current = generation(
            digest: String(repeating: "c", count: 64),
            role: .current,
            profile: profile,
            package: true
        )
        let drain = generation(
            digest: String(repeating: "d", count: 64),
            role: .draining,
            profile: profile,
            package: true
        )
        // Only the draining generation is published; the current one is not.
        try publish(drain, store: store)
        try bindSocket(at: URL(fileURLWithPath: current.info.socketPath))
        _ = try store.save(
            currentGenerationID: current.id,
            generations: [current, drain],
            expectedRevision: nil,
            now: 1
        )
        let locator = BrokerInfoLocator(userDataCandidates: [profile])
        XCTAssertThrowsError(try locator.locateTopology()) { error in
            XCTAssertEqual(
                error as? BrokerDiscoveryError, .notRunning,
                "an unpublished current generation must stay recoverable"
            )
        }
    }

    func testInterruptedTemporaryRegistryWriteCannotShadowPublishedRegistry() throws {
        let profile = try makePrivateProfile()
        let store = BrokerGenerationRegistryStore(profileRoot: profile)
        let digest = String(repeating: "a", count: 64)
        let current = generation(digest: digest, role: .current, profile: profile, package: true)
        let saved = try store.save(
            currentGenerationID: digest,
            generations: [current],
            expectedRevision: nil,
            now: 1
        )
        let interrupted = store.brokerDirectory.appendingPathComponent(
            ".registry-v1.interrupted.tmp"
        )
        try Data("{partial".utf8).write(to: interrupted)
        _ = chmod(interrupted.path, 0o600)

        XCTAssertEqual(try store.load(), saved)
    }

    private func makePrivateProfile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kaisola-generation-registry-\(UUID().uuidString)",
            isDirectory: true
        )
        roots.append(root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(root.path, 0o700)
        return root
    }

    private func generation(
        digest: String,
        role: BrokerGenerationRole,
        profile: URL,
        package: Bool
    ) -> BrokerGenerationRecord {
        let broker = profile.appendingPathComponent("session-broker", isDirectory: true)
        let socketLeaf = BrokerLaunchConfiguration.generationSocketLeaf(
            userData: profile,
            contentDigest: digest
        )
        let durableSocket = broker.appendingPathComponent(socketLeaf)
        let socket = durableSocket.path.utf8.count <= 100
            ? durableSocket
            : URL(fileURLWithPath: "/tmp/.kaisola-session", isDirectory: true)
                .appendingPathComponent(socketLeaf)
        return BrokerGenerationRecord(
            id: digest,
            role: role,
            info: BrokerInfo(
                protocolVersion: 2,
                securityEpoch: 1,
                implementationVersion: 1,
                packageSchema: 1,
                packageVersion: "test",
                contentDigest: digest,
                pid: getpid(),
                socketPath: socket.path,
                token: String(repeating: "e", count: 64),
                startedAt: 1,
                version: "test"
            ),
            packageRoot: package
                ? profile
                    .appendingPathComponent("broker-generations", isDirectory: true)
                    .appendingPathComponent(digest, isDirectory: true)
                    .path
                : nil,
            registeredAt: 1
        )
    }

    private func publish(
        _ generation: BrokerGenerationRecord,
        store: BrokerGenerationRegistryStore
    ) throws {
        let metadataDirectory = store.brokerDirectory.appendingPathComponent(
            BrokerLaunchConfiguration.generationMetadataDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(store.brokerDirectory.path, 0o700)
        _ = chmod(metadataDirectory.path, 0o700)
        try bindSocket(at: URL(fileURLWithPath: generation.info.socketPath))
        let metadataURL = store.metadataURL(for: generation)
        try JSONEncoder().encode(generation.info).write(to: metadataURL)
        _ = chmod(metadataURL.path, 0o600)
    }

    private func bindSocket(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var address = sockaddr_un()
        let bytes = Array(url.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
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
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        _ = chmod(url.path, 0o600)
        socketDescriptors.append(descriptor)
        socketURLs.append(url)
    }
}
