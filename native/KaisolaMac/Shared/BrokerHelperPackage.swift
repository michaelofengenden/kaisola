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
            // The retired schema-2 launch keys stay reserved so a manifest
            // cannot smuggle native launch metadata under the schema-1 label.
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
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported broker helper package schema."
            )
        }
    }
}

struct VerifiedBrokerHelperPackage: Equatable, Sendable {
    let root: URL
    let manifest: BrokerHelperManifest

    var nodeExecutable: URL { root.appendingPathComponent("bin/node") }
    var usageScript: URL { root.appendingPathComponent("lib/scripts/native-usage-service.cjs") }
}

enum BrokerHelperPackageVerification {
    static let maximumManifestBytes = 2 * 1_024 * 1_024
    static let maximumFileCount = 512
    static let maximumSingleFileBytes: Int64 = 512 * 1_024 * 1_024
    static let digestReadChunkBytes = 1 * 1_024 * 1_024

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
        currentUserID: uid_t = getuid()
    ) throws -> VerifiedBrokerHelperPackage {
        // `/tmp` is a symlink to `/private/tmp` on macOS. Resolve the package
        // root once so enumerated file URLs and manifest-relative paths use the
        // same canonical prefix under app translocation and temporary test
        // roots.
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

        switch manifest.packageKind {
        case let .nodeV1(node, nodePty):
            guard manifest.schemaVersion == BrokerWire.helperPackageSchema,
                  !node.version.isEmpty,
                  !node.abi.isEmpty,
                  !nodePty.version.isEmpty else {
                throw BrokerHelperPackageError.incompatibleManifest
            }
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
            guard value.st_size == record.size,
                  Int(value.st_mode & 0o777) == expectedMode,
                  value.st_mode & 0o022 == 0 else {
                throw BrokerHelperPackageError.fileMismatch(record.path)
            }
            guard try digest(fileURL) == record.sha256.lowercased() else {
                throw BrokerHelperPackageError.fileMismatch(record.path)
            }
            if let machO = record.machO {
                guard !machO.architectures.isEmpty else {
                    throw BrokerHelperPackageError.invalidManifest
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
        // Every sealed file already had to exist with its manifest mode, so
        // this final check only proves the one entrypoint every consumer
        // executes: the pinned Node runtime. Callers resolve their own script
        // paths against the sealed inventory.
        guard FileManager.default.isExecutableFile(atPath: verified.nodeExecutable.path) else {
            throw BrokerHelperPackageError.inventoryMismatch("required entrypoint is missing")
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
    /// `scripts/native-broker-package.cjs:contentDigestV1`. It intentionally
    /// excludes generated timestamps and JSON formatting while binding the
    /// compatibility envelope and every sealed behavior-bearing file.
    static func contentDigest(for manifest: BrokerHelperManifest) -> String {
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
        }
    }
}
