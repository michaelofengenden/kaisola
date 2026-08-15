import Darwin
import CryptoKit
import Foundation
import KaisolaBrokerProtocol

struct BrokerLaunchConfiguration: Codable, Equatable, Sendable {
    static let generationMetadataDirectoryName = "generations"
    static var defaultMaximumLiveTerminals: Int { BrokerWire.defaultMaximumLiveTerminals }
    static var maximumConfigurableLiveTerminals: Int { BrokerWire.maximumConfigurableLiveTerminals }

    let protocolVersion: Int
    let securityEpoch: Int
    let implementationVersion: Int
    let packageSchema: Int
    let packageVersion: String
    /// Schema-2 app provenance is copied from the already verified native
    /// package. The bootstrap then uses this pair as an expectation while it
    /// re-verifies the staged root, so the private launch file cannot select a
    /// different native build under the same compatibility envelope.
    let appReleaseVersion: String?
    let appReleaseBuild: String?
    let contentDigest: String
    /// Digest-addressed verified copy outside the replaceable application
    /// bundle. Older launch files omit this field and retain the bundled
    /// helper fallback; every newly written native launch names it explicitly.
    let packageRoot: String?
    let token: String
    let socketPath: String
    let infoFile: String
    let lockFile: String
    let storageDir: String
    let logFile: String
    /// Process-wide PTY ceiling for this detached broker generation. Optional
    /// only so launch files written by the immediately previous app remain
    /// decodable during a rolling upgrade; all new launch files seal a value.
    let maximumLiveTerminals: Int?
    let startedAt: Int64
    let version: String
    let smoke: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case securityEpoch, implementationVersion, packageSchema, packageVersion, contentDigest
        case appReleaseVersion, appReleaseBuild
        case packageRoot
        case token, socketPath, infoFile, lockFile, storageDir, logFile, maximumLiveTerminals
        case startedAt, version, smoke
    }

    init(
        protocolVersion: Int,
        securityEpoch: Int,
        implementationVersion: Int,
        packageSchema: Int,
        packageVersion: String,
        appReleaseVersion: String? = nil,
        appReleaseBuild: String? = nil,
        contentDigest: String,
        packageRoot: String?,
        token: String,
        socketPath: String,
        infoFile: String,
        lockFile: String,
        storageDir: String,
        logFile: String,
        maximumLiveTerminals: Int?,
        startedAt: Int64,
        version: String,
        smoke: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.securityEpoch = securityEpoch
        self.implementationVersion = implementationVersion
        self.packageSchema = packageSchema
        self.packageVersion = packageVersion
        self.appReleaseVersion = appReleaseVersion
        self.appReleaseBuild = appReleaseBuild
        self.contentDigest = contentDigest
        self.packageRoot = packageRoot
        self.token = token
        self.socketPath = socketPath
        self.infoFile = infoFile
        self.lockFile = lockFile
        self.storageDir = storageDir
        self.logFile = logFile
        self.maximumLiveTerminals = maximumLiveTerminals
        self.startedAt = startedAt
        self.version = version
        self.smoke = smoke
    }

    func validate(
        configurationURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard protocolVersion == BrokerWire.protocolVersion,
              securityEpoch == BrokerWire.securityEpoch,
              BrokerWire.compatibleImplementationVersions.contains(implementationVersion),
              BrokerWire.supportedHelperPackageSchemas.contains(packageSchema),
              !packageVersion.isEmpty,
              packageVersion.utf8.count <= 64,
              BrokerHelperPackageVerification.isLowercaseSHA256(contentDigest),
              token.count == 64,
              token.allSatisfy(\.isHexDigit),
              maximumLiveTerminals.map({
                  (1...Self.maximumConfigurableLiveTerminals).contains($0)
              }) ?? true,
              startedAt > 0,
              !version.isEmpty,
              version.count <= 120,
              !smoke else {
            throw BrokerLaunchConfigurationError.invalidConfiguration
        }

        // A schema-1 request must remain byte-for-byte compatible with the
        // stable Node launch contract. Schema 2 carries both signed app
        // provenance fields as one indivisible bounded identity and always
        // names its digest-addressed package root.
        switch packageSchema {
        case BrokerWire.nodeHelperPackageSchema:
            guard appReleaseVersion == nil, appReleaseBuild == nil else {
                throw BrokerLaunchConfigurationError.invalidConfiguration
            }
        case BrokerWire.nativeHelperPackageSchema:
            guard let appReleaseVersion,
                  let appReleaseBuild,
                  Self.isBoundedIdentity(appReleaseVersion),
                  Self.isBoundedIdentity(appReleaseBuild),
                  packageRoot != nil else {
                throw BrokerLaunchConfigurationError.invalidConfiguration
            }
        default:
            // The supported-schema guard above is the sole compatibility
            // window. Keep this explicit branch so widening that set requires
            // defining the launch provenance contract here too.
            throw BrokerLaunchConfigurationError.invalidConfiguration
        }

        let brokerDirectory = configurationURL.deletingLastPathComponent().standardizedFileURL
        let userData = brokerDirectory.deletingLastPathComponent().standardizedFileURL
        guard brokerDirectory.lastPathComponent == "session-broker",
              configurationURL.standardizedFileURL.deletingLastPathComponent() == brokerDirectory,
              configurationURL.lastPathComponent.hasPrefix("launch-native-"),
              configurationURL.pathExtension == "json" else {
            throw BrokerLaunchConfigurationError.unsafePath
        }

        if let packageRoot {
            let expectedPackageRoot = userData
                .appendingPathComponent("broker-generations", isDirectory: true)
                .appendingPathComponent(contentDigest, isDirectory: true)
                .standardizedFileURL
            guard URL(fileURLWithPath: packageRoot, isDirectory: true).standardizedFileURL
                == expectedPackageRoot else {
                throw BrokerLaunchConfigurationError.unsafePath
            }

            let metadataDirectory = brokerDirectory
                .appendingPathComponent(Self.generationMetadataDirectoryName, isDirectory: true)
            let exactGenerationFiles = [
                infoFile: metadataDirectory.appendingPathComponent("\(contentDigest).json").path,
                lockFile: metadataDirectory.appendingPathComponent("\(contentDigest).lock").path,
                logFile: metadataDirectory.appendingPathComponent("\(contentDigest).log").path,
                storageDir: userData.appendingPathComponent("terminal-cache", isDirectory: true).path,
            ]
            guard exactGenerationFiles.allSatisfy({
                URL(fileURLWithPath: $0.key).standardizedFileURL.path == $0.value
            }) else {
                throw BrokerLaunchConfigurationError.unsafePath
            }

            let socketLeaf = Self.generationSocketLeaf(
                userData: userData,
                contentDigest: contentDigest
            )
            let durableSocket = brokerDirectory.appendingPathComponent(socketLeaf).path
            let compactSocket = homeDirectory
                .appendingPathComponent(".kaisola-session", isDirectory: true)
                .appendingPathComponent(socketLeaf)
                .standardizedFileURL.path
            let standardizedSocket = URL(fileURLWithPath: socketPath).standardizedFileURL.path
            guard standardizedSocket == durableSocket || standardizedSocket == compactSocket else {
                throw BrokerLaunchConfigurationError.unsafePath
            }
        } else {
            // Launch files written by the pre-registry app remain valid only
            // for their exact single-broker layout. New launch requests always
            // include packageRoot and therefore cannot fall back into it.
            let exactLegacyFiles = [
                infoFile: brokerDirectory.appendingPathComponent("broker.json").path,
                lockFile: brokerDirectory.appendingPathComponent("broker.lock").path,
                logFile: brokerDirectory.appendingPathComponent("broker.log").path,
                storageDir: userData.appendingPathComponent("terminal-cache", isDirectory: true).path,
            ]
            guard exactLegacyFiles.allSatisfy({
                URL(fileURLWithPath: $0.key).standardizedFileURL.path == $0.value
            }) else {
                throw BrokerLaunchConfigurationError.unsafePath
            }

            let durableSocket = brokerDirectory.appendingPathComponent("broker.sock").path
            let compactRoot = homeDirectory
                .appendingPathComponent(".kaisola-session", isDirectory: true)
                .standardizedFileURL.path
            let socketURL = URL(fileURLWithPath: socketPath).standardizedFileURL
            let compactSocket = socketURL.deletingLastPathComponent().path == compactRoot
                && socketURL.pathExtension == "sock"
                && socketURL.deletingPathExtension().lastPathComponent.range(
                    of: #"^[0-9a-f]{18}$"#,
                    options: .regularExpression
                ) != nil
            guard socketURL.path == durableSocket || compactSocket else {
                throw BrokerLaunchConfigurationError.unsafePath
            }
        }
    }

    static func generationSocketLeaf(userData: URL, contentDigest: String) -> String {
        let material = Data(
            (userData.standardizedFileURL.path + "\u{0}" + contentDigest).utf8
        )
        // Nine digest bytes retain the existing 72-bit compact identity while
        // base64url saves six pathname bytes versus hexadecimal. That matters
        // for long home-directory paths near sockaddr_un.sun_path's limit.
        let shortIdentity = Data(SHA256.hash(data: material).prefix(9))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "\(shortIdentity).sock"
    }

    /// The package manifest schema and its runtime-neutral launch payload are
    /// two independently decoded inputs. Resolve them together so the tested
    /// command is exactly the command the privileged bootstrap spawns.
    func launchCommand(
        for launchPayload: BrokerLaunchPayload,
        configurationURL: URL
    ) throws -> BrokerLaunchCommand {
        switch (packageSchema, launchPayload) {
        case let (BrokerWire.nodeHelperPackageSchema, .node(executable, script)):
            return BrokerLaunchCommand(
                executable: executable,
                arguments: [script.path, "--launch", configurationURL.path],
                requiresSwiftLaunchMarker: false
            )
        case let (BrokerWire.nativeHelperPackageSchema, .native(executable, arguments)):
            return BrokerLaunchCommand(
                executable: executable,
                arguments: arguments + ["--launch", configurationURL.path],
                requiresSwiftLaunchMarker: true
            )
        default:
            throw BrokerLaunchConfigurationError.invalidConfiguration
        }
    }

    private static func isBoundedIdentity(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 64
            && !value.contains("\0")
    }
}

struct BrokerLaunchCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    /// The native executable refuses production launch mode without this
    /// explicit environment marker. Node must never receive it.
    let requiresSwiftLaunchMarker: Bool
}

enum BrokerLaunchConfigurationError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case unsafePath
    case unsafePermissions

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The private broker launch request is invalid."
        case .unsafePath: "The private broker launch request contains an unsafe path."
        case .unsafePermissions: "The private broker launch request is not owned by this user."
        }
    }
}
