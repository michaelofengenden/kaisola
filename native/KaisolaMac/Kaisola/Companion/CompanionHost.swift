import Combine
import Foundation
import KaisolaCore
import Network

/// Main-actor capability registry shared by Nearby and Link connections.
/// Revocation invalidates every token synchronously before any socket, lease,
/// replay, or persistence cleanup is allowed to suspend.
@MainActor
final class CompanionDeviceRevocationFence {
    struct Token: Hashable {
        fileprivate let id: UUID
        let deviceID: String
        let connectionID: String
    }

    private var tokensByConnection: [String: Token] = [:]
    private var revokedDeviceIDs: Set<String> = []

    func authorize(deviceID: String, connectionID: String, resumed: Bool) -> Token? {
        guard !deviceID.isEmpty, !connectionID.isEmpty else { return nil }
        if resumed, revokedDeviceIDs.contains(deviceID) { return nil }
        if !resumed { revokedDeviceIDs.remove(deviceID) }
        let token = Token(id: UUID(), deviceID: deviceID, connectionID: connectionID)
        tokensByConnection[connectionID] = token
        return token
    }

    func token(connectionID: String, deviceID: String) -> Token? {
        guard let token = tokensByConnection[connectionID], token.deviceID == deviceID,
              isAuthorized(token) else { return nil }
        return token
    }

    func token(connectionID: String) -> Token? {
        guard let token = tokensByConnection[connectionID], isAuthorized(token) else { return nil }
        return token
    }

    func isAuthorized(_ token: Token) -> Bool {
        !revokedDeviceIDs.contains(token.deviceID)
            && tokensByConnection[token.connectionID] == token
    }

    @discardableResult
    func revoke(deviceID: String) -> [String] {
        revokedDeviceIDs.insert(deviceID)
        let connectionIDs = tokensByConnection.values
            .filter { $0.deviceID == deviceID }
            .map(\.connectionID)
            .sorted()
        for connectionID in connectionIDs { tokensByConnection.removeValue(forKey: connectionID) }
        return connectionIDs
    }

    func invalidate(connectionID: String) {
        tokensByConnection.removeValue(forKey: connectionID)
    }

    func invalidateAllConnections() {
        tokensByConnection.removeAll()
    }

    /// Durable roster tombstones remain account-scoped in their own stores.
    /// The in-memory fence must not carry Account A's device identifiers into
    /// Account B, where an unrelated device may legitimately use the same ID.
    func resetForAccountChange() {
        tokensByConnection.removeAll()
        revokedDeviceIDs.removeAll()
    }
}

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

    private struct ConnectionCapabilityAuthority: Equatable {
        let deviceID: String
        let capabilities: Set<CompanionCapability>
        let generation: UInt64
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
    private var pairingCoordinatorDisposal: (id: UUID, task: Task<Void, Never>)?
    private var linkConfiguration: LinkConfiguration?
    private var linkClient: CompanionLinkClient?
    private var linkObservations: Set<AnyCancellable> = []
    private var linkSignedIn = false
    private var activeAccountScope: CompanionAccountScope?
    private var connections: [String: any CompanionHostConnection] = [:]
    private var deviceConnections: [String: String] = [:]
    private var connectionAuthorities: [String: ConnectionCapabilityAuthority] = [:]
    private var pendingCapabilityUpdates: [String: Set<CompanionCapability>] = [:]
    private var nextAuthorityGeneration: UInt64 = 1
    private var liveConnectionIDs: Set<String> = []
    private var synchronizationTasks: [String: Task<Bool, Never>] = [:]
    private var synchronizationTokens: [String: UUID] = [:]
    private var connectionEpoch: String
    private var eventLog: CompanionEventLog
    private var projectionRevisions = CompanionProjectionRevisions()
    private let commandRouter = CompanionCommandRouter()
    private let revocationFence = CompanionDeviceRevocationFence()
    private var terminalControlAdapter: CompanionTerminalControlAdapter?
    private var terminalControl: CompanionTerminalControl?
    private var terminalControlDisposal: (id: UUID, task: Task<Void, Never>)?
    private var terminalControlGeneration = UUID()
    private var terminalRecordsByKey: [String: BrokerTerminalRecord] = [:]
    private var terminalStreamHubInstance: CompanionTerminalStreamHub?
    private var terminalStreamHubGeneration = UUID()
    /// Invalidates every async callback and resource capture from an older
    /// signed-in account or host incarnation. This is separate from device
    /// revocation: account switches must also fence pairing and roster work
    /// that has not authenticated a device yet.
    private var hostGeneration = UUID()

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
        let accountScope = try! CompanionAccountScope(accountID: "visual-companion-account")
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
                lastSeenAt: 1_785_216_060_000,
                accountScope: accountScope
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
    /// restore has proven a signed-in user. Neither LAN nor Link may inherit
    /// pairing authority from an anonymous or stale account session.
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

    /// Switch the entire Companion authority partition. The old listener,
    /// connections, command lanes, leases, replay log, and roster references
    /// are synchronously sealed before the replacement account can start.
    func setActiveAccountID(_ accountID: String?) {
        let nextScope = accountID.flatMap { try? CompanionAccountScope(accountID: $0) }
        guard nextScope != activeAccountScope else {
            setKaisolaLinkSignedIn(nextScope != nil)
            return
        }
        hostGeneration = UUID()
        if isEnabled || identity != nil || !connections.isEmpty {
            stop(persistPreference: false)
        }
        activeAccountScope = nextScope
        setKaisolaLinkSignedIn(nextScope != nil)
        if nextScope != nil, defaults.bool(forKey: Self.enabledDefaultsKey) {
            startAfterRetiredPairingStateIsSealed()
        }
    }

    private func prepareKaisolaLink() {
        guard isEnabled, linkSignedIn, linkClient == nil,
              let linkConfiguration, let identity else { return }
        let generation = hostGeneration
        guard let client = CompanionLinkClient(
            desktopID: identity.id,
            baseURL: linkConfiguration.baseURL,
            tokenProvider: linkConfiguration.tokenProvider,
            acceptSocket: { [weak self] socket in
                self?.accept(socket, generation: generation)
            }
        ) else {
            linkPhase = .unavailable
            return
        }
        linkClient = client
        client.$phase
            .sink { [weak self] phase in
                guard self?.isCurrentHost(generation) == true,
                      self?.linkClient === client else { return }
                self?.linkPhase = phase
            }
            .store(in: &linkObservations)
        client.$channelCount
            .sink { [weak self] count in
                guard self?.isCurrentHost(generation) == true,
                      self?.linkClient === client else { return }
                self?.linkChannelCount = count
            }
            .store(in: &linkObservations)
        client.enable()
    }

    private func terminalStreamHub() -> CompanionTerminalStreamHub {
        if let terminalStreamHubInstance { return terminalStreamHubInstance }
        let generation = terminalStreamHubGeneration
        let hub = CompanionTerminalStreamHub { [weak self] delivery in
            Task { @MainActor in
                guard let self, self.terminalStreamHubGeneration == generation else { return }
                self.deliver(delivery)
            }
        }
        terminalStreamHubInstance = hub
        return hub
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
        guard activeAccountScope != nil,
              defaults.bool(forKey: Self.enabledDefaultsKey) else { return }
        startAfterRetiredPairingStateIsSealed()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled { startAfterRetiredPairingStateIsSealed() }
        else { stop() }
    }

    /// A recovery action that never revokes a pairing or widens capabilities.
    /// Nearby already listens continuously; refreshing Link (or restarting a
    /// failed listener) gives an offline phone a fresh route to resume on.
    func refreshReconnectAvailability() {
        lastError = nil
        if case .failed = state {
            stop(persistPreference: false)
            startAfterRetiredPairingStateIsSealed()
            return
        }
        if !isEnabled {
            setEnabled(true)
            return
        }
        linkClient?.refresh()
    }

    private func startAfterRetiredPairingStateIsSealed() {
        guard activeAccountScope != nil else {
            state = .disabled
            lastError = "Sign in before enabling Companion."
            return
        }
        guard let pending = pairingCoordinatorDisposal else {
            start()
            return
        }
        let generation = hostGeneration
        state = .starting
        Task { @MainActor [weak self] in
            await pending.task.value
            guard let self else { return }
            if self.pairingCoordinatorDisposal?.id == pending.id {
                self.pairingCoordinatorDisposal = nil
            }
            guard self.hostGeneration == generation,
                  self.activeAccountScope != nil,
                  self.defaults.bool(forKey: Self.enabledDefaultsKey) else { return }
            self.state = .disabled
            self.start()
        }
    }

    func createPairingOffer(
        allowsAgentControl: Bool,
        allowsTerminalControl: Bool
    ) async throws {
        guard case let .ready(port) = state, let coordinator,
              let accountScope = activeAccountScope else {
            throw CompanionWireError.connectionUnavailable
        }
        let generation = hostGeneration
        if let current = pairingPayload {
            _ = await coordinator.cancelOffer(pairingID: current.pairingNonce)
            guard isCurrentHost(generation, accountScope: accountScope),
                  self.coordinator === coordinator else {
                throw CompanionWireError.connectionUnavailable
            }
        }
        pairingPhrase = nil
        var selected: Set<CompanionCapability> = [.observe]
        if allowsAgentControl { selected.insert(.agentControl) }
        if allowsTerminalControl { selected.insert(.terminalControl) }
        let capabilities = CompanionCapability.allCases.filter(selected.contains)
        let payload = try await coordinator.createOffer(
            listenerPort: port,
            requestedCapabilities: capabilities,
            nowMilliseconds: Self.nowMilliseconds()
        )
        guard isCurrentHost(generation, accountScope: accountScope),
              self.coordinator === coordinator,
              payload.accountScope == accountScope else {
            _ = await coordinator.cancelOffer(pairingID: payload.pairingNonce)
            throw CompanionWireError.connectionUnavailable
        }
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
              let connection = connections[phrase.connectionID],
              let roster else {
            throw CompanionPairingCoordinatorError.handshakeOrder
        }
        let generation = hostGeneration
        guard await connection.confirmPairing(pairingID: phrase.pairingID) else {
            throw CompanionPairingCoordinatorError.handshakeOrder
        }
        guard isCurrentHost(generation),
              connections[phrase.connectionID] != nil else {
            // If the final SAS frame won the race with account shutdown, leave
            // a durable tombstone in the retired account rather than allowing
            // that late pairing to reappear when the user switches back.
            _ = try? await roster.revoke(phrase.deviceID)
            await connection.close(reason: "account_changed")
            throw CompanionWireError.connectionUnavailable
        }
    }

    func revoke(deviceID: String) async throws {
        guard let roster else { throw CompanionWireError.connectionUnavailable }
        let generation = hostGeneration
        let streamHub = terminalStreamHubInstance
        let terminalControl = self.terminalControl
        // Seal both revocation and capability authority before the first await.
        // This is the linearization point for every transport and queued command.
        var revokedConnectionIDs = Set(revocationFence.revoke(deviceID: deviceID))
        revokedConnectionIDs.formUnion(connectionAuthorities.compactMap { connectionID, authority in
            authority.deviceID == deviceID ? connectionID : nil
        })
        if let mapped = deviceConnections.removeValue(forKey: deviceID) {
            revokedConnectionIDs.insert(mapped)
        }
        commandRouter.revoke(deviceID: deviceID)
        eventLog.dropClient(deviceID)
        connectedDeviceIDs.remove(deviceID)
        for connectionID in revokedConnectionIDs {
            synchronizationTasks.removeValue(forKey: connectionID)?.cancel()
            synchronizationTokens.removeValue(forKey: connectionID)
            liveConnectionIDs.remove(connectionID)
            connectionAuthorities.removeValue(forKey: connectionID)
        }
        let revokedConnections = revokedConnectionIDs.compactMap { connectionID in
            connections.removeValue(forKey: connectionID).map { (connectionID, $0) }
        }

        // Persist the roster tombstone before reporting success. The in-memory
        // fence remains closed if persistence fails, so access never widens.
        _ = try await roster.revoke(deviceID)
        for (connectionID, connection) in revokedConnections {
            await streamHub?.releaseConnection(connectionID)
            await terminalControl?.releaseConnection(connectionID)
            _ = try? await connection.sendDeviceRevoked()
            await connection.close(reason: "device_revoked")
        }
        await refreshDevices(using: roster, generation: generation)
    }

    /// Persist a new per-device grant and apply it to every authenticated route.
    /// Removed authority is fenced synchronously before any actor or transport
    /// await. Added authority is exposed only after the connection has adopted
    /// it and delivered a replacement desktop hello.
    func updateCapabilities(
        deviceID: String,
        capabilities: [CompanionCapability]
    ) async throws {
        guard let roster else { throw CompanionWireError.connectionUnavailable }
        let hostGeneration = self.hostGeneration
        let streamHub = terminalStreamHubInstance
        let terminalControl = self.terminalControl
        let desired = Set(capabilities)
        guard desired.contains(.observe), desired.count == capabilities.count,
              pendingCapabilityUpdates[deviceID] == nil else {
            throw CompanionWireError.connectionUnavailable
        }
        pendingCapabilityUpdates[deviceID] = desired
        defer {
            if isCurrentHost(hostGeneration), pendingCapabilityUpdates[deviceID] == desired {
                pendingCapabilityUpdates.removeValue(forKey: deviceID)
            }
        }

        let initialAuthorities = connectionAuthorities.filter {
            $0.value.deviceID == deviceID
        }
        for (connectionID, authority) in initialAuthorities {
            let generation = issueAuthorityGeneration()
            connectionAuthorities[connectionID] = ConnectionCapabilityAuthority(
                deviceID: deviceID,
                capabilities: authority.capabilities.intersection(desired),
                generation: generation
            )
        }
        commandRouter.invalidate(deviceID: deviceID)

        for (connectionID, authority) in initialAuthorities
        where authority.capabilities.contains(.terminalControl)
            && !desired.contains(.terminalControl) {
            await terminalControl?.releaseConnection(connectionID)
            guard isCurrentHost(hostGeneration), self.roster === roster else {
                throw CompanionWireError.connectionUnavailable
            }
        }

        let record: CompanionPairedDeviceRecord
        do {
            record = try await roster.updateCapabilities(capabilities, for: deviceID)
        } catch {
            guard isCurrentHost(hostGeneration), self.roster === roster else {
                throw CompanionWireError.connectionUnavailable
            }
            // We cannot safely re-widen a session after persistence failed: it
            // may already have observed the provisional narrowing. Seal every
            // route for this device and let a later reconnect read the durable
            // roster rather than guessing which actor write completed.
            await closeConnections(deviceID: deviceID, reason: "capability_persist_failed")
            throw error
        }
        guard isCurrentHost(hostGeneration), self.roster === roster else {
            throw CompanionWireError.connectionUnavailable
        }
        let stored = Set(record.capabilities)
        var connectionIDs = Set(connectionAuthorities.compactMap { connectionID, authority in
            authority.deviceID == deviceID ? connectionID : nil
        })
        if let connectionID = deviceConnections[deviceID] {
            connectionIDs.insert(connectionID)
        }

        for connectionID in connectionIDs {
            if let authority = connectionAuthorities[connectionID],
               authority.deviceID == deviceID {
                let generation = issueAuthorityGeneration()
                connectionAuthorities[connectionID] = ConnectionCapabilityAuthority(
                    deviceID: deviceID,
                    capabilities: authority.capabilities.intersection(stored),
                    generation: generation
                )
            }
            guard let connection = connections[connectionID] else { continue }
            do {
                let effective = Set(try await connection.updateCapabilities(record.capabilities))
                guard isCurrentHost(hostGeneration), self.roster === roster,
                      connections[connectionID] != nil,
                      let current = connectionAuthorities[connectionID],
                      current.deviceID == deviceID else {
                    continue
                }
                let generation = issueAuthorityGeneration()
                connectionAuthorities[connectionID] = ConnectionCapabilityAuthority(
                    deviceID: deviceID,
                    capabilities: effective.intersection(stored),
                    generation: generation
                )
            } catch {
                guard isCurrentHost(hostGeneration), self.roster === roster else {
                    throw CompanionWireError.connectionUnavailable
                }
                retireAuthority(connectionID: connectionID, deviceID: deviceID)
                connections.removeValue(forKey: connectionID)
                revocationFence.invalidate(connectionID: connectionID)
                liveConnectionIDs.remove(connectionID)
                deviceConnections = deviceConnections.filter { $0.value != connectionID }
                connectedDeviceIDs.remove(deviceID)
                await streamHub?.releaseConnection(connectionID)
                await terminalControl?.releaseConnection(connectionID)
                await connection.close(reason: "capability_update_failed")
            }
        }
        await refreshDevices(using: roster, generation: hostGeneration)
    }

    /// Accept a whole-app snapshot from the AppDelegate's window registry.
    /// Meaningless refreshes are dropped before any secure socket write.
    func publishProjection(
        drafts: [RememberedSessionDraft],
        terminalStreams: [String: CompanionTerminalStreamHead],
        terminalRecords: [BrokerTerminalRecord]
    ) {
        // Projection caches are account capabilities, not app-global display
        // state. Never stage a signed-out snapshot for whichever user signs in
        // next, and reset the gate synchronously during stop/account switch.
        guard activeAccountScope != nil, isEnabled else { return }
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
            let targets: [(
                id: String,
                connection: any CompanionHostConnection,
                authority: CompanionDeviceRevocationFence.Token
            )] = liveConnectionIDs.compactMap { id in
                guard let connection = connections[id],
                      let authority = revocationFence.token(connectionID: id) else { return nil }
                return (id: id, connection: connection, authority: authority)
            }
            Task {
                for (id, connection, authority) in targets {
                    await send(
                        record,
                        connectionID: id,
                        connection: connection,
                        authority: authority
                    )
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
        guard let accountScope = activeAccountScope else {
            state = .disabled
            lastError = "Sign in before enabling Companion."
            return
        }
        let generation = UUID()
        hostGeneration = generation
        state = .starting
        lastError = nil
        prepareTerminalControl()
        do {
            try NativePreviewPaths.prepareCompanionDirectory()
            let identity = try CompanionIdentityStore().loadOrCreate(
                displayName: Host.current().localizedName ?? "Kaisola Desktop"
            )
            let roster = try CompanionDeviceRosterStore(
                fileURL: NativePreviewPaths.companionDevices(accountScope: accountScope),
                accountScope: accountScope
            )
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
                Task { @MainActor in
                    self?.accept(connection, generation: generation)
                }
            }
            try listener.start(identity: identity)
            prepareKaisolaLink()
            Task { await refreshDevices(using: roster, generation: generation) }
        } catch {
            fail(error)
        }
    }

    private func stop(persistPreference: Bool = true) {
        if persistPreference { defaults.set(false, forKey: Self.enabledDefaultsKey) }
        hostGeneration = UUID()
        commandRouter.invalidateAll()
        listener.stop()
        linkClient?.disable()
        linkClient = nil
        linkObservations.removeAll()
        linkPhase = .off
        linkChannelCount = 0
        let active = Array(connections.values)
        let expiringCoordinator = coordinator
        let priorPairingDisposal = pairingCoordinatorDisposal
        let pairingDisposalID = UUID()
        let pairingDisposalTask = Task {
            await priorPairingDisposal?.task.value
            await expiringCoordinator?.invalidateAll()
        }
        pairingCoordinatorDisposal = (pairingDisposalID, pairingDisposalTask)
        let expiringTerminalStreamHub = terminalStreamHubInstance
        terminalStreamHubInstance = nil
        terminalStreamHubGeneration = UUID()
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
        revocationFence.resetForAccountChange()
        deviceConnections.removeAll()
        for deviceID in Set(connectionAuthorities.values.map(\.deviceID)) {
            commandRouter.invalidate(deviceID: deviceID)
        }
        connectionAuthorities.removeAll()
        pendingCapabilityUpdates.removeAll()
        nextAuthorityGeneration = 1
        liveConnectionIDs.removeAll()
        terminalRecordsByKey.removeAll()
        connectionEpoch = "epoch-\(UUID().uuidString.lowercased())"
        eventLog = CompanionEventLog(epoch: connectionEpoch)
        projectionRevisions = CompanionProjectionRevisions()
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
            await pairingDisposalTask.value
            for connection in active { await connection.close(reason: "host_disabled") }
            await expiringTerminalStreamHub?.shutdown()
            await disposalTask.value
            if terminalControlDisposal?.id == disposalID {
                terminalControlDisposal = nil
            }
            if pairingCoordinatorDisposal?.id == pairingDisposalID {
                pairingCoordinatorDisposal = nil
            }
        }
    }

    private func accept(_ networkConnection: NWConnection, generation: UUID) {
        guard isCurrentHost(generation), isEnabled, let coordinator, let roster else {
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
            Task { @MainActor in
                self?.handle(
                    event,
                    connectionID: id,
                    generation: generation,
                    roster: roster
                )
            }
        }
        connections[id] = connection
        Task {
            do { try await connection.start() }
            catch { await connection.close(reason: "socket_start_failed") }
        }
    }

    private func accept(_ relaySocket: CompanionRelayVirtualSocket, generation: UUID) {
        guard isCurrentHost(generation), isEnabled, linkSignedIn,
              let coordinator, let roster else {
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
            Task { @MainActor in
                self?.handle(
                    event,
                    connectionID: id,
                    generation: generation,
                    roster: roster
                )
            }
        }
        connections[id] = connection
        Task {
            do { try await connection.start() }
            catch { await connection.close(reason: "relay_start_failed") }
        }
    }

    private func handle(
        _ event: CompanionConnectionEvent,
        connectionID: String,
        generation: UUID,
        roster: CompanionDeviceRosterStore
    ) {
        guard isCurrentHost(generation), self.roster === roster else {
            if case let .authenticated(device, resumed) = event, !resumed {
                Task { _ = try? await roster.revoke(device.deviceId) }
            }
            return
        }
        switch event {
        case let .pairingPhrase(pairingID, deviceID, displayName, sas):
            guard connections[connectionID] != nil else { break }
            pairingPhrase = PairingPhrase(
                pairingID: pairingID,
                connectionID: connectionID,
                deviceID: deviceID,
                displayName: displayName,
                sas: sas
            )
        case let .authenticated(device, resumed):
            guard let rejectedConnection = connections[connectionID] else { break }
            guard revocationFence.authorize(
                deviceID: device.deviceId,
                connectionID: connectionID,
                resumed: resumed
            ) != nil else {
                connections.removeValue(forKey: connectionID)
                Task {
                    _ = try? await rejectedConnection.sendDeviceRevoked()
                    await rejectedConnection.close(reason: "device_revoked")
                }
                break
            }
            connectedDeviceIDs.remove(device.deviceId)
            if let previousID = deviceConnections[device.deviceId],
               previousID != connectionID,
               let previous = connections.removeValue(forKey: previousID) {
                let streamHub = terminalStreamHubInstance
                let terminalControl = self.terminalControl
                retireAuthority(connectionID: previousID, deviceID: device.deviceId)
                revocationFence.invalidate(connectionID: previousID)
                synchronizationTasks.removeValue(forKey: previousID)?.cancel()
                synchronizationTokens.removeValue(forKey: previousID)
                liveConnectionIDs.remove(previousID)
                Task {
                    await streamHub?.releaseConnection(previousID)
                    await terminalControl?.releaseConnection(previousID)
                    await previous.close(reason: "device_connection_replaced")
                }
            }
            deviceConnections[device.deviceId] = connectionID
            pairingPayload = nil
            pairingCode = nil
            pairingPhrase = nil
            Task { await refreshDevices(using: roster, generation: generation) }
        case let .live(device, capabilities, resumeCursor):
            guard let connection = connections[connectionID] else { break }
            guard let revocationAuthority = revocationFence.token(
                    connectionID: connectionID,
                    deviceID: device.deviceId
                  ) else {
                connections.removeValue(forKey: connectionID)
                Task { await connection.close(reason: "device_revoked") }
                break
            }
            let authorityGeneration = issueAuthorityGeneration()
            let granted = Set(capabilities)
            let authorized = pendingCapabilityUpdates[device.deviceId]
                .map { granted.intersection($0) } ?? granted
            let capabilityAuthority = ConnectionCapabilityAuthority(
                deviceID: device.deviceId,
                capabilities: authorized,
                generation: authorityGeneration
            )
            connectionAuthorities[connectionID] = capabilityAuthority
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
                    connection: connection,
                    authority: revocationAuthority,
                    generation: generation
                )
            }
            synchronizationTasks[connectionID] = synchronization
            Task { @MainActor [weak self] in
                let synchronized = await synchronization.value
                guard let self,
                      self.synchronizationTokens[connectionID] == synchronizationToken else { return }
                self.synchronizationTasks.removeValue(forKey: connectionID)
                self.synchronizationTokens.removeValue(forKey: connectionID)
                guard synchronized, self.isCurrentHost(generation),
                      self.connections[connectionID] != nil,
                      self.revocationFence.isAuthorized(revocationAuthority),
                      self.connectionAuthorities[connectionID] == capabilityAuthority else { return }
                self.liveConnectionIDs.insert(connectionID)
            }
        case let .envelope(envelope, device):
            guard let connection = connections[connectionID],
                  let revocationAuthority = revocationFence.token(
                    connectionID: connectionID,
                    deviceID: device.deviceId
                  ) else { break }
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
            let streamHub = terminalStreamHub()
            let terminalControl = self.terminalControl
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let synchronization = synchronizationTasks[connectionID],
                   await synchronization.value == false { return }
                guard isCurrentHost(generation),
                      connections[connectionID] != nil,
                      revocationFence.isAuthorized(revocationAuthority),
                      let capabilityAuthority = connectionAuthorities[connectionID],
                      capabilityAuthority.deviceID == device.deviceId else { return }
                do {
                    let command = try envelope.body.decode(CompanionCommandBody.self)
                    let receipt = try await commandRouter.route(
                        envelope,
                        device: device,
                        effectiveCapabilities: capabilityAuthority.capabilities,
                        authorityGeneration: capabilityAuthority.generation,
                        authorityIsCurrent: { [weak self] in
                            guard let self else { return false }
                            return self.isCurrentHost(generation)
                                && self.connections[connectionID] != nil
                                && self.deviceConnections[device.deviceId] == connectionID
                                && self.connectionAuthorities[connectionID] == capabilityAuthority
                                && self.revocationFence.isAuthorized(revocationAuthority)
                        },
                        projection: projectionRevisions.current,
                        isAuthorized: { [weak self] in
                            guard let self else { return false }
                            return self.isCurrentHost(generation)
                                && self.revocationFence.isAuthorized(revocationAuthority)
                        },
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
                                connectionID: connectionID,
                                authority: revocationAuthority,
                                generation: generation,
                                streamHub: streamHub,
                                terminalControl: terminalControl
                            )
                        }
                    )
                    guard self.isCurrentHost(generation),
                          self.revocationFence.isAuthorized(revocationAuthority),
                          self.connections[connectionID] != nil,
                          self.connectionAuthorities[connectionID] == capabilityAuthority else { return }
                    try await connection.sendReceipt(
                        receipt,
                        sequence: eventLog.currentSequence,
                        sentAt: Self.nowMilliseconds()
                    )
                    if command.type == "stream.subscribe",
                       receipt.status == .applied || receipt.status == .accepted,
                       let snapshot = await streamHub.currentSnapshot(
                           connectionID: connectionID,
                           command: command
                       ) {
                        guard self.isCurrentHost(generation),
                              self.revocationFence.isAuthorized(revocationAuthority),
                              self.connections[connectionID] != nil,
                              self.connectionAuthorities[connectionID] == capabilityAuthority else { return }
                        let record = try eventLog.append(
                            kind: .event,
                            id: "terminal-snapshot-\(UUID().uuidString.lowercased())",
                            body: snapshot,
                            sentAt: Self.nowMilliseconds(),
                            audience: [connectionID]
                        )
                        guard self.isCurrentHost(generation),
                              self.revocationFence.isAuthorized(revocationAuthority),
                              self.connections[connectionID] != nil,
                              self.connectionAuthorities[connectionID] == capabilityAuthority else { return }
                        try await send(record, to: connection)
                    }
                } catch {
                    await connection.close(reason: "command_route_failed")
                }
            }
        case .closed:
            guard connections[connectionID] != nil else { break }
            let streamHub = terminalStreamHubInstance
            let terminalControl = self.terminalControl
            synchronizationTasks.removeValue(forKey: connectionID)?.cancel()
            synchronizationTokens.removeValue(forKey: connectionID)
            connections.removeValue(forKey: connectionID)
            revocationFence.invalidate(connectionID: connectionID)
            liveConnectionIDs.remove(connectionID)
            if let authority = connectionAuthorities[connectionID] {
                retireAuthority(
                    connectionID: connectionID,
                    deviceID: authority.deviceID
                )
            }
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
                await streamHub?.releaseConnection(connectionID)
                await terminalControl?.releaseConnection(connectionID)
            }
        }
    }

    private func refreshDevices(
        using roster: CompanionDeviceRosterStore,
        generation: UUID
    ) async {
        let devices = await roster.list()
        guard isCurrentHost(generation), self.roster === roster else { return }
        pairedDevices = devices
    }

    private func routeExternal(
        _ command: CompanionCommandBody,
        deviceID: String,
        connectionID: String,
        authority: CompanionDeviceRevocationFence.Token,
        generation: UUID,
        streamHub: CompanionTerminalStreamHub,
        terminalControl: CompanionTerminalControl?
    ) async -> CompanionReceiptBody? {
        guard isCurrentHost(generation),
              revocationFence.isAuthorized(authority) else { return revokedReceipt(command) }
        let key = terminalKey(projectID: command.projectId, terminalID: command.targetId)
        let terminal = terminalRecordsByKey[key]
        switch command.type {
        case "stream.subscribe":
            guard let terminal else {
                return receipt(
                    command,
                    status: .rejected,
                    message: "That terminal is no longer available in this project."
                )
            }
            let response = await streamHub.subscribe(
                connectionID: connectionID,
                command: command,
                terminal: terminal
            )
            guard isCurrentHost(generation),
                  revocationFence.isAuthorized(authority) else {
                await streamHub.releaseConnection(connectionID)
                return revokedReceipt(command)
            }
            return response.receipt
        case "stream.unsubscribe":
            let response = await streamHub.unsubscribe(
                connectionID: connectionID,
                command: command,
                terminal: terminal
            )
            guard isCurrentHost(generation),
                  revocationFence.isAuthorized(authority) else {
                await streamHub.releaseConnection(connectionID)
                return revokedReceipt(command)
            }
            return response.receipt
        default:
            let response = await terminalControl?.route(
                command: command,
                deviceID: deviceID,
                connectionID: connectionID,
                terminal: terminal,
                isAuthorized: { [weak self] in
                    guard let self else { return false }
                    return self.isCurrentHost(generation)
                        && self.revocationFence.isAuthorized(authority)
                }
            )
            guard isCurrentHost(generation),
                  revocationFence.isAuthorized(authority) else {
                return revokedReceipt(command)
            }
            return response
        }
    }

    private func revokedReceipt(_ command: CompanionCommandBody) -> CompanionReceiptBody {
        receipt(
            command,
            status: .rejected,
            message: "This Companion device is no longer authorized."
        )
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
                  let connection = connections[connectionID],
                  let authority = revocationFence.token(connectionID: connectionID) else { continue }
            Task {
                await send(
                    record,
                    connectionID: connectionID,
                    connection: connection,
                    authority: authority,
                    failureReason: "terminal_stream_send_failed"
                )
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
        guard let sanitized = CompanionCapabilityPolicy.sanitizedProjection(
            projection,
            grantedCapabilities: [.observe]
        ) else {
            throw CompanionProtocolError.invalidBody("snapshot.projects projection")
        }
        return try eventLog.append(
            kind: .snapshot,
            id: "snapshot-\(sanitized.revision)-\(UUID().uuidString.lowercased())",
            body: CompanionBody(CompanionSnapshotBody(
                type: "snapshot.projects",
                revision: sanitized.revision,
                projection: sanitized
            )),
            sentAt: Self.nowMilliseconds()
        )
    }

    private func synchronize(
        connectionID: String,
        deviceID: String,
        resumeCursor: CompanionAckCursor?,
        connection: any CompanionHostConnection,
        authority: CompanionDeviceRevocationFence.Token,
        generation: UUID
    ) async -> Bool {
        do {
            var cursor = resumeCursor
            // Usually one pass. The bounded retry closes the small reentrancy
            // window where a projection is published while the socket write is
            // suspended, without allowing a noisy peer to starve hello forever.
            for _ in 0..<4 {
                guard !Task.isCancelled, isCurrentHost(generation),
                      revocationFence.isAuthorized(authority) else { return false }
                let synchronizedThrough: Int64
                switch try eventLog.replay(after: cursor, connectionID: connectionID) {
                case let .replay(records, currentSequence):
                    for record in records {
                        guard isCurrentHost(generation),
                              revocationFence.isAuthorized(authority) else { return false }
                        try await send(record, to: connection)
                        guard isCurrentHost(generation),
                              revocationFence.isAuthorized(authority) else { return false }
                    }
                    synchronizedThrough = currentSequence
                case let .snapshotRequired(_, currentSequence):
                    guard let projection = projectionRevisions.current else { return true }
                    guard let sanitized = CompanionCapabilityPolicy.sanitizedProjection(
                        projection,
                        grantedCapabilities: [.observe]
                    ) else { return false }
                    let record = CompanionOutboundRecord(
                        kind: .snapshot,
                        sequence: currentSequence,
                        id: "snapshot-sync-\(UUID().uuidString.lowercased())",
                        sentAt: Self.nowMilliseconds(),
                        body: try CompanionBody(CompanionSnapshotBody(
                            type: "snapshot.projects",
                            revision: sanitized.revision,
                            projection: sanitized
                        )),
                        audience: nil
                    )
                    guard isCurrentHost(generation),
                          revocationFence.isAuthorized(authority) else { return false }
                    try await send(record, to: connection)
                    guard isCurrentHost(generation),
                          revocationFence.isAuthorized(authority) else { return false }
                    synchronizedThrough = currentSequence
                }
                cursor = CompanionAckCursor(epoch: connectionEpoch, seq: synchronizedThrough)
                if eventLog.currentSequence == synchronizedThrough { return true }
            }

            // A continuously streaming terminal can advance audience-scoped
            // records between every write. Finish with one coherent projection
            // at the latest cursor; the phone will immediately re-subscribe for
            // its own bounded terminal tail.
            if let projection = projectionRevisions.current,
               isCurrentHost(generation),
               revocationFence.isAuthorized(authority) {
                guard let sanitized = CompanionCapabilityPolicy.sanitizedProjection(
                    projection,
                    grantedCapabilities: [.observe]
                ) else { return false }
                let sequence = eventLog.currentSequence
                try await send(CompanionOutboundRecord(
                    kind: .snapshot,
                    sequence: sequence,
                    id: "snapshot-sync-final-\(UUID().uuidString.lowercased())",
                    sentAt: Self.nowMilliseconds(),
                    body: try CompanionBody(CompanionSnapshotBody(
                        type: "snapshot.projects",
                        revision: sanitized.revision,
                        projection: sanitized
                    )),
                    audience: nil
                ), to: connection)
                guard isCurrentHost(generation),
                      revocationFence.isAuthorized(authority) else { return false }
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
        connection: any CompanionHostConnection,
        authority: CompanionDeviceRevocationFence.Token,
        failureReason: String = "projection_send_failed"
    ) async {
        guard revocationFence.isAuthorized(authority),
              connections[connectionID] != nil else { return }
        do {
            try await send(record, to: connection)
        } catch {
            await connection.close(reason: failureReason)
            guard revocationFence.isAuthorized(authority) else { return }
            connections.removeValue(forKey: connectionID)
            revocationFence.invalidate(connectionID: connectionID)
            liveConnectionIDs.remove(connectionID)
            if let authority = connectionAuthorities[connectionID] {
                retireAuthority(
                    connectionID: connectionID,
                    deviceID: authority.deviceID
                )
            }
            deviceConnections = deviceConnections.filter { $0.value != connectionID }
            await terminalControl?.releaseConnection(connectionID)
        }
    }

    private func isCurrentHost(
        _ generation: UUID,
        accountScope: CompanionAccountScope? = nil
    ) -> Bool {
        guard hostGeneration == generation else { return false }
        guard let accountScope else { return true }
        return activeAccountScope == accountScope
    }

    private func issueAuthorityGeneration() -> UInt64 {
        let generation = nextAuthorityGeneration
        nextAuthorityGeneration &+= 1
        if nextAuthorityGeneration == 0 { nextAuthorityGeneration = 1 }
        return generation
    }

    private func retireAuthority(connectionID: String, deviceID: String) {
        connectionAuthorities.removeValue(forKey: connectionID)
        commandRouter.invalidate(deviceID: deviceID)
    }

    private func closeConnections(deviceID: String, reason: String) async {
        var connectionIDs = Set(connectionAuthorities.compactMap { connectionID, authority in
            authority.deviceID == deviceID ? connectionID : nil
        })
        if let connectionID = deviceConnections.removeValue(forKey: deviceID) {
            connectionIDs.insert(connectionID)
        }
        let streamHub = terminalStreamHubInstance
        let terminalControl = self.terminalControl
        var retiringConnections: [(String, any CompanionHostConnection)] = []
        for connectionID in connectionIDs {
            if let connection = connections.removeValue(forKey: connectionID) {
                retiringConnections.append((connectionID, connection))
            }
            revocationFence.invalidate(connectionID: connectionID)
            synchronizationTasks.removeValue(forKey: connectionID)?.cancel()
            synchronizationTokens.removeValue(forKey: connectionID)
            liveConnectionIDs.remove(connectionID)
            retireAuthority(connectionID: connectionID, deviceID: deviceID)
        }
        connectedDeviceIDs.remove(deviceID)
        for (connectionID, connection) in retiringConnections {
            await streamHub?.releaseConnection(connectionID)
            await terminalControl?.releaseConnection(connectionID)
            await connection.close(reason: reason)
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
