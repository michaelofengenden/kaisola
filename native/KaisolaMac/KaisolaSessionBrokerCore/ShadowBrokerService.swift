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
    private let eventRouter = BrokerEventRouter()
    private var inFlightMutations = 0
    private var authenticatedClients: [String: BrokerAuthenticatedClient] = [:]

    public init(
        configuration: ShadowBrokerServiceConfiguration,
        requestGate: BrokerRequestGate = BrokerRequestGate(),
        terminalStore: FreshTerminalStore? = nil
    ) throws {
        self.configuration = configuration
        // Feature advertisement is per runtime mode so it stays truthful:
        // shadow keeps its observe-only trio, the fresh PTY runtime adds only
        // the terminal streaming surface implemented below.
        self.authentication = BrokerAuthentication(
            configuration: configuration,
            features: terminalStore == nil
                ? BrokerAuthentication.advertisedFeatures
                : BrokerAuthentication.freshAdvertisedFeatures
        )
        self.requestGate = requestGate
        self.terminalStore = terminalStore
        if let terminalStore {
            let router = eventRouter
            terminalStore.setEventSink { owner, channel, payload, maxQueueBytes, force in
                router.deliver(
                    owner: owner,
                    channel: channel,
                    payload: payload,
                    maxQueueBytes: maxQueueBytes,
                    force: force
                )
            }
        }
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

    /// Called by the connection after its accepted hello. Events for every
    /// subscription keyed `instanceID|…` flow through this sink from then on.
    /// The authority guard keeps a stale connection racing its replacement
    /// from stealing the replacement's stream.
    public func attachConnection(
        client: BrokerAuthenticatedClient,
        sink: BrokerConnectionEventSink
    ) {
        guard authenticatedClients[client.instanceID] == client else { return }
        eventRouter.attach(
            instanceID: client.instanceID,
            authority: client,
            features: Set(client.negotiatedFeatures),
            sink: sink
        )
    }

    public func disconnect(client: BrokerAuthenticatedClient) async {
        guard authenticatedClients[client.instanceID] == client else { return }
        authenticatedClients.removeValue(forKey: client.instanceID)
        eventRouter.detach(instanceID: client.instanceID, authority: client)
        // A closed connection can never drain its subscriptions again; drop
        // them all rather than letting them pause-and-linger on first output.
        await terminalStore?.unsubscribeSubscriberPrefix("\(client.instanceID)|")
    }

    public func dispatch(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest
    ) async -> BrokerResponse {
        // The responder-free form cannot return nil: only a connection-backed
        // subscribe answers through its responder.
        await dispatch(client: client, request: request, responder: nil)
            ?? .failure(
                id: request.id,
                code: "internal_error",
                message: "broker response was already delivered"
            )
    }

    /// `responder` is the connection's ordered outbound queue. A nil return
    /// means the response was already enqueued there — for `terminal.subscribe`
    /// that enqueue happens inside the terminal's output critical section, so
    /// the response frame provably precedes the subscriber's first live event.
    public func dispatch(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest,
        responder: (@Sendable (BrokerResponse) -> Bool)?
    ) async -> BrokerResponse? {
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

        let response = await dispatchAdmitted(
            client: client,
            request: request,
            responder: responder
        )
        _ = await lease.release()
        return response
    }

    private func dispatchAdmitted(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest,
        responder: (@Sendable (BrokerResponse) -> Bool)?
    ) async -> BrokerResponse? {
        guard let terminalStore else {
            return dispatchShadowAdmitted(request)
        }
        return await dispatchFreshAdmitted(
            client: client,
            request: request,
            terminalStore: terminalStore,
            responder: responder
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
        terminalStore: FreshTerminalStore,
        responder: (@Sendable (BrokerResponse) -> Bool)?
    ) async -> BrokerResponse? {
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
                    request: create,
                    // The creator's own negotiation answers whether the broker
                    // should produce the primary `terminal:data` copy for the
                    // terminal it now owns; adoption re-answers it the same way.
                    primaryStreamEnabled: !client.negotiatedFeatures.contains(
                        BrokerWire.terminalObserverOnlyOutputFeature
                    )
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
                    "maximumBytes": .integer(Int64(64 * 1_024)),
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
                terminalStore: terminalStore,
                responder: responder
            )

        case "terminal.unsubscribe":
            return await freshUnsubscribe(
                client: client,
                request: request,
                terminalStore: terminalStore
            )

        case "terminal.history":
            return await freshHistory(
                client: client,
                request: request,
                terminalStore: terminalStore
            )

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
        case .invalidObserverCursor, .invalidObserverSubscriber:
            "invalid_request"
        case .observerLimitReached:
            "terminal_observer_limit"
        case .historyEpochMismatch:
            "terminal_history_epoch_mismatch"
        case .invalidHistoryOffset:
            "invalid_terminal_history_offset"
        case nil:
            "terminal_operation_failed"
        }
    }

    /// One subscribe/unsubscribe/history identity: the terminal, the access
    /// scope the role must satisfy, and the subscriber key events route by.
    private struct FreshObserverIdentity {
        let id: String
        let projectID: String
        /// Controllers must present the exact owner; observers pass nil and
        /// are bounded by the exact-project check instead.
        let accessOwner: String?
        /// `instanceID|ownerId|projectId`, exactly the Node broker's
        /// subscriber owner key, so events parse back into the same
        /// `{ownerId, projectId}` wire fields.
        let subscriber: String
    }

    private func freshObserverIdentity(
        client: BrokerAuthenticatedClient,
        params: [String: BrokerJSONValue]
    ) -> FreshObserverIdentity?? {
        guard let id = params["id"]?.stringValue,
              let projectID = params["projectId"]?.stringValue,
              !id.isEmpty,
              !projectID.isEmpty else {
            return nil
        }
        switch client.role {
        case .observer, .administrator:
            // The Node broker normalizes an absent/loose observer ownerId to
            // "0"; the subscriber key still has three parts either way.
            let ownerID = normalizedFreshOwnerID(params["ownerId"]?.stringValue)
            return FreshObserverIdentity(
                id: id,
                projectID: projectID,
                accessOwner: nil,
                subscriber: freshOwnerKey(client: client, ownerID: ownerID, projectID: projectID)
            )
        case .controller:
            guard let ownerID = params["ownerId"]?.stringValue,
                  validFreshOwnerID(ownerID),
                  validFreshProjectID(projectID) else {
                return .some(nil)
            }
            let owner = freshOwnerKey(client: client, ownerID: ownerID, projectID: projectID)
            return FreshObserverIdentity(
                id: id,
                projectID: projectID,
                accessOwner: owner,
                subscriber: owner
            )
        }
    }

    private func freshSubscribe(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest,
        terminalStore: FreshTerminalStore,
        responder: (@Sendable (BrokerResponse) -> Bool)?
    ) async -> BrokerResponse? {
        guard let params = request.params?.objectValue,
              let resolved = freshObserverIdentity(client: client, params: params) else {
            return invalidFreshRequest(request.id)
        }
        guard let identity = resolved else {
            return freshControllerReadFailure(id: request.id)
        }

        // Node validates the cursor pair as a unit: absent means a plain
        // snapshot; a half-provided or malformed cursor is a protocol error.
        let cursorEpochValue = params["streamEpoch"]
        let cursorOffsetValue = params["afterOffset"]
        var cursorEpoch: String?
        var cursorOffset: Int64?
        if cursorEpochValue != nil || cursorOffsetValue != nil {
            guard let epoch = cursorEpochValue?.stringValue,
                  !epoch.isEmpty,
                  let offset = cursorOffsetValue?.integerValue,
                  offset >= 0 else {
                return freshStoreFailure(
                    id: request.id,
                    error: FreshTerminalStoreError.invalidObserverCursor
                )
            }
            cursorEpoch = epoch
            cursorOffset = offset
        }

        let requestID = request.id
        // The reply is produced inside the terminal's output critical section.
        // With a connection responder it is enqueued right there — before any
        // later append can broadcast — and this method then returns nil; the
        // responder-free (in-process test) path captures it instead.
        let box = FreshSubscribeResponseBox()
        let respond: @Sendable (FreshTerminalSubscribeReply) -> Void = { reply in
            let response = Self.freshSubscribeResponse(id: requestID, reply: reply)
            if let responder {
                _ = responder(response)
            } else {
                box.store(response)
            }
        }
        do {
            try await terminalStore.subscribe(
                id: identity.id,
                projectID: identity.projectID,
                accessOwner: identity.accessOwner,
                subscriber: identity.subscriber,
                streamEpoch: cursorEpoch,
                afterOffset: cursorOffset,
                maxQueueBytes: params["maxQueueBytes"]?.integerValue,
                respond: respond
            )
        } catch {
            return freshStoreFailure(id: request.id, error: error)
        }
        if responder != nil { return nil }
        return box.take() ?? .failure(
            id: request.id,
            code: "internal_error",
            message: "terminal subscribe produced no reply"
        )
    }

    private static func freshSubscribeResponse(
        id: String,
        reply: FreshTerminalSubscribeReply
    ) -> BrokerResponse {
        switch reply {
        case .unavailable:
            return .success(id: id, result: .object([
                "ok": .bool(false),
                "message": .string("Terminal is no longer available."),
            ]))
        case let .current(streamEpoch, offset):
            return .success(id: id, result: .object([
                "ok": .bool(true),
                "mode": .string("current"),
                "cursor": .object([
                    "streamEpoch": .string(streamEpoch),
                    "offset": .integer(offset),
                ]),
            ]))
        case let .snapshot(snapshot, resetReason):
            var result: [String: BrokerJSONValue] = [
                "ok": .bool(true),
                "mode": .string("snapshot"),
                "snapshot": .object([
                    "streamEpoch": .string(snapshot.streamEpoch),
                    "output": .string(snapshot.output),
                    "startOffset": .integer(snapshot.startOffset),
                    "endOffset": .integer(snapshot.endOffset),
                    "truncated": .bool(snapshot.truncated),
                    "exited": .bool(snapshot.exited),
                    "exitStatus": freshExitStatusValue(snapshot.exitStatus),
                ]),
            ]
            if let resetReason {
                result["resetReason"] = .string(resetReason)
            }
            return .success(id: id, result: .object(result))
        }
    }

    private static func freshExitStatusValue(
        _ status: FreshTerminalExitStatus?
    ) -> BrokerJSONValue {
        guard let status else { return .null }
        return .object([
            "exitCode": .integer(status.exitCode),
            "signal": status.signal.map(BrokerJSONValue.integer) ?? .null,
        ])
    }

    private func freshUnsubscribe(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest,
        terminalStore: FreshTerminalStore
    ) async -> BrokerResponse {
        guard let params = request.params?.objectValue,
              let resolved = freshObserverIdentity(client: client, params: params) else {
            return invalidFreshRequest(request.id)
        }
        guard let identity = resolved else {
            return freshControllerReadFailure(id: request.id)
        }
        do {
            let removed = try await terminalStore.unsubscribe(
                id: identity.id,
                projectID: identity.projectID,
                accessOwner: identity.accessOwner,
                subscriber: identity.subscriber
            )
            return .success(id: request.id, result: .object([
                "ok": .bool(true),
                "removed": .bool(removed),
            ]))
        } catch {
            return freshStoreFailure(id: request.id, error: error)
        }
    }

    private func freshHistory(
        client: BrokerAuthenticatedClient,
        request: BrokerRequest,
        terminalStore: FreshTerminalStore
    ) async -> BrokerResponse {
        guard let params = request.params?.objectValue,
              let resolved = freshObserverIdentity(client: client, params: params) else {
            return invalidFreshRequest(request.id)
        }
        guard let identity = resolved else {
            return freshControllerReadFailure(id: request.id)
        }
        do {
            guard let page = try await terminalStore.history(
                id: identity.id,
                projectID: identity.projectID,
                accessOwner: identity.accessOwner,
                streamEpoch: params["streamEpoch"]?.stringValue,
                beforeOffset: params["beforeOffset"]?.integerValue,
                maxBytes: params["maxBytes"]?.integerValue
            ) else {
                return .success(id: request.id, result: .object([
                    "ok": .bool(false),
                    "message": .string("Terminal is no longer available."),
                ]))
            }
            return .success(id: request.id, result: .object([
                "ok": .bool(true),
                "streamEpoch": .string(page.streamEpoch),
                "output": .string(page.output),
                "startOffset": .integer(page.startOffset),
                "endOffset": .integer(page.endOffset),
                "hasMore": .bool(page.hasMore),
                "truncated": .bool(page.truncated),
            ]))
        } catch {
            return freshStoreFailure(id: request.id, error: error)
        }
    }

    /// Node's `normalizeBrokerOwnerID`: strip everything outside
    /// `[a-zA-Z0-9_-]`, cap at 80, and let an empty result mean "0".
    private func normalizedFreshOwnerID(_ value: String?) -> String {
        let allowed = (value ?? "0").unicodeScalars.filter { scalar in
            (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "_"
                || scalar == "-"
        }
        let normalized = String(String.UnicodeScalarView(allowed.prefix(80)))
        return normalized.isEmpty ? "0" : normalized
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
            "features": .array(authentication.features.map(BrokerJSONValue.string)),
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
            "features": .array(authentication.features.map(BrokerJSONValue.string)),
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

/// One authenticated connection's entry point for `{type:'event'}` frames.
/// `deliver` must be synchronous and non-blocking: it runs inside terminal
/// output critical sections. Returning false refuses the frame — the signal
/// the slow-consumer policy converts into a pause-with-cursor.
public struct BrokerConnectionEventSink: Sendable {
    public typealias Deliver = @Sendable (
        _ frame: Data,
        _ maxQueueBytes: Int?,
        _ force: Bool
    ) -> Bool

    public let deliver: Deliver

    public init(deliver: @escaping Deliver) {
        self.deliver = deliver
    }
}

/// The Swift analog of the Node broker's `mgr.setEventSink` closure plus its
/// per-client feature shaping: resolves a subscriber owner key to the live
/// connection for its instance, downgrades `terminal:exit:*` payloads for
/// clients that never negotiated terminal-exit-status-v1, and validates the
/// encoded frame against the per-channel event cap before it may be queued.
/// Lock-protected rather than actor-isolated because delivery happens
/// synchronously on PTY read threads.
final class BrokerEventRouter: @unchecked Sendable {
    private struct Registration {
        let authority: BrokerAuthenticatedClient
        let features: Set<String>
        let sink: BrokerConnectionEventSink
    }

    private let lock = NSLock()
    private var registrations: [String: Registration] = [:]

    func attach(
        instanceID: String,
        authority: BrokerAuthenticatedClient,
        features: Set<String>,
        sink: BrokerConnectionEventSink
    ) {
        lock.lock()
        defer { lock.unlock() }
        registrations[instanceID] = Registration(
            authority: authority,
            features: features,
            sink: sink
        )
    }

    func detach(instanceID: String, authority: BrokerAuthenticatedClient) {
        lock.lock()
        defer { lock.unlock() }
        guard registrations[instanceID]?.authority == authority else { return }
        registrations.removeValue(forKey: instanceID)
    }

    func deliver(
        owner: String,
        channel: String,
        payload: BrokerJSONValue,
        maxQueueBytes: Int?,
        force: Bool
    ) -> Bool {
        guard let parts = Self.ownerParts(owner) else { return false }
        lock.lock()
        let registration = registrations[parts.instanceID]
        lock.unlock()
        guard let registration else { return false }

        let frame: BrokerJSONValue = .object([
            "type": .string("event"),
            "ownerId": .string(parts.ownerID),
            "projectId": .string(parts.projectID),
            "channel": .string(channel),
            "payload": Self.payloadForFeatures(
                channel: channel,
                payload: payload,
                features: registration.features
            ),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(frame) else { return false }
        do {
            // Same verdict the Node `writeFrame` produces for an oversized
            // event: undeliverable, so the overflow policy handles it.
            try BrokerWire.validateEncodedFrame(data, purpose: .event(channel))
        } catch {
            return false
        }
        data.append(0x0A)
        return registration.sink.deliver(data, maxQueueBytes, force)
    }

    /// Node's `terminalOwnerParts`: `instance|owner[|project]`, with a
    /// missing third part reading as the legacy project scope.
    static func ownerParts(
        _ owner: String
    ) -> (instanceID: String, ownerID: String, projectID: String)? {
        guard let first = owner.firstIndex(of: "|"), first != owner.startIndex else {
            return nil
        }
        let instanceID = String(owner[..<first])
        let remainder = owner[owner.index(after: first)...]
        guard let second = remainder.firstIndex(of: "|") else {
            let ownerID = String(remainder)
            return ownerID.isEmpty ? nil : (instanceID, ownerID, "legacy")
        }
        let ownerID = String(remainder[..<second])
        let projectID = String(remainder[remainder.index(after: second)...])
        guard !ownerID.isEmpty, !projectID.isEmpty else { return nil }
        return (instanceID, ownerID, projectID)
    }

    /// Node's `eventPayloadForFeatures`: only `terminal:exit:<id>` is shaped
    /// per client — a structured status downgrades to the bare exit code for
    /// clients that never declared terminal-exit-status-v1.
    static func payloadForFeatures(
        channel: String,
        payload: BrokerJSONValue,
        features: Set<String>
    ) -> BrokerJSONValue {
        guard channel.hasPrefix("terminal:exit:"),
              !features.contains(BrokerWire.terminalExitStatusFeature),
              case let .object(status) = payload else {
            return payload
        }
        guard let exitCode = status["exitCode"], exitCode != .null else {
            return .integer(0)
        }
        return exitCode
    }
}

/// Captures the subscribe reply for responder-free (in-process) dispatch. The
/// store invokes `respond` synchronously before its subscribe call returns, so
/// the box is filled by the time the caller reads it.
private final class FreshSubscribeResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: BrokerResponse?

    func store(_ value: BrokerResponse) {
        lock.lock()
        defer { lock.unlock() }
        response = value
    }

    func take() -> BrokerResponse? {
        lock.lock()
        defer { lock.unlock() }
        return response
    }
}
