import AppKit
import Foundation
import SwiftUI

/// Lightweight, regex-based read-mode syntax highlighting for the file preview.
///
/// Design goals, in priority order:
///  1. **Never throws / never crashes.** Every regex is compiled with `try?`,
///     every index conversion is bounds-checked, and any failure degrades to
///     plain (uncolored) text. A highlighter that blanks or crashes the
///     preview is worse than no highlighter.
///  2. **Pure + fast.** No shared mutable state (safe to call off any actor),
///     input capped at ``maxLength`` characters, and each pattern is applied
///     over the bridged `NSString` exactly once via ``NSRegularExpression``.
///  3. **Good enough, not perfect.** Strings and comments form a single
///     "protected" leftmost-longest pass so a `//` inside a string, or a quote
///     inside a comment, is handled correctly; keywords/numbers are suppressed
///     inside those protected regions. Exotic cases (nested block comments,
///     regex literals, shell here-docs) are intentionally naive.
enum SyntaxHighlighter {
    /// Beyond this many UTF-16 units the input is returned plain. Keeps a single
    /// highlight pass comfortably sub-frame even on the 1 MiB preview ceiling.
    static let maxLength = 200_000

    enum Language: String, CaseIterable, Sendable {
        case swift, javascript, python, json, shell, yaml, html, css
    }

    /// Color roles, kept small on purpose. HTML tags reuse ``tag``; attribute
    /// names, JSON/YAML keys, and language keywords all reuse ``keyword``.
    enum Role: String, CaseIterable, Sendable {
        case comment, string, keyword, number, tag
    }

    /// One colored region of the source, addressed in UTF-16 offsets. Roles —
    /// not resolved colors — are what the scanner produces, so the same result
    /// drives the SwiftUI `AttributedString` path and the AppKit text storage
    /// the TextKit 2 reader hands to its layout manager.
    struct Span: Equatable, Sendable {
        let range: NSRange
        let role: Role
    }

    /// The SwiftUI palette for one appearance.
    struct Theme: Sendable {
        var comment: Color
        var string: Color
        var keyword: Color
        var number: Color
        var tag: Color

        func color(for role: Role) -> Color {
            switch role {
            case .comment: comment
            case .string: string
            case .keyword: keyword
            case .number: number
            case .tag: tag
            }
        }

        /// Ink appearance. Tones are drawn from the app's terminal palette
        /// (`TerminalTheme.dark`) so the editor reads as the same product:
        /// green-gray comments, warm strings, purple keywords, teal numbers,
        /// blue markup tags.
        static let dark = Theme(
            comment: hexColor(syntaxInk(.comment, dark: true)),
            string: hexColor(syntaxInk(.string, dark: true)),
            keyword: hexColor(syntaxInk(.keyword, dark: true)),
            number: hexColor(syntaxInk(.number, dark: true)),
            tag: hexColor(syntaxInk(.tag, dark: true))
        )

        /// Paper appearance — the same roles darkened for contrast on a light
        /// background.
        static let light = Theme(
            comment: hexColor(syntaxInk(.comment, dark: false)),
            string: hexColor(syntaxInk(.string, dark: false)),
            keyword: hexColor(syntaxInk(.keyword, dark: false)),
            number: hexColor(syntaxInk(.number, dark: false)),
            tag: hexColor(syntaxInk(.tag, dark: false))
        )
    }

    /// AppKit ink for `role`, resolved from the same table as ``Theme`` so the
    /// two rendering paths can never drift.
    nonisolated static func nsColor(for role: Role, dark: Bool) -> NSColor {
        nsHexColor(syntaxInk(role, dark: dark))
    }

    /// The language for a file extension, or `nil` when unknown (caller shows
    /// plain text). Case-insensitive.
    static func language(forExtension ext: String) -> Language? {
        switch ext.lowercased() {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return .javascript
        case "py", "pyw", "pyi": return .python
        case "json", "jsonc", "json5": return .json
        case "sh", "bash", "zsh", "command", "zshrc", "bashrc": return .shell
        case "yml", "yaml": return .yaml
        case "html", "htm", "xhtml", "xml", "svg", "vue", "plist": return .html
        case "css", "scss", "less": return .css
        default: return nil
        }
    }

    /// Every extension the shipped table claims. Custom grammars may not take
    /// these over — the shipped grammars are part of the product's behavior,
    /// and a user file that silently restyles Swift is the kind of quiet
    /// override PR 6 forbids. `testShippedExtensionsMatchTheShippedTable`
    /// holds this set and `language(forExtension:)` to each other.
    nonisolated static let shippedExtensions: Set<String> = [
        "swift",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts",
        "py", "pyw", "pyi",
        "json", "jsonc", "json5",
        "sh", "bash", "zsh", "command", "zshrc", "bashrc",
        "yml", "yaml",
        "html", "htm", "xhtml", "xml", "svg", "vue", "plist",
        "css", "scss", "less",
    ]

    /// What a consumer holds after resolution: a shipped language, or a custom
    /// grammar's compiled-checked rule set. Both scan through
    /// `spans(in:rules:)`; the split exists only so shipped languages keep
    /// costing a table lookup.
    enum GrammarChoice: Sendable, Equatable {
        case shipped(Language)
        case custom(id: String, rules: [Rule])

        var rules: [Rule] {
            switch self {
            case let .shipped(language): SyntaxHighlighter.rules(for: language)
            case let .custom(_, rules): rules
            }
        }

        /// Identity comparison: a shipped language is its case, a custom
        /// grammar is its id — rule arrays are derived data.
        static func == (lhs: GrammarChoice, rhs: GrammarChoice) -> Bool {
            switch (lhs, rhs) {
            case let (.shipped(left), .shipped(right)): left == right
            case let (.custom(left, _), .custom(right, _)): left == right
            default: false
            }
        }
    }

    /// The grammar for a file extension: shipped table first, then the
    /// validated custom registry. Case-insensitive; nil means plain text.
    static func grammar(
        forExtension ext: String,
        store: CustomGrammarStore = CustomGrammarStore()
    ) -> GrammarChoice? {
        if let language = language(forExtension: ext) { return .shipped(language) }
        return CustomGrammarCache.shared.grammar(forExtension: ext.lowercased(), store: store)
    }

    /// The grammar for a fenced-code-block token, same precedence.
    static func grammar(
        forFence token: String,
        store: CustomGrammarStore = CustomGrammarStore()
    ) -> GrammarChoice? {
        if let language = language(forExtension: token) { return .shipped(language) }
        return CustomGrammarCache.shared.grammar(forFence: token.lowercased(), store: store)
    }

    /// `attributedSource` over a resolved grammar — the registry-aware form of
    /// the `language:` entry point below it.
    nonisolated static func attributedSource(
        _ text: String,
        grammar: GrammarChoice?,
        dark: Bool
    ) -> AttributedSource {
        attributedSource(text, rules: grammar?.rules, dark: dark)
    }

    /// `highlight` over a resolved grammar.
    static func highlight(_ text: String, grammar: GrammarChoice, theme: Theme) -> AttributedString {
        var result = AttributedString(text)
        let spans = spans(in: text, rules: grammar.rules)
        guard !spans.isEmpty else { return result }
        let length = (text as NSString).length
        let indexMap = buildIndexMap(text: text, attributed: result)
        for span in spans {
            apply(span, color: theme.color(for: span.role), to: &result, indexMap: indexMap, length: length)
        }
        return result
    }

    /// The colored regions of `text` for `language`, in application order.
    /// Pure; never throws. Empty and oversized inputs yield no spans, so both
    /// rendering paths degrade to plain text without a second size check.
    nonisolated static func spans(in text: String, language: Language) -> [Span] {
        spans(in: text, rules: rules(for: language))
    }

    /// The same scan over an explicit rule set — the entry point a custom
    /// grammar uses. Shipped languages route through it unchanged, so both
    /// kinds of grammar exercise one code path and one set of guarantees.
    nonisolated static func spans(in text: String, rules: [Rule]) -> [Span] {
        let ns = text as NSString
        let length = ns.length
        guard length > 0, length <= maxLength else { return [] }
        let fullRange = NSRange(location: 0, length: length)

        // 1) Protected pass: strings + comments merged into one leftmost-longest,
        //    non-overlapping set. Because both kinds compete here, a comment that
        //    opens inside a string (or a quote inside a comment) loses to whichever
        //    started first — the naive-but-correct behavior for real code.
        var contextSpans: [RankedSpan] = []
        for rule in rules where rule.context {
            guard let regex = rule.compiled else { continue }
            for match in regex.matches(in: text, options: [], range: fullRange) where match.range.location != NSNotFound {
                contextSpans.append(RankedSpan(range: match.range, role: rule.role, priority: rule.priority))
            }
        }
        // Leftmost first; for a shared start the longer match wins; for an
        // identical range the higher-priority rule wins (JSON keys override the
        // generic string rule that also covers them).
        contextSpans.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
            return lhs.priority > rhs.priority
        }

        var covered = [Bool](repeating: false, count: length)
        var ordered: [Span] = []
        var freeFrom = 0
        for span in contextSpans where span.range.location >= freeFrom && span.range.length > 0 {
            let end = min(span.range.location + span.range.length, length)
            guard end > span.range.location else { continue }
            ordered.append(Span(range: span.range, role: span.role))
            for index in span.range.location..<end { covered[index] = true }
            freeFrom = end
        }

        // 2) Token pass: keywords, numbers, tags, attribute/key names — dropped
        //    when they fall inside a protected (string/comment) region. Appended
        //    after the protected spans so a later application overwrites nothing
        //    it should not (tokens never overlap protected ranges; among
        //    themselves later rules win by ordering).
        for rule in rules where !rule.context {
            guard let regex = rule.compiled else { continue }
            for match in regex.matches(in: text, options: [], range: fullRange) {
                let range = match.range
                guard range.location != NSNotFound, range.length > 0,
                      range.location < length, !covered[range.location] else { continue }
                ordered.append(Span(range: range, role: rule.role))
            }
        }
        return ordered
    }

    /// Highlight `text` for `language` using `theme`. Pure; never throws. On any
    /// problem (oversized input, regex failure, index mismatch) the affected
    /// span — or the whole string — falls back to plain text.
    static func highlight(_ text: String, language: Language, theme: Theme) -> AttributedString {
        var result = AttributedString(text)
        let spans = spans(in: text, language: language)
        // The grapheme index map is O(n) in both time and memory; skip it
        // entirely when there is nothing to color.
        guard !spans.isEmpty else { return result }
        let length = (text as NSString).length
        let indexMap = buildIndexMap(text: text, attributed: result)
        for span in spans {
            apply(span, color: theme.color(for: span.role), to: &result, indexMap: indexMap, length: length)
        }
        return result
    }

    /// An AppKit rendering of `text`, ready to install in a TextKit 2 text
    /// storage. Colors and line spacing only: the caller owns the font, so a
    /// zoom step re-lays out without paying for a re-highlight. Plain source
    /// keeps `labelColor`, which resolves per appearance at draw time.
    ///
    /// Pure and safe to call off the main actor; the deeply immutable — but
    /// pre-`Sendable` — result crosses back in ``AttributedSource``.
    nonisolated static func attributedSource(
        _ text: String,
        language: Language?,
        dark: Bool
    ) -> AttributedSource {
        attributedSource(text, rules: language.map { rules(for: $0) }, dark: dark)
    }

    nonisolated static func attributedSource(
        _ text: String,
        rules: [Rule]?,
        dark: Bool
    ) -> AttributedSource {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let storage = NSMutableAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        guard let rules else { return AttributedSource(value: storage) }
        let spans = spans(in: text, rules: rules)
        guard !spans.isEmpty else { return AttributedSource(value: storage) }

        // Five roles, resolved once — a per-span conversion would allocate an
        // NSColor for every keyword in the file.
        var palette: [Role: NSColor] = [:]
        for role in Role.allCases { palette[role] = nsColor(for: role, dark: dark) }

        storage.beginEditing()
        for span in spans {
            guard let color = palette[span.role] else { continue }
            applyAppKitSpan(span, color: color, to: storage)
        }
        storage.endEditing()
        return AttributedSource(value: storage)
    }

    /// Applies `color` for `span` to `storage`'s foreground color attribute,
    /// clamped to what `storage` actually contains. Never throws: the
    /// AttributedString path (`apply(_:to:indexMap:length:)` below) already
    /// clamps span ranges to the text length, and this AppKit path must too —
    /// a span range that runs past the end (never expected from well-formed
    /// tokenization, but not guaranteed for pathological input) would
    /// otherwise trap `NSMutableAttributedString` with an out-of-range
    /// exception instead of just skipping the tail. Internal so the clamp is
    /// directly testable without needing a span-producing input that already
    /// runs past bounds.
    nonisolated static func applyAppKitSpan(
        _ span: Span,
        color: NSColor,
        to storage: NSMutableAttributedString
    ) {
        let bounds = NSRange(location: 0, length: storage.length)
        guard let range = bounds.intersection(span.range), range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: color, range: range)
    }

    // MARK: - Internals

    private struct RankedSpan {
        let range: NSRange
        let role: Role
        let priority: Int
    }

    /// One highlight rule. Internal (not private) because custom grammars are
    /// rule arrays too — validated by `CustomGrammarSpec` and scanned by the
    /// same `spans(in:rules:)` pass as every shipped language.
    struct Rule: Sendable {
        let pattern: String
        let role: Role
        let context: Bool
        let priority: Int
        let options: NSRegularExpression.Options

        init(_ pattern: String, _ role: Role, context: Bool = false, priority: Int = 0, options: NSRegularExpression.Options = []) {
            self.pattern = pattern
            self.role = role
            self.context = context
            self.priority = priority
            self.options = options
        }

        /// Compiled lazily; `nil` (rule skipped) if the pattern is ever invalid.
        var compiled: NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: options)
        }
    }

    /// Maps every grapheme-boundary UTF-16 offset to the matching
    /// `AttributedString.Index`. Built once per highlight in O(n); span
    /// application is then O(1) per endpoint. Offsets that fall inside a grapheme
    /// (never produced by our token regexes on well-formed source, but possible
    /// for pathological input) are simply absent, so ``apply(_:to:indexMap:length:)``
    /// skips them instead of trapping.
    private static func buildIndexMap(text: String, attributed: AttributedString) -> [Int: AttributedString.Index] {
        var map: [Int: AttributedString.Index] = [:]
        map.reserveCapacity(text.count + 1)
        var textIndex = text.startIndex
        var attrIndex = attributed.characters.startIndex
        var utf16Offset = 0
        map[0] = attrIndex
        while textIndex < text.endIndex {
            let next = text.index(after: textIndex)
            utf16Offset += text.utf16.distance(from: textIndex, to: next)
            textIndex = next
            attrIndex = attributed.characters.index(after: attrIndex)
            map[utf16Offset] = attrIndex
        }
        return map
    }

    private static func apply(
        _ span: Span,
        color: Color,
        to attributed: inout AttributedString,
        indexMap: [Int: AttributedString.Index],
        length: Int
    ) {
        let start = span.range.location
        let end = span.range.location + span.range.length
        guard start >= 0, end <= length, start < end,
              let lower = indexMap[start], let upper = indexMap[end], lower < upper else { return }
        attributed[lower..<upper].foregroundColor = color
    }

    // MARK: - Language rules

    private static func rules(for language: Language) -> [Rule] {
        // Shared building blocks. `[\s\S]` matches across newlines without a
        // dot-all option; `\z` lets an unterminated block/string highlight to
        // end-of-file instead of not at all.
        let lineSlash = Rule(#"//[^\n]*"#, .comment, context: true)
        let blockC = Rule(#"/\*[\s\S]*?(?:\*/|\z)"#, .comment, context: true)
        // Single-line double/single quoted, with backslash escapes.
        let dquote = Rule(#""(?:\\.|[^"\\\n])*""#, .string, context: true)
        let squote = Rule(#"'(?:\\.|[^'\\\n])*'"#, .string, context: true)

        switch language {
        case .swift:
            return [
                lineSlash,
                blockC,
                // Multiline "" "" "" and raw #"..."# — written as normal strings
                // so the triple/hash quoting stays unambiguous.
                Rule("\"\"\"[\\s\\S]*?\"\"\"", .string, context: true),
                Rule("#+\"[\\s\\S]*?\"#+", .string, context: true),
                dquote,
                Rule(#"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, .number),
                Rule(swiftKeywords, .keyword),
            ]

        case .javascript:
            return [
                lineSlash,
                blockC,
                Rule(#"`(?:\\.|[^`\\])*`"#, .string, context: true), // template literal
                dquote,
                squote,
                Rule(#"\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?n?)\b"#, .number),
                Rule(javascriptKeywords, .keyword),
            ]

        case .python:
            return [
                Rule(#"#[^\n]*"#, .comment, context: true),
                Rule("\"\"\"[\\s\\S]*?\"\"\"", .string, context: true),
                Rule(#"'''[\s\S]*?'''"#, .string, context: true),
                dquote,
                squote,
                Rule(#"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?j?)\b"#, .number),
                Rule(#"\b(?:True|False|None)\b"#, .keyword),
                Rule(pythonKeywords, .keyword),
            ]

        case .json:
            return [
                // One plain string rule pairs every quote correctly in a single
                // left-to-right scan (a trailing lookahead would make the engine
                // restart mid-pair on keys and mis-pair the rest). Keys — strings
                // followed by a colon — reuse the same range but win the tie via
                // the higher priority, so they recolor to `keyword`.
                Rule(#""(?:\\.|[^"\\])*"(?=\s*:)"#, .keyword, context: true, priority: 1),
                Rule(#""(?:\\.|[^"\\])*""#, .string, context: true),
                Rule(#"-?(?:\d+)(?:\.\d+)?(?:[eE][+-]?\d+)?"#, .number),
                Rule(#"\b(?:true|false|null)\b"#, .keyword),
            ]

        case .shell:
            return [
                // `#` only starts a comment at line start or after whitespace.
                Rule(#"(?:^|(?<=\s))#[^\n]*"#, .comment, context: true, options: [.anchorsMatchLines]),
                Rule(#""(?:\\.|[^"\\])*""#, .string, context: true),
                Rule(#"'[^']*'"#, .string, context: true), // single quotes are literal in sh
                Rule(#"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]"#, .number), // variables
                Rule(shellBuiltins, .keyword),
                Rule(#"\b\d+\b"#, .number),
            ]

        case .yaml:
            return [
                Rule(#"(?:^|(?<=\s))#[^\n]*"#, .comment, context: true, options: [.anchorsMatchLines]),
                Rule(#""(?:\\.|[^"\\\n])*""#, .string, context: true),
                Rule(#"'[^'\n]*'"#, .string, context: true),
                Rule(#"\b(?:true|false|null|True|False|Null|yes|no|on|off)\b"#, .number),
                // Key: from line start (optionally a "- " list marker) up to the
                // first colon. Applied last so a key named `true` wins over the
                // boolean rule above.
                Rule(#"^\s*(?:-\s+)?[^\s:#][^:#\n]*(?=:)"#, .keyword, options: [.anchorsMatchLines]),
            ]

        case .html:
            return [
                Rule(#"<!--[\s\S]*?(?:-->|\z)"#, .comment, context: true),
                Rule(#""[^"\n]*""#, .string, context: true),
                Rule(#"'[^'\n]*'"#, .string, context: true),
                Rule(#"</?[A-Za-z][\w:.-]*"#, .tag),
                Rule(#"[A-Za-z_:][\w:.-]*(?=\s*=)"#, .keyword), // attribute name
            ]

        case .css:
            return [
                blockC,
                Rule(#""[^"\n]*""#, .string, context: true),
                Rule(#"'[^'\n]*'"#, .string, context: true),
                Rule(#"#[0-9a-fA-F]{3,8}\b"#, .number), // hex color
                Rule(#"@[\w-]+"#, .keyword),            // at-rule
                Rule(#"!important\b"#, .keyword),
                Rule(#"\b\d+(?:\.\d+)?%?"#, .number),
                Rule(#"[-A-Za-z][\w-]*(?=\s*:)"#, .keyword), // property name
            ]
        }
    }

    // MARK: - Keyword sets

    private static let swiftKeywords =
        #"\b(?:actor|as|associatedtype|async|await|break|case|catch|class|continue|convenience|default|defer|deinit|didSet|do|dynamic|else|enum|extension|fallthrough|false|fileprivate|final|for|func|get|guard|if|import|in|indirect|init|inout|internal|is|lazy|let|mutating|nil|nonisolated|nonmutating|open|operator|override|precedencegroup|private|protocol|public|repeat|required|rethrows|return|self|Self|set|some|static|struct|subscript|super|switch|throw|throws|true|try|typealias|unowned|var|weak|where|while|willSet)\b"#

    private static let javascriptKeywords =
        #"\b(?:abstract|any|as|async|await|boolean|break|case|catch|class|const|continue|debugger|declare|default|delete|do|else|enum|export|extends|false|finally|for|from|function|get|if|implements|import|in|instanceof|interface|is|keyof|let|namespace|new|null|number|of|private|protected|public|readonly|return|satisfies|set|static|string|super|switch|this|throw|true|try|type|typeof|undefined|unknown|var|void|while|with|yield)\b"#

    private static let pythonKeywords =
        #"\b(?:and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|match|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#

    private static let shellBuiltins =
        #"\b(?:alias|break|case|cd|continue|declare|do|done|echo|elif|else|esac|eval|exec|exit|export|false|fi|for|function|getopts|if|in|kill|local|popd|printf|pushd|pwd|read|readonly|return|select|set|shift|source|test|then|trap|true|unalias|unset|until|wait|while)\b"#
}

/// An immutable AppKit rendering of highlighted source, moved across the
/// highlight boundary explicitly: `NSAttributedString` is deeply immutable but
/// predates `Sendable`.
struct AttributedSource: @unchecked Sendable {
    let value: NSAttributedString
}

/// The single ink table behind both palettes — the SwiftUI ``SyntaxHighlighter/Theme``
/// and the AppKit colors the TextKit 2 reader applies. Kept here, file-scoped,
/// so neither path can drift from the other.
///
/// Ink tones are drawn from the app's terminal palette so the editor reads as
/// the same product; paper tones are the same roles darkened for contrast.
private func syntaxInk(_ role: SyntaxHighlighter.Role, dark: Bool) -> UInt32 {
    switch role {
    case .comment: dark ? 0x7C8574 : 0x5C7355
    case .string: dark ? 0xE0865E : 0xB4492A
    case .keyword: dark ? 0xB78CE6 : 0x8035C0
    case .number: dark ? 0x56C1BC : 0x0F7A73
    case .tag: dark ? 0x5AA9E6 : 0x1F6FB0
    }
}

/// sRGB color from a 0xRRGGBB literal. File-scoped so ``SyntaxHighlighter.Theme``
/// can build its static palettes without any main-actor hop.
private func hexColor(_ hex: UInt32) -> Color {
    Color(
        .sRGB,
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255,
        opacity: 1
    )
}

/// The AppKit sibling of ``hexColor(_:)``, in the same sRGB space so the two
/// rendering paths produce identical pixels.
private func nsHexColor(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}
