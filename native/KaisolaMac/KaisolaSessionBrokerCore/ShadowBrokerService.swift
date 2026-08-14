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
    private let terminalStore: FreshTerminalStore?
    private var inFlightMutations = 0
    private var authenticatedClients: [String: BrokerAuthenticatedClient] = [:]

    public init(
        configuration: ShadowBrokerServiceConfiguration,
        requestGate: BrokerRequestGate = BrokerRequestGate(),
        terminalStore: FreshTerminalStore? = nil
    ) throws {
        self.configuration = configuration
        self.authentication = BrokerAuthentication(configuration: configuration)
        self.requestGate = requestGate
        self.terminalStore = terminalStore
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

        guard authenticatedClients[client.instanceID] == client else {
            _ = await lease.release()
            return .failure(
                id: request.id,
                code: "authentication_required",
                message: "broker authentication is required"
            )
        }

        let response = await dispatchAdmitted(client: client, request: request)
        _ = await lease.release()
        return response
    }

    private func dispatchAdmitted(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest
    ) async -> BrokerResponse {
        guard let terminalStore else {
            return dispatchShadowAdmitted(request)
        }
        return await dispatchFreshAdmitted(
            client: client,
            request: request,
            terminalStore: terminalStore
        )
    }

    /// The no-store path is the original shadow contract. Keep it separate
    /// from the fresh-session adapter so merely adding the optional dependency
    /// cannot widen the already-shipped observe-only executable.
    private func dispatchShadowAdmitted(_ request: BrokerRequest) -> BrokerResponse {
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

    private func dispatchFreshAdmitted(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest,
        terminalStore: FreshTerminalStore
    ) async -> BrokerResponse {
        switch request.method {
        case "terminal.create":
            guard let create = freshCreateRequest(from: request.params) else {
                return invalidFreshRequest(request.id)
            }
            beginFreshMutation()
            var didMutate = false
            defer { finishFreshMutation(didMutate: didMutate) }
            do {
                let creation = try await terminalStore.create(
                    client: client,
                    request: create
                )
                didMutate = true
                guard let snapshot = try await terminalStore.snapshot(
                    id: creation.id,
                    projectID: create.projectID
                ) else {
                    return .failure(
                        id: request.id,
                        code: "terminal_not_found",
                        message: "terminal is no longer available"
                    )
                }
                return .success(id: request.id, result: .object([
                    "ok": .bool(true),
                    "existed": .bool(creation.existed),
                    "pid": .integer(Int64(creation.pid)),
                    "continuation": .null,
                    "streamEpoch": .string(snapshot.streamEpoch),
                    "output": .string(snapshot.output),
                    "startOffset": .integer(snapshot.startOffset),
                    "endOffset": .integer(snapshot.endOffset),
                    "truncated": .bool(snapshot.truncated),
                    "exited": .bool(snapshot.exited),
                    "recovered": .null,
                ]))
            } catch {
                return freshCreateFailure(id: request.id, error: error)
            }

        case "terminal.write":
            guard let identity = freshIdentity(from: request.params),
                  let data = request.params?.objectValue?["data"]?.stringValue else {
                return .success(id: request.id, result: .object([
                    "ok": .bool(false),
                    "code": .string("invalid_terminal_write_payload"),
                    "message": .string("terminal.write data must be a string"),
                    "maximumBytes": .integer(64 * 1_024),
                ]))
            }
            return await freshWrite(
                id: request.id,
                client: client,
                identity: identity,
                data: data,
                terminalStore: terminalStore
            )

        case "terminal.resize":
            guard let identity = freshIdentity(from: request.params),
                  let cols = freshInteger(request.params, key: "cols"),
                  let rows = freshInteger(request.params, key: "rows") else {
                return invalidFreshRequest(request.id)
            }
            beginFreshMutation()
            var didMutate = false
            defer { finishFreshMutation(didMutate: didMutate) }
            do {
                try await terminalStore.resize(
                    client: client,
                    identity: identity,
                    cols: cols,
                    rows: rows
                )
                didMutate = true
                return .success(
                    id: request.id,
                    result: .object(["ok": .bool(true)])
                )
            } catch {
                return freshOrdinaryMutationFailure(
                    id: request.id,
                    error: error
                )
            }

        case "terminal.signal":
            guard let identity = freshIdentity(from: request.params) else {
                return invalidFreshRequest(request.id)
            }
            // Protocol 2 freezes terminal.signal as an ETX write. The PTY
            // decides which foreground job receives Ctrl-C; this route must
            // never reinterpret the request as a Darwin signal API.
            return await freshWrite(
                id: request.id,
                client: client,
                identity: identity,
                data: "\u{3}",
                terminalStore: terminalStore
            )

        case "terminal.kill":
            guard let identity = freshIdentity(from: request.params) else {
                return invalidFreshRequest(request.id)
            }
            beginFreshMutation()
            var didMutate = false
            defer { finishFreshMutation(didMutate: didMutate) }
            do {
                try await terminalStore.kill(client: client, identity: identity)
                didMutate = true
                return .success(id: request.id, result: .object([
                    "id": .string(identity.id),
                    "ok": .bool(true),
                ]))
            } catch FreshTerminalStoreError.terminalEnded {
                return .success(id: request.id, result: .object([
                    "id": .string(identity.id),
                    "ok": .bool(true),
                    "alreadyExited": .bool(true),
                ]))
            } catch FreshTerminalStoreError.terminalNotFound {
                return .success(id: request.id, result: .object([
                    "id": .string(identity.id),
                    "ok": .bool(false),
                    "code": .string("terminal_not_found"),
                    "message": .string("terminal is no longer available"),
                ]))
            } catch {
                return freshStoreFailure(id: request.id, error: error)
            }

        case "terminal.release":
            guard let identity = freshIdentity(from: request.params) else {
                return invalidFreshRequest(request.id)
            }
            beginFreshMutation()
            var didMutate = false
            defer { finishFreshMutation(didMutate: didMutate) }
            do {
                let release = try await terminalStore.release(
                    client: client,
                    identity: identity
                )
                didMutate = !release.alreadyAbsent
                return .success(id: request.id, result: .object([
                    "id": .string(release.id),
                    "ok": .bool(true),
                    "released": .bool(release.released),
                    "alreadyAbsent": .bool(release.alreadyAbsent),
                ]))
            } catch {
                return freshStoreFailure(id: request.id, error: error)
            }

        case "broker.status":
            let capture = await freshInventoryCapture(terminalStore)
            guard let view = freshReadView(
                client: client,
                params: request.params,
                inventory: capture.records
            ) else {
                return freshControllerReadFailure(id: request.id)
            }
            return .success(
                id: request.id,
                result: .object(freshStatusSnapshot(
                    inventory: view.records,
                    activityEpoch: capture.activityEpoch,
                    includeCapacity: view.isGlobal
                ))
            )

        case "broker.inventory":
            guard inFlightMutations == 0 else {
                return await freshActivityChanged(
                    id: request.id,
                    terminalStore: terminalStore
                )
            }
            let capture = await terminalStore.atomicInventorySnapshot()
            let completedEpoch = await terminalStore.currentActivityEpoch()
            guard inFlightMutations == 0,
                  completedEpoch == capture.activityEpoch else {
                return await freshActivityChanged(
                    id: request.id,
                    terminalStore: terminalStore
                )
            }
            guard let view = freshReadView(
                client: client,
                params: request.params,
                inventory: capture.records
            ) else {
                return freshControllerReadFailure(id: request.id)
            }
            let diagnostics = view.records.map(freshDiagnosticRow)
            let live = view.records.filter { !$0.exited }.map(freshLiveRow)
            return .success(id: request.id, result: .object([
                "ok": .bool(true),
                "state": .string("stable"),
                "activityEpoch": .integer(capture.activityEpoch),
                "status": .object(freshStatusSnapshot(
                    inventory: view.records,
                    diagnostics: diagnostics,
                    activityEpoch: capture.activityEpoch,
                    includeCapacity: view.isGlobal
                )),
                "diagnostics": .array(diagnostics),
                "live": .array(live),
            ]))

        case "terminal.list":
            let inventory = await terminalStore.inventory()
            guard let view = freshReadView(
                client: client,
                params: request.params,
                inventory: inventory
            ) else {
                return freshControllerReadFailure(id: request.id)
            }
            return .success(
                id: request.id,
                result: .array(view.records.filter { !$0.exited }.map(freshLiveRow))
            )

        case "terminal.diagnostics":
            let inventory = await terminalStore.inventory()
            guard let view = freshReadView(
                client: client,
                params: request.params,
                inventory: inventory
            ) else {
                return freshControllerReadFailure(id: request.id)
            }
            return .success(
                id: request.id,
                result: .array(view.records.map(freshDiagnosticRow))
            )

        case "terminal.subscribe":
            return await freshSubscribe(
                client: client,
                request: request,
                terminalStore: terminalStore
            )

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

    private func freshWrite(
        id: String,
        client: BrokerAuthenticatedClient,
        identity: FreshTerminalIdentity,
        data: String,
        terminalStore: FreshTerminalStore
    ) async -> BrokerResponse {
        beginFreshMutation()
        var didMutate = false
        defer { finishFreshMutation(didMutate: didMutate) }
        do {
            try await terminalStore.write(
                client: client,
                identity: identity,
                data: data
            )
            didMutate = true
            return .success(id: id, result: .object(["ok": .bool(true)]))
        } catch FreshTerminalStoreError.terminalNotFound {
            return .success(id: id, result: .object(["ok": .bool(false)]))
        } catch FreshTerminalStoreError.terminalEnded {
            return .success(id: id, result: .object([
                "ok": .bool(false),
                "message": .string("terminal already ended"),
            ]))
        } catch let FreshTerminalStoreError.writePayloadTooLarge(maximum, actual) {
            return .success(id: id, result: .object([
                "ok": .bool(false),
                "code": .string("terminal_write_payload_too_large"),
                "message": .string(
                    "terminal.write data exceeds \(maximum) UTF-8 bytes"
                ),
                "maximumBytes": .integer(Int64(maximum)),
                "actualBytes": .integer(Int64(actual)),
            ]))
        } catch {
            return freshStoreFailure(id: id, error: error)
        }
    }

    private func freshOrdinaryMutationFailure(
        id: String,
        error: any Error
    ) -> BrokerResponse {
        switch error as? FreshTerminalStoreError {
        case .terminalNotFound:
            return .success(id: id, result: .object(["ok": .bool(false)]))
        case .terminalEnded:
            return .success(id: id, result: .object([
                "ok": .bool(false),
                "message": .string("terminal already ended"),
            ]))
        case .invalidGeometry:
            return .success(id: id, result: .object([
                "ok": .bool(false),
                "message": .string("invalid terminal geometry"),
            ]))
        default:
            return freshStoreFailure(id: id, error: error)
        }
    }

    private func freshCreateFailure(
        id: String,
        error: any Error
    ) -> BrokerResponse {
        if case let .capacityExceeded(maximum) = error as? FreshTerminalStoreError {
            return .success(id: id, result: .object([
                "ok": .bool(false),
                "code": .string("terminal_capacity_exceeded"),
                "message": .string("broker terminal capacity reached"),
                "maximumLiveTerminals": .integer(Int64(maximum)),
            ]))
        }
        return freshStoreFailure(id: id, error: error)
    }

    private func freshStoreFailure(
        id: String,
        error: any Error
    ) -> BrokerResponse {
        let storeError = error as? FreshTerminalStoreError
        return .failure(
            id: id,
            code: freshErrorCode(storeError),
            message: storeError?.errorDescription ?? "terminal operation failed"
        )
    }

    private func freshErrorCode(_ error: FreshTerminalStoreError?) -> String {
        switch error {
        case .controllerRequired:
            "access_denied"
        case .terminalAccessDenied:
            "terminal_access_denied"
        case .restoreUnsupported:
            "fresh_start_only"
        case .invalidClientIdentity, .invalidOwner, .invalidProject,
             .invalidTerminalID, .invalidCommand, .invalidArguments,
             .invalidEnvironment, .invalidCWD, .invalidGeometry:
            "invalid_request"
        case .terminalCreationInProgress, .terminalReleaseInProgress:
            "terminal_busy"
        case .terminalNotFound:
            "terminal_not_found"
        case .terminalEnded:
            "terminal_ended"
        case .writePayloadTooLarge:
            "terminal_write_payload_too_large"
        case .capacityExceeded:
            "terminal_capacity_exceeded"
        case .processOperationFailed:
            "terminal_operation_failed"
        case .shuttingDown, .shutdownIncomplete:
            "broker_shutting_down"
        case nil:
            "terminal_operation_failed"
        }
    }

    private func freshSubscribe(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest,
        terminalStore: FreshTerminalStore
    ) async -> BrokerResponse {
        guard let params = request.params?.objectValue,
              let id = params["id"]?.stringValue,
              let projectID = params["projectId"]?.stringValue,
              !id.isEmpty,
              !projectID.isEmpty else {
            return invalidFreshRequest(request.id)
        }
        let owner: String?
        switch client.role {
        case .observer, .administrator:
            owner = nil
        case .controller:
            guard let ownerID = params["ownerId"]?.stringValue,
                  validFreshOwnerID(ownerID),
                  validFreshProjectID(projectID) else {
                return freshControllerReadFailure(id: request.id)
            }
            owner = freshOwnerKey(
                client: client,
                ownerID: ownerID,
                projectID: projectID
            )
        }
        let snapshot: FreshTerminalSnapshot
        do {
            guard let value = try await terminalStore.snapshot(
                id: id,
                projectID: projectID,
                owner: owner
            ) else {
                return .success(id: request.id, result: .object([
                    "ok": .bool(false),
                    "message": .string("Terminal is no longer available."),
                ]))
            }
            snapshot = value
        } catch {
            return freshStoreFailure(id: request.id, error: error)
        }

        return .success(id: request.id, result: .object([
            "ok": .bool(true),
            "mode": .string("snapshot"),
            "snapshot": .object([
                "streamEpoch": .string(snapshot.streamEpoch),
                "output": .string(snapshot.output),
                "startOffset": .integer(snapshot.startOffset),
                "endOffset": .integer(snapshot.endOffset),
                "truncated": .bool(snapshot.truncated),
                "exited": .bool(snapshot.exited),
            ]),
        ]))
    }

    private func freshCreateRequest(
        from value: BrokerJSONValue?
    ) -> FreshTerminalCreateRequest? {
        guard let params = value?.objectValue,
              let ownerID = params["ownerId"]?.stringValue,
              let projectID = params["projectId"]?.stringValue,
              let id = params["id"]?.stringValue,
              let command = params["command"]?.stringValue,
              let args = params["args"]?.arrayValue,
              args.allSatisfy({ $0.stringValue != nil }),
              let cwd = params["cwd"]?.stringValue,
              let envValues = params["env"]?.objectValue,
              envValues.values.allSatisfy({ $0.stringValue != nil }),
              let cols = freshInteger(value, key: "cols"),
              let rows = freshInteger(value, key: "rows") else {
            return nil
        }
        if params["restore"] != nil, params["restore"]?.boolValue == nil {
            return nil
        }
        return FreshTerminalCreateRequest(
            ownerID: ownerID,
            projectID: projectID,
            id: id,
            command: command,
            args: args.compactMap(\.stringValue),
            cwd: cwd,
            env: envValues.compactMapValues(\.stringValue),
            cols: cols,
            rows: rows,
            restore: params["restore"]?.boolValue ?? false
        )
    }

    private func freshIdentity(
        from value: BrokerJSONValue?
    ) -> FreshTerminalIdentity? {
        guard let params = value?.objectValue,
              let ownerID = params["ownerId"]?.stringValue,
              let projectID = params["projectId"]?.stringValue,
              let id = params["id"]?.stringValue else {
            return nil
        }
        return FreshTerminalIdentity(
            ownerID: ownerID,
            projectID: projectID,
            id: id
        )
    }

    private func freshInteger(
        _ value: BrokerJSONValue?,
        key: String
    ) -> Int? {
        value?.objectValue?[key]?.integerValue.flatMap(Int.init(exactly:))
    }

    private func invalidFreshRequest(_ id: String) -> BrokerResponse {
        .failure(
            id: id,
            code: "invalid_request",
            message: "invalid broker request"
        )
    }

    private func beginFreshMutation() {
        inFlightMutations += 1
    }

    private func finishFreshMutation(didMutate: Bool) {
        inFlightMutations = max(0, inFlightMutations - 1)
        _ = didMutate
    }

    private func freshActivityChanged(
        id: String,
        terminalStore: FreshTerminalStore
    ) async -> BrokerResponse {
        let activityEpoch = await terminalStore.currentActivityEpoch()
        return .success(id: id, result: .object([
            "ok": .bool(false),
            "state": .string("activity_changed"),
            "activityEpoch": .integer(activityEpoch),
        ]))
    }

    private struct FreshReadView {
        let records: [FreshTerminalInventoryRecord]
        let isGlobal: Bool
    }

    private func freshReadView(
        client: BrokerAuthenticatedClient,
        params: BrokerJSONValue?,
        inventory: [FreshTerminalInventoryRecord]
    ) -> FreshReadView? {
        switch client.role {
        case .observer, .administrator:
            return FreshReadView(records: inventory, isGlobal: true)
        case .controller:
            guard let ownerID = params?.objectValue?["ownerId"]?.stringValue,
                  validFreshOwnerID(ownerID) else {
                return nil
            }
            let projectID = params?.objectValue?["projectId"]?.stringValue ?? "legacy"
            guard validFreshProjectID(projectID) else { return nil }
            let owner = freshOwnerKey(
                client: client,
                ownerID: ownerID,
                projectID: projectID
            )
            return FreshReadView(
                records: inventory.filter { $0.owner == owner },
                isGlobal: false
            )
        }
    }

    private func freshOwnerKey(
        client: BrokerAuthenticatedClient,
        ownerID: String,
        projectID: String
    ) -> String {
        "\(client.instanceID)|\(ownerID)|\(projectID)"
    }

    private func validFreshOwnerID(_ value: String) -> Bool {
        value != "0"
            && value.range(
                of: #"^[a-zA-Z0-9_-]{1,80}$"#,
                options: .regularExpression
            ) != nil
    }

    private func validFreshProjectID(_ value: String) -> Bool {
        value.range(
            of: #"^[a-zA-Z0-9_.:-]{1,160}$"#,
            options: .regularExpression
        ) != nil
    }

    private func freshControllerReadFailure(id: String) -> BrokerResponse {
        .failure(
            id: id,
            code: "access_denied",
            message: "controller access requires a nonzero owner identity"
        )
    }

    private func freshInventoryCapture(
        _ terminalStore: FreshTerminalStore
    ) async -> FreshTerminalInventorySnapshot {
        await terminalStore.atomicInventorySnapshot()
    }

    private func freshDiagnosticRow(
        _ row: FreshTerminalInventoryRecord
    ) -> BrokerJSONValue {
        .object([
            "id": .string(row.id),
            "pid": .integer(Int64(row.pid)),
            "exited": .bool(row.exited),
            "owner": .string(row.owner),
            "lastOwner": .string(row.lastOwner),
            "streamEpoch": .string(row.streamEpoch),
            "endOffset": .integer(row.endOffset),
            "diskBytes": .integer(0),
            "cwd": .string(row.cwd),
            "cols": .integer(Int64(row.cols)),
            "rows": .integer(Int64(row.rows)),
        ])
    }

    private func freshLiveRow(
        _ row: FreshTerminalInventoryRecord
    ) -> BrokerJSONValue {
        .object([
            "id": .string(row.id),
            "pid": .integer(Int64(row.pid)),
            "process": .string(""),
            "cwd": .string(row.cwd),
            "cols": .integer(Int64(row.cols)),
            "rows": .integer(Int64(row.rows)),
            "owner": .string(row.owner),
            "lastOwner": .string(row.lastOwner),
            "agentBusy": .bool(false),
            "agentTurnOpen": .bool(false),
        ])
    }

    private func freshStatusSnapshot(
        inventory: [FreshTerminalInventoryRecord],
        diagnostics: [BrokerJSONValue]? = nil,
        activityEpoch: Int64,
        includeCapacity: Bool
    ) -> [String: BrokerJSONValue] {
        let terminalRows = diagnostics ?? inventory.map(freshDiagnosticRow)
        let liveCount = inventory.lazy.filter { !$0.exited }.count
        var status: [String: BrokerJSONValue] = [
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
            "activityEpoch": .integer(activityEpoch),
            "companionLeaseEpoch": .integer(1),
            "companionLeaseCount": .integer(0),
            "inFlightMutations": .integer(Int64(inFlightMutations)),
            "generationState": .string("current"),
            "drainingTargetContentDigest": .null,
            "authenticatedClientCount": .integer(Int64(authenticatedClients.count)),
            "terminals": .array(terminalRows),
        ]
        if includeCapacity {
            status["terminalCapacity"] = .object([
                "maximumLiveTerminals": .integer(64),
                "liveTerminalCount": .integer(Int64(liveCount)),
                "availableTerminalSlots": .integer(Int64(max(0, 64 - liveCount))),
            ])
        }
        return status
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
