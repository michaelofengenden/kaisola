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
    /// The reviewed remote repository and base branch. Execution rechecks this
    /// identity and uses it verbatim instead of asking Git or `gh` to infer a
    /// destination after the user confirms.
    var destination: GitService.PRDestination
    /// The branch the pull request will target.
    var baseBranch: String { destination.baseBranch }
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
    /// Exact paths those commits touch. Production plans always populate this;
    /// the separate count keeps narrow planner fixtures representable.
    var changedFiles: [String]
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

/// Which side effects of a reviewed plan have already happened.
///
/// Confirming a pull request is three effects in a row — fork the branch, push
/// it, then ask `gh` to open the PR — and only the last one can simply be run
/// again. A failure at the third step used to come back as one generic
/// operation error, leaving the user standing on a branch they were never told
/// had been created, with a remote branch nothing on screen mentioned. Progress
/// records each completed phase so the panel can name it, link the pushed
/// branch, and resume at the first phase that has not run.
struct PRExecutionProgress: Equatable, Sendable {
    /// The branch `createBranchFromHead` forked and checked out, if it ran.
    var createdBranch: String?
    /// The branch a completed push put on the remote, if it ran…
    var pushedBranch: String?
    /// …and the commit it put there. A plan for the same branch at a *newer*
    /// commit must push again, or the pull request would omit that newer work.
    var pushedHeadOID: String?
    /// The pushed branch's page on the remote — the "where did my work go?"
    /// answer for a run that pushed but never opened a pull request.
    var remoteBranchURL: String?

    /// Did anything at all run? Drives whether the panel may still claim that
    /// nothing has happened yet.
    var hasSideEffects: Bool { createdBranch != nil || pushedBranch != nil }

    /// The completed phases, in the order they ran, phrased for the panel.
    var completedPhases: [String] {
        var phases: [String] = []
        if let createdBranch { phases.append("Created branch \(createdBranch)") }
        if let pushedBranch { phases.append("Pushed \(pushedBranch) to the remote") }
        return phases
    }

    /// The line the panel keeps even after the review card is dismissed, so a
    /// half-finished run never becomes invisible. Nil when nothing ran.
    var recoveryNote: String? {
        guard hasSideEffects else { return nil }
        return (completedPhases + ["The pull request was not opened."]).joined(separator: ". ")
    }

    /// Does this plan still need its branch forked? False once an earlier
    /// attempt created exactly that branch — `checkout -b` would only fail.
    func needsBranchCreation(for plan: PRPlan) -> Bool {
        plan.createsBranch && createdBranch != plan.headBranch
    }

    /// Does this plan still need a push? Only when the remote does not already
    /// have this branch at this exact commit.
    func needsPush(for plan: PRPlan) -> Bool {
        pushedBranch != plan.headBranch || pushedHeadOID != plan.headOID
    }

    /// What a confirm would still do, phrased for the review card's caption so
    /// the button never over-promises or under-reports.
    func remainingWork(for plan: PRPlan) -> String {
        var steps: [String] = []
        if needsBranchCreation(for: plan) { steps.append("create branch \(plan.headBranch)") }
        if needsPush(for: plan) { steps.append("push \(plan.headBranch) to \(plan.destination.remoteName)") }
        steps.append("open the pull request against \(plan.baseBranch)")
        return steps.joined(separator: ", then ")
    }

    /// The part of this progress that still describes a freshly assembled plan.
    /// A re-review after a failed run must not forget a branch that already
    /// exists, and must not remember a push that no longer covers the commit
    /// the new plan would open.
    func carriedForward(into plan: PRPlan) -> PRExecutionProgress {
        var carried = PRExecutionProgress()
        if createdBranch == plan.headBranch { carried.createdBranch = createdBranch }
        if !needsPush(for: plan) {
            carried.pushedBranch = pushedBranch
            carried.pushedHeadOID = pushedHeadOID
            carried.remoteBranchURL = remoteBranchURL
        }
        return carried
    }
}

/// A confirm that stopped part way, carrying the phases that did complete. The
/// panel reads `progress` off it instead of reducing a partly-executed run to a
/// single error string; `errorDescription` stays the underlying git/`gh`
/// message so the error banner reads exactly as it did before.
struct PRExecutionFailure: Error, LocalizedError {
    let progress: PRExecutionProgress
    let underlying: any Error

    var errorDescription: String? {
        (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription
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
        destination: GitService.PRDestination? = nil,
        headOID: String,
        requestedBranchName: String,
        commitSubjects: [String],
        changedFileCount: Int,
        changedFiles: [String] = []
    ) throws -> PRPlan {
        guard prep.aheadCount > 0 || !commitSubjects.isEmpty else {
            throw GitService.GitError.commandFailed(
                "This branch has no commits to open a pull request with."
            )
        }
        guard changedFileCount >= 0,
              (changedFiles.isEmpty || changedFiles.count == changedFileCount),
              Set(changedFiles).count == changedFiles.count,
              changedFiles.allSatisfy({ !$0.isEmpty }) else {
            throw GitService.GitError.commandFailed(
                "The pull request file inventory is incomplete. Review it again."
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

        let reviewedDestination = destination ?? .unavailable(baseBranch: defaultBranch)
        guard reviewedDestination.baseBranch == defaultBranch else {
            throw GitService.GitError.commandFailed(
                "The reviewed pull request destination does not match its base branch."
            )
        }

        return PRPlan(
            destination: reviewedDestination,
            headBranch: headBranch,
            createsBranch: createsBranch,
            setsUpstream: setsUpstream,
            headOID: headOID,
            commitSubjects: commitSubjects,
            changedFileCount: changedFileCount,
            changedFiles: changedFiles,
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
    static func stalenessMessage(
        plan: PRPlan,
        currentHeadOID: String,
        currentBranch: String,
        currentDestination: GitService.PRDestination? = nil,
        completedBranchCreation: Bool = false
    ) -> String? {
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
            //
            // Unless this very plan already forked it: the fork is checked out
            // *because* the run got that far, so the branch it must still be
            // standing on is the head, not the base. Expecting the base here is
            // what used to make a half-finished run unretryable.
            let expected = completedBranchCreation ? plan.headBranch : plan.baseBranch
            if currentBranch != expected {
                return "The checked-out branch changed since this plan was reviewed. Review it again."
            }
        } else if plan.headBranch != currentBranch {
            return "The checked-out branch changed since this plan was reviewed. Review it again."
        }
        if let currentDestination,
           plan.destination != currentDestination {
            return "The pull request remote or destination changed since this plan was reviewed. Review it again."
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
    static func isStale(
        plan: PRPlan,
        currentHeadOID: String?,
        currentBranch: String?,
        currentDestination: GitService.PRDestination? = nil,
        completedBranchCreation: Bool = false
    ) -> Bool {
        guard let currentHeadOID, let currentBranch else { return false }
        return stalenessMessage(
            plan: plan,
            currentHeadOID: currentHeadOID,
            currentBranch: currentBranch,
            currentDestination: currentDestination,
            completedBranchCreation: completedBranchCreation
        ) != nil
    }
}
