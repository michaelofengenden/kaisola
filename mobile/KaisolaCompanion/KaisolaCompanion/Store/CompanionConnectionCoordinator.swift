import Combine
import Foundation

/// Persists the one paired desktop so the app reconnects after relaunch.
@MainActor
protocol PairedDesktopPersisting {
    func load() -> CompanionPairedDesktop?
    func save(_ desktop: CompanionPairedDesktop)
    func clear()
}

@MainActor
struct UserDefaultsPairedDesktopStore: PairedDesktopPersisting {
    private let key = "com.kaisola.companion.paired-desktop.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> CompanionPairedDesktop? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CompanionPairedDesktop.self, from: data)
    }
    func save(_ desktop: CompanionPairedDesktop) {
        guard let data = try? JSONEncoder().encode(desktop) else { return }
        defaults.set(data, forKey: key)
    }
    func clear() {
        defaults.removeObject(forKey: key)
        // Cursors from builds that persisted them are deliberately discarded.
        // A cold launch has no matching in-memory projection to replay onto.
        defaults.removeObject(forKey: "com.kaisola.companion.replay-cursor.v1")
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
        self.pairedDesktop = persistence.load()
        observe()
    }

    // MARK: Public API

    /// Begin pairing from a scanned/pasted QR payload.
    func pair(with payload: CompanionPairingPayload) async {
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
            self.pendingPayload = payload
            connectionWanted = true
            lifecycleIntentVersion &+= 1
            activePairingNonce = payload.pairingNonce
            pairingPhase = .connecting
            armPairingTimeout(for: payload)
            client.transport.startDiscovery(
                preferred: payload.transportHint,
                desktopId: payload.desktopId,
                force: true
            )
            _ = identity
        } catch {
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
                guard accountLookupID == lookupID else { return }
                offers = try await accountRendezvous.listOffers(idToken: idToken)
                if !offers.isEmpty { break }
                if attempt < 3 { try await Task.sleep(for: .milliseconds(650)) }
            }
            guard accountLookupID == lookupID else { return }
            if offers.count == 1, let offer = offers.first {
                await pair(with: offer.payload)
            } else if offers.isEmpty {
                pairingPhase = .failed("No Mac is waiting to pair. On your Mac, open Settings → Companion and choose Pair a device.")
            } else {
                accountOffers = offers
                pairingPhase = .idle
            }
        } catch is CancellationError {
            return
        } catch {
            guard accountLookupID == lookupID else { return }
            pairingPhase = .failed(
                (error as? LocalizedError)?.errorDescription ?? "Account pairing is temporarily unavailable."
            )
        }
    }

    func pair(with offer: CompanionAccountOffer) async {
        await pair(with: offer.payload)
    }

    func reportAccountPairingError(_ error: Error) {
        pairingPhase = .failed(
            (error as? LocalizedError)?.errorDescription ?? "Kaisola couldn't refresh your sign-in. Try again."
        )
    }

    /// A scanned/pasted string that wasn't a valid pairing code.
    func reportInvalidCode() {
        pairingPhase = .failed("That isn't a Kaisola pairing code. Try scanning again.")
    }

    /// The four words matched on both screens — complete the handshake.
    func confirmSAS() {
        do { try client.confirmSAS() } catch { fail(error) }
    }

    /// Abandon an in-flight pairing.
    func cancelPairing() {
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
            client.transport.stop()
        }
    }

    /// On launch (or when returning to foreground) reconnect to the known Mac.
    func connectIfPaired(force: Bool = false) async {
        guard let desktop = pairedDesktop else { return }
        connectionWanted = true
        lifecycleIntentVersion &+= 1
        if !force {
            switch client.transport.state {
            case .discovering, .connecting, .handshaking, .live, .reconnecting:
                return
            case .idle:
                break
            }
        }
        guard !resumeInProgress else { return }
        resumeInProgress = true
        defer { resumeInProgress = false }
        store.connection = .reconnecting
        do {
            let identity = try await resolveIdentity()
            guard connectionWanted else { return }
            // Resume deltas only when this process still holds the projection
            // that cursor acknowledges. A cold launch sends no cursor and gets
            // a coherent snapshot instead of a green-but-empty board.
            try client.configureResume(desktop: desktop, identity: identity, cursor: store.lastAckCursor)
            client.transport.startDiscovery(
                preferred: desktop.transportHint,
                desktopId: desktop.desktopId,
                force: force
            )
        } catch {
            store.connection = store.projects.isEmpty ? .offline : .stale
        }
    }

    /// User-visible recovery is always available, while ordinary lifecycle
    /// calls remain idempotent and cannot cancel an in-flight secure resume.
    func reconnect() async {
        await connectIfPaired(force: true)
    }

    /// Start/stop the live byte stream for a terminal session being viewed.
    func setTerminalStream(projectId: String, sessionId: String, subscribed: Bool, force: Bool = false) {
        guard !store.isPreview else { return }
        terminalStreamIssues.removeValue(forKey: sessionId)
        try? client.setStreamSubscription(
            projectId: projectId,
            sessionId: sessionId,
            subscribed: subscribed,
            force: force
        )
    }

    func sendAgentMessage(to session: CompanionSession, text: String) async -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if store.isPreview {
            store.sendPreviewPrompt(to: session.id, text: clean)
            return true
        }
        guard store.canControlAgents else {
            store.showActionMessage("Agent control is not enabled for this iPhone. Grant it from the Mac.")
            return false
        }
        do {
            try await authorizeControl(reason: "Send a message to \(session.title) on your Mac")
            let type = session.status == .running ? "agent.steer" : "agent.prompt"
            let receipt = try await client.performCommand(
                type: type,
                projectId: session.projectId,
                targetId: session.id,
                capability: .agentControl,
                payload: ["text": .string(clean)]
            )
            guard receiptAccepted(receipt) else {
                store.showActionMessage(receipt.message ?? "The Mac rejected this message.")
                return false
            }
            store.appendUserTurn(to: session.id, text: clean)
            return true
        } catch {
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func cancelAgent(_ session: CompanionSession) async -> Bool {
        guard !store.isPreview else {
            store.showActionMessage("Preview only: stop requested")
            return true
        }
        guard store.canControlAgents else { return false }
        do {
            try await authorizeControl(reason: "Stop \(session.title) on your Mac")
            let receipt = try await client.performCommand(
                type: "agent.cancel",
                projectId: session.projectId,
                targetId: session.id,
                capability: .agentControl
            )
            if !receiptAccepted(receipt) { store.showActionMessage(receipt.message ?? "The agent was not stopped.") }
            return receiptAccepted(receipt)
        } catch {
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func respond(to permission: CompanionPermission, option: CompanionPermissionOption) async -> Bool {
        if store.isPreview {
            store.resolvePermission(permission.id, decision: option.id.lowercased().contains("reject") ? "reject" : "allow")
            return true
        }
        guard store.canControlAgents,
              let targetId = permission.sessionId,
              let revision = permission.revision,
              (permission.completeness ?? "complete") == "complete" else {
            store.showActionMessage("Review this permission on the Mac for complete context.")
            return false
        }
        do {
            try await authorizeControl(reason: "Respond to \(permission.agent) on your Mac")
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
            if !receiptAccepted(receipt) { store.showActionMessage(receipt.message ?? "The permission decision was not applied.") }
            return receiptAccepted(receipt)
        } catch {
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func hasTerminalControl(_ session: CompanionSession) -> Bool {
        if store.isPreview { return controlledTerminalIds.contains(session.id) }
        return controlledTerminalIds.contains(session.id) && terminalLeases[terminalKey(session)] != nil
    }

    func acquireTerminalControl(_ session: CompanionSession) async -> Bool {
        if store.isPreview {
            controlledTerminalIds.insert(session.id)
            return true
        }
        guard store.canControlTerminals else {
            store.showActionMessage("Terminal control is not enabled for this iPhone. Grant it from the Mac.")
            return false
        }
        do {
            try await authorizeControl(reason: "Control \(session.title) on your Mac")
            let receipt = try await client.performCommand(
                type: "terminal.acquire-control",
                projectId: session.projectId,
                targetId: session.id,
                capability: .terminalControl
            )
            guard receiptAccepted(receipt), let lease = lease(from: receipt, session: session) else {
                store.showActionMessage(receipt.message ?? "Terminal control was not granted.")
                return false
            }
            remember(lease)
            return true
        } catch {
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func releaseTerminalControl(_ session: CompanionSession) async {
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

    func sendTerminalInput(_ data: Data, to session: CompanionSession) async -> Bool {
        guard !data.isEmpty, data.count <= 16 * 1024 else {
            store.showActionMessage("Terminal input is too large. Paste 16 KB or less.")
            return false
        }
        if store.isPreview {
            store.showActionMessage("Preview only: terminal input captured")
            return true
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
            if !receiptAccepted(receipt) {
                dropTerminalLease(for: session)
                store.showActionMessage(receipt.message ?? "Terminal input was not applied.")
            }
            return receiptAccepted(receipt)
        } catch {
            dropTerminalLease(for: session)
            store.showActionMessage(actionMessage(error))
            return false
        }
    }

    func resizeTerminal(_ session: CompanionSession, cols: Int, rows: Int) async {
        guard !store.isPreview,
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

    func interruptTerminal(_ session: CompanionSession) async -> Bool {
        if store.isPreview { return true }
        guard let lease = terminalLeases[terminalKey(session)] else { return false }
        do {
            let receipt = try await client.performCommand(
                type: "terminal.interrupt",
                projectId: session.projectId,
                targetId: session.id,
                capability: .terminalControl,
                payload: ["leaseId": .string(lease.leaseId)]
            )
            return receiptAccepted(receipt)
        } catch {
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
        let sessions = terminalLeases.values.compactMap { lease in store.session(for: lease.terminalId) }
        for session in sessions { await releaseTerminalControl(session) }
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
        persistence.clear()
        pairedDesktop = nil
        pendingPayload = nil
        activePairingNonce = nil
        accountLookupID = nil
        accountLookupInProgress = false
        accountOffers = []
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingPhase = .idle
        client.transport.stop()
    }

    // MARK: Wiring

    private func observe() {
        client.onStreamIssue = { [weak self] sessionId, message in
            guard let self else { return }
            if let message { self.terminalStreamIssues[sessionId] = message }
            else { self.terminalStreamIssues.removeValue(forKey: sessionId) }
        }
        client.transport.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.handleTransportState(state) }
            .store(in: &cancellables)
        client.$sas
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] sas in
                guard let self, case .connecting = self.pairingPhase else { return }
                self.pairingTimeoutTask?.cancel()
                self.pairingTimeoutTask = nil
                self.pairingPhase = .confirm(sas)
                #if DEBUG
                // Automated pairing harness: confirm the SAS without a tap.
                if ProcessInfo.processInfo.environment["KAISOLA_AUTOSAS"] == "1" { self.confirmSAS() }
                #endif
            }
            .store(in: &cancellables)
        client.$pairedDesktop
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] desktop in self?.handlePaired(desktop) }
            .store(in: &cancellables)
        client.$lastError
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self, case .idle = self.pairingPhase else {
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
            do { try client.beginPairing(payload: payload, identity: identity) }
            catch { fail(error) }
        }
    }

    private func handlePaired(_ desktop: CompanionPairedDesktop) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        activePairingNonce = nil
        persistence.save(desktop)
        pairedDesktop = desktop
        connectionWanted = true
        pairingPhase = .paired
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

    private func remember(_ lease: TerminalLease) {
        let key = "\(lease.projectId)\u{0}\(lease.terminalId)"
        terminalLeases[key] = lease
        controlledTerminalIds.insert(lease.terminalId)
        terminalRenewals.removeValue(forKey: key)?.cancel()
        terminalRenewals[key] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = max(3_000, min(lease.renewAfterMs, 12_000))
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self, let current = self.terminalLeases[key] else { return }
                do {
                    let receipt = try await self.client.performCommand(
                        type: "terminal.renew-control",
                        projectId: current.projectId,
                        targetId: current.terminalId,
                        capability: .terminalControl,
                        payload: ["leaseId": .string(current.leaseId)],
                        timeout: .seconds(5)
                    )
                    guard self.receiptAccepted(receipt),
                          let session = self.store.session(for: current.terminalId),
                          let renewed = self.lease(from: receipt, session: session) else {
                        self.dropTerminalLease(key: key, terminalId: current.terminalId)
                        return
                    }
                    self.terminalLeases[key] = renewed
                } catch {
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
                "Couldn't reach this Mac. Keep Companion on and put both devices on the same Wi-Fi, then try again."
            )
        }
    }
}
