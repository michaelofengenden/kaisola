import Darwin
import Foundation
import KaisolaBrokerProtocol
import Security

protocol BrokerInfoPreparing: Sendable {
    func prepare() async throws -> BrokerInfo
}

protocol BrokerGenerationTopologyProviding: BrokerInfoPreparing {
    func generationTopology() async -> BrokerGenerationTopology?
}

struct BrokerUpgradeBlockers: Equatable, Sendable {
    let liveTerminalCount: Int
    let liveTerminalIDs: [String]
    let busyAgentCount: Int
    let busyTerminalIDs: [String]
    let childTaskCount: Int
}

enum BrokerUpgradePendingReason: Equatable, Sendable {
    case liveWork(BrokerUpgradeBlockers)
    case activityChanged(BrokerUpgradeBlockers)
    case companionLeaseChanged(BrokerUpgradeBlockers)
    case legacyIdentityUnavailable
    case identityChanged
    case requestUnavailable
    case shutdownTimedOut
    case launchFailed
}

enum BrokerUpgradeState: Equatable, Sendable {
    case unknown
    case current(contentDigest: String)
    case checking(fromContentDigest: String, targetContentDigest: String)
    case pending(
        fromContentDigest: String?,
        targetContentDigest: String,
        reason: BrokerUpgradePendingReason
    )
    case updating(fromContentDigest: String, targetContentDigest: String)

    var detail: String {
        switch self {
        case .unknown:
            "Terminal continuity has not been checked yet."
        case let .current(contentDigest):
            "Terminal continuity is up to date · content \(contentDigest)."
        case let .checking(fromContentDigest, targetContentDigest):
            "Checking a terminal-continuity update \(Self.transition(fromContentDigest, targetContentDigest)) safely."
        case let .pending(from, target, .liveWork(blockers)):
            "Terminal-continuity update waiting \(Self.transition(from, target)): \(blockers.liveTerminalCount) live terminal(s), \(blockers.busyAgentCount) working agent(s), \(blockers.childTaskCount) child task(s)."
        case let .pending(from, target, .activityChanged(blockers)):
            "Terminal-continuity update retrying \(Self.transition(from, target)): terminal activity changed during the stability window (\(blockers.liveTerminalCount) retained terminal(s))."
        case let .pending(from, target, .companionLeaseChanged(blockers)):
            "Terminal-continuity update retrying \(Self.transition(from, target)): Companion control changed during the stability window (\(blockers.liveTerminalCount) retained terminal(s))."
        case let .pending(from, target, .legacyIdentityUnavailable):
            "Terminal-continuity update waiting \(Self.transition(from, target)): this older version cannot prove a safe handoff."
        case let .pending(from, target, .identityChanged):
            "Terminal-continuity update waiting \(Self.transition(from, target)): the running service changed during the safety check."
        case let .pending(from, target, .requestUnavailable):
            "Terminal-continuity update waiting \(Self.transition(from, target)): the running version cannot complete a verified handoff."
        case let .pending(from, target, .shutdownTimedOut):
            "Terminal-continuity update waiting \(Self.transition(from, target)): the old version did not finish its safe handoff."
        case let .pending(from, target, .launchFailed):
            "Terminal-continuity update waiting \(Self.transition(from, target)): the replacement could not be started yet."
        case let .updating(fromContentDigest, targetContentDigest):
            "Terminal continuity is updating \(Self.transition(fromContentDigest, targetContentDigest)); no terminal processes are being interrupted."
        }
    }

    private static func transition(_ from: String?, _ target: String) -> String {
        "content \(from ?? "legacy-unsealed") → \(target)"
    }
}

enum BrokerUpgradeDecision: Equatable, Sendable {
    case current
    case accepted
    case deferred(BrokerUpgradeBlockers)
    case activityChanged(BrokerUpgradeBlockers)
    case companionLeaseChanged(BrokerUpgradeBlockers)
    case identityChanged
}

protocol BrokerUpgradeRequesting: Sendable {
    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerUpgradeDecision
}

enum BrokerRetirementDecision: Equatable, Sendable {
    case accepted
    case deferred(BrokerUpgradeBlockers, clientCount: Int)
    case identityChanged
}

protocol BrokerRollingUpdateRequesting: BrokerUpgradeRequesting {
    func cancelRollingUpdate(from info: BrokerInfo, targetContentDigest: String) async throws
    func requestRetirement(
        of info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerRetirementDecision
}

protocol BrokerUpgradeMonitoring: Sendable {
    func upgradeState() async -> BrokerUpgradeState
    func attemptUpgradeIfNeeded() async -> BrokerUpgradeState
}

struct BrokerRollbackCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let brokerVersion: String
    let packageVersion: String
    let implementationVersion: Int
    let pid: Int32
    let retainedForExplicitSelection: Bool
}

enum BrokerRollbackError: Error, Equatable, LocalizedError {
    case unavailable
    case targetUnavailable
    case targetNotVerified
    case incompatibleTarget
    case quiescenceDeferred
    case identityChanged
    case activationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Broker rollback is unavailable for this terminal-continuity version."
        case .targetUnavailable:
            "That retained broker generation is no longer available."
        case .targetNotVerified:
            "The retained broker package no longer matches its sealed generation."
        case .incompatibleTarget:
            "That retained broker generation is not compatible with this app."
        case .quiescenceDeferred:
            "Terminal activity changed before rollback could commit. Try again when agents are idle."
        case .identityChanged:
            "Broker identity changed before rollback could commit."
        case .activationFailed:
            "The selected generation could not be activated; terminal creation remains safely paused."
        }
    }
}

protocol BrokerGenerationRollbackServing: Sendable {
    func rollbackCandidates() async -> [BrokerRollbackCandidate]
    func rollback(toGenerationID generationID: String) async throws -> BrokerInfo
}

/// The installed two-generation acceptance lane proves that a replaced app can
/// keep an old PTY on its draining broker, route new work to the sealed current
/// package, and retire the old process only after its last terminal is released.
enum BrokerRollingUpdatePolicy {
    static let clientRoutingEnabled = true
}

struct LocatedBrokerInfoPreparer: BrokerInfoPreparing {
    let locator: any BrokerInfoLocating

    func prepare() async throws -> BrokerInfo {
        try locator.locate()
    }
}

/// A visual Settings fixture must remain broker-free even if future view work
/// accidentally invokes `AppModel.reload()`. This seam has no locator or
/// launcher, so it cannot discover, adopt, start, upgrade, or reconnect.
struct BrokerFreeFixturePreparer: BrokerInfoPreparing {
    func prepare() async throws -> BrokerInfo {
        throw BrokerDiscoveryError.notRunning
    }
}

actor BrokerStartupCoordinator:
    BrokerGenerationTopologyProviding,
    BrokerUpgradeMonitoring,
    BrokerGenerationRollbackServing
{
    private static let maximumSocketPathBytes = 100
    private static let startupTimeoutNanoseconds: UInt64 = 8_000_000_000

    private let locator: BrokerInfoLocator
    private let launcher: any BrokerHelperLaunching
    private let homeDirectory: URL
    private let appVersion: String
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let upgradeRequester: any BrokerUpgradeRequesting
    private let rollingUpdatesEnabled: Bool
    private var currentUpgradeState: BrokerUpgradeState = .unknown
    private var pendingUpgrade: PendingUpgrade?
    private var currentTopology: BrokerGenerationTopology?

    private struct PendingUpgrade: Sendable {
        let info: BrokerInfo
        let package: BrokerHelperManifest
    }

    init(
        locator: BrokerInfoLocator,
        launcher: any BrokerHelperLaunching,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "kaisola-native",
        upgradeRequester: any BrokerUpgradeRequesting = BrokerControlClient(),
        rollingUpdatesEnabled: Bool = BrokerRollingUpdatePolicy.clientRoutingEnabled,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.locator = locator
        self.launcher = launcher
        self.homeDirectory = homeDirectory
        self.appVersion = appVersion
        self.upgradeRequester = upgradeRequester
        self.rollingUpdatesEnabled = rollingUpdatesEnabled
        self.sleep = sleep
    }

    static func live() -> BrokerStartupCoordinator {
        BrokerStartupCoordinator(
            locator: .preview(),
            // The native-only broker must outlive the app without depending on
            // Login Item registration state. The sealed bootstrap double-forks
            // the broker and returns only after publishing its detached PID.
            launcher: BrokerBootstrapClient(directOnly: true)
        )
    }

    /// Real broker lane for the disposable paired-resource fixture. The root is
    /// validated by `NativeResourceWorkloadConfiguration` before this is ever
    /// constructed, and the ordinary live profile remains unreachable.
    static func resourceFixture(userDataRoot: URL) -> BrokerStartupCoordinator {
        BrokerStartupCoordinator(
            locator: BrokerInfoLocator(userDataCandidates: [userDataRoot]),
            launcher: BrokerBootstrapClient(directOnly: true)
        )
    }

    func prepare() async throws -> BrokerInfo {
        let package = try await launcher.packageManifest()
        do {
            let topology = try locator.locateTopology()
            let info = topology.current.info
            // A socket vnode can survive its detached broker. Treating that
            // stale file as a live endpoint makes every connection fail with
            // ECONNREFUSED and bypasses the safe relaunch path below.
            guard !info.isProcessAlive else {
                return try await reconcileLiveBroker(topology, package: package)
            }
            try removeStaleRendezvous(topology.current)
        } catch let error as BrokerDiscoveryError {
            switch error {
            case .notRunning:
                break
            case .privateEndpointUnavailable:
                let topology = try locator.locateTopology(validateSockets: false)
                guard !topology.current.info.isProcessAlive else { throw error }
                try removeStaleRendezvous(topology.current)
            default:
                // A live or ambiguous incompatible broker is never replaced.
                throw error
            }
        }

        let launched = try await launchPackagedBroker(package)
        currentTopology = try locator.locateTopology()
        return launched
    }

    func upgradeState() -> BrokerUpgradeState {
        currentUpgradeState
    }

    func generationTopology() async -> BrokerGenerationTopology? {
        currentTopology
    }

    func rollbackCandidates() async -> [BrokerRollbackCandidate] {
        guard rollingUpdatesEnabled else { return [] }
        guard let topology = try? locator.locateTopology(),
              let registry = try? BrokerGenerationRegistryStore(
                  profileRoot: locator.preferredUserDataRoot
              ).load(),
              registry.topology == topology else { return [] }
        currentTopology = topology
        var candidates: [BrokerRollbackCandidate] = []
        for generation in topology.draining {
            guard generation.info.isProcessAlive,
                  (generation.info.implementationVersion ?? 1) >= 2,
                  let packageRoot = generation.packageRoot,
                  let verified = try? await launcher.verifiedStagedPackage(
                      at: URL(fileURLWithPath: packageRoot, isDirectory: true)
                  ),
                  Self.packageManifest(verified.manifest, exactlyMatches: generation) else {
                continue
            }
            candidates.append(BrokerRollbackCandidate(
                id: generation.id,
                brokerVersion: generation.info.version,
                packageVersion: verified.manifest.packageVersion,
                implementationVersion: verified.manifest.brokerImplementationVersion,
                pid: generation.info.pid,
                retainedForExplicitSelection:
                    registry.selection?.selectingAppContentDigest == generation.id
            ))
        }
        return candidates
    }

    /// Selects one already-running, independently re-verified draining
    /// generation. No process is mutated in place: the registry current pointer
    /// changes atomically, then the selected broker leaves drain mode. Any
    /// failure before both steps complete either restores the prior registry or
    /// leaves terminal creation rejected, never ambiguously split between two
    /// active generations.
    func rollback(toGenerationID generationID: String) async throws -> BrokerInfo {
        guard rollingUpdatesEnabled else { throw BrokerRollbackError.unavailable }
        guard let rolling = upgradeRequester as? any BrokerRollingUpdateRequesting else {
            throw BrokerRollbackError.unavailable
        }
        let topology: BrokerGenerationTopology
        do { topology = try locator.locateTopology() }
        catch { throw BrokerRollbackError.identityChanged }
        guard let target = topology.draining.first(where: { $0.id == generationID }),
              target.info.isProcessAlive,
              topology.current.info.isProcessAlive,
              let packageRoot = target.packageRoot else {
            throw BrokerRollbackError.targetUnavailable
        }
        guard (topology.current.info.implementationVersion ?? 1) >= 2,
              (target.info.implementationVersion ?? 1) >= 2 else {
            throw BrokerRollbackError.incompatibleTarget
        }

        let verified: VerifiedBrokerHelperPackage
        do {
            verified = try await launcher.verifiedStagedPackage(
                at: URL(fileURLWithPath: packageRoot, isDirectory: true)
            )
        } catch {
            throw BrokerRollbackError.targetNotVerified
        }
        guard Self.packageManifest(verified.manifest, exactlyMatches: target) else {
            throw BrokerRollbackError.targetNotVerified
        }
        let selectingAppPackage: BrokerHelperManifest
        do { selectingAppPackage = try await launcher.packageManifest() }
        catch { throw BrokerRollbackError.unavailable }

        let decision: BrokerUpgradeDecision
        do {
            decision = try await rolling.requestUpgrade(
                from: topology.current.info,
                targetContentDigest: target.id
            )
        } catch {
            throw BrokerRollbackError.unavailable
        }
        guard decision == .accepted else {
            switch decision {
            case .identityChanged:
                throw BrokerRollbackError.identityChanged
            default:
                throw BrokerRollbackError.quiescenceDeferred
            }
        }

        let store = BrokerGenerationRegistryStore(profileRoot: locator.preferredUserDataRoot)
        var published: BrokerGenerationRegistry?
        var priorRegistry: BrokerGenerationRegistry?
        do {
            let registry = try store.load()
            guard registry.topology == topology else {
                throw BrokerRollbackError.identityChanged
            }
            priorRegistry = registry
            let selectedCurrent = BrokerGenerationRecord(
                id: target.id,
                role: .current,
                info: target.info,
                packageRoot: target.packageRoot,
                registeredAt: target.registeredAt
            )
            var drains = topology.draining.filter { $0.id != target.id }
            drains.append(BrokerGenerationRecord(
                id: topology.current.id,
                role: .draining,
                info: topology.current.info,
                packageRoot: topology.current.packageRoot,
                registeredAt: topology.current.registeredAt
            ))
            let selection = BrokerGenerationSelection(
                generationID: target.id,
                selectingAppContentDigest: selectingAppPackage.contentDigest,
                selectedAt: max(1, Int64(Date().timeIntervalSince1970 * 1_000))
            )
            published = try store.save(
                currentGenerationID: target.id,
                generations: [selectedCurrent] + drains,
                expectedRevision: registry.revision,
                selection: selection
            )
            do {
                try await rolling.cancelRollingUpdate(
                    from: target.info,
                    targetContentDigest: topology.current.id
                )
            } catch {
                throw BrokerRollbackError.activationFailed
            }

            let selectedTopology = try locator.locateTopology()
            guard selectedTopology.current.id == target.id else {
                throw BrokerRollbackError.identityChanged
            }
            currentTopology = selectedTopology
            pendingUpgrade = nil
            currentUpgradeState = .current(contentDigest: target.id)
            return selectedTopology.current.info
        } catch {
            let registryRestored: Bool
            if let published, let priorRegistry {
                registryRestored = (try? store.save(
                    currentGenerationID: topology.current.id,
                    generations: topology.all,
                    expectedRevision: published.revision,
                    selection: priorRegistry.selection
                )) != nil
            } else {
                registryRestored = true
            }
            if registryRestored {
                try? await rolling.cancelRollingUpdate(
                    from: topology.current.info,
                    targetContentDigest: target.id
                )
                currentTopology = topology
            }
            if let rollbackError = error as? BrokerRollbackError { throw rollbackError }
            if error is BrokerGenerationRegistryError {
                throw BrokerRollbackError.identityChanged
            }
            throw BrokerRollbackError.activationFailed
        }
    }

    /// Called from the app's ordinary inventory heartbeat. A stale broker is
    /// retried only through its own atomic safety method; UI-observed quietness
    /// is never used as replacement authority.
    func attemptUpgradeIfNeeded() async -> BrokerUpgradeState {
        guard let pendingUpgrade else {
            await retireEmptyDrainingGenerationIfPossible()
            return currentUpgradeState
        }
        do {
            let topology = try locator.locateTopology()
            guard topology.current.info == pendingUpgrade.info else {
                self.pendingUpgrade = nil
                currentUpgradeState = .pending(
                    fromContentDigest: pendingUpgrade.info.contentDigest,
                    targetContentDigest: pendingUpgrade.package.contentDigest,
                    reason: .identityChanged
                )
                return currentUpgradeState
            }
            _ = try await reconcileLiveBroker(topology, package: pendingUpgrade.package)
        } catch BrokerStartupError.timedOut(_) {
            currentUpgradeState = .pending(
                fromContentDigest: pendingUpgrade.info.contentDigest,
                targetContentDigest: pendingUpgrade.package.contentDigest,
                reason: .shutdownTimedOut
            )
        } catch {
            currentUpgradeState = .pending(
                fromContentDigest: pendingUpgrade.info.contentDigest,
                targetContentDigest: pendingUpgrade.package.contentDigest,
                reason: .launchFailed
            )
        }
        return currentUpgradeState
    }

    private func retireEmptyDrainingGenerationIfPossible() async {
        guard rollingUpdatesEnabled,
              let rolling = upgradeRequester as? any BrokerRollingUpdateRequesting,
              let topology = currentTopology ?? (try? locator.locateTopology()) else { return }
        let store = BrokerGenerationRegistryStore(profileRoot: locator.preferredUserDataRoot)
        guard let registry = try? store.load(), registry.topology == topology else { return }
        let retainedRollbackID = registry.selection?.selectingAppContentDigest
        // Every non-rollback drain is a candidate, not only the first: the
        // broker itself is the emptiness authority (a populated or still-
        // connected drain answers `pending`), and a populated drain that
        // sorts first would otherwise starve the empty generations behind it
        // of retirement on every heartbeat — the 2026-08-07 stuck-typing
        // incident kept two empty drains pinned in the registry exactly this
        // way. At most one retirement is committed per heartbeat.
        for draining in topology.draining where draining.id != retainedRollbackID {
            let decision: BrokerRetirementDecision
            do {
                decision = try await rolling.requestRetirement(
                    of: draining.info,
                    targetContentDigest: topology.current.id
                )
            } catch {
                continue
            }
            guard decision == .accepted else { continue }
            do {
                try await waitForRetirement(of: draining, profileRoot: locator.preferredUserDataRoot)
                let registry = try store.load()
                guard registry.topology == topology,
                      registry.currentGenerationID == topology.current.id else {
                    throw BrokerGenerationRegistryError.revisionChanged
                }
                let retained = registry.generations.filter { $0.id != draining.id }
                let next = try store.save(
                    currentGenerationID: topology.current.id,
                    generations: retained,
                    expectedRevision: registry.revision,
                    selection: registry.selection
                )
                currentTopology = next.topology
                try garbageCollectRetiredMetadata(draining, store: store)
            } catch {
                // The registry intentionally retains the generation if
                // retirement or its identity recheck is ambiguous. A later
                // heartbeat retries.
            }
            return
        }
    }

    private func waitForRetirement(
        of generation: BrokerGenerationRecord,
        profileRoot: URL
    ) async throws {
        let metadataURL = BrokerGenerationRegistryStore(profileRoot: profileRoot)
            .metadataURL(for: generation)
        let started = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - started < Self.startupTimeoutNanoseconds {
            var metadata = stat()
            let metadataExists = lstat(metadataURL.path, &metadata) == 0
            if !generation.info.isProcessAlive, !metadataExists { return }
            try await sleep(60_000_000)
        }
        throw BrokerStartupError.timedOut(nil)
    }

    private func garbageCollectRetiredMetadata(
        _ generation: BrokerGenerationRecord,
        store: BrokerGenerationRegistryStore
    ) throws {
        let brokerDirectory = store.brokerDirectory.standardizedFileURL
        let metadataDirectory = brokerDirectory.appendingPathComponent(
            BrokerLaunchConfiguration.generationMetadataDirectoryName,
            isDirectory: true
        )
        let logURL = generation.packageRoot == nil
            ? brokerDirectory.appendingPathComponent("broker.log")
            : metadataDirectory.appendingPathComponent("\(generation.id).log")
        for candidate in [logURL, logURL.appendingPathExtension("previous")] {
            var metadata = stat()
            guard lstat(candidate.path, &metadata) == 0 else {
                if errno == ENOENT { continue }
                throw BrokerStartupError.unsafeStaleRendezvous
            }
            guard candidate.standardizedFileURL.deletingLastPathComponent()
                    == logURL.standardizedFileURL.deletingLastPathComponent(),
                  metadata.st_uid == getuid(),
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_mode & 0o077 == 0 else {
                throw BrokerStartupError.unsafeStaleRendezvous
            }
            try FileManager.default.removeItem(at: candidate)
        }
    }

    private func reconcileLiveBroker(
        _ topology: BrokerGenerationTopology,
        package: BrokerHelperManifest
    ) async throws -> BrokerInfo {
        let info = topology.current.info
        let exactPackageIdentity = info.contentDigest == package.contentDigest
            && info.packageVersion == package.packageVersion
            && info.packageSchema == package.schemaVersion
            && info.implementationVersion == package.brokerImplementationVersion
        if exactPackageIdentity {
            pendingUpgrade = nil
            currentUpgradeState = .current(contentDigest: package.contentDigest)
            currentTopology = topology
            return info
        }
        if try await honorsExplicitSelection(topology, selectingAppPackage: package) {
            pendingUpgrade = nil
            currentUpgradeState = .current(contentDigest: topology.current.id)
            currentTopology = topology
            return info
        }
        guard let runningDigest = info.contentDigest else {
            pendingUpgrade = nil
            currentUpgradeState = .pending(
                fromContentDigest: nil,
                targetContentDigest: package.contentDigest,
                reason: .legacyIdentityUnavailable
            )
            return info
        }
        guard runningDigest != package.contentDigest else {
            pendingUpgrade = nil
            currentUpgradeState = .pending(
                fromContentDigest: runningDigest,
                targetContentDigest: package.contentDigest,
                reason: .identityChanged
            )
            return info
        }

        pendingUpgrade = PendingUpgrade(info: info, package: package)
        currentUpgradeState = .checking(
            fromContentDigest: runningDigest,
            targetContentDigest: package.contentDigest
        )
        let supportsRolling = rollingUpdatesEnabled
            && (info.implementationVersion ?? 1) >= 2
        let preparedReplacement: BrokerInfo?
        if supportsRolling {
            do { preparedReplacement = try await launchGeneration(package) }
            catch {
                currentUpgradeState = .pending(
                    fromContentDigest: runningDigest,
                    targetContentDigest: package.contentDigest,
                    reason: .launchFailed
                )
                return info
            }
        } else {
            preparedReplacement = nil
        }

        let decision: BrokerUpgradeDecision
        do {
            decision = try await upgradeRequester.requestUpgrade(
                from: info,
                targetContentDigest: package.contentDigest
            )
        } catch {
            currentUpgradeState = .pending(
                fromContentDigest: runningDigest,
                targetContentDigest: package.contentDigest,
                reason: .requestUnavailable
            )
            return info
        }

        switch decision {
        case .current:
            pendingUpgrade = nil
            currentUpgradeState = .current(contentDigest: package.contentDigest)
            return info
        case let .deferred(blockers):
            currentUpgradeState = .pending(
                fromContentDigest: runningDigest,
                targetContentDigest: package.contentDigest,
                reason: .liveWork(blockers)
            )
            return info
        case let .activityChanged(blockers):
            currentUpgradeState = .pending(
                fromContentDigest: runningDigest,
                targetContentDigest: package.contentDigest,
                reason: .activityChanged(blockers)
            )
            return info
        case let .companionLeaseChanged(blockers):
            currentUpgradeState = .pending(
                fromContentDigest: runningDigest,
                targetContentDigest: package.contentDigest,
                reason: .companionLeaseChanged(blockers)
            )
            return info
        case .identityChanged:
            pendingUpgrade = nil
            currentUpgradeState = .pending(
                fromContentDigest: runningDigest,
                targetContentDigest: package.contentDigest,
                reason: .identityChanged
            )
            return info
        case .accepted:
            currentUpgradeState = .updating(
                fromContentDigest: runningDigest,
                targetContentDigest: package.contentDigest
            )
            if supportsRolling, let preparedReplacement {
                do {
                    let replacement = try await publishCutover(
                        replacement: preparedReplacement,
                        package: package,
                        prior: topology,
                        retainPriorCurrent: true
                    )
                    pendingUpgrade = nil
                    currentUpgradeState = .current(contentDigest: package.contentDigest)
                    currentTopology = try locator.locateTopology()
                    return replacement
                } catch {
                    if let rolling = upgradeRequester as? any BrokerRollingUpdateRequesting {
                        try? await rolling.cancelRollingUpdate(
                            from: info,
                            targetContentDigest: package.contentDigest
                        )
                    }
                    currentUpgradeState = .pending(
                        fromContentDigest: runningDigest,
                        targetContentDigest: package.contentDigest,
                        reason: .launchFailed
                    )
                    return info
                }
            } else {
                try await waitForSafeShutdown(of: info)
                let prepared = try await launchGeneration(package)
                let replacement = try await publishCutover(
                    replacement: prepared,
                    package: package,
                    prior: topology,
                    retainPriorCurrent: false
                )
                pendingUpgrade = nil
                currentUpgradeState = .current(contentDigest: package.contentDigest)
                currentTopology = try locator.locateTopology()
                return replacement
            }
        }
    }

    private func waitForSafeShutdown(of info: BrokerInfo) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - started < Self.startupTimeoutNanoseconds {
            let metadataStillMatches = (try? locator.locateMetadata(validateSocket: false)) == info
            if !info.isProcessAlive, !metadataStillMatches { return }
            try await sleep(60_000_000)
        }
        throw BrokerStartupError.timedOut(nil)
    }

    private func launchPackagedBroker(_ package: BrokerHelperManifest) async throws -> BrokerInfo {
        let generation = try await launchGeneration(package)
        return try publishFreshGeneration(generation, package: package)
    }

    /// Starts or adopts one exact staged generation without changing which
    /// generation is current. Rolling cutover publishes the registry only
    /// after the old broker commits its activity epoch.
    private func launchGeneration(_ package: BrokerHelperManifest) async throws -> BrokerInfo {
        if let existing = try? locator.locateGenerationMetadata(
            contentDigest: package.contentDigest
        ), existing.isProcessAlive {
            try await verifyStagedPackage(package)
            return existing
        }

        let launchURL = try writeLaunchConfiguration(package: package)
        defer { try? FileManager.default.removeItem(at: launchURL) }
        do {
            _ = try await launcher.launch(configurationURL: launchURL)
        } catch {
            // Another Kaisola window may win the empty-broker launch race. Its
            // exact sealed digest is safe to adopt; any other identity is not.
            if let adopted = try? locator.locate(),
               adopted.contentDigest == package.contentDigest {
                return adopted
            }
            // The competing generation can publish its own metadata before it
            // wins the registry compare-and-swap. Complete that same exact
            // publication instead of launching a duplicate process.
            if let adopted = try? locator.locateGenerationMetadata(
                contentDigest: package.contentDigest
            ), adopted.isProcessAlive {
                try await verifyStagedPackage(package)
                return adopted
            }
            throw error
        }

        let started = DispatchTime.now().uptimeNanoseconds
        var lastError: (any Error)?
        while DispatchTime.now().uptimeNanoseconds - started < Self.startupTimeoutNanoseconds {
            do {
                let info = try locator.locateGenerationMetadata(
                    contentDigest: package.contentDigest
                )
                guard info.contentDigest == package.contentDigest,
                      info.isProcessAlive else {
                    throw BrokerStartupError.rendezvousChanged
                }
                try await verifyStagedPackage(package)
                return info
            } catch {
                lastError = error
                try await sleep(60_000_000)
            }
        }
        throw BrokerStartupError.timedOut(lastError?.localizedDescription)
    }

    private func verifyStagedPackage(_ package: BrokerHelperManifest) async throws {
        let root = locator.preferredUserDataRoot
            .appendingPathComponent("broker-generations", isDirectory: true)
            .appendingPathComponent(package.contentDigest, isDirectory: true)
        try await launcher.validateStagedPackage(
            at: root,
            expected: package
        )
    }

    private func honorsExplicitSelection(
        _ topology: BrokerGenerationTopology,
        selectingAppPackage: BrokerHelperManifest
    ) async throws -> Bool {
        guard topology.current.packageRoot != nil else { return false }
        let registry = try BrokerGenerationRegistryStore(
            profileRoot: locator.preferredUserDataRoot
        ).load()
        guard registry.topology == topology,
              let selection = registry.selection,
              selection.generationID == topology.current.id,
              selection.selectingAppContentDigest == selectingAppPackage.contentDigest,
              let packageRoot = topology.current.packageRoot else {
            return false
        }
        let verified = try await launcher.verifiedStagedPackage(
            at: URL(fileURLWithPath: packageRoot, isDirectory: true)
        )
        guard Self.packageManifest(verified.manifest, exactlyMatches: topology.current) else {
            throw BrokerRollbackError.targetNotVerified
        }
        return true
    }

    private static func packageManifest(
        _ manifest: BrokerHelperManifest,
        exactlyMatches generation: BrokerGenerationRecord
    ) -> Bool {
        manifest.contentDigest == generation.id
            && manifest.packageVersion == generation.info.packageVersion
            && manifest.schemaVersion == generation.info.packageSchema
            && manifest.brokerImplementationVersion == generation.info.implementationVersion
            && manifest.brokerProtocol.minimum <= BrokerWire.protocolVersion
            && manifest.brokerProtocol.maximum >= BrokerWire.protocolVersion
            && manifest.brokerProtocol.securityEpoch == BrokerWire.securityEpoch
    }

    private func writeLaunchConfiguration(package: BrokerHelperManifest) throws -> URL {
        let userData = locator.preferredUserDataRoot.standardizedFileURL
        try preparePrivateDirectory(userData)
        let brokerDirectory = userData.appendingPathComponent("session-broker", isDirectory: true)
        try preparePrivateDirectory(brokerDirectory)
        let metadataDirectory = brokerDirectory.appendingPathComponent(
            BrokerLaunchConfiguration.generationMetadataDirectoryName,
            isDirectory: true
        )
        try preparePrivateDirectory(metadataDirectory)
        let socket = try socketPath(userData: userData, contentDigest: package.contentDigest)
        try preparePrivateDirectory(URL(fileURLWithPath: socket).deletingLastPathComponent())

        var tokenBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes) == errSecSuccess else {
            throw BrokerStartupError.randomnessUnavailable
        }
        let token = tokenBytes.map { String(format: "%02x", $0) }.joined()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let configuration = BrokerLaunchConfiguration(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: package.brokerImplementationVersion,
            packageSchema: package.schemaVersion,
            packageVersion: package.packageVersion,
            contentDigest: package.contentDigest,
            packageRoot: userData
                .appendingPathComponent("broker-generations", isDirectory: true)
                .appendingPathComponent(package.contentDigest, isDirectory: true)
                .path,
            token: token,
            socketPath: socket,
            infoFile: metadataDirectory.appendingPathComponent("\(package.contentDigest).json").path,
            lockFile: metadataDirectory.appendingPathComponent("\(package.contentDigest).lock").path,
            storageDir: userData.appendingPathComponent("terminal-cache", isDirectory: true).path,
            logFile: metadataDirectory.appendingPathComponent("\(package.contentDigest).log").path,
            startedAt: timestamp,
            version: appVersion,
            smoke: false
        )
        let launchURL = brokerDirectory
            .appendingPathComponent("launch-native-\(UUID().uuidString.lowercased()).json")
        try configuration.validate(configurationURL: launchURL, homeDirectory: homeDirectory)
        let data = try JSONEncoder.sorted.encode(configuration)
        try writeExclusivePrivateFile(data, to: launchURL)
        return launchURL
    }

    private func socketPath(userData: URL, contentDigest: String) throws -> String {
        let socketLeaf = BrokerLaunchConfiguration.generationSocketLeaf(
            userData: userData,
            contentDigest: contentDigest
        )
        let durable = userData
            .appendingPathComponent("session-broker", isDirectory: true)
            .appendingPathComponent(socketLeaf).path
        if durable.utf8.count <= Self.maximumSocketPathBytes { return durable }
        let compact = homeDirectory
            .appendingPathComponent(".kaisola-session", isDirectory: true)
            .appendingPathComponent(socketLeaf).path
        guard compact.utf8.count <= Self.maximumSocketPathBytes else {
            throw BrokerClientError.socketPathTooLong
        }
        return compact
    }

    private func publishFreshGeneration(
        _ info: BrokerInfo,
        package: BrokerHelperManifest
    ) throws -> BrokerInfo {
        guard info.contentDigest == package.contentDigest,
              info.packageVersion == package.packageVersion,
              info.packageSchema == package.schemaVersion,
              info.implementationVersion == package.brokerImplementationVersion,
              info.isProcessAlive else {
            throw BrokerStartupError.rendezvousChanged
        }
        let userData = locator.preferredUserDataRoot.standardizedFileURL
        let record = BrokerGenerationRecord(
            id: package.contentDigest,
            role: .current,
            info: info,
            packageRoot: userData
                .appendingPathComponent("broker-generations", isDirectory: true)
                .appendingPathComponent(package.contentDigest, isDirectory: true)
                .path,
            registeredAt: max(1, info.startedAt)
        )
        let store = BrokerGenerationRegistryStore(profileRoot: userData)
        do {
            _ = try store.save(
                currentGenerationID: record.id,
                generations: [record],
                expectedRevision: nil
            )
        } catch BrokerGenerationRegistryError.revisionChanged {
            let existing = try store.load()
            if existing.topology?.current == record {
                // A second app window published the same launched generation.
            } else if let topology = existing.topology,
                      topology.draining.isEmpty,
                      !topology.current.info.isProcessAlive {
                _ = try store.save(
                    currentGenerationID: record.id,
                    generations: [record],
                    expectedRevision: existing.revision
                )
            } else {
                throw BrokerStartupError.rendezvousChanged
            }
        }
        let adopted = try locator.locate()
        guard adopted == info else { throw BrokerStartupError.rendezvousChanged }
        pendingUpgrade = nil
        currentUpgradeState = .current(contentDigest: package.contentDigest)
        return adopted
    }

    private func publishCutover(
        replacement: BrokerInfo,
        package: BrokerHelperManifest,
        prior: BrokerGenerationTopology,
        retainPriorCurrent: Bool
    ) async throws -> BrokerInfo {
        guard replacement.contentDigest == package.contentDigest,
              replacement.packageVersion == package.packageVersion,
              replacement.packageSchema == package.schemaVersion,
              replacement.implementationVersion == package.brokerImplementationVersion,
              replacement.isProcessAlive else {
            throw BrokerStartupError.rendezvousChanged
        }
        try await verifyStagedPackage(package)

        let userData = locator.preferredUserDataRoot.standardizedFileURL
        let store = BrokerGenerationRegistryStore(profileRoot: userData)
        let existingRegistry: BrokerGenerationRegistry?
        if prior.current.packageRoot == nil {
            existingRegistry = nil
        } else {
            let loaded = try store.load()
            guard loaded.topology == prior else {
                throw BrokerGenerationRegistryError.revisionChanged
            }
            existingRegistry = loaded
        }

        let priorTarget = prior.all.first(where: { $0.id == package.contentDigest })
        let current = BrokerGenerationRecord(
            id: package.contentDigest,
            role: .current,
            info: replacement,
            packageRoot: userData
                .appendingPathComponent("broker-generations", isDirectory: true)
                .appendingPathComponent(package.contentDigest, isDirectory: true)
                .path,
            registeredAt: priorTarget?.registeredAt ?? max(1, replacement.startedAt)
        )
        var retained = prior.draining.filter { $0.id != package.contentDigest }
        if retainPriorCurrent, prior.current.id != package.contentDigest {
            retained.append(BrokerGenerationRecord(
                id: prior.current.id,
                role: .draining,
                info: prior.current.info,
                packageRoot: prior.current.packageRoot,
                registeredAt: prior.current.registeredAt
            ))
        }
        _ = try store.save(
            currentGenerationID: current.id,
            generations: [current] + retained,
            expectedRevision: existingRegistry?.revision
        )
        let adopted = try locator.locate()
        guard adopted == replacement else {
            throw BrokerStartupError.rendezvousChanged
        }
        return adopted
    }

    private func removeStaleRendezvous(_ stale: BrokerGenerationRecord) throws {
        if stale.packageRoot != nil {
            try removeStaleGenerationRendezvous(stale)
        } else {
            try removeStaleLegacyRendezvous(stale.info)
        }
    }

    private func removeStaleGenerationRendezvous(_ stale: BrokerGenerationRecord) throws {
        guard !stale.info.isProcessAlive else { throw BrokerStartupError.liveBrokerRefused }
        let root = locator.preferredUserDataRoot.standardizedFileURL
        let store = BrokerGenerationRegistryStore(profileRoot: root)
        let registry = try store.load()
        guard registry.topology?.current == stale,
              !stale.info.isProcessAlive,
              try locator.locateGenerationMetadata(
                  contentDigest: stale.id,
                  validateSocket: false
              ) == stale.info else {
            throw BrokerStartupError.rendezvousChanged
        }

        let lockURL = store.brokerDirectory
            .appendingPathComponent(
                BrokerLaunchConfiguration.generationMetadataDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("\(stale.id).lock", isDirectory: false)
        let lockDescriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockDescriptor >= 0 else { throw BrokerStartupError.unsafeStaleRendezvous }
        defer { Darwin.close(lockDescriptor) }
        var lockMetadata = stat()
        guard fstat(lockDescriptor, &lockMetadata) == 0,
              lockMetadata.st_uid == getuid(),
              lockMetadata.st_mode & S_IFMT == S_IFREG,
              lockMetadata.st_mode & 0o077 == 0,
              flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw BrokerStartupError.unsafeStaleRendezvous
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        // Recheck identity after acquiring the generation lock. Another app
        // may have relaunched it between the registry read and the lock.
        guard registry == (try store.load()),
              !stale.info.isProcessAlive,
              try locator.locateGenerationMetadata(
                  contentDigest: stale.id,
                  validateSocket: false
              ) == stale.info else {
            throw BrokerStartupError.rendezvousChanged
        }
        let metadataURL = store.metadataURL(for: stale)
        let socketURL = URL(fileURLWithPath: stale.info.socketPath)
        let expectedSocketLeaf = BrokerLaunchConfiguration.generationSocketLeaf(
            userData: root,
            contentDigest: stale.id
        )
        guard socketURL.lastPathComponent == expectedSocketLeaf else {
            throw BrokerStartupError.unsafeStaleRendezvous
        }
        try removePrivateRendezvousFile(
            socketURL,
            expectedParents: [
                store.brokerDirectory,
                homeDirectory.appendingPathComponent(".kaisola-session", isDirectory: true),
            ],
            allowedKinds: [S_IFSOCK]
        )
        // Remove metadata last. If an earlier unlink fails, the independently
        // published identity remains available for a safe retry.
        try removePrivateRendezvousFile(
            metadataURL,
            expectedParent: metadataURL.deletingLastPathComponent(),
            allowedKinds: [S_IFREG]
        )
    }

    private func removeStaleLegacyRendezvous(_ stale: BrokerInfo) throws {
        guard !stale.isProcessAlive else { throw BrokerStartupError.liveBrokerRefused }
        let current = try locator.locateMetadata(validateSocket: false)
        guard current == stale, !current.isProcessAlive else {
            throw BrokerStartupError.rendezvousChanged
        }
        let root = locator.preferredUserDataRoot
        let brokerDirectory = root.appendingPathComponent("session-broker", isDirectory: true)
        let removable = [
            brokerDirectory.appendingPathComponent("broker.json"),
            brokerDirectory.appendingPathComponent("broker.lock"),
            URL(fileURLWithPath: stale.socketPath),
        ]
        for url in removable {
            try removePrivateRendezvousFile(
                url,
                expectedParents: [
                    brokerDirectory,
                    homeDirectory.appendingPathComponent(".kaisola-session", isDirectory: true),
                ],
                allowedKinds: [S_IFREG, S_IFSOCK]
            )
        }
    }

    private func removePrivateRendezvousFile(
        _ url: URL,
        expectedParent: URL,
        allowedKinds: Set<mode_t>
    ) throws {
        try removePrivateRendezvousFile(
            url,
            expectedParents: [expectedParent],
            allowedKinds: allowedKinds
        )
    }

    private func removePrivateRendezvousFile(
        _ url: URL,
        expectedParents: Set<URL>,
        allowedKinds: Set<mode_t>
    ) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return }
            throw BrokerStartupError.unsafeStaleRendezvous
        }
        guard expectedParents.contains(url.deletingLastPathComponent()),
              value.st_uid == getuid(),
              value.st_mode & 0o077 == 0,
              allowedKinds.contains(value.st_mode & S_IFMT) else {
            throw BrokerStartupError.unsafeStaleRendezvous
        }
        try FileManager.default.removeItem(at: url)
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        var value = stat()
        if lstat(url.path, &value) == 0 {
            guard value.st_uid == getuid(),
                  value.st_mode & S_IFMT == S_IFDIR,
                  value.st_mode & 0o077 == 0 else {
                throw BrokerStartupError.unsafeDirectory
            }
            return
        }
        guard errno == ENOENT else { throw BrokerStartupError.unsafeDirectory }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(url.path, 0o700)
        guard lstat(url.path, &value) == 0,
              value.st_uid == getuid(),
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_mode & 0o077 == 0 else {
            throw BrokerStartupError.unsafeDirectory
        }
    }

    private func writeExclusivePrivateFile(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BrokerStartupError.couldNotWriteLaunchRequest }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else { throw BrokerStartupError.couldNotWriteLaunchRequest }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw BrokerStartupError.couldNotWriteLaunchRequest }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

enum BrokerStartupError: Error, Equatable, LocalizedError {
    case liveBrokerRefused
    case rendezvousChanged
    case unsafeStaleRendezvous
    case unsafeDirectory
    case randomnessUnavailable
    case couldNotWriteLaunchRequest
    case timedOut(String?)

    var errorDescription: String? {
        switch self {
        case .liveBrokerRefused:
            "A live terminal service was left untouched."
        case .rendezvousChanged:
            "Another Kaisola process changed the saved-session connection; reconnect to adopt it safely."
        case .unsafeStaleRendezvous:
            "Stale session-connection data was preserved because its path or permissions were unsafe."
        case .unsafeDirectory:
            "The session support directory is not private to this macOS user."
        case .randomnessUnavailable:
            "A secure session-connection token could not be generated."
        case .couldNotWriteLaunchRequest:
            "The private session launch request could not be written safely."
        case .timedOut:
            "The session helper launched, but its private connection did not become ready."
        }
    }
}
