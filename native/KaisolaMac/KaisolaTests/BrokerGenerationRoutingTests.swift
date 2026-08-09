import Darwin
import Foundation
import XCTest
@testable import Kaisola

final class BrokerGenerationRoutingTests: XCTestCase {
    func testInventoryTagsEveryTerminalAndRoutesReadsAndWritesToItsOwningGeneration() async throws {
        let topology = makeTopology()
        let currentObserver = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("current-terminal")])
        )
        let drainingObserver = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("draining-terminal")])
        )
        let observerQueue = ObserverClientQueue([currentObserver, drainingObserver])
        let routes = BrokerGenerationRouteTable()
        let observer = BrokerGenerationObserverRouter(
            routes: routes,
            factory: { observerQueue.next() }
        )

        let connectionID = "11111111-1111-4111-8111-111111111111"
        let currentControl = RoutingControlClient(connectionInstanceID: connectionID)
        let drainingControl = RoutingControlClient(connectionInstanceID: connectionID)
        let controlQueue = ControlClientQueue([currentControl, drainingControl])
        let control = BrokerGenerationControlRouter(
            routes: routes,
            connectionInstanceID: connectionID,
            factory: { _ in controlQueue.next() }
        )

        _ = try await observer.connect(to: topology)
        let status = try await observer.inventory()
        try await control.connect(to: topology, ownerID: "owner")

        XCTAssertEqual(status.terminals.map(\.id), ["current-terminal", "draining-terminal"])
        XCTAssertEqual(status.terminals[0].brokerGenerationID, topology.current.id)
        XCTAssertEqual(
            status.terminals[0].brokerPersistenceIdentity,
            topology.current.info.persistenceIdentity
        )
        XCTAssertEqual(status.terminals[1].brokerGenerationID, topology.draining[0].id)
        XCTAssertEqual(
            status.terminals[1].brokerPersistenceIdentity,
            topology.draining[0].info.persistenceIdentity
        )

        let drainingTerminal = status.terminals[1]
        _ = try await observer.subscribe(
            to: drainingTerminal,
            ownerID: "owner",
            cursor: nil
        )
        _ = try await observer.historyPage(
            for: drainingTerminal,
            ownerID: "owner",
            streamEpoch: "epoch",
            beforeOffset: 0,
            maxBytes: 1_024
        )
        try await observer.unsubscribe(from: drainingTerminal, ownerID: "owner")

        _ = try await control.createTerminal(
            projectID: "project",
            terminalID: "new-terminal",
            command: "/bin/sh",
            arguments: [],
            cwd: "/tmp",
            columns: 80,
            rows: 24
        )
        try await control.write(projectID: "project", terminalID: "new-terminal", data: "new")
        try await control.attach(projectID: "project", terminalID: drainingTerminal.id)
        try await control.write(projectID: "project", terminalID: drainingTerminal.id, data: "old")
        try await control.resize(
            projectID: "project",
            terminalID: drainingTerminal.id,
            columns: 90,
            rows: 30
        )
        try await control.setAgentTurn(
            projectID: "project",
            terminalID: drainingTerminal.id,
            busy: true
        )
        try await control.setControlLease(
            projectID: "project",
            terminalID: drainingTerminal.id,
            active: true
        )
        try await control.release(projectID: "project", terminalID: drainingTerminal.id)

        let drainingObserverCalls = await drainingObserver.calls()
        let currentObserverCalls = await currentObserver.calls()
        let currentControlCalls = await currentControl.calls()
        let drainingControlCalls = await drainingControl.calls()
        XCTAssertEqual(
            drainingObserverCalls,
            ["subscribe:draining-terminal", "history:draining-terminal", "unsubscribe:draining-terminal"]
        )
        XCTAssertEqual(currentObserverCalls, [])
        XCTAssertEqual(
            currentControlCalls,
            ["create:new-terminal", "write:new-terminal"]
        )
        XCTAssertEqual(
            drainingControlCalls,
            [
                "attach:draining-terminal",
                "write:draining-terminal",
                "resize:draining-terminal",
                "agent-turn:draining-terminal",
                "control-lease:draining-terminal",
                "release:draining-terminal",
            ]
        )
    }

    func testDuplicateTerminalIdentityAcrossGenerationsFailsClosed() async throws {
        let topology = makeTopology()
        let duplicate = terminal("duplicate")
        let queue = ObserverClientQueue([
            RoutingObserverClient(status: BrokerStatus(terminals: [duplicate])),
            RoutingObserverClient(status: BrokerStatus(terminals: [duplicate])),
        ])
        let observer = BrokerGenerationObserverRouter(
            routes: BrokerGenerationRouteTable(),
            factory: { queue.next() }
        )

        _ = try await observer.connect(to: topology)
        do {
            _ = try await observer.inventory()
            XCTFail("expected duplicate terminal identity to fail closed")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
    }

    func testAcknowledgedCreateSurvivesAnOlderInventorySnapshot() async throws {
        let topology = makeTopology()
        let routes = BrokerGenerationRouteTable()
        await routes.configure(topology)
        try await routes.replaceTerminalOwners(["existing": topology.current.id])

        try await routes.noteCreated(terminalID: "new-terminal")
        // This response may have been captured before terminal.create was
        // processed on the other authenticated socket.
        try await routes.replaceTerminalOwners(["existing": topology.current.id])
        let routedGenerationID = try await routes.generationID(for: "new-terminal")
        XCTAssertEqual(routedGenerationID, topology.current.id)

        // Once an inventory observes the terminal, ordinary snapshots own its
        // lifecycle again; explicit release removes the provisional route.
        try await routes.replaceTerminalOwners([
            "existing": topology.current.id,
            "new-terminal": topology.current.id,
        ])
        await routes.noteReleased(terminalID: "new-terminal")
        do {
            _ = try await routes.generationID(for: "new-terminal")
            XCTFail("expected a released terminal route to be removed")
        } catch {
            XCTAssertEqual(
                error as? BrokerClientError,
                .requestFailed("terminal generation unavailable")
            )
        }
    }

    func testEmptyDrainDetachesBothAuthenticatedLanesBeforeRetirement() async throws {
        let topology = makeTopology()
        let currentObserver = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("current-terminal")])
        )
        let drainingObserver = RoutingObserverClient(status: BrokerStatus(terminals: []))
        let observerQueue = ObserverClientQueue([currentObserver, drainingObserver])
        let routes = BrokerGenerationRouteTable()
        let observer = BrokerGenerationObserverRouter(
            routes: routes,
            factory: { observerQueue.next() }
        )
        let connectionID = "22222222-2222-4222-8222-222222222222"
        let currentControl = RoutingControlClient(connectionInstanceID: connectionID)
        let drainingControl = RoutingControlClient(connectionInstanceID: connectionID)
        let controlQueue = ControlClientQueue([currentControl, drainingControl])
        let control = BrokerGenerationControlRouter(
            routes: routes,
            connectionInstanceID: connectionID,
            factory: { _ in controlQueue.next() }
        )

        _ = try await observer.connect(to: topology)
        _ = try await observer.inventory()
        try await control.connect(to: topology, ownerID: "owner")
        await observer.preserveDrainingGenerations(Set([topology.draining[0].id]))
        let retained = await observer.detachEmptyDrainingGenerations()
        let retainedObserverDisconnects = await drainingObserver.disconnectCount()
        XCTAssertEqual(retained, [])
        XCTAssertEqual(retainedObserverDisconnects, 0)

        _ = try await observer.inventory()
        await observer.preserveDrainingGenerations([])
        let detached = await observer.detachEmptyDrainingGenerations()
        await control.detachGenerations(detached)

        let currentObserverDisconnects = await currentObserver.disconnectCount()
        let currentControlDisconnects = await currentControl.disconnectCount()
        let drainingObserverDisconnects = await drainingObserver.disconnectCount()
        let drainingControlDisconnects = await drainingControl.disconnectCount()
        XCTAssertEqual(detached, Set([topology.draining[0].id]))
        XCTAssertEqual(currentObserverDisconnects, 0)
        XCTAssertEqual(currentControlDisconnects, 0)
        XCTAssertEqual(drainingObserverDisconnects, 1)
        XCTAssertEqual(drainingControlDisconnects, 1)
    }

    func testInventoryKeepsWorkingAfterAnEmptyDrainIsDetached() async throws {
        let topology = makeTopology()
        let currentObserver = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("current-terminal")])
        )
        let drainingObserver = RoutingObserverClient(status: BrokerStatus(terminals: []))
        let observerQueue = ObserverClientQueue([currentObserver, drainingObserver])
        let observer = BrokerGenerationObserverRouter(
            routes: BrokerGenerationRouteTable(),
            factory: { observerQueue.next() }
        )

        _ = try await observer.connect(to: topology)
        _ = try await observer.inventory()
        let detached = await observer.detachEmptyDrainingGenerations()
        XCTAssertEqual(detached, Set([topology.draining[0].id]))

        // Retirement is a separate registry-owner transaction, so the topology
        // can keep naming an empty drain long after both lanes detached from
        // it. Inventory must keep serving the remaining generations instead of
        // failing every poll tick: the 2026-08-07 stuck-typing regression was
        // this exact throw counting up to a full reconnect every ~10 seconds,
        // forever, while two empty 0.1.110 drains sat in the registry.
        let after = try await observer.inventory()
        XCTAssertEqual(after.terminals.map(\.id), ["current-terminal"])
        let repeated = await observer.detachEmptyDrainingGenerations()
        XCTAssertEqual(repeated, [])
    }

    func testDiagnosticsNameAppCurrentAndEveryDrainingBrokerVersion() {
        let topology = makeTopology()
        let retirement = BrokerRetirementDiagnostic(
            generationID: topology.draining[0].id,
            pid: topology.draining[0].info.pid,
            failureCount: 2,
            reason: .shutdownTimedOut,
            nextAttemptInSweeps: 4
        )
        let detail = BrokerGenerationDiagnostics.detail(
            appVersion: "1.1.8",
            topology: topology,
            retirementDiagnostics: [retirement]
        )

        XCTAssertTrue(detail.contains("App 1.1.8"))
        XCTAssertTrue(detail.contains("Current broker routing-test"))
        XCTAssertTrue(detail.contains("Draining brokers: routing-test"))
        XCTAssertEqual(detail.components(separatedBy: "package routing-test").count - 1, 2)
        XCTAssertEqual(detail.components(separatedBy: "implementation 2").count - 1, 2)
        XCTAssertTrue(detail.contains("Retirement skipped"))
        XCTAssertTrue(detail.contains("safe handoff timed out"))
        XCTAssertTrue(detail.contains("failure count 2"))
        XCTAssertTrue(detail.contains("retry in 4 heartbeats"))

        let staleDetail = BrokerGenerationDiagnostics.detail(
            appVersion: "1.1.8",
            topology: .single(topology.current.info),
            retirementDiagnostics: [retirement]
        )
        XCTAssertFalse(staleDetail.contains("Retirement skipped"))
    }

    private func makeTopology() -> BrokerGenerationTopology {
        let currentDigest = String(repeating: "a", count: 64)
        let drainingDigest = String(repeating: "b", count: 64)
        return BrokerGenerationTopology(
            current: generation(currentDigest, role: .current, startedAt: 2),
            draining: [generation(drainingDigest, role: .draining, startedAt: 1)]
        )
    }

    private func generation(
        _ digest: String,
        role: BrokerGenerationRole,
        startedAt: Int64
    ) -> BrokerGenerationRecord {
        BrokerGenerationRecord(
            id: digest,
            role: role,
            info: BrokerInfo(
                protocolVersion: 2,
                securityEpoch: 1,
                implementationVersion: 2,
                packageSchema: 1,
                packageVersion: "routing-test",
                contentDigest: digest,
                pid: getpid(),
                socketPath: "/tmp/kaisola-routing-\(digest.prefix(8)).sock",
                token: String(repeating: "c", count: 64),
                startedAt: startedAt,
                version: "routing-test"
            ),
            packageRoot: "/tmp/kaisola-routing/\(digest)",
            registeredAt: startedAt
        )
    }

    private func terminal(_ id: String) -> BrokerTerminalRecord {
        BrokerTerminalRecord(
            id: id,
            projectID: "project",
            pid: getpid(),
            exited: false,
            streamEpoch: "epoch",
            endOffset: 0
        )
    }
}

private final class ObserverClientQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [any ObserveOnlyBrokerServing]

    init(_ clients: [any ObserveOnlyBrokerServing]) {
        self.clients = clients
    }

    func next() -> any ObserveOnlyBrokerServing {
        lock.lock()
        defer { lock.unlock() }
        precondition(!clients.isEmpty)
        return clients.removeFirst()
    }
}

private final class ControlClientQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [any BrokerControlServing]

    init(_ clients: [any BrokerControlServing]) {
        self.clients = clients
    }

    func next() -> any BrokerControlServing {
        lock.lock()
        defer { lock.unlock() }
        precondition(!clients.isEmpty)
        return clients.removeFirst()
    }
}

private actor RoutingObserverClient: ObserveOnlyBrokerServing {
    private let status: BrokerStatus
    private var recordedCalls: [String] = []
    private var recordedDisconnectCount = 0
    private var eventHandler: (@Sendable (BrokerEvent) -> Void)?
    private var disconnectHandler: (@Sendable (any Error) -> Void)?

    init(status: BrokerStatus) {
        self.status = status
    }

    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async {
        eventHandler = handler
    }

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {
        disconnectHandler = handler
    }

    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        BrokerHello(
            protocolVersion: info.protocolVersion,
            securityEpoch: info.securityEpoch,
            implementationVersion: info.implementationVersion ?? 1,
            packageSchema: info.packageSchema,
            packageVersion: info.packageVersion,
            contentDigest: info.contentDigest,
            features: ["terminal-observe-v1"],
            pid: info.pid,
            startedAt: info.startedAt,
            version: info.version,
            serverEnforcedObserver: true
        )
    }

    func inventory() async throws -> BrokerStatus { status }

    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        recordedCalls.append("subscribe:\(terminal.id)")
        return .current(TerminalCursor(streamEpoch: "epoch", offset: 0))
    }

    func subscribeBounded(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?,
        maximumSnapshotBytes: Int
    ) async throws -> TerminalSubscriptionResult {
        recordedCalls.append("subscribe-bounded:\(terminal.id)")
        return .current(TerminalCursor(streamEpoch: "epoch", offset: 0))
    }

    func historyPage(
        for terminal: BrokerTerminalRecord,
        ownerID: String,
        streamEpoch: String,
        beforeOffset: Int64,
        maxBytes: Int
    ) async throws -> TerminalHistoryPage {
        recordedCalls.append("history:\(terminal.id)")
        return TerminalHistoryPage(
            streamEpoch: streamEpoch,
            output: "",
            startOffset: beforeOffset,
            endOffset: beforeOffset,
            hasMore: false,
            truncated: false
        )
    }

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {
        recordedCalls.append("unsubscribe:\(terminal.id)")
    }

    func disconnect() async {
        recordedDisconnectCount += 1
    }

    func calls() -> [String] { recordedCalls }
    func disconnectCount() -> Int { recordedDisconnectCount }
}

private actor RoutingControlClient: BrokerControlServing {
    nonisolated let connectionInstanceID: String
    private var recordedCalls: [String] = []
    private var recordedDisconnectCount = 0
    private var disconnectHandler: (@Sendable (any Error) -> Void)?

    init(connectionInstanceID: String) {
        self.connectionInstanceID = connectionInstanceID
    }

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {
        disconnectHandler = handler
    }

    func connect(to info: BrokerInfo, ownerID: String) async throws {}

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
        recordedCalls.append("create:\(terminalID)")
        return TerminalCreation(
            terminalID: terminalID,
            projectID: projectID,
            pid: getpid(),
            streamEpoch: "epoch"
        )
    }

    func attach(projectID: String, terminalID: String) async throws {
        recordedCalls.append("attach:\(terminalID)")
    }

    func write(projectID: String, terminalID: String, data: String) async throws {
        recordedCalls.append("write:\(terminalID)")
    }

    func resize(projectID: String, terminalID: String, columns: Int, rows: Int) async throws {
        recordedCalls.append("resize:\(terminalID)")
    }

    func kill(projectID: String, terminalID: String) async throws {
        recordedCalls.append("kill:\(terminalID)")
    }

    func release(projectID: String, terminalID: String) async throws {
        recordedCalls.append("release:\(terminalID)")
    }

    func detachOwner(projectID: String, terminalID: String) async throws {
        recordedCalls.append("detach-owner:\(terminalID)")
    }

    func setAgentTurn(projectID: String, terminalID: String, busy: Bool) async throws {
        recordedCalls.append("agent-turn:\(terminalID)")
    }

    func setControlLease(projectID: String, terminalID: String, active: Bool) async throws {
        recordedCalls.append("control-lease:\(terminalID)")
    }

    func disconnect() async {
        recordedDisconnectCount += 1
    }

    func calls() -> [String] { recordedCalls }
    func disconnectCount() -> Int { recordedDisconnectCount }
}
