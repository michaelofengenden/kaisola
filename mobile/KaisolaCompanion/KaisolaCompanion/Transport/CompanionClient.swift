import CryptoKit
import Foundation

enum CompanionCommandError: LocalizedError, Equatable {
    case unavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable: "The Mac disconnected before confirming this action. It was not retried."
        case .timedOut: "The Mac did not confirm this action in time. It was not retried."
        }
    }
}

@MainActor
final class CompanionClient: ObservableObject {
    @Published private(set) var sas: CompanionSAS?
    @Published private(set) var lastError: String?
    @Published private(set) var pairedDesktop: CompanionPairedDesktop?

    var onEnvelope: ((CompanionEnvelope) -> Void)?
    var onTransportState: ((CompanionTransportState) -> Void)?
    var onPairedDesktop: ((CompanionPairedDesktop) -> Void)?
    var onAckCursor: ((CompanionAckCursor) -> Void)?
    var onCapabilities: ((Set<CompanionCapability>) -> Void)?
    var onStreamIssue: ((String, String?) -> Void)?

    let transport: CompanionTransport

    private enum Mode { case pairing(CompanionPairingPayload), resume(CompanionPairedDesktop) }
    private var mode: Mode?
    private var identity: CompanionIdentity?
    private var initiator: NoiseXXInitiator?
    private var handshakeResult: NoiseHandshakeResult?
    private var channel: SecureFrameChannel?
    private var connectionContext: CompanionConnectionContext?
    private var sessionId: String?
    private var localSASConfirmed = false
    private var remoteSASConfirmed = false
    private var outboundSeq: Int64 = 0
    private(set) var ackCursor: CompanionAckCursor?
    // Epoch observed on THIS connection's inbound frames. The desktop
    // regenerates its epoch every launch and rejects any command whose epoch
    // differs, so after a resume across a desktop restart the persisted
    // ackCursor epoch is stale. We learn the live epoch from the first inbound
    // frame (the desktop's hello reply carries it) and gate outbound commands
    // on it — otherwise the first stream.subscribe tears the connection down.
    private var liveEpoch: String?
    private struct StreamSubscription: Hashable {
        let projectId: String
        let sessionId: String
    }
    private var desiredStreamSubscriptions: Set<StreamSubscription> = []
    private var activeStreamSubscriptions: Set<StreamSubscription> = []
    private var streamSubscriptionTasks: [StreamSubscription: Task<Void, Never>] = [:]
    private var streamSubscriptionGenerations: [StreamSubscription: Int] = [:]
    private var pendingCommands: [String: CheckedContinuation<CompanionReceiptBody, Error>] = [:]
    private var commandTimeouts: [String: Task<Void, Never>] = [:]

    init(transport: CompanionTransport = CompanionTransport()) {
        self.transport = transport
        transport.onWireFrame = { [weak self] data in try self?.receive(data) }
        transport.onStateChange = { [weak self] state in
            guard let self else { return }
            self.onTransportState?(state)
            if state != .live {
                self.resetActiveStreamSubscriptions()
                self.failPendingCommands(with: CompanionCommandError.unavailable)
            }
            if state == .handshaking, case .resume = self.mode {
                do { try self.startHandshake() } catch { self.fail(error) }
            }
        }
        transport.onError = { [weak self] error in
            guard let self else { return }
            switch self.transport.state {
            case .discovering, .connecting, .live, .reconnecting:
                // Direct endpoint and Bonjour failures are recoverable. The
                // transport keeps racing/retrying them without invalidating the
                // single-use offer or flashing a terminal error in the UI.
                break
            case .idle, .handshaking:
                self.fail(error)
            }
        }
    }

    func beginPairing(payload: CompanionPairingPayload, identity: CompanionIdentity) throws {
        try payload.validate()
        guard identity.role == .device else { throw CompanionCryptoError.roleMismatch }
        self.identity = identity
        pairedDesktop = nil
        ackCursor = nil
        desiredStreamSubscriptions.removeAll()
        mode = .pairing(payload)
        try startHandshake()
    }

    func configureResume(
        desktop: CompanionPairedDesktop,
        identity: CompanionIdentity,
        cursor: CompanionAckCursor?
    ) throws {
        guard identity.role == .device else { throw CompanionCryptoError.roleMismatch }
        self.identity = identity
        pairedDesktop = desktop
        mode = .resume(desktop)
        ackCursor = cursor
        if transport.state == .handshaking { try startHandshake() }
    }

    func confirmSAS() throws {
        guard case .pairing = mode,
              let channel,
              let result = handshakeResult,
              !localSASConfirmed else { throw CompanionCryptoError.handshakeOrder }
        let payload: JSONValue = .object([
            "type": .string("sas-confirm"),
            "role": .string(CompanionPeerRole.device.rawValue),
            "transcriptHash": .string(result.handshakeHash.base64URLEncodedString()),
        ])
        try sendSecureFrame(channel.encrypt(payload))
        localSASConfirmed = true
    }

    /// Subscribe to (or unsubscribe from) a terminal's live byte stream. The
    /// desktop filters terminal.output to subscribed sessions, so the phone must
    /// ask before deltas flow — the snapshot arrives regardless.
    func setStreamSubscription(
        projectId: String,
        sessionId: String,
        subscribed: Bool,
        force: Bool = false
    ) throws {
        let subscription = StreamSubscription(projectId: projectId, sessionId: sessionId)
        if subscribed {
            desiredStreamSubscriptions.insert(subscription)
            onStreamIssue?(sessionId, nil)
            guard transport.state == .live else { return }
            if force { invalidateStreamSubscription(subscription) }
            startStreamSubscription(subscription)
        } else {
            desiredStreamSubscriptions.remove(subscription)
            let wasActive = activeStreamSubscriptions.contains(subscription)
            invalidateStreamSubscription(subscription)
            onStreamIssue?(sessionId, nil)
            // A subscribe that never became active has nothing remote to tear
            // down. Skipping that no-op removes the recurring “already
            // unsubscribed” receipt while keeping real teardown exact.
            guard wasActive else { return }
            guard transport.state == .live else { return }
            try sendStreamSubscription(subscription, subscribed: false)
        }
    }

    private func startStreamSubscription(_ subscription: StreamSubscription) {
        guard transport.state == .live,
              desiredStreamSubscriptions.contains(subscription),
              !activeStreamSubscriptions.contains(subscription),
              streamSubscriptionTasks[subscription] == nil else { return }
        let generation = (streamSubscriptionGenerations[subscription] ?? 0) + 1
        streamSubscriptionGenerations[subscription] = generation
        streamSubscriptionTasks[subscription] = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastMessage = "The terminal stream did not start."
            var attempt = 0
            while true {
                guard !Task.isCancelled,
                      self.transport.state == .live,
                      self.desiredStreamSubscriptions.contains(subscription),
                      self.streamSubscriptionGenerations[subscription] == generation else { return }
                do {
                    let receipt = try await self.performCommand(
                        type: "stream.subscribe",
                        projectId: subscription.projectId,
                        targetId: subscription.sessionId,
                        capability: .observe,
                        timeout: .seconds(4)
                    )
                    if receipt.status == .accepted || receipt.status == .applied {
                        guard self.desiredStreamSubscriptions.contains(subscription),
                              self.streamSubscriptionGenerations[subscription] == generation else { return }
                        self.activeStreamSubscriptions.insert(subscription)
                        self.onStreamIssue?(subscription.sessionId, nil)
                        break
                    }
                    lastMessage = receipt.message ?? lastMessage
                } catch {
                    lastMessage = (error as? LocalizedError)?.errorDescription ?? lastMessage
                }
                attempt += 1
                // Keep healing while this terminal is on screen. A desktop
                // relaunch can briefly publish its project before the durable
                // broker inventory is reattached; three one-shot attempts made
                // that harmless ordering race look permanent until a manual tap.
                if attempt >= 3 { self.onStreamIssue?(subscription.sessionId, lastMessage) }
                let delay = min(5_000, 500 * (1 << min(attempt, 3)))
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
            }
            guard self.streamSubscriptionGenerations[subscription] == generation else { return }
            self.streamSubscriptionTasks[subscription] = nil
        }
    }

    private func invalidateStreamSubscription(_ subscription: StreamSubscription) {
        streamSubscriptionGenerations[subscription] = (streamSubscriptionGenerations[subscription] ?? 0) + 1
        streamSubscriptionTasks.removeValue(forKey: subscription)?.cancel()
        activeStreamSubscriptions.remove(subscription)
    }

    private func resetActiveStreamSubscriptions() {
        activeStreamSubscriptions.removeAll()
        for subscription in Array(streamSubscriptionTasks.keys) {
            invalidateStreamSubscription(subscription)
        }
    }

    private func sendStreamSubscription(_ subscription: StreamSubscription, subscribed: Bool) throws {
        guard let channel, let context = connectionContext else {
            throw CompanionWireError.connectionUnavailable
        }
        let commandId = "cmd-\(UUID().uuidString.lowercased())"
        outboundSeq += 1
        let body = CompanionCommandBody(
            type: subscribed ? "stream.subscribe" : "stream.unsubscribe",
            commandId: commandId,
            projectId: subscription.projectId,
            targetId: subscription.sessionId,
            capability: .observe,
            expectedRevision: nil,
            payload: nil
        )
        let envelope = try CompanionEnvelope(
            kind: .command,
            desktopId: context.desktopId,
            deviceId: context.deviceId,
            connectionId: context.connectionId,
            epoch: ackCursor?.epoch ?? "initial",
            seq: outboundSeq,
            id: commandId,
            sentAt: Self.nowMilliseconds,
            body: CompanionBody(body)
        )
        try sendSecureFrame(channel.encrypt(CompanionProtocolCodec.encode(envelope)))
    }

    func performCommand(
        type: String,
        projectId: String,
        targetId: String,
        capability: CompanionCapability,
        expectedRevision: Int64? = nil,
        payload: [String: JSONValue]? = nil,
        timeout: Duration = .seconds(15)
    ) async throws -> CompanionReceiptBody {
        guard transport.state == .live else { throw CompanionCommandError.unavailable }
        let commandId = "cmd-\(UUID().uuidString.lowercased())"
        let body = CompanionCommandBody(
            type: type,
            commandId: commandId,
            projectId: projectId,
            targetId: targetId,
            capability: capability,
            expectedRevision: expectedRevision,
            payload: payload
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingCommands[commandId] = continuation
                commandTimeouts[commandId] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishCommand(commandId, result: .failure(CompanionCommandError.timedOut))
                }
                do { try sendCommand(body) }
                catch { finishCommand(commandId, result: .failure(error)) }
            }
        } onCancel: {
            // Without this the continuation lingers until a receipt or the 15s
            // timeout arrives even after its caller is cancelled — long enough
            // for a cancelled lease-renewal to resume and resurrect the lease.
            Task { @MainActor [weak self] in
                self?.finishCommand(commandId, result: .failure(CancellationError()))
            }
        }
    }

    private func sendCommand(_ body: CompanionCommandBody) throws {
        guard let channel, let context = connectionContext else { throw CompanionWireError.connectionUnavailable }
        outboundSeq += 1
        let envelope = try CompanionEnvelope(
            kind: .command,
            desktopId: context.desktopId,
            deviceId: context.deviceId,
            connectionId: context.connectionId,
            // Prefer the epoch learned from this connection's inbound frames
            // over the persisted resume cursor, which is stale after a desktop
            // restart. Commands are only ever sent after the first inbound frame
            // (subscriptions are gated, other commands are user-driven), so
            // liveEpoch is populated in every realistic path.
            epoch: liveEpoch ?? ackCursor?.epoch ?? "initial",
            seq: outboundSeq,
            id: body.commandId,
            sentAt: Self.nowMilliseconds,
            body: CompanionBody(body)
        )
        try sendSecureFrame(channel.encrypt(CompanionProtocolCodec.encode(envelope)))
    }

    func acknowledge(_ cursor: CompanionAckCursor) throws {
        guard let channel, let context = connectionContext else { throw CompanionWireError.connectionUnavailable }
        let envelope = try CompanionEnvelope(
            kind: .ack,
            desktopId: context.desktopId,
            deviceId: context.deviceId,
            connectionId: context.connectionId,
            epoch: cursor.epoch,
            seq: cursor.seq,
            id: "ack-\(UUID().uuidString.lowercased())",
            sentAt: Self.nowMilliseconds,
            body: CompanionBody(CompanionAckBody(ackSeq: cursor.seq))
        )
        try sendSecureFrame(channel.encrypt(CompanionProtocolCodec.encode(envelope)))
        ackCursor = cursor
        onAckCursor?(cursor)
    }

    private func startHandshake() throws {
        guard transport.state == .handshaking, let identity, let mode else {
            throw CompanionWireError.connectionUnavailable
        }
        sas = nil
        channel = nil
        handshakeResult = nil
        sessionId = nil
        localSASConfirmed = false
        remoteSASConfirmed = false
        // Each connection learns its epoch afresh from the first inbound frame.
        liveEpoch = nil

        let connectionId = "connection-\(UUID().uuidString.lowercased())"
        let desktopId: String
        let pin: CompanionIdentityPin
        let contextValue: JSONValue
        switch mode {
        case let .pairing(payload):
            desktopId = payload.desktopId
            pin = payload.desktopPin
            contextValue = try payload.handshakeContext(connectionId: connectionId)
        case let .resume(desktop):
            desktopId = desktop.desktopId
            pin = desktop.pin
            contextValue = try desktop.resumeHandshakeContext(deviceId: identity.id, connectionId: connectionId)
        }
        let context = CompanionConnectionContext(
            desktopId: desktopId,
            deviceId: identity.id,
            connectionId: connectionId
        )
        connectionContext = context
        let initiator = try NoiseXXInitiator(
            identity: identity,
            prologue: createNoisePrologue(contextValue),
            peerPin: pin
        )
        self.initiator = initiator
        let message1 = try initiator.writeMessage1().base64URLEncodedString()

        let start: JSONValue
        switch mode {
        case let .pairing(payload):
            start = .object([
                "v": .integer(1),
                "type": .string("pair.start"),
                "qrPayload": try JSONValue.from(payload),
                "connectionId": .string(connectionId),
                "message1": .string(message1),
            ])
        case .resume:
            start = .object([
                "v": .integer(1),
                "type": .string("resume.start"),
                "deviceId": .string(identity.id),
                "connectionId": .string(connectionId),
                "message1": .string(message1),
            ])
        }
        try transport.send(CanonicalJSON.data(from: start))
    }

    private func receive(_ data: Data) throws {
        if transport.state == .live {
            try receiveApplicationFrame(data)
            return
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else { throw CompanionWireError.invalidFrame }

        if let type = object["type"]?.stringValue {
            if type.hasSuffix(".message2") { try receiveMessage2(object, type: type); return }
            if type.hasSuffix(".confirmation") { try receiveConfirmation(object, type: type); return }
        }
        try receiveSecureHandshakeFrame(value)
    }

    private func receiveMessage2(_ object: [String: JSONValue], type: String) throws {
        guard let initiator,
              let sessionId = object["sessionId"]?.stringValue,
              let message = object["message2"]?.stringValue,
              let messageData = Data(base64URLString: message),
              (type == "pair.message2") == isPairing else {
            throw CompanionWireError.invalidFrame
        }
        self.sessionId = sessionId
        try initiator.readMessage2(messageData)
        let message3 = try initiator.writeMessage3()
        let result = try initiator.result()
        handshakeResult = result
        guard let context = connectionContext else { throw CompanionCryptoError.handshakeOrder }
        channel = try SecureFrameChannel(result: result, context: context, role: .device)
        let response: JSONValue = .object([
            "v": .integer(1),
            "type": .string(isPairing ? "pair.message3" : "resume.message3"),
            "sessionId": .string(sessionId),
            "message3": .string(message3.base64URLEncodedString()),
        ])
        try transport.send(CanonicalJSON.data(from: response))
    }

    private func receiveConfirmation(_ object: [String: JSONValue], type: String) throws {
        guard let channel,
              let result = handshakeResult,
              let confirmation = object["confirmationFrame"],
              (type == "pair.confirmation") == isPairing else {
            throw CompanionWireError.invalidFrame
        }
        let frame = try decodeSecureFrame(confirmation)
        try CompanionKeyConfirmation.verify(
            channel: channel,
            frame: frame,
            expectedRole: .desktop,
            handshakeHash: result.handshakeHash
        )
        try sendSecureFrame(CompanionKeyConfirmation.make(
            channel: channel,
            role: .device,
            handshakeHash: result.handshakeHash
        ))
        if isPairing {
            let localSAS = CompanionSAS.derive(handshakeHash: result.handshakeHash)
            if let serverSAS = object["sas"],
               let advertised = try? JSONDecoder().decode(
                   CompanionSAS.self,
                   from: CanonicalJSON.data(from: serverSAS)
               ), advertised != localSAS {
                throw CompanionCryptoError.authenticationFailed
            }
            sas = localSAS
        } else {
            try activateLive()
        }
    }

    private func receiveSecureHandshakeFrame(_ value: JSONValue) throws {
        guard let channel, let result = handshakeResult else { throw CompanionCryptoError.handshakeOrder }
        let frame = try decodeSecureFrame(value)
        let payload = try channel.decryptJSON(frame)
        guard let object = payload.objectValue, let type = object["type"]?.stringValue else {
            throw CompanionCryptoError.invalidSecurePayload
        }
        if type == "sas-confirm" {
            guard object["role"]?.stringValue == CompanionPeerRole.desktop.rawValue,
                  object["transcriptHash"]?.stringValue == result.handshakeHash.base64URLEncodedString() else {
                throw CompanionCryptoError.authenticationFailed
            }
            remoteSASConfirmed = true
            return
        }
        if type == "paired" {
            guard case let .pairing(payload) = mode,
                  localSASConfirmed, remoteSASConfirmed,
                  object["deviceId"]?.stringValue == identity?.id,
                  object["transcriptHash"]?.stringValue == result.handshakeHash.base64URLEncodedString() else {
                throw CompanionCryptoError.authenticationFailed
            }
            let granted: [CompanionCapability]
            if let value = object["capabilities"],
               let decoded = try? JSONDecoder().decode(
                   [CompanionCapability].self,
                   from: CanonicalJSON.data(from: value)
               ) {
                granted = decoded
            } else {
                granted = payload.requestedCapabilities
            }
            guard !granted.isEmpty,
                  granted.contains(.observe),
                  Set(granted).count == granted.count else {
                throw CompanionCryptoError.authenticationFailed
            }
            let desktop = CompanionPairedDesktop(
                desktopId: payload.desktopId,
                identityPublic: payload.identityPublic,
                x25519StaticPublic: payload.keyRecord.x25519StaticPublic,
                capabilities: CompanionCapability.allCases.filter(granted.contains),
                transportHint: payload.transportHint
            )
            pairedDesktop = desktop
            mode = .resume(desktop)
            onPairedDesktop?(desktop)
            try activateLive()
            return
        }
        throw CompanionCryptoError.invalidSecurePayload
    }

    private func activateLive() throws {
        guard let channel, let context = connectionContext else { throw CompanionCryptoError.handshakeOrder }
        let hello = CompanionHelloBody(
            role: .device,
            // Ask for every capability on each authenticated resume. The Mac
            // grants only the intersection in its current per-device record,
            // so desktop-side widening/narrowing takes effect after reconnect.
            capabilities: CompanionCapability.allCases,
            lastAck: ackCursor?.seq
        )
        let envelope = try CompanionEnvelope(
            kind: .hello,
            desktopId: context.desktopId,
            deviceId: context.deviceId,
            connectionId: context.connectionId,
            epoch: ackCursor?.epoch ?? "initial",
            seq: 0,
            id: "hello-\(UUID().uuidString.lowercased())",
            sentAt: Self.nowMilliseconds,
            body: CompanionBody(hello)
        )
        try sendSecureFrame(channel.encrypt(CompanionProtocolCodec.encode(envelope)))
        transport.markLive()
        // Do NOT issue stream.subscribe yet: the live epoch is still unknown on
        // a fresh resume. The subscriptions are flushed once the first inbound
        // frame establishes this connection's epoch (see receiveApplicationFrame).
    }

    private func flushDesiredStreamSubscriptions() {
        for subscription in desiredStreamSubscriptions {
            startStreamSubscription(subscription)
        }
    }

    private func receiveApplicationFrame(_ data: Data) throws {
        guard let channel else { throw CompanionWireError.connectionUnavailable }
        let secure = try JSONDecoder().decode(CompanionSecureFrame.self, from: data)
        let envelope = try CompanionProtocolCodec.decode(channel.decrypt(secure))
        // First inbound frame on this connection tells us the desktop's current
        // epoch. Adopt it for outbound commands and only now fire the deferred
        // stream subscriptions, so they can never carry a stale (rejected) epoch.
        if liveEpoch == nil {
            liveEpoch = envelope.epoch
            flushDesiredStreamSubscriptions()
        }
        if envelope.kind == .hello {
            let hello = try envelope.body.decode(CompanionHelloBody.self)
            guard hello.role == .desktop,
                  hello.capabilities.contains(.observe),
                  Set(hello.capabilities).count == hello.capabilities.count else {
                throw CompanionCryptoError.authenticationFailed
            }
            let granted = Set(hello.capabilities)
            if let transportHint = hello.transportHint {
                try transportHint.validate()
            }
            onCapabilities?(granted)
            if let current = pairedDesktop {
                let updated = CompanionPairedDesktop(
                    desktopId: current.desktopId,
                    identityPublic: current.identityPublic,
                    x25519StaticPublic: current.x25519StaticPublic,
                    capabilities: CompanionCapability.allCases.filter(granted.contains),
                    transportHint: hello.transportHint ?? current.transportHint
                )
                pairedDesktop = updated
                mode = .resume(updated)
                onPairedDesktop?(updated)
            }
        } else if envelope.kind == .receipt {
            let receipt = try envelope.body.decode(CompanionReceiptBody.self)
            finishCommand(receipt.commandId, result: .success(receipt))
        }
        onEnvelope?(envelope)
    }

    private func finishCommand(_ commandId: String, result: Result<CompanionReceiptBody, Error>) {
        guard let continuation = pendingCommands.removeValue(forKey: commandId) else { return }
        commandTimeouts.removeValue(forKey: commandId)?.cancel()
        switch result {
        case let .success(receipt): continuation.resume(returning: receipt)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    private func failPendingCommands(with error: Error) {
        for commandId in Array(pendingCommands.keys) {
            finishCommand(commandId, result: .failure(error))
        }
    }

    private func sendSecureFrame(_ frame: CompanionSecureFrame) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try transport.send(encoder.encode(frame))
    }

    private func decodeSecureFrame(_ value: JSONValue) throws -> CompanionSecureFrame {
        try JSONDecoder().decode(CompanionSecureFrame.self, from: CanonicalJSON.data(from: value))
    }

    private var isPairing: Bool {
        if case .pairing = mode { return true }
        return false
    }

    private func fail(_ error: Error) {
        lastError = String(describing: error)
    }

    private static var nowMilliseconds: Int64 {
        Int64(Date.now.timeIntervalSince1970 * 1_000)
    }
}
