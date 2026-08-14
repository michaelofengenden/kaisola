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

    func testObserverSubscribeReturnsANormalizedSnapshotAndRegistersTheObserver() async throws {
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
            "exitStatus": .null,
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

        // History exists for fresh terminals now, but only over the retained
        // in-memory tail: a terminal that never existed answers the same
        // unavailable result the Node broker produces, and nothing spawns.
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
        XCTAssertTrue(history.ok)
        XCTAssertEqual(history.result, .object([
            "ok": .bool(false),
            "message": .string("Terminal is no longer available."),
        ]))
        let spawnCount = await factory.spawnCount
        XCTAssertEqual(spawnCount, 0)
    }

    func testSubscribeSnapshotThenLiveEventsHaveNoGapNorDuplicateUnderConcurrentOutput() async throws {
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
        let recorder = WireBrokerFrameRecorder()
        await service.attachConnection(client: observer, sink: recorder.sink())
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )

        // Race live PTY output against the subscribe itself. The chunks travel
        // through the same accumulator lock that registers the observer, so
        // every byte must land exactly once: in the snapshot or in an event.
        let chunks = (0..<200).map { "chunk-\($0);" }
        let expected = chunks.joined()
        let flood = Task {
            for chunk in chunks {
                await factory.emit(Data(chunk.utf8), fromProcessAt: 0)
            }
        }
        let inline = await service.dispatch(
            client: observer,
            request: request(
                id: "subscribe",
                method: "terminal.subscribe",
                params: observerIdentityParams()
            ),
            responder: recorder.responder()
        )
        XCTAssertNil(inline, "a connection-backed subscribe answers through its responder")
        await flood.value

        let total = Int64(expected.utf8.count)
        try await eventually { recorder.highestContiguousEndOffset() == total }

        // Three more appends after the flood settles prove genuinely live
        // events exist even if the subscribe raced past the entire flood.
        for extra in ["tail-a;", "tail-b;", "tail-c;"] {
            await factory.emit(Data(extra.utf8), fromProcessAt: 0)
        }
        let extendedTotal = total + Int64("tail-a;tail-b;tail-c;".utf8.count)

        let items = recorder.items()
        guard case let .response(first) = items.first else {
            return XCTFail("the subscribe response must precede every event frame")
        }
        let snapshot = try XCTUnwrap(
            first.result?.objectValue?["snapshot"]?.objectValue
        )
        let snapshotEnd = try XCTUnwrap(snapshot["endOffset"]?.integerValue)
        let snapshotOutput = try XCTUnwrap(snapshot["output"]?.stringValue)
        XCTAssertEqual(snapshot["startOffset"], .integer(0))
        XCTAssertEqual(Int64(snapshotOutput.utf8.count), snapshotEnd)

        var cursor = snapshotEnd
        var streamed = ""
        var sawLiveEvent = false
        for item in items.dropFirst() {
            guard case let .event(frame, _, force) = item else {
                return XCTFail("only the subscribe response and events may appear")
            }
            XCTAssertFalse(force)
            let payload = try XCTUnwrap(frame.objectValue?["payload"]?.objectValue)
            XCTAssertEqual(frame.objectValue?["channel"], .string("terminal:observer-output"))
            XCTAssertEqual(payload["id"], .string(terminalID))
            let start = try XCTUnwrap(payload["startOffset"]?.integerValue)
            let end = try XCTUnwrap(payload["endOffset"]?.integerValue)
            let data = try XCTUnwrap(payload["data"]?.stringValue)
            XCTAssertEqual(start, cursor, "live events must be gapless and duplicate-free")
            XCTAssertEqual(end - start, Int64(data.utf8.count))
            cursor = end
            streamed += data
            sawLiveEvent = true
        }
        XCTAssertTrue(sawLiveEvent)
        XCTAssertEqual(cursor, extendedTotal)
        XCTAssertEqual(snapshotOutput + streamed, expected + "tail-a;tail-b;tail-c;")
    }

    func testMultipleClientsReceiveTheSameOrderedObserverStream() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, _) = try makeService(factory: factory)
        let controller = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        await factory.emit(Data("prelude;".utf8), fromProcessAt: 0)

        let observer = try await authenticate(
            service: service,
            role: .observer,
            instanceID: observerInstanceID
        )
        let observerRecorder = WireBrokerFrameRecorder()
        let controllerRecorder = WireBrokerFrameRecorder()
        await service.attachConnection(client: observer, sink: observerRecorder.sink())
        await service.attachConnection(client: controller, sink: controllerRecorder.sink())
        _ = await service.dispatch(
            client: observer,
            request: request(
                id: "subscribe-observer",
                method: "terminal.subscribe",
                params: observerIdentityParams()
            ),
            responder: observerRecorder.responder()
        )
        // The owning controller reads the same stream through its own exact
        // owner subscription: controller and observer roles see one ordered
        // stream with identical offsets and payloads.
        _ = await service.dispatch(
            client: controller,
            request: request(
                id: "subscribe-controller",
                method: "terminal.subscribe",
                params: observerIdentityParams(ownerID: ownerID)
            ),
            responder: controllerRecorder.responder()
        )
        await factory.emit(Data("alpha;".utf8), fromProcessAt: 0)
        await factory.emit(Data("beta🙂;".utf8), fromProcessAt: 0)

        let observerEvents = observerRecorder.outputEventPayloads()
        let controllerEvents = controllerRecorder.outputEventPayloads()
        XCTAssertEqual(observerEvents.count, 2)
        XCTAssertEqual(observerEvents, controllerEvents)
        XCTAssertEqual(
            observerEvents.compactMap { $0.objectValue?["data"]?.stringValue },
            ["alpha;", "beta🙂;"]
        )
    }

    func testSlowConsumerOverflowPausesWithExactResubscribeCursor() async throws {
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
        let recorder = WireBrokerFrameRecorder()
        await service.attachConnection(client: observer, sink: recorder.sink())
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        let subscribed = await service.dispatch(
            client: observer,
            request: request(
                id: "subscribe",
                method: "terminal.subscribe",
                params: observerIdentityParams()
            ),
            responder: recorder.responder()
        )
        XCTAssertNil(subscribed)
        await factory.emit(Data("warmup;".utf8), fromProcessAt: 0)
        let delivered = Int64("warmup;".utf8.count)
        XCTAssertEqual(recorder.highestContiguousEndOffset(), delivered)
        let streamEpoch = try XCTUnwrap(recorder.firstSnapshotStreamEpoch())

        // The sink refuses ordinary deliveries exactly like a saturated
        // socket. The one permitted overflow is the forced reset marker that
        // carries the resubscribe cursor of the batch that could not be sent.
        recorder.setAcceptsDeliveries(false)
        await factory.emit(Data("lost-bytes".utf8), fromProcessAt: 0)
        recorder.setAcceptsDeliveries(true)
        let lostEnd = delivered + Int64("lost-bytes".utf8.count)

        let markers = recorder.eventFrames(channel: "terminal:observer-snapshot-required")
        XCTAssertEqual(markers.count, 1)
        let marker = try XCTUnwrap(markers.first)
        XCTAssertTrue(marker.force, "the reset marker must bypass the queue cap")
        XCTAssertEqual(marker.payload.objectValue?["id"], .string(terminalID))
        XCTAssertEqual(marker.payload.objectValue?["reason"], .string("slow_consumer"))
        XCTAssertEqual(marker.payload.objectValue?["streamEpoch"], .string(streamEpoch))
        XCTAssertEqual(marker.payload.objectValue?["endOffset"], .integer(lostEnd))

        // A paused subscription is never spoken to again until an explicit
        // resubscribe: no deltas, no repeated markers, no silent byte loss.
        await factory.emit(Data("after-pause;".utf8), fromProcessAt: 0)
        XCTAssertEqual(recorder.outputEventPayloads().count, 1)
        XCTAssertEqual(recorder.eventFrames(channel: "terminal:observer-snapshot-required").count, 1)

        let resubscribed = await service.dispatch(
            client: observer,
            request: request(
                id: "resubscribe",
                method: "terminal.subscribe",
                params: observerIdentityParams(extra: [
                    "streamEpoch": .string(streamEpoch),
                    "afterOffset": .integer(delivered),
                ])
            )
        )
        let result = try XCTUnwrap(resubscribed.result?.objectValue)
        XCTAssertEqual(result["ok"], .bool(true))
        XCTAssertEqual(result["mode"], .string("snapshot"))
        XCTAssertNil(result["resetReason"])
        let snapshot = try XCTUnwrap(result["snapshot"]?.objectValue)
        XCTAssertEqual(snapshot["startOffset"], .integer(delivered))
        XCTAssertEqual(snapshot["output"], .string("lost-bytesafter-pause;"))
        XCTAssertEqual(snapshot["truncated"], .bool(true))

        // The replacing subscribe clears the paused state, so deltas flow again.
        await factory.emit(Data("resumed;".utf8), fromProcessAt: 0)
        let resumed = try XCTUnwrap(recorder.outputEventPayloads().last?.objectValue)
        XCTAssertEqual(resumed["data"], .string("resumed;"))
        XCTAssertEqual(resumed["startOffset"]?.integerValue, lostEnd + Int64("after-pause;".utf8.count))
    }

    func testUnsubscribeRemovesTheSubscriptionAndDisconnectCleansUp() async throws {
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
        let observerRecorder = WireBrokerFrameRecorder()
        let controllerRecorder = WireBrokerFrameRecorder()
        await service.attachConnection(client: observer, sink: observerRecorder.sink())
        await service.attachConnection(client: controller, sink: controllerRecorder.sink())
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        _ = await service.dispatch(
            client: observer,
            request: request(
                id: "subscribe-observer",
                method: "terminal.subscribe",
                params: observerIdentityParams()
            ),
            responder: observerRecorder.responder()
        )
        _ = await service.dispatch(
            client: controller,
            request: request(
                id: "subscribe-controller",
                method: "terminal.subscribe",
                params: observerIdentityParams(ownerID: ownerID)
            ),
            responder: controllerRecorder.responder()
        )
        await factory.emit(Data("both;".utf8), fromProcessAt: 0)
        XCTAssertEqual(observerRecorder.outputEventPayloads().count, 1)
        XCTAssertEqual(controllerRecorder.outputEventPayloads().count, 1)

        let removed = await service.dispatch(
            client: observer,
            request: request(
                id: "unsubscribe",
                method: "terminal.unsubscribe",
                params: observerIdentityParams()
            )
        )
        XCTAssertEqual(removed.result, .object(["ok": .bool(true), "removed": .bool(true)]))
        let removedAgain = await service.dispatch(
            client: observer,
            request: request(
                id: "unsubscribe-again",
                method: "terminal.unsubscribe",
                params: observerIdentityParams()
            )
        )
        XCTAssertEqual(removedAgain.result, .object(["ok": .bool(true), "removed": .bool(false)]))

        await factory.emit(Data("controller-only;".utf8), fromProcessAt: 0)
        XCTAssertEqual(observerRecorder.outputEventPayloads().count, 1)
        XCTAssertEqual(controllerRecorder.outputEventPayloads().count, 2)

        // Closing a connection removes every subscription it registered.
        await service.disconnect(client: controller)
        await factory.emit(Data("nobody;".utf8), fromProcessAt: 0)
        XCTAssertEqual(controllerRecorder.outputEventPayloads().count, 2)
    }

    func testExitPublishesFinalRepairedOutputThenExitEventWithStatus() async throws {
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
        let recorder = WireBrokerFrameRecorder()
        await service.attachConnection(client: observer, sink: recorder.sink())
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        _ = await service.dispatch(
            client: observer,
            request: request(
                id: "subscribe",
                method: "terminal.subscribe",
                params: observerIdentityParams()
            ),
            responder: recorder.responder()
        )
        await factory.emit(Data("bye".utf8), fromProcessAt: 0)
        // An incomplete scalar at exit must flush as one deterministic U+FFFD
        // repair BEFORE the exit event, never as silently dropped bytes.
        await factory.emit(Data([0xF0, 0x9F]), fromProcessAt: 0)
        let spawnedProcess = await factory.process(at: 0)
        let process = try XCTUnwrap(spawnedProcess)
        process.simulateExit(status: FreshTerminalExitStatus(exitCode: 3, signal: nil))

        try await eventually {
            !recorder.eventFrames(channel: "terminal:observer-exit").isEmpty
        }
        let outputs = recorder.outputEventPayloads()
        XCTAssertEqual(
            outputs.compactMap { $0.objectValue?["data"]?.stringValue },
            ["bye", "\u{FFFD}"]
        )
        let exitEnd = Int64("bye".utf8.count) + 3
        XCTAssertEqual(outputs.last?.objectValue?["endOffset"], .integer(exitEnd))

        let items = recorder.items()
        let lastOutputIndex = try XCTUnwrap(items.lastIndex {
            $0.eventChannel == "terminal:observer-output"
        })
        let exitIndex = try XCTUnwrap(items.firstIndex {
            $0.eventChannel == "terminal:observer-exit"
        })
        XCTAssertGreaterThan(exitIndex, lastOutputIndex, "output must land before exit")
        let exitFrame = try XCTUnwrap(recorder.eventFrames(channel: "terminal:observer-exit").first)
        let payload = try XCTUnwrap(exitFrame.payload.objectValue)
        XCTAssertEqual(payload["id"], .string(terminalID))
        XCTAssertEqual(payload["offset"], .integer(exitEnd))
        XCTAssertEqual(payload["exitStatus"], .object([
            "exitCode": .integer(3),
            "signal": .null,
        ]))

        // A late subscribe still reports the exited terminal and its status.
        let late = await service.dispatch(
            client: observer,
            request: request(
                id: "late-subscribe",
                method: "terminal.subscribe",
                params: observerIdentityParams(ownerID: "late-observer")
            )
        )
        let snapshot = try XCTUnwrap(late.result?.objectValue?["snapshot"]?.objectValue)
        XCTAssertEqual(snapshot["exited"], .bool(true))
        XCTAssertEqual(snapshot["exitStatus"], .object([
            "exitCode": .integer(3),
            "signal": .null,
        ]))
    }

    func testUTF8SplitAcrossReadsEmitsOnlyCompleteScalars() async throws {
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
        let recorder = WireBrokerFrameRecorder()
        await service.attachConnection(client: observer, sink: recorder.sink())
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        _ = await service.dispatch(
            client: observer,
            request: request(
                id: "subscribe",
                method: "terminal.subscribe",
                params: observerIdentityParams()
            ),
            responder: recorder.responder()
        )

        await factory.emit(Data([0xF0, 0x9F]), fromProcessAt: 0)
        XCTAssertEqual(
            recorder.outputEventPayloads().count,
            0,
            "a split scalar must wait for its remaining bytes"
        )
        await factory.emit(Data([0x99, 0x82]), fromProcessAt: 0)
        let events = recorder.outputEventPayloads()
        XCTAssertEqual(events.count, 1)
        let payload = try XCTUnwrap(events.first?.objectValue)
        XCTAssertEqual(payload["data"], .string("🙂"))
        XCTAssertEqual(payload["startOffset"], .integer(0))
        XCTAssertEqual(payload["endOffset"], .integer(4))
    }

    func testObserverLimitInvalidCursorsAndResumeModesMatchNodeSemantics() async throws {
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
        await factory.emit(Data("A🙂".utf8), fromProcessAt: 0)

        for index in 0..<8 {
            let response = await service.dispatch(
                client: observer,
                request: request(
                    id: "subscribe-\(index)",
                    method: "terminal.subscribe",
                    params: observerIdentityParams(ownerID: "observer-\(index)")
                )
            )
            XCTAssertEqual(response.result?.objectValue?["ok"], .bool(true), "subscriber \(index)")
        }
        let overLimit = await service.dispatch(
            client: observer,
            request: request(
                id: "subscribe-limit",
                method: "terminal.subscribe",
                params: observerIdentityParams(ownerID: "observer-9")
            )
        )
        XCTAssertFalse(overLimit.ok)
        XCTAssertEqual(overLimit.message, "terminal observer limit of 8 reached")

        for params in [
            observerIdentityParams(extra: ["afterOffset": .integer(5)]),
            observerIdentityParams(extra: ["streamEpoch": .string(streamEpoch)]),
            observerIdentityParams(extra: [
                "streamEpoch": .string(streamEpoch),
                "afterOffset": .integer(-1),
            ]),
        ] {
            let invalid = await service.dispatch(
                client: observer,
                request: request(id: "invalid-cursor", method: "terminal.subscribe", params: params)
            )
            XCTAssertFalse(invalid.ok)
            XCTAssertEqual(invalid.message, "invalid terminal observer cursor")
        }

        func resume(afterOffset: Int64, epoch: String = streamEpoch) async -> [String: BrokerJSONValue]? {
            let response = await service.dispatch(
                client: observer,
                request: request(
                    id: "resume-\(epoch)-\(afterOffset)",
                    method: "terminal.subscribe",
                    params: observerIdentityParams(ownerID: "observer-0", extra: [
                        "streamEpoch": .string(epoch),
                        "afterOffset": .integer(afterOffset),
                    ])
                )
            )
            return response.result?.objectValue
        }

        let current = await resume(afterOffset: 5)
        XCTAssertEqual(current?["mode"], .string("current"))
        XCTAssertEqual(current?["cursor"], .object([
            "streamEpoch": .string(streamEpoch),
            "offset": .integer(5),
        ]))

        let ahead = await resume(afterOffset: 6)
        XCTAssertEqual(ahead?["mode"], .string("snapshot"))
        XCTAssertEqual(ahead?["resetReason"], .string("cursor_ahead"))

        let mismatch = await resume(afterOffset: 5, epoch: "not-the-epoch")
        XCTAssertEqual(mismatch?["resetReason"], .string("epoch_mismatch"))

        let midScalar = await resume(afterOffset: 2)
        XCTAssertEqual(midScalar?["resetReason"], .string("invalid_utf8_boundary"))

        let suffix = await resume(afterOffset: 1)
        XCTAssertEqual(suffix?["mode"], .string("snapshot"))
        XCTAssertNil(suffix?["resetReason"])
        let suffixSnapshot = try XCTUnwrap(suffix?["snapshot"]?.objectValue)
        XCTAssertEqual(suffixSnapshot["output"], .string("🙂"))
        XCTAssertEqual(suffixSnapshot["startOffset"], .integer(1))
        XCTAssertEqual(suffixSnapshot["truncated"], .bool(true))
    }

    func testHistoryPagesBackToRetainedOffsetZeroWithNodeClamps() async throws {
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
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        let sections = [
            String(repeating: "a", count: 60_000),
            String(repeating: "b", count: 60_000),
            String(repeating: "c", count: 60_000),
        ]
        for section in sections {
            await factory.emit(Data(section.utf8), fromProcessAt: 0)
        }
        let created = await service.dispatch(
            client: observer,
            request: request(
                id: "resubscribe-for-epoch",
                method: "terminal.subscribe",
                params: observerIdentityParams()
            )
        )
        let snapshot = try XCTUnwrap(created.result?.objectValue?["snapshot"]?.objectValue)
        let streamEpoch = try XCTUnwrap(snapshot["streamEpoch"]?.stringValue)
        XCTAssertEqual(snapshot["endOffset"], .integer(180_000))

        func page(before: Int64, maxBytes: Int64) async -> BrokerResponse {
            await service.dispatch(
                client: observer,
                request: request(
                    id: "history-\(before)",
                    method: "terminal.history",
                    params: observerIdentityParams(extra: [
                        "streamEpoch": .string(streamEpoch),
                        "beforeOffset": .integer(before),
                        "maxBytes": .integer(maxBytes),
                    ])
                )
            )
        }

        var before = Int64(180_000)
        var assembled = ""
        var pages = 0
        while true {
            let response = await page(before: before, maxBytes: 65_536)
            let result = try XCTUnwrap(response.result?.objectValue)
            XCTAssertEqual(result["ok"], .bool(true))
            XCTAssertEqual(result["streamEpoch"], .string(streamEpoch))
            let start = try XCTUnwrap(result["startOffset"]?.integerValue)
            let end = try XCTUnwrap(result["endOffset"]?.integerValue)
            let output = try XCTUnwrap(result["output"]?.stringValue)
            XCTAssertEqual(end, before, "a page must end exactly at the requested offset")
            XCTAssertEqual(Int64(output.utf8.count), end - start)
            XCTAssertLessThanOrEqual(output.utf8.count, 65_536)
            assembled = output + assembled
            pages += 1
            before = start
            let hasMore = try XCTUnwrap(result["hasMore"]?.boolValue)
            if !hasMore { break }
        }
        XCTAssertEqual(before, 0, "paging must reach retained offset zero")
        XCTAssertGreaterThanOrEqual(pages, 3)
        XCTAssertEqual(assembled, sections.joined())

        // The Node broker clamps small page limits UP to 64 KiB.
        let clamped = await page(before: 180_000, maxBytes: 10)
        XCTAssertEqual(
            clamped.result?.objectValue?["output"]?.stringValue?.utf8.count,
            65_536
        )

        let wrongEpoch = await service.dispatch(
            client: observer,
            request: request(
                id: "history-wrong-epoch",
                method: "terminal.history",
                params: observerIdentityParams(extra: [
                    "streamEpoch": .string("not-the-epoch"),
                    "beforeOffset": .integer(0),
                    "maxBytes": .integer(65_536),
                ])
            )
        )
        XCTAssertFalse(wrongEpoch.ok)
        XCTAssertEqual(wrongEpoch.message, "terminal history epoch mismatch")

        let pastEnd = await page(before: 180_001, maxBytes: 65_536)
        XCTAssertFalse(pastEnd.ok)
        XCTAssertEqual(pastEnd.message, "invalid terminal history offset")

        let missing = await service.dispatch(
            client: observer,
            request: request(
                id: "history-missing",
                method: "terminal.history",
                params: observerIdentityParams(id: "term-nproj_fresh-deadbeef", extra: [
                    "streamEpoch": .string(streamEpoch),
                    "beforeOffset": .integer(0),
                    "maxBytes": .integer(65_536),
                ])
            )
        )
        XCTAssertTrue(missing.ok)
        XCTAssertEqual(missing.result, .object([
            "ok": .bool(false),
            "message": .string("Terminal is no longer available."),
        ]))
    }

    func testHistoryClampsPagesToTheRetainedFloorAfterTruncation() async throws {
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
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        // 540,000 bytes against the 512 KiB retained tail evicts the oldest
        // 15,712 bytes; a request beneath that floor answers an empty page at
        // the floor instead of inventing bytes that no longer exist.
        for _ in 0..<9 {
            await factory.emit(
                Data(String(repeating: "x", count: 60_000).utf8),
                fromProcessAt: 0
            )
        }
        let subscribed = await service.dispatch(
            client: observer,
            request: request(
                id: "subscribe",
                method: "terminal.subscribe",
                params: observerIdentityParams()
            )
        )
        let snapshot = try XCTUnwrap(subscribed.result?.objectValue?["snapshot"]?.objectValue)
        let streamEpoch = try XCTUnwrap(snapshot["streamEpoch"]?.stringValue)
        XCTAssertEqual(snapshot["truncated"], .bool(true))
        let retainedStart = try XCTUnwrap(snapshot["startOffset"]?.integerValue)
        XCTAssertEqual(retainedStart, 540_000 - 524_288)

        let floored = await service.dispatch(
            client: observer,
            request: request(
                id: "history-floor",
                method: "terminal.history",
                params: observerIdentityParams(extra: [
                    "streamEpoch": .string(streamEpoch),
                    "beforeOffset": .integer(10),
                    "maxBytes": .integer(65_536),
                ])
            )
        )
        let result = try XCTUnwrap(floored.result?.objectValue)
        XCTAssertEqual(result["ok"], .bool(true))
        XCTAssertEqual(result["output"], .string(""))
        XCTAssertEqual(result["startOffset"], .integer(retainedStart))
        XCTAssertEqual(result["endOffset"], .integer(retainedStart))
        XCTAssertEqual(result["hasMore"], .bool(false))
        XCTAssertEqual(result["truncated"], .bool(true))
    }

    func testPrimaryStreamFollowsObserverOnlyOutputNegotiationPerClient() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, _) = try makeService(factory: factory)
        // Legacy-shaped controller: no observer-only-output, no exit-status.
        let legacy = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )
        let legacyRecorder = WireBrokerFrameRecorder()
        await service.attachConnection(client: legacy, sink: legacyRecorder.sink())
        _ = await service.dispatch(
            client: legacy,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        await factory.emit(Data("one".utf8), fromProcessAt: 0)
        let dataFrames = legacyRecorder.eventFrames(channel: "terminal:data:\(terminalID)")
        XCTAssertEqual(dataFrames.count, 1)
        XCTAssertEqual(dataFrames.first?.payload, .string("one"))
        XCTAssertEqual(dataFrames.first?.frame.objectValue?["ownerId"], .string(ownerID))
        XCTAssertEqual(dataFrames.first?.frame.objectValue?["projectId"], .string(projectID))

        // A controller that negotiated observer-only-output must not receive
        // the primary copy at all.
        let modern = try await authenticate(
            service: service,
            role: .controller,
            instanceID: secondControllerInstanceID,
            features: [
                "terminal-observe-v1",
                "broker-inventory-v1",
                "terminal-observer-only-output-v1",
                "terminal-exit-status-v1",
            ]
        )
        let modernRecorder = WireBrokerFrameRecorder()
        await service.attachConnection(client: modern, sink: modernRecorder.sink())
        let modernTerminal = "term-nproj_fresh-cafef00d"
        _ = await service.dispatch(
            client: modern,
            request: request(
                id: "create-modern",
                method: "terminal.create",
                params: createParams(id: modernTerminal, extra: [
                    "ownerId": .string("native-install-b"),
                ])
            )
        )
        await factory.emit(Data("two".utf8), fromProcessAt: 1)
        XCTAssertTrue(modernRecorder.eventFrames(channel: "terminal:data:\(modernTerminal)").isEmpty)

        // Exit publication reaches both owners; the payload shape follows each
        // client's negotiated terminal-exit-status-v1.
        let spawnedLegacyProcess = await factory.process(at: 0)
        let legacyProcess = try XCTUnwrap(spawnedLegacyProcess)
        legacyProcess.simulateExit(status: FreshTerminalExitStatus(exitCode: 0, signal: 15))
        try await eventually {
            !legacyRecorder.eventFrames(channel: "terminal:exit:\(self.terminalID)").isEmpty
        }
        let legacyExit = try XCTUnwrap(
            legacyRecorder.eventFrames(channel: "terminal:exit:\(terminalID)").first
        )
        XCTAssertEqual(legacyExit.payload, .integer(0), "legacy clients get the bare exit code")

        let spawnedModernProcess = await factory.process(at: 1)
        let modernProcess = try XCTUnwrap(spawnedModernProcess)
        modernProcess.simulateExit(status: FreshTerminalExitStatus(exitCode: 2, signal: nil))
        try await eventually {
            !modernRecorder.eventFrames(channel: "terminal:exit:\(modernTerminal)").isEmpty
        }
        let modernExit = try XCTUnwrap(
            modernRecorder.eventFrames(channel: "terminal:exit:\(modernTerminal)").first
        )
        XCTAssertEqual(modernExit.payload, .object([
            "exitCode": .integer(2),
            "signal": .null,
        ]))
    }

    func testPrimaryStreamOverflowPausesUntilAdoptionRearmsIt() async throws {
        let factory = WireFreshTerminalFactory()
        let (service, _) = try makeService(factory: factory)
        let controller = try await authenticate(
            service: service,
            role: .controller,
            instanceID: controllerInstanceID
        )
        let recorder = WireBrokerFrameRecorder()
        await service.attachConnection(client: controller, sink: recorder.sink())
        _ = await service.dispatch(
            client: controller,
            request: request(id: "create", method: "terminal.create", params: createParams())
        )
        await factory.emit(Data("flowing".utf8), fromProcessAt: 0)
        XCTAssertEqual(recorder.eventFrames(channel: "terminal:data:\(terminalID)").count, 1)

        recorder.setAcceptsDeliveries(false)
        await factory.emit(Data("dropped".utf8), fromProcessAt: 0)
        recorder.setAcceptsDeliveries(true)
        let markers = recorder.eventFrames(channel: "terminal:snapshot-required")
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.payload.objectValue?["reason"], .string("slow_consumer"))
        XCTAssertEqual(
            markers.first?.payload.objectValue?["endOffset"],
            .integer(Int64("flowingdropped".utf8.count))
        )

        await factory.emit(Data("silent".utf8), fromProcessAt: 0)
        XCTAssertEqual(recorder.eventFrames(channel: "terminal:data:\(terminalID)").count, 1)

        // Same-project adoption is the fresh analog of a renderer reattach: it
        // re-answers the primary policy and clears the paused marker state.
        let adopted = await service.dispatch(
            client: controller,
            request: request(id: "adopt", method: "terminal.create", params: createParams())
        )
        XCTAssertEqual(adopted.result?.objectValue?["existed"], .bool(true))
        await factory.emit(Data("revived".utf8), fromProcessAt: 0)
        let frames = recorder.eventFrames(channel: "terminal:data:\(terminalID)")
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.last?.payload, .string("revived"))
    }

    func testOutboundFrameQueuePreservesOrderBoundsAndForcedDelivery() async {
        let queue = BrokerOutboundFrameQueue()
        let response = Data("{\"type\":\"response\"}\n".utf8)
        let event = Data(repeating: 0x61, count: 100)

        XCTAssertTrue(queue.enqueue(response, maxQueueBytes: nil, force: false))
        XCTAssertTrue(queue.enqueue(event, maxQueueBytes: 1_000, force: false))
        // The cap covers everything buffered on the socket, responses included.
        XCTAssertFalse(queue.enqueue(event, maxQueueBytes: response.count + event.count + 50, force: false))
        XCTAssertTrue(queue.enqueue(event, maxQueueBytes: 1, force: true))

        let first = await queue.next()
        XCTAssertEqual(first, response)
        queue.markWritten(response.count)
        let second = await queue.next()
        XCTAssertEqual(second, event)
        queue.markWritten(event.count)
        let third = await queue.next()
        XCTAssertEqual(third, event)
        queue.markWritten(event.count)
        XCTAssertEqual(queue.queuedByteCount, 0)

        // finish() drains what is queued, then ends the writer loop.
        XCTAssertTrue(queue.enqueue(response, maxQueueBytes: nil, force: false))
        queue.finish()
        XCTAssertFalse(queue.enqueue(event, maxQueueBytes: nil, force: false))
        let drained = await queue.next()
        XCTAssertEqual(drained, response)
        let ended = await queue.next()
        XCTAssertNil(ended)

        let discarding = BrokerOutboundFrameQueue()
        XCTAssertTrue(discarding.enqueue(response, maxQueueBytes: nil, force: false))
        discarding.closeDiscarding()
        XCTAssertFalse(discarding.enqueue(response, maxQueueBytes: nil, force: true))
        let dropped = await discarding.next()
        XCTAssertNil(dropped)
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
        instanceID: String,
        features: [String] = ["terminal-observe-v1", "broker-inventory-v1"]
    ) async throws -> BrokerAuthenticatedClient {
        let result = await service.authenticate(
            hello: BrokerHelloRequest(
                protocolVersion: 2,
                token: token,
                instanceID: instanceID,
                access: role.rawValue,
                features: features
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
    private var storedExitStatus: FreshTerminalExitStatus?
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

    func freshTerminalExitStatus() async -> FreshTerminalExitStatus? {
        withLock { storedExitStatus }
    }

    /// The exit the real PTY reports through waitpid: resumes the store's
    /// exit waiter with a concrete status without a release/terminate call.
    func simulateExit(status: FreshTerminalExitStatus) {
        withLock { storedExitStatus = status }
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

/// One fake connection's outbound timeline. The subscribe responder and the
/// event sink append into a single locked list, so a test can assert the exact
/// response-before-event ordering that a real socket would carry.
private final class WireBrokerFrameRecorder: @unchecked Sendable {
    enum Item {
        case response(BrokerResponse)
        case event(frame: BrokerJSONValue, maxQueueBytes: Int?, force: Bool)

        var eventChannel: String? {
            guard case let .event(frame, _, _) = self else { return nil }
            return frame.objectValue?["channel"]?.stringValue
        }
    }

    struct EventFrame {
        let frame: BrokerJSONValue
        let payload: BrokerJSONValue
        let maxQueueBytes: Int?
        let force: Bool
    }

    private let lock = NSLock()
    private var recorded: [Item] = []
    private var acceptsDeliveries = true

    /// Refusing non-forced deliveries emulates a saturated per-connection
    /// queue without a real socket; forced recovery markers still land.
    func setAcceptsDeliveries(_ accepts: Bool) {
        lock.lock()
        defer { lock.unlock() }
        acceptsDeliveries = accepts
    }

    func sink() -> BrokerConnectionEventSink {
        BrokerConnectionEventSink { [weak self] frame, maxQueueBytes, force in
            guard let self else { return false }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard force || self.acceptsDeliveries else { return false }
            var data = frame
            if data.last == 0x0A { data.removeLast() }
            guard let decoded = try? JSONDecoder().decode(BrokerJSONValue.self, from: data) else {
                return false
            }
            self.recorded.append(.event(frame: decoded, maxQueueBytes: maxQueueBytes, force: force))
            return true
        }
    }

    func responder() -> @Sendable (BrokerResponse) -> Bool {
        { [weak self] response in
            guard let self else { return false }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.recorded.append(.response(response))
            return true
        }
    }

    func items() -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func eventFrames(channel: String) -> [EventFrame] {
        items().compactMap { item in
            guard case let .event(frame, maxQueueBytes, force) = item,
                  frame.objectValue?["channel"] == .string(channel),
                  let payload = frame.objectValue?["payload"] else {
                return nil
            }
            return EventFrame(
                frame: frame,
                payload: payload,
                maxQueueBytes: maxQueueBytes,
                force: force
            )
        }
    }

    func outputEventPayloads() -> [BrokerJSONValue] {
        eventFrames(channel: "terminal:observer-output").map(\.payload)
    }

    func firstSnapshotStreamEpoch() -> String? {
        for item in items() {
            guard case let .response(response) = item else { continue }
            return response.result?.objectValue?["snapshot"]?
                .objectValue?["streamEpoch"]?.stringValue
        }
        return nil
    }

    /// Walks the recorded timeline exactly as a client would: the snapshot in
    /// the first response seeds the cursor, and only gapless observer-output
    /// events may advance it. A gap or duplicate freezes the walk, which the
    /// coverage assertions then report as missing bytes.
    func highestContiguousEndOffset() -> Int64? {
        var cursor: Int64?
        for item in items() {
            switch item {
            case let .response(response):
                guard cursor == nil else { continue }
                let result = response.result?.objectValue
                if let end = result?["snapshot"]?.objectValue?["endOffset"]?.integerValue {
                    cursor = end
                } else if let offset = result?["cursor"]?.objectValue?["offset"]?.integerValue {
                    cursor = offset
                }
            case let .event(frame, _, _):
                guard let current = cursor,
                      frame.objectValue?["channel"] == .string("terminal:observer-output"),
                      let payload = frame.objectValue?["payload"]?.objectValue,
                      payload["startOffset"]?.integerValue == current,
                      let end = payload["endOffset"]?.integerValue else {
                    continue
                }
                cursor = end
            }
        }
        return cursor
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
