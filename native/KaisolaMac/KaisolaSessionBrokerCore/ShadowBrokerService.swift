import Foundation
import KaisolaBrokerProtocol

public actor ShadowBrokerService {
    private static let mutationMethods: Set<String> = [
        "broker.shutdown",
        "broker.shutdownForUpdate",
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

    private let configuration: ShadowBrokerServiceConfiguration
    private let authentication: BrokerAuthentication
    private let requestGate: BrokerRequestGate
    private var authenticatedClients: [String: BrokerAuthenticatedClient] = [:]

    public init(
        configuration: ShadowBrokerServiceConfiguration,
        requestGate: BrokerRequestGate = BrokerRequestGate()
    ) throws {
        self.configuration = configuration
        self.authentication = BrokerAuthentication(configuration: configuration)
        self.requestGate = requestGate
    }

    public func authenticate(
        hello: BrokerHelloRequest,
        peerUID: UInt32
    ) -> BrokerAuthenticationResult {
        let result = authentication.authenticate(hello: hello, peerUID: peerUID)
        if case let .accepted(client, _) = result {
            // A later hello with the same instance replaces the authority held
            // by the old connection. A stale disconnect below cannot remove it
            // unless the complete authenticated identity still matches.
            authenticatedClients[client.instanceID] = client
        }
        return result
    }

    public func disconnect(client: BrokerAuthenticatedClient) {
        guard authenticatedClients[client.instanceID] == client else { return }
        authenticatedClients.removeValue(forKey: client.instanceID)
    }

    public func dispatch(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest
    ) async -> BrokerResponse {
        guard authenticatedClients[client.instanceID] == client else {
            return .failure(
                id: request.id,
                code: "authentication_required",
                message: "broker authentication is required"
            )
        }
        guard request.type == "request", !request.id.isEmpty, !request.method.isEmpty else {
            return .failure(
                id: request.id,
                code: "invalid_request",
                message: "invalid broker request"
            )
        }

        let admission = await requestGate.acquire(clientID: client.instanceID)
        guard case let .granted(lease) = admission else {
            guard case let .rejected(overload) = admission else {
                return .failure(
                    id: request.id,
                    code: "broker_overloaded",
                    message: "broker request capacity exceeded"
                )
            }
            return .failure(
                id: request.id,
                code: "broker_overloaded",
                message: "broker request capacity exceeded",
                scope: overload.scope.rawValue,
                limit: overload.limit
            )
        }

        let response = dispatchAdmitted(request)
        _ = await lease.release()
        return response
    }

    private func dispatchAdmitted(_ request: BrokerRequest) -> BrokerResponse {
        if Self.mutationMethods.contains(request.method) {
            return .failure(
                id: request.id,
                code: "shadow_mode",
                message: "broker shadow mode rejects mutations"
            )
        }

        switch request.method {
        case "broker.status":
            return .success(id: request.id, result: .object(statusSnapshot()))

        case "broker.inventory":
            let status = statusSnapshot()
            return .success(id: request.id, result: .object([
                "ok": .bool(true),
                "state": .string("stable"),
                "activityEpoch": .integer(1),
                "status": .object(status),
                "diagnostics": .array([]),
                "live": .array([]),
            ]))

        case "terminal.list", "terminal.diagnostics":
            return .success(id: request.id, result: .array([]))

        case "terminal.subscribe":
            return .success(id: request.id, result: .object([
                "ok": .bool(false),
                "message": .string("Terminal is no longer available."),
            ]))

        case "terminal.unsubscribe":
            return .success(id: request.id, result: .object([
                "ok": .bool(true),
                "removed": .bool(false),
            ]))

        default:
            return .failure(
                id: request.id,
                code: "unsupported_method",
                message: "unsupported broker method: \(request.method)"
            )
        }
    }

    private func statusSnapshot() -> [String: BrokerJSONValue] {
        [
            "ok": .bool(true),
            "protocol": .integer(Int64(BrokerWire.protocolVersion)),
            "securityEpoch": .integer(Int64(BrokerWire.securityEpoch)),
            "implementationVersion": .integer(Int64(BrokerWire.implementationVersion)),
            "packageSchema": .integer(Int64(configuration.packageSchema)),
            "packageVersion": configuration.packageVersion.map(BrokerJSONValue.string) ?? .null,
            "contentDigest": .string(configuration.contentDigest),
            "features": .array(BrokerAuthentication.advertisedFeatures.map(BrokerJSONValue.string)),
            "pid": .integer(Int64(configuration.pid)),
            "startedAt": .integer(configuration.startedAt),
            "version": .string(configuration.version),
            "runtimeKind": .string("swift"),
            "activityEpoch": .integer(1),
            "companionLeaseEpoch": .integer(1),
            "companionLeaseCount": .integer(0),
            "inFlightMutations": .integer(0),
            "generationState": .string("current"),
            "drainingTargetContentDigest": .null,
            "authenticatedClientCount": .integer(Int64(authenticatedClients.count)),
            "terminals": .array([]),
        ]
    }
}
