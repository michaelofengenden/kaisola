import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

@MainActor
final class CompanionCommandRouterTests: XCTestCase {
    func testAttentionAckRequiresExactProjectAndRevisionAndIsAtMostOnce() async throws {
        let router = CompanionCommandRouter()
        let device = try pairedDevice()
        var applied: [String] = []
        let envelope = try commandEnvelope(
            id: "command-attention-1",
            projectID: "project-1",
            targetID: "attention-session-1",
            expectedRevision: 7
        )

        let first = try await router.route(
            envelope,
            device: device,
            projection: projection(revision: 7),
            acknowledgeAttention: { applied.append($0); return true }
        )
        XCTAssertEqual(first.status, .applied)
        XCTAssertEqual(applied, ["session-1"])

        let replay = try await router.route(
            envelope,
            device: device,
            projection: projection(revision: 8),
            acknowledgeAttention: { applied.append($0); return true }
        )
        XCTAssertEqual(replay, first)
        XCTAssertEqual(applied, ["session-1"])

        let stale = try await router.route(
            commandEnvelope(
                id: "command-attention-stale",
                projectID: "project-1",
                targetID: "attention-session-1",
                expectedRevision: 6
            ),
            device: device,
            projection: projection(revision: 7),
            acknowledgeAttention: { _ in XCTFail("stale command applied"); return true }
        )
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.payload?["currentRevision"]?.intValue, 7)

        let wrongProject = try await router.route(
            commandEnvelope(
                id: "command-attention-wrong-project",
                projectID: "project-2",
                targetID: "attention-session-1",
                expectedRevision: 7
            ),
            device: device,
            projection: projection(revision: 7),
            acknowledgeAttention: { _ in XCTFail("cross-project command applied"); return true }
        )
        XCTAssertEqual(wrongProject.status, .rejected)
    }

    func testCommandIDCollisionRejectsDifferentContent() async throws {
        let router = CompanionCommandRouter()
        let device = try pairedDevice()
        let first = try await router.route(
            commandEnvelope(
                id: "command-collision",
                projectID: "project-1",
                targetID: "attention-session-1",
                expectedRevision: 7
            ),
            device: device,
            projection: projection(revision: 7),
            acknowledgeAttention: { _ in true }
        )
        XCTAssertEqual(first.status, .applied)

        let collision = try await router.route(
            commandEnvelope(
                id: "command-collision",
                projectID: "project-1",
                targetID: "attention-other",
                expectedRevision: 7
            ),
            device: device,
            projection: projection(revision: 7),
            acknowledgeAttention: { _ in XCTFail("collision applied"); return true }
        )
        XCTAssertEqual(collision.status, .rejected)
    }

    func testTerminalControlUsesOnlyTheExplicitExternalRoute() async throws {
        let router = CompanionCommandRouter()
        let device = try pairedDevice(capabilities: [.observe, .terminalControl])
        var routedTypes: [String] = []
        let envelope = try terminalCommandEnvelope(
            id: "command-terminal-acquire",
            type: "terminal.acquire-control"
        )
        let applied = try await router.route(
            envelope,
            device: device,
            projection: nil,
            acknowledgeAttention: { _ in XCTFail("terminal command entered attention route"); return false },
            handleExternal: { command in
                routedTypes.append(command.type)
                return CompanionReceiptBody(
                    type: "command.receipt",
                    commandId: command.commandId,
                    status: .applied,
                    message: "leased",
                    payload: ["leaseId": .string("lease-test")]
                )
            }
        )
        XCTAssertEqual(applied.status, .applied)
        XCTAssertEqual(routedTypes, ["terminal.acquire-control"])

        let unavailable = try await router.route(
            terminalCommandEnvelope(
                id: "command-terminal-no-adapter",
                type: "terminal.interrupt"
            ),
            device: device,
            projection: nil,
            acknowledgeAttention: { _ in false }
        )
        XCTAssertEqual(unavailable.status, .unavailable)
    }

    func testEffectiveGrantDeniesBeforeExternalRouteOrReceiptCache() async throws {
        let router = CompanionCommandRouter()
        let device = try pairedDevice(capabilities: [.observe, .terminalControl])
        var externalCalls = 0
        let result = try await router.route(
            terminalCommandEnvelope(id: "command-downgraded", type: "terminal.write"),
            device: device,
            effectiveCapabilities: [.observe],
            authorityGeneration: 2,
            projection: nil,
            acknowledgeAttention: { _ in false },
            handleExternal: { _ in
                externalCalls += 1
                return nil
            }
        )
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(
            result.message,
            "This device's Companion access changed. Refresh and try again."
        )
        XCTAssertEqual(externalCalls, 0)
    }

    func testGenerationChangeCancelsLateResultAndSealsCommandIdentity() async throws {
        let router = CompanionCommandRouter()
        let device = try pairedDevice(capabilities: [.observe, .terminalControl])
        let envelope = try terminalCommandEnvelope(
            id: "command-generation-race",
            type: "terminal.write"
        )
        let started = expectation(description: "external route started")
        let gate = CommandGate()
        var authorityIsCurrent = true
        var externalCalls = 0
        let firstTask = Task { @MainActor in
            try await router.route(
                envelope,
                device: device,
                effectiveCapabilities: [.observe, .terminalControl],
                authorityGeneration: 7,
                authorityIsCurrent: { authorityIsCurrent },
                projection: nil,
                acknowledgeAttention: { _ in false },
                handleExternal: { command in
                    externalCalls += 1
                    started.fulfill()
                    await gate.wait()
                    return CompanionReceiptBody(
                        type: "command.receipt",
                        commandId: command.commandId,
                        status: .applied,
                        message: "applied",
                        payload: nil
                    )
                }
            )
        }
        await fulfillment(of: [started], timeout: 2)
        authorityIsCurrent = false
        router.invalidate(deviceID: device.deviceId)
        await gate.release()
        let first = try await firstTask.value
        XCTAssertEqual(first.status, .rejected)

        authorityIsCurrent = true
        let second = try await router.route(
            envelope,
            device: device,
            effectiveCapabilities: [.observe, .terminalControl],
            authorityGeneration: 8,
            authorityIsCurrent: { authorityIsCurrent },
            projection: nil,
            acknowledgeAttention: { _ in false },
            handleExternal: { command in
                externalCalls += 1
                return CompanionReceiptBody(
                    type: "command.receipt",
                    commandId: command.commandId,
                    status: .applied,
                    message: "applied after regrant",
                    payload: nil
                )
            }
        )
        XCTAssertEqual(second.status, .rejected)
        XCTAssertEqual(
            second.message,
            "This device's Companion access changed. Refresh and try again."
        )
        XCTAssertEqual(externalCalls, 1)
    }

    private func projection(revision: Int) -> CompanionProjection {
        CompanionProjection(
            projectionKind: "kaisola.companion.projection",
            revision: revision,
            generatedAt: 100,
            freshness: "live",
            projects: [CompanionProject(
                id: "project-1",
                name: "Kaisola",
                connection: "live",
                lastContactAt: 100
            )],
            sessions: [],
            attention: [CompanionAttention(
                id: "attention-session-1",
                projectId: "project-1",
                sessionId: "session-1",
                kind: "review",
                title: "Review",
                createdAt: 100,
                severity: "info"
            )],
            permissions: []
        )
    }

    private func pairedDevice(
        capabilities: [CompanionCapability] = [.observe]
    ) throws -> CompanionPairedDeviceRecord {
        CompanionPairedDeviceRecord(
            deviceId: "device-router-test",
            displayName: "iPhone",
            identityPublic: Data(repeating: 1, count: 32).base64URLEncodedString(),
            x25519StaticPublic: Data(repeating: 2, count: 32).base64URLEncodedString(),
            capabilities: capabilities,
            pairedAt: 1,
            lastSeenAt: 1
        )
    }

    private func commandEnvelope(
        id: String,
        projectID: String,
        targetID: String,
        expectedRevision: Int64?
    ) throws -> CompanionEnvelope {
        try CompanionEnvelope(
            kind: .command,
            desktopId: "desktop-router-test",
            deviceId: "device-router-test",
            connectionId: "connection-router-test",
            epoch: "epoch-router-test",
            seq: 1,
            id: id,
            sentAt: 100,
            body: CompanionBody(CompanionCommandBody(
                type: "attention.ack",
                commandId: id,
                projectId: projectID,
                targetId: targetID,
                capability: .observe,
                expectedRevision: expectedRevision,
                payload: nil
            ))
        )
    }

    private func terminalCommandEnvelope(
        id: String,
        type: String
    ) throws -> CompanionEnvelope {
        try CompanionEnvelope(
            kind: .command,
            desktopId: "desktop-router-test",
            deviceId: "device-router-test",
            connectionId: "connection-router-test",
            epoch: "epoch-router-test",
            seq: 1,
            id: id,
            sentAt: 100,
            body: CompanionBody(CompanionCommandBody(
                type: type,
                commandId: id,
                projectId: "project-1",
                targetId: "terminal-1",
                capability: .terminalControl,
                expectedRevision: nil,
                payload: nil
            ))
        )
    }
}

private actor CommandGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
