import Darwin
import Foundation

enum BrokerGenerationRole: String, Codable, Equatable, Sendable {
    case current
    case draining
}

/// One authenticated broker rendezvous retained by the rolling-update
/// registry. The token remains private because the registry itself is 0600.
struct BrokerGenerationRecord: Codable, Equatable, Sendable {
    let id: String
    let role: BrokerGenerationRole
    let info: BrokerInfo
    /// Nil is accepted only for a draining generation adopted from the legacy
    /// single-rendezvous layout. Newly launched generations always point at an
    /// exact digest-addressed staged package.
    let packageRoot: String?
    let registeredAt: Int64
}

struct BrokerGenerationTopology: Equatable, Sendable {
    let current: BrokerGenerationRecord
    let draining: [BrokerGenerationRecord]
    /// Registry CAS revision that published this exact generation set. Legacy
    /// single-broker discovery derives a stable version from broker identity.
    let registryTopologyVersion: Int64

    init(
        current: BrokerGenerationRecord,
        draining: [BrokerGenerationRecord],
        registryTopologyVersion: Int64 = 1
    ) {
        self.current = current
        self.draining = draining
        self.registryTopologyVersion = registryTopologyVersion
    }

    var all: [BrokerGenerationRecord] { [current] + draining }

    static func single(_ info: BrokerInfo) -> BrokerGenerationTopology {
        let identifier = info.contentDigest ?? "legacy-\(info.persistenceIdentity)"
        return BrokerGenerationTopology(
            current: BrokerGenerationRecord(
                id: identifier,
                role: .current,
                info: info,
                packageRoot: nil,
                registeredAt: max(1, info.startedAt)
            ),
            draining: [],
            registryTopologyVersion: max(1, info.startedAt)
        )
    }
}

/// An explicit rollback choice is bound to the sealed package shipped by the
/// app that made it. Relaunches of that same app respect the choice; a later
/// app package gets a fresh upgrade opportunity instead of pinning an old
/// broker forever.
struct BrokerGenerationSelection: Codable, Equatable, Sendable {
    let generationID: String
    let selectingAppContentDigest: String
    let selectedAt: Int64
}

struct BrokerGenerationRegistry: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumGenerationCount = 8

    let schema: Int
    let revision: Int64
    let updatedAt: Int64
    let currentGenerationID: String
    let generations: [BrokerGenerationRecord]
    let selection: BrokerGenerationSelection?

    var topology: BrokerGenerationTopology? {
        guard let current = generations.first(where: { $0.id == currentGenerationID }) else {
            return nil
        }
        return BrokerGenerationTopology(
            current: current,
            draining: generations.filter { $0.id != currentGenerationID },
            registryTopologyVersion: revision
        )
    }

    func validate(profileRoot: URL) throws {
        guard schema == Self.schemaVersion,
              revision > 0,
              updatedAt > 0,
              !generations.isEmpty,
              generations.count <= Self.maximumGenerationCount,
              Set(generations.map(\.id)).count == generations.count,
              let topology else {
            throw BrokerGenerationRegistryError.invalidRegistry
        }
        let canonical = [topology.current] + topology.draining.sorted { $0.id < $1.id }
        guard canonical == generations,
              topology.current.role == .current,
              topology.current.packageRoot != nil,
              topology.draining.allSatisfy({ $0.role == .draining }) else {
            throw BrokerGenerationRegistryError.invalidRegistry
        }
        if let selection {
            guard selection.generationID == currentGenerationID,
                  BrokerHelperPackageVerification.isLowercaseSHA256(
                      selection.selectingAppContentDigest
                  ),
                  selection.selectedAt > 0 else {
                throw BrokerGenerationRegistryError.invalidRegistry
            }
        }

        let standardizedProfile = profileRoot.standardizedFileURL
        for generation in generations {
            guard BrokerHelperPackageVerification.isLowercaseSHA256(generation.id),
                  generation.registeredAt > 0,
                  generation.info.contentDigest == generation.id else {
                throw BrokerGenerationRegistryError.invalidRegistry
            }
            do { try generation.info.validate() }
            catch { throw BrokerGenerationRegistryError.invalidRegistry }

            if let packageRoot = generation.packageRoot {
                let expected = standardizedProfile
                    .appendingPathComponent("broker-generations", isDirectory: true)
                    .appendingPathComponent(generation.id, isDirectory: true)
                    .standardizedFileURL
                guard URL(fileURLWithPath: packageRoot, isDirectory: true).standardizedFileURL
                    == expected else {
                    throw BrokerGenerationRegistryError.invalidRegistry
                }
                let socketLeaf = BrokerLaunchConfiguration.generationSocketLeaf(
                    userData: standardizedProfile,
                    contentDigest: generation.id
                )
                let durableSocket = standardizedProfile
                    .appendingPathComponent("session-broker", isDirectory: true)
                    .appendingPathComponent(socketLeaf, isDirectory: false)
                    .standardizedFileURL
                let publishedSocket = URL(fileURLWithPath: generation.info.socketPath)
                    .standardizedFileURL
                let compactSocket = publishedSocket.lastPathComponent == socketLeaf
                    && publishedSocket.deletingLastPathComponent().lastPathComponent
                        == ".kaisola-session"
                guard publishedSocket == durableSocket || compactSocket else {
                    throw BrokerGenerationRegistryError.invalidRegistry
                }
            }
        }
    }
}

/// Atomic, compare-and-swap registry writer. A process-scoped lock closes the
/// race between two app windows reading the same revision and both attempting
/// a cutover; readers need no lock because rename publishes one complete file.
struct BrokerGenerationRegistryStore: Sendable {
    static let maximumRegistryBytes = 512 * 1_024

    let profileRoot: URL
    let currentUserID: uid_t

    init(profileRoot: URL, currentUserID: uid_t = getuid()) {
        self.profileRoot = profileRoot.standardizedFileURL
        self.currentUserID = currentUserID
    }

    var brokerDirectory: URL {
        profileRoot.appendingPathComponent("session-broker", isDirectory: true)
    }

    var registryURL: URL {
        brokerDirectory.appendingPathComponent("registry-v1.json", isDirectory: false)
    }

    func metadataURL(for generation: BrokerGenerationRecord) -> URL {
        if generation.packageRoot == nil {
            return brokerDirectory.appendingPathComponent("broker.json", isDirectory: false)
        }
        return brokerDirectory
            .appendingPathComponent(
                BrokerLaunchConfiguration.generationMetadataDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("\(generation.id).json", isDirectory: false)
    }

    private var lockURL: URL {
        brokerDirectory.appendingPathComponent("registry-v1.lock", isDirectory: false)
    }

    func load() throws -> BrokerGenerationRegistry {
        let registry = try readRegistry(at: registryURL)
        try registry.validate(profileRoot: profileRoot)
        return registry
    }

    /// Publish one canonical topology only if the caller still holds the
    /// revision it inspected. `nil` means the registry must not exist yet.
    func save(
        currentGenerationID: String,
        generations requestedGenerations: [BrokerGenerationRecord],
        expectedRevision: Int64?,
        selection: BrokerGenerationSelection? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> BrokerGenerationRegistry {
        try preparePrivateDirectory(brokerDirectory)
        let lockDescriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockDescriptor >= 0 else { throw BrokerGenerationRegistryError.couldNotLock }
        defer { Darwin.close(lockDescriptor) }
        try validatePrivateDescriptor(lockDescriptor, expectedKind: S_IFREG)
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw BrokerGenerationRegistryError.couldNotLock
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        let existing: BrokerGenerationRegistry?
        if FileManager.default.fileExists(atPath: registryURL.path) {
            existing = try load()
        } else {
            existing = nil
        }
        guard existing?.revision == expectedRevision else {
            throw BrokerGenerationRegistryError.revisionChanged
        }

        guard let current = requestedGenerations.first(where: { $0.id == currentGenerationID }) else {
            throw BrokerGenerationRegistryError.invalidRegistry
        }
        let canonicalCurrent = BrokerGenerationRecord(
            id: current.id,
            role: .current,
            info: current.info,
            packageRoot: current.packageRoot,
            registeredAt: current.registeredAt
        )
        let draining = requestedGenerations
            .filter { $0.id != currentGenerationID }
            .map {
                BrokerGenerationRecord(
                    id: $0.id,
                    role: .draining,
                    info: $0.info,
                    packageRoot: $0.packageRoot,
                    registeredAt: $0.registeredAt
                )
            }
            .sorted { $0.id < $1.id }
        let registry = BrokerGenerationRegistry(
            schema: BrokerGenerationRegistry.schemaVersion,
            revision: (existing?.revision ?? 0) + 1,
            updatedAt: max(1, now),
            currentGenerationID: currentGenerationID,
            generations: [canonicalCurrent] + draining,
            selection: selection
        )
        try registry.validate(profileRoot: profileRoot)
        try writeAtomically(registry)
        return registry
    }

    private func readRegistry(at url: URL) throws -> BrokerGenerationRegistry {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_uid == currentUserID,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0,
              metadata.st_size <= Self.maximumRegistryBytes else {
            throw BrokerGenerationRegistryError.unsafeRegistry
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BrokerGenerationRegistryError.unsafeRegistry }
        defer { Darwin.close(descriptor) }
        try validatePrivateDescriptor(descriptor, expectedKind: S_IFREG)
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw BrokerGenerationRegistryError.unsafeRegistry }
            if count == 0 { break }
            guard data.count <= Self.maximumRegistryBytes - count else {
                throw BrokerGenerationRegistryError.unsafeRegistry
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        do { return try JSONDecoder().decode(BrokerGenerationRegistry.self, from: data) }
        catch { throw BrokerGenerationRegistryError.invalidRegistry }
    }

    private func writeAtomically(_ registry: BrokerGenerationRegistry) throws {
        let data = try JSONEncoder.canonical.encode(registry)
        guard !data.isEmpty, data.count <= Self.maximumRegistryBytes else {
            throw BrokerGenerationRegistryError.invalidRegistry
        }
        let temporary = brokerDirectory.appendingPathComponent(
            ".registry-v1.\(getpid()).\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw BrokerGenerationRegistryError.couldNotWrite }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else { throw BrokerGenerationRegistryError.couldNotWrite }
                offset += written
            }
        }
        guard fsync(descriptor) == 0,
              rename(temporary.path, registryURL.path) == 0 else {
            throw BrokerGenerationRegistryError.couldNotWrite
        }
        shouldRemove = false
        let directoryDescriptor = open(brokerDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw BrokerGenerationRegistryError.couldNotWrite }
        defer { Darwin.close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw BrokerGenerationRegistryError.couldNotWrite
        }
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            guard metadata.st_uid == currentUserID,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_mode & 0o077 == 0 else {
                throw BrokerGenerationRegistryError.unsafeRegistry
            }
            return
        }
        guard errno == ENOENT else { throw BrokerGenerationRegistryError.unsafeRegistry }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(url.path, 0o700) == 0,
              lstat(url.path, &metadata) == 0,
              metadata.st_uid == currentUserID,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o077 == 0 else {
            throw BrokerGenerationRegistryError.unsafeRegistry
        }
    }

    private func validatePrivateDescriptor(_ descriptor: Int32, expectedKind: mode_t) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == currentUserID,
              metadata.st_mode & S_IFMT == expectedKind,
              metadata.st_mode & 0o077 == 0 else {
            throw BrokerGenerationRegistryError.unsafeRegistry
        }
    }
}

private extension JSONEncoder {
    static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

enum BrokerGenerationRegistryError: Error, Equatable, LocalizedError {
    case invalidRegistry
    case unsafeRegistry
    case revisionChanged
    case couldNotLock
    case couldNotWrite

    var errorDescription: String? {
        switch self {
        case .invalidRegistry:
            "The saved broker generation registry is invalid. No terminal was adopted."
        case .unsafeRegistry:
            "The broker generation registry is not private to this macOS user."
        case .revisionChanged:
            "Another Kaisola window changed the broker generation registry."
        case .couldNotLock:
            "The broker generation registry could not be locked safely."
        case .couldNotWrite:
            "The broker generation registry could not be committed durably."
        }
    }
}
