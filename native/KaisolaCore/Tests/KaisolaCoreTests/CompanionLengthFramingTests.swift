import Foundation
import KaisolaCore
import XCTest

final class CompanionLengthFramingTests: XCTestCase {
    func testBigEndianFramesSurviveEveryByteBoundary() throws {
        let first = Data(#"{"v":1}"#.utf8)
        let second = Data(#"{"type":"hello"}"#.utf8)
        let wire = try CompanionLengthFrameDecoder.encode(first)
            + CompanionLengthFrameDecoder.encode(second)

        XCTAssertEqual(Array(wire.prefix(4)), [0, 0, 0, UInt8(first.count)])

        var decoder = CompanionLengthFrameDecoder()
        var decoded: [Data] = []
        for byte in wire {
            decoded.append(contentsOf: try decoder.push(Data([byte])))
        }
        XCTAssertEqual(decoded, [first, second])
        XCTAssertTrue(decoder.buffer.isEmpty)
    }

    func testCoalescedFramesAndPartialTrailingFrameAreRetained() throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let third = Data("third".utf8)
        let firstTwo = try CompanionLengthFrameDecoder.encode(first)
            + CompanionLengthFrameDecoder.encode(second)
        let thirdFrame = try CompanionLengthFrameDecoder.encode(third)

        var decoder = CompanionLengthFrameDecoder()
        XCTAssertEqual(
            try decoder.push(firstTwo + thirdFrame.prefix(6)),
            [first, second]
        )
        XCTAssertFalse(decoder.buffer.isEmpty)
        XCTAssertEqual(try decoder.push(thirdFrame.dropFirst(6)), [third])
        XCTAssertTrue(decoder.buffer.isEmpty)
    }

    func testExactMaximumFrameRoundTrips() throws {
        let payload = Data(repeating: 0xA5, count: 64)
        let encoded = try CompanionLengthFrameDecoder.encode(payload, maximumFrameBytes: 64)
        var decoder = CompanionLengthFrameDecoder(maximumFrameBytes: 64)
        XCTAssertEqual(try decoder.push(encoded), [payload])
    }

    func testZeroEmptyAndOversizedFramesFailClosed() throws {
        var zeroLength = CompanionLengthFrameDecoder(maximumFrameBytes: 8)
        XCTAssertThrowsError(try zeroLength.push(Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? CompanionWireError, .frameTooLarge)
        }

        XCTAssertThrowsError(
            try CompanionLengthFrameDecoder.encode(Data(), maximumFrameBytes: 8)
        ) { error in
            XCTAssertEqual(error as? CompanionWireError, .frameTooLarge)
        }
        XCTAssertThrowsError(
            try CompanionLengthFrameDecoder.encode(Data(repeating: 1, count: 9), maximumFrameBytes: 8)
        ) { error in
            XCTAssertEqual(error as? CompanionWireError, .frameTooLarge)
        }

        var oversizedHeader = CompanionLengthFrameDecoder(maximumFrameBytes: 8)
        XCTAssertThrowsError(try oversizedHeader.push(Data([0, 0, 0, 9]))) { error in
            XCTAssertEqual(error as? CompanionWireError, .frameTooLarge)
        }
    }
}
