import Foundation
import KaisolaCore
import XCTest
@testable import Kaisola

@MainActor
private final class TerminalAuthorizationState {
    var value = true
}

@MainActor
final class CompanionTerminalControlTests: XCTestCase {
    private enum Call: Equatable {
        case available(String)
        case write(String)
        case resize(Int, Int)
        case interrupt
    }

    @MainActor
    private final class FakeAdapter {
        var geometry: CompanionTerminalGeometry?
        var available = true
        var failMutations = false
        var calls: [Call] = []
        var controlStates: [Bool] = []

        init(columns: Int? = 120, rows: Int? = 42) {
            geometry = CompanionTerminalGeometry(columns: columns, rows: rows)
        }

        @MainActor
        func adapter() -> CompanionTerminalControlAdapter {
            CompanionTerminalControlAdapter(
                availability: { [weak self] terminal in
                    guard let self else { return nil }
                    self.calls.append(.available(terminal.id))
                    guard self.available else { return nil }
                    return CompanionTerminalControlAvailability(geometry: self.geometry)
                },
                write: { [weak self] _, data in
                    guard let self, !self.failMutations else {
                        throw CompanionTerminalControlAdapterError.unavailable
                    }
                    self.calls.append(.write(data))
                },
                resize: { [weak self] _, geometry in
                    guard let self, !self.failMutations else {
                        throw CompanionTerminalControlAdapterError.unavailable
                    }
                    self.calls.append(.resize(geometry.columns, geometry.rows))
                },
                interrupt: { [weak self] _ in
                    guard let self, !self.failMutations else {
                        throw CompanionTerminalControlAdapterError.unavailable
                    }
                    self.calls.append(.interrupt)
                },
                controlStateChanged: { [weak self] _, active in
                    self?.controlStates.append(active)
                }
            )
        }
    }

    func testLeaseGatesMutationsAndReleaseRestoresOriginalGeometry() async throws {
        let fake = FakeAdapter()
        let harness = makeControl(fake: fake)
        let acquired = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-first",
            connectionID: "connection-first",
            terminal: terminal
        )
        XCTAssertEqual(acquired.status, .applied)
        XCTAssertEqual(acquired.payload?["expiresAt"]?.intValue, 40_000)
        XCTAssertEqual(acquired.payload?["renewAfterMs"]?.intValue, 10_000)
        XCTAssertEqual(acquired.payload?["resizeEnabled"]?.boolValue, true)
        let leaseID = try XCTUnwrap(acquired.payload?["leaseId"]?.stringValue)
        XCTAssertTrue(leaseID.hasPrefix("lease-"))
        XCTAssertEqual(harness.statuses().last, [
            CompanionTerminalControlStatus(
                projectID: "project-kaisola",
                terminalID: "terminal-codex",
                deviceID: "device-first",
                connectionID: "connection-first",
                expiresAt: 40_000
            ),
        ])

        let wrote = try await route(
            harness.control,
            command("terminal.write", ["leaseId": .string(leaseID), "data": .string("npm test\r")]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(wrote.status, .applied)
        let resized = try await route(
            harness.control,
            command("terminal.resize", [
                "leaseId": .string(leaseID), "cols": .integer(92), "rows": .integer(31),
            ]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(resized.status, .applied)
        let interrupted = try await route(
            harness.control,
            command("terminal.interrupt", ["leaseId": .string(leaseID)]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(interrupted.status, .applied)
        let released = try await route(
            harness.control,
            command("terminal.release-control", ["leaseId": .string(leaseID)]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(released.status, .applied)
        XCTAssertEqual(fake.calls, [
            .available("terminal-codex"),
            .write("npm test\r"),
            .resize(92, 31),
            .interrupt,
            .resize(120, 42),
        ])
        XCTAssertEqual(fake.controlStates, [true, false])
        XCTAssertEqual(harness.statuses().last, [])
        XCTAssertEqual(harness.control.activeLeaseCount, 0)
    }

    func testContentionExpiryAndReacquisitionRejectStaleGeneration() async throws {
        let fake = FakeAdapter()
        let harness = makeControl(fake: fake)
        let first = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-first",
            connectionID: "connection-first",
            terminal: terminal
        )
        let firstID = try XCTUnwrap(first.payload?["leaseId"]?.stringValue)

        let denied = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-second",
            connectionID: "connection-second",
            terminal: terminal
        )
        XCTAssertEqual(denied.status, .rejected)
        XCTAssertTrue(denied.message?.contains("another device") == true)

        harness.setNow(40_000)
        let staleRenewal = try await route(
            harness.control,
            command("terminal.renew-control", ["leaseId": .string(firstID)]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(staleRenewal.status, .stale)

        let second = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-second",
            connectionID: "connection-second",
            terminal: terminal
        )
        XCTAssertEqual(second.status, .applied)
        XCTAssertNotEqual(second.payload?["leaseId"]?.stringValue, firstID)
        let delayed = try await route(
            harness.control,
            command("terminal.write", ["leaseId": .string(firstID), "data": .string("must-not-run")]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(delayed.status, .stale)
        XCTAssertFalse(fake.calls.contains(.write("must-not-run")))
        await harness.control.dispose()
    }

    func testInputGeometryAndConnectionBoundsFailBeforeAdapter() async throws {
        let fake = FakeAdapter()
        let harness = makeControl(fake: fake)
        let acquired = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-first",
            connectionID: "connection-first",
            terminal: terminal
        )
        let leaseID = try XCTUnwrap(acquired.payload?["leaseId"]?.stringValue)
        let baseline = fake.calls.count

        let empty = try await route(
            harness.control,
            command("terminal.write", ["leaseId": .string(leaseID), "data": .string("")]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(empty.status, .rejected)
        let oversized = try await route(
            harness.control,
            command("terminal.write", [
                "leaseId": .string(leaseID),
                "data": .string(String(repeating: "x", count: CompanionTerminalControl.maximumInputBytes + 1)),
            ]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(oversized.status, .rejected)
        let badSize = try await route(
            harness.control,
            command("terminal.resize", [
                "leaseId": .string(leaseID), "cols": .integer(19), "rows": .integer(30),
            ]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(badSize.status, .rejected)
        let wrongConnection = try await route(
            harness.control,
            command("terminal.write", ["leaseId": .string(leaseID), "data": .string("nope")]),
            deviceID: "device-first",
            connectionID: "connection-replaced"
        )
        XCTAssertEqual(wrongConnection.status, .stale)
        XCTAssertEqual(fake.calls.count, baseline)
        await harness.control.dispose()
    }

    func testUnknownGeometryAllowsInputButWithholdsResize() async throws {
        let fake = FakeAdapter(columns: nil, rows: nil)
        let harness = makeControl(fake: fake)
        let acquired = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-first",
            connectionID: "connection-first",
            terminal: terminal
        )
        XCTAssertEqual(acquired.payload?["resizeEnabled"]?.boolValue, false)
        let leaseID = try XCTUnwrap(acquired.payload?["leaseId"]?.stringValue)
        let resized = try await route(
            harness.control,
            command("terminal.resize", [
                "leaseId": .string(leaseID), "cols": .integer(80), "rows": .integer(24),
            ]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(resized.status, .unavailable)
        XCTAssertFalse(fake.calls.contains { if case .resize = $0 { true } else { false } })
        await harness.control.dispose()
    }

    func testDisconnectDropsOnlyThatConnectionsLeasesAndRestoresGeometry() async throws {
        let fake = FakeAdapter()
        let harness = makeControl(fake: fake)
        _ = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-first",
            connectionID: "connection-first",
            terminal: terminal
        )
        let unrelated = await harness.control.releaseConnection("another-connection")
        let released = await harness.control.releaseConnection("connection-first")
        XCTAssertEqual(unrelated, 0)
        XCTAssertEqual(released, 1)
        XCTAssertEqual(fake.calls.last, .resize(120, 42))
        XCTAssertEqual(harness.control.activeLeaseCount, 0)
    }

    func testInventoryReconciliationRevokesAControllerThatLostBrokerOwnership() async throws {
        let fake = FakeAdapter()
        let harness = makeControl(fake: fake)
        _ = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-first",
            connectionID: "connection-first",
            terminal: terminal
        )
        fake.available = false
        await harness.control.reconcileAvailableTerminals([terminal])
        XCTAssertEqual(harness.control.activeLeaseCount, 0)
        XCTAssertEqual(fake.calls.last, .resize(120, 42))
        XCTAssertEqual(fake.controlStates, [true, false])
    }

    func testAdapterFailureIsUnavailableAndNeverExtendsAuthority() async throws {
        let fake = FakeAdapter()
        let harness = makeControl(fake: fake)
        fake.available = false
        let unavailable = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-first",
            connectionID: "connection-first",
            terminal: terminal
        )
        XCTAssertEqual(unavailable.status, .unavailable)
        fake.available = true
        let acquired = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-first",
            connectionID: "connection-first",
            terminal: terminal
        )
        fake.failMutations = true
        let failed = try await route(
            harness.control,
            command("terminal.interrupt", [
                "leaseId": .string(try XCTUnwrap(acquired.payload?["leaseId"]?.stringValue)),
            ]),
            deviceID: "device-first",
            connectionID: "connection-first"
        )
        XCTAssertEqual(failed.status, .unavailable)
        await harness.control.dispose()
    }

    func testRevokedAuthorityCannotAcquireOrUseAnExistingLease() async throws {
        let fake = FakeAdapter()
        let harness = makeControl(fake: fake)
        let authorization = TerminalAuthorizationState()
        let acquired = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-first",
            connectionID: "connection-first",
            terminal: terminal,
            isAuthorized: { authorization.value }
        )
        let leaseID = try XCTUnwrap(acquired.payload?["leaseId"]?.stringValue)
        let baseline = fake.calls

        authorization.value = false
        let revokedWrite = try await route(
            harness.control,
            command("terminal.write", [
                "leaseId": .string(leaseID),
                "data": .string("must-not-cross-revocation"),
            ]),
            deviceID: "device-first",
            connectionID: "connection-first",
            isAuthorized: { authorization.value }
        )
        XCTAssertEqual(revokedWrite.status, .rejected)
        XCTAssertEqual(fake.calls, baseline)

        let revokedRenewal = try await route(
            harness.control,
            command("terminal.renew-control", ["leaseId": .string(leaseID)]),
            deviceID: "device-first",
            connectionID: "connection-first",
            isAuthorized: { authorization.value }
        )
        XCTAssertEqual(revokedRenewal.status, .rejected)
        XCTAssertEqual(fake.calls, baseline)

        let revokedAcquire = try await route(
            harness.control,
            command("terminal.acquire-control"),
            deviceID: "device-second",
            connectionID: "connection-second",
            terminal: terminal,
            isAuthorized: { false }
        )
        XCTAssertEqual(revokedAcquire.status, .rejected)
        XCTAssertEqual(fake.calls, baseline)
        await harness.control.dispose()
    }

    private struct Harness {
        let control: CompanionTerminalControl
        let setNow: (Int64) -> Void
        let statuses: () -> [[CompanionTerminalControlStatus]]
    }

    private func makeControl(fake: FakeAdapter) -> Harness {
        final class Clock { var value: Int64 = 10_000 }
        final class StatusHistory { var values: [[CompanionTerminalControlStatus]] = [] }
        let clock = Clock()
        let statusHistory = StatusHistory()
        var counter = 0
        let control = CompanionTerminalControl(
            adapter: fake.adapter(),
            now: { clock.value },
            makeID: {
                counter += 1
                return "00000000-0000-4000-8000-\(String(counter).leftPadded(to: 12, with: "0"))"
            },
            sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onLeaseChange: { statusHistory.values.append($0) }
        )
        return Harness(
            control: control,
            setNow: { clock.value = $0 },
            statuses: { statusHistory.values }
        )
    }

    private var terminal: BrokerTerminalRecord {
        BrokerTerminalRecord(
            id: "terminal-codex",
            projectID: "project-kaisola",
            pid: 123,
            exited: false,
            streamEpoch: "stream-1",
            endOffset: 0,
            columns: 120,
            rows: 42
        )
    }

    private func command(
        _ type: String,
        _ payload: [String: JSONValue]? = nil
    ) -> CompanionCommandBody {
        CompanionCommandBody(
            type: type,
            commandId: "command-\(UUID().uuidString.lowercased())",
            projectId: "project-kaisola",
            targetId: "terminal-codex",
            capability: .terminalControl,
            expectedRevision: nil,
            payload: payload
        )
    }

    private func route(
        _ control: CompanionTerminalControl,
        _ command: CompanionCommandBody,
        deviceID: String,
        connectionID: String,
        terminal: BrokerTerminalRecord? = nil,
        isAuthorized: @escaping @MainActor () -> Bool = { true }
    ) async throws -> CompanionReceiptBody {
        let result = await control.route(
            command: command,
            deviceID: deviceID,
            connectionID: connectionID,
            terminal: terminal,
            isAuthorized: isAuthorized
        )
        return try XCTUnwrap(result)
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        String(repeating: String(character), count: max(0, length - count)) + self
    }
}
