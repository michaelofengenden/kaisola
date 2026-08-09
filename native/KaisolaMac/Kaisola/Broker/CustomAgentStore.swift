import Foundation

/// A user-registered terminal agent — any CLI the user wants in the New menu
/// beyond the built-in roster (Electron Settings ▸ Agents parity).
///
/// Terminal-only by default. A spec may additionally declare an ACP adapter
/// package and a credential context, and — after the user explicitly enables
/// it and the adapter is resolved into a pinned, integrity-checked install
/// (`AdapterInstallManager`) — reach the chat surface. All three fields are
/// additive optionals: every legacy roster entry decodes with them absent,
/// which reads as terminal-only and chat-disabled (the adversarial review's
/// finding 4 — a missing enablement flag must never decode as enabled).
struct CustomAgentSpec: Codable, Equatable, Identifiable {
    /// Whose credentials a chat with this agent uses — declared data, never
    /// inferred from an id or a package name (review finding 3).
    enum Credentials: String, Codable, CaseIterable, Identifiable {
        /// The Claude account bindings (CLAUDE_CONFIG_DIR profiles).
        case claude
        /// The Codex account bindings (CODEX_HOME profiles).
        case codex
        /// No provider identity: chats open with no account binding and no
        /// resumable provider continuation.
        case none

        var id: String { rawValue }
        var title: String {
            switch self {
            case .claude: "Claude accounts"
            case .codex: "Codex accounts"
            case .none: "No provider account"
            }
        }
    }

    var id: String
    var name: String
    var launchCommand: String
    var symbol: String
    /// npm registry package (optionally `@version`) for this agent's ACP
    /// adapter. Registry names only — never a path, git ref, or URL.
    var acpPackage: String?
    /// Raw `Credentials` value; absent means `.none`.
    var credentials: String?
    /// Whether the user has explicitly enabled the chat surface for this
    /// agent. Enablement is only honored when a verified install exists.
    var chatEnabled: Bool?

    var resolvedCredentials: Credentials {
        credentials.flatMap(Credentials.init) ?? .none
    }

    /// Why the declared ACP package can never be installed, or nil when the
    /// declaration is usable (or absent).
    var acpPackageValidationError: String? {
        guard let package = acpPackage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !package.isEmpty else { return nil }
        return Self.packageNameError(package)
    }

    /// npm-registry package shape: optional scope, name, optional version tag.
    /// Anything path-like, URL-like, or shell-hostile is refused by name.
    static func packageNameError(_ package: String) -> String? {
        if package.count > 214 { return "The package name exceeds npm's 214-character limit." }
        if package.contains("://") || package.hasPrefix(".") || package.hasPrefix("/")
            || package.contains("..") {
            return "Only npm registry package names are allowed — no paths, URLs, or git references."
        }
        let pattern = #"^(@[a-z0-9~][a-z0-9-._~]*\/)?[a-z0-9~][a-z0-9-._~]*(@[A-Za-z0-9-._^~<>=]+)?$"#
        if package.range(of: pattern, options: .regularExpression) == nil {
            return "\"\(package)\" is not an npm registry package name."
        }
        return nil
    }
}

/// Persists the user's executable custom-agent registry to the native
/// application-support directory (never Electron's). Reads and writes are
/// deliberately failure-visible: a caller must distinguish an empty registry
/// from one this build could not safely understand, and no save may overwrite
/// bytes that failed that check.
struct CustomAgentStore: Sendable {
    enum PersistenceOperation: String, Equatable, Sendable {
        case encodeRegistry
        case createDirectory
        case writeTemporaryFile
        case setPermissions
        case replaceRegistry

        var description: String {
            switch self {
            case .encodeRegistry: "encoding the registry"
            case .createDirectory: "creating its private directory"
            case .writeTemporaryFile: "writing its temporary file"
            case .setPermissions: "setting private file permissions"
            case .replaceRegistry: "atomically replacing the registry"
            }
        }
    }

    enum StoreError: Error, Equatable, Sendable {
        case registryUnreadable(path: String, reason: String)
        case corruptRegistry(path: String)
        case unsupportedSchema(found: Int, supported: Int)
        case invalidEntry(index: Int, id: String?, reason: String)
        case persistenceFailed(
            entryID: String?,
            operation: PersistenceOperation,
            path: String,
            reason: String
        )
    }

    typealias LoadResult = Result<[CustomAgentSpec], StoreError>
    typealias SaveResult = Result<[CustomAgentSpec], StoreError>

    static let schemaVersion = 1

    private struct Payload: Codable {
        var schemaVersion: Int
        var agents: [CustomAgentSpec]

        init(agents: [CustomAgentSpec]) {
            self.schemaVersion = CustomAgentStore.schemaVersion
            self.agents = agents
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case agents
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The original registry was unversioned. It is schema 1 by
            // definition, so existing users migrate without rewriting on read.
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            agents = try container.decode([CustomAgentSpec].self, forKey: .agents)
        }
    }

    private struct Header: Decodable {
        let schemaVersion: Int?
    }

    let fileURL: URL
    /// A deliberately small ceiling: the New menu is a launcher, not a registry.
    private let cap = 12
    private let replaceRegistry: @Sendable (URL, URL) throws -> Void

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("custom-agents.json", isDirectory: false)) {
        self.init(fileURL: fileURL, replaceRegistry: Self.atomicReplace)
    }

    /// `replaceRegistry` is an internal fault-injection seam for proving that
    /// an interrupted final rename leaves the old registry byte-for-byte intact.
    init(
        fileURL: URL,
        replaceRegistry: @escaping @Sendable (URL, URL) throws -> Void
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.replaceRegistry = replaceRegistry
    }

    /// Compatibility convenience for non-authoritative display code. Settings
    /// and every launch decision consume `load()` directly so a failure can
    /// never be mistaken for an intentionally empty registry.
    func all() -> [CustomAgentSpec] {
        (try? load().get()) ?? []
    }

    /// Load the complete registry or a typed failure. Decoding is all-or-none:
    /// one malformed row makes the entire result unusable for launching, while
    /// the original bytes remain untouched for diagnosis and recovery.
    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .success([])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .failure(.registryUnreadable(
                path: fileURL.path,
                reason: error.localizedDescription
            ))
        }

        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            return .failure(.corruptRegistry(path: fileURL.path))
        }
        let foundSchema = header.schemaVersion ?? 1
        guard foundSchema == Self.schemaVersion else {
            return .failure(.unsupportedSchema(
                found: foundSchema,
                supported: Self.schemaVersion
            ))
        }

        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            return .failure(Self.decodingFailure(error, data: data, path: fileURL.path))
        }
        if let error = Self.validationFailure(in: payload.agents, cap: cap) {
            return .failure(error)
        }
        return .success(payload.agents)
    }

    /// Replace the stored set as one transaction. Overflow and duplicate ids
    /// are rejected with the exact entry index instead of silently applying a
    /// subset: an id is a package and credential contract key.
    @discardableResult
    func save(_ specs: [CustomAgentSpec], affectedAgentID: String? = nil) -> SaveResult {
        if let error = Self.validationFailure(in: specs, cap: cap) {
            return .failure(error)
        }

        // A corrupt, partial, unreadable, or forward-version registry is not
        // an empty starting point. Refuse the write and preserve those bytes.
        if FileManager.default.fileExists(atPath: fileURL.path),
           case let .failure(error) = load() {
            return .failure(error)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(Payload(agents: specs))
        } catch {
            return persistenceFailure(
                affectedAgentID,
                operation: .encodeRegistry,
                path: fileURL.path,
                error: error
            )
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return persistenceFailure(
                affectedAgentID,
                operation: .createDirectory,
                path: directory.path,
                error: error
            )
        }

        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: [])
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return persistenceFailure(
                affectedAgentID,
                operation: .writeTemporaryFile,
                path: temporary.path,
                error: error
            )
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return persistenceFailure(
                affectedAgentID,
                operation: .setPermissions,
                path: temporary.path,
                error: error
            )
        }
        do {
            try replaceRegistry(temporary, fileURL)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return persistenceFailure(
                affectedAgentID,
                operation: .replaceRegistry,
                path: fileURL.path,
                error: error
            )
        }
        return .success(specs)
    }

    /// Map each spec into an `AgentProfile` for `AgentRegistry`. An empty symbol
    /// falls back to "terminal" so the session row always has a glyph.
    func asProfiles() -> Result<[AgentProfile], StoreError> {
        load().map { specs in specs.map { spec in
            AgentProfile(
                id: spec.id,
                name: spec.name,
                launchCommand: spec.launchCommand,
                symbol: spec.symbol.isEmpty ? "terminal" : spec.symbol
            )
        } }
    }

    /// Derive a stable, filesystem-safe id from a display name: lowercased, ASCII
    /// alphanumerics kept, every other run collapsed to a single dash, leading and
    /// trailing dashes trimmed, then "custom-" prefixed. Empty input — or a name
    /// with no alphanumerics — falls back to "custom-agent".
    ///
    /// Collision suffixing IS applied when `existing` ids are handed in: an id
    /// is a credential and package contract now (chat enablement binds to it),
    /// so two agents sharing one silently cross those contracts — the
    /// adversarial review's finding 2.
    static func slugify(_ name: String, existing: Set<String> = []) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var slug = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if allowed.contains(character) {
                slug.append(character)
                lastWasDash = false
            } else if !slug.isEmpty && !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        let base = slug.isEmpty ? "custom-agent" : "custom-\(slug)"
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private func persistenceFailure(
        _ entryID: String?,
        operation: PersistenceOperation,
        path: String,
        error: Error
    ) -> SaveResult {
        .failure(.persistenceFailed(
            entryID: entryID,
            operation: operation,
            path: path,
            reason: error.localizedDescription
        ))
    }

    private static func atomicReplace(temporary: URL, registry: URL) throws {
        if rename(temporary.path, registry.path) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }

    private static func decodingFailure(_ error: Error, data: Data, path: String) -> StoreError {
        let codingPath: [CodingKey]
        let reason: String
        switch error {
        case let DecodingError.keyNotFound(key, context):
            codingPath = context.codingPath
            reason = "Missing required field \"\(key.stringValue)\"."
        case let DecodingError.typeMismatch(_, context):
            codingPath = context.codingPath
            reason = context.debugDescription
        case let DecodingError.valueNotFound(_, context):
            codingPath = context.codingPath
            reason = context.debugDescription
        case let DecodingError.dataCorrupted(context):
            codingPath = context.codingPath
            reason = context.debugDescription
        default:
            return .corruptRegistry(path: path)
        }

        guard let index = codingPath.compactMap(\.intValue).first else {
            return .corruptRegistry(path: path)
        }
        let id = rawAgentID(at: index, data: data)
        return .invalidEntry(index: index, id: id, reason: reason)
    }

    private static func rawAgentID(at index: Int, data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = object["agents"] as? [[String: Any]],
              agents.indices.contains(index) else { return nil }
        return agents[index]["id"] as? String
    }

    private static func validationFailure(
        in specs: [CustomAgentSpec],
        cap: Int
    ) -> StoreError? {
        guard specs.count <= cap else {
            let index = cap
            return .invalidEntry(
                index: index,
                id: specs[index].id,
                reason: "The registry supports at most \(cap) custom agents."
            )
        }

        var seen = Set<String>()
        let reserved = Set(["claude-code", "codex", "opencode", "gemini"])
        for (index, spec) in specs.enumerated() {
            let id = spec.id
            if id.isEmpty || id != id.trimmingCharacters(in: .whitespacesAndNewlines) {
                return .invalidEntry(index: index, id: id, reason: "The agent id is empty or contains surrounding whitespace.")
            }
            if reserved.contains(id) {
                return .invalidEntry(index: index, id: id, reason: "The agent id is reserved for a built-in agent.")
            }
            if !seen.insert(id).inserted {
                return .invalidEntry(index: index, id: id, reason: "The agent id duplicates an earlier entry.")
            }
            if spec.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .invalidEntry(index: index, id: id, reason: "The display name is empty.")
            }
            if spec.launchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .invalidEntry(index: index, id: id, reason: "The launch command is empty.")
            }
            if let credentials = spec.credentials,
               CustomAgentSpec.Credentials(rawValue: credentials) == nil {
                return .invalidEntry(
                    index: index,
                    id: id,
                    reason: "The credential context \"\(credentials)\" is not recognized."
                )
            }
            if spec.chatEnabled == true {
                if spec.acpPackage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    return .invalidEntry(
                        index: index,
                        id: id,
                        reason: "Chat cannot be enabled without an ACP adapter package."
                    )
                }
                if let reason = spec.acpPackageValidationError {
                    return .invalidEntry(index: index, id: id, reason: reason)
                }
            }
        }
        return nil
    }
}

extension CustomAgentStore.StoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .registryUnreadable(path, reason):
            "Custom-agent registry at \(path) could not be read: \(reason)"
        case let .corruptRegistry(path):
            "Custom-agent registry at \(path) is malformed. Its bytes were preserved and no custom agent will launch."
        case let .unsupportedSchema(found, supported):
            "Custom-agent registry uses schema \(found), but this build supports schema \(supported). It was preserved unchanged and no custom agent will launch."
        case let .invalidEntry(index, id, reason):
            "Custom-agent entry \(index + 1)\(id.map { " (\($0))" } ?? "") is invalid: \(reason)"
        case let .persistenceFailed(entryID, operation, path, reason):
            "Could not save \(entryID.map { "custom agent \($0)" } ?? "the custom-agent registry") while \(operation.description) at \(path): \(reason). The previous registry was preserved."
        }
    }
}
