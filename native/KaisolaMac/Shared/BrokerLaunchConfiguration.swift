import Darwin
import CryptoKit
import Foundation
import KaisolaBrokerProtocol

struct BrokerLaunchConfiguration: Codable, Equatable, Sendable {
    static let generationMetadataDirectoryName = "generations"

    let protocolVersion: Int
    let securityEpoch: Int
    let implementationVersion: Int
    let packageSchema: Int
    let packageVersion: String
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
    let startedAt: Int64
    let version: String
    let smoke: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case securityEpoch, implementationVersion, packageSchema, packageVersion, contentDigest
        case packageRoot
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
              BrokerHelperPackageVerification.isLowercaseSHA256(contentDigest),
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
