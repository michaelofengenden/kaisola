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

    func testObserverRegistryClampsQueueLimitsLikeTheNodeBroker() {
        XCTAssertEqual(TerminalOutputObservers.queueLimit(nil), 256 * 1_024)
        XCTAssertEqual(TerminalOutputObservers.queueLimit(1), 64 * 1_024)
        XCTAssertEqual(TerminalOutputObservers.queueLimit(512 * 1_024), 512 * 1_024)
        XCTAssertEqual(
            TerminalOutputObservers.queueLimit(Int64(64 * 1_024 * 1_024)),
            2 * 1_024 * 1_024
        )
    }

    func testObserverRegistryPausesOnOverflowAndDropsOnlyUndeliverableMarkers() throws {
        var observers = TerminalOutputObservers(terminalID: "term-observers")
        _ = try observers.subscribe(owner: "healthy", maxQueueBytes: nil)
        _ = try observers.subscribe(owner: "slow", maxQueueBytes: 64 * 1_024)
        let payload: BrokerJSONValue = .object(["id": .string("term-observers")])
        let cursor = TerminalObserverCursor(streamEpoch: streamEpoch, endOffset: 40)

        var markers: [(owner: String, payload: BrokerJSONValue)] = []
        let overflowing = observers.broadcast(
            channel: "terminal:observer-output",
            payload: payload,
            cursor: cursor
        ) { owner, channel, delivered, _, force in
            if force {
                markers.append((owner, delivered))
                return true
            }
            XCTAssertEqual(channel, "terminal:observer-output")
            return owner == "healthy"
        }
        XCTAssertEqual(overflowing.delivered, 1)
        XCTAssertEqual(overflowing.paused, 1)
        XCTAssertEqual(overflowing.dropped, 0)
        XCTAssertEqual(markers.map(\.owner), ["slow"])
        // The one permitted overflow marker names the exact resubscribe cursor.
        XCTAssertEqual(markers.first?.payload, .object([
            "id": .string("term-observers"),
            "reason": .string("slow_consumer"),
            "streamEpoch": .string(streamEpoch),
            "endOffset": .integer(40),
        ]))

        // A paused subscription is skipped without new markers or deltas.
        let skipped = observers.broadcast(
            channel: "terminal:observer-output",
            payload: payload,
            cursor: cursor
        ) { _, _, _, _, _ in true }
        XCTAssertEqual(skipped.delivered, 1)
        XCTAssertEqual(skipped.paused, 0)
        XCTAssertEqual(observers.pausedCount, 1)

        // Resubscribing replaces the entry and clears the paused state.
        _ = try observers.subscribe(owner: "slow", maxQueueBytes: nil)
        XCTAssertEqual(observers.pausedCount, 0)

        // When even the forced marker cannot land, the subscription retires.
        let undeliverable = observers.broadcast(
            channel: "terminal:observer-output",
            payload: payload,
            cursor: cursor
        ) { owner, _, _, _, _ in owner == "healthy" }
        XCTAssertEqual(undeliverable.delivered, 1)
        XCTAssertEqual(undeliverable.paused, 0)
        XCTAssertEqual(undeliverable.dropped, 1)
        XCTAssertEqual(observers.subscriberCount, 1)
        XCTAssertTrue(observers.unsubscribe(owner: "healthy"))
        XCTAssertFalse(observers.unsubscribe(owner: "slow"))
    }

    func testObserverRegistryEnforcesTheEightSubscriberLimit() throws {
        var observers = TerminalOutputObservers(terminalID: "term-limit")
        for index in 0..<8 {
            _ = try observers.subscribe(owner: "owner-\(index)", maxQueueBytes: nil)
        }
        // Replacing an existing subscription never counts against the limit.
        _ = try observers.subscribe(owner: "owner-0", maxQueueBytes: nil)
        XCTAssertEqual(observers.subscriberCount, 8)
        XCTAssertThrowsError(
            try observers.subscribe(owner: "owner-8", maxQueueBytes: nil)
        ) { error in
            XCTAssertEqual(
                error as? TerminalObserverRegistryError,
                .observerLimitReached(maximum: 8)
            )
        }
        XCTAssertThrowsError(
            try observers.subscribe(owner: "", maxQueueBytes: nil)
        ) { error in
            XCTAssertEqual(error as? TerminalObserverRegistryError, .invalidSubscriber)
        }
        XCTAssertEqual(observers.unsubscribe(prefix: "owner-"), 8)
        XCTAssertEqual(observers.subscriberCount, 0)
    }

    func testEmissionSplitsAtTheObserverFrameLimitOnScalarBoundaries() {
        // A four-byte scalar straddles the 64 KiB boundary, so the split must
        // retreat to a boundary instead of cutting the scalar.
        let limit = 64 * 1_024
        let head = String(repeating: "x", count: limit - 2)
        let text = head + "🙂" + String(repeating: "y", count: 100)
        let emission = TerminalOutputEmission(
            streamEpoch: streamEpoch,
            output: text,
            startOffset: 500,
            endOffset: 500 + Int64(text.utf8.count)
        )

        let pieces = emission.splitForObserverFrames()
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.output).joined(), text)
        XCTAssertEqual(pieces.first?.output, head)
        XCTAssertEqual(pieces.first?.startOffset, 500)
        XCTAssertEqual(pieces.first?.endOffset, 500 + Int64(head.utf8.count))
        XCTAssertEqual(pieces.last?.startOffset, pieces.first?.endOffset)
        XCTAssertEqual(pieces.last?.endOffset, emission.endOffset)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.output.utf8.count, limit)
            XCTAssertEqual(
                piece.endOffset - piece.startOffset,
                Int64(piece.output.utf8.count)
            )
            XCTAssertEqual(piece.streamEpoch, streamEpoch)
        }

        let tiny = TerminalOutputEmission(
            streamEpoch: streamEpoch,
            output: "small",
            startOffset: 0,
            endOffset: 5
        )
        XCTAssertEqual(tiny.splitForObserverFrames(), [tiny])
    }

    func testHistorySliceServesBoundedPagesOverTheRetainedTail() throws {
        var buffer = try TerminalOutputBuffer(
            streamEpoch: streamEpoch,
            tailByteLimit: 10
        )
        _ = try buffer.append(Data("ABCDEFGHIJKLMN".utf8))
        // Retained tail is EFGHIJKLMN over absolute offsets [4, 14).

        let newest = try XCTUnwrap(buffer.historySlice(before: 14, maximumBytes: 4))
        XCTAssertEqual(newest.output, "KLMN")
        XCTAssertEqual(newest.startOffset, 10)
        XCTAssertEqual(newest.endOffset, 14)
        XCTAssertTrue(newest.hasMore)
        XCTAssertTrue(newest.truncated)

        let older = try XCTUnwrap(buffer.historySlice(before: 10, maximumBytes: 100))
        XCTAssertEqual(older.output, "EFGHIJ")
        XCTAssertEqual(older.startOffset, 4)
        XCTAssertEqual(older.endOffset, 10)
        XCTAssertFalse(older.hasMore)

        // Requests beneath the retained floor clamp to an empty page at the
        // floor rather than fabricating evicted bytes.
        let beneath = try XCTUnwrap(buffer.historySlice(before: 2, maximumBytes: 4))
        XCTAssertEqual(beneath.output, "")
        XCTAssertEqual(beneath.startOffset, 4)
        XCTAssertEqual(beneath.endOffset, 4)
        XCTAssertFalse(beneath.hasMore)

        XCTAssertNil(buffer.historySlice(before: 15, maximumBytes: 4))
        XCTAssertNil(buffer.historySlice(before: -1, maximumBytes: 4))
    }

    func testHistorySliceSkipsForwardOverASplitScalarAtThePageStart() throws {
        var buffer = try TerminalOutputBuffer(
            streamEpoch: streamEpoch,
            tailByteLimit: 64
        )
        _ = try buffer.append(Data("AB🙂CD".utf8)) // offsets: A0 B1 🙂2-5 C6 D7

        // A page cap that lands inside the scalar must move forward to the
        // next boundary; the skipped bytes stay reachable in the older page.
        let page = try XCTUnwrap(buffer.historySlice(before: 8, maximumBytes: 4))
        XCTAssertEqual(page.output, "CD")
        XCTAssertEqual(page.startOffset, 6)
        XCTAssertEqual(page.endOffset, 8)
        XCTAssertTrue(page.hasMore)

        let preceding = try XCTUnwrap(buffer.historySlice(before: 6, maximumBytes: 6))
        XCTAssertEqual(page.output.utf8.count + preceding.output.utf8.count, 8)
        XCTAssertEqual(preceding.output, "AB🙂")
        XCTAssertFalse(preceding.hasMore)
    }
}
