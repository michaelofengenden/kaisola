import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

final class CompanionTerminalStreamHubTests: XCTestCase {
    func testMultiplexesOneBrokerSubscriptionAndFansOutContiguousOutput() async throws {
        let broker = FakeCompanionTerminalBroker()
        let deliveries = DeliveryCapture()
        let hub = CompanionTerminalStreamHub(
            broker: broker,
            locator: FakeBrokerLocator(),
            ownerID: "native-owner",
            eventSink: { deliveries.append($0) }
        )
        let terminal = record(endOffset: 5)
        let first = await hub.subscribe(
            connectionID: "socket-1",
            command: command(id: "command-subscribe-1"),
            terminal: terminal
        )
        let second = await hub.subscribe(
            connectionID: "socket-2",
            command: command(id: "command-subscribe-2"),
            terminal: terminal
        )

        XCTAssertEqual(first.receipt.status, .applied)
        XCTAssertEqual(first.initialSnapshot?.fields["output"]?.stringValue, "hello")
        XCTAssertEqual(second.initialSnapshot?.fields["endOffset"]?.intValue, 5)
        let subscriptions = await broker.subscribeCount()
        XCTAssertEqual(subscriptions, 1)

        await broker.emit(BrokerEvent(
            ownerID: "native-owner",
            projectID: "project.one",
            terminalID: "terminal:codex-1",
            kind: .output(epoch: "epoch", startOffset: 5, endOffset: 9, data: "🙂")
        ))
        for _ in 0..<50 where deliveries.values().isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let delivery = try XCTUnwrap(deliveries.values().last)
        XCTAssertEqual(delivery.connectionIDs, ["socket-1", "socket-2"])
        XCTAssertEqual(delivery.kind, .event)
        XCTAssertEqual(delivery.body.fields["data"]?.stringValue, "🙂")
        XCTAssertEqual(delivery.body.fields["startOffset"]?.intValue, 5)
        XCTAssertEqual(delivery.body.fields["endOffset"]?.intValue, 9)

        await broker.emit(BrokerEvent(
            ownerID: "native-owner",
            projectID: "project.one",
            terminalID: "terminal:codex-1",
            kind: .snapshotRequired
        ))
        for _ in 0..<50 where deliveries.values().count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let replacement = try XCTUnwrap(deliveries.values().last)
        XCTAssertEqual(replacement.kind, .event)
        XCTAssertEqual(replacement.body.type, "terminal.snapshot")
        XCTAssertEqual(replacement.body.fields["snapshotRequired"]?.boolValue, true)

        _ = await hub.unsubscribe(
            connectionID: "socket-1",
            command: command(id: "command-unsubscribe-1", type: "stream.unsubscribe"),
            terminal: terminal
        )
        let intermediateUnsubscriptions = await broker.unsubscribeCount()
        XCTAssertEqual(intermediateUnsubscriptions, 0)
        _ = await hub.unsubscribe(
            connectionID: "socket-2",
            command: command(id: "command-unsubscribe-2", type: "stream.unsubscribe"),
            terminal: terminal
        )
        let finalUnsubscriptions = await broker.unsubscribeCount()
        XCTAssertEqual(finalUnsubscriptions, 1)
        await hub.shutdown()
    }

    func testRejectsCrossProjectTerminalBeforeTouchingBroker() async {
        let broker = FakeCompanionTerminalBroker()
        let hub = CompanionTerminalStreamHub(
            broker: broker,
            locator: FakeBrokerLocator(),
            ownerID: "native-owner",
            eventSink: { _ in }
        )
        let response = await hub.subscribe(
            connectionID: "socket-1",
            command: command(id: "command-cross-project", projectID: "project.two"),
            terminal: record(endOffset: 5)
        )
        XCTAssertEqual(response.receipt.status, .rejected)
        let subscriptions = await broker.subscribeCount()
        XCTAssertEqual(subscriptions, 0)
    }

    private func record(endOffset: Int64) -> BrokerTerminalRecord {
        BrokerTerminalRecord(
            id: "terminal:codex-1",
            projectID: "project.one",
            pid: 123,
            exited: false,
            streamEpoch: "epoch",
            endOffset: endOffset
        )
    }

    private func command(
        id: String,
        type: String = "stream.subscribe",
        projectID: String = "project.one"
    ) -> CompanionCommandBody {
        CompanionCommandBody(
            type: type,
            commandId: id,
            projectId: projectID,
            targetId: "terminal:codex-1",
            capability: .observe,
            expectedRevision: nil,
            payload: nil
        )
    }
}

private struct FakeBrokerLocator: BrokerInfoLocating {
    func locate() throws -> BrokerInfo {
        BrokerInfo(
            protocolVersion: 3,
            securityEpoch: 3,
            pid: 123,
            socketPath: "/tmp/fake.sock",
            token: String(repeating: "a", count: 64),
            startedAt: 1,
            version: "test"
        )
    }
}

private actor FakeCompanionTerminalBroker: CompanionTerminalBrokerServing {
    private var eventHandler: (@Sendable (BrokerEvent) -> Void)?
    private var disconnectHandler: (@Sendable (any Error) -> Void)?
    private var subscriptions = 0
    private var unsubscriptions = 0

    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) { eventHandler = handler }
    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) { disconnectHandler = handler }
    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        BrokerHello(
            protocolVersion: info.protocolVersion,
            securityEpoch: info.securityEpoch,
            implementationVersion: 1,
            packageSchema: nil,
            packageVersion: nil,
            features: [],
            pid: info.pid,
            startedAt: info.startedAt,
            version: info.version,
            serverEnforcedObserver: true
        )
    }
    func subscribeBounded(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?,
        maximumSnapshotBytes: Int
    ) async throws -> TerminalSubscriptionResult {
        subscriptions += 1
        return .snapshot(TerminalSnapshot(
            streamEpoch: "epoch",
            output: "hello",
            startOffset: 0,
            endOffset: 5,
            truncated: false,
            exited: false
        ), resetReason: nil)
    }
    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) { unsubscriptions += 1 }
    func disconnect() {}
    func emit(_ event: BrokerEvent) { eventHandler?(event) }
    func subscribeCount() -> Int { subscriptions }
    func unsubscribeCount() -> Int { unsubscriptions }
}

private final class DeliveryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [CompanionTerminalStreamDelivery] = []
    func append(_ value: CompanionTerminalStreamDelivery) { lock.withLock { captured.append(value) } }
    func values() -> [CompanionTerminalStreamDelivery] { lock.withLock { captured } }
}
