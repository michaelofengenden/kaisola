import KaisolaCore
import XCTest
@testable import Kaisola

@MainActor
final class CompanionEventLogTests: XCTestCase {
    func testOneEpochSequenceIsSharedAndConnectionScopedGapsFallBackToSnapshot() throws {
        let log = CompanionEventLog(epoch: "epoch-test")
        let first = try log.append(
            kind: .snapshot,
            id: "snapshot-1",
            body: body(type: "snapshot.projects"),
            sentAt: 100
        )
        let terminal = try log.append(
            kind: .event,
            id: "terminal-2",
            body: body(type: "terminal.output"),
            sentAt: 101,
            audience: ["socket-one"]
        )
        let third = try log.append(
            kind: .snapshot,
            id: "snapshot-3",
            body: body(type: "snapshot.projects"),
            sentAt: 102
        )

        XCTAssertEqual([first.sequence, terminal.sequence, third.sequence], [1, 2, 3])
        XCTAssertEqual(
            try log.replay(
                after: CompanionAckCursor(epoch: "epoch-test", seq: 0),
                connectionID: "socket-one"
            ),
            .replay(records: [first, terminal, third], currentSequence: 3)
        )
        XCTAssertEqual(
            try log.replay(
                after: CompanionAckCursor(epoch: "epoch-test", seq: 0),
                connectionID: "socket-two"
            ),
            .snapshotRequired(reason: .audienceGap, currentSequence: 3)
        )
        XCTAssertEqual(
            try log.replay(
                after: CompanionAckCursor(epoch: "epoch-test", seq: 2),
                connectionID: "socket-two"
            ),
            .replay(records: [third], currentSequence: 3)
        )
    }

    func testCountPruningCreatesAnExplicitReplayGap() throws {
        let log = CompanionEventLog(epoch: "epoch-bounded", maximumEvents: 2)
        for sequence in 1...3 {
            _ = try log.append(
                kind: .event,
                id: "event-\(sequence)",
                body: body(type: "session.updated"),
                sentAt: Int64(sequence)
            )
        }
        XCTAssertEqual(log.currentSequence, 3)
        XCTAssertEqual(log.droppedThrough, 1)
        XCTAssertEqual(
            try log.replay(
                after: CompanionAckCursor(epoch: "epoch-bounded", seq: 0),
                connectionID: "socket-test"
            ),
            .snapshotRequired(reason: .eventGap, currentSequence: 3)
        )
        let replay = try log.replay(
            after: CompanionAckCursor(epoch: "epoch-bounded", seq: 1),
            connectionID: "socket-test"
        )
        guard case let .replay(records, current) = replay else {
            return XCTFail("Expected retained replay")
        }
        XCTAssertEqual(current, 3)
        XCTAssertEqual(records.map(\.sequence), [2, 3])
    }

    func testMissingStaleAndAheadCursorsRequireReplacementSnapshot() throws {
        let log = CompanionEventLog(epoch: "epoch-current")
        _ = try log.append(
            kind: .snapshot,
            id: "snapshot-current",
            body: body(type: "snapshot.projects"),
            sentAt: 100
        )
        XCTAssertEqual(
            try log.replay(after: nil, connectionID: "socket-test"),
            .snapshotRequired(reason: .missingCursor, currentSequence: 1)
        )
        XCTAssertEqual(
            try log.replay(
                after: CompanionAckCursor(epoch: "epoch-old", seq: 1),
                connectionID: "socket-test"
            ),
            .snapshotRequired(reason: .epochMismatch, currentSequence: 1)
        )
        XCTAssertEqual(
            try log.replay(
                after: CompanionAckCursor(epoch: "epoch-current", seq: 2),
                connectionID: "socket-test"
            ),
            .snapshotRequired(reason: .cursorAhead, currentSequence: 1)
        )
    }

    func testAcknowledgementsAreMonotonicAndCannotRunAhead() throws {
        let log = CompanionEventLog(epoch: "epoch-ack")
        _ = try log.append(
            kind: .event,
            id: "event-one",
            body: body(type: "session.updated"),
            sentAt: 100
        )
        XCTAssertEqual(try log.acknowledge(deviceID: "device-one", sequence: 1), 1)
        XCTAssertEqual(try log.acknowledge(deviceID: "device-one", sequence: 0), 1)
        XCTAssertEqual(log.acknowledgedSequence(deviceID: "device-one"), 1)
        XCTAssertThrowsError(try log.acknowledge(deviceID: "device-one", sequence: 2)) {
            XCTAssertEqual($0 as? CompanionEventLogError, .acknowledgementAhead)
        }
    }

    func testByteLimitRejectsOneOversizedFrameAndPrunesOlderFrames() throws {
        let tiny = CompanionEventLog(epoch: "epoch-tiny", maximumEvents: 10, maximumBytes: 220)
        XCTAssertThrowsError(try tiny.append(
            kind: .event,
            id: "event-too-large",
            body: try CompanionBody(fields: [
                "type": .string("session.updated"),
                "text": .string(String(repeating: "x", count: 500)),
            ]),
            sentAt: 1
        )) {
            XCTAssertEqual($0 as? CompanionEventLogError, .frameTooLarge)
        }

        let bounded = CompanionEventLog(epoch: "epoch-bytes", maximumEvents: 10, maximumBytes: 900)
        for sequence in 1...8 {
            _ = try bounded.append(
                kind: .event,
                id: "event-\(sequence)",
                body: try CompanionBody(fields: [
                    "type": .string("session.updated"),
                    "text": .string(String(repeating: "y", count: 120)),
                ]),
                sentAt: Int64(sequence)
            )
        }
        XCTAssertLessThanOrEqual(bounded.stats().retainedBytes, 900)
        XCTAssertGreaterThan(bounded.droppedThrough, 0)
    }

    func testLongSyntheticStreamRemainsStrictlyBounded() throws {
        let log = CompanionEventLog(
            epoch: "epoch-load",
            maximumEvents: 32,
            maximumBytes: 8 * 1_024
        )
        for sequence in 1...50_000 {
            _ = try log.append(
                kind: .event,
                id: "event-\(sequence)",
                body: try CompanionBody(fields: [
                    "type": .string("session.updated"),
                    "busy": .bool(sequence.isMultiple(of: 2)),
                ]),
                sentAt: Int64(sequence)
            )
        }
        let stats = log.stats()
        XCTAssertEqual(stats.currentSequence, 50_000)
        XCTAssertLessThanOrEqual(stats.retainedEvents, 32)
        XCTAssertLessThanOrEqual(stats.retainedBytes, 8 * 1_024)
        XCTAssertEqual(stats.droppedThrough + Int64(stats.retainedEvents), stats.currentSequence)
    }

    private func body(type: String) throws -> CompanionBody {
        try CompanionBody(fields: ["type": .string(type)])
    }
}
