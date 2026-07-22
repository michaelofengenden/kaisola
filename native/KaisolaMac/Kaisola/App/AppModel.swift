import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState: Equatable {
        case looking
        case connecting
        case reconnecting(attempt: Int)
        case connected(version: String, pid: Int32, serverEnforcedObserver: Bool)
        case unavailable(String)

        var title: String {
            switch self {
            case .looking: "Looking for broker"
            case .connecting: "Connecting"
            case .reconnecting: "Reconnecting"
            case .connected: "Connected"
            case .unavailable: "Offline"
            }
        }

        var detail: String? {
            switch self {
            case let .reconnecting(attempt):
                "Attempt \(attempt) · running terminals remain on the broker"
            case let .connected(version, pid, serverEnforced):
                "Broker \(version) · PID \(pid) · \(serverEnforced ? "server-enforced observer" : "local observer policy")"
            case let .unavailable(message): message
            default: nil
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    @Published private(set) var connectionState: ConnectionState = .looking
    @Published private(set) var sessions: [BrokerTerminalRecord] = []
    @Published var selectedSessionID: String?
    @Published private(set) var terminalDocument = TerminalDocument.empty

    private let brokerPreparer: any BrokerInfoPreparing
    private let client: any ObserveOnlyBrokerServing
    private let cursorStore: TerminalCursorStore
    private let reconnectBackoff: BrokerReconnectBackoff
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let jitter: @Sendable () -> Double
    private var selectedSession: BrokerTerminalRecord?
    private var activeBrokerIdentity: String?
    private var reconnectTask: Task<Void, Never>?
    private var cursorSaveTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var shouldReconnect = false
    private var hasStarted = false
    private let observerOwnerID = "native-preview"

    init(
        brokerPreparer: any BrokerInfoPreparing = BrokerStartupCoordinator.live(),
        client: any ObserveOnlyBrokerServing = ObserveOnlyBrokerClient(),
        cursorStore: TerminalCursorStore = TerminalCursorStore(fileURL: NativePreviewPaths.terminalCursorStore),
        reconnectBackoff: BrokerReconnectBackoff = BrokerReconnectBackoff(),
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        jitter: @escaping @Sendable () -> Double = {
            Double.random(in: -1...1)
        }
    ) {
        self.brokerPreparer = brokerPreparer
        self.client = client
        self.cursorStore = cursorStore
        self.reconnectBackoff = reconnectBackoff
        self.sleep = sleep
        self.jitter = jitter
    }

    var projects: [(name: String, sessions: [BrokerTerminalRecord])] {
        Dictionary(grouping: sessions, by: \.projectID)
            .map { (name: $0.key, sessions: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func reload() async {
        hasStarted = true
        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await persistCurrentCursor()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectionState = .looking
        await client.disconnect()
        selectedSession = nil

        if !(await connect(generation: generation, reconnectAttempt: nil)) {
            scheduleReconnect(attempt: 0, generation: generation)
        }
    }

    /// Called when the app returns to the foreground. An existing healthy
    /// observer is left alone; an offline one resumes its bounded retry loop.
    func resumeIfNeeded() {
        guard hasStarted,
              shouldReconnect,
              case .unavailable = connectionState else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        scheduleReconnect(attempt: 0, generation: connectionGeneration, immediate: true)
    }

    /// Sleep can invalidate a Unix socket without promptly waking a blocked
    /// read. Reopening the observer is safe and retains the in-memory cursor.
    func recoverAfterWake() async {
        guard hasStarted, shouldReconnect else { return }
        await reload()
    }

    func select(_ id: String?) async {
        guard let id, let next = sessions.first(where: { $0.id == id }) else {
            await persistCurrentCursor()
            if let current = selectedSession, connectionState.isConnected {
                try? await client.unsubscribe(from: current, ownerID: observerOwnerID)
            }
            selectedSession = nil
            selectedSessionID = nil
            terminalDocument = .empty
            return
        }

        if let current = selectedSession, current.id != next.id {
            await persistCurrentCursor()
            if connectionState.isConnected {
                try? await client.unsubscribe(from: current, ownerID: observerOwnerID)
            }
        }

        let retainedDocument = terminalDocument.sessionID == next.id ? terminalDocument : .empty
        selectedSession = next
        selectedSessionID = next.id
        guard connectionState.isConnected else {
            terminalDocument = retainedDocument
            return
        }

        let resumeCursor = retainedDocument.cursor
        let priorPersistedCursor: TerminalCursor?
        if let scope = cursorScope(for: next) {
            priorPersistedCursor = try? await cursorStore.cursor(for: scope)
        } else {
            priorPersistedCursor = nil
        }

        do {
            let result = try await client.subscribe(
                to: next,
                ownerID: observerOwnerID,
                cursor: resumeCursor
            )
            var document = retainedDocument.applying(result, sessionID: next.id)
            // A cold launch asks for the full retained snapshot instead of
            // skipping bytes merely because a disk cursor exists. The cursor
            // still proves whether history disappeared while the UI was away.
            if resumeCursor == nil,
               let priorPersistedCursor,
               case let .snapshot(snapshot, _) = result,
               (priorPersistedCursor.streamEpoch != snapshot.streamEpoch
                   || priorPersistedCursor.offset < snapshot.startOffset
                   || priorPersistedCursor.offset > snapshot.endOffset) {
                document.truncated = true
            }
            terminalDocument = document
            await persistCurrentCursor()
        } catch {
            terminalDocument = .failure(sessionID: next.id, message: error.kaisolaSafeDescription)
        }
    }

    func disconnect() async {
        shouldReconnect = false
        connectionGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        cursorSaveTask?.cancel()
        cursorSaveTask = nil
        await persistCurrentCursor()
        if let selectedSession, connectionState.isConnected {
            try? await client.unsubscribe(from: selectedSession, ownerID: observerOwnerID)
        }
        await client.disconnect()
    }

    private func connect(generation: Int, reconnectAttempt: Int?) async -> Bool {
        guard generation == connectionGeneration, shouldReconnect else { return false }
        connectionState = reconnectAttempt.map { .reconnecting(attempt: $0 + 1) } ?? .connecting

        do {
            let info = try await brokerPreparer.prepare()
            activeBrokerIdentity = info.persistenceIdentity
            await client.setEventHandler { [weak self] event in
                Task { @MainActor in self?.consume(event) }
            }
            await client.setDisconnectHandler { [weak self] error in
                Task { @MainActor in self?.connectionLost(error, generation: generation) }
            }
            let hello = try await client.connect(to: info)
            let status = try await client.inventory()
            guard generation == connectionGeneration, shouldReconnect else { return false }

            sessions = status.terminals
            connectionState = .connected(
                version: hello.version,
                pid: hello.pid,
                serverEnforcedObserver: hello.serverEnforcedObserver
            )
            let preferredID = selectedSessionID.flatMap { selected in
                sessions.contains(where: { $0.id == selected }) ? selected : nil
            } ?? sessions.first?.id
            selectedSession = nil
            if let preferredID {
                selectedSessionID = preferredID
                await select(preferredID)
            } else {
                selectedSessionID = nil
                terminalDocument = .empty
            }
            return true
        } catch {
            guard generation == connectionGeneration, shouldReconnect else { return false }
            connectionState = .unavailable(error.kaisolaSafeDescription)
            return false
        }
    }

    private func scheduleReconnect(attempt: Int, generation: Int, immediate: Bool = false) {
        guard generation == connectionGeneration,
              shouldReconnect,
              reconnectTask == nil else { return }
        let delay = immediate ? 0 : reconnectBackoff.delayNanoseconds(
            forAttempt: attempt,
            jitterUnit: jitter()
        )
        let sleeper = sleep
        reconnectTask = Task { [weak self] in
            do {
                if delay > 0 { try await sleeper(delay) }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runReconnectAttempt(attempt, generation: generation)
        }
    }

    private func runReconnectAttempt(_ attempt: Int, generation: Int) async {
        reconnectTask = nil
        guard generation == connectionGeneration, shouldReconnect else { return }
        await client.disconnect()
        selectedSession = nil
        if !(await connect(generation: generation, reconnectAttempt: attempt)) {
            scheduleReconnect(attempt: attempt + 1, generation: generation)
        }
    }

    private func consume(_ event: BrokerEvent) {
        guard event.ownerID == observerOwnerID,
              event.projectID == selectedSession?.projectID,
              event.terminalID == selectedSession?.id else { return }

        switch event.kind {
        case let .output(epoch, startOffset, endOffset, data):
            guard terminalDocument.append(
                epoch: epoch,
                startOffset: startOffset,
                endOffset: endOffset,
                data: data
            ) else {
                Task { await select(selectedSessionID) }
                return
            }
            queueCursorPersistence()
        case .snapshotRequired:
            Task { await select(selectedSessionID) }
        case .exit:
            terminalDocument.exited = true
            queueCursorPersistence()
        case .activity:
            break
        }
    }

    private func connectionLost(_ error: any Error, generation: Int) {
        guard generation == connectionGeneration, shouldReconnect else { return }
        connectionState = .unavailable(error.kaisolaSafeDescription)
        scheduleReconnect(attempt: 0, generation: generation)
    }

    private func cursorScope(for session: BrokerTerminalRecord) -> TerminalCursorScope? {
        guard let activeBrokerIdentity else { return nil }
        return TerminalCursorScope(
            brokerIdentity: activeBrokerIdentity,
            projectID: session.projectID,
            terminalID: session.id
        )
    }

    private func persistCurrentCursor() async {
        cursorSaveTask?.cancel()
        cursorSaveTask = nil
        guard let session = selectedSession,
              let scope = cursorScope(for: session),
              terminalDocument.sessionID == session.id,
              let cursor = terminalDocument.cursor else { return }
        try? await cursorStore.save(cursor, for: scope)
    }

    private func queueCursorPersistence() {
        guard let session = selectedSession,
              let scope = cursorScope(for: session),
              terminalDocument.sessionID == session.id,
              let cursor = terminalDocument.cursor else { return }
        cursorSaveTask?.cancel()
        let store = cursorStore
        cursorSaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            try? await store.save(cursor, for: scope)
        }
    }
}

private extension Error {
    var kaisolaSafeDescription: String {
        if let localized = self as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "The terminal observer could not connect. The running broker and its sessions were left untouched."
    }
}
