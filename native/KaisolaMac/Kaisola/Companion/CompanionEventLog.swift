import Foundation
import KaisolaCore

struct CompanionOutboundRecord: Equatable, Sendable {
    let kind: CompanionEnvelopeKind
    let sequence: Int64
    let id: String
    let sentAt: Int64
    let body: CompanionBody
    let audience: Set<String>?
}

enum CompanionReplayGapReason: String, Equatable, Sendable {
    case missingCursor
    case epochMismatch
    case cursorAhead
    case eventGap
    case audienceGap
}

enum CompanionReplayResult: Equatable, Sendable {
    case replay(records: [CompanionOutboundRecord], currentSequence: Int64)
    case snapshotRequired(reason: CompanionReplayGapReason, currentSequence: Int64)
}

enum CompanionEventLogError: Error, Equatable {
    case invalidLimit
    case invalidFrame
    case frameTooLarge
    case cursorAhead
    case acknowledgementAhead
}

/// A process-epoch replay log for authoritative Companion state frames.
///
/// Projection snapshots are retained within strict count and byte bounds.
/// Audience-scoped terminal frames remain replayable only to that exact socket.
/// A different connection crossing one receives a coherent projection snapshot
/// and re-subscribes for a fresh bounded terminal tail instead of leaking bytes.
@MainActor
final class CompanionEventLog {
    static let defaultMaximumEvents = 2_048
    static let defaultMaximumBytes = 2 * 1_024 * 1_024
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    struct Stats: Equatable, Sendable {
        let epoch: String
        let currentSequence: Int64
        let droppedThrough: Int64
        let earliestSequence: Int64
        let retainedEvents: Int
        let retainedBytes: Int
        let activeClients: Int
        let maximumEvents: Int
        let maximumBytes: Int
    }

    let epoch: String
    private let maximumEvents: Int
    private let maximumBytes: Int
    private var frames: [(frame: CompanionOutboundRecord, bytes: Int)] = []
    private var frameHead = 0
    private var retainedBytes = 0
    private(set) var currentSequence: Int64 = 0
    private(set) var droppedThrough: Int64 = 0
    private var acknowledgements: [String: Int64] = [:]

    init(
        epoch: String,
        maximumEvents: Int = CompanionEventLog.defaultMaximumEvents,
        maximumBytes: Int = CompanionEventLog.defaultMaximumBytes
    ) {
        precondition((try? CompanionCrypto.validateIdentifier(epoch, label: "epoch")) != nil)
        precondition(maximumEvents > 0 && maximumBytes > 0)
        self.epoch = epoch
        self.maximumEvents = maximumEvents
        self.maximumBytes = maximumBytes
    }

    func append(
        kind: CompanionEnvelopeKind,
        id: String,
        body: CompanionBody,
        sentAt: Int64,
        audience: Set<String>? = nil
    ) throws -> CompanionOutboundRecord {
        guard kind == .snapshot || kind == .event,
              sentAt >= 0,
              sentAt <= Self.maximumSafeInteger,
              currentSequence < Self.maximumSafeInteger,
              (try? CompanionCrypto.validateIdentifier(id, label: "id")) != nil else {
            throw CompanionEventLogError.invalidFrame
        }
        if let audience {
            guard !audience.isEmpty,
                  audience.allSatisfy({
                      (try? CompanionCrypto.validateIdentifier($0, label: "audience")) != nil
                  }) else {
                throw CompanionEventLogError.invalidFrame
            }
        }
        let bytes = try encodedSize(
            kind: kind,
            id: id,
            sentAt: sentAt,
            body: body,
            audience: audience
        )
        guard bytes <= maximumBytes else { throw CompanionEventLogError.frameTooLarge }
        currentSequence += 1
        let frame = CompanionOutboundRecord(
            kind: kind,
            sequence: currentSequence,
            id: id,
            sentAt: sentAt,
            body: body,
            audience: audience
        )
        frames.append((frame, bytes))
        retainedBytes += bytes
        trimToLimits()
        return frame
    }

    /// Advance the durable state cursor while intentionally retaining no body.
    /// This is used for per-subscription terminal traffic, whose replacement is
    /// a freshly authorized bounded snapshot rather than cross-socket replay.
    func invalidate() throws -> Int64 {
        guard currentSequence < Self.maximumSafeInteger else {
            throw CompanionEventLogError.invalidFrame
        }
        currentSequence += 1
        droppedThrough = currentSequence
        frames.removeAll(keepingCapacity: true)
        frameHead = 0
        retainedBytes = 0
        return currentSequence
    }

    func replay(
        after cursor: CompanionAckCursor?,
        connectionID: String
    ) throws -> CompanionReplayResult {
        guard (try? CompanionCrypto.validateIdentifier(connectionID, label: "connectionId")) != nil else {
            throw CompanionEventLogError.invalidFrame
        }
        guard let cursor else {
            return .snapshotRequired(reason: .missingCursor, currentSequence: currentSequence)
        }
        guard cursor.epoch == epoch else {
            return .snapshotRequired(reason: .epochMismatch, currentSequence: currentSequence)
        }
        guard cursor.seq <= currentSequence else {
            return .snapshotRequired(reason: .cursorAhead, currentSequence: currentSequence)
        }
        guard cursor.seq >= droppedThrough else {
            return .snapshotRequired(reason: .eventGap, currentSequence: currentSequence)
        }
        let suffix = frames[frameHead...].lazy
            .map(\.frame)
            .filter { $0.sequence > cursor.seq }
        if suffix.contains(where: { frame in
            frame.audience != nil && frame.audience?.contains(connectionID) != true
        }) {
            return .snapshotRequired(reason: .audienceGap, currentSequence: currentSequence)
        }
        return .replay(
            records: Array(suffix.filter { frame in
                frame.audience == nil || frame.audience?.contains(connectionID) == true
            }),
            currentSequence: currentSequence
        )
    }

    @discardableResult
    func acknowledge(deviceID: String, sequence: Int64) throws -> Int64 {
        guard (try? CompanionCrypto.validateIdentifier(deviceID, label: "deviceId")) != nil,
              sequence >= 0 else {
            throw CompanionEventLogError.invalidFrame
        }
        guard sequence <= currentSequence else {
            throw CompanionEventLogError.acknowledgementAhead
        }
        let acknowledged = max(acknowledgements[deviceID] ?? 0, sequence)
        acknowledgements[deviceID] = acknowledged
        return acknowledged
    }

    func acknowledgedSequence(deviceID: String) -> Int64? {
        acknowledgements[deviceID]
    }

    @discardableResult
    func dropClient(_ deviceID: String) -> Bool {
        acknowledgements.removeValue(forKey: deviceID) != nil
    }

    func stats() -> Stats {
        Stats(
            epoch: epoch,
            currentSequence: currentSequence,
            droppedThrough: droppedThrough,
            earliestSequence: frameHead < frames.count
                ? frames[frameHead].frame.sequence
                : currentSequence + 1,
            retainedEvents: frames.count - frameHead,
            retainedBytes: retainedBytes,
            activeClients: acknowledgements.count,
            maximumEvents: maximumEvents,
            maximumBytes: maximumBytes
        )
    }

    private func encodedSize(
        kind: CompanionEnvelopeKind,
        id: String,
        sentAt: Int64,
        body: CompanionBody,
        audience: Set<String>?
    ) throws -> Int {
        let envelope = try CompanionEnvelope(
            kind: kind,
            desktopId: "desktop-size-probe",
            deviceId: "device-size-probe",
            connectionId: "connection-size-probe",
            epoch: epoch,
            seq: currentSequence + 1,
            id: id,
            sentAt: sentAt,
            body: body
        )
        let audienceBytes = audience?.reduce(0) { $0 + $1.utf8.count + 4 } ?? 0
        return try CompanionProtocolCodec.encode(envelope).count + audienceBytes
    }

    private func trimToLimits() {
        while frames.count - frameHead > maximumEvents || retainedBytes > maximumBytes {
            let removed = frames[frameHead]
            frameHead += 1
            retainedBytes -= removed.bytes
            droppedThrough = max(droppedThrough, removed.frame.sequence)
        }
        // Avoid Array.removeFirst's quadratic behavior under long-running
        // streams while still periodically releasing discarded storage.
        if frameHead >= 4_096, frameHead * 2 >= frames.count {
            frames.removeFirst(frameHead)
            frameHead = 0
        }
    }
}
