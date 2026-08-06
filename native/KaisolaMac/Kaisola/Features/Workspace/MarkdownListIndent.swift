import Foundation

/// Tab / Shift-Tab on a list line: indent inserts one tab at the line start,
/// outdent removes one leading tab (or up to four leading spaces). Ordered
/// blocks renumber as a unit. All edits are plain byte replacements applied
/// through the text view's normal edit path.
enum MarkdownListIndent {
    enum Direction {
        case indent
        case outdent
    }

    private static let listLine = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+"#
    )
    private static let orderedLine = try? NSRegularExpression(
        pattern: #"^([ \t]*)(\d{1,9})([.)][ \t]+)"#
    )

    static func edit(
        for source: NSString,
        paragraph: NSRange,
        direction: Direction
    ) -> (range: NSRange, replacement: String)? {
        guard let listLine, paragraph.location <= source.length,
              NSMaxRange(paragraph) <= source.length else { return nil }
        let line = source.substring(with: paragraph)
        let lineRange = NSRange(location: 0, length: (line as NSString).length)
        guard listLine.firstMatch(in: line, range: lineRange) != nil else { return nil }
        switch direction {
        case .indent:
            return (NSRange(location: paragraph.location, length: 0), "\t")
        case .outdent:
            if line.hasPrefix("\t") {
                return (NSRange(location: paragraph.location, length: 1), "")
            }
            let spaces = line.prefix(4).prefix(while: { $0 == " " }).count
            guard spaces > 0 else { return nil }
            return (NSRange(location: paragraph.location, length: spaces), "")
        }
    }

    /// The contiguous run of ordered-list lines containing `location`, or nil
    /// when that line is not an ordered item. This is the unit `renumber`
    /// re-sequences after an indent or continuation edit.
    static func orderedBlock(containing location: Int, in source: NSString) -> NSRange? {
        guard let orderedLine, source.length > 0, location >= 0, location < source.length else { return nil }
        func isOrdered(_ paragraph: NSRange) -> Bool {
            let line = source.substring(with: paragraph)
            return orderedLine.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
            ) != nil
        }
        var block = source.paragraphRange(for: NSRange(location: location, length: 0))
        guard isOrdered(block) else { return nil }
        while block.location > 0 {
            let previous = source.paragraphRange(
                for: NSRange(location: block.location - 1, length: 0)
            )
            guard isOrdered(previous) else { break }
            block = NSUnionRange(block, previous)
        }
        while NSMaxRange(block) < source.length {
            let next = source.paragraphRange(
                for: NSRange(location: NSMaxRange(block), length: 0)
            )
            guard next.length > 0, isOrdered(next) else { break }
            block = NSUnionRange(block, next)
        }
        return block
    }

    /// Re-sequences a contiguous ordered-list block to 1, 2, 3… Edits are
    /// returned bottom-up so earlier ranges stay valid while the caller
    /// applies them in order. Lines keep their own indent and delimiter.
    static func renumber(
        block: NSRange,
        in source: NSString
    ) -> [(range: NSRange, replacement: String)] {
        guard let orderedLine, block.length > 0,
              NSMaxRange(block) <= source.length else { return [] }
        var lineStarts: [Int] = []
        var location = block.location
        while location < NSMaxRange(block) {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            lineStarts.append(paragraph.location)
            guard NSMaxRange(paragraph) > location else { break }
            location = NSMaxRange(paragraph)
        }
        var edits: [(NSRange, String)] = []
        var expected = 1
        var pending: [(NSRange, String)] = []
        for start in lineStarts {
            let paragraph = source.paragraphRange(for: NSRange(location: start, length: 0))
            let line = source.substring(with: paragraph)
            let lineRange = NSRange(location: 0, length: (line as NSString).length)
            guard let match = orderedLine.firstMatch(in: line, range: lineRange) else {
                expected = 1
                continue
            }
            let numberRange = match.range(at: 2)
            let current = (line as NSString).substring(with: numberRange)
            let wanted = String(expected)
            if current != wanted {
                pending.append((
                    NSRange(location: paragraph.location + numberRange.location, length: numberRange.length),
                    wanted
                ))
            }
            expected += 1
        }
        edits = pending.reversed()
        return edits
    }
}
