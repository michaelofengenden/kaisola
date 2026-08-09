import Combine
import Foundation
import KaisolaCore
import Network

@MainActor
final class CompanionHost: ObservableObject {
    enum State: Equatable {
        case disabled
        case starting
        case ready(port: UInt16)
        case failed(String)

        var title: String {
            switch self {
            case .disabled: "Off"
            case .starting: "Starting…"
            case let .ready(port): "Nearby on port \(port)"
            case .failed: "Needs attention"
            }
        }
    }

    struct PairingPhrase: Identifiable, Equatable {
        let pairingID: String
        let connectionID: String
        let deviceID: String
        let displayName: String
        let sas: CompanionSAS
        var id: String { pairingID }
    }

    private struct LinkConfiguration {
        let baseURL: URL
        let tokenProvider: CompanionLinkClient.TokenProvider
    }

    static let shared = CompanionHost()
    private static let enabledDefaultsKey = "companion.nativeHostEnabled"

    @Published private(set) var state: State = .disabled
    @Published private(set) var pairingPayload: CompanionPairingPayload?
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingPhrase: PairingPhrase?
    @Published private(set) var pairedDevices: [CompanionPairedDeviceRecord] = []
    @Published private(set) var connectedDeviceIDs: Set<String> = []
    @Published private(set) var terminalControlStatuses: [CompanionTerminalControlStatus] = []
    @Published private(set) var linkPhase: CompanionLinkClient.Phase = .off
    @Published private(set) var linkChannelCount = 0
    @Published private(set) var lastError: String?

    var isEnabled: Bool { state != .disabled }

    private let defaults: UserDefaults
    private let listener = CompanionListener()
    private var listenerObservation: AnyCancellable?
    private var identity: CompanionIdentity?
    private var roster: CompanionDeviceRosterStore?
    private var coordinator: CompanionPairingCoordinator?
    private var linkConfiguration: LinkConfiguration?
    private var linkClient: CompanionLinkClient?
    private var linkObservations: Set<AnyCancellable> = []
    private var linkSignedIn = false
    private var connections: [String: any CompanionHostConnection] = [:]
    private var deviceConnections: [String: String] = [:]
    private var liveConnectionIDs: Set<String> = []
    private var synchronizationTasks: [String: Task<Bool, Never>] = [:]
    private var synchronizationTokens: [String: UUID] = [:]
    private var connectionEpoch: String
    private var eventLog: CompanionEventLog
    private let projectionRevisions = CompanionProjectionRevisions()
    private let commandRouter = CompanionCommandRouter()
    private var terminalControlAdapter: CompanionTerminalControlAdapter?
    private var terminalControl: CompanionTerminalControl?
    private var terminalControlDisposal: (id: UUID, task: Task<Void, Never>)?
    private var terminalControlGeneration = UUID()
    private var terminalRecordsByKey: [String: BrokerTerminalRecord] = [:]
    private lazy var terminalStreamHub = CompanionTerminalStreamHub { [weak self] delivery in
        Task { @MainActor in self?.deliver(delivery) }
    }

    init(defaults: UserDefaults = .standard) {
        let epoch = "epoch-\(UUID().uuidString.lowercased())"
        self.defaults = defaults
        connectionEpoch = epoch
        eventLog = CompanionEventLog(epoch: epoch)
        listenerObservation = listener.$state.sink { [weak self] state in
            self?.adopt(listenerState: state)
        }
    }

    /// Deterministic, broker-free state for the hosted Companion Settings
    /// screenshot. Production startup never calls this; keeping the fixture at
    /// the authority boundary makes the real view prove both Nearby and Link
    /// status without opening a listener, touching Keychain, or reaching the
    /// relay.
    func loadVisualLinkFixture() {
        state = .ready(port: 48_911)
        linkPhase = .ready
        linkChannelCount = 1
        pairedDevices = [
            CompanionPairedDeviceRecord(
                deviceId: "visual-iphone",
                displayName: "Michael's iPhone",
                identityPublic: Data(repeating: 0x11, count: 32).base64EncodedString(),
                x25519StaticPublic: Data(repeating: 0x22, count: 32).base64EncodedString(),
                capabilities: [.observe, .terminalControl],
                pairedAt: 1_785_216_000_000,
                lastSeenAt: 1_785_216_060_000
            )
        ]
        connectedDeviceIDs = ["visual-iphone"]
        lastError = nil
    }

    func configureTerminalControl(adapter: CompanionTerminalControlAdapter) {
        terminalControlAdapter = adapter
        prepareTerminalControl()
    }

    /// Configure the account-authenticated remote transport. This does not
    /// connect until both the Companion host is enabled and native account
    /// restore has proven a signed-in user. LAN pairing remains available
    /// without an account; Link never receives a stale or anonymous token.
    func configureKaisolaLink(
        baseURL: URL,
        tokenProvider: @escaping CompanionLinkClient.TokenProvider
    ) {
        linkClient?.disable()
        linkClient = nil
        linkObservations.removeAll()
        linkPhase = .off
        linkChannelCount = 0
        linkConfiguration = LinkConfiguration(
            baseURL: baseURL,
            tokenProvider: tokenProvider
        )
        prepareKaisolaLink()
    }

    func setKaisolaLinkSignedIn(_ signedIn: Bool) {
        linkSignedIn = signedIn
        guard signedIn else {
            linkClient?.disable()
            linkPhase = .off
            linkChannelCount = 0
            return
        }
        if let linkClient {
            linkClient.enable()
            linkClient.refresh()
        } else {
            prepareKaisolaLink()
        }
    }

    private func prepareKaisolaLink() {
        guard isEnabled, linkSignedIn, linkClient == nil,
              let linkConfiguration, let identity else { return }
        guard let client = CompanionLinkClient(
            desktopID: identity.id,
            baseURL: linkConfiguration.baseURL,
            tokenProvider: linkConfiguration.tokenProvider,
            acceptSocket: { [weak self] socket in self?.accept(socket) }
        ) else {
            linkPhase = .unavailable
            return
        }
        linkClient = client
        client.$phase
            .sink { [weak self] in self?.linkPhase = $0 }
            .store(in: &linkObservations)
        client.$channelCount
            .sink { [weak self] in self?.linkChannelCount = $0 }
            .store(in: &linkObservations)
        client.enable()
    }

    private func installTerminalControl(_ adapter: CompanionTerminalControlAdapter) {
        let generation = UUID()
        terminalControlGeneration = generation
        terminalControlStatuses = []
        terminalControl = CompanionTerminalControl(
            adapter: adapter,
            onLeaseChange: { [weak self] statuses in
                guard self?.terminalControlGeneration == generation else { return }
                self?.terminalControlStatuses = statuses
            }
        )
    }

    private func prepareTerminalControl() {
        guard terminalControl == nil, let terminalControlAdapter else { return }
        guard let pending = terminalControlDisposal else {
            installTerminalControl(terminalControlAdapter)
            return
        }
        Task { @MainActor [weak self] in
            await pending.task.value
            guard let self else { return }
            if self.terminalControlDisposal?.id == pending.id {
                self.terminalControlDisposal = nil
            }
            guard self.isEnabled, self.terminalControl == nil,
                  let adapter = self.terminalControlAdapter else { return }
            self.installTerminalControl(adapter)
        }
    }

    func controllingDeviceName(projectID: String, terminalID: String) -> String? {
        guard let status = terminalControlStatuses.first(where: {
            $0.projectID == projectID && $0.terminalID == terminalID
        }) else { return nil }
        return pairedDevices.first(where: { $0.deviceId == status.deviceID })?.displayName
            ?? "paired device"
    }

    func startIfEnabled() {
        guard defaults.bool(forKey: Self.enabledDefaultsKey) else { return }
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled { start() }
        else { stop() }
    }

    /// A recovery action that never revokes a pairing or widens capabilities.
    /// Nearby already listens continuously; refreshing Link (or restarting a
    /// failed listener) gives an offline phone a fresh route to resume on.
    func refreshReconnectAvailability() {
        lastError = nil
        if case .failed = state {
            stop(persistPreference: false)
            start()
            return
        }
        if !isEnabled {
            setEnabled(true)
            return
        }
        linkClient?.refresh()
    }

    func createPairingOffer(allowsTerminalControl: Bool) async throws {
        guard case let .ready(port) = state, let coordinator else {
            throw CompanionWireError.connectionUnavailable
        }
        if let current = pairingPayload {
            _ = await coordinator.cancelOffer(pairingID: current.pairingNonce)
        }
        pairingPhrase = nil
        let capabilities: [CompanionCapability] = allowsTerminalControl
            ? [.observe, .terminalControl]
            : [.observe]
        let payload = try await coordinator.createOffer(
            listenerPort: port,
            requestedCapabilities: capabilities,
            nowMilliseconds: Self.nowMilliseconds()
        )
        let encoded = try CanonicalJSON.data(from: payload)
        guard let code = String(data: encoded, encoding: .utf8) else {
            throw CompanionPairingCoordinatorError.invalidOffer
        }
        pairingPayload = payload
        pairingCode = code
        lastError = nil
    }

    func cancelPairing() {
        let current = pairingPayload
        pairingPayload = nil
        pairingCode = nil
        pairingPhrase = nil
        guard let current, let coordinator else { return }
        Task { _ = await coordinator.cancelOffer(pairingID: current.pairingNonce) }
    }

    func confirmPairing() async throws {
        guard let phrase = pairingPhrase,
              let connection = connections[phrase.connectionID] else {
            throw CompanionPairingCoordinatorError.handshakeOrder
        }
        guard await connection.confirmPairing(pairingID: phrase.pairingID) else {
            throw CompanionPairingCoordinatorError.handshakeOrder
        }
    }

    func revoke(deviceID: String) async throws {
        guard let roster else { throw CompanionWireError.connectionUnavailable }
        if let connectionID = deviceConnections.removeValue(forKey: deviceID),
           let connection = connections.removeValue(forKey: connectionID) {
            await terminalStreamHub.releaseConnection(connectionID)
            await terminalControl?.releaseConnection(connectionID)
            await connection.close(reason: "device_revoked")
        }
        eventLog.dropClient(deviceID)
        connectedDeviceIDs.remove(deviceID)
        _ = try await roster.revoke(deviceID)
        await refreshDevices()
    }

    /// Accept a whole-app snapshot from the AppDelegate's window registry.
    /// Meaningless refreshes are dropped before any secure socket write.
    func publishProjection(
        drafts: [RememberedSessionDraft],
        terminalStreams: [String: CompanionTerminalStreamHead],
        terminalRecords: [BrokerTerminalRecord]
    ) {
        var records: [String: BrokerTerminalRecord] = [:]
        for terminal in terminalRecords {
            let key = terminalKey(
                projectID: portableID(terminal.projectID, domain: "project", maximum: 160),
                terminalID: portableID(terminal.id, domain: "session", maximum: 240)
            )
            if let current = records[key],
               !current.exited,
               current.endOffset >= terminal.endOffset { continue }
            records[key] = terminal
        }
        terminalRecordsByKey = records
        let terminalControl = self.terminalControl
        Task { await terminalControl?.reconcileAvailableTerminals(terminalRecords) }
        let now = Self.nowMilliseconds()
        guard let projection = projectionRevisions.next(
            drafts: drafts,
            terminalStreams: terminalStreams,
            nowMilliseconds: now
        ) else { return }
        do {
            let record = try appendProjection(projection)
            let targets = liveConnectionIDs.compactMap { id in
                connections[id].map { (id, $0) }
            }
            Task {
                for (id, connection) in targets {
                    await send(record, connectionID: id, connection: connection)
                }
            }
        } catch {
            lastError = "Kaisola could not publish the current Companion state."
        }
    }

    func shutdown() {
        stop(persistPreference: false)
    }

    private func start() {
        guard state == .disabled || {
            if case .failed = state { return true }
            return false
        }() else { return }
        state = .starting
        lastError = nil
        prepareTerminalControl()
        do {
            try NativePreviewPaths.prepareCompanionDirectory()
            let identity = try CompanionIdentityStore().loadOrCreate(
                displayName: Host.current().localizedName ?? "Kaisola Desktop"
            )
            let roster = try CompanionDeviceRosterStore()
            let coordinator = try CompanionPairingCoordinator(identity: identity, roster: roster)
            self.identity = identity
            self.roster = roster
            self.coordinator = coordinator
            connectionEpoch = "epoch-\(UUID().uuidString.lowercased())"
            eventLog = CompanionEventLog(epoch: connectionEpoch)
            if let projection = projectionRevisions.current {
                _ = try appendProjection(projection)
            }
            listener.onConnection = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            try listener.start(identity: identity)
            prepareKaisolaLink()
            Task { await refreshDevices() }
        } catch {
            fail(error)
        }
    }

    private func stop(persistPreference: Bool = true) {
        if persistPreference { defaults.set(false, forKey: Self.enabledDefaultsKey) }
        listener.stop()
        linkClient?.disable()
        linkClient = nil
        linkObservations.removeAll()
        linkPhase = .off
        linkChannelCount = 0
        let active = Array(connections.values)
        let expiringTerminalControl = terminalControl
        terminalControl = nil
        terminalControlGeneration = UUID()
        let disposalID = UUID()
        let disposalTask = Task {
            if let expiringTerminalControl { await expiringTerminalControl.dispose() }
        }
        terminalControlDisposal = (disposalID, disposalTask)
        for task in synchronizationTasks.values { task.cancel() }
        synchronizationTasks.removeAll()
        synchronizationTokens.removeAll()
        connections.removeAll()
        deviceConnections.removeAll()
        liveConnectionIDs.removeAll()
        terminalRecordsByKey.removeAll()
        identity = nil
        roster = nil
        coordinator = nil
        pairingPayload = nil
        pairingCode = nil
        pairingPhrase = nil
        pairedDevices = []
        connectedDeviceIDs = []
        terminalControlStatuses = []
        lastError = nil
        state = .disabled
        Task {
            for connection in active { await connection.close(reason: "host_disabled") }
            await terminalStreamHub.shutdown()
            await disposalTask.value
            if terminalControlDisposal?.id == disposalID {
                terminalControlDisposal = nil
            }
        }
    }

    private func accept(_ networkConnection: NWConnection) {
        guard isEnabled, let coordinator else {
            networkConnection.cancel()
            return
        }
        let id = "socket-\(UUID().uuidString.lowercased())"
        let port: Int? = {
            guard case let .ready(value) = state else { return nil }
            return Int(value)
        }()
        let hint = CompanionPairingTransportHint(
            service: CompanionListenerAdvertisement.serviceType,
            protocol: "tcp",
            port: port
        )
        let connection = CompanionNetworkConnection(
            id: id,
            connection: networkConnection,
            coordinator: coordinator,
            epoch: connectionEpoch,
            transportHint: hint
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event, connectionID: id) }
        }
        connections[id] = connection
        Task {
            do { try await connection.start() }
            catch { await connection.close(reason: "socket_start_failed") }
        }
    }

    private func accept(_ relaySocket: CompanionRelayVirtualSocket) {
        guard isEnabled, linkSignedIn, let coordinator else {
            Task { await relaySocket.localClose() }
            return
        }
        // A relay may re-open the same mux channel while its prior session's
        // async close is still draining. A unique host id prevents that late
        // `.closed` event from deleting the replacement connection.
        let id = "relay-\(relaySocket.id)-\(UUID().uuidString.lowercased())"
        let connection = CompanionRelayConnection(
            id: id,
            socket: relaySocket,
            coordinator: coordinator,
            epoch: connectionEpoch
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event, connectionID: id) }
        }
        connections[id] = connection
        Task {
            do { try await connection.start() }
            catch { await connection.close(reason: "relay_start_failed") }
        }
    }

    private func handle(_ event: CompanionConnectionEvent, connectionID: String) {
        switch event {
        case let .pairingPhrase(pairingID, deviceID, displayName, sas):
            pairingPhrase = PairingPhrase(
                pairingID: pairingID,
                connectionID: connectionID,
                deviceID: deviceID,
                displayName: displayName,
                sas: sas
            )
        case let .authenticated(device, _):
            connectedDeviceIDs.remove(device.deviceId)
            if let previousID = deviceConnections[device.deviceId],
               previousID != connectionID,
               let previous = connections.removeValue(forKey: previousID) {
                synchronizationTasks.removeValue(forKey: previousID)?.cancel()
                synchronizationTokens.removeValue(forKey: previousID)
                liveConnectionIDs.remove(previousID)
                Task {
                    await terminalStreamHub.releaseConnection(previousID)
                    await terminalControl?.releaseConnection(previousID)
                    await previous.close(reason: "device_connection_replaced")
                }
            }
            deviceConnections[device.deviceId] = connectionID
            pairingPayload = nil
            pairingCode = nil
            pairingPhrase = nil
            Task { await refreshDevices() }
        case let .live(device, _, resumeCursor):
            guard let connection = connections[connectionID] else { break }
            connectedDeviceIDs.insert(device.deviceId)
            synchronizationTasks[connectionID]?.cancel()
            let synchronizationToken = UUID()
            synchronizationTokens[connectionID] = synchronizationToken
            let synchronization = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return false }
                return await synchronize(
                    connectionID: connectionID,
                    deviceID: device.deviceId,
                    resumeCursor: resumeCursor,
                    connection: connection
                )
            }
            synchronizationTasks[connectionID] = synchronization
            Task { @MainActor [weak self] in
                let synchronized = await synchronization.value
                guard let self,
                      self.synchronizationTokens[connectionID] == synchronizationToken else { return }
                self.synchronizationTasks.removeValue(forKey: connectionID)
                self.synchronizationTokens.removeValue(forKey: connectionID)
                guard synchronized, self.connections[connectionID] != nil else { return }
                self.liveConnectionIDs.insert(connectionID)
            }
        case let .envelope(envelope, device):
            guard let connection = connections[connectionID] else { break }
            if envelope.kind == .ack {
                do {
                    let ack = try envelope.body.decode(CompanionAckBody.self)
                    try eventLog.acknowledge(deviceID: device.deviceId, sequence: ack.ackSeq)
                } catch {
                    Task { await connection.close(reason: "invalid_ack_cursor") }
                }
                break
            }
            guard envelope.kind == .command else { break }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let synchronization = synchronizationTasks[connectionID],
                   await synchronization.value == false { return }
                guard connections[connectionID] != nil else { return }
                do {
                    let command = try envelope.body.decode(CompanionCommandBody.self)
                    let receipt = try await commandRouter.route(
                        envelope,
                        device: device,
                        projection: projectionRevisions.current,
                        acknowledgeAttention: { portableSessionID in
                            guard let entry = AttentionCenter.shared.entries.first(where: {
                                RememberedSessionCatalogPortable.id(
                                    $0.targetID,
                                    domain: "session",
                                    maximumUTF8Bytes: 240
                                ) == portableSessionID
                            }) else { return false }
                            AttentionCenter.shared.clear(targetID: entry.targetID)
                            return true
                        },
                        handleExternal: { [weak self] command in
                            guard let self else { return nil }
                            return await self.routeExternal(
                                command,
                                deviceID: device.deviceId,
                                connectionID: connectionID
                            )
                        }
                    )
                    try await connection.sendReceipt(
                        receipt,
                        sequence: eventLog.currentSequence,
                        sentAt: Self.nowMilliseconds()
                    )
                    if command.type == "stream.subscribe",
                       receipt.status == .applied || receipt.status == .accepted,
                       let snapshot = await terminalStreamHub.currentSnapshot(
                           connectionID: connectionID,
                           command: command
                       ) {
                        let record = try eventLog.append(
                            kind: .event,
                            id: "terminal-snapshot-\(UUID().uuidString.lowercased())",
                            body: snapshot,
                            sentAt: Self.nowMilliseconds(),
                            audience: [connectionID]
                        )
                        try await send(record, to: connection)
                    }
                } catch {
                    await connection.close(reason: "command_route_failed")
                }
            }
        case .closed:
            synchronizationTasks.removeValue(forKey: connectionID)?.cancel()
            synchronizationTokens.removeValue(forKey: connectionID)
            connections.removeValue(forKey: connectionID)
            liveConnectionIDs.remove(connectionID)
            let disconnectedDeviceIDs = deviceConnections.compactMap { entry in
                entry.value == connectionID ? entry.key : nil
            }
            for deviceID in disconnectedDeviceIDs {
                eventLog.dropClient(deviceID)
                connectedDeviceIDs.remove(deviceID)
            }
            deviceConnections = deviceConnections.filter { $0.value != connectionID }
            if pairingPhrase?.connectionID == connectionID { pairingPhrase = nil }
            Task {
                await terminalStreamHub.releaseConnection(connectionID)
                await terminalControl?.releaseConnection(connectionID)
            }
        }
    }

    private func refreshDevices() async {
        pairedDevices = await roster?.list() ?? []
    }

    private func routeExternal(
        _ command: CompanionCommandBody,
        deviceID: String,
        connectionID: String
    ) async -> CompanionReceiptBody? {
        let key = terminalKey(projectID: command.projectId, terminalID: command.targetId)
        switch command.type {
        case "stream.subscribe":
            guard let terminal = terminalRecordsByKey[key] else {
                return receipt(
                    command,
                    status: .rejected,
                    message: "That terminal is no longer available in this project."
                )
            }
            return await terminalStreamHub.subscribe(
                connectionID: connectionID,
                command: command,
                terminal: terminal
            ).receipt
        case "stream.unsubscribe":
            return await terminalStreamHub.unsubscribe(
                connectionID: connectionID,
                command: command,
                terminal: terminalRecordsByKey[key]
            ).receipt
        default:
            return await terminalControl?.route(
                command: command,
                deviceID: deviceID,
                connectionID: connectionID,
                terminal: terminalRecordsByKey[key]
            )
        }
    }

    private func deliver(_ delivery: CompanionTerminalStreamDelivery) {
        let record: CompanionOutboundRecord
        do {
            record = try eventLog.append(
                kind: delivery.kind,
                id: delivery.id,
                body: delivery.body,
                sentAt: Self.nowMilliseconds(),
                audience: delivery.connectionIDs
            )
        } catch {
            lastError = "Kaisola could not sequence Companion terminal output."
            return
        }
        for connectionID in delivery.connectionIDs {
            guard liveConnectionIDs.contains(connectionID),
                  let connection = connections[connectionID] else { continue }
            Task {
                do {
                    try await send(record, to: connection)
                } catch {
                    await connection.close(reason: "terminal_stream_send_failed")
                }
            }
        }
    }

    private func receipt(
        _ command: CompanionCommandBody,
        status: CompanionReceiptStatus,
        message: String
    ) -> CompanionReceiptBody {
        CompanionReceiptBody(
            type: "command.receipt",
            commandId: command.commandId,
            status: status,
            message: String(message.prefix(800)),
            payload: nil
        )
    }

    private func terminalKey(projectID: String, terminalID: String) -> String {
        "\(projectID)\u{0}\(terminalID)"
    }

    private func portableID(_ value: String, domain: String, maximum: Int) -> String {
        RememberedSessionCatalogPortable.id(
            value,
            domain: domain,
            maximumUTF8Bytes: maximum
        )
    }

    private func appendProjection(
        _ projection: CompanionProjection
    ) throws -> CompanionOutboundRecord {
        try eventLog.append(
            kind: .snapshot,
            id: "snapshot-\(projection.revision)-\(UUID().uuidString.lowercased())",
            body: CompanionBody(CompanionSnapshotBody(
                type: "snapshot.projects",
                revision: projection.revision,
                projection: projection
            )),
            sentAt: Self.nowMilliseconds()
        )
    }

    private func synchronize(
        connectionID: String,
        deviceID: String,
        resumeCursor: CompanionAckCursor?,
        connection: any CompanionHostConnection
    ) async -> Bool {
        do {
            var cursor = resumeCursor
            // Usually one pass. The bounded retry closes the small reentrancy
            // window where a projection is published while the socket write is
            // suspended, without allowing a noisy peer to starve hello forever.
            for _ in 0..<4 {
                guard !Task.isCancelled else { return false }
                let synchronizedThrough: Int64
                switch try eventLog.replay(after: cursor, connectionID: connectionID) {
                case let .replay(records, currentSequence):
                    for record in records { try await send(record, to: connection) }
                    synchronizedThrough = currentSequence
                case let .snapshotRequired(_, currentSequence):
                    guard let projection = projectionRevisions.current else { return true }
                    let record = CompanionOutboundRecord(
                        kind: .snapshot,
                        sequence: currentSequence,
                        id: "snapshot-sync-\(UUID().uuidString.lowercased())",
                        sentAt: Self.nowMilliseconds(),
                        body: try CompanionBody(CompanionSnapshotBody(
                            type: "snapshot.projects",
                            revision: projection.revision,
                            projection: projection
                        )),
                        audience: nil
                    )
                    try await send(record, to: connection)
                    synchronizedThrough = currentSequence
                }
                cursor = CompanionAckCursor(epoch: connectionEpoch, seq: synchronizedThrough)
                if eventLog.currentSequence == synchronizedThrough { return true }
            }

            // A continuously streaming terminal can advance audience-scoped
            // records between every write. Finish with one coherent projection
            // at the latest cursor; the phone will immediately re-subscribe for
            // its own bounded terminal tail.
            if let projection = projectionRevisions.current {
                let sequence = eventLog.currentSequence
                try await send(CompanionOutboundRecord(
                    kind: .snapshot,
                    sequence: sequence,
                    id: "snapshot-sync-final-\(UUID().uuidString.lowercased())",
                    sentAt: Self.nowMilliseconds(),
                    body: try CompanionBody(CompanionSnapshotBody(
                        type: "snapshot.projects",
                        revision: projection.revision,
                        projection: projection
                    )),
                    audience: nil
                ), to: connection)
            }
            _ = deviceID
            return true
        } catch {
            await connection.close(reason: "companion_replay_failed")
            return false
        }
    }

    private func send(
        _ record: CompanionOutboundRecord,
        to connection: any CompanionHostConnection
    ) async throws {
        _ = try await connection.send(
            kind: record.kind,
            id: record.id,
            sequence: record.sequence,
            sentAt: record.sentAt,
            body: record.body
        )
    }

    private func send(
        _ record: CompanionOutboundRecord,
        connectionID: String,
        connection: any CompanionHostConnection
    ) async {
        do {
            try await send(record, to: connection)
        } catch {
            await connection.close(reason: "projection_send_failed")
            connections.removeValue(forKey: connectionID)
            liveConnectionIDs.remove(connectionID)
            deviceConnections = deviceConnections.filter { $0.value != connectionID }
            await terminalControl?.releaseConnection(connectionID)
        }
    }

    private func adopt(listenerState: CompanionListener.State) {
        switch listenerState {
        case .disabled:
            if state != .disabled { state = .starting }
        case .starting:
            state = .starting
        case let .ready(port):
            state = .ready(port: port)
            lastError = nil
        case let .failed(message):
            state = .failed(message)
            lastError = message
        }
    }

    private func fail(_ error: Error) {
        listener.stop()
        linkClient?.disable()
        let message = (error as? LocalizedError)?.errorDescription
            ?? "Kaisola could not start Companion."
        state = .failed(message)
        lastError = message
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
