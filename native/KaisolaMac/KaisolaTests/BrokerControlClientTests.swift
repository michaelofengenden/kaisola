import Darwin
import Foundation
import KaisolaBrokerProtocol
import KaisolaCore
import XCTest
@testable import Kaisola

private let primaryControlBrokerInfo = BrokerInfo(
    protocolVersion: BrokerWire.protocolVersion,
    securityEpoch: BrokerWire.securityEpoch,
    implementationVersion: BrokerWire.implementationVersion,
    packageSchema: BrokerWire.helperPackageSchema,
    packageVersion: "test-package",
    contentDigest: String(repeating: "c", count: 64),
    pid: 12_345,
    socketPath: "/tmp/kaisola-controller-test.sock",
    token: String(repeating: "a", count: 64),
    startedAt: 1_784_250_001_000,
    version: "test"
)

private let replacementControlBrokerInfo = BrokerInfo(
    protocolVersion: BrokerWire.protocolVersion,
    securityEpoch: BrokerWire.securityEpoch,
    implementationVersion: BrokerWire.implementationVersion,
    packageSchema: BrokerWire.helperPackageSchema,
    packageVersion: "test-package",
    contentDigest: String(repeating: "c", count: 64),
    pid: 12_346,
    socketPath: "/tmp/kaisola-controller-test-next.sock",
    token: String(repeating: "b", count: 64),
    startedAt: 1_784_250_009_000,
    version: "test"
)

private let otherControlBrokerInfoFixture = BrokerInfo(
    protocolVersion: BrokerWire.protocolVersion,
    securityEpoch: BrokerWire.securityEpoch,
    implementationVersion: BrokerWire.implementationVersion,
    packageSchema: BrokerWire.helperPackageSchema,
    packageVersion: "test-package",
    contentDigest: String(repeating: "c", count: 64),
    pid: 12_346,
    socketPath: "/tmp/kaisola-controller-test-other.sock",
    token: String(repeating: "b", count: 64),
    startedAt: 1_784_250_002_000,
    version: "test"
)

private func controlBrokerInfoFixture(for socketPath: String) -> BrokerInfo {
    switch socketPath {
    case replacementControlBrokerInfo.socketPath: replacementControlBrokerInfo
    case otherControlBrokerInfoFixture.socketPath: otherControlBrokerInfoFixture
    default: primaryControlBrokerInfo
    }
}

private func controlHello(
    for info: BrokerInfo,
    replacing field: String? = nil,
    with value: JSONValue? = nil
) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": .string("hello"),
        "ok": .bool(true),
        "protocol": .integer(Int64(info.protocolVersion)),
        "securityEpoch": .integer(Int64(info.securityEpoch)),
        "implementationVersion": .integer(Int64(info.implementationVersion ?? 1)),
        "packageSchema": info.packageSchema.map { .integer(Int64($0)) } ?? .null,
        "packageVersion": info.packageVersion.map(JSONValue.string) ?? .null,
        "contentDigest": info.contentDigest.map(JSONValue.string) ?? .null,
        "pid": .integer(Int64(info.pid)),
        "startedAt": .integer(info.startedAt),
        "version": .string(info.version),
        "features": .array([.string(BrokerWire.terminalObserveFeature)]),
        "negotiatedFeatures": .array([]),
        "access": .string("controller"),
    ]
    if let field, let value { object[field] = value }
    return .object(object)
}

/// The controller lane's contract: its sealed method set is exactly the
/// mutations the native app needs, every request carries the owner identity,
/// and the connection refuses brokers that predate role enforcement.
final class BrokerControlClientTests: XCTestCase {
    func testEveryMutationReconcilesAfterAResponseDelayedBeyondTimeout() async throws {
        let transport = TimeoutReconcilingControlBrokerTransport()
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 50_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        let operations: [(ControlBrokerMethod, (BrokerControlClient) async throws -> Void)] = [
            (.create, { client in
                _ = try await client.createTerminal(
                    projectID: "project.one",
                    terminalID: "terminal-one",
                    command: "/bin/sh",
                    arguments: [],
                    cwd: "/tmp",
                    columns: 80,
                    rows: 24
                )
            }),
            (.attach, { client in
                try await client.attach(projectID: "project.one", terminalID: "terminal-one")
            }),
            (.write, { client in
                try await client.write(projectID: "project.one", terminalID: "terminal-one", data: "date\n")
            }),
            (.resize, { client in
                try await client.resize(
                    projectID: "project.one",
                    terminalID: "terminal-one",
                    columns: 100,
                    rows: 30
                )
            }),
            (.kill, { client in
                try await client.kill(projectID: "project.one", terminalID: "terminal-one")
            }),
            (.release, { client in
                try await client.release(projectID: "project.one", terminalID: "terminal-one")
            }),
            (.detachOwner, { client in
                try await client.detachOwner(projectID: "project.one", terminalID: "terminal-one")
            }),
            (.agentTurn, { client in
                try await client.setAgentTurn(
                    projectID: "project.one",
                    terminalID: "terminal-one",
                    busy: true
                )
            }),
            (.controlLease, { client in
                try await client.setControlLease(
                    projectID: "project.one",
                    terminalID: "terminal-one",
                    active: true
                )
            }),
        ]

        for operation in operations {
            try await operation.1(client)
        }

        let attempts = await transport.attemptsByMethod
        let applications = await transport.applicationsByMethod
        let mutationIDs = await transport.mutationIDsByMethod
        XCTAssertEqual(Set(operations.map(\.0)), Set(ControlBrokerMethod.allCases))
        for method in ControlBrokerMethod.allCases {
            XCTAssertEqual(attempts[method.rawValue], 2, method.rawValue)
            XCTAssertEqual(applications[method.rawValue], 1, method.rawValue)
            let ids = try XCTUnwrap(mutationIDs[method.rawValue], method.rawValue)
            XCTAssertEqual(ids.count, 2, method.rawValue)
            XCTAssertEqual(Set(ids).count, 1, "\(method.rawValue) must reuse its idempotency key")
            XCTAssertNotNil(UUID(uuidString: ids[0]), method.rawValue)
        }
        await client.disconnect()
    }

    func testAdministrativeMutationsReconcileAfterAResponseDelayedBeyondTimeout() async throws {
        let targetDigest = String(repeating: "d", count: 64)
        let operations: [(method: String, call: (BrokerControlClient) async throws -> Void)] = [
            ("broker.prepareRollingUpdate", { client in
                let decision = try await client.requestUpgrade(
                    from: primaryControlBrokerInfo,
                    targetContentDigest: targetDigest
                )
                XCTAssertEqual(decision, .accepted)
            }),
            ("broker.cancelRollingUpdate", { client in
                try await client.cancelRollingUpdate(
                    from: primaryControlBrokerInfo,
                    targetContentDigest: targetDigest
                )
            }),
            ("broker.retireDraining", { client in
                let decision = try await client.requestRetirement(
                    of: primaryControlBrokerInfo,
                    targetContentDigest: targetDigest
                )
                XCTAssertEqual(decision, .accepted)
            }),
        ]

        for operation in operations {
            let transport = TimeoutReconcilingControlBrokerTransport()
            let client = BrokerControlClient(
                transport: transport,
                operationTimeoutNanoseconds: 50_000_000
            )
            try await operation.call(client)
            let attemptsByMethod = await transport.attemptsByMethod
            let applicationsByMethod = await transport.applicationsByMethod
            let mutationIDsByMethod = await transport.mutationIDsByMethod
            let attempts = attemptsByMethod[operation.method]
            let applications = applicationsByMethod[operation.method]
            let ids = try XCTUnwrap(
                mutationIDsByMethod[operation.method],
                operation.method
            )
            XCTAssertEqual(attempts, 2, operation.method)
            XCTAssertEqual(applications, 1, operation.method)
            XCTAssertEqual(ids.count, 2, operation.method)
            XCTAssertEqual(Set(ids).count, 1, "\(operation.method) must reuse its idempotency key")
        }
    }

    func testTimeoutDoesNotBlindlyRetryAnOlderBrokerWithoutIdempotencyReceipts() async throws {
        let transport = TimeoutReconcilingControlBrokerTransport(supportsIdempotency: false)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 50_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        do {
            try await client.write(
                projectID: "project.one",
                terminalID: "terminal-one",
                data: "must-not-duplicate\n"
            )
            XCTFail("An older broker cannot authoritatively reconcile a timed-out mutation.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .requestTimedOut)
        }
        let attempts = await transport.attemptsByMethod
        let applications = await transport.applicationsByMethod
        XCTAssertEqual(attempts[ControlBrokerMethod.write.rawValue], 1)
        XCTAssertEqual(applications[ControlBrokerMethod.write.rawValue], 1)
        await client.disconnect()
    }

    func testOrdinaryControllerRefusesTheAdministrativeOwnerIdentityBeforeConnect() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )

        do {
            try await client.connect(to: controlBrokerInfo, ownerID: "0")
            XCTFail("The ordinary controller lane must never claim broker administration.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .requestFailed("controller owner id"))
        }
        let sentFrames = await transport.sentFrames()
        XCTAssertEqual(sentFrames, [])
    }

    func testAdministrativeHandshakeRequestsAndVerifiesItsOwnCapability() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )

        try await client.connectForAdministration(to: controlBrokerInfo)
        let frames = await transport.sentFrames()
        let hello = try XCTUnwrap(frames.first?.objectValue)
        XCTAssertEqual(hello["access"]?.stringValue, "administrator")
        XCTAssertEqual(
            hello["features"]?.arrayValue?.compactMap(\.stringValue),
            [BrokerWire.brokerAdministrationFeature]
        )
        await client.disconnect()
    }

    func testAdministrativeHandshakeRejectsRoleOrCapabilityDowngrade() async throws {
        for transport in [
            ScriptedControlBrokerTransport(
                resizeAccepted: true,
                helloAccessOverride: "controller"
            ),
            ScriptedControlBrokerTransport(
                resizeAccepted: true,
                grantAdministratorFeature: false
            ),
        ] {
            let client = BrokerControlClient(
                transport: transport,
                operationTimeoutNanoseconds: 100_000_000
            )
            do {
                try await client.connectForAdministration(to: primaryControlBrokerInfo)
                XCTFail("A broker must explicitly grant the requested administrative identity.")
            } catch {
                XCTAssertEqual(error as? BrokerClientError, .authenticationRejected)
            }
            await client.disconnect()
        }
    }

    func testOrdinaryHandshakeDoesNotRequestAdministrativeCapability() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )

        try await client.connect(to: primaryControlBrokerInfo, ownerID: "native-test")
        let frames = await transport.sentFrames()
        let hello = try XCTUnwrap(frames.first?.objectValue)
        XCTAssertEqual(hello["access"]?.stringValue, "controller")
        XCTAssertEqual(hello["features"]?.arrayValue, [])
        await client.disconnect()
    }

    func testCreateSurfacesTypedTerminalCapacityWithoutRawBrokerDetails() async throws {
        let transport = ScriptedControlResultBrokerTransport(result: .object([
            "ok": .bool(false),
            "code": .string("terminal_capacity_exceeded"),
            "message": .string("broker terminal capacity reached"),
            "maximumLiveTerminals": .integer(64),
        ]))
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: primaryControlBrokerInfo, ownerID: "native-test")

        do {
            _ = try await client.createTerminal(
                projectID: "project.one",
                terminalID: "terminal-capacity-rejected",
                command: "/bin/zsh",
                arguments: [],
                cwd: "/tmp",
                columns: 80,
                rows: 24
            )
            XCTFail("A typed process-wide capacity result must reject terminal creation.")
        } catch {
            XCTAssertEqual(
                error as? BrokerClientError,
                .terminalCapacityExceeded(maximum: 64)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "The session service is already running its limit of 64 terminals. Close one and try again."
            )
        }
        await client.disconnect()
    }

    func testHandshakeRejectsEveryImmutableBrokerIdentityMismatch() async throws {
        let mismatches: [(field: String, value: JSONValue, error: BrokerClientError)] = [
            ("protocol", .integer(Int64(BrokerWire.protocolVersion + 1)), .protocolMismatch),
            ("securityEpoch", .integer(Int64(BrokerWire.securityEpoch + 1)), .securityEpochMismatch),
            ("implementationVersion", .integer(1), .identityChanged),
            ("packageSchema", .integer(Int64(BrokerWire.helperPackageSchema + 1)), .identityChanged),
            ("packageVersion", .string("substituted-package"), .identityChanged),
            ("contentDigest", .string(String(repeating: "d", count: 64)), .identityChanged),
            ("pid", .integer(Int64(primaryControlBrokerInfo.pid + 1)), .identityChanged),
            ("startedAt", .integer(primaryControlBrokerInfo.startedAt + 1), .identityChanged),
            ("version", .string("substituted-version"), .identityChanged),
        ]

        for mismatch in mismatches {
            let transport = IdentityControlBrokerTransport(
                hello: controlHello(
                    for: primaryControlBrokerInfo,
                    replacing: mismatch.field,
                    with: mismatch.value
                )
            )
            let client = BrokerControlClient(
                transport: transport,
                operationTimeoutNanoseconds: 100_000_000
            )
            do {
                try await client.connect(to: primaryControlBrokerInfo, ownerID: "native-test")
                XCTFail("A mismatched \(mismatch.field) must not authenticate the controller lane.")
            } catch {
                XCTAssertEqual(error as? BrokerClientError, mismatch.error, mismatch.field)
            }
            await client.disconnect()
        }
    }
    func testOversizedWriteIsRejectedBeforeTransportSend() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        let framesBeforeWrite = await transport.sentFrames().count

        do {
            try await client.write(
                projectID: "project.one",
                terminalID: "terminal-one",
                data: String(repeating: "x", count: BrokerWire.maximumEncodedBytes(for: .request("terminal.write")))
            )
            XCTFail("The request envelope must not widen the terminal.write byte contract.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .frameRejected)
        }

        let framesAfterWrite = await transport.sentFrames().count
        XCTAssertEqual(framesAfterWrite, framesBeforeWrite)
        await client.disconnect()
    }

    func testSmallMethodResponseIsRejectedBeforeJSONValueDecode() async throws {
        let transport = ScriptedControlResultBrokerTransport(result: .object([
            "ok": .bool(true),
            "padding": .string(String(repeating: "x", count: 300 * 1_024)),
        ]))
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 500_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        do {
            try await client.resize(
                projectID: "project.one",
                terminalID: "terminal-one",
                columns: 120,
                rows: 40
            )
            XCTFail("A terminal.resize response must use the small response contract.")
        } catch {
            XCTAssertEqual(
                error as? BrokerWireError,
                .frameTooLarge(maximum: BrokerWire.maximumEncodedBytes(for: .response("terminal.resize")))
            )
        }
        await client.disconnect()
    }

    func testResizeRequiresPositiveBrokerAcknowledgement() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: false)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        do {
            try await client.resize(
                projectID: "project.one",
                terminalID: "terminal-one",
                columns: 120,
                rows: 40
            )
            XCTFail("An inner {ok:false} result must not be cached as applied geometry.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .requestFailed("terminal.resize"))
        }
        await client.disconnect()
    }

    func testWriteMapsEndedAndMissingResultsToDistinctUserVisibleErrors() async throws {
        let failures: [(result: JSONValue, error: TerminalWriteError, description: String)] = [
            (
                .object([
                    "ok": .bool(false),
                    "message": .string("terminal already ended"),
                ]),
                .ended,
                "This terminal has ended and cannot accept input."
            ),
            (
                .object(["ok": .bool(false)]),
                .missing,
                "This terminal is no longer available."
            ),
        ]

        for failure in failures {
            let transport = ScriptedControlResultBrokerTransport(result: failure.result)
            let client = BrokerControlClient(
                transport: transport,
                operationTimeoutNanoseconds: 100_000_000
            )
            try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
            do {
                try await client.write(
                    projectID: "project.one",
                    terminalID: "terminal-one",
                    data: "whoami\n"
                )
                XCTFail("A broker-rejected write must not be reported as delivered.")
            } catch {
                XCTAssertEqual(error as? TerminalWriteError, failure.error)
                XCTAssertEqual(error.localizedDescription, failure.description)
            }
            await client.disconnect()
        }
        XCTAssertNotEqual(failures[0].description, failures[1].description)
    }

    func testWriteRequiresExplicitPositiveBrokerAcknowledgement() async throws {
        for result in [
            JSONValue.object([:]),
            .object(["ok": .string("true")]),
            .string("accepted"),
        ] {
            let transport = ScriptedControlResultBrokerTransport(result: result)
            let client = BrokerControlClient(
                transport: transport,
                operationTimeoutNanoseconds: 100_000_000
            )
            try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
            do {
                try await client.write(
                    projectID: "project.one",
                    terminalID: "terminal-one",
                    data: "pwd\n"
                )
                XCTFail("Malformed terminal.write acknowledgement must fail closed.")
            } catch {
                XCTAssertEqual(error as? BrokerClientError, .malformedResponse)
            }
            await client.disconnect()
        }

        let transport = ScriptedControlResultBrokerTransport(result: .object(["ok": .bool(true)]))
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        try await client.write(
            projectID: "project.one",
            terminalID: "terminal-one",
            data: "pwd\n"
        )
        await client.disconnect()
    }

    func testResizeAcceptsExplicitPositiveBrokerAcknowledgement() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        try await client.resize(
            projectID: "project.one",
            terminalID: "terminal-one",
            columns: 132,
            rows: 44
        )
        let frames = await transport.sentFrames()
        let request = try XCTUnwrap(frames.last?.objectValue)
        XCTAssertEqual(request["method"]?.stringValue, "terminal.resize")
        XCTAssertEqual(request["params"]?.objectValue?["cols"]?.intValue, 132)
        XCTAssertEqual(request["params"]?.objectValue?["rows"]?.intValue, 44)
        await client.disconnect()
    }

    func testAgentTurnRequiresPositiveBrokerAcknowledgement() async throws {
        let transport = ScriptedControlBrokerTransport(
            resizeAccepted: true,
            agentTurnAccepted: false
        )
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        do {
            try await client.setAgentTurn(
                projectID: "project.one",
                terminalID: "terminal-one",
                busy: true
            )
            XCTFail("A refused turn leaves the broker eligible for rolling cutover.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .requestFailed("terminal.agentTurn"))
        }
        await client.disconnect()
    }

    func testAgentTurnAcceptsExplicitPositiveBrokerAcknowledgement() async throws {
        let transport = ScriptedControlBrokerTransport(
            resizeAccepted: true,
            agentTurnAccepted: true
        )
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        try await client.setAgentTurn(
            projectID: "project.one",
            terminalID: "terminal-one",
            busy: true
        )
        let frames = await transport.sentFrames()
        let request = try XCTUnwrap(frames.last?.objectValue)
        XCTAssertEqual(request["method"]?.stringValue, "terminal.agentTurn")
        XCTAssertEqual(request["params"]?.objectValue?["busy"]?.boolValue, true)
        await client.disconnect()
    }

    func testControllerLaneReportsUnexpectedPeerDisconnect() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        let signal = DisconnectSignal()
        await client.setDisconnectHandler { error in
            Task { await signal.record(error) }
        }
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        await transport.disconnectPeer()
        for _ in 0..<100 {
            if await signal.count > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let disconnectCount = await signal.count
        let disconnectDescription = await signal.lastDescription
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(disconnectDescription, BrokerClientError.connectionClosed.localizedDescription)
        await client.disconnect()
    }

    func testRequestSendFailureAbortsControllerExactlyOnce() async throws {
        let transport = ScriptedControlBrokerTransport(
            resizeAccepted: true,
            failFirstRequestSend: true
        )
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        let signal = DisconnectSignal()
        await client.setDisconnectHandler { error in
            Task { await signal.record(error) }
        }
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        do {
            try await client.resize(
                projectID: "project.one",
                terminalID: "terminal-one",
                columns: 120,
                rows: 40
            )
            XCTFail("A failed socket send must invalidate the controller lane.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .connectionClosed)
        }

        for _ in 0..<100 {
            if await signal.count > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let disconnectCount = await signal.count
        XCTAssertEqual(disconnectCount, 1)

        do {
            try await client.resize(
                projectID: "project.one",
                terminalID: "terminal-one",
                columns: 132,
                rows: 44
            )
            XCTFail("A failed controller must be reconnected before accepting another request.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .notConnected)
        }
        await client.disconnect()
    }

    func testExplicitControllerDisconnectDoesNotReportConnectionLoss() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        let signal = DisconnectSignal()
        await client.setDisconnectHandler { error in
            Task { await signal.record(error) }
        }
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        await client.disconnect()
        try await Task.sleep(nanoseconds: 10_000_000)
        let disconnectCount = await signal.count
        XCTAssertEqual(disconnectCount, 0, "App quit/reload must not schedule a recovery reconnect.")
    }

    /// Two callers asking for the same broker at once must share one handshake.
    /// The old single-slot waiter let the second connect overwrite the first
    /// caller's continuation, and that caller then waited forever.
    func testConcurrentConnectsToOneBrokerShareASingleHandshake() async throws {
        let transport = GatedControlBrokerTransport()
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 2_000_000_000
        )
        let outcomes = ConnectOutcomes()
        let info = controlBrokerInfo

        let first = Task { [client] in
            do {
                try await client.connect(to: info, ownerID: "native-test")
                await outcomes.record("first", failure: nil)
            } catch {
                await outcomes.record("first", failure: error)
            }
        }
        defer { first.cancel() }
        try await waitUntil("the first connect reaches the socket") {
            await transport.connectAttemptCount == 1
        }

        let second = Task { [client] in
            do {
                try await client.connect(to: info, ownerID: "native-test")
                await outcomes.record("second", failure: nil)
            } catch {
                await outcomes.record("second", failure: error)
            }
        }
        defer { second.cancel() }
        try await waitUntil("the second connect coalesces onto the first") {
            await client.connectWaiterCount == 1
        }

        await transport.openConnectGate()
        try await waitUntil("both callers are answered") { await outcomes.count == 2 }

        let firstFailure = await outcomes.failure(for: "first")
        let secondFailure = await outcomes.failure(for: "second")
        let connectAttempts = await transport.connectAttemptCount
        let helloFrames = await transport.helloFrameCount()
        let parkedWaiters = await client.connectWaiterCount
        XCTAssertNil(firstFailure)
        XCTAssertNil(secondFailure)
        XCTAssertEqual(connectAttempts, 1, "A coalesced connect must not open a second transport.")
        XCTAssertEqual(
            helloFrames,
            1,
            "Both callers must ride one handshake, not race two on a shared decoder."
        )
        XCTAssertEqual(
            parkedWaiters,
            0,
            "Every coalesced caller must be resumed; none may be left parked."
        )
        await client.disconnect()
    }

    /// A concurrent connect naming a different broker is refused outright. It
    /// must not open a second socket, and the handshake already in flight must
    /// still answer its own caller.
    func testConcurrentConnectToADifferentBrokerIsRefused() async throws {
        let transport = GatedControlBrokerTransport()
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 2_000_000_000
        )
        let outcomes = ConnectOutcomes()
        let info = controlBrokerInfo
        let other = otherControlBrokerInfo

        let first = Task { [client] in
            do {
                try await client.connect(to: info, ownerID: "native-test")
                await outcomes.record("first", failure: nil)
            } catch {
                await outcomes.record("first", failure: error)
            }
        }
        defer { first.cancel() }
        try await waitUntil("the first connect reaches the socket") {
            await transport.connectAttemptCount == 1
        }

        let second = Task { [client] in
            do {
                try await client.connect(to: other, ownerID: "native-test")
                await outcomes.record("second", failure: nil)
            } catch {
                await outcomes.record("second", failure: error)
            }
        }
        defer { second.cancel() }
        try await waitUntil("the mismatched connect is answered") {
            await outcomes.count == 1
        }
        let refusal = await outcomes.failure(for: "second")
        XCTAssertEqual(
            refusal as? BrokerClientError,
            .identityChanged,
            "A connect to another broker must be refused, not raced onto this one."
        )

        await transport.openConnectGate()
        try await waitUntil("the original caller is answered") { await outcomes.count == 2 }
        let firstFailure = await outcomes.failure(for: "first")
        let paths = await transport.connectedPaths()
        let helloFrames = await transport.helloFrameCount()
        let parkedWaiters = await client.connectWaiterCount
        XCTAssertNil(firstFailure, "The in-flight handshake must still answer its own caller.")
        XCTAssertEqual(paths, [info.socketPath])
        XCTAssertEqual(helloFrames, 1)
        XCTAssertEqual(parkedWaiters, 0)
        await client.disconnect()
    }

    /// Polls a condition instead of sleeping a fixed span, so a regression
    /// fails the assertion rather than hanging the suite.
    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for \(description).")
    }

    private var otherControlBrokerInfo: BrokerInfo {
        otherControlBrokerInfoFixture
    }

    func testUnixTransportShutdownWakesBlockedReceive() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let transport = UnixBrokerTransport(connectedFileDescriptor: descriptors[0])
        defer { Darwin.close(descriptors[1]) }

        let receive = Task {
            do {
                _ = try await transport.receive(maximumBytes: 64)
                return true
            } catch {
                // shutdown may surface as EOF or a socket error; both prove the
                // blocked system call was released.
                return true
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        await transport.close()
        let didUnblock = await receive.value
        XCTAssertTrue(didUnblock)
    }

    func testReconnectToAReplacementBrokerIsRejectedWhileTheLaneIsLive() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        do {
            try await client.connect(to: replacementBrokerInfo, ownerID: "native-test")
            XCTFail("A live controller lane must not answer for a different broker.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
        let helloCount = await transport.sentFrames()
            .filter { $0.objectValue?["type"]?.stringValue == "hello" }
            .count
        XCTAssertEqual(helloCount, 1, "The rejected reconnect must not reshape the live handshake.")
        await client.disconnect()
    }

    func testReconnectUnderADifferentOwnerIsRejectedWhileTheLaneIsLive() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-one")

        do {
            try await client.connect(to: controlBrokerInfo, ownerID: "native-two")
            XCTFail("Silent reuse would keep writing as the previous owner.")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
        // The lane still speaks for the owner it connected as, which is exactly
        // why the caller must never be told the new owner was adopted.
        try await client.write(projectID: "project.one", terminalID: "terminal-one", data: "ls\n")
        let frames = await transport.sentFrames()
        let write = try XCTUnwrap(frames.last?.objectValue)
        XCTAssertEqual(write["method"]?.stringValue, "terminal.write")
        XCTAssertEqual(write["params"]?.objectValue?["ownerId"]?.stringValue, "native-one")
        await client.disconnect()
    }

    func testReconnectWithTheSameIdentityReusesTheLiveConnection() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")

        let helloCount = await transport.sentFrames()
            .filter { $0.objectValue?["type"]?.stringValue == "hello" }
            .count
        XCTAssertEqual(helloCount, 1)
        await client.disconnect()
    }

    func testDisconnectReleasesTheIdentitySoAReplacementBrokerCanBeAdopted() async throws {
        let transport = ScriptedControlBrokerTransport(resizeAccepted: true)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-one")
        await client.disconnect()

        try await client.connect(to: replacementBrokerInfo, ownerID: "native-two")
        try await client.write(projectID: "project.one", terminalID: "terminal-one", data: "ls\n")
        let frames = await transport.sentFrames()
        let write = try XCTUnwrap(frames.last?.objectValue)
        XCTAssertEqual(write["params"]?.objectValue?["ownerId"]?.stringValue, "native-two")
        await client.disconnect()
    }

    private var controlBrokerInfo: BrokerInfo {
        primaryControlBrokerInfo
    }

    /// A broker that replaced the one above: new process, new socket, new token.
    private var replacementBrokerInfo: BrokerInfo {
        replacementControlBrokerInfo
    }

    func testControlMethodSetIsExactlyTheNativeMutationSurface() {
        XCTAssertEqual(
            Set(ControlBrokerMethod.allCases.map(\.rawValue)),
            [
                "terminal.create",
                "terminal.attach",
                "terminal.write",
                "terminal.resize",
                "terminal.kill",
                "terminal.release",
                "terminal.detachOwner",
                "terminal.agentTurn",
                "terminal.controlLease",
            ]
        )
    }

    func testControlMethodsNeverOverlapObserverPolicyReads() {
        let controlMethods = Set(ControlBrokerMethod.allCases.map(\.rawValue))
        let observerMethods = Set(ObserveOnlyBrokerMethod.allCases.map(\.rawValue))
        XCTAssertTrue(controlMethods.isDisjoint(with: observerMethods))
        // Every control method is one the observer policy explicitly forbids,
        // proving the two lanes partition the wire surface.
        XCTAssertTrue(controlMethods.isSubset(of: ObserveOnlyBrokerPolicy.forbiddenTerminalMethods))
    }

    func testKillPropagatesMissingAndSignalFailureResults() async throws {
        for (name, result) in [
            (
                "missing",
                JSONValue.object([
                    "id": .string("terminal-one"),
                    "ok": .bool(false),
                    "code": .string("terminal_not_found"),
                ])
            ),
            (
                "signal refusal",
                JSONValue.object([
                    "id": .string("terminal-one"),
                    "ok": .bool(false),
                    "code": .string("terminal_kill_failed"),
                ])
            ),
        ] {
            try await assertKillFails(result: result, context: name)
        }
    }

    func testKillFailsClosedOnMissingOrMismatchedTerminalIdentity() async throws {
        for (name, result) in [
            (
                "missing identity",
                JSONValue.object(["ok": .bool(true)])
            ),
            (
                "mismatched identity",
                JSONValue.object([
                    "id": .string("terminal-two"),
                    "ok": .bool(true),
                ])
            ),
            (
                "non-string identity",
                JSONValue.object([
                    "id": .integer(1),
                    "ok": .bool(true),
                ])
            ),
            (
                "missing acknowledgement",
                JSONValue.object(["id": .string("terminal-one")])
            ),
        ] {
            try await assertKillFails(result: result, context: name)
        }
    }

    func testKillAcceptsAlreadyExitedForTheExactTerminal() async throws {
        let transport = ScriptedControlResultBrokerTransport(result: .object([
            "id": .string("terminal-one"),
            "ok": .bool(true),
            "alreadyExited": .bool(true),
        ]))
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        try await client.kill(projectID: "project.one", terminalID: "terminal-one")

        let frames = await transport.sentFrames()
        let request = try XCTUnwrap(frames.last?.objectValue)
        XCTAssertEqual(request["method"]?.stringValue, "terminal.kill")
        XCTAssertEqual(request["params"]?.objectValue?["projectId"]?.stringValue, "project.one")
        XCTAssertEqual(request["params"]?.objectValue?["id"]?.stringValue, "terminal-one")
        await client.disconnect()
    }

    private func assertKillFails(result: JSONValue, context: String) async throws {
        let transport = ScriptedControlResultBrokerTransport(result: result)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        do {
            try await client.kill(projectID: "project.one", terminalID: "terminal-one")
            XCTFail("\(context) must not be reported as a successful terminal kill")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .requestFailed("terminal.kill"), context)
        }
        await client.disconnect()
    }

    func testAttachPropagatesMissingTerminalResult() async throws {
        try await assertAttachFails(
            result: .object([
                "id": .string("terminal-one"),
                "ok": .bool(false),
                "code": .string("terminal_not_found"),
            ]),
            context: "missing terminal"
        )
    }

    func testAttachFailsClosedOnInvalidAcknowledgementOrIdentity() async throws {
        for (name, result) in [
            (
                "missing identity",
                JSONValue.object(["ok": .bool(true)])
            ),
            (
                "mismatched identity",
                JSONValue.object([
                    "id": .string("terminal-two"),
                    "ok": .bool(true),
                ])
            ),
            (
                "non-string identity",
                JSONValue.object([
                    "id": .integer(1),
                    "ok": .bool(true),
                ])
            ),
            (
                "missing acknowledgement",
                JSONValue.object(["id": .string("terminal-one")])
            ),
        ] {
            try await assertAttachFails(result: result, context: name)
        }
    }

    func testAttachAcceptsExplicitExistingTerminalIdentity() async throws {
        let transport = ScriptedControlResultBrokerTransport(result: .object([
            "id": .string("terminal-one"),
            "ok": .bool(true),
            "exited": .bool(false),
        ]))
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        try await client.attach(projectID: "project.one", terminalID: "terminal-one")

        let frames = await transport.sentFrames()
        let request = try XCTUnwrap(frames.last?.objectValue)
        XCTAssertEqual(request["method"]?.stringValue, "terminal.attach")
        XCTAssertEqual(request["params"]?.objectValue?["projectId"]?.stringValue, "project.one")
        XCTAssertEqual(request["params"]?.objectValue?["id"]?.stringValue, "terminal-one")
        await client.disconnect()
    }

    private func assertAttachFails(result: JSONValue, context: String) async throws {
        let transport = ScriptedControlResultBrokerTransport(result: result)
        let client = BrokerControlClient(
            transport: transport,
            operationTimeoutNanoseconds: 100_000_000
        )
        try await client.connect(to: controlBrokerInfo, ownerID: "native-test")
        do {
            try await client.attach(projectID: "project.one", terminalID: "terminal-one")
            XCTFail("\(context) must not be reported as a successful terminal attach")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .requestFailed("terminal.attach"), context)
        }
        await client.disconnect()
    }

    func testNewTerminalsNeutralizeOuterCLILauncherColorState() {
        XCTAssertEqual(BrokerControlClient.cleanTerminalEnvironment, [
            "PROMPT_EOL_MARK": .string(""),
            "NO_COLOR": .string(""),
            "FORCE_COLOR": .string("1"),
            "CODEX_CI": .string(""),
            "CODEX_MANAGED_BY_NPM": .string(""),
            "CODEX_MANAGED_PACKAGE_ROOT": .string(""),
            "CODEX_THREAD_ID": .string(""),
        ])
    }

    func testUpgradeDecisionPreservesBrokerAuthoritativeBlockersExactly() throws {
        let decision = try BrokerControlClient.upgradeDecision(.object([
            "ok": .bool(false),
            "state": .string("pending"),
            "liveTerminalCount": .integer(2),
            "liveTerminalIds": .array([.string("claude"), .string("codex")]),
            "busyAgentCount": .integer(1),
            "busyTerminalIds": .array([.string("claude")]),
            "childTaskCount": .integer(3),
        ]))
        XCTAssertEqual(decision, .deferred(BrokerUpgradeBlockers(
            liveTerminalCount: 2,
            liveTerminalIDs: ["claude", "codex"],
            busyAgentCount: 1,
            busyTerminalIDs: ["claude"],
            childTaskCount: 3
        )))
    }

    func testUpgradeDecisionRejectsCountAndIdentityDrift() {
        XCTAssertThrowsError(try BrokerControlClient.upgradeDecision(.object([
            "ok": .bool(false),
            "state": .string("pending"),
            "liveTerminalCount": .integer(2),
            "liveTerminalIds": .array([.string("only-one")]),
            "busyAgentCount": .integer(0),
            "busyTerminalIds": .array([]),
            "childTaskCount": .integer(0),
        ]))) { error in
            XCTAssertEqual(error as? BrokerClientError, .malformedResponse)
        }
    }

    func testUpgradePreflightRequiresExactStatusIdentityAndAdvertisedCapability() throws {
        let info = BrokerInfo(
            protocolVersion: 2,
            securityEpoch: 1,
            implementationVersion: 1,
            packageSchema: 1,
            packageVersion: "1.0.0",
            contentDigest: String(repeating: "a", count: 64),
            pid: 7_777,
            socketPath: "/tmp/broker.sock",
            token: String(repeating: "b", count: 64),
            startedAt: 123_456,
            version: "test"
        )
        let valid: JSONValue = .object([
            "ok": .bool(true),
            "pid": .integer(7_777),
            "startedAt": .integer(123_456),
            "implementationVersion": .integer(1),
            "packageSchema": .integer(1),
            "packageVersion": .string("1.0.0"),
            "contentDigest": .string(String(repeating: "a", count: 64)),
            "features": .array([.string(BrokerWire.brokerUpdateFeature)]),
        ])
        XCTAssertNoThrow(try BrokerControlClient.validateUpgradeStatus(valid, expected: info))

        guard var unsupported = valid.objectValue else { return XCTFail("expected object") }
        unsupported["features"] = .array([])
        XCTAssertThrowsError(
            try BrokerControlClient.validateUpgradeStatus(.object(unsupported), expected: info)
        ) { error in
            XCTAssertEqual(error as? BrokerClientError, .identityChanged)
        }
    }

    func testSessionStorePersistsOwnershipAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-session-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("native-sessions.json")

        let first = NativeSessionStore(fileURL: file)
        let owner = first.ownerID()
        XCTAssertTrue(owner.hasPrefix("native-"))
        first.upsert(NativeOwnedSession(
            id: "term-nproj_abc-1",
            projectID: "nproj_abc",
            cwd: "/tmp/example",
            title: "example",
            createdAt: 1
        ))

        let second = NativeSessionStore(fileURL: file)
        XCTAssertEqual(second.ownerID(), owner)
        XCTAssertTrue(second.owns(terminalID: "term-nproj_abc-1"))
        XCTAssertFalse(second.owns(terminalID: "term-proj_electron"))

        second.remove(terminalID: "term-nproj_abc-1")
        XCTAssertFalse(NativeSessionStore(fileURL: file).owns(terminalID: "term-nproj_abc-1"))
    }

    func testProjectIdentityIsDeterministicAndNamespaced() {
        let one = NativeSessionStore.projectID(forDirectory: "/Users/example/code/app")
        let two = NativeSessionStore.projectID(forDirectory: "/Users/example/code/app/")
        let other = NativeSessionStore.projectID(forDirectory: "/Users/example/code/other")
        XCTAssertEqual(one, two)
        XCTAssertNotEqual(one, other)
        XCTAssertTrue(one.hasPrefix("nproj_"))
        XCTAssertFalse(one.hasPrefix("proj_"))
    }

    func testControlSurfaceIncludesAgentTurnAndStaysSealed() {
        XCTAssertTrue(ControlBrokerMethod.allCases.map(\.rawValue).contains("terminal.agentTurn"))
        // Still disjoint from the observer reads and still a strict subset of
        // the methods the observer policy forbids — the two lanes never blur.
        let controlMethods = Set(ControlBrokerMethod.allCases.map(\.rawValue))
        XCTAssertTrue(controlMethods.isDisjoint(with: Set(ObserveOnlyBrokerMethod.allCases.map(\.rawValue))))
        XCTAssertTrue(controlMethods.isSubset(of: ObserveOnlyBrokerPolicy.forbiddenTerminalMethods))
    }

    func testAgentRegistryRecognizesClaudeAndCodexByCommand() {
        XCTAssertEqual(AgentRegistry.profile(id: "claude-code")?.name, "Claude")
        XCTAssertEqual(AgentRegistry.profile(id: "codex")?.name, "Codex")
        XCTAssertEqual(AgentRegistry.profile(forCommand: "claude")?.id, "claude-code")
        XCTAssertEqual(AgentRegistry.profile(forCommand: "/opt/homebrew/bin/codex")?.id, "codex")
        XCTAssertEqual(AgentRegistry.profile(displayName: "Claude")?.id, "claude-code")
        XCTAssertEqual(AgentRegistry.profile(displayName: "codex")?.id, "codex")
        XCTAssertNil(AgentRegistry.profile(displayName: "npm"))
        XCTAssertNil(AgentRegistry.profile(forCommand: "/bin/zsh"))
        XCTAssertNil(AgentRegistry.profile(forCommand: ""))
    }

    func testSessionStorePersistsAgentIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-agent-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("native-sessions.json")

        let store = NativeSessionStore(fileURL: file)
        store.upsert(NativeOwnedSession(
            id: "term-nproj_x-1", projectID: "nproj_x", cwd: "/tmp/x",
            title: "Claude · x", createdAt: 1, agentID: "claude-code"
        ))
        let reread = NativeSessionStore(fileURL: file).sessions().first
        XCTAssertEqual(reread?.agentID, "claude-code")
    }

    func testAgentActivityParsesFromBrokerRecord() {
        let working = BrokerTerminalRecord(
            value: .object([
                "id": .string("term-nproj_a-1"),
                "owner": .string("native-1|1|nproj_a"),
                "agentBusy": .bool(true),
            ])
        )
        XCTAssertEqual(working?.agentActivity, .working)

        let responded = BrokerTerminalRecord(
            value: .object([
                "id": .string("term-nproj_a-2"),
                "owner": .string("native-1|1|nproj_a"),
                "agentBusy": .bool(false),
                "agentCompletedAt": .integer(1_700_000_000_000),
            ])
        )
        XCTAssertEqual(responded?.agentActivity, .responded(at: 1_700_000_000_000))

        let idle = BrokerTerminalRecord(
            value: .object([
                "id": .string("term-nproj_a-3"),
                "owner": .string("native-1|1|nproj_a"),
            ])
        )
        XCTAssertEqual(idle?.agentActivity, .idle)
    }

    func testCorruptStoreDegradesToEmptyRegistry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-session-store-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("native-sessions.json")
        try Data("not json".utf8).write(to: file)

        let store = NativeSessionStore(fileURL: file)
        XCTAssertEqual(store.sessions(), [])
        XCTAssertTrue(store.ownerID().hasPrefix("native-"))
    }
}

private actor ConnectOutcomes {
    private var failures: [String: (any Error)?] = [:]

    var count: Int { failures.count }

    func record(_ label: String, failure: (any Error)?) {
        failures[label] = failure
    }

    func failure(for label: String) -> (any Error)? {
        failures[label] ?? nil
    }
}

private func scriptedControlHello(
    for request: JSONValue,
    info: BrokerInfo = primaryControlBrokerInfo,
    accessOverride: String? = nil,
    grantAdministratorFeature: Bool = true
) -> JSONValue {
    let requestObject = request.objectValue
    let requestedAccess = requestObject?["access"]?.stringValue ?? "controller"
    let requestedFeatures = Set(
        requestObject?["features"]?.arrayValue?.compactMap(\.stringValue) ?? []
    )
    let grantsAdministrator = grantAdministratorFeature
        && requestedAccess == "administrator"
        && requestedFeatures.contains(BrokerWire.brokerAdministrationFeature)
    return .object([
        "type": .string("hello"),
        "ok": .bool(true),
        "protocol": .integer(Int64(BrokerWire.protocolVersion)),
        "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
        "implementationVersion": .integer(Int64(info.implementationVersion ?? 1)),
        "packageSchema": info.packageSchema.map { .integer(Int64($0)) } ?? .null,
        "packageVersion": info.packageVersion.map(JSONValue.string) ?? .null,
        "contentDigest": info.contentDigest.map(JSONValue.string) ?? .null,
        "pid": .integer(Int64(info.pid)),
        "startedAt": .integer(info.startedAt),
        "version": .string(info.version),
        "features": .array([
            .string(BrokerWire.terminalObserveFeature),
            .string(BrokerWire.brokerAdministrationFeature),
        ]),
        "negotiatedFeatures": .array(
            grantsAdministrator ? [.string(BrokerWire.brokerAdministrationFeature)] : []
        ),
        "access": .string(accessOverride ?? requestedAccess),
    ])
}

/// A broker double whose socket open parks until the test opens the gate, so a
/// second connect is guaranteed to arrive while the first handshake is still in
/// flight. Otherwise it answers hello exactly like the scripted double.
private actor GatedControlBrokerTransport: BrokerByteTransport {
    private(set) var connectAttemptCount = 0
    private var paths: [String] = []
    private var gateOpen = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var frames: [JSONValue] = []
    private var incoming: [Data?] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []

    func connect(path: String) async throws {
        connectAttemptCount += 1
        paths.append(path)
        if gateOpen { return }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    func openConnectGate() {
        gateOpen = true
        let parked = gateWaiters
        gateWaiters.removeAll()
        for continuation in parked { continuation.resume() }
    }

    func send(_ data: Data) async throws {
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw BrokerClientError.malformedResponse
        }
        let frame = try JSONDecoder().decode(JSONValue.self, from: data[..<newline])
        frames.append(frame)
        guard frame.objectValue?["type"]?.stringValue == "hello" else { return }
        var reply = try JSONEncoder().encode(scriptedControlHello(for: frame))
        reply.append(0x0A)
        deliver(reply)
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func close() async {
        deliver(nil)
    }

    func connectedPaths() -> [String] { paths }

    func helloFrameCount() -> Int {
        frames.filter { $0.objectValue?["type"]?.stringValue == "hello" }.count
    }

    private func deliver(_ data: Data?) {
        if receiveWaiters.isEmpty {
            incoming.append(data)
        } else {
            receiveWaiters.removeFirst().resume(returning: data)
        }
    }
}

private actor DisconnectSignal {
    private(set) var count = 0
    private(set) var lastDescription: String?

    func record(_ error: any Error) {
        count += 1
        lastDescription = error.localizedDescription
    }
}

private actor ScriptedControlBrokerTransport: BrokerByteTransport {
    private let resizeAccepted: Bool
    private let agentTurnAccepted: Bool
    private var failFirstRequestSend: Bool
    private let helloAccessOverride: String?
    private let grantAdministratorFeature: Bool
    private var frames: [JSONValue] = []
    private var incoming: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var connectedInfo = primaryControlBrokerInfo

    init(
        resizeAccepted: Bool,
        agentTurnAccepted: Bool = true,
        failFirstRequestSend: Bool = false,
        helloAccessOverride: String? = nil,
        grantAdministratorFeature: Bool = true
    ) {
        self.resizeAccepted = resizeAccepted
        self.agentTurnAccepted = agentTurnAccepted
        self.failFirstRequestSend = failFirstRequestSend
        self.helloAccessOverride = helloAccessOverride
        self.grantAdministratorFeature = grantAdministratorFeature
    }

    func connect(path: String) async throws {
        connectedInfo = controlBrokerInfoFixture(for: path)
    }

    func send(_ data: Data) async throws {
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw BrokerClientError.malformedResponse
        }
        let frame = try JSONDecoder().decode(JSONValue.self, from: data[..<newline])
        frames.append(frame)
        guard let object = frame.objectValue,
              let type = object["type"]?.stringValue else { return }
        if type == "hello" {
            deliver(try encoded(scriptedControlHello(
                for: frame,
                info: connectedInfo,
                accessOverride: helloAccessOverride,
                grantAdministratorFeature: grantAdministratorFeature
            )))
            return
        }
        if failFirstRequestSend {
            failFirstRequestSend = false
            throw BrokerClientError.connectionClosed
        }
        guard type == "request", let id = object["id"]?.stringValue else { return }
        let result: JSONValue
        switch object["method"]?.stringValue {
        case "terminal.resize":
            result = .object(["ok": .bool(resizeAccepted)])
        case "terminal.agentTurn":
            result = .object(["ok": .bool(agentTurnAccepted)])
        default:
            result = .object(["ok": .bool(true)])
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
        deliver(nil)
    }

    func disconnectPeer() {
        deliver(nil)
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

/// Dedicated fixture keeps nested result-shape tests independent from the
/// shared controller fixture used by transport and resize contracts.
private actor ScriptedControlResultBrokerTransport: BrokerByteTransport {
    private let result: JSONValue
    private var frames: [JSONValue] = []
    private var incoming: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?

    init(result: JSONValue) {
        self.result = result
    }

    func connect(path: String) async throws {}

    func send(_ data: Data) async throws {
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw BrokerClientError.malformedResponse
        }
        let frame = try JSONDecoder().decode(JSONValue.self, from: data[..<newline])
        frames.append(frame)
        guard let object = frame.objectValue,
              let type = object["type"]?.stringValue else { return }
        if type == "hello" {
            deliver(try encoded(scriptedControlHello(for: frame)))
            return
        }
        guard type == "request", let id = object["id"]?.stringValue else { return }
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
        deliver(nil)
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

private actor IdentityControlBrokerTransport: BrokerByteTransport {
    private let hello: JSONValue
    private var incoming: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?

    init(hello: JSONValue) {
        self.hello = hello
    }

    func connect(path: String) async throws {}

    func send(_ data: Data) async throws {
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw BrokerClientError.malformedResponse
        }
        let frame = try JSONDecoder().decode(JSONValue.self, from: data[..<newline])
        guard frame.objectValue?["type"]?.stringValue == "hello" else { return }
        var reply = try JSONEncoder().encode(hello)
        reply.append(0x0A)
        deliver(reply)
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func close() async {
        deliver(nil)
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

/// Applies the first request but withholds its response past the client's
/// timeout. The retry receives the retained result only when it carries the
/// same mutation id, modeling the broker's bounded idempotency ledger without
/// relying on timing sleeps in the test itself.
private actor TimeoutReconcilingControlBrokerTransport: BrokerByteTransport {
    private let supportsIdempotency: Bool
    private var incoming: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var retainedResults: [String: JSONValue] = [:]
    private(set) var attemptsByMethod: [String: Int] = [:]
    private(set) var applicationsByMethod: [String: Int] = [:]
    private(set) var mutationIDsByMethod: [String: [String]] = [:]

    init(supportsIdempotency: Bool = true) {
        self.supportsIdempotency = supportsIdempotency
    }

    func connect(path: String) async throws {}

    func send(_ data: Data) async throws {
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw BrokerClientError.malformedResponse
        }
        let frame = try JSONDecoder().decode(JSONValue.self, from: data[..<newline])
        guard let object = frame.objectValue,
              let type = object["type"]?.stringValue else { return }
        if type == "hello" {
            var hello = controlHello(for: primaryControlBrokerInfo).objectValue ?? [:]
            let requestedAccess = object["access"]?.stringValue ?? "controller"
            let administration = BrokerWire.brokerAdministrationFeature
            hello["features"] = .array([
                .string(BrokerWire.terminalObserveFeature),
                .string(BrokerWire.brokerUpdateFeature),
                .string(BrokerWire.brokerRollingUpdateFeature),
                .string(administration),
            ] + (supportsIdempotency ? [.string(BrokerWire.brokerMutationIdempotencyFeature)] : []))
            hello["access"] = .string(requestedAccess)
            hello["negotiatedFeatures"] = .array(
                requestedAccess == "administrator" ? [.string(administration)] : []
            )
            deliver(try encoded(.object(hello)))
            return
        }
        guard type == "request",
              let requestID = object["id"]?.stringValue,
              let method = object["method"]?.stringValue,
              let params = object["params"]?.objectValue else {
            throw BrokerClientError.malformedResponse
        }
        if method == "broker.status" {
            deliver(try encoded(.object([
                "type": .string("response"),
                "id": .string(requestID),
                "ok": .bool(true),
                "result": brokerStatus(),
            ])))
            return
        }
        guard let mutationID = params["mutationId"]?.stringValue else {
            throw BrokerClientError.malformedResponse
        }
        attemptsByMethod[method, default: 0] += 1
        mutationIDsByMethod[method, default: []].append(mutationID)
        if retainedResults[mutationID] == nil {
            applicationsByMethod[method, default: 0] += 1
            retainedResults[mutationID] = result(for: method, params: params)
            return
        }
        deliver(try encoded(.object([
            "type": .string("response"),
            "id": .string(requestID),
            "ok": .bool(true),
            "result": retainedResults[mutationID] ?? .null,
        ])))
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    func close() async {
        deliver(nil)
    }

    private func result(for method: String, params: [String: JSONValue]) -> JSONValue {
        switch method {
        case ControlBrokerMethod.create.rawValue:
            .object(["ok": .bool(true), "pid": .integer(42_424)])
        case ControlBrokerMethod.attach.rawValue, ControlBrokerMethod.kill.rawValue:
            .object(["ok": .bool(true), "id": params["id"] ?? .null])
        case ControlBrokerMethod.controlLease.rawValue:
            .object(["ok": .bool(true), "active": params["active"] ?? .bool(false)])
        case "broker.prepareRollingUpdate":
            .object(["ok": .bool(true), "state": .string("rolling")])
        case "broker.cancelRollingUpdate":
            .object(["ok": .bool(true), "state": .string("current")])
        case "broker.retireDraining":
            .object(["ok": .bool(true), "state": .string("retiring")])
        default:
            .object(["ok": .bool(true)])
        }
    }

    private func brokerStatus() -> JSONValue {
        .object([
            "ok": .bool(true),
            "pid": .integer(Int64(primaryControlBrokerInfo.pid)),
            "startedAt": .integer(primaryControlBrokerInfo.startedAt),
            "contentDigest": .string(primaryControlBrokerInfo.contentDigest ?? ""),
            "implementationVersion": .integer(Int64(primaryControlBrokerInfo.implementationVersion ?? 1)),
            "packageSchema": .integer(Int64(primaryControlBrokerInfo.packageSchema ?? 1)),
            "packageVersion": .string(primaryControlBrokerInfo.packageVersion ?? ""),
            "features": .array([.string(BrokerWire.brokerUpdateFeature)]),
        ])
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
