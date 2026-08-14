import Foundation

public enum TerminalOutputBufferError: Error, Equatable, Sendable {
    case invalidTailByteLimit
    case finished
    case offsetOverflow
}

public enum TerminalOutputDrainState: Equatable, Sendable {
    case streaming
    case final
}

/// One contiguous piece of repaired UTF-8 terminal output. Offsets count the
/// bytes in `output`, not the possibly-invalid source bytes read from the PTY.
public struct TerminalOutputEmission: Equatable, Sendable {
    public let streamEpoch: String
    public let output: String
    public let startOffset: Int64
    public let endOffset: Int64

    public init(
        streamEpoch: String,
        output: String,
        startOffset: Int64,
        endOffset: Int64
    ) {
        self.streamEpoch = streamEpoch
        self.output = output
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

/// The result of consuming bytes from the PTY. A `.final` result is the
/// ordering barrier: publish its optional emission before publishing exit.
public struct TerminalOutputDrain: Equatable, Sendable {
    public let state: TerminalOutputDrainState
    public let emission: TerminalOutputEmission?

    public init(
        state: TerminalOutputDrainState,
        emission: TerminalOutputEmission?
    ) {
        self.state = state
        self.emission = emission
    }
}

public struct TerminalOutputSnapshot: Equatable, Sendable {
    public let streamEpoch: String
    public let output: String
    public let startOffset: Int64
    public let endOffset: Int64
    public let truncated: Bool
    public let state: TerminalOutputDrainState

    public init(
        streamEpoch: String,
        output: String,
        startOffset: Int64,
        endOffset: Int64,
        truncated: Bool,
        state: TerminalOutputDrainState
    ) {
        self.streamEpoch = streamEpoch
        self.output = output
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.truncated = truncated
        self.state = state
    }
}

/// Incrementally decodes raw PTY bytes without mistaking a read boundary for
/// malformed UTF-8. At most three bytes are retained between reads, which is
/// enough to hold the incomplete prefix of a four-byte scalar.
public struct TerminalOutputBuffer: Sendable {
    public let streamEpoch: String
    public let tailByteLimit: Int

    private var pendingUTF8 = Data()
    private var tailUTF8 = Data()
    private var endOffset: Int64 = 0
    private var wasTruncated = false
    private var state: TerminalOutputDrainState = .streaming

    public init(streamEpoch: String, tailByteLimit: Int) throws {
        guard tailByteLimit > 0 else {
            throw TerminalOutputBufferError.invalidTailByteLimit
        }
        self.streamEpoch = streamEpoch
        self.tailByteLimit = tailByteLimit
    }

    /// Consumes one arbitrary PTY read. The returned emission can be absent
    /// when the read ends with only an incomplete, still-valid scalar prefix.
    public mutating func append(_ bytes: Data) throws -> TerminalOutputDrain {
        guard state == .streaming else {
            throw TerminalOutputBufferError.finished
        }

        var undecoded = pendingUTF8
        undecoded.append(bytes)

        if let suffixStart = Self.incompleteScalarSuffixStart(in: undecoded) {
            pendingUTF8 = Data(undecoded[suffixStart...])
            undecoded.removeSubrange(suffixStart...)
        } else {
            pendingUTF8.removeAll(keepingCapacity: true)
        }

        let output = String(decoding: undecoded, as: UTF8.self)
        let emission = try record(output)
        return TerminalOutputDrain(state: .streaming, emission: emission)
    }

    /// Flushes any incomplete terminal bytes through deterministic U+FFFD
    /// repair. Repeated calls are harmless and never duplicate output.
    public mutating func finish() throws -> TerminalOutputDrain {
        guard state == .streaming else {
            return TerminalOutputDrain(state: .final, emission: nil)
        }

        state = .final
        let output = String(decoding: pendingUTF8, as: UTF8.self)
        pendingUTF8.removeAll(keepingCapacity: false)
        let emission = try record(output)
        return TerminalOutputDrain(state: .final, emission: emission)
    }

    public func snapshot() -> TerminalOutputSnapshot {
        TerminalOutputSnapshot(
            streamEpoch: streamEpoch,
            output: String(decoding: tailUTF8, as: UTF8.self),
            startOffset: endOffset - Int64(tailUTF8.count),
            endOffset: endOffset,
            truncated: wasTruncated,
            state: state
        )
    }

    private mutating func record(_ output: String) throws -> TerminalOutputEmission? {
        guard !output.isEmpty else { return nil }

        let encoded = Data(output.utf8)
        guard encoded.count <= Int(Int64.max - endOffset) else {
            throw TerminalOutputBufferError.offsetOverflow
        }
        let startOffset = endOffset
        endOffset += Int64(encoded.count)
        appendToTail(encoded)
        return TerminalOutputEmission(
            streamEpoch: streamEpoch,
            output: output,
            startOffset: startOffset,
            endOffset: endOffset
        )
    }

    private mutating func appendToTail(_ bytes: Data) {
        tailUTF8.append(bytes)
        guard tailUTF8.count > tailByteLimit else { return }

        var start = tailUTF8.count - tailByteLimit
        while start < tailUTF8.count, Self.isContinuation(tailUTF8[start]) {
            start += 1
        }
        wasTruncated = true
        tailUTF8 = Data(tailUTF8[start...])
    }

    /// Returns the start of a suffix that could become one valid scalar when
    /// more bytes arrive. Everything before it has a stable repair independent
    /// of how the OS divided the reads.
    private static func incompleteScalarSuffixStart(in bytes: Data) -> Int? {
        guard !bytes.isEmpty else { return nil }

        var candidate = bytes.count - 1
        var continuationCount = 0
        while candidate >= 0,
              continuationCount < 3,
              isContinuation(bytes[candidate]) {
            candidate -= 1
            continuationCount += 1
        }
        guard candidate >= 0,
              let expectedLength = scalarLength(for: bytes[candidate]) else {
            return nil
        }

        let suffixLength = bytes.count - candidate
        guard suffixLength < expectedLength,
              isValidScalarPrefix(bytes[candidate...]) else {
            return nil
        }
        return candidate
    }

    private static func scalarLength(for first: UInt8) -> Int? {
        switch first {
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: nil
        }
    }

    private static func isValidScalarPrefix(_ bytes: Data.SubSequence) -> Bool {
        guard let first = bytes.first else { return false }
        if bytes.count >= 2 {
            let second = bytes[bytes.index(after: bytes.startIndex)]
            let secondIsValid: Bool
            switch first {
            case 0xE0:
                secondIsValid = (0xA0...0xBF).contains(second)
            case 0xED:
                secondIsValid = (0x80...0x9F).contains(second)
            case 0xF0:
                secondIsValid = (0x90...0xBF).contains(second)
            case 0xF4:
                secondIsValid = (0x80...0x8F).contains(second)
            default:
                secondIsValid = isContinuation(second)
            }
            guard secondIsValid else { return false }
        }

        if bytes.count >= 3 {
            for byte in bytes.dropFirst(2) where !isContinuation(byte) {
                return false
            }
        }
        return true
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }
}

public struct TerminalOutputHistorySlice: Equatable, Sendable {
    public let output: String
    public let startOffset: Int64
    public let endOffset: Int64
    public let hasMore: Bool
    public let truncated: Bool

    public init(
        output: String,
        startOffset: Int64,
        endOffset: Int64,
        hasMore: Bool,
        truncated: Bool
    ) {
        self.output = output
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.hasMore = hasMore
        self.truncated = truncated
    }
}

extension TerminalOutputBuffer {
    /// One bounded history page over the retained tail, ending at
    /// `beforeOffset`. Absolute stream offsets, so pages concatenate exactly
    /// with subscription snapshots and live events. Requests beneath the
    /// retained floor clamp to an empty page AT the floor: evicted bytes are
    /// reported as absent, never fabricated. A `beforeOffset` outside
    /// `[0, endOffset]` is the caller's protocol error and answers nil.
    public func historySlice(
        before beforeOffset: Int64,
        maximumBytes: Int
    ) -> TerminalOutputHistorySlice? {
        let snapshot = snapshot()
        guard beforeOffset >= 0, beforeOffset <= snapshot.endOffset else { return nil }
        let retainedStart = snapshot.startOffset
        let cap = Int64(max(0, maximumBytes))
        let end = max(retainedStart, beforeOffset)
        var start = max(retainedStart, end - cap)

        let bytes = Data(snapshot.output.utf8)
        // A byte cap may land inside a multi-byte scalar. Move forward to the
        // next boundary; the skipped continuation bytes remain reachable in
        // the preceding (older) page, so pages still concatenate as valid text.
        var relativeStart = Int(start - retainedStart)
        let relativeEnd = Int(end - retainedStart)
        while relativeStart < relativeEnd, bytes[relativeStart] & 0xC0 == 0x80 {
            relativeStart += 1
            start += 1
        }
        let output = String(decoding: bytes[relativeStart..<relativeEnd], as: UTF8.self)
        return TerminalOutputHistorySlice(
            output: output,
            startOffset: start,
            endOffset: end,
            hasMore: start > retainedStart,
            truncated: snapshot.truncated
        )
    }
}

extension TerminalOutputEmission {
    /// The Node broker never broadcasts an observer frame carrying more than
    /// 64 KiB of raw output (`OBSERVER_CHUNK_BYTES`): worst-case JSON escaping
    /// expands control-dense bytes several times over, and the encoded
    /// observer-output frame cap is 512 KiB.
    public static let observerFrameByteLimit = 64 * 1_024

    /// Splits one emission into bounded contiguous pieces on UTF-8 scalar
    /// boundaries. Offsets subdivide exactly, so every piece is itself a valid
    /// observer-output payload and the pieces concatenate back byte-for-byte.
    public func splitForObserverFrames(
        maximumBytes: Int = TerminalOutputEmission.observerFrameByteLimit
    ) -> [TerminalOutputEmission] {
        let bytes = Data(output.utf8)
        guard bytes.count > maximumBytes, maximumBytes > 0 else { return [self] }

        var pieces: [TerminalOutputEmission] = []
        var start = 0
        while start < bytes.count {
            var end = min(bytes.count, start + maximumBytes)
            // Retreat to a scalar boundary; a pathological cap smaller than
            // one scalar advances instead so the split always terminates.
            while end < bytes.count, end > start, bytes[end] & 0xC0 == 0x80 {
                end -= 1
            }
            if end == start {
                end = min(bytes.count, start + maximumBytes)
                while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end += 1 }
            }
            pieces.append(TerminalOutputEmission(
                streamEpoch: streamEpoch,
                output: String(decoding: bytes[start..<end], as: UTF8.self),
                startOffset: startOffset + Int64(start),
                endOffset: startOffset + Int64(end)
            ))
            start = end
        }
        return pieces
    }
}

public enum TerminalObserverRegistryError: Error, Equatable, Sendable {
    case invalidSubscriber
    case observerLimitReached(maximum: Int)
}

public struct TerminalObserverCursor: Equatable, Sendable {
    public let streamEpoch: String
    public let endOffset: Int64

    public init(streamEpoch: String, endOffset: Int64) {
        self.streamEpoch = streamEpoch
        self.endOffset = endOffset
    }
}

public struct TerminalObserverBroadcastResult: Equatable, Sendable {
    public let delivered: Int
    public let paused: Int
    public let dropped: Int
}

/// Port of the Node broker's `TerminalObservers` (terminalObservers.cjs):
/// bounded per-subscriber queues and the single fail-closed slow-consumer
/// policy. Not internally synchronized — the owning terminal serializes every
/// call under the same lock that serializes output intake, which is what makes
/// snapshot-then-live registration gapless.
public struct TerminalOutputObservers: Sendable {
    public static let defaultQueueBytes = 256 * 1_024
    public static let minimumQueueBytes = 64 * 1_024
    public static let maximumQueueBytes = 2 * 1_024 * 1_024
    public static let maximumObservers = 8

    public typealias Deliver = (
        _ owner: String,
        _ channel: String,
        _ payload: BrokerJSONValue,
        _ maxQueueBytes: Int?,
        _ force: Bool
    ) -> Bool

    private struct Subscriber {
        var maxQueueBytes: Int
        var paused: Bool
    }

    public let terminalID: String
    private var subscribers: [String: Subscriber] = [:]
    // Broadcast order matches Node's insertion-ordered Map, so wire timelines
    // are deterministic for tests and identical across resubscribes.
    private var order: [String] = []

    public init(terminalID: String) {
        self.terminalID = terminalID
    }

    public var subscriberCount: Int { subscribers.count }

    public var pausedCount: Int {
        subscribers.values.lazy.filter(\.paused).count
    }

    public static func queueLimit(_ requested: Int64?) -> Int {
        guard let requested else { return defaultQueueBytes }
        let clamped = min(Int64(maximumQueueBytes), max(Int64(minimumQueueBytes), requested))
        return Int(clamped)
    }

    /// Registers or replaces one subscription. Replacement resets the paused
    /// state — an explicit resubscribe just obtained a fresh snapshot, so its
    /// live stream may flow again.
    @discardableResult
    public mutating func subscribe(
        owner: String,
        maxQueueBytes: Int64?
    ) throws -> Int {
        guard !owner.isEmpty, owner.count <= 500 else {
            throw TerminalObserverRegistryError.invalidSubscriber
        }
        if subscribers[owner] == nil {
            guard subscribers.count < Self.maximumObservers else {
                throw TerminalObserverRegistryError.observerLimitReached(
                    maximum: Self.maximumObservers
                )
            }
            order.append(owner)
        }
        let limit = Self.queueLimit(maxQueueBytes)
        subscribers[owner] = Subscriber(maxQueueBytes: limit, paused: false)
        return limit
    }

    @discardableResult
    public mutating func unsubscribe(owner: String) -> Bool {
        guard subscribers.removeValue(forKey: owner) != nil else { return false }
        order.removeAll { $0 == owner }
        return true
    }

    @discardableResult
    public mutating func unsubscribe(prefix: String) -> Int {
        guard !prefix.isEmpty else { return 0 }
        var removed = 0
        for owner in order where owner.hasPrefix(prefix) {
            subscribers.removeValue(forKey: owner)
            removed += 1
        }
        order.removeAll { $0.hasPrefix(prefix) }
        return removed
    }

    /// One overflow policy, exactly the Node broker's: a refused delta earns
    /// one forced, small `terminal:observer-snapshot-required` marker carrying
    /// the exact resubscribe cursor, and the subscription pauses. A paused
    /// subscription is never spoken to again until an explicit resubscribe.
    /// If even the forced marker cannot land, the subscription retires: a
    /// paused subscriber whose marker never arrived would be silenced forever.
    @discardableResult
    public mutating func broadcast(
        channel: String,
        payload: BrokerJSONValue,
        cursor: TerminalObserverCursor,
        deliver: Deliver
    ) -> TerminalObserverBroadcastResult {
        var delivered = 0
        var paused = 0
        var dropped = 0
        for owner in order {
            guard let subscriber = subscribers[owner], !subscriber.paused else { continue }
            if deliver(owner, channel, payload, subscriber.maxQueueBytes, false) {
                delivered += 1
                continue
            }
            let marker: BrokerJSONValue = .object([
                "id": .string(terminalID),
                "reason": .string("slow_consumer"),
                "streamEpoch": .string(cursor.streamEpoch),
                "endOffset": .integer(cursor.endOffset),
            ])
            if deliver(
                owner,
                "terminal:observer-snapshot-required",
                marker,
                subscriber.maxQueueBytes,
                true
            ) {
                subscribers[owner]?.paused = true
                paused += 1
                continue
            }
            subscribers.removeValue(forKey: owner)
            dropped += 1
        }
        if dropped > 0 {
            order.removeAll { subscribers[$0] == nil }
        }
        return TerminalObserverBroadcastResult(
            delivered: delivered,
            paused: paused,
            dropped: dropped
        )
    }
}
