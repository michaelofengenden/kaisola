import AppKit
import Foundation
import SwiftUI

/// Small native Markdown document model. `Text(AttributedString(markdown:))`
/// renders inline emphasis but ignores most block presentation intents, which
/// is why headings, lists, quotes, tables, and fenced code previously collapsed
/// into an almost-plain paragraph. This parser preserves those structural
/// blocks while still delegating inline Markdown to Foundation.
struct MarkdownDocument: Equatable, Sendable {
    enum ContentAlignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String, alignment: ContentAlignment?)
        case paragraph(String, alignment: ContentAlignment?)
        case image(
            source: String,
            alt: String?,
            declaredWidth: Double?,
            declaredHeight: Double?,
            alignment: ContentAlignment?
        )
        case listItem(indent: Int, marker: String, text: String)
        case quote(String)
        case code(language: String?, text: String)
        case table(headers: [String], rows: [[String]], omittedRows: Int)
        case rule
    }

    let blocks: [Block]

    static func containsPresentationalHTML(_ source: String) -> Bool {
        source.range(
            of: #"(?is)<(?:p|h[1-6]|picture|img)\b"#,
            options: .regularExpression
        ) != nil
    }

    static func parse(_ source: String) -> MarkdownDocument {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [Block] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " "), alignment: nil))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let html = htmlBlock(in: lines, at: index) {
                flushParagraph()
                if let block = html.block { blocks.append(block) }
                index = html.nextIndex
                continue
            }
            if index + 1 < lines.count,
               let level = setextHeadingLevel(lines[index + 1]) {
                flushParagraph()
                blocks.append(.heading(level: level, text: trimmed, alignment: nil))
                index += 2
                continue
            }
            if let image = markdownImage(trimmed) {
                flushParagraph()
                blocks.append(image)
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let languageToken = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(
                    language: languageToken.isEmpty ? nil : languageToken,
                    text: code.joined(separator: "\n")
                ))
                continue
            }
            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text, alignment: nil))
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if let item = listItem(in: line) {
                flushParagraph()
                index += 1
                var text = [item.text]
                while index < lines.count {
                    let continuation = lines[index]
                    let continuationTrimmed = continuation.trimmingCharacters(in: .whitespaces)
                    guard !continuationTrimmed.isEmpty,
                          listItem(in: continuation) == nil,
                          leadingWhitespaceWidth(in: continuation) >= (item.indent * 2) + 2 else {
                        break
                    }
                    text.append(continuationTrimmed)
                    index += 1
                }
                blocks.append(.listItem(
                    indent: item.indent,
                    marker: item.marker,
                    text: text.joined(separator: " ")
                ))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quote.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if index + 1 < lines.count,
               line.contains("|"),
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let headers = tableCells(line)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                let visibleRows = Array(rows.prefix(100))
                blocks.append(.table(
                    headers: headers,
                    rows: visibleRows,
                    omittedRows: rows.count - visibleRows.count
                ))
                continue
            }
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return MarkdownDocument(blocks: blocks)
    }

    /// GitHub READMEs often use a small amount of presentational HTML for
    /// centered logos, headings, and link rows. Showing those tags verbatim is
    /// worse than ignoring their alignment, so translate the safe textual
    /// subset into the same native blocks used for Markdown. Common alignment
    /// and image dimensions are retained so a README logo does not expand into
    /// a full-width hero merely because it was authored with an HTML `<img>`.
    private static func htmlBlock(
        in lines: [String],
        at index: Int
    ) -> (block: Block?, nextIndex: Int)? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        for level in 1...6 where lower.hasPrefix("<h\(level)") {
            let closing = "</h\(level)>"
            let collected = collectHTML(lines: lines, from: index, closingTag: closing)
            let text = markdownFromHTML(collected.source)
            return (
                text.isEmpty ? nil : .heading(
                    level: level,
                    text: text,
                    alignment: alignmentFromHTML(collected.source)
                ),
                collected.nextIndex
            )
        }

        if lower.hasPrefix("<p") {
            let collected = collectHTML(lines: lines, from: index, closingTag: "</p>")
            let text = markdownFromHTML(collected.source)
            let alignment = alignmentFromHTML(collected.source)
            if !text.isEmpty {
                return (.paragraph(text, alignment: alignment), collected.nextIndex)
            }
            return (imageFromHTML(collected.source, inheritedAlignment: alignment), collected.nextIndex)
        }

        if lower.hasPrefix("<img") {
            return (imageFromHTML(trimmed, inheritedAlignment: nil), index + 1)
        }
        return nil
    }

    private static func imageFromHTML(
        _ html: String,
        inheritedAlignment: ContentAlignment?
    ) -> Block? {
        guard let expression = try? NSRegularExpression(
            pattern: #"<img\b[^>]*\bsrc=[\"']([^\"']+)[\"'][^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: full),
              let sourceRange = Range(match.range(at: 1), in: html) else { return nil }
        let source = String(html[sourceRange])
        let alt: String? = {
            guard let altExpression = try? NSRegularExpression(
                pattern: #"\balt=[\"']([^\"']*)[\"']"#,
                options: .caseInsensitive
            ),
            let altMatch = altExpression.firstMatch(in: html, range: full),
            let altRange = Range(altMatch.range(at: 1), in: html) else { return nil }
            let value = String(html[altRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }()
        return .image(
            source: source,
            alt: alt,
            declaredWidth: numericHTMLAttribute("width", in: html),
            declaredHeight: numericHTMLAttribute("height", in: html),
            alignment: inheritedAlignment ?? alignmentFromHTML(html)
        )
    }

    private static func numericHTMLAttribute(_ name: String, in html: String) -> Double? {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b\#(name)\s*=\s*(?:[\"']\s*)?([0-9]+(?:\.[0-9]+)?)(?:\s*[\"'])?"#,
            options: .caseInsensitive
        ) else { return nil }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: full),
              let valueRange = Range(match.range(at: 1), in: html),
              let value = Double(html[valueRange]),
              value.isFinite,
              value > 0 else { return nil }
        return min(value, 20_000)
    }

    private static func alignmentFromHTML(_ html: String) -> ContentAlignment? {
        guard let expression = try? NSRegularExpression(
            pattern: #"\balign\s*=\s*[\"']?(left|center|right)[\"']?"#,
            options: .caseInsensitive
        ) else { return nil }
        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: full),
              let valueRange = Range(match.range(at: 1), in: html) else { return nil }
        switch html[valueRange].lowercased() {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private static func collectHTML(
        lines: [String],
        from start: Int,
        closingTag: String
    ) -> (source: String, nextIndex: Int) {
        var fragments: [String] = []
        var cursor = start
        while cursor < lines.count {
            fragments.append(lines[cursor].trimmingCharacters(in: .whitespaces))
            cursor += 1
            if fragments.last?.lowercased().contains(closingTag) == true { break }
        }
        return (fragments.joined(separator: " "), cursor)
    }

    private static func markdownFromHTML(_ html: String) -> String {
        var value = html
        value = replacingHTML(value, pattern: #"<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#, with: "[$2]($1)")
        value = replacingHTML(value, pattern: #"<strong\b[^>]*>(.*?)</strong>"#, with: "**$1**")
        value = replacingHTML(value, pattern: #"<b\b[^>]*>(.*?)</b>"#, with: "**$1**")
        value = replacingHTML(value, pattern: #"<em\b[^>]*>(.*?)</em>"#, with: "*$1*")
        value = replacingHTML(value, pattern: #"<i\b[^>]*>(.*?)</i>"#, with: "*$1*")
        value = replacingHTML(value, pattern: #"<code\b[^>]*>(.*?)</code>"#, with: "`$1`")
        value = replacingHTML(value, pattern: #"<img\b[^>]*>"#, with: "")
        value = replacingHTML(value, pattern: #"<br\s*/?>"#, with: " ")
        value = replacingHTML(value, pattern: #"<[^>]+>"#, with: "")
        value = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        value = replacingHTML(value, pattern: #"\s+"#, with: " ")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingHTML(_ value: String, pattern: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func setextHeadingLevel(_ line: String) -> Int? {
        let compact = line.trimmingCharacters(in: .whitespaces)
        guard compact.count >= 3, let marker = compact.first,
              marker == "=" || marker == "-",
              compact.allSatisfy({ $0 == marker }) else { return nil }
        return marker == "=" ? 1 : 2
    }

    private static func markdownImage(_ line: String) -> Block? {
        guard let expression = try? NSRegularExpression(
            pattern: #"^!\[([^\]]*)\]\((<?[^\s>]+>?)(?:\s+[\"'][^\"']*[\"'])?\)$"#
        ) else { return nil }
        let full = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: full),
              let altRange = Range(match.range(at: 1), in: line),
              let sourceRange = Range(match.range(at: 2), in: line) else { return nil }
        let altValue = String(line[altRange]).trimmingCharacters(in: .whitespaces)
        let source = String(line[sourceRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !source.isEmpty else { return nil }
        return .image(
            source: source,
            alt: altValue.isEmpty ? nil : altValue,
            declaredWidth: nil,
            declaredHeight: nil,
            alignment: nil
        )
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(in line: String) -> (indent: Int, marker: String, text: String)? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leadingWhitespaceWidth(in: String(leading)) / 2
        let body = line.dropFirst(leading.count)
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return (indent, "•", String(body.dropFirst(2)))
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, body.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (indent, "\(digits).", String(body.dropFirst(digits.count + 2)))
    }

    private static func leadingWhitespaceWidth(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
    }

    private static func tableCells(_ line: String) -> [String] {
        MarkdownTableSource.values(in: line)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }
}

struct MarkdownTableSourceCell: Equatable, Sendable {
    let row: Int
    let column: Int
    let range: NSRange
    let text: String
}

/// Exact cell ranges for a GitHub-style Markdown table. Separator syntax and
/// cosmetic padding are not part of the editable range, so changing one cell
/// cannot reformat the table or normalize the document's line endings.
enum MarkdownTableSource {
    /// Where a single table line's pipes and cells actually are.
    ///
    /// The continuous editor styles a table by kerning the padding that already
    /// sits between these pipes, so it needs the separators as well as the cell
    /// content — the same scan the block editor used for exact-range writes.
    struct LineLayout: Equatable, Sendable {
        /// Whitespace-trimmed content range of each cell, local to the line.
        let cells: [NSRange]
        /// Every unescaped `|` in the line, local to the line.
        let pipes: [Int]
        let hasLeadingPipe: Bool
        let hasTrailingPipe: Bool
    }

    static func layout(of line: String) -> LineLayout {
        let value = line as NSString
        guard value.length > 0 else {
            return LineLayout(cells: [], pipes: [], hasLeadingPipe: false, hasTrailingPipe: false)
        }
        var delimiters: [Int] = []
        var backslashes = 0
        for index in 0..<value.length {
            let character = value.character(at: index)
            if character == 0x5C {
                backslashes += 1
                continue
            }
            if character == 0x7C, backslashes.isMultiple(of: 2) {
                delimiters.append(index)
            }
            backslashes = 0
        }

        func isWhitespace(_ character: unichar) -> Bool {
            character == 0x20 || character == 0x09
        }
        var firstContent = 0
        while firstContent < value.length, isWhitespace(value.character(at: firstContent)) {
            firstContent += 1
        }
        var lastContent = value.length
        while lastContent > firstContent, isWhitespace(value.character(at: lastContent - 1)) {
            lastContent -= 1
        }
        let hasLeadingPipe = delimiters.first == firstContent
        // One lone `|` is both the first and the last delimiter; it can only be
        // one of the two, or the caller would kern the same character twice.
        let hasTrailingPipe = delimiters.last == lastContent - 1
            && !(hasLeadingPipe && delimiters.count == 1)
        var separators = delimiters
        var cellStart = 0
        if hasLeadingPipe, let leading = separators.first {
            cellStart = leading + 1
            separators.removeFirst()
        }
        let cellEnd = hasTrailingPipe ? (separators.last ?? value.length) : value.length
        if hasTrailingPipe, !separators.isEmpty { separators.removeLast() }

        var cells: [NSRange] = []
        for separator in separators + [cellEnd] {
            guard separator >= cellStart else { continue }
            var start = cellStart
            var end = separator
            while start < end, isWhitespace(value.character(at: start)) { start += 1 }
            while end > start, isWhitespace(value.character(at: end - 1)) { end -= 1 }
            cells.append(NSRange(location: start, length: end - start))
            cellStart = separator + 1
        }
        return LineLayout(
            cells: cells,
            pipes: delimiters,
            hasLeadingPipe: hasLeadingPipe,
            hasTrailingPipe: hasTrailingPipe
        )
    }

    static func values(in line: String) -> [String] {
        localCellRanges(in: line).map { range in
            decodeCell((line as NSString).substring(with: range))
        }
    }

    static func cells(in block: MarkdownSourceBlock) -> [MarkdownTableSourceCell] {
        guard case .table = block.block else { return [] }
        let source = block.source as NSString
        var result: [MarkdownTableSourceCell] = []
        var lineLocation = 0
        var physicalRow = 0
        while lineLocation < source.length {
            let fullRange = source.lineRange(for: NSRange(location: lineLocation, length: 0))
            var contentEnd = NSMaxRange(fullRange)
            while contentEnd > fullRange.location {
                let character = source.character(at: contentEnd - 1)
                guard character == 0x0A || character == 0x0D else { break }
                contentEnd -= 1
            }
            let lineRange = NSRange(
                location: fullRange.location,
                length: contentEnd - fullRange.location
            )
            if physicalRow != 1 {
                let line = source.substring(with: lineRange)
                let logicalRow = physicalRow == 0 ? 0 : physicalRow - 1
                for (column, localRange) in localCellRanges(in: line).enumerated() {
                    result.append(MarkdownTableSourceCell(
                        row: logicalRow,
                        column: column,
                        range: NSRange(
                            location: block.range.location + lineRange.location + localRange.location,
                            length: localRange.length
                        ),
                        text: decodeCell((line as NSString).substring(with: localRange))
                    ))
                }
            }
            physicalRow += 1
            lineLocation = NSMaxRange(fullRange)
        }
        return result
    }

    static func replacingCell(
        row: Int,
        column: Int,
        in block: MarkdownSourceBlock,
        source: String,
        with replacement: String
    ) -> String? {
        guard let cell = cells(in: block).first(where: {
            $0.row == row && $0.column == column
        }) else { return nil }
        let normalized = replacement
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return MarkdownSourceDocument.replacing(
            cell.range,
            in: source,
            with: encodeCell(normalized)
        )
    }

    private static func localCellRanges(in line: String) -> [NSRange] {
        layout(of: line).cells
    }

    private static func decodeCell(_ source: String) -> String {
        var result = ""
        var escaped = false
        for character in source {
            if escaped {
                if character == "|" || character == "\\" { result.append(character) }
                else {
                    result.append("\\")
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func encodeCell(_ value: String) -> String {
        var result = ""
        for character in value {
            if character == "\\" || character == "|" { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// Exact UTF-16 source ranges paired with the structural blocks shown by the
/// native Markdown reader. A block editor replaces only this range in the
/// original string, so line endings, unsupported syntax, comments, and every
/// byte outside the active block remain untouched.
struct MarkdownSourceBlock: Equatable, Identifiable, Sendable {
    let range: NSRange
    let source: String
    let block: MarkdownDocument.Block

    var id: Int { range.location }
}

enum MarkdownSourceDocument {
    private struct Line {
        let text: String
        let contentRange: NSRange
    }

    static func blocks(in source: String) -> [MarkdownSourceBlock] {
        let nsSource = source as NSString
        let lines = sourceLines(in: nsSource)
        guard !lines.isEmpty else { return [] }
        var result: [MarkdownSourceBlock] = []
        var index = 0

        func append(_ start: Int, _ endExclusive: Int) {
            guard start < endExclusive else { return }
            let startLocation = lines[start].contentRange.location
            let endLocation = NSMaxRange(lines[endExclusive - 1].contentRange)
            guard endLocation >= startLocation else { return }
            let range = NSRange(location: startLocation, length: endLocation - startLocation)
            let fragment = nsSource.substring(with: range)
            let parsed = MarkdownDocument.parse(fragment).blocks
            let block = parsed.first ?? .paragraph(
                fragment.trimmingCharacters(in: .whitespacesAndNewlines),
                alignment: nil
            )
            result.append(MarkdownSourceBlock(range: range, source: fragment, block: block))
        }

        while index < lines.count {
            if isBlank(lines[index].text) {
                index += 1
                continue
            }
            let start = index
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)

            if let closing = htmlClosingTag(for: trimmed) {
                index += 1
                if !trimmed.lowercased().contains(closing) {
                    while index < lines.count {
                        let found = lines[index].text.lowercased().contains(closing)
                        index += 1
                        if found { break }
                    }
                }
                append(start, index)
                continue
            }
            if isFence(trimmed) {
                let fence = String(trimmed.prefix(3))
                index += 1
                while index < lines.count {
                    let closed = lines[index].text
                        .trimmingCharacters(in: .whitespaces)
                        .hasPrefix(fence)
                    index += 1
                    if closed { break }
                }
                append(start, index)
                continue
            }
            if index + 1 < lines.count, isSetextRule(lines[index + 1].text) {
                index += 2
                append(start, index)
                continue
            }
            if index + 1 < lines.count,
               lines[index].text.contains("|"),
               isTableSeparator(lines[index + 1].text) {
                index += 2
                while index < lines.count,
                      !isBlank(lines[index].text),
                      lines[index].text.contains("|") {
                    index += 1
                }
                append(start, index)
                continue
            }
            if trimmed.hasPrefix(">") {
                index += 1
                while index < lines.count,
                      lines[index].text.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    index += 1
                }
                append(start, index)
                continue
            }
            if let listIndent = listItemIndent(lines[index].text) {
                index += 1
                while index < lines.count {
                    let candidate = lines[index].text
                    guard !isBlank(candidate),
                          listItemIndent(candidate) == nil,
                          leadingWhitespaceWidth(in: candidate) >= listIndent + 2 else {
                        break
                    }
                    index += 1
                }
                append(start, index)
                continue
            }
            if isSingleLineBlock(trimmed) {
                index += 1
                append(start, index)
                continue
            }

            index += 1
            while index < lines.count,
                  !isBlank(lines[index].text),
                  !startsStructuralBlock(lines: lines, at: index) {
                index += 1
            }
            append(start, index)
        }
        return result
    }

    static func replacing(_ range: NSRange, in source: String, with replacement: String) -> String? {
        let nsSource = source as NSString
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= nsSource.length else { return nil }
        return nsSource.replacingCharacters(in: range, with: replacement)
    }

    private static func sourceLines(in source: NSString) -> [Line] {
        guard source.length > 0 else { return [] }
        var result: [Line] = []
        var location = 0
        while location < source.length {
            let full = source.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(full)
            while contentEnd > full.location {
                let value = source.character(at: contentEnd - 1)
                guard value == 0x0A || value == 0x0D else { break }
                contentEnd -= 1
            }
            let contentRange = NSRange(
                location: full.location,
                length: contentEnd - full.location
            )
            result.append(Line(
                text: source.substring(with: contentRange),
                contentRange: contentRange
            ))
            location = NSMaxRange(full)
        }
        return result
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func htmlClosingTag(for trimmed: String) -> String? {
        let lower = trimmed.lowercased()
        for level in 1...6 where lower.hasPrefix("<h\(level)") {
            return "</h\(level)>"
        }
        return lower.hasPrefix("<p") ? "</p>" : nil
    }

    private static func startsStructuralBlock(lines: [Line], at index: Int) -> Bool {
        let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
        if htmlClosingTag(for: trimmed) != nil || isFence(trimmed)
            || isSingleLineBlock(trimmed) || trimmed.hasPrefix(">") {
            return true
        }
        if index + 1 < lines.count, isSetextRule(lines[index + 1].text) { return true }
        return index + 1 < lines.count
            && lines[index].text.contains("|")
            && isTableSeparator(lines[index + 1].text)
    }

    private static func isSingleLineBlock(_ trimmed: String) -> Bool {
        if trimmed.range(of: #"^#{1,6}[ \t]+"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"^!\[[^\]]*\]\("#, options: .regularExpression) != nil { return true }
        if trimmed.lowercased().hasPrefix("<img") { return true }
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func listItemIndent(_ line: String) -> Int? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(leading.count)
        let isBullet = ["- ", "* ", "+ "].contains { body.hasPrefix($0) }
        let digits = body.prefix { $0.isNumber }
        let isOrdered = !digits.isEmpty && body.dropFirst(digits.count).hasPrefix(". ")
        return isBullet || isOrdered ? leadingWhitespaceWidth(in: line) : nil
    }

    private static func leadingWhitespaceWidth(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
    }

    private static func isSetextRule(_ line: String) -> Bool {
        let compact = line.trimmingCharacters(in: .whitespaces)
        guard compact.count >= 3, let marker = compact.first,
              marker == "=" || marker == "-" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        let cells = value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy { $0 == "-" }
        }
    }
}

/// A view-lifetime cache for the exact structural projection. SwiftUI can
/// recompute `body` many times during a pinch or panel resize; reparsing the
/// same large Markdown string on every frame turns an otherwise linear parser
/// into visible interaction jank.
final class MarkdownSourceBlockCache {
    private var source: String?
    private var cachedBlocks: [MarkdownSourceBlock] = []
    private(set) var parseCount = 0

    func blocks(for source: String) -> [MarkdownSourceBlock] {
        guard self.source != source else { return cachedBlocks }
        self.source = source
        cachedBlocks = MarkdownSourceDocument.blocks(in: source)
        parseCount += 1
        return cachedBlocks
    }
}

/// Responsive measurements shared by the rendered Markdown surface and its
/// tests. The document keeps a comfortable reading measure on a wide canvas,
/// but yields every point needed by a narrow split instead of creating a
/// hidden horizontal overflow. HTML image dimensions are treated as preferred
/// sizes, then scaled down to the live content width while preserving aspect.
enum MarkdownPreviewLayout {
    static let maximumReadableWidth: CGFloat = 760
    static let minimumZoom: CGFloat = 0.65
    static let maximumZoom: CGFloat = 2

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(maximumZoom, max(minimumZoom, zoom))
    }

    static func magnifiedZoom(start: CGFloat, gestureScale: CGFloat) -> CGFloat {
        clampedZoom(start * gestureScale)
    }

    static func horizontalInset(viewportWidth: CGFloat) -> CGFloat {
        switch viewportWidth {
        case ..<360: 12
        case ..<560: 18
        default: 28
        }
    }

    static func contentWidth(viewportWidth: CGFloat) -> CGFloat {
        let viewport = max(1, viewportWidth)
        let inset = horizontalInset(viewportWidth: viewport)
        return max(1, min(maximumReadableWidth, viewport - inset * 2))
    }

    static func imageSize(
        intrinsicSize: CGSize,
        declaredWidth: Double?,
        declaredHeight: Double?,
        availableWidth: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        let intrinsicWidth = max(1, intrinsicSize.width)
        let intrinsicHeight = max(1, intrinsicSize.height)
        let safeZoom = max(0.01, zoom)
        let preferredWidth: CGFloat
        let aspectRatio: CGFloat

        if let declaredWidth, let declaredHeight {
            preferredWidth = CGFloat(declaredWidth) * safeZoom
            aspectRatio = CGFloat(declaredHeight / declaredWidth)
        } else if let declaredWidth {
            preferredWidth = CGFloat(declaredWidth) * safeZoom
            aspectRatio = intrinsicHeight / intrinsicWidth
        } else if let declaredHeight {
            aspectRatio = intrinsicHeight / intrinsicWidth
            preferredWidth = CGFloat(declaredHeight) * safeZoom / aspectRatio
        } else {
            preferredWidth = intrinsicWidth * safeZoom
            aspectRatio = intrinsicHeight / intrinsicWidth
        }

        let width = max(1, min(max(1, availableWidth), preferredWidth))
        return CGSize(width: width, height: max(1, width * aspectRatio))
    }
}

/// Presentation-only typography for rendered inline Markdown. Source remains
/// byte-for-byte untouched; this merely prevents separator punctuation from
/// becoming the first glyph on a wrapped line in narrow document panes.
enum MarkdownInlinePresentation {
    static func preventingOrphanedSeparators(_ source: String) -> String {
        source.replacingOccurrences(of: " · ", with: "\u{00A0}· ")
    }
}

enum MarkdownTableNavigation {
    enum Direction { case left, right, up, down }

    struct Position: Equatable {
        let row: Int
        let column: Int
    }

    static func destination(
        from position: Position,
        direction: Direction,
        rows: [[String]]
    ) -> Position? {
        guard rows.indices.contains(position.row),
              rows[position.row].indices.contains(position.column) else { return nil }
        let candidate: Position
        switch direction {
        case .left:
            candidate = Position(row: position.row, column: position.column - 1)
        case .right:
            candidate = Position(row: position.row, column: position.column + 1)
        case .up:
            candidate = Position(row: position.row - 1, column: position.column)
        case .down:
            candidate = Position(row: position.row + 1, column: position.column)
        }
        guard rows.indices.contains(candidate.row),
              rows[candidate.row].indices.contains(candidate.column) else { return nil }
        return candidate
    }
}

/// The continuous Markdown surface: one editor over the whole document.
///
/// This replaced a rendered document whose blocks were swapped one at a time
/// for a small embedded text editor on double-click. That model cost the reader
/// twice. Editing was per block: every change was committed into an exact
/// source range and the editor had to be re-entered for the next paragraph.
/// And the viewport jumped, because a `LazyVStack` identified each block by its
/// source location, so any keystroke that changed a block's length
/// re-identified every block below it and tore the stack down underneath the
/// scroll view.
///
/// The document is now a single `NSTextView` holding the file's exact Markdown,
/// styled in place so it reads like prose. It owns its text storage, selection,
/// and scroll position, so typing, saving, autosaving, and reconciling an
/// unchanged file on disk cost the viewport nothing.
///
/// Byte fidelity came out stronger rather than weaker: there is no source-range
/// write path left to get wrong, because the bytes on screen are the bytes that
/// are saved. Styling is applied as TextKit temporary attributes and images are
/// painted by the layout manager, so neither ever reaches the text storage.
struct MarkdownDocumentView: View {
    @Binding var source: String
    let documentURL: URL
    let workspaceRoot: URL?
    let imageRevision: Int
    @Binding var zoom: CGFloat
    let onError: (String) -> Void
    /// Shared with the raw-source editor so the source toggle keeps its place.
    var scrollMemory: FilePreviewTextScrollMemory? = nil
    var targetLine: Int? = nil
    var navigationRevision: UInt64 = 0
    /// Visual fixtures open with the caret already placed, so a capture proves
    /// the editable surface rather than a static rendering.
    var automaticallyFocus = false

    var body: some View {
        MarkdownRenderedEditor(
            text: $source,
            markdownURL: documentURL,
            workspaceRoot: workspaceRoot,
            zoom: $zoom,
            targetLine: targetLine,
            onError: onError,
            documentID: documentURL.standardizedFileURL.path,
            scrollMemory: scrollMemory,
            imageRevision: imageRevision,
            navigationRevision: navigationRevision,
            automaticallyFocus: automaticallyFocus,
            onOpenLink: open
        )
        .background {
            MarkdownCommandScrollZoomBridge(zoom: $zoom)
        }
    }

    /// Command-clicking a Markdown link follows it under the same policy the
    /// rendered document used: project files open in Kaisola, external schemes
    /// go to the system browser, everything else is refused.
    private func open(_ link: URL) {
        switch WorkspacePreviewLinkPolicy.decision(
            for: link,
            documentURL: documentURL,
            workspaceRoot: workspaceRoot
        ) {
        case let .external(url):
            NSWorkspace.shared.open(url)
        case let .workspaceFile(url, line):
            var userInfo: [AnyHashable: Any] = [
                "url": url,
                "workspaceHint": workspaceRoot
                    ?? documentURL.deletingLastPathComponent(),
            ]
            if let line { userInfo["line"] = line }
            NotificationCenter.default.post(
                name: .kaisolaOpenFileLink,
                object: nil,
                userInfo: userInfo
            )
        case .blocked:
            onError(
                "Kaisola blocked a Markdown link outside this project or using an unsupported scheme."
            )
        }
    }
}

enum MarkdownTableTruncation {
    static func message(omittedRows: Int) -> String {
        let noun = omittedRows == 1 ? "row" : "rows"
        return "\(omittedRows) more \(noun) not shown"
    }
}
