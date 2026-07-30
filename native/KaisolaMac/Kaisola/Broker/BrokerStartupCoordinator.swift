import CryptoKit
import Darwin
import Foundation
import KaisolaBrokerProtocol
import Security

protocol BrokerInfoPreparing: Sendable {
    func prepare() async throws -> BrokerInfo
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
            "Broker helper identity has not been checked."
        case let .current(contentDigest):
            "Broker helper is current · content \(contentDigest)."
        case let .checking(fromContentDigest, targetContentDigest):
            "Checking broker helper update \(Self.transition(fromContentDigest, targetContentDigest)) safely."
        case let .pending(from, target, .liveWork(blockers)):
            "Broker update pending \(Self.transition(from, target)): \(blockers.liveTerminalCount) live terminal(s), \(blockers.busyAgentCount) working agent(s), \(blockers.childTaskCount) child task(s)."
        case let .pending(from, target, .legacyIdentityUnavailable):
            "Broker update pending \(Self.transition(from, target)): this older broker cannot prove an atomic safe shutdown."
        case let .pending(from, target, .identityChanged):
            "Broker update pending \(Self.transition(from, target)): the live broker identity changed during the safety check."
        case let .pending(from, target, .requestUnavailable):
            "Broker update pending \(Self.transition(from, target)): the live broker does not support sealed safe promotion."
        case let .pending(from, target, .shutdownTimedOut):
            "Broker update pending \(Self.transition(from, target)): the old helper did not finish its safe shutdown."
        case let .pending(from, target, .launchFailed):
            "Broker update pending \(Self.transition(from, target)): the replacement helper could not be started yet."
        case let .updating(fromContentDigest, targetContentDigest):
            "Broker helper is updating \(Self.transition(fromContentDigest, targetContentDigest)); no terminal processes are being interrupted."
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
    case identityChanged
}

protocol BrokerUpgradeRequesting: Sendable {
    func requestUpgrade(
        from info: BrokerInfo,
        targetContentDigest: String
    ) async throws -> BrokerUpgradeDecision
}

protocol BrokerUpgradeMonitoring: Sendable {
    func upgradeState() async -> BrokerUpgradeState
    func attemptUpgradeIfNeeded() async -> BrokerUpgradeState
}

struct LocatedBrokerInfoPreparer: BrokerInfoPreparing {
    let locator: any BrokerInfoLocating

    func prepare() async throws -> BrokerInfo {
        try locator.locate()
    }
}

actor BrokerStartupCoordinator: BrokerInfoPreparing, BrokerUpgradeMonitoring {
    private static let maximumSocketPathBytes = 100
    private static let startupTimeoutNanoseconds: UInt64 = 8_000_000_000

    private let locator: BrokerInfoLocator
    private let launcher: any BrokerHelperLaunching
    private let homeDirectory: URL
    private let appVersion: String
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let upgradeRequester: any BrokerUpgradeRequesting
    private var currentUpgradeState: BrokerUpgradeState = .unknown
    private var pendingUpgrade: PendingUpgrade?

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
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.locator = locator
        self.launcher = launcher
        self.homeDirectory = homeDirectory
        self.appVersion = appVersion
        self.upgradeRequester = upgradeRequester
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
            let info = try locator.locate()
            // A socket vnode can survive its detached broker. Treating that
            // stale file as a live endpoint makes every connection fail with
            // ECONNREFUSED and bypasses the safe relaunch path below.
            guard !info.isProcessAlive else {
                return try await reconcileLiveBroker(info, package: package)
            }
            try removeStaleRendezvous(info)
        } catch let error as BrokerDiscoveryError {
            switch error {
            case .notRunning:
                break
            case .privateEndpointUnavailable:
                let metadata = try locator.locateMetadata(validateSocket: false)
                guard !metadata.isProcessAlive else { throw error }
                try removeStaleRendezvous(metadata)
            default:
                // A live or ambiguous incompatible broker is never replaced.
                throw error
            }
        }

        return try await launchPackagedBroker(package)
    }

    func upgradeState() -> BrokerUpgradeState {
        currentUpgradeState
    }

    /// Called from the app's ordinary inventory heartbeat. A stale broker is
    /// retried only through its own atomic safety method; UI-observed quietness
    /// is never used as replacement authority.
    func attemptUpgradeIfNeeded() async -> BrokerUpgradeState {
        guard let pendingUpgrade else { return currentUpgradeState }
        do {
            _ = try await reconcileLiveBroker(
                pendingUpgrade.info,
                package: pendingUpgrade.package
            )
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

    private func reconcileLiveBroker(
        _ info: BrokerInfo,
        package: BrokerHelperManifest
    ) async throws -> BrokerInfo {
        let exactPackageIdentity = info.contentDigest == package.contentDigest
            && info.packageVersion == package.packageVersion
            && info.packageSchema == package.schemaVersion
            && info.implementationVersion == package.brokerImplementationVersion
        if exactPackageIdentity {
            pendingUpgrade = nil
            currentUpgradeState = .current(contentDigest: package.contentDigest)
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
            try await waitForSafeShutdown(of: info)
            let replacement = try await launchPackagedBroker(package)
            pendingUpgrade = nil
            currentUpgradeState = .current(contentDigest: package.contentDigest)
            return replacement
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
        let launchURL = try writeLaunchConfiguration(package: package)
        defer { try? FileManager.default.removeItem(at: launchURL) }
        do {
            _ = try await launcher.launch(configurationURL: launchURL)
        } catch {
            // Another Kaisola window may win the empty-broker launch race. Its
            // exact sealed digest is safe to adopt; any other identity is not.
            if let adopted = try? locator.locate(),
               adopted.contentDigest == package.contentDigest {
                pendingUpgrade = nil
                currentUpgradeState = .current(contentDigest: package.contentDigest)
                return adopted
            }
            throw error
        }

        let started = DispatchTime.now().uptimeNanoseconds
        var lastError: (any Error)?
        while DispatchTime.now().uptimeNanoseconds - started < Self.startupTimeoutNanoseconds {
            do {
                let info = try locator.locate()
                guard info.contentDigest == package.contentDigest else {
                    throw BrokerStartupError.rendezvousChanged
                }
                pendingUpgrade = nil
                currentUpgradeState = .current(contentDigest: package.contentDigest)
                return info
            } catch {
                lastError = error
                try await sleep(60_000_000)
            }
        }
        throw BrokerStartupError.timedOut(lastError?.localizedDescription)
    }

    private func writeLaunchConfiguration(package: BrokerHelperManifest) throws -> URL {
        let userData = locator.preferredUserDataRoot.standardizedFileURL
        try preparePrivateDirectory(userData)
        let brokerDirectory = userData.appendingPathComponent("session-broker", isDirectory: true)
        try preparePrivateDirectory(brokerDirectory)
        let socket = try socketPath(userData: userData)
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
            token: token,
            socketPath: socket,
            infoFile: brokerDirectory.appendingPathComponent("broker.json").path,
            lockFile: brokerDirectory.appendingPathComponent("broker.lock").path,
            storageDir: userData.appendingPathComponent("terminal-cache", isDirectory: true).path,
            logFile: brokerDirectory.appendingPathComponent("broker.log").path,
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

    private func socketPath(userData: URL) throws -> String {
        let durable = userData
            .appendingPathComponent("session-broker", isDirectory: true)
            .appendingPathComponent("broker.sock").path
        if durable.utf8.count <= Self.maximumSocketPathBytes { return durable }
        let digest = SHA256.hash(data: Data(userData.path.utf8))
            .prefix(9)
            .map { String(format: "%02x", $0) }
            .joined()
        let compact = homeDirectory
            .appendingPathComponent(".kaisola-session", isDirectory: true)
            .appendingPathComponent("\(digest).sock").path
        guard compact.utf8.count <= Self.maximumSocketPathBytes else {
            throw BrokerClientError.socketPathTooLong
        }
        return compact
    }

    private func removeStaleRendezvous(_ stale: BrokerInfo) throws {
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
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                if errno == ENOENT { continue }
                throw BrokerStartupError.unsafeStaleRendezvous
            }
            let allowedPath = url.deletingLastPathComponent() == brokerDirectory
                || url.deletingLastPathComponent() == homeDirectory.appendingPathComponent(".kaisola-session", isDirectory: true)
            let kind = value.st_mode & S_IFMT
            guard allowedPath,
                  value.st_uid == getuid(),
                  value.st_mode & 0o077 == 0,
                  (kind == S_IFREG || kind == S_IFSOCK) else {
                throw BrokerStartupError.unsafeStaleRendezvous
            }
            try FileManager.default.removeItem(at: url)
        }
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
            "A live terminal broker was left untouched."
        case .rendezvousChanged:
            "Another Kaisola process changed the broker rendezvous; reconnect to adopt it safely."
        case .unsafeStaleRendezvous:
            "Stale broker metadata was not removed because its path or permissions were unsafe."
        case .unsafeDirectory:
            "The broker support directory is not private to this macOS user."
        case .randomnessUnavailable:
            "A secure broker authentication token could not be generated."
        case .couldNotWriteLaunchRequest:
            "The private broker launch request could not be written safely."
        case .timedOut:
            "The standalone broker helper launched, but its private socket did not become ready."
        }
    }
}
