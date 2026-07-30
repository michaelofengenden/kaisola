import Foundation

/// A tiny subsequence fuzzy matcher for the command palette. Pure and
/// case-insensitive so it can be unit-tested directly. Returns nil when the
/// query isn't a subsequence of the candidate; otherwise a score where higher
/// is better (contiguous runs, word-boundary hits, and an early first match all
/// score higher), so callers can rank results.
enum FuzzyMatch {
    static func score(query: String, candidate: String) -> Int? {
        let q = Array(query.lowercased())
        if q.isEmpty { return 0 }
        let c = Array(candidate.lowercased())
        guard q.count <= c.count else { return nil }

        var score = 0
        var qi = 0
        var lastMatch = -1
        var previousWasBoundary = true

        for (ci, ch) in c.enumerated() {
            let isBoundary = previousWasBoundary
            previousWasBoundary = ch == " " || ch == "-" || ch == "/" || ch == "_" || ch == "."
            guard qi < q.count, ch == q[qi] else { continue }

            score += 1
            if lastMatch == ci - 1 { score += 5 }        // contiguous
            if isBoundary { score += 8 }                 // start of a word
            if ci == 0 { score += 4 }                    // very first char
            lastMatch = ci
            qi += 1
            if qi == q.count { break }
        }
        guard qi == q.count else { return nil }
        // Prefer shorter candidates on ties (less noise around the match).
        return score * 1000 - c.count
    }

    /// Whether the query matches at all.
    static func matches(query: String, candidate: String) -> Bool {
        score(query: query, candidate: candidate) != nil
    }
}
