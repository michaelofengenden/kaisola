import Foundation

struct SourceOutlineItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case section
        case type
        case function
        case key

        var systemImage: String {
            switch self {
            case .section: "text.alignleft"
            case .type: "cube"
            case .function: "function"
            case .key: "key"
            }
        }
    }

    let line: Int
    let title: String
    let depth: Int
    let kind: Kind

    var id: String { "\(line)|\(kind.rawValue)|\(title)" }
}

/// A deliberately lightweight source outline. It never evaluates source or
/// asks the editor page to inspect a document; Swift parses the bounded source
/// snapshot already owned by `FilePreviewView`. The recognizers favor stable,
/// high-signal declarations over pretending to be a compiler front-end.
enum SourceOutline {
    static let maximumItems = 200
    static let maximumLines = 50_000
    static let maximumLineLength = 1_024
    static let maximumTitleLength = 120

    private static let swiftDeclaration = expression(
        #"^\s*(?:(?:@\w+(?:\([^)]*\))?|public|private|fileprivate|internal|open|final|static|class|nonisolated|isolated|override|mutating|nonmutating|required|convenience|indirect|distributed)\s+)*(actor|class|enum|extension|protocol|struct|func|init|deinit|subscript|typealias)\b\s*([A-Za-z_][A-Za-z0-9_.<>]*)?"#
    )
    private static let pythonDeclaration = expression(
        #"^\s*(async\s+def|def|class)\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )
    private static let javascriptDeclaration = expression(
        #"^\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?(class|function|interface|type|enum|namespace)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#
    )
    private static let javascriptArrow = expression(
        #"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][A-Za-z0-9_$]*)\s*=>"#
    )
    private static let shellFunction = expression(
        #"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*(?:\(\s*\))?\s*\{"#
    )
    private static let htmlHeading = expression(
        #"(?i)<h([1-6])\b[^>]*>(.*?)</h\1\s*>"#
    )
    private static let htmlTag = expression(#"<[^>]+>"#)

    static func items(in source: String, fileURL: URL) -> [SourceOutlineItem] {
        guard !source.isEmpty else { return [] }
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let ext = fileURL.pathExtension.lowercased()
        let language = CodeEditorLanguage.detect(for: fileURL)
        var items: [SourceOutlineItem] = []
        items.reserveCapacity(min(maximumItems, 64))

        func append(_ item: SourceOutlineItem?) {
            guard items.count < maximumItems, let item, !item.title.isEmpty else { return }
            items.append(item)
        }

        for index in lines.indices.prefix(maximumLines) where items.count < maximumItems {
            let raw = String(lines[index].prefix(maximumLineLength))
            let line = index + 1
            if ext == "md" || ext == "markdown" {
                append(markdownItem(line: raw, next: lines.indices.contains(index + 1)
                    ? String(lines[index + 1].prefix(maximumLineLength))
                    : nil, lineNumber: line))
                continue
            }
            switch language {
            case .swift:
                append(declarationItem(
                    expression: swiftDeclaration,
                    line: raw,
                    lineNumber: line,
                    keywordGroup: 1,
                    nameGroup: 2
                ))
            case .python:
                append(declarationItem(
                    expression: pythonDeclaration,
                    line: raw,
                    lineNumber: line,
                    keywordGroup: 1,
                    nameGroup: 2
                ))
            case .javascript, .typescript, .tsx:
                if let declaration = declarationItem(
                    expression: javascriptDeclaration,
                    line: raw,
                    lineNumber: line,
                    keywordGroup: 1,
                    nameGroup: 2
                ) {
                    append(declaration)
                } else if let name = capture(javascriptArrow, group: 1, in: raw) {
                    append(SourceOutlineItem(
                        line: line,
                        title: bounded(name),
                        depth: indentationDepth(raw),
                        kind: .function
                    ))
                }
            case .html:
                append(htmlItem(line: raw, lineNumber: line))
            case .css:
                append(cssItem(line: raw, lineNumber: line))
            case .shell:
                if let name = capture(shellFunction, group: 1, in: raw) {
                    append(SourceOutlineItem(
                        line: line,
                        title: bounded(name),
                        depth: indentationDepth(raw),
                        kind: .function
                    ))
                }
            case .json, .yaml:
                append(keyItem(line: raw, lineNumber: line, includeScalar: language == .yaml))
            case .plain:
                break
            }
        }
        return items
    }

    private static func markdownItem(
        line: String,
        next: String?,
        lineNumber: Int
    ) -> SourceOutlineItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        if (1...6).contains(hashes),
           trimmed.dropFirst(hashes).first?.isWhitespace == true {
            let title = trimmed.dropFirst(hashes)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            return SourceOutlineItem(
                line: lineNumber,
                title: bounded(title),
                depth: hashes,
                kind: .section
            )
        }
        guard !trimmed.isEmpty, let next else { return nil }
        let rule = next.trimmingCharacters(in: .whitespaces)
        guard rule.count >= 3,
              rule.allSatisfy({ $0 == "=" }) || rule.allSatisfy({ $0 == "-" }) else { return nil }
        return SourceOutlineItem(
            line: lineNumber,
            title: bounded(trimmed),
            depth: rule.first == "=" ? 1 : 2,
            kind: .section
        )
    }

    private static func declarationItem(
        expression: NSRegularExpression,
        line: String,
        lineNumber: Int,
        keywordGroup: Int,
        nameGroup: Int
    ) -> SourceOutlineItem? {
        guard let keyword = capture(expression, group: keywordGroup, in: line) else { return nil }
        let name = capture(expression, group: nameGroup, in: line)
        let kind: SourceOutlineItem.Kind = switch keyword {
        case "actor", "class", "enum", "extension", "interface", "namespace", "protocol", "struct", "type", "typealias": .type
        default: .function
        }
        return SourceOutlineItem(
            line: lineNumber,
            title: bounded(name.map { "\(keyword) \($0)" } ?? keyword),
            depth: indentationDepth(line),
            kind: kind
        )
    }

    private static func htmlItem(line: String, lineNumber: Int) -> SourceOutlineItem? {
        guard let levelText = capture(htmlHeading, group: 1, in: line),
              let rawTitle = capture(htmlHeading, group: 2, in: line),
              let level = Int(levelText) else { return nil }
        let range = NSRange(location: 0, length: (rawTitle as NSString).length)
        let title = htmlTag.stringByReplacingMatches(
            in: rawTitle,
            range: range,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return SourceOutlineItem(
            line: lineNumber,
            title: bounded(title),
            depth: level,
            kind: .section
        )
    }

    private static func cssItem(line: String, lineNumber: Int) -> SourceOutlineItem? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("{"),
              !trimmed.hasPrefix("/*"),
              !trimmed.hasPrefix("//") else { return nil }
        let title = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return SourceOutlineItem(
            line: lineNumber,
            title: bounded(title),
            depth: indentationDepth(line),
            kind: .section
        )
    }

    private static func keyItem(
        line: String,
        lineNumber: Int,
        includeScalar: Bool
    ) -> SourceOutlineItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { return nil }
        let rawKey = String(trimmed[..<colon])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let value = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty,
              !rawKey.contains("{"),
              !rawKey.contains("[") else { return nil }
        guard includeScalar || value.isEmpty || value.hasPrefix("{") || value.hasPrefix("[") else {
            return nil
        }
        return SourceOutlineItem(
            line: lineNumber,
            title: bounded(rawKey),
            depth: indentationDepth(line),
            kind: .key
        )
    }

    private static func indentationDepth(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 }
            else if character == "\t" { columns += 4 }
            else { break }
        }
        return min(6, max(1, columns / 4 + 1))
    }

    private static func bounded<S: StringProtocol>(_ value: S) -> String {
        let compact = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > maximumTitleLength else { return compact }
        return String(compact.prefix(maximumTitleLength - 1)) + "…"
    }

    private static func capture(
        _ expression: NSRegularExpression,
        group: Int,
        in line: String
    ) -> String? {
        let source = line as NSString
        guard let match = expression.firstMatch(
            in: line,
            range: NSRange(location: 0, length: source.length)
        ), group < match.numberOfRanges else { return nil }
        let range = match.range(at: group)
        guard range.location != NSNotFound else { return nil }
        return source.substring(with: range)
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        // Every pattern is compile-time constant and covered by unit tests.
        try! NSRegularExpression(pattern: pattern)
    }
}
