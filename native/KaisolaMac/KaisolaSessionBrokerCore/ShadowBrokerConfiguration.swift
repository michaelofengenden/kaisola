import Darwin
import Foundation

public enum SwiftBrokerRuntimeMode: String, Equatable, Sendable {
    case shadow
    case freshPTY
}

public struct ShadowBrokerConfiguration: Codable, Equatable, Sendable {
    private static let environmentMarker = "KAISOLA_SWIFT_BROKER_SHADOW"
    private static let freshPTYEnvironmentMarker = "KAISOLA_SWIFT_BROKER_FRESH_PTY"
    private static let maximumConfigurationBytes = 16 * 1_024
    private static let exactJSONKeys: Set<String> = [
        "protocol",
        "securityEpoch",
        "implementationVersion",
        "packageSchema",
        "contentDigest",
        "token",
        "socketPath",
    ]

    public let protocolVersion: Int
    public let securityEpoch: Int
    public let implementationVersion: Int
    public let packageSchema: Int
    public let contentDigest: String
    public let token: String
    public let socketPath: String
    public let runtimeMode: SwiftBrokerRuntimeMode

    public var socketURL: URL { URL(fileURLWithPath: socketPath) }
    public var privateRootURL: URL { socketURL.deletingLastPathComponent() }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case securityEpoch
        case implementationVersion
        case packageSchema
        case contentDigest
        case token
        case socketPath
    }

    public init(
        protocolVersion: Int,
        securityEpoch: Int,
        implementationVersion: Int,
        packageSchema: Int,
        contentDigest: String,
        token: String,
        socketPath: String,
        runtimeMode: SwiftBrokerRuntimeMode = .shadow
    ) throws {
        guard protocolVersion == 2,
              securityEpoch == 1,
              implementationVersion == 2,
              packageSchema == 2,
              Self.isLowercaseSHA256(contentDigest),
              Self.isHexToken(token) else {
            throw ShadowBrokerConfigurationError.invalidConfiguration
        }
        guard Self.isCanonicalAbsolutePath(socketPath) else {
            throw ShadowBrokerConfigurationError.unsafePath
        }

        self.protocolVersion = protocolVersion
        self.securityEpoch = securityEpoch
        self.implementationVersion = implementationVersion
        self.packageSchema = packageSchema
        self.contentDigest = contentDigest
        self.token = token
        self.socketPath = socketPath
        self.runtimeMode = runtimeMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: values.decode(Int.self, forKey: .protocolVersion),
            securityEpoch: values.decode(Int.self, forKey: .securityEpoch),
            implementationVersion: values.decode(Int.self, forKey: .implementationVersion),
            packageSchema: values.decode(Int.self, forKey: .packageSchema),
            contentDigest: values.decode(String.self, forKey: .contentDigest),
            token: values.decode(String.self, forKey: .token),
            socketPath: values.decode(String.self, forKey: .socketPath),
            runtimeMode: .shadow
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(securityEpoch, forKey: .securityEpoch)
        try values.encode(implementationVersion, forKey: .implementationVersion)
        try values.encode(packageSchema, forKey: .packageSchema)
        try values.encode(contentDigest, forKey: .contentDigest)
        try values.encode(token, forKey: .token)
        try values.encode(socketPath, forKey: .socketPath)
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
        guard !(shadowEnabled && freshPTYEnabled) else {
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
        } else {
            guard shadowEnabled || freshPTYEnabled else {
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
                  Set(object.keys) == exactJSONKeys else {
                throw ShadowBrokerConfigurationError.invalidConfiguration
            }
            let decoded = try JSONDecoder().decode(Self.self, from: data)
            let configuration = try Self(
                protocolVersion: decoded.protocolVersion,
                securityEpoch: decoded.securityEpoch,
                implementationVersion: decoded.implementationVersion,
                packageSchema: decoded.packageSchema,
                contentDigest: decoded.contentDigest,
                token: decoded.token,
                socketPath: decoded.socketPath,
                runtimeMode: runtimeMode
            )
            guard configuration.privateRootURL == privateRoot else {
                throw ShadowBrokerConfigurationError.unsafePath
            }
            return configuration
        } catch let error as ShadowBrokerConfigurationError {
            throw error
        } catch {
            throw ShadowBrokerConfigurationError.invalidConfiguration
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
}

public enum ShadowBrokerConfigurationError: Error, Equatable, LocalizedError {
    case shadowModeDisabled
    case freshPTYModeDisabled
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
        case .ambiguousRuntimeMode:
            "The Swift broker accepts exactly one explicit runtime mode."
        case .invalidArguments:
            "The Swift broker accepts only a private shadow configuration."
        case .unsafePath:
            "The Swift broker shadow configuration contains an unsafe path."
        case .unsafePermissions:
            "The Swift broker shadow configuration is not private to this user."
        case .invalidConfiguration:
            "The Swift broker shadow configuration is invalid."
        }
    }
}
