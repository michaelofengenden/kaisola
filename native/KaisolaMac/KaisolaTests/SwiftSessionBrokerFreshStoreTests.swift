import Foundation
import XCTest
@testable import KaisolaSessionBrokerCore

final class SwiftSessionBrokerFreshStoreTests: XCTestCase {
    func testValidCreateForwardsTheCurrentNodeFieldsAndPublishesDynamicInventory() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        let request = createRequest(cols: 2_000, rows: 3_000)

        let creation = try await store.create(client: client, request: request)

        XCTAssertFalse(creation.existed)
        XCTAssertEqual(creation.id, request.id)
        XCTAssertEqual(creation.pid, 10_000)
        XCTAssertEqual(creation.cols, 1_000)
        XCTAssertEqual(creation.rows, 1_000)
        XCTAssertEqual(creation.endOffset, 0)
        XCTAssertNotNil(UUID(uuidString: creation.streamEpoch))

        let spawnRequests = await factory.requests
        XCTAssertEqual(spawnRequests, [FreshTerminalSpawnRequest(
            command: "/bin/zsh",
            arguments: ["-il"],
            environment: ["TERM": "xterm-256color"],
            cwd: "/tmp/project-a",
            columns: 1_000,
            rows: 1_000
        )])

        await factory.emit(Data("🙂".utf8), fromProcessAt: 0)
        try await eventually {
            await store.inventory().first?.endOffset == 4
        }
        let inventory = await store.inventory()
        let row = try XCTUnwrap(inventory.first)
        let owner = "\(client.instanceID)|owner-a|project-a"
        XCTAssertEqual(row.id, "term-project-a-1234abcd")
        XCTAssertEqual(row.owner, owner)
        XCTAssertEqual(row.lastOwner, owner)
        XCTAssertEqual(row.streamEpoch, creation.streamEpoch)
        XCTAssertEqual(row.endOffset, 4)
        XCTAssertEqual(row.cwd, "/tmp/project-a")
        XCTAssertEqual(row.cols, 1_000)
        XCTAssertEqual(row.rows, 1_000)
        XCTAssertFalse(row.exited)

        _ = try await store.release(client: client, identity: identity())
    }

    func testRestoreIsRefusedBeforeTheFactoryCanSpawn() async {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)

        await assertStoreError(.restoreUnsupported) {
            try await store.create(
                client: self.controller(),
                request: self.createRequest(restore: true)
            )
        }
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 0)
    }

    func testCreateRejectsMalformedIdentityCommandAndCWDWithoutSpawning() async {
        let invalid: [(FreshTerminalCreateRequest, FreshTerminalStoreError)] = [
            (createRequest(ownerID: "0"), .invalidOwner),
            (createRequest(ownerID: "owner with spaces"), .invalidOwner),
            (createRequest(projectID: "bad/project"), .invalidProject),
            (createRequest(id: ""), .invalidTerminalID),
            (createRequest(id: String(repeating: "x", count: 241)), .invalidTerminalID),
            (createRequest(command: ""), .invalidCommand),
            (createRequest(command: "/bin/zsh\0oops"), .invalidCommand),
            (createRequest(cwd: "relative/path"), .invalidCWD),
            (createRequest(cwd: "/tmp/project\0a"), .invalidCWD),
        ]

        for (request, expected) in invalid {
            let factory = FakeFreshTerminalFactory()
            let store = FreshTerminalStore(factory: factory)
            await assertStoreError(expected) {
                try await store.create(client: self.controller(), request: request)
            }
            let spawnCount = await factory.spawnCount
            XCTAssertEqual(spawnCount, 0, "\(expected)")
        }

        let malformedClient = BrokerAuthenticatedClient(
            instanceID: "not-a-uuid",
            role: .controller,
            negotiatedFeatures: []
        )
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        await assertStoreError(.invalidClientIdentity) {
            try await store.create(client: malformedClient, request: self.createRequest())
        }
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 0)
    }

    func testCreateEnforcesNodeArgumentAndEnvironmentBoundsWithoutSpawning() async {
        let tooManyArguments = Array(repeating: "x", count: 201)
        let oversizedArgument = [String(repeating: "x", count: 16 * 1_024 + 1)]
        let oversizedArguments = Array(repeating: String(repeating: "x", count: 16 * 1_024), count: 17)
        let tooManyEnvironmentEntries = Dictionary(
            uniqueKeysWithValues: (0...256).map { ("KEY_\($0)", "x") }
        )
        let oversizedEnvironmentValue = ["KEY": String(repeating: "x", count: 64 * 1_024 + 1)]
        let oversizedEnvironment = Dictionary(
            uniqueKeysWithValues: (0..<5).map { ("KEY_\($0)", String(repeating: "x", count: 64 * 1_024)) }
        )
        let invalid: [(FreshTerminalCreateRequest, FreshTerminalStoreError)] = [
            (createRequest(args: tooManyArguments), .invalidArguments),
            (createRequest(args: oversizedArgument), .invalidArguments),
            (createRequest(args: oversizedArguments), .invalidArguments),
            (createRequest(args: ["bad\0argument"]), .invalidArguments),
            (createRequest(env: tooManyEnvironmentEntries), .invalidEnvironment),
            (createRequest(env: oversizedEnvironmentValue), .invalidEnvironment),
            (createRequest(env: oversizedEnvironment), .invalidEnvironment),
            (createRequest(env: ["BAD=KEY": "value"]), .invalidEnvironment),
            (createRequest(env: ["KEY": "bad\0value"]), .invalidEnvironment),
        ]

        for (request, expected) in invalid {
            let factory = FakeFreshTerminalFactory()
            let store = FreshTerminalStore(factory: factory)
            await assertStoreError(expected) {
                try await store.create(client: self.controller(), request: request)
            }
            let spawnCount = await factory.spawnCount
            XCTAssertEqual(spawnCount, 0, "\(expected)")
        }
    }

    func testCreateRejectsNonPositiveGeometryAndClampsLargeGeometry() async throws {
        for (request, field) in [
            (createRequest(cols: 0), "cols"),
            (createRequest(rows: -1), "rows"),
        ] {
            let factory = FakeFreshTerminalFactory()
            let store = FreshTerminalStore(factory: factory)
            await assertStoreError(.invalidGeometry(field: field)) {
                try await store.create(client: self.controller(), request: request)
            }
            let spawnCount = await factory.spawnCount
            XCTAssertEqual(spawnCount, 0)
        }

        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        _ = try await store.create(
            client: controller(),
            request: createRequest(cols: Int.max, rows: Int.max)
        )
        let requests = await factory.requests
        XCTAssertEqual(requests.first?.columns, 1_000)
        XCTAssertEqual(requests.first?.rows, 1_000)
        _ = try await store.release(client: controller(), identity: identity())
    }

    func testCapacityIsSixtyFourLiveTerminals() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()

        for index in 0..<64 {
            _ = try await store.create(
                client: client,
                request: createRequest(id: String(format: "term-project-a-%08x", index))
            )
        }
        await assertStoreError(.capacityExceeded(maximum: 64)) {
            try await store.create(
                client: client,
                request: self.createRequest(id: "term-project-a-ffffffff")
            )
        }
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 64)
        try await store.shutdown()
    }

    func testFailedSameIDReplacementPreservesTheExitedSnapshotAndActivityEpoch() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        let retainedRequest = createRequest(id: "term-project-a-retained")

        _ = try await store.create(client: client, request: retainedRequest)
        await factory.emit(Data("retained output".utf8), fromProcessAt: 0)
        let retainedProcessValue = await factory.process(at: 0)
        let retainedProcess = try XCTUnwrap(retainedProcessValue)
        retainedProcess.confirmExit()
        try await eventually {
            await store.inventory().contains { record in
                record.id == retainedRequest.id && record.exited
            }
        }

        for index in 0..<64 {
            _ = try await store.create(
                client: client,
                request: createRequest(id: String(format: "term-project-a-%08x", index))
            )
        }
        let snapshotBeforeValue = try await store.snapshot(
            id: retainedRequest.id,
            projectID: retainedRequest.projectID
        )
        let snapshotBefore = try XCTUnwrap(snapshotBeforeValue)
        let epochBefore = await store.currentActivityEpoch()

        await assertStoreError(.capacityExceeded(maximum: 64)) {
            try await store.create(client: client, request: retainedRequest)
        }

        let snapshotAfterValue = try await store.snapshot(
            id: retainedRequest.id,
            projectID: retainedRequest.projectID
        )
        let snapshotAfter = try XCTUnwrap(snapshotAfterValue)
        XCTAssertEqual(snapshotAfter, snapshotBefore)
        let epochAfter = await store.currentActivityEpoch()
        XCTAssertEqual(epochAfter, epochBefore)
        let retainedRecord = await store.inventory().first { $0.id == retainedRequest.id }
        XCTAssertTrue(try XCTUnwrap(retainedRecord).exited)
        try await store.shutdown()
    }

    func testConcurrentRepeatedIDNeverStartsASecondProcess() async throws {
        let factory = FakeFreshTerminalFactory()
        await factory.setSpawnsPaused(true)
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        let request = createRequest()
        let first = Task { try await store.create(client: client, request: request) }

        try await eventually { await factory.spawnCount == 1 }
        await assertStoreError(.terminalCreationInProgress) {
            try await store.create(client: client, request: request)
        }
        let pendingSpawnCount = await factory.spawnCount
        XCTAssertEqual(pendingSpawnCount, 1)

        await factory.resumeSpawns()
        _ = try await first.value
        let repeated = try await store.create(client: client, request: request)
        XCTAssertTrue(repeated.existed)
        let finalSpawnCount = await factory.spawnCount
        XCTAssertEqual(finalSpawnCount, 1)
        _ = try await store.release(client: client, identity: identity())
    }

    func testReleaseDuringSpawnCancelsAndReapsBeforeReturning() async throws {
        let factory = FakeFreshTerminalFactory()
        await factory.setSpawnsPaused(true)
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        let request = createRequest()
        let terminalIdentity = identity()
        let creating = Task {
            try await store.create(client: client, request: request)
        }

        try await eventually { await factory.spawnCount == 1 }
        let releasing = Task {
            try await store.release(client: client, identity: terminalIdentity)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        await factory.resumeSpawns()

        do {
            _ = try await creating.value
            XCTFail("cancelled create unexpectedly succeeded")
        } catch {
            XCTAssertEqual(
                error as? FreshTerminalStoreError,
                .terminalReleaseInProgress
            )
        }
        let released = try await releasing.value
        XCTAssertTrue(released.released)
        XCTAssertFalse(released.alreadyAbsent)
        let releasedInventory = await store.inventory()
        XCTAssertEqual(releasedInventory, [])
        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)
        XCTAssertEqual(process.terminationCount, 1)
    }

    func testRepeatedLiveCreateAdoptsWithinProjectButMutationsRequireTheCurrentOwner() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let firstClient = controller()
        let secondClient = controller(instanceID: "123e4567-e89b-42d3-a456-426614174001")
        _ = try await store.create(client: firstClient, request: createRequest())

        let adopted = try await store.create(
            client: secondClient,
            request: createRequest(ownerID: "owner-b")
        )
        XCTAssertTrue(adopted.existed)
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 1)
        let owner = "\(secondClient.instanceID)|owner-b|project-a"
        let inventory = await store.inventory()
        let row = try XCTUnwrap(inventory.first)
        XCTAssertEqual(row.owner, owner)
        XCTAssertEqual(row.lastOwner, owner)

        await assertStoreError(.terminalAccessDenied) {
            try await store.write(
                client: firstClient,
                identity: self.identity(),
                data: "stale"
            )
        }
        await assertStoreError(.terminalAccessDenied) {
            try await store.create(
                client: firstClient,
                request: self.createRequest(projectID: "project-b")
            )
        }

        _ = try await store.release(
            client: secondClient,
            identity: identity(ownerID: "owner-b")
        )
    }

    func testOnlyAControllerWithAValidOwnerCanMutate() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let observer = BrokerAuthenticatedClient(
            instanceID: controller().instanceID,
            role: .observer,
            negotiatedFeatures: []
        )

        await assertStoreError(.controllerRequired) {
            try await store.create(client: observer, request: self.createRequest())
        }
        await assertStoreError(.invalidOwner) {
            try await store.create(
                client: self.controller(),
                request: self.createRequest(ownerID: "0")
            )
        }
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 0)
    }

    func testWriteUsesUTF8BytesAndRefusesPayloadsOverSixtyFourKiB() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        _ = try await store.create(client: client, request: createRequest())
        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)

        let accepted = String(repeating: "x", count: 64 * 1_024)
        try await store.write(client: client, identity: identity(), data: accepted)
        XCTAssertEqual(process.writes.map(\.count), [64 * 1_024])

        let rejected = accepted + "🙂"
        await assertStoreError(.writePayloadTooLarge(
            maximumBytes: 64 * 1_024,
            actualBytes: 64 * 1_024 + 4
        )) {
            try await store.write(client: client, identity: self.identity(), data: rejected)
        }
        XCTAssertEqual(process.writes.count, 1)

        process.confirmExit()
        try await eventually { await store.inventory().first?.exited == true }
        await assertStoreError(.terminalEnded) {
            try await store.write(client: client, identity: self.identity(), data: "late")
        }
        _ = try await store.release(client: client, identity: identity())
    }

    func testOutputSnapshotSerializesUTF8RepairAndFinishesBeforeExit() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        _ = try await store.create(client: client, request: createRequest())
        let epochBeforeOutput = await store.currentActivityEpoch()

        await factory.emit(Data([0xF0, 0x9F]), fromProcessAt: 0)
        await factory.emit(Data([0x99, 0x82]), fromProcessAt: 0)
        await factory.emit(Data([0xFF]), fromProcessAt: 0)
        await factory.emit(Data([0xE2]), fromProcessAt: 0)
        let streamingSnapshot = try await store.snapshot(
            id: createRequest().id,
            projectID: "project-a"
        )
        var snapshot = try XCTUnwrap(streamingSnapshot)
        XCTAssertEqual(snapshot.output, "🙂�")
        XCTAssertEqual(snapshot.startOffset, 0)
        XCTAssertEqual(snapshot.endOffset, 7)
        XCTAssertFalse(snapshot.exited)
        let epochAfterOutput = await store.currentActivityEpoch()
        XCTAssertGreaterThan(epochAfterOutput, epochBeforeOutput)

        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)
        process.confirmExit()
        try await eventually {
            (try? await store.snapshot(
                id: self.createRequest().id,
                projectID: "project-a"
            ))?.exited == true
        }
        let finalSnapshot = try await store.snapshot(
            id: createRequest().id,
            projectID: "project-a"
        )
        snapshot = try XCTUnwrap(finalSnapshot)
        XCTAssertEqual(snapshot.output, "🙂��")
        XCTAssertEqual(snapshot.endOffset, 10)
        XCTAssertTrue(snapshot.exited)
        let epochAfterExit = await store.currentActivityEpoch()
        XCTAssertGreaterThan(epochAfterExit, epochAfterOutput)
        _ = try await store.release(client: client, identity: identity())
    }

    func testResizeClampsAtTheProcessBoundaryAndOnlyCommitsAcceptedGeometry() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        _ = try await store.create(client: client, request: createRequest())
        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)

        try await store.resize(
            client: client,
            identity: identity(),
            cols: 2_000,
            rows: 3_000
        )
        XCTAssertEqual(process.resizes, [FakeFreshTerminalProcess.Size(columns: 1_000, rows: 1_000)])
        var inventory = await store.inventory()
        var row = try XCTUnwrap(inventory.first)
        XCTAssertEqual(row.cols, 1_000)
        XCTAssertEqual(row.rows, 1_000)

        process.failNextResize()
        await assertStoreError(.processOperationFailed(operation: "resize")) {
            try await store.resize(
                client: client,
                identity: self.identity(),
                cols: 120,
                rows: 50
            )
        }
        inventory = await store.inventory()
        row = try XCTUnwrap(inventory.first)
        XCTAssertEqual(row.cols, 1_000)
        XCTAssertEqual(row.rows, 1_000)

        await assertStoreError(.invalidGeometry(field: "rows")) {
            try await store.resize(
                client: client,
                identity: self.identity(),
                cols: 80,
                rows: 0
            )
        }
        _ = try await store.release(client: client, identity: identity())
    }

    func testSignalAndKillReachTheProcessWithoutRemovingItsRecord() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        _ = try await store.create(client: client, request: createRequest())
        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)

        try await store.signal(
            client: client,
            identity: identity(),
            signal: .interrupt
        )
        try await store.kill(client: client, identity: identity())
        XCTAssertEqual(process.signals, [2, 9])
        let inventory = await store.inventory()
        XCTAssertEqual(inventory.count, 1)
        XCTAssertFalse(try XCTUnwrap(inventory.first).exited)

        process.confirmExit()
        try await eventually { await store.inventory().first?.exited == true }
        _ = try await store.release(client: client, identity: identity())
    }

    func testReleaseIsIdempotentAndRetainsTheRecordUntilTerminationIsConfirmed() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        _ = try await store.create(client: client, request: createRequest())
        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)
        process.setTerminationMode(.manual)
        let terminalIdentity = identity()

        let releasing = Task {
            try await store.release(client: client, identity: terminalIdentity)
        }
        try await eventually { process.terminationCount == 1 }
        let pendingInventory = await store.inventory()
        XCTAssertEqual(pendingInventory.count, 1)

        process.confirmExit()
        let first = try await releasing.value
        XCTAssertTrue(first.released)
        XCTAssertFalse(first.alreadyAbsent)
        let releasedInventory = await store.inventory()
        XCTAssertEqual(releasedInventory, [])

        let repeated = try await store.release(client: client, identity: identity())
        XCTAssertTrue(repeated.released)
        XCTAssertTrue(repeated.alreadyAbsent)
        XCTAssertEqual(process.terminationCount, 1)
    }

    func testFailedReleaseKeepsTheRecordRetryable() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        _ = try await store.create(client: client, request: createRequest())
        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)
        process.setTerminationMode(.fail)

        await assertStoreError(.processOperationFailed(operation: "release")) {
            try await store.release(client: client, identity: self.identity())
        }
        let failedInventory = await store.inventory()
        XCTAssertEqual(failedInventory.count, 1)

        process.setTerminationMode(.immediate)
        let retried = try await store.release(client: client, identity: identity())
        XCTAssertTrue(retried.released)
        XCTAssertEqual(process.terminationCount, 2)
        let releasedInventory = await store.inventory()
        XCTAssertEqual(releasedInventory, [])
    }

    func testNaturalExitFreesCapacityAndTheSameIDCanStartFresh() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        let first = try await store.create(client: client, request: createRequest())
        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)
        process.confirmExit()
        try await eventually { await store.inventory().first?.exited == true }

        let second = try await store.create(client: client, request: createRequest())
        XCTAssertFalse(second.existed)
        XCTAssertNotEqual(second.streamEpoch, first.streamEpoch)
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 2)
        _ = try await store.release(client: client, identity: identity())
    }

    func testShutdownReapsEveryTerminalAndRejectsLaterCreates() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        for index in 0..<2 {
            _ = try await store.create(
                client: client,
                request: createRequest(id: String(format: "term-project-a-%08x", index))
            )
        }

        try await store.shutdown()

        let inventory = await store.inventory()
        XCTAssertEqual(inventory, [])
        let firstSpawnedProcess = await factory.process(at: 0)
        let secondSpawnedProcess = await factory.process(at: 1)
        let firstProcess = try XCTUnwrap(firstSpawnedProcess)
        let secondProcess = try XCTUnwrap(secondSpawnedProcess)
        XCTAssertEqual(firstProcess.terminationCount, 1)
        XCTAssertEqual(secondProcess.terminationCount, 1)
        await assertStoreError(.shuttingDown) {
            try await store.create(
                client: client,
                request: self.createRequest(id: "term-project-a-deadbeef")
            )
        }
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 2)
    }

    func testShutdownRetainsSpawnedChildAfterFailedCleanupAndRetriesIt() async throws {
        let factory = FakeFreshTerminalFactory()
        await factory.setSpawnsPaused(true)
        let store = FreshTerminalStore(factory: factory)
        let client = controller()
        let request = createRequest()
        let creating = Task {
            try await store.create(client: client, request: request)
        }

        try await eventually { await factory.spawnCount == 1 }
        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)
        process.setTerminationMode(.fail)
        let shuttingDown = Task { try await store.shutdown() }
        try await Task.sleep(nanoseconds: 10_000_000)
        await factory.resumeSpawns()

        do {
            _ = try await creating.value
            XCTFail("create unexpectedly succeeded during shutdown")
        } catch {
            XCTAssertEqual(error as? FreshTerminalStoreError, .shuttingDown)
        }
        do {
            try await shuttingDown.value
            XCTFail("shutdown unexpectedly hid failed cleanup")
        } catch {
            XCTAssertEqual(
                error as? FreshTerminalStoreError,
                .shutdownIncomplete(ids: [createRequest().id])
            )
        }
        let failedInventory = await store.inventory()
        XCTAssertEqual(failedInventory.map(\.id), [createRequest().id])

        process.setTerminationMode(.immediate)
        try await store.shutdown()
        let finalInventory = await store.inventory()
        XCTAssertEqual(finalInventory, [])
        XCTAssertEqual(process.terminationCount, 2)
    }

    func testExitedScrollbackRetentionIsBounded() async throws {
        let factory = FakeFreshTerminalFactory()
        let store = FreshTerminalStore(factory: factory)
        let client = controller()

        for index in 0..<65 {
            let id = String(format: "term-project-a-%08x", index)
            _ = try await store.create(
                client: client,
                request: createRequest(id: id)
            )
            let spawnedProcess = await factory.process(at: index)
            let process = try XCTUnwrap(spawnedProcess)
            process.confirmExit()
            try await eventually {
                await store.inventory().contains { $0.id == id && $0.exited }
            }
        }

        let retained = await store.inventory()
        XCTAssertEqual(retained.count, 64)
        XCTAssertFalse(retained.contains { $0.id == "term-project-a-00000000" })
        XCTAssertTrue(retained.allSatisfy(\.exited))
    }

    private func controller(
        instanceID: String = "123e4567-e89b-42d3-a456-426614174000"
    ) -> BrokerAuthenticatedClient {
        BrokerAuthenticatedClient(
            instanceID: instanceID,
            role: .controller,
            negotiatedFeatures: []
        )
    }

    private func identity(
        ownerID: String = "owner-a",
        projectID: String = "project-a",
        id: String = "term-project-a-1234abcd"
    ) -> FreshTerminalIdentity {
        FreshTerminalIdentity(ownerID: ownerID, projectID: projectID, id: id)
    }

    private func createRequest(
        ownerID: String = "owner-a",
        projectID: String = "project-a",
        id: String = "term-project-a-1234abcd",
        command: String = "/bin/zsh",
        args: [String] = ["-il"],
        cwd: String = "/tmp/project-a",
        env: [String: String] = ["TERM": "xterm-256color"],
        cols: Int = 80,
        rows: Int = 24,
        restore: Bool = false
    ) -> FreshTerminalCreateRequest {
        FreshTerminalCreateRequest(
            ownerID: ownerID,
            projectID: projectID,
            id: id,
            command: command,
            args: args,
            cwd: cwd,
            env: env,
            cols: cols,
            rows: rows,
            restore: restore
        )
    }

    private func assertStoreError<T>(
        _ expected: FreshTerminalStoreError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? FreshTerminalStoreError, expected, file: file, line: line)
        }
    }

    private func eventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true", file: file, line: line)
        throw FakeFreshTerminalError.requested
    }
}

private enum FakeFreshTerminalError: Error {
    case requested
}

private final class FakeFreshTerminalProcess: FreshTerminalProcess, @unchecked Sendable {
    struct Size: Equatable {
        let columns: Int
        let rows: Int
    }

    enum TerminationMode {
        case immediate
        case manual
        case fail
    }

    let pid: Int32
    private let lock = NSLock()
    private var storedWrites: [Data] = []
    private var storedResizes: [Size] = []
    private var storedSignals: [Int32] = []
    private var shouldFailResize = false
    private var mode = TerminationMode.immediate
    private var storedTerminationCount = 0
    private var exited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminationWaiters: [CheckedContinuation<Void, any Error>] = []

    init(pid: Int32) {
        self.pid = pid
    }

    var writes: [Data] { withLock { storedWrites } }
    var resizes: [Size] { withLock { storedResizes } }
    var signals: [Int32] { withLock { storedSignals } }
    var terminationCount: Int { withLock { storedTerminationCount } }

    func write(_ data: Data) throws {
        withLock { storedWrites.append(data) }
    }

    func resize(columns: Int, rows: Int) throws {
        try withLock {
            if shouldFailResize {
                shouldFailResize = false
                throw FakeFreshTerminalError.requested
            }
            storedResizes.append(Size(columns: columns, rows: rows))
        }
    }

    func send(signal: Int32) throws {
        withLock { storedSignals.append(signal) }
    }

    func waitForFreshTerminalExit() async {
        await withCheckedContinuation { continuation in
            let resumeNow = withLock {
                if exited { return true }
                exitWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func terminateFreshTerminal(graceNanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var exitContinuations: [CheckedContinuation<Void, Never>] = []
            let action: TerminationMode = withLock {
                storedTerminationCount += 1
                switch mode {
                case .immediate:
                    exited = true
                    exitContinuations = exitWaiters
                    exitWaiters.removeAll()
                case .manual:
                    terminationWaiters.append(continuation)
                case .fail:
                    break
                }
                return mode
            }
            exitContinuations.forEach { $0.resume() }
            switch action {
            case .immediate:
                continuation.resume()
            case .manual:
                break
            case .fail:
                continuation.resume(throwing: FakeFreshTerminalError.requested)
            }
        }
    }

    func setTerminationMode(_ mode: TerminationMode) {
        withLock { self.mode = mode }
    }

    func failNextResize() {
        withLock { shouldFailResize = true }
    }

    func confirmExit() {
        var exits: [CheckedContinuation<Void, Never>] = []
        var terminations: [CheckedContinuation<Void, any Error>] = []
        withLock {
            guard !exited else { return }
            exited = true
            exits = exitWaiters
            exitWaiters.removeAll()
            terminations = terminationWaiters
            terminationWaiters.removeAll()
        }
        exits.forEach { $0.resume() }
        terminations.forEach { $0.resume() }
    }

    @discardableResult
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private actor FakeFreshTerminalFactory: FreshTerminalProcessFactory {
    private(set) var requests: [FreshTerminalSpawnRequest] = []
    private var processes: [FakeFreshTerminalProcess] = []
    private var outputs: [@Sendable (Data) -> Void] = []
    private var spawnsPaused = false
    private var spawnWaiters: [CheckedContinuation<Void, Never>] = []

    var spawnCount: Int { processes.count }

    func spawn(
        request: FreshTerminalSpawnRequest,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> any FreshTerminalProcess {
        let process = FakeFreshTerminalProcess(pid: Int32(10_000 + processes.count))
        requests.append(request)
        processes.append(process)
        outputs.append(onOutput)
        if spawnsPaused {
            await withCheckedContinuation { spawnWaiters.append($0) }
        }
        return process
    }

    func process(at index: Int) -> FakeFreshTerminalProcess? {
        processes.indices.contains(index) ? processes[index] : nil
    }

    func emit(_ data: Data, fromProcessAt index: Int) {
        guard outputs.indices.contains(index) else { return }
        outputs[index](data)
    }

    func setSpawnsPaused(_ paused: Bool) {
        spawnsPaused = paused
    }

    func resumeSpawns() {
        spawnsPaused = false
        let waiters = spawnWaiters
        spawnWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
