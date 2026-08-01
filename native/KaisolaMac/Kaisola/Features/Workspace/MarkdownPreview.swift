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
        let value = line as NSString
        guard value.length > 0 else { return [] }
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
        let hasTrailingPipe = delimiters.last == lastContent - 1
        var separators = delimiters
        var cellStart = 0
        if hasLeadingPipe, let leading = separators.first {
            cellStart = leading + 1
            separators.removeFirst()
        }
        let cellEnd = hasTrailingPipe ? (separators.last ?? value.length) : value.length
        if hasTrailingPipe, !separators.isEmpty { separators.removeLast() }

        var ranges: [NSRange] = []
        for separator in separators + [cellEnd] {
            guard separator >= cellStart else { continue }
            var start = cellStart
            var end = separator
            while start < end, isWhitespace(value.character(at: start)) { start += 1 }
            while end > start, isWhitespace(value.character(at: end - 1)) { end -= 1 }
            ranges.append(NSRange(location: start, length: end - start))
            cellStart = separator + 1
        }
        return ranges
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

private struct MarkdownTableCellID: Hashable {
    let blockLocation: Int
    let row: Int
    let column: Int
}

/// Own hover state at block granularity. Keeping it on the parent document
/// invalidated every rendered block whenever scrolling moved a new block under
/// a stationary pointer; image decoding and Markdown layout then fought native
/// scroll momentum. Local state redraws only the affected block chrome.
private struct MarkdownBlockHoverChrome<Content: View>: View {
    let onEdit: () -> Void
    let content: Content
    @State private var isHovered = false

    init(onEdit: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onEdit = onEdit
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            if isHovered {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 25, height: 23)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Edit this block in place")
                .accessibilityLabel("Edit this Markdown block")
            }
        }
        .onHover { isHovered = $0 }
    }
}

struct MarkdownDocumentView: View {
    @Binding var source: String
    let documentURL: URL
    let workspaceRoot: URL?
    let imageRevision: Int
    @Binding var zoom: CGFloat
    let onError: (String) -> Void
    let automaticallyEditFirstBlock: Bool
    let automaticallyEditFirstTableCell: Bool
    @State private var pinchStartZoom: CGFloat?
    @State private var activeEdit: ActiveEdit?
    @State private var activeTableCell: (id: MarkdownTableCellID, text: String)?
    @State private var appliedAutomaticEdit = false
    @State private var blockCache = MarkdownSourceBlockCache()

    private struct ActiveEdit {
        var range: NSRange
        var text: String
        var before: [MarkdownSourceBlock]
        var after: [MarkdownSourceBlock]
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = MarkdownPreviewLayout.contentWidth(
                viewportWidth: geometry.size.width
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let activeEdit {
                        sourceBlocks(activeEdit.before, availableWidth: contentWidth)
                        activeEditor(activeEdit, availableWidth: contentWidth)
                        sourceBlocks(activeEdit.after, availableWidth: contentWidth)
                    } else {
                        let blocks = blockCache.blocks(for: source)
                        if blocks.isEmpty {
                            Button {
                                beginEditingEmptyDocument()
                            } label: {
                                ContentUnavailableView(
                                    "Empty Markdown document",
                                    systemImage: "text.badge.plus",
                                    description: Text("Click to start writing in place.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 220)
                            }
                            .buttonStyle(.plain)
                        } else {
                            sourceBlocks(blocks, availableWidth: contentWidth)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .frame(width: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            MarkdownCommandScrollZoomBridge(zoom: $zoom)
        }
        .environment(\.openURL, OpenURLAction { link in
            switch WorkspacePreviewLinkPolicy.decision(
                for: link,
                documentURL: documentURL,
                workspaceRoot: workspaceRoot
            ) {
            case let .external(url):
                NSWorkspace.shared.open(url)
                return .handled
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
                return .handled
            case .blocked:
                onError(
                    "Kaisola blocked a Markdown link outside this project or using an unsupported scheme."
                )
                return .discarded
            }
        })
        .onAppear { beginAutomaticEditIfReady() }
        .onChange(of: source) { _, _ in beginAutomaticEditIfReady() }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    let start = pinchStartZoom ?? zoom
                    if pinchStartZoom == nil { pinchStartZoom = zoom }
                    zoom = MarkdownPreviewLayout.magnifiedZoom(
                        start: start,
                        gestureScale: scale
                    )
                }
                .onEnded { scale in
                    zoom = MarkdownPreviewLayout.magnifiedZoom(
                        start: pinchStartZoom ?? zoom,
                        gestureScale: scale
                    )
                    pinchStartZoom = nil
                }
        )
    }

    @ViewBuilder
    private func sourceBlocks(
        _ blocks: [MarkdownSourceBlock],
        availableWidth: CGFloat
    ) -> some View {
        let renderedBlocks = blocks.map(\.block)
        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, sourceBlock in
            let renderedBlock = MarkdownBlockHoverChrome(
                onEdit: { beginEditing(sourceBlock) }
            ) {
                blockView(sourceBlock, availableWidth: availableWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .table = sourceBlock.block {
                interactiveTableBlock(
                    renderedBlock.accessibilityElement(children: .contain),
                    sourceBlock: sourceBlock,
                    index: index,
                    renderedBlocks: renderedBlocks
                )
            } else {
                interactiveBlock(
                    renderedBlock
                        .textSelection(.enabled)
                        .accessibilityElement(children: .combine),
                    sourceBlock: sourceBlock,
                    index: index,
                    renderedBlocks: renderedBlocks
                )
            }
        }
    }

    private func interactiveBlock<Content: View>(
        _ content: Content,
        sourceBlock: MarkdownSourceBlock,
        index: Int,
        renderedBlocks: [MarkdownDocument.Block]
    ) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    // Tables own double-click at cell granularity. The hover
                    // pencil remains available for exact whole-block source.
                    if case .table = sourceBlock.block { return }
                    beginEditing(sourceBlock)
                }
            )
            .focusable()
            .onKeyPress(.return) {
                beginEditing(sourceBlock)
                return .handled
            }
            .accessibilityAction(named: "Edit Markdown source") {
                beginEditing(sourceBlock)
            }
            .accessibilityHint("Press Return to edit this block's exact Markdown source")
            .help("Double-click, focus and press Return, or use the pencil to edit this block in place")
            .padding(.bottom, spacing(after: index, in: renderedBlocks))
    }

    private func interactiveTableBlock<Content: View>(
        _ content: Content,
        sourceBlock: MarkdownSourceBlock,
        index: Int,
        renderedBlocks: [MarkdownDocument.Block]
    ) -> some View {
        content
            .contentShape(Rectangle())
            // Individual table cells own Return and arrow-key handling. A
            // focusable whole-table Return handler receives the bubbled key
            // first on macOS and incorrectly opens raw block source instead.
            .accessibilityAction(named: "Edit Markdown source") {
                beginEditing(sourceBlock)
            }
            .accessibilityHint("Navigate individual cells to edit them, or use this action to edit exact table source")
            .help("Double-click a cell to edit it, or use the pencil to edit exact table source")
            .padding(.bottom, spacing(after: index, in: renderedBlocks))
    }

    private func activeEditor(
        _ edit: ActiveEdit,
        availableWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "pencil.line")
                    .foregroundStyle(.tint)
                Text("Editing this Markdown block directly")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("Done") { activeEdit = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            MarkdownRenderedEditor(
                text: activeTextBinding,
                markdownURL: documentURL,
                workspaceRoot: workspaceRoot,
                zoom: $zoom,
                targetLine: nil,
                onError: onError
            )
            .frame(width: availableWidth)
            .frame(
                minHeight: editorHeight(for: edit.text),
                maxHeight: min(420, editorHeight(for: edit.text))
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.48), lineWidth: 1)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .padding(.bottom, 16 * zoom)
    }

    private var activeTextBinding: Binding<String> {
        Binding(
            get: { activeEdit?.text ?? "" },
            set: { replacement in updateActiveText(replacement) }
        )
    }

    private var activeTableTextBinding: Binding<String> {
        Binding(
            get: { activeTableCell?.text ?? "" },
            set: { replacement in
                guard var edit = activeTableCell else { return }
                edit.text = replacement
                activeTableCell = edit
            }
        )
    }

    private func beginEditing(_ block: MarkdownSourceBlock) {
        let blocks = MarkdownSourceDocument.blocks(in: source)
        guard let exact = blocks.first(where: { $0.range == block.range })
            ?? blocks.first(where: { $0.range.location == block.range.location }) else { return }
        activeTableCell = nil
        activeEdit = ActiveEdit(
            range: exact.range,
            text: exact.source,
            before: blocks.filter { NSMaxRange($0.range) <= exact.range.location },
            after: blocks.filter { $0.range.location >= NSMaxRange(exact.range) }
        )
    }

    private func beginEditingEmptyDocument() {
        activeTableCell = nil
        activeEdit = ActiveEdit(
            range: NSRange(location: 0, length: 0),
            text: "",
            before: [],
            after: []
        )
    }

    private func beginAutomaticEditIfReady() {
        guard !appliedAutomaticEdit else { return }
        let blocks = MarkdownSourceDocument.blocks(in: source)
        let tableAndCell: (MarkdownSourceBlock, MarkdownTableSourceCell)? = blocks
            .compactMap { block -> (MarkdownSourceBlock, MarkdownTableSourceCell)? in
                guard case .table = block.block else { return nil }
                let cells = MarkdownTableSource.cells(in: block)
                let cell = cells.first(where: { $0.row == 1 && $0.column == 1 })
                    ?? cells.first(where: { $0.row > 0 })
                return cell.map { (block, $0) }
            }
            .first
        if automaticallyEditFirstTableCell,
           let (table, cell) = tableAndCell {
            appliedAutomaticEdit = true
            beginEditingTableCell(
                blockLocation: table.range.location,
                row: cell.row,
                column: cell.column,
                text: cell.text
            )
            return
        }
        guard automaticallyEditFirstBlock, let first = blocks.first else { return }
        appliedAutomaticEdit = true
        beginEditing(first)
    }

    private func updateActiveText(_ replacement: String) {
        guard var edit = activeEdit,
              let updatedSource = MarkdownSourceDocument.replacing(
                edit.range,
                in: source,
                with: replacement
              ) else { return }
        let delta = replacement.utf16.count - edit.range.length
        edit.range.length = replacement.utf16.count
        edit.text = replacement
        if delta != 0 {
            edit.after = edit.after.map { block in
                MarkdownSourceBlock(
                    range: NSRange(
                        location: block.range.location + delta,
                        length: block.range.length
                    ),
                    source: block.source,
                    block: block.block
                )
            }
        }
        activeEdit = edit
        source = updatedSource
    }

    private func beginEditingTableCell(
        blockLocation: Int,
        row: Int,
        column: Int,
        text: String
    ) {
        activeEdit = nil
        activeTableCell = (
            MarkdownTableCellID(
                blockLocation: blockLocation,
                row: row,
                column: column
            ),
            text
        )
    }

    private func commitTableCellEdit() {
        guard let edit = activeTableCell else { return }
        let blocks = MarkdownSourceDocument.blocks(in: source)
        guard let block = blocks.first(where: { block in
            guard block.range.location == edit.id.blockLocation else { return false }
            if case .table = block.block { return true }
            return false
        }), let updatedSource = MarkdownTableSource.replacingCell(
            row: edit.id.row,
            column: edit.id.column,
            in: block,
            source: source,
            with: edit.text
        ) else {
            activeTableCell = nil
            return
        }
        activeTableCell = nil
        source = updatedSource
    }

    private func editorHeight(for text: String) -> CGFloat {
        let lines = max(1, text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })
        return min(420, max(76, CGFloat(lines) * max(18, 19 * zoom) + 28))
    }

    @ViewBuilder
    private func blockView(
        _ sourceBlock: MarkdownSourceBlock,
        availableWidth: CGFloat
    ) -> some View {
        switch sourceBlock.block {
        case let .heading(level, text, alignment):
            VStack(alignment: .leading, spacing: 7 * zoom) {
                Text(inline(text))
                    .font(headingFont(level))
                    .multilineTextAlignment(textAlignment(alignment))
                    .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
                if level <= 2 {
                    Divider()
                }
            }
            .padding(.top, level <= 2 ? 8 : 2)
        case let .paragraph(text, alignment):
            Text(inline(text))
                .font(.system(size: 14 * zoom))
                .lineSpacing(4 * zoom)
                .multilineTextAlignment(textAlignment(alignment))
                .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
        case let .image(source, alt, declaredWidth, declaredHeight, alignment):
            MarkdownLocalImageView(
                source: source,
                alt: alt,
                declaredWidth: declaredWidth,
                declaredHeight: declaredHeight,
                alignment: alignment,
                availableWidth: availableWidth,
                zoom: zoom,
                documentURL: documentURL,
                workspaceRoot: workspaceRoot,
                revision: imageRevision
            )
        case let .listItem(indent, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(marker)
                    .font(.system(size: 14 * zoom, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(inline(text)).font(.system(size: 14 * zoom)).lineSpacing(3 * zoom)
            }
            .padding(.leading, CGFloat(indent) * 20 * zoom)
        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: 3)
                Text(inline(text))
                    .font(.system(size: 14 * zoom))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
            .padding(.vertical, 4)
        case let .code(language, text):
            VStack(alignment: .leading, spacing: 0) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: text)
                        .font(.system(size: 13 * zoom, design: .monospaced))
                        .lineSpacing(3 * zoom)
                        .padding(12 * zoom)
                }
            }
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        case let .table(headers, rows, omittedRows):
            VStack(alignment: .leading, spacing: 7 * zoom) {
                MarkdownTable(
                    headers: headers,
                    rows: rows,
                    zoom: zoom,
                    blockLocation: sourceBlock.range.location,
                    activeCell: activeTableCell?.id,
                    activeText: activeTableTextBinding,
                    onBeginEdit: { row, column, text in
                        beginEditingTableCell(
                            blockLocation: sourceBlock.range.location,
                            row: row,
                            column: column,
                            text: text
                        )
                    },
                    onCommit: commitTableCellEdit,
                    onCancel: { activeTableCell = nil }
                )
                if omittedRows > 0 {
                    Label(
                        MarkdownTableTruncation.message(omittedRows: omittedRows),
                        systemImage: "ellipsis.rectangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        MarkdownTableTruncation.message(omittedRows: omittedRows)
                    )
                }
            }
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func spacing(after index: Int, in blocks: [MarkdownDocument.Block]) -> CGFloat {
        guard index + 1 < blocks.count else { return 0 }
        let current = blocks[index]
        let next = blocks[index + 1]
        if case .listItem = current, case .listItem = next { return 5 * zoom }
        if case .heading = current { return 10 * zoom }
        if case .heading = next { return 20 * zoom }
        return 16 * zoom
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: MarkdownInlinePresentation.preventingOrphanedSeparators(text),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 30 * zoom, weight: .bold)
        case 2: .system(size: 24 * zoom, weight: .bold)
        case 3: .system(size: 20 * zoom, weight: .semibold)
        case 4: .system(size: 17 * zoom, weight: .semibold)
        default: .system(size: 15 * zoom, weight: .semibold)
        }
    }

    private func textAlignment(_ alignment: MarkdownDocument.ContentAlignment?) -> TextAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    private func frameAlignment(_ alignment: MarkdownDocument.ContentAlignment?) -> Alignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

}

enum MarkdownTableTruncation {
    static func message(omittedRows: Int) -> String {
        let noun = omittedRows == 1 ? "row" : "rows"
        return "\(omittedRows) more \(noun) not shown"
    }
}

private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]
    let zoom: CGFloat
    let blockLocation: Int
    let activeCell: MarkdownTableCellID?
    @Binding var activeText: String
    let onBeginEdit: (_ row: Int, _ column: Int, _ text: String) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedCell: MarkdownTableCellID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { cells(headers, row: 0, header: true) }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow { cells(row, row: index + 1, header: false) }
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear)
                }
            }
            .accessibilityElement(children: .contain)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func cells(_ values: [String], row: Int, header: Bool) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { column, value in
            let id = MarkdownTableCellID(
                blockLocation: blockLocation,
                row: row,
                column: column
            )
            Group {
                if activeCell == id {
                    TextField("Cell", text: $activeText)
                        .textFieldStyle(.plain)
                        .focused($focusedCell, equals: id)
                        .onSubmit(onCommit)
                        .onExitCommand(perform: onCancel)
                        .onAppear {
                            DispatchQueue.main.async { focusedCell = id }
                        }
                        .onChange(of: focusedCell) { oldValue, newValue in
                            if oldValue == id, newValue != id { onCommit() }
                        }
                        .accessibilityLabel("Editing table cell")
                } else {
                    Button {
                        onBeginEdit(row, column, value)
                    } label: {
                        Text(inline(value))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .focused($focusedCell, equals: id)
                        .onKeyPress(.leftArrow) {
                            moveFocus(from: id, direction: .left)
                        }
                        .onKeyPress(.rightArrow) {
                            moveFocus(from: id, direction: .right)
                        }
                        .onKeyPress(.upArrow) {
                            moveFocus(from: id, direction: .up)
                        }
                        .onKeyPress(.downArrow) {
                            moveFocus(from: id, direction: .down)
                        }
                        .help("Click or focus and press Return to edit this table cell")
                        .accessibilityLabel(
                            "\(header ? "Header" : "Row \(row)") column \(column + 1): \(value)"
                        )
                        .accessibilityHint("Press Return to edit; use arrow keys to move between cells")
                        .accessibilityAction(named: "Edit table cell") {
                            onBeginEdit(row, column, value)
                        }
                }
            }
                .font(.system(size: 13 * zoom, weight: header ? .semibold : .regular))
                .frame(minWidth: 100 * zoom, maxWidth: 280 * zoom, alignment: .leading)
                .padding(.horizontal, 10 * zoom)
                .padding(.vertical, 8 * zoom)
                .background(
                    activeCell == id
                        ? Color.accentColor.opacity(0.12)
                        : (header ? Color.primary.opacity(0.07) : .clear)
                )
                .overlay {
                    ZStack(alignment: .trailing) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.55))
                            .frame(width: 1)
                        if activeCell == id {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: 1.5)
                                .padding(2)
                        }
                    }
                }
        }
    }

    private func moveFocus(
        from id: MarkdownTableCellID,
        direction: MarkdownTableNavigation.Direction
    ) -> KeyPress.Result {
        let matrix = [headers] + rows
        guard let destination = MarkdownTableNavigation.destination(
            from: .init(row: id.row, column: id.column),
            direction: direction,
            rows: matrix
        ) else { return .ignored }
        focusedCell = MarkdownTableCellID(
            blockLocation: blockLocation,
            row: destination.row,
            column: destination.column
        )
        return .handled
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: MarkdownInlinePresentation.preventingOrphanedSeparators(text),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
