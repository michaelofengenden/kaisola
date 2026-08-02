import AppKit
import CoreText
import Foundation

/// Renders GitHub-style pipe tables and thematic breaks *as* a grid and a rule
/// inside the one continuous Markdown editor.
///
/// The rule this whole surface lives by is that the document's bytes are the
/// bytes on screen. So nothing here builds a table widget, swaps a block, or
/// rewrites a row: the pipes, dashes and padding stay exactly where the author
/// typed them, and the grid is produced entirely by *attributes* —
/// `.kern` on the padding runs so every column lands on the same x, a dimmed
/// colour on the pipes so they read as the vertical rules they already look
/// like, and a collapsed delimiter row with a hairline drawn behind it.
///
/// Typing inside a table is therefore ordinary typing: the caret is in the same
/// text view, over the same characters, and the columns re-measure on the next
/// debounced styling pass.

// MARK: - Regions

enum MarkdownTableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

/// One source line of a pipe table, located exactly in the document.
struct MarkdownTableRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case header
        /// The `|---|:--:|` line. Kept in the document, drawn as a rule.
        case delimiter
        case body
    }

    let kind: Kind
    /// The line's content range, excluding its terminator.
    let lineRange: NSRange
    let hasLeadingPipe: Bool
    let hasTrailingPipe: Bool
    /// Absolute indices of the unescaped pipes this line draws.
    let pipes: [Int]
    /// Absolute, whitespace-trimmed content range of each cell.
    let cells: [NSRange]

    /// The pipe drawn immediately before cell `index`, if the line has one.
    func precedingPipe(ofCell index: Int) -> Int? {
        if hasLeadingPipe {
            return index < pipes.count ? pipes[index] : nil
        }
        guard index > 0, index - 1 < pipes.count else { return nil }
        return pipes[index - 1]
    }

    var trailingPipe: Int? { hasTrailingPipe ? pipes.last : nil }

    /// The pipe drawn immediately after cell `index`, if the line has one.
    func followingPipe(ofCell index: Int) -> Int? {
        index + 1 < cells.count ? precedingPipe(ofCell: index + 1) : trailingPipe
    }
}

struct MarkdownTableRegion: Equatable, Sendable {
    /// First character of the header line through the last character of the
    /// final row, terminators excluded.
    let range: NSRange
    let rows: [MarkdownTableRow]
    let alignments: [MarkdownTableAlignment]

    var columnCount: Int { alignments.count }
}

/// Finds the pipe tables in a Markdown source.
///
/// Deliberately strict about what counts as a table — a delimiter row whose
/// column count matches its header, as GitHub requires — because a false
/// positive would re-align prose that the author never meant as a table.
enum MarkdownTableRegions {
    /// Bounded so a pathological document cannot make a styling pass unbounded
    /// work, matching `MarkdownInlineImages.maximumLines`.
    static let maximumTables = 128
    static let maximumRowsPerTable = 512

    static func scan(_ source: String) -> [MarkdownTableRegion] {
        let lines = MarkdownSourceLines.scan(source)
        guard !lines.isEmpty else { return [] }

        var regions: [MarkdownTableRegion] = []
        var index = 0
        while index < lines.count, regions.count < maximumTables {
            guard !lines[index].isFenced,
                  index + 1 < lines.count,
                  !lines[index + 1].isFenced else {
                index += 1
                continue
            }
            let header = lines[index]
            let headerLayout = MarkdownTableSource.layout(of: header.text)
            guard !headerLayout.pipes.isEmpty, !headerLayout.cells.isEmpty else {
                index += 1
                continue
            }
            guard let alignments = delimiterAlignments(in: lines[index + 1].text),
                  alignments.count == headerLayout.cells.count else {
                index += 1
                continue
            }

            var rows = [
                row(kind: .header, line: header, layout: headerLayout),
                row(
                    kind: .delimiter,
                    line: lines[index + 1],
                    layout: MarkdownTableSource.layout(of: lines[index + 1].text)
                ),
            ]
            var last = index + 1
            var cursor = index + 2
            while cursor < lines.count, rows.count < maximumRowsPerTable {
                let candidate = lines[cursor]
                guard !candidate.isFenced, !candidate.text.trimmingCharacters(
                    in: .whitespaces
                ).isEmpty else { break }
                let layout = MarkdownTableSource.layout(of: candidate.text)
                guard !layout.pipes.isEmpty, !layout.cells.isEmpty else { break }
                rows.append(row(kind: .body, line: candidate, layout: layout))
                last = cursor
                cursor += 1
            }

            let start = header.contentRange.location
            let end = NSMaxRange(lines[last].contentRange)
            regions.append(
                MarkdownTableRegion(
                    range: NSRange(location: start, length: max(0, end - start)),
                    rows: rows,
                    alignments: alignments
                )
            )
            index = cursor
        }
        return regions
    }

    private static func row(
        kind: MarkdownTableRow.Kind,
        line: MarkdownSourceLines.Line,
        layout: MarkdownTableSource.LineLayout
    ) -> MarkdownTableRow {
        let origin = line.contentRange.location
        return MarkdownTableRow(
            kind: kind,
            lineRange: line.contentRange,
            hasLeadingPipe: layout.hasLeadingPipe,
            hasTrailingPipe: layout.hasTrailingPipe,
            pipes: layout.pipes.map { $0 + origin },
            cells: layout.cells.map {
                NSRange(location: $0.location + origin, length: $0.length)
            }
        )
    }

    /// `| :--- | ---: | :--: |` → per-column alignment, or `nil` when the line
    /// is not a delimiter row at all.
    static func delimiterAlignments(in line: String) -> [MarkdownTableAlignment]? {
        let layout = MarkdownTableSource.layout(of: line)
        guard !layout.cells.isEmpty else { return nil }
        let value = line as NSString
        var result: [MarkdownTableAlignment] = []
        for range in layout.cells {
            var cell = value.substring(with: range)
            guard !cell.isEmpty else { return nil }
            let leading = cell.hasPrefix(":")
            if leading { cell.removeFirst() }
            let trailing = cell.hasSuffix(":")
            if trailing { cell.removeLast() }
            guard !cell.isEmpty, cell.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leading, trailing) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }
}

/// Lines that render as a horizontal rule while keeping their characters.
///
/// A `---` directly under a paragraph is a Setext heading underline rather than
/// a break, and a `---` on line one opens YAML front matter. Both keep their
/// literal source, because drawing a rule there would be a lie about what the
/// document says.
enum MarkdownThematicBreaks {
    static func scan(_ source: String) -> [NSRange] {
        let lines = MarkdownSourceLines.scan(source)
        guard !lines.isEmpty else { return [] }

        var frontMatterEnd = -1
        if lines[0].text.trimmingCharacters(in: .whitespaces) == "---" {
            for index in 1..<lines.count
            where lines[index].text.trimmingCharacters(in: .whitespaces) == "---" {
                frontMatterEnd = index
                break
            }
            if frontMatterEnd < 0 { frontMatterEnd = 0 }
        }

        var result: [NSRange] = []
        for (index, line) in lines.enumerated() {
            guard index > frontMatterEnd || frontMatterEnd < 0, !line.isFenced else { continue }
            let compact = line.text.filter { !$0.isWhitespace }
            guard compact.count >= 3, let marker = compact.first,
                  marker == "-" || marker == "*" || marker == "_",
                  compact.allSatisfy({ $0 == marker }) else { continue }
            // Only `-` is ambiguous: `***` and `___` can never underline a
            // Setext heading.
            if marker == "-" {
                let previous = index > 0
                    ? lines[index - 1].text.trimmingCharacters(in: .whitespaces)
                    : ""
                guard previous.isEmpty else { continue }
            }
            result.append(line.contentRange)
        }
        return result
    }
}

/// Shared line enumeration with fenced-code awareness.
enum MarkdownSourceLines {
    struct Line: Equatable, Sendable {
        /// Content range, excluding the line terminator.
        let contentRange: NSRange
        let text: String
        /// Inside a ``` or ~~~ fence, including the fence lines themselves.
        let isFenced: Bool
    }

    static func scan(_ source: String) -> [Line] {
        let value = source as NSString
        guard value.length > 0 else { return [] }
        var result: [Line] = []
        var location = 0
        var fence: String?
        while location < value.length {
            let full = value.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(full)
            var end = NSMaxRange(full)
            while end > full.location {
                let character = value.character(at: end - 1)
                guard character == 0x0A || character == 0x0D else { break }
                end -= 1
            }
            let contentRange = NSRange(location: full.location, length: end - full.location)
            let text = value.substring(with: contentRange)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            var fenced = fence != nil
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") {
                fence = "```"
                fenced = true
            } else if trimmed.hasPrefix("~~~") {
                fence = "~~~"
                fenced = true
            }
            result.append(Line(contentRange: contentRange, text: text, isFenced: fenced))
        }
        return result
    }
}

// MARK: - Geometry

/// Turns measured cell widths into the `.kern` deltas that push every column
/// onto a shared x position.
///
/// Pure arithmetic on purpose. Screenshots of this surface are unavailable, so
/// alignment is proved by asserting the positions this planner computes and by
/// replaying its own adjustments across each row.
enum MarkdownTableGeometry {
    /// One measured cell plus the padding runs on either side of it.
    struct MeasuredCell: Equatable, Sendable {
        let content: NSRange
        let contentWidth: CGFloat
        /// Whitespace between the preceding pipe (or the line start) and the
        /// content. May be empty.
        let leadingGap: NSRange
        let leadingGapWidth: CGFloat
        /// Whitespace between the content and the next pipe. May be empty.
        let trailingGap: NSRange
        let trailingGapWidth: CGFloat
        /// The pipe drawn immediately before this cell, if the line has one.
        let precedingPipe: Int?
    }

    struct MeasuredRow: Equatable, Sendable {
        /// Delimiter rows are collapsed into a rule, so they neither contribute
        /// a column width nor receive adjustments.
        let isDelimiter: Bool
        let hasLeadingPipe: Bool
        let cells: [MeasuredCell]
        let trailingPipe: Int?
    }

    /// Extra advance to add after *every* character of `range`.
    struct Adjustment: Equatable, Sendable {
        let range: NSRange
        let kern: CGFloat
    }

    struct RowPlan: Equatable, Sendable {
        let headIndent: CGFloat
        let adjustments: [Adjustment]
        /// Where each pipe this row draws ends up, left to right.
        let separatorPositions: [CGFloat]
    }

    struct Plan: Equatable, Sendable {
        let columnWidths: [CGFloat]
        let columnOrigins: [CGFloat]
        let totalWidth: CGFloat
        let rows: [RowPlan]
    }

    static func plan(
        rows: [MeasuredRow],
        alignments: [MarkdownTableAlignment],
        pipeWidth: CGFloat,
        padding: CGFloat
    ) -> Plan {
        let columnCount = rows.reduce(0) { max($0, $1.cells.count) }
        guard columnCount > 0 else {
            return Plan(columnWidths: [], columnOrigins: [], totalWidth: 0, rows: [])
        }

        var columnWidths = [CGFloat](repeating: 0, count: columnCount)
        for row in rows where !row.isDelimiter {
            for (column, cell) in row.cells.enumerated() {
                columnWidths[column] = max(columnWidths[column], cell.contentWidth)
            }
        }

        let leadingPipeWidth = rows.contains { $0.hasLeadingPipe } ? pipeWidth : 0
        var columnOrigins = [CGFloat](repeating: 0, count: columnCount)
        columnOrigins[0] = leadingPipeWidth + padding
        for column in 1..<columnCount {
            columnOrigins[column] = columnOrigins[column - 1]
                + columnWidths[column - 1]
                + padding
                + pipeWidth
                + padding
        }
        let hasTrailingPipe = rows.contains { $0.trailingPipe != nil }
        let totalWidth = columnOrigins[columnCount - 1]
            + columnWidths[columnCount - 1]
            + padding
            + (hasTrailingPipe ? pipeWidth : 0)

        let plans = rows.map { row in
            self.plan(
                row: row,
                columnWidths: columnWidths,
                columnOrigins: columnOrigins,
                alignments: alignments,
                pipeWidth: pipeWidth,
                padding: padding
            )
        }
        return Plan(
            columnWidths: columnWidths,
            columnOrigins: columnOrigins,
            totalWidth: totalWidth,
            rows: plans
        )
    }

    private struct Run {
        let range: NSRange
        /// Padding runs spread their correction over every space, so the caret
        /// keeps moving forward through them. Everything else takes the whole
        /// correction on its last character.
        let distributes: Bool
    }

    private static func plan(
        row: MeasuredRow,
        columnWidths: [CGFloat],
        columnOrigins: [CGFloat],
        alignments: [MarkdownTableAlignment],
        pipeWidth: CGFloat,
        padding: CGFloat
    ) -> RowPlan {
        guard !row.isDelimiter, !row.cells.isEmpty else {
            return RowPlan(headIndent: 0, adjustments: [], separatorPositions: [])
        }

        var cursor: CGFloat = 0
        var headIndent: CGFloat = 0
        var separators: [CGFloat] = []
        var deltas: [NSRange: CGFloat] = [:]
        var previous: Run?

        // Shifting everything after a character is what `.kern` does, so any
        // preceding run can carry the correction; the nearest one keeps the
        // shift local and invisible.
        func require(_ target: CGFloat) {
            let delta = target - cursor
            cursor = target
            guard abs(delta) > 0.0001 else { return }
            guard let previous else {
                headIndent += delta
                return
            }
            if previous.distributes, previous.range.length > 1 {
                deltas[previous.range, default: 0] += delta / CGFloat(previous.range.length)
            } else {
                let last = NSRange(location: NSMaxRange(previous.range) - 1, length: 1)
                deltas[last, default: 0] += delta
            }
        }

        func advance(_ range: NSRange, width: CGFloat, distributes: Bool) {
            guard range.length > 0 else { return }
            cursor += width
            previous = Run(range: range, distributes: distributes)
        }

        for (column, cell) in row.cells.enumerated() {
            if let pipe = cell.precedingPipe {
                separators.append(cursor)
                advance(NSRange(location: pipe, length: 1), width: pipeWidth, distributes: false)
            }
            advance(cell.leadingGap, width: cell.leadingGapWidth, distributes: true)

            let width = columnWidths[column]
            let alignment = column < alignments.count ? alignments[column] : .leading
            let slack = max(0, width - cell.contentWidth)
            let before: CGFloat
            switch alignment {
            case .leading: before = 0
            case .center: before = slack / 2
            case .trailing: before = slack
            }
            require(columnOrigins[column] + before)
            advance(cell.content, width: cell.contentWidth, distributes: false)
            advance(cell.trailingGap, width: cell.trailingGapWidth, distributes: true)
            require(columnOrigins[column] + width + padding)
        }
        if let trailing = row.trailingPipe {
            separators.append(cursor)
            advance(NSRange(location: trailing, length: 1), width: pipeWidth, distributes: false)
        }

        let adjustments = deltas
            .filter { abs($0.value) > 0.0001 }
            .map { Adjustment(range: $0.key, kern: $0.value) }
            .sorted { $0.range.location < $1.range.location }
        return RowPlan(
            headIndent: headIndent,
            adjustments: adjustments,
            separatorPositions: separators
        )
    }
}

// MARK: - Presentation constants

enum MarkdownTableStyle {
    /// Space between a column's vertical rule and its text, on each side.
    static let cellPadding: CGFloat = 10
    /// The point size a delimiter row and a thematic break collapse to. Small
    /// enough to read as a rule, large enough that the caret can still be put
    /// there and the characters typed over.
    static let rulePointSize: CGFloat = 6
    static let ruleThickness: CGFloat = 1
    /// Tables narrower than this after shrinking are left as plain source
    /// rather than clipped or wrapped mid-grid.
    static let minimumPointSize: CGFloat = 10.5

    static var pipeColor: NSColor { .separatorColor }
    static var ruleColor: NSColor { .separatorColor }
    static var headerFill: NSColor { .quaternaryLabelColor }

    static func rowFont(ofSize size: CGFloat, header: Bool) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: header ? .semibold : .regular)
    }

    /// `wraps` is the escape hatch for a table too wide to align: it keeps the
    /// row readable as ordinary wrapped source instead of clipping columns off
    /// the right edge where nobody could reach them.
    static func rowParagraphStyle(
        headIndent: CGFloat,
        isLast: Bool,
        wraps: Bool = false
    ) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        // Rows of one table sit together; the table as a whole keeps the
        // document's paragraph rhythm.
        paragraph.paragraphSpacing = isLast ? 8 : 0
        paragraph.firstLineHeadIndent = max(0, headIndent)
        paragraph.headIndent = max(0, headIndent)
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        return paragraph
    }

    static var ruleParagraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byClipping
        return paragraph
    }

    /// The attributes that collapse a delimiter row or a `---` break to a thin,
    /// blank strip. The characters are still there; they are simply not the
    /// thing being drawn.
    static var collapsedRuleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: rulePointSize),
            .foregroundColor: NSColor.clear,
            .paragraphStyle: ruleParagraphStyle,
            .kern: 0,
        ]
    }
}

// MARK: - Measurement

enum MarkdownTextMeasure {
    /// Rendered advance width of an attributed run, font fallback included.
    ///
    /// Core Text rather than `NSAttributedString.size()`: it reports the
    /// typographic width (trailing spaces included, which is exactly what a
    /// padding run is) and is safe to call away from AppKit's drawing stack.
    static func width(of attributed: NSAttributedString) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

// MARK: - Applying the grid to a text storage

/// Writes the table grid into a storage that already carries the document's
/// base typography and inline spans.
///
/// Split in two on purpose. `applyTypography` runs *before* the inline span
/// pass so a header cell's own `**bold**` or `` `code` `` still wins; the
/// geometry pass then runs *after* it and measures what the storage actually
/// resolved to, which is why a cell containing collapsed Markdown delimiters
/// still lands on the column.
enum MarkdownTableStyler {
    /// Row fonts and the collapsed rule rows. Bytes are never touched — every
    /// call here is `addAttributes`.
    static func applyTypography(
        regions: [MarkdownTableRegion],
        thematicBreaks: [NSRange],
        to storage: NSTextStorage
    ) {
        let length = storage.length
        for region in regions {
            for (index, row) in region.rows.enumerated() {
                guard NSMaxRange(row.lineRange) <= length, row.lineRange.length > 0 else { continue }
                guard row.kind != .delimiter else {
                    storage.addAttributes(
                        MarkdownTableStyle.collapsedRuleAttributes,
                        range: row.lineRange
                    )
                    continue
                }
                storage.addAttributes(
                    [
                        .font: MarkdownTableStyle.rowFont(
                            ofSize: MarkdownEditingStyle.bodySize,
                            header: row.kind == .header
                        ),
                        .paragraphStyle: MarkdownTableStyle.rowParagraphStyle(
                            headIndent: 0,
                            isLast: index == region.rows.count - 1,
                            wraps: true
                        ),
                    ],
                    range: row.lineRange
                )
            }
        }
        for range in thematicBreaks where NSMaxRange(range) <= length && range.length > 0 {
            storage.addAttributes(MarkdownTableStyle.collapsedRuleAttributes, range: range)
        }
    }

    /// Measure, align, and return what the layout manager should draw behind
    /// the text.
    static func applyGeometry(
        regions: [MarkdownTableRegion],
        thematicBreaks: [NSRange],
        to storage: NSTextStorage,
        availableWidth: CGFloat
    ) -> [MarkdownInlineImageLayoutManager.Decoration] {
        let length = storage.length
        let usable = max(120, availableWidth - 2)
        var decorations: [MarkdownInlineImageLayoutManager.Decoration] = []

        for region in regions {
            guard NSMaxRange(region.range) <= length else { continue }
            let pipeFont = NSFont.systemFont(ofSize: MarkdownEditingStyle.bodySize)
            for row in region.rows where row.kind != .delimiter {
                for pipe in row.pipes where pipe + 1 <= length {
                    storage.addAttributes(
                        [.font: pipeFont, .foregroundColor: MarkdownTableStyle.pipeColor],
                        range: NSRange(location: pipe, length: 1)
                    )
                }
            }

            var scale: CGFloat = 1
            var plan = self.plan(region: region, in: storage, pipeFont: pipeFont)
            var attempts = 0
            // A table wider than the pane is shrunk rather than clipped. Fonts
            // are *scaled*, not replaced, so inline code and emphasis inside a
            // cell keep their own face.
            while plan.totalWidth > usable, attempts < 2 {
                let floor = MarkdownTableStyle.minimumPointSize / MarkdownEditingStyle.bodySize
                let next = max(floor, scale * (usable / plan.totalWidth))
                guard next < scale - 0.01 else { break }
                scaleFonts(in: region.range, by: next / scale, storage: storage)
                scale = next
                plan = self.plan(region: region, in: storage, pipeFont: pipeFont.withSize(
                    MarkdownEditingStyle.bodySize * scale
                ))
                attempts += 1
            }

            let fits = plan.totalWidth <= usable
            let tableWidth = fits ? plan.totalWidth : usable
            for (index, row) in region.rows.enumerated() {
                guard row.kind != .delimiter, row.lineRange.length > 0,
                      index < plan.rows.count else { continue }
                let rowPlan = plan.rows[index]
                storage.addAttribute(
                    .paragraphStyle,
                    value: MarkdownTableStyle.rowParagraphStyle(
                        headIndent: fits ? rowPlan.headIndent : 0,
                        isLast: index == region.rows.count - 1,
                        wraps: !fits
                    ),
                    range: row.lineRange
                )
                guard fits else { continue }
                for adjustment in rowPlan.adjustments
                where NSMaxRange(adjustment.range) <= length {
                    storage.addAttribute(.kern, value: adjustment.kern, range: adjustment.range)
                }
            }

            if let header = region.rows.first, header.lineRange.length > 0 {
                decorations.append(
                    MarkdownInlineImageLayoutManager.Decoration(
                        characterIndex: header.lineRange.location,
                        width: tableWidth,
                        kind: .fill
                    )
                )
            }
            if let delimiter = region.rows.first(where: { $0.kind == .delimiter }),
               delimiter.lineRange.length > 0 {
                decorations.append(
                    MarkdownInlineImageLayoutManager.Decoration(
                        characterIndex: delimiter.lineRange.location,
                        width: tableWidth,
                        kind: .rule
                    )
                )
            }
        }

        for range in thematicBreaks where NSMaxRange(range) <= length && range.length > 0 {
            decorations.append(
                MarkdownInlineImageLayoutManager.Decoration(
                    characterIndex: range.location,
                    width: usable,
                    kind: .rule
                )
            )
        }
        return decorations
    }

    private static func plan(
        region: MarkdownTableRegion,
        in storage: NSTextStorage,
        pipeFont: NSFont
    ) -> MarkdownTableGeometry.Plan {
        let pipeWidth = MarkdownTextMeasure.width(
            of: NSAttributedString(string: "|", attributes: [.font: pipeFont])
        )
        let rows = region.rows.map { row -> MarkdownTableGeometry.MeasuredRow in
            guard row.kind != .delimiter else {
                return MarkdownTableGeometry.MeasuredRow(
                    isDelimiter: true,
                    hasLeadingPipe: row.hasLeadingPipe,
                    cells: [],
                    trailingPipe: nil
                )
            }
            let cells = row.cells.enumerated().map { index, content -> MarkdownTableGeometry.MeasuredCell in
                let preceding = row.precedingPipe(ofCell: index)
                let following = row.followingPipe(ofCell: index)
                let gapStart = preceding.map { $0 + 1 } ?? row.lineRange.location
                let leadingGap = NSRange(
                    location: gapStart,
                    length: max(0, content.location - gapStart)
                )
                let gapEnd = following ?? NSMaxRange(row.lineRange)
                let trailingGap = NSRange(
                    location: NSMaxRange(content),
                    length: max(0, gapEnd - NSMaxRange(content))
                )
                return MarkdownTableGeometry.MeasuredCell(
                    content: content,
                    contentWidth: width(of: content, in: storage),
                    leadingGap: leadingGap,
                    leadingGapWidth: width(of: leadingGap, in: storage),
                    trailingGap: trailingGap,
                    trailingGapWidth: width(of: trailingGap, in: storage),
                    precedingPipe: preceding
                )
            }
            return MarkdownTableGeometry.MeasuredRow(
                isDelimiter: false,
                hasLeadingPipe: row.hasLeadingPipe,
                cells: cells,
                trailingPipe: row.trailingPipe
            )
        }
        return MarkdownTableGeometry.plan(
            rows: rows,
            alignments: region.alignments,
            pipeWidth: pipeWidth,
            padding: MarkdownTableStyle.cellPadding
        )
    }

    private static func width(of range: NSRange, in storage: NSTextStorage) -> CGFloat {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return 0 }
        return MarkdownTextMeasure.width(of: storage.attributedSubstring(from: range))
    }

    private static func scaleFonts(in range: NSRange, by scale: CGFloat, storage: NSTextStorage) {
        guard NSMaxRange(range) <= storage.length, scale > 0, scale < 1 else { return }
        // Collected first: mutating the very attribute being enumerated is not
        // defined, and the whole point of scaling rather than replacing is that
        // inline code and emphasis inside a cell keep their own face.
        var scaled: [(NSRange, NSFont)] = []
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            scaled.append((subrange, font.withSize(max(0.1, font.pointSize * scale))))
        }
        for (subrange, font) in scaled {
            storage.addAttribute(.font, value: font, range: subrange)
        }
    }
}
