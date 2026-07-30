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

    /// Beyond this many lines per side, skip the O(m×n) LCS — an agent editing a
    /// 15k-line lockfile would otherwise allocate a ~1.8 GB DP table on the main
    /// thread and freeze (or OOM) the UI. Mirrors Electron's diff-text cap.
    static let lineDiffCap = 2_000

    /// Compute the unified line diff between `old` and `new`. When `old` is empty
    /// every line is an addition (a freshly written file), the common case for
    /// agent `write` tools.
    static func lines(old: String, new: String) -> [Line] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        if oldLines.isEmpty { return newLines.map { Line(kind: .added, text: $0) } }
        if newLines.isEmpty { return oldLines.map { Line(kind: .removed, text: $0) } }

        // Oversized diffs skip the quadratic LCS: show every old line removed
        // then every new line added (a coarse but bounded, non-freezing view).
        if oldLines.count > lineDiffCap || newLines.count > lineDiffCap {
            return oldLines.map { Line(kind: .removed, text: $0) }
                + newLines.map { Line(kind: .added, text: $0) }
        }

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

    // MARK: - Word-level refinement

    /// A run of characters within one diff line; `changed` marks the words that
    /// differ from the paired line (stronger tint than the line background).
    struct Segment: Equatable, Sendable {
        let text: String
        let changed: Bool
    }

    /// One rendered diff row. Context rows carry both sides; a pure removal has
    /// `new == nil`, a pure addition `old == nil`, and a changed pair carries
    /// word-refined segments on both sides. Drives unified and split layouts.
    struct Row: Equatable, Sendable {
        let old: [Segment]?
        let new: [Segment]?
    }

    /// Beyond this many word tokens per side, skip the LCS refinement and mark
    /// the whole line changed — keeps pathological lines O(1) to render.
    static let wordTokenCap = 200

    /// Word-level segments for a removed/added line pair: LCS over word tokens
    /// (whitespace runs are tokens too, so the segments reconstruct each line
    /// exactly). Tokens outside the LCS are `changed`.
    static func wordSegments(removed: String, added: String) -> (removed: [Segment], added: [Segment]) {
        let oldTokens = wordTokens(removed)
        let newTokens = wordTokens(added)
        guard oldTokens.count <= wordTokenCap, newTokens.count <= wordTokenCap else {
            return (
                removed.isEmpty ? [] : [Segment(text: removed, changed: true)],
                added.isEmpty ? [] : [Segment(text: added, changed: true)]
            )
        }
        let m = oldTokens.count, n = newTokens.count
        var lcs = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                lcs[i][j] = oldTokens[i] == newTokens[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var oldSegments: [Segment] = [], newSegments: [Segment] = []
        var i = 0, j = 0
        while i < m, j < n {
            if oldTokens[i] == newTokens[j] {
                oldSegments.append(Segment(text: oldTokens[i], changed: false))
                newSegments.append(Segment(text: newTokens[j], changed: false))
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                oldSegments.append(Segment(text: oldTokens[i], changed: true))
                i += 1
            } else {
                newSegments.append(Segment(text: newTokens[j], changed: true))
                j += 1
            }
        }
        while i < m { oldSegments.append(Segment(text: oldTokens[i], changed: true)); i += 1 }
        while j < n { newSegments.append(Segment(text: newTokens[j], changed: true)); j += 1 }
        return (coalesce(oldSegments), coalesce(newSegments))
    }

    /// Group a line diff into rows, pairing each removed-run with the added-run
    /// that immediately follows it (positionally, like editors do) so paired
    /// lines get word-level refinement. Leftovers of the longer run and lone
    /// runs stay whole-line changes.
    static func rows(old: String, new: String) -> [Row] {
        let lines = lines(old: old, new: new)
        var rows: [Row] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            switch line.kind {
            case .context:
                let segment = [Segment(text: line.text, changed: false)]
                rows.append(Row(old: segment, new: segment))
                index += 1
            case .added:
                rows.append(Row(old: nil, new: [Segment(text: line.text, changed: true)]))
                index += 1
            case .removed:
                var removedTexts: [String] = []
                while index < lines.count, lines[index].kind == .removed {
                    removedTexts.append(lines[index].text)
                    index += 1
                }
                var addedTexts: [String] = []
                while index < lines.count, lines[index].kind == .added {
                    addedTexts.append(lines[index].text)
                    index += 1
                }
                let paired = min(removedTexts.count, addedTexts.count)
                for k in 0 ..< paired {
                    let (oldSegments, newSegments) = wordSegments(removed: removedTexts[k], added: addedTexts[k])
                    rows.append(Row(old: oldSegments, new: newSegments))
                }
                for k in paired ..< removedTexts.count {
                    rows.append(Row(old: [Segment(text: removedTexts[k], changed: true)], new: nil))
                }
                for k in paired ..< addedTexts.count {
                    rows.append(Row(old: nil, new: [Segment(text: addedTexts[k], changed: true)]))
                }
            }
        }
        return rows
    }

    /// Runs of non-whitespace and runs of whitespace, in order — concatenating
    /// the tokens reproduces the input exactly.
    static func wordTokens(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for character in text {
            let isSpace = character.isWhitespace
            if currentIsSpace == nil || currentIsSpace == isSpace {
                current.append(character)
            } else {
                tokens.append(current)
                current = String(character)
            }
            currentIsSpace = isSpace
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func coalesce(_ segments: [Segment]) -> [Segment] {
        // A whitespace-only unchanged run between two changed words is visual
        // noise (the spaces "matched" but everything around them changed) —
        // absorb it into the surrounding change before merging runs.
        var absorbed = segments
        if absorbed.count >= 3 {
            for index in 1 ..< (absorbed.count - 1) {
                guard !absorbed[index].changed,
                      absorbed[index].text.allSatisfy(\.isWhitespace),
                      segments[index - 1].changed,
                      segments[index + 1].changed else { continue }
                absorbed[index] = Segment(text: absorbed[index].text, changed: true)
            }
        }
        var result: [Segment] = []
        for segment in absorbed {
            if let last = result.last, last.changed == segment.changed {
                result[result.count - 1] = Segment(text: last.text + segment.text, changed: segment.changed)
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
