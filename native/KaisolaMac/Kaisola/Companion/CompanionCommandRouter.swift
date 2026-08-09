import Foundation
import KaisolaCore

/// Main-owned, bounded at-most-once routing for authenticated phone commands.
/// The connection actor has already enforced negotiated capability; this layer
/// enforces exact projection membership and command-specific state.
@MainActor
final class CompanionCommandRouter {
    static let maximumCachedCommands = 2_048

    private struct Cached {
        let fingerprint: Data
        let receipt: CompanionReceiptBody
    }

    private struct Pending {
        let id: UUID
        let generation: UInt64
        let fingerprint: Data
        let task: Task<CompanionReceiptBody, Never>
    }

    private var cache: [String: Cached] = [:]
    private var cacheOrder: [String] = []
    private var pending: [String: Pending] = [:]
    private var authorityGenerations: [String: UInt64] = [:]

    func route(
        _ envelope: CompanionEnvelope,
        device: CompanionPairedDeviceRecord,
        projection: CompanionProjection?,
        isAuthorized: @escaping @MainActor () -> Bool = { true },
        acknowledgeAttention: @escaping @MainActor (String) -> Bool,
        handleExternal: (@MainActor (CompanionCommandBody) async -> CompanionReceiptBody?)? = nil
    ) async throws -> CompanionReceiptBody {
        guard envelope.kind == .command else {
            throw CompanionProtocolError.invalidBody("command router")
        }
        let command = try envelope.body.decode(CompanionCommandBody.self)
        guard isAuthorized() else { return revokedReceipt(command) }
        let fingerprint = try CanonicalJSON.data(from: .object(envelope.body.fields))
        let cacheKey = "\(device.deviceId)\u{0}\(command.commandId)"
        let generation = authorityGenerations[device.deviceId, default: 0]
        if let prior = cache[cacheKey] {
            guard prior.fingerprint == fingerprint else {
                return receipt(
                    command,
                    status: .rejected,
                    message: "This command identifier was reused with different content."
                )
            }
            return prior.receipt
        }
        if let inFlight = pending[cacheKey] {
            guard inFlight.generation == generation else { return revokedReceipt(command) }
            guard inFlight.fingerprint == fingerprint else {
                return receipt(
                    command,
                    status: .rejected,
                    message: "This command identifier was reused with different content."
                )
            }
            return await inFlight.task.value
        }

        let pendingID = UUID()
        let task = Task { @MainActor [projection] in
            guard !Task.isCancelled,
                  self.authorityGenerations[device.deviceId, default: 0] == generation,
                  isAuthorized() else { return self.revokedReceipt(command) }
            switch command.type {
            case "attention.ack":
                guard isAuthorized() else { return self.revokedReceipt(command) }
                return self.acknowledge(command, projection: projection, apply: acknowledgeAttention)
            case "stream.subscribe", "stream.unsubscribe",
                 "terminal.acquire-control", "terminal.renew-control",
                 "terminal.write", "terminal.resize", "terminal.interrupt",
                 "terminal.release-control":
                if let external = await handleExternal?(command) { return external }
                return self.receipt(
                    command,
                    status: .unavailable,
                    message: "That Companion operation is not enabled in this build."
                )
            default:
                return self.receipt(
                    command,
                    status: .unavailable,
                    message: "\(command.type) is not available in this Companion build."
                )
            }
        }
        pending[cacheKey] = Pending(
            id: pendingID,
            generation: generation,
            fingerprint: fingerprint,
            task: task
        )
        let result = await task.value
        if pending[cacheKey]?.id == pendingID { pending.removeValue(forKey: cacheKey) }
        guard authorityGenerations[device.deviceId, default: 0] == generation,
              isAuthorized() else { return revokedReceipt(command) }
        remember(result, fingerprint: fingerprint, key: cacheKey)
        return result
    }

    /// Cancel queued work and erase at-most-once receipts at the same
    /// synchronous authority boundary used to close the device's transports.
    func revoke(deviceID: String) {
        authorityGenerations[deviceID, default: 0] &+= 1
        let prefix = "\(deviceID)\u{0}"
        for key in pending.keys.filter({ $0.hasPrefix(prefix) }) {
            pending.removeValue(forKey: key)?.task.cancel()
        }
        for key in cache.keys.filter({ $0.hasPrefix(prefix) }) { cache.removeValue(forKey: key) }
        cacheOrder.removeAll { $0.hasPrefix(prefix) }
    }

    private func acknowledge(
        _ command: CompanionCommandBody,
        projection: CompanionProjection?,
        apply: (String) -> Bool
    ) -> CompanionReceiptBody {
        guard let projection else {
            return receipt(command, status: .unavailable, message: "Desktop state is not ready yet.")
        }
        if let expected = command.expectedRevision,
           expected != Int64(projection.revision) {
            return receipt(
                command,
                status: .stale,
                message: "Desktop state changed. Refresh and try again.",
                payload: ["currentRevision": .integer(Int64(projection.revision))]
            )
        }
        guard let attention = projection.attention.first(where: {
            $0.id == command.targetId && $0.projectId == command.projectId
        }), let sessionID = attention.sessionId else {
            return receipt(
                command,
                status: .rejected,
                message: "That attention item is no longer active in this project."
            )
        }
        guard apply(sessionID) else {
            return receipt(
                command,
                status: .rejected,
                message: "That attention item was already cleared."
            )
        }
        return receipt(command, status: .applied, message: "Attention cleared on the Mac.")
    }

    private func receipt(
        _ command: CompanionCommandBody,
        status: CompanionReceiptStatus,
        message: String,
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

    private func revokedReceipt(_ command: CompanionCommandBody) -> CompanionReceiptBody {
        receipt(
            command,
            status: .rejected,
            message: "This Companion device is no longer authorized."
        )
    }

    private func remember(_ receipt: CompanionReceiptBody, fingerprint: Data, key: String) {
        cache[key] = Cached(fingerprint: fingerprint, receipt: receipt)
        cacheOrder.append(key)
        if cacheOrder.count > Self.maximumCachedCommands {
            let overflow = cacheOrder.count - Self.maximumCachedCommands
            for old in cacheOrder.prefix(overflow) { cache.removeValue(forKey: old) }
            cacheOrder.removeFirst(overflow)
        }
    }
}
