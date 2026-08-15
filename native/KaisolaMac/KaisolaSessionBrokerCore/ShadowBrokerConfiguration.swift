import Darwin
import CryptoKit
import Foundation
import KaisolaBrokerProtocol

public enum SwiftBrokerRuntimeMode: String, Equatable, Sendable {
    case shadow
    case freshPTY
    case launch
}

public struct ShadowBrokerConfiguration: Codable, Equatable, Sendable {
    private static let environmentMarker = "KAISOLA_SWIFT_BROKER_SHADOW"
    private static let freshPTYEnvironmentMarker = "KAISOLA_SWIFT_BROKER_FRESH_PTY"
    private static let launchEnvironmentMarker = "KAISOLA_SWIFT_BROKER_LAUNCH"
    private static let maximumConfigurationBytes = 64 * 1_024
    private static let shadowJSONKeys: Set<String> = [
        "protocol",
        "securityEpoch",
        "implementationVersion",
        "packageSchema",
        "contentDigest",
        "token",
        "socketPath",
    ]
    private static let launchJSONKeys = shadowJSONKeys.union([
        "packageVersion",
        "contentDigest",
        "packageRoot",
        "infoFile",
        "lockFile",
        "storageDir",
        "logFile",
        "maximumLiveTerminals",
        "startedAt",
        "version",
        "smoke",
    ])
    private static let nativeLaunchJSONKeys = launchJSONKeys.union([
        "appReleaseVersion",
        "appReleaseBuild",
    ])

    public let protocolVersion: Int
    public let securityEpoch: Int
    public let implementationVersion: Int
    public let packageSchema: Int
    public let packageVersion: String?
    public let appReleaseVersion: String?
    public let appReleaseBuild: String?
    public let contentDigest: String
    public let packageRoot: String?
    public let token: String
    public let socketPath: String
    public let infoFile: String?
    public let lockFile: String?
    public let storageDir: String?
    public let logFile: String?
    public let maximumLiveTerminals: Int?
    public let startedAt: Int64?
    public let version: String?
    public let smoke: Bool?
    public let runtimeMode: SwiftBrokerRuntimeMode

    public var socketURL: URL { URL(fileURLWithPath: socketPath) }
    public var privateRootURL: URL { socketURL.deletingLastPathComponent() }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case securityEpoch
        case implementationVersion
        case packageSchema
        case packageVersion
        case appReleaseVersion
        case appReleaseBuild
        case contentDigest
        case packageRoot
        case token
        case socketPath
        case infoFile
        case lockFile
        case storageDir
        case logFile
        case maximumLiveTerminals
        case startedAt
        case version
        case smoke
    }

    public init(
        protocolVersion: Int,
        securityEpoch: Int,
        implementationVersion: Int,
        packageSchema: Int,
        packageVersion: String? = nil,
        appReleaseVersion: String? = nil,
        appReleaseBuild: String? = nil,
        contentDigest: String,
        packageRoot: String? = nil,
        token: String,
        socketPath: String,
        infoFile: String? = nil,
        lockFile: String? = nil,
        storageDir: String? = nil,
        logFile: String? = nil,
        maximumLiveTerminals: Int? = nil,
        startedAt: Int64? = nil,
        version: String? = nil,
        smoke: Bool? = nil,
        runtimeMode: SwiftBrokerRuntimeMode = .shadow
    ) throws {
        guard protocolVersion == 2,
              securityEpoch == 1,
              implementationVersion == 2,
              Self.isLowercaseSHA256(contentDigest),
              Self.isHexToken(token) else {
            throw ShadowBrokerConfigurationError.invalidConfiguration
        }
        guard Self.isCanonicalAbsolutePath(socketPath) else {
            throw ShadowBrokerConfigurationError.unsafePath
        }

        switch runtimeMode {
        case .shadow, .freshPTY:
            guard packageSchema == BrokerWire.nativeHelperPackageSchema,
                  packageVersion == nil,
                  appReleaseVersion == nil,
                  appReleaseBuild == nil,
                  packageRoot == nil,
                  infoFile == nil,
                  lockFile == nil,
                  storageDir == nil,
                  logFile == nil,
                  maximumLiveTerminals == nil,
                  startedAt == nil,
                  version == nil,
                  smoke == nil else {
                throw ShadowBrokerConfigurationError.invalidConfiguration
            }
        case .launch:
            guard BrokerWire.supportedHelperPackageSchemas.contains(packageSchema),
                  let packageVersion,
                  Self.isBoundedIdentity(packageVersion, maximumBytes: 64),
                  let packageRoot,
                  let infoFile,
                  let lockFile,
                  let storageDir,
                  let logFile,
                  let maximumLiveTerminals,
                  (1...BrokerWire.maximumConfigurableLiveTerminals).contains(maximumLiveTerminals),
                  let startedAt,
                  startedAt > 0,
                  let version,
                  Self.isBoundedIdentity(version, maximumBytes: 120),
                  smoke == false else {
                throw ShadowBrokerConfigurationError.invalidConfiguration
            }
            let launchPaths = [packageRoot, infoFile, lockFile, storageDir, logFile]
            guard launchPaths.allSatisfy(Self.isCanonicalAbsolutePath) else {
                throw ShadowBrokerConfigurationError.unsafePath
            }
            if packageSchema == BrokerWire.nativeHelperPackageSchema {
                guard let appReleaseVersion,
                      let appReleaseBuild,
                      Self.isBoundedIdentity(appReleaseVersion, maximumBytes: 64),
                      Self.isBoundedIdentity(appReleaseBuild, maximumBytes: 64) else {
                    throw ShadowBrokerConfigurationError.invalidConfiguration
                }
            } else if appReleaseVersion != nil || appReleaseBuild != nil {
                throw ShadowBrokerConfigurationError.invalidConfiguration
            }
        }

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
        self.runtimeMode = runtimeMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: values.decode(Int.self, forKey: .protocolVersion),
            securityEpoch: values.decode(Int.self, forKey: .securityEpoch),
            implementationVersion: values.decode(Int.self, forKey: .implementationVersion),
            packageSchema: values.decode(Int.self, forKey: .packageSchema),
            packageVersion: values.decodeIfPresent(String.self, forKey: .packageVersion),
            appReleaseVersion: values.decodeIfPresent(String.self, forKey: .appReleaseVersion),
            appReleaseBuild: values.decodeIfPresent(String.self, forKey: .appReleaseBuild),
            contentDigest: values.decode(String.self, forKey: .contentDigest),
            packageRoot: values.decodeIfPresent(String.self, forKey: .packageRoot),
            token: values.decode(String.self, forKey: .token),
            socketPath: values.decode(String.self, forKey: .socketPath),
            infoFile: values.decodeIfPresent(String.self, forKey: .infoFile),
            lockFile: values.decodeIfPresent(String.self, forKey: .lockFile),
            storageDir: values.decodeIfPresent(String.self, forKey: .storageDir),
            logFile: values.decodeIfPresent(String.self, forKey: .logFile),
            maximumLiveTerminals: values.decodeIfPresent(
                Int.self,
                forKey: .maximumLiveTerminals
            ),
            startedAt: values.decodeIfPresent(Int64.self, forKey: .startedAt),
            version: values.decodeIfPresent(String.self, forKey: .version),
            smoke: values.decodeIfPresent(Bool.self, forKey: .smoke),
            runtimeMode: .shadow
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(securityEpoch, forKey: .securityEpoch)
        try values.encode(implementationVersion, forKey: .implementationVersion)
        try values.encode(packageSchema, forKey: .packageSchema)
        try values.encodeIfPresent(packageVersion, forKey: .packageVersion)
        try values.encodeIfPresent(appReleaseVersion, forKey: .appReleaseVersion)
        try values.encodeIfPresent(appReleaseBuild, forKey: .appReleaseBuild)
        try values.encode(contentDigest, forKey: .contentDigest)
        try values.encodeIfPresent(packageRoot, forKey: .packageRoot)
        try values.encode(token, forKey: .token)
        try values.encode(socketPath, forKey: .socketPath)
        try values.encodeIfPresent(infoFile, forKey: .infoFile)
        try values.encodeIfPresent(lockFile, forKey: .lockFile)
        try values.encodeIfPresent(storageDir, forKey: .storageDir)
        try values.encodeIfPresent(logFile, forKey: .logFile)
        try values.encodeIfPresent(maximumLiveTerminals, forKey: .maximumLiveTerminals)
        try values.encodeIfPresent(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(version, forKey: .version)
        try values.encodeIfPresent(smoke, forKey: .smoke)
    }

    public static func load(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        try load(arguments: arguments, environment: environment, currentUserID: geteuid())
    }

    static func load(
        arguments: [String],
        environment: [String: String],
        currentUserID: uid_t
    ) throws -> Self {
        let shadowEnabled = environment[environmentMarker] == "1"
        let freshPTYEnabled = environment[freshPTYEnvironmentMarker] == "1"
        let launchEnabled = environment[launchEnvironmentMarker] == "1"
        guard [shadowEnabled, freshPTYEnabled, launchEnabled].filter({ $0 }).count <= 1 else {
            throw ShadowBrokerConfigurationError.ambiguousRuntimeMode
        }

        let runtimeMode: SwiftBrokerRuntimeMode
        if arguments.count == 3, arguments[1] == "--shadow-config" {
            guard shadowEnabled else {
                throw ShadowBrokerConfigurationError.shadowModeDisabled
            }
            runtimeMode = .shadow
        } else if arguments.count == 3, arguments[1] == "--fresh-pty-config" {
            guard freshPTYEnabled else {
                throw ShadowBrokerConfigurationError.freshPTYModeDisabled
            }
            runtimeMode = .freshPTY
        } else if arguments.count == 3, arguments[1] == "--launch" {
            guard launchEnabled else {
                throw ShadowBrokerConfigurationError.launchModeDisabled
            }
            runtimeMode = .launch
        } else {
            guard shadowEnabled || freshPTYEnabled || launchEnabled else {
                throw ShadowBrokerConfigurationError.shadowModeDisabled
            }
            throw ShadowBrokerConfigurationError.invalidArguments
        }

        let configurationPath = arguments[2]
        guard isCanonicalAbsolutePath(configurationPath) else {
            throw ShadowBrokerConfigurationError.unsafePath
        }
        let configurationURL = URL(fileURLWithPath: configurationPath)
        let privateRoot = configurationURL.deletingLastPathComponent()
        try validatePrivateRoot(privateRoot, currentUserID: currentUserID)
        let data = try readPrivateConfiguration(
            configurationURL,
            currentUserID: currentUserID
        )

        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.hasExactJSONKeys(Set(object.keys), runtimeMode: runtimeMode) else {
                throw ShadowBrokerConfigurationError.invalidConfiguration
            }
            let decoded = try JSONDecoder().decode(DecodedConfiguration.self, from: data)
            let configuration = try Self(
                protocolVersion: decoded.protocolVersion,
                securityEpoch: decoded.securityEpoch,
                implementationVersion: decoded.implementationVersion,
                packageSchema: decoded.packageSchema,
                packageVersion: decoded.packageVersion,
                appReleaseVersion: decoded.appReleaseVersion,
                appReleaseBuild: decoded.appReleaseBuild,
                contentDigest: decoded.contentDigest,
                packageRoot: decoded.packageRoot,
                token: decoded.token,
                socketPath: decoded.socketPath,
                infoFile: decoded.infoFile,
                lockFile: decoded.lockFile,
                storageDir: decoded.storageDir,
                logFile: decoded.logFile,
                maximumLiveTerminals: decoded.maximumLiveTerminals,
                startedAt: decoded.startedAt,
                version: decoded.version,
                smoke: decoded.smoke,
                runtimeMode: runtimeMode
            )
            switch runtimeMode {
            case .shadow, .freshPTY:
                guard configuration.privateRootURL == privateRoot else {
                    throw ShadowBrokerConfigurationError.unsafePath
                }
            case .launch:
                try configuration.validateLaunchLayout(configurationURL: configurationURL)
            }
            return configuration
        } catch let error as ShadowBrokerConfigurationError {
            throw error
        } catch {
            throw ShadowBrokerConfigurationError.invalidConfiguration
        }
    }

    private struct DecodedConfiguration: Decodable {
        let protocolVersion: Int
        let securityEpoch: Int
        let implementationVersion: Int
        let packageSchema: Int
        let packageVersion: String?
        let appReleaseVersion: String?
        let appReleaseBuild: String?
        let contentDigest: String
        let packageRoot: String?
        let token: String
        let socketPath: String
        let infoFile: String?
        let lockFile: String?
        let storageDir: String?
        let logFile: String?
        let maximumLiveTerminals: Int?
        let startedAt: Int64?
        let version: String?
        let smoke: Bool?

        private enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case securityEpoch
            case implementationVersion
            case packageSchema
            case packageVersion
            case appReleaseVersion
            case appReleaseBuild
            case contentDigest
            case packageRoot
            case token
            case socketPath
            case infoFile
            case lockFile
            case storageDir
            case logFile
            case maximumLiveTerminals
            case startedAt
            case version
            case smoke
        }
    }

    private static func hasExactJSONKeys(
        _ keys: Set<String>,
        runtimeMode: SwiftBrokerRuntimeMode
    ) -> Bool {
        switch runtimeMode {
        case .shadow, .freshPTY:
            keys == shadowJSONKeys
        case .launch:
            keys == launchJSONKeys || keys == nativeLaunchJSONKeys
        }
    }

    private func validateLaunchLayout(configurationURL: URL) throws {
        guard runtimeMode == .launch,
              configurationURL.lastPathComponent.hasPrefix("launch-native-"),
              configurationURL.pathExtension == "json",
              let packageRoot,
              let infoFile,
              let lockFile,
              let storageDir,
              let logFile else {
            throw ShadowBrokerConfigurationError.unsafePath
        }
        let brokerDirectory = configurationURL.deletingLastPathComponent().standardizedFileURL
        let userData = brokerDirectory.deletingLastPathComponent().standardizedFileURL
        guard brokerDirectory.lastPathComponent == "session-broker",
              URL(fileURLWithPath: packageRoot, isDirectory: true).standardizedFileURL
                == userData
                    .appendingPathComponent("broker-generations", isDirectory: true)
                    .appendingPathComponent(contentDigest, isDirectory: true)
                    .standardizedFileURL else {
            throw ShadowBrokerConfigurationError.unsafePath
        }

        let metadata = brokerDirectory.appendingPathComponent("generations", isDirectory: true)
        let expectedPaths = [
            infoFile: metadata.appendingPathComponent("\(contentDigest).json").path,
            lockFile: metadata.appendingPathComponent("\(contentDigest).lock").path,
            logFile: metadata.appendingPathComponent("\(contentDigest).log").path,
            storageDir: userData.appendingPathComponent("terminal-cache", isDirectory: true).path,
        ]
        guard expectedPaths.allSatisfy({
            URL(fileURLWithPath: $0.key).standardizedFileURL.path == $0.value
        }) else {
            throw ShadowBrokerConfigurationError.unsafePath
        }

        let socketLeaf = Self.generationSocketLeaf(userData: userData, contentDigest: contentDigest)
        let socketURL = URL(fileURLWithPath: socketPath).standardizedFileURL
        let durableSocket = brokerDirectory.appendingPathComponent(socketLeaf).path
        let compactRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kaisola-session", isDirectory: true)
            .standardizedFileURL.path
        let isDurable = socketURL.path == durableSocket
        let isCompact = socketURL.deletingLastPathComponent().path == compactRoot
            && socketURL.lastPathComponent == socketLeaf
        guard isDurable || isCompact else {
            throw ShadowBrokerConfigurationError.unsafePath
        }
    }

    private static func validatePrivateRoot(_ url: URL, currentUserID: uid_t) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_uid == currentUserID,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700 else {
            throw ShadowBrokerConfigurationError.unsafePermissions
        }
    }

    private static func readPrivateConfiguration(
        _ url: URL,
        currentUserID: uid_t
    ) throws -> Data {
        var before = stat()
        guard lstat(url.path, &before) == 0,
              before.st_uid == currentUserID,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o777 == 0o600,
              before.st_nlink == 1,
              before.st_size > 0,
              before.st_size <= maximumConfigurationBytes else {
            throw ShadowBrokerConfigurationError.unsafePermissions
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ShadowBrokerConfigurationError.unsafePermissions
        }
        defer { Darwin.close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino,
              opened.st_uid == currentUserID,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_mode & 0o777 == 0o600,
              opened.st_nlink == 1,
              opened.st_size == before.st_size else {
            throw ShadowBrokerConfigurationError.unsafePermissions
        }

        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw ShadowBrokerConfigurationError.invalidConfiguration
            }
            if count == 0 { break }
            guard data.count <= maximumConfigurationBytes - count else {
                throw ShadowBrokerConfigurationError.invalidConfiguration
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == opened.st_dev,
              after.st_ino == opened.st_ino,
              after.st_uid == opened.st_uid,
              after.st_mode == opened.st_mode,
              after.st_nlink == opened.st_nlink,
              after.st_size == opened.st_size,
              data.count == Int(opened.st_size) else {
            throw ShadowBrokerConfigurationError.unsafePermissions
        }
        return data
    }

    private static func isCanonicalAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !value.utf8.contains(0) else { return false }
        return URL(fileURLWithPath: value).standardizedFileURL.path == value
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isHexToken(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func isBoundedIdentity(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.utf8.contains(0)
    }

    private static func generationSocketLeaf(userData: URL, contentDigest: String) -> String {
        let material = Data((userData.standardizedFileURL.path + "\u{0}" + contentDigest).utf8)
        return Data(SHA256.hash(data: material).prefix(9))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_") + ".sock"
    }
}

public enum ShadowBrokerConfigurationError: Error, Equatable, LocalizedError {
    case shadowModeDisabled
    case freshPTYModeDisabled
    case launchModeDisabled
    case ambiguousRuntimeMode
    case invalidArguments
    case unsafePath
    case unsafePermissions
    case invalidConfiguration

    public var errorDescription: String? {
        switch self {
        case .shadowModeDisabled:
            "The Swift broker is available only in explicit shadow mode."
        case .freshPTYModeDisabled:
            "The Swift PTY broker is available only in explicit fresh-session development mode."
        case .launchModeDisabled:
            "The Swift PTY broker production launch is available only through explicit development selection."
        case .ambiguousRuntimeMode:
            "The Swift broker accepts exactly one explicit runtime mode."
        case .invalidArguments:
            "The Swift broker accepts only one exact private configuration argument."
        case .unsafePath:
            "The Swift broker configuration contains an unsafe path."
        case .unsafePermissions:
            "The Swift broker configuration is not private to this user."
        case .invalidConfiguration:
            "The Swift broker configuration is invalid."
        }
    }
}
