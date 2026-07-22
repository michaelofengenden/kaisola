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
        XCTAssertEqual(hello.implementationVersion, BrokerWire.implementationVersion)
        XCTAssertEqual(hello.packageSchema, BrokerWire.helperPackageSchema)
        XCTAssertEqual(hello.packageVersion, "1.0.0")
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
            packageVersion: nil
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
                statusImplementationVersion: 2
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
            implementationVersion: BrokerWire.implementationVersion,
            packageSchema: BrokerWire.helperPackageSchema,
            packageVersion: "1.0.0",
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
    private let replyToHello: Bool
    private let helloAccess: String?
    private let advertiseObserverRole: Bool
    private let replyToRequests: Bool
    private let implementationVersion: Int?
    private let packageSchema: Int?
    private let packageVersion: String?
    private let statusImplementationVersion: Int?
    private var frames: [JSONValue] = []
    private var incoming: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?

    init(
        replyToHello: Bool = true,
        helloAccess: String? = nil,
        advertiseObserverRole: Bool = false,
        replyToRequests: Bool = false,
        implementationVersion: Int? = BrokerWire.implementationVersion,
        packageSchema: Int? = BrokerWire.helperPackageSchema,
        packageVersion: String? = "1.0.0",
        statusImplementationVersion: Int? = nil
    ) {
        self.replyToHello = replyToHello
        self.helloAccess = helloAccess
        self.advertiseObserverRole = advertiseObserverRole
        self.replyToRequests = replyToRequests
        self.implementationVersion = implementationVersion
        self.packageSchema = packageSchema
        self.packageVersion = packageVersion
        self.statusImplementationVersion = statusImplementationVersion
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
            if let implementationVersion {
                fields["implementationVersion"] = .integer(Int64(implementationVersion))
            }
            if let packageSchema { fields["packageSchema"] = .integer(Int64(packageSchema)) }
            if let packageVersion { fields["packageVersion"] = .string(packageVersion) }
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
            var status: [String: JSONValue] = [
                "ok": .bool(true),
                "protocol": .integer(Int64(BrokerWire.protocolVersion)),
                "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
                "pid": .integer(12_345),
                "startedAt": .integer(1_784_250_001_000),
            ]
            if let value = statusImplementationVersion ?? implementationVersion {
                status["implementationVersion"] = .integer(Int64(value))
            }
            if let packageSchema { status["packageSchema"] = .integer(Int64(packageSchema)) }
            if let packageVersion { status["packageVersion"] = .string(packageVersion) }
            result = .object(status)
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
