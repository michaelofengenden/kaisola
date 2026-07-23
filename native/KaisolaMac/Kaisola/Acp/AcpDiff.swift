import Foundation

/// A pure line-level diff for ACP tool-call file edits. LCS-based so unchanged
/// lines stay as context and only the true insertions/deletions are tinted —
/// no SwiftUI here so it can be unit-tested directly.
enum AcpDiff {
    enum LineKind: Equatable, Sendable {
        case context
        case removed
        case added

        var prefix: String {
            switch self {
            case .context: "  "
            case .removed: "- "
            case .added: "+ "
            }
        }
    }

    struct Line: Equatable, Sendable {
        let kind: LineKind
        let text: String
    }

    /// Compute the unified line diff between `old` and `new`. When `old` is empty
    /// every line is an addition (a freshly written file), the common case for
    /// agent `write` tools.
    static func lines(old: String, new: String) -> [Line] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        if oldLines.isEmpty { return newLines.map { Line(kind: .added, text: $0) } }
        if newLines.isEmpty { return oldLines.map { Line(kind: .removed, text: $0) } }

        // LCS table over lines.
        let m = oldLines.count, n = newLines.count
        var lcs = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                if oldLines[i] == newLines[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var result: [Line] = []
        var i = 0, j = 0
        while i < m, j < n {
            if oldLines[i] == newLines[j] {
                result.append(Line(kind: .context, text: oldLines[i]))
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(Line(kind: .removed, text: oldLines[i]))
                i += 1
            } else {
                result.append(Line(kind: .added, text: newLines[j]))
                j += 1
            }
        }
        while i < m { result.append(Line(kind: .removed, text: oldLines[i])); i += 1 }
        while j < n { result.append(Line(kind: .added, text: newLines[j])); j += 1 }
        return result
    }

    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        // Drop a single trailing newline so a file ending in "\n" doesn't yield a
        // spurious empty final line.
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        return body.components(separatedBy: "\n")
    }
}
