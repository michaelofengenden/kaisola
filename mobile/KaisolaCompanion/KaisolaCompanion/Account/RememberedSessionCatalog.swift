import CryptoKit
import Combine
import Foundation

enum RememberedSessionKind: String, Codable, Sendable {
    case terminal
    case agentChat = "agent-chat"
    case mesh
}

enum RememberedSessionActivity: String, Codable, Sendable {
    case idle
    case working
    case needsAttention = "needs-attention"
    case ended
}

enum RememberedSessionResumeKind: String, Codable, Sendable {
    case livePTY = "live-pty"
    case providerSession = "provider-session"
    case metadataOnly = "metadata-only"
}

struct RememberedSessionDraft: Equatable, Sendable {
    let id: String
    let projectID: String
    let projectName: String
    let title: String
    let kind: RememberedSessionKind
    let agentID: String?
    let activity: RememberedSessionActivity
    let resumeKind: RememberedSessionResumeKind
    let createdAt: Int64?
    let lastActivityAt: Int64?
    let hasLocalTranscript: Bool
}

struct RememberedSessionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let projectId: String
    let projectName: String
    let title: String
    let kind: RememberedSessionKind
    let agentId: String?
    let activity: RememberedSessionActivity
    let resumeKind: RememberedSessionResumeKind
    let createdAt: Int64
    let lastActivityAt: Int64
    let hasLocalTranscript: Bool
}

struct RememberedDeviceCatalog: Codable, Equatable, Identifiable, Sendable {
    enum Presence: String, Codable, Sendable {
        case online
        case offline
    }

    var id: String { deviceId }
    let deviceId: String
    let deviceName: String
    let revision: Int
    let updatedAt: Int64
    let presence: Presence
    let sessions: [RememberedSessionRecord]
}

enum RememberedSessionCatalogEndpoint {
    static func derive(from sessionURL: URL) -> URL? {
        guard sessionURL.scheme?.lowercased() == "https",
              sessionURL.host?.isEmpty == false,
              sessionURL.user == nil,
              sessionURL.password == nil,
              var components = URLComponents(url: sessionURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var segments = components.path.split(separator: "/").map(String.init)
        if segments.last == "session" {
            segments[segments.count - 1] = "sessionCatalog"
        } else {
            segments.append("sessionCatalog")
        }
        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum RememberedSessionCatalogDevice {
    /// Never use the broker owner/capability identity as a cloud identifier.
    /// The account-scoped catalog gets a stable, one-way pseudonym instead.
    static func id(from localOwnerID: String) -> String {
        let digest = SHA256.hash(data: Data("kaisola-session-catalog-v1\0\(localOwnerID)".utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum RememberedSessionCatalogPortable {
    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:@-"
    )

    /// Preserve ordinary local identifiers for diagnostics. If an ID is too
    /// long or contains path/separator/control characters, replace it with a
    /// stable domain-separated digest rather than leaking or truncating it.
    static func id(_ value: String, domain: String, maximumUTF8Bytes: Int) -> String {
        let scalars = value.unicodeScalars
        let isPortable = !value.isEmpty
            && value.utf8.count <= maximumUTF8Bytes
            && scalars.first.map { CharacterSet.alphanumerics.contains($0) } == true
            && scalars.allSatisfy { identifierCharacters.contains($0) }
        if isPortable { return value }
        let digest = SHA256.hash(data: Data("kaisola-catalog-\(domain)-v1\0\(value)".utf8))
        let encoded = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(domain)-\(encoded)"
    }

    /// Catalog labels are deliberately one line and byte-bounded to the exact
    /// server contract. UTF-8 truncation backs up to a complete scalar.
    static func text(_ value: String, maximumUTF8Bytes: Int, fallback: String) -> String {
        let cleaned = String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = cleaned.isEmpty ? fallback : cleaned
        if candidate.utf8.count <= maximumUTF8Bytes { return candidate }
        var bytes = Data(candidate.utf8.prefix(maximumUTF8Bytes))
        while !bytes.isEmpty, String(data: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        let truncated = String(data: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated?.isEmpty == false ? truncated! : fallback
    }
}

enum RememberedSessionCatalogError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidResponse
    case rejected(status: Int, message: String)
    case revisionConflict(current: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Kaisola's remembered-session endpoint is not configured securely."
        case .invalidResponse: "Kaisola's remembered-session service returned an invalid response."
        case let .rejected(_, message): message
        case .revisionConflict: "This device's remembered-session catalog changed remotely."
        }
    }
}

actor RememberedSessionCatalogClient {
    private struct ListRequest: Encodable { let action = "list" }
    private struct ListResponse: Decodable {
        let ok: Bool
        let schema: Int
        let devices: [RememberedDeviceCatalog]
    }
    private struct PublishRequest: Encodable {
        let action = "publish"
        let deviceId: String
        let deviceName: String
        let expectedRevision: Int
        let sessions: [RememberedSessionRecord]
    }
    private struct PublishResponse: Decodable {
        let ok: Bool
        let schema: Int
        let revision: Int
    }
    private struct RemoveRequest: Encodable {
        let action = "remove-device"
        let deviceId: String
    }
    private struct RemoveResponse: Decodable { let ok: Bool }
    private struct ErrorResponse: Decodable {
        let message: String?
        let currentRevision: Int?
    }

    private let endpoint: URL
    private let httpClient: any AuthHTTPClient
    private var cacheAccountID: String?
    private var cacheEpoch: UInt64 = 0
    private var revisions: [String: Int] = [:]
    private var createdAtByDeviceAndSessionID: [String: Int64] = [:]

    init(
        sessionURL: URL,
        httpClient: any AuthHTTPClient = URLSessionAuthHTTPClient()
    ) throws {
        guard let endpoint = RememberedSessionCatalogEndpoint.derive(from: sessionURL) else {
            throw RememberedSessionCatalogError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.httpClient = httpClient
    }

    func deactivate() {
        cacheAccountID = nil
        cacheEpoch &+= 1
        revisions.removeAll(keepingCapacity: false)
        createdAtByDeviceAndSessionID.removeAll(keepingCapacity: false)
    }

    func list(idToken: String, accountID: String) async throws -> [RememberedDeviceCatalog] {
        let epoch = try activate(accountID: accountID)
        let response: ListResponse = try await post(ListRequest(), idToken: idToken)
        try requireActive(accountID: accountID, epoch: epoch)
        guard response.ok, response.schema == 1 else {
            throw RememberedSessionCatalogError.invalidResponse
        }
        for device in response.devices {
            revisions[device.deviceId] = device.revision
            for session in device.sessions {
                createdAtByDeviceAndSessionID[cacheKey(deviceID: device.deviceId, sessionID: session.id)] = session.createdAt
            }
        }
        return response.devices
    }

    @discardableResult
    func publish(
        idToken: String,
        accountID: String,
        deviceID: String,
        deviceName: String,
        drafts: [RememberedSessionDraft],
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async throws -> Int {
        let epoch = try activate(accountID: accountID)
        let normalizedDeviceID = RememberedSessionCatalogPortable.id(
            deviceID, domain: "device", maximumUTF8Bytes: 160
        )
        let normalizedDeviceName = RememberedSessionCatalogPortable.text(
            deviceName, maximumUTF8Bytes: 160, fallback: "Kaisola device"
        )
        if revisions[normalizedDeviceID] == nil {
            _ = try await list(idToken: idToken, accountID: accountID)
            try requireActive(accountID: accountID, epoch: epoch)
        }
        let normalized = drafts.map { draft in
            let sessionID = RememberedSessionCatalogPortable.id(
                draft.id, domain: "session", maximumUTF8Bytes: 240
            )
            let projectID = RememberedSessionCatalogPortable.id(
                draft.projectID, domain: "project", maximumUTF8Bytes: 160
            )
            let cachedCreatedAt = createdAtByDeviceAndSessionID[
                cacheKey(deviceID: normalizedDeviceID, sessionID: sessionID)
            ]
            let createdAt = min(now, max(0, draft.createdAt ?? cachedCreatedAt ?? now))
            let lastActivityAt = min(now, max(createdAt, draft.lastActivityAt ?? createdAt))
            return RememberedSessionRecord(
                id: sessionID,
                projectId: projectID,
                projectName: RememberedSessionCatalogPortable.text(
                    draft.projectName, maximumUTF8Bytes: 240, fallback: "Kaisola project"
                ),
                title: RememberedSessionCatalogPortable.text(
                    draft.title, maximumUTF8Bytes: 320, fallback: "Kaisola session"
                ),
                kind: draft.kind,
                agentId: draft.agentID.map {
                    RememberedSessionCatalogPortable.text(
                        $0, maximumUTF8Bytes: 160, fallback: "agent"
                    )
                },
                activity: draft.activity,
                resumeKind: draft.resumeKind,
                createdAt: createdAt,
                lastActivityAt: lastActivityAt,
                hasLocalTranscript: draft.hasLocalTranscript
            )
        }
        // A device publishes a current snapshot. Keep the 256 most recently
        // active records if a long-lived installation exceeds the server cap,
        // then canonicalize the wire order for deterministic retries.
        var newestByID: [String: RememberedSessionRecord] = [:]
        for session in normalized {
            if let existing = newestByID[session.id],
               existing.lastActivityAt >= session.lastActivityAt {
                continue
            }
            newestByID[session.id] = session
        }
        let recentFirst = newestByID.values.sorted { left, right in
            if left.lastActivityAt != right.lastActivityAt {
                return left.lastActivityAt > right.lastActivityAt
            }
            return left.id < right.id
        }
        let retained = Array(recentFirst.prefix(256))
        let sessions = retained.sorted { left, right in
            if left.lastActivityAt != right.lastActivityAt {
                return left.lastActivityAt < right.lastActivityAt
            }
            return left.id < right.id
        }
        let expected = revisions[normalizedDeviceID] ?? 0
        do {
            return try await publishOnce(
                idToken: idToken,
                accountID: accountID,
                epoch: epoch,
                deviceID: normalizedDeviceID,
                deviceName: normalizedDeviceName,
                expectedRevision: expected,
                sessions: sessions
            )
        } catch RememberedSessionCatalogError.revisionConflict(let current) {
            try requireActive(accountID: accountID, epoch: epoch)
            revisions[normalizedDeviceID] = current
            return try await publishOnce(
                idToken: idToken,
                accountID: accountID,
                epoch: epoch,
                deviceID: normalizedDeviceID,
                deviceName: normalizedDeviceName,
                expectedRevision: current,
                sessions: sessions
            )
        }
    }

    /// Remove only this account's device document. The UID stays in the
    /// bearer token and is never copied into the request body. As with list and
    /// publish, a sign-out/account switch invalidates a suspended response
    /// before it can mutate the replacement account's local cache.
    func removeDevice(
        idToken: String,
        accountID: String,
        deviceID: String
    ) async throws {
        let epoch = try activate(accountID: accountID)
        let normalizedDeviceID = RememberedSessionCatalogPortable.id(
            deviceID, domain: "device", maximumUTF8Bytes: 160
        )
        let response: RemoveResponse = try await post(
            RemoveRequest(deviceId: normalizedDeviceID),
            idToken: idToken
        )
        try requireActive(accountID: accountID, epoch: epoch)
        guard response.ok else {
            throw RememberedSessionCatalogError.invalidResponse
        }
        revisions.removeValue(forKey: normalizedDeviceID)
        let prefix = "\(normalizedDeviceID)\0"
        createdAtByDeviceAndSessionID = createdAtByDeviceAndSessionID.filter {
            !$0.key.hasPrefix(prefix)
        }
    }

    private func publishOnce(
        idToken: String,
        accountID: String,
        epoch: UInt64,
        deviceID: String,
        deviceName: String,
        expectedRevision: Int,
        sessions: [RememberedSessionRecord]
    ) async throws -> Int {
        let response: PublishResponse = try await post(
            PublishRequest(
                deviceId: deviceID,
                deviceName: deviceName,
                expectedRevision: expectedRevision,
                sessions: sessions
            ),
            idToken: idToken
        )
        try requireActive(accountID: accountID, epoch: epoch)
        guard response.ok, response.schema == 1, response.revision == expectedRevision + 1 else {
            throw RememberedSessionCatalogError.invalidResponse
        }
        revisions[deviceID] = response.revision
        for session in sessions {
            createdAtByDeviceAndSessionID[cacheKey(deviceID: deviceID, sessionID: session.id)] = session.createdAt
        }
        return response.revision
    }

    /// The Firebase UID never goes on this request body; it only fences local
    /// revision and creation-time caches. An account transition invalidates
    /// suspended requests before they can mutate or project another account's
    /// metadata.
    private func activate(accountID: String) throws -> UInt64 {
        guard !accountID.isEmpty else {
            throw RememberedSessionCatalogError.invalidResponse
        }
        if cacheAccountID != accountID {
            cacheAccountID = accountID
            cacheEpoch &+= 1
            revisions.removeAll(keepingCapacity: false)
            createdAtByDeviceAndSessionID.removeAll(keepingCapacity: false)
        }
        return cacheEpoch
    }

    private func requireActive(accountID: String, epoch: UInt64) throws {
        guard cacheAccountID == accountID, cacheEpoch == epoch else {
            throw CancellationError()
        }
    }

    private func cacheKey(deviceID: String, sessionID: String) -> String {
        "\(deviceID)\0\(sessionID)"
    }

    private func post<Request: Encodable, Response: Decodable>(
        _ payload: Request,
        idToken: String
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await httpClient.data(for: request)
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw RememberedSessionCatalogError.invalidResponse
        }
        if response.statusCode == 409,
           let conflict = try? JSONDecoder().decode(ErrorResponse.self, from: data),
           let current = conflict.currentRevision,
           current >= 0 {
            throw RememberedSessionCatalogError.revisionConflict(current: current)
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).message)
                ?? "Remembered sessions are temporarily unavailable."
            throw RememberedSessionCatalogError.rejected(
                status: response.statusCode,
                message: message
            )
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RememberedSessionCatalogError.invalidResponse
        }
        return decoded
    }
}

struct RememberedSessionCatalogSnapshot: Codable, Equatable, Sendable {
    let schema: Int
    let savedAt: Int64
    let devices: [RememberedDeviceCatalog]
}

enum RememberedSessionCatalogSnapshotError: Error, Equatable {
    case invalidAccount
    case invalidSnapshot
    case unsafeStorage
}

/// Account-keyed last-known catalog metadata for offline startup. The filename
/// is a domain-separated UID digest and the payload contains only the same
/// bounded portable projection accepted by the cloud client: never a token,
/// UID, cwd, terminal output, prompt, environment, or provider credential.
actor RememberedSessionCatalogSnapshotStore {
    private static let maximumBytes = 2 * 1_024 * 1_024
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    func load(accountID: String) throws -> RememberedSessionCatalogSnapshot? {
        try prepareDirectory()
        let file = try fileURL(accountID: accountID)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        try requireRegularFile(file)
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard data.count <= Self.maximumBytes,
              let snapshot = try? JSONDecoder().decode(
                RememberedSessionCatalogSnapshot.self,
                from: data
              ),
              Self.isValid(snapshot) else {
            throw RememberedSessionCatalogSnapshotError.invalidSnapshot
        }
        return snapshot
    }

    func save(
        accountID: String,
        devices: [RememberedDeviceCatalog],
        savedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws {
        let snapshot = RememberedSessionCatalogSnapshot(
            schema: 1,
            savedAt: savedAt,
            devices: devices
        )
        guard Self.isValid(snapshot) else {
            throw RememberedSessionCatalogSnapshotError.invalidSnapshot
        }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumBytes else {
            throw RememberedSessionCatalogSnapshotError.invalidSnapshot
        }
        try prepareDirectory()
        let file = try fileURL(accountID: accountID)
        if fileManager.fileExists(atPath: file.path) {
            try requireRegularFile(file)
        }
        try data.write(to: file, options: [.atomic])
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try fileManager.setAttributes(attributes, ofItemAtPath: file.path)
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RememberedSessionCatalogSnapshotError.unsafeStorage
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func requireRegularFile(_ file: URL) throws {
        let values = try file.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RememberedSessionCatalogSnapshotError.unsafeStorage
        }
    }

    private func fileURL(accountID: String) throws -> URL {
        guard !accountID.isEmpty,
              accountID.utf8.count <= 256,
              accountID.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw RememberedSessionCatalogSnapshotError.invalidAccount
        }
        let digest = SHA256.hash(
            data: Data("kaisola-session-catalog-cache-v1\0\(accountID)".utf8)
        )
        let name = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent("\(name).json", isDirectory: false)
    }

    private static func isValid(_ snapshot: RememberedSessionCatalogSnapshot) -> Bool {
        guard snapshot.schema == 1,
              snapshot.savedAt >= 0,
              snapshot.devices.count <= 8,
              Set(snapshot.devices.map(\.deviceId)).count == snapshot.devices.count else {
            return false
        }
        return snapshot.devices.allSatisfy { device in
            device.revision >= 0
                && device.updatedAt >= 0
                && RememberedSessionCatalogPortable.id(
                    device.deviceId,
                    domain: "device",
                    maximumUTF8Bytes: 160
                ) == device.deviceId
                && RememberedSessionCatalogPortable.text(
                    device.deviceName,
                    maximumUTF8Bytes: 160,
                    fallback: "Kaisola device"
                ) == device.deviceName
                && device.sessions.count <= 256
                && Set(device.sessions.map(\.id)).count == device.sessions.count
                && device.sessions.allSatisfy(isValidSession)
        }
    }

    private static func isValidSession(_ session: RememberedSessionRecord) -> Bool {
        session.createdAt >= 0
            && session.lastActivityAt >= session.createdAt
            && RememberedSessionCatalogPortable.id(
                session.id,
                domain: "session",
                maximumUTF8Bytes: 240
            ) == session.id
            && RememberedSessionCatalogPortable.id(
                session.projectId,
                domain: "project",
                maximumUTF8Bytes: 160
            ) == session.projectId
            && RememberedSessionCatalogPortable.text(
                session.projectName,
                maximumUTF8Bytes: 240,
                fallback: "Kaisola project"
            ) == session.projectName
            && RememberedSessionCatalogPortable.text(
                session.title,
                maximumUTF8Bytes: 320,
                fallback: "Kaisola session"
            ) == session.title
            && session.agentId.map {
                RememberedSessionCatalogPortable.text(
                    $0,
                    maximumUTF8Bytes: 160,
                    fallback: "agent"
                ) == $0
            } ?? true
    }
}

/// Cross-platform, presentation-safe account catalog state. It contains only the
/// server's portable metadata projection; local AppModels and the detached
/// broker remain the sole authority for opening or controlling real sessions.
enum RememberedSessionCatalogSource: Equatable, Sendable {
    case live
    case savedSnapshot
}

@MainActor
final class RememberedSessionCatalogCenter: ObservableObject {
    @Published private(set) var devices: [RememberedDeviceCatalog] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdatedAt: Int64?
    @Published private(set) var source: RememberedSessionCatalogSource?
    @Published private(set) var errorMessage: String?
    /// Latched the first time any applied catalog names a device other than
    /// this one, and reset only by `clear()` (account switch / sign-out). A
    /// transient empty live list must not re-hide a fleet mid-session, and a
    /// never-paired install must not surface fleet errors about no fleet.
    /// Persisted in defaults, not only re-seeded by the saved snapshot: a
    /// fleet whose snapshot fails to load (cache wipe, decode failure) must
    /// still surface its refresh errors instead of hiding the whole section.
    @Published private(set) var hasEverSeenRemoteDevice = false

    let localDeviceID: String
    private let latchDefaults: UserDefaults
    private static let fleetLatchKey = "kaisola.rememberedSessions.hasEverSeenRemoteDevice"

    init(localDeviceID: String, latchDefaults: UserDefaults = .standard) {
        self.localDeviceID = localDeviceID
        self.latchDefaults = latchDefaults
        hasEverSeenRemoteDevice = latchDefaults.bool(forKey: Self.fleetLatchKey)
    }

    var remoteDevices: [RememberedDeviceCatalog] {
        devices.filter { $0.deviceId != localDeviceID }
    }

    var freshnessTitle: String? {
        guard let source, let lastUpdatedAt else { return nil }
        let date = Date(timeIntervalSince1970: Double(lastUpdatedAt) / 1_000)
        let relative = date.formatted(.relative(presentation: .named))
        switch source {
        case .live:
            return "Updated \(relative)"
        case .savedSnapshot where errorMessage != nil:
            return "Saved · refresh failed · \(relative)"
        case .savedSnapshot:
            return "Saved \(relative)"
        }
    }

    func beginRefresh() {
        isRefreshing = true
        errorMessage = nil
    }

    func apply(
        _ devices: [RememberedDeviceCatalog],
        now: Int64,
        source: RememberedSessionCatalogSource = .live
    ) {
        self.devices = devices.sorted { left, right in
            let leftIsLocal = left.deviceId == localDeviceID
            let rightIsLocal = right.deviceId == localDeviceID
            if leftIsLocal != rightIsLocal { return leftIsLocal }
            if left.presence != right.presence { return left.presence == .online }
            let nameOrder = left.deviceName.localizedCaseInsensitiveCompare(right.deviceName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return left.deviceId < right.deviceId
        }
        lastUpdatedAt = now
        self.source = source
        isRefreshing = false
        errorMessage = nil
        if devices.contains(where: { $0.deviceId != localDeviceID }), !hasEverSeenRemoteDevice {
            hasEverSeenRemoteDevice = true
            latchDefaults.set(true, forKey: Self.fleetLatchKey)
        }
    }

    func fail(_ error: any Error) {
        isRefreshing = false
        errorMessage = (error as? any LocalizedError)?.errorDescription
            ?? "Remembered sessions are temporarily unavailable."
    }

    func cancelRefresh() {
        isRefreshing = false
        errorMessage = nil
    }

    func clear() {
        devices = []
        isRefreshing = false
        lastUpdatedAt = nil
        source = nil
        errorMessage = nil
        hasEverSeenRemoteDevice = false
        latchDefaults.removeObject(forKey: Self.fleetLatchKey)
    }

    func requestRefresh() {
        NotificationCenter.default.post(name: .kaisolaRefreshRememberedSessions, object: nil)
    }

    static func preview(localDeviceID: String) -> RememberedSessionCatalogCenter {
        let center = RememberedSessionCatalogCenter(localDeviceID: localDeviceID)
        center.apply([
            RememberedDeviceCatalog(
                deviceId: localDeviceID,
                deviceName: "Studio Mac",
                revision: 4,
                updatedAt: 1_784_250_000_000,
                presence: .online,
                sessions: []
            ),
            RememberedDeviceCatalog(
                deviceId: "remote-mac",
                deviceName: "MacBook Air",
                revision: 8,
                updatedAt: 1_784_249_950_000,
                presence: .offline,
                sessions: [
                    RememberedSessionRecord(
                        id: "remote-codex",
                        projectId: "kaisola",
                        projectName: "Kaisola",
                        title: "Codex · release review",
                        kind: .terminal,
                        agentId: "codex",
                        activity: .needsAttention,
                        resumeKind: .livePTY,
                        createdAt: 1_784_240_000_000,
                        lastActivityAt: 1_784_249_900_000,
                        hasLocalTranscript: false
                    ),
                ]
            ),
        ], now: 1_784_250_000_000, source: .savedSnapshot)
        return center
    }
}

extension Notification.Name {
    static let kaisolaRefreshRememberedSessions = Notification.Name(
        "com.kaisola.mac.refresh-remembered-sessions"
    )
}
