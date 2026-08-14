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

    /// The same state in one short sentence, with no content digests in it.
    ///
    /// `detail` is diagnostic text: every case names the digests it moved
    /// between, which is exactly what you want when reading a bug report and
    /// exactly what you do not want in the account menu, where two 64-character
    /// hashes stretched the menu across the whole window and buried the one
    /// clause that meant anything. Nil where there is genuinely nothing to say,
    /// so the menu shows a line only when a line is warranted.
    var summary: String? {
        switch self {
        case .unknown:
            nil
        case .current:
            nil
        case .checking:
            "Checking for a terminal update"
        case let .pending(_, _, .liveWork(blockers)):
            Self.liveWorkSummary(blockers)
        case .pending(_, _, .activityChanged):
            "Terminal update retrying after activity changed"
        case .pending(_, _, .companionLeaseChanged):
            "Terminal update retrying after Companion control changed"
        case .pending(_, _, .legacyIdentityUnavailable):
            "Terminal update waiting: this older version cannot prove a safe handoff"
        case .pending(_, _, .identityChanged):
            "Terminal update waiting: the running service changed"
        case .pending(_, _, .requestUnavailable):
            "Terminal update waiting: the running version cannot verify a handoff"
        case .pending(_, _, .shutdownTimedOut):
            "Terminal update waiting: the old version did not finish its handoff"
        case .pending(_, _, .launchFailed):
            "Terminal update waiting: the replacement could not start"
        case .updating:
            "Terminal continuity is updating, without interrupting anything"
        }
    }

    /// Names only the blockers that are actually holding the update.
    ///
    /// A rolling-capable broker retains ordinary live terminals rather than
    /// waiting on them — `rollingUpdateReadiness()` in the node broker keys off
    /// busy agents — so "waiting on N live terminals" was both the wrong reason
    /// and, when an exited terminal still had an open agent turn, capable of
    /// reading "waiting on 0 live terminals". Working agents and child tasks
    /// come first because those are what defer the update; a live-terminal count
    /// is reported only when it is the sole thing left to name.
    static func liveWorkSummary(_ blockers: BrokerUpgradeBlockers) -> String {
        func plural(_ count: Int, _ noun: String) -> String {
            "\(count) \(noun)\(count == 1 ? "" : "s")"
        }
        var parts: [String] = []
        if blockers.busyAgentCount > 0 {
            parts.append(plural(blockers.busyAgentCount, "working agent"))
        }
        if blockers.childTaskCount > 0 {
            parts.append(plural(blockers.childTaskCount, "child task"))
        }
        if parts.isEmpty, blockers.liveTerminalCount > 0 {
            parts.append(plural(blockers.liveTerminalCount, "live terminal"))
        }
        guard !parts.isEmpty else {
            return "Terminal update waiting for work in progress to finish"
        }
        return "Terminal update waiting on " + parts.joined(separator: " and ")
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
    case preparedForOtherTarget(targetContentDigest: String)
    case identityChanged
}

/// Administrative authentication used for a broker-generation lifecycle RPC.
///
/// Brokers shipped before `broker-administration-v1` authenticated their
/// lifecycle lane as controller owner `0`. That shape is safe to reuse only
/// when the coordinator has independently re-verified the exact staged package
/// which owns the authenticated socket. Modern brokers always use their
/// dedicated administrator role; this value merely permits the client to try
/// the sealed legacy bridge after that stronger handshake is unavailable.
enum BrokerUpgradeAuthorization: Equatable, Sendable {
    case dedicatedOnly
    case sealedLegacyFallback
}

protocol BrokerUpgradeRequesting: Sendable {
    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws -> BrokerUpgradeDecision
}

extension BrokerUpgradeRequesting {
    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerUpgradeDecision {
        try await requestUpgrade(
            from: info,
            targetContentDigest: targetContentDigest,
            authorization: .dedicatedOnly
        )
    }
}

enum BrokerRetirementDecision: Equatable, Sendable {
    case accepted
    case deferred(BrokerUpgradeBlockers, clientCount: Int)
    case identityChanged
}

protocol BrokerRollingUpdateRequesting: BrokerUpgradeRequesting {
    func cancelRollingUpdate(
        from info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws
    func requestRetirement(
        of info: BrokerInfo,
        targetContentDigest: String,
        authorization: BrokerUpgradeAuthorization
    ) async throws -> BrokerRetirementDecision
}

extension BrokerRollingUpdateRequesting {
    func cancelRollingUpdate(
        from info: BrokerInfo,
        targetContentDigest: String
    ) async throws {
        try await cancelRollingUpdate(
            from: info,
            targetContentDigest: targetContentDigest,
            authorization: .dedicatedOnly
        )
    }

    func requestRetirement(
        of info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerRetirementDecision {
        try await requestRetirement(
            of: info,
            targetContentDigest: targetContentDigest,
            authorization: .dedicatedOnly
        )
    }
}

protocol BrokerUpgradeMonitoring: Sendable {
    func upgradeState() async -> BrokerUpgradeState
    func attemptUpgradeIfNeeded() async -> BrokerUpgradeState
    func retirementDiagnostics() async -> [BrokerRetirementDiagnostic]
}

enum BrokerRetirementFailureReason: Equatable, Sendable {
    case shutdownTimedOut
    case requestUnavailable
    case identityChanged

    fileprivate var detail: String {
        switch self {
        case .shutdownTimedOut:
            "safe handoff timed out"
        case .requestUnavailable:
            "safe handoff request was unavailable"
        case .identityChanged:
            "broker identity changed during the safety check"
        }
    }
}

struct BrokerRetirementDiagnostic: Equatable, Sendable {
    let generationID: String
    let pid: Int32
    let failureCount: Int
    let reason: BrokerRetirementFailureReason
    let nextAttemptInSweeps: Int

    var detail: String {
        let retry = nextAttemptInSweeps == 0
            ? "retry ready"
            : "retry in \(nextAttemptInSweeps) heartbeat\(nextAttemptInSweeps == 1 ? "" : "s")"
        return [
            "Retirement skipped for content \(generationID.prefix(12))",
            "PID \(pid)",
            reason.detail,
            "failure count \(failureCount)",
            retry,
        ].joined(separator: " · ")
    }
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

/// Fail-closed broker seam for installed visual fixtures. Unlike a preview
/// locator pointed at an empty directory, this type has no launcher and cannot
/// discover, adopt, start, upgrade, or reconnect to any broker even if a future
/// fixture accidentally invokes `AppModel.reload()`.
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
    private static let maximumRetirementBackoffSweeps: UInt64 = 16

    private let locator: BrokerInfoLocator
    private let launcher: any BrokerHelperLaunching
    private let homeDirectory: URL
    private let appVersion: String
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let upgradeRequester: any BrokerUpgradeRequesting
    private let rollingUpdatesEnabled: Bool
    private let retirementWaiter: (@Sendable (BrokerGenerationRecord, URL) async throws -> Void)?
    private var currentUpgradeState: BrokerUpgradeState = .unknown
    private var pendingUpgrade: PendingUpgrade?
    private var currentTopology: BrokerGenerationTopology?
    private var retirementSweepInFlight = false
    private var retirementSweepNumber: UInt64 = 0
    private var retirementQuarantines: [String: RetirementQuarantine] = [:]
    /// Exact generation identities whose staged packages were re-verified in
    /// this coordinator lifetime. Package verification hashes the complete
    /// helper (including Node), so retain the result for an unchanged broker
    /// identity instead of re-reading it on every inventory heartbeat.
    private var sealedLegacyAuthorizations: [String: BrokerInfo] = [:]

    private struct PendingUpgrade: Sendable {
        let info: BrokerInfo
        let package: BrokerHelperManifest
    }

    private struct RetirementQuarantine: Sendable {
        let info: BrokerInfo
        let failureCount: Int
        let reason: BrokerRetirementFailureReason
        let nextEligibleSweep: UInt64
    }

    init(
        locator: BrokerInfoLocator,
        launcher: any BrokerHelperLaunching,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "kaisola-native",
        upgradeRequester: any BrokerUpgradeRequesting = BrokerControlClient(),
        rollingUpdatesEnabled: Bool = BrokerRollingUpdatePolicy.clientRoutingEnabled,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        retirementWaiter: (@Sendable (BrokerGenerationRecord, URL) async throws -> Void)? = nil
    ) {
        self.locator = locator
        self.launcher = launcher
        self.homeDirectory = homeDirectory
        self.appVersion = appVersion
        self.upgradeRequester = upgradeRequester
        self.rollingUpdatesEnabled = rollingUpdatesEnabled
        self.sleep = sleep
        self.retirementWaiter = retirementWaiter
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
        let handoffClaim = try await acquireHandoffClaim()
        defer { handoffClaim.release() }
        return try await prepare(package: package)
    }

    private func prepare(package: BrokerHelperManifest) async throws -> BrokerInfo {
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

    private func acquireHandoffClaim() async throws -> BrokerGenerationHandoffClaim {
        let store = BrokerGenerationRegistryStore(
            profileRoot: locator.preferredUserDataRoot.standardizedFileURL
        )
        let started = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - started < Self.startupTimeoutNanoseconds {
            if let claim = try store.tryAcquireHandoffClaim(expectedRevision: nil) {
                return claim
            }
            try await sleep(60_000_000)
        }
        throw BrokerStartupError.timedOut(nil)
    }

    func upgradeState() -> BrokerUpgradeState {
        currentUpgradeState
    }

    func retirementDiagnostics() async -> [BrokerRetirementDiagnostic] {
        retirementQuarantines.map { generationID, quarantine in
            BrokerRetirementDiagnostic(
                generationID: generationID,
                pid: quarantine.info.pid,
                failureCount: quarantine.failureCount,
                reason: quarantine.reason,
                nextAttemptInSweeps: Int(
                    quarantine.nextEligibleSweep > retirementSweepNumber
                        ? quarantine.nextEligibleSweep - retirementSweepNumber
                        : 0
                )
            )
        }
        .sorted { $0.generationID < $1.generationID }
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
        let currentAuthorization = await upgradeAuthorization(for: topology.current)
        // `target` was re-verified immediately above, including its complete
        // staged file inventory and exact manifest-to-generation binding.
        sealedLegacyAuthorizations[target.id] = target.info
        let targetAuthorization = BrokerUpgradeAuthorization.sealedLegacyFallback

        let decision: BrokerUpgradeDecision
        do {
            decision = try await rolling.requestUpgrade(
                from: topology.current.info,
                targetContentDigest: target.id,
                authorization: currentAuthorization
            )
        } catch {
            throw BrokerRollbackError.unavailable
        }
        guard decision == .accepted else {
            switch decision {
            case .identityChanged, .preparedForOtherTarget:
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
                    targetContentDigest: topology.current.id,
                    authorization: targetAuthorization
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
                    targetContentDigest: target.id,
                    authorization: currentAuthorization
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
            let handoffClaim = try await acquireHandoffClaim()
            defer { handoffClaim.release() }
            let topology = try locator.locateTopology()
            // Another window, including v0.1.120 which does not honor our
            // claim, may have completed the handoff we observed earlier.
            // Reconcile the authoritative current instead of stranding this
            // window on the old generation or cancelling the winner.
            currentTopology = topology
            _ = try await reconcileLiveBroker(topology, package: pendingUpgrade.package)
        } catch BrokerStartupError.timedOut(_) {
            currentUpgradeState = .pending(
                fromContentDigest: currentTopology?.current.info.contentDigest
                    ?? pendingUpgrade.info.contentDigest,
                targetContentDigest: pendingUpgrade.package.contentDigest,
                reason: .shutdownTimedOut
            )
        } catch {
            currentUpgradeState = .pending(
                fromContentDigest: currentTopology?.current.info.contentDigest
                    ?? pendingUpgrade.info.contentDigest,
                targetContentDigest: pendingUpgrade.package.contentDigest,
                reason: .launchFailed
            )
        }
        return currentUpgradeState
    }

    private func retireEmptyDrainingGenerationIfPossible() async {
        guard !retirementSweepInFlight else { return }
        retirementSweepInFlight = true
        defer { retirementSweepInFlight = false }

        guard rollingUpdatesEnabled,
              let rolling = upgradeRequester as? any BrokerRollingUpdateRequesting,
              let topology = currentTopology ?? (try? locator.locateTopology()) else { return }
        let handoffStore = BrokerGenerationRegistryStore(
            profileRoot: locator.preferredUserDataRoot.standardizedFileURL
        )
        guard let handoffClaim = try? handoffStore.tryAcquireHandoffClaim(
            expectedRevision: nil
        ) else { return }
        defer { handoffClaim.release() }
        let store = BrokerGenerationRegistryStore(profileRoot: locator.preferredUserDataRoot)
        guard let registry = exactRetirementRegistry(matching: topology, store: store) else {
            return
        }
        let retainedRollbackID = registry.selection?.selectingAppContentDigest
        advanceRetirementSweep()
        let eligibleGenerations = Dictionary(uniqueKeysWithValues: topology.draining
            .filter { $0.id != retainedRollbackID }
            .map { ($0.id, $0.info) })
        retirementQuarantines = retirementQuarantines.filter { generationID, quarantine in
            eligibleGenerations[generationID] == quarantine.info
        }
        // Every non-rollback drain is a candidate, not only the first: the
        // broker itself is the emptiness authority (a populated or still-
        // connected drain answers `pending`), and a populated drain that
        // sorts first would otherwise starve the empty generations behind it
        // of retirement on every heartbeat — the 2026-08-07 stuck-typing
        // incident kept two empty drains pinned in the registry exactly this
        // way. At most one retirement is committed per heartbeat.
        for draining in topology.draining where draining.id != retainedRollbackID {
            if let quarantine = retirementQuarantines[draining.id],
               quarantine.info == draining.info,
               retirementSweepNumber < quarantine.nextEligibleSweep {
                continue
            }
            let authorization = await upgradeAuthorization(for: draining)
            let decision: BrokerRetirementDecision
            do {
                decision = try await rolling.requestRetirement(
                    of: draining.info,
                    targetContentDigest: topology.current.id,
                    authorization: authorization
                )
            } catch {
                if error is CancellationError { return }
                guard exactRetirementRegistry(matching: topology, store: store) != nil else {
                    return
                }
                let reason: BrokerRetirementFailureReason
                if let clientError = error as? BrokerClientError,
                   clientError == .identityChanged {
                    reason = .identityChanged
                } else {
                    reason = .requestUnavailable
                }
                quarantine(draining, reason: reason)
                continue
            }
            // The request is an actor suspension point. Do not use a decision
            // from an earlier ownership epoch after any registry mutation.
            guard exactRetirementRegistry(matching: topology, store: store) != nil else {
                return
            }
            switch decision {
            case .accepted:
                break
            case .deferred:
                retirementQuarantines.removeValue(forKey: draining.id)
                continue
            case .identityChanged:
                quarantine(draining, reason: .identityChanged)
                continue
            }
            do {
                if let retirementWaiter {
                    try await retirementWaiter(draining, locator.preferredUserDataRoot)
                } else {
                    try await waitForRetirement(
                        of: draining,
                        profileRoot: locator.preferredUserDataRoot
                    )
                }
            } catch {
                if error is CancellationError { return }
                guard exactRetirementRegistry(matching: topology, store: store) != nil else {
                    return
                }
                let reason: BrokerRetirementFailureReason
                if let startupError = error as? BrokerStartupError,
                   case .timedOut = startupError {
                    reason = .shutdownTimedOut
                } else {
                    reason = .requestUnavailable
                }
                quarantine(
                    draining,
                    reason: reason
                )
                continue
            }

            // Waiting crosses an actor suspension point. Re-read the complete
            // validated registry and require the exact topology, current
            // generation, and candidate identity observed before the request.
            // Any concurrent registry change fails closed for this sweep.
            guard let latestRegistry = exactRetirementRegistry(
                matching: topology,
                store: store
            ), latestRegistry.generations.contains(draining) else {
                return
            }
            let retained = latestRegistry.generations.filter { $0.id != draining.id }
            guard let next = try? store.save(
                currentGenerationID: topology.current.id,
                generations: retained,
                expectedRevision: latestRegistry.revision,
                selection: latestRegistry.selection
            ) else {
                currentTopology = (try? store.load())?.topology
                return
            }
            retirementQuarantines.removeValue(forKey: draining.id)
            currentTopology = next.topology
            // Registry removal is the authority boundary. Log cleanup is
            // best-effort afterward and must never turn a committed retirement
            // into a misleading quarantine/retry of the removed generation.
            try? garbageCollectRetiredMetadata(draining, store: store)
            return
        }
    }

    private func exactRetirementRegistry(
        matching topology: BrokerGenerationTopology,
        store: BrokerGenerationRegistryStore
    ) -> BrokerGenerationRegistry? {
        guard let registry = try? store.load() else {
            currentTopology = nil
            return nil
        }
        guard registry.topology == topology,
              registry.currentGenerationID == topology.current.id else {
            currentTopology = registry.topology
            return nil
        }
        return registry
    }

    private func advanceRetirementSweep() {
        if retirementSweepNumber == UInt64.max {
            retirementSweepNumber = 1
            retirementQuarantines.removeAll()
        } else {
            retirementSweepNumber += 1
        }
    }

    private func quarantine(
        _ generation: BrokerGenerationRecord,
        reason: BrokerRetirementFailureReason
    ) {
        let priorFailures = retirementQuarantines[generation.id]
            .flatMap { $0.info == generation.info ? $0.failureCount : nil } ?? 0
        let failureCount = min(priorFailures + 1, 32)
        let exponent = min(failureCount - 1, 3)
        let backoff = min(
            UInt64(2) << UInt64(exponent),
            Self.maximumRetirementBackoffSweeps
        )
        let nextEligibleSweep = retirementSweepNumber > UInt64.max - backoff
            ? UInt64.max
            : retirementSweepNumber + backoff
        retirementQuarantines[generation.id] = RetirementQuarantine(
            info: generation.info,
            failureCount: failureCount,
            reason: reason,
            nextEligibleSweep: nextEligibleSweep
        )
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
        // Discovery already authenticated this complete topology. Publish it
        // to routing consumers even when the following upgrade decision waits
        // or fails, so retained terminal IDs never lose their drain routes.
        currentTopology = topology
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

        let decision: BrokerUpgradeDecision
        let authorization = await upgradeAuthorization(for: topology.current)
        do {
            decision = try await upgradeRequester.requestUpgrade(
                from: info,
                targetContentDigest: package.contentDigest,
                authorization: authorization
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
            // Identity can change after status but before the lifecycle
            // mutation when an older coordinator prepares or publishes. Keep
            // retrying discovery so this window follows the authoritative
            // registry instead of remaining connected to a draining broker.
            currentUpgradeState = .pending(
                fromContentDigest: runningDigest,
                targetContentDigest: package.contentDigest,
                reason: .identityChanged
            )
            return info
        case .preparedForOtherTarget:
            // A previous-version window may still own this handoff. Preserve
            // our retry so the heartbeat can follow its eventual registry
            // publication without mutating the prepared target.
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
            if supportsRolling {
                do {
                    // Commit the old generation's authenticated stability
                    // window before starting a candidate. Besides avoiding
                    // useless detached-process churn when administration is
                    // incompatible, that means every launched target has a
                    // verified old-generation handoff waiting for it. The old
                    // broker rejects only *new* creates while this short launch
                    // completes; its PTYs and existing routes stay live.
                    let preparedReplacement = try await launchGeneration(package)
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
                    // A window from the previous app version does not know the
                    // handoff claim. If it published this exact candidate while
                    // we were launching it, the registry CAS legitimately
                    // loses. Adopt that winner and never cancel its handoff.
                    if let winner = await verifiedPublishedWinner(matching: package) {
                        pendingUpgrade = nil
                        currentUpgradeState = .current(contentDigest: package.contentDigest)
                        currentTopology = winner
                        return winner.current.info
                    }
                    // An older coordinator does not honor our handoff claim
                    // and can prepare this same digest between status and our
                    // request. Without a broker-issued owner nonce, registry
                    // equality cannot prove the accepted prepare was ours, so
                    // launch failure must remain fail-closed and never cancel.
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
               adopted.contentDigest == package.contentDigest,
               adopted.isProcessAlive {
                try await verifyStagedPackage(package)
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

    private func verifiedPublishedWinner(
        matching package: BrokerHelperManifest
    ) async -> BrokerGenerationTopology? {
        guard let winner = try? locator.locateTopology(),
              winner.current.id == package.contentDigest,
              winner.current.info.contentDigest == package.contentDigest,
              winner.current.info.packageVersion == package.packageVersion,
              winner.current.info.packageSchema == package.schemaVersion,
              winner.current.info.implementationVersion
                == package.brokerImplementationVersion,
              winner.current.info.isProcessAlive,
              (try? await verifyStagedPackage(package)) != nil else {
            return nil
        }
        return winner
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

    /// A pre-administrator broker may use its legacy lifecycle lane only after
    /// its complete staged helper package independently matches the exact live
    /// generation selected from the private registry. Unsealed legacy
    /// rendezvous and tampered/missing generation packages remain dedicated-
    /// role only and therefore fail closed on old peers.
    private func upgradeAuthorization(
        for generation: BrokerGenerationRecord
    ) async -> BrokerUpgradeAuthorization {
        if sealedLegacyAuthorizations[generation.id] == generation.info {
            return .sealedLegacyFallback
        }
        guard let packageRoot = generation.packageRoot,
              let verified = try? await launcher.verifiedStagedPackage(
                  at: URL(fileURLWithPath: packageRoot, isDirectory: true)
              ),
              Self.packageManifest(verified.manifest, exactlyMatches: generation) else {
            sealedLegacyAuthorizations.removeValue(forKey: generation.id)
            return .dedicatedOnly
        }
        sealedLegacyAuthorizations[generation.id] = generation.info
        return .sealedLegacyFallback
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
            maximumLiveTerminals: BrokerLaunchConfiguration.defaultMaximumLiveTerminals,
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
                      topology.draining.allSatisfy({ $0.id != record.id }),
                      registryCurrentIsReplaceable(
                          topology.current,
                          by: record,
                          store: store
                      ) {
                // Replace only the gone current; every draining generation
                // keeps its registration, its terminals, and its rollback
                // eligibility. An explicit selection cannot outlive the
                // generation it named, so it is dropped with it.
                _ = try store.save(
                    currentGenerationID: record.id,
                    generations: [record] + topology.draining,
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

    /// True when the registry's recorded current generation is adoptable by no
    /// client, so a freshly launched `record` may take its place. Covers the
    /// routine gap where an empty current broker self-exited and removed its
    /// own rendezvous while older generations still drain live terminals
    /// (metadata absent — the exact state `locateTopology` reports as
    /// `notRunning`), and the relaunch of the same sealed digest whose
    /// rendezvous now names the replacement. A live published current, or
    /// metadata that agrees with neither identity, stays refused.
    private func registryCurrentIsReplaceable(
        _ current: BrokerGenerationRecord,
        by record: BrokerGenerationRecord,
        store: BrokerGenerationRegistryStore
    ) -> Bool {
        var metadataStat = stat()
        if lstat(store.metadataURL(for: current).path, &metadataStat) != 0,
           errno == ENOENT {
            return true
        }
        guard current.id == record.id, !current.info.isProcessAlive else {
            return false
        }
        let published = try? locator.locateGenerationMetadata(
            contentDigest: current.id,
            validateSocket: false
        )
        return published == record.info
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
