import Foundation
import KaisolaCore

struct CompanionTerminalGeometry: Equatable, Sendable {
    let columns: Int
    let rows: Int

    init?(columns: Int?, rows: Int?) {
        guard let columns, columns > 0, let rows, rows > 0 else { return nil }
        self.columns = columns
        self.rows = rows
    }
}

struct CompanionTerminalControlAvailability: Equatable, Sendable {
    let geometry: CompanionTerminalGeometry?
}

struct CompanionTerminalControlStatus: Equatable, Identifiable, Sendable {
    let projectID: String
    let terminalID: String
    let deviceID: String
    let connectionID: String
    let expiresAt: Int64

    var id: String { "\(projectID)\u{0}\(terminalID)" }
}

enum CompanionTerminalControlAdapterError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? {
        "The desktop no longer owns this terminal."
    }
}

/// The intentionally tiny bridge from a phone lease to the main-owned AppModel
/// controller. There is no attach, create, kill, release, detach, or broker
/// lifecycle operation here, so Companion cannot widen itself into those
/// authorities through a routing mistake.
@MainActor
struct CompanionTerminalControlAdapter {
    let availability: (BrokerTerminalRecord) -> CompanionTerminalControlAvailability?
    let write: (BrokerTerminalRecord, String) async throws -> Void
    let resize: (BrokerTerminalRecord, CompanionTerminalGeometry) async throws -> Void
    let interrupt: (BrokerTerminalRecord) async throws -> Void
    let controlStateChanged: (BrokerTerminalRecord, Bool) async throws -> Void

    init(
        availability: @escaping (BrokerTerminalRecord) -> CompanionTerminalControlAvailability?,
        write: @escaping (BrokerTerminalRecord, String) async throws -> Void,
        resize: @escaping (BrokerTerminalRecord, CompanionTerminalGeometry) async throws -> Void,
        interrupt: @escaping (BrokerTerminalRecord) async throws -> Void,
        controlStateChanged: @escaping (BrokerTerminalRecord, Bool) async throws -> Void = { _, _ in }
    ) {
        self.availability = availability
        self.write = write
        self.resize = resize
        self.interrupt = interrupt
        self.controlStateChanged = controlStateChanged
    }
}

/// One exclusive, short-lived authorization per PTY. The broker's existing
/// ownership check remains the final mutation boundary; this layer adds device
/// + authenticated-connection + lease-generation checks before every call.
@MainActor
final class CompanionTerminalControl {
    static let leaseTTLMilliseconds: Int64 = 30_000
    static let maximumInputBytes = 16 * 1_024
    static let minimumColumns = 20
    static let maximumColumns = 400
    static let minimumRows = 5
    static let maximumRows = 200

    private struct Key: Hashable {
        let projectID: String
        let terminalID: String
    }

    private struct Lease {
        let key: Key
        let leaseID: String
        let deviceID: String
        let connectionID: String
        let terminal: BrokerTerminalRecord
        let originalGeometry: CompanionTerminalGeometry?
        var expiresAt: Int64
    }

    private struct Restoration {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let adapter: CompanionTerminalControlAdapter
    private let ttlMilliseconds: Int64
    private let now: () -> Int64
    private let makeID: () -> String
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let onLeaseChange: ([CompanionTerminalControlStatus]) -> Void
    private var leases: [Key: Lease] = [:]
    private var expiryTasks: [Key: Task<Void, Never>] = [:]
    private var restorations: [Key: Restoration] = [:]

    init(
        adapter: CompanionTerminalControlAdapter,
        ttlMilliseconds: Int64 = CompanionTerminalControl.leaseTTLMilliseconds,
        now: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        makeID: @escaping () -> String = {
            UUID().uuidString.lowercased()
        },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        onLeaseChange: @escaping ([CompanionTerminalControlStatus]) -> Void = { _ in }
    ) {
        precondition((1_000...(5 * 60_000)).contains(ttlMilliseconds))
        self.adapter = adapter
        self.ttlMilliseconds = ttlMilliseconds
        self.now = now
        self.makeID = makeID
        self.sleep = sleep
        self.onLeaseChange = onLeaseChange
    }

    func route(
        command: CompanionCommandBody,
        deviceID: String,
        connectionID: String,
        terminal: BrokerTerminalRecord?
    ) async -> CompanionReceiptBody? {
        switch command.type {
        case "terminal.acquire-control":
            return await acquire(
                command: command,
                deviceID: deviceID,
                connectionID: connectionID,
                terminal: terminal
            )
        case "terminal.renew-control":
            return await renew(command: command, deviceID: deviceID, connectionID: connectionID)
        case "terminal.write":
            return await write(command: command, deviceID: deviceID, connectionID: connectionID)
        case "terminal.resize":
            return await resize(command: command, deviceID: deviceID, connectionID: connectionID)
        case "terminal.interrupt":
            return await interrupt(command: command, deviceID: deviceID, connectionID: connectionID)
        case "terminal.release-control":
            return await release(command: command, deviceID: deviceID, connectionID: connectionID)
        default:
            return nil
        }
    }

    @discardableResult
    func releaseConnection(_ connectionID: String) async -> Int {
        let keys = leases.values
            .filter { $0.connectionID == connectionID }
            .map(\.key)
        for key in keys { await drop(key) }
        return keys.count
    }

    func dispose() async {
        for key in Array(leases.keys) { await drop(key) }
        let pending = restorations.values.map(\.task)
        for task in pending { await task.value }
    }

    func reconcileAvailableTerminals(_ terminals: [BrokerTerminalRecord]) async {
        let active = Set(terminals.filter { !$0.exited }.map {
            "\($0.projectID)\u{0}\($0.id)"
        })
        let invalid = leases.values.filter {
            !active.contains("\($0.terminal.projectID)\u{0}\($0.terminal.id)")
                || adapter.availability($0.terminal) == nil
        }.map(\.key)
        for key in invalid { await drop(key) }
    }

    var activeLeaseCount: Int { leases.count }

    private func acquire(
        command: CompanionCommandBody,
        deviceID: String,
        connectionID: String,
        terminal: BrokerTerminalRecord?
    ) async -> CompanionReceiptBody {
        guard !deviceID.isEmpty, !connectionID.isEmpty, let terminal,
              !terminal.exited else {
            return receipt(command, .rejected, "Terminal control request is invalid.")
        }
        let key = Key(projectID: command.projectId, terminalID: command.targetId)
        await expireIfNeeded(key)
        await waitForRestoration(key)
        if let current = leases[key],
           !sameHolder(current, deviceID: deviceID, connectionID: connectionID) {
            return receipt(command, .rejected, "Terminal is already controlled from another device.")
        }
        guard let available = adapter.availability(terminal) else {
            return receipt(command, .unavailable, "That terminal is no longer controllable from this Mac.")
        }

        let isNewLease = leases[key] == nil
        var lease = leases[key] ?? Lease(
            key: key,
            leaseID: "lease-\(makeID())",
            deviceID: deviceID,
            connectionID: connectionID,
            terminal: terminal,
            originalGeometry: available.geometry,
            expiresAt: 0
        )
        if isNewLease {
            do { try await adapter.controlStateChanged(terminal, true) }
            catch {
                return receipt(command, .unavailable, "Terminal control could not be fenced safely.")
            }
        }
        arm(&lease)
        return receipt(
            command,
            .applied,
            "Terminal control enabled.",
            payload: leasePayload(lease)
        )
    }

    private func renew(
        command: CompanionCommandBody,
        deviceID: String,
        connectionID: String
    ) async -> CompanionReceiptBody {
        guard var lease = await requiredLease(
            command,
            deviceID: deviceID,
            connectionID: connectionID
        ) else { return stale(command) }
        do { try await adapter.controlStateChanged(lease.terminal, true) }
        catch { return receipt(command, .unavailable, "Terminal control could not be renewed safely.") }
        arm(&lease)
        return receipt(command, .applied, "Terminal control renewed.", payload: leasePayload(lease))
    }

    private func write(
        command: CompanionCommandBody,
        deviceID: String,
        connectionID: String
    ) async -> CompanionReceiptBody {
        guard let lease = await requiredLease(
            command,
            deviceID: deviceID,
            connectionID: connectionID
        ) else { return stale(command) }
        guard let data = command.payload?["data"]?.stringValue else {
            return receipt(
                command,
                .rejected,
                "Terminal input must be between 1 and \(Self.maximumInputBytes) bytes."
            )
        }
        let byteCount = data.utf8.count
        guard byteCount > 0, byteCount <= Self.maximumInputBytes else {
            return receipt(
                command,
                .rejected,
                "Terminal input must be between 1 and \(Self.maximumInputBytes) bytes."
            )
        }
        do {
            try await adapter.write(lease.terminal, data)
            return receipt(command, .applied, "Terminal input applied.")
        } catch {
            return receipt(command, .unavailable, "Terminal input was not applied.")
        }
    }

    private func resize(
        command: CompanionCommandBody,
        deviceID: String,
        connectionID: String
    ) async -> CompanionReceiptBody {
        guard let lease = await requiredLease(
            command,
            deviceID: deviceID,
            connectionID: connectionID
        ) else { return stale(command) }
        guard lease.originalGeometry != nil else {
            return receipt(
                command,
                .unavailable,
                "Terminal resize is unavailable until the desktop session reconnects."
            )
        }
        guard let columns64 = command.payload?["cols"]?.intValue,
              let rows64 = command.payload?["rows"]?.intValue,
              let columns = Int(exactly: columns64),
              let rows = Int(exactly: rows64),
              (Self.minimumColumns...Self.maximumColumns).contains(columns),
              (Self.minimumRows...Self.maximumRows).contains(rows),
              let geometry = CompanionTerminalGeometry(columns: columns, rows: rows) else {
            return receipt(command, .rejected, "Terminal size is outside the supported range.")
        }
        do {
            try await adapter.resize(lease.terminal, geometry)
            return receipt(command, .applied, "Terminal size applied.")
        } catch {
            return receipt(command, .unavailable, "Terminal resize was not applied.")
        }
    }

    private func interrupt(
        command: CompanionCommandBody,
        deviceID: String,
        connectionID: String
    ) async -> CompanionReceiptBody {
        guard let lease = await requiredLease(
            command,
            deviceID: deviceID,
            connectionID: connectionID
        ) else { return stale(command) }
        do {
            try await adapter.interrupt(lease.terminal)
            return receipt(command, .applied, "Interrupt sent.")
        } catch {
            return receipt(command, .unavailable, "Interrupt was not applied.")
        }
    }

    private func release(
        command: CompanionCommandBody,
        deviceID: String,
        connectionID: String
    ) async -> CompanionReceiptBody {
        guard let lease = await requiredLease(
            command,
            deviceID: deviceID,
            connectionID: connectionID
        ) else { return stale(command) }
        await drop(lease.key)
        return receipt(command, .applied, "Terminal control released.")
    }

    private func requiredLease(
        _ command: CompanionCommandBody,
        deviceID: String,
        connectionID: String
    ) async -> Lease? {
        guard !deviceID.isEmpty, !connectionID.isEmpty else { return nil }
        let key = Key(projectID: command.projectId, terminalID: command.targetId)
        await expireIfNeeded(key)
        guard let lease = leases[key],
              command.payload?["leaseId"]?.stringValue == lease.leaseID,
              sameHolder(lease, deviceID: deviceID, connectionID: connectionID) else {
            return nil
        }
        return lease
    }

    private func sameHolder(_ lease: Lease, deviceID: String, connectionID: String) -> Bool {
        lease.deviceID == deviceID && lease.connectionID == connectionID
    }

    private func arm(_ lease: inout Lease) {
        lease.expiresAt = now() + ttlMilliseconds
        leases[lease.key] = lease
        publishLeaseState()
        expiryTasks.removeValue(forKey: lease.key)?.cancel()
        let key = lease.key
        let expectedLeaseID = lease.leaseID
        let expectedExpiry = lease.expiresAt
        let delay = UInt64(ttlMilliseconds + 5) * 1_000_000
        expiryTasks[key] = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self,
                  self.leases[key]?.leaseID == expectedLeaseID,
                  self.leases[key]?.expiresAt == expectedExpiry else { return }
            await self.expireIfNeeded(key)
        }
    }

    private func expireIfNeeded(_ key: Key) async {
        guard let lease = leases[key], lease.expiresAt <= now() else { return }
        await drop(key)
    }

    private func drop(_ key: Key) async {
        guard let lease = leases.removeValue(forKey: key) else {
            await waitForRestoration(key)
            return
        }
        publishLeaseState()
        expiryTasks.removeValue(forKey: key)?.cancel()
        guard let geometry = lease.originalGeometry else {
            try? await adapter.controlStateChanged(lease.terminal, false)
            return
        }
        let token = UUID()
        let adapter = self.adapter
        let task = Task { @MainActor in
            _ = try? await adapter.resize(lease.terminal, geometry)
        }
        restorations[key] = Restoration(token: token, task: task)
        await task.value
        if restorations[key]?.token == token { restorations.removeValue(forKey: key) }
        try? await adapter.controlStateChanged(lease.terminal, false)
    }

    private func waitForRestoration(_ key: Key) async {
        await restorations[key]?.task.value
    }

    private func leasePayload(_ lease: Lease) -> [String: JSONValue] {
        [
            "leaseId": .string(lease.leaseID),
            "expiresAt": .integer(lease.expiresAt),
            "renewAfterMs": .integer(ttlMilliseconds / 3),
            "resizeEnabled": .bool(lease.originalGeometry != nil),
        ]
    }

    private func publishLeaseState() {
        onLeaseChange(leases.values.map { lease in
            CompanionTerminalControlStatus(
                projectID: lease.key.projectID,
                terminalID: lease.key.terminalID,
                deviceID: lease.deviceID,
                connectionID: lease.connectionID,
                expiresAt: lease.expiresAt
            )
        }.sorted { lhs, rhs in
            if lhs.projectID != rhs.projectID { return lhs.projectID < rhs.projectID }
            return lhs.terminalID < rhs.terminalID
        })
    }

    private func stale(_ command: CompanionCommandBody) -> CompanionReceiptBody {
        receipt(command, .stale, "Terminal control lease is missing or expired.")
    }

    private func receipt(
        _ command: CompanionCommandBody,
        _ status: CompanionReceiptStatus,
        _ message: String,
        payload: [String: JSONValue]? = nil
    ) -> CompanionReceiptBody {
        CompanionReceiptBody(
            type: "command.receipt",
            commandId: command.commandId,
            status: status,
            message: String(message.prefix(800)),
            payload: payload
        )
    }
}
