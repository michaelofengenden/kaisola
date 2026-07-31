import Foundation
import KaisolaBrokerProtocol
import KaisolaCore

protocol ObserveOnlyBrokerServing: Sendable {
    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async
    func connect(to info: BrokerInfo) async throws -> BrokerHello
    func inventory() async throws -> BrokerStatus
    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult
    func historyPage(
        for terminal: BrokerTerminalRecord,
        ownerID: String,
        streamEpoch: String,
        beforeOffset: Int64,
        maxBytes: Int
    ) async throws -> TerminalHistoryPage
    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws
    func disconnect() async
}

extension ObserveOnlyBrokerServing {
    /// Test doubles and older alternative clients remain source-compatible;
    /// the production client below is the only implementation that advertises
    /// and performs the additive read-only history request.
    func historyPage(
        for terminal: BrokerTerminalRecord,
        ownerID: String,
        streamEpoch: String,
        beforeOffset: Int64,
        maxBytes: Int
    ) async throws -> TerminalHistoryPage {
        throw BrokerClientError.requestFailed("terminal.history unavailable")
    }
}

/// How much retained spool a cold terminal selection pulls into memory.
///
/// Selection used to page backwards until it held 64 MiB, which cost up to
/// sixteen sequential `terminal.history` round trips — each with its own
/// five-second deadline — before the first frame could be published, and left
/// that string resident for every terminal the user visited.
///
/// Almost none of it was reachable. SwiftTerm keeps
/// `NativePreviewSettings.terminalScrollbackDefault` lines in a circular
/// buffer and discards the rest, so bytes past that depth cannot be scrolled
/// to no matter how many were fetched. Deeper history is the transcript
/// viewer's job: it pages the same request on demand against a cursor frozen
/// at open time, which is also the only way to read old bytes without
/// re-feeding ANSI into a live renderer.
enum ObserverHistoryTailPolicy {
    /// The broker answers `terminal.history` with at most 4 MiB per page and
    /// caps its own subscribe snapshot at the same size, so a tail of exactly
    /// one page means a cold selection normally issues *zero* extra requests
    /// and never more than one. 4 MiB also covers 20,000 rows at 200 columns —
    /// SwiftTerm's whole default scrollback — so a deeper tail could not put a
    /// single additional row within reach.
    static let coldSubscribeTailBytes = 4 * 1_024 * 1_024
    static let maximumPageBytes = 4 * 1_024 * 1_024

    /// Bytes to request immediately before a cold snapshot, or `nil` when the
    /// snapshot already covers the tail or the stream has no earlier bytes.
    /// Always satisfiable by a single page.
    static func coldTailRequestBytes(snapshotBytes: Int, startOffset: Int64) -> Int? {
        guard snapshotBytes >= 0, startOffset > 0 else { return nil }
        let deficit = coldSubscribeTailBytes - snapshotBytes
        guard deficit > 0 else { return nil }
        return min(deficit, maximumPageBytes, Int(clamping: startOffset))
    }
}

actor ObserveOnlyBrokerClient: ObserveOnlyBrokerServing {
    typealias EventHandler = @Sendable (BrokerEvent) -> Void
    typealias DisconnectHandler = @Sendable (any Error) -> Void
    private static let historyPageBytes = ObserverHistoryTailPolicy.maximumPageBytes

    private let transport: any BrokerByteTransport
    private let operationTimeoutNanoseconds: UInt64
    private var decoder = BrokerLineFrameDecoder()
    private var info: BrokerInfo?
    private var hello: BrokerHello?
    private var connectTarget: BrokerInfo?
    private var connectWaiters: [CheckedContinuation<BrokerHello, any Error>] = []
    private var connectAttemptTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var readerTask: Task<Void, Never>?
    private var eventHandler: EventHandler?
    private var disconnectHandler: DisconnectHandler?

    init(
        transport: any BrokerByteTransport = UnixBrokerTransport(),
        operationTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        precondition(operationTimeoutNanoseconds > 0)
        self.transport = transport
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
    }

    func setEventHandler(_ handler: EventHandler?) async {
        eventHandler = handler
    }

    func setDisconnectHandler(_ handler: DisconnectHandler?) async {
        disconnectHandler = handler
    }

    func connect(to requestedInfo: BrokerInfo) async throws -> BrokerHello {
        try requestedInfo.validate()

        if let hello {
            guard info == requestedInfo else { throw BrokerClientError.identityChanged }
            return hello
        }
        if let connectTarget {
            guard connectTarget == requestedInfo else {
                throw BrokerClientError.identityChanged
            }
            return try await waitForConnectResult()
        }

        connectionGeneration &+= 1
        let generation = connectionGeneration
        info = requestedInfo
        connectTarget = requestedInfo
        return try await withCheckedThrowingContinuation { continuation in
            connectWaiters.append(continuation)
            connectAttemptTask = Task { [weak self] in
                await self?.performConnect(to: requestedInfo, generation: generation)
            }
        }
    }

    private func waitForConnectResult() async throws -> BrokerHello {
        try await withCheckedThrowingContinuation { continuation in
            connectWaiters.append(continuation)
        }
    }

    private func performConnect(to info: BrokerInfo, generation: UInt64) async {
        do {
            try await transport.connect(path: info.socketPath)
            guard generation == connectionGeneration, connectTarget == info else { return }

            readerTask = Task { [weak self] in
                await self?.readLoop(generation: generation)
            }
            let frame: JSONValue = .object([
                "type": .string("hello"),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "token": .string(info.token),
                "instanceId": .string(UUID().uuidString.lowercased()),
                "appVersion": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "kaisola-native"),
                "access": .string("observer"),
            ])
            let encoded = try encode(frame)

            handshakeTimeoutTask?.cancel()
            let timeoutNanoseconds = operationTimeoutNanoseconds
            handshakeTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.handshakeTimedOut(generation: generation)
            }
            try await transport.send(encoded)
        } catch {
            await abortConnection(with: error, generation: generation)
        }
    }

    private func handshakeTimedOut(generation: UInt64) async {
        guard generation == connectionGeneration,
              connectTarget != nil,
              hello == nil else { return }
        await abortConnection(
            with: BrokerClientError.connectionTimedOut,
            generation: generation
        )
    }

    func inventory() async throws -> BrokerStatus {
        guard let hello else { throw BrokerClientError.notConnected }
        // These are typed read methods. The raw request encoder stays private,
        // so application code cannot represent or emit an arbitrary method.
        let status = try await request(.status, params: .object(["ownerId": .string("0")]))
        let diagnostics = try await request(.diagnostics, params: .object(["ownerId": .string("0")]))
        let live = try await request(.list, params: .object(["ownerId": .string("0")]))
        return try BrokerStatus(
            status: status,
            diagnostics: diagnostics,
            live: live,
            expectedHello: hello
        )
    }

    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        let result = try await subscribeWire(
            to: terminal,
            ownerID: ownerID,
            cursor: cursor
        )
        switch result {
        case let .snapshot(snapshot, resetReason):
            return .snapshot(
                await prependColdTail(
                    snapshot,
                    terminal: terminal,
                    ownerID: ownerID
                ),
                resetReason: resetReason
            )
        case .current:
            return result
        }
    }

    /// Companion screens need a quick terminal tail, not the desktop's entire
    /// retained transcript. This uses the same typed observer request but never
    /// pages older spool data, then trims at a valid UTF-8 scalar boundary.
    func subscribeBounded(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?,
        maximumSnapshotBytes: Int
    ) async throws -> TerminalSubscriptionResult {
        guard 1...(512 * 1_024) ~= maximumSnapshotBytes else {
            throw BrokerClientError.requestFailed("terminal snapshot limit")
        }
        let result = try await subscribeWire(
            to: terminal,
            ownerID: ownerID,
            cursor: cursor
        )
        switch result {
        case let .snapshot(snapshot, resetReason):
            return .snapshot(
                Self.bounded(snapshot, maximumBytes: maximumSnapshotBytes),
                resetReason: resetReason
            )
        case .current:
            return result
        }
    }

    private func subscribeWire(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        var params: [String: JSONValue] = [
            "id": .string(terminal.id),
            "ownerId": .string(ownerID),
            "projectId": .string(terminal.projectID),
            "maxQueueBytes": .integer(512 * 1_024),
        ]
        if let cursor {
            params["streamEpoch"] = .string(cursor.streamEpoch)
            params["afterOffset"] = .integer(cursor.offset)
        }
        let result = try await request(.subscribe, params: .object(params))
        guard let object = result.objectValue, object["ok"]?.boolValue == true else {
            throw BrokerClientError.requestFailed("subscribe")
        }
        let resetReason = object["resetReason"]?.stringValue
        switch object["mode"]?.stringValue {
        case "snapshot":
            guard let value = object["snapshot"] else { throw BrokerClientError.malformedResponse }
            return .snapshot(try TerminalSnapshot(value: value), resetReason: resetReason)
        case "current":
            guard let cursorObject = object["cursor"]?.objectValue,
                  let epoch = cursorObject["streamEpoch"]?.stringValue,
                  let offset = cursorObject["offset"]?.intValue else {
                throw BrokerClientError.malformedResponse
            }
            return .current(TerminalCursor(streamEpoch: epoch, offset: offset))
        default:
            throw BrokerClientError.malformedResponse
        }
    }

    private static func bounded(
        _ snapshot: TerminalSnapshot,
        maximumBytes: Int
    ) -> TerminalSnapshot {
        let bytes = Data(snapshot.output.utf8)
        guard bytes.count > maximumBytes else { return snapshot }
        var start = bytes.count - maximumBytes
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        let tail = String(decoding: bytes[start...], as: UTF8.self)
        let retained = Int64(tail.utf8.count)
        return TerminalSnapshot(
            streamEpoch: snapshot.streamEpoch,
            output: tail,
            startOffset: snapshot.endOffset - retained,
            endOffset: snapshot.endOffset,
            truncated: true,
            exited: snapshot.exited
        )
    }

    /// Top a cold snapshot up to `ObserverHistoryTailPolicy.coldSubscribeTailBytes`
    /// with at most one read-only page, then stop. Anything older stays in the
    /// broker's spool, where the transcript viewer pages it on demand.
    ///
    /// Older compatible brokers reject this additive method, in which case the
    /// ordinary reattach snapshot remains a safe fallback until the broker can
    /// be upgraded without interrupting a live PTY.
    private func prependColdTail(
        _ snapshot: TerminalSnapshot,
        terminal: BrokerTerminalRecord,
        ownerID: String
    ) async -> TerminalSnapshot {
        guard hello?.features.contains(BrokerWire.terminalHistoryFeature) == true,
              let requestedBytes = ObserverHistoryTailPolicy.coldTailRequestBytes(
                  snapshotBytes: snapshot.output.utf8.count,
                  startOffset: snapshot.startOffset
              ) else {
            return snapshot
        }

        let page: TerminalHistoryPage
        do {
            page = try await historyPage(
                for: terminal,
                ownerID: ownerID,
                streamEpoch: snapshot.streamEpoch,
                beforeOffset: snapshot.startOffset,
                maxBytes: requestedBytes
            )
        } catch {
            return snapshot
        }
        // `TerminalHistoryPage` already proves the page ends exactly at the
        // requested offset and that its byte span matches its output, so the
        // concatenation below preserves the snapshot's cursor arithmetic.
        guard page.startOffset < page.endOffset else { return snapshot }

        return TerminalSnapshot(
            streamEpoch: snapshot.streamEpoch,
            output: page.output + snapshot.output,
            startOffset: page.startOffset,
            endOffset: snapshot.endOffset,
            truncated: page.hasMore || page.truncated || page.startOffset > 0,
            exited: snapshot.exited
        )
    }

    func historyPage(
        for terminal: BrokerTerminalRecord,
        ownerID: String,
        streamEpoch: String,
        beforeOffset: Int64,
        maxBytes: Int
    ) async throws -> TerminalHistoryPage {
        guard hello?.features.contains(BrokerWire.terminalHistoryFeature) == true else {
            throw BrokerClientError.requestFailed("terminal.history unavailable")
        }
        guard !streamEpoch.isEmpty,
              beforeOffset >= 0,
              1...Self.historyPageBytes ~= maxBytes else {
            throw BrokerClientError.requestFailed("terminal.history invalid range")
        }
        let value = try await request(.history, params: .object([
            "id": .string(terminal.id),
            "ownerId": .string(ownerID),
            "projectId": .string(terminal.projectID),
            "streamEpoch": .string(streamEpoch),
            "beforeOffset": .integer(beforeOffset),
            "maxBytes": .integer(Int64(maxBytes)),
        ]))
        return try TerminalHistoryPage(
            value: value,
            expectedEpoch: streamEpoch,
            beforeOffset: beforeOffset
        )
    }

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {
        _ = try await request(.unsubscribe, params: .object([
            "id": .string(terminal.id),
            "ownerId": .string(ownerID),
            "projectId": .string(terminal.projectID),
        ]))
    }

    func disconnect() async {
        connectionGeneration &+= 1
        connectAttemptTask?.cancel()
        connectAttemptTask = nil
        connectTarget = nil
        readerTask?.cancel()
        readerTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        for task in requestTimeoutTasks.values { task.cancel() }
        requestTimeoutTasks.removeAll()
        failConnection(with: BrokerClientError.connectionClosed)
        decoder = BrokerLineFrameDecoder()
        info = nil
        hello = nil
        await transport.close()
    }

    private func request(_ method: ObserveOnlyBrokerMethod, params: JSONValue) async throws -> JSONValue {
        guard hello != nil else { throw BrokerClientError.notConnected }
        _ = try ObserveOnlyBrokerPolicy.validate(method.rawValue)
        let requestID = UUID().uuidString.lowercased()
        let frame: JSONValue = .object([
            "type": .string("request"),
            "id": .string(requestID),
            "method": .string(method.rawValue),
            "params": params,
        ])
        let encoded = try encode(frame)
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            requestTimeoutTasks[requestID] = Task {
                do {
                    try await Task.sleep(nanoseconds: operationTimeoutNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                failRequest(requestID, with: BrokerClientError.requestTimedOut)
            }
            Task {
                do { try await transport.send(encoded) }
                catch { failRequest(requestID, with: error) }
            }
        }
    }

    private func readLoop(generation: UInt64) async {
        do {
            while !Task.isCancelled {
                guard let data = try await transport.receive(maximumBytes: 64 * 1_024) else {
                    throw BrokerClientError.connectionClosed
                }
                guard generation == connectionGeneration else { return }
                if data.isEmpty { continue }
                var activeDecoder = decoder
                try activeDecoder.consume(data) { data in
                    let frame = try JSONDecoder().decode(JSONValue.self, from: data)
                    try handle(frame)
                }
                decoder = activeDecoder
            }
        } catch {
            if !Task.isCancelled {
                await abortConnection(with: error, generation: generation)
            }
        }
    }

    private func abortConnection(with error: any Error, generation: UInt64) async {
        guard generation == connectionGeneration else { return }
        connectionGeneration &+= 1
        connectAttemptTask?.cancel()
        connectAttemptTask = nil
        connectTarget = nil
        readerTask?.cancel()
        readerTask = nil
        decoder = BrokerLineFrameDecoder()
        failConnection(with: error)
        info = nil
        await transport.close()
        disconnectHandler?(error)
    }

    private func handle(_ frame: JSONValue) throws {
        guard let object = frame.objectValue, let type = object["type"]?.stringValue else {
            throw BrokerClientError.malformedResponse
        }
        switch type {
        case "hello":
            guard let info else { throw BrokerClientError.notConnected }
            guard object["ok"]?.boolValue == true else { throw BrokerClientError.authenticationRejected }
            guard object["protocol"]?.intValue == Int64(BrokerWire.protocolVersion) else {
                throw BrokerClientError.protocolMismatch
            }
            guard object["securityEpoch"]?.intValue == Int64(BrokerWire.securityEpoch) else {
                throw BrokerClientError.securityEpochMismatch
            }
            let advertisedImplementation = object["implementationVersion"]?.intValue.flatMap(Int.init(exactly:))
            guard BrokerWire.accepts(
                protocolVersion: BrokerWire.protocolVersion,
                securityEpoch: BrokerWire.securityEpoch,
                implementationVersion: advertisedImplementation
            ) else {
                throw BrokerClientError.implementationMismatch
            }
            let implementationVersion = advertisedImplementation ?? BrokerWire.implementationVersion
            let packageSchema = object["packageSchema"]?.intValue.flatMap(Int.init(exactly:))
            let packageVersion = object["packageVersion"]?.stringValue
            let contentDigest = object["contentDigest"]?.stringValue
            if let contentDigest,
               !BrokerHelperPackageVerification.isLowercaseSHA256(contentDigest) {
                throw BrokerClientError.identityChanged
            }
            guard object["pid"]?.intValue == Int64(info.pid),
                  object["startedAt"]?.intValue == info.startedAt,
                  info.implementationVersion == nil || info.implementationVersion == implementationVersion,
                  info.packageSchema == nil || info.packageSchema == packageSchema,
                  info.packageVersion == nil || info.packageVersion == packageVersion,
                  info.contentDigest == nil || info.contentDigest == contentDigest else {
                throw BrokerClientError.identityChanged
            }
            let features = Set(object["features"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            guard features.contains(BrokerWire.terminalObserveFeature) else {
                throw BrokerClientError.observeFeatureMissing
            }
            let serverEnforcesObserver = features.contains(BrokerWire.observerRoleFeature)
            if serverEnforcesObserver, object["access"]?.stringValue != "observer" {
                throw BrokerClientError.authenticationRejected
            }
            let hello = BrokerHello(
                protocolVersion: BrokerWire.protocolVersion,
                securityEpoch: BrokerWire.securityEpoch,
                implementationVersion: implementationVersion,
                packageSchema: packageSchema,
                packageVersion: packageVersion,
                contentDigest: contentDigest,
                features: features,
                pid: info.pid,
                startedAt: object["startedAt"]?.intValue ?? info.startedAt,
                version: object["version"]?.stringValue ?? info.version,
                // Old protocol-2 brokers ignore the additive access marker.
                // Local typed policy still keeps them observe-only; upgraded
                // brokers additionally enforce the same role at the server.
                serverEnforcedObserver: serverEnforcesObserver
            )
            self.hello = hello
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            connectAttemptTask = nil
            connectTarget = nil
            let waiters = connectWaiters
            connectWaiters.removeAll()
            for waiter in waiters { waiter.resume(returning: hello) }
        case "response":
            guard let id = object["id"]?.stringValue, let continuation = pending.removeValue(forKey: id) else {
                return
            }
            requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            if object["ok"]?.boolValue == true, let result = object["result"] {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: BrokerClientError.requestFailed(object["message"]?.stringValue ?? "request"))
            }
        case "event":
            if let event = BrokerEvent(frame: frame) { eventHandler?(event) }
        default:
            break
        }
    }

    private func encode(_ frame: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        guard data.count <= BrokerWire.maximumFrameBytes else { throw BrokerClientError.frameRejected }
        data.append(0x0A)
        return data
    }

    private func failRequest(_ id: String, with error: any Error) {
        requestTimeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failConnection(with error: any Error) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
        for task in requestTimeoutTasks.values { task.cancel() }
        requestTimeoutTasks.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        hello = nil
    }
}
