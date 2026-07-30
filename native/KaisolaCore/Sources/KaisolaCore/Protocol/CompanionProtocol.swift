import Foundation

public enum CompanionProtocolError: Error, Equatable {
    case frameTooLarge
    case protocolMismatch(Int)
    case unknownKind(String)
    case unknownType(String)
    case invalidIdentifier(String)
    case invalidNumber(String)
    case invalidBody(String)
    case unknownField(String)
}

public enum CompanionEnvelopeKind: String, Codable, CaseIterable, Sendable {
    case hello
    case event
    case command
    case receipt
    case snapshot
    case ack
    case error
}

public enum CompanionCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case observe
    case agentControl = "agent-control"
    case terminalControl = "terminal-control"
}

public struct CompanionBody: Codable, Hashable, Sendable {
    public let fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) throws {
        guard fields["type"]?.stringValue != nil else {
            throw CompanionProtocolError.invalidBody("body.type")
        }
        self.fields = fields
    }

    public init<T: Encodable>(_ value: T) throws {
        guard case let .object(fields) = try JSONValue.from(value) else {
            throw CompanionProtocolError.invalidBody("body")
        }
        try self.init(fields: fields)
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(fields) = value else {
            throw CompanionProtocolError.invalidBody("body")
        }
        try self.init(fields: fields)
    }

    public func encode(to encoder: Encoder) throws {
        try JSONValue.object(fields).encode(to: encoder)
    }

    public var type: String { fields["type"]?.stringValue ?? "" }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: CanonicalJSON.data(from: .object(fields)))
    }
}

public struct CompanionEnvelope: Codable, Hashable, Sendable {
    public static let protocolVersion = 1
    public static let protocolMinor = 0
    public static let maximumBytes = 1_024 * 1_024

    public let v: Int
    public let kind: CompanionEnvelopeKind
    public let desktopId: String
    public let deviceId: String
    public let connectionId: String
    public let epoch: String
    public let seq: Int64
    public let id: String
    public let sentAt: Int64
    public let body: CompanionBody

    public init(
        v: Int = protocolVersion,
        kind: CompanionEnvelopeKind,
        desktopId: String,
        deviceId: String,
        connectionId: String,
        epoch: String,
        seq: Int64,
        id: String,
        sentAt: Int64,
        body: CompanionBody
    ) throws {
        self.v = v
        self.kind = kind
        self.desktopId = desktopId
        self.deviceId = deviceId
        self.connectionId = connectionId
        self.epoch = epoch
        self.seq = seq
        self.id = id
        self.sentAt = sentAt
        self.body = body
        try validate()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case v, kind, desktopId, deviceId, connectionId, epoch, seq, id, sentAt, body
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = dynamic.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw CompanionProtocolError.unknownField(unknown.stringValue)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        kind = try container.decode(CompanionEnvelopeKind.self, forKey: .kind)
        desktopId = try container.decode(String.self, forKey: .desktopId)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        connectionId = try container.decode(String.self, forKey: .connectionId)
        epoch = try container.decode(String.self, forKey: .epoch)
        seq = try container.decode(Int64.self, forKey: .seq)
        id = try container.decode(String.self, forKey: .id)
        sentAt = try container.decode(Int64.self, forKey: .sentAt)
        body = try container.decode(CompanionBody.self, forKey: .body)
        try validate()
    }

    private func validate() throws {
        guard v == Self.protocolVersion else { throw CompanionProtocolError.protocolMismatch(v) }
        try Self.validateIdentifier(desktopId, label: "desktopId")
        try Self.validateIdentifier(deviceId, label: "deviceId")
        try Self.validateIdentifier(connectionId, label: "connectionId")
        try Self.validateIdentifier(epoch, label: "epoch")
        try Self.validateIdentifier(id, label: "id")
        guard seq >= 0, seq <= 9_007_199_254_740_991 else {
            throw CompanionProtocolError.invalidNumber("seq")
        }
        guard sentAt >= 0, sentAt <= 9_007_199_254_740_991 else {
            throw CompanionProtocolError.invalidNumber("sentAt")
        }

        let allowedTypes: Set<String>
        switch kind {
        case .hello: allowedTypes = ["hello"]
        case .event: allowedTypes = Self.eventTypes
        case .command: allowedTypes = Set(Self.commandCapabilities.keys)
        case .receipt: allowedTypes = ["command.receipt"]
        case .snapshot: allowedTypes = ["snapshot.projects", "terminal.snapshot"]
        case .ack: allowedTypes = ["ack"]
        case .error: allowedTypes = ["error"]
        }
        guard allowedTypes.contains(body.type) else { throw CompanionProtocolError.unknownType(body.type) }

        if kind == .hello {
            let hello = try body.decode(CompanionHelloBody.self)
            guard hello.role == .desktop || hello.role == .device else {
                throw CompanionProtocolError.invalidBody("body.role")
            }
            if let protocolMinor = hello.protocolMinor,
               protocolMinor < 0 || protocolMinor > 10_000 {
                throw CompanionProtocolError.invalidNumber("body.protocolMinor")
            }
            if let lastAck = hello.lastAck,
               lastAck < 0 || lastAck > 9_007_199_254_740_991 {
                throw CompanionProtocolError.invalidNumber("body.lastAck")
            }
            try Self.validateCapabilities(hello.capabilities)
            try hello.transportHint?.validate()
        } else if kind == .snapshot {
            if let value = body.fields["revision"] {
                guard let revision = value.intValue,
                      revision >= 0,
                      revision <= 9_007_199_254_740_991 else {
                    throw CompanionProtocolError.invalidNumber("body.revision")
                }
            }
        } else if kind == .command {
            let command = try body.decode(CompanionCommandBody.self)
            try Self.validateIdentifier(command.commandId, label: "body.commandId")
            try Self.validateIdentifier(command.projectId, label: "body.projectId", maximum: 240)
            try Self.validateIdentifier(command.targetId, label: "body.targetId", maximum: 240)
            guard command.commandId == id,
                  Self.commandCapabilities[command.type] == command.capability else {
                throw CompanionProtocolError.invalidBody("body.commandId/capability")
            }
            if let revision = command.expectedRevision,
               revision < 0 || revision > 9_007_199_254_740_991 {
                throw CompanionProtocolError.invalidNumber("body.expectedRevision")
            }
        } else if kind == .receipt {
            let receipt = try body.decode(CompanionReceiptBody.self)
            try Self.validateIdentifier(receipt.commandId, label: "body.commandId")
            guard CompanionReceiptStatus.allCases.contains(receipt.status) else {
                throw CompanionProtocolError.invalidBody("body.status")
            }
            if let message = receipt.message, message.count > 800 {
                throw CompanionProtocolError.invalidBody("body.message")
            }
        } else if kind == .ack {
            let ack = try body.decode(CompanionAckBody.self)
            guard ack.ackSeq >= 0, ack.ackSeq <= 9_007_199_254_740_991 else {
                throw CompanionProtocolError.invalidNumber("body.ackSeq")
            }
        } else if kind == .error {
            let error = try body.decode(CompanionErrorBody.self)
            try Self.validateIdentifier(error.code, label: "body.code", maximum: 80)
            guard !error.message.isEmpty, error.message.count <= 800 else {
                throw CompanionProtocolError.invalidBody("body.message")
            }
        }
    }

    private static func validateIdentifier(_ value: String, label: String, maximum: Int = 160) throws {
        guard !value.isEmpty, value.count <= maximum,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:@-]*$"#, options: .regularExpression) != nil else {
            throw CompanionProtocolError.invalidIdentifier(label)
        }
    }

    private static func validateCapabilities(_ capabilities: [CompanionCapability]) throws {
        guard capabilities.count <= CompanionCapability.allCases.count,
              Set(capabilities).count == capabilities.count else {
            throw CompanionProtocolError.invalidBody("body.capabilities")
        }
    }

    public static let eventTypes: Set<String> = [
        "desktop.status", "project.updated", "session.updated", "attention.raised", "attention.cleared",
        "agent.turn.delta", "agent.turn.completed", "agent.permission.requested", "agent.permission.resolved",
        "terminal.snapshot", "terminal.output", "terminal.exit", "ledger.task.updated",
    ]

    public static let commandCapabilities: [String: CompanionCapability] = [
        "attention.ack": .observe,
        "stream.subscribe": .observe,
        "stream.unsubscribe": .observe,
        "agent.prompt": .agentControl,
        "agent.steer": .agentControl,
        "agent.cancel": .agentControl,
        "permission.respond": .agentControl,
        "terminal.acquire-control": .terminalControl,
        "terminal.renew-control": .terminalControl,
        "terminal.write": .terminalControl,
        "terminal.resize": .terminalControl,
        "terminal.interrupt": .terminalControl,
        "terminal.release-control": .terminalControl,
    ]
}

public enum CompanionProtocolCodec {
    public static func decode(_ data: Data) throws -> CompanionEnvelope {
        guard !data.isEmpty, data.count <= CompanionEnvelope.maximumBytes else {
            throw CompanionProtocolError.frameTooLarge
        }
        return try JSONDecoder().decode(CompanionEnvelope.self, from: data)
    }

    public static func encode(_ envelope: CompanionEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= CompanionEnvelope.maximumBytes else { throw CompanionProtocolError.frameTooLarge }
        return data
    }
}

public enum CompanionPeerRole: String, Codable, Sendable {
    case desktop
    case device
}

public struct CompanionHelloBody: Codable, Hashable, Sendable {
    public let type: String
    public let role: CompanionPeerRole
    public let protocolMinor: Int?
    public let capabilities: [CompanionCapability]
    public let lastAck: Int64?
    public let transportHint: CompanionPairingTransportHint?

    public init(
        role: CompanionPeerRole,
        capabilities: [CompanionCapability],
        lastAck: Int64? = nil,
        transportHint: CompanionPairingTransportHint? = nil
    ) {
        type = "hello"
        self.role = role
        protocolMinor = CompanionEnvelope.protocolMinor
        self.capabilities = capabilities
        self.lastAck = lastAck
        self.transportHint = transportHint
    }
}

public struct CompanionAckBody: Codable, Hashable, Sendable {
    public let type: String
    public let ackSeq: Int64

    public init(ackSeq: Int64) {
        type = "ack"
        self.ackSeq = ackSeq
    }
}

public enum CompanionReceiptStatus: String, Codable, CaseIterable, Sendable {
    case accepted, applied, rejected, stale, unavailable
    case timedOut = "timed_out"
}

public struct CompanionReceiptBody: Codable, Hashable, Sendable {
    public let type: String
    public let commandId: String
    public let status: CompanionReceiptStatus
    public let message: String?
    public let payload: [String: JSONValue]?

    public init(
        type: String,
        commandId: String,
        status: CompanionReceiptStatus,
        message: String?,
        payload: [String: JSONValue]?
    ) {
        self.type = type
        self.commandId = commandId
        self.status = status
        self.message = message
        self.payload = payload
    }
}

public struct CompanionErrorBody: Codable, Hashable, Sendable {
    public let type: String
    public let code: String
    public let message: String

    public init(type: String, code: String, message: String) {
        self.type = type
        self.code = code
        self.message = message
    }
}

public struct CompanionCommandBody: Codable, Hashable, Sendable {
    public let type: String
    public let commandId: String
    public let projectId: String
    public let targetId: String
    public let capability: CompanionCapability
    public let expectedRevision: Int64?
    public let payload: [String: JSONValue]?

    public init(
        type: String,
        commandId: String,
        projectId: String,
        targetId: String,
        capability: CompanionCapability,
        expectedRevision: Int64?,
        payload: [String: JSONValue]?
    ) {
        self.type = type
        self.commandId = commandId
        self.projectId = projectId
        self.targetId = targetId
        self.capability = capability
        self.expectedRevision = expectedRevision
        self.payload = payload
    }
}

public struct CompanionAgentTurnDeltaBody: Codable, Hashable, Sendable {
    public let type: String
    public let projectId: String
    public let targetId: String?
    public let sessionId: String?
    public let turnId: String
    public let delta: JSONValue

    public init(
        type: String,
        projectId: String,
        targetId: String?,
        sessionId: String?,
        turnId: String,
        delta: JSONValue
    ) {
        self.type = type
        self.projectId = projectId
        self.targetId = targetId
        self.sessionId = sessionId
        self.turnId = turnId
        self.delta = delta
    }
}

public struct CompanionPermissionRequestedBody: Codable, Hashable, Sendable {
    public let type: String
    public let projectId: String
    public let targetId: String?
    public let sessionId: String?
    public let permId: String
    public let revision: Int64?
    public let completeness: String?
    public let agent: String
    public let title: String
    public let kind: String?
    public let requestedAt: Int64?
    public let options: [CompanionPermissionOption]
    public let diffs: [CompanionPermissionDiff]

    public init(
        type: String,
        projectId: String,
        targetId: String?,
        sessionId: String?,
        permId: String,
        revision: Int64?,
        completeness: String?,
        agent: String,
        title: String,
        kind: String?,
        requestedAt: Int64?,
        options: [CompanionPermissionOption],
        diffs: [CompanionPermissionDiff]
    ) {
        self.type = type
        self.projectId = projectId
        self.targetId = targetId
        self.sessionId = sessionId
        self.permId = permId
        self.revision = revision
        self.completeness = completeness
        self.agent = agent
        self.title = title
        self.kind = kind
        self.requestedAt = requestedAt
        self.options = options
        self.diffs = diffs
    }
}

public struct CompanionTerminalOutputBody: Codable, Hashable, Sendable {
    public let type: String
    public let projectId: String
    public let terminalId: String
    public let streamEpoch: String
    public let startOffset: Int64
    public let endOffset: Int64
    public let data: String

    public init(
        type: String,
        projectId: String,
        terminalId: String,
        streamEpoch: String,
        startOffset: Int64,
        endOffset: Int64,
        data: String
    ) {
        self.type = type
        self.projectId = projectId
        self.terminalId = terminalId
        self.streamEpoch = streamEpoch
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.data = data
    }
}

public struct CompanionTerminalCursorFixture: Codable, Hashable, Sendable {
    public struct Chunk: Codable, Hashable, Sendable {
        public let data: String
        public let startOffset: Int64
        public let endOffset: Int64

        public init(data: String, startOffset: Int64, endOffset: Int64) {
            self.data = data
            self.startOffset = startOffset
            self.endOffset = endOffset
        }
    }

    public struct Snapshot: Codable, Hashable, Sendable {
        public let output: String
        public let startOffset: Int64
        public let endOffset: Int64
        public let truncated: Bool

        public init(output: String, startOffset: Int64, endOffset: Int64, truncated: Bool) {
            self.output = output
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.truncated = truncated
        }
    }

    public let streamEpoch: String
    public let chunks: [Chunk]
    public let snapshot: Snapshot

    public init(streamEpoch: String, chunks: [Chunk], snapshot: Snapshot) {
        self.streamEpoch = streamEpoch
        self.chunks = chunks
        self.snapshot = snapshot
    }
}

public struct CompanionAckCursor: Codable, Hashable, Sendable {
    public var epoch: String
    public var seq: Int64

    public init(epoch: String, seq: Int64) {
        self.epoch = epoch
        self.seq = seq
    }

    public mutating func accept(_ envelope: CompanionEnvelope) -> Bool {
        guard envelope.kind == .snapshot || envelope.kind == .event else { return false }
        if envelope.kind == .snapshot {
            epoch = envelope.epoch
            seq = envelope.seq
            return true
        }
        guard envelope.epoch == epoch, envelope.seq > seq else { return false }
        seq = envelope.seq
        return true
    }
}
