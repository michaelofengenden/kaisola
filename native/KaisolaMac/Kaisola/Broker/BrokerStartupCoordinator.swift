import CryptoKit
import Darwin
import Foundation
import KaisolaBrokerProtocol
import Security

protocol BrokerInfoPreparing: Sendable {
    func prepare() async throws -> BrokerInfo
}

struct LocatedBrokerInfoPreparer: BrokerInfoPreparing {
    let locator: any BrokerInfoLocating

    func prepare() async throws -> BrokerInfo {
        try locator.locate()
    }
}

actor BrokerStartupCoordinator: BrokerInfoPreparing {
    private static let maximumSocketPathBytes = 100
    private static let startupTimeoutNanoseconds: UInt64 = 8_000_000_000

    private let locator: BrokerInfoLocator
    private let launcher: any BrokerHelperLaunching
    private let homeDirectory: URL
    private let appVersion: String
    private let sleep: @Sendable (UInt64) async throws -> Void

    init(
        locator: BrokerInfoLocator,
        launcher: any BrokerHelperLaunching,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "native-preview",
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.locator = locator
        self.launcher = launcher
        self.homeDirectory = homeDirectory
        self.appVersion = appVersion
        self.sleep = sleep
    }

    static func live() -> BrokerStartupCoordinator {
        BrokerStartupCoordinator(
            locator: .preview(),
            launcher: BrokerBootstrapClient()
        )
    }

    func prepare() async throws -> BrokerInfo {
        do {
            return try locator.locate()
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

        let package = try await launcher.packageManifest()
        let launchURL = try writeLaunchConfiguration(package: package)
        defer { try? FileManager.default.removeItem(at: launchURL) }
        _ = try await launcher.launch(configurationURL: launchURL)

        let started = DispatchTime.now().uptimeNanoseconds
        var lastError: (any Error)?
        while DispatchTime.now().uptimeNanoseconds - started < Self.startupTimeoutNanoseconds {
            do {
                return try locator.locate()
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
