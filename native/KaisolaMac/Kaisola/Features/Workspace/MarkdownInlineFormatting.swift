import Foundation

/// Selection-relative Markdown formatting edits, expressed as byte
/// replacements ordered bottom-up so the caller can apply them sequentially
/// through `insertText(_:replacementRange:)` without invalidating ranges.
enum MarkdownInlineFormatting {
    /// Wrap the selection in `delimiter` — or unwrap it when the delimiters
    /// already sit immediately outside the selection. Nil for a collapsed
    /// selection (the caller falls back to its placeholder insertion).
    static func toggleWrap(
        _ delimiter: String,
        selection: NSRange,
        in source: NSString
    ) -> (edits: [(NSRange, String)], newSelection: NSRange)? {
        guard selection.length > 0,
              NSMaxRange(selection) <= source.length else { return nil }
        let width = (delimiter as NSString).length
        let before = NSRange(location: selection.location - width, length: width)
        let after = NSRange(location: NSMaxRange(selection), length: width)
        let wrapped = before.location >= 0
            && NSMaxRange(after) <= source.length
            && source.substring(with: before) == delimiter
            && source.substring(with: after) == delimiter
        if wrapped {
            return (
                edits: [(after, ""), (before, "")],
                newSelection: NSRange(location: before.location, length: selection.length)
            )
        }
        return (
            edits: [
                (NSRange(location: NSMaxRange(selection), length: 0), delimiter),
                (NSRange(location: selection.location, length: 0), delimiter),
            ],
            newSelection: NSRange(location: selection.location + width, length: selection.length)
        )
    }

    /// `[selection](url)` — with a URL the caret lands after the closing
    /// paren; without one it lands inside the empty parens ready to type.
    /// Nil for a collapsed selection.
    static func linkEdit(
        selection: NSRange,
        url: String?,
        in source: NSString
    ) -> (edits: [(NSRange, String)], newSelection: NSRange)? {
        guard selection.length > 0,
              NSMaxRange(selection) <= source.length else { return nil }
        let suffix = "](" + (url ?? "") + ")"
        let caret: NSRange
        if url == nil {
            caret = NSRange(location: selection.location + selection.length + 3, length: 0)
        } else {
            caret = NSRange(
                location: selection.location + selection.length + 1 + (suffix as NSString).length,
                length: 0
            )
        }
        return (
            edits: [
                (NSRange(location: NSMaxRange(selection), length: 0), suffix),
                (NSRange(location: selection.location, length: 0), "["),
            ],
            newSelection: caret
        )
    }

    /// Whether a pasted string should become a link destination: a single
    /// absolute http(s) URL with a host and no whitespace.
    static func pastedURL(from candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return trimmed
    }
}

/// Resolves `[[wikilink]]` names against the project's cached file list:
/// case-insensitive base-name match with `.md` implied.
enum WikilinkResolver {
    static func resolve(_ name: String, inFiles files: [String], root: URL) -> URL? {
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return nil }
        let match = files.first { path in
            guard path.lowercased().hasSuffix(".md") else { return false }
            let base = URL(fileURLWithPath: path)
                .deletingPathExtension().lastPathComponent.lowercased()
            return base == target
        }
        return match.map { root.appendingPathComponent($0).standardizedFileURL }
    }
}
