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

    func testDeadCurrentNeverPromotesAnAlreadyDrainingTarget() async throws {
        let fixture = try makeDeadCurrentWithDrains(
            drainDigests: [String(repeating: "d", count: 64), String(repeating: "a", count: 64)]
        )
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }
        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        do {
            _ = try await coordinator.prepare()
            XCTFail("an internally draining generation must never be exposed as current")
        } catch {
            XCTAssertEqual(error as? BrokerStartupError, .rendezvousChanged)
        }
        let registry = try fixture.store.load()
        XCTAssertEqual(registry.currentGenerationID, fixture.dead.id)
        XCTAssertEqual(registry.revision, 1)
        await launcher.close()
    }

    /// The routine no-current state: an empty current broker self-exited and
    /// removed its own rendezvous while older generations still drain live
    /// terminals. A fresh launch must replace only the gone current and keep
    /// every draining generation registered, or the app relaunches its packaged
    /// broker forever without ever connecting.
    func testGoneUnpublishedCurrentIsReplacedWhileLiveDrainsArePreserved() async throws {
        let drainDigest = String(repeating: "a", count: 64)
        let fixture = try makeDeadCurrentWithDrains(drainDigests: [drainDigest])
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }
        try FileManager.default.removeItem(
            at: fixture.store.metadataURL(for: fixture.dead)
        )

        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        let replacement = try await coordinator.prepare()
        let registry = try fixture.store.load()
        let launchCount = await launcher.launchCount

        XCTAssertEqual(replacement.pid, getpid())
        XCTAssertEqual(replacement.contentDigest, String(repeating: "d", count: 64))
        XCTAssertEqual(registry.revision, 2)
        XCTAssertEqual(registry.topology?.current.info, replacement)
        XCTAssertEqual(registry.topology?.draining, fixture.drains.map(\.generation))
        XCTAssertNil(registry.selection)
        XCTAssertEqual(launchCount, 1)
        await launcher.close()
    }

    /// Same recovery when the dead current is still published at discovery
    /// time: prepare() removes the stale rendezvous itself, then the fresh
    /// publication must complete with the draining generations preserved.
    func testDeadPublishedCurrentIsReplacedWhileLiveDrainsArePreserved() async throws {
        let drainDigest = String(repeating: "a", count: 64)
        let fixture = try makeDeadCurrentWithDrains(drainDigests: [drainDigest])
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }

        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        let replacement = try await coordinator.prepare()
        let registry = try fixture.store.load()
        let launchCount = await launcher.launchCount

        XCTAssertEqual(replacement.pid, getpid())
        XCTAssertEqual(replacement.contentDigest, String(repeating: "d", count: 64))
        XCTAssertEqual(registry.revision, 2)
        XCTAssertEqual(registry.topology?.current.info, replacement)
        XCTAssertEqual(registry.topology?.draining, fixture.drains.map(\.generation))
        XCTAssertEqual(launchCount, 1)
        await launcher.close()
    }

    /// The same-digest half of the recovery: the registry still names a dead
    /// prior instance of the packaged digest whose rendezvous now describes
    /// the relaunch. Drains survive, and — because the current generation id
    /// does not change — so does an explicit selection pinned to it.
    func testDeadSameDigestCurrentIsRelaunchedKeepingDrainsAndSelection() async throws {
        let packagedDigest = String(repeating: "d", count: 64)
        let drainDigest = String(repeating: "a", count: 64)
        let fixture = try makeDeadCurrent(
            digest: packagedDigest,
            drainDigests: [drainDigest],
            selectionAppDigest: String(repeating: "b", count: 64)
        )
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }

        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        let replacement = try await coordinator.prepare()
        let registry = try fixture.store.load()

        XCTAssertEqual(replacement.pid, getpid())
        XCTAssertEqual(replacement.contentDigest, packagedDigest)
        XCTAssertEqual(registry.revision, 2)
        XCTAssertEqual(registry.currentGenerationID, packagedDigest)
        XCTAssertEqual(registry.topology?.draining, fixture.drains.map(\.generation))
        XCTAssertEqual(
            registry.selection?.selectingAppContentDigest,
            String(repeating: "b", count: 64),
            "a same-digest relaunch must not clear the explicit selection"
        )
        await launcher.close()
    }

    /// A cross-digest replacement retires the selection with the generation it
    /// named — asserted against a fixture that actually seeds one, so the nil
    /// is a decision rather than an accident of the fixture.
    func testCrossDigestRecoveryDropsTheSelectionItsGenerationHeld() async throws {
        let drainDigest = String(repeating: "a", count: 64)
        let fixture = try makeDeadCurrentWithDrains(drainDigests: [drainDigest])
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }
        let seeded = try fixture.store.save(
            currentGenerationID: fixture.dead.id,
            generations: [fixture.dead] + fixture.drains.map(\.generation),
            expectedRevision: 1,
            selection: BrokerGenerationSelection(
                generationID: fixture.dead.id,
                selectingAppContentDigest: String(repeating: "b", count: 64),
                selectedAt: 5
            ),
            now: 5
        )
        XCTAssertNotNil(seeded.selection)
        try FileManager.default.removeItem(
            at: fixture.store.metadataURL(for: fixture.dead)
        )

        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        _ = try await coordinator.prepare()
        let registry = try fixture.store.load()
        XCTAssertEqual(registry.currentGenerationID, String(repeating: "d", count: 64))
        XCTAssertNil(registry.selection)
        await launcher.close()
    }

    /// A draining record whose rendezvous no longer exists must not be copied
    /// into the recovery revision: a phantom written under a fresh revision
    /// could never again match discovered topology, wedging every retirement
    /// sweep behind it.
    func testRecoveryDropsPhantomDrainsInsteadOfWritingThemForward() async throws {
        let liveDrain = String(repeating: "a", count: 64)
        let phantomDrain = String(repeating: "f", count: 64)
        let fixture = try makeDeadCurrentWithDrains(drainDigests: [liveDrain, phantomDrain])
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }
        try FileManager.default.removeItem(
            at: fixture.store.metadataURL(for: fixture.dead)
        )
        try FileManager.default.removeItem(at: fixture.drains[1].metadataURL)

        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        _ = try await coordinator.prepare()
        let registry = try fixture.store.load()
        XCTAssertEqual(
            registry.topology?.draining.map(\.id),
            [liveDrain],
            "the announced drain survives; the phantom must not be reminted"
        )
        await launcher.close()
    }

    /// A recorded current whose process still answers is refused even with its
    /// rendezvous missing: unreachable, but evicting it would orphan whatever
    /// terminals it owns with no record they existed.
    func testAliveUnpublishedCurrentIsStillRefusedReplacement() async throws {
        let drainDigest = String(repeating: "a", count: 64)
        let fixture = try makeDeadCurrent(
            digest: String(repeating: "e", count: 64),
            drainDigests: [drainDigest],
            currentPID: getpid()
        )
        defer { fixture.drains.forEach { Darwin.close($0.descriptor) } }
        try FileManager.default.removeItem(
            at: fixture.store.metadataURL(for: fixture.dead)
        )

        let launcher = FakeBrokerHelperLauncher()
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [fixture.profile]),
            launcher: launcher,
            homeDirectory: fixture.home,
            appVersion: "native-test"
        )

        do {
            _ = try await coordinator.prepare()
            XCTFail("a live recorded current must never be evicted by a fresh launch")
        } catch {
            XCTAssertEqual(error as? BrokerStartupError, .rendezvousChanged)
        }
        let registry = try fixture.store.load()
        XCTAssertEqual(registry.currentGenerationID, fixture.dead.id)
        XCTAssertEqual(registry.revision, 1)
        await launcher.close()
    }

    func testTwoCoordinatorsTargetingSamePackageSerializeThroughPublication() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let targetDigest = String(repeating: "d", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }

        let requester = InterleavingRollingBrokerUpgradeRequester(initialLifecycle: .current)
        let firstLaunchGate = AsyncBrokerTestGate()
        let secondClaimWaitGate = AsyncBrokerTestGate()
        let firstLauncher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: targetDigest,
            onLaunch: { try await firstLaunchGate.enterAndWait() }
        )
        let secondLauncher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: targetDigest
        )
        let firstCoordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: firstLauncher,
            homeDirectory: home,
            appVersion: "native-test-a",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )
        let secondCoordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: secondLauncher,
            homeDirectory: home,
            appVersion: "native-test-b",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true,
            sleep: { _ in try await secondClaimWaitGate.enterAndWait() }
        )

        let first = Task { try await firstCoordinator.prepare() }
        await firstLaunchGate.waitUntilEntered()
        let second = Task { try await secondCoordinator.prepare() }
        await secondClaimWaitGate.waitUntilEntered()
        await firstLaunchGate.release()
        let firstResult = try await first.value
        await secondClaimWaitGate.release()
        let secondResult = try await second.value

        let registry = try BrokerGenerationRegistryStore(profileRoot: live.profile).load()
        let secondLaunchCount = await secondLauncher.launchCount
        let cancelledTargets = await requester.cancelledTargets()
        let lifecycle = await requester.lifecycleState()
        XCTAssertEqual(firstResult.contentDigest, targetDigest)
        XCTAssertEqual(secondResult, firstResult)
        XCTAssertEqual(registry.currentGenerationID, targetDigest)
        XCTAssertEqual(secondLaunchCount, 0)
        XCTAssertEqual(cancelledTargets, [])
        XCTAssertEqual(
            lifecycle,
            .draining(targetContentDigest: targetDigest),
            "the old registered drain must still name the generation that won the registry CAS"
        )
        await firstLauncher.close()
        await secondLauncher.close()
    }

    func testLegacySameTargetCASWinnerIsAdoptedWithoutCancellingItsHandoff() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let targetDigest = String(repeating: "d", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let locator = BrokerInfoLocator(userDataCandidates: [live.profile])
        let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: targetDigest,
            afterLaunch: {
                let prior = try store.load()
                let targetInfo = try locator.locateGenerationMetadata(
                    contentDigest: targetDigest
                )
                let target = BrokerGenerationRecord(
                    id: targetDigest,
                    role: .current,
                    info: targetInfo,
                    packageRoot: live.profile
                        .appendingPathComponent("broker-generations", isDirectory: true)
                        .appendingPathComponent(targetDigest, isDirectory: true)
                        .path,
                    registeredAt: max(1, targetInfo.startedAt)
                )
                let old = BrokerGenerationRecord(
                    id: prior.topology!.current.id,
                    role: .draining,
                    info: prior.topology!.current.info,
                    packageRoot: prior.topology!.current.packageRoot,
                    registeredAt: prior.topology!.current.registeredAt
                )
                _ = try store.save(
                    currentGenerationID: targetDigest,
                    generations: [target, old],
                    expectedRevision: prior.revision,
                    now: 2
                )
            }
        )
        let coordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )

        let replacement = try await coordinator.prepare()
        let registry = try store.load()
        let cancelCallCount = await requester.cancelCallCount()

        XCTAssertEqual(replacement.contentDigest, targetDigest)
        XCTAssertEqual(registry.currentGenerationID, targetDigest)
        XCTAssertEqual(cancelCallCount, 0)
        await launcher.close()
    }

    func testDeadSameTargetRegistryWinnerIsNeverAdoptedAsCurrent() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let targetDigest = String(repeating: "d", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let prior = try XCTUnwrap(try store.load().topology)
        let deadTargetFixture = try makeLiveDrainingGeneration(
            profile: live.profile,
            template: prior.current,
            contentDigest: targetDigest
        )
        defer { Darwin.close(deadTargetFixture.descriptor) }
        let deadInfo = BrokerInfo(
            protocolVersion: deadTargetFixture.generation.info.protocolVersion,
            securityEpoch: deadTargetFixture.generation.info.securityEpoch,
            implementationVersion: 2,
            packageSchema: 1,
            packageVersion: "test-package",
            contentDigest: targetDigest,
            pid: Int32.max,
            socketPath: deadTargetFixture.generation.info.socketPath,
            token: deadTargetFixture.generation.info.token,
            startedAt: deadTargetFixture.generation.info.startedAt,
            version: deadTargetFixture.generation.info.version
        )
        try JSONEncoder().encode(deadInfo).write(to: deadTargetFixture.metadataURL)
        _ = chmod(deadTargetFixture.metadataURL.path, 0o600)
        let deadTarget = BrokerGenerationRecord(
            id: targetDigest,
            role: .current,
            info: deadInfo,
            packageRoot: deadTargetFixture.generation.packageRoot,
            registeredAt: deadTargetFixture.generation.registeredAt
        )
        let oldDrain = BrokerGenerationRecord(
            id: prior.current.id,
            role: .draining,
            info: prior.current.info,
            packageRoot: prior.current.packageRoot,
            registeredAt: prior.current.registeredAt
        )
        let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: targetDigest,
            failLaunch: true,
            onLaunch: {
                _ = try store.save(
                    currentGenerationID: targetDigest,
                    generations: [deadTarget, oldDrain],
                    expectedRevision: prior.registryTopologyVersion,
                    now: 2
                )
            }
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
        let state = await coordinator.upgradeState()

        XCTAssertEqual(adopted, live.info)
        XCTAssertEqual(state, .pending(
            fromContentDigest: oldDigest,
            targetContentDigest: targetDigest,
            reason: .launchFailed
        ))
        await launcher.close()
    }

    func testTamperedSameTargetRegistryWinnerIsNeverAdoptedAsCurrent() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let targetDigest = String(repeating: "d", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let locator = BrokerInfoLocator(userDataCandidates: [live.profile])
        let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: targetDigest,
            rejectedStagedDigests: [targetDigest],
            afterLaunch: {
                let prior = try store.load()
                let targetInfo = try locator.locateGenerationMetadata(
                    contentDigest: targetDigest
                )
                let target = BrokerGenerationRecord(
                    id: targetDigest,
                    role: .current,
                    info: targetInfo,
                    packageRoot: live.profile
                        .appendingPathComponent("broker-generations", isDirectory: true)
                        .appendingPathComponent(targetDigest, isDirectory: true)
                        .path,
                    registeredAt: max(1, targetInfo.startedAt)
                )
                let old = BrokerGenerationRecord(
                    id: prior.topology!.current.id,
                    role: .draining,
                    info: prior.topology!.current.info,
                    packageRoot: prior.topology!.current.packageRoot,
                    registeredAt: prior.topology!.current.registeredAt
                )
                _ = try store.save(
                    currentGenerationID: targetDigest,
                    generations: [target, old],
                    expectedRevision: prior.revision,
                    now: 2
                )
            }
        )
        let coordinator = BrokerStartupCoordinator(
            locator: locator,
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )

        let adopted = try await coordinator.prepare()
        let state = await coordinator.upgradeState()

        XCTAssertEqual(adopted, live.info)
        XCTAssertEqual(state, .pending(
            fromContentDigest: oldDigest,
            targetContentDigest: targetDigest,
            reason: .launchFailed
        ))
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

    func testClaimOwnerDoesNotCancelOtherPreparedTargetFromMixedVersionWindow() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let staleTarget = String(repeating: "f", count: 64)
        let bundledTarget = String(repeating: "d", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let prior = try XCTUnwrap(try store.load().topology)
        let retained = try makeLiveDrainingGeneration(
            profile: live.profile,
            template: prior.current,
            contentDigest: String(repeating: "a", count: 64)
        )
        defer { Darwin.close(retained.descriptor) }
        _ = try store.save(
            currentGenerationID: oldDigest,
            generations: [prior.current, retained.generation],
            expectedRevision: prior.registryTopologyVersion,
            now: 2
        )
        let requester = ClaimedStaleHandoffRequester(staleTarget: staleTarget)
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: bundledTarget
        )
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )

        let replacement = try await coordinator.prepare()
        let cancelled = await requester.cancelledTargets()
        let requests = await requester.upgradeTargets()
        let launchCount = await launcher.launchCount
        let registry = try store.load()

        XCTAssertEqual(replacement, live.info)
        XCTAssertEqual(registry.currentGenerationID, oldDigest)
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(requests, [bundledTarget])
        XCTAssertEqual(launchCount, 0)
        let topology = await coordinator.generationTopology()
        XCTAssertEqual(topology?.current.id, oldDigest)
        XCTAssertEqual(topology?.draining.map(\.id), [retained.generation.id])
        await launcher.close()
    }

    func testPendingOtherHandoffFollowsPublishedCurrentAndCompletesBundledUpgrade() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let publishedDigest = String(repeating: "f", count: 64)
        let bundledDigest = String(repeating: "d", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let requester = ClaimedStaleHandoffRequester(staleTarget: publishedDigest)
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: bundledDigest
        )
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )

        let initiallyAdopted = try await coordinator.prepare()
        XCTAssertEqual(initiallyAdopted, live.info)
        let prior = try XCTUnwrap(try store.load().topology)
        let published = try makeLiveDrainingGeneration(
            profile: live.profile,
            template: prior.current,
            contentDigest: publishedDigest
        )
        defer { Darwin.close(published.descriptor) }
        let publishedCurrent = BrokerGenerationRecord(
            id: publishedDigest,
            role: .current,
            info: published.generation.info,
            packageRoot: published.generation.packageRoot,
            registeredAt: published.generation.registeredAt
        )
        let oldDrain = BrokerGenerationRecord(
            id: prior.current.id,
            role: .draining,
            info: prior.current.info,
            packageRoot: prior.current.packageRoot,
            registeredAt: prior.current.registeredAt
        )
        _ = try store.save(
            currentGenerationID: publishedDigest,
            generations: [publishedCurrent, oldDrain],
            expectedRevision: prior.registryTopologyVersion,
            now: 2
        )
        await requester.markPublished()

        let state = await coordinator.attemptUpgradeIfNeeded()
        let topology = await coordinator.generationTopology()
        let cancelled = await requester.cancelledTargets()

        XCTAssertEqual(state, .current(contentDigest: bundledDigest))
        XCTAssertEqual(topology?.current.id, bundledDigest)
        XCTAssertEqual(cancelled, [])
        await launcher.close()
    }

    func testMutationTimeIdentityChangeKeepsRetryAndFollowsPublishedCurrent() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let publishedDigest = String(repeating: "f", count: 64)
        let bundledDigest = String(repeating: "d", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let requester = ClaimedStaleHandoffRequester(
            staleTarget: publishedDigest,
            firstDecision: .identityChanged
        )
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: bundledDigest
        )
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )

        let initiallyAdopted = try await coordinator.prepare()
        XCTAssertEqual(initiallyAdopted, live.info)
        let prior = try XCTUnwrap(try store.load().topology)
        let published = try makeLiveDrainingGeneration(
            profile: live.profile,
            template: prior.current,
            contentDigest: publishedDigest
        )
        defer { Darwin.close(published.descriptor) }
        let publishedCurrent = BrokerGenerationRecord(
            id: publishedDigest,
            role: .current,
            info: published.generation.info,
            packageRoot: published.generation.packageRoot,
            registeredAt: published.generation.registeredAt
        )
        let oldDrain = BrokerGenerationRecord(
            id: prior.current.id,
            role: .draining,
            info: prior.current.info,
            packageRoot: prior.current.packageRoot,
            registeredAt: prior.current.registeredAt
        )
        _ = try store.save(
            currentGenerationID: publishedDigest,
            generations: [publishedCurrent, oldDrain],
            expectedRevision: prior.registryTopologyVersion,
            now: 2
        )
        await requester.markPublished()

        let state = await coordinator.attemptUpgradeIfNeeded()
        let topology = await coordinator.generationTopology()

        XCTAssertEqual(state, .current(contentDigest: bundledDigest))
        XCTAssertEqual(topology?.current.id, bundledDigest)
        await launcher.close()
    }

    func testPublishedOtherCurrentReroutesEvenWhenItsNextUpgradeDefers() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let publishedDigest = String(repeating: "f", count: 64)
        let bundledDigest = String(repeating: "d", count: 64)
        let blockers = BrokerUpgradeBlockers(
            liveTerminalCount: 1,
            liveTerminalIDs: ["retained"],
            busyAgentCount: 1,
            busyTerminalIDs: ["retained"],
            childTaskCount: 0
        )
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let requester = ClaimedStaleHandoffRequester(
            staleTarget: publishedDigest,
            publishedDecision: .deferred(blockers)
        )
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: bundledDigest
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
        let prior = try XCTUnwrap(try store.load().topology)
        let published = try makeLiveDrainingGeneration(
            profile: live.profile,
            template: prior.current,
            contentDigest: publishedDigest
        )
        defer { Darwin.close(published.descriptor) }
        let publishedCurrent = BrokerGenerationRecord(
            id: publishedDigest,
            role: .current,
            info: published.generation.info,
            packageRoot: published.generation.packageRoot,
            registeredAt: published.generation.registeredAt
        )
        let oldDrain = BrokerGenerationRecord(
            id: prior.current.id,
            role: .draining,
            info: prior.current.info,
            packageRoot: prior.current.packageRoot,
            registeredAt: prior.current.registeredAt
        )
        _ = try store.save(
            currentGenerationID: publishedDigest,
            generations: [publishedCurrent, oldDrain],
            expectedRevision: prior.registryTopologyVersion,
            now: 2
        )
        await requester.markPublished()

        let state = await coordinator.attemptUpgradeIfNeeded()
        let topology = await coordinator.generationTopology()

        XCTAssertEqual(state, .pending(
            fromContentDigest: publishedDigest,
            targetContentDigest: bundledDigest,
            reason: .liveWork(blockers)
        ))
        XCTAssertEqual(
            topology?.current.id,
            publishedDigest,
            "the app must reconnect to the newly authoritative current even if its next upgrade waits"
        )
        await launcher.close()
    }

    func testPublishedOtherCurrentUsesNewDigestWhenReconciliationThrows() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let publishedDigest = String(repeating: "f", count: 64)
        let bundledDigest = String(repeating: "d", count: 64)
        let live = try makeRegisteredLiveBroker(home: home, contentDigest: oldDigest)
        defer { Darwin.close(live.descriptor) }
        let store = BrokerGenerationRegistryStore(profileRoot: live.profile)
        let requester = ClaimedStaleHandoffRequester(staleTarget: publishedDigest)
        let launcher = FakeBrokerHelperLauncher(
            implementationVersion: 2,
            contentDigest: bundledDigest,
            rejectedStagedDigests: [publishedDigest]
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
        let prior = try XCTUnwrap(try store.load().topology)
        let published = try makeLiveDrainingGeneration(
            profile: live.profile,
            template: prior.current,
            contentDigest: publishedDigest
        )
        defer { Darwin.close(published.descriptor) }
        let publishedCurrent = BrokerGenerationRecord(
            id: publishedDigest,
            role: .current,
            info: published.generation.info,
            packageRoot: published.generation.packageRoot,
            registeredAt: published.generation.registeredAt
        )
        let oldDrain = BrokerGenerationRecord(
            id: prior.current.id,
            role: .draining,
            info: prior.current.info,
            packageRoot: prior.current.packageRoot,
            registeredAt: prior.current.registeredAt
        )
        _ = try store.save(
            currentGenerationID: publishedDigest,
            generations: [publishedCurrent, oldDrain],
            expectedRevision: prior.registryTopologyVersion,
            selection: BrokerGenerationSelection(
                generationID: publishedDigest,
                selectingAppContentDigest: bundledDigest,
                selectedAt: 2
            ),
            now: 2
        )

        let state = await coordinator.attemptUpgradeIfNeeded()
        let topology = await coordinator.generationTopology()

        XCTAssertEqual(state, .pending(
            fromContentDigest: publishedDigest,
            targetContentDigest: bundledDigest,
            reason: .launchFailed
        ))
        XCTAssertEqual(topology?.current.id, publishedDigest)
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

    func testAcceptedRollingHandoffNeverCancelsUnprovablyOwnedPrepareWhenLaunchFails() async throws {
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
        XCTAssertEqual(cancelCount, 0)
        XCTAssertEqual(cancelAuthorizations, [])
        XCTAssertEqual(state, .pending(
            fromContentDigest: oldDigest,
            targetContentDigest: String(repeating: "d", count: 64),
            reason: .launchFailed
        ))
        await launcher.close()
    }

    func testLegacyRollingHandoffNeverCancelsUnprovablyOwnedPrepareWhenLaunchFails() async throws {
        let home = try privateTemporaryDirectory()
        let oldDigest = String(repeating: "e", count: 64)
        let live = try makeLiveBroker(
            home: home,
            contentDigest: oldDigest,
            implementationVersion: 2
        )
        defer { Darwin.close(live.descriptor) }
        let requester = FakeRollingBrokerUpgradeRequester(upgradeDecision: .accepted)
        let launcher = FakeBrokerHelperLauncher(implementationVersion: 2, failLaunch: true)
        let coordinator = BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [live.profile]),
            launcher: launcher,
            homeDirectory: home,
            appVersion: "native-test",
            upgradeRequester: requester,
            rollingUpdatesEnabled: true
        )

        let adopted = try await coordinator.prepare()
        let cancelCount = await requester.cancelCallCount()

        XCTAssertEqual(adopted.contentDigest, oldDigest)
        XCTAssertEqual(cancelCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: BrokerGenerationRegistryStore(profileRoot: live.profile).registryURL.path
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
        contentDigest: String?,
        implementationVersion: Int = 1
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
            "implementationVersion": implementationVersion,
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
        drainDigests: [String],
        implementationVersion: Int = 1
    ) throws -> (
        home: URL,
        profile: URL,
        dead: BrokerGenerationRecord,
        drains: [(generation: BrokerGenerationRecord, descriptor: Int32, metadataURL: URL)],
        store: BrokerGenerationRegistryStore
    ) {
        try makeDeadCurrent(
            digest: String(repeating: "e", count: 64),
            drainDigests: drainDigests,
            implementationVersion: implementationVersion
        )
    }

    private func makeDeadCurrent(
        digest: String,
        drainDigests: [String],
        implementationVersion: Int = 1,
        selectionAppDigest: String? = nil,
        currentPID: Int32 = Int32.max
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
            implementationVersion: implementationVersion,
            packageSchema: 1,
            packageVersion: "old-package",
            contentDigest: digest,
            pid: currentPID,
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
                    implementationVersion: implementationVersion,
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
            selection: selectionAppDigest.map {
                BrokerGenerationSelection(
                    generationID: dead.id,
                    selectingAppContentDigest: $0,
                    selectedAt: 1
                )
            },
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

private actor InterleavingRollingBrokerUpgradeRequester: BrokerRollingUpdateRequesting {
    enum Lifecycle: Equatable, Sendable {
        case current
        case draining(targetContentDigest: String)
    }

    private var lifecycle: Lifecycle
    private var cancellations: [String] = []
    init(initialLifecycle: Lifecycle) {
        lifecycle = initialLifecycle
    }

    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws -> BrokerUpgradeDecision {
        switch lifecycle {
        case .current:
            lifecycle = .draining(targetContentDigest: targetContentDigest)
        case .draining(let preparedTarget) where preparedTarget == targetContentDigest:
            break
        case .draining(let preparedTarget):
            // Models the unsafe implementation being regressed: it cancels a
            // different coordinator's prepared target and immediately replaces
            // it before either caller publishes the registry CAS.
            cancellations.append(preparedTarget)
            lifecycle = .draining(targetContentDigest: targetContentDigest)
        }
        return .accepted
    }

    func cancelRollingUpdate(
        from info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws {
        guard lifecycle == .draining(targetContentDigest: targetContentDigest) else {
            throw BrokerClientError.identityChanged
        }
        cancellations.append(targetContentDigest)
        lifecycle = .current
    }

    func requestRetirement(
        of info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws -> BrokerRetirementDecision {
        .identityChanged
    }

    func lifecycleState() -> Lifecycle { lifecycle }
    func cancelledTargets() -> [String] { cancellations }
}

private actor ClaimedStaleHandoffRequester: BrokerRollingUpdateRequesting {
    private let staleTarget: String
    private let firstDecision: BrokerUpgradeDecision?
    private let publishedDecision: BrokerUpgradeDecision
    private var staleHandoffPresent = true
    private var upgrades: [String] = []
    private var cancellations: [String] = []

    init(
        staleTarget: String,
        firstDecision: BrokerUpgradeDecision? = nil,
        publishedDecision: BrokerUpgradeDecision = .accepted
    ) {
        self.staleTarget = staleTarget
        self.firstDecision = firstDecision
        self.publishedDecision = publishedDecision
    }

    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws -> BrokerUpgradeDecision {
        upgrades.append(targetContentDigest)
        if upgrades.count == 1, let firstDecision { return firstDecision }
        return staleHandoffPresent
            ? .preparedForOtherTarget(targetContentDigest: staleTarget)
            : publishedDecision
    }

    func cancelRollingUpdate(
        from info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws {
        guard staleHandoffPresent, targetContentDigest == staleTarget else {
            throw BrokerClientError.identityChanged
        }
        cancellations.append(targetContentDigest)
        staleHandoffPresent = false
    }

    func requestRetirement(
        of info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws -> BrokerRetirementDecision {
        .identityChanged
    }

    func cancelledTargets() -> [String] { cancellations }
    func upgradeTargets() -> [String] { upgrades }
    func markPublished() { staleHandoffPresent = false }
}

private actor AsyncBrokerTestGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async throws {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor FakeBrokerHelperLauncher: BrokerHelperLaunching {
    private let implementationVersion: Int
    private let contentDigest: String
    private let rejectedStagedDigests: Set<String>
    private let failLaunch: Bool
    private let onLaunch: @Sendable () async throws -> Void
    private let afterLaunch: @Sendable () async throws -> Void
    private(set) var launchCount = 0
    private var descriptor: Int32 = -1
    private var socketURL: URL?

    init(
        implementationVersion: Int = 1,
        contentDigest: String = String(repeating: "d", count: 64),
        rejectedStagedDigests: Set<String> = [],
        failLaunch: Bool = false,
        onLaunch: @escaping @Sendable () async throws -> Void = {},
        afterLaunch: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.implementationVersion = implementationVersion
        self.contentDigest = contentDigest
        self.rejectedStagedDigests = rejectedStagedDigests
        self.failLaunch = failLaunch
        self.onLaunch = onLaunch
        self.afterLaunch = afterLaunch
    }

    func packageManifest() async throws -> BrokerHelperManifest {
        BrokerHelperManifest(
            schemaVersion: 1,
            packageVersion: "test-package",
            contentDigest: contentDigest,
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
    ) async throws {
        guard !rejectedStagedDigests.contains(manifest.contentDigest) else {
            throw BrokerHelperPackageError.stagedPackageMismatch
        }
    }

    func verifiedStagedPackage(at root: URL) async throws -> VerifiedBrokerHelperPackage {
        let digest = root.lastPathComponent
        guard !rejectedStagedDigests.contains(digest) else {
            throw BrokerHelperPackageError.stagedPackageMismatch
        }
        let packageVersion = digest == contentDigest
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
        try await onLaunch()
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
        try await afterLaunch()
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
