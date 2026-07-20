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
    /// Drives presentation of the pairing sheet from anywhere in the app.
    @Published var wantsPairing = false

    let store: CompanionStore

    private let client: CompanionClient
    private let keychain: CompanionIdentityKeychain
    private let persistence: PairedDesktopPersisting
    private let accountRendezvous: any CompanionAccountRendezvousServing
    private var identity: CompanionIdentity?
    private var pendingPayload: CompanionPairingPayload?
    private var activePairingNonce: String?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var accountLookupID: UUID?
    private var cancellables: Set<AnyCancellable> = []

    var isPaired: Bool { pairedDesktop != nil }

    init(
        client: CompanionClient = CompanionClient(transport: CompanionTransport(autoConnect: true)),
        keychain: CompanionIdentityKeychain = CompanionIdentityKeychain(),
        persistence: PairedDesktopPersisting = UserDefaultsPairedDesktopStore(),
        accountRendezvous: any CompanionAccountRendezvousServing = CompanionAccountRendezvousService()
    ) {
        self.client = client
        self.keychain = keychain
        self.persistence = persistence
        self.accountRendezvous = accountRendezvous
        self.store = CompanionStore.live(client: client)
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
            activePairingNonce = payload.pairingNonce
            pairingPhase = .connecting
            armPairingTimeout(for: payload)
            client.transport.startDiscovery(preferred: payload.transportHint)
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
        if !isPaired { client.transport.stop() }
    }

    /// On launch (or when returning to foreground) reconnect to the known Mac.
    func connectIfPaired() async {
        guard let desktop = pairedDesktop else { return }
        do {
            let identity = try await resolveIdentity()
            // Resume deltas only when this process still holds the projection
            // that cursor acknowledges. A cold launch sends no cursor and gets
            // a coherent snapshot instead of a green-but-empty board.
            try client.configureResume(desktop: desktop, identity: identity, cursor: store.lastAckCursor)
            client.transport.startDiscovery(preferred: desktop.transportHint)
        } catch {
            store.connection = .offline
        }
    }

    /// Start/stop the live byte stream for a terminal session being viewed.
    func setTerminalStream(projectId: String, sessionId: String, subscribed: Bool) {
        guard !store.isPreview else { return }
        try? client.setStreamSubscription(projectId: projectId, sessionId: sessionId, subscribed: subscribed)
    }

    /// Forget the paired Mac and drop the connection.
    func unpair() {
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
        pairingPhase = .paired
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
