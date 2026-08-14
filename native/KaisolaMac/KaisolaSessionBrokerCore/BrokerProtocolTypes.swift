import Foundation

/// Runtime-local JSON representation for the broker executable. Keeping this
/// value type in the broker core avoids importing the GUI's models while still
/// preserving protocol-2 integer values exactly.
public enum BrokerJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([BrokerJSONValue])
    case object([String: BrokerJSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([BrokerJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: BrokerJSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var objectValue: [String: BrokerJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var arrayValue: [BrokerJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var integerValue: Int64? {
        switch self {
        case let .integer(value):
            value
        case let .number(value) where value.isFinite && value.rounded() == value:
            Int64(exactly: value)
        default:
            nil
        }
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }
}

public enum BrokerAccessRole: String, Codable, Equatable, Sendable {
    case controller
    case observer
    case administrator
}

public struct BrokerHelloRequest: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let token: String
    public let instanceID: String
    public let appVersion: String?
    public let access: String?
    public let features: [String]?

    public init(
        type: String = "hello",
        protocolVersion: Int,
        token: String,
        instanceID: String,
        appVersion: String? = nil,
        access: String?,
        features: [String]? = nil
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.token = token
        self.instanceID = instanceID
        self.appVersion = appVersion
        self.access = access
        self.features = features
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case token
        case instanceID = "instanceId"
        case appVersion
        case access
        case features
    }
}

public struct BrokerHelloResponse: Codable, Equatable, Sendable {
    public let type: String
    public let ok: Bool
    public let message: String?
    public let protocolVersion: Int?
    public let securityEpoch: Int?
    public let implementationVersion: Int?
    public let packageSchema: Int?
    public let packageVersion: String?
    public let contentDigest: String?
    public let features: [String]?
    public let negotiatedFeatures: [String]?
    public let access: String?
    public let pid: Int32?
    public let startedAt: Int64?
    public let version: String?
    public let runtimeKind: String?

    public init(
        type: String = "hello",
        ok: Bool,
        message: String? = nil,
        protocolVersion: Int? = nil,
        securityEpoch: Int? = nil,
        implementationVersion: Int? = nil,
        packageSchema: Int? = nil,
        packageVersion: String? = nil,
        contentDigest: String? = nil,
        features: [String]? = nil,
        negotiatedFeatures: [String]? = nil,
        access: String? = nil,
        pid: Int32? = nil,
        startedAt: Int64? = nil,
        version: String? = nil,
        runtimeKind: String? = nil
    ) {
        self.type = type
        self.ok = ok
        self.message = message
        self.protocolVersion = protocolVersion
        self.securityEpoch = securityEpoch
        self.implementationVersion = implementationVersion
        self.packageSchema = packageSchema
        self.packageVersion = packageVersion
        self.contentDigest = contentDigest
        self.features = features
        self.negotiatedFeatures = negotiatedFeatures
        self.access = access
        self.pid = pid
        self.startedAt = startedAt
        self.version = version
        self.runtimeKind = runtimeKind
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case ok
        case message
        case protocolVersion = "protocol"
        case securityEpoch
        case implementationVersion
        case packageSchema
        case packageVersion
        case contentDigest
        case features
        case negotiatedFeatures
        case access
        case pid
        case startedAt
        case version
        case runtimeKind
    }
}

public struct BrokerAuthenticatedClient: Codable, Equatable, Hashable, Sendable {
    /// Opaque authority for one successful hello. Including this value in the
    /// synthesized identity makes a later hello for the same instance replace
    /// the old connection without letting its eventual disconnect remove the
    /// replacement.
    private let registrationID: UUID
    public let instanceID: String
    public let role: BrokerAccessRole
    public let negotiatedFeatures: [String]

    public init(
        instanceID: String,
        role: BrokerAccessRole,
        negotiatedFeatures: [String]
    ) {
        self.registrationID = UUID()
        self.instanceID = instanceID
        self.role = role
        self.negotiatedFeatures = negotiatedFeatures
    }
}

public enum BrokerAuthenticationResult: Equatable, Sendable {
    case accepted(client: BrokerAuthenticatedClient, response: BrokerHelloResponse)
    case rejected(response: BrokerHelloResponse)
}

public struct BrokerRequest: Codable, Equatable, Sendable {
    public let type: String
    public let id: String
    public let method: String
    public let params: BrokerJSONValue?

    public init(
        type: String = "request",
        id: String,
        method: String,
        params: BrokerJSONValue? = nil
    ) {
        self.type = type
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct BrokerResponse: Codable, Equatable, Sendable {
    public let type: String
    public let id: String
    public let ok: Bool
    public let result: BrokerJSONValue?
    public let code: String?
    public let message: String?
    public let scope: String?
    public let limit: Int?

    public init(
        type: String = "response",
        id: String,
        ok: Bool,
        result: BrokerJSONValue? = nil,
        code: String? = nil,
        message: String? = nil,
        scope: String? = nil,
        limit: Int? = nil
    ) {
        self.type = type
        self.id = id
        self.ok = ok
        self.result = result
        self.code = code
        self.message = message
        self.scope = scope
        self.limit = limit
    }

    public static func success(id: String, result: BrokerJSONValue) -> BrokerResponse {
        BrokerResponse(id: id, ok: true, result: result)
    }

    public static func failure(
        id: String,
        code: String? = nil,
        message: String,
        scope: String? = nil,
        limit: Int? = nil
    ) -> BrokerResponse {
        BrokerResponse(
            id: id,
            ok: false,
            code: code,
            message: message,
            scope: scope,
            limit: limit
        )
    }
}
