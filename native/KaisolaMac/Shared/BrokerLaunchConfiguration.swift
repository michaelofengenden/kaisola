import Darwin
import Foundation
import KaisolaBrokerProtocol

struct BrokerLaunchConfiguration: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let securityEpoch: Int
    let implementationVersion: Int
    let packageSchema: Int
    let packageVersion: String
    let token: String
    let socketPath: String
    let infoFile: String
    let lockFile: String
    let storageDir: String
    let logFile: String
    let startedAt: Int64
    let version: String
    let smoke: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case securityEpoch, implementationVersion, packageSchema, packageVersion
        case token, socketPath, infoFile, lockFile, storageDir, logFile
        case startedAt, version, smoke
    }

    func validate(
        configurationURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard protocolVersion == BrokerWire.protocolVersion,
              securityEpoch == BrokerWire.securityEpoch,
              BrokerWire.compatibleImplementationVersions.contains(implementationVersion),
              packageSchema == BrokerWire.helperPackageSchema,
              !packageVersion.isEmpty,
              packageVersion.count <= 64,
              token.count == 64,
              token.allSatisfy(\.isHexDigit),
              startedAt > 0,
              !version.isEmpty,
              version.count <= 120,
              !smoke else {
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

        let exactBrokerFiles = [
            infoFile: brokerDirectory.appendingPathComponent("broker.json").path,
            lockFile: brokerDirectory.appendingPathComponent("broker.lock").path,
            logFile: brokerDirectory.appendingPathComponent("broker.log").path,
            storageDir: userData.appendingPathComponent("terminal-cache", isDirectory: true).path,
        ]
        guard exactBrokerFiles.allSatisfy({ URL(fileURLWithPath: $0.key).standardizedFileURL.path == $0.value }) else {
            throw BrokerLaunchConfigurationError.unsafePath
        }

        let durableSocket = brokerDirectory.appendingPathComponent("broker.sock").path
        let compactRoot = homeDirectory.appendingPathComponent(".kaisola-session", isDirectory: true).standardizedFileURL.path
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
