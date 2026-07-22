import Foundation

/// Constants mirrored from `electron/ipc/brokerWire.cjs`.
///
/// JavaScript and Swift tests pin these values so a client cannot silently
/// connect with different ownership or framing assumptions.
public enum BrokerWire {
    public static let protocolVersion = 2
    public static let securityEpoch = 1
    public static let implementationVersion = 1
    public static let helperPackageSchema = 1
    /// Protocol-2 implementation N and N+1 are additive-compatible. A future
    /// implementation that needs a wire break must increment `protocolVersion`
    /// rather than widening this range silently.
    public static let compatibleImplementationVersions = 1...2
    public static let terminalObserveFeature = "terminal-observe-v1"
    public static let observerRoleFeature = "observer-role-v1"
    public static let observerMethods: Set<String> = [
        "broker.status",
        "terminal.list",
        "terminal.diagnostics",
        "terminal.subscribe",
        "terminal.unsubscribe",
    ]
    public static let maximumFrameBytes = 56 * 1_024 * 1_024

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
                    buffer.removeAll(keepingCapacity: true)
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
