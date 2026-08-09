import CryptoKit
import Foundation

/// A user-supplied language grammar: file extensions and fence tokens it
/// claims, plus regex highlight rules over the app's five fixed color roles.
/// Data-capability only (PR 6): a grammar can name no command, no file, and no
/// URL. The regexes compile under `NSRegularExpression` inside the same
/// never-throws scanner every shipped language uses, and an invalid spec is
/// kept, listed, and explained — never silently dropped, never installed.
struct CustomGrammarSpec: Codable, Equatable, Identifiable {
    struct RuleSpec: Codable, Equatable {
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

/// Persists custom grammars — the `CustomAgentStore` recipe (capped array,
/// atomic replace, user-scoped file) with one deliberate difference: bytes
/// this build cannot read are never reported as an empty registry. A malformed
/// or newer-schema file is copied beside the active one and every write is
/// refused until the user resets the registry, so the next edit can no longer
/// destroy the only copy of somebody's grammars.
struct CustomGrammarStore: Sendable {
    /// The schema `write` emits. A registry saved by a newer Kaisola carries a
    /// higher number; this build preserves it instead of guessing at it.
    static let schemaVersion = 1

    /// Where unreadable bytes were copied, or why the copy could not be made.
    /// A failed copy is what keeps the reset unavailable — with nothing
    /// preserved there is nothing to recover from afterwards.
    enum PreservedCopy: Equatable, Sendable {
        case saved(URL)
        case failed(String)

        var url: URL? {
            if case let .saved(url) = self { return url }
            return nil
        }
    }

    /// What the last read found. Every state but `ready` answers `[]` specs —
    /// falling back to plain text is safe — while the refusal to write is what
    /// keeps the file recoverable.
    enum LoadState: Equatable, Sendable {
        /// No registry file yet: the ordinary first-run state.
        case absent
        case ready(version: Int)
        /// The bytes are not a registry this build can decode.
        case malformed(PreservedCopy)
        case newerSchema(version: Int, preserved: PreservedCopy)
        /// The file exists but could not be read at all (permissions, I/O).
        case unreadable(String)

        var allowsWrites: Bool {
            switch self {
            case .absent, .ready: true
            case .malformed, .newerSchema, .unreadable: false
            }
        }

        var preservedCopy: URL? {
            switch self {
            case let .malformed(copy), let .newerSchema(_, copy): copy.url
            case .absent, .ready, .unreadable: nil
            }
        }

        /// A reset discards the active file, so it is offered only once the
        /// preserved copy has actually landed.
        var canReset: Bool { preservedCopy != nil }
    }

    struct Snapshot: Equatable, Sendable {
        var specs: [CustomGrammarSpec]
        var state: LoadState
    }

    /// Every way a write can be refused, each carrying the sentence the
    /// Extensions settings pane shows.
    enum WriteRefusal: LocalizedError, Equatable, Sendable {
        case registryUnreadable(LoadState)
        case resetNeedsPreservedCopy
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .registryUnreadable:
                "Custom grammars are read-only until the unreadable registry is reset."
            case .resetNeedsPreservedCopy:
                "Kaisola will not reset the registry without a preserved copy of the current file."
            case let .writeFailed(reason):
                "Kaisola could not save custom grammars: \(reason) The stored registry is unchanged."
            }
        }
    }

    /// Read before the full payload, so a future registry is preserved by its
    /// version even when its grammars decode as nonsense here.
    private struct VersionProbe: Codable {
        var version: Int?
    }

    private struct Payload: Codable {
        var version: Int?
        var grammars: [CustomGrammarSpec]
    }

    let fileURL: URL
    private let cap = 16

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("custom-grammars.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    /// Every stored spec, valid or not, in insertion order. An unreadable
    /// registry answers `[]`; `load()` is what says why.
    func specs() -> [CustomGrammarSpec] {
        load().specs
    }

    func load() -> Snapshot {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError {
                return Snapshot(specs: [], state: .absent)
            }
            return Snapshot(specs: [], state: .unreadable(Self.describe(error)))
        }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return Snapshot(specs: [], state: .malformed(preserve(data)))
        }
        // A registry with no version predates the field; it reads as 0 and is
        // rewritten at the current version by the next successful save.
        let version = probe.version ?? 0
        if version < 0 {
            return Snapshot(specs: [], state: .malformed(preserve(data)))
        }
        if version > Self.schemaVersion {
            return Snapshot(
                specs: [],
                state: .newerSchema(version: version, preserved: preserve(data))
            )
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Snapshot(specs: [], state: .malformed(preserve(data)))
        }
        return Snapshot(specs: payload.grammars, state: .ready(version: version))
    }

    func save(_ specs: [CustomGrammarSpec]) throws {
        let state = load().state
        guard state.allowsWrites else { throw WriteRefusal.registryUnreadable(state) }
        try write(specs.count > cap ? Array(specs.prefix(cap)) : specs)
    }

    /// Add or replace by id. Returns the reason the spec can never install when
    /// it is invalid — it is still stored, so the user sees it listed with that
    /// reason instead of wondering where the import went.
    @discardableResult
    func upsert(_ spec: CustomGrammarSpec) throws -> String? {
        let snapshot = load()
        guard snapshot.state.allowsWrites else {
            throw WriteRefusal.registryUnreadable(snapshot.state)
        }
        var current = snapshot.specs
        if let index = current.firstIndex(where: { $0.id == spec.id }) {
            current[index] = spec
        } else {
            current.append(spec)
        }
        try write(current.count > cap ? Array(current.prefix(cap)) : current)
        return spec.validationError
    }

    @discardableResult
    func remove(id: String) throws -> Bool {
        let snapshot = load()
        guard snapshot.state.allowsWrites else {
            throw WriteRefusal.registryUnreadable(snapshot.state)
        }
        let remaining = snapshot.specs.filter { $0.id != id }
        guard remaining.count != snapshot.specs.count else { return false }
        try write(remaining)
        return true
    }

    /// The one path that replaces an unreadable registry with an empty one.
    /// It exists only alongside a preserved copy, so "start over" never means
    /// "lose the file".
    @discardableResult
    func resetUnreadableRegistry() throws -> Snapshot {
        guard load().state.canReset else { throw WriteRefusal.resetNeedsPreservedCopy }
        try write([])
        return Snapshot(specs: [], state: .ready(version: Self.schemaVersion))
    }

    /// Copies the bytes we refuse to interpret next to the active file. The
    /// name carries a fingerprint of the content, so re-reading the same broken
    /// registry lands on the same copy instead of littering the directory.
    private func preserve(_ data: Data) -> PreservedCopy {
        let directory = fileURL.deletingLastPathComponent()
        let preserved = directory.appendingPathComponent(
            "\(fileURL.lastPathComponent).quarantined-\(Self.fingerprint(of: data)).json",
            isDirectory: false
        )
        if let existing = try? Data(contentsOf: preserved) {
            return existing == data
                ? .saved(preserved)
                : .failed("A different file already occupies \(preserved.lastPathComponent).")
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: preserved, options: [.withoutOverwriting])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: preserved.path
            )
            return .saved(preserved)
        } catch {
            return .failed(Self.describe(error))
        }
    }

    private func write(_ specs: [CustomGrammarSpec]) throws {
        let payload = Payload(version: Self.schemaVersion, grammars: specs)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)"
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporary.path
            )
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw WriteRefusal.writeFailed(Self.describe(error))
        }
    }

    /// One sentence, no domain codes: these strings end up in a settings row.
    private static func describe(_ error: Error) -> String {
        let message = (error as NSError).localizedDescription
        return message.hasSuffix(".") ? message : "\(message)."
    }

    private static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
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
