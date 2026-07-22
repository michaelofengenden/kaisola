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
    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws
    func disconnect() async
}

actor ObserveOnlyBrokerClient: ObserveOnlyBrokerServing {
    typealias EventHandler = @Sendable (BrokerEvent) -> Void
    typealias DisconnectHandler = @Sendable (any Error) -> Void

    private let transport: any BrokerByteTransport
    private let operationTimeoutNanoseconds: UInt64
    private var decoder = BrokerLineFrameDecoder()
    private var info: BrokerInfo?
    private var hello: BrokerHello?
    private var helloWaiter: CheckedContinuation<BrokerHello, any Error>?
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

    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        if let hello { return hello }
        try info.validate()
        self.info = info
        try await transport.connect(path: info.socketPath)
        readerTask = Task { await readLoop() }

        let frame: JSONValue = .object([
            "type": .string("hello"),
            "protocol": .integer(Int64(BrokerWire.protocolVersion)),
            "token": .string(info.token),
            "instanceId": .string(UUID().uuidString.lowercased()),
            "appVersion": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "native-preview"),
            "access": .string("observer"),
        ])
        let encoded = try encode(frame)

        return try await withCheckedThrowingContinuation { continuation in
            helloWaiter = continuation
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: operationTimeoutNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await abortConnection(with: BrokerClientError.connectionTimedOut)
            }
            Task {
                do { try await transport.send(encoded) }
                catch { await abortConnection(with: error) }
            }
        }
    }

    func inventory() async throws -> BrokerStatus {
        // These are typed read methods. The raw request encoder stays private,
        // so application code cannot represent or emit an arbitrary method.
        let status = try await request(.status, params: .object(["ownerId": .string("0")]))
        let diagnostics = try await request(.diagnostics, params: .object(["ownerId": .string("0")]))
        let live = try await request(.list, params: .object(["ownerId": .string("0")]))
        return try BrokerStatus(status: status, diagnostics: diagnostics, live: live)
    }

    func subscribe(
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

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {
        _ = try await request(.unsubscribe, params: .object([
            "id": .string(terminal.id),
            "ownerId": .string(ownerID),
            "projectId": .string(terminal.projectID),
        ]))
    }

    func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        for task in requestTimeoutTasks.values { task.cancel() }
        requestTimeoutTasks.removeAll()
        await transport.close()
        failConnection(with: BrokerClientError.connectionClosed)
        decoder = BrokerLineFrameDecoder()
        info = nil
        hello = nil
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

    private func readLoop() async {
        do {
            while !Task.isCancelled {
                guard let data = try await transport.receive(maximumBytes: 64 * 1_024) else {
                    throw BrokerClientError.connectionClosed
                }
                if data.isEmpty { continue }
                var activeDecoder = decoder
                try activeDecoder.consume(data) { data in
                    let frame = try JSONDecoder().decode(JSONValue.self, from: data)
                    try handle(frame)
                }
                decoder = activeDecoder
            }
        } catch {
            if !Task.isCancelled { await abortConnection(with: error) }
        }
    }

    private func abortConnection(with error: any Error) async {
        await transport.close()
        readerTask = nil
        decoder = BrokerLineFrameDecoder()
        failConnection(with: error)
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
            guard object["pid"]?.intValue == Int64(info.pid) else { throw BrokerClientError.identityChanged }
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
            helloWaiter?.resume(returning: hello)
            helloWaiter = nil
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
        helloWaiter?.resume(throwing: error)
        helloWaiter = nil
        for task in requestTimeoutTasks.values { task.cancel() }
        requestTimeoutTasks.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        hello = nil
    }
}
