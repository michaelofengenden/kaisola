import KaisolaCore
import Combine
import Foundation

/// Terminal-control limits the desktop enforces authoritatively
/// (the native desktop Companion host). Mirrored here only to fail fast
/// with a clear message before a doomed round-trip; keep in sync with that file.
enum CompanionTerminalLimits {
    static let maxInputBytes = 16 * 1024
}

/// Persists the one paired desktop so the app reconnects after relaunch.
@MainActor
protocol PairedDesktopPersisting {
    func load(accountScope: CompanionAccountScope) -> CompanionPairedDesktop?
    func save(_ desktop: CompanionPairedDesktop, accountScope: CompanionAccountScope)
    func clear(accountScope: CompanionAccountScope)
}

@MainActor
struct UserDefaultsPairedDesktopStore: PairedDesktopPersisting {
    private let legacyKey = "com.kaisola.companion.paired-desktop.v1"
    private let keyPrefix = "com.kaisola.companion.paired-desktop.v2."
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(accountScope: CompanionAccountScope) -> CompanionPairedDesktop? {
        // The v1 ticket had no account attribution. It must never be adopted by
        // whichever account happens to sign in first after upgrade.
        defaults.removeObject(forKey: legacyKey)
        guard let data = defaults.data(forKey: key(accountScope)),
              let desktop = try? JSONDecoder().decode(CompanionPairedDesktop.self, from: data),
              desktop.accountScope == accountScope else { return nil }
        return desktop
    }
    func save(_ desktop: CompanionPairedDesktop, accountScope: CompanionAccountScope) {
        guard desktop.accountScope == accountScope else { return }
        guard let data = try? JSONEncoder().encode(desktop) else { return }
        defaults.set(data, forKey: key(accountScope))
    }
    func clear(accountScope: CompanionAccountScope) {
        defaults.removeObject(forKey: key(accountScope))
        defaults.removeObject(forKey: legacyKey)
        // Cursors from builds that persisted them are deliberately discarded.
        // A cold launch has no matching in-memory projection to replay onto.
        defaults.removeObject(forKey: "com.kaisola.companion.replay-cursor.v1")
    }

    private func key(_ accountScope: CompanionAccountScope) -> String {
        keyPrefix + accountScope.rawValue
    }
}

/// The orchestration layer: owns the device identity, the wire client, the live
/// store, and the persisted paired desktop. It drives pairing (scan → connect →
/// handshake → SAS → paired) and reconnect (discover a known desktop → resume),
/// forwarding the client's published state into UI-facing phases.
@MainActor
final class CompanionConnectionCoordinator: ObservableObject {
    enum PairingPhase: Equatable {
        case idle
        case preparing            // loading the Keychain identity (Face ID)
        case connecting           // discovering + connecting + handshaking
        case confirm(CompanionSAS)
        case paired
        case failed(String)
    }

    @Published private(set) var pairingPhase: PairingPhase = .idle
    @Published private(set) var pairedDesktop: CompanionPairedDesktop?
    @Published private(set) var accountOffers: [CompanionAccountOffer] = []
    @Published private(set) var accountLookupInProgress = false
    @Published private(set) var controlledTerminalIds: Set<String> = []
    @Published private(set) var terminalStreamIssues: [String: String] = [:]
    @Published private(set) var activeRoute: CompanionTransportRoute = .none
    @Published private(set) var activeAccountScope: CompanionAccountScope?
    /// Drives presentation of the pairing sheet from anywhere in the app.
    @Published var wantsPairing = false

    let store: CompanionStore

    private let client: CompanionClient
    private let keychain: CompanionIdentityKeychain
    private let persistence: PairedDesktopPersisting
    private let accountRendezvous: any CompanionAccountRendezvousServing
    private let controlAuthorization: CompanionControlAuthorization
    private var identity: CompanionIdentity?
    private var pendingPayload: CompanionPairingPayload?
    private var activePairingNonce: String?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var accountLookupID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private var resumeInProgress = false
    private var connectionWanted = false
    private var lifecycleIntentVersion = 0
    /// Published so a view that captured one account epoch can dismiss instead
    /// of silently adopting a replacement account while it still retains the
    /// prior account's session or permission value.
    @Published private(set) var accountGeneration: UInt64 = 0
    struct AccountIntent: Equatable, Sendable {
        let scope: CompanionAccountScope
        let generation: UInt64
    }
    private var clientAccountAuthority: (
        session: CompanionClient.SessionAuthority,
        account: AccountIntent
    )?
    private struct TerminalLease {
        let projectId: String
        let terminalId: String
        let leaseId: String
        var expiresAt: Int64
        var renewAfterMs: Int64
        let resizeEnabled: Bool
    }
    private var terminalLeases: [String: TerminalLease] = [:]
    private var terminalRenewals: [String: Task<Void, Never>] = [:]

    var isPaired: Bool { pairedDesktop != nil }

    func configureKaisolaLink(
        baseURL: URL?,
        tokenProvider: KaisolaLinkConnection.TokenProvider?
    ) {
        client.transport.configureKaisolaLink(baseURL: baseURL, tokenProvider: tokenProvider)
    }

    init(
        client: CompanionClient = CompanionClient(transport: CompanionTransport(autoConnect: true)),
        keychain: CompanionIdentityKeychain = CompanionIdentityKeychain(),
        persistence: PairedDesktopPersisting = UserDefaultsPairedDesktopStore(),
        accountRendezvous: any CompanionAccountRendezvousServing = CompanionAccountRendezvousService(),
        controlAuthorization: CompanionControlAuthorization = CompanionControlAuthorization(),
        store: CompanionStore? = nil
    ) {
        self.client = client
        self.keychain = keychain
        self.persistence = persistence
        self.accountRendezvous = accountRendezvous
        self.controlAuthorization = controlAuthorization
        self.store = store ?? CompanionStore.live(client: client)
        self.pairedDesktop = nil
        self.activeAccountScope = nil
        observe()
    }

    // MARK: Public API

    /// Advance the local account authority epoch before any new account state
    /// is loaded. Saved pairings remain partitioned so returning to an account
    /// can restore only that account's still-valid ticket.
    func activateAccount(accountID: String?) {
        let nextScope = accountID.flatMap { try? CompanionAccountScope(accountID: $0) }
        guard nextScope != activeAccountScope else { return }

        accountGeneration &+= 1
        connectionWanted = false
        lifecycleIntentVersion &+= 1
        resumeInProgress = false
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        accountLookupID = nil
        accountLookupInProgress = false
        accountOffers.removeAll()
        wantsPairing = false
        terminalStreamIssues.removeAll()
        activeRoute = .none
        pendingPayload = nil
        activePairingNonce = nil
        clearLocalTerminalControls()
        controlAuthorization.lock()
        clientAccountAuthority = nil
        client.resetForAccountTransition()
        store.clearForAccountChange()
        activeAccountScope = nextScope
        pairedDesktop = nextScope.flatMap { persistence.load(accountScope: $0) }
        pairingPhase = .idle
    }

    /// Begin pairing from a scanned/pasted QR payload.
    func pair(with payload: CompanionPairingPayload) async {
        await pair(with: payload, intent: captureActiveAccountIntent())
    }

    func pair(with payload: CompanionPairingPayload, intent: AccountIntent?) async {
        guard let authority = activeAccountAuthority(matching: intent) else { return }
        let accountScope = authority.scope
        guard payload.accountScope == accountScope else {
            pairingPhase = .failed("This pairing code belongs to another Kaisola account.")
            return
        }
        let generation = authority.generation
        do { try payload.validate() } catch {
            pairingPhase = .failed("This pairing code is invalid or expired.")
            return
        }
        pairingPhase = .preparing
        accountOffers = []
        accountLookupID = nil
        accountLookupInProgress = false
        do {
            let identity = try await resolveIdentity()
            guard generation == accountGeneration,
                  activeAccountScope == accountScope else { return }
            self.pendingPayload = payload
            connectionWanted = true
            lifecycleIntentVersion &+= 1
            activePairingNonce = payload.pairingNonce
            pairingPhase = .connecting
            armPairingTimeout(for: payload)
            client.transport.startDiscovery(
                preferred: payload.transportHint,
                desktopId: payload.desktopId,
                deviceId: identity.id,
                force: true
            )
        } catch {
            guard generation == accountGeneration,
                  activeAccountScope == accountScope else { return }
            pairingPhase = .failed(Self.identityMessage(error))
        }
    }

    /// Open the pairing sheet fresh.
    func presentPairing() {
        pairingPhase = .idle
        accountOffers = []
        wantsPairing = true
    }

    /// Find a short-lived offer published by a signed-in Mac. The account is
    /// rendezvous only: the connection still uses the signed pairing payload,
    /// local transport, Noise handshake, and four-word verification.
    func findAccountMac(idToken: String) async {
        await findAccountMac(idToken: idToken, intent: captureActiveAccountIntent())
    }

    func findAccountMac(idToken: String, intent: AccountIntent?) async {
        guard let authority = activeAccountAuthority(matching: intent) else {
            pairingPhase = .failed("Sign in before pairing a Mac.")
            return
        }
        let accountScope = authority.scope
        let generation = authority.generation
        let lookupID = UUID()
        accountLookupID = lookupID
        accountLookupInProgress = true
        accountOffers = []
        defer {
            if accountLookupID == lookupID {
                accountLookupInProgress = false
                accountLookupID = nil
            }
        }
        do {
            var offers: [CompanionAccountOffer] = []
            for attempt in 0..<4 {
                guard accountLookupID == lookupID,
                      accountGeneration == generation,
                      activeAccountScope == accountScope else { return }
                offers = try await accountRendezvous.listOffers(idToken: idToken)
                guard offers.allSatisfy({ offer in
                    offer.payload.accountScope == accountScope
                        && (try? offer.payload.validate()) != nil
                }) else {
                    throw CompanionCryptoError.identityMismatch
                }
                if !offers.isEmpty { break }
                if attempt < 3 { try await Task.sleep(for: .milliseconds(650)) }
            }
            guard accountLookupID == lookupID,
                  accountGeneration == generation,
                  activeAccountScope == accountScope else { return }
            if offers.count == 1, let offer = offers.first {
                await pair(with: offer.payload, intent: authority)
            } else if offers.isEmpty {
                pairingPhase = .failed("No Mac is waiting to pair. On your Mac, open Settings → Companion and choose Pair a device.")
            } else {
                accountOffers = offers
                pairingPhase = .idle
            }
        } catch is CancellationError {
            return
        } catch {
            guard accountLookupID == lookupID,
                  accountGeneration == generation,
                  activeAccountScope == accountScope else { return }
            pairingPhase = .failed(
                (error as? LocalizedError)?.errorDescription ?? "Account pairing is temporarily unavailable."
            )
        }
    }

    func pair(with offer: CompanionAccountOffer) async {
        await pair(with: offer.payload)
    }

    func pair(with offer: CompanionAccountOffer, intent: AccountIntent?) async {
        await pair(with: offer.payload, intent: intent)
    }

    func reportAccountPairingError(_ error: Error, intent: AccountIntent?) {
        guard activeAccountAuthority(matching: intent) != nil else { return }
        pairingPhase = .failed(
            (error as? LocalizedError)?.errorDescription ?? "Kaisola couldn't refresh your sign-in. Try again."
        )
    }

    /// A scanned/pasted string that wasn't a valid pairing code.
    func reportInvalidCode(intent: AccountIntent?) {
        guard activeAccountAuthority(matching: intent) != nil else { return }
        pairingPhase = .failed("That isn't a Kaisola pairing code. Try scanning again.")
    }

    /// The four words matched on both screens — complete the handshake.
    func confirmSAS(intent: AccountIntent?) {
        guard activeAccountAuthority(matching: intent) != nil else { return }
        do { try client.confirmSAS() } catch { fail(error) }
    }

    /// Abandon an in-flight pairing.
    func cancelPairing(intent: AccountIntent?) {
        guard activeAccountAuthority(matching: intent) != nil else { return }
        pendingPayload = nil
        activePairingNonce = nil
        accountLookupID = nil
        accountLookupInProgress = false
        accountOffers = []
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingPhase = .idle
        if !isPaired {
            connectionWanted = false
            lifecycleIntentVersion &+= 1
            clientAccountAuthority = nil
            client.resetForAccountTransition()
        }
    }

    /// On launch (or when returning to foreground) reconnect to the known Mac.
    func connectIfPaired(force: Bool = false) async {
        guard let accountScope = activeAccountScope,
              let desktop = pairedDesktop,
              desktop.accountScope == accountScope else { return }
        let generation = accountGeneration
        connectionWanted = true
        lifecycleIntentVersion &+= 1
        if !force {
            switch client.transport.state {
            case .discovering, .reconnecting:
                client.transport.nudgeReconnect()
                return
            case .connecting, .handshaking, .live:
                return
            case .idle, .reconnectRequired:
                break
            }
        }
        guard !resumeInProgress else { return }
        resumeInProgress = true
        defer {
            if accountGeneration == generation { resumeInProgress = false }
        }
        store.connection = .reconnecting
        do {
            let identity = try await resolveIdentity()
            guard connectionWanted,
                  accountGeneration == generation,
                  activeAccountScope == accountScope,
                  pairedDesktop == desktop else { return }
            // Resume deltas only when this process still holds the projection
            // that cursor acknowledges. A cold launch sends no cursor and gets
            // a coherent snapshot instead of a green-but-empty board.
            try client.configureResume(
                desktop: desktop,
                identity: identity,
                cursor: store.lastAckCursor,
                accountScope: accountScope
            )
            guard let sessionAuthority = client.currentSessionAuthority else {
                throw CompanionCryptoError.handshakeOrder
            }
            guard adoptConfiguredClientAuthority(
                sessionAuthority,
                account: AccountIntent(scope: accountScope, generation: generation)
            ) else { throw CompanionCryptoError.identityMismatch }
            client.transport.startDiscovery(
                preferred: desktop.transportHint,
                desktopId: desktop.desktopId,
                deviceId: identity.id,
                // A spent automatic retry budget is a completed resume
                // episode. Foreground activation or the explicit reconnect
                // button begins a fresh bounded episode without re-pairing.
                force: force || client.transport.state == .reconnectRequired
            )
        } catch {
            guard accountGeneration == generation,
                  activeAccountScope == accountScope,
                  pairedDesktop == desktop else { return }
            store.connection = store.projects.isEmpty ? .offline : .stale
        }
    }

    /// User-visible recovery is always available, while ordinary lifecycle
    /// calls remain idempotent and cannot cancel an in-flight secure resume.
    func reconnect() async {
        await connectIfPaired(force: true)
    }

    /// Start/stop the live byte stream for a terminal session being viewed.
    func setTerminalStream(
        projectId: String,
        sessionId: String,
        subscribed: Bool,
        force: Bool = false,
        intent: AccountIntent?
    ) {
        guard !store.isPreview else { return }
        guard accountAuthority(matching: intent) != nil else { return }
        terminalStreamIssues.removeValue(forKey: sessionId)
        try? client.setStreamSubscription(
            projectId: projectId,
            sessionId: sessionId,
            subscribed: subscribed,
            force: force
        )
    }

    func sendAgentMessage(
        to session: CompanionSession,
        text: String,
        intent: AccountIntent?
    ) async -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if store.isPreview {
            store.sendPreviewPrompt(to: session.id, text: clean)
            return true
        }
        guard let authority = accountAuthority(matching: intent) else { return false }
        guard store.canControlAgents else {
            store.showActionMessage("Agent control is not enabled for this iPhone. Grant it from the Mac.")
            return false
        }
        do {
            try await authorizeControl(reason: "Send a message to \(session.title) on your Mac")
            guard isCurrent(authority) else { return false }
            let type = session.status == .running ? "agent.steer" : "agent.prompt"
            let receipt = try await client.performCommand(
                type: type,
                projectId: session.projectId,
                targetId: session.id,
                capability: .agentControl,
                payload: ["text": .string(clean)]
            )
            guard isCurrent(authority) else { return false }
            guard receiptAccepted(receipt) else {
                store.showActionMessage(receipt.message ?? "The Mac rejected this message.")
                return false
            }
            store.appendUserTurn(to: session.id, text: clean)
            return true
        } catch {
            guard isCurrent(authority) else { return false }
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func cancelAgent(_ session: CompanionSession, intent: AccountIntent?) async -> Bool {
        guard !store.isPreview else {
            store.showActionMessage("Preview only: stop requested")
            return true
        }
        guard let authority = accountAuthority(matching: intent) else { return false }
        guard store.canControlAgents else { return false }
        do {
            try await authorizeControl(reason: "Stop \(session.title) on your Mac")
            guard isCurrent(authority) else { return false }
            let receipt = try await client.performCommand(
                type: "agent.cancel",
                projectId: session.projectId,
                targetId: session.id,
                capability: .agentControl
            )
            guard isCurrent(authority) else { return false }
            if !receiptAccepted(receipt) { store.showActionMessage(receipt.message ?? "The agent was not stopped.") }
            return receiptAccepted(receipt)
        } catch {
            guard isCurrent(authority) else { return false }
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func respond(
        to permission: CompanionPermission,
        option: CompanionPermissionOption,
        intent: AccountIntent?
    ) async -> Bool {
        if store.isPreview {
            store.resolvePermission(permission.id, decision: option.id.lowercased().contains("reject") ? "reject" : "allow")
            return true
        }
        guard let authority = accountAuthority(matching: intent) else { return false }
        guard store.canControlAgents,
              let targetId = permission.sessionId,
              let revision = permission.revision,
              (permission.completeness ?? "complete") == "complete" else {
            store.showActionMessage("Review this permission on the Mac for complete context.")
            return false
        }
        do {
            try await authorizeControl(reason: "Respond to \(permission.agent) on your Mac")
            guard isCurrent(authority) else { return false }
            let decision = option.id.lowercased().contains("reject") || option.label.lowercased().contains("reject")
                ? "reject" : "allow_once"
            let receipt = try await client.performCommand(
                type: "permission.respond",
                projectId: permission.projectId,
                targetId: targetId,
                capability: .agentControl,
                expectedRevision: revision,
                payload: [
                    "permId": .string(permission.permId),
                    "optionId": .string(option.id),
                    "decision": .string(decision),
                ]
            )
            guard isCurrent(authority) else { return false }
            if !receiptAccepted(receipt) { store.showActionMessage(receipt.message ?? "The permission decision was not applied.") }
            return receiptAccepted(receipt)
        } catch {
            guard isCurrent(authority) else { return false }
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func hasTerminalControl(_ session: CompanionSession, intent: AccountIntent?) -> Bool {
        if store.isPreview { return controlledTerminalIds.contains(session.id) }
        guard accountAuthority(matching: intent) != nil else { return false }
        return controlledTerminalIds.contains(session.id) && terminalLeases[terminalKey(session)] != nil
    }

    func acquireTerminalControl(
        _ session: CompanionSession,
        intent: AccountIntent?
    ) async -> Bool {
        if store.isPreview {
            controlledTerminalIds.insert(session.id)
            return true
        }
        guard let authority = accountAuthority(matching: intent) else { return false }
        guard store.canControlTerminals else {
            store.showActionMessage("Terminal control is not enabled for this iPhone. Grant it from the Mac.")
            return false
        }
        do {
            try await authorizeControl(reason: "Control \(session.title) on your Mac")
            guard isCurrent(authority) else { return false }
            let receipt = try await client.performCommand(
                type: "terminal.acquire-control",
                projectId: session.projectId,
                targetId: session.id,
                capability: .terminalControl
            )
            guard isCurrent(authority) else { return false }
            guard receiptAccepted(receipt), let lease = lease(from: receipt, session: session) else {
                store.showActionMessage(receipt.message ?? "Terminal control was not granted.")
                return false
            }
            remember(lease, authority: authority)
            return true
        } catch {
            guard isCurrent(authority) else { return false }
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func releaseTerminalControl(_ session: CompanionSession, intent: AccountIntent?) async {
        if !store.isPreview, accountAuthority(matching: intent) == nil { return }
        let key = terminalKey(session)
        guard let lease = terminalLeases[key] else {
            controlledTerminalIds.remove(session.id)
            return
        }
        terminalRenewals.removeValue(forKey: key)?.cancel()
        terminalLeases.removeValue(forKey: key)
        controlledTerminalIds.remove(session.id)
        guard !store.isPreview, client.transport.state == .live else { return }
        _ = try? await client.performCommand(
            type: "terminal.release-control",
            projectId: lease.projectId,
            targetId: lease.terminalId,
            capability: .terminalControl,
            payload: ["leaseId": .string(lease.leaseId)],
            timeout: .seconds(5)
        )
    }

    func sendTerminalInput(
        _ data: Data,
        to session: CompanionSession,
        intent: AccountIntent?
    ) async -> Bool {
        if store.isPreview {
            guard !data.isEmpty, data.count <= CompanionTerminalLimits.maxInputBytes else {
                store.showActionMessage("Terminal input is too large. Paste 16 KB or less.")
                return false
            }
            store.showActionMessage("Preview only: terminal input captured")
            return true
        }
        guard let authority = accountAuthority(matching: intent) else { return false }
        guard !data.isEmpty, data.count <= CompanionTerminalLimits.maxInputBytes else {
            store.showActionMessage("Terminal input is too large. Paste 16 KB or less.")
            return false
        }
        guard let lease = terminalLeases[terminalKey(session)] else { return false }
        do {
            let receipt = try await client.performCommand(
                type: "terminal.write",
                projectId: session.projectId,
                targetId: session.id,
                capability: .terminalControl,
                payload: [
                    "leaseId": .string(lease.leaseId),
                    "data": .string(String(decoding: data, as: UTF8.self)),
                ]
            )
            guard isCurrent(authority) else { return false }
            if !receiptAccepted(receipt) {
                dropTerminalLease(for: session)
                store.showActionMessage(receipt.message ?? "Terminal input was not applied.")
            }
            return receiptAccepted(receipt)
        } catch {
            guard isCurrent(authority) else { return false }
            dropTerminalLease(for: session)
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func resizeTerminal(
        _ session: CompanionSession,
        cols: Int,
        rows: Int,
        intent: AccountIntent?
    ) async {
        guard !store.isPreview,
              accountAuthority(matching: intent) != nil,
              let lease = terminalLeases[terminalKey(session)],
              lease.resizeEnabled else { return }
        _ = try? await client.performCommand(
            type: "terminal.resize",
            projectId: session.projectId,
            targetId: session.id,
            capability: .terminalControl,
            payload: [
                "leaseId": .string(lease.leaseId),
                "cols": .integer(Int64(cols)),
                "rows": .integer(Int64(rows)),
            ],
            timeout: .seconds(5)
        )
    }

    func interruptTerminal(
        _ session: CompanionSession,
        intent: AccountIntent?
    ) async -> Bool {
        if store.isPreview { return true }
        guard let authority = accountAuthority(matching: intent) else { return false }
        guard let lease = terminalLeases[terminalKey(session)] else { return false }
        do {
            let receipt = try await client.performCommand(
                type: "terminal.interrupt",
                projectId: session.projectId,
                targetId: session.id,
                capability: .terminalControl,
                payload: ["leaseId": .string(lease.leaseId)]
            )
            guard isCurrent(authority) else { return false }
            return receiptAccepted(receipt)
        } catch {
            guard isCurrent(authority) else { return false }
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    /// Called before iOS snapshots/backgrounds the UI. Leases are best-effort
    /// released, then local authorization and the socket are dropped.
    func suspend() async {
        connectionWanted = false
        lifecycleIntentVersion &+= 1
        let intent = lifecycleIntentVersion
        let accountIntent = captureAccountIntent()
        let sessions = terminalLeases.values.compactMap { lease in store.session(for: lease.terminalId) }
        for session in sessions { await releaseTerminalControl(session, intent: accountIntent) }
        clearLocalTerminalControls()
        controlAuthorization.lock()
        guard !store.isPreview else { return }
        // If the app became active while lease cleanup was awaiting the Mac,
        // the newer foreground intent owns the socket. Do not stop it here.
        guard !connectionWanted, lifecycleIntentVersion == intent else { return }
        client.transport.stop()
        store.connection = store.projects.isEmpty ? .offline : .stale
    }

    /// Forget the paired Mac and drop the connection.
    func unpair() {
        connectionWanted = false
        lifecycleIntentVersion &+= 1
        clearLocalTerminalControls()
        controlAuthorization.lock()
        if let activeAccountScope {
            persistence.clear(accountScope: activeAccountScope)
        }
        pairedDesktop = nil
        pendingPayload = nil
        activePairingNonce = nil
        accountLookupID = nil
        accountLookupInProgress = false
        accountOffers = []
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingPhase = .idle
        clientAccountAuthority = nil
        client.resetForAccountTransition()
    }

    // MARK: Wiring

    private func observe() {
        client.onRevoked = { [weak self] authority, message in
            guard let self, self.isCurrentClientAuthority(authority) else { return }
            self.clientAccountAuthority = nil
            self.handleDeviceRevocation(message: message)
        }
        client.onPairedDesktop = { [weak self] authority, desktop in
            guard let self, self.isCurrentClientAuthority(authority) else { return }
            self.handlePaired(desktop)
        }
        client.onStreamIssue = { [weak self] authority, sessionId, message in
            guard let self, self.isCurrentClientAuthority(authority) else { return }
            if let message { self.terminalStreamIssues[sessionId] = message }
            else { self.terminalStreamIssues.removeValue(forKey: sessionId) }
        }
        client.transport.$state
            .receive(on: RunLoop.main)
            .sink { [weak self, weak client] state in
                guard let self, client?.transport.state == state else { return }
                self.handleTransportState(state)
            }
            .store(in: &cancellables)
        client.transport.$route
            .receive(on: RunLoop.main)
            .sink { [weak self, weak client] route in
                guard client?.transport.route == route else { return }
                self?.activeRoute = route
            }
            .store(in: &cancellables)
        client.$sas
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self, weak client] sas in
                guard let self, client?.sas == sas,
                      case .connecting = self.pairingPhase else { return }
                self.pairingTimeoutTask?.cancel()
                self.pairingTimeoutTask = nil
                self.pairingPhase = .confirm(sas)
                #if DEBUG
                // Automated pairing harness: confirm the SAS without a tap.
                if ProcessInfo.processInfo.environment["KAISOLA_AUTOSAS"] == "1" {
                    self.confirmSAS(intent: self.captureActiveAccountIntent())
                }
                #endif
            }
            .store(in: &cancellables)
        client.$lastError
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self, weak client] message in
                guard let self, client?.lastError == message,
                      case .idle = self.pairingPhase else {
                    self?.failIfPairing(message)
                    return
                }
            }
            .store(in: &cancellables)
    }

    private func handleTransportState(_ state: CompanionTransportState) {
        if state != .live { clearLocalTerminalControls() }
        // Pairing: the phone must start the handshake once the socket is up.
        if state == .handshaking, let payload = pendingPayload, let identity {
            pendingPayload = nil
            guard let accountAuthority = activeAccountAuthority(),
                  let accountScope = activeAccountScope,
                  accountAuthority.scope == accountScope,
                  payload.accountScope == accountScope else {
                pairingPhase = .failed("This pairing code belongs to another Kaisola account.")
                client.resetForAccountTransition()
                return
            }
            do {
                try client.beginPairing(
                    payload: payload,
                    identity: identity,
                    accountScope: accountScope
                )
                guard let sessionAuthority = client.currentSessionAuthority else {
                    throw CompanionCryptoError.handshakeOrder
                }
                guard adoptConfiguredClientAuthority(
                    sessionAuthority,
                    account: accountAuthority
                ) else { throw CompanionCryptoError.identityMismatch }
            }
            catch { fail(error) }
        }
    }

    private func handlePaired(_ desktop: CompanionPairedDesktop) {
        guard let accountScope = activeAccountScope,
              desktop.accountScope == accountScope else { return }
        let previous = Set(pairedDesktop?.capabilities ?? [])
        let current = Set(desktop.capabilities)
        if previous.contains(.terminalControl), !current.contains(.terminalControl) {
            clearLocalTerminalControls()
        }
        if !previous.subtracting(current).intersection([.agentControl, .terminalControl]).isEmpty {
            controlAuthorization.lock()
        }
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        activePairingNonce = nil
        persistence.save(desktop, accountScope: accountScope)
        pairedDesktop = desktop
        connectionWanted = true
        pairingPhase = .paired
    }

    func handleDeviceRevocation(message: String) {
        connectionWanted = false
        lifecycleIntentVersion &+= 1
        clearLocalTerminalControls()
        controlAuthorization.lock()
        if let activeAccountScope {
            persistence.clear(accountScope: activeAccountScope)
        }
        pairedDesktop = nil
        pendingPayload = nil
        activePairingNonce = nil
        accountLookupID = nil
        accountLookupInProgress = false
        accountOffers.removeAll()
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        terminalStreamIssues.removeAll()
        pairingPhase = .failed(message)
        store.clearAfterRevocation(message: message)
    }

    private func authorizeControl(reason: String) async throws {
        if store.isPreview { return }
        try await controlAuthorization.authorize(reason: reason)
    }

    private func receiptAccepted(_ receipt: CompanionReceiptBody) -> Bool {
        receipt.status == .accepted || receipt.status == .applied
    }

    private func actionMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "The action could not be confirmed. It was not retried."
    }

    private func terminalKey(_ session: CompanionSession) -> String {
        "\(session.projectId)\u{0}\(session.id)"
    }

    private func lease(from receipt: CompanionReceiptBody, session: CompanionSession) -> TerminalLease? {
        guard let leaseId = receipt.payload?["leaseId"]?.stringValue,
              let expiresAt = receipt.payload?["expiresAt"]?.intValue else { return nil }
        return TerminalLease(
            projectId: session.projectId,
            terminalId: session.id,
            leaseId: leaseId,
            expiresAt: expiresAt,
            renewAfterMs: receipt.payload?["renewAfterMs"]?.intValue ?? 10_000,
            resizeEnabled: receipt.payload?["resizeEnabled"]?.boolValue == true
        )
    }

    private func remember(_ lease: TerminalLease, authority: AccountIntent) {
        let key = "\(lease.projectId)\u{0}\(lease.terminalId)"
        terminalLeases[key] = lease
        controlledTerminalIds.insert(lease.terminalId)
        terminalRenewals.removeValue(forKey: key)?.cancel()
        terminalRenewals[key] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = max(3_000, min(lease.renewAfterMs, 12_000))
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, let current = self.terminalLeases[key] else { return }
                guard self.isCurrent(authority) else { return }
                do {
                    let receipt = try await self.client.performCommand(
                        type: "terminal.renew-control",
                        projectId: current.projectId,
                        targetId: current.terminalId,
                        capability: .terminalControl,
                        payload: ["leaseId": .string(current.leaseId)],
                        timeout: .seconds(5)
                    )
                    guard self.isCurrent(authority) else { return }
                    guard self.receiptAccepted(receipt),
                          let session = self.store.session(for: current.terminalId),
                          let renewed = self.lease(from: receipt, session: session) else {
                        self.dropTerminalLease(key: key, terminalId: current.terminalId)
                        return
                    }
                    // The user (or a background release) may have dropped this
                    // lease while the renew round-trip was in flight. Re-check
                    // before re-inserting so an accepted renewal cannot resurrect
                    // a lease that was already released.
                    guard !Task.isCancelled, self.terminalLeases[key] != nil else { return }
                    self.terminalLeases[key] = renewed
                } catch {
                    guard self.isCurrent(authority) else { return }
                    self.dropTerminalLease(key: key, terminalId: current.terminalId)
                    return
                }
            }
        }
    }

    private func dropTerminalLease(for session: CompanionSession) {
        dropTerminalLease(key: terminalKey(session), terminalId: session.id)
    }

    private func dropTerminalLease(key: String, terminalId: String) {
        terminalRenewals.removeValue(forKey: key)?.cancel()
        terminalLeases.removeValue(forKey: key)
        controlledTerminalIds.remove(terminalId)
    }

    private func clearLocalTerminalControls() {
        for task in terminalRenewals.values { task.cancel() }
        terminalRenewals.removeAll()
        terminalLeases.removeAll()
        controlledTerminalIds.removeAll()
    }

    func captureAccountIntent() -> AccountIntent? {
        accountAuthority()
    }

    func captureActiveAccountIntent() -> AccountIntent? {
        activeAccountAuthority()
    }

    private func activeAccountAuthority() -> AccountIntent? {
        guard let scope = activeAccountScope else { return nil }
        return AccountIntent(scope: scope, generation: accountGeneration)
    }

    private func activeAccountAuthority(matching intent: AccountIntent?) -> AccountIntent? {
        guard let intent, isCurrentAccount(intent) else { return nil }
        return intent
    }

    private func accountAuthority() -> AccountIntent? {
        guard let authority = activeAccountAuthority(),
              pairedDesktop?.accountScope == authority.scope else { return nil }
        return authority
    }

    private func accountAuthority(matching intent: AccountIntent?) -> AccountIntent? {
        guard let intent, isCurrent(intent) else { return nil }
        return intent
    }

    private func isCurrent(_ authority: AccountIntent) -> Bool {
        isCurrentAccount(authority)
            && pairedDesktop?.accountScope == authority.scope
    }

    private func isCurrentAccount(_ authority: AccountIntent) -> Bool {
        accountGeneration == authority.generation
            && activeAccountScope == authority.scope
    }

    private func isCurrentClientAuthority(
        _ authority: CompanionClient.SessionAuthority
    ) -> Bool {
        guard let binding = clientAccountAuthority else { return false }
        return binding.session == authority && isCurrentAccount(binding.account)
    }

    /// Bind callbacks only after the client has been configured from the exact
    /// account intent that initiated pairing/resume. Internal visibility also
    /// lets protocol tests exercise delayed old-authority callbacks directly.
    @discardableResult
    func adoptConfiguredClientAuthority(
        _ authority: CompanionClient.SessionAuthority,
        account: AccountIntent? = nil
    ) -> Bool {
        guard client.currentSessionAuthority == authority,
              let account = account ?? activeAccountAuthority(),
              isCurrentAccount(account),
              authority.accountScope == account.scope else { return false }
        clientAccountAuthority = (session: authority, account: account)
        return true
    }

    private func resolveIdentity() async throws -> CompanionIdentity {
        if let identity { return identity }
        let identity = try await keychain.loadOrCreateDeviceIdentity(
            displayName: Self.deviceDisplayName(),
            reason: "Unlock Kaisola to pair with your Mac"
        )
        self.identity = identity
        return identity
    }

    private func fail(_ error: Error) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        activePairingNonce = nil
        pairingPhase = .failed(Self.pairingMessage(error))
    }

    private func failIfPairing(_ message: String) {
        switch pairingPhase {
        case .connecting, .preparing, .confirm:
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            activePairingNonce = nil
            pairingPhase = .failed("The secure handshake didn't complete. Start a fresh code on your Mac and try again.")
        default:
            break
        }
    }

    private static func deviceDisplayName() -> String {
        #if canImport(UIKit)
        return "iPhone"
        #else
        return "Kaisola Device"
        #endif
    }

    private static func identityMessage(_ error: Error) -> String {
        if error is CancellationError { return "Sign-in was cancelled." }
        return "Couldn't unlock this device's secure identity. Try again."
    }

    private static func pairingMessage(_ error: Error) -> String {
        if error is CancellationError { return "Pairing was cancelled." }
        return "The secure handshake didn't complete. Start a fresh code on your Mac and try again."
    }

    private func armPairingTimeout(for payload: CompanionPairingPayload) {
        pairingTimeoutTask?.cancel()
        let now = Int64(Date.now.timeIntervalSince1970 * 1_000)
        let remaining = max(1_000, min(payload.expiresAt - now, 45_000))
        pairingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(remaining))
            guard !Task.isCancelled,
                  let self,
                  case .connecting = self.pairingPhase,
                  self.activePairingNonce == payload.pairingNonce else { return }
            self.activePairingNonce = nil
            self.client.transport.stop()
            self.pairingPhase = .failed(
                "Couldn't reach this Mac. Keep Kaisola Companion on and make sure the Mac is online, then try again."
            )
        }
    }
}
