import Foundation

/// Which paragraphs currently reveal their Markdown syntax marks. Computed
/// from the selection; the diff between two states is exactly what the
/// incremental style pass repaints, so a cursor move costs the size of the
/// paragraphs it left and entered, never the document.
struct MarkdownRevealState: Equatable {
    let activeParagraphs: [NSRange]

    static let none = MarkdownRevealState(activeParagraphs: [])

    static func compute(selection: NSRange, in source: NSString) -> MarkdownRevealState {
        guard source.length > 0 else { return .none }
        let location = min(selection.location, source.length)
        let clamped = NSRange(
            location: location,
            length: min(selection.length, source.length - location)
        )
        return MarkdownRevealState(activeParagraphs: [source.paragraphRange(for: clamped)])
    }

    /// The ranges whose reveal state differs between `old` and `new`, merged
    /// when overlapping or adjacent. Equal states diff to nothing.
    static func changedRanges(
        from old: MarkdownRevealState,
        to new: MarkdownRevealState
    ) -> [NSRange] {
        guard old != new else { return [] }
        var ranges = old.activeParagraphs + new.activeParagraphs
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
