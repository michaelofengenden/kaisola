import Foundation

/// The "prompts are technical debt" nudge (Theo Browne's argument, adopted
/// from tonight's research): a project's agent instruction file silently
/// decays as models change roughly every forty days, and nothing errors when
/// it goes stale. This rule is deliberately pure and deliberately gentle —
/// one informational toast per project per app run, only at the moment the
/// instructions start mattering (a chat opening there), and never for a
/// project that has no instruction file at all: absence is a choice, not rot.
enum InstructionFileStaleness {
    /// Days without an edit before the nudge is worth a toast.
    static let staleAfterDays = 90
    /// Theo's observed model cadence, used only to phrase the nudge.
    static let modelCadenceDays = 40

    /// The instruction files worth checking, in precedence order — the first
    /// one that exists is the project's live instruction file.
    static let fileNames = ["CLAUDE.md", "AGENTS.md"]

    /// The nudge for an instruction file last modified at `modified`, or nil
    /// when it is fresh enough (or its date is unknowable).
    static func nudge(fileName: String, modified: Date?, now: Date) -> String? {
        guard let modified else { return nil }
        let days = Int(now.timeIntervalSince(modified) / 86_400)
        guard days >= staleAfterDays else { return nil }
        let generations = max(1, days / modelCadenceDays)
        let generationLabel = generations == 1
            ? "about one model generation"
            : "about \(generations) model generations"
        return "\(fileName) here hasn't changed in \(days) days — \(generationLabel) ago. Worth a skim."
    }

    /// The on-disk check: the first instruction file that exists under
    /// `directory`, assessed. One or two stats; cheap enough for a chat open.
    static func nudge(forProjectAt directory: URL, now: Date = Date()) -> String? {
        for name in fileNames {
            let url = directory.appending(path: name)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            return nudge(fileName: name, modified: modified, now: now)
        }
        return nil
    }
}
