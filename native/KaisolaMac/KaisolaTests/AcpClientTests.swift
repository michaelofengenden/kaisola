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

    func testPermissionResolutionSendsOnlyAnExactlyOfferedOptionOnce() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        let wireID: Int64 = 48_101
        await transport.emitPermission(
            wireID: wireID,
            title: "Exact membership",
            optionIDs: ["allow-once", "reject-once"]
        )
        try await Self.until("the exact-membership request surfaced") {
            events.permissionRequests.count == 1
        }
        let request = try XCTUnwrap(events.permissionRequests.first)

        await client.resolvePermission(id: request.id, optionID: "allow-once")
        try await Self.until("the valid one-shot response reached the adapter") {
            await transport.permissionResponseCount(for: wireID) == 1
        }
        let response = await transport.permissionResponse(for: wireID)
        XCTAssertEqual(response, .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string("allow-once"),
            ]),
        ]))
        let retainedAfterResolution = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterResolution, 0)

        // A duplicate selection arrives after the request has been consumed.
        // It must neither overwrite the result nor create another wire frame.
        await client.resolvePermission(id: request.id, optionID: "reject-once")
        let duplicateResponseCount = await transport.permissionResponseCount(for: wireID)
        let retainedAfterDuplicate = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(duplicateResponseCount, 1)
        XCTAssertEqual(retainedAfterDuplicate, 0)
    }

    func testPermissionResolutionRejectsEmptyAndNeverOfferedIDsWithoutConsumingRequest() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        let wireID: Int64 = 48_102
        await transport.emitPermission(
            wireID: wireID,
            title: "Invalid selections",
            optionIDs: ["offered"]
        )
        try await Self.until("the invalid-selection request surfaced") {
            events.permissionRequests.count == 1
        }
        let request = try XCTUnwrap(events.permissionRequests.first)

        // Empty and undisclosed ids are rejected by the same exact-membership
        // gate without consuming the valid request.
        await client.resolvePermission(id: request.id, optionID: "")
        await client.resolvePermission(id: request.id, optionID: "never-offered")
        let invalidResponseCount = await transport.permissionResponseCount(for: wireID)
        let retainedAfterInvalidSelections = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(invalidResponseCount, 0)
        XCTAssertEqual(retainedAfterInvalidSelections, 1)

        // Invalid attempts leave the real ask active and usable.
        await client.resolvePermission(id: request.id, optionID: "offered")
        try await Self.until("the request remained valid after rejected selections") {
            await transport.permissionResponseCount(for: wireID) == 1
        }
        let selectedOptionID = await transport.permissionResponse(for: wireID)?
            .objectValue?["outcome"]?.objectValue?["optionId"]
        let retainedAfterValidSelection = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(selectedOptionID, .string("offered"))
        XCTAssertEqual(retainedAfterValidSelection, 0)
    }

    func testStalePermissionCannotResolveSameWireIDInANewGeneration() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )

        let reusedWireID: Int64 = 48_103
        await transport.emitPermission(
            wireID: reusedWireID,
            title: "Old generation",
            optionIDs: ["shared-option"]
        )
        try await Self.until("the old-generation request surfaced") {
            events.permissionRequests.count == 1
        }
        let staleRequest = try XCTUnwrap(events.permissionRequests.first)
        await client.stop()
        let retainedAfterStop = await client.retainedPermissionOptionSetCount
        let oldGenerationResponseCount = await transport.permissionResponseCount(for: reusedWireID)
        XCTAssertEqual(retainedAfterStop, 0)
        XCTAssertEqual(oldGenerationResponseCount, 0)

        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }
        await transport.emitPermission(
            wireID: reusedWireID,
            title: "New generation",
            optionIDs: ["shared-option"]
        )
        try await Self.until("the new-generation request surfaced") {
            events.permissionRequests.count == 2
        }
        let currentRequest = try XCTUnwrap(events.permissionRequests.last)
        XCTAssertNotEqual(staleRequest.id, currentRequest.id)

        // Even the same wire id and same offered option string do not let a
        // stale local request cross the adapter-generation boundary.
        await client.resolvePermission(id: staleRequest.id, optionID: "shared-option")
        let staleResponseCount = await transport.permissionResponseCount(for: reusedWireID)
        let retainedCurrentRequest = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(staleResponseCount, 0)
        XCTAssertEqual(retainedCurrentRequest, 1)

        await client.resolvePermission(id: currentRequest.id, optionID: "shared-option")
        try await Self.until("the current generation resolved") {
            await transport.permissionResponseCount(for: reusedWireID) == 1
        }
        let newSelectedOptionID = await transport.permissionResponse(for: reusedWireID)?
            .objectValue?["outcome"]?.objectValue?["optionId"]
        let retainedAfterCurrentResolution = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(newSelectedOptionID, .string("shared-option"))
        XCTAssertEqual(retainedAfterCurrentResolution, 0)
    }

    func testPermissionAggregateByteBoundaryIsExactAndErrorIsTypedAndSafe() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        let marker = "SENSITIVE_PERMISSION_MARKER"
        let emptyPadding = Self.permissionParams(
            title: marker,
            extra: ["padding": .string("")]
        )
        let emptyMeasurement = AcpClient.validatePermissionRequestPayload(emptyPadding)
        XCTAssertNil(emptyMeasurement.rejection)
        let paddingCount = AcpPermissionPayloadLimits.maximumAggregateBytes
            - emptyMeasurement.aggregateBytes
        XCTAssertGreaterThan(paddingCount, 0)

        let exact = Self.permissionParams(
            title: marker,
            extra: ["padding": .string(String(repeating: "p", count: paddingCount))]
        )
        let exactMeasurement = AcpClient.validatePermissionRequestPayload(exact)
        XCTAssertNil(exactMeasurement.rejection)
        XCTAssertEqual(
            exactMeasurement.aggregateBytes,
            AcpPermissionPayloadLimits.maximumAggregateBytes
        )

        let validWireID: Int64 = 48_201
        await transport.emitPermission(wireID: validWireID, params: exact)
        try await Self.until("the aggregate-limit request surfaced") {
            events.permissionRequests.count == 1
        }
        let request = try XCTUnwrap(events.permissionRequests.first)
        await client.resolvePermission(id: request.id, optionID: "allow")
        try await Self.until("the aggregate-limit request resolved once") {
            await transport.permissionResponseCount(for: validWireID) == 1
        }

        let oversized = Self.permissionParams(
            title: marker,
            extra: ["padding": .string(String(repeating: "p", count: paddingCount + 1))]
        )
        XCTAssertEqual(
            AcpClient.validatePermissionRequestPayload(oversized).rejection,
            .aggregateBytes
        )
        let rejectedWireID: Int64 = 48_202
        await transport.emitPermission(wireID: rejectedWireID, params: oversized)
        try await Self.until("the aggregate overflow was rejected") {
            await transport.permissionError(for: rejectedWireID) != nil
        }
        let receivedError = await transport.permissionError(for: rejectedWireID)
        let error = try XCTUnwrap(receivedError)
        XCTAssertEqual(error.objectValue?["code"], .integer(-32602))
        XCTAssertEqual(error.objectValue?["message"], .string("Permission request rejected"))
        XCTAssertEqual(Self.permissionErrorReason(error), "aggregate_bytes")
        let encodedError = try JSONEncoder().encode(error)
        XCTAssertLessThanOrEqual(encodedError.count, 256)
        XCTAssertFalse(String(decoding: encodedError, as: UTF8.self).contains(marker))
        XCTAssertEqual(events.permissionRequests.count, 1, "an oversized ask must not emit a card")
        let retainedAfterAggregateRejection = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterAggregateRejection, 0)
    }

    func testPermissionFieldLimitsUseUTF8BytesAtAndOverBoundary() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        let exactTitle = String(
            repeating: "é",
            count: AcpPermissionPayloadLimits.maximumTitleBytes / "é".utf8.count
        )
        XCTAssertEqual(exactTitle.utf8.count, AcpPermissionPayloadLimits.maximumTitleBytes)
        let titleWireID: Int64 = 48_203
        await transport.emitPermission(
            wireID: titleWireID,
            params: Self.permissionParams(title: exactTitle)
        )
        try await Self.until("the maximum UTF-8 title surfaced") {
            events.permissionRequests.count == 1
        }
        await client.resolvePermission(
            id: try XCTUnwrap(events.permissionRequests.last).id,
            optionID: "allow"
        )
        try await Self.until("the maximum UTF-8 title resolved") {
            await transport.permissionResponseCount(for: titleWireID) == 1
        }

        let titleOverflowWireID: Int64 = 48_204
        await transport.emitPermission(
            wireID: titleOverflowWireID,
            params: Self.permissionParams(title: exactTitle + "é")
        )
        try await Self.until("the UTF-8 title overflow was rejected") {
            await transport.permissionError(for: titleOverflowWireID) != nil
        }
        let titleError = await transport.permissionError(for: titleOverflowWireID)
        XCTAssertEqual(Self.permissionErrorReason(titleError), "title_bytes")

        let exactRaw = String(
            repeating: "r",
            count: AcpPermissionPayloadLimits.maximumRawInputBytes - 2
        )
        let rawWireID: Int64 = 48_205
        await transport.emitPermission(
            wireID: rawWireID,
            params: Self.permissionParams(rawInput: .string(exactRaw))
        )
        try await Self.until("the maximum raw input surfaced") {
            events.permissionRequests.count == 2
        }
        await client.resolvePermission(
            id: try XCTUnwrap(events.permissionRequests.last).id,
            optionID: "allow"
        )
        try await Self.until("the maximum raw input resolved") {
            await transport.permissionResponseCount(for: rawWireID) == 1
        }

        let rawOverflowWireID: Int64 = 48_206
        await transport.emitPermission(
            wireID: rawOverflowWireID,
            params: Self.permissionParams(rawInput: .string(exactRaw + "r"))
        )
        try await Self.until("the raw-input byte overflow was rejected") {
            await transport.permissionError(for: rawOverflowWireID) != nil
        }
        let rawInputError = await transport.permissionError(for: rawOverflowWireID)
        XCTAssertEqual(Self.permissionErrorReason(rawInputError), "raw_input_bytes")

        let exactKind = String(repeating: "k", count: AcpPermissionPayloadLimits.maximumKindBytes)
        let kindWireID: Int64 = 48_207
        await transport.emitPermission(
            wireID: kindWireID,
            params: Self.permissionParams(kind: exactKind)
        )
        try await Self.until("the maximum kind surfaced") {
            events.permissionRequests.count == 3
        }
        await client.resolvePermission(
            id: try XCTUnwrap(events.permissionRequests.last).id,
            optionID: "allow"
        )
        try await Self.until("the maximum kind resolved") {
            await transport.permissionResponseCount(for: kindWireID) == 1
        }
        let kindOverflowWireID: Int64 = 48_208
        await transport.emitPermission(
            wireID: kindOverflowWireID,
            params: Self.permissionParams(kind: exactKind + "k")
        )
        try await Self.until("the kind byte overflow was rejected") {
            await transport.permissionError(for: kindOverflowWireID) != nil
        }
        let kindError = await transport.permissionError(for: kindOverflowWireID)
        XCTAssertEqual(Self.permissionErrorReason(kindError), "kind_bytes")

        var exactSessionFields = try XCTUnwrap(Self.permissionParams().objectValue)
        exactSessionFields["sessionId"] = .string(String(
            repeating: "s",
            count: AcpPermissionPayloadLimits.maximumSessionIDBytes
        ))
        let sessionWireID: Int64 = 48_241
        await transport.emitPermission(wireID: sessionWireID, params: .object(exactSessionFields))
        try await Self.until("the maximum session-id field surfaced") {
            events.permissionRequests.count == 4
        }
        await client.resolvePermission(
            id: try XCTUnwrap(events.permissionRequests.last).id,
            optionID: "allow"
        )
        try await Self.until("the maximum session-id field resolved") {
            await transport.permissionResponseCount(for: sessionWireID) == 1
        }
        exactSessionFields["sessionId"] = .string(String(
            repeating: "s",
            count: AcpPermissionPayloadLimits.maximumSessionIDBytes + 1
        ))
        let sessionOverflowWireID: Int64 = 48_242
        await transport.emitPermission(
            wireID: sessionOverflowWireID,
            params: .object(exactSessionFields)
        )
        try await Self.until("the session-id byte overflow was rejected") {
            await transport.permissionError(for: sessionOverflowWireID) != nil
        }
        let sessionIDError = await transport.permissionError(for: sessionOverflowWireID)
        XCTAssertEqual(Self.permissionErrorReason(sessionIDError), "session_id_bytes")

        var exactToolCallFields = try XCTUnwrap(Self.permissionParams().objectValue)
        var exactToolCall = try XCTUnwrap(exactToolCallFields["toolCall"]?.objectValue)
        exactToolCall["toolCallId"] = .string(String(
            repeating: "t",
            count: AcpPermissionPayloadLimits.maximumToolCallIDBytes
        ))
        exactToolCallFields["toolCall"] = .object(exactToolCall)
        let toolCallWireID: Int64 = 48_243
        await transport.emitPermission(wireID: toolCallWireID, params: .object(exactToolCallFields))
        try await Self.until("the maximum tool-call-id field surfaced") {
            events.permissionRequests.count == 5
        }
        await client.resolvePermission(
            id: try XCTUnwrap(events.permissionRequests.last).id,
            optionID: "allow"
        )
        try await Self.until("the maximum tool-call-id field resolved") {
            await transport.permissionResponseCount(for: toolCallWireID) == 1
        }
        exactToolCall["toolCallId"] = .string(String(
            repeating: "t",
            count: AcpPermissionPayloadLimits.maximumToolCallIDBytes + 1
        ))
        exactToolCallFields["toolCall"] = .object(exactToolCall)
        let toolCallOverflowWireID: Int64 = 48_244
        await transport.emitPermission(
            wireID: toolCallOverflowWireID,
            params: .object(exactToolCallFields)
        )
        try await Self.until("the tool-call-id byte overflow was rejected") {
            await transport.permissionError(for: toolCallOverflowWireID) != nil
        }
        let toolCallIDError = await transport.permissionError(for: toolCallOverflowWireID)
        XCTAssertEqual(Self.permissionErrorReason(toolCallIDError), "tool_call_id_bytes")

        XCTAssertEqual(events.permissionRequests.count, 5)
        let retainedAfterFieldRejections = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterFieldRejections, 0)
    }

    func testPermissionOptionCountAndEveryOptionFieldAreBounded() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        func option(id: String, name: String, kind: String) -> JSONValue {
            .object([
                "optionId": .string(id),
                "name": .string(name),
                "kind": .string(kind),
            ])
        }
        var nextWireID: Int64 = 48_209
        var expectedCards = 0
        let boundaryOptions: [[JSONValue]] = [
            (0 ..< AcpPermissionPayloadLimits.maximumOptionCount).map {
                option(id: "option-\($0)", name: "Option \($0)", kind: "allow_once")
            },
            [option(
                id: String(repeating: "i", count: AcpPermissionPayloadLimits.maximumOptionIDBytes),
                name: "Allow",
                kind: "allow_once"
            )],
            [option(
                id: "allow-name",
                name: String(repeating: "n", count: AcpPermissionPayloadLimits.maximumOptionNameBytes),
                kind: "allow_once"
            )],
            [option(
                id: "allow-kind",
                name: "Allow",
                kind: String(repeating: "k", count: AcpPermissionPayloadLimits.maximumOptionKindBytes)
            )],
        ]
        for options in boundaryOptions {
            let wireID = nextWireID
            nextWireID += 1
            expectedCards += 1
            await transport.emitPermission(
                wireID: wireID,
                params: Self.permissionParams(options: options)
            )
            try await Self.until("option boundary request \(wireID) surfaced") {
                events.permissionRequests.count == expectedCards
            }
            let request = try XCTUnwrap(events.permissionRequests.last)
            await client.resolvePermission(id: request.id, optionID: request.options[0].id)
            try await Self.until("option boundary request \(wireID) resolved") {
                await transport.permissionResponseCount(for: wireID) == 1
            }
        }

        let overLimitOptions: [(options: [JSONValue], reason: String)] = [
            (
                (0 ... AcpPermissionPayloadLimits.maximumOptionCount).map {
                    option(id: "option-\($0)", name: "Option \($0)", kind: "allow_once")
                },
                "option_count"
            ),
            ([option(
                id: String(repeating: "i", count: AcpPermissionPayloadLimits.maximumOptionIDBytes + 1),
                name: "Allow",
                kind: "allow_once"
            )], "option_id_bytes"),
            ([option(
                id: "allow-name",
                name: String(repeating: "n", count: AcpPermissionPayloadLimits.maximumOptionNameBytes + 1),
                kind: "allow_once"
            )], "option_name_bytes"),
            ([option(
                id: "allow-kind",
                name: "Allow",
                kind: String(repeating: "k", count: AcpPermissionPayloadLimits.maximumOptionKindBytes + 1)
            )], "option_kind_bytes"),
        ]
        for testCase in overLimitOptions {
            let wireID = nextWireID
            nextWireID += 1
            await transport.emitPermission(
                wireID: wireID,
                params: Self.permissionParams(options: testCase.options)
            )
            try await Self.until("option overflow \(wireID) was rejected") {
                await transport.permissionError(for: wireID) != nil
            }
            let error = await transport.permissionError(for: wireID)
            XCTAssertEqual(Self.permissionErrorReason(error), testCase.reason)
        }
        XCTAssertEqual(events.permissionRequests.count, expectedCards)
        let retainedAfterOptionRejections = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterOptionRejections, 0)
    }

    func testPermissionPathsAreDeduplicatedThenCountedAndFieldBounded() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        let duplicates = Array(repeating: "Sources/Duplicate.swift", count: 2_000)
        let duplicateWireID: Int64 = 48_217
        await transport.emitPermission(
            wireID: duplicateWireID,
            params: Self.permissionParams(locations: duplicates, diffPaths: duplicates)
        )
        try await Self.until("duplicate paths were deduplicated") {
            events.permissionRequests.count == 1
        }
        let duplicateRequest = try XCTUnwrap(events.permissionRequests.last)
        XCTAssertEqual(duplicateRequest.paths, ["Sources/Duplicate.swift"])
        await client.resolvePermission(id: duplicateRequest.id, optionID: "allow")
        try await Self.until("the duplicate-path request resolved") {
            await transport.permissionResponseCount(for: duplicateWireID) == 1
        }

        let exactPaths = (0 ..< AcpPermissionPayloadLimits.maximumPathCount).map {
            "Sources/P\($0).swift"
        }
        let pathCountWireID: Int64 = 48_218
        await transport.emitPermission(
            wireID: pathCountWireID,
            params: Self.permissionParams(locations: exactPaths)
        )
        try await Self.until("the maximum distinct path count surfaced") {
            events.permissionRequests.count == 2
        }
        let pathCountRequest = try XCTUnwrap(events.permissionRequests.last)
        XCTAssertEqual(pathCountRequest.paths.count, AcpPermissionPayloadLimits.maximumPathCount)
        await client.resolvePermission(id: pathCountRequest.id, optionID: "allow")
        try await Self.until("the maximum distinct path request resolved") {
            await transport.permissionResponseCount(for: pathCountWireID) == 1
        }

        let pathCountOverflowWireID: Int64 = 48_219
        await transport.emitPermission(
            wireID: pathCountOverflowWireID,
            params: Self.permissionParams(locations: exactPaths + ["Sources/Overflow.swift"])
        )
        try await Self.until("the distinct path overflow was rejected") {
            await transport.permissionError(for: pathCountOverflowWireID) != nil
        }
        let pathCountError = await transport.permissionError(for: pathCountOverflowWireID)
        XCTAssertEqual(Self.permissionErrorReason(pathCountError), "path_count")

        let exactPath = String(repeating: "p", count: AcpPermissionPayloadLimits.maximumPathBytes)
        let pathBytesWireID: Int64 = 48_220
        await transport.emitPermission(
            wireID: pathBytesWireID,
            params: Self.permissionParams(diffPaths: [exactPath])
        )
        try await Self.until("the maximum path field surfaced") {
            events.permissionRequests.count == 3
        }
        let pathBytesRequest = try XCTUnwrap(events.permissionRequests.last)
        await client.resolvePermission(id: pathBytesRequest.id, optionID: "allow")
        try await Self.until("the maximum path field resolved") {
            await transport.permissionResponseCount(for: pathBytesWireID) == 1
        }

        let pathBytesOverflowWireID: Int64 = 48_221
        await transport.emitPermission(
            wireID: pathBytesOverflowWireID,
            params: Self.permissionParams(diffPaths: [exactPath + "p"])
        )
        try await Self.until("the path field overflow was rejected") {
            await transport.permissionError(for: pathBytesOverflowWireID) != nil
        }
        let pathBytesError = await transport.permissionError(for: pathBytesOverflowWireID)
        XCTAssertEqual(Self.permissionErrorReason(pathBytesError), "path_bytes")
        XCTAssertEqual(events.permissionRequests.count, 3)
        let retainedAfterPathRejections = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterPathRejections, 0)
    }

    func testPermissionRawInputComplexityStopsAtNodeBudget() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        let exactRawInput = JSONValue.array(Array(
            repeating: .null,
            count: AcpPermissionPayloadLimits.maximumRawInputNodes - 1
        ))
        let exactWireID: Int64 = 48_222
        await transport.emitPermission(
            wireID: exactWireID,
            params: Self.permissionParams(rawInput: exactRawInput)
        )
        try await Self.until("the maximum-node raw input surfaced") {
            events.permissionRequests.count == 1
        }
        let exactRequest = try XCTUnwrap(events.permissionRequests.last)
        await client.resolvePermission(id: exactRequest.id, optionID: "allow")
        try await Self.until("the maximum-node raw input resolved") {
            await transport.permissionResponseCount(for: exactWireID) == 1
        }

        let oversizedRawInput = JSONValue.array(Array(
            repeating: .null,
            count: AcpPermissionPayloadLimits.maximumRawInputNodes
        ))
        let oversizedParams = Self.permissionParams(rawInput: oversizedRawInput)
        let validation = AcpClient.validatePermissionRequestPayload(oversizedParams)
        XCTAssertEqual(validation.rejection, .complexity)
        XCTAssertEqual(
            validation.inspectedNodes,
            AcpPermissionPayloadLimits.maximumRawInputNodes + 1,
            "rawInput traversal must stop at the first node over budget"
        )

        let oversizedWireID: Int64 = 48_223
        await transport.emitPermission(wireID: oversizedWireID, params: oversizedParams)
        try await Self.until("the over-complex raw input was rejected") {
            await transport.permissionError(for: oversizedWireID) != nil
        }
        let complexityError = await transport.permissionError(for: oversizedWireID)
        XCTAssertEqual(Self.permissionErrorReason(complexityError), "complexity")
        XCTAssertEqual(events.permissionRequests.count, 1)
        let retainedAfterComplexityRejection = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterComplexityRejection, 0)
    }

    func testInheritedToolContextIsBoundedBeforePermissionEmission() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        let rawToolCallID = "retained-raw"
        await transport.emitSessionUpdate(.object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string(rawToolCallID),
            "title": .string("Retained raw input"),
            "kind": .string("execute"),
            "rawInput": .array(Array(
                repeating: .null,
                count: AcpPermissionPayloadLimits.maximumRawInputNodes
            )),
        ]))
        let rawWireID: Int64 = 48_245
        await transport.emitPermission(wireID: rawWireID, params: .object([
            "sessionId": .string("sess-1"),
            "toolCall": .object(["toolCallId": .string(rawToolCallID)]),
            "options": .array([.object(["optionId": .string("allow")])]),
        ]))
        try await Self.until("inherited raw input was rejected") {
            await transport.permissionError(for: rawWireID) != nil
        }
        let rawError = await transport.permissionError(for: rawWireID)
        XCTAssertEqual(Self.permissionErrorReason(rawError), "incomplete_review_context")

        let pathsToolCallID = "retained-paths"
        let inheritedPaths = (0 ... AcpPermissionPayloadLimits.maximumPathCount).map {
            JSONValue.object(["path": .string("Sources/Inherited\($0).swift")])
        }
        await transport.emitSessionUpdate(.object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string(pathsToolCallID),
            "title": .string("Retained paths"),
            "kind": .string("edit"),
            "locations": .array(inheritedPaths),
        ]))
        let pathsWireID: Int64 = 48_246
        await transport.emitPermission(wireID: pathsWireID, params: .object([
            "sessionId": .string("sess-1"),
            "toolCall": .object(["toolCallId": .string(pathsToolCallID)]),
            "options": .array([.object(["optionId": .string("allow")])]),
        ]))
        try await Self.until("inherited path count was rejected") {
            await transport.permissionError(for: pathsWireID) != nil
        }
        let pathsError = await transport.permissionError(for: pathsWireID)
        XCTAssertEqual(Self.permissionErrorReason(pathsError), "incomplete_review_context")
        XCTAssertTrue(events.permissionRequests.isEmpty)
        let retained = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retained, 0)
        let retainedContextBytes = await client.retainedToolCallReviewContextBytes
        XCTAssertLessThanOrEqual(
            retainedContextBytes,
            AcpToolCallReviewContextLimits.production.maximumAggregateBytes
        )
    }

    func testToolReviewContextUsesExactUTF8AndAggregateByteBoundaries() {
        let limits = AcpToolCallReviewContextLimits(
            maximumContextBytes: 128,
            maximumAggregateBytes: 256,
            maximumCount: 8
        )
        let exactRawInput = String(repeating: "é", count: 39)
        XCTAssertEqual(exactRawInput.utf8.count, 78)
        var store = AcpToolCallReviewContextStore(limits: limits)

        store.record(id: "context1", update: ["rawInput": .string(exactRawInput)])
        XCTAssertEqual(store.retainedBytes, 128)
        XCTAssertEqual(store.lookup(id: "context1").context?.rawInput, .string(exactRawInput))
        XCTAssertTrue(store.lookup(id: "context1").unavailableFields.isEmpty)

        store.record(id: "context2", update: ["rawInput": .string(exactRawInput)])
        XCTAssertEqual(store.retainedBytes, 256)
        XCTAssertEqual(store.count, 2)

        // A field one UTF-8 byte over the exact per-context boundary is
        // discarded and explicitly made unavailable rather than partially
        // retained or allowed to exceed the ceiling.
        var overBoundaryStore = AcpToolCallReviewContextStore(limits: limits)
        overBoundaryStore.record(
            id: "boundary",
            update: ["rawInput": .string(exactRawInput + "x")]
        )
        let overBoundary = overBoundaryStore.lookup(id: "boundary")
        XCTAssertNil(overBoundary.context?.rawInput)
        XCTAssertEqual(overBoundary.unavailableFields, [.rawInput])
        XCTAssertLessThanOrEqual(overBoundaryStore.retainedBytes, limits.maximumContextBytes)

        // Touch context1 so aggregate eviction is deterministic LRU, then add
        // one more exact-sized entry. The untouched oldest context is removed.
        store.record(id: "context1", update: ["status": .string("pending")])
        store.record(id: "context3", update: ["rawInput": .string(exactRawInput)])
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.retainedBytes, 256)
        XCTAssertNotNil(store.lookup(id: "context1").context)
        XCTAssertNotNil(store.lookup(id: "context3").context)
        let evicted = store.lookup(id: "context2")
        XCTAssertNil(evicted.context)
        XCTAssertEqual(evicted.unavailableFields, Set(AcpToolCallReviewField.allCases))
        XCTAssertTrue(store.hasEvictedContext)

        let partialValidation = AcpClient.validatePermissionRequestPayload(
            Self.permissionParams(),
            priorContext: evicted.context,
            unavailablePriorFields: evicted.unavailableFields
        )
        XCTAssertEqual(partialValidation.rejection, .incompleteReviewContext)

        let selfContainedValidation = AcpClient.validatePermissionRequestPayload(
            Self.permissionParams(rawInput: .null, locations: [], diffPaths: []),
            priorContext: evicted.context,
            unavailablePriorFields: evicted.unavailableFields
        )
        XCTAssertNil(selfContainedValidation.rejection)

        store.removeAll(keepingCapacity: true)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.retainedBytes, 0)
        XCTAssertFalse(store.hasEvictedContext)
    }

    func testEveryOversizedReviewFieldIsUnavailableUntilExplicitlyReplaced() {
        var store = AcpToolCallReviewContextStore()
        store.record(id: "hostile-context", update: [
            "title": .string(String(
                repeating: "t",
                count: AcpPermissionPayloadLimits.maximumTitleBytes + 1
            )),
            "kind": .string(String(
                repeating: "k",
                count: AcpPermissionPayloadLimits.maximumKindBytes + 1
            )),
            "rawInput": .array(Array(
                repeating: .null,
                count: AcpPermissionPayloadLimits.maximumRawInputNodes
            )),
            "locations": .array((0 ... AcpPermissionPayloadLimits.maximumPathCount).map {
                .object(["path": .string("Sources/Hostile\($0).swift")])
            }),
            "content": .array([.object([
                "type": .string("diff"),
                "path": .string(String(
                    repeating: "p",
                    count: AcpPermissionPayloadLimits.maximumPathBytes + 1
                )),
            ])]),
        ])

        let redacted = store.lookup(id: "hostile-context")
        XCTAssertEqual(redacted.unavailableFields, Set(AcpToolCallReviewField.allCases))
        XCTAssertNil(redacted.context?.title)
        XCTAssertNil(redacted.context?.kind)
        XCTAssertNil(redacted.context?.rawInput)
        XCTAssertEqual(redacted.context?.locationPaths, [])
        XCTAssertEqual(redacted.context?.diffPaths, [])
        XCTAssertLessThanOrEqual(
            store.retainedBytes,
            AcpToolCallReviewContextLimits.production.maximumContextBytes
        )

        store.record(id: "hostile-context", update: [
            "title": .string("Review safe replacement"),
            "kind": .string("edit"),
            "rawInput": .object(["operation": .string("replace")]),
            "locations": .array([.object(["path": .string("Sources/App.swift")])]),
            "content": .array([.object([
                "type": .string("diff"),
                "path": .string("Tests/AppTests.swift"),
            ])]),
        ])
        let replaced = store.lookup(id: "hostile-context")
        XCTAssertTrue(replaced.unavailableFields.isEmpty)
        XCTAssertEqual(replaced.context?.title, "Review safe replacement")
        XCTAssertEqual(replaced.context?.kind, "edit")
        XCTAssertEqual(replaced.context?.locationPaths, ["Sources/App.swift"])
        XCTAssertEqual(replaced.context?.diffPaths, ["Tests/AppTests.swift"])
    }

    func testEvictedToolReviewContextFailsClosedButSelfContainedAskStillWorks() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(
            transport: transport,
            toolCallReviewContextLimits: AcpToolCallReviewContextLimits(
                maximumContextBytes: 128,
                maximumAggregateBytes: 256,
                maximumCount: 8
            )
        )
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        let exactRawInput = String(repeating: "é", count: 39)
        for id in ["context1", "context2"] {
            await transport.emitSessionUpdate(.object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string(id),
                "rawInput": .string(exactRawInput),
            ]))
        }
        await transport.emitSessionUpdate(.object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("context1"),
            "status": .string("pending"),
        ]))
        await transport.emitSessionUpdate(.object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("context3"),
            "rawInput": .string(exactRawInput),
        ]))
        try await Self.until("the oldest review context was evicted") {
            await client.hasEvictedToolCallReviewContext
        }
        let retainedBytes = await client.retainedToolCallReviewContextBytes
        let retainedCount = await client.retainedToolCallReviewContextCount
        XCTAssertEqual(retainedBytes, 256)
        XCTAssertEqual(retainedCount, 2)

        let partialWireID: Int64 = 48_247
        await transport.emitPermission(wireID: partialWireID, params: .object([
            "sessionId": .string("sess-1"),
            "toolCall": .object(["toolCallId": .string("context2")]),
            "options": .array([.object(["optionId": .string("allow")])]),
        ]))
        try await Self.until("the partial ask depending on evicted evidence was rejected") {
            await transport.permissionError(for: partialWireID) != nil
        }
        let partialError = await transport.permissionError(for: partialWireID)
        XCTAssertEqual(Self.permissionErrorReason(partialError), "incomplete_review_context")
        XCTAssertEqual(
            partialError?.objectValue?["data"]?.objectValue?["summary"],
            .string("Permission request depends on review details that are no longer available.")
        )
        XCTAssertTrue(events.permissionRequests.isEmpty)

        let completeWireID: Int64 = 48_248
        await transport.emitPermission(wireID: completeWireID, params: .object([
            "sessionId": .string("sess-1"),
            "toolCall": .object([
                "toolCallId": .string("context2"),
                "title": .string("Self-contained action"),
                "kind": .string("execute"),
                "rawInput": .null,
                "locations": .array([]),
                "content": .array([]),
            ]),
            "options": .array([.object(["optionId": .string("allow")])]),
        ]))
        try await Self.until("the self-contained ask surfaced") {
            events.permissionRequests.count == 1
        }
        let request = try XCTUnwrap(events.permissionRequests.first)
        XCTAssertEqual(request.title, "Self-contained action")
        await client.resolvePermission(id: request.id, optionID: "allow")
        try await Self.until("the self-contained ask resolved") {
            await transport.permissionResponseCount(for: completeWireID) == 1
        }
    }

    func testMalformedPermissionPayloadsNeverEmitCardsOrRetainMetadata() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let events = EventCollector()
        await client.setEventHandler { events.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        let malformed: [JSONValue] = [
            .string("not params"),
            .object(["sessionId": .string("sess-1")]),
            .object(["sessionId": .string("sess-1"), "options": .array([])]),
            .object(["sessionId": .string("sess-1"), "options": .array([.string("bad")])]),
            .object([
                "sessionId": .string("sess-1"),
                "options": .array([.object(["optionId": .string("")])]),
            ]),
            .object([
                "sessionId": .string("sess-1"),
                "options": .array([.object([
                    "optionId": .string("allow"),
                    "name": .integer(7),
                ])]),
            ]),
            .object([
                "sessionId": .string("sess-1"),
                "options": .array([.object([
                    "optionId": .string("allow"),
                    "kind": .bool(true),
                ])]),
            ]),
            .object([
                "sessionId": .string("sess-1"),
                "toolCall": .string("bad"),
                "options": .array([.object(["optionId": .string("allow")])]),
            ]),
            .object([
                "sessionId": .string("sess-1"),
                "toolCall": .object(["locations": .string("bad")]),
                "options": .array([.object(["optionId": .string("allow")])]),
            ]),
            .object([
                "sessionId": .string("sess-1"),
                "toolCall": .object(["locations": .array([.object([:])])]),
                "options": .array([.object(["optionId": .string("allow")])]),
            ]),
            .object([
                "sessionId": .string("sess-1"),
                "toolCall": .object([
                    "content": .array([.object(["type": .string("diff")])]),
                ]),
                "options": .array([.object(["optionId": .string("allow")])]),
            ]),
        ]
        for (index, params) in malformed.enumerated() {
            let wireID = Int64(48_224 + index)
            await transport.emitPermission(wireID: wireID, params: params)
            try await Self.until("malformed request \(index) was rejected") {
                await transport.permissionError(for: wireID) != nil
            }
            let error = await transport.permissionError(for: wireID)
            let replyCount = await transport.permissionReplyCount(for: wireID)
            XCTAssertEqual(Self.permissionErrorReason(error), "malformed")
            XCTAssertEqual(replyCount, 1)
        }
        XCTAssertTrue(events.permissionRequests.isEmpty)
        let retainedAfterMalformedRequests = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterMalformedRequests, 0)

        // Rejections retain no active state. A later healthy request still
        // surfaces normally and remains governed by #481 membership.
        let validWireID: Int64 = 48_240
        await transport.emitPermission(
            wireID: validWireID,
            params: Self.permissionParams(options: [
                .object(["optionId": .string("allow"), "kind": .string("allow_once")]),
            ])
        )
        try await Self.until("a healthy sibling request surfaced") {
            events.permissionRequests.count == 1
        }
        let validRequest = try XCTUnwrap(events.permissionRequests.first)
        await client.resolvePermission(id: validRequest.id, optionID: "never-offered")
        let invalidSelectionReplyCount = await transport.permissionReplyCount(for: validWireID)
        XCTAssertEqual(invalidSelectionReplyCount, 0)
        await client.resolvePermission(id: validRequest.id, optionID: "allow")
        try await Self.until("the healthy sibling request resolved once") {
            await transport.permissionResponseCount(for: validWireID) == 1
        }
        let validReplyCount = await transport.permissionReplyCount(for: validWireID)
        let retainedAfterValidSibling = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(validReplyCount, 1)
        XCTAssertEqual(retainedAfterValidSibling, 0)
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
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Permission bounds", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
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
        let retainedAtQueueBound = await client.retainedPermissionOptionSetCount
        XCTAssertLessThanOrEqual(
            retainedAtQueueBound, AcpConversation.maximumOutstandingPermissionCount
        )
        XCTAssertTrue(conversation.rows.contains { row in
            guard case let .permissionDecision(_, text) = row else { return false }
            return text.contains("Overflow") && text.contains("denied automatically")
        })
        _ = await conversation.stop()
        let retainedAfterStop = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterStop, 0)
    }

    @MainActor
    func testExpiredPermissionReturnsRejectOnceResponseAndTimelineEvent() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let conversation = AcpConversation(
            title: "Permission expiry", command: "mock", arguments: [], environment: [:],
            cwd: "/tmp", client: client
        )
        await conversation.start()
        let wireID: Int64 = 8_888
        await transport.emitPermission(wireID: wireID, title: "Stale operation")
        try await Self.until("the permission surfaced") {
            conversation.pendingPermission != nil
        }
        let expiredRequestID = try XCTUnwrap(conversation.pendingPermission?.id)

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
        let retainedAfterSelectedExpiry = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterSelectedExpiry, 0)
        await client.resolvePermission(id: expiredRequestID, optionID: "allow")
        let selectedExpiryResponseCount = await transport.permissionResponseCount(for: wireID)
        XCTAssertEqual(selectedExpiryResponseCount, 1, "an expired request must stay consumed")
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
        let cancelledRequestID = try XCTUnwrap(conversation.pendingPermission?.id)
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
        let retainedAfterCancelledExpiry = await client.retainedPermissionOptionSetCount
        XCTAssertEqual(retainedAfterCancelledExpiry, 0)
        await client.resolvePermission(id: cancelledRequestID, optionID: "allow")
        let cancelledExpiryResponseCount = await transport.permissionResponseCount(for: cancelledWireID)
        XCTAssertEqual(cancelledExpiryResponseCount, 1, "a cancelled request must stay consumed")
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

    private static func permissionParams(
        title: String = "Review action",
        kind: String = "execute",
        rawInput: JSONValue? = nil,
        locations: [String]? = nil,
        diffPaths: [String]? = nil,
        options: [JSONValue]? = nil,
        extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var toolCall: [String: JSONValue] = [
            "toolCallId": .string("permission-probe"),
            "title": .string(title),
            "kind": .string(kind),
        ]
        if let rawInput { toolCall["rawInput"] = rawInput }
        if let locations {
            toolCall["locations"] = .array(locations.map { .object(["path": .string($0)]) })
        }
        if let diffPaths {
            toolCall["content"] = .array(diffPaths.map {
                .object(["type": .string("diff"), "path": .string($0)])
            })
        }
        var params: [String: JSONValue] = [
            "sessionId": .string("sess-1"),
            "toolCall": .object(toolCall),
            "options": .array(options ?? [
                .object([
                    "optionId": .string("allow"),
                    "name": .string("Allow"),
                    "kind": .string("allow_once"),
                ]),
            ]),
        ]
        for (key, value) in extra { params[key] = value }
        return .object(params)
    }

    private static func permissionErrorReason(_ error: JSONValue?) -> String? {
        error?.objectValue?["data"]?.objectValue?["reason"]?.stringValue
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

    func testSessionUpdatesRequireTheExactActiveIdentityAndBoundDiagnostics() async throws {
        let transport = ScriptedAcpTransport()
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { collector.append($0) }
        _ = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        defer { Task { await client.stop() } }

        await transport.emitSessionUpdateWithoutSessionID(.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("missing identity")]),
        ]))
        for index in 0 ..< 39 {
            await transport.emitSessionUpdate(.object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("stale \(index)"),
                ]),
            ]), sessionID: "old-\(index)")
        }
        await transport.emitSessionUpdate(.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("current")]),
        ]), sessionID: "sess-1")

        // A request/response after the notifications is a deterministic FIFO
        // barrier: no scheduler timing or sleep is needed before assertions.
        await client.setConfigOption(id: "reasoning_effort", value: "high")

        let messages = collector.events.compactMap { event -> String? in
            if case let .turnItem(.message(_, text)) = event { return text }
            return nil
        }
        XCTAssertEqual(messages, ["current"])
        let diagnostics = await client.sessionIdentityDiagnostics()
        XCTAssertEqual(diagnostics.total, 40)
        XCTAssertEqual(diagnostics.tail.count, AcpClient.maximumSessionIdentityDiagnostics)
        XCTAssertTrue(diagnostics.tail.allSatisfy { $0.method == "session/update" })
        XCTAssertTrue(diagnostics.tail.allSatisfy { $0.reason == .identityMismatch })
        XCTAssertEqual(diagnostics.tail.first?.receivedSessionIDBytes, "old-7".utf8.count)
        XCTAssertEqual(diagnostics.tail.last?.receivedSessionIDBytes, "old-38".utf8.count)
        XCTAssertEqual(diagnostics.tail.last?.expectedSessionIDBytes, "sess-1".utf8.count)
    }

    func testRestartDropsPriorSessionOutputBeforeTheNewIdentityIsEstablished() async throws {
        let transport = ScriptedAcpTransport(
            newSessionIDs: ["sess-stable", "sess-stable"],
            restartRaceStaleSessionID: "sess-stable"
        )
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { collector.append($0) }
        let first = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        XCTAssertEqual(first.sessionID, "sess-stable")
        let retiredGeneration = await client.connectionGenerationForTesting()
        await client.stop()

        let second = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp", mcpServers: []
        )
        XCTAssertEqual(second.sessionID, "sess-stable")
        let activeGeneration = await client.connectionGenerationForTesting()
        XCTAssertNotEqual(retiredGeneration, activeGeneration)
        await client.handleSessionUpdateForTesting(
            sessionID: "sess-stable",
            update: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("late retired-reader output"),
                ]),
            ]),
            sourceConnectionGeneration: retiredGeneration
        )
        await client.handleSessionUpdateForTesting(sessionID: "sess-stable", update: .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("current restart output")]),
        ]), sourceConnectionGeneration: activeGeneration)

        let messages = collector.events.compactMap { event -> String? in
            if case let .turnItem(.message(_, text)) = event { return text }
            return nil
        }
        XCTAssertEqual(messages, ["current restart output"])
        let diagnostics = await client.sessionIdentityDiagnostics()
        XCTAssertEqual(diagnostics.total, 2)
        XCTAssertEqual(
            diagnostics.tail.map(\.reason),
            [.noActiveSession, .staleConnectionGeneration]
        )
        XCTAssertEqual(diagnostics.tail.first?.receivedSessionIDBytes, "sess-stable".utf8.count)
        XCTAssertNil(diagnostics.tail.first?.expectedSessionIDBytes)
        XCTAssertEqual(diagnostics.tail.last?.connectionGeneration, activeGeneration)
        XCTAssertEqual(diagnostics.tail.last?.receivedSessionIDBytes, "sess-stable".utf8.count)
        XCTAssertNil(diagnostics.tail.last?.expectedSessionIDBytes)
        await client.stop()
    }

    func testLoadReplayAcceptsOnlyThePendingRestoredIdentityBeforeResponse() async throws {
        let transport = ScriptedAcpTransport(
            loadRaceStaleSessionID: "sess-pruned",
            loadReplay: [(messageID: "m-current", text: "current restored history")]
        )
        let client = AcpClient(transport: transport)
        let collector = EventCollector()
        await client.setEventHandler { collector.append($0) }

        let info = try await client.start(
            command: "mock", arguments: [], environment: [:], cwd: "/tmp",
            mcpServers: [], resumeSessionID: "sess-persisted"
        )
        XCTAssertEqual(info.sessionID, "sess-persisted")

        // The scripted load emits both notifications before its response, so
        // start() returning is the deterministic review/mutation race barrier.
        let replay = collector.events.compactMap { event -> String? in
            switch event {
            case let .turnItem(.message(_, text)), let .turnItem(.userMessage(_, text)):
                return text
            default:
                return nil
            }
        }
        XCTAssertEqual(replay, ["current restored history"])
        let diagnostics = await client.sessionIdentityDiagnostics()
        XCTAssertEqual(diagnostics.total, 1)
        XCTAssertEqual(diagnostics.tail.map(\.reason), [.identityMismatch])
        XCTAssertEqual(diagnostics.tail.first?.receivedSessionIDBytes, "sess-pruned".utf8.count)
        XCTAssertEqual(diagnostics.tail.first?.expectedSessionIDBytes, "sess-persisted".utf8.count)
        await client.stop()
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
    var permissionRequests: [AcpPermissionRequest] {
        events.compactMap { event in
            if case let .permission(request) = event { return request }
            return nil
        }
    }
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
    private let newSessionIDs: [String]
    private let restartRaceStaleSessionID: String?
    private let loadRaceStaleSessionID: String?
    private let loadReplay: [(messageID: String?, text: String)]
    private var sessionMcpServers: [JSONValue] = []
    private var sessionMcpAttempts: [[JSONValue]] = []
    private var sessionMethods: [String] = []
    private var promptTexts: [String] = []
    private var promptBlocks: [[JSONValue]] = []
    private var steerRequests: [JSONValue] = []
    private var permissionResponses: [Int64: [JSONValue]] = [:]
    private var permissionErrors: [Int64: [JSONValue]] = [:]
    private var didCrashPrompt = false
    private var recordedExitCode: Int32 = 0
    private var terminations = 0
    private var newSessionIndex = 0
    private var currentSessionID = "sess-1"

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
        newSessionIDs: [String] = ["sess-1"],
        restartRaceStaleSessionID: String? = nil,
        loadRaceStaleSessionID: String? = nil,
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
        self.newSessionIDs = newSessionIDs.isEmpty ? ["sess-1"] : newSessionIDs
        self.restartRaceStaleSessionID = restartRaceStaleSessionID
        self.loadRaceStaleSessionID = loadRaceStaleSessionID
        self.loadReplay = loadReplay
    }

    func receivedSessionMcpServers() -> [JSONValue] { sessionMcpServers }
    func receivedSessionMcpAttempts() -> [[JSONValue]] { sessionMcpAttempts }
    func receivedSessionMethods() -> [String] { sessionMethods }
    func receivedPromptTexts() -> [String] { promptTexts }
    func receivedPromptBlocks() -> [[JSONValue]] { promptBlocks }
    func receivedSteerRequests() -> [JSONValue] { steerRequests }
    func permissionResponse(for wireID: Int64) -> JSONValue? { permissionResponses[wireID]?.last }
    func permissionResponseCount(for wireID: Int64) -> Int { permissionResponses[wireID]?.count ?? 0 }
    func permissionError(for wireID: Int64) -> JSONValue? { permissionErrors[wireID]?.last }
    func permissionReplyCount(for wireID: Int64) -> Int {
        (permissionResponses[wireID]?.count ?? 0) + (permissionErrors[wireID]?.count ?? 0)
    }
    func terminationCount() -> Int { terminations }

    func emitPermission(
        wireID: Int64,
        title: String,
        includeRejectOnce: Bool = true,
        optionIDs: [String]? = nil
    ) {
        let options: [JSONValue]
        if let optionIDs {
            options = optionIDs.map { optionID in
                .object([
                    "optionId": .string(optionID),
                    "name": .string(optionID.isEmpty ? "Empty" : optionID),
                    "kind": .string("allow_once"),
                ])
            }
        } else {
            var defaultOptions: [JSONValue] = [
                .object([
                    "optionId": .string("allow"),
                    "name": .string("Allow"),
                    "kind": .string("allow_once"),
                ]),
            ]
            if includeRejectOnce {
                defaultOptions.append(.object([
                    "optionId": .string("reject"),
                    "name": .string("Reject"),
                    "kind": .string("reject_once"),
                ]))
            } else {
                defaultOptions.append(.object([
                    "optionId": .string("reject-always"),
                    "name": .string("Always reject"),
                    "kind": .string("reject_always"),
                ]))
            }
            options = defaultOptions
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

    func emitPermission(wireID: Int64, params: JSONValue) {
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(wireID),
            "method": .string("session/request_permission"),
            "params": params,
        ]))
    }

    func emitSessionUpdate(_ update: JSONValue, sessionID: String = "sess-1") {
        notify(update: update, sessionID: sessionID)
    }

    func emitSessionUpdateWithoutSessionID(_ update: JSONValue) {
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object(["update": update]),
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
            permissionResponses[wireID, default: []].append(result)
            return
        }
        if object["method"] == nil,
           let wireID = id?.intValue,
           let error = object["error"] {
            permissionErrors[wireID, default: []].append(error)
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
            let sessionIndex = min(newSessionIndex, newSessionIDs.count - 1)
            let newSessionID = newSessionIDs[sessionIndex]
            if newSessionIndex > 0, let restartRaceStaleSessionID {
                notify(update: .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("stale restart output"),
                    ]),
                ]), sessionID: restartRaceStaleSessionID)
            }
            newSessionIndex += 1
            currentSessionID = newSessionID
            reply(id: id, result: .object([
                "sessionId": .string(newSessionID),
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
                currentSessionID = restoredID
                // Both shipping adapters replay a loaded thread's whole history
                // as `session/update`s BEFORE answering the load.
                if method == "session/load" {
                    if let loadRaceStaleSessionID {
                        notify(update: .object([
                            "sessionUpdate": .string("agent_message_chunk"),
                            "content": .object([
                                "type": .string("text"),
                                "text": .string("stale restored history"),
                            ]),
                        ]), sessionID: loadRaceStaleSessionID)
                    }
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
                        notify(update: .object(update), sessionID: restoredID)
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

    private func notify(update: JSONValue, sessionID: String? = nil) {
        enqueue(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(sessionID ?? currentSessionID),
                "update": update,
            ]),
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
