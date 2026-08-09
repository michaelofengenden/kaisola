import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

/// Drives the ACP client through a scripted in-memory transport so the wire
/// protocol (initialize → session/new → session/prompt → session/update
/// stream, plus a permission callback) is verified without spawning a process.
final class AcpClientTests: XCTestCase {
    @MainActor
    func testOwnedConversationCanRestartAfterAdapterExit() async {
        let conversation = AcpConversation(
            title: "Restart", command: "/usr/bin/true", arguments: [], cwd: "/tmp"
        )

        // `true` exits before the ACP initialize handshake. A restart must
        // replace the dead Process transport and complete another bounded
        // attempt instead of reusing its closed handles or hanging.
        await conversation.start()
        XCTAssertFalse(conversation.isConnected)
        XCTAssertTrue(conversation.canRestart)

        await conversation.restart()
        XCTAssertFalse(conversation.isConnected)
        XCTAssertFalse(conversation.isReconnecting)
        XCTAssertTrue(conversation.canRestart)
        XCTAssertNotNil(conversation.statusMessage)
    }

    @MainActor
    func testRestartResumesOnlyNeverDispatchedFollowUpsInExactFIFOOrder() async throws {
        let crashedTransport = ScriptedAcpTransport(crashOnFirstPrompt: true)
        let recoveredTransport = ScriptedAcpTransport()
        let clients = [
            AcpClient(transport: crashedTransport),
            AcpClient(transport: recoveredTransport),
        ]
        var clientIndex = 0
        let conversation = AcpConversation(
            title: "Queue recovery",
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: "/tmp",
            clientFactory: {
                let client = clients[clientIndex]
                clientIndex += 1
                return client
            }
        )
        await conversation.start()

        XCTAssertTrue(conversation.send("ambiguous in-flight prompt"))
        XCTAssertTrue(conversation.send("oldest never-dispatched follow-up"))
        XCTAssertTrue(conversation.send("newest never-dispatched follow-up"))

        var deadline = Date().addingTimeInterval(5)
        while conversation.isConnected || conversation.isRunning {
            if Date() > deadline { XCTFail("scripted adapter did not crash"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            conversation.queued.map(\.text),
            ["oldest never-dispatched follow-up", "newest never-dispatched follow-up"]
        )
        XCTAssertTrue(conversation.rows.contains { row in
            if case let .user(_, text, failed) = row {
                return text == "ambiguous in-flight prompt" && failed
            }
            return false
        })

        await conversation.restart()

        deadline = Date().addingTimeInterval(5)
        while conversation.isRunning || !conversation.queued.isEmpty {
            if Date() > deadline { XCTFail("preserved queue did not drain after restart"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let crashedPrompts = await crashedTransport.receivedPromptTexts()
        let recoveredPrompts = await recoveredTransport.receivedPromptTexts()
        let recoveredSessionMethods = await recoveredTransport.receivedSessionMethods()
        XCTAssertTrue(conversation.isConnected)
        XCTAssertEqual(crashedPrompts, ["ambiguous in-flight prompt"])
        XCTAssertEqual(
            recoveredPrompts,
            ["oldest never-dispatched follow-up", "newest never-dispatched follow-up"]
        )
        XCTAssertFalse(
            recoveredPrompts.contains("ambiguous in-flight prompt"),
            "an interrupted prompt has ambiguous delivery and must require explicit Retry"
        )
        XCTAssertTrue(
            recoveredSessionMethods.contains("session/load"),
            "restart should offer the prior provider session before draining its queue"
        )
        _ = await conversation.stop()
    }

    func testFailedSendPayloadStoreEvictsOldestAtExactAggregateBudget() throws {
        let attachment = AcpAttachment.image(
            data: Data(repeating: 0xA5, count: 1_024),
            mimeType: "image/png",
            name: "near-limit.png"
        )
        let payloadBytes = AcpFailedSendPayloadStore.payloadByteCount(
            text: "retry",
            attachments: [attachment]
        )
        var store = AcpFailedSendPayloadStore(
            maximumCount: 3,
            maximumBytes: payloadBytes * 2
        )

        XCTAssertEqual(
            store.retain(rowID: "user-1", text: "retry", attachments: [attachment]),
            .init(retained: true, evictedRowIDs: [])
        )
        XCTAssertEqual(
            store.retain(rowID: "user-2", text: "retry", attachments: [attachment]),
            .init(retained: true, evictedRowIDs: [])
        )
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.retainedBytes, payloadBytes * 2)

        XCTAssertEqual(
            store.retain(rowID: "user-3", text: "retry", attachments: [attachment]),
            .init(retained: true, evictedRowIDs: ["user-1"])
        )
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.retainedBytes, payloadBytes * 2)
        XCTAssertNil(store.remove(rowID: "user-1"))
        XCTAssertEqual(store.remove(rowID: "user-2")?.attachments, [attachment])
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.retainedBytes, payloadBytes)

        let oversized = AcpAttachment.image(
            data: Data(repeating: 0x5A, count: payloadBytes * 2),
            mimeType: "image/png",
            name: "too-large.png"
        )
        XCTAssertFalse(
            store.retain(rowID: "user-4", text: "retry", attachments: [oversized]).retained
        )
        XCTAssertEqual(store.count, 1, "an oversized new payload must not evict a safe older one")
        XCTAssertEqual(store.retainedBytes, payloadBytes)
        store.removeAll()
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.retainedBytes, 0)

        var countBoundStore = AcpFailedSendPayloadStore(
            maximumCount: 2,
            maximumBytes: payloadBytes * 3
        )
        _ = countBoundStore.retain(rowID: "user-1", text: "retry", attachments: [attachment])
        _ = countBoundStore.retain(rowID: "user-2", text: "retry", attachments: [attachment])
        XCTAssertEqual(
            countBoundStore.retain(rowID: "user-3", text: "retry", attachments: [attachment]),
            .init(retained: true, evictedRowIDs: ["user-1"])
        )
        XCTAssertEqual(countBoundStore.count, 2)
        XCTAssertEqual(countBoundStore.retainedBytes, payloadBytes * 2)
    }

    @MainActor
    func testRepeatedFailedAttachmentsPublishBoundedEvictionStatusAndStopReleasesThem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-failed-send-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("near-limit.txt")
        let contents = String(repeating: "x", count: 4_096)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        let retainedAttachment = AcpAttachment.textFile(
            path: fileURL.path,
            contents: contents,
            name: fileURL.lastPathComponent
        )
        let payloadBytes = AcpFailedSendPayloadStore.payloadByteCount(
            text: "retry",
            attachments: [retainedAttachment]
        )
        let transport = ScriptedAcpTransport(promptErrorMessage: "synthetic prompt failure")
        let conversation = AcpConversation(
            title: "Failed-send budget",
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: directory.path,
            client: AcpClient(transport: transport),
            failedSendPayloadMaximumCount: 3,
            failedSendPayloadMaximumBytes: payloadBytes * 2
        )
        await conversation.start()

        for expectedFailureCount in 1...3 {
            conversation.addAttachment(fileURL: fileURL)
            XCTAssertEqual(conversation.pendingAttachments.count, 1)
            XCTAssertTrue(conversation.send("retry"))
            try await Self.until("failed prompt \(expectedFailureCount) settled") {
                !conversation.isRunning && conversation.rows.filter { row in
                    if case let .user(_, _, failed) = row { return failed }
                    return false
                }.count == expectedFailureCount
            }
        }

        XCTAssertEqual(conversation.retainedFailedSendPayloadCount, 2)
        XCTAssertEqual(conversation.retainedFailedSendPayloadBytes, payloadBytes * 2)
        XCTAssertEqual(
            conversation.statusMessage,
            "Retry data for 1 older failed message was discarded to keep failed-send storage bounded."
        )
        XCTAssertLessThanOrEqual(conversation.statusMessage?.utf8.count ?? .max, 128)

        _ = await conversation.stop()
        XCTAssertEqual(conversation.retainedFailedSendPayloadCount, 0)
        XCTAssertEqual(conversation.retainedFailedSendPayloadBytes, 0)
    }

    @MainActor
    func testStopReleasesPayloadRecordedByAnInFlightPromptFailure() async throws {
        let transport = ScriptedAcpTransport(holdPromptOpen: true)
        let conversation = AcpConversation(
            title: "Stop during prompt",
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: "/tmp",
            client: AcpClient(transport: transport)
        )
        await conversation.start()
        XCTAssertTrue(conversation.send("in flight"))
        try await Self.until("the prompt reached the adapter") {
            await transport.receivedPromptBlocks().count == 1
        }

        _ = await conversation.stop()
        XCTAssertEqual(conversation.retainedFailedSendPayloadCount, 0)
        XCTAssertEqual(conversation.retainedFailedSendPayloadBytes, 0)
    }

    @MainActor
    func testFailedAttachmentRetryUsesTheCapturedSnapshotAfterTheSourceIsDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-failed-send-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("evidence.txt")
        let originalContents = "original private snapshot"
        try originalContents.write(to: fileURL, atomically: true, encoding: .utf8)

        let crashedTransport = ScriptedAcpTransport(
            crashOnFirstPrompt: true,
            promptEmbeddedContext: true
        )
        let recoveredTransport = ScriptedAcpTransport(promptEmbeddedContext: true)
        let clients = [
            AcpClient(transport: crashedTransport),
            AcpClient(transport: recoveredTransport),
        ]
        var clientIndex = 0
        let conversation = AcpConversation(
            title: "Retry snapshot",
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: directory.path,
            clientFactory: {
                let client = clients[clientIndex]
                clientIndex += 1
                return client
            }
        )
        await conversation.start()
        conversation.addAttachment(fileURL: fileURL)
        XCTAssertTrue(conversation.send("review evidence"))
        try await Self.until("the attachment prompt failed") {
            !conversation.isConnected && !conversation.isRunning
        }
        XCTAssertEqual(conversation.retainedFailedSendPayloadCount, 1)
        let failedRowID = try XCTUnwrap(conversation.rows.first(where: { row in
            if case let .user(_, _, failed) = row { return failed }
            return false
        })?.id)

        try "replacement contents".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fileURL)
        await conversation.restart()
        conversation.retryFailed(failedRowID)
        try await Self.until("the captured attachment retry completed") {
            !conversation.isRunning
        }

        let recoveredPromptBlocks = await recoveredTransport.receivedPromptBlocks()
        let blocks = try XCTUnwrap(recoveredPromptBlocks.first)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(
            blocks[1].objectValue?["resource"]?.objectValue?["text"],
            .string(originalContents),
            "Retry must use the captured value, never reread a changed or deleted path"
        )
        XCTAssertEqual(conversation.retainedFailedSendPayloadCount, 0)
        XCTAssertEqual(conversation.retainedFailedSendPayloadBytes, 0)
        _ = await conversation.stop()
    }

    @MainActor
    func testPersistedFailedRowRestoresNoRetryAttachmentPayload() async throws {
        let transport = ScriptedAcpTransport(promptEmbeddedContext: true)
        let conversation = AcpConversation(
            title: "Durable transcript",
            command: "mock",
            arguments: [],
            environment: [:],
            cwd: "/tmp",
            client: AcpClient(transport: transport),
            initialRows: [
                .user(id: "persisted", text: "review evidence\n📎 secret.txt", failed: true),
            ]
        )
        await conversation.start()
        XCTAssertEqual(conversation.retainedFailedSendPayloadCount, 0)
        XCTAssertEqual(conversation.retainedFailedSendPayloadBytes, 0)

        conversation.retryFailed("user-persisted")
        try await Self.until("the restored text-only retry completed") {
            !conversation.isRunning
        }
        let receivedPromptBlocks = await transport.receivedPromptBlocks()
        let blocks = try XCTUnwrap(receivedPromptBlocks.first)
        XCTAssertEqual(blocks.count, 1, "failed-send attachments must never be restored from transcript state")
        XCTAssertEqual(
            blocks.first?.objectValue?["text"],
            .string("review evidence\n📎 secret.txt")
        )
        _ = await conversation.stop()
    }

    @MainActor
    func testInjectingQueuedMessageLeavesTheTurnAndItsPermissionsAlone() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let ruleDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-steer-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ruleDirectory) }
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client,
            ruleStore: PermissionRuleStore(fileURL: ruleDirectory.appendingPathComponent("rules.json"))
        )
        await conversation.start()
        conversation.send("current")
        conversation.send("steer me")
        let options = [
            AcpPermissionRequest.Option(id: "allow", name: "Allow", kind: "allow_once"),
            AcpPermissionRequest.Option(id: "reject", name: "Reject", kind: "reject_once"),
        ]
        conversation.receivePermissionForTesting(AcpPermissionRequest(
            id: 101, sessionID: "session", title: "First", options: options
        ))
        conversation.receivePermissionForTesting(AcpPermissionRequest(
            id: 102, sessionID: "session", title: "Second", options: options
        ))
        XCTAssertEqual(conversation.pendingPermissionCount, 2)

        let queuedID = try XCTUnwrap(conversation.queued.first?.id)
        conversation.injectQueued(queuedID)

        // Injection joins the running turn instead of interrupting it, so the
        // asks that turn already raised stay exactly where they were. (The old
        // cancel-based steer had to discard them.)
        XCTAssertEqual(conversation.pendingPermissionCount, 2)
        XCTAssertEqual(conversation.pendingPermission?.title, "First")
    }

    @MainActor
    func testPermissionCountOverflowReturnsExactRejectOnceResponse() async throws {
        let transport = ScriptedAcpTransport()
        let conversation = AcpConversation(
            title: "Permission bounds", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport)
        )
        await conversation.start()
        for id in 1...AcpConversation.maximumOutstandingPermissionCount {
            await transport.emitPermission(wireID: Int64(id), title: "Accepted \(id)")
        }
        try await Self.until("the bounded permission queue filled") {
            conversation.pendingPermissionCount == AcpConversation.maximumOutstandingPermissionCount
        }

        let overflowWireID: Int64 = 9_999
        await transport.emitPermission(wireID: overflowWireID, title: "Overflow")
        try await Self.until("the overflow denial reached the adapter") {
            await transport.permissionResponse(for: overflowWireID) != nil
        }

        let response = await transport.permissionResponse(for: overflowWireID)
        XCTAssertEqual(response?.objectValue?["outcome"], .object([
            "outcome": .string("selected"),
            "optionId": .string("reject"),
        ]))
        XCTAssertEqual(
            conversation.pendingPermissionCount,
            AcpConversation.maximumOutstandingPermissionCount
        )
        XCTAssertTrue(conversation.rows.contains { row in
            guard case let .permissionDecision(_, text) = row else { return false }
            return text.contains("Overflow") && text.contains("denied automatically")
        })
        _ = await conversation.stop()
    }

    @MainActor
    func testExpiredPermissionReturnsRejectOnceResponseAndTimelineEvent() async throws {
        let transport = ScriptedAcpTransport()
        let conversation = AcpConversation(
            title: "Permission expiry", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: AcpClient(transport: transport)
        )
        await conversation.start()
        let wireID: Int64 = 8_888
        await transport.emitPermission(wireID: wireID, title: "Stale operation")
        try await Self.until("the permission surfaced") {
            conversation.pendingPermission != nil
        }

        conversation.expirePermissionsForTesting(
            at: Date().addingTimeInterval(AcpConversation.permissionPromptLifetime + 1)
        )
        try await Self.until("the expiry denial reached the adapter") {
            await transport.permissionResponse(for: wireID) != nil
        }

        let response = await transport.permissionResponse(for: wireID)
        XCTAssertEqual(response?.objectValue?["outcome"], .object([
            "outcome": .string("selected"),
            "optionId": .string("reject"),
        ]))
        XCTAssertNil(conversation.pendingPermission)
        XCTAssertTrue(conversation.rows.contains { row in
            guard case let .permissionDecision(_, text) = row else { return false }
            return text.contains("Stale operation") && text.contains("expired after 5 minutes")
        })

        // An adapter without exact reject_once must receive ACP's safe,
        // non-persistent cancelled outcome, never an opaque reject_always.
        let cancelledWireID: Int64 = 8_889
        await transport.emitPermission(
            wireID: cancelledWireID,
            title: "No one-time reject",
            includeRejectOnce: false
        )
        try await Self.until("the fallback permission surfaced") {
            conversation.pendingPermission != nil
        }
        conversation.expirePermissionsForTesting(
            at: Date().addingTimeInterval(AcpConversation.permissionPromptLifetime + 1)
        )
        try await Self.until("the cancelled expiry reached the adapter") {
            await transport.permissionResponse(for: cancelledWireID) != nil
        }
        let cancelled = await transport.permissionResponse(for: cancelledWireID)
        XCTAssertEqual(
            cancelled?.objectValue?["outcome"],
            .object(["outcome": .string("cancelled")])
        )
        _ = await conversation.stop()
    }

    func testSteeringCapabilityIsReadFromTheResponsesOwnMeta() {
        // Both adapters advertise steering on the InitializeResponse's own
        // `_meta`, a SIBLING of `agentCapabilities`. Reading it from inside the
        // capability block would leave the action permanently hidden.
        let advertised = AcpClient.parseCapabilities(.object([
            "protocolVersion": .integer(1),
            "agentCapabilities": .object(["loadSession": .bool(true)]),
            "_meta": .object(["steering": .object(["supported": .bool(true)])]),
        ]))
        XCTAssertTrue(advertised.steering)
        XCTAssertTrue(advertised.loadSession)

        // Nested in the wrong place is not an advertisement.
        let misplaced = AcpClient.parseCapabilities(.object([
            "agentCapabilities": .object([
                "_meta": .object(["steering": .object(["supported": .bool(true)])]),
            ]),
        ]))
        XCTAssertFalse(misplaced.steering)

        XCTAssertFalse(AcpClient.parseCapabilities(.object([:])).steering)
    }

    func testSteerRequestIsShapedLikeAPromptWithTheIdleOptIn() throws {
        let params = try XCTUnwrap(
            AcpSteering.requestParams(sessionID: "sess-1", text: "use tabs").objectValue
        )
        XCTAssertEqual(params["sessionId"], .string("sess-1"))
        XCTAssertEqual(params["prompt"], .array([.object([
            "type": .string("text"),
            "text": .string("use tabs"),
        ])]))
        // The opt-in keeps an idle session from starting a DETACHED turn whose
        // `session/prompt` response this client would never see.
        XCTAssertEqual(
            params["_meta"],
            .object(["steering": .object(["idleBehavior": .string("promptRequired")])])
        )
    }

    func testSteerOutcomeParsingTreatsAnythingUnknownAsRejected() {
        XCTAssertEqual(AcpSteering.parseOutcome(.object(["outcome": .string("injected")])), .injected)
        XCTAssertEqual(
            AcpSteering.parseOutcome(.object(["outcome": .string("startedNewTurn")])),
            .startedNewTurn
        )
        XCTAssertEqual(
            AcpSteering.parseOutcome(.object([
                "outcome": .string("promptRequired"),
                "reason": .string("noRunningTurn"),
            ])),
            .promptRequired
        )
        // Codex's own refusal vocabulary.
        guard case .rejected = AcpSteering.parseOutcome(.object(["outcome": .string("failed")])) else {
            return XCTFail("\"failed\" must not read as delivered")
        }
        guard case .rejected = AcpSteering.parseOutcome(.object(["outcome": .string("teleported")])) else {
            return XCTFail("an unknown outcome must not read as delivered")
        }
        guard case .rejected = AcpSteering.parseOutcome(.object([:])) else {
            return XCTFail("a missing outcome must not read as delivered")
        }
        guard case .rejected = AcpSteering.parseOutcome(nil) else {
            return XCTFail("no body must not read as delivered")
        }
    }

    func testInjectActionIsOfferedOnlyWhenItCanWork() {
        XCTAssertTrue(AcpSteering.canInject(supportsSteering: true, isConnected: true, isRunning: true))
        XCTAssertFalse(AcpSteering.canInject(supportsSteering: false, isConnected: true, isRunning: true))
        XCTAssertFalse(AcpSteering.canInject(supportsSteering: true, isConnected: false, isRunning: true))
        XCTAssertFalse(AcpSteering.canInject(supportsSteering: true, isConnected: true, isRunning: false))
    }

    func testSteerOutcomesMapToQueueTransitions() {
        XCTAssertEqual(AcpSteering.decide(.injected), .delivered)
        guard case .deliveredAsNewTurn = AcpSteering.decide(.startedNewTurn) else {
            return XCTFail("a turn the adapter started is already sent and must leave the queue")
        }
        guard case .keptQueued = AcpSteering.decide(.promptRequired) else {
            return XCTFail("nothing was sent, so the message must stay queued")
        }
        guard case let .keptQueued(notice) = AcpSteering.decide(.rejected("busy")) else {
            return XCTFail("a refusal must never lose the message")
        }
        XCTAssertTrue(notice.contains("busy"), "the user must be told why: \(notice)")
    }

    @MainActor
    func testInjectedQueuedMessageLeavesTheQueueAndJoinsTheTranscript() async throws {
        let transport = ScriptedAcpTransport(steerOutcome: "injected")
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        XCTAssertTrue(conversation.supportsSteering)
        XCTAssertFalse(conversation.canInjectQueued, "no turn is running yet")

        conversation.send("first")
        conversation.send("actually use tabs")
        XCTAssertTrue(conversation.canInjectQueued)
        let queuedID = try XCTUnwrap(conversation.queued.first?.id)
        conversation.injectQueued(queuedID)

        try await Self.until("the injected message left the queue") {
            conversation.queued.isEmpty && conversation.injectingQueuedIDs.isEmpty
        }
        let steerTexts = await transport.receivedSteerRequests().compactMap {
            $0.objectValue?["prompt"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        }
        XCTAssertEqual(steerTexts, ["actually use tabs"])
        // It rode the running turn, not a second `session/prompt` — checked once
        // the turn has fully settled so an unsent prompt cannot pass by being
        // merely late.
        try await Self.until("the turn settled") { !conversation.isRunning }
        let prompts = await transport.receivedPromptTexts()
        XCTAssertEqual(prompts, ["first"])
        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "actually use tabs"])
    }

    @MainActor
    func testRefusedInjectionKeepsTheMessageAndTellsTheUser() async throws {
        let transport = ScriptedAcpTransport(steerErrorMessage: "Session not found")
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("actually use tabs")
        let queuedID = try XCTUnwrap(conversation.queued.first?.id)
        conversation.injectQueued(queuedID)

        try await Self.until("the refusal was reported") {
            conversation.injectingQueuedIDs.isEmpty && conversation.statusMessage != nil
        }
        // Nothing was delivered, so nothing was lost: the message is still
        // queued and the ordinary flush will send it as its own turn.
        XCTAssertEqual(conversation.queued.map(\.text), ["actually use tabs"])
        XCTAssertTrue(
            conversation.statusMessage?.contains("Session not found") == true,
            "the user must be told: \(conversation.statusMessage ?? "nil")"
        )
        XCTAssertFalse(conversation.rows.contains { row in
            if case let .user(_, text, _) = row { return text == "actually use tabs" }
            return false
        }, "an undelivered message must not appear as if it had been said")
    }

    @MainActor
    func testTurnEndingMidInjectionSendsTheMessageExactlyOnce() async throws {
        // The Claude adapter answers `promptRequired` when the turn it was asked
        // to steer has already finished — the content stays host-owned, so the
        // queue must send it in the ordinary way and MUST NOT send it twice.
        let transport = ScriptedAcpTransport(steerOutcome: "promptRequired")
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("actually use tabs")
        let queuedID = try XCTUnwrap(conversation.queued.first?.id)
        conversation.injectQueued(queuedID)

        try await Self.until("the queue drained normally") {
            conversation.queued.isEmpty && !conversation.isRunning
        }
        let prompts = await transport.receivedPromptTexts()
        XCTAssertEqual(prompts, ["first", "actually use tabs"])
        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "actually use tabs"])
    }

    @MainActor
    func testUnsupportedAdapterNeverOffersTheInjectAction() async {
        let transport = ScriptedAcpTransport(steeringSupported: false)
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Steer", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("actually use tabs")
        XCTAssertFalse(conversation.supportsSteering)
        XCTAssertFalse(conversation.canInjectQueued)

        // Even called directly it must not put an unanswerable request on the
        // wire; the message simply stays queued.
        conversation.injectQueued(conversation.queued[0].id)
        XCTAssertTrue(conversation.injectingQueuedIDs.isEmpty)
        XCTAssertEqual(conversation.queued.map(\.text), ["actually use tabs"])
        let steers = await transport.receivedSteerRequests()
        XCTAssertTrue(steers.isEmpty)
    }

    // MARK: - Resumed sessions show the user's own prompts

    @MainActor
    func testResumedSessionRestoresTheUsersOwnPromptsWithoutDuplicatingThem() async throws {
        // `session/load` replays the whole thread. "already asked" is a prompt
        // this chat persisted locally, so its replay must be absorbed; "asked
        // before the store was pruned" is history only the adapter still has,
        // so it must appear.
        let transport = ScriptedAcpTransport(loadReplay: [
            (messageID: "m1", text: "already asked"),
            (messageID: "m2", text: "asked before the store was pruned"),
        ])
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Resume", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client,
            resumeSessionID: "sess-persisted",
            initialRows: [
                .user(id: "1", text: "already asked", failed: false),
                .message(id: "1", text: "An answer."),
            ]
        )
        await conversation.start()

        try await Self.until("the replay reached the transcript") {
            conversation.rows.contains { row in
                if case let .user(_, text, _) = row {
                    return text == "asked before the store was pruned"
                }
                return false
            }
        }
        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["already asked", "asked before the store was pruned"])
    }

    func testLedgerAbsorbsAReplayOnlyAsOftenAsTheTranscriptAlreadyShowsIt() {
        var ledger = AcpUserMessageLedger(rows: [
            .user(id: "1", text: "continue", failed: false),
            .user(id: "2", text: "continue", failed: false),
            .message(id: "1", text: "…"),
        ])
        // Two local rows absorb exactly two replayed copies.
        XCTAssertEqual(ledger.reconcile(text: "continue", adapterMessageID: "a"), .drop)
        XCTAssertEqual(ledger.reconcile(text: "continue", adapterMessageID: "b"), .drop)
        // A third is history this transcript does not have, so it is shown.
        XCTAssertEqual(
            ledger.reconcile(text: "continue", adapterMessageID: "c"),
            .append(id: "acp:c")
        )
        // …and recognized by id the next time the thread is loaded, without
        // needing the text to be unique.
        XCTAssertEqual(ledger.reconcile(text: "continue", adapterMessageID: "c"), .drop)
    }

    func testLedgerRecognizesItsOwnEarlierReplayAcrossARestart() {
        // The row an earlier replay appended was persisted under its adapter id,
        // so a later load matches on that id and shows it once.
        var ledger = AcpUserMessageLedger(rows: [
            .user(id: "acp:m2", text: "asked before the store was pruned", failed: false),
        ])
        XCTAssertEqual(
            ledger.reconcile(text: "asked before the store was pruned", adapterMessageID: "m2"),
            .drop
        )
    }

    func testLedgerGivesUnkeyedReplayChunksDistinctRowIdentities() {
        // Codex's rollout-file fallback replays user messages with no messageId.
        var ledger = AcpUserMessageLedger()
        XCTAssertEqual(ledger.reconcile(text: "one", adapterMessageID: nil), .append(id: "acp:anon-1"))
        XCTAssertEqual(ledger.reconcile(text: "two", adapterMessageID: nil), .append(id: "acp:anon-2"))
    }

    @MainActor
    func testLocallySentPromptIsNotShownTwiceWhenTheAdapterEchoesIt() async throws {
        // Claude echoes any prompt that carried more than one content block
        // (every attachment send) straight back as `user_message_chunk`.
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Echo", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("look at this")
        try await Self.until("the send landed") {
            conversation.rows.contains { if case .user = $0 { return true } else { return false } }
        }
        conversation.receiveTurnItemForTesting(.userMessage(id: "echo-1", text: "look at this"))

        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["look at this"])
    }

    @MainActor
    func testMultiBlockReplayFoldsIntoOneRowInsteadOfLeakingItsContext() {
        // A file attachment replays as several chunks sharing one messageId:
        // the prompt text, a link, then a `<context>` dump. They are one message
        // and must render as one row.
        let conversation = AcpConversation(
            title: "Replay", command: "mock", arguments: [], environment: [:], cwd: "/tmp"
        )
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: "review this"))
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: " [notes.txt]"))
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: "\n<context>…</context>"))

        let userRows = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userRows, ["review this [notes.txt]\n<context>…</context>"])
    }

    @MainActor
    func testSuppressedMultiBlockReplayDoesNotLeakItsRemainingChunks() {
        // When the first chunk is recognized as one the transcript already
        // shows, the rest of that message must stay suppressed with it —
        // otherwise the context dump would appear as a user row of its own.
        let conversation = AcpConversation(
            title: "Replay", command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            initialRows: [.user(id: "1", text: "review this", failed: false)]
        )
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: "review this"))
        conversation.receiveTurnItemForTesting(.userMessage(id: "m9", text: "\n<context>…</context>"))

        let userRows = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userRows, ["review this"])
    }

    /// Poll until `condition` holds, failing with `description` on timeout.
    @MainActor
    private static func until(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Async variant for actor-backed transport receipts.
    @MainActor
    private static func until(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return XCTFail("timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testConversationStopReturnsFinalDebouncedDraft() async {
        let key = "stop-draft-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "chatDraft.\(key)") }
        let conversation = AcpConversation(
            title: "Draft", command: "unused", arguments: [], cwd: "/tmp", draftKey: key
        )
        conversation.saveDraft("unfinished thought")

        let finalDraft = await conversation.stop()

        XCTAssertEqual(finalDraft, "unfinished thought")
    }
    func testRejectsUnsupportedNegotiatedProtocol() async throws {
        let transport = ScriptedAcpTransport(protocolVersion: 2)
        let client = AcpClient(transport: transport)
        do {
            _ = try await client.start(
                command: "mock", arguments: [], environment: [:], cwd: "/tmp",
                mcpServers: []
            )
            XCTFail("Expected the ACP protocol mismatch to fail before session/new")
        } catch let AcpClientError.unsupportedProtocol(version) {
            XCTAssertEqual(version, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let terminationCount = await transport.terminationCount()
        let sessionServers = await transport.receivedSessionMcpServers()
        XCTAssertEqual(terminationCount, 1)
        XCTAssertTrue(sessionServers.isEmpty)
    }

    func testMcpServersAreFilteredAgainstNegotiatedCapabilities() async throws {
        let transport = ScriptedAcpTransport(mcpHTTP: true, mcpSSE: false)
        let client = AcpClient(transport: transport)
        let configured: [JSONValue] = [
            .object([
                "name": .string("local"), "command": .string("mcp-local"),
                "args": .array([]), "env": .array([]),
            ]),
            .object([
                "type": .string("http"), "name": .string("remote"),
                "url": .string("https://example.com/mcp"), "headers": .array([]),
            ]),
            .object([
                "type": .string("sse"), "name": .string("stream"),
                "url": .string("https://example.com/sse"), "headers": .array([]),
            ]),
        ]

        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: configured
        )

        let sent = await transport.receivedSessionMcpServers()
        XCTAssertEqual(sent.compactMap { $0.objectValue?["name"]?.stringValue }, ["local", "remote"])
        XCTAssertNil(sent.first?.objectValue?["type"], "stdio must use the ACP untagged wire shape")
        XCTAssertEqual(sent.last?.objectValue?["type"], .string("http"))
    }

    func testInvalidMcpParamsRetrySessionWithoutTools() async throws {
        let transport = ScriptedAcpTransport(rejectFirstMcpSession: true)
        let client = AcpClient(transport: transport)
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [.object([
                "name": .string("local"), "command": .string("mcp-local"),
                "args": .array([]), "env": .array([]),
            ])]
        )
        let attempts = await transport.receivedSessionMcpAttempts()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first?.count, 1)
        XCTAssertTrue(attempts.last?.isEmpty == true)
    }

    func testRestartContinuityLoadsPriorAgentSessionWhenAdvertised() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let info = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [], resumeSessionID: "sess-persisted"
        )

        XCTAssertEqual(info.sessionID, "sess-persisted")
        let methods = await transport.receivedSessionMethods()
        XCTAssertEqual(methods, ["session/load"])
    }

    func testRestartContinuityPrefersStableResumeThenFallsBackFresh() async throws {
        let resumedTransport = ScriptedAcpTransport(resumeCapability: true)
        let resumedClient = AcpClient(transport: resumedTransport)
        let resumed = try await resumedClient.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [], resumeSessionID: "sess-stable"
        )
        XCTAssertEqual(resumed.sessionID, "sess-stable")
        let resumedMethods = await resumedTransport.receivedSessionMethods()
        XCTAssertEqual(resumedMethods, ["session/resume"])

        let staleTransport = ScriptedAcpTransport(rejectRestoration: true)
        let staleClient = AcpClient(transport: staleTransport)
        let fresh = try await staleClient.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [], resumeSessionID: "sess-pruned"
        )
        XCTAssertEqual(fresh.sessionID, "sess-1")
        let staleMethods = await staleTransport.receivedSessionMethods()
        XCTAssertEqual(staleMethods, ["session/load", "session/new"])
    }

    func testHandshakeAndStreamedTurn() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { event in collector.append(event) }

        let info = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: []
        )
        XCTAssertEqual(info.sessionID, "sess-1")
        XCTAssertEqual(info.models.map(\.id), ["opus", "sonnet"])
        // Nested SessionModeState parses; current mode carried through.
        XCTAssertEqual(info.modes.map(\.id), ["default", "plan"])
        XCTAssertEqual(info.currentModeID, "default")
        // Config options (effort levels) parse with their choices.
        XCTAssertEqual(info.configOptions.map(\.id), ["reasoning_effort"])
        XCTAssertEqual(info.configOptions.first?.currentValue, "low")
        XCTAssertEqual(info.configOptions.first?.choices.map(\.value), ["low", "high"])

        // The scripted transport streams a thought, a plan, two message chunks,
        // a tool call + completion, and a usage update when it sees the prompt.
        try await client.prompt("hello")

        let events = collector.events
        XCTAssertTrue(events.contains { if case .turnItem(.thought) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case .turnItem(.plan) = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains { if case let .turnItem(.toolCall(c)) = $0 { return c.id == "t1" } else { return false } })
        XCTAssertTrue(events.contains {
            if case let .toolCallUpdate(id, status, _, locations, _) = $0 {
                return id == "t1"
                    && status == .completed
                    && locations == ["Sources/App.swift"]
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case let .usage(u) = $0 {
                return u.used == 5000
                    && u.max == 200000
                    && u.costAmount == 0.42
                    && u.costCurrency == "USD"
            }
            return false
        })
        XCTAssertTrue(events.contains { if case .turnEnded = $0 { return true } else { return false } })
        // Slash commands stream in via available_commands_update.
        XCTAssertTrue(events.contains { event in
            if case let .commands(list) = event { return list.map(\.name) == ["compact", "review"] }
            return false
        })

        // set_config_option round-trips the adapter's normalized option set.
        await client.setConfigOption(id: "reasoning_effort", value: "high")
        XCTAssertTrue(collector.events.contains { event in
            if case let .configOptions(options) = event { return options.first?.currentValue == "high" }
            return false
        })
    }

    @MainActor
    func testConversationAccumulatesStreamingChunks() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        XCTAssertTrue(conversation.isConnected)

        conversation.send("hello")
        // Generous deadline: dispatch awaits a pre-turn git checkpoint before the
        // prompt is even sent, and a loaded CI runner can make that first git
        // spawn slow. A too-tight bound flakes on latency, not on a real stall.
        let deadline = Date().addingTimeInterval(15)
        while conversation.isRunning || !conversation.rows.contains(where: { if case .message = $0 { return true } else { return false } }) {
            if Date() > deadline { XCTFail("stream did not complete"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // The two "Hello" / " world" chunks accumulate into ONE message row.
        let messages = conversation.rows.compactMap { row -> String? in
            if case let .message(_, text) = row { return text } else { return nil }
        }
        XCTAssertEqual(messages, ["Hello world"])
        XCTAssertTrue(conversation.rows.contains { if case .user = $0 { return true } else { return false } })
        XCTAssertTrue(conversation.rows.contains { if case .tool = $0 { return true } else { return false } })
    }

    @MainActor
    func testFollowUpQueuedWhileRunningDispatchesAfterTurn() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let ruleFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-q-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("rules.json")
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client, ruleStore: PermissionRuleStore(fileURL: ruleFile)
        )
        defer { try? FileManager.default.removeItem(at: ruleFile.deletingLastPathComponent()) }
        await conversation.start()

        conversation.send("first")
        conversation.send("second")   // a turn is running → this queues
        XCTAssertTrue(conversation.isRunning)
        XCTAssertEqual(conversation.queued.map(\.text), ["second"])

        // Both turns complete: "second" dispatches when "first" ends, and the
        // queue drains.
        let deadline = Date().addingTimeInterval(5)
        while conversation.isRunning || !conversation.queued.isEmpty
            || conversation.rows.filter({ if case .user = $0 { return true } else { return false } }).count < 2 {
            if Date() > deadline { XCTFail("queued follow-up did not dispatch"); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "second"])
        XCTAssertTrue(conversation.queued.isEmpty)
    }

    @MainActor
    func testInjectingOneQueuedMessageLeavesTheRestOfTheQueueInOrder() async throws {
        // Steering is per-message: the one the user picked reaches the running
        // turn, and every other follow-up keeps its place in the FIFO.
        let transport = ScriptedAcpTransport(steerOutcome: "injected")
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("second")
        conversation.send("third")
        XCTAssertEqual(conversation.queued.map(\.text), ["second", "third"])

        let steerID = try XCTUnwrap(conversation.queued.last?.id)
        conversation.injectQueued(steerID)

        try await Self.until("the queue drained") {
            !conversation.isRunning && conversation.queued.isEmpty
                && conversation.injectingQueuedIDs.isEmpty
        }
        let prompts = await transport.receivedPromptTexts()
        XCTAssertEqual(prompts, ["first", "second"], "\"third\" was steered, not prompted")
        let userTexts = conversation.rows.compactMap { row -> String? in
            if case let .user(_, text, _) = row { return text } else { return nil }
        }
        XCTAssertEqual(userTexts, ["first", "third", "second"])
    }

    @MainActor
    func testRemoveQueuedDropsPendingFollowUp() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Test", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        conversation.send("first")
        conversation.send("drop me")
        let id = try XCTUnwrap(conversation.queued.first?.id)
        conversation.removeQueued(id)
        XCTAssertTrue(conversation.queued.isEmpty)
    }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AcpEvent] = []
    func append(_ event: AcpEvent) { lock.lock(); storage.append(event); lock.unlock() }
    var events: [AcpEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// A transport that answers the ACP handshake and, on a prompt, streams a
/// scripted `session/update` sequence, a permission request, then resolves.
private actor ScriptedAcpTransport: AcpByteTransport {
    private var outbound: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var started = false
    private let protocolVersion: Int64
    private let mcpHTTP: Bool
    private let mcpSSE: Bool
    private let rejectFirstMcpSession: Bool
    private let resumeCapability: Bool
    private let rejectRestoration: Bool
    private let crashOnFirstPrompt: Bool
    private let promptErrorMessage: String?
    private let holdPromptOpen: Bool
    private let promptEmbeddedContext: Bool
    private let steeringSupported: Bool
    private let steerOutcome: String?
    private let steerErrorMessage: String?
    private let loadReplay: [(messageID: String?, text: String)]
    private var sessionMcpServers: [JSONValue] = []
    private var sessionMcpAttempts: [[JSONValue]] = []
    private var sessionMethods: [String] = []
    private var promptTexts: [String] = []
    private var promptBlocks: [[JSONValue]] = []
    private var steerRequests: [JSONValue] = []
    private var permissionResponses: [Int64: JSONValue] = [:]
    private var didCrashPrompt = false
    private var recordedExitCode: Int32 = 0
    private var terminations = 0

    init(
        protocolVersion: Int64 = 1,
        mcpHTTP: Bool = true,
        mcpSSE: Bool = false,
        rejectFirstMcpSession: Bool = false,
        resumeCapability: Bool = false,
        rejectRestoration: Bool = false,
        crashOnFirstPrompt: Bool = false,
        promptErrorMessage: String? = nil,
        holdPromptOpen: Bool = false,
        promptEmbeddedContext: Bool = false,
        steeringSupported: Bool = true,
        steerOutcome: String? = "injected",
        steerErrorMessage: String? = nil,
        loadReplay: [(messageID: String?, text: String)] = []
    ) {
        self.protocolVersion = protocolVersion
        self.mcpHTTP = mcpHTTP
        self.mcpSSE = mcpSSE
        self.rejectFirstMcpSession = rejectFirstMcpSession
        self.resumeCapability = resumeCapability
        self.rejectRestoration = rejectRestoration
        self.crashOnFirstPrompt = crashOnFirstPrompt
        self.promptErrorMessage = promptErrorMessage
        self.holdPromptOpen = holdPromptOpen
        self.promptEmbeddedContext = promptEmbeddedContext
        self.steeringSupported = steeringSupported
        self.steerOutcome = steerOutcome
        self.steerErrorMessage = steerErrorMessage
        self.loadReplay = loadReplay
    }

    func receivedSessionMcpServers() -> [JSONValue] { sessionMcpServers }
    func receivedSessionMcpAttempts() -> [[JSONValue]] { sessionMcpAttempts }
    func receivedSessionMethods() -> [String] { sessionMethods }
    func receivedPromptTexts() -> [String] { promptTexts }
    func receivedPromptBlocks() -> [[JSONValue]] { promptBlocks }
    func receivedSteerRequests() -> [JSONValue] { steerRequests }
    func permissionResponse(for wireID: Int64) -> JSONValue? { permissionResponses[wireID] }
    func terminationCount() -> Int { terminations }

    func emitPermission(
        wireID: Int64,
        title: String,
        includeRejectOnce: Bool = true
    ) {
        var options: [JSONValue] = [
            .object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")]),
        ]
        if includeRejectOnce {
            options.append(.object([
                "optionId": .string("reject"),
                "name": .string("Reject"),
                "kind": .string("reject_once"),
            ]))
        } else {
            options.append(.object([
                "optionId": .string("reject-always"),
                "name": .string("Always reject"),
                "kind": .string("reject_always"),
            ]))
        }
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(wireID),
            "method": .string("session/request_permission"),
            "params": .object([
                "sessionId": .string("sess-1"),
                "toolCall": .object([
                    "toolCallId": .string("permission-\(wireID)"),
                    "title": .string(title),
                    "kind": .string("execute"),
                    "rawInput": .object(["command": .string("echo safe")]),
                ]),
                "options": .array(options),
            ]),
        ]))
    }

    func start(command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        started = true
    }

    func send(_ data: Data) async throws {
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: trimmed(data)).objectValue else { return }
        let id = object["id"]
        if object["method"] == nil,
           let wireID = id?.intValue,
           let result = object["result"] {
            permissionResponses[wireID] = result
            return
        }
        switch object["method"]?.stringValue {
        case "initialize":
            reply(id: id, result: .object([
                "protocolVersion": .integer(protocolVersion),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "sessionCapabilities": .object([
                        "resume": .bool(resumeCapability),
                        "close": .bool(true),
                    ]),
                    "mcpCapabilities": .object([
                        "http": .bool(mcpHTTP),
                        "sse": .bool(mcpSSE),
                    ]),
                    "promptCapabilities": .object([
                        "embeddedContext": .bool(promptEmbeddedContext),
                    ]),
                ]),
                // Sibling of `agentCapabilities`, exactly where both shipping
                // adapters advertise the steering extension.
                "_meta": .object(["steering": .object(["supported": .bool(steeringSupported)])]),
            ]))
        case "session/new":
            sessionMethods.append("session/new")
            sessionMcpServers = object["params"]?.objectValue?["mcpServers"]?.arrayValue ?? []
            sessionMcpAttempts.append(sessionMcpServers)
            if rejectFirstMcpSession, sessionMcpAttempts.count == 1, !sessionMcpServers.isEmpty {
                replyError(id: id, message: "Invalid params: unsupported MCP server")
                return
            }
            reply(id: id, result: .object([
                "sessionId": .string("sess-1"),
                // Flat models shape (exercises the fallback parse path).
                "models": .array([
                    .object(["modelId": .string("opus"), "name": .string("Opus")]),
                    .object(["modelId": .string("sonnet"), "name": .string("Sonnet")]),
                ]),
                // Nested modes shape (the ACP standard SessionModeState).
                "modes": .object([
                    "currentModeId": .string("default"),
                    "availableModes": .array([
                        .object(["id": .string("default"), "name": .string("Default")]),
                        .object(["id": .string("plan"), "name": .string("Plan")]),
                    ]),
                ]),
                "configOptions": .array([
                    .object([
                        "id": .string("reasoning_effort"),
                        "name": .string("Reasoning effort"),
                        "type": .string("select"),
                        "currentValue": .string("low"),
                        "options": .array([
                            .object(["value": .string("low"), "name": .string("Low")]),
                            .object(["value": .string("high"), "name": .string("High")]),
                        ]),
                    ]),
                ]),
            ]))
        case "session/load", "session/resume":
            let method = object["method"]?.stringValue ?? ""
            sessionMethods.append(method)
            if rejectRestoration {
                replyError(id: id, message: "Unknown session")
            } else {
                let restoredID = object["params"]?.objectValue?["sessionId"]?.stringValue ?? "sess-restored"
                // Both shipping adapters replay a loaded thread's whole history
                // as `session/update`s BEFORE answering the load.
                if method == "session/load" {
                    for entry in loadReplay {
                        var update: [String: JSONValue] = [
                            "sessionUpdate": .string("user_message_chunk"),
                            "content": .object([
                                "type": .string("text"),
                                "text": .string(entry.text),
                            ]),
                        ]
                        if let messageID = entry.messageID {
                            update["messageId"] = .string(messageID)
                        }
                        notify(update: .object(update))
                    }
                }
                reply(id: id, result: .object(["sessionId": .string(restoredID)]))
            }
        case AcpSteering.method:
            steerRequests.append(object["params"] ?? .null)
            if let steerErrorMessage {
                replyError(id: id, message: steerErrorMessage)
            } else if let steerOutcome {
                reply(id: id, result: .object(["outcome": .string(steerOutcome)]))
            } else {
                reply(id: id, result: .object([:]))
            }
        case "session/set_config_option":
            reply(id: id, result: .object([
                "configOptions": .array([
                    .object([
                        "id": .string("reasoning_effort"),
                        "name": .string("Reasoning effort"),
                        "currentValue": .string("high"),
                        "options": .array([
                            .object(["value": .string("low"), "name": .string("Low")]),
                            .object(["value": .string("high"), "name": .string("High")]),
                        ]),
                    ]),
                ]),
            ]))
        case "session/prompt":
            let blocks = object["params"]?.objectValue?["prompt"]?.arrayValue ?? []
            promptBlocks.append(blocks)
            if let text = blocks.first?.objectValue?["text"]?.stringValue {
                promptTexts.append(text)
            }
            if crashOnFirstPrompt, !didCrashPrompt {
                didCrashPrompt = true
                recordedExitCode = 17
                started = false
                waiter?.resume(returning: nil)
                waiter = nil
                return
            }
            if let promptErrorMessage {
                replyError(id: id, message: promptErrorMessage)
                return
            }
            if holdPromptOpen { return }
            streamTurn()
            reply(id: id, result: .object(["stopReason": .string("end_turn")]))
        default:
            if let id { reply(id: id, result: .null) }
        }
    }

    private func streamTurn() {
        notify(update: .object(["sessionUpdate": .string("agent_thought_chunk"), "content": .object(["type": .string("text"), "text": .string("thinking…")])]))
        notify(update: .object(["sessionUpdate": .string("plan"), "entries": .array([
            .object(["content": .string("step one"), "priority": .string("high"), "status": .string("pending")]),
        ])]))
        notify(update: .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Hello")])]))
        notify(update: .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string(" world")])]))
        notify(update: .object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("t1"), "title": .string("run echo"), "kind": .string("execute"), "status": .string("pending")]))
        notify(update: .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("t1"),
            "status": .string("completed"),
            "locations": .array([
                .object(["path": .string("Sources/App.swift")]),
            ]),
        ]))
        notify(update: .object(["sessionUpdate": .string("available_commands_update"), "availableCommands": .array([
            .object(["name": .string("compact"), "description": .string("Compact the conversation")]),
            .object(["name": .string("review"), "description": .string("Review changes")]),
        ])]))
        // Current ACP schema: `used` + `size`, with optional cumulative cost.
        notify(update: .object([
            "sessionUpdate": .string("usage_update"),
            "used": .integer(5000),
            "size": .integer(200000),
            "cost": .object(["amount": .number(0.42), "currency": .string("USD")]),
        ]))
    }

    private func reply(id: JSONValue?, result: JSONValue) {
        guard let id else { return }
        enqueue(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func replyError(id: JSONValue?, message: String) {
        guard let id else { return }
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .integer(-32602), "message": .string(message)]),
        ]))
    }

    private func notify(update: JSONValue) {
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object(["sessionId": .string("sess-1"), "update": update]),
        ]))
    }

    private func enqueue(_ value: JSONValue) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            outbound.append(data)
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        if !outbound.isEmpty { return outbound.removeFirst() }
        return await withCheckedContinuation { continuation in waiter = continuation }
    }

    func terminate() async {
        terminations += 1
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func exitCode() async -> Int32? { recordedExitCode }

    private func trimmed(_ data: Data) -> Data {
        data.last == 0x0A ? data.dropLast() : data
    }
}
