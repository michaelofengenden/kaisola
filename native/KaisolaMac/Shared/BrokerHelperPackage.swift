import CryptoKit
import Darwin
import Foundation
import KaisolaBrokerProtocol
import Security

struct BrokerHelperManifest: Decodable, Equatable, Sendable {
    struct ProtocolRange: Decodable, Equatable, Sendable {
        let minimum: Int
        let maximum: Int
        let securityEpoch: Int
    }

    struct NodeRuntime: Decodable, Equatable, Sendable {
        let version: String
        let abi: String
        let architectures: [String]
    }

    struct NodePTY: Decodable, Equatable, Sendable {
        let version: String
    }

    struct AppRelease: Decodable, Equatable, Sendable {
        let version: String
        let build: String
    }

    struct Launch: Decodable, Equatable, Sendable {
        enum Kind: String, Decodable, Equatable, Sendable {
            case native
        }

        let kind: Kind
        let executable: String
        let arguments: [String]
    }

    struct FileRecord: Decodable, Equatable, Sendable {
        struct MachO: Decodable, Equatable, Sendable {
            let architectures: [String]
            let designatedRequirement: String?
        }

        let path: String
        let role: String
        let size: Int64
        let mode: String
        let sha256: String
        let machO: MachO?
    }

    enum PackageKind: Equatable, Sendable {
        case nodeV1(node: NodeRuntime, nodePty: NodePTY)
        case nativeV2(appRelease: AppRelease, launch: Launch)
    }

    let schemaVersion: Int
    let packageVersion: String
    let contentDigest: String
    let brokerImplementationVersion: Int
    let brokerProtocol: ProtocolRange
    let files: [FileRecord]
    let packageKind: PackageKind

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case packageVersion
        case contentDigest
        case brokerImplementationVersion
        case brokerProtocol
        case node
        case nodePty
        case appRelease
        case launch
        case files
    }

    /// Keeps the schema-1 construction surface used by the existing broker
    /// coordinator and its tests unchanged while decoded manifests use the
    /// explicit package discriminator.
    init(
        schemaVersion: Int,
        packageVersion: String,
        contentDigest: String,
        brokerImplementationVersion: Int,
        brokerProtocol: ProtocolRange,
        node: NodeRuntime,
        nodePty: NodePTY,
        files: [FileRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.packageVersion = packageVersion
        self.contentDigest = contentDigest
        self.brokerImplementationVersion = brokerImplementationVersion
        self.brokerProtocol = brokerProtocol
        self.files = files
        packageKind = .nodeV1(node: node, nodePty: nodePty)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        packageVersion = try container.decode(String.self, forKey: .packageVersion)
        contentDigest = try container.decode(String.self, forKey: .contentDigest)
        brokerImplementationVersion = try container.decode(
            Int.self,
            forKey: .brokerImplementationVersion
        )
        brokerProtocol = try container.decode(ProtocolRange.self, forKey: .brokerProtocol)
        files = try container.decode([FileRecord].self, forKey: .files)

        switch schemaVersion {
        case 1:
            guard !container.contains(.appRelease), !container.contains(.launch) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion,
                    in: container,
                    debugDescription: "Schema 1 cannot contain schema-2 native launch metadata."
                )
            }
            packageKind = .nodeV1(
                node: try container.decode(NodeRuntime.self, forKey: .node),
                nodePty: try container.decode(NodePTY.self, forKey: .nodePty)
            )
        case 2:
            guard !container.contains(.node), !container.contains(.nodePty) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion,
                    in: container,
                    debugDescription: "Schema 2 cannot contain schema-1 Node runtime metadata."
                )
            }
            packageKind = .nativeV2(
                appRelease: try container.decode(AppRelease.self, forKey: .appRelease),
                launch: try container.decode(Launch.self, forKey: .launch)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported broker helper package schema."
            )
        }
    }
}

struct BrokerHelperPackageExpectation: Equatable, Sendable {
    let packageVersion: String
    let appReleaseVersion: String
    let appReleaseBuild: String
}

// Schema 2 is decoded and staged for conformance only in this slice;
// BrokerLaunchConfiguration and BrokerBootstrapService remain pinned to the
// schema-1 Node launch.
enum BrokerLaunchPayload: Equatable, Sendable {
    case node(executable: URL, script: URL)
    case native(executable: URL, arguments: [String])
}

struct VerifiedBrokerHelperPackage: Equatable, Sendable {
    let root: URL
    let manifest: BrokerHelperManifest

    var nodeExecutable: URL { root.appendingPathComponent("bin/node") }
    var bootstrapExecutable: URL { root.appendingPathComponent("bin/kaisola-broker-bootstrap") }
    var brokerScript: URL { root.appendingPathComponent("lib/runtime/node-broker/session-broker.cjs") }
    var usageScript: URL { root.appendingPathComponent("lib/scripts/native-usage-service.cjs") }

    fileprivate var schema2Expectation: BrokerHelperPackageExpectation? {
        guard case let .nativeV2(appRelease, _) = manifest.packageKind else {
            return nil
        }
        return BrokerHelperPackageExpectation(
            packageVersion: manifest.packageVersion,
            appReleaseVersion: appRelease.version,
            appReleaseBuild: appRelease.build
        )
    }

    var launchPayload: BrokerLaunchPayload {
        switch manifest.packageKind {
        case .nodeV1:
            .node(executable: nodeExecutable, script: brokerScript)
        case let .nativeV2(_, launch):
            .native(
                executable: root.appendingPathComponent(launch.executable),
                arguments: launch.arguments
            )
        }
    }
}

enum BrokerHelperPackageVerification {
    static let maximumManifestBytes = 2 * 1_024 * 1_024
    static let maximumFileCount = 512
    static let maximumSingleFileBytes: Int64 = 512 * 1_024 * 1_024
    static let digestReadChunkBytes = 1 * 1_024 * 1_024
    static let maximumLaunchArgumentCount = 32
    static let maximumLaunchArgumentBytes = 4_096

    static func bundledRoot(bundle: Bundle = .main) throws -> URL {
        guard let resourceURL = bundle.resourceURL else {
            throw BrokerHelperPackageError.notPackaged
        }
        return resourceURL.appendingPathComponent("BrokerHelper", isDirectory: true)
    }

    static func verifyBundled(
        bundle: Bundle = .main,
        requireSignatures: Bool
    ) throws -> VerifiedBrokerHelperPackage {
        try verify(root: bundledRoot(bundle: bundle), requireSignatures: requireSignatures)
    }

    static func verify(
        root requestedRoot: URL,
        requireSignatures: Bool,
        schema2Expectation: BrokerHelperPackageExpectation? = nil,
        currentUserID: uid_t = getuid()
    ) throws -> VerifiedBrokerHelperPackage {
        // `/tmp` is a symlink to `/private/tmp` on macOS. Resolve the package
        // root once so enumerated file URLs and manifest-relative paths use the
        // same canonical prefix under app translocation and test staging.
        let standardizedRoot = requestedRoot.standardizedFileURL
        // In production the manifest is an authority for nested hashes and
        // designated requirements only because the outer app signature seals
        // it. Reject a relocated/symlinked helper root and validate that seal
        // before trusting any manifest-provided requirement.
        if requireSignatures {
            try validateContainingApplicationSignature(for: standardizedRoot)
        }
        let root = requireSignatures
            ? standardizedRoot
            : standardizedRoot.resolvingSymlinksInPath()
        try validateDirectory(root, currentUserID: currentUserID)
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let manifestStat = try validateRegularFile(manifestURL, currentUserID: currentUserID)
        guard manifestStat.st_size > 0,
              manifestStat.st_size <= maximumManifestBytes else {
            throw BrokerHelperPackageError.invalidManifest
        }
        let manifest: BrokerHelperManifest
        do {
            manifest = try JSONDecoder().decode(
                BrokerHelperManifest.self,
                from: Data(contentsOf: manifestURL, options: [.mappedIfSafe])
            )
        } catch {
            throw BrokerHelperPackageError.invalidManifest
        }

        guard !manifest.packageVersion.isEmpty,
              manifest.packageVersion.count <= 64,
              isLowercaseSHA256(manifest.contentDigest),
              BrokerWire.compatibleImplementationVersions.contains(manifest.brokerImplementationVersion),
              manifest.brokerProtocol.minimum <= BrokerWire.protocolVersion,
              manifest.brokerProtocol.maximum >= BrokerWire.protocolVersion,
              manifest.brokerProtocol.securityEpoch == BrokerWire.securityEpoch,
              !manifest.files.isEmpty,
              manifest.files.count <= maximumFileCount else {
            throw BrokerHelperPackageError.incompatibleManifest
        }

        let isNativeV2: Bool
        switch manifest.packageKind {
        case let .nodeV1(node, nodePty):
            guard manifest.schemaVersion == BrokerWire.helperPackageSchema,
                  !node.version.isEmpty,
                  !node.abi.isEmpty,
                  !nodePty.version.isEmpty else {
                throw BrokerHelperPackageError.incompatibleManifest
            }
            isNativeV2 = false
        case let .nativeV2(appRelease, launch):
            guard let schema2Expectation,
                  manifest.schemaVersion == BrokerWire.nativeHelperPackageSchema,
                  manifest.packageVersion == schema2Expectation.packageVersion,
                  isBoundedIdentity(appRelease.version),
                  isBoundedIdentity(appRelease.build),
                  appRelease.version == schema2Expectation.appReleaseVersion,
                  appRelease.build == schema2Expectation.appReleaseBuild,
                  manifest.brokerImplementationVersion == BrokerWire.implementationVersion,
                  manifest.brokerProtocol.minimum == BrokerWire.protocolVersion,
                  manifest.brokerProtocol.maximum == BrokerWire.protocolVersion,
                  manifest.brokerProtocol.securityEpoch == BrokerWire.securityEpoch else {
                throw BrokerHelperPackageError.incompatibleManifest
            }
            try validateNativeLaunch(launch, files: manifest.files)
            isNativeV2 = true
        }

        if isNativeV2, manifestStat.st_nlink != 1 {
            throw BrokerHelperPackageError.invalidManifest
        }

        let expectedPaths = Set(manifest.files.map(\.path))
        guard expectedPaths.count == manifest.files.count else {
            throw BrokerHelperPackageError.invalidManifest
        }
        let actualPaths = try packageFiles(root: root, currentUserID: currentUserID)
        let sealedPaths = expectedPaths.union(["manifest.json"])
        guard actualPaths == sealedPaths else {
            let missing = sealedPaths.subtracting(actualPaths).sorted().joined(separator: ",")
            let extra = actualPaths.subtracting(sealedPaths).sorted().joined(separator: ",")
            throw BrokerHelperPackageError.inventoryMismatch("missing=\(missing) extra=\(extra)")
        }

        for record in manifest.files {
            guard isSafeRelativePath(record.path),
                  let expectedMode = Int(record.mode, radix: 8),
                  record.sha256.count == 64,
                  record.sha256.allSatisfy(\.isHexDigit),
                  record.size >= 0,
                  record.size <= maximumSingleFileBytes else {
                throw BrokerHelperPackageError.invalidManifest
            }
            let fileURL = root.appendingPathComponent(record.path, isDirectory: false)
            let value = try validateRegularFile(fileURL, currentUserID: currentUserID)
            if isNativeV2,
               record.role == "session-broker-executable",
               record.mode != "0755" {
                throw BrokerHelperPackageError.fileMismatch(record.path)
            }
            guard value.st_size == record.size,
                  Int(value.st_mode & 0o777) == expectedMode,
                  value.st_mode & 0o022 == 0 else {
                throw BrokerHelperPackageError.fileMismatch(record.path)
            }
            if isNativeV2, value.st_nlink != 1 {
                throw BrokerHelperPackageError.fileMismatch(record.path)
            }
            guard try digest(fileURL) == record.sha256.lowercased() else {
                throw BrokerHelperPackageError.fileMismatch(record.path)
            }
            let actualMachOArchitectures = isNativeV2
                ? try machOArchitectures(fileURL)
                : []
            if isNativeV2,
               (record.machO != nil) != !actualMachOArchitectures.isEmpty {
                throw BrokerHelperPackageError.fileMismatch(record.path)
            }
            if let machO = record.machO {
                guard !machO.architectures.isEmpty else {
                    throw BrokerHelperPackageError.invalidManifest
                }
                if isNativeV2 {
                    guard machO.architectures == ["arm64"],
                          actualMachOArchitectures == ["arm64"] else {
                        throw BrokerHelperPackageError.fileMismatch(record.path)
                    }
                }
                if requireSignatures {
                    guard let requirement = machO.designatedRequirement, !requirement.isEmpty else {
                        throw BrokerHelperPackageError.unsignedNestedCode(record.path)
                    }
                    try validateSignature(fileURL, requirement: requirement)
                }
            }
        }

        guard contentDigest(for: manifest) == manifest.contentDigest else {
            throw BrokerHelperPackageError.invalidManifest
        }

        let verified = VerifiedBrokerHelperPackage(root: root, manifest: manifest)
        switch verified.launchPayload {
        case .node:
            guard FileManager.default.isExecutableFile(atPath: verified.nodeExecutable.path),
                  FileManager.default.isExecutableFile(atPath: verified.bootstrapExecutable.path),
                  FileManager.default.fileExists(atPath: verified.brokerScript.path) else {
                throw BrokerHelperPackageError.inventoryMismatch("required entrypoint is missing")
            }
        case let .native(executable, _):
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw BrokerHelperPackageError.inventoryMismatch("required entrypoint is missing")
            }
        }
        return verified
    }

    private static func packageFiles(root: URL, currentUserID: uid_t) throws -> Set<String> {
        var result: Set<String> = []
        func visit(_ directory: URL) throws {
            for entry in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                // Inspect the directory entry itself. Resolving it first would
                // turn a symlink into its target and defeat the non-regular
                // entry check below.
                let canonicalEntry = entry.standardizedFileURL
                var value = stat()
                guard lstat(canonicalEntry.path, &value) == 0 else {
                    throw BrokerHelperPackageError.inventoryMismatch("unreadable entry")
                }
                guard value.st_uid == currentUserID || value.st_uid == 0,
                      value.st_mode & 0o022 == 0 else {
                    throw BrokerHelperPackageError.unsafePermissions
                }
                let kind = value.st_mode & S_IFMT
                if kind == S_IFDIR {
                    try visit(canonicalEntry)
                } else if kind == S_IFREG {
                    let relative = String(canonicalEntry.path.dropFirst(root.path.count + 1))
                    guard isSafeRelativePath(relative) else {
                        throw BrokerHelperPackageError.inventoryMismatch("unsafe relative path")
                    }
                    result.insert(relative)
                } else {
                    throw BrokerHelperPackageError.inventoryMismatch("non-regular entry")
                }
            }
        }
        try visit(root)
        return result
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isBoundedIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 64
            && !value.contains("\0")
    }

    private static func validateNativeLaunch(
        _ launch: BrokerHelperManifest.Launch,
        files: [BrokerHelperManifest.FileRecord]
    ) throws {
        guard isSafeRelativePath(launch.executable),
              launch.arguments.count <= maximumLaunchArgumentCount,
              launch.arguments.allSatisfy({ argument in
                  !argument.isEmpty
                      && argument.utf8.count <= maximumLaunchArgumentBytes
                      && !argument.contains("\0")
                      && argument != "--launch"
                      && argument != "--pty-child"
              }),
              files.allSatisfy({ !$0.role.isEmpty && $0.role.utf8.count <= 64 }) else {
            throw BrokerHelperPackageError.invalidManifest
        }

        let executableRecords = files.filter { $0.role == "session-broker-executable" }
        guard executableRecords.count == 1,
              let executable = executableRecords.first,
              executable.path == launch.executable,
              let machO = executable.machO,
              machO.architectures == ["arm64"],
              let requirement = machO.designatedRequirement,
              !requirement.isEmpty else {
            throw BrokerHelperPackageError.invalidManifest
        }
    }

    private static func machOArchitectures(_ url: URL) throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4_096) ?? Data()

        func readUInt32(_ offset: Int, littleEndian: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= header.count else { return nil }
            let bytes = [
                UInt32(header[offset]),
                UInt32(header[offset + 1]),
                UInt32(header[offset + 2]),
                UInt32(header[offset + 3]),
            ]
            if littleEndian {
                return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
            }
            return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
        }

        func architecture(_ cpuType: UInt32) -> String {
            switch cpuType {
            case 0x0100_000C: "arm64"
            case 0x0100_0007: "x86_64"
            case 0x0000_000C: "arm"
            case 0x0000_0007: "x86"
            default: "unknown-\(cpuType)"
            }
        }

        guard let littleMagic = readUInt32(0, littleEndian: true),
              let bigMagic = readUInt32(0, littleEndian: false) else {
            return []
        }
        if littleMagic == 0xFEED_FACE || littleMagic == 0xFEED_FACF {
            guard let cpuType = readUInt32(4, littleEndian: true) else { return [] }
            return [architecture(cpuType)]
        }
        if bigMagic == 0xFEED_FACE || bigMagic == 0xFEED_FACF {
            guard let cpuType = readUInt32(4, littleEndian: false) else { return [] }
            return [architecture(cpuType)]
        }

        let fatEntryBytes: Int
        switch bigMagic {
        case 0xCAFE_BABE:
            fatEntryBytes = 20
        case 0xCAFE_BABF:
            fatEntryBytes = 32
        default:
            return []
        }
        guard let rawCount = readUInt32(4, littleEndian: false),
              rawCount > 0,
              rawCount <= 32 else {
            return []
        }
        let count = Int(rawCount)
        guard 8 + (count * fatEntryBytes) <= header.count else { return [] }
        return (0..<count).compactMap { index in
            readUInt32(8 + (index * fatEntryBytes), littleEndian: false).map(architecture)
        }
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let reachedEnd = try autoreleasepool { () throws -> Bool in
                let data = try handle.read(upToCount: digestReadChunkBytes) ?? Data()
                guard !data.isEmpty else { return true }
                hash.update(data: data)
                return false
            }
            if reachedEnd { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Must remain byte-for-byte equivalent to
    /// `scripts/native-broker-package.cjs:contentDigest`. It intentionally
    /// excludes generated timestamps and JSON formatting while binding the
    /// compatibility envelope and every sealed behavior-bearing file.
    static func contentDigest(for manifest: BrokerHelperManifest) -> String {
        if case let .nativeV2(appRelease, launch) = manifest.packageKind {
            return nativeContentDigest(
                for: manifest,
                appRelease: appRelease,
                launch: launch
            )
        }
        var hash = SHA256()
        func field(_ value: String) {
            let bytes = Data(value.utf8)
            hash.update(data: Data("\(bytes.count):".utf8))
            hash.update(data: bytes)
        }
        field("kaisola-broker-helper-content-v1")
        field(String(manifest.schemaVersion))
        field(manifest.packageVersion)
        field(String(manifest.brokerImplementationVersion))
        field(String(manifest.brokerProtocol.minimum))
        field(String(manifest.brokerProtocol.maximum))
        field(String(manifest.brokerProtocol.securityEpoch))
        for record in manifest.files.sorted(by: { $0.path < $1.path }) {
            field(record.path)
            field(String(record.size))
            field(record.mode)
            field(record.sha256.lowercased())
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func nativeContentDigest(
        for manifest: BrokerHelperManifest,
        appRelease: BrokerHelperManifest.AppRelease,
        launch: BrokerHelperManifest.Launch
    ) -> String {
        var hash = SHA256()
        func field(_ value: String) {
            let bytes = Data(value.utf8)
            hash.update(data: Data("\(bytes.count):".utf8))
            hash.update(data: bytes)
        }
        field("kaisola-broker-helper-content-v2")
        field(String(manifest.schemaVersion))
        field(manifest.packageVersion)
        field(appRelease.version)
        field(appRelease.build)
        field(String(manifest.brokerImplementationVersion))
        field(String(manifest.brokerProtocol.minimum))
        field(String(manifest.brokerProtocol.maximum))
        field(String(manifest.brokerProtocol.securityEpoch))
        field(launch.kind.rawValue)
        field(launch.executable)
        field(String(launch.arguments.count))
        for argument in launch.arguments {
            field(argument)
        }
        for record in manifest.files.sorted(by: { $0.path < $1.path }) {
            field(record.path)
            field(record.role)
            field(String(record.size))
            field(record.mode)
            field(record.sha256.lowercased())
            field(String(record.machO?.architectures.count ?? 0))
            for architecture in record.machO?.architectures ?? [] {
                field(architecture)
            }
            field(record.machO?.designatedRequirement ?? "")
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }

    private static func validateSignature(_ url: URL, requirement: String) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw BrokerHelperPackageError.unsignedNestedCode(url.lastPathComponent)
        }
        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let secRequirement,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: (1 << 0) | (1 << 4)), // kSecCSCheckAllArchitectures | kSecCSStrictValidate
                  secRequirement
              ) == errSecSuccess else {
            throw BrokerHelperPackageError.signatureMismatch(url.lastPathComponent)
        }
    }

    private static func validateContainingApplicationSignature(for helperRoot: URL) throws {
        var value = stat()
        guard lstat(helperRoot.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR else {
            throw BrokerHelperPackageError.unsealedHostApplication
        }

        var candidate = helperRoot
        var applicationURL: URL?
        for _ in 0..<8 {
            if candidate.pathExtension.lowercased() == "app" {
                applicationURL = candidate
                break
            }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        guard let applicationURL else {
            throw BrokerHelperPackageError.unsealedHostApplication
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: (1 << 0) | (1 << 4)),
                  nil
              ) == errSecSuccess else {
            throw BrokerHelperPackageError.unsealedHostApplication
        }
    }

    @discardableResult
    private static func validateDirectory(_ url: URL, currentUserID: uid_t) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFDIR,
              (value.st_uid == currentUserID || value.st_uid == 0),
              value.st_mode & 0o022 == 0 else {
            throw BrokerHelperPackageError.unsafePermissions
        }
        return value
    }

    @discardableResult
    private static func validateRegularFile(_ url: URL, currentUserID: uid_t) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG,
              (value.st_uid == currentUserID || value.st_uid == 0),
              value.st_mode & 0o022 == 0 else {
            throw BrokerHelperPackageError.unsafePermissions
        }
        return value
    }
}

/// Copies one already verified helper package out of the replaceable `.app`
/// bundle into a private, digest-addressed generation directory. The final
/// path is immutable by convention: an existing directory is reused only when
/// every byte still verifies against the sealed source manifest. A mismatch
/// fails closed instead of repairing over evidence of tampering.
enum BrokerHelperPackageStaging {
    static func stage(
        _ source: VerifiedBrokerHelperPackage,
        at requestedDestination: URL,
        currentUserID: uid_t = getuid()
    ) throws -> VerifiedBrokerHelperPackage {
        let destination = requestedDestination.standardizedFileURL
        let generations = destination.deletingLastPathComponent()
        guard generations.lastPathComponent == "broker-generations",
              destination.lastPathComponent == source.manifest.contentDigest else {
            throw BrokerHelperPackageError.unsafeStagingPath
        }
        let schema2Expectation = source.schema2Expectation
        try preparePrivateDirectory(generations, currentUserID: currentUserID)

        if FileManager.default.fileExists(atPath: destination.path) {
            return try verifiedExisting(
                destination,
                expected: source.manifest,
                schema2Expectation: schema2Expectation,
                currentUserID: currentUserID
            )
        }

        let temporary = generations.appendingPathComponent(
            ".stage-\(source.manifest.contentDigest)-\(getpid())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        var temporaryExists = false
        defer {
            if temporaryExists { try? FileManager.default.removeItem(at: temporary) }
        }
        do {
            try FileManager.default.copyItem(at: source.root, to: temporary)
            temporaryExists = true
            guard chmod(temporary.path, 0o700) == 0 else {
                throw BrokerHelperPackageError.unsafePermissions
            }
            let copied = try BrokerHelperPackageVerification.verify(
                root: temporary,
                requireSignatures: false,
                schema2Expectation: schema2Expectation,
                currentUserID: currentUserID
            )
            guard copied.manifest == source.manifest else {
                throw BrokerHelperPackageError.stagedPackageMismatch
            }
            try synchronize(copied)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                temporaryExists = false
            } catch {
                // A second window may have won the same digest-addressed stage
                // race. Adopt only its independently verified exact bytes.
                if FileManager.default.fileExists(atPath: destination.path) {
                    return try verifiedExisting(
                        destination,
                        expected: source.manifest,
                        schema2Expectation: schema2Expectation,
                        currentUserID: currentUserID
                    )
                }
                throw error
            }
            try synchronizeDirectory(generations)
            return try verifiedExisting(
                destination,
                expected: source.manifest,
                schema2Expectation: schema2Expectation,
                currentUserID: currentUserID
            )
        } catch let error as BrokerHelperPackageError {
            throw error
        } catch {
            throw BrokerHelperPackageError.couldNotStage
        }
    }

    private static func verifiedExisting(
        _ destination: URL,
        expected: BrokerHelperManifest,
        schema2Expectation: BrokerHelperPackageExpectation?,
        currentUserID: uid_t
    ) throws -> VerifiedBrokerHelperPackage {
        let verified: VerifiedBrokerHelperPackage
        do {
            verified = try BrokerHelperPackageVerification.verify(
                root: destination,
                requireSignatures: false,
                schema2Expectation: schema2Expectation,
                currentUserID: currentUserID
            )
        } catch {
            throw BrokerHelperPackageError.stagedPackageMismatch
        }
        guard verified.manifest == expected else {
            throw BrokerHelperPackageError.stagedPackageMismatch
        }
        return verified
    }

    private static func preparePrivateDirectory(_ url: URL, currentUserID: uid_t) throws {
        var value = stat()
        if lstat(url.path, &value) == 0 {
            guard value.st_uid == currentUserID,
                  value.st_mode & S_IFMT == S_IFDIR,
                  value.st_mode & 0o077 == 0 else {
                throw BrokerHelperPackageError.unsafePermissions
            }
            return
        }
        guard errno == ENOENT else { throw BrokerHelperPackageError.unsafePermissions }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(url.path, 0o700) == 0,
              lstat(url.path, &value) == 0,
              value.st_uid == currentUserID,
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_mode & 0o077 == 0 else {
            throw BrokerHelperPackageError.unsafePermissions
        }
    }

    private static func synchronize(_ package: VerifiedBrokerHelperPackage) throws {
        for record in package.manifest.files {
            try synchronizeFile(package.root.appendingPathComponent(record.path))
        }
        try synchronizeFile(package.root.appendingPathComponent("manifest.json"))
        try synchronizeDirectory(package.root)
    }

    private static func synchronizeFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BrokerHelperPackageError.couldNotStage }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw BrokerHelperPackageError.couldNotStage }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BrokerHelperPackageError.couldNotStage }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw BrokerHelperPackageError.couldNotStage }
    }
}

enum BrokerHelperPackageError: Error, Equatable, LocalizedError {
    case notPackaged
    case invalidManifest
    case incompatibleManifest
    case inventoryMismatch(String)
    case unsafePermissions
    case fileMismatch(String)
    case unsealedHostApplication
    case unsignedNestedCode(String)
    case signatureMismatch(String)
    case unsafeStagingPath
    case stagedPackageMismatch
    case couldNotStage

    var errorDescription: String? {
        switch self {
        case .notPackaged:
            "This development build does not contain the standalone terminal helper."
        case .invalidManifest:
            "The bundled terminal helper manifest is invalid."
        case .incompatibleManifest:
            "The bundled terminal helper is outside this app's compatibility window."
        case let .inventoryMismatch(detail):
            "The bundled terminal helper file inventory does not match its sealed manifest (\(detail))."
        case .unsafePermissions:
            "The bundled terminal helper has unsafe ownership or permissions."
        case let .fileMismatch(path):
            "The bundled terminal helper failed integrity verification for \(path)."
        case .unsealedHostApplication:
            "The terminal helper is not contained in an intact signed Kaisola application."
        case let .unsignedNestedCode(path):
            "The bundled terminal helper contains unsigned code at \(path)."
        case let .signatureMismatch(path):
            "The bundled terminal helper signature is invalid at \(path)."
        case .unsafeStagingPath:
            "The terminal helper generation path is invalid."
        case .stagedPackageMismatch:
            "The staged terminal helper no longer matches its sealed generation."
        case .couldNotStage:
            "The terminal helper generation could not be staged durably."
        }
    }
}
