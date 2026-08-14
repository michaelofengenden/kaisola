import Darwin
import Foundation
import XCTest
@testable import KaisolaSessionBrokerCore

final class SwiftSessionBrokerFreshWireTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)
    private let digest = String(repeating: "b", count: 64)
    private let controllerInstanceID = "123e4567-e89b-42d3-a456-426614174000"
    private let observerInstanceID = "123e4567-e89b-42d3-a456-426614174001"
    private let secondControllerInstanceID = "123e4567-e89b-42d3-a456-426614174002"
    private let ownerID = "native-install-a"
    private let projectID = "nproj_fresh"
    private let terminalID = "term-nproj_fresh-1234abcd"

    func testControllerFreshLifecycleUsesTheExistingClientWireShapes() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, store) = try makeService(factory: factory)
        let controller = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )

        let created = await service.dispatch(
            client: controller,
            request: request(
                id: "create",
                method: "terminal.create",
                params: createParams()
            )
        )

        XCTAssertTrue(created.ok)
        let creation = try XCTUnwrap(created.result?.objectValue)
        XCTAssertEqual(creation["ok"], .bool(true))
        XCTAssertEqual(creation["existed"], .bool(false))
        XCTAssertEqual(creation["pid"], .integer(43_000))
        XCTAssertEqual(creation["exited"], .bool(false))
        XCTAssertEqual(creation["output"], .string(""))
        XCTAssertEqual(creation["startOffset"], .integer(0))
        XCTAssertEqual(creation["endOffset"], .integer(0))
        XCTAssertEqual(creation["truncated"], .bool(false))
        XCTAssertEqual(creation["recovered"], .null)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(creation["streamEpoch"]?.stringValue)))

        let spawnRequests = await factory.requests
        XCTAssertEqual(spawnRequests, [FreshTerminalSpawnRequest(
            command: "/bin/zsh",
            arguments: ["-il"],
            environment: cleanTerminalEnvironment,
            cwd: "/tmp/nproj_fresh",
            columns: 100,
            rows: 30
        )])

        let write = await service.dispatch(
            client: controller,
            request: request(
                id: "write",
                method: "terminal.write",
                params: identityParams(extra: ["data": .string("printf ready\n")])
            )
        )
        XCTAssertEqual(write.result, .object(["ok": .bool(true)]))

        let resize = await service.dispatch(
            client: controller,
            request: request(
                id: "resize",
                method: "terminal.resize",
                params: identityParams(extra: [
                    "cols": .integer(132),
                    "rows": .integer(41),
                ])
            )
        )
        XCTAssertEqual(resize.result, .object(["ok": .bool(true)]))

        // Protocol 2 freezes terminal.signal as ETX input. It is deliberately
        // not an OS-signal API; changing this to SIGINT breaks the readiness
        // probe and shells whose foreground process owns the terminal input.
        let signal = await service.dispatch(
            client: controller,
            request: request(
                id: "signal",
                method: "terminal.signal",
                params: identityParams()
            )
        )
        XCTAssertEqual(signal.result, .object(["ok": .bool(true)]))

        let kill = await service.dispatch(
            client: controller,
            request: request(
                id: "kill",
                method: "terminal.kill",
                params: identityParams()
            )
        )
        XCTAssertEqual(kill.result, .object([
            "id": .string(terminalID),
            "ok": .bool(true),
        ]))

        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)
        XCTAssertEqual(process.writes, [
            Data("printf ready\n".utf8),
            Data([0x03]),
        ])
        XCTAssertEqual(process.resizes, [
            WireFreshTerminalProcess.Size(columns: 132, rows: 41),
        ])
        XCTAssertEqual(process.signals, [SIGKILL])

        let released = await service.dispatch(
            client: controller,
            request: request(
                id: "release",
                method: "terminal.release",
                params: identityParams()
            )
        )
        XCTAssertTrue(released.ok)
        XCTAssertEqual(released.result?.objectValue?["id"], .string(terminalID))
        XCTAssertEqual(released.result?.objectValue?["ok"], .bool(true))
        XCTAssertEqual(released.result?.objectValue?["released"], .bool(true))
        XCTAssertEqual(process.terminationCount, 1)
        let finalInventory = await store.inventory()
        XCTAssertEqual(finalInventory, [])
    }

    func testObserverInventoryListAndDiagnosticsExposeFreshDynamicRows() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, store) = try makeService(factory: factory)
        let controller = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )
        let observer = try await authenticate(
            service: service,
            role: .observer,
            instanceID: observerInstanceID
        )
        let created = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        let streamEpoch = try XCTUnwrap(
            created.result?.objectValue?["streamEpoch"]?.stringValue
        )
        await factory.emit(Data("ready\n".utf8), fromProcessAt: 0)

        try await eventually {
            let response = await service.dispatch(
                client: observer,
                request: self.request(
                    id: "inventory-poll",
                    method: "broker.inventory",
                    params: .object(["ownerId": .string("0")])
                )
            )
            return response.result?.objectValue?["diagnostics"]?.arrayValue?.first?
                .objectValue?["endOffset"] == .integer(6)
        }

        let inventoryResponse = await service.dispatch(
            client: observer,
            request: request(
                id: "inventory",
                method: "broker.inventory",
                params: .object(["ownerId": .string("0")])
            )
        )
        XCTAssertTrue(inventoryResponse.ok)
        let inventory = try XCTUnwrap(inventoryResponse.result?.objectValue)
        XCTAssertEqual(inventory["ok"], .bool(true))
        XCTAssertEqual(inventory["state"], .string("stable"))
        let activityEpoch = try XCTUnwrap(inventory["activityEpoch"]?.integerValue)
        XCTAssertGreaterThan(activityEpoch, 0)

        let diagnostics = try XCTUnwrap(inventory["diagnostics"]?.arrayValue)
        let live = try XCTUnwrap(inventory["live"]?.arrayValue)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(live.count, 1)
        let diagnostic = try XCTUnwrap(diagnostics.first?.objectValue)
        let liveRow = try XCTUnwrap(live.first?.objectValue)
        let owner = "\(controllerInstanceID)|\(ownerID)|\(projectID)"

        XCTAssertEqual(diagnostic["id"], .string(terminalID))
        XCTAssertEqual(diagnostic["pid"], .integer(43_000))
        XCTAssertEqual(diagnostic["exited"], .bool(false))
        XCTAssertEqual(diagnostic["owner"], .string(owner))
        XCTAssertEqual(diagnostic["lastOwner"], .string(owner))
        XCTAssertEqual(diagnostic["streamEpoch"], .string(streamEpoch))
        XCTAssertEqual(diagnostic["endOffset"], .integer(6))
        XCTAssertEqual(diagnostic["diskBytes"], .integer(0))
        XCTAssertEqual(diagnostic["cwd"], .string("/tmp/nproj_fresh"))
        XCTAssertEqual(diagnostic["cols"], .integer(100))
        XCTAssertEqual(diagnostic["rows"], .integer(30))

        XCTAssertEqual(liveRow["id"], .string(terminalID))
        XCTAssertEqual(liveRow["pid"], .integer(43_000))
        XCTAssertEqual(liveRow["owner"], .string(owner))
        XCTAssertEqual(liveRow["lastOwner"], .string(owner))
        XCTAssertEqual(liveRow["cwd"], .string("/tmp/nproj_fresh"))
        XCTAssertEqual(liveRow["cols"], .integer(100))
        XCTAssertEqual(liveRow["rows"], .integer(30))

        let status = try XCTUnwrap(inventory["status"]?.objectValue)
        XCTAssertEqual(status["activityEpoch"], .integer(activityEpoch))
        XCTAssertEqual(status["terminals"], .array(diagnostics))
        XCTAssertEqual(status["terminalCapacity"], .object([
            "maximumLiveTerminals": .integer(64),
            "liveTerminalCount": .integer(1),
            "availableTerminalSlots": .integer(63),
        ]))

        let listResponse = await service.dispatch(
            client: observer,
            request: request(
                id: "list",
                method: "terminal.list",
                params: .object(["ownerId": .string("0")])
            )
        )
        XCTAssertEqual(listResponse.result, .array(live))

        let diagnosticsResponse = await service.dispatch(
            client: observer,
            request: request(
                id: "diagnostics",
                method: "terminal.diagnostics",
                params: .object(["ownerId": .string("0")])
            )
        )
        XCTAssertEqual(diagnosticsResponse.result, .array(diagnostics))

        _ = await service.dispatch(
            client: controller,
            request: request(id: "release", method: "terminal.release", params: identityParams())
        )
        let finalInventory = await store.inventory()
        XCTAssertEqual(finalInventory, [])
    }

    func testAtomicInventoryRejectsAnInFlightFreshMutation() async throws {
        let factory = WireFreshTerminalFactory()
        await factory.setSpawnsPaused(true)
        let (service, store) = try makeService(factory: factory)
        let controller = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )
        let observer = try await authenticate(
            service: service,
            role: .observer,
            instanceID: observerInstanceID
        )
        let create = request(
            id: "create-paused",
            method: "terminal.create",
            params: createParams()
        )
        let creating = Task {
            await service.dispatch(client: controller, request: create)
        }
        try await eventually { await factory.spawnCount == 1 }

        let changing = await service.dispatch(
            client: observer,
            request: request(
                id: "inventory-changing",
                method: "broker.inventory",
                params: .object(["ownerId": .string("0")])
            )
        )
        XCTAssertTrue(changing.ok)
        XCTAssertEqual(changing.result?.objectValue?["ok"], .bool(false))
        XCTAssertEqual(
            changing.result?.objectValue?["state"],
            .string("activity_changed")
        )

        await factory.resumeSpawns()
        let created = await creating.value
        XCTAssertEqual(created.result?.objectValue?["ok"], .bool(true))
        let stable = await service.dispatch(
            client: observer,
            request: request(
                id: "inventory-stable",
                method: "broker.inventory",
                params: .object(["ownerId": .string("0")])
            )
        )
        XCTAssertEqual(stable.result?.objectValue?["ok"], .bool(true))
        XCTAssertEqual(stable.result?.objectValue?["state"], .string("stable"))
        try await store.shutdown()
    }

    func testObserverSubscribeReturnsANormalizedSnapshotWithoutOpeningALiveStream() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, _) = try makeService(factory: factory)
        let controller = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )
        let observer = try await authenticate(
            service: service,
            role: .observer,
            instanceID: observerInstanceID
        )
        let created = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        let streamEpoch = try XCTUnwrap(
            created.result?.objectValue?["streamEpoch"]?.stringValue
        )

        // The emoji is split across PTY reads and the final byte is invalid.
        // The wire offsets count the repaired UTF-8 sent to the client: 1 + 4 + 3.
        await factory.emit(Data([0x41, 0xF0, 0x9F]), fromProcessAt: 0)
        await factory.emit(Data([0x99, 0x82]), fromProcessAt: 0)
        await factory.emit(Data([0xFF]), fromProcessAt: 0)

        var subscribed: BrokerResponse?
        try await eventually {
            let response = await service.dispatch(
                client: observer,
                request: self.request(
                    id: "subscribe",
                    method: "terminal.subscribe",
                    params: self.observerIdentityParams()
                )
            )
            subscribed = response
            return response.result?.objectValue?["snapshot"]?.objectValue?["endOffset"]
                == .integer(8)
        }

        let result = try XCTUnwrap(subscribed?.result?.objectValue)
        XCTAssertEqual(result["ok"], .bool(true))
        XCTAssertEqual(result["mode"], .string("snapshot"))
        XCTAssertNil(result["cursor"])
        XCTAssertNil(result["subscriptionId"])
        XCTAssertEqual(result["snapshot"], .object([
            "streamEpoch": .string(streamEpoch),
            "output": .string("A🙂\u{FFFD}"),
            "startOffset": .integer(0),
            "endOffset": .integer(8),
            "truncated": .bool(false),
            "exited": .bool(false),
        ]))

        let wrongProject = await service.dispatch(
            client: observer,
            request: request(
                id: "wrong-project",
                method: "terminal.subscribe",
                params: observerIdentityParams(
                    ownerID: "native-install-b",
                    projectID: "nproj_other"
                )
            )
        )
        XCTAssertFalse(wrongProject.ok)
        XCTAssertEqual(wrongProject.message, "terminal access denied")

        let absent = await service.dispatch(
            client: observer,
            request: request(
                id: "absent",
                method: "terminal.subscribe",
                params: observerIdentityParams(id: "term-nproj_fresh-deadbeef")
            )
        )
        XCTAssertTrue(absent.ok)
        XCTAssertEqual(absent.result, .object([
            "ok": .bool(false),
            "message": .string("Terminal is no longer available."),
        ]))

        _ = await service.dispatch(
            client: controller,
            request: request(id: "release", method: "terminal.release", params: identityParams())
        )
    }

    func testControllerReadsRequireAndFilterToItsExactOwnerScope() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, store) = try makeService(factory: factory)
        let first = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )
        let second = try await authenticate(
            service: service,
            role: .controller,
            instanceID: secondControllerInstanceID
        )
        let otherID = "term-nproj_fresh-deadbeef"
        _ = await service.dispatch(
            client: first,
            request: request(id: "create-first", method: "terminal.create", params: createParams())
        )
        _ = await service.dispatch(
            client: second,
            request: request(
                id: "create-second",
                method: "terminal.create",
                params: createParams(id: otherID, extra: [
                    "ownerId": .string("native-install-b"),
                ])
            )
        )

        let readParams: BrokerJSONValue = .object([
            "ownerId": .string(ownerID),
            "projectId": .string(projectID),
        ])
        let inventoryResponse = await service.dispatch(
            client: first,
            request: request(
                id: "controller-inventory",
                method: "broker.inventory",
                params: readParams
            )
        )
        let inventory = try XCTUnwrap(inventoryResponse.result?.objectValue)
        let diagnostics = try XCTUnwrap(inventory["diagnostics"]?.arrayValue)
        let live = try XCTUnwrap(inventory["live"]?.arrayValue)
        XCTAssertEqual(diagnostics.compactMap { $0.objectValue?["id"] }, [
            .string(terminalID),
        ])
        XCTAssertEqual(live.compactMap { $0.objectValue?["id"] }, [
            .string(terminalID),
        ])
        XCTAssertNil(inventory["status"]?.objectValue?["terminalCapacity"])

        let list = await service.dispatch(
            client: first,
            request: request(id: "controller-list", method: "terminal.list", params: readParams)
        )
        XCTAssertEqual(list.result?.arrayValue?.count, 1)
        let diagnosticRows = await service.dispatch(
            client: first,
            request: request(
                id: "controller-diagnostics",
                method: "terminal.diagnostics",
                params: readParams
            )
        )
        XCTAssertEqual(diagnosticRows.result?.arrayValue?.count, 1)

        let foreignSubscribe = await service.dispatch(
            client: first,
            request: request(
                id: "foreign-subscribe",
                method: "terminal.subscribe",
                params: observerIdentityParams(
                    ownerID: ownerID,
                    id: otherID
                )
            )
        )
        XCTAssertFalse(foreignSubscribe.ok)
        XCTAssertEqual(foreignSubscribe.message, "terminal access denied")

        let zeroOwner = await service.dispatch(
            client: first,
            request: request(
                id: "zero-owner",
                method: "broker.status",
                params: .object(["ownerId": .string("0")])
            )
        )
        XCTAssertFalse(zeroOwner.ok)
        XCTAssertEqual(
            zeroOwner.message,
            "controller access requires a nonzero owner identity"
        )

        _ = await service.dispatch(
            client: first,
            request: request(id: "release-first", method: "terminal.release", params: identityParams())
        )
        _ = await service.dispatch(
            client: second,
            request: request(
                id: "release-second",
                method: "terminal.release",
                params: identityParams(
                    ownerID: "native-install-b",
                    id: otherID
                )
            )
        )
        let finalInventory = await store.inventory()
        XCTAssertEqual(finalInventory, [])
    }

    func testMutationAuthorizationAndMissingWriteMatchExistingClientErrors() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, _) = try makeService(factory: factory)
        let controller = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )
        let observer = try await authenticate(
            service: service,
            role: .observer,
            instanceID: observerInstanceID
        )
        let otherController = try await authenticate(
            service: service,
            role: .controller,
            instanceID: secondControllerInstanceID
        )
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )

        let missing = await service.dispatch(
            client: controller,
            request: request(
                id: "missing",
                method: "terminal.write",
                params: identityParams(
                    id: "term-nproj_fresh-deadbeef",
                    extra: ["data": .string("ignored")]
                )
            )
        )
        // BrokerControlClient intentionally maps this exact absence shape to
        // TerminalWriteError.missing rather than a transport failure.
        XCTAssertTrue(missing.ok)
        XCTAssertEqual(missing.result, .object(["ok": .bool(false)]))

        let staleOwner = await service.dispatch(
            client: otherController,
            request: request(
                id: "stale-owner",
                method: "terminal.write",
                params: identityParams(
                    ownerID: "native-install-b",
                    extra: ["data": .string("forbidden")]
                )
            )
        )
        XCTAssertFalse(staleOwner.ok)
        XCTAssertEqual(staleOwner.message, "terminal access denied")

        let observerMutation = await service.dispatch(
            client: observer,
            request: request(
                id: "observer-write",
                method: "terminal.write",
                params: identityParams(extra: ["data": .string("forbidden")])
            )
        )
        XCTAssertFalse(observerMutation.ok)
        XCTAssertEqual(observerMutation.message, "terminal mutations require controller access")

        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)
        XCTAssertEqual(process.writes, [])
        _ = await service.dispatch(
            client: controller,
            request: request(id: "release", method: "terminal.release", params: identityParams())
        )
    }

    func testCapacityMapsToTheTypedBrokerControlClientResult() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, store) = try makeService(factory: factory)
        let controller = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )

        for index in 0..<64 {
            let id = String(format: "term-nproj_fresh-%08x", index)
            let response = await service.dispatch(
                client: controller,
                request: request(
                    id: "create-\(index)",
                    method: "terminal.create",
                    params: createParams(id: id)
                )
            )
            XCTAssertEqual(response.result?.objectValue?["ok"], .bool(true), id)
        }

        let rejected = await service.dispatch(
            client: controller,
            request: request(
                id: "capacity",
                method: "terminal.create",
                params: createParams(id: "term-nproj_fresh-ffffffff")
            )
        )
        XCTAssertTrue(rejected.ok)
        XCTAssertEqual(rejected.result, .object([
            "ok": .bool(false),
            "code": .string("terminal_capacity_exceeded"),
            "message": .string("broker terminal capacity reached"),
            "maximumLiveTerminals": .integer(64),
        ]))
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 64)

        try await store.shutdown()
    }

    func testFreshBoundaryRefusesRestoreAttachAndDurableHistoryWithoutSpawning() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, _) = try makeService(factory: factory)
        let controller = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )
        let observer = try await authenticate(
            service: service,
            role: .observer,
            instanceID: observerInstanceID
        )

        let restore = await service.dispatch(
            client: controller,
            request: request(
                id: "restore",
                method: "terminal.create",
                params: createParams(extra: ["restore": .bool(true)])
            )
        )
        XCTAssertFalse(restore.ok)
        XCTAssertEqual(
            restore.message,
            "fresh Swift broker does not restore prior terminal state"
        )

        let attach = await service.dispatch(
            client: controller,
            request: request(
                id: "attach",
                method: "terminal.attach",
                params: identityParams()
            )
        )
        XCTAssertFalse(attach.ok)

        let history = await service.dispatch(
            client: observer,
            request: request(
                id: "history",
                method: "terminal.history",
                params: observerIdentityParams(extra: [
                    "streamEpoch": .string("does-not-exist"),
                    "beforeOffset": .integer(0),
                    "maxBytes": .integer(Int64(4 * 1_024 * 1_024)),
                ])
            )
        )
        XCTAssertFalse(history.ok)
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 0)
    }

    private var cleanTerminalEnvironment: [String: String] {
        [
            "PROMPT_EOL_MARK": "",
            "NO_COLOR": "",
            "FORCE_COLOR": "1",
            "CODEX_CI": "",
            "CODEX_MANAGED_BY_NPM": "",
            "CODEX_MANAGED_PACKAGE_ROOT": "",
            "CODEX_THREAD_ID": "",
        ]
    }

    private func makeService(
        factory: WireFreshTerminalFactory
    ) throws -> (ShadowBrokerService, FreshTerminalStore) {
        let store = FreshTerminalStore(factory: factory)
        return (
            try ShadowBrokerService(
                configuration: ShadowBrokerServiceConfiguration(
                    expectedToken: token,
                    expectedUID: 501,
                    packageSchema: 2,
                    packageVersion: "0.1.124",
                    contentDigest: digest,
                    pid: 12_345,
                    startedAt: 1_786_000_000_000,
                    version: "0.1.124"
                ),
                terminalStore: store
            ),
            store
        )
    }

    private func authenticate(
        service: ShadowBrokerService,
        role: BrokerAccessRole,
        instanceID: String
    ) async throws -> BrokerAuthenticatedClient {
        let result = await service.authenticate(
            hello: BrokerHelloRequest(
                protocolVersion: 2,
                token: token,
                instanceID: instanceID,
                access: role.rawValue,
                features: ["terminal-observe-v1", "broker-inventory-v1"]
            ),
            peerUID: 501
        )
        guard case let .accepted(client, _) = result else {
            throw WireFreshTerminalTestError.authenticationRejected
        }
        return client
    }

    private func request(
        id: String,
        method: String,
        params: BrokerJSONValue
    ) -> BrokerRequest {
        BrokerRequest(id: id, method: method, params: params)
    }

    private func createParams(
        id: String? = nil,
        extra: [String: BrokerJSONValue] = [:]
    ) -> BrokerJSONValue {
        var params: [String: BrokerJSONValue] = [
            "ownerId": .string(ownerID),
            "projectId": .string(projectID),
            "id": .string(id ?? terminalID),
            "command": .string("/bin/zsh"),
            "args": .array([.string("-il")]),
            "cwd": .string("/tmp/nproj_fresh"),
            "env": .object(cleanTerminalEnvironment.mapValues(BrokerJSONValue.string)),
            "cols": .integer(100),
            "rows": .integer(30),
            "mutationId": .string(UUID().uuidString.lowercased()),
        ]
        params.merge(extra) { _, replacement in replacement }
        return .object(params)
    }

    private func identityParams(
        ownerID: String? = nil,
        projectID: String? = nil,
        id: String? = nil,
        extra: [String: BrokerJSONValue] = [:]
    ) -> BrokerJSONValue {
        var params: [String: BrokerJSONValue] = [
            "ownerId": .string(ownerID ?? self.ownerID),
            "projectId": .string(projectID ?? self.projectID),
            "id": .string(id ?? terminalID),
            "mutationId": .string(UUID().uuidString.lowercased()),
        ]
        params.merge(extra) { _, replacement in replacement }
        return .object(params)
    }

    private func observerIdentityParams(
        ownerID: String = "native-observer",
        projectID: String? = nil,
        id: String? = nil,
        extra: [String: BrokerJSONValue] = [:]
    ) -> BrokerJSONValue {
        var params: [String: BrokerJSONValue] = [
            "ownerId": .string(ownerID),
            "projectId": .string(projectID ?? self.projectID),
            "id": .string(id ?? terminalID),
            "maxQueueBytes": .integer(Int64(512 * 1_024)),
        ]
        params.merge(extra) { _, replacement in replacement }
        return .object(params)
    }

    private func eventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () async -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true", file: file, line: line)
        throw WireFreshTerminalTestError.conditionTimedOut
    }
}

private enum WireFreshTerminalTestError: Error {
    case authenticationRejected
    case conditionTimedOut
}

private final class WireFreshTerminalProcess: FreshTerminalProcess, @unchecked Sendable {
    struct Size: Equatable {
        let columns: Int
        let rows: Int
    }

    let pid: Int32
    private let lock = NSLock()
    private var storedWrites: [Data] = []
    private var storedResizes: [Size] = []
    private var storedSignals: [Int32] = []
    private var storedTerminationCount = 0
    private var exited = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

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
        withLock { storedResizes.append(Size(columns: columns, rows: rows)) }
    }

    func send(signal: Int32) throws {
        withLock { storedSignals.append(signal) }
    }

    func waitForFreshTerminalExit() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                if exited { return true }
                exitWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func terminateFreshTerminal(graceNanoseconds: UInt64) async throws {
        withLock { storedTerminationCount += 1 }
        confirmExit()
    }

    private func confirmExit() {
        let waiters: [CheckedContinuation<Void, Never>] = withLock {
            guard !exited else { return [] }
            exited = true
            let waiters = exitWaiters
            exitWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    @discardableResult
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private actor WireFreshTerminalFactory: FreshTerminalProcessFactory {
    private(set) var requests: [FreshTerminalSpawnRequest] = []
    private var processes: [WireFreshTerminalProcess] = []
    private var outputs: [@Sendable (Data) -> Void] = []
    private var spawnsPaused = false
    private var spawnWaiters: [CheckedContinuation<Void, Never>] = []

    var spawnCount: Int { processes.count }

    func spawn(
        request: FreshTerminalSpawnRequest,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> any FreshTerminalProcess {
        let process = WireFreshTerminalProcess(pid: Int32(43_000 + processes.count))
        requests.append(request)
        processes.append(process)
        outputs.append(onOutput)
        if spawnsPaused {
            await withCheckedContinuation { spawnWaiters.append($0) }
        }
        return process
    }

    func process(at index: Int) -> WireFreshTerminalProcess? {
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
