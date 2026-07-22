import Darwin
import KaisolaBrokerProtocol
import KaisolaCore
import XCTest
@testable import KaisolaMacPreview

@MainActor
final class AppModelReconnectTests: XCTestCase {
    func testDisconnectRetriesAndResubscribesFromTheVisibleCursor() async throws {
        let fixture = try Fixture(failingConnectAttempts: [2])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        XCTAssertTrue(fixture.model.connectionState.isConnected)
        XCTAssertEqual(fixture.model.terminalDocument.output, "hello")

        await fixture.client.simulateDisconnect()
        await waitUntil {
            let attempts = await fixture.client.connectionAttempts()
            let subscriptions = await fixture.client.subscriptionCursors()
            return attempts >= 3
                && subscriptions.count >= 2
                && fixture.model.connectionState.isConnected
        }

        let attempts = await fixture.client.connectionAttempts()
        let cursors = await fixture.client.subscriptionCursors()
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(cursors, [nil, TerminalCursor(streamEpoch: "epoch", offset: 5)])
        XCTAssertEqual(fixture.model.terminalDocument.output, "hello")
        await fixture.model.disconnect()
    }

    func testWakeReopensTheSocketWithoutDiscardingVisibleScrollback() async throws {
        let fixture = try Fixture(failingConnectAttempts: [])
        defer { fixture.cleanUp() }
        await fixture.model.reload()
        await fixture.model.recoverAfterWake()

        let attempts = await fixture.client.connectionAttempts()
        let cursors = await fixture.client.subscriptionCursors()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(cursors, [nil, TerminalCursor(streamEpoch: "epoch", offset: 5)])
        XCTAssertEqual(fixture.model.terminalDocument.output, "hello")
        await fixture.model.disconnect()
    }

    private func waitUntil(
        iterations: Int = 500,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("The reconnect state machine did not settle")
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let client: ReconnectBrokerClient
    let model: AppModel

    init(failingConnectAttempts: Set<Int>) throws {
        root = URL(fileURLWithPath: "/tmp/kaisola-app-model-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(root.path, 0o700)
        client = ReconnectBrokerClient(failingConnectAttempts: failingConnectAttempts)
        model = AppModel(
            brokerPreparer: LocatedBrokerInfoPreparer(locator: FixedBrokerLocator(info: Self.brokerInfo)),
            client: client,
            cursorStore: TerminalCursorStore(fileURL: root.appendingPathComponent("cursors.json")),
            reconnectBackoff: BrokerReconnectBackoff(
                baseNanoseconds: 1,
                maximumNanoseconds: 2,
                jitterFraction: 0
            ),
            sleep: { _ in await Task.yield() },
            jitter: { 0 }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static var brokerInfo: BrokerInfo {
        BrokerInfo(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            pid: 12_345,
            socketPath: "/tmp/kaisola-app-model.sock",
            token: String(repeating: "a", count: 64),
            startedAt: 1_784_250_001_000,
            version: "test"
        )
    }
}

private struct FixedBrokerLocator: BrokerInfoLocating {
    let info: BrokerInfo

    func locate() throws -> BrokerInfo { info }
}

private actor ReconnectBrokerClient: ObserveOnlyBrokerServing {
    private let failingConnectAttempts: Set<Int>
    private var connectCount = 0
    private var cursors: [TerminalCursor?] = []
    private var disconnectHandler: (@Sendable (any Error) -> Void)?

    init(failingConnectAttempts: Set<Int>) {
        self.failingConnectAttempts = failingConnectAttempts
    }

    func setEventHandler(_ handler: (@Sendable (BrokerEvent) -> Void)?) async {}

    func setDisconnectHandler(_ handler: (@Sendable (any Error) -> Void)?) async {
        disconnectHandler = handler
    }

    func connect(to info: BrokerInfo) async throws -> BrokerHello {
        connectCount += 1
        if failingConnectAttempts.contains(connectCount) {
            throw BrokerClientError.connectionClosed
        }
        return BrokerHello(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: nil,
            packageVersion: nil,
            features: [BrokerWire.terminalObserveFeature, BrokerWire.observerRoleFeature],
            pid: info.pid,
            startedAt: info.startedAt,
            version: info.version,
            serverEnforcedObserver: true
        )
    }

    func inventory() async throws -> BrokerStatus {
        let expectedHello = BrokerHello(
            protocolVersion: BrokerWire.protocolVersion,
            securityEpoch: BrokerWire.securityEpoch,
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: nil,
            packageVersion: nil,
            features: [BrokerWire.terminalObserveFeature, BrokerWire.observerRoleFeature],
            pid: 12_345,
            startedAt: 1_784_250_001_000,
            version: "test",
            serverEnforcedObserver: true
        )
        return try BrokerStatus(
            status: .object([
                "ok": .bool(true),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
            ]),
            diagnostics: .array([.object([
                "id": .string("terminal:codex-1"),
                "owner": .string("instance|42|project.one"),
                "pid": .integer(123),
                "streamEpoch": .string("epoch"),
                "endOffset": .integer(5),
            ])]),
            live: .array([.object([
                "id": .string("terminal:codex-1"),
                "pid": .integer(123),
            ])]),
            expectedHello: expectedHello
        )
    }

    func subscribe(
        to terminal: BrokerTerminalRecord,
        ownerID: String,
        cursor: TerminalCursor?
    ) async throws -> TerminalSubscriptionResult {
        cursors.append(cursor)
        if let cursor { return .current(cursor) }
        return .snapshot(
            try TerminalSnapshot(value: .object([
                "streamEpoch": .string("epoch"),
                "output": .string("hello"),
                "startOffset": .integer(0),
                "endOffset": .integer(5),
            ])),
            resetReason: nil
        )
    }

    func unsubscribe(from terminal: BrokerTerminalRecord, ownerID: String) async throws {}
    func disconnect() async {}

    func simulateDisconnect() {
        disconnectHandler?(BrokerClientError.connectionClosed)
    }

    func connectionAttempts() -> Int { connectCount }
    func subscriptionCursors() -> [TerminalCursor?] { cursors }
}
