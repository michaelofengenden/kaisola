import Foundation
import XCTest
@testable import KaisolaSessionBrokerCore

final class SwiftSessionBrokerCoreTests: XCTestCase {
    private let token = String(repeating: "a", count: 64)
    private let digest = String(repeating: "b", count: 64)
    private let instanceID = "123e4567-e89b-42d3-a456-426614174000"

    func testHelloAndRequestFramesUseTheProtocol2WireKeys() throws {
        let hello = BrokerHelloRequest(
            protocolVersion: 2,
            token: token,
            instanceID: instanceID,
            appVersion: "0.1.124",
            access: "observer",
            features: ["broker-inventory-v1"]
        )
        let helloObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any]
        )
        XCTAssertEqual(helloObject["type"] as? String, "hello")
        XCTAssertEqual(helloObject["protocol"] as? Int, 2)
        XCTAssertEqual(helloObject["instanceId"] as? String, instanceID)
        XCTAssertEqual(helloObject["access"] as? String, "observer")
        XCTAssertNil(helloObject["protocolVersion"])
        XCTAssertNil(helloObject["instanceID"])

        let request = BrokerRequest(
            id: "request-1",
            method: "broker.status",
            params: .object(["ownerId": .string("0")])
        )
        let decoded = try JSONDecoder().decode(
            BrokerRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.type, "request")
    }

    func testAuthenticationAcceptsControllerAndNegotiatesOnlyImplementedFeatures() throws {
        let authentication = try authenticationPolicy()
        let result = authentication.authenticate(
            hello: BrokerHelloRequest(
                protocolVersion: 2,
                token: token,
                instanceID: instanceID,
                appVersion: "0.1.124",
                access: "controller",
                features: [
                    "unknown-feature",
                    "broker-inventory-v1",
                    "terminal-observe-v1",
                    "broker-inventory-v1",
                ]
            ),
            peerUID: 501
        )

        guard case let .accepted(client, response) = result else {
            return XCTFail("expected an authenticated controller")
        }
        XCTAssertEqual(client.instanceID, instanceID)
        XCTAssertEqual(client.role, .controller)
        XCTAssertEqual(client.negotiatedFeatures, [
            "terminal-observe-v1",
            "broker-inventory-v1",
        ])
        XCTAssertEqual(response.type, "hello")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.protocolVersion, 2)
        XCTAssertEqual(response.securityEpoch, 1)
        XCTAssertEqual(response.implementationVersion, 2)
        XCTAssertEqual(response.features, [
            "terminal-observe-v1",
            "observer-role-v1",
            "broker-inventory-v1",
        ])
        XCTAssertEqual(response.negotiatedFeatures, client.negotiatedFeatures)
        XCTAssertEqual(response.access, "controller")
        XCTAssertEqual(response.runtimeKind, "swift")
        let responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
        XCTAssertNil(responseObject["shadowMode"])
        XCTAssertNil(responseObject["publicationEligible"])
    }

    func testAuthenticationAcceptsExplicitObserverWithoutRequestedFeatures() throws {
        let result = try authenticationPolicy().authenticate(
            hello: BrokerHelloRequest(
                protocolVersion: 2,
                token: token,
                instanceID: instanceID,
                access: "observer"
            ),
            peerUID: 501
        )

        guard case let .accepted(client, response) = result else {
            return XCTFail("expected an authenticated observer")
        }
        XCTAssertEqual(client.role, .observer)
        XCTAssertEqual(client.negotiatedFeatures, [])
        XCTAssertEqual(response.access, "observer")
        XCTAssertEqual(response.negotiatedFeatures, [])
    }

    func testAuthenticationRejectsAdministratorAndUnknownRoles() throws {
        let authentication = try authenticationPolicy()
        for access in ["administrator", "Observer", "", "reader"] {
            let result = authentication.authenticate(
                hello: BrokerHelloRequest(
                    protocolVersion: 2,
                    token: token,
                    instanceID: instanceID,
                    access: access
                ),
                peerUID: 501
            )
            assertAuthenticationRejected(result)
        }
    }

    func testAuthenticationRequiresExactTokenUIDProtocolAndCanonicalInstance() throws {
        let authentication = try authenticationPolicy()
        let invalid: [(BrokerHelloRequest, UInt32)] = [
            (BrokerHelloRequest(
                protocolVersion: 2,
                token: String(repeating: "a", count: 63) + "b",
                instanceID: instanceID,
                access: "controller"
            ), 501),
            (BrokerHelloRequest(
                protocolVersion: 2,
                token: token,
                instanceID: instanceID,
                access: "controller"
            ), 502),
            (BrokerHelloRequest(
                protocolVersion: 1,
                token: token,
                instanceID: instanceID,
                access: "controller"
            ), 501),
            (BrokerHelloRequest(
                protocolVersion: 2,
                token: token,
                instanceID: instanceID.uppercased(),
                access: "controller"
            ), 501),
            (BrokerHelloRequest(
                protocolVersion: 2,
                token: token,
                instanceID: "123e4567-e89b-12d3-a456-426614174000",
                access: "controller"
            ), 501),
            (BrokerHelloRequest(
                protocolVersion: 2,
                token: token,
                instanceID: instanceID,
                access: nil
            ), 501),
        ]

        for (hello, uid) in invalid {
            assertAuthenticationRejected(authentication.authenticate(hello: hello, peerUID: uid))
        }
    }

    func testAuthenticationPolicyRejectsMalformedLaunchIdentity() {
        XCTAssertThrowsError(try ShadowBrokerServiceConfiguration(
            expectedToken: "not-a-token",
            expectedUID: 501,
            packageSchema: 2,
            packageVersion: "0.1.124",
            contentDigest: digest,
            pid: 12_345,
            startedAt: 1_786_000_000_000,
            version: "0.1.124"
        )) { error in
            XCTAssertEqual(error as? ShadowBrokerServiceConfigurationError, .invalidToken)
        }

        XCTAssertThrowsError(try configuration(contentDigest: "bad")) { error in
            XCTAssertEqual(error as? ShadowBrokerServiceConfigurationError, .invalidContentDigest)
        }
    }

    func testRequestGateEnforcesTheDefaultSixteenRequestClientCeiling() async {
        let gate = BrokerRequestGate()
        var leases: [BrokerRequestLease] = []
        for _ in 0..<16 {
            guard case let .granted(lease) = await gate.acquire(clientID: "flood") else {
                return XCTFail("the first sixteen requests must be admitted")
            }
            leases.append(lease)
        }

        guard case let .rejected(overload) = await gate.acquire(clientID: "flood") else {
            return XCTFail("the seventeenth request must be rejected")
        }
        XCTAssertEqual(overload, BrokerOverload(scope: .client, limit: 16))

        for lease in leases { _ = await lease.release() }
    }

    func testRequestGateEnforcesTheDefaultOneHundredTwentyEightRequestProcessCeiling() async {
        let gate = BrokerRequestGate()
        var leases: [BrokerRequestLease] = []
        for index in 0..<128 {
            let client = "client-\(index / 16)"
            guard case let .granted(lease) = await gate.acquire(clientID: client) else {
                return XCTFail("the first 128 process requests must be admitted")
            }
            leases.append(lease)
        }

        guard case let .rejected(overload) = await gate.acquire(clientID: "ninth-client") else {
            return XCTFail("the 129th process request must be rejected")
        }
        XCTAssertEqual(overload, BrokerOverload(scope: .process, limit: 128))

        for lease in leases { _ = await lease.release() }
    }

    func testRequestLeaseReleaseIsIdempotentAndCannotFreeLaterWork() async throws {
        let gate = try BrokerRequestGate(perClientLimit: 1, processLimit: 1)
        guard case let .granted(first) = await gate.acquire(clientID: "client") else {
            return XCTFail("first request should be admitted")
        }
        let firstRelease = await first.release()
        let repeatedRelease = await first.release()
        XCTAssertTrue(firstRelease)
        XCTAssertFalse(repeatedRelease)

        guard case let .granted(second) = await gate.acquire(clientID: "client") else {
            return XCTFail("capacity should be restored once")
        }
        let staleRelease = await first.release()
        XCTAssertFalse(staleRelease)
        guard case let .rejected(overload) = await gate.acquire(clientID: "other") else {
            return XCTFail("a repeated old release must not free the new request")
        }
        XCTAssertEqual(overload, BrokerOverload(scope: .process, limit: 1))
        let secondRelease = await second.release()
        XCTAssertTrue(secondRelease)
    }

    func testShadowStatusAndInventoryAreStableEmptySwiftSnapshots() async throws {
        let (service, client) = try await authenticatedService(role: "observer")

        let statusResponse = await service.dispatch(
            client: client,
            request: BrokerRequest(id: "status", method: "broker.status")
        )
        XCTAssertTrue(statusResponse.ok)
        let status = try XCTUnwrap(statusResponse.result?.objectValue)
        XCTAssertEqual(status["ok"], .bool(true))
        XCTAssertEqual(status["protocol"], .integer(2))
        XCTAssertEqual(status["securityEpoch"], .integer(1))
        XCTAssertEqual(status["implementationVersion"], .integer(2))
        XCTAssertEqual(status["packageSchema"], .integer(2))
        XCTAssertEqual(status["packageVersion"], .string("0.1.124"))
        XCTAssertEqual(status["contentDigest"], .string(digest))
        XCTAssertEqual(status["features"], .array([
            .string("terminal-observe-v1"),
            .string("observer-role-v1"),
            .string("broker-inventory-v1"),
        ]))
        XCTAssertEqual(status["runtimeKind"], .string("swift"))
        XCTAssertNil(status["shadowMode"])
        XCTAssertNil(status["publicationEligible"])
        XCTAssertEqual(status["generationState"], .string("current"))
        XCTAssertEqual(status["activityEpoch"], .integer(1))
        XCTAssertEqual(status["inFlightMutations"], .integer(0))
        XCTAssertEqual(status["terminals"], .array([]))

        let inventoryResponse = await service.dispatch(
            client: client,
            request: BrokerRequest(id: "inventory", method: "broker.inventory")
        )
        XCTAssertTrue(inventoryResponse.ok)
        let inventory = try XCTUnwrap(inventoryResponse.result?.objectValue)
        XCTAssertEqual(inventory["ok"], .bool(true))
        XCTAssertEqual(inventory["state"], .string("stable"))
        XCTAssertEqual(inventory["activityEpoch"], .integer(1))
        XCTAssertEqual(inventory["status"], .object(status))
        XCTAssertEqual(inventory["diagnostics"], .array([]))
        XCTAssertEqual(inventory["live"], .array([]))
    }

    func testShadowListDiagnosticsAndAbsentSubscriptionMatchEmptyBrokerSemantics() async throws {
        let (service, client) = try await authenticatedService(role: "controller")

        for method in ["terminal.list", "terminal.diagnostics"] {
            let response = await service.dispatch(
                client: client,
                request: BrokerRequest(id: method, method: method)
            )
            XCTAssertTrue(response.ok, method)
            XCTAssertEqual(response.result, .array([]), method)
        }

        let subscribe = await service.dispatch(
            client: client,
            request: BrokerRequest(
                id: "subscribe",
                method: "terminal.subscribe",
                params: .object(["id": .string("absent")])
            )
        )
        XCTAssertTrue(subscribe.ok)
        XCTAssertEqual(subscribe.result, .object([
            "ok": .bool(false),
            "message": .string("Terminal is no longer available."),
        ]))

        let unsubscribe = await service.dispatch(
            client: client,
            request: BrokerRequest(
                id: "unsubscribe",
                method: "terminal.unsubscribe",
                params: .object(["id": .string("absent")])
            )
        )
        XCTAssertTrue(unsubscribe.ok)
        XCTAssertEqual(unsubscribe.result, .object([
            "ok": .bool(true),
            "removed": .bool(false),
        ]))
    }

    func testShadowModeRejectsEveryProtocolMutationWithoutSideEffects() async throws {
        let (service, client) = try await authenticatedService(role: "controller")
        let mutationMethods = [
            "broker.shutdown",
            "broker.shutdownForUpdate",
            "broker.prepareCleanStartRollback",
            "broker.prepareRollingUpdate",
            "broker.cancelRollingUpdate",
            "broker.retireDraining",
            "terminal.create",
            "terminal.attach",
            "terminal.detachRenderer",
            "terminal.detachOwner",
            "terminal.write",
            "terminal.agentTurn",
            "terminal.resize",
            "terminal.signal",
            "terminal.kill",
            "terminal.release",
            "terminal.scheduleRelease",
            "terminal.cancelRelease",
            "terminal.setFocused",
            "terminal.controlLease",
        ]

        for method in mutationMethods {
            let response = await service.dispatch(
                client: client,
                request: BrokerRequest(id: method, method: method)
            )
            XCTAssertFalse(response.ok, method)
            XCTAssertEqual(response.code, "shadow_mode", method)
            XCTAssertEqual(response.message, "broker shadow mode rejects mutations", method)
            XCTAssertNil(response.result, method)
        }

        let inventory = await service.dispatch(
            client: client,
            request: BrokerRequest(id: "after", method: "broker.inventory")
        )
        XCTAssertEqual(inventory.result?.objectValue?["activityEpoch"], .integer(1))
        XCTAssertEqual(inventory.result?.objectValue?["live"], .array([]))
    }

    func testUnimplementedReadMethodFailsWithTypedUnsupportedMethodResponse() async throws {
        let (service, client) = try await authenticatedService(role: "observer")
        let response = await service.dispatch(
            client: client,
            request: BrokerRequest(id: "history", method: "terminal.history")
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, "unsupported_method")
        XCTAssertEqual(response.message, "unsupported broker method: terminal.history")
    }

    func testServiceRejectsForgedAndDisconnectedAuthenticatedClients() async throws {
        let (service, client) = try await authenticatedService(role: "observer")
        let forged = BrokerAuthenticatedClient(
            instanceID: client.instanceID,
            role: .controller,
            negotiatedFeatures: client.negotiatedFeatures
        )
        let forgedResponse = await service.dispatch(
            client: forged,
            request: BrokerRequest(id: "forged", method: "broker.status")
        )
        XCTAssertFalse(forgedResponse.ok)
        XCTAssertEqual(forgedResponse.code, "authentication_required")

        await service.disconnect(client: client)
        let disconnectedResponse = await service.dispatch(
            client: client,
            request: BrokerRequest(id: "disconnected", method: "broker.status")
        )
        XCTAssertFalse(disconnectedResponse.ok)
        XCTAssertEqual(disconnectedResponse.code, "authentication_required")
    }

    func testSecondIdenticalHelloInvalidatesTheFirstConnectionRegistration() async throws {
        let service = try ShadowBrokerService(configuration: configuration())
        let hello = BrokerHelloRequest(
            protocolVersion: 2,
            token: token,
            instanceID: instanceID,
            access: "observer"
        )

        guard case let .accepted(first, _) = await service.authenticate(
            hello: hello,
            peerUID: 501
        ) else {
            return XCTFail("expected the first connection to authenticate")
        }
        guard case let .accepted(replacement, _) = await service.authenticate(
            hello: hello,
            peerUID: 501
        ) else {
            return XCTFail("expected the replacement connection to authenticate")
        }

        let superseded = await service.dispatch(
            client: first,
            request: BrokerRequest(id: "superseded", method: "broker.status")
        )
        XCTAssertFalse(superseded.ok)
        XCTAssertEqual(superseded.code, "authentication_required")

        let current = await service.dispatch(
            client: replacement,
            request: BrokerRequest(id: "current", method: "broker.status")
        )
        XCTAssertTrue(current.ok)
    }

    func testStaleDisconnectCannotRemoveTheReplacementConnectionRegistration() async throws {
        let service = try ShadowBrokerService(configuration: configuration())
        let hello = BrokerHelloRequest(
            protocolVersion: 2,
            token: token,
            instanceID: instanceID,
            access: "controller"
        )

        guard case let .accepted(first, _) = await service.authenticate(
            hello: hello,
            peerUID: 501
        ) else {
            return XCTFail("expected the first connection to authenticate")
        }
        guard case let .accepted(replacement, _) = await service.authenticate(
            hello: hello,
            peerUID: 501
        ) else {
            return XCTFail("expected the replacement connection to authenticate")
        }

        await service.disconnect(client: first)

        let current = await service.dispatch(
            client: replacement,
            request: BrokerRequest(id: "replacement", method: "broker.status")
        )
        XCTAssertTrue(current.ok)
    }

    private func configuration(
        contentDigest: String? = nil
    ) throws -> ShadowBrokerServiceConfiguration {
        try ShadowBrokerServiceConfiguration(
            expectedToken: token,
            expectedUID: 501,
            packageSchema: 2,
            packageVersion: "0.1.124",
            contentDigest: contentDigest ?? digest,
            pid: 12_345,
            startedAt: 1_786_000_000_000,
            version: "0.1.124"
        )
    }

    private func authenticationPolicy() throws -> BrokerAuthentication {
        BrokerAuthentication(configuration: try configuration())
    }

    private func authenticatedService(
        role: String
    ) async throws -> (ShadowBrokerService, BrokerAuthenticatedClient) {
        let service = try ShadowBrokerService(configuration: configuration())
        let result = await service.authenticate(
            hello: BrokerHelloRequest(
                protocolVersion: 2,
                token: token,
                instanceID: instanceID,
                access: role
            ),
            peerUID: 501
        )
        guard case let .accepted(client, _) = result else {
            throw TestFailure.authenticationRejected
        }
        return (service, client)
    }

    private func assertAuthenticationRejected(
        _ result: BrokerAuthenticationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .rejected(response) = result else {
            return XCTFail("expected authentication rejection", file: file, line: line)
        }
        XCTAssertEqual(response.type, "hello", file: file, line: line)
        XCTAssertFalse(response.ok, file: file, line: line)
        XCTAssertEqual(
            response.message,
            "broker authentication failed",
            file: file,
            line: line
        )
        XCTAssertNil(response.protocolVersion, file: file, line: line)
        XCTAssertNil(response.access, file: file, line: line)
    }

    private enum TestFailure: Error {
        case authenticationRejected
    }
}
