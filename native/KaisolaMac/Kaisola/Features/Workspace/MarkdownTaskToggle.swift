import Foundation

/// Locates the `- [ ]` / `- [x]` marker on the line containing a character
/// index and produces the one-character edit that toggles it. The edit goes
/// through the text view's normal `insertText(_:replacementRange:)` path, so
/// undo, autosave, and restyle all see an ordinary typed change.
enum MarkdownTaskToggle {
    private static let marker = try? NSRegularExpression(
        pattern: #"^([ \t]*(?:[-*+])[ \t]+\[)( |x|X)(\][ \t])"#
    )

    /// The single-character toggle for the task item whose line contains
    /// `characterIndex`, or nil when that line is not a task item.
    static func toggleRange(
        at characterIndex: Int,
        in source: NSString
    ) -> (range: NSRange, replacement: String)? {
        guard let marker, source.length > 0,
              characterIndex >= 0, characterIndex <= source.length else { return nil }
        let paragraph = source.paragraphRange(
            for: NSRange(location: min(characterIndex, source.length - 1), length: 0)
        )
        let line = source.substring(with: paragraph)
        guard let match = marker.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) else { return nil }
        let stateRange = match.range(at: 2)
        let absolute = NSRange(location: paragraph.location + stateRange.location, length: 1)
        let checked = (line as NSString).substring(with: stateRange).lowercased() == "x"
        return (absolute, checked ? " " : "x")
    }

    /// Whether `characterIndex` falls inside the marker's 3-character bracket
    /// group — the click target for toggling, so ordinary text clicks on the
    /// rest of the line still just place the caret.
    static func bracketGroupContains(
        _ characterIndex: Int,
        in source: NSString
    ) -> Bool {
        guard let marker, source.length > 0,
              characterIndex >= 0, characterIndex < source.length else { return false }
        let paragraph = source.paragraphRange(
            for: NSRange(location: characterIndex, length: 0)
        )
        let line = source.substring(with: paragraph)
        guard let match = marker.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) else { return false }
        let open = match.range(at: 1)
        let bracketStart = paragraph.location + NSMaxRange(open) - 1
        return characterIndex >= bracketStart && characterIndex < bracketStart + 3
    }
}
