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

    func testReleaseClassifiesAbsentTerminalAndRetiredGenerationWithoutGuessingARoute() async throws {
        let topology = makeTopology()
        let connectionID = "22222222-2222-4222-8222-222222222222"
        let current = RoutingControlClient(connectionInstanceID: connectionID)
        let draining = RoutingControlClient(connectionInstanceID: connectionID)
        let queue = ControlClientQueue([current, draining])
        let routes = BrokerGenerationRouteTable()
        let control = BrokerGenerationControlRouter(
            routes: routes,
            connectionInstanceID: connectionID,
            factory: { _ in queue.next() }
        )
        try await control.connect(to: topology, ownerID: "owner")

        do {
            _ = try await control.release(
                projectID: "project",
                terminalID: "not-yet-classified",
                brokerGenerationID: nil
            )
            XCTFail("An empty route map is not absence until inventory validates it")
        } catch {
            XCTAssertEqual(
                error as? BrokerClientError,
                .requestFailed("terminal generation unavailable")
            )
        }
        try await routes.replaceTerminalOwners(["moved-terminal": topology.current.id])
        do {
            _ = try await control.release(
                projectID: "project",
                terminalID: "moved-terminal",
                brokerGenerationID: topology.draining[0].id
            )
            XCTFail("Persisted generation evidence must not override current inventory")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
        try await routes.replaceTerminalOwners([:])

        let legacyAbsent = try await control.release(
            projectID: "project",
            terminalID: "legacy-absent",
            brokerGenerationID: nil
        )
        let retiredGeneration = try await control.release(
            projectID: "project",
            terminalID: "retired-terminal",
            brokerGenerationID: String(repeating: "f", count: 64)
        )
        let activeButAbsent = try await control.release(
            projectID: "project",
            terminalID: "active-absent",
            brokerGenerationID: topology.current.id
        )

        XCTAssertEqual(legacyAbsent, .terminalAbsent)
        XCTAssertEqual(retiredGeneration, .generationAbsent)
        XCTAssertEqual(activeButAbsent, .released)
        let currentCalls = await current.calls()
        let drainingCalls = await draining.calls()
        XCTAssertEqual(currentCalls, ["release:active-absent"])
        XCTAssertEqual(drainingCalls, [])
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

    func testInvalidInventoryRowPreservesTheLastPublishedRouteSnapshot() async throws {
        let topology = makeTopology()
        let current = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("current-terminal")])
        )
        let draining = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("draining-terminal")])
        )
        let queue = ObserverClientQueue([current, draining])
        let routes = BrokerGenerationRouteTable()
        let observer = BrokerGenerationObserverRouter(routes: routes, factory: { queue.next() })

        _ = try await observer.connect(to: topology)
        _ = try await observer.inventory()
        await current.failInventory(with: .invalidDiagnosticRow(index: 2))

        do {
            _ = try await observer.inventory()
            XCTFail("an invalid child row must reject the complete merged inventory")
        } catch {
            XCTAssertEqual(error as? BrokerInventoryError, .invalidDiagnosticRow(index: 2))
        }

        let retainedCurrentRoute = try await routes.generationID(for: "current-terminal")
        let retainedDrainingRoute = try await routes.generationID(for: "draining-terminal")
        XCTAssertEqual(retainedCurrentRoute, topology.current.id)
        XCTAssertEqual(retainedDrainingRoute, topology.draining[0].id)
    }

    func testInventoryRetriesWholeMergeWhenOneBrokerActivityEpochChanges() async throws {
        let topology = makeTopology()
        let current = RoutingObserverClient(statuses: [
            BrokerStatus(terminals: [terminal("stale-current")], activityEpoch: 10),
            BrokerStatus(terminals: [terminal("fresh-current")], activityEpoch: 11),
        ])
        let draining = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("stable-drain")], activityEpoch: 20)
        )
        let queue = ObserverClientQueue([current, draining])
        let routes = BrokerGenerationRouteTable()
        let observer = BrokerGenerationObserverRouter(routes: routes, factory: { queue.next() })

        _ = try await observer.connect(to: topology)
        let status = try await observer.inventory()
        let currentRoute = try await routes.generationID(for: "fresh-current")
        let drainRoute = try await routes.generationID(for: "stable-drain")
        let currentInventoryCount = await current.inventoryCount()
        let drainingInventoryCount = await draining.inventoryCount()

        XCTAssertEqual(status.terminals.map(\.id), ["fresh-current", "stable-drain"])
        XCTAssertEqual(currentRoute, topology.current.id)
        XCTAssertEqual(drainRoute, topology.draining[0].id)
        do {
            _ = try await routes.generationID(for: "stale-current")
            XCTFail("the discarded mixed snapshot must never replace live routes")
        } catch {
            XCTAssertEqual(
                error as? BrokerClientError,
                .requestFailed("terminal generation unavailable")
            )
        }
        XCTAssertEqual(currentInventoryCount, 4)
        XCTAssertEqual(drainingInventoryCount, 3)
    }

    func testMultiGenerationInventoryRejectsAMissingActivityEpoch() async throws {
        let topology = makeTopology()
        let unfenced = RoutingObserverClient(
            unfencedStatus: BrokerStatus(terminals: [terminal("unfenced")])
        )
        let draining = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("draining")], activityEpoch: 1)
        )
        let queue = ObserverClientQueue([unfenced, draining])
        let routes = BrokerGenerationRouteTable()
        let observer = BrokerGenerationObserverRouter(routes: routes, factory: { queue.next() })

        _ = try await observer.connect(to: topology)
        do {
            _ = try await observer.inventory()
            XCTFail("every generation in a merged inventory must provide an activity epoch")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .malformedResponse)
        }
        do {
            _ = try await routes.generationID(for: "unfenced")
            XCTFail("an unfenced inventory must not replace routes")
        } catch {
            XCTAssertEqual(
                error as? BrokerClientError,
                .requestFailed("terminal generation unavailable")
            )
        }
    }

    func testInventoryRetriesWhenRegistryRevisionChangesWithTheSameGenerationIDs() async throws {
        let original = makeTopology(registryTopologyVersion: 41)
        let revised = makeTopology(registryTopologyVersion: 42)
        let pause = RoutingInventoryPause()
        let staleCurrent = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("stale-current")], activityEpoch: 1),
            pause: pause
        )
        let staleDrain = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("stale-drain")], activityEpoch: 1)
        )
        let current = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("revised-current")], activityEpoch: 2)
        )
        let drain = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("revised-drain")], activityEpoch: 2)
        )
        let queue = ObserverClientQueue([staleCurrent, staleDrain, current, drain])
        let routes = BrokerGenerationRouteTable()
        let observer = BrokerGenerationObserverRouter(routes: routes, factory: { queue.next() })

        _ = try await observer.connect(to: original)
        let pending = Task { try await observer.inventory() }
        await pause.waitUntilPaused()
        _ = try await observer.connect(to: revised)
        await pause.resume()
        let status = try await pending.value
        let currentRoute = try await routes.generationID(for: "revised-current")
        let staleInventoryCount = await staleCurrent.inventoryCount()
        let currentInventoryCount = await current.inventoryCount()

        XCTAssertEqual(status.terminals.map(\.id), ["revised-current", "revised-drain"])
        XCTAssertEqual(currentRoute, revised.current.id)
        do {
            _ = try await routes.generationID(for: "stale-current")
            XCTFail("the old registry revision must not publish routes")
        } catch {
            XCTAssertEqual(
                error as? BrokerClientError,
                .requestFailed("terminal generation unavailable")
            )
        }
        XCTAssertEqual(staleInventoryCount, 1)
        XCTAssertEqual(currentInventoryCount, 2)
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

    func testControllerReconnectReplacesAChildThatReportedDisconnect() async throws {
        let topology = BrokerGenerationTopology(
            current: makeTopology().current,
            draining: []
        )
        let routes = BrokerGenerationRouteTable()
        let connectionID = "33333333-3333-4333-8333-333333333333"
        let failed = RoutingControlClient(connectionInstanceID: connectionID)
        let replacement = RoutingControlClient(connectionInstanceID: connectionID)
        let queue = ControlClientQueue([failed, replacement])
        let control = BrokerGenerationControlRouter(
            routes: routes,
            connectionInstanceID: connectionID,
            factory: { _ in queue.next() }
        )
        let signal = RoutingDisconnectSignal()
        await control.setDisconnectHandler { error in
            Task { await signal.record(error) }
        }

        try await control.connect(to: topology, ownerID: "owner")
        await failed.simulateDisconnect()
        for _ in 0..<100 {
            if await signal.count > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let disconnectCount = await signal.count
        XCTAssertEqual(disconnectCount, 1)

        try await control.connect(to: topology, ownerID: "owner")
        _ = try await control.createTerminal(
            projectID: "project",
            terminalID: "replacement-terminal",
            command: "/bin/sh",
            arguments: [],
            cwd: "/tmp",
            columns: 80,
            rows: 24
        )

        let failedConnectCount = await failed.connectCount()
        let replacementConnectCount = await replacement.connectCount()
        let replacementCalls = await replacement.calls()
        XCTAssertEqual(failedConnectCount, 1)
        XCTAssertEqual(replacementConnectCount, 1)
        XCTAssertEqual(replacementCalls, ["create:replacement-terminal"])
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

    /// A dead broker's socket vnode outlives it and answers ECONNREFUSED.
    /// One such corpse in the topology used to fail the WHOLE connect —
    /// taking the healthy current broker down with it — while the reaping
    /// that removes dead records ran behind the connect that could never
    /// succeed. A provably dead drain that refuses its dial is now skipped
    /// as detached; its terminals are gone with its process.
    func testAProvablyDeadDrainThatRefusesItsDialIsSkippedNotFatal() async throws {
        let topology = makeTopology()
        let currentObserver = RoutingObserverClient(
            status: BrokerStatus(terminals: [terminal("current-terminal")])
        )
        let observerQueue = ObserverClientQueue([currentObserver, RefusingObserverClient()])
        let routes = BrokerGenerationRouteTable()
        let observer = BrokerGenerationObserverRouter(
            routes: routes,
            factory: { observerQueue.next() }
        )

        _ = try await observer.connect(to: topology)
        let status = try await observer.inventory()

        XCTAssertEqual(status.terminals.map(\.id), ["current-terminal"])
        XCTAssertEqual(status.terminals[0].brokerGenerationID, topology.current.id)
    }

    /// A LIVE drain refusing its dial is an anomaly, not a corpse: its
    /// terminals exist and skipping it would silently drop them from the
    /// inventory. That failure stays loud.
    func testALiveDrainThatRefusesItsDialStillFailsTheConnect() async {
        let liveStartedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        let topology = BrokerGenerationTopology(
            current: generation(String(repeating: "a", count: 64), role: .current, startedAt: 2),
            draining: [
                generation(String(repeating: "b", count: 64), role: .draining, startedAt: liveStartedAt),
            ],
            registryTopologyVersion: 1
        )
        let currentObserver = RoutingObserverClient(status: BrokerStatus(terminals: []))
        let observerQueue = ObserverClientQueue([currentObserver, RefusingObserverClient()])
        let observer = BrokerGenerationObserverRouter(
            routes: BrokerGenerationRouteTable(),
            factory: { observerQueue.next() }
        )

        do {
            _ = try await observer.connect(to: topology)
            XCTFail("a live drain's dial failure must fail the connect")
        } catch let error as BrokerClientError {
            XCTAssertEqual(error, .socketFailure(61))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// The write lane dials seconds after the observer lane — inventory and
    /// upgrade probes sit between them — so a drain can die in the gap. The
    /// control connect must skip the corpse exactly as the observer does;
    /// failing it silently cost every terminal its writes until the next
    /// reconnect.
    func testTheControlLaneAlsoSkipsAProvablyDeadDrainThatRefusesItsDial() async throws {
        let topology = makeTopology()
        let connectionID = "33333333-3333-4333-8333-333333333333"
        let current = RoutingControlClient(connectionInstanceID: connectionID)
        let refusing = RoutingControlClient(
            connectionInstanceID: connectionID,
            connectError: .socketFailure(61)
        )
        let queue = ControlClientQueue([current, refusing])
        let routes = BrokerGenerationRouteTable()
        let control = BrokerGenerationControlRouter(
            routes: routes,
            connectionInstanceID: connectionID,
            factory: { _ in queue.next() }
        )

        try await control.connect(to: topology, ownerID: "owner")
        _ = try await control.createTerminal(
            projectID: "project",
            terminalID: "new-terminal",
            command: "/bin/sh",
            arguments: [],
            cwd: "/tmp",
            columns: 80,
            rows: 24
        )

        let currentCalls = await current.calls()
        XCTAssertEqual(currentCalls, ["create:new-terminal"])
    }

    /// The tolerance is three-conditional on purpose: draining role, provably
    /// dead process, and an unreachable-endpoint failure. An authentication
    /// or protocol rejection means something ANSWERED — whatever answered is
    /// not a corpse, whatever the record's age claims.
    func testDialPolicyToleratesOnlyUnreachableCorpses() {
        let dead = generation(String(repeating: "b", count: 64), role: .draining, startedAt: 1)
        let liveDrain = generation(
            String(repeating: "a", count: 64),
            role: .draining,
            startedAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        let deadShapedCurrent = generation(String(repeating: "d", count: 64), role: .current, startedAt: 1)

        XCTAssertTrue(BrokerGenerationDialPolicy.tolerates(BrokerClientError.socketFailure(61), from: dead))
        XCTAssertTrue(BrokerGenerationDialPolicy.tolerates(BrokerClientError.socketFailure(2), from: dead))
        XCTAssertTrue(BrokerGenerationDialPolicy.tolerates(BrokerClientError.connectionTimedOut, from: dead))
        XCTAssertFalse(BrokerGenerationDialPolicy.tolerates(BrokerClientError.authenticationRejected, from: dead))
        XCTAssertFalse(BrokerGenerationDialPolicy.tolerates(BrokerClientError.protocolMismatch, from: dead))
        XCTAssertFalse(BrokerGenerationDialPolicy.tolerates(BrokerClientError.socketFailure(61), from: liveDrain))
        XCTAssertFalse(
            BrokerGenerationDialPolicy.tolerates(BrokerClientError.socketFailure(61), from: deadShapedCurrent)
        )
    }

    /// The pre-boot dead rule corroborates against the kernel's own start
    /// time for the pid holder — kernel starts never move, unlike boottime,
    /// which steps with wall-clock corrections. What a real process can
    /// prove here: the kernel reports a usable start for a live pid, a
    /// record whose startedAt matches its live holder is not dead, an
    /// ancient startedAt on a live pid IS provably dead exactly because the
    /// kernel start disagrees, and an invalid pid yields no start at all.
    func testALiveProcessWhoseStartMatchesItsRecordIsNeverProvablyDead() throws {
        let processStart = try XCTUnwrap(
            BrokerInfo.processStartTimeMilliseconds(pid: getpid())
        )
        let matching = generation(
            String(repeating: "a", count: 64),
            role: .draining,
            startedAt: processStart
        )
        XCTAssertFalse(matching.info.isProcessProvablyDead)

        let ancient = generation(String(repeating: "b", count: 64), role: .draining, startedAt: 1)
        XCTAssertTrue(ancient.info.isProcessProvablyDead)

        XCTAssertNil(BrokerInfo.processStartTimeMilliseconds(pid: -1))
    }

    /// The current generation is never skippable, whatever its record's age
    /// claims — there is no session service without it.
    func testTheCurrentGenerationsDialFailureIsAlwaysFatal() async {
        let topology = makeTopology()
        let observerQueue = ObserverClientQueue([RefusingObserverClient()])
        let observer = BrokerGenerationObserverRouter(
            routes: BrokerGenerationRouteTable(),
            factory: { observerQueue.next() }
        )

        do {
            _ = try await observer.connect(to: topology)
            XCTFail("the current generation's dial failure must fail the connect")
        } catch let error as BrokerClientError {
            XCTAssertEqual(error, .socketFailure(61))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    private func makeTopology(registryTopologyVersion: Int64 = 1) -> BrokerGenerationTopology {
        let currentDigest = String(repeating: "a", count: 64)
        let drainingDigest = String(repeating: "b", count: 64)
        return BrokerGenerationTopology(
            current: generation(currentDigest, role: .current, startedAt: 2),
            draining: [generation(drainingDigest, role: .draining, startedAt: 1)],
            registryTopologyVersion: registryTopologyVersion
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

/// Stands in for a generation whose socket answers ECONNREFUSED — the exact
/// behavior of a socket vnode whose broker is gone.
private actor RefusingObserverClient: ObserveOnlyBrokerServing {
    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async {}
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {}
    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        throw BrokerClientError.socketFailure(61)
    }
    func inventory() async throws -> BrokerStatus {
        throw BrokerClientError.notConnected
    }
    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        throw BrokerClientError.notConnected
    }
    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {
        throw BrokerClientError.notConnected
    }
    func disconnect() async {}
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
    private var statuses: [BrokerStatus]
    private var inventoryError: BrokerInventoryError?
    private let pause: RoutingInventoryPause?
    private var recordedInventoryCount = 0
    private var recordedCalls: [String] = []
    private var recordedDisconnectCount = 0
    private var eventHandler: (@Sendable (BrokerEvent) -> Void)?
    private var disconnectHandler: (@Sendable (any Error) -> Void)?

    init(status: BrokerStatus) {
        self.statuses = [Self.withDefaultActivityEpoch(status)]
        pause = nil
    }

    init(unfencedStatus status: BrokerStatus) {
        self.statuses = [status]
        pause = nil
    }

    init(status: BrokerStatus, pause: RoutingInventoryPause) {
        self.statuses = [Self.withDefaultActivityEpoch(status)]
        self.pause = pause
    }

    init(statuses: [BrokerStatus]) {
        precondition(!statuses.isEmpty)
        self.statuses = statuses.map(Self.withDefaultActivityEpoch)
        pause = nil
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

    func inventory() async throws -> BrokerStatus {
        recordedInventoryCount += 1
        if let inventoryError { throw inventoryError }
        if recordedInventoryCount == 1, let pause { await pause.pause() }
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses[0]
    }

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
    func failInventory(with error: BrokerInventoryError) { inventoryError = error }
    func inventoryCount() -> Int { recordedInventoryCount }
    func disconnectCount() -> Int { recordedDisconnectCount }

    private static func withDefaultActivityEpoch(_ status: BrokerStatus) -> BrokerStatus {
        BrokerStatus(
            terminals: status.terminals,
            activityEpoch: status.activityEpoch ?? 1
        )
    }
}

/// Deterministic suspension seam: the test waits until a child inventory is
/// in flight, publishes a new registry revision, then lets the stale call
/// return. No wall-clock sleeps or scheduler assumptions are involved.
private actor RoutingInventoryPause {
    private var didPause = false
    private var didResume = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        didPause = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !didResume else { return }
        await withCheckedContinuation { resumeWaiters.append($0) }
    }

    func waitUntilPaused() async {
        if didPause { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        didResume = true
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor RoutingControlClient: BrokerControlServing {
    nonisolated let connectionInstanceID: String
    private let connectError: BrokerClientError?
    private var recordedCalls: [String] = []
    private var recordedDisconnectCount = 0
    private var recordedConnectCount = 0
    private var disconnectHandler: (@Sendable (any Error) -> Void)?

    init(connectionInstanceID: String, connectError: BrokerClientError? = nil) {
        self.connectionInstanceID = connectionInstanceID
        self.connectError = connectError
    }

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {
        disconnectHandler = handler
    }

    func connect(to info: BrokerInfo, ownerID: String) async throws {
        recordedConnectCount += 1
        if let connectError { throw connectError }
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
    func connectCount() -> Int { recordedConnectCount }
    func disconnectCount() -> Int { recordedDisconnectCount }
    func simulateDisconnect() {
        disconnectHandler?(BrokerClientError.connectionClosed)
    }
}

private actor RoutingDisconnectSignal {
    private(set) var count = 0

    func record(_ error: any Error) {
        count += 1
    }
}
