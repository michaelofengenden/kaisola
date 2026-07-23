import Darwin
import CryptoKit
import Foundation
import KaisolaBrokerProtocol

struct BrokerInfo: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let securityEpoch: Int
    let implementationVersion: Int?
    let packageSchema: Int?
    let packageVersion: String?
    let pid: Int32
    let socketPath: String
    let token: String
    let startedAt: Int64
    let version: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case securityEpoch, implementationVersion, packageSchema, packageVersion
        case pid, socketPath, token, startedAt, version
    }

    init(
        protocolVersion: Int,
        securityEpoch: Int,
        implementationVersion: Int? = nil,
        packageSchema: Int? = nil,
        packageVersion: String? = nil,
        pid: Int32,
        socketPath: String,
        token: String,
        startedAt: Int64,
        version: String
    ) {
        self.protocolVersion = protocolVersion
        self.securityEpoch = securityEpoch
        self.implementationVersion = implementationVersion
        self.packageSchema = packageSchema
        self.packageVersion = packageVersion
        self.pid = pid
        self.socketPath = socketPath
        self.token = token
        self.startedAt = startedAt
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        securityEpoch = try values.decode(Int.self, forKey: .securityEpoch)
        implementationVersion = try values.decodeIfPresent(Int.self, forKey: .implementationVersion)
        packageSchema = try values.decodeIfPresent(Int.self, forKey: .packageSchema)
        packageVersion = try values.decodeIfPresent(String.self, forKey: .packageVersion)
        pid = try values.decode(Int32.self, forKey: .pid)
        socketPath = try values.decode(String.self, forKey: .socketPath)
        token = try values.decode(String.self, forKey: .token)
        startedAt = try values.decode(Int64.self, forKey: .startedAt)
        version = try values.decode(String.self, forKey: .version)
    }

    func validate() throws {
        guard protocolVersion == BrokerWire.protocolVersion else {
            throw BrokerDiscoveryError.unsupportedProtocol(protocolVersion)
        }
        guard securityEpoch == BrokerWire.securityEpoch else {
            throw BrokerDiscoveryError.unsupportedSecurityEpoch
        }
        guard BrokerWire.accepts(
            protocolVersion: protocolVersion,
            securityEpoch: securityEpoch,
            implementationVersion: implementationVersion
        ) else {
            throw BrokerDiscoveryError.unsupportedImplementation(implementationVersion ?? 1)
        }
        guard pid > 1 else { throw BrokerDiscoveryError.invalidMetadata }
        guard socketPath.hasPrefix("/"), !socketPath.contains("\0") else {
            throw BrokerDiscoveryError.invalidMetadata
        }
        guard token.count == 64, token.allSatisfy(\.isHexDigit) else {
            throw BrokerDiscoveryError.invalidMetadata
        }
    }

    /// A non-secret, stable scope for native resume cursors. The broker token
    /// is random and changes with a replacement broker, so hashing it keeps a
    /// cursor from one PTY owner from ever being replayed against another.
    var persistenceIdentity: String {
        let material = [
            String(protocolVersion),
            String(securityEpoch),
            String(pid),
            String(startedAt),
            socketPath,
            token,
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var isProcessAlive: Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

protocol BrokerInfoLocating: Sendable {
    func locate() throws -> BrokerInfo
}

struct BrokerInfoLocator: BrokerInfoLocating, Sendable {
    enum PreviewProfile: String, Sendable {
        case native
        case development
        case installed
    }

    static let installedProfileNames = ["pasola", "Pasola", "Kiasola", "Kaisola"]
    static let developmentProfileName = "Kaisola Dev"
    /// The native app's OWN broker profile — used when Electron's broker exists
    /// but predates the features the native app needs. Fully separate: nothing
    /// under an Electron profile is read or written, and Electron's broker (and
    /// every session on it) is left untouched.
    static let nativeOwnProfileName = "Kaisola Native"
    static let maximumMetadataBytes: off_t = 64 * 1_024

    /// Debug previews opened from Finder/Spotlight cannot inherit the launch
    /// script's environment. Point them directly at the native-only broker so
    /// a direct launch and the canonical launcher see the same durable PTYs.
    /// Signed releases retain installed-profile discovery + native fallback.
    static var defaultPreviewProfile: PreviewProfile {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["KAISOLA_NATIVE_BROKER_PROFILE"],
           let profile = PreviewProfile(rawValue: explicit) {
            return profile
        }
        // Backward compatibility for older development launcher scripts.
        if environment["KAISOLA_NATIVE_USE_DEV_PROFILE"] == "1" {
            return .development
        }
        #if DEBUG
        return .native
        #else
        return .installed
        #endif
    }

    let userDataCandidates: [URL]
    let currentUserID: uid_t

    init(userDataCandidates: [URL], currentUserID: uid_t = getuid()) {
        self.userDataCandidates = userDataCandidates
        self.currentUserID = currentUserID
    }

    static func live(
        fileManager: FileManager = .default,
        developmentProfile: Bool = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_USE_DEV_PROFILE"] == "1"
    ) -> BrokerInfoLocator {
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        // Electron deliberately keeps the first historical profile it finds.
        // Reading the same ordered set preserves running sessions across names
        // without ever pointing native state at Electron's database.
        let profileNames = developmentProfile ? [developmentProfileName] : installedProfileNames
        return BrokerInfoLocator(
            userDataCandidates: profileNames.map {
                support.appendingPathComponent($0, isDirectory: true)
            }
        )
    }

    /// Profile routing for the native UI. A clean-room development broker stays
    /// explicitly available without making ordinary Debug launches fork state.
    static func preview(
        fileManager: FileManager = .default,
        profile: PreviewProfile = BrokerInfoLocator.defaultPreviewProfile
    ) -> BrokerInfoLocator {
        switch profile {
        case .native:
            nativeOwn(fileManager: fileManager)
        case .development:
            live(fileManager: fileManager, developmentProfile: true)
        case .installed:
            live(fileManager: fileManager, developmentProfile: false)
        }
    }

    /// Locator for the native app's own separate broker profile.
    static func nativeOwn(fileManager: FileManager = .default) -> BrokerInfoLocator {
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return BrokerInfoLocator(
            userDataCandidates: [support.appendingPathComponent(nativeOwnProfileName, isDirectory: true)]
        )
    }

    func locate() throws -> BrokerInfo {
        try locateMetadata(validateSocket: true)
    }

    var preferredUserDataRoot: URL {
        userDataCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) ?? userDataCandidates.last ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func locateMetadata(validateSocket: Bool) throws -> BrokerInfo {
        guard let root = userDataCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { throw BrokerDiscoveryError.notRunning }

        // Electron chooses the oldest existing profile directory first, even
        // when it currently has no broker. Never fall through to a newer stale
        // profile merely because it happens to contain old metadata.
        try validatePrivatePath(root, expectedKind: S_IFDIR)
        let brokerDirectory = root.appendingPathComponent("session-broker", isDirectory: true)
        let infoURL = brokerDirectory.appendingPathComponent("broker.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            throw BrokerDiscoveryError.notRunning
        }

        try validatePrivatePath(brokerDirectory, expectedKind: S_IFDIR)
        let metadataStat = try validatePrivatePath(infoURL, expectedKind: S_IFREG)
        guard metadataStat.st_size > 0, metadataStat.st_size <= Self.maximumMetadataBytes else {
            throw BrokerDiscoveryError.invalidMetadata
        }
        let data = try Data(contentsOf: infoURL)
        let info: BrokerInfo
        do {
            info = try JSONDecoder().decode(BrokerInfo.self, from: data)
            try info.validate()
        } catch let error as BrokerDiscoveryError {
            throw error
        } catch {
            throw BrokerDiscoveryError.invalidMetadata
        }
        if validateSocket {
            try validatePrivatePath(URL(fileURLWithPath: info.socketPath), expectedKind: S_IFSOCK)
        }
        return info
    }

    @discardableResult
    private func validatePrivatePath(_ url: URL, expectedKind: mode_t) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw BrokerDiscoveryError.privateEndpointUnavailable
        }
        guard value.st_uid == currentUserID,
              value.st_mode & S_IFMT == expectedKind,
              value.st_mode & 0o077 == 0 else {
            throw BrokerDiscoveryError.unsafePermissions
        }
        return value
    }
}

enum BrokerDiscoveryError: Error, Equatable, LocalizedError {
    case notRunning
    case privateEndpointUnavailable
    case unsafePermissions
    case invalidMetadata
    case unsupportedProtocol(Int)
    case unsupportedSecurityEpoch
    case unsupportedImplementation(Int)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "Open the Electron Kaisola app once so its durable terminal broker can be discovered."
        case .privateEndpointUnavailable:
            "The broker is republishing its private socket. Try reconnecting in a moment."
        case .unsafePermissions:
            "The broker endpoint was refused because it is not private to this macOS user."
        case let .unsupportedProtocol(version):
            "The running broker uses protocol \(version), which this preview will not replace or terminate."
        case .unsupportedSecurityEpoch:
            "The running broker does not provide project-scoped terminal isolation."
        case let .unsupportedImplementation(version):
            "The running broker implementation \(version) is outside this preview's compatibility window and was left untouched."
        case .invalidMetadata:
            "The broker rendezvous metadata is invalid. No terminal process was changed."
        }
    }
}
