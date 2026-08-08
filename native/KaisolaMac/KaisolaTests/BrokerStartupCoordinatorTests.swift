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

    func testDeadRegisteredGenerationIsReplacedWithOneCASRevision() async throws {
        let home = try privateTemporaryDirectory()
        let profile = home.appendingPathComponent("Kaisola", isDirectory: true)
        let broker = profile.appendingPathComponent("session-broker", isDirectory: true)
        let metadataDirectory = broker.appendingPathComponent(
            BrokerLaunchConfiguration.generationMetadataDirectoryName,
            isDirectory: true
        )
        for directory in [profile, broker, metadataDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(directory.path, 0o700)
        }

        let digest = String(repeating: "d", count: 64)
        let socket = broker.appendingPathComponent(
            BrokerLaunchConfiguration.generationSocketLeaf(
                userData: profile,
                contentDigest: digest
            )
        )
        let staleDescriptor = try bindUnixSocket(at: socket)
        Darwin.close(staleDescriptor)
        let stale = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: 1,
            packageVersion: "test-package",
            contentDigest: digest,
            pid: Int32.max,
            socketPath: socket.path,
            token: String(repeating: "c", count: 64),
            startedAt: 1,
            version: "stale-native"
        )
        let metadataURL = metadataDirectory.appendingPathComponent("\(digest).json")
        try JSONEncoder().encode(stale).write(to: metadataURL)
        _ = chmod(metadataURL.path, 0o600)
        let record = BrokerGenerationRecord(
            id: digest,
            role: .current,
            info: stale,
            packageRoot: profile
                .appendingPathComponent("broker-generations", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
                .path,
            registeredAt: 1
        )
        let store = BrokerGenerationRegistryStore(profileRoot: profile)
        _ = try store.save(
            currentGenerationID: digest,
            generations: [record],
            expectedRevision: nil,
            now: 1
        )

        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [profile]),
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test"
        )
        let replacement = try await coordinator.prepare()
        let registry = try store.load()
        let launchCount = await launcher.launchCount

        XCTAssertEqual(replacement.pid, getpid())
        XCTAssertEqual(replacement.contentDigest, digest)
        XCTAssertEqual(registry.revision, 2)
        XCTAssertEqual(registry.topology?.current.info, replacement)
        XCTAssertTrue(registry.topology?.draining.isEmpty == true)
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

    func testRollingCutoverPublishesNewCurrentAndRetainsLivePriorGeneration() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(implementationVersion: 2)
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )

        let replacement = try await coordinator.prepare()
        let registry = try BrokerGenerationRegistryStore(profileRoot: live.profile).load()
        let topology = try XCTUnwrap(registry.topology)
        let upgradeCalls = await requester.upgradeCallCount()
        let cancelCalls = await requester.cancelCallCount()
        let launchCalls = await launcher.launchCount

        XCTAssertEqual(replacement.contentDigest, String(repeating: "d", count: 64))
        XCTAssertEqual(replacement.implementationVersion, 2)
        XCTAssertEqual(registry.revision, 2)
        XCTAssertEqual(topology.current.info, replacement)
        XCTAssertEqual(topology.draining.map(\.id), [oldDigest])
        XCTAssertEqual(topology.draining[0].info, live.info)
        XCTAssertTrue(live.info.isProcessAlive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.info.socketPath))
        XCTAssertEqual(upgradeCalls, 1)
        XCTAssertEqual(cancelCalls, 0)
        XCTAssertEqual(launchCalls, 1)
        await launcher.close()
    }

    func testRollbackSelectsVerifiedDrainAndSurvivesSameAppRelaunch() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let bundledDigest = String(repeating: "d", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(implementationVersion: 2)
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )

        _ = try await coordinator.prepare()
        let candidates = await coordinator.rollbackCandidates()
        XCTAssertEqual(candidates.map(\.id), [oldDigest])
        XCTAssertEqual(candidates.first?.packageVersion, "old-package")

        let selected = try await coordinator.rollback(toGenerationID: oldDigest)
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let rolledBack = try store.load()
        XCTAssertEqual(selected, live.info)
        XCTAssertEqual(rolledBack.currentGenerationID, oldDigest)
        XCTAssertEqual(rolledBack.topology?.draining.map(\.id), [bundledDigest])
        XCTAssertEqual(rolledBack.selection?.generationID, oldDigest)
        XCTAssertEqual(rolledBack.selection?.selectingAppContentDigest, bundledDigest)
        _ = await coordinator.attemptUpgradeIfNeeded()
        let retirementCalls = await requester.retirementCallCount()
        XCTAssertEqual(retirementCalls, 0)
        XCTAssertEqual(try store.load(), rolledBack)

        // The same sealed app honors its explicit selection rather than
        // immediately rolling forward on the next heartbeat/relaunch probe.
        let adoptedAgain = try await coordinator.prepare()
        let upgradeCalls = await requester.upgradeCallCount()
        let cancelCalls = await requester.cancelCallCount()
        XCTAssertEqual(adoptedAgain, live.info)
        XCTAssertEqual(upgradeCalls, 2)
        XCTAssertEqual(cancelCalls, 1)
        XCTAssertEqual(try store.load(), rolledBack)
        await launcher.close()
    }

    func testRollbackRejectsTamperedStagedDrainWithoutChangingRegistry() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            rejectedStagedDigests: [oldDigest]
        )
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )

        _ = try await coordinator.prepare()
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let before = try store.load()
        let candidates = await coordinator.rollbackCandidates()
        XCTAssertEqual(candidates, [])
        do {
            _ = try await coordinator.rollback(toGenerationID: oldDigest)
            XCTFail("expected staged-package tampering to block rollback")
        } catch {
            XCTAssertEqual(error as? BrokerRollbackError, .targetNotVerified)
        }
        let upgradeCalls = await requester.upgradeCallCount()
        XCTAssertEqual(try store.load(), before)
        XCTAssertEqual(upgradeCalls, 1)
        await launcher.close()
    }

    func testEmptyDrainingGenerationRetiresAfterIdentityRecheckAndDetachment() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let cutoverRequester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(implementationVersion: 2)
        let locator = BrokerInfoLocator(userDataCandidates: [live.profile])
        let cutoverCoordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: cutoverRequester,
            rollingUpdatesEnabled: true
        )
        _ = try await cutoverCoordinator.prepare()

        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let cutoverRegistry = try store.load()
        let cutoverTopology = try XCTUnwrap(cutoverRegistry.topology)
        let old = try XCTUnwrap(cutoverTopology.draining.first)
        let childPID = try spawnPausedChild()
        defer {
            _ = Darwin.kill(childPID, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(childPID, &status, WNOHANG)
        }
        let childInfo = BrokerInfo(
            protocolVersion: old.info.protocolVersion,
            securityEpoch: old.info.securityEpoch,
            implementationVersion: old.info.implementationVersion,
            packageSchema: old.info.packageSchema,
            packageVersion: old.info.packageVersion,
            contentDigest: old.info.contentDigest,
            pid: childPID,
            socketPath: old.info.socketPath,
            token: old.info.token,
            startedAt: old.info.startedAt,
            version: old.info.version
        )
        let childGeneration = BrokerGenerationRecord(
            id: old.id,
            role: .draining,
            info: childInfo,
            packageRoot: old.packageRoot,
            registeredAt: old.registeredAt
        )
        let metadataURL = store.metadataURL(for: childGeneration)
        try JSONEncoder().encode(childInfo).write(to: metadataURL)
        _ = chmod(metadataURL.path, 0o600)
        let rewritten = try store.save(
            currentGenerationID: cutoverTopology.current.id,
            generations: [cutoverTopology.current, childGeneration],
            expectedRevision: cutoverRegistry.revision
        )

        let metadataPath = metadataURL.path
        let socketPath = childInfo.socketPath
        let retirementRequester = FakeRollingBrokerUpgradeRequester(
            upgradeDecision: .accepted,
            retirementDecision: .accepted,
            onRetirement: {
                _ = Darwin.kill(childPID, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(childPID, &status, 0)
                _ = metadataPath.withCString(Darwin.unlink)
                _ = socketPath.withCString(Darwin.unlink)
            }
        )
        let retirementCoordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: retirementRequester,
            rollingUpdatesEnabled: true
        )
        _ = try await retirementCoordinator.prepare()
        _ = await retirementCoordinator.attemptUpgradeIfNeeded()

        let retired = try store.load()
        let retirementCalls = await retirementRequester.retirementCallCount()
        XCTAssertEqual(rewritten.revision, 3)
        XCTAssertEqual(retired.revision, 4)
        XCTAssertEqual(retired.currentGenerationID, cutoverTopology.current.id)
        XCTAssertTrue(retired.topology?.draining.isEmpty == true)
        XCTAssertEqual(retirementCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataPath))
        await launcher.close()
    }

    func testBlockedFirstDrainDoesNotStarveAnEmptyLaterDrainOfRetirement() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        // Not "d": that is the fake launcher's staged (current) digest, and a
        // collision would silently fold this record into the current
        // generation at save time. "c" still sorts ahead of the empty "e".
        let blockedDigest = String(repeating: "c", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let cutoverRequester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(implementationVersion: 2)
        let locator = BrokerInfoLocator(userDataCandidates: [live.profile])
        let cutoverCoordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: cutoverRequester,
            rollingUpdatesEnabled: true
        )
        _ = try await cutoverCoordinator.prepare()

        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let cutoverRegistry = try store.load()
        let cutoverTopology = try XCTUnwrap(cutoverRegistry.topology)
        let old = try XCTUnwrap(cutoverTopology.draining.first)
        let childPID = try spawnPausedChild()
        defer {
            _ = Darwin.kill(childPID, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(childPID, &status, WNOHANG)
        }
        let emptyInfo = BrokerInfo(
            protocolVersion: old.info.protocolVersion,
            securityEpoch: old.info.securityEpoch,
            implementationVersion: old.info.implementationVersion,
            packageSchema: old.info.packageSchema,
            packageVersion: old.info.packageVersion,
            contentDigest: old.info.contentDigest,
            pid: childPID,
            socketPath: old.info.socketPath,
            token: old.info.token,
            startedAt: old.info.startedAt,
            version: old.info.version
        )
        let emptyGeneration = BrokerGenerationRecord(
            id: old.id,
            role: .draining,
            info: emptyInfo,
            packageRoot: old.packageRoot,
            registeredAt: old.registeredAt
        )
        // Sorts ahead of the empty drain ("d" < "e"): the registry canonical
        // order is by generation id, so this populated broker is the first
        // retirement candidate every heartbeat. It must look genuinely live
        // (bound canonical socket, live pid, metadata, package root) so
        // prepare() retains it rather than pruning a dead drain.
        let blockedPackageRoot = live.profile
            .appendingPathComponent("broker-generations", isDirectory: true)
            .appendingPathComponent(blockedDigest, isDirectory: true)
        try FileManager.default.createDirectory(
            at: blockedPackageRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let blockedSocket = live.profile
            .appendingPathComponent("session-broker", isDirectory: true)
            .appendingPathComponent(
                BrokerLaunchConfiguration.generationSocketLeaf(
                    userData: live.profile,
                    contentDigest: blockedDigest
                )
            )
        let blockedDescriptor = try bindUnixSocket(at: blockedSocket)
        defer { Darwin.close(blockedDescriptor) }
        let blockedInfo = BrokerInfo(
            protocolVersion: old.info.protocolVersion,
            securityEpoch: old.info.securityEpoch,
            implementationVersion: old.info.implementationVersion,
            packageSchema: old.info.packageSchema,
            packageVersion: old.info.packageVersion,
            contentDigest: blockedDigest,
            pid: getpid(),
            socketPath: blockedSocket.path,
            token: old.info.token,
            startedAt: old.info.startedAt,
            version: old.info.version
        )
        let blockedGeneration = BrokerGenerationRecord(
            id: blockedDigest,
            role: .draining,
            info: blockedInfo,
            packageRoot: blockedPackageRoot.path,
            registeredAt: old.registeredAt
        )
        let emptyMetadataURL = store.metadataURL(for: emptyGeneration)
        try JSONEncoder().encode(emptyInfo).write(to: emptyMetadataURL)
        _ = chmod(emptyMetadataURL.path, 0o600)
        let blockedMetadataURL = store.metadataURL(for: blockedGeneration)
        try JSONEncoder().encode(blockedInfo).write(to: blockedMetadataURL)
        _ = chmod(blockedMetadataURL.path, 0o600)
        let rewritten = try store.save(
            currentGenerationID: cutoverTopology.current.id,
            generations: [cutoverTopology.current, blockedGeneration, emptyGeneration],
            expectedRevision: cutoverRegistry.revision
        )
        XCTAssertEqual(
            rewritten.topology?.draining.map(\.id),
            [blockedDigest, oldDigest]
        )

        let emptyMetadataPath = emptyMetadataURL.path
        let emptySocketPath = emptyInfo.socketPath
        let retirementRequester = FakeRollingBrokerUpgradeRequester(
            upgradeDecision: .accepted,
            retirementDecisionsByDigest: [
                blockedDigest: .deferred(
                    BrokerUpgradeBlockers(
                        liveTerminalCount: 3,
                        liveTerminalIDs: ["a", "b", "c"],
                        busyAgentCount: 0,
                        busyTerminalIDs: [],
                        childTaskCount: 0
                    ),
                    clientCount: 2
                ),
                oldDigest: .accepted,
            ],
            onRetirement: {
                _ = Darwin.kill(childPID, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(childPID, &status, 0)
                _ = emptyMetadataPath.withCString(Darwin.unlink)
                _ = emptySocketPath.withCString(Darwin.unlink)
            }
        )
        let retirementCoordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: retirementRequester,
            rollingUpdatesEnabled: true
        )
        // No prepare(): the retirement sweep locates topology on its own, and
        // prepare's full startup reconciliation is not what this test pins.
        _ = await retirementCoordinator.attemptUpgradeIfNeeded()

        let retired = try store.load()
        let retirementCalls = await retirementRequester.retirementCallCount()
        // Both drains were asked; only the empty one retired. The populated
        // drain (still pending) must survive with its terminals intact.
        XCTAssertEqual(retirementCalls, 2)
        XCTAssertEqual(retired.currentGenerationID, cutoverTopology.current.id)
        XCTAssertEqual(retired.topology?.draining.map(\.id), [blockedDigest])
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyMetadataPath))
        await launcher.close()
    }

    func testRollbackRefusesOlderImplementationEvenWhenItsProcessIsLive() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(implementationVersion: 2)
        let locator = BrokerInfoLocator(userDataCandidates: [live.profile])
        let coordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )
        _ = try await coordinator.prepare()

        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let registry = try store.load()
        let topology = try XCTUnwrap(registry.topology)
        let old = try XCTUnwrap(topology.draining.first)
        let downgradedInfo = BrokerInfo(
            protocolVersion: old.info.protocolVersion,
            securityEpoch: old.info.securityEpoch,
            implementationVersion: 1,
            packageSchema: old.info.packageSchema,
            packageVersion: old.info.packageVersion,
            contentDigest: old.info.contentDigest,
            pid: old.info.pid,
            socketPath: old.info.socketPath,
            token: old.info.token,
            startedAt: old.info.startedAt,
            version: "older-implementation"
        )
        let downgraded = BrokerGenerationRecord(
            id: old.id,
            role: .draining,
            info: downgradedInfo,
            packageRoot: old.packageRoot,
            registeredAt: old.registeredAt
        )
        try JSONEncoder().encode(downgradedInfo).write(to: store.metadataURL(for: downgraded))
        _ = chmod(store.metadataURL(for: downgraded).path, 0o600)
        let before = try store.save(
            currentGenerationID: topology.current.id,
            generations: [topology.current, downgraded],
            expectedRevision: registry.revision
        )

        let candidates = await coordinator.rollbackCandidates()
        XCTAssertEqual(candidates, [])
        do {
            _ = try await coordinator.rollback(toGenerationID: oldDigest)
            XCTFail("expected older implementation to be refused")
        } catch {
            XCTAssertEqual(error as? BrokerRollbackError, .incompatibleTarget)
        }
        let upgradeCalls = await requester.upgradeCallCount()
        XCTAssertEqual(try store.load(), before)
        XCTAssertEqual(upgradeCalls, 1)
        await launcher.close()
    }

    func testRollingActivityAndLeaseRacesLeaveOldGenerationCurrent() async throws {
        let blockers = BrokerUpgradeBlockers(
            liveTerminalCount: 1,
            liveTerminalIDs: ["retained"],
            busyAgentCount: 0,
            busyTerminalIDs: [],
            childTaskCount: 0
        )
        let decisions: [(BrokerUpgradeDecision, BrokerUpgradePendingReason)] = [
            (.activityChanged(blockers), .activityChanged(blockers)),
            (.companionLeaseChanged(blockers), .companionLeaseChanged(blockers)),
        ]

        for (index, entry) in decisions.enumerated() {
            let home = try privateTemporaryDirectory()
            let oldDigest = String(repeating: index == 0 ? "e" : "f", count: 64)
            let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
            let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: entry.0)
            let launcher = FakeBrokerHelperLauncher(implementationVersion: 2)
            let coordinator = BrokerStartupCoordinator(
                locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
                launcher: launcher,
                homeDirectory: home,
                appVersion: "native-test",
                upgradeRequester: requester,
                rollingUpdatesEnabled: true
            )

            let adopted = try await coordinator.prepare()
            let registry = try BrokerGenerationRegistryStore(profileRoot: live.profile).load()
            let state = await coordinator.upgradeState()
            let upgradeCalls = await requester.upgradeCallCount()
            let cancelCalls = await requester.cancelCallCount()
            let launchCalls = await launcher.launchCount

            XCTAssertEqual(adopted, live.info)
            XCTAssertEqual(registry.revision, 1)
            XCTAssertEqual(registry.currentGenerationID, oldDigest)
            XCTAssertTrue(registry.topology?.draining.isEmpty == true)
            XCTAssertEqual(state, .pending(
                fromContentDigest: oldDigest,
                targetContentDigest: String(repeating: "d", count: 64),
                reason: entry.1
            ))
            XCTAssertEqual(upgradeCalls, 1)
            XCTAssertEqual(cancelCalls, 0)
            XCTAssertEqual(launchCalls, 1)
            await launcher.close()
            Darwin.close(live.descriptor)
        }
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

    private func makeRegisteredLiveBroker(
        home: URL,
        contentDigest: String
    ) throws -> (profile: URL, descriptor: Int32, info: BrokerInfo) {
        let profile = home.appendingPathComponent("Kaisola", isDirectory: true)
        let broker = profile.appendingPathComponent("session-broker", isDirectory: true)
        let metadataDirectory = broker.appendingPathComponent(
            BrokerLaunchConfiguration.generationMetadataDirectoryName,
            isDirectory: true
        )
        let packageRoot = profile
            .appendingPathComponent("broker-generations", isDirectory: true)
            .appendingPathComponent(contentDigest, isDirectory: true)
        for directory in [profile, broker, metadataDirectory, packageRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(directory.path, 0o700)
        }
        let socket = broker.appendingPathComponent(
            BrokerLaunchConfiguration.generationSocketLeaf(
                userData: profile,
                contentDigest: contentDigest
            )
        )
        let descriptor = try bindUnixSocket(at: socket)
        let info = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 2,
            packageSchema: 1,
            packageVersion: "old-package",
            contentDigest: contentDigest,
            pid: getpid(),
            socketPath: socket.path,
            token: String(repeating: "b", count: 64),
            startedAt: 1,
            version: "old-native"
        )
        let metadataURL = metadataDirectory.appendingPathComponent("\(contentDigest).json")
        try JSONEncoder().encode(info).write(to: metadataURL)
        _ = chmod(metadataURL.path, 0o600)
        let record = BrokerGenerationRecord(
            id: contentDigest,
            role: .current,
            info: info,
            packageRoot: packageRoot.path,
            registeredAt: 1
        )
        _ = try BrokerGenerationRegistryStore(profileRoot: profile).save(
            currentGenerationID: contentDigest,
            generations: [record],
            expectedRevision: nil,
            now: 1
        )
        return (profile, descriptor, info)
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

private actor FakeRollingBrokerUpgradeRequester: BrokerRollingUpdateRequesting {
    private let upgradeDecision: BrokerUpgradeDecision
    private let retirementDecision: BrokerRetirementDecision
    /// Per-generation overrides so one fake can play a populated drain
    /// (pending) and an empty one (accepted) in the same heartbeat.
    private let retirementDecisionsByDigest: [String: BrokerRetirementDecision]
    private let onRetirement: @Sendable () -> Void
    private var upgrades = 0
    private var cancels = 0
    private var retirements = 0

    init(
        upgradeDecision: BrokerUpgradeDecision,
        retirementDecision: BrokerRetirementDecision = .deferred(
            BrokerUpgradeBlockers(
                liveTerminalCount: 1,
                liveTerminalIDs: ["retained"],
                busyAgentCount: 0,
                busyTerminalIDs: [],
                childTaskCount: 0
            ),
            clientCount: 1
        ),
        retirementDecisionsByDigest: [String: BrokerRetirementDecision] = [:],
        onRetirement: @escaping @Sendable () -> Void = {}
    ) {
        self.upgradeDecision = upgradeDecision
        self.retirementDecision = retirementDecision
        self.retirementDecisionsByDigest = retirementDecisionsByDigest
        self.onRetirement = onRetirement
    }

    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerUpgradeDecision {
        upgrades += 1
        return upgradeDecision
    }

    func cancelRollingUpdate(from info: BrokerInfo, targetContentDigest: String) async throws {
        cancels += 1
    }

    func requestRetirement(
        of info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerRetirementDecision {
        retirements += 1
        let decision = info.contentDigest.flatMap { retirementDecisionsByDigest[$0] }
            ?? retirementDecision
        if decision == .accepted { onRetirement() }
        return decision
    }

    func upgradeCallCount() -> Int { upgrades }
    func cancelCallCount() -> Int { cancels }
    func retirementCallCount() -> Int { retirements }
}

private actor FakeBrokerHelperLauncher: BrokerHelperLaunching {
    private let implementationVersion: Int
    private let rejectedStagedDigests: Set<String>
    private(set) var launchCount = 0
    private var descriptor: Int32 = -1
    private var socketURL: URL?

    init(
        implementationVersion: Int = 1,
        rejectedStagedDigests: Set<String> = []
    ) {
        self.implementationVersion = implementationVersion
        self.rejectedStagedDigests = rejectedStagedDigests
    }

    func packageManifest() async throws -> BrokerHelperManifest {
        BrokerHelperManifest(
            schemaVersion: 1,
            packageVersion: "test-package",
            contentDigest: String(repeating: "d", count: 64),
            brokerImplementationVersion: implementationVersion,
            brokerProtocol: .init(minimum: 2, maximum: 2, securityEpoch: 1),
            node: .init(version: "22.23.1", abi: "127", architectures: ["arm64"]),
            nodePty: .init(version: "1.1.0"),
            files: []
        )
    }

    func validateStagedPackage(
        at root: URL,
        expected manifest: BrokerHelperManifest
    ) async throws {}

    func verifiedStagedPackage(at root: URL) async throws -> VerifiedBrokerHelperPackage {
        let digest = root.lastPathComponent
        guard !rejectedStagedDigests.contains(digest) else {
            throw BrokerHelperPackageError.stagedPackageMismatch
        }
        let packageVersion = digest == String(repeating: "d", count: 64)
            ? "test-package"
            : "old-package"
        let manifest = BrokerHelperManifest(
            schemaVersion: 1,
            packageVersion: packageVersion,
            contentDigest: digest,
            brokerImplementationVersion: implementationVersion,
            brokerProtocol: .init(minimum: 2, maximum: 2, securityEpoch: 1),
            node: .init(version: "22.23.1", abi: "127", architectures: ["arm64"]),
            nodePty: .init(version: "1.1.0"),
            files: []
        )
        return VerifiedBrokerHelperPackage(root: root, manifest: manifest)
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

private func spawnPausedChild() throws -> pid_t {
    let argv = [strdup("/bin/sleep"), strdup("60"), nil]
    let environment = [UnsafeMutablePointer<CChar>?](arrayLiteral: nil)
    defer { argv.dropLast().forEach { free($0) } }
    var pid: pid_t = 0
    let result = argv.withUnsafeBufferPointer { arguments in
        environment.withUnsafeBufferPointer { variables in
            posix_spawn(
                &pid,
                "/bin/sleep",
                nil,
                nil,
                UnsafeMutablePointer(mutating: arguments.baseAddress),
                UnsafeMutablePointer(mutating: variables.baseAddress)
            )
        }
    }
    guard result == 0, pid > 1 else { throw POSIXError(.EAGAIN) }
    return pid
}
