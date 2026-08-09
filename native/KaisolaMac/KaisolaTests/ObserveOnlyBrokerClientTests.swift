import Foundation
import KaisolaBrokerProtocol
import KaisolaCore
import XCTest
@testable import Kaisola

final class ObserveOnlyBrokerClientTests: XCTestCase {
    func testInventoryResponseUsesCorrelatedMethodLimitBeforeDecode() async throws {
        let transport = ScriptedBrokerTransport()
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 500_000_000
        )
        _ = try await client.connect(to: brokerInfo)
        let inventory = Task { try await client.inventory() }
        var requestID: String?
        for _ in 0..<100 {
            requestID = await transport.sentFrames().last?.objectValue?["id"]?.stringValue
            if requestID != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let id = try XCTUnwrap(requestID)
        var response = try JSONEncoder().encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": .object([
                "padding": .string(
                    String(
                        repeating: "x",
                        count: BrokerWire.maximumEncodedBytes(for: .response("broker.status"))
                    )
                ),
            ]),
        ]))
        response.append(0x0A)
        await transport.inject(response)

        do {
            _ = try await inventory.value
            XCTFail("broker.status must not inherit the 56 MiB transport ceiling.")
        } catch {
            XCTAssertEqual(
                error as? BrokerWireError,
                .frameTooLarge(maximum: BrokerWire.maximumEncodedBytes(for: .response("broker.status")))
            )
        }
        await client.disconnect()
    }

    func testConcurrentConnectsToSameBrokerShareOneTransportAndHandshake() async throws {
        let transport = ScriptedBrokerTransport(
            suspendConnect: true,
            helloAccess: "observer",
            advertiseObserverRole: true
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 500_000_000
        )
        let info = brokerInfo

        let first = Task { try await client.connect(to: info) }
        await transport.waitUntilConnectCallCount(1)
        let second = Task { try await client.connect(to: info) }
        for _ in 0..<100 { await Task.yield() }

        let callsDuringHandshake = await transport.connectCalls()
        XCTAssertEqual(callsDuringHandshake, 1)
        await transport.releaseConnect()
        let firstHello = try await first.value
        let secondHello = try await second.value

        XCTAssertEqual(firstHello, secondHello)
        let helloFrames = await transport.sentFrames().filter {
            $0.objectValue?["type"]?.stringValue == "hello"
        }
        XCTAssertEqual(helloFrames.count, 1)
        let completedCalls = await transport.connectCalls()
        XCTAssertEqual(completedCalls, 1)
        await client.disconnect()
    }

    func testConcurrentConnectToDifferentBrokerFailsWithoutDisturbingActiveAttempt() async throws {
        let transport = ScriptedBrokerTransport(
            suspendConnect: true,
            helloAccess: "observer",
            advertiseObserverRole: true
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 500_000_000
        )
        let info = brokerInfo
        let active = Task { try await client.connect(to: info) }
        await transport.waitUntilConnectCallCount(1)
        let other = BrokerInfo(
            protocolVersion: info.protocolVersion,
            securityEpoch: info.securityEpoch,
            implementationVersion: info.implementationVersion,
            packageSchema: info.packageSchema,
            packageVersion: info.packageVersion,
            contentDigest: info.contentDigest,
            pid: info.pid,
            socketPath: "/tmp/kaisola-other-observer-test.sock",
            token: String(repeating: "b", count: 64),
            startedAt: info.startedAt + 1,
            version: info.version
        )

        do {
            _ = try await client.connect(to: other)
            XCTFail("A different broker must not replace an in-flight handshake")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
        let callsAfterRefusal = await transport.connectCalls()
        XCTAssertEqual(callsAfterRefusal, 1)

        await transport.releaseConnect()
        _ = try await active.value
        let completedCalls = await transport.connectCalls()
        XCTAssertEqual(completedCalls, 1)
        await client.disconnect()
    }

    func testDisconnectFailsEveryConnectWaiterAndAllowsCleanRetry() async throws {
        let transport = ScriptedBrokerTransport(
            suspendConnect: true,
            helloAccess: "observer",
            advertiseObserverRole: true
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 500_000_000
        )
        let info = brokerInfo
        let first = Task { try await client.connect(to: info) }
        await transport.waitUntilConnectCallCount(1)
        let second = Task { try await client.connect(to: info) }
        for _ in 0..<100 { await Task.yield() }

        await client.disconnect()
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("Disconnect must fail every caller sharing the connect attempt")
            } catch {
                XCTAssertEqual(error as? BrokerClientError, .connectionClosed)
            }
        }
        let callsAfterDisconnect = await transport.connectCalls()
        XCTAssertEqual(callsAfterDisconnect, 1)

        let hello = try await client.connect(to: info)
        XCTAssertTrue(hello.serverEnforcedObserver)
        let callsAfterRetry = await transport.connectCalls()
        XCTAssertEqual(callsAfterRetry, 2)
        await client.disconnect()
    }

    func testObserverHandshakeIsExplicitAndNewBrokerMustEchoTheRole() async throws {
        let transport = ScriptedBrokerTransport(helloAccess: "observer", advertiseObserverRole: true)
        let client = ObserveOnlyBrokerClient(transport: transport, operationTimeoutNanoseconds: 100_000_000)

        let hello = try await client.connect(to: brokerInfo)
        XCTAssertTrue(hello.serverEnforcedObserver)
        XCTAssertEqual(hello.implementationVersion, BrokerWire.implementationVersion)
        XCTAssertEqual(hello.packageSchema, BrokerWire.helperPackageSchema)
        XCTAssertEqual(hello.packageVersion, "1.0.0")
        XCTAssertEqual(hello.contentDigest, String(repeating: "a", count: 64))
        let frames = await transport.sentFrames()
        let sent = try XCTUnwrap(frames.first?.objectValue)
        XCTAssertEqual(sent["type"]?.stringValue, "hello")
        XCTAssertEqual(sent["access"]?.stringValue, "observer")
        await client.disconnect()

        let refusedTransport = ScriptedBrokerTransport(helloAccess: "controller", advertiseObserverRole: true)
        let refused = ObserveOnlyBrokerClient(
            transport: refusedTransport,
            operationTimeoutNanoseconds: 100_000_000
        )
        do {
            _ = try await refused.connect(to: brokerInfo)
            XCTFail("A broker advertising observer-role enforcement must echo observer access")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .authenticationRejected)
        }
    }

    func testOldProtocolTwoBrokerStaysUsableUnderTheLocalTypedPolicy() async throws {
        let transport = ScriptedBrokerTransport(
            helloAccess: nil,
            advertiseObserverRole: false,
            implementationVersion: nil,
            packageSchema: nil,
            packageVersion: nil,
            contentDigest: nil
        )
        let client = ObserveOnlyBrokerClient(transport: transport, operationTimeoutNanoseconds: 100_000_000)

        let hello = try await client.connect(to: legacyBrokerInfo)
        XCTAssertFalse(hello.serverEnforcedObserver)
        XCTAssertEqual(hello.implementationVersion, 1)
        await client.disconnect()
    }

    func testAdditiveNPlusOneBrokerIsAcceptedButFutureImplementationIsRefused() async throws {
        let compatible = ObserveOnlyBrokerClient(
            transport: ScriptedBrokerTransport(implementationVersion: 2),
            operationTimeoutNanoseconds: 100_000_000
        )
        var info = brokerInfo
        info = BrokerInfo(
            protocolVersion: info.protocolVersion,
            securityEpoch: info.securityEpoch,
            implementationVersion: 2,
            packageSchema: info.packageSchema,
            packageVersion: info.packageVersion,
            pid: info.pid,
            socketPath: info.socketPath,
            token: info.token,
            startedAt: info.startedAt,
            version: info.version
        )
        let compatibleHello = try await compatible.connect(to: info)
        XCTAssertEqual(compatibleHello.implementationVersion, 2)
        await compatible.disconnect()

        let future = ObserveOnlyBrokerClient(
            transport: ScriptedBrokerTransport(implementationVersion: 3),
            operationTimeoutNanoseconds: 100_000_000
        )
        do {
            _ = try await future.connect(to: legacyBrokerInfo)
            XCTFail("An implementation beyond the declared N/N+1 window must be refused")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .implementationMismatch)
        }
    }

    func testHelloAndStatusCannotDriftFromPublishedBrokerIdentity() async throws {
        let changedHello = ObserveOnlyBrokerClient(
            transport: ScriptedBrokerTransport(packageVersion: "2.0.0"),
            operationTimeoutNanoseconds: 100_000_000
        )
        do {
            _ = try await changedHello.connect(to: brokerInfo)
            XCTFail("A package identity change between metadata and hello must be refused")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }

        let changedStatus = ObserveOnlyBrokerClient(
            transport: ScriptedBrokerTransport(
                replyToRequests: true,
                statusImplementationVersion: 1
            ),
            operationTimeoutNanoseconds: 100_000_000
        )
        _ = try await changedStatus.connect(to: brokerInfo)
        do {
            _ = try await changedStatus.inventory()
            XCTFail("A broker identity change after hello must be refused")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
        await changedStatus.disconnect()

        let changedDigest = ObserveOnlyBrokerClient(
            transport: ScriptedBrokerTransport(contentDigest: String(repeating: "b", count: 64)),
            operationTimeoutNanoseconds: 100_000_000
        )
        do {
            _ = try await changedDigest.connect(to: brokerInfo)
            XCTFail("A content digest change between metadata and hello must be refused")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
    }

    func testHandshakeAndReadRequestsAreTimeBounded() async throws {
        let silent = ScriptedBrokerTransport(replyToHello: false)
        let handshakeClient = ObserveOnlyBrokerClient(
            transport: silent,
            operationTimeoutNanoseconds: 5_000_000
        )
        do {
            _ = try await handshakeClient.connect(to: brokerInfo)
            XCTFail("A silent endpoint must not strand the UI")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .connectionTimedOut)
        }

        let helloOnly = ScriptedBrokerTransport(helloAccess: "observer", advertiseObserverRole: true)
        let requestClient = ObserveOnlyBrokerClient(
            transport: helloOnly,
            operationTimeoutNanoseconds: 5_000_000
        )
        _ = try await requestClient.connect(to: brokerInfo)
        do {
            _ = try await requestClient.inventory()
            XCTFail("A silent request must not strand the UI")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .requestTimedOut)
        }
        await requestClient.disconnect()
    }

    func testInventoryUsesOneAtomicBrokerSnapshotWhenAdvertised() async throws {
        let transport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            advertiseAtomicInventory: true,
            replyToRequests: true,
            terminalCapacity: .object([
                "liveTerminalCount": .integer(1),
                "maximumLiveTerminals": .integer(64),
                "availableTerminalSlots": .integer(63),
            ])
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        _ = try await client.connect(to: brokerInfo)

        let inventory = try await client.inventory()
        let methods = await transport.sentFrames().compactMap {
            $0.objectValue?["method"]?.stringValue
        }

        XCTAssertEqual(
            methods,
            ["broker.inventory"]
        )
        XCTAssertEqual(inventory.terminals.map(\.id), ["terminal:codex-1"])
        XCTAssertEqual(inventory.terminalCapacity?.liveTerminalCount, 1)
        XCTAssertEqual(inventory.terminalCapacity?.maximumLiveTerminals, 64)
        XCTAssertEqual(inventory.terminalCapacity?.availableTerminalSlots, 63)
        await client.disconnect()
    }

    func testAtomicInventoryRetriesEpochRejectionsAndStopsAtTheBound() async throws {
        let retryTransport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            advertiseAtomicInventory: true,
            replyToRequests: true,
            atomicInventoryRejections: 2
        )
        let retryClient = ObserveOnlyBrokerClient(
            transport: retryTransport,
            operationTimeoutNanoseconds: 100_000_000
        )
        _ = try await retryClient.connect(to: brokerInfo)
        let inventory = try await retryClient.inventory()
        XCTAssertEqual(inventory.terminals.map(\.id), ["terminal:codex-1"])
        let retryMethods = await retryTransport.sentFrames().compactMap {
            $0.objectValue?["method"]?.stringValue
        }
        XCTAssertEqual(retryMethods, ["broker.inventory", "broker.inventory", "broker.inventory"])
        await retryClient.disconnect()

        let changingTransport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            advertiseAtomicInventory: true,
            replyToRequests: true,
            atomicInventoryRejections: 3
        )
        let changingClient = ObserveOnlyBrokerClient(
            transport: changingTransport,
            operationTimeoutNanoseconds: 100_000_000
        )
        _ = try await changingClient.connect(to: brokerInfo)
        do {
            _ = try await changingClient.inventory()
            XCTFail("An inventory that changes on every bounded attempt must be rejected")
        } catch {
            XCTAssertEqual(
                error as? BrokerClientError,
                .requestFailed("broker inventory kept changing while the snapshot was collected")
            )
        }
        await changingClient.disconnect()
    }

    func testAtomicInventoryRejectsAWrapperAndStatusEpochMismatch() async throws {
        let transport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            advertiseAtomicInventory: true,
            replyToRequests: true,
            atomicInventoryStatusEpochOffset: 1
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        _ = try await client.connect(to: brokerInfo)
        do {
            _ = try await client.inventory()
            XCTFail("A mixed-epoch atomic payload must fail closed")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .malformedResponse)
        }
        await client.disconnect()
    }

    func testLegacyInventoryRetriesWhenItsStatusFenceChanges() async throws {
        let transport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            replyToRequests: true,
            statusEpochs: [1, 2, 2, 2]
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        _ = try await client.connect(to: brokerInfo)

        let inventory = try await client.inventory()
        XCTAssertEqual(inventory.activityEpoch, 2)
        XCTAssertEqual(inventory.terminals.map(\.id), ["terminal:codex-1"])
        let methods = await transport.sentFrames().compactMap {
            $0.objectValue?["method"]?.stringValue
        }
        XCTAssertEqual(methods, [
            "broker.status", "terminal.diagnostics", "terminal.list", "broker.status",
            "broker.status", "terminal.diagnostics", "terminal.list", "broker.status",
        ])
        await client.disconnect()
    }

    func testActivityEpochProbeUsesOnlyBrokerStatus() async throws {
        let transport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            replyToRequests: true,
            activityEpoch: 73
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        _ = try await client.connect(to: brokerInfo)

        let activityEpoch = try await client.inventoryActivityEpoch()
        let methods = await transport.sentFrames().compactMap {
            $0.objectValue?["method"]?.stringValue
        }

        XCTAssertEqual(activityEpoch, 73)
        XCTAssertEqual(methods, ["broker.status"])
        await client.disconnect()
    }

    func testHistoryUsesBoundedTypedObserverRequest() async throws {
        let transport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            advertiseHistory: true,
            replyToRequests: true
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        _ = try await client.connect(to: brokerInfo)
        let terminal = BrokerTerminalRecord(
            id: "terminal:codex-1",
            projectID: "project.one",
            pid: 123,
            exited: false,
            streamEpoch: "epoch",
            endOffset: 5
        )

        let page = try await client.historyPage(
            for: terminal,
            ownerID: "native-observer",
            streamEpoch: "epoch",
            beforeOffset: 5,
            maxBytes: 64 * 1_024
        )

        XCTAssertEqual(page.output, "hello")
        let frames = await transport.sentFrames()
        let request = try XCTUnwrap(frames.last?.objectValue)
        XCTAssertEqual(request["method"]?.stringValue, "terminal.history")
        XCTAssertEqual(request["params"]?.objectValue?["ownerId"]?.stringValue, "native-observer")
        XCTAssertEqual(request["params"]?.objectValue?["projectId"]?.stringValue, "project.one")
        await client.disconnect()
    }

    func testCompanionSubscriptionKeepsUTF8Safe256KiBTailWithoutHistoryPaging() async throws {
        let prefix = "begin\n"
        let suffix = "\nend"
        let output = prefix + String(repeating: "🙂", count: 90_000) + suffix
        let transport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            advertiseHistory: true,
            replyToRequests: true,
            subscribeOutput: output
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        _ = try await client.connect(to: brokerInfo)
        let terminal = BrokerTerminalRecord(
            id: "terminal:codex-1",
            projectID: "project.one",
            pid: 123,
            exited: false,
            streamEpoch: "epoch",
            endOffset: Int64(output.utf8.count)
        )

        let result = try await client.subscribeBounded(
            to: terminal,
            ownerID: "native-observer",
            cursor: nil,
            maximumSnapshotBytes: 256 * 1_024
        )
        guard case let .snapshot(snapshot, _) = result else {
            return XCTFail("expected bounded snapshot")
        }
        XCTAssertLessThanOrEqual(snapshot.output.utf8.count, 256 * 1_024)
        XCTAssertTrue(snapshot.output.hasSuffix(suffix))
        XCTAssertFalse(snapshot.output.hasPrefix(prefix))
        XCTAssertEqual(snapshot.endOffset - snapshot.startOffset, Int64(snapshot.output.utf8.count))
        XCTAssertTrue(snapshot.truncated)
        let methods = await transport.sentFrames().compactMap {
            $0.objectValue?["method"]?.stringValue
        }
        XCTAssertEqual(methods, ["terminal.subscribe"])
        await client.disconnect()
    }

    func testColdSubscribeTopsUpTheTailWithExactlyOneHistoryRequest() async throws {
        // A deep spool whose subscribe snapshot lands well short of the tail.
        // The old client kept paging until it held 64 MiB — sixteen sequential
        // requests at a five-second deadline each — before the first frame.
        let snapshotOutput = String(repeating: "s", count: 1_024)
        let spoolDepth: Int64 = 8 * 1_024 * 1_024
        let transport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            advertiseHistory: true,
            replyToRequests: true,
            subscribeOutput: snapshotOutput,
            subscribeStartOffset: spoolDepth,
            historyPageBytes: 64 * 1_024
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 2_000_000_000
        )
        _ = try await client.connect(to: brokerInfo)
        let terminal = BrokerTerminalRecord(
            id: "terminal:codex-1",
            projectID: "project.one",
            pid: 123,
            exited: false,
            streamEpoch: "epoch",
            endOffset: spoolDepth + Int64(snapshotOutput.utf8.count)
        )

        let result = try await client.subscribe(
            to: terminal,
            ownerID: "native-observer",
            cursor: nil
        )
        guard case let .snapshot(snapshot, _) = result else {
            return XCTFail("expected a snapshot")
        }

        let requests = await transport.sentFrames().compactMap {
            $0.objectValue?["method"]?.stringValue
        }
        XCTAssertEqual(
            requests,
            ["terminal.subscribe", "terminal.history"],
            "The page said hasMore; deeper history belongs to the transcript viewer, not to selection latency."
        )

        let lastFrame = await transport.sentFrames().last
        let historyRequest = try XCTUnwrap(lastFrame?.objectValue?["params"]?.objectValue)
        XCTAssertEqual(historyRequest["beforeOffset"]?.intValue, spoolDepth)
        XCTAssertEqual(
            historyRequest["maxBytes"]?.intValue,
            Int64(ObserverHistoryTailPolicy.coldSubscribeTailBytes - snapshotOutput.utf8.count)
        )

        XCTAssertTrue(snapshot.output.hasSuffix(snapshotOutput), "The live tail must stay last.")
        XCTAssertEqual(snapshot.startOffset, spoolDepth - 64 * 1_024)
        XCTAssertEqual(
            snapshot.endOffset - snapshot.startOffset,
            Int64(snapshot.output.utf8.count),
            "Byte-cursor arithmetic must survive the prepend."
        )
        XCTAssertTrue(snapshot.truncated, "Older bytes remain; the transcript can still reach them.")
        await client.disconnect()
    }

    func testColdSubscribeMakesNoHistoryRequestWhenTheSnapshotAlreadyCoversTheTail() async throws {
        let output = String(repeating: "t", count: 4_096)
        let transport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            advertiseHistory: true,
            replyToRequests: true,
            subscribeOutput: output,
            subscribeStartOffset: 0
        )
        let client = ObserveOnlyBrokerClient(
            transport: transport,
            operationTimeoutNanoseconds: 2_000_000_000
        )
        _ = try await client.connect(to: brokerInfo)
        let terminal = BrokerTerminalRecord(
            id: "terminal:codex-1",
            projectID: "project.one",
            pid: 123,
            exited: false,
            streamEpoch: "epoch",
            endOffset: Int64(output.utf8.count)
        )

        _ = try await client.subscribe(to: terminal, ownerID: "native-observer", cursor: nil)

        let methods = await transport.sentFrames().compactMap {
            $0.objectValue?["method"]?.stringValue
        }
        XCTAssertEqual(methods, ["terminal.subscribe"])
        await client.disconnect()
    }

    private var brokerInfo: BrokerInfo {
        BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: BrokerWire.helperPackageSchema,
            packageVersion: "1.0.0",
            contentDigest: String(repeating: "a", count: 64),
            pid: 12_345,
            socketPath: "/tmp/kaisola-observer-test.sock",
            token: String(repeating: "a", count: 64),
            startedAt: 1_784_250_001_000,
            version: "test"
        )
    }

    private var legacyBrokerInfo: BrokerInfo {
        BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            pid: 12_345,
            socketPath: "/tmp/kaisola-observer-test.sock",
            token: String(repeating: "a", count: 64),
            startedAt: 1_784_250_001_000,
            version: "test"
        )
    }
}

private actor ScriptedBrokerTransport: BrokerByteTransport {
    private let suspendConnect: Bool
    private let replyToHello: Bool
    private let helloAccess: String?
    private let advertiseObserverRole: Bool
    private let advertiseHistory: Bool
    private let advertiseAtomicInventory: Bool
    private let replyToRequests: Bool
    private let implementationVersion: Int?
    private let packageSchema: Int?
    private let packageVersion: String?
    private let contentDigest: String?
    private let statusImplementationVersion: Int?
    private let activityEpoch: Int64
    private let terminalCapacity: JSONValue?
    private let atomicInventoryStatusEpochOffset: Int64
    private let subscribeOutput: String?
    private let subscribeStartOffset: Int64
    private let historyPageBytes: Int?
    private var connectCallCount = 0
    private var atomicInventoryRejections: Int
    private var statusEpochs: [Int64]
    private var connectReleased: Bool
    private var connectGates: [CheckedContinuation<Void, Never>] = []
    private var connectCallWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var frames: [JSONValue] = []
    private var incoming: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?

    init(
        suspendConnect: Bool = false,
        replyToHello: Bool = true,
        helloAccess: String? = nil,
        advertiseObserverRole: Bool = false,
        advertiseHistory: Bool = false,
        advertiseAtomicInventory: Bool = false,
        replyToRequests: Bool = false,
        implementationVersion: Int? = BrokerWire.implementationVersion,
        packageSchema: Int? = BrokerWire.helperPackageSchema,
        packageVersion: String? = "1.0.0",
        contentDigest: String? = String(repeating: "a", count: 64),
        statusImplementationVersion: Int? = nil,
        activityEpoch: Int64 = 1,
        terminalCapacity: JSONValue? = nil,
        statusEpochs: [Int64] = [],
        atomicInventoryRejections: Int = 0,
        atomicInventoryStatusEpochOffset: Int64 = 0,
        subscribeOutput: String? = nil,
        subscribeStartOffset: Int64 = 0,
        historyPageBytes: Int? = nil
    ) {
        self.suspendConnect = suspendConnect
        connectReleased = !suspendConnect
        self.replyToHello = replyToHello
        self.helloAccess = helloAccess
        self.advertiseObserverRole = advertiseObserverRole
        self.advertiseHistory = advertiseHistory
        self.advertiseAtomicInventory = advertiseAtomicInventory
        self.replyToRequests = replyToRequests
        self.implementationVersion = implementationVersion
        self.packageSchema = packageSchema
        self.packageVersion = packageVersion
        self.contentDigest = contentDigest
        self.statusImplementationVersion = statusImplementationVersion
        self.activityEpoch = activityEpoch
        self.terminalCapacity = terminalCapacity
        self.statusEpochs = statusEpochs
        self.atomicInventoryRejections = atomicInventoryRejections
        self.atomicInventoryStatusEpochOffset = atomicInventoryStatusEpochOffset
        self.subscribeOutput = subscribeOutput
        self.subscribeStartOffset = subscribeStartOffset
        self.historyPageBytes = historyPageBytes
    }

    func connect(path: String) async throws {
        connectCallCount += 1
        let ready = connectCallWaiters.filter { connectCallCount >= $0.count }
        connectCallWaiters.removeAll { connectCallCount >= $0.count }
        for observer in ready { observer.continuation.resume() }

        guard suspendConnect, !connectReleased else { return }
        await withCheckedContinuation { connectGates.append($0) }
    }

    func waitUntilConnectCallCount(_ count: Int) async {
        guard connectCallCount < count else { return }
        await withCheckedContinuation { continuation in
            connectCallWaiters.append((count, continuation))
        }
    }

    func releaseConnect() {
        connectReleased = true
        let gates = connectGates
        connectGates.removeAll()
        for gate in gates { gate.resume() }
    }

    func connectCalls() -> Int { connectCallCount }

    func send(_ data: Data) async throws {
        guard let newline = data.firstIndex(of: 0x0A) else { throw BrokerClientError.malformedResponse }
        let frame = try JSONDecoder().decode(JSONValue.self, from: data[..<newline])
        frames.append(frame)
        if replyToHello, frame.objectValue?["type"]?.stringValue == "hello" {
            var features: [JSONValue] = [.string(BrokerWire.terminalObserveFeature)]
            if advertiseObserverRole { features.append(.string(BrokerWire.observerRoleFeature)) }
            if advertiseHistory { features.append(.string(BrokerWire.terminalHistoryFeature)) }
            if advertiseAtomicInventory { features.append(.string(BrokerWire.brokerInventoryFeature)) }
            var fields: [String: JSONValue] = [
                "type": .string("hello"),
                "ok": .bool(true),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
                "features": .array(features),
                "pid": .integer(12_345),
                "startedAt": .integer(1_784_250_001_000),
                "version": .string("test"),
            ]
            if let implementationVersion {
                fields["implementationVersion"] = .integer(Int64(implementationVersion))
            }
            if let packageSchema { fields["packageSchema"] = .integer(Int64(packageSchema)) }
            if let packageVersion { fields["packageVersion"] = .string(packageVersion) }
            if let contentDigest { fields["contentDigest"] = .string(contentDigest) }
            if let helloAccess { fields["access"] = .string(helloAccess) }
            deliver(try encoded(.object(fields)))
            return
        }

        guard replyToRequests,
              let object = frame.objectValue,
              object["type"]?.stringValue == "request",
              let id = object["id"]?.stringValue,
              let method = object["method"]?.stringValue else { return }
        let result: JSONValue
        switch method {
        case "broker.status":
            let epoch = statusEpochs.isEmpty ? activityEpoch : statusEpochs.removeFirst()
            result = statusValue(activityEpoch: epoch)
        case "broker.inventory":
            if atomicInventoryRejections > 0 {
                atomicInventoryRejections -= 1
                result = .object([
                    "ok": .bool(false),
                    "state": .string("activity_changed"),
                    "activityEpoch": .integer(activityEpoch),
                ])
            } else {
                result = .object([
                    "ok": .bool(true),
                    "state": .string("stable"),
                    "activityEpoch": .integer(activityEpoch),
                    "status": statusValue(
                        activityEpoch: activityEpoch + atomicInventoryStatusEpochOffset
                    ),
                    "diagnostics": diagnosticsValue(),
                    "live": liveValue(),
                ])
            }
        case "terminal.diagnostics":
            result = diagnosticsValue()
        case "terminal.list":
            result = liveValue()
        case "terminal.history":
            // A broker may answer with fewer bytes than were requested; the
            // page is still exactly contiguous with `beforeOffset`.
            guard let historyPageBytes else {
                result = .object([
                    "ok": .bool(true),
                    "streamEpoch": .string("epoch"),
                    "output": .string("hello"),
                    "startOffset": .integer(0),
                    "endOffset": .integer(5),
                    "hasMore": .bool(false),
                    "truncated": .bool(false),
                ])
                break
            }
            let beforeOffset = object["params"]?.objectValue?["beforeOffset"]?.intValue ?? 0
            let served = Int64(min(historyPageBytes, Int(clamping: beforeOffset)))
            result = .object([
                "ok": .bool(true),
                "streamEpoch": .string("epoch"),
                "output": .string(String(repeating: "h", count: Int(served))),
                "startOffset": .integer(beforeOffset - served),
                "endOffset": .integer(beforeOffset),
                "hasMore": .bool(beforeOffset - served > 0),
                "truncated": .bool(false),
            ])
        case "terminal.subscribe":
            guard let subscribeOutput else { return }
            result = .object([
                "ok": .bool(true),
                "mode": .string("snapshot"),
                "snapshot": .object([
                    "streamEpoch": .string("epoch"),
                    "output": .string(subscribeOutput),
                    "startOffset": .integer(subscribeStartOffset),
                    "endOffset": .integer(subscribeStartOffset + Int64(subscribeOutput.utf8.count)),
                    "truncated": .bool(subscribeStartOffset > 0),
                    "exited": .bool(false),
                ]),
            ])
        default:
            return
        }
        deliver(try encoded(.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ])))
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func close() async {
        releaseConnect()
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func sentFrames() -> [JSONValue] { frames }

    func inject(_ data: Data?) { deliver(data) }

    private func statusValue(activityEpoch: Int64) -> JSONValue {
        var status: [String: JSONValue] = [
            "ok": .bool(true),
            "protocol": .integer(Int64(BrokerWire.protocolVersion)),
            "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
            "pid": .integer(12_345),
            "startedAt": .integer(1_784_250_001_000),
            "activityEpoch": .integer(activityEpoch),
            "inFlightMutations": .integer(0),
        ]
        if let value = statusImplementationVersion ?? implementationVersion {
            status["implementationVersion"] = .integer(Int64(value))
        }
        if let packageSchema { status["packageSchema"] = .integer(Int64(packageSchema)) }
        if let packageVersion { status["packageVersion"] = .string(packageVersion) }
        if let contentDigest { status["contentDigest"] = .string(contentDigest) }
        if let terminalCapacity { status["terminalCapacity"] = terminalCapacity }
        return .object(status)
    }

    private func diagnosticsValue() -> JSONValue {
        .array([.object([
            "id": .string("terminal:codex-1"),
            "owner": .string("instance|42|project.one"),
            "pid": .integer(123),
            "streamEpoch": .string("epoch"),
            "endOffset": .integer(0),
        ])])
    }

    private func liveValue() -> JSONValue {
        .array([.object([
            "id": .string("terminal:codex-1"),
            "pid": .integer(123),
        ])])
    }

    private func encoded(_ frame: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(frame)
        data.append(0x0A)
        return data
    }

    private func deliver(_ data: Data?) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            incoming.append(data)
        }
    }
}
