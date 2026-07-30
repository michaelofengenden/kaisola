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
    struct Theme: Sendable {
        var comment: Color
        var string: Color
        var keyword: Color
        var number: Color
        var tag: Color

        /// Ink appearance. Tones are drawn from the app's terminal palette
        /// (`TerminalTheme.dark`) so the editor reads as the same product:
        /// green-gray comments, warm strings, purple keywords, teal numbers,
        /// blue markup tags.
        static let dark = Theme(
            comment: hexColor(0x7C8574),
            string: hexColor(0xE0865E),
            keyword: hexColor(0xB78CE6),
            number: hexColor(0x56C1BC),
            tag: hexColor(0x5AA9E6)
        )

        /// Paper appearance — the same roles darkened for contrast on a light
        /// background.
        static let light = Theme(
            comment: hexColor(0x5C7355),
            string: hexColor(0xB4492A),
            keyword: hexColor(0x8035C0),
            number: hexColor(0x0F7A73),
            tag: hexColor(0x1F6FB0)
        )
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

    /// Highlight `text` for `language` using `theme`. Pure; never throws. On any
    /// problem (oversized input, regex failure, index mismatch) the affected
    /// span — or the whole string — falls back to plain text.
    static func highlight(_ text: String, language: Language, theme: Theme) -> AttributedString {
        let ns = text as NSString
        let length = ns.length
        // Empty and oversized inputs are returned as a single plain run.
        guard length > 0, length <= maxLength else { return AttributedString(text) }
        let fullRange = NSRange(location: 0, length: length)
        let rules = rules(for: language, theme: theme)

        // 1) Protected pass: strings + comments merged into one leftmost-longest,
        //    non-overlapping set. Because both kinds compete here, a comment that
        //    opens inside a string (or a quote inside a comment) loses to whichever
        //    started first — the naive-but-correct behavior for real code.
        var contextSpans: [Span] = []
        for rule in rules where rule.context {
            guard let regex = rule.compiled else { continue }
            for match in regex.matches(in: text, options: [], range: fullRange) where match.range.location != NSNotFound {
                contextSpans.append(Span(range: match.range, color: rule.color, priority: rule.priority))
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
        var protectedSpans: [Span] = []
        var freeFrom = 0
        for span in contextSpans where span.range.location >= freeFrom && span.range.length > 0 {
            let end = min(span.range.location + span.range.length, length)
            guard end > span.range.location else { continue }
            protectedSpans.append(span)
            for index in span.range.location..<end { covered[index] = true }
            freeFrom = end
        }

        // 2) Token pass: keywords, numbers, tags, attribute/key names — dropped
        //    when they fall inside a protected (string/comment) region.
        var tokenSpans: [Span] = []
        for rule in rules where !rule.context {
            guard let regex = rule.compiled else { continue }
            for match in regex.matches(in: text, options: [], range: fullRange) {
                let range = match.range
                guard range.location != NSNotFound, range.length > 0,
                      range.location < length, !covered[range.location] else { continue }
                tokenSpans.append(Span(range: range, color: rule.color, priority: rule.priority))
            }
        }

        // 3) Apply. Protected spans first, then tokens (tokens never overlap
        //    protected ranges; among themselves later rules win by ordering).
        var result = AttributedString(text)
        let indexMap = buildIndexMap(text: text, attributed: result)
        for span in protectedSpans {
            apply(span, to: &result, indexMap: indexMap, length: length)
        }
        for span in tokenSpans {
            apply(span, to: &result, indexMap: indexMap, length: length)
        }
        return result
    }

    // MARK: - Internals

    private struct Span {
        let range: NSRange
        let color: Color
        let priority: Int
    }

    private struct Rule {
        let pattern: String
        let color: Color
        let context: Bool
        let priority: Int
        let options: NSRegularExpression.Options

        init(_ pattern: String, _ color: Color, context: Bool = false, priority: Int = 0, options: NSRegularExpression.Options = []) {
            self.pattern = pattern
            self.color = color
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
        to attributed: inout AttributedString,
        indexMap: [Int: AttributedString.Index],
        length: Int
    ) {
        let start = span.range.location
        let end = span.range.location + span.range.length
        guard start >= 0, end <= length, start < end,
              let lower = indexMap[start], let upper = indexMap[end], lower < upper else { return }
        attributed[lower..<upper].foregroundColor = span.color
    }

    // MARK: - Language rules

    private static func rules(for language: Language, theme t: Theme) -> [Rule] {
        // Shared building blocks. `[\s\S]` matches across newlines without a
        // dot-all option; `\z` lets an unterminated block/string highlight to
        // end-of-file instead of not at all.
        let lineSlash = Rule(#"//[^\n]*"#, t.comment, context: true)
        let blockC = Rule(#"/\*[\s\S]*?(?:\*/|\z)"#, t.comment, context: true)
        // Single-line double/single quoted, with backslash escapes.
        let dquote = Rule(#""(?:\\.|[^"\\\n])*""#, t.string, context: true)
        let squote = Rule(#"'(?:\\.|[^'\\\n])*'"#, t.string, context: true)

        switch language {
        case .swift:
            return [
                lineSlash,
                blockC,
                // Multiline "" "" "" and raw #"..."# — written as normal strings
                // so the triple/hash quoting stays unambiguous.
                Rule("\"\"\"[\\s\\S]*?\"\"\"", t.string, context: true),
                Rule("#+\"[\\s\\S]*?\"#+", t.string, context: true),
                dquote,
                Rule(#"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, t.number),
                Rule(swiftKeywords, t.keyword),
            ]

        case .javascript:
            return [
                lineSlash,
                blockC,
                Rule(#"`(?:\\.|[^`\\])*`"#, t.string, context: true), // template literal
                dquote,
                squote,
                Rule(#"\b(?:0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?n?)\b"#, t.number),
                Rule(javascriptKeywords, t.keyword),
            ]

        case .python:
            return [
                Rule(#"#[^\n]*"#, t.comment, context: true),
                Rule("\"\"\"[\\s\\S]*?\"\"\"", t.string, context: true),
                Rule(#"'''[\s\S]*?'''"#, t.string, context: true),
                dquote,
                squote,
                Rule(#"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?j?)\b"#, t.number),
                Rule(#"\b(?:True|False|None)\b"#, t.keyword),
                Rule(pythonKeywords, t.keyword),
            ]

        case .json:
            return [
                // One plain string rule pairs every quote correctly in a single
                // left-to-right scan (a trailing lookahead would make the engine
                // restart mid-pair on keys and mis-pair the rest). Keys — strings
                // followed by a colon — reuse the same range but win the tie via
                // the higher priority, so they recolor to `keyword`.
                Rule(#""(?:\\.|[^"\\])*"(?=\s*:)"#, t.keyword, context: true, priority: 1),
                Rule(#""(?:\\.|[^"\\])*""#, t.string, context: true),
                Rule(#"-?(?:\d+)(?:\.\d+)?(?:[eE][+-]?\d+)?"#, t.number),
                Rule(#"\b(?:true|false|null)\b"#, t.keyword),
            ]

        case .shell:
            return [
                // `#` only starts a comment at line start or after whitespace.
                Rule(#"(?:^|(?<=\s))#[^\n]*"#, t.comment, context: true, options: [.anchorsMatchLines]),
                Rule(#""(?:\\.|[^"\\])*""#, t.string, context: true),
                Rule(#"'[^']*'"#, t.string, context: true), // single quotes are literal in sh
                Rule(#"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@*#?$!-]"#, t.number), // variables
                Rule(shellBuiltins, t.keyword),
                Rule(#"\b\d+\b"#, t.number),
            ]

        case .yaml:
            return [
                Rule(#"(?:^|(?<=\s))#[^\n]*"#, t.comment, context: true, options: [.anchorsMatchLines]),
                Rule(#""(?:\\.|[^"\\\n])*""#, t.string, context: true),
                Rule(#"'[^'\n]*'"#, t.string, context: true),
                Rule(#"\b(?:true|false|null|True|False|Null|yes|no|on|off)\b"#, t.number),
                // Key: from line start (optionally a "- " list marker) up to the
                // first colon. Applied last so a key named `true` wins over the
                // boolean rule above.
                Rule(#"^\s*(?:-\s+)?[^\s:#][^:#\n]*(?=:)"#, t.keyword, options: [.anchorsMatchLines]),
            ]

        case .html:
            return [
                Rule(#"<!--[\s\S]*?(?:-->|\z)"#, t.comment, context: true),
                Rule(#""[^"\n]*""#, t.string, context: true),
                Rule(#"'[^'\n]*'"#, t.string, context: true),
                Rule(#"</?[A-Za-z][\w:.-]*"#, t.tag),
                Rule(#"[A-Za-z_:][\w:.-]*(?=\s*=)"#, t.keyword), // attribute name
            ]

        case .css:
            return [
                blockC,
                Rule(#""[^"\n]*""#, t.string, context: true),
                Rule(#"'[^'\n]*'"#, t.string, context: true),
                Rule(#"#[0-9a-fA-F]{3,8}\b"#, t.number), // hex color
                Rule(#"@[\w-]+"#, t.keyword),            // at-rule
                Rule(#"!important\b"#, t.keyword),
                Rule(#"\b\d+(?:\.\d+)?%?"#, t.number),
                Rule(#"[-A-Za-z][\w-]*(?=\s*:)"#, t.keyword), // property name
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
