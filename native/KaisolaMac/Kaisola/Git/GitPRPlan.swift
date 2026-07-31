import Foundation

/// Exactly what "Push and Create PR" will do, assembled and shown BEFORE
/// anything runs.
///
/// The old panel did all of this behind one click — fork a branch off the
/// default branch under a guessed name, synthesize a title and body from the
/// ahead commits, push (setting an upstream), then `gh pr create` — with the
/// user seeing none of it until a PR existed. `PRPlan` is that same sequence as
/// data: assembled by `GitPRPlanner` for review, edited by the user, then handed
/// back for execution unchanged.
struct PRPlan: Equatable, Sendable {
    /// The branch the pull request will target.
    var baseBranch: String
    /// The branch that will be pushed (existing, or created when `createsBranch`).
    var headBranch: String
    /// True when the head branch does not exist yet and will be forked off HEAD.
    var createsBranch: Bool
    /// True when the push must set an upstream (`push -u origin HEAD`).
    var setsUpstream: Bool
    /// The commit the review was assembled against — execution refuses to run if
    /// the repository has moved past it.
    var headOID: String
    /// The commits the pull request would contain, newest first.
    var commitSubjects: [String]
    /// How many files those commits touch.
    var changedFileCount: Int
    var title: String
    var body: String

    var commitCount: Int { commitSubjects.count }

    /// Fold the review sheet's edits into the plan. The title and body are always
    /// editable; the head branch only when the plan is the one creating it (on an
    /// existing branch the head is the checked-out branch, and renaming it is a
    /// different operation entirely).
    func applyingEdits(headBranch rawHead: String, title rawTitle: String, body rawBody: String) throws -> PRPlan {
        var edited = self
        if createsBranch {
            edited.headBranch = try GitPRPlanner.validatedBranchName(rawHead)
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw GitService.GitError.commandFailed("Enter a title for the pull request.")
        }
        edited.title = title
        edited.body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited
    }
}

/// Pure assembly and validation for `PRPlan` — every git read happens in the
/// caller, so the decisions themselves are unit-testable without a repository.
enum GitPRPlanner {
    static let fallbackTitle = "Kaisola changes"
    static let fallbackBody = "Opened from Kaisola."

    /// Build the reviewable plan. Throws (rather than silently producing a bad
    /// plan) when there is nothing to open a pull request with, or when the fork
    /// name the panel would use is empty or unsafe.
    static func assemble(
        prep: GitService.PRPrep,
        defaultBranch: String,
        headOID: String,
        requestedBranchName: String,
        commitSubjects: [String],
        changedFileCount: Int
    ) throws -> PRPlan {
        guard prep.aheadCount > 0 || !commitSubjects.isEmpty else {
            throw GitService.GitError.commandFailed(
                "This branch has no commits to open a pull request with."
            )
        }

        let headBranch: String
        let createsBranch: Bool
        let setsUpstream: Bool
        if prep.isDefaultBranch {
            // Committed work on the default branch must never become a PR *from*
            // the default branch, so the plan forks a branch first — and a brand
            // new branch never tracks anything, so its push always sets upstream.
            headBranch = try validatedBranchName(requestedBranchName)
            createsBranch = true
            setsUpstream = true
        } else {
            headBranch = prep.branch
            createsBranch = false
            setsUpstream = !prep.hasUpstream
        }

        return PRPlan(
            baseBranch: defaultBranch,
            headBranch: headBranch,
            createsBranch: createsBranch,
            setsUpstream: setsUpstream,
            headOID: headOID,
            commitSubjects: commitSubjects,
            changedFileCount: changedFileCount,
            title: title(for: commitSubjects),
            body: body(for: commitSubjects)
        )
    }

    /// The same charset `GitService.createBranchFromHead` enforces, applied at
    /// review time so an unusable name is refused before anything runs.
    static func validatedBranchName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw GitService.GitError.commandFailed("Enter a branch name for the pull request.")
        }
        guard name.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil else {
            throw GitService.GitError.commandFailed(
                "Invalid branch name — use letters, digits, and . _ / - only."
            )
        }
        return name
    }

    /// Newest subject as the title (the panel's long-standing choice), now shown
    /// for review and editable before it becomes a pull request.
    static func title(for subjects: [String]) -> String {
        subjects.first ?? fallbackTitle
    }

    static func body(for subjects: [String]) -> String {
        subjects.isEmpty ? fallbackBody : subjects.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Why the reviewed plan can no longer be executed as shown, or nil when the
    /// repository still matches it. Review and confirm are two separate clicks,
    /// and an agent can commit or switch branches in between — executing "the
    /// plan the user approved" against a different HEAD would push work nobody
    /// reviewed.
    static func stalenessMessage(plan: PRPlan, currentHeadOID: String, currentBranch: String) -> String? {
        if plan.headOID.lowercased() != currentHeadOID.lowercased() {
            return "The branch moved since this plan was reviewed. Review it again."
        }
        if plan.createsBranch {
            // A plan that forks a branch does so off whatever is checked out
            // *right now* — reviewed while `currentBranch` was `plan.baseBranch`
            // (the default branch). Matching HEAD OID alone is not enough: an
            // agent or terminal could check out a different branch that
            // happens to point at the same commit (a synced branch, a
            // detached checkout) between review and confirm, and forking would
            // then run against a branch context nobody reviewed.
            if currentBranch != plan.baseBranch {
                return "The checked-out branch changed since this plan was reviewed. Review it again."
            }
        } else if plan.headBranch != currentBranch {
            return "The checked-out branch changed since this plan was reviewed. Review it again."
        }
        return nil
    }

    /// Same discriminating check as `stalenessMessage`, boolean and resilient to
    /// a background refresh snapshot that could not resolve one of the two
    /// current identities (a transient git failure must not flip the open
    /// review card's staleness either way — missing data simply reports "not
    /// stale" rather than guessing). Used by the panel's live refresh to
    /// self-invalidate an open plan without waiting for the user to click
    /// Confirm and hit the same check as an error.
    static func isStale(plan: PRPlan, currentHeadOID: String?, currentBranch: String?) -> Bool {
        guard let currentHeadOID, let currentBranch else { return false }
        return stalenessMessage(plan: plan, currentHeadOID: currentHeadOID, currentBranch: currentBranch) != nil
    }
}
