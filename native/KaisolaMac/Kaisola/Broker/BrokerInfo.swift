import Darwin
import CryptoKit
import Foundation
import KaisolaBrokerProtocol

struct BrokerInfo: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let securityEpoch: Int
    let pid: Int32
    let socketPath: String
    let token: String
    let startedAt: Int64
    let version: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case securityEpoch, pid, socketPath, token, startedAt, version
    }

    func validate() throws {
        guard protocolVersion == BrokerWire.protocolVersion else {
            throw BrokerDiscoveryError.unsupportedProtocol(protocolVersion)
        }
        guard securityEpoch == BrokerWire.securityEpoch else {
            throw BrokerDiscoveryError.unsupportedSecurityEpoch
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
}

protocol BrokerInfoLocating: Sendable {
    func locate() throws -> BrokerInfo
}

struct BrokerInfoLocator: BrokerInfoLocating, Sendable {
    static let installedProfileNames = ["pasola", "Pasola", "Kiasola", "Kaisola"]
    static let developmentProfileName = "Kaisola Dev"
    static let maximumMetadataBytes: off_t = 64 * 1_024

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

    func locate() throws -> BrokerInfo {
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
        try validatePrivatePath(URL(fileURLWithPath: info.socketPath), expectedKind: S_IFSOCK)
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
        case .invalidMetadata:
            "The broker rendezvous metadata is invalid. No terminal process was changed."
        }
    }
}
