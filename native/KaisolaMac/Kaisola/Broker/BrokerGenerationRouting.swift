import Foundation

enum BrokerGenerationDiagnostics {
    static func detail(
        appVersion: String,
        topology: BrokerGenerationTopology
    ) -> String {
        let current = generationDetail(topology.current)
        let drains = topology.draining.map(generationDetail).joined(separator: "; ")
        if drains.isEmpty {
            return "App \(appVersion) · Current broker \(current) · No draining brokers"
        }
        return "App \(appVersion) · Current broker \(current) · Draining brokers: \(drains)"
    }

    private static func generationDetail(_ generation: BrokerGenerationRecord) -> String {
        let implementation = generation.info.implementationVersion ?? 1
        let package = generation.info.packageVersion ?? "legacy"
        return "\(generation.info.version) · package \(package) · implementation \(implementation) · PID \(generation.info.pid) · content \(generation.id.prefix(12))"
    }
}

/// Shared ownership map for the independently authenticated observer and
/// controller lanes. The validated inventory is authoritative for existing
/// terminals; only terminal.create can add an owner between inventory polls.
actor BrokerGenerationRouteTable {
    private var topology: BrokerGenerationTopology?
    private var terminalOwners: [String: String] = [:]
    /// A create reply is authoritative even if an inventory request that began
    /// just before it finishes afterward. Keep that acknowledged owner until a
    /// later inventory observes it (or release explicitly removes it), so the
    /// stale snapshot cannot make the terminal temporarily unroutable.
    private var createdAwaitingInventory: [String: String] = [:]

    func configure(_ topology: BrokerGenerationTopology) {
        self.topology = topology
        let liveGenerations = Set(topology.all.map(\.id))
        terminalOwners = terminalOwners.filter { liveGenerations.contains($0.value) }
        createdAwaitingInventory = createdAwaitingInventory.filter {
            liveGenerations.contains($0.value)
        }
    }

    func replaceTerminalOwners(_ owners: [String: String]) throws {
        guard let topology else { throw BrokerClientError.notConnected }
        let valid = Set(topology.all.map(\.id))
        guard owners.values.allSatisfy(valid.contains) else {
            throw BrokerClientError.identityChanged
        }
        var reconciled = owners
        var observedCreates: [String] = []
        for (terminalID, generationID) in createdAwaitingInventory {
            if let observed = owners[terminalID] {
                guard observed == generationID else {
                    throw BrokerClientError.identityChanged
                }
                observedCreates.append(terminalID)
            } else {
                reconciled[terminalID] = generationID
            }
        }
        for terminalID in observedCreates {
            createdAwaitingInventory.removeValue(forKey: terminalID)
        }
        terminalOwners = reconciled
    }

    func noteCreated(terminalID: String) throws {
        guard let topology else { throw BrokerClientError.notConnected }
        terminalOwners[terminalID] = topology.current.id
        createdAwaitingInventory[terminalID] = topology.current.id
    }

    func noteReleased(terminalID: String) {
        terminalOwners.removeValue(forKey: terminalID)
        createdAwaitingInventory.removeValue(forKey: terminalID)
    }

    func generationID(for terminalID: String, hint: String? = nil) throws -> String {
        guard let topology else { throw BrokerClientError.notConnected }
        if let hint {
            guard topology.all.contains(where: { $0.id == hint }),
                  terminalOwners[terminalID] == nil || terminalOwners[terminalID] == hint else {
                throw BrokerClientError.identityChanged
            }
            return hint
        }
        guard let owner = terminalOwners[terminalID] else {
            throw BrokerClientError.requestFailed("terminal generation unavailable")
        }
        return owner
    }

    func currentGenerationID() throws -> String {
        guard let topology else { throw BrokerClientError.notConnected }
        return topology.current.id
    }
}

/// One read-only socket per registered generation. Inventories are merged only
/// after every generation independently proves its sealed identity; duplicate
/// terminal IDs fail closed instead of making routing order-dependent.
actor BrokerGenerationObserverRouter: ObserveOnlyBrokerServing {
    typealias ClientFactory = @Sendable () -> any ObserveOnlyBrokerServing

    private let routes: BrokerGenerationRouteTable
    private let factory: ClientFactory
    private var topology: BrokerGenerationTopology?
    private var clients: [String: any ObserveOnlyBrokerServing] = [:]
    private var eventHandler: (@Sendable (BrokerEvent) -> Void)?
    private var disconnectHandler: (@Sendable (any Error) -> Void)?
    private var reportedDisconnect = false
    private var emptyDrainingGenerationIDs: Set<String> = []
    private var preservedDrainingGenerationIDs: Set<String> = []

    init(
        routes: BrokerGenerationRouteTable,
        factory: @escaping ClientFactory = { ObserveOnlyBrokerClient() }
    ) {
        self.routes = routes
        self.factory = factory
    }

    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async {
        eventHandler = handler
    }

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {
        disconnectHandler = handler
    }

    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        try await connect(to: .single(info))
    }

    func connect(to requestedTopology: BrokerGenerationTopology) async throws -> BrokerHello {
        if topology == requestedTopology,
           let current = clients[requestedTopology.current.id] {
            return try await current.connect(to: requestedTopology.current.info)
        }
        await disconnect()
        await routes.configure(requestedTopology)
        topology = requestedTopology
        reportedDisconnect = false
        var currentHello: BrokerHello?
        do {
            for generation in requestedTopology.all {
                let client = factory()
                let generationID = generation.id
                await client.setEventHandler { [weak self] event in
                    Task { await self?.forward(event, from: generationID) }
                }
                await client.setDisconnectHandler { [weak self] error in
                    Task { await self?.childDisconnected(error, generationID: generationID) }
                }
                let hello = try await client.connect(to: generation.info)
                clients[generationID] = client
                if generationID == requestedTopology.current.id { currentHello = hello }
            }
            guard let currentHello else { throw BrokerClientError.identityChanged }
            return currentHello
        } catch {
            await disconnect()
            throw error
        }
    }

    func inventory() async throws -> BrokerStatus {
        guard let topology else { throw BrokerClientError.notConnected }
        var routed: [BrokerTerminalRecord] = []
        var owners: [String: String] = [:]
        var emptyDrains: Set<String> = []
        for generation in topology.all {
            guard let client = clients[generation.id] else {
                throw BrokerClientError.notConnected
            }
            let status = try await client.inventory()
            if generation.role == .draining, status.terminals.isEmpty {
                emptyDrains.insert(generation.id)
            }
            for terminal in status.terminals {
                guard owners.updateValue(generation.id, forKey: terminal.id) == nil else {
                    throw BrokerClientError.identityChanged
                }
                routed.append(terminal.routed(to: generation))
            }
        }
        try await routes.replaceTerminalOwners(owners)
        emptyDrainingGenerationIDs = emptyDrains
        return BrokerStatus(terminals: routed)
    }

    func detachEmptyDrainingGenerations() async -> Set<String> {
        let generationIDs = emptyDrainingGenerationIDs
            .subtracting(preservedDrainingGenerationIDs)
        emptyDrainingGenerationIDs = []
        for generationID in generationIDs {
            guard let client = clients.removeValue(forKey: generationID) else { continue }
            await client.setDisconnectHandler(nil)
            await client.setEventHandler(nil)
            await client.disconnect()
        }
        return generationIDs
    }

    func preserveDrainingGenerations(_ generationIDs: Set<String>) async {
        guard let topology else {
            preservedDrainingGenerationIDs = []
            return
        }
        let drains = Set(topology.draining.map(\.id))
        preservedDrainingGenerationIDs = generationIDs.intersection(drains)
    }

    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        try await client(for: terminal).subscribe(to: terminal, ownerID: ownerID, cursor: cursor)
    }

    func subscribeBounded(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?,
        maximumSnapshotBytes: Int
    ) async throws -> TerminalSubscriptionResult {
        try await client(for: terminal).subscribeBounded(
            to: terminal,
            ownerID: ownerID,
            cursor: cursor,
            maximumSnapshotBytes: maximumSnapshotBytes
        )
    }

    func historyPage(
        for terminal: BrokerTerminalRecord,
        ownerID: String,
        streamEpoch: String,
        beforeOffset: Int64,
        maxBytes: Int
    ) async throws -> TerminalHistoryPage {
        try await client(for: terminal).historyPage(
            for: terminal,
            ownerID: ownerID,
            streamEpoch: streamEpoch,
            beforeOffset: beforeOffset,
            maxBytes: maxBytes
        )
    }

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {
        try await client(for: terminal).unsubscribe(from: terminal, ownerID: ownerID)
    }

    func disconnect() async {
        let active = clients.values
        clients.removeAll()
        topology = nil
        reportedDisconnect = false
        emptyDrainingGenerationIDs = []
        preservedDrainingGenerationIDs = []
        for client in active {
            await client.setDisconnectHandler(nil)
            await client.setEventHandler(nil)
            await client.disconnect()
        }
    }

    private func client(
        for terminal: BrokerTerminalRecord
    ) async throws -> any ObserveOnlyBrokerServing {
        let generationID = try await routes.generationID(
            for: terminal.id,
            hint: terminal.brokerGenerationID
        )
        guard let client = clients[generationID] else { throw BrokerClientError.notConnected }
        return client
    }

    private func forward(_ event: BrokerEvent, from generationID: String) {
        guard clients[generationID] != nil else { return }
        eventHandler?(event)
    }

    private func childDisconnected(_ error: any Error, generationID: String) {
        guard clients[generationID] != nil, !reportedDisconnect else { return }
        reportedDisconnect = true
        disconnectHandler?(error)
    }
}

/// The write lane uses the same inventory-derived owner map. New terminals are
/// always created on the registry's current generation; every later mutation
/// returns to that recorded owner even after the generation begins draining.
actor BrokerGenerationControlRouter: BrokerControlServing {
    typealias ClientFactory = @Sendable (String) -> any BrokerControlServing

    nonisolated let connectionInstanceID: String
    private let routes: BrokerGenerationRouteTable
    private let factory: ClientFactory
    private var topology: BrokerGenerationTopology?
    private var clients: [String: any BrokerControlServing] = [:]
    private var disconnectHandler: (@Sendable (any Error) -> Void)?
    private var reportedDisconnect = false

    init(
        routes: BrokerGenerationRouteTable,
        connectionInstanceID: String = UUID().uuidString.lowercased(),
        factory: ClientFactory? = nil
    ) {
        precondition(UUID(uuidString: connectionInstanceID) != nil)
        self.routes = routes
        self.connectionInstanceID = connectionInstanceID.lowercased()
        self.factory = factory ?? { BrokerControlClient(connectionInstanceID: $0) }
    }

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {
        disconnectHandler = handler
    }

    func connect(to info: BrokerInfo, ownerID: String) async throws {
        try await connect(to: .single(info), ownerID: ownerID)
    }

    func connect(
        to requestedTopology: BrokerGenerationTopology,
        ownerID: String
    ) async throws {
        if topology == requestedTopology, clients[requestedTopology.current.id] != nil { return }
        await disconnect()
        await routes.configure(requestedTopology)
        topology = requestedTopology
        reportedDisconnect = false
        do {
            for generation in requestedTopology.all {
                let client = factory(connectionInstanceID)
                let generationID = generation.id
                await client.setDisconnectHandler { [weak self] error in
                    Task { await self?.childDisconnected(error, generationID: generationID) }
                }
                try await client.connect(to: generation.info, ownerID: ownerID)
                clients[generationID] = client
            }
        } catch {
            await disconnect()
            throw error
        }
    }

    func createTerminal(
        projectID: String,
        terminalID: String,
        command: String,
        arguments: [String],
        cwd: String,
        columns: Int,
        rows: Int,
        restore: Bool
    ) async throws -> TerminalCreation {
        let current = try await routes.currentGenerationID()
        guard let client = clients[current] else { throw BrokerClientError.notConnected }
        let created = try await client.createTerminal(
            projectID: projectID,
            terminalID: terminalID,
            command: command,
            arguments: arguments,
            cwd: cwd,
            columns: columns,
            rows: rows,
            restore: restore
        )
        try await routes.noteCreated(terminalID: terminalID)
        return created
    }

    func attach(projectID: String, terminalID: String) async throws {
        try await client(for: terminalID).attach(projectID: projectID, terminalID: terminalID)
    }

    func write(projectID: String, terminalID: String, data: String) async throws {
        try await client(for: terminalID).write(projectID: projectID, terminalID: terminalID, data: data)
    }

    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws {
        try await client(for: terminalID).resize(
            projectID: projectID,
            terminalID: terminalID,
            columns: columns,
            rows: rows
        )
    }

    func kill(projectID: String, terminalID: String) async throws {
        try await client(for: terminalID).kill(projectID: projectID, terminalID: terminalID)
    }

    func release(projectID: String, terminalID: String) async throws {
        try await client(for: terminalID).release(projectID: projectID, terminalID: terminalID)
        await routes.noteReleased(terminalID: terminalID)
    }

    func detachOwner(projectID: String, terminalID: String) async throws {
        try await client(for: terminalID).detachOwner(projectID: projectID, terminalID: terminalID)
    }

    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws {
        try await client(for: terminalID).setAgentTurn(
            projectID: projectID,
            terminalID: terminalID,
            busy: busy
        )
    }

    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws {
        try await client(for: terminalID).setControlLease(
            projectID: projectID,
            terminalID: terminalID,
            active: active
        )
    }

    func disconnect() async {
        let active = clients.values
        clients.removeAll()
        topology = nil
        reportedDisconnect = false
        for client in active {
            await client.setDisconnectHandler(nil)
            await client.disconnect()
        }
    }

    func detachGenerations(_ generationIDs: Set<String>) async {
        guard let topology else { return }
        let allowed = Set(topology.draining.map(\.id))
        for generationID in generationIDs where allowed.contains(generationID) {
            guard let client = clients.removeValue(forKey: generationID) else { continue }
            await client.setDisconnectHandler(nil)
            await client.disconnect()
        }
    }

    private func client(for terminalID: String) async throws -> any BrokerControlServing {
        let generationID = try await routes.generationID(for: terminalID)
        guard let client = clients[generationID] else { throw BrokerClientError.notConnected }
        return client
    }

    private func childDisconnected(_ error: any Error, generationID: String) {
        guard clients[generationID] != nil, !reportedDisconnect else { return }
        reportedDisconnect = true
        disconnectHandler?(error)
    }
}
