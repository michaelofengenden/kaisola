import Darwin
import Foundation
import KaisolaCore

struct CompanionPairedDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String { deviceId }
    let deviceId: String
    var displayName: String
    let identityPublic: String
    let x25519StaticPublic: String
    var capabilities: [CompanionCapability]
    let pairedAt: Int64
    var lastSeenAt: Int64

    var pin: CompanionIdentityPin {
        CompanionIdentityPin(
            id: deviceId,
            identityPublic: identityPublic,
            x25519StaticPublic: x25519StaticPublic
        )
    }
}

struct CompanionRevokedDeviceRecord: Codable, Equatable, Sendable {
    let deviceId: String
    let identityPublic: String
    let x25519StaticPublic: String
    let revokedAt: Int64

    var pin: CompanionIdentityPin {
        CompanionIdentityPin(
            id: deviceId,
            identityPublic: identityPublic,
            x25519StaticPublic: x25519StaticPublic
        )
    }
}

enum CompanionDeviceRosterError: LocalizedError, Equatable {
    case invalidStore
    case unsafePath
    case tooLarge
    case deviceLimit
    case duplicateDevice
    case unknownDevice

    var errorDescription: String? {
        switch self {
        case .invalidStore: "Kaisola's paired-device roster is invalid."
        case .unsafePath: "Kaisola refused an unsafe paired-device roster path."
        case .tooLarge: "Kaisola's paired-device roster exceeds its size limit."
        case .deviceLimit: "Kaisola supports at most 64 paired devices."
        case .duplicateDevice: "This device is already paired."
        case .unknownDevice: "This device is no longer paired."
        }
    }
}

actor CompanionDeviceRosterStore {
    private struct Archive: Codable {
        let version: Int
        let devices: [CompanionPairedDeviceRecord]
        let revoked: [CompanionRevokedDeviceRecord]?
    }

    static let maximumStoreBytes = 1 * 1_024 * 1_024
    static let maximumDevices = 64
    static let maximumRevokedDevices = 256

    private let fileURL: URL
    private var devicesByID: [String: CompanionPairedDeviceRecord]
    private var revokedByID: [String: CompanionRevokedDeviceRecord]

    init(fileURL: URL = NativePreviewPaths.companionDevices) throws {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else {
            throw CompanionDeviceRosterError.unsafePath
        }
        self.fileURL = fileURL.standardizedFileURL
        let archive = try Self.load(from: self.fileURL)
        var indexed: [String: CompanionPairedDeviceRecord] = [:]
        for record in archive.devices {
            guard indexed.updateValue(record, forKey: record.deviceId) == nil else {
                throw CompanionDeviceRosterError.invalidStore
            }
        }
        var revoked: [String: CompanionRevokedDeviceRecord] = [:]
        for record in archive.revoked {
            guard indexed[record.deviceId] == nil,
                  revoked.updateValue(record, forKey: record.deviceId) == nil else {
                throw CompanionDeviceRosterError.invalidStore
            }
        }
        devicesByID = indexed
        revokedByID = revoked
    }

    func list() -> [CompanionPairedDeviceRecord] {
        devicesByID.values.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.deviceId < $1.deviceId : order == .orderedAscending
        }
    }

    func device(_ id: String) -> CompanionPairedDeviceRecord? {
        devicesByID[id]
    }

    func revokedDevice(_ id: String) -> CompanionRevokedDeviceRecord? {
        revokedByID[id]
    }

    @discardableResult
    func pair(
        peer: CompanionIdentityPin,
        displayName: String,
        capabilities: [CompanionCapability],
        now: Int64
    ) throws -> CompanionPairedDeviceRecord {
        guard devicesByID[peer.id] == nil else { throw CompanionDeviceRosterError.duplicateDevice }
        guard devicesByID.count < Self.maximumDevices else { throw CompanionDeviceRosterError.deviceLimit }
        let record = try Self.normalizedRecord(
            CompanionPairedDeviceRecord(
                deviceId: peer.id,
                displayName: displayName,
                identityPublic: peer.identityPublic,
                x25519StaticPublic: peer.x25519StaticPublic,
                capabilities: capabilities,
                pairedAt: now,
                lastSeenAt: now
            )
        )
        let priorRevocation = revokedByID.removeValue(forKey: record.deviceId)
        devicesByID[record.deviceId] = record
        do { try persist() }
        catch {
            devicesByID.removeValue(forKey: record.deviceId)
            if let priorRevocation { revokedByID[record.deviceId] = priorRevocation }
            throw error
        }
        return record
    }

    func markSeen(_ id: String, now: Int64) throws {
        guard var record = devicesByID[id] else { throw CompanionDeviceRosterError.unknownDevice }
        let previous = record
        record.lastSeenAt = max(record.lastSeenAt, now)
        devicesByID[id] = record
        do { try persist() }
        catch { devicesByID[id] = previous; throw error }
    }

    @discardableResult
    func updateCapabilities(
        _ capabilities: [CompanionCapability],
        for id: String
    ) throws -> CompanionPairedDeviceRecord {
        guard var record = devicesByID[id] else {
            throw CompanionDeviceRosterError.unknownDevice
        }
        let previous = record
        record.capabilities = capabilities
        record = try Self.normalizedRecord(record)
        devicesByID[id] = record
        do { try persist() }
        catch {
            devicesByID[id] = previous
            throw error
        }
        return record
    }

    /// Resume authorization and last-seen persistence are one actor-isolated
    /// operation. A revocation cannot slip between a successful markSeen and a
    /// second lookup that falls back to a stale in-memory handshake record.
    func authorizeResume(
        deviceID: String,
        expectedPin: CompanionIdentityPin,
        now: Int64
    ) throws -> CompanionPairedDeviceRecord {
        guard var record = devicesByID[deviceID], record.pin == expectedPin else {
            throw CompanionDeviceRosterError.unknownDevice
        }
        let previous = record
        record.lastSeenAt = max(record.lastSeenAt, now)
        devicesByID[deviceID] = record
        do { try persist() }
        catch {
            devicesByID[deviceID] = previous
            throw error
        }
        return record
    }

    @discardableResult
    func revoke(
        _ id: String,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> Bool {
        guard let previous = devicesByID.removeValue(forKey: id) else { return false }
        let previousRevocations = revokedByID
        revokedByID[id] = CompanionRevokedDeviceRecord(
            deviceId: previous.deviceId,
            identityPublic: previous.identityPublic,
            x25519StaticPublic: previous.x25519StaticPublic,
            revokedAt: max(0, now)
        )
        pruneRevocations(preserving: id)
        do { try persist() }
        catch {
            devicesByID[id] = previous
            revokedByID = previousRevocations
            throw error
        }
        return true
    }

    private static func load(
        from url: URL
    ) throws -> (devices: [CompanionPairedDeviceRecord], revoked: [CompanionRevokedDeviceRecord]) {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            guard errno == ENOENT else { throw CompanionDeviceRosterError.unsafePath }
            return ([], [])
        }
        guard metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0,
              metadata.st_size <= Int64(maximumStoreBytes) else {
            throw CompanionDeviceRosterError.unsafePath
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumStoreBytes,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              (archive.version == 1 && archive.revoked == nil)
                || (archive.version == 2 && archive.revoked != nil),
              archive.devices.count <= maximumDevices,
              (archive.revoked?.count ?? 0) <= maximumRevokedDevices else {
            throw CompanionDeviceRosterError.invalidStore
        }
        do {
            return (
                try archive.devices.map(normalizedRecord),
                try (archive.revoked ?? []).map(normalizedRevocation)
            )
        }
        catch { throw CompanionDeviceRosterError.invalidStore }
    }

    private static func normalizedRecord(
        _ record: CompanionPairedDeviceRecord
    ) throws -> CompanionPairedDeviceRecord {
        _ = try CompanionCrypto.validateIdentifier(record.deviceId, label: "deviceId")
        _ = try CompanionCrypto.decodeBase64URL(
            record.identityPublic, bytes: 32, label: "identityPublic"
        )
        _ = try CompanionCrypto.decodeBase64URL(
            record.x25519StaticPublic, bytes: 32, label: "x25519StaticPublic"
        )
        let name = record.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              record.pairedAt >= 0,
              record.lastSeenAt >= record.pairedAt,
              !record.capabilities.isEmpty,
              record.capabilities.count <= CompanionCapability.allCases.count,
              Set(record.capabilities).count == record.capabilities.count,
              record.capabilities.contains(.observe) else {
            throw CompanionDeviceRosterError.invalidStore
        }
        let ordered = CompanionCapability.allCases.filter(record.capabilities.contains)
        return CompanionPairedDeviceRecord(
            deviceId: record.deviceId,
            displayName: name,
            identityPublic: record.identityPublic,
            x25519StaticPublic: record.x25519StaticPublic,
            capabilities: ordered,
            pairedAt: record.pairedAt,
            lastSeenAt: record.lastSeenAt
        )
    }

    private static func normalizedRevocation(
        _ record: CompanionRevokedDeviceRecord
    ) throws -> CompanionRevokedDeviceRecord {
        _ = try CompanionCrypto.validateIdentifier(record.deviceId, label: "deviceId")
        _ = try CompanionCrypto.decodeBase64URL(
            record.identityPublic, bytes: 32, label: "identityPublic"
        )
        _ = try CompanionCrypto.decodeBase64URL(
            record.x25519StaticPublic, bytes: 32, label: "x25519StaticPublic"
        )
        guard record.revokedAt >= 0 else { throw CompanionDeviceRosterError.invalidStore }
        return record
    }

    private func pruneRevocations(preserving deviceID: String) {
        guard revokedByID.count > Self.maximumRevokedDevices else { return }
        let overflow = revokedByID.values
            .filter { $0.deviceId != deviceID }
            .sorted {
                $0.revokedAt == $1.revokedAt
                    ? $0.deviceId < $1.deviceId
                    : $0.revokedAt < $1.revokedAt
            }
            .prefix(revokedByID.count - Self.maximumRevokedDevices)
        for record in overflow { revokedByID.removeValue(forKey: record.deviceId) }
    }

    private func persist() throws {
        let records = devicesByID.values.sorted { $0.deviceId < $1.deviceId }
        let revoked = revokedByID.values.sorted { $0.deviceId < $1.deviceId }
        let data = try JSONEncoder().encode(Archive(version: 2, devices: records, revoked: revoked))
        guard data.count <= Self.maximumStoreBytes else { throw CompanionDeviceRosterError.tooLarge }
        let directory = fileURL.deletingLastPathComponent()
        try NativePreviewPaths.prepareCompanionDirectory(at: directory)
        let temporary = directory.appendingPathComponent(
            ".devices-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            _ = chmod(temporary.path, 0o600)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            _ = chmod(fileURL.path, 0o600)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
