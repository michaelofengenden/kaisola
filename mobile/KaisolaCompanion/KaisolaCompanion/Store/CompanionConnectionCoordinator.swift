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
    func clear() { defaults.removeObject(forKey: key) }
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
    /// Drives presentation of the pairing sheet from anywhere in the app.
    @Published var wantsPairing = false

    let store: CompanionStore

    private let client: CompanionClient
    private let keychain: CompanionIdentityKeychain
    private let persistence: PairedDesktopPersisting
    private var identity: CompanionIdentity?
    private var pendingPayload: CompanionPairingPayload?
    private var cancellables: Set<AnyCancellable> = []

    var isPaired: Bool { pairedDesktop != nil }

    init(
        client: CompanionClient = CompanionClient(transport: CompanionTransport(autoConnect: true)),
        keychain: CompanionIdentityKeychain = CompanionIdentityKeychain(),
        persistence: PairedDesktopPersisting = UserDefaultsPairedDesktopStore()
    ) {
        self.client = client
        self.keychain = keychain
        self.persistence = persistence
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
        do {
            let identity = try await resolveIdentity()
            self.pendingPayload = payload
            pairingPhase = .connecting
            client.transport.startDiscovery()
            _ = identity
        } catch {
            pairingPhase = .failed(Self.identityMessage(error))
        }
    }

    /// Open the pairing sheet fresh.
    func presentPairing() {
        pairingPhase = .idle
        wantsPairing = true
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
        pairingPhase = .idle
        if !isPaired { client.transport.stop() }
    }

    /// On launch (or when returning to foreground) reconnect to the known Mac.
    func connectIfPaired() async {
        guard let desktop = pairedDesktop else { return }
        do {
            let identity = try await resolveIdentity()
            try client.configureResume(desktop: desktop, identity: identity, cursor: client.ackCursor)
            client.transport.startDiscovery()
        } catch {
            store.connection = .offline
        }
    }

    /// Forget the paired Mac and drop the connection.
    func unpair() {
        persistence.clear()
        pairedDesktop = nil
        pendingPayload = nil
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
        pairingPhase = .failed(Self.identityMessage(error))
    }

    private func failIfPairing(_ message: String) {
        switch pairingPhase {
        case .connecting, .preparing, .confirm:
            pairingPhase = .failed("Pairing didn't complete. Move closer to your Mac and try again.")
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
}
