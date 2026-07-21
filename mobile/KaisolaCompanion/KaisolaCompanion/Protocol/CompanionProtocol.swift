import Foundation

enum CompanionProtocolError: Error, Equatable {
    case frameTooLarge
    case protocolMismatch(Int)
    case unknownKind(String)
    case unknownType(String)
    case invalidIdentifier(String)
    case invalidNumber(String)
    case invalidBody(String)
    case unknownField(String)
}

enum CompanionEnvelopeKind: String, Codable, CaseIterable, Sendable {
    case hello
    case event
    case command
    case receipt
    case snapshot
    case ack
    case error
}

enum CompanionCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case observe
    case agentControl = "agent-control"
    case terminalControl = "terminal-control"
}

struct CompanionBody: Codable, Hashable, Sendable {
    let fields: [String: JSONValue]

    init(fields: [String: JSONValue]) throws {
        guard fields["type"]?.stringValue != nil else {
            throw CompanionProtocolError.invalidBody("body.type")
        }
        self.fields = fields
    }

    init<T: Encodable>(_ value: T) throws {
        guard case let .object(fields) = try JSONValue.from(value) else {
            throw CompanionProtocolError.invalidBody("body")
        }
        try self.init(fields: fields)
    }

    init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(fields) = value else {
            throw CompanionProtocolError.invalidBody("body")
        }
        try self.init(fields: fields)
    }

    func encode(to encoder: Encoder) throws {
        try JSONValue.object(fields).encode(to: encoder)
    }

    var type: String { fields["type"]?.stringValue ?? "" }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: CanonicalJSON.data(from: .object(fields)))
    }
}

struct CompanionEnvelope: Codable, Hashable, Sendable {
    static let protocolVersion = 1
    static let protocolMinor = 0
    static let maximumBytes = 1_024 * 1_024

    let v: Int
    let kind: CompanionEnvelopeKind
    let desktopId: String
    let deviceId: String
    let connectionId: String
    let epoch: String
    let seq: Int64
    let id: String
    let sentAt: Int64
    let body: CompanionBody

    init(
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

    init(from decoder: Decoder) throws {
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

    static let eventTypes: Set<String> = [
        "desktop.status", "project.updated", "session.updated", "attention.raised", "attention.cleared",
        "agent.turn.delta", "agent.turn.completed", "agent.permission.requested", "agent.permission.resolved",
        "terminal.snapshot", "terminal.output", "terminal.exit", "ledger.task.updated",
    ]

    static let commandCapabilities: [String: CompanionCapability] = [
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

enum CompanionProtocolCodec {
    static func decode(_ data: Data) throws -> CompanionEnvelope {
        guard !data.isEmpty, data.count <= CompanionEnvelope.maximumBytes else {
            throw CompanionProtocolError.frameTooLarge
        }
        return try JSONDecoder().decode(CompanionEnvelope.self, from: data)
    }

    static func encode(_ envelope: CompanionEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= CompanionEnvelope.maximumBytes else { throw CompanionProtocolError.frameTooLarge }
        return data
    }
}

enum CompanionPeerRole: String, Codable, Sendable {
    case desktop
    case device
}

struct CompanionHelloBody: Codable, Hashable, Sendable {
    let type: String
    let role: CompanionPeerRole
    let protocolMinor: Int?
    let capabilities: [CompanionCapability]
    let lastAck: Int64?
    let transportHint: CompanionPairingTransportHint?

    init(
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

struct CompanionAckBody: Codable, Hashable, Sendable {
    let type: String
    let ackSeq: Int64

    init(ackSeq: Int64) {
        type = "ack"
        self.ackSeq = ackSeq
    }
}

enum CompanionReceiptStatus: String, Codable, CaseIterable, Sendable {
    case accepted, applied, rejected, stale, unavailable
    case timedOut = "timed_out"
}

struct CompanionReceiptBody: Codable, Hashable, Sendable {
    let type: String
    let commandId: String
    let status: CompanionReceiptStatus
    let message: String?
    let payload: [String: JSONValue]?
}

struct CompanionErrorBody: Codable, Hashable, Sendable {
    let type: String
    let code: String
    let message: String
}

struct CompanionCommandBody: Codable, Hashable, Sendable {
    let type: String
    let commandId: String
    let projectId: String
    let targetId: String
    let capability: CompanionCapability
    let expectedRevision: Int64?
    let payload: [String: JSONValue]?
}

struct CompanionAgentTurnDeltaBody: Codable, Hashable, Sendable {
    let type: String
    let projectId: String
    let targetId: String?
    let sessionId: String?
    let turnId: String
    let delta: JSONValue
}

struct CompanionPermissionRequestedBody: Codable, Hashable, Sendable {
    let type: String
    let projectId: String
    let targetId: String?
    let sessionId: String?
    let permId: String
    let revision: Int64?
    let completeness: String?
    let agent: String
    let title: String
    let kind: String?
    let requestedAt: Int64?
    let options: [CompanionPermissionOption]
    let diffs: [CompanionPermissionDiff]
}

struct CompanionTerminalOutputBody: Codable, Hashable, Sendable {
    let type: String
    let projectId: String
    let terminalId: String
    let streamEpoch: String
    let startOffset: Int64
    let endOffset: Int64
    let data: String
}

struct CompanionTerminalCursorFixture: Codable, Hashable, Sendable {
    struct Chunk: Codable, Hashable, Sendable {
        let data: String
        let startOffset: Int64
        let endOffset: Int64
    }

    struct Snapshot: Codable, Hashable, Sendable {
        let output: String
        let startOffset: Int64
        let endOffset: Int64
        let truncated: Bool
    }

    let streamEpoch: String
    let chunks: [Chunk]
    let snapshot: Snapshot
}

struct CompanionAckCursor: Codable, Hashable, Sendable {
    var epoch: String
    var seq: Int64

    mutating func accept(_ envelope: CompanionEnvelope) -> Bool {
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
