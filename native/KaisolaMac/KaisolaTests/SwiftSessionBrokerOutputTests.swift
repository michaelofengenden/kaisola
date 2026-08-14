import Foundation
import XCTest
@testable import KaisolaSessionBrokerCore

final class SwiftSessionBrokerOutputTests: XCTestCase {
    private let streamEpoch = "fresh-stream-epoch"

    func testSplitUTF8ScalarWaitsUntilCompleteAndKeepsOffsetsContiguous() throws {
        var buffer = try TerminalOutputBuffer(
            streamEpoch: streamEpoch,
            tailByteLimit: 64
        )
        let bytes = Array("Aé🙂B".utf8)
        var emissions: [TerminalOutputEmission] = []

        for byte in bytes {
            let drain = try buffer.append(Data([byte]))
            XCTAssertEqual(drain.state, .streaming)
            if let emission = drain.emission {
                emissions.append(emission)
            }
        }

        XCTAssertEqual(emissions.map(\.output).joined(), "Aé🙂B")
        XCTAssertEqual(emissions.first?.startOffset, 0)
        XCTAssertEqual(emissions.last?.endOffset, 8)
        for (left, right) in zip(emissions, emissions.dropFirst()) {
            XCTAssertEqual(left.endOffset, right.startOffset)
        }
        for emission in emissions {
            XCTAssertEqual(
                emission.endOffset - emission.startOffset,
                Int64(emission.output.utf8.count)
            )
            XCTAssertEqual(emission.streamEpoch, streamEpoch)
        }
    }

    func testInvalidUTF8RepairIsIdenticalForEveryChunkPartition() throws {
        let input: [UInt8] = [
            0x61,
            0xE2, 0x82, 0x41,
            0xFF,
            0xF0, 0x9F, 0x92, 0xA9,
        ]
        let expected = "a\u{FFFD}A\u{FFFD}💩"
        let partitionCount = 1 << (input.count - 1)

        for partitionMask in 0..<partitionCount {
            var buffer = try TerminalOutputBuffer(
                streamEpoch: streamEpoch,
                tailByteLimit: 128
            )
            var output = ""
            var chunkStart = 0

            for boundary in 0..<(input.count - 1) where partitionMask & (1 << boundary) != 0 {
                let drain = try buffer.append(Data(input[chunkStart...boundary]))
                output += drain.emission?.output ?? ""
                chunkStart = boundary + 1
            }
            let drain = try buffer.append(Data(input[chunkStart...]))
            output += drain.emission?.output ?? ""
            let finalDrain = try buffer.finish()
            output += finalDrain.emission?.output ?? ""

            XCTAssertEqual(output, expected, "partition mask \(partitionMask)")
            XCTAssertEqual(finalDrain.state, .final)
        }
    }

    func testOffsetsMeasureTheRepairedUTF8ThatWasEmitted() throws {
        var buffer = try TerminalOutputBuffer(
            streamEpoch: streamEpoch,
            tailByteLimit: 64
        )

        let repaired = try XCTUnwrap(buffer.append(Data([0xFF])).emission)
        XCTAssertEqual(repaired.output, "\u{FFFD}")
        XCTAssertEqual(repaired.startOffset, 0)
        XCTAssertEqual(repaired.endOffset, 3)

        let valid = try XCTUnwrap(buffer.append(Data("é".utf8)).emission)
        XCTAssertEqual(valid.output, "é")
        XCTAssertEqual(valid.startOffset, 3)
        XCTAssertEqual(valid.endOffset, 5)
        XCTAssertEqual(
            valid.endOffset - valid.startOffset,
            Int64(valid.output.utf8.count)
        )
    }

    func testBoundedTailAdvancesPastASplitScalar() throws {
        var buffer = try TerminalOutputBuffer(
            streamEpoch: streamEpoch,
            tailByteLimit: 5
        )

        _ = try buffer.append(Data("A🙂BC".utf8))
        let snapshot = buffer.snapshot()

        XCTAssertEqual(snapshot.streamEpoch, streamEpoch)
        XCTAssertEqual(snapshot.output, "BC")
        XCTAssertEqual(snapshot.startOffset, 5)
        XCTAssertEqual(snapshot.endOffset, 7)
        XCTAssertEqual(snapshot.endOffset - snapshot.startOffset, 2)
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(snapshot.state, .streaming)
        XCTAssertLessThanOrEqual(snapshot.output.utf8.count, 5)
    }

    func testFinalDrainRepairsPendingBytesBeforeReportingFinal() throws {
        var buffer = try TerminalOutputBuffer(
            streamEpoch: streamEpoch,
            tailByteLimit: 64
        )

        let streaming = try buffer.append(Data([0xF0, 0x9F, 0x92]))
        XCTAssertNil(streaming.emission)
        XCTAssertEqual(streaming.state, .streaming)

        let finalDrain = try buffer.finish()
        let finalEmission = try XCTUnwrap(finalDrain.emission)
        XCTAssertEqual(finalEmission.output, "\u{FFFD}")
        XCTAssertEqual(finalEmission.startOffset, 0)
        XCTAssertEqual(finalEmission.endOffset, 3)
        XCTAssertEqual(finalDrain.state, .final)
        XCTAssertEqual(buffer.snapshot().state, .final)

        let repeatedFinish = try buffer.finish()
        XCTAssertNil(repeatedFinish.emission)
        XCTAssertEqual(repeatedFinish.state, .final)
        XCTAssertThrowsError(try buffer.append(Data("late".utf8))) { error in
            XCTAssertEqual(error as? TerminalOutputBufferError, .finished)
        }
    }

    func testTailLimitMustBePositive() {
        XCTAssertThrowsError(
            try TerminalOutputBuffer(streamEpoch: streamEpoch, tailByteLimit: 0)
        ) { error in
            XCTAssertEqual(error as? TerminalOutputBufferError, .invalidTailByteLimit)
        }
    }
}
