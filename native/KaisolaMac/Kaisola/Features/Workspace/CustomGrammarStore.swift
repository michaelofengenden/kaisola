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

/// Persists custom grammars — the `CustomAgentStore` recipe: capped array,
/// atomic replace, corrupt → empty, user-scoped file.
struct CustomGrammarStore: Sendable {
    private struct Payload: Codable {
        var grammars: [CustomGrammarSpec]
    }

    let fileURL: URL
    private let cap = 16

    init(fileURL: URL = NativePreviewPaths.applicationSupportDirectory
        .appendingPathComponent("custom-grammars.json", isDirectory: false)) {
        self.fileURL = fileURL
    }

    func specs() -> [CustomGrammarSpec] {
        read()?.grammars ?? []
    }

    func save(_ specs: [CustomGrammarSpec]) {
        let capped = specs.count > cap ? Array(specs.prefix(cap)) : specs
        write(Payload(grammars: capped))
    }

    @discardableResult
    func upsert(_ spec: CustomGrammarSpec) -> String? {
        var current = specs()
        if let index = current.firstIndex(where: { $0.id == spec.id }) {
            current[index] = spec
        } else {
            current.append(spec)
        }
        save(current)
        return spec.validationError
    }

    @discardableResult
    func remove(id: String) -> Bool {
        let current = specs()
        let remaining = current.filter { $0.id != id }
        guard remaining.count != current.count else { return false }
        save(remaining)
        return true
    }

    private func read() -> Payload? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private func write(_ payload: Payload) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
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
