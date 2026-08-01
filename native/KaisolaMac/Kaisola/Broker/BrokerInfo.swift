import Darwin
import CryptoKit
import Foundation
import KaisolaBrokerProtocol

struct BrokerInfo: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let securityEpoch: Int
    let implementationVersion: Int?
    let packageSchema: Int?
    let packageVersion: String?
    let contentDigest: String?
    let pid: Int32
    let socketPath: String
    let token: String
    let startedAt: Int64
    let version: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case securityEpoch, implementationVersion, packageSchema, packageVersion, contentDigest
        case pid, socketPath, token, startedAt, version
    }

    init(
        protocolVersion: Int,
        securityEpoch: Int,
        implementationVersion: Int? = nil,
        packageSchema: Int? = nil,
        packageVersion: String? = nil,
        contentDigest: String? = nil,
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
        self.contentDigest = contentDigest
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
        contentDigest = try values.decodeIfPresent(String.self, forKey: .contentDigest)
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
        if let contentDigest,
           !BrokerHelperPackageVerification.isLowercaseSHA256(contentDigest) {
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

protocol BrokerTopologyLocating: BrokerInfoLocating {
    func locateTopology(validateSockets: Bool) throws -> BrokerGenerationTopology
}

/// A deliberately narrow launch contract for paired native/Electron resource
/// measurements. The normal app never consults this root: only an explicitly
/// named workload may route its broker and fixture state beneath the caller's
/// private temporary directory.
struct NativeResourceWorkloadConfiguration: Equatable, Sendable {
    static let idleID = "one-window-idle-terminal-fresh-broker"
    static let streamingID = "one-window-streaming-terminal-fresh-broker"
    static let restoredWindowsID = "three-restored-project-windows-fresh-broker"
    static let supportedIDs: Set<String> = [idleID, streamingID, restoredWindowsID]

    let workloadID: String
    let root: URL

    var brokerUserDataRoot: URL {
        root.appendingPathComponent("broker-profile", isDirectory: true)
    }

    var appStateRoot: URL {
        root.appendingPathComponent("app-state", isDirectory: true)
    }

    var workspaceRoot: URL {
        root.appendingPathComponent("workspace", isDirectory: true)
    }

    var restoredWorkspaceRoots: [URL] {
        (1...3).map { index in
            root.appendingPathComponent("workspace-\(index)", isDirectory: true)
        }
    }

    var expectedWindowCount: Int {
        workloadID == Self.restoredWindowsID ? 3 : 1
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> NativeResourceWorkloadConfiguration? {
        guard let workloadID = environment["KAISOLA_NATIVE_RESOURCE_WORKLOAD"],
              supportedIDs.contains(workloadID),
              let rawRoot = environment["KAISOLA_NATIVE_RESOURCE_ROOT"],
              rawRoot.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let temporary = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(temporary.path + "/") else { return nil }
        return NativeResourceWorkloadConfiguration(workloadID: workloadID, root: root)
    }
}

struct BrokerInfoLocator: BrokerTopologyLocating, Sendable {
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

    /// Every ordinary preview launch uses the native-only broker. Historical
    /// Electron discovery remains available only through an explicit profile
    /// override while the old app is still being archived.
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
        return .native
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
        try locateTopology(validateSockets: true).current.info
    }

    var preferredUserDataRoot: URL {
        userDataCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) ?? userDataCandidates.last ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func locateMetadata(validateSocket: Bool) throws -> BrokerInfo {
        try locateTopology(validateSockets: validateSocket).current.info
    }

    /// Resolves the atomic generation registry when present and otherwise
    /// preserves the pre-registry single-broker discovery contract. Registry
    /// metadata is cross-checked against each generation's independently
    /// published identity before any socket is adopted.
    func locateTopology(validateSockets: Bool = true) throws -> BrokerGenerationTopology {
        guard let root = userDataCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { throw BrokerDiscoveryError.notRunning }

        // Electron chooses the oldest existing profile directory first, even
        // when it currently has no broker. Never fall through to a newer stale
        // profile merely because it happens to contain old metadata.
        try validatePrivatePath(root, expectedKind: S_IFDIR)
        let brokerDirectory = root.appendingPathComponent("session-broker", isDirectory: true)
        var brokerDirectoryStat = stat()
        guard lstat(brokerDirectory.path, &brokerDirectoryStat) == 0 else {
            if errno == ENOENT { throw BrokerDiscoveryError.notRunning }
            throw BrokerDiscoveryError.privateEndpointUnavailable
        }
        try validatePrivatePath(brokerDirectory, expectedKind: S_IFDIR)

        let store = BrokerGenerationRegistryStore(
            profileRoot: root,
            currentUserID: currentUserID
        )
        var registryStat = stat()
        if lstat(store.registryURL.path, &registryStat) == 0 {
            let registry: BrokerGenerationRegistry
            do { registry = try store.load() }
            catch { throw BrokerDiscoveryError.invalidRegistry }
            guard let topology = registry.topology else {
                throw BrokerDiscoveryError.invalidRegistry
            }
            var socketPaths = Set<String>()
            for generation in topology.all {
                let published: BrokerInfo
                do {
                    published = try readMetadata(at: store.metadataURL(for: generation))
                } catch {
                    // The registry is published only after generation metadata.
                    // A missing, swapped, or unreadable identity therefore
                    // represents an incomplete/tampered topology, not a
                    // discoverable broker that callers may safely adopt.
                    throw BrokerDiscoveryError.invalidRegistry
                }
                guard published == generation.info,
                      socketPaths.insert(published.socketPath).inserted else {
                    throw BrokerDiscoveryError.invalidRegistry
                }
                if validateSockets {
                    try validatePrivatePath(
                        URL(fileURLWithPath: published.socketPath),
                        expectedKind: S_IFSOCK
                    )
                }
            }
            return topology
        }
        guard errno == ENOENT else { throw BrokerDiscoveryError.invalidRegistry }

        let infoURL = brokerDirectory.appendingPathComponent("broker.json", isDirectory: false)
        var legacyStat = stat()
        guard lstat(infoURL.path, &legacyStat) == 0 else {
            if errno != ENOENT { throw BrokerDiscoveryError.privateEndpointUnavailable }
            throw BrokerDiscoveryError.notRunning
        }
        let info = try readMetadata(at: infoURL)
        if validateSockets {
            try validatePrivatePath(URL(fileURLWithPath: info.socketPath), expectedKind: S_IFSOCK)
        }
        return .single(info)
    }

    func locateGenerationMetadata(
        contentDigest: String,
        validateSocket: Bool = true
    ) throws -> BrokerInfo {
        guard BrokerHelperPackageVerification.isLowercaseSHA256(contentDigest),
              let root = userDataCandidates.first(where: {
                  FileManager.default.fileExists(atPath: $0.path)
              }) else {
            throw BrokerDiscoveryError.notRunning
        }
        try validatePrivatePath(root, expectedKind: S_IFDIR)
        let brokerDirectory = root.appendingPathComponent("session-broker", isDirectory: true)
        try validatePrivatePath(brokerDirectory, expectedKind: S_IFDIR)
        let metadataDirectory = brokerDirectory.appendingPathComponent(
            BrokerLaunchConfiguration.generationMetadataDirectoryName,
            isDirectory: true
        )
        try validatePrivatePath(metadataDirectory, expectedKind: S_IFDIR)
        let info = try readMetadata(
            at: metadataDirectory.appendingPathComponent("\(contentDigest).json")
        )
        guard info.contentDigest == contentDigest else {
            throw BrokerDiscoveryError.invalidMetadata
        }
        if validateSocket {
            try validatePrivatePath(
                URL(fileURLWithPath: info.socketPath),
                expectedKind: S_IFSOCK
            )
        }
        return info
    }

    private func readMetadata(at url: URL) throws -> BrokerInfo {
        let metadata = try validatePrivatePath(url, expectedKind: S_IFREG)
        guard metadata.st_size > 0, metadata.st_size <= Self.maximumMetadataBytes else {
            throw BrokerDiscoveryError.invalidMetadata
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BrokerDiscoveryError.privateEndpointUnavailable }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_uid == currentUserID,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_mode & 0o077 == 0,
              opened.st_size > 0,
              opened.st_size <= Self.maximumMetadataBytes else {
            throw BrokerDiscoveryError.unsafePermissions
        }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw BrokerDiscoveryError.invalidMetadata }
            if count == 0 { break }
            guard data.count <= Int(Self.maximumMetadataBytes) - count else {
                throw BrokerDiscoveryError.invalidMetadata
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        do {
            let info = try JSONDecoder().decode(BrokerInfo.self, from: data)
            try info.validate()
            return info
        } catch let error as BrokerDiscoveryError {
            throw error
        } catch {
            throw BrokerDiscoveryError.invalidMetadata
        }
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
    case invalidRegistry
    case unsupportedProtocol(Int)
    case unsupportedSecurityEpoch
    case unsupportedImplementation(Int)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "Kaisola's native terminal service is not running. Reconnect to start it again."
        case .privateEndpointUnavailable:
            "Saved sessions are reopening their private connection. Try reconnecting in a moment."
        case .unsafePermissions:
            "The terminal connection was refused because it is not private to this macOS user."
        case let .unsupportedProtocol(version):
            "The running session service uses an incompatible version (\(version)) and was left untouched."
        case .unsupportedSecurityEpoch:
            "The running session service does not provide project-scoped terminal isolation."
        case let .unsupportedImplementation(version):
            "The running session service version \(version) is incompatible with this version of Kaisola and was left untouched."
        case .invalidMetadata:
            "Saved terminal connection information is invalid. No terminal process was changed."
        case .invalidRegistry:
            "The saved terminal-generation registry is invalid. No terminal process was changed."
        }
    }
}
