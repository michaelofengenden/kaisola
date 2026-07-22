import Foundation
import KaisolaBrokerProtocol
import KaisolaCore
import XCTest
@testable import KaisolaMacPreview

final class ObserveOnlyBrokerClientTests: XCTestCase {
    func testObserverHandshakeIsExplicitAndNewBrokerMustEchoTheRole() async throws {
        let transport = ScriptedBrokerTransport(helloAccess: "observer", advertiseObserverRole: true)
        let client = ObserveOnlyBrokerClient(transport: transport, operationTimeoutNanoseconds: 100_000_000)

        let hello = try await client.connect(to: brokerInfo)
        XCTAssertTrue(hello.serverEnforcedObserver)
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
        let transport = ScriptedBrokerTransport(helloAccess: nil, advertiseObserverRole: false)
        let client = ObserveOnlyBrokerClient(transport: transport, operationTimeoutNanoseconds: 100_000_000)

        let hello = try await client.connect(to: brokerInfo)
        XCTAssertFalse(hello.serverEnforcedObserver)
        await client.disconnect()
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

    func testInventoryUsesEveryPlannedReadSurfaceInOrder() async throws {
        let transport = ScriptedBrokerTransport(
            helloAccess: "observer",
            advertiseObserverRole: true,
            replyToRequests: true
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
            ["broker.status", "terminal.diagnostics", "terminal.list"]
        )
        XCTAssertEqual(inventory.terminals.map(\.id), ["terminal:codex-1"])
        await client.disconnect()
    }

    private var brokerInfo: BrokerInfo {
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
    private let replyToHello: Bool
    private let helloAccess: String?
    private let advertiseObserverRole: Bool
    private let replyToRequests: Bool
    private var frames: [JSONValue] = []
    private var incoming: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?

    init(
        replyToHello: Bool = true,
        helloAccess: String? = nil,
        advertiseObserverRole: Bool = false,
        replyToRequests: Bool = false
    ) {
        self.replyToHello = replyToHello
        self.helloAccess = helloAccess
        self.advertiseObserverRole = advertiseObserverRole
        self.replyToRequests = replyToRequests
    }

    func connect(path: String) async throws {}

    func send(_ data: Data) async throws {
        guard let newline = data.firstIndex(of: 0x0A) else { throw BrokerClientError.malformedResponse }
        let frame = try JSONDecoder().decode(JSONValue.self, from: data[..<newline])
        frames.append(frame)
        if replyToHello, frame.objectValue?["type"]?.stringValue == "hello" {
            var features: [JSONValue] = [.string(BrokerWire.terminalObserveFeature)]
            if advertiseObserverRole { features.append(.string(BrokerWire.observerRoleFeature)) }
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
            result = .object([
                "ok": .bool(true),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
            ])
        case "terminal.diagnostics":
            result = .array([.object([
                "id": .string("terminal:codex-1"),
                "owner": .string("instance|42|project.one"),
                "pid": .integer(123),
                "streamEpoch": .string("epoch"),
                "endOffset": .integer(0),
            ])])
        case "terminal.list":
            result = .array([.object([
                "id": .string("terminal:codex-1"),
                "pid": .integer(123),
            ])])
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
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func sentFrames() -> [JSONValue] { frames }

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
