import CryptoKit
import Darwin
import Foundation

/// A user-supplied language grammar: file extensions and fence tokens it
/// claims, plus regex highlight rules over the app's five fixed color roles.
/// Data-capability only (PR 6): a grammar can name no command, no file, and no
/// URL. The regexes compile under `NSRegularExpression` inside the same
/// never-throws scanner every shipped language uses, and an invalid spec is
/// kept, listed, and explained — never silently dropped, never installed.
struct CustomGrammarSpec: Codable, Equatable, Identifiable, Sendable {
    struct RuleSpec: Codable, Equatable, Sendable {
        var pattern: String
        /// One of the five fixed roles: comment, string, keyword, number, tag.
        var role: String
        /// Protected-pass rules (strings/comments) compete leftmost-longest;
        /// token rules are suppressed inside protected regions.
        var context: Bool?
        var priority: Int?
        var caseInsensitive: Bool?
        var anchorsMatchLines: Bool?
    }

    var id: String
    var title: String
    /// Lowercase file extensions, without dots.
    var extensions: [String]
    /// Fenced-code-block tokens (```token). Defaults to `extensions`.
    var fences: [String]?
    var rules: [RuleSpec]

    static let maximumRules = 24
    static let maximumPatternLength = 1_000
    static let maximumExtensions = 16

    /// Why this spec cannot be installed, or nil when it can. Each message
    /// names the field and value at fault — it is the settings row's whole
    /// explanation.
    var validationError: String? {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanID.isEmpty { return "The grammar has no id." }
        if cleanID.count > 64 { return "The id must be 64 characters or fewer." }
        if cleanID.unicodeScalars.contains(where: { !CharacterSet.alphanumerics.contains($0) && $0 != "-" && $0 != "_" }) {
            return "The id may only use letters, numbers, dashes, and underscores."
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty { return "The grammar has no title." }
        if cleanTitle.count > 60 { return "The title must be 60 characters or fewer." }
        if extensions.isEmpty { return "The grammar claims no file extensions." }
        if extensions.count > Self.maximumExtensions {
            return "A grammar may claim at most \(Self.maximumExtensions) extensions."
        }
        for ext in extensions {
            let clean = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if clean.isEmpty || clean.count > 12
                || clean.unicodeScalars.contains(where: { !CharacterSet.alphanumerics.contains($0) }) {
                return "\"\(ext)\" is not a usable file extension (letters and numbers, 12 characters or fewer, no dot)."
            }
            if SyntaxHighlighter.shippedExtensions.contains(clean) {
                return "\".\(clean)\" already belongs to a built-in grammar."
            }
        }
        if rules.isEmpty { return "The grammar has no rules." }
        if rules.count > Self.maximumRules {
            return "A grammar may have at most \(Self.maximumRules) rules."
        }
        for rule in rules {
            if SyntaxHighlighter.Role(rawValue: rule.role) == nil {
                return "\"\(rule.role)\" is not a color role (comment, string, keyword, number, tag)."
            }
            if rule.pattern.count > Self.maximumPatternLength {
                return "A rule pattern exceeds \(Self.maximumPatternLength) characters."
            }
            var options: NSRegularExpression.Options = []
            if rule.caseInsensitive == true { options.insert(.caseInsensitive) }
            if rule.anchorsMatchLines == true { options.insert(.anchorsMatchLines) }
            if (try? NSRegularExpression(pattern: rule.pattern, options: options)) == nil {
                return "The pattern \"\(rule.pattern.prefix(60))\" does not compile as a regular expression."
            }
        }
        return nil
    }

    /// The scanner-ready rules, or nil when `validationError` is non-nil.
    func asRules() -> [SyntaxHighlighter.Rule]? {
        guard validationError == nil else { return nil }
        return rules.compactMap { rule in
            guard let role = SyntaxHighlighter.Role(rawValue: rule.role) else { return nil }
            var options: NSRegularExpression.Options = []
            if rule.caseInsensitive == true { options.insert(.caseInsensitive) }
            if rule.anchorsMatchLines == true { options.insert(.anchorsMatchLines) }
            return SyntaxHighlighter.Rule(
                rule.pattern,
                role,
                context: rule.context ?? false,
                priority: rule.priority ?? 0,
                options: options
            )
        }
    }

    var normalizedExtensions: [String] {
        extensions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    var normalizedFences: [String] {
        (fences?.isEmpty == false ? fences! : extensions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}

/// Persists custom grammars without interpreting unreadable bytes as an empty
/// catalog. Corrupt and forward-version registries are preserved byte-for-byte
/// before an explicit reset is offered, while a process-scoped last-known-good
/// snapshot keeps already-running highlighters on their current grammar.
struct CustomGrammarStore: Sendable {
    enum Preservation: Equatable, Sendable {
        case preserved(URL)
        case failed(String)
    }

    enum LoadState: Equatable, Sendable {
        case missing
        case ready(schemaVersion: Int)
        case corrupt(Preservation)
        case newerVersion(Int, Preservation)
        case ioFailure(String)

        var allowsMutations: Bool {
            switch self {
            case .missing, .ready: true
            case .corrupt, .newerVersion, .ioFailure: false
            }
        }

        var canReset: Bool {
            switch self {
            case .corrupt(.preserved), .newerVersion(_, .preserved): true
            case .missing, .ready, .corrupt(.failed), .newerVersion(_, .failed), .ioFailure: false
            }
        }

        var preservedCopyURL: URL? {
            switch self {
            case let .corrupt(.preserved(url)), let .newerVersion(_, .preserved(url)): url
            case .missing, .ready, .corrupt(.failed), .newerVersion(_, .failed), .ioFailure: nil
            }
        }
    }

    struct Snapshot: Equatable, Sendable {
        var specs: [CustomGrammarSpec]
        var state: LoadState
    }

    enum StoreError: LocalizedError, Equatable, Sendable {
        case mutationBlocked
        case resetRequiresPreservedCopy
        case capacityExceeded(Int)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .mutationBlocked:
                "Language grammars are read-only until the registry issue is resolved."
            case .resetRequiresPreservedCopy:
                "Kaisola cannot reset language grammars without a verified recovery copy."
            case let .capacityExceeded(limit):
                "A maximum of \(limit) custom language grammars is supported."
            case .writeFailed:
                "Kaisola could not save language grammars. The existing registry was left unchanged."
            }
        }
    }

    private struct CurrentPayload: Codable {
        var version: Int
        var grammars: [CustomGrammarSpec]
    }

    private struct LegacyPayload: Codable {
        var grammars: [CustomGrammarSpec]
    }

    private final class RuntimeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var valuesByPath: [String: [CustomGrammarSpec]] = [:]

        func value(for path: String) -> [CustomGrammarSpec] {
            lock.lock()
            defer { lock.unlock() }
            return valuesByPath[path] ?? []
        }

        func replace(_ specs: [CustomGrammarSpec], for path: String) {
            lock.lock()
            defer { lock.unlock() }
            valuesByPath[path] = specs
        }

        func removeValue(for path: String) {
            lock.lock()
            defer { lock.unlock() }
            _ = valuesByPath.removeValue(forKey: path)
        }
    }

    static let schemaVersion = 1
    static let registryIssueID = "language-grammar-registry"
    private static let runtimeCache = RuntimeCache()
    let fileURL: URL
    private let cap = 16

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("custom-grammars.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    func specs() -> [CustomGrammarSpec] {
        load().specs
    }

    func load() -> Snapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            Self.runtimeCache.removeValue(for: cacheKey)
            return Snapshot(specs: [], state: .missing)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            return Snapshot(specs: lastKnownGood, state: .ioFailure(Self.describe(error)))
        }

        let object: [String: Any]
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return unreadableSnapshot(data: data)
            }
            object = dictionary
        } catch {
            return unreadableSnapshot(data: data)
        }

        guard let rawVersion = object["version"] else {
            do {
                let payload = try JSONDecoder().decode(LegacyPayload.self, from: data)
                guard payload.grammars.count <= cap else { return unreadableSnapshot(data: data) }
                remember(payload.grammars)
                return Snapshot(specs: payload.grammars, state: .ready(schemaVersion: 0))
            } catch {
                return unreadableSnapshot(data: data)
            }
        }
        guard let version = rawVersion as? Int, version >= 0 else {
            return unreadableSnapshot(data: data)
        }
        guard version <= Self.schemaVersion else {
            return Snapshot(
                specs: lastKnownGood,
                state: .newerVersion(version, preserve(data))
            )
        }

        do {
            let payload = try JSONDecoder().decode(CurrentPayload.self, from: data)
            guard payload.version == version, payload.grammars.count <= cap else {
                return unreadableSnapshot(data: data)
            }
            remember(payload.grammars)
            return Snapshot(specs: payload.grammars, state: .ready(schemaVersion: version))
        } catch {
            return unreadableSnapshot(data: data)
        }
    }

    func save(_ specs: [CustomGrammarSpec]) throws {
        let snapshot = load()
        guard snapshot.state.allowsMutations else { throw StoreError.mutationBlocked }
        guard specs.count <= cap else { throw StoreError.capacityExceeded(cap) }
        try write(specs)
    }

    @discardableResult
    func upsert(_ spec: CustomGrammarSpec) throws -> String? {
        let snapshot = load()
        guard snapshot.state.allowsMutations else { throw StoreError.mutationBlocked }
        var current = snapshot.specs
        if let index = current.firstIndex(where: { $0.id == spec.id }) {
            current[index] = spec
        } else {
            current.append(spec)
        }
        guard current.count <= cap else { throw StoreError.capacityExceeded(cap) }
        try write(current)
        return spec.validationError
    }

    @discardableResult
    func remove(id: String) throws -> Bool {
        let snapshot = load()
        guard snapshot.state.allowsMutations else { throw StoreError.mutationBlocked }
        let current = snapshot.specs
        let remaining = current.filter { $0.id != id }
        guard remaining.count != current.count else { return false }
        try write(remaining)
        return true
    }

    @discardableResult
    func resetUnreadableRegistry() throws -> Snapshot {
        let snapshot = load()
        guard snapshot.state.canReset else { throw StoreError.resetRequiresPreservedCopy }
        try write([])
        return Snapshot(specs: [], state: .ready(schemaVersion: Self.schemaVersion))
    }

    private var cacheKey: String { fileURL.standardizedFileURL.path }

    private var lastKnownGood: [CustomGrammarSpec] {
        Self.runtimeCache.value(for: cacheKey)
    }

    private func remember(_ specs: [CustomGrammarSpec]) {
        Self.runtimeCache.replace(specs, for: cacheKey)
    }

    private func unreadableSnapshot(data: Data) -> Snapshot {
        Snapshot(specs: lastKnownGood, state: .corrupt(preserve(data)))
    }

    private func preserve(_ data: Data) -> Preservation {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let preservedURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).preserved-\(digest).json", isDirectory: false)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: preservedURL.path) {
            do {
                return try Data(contentsOf: preservedURL) == data
                    ? .preserved(preservedURL)
                    : .failed("A recovery copy with the same fingerprint does not match.")
            } catch {
                return .failed(Self.describe(error))
            }
        }

        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(preservedURL.lastPathComponent).\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: temporary, options: [.withoutOverwriting])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try Self.synchronizeFile(at: temporary)
            do {
                try fileManager.moveItem(at: temporary, to: preservedURL)
            } catch {
                try? fileManager.removeItem(at: temporary)
                guard fileManager.fileExists(atPath: preservedURL.path),
                      try Data(contentsOf: preservedURL) == data else {
                    throw error
                }
            }
            return .preserved(preservedURL)
        } catch {
            try? fileManager.removeItem(at: temporary)
            return .failed(Self.describe(error))
        }
    }

    private func write(_ specs: [CustomGrammarSpec]) throws {
        let payload = CurrentPayload(version: Self.schemaVersion, grammars: specs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw StoreError.writeFailed(Self.describe(error))
        }

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: temporary, options: [.withoutOverwriting])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try Self.synchronizeFile(at: temporary)
            guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw StoreError.writeFailed(Self.describe(error))
        }
        remember(specs)
    }

    private static func synchronizeFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

/// Compiled custom grammars behind one `stat`. Fence blocks resolve a grammar
/// per transcript row render — during streaming that is a hot path, and a
/// JSON decode per row would be felt. The cache re-reads only when the store
/// file's modification date moves, which is the same freshness recipe the
/// desktop-wallpaper watch uses.
final class CustomGrammarCache: @unchecked Sendable {
    static let shared = CustomGrammarCache()

    private struct Compiled {
        let byExtension: [String: SyntaxHighlighter.GrammarChoice]
        let byFence: [String: SyntaxHighlighter.GrammarChoice]
        let modified: Date?
        let path: String
    }

    private let lock = NSLock()
    private var compiled: Compiled?

    func grammar(forExtension ext: String, store: CustomGrammarStore) -> SyntaxHighlighter.GrammarChoice? {
        current(store: store).byExtension[ext]
    }

    func grammar(forFence token: String, store: CustomGrammarStore) -> SyntaxHighlighter.GrammarChoice? {
        current(store: store).byFence[token]
    }

    private func current(store: CustomGrammarStore) -> Compiled {
        let modified = (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path))?[.modificationDate] as? Date
        lock.lock()
        defer { lock.unlock() }
        if let compiled, compiled.path == store.fileURL.path, compiled.modified == modified {
            return compiled
        }
        var byExtension: [String: SyntaxHighlighter.GrammarChoice] = [:]
        var byFence: [String: SyntaxHighlighter.GrammarChoice] = [:]
        for spec in store.specs() {
            guard let rules = spec.asRules() else { continue }
            let choice = SyntaxHighlighter.GrammarChoice.custom(id: spec.id, rules: rules)
            // First claim wins, matching the store's insertion order.
            for ext in spec.normalizedExtensions where byExtension[ext] == nil {
                byExtension[ext] = choice
            }
            for fence in spec.normalizedFences where byFence[fence] == nil {
                byFence[fence] = choice
            }
        }
        let fresh = Compiled(
            byExtension: byExtension,
            byFence: byFence,
            modified: modified,
            path: store.fileURL.path
        )
        compiled = fresh
        return fresh
    }
}
