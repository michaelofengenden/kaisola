import Foundation

enum CompanionWireError: Error, Equatable {
    case frameTooLarge
    case invalidFrame
    case connectionUnavailable
}

struct CompanionLengthFrameDecoder: Sendable {
    // Largest length-framed secure frame, derived from the same secure-plaintext
    // cap the desktop uses (electron/companion/bonjourTransport.cjs:
    // ceil((plaintext + 16) * 4/3) + 2048). Derived rather than hard-coded so
    // raising the plaintext cap for larger terminal snapshots can never leave
    // the two ends disagreeing on the maximum accepted frame.
    static let defaultMaximumFrameBytes =
        Int((Double(CompanionCrypto.maximumSecurePlaintextBytes + 16) * 4 / 3).rounded(.up)) + 2048

    private(set) var buffer = Data()
    let maximumFrameBytes: Int

    init(maximumFrameBytes: Int = CompanionLengthFrameDecoder.defaultMaximumFrameBytes) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= maximumFrameBytes else { throw CompanionWireError.frameTooLarge }
            guard buffer.count >= length + 4 else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer.removeFirst(length + 4)
        }
        if buffer.count > maximumFrameBytes + 4 { throw CompanionWireError.frameTooLarge }
        return frames
    }

    static func encode(_ payload: Data, maximumFrameBytes: Int = CompanionLengthFrameDecoder.defaultMaximumFrameBytes) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumFrameBytes, payload.count <= Int(UInt32.max) else {
            throw CompanionWireError.frameTooLarge
        }
        let length = UInt32(payload.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        frame.append(payload)
        return frame
    }
}
