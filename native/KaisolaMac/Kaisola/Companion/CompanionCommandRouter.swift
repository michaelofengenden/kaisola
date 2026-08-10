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
        let hostGeneration: UInt64
        let generation: UInt64
        let capabilityGeneration: UInt64
        let fingerprint: Data
        let denial: CompanionReceiptBody
        let task: Task<CompanionReceiptBody, Never>
    }

    private var cache: [String: Cached] = [:]
    private var cacheOrder: [String] = []
    private var pending: [String: Pending] = [:]
    private var authorityGenerations: [String: UInt64] = [:]
    private var hostGeneration: UInt64 = 0

    func route(
        _ envelope: CompanionEnvelope,
        device: CompanionPairedDeviceRecord,
        effectiveCapabilities: Set<CompanionCapability>? = nil,
        authorityGeneration: UInt64 = 0,
        authorityIsCurrent: @escaping @MainActor () -> Bool = { true },
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
        let granted = effectiveCapabilities ?? Set(device.capabilities)
        guard authorityIsCurrent(), CompanionCapabilityPolicy.allowsCommand(
            type: command.type,
            claimedCapability: command.capability,
            grantedCapabilities: granted
        ) else {
            return authorityDenied(command)
        }
        let fingerprint = try CanonicalJSON.data(from: .object(envelope.body.fields))
        // Capability generations fence whether work may execute, but command
        // identity remains device-scoped. Reusing a command after a downgrade
        // must not repeat a side effect that may already have reached an actor.
        let cacheKey = "\(device.deviceId)\u{0}\(command.commandId)"
        let currentHostGeneration = hostGeneration
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
            guard inFlight.hostGeneration == currentHostGeneration,
                  inFlight.generation == generation,
                  isAuthorized() else {
                return revokedReceipt(command)
            }
            guard inFlight.capabilityGeneration == authorityGeneration,
                  authorityIsCurrent() else {
                return authorityDenied(command)
            }
            guard inFlight.fingerprint == fingerprint else {
                return receipt(
                    command,
                    status: .rejected,
                    message: "This command identifier was reused with different content."
                )
            }
            let result = await inFlight.task.value
            guard hostGeneration == currentHostGeneration,
                  isAuthorized(),
                  generation == authorityGenerations[device.deviceId, default: 0] else {
                return revokedReceipt(command)
            }
            guard authorityIsCurrent(), !Task.isCancelled else {
                return authorityDenied(command)
            }
            return result
        }

        let pendingID = UUID()
        let task = Task { @MainActor [projection] in
            guard !Task.isCancelled,
                  self.hostGeneration == currentHostGeneration,
                  self.authorityGenerations[device.deviceId, default: 0] == generation,
                  isAuthorized() else { return self.revokedReceipt(command) }
            guard authorityIsCurrent() else { return self.authorityDenied(command) }
            let result: CompanionReceiptBody
            switch command.type {
            case "attention.ack":
                result = self.acknowledge(
                    command,
                    projection: projection,
                    apply: acknowledgeAttention
                )
            case "stream.subscribe", "stream.unsubscribe",
                 "terminal.acquire-control", "terminal.renew-control",
                 "terminal.write", "terminal.resize", "terminal.interrupt",
                 "terminal.release-control":
                if let external = await handleExternal?(command) {
                    result = external
                } else {
                    result = self.receipt(
                        command,
                        status: .unavailable,
                        message: "That Companion operation is not enabled in this build."
                    )
                }
            default:
                result = self.receipt(
                    command,
                    status: .unavailable,
                    message: "\(command.type) is not available in this Companion build."
                )
            }
            guard self.hostGeneration == currentHostGeneration,
                  isAuthorized(),
                  self.authorityGenerations[device.deviceId, default: 0] == generation else {
                return self.revokedReceipt(command)
            }
            guard authorityIsCurrent(), !Task.isCancelled else {
                return self.authorityDenied(command)
            }
            return result
        }
        pending[cacheKey] = Pending(
            id: pendingID,
            hostGeneration: currentHostGeneration,
            generation: generation,
            capabilityGeneration: authorityGeneration,
            fingerprint: fingerprint,
            denial: authorityDenied(command),
            task: task
        )
        let result = await task.value
        if pending[cacheKey]?.id == pendingID { pending.removeValue(forKey: cacheKey) }
        guard hostGeneration == currentHostGeneration,
              authorityGenerations[device.deviceId, default: 0] == generation,
              isAuthorized() else { return revokedReceipt(command) }
        guard authorityIsCurrent(), !Task.isCancelled else {
            return authorityDenied(command)
        }
        remember(result, fingerprint: fingerprint, key: cacheKey)
        return result
    }

    /// Capability downgrades seal in-flight identifiers because the external
    /// actor may already have applied their side effects. Regranting authority
    /// must not execute the same device-scoped command again.
    func invalidate(deviceID: String) {
        let prefix = "\(deviceID)\u{0}"
        for key in Array(pending.keys) where key.hasPrefix(prefix) {
            guard let retiring = pending.removeValue(forKey: key) else { continue }
            // Seal the identifier before cancellation. The external actor may
            // already have applied the operation even though its late receipt
            // is suppressed, so a future grant cannot safely run it again.
            remember(retiring.denial, fingerprint: retiring.fingerprint, key: key)
            retiring.task.cancel()
        }
    }

    private func authorityDenied(_ command: CompanionCommandBody) -> CompanionReceiptBody {
        receipt(
            command,
            status: .rejected,
            message: "This device's Companion access changed. Refresh and try again."
        )
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

    /// Cross-account host transitions are a global authority boundary. Clear
    /// every cached receipt and cancel every queued route before the old
    /// transports are closed so an account-A result cannot be observed or
    /// reused by a later account-B host with the same device/command IDs.
    func invalidateAll() {
        hostGeneration &+= 1
        for work in pending.values { work.task.cancel() }
        pending.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        authorityGenerations.removeAll()
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
