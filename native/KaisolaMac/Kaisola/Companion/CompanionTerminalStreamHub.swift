import Foundation
import KaisolaCore

protocol CompanionTerminalBrokerServing: Sendable {
    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async
    func connect(to info: BrokerInfo) async throws -> BrokerHello
    func subscribeBounded(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?,
        maximumSnapshotBytes: Int
    ) async throws -> TerminalSubscriptionResult
    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws
    func disconnect() async
}


struct CompanionTerminalStreamDelivery: Sendable {
    let connectionIDs: Set<String>
    let kind: CompanionEnvelopeKind
    let id: String
    let body: CompanionBody
}

struct CompanionTerminalSubscriptionResponse: Sendable {
    let receipt: CompanionReceiptBody
    let initialSnapshot: CompanionBody?
}

/// One typed observer view multiplexed across paired phones. Terminal bytes
/// stay in the in-process engine; this actor retains only a 256 KiB tail per
/// actively viewed terminal and fans validated deltas to interested peers.
actor CompanionTerminalStreamHub {
    static let maximumSnapshotBytes = 256 * 1_024
    static let maximumActiveStreams = 8
    static let maximumMembersPerStream = 8

    private struct Key: Hashable, Sendable {
        let projectID: String
        let terminalID: String
    }

    private struct Stream: Sendable {
        let terminal: BrokerTerminalRecord
        var snapshot: TerminalSnapshot
        var members: Set<String>
    }

    private let broker: any CompanionTerminalBrokerServing
    private let locator: any BrokerInfoLocating
    private let ownerID: String
    private let eventSink: @Sendable (CompanionTerminalStreamDelivery) -> Void
    private var configured = false
    private var connected = false
    private var streams: [Key: Stream] = [:]

    init(
        broker: (any CompanionTerminalBrokerServing)? = nil,
        locator: (any BrokerInfoLocating)? = nil,
        ownerID: String = NativeSessionStore().ownerID(),
        eventSink: @escaping @Sendable (CompanionTerminalStreamDelivery) -> Void
    ) {
        // Default to one in-process facade for both seams: the terminal
        // engine lives in this process, so there is nothing to locate.
        let inProcess = InProcessTerminalService()
        self.broker = broker ?? inProcess
        self.locator = locator ?? inProcess
        self.ownerID = ownerID
        self.eventSink = eventSink
    }

    func subscribe(
        connectionID: String,
        command: CompanionCommandBody,
        terminal: BrokerTerminalRecord
    ) async -> CompanionTerminalSubscriptionResponse {
        guard exact(command: command, terminal: terminal) else {
            return response(
                command,
                status: .rejected,
                message: "That terminal is not part of this project."
            )
        }
        let key = Key(projectID: command.projectId, terminalID: command.targetId)
        if var stream = streams[key] {
            guard stream.members.contains(connectionID)
                    || stream.members.count < Self.maximumMembersPerStream else {
                return response(command, status: .rejected, message: "This terminal already has too many viewers.")
            }
            stream.members.insert(connectionID)
            streams[key] = stream
            return response(
                command,
                status: .applied,
                message: "Terminal stream subscribed.",
                snapshot: try? snapshotBody(
                    projectID: key.projectID,
                    terminalID: key.terminalID,
                    snapshot: resumedSnapshot(stream.snapshot, payload: command.payload)
                )
            )
        }
        guard streams.count < Self.maximumActiveStreams else {
            return response(
                command,
                status: .rejected,
                message: "Kaisola supports at most \(Self.maximumActiveStreams) active phone terminal streams."
            )
        }
        do {
            try await ensureConnected()
            let result = try await broker.subscribeBounded(
                to: terminal,
                ownerID: ownerID,
                cursor: cursor(from: command.payload),
                maximumSnapshotBytes: Self.maximumSnapshotBytes
            )
            let snapshot: TerminalSnapshot
            switch result {
            case let .snapshot(value, _): snapshot = value
            case let .current(value):
                snapshot = TerminalSnapshot(
                    streamEpoch: value.streamEpoch,
                    output: "",
                    startOffset: value.offset,
                    endOffset: value.offset,
                    truncated: value.offset > 0,
                    exited: terminal.exited
                )
            }
            streams[key] = Stream(
                terminal: terminal,
                snapshot: snapshot,
                members: [connectionID]
            )
            return response(
                command,
                status: .applied,
                message: "Terminal stream subscribed.",
                snapshot: try snapshotBody(
                    projectID: key.projectID,
                    terminalID: key.terminalID,
                    snapshot: snapshot
                )
            )
        } catch {
            return response(
                command,
                status: .unavailable,
                message: "The terminal engine is temporarily unavailable."
            )
        }
    }

    func unsubscribe(
        connectionID: String,
        command: CompanionCommandBody,
        terminal: BrokerTerminalRecord?
    ) async -> CompanionTerminalSubscriptionResponse {
        let key = Key(projectID: command.projectId, terminalID: command.targetId)
        guard var stream = streams[key] else {
            return response(command, status: .applied, message: "Terminal stream was already unsubscribed.")
        }
        stream.members.remove(connectionID)
        if stream.members.isEmpty {
            streams.removeValue(forKey: key)
            try? await broker.unsubscribe(from: terminal ?? stream.terminal, ownerID: ownerID)
        } else {
            streams[key] = stream
        }
        return response(command, status: .applied, message: "Terminal stream unsubscribed.")
    }

    func currentSnapshot(
        connectionID: String,
        command: CompanionCommandBody
    ) -> CompanionBody? {
        let key = Key(projectID: command.projectId, terminalID: command.targetId)
        guard let stream = streams[key], stream.members.contains(connectionID) else { return nil }
        return try? snapshotBody(
            projectID: key.projectID,
            terminalID: key.terminalID,
            snapshot: resumedSnapshot(stream.snapshot, payload: command.payload)
        )
    }

    func releaseConnection(_ connectionID: String) async {
        for key in Array(streams.keys) {
            guard var stream = streams[key], stream.members.remove(connectionID) != nil else { continue }
            if stream.members.isEmpty {
                streams.removeValue(forKey: key)
                try? await broker.unsubscribe(from: stream.terminal, ownerID: ownerID)
            } else {
                streams[key] = stream
            }
        }
    }

    func shutdown() async {
        streams.removeAll()
        connected = false
        await broker.disconnect()
    }

    private func ensureConnected() async throws {
        if !configured {
            configured = true
            await broker.setEventHandler { [weak self] event in
                Task { await self?.handle(event) }
            }
            await broker.setDisconnectHandler { [weak self] _ in
                Task { await self?.brokerDisconnected() }
            }
        }
        guard !connected else { return }
        _ = try await broker.connect(to: locator.locate())
        connected = true
    }

    private func handle(_ event: BrokerEvent) async {
        guard event.ownerID == ownerID else { return }
        let projectID = portableID(event.projectID, domain: "project", maximum: 160)
        let terminalID = portableID(event.terminalID, domain: "session", maximum: 240)
        let key = Key(projectID: projectID, terminalID: terminalID)
        guard var stream = streams[key], !stream.members.isEmpty else { return }
        do {
            switch event.kind {
            case let .output(epoch, startOffset, endOffset, data):
                guard Int64(data.utf8.count) == endOffset - startOffset else {
                    throw BrokerClientError.malformedResponse
                }
                if epoch == stream.snapshot.streamEpoch,
                   endOffset <= stream.snapshot.endOffset { return }
                guard epoch == stream.snapshot.streamEpoch,
                      startOffset == stream.snapshot.endOffset else {
                    throw BrokerClientError.malformedResponse
                }
                stream.snapshot = append(data, to: stream.snapshot, endOffset: endOffset)
                streams[key] = stream
                let body = try CompanionBody(CompanionTerminalOutputBody(
                    type: "terminal.output",
                    projectId: key.projectID,
                    terminalId: key.terminalID,
                    streamEpoch: epoch,
                    startOffset: startOffset,
                    endOffset: endOffset,
                    data: data
                ))
                emit(kind: .event, prefix: "terminal-output", stream: stream, key: key, body: body)
            case .snapshotRequired:
                let body = try CompanionBody(fields: [
                    "type": .string("terminal.snapshot"),
                    "projectId": .string(key.projectID),
                    "terminalId": .string(key.terminalID),
                    "streamEpoch": .string(stream.snapshot.streamEpoch),
                    "endOffset": .integer(stream.snapshot.endOffset),
                    "snapshotRequired": .bool(true),
                    "reason": .string("broker_resync"),
                ])
                // `snapshot` is reserved for the whole `snapshot.projects`
                // replacement in CompanionStore. A terminal replacement is an
                // ordered event whose body type is `terminal.snapshot`.
                emit(kind: .event, prefix: "terminal-reset", stream: stream, key: key, body: body)
            case .exit:
                stream.snapshot = TerminalSnapshot(
                    streamEpoch: stream.snapshot.streamEpoch,
                    output: stream.snapshot.output,
                    startOffset: stream.snapshot.startOffset,
                    endOffset: stream.snapshot.endOffset,
                    truncated: stream.snapshot.truncated,
                    exited: true,
                    readError: stream.snapshot.readError
                )
                streams[key] = stream
                let body = try CompanionBody(fields: [
                    "type": .string("terminal.exit"),
                    "projectId": .string(key.projectID),
                    "terminalId": .string(key.terminalID),
                    "streamEpoch": .string(stream.snapshot.streamEpoch),
                    "offset": .integer(stream.snapshot.endOffset),
                ])
                emit(kind: .event, prefix: "terminal-exit", stream: stream, key: key, body: body)
            case .activity:
                break
            }
        } catch {
            let body = try? CompanionBody(fields: [
                "type": .string("terminal.snapshot"),
                "projectId": .string(key.projectID),
                "terminalId": .string(key.terminalID),
                "streamEpoch": .string(stream.snapshot.streamEpoch),
                "endOffset": .integer(stream.snapshot.endOffset),
                "snapshotRequired": .bool(true),
                "reason": .string("cursor_gap"),
            ])
            if let body { emit(kind: .event, prefix: "terminal-reset", stream: stream, key: key, body: body) }
        }
    }

    private func brokerDisconnected() {
        connected = false
        let active = streams
        streams.removeAll()
        for (key, stream) in active {
            guard let body = try? CompanionBody(fields: [
                "type": .string("terminal.snapshot"),
                "projectId": .string(key.projectID),
                "terminalId": .string(key.terminalID),
                "streamEpoch": .string(stream.snapshot.streamEpoch),
                "endOffset": .integer(stream.snapshot.endOffset),
                "snapshotRequired": .bool(true),
                "reason": .string("broker_restarted"),
            ]) else { continue }
            emit(kind: .event, prefix: "terminal-reset", stream: stream, key: key, body: body)
        }
    }

    private func emit(
        kind: CompanionEnvelopeKind,
        prefix: String,
        stream: Stream,
        key: Key,
        body: CompanionBody
    ) {
        eventSink(CompanionTerminalStreamDelivery(
            connectionIDs: stream.members,
            kind: kind,
            id: "\(prefix)-\(portableID(key.terminalID, domain: "event", maximum: 80))-\(UUID().uuidString.lowercased())",
            body: body
        ))
    }

    private func append(_ data: String, to snapshot: TerminalSnapshot, endOffset: Int64) -> TerminalSnapshot {
        let combined = Data((snapshot.output + data).utf8)
        var start = max(0, combined.count - Self.maximumSnapshotBytes)
        while start < combined.count, combined[start] & 0xC0 == 0x80 { start += 1 }
        let tail = String(decoding: combined[start...], as: UTF8.self)
        return TerminalSnapshot(
            streamEpoch: snapshot.streamEpoch,
            output: tail,
            startOffset: endOffset - Int64(tail.utf8.count),
            endOffset: endOffset,
            truncated: snapshot.truncated || start > 0,
            exited: false,
            readError: snapshot.readError
        )
    }

    private func resumedSnapshot(
        _ snapshot: TerminalSnapshot,
        payload: [String: JSONValue]?
    ) -> TerminalSnapshot {
        guard let cursor = try? cursor(from: payload),
              cursor.streamEpoch == snapshot.streamEpoch,
              cursor.offset >= snapshot.startOffset,
              cursor.offset <= snapshot.endOffset else { return snapshot }
        let relative = Int(cursor.offset - snapshot.startOffset)
        let bytes = Data(snapshot.output.utf8)
        guard relative <= bytes.count,
              relative == bytes.count || bytes[relative] & 0xC0 != 0x80 else { return snapshot }
        let suffix = String(decoding: bytes[relative...], as: UTF8.self)
        return TerminalSnapshot(
            streamEpoch: snapshot.streamEpoch,
            output: suffix,
            startOffset: cursor.offset,
            endOffset: snapshot.endOffset,
            truncated: snapshot.truncated || cursor.offset > 0,
            exited: snapshot.exited,
            readError: snapshot.readError
        )
    }

    private func cursor(from payload: [String: JSONValue]?) throws -> TerminalCursor? {
        let epoch = payload?["streamEpoch"]?.stringValue
        let offset = payload?["afterOffset"]?.intValue
        guard (epoch == nil) == (offset == nil) else {
            throw BrokerClientError.requestFailed("terminal cursor incomplete")
        }
        guard let epoch, let offset else { return nil }
        guard !epoch.isEmpty, offset >= 0 else {
            throw BrokerClientError.requestFailed("terminal cursor invalid")
        }
        return TerminalCursor(streamEpoch: epoch, offset: offset)
    }

    private func exact(command: CompanionCommandBody, terminal: BrokerTerminalRecord) -> Bool {
        portableID(terminal.id, domain: "session", maximum: 240) == command.targetId
            && portableID(terminal.projectID, domain: "project", maximum: 160) == command.projectId
    }

    private func snapshotBody(
        projectID: String,
        terminalID: String,
        snapshot: TerminalSnapshot
    ) throws -> CompanionBody {
        try CompanionBody(fields: [
            "type": .string("terminal.snapshot"),
            "projectId": .string(projectID),
            "terminalId": .string(terminalID),
            "mode": .string("snapshot"),
            "streamEpoch": .string(snapshot.streamEpoch),
            "output": .string(snapshot.output),
            "startOffset": .integer(snapshot.startOffset),
            "endOffset": .integer(snapshot.endOffset),
            "truncated": .bool(snapshot.truncated),
            "exited": .bool(snapshot.exited),
        ])
    }

    private func response(
        _ command: CompanionCommandBody,
        status: CompanionReceiptStatus,
        message: String,
        snapshot: CompanionBody? = nil
    ) -> CompanionTerminalSubscriptionResponse {
        CompanionTerminalSubscriptionResponse(
            receipt: CompanionReceiptBody(
                type: "command.receipt",
                commandId: command.commandId,
                status: status,
                message: String(message.prefix(800)),
                payload: nil
            ),
            initialSnapshot: snapshot
        )
    }

    private func portableID(_ value: String, domain: String, maximum: Int) -> String {
        RememberedSessionCatalogPortable.id(
            value,
            domain: domain,
            maximumUTF8Bytes: maximum
        )
    }
}
