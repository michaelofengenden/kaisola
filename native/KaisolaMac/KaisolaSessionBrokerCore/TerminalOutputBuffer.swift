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
