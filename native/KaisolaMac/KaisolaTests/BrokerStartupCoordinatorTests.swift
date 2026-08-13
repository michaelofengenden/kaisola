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

    func testDeadRegisteredCurrentIsReplacedWithoutDiscardingLiveDrainsOrRelaunching() async throws {
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

        let deadDigest = String(repeating: "e", count: 64)
        let deadSocket = broker.appendingPathComponent(
            BrokerLaunchConfiguration.generationSocketLeaf(
                userData: profile,
                contentDigest: deadDigest
            )
        )
        let staleDescriptor = try bindUnixSocket(at: deadSocket)
        Darwin.close(staleDescriptor)
        let deadInfo = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: 1,
            packageVersion: "old-package",
            contentDigest: deadDigest,
            pid: Int32.max,
            socketPath: deadSocket.path,
            token: String(repeating: "c", count: 64),
            startedAt: 1,
            version: "stale-native"
        )
        let deadMetadataURL = metadataDirectory.appendingPathComponent("\(deadDigest).json")
        try JSONEncoder().encode(deadInfo).write(to: deadMetadataURL)
        _ = chmod(deadMetadataURL.path, 0o600)
        let dead = BrokerGenerationRecord(
            id: deadDigest,
            role: .current,
            info: deadInfo,
            packageRoot: profile
                .appendingPathComponent("broker-generations", isDirectory: true)
                .appendingPathComponent(deadDigest, isDirectory: true)
                .path,
            registeredAt: 1
        )
        let drainA = try makeLiveDrainingGeneration(
            profile: profile,
            template: dead,
            contentDigest: String(repeating: "a", count: 64)
        )
        let drainB = try makeLiveDrainingGeneration(
            profile: profile,
            template: dead,
            contentDigest: String(repeating: "b", count: 64)
        )
        defer {
            Darwin.close(drainA.descriptor)
            Darwin.close(drainB.descriptor)
        }
        let store = BrokerGenerationRegistryStore(profileRoot: profile)
        _ = try store.save(
            currentGenerationID: dead.id,
            generations: [dead, drainB.generation, drainA.generation],
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
        let afterFirstPrepare = try store.load()
        let adoptedAgain = try await coordinator.prepare()
        let afterSecondPrepare = try store.load()
        let launchCount = await launcher.launchCount
        let expectedDrains = [drainA.generation, drainB.generation]

        XCTAssertEqual(replacement.contentDigest, String(repeating: "d", count: 64))
        XCTAssertEqual(adoptedAgain, replacement)
        XCTAssertEqual(afterFirstPrepare.revision, 2)
        XCTAssertEqual(afterFirstPrepare.topology?.current.info, replacement)
        XCTAssertEqual(afterFirstPrepare.topology?.draining, expectedDrains)
        XCTAssertEqual(afterSecondPrepare, afterFirstPrepare)
        XCTAssertEqual(launchCount, 1, "a published replacement must be adopted, not relaunched")
        await launcher.close()
    }

    func testDeadCurrentPromotesAnAlreadyDrainingTargetWithoutDuplicatingIt() async throws {
        let fixture = try makeDeadCurrentWithDrains(
            drainDigests: [String(repeating: "d", count: 64), String(repeating: "a", count: 64)]
        )
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }
        let targetBefore = try XCTUnwrap(fixture.drains.first(where: {
            $0.generation.id == String(repeating: "d", count: 64)
        }))
        let unrelated = try XCTUnwrap(fixture.drains.first(where: {
            $0.generation.id == String(repeating: "a", count: 64)
        }))
        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        let replacement = try await coordinator.prepare()
        let registry = try fixture.store.load()
        let topology = try XCTUnwrap(registry.topology)

        XCTAssertEqual(topology.current.info, replacement)
        XCTAssertEqual(topology.current.id, targetBefore.generation.id)
        XCTAssertEqual(topology.current.registeredAt, targetBefore.generation.registeredAt)
        XCTAssertEqual(topology.draining, [unrelated.generation])
        XCTAssertEqual(Set(registry.generations.map(\.id)).count, registry.generations.count)
        await launcher.close()
    }

    func testDeadCurrentReplacementFailsClosedWhenRegistryRevisionChangesDuringLaunch() async throws {
        let fixture = try makeDeadCurrentWithDrains(
            drainDigests: [String(repeating: "a", count: 64)]
        )
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }
        let winnerDigest = String(repeating: "f", count: 64)
        let winner = try makeLiveDrainingGeneration(
            profile: fixture.profile,
            template: fixture.dead,
            contentDigest: winnerDigest
        )
        defer { Darwin.close(winner.descriptor) }
        let winnerCurrent = BrokerGenerationRecord(
            id: winner.generation.id,
            role: .current,
            info: winner.generation.info,
            packageRoot: winner.generation.packageRoot,
            registeredAt: winner.generation.registeredAt
        )
        let selection = BrokerGenerationSelection(
            generationID: winnerDigest,
            selectingAppContentDigest: String(repeating: "9", count: 64),
            selectedAt: 9
        )
        let originalDrain = try XCTUnwrap(fixture.drains.first?.generation)
        let launcher = FakeBrokerHelperLauncher(onLaunch: {
            _ = try fixture.store.save(
                currentGenerationID: winnerDigest,
                generations: [winnerCurrent, originalDrain],
                expectedRevision: 1,
                selection: selection,
                now: 2
            )
        })
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        do {
            _ = try await coordinator.prepare()
            XCTFail("a stale launcher must not overwrite a concurrent registry winner")
        } catch {
            XCTAssertEqual(error as? BrokerStartupError, .rendezvousChanged)
        }
        let registry = try fixture.store.load()
        XCTAssertEqual(registry.revision, 2)
        XCTAssertEqual(registry.currentGenerationID, winnerDigest)
        XCTAssertEqual(registry.topology?.current, winnerCurrent)
        XCTAssertEqual(registry.topology?.draining, [originalDrain])
        XCTAssertEqual(registry.selection, selection)
        let launchCount = await launcher.launchCount
        XCTAssertEqual(launchCount, 1)
        await launcher.close()
    }

    func testDeadCurrentReplacementFailsClosedWhenRegistryDisappearsDuringLaunch() async throws {
        let fixture = try makeDeadCurrentWithDrains(
            drainDigests: [String(repeating: "a", count: 64), String(repeating: "b", count: 64)]
        )
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }
        let drainMetadata = try fixture.drains.map { try Data(contentsOf: $0.metadataURL) }
        let launcher = FakeBrokerHelperLauncher(onLaunch: {
            try FileManager.default.removeItem(at: fixture.store.registryURL)
        })
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        do {
            _ = try await coordinator.prepare()
            XCTFail("a vanished captured registry must not be recreated without its drains")
        } catch {
            XCTAssertEqual(error as? BrokerStartupError, .rendezvousChanged)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.registryURL.path))
        for (index, drain) in fixture.drains.enumerated() {
            XCTAssertEqual(try Data(contentsOf: drain.metadataURL), drainMetadata[index])
            XCTAssertTrue(FileManager.default.fileExists(atPath: drain.generation.info.socketPath))
        }
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
        let upgradeAuthorizations = await requester.recordedUpgradeAuthorizations()
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
        XCTAssertEqual(upgradeAuthorizations, [.sealedLegacyFallback])
        XCTAssertEqual(cancelCalls, 0)
        XCTAssertEqual(launchCalls, 1)
        await launcher.close()
    }

    func testRollingCutoverDoesNotAuthorizeLegacyAdministrationForTamperedPriorPackage() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let requester = FakeRollingBrokerUpgradeRequester(
            upgradeDecision: .accepted,
            requiredUpgradeAuthorization: .sealedLegacyFallback
        )
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

        let adopted = try await coordinator.prepare()
        let registry = try BrokerGenerationRegistryStore(profileRoot: live.profile).load()
        let state = await coordinator.upgradeState()
        let authorizations = await requester.recordedUpgradeAuthorizations()

        XCTAssertEqual(adopted, live.info)
        XCTAssertEqual(registry.currentGenerationID, oldDigest)
        XCTAssertTrue(registry.topology?.draining.isEmpty == true)
        XCTAssertEqual(authorizations, [.dedicatedOnly])
        XCTAssertEqual(state, .pending(
            fromContentDigest: oldDigest,
            targetContentDigest: String(repeating: "d", count: 64),
            reason: .requestUnavailable
        ))
        await launcher.close()
    }

    func testAcceptedRollingHandoffCancelsDeterministicallyWhenTargetLaunchFails() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            failLaunch: true
        )
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
        let launchCount = await launcher.launchCount
        let cancelCount = await requester.cancelCallCount()
        let cancelAuthorizations = await requester.recordedCancelAuthorizations()

        XCTAssertEqual(adopted, live.info)
        XCTAssertEqual(registry.currentGenerationID, oldDigest)
        XCTAssertTrue(registry.topology?.draining.isEmpty == true)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(cancelAuthorizations, [.sealedLegacyFallback])
        XCTAssertEqual(state, .pending(
            fromContentDigest: oldDigest,
            targetContentDigest: String(repeating: "d", count: 64),
            reason: .launchFailed
        ))
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

    func testTimedOutFirstRetirementIsQuarantinedWhileTwoHealthyDrainsRetire() async throws {
        let home = try privateTemporaryDirectory()
        let stuckDigest = String(repeating: "a", count: 64)
        let oldDigest = String(repeating: "e", count: 64)
        let laterDigest = String(repeating: "f", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let launcher = FakeBrokerHelperLauncher(implementationVersion: 2)
        let locator = BrokerInfoLocator(userDataCandidates: [live.profile])
        let cutoverCoordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted),
            rollingUpdatesEnabled: true
        )
        _ = try await cutoverCoordinator.prepare()

        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let cutoverRegistry = try store.load()
        let cutoverTopology = try XCTUnwrap(cutoverRegistry.topology)
        let old = try XCTUnwrap(cutoverTopology.draining.first)
        let stuck = try makeLiveDrainingGeneration(
            profile: live.profile,
            template: old,
            contentDigest: stuckDigest
        )
        let later = try makeLiveDrainingGeneration(
            profile: live.profile,
            template: old,
            contentDigest: laterDigest
        )
        defer {
            Darwin.close(stuck.descriptor)
            Darwin.close(later.descriptor)
        }
        let rewritten = try store.save(
            currentGenerationID: cutoverTopology.current.id,
            generations: [
                cutoverTopology.current,
                stuck.generation,
                old,
                later.generation,
            ],
            expectedRevision: cutoverRegistry.revision
        )
        XCTAssertEqual(
            rewritten.topology?.draining.map(\.id),
            [stuckDigest, oldDigest, laterDigest]
        )

        let requester = FakeRollingBrokerUpgradeRequester(
            upgradeDecision: .accepted,
            retirementDecision: .accepted
        )
        let coordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true,
            retirementWaiter: { generation, profileRoot in
                if generation.id == stuckDigest {
                    throw BrokerStartupError.timedOut(nil)
                }
                let metadataURL = BrokerGenerationRegistryStore(profileRoot: profileRoot)
                    .metadataURL(for: generation)
                _ = metadataURL.path.withCString(Darwin.unlink)
            }
        )

        // The first heartbeat records and bypasses the accepted-but-stuck
        // generation, then commits at most one healthy retirement. The next
        // heartbeat skips the bounded quarantine and reaches the second healthy
        // generation instead of spending its whole budget on the same timeout.
        _ = await coordinator.attemptUpgradeIfNeeded()
        let firstSweepDiagnostics = await coordinator.retirementDiagnostics()
        XCTAssertEqual(firstSweepDiagnostics.count, 1)
        XCTAssertEqual(firstSweepDiagnostics.first?.generationID, stuckDigest)
        XCTAssertEqual(firstSweepDiagnostics.first?.nextAttemptInSweeps, 2)
        _ = await coordinator.attemptUpgradeIfNeeded()

        let retired = try store.load()
        XCTAssertEqual(retired.topology?.draining.map(\.id), [stuckDigest])
        let retirementDigests = await requester.retirementContentDigests()
        XCTAssertEqual(retirementDigests, [stuckDigest, oldDigest, laterDigest])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.metadataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.metadataURL(for: old).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: later.metadataURL.path))

        let diagnostics = await coordinator.retirementDiagnostics()
        let diagnostic = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(diagnostic.generationID, stuckDigest)
        XCTAssertEqual(diagnostic.pid, stuck.generation.info.pid)
        XCTAssertEqual(diagnostic.failureCount, 1)
        XCTAssertEqual(diagnostic.reason, .shutdownTimedOut)
        XCTAssertEqual(diagnostic.nextAttemptInSweeps, 1)
        XCTAssertTrue(diagnostic.detail.contains(String(stuckDigest.prefix(12))))
        XCTAssertTrue(diagnostic.detail.contains("timed out"))
        XCTAssertTrue(diagnostic.detail.contains("failure count 1"))

        // Repeated instant failures grow 2 → 4 → 8 → 16 sweeps, then stay
        // capped. Advancing through sweep 31 reaches the fifth failure without
        // letting the quarantine or its user-visible retry estimate grow
        // without bound.
        for _ in 0..<29 {
            _ = await coordinator.attemptUpgradeIfNeeded()
        }
        let boundedDiagnostics = await coordinator.retirementDiagnostics()
        let boundedDiagnostic = try XCTUnwrap(boundedDiagnostics.first)
        XCTAssertEqual(boundedDiagnostic.failureCount, 5)
        XCTAssertEqual(boundedDiagnostic.nextAttemptInSweeps, 16)
        let boundedRetirementDigests = await requester.retirementContentDigests()
        XCTAssertEqual(
            boundedRetirementDigests,
            [stuckDigest, oldDigest, laterDigest] + Array(repeating: stuckDigest, count: 4)
        )
        await launcher.close()
    }

    func testRetirementStopsBeforeLaterCandidateWhenRegistryIdentityChangesDuringWait() async throws {
        let home = try privateTemporaryDirectory()
        let changingDigest = String(repeating: "a", count: 64)
        let oldDigest = String(repeating: "e", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let launcher = FakeBrokerHelperLauncher(implementationVersion: 2)
        let locator = BrokerInfoLocator(userDataCandidates: [live.profile])
        let cutoverCoordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted),
            rollingUpdatesEnabled: true
        )
        _ = try await cutoverCoordinator.prepare()

        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let cutoverRegistry = try store.load()
        let cutoverTopology = try XCTUnwrap(cutoverRegistry.topology)
        let old = try XCTUnwrap(cutoverTopology.draining.first)
        let changing = try makeLiveDrainingGeneration(
            profile: live.profile,
            template: old,
            contentDigest: changingDigest
        )
        defer { Darwin.close(changing.descriptor) }
        let rewritten = try store.save(
            currentGenerationID: cutoverTopology.current.id,
            generations: [cutoverTopology.current, changing.generation, old],
            expectedRevision: cutoverRegistry.revision
        )
        let changedInfo = BrokerInfo(
            protocolVersion: changing.generation.info.protocolVersion,
            securityEpoch: changing.generation.info.securityEpoch,
            implementationVersion: changing.generation.info.implementationVersion,
            packageSchema: changing.generation.info.packageSchema,
            packageVersion: changing.generation.info.packageVersion,
            contentDigest: changing.generation.info.contentDigest,
            pid: changing.generation.info.pid,
            socketPath: changing.generation.info.socketPath,
            token: String(repeating: "c", count: 64),
            startedAt: changing.generation.info.startedAt + 1,
            version: changing.generation.info.version
        )
        let changedGeneration = BrokerGenerationRecord(
            id: changing.generation.id,
            role: .draining,
            info: changedInfo,
            packageRoot: changing.generation.packageRoot,
            registeredAt: changing.generation.registeredAt
        )
        let requester = FakeRollingBrokerUpgradeRequester(
            upgradeDecision: .accepted,
            retirementDecision: .accepted
        )
        let coordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true,
            retirementWaiter: { generation, _ in
                if generation.id == changingDigest {
                    _ = try store.save(
                        currentGenerationID: cutoverTopology.current.id,
                        generations: [cutoverTopology.current, changedGeneration, old],
                        expectedRevision: rewritten.revision
                    )
                    throw BrokerStartupError.timedOut(nil)
                }
            }
        )

        _ = await coordinator.attemptUpgradeIfNeeded()

        let retained = try store.load()
        XCTAssertEqual(retained.topology?.draining, [changedGeneration, old])
        let retirementDigests = await requester.retirementContentDigests()
        XCTAssertEqual(retirementDigests, [changingDigest])
        let diagnostics = await coordinator.retirementDiagnostics()
        XCTAssertTrue(diagnostics.isEmpty)
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
            XCTAssertEqual(
                launchCalls,
                0,
                "A deferred handoff must not churn an unused target process."
            )
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

    private func makeDeadCurrentWithDrains(
        drainDigests: [String]
    ) throws -> (
        home: URL,
        profile: URL,
        dead: BrokerGenerationRecord,
        drains: [(generation: BrokerGenerationRecord, descriptor: Int32, metadataURL: URL)],
        store: BrokerGenerationRegistryStore
    ) {
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
        let digest = String(repeating: "e", count: 64)
        let socket = broker.appendingPathComponent(
            BrokerLaunchConfiguration.generationSocketLeaf(
                userData: profile,
                contentDigest: digest
            )
        )
        let staleDescriptor = try bindUnixSocket(at: socket)
        Darwin.close(staleDescriptor)
        let info = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: 1,
            packageVersion: "old-package",
            contentDigest: digest,
            pid: Int32.max,
            socketPath: socket.path,
            token: String(repeating: "c", count: 64),
            startedAt: 1,
            version: "stale-native"
        )
        let metadataURL = metadataDirectory.appendingPathComponent("\(digest).json")
        try JSONEncoder().encode(info).write(to: metadataURL)
        _ = chmod(metadataURL.path, 0o600)
        let dead = BrokerGenerationRecord(
            id: digest,
            role: .current,
            info: info,
            packageRoot: profile
                .appendingPathComponent("broker-generations", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
                .path,
            registeredAt: 1
        )
        let drains = try drainDigests.enumerated().map { index, digest in
            let drain = try makeLiveDrainingGeneration(
                profile: profile,
                template: dead,
                contentDigest: digest
            )
            let publishedInfo: BrokerInfo
            if digest == String(repeating: "d", count: 64) {
                publishedInfo = BrokerInfo(
                    protocolVersion: drain.generation.info.protocolVersion,
                    securityEpoch: drain.generation.info.securityEpoch,
                    implementationVersion: 1,
                    packageSchema: 1,
                    packageVersion: "test-package",
                    contentDigest: digest,
                    pid: drain.generation.info.pid,
                    socketPath: drain.generation.info.socketPath,
                    token: drain.generation.info.token,
                    startedAt: drain.generation.info.startedAt,
                    version: drain.generation.info.version
                )
                try JSONEncoder().encode(publishedInfo).write(to: drain.metadataURL)
                _ = chmod(drain.metadataURL.path, 0o600)
            } else {
                publishedInfo = drain.generation.info
            }
            return (
                generation: BrokerGenerationRecord(
                    id: drain.generation.id,
                    role: .draining,
                    info: publishedInfo,
                    packageRoot: drain.generation.packageRoot,
                    registeredAt: Int64(index + 7)
                ),
                descriptor: drain.descriptor,
                metadataURL: drain.metadataURL
            )
        }
        let store = BrokerGenerationRegistryStore(profileRoot: profile)
        _ = try store.save(
            currentGenerationID: dead.id,
            generations: [dead] + drains.map(\.generation),
            expectedRevision: nil,
            now: 1
        )
        return (home, profile, dead, drains, store)
    }

    private func makeLiveDrainingGeneration(
        profile: URL,
        template: BrokerGenerationRecord,
        contentDigest: String
    ) throws -> (
        generation: BrokerGenerationRecord,
        descriptor: Int32,
        metadataURL: URL
    ) {
        let packageRoot = profile
            .appendingPathComponent("broker-generations", isDirectory: true)
            .appendingPathComponent(contentDigest, isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let socket = profile
            .appendingPathComponent("session-broker", isDirectory: true)
            .appendingPathComponent(
                BrokerLaunchConfiguration.generationSocketLeaf(
                    userData: profile,
                    contentDigest: contentDigest
                )
            )
        let descriptor = try bindUnixSocket(at: socket)
        let info = BrokerInfo(
            protocolVersion: template.info.protocolVersion,
            securityEpoch: template.info.securityEpoch,
            implementationVersion: template.info.implementationVersion,
            packageSchema: template.info.packageSchema,
            packageVersion: template.info.packageVersion,
            contentDigest: contentDigest,
            pid: getpid(),
            socketPath: socket.path,
            token: template.info.token,
            startedAt: template.info.startedAt,
            version: template.info.version
        )
        let generation = BrokerGenerationRecord(
            id: contentDigest,
            role: .draining,
            info: info,
            packageRoot: packageRoot.path,
            registeredAt: template.registeredAt
        )
        let metadataURL = BrokerGenerationRegistryStore(profileRoot: profile)
            .metadataURL(for: generation)
        try JSONEncoder().encode(info).write(to: metadataURL)
        _ = chmod(metadataURL.path, 0o600)
        return (generation, descriptor, metadataURL)
    }
}

private actor FakeBrokerUpgradeRequester: BrokerUpgradeRequesting {
    let decision: BrokerUpgradeDecision
    private(set) var callCount = 0
    private(set) var authorizations: [BrokerUpgradeAuthorization] = []

    init(decision: BrokerUpgradeDecision) {
        self.decision = decision
    }

    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws -> BrokerUpgradeDecision {
        callCount += 1
        authorizations.append(authorization)
        return decision
    }
}

private actor FakeRollingBrokerUpgradeRequester: BrokerRollingUpdateRequesting {
    private let upgradeDecision: BrokerUpgradeDecision
    private let requiredUpgradeAuthorization: BrokerUpgradeAuthorization?
    private let retirementDecision: BrokerRetirementDecision
    /// Per-generation overrides so one fake can play a populated drain
    /// (pending) and an empty one (accepted) in the same heartbeat.
    private let retirementDecisionsByDigest: [String: BrokerRetirementDecision]
    private let onRetirement: @Sendable () -> Void
    private var upgrades = 0
    private var cancels = 0
    private var retirements = 0
    private var retirementDigests: [String] = []
    private var upgradeAuthorizations: [BrokerUpgradeAuthorization] = []
    private var cancelAuthorizations: [BrokerUpgradeAuthorization] = []
    private var retirementAuthorizations: [BrokerUpgradeAuthorization] = []

    init(
        upgradeDecision: BrokerUpgradeDecision,
        requiredUpgradeAuthorization: BrokerUpgradeAuthorization? = nil,
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
        self.requiredUpgradeAuthorization = requiredUpgradeAuthorization
        self.retirementDecision = retirementDecision
        self.retirementDecisionsByDigest = retirementDecisionsByDigest
        self.onRetirement = onRetirement
    }

    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws -> BrokerUpgradeDecision {
        upgrades += 1
        upgradeAuthorizations.append(authorization)
        if let requiredUpgradeAuthorization,
           authorization != requiredUpgradeAuthorization {
            throw BrokerClientError.authenticationRejected
        }
        return upgradeDecision
    }

    func cancelRollingUpdate(
        from info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws {
        cancels += 1
        cancelAuthorizations.append(authorization)
    }

    func requestRetirement(
        of info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws -> BrokerRetirementDecision {
        retirements += 1
        retirementAuthorizations.append(authorization)
        retirementDigests.append(info.contentDigest ?? "legacy")
        let decision = info.contentDigest.flatMap { retirementDecisionsByDigest[$0] }
            ?? retirementDecision
        if decision == .accepted { onRetirement() }
        return decision
    }

    func upgradeCallCount() -> Int { upgrades }
    func cancelCallCount() -> Int { cancels }
    func retirementCallCount() -> Int { retirements }
    func retirementContentDigests() -> [String] { retirementDigests }
    func recordedUpgradeAuthorizations() -> [BrokerUpgradeAuthorization] {
        upgradeAuthorizations
    }
    func recordedCancelAuthorizations() -> [BrokerUpgradeAuthorization] {
        cancelAuthorizations
    }
    func recordedRetirementAuthorizations() -> [BrokerUpgradeAuthorization] {
        retirementAuthorizations
    }
}

private actor FakeBrokerHelperLauncher: BrokerHelperLaunching {
    private let implementationVersion: Int
    private let rejectedStagedDigests: Set<String>
    private let failLaunch: Bool
    private let onLaunch: @Sendable () throws -> Void
    private(set) var launchCount = 0
    private var descriptor: Int32 = -1
    private var socketURL: URL?

    init(
        implementationVersion: Int = 1,
        rejectedStagedDigests: Set<String> = [],
        failLaunch: Bool = false,
        onLaunch: @escaping @Sendable () throws -> Void = {}
    ) {
        self.implementationVersion = implementationVersion
        self.rejectedStagedDigests = rejectedStagedDigests
        self.failLaunch = failLaunch
        self.onLaunch = onLaunch
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
        try onLaunch()
        if failLaunch {
            throw BrokerBootstrapError.launchRejected("focused test")
        }
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
