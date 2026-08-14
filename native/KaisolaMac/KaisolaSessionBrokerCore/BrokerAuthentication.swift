import Darwin
import Foundation
import KaisolaBrokerProtocol

public struct ShadowBrokerServiceConfiguration: Equatable, Sendable {
    public let expectedToken: String
    public let expectedUID: UInt32
    public let packageSchema: Int
    public let packageVersion: String?
    public let contentDigest: String
    public let pid: Int32
    public let startedAt: Int64
    public let version: String

    public init(
        expectedToken: String,
        expectedUID: UInt32 = geteuid(),
        packageSchema: Int = BrokerWire.nativeHelperPackageSchema,
        packageVersion: String? = nil,
        contentDigest: String,
        pid: Int32 = getpid(),
        startedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        version: String = "kaisola-swift-shadow"
    ) throws {
        guard Self.isHex(expectedToken, exactBytes: 64) else {
            throw ShadowBrokerServiceConfigurationError.invalidToken
        }
        guard packageSchema == BrokerWire.nativeHelperPackageSchema else {
            throw ShadowBrokerServiceConfigurationError.invalidPackageSchema
        }
        guard Self.isLowercaseHex(contentDigest, exactBytes: 64) else {
            throw ShadowBrokerServiceConfigurationError.invalidContentDigest
        }
        if let packageVersion,
           packageVersion.isEmpty || packageVersion.utf8.count > 64 {
            throw ShadowBrokerServiceConfigurationError.invalidPackageVersion
        }
        guard pid > 0, startedAt > 0,
              !version.isEmpty, version.utf8.count <= 128 else {
            throw ShadowBrokerServiceConfigurationError.invalidRuntimeIdentity
        }

        self.expectedToken = expectedToken
        self.expectedUID = expectedUID
        self.packageSchema = packageSchema
        self.packageVersion = packageVersion
        self.contentDigest = contentDigest
        self.pid = pid
        self.startedAt = startedAt
        self.version = version
    }

    private static func isHex(_ value: String, exactBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == exactBytes && bytes.allSatisfy {
            (48...57).contains($0)
                || (65...70).contains($0)
                || (97...102).contains($0)
        }
    }

    private static func isLowercaseHex(_ value: String, exactBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == exactBytes && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public enum ShadowBrokerServiceConfigurationError: Error, Equatable, Sendable {
    case invalidToken
    case invalidPackageSchema
    case invalidPackageVersion
    case invalidContentDigest
    case invalidRuntimeIdentity
}

public struct BrokerAuthentication: Sendable {
    public static let advertisedFeatures = [
        BrokerWire.terminalObserveFeature,
        BrokerWire.observerRoleFeature,
        BrokerWire.brokerInventoryFeature,
    ]

    private let configuration: ShadowBrokerServiceConfiguration

    public init(configuration: ShadowBrokerServiceConfiguration) {
        self.configuration = configuration
    }

    public func authenticate(
        hello: BrokerHelloRequest,
        peerUID: UInt32
    ) -> BrokerAuthenticationResult {
        guard hello.type == "hello",
              hello.protocolVersion == BrokerWire.protocolVersion,
              peerUID == configuration.expectedUID,
              Self.constantTimeTokenMatch(
                  candidate: hello.token,
                  expected: configuration.expectedToken
              ),
              Self.isCanonicalVersionFourUUID(hello.instanceID),
              let access = hello.access,
              let role = BrokerAccessRole(rawValue: access),
              role == .controller || role == .observer else {
            return .rejected(response: Self.rejection())
        }

        let requested = Set(hello.features ?? [])
        let negotiated = Self.advertisedFeatures.filter(requested.contains)
        let client = BrokerAuthenticatedClient(
            instanceID: hello.instanceID,
            role: role,
            negotiatedFeatures: negotiated
        )
        let response = BrokerHelloResponse(
            ok: true,
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: configuration.packageSchema,
            packageVersion: configuration.packageVersion,
            contentDigest: configuration.contentDigest,
            features: Self.advertisedFeatures,
            negotiatedFeatures: negotiated,
            access: role.rawValue,
            pid: configuration.pid,
            startedAt: configuration.startedAt,
            version: configuration.version,
            runtimeKind: "swift"
        )
        return .accepted(client: client, response: response)
    }

    private static func rejection() -> BrokerHelloResponse {
        BrokerHelloResponse(ok: false, message: "broker authentication failed")
    }

    /// Compares exactly 64 token bytes and never returns from the comparison
    /// loop early. Length participates in the accumulated mismatch so a prefix,
    /// suffix, or differently-cased token cannot authenticate.
    private static func constantTimeTokenMatch(candidate: String, expected: String) -> Bool {
        let candidateBytes = Array(candidate.utf8)
        let expectedBytes = Array(expected.utf8)
        var mismatch = candidateBytes.count ^ expectedBytes.count
        for index in 0..<64 {
            let candidateByte = index < candidateBytes.count ? candidateBytes[index] : 0
            let expectedByte = index < expectedBytes.count ? expectedBytes[index] : 0
            mismatch |= Int(candidateByte ^ expectedByte)
        }
        return mismatch == 0
    }

    private static func isCanonicalVersionFourUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36,
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else { return false }
        let characters = Array(value.utf8)
        guard characters[14] == UInt8(ascii: "4") else { return false }
        return [UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b")]
            .contains(characters[19])
    }
}
