import Foundation

/// Constants mirrored from `runtime/node-broker/ipc/brokerWire.cjs`.
///
/// JavaScript and Swift tests pin these values so a client cannot silently
/// connect with different ownership or framing assumptions.
public enum BrokerWire {
    public static let protocolVersion = 2
    public static let securityEpoch = 1
    public static let implementationVersion = 2
    public static let helperPackageSchema = 1
    /// Protocol-2 implementation N and N+1 are additive-compatible. A future
    /// implementation that needs a wire break must increment `protocolVersion`
    /// rather than widening this range silently.
    public static let compatibleImplementationVersions = 1...2
    public static let terminalObserveFeature = "terminal-observe-v1"
    public static let terminalHistoryFeature = "terminal-history-v1"
    public static let observerRoleFeature = "observer-role-v1"
    public static let brokerUpdateFeature = "broker-update-v1"
    public static let brokerRollingUpdateFeature = "broker-rolling-update-v1"
    public static let brokerMutationIdempotencyFeature = "broker-mutation-idempotency-v1"
    public static let brokerInventoryFeature = "broker-inventory-v1"
    public static let brokerAdministrationFeature = "broker-administration-v1"
    public static let observerMethods: Set<String> = [
        "broker.status",
        "broker.inventory",
        "terminal.list",
        "terminal.diagnostics",
        "terminal.history",
        "terminal.subscribe",
        "terminal.unsubscribe",
    ]
    public static let maximumFrameBytes = 56 * 1_024 * 1_024
    public static let terminalHistoryPageBytes = 4 * 1_024 * 1_024

    /// The transport ceiling only exists for the two snapshot-shaped replies
    /// which may contain an 8 MiB terminal tail after worst-case JSON escaping.
    /// Every other frame is rejected against the narrower contract selected by
    /// its request method or event channel before it reaches JSONDecoder.
    public static func maximumEncodedBytes(for purpose: BrokerFramePurpose) -> Int {
        switch purpose {
        case .hello:
            64 * 1_024
        case let .request(method):
            switch method {
            case "terminal.write": 1 * 1_024 * 1_024
            case "terminal.create": 256 * 1_024
            default: 64 * 1_024
            }
        case let .response(method):
            switch method {
            case "terminal.create", "terminal.attach", "terminal.snapshot", "terminal.output":
                50 * 1_024 * 1_024
            case "terminal.history", "terminal.subscribe":
                26 * 1_024 * 1_024
            case "broker.status", "terminal.list", "terminal.diagnostics":
                4 * 1_024 * 1_024
            case "broker.inventory":
                12 * 1_024 * 1_024
            default:
                256 * 1_024
            }
        case let .event(channel):
            channel == "terminal:observer-output" ? 512 * 1_024 : 64 * 1_024
        case .unknown:
            64 * 1_024
        }
    }

    public static func purpose(
        for envelope: BrokerFrameEnvelope,
        responseMethod: (String) -> String?
    ) -> BrokerFramePurpose {
        switch envelope.type {
        case "hello":
            return .hello
        case "request":
            return envelope.method.map(BrokerFramePurpose.request) ?? .unknown
        case "response":
            guard let id = envelope.id else { return .unknown }
            return .response(responseMethod(id))
        case "event":
            return envelope.channel.map(BrokerFramePurpose.event) ?? .unknown
        default:
            return .unknown
        }
    }

    public static func validateEncodedFrame(
        _ data: Data,
        purpose: BrokerFramePurpose
    ) throws {
        let maximum = maximumEncodedBytes(for: purpose)
        guard data.count <= maximum else {
            throw BrokerWireError.frameTooLarge(maximum: maximum)
        }
    }

    /// Resolves only the small top-level routing strings. Nested params,
    /// results, and event payloads are skipped in-place without constructing a
    /// JSON object, so a legal transport frame cannot allocate a 56 MiB
    /// JSONValue merely to discover that its method limit is 64 KiB.
    public static func validateDecodedFrame(
        _ data: Data,
        responseMethod: (String) -> String?
    ) throws -> BrokerFrameEnvelope {
        let envelope = try BrokerFrameEnvelope(data: data)
        try validateEncodedFrame(
            data,
            purpose: purpose(for: envelope, responseMethod: responseMethod)
        )
        return envelope
    }

    public static func accepts(
        protocolVersion: Int,
        securityEpoch: Int,
        implementationVersion: Int?
    ) -> Bool {
        guard protocolVersion == self.protocolVersion,
              securityEpoch == self.securityEpoch else { return false }
        // Protocol-2 brokers shipped before independent implementation
        // metadata. They are implementation N for compatibility purposes.
        return compatibleImplementationVersions.contains(implementationVersion ?? 1)
    }
}

public enum BrokerWireError: Error, Equatable, Sendable {
    case frameTooLarge(maximum: Int)
    case invalidUTF8
    case incompleteFrame
    case invalidEnvelope
}

public enum BrokerFramePurpose: Equatable, Sendable {
    case hello
    case request(String)
    case response(String?)
    case event(String)
    case unknown
}

public struct BrokerFrameEnvelope: Equatable, Sendable {
    public let type: String?
    public let id: String?
    public let method: String?
    public let channel: String?

    public init(data: Data) throws {
        self = try data.withUnsafeBytes { rawBuffer in
            var scanner = BrokerEnvelopeScanner(bytes: rawBuffer)
            return try scanner.scan()
        }
    }

    init(type: String?, id: String?, method: String?, channel: String?) {
        self.type = type
        self.id = id
        self.method = method
        self.channel = channel
    }
}

private struct BrokerEnvelopeScanner {
    private let bytes: UnsafeRawBufferPointer
    private var cursor = 0

    init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func scan() throws -> BrokerFrameEnvelope {
        skipWhitespace()
        guard consume(0x7B) else { throw BrokerWireError.invalidEnvelope } // {

        var type: String?
        var id: String?
        var method: String?
        var channel: String?
        var first = true

        while true {
            skipWhitespace()
            if consume(0x7D) { break } // }
            if first {
                first = false
            } else {
                guard consume(0x2C) else { throw BrokerWireError.invalidEnvelope } // ,
                skipWhitespace()
            }

            let keyRange = try scanString()
            let key = try decodeString(in: keyRange, maximumBytes: 96)
            skipWhitespace()
            guard consume(0x3A) else { throw BrokerWireError.invalidEnvelope } // :
            skipWhitespace()

            if key == "type" || key == "id" || key == "method" || key == "channel" {
                guard peek() == 0x22 else { // "
                    try skipValue()
                    continue
                }
                let value = try decodeString(in: scanString(), maximumBytes: 512)
                switch key {
                case "type": type = value
                case "id": id = value
                case "method": method = value
                case "channel": channel = value
                default: break
                }
            } else {
                try skipValue()
            }
        }

        skipWhitespace()
        guard cursor == bytes.count else { throw BrokerWireError.invalidEnvelope }
        return BrokerFrameEnvelope(type: type, id: id, method: method, channel: channel)
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            cursor += 1
        }
    }

    private func peek() -> UInt8? {
        guard cursor < bytes.count else { return nil }
        return bytes[cursor]
    }

    private mutating func consume(_ expected: UInt8) -> Bool {
        guard peek() == expected else { return false }
        cursor += 1
        return true
    }

    /// Returns a range including both quotes.
    private mutating func scanString() throws -> Range<Int> {
        guard consume(0x22) else { throw BrokerWireError.invalidEnvelope }
        let start = cursor - 1
        var escaped = false
        while cursor < bytes.count {
            let byte = bytes[cursor]
            cursor += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C { // \
                escaped = true
            } else if byte == 0x22 { // "
                return start..<cursor
            }
        }
        throw BrokerWireError.invalidEnvelope
    }

    private func decodeString(in range: Range<Int>, maximumBytes: Int) throws -> String? {
        guard range.count <= maximumBytes else { return nil }
        let token = Data(bytes[range])
        do {
            return try JSONDecoder().decode(String.self, from: token)
        } catch {
            throw BrokerWireError.invalidEnvelope
        }
    }

    private mutating func skipValue() throws {
        guard let byte = peek() else { throw BrokerWireError.invalidEnvelope }
        if byte == 0x22 {
            _ = try scanString()
            return
        }
        if byte == 0x7B || byte == 0x5B { // { or [
            var depth = 0
            while cursor < bytes.count {
                let current = bytes[cursor]
                if current == 0x22 {
                    _ = try scanString()
                    continue
                }
                cursor += 1
                if current == 0x7B || current == 0x5B {
                    depth += 1
                } else if current == 0x7D || current == 0x5D {
                    depth -= 1
                    if depth == 0 { return }
                }
            }
            throw BrokerWireError.invalidEnvelope
        }

        let start = cursor
        while let current = peek(), current != 0x2C, current != 0x7D { cursor += 1 }
        guard cursor > start else { throw BrokerWireError.invalidEnvelope }
    }
}

/// Incrementally splits the broker's newline-delimited JSON transport without
/// ever buffering more than one legal frame plus its delimiter.
public struct BrokerLineFrameDecoder: Sendable {
    public let maximumFrameBytes: Int
    public private(set) var bufferedByteCount = 0

    private var buffer = Data()

    public init(maximumFrameBytes: Int = BrokerWire.maximumFrameBytes) {
        precondition(maximumFrameBytes > 0)
        self.maximumFrameBytes = maximumFrameBytes
    }

    /// Delivers frames synchronously so the caller controls backpressure and
    /// the decoder never retains an entire socket read or a batch of frames.
    public mutating func consume(
        _ chunk: Data,
        onFrame: (Data) throws -> Void
    ) throws {
        guard !chunk.isEmpty else { return }
        defer { bufferedByteCount = buffer.count }

        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            if let newline = chunk[cursor...].firstIndex(of: 0x0A) {
                let segment = chunk[cursor..<newline]
                guard segment.count <= maximumFrameBytes - buffer.count else {
                    throw BrokerWireError.frameTooLarge(maximum: maximumFrameBytes)
                }

                let frame: Data
                if buffer.isEmpty {
                    frame = Data(segment)
                } else {
                    buffer.append(contentsOf: segment)
                    frame = buffer
                    // One large frame (a 4 MiB history page, a big tool
                    // result) must not pin its high-water storage for the
                    // client's lifetime — there is one decoder per ACP chat
                    // and per Mesh column. Small buffers keep their storage;
                    // big ones release it (2026-08-06 spec §2i). Data hides
                    // capacity, so the frame's size is the signal.
                    if frame.count <= 64 * 1_024 {
                        buffer.removeAll(keepingCapacity: true)
                    } else {
                        buffer = Data()
                    }
                }

                if !frame.isEmpty {
                    guard String(data: frame, encoding: .utf8) != nil else {
                        throw BrokerWireError.invalidUTF8
                    }
                    try onFrame(frame)
                }
                cursor = chunk.index(after: newline)
            } else {
                let remainder = chunk[cursor...]
                guard remainder.count <= maximumFrameBytes - buffer.count else {
                    throw BrokerWireError.frameTooLarge(maximum: maximumFrameBytes)
                }
                buffer.append(contentsOf: remainder)
                cursor = chunk.endIndex
            }
        }
    }

    /// Compatibility convenience for call sites that intentionally want a
    /// batch. Streaming clients should use `consume(_:onFrame:)`.
    public mutating func push(_ chunk: Data) throws -> [Data] {
        var frames: [Data] = []
        try consume(chunk) { frames.append($0) }
        return frames
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw BrokerWireError.incompleteFrame }
    }
}
