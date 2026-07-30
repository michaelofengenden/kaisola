import Foundation
import KaisolaCore
@preconcurrency import Network

enum CompanionConnectionEvent: Sendable {
    case pairingPhrase(
        pairingID: String,
        deviceID: String,
        displayName: String,
        sas: CompanionSAS
    )
    case authenticated(device: CompanionPairedDeviceRecord, resumed: Bool)
    case live(
        device: CompanionPairedDeviceRecord,
        capabilities: [CompanionCapability],
        resumeCursor: CompanionAckCursor?
    )
    case envelope(CompanionEnvelope, device: CompanionPairedDeviceRecord)
    case closed(reason: String)
}

/// Protocol state above a byte-stream connection. This actor owns framing,
/// handshake ordering, the secure channel, and the mandatory hello exchange;
/// the Network.framework adapter below owns only socket lifecycle and I/O.
actor CompanionConnectionSession {
    static let maximumHandshakeFrameBytes = 64 * 1_024

    private enum Phase {
        case handshaking
        case authenticated
        case live
        case closed
    }

    typealias Writer = @Sendable (Data) async throws -> Void
    typealias Closer = @Sendable () async -> Void
    typealias EventSink = @Sendable (CompanionConnectionEvent) -> Void
    typealias DiagnosticSink = @Sendable (String) -> Void

    let socketID: String
    private let coordinator: CompanionPairingCoordinator
    private let epoch: String
    private let transportHint: CompanionPairingTransportHint?
    private let writer: Writer
    private let closer: Closer
    private let eventSink: EventSink
    private let diagnosticSink: DiagnosticSink
    private let now: @Sendable () -> Int64
    private var decoder = CompanionLengthFrameDecoder(
        maximumFrameBytes: CompanionConnectionSession.maximumHandshakeFrameBytes
    )
    private var phase: Phase = .handshaking
    private var authenticated: CompanionAuthenticatedConnection?
    private var effectiveCapabilities: [CompanionCapability] = []
    private var nextOutgoingSequence: Int64 = 1
    private var lastStateSequence: Int64 = 0
    private var lastProjectionRevision = 0

    init(
        socketID: String,
        coordinator: CompanionPairingCoordinator,
        epoch: String,
        transportHint: CompanionPairingTransportHint?,
        writer: @escaping Writer,
        closer: @escaping Closer,
        eventSink: @escaping EventSink,
        diagnosticSink: @escaping DiagnosticSink = { _ in },
        now: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) throws {
        _ = try CompanionCrypto.validateIdentifier(socketID, label: "socketId")
        _ = try CompanionCrypto.validateIdentifier(epoch, label: "epoch")
        try transportHint?.validate()
        self.socketID = socketID
        self.coordinator = coordinator
        self.epoch = epoch
        self.transportHint = transportHint
        self.writer = writer
        self.closer = closer
        self.eventSink = eventSink
        self.diagnosticSink = diagnosticSink
        self.now = now
    }

    func receive(_ bytes: Data) async {
        guard phase != .closed, !bytes.isEmpty else { return }
        do {
            let frames = try decoder.push(bytes)
            for frame in frames {
                switch phase {
                case .handshaking:
                    try await receiveHandshakeFrame(frame)
                case .authenticated, .live:
                    try receiveApplicationFrame(frame)
                case .closed:
                    return
                }
            }
            // The authentication frame and the device hello can be coalesced,
            // but both are necessarily below the 64 KiB handshake cap. Once
            // that batch is consumed, admit the full secure protocol limit.
            if phase != .handshaking,
               decoder.maximumFrameBytes == Self.maximumHandshakeFrameBytes,
               decoder.buffer.isEmpty {
                decoder = CompanionLengthFrameDecoder()
            }
        } catch {
            diagnosticSink(Self.safeDiagnostic(error))
            await close(reason: phase == .handshaking ? "authentication_failed" : "invalid_secure_frame")
        }
    }

    func confirmPairing(pairingID: String) async -> Bool {
        guard phase == .handshaking else { return false }
        do {
            let output = try await coordinator.confirmPairing(
                pairingID: pairingID,
                nowMilliseconds: now()
            )
            try await apply(output)
            return true
        } catch {
            await close(reason: "pairing_confirmation_failed")
            return false
        }
    }

    func send(_ envelope: CompanionEnvelope) async throws {
        guard phase == .live,
              let authenticated,
              envelope.desktopId == authenticated.context.desktopId,
              envelope.deviceId == authenticated.context.deviceId,
              envelope.connectionId == authenticated.context.connectionId,
              envelope.epoch == epoch else {
            throw CompanionWireError.connectionUnavailable
        }
        try await sendSecure(envelope, channel: authenticated.channel)
    }

    @discardableResult
    func send(
        kind: CompanionEnvelopeKind,
        id: String,
        body: CompanionBody
    ) async throws -> CompanionEnvelope {
        guard phase == .live, let authenticated else {
            throw CompanionWireError.connectionUnavailable
        }
        let sequence = nextOutgoingSequence
        guard sequence >= 1, sequence < 9_007_199_254_740_991 else {
            throw CompanionWireError.connectionUnavailable
        }
        // Reserve before the awaited socket write. Actors are reentrant, so
        // incrementing afterward can assign one sequence to concurrent sends.
        nextOutgoingSequence = sequence + 1
        let envelope = try CompanionEnvelope(
            kind: kind,
            desktopId: authenticated.context.desktopId,
            deviceId: authenticated.context.deviceId,
            connectionId: authenticated.context.connectionId,
            epoch: epoch,
            seq: sequence,
            id: id,
            sentAt: now(),
            body: body
        )
        try await sendSecure(envelope, channel: authenticated.channel)
        return envelope
    }

    /// Send a host-sequenced replay record. Companion sequence numbers belong
    /// to the desktop epoch, not to an individual socket, so reconnecting
    /// devices must see the same cursor for the same logical event.
    @discardableResult
    func send(
        kind: CompanionEnvelopeKind,
        id: String,
        sequence: Int64,
        sentAt: Int64,
        body: CompanionBody
    ) async throws -> CompanionEnvelope? {
        guard phase == .live, let authenticated else {
            throw CompanionWireError.connectionUnavailable
        }
        if kind == .snapshot || kind == .event {
            // Full projection snapshots make a late older state frame
            // unnecessary. Reserve before the awaited write because this actor
            // is reentrant while Network.framework drains a slow peer.
            guard sequence > lastStateSequence else { return nil }
            lastStateSequence = sequence
        }
        let envelope = try CompanionEnvelope(
            kind: kind,
            desktopId: authenticated.context.desktopId,
            deviceId: authenticated.context.deviceId,
            connectionId: authenticated.context.connectionId,
            epoch: epoch,
            seq: sequence,
            id: id,
            sentAt: sentAt,
            body: body
        )
        nextOutgoingSequence = max(nextOutgoingSequence, sequence + 1)
        try await sendSecure(envelope, channel: authenticated.channel)
        return envelope
    }

    /// Publish the current bounded desktop projection. Sequence numbers and
    /// connection context stay owned by this authenticated session so callers
    /// cannot accidentally address a different peer. A late task carrying an
    /// older revision is ignored rather than regressing the phone's view.
    func sendProjection(_ projection: CompanionProjection) async throws {
        guard projection.revision > lastProjectionRevision else { return }
        // Reserve the revision before the awaited write for the same reentrant
        // actor reason as sequence allocation. A failed write closes the peer.
        lastProjectionRevision = projection.revision
        let body = CompanionSnapshotBody(
            type: "snapshot.projects",
            revision: projection.revision,
            projection: projection
        )
        _ = try await send(
            kind: .snapshot,
            id: "snapshot-\(projection.revision)-\(UUID().uuidString.lowercased())",
            body: CompanionBody(body)
        )
    }

    /// Phase 2 is intentionally observe-only. Commands that passed capability
    /// negotiation still receive an explicit typed receipt instead of being
    /// dropped or appearing successful while the command router is absent.
    func sendUnavailableReceipt(
        for commandEnvelope: CompanionEnvelope,
        message: String = "This Companion command is not available yet."
    ) async throws {
        guard commandEnvelope.kind == .command else {
            throw CompanionProtocolError.invalidBody("command receipt")
        }
        let command = try commandEnvelope.body.decode(CompanionCommandBody.self)
        let receipt = CompanionReceiptBody(
            type: "command.receipt",
            commandId: command.commandId,
            status: .unavailable,
            message: String(message.prefix(800)),
            payload: nil
        )
        try await sendReceipt(receipt)
    }

    func sendReceipt(
        _ receipt: CompanionReceiptBody,
        sequence: Int64? = nil,
        sentAt: Int64? = nil
    ) async throws {
        if let sequence {
            _ = try await send(
                kind: .receipt,
                id: receipt.commandId,
                sequence: sequence,
                sentAt: sentAt ?? now(),
                body: CompanionBody(receipt)
            )
        } else {
            _ = try await send(
                kind: .receipt,
                id: receipt.commandId,
                body: CompanionBody(receipt)
            )
        }
    }

    func authenticationTimedOut() async {
        guard phase == .handshaking else { return }
        await close(reason: "authentication_timeout")
    }

    func close(reason: String) async {
        guard phase != .closed else { return }
        phase = .closed
        authenticated = nil
        effectiveCapabilities = []
        await coordinator.release(socketID: socketID)
        await closer()
        eventSink(.closed(reason: Self.safeReason(reason)))
    }

    private func receiveHandshakeFrame(_ payload: Data) async throws {
        let output = try await coordinator.receive(
            socketID: socketID,
            payload: payload,
            nowMilliseconds: now()
        )
        try await apply(output)
    }

    private func apply(_ output: CompanionPairingCoordinatorOutput) async throws {
        for payload in output.frames { try await sendPayload(payload) }
        guard let event = output.event else { return }
        switch event {
        case let .pairingPhrase(pairingID, _, deviceID, displayName, sas):
            eventSink(.pairingPhrase(
                pairingID: pairingID,
                deviceID: deviceID,
                displayName: displayName,
                sas: sas
            ))
        case let .authenticated(device, resumed):
            guard let connection = await coordinator.authenticatedConnection(socketID: socketID) else {
                throw CompanionWireError.connectionUnavailable
            }
            authenticated = connection
            phase = .authenticated
            try await sendDesktopHello(connection: connection)
            eventSink(.authenticated(device: device, resumed: resumed))
        }
    }

    private func sendDesktopHello(connection: CompanionAuthenticatedConnection) async throws {
        let hello = CompanionHelloBody(
            role: .desktop,
            capabilities: connection.device.capabilities,
            transportHint: transportHint
        )
        let envelope = try CompanionEnvelope(
            kind: .hello,
            desktopId: connection.context.desktopId,
            deviceId: connection.context.deviceId,
            connectionId: connection.context.connectionId,
            epoch: epoch,
            seq: 0,
            id: "hello-\(UUID().uuidString.lowercased())",
            sentAt: now(),
            body: CompanionBody(hello)
        )
        try await sendSecure(envelope, channel: connection.channel)
    }

    private func receiveApplicationFrame(_ payload: Data) throws {
        guard let authenticated else { throw CompanionWireError.connectionUnavailable }
        let secure = try JSONDecoder().decode(CompanionSecureFrame.self, from: payload)
        let envelope = try CompanionProtocolCodec.decode(authenticated.channel.decrypt(secure))
        guard envelope.desktopId == authenticated.context.desktopId,
              envelope.deviceId == authenticated.context.deviceId,
              envelope.connectionId == authenticated.context.connectionId else {
            throw CompanionCryptoError.authenticationFailed
        }

        if phase == .authenticated {
            guard envelope.kind == .hello else {
                throw CompanionCryptoError.authenticationFailed
            }
            let hello = try envelope.body.decode(CompanionHelloBody.self)
            let requested = Set(hello.capabilities)
            let granted = authenticated.device.capabilities.filter(requested.contains)
            guard hello.role == .device,
                  requested.contains(.observe),
                  Set(hello.capabilities).count == hello.capabilities.count,
                  granted.contains(.observe) else {
                throw CompanionCryptoError.authenticationFailed
            }
            effectiveCapabilities = granted
            phase = .live
            let cursor = hello.lastAck.map {
                CompanionAckCursor(epoch: envelope.epoch, seq: $0)
            }
            eventSink(.live(
                device: authenticated.device,
                capabilities: granted,
                resumeCursor: cursor
            ))
            return
        }

        guard phase == .live,
              envelope.kind != .hello,
              envelope.epoch == epoch else {
            throw CompanionCryptoError.authenticationFailed
        }
        switch envelope.kind {
        case .command:
            let command = try envelope.body.decode(CompanionCommandBody.self)
            guard effectiveCapabilities.contains(command.capability) else {
                throw CompanionCryptoError.authenticationFailed
            }
        case .ack:
            break
        default:
            // The device side is a command/ACK client. Accepting projection,
            // receipt, or error kinds in this direction would blur authority
            // before the typed router even sees the envelope.
            throw CompanionCryptoError.authenticationFailed
        }
        eventSink(.envelope(envelope, device: authenticated.device))
    }

    private func sendSecure(
        _ envelope: CompanionEnvelope,
        channel: SecureFrameChannel
    ) async throws {
        let plaintext = try CompanionProtocolCodec.encode(envelope)
        try await sendPayload(CanonicalJSON.data(from: channel.encrypt(plaintext)))
    }

    private func sendPayload(_ payload: Data) async throws {
        try await writer(CompanionLengthFrameDecoder.encode(payload))
    }

    private static func safeReason(_ value: String) -> String {
        let cleaned = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        return cleaned.isEmpty ? "closed" : String(cleaned.prefix(80))
    }

    private static func safeDiagnostic(_ error: Error) -> String {
        if let crypto = error as? CompanionCryptoError {
            switch crypto {
            case .identityProofFailed: return "crypto_identity_proof_failed"
            case .identityMismatch: return "crypto_identity_mismatch"
            case .invalidHandshakeMessage: return "crypto_invalid_handshake_message"
            case .handshakeOrder: return "crypto_handshake_order"
            case .authenticationFailed: return "crypto_authentication_failed"
            case .keyConfirmationFailed: return "crypto_key_confirmation_failed"
            case .invalidSecureFrame: return "crypto_invalid_secure_frame"
            case .replayOrOutOfOrder: return "crypto_replay_or_out_of_order"
            default: return "crypto_error"
            }
        }
        switch error {
        case CompanionPairingCoordinatorError.invalidFrame: return "pairing_invalid_frame"
        case CompanionPairingCoordinatorError.invalidOffer: return "pairing_invalid_offer"
        case CompanionPairingCoordinatorError.offerUnavailable: return "pairing_offer_unavailable"
        case CompanionPairingCoordinatorError.expired: return "pairing_expired"
        case CompanionPairingCoordinatorError.serverBusy: return "pairing_server_busy"
        case CompanionPairingCoordinatorError.handshakeOrder: return "pairing_handshake_order"
        case CompanionPairingCoordinatorError.authenticationFailed: return "pairing_authentication_failed"
        case CompanionPairingCoordinatorError.duplicateDevice: return "pairing_duplicate_device"
        case CompanionWireError.invalidFrame: return "wire_invalid_frame"
        case CompanionWireError.frameTooLarge: return "wire_frame_too_large"
        case CompanionWireError.connectionUnavailable: return "wire_connection_unavailable"
        default:
            let typeName = String(reflecting: type(of: error)).lowercased().filter {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".")
            }
            return typeName.isEmpty ? "protocol_error" : "error_\(String(typeName.prefix(80)))"
        }
    }
}

/// The host owns protocol authority above transport. LAN TCP and the opaque
/// relay implement this same actor boundary so neither transport can grow a
/// second handshake, command router, replay log, or lease implementation.
protocol CompanionHostConnection: Actor {
    nonisolated var id: String { get }
    func start() async throws
    func confirmPairing(pairingID: String) async -> Bool
    func send(
        kind: CompanionEnvelopeKind,
        id: String,
        sequence: Int64,
        sentAt: Int64,
        body: CompanionBody
    ) async throws -> CompanionEnvelope?
    func sendReceipt(
        _ receipt: CompanionReceiptBody,
        sequence: Int64?,
        sentAt: Int64?
    ) async throws
    func close(reason: String) async
}

/// Network.framework adapter for one accepted Companion TCP connection. Sends
/// are awaited and therefore serialized, so a slow peer can never create an
/// unbounded user-space write queue.
actor CompanionNetworkConnection: CompanionHostConnection {
    static let authenticationTimeout = Duration.seconds(30)

    nonisolated let id: String
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let coordinator: CompanionPairingCoordinator
    private let epoch: String
    private let transportHint: CompanionPairingTransportHint?
    private let eventSink: CompanionConnectionSession.EventSink
    private var session: CompanionConnectionSession?
    private var started = false
    private var timeoutTask: Task<Void, Never>?

    init(
        id: String = "socket-\(UUID().uuidString.lowercased())",
        connection: NWConnection,
        coordinator: CompanionPairingCoordinator,
        epoch: String,
        transportHint: CompanionPairingTransportHint?,
        eventSink: @escaping CompanionConnectionSession.EventSink
    ) {
        self.id = id
        self.connection = connection
        self.coordinator = coordinator
        self.epoch = epoch
        self.transportHint = transportHint
        self.eventSink = eventSink
        queue = DispatchQueue(label: "com.kaisola.mac.companion-connection.\(id)", qos: .userInitiated)
    }

    deinit { timeoutTask?.cancel() }

    func start() async throws {
        guard !started else { return }
        started = true
        let session = try CompanionConnectionSession(
            socketID: id,
            coordinator: coordinator,
            epoch: epoch,
            transportHint: transportHint,
            writer: { [weak self] data in
                guard let self else { throw CompanionWireError.connectionUnavailable }
                try await self.write(data)
            },
            closer: { [weak self] in await self?.cancelNetwork() },
            eventSink: eventSink
        )
        self.session = session
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleState(state) }
        }
        connection.start(queue: queue)
        timeoutTask = Task { [weak session] in
            try? await Task.sleep(for: Self.authenticationTimeout)
            guard !Task.isCancelled else { return }
            await session?.authenticationTimedOut()
        }
    }

    func confirmPairing(pairingID: String) async -> Bool {
        await session?.confirmPairing(pairingID: pairingID) ?? false
    }

    func send(_ envelope: CompanionEnvelope) async throws {
        guard let session else { throw CompanionWireError.connectionUnavailable }
        try await session.send(envelope)
    }

    @discardableResult
    func send(
        kind: CompanionEnvelopeKind,
        id: String,
        body: CompanionBody
    ) async throws -> CompanionEnvelope {
        guard let session else { throw CompanionWireError.connectionUnavailable }
        return try await session.send(kind: kind, id: id, body: body)
    }

    @discardableResult
    func send(
        kind: CompanionEnvelopeKind,
        id: String,
        sequence: Int64,
        sentAt: Int64,
        body: CompanionBody
    ) async throws -> CompanionEnvelope? {
        guard let session else { throw CompanionWireError.connectionUnavailable }
        return try await session.send(
            kind: kind,
            id: id,
            sequence: sequence,
            sentAt: sentAt,
            body: body
        )
    }

    func sendProjection(_ projection: CompanionProjection) async throws {
        guard let session else { throw CompanionWireError.connectionUnavailable }
        try await session.sendProjection(projection)
    }

    func sendUnavailableReceipt(for envelope: CompanionEnvelope) async throws {
        guard let session else { throw CompanionWireError.connectionUnavailable }
        try await session.sendUnavailableReceipt(for: envelope)
    }

    func sendReceipt(
        _ receipt: CompanionReceiptBody,
        sequence: Int64? = nil,
        sentAt: Int64? = nil
    ) async throws {
        guard let session else { throw CompanionWireError.connectionUnavailable }
        try await session.sendReceipt(receipt, sequence: sequence, sentAt: sentAt)
    }

    func close(reason: String = "closed") async {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let session { await session.close(reason: reason) }
        else { connection.cancel() }
    }

    private func handleState(_ state: NWConnection.State) async {
        switch state {
        case .ready:
            receiveNext()
        case .failed:
            await close(reason: "socket_error")
        case .cancelled:
            if let session { await session.close(reason: "socket_closed") }
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] content, _, complete, error in
            Task { [weak self] in
                guard let self else { return }
                if let content, !content.isEmpty { await self.session?.receive(content) }
                if error != nil { await self.close(reason: "socket_error") }
                else if complete { await self.close(reason: "socket_closed") }
                else { await self.receiveNext() }
            }
        }
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func cancelNetwork() {
        timeoutTask?.cancel()
        timeoutTask = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
