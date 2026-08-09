import Combine
import Foundation
import XCTest
@testable import Kaisola

/// The Git panel's two testable seams:
///
/// 1. `GitRefreshPolicy` — the pure "should a filesystem event turn into a real
///    `git status` run yet?" decision that replaced the panel's 3s poll, plus a
///    live round-trip proving an *external* `git add` refreshes the open panel.
/// 2. `GitPRPlanner` / `PRPlan` — the pure assembly of a reviewable pull-request
///    plan, so the first click can show exactly what the second click will do.
final class GitPanelModelTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-gitpanel-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "test@example.com"])
        try git(["config", "user.name", "Test"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    // MARK: - GitRefreshPolicy (pure)

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = GitRefreshPolicy()

    func testNoPendingEventIsIdle() {
        XCTAssertEqual(
            policy.decide(pendingEventAt: nil, lastRefreshAt: now.addingTimeInterval(-60), isBusy: false, now: now),
            .idle
        )
        // Idle regardless of a busy operation: nothing is waiting to be shown.
        XCTAssertEqual(
            policy.decide(pendingEventAt: nil, lastRefreshAt: nil, isBusy: true, now: now),
            .idle
        )
    }

    func testBusyDefersInsteadOfDroppingTheEvent() {
        // A refresh started over a running op would be swallowed by the model's
        // isBusy guard and the event lost, so a due event must WAIT, not refresh.
        let decision = policy.decide(
            pendingEventAt: now.addingTimeInterval(-10),
            lastRefreshAt: now.addingTimeInterval(-10),
            isBusy: true,
            now: now
        )
        XCTAssertEqual(waitSeconds(decision), policy.busyRetry, accuracy: 0.001)
    }

    func testEventInsideDebounceWaitsForTheRemainder() {
        let decision = policy.decide(
            pendingEventAt: now.addingTimeInterval(-0.1),
            lastRefreshAt: nil,
            isBusy: false,
            now: now
        )
        XCTAssertEqual(waitSeconds(decision), policy.debounce - 0.1, accuracy: 0.001)
    }

    func testDebouncedEventRefreshesWhenNoRefreshHasRunYet() {
        XCTAssertEqual(
            policy.decide(
                pendingEventAt: now.addingTimeInterval(-policy.debounce),
                lastRefreshAt: nil,
                isBusy: false,
                now: now
            ),
            .refresh
        )
    }

    func testRateFloorHoldsBackAStormOfEvents() {
        // Debounce satisfied, but a refresh ran 0.2s ago: agents rewriting a
        // hundred files must not spawn a `git status` per event.
        let decision = policy.decide(
            pendingEventAt: now.addingTimeInterval(-policy.debounce),
            lastRefreshAt: now.addingTimeInterval(-0.2),
            isBusy: false,
            now: now
        )
        XCTAssertEqual(waitSeconds(decision), policy.minimumInterval - 0.2, accuracy: 0.001)

        // Once the floor has elapsed the same event refreshes.
        XCTAssertEqual(
            policy.decide(
                pendingEventAt: now.addingTimeInterval(-policy.debounce),
                lastRefreshAt: now.addingTimeInterval(-policy.minimumInterval),
                isBusy: false,
                now: now
            ),
            .refresh
        )
    }

    func testFutureTimestampsCannotParkThePanelForever() {
        // A backwards clock jump (or a future-stamped event) must never produce
        // an unbounded wait: each wait is capped by its own interval.
        let futureEvent = policy.decide(
            pendingEventAt: now.addingTimeInterval(3_600),
            lastRefreshAt: nil,
            isBusy: false,
            now: now
        )
        XCTAssertEqual(waitSeconds(futureEvent), policy.debounce, accuracy: 0.001)

        let futureRefresh = policy.decide(
            pendingEventAt: now.addingTimeInterval(-policy.debounce),
            lastRefreshAt: now.addingTimeInterval(3_600),
            isBusy: false,
            now: now
        )
        XCTAssertEqual(waitSeconds(futureRefresh), policy.minimumInterval, accuracy: 0.001)
    }

    func testDebounceStaysInTheAgreedWindow() {
        // The fix's contract: a 300–500ms trailing debounce, not a 3s poll.
        XCTAssertGreaterThanOrEqual(policy.debounce, 0.3)
        XCTAssertLessThanOrEqual(policy.debounce, 0.5)
    }

    // MARK: - Git directory resolution

    func testResolvesThePlainRepositoryGitDirectory() throws {
        let resolved = try XCTUnwrap(GitDirectoryWatcher.resolveGitDirectory(repoRoot: repo))
        XCTAssertEqual(resolved.standardizedFileURL.path, repo.appendingPathComponent(".git").standardizedFileURL.path)
    }

    func testResolvesALinkedWorktreeGitDirectory() throws {
        // Kaisola Mesh (and this very branch) run inside linked worktrees, where
        // `.git` is a FILE pointing at the real per-worktree git directory. A
        // watcher that assumed a directory would silently never fire there.
        try write("a.txt", "hello\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "init"])
        let tree = repo.appendingPathComponent("wt", isDirectory: true)
        try git(["worktree", "add", "-q", "-b", "side", tree.path])

        let resolved = try XCTUnwrap(GitDirectoryWatcher.resolveGitDirectory(repoRoot: tree))
        XCTAssertTrue(
            resolved.path.contains("/worktrees/"),
            "a linked worktree must resolve to its per-worktree git dir, got \(resolved.path)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.appendingPathComponent("HEAD").path))
    }

    func testGitDirectoryPointerParsingRejectsGarbage() {
        XCTAssertNil(GitDirectoryWatcher.gitDirectory(fromPointerFile: "not a pointer", repoRoot: repo))
        XCTAssertNil(GitDirectoryWatcher.gitDirectory(fromPointerFile: "gitdir:   \n", repoRoot: repo))
        XCTAssertEqual(
            GitDirectoryWatcher.gitDirectory(fromPointerFile: "gitdir: /abs/path/.git/worktrees/x\n", repoRoot: repo)?.path,
            "/abs/path/.git/worktrees/x"
        )
        // Relative pointers resolve against the worktree root.
        XCTAssertEqual(
            GitDirectoryWatcher.gitDirectory(fromPointerFile: "gitdir: ../.git/worktrees/x", repoRoot: repo)?
                .standardizedFileURL.path,
            repo.deletingLastPathComponent().appendingPathComponent(".git/worktrees/x").standardizedFileURL.path
        )
    }

    // MARK: - PR plan assembly (pure)

    private func prep(branch: String, isDefault: Bool, hasUpstream: Bool, ahead: Int) -> GitService.PRPrep {
        GitService.PRPrep(branch: branch, isDefaultBranch: isDefault, hasUpstream: hasUpstream, aheadCount: ahead)
    }

    func testPlanOnAFeatureBranchKeepsTheBranchAndSetsUpstreamOnce() throws {
        let plan = try GitPRPlanner.assemble(
            prep: prep(branch: "feature/x", isDefault: false, hasUpstream: false, ahead: 2),
            defaultBranch: "main",
            headOID: String(repeating: "a", count: 40),
            requestedBranchName: "ignored/name",
            commitSubjects: ["newest subject", "older subject"],
            changedFileCount: 3,
            changedFiles: ["Sources/App.swift", "Tests/AppTests.swift", "README.md"]
        )
        XCTAssertEqual(plan.baseBranch, "main")
        XCTAssertEqual(plan.headBranch, "feature/x")
        XCTAssertFalse(plan.createsBranch)
        XCTAssertTrue(plan.setsUpstream)              // no upstream yet → push -u
        XCTAssertEqual(plan.commitSubjects.count, 2)
        XCTAssertEqual(plan.changedFileCount, 3)
        XCTAssertEqual(plan.changedFiles, ["Sources/App.swift", "Tests/AppTests.swift", "README.md"])
        XCTAssertEqual(plan.title, "newest subject")
        XCTAssertEqual(plan.body, "- newest subject\n- older subject")

        let tracked = try GitPRPlanner.assemble(
            prep: prep(branch: "feature/x", isDefault: false, hasUpstream: true, ahead: 1),
            defaultBranch: "main",
            headOID: String(repeating: "a", count: 40),
            requestedBranchName: "",
            commitSubjects: ["only"],
            changedFileCount: 1
        )
        XCTAssertFalse(tracked.setsUpstream)          // already tracking → plain push
    }

    func testPlanOnTheDefaultBranchForksTheRequestedBranch() throws {
        let plan = try GitPRPlanner.assemble(
            prep: prep(branch: "main", isDefault: true, hasUpstream: true, ahead: 1),
            defaultBranch: "main",
            headOID: String(repeating: "b", count: 40),
            requestedBranchName: "  kaisola/pr-branch  ",
            commitSubjects: ["work"],
            changedFileCount: 2
        )
        XCTAssertTrue(plan.createsBranch)
        XCTAssertEqual(plan.headBranch, "kaisola/pr-branch")
        XCTAssertTrue(plan.setsUpstream)              // a brand-new branch never tracks
        XCTAssertEqual(plan.baseBranch, "main")
    }

    func testPlanRejectsAnEmptyOrUnsafeForkName() {
        XCTAssertThrowsError(try GitPRPlanner.assemble(
            prep: prep(branch: "main", isDefault: true, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "c", count: 40),
            requestedBranchName: "   ", commitSubjects: ["work"], changedFileCount: 1
        ))
        XCTAssertThrowsError(try GitPRPlanner.assemble(
            prep: prep(branch: "main", isDefault: true, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "c", count: 40),
            requestedBranchName: "bad name; rm -rf /", commitSubjects: ["work"], changedFileCount: 1
        ))
    }

    func testPlanRefusesABranchWithNothingToPush() {
        XCTAssertThrowsError(try GitPRPlanner.assemble(
            prep: prep(branch: "feature/x", isDefault: false, hasUpstream: true, ahead: 0),
            defaultBranch: "main", headOID: String(repeating: "d", count: 40),
            requestedBranchName: "", commitSubjects: [], changedFileCount: 0
        ))
    }

    func testTitleAndBodyFallBackWhenSubjectsAreUnavailable() throws {
        let plan = try GitPRPlanner.assemble(
            prep: prep(branch: "feature/x", isDefault: false, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "e", count: 40),
            requestedBranchName: "", commitSubjects: [], changedFileCount: 0
        )
        XCTAssertEqual(plan.title, GitPRPlanner.fallbackTitle)
        XCTAssertEqual(plan.body, GitPRPlanner.fallbackBody)
    }

    // MARK: - PR draft reseed decision (pure)

    /// Whether a re-prepare ("Review Again") may overwrite a review-stage
    /// draft: only when there is nothing to compare against yet (the first
    /// prepare) or the draft still matches exactly what this model seeded
    /// last time. Anything else is a real user edit and must survive.
    func testShouldReseedDraftOnlyOverwritesUntouchedDefaults() {
        XCTAssertTrue(GitPanelModel.shouldReseedDraft(current: "", previousDefault: nil))
        XCTAssertTrue(GitPanelModel.shouldReseedDraft(current: "anything at all", previousDefault: nil))
        XCTAssertTrue(GitPanelModel.shouldReseedDraft(current: "feature work", previousDefault: "feature work"))
        XCTAssertFalse(GitPanelModel.shouldReseedDraft(current: "My custom PR title", previousDefault: "feature work"))
    }

    func testReviewEditsAreCarriedIntoTheExecutedPlan() throws {
        let reviewed = try GitPRPlanner.assemble(
            prep: prep(branch: "main", isDefault: true, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "f", count: 40),
            requestedBranchName: "kaisola/pr-branch", commitSubjects: ["work"], changedFileCount: 1
        )
        let edited = try reviewed.applyingEdits(
            headBranch: " kaisola/reviewed ",
            title: "  A reviewed title  ",
            body: "Body the user rewrote.\n"
        )
        XCTAssertEqual(edited.headBranch, "kaisola/reviewed")
        XCTAssertEqual(edited.title, "A reviewed title")
        XCTAssertEqual(edited.body, "Body the user rewrote.")
        // Everything the review displayed but did not offer for editing is
        // carried through untouched — execution runs the reviewed plan.
        XCTAssertEqual(edited.baseBranch, reviewed.baseBranch)
        XCTAssertEqual(edited.headOID, reviewed.headOID)
        XCTAssertEqual(edited.changedFiles, reviewed.changedFiles)
        XCTAssertTrue(edited.createsBranch)
    }

    func testReviewEditsRejectAnEmptyTitleOrUnsafeBranch() throws {
        let reviewed = try GitPRPlanner.assemble(
            prep: prep(branch: "main", isDefault: true, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "f", count: 40),
            requestedBranchName: "kaisola/pr-branch", commitSubjects: ["work"], changedFileCount: 1
        )
        XCTAssertThrowsError(try reviewed.applyingEdits(headBranch: "kaisola/ok", title: "   ", body: "b"))
        XCTAssertThrowsError(try reviewed.applyingEdits(headBranch: "no good", title: "t", body: "b"))

        // On an existing branch the head is not editable, so a junk field value
        // cannot rewrite it (nor fail the confirm).
        let onBranch = try GitPRPlanner.assemble(
            prep: prep(branch: "feature/x", isDefault: false, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "f", count: 40),
            requestedBranchName: "", commitSubjects: ["work"], changedFileCount: 1
        )
        XCTAssertEqual(try onBranch.applyingEdits(headBranch: "junk value", title: "t", body: "b").headBranch, "feature/x")
    }

    func testAReviewedPlanIsRefusedOnceTheRepositoryMovesPastIt() throws {
        let plan = try GitPRPlanner.assemble(
            prep: prep(branch: "feature/x", isDefault: false, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "1", count: 40),
            requestedBranchName: "", commitSubjects: ["work"], changedFileCount: 1
        )
        XCTAssertNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: String(repeating: "1", count: 40), currentBranch: "feature/x"
        ))
        XCTAssertNotNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: String(repeating: "2", count: 40), currentBranch: "feature/x"
        ), "a new commit after the review must invalidate the plan")
        XCTAssertNotNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: String(repeating: "1", count: 40), currentBranch: "other"
        ), "a branch switch after the review must invalidate the plan")
    }

    func testReviewedRemoteAndDestinationArePreservedAndInvalidateWhenChanged() throws {
        let reviewedDestination = GitService.PRDestination(
            remoteName: "origin",
            remoteDisplayURL: "https://github.com/acme/widget",
            webURL: "https://github.com/acme/widget",
            remoteIdentity: "reviewed-identity",
            baseBranch: "main",
            isConfigured: true
        )
        let plan = try GitPRPlanner.assemble(
            prep: prep(branch: "feature/x", isDefault: false, hasUpstream: true, ahead: 1),
            defaultBranch: "main",
            destination: reviewedDestination,
            headOID: String(repeating: "7", count: 40),
            requestedBranchName: "",
            commitSubjects: ["work"],
            changedFileCount: 1
        )
        XCTAssertEqual(plan.destination, reviewedDestination)
        XCTAssertNil(GitPRPlanner.stalenessMessage(
            plan: plan,
            currentHeadOID: plan.headOID,
            currentBranch: plan.headBranch,
            currentDestination: reviewedDestination
        ))

        let changedRemote = GitService.PRDestination(
            remoteName: "origin",
            remoteDisplayURL: "https://github.com/acme/other",
            webURL: "https://github.com/acme/other",
            remoteIdentity: "changed-identity",
            baseBranch: "main",
            isConfigured: true
        )
        XCTAssertNotNil(GitPRPlanner.stalenessMessage(
            plan: plan,
            currentHeadOID: plan.headOID,
            currentBranch: plan.headBranch,
            currentDestination: changedRemote
        ))
        XCTAssertTrue(GitPRPlanner.isStale(
            plan: plan,
            currentHeadOID: plan.headOID,
            currentBranch: plan.headBranch,
            currentDestination: changedRemote
        ))
    }

    /// The discriminating case `testAReviewedPlanIsRefusedOnceTheRepositoryMovesPastIt`
    /// does not cover: when the plan forks a new branch, only re-checking the
    /// HEAD OID is not enough — the branch that was checked out at review time
    /// (the default/base branch) must still be checked out at confirm time too,
    /// even if some other branch now happens to point at the same commit.
    func testAPlanThatForksABranchIsRefusedIfTheCheckedOutBranchChangedEvenWithTheSameHeadOID() throws {
        let plan = try GitPRPlanner.assemble(
            prep: prep(branch: "main", isDefault: true, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "3", count: 40),
            requestedBranchName: "kaisola/pr-branch", commitSubjects: ["work"], changedFileCount: 1
        )
        XCTAssertTrue(plan.createsBranch)

        // Still on "main" (the branch it was reviewed on), HEAD unmoved: fine.
        XCTAssertNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: String(repeating: "3", count: 40), currentBranch: "main"
        ))

        // A different branch is checked out that happens to point at the exact
        // same commit (a synced branch, a detached checkout) — the HEAD-OID
        // check alone would pass, but forking "off HEAD" now forks off a
        // branch context nobody reviewed, so this must still be refused.
        XCTAssertNotNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: String(repeating: "3", count: 40), currentBranch: "other"
        ), "checking out a different branch, even at the same commit, must invalidate a plan that forks off it")
    }

    /// `GitPRPlanner.isStale` is the pure seam the panel's background refresh
    /// uses to self-invalidate an open review card — same discrimination as
    /// `stalenessMessage`, but boolean and safe against a refresh snapshot
    /// missing one of its two current identities.
    func testIsStaleMirrorsStalenessMessageAndIgnoresMissingSnapshotData() throws {
        let onBranch = try GitPRPlanner.assemble(
            prep: prep(branch: "feature/x", isDefault: false, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "4", count: 40),
            requestedBranchName: "", commitSubjects: ["work"], changedFileCount: 1
        )
        XCTAssertFalse(GitPRPlanner.isStale(
            plan: onBranch, currentHeadOID: String(repeating: "4", count: 40), currentBranch: "feature/x"
        ))
        XCTAssertTrue(GitPRPlanner.isStale(
            plan: onBranch, currentHeadOID: String(repeating: "5", count: 40), currentBranch: "feature/x"
        ), "a new commit after the review must read as stale")
        XCTAssertTrue(GitPRPlanner.isStale(
            plan: onBranch, currentHeadOID: String(repeating: "4", count: 40), currentBranch: "other"
        ), "a branch switch after the review must read as stale")

        let forking = try GitPRPlanner.assemble(
            prep: prep(branch: "main", isDefault: true, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "6", count: 40),
            requestedBranchName: "kaisola/pr-branch", commitSubjects: ["work"], changedFileCount: 1
        )
        XCTAssertTrue(GitPRPlanner.isStale(
            plan: forking, currentHeadOID: String(repeating: "6", count: 40), currentBranch: "other"
        ), "isStale must apply the same createsBranch discrimination as stalenessMessage")

        // A refresh that could not resolve the current HEAD OID or branch (a
        // transient git failure) must not flip staleness either way.
        XCTAssertFalse(GitPRPlanner.isStale(plan: onBranch, currentHeadOID: nil, currentBranch: "feature/x"))
        XCTAssertFalse(GitPRPlanner.isStale(
            plan: onBranch, currentHeadOID: String(repeating: "4", count: 40), currentBranch: nil
        ))
    }

    // MARK: - Recovering from a confirm that stopped part way

    /// Confirming is three side effects in a row and only the last can simply be
    /// run again. Each completed phase is recorded and named, so a run that
    /// forked a branch or pushed it before failing says so instead of collapsing
    /// into one generic operation error.
    func testCompletedPhasesNameEverySideEffectTheRunLeftBehind() {
        let nothing = PRExecutionProgress()
        XCTAssertFalse(nothing.hasSideEffects)
        XCTAssertEqual(nothing.completedPhases, [])
        XCTAssertNil(nothing.recoveryNote)

        var forked = PRExecutionProgress()
        forked.createdBranch = "kaisola/pr-branch"
        XCTAssertTrue(forked.hasSideEffects)
        XCTAssertEqual(forked.completedPhases, ["Created branch kaisola/pr-branch"])
        XCTAssertEqual(
            forked.recoveryNote,
            "Created branch kaisola/pr-branch. The pull request was not opened."
        )

        var pushed = forked
        pushed.pushedBranch = "kaisola/pr-branch"
        pushed.pushedHeadOID = String(repeating: "a", count: 40)
        pushed.remoteBranchURL = "https://github.com/acme/widget/tree/kaisola/pr-branch"
        XCTAssertEqual(pushed.completedPhases, [
            "Created branch kaisola/pr-branch",
            "Pushed kaisola/pr-branch to the remote",
        ])
        XCTAssertEqual(
            pushed.recoveryNote,
            "Created branch kaisola/pr-branch. Pushed kaisola/pr-branch to the remote. "
                + "The pull request was not opened."
        )
    }

    /// Retry resumes rather than restarts: a phase that already landed is
    /// skipped (a second `checkout -b` only fails), but a push is skipped only
    /// while the remote already has that branch at this exact commit.
    func testRetrySkipsCompletedPhasesButNeverASupersededPush() throws {
        let plan = try GitPRPlanner.assemble(
            prep: prep(branch: "main", isDefault: true, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "a", count: 40),
            requestedBranchName: "kaisola/pr-branch", commitSubjects: ["work"], changedFileCount: 1
        )

        var progress = PRExecutionProgress()
        XCTAssertTrue(progress.needsBranchCreation(for: plan))
        XCTAssertTrue(progress.needsPush(for: plan))
        XCTAssertEqual(
            progress.remainingWork(for: plan),
            "create branch kaisola/pr-branch, then push kaisola/pr-branch to origin, "
                + "then open the pull request against main"
        )

        progress.createdBranch = "kaisola/pr-branch"
        XCTAssertFalse(progress.needsBranchCreation(for: plan))
        XCTAssertTrue(progress.needsPush(for: plan))
        XCTAssertEqual(
            progress.remainingWork(for: plan),
            "push kaisola/pr-branch to origin, then open the pull request against main"
        )

        progress.pushedBranch = "kaisola/pr-branch"
        progress.pushedHeadOID = plan.headOID
        XCTAssertFalse(progress.needsPush(for: plan))
        XCTAssertEqual(progress.remainingWork(for: plan), "open the pull request against main")

        // The same branch name at a newer commit is not the branch that was
        // pushed: skipping the push there would open a pull request missing the
        // work the review promised.
        var moved = plan
        moved.headOID = String(repeating: "b", count: 40)
        XCTAssertTrue(progress.needsPush(for: moved))
    }

    /// "Review Again" after a half-finished run keeps the completed phases the
    /// fresh plan still stands on, and forgets the ones it does not.
    func testProgressCarriedIntoAFreshPlanKeepsOnlyWhatStillHolds() throws {
        let plan = try GitPRPlanner.assemble(
            prep: prep(branch: "kaisola/pr-branch", isDefault: false, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "c", count: 40),
            requestedBranchName: "", commitSubjects: ["work"], changedFileCount: 1
        )
        var progress = PRExecutionProgress()
        progress.createdBranch = "kaisola/pr-branch"
        progress.pushedBranch = "kaisola/pr-branch"
        progress.pushedHeadOID = plan.headOID
        progress.remoteBranchURL = "https://github.com/acme/widget/tree/kaisola/pr-branch"

        let sameCommit = progress.carriedForward(into: plan)
        XCTAssertEqual(sameCommit, progress, "a re-review of the same commit still knows the branch is pushed")

        // A commit landed and the user reviewed again: the branch is still
        // theirs, but what sits on the remote no longer covers this plan.
        var newer = plan
        newer.headOID = String(repeating: "d", count: 40)
        let carried = progress.carriedForward(into: newer)
        XCTAssertEqual(carried.createdBranch, "kaisola/pr-branch")
        XCTAssertNil(carried.pushedBranch)
        XCTAssertNil(carried.pushedHeadOID)
        XCTAssertNil(carried.remoteBranchURL)
        XCTAssertTrue(carried.needsPush(for: newer))

        // A plan for a different branch keeps none of it.
        var other = plan
        other.headBranch = "kaisola/other"
        XCTAssertEqual(progress.carriedForward(into: other), PRExecutionProgress())
    }

    /// The fork a half-finished confirm made is the plan running, not the
    /// repository drifting away from it. Reading it as staleness is exactly what
    /// left the user on a new branch with no way to retry.
    func testAForkThisPlanItselfMadeDoesNotCountAsStaleness() throws {
        let plan = try GitPRPlanner.assemble(
            prep: prep(branch: "main", isDefault: true, hasUpstream: true, ahead: 1),
            defaultBranch: "main", headOID: String(repeating: "8", count: 40),
            requestedBranchName: "kaisola/pr-branch", commitSubjects: ["work"], changedFileCount: 1
        )
        let oid = String(repeating: "8", count: 40)
        XCTAssertTrue(plan.createsBranch)

        // Before the fork runs, standing on the head branch is somebody else's
        // checkout and must still be refused.
        XCTAssertNotNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: oid, currentBranch: plan.headBranch
        ))
        XCTAssertTrue(GitPRPlanner.isStale(
            plan: plan, currentHeadOID: oid, currentBranch: plan.headBranch
        ))

        // Once this plan's own fork landed, that branch IS where the retry must
        // be standing.
        XCTAssertNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: oid, currentBranch: plan.headBranch,
            completedBranchCreation: true
        ))
        XCTAssertFalse(GitPRPlanner.isStale(
            plan: plan, currentHeadOID: oid, currentBranch: plan.headBranch,
            completedBranchCreation: true
        ))

        // It licenses that branch and nothing else: going back to the base, or
        // off to a third branch, still refuses.
        XCTAssertNotNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: oid, currentBranch: plan.baseBranch,
            completedBranchCreation: true
        ))
        XCTAssertNotNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: oid, currentBranch: "someone/else",
            completedBranchCreation: true
        ))
        // And a moved HEAD is still a moved HEAD.
        XCTAssertNotNil(GitPRPlanner.stalenessMessage(
            plan: plan, currentHeadOID: String(repeating: "9", count: 40),
            currentBranch: plan.headBranch, completedBranchCreation: true
        ))
    }

    // MARK: - Live model behavior

    /// The first click must assemble a review and execute NOTHING: no fork, no
    /// push, no `gh`, even with a real web destination configured.
    @MainActor
    func testPreparingAPullRequestOnlyAssemblesAReview() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])
        try git(["checkout", "-q", "-b", "feature/live"])
        try write("b.txt", "two\n")
        try git(["add", "b.txt"])
        try git(["commit", "-q", "-m", "feature work"])
        try git(["remote", "add", "origin", "git@github.com:acme/widget.git"])

        let model = GitPanelModel(repoRoot: repo)
        model.preparePR()
        XCTAssertTrue(pump(until: { model.prPlan != nil || model.errorMessage != nil }, timeout: 10))

        let plan = try XCTUnwrap(model.prPlan, "expected a review plan, error: \(model.errorMessage ?? "none")")
        XCTAssertEqual(plan.headBranch, "feature/live")
        XCTAssertFalse(plan.createsBranch)
        XCTAssertEqual(plan.baseBranch, "main")
        XCTAssertEqual(plan.commitSubjects, ["feature work"])
        XCTAssertEqual(plan.changedFileCount, 1)
        XCTAssertEqual(plan.changedFiles, ["b.txt"])
        XCTAssertEqual(plan.destination.remoteName, "origin")
        XCTAssertEqual(plan.destination.remoteDisplayURL, "ssh://github.com/acme/widget")
        XCTAssertEqual(plan.destination.webURL, "https://github.com/acme/widget")
        XCTAssertTrue(plan.destination.isReadyForPullRequest)
        XCTAssertEqual(model.prTitleDraft, "feature work")

        // Nothing ran: no PR/compare URL, no error, no new branch, HEAD unmoved.
        XCTAssertNil(model.prURL)
        XCTAssertNil(model.prState)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try gitOutput(["branch", "--format=%(refname:short)"]).split(separator: "\n").sorted(),
                       ["feature/live", "main"])
    }

    /// Event-driven refresh: an external `git add` (an agent, a terminal) must
    /// reach the open panel on its own — no manual refresh, no 3s poll tick.
    @MainActor
    func testExternalStagingRefreshesTheOpenPanel() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("b.txt", "two\n")

        let model = GitPanelModel(repoRoot: repo)
        model.startWatching()
        defer { model.stopWatching() }
        XCTAssertTrue(pump(until: { model.status != nil }, timeout: 10), "the panel should load its first status")
        XCTAssertEqual(model.status?.untracked, ["b.txt"])

        // External stage — nothing in the app touches the model.
        try git(["add", "b.txt"])
        let sawStage = pump(until: { model.status?.staged.isEmpty == false }, timeout: 12)
        XCTAssertTrue(sawStage, "an external `git add` must refresh the panel through the watcher")
        XCTAssertEqual(model.status?.staged.map(\.path), ["b.txt"])
    }

    @MainActor
    func testExternalStagePublishesFileStateAndAllCountersAtomically() throws {
        try write("tracked.txt", "one\ntwo\n")
        try git(["add", "tracked.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("tracked.txt", "ONE\ntwo\n")
        try git(["add", "tracked.txt"])
        try write("tracked.txt", "ONE\nTWO\n")

        let model = GitPanelModel(repoRoot: repo)
        var published: [GitService.Status] = []
        let observation = model.$status.compactMap { $0 }.sink { published.append($0) }
        defer { observation.cancel() }
        model.startWatching()
        defer { model.stopWatching() }
        XCTAssertTrue(pump(until: { model.status != nil }, timeout: 10))
        let before = try XCTUnwrap(model.status)
        XCTAssertEqual(before.stagedStats, .init(additions: 1, deletions: 1, textFiles: 1))
        XCTAssertEqual(before.unstagedStats, .init(additions: 1, deletions: 1, textFiles: 1))
        XCTAssertEqual(before.combinedStats, .init(additions: 2, deletions: 2, textFiles: 1))

        try git(["add", "tracked.txt"])
        XCTAssertTrue(
            pump(until: {
                model.status?.stagedStats == .init(additions: 2, deletions: 2, textFiles: 1)
                    && model.status?.unstaged.isEmpty == true
            }, timeout: 12),
            "the Git-directory watcher should publish the externally staged snapshot"
        )
        let after = try XCTUnwrap(model.status)
        XCTAssertEqual(after.staged.map(\.path), ["tracked.txt"])
        XCTAssertTrue(after.unstaged.isEmpty)
        XCTAssertEqual(after.unstagedStats, .empty)
        XCTAssertEqual(after.combinedStats, .init(additions: 2, deletions: 2, textFiles: 1))
        XCTAssertTrue(
            published.allSatisfy { $0 == before || $0 == after },
            "status lists and all counters must move as one published value"
        )
    }

    func testBinaryStatsRenderingNeverInventsLineCounts() {
        XCTAssertEqual(
            GitStatsRendering.summary(.init(binaryFiles: 1)),
            "1 binary"
        )
        XCTAssertEqual(
            GitStatsRendering.summary(.init(additions: 3, deletions: 2, textFiles: 1, binaryFiles: 1)),
            "+3 −2 · 1 binary"
        )
        XCTAssertNil(GitStatsRendering.summary(.empty))
    }

    func testGitStatusAccessibilityExpandsEveryPorcelainState() {
        XCTAssertEqual(GitStatusAccessibility.statusName(for: "M"), "Modified")
        XCTAssertEqual(GitStatusAccessibility.statusName(for: "A"), "Added")
        XCTAssertEqual(GitStatusAccessibility.statusName(for: "D"), "Deleted")
        XCTAssertEqual(GitStatusAccessibility.statusName(for: "?"), "Untracked")
        XCTAssertEqual(GitStatusAccessibility.statusName(for: "R"), "Renamed")
        XCTAssertEqual(GitStatusAccessibility.statusName(for: "C"), "Copied")
        XCTAssertEqual(GitStatusAccessibility.statusName(for: "T"), "Type changed")
        XCTAssertEqual(GitStatusAccessibility.statusName(for: "U"), "Unmerged")
        XCTAssertEqual(GitStatusAccessibility.statusName(for: "X"), "Git status X")
    }

    func testGitStatusAccessibilityNamesSectionAndFullPath() {
        XCTAssertEqual(
            GitStatusAccessibility.rowLabel(
                path: "Sources/Feature/Status Row.swift",
                code: "M",
                staged: true
            ),
            "Modified, staged, Sources/Feature/Status Row.swift"
        )
        XCTAssertEqual(
            GitStatusAccessibility.rowLabel(
                path: "資料/新規.swift",
                code: "?",
                staged: false
            ),
            "Untracked, unstaged, 資料/新規.swift"
        )
    }

    @MainActor
    func testRejectingCommitMessageHookKeepsDraftAndStagedIndexVisible() throws {
        try write("base.txt", "base\n")
        try git(["add", "base.txt"])
        try git(["commit", "-q", "-m", "base"])
        let headBeforeCommit = try gitOutput(["rev-parse", "HEAD"])
        try write("pending.txt", "keep staged\n")
        try git(["add", "pending.txt"])
        try installCommitMessageHook(
            """
            #!/bin/sh
            printf '%s\n' 'panel hook stdout'
            printf '%s\n' 'panel hook stderr' >&2
            exit 41
            """
        )

        let model = GitPanelModel(repoRoot: repo)
        model.refresh()
        XCTAssertTrue(pump(until: { model.status?.staged.map(\.path) == ["pending.txt"] }, timeout: 10))
        model.commitMessage = "keep my draft"
        model.commit()
        XCTAssertTrue(pump(until: { model.errorMessage != nil && !model.isBusy }, timeout: 10))

        XCTAssertEqual(model.commitMessage, "keep my draft")
        XCTAssertEqual(model.status?.staged.map(\.path), ["pending.txt"])
        XCTAssertFalse(model.errorIsRetryable)
        XCTAssertTrue(model.errorMessage?.contains("git commit exited with status 1") == true)
        XCTAssertTrue(model.errorMessage?.contains("panel hook stdout") == true)
        XCTAssertTrue(model.errorMessage?.contains("panel hook stderr") == true)
        XCTAssertEqual(try gitOutput(["rev-parse", "HEAD"]), headBeforeCommit)
        XCTAssertEqual(
            try gitOutput(["diff", "--cached", "--name-only"])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "pending.txt"
        )
    }

    /// The review card must self-invalidate: a background refresh (an external
    /// commit landing between the review and confirm clicks) marks the open
    /// plan stale so Confirm gets disabled instead of waiting for the user's
    /// own click to discover it as an error.
    @MainActor
    func testBackgroundRefreshMarksAnOpenPlanStale() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])
        try git(["checkout", "-q", "-b", "feature/live"])
        try write("b.txt", "two\n")
        try git(["add", "b.txt"])
        try git(["commit", "-q", "-m", "feature work"])

        let model = GitPanelModel(repoRoot: repo)
        model.preparePR()
        XCTAssertTrue(pump(until: { model.prPlan != nil }, timeout: 10))
        XCTAssertFalse(model.prPlanStale)

        // An external commit lands on the reviewed branch — the plan's
        // recorded HEAD OID no longer matches.
        try write("c.txt", "three\n")
        try git(["add", "c.txt"])
        try git(["commit", "-q", "-m", "external commit"])

        model.refresh()
        XCTAssertTrue(
            pump(until: { model.prPlanStale }, timeout: 10),
            "a background refresh must mark the open plan stale once the repository moves past it"
        )
        XCTAssertNotNil(model.prPlan, "the card stays on screen — only its confirm affordance is disabled")
    }

    /// "Review Again" re-runs `preparePR()` on a stale plan. It must not
    /// clobber a title the user already edited, but an untouched body should
    /// still pick up the regenerated default (a new commit landed).
    @MainActor
    func testReviewAgainPreservesEditedDraftsAndReseedsUntouchedOnes() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])
        try git(["checkout", "-q", "-b", "feature/live"])
        try write("b.txt", "two\n")
        try git(["add", "b.txt"])
        try git(["commit", "-q", "-m", "feature work"])

        let model = GitPanelModel(repoRoot: repo)
        model.preparePR()
        XCTAssertTrue(pump(until: { model.prPlan != nil }, timeout: 10))
        XCTAssertEqual(model.prTitleDraft, "feature work")
        XCTAssertEqual(model.prBodyDraft, "- feature work")

        // The user edits the title but leaves the body exactly as generated.
        model.prTitleDraft = "My custom PR title"

        // An external commit lands, making the reviewed plan stale and
        // changing what a fresh assembly would generate as defaults.
        try write("c.txt", "three\n")
        try git(["add", "c.txt"])
        try git(["commit", "-q", "-m", "more feature work"])
        model.refresh()
        XCTAssertTrue(pump(until: { model.prPlanStale }, timeout: 10))

        // Review Again.
        model.preparePR()
        XCTAssertTrue(
            pump(until: { !model.prPlanStale && model.prPlan?.commitSubjects.count == 2 }, timeout: 10)
        )

        XCTAssertEqual(
            model.prTitleDraft, "My custom PR title",
            "an edited draft must survive Review Again"
        )
        XCTAssertEqual(
            model.prBodyDraft, "- more feature work\n- feature work",
            "an untouched draft should pick up the regenerated default"
        )
    }

    /// GitPanelModel level (not just `GitRefreshPolicy`): an event noted while
    /// an unrelated operation holds the model busy must not be dropped — once
    /// the busy operation clears, the deferred refresh must still run.
    @MainActor
    func testEventDuringBusyProducesADeferredRefreshOnceBusyClears() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])

        let model = GitPanelModel(repoRoot: repo)
        model.refresh()
        XCTAssertTrue(
            pump(until: { model.status != nil && !model.isBusy }, timeout: 10),
            "initial status should load"
        )
        XCTAssertEqual(model.status?.untracked, [])

        // An unrelated operation (loading history) holds the model busy...
        model.loadLog()
        XCTAssertTrue(model.isBusy, "loadLog should mark the model busy synchronously, before its Task runs")

        // ...while an external change lands and is noted.
        try write("b.txt", "two\n")
        model.noteRepositoryEvent()

        XCTAssertTrue(pump(until: { !model.isBusy }, timeout: 10), "the busy operation should complete")
        XCTAssertTrue(
            pump(until: { model.status?.untracked == ["b.txt"] }, timeout: 10),
            "an event noted while busy must still produce a refresh once isBusy clears"
        )
    }

    // MARK: - Commit gating (Return must not bypass the disabled button)

    /// Return in the message field calls `commit()` directly, so `commit()` —
    /// not the button's `.disabled` modifier — is what has to refuse an invalid
    /// commit. HEAD alone cannot prove this: `GitService.commit` rejects a blank
    /// message itself, so an ungated submit leaves HEAD where it was and only
    /// shows up as a failed git run. What each case asserts instead is that no
    /// git operation ever *starts*: `perform` flips `isBusy` synchronously, so
    /// an ungated `commit()` is observable the instant it returns.
    @MainActor
    func testReturnDoesNotCommitWhenTheCommitButtonWouldBeDisabled() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("b.txt", "two\n")
        try git(["add", "b.txt"])

        let model = GitPanelModel(repoRoot: repo)
        model.refresh()
        XCTAssertTrue(pump(until: { model.status != nil && !model.isBusy }, timeout: 10))
        XCTAssertEqual(model.status?.staged.map(\.path), ["b.txt"])

        // Blank message, with a file staged.
        model.commitMessage = ""
        XCTAssertFalse(model.canCommit)
        model.commit()
        XCTAssertFalse(model.isBusy, "a blank-message Return must not start a git commit")

        // Whitespace-only message (spaces, a tab, a newline).
        model.commitMessage = "  \t \n "
        XCTAssertFalse(model.canCommit)
        model.commit()
        XCTAssertFalse(model.isBusy, "a whitespace-only Return must not start a git commit")

        // A perfectly good message, but nothing staged.
        try git(["reset", "-q"])
        model.refresh()
        XCTAssertTrue(pump(until: { model.status?.staged.isEmpty == true && !model.isBusy }, timeout: 10))
        model.commitMessage = "a perfectly good message"
        XCTAssertFalse(model.canCommit)
        model.commit()
        XCTAssertFalse(model.isBusy, "Return with nothing staged must not start a git commit")

        // None of the three reached git: no failure surfaced, HEAD never moved.
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(commitCount(), "1")
    }

    /// The busy case: a git operation already in flight must swallow a Return so
    /// a second git process cannot overlap the first, and the typed message has
    /// to survive the swallowed submit.
    @MainActor
    func testReturnIsIgnoredWhileAnotherGitOperationIsInFlight() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("b.txt", "two\n")
        try git(["add", "b.txt"])

        let model = GitPanelModel(repoRoot: repo)
        model.refresh()
        XCTAssertTrue(pump(until: { model.status?.staged.isEmpty == false && !model.isBusy }, timeout: 10))

        model.commitMessage = "valid message"
        XCTAssertTrue(model.canCommit)

        // An unrelated operation takes the model busy, synchronously.
        model.loadLog()
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canCommit, "a busy model must report Commit as disabled")

        model.commit()
        XCTAssertTrue(pump(until: { !model.isBusy }, timeout: 10))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(commitCount(), "1", "a Return during a busy op must not commit")
        XCTAssertEqual(model.commitMessage, "valid message", "a swallowed submit must keep the message")
    }

    /// The guard must not over-block: a valid keyboard submission still commits,
    /// clears the field, and the service trims the padding off the subject.
    @MainActor
    func testValidKeyboardSubmissionCommitsTheStagedFiles() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])
        try write("b.txt", "two\n")
        try git(["add", "b.txt"])

        let model = GitPanelModel(repoRoot: repo)
        model.refresh()
        XCTAssertTrue(pump(until: { model.status?.staged.isEmpty == false && !model.isBusy }, timeout: 10))

        model.commitMessage = "  a real commit message  "
        XCTAssertTrue(model.canCommit, "a staged file plus a real message must enable Return and the button")

        model.commit()  // exactly what the field's .onSubmit does
        XCTAssertTrue(
            pump(until: { model.commitMessage.isEmpty && !model.isBusy }, timeout: 10),
            "the commit should complete, error: \(model.errorMessage ?? "none")"
        )
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(commitCount(), "2")
        XCTAssertEqual(
            (try? gitOutput(["log", "-1", "--pretty=%s"]))?.trimmingCharacters(in: .whitespacesAndNewlines),
            "a real commit message"
        )
        XCTAssertEqual(model.status?.staged.map(\.path), [], "the commit clears the staged list")
    }

    /// `canCommit` is the shared gate, so it must read exactly like the Commit
    /// button's old enabled condition, and `commitHelp` must say which of the
    /// three blockers is the live one.
    @MainActor
    func testCanCommitMatchesTheButtonStateAndExplainsWhyItIsDisabled() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])

        let model = GitPanelModel(repoRoot: repo)

        // No status loaded yet: nothing is known to be staged, so no commit.
        XCTAssertNil(model.status)
        model.commitMessage = "message"
        XCTAssertFalse(model.canCommit)

        model.refresh()
        XCTAssertTrue(pump(until: { model.status != nil && !model.isBusy }, timeout: 10))
        XCTAssertFalse(model.canCommit, "nothing staged")
        XCTAssertEqual(model.commitHelp, "Stage at least one file before committing")

        try write("b.txt", "two\n")
        try git(["add", "b.txt"])
        model.refresh()
        XCTAssertTrue(pump(until: { model.status?.staged.isEmpty == false && !model.isBusy }, timeout: 10))

        model.commitMessage = ""
        XCTAssertFalse(model.canCommit)
        XCTAssertEqual(model.commitHelp, "Enter a commit message")

        model.commitMessage = " \n\t "
        XCTAssertFalse(model.canCommit, "whitespace-only is not a commit message")
        XCTAssertEqual(model.commitHelp, "Enter a commit message")

        model.commitMessage = "real"
        XCTAssertTrue(model.canCommit)
        XCTAssertEqual(model.commitHelp, "Commit the staged files")
    }

    /// The half-finished confirm, end to end. On the default branch with a
    /// remote nothing can reach, the fork lands and the push fails: the panel
    /// must name the branch it created, keep the review card usable, and let a
    /// retry resume at the push instead of being refused as stale or forking a
    /// second branch.
    @MainActor
    func testAConfirmThatFailsMidwayReportsWhatItDidAndStaysRetryable() throws {
        try write("a.txt", "one\n")
        try git(["add", "a.txt"])
        try git(["commit", "-q", "-m", "base"])
        let baseOID = try gitOutput(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try write("b.txt", "two\n")
        try git(["add", "b.txt"])
        try git(["commit", "-q", "-m", "feature work"])
        // A web destination whose push cannot connect: port 1 refuses instantly,
        // so the confirm fails at the push and never leaves this machine.
        try git(["remote", "add", "origin", "ssh://git@127.0.0.1:1/acme/widget.git"])
        // `main` is the default branch and the PR base, so the plan forks first.
        try git(["update-ref", "refs/remotes/origin/main", baseOID])

        let model = GitPanelModel(repoRoot: repo)
        model.preparePR()
        XCTAssertTrue(pump(until: { model.prPlan != nil || model.errorMessage != nil }, timeout: 10))
        let plan = try XCTUnwrap(model.prPlan, "expected a plan, error: \(model.errorMessage ?? "none")")
        XCTAssertTrue(plan.createsBranch)
        XCTAssertEqual(plan.headBranch, "kaisola/pr-branch")

        model.confirmPR()
        XCTAssertTrue(pump(until: { model.errorMessage != nil }, timeout: 30), "the push should fail")

        // The fork happened, and the panel says so.
        XCTAssertEqual(model.prProgress.createdBranch, "kaisola/pr-branch")
        XCTAssertNil(model.prProgress.pushedBranch, "the push is what failed")
        XCTAssertEqual(model.prProgress.completedPhases, ["Created branch kaisola/pr-branch"])
        XCTAssertEqual(
            model.prState,
            "Created branch kaisola/pr-branch. The pull request was not opened."
        )
        XCTAssertNotNil(model.prPlan, "the review card stays so the run can be finished")
        XCTAssertEqual(
            try gitOutput(["rev-parse", "--abbrev-ref", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "kaisola/pr-branch"
        )

        // A background refresh must not read this plan's own fork as the
        // repository moving past it — that would disable the retry.
        model.refresh()
        XCTAssertTrue(pump(until: { !model.isBusy && model.status != nil }, timeout: 10))
        XCTAssertFalse(model.prPlanStale, "the fork this very plan made is not staleness")

        // Retry resumes at the push: not refused as stale, and no second fork.
        model.confirmPR()
        XCTAssertTrue(pump(until: { model.errorMessage != nil }, timeout: 30))
        let retryError = model.errorMessage ?? ""
        XCTAssertFalse(
            retryError.contains("Review it again"),
            "a retry must not be refused as stale: \(retryError)"
        )
        XCTAssertFalse(
            retryError.contains("already exists"),
            "a retry must not fork the branch a second time: \(retryError)"
        )
        XCTAssertEqual(
            try gitOutput(["branch", "--format=%(refname:short)"]).split(separator: "\n").sorted(),
            ["kaisola/pr-branch", "main"]
        )

        // Dismissing the review must not take the record with it: the branch is
        // still there, so the note that explains it stays too.
        model.cancelPR()
        XCTAssertNil(model.prPlan)
        XCTAssertEqual(
            model.prState,
            "Created branch kaisola/pr-branch. The pull request was not opened."
        )
    }

    // MARK: - helpers

    /// Commits on HEAD, as a string — the cheapest proof that no commit landed.
    @MainActor
    private func commitCount() -> String {
        ((try? gitOutput(["rev-list", "--count", "HEAD"])) ?? "?")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitSeconds(_ decision: GitRefreshPolicy.Decision) -> TimeInterval {
        guard case let .wait(seconds) = decision else {
            XCTFail("expected a wait decision, got \(decision)")
            return .nan
        }
        return seconds
    }

    /// Pump the main run loop until `condition` holds (see WorkspaceWatcherTests):
    /// dispatch-source callbacks and MainActor continuations are only serviced
    /// while the run loop actually runs, so a sleep would starve them.
    @MainActor
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func installCommitMessageHook(_ script: String) throws {
        let hook = repo.appendingPathComponent(".git/hooks/commit-msg")
        try script.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    @discardableResult
    private func git(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = repo
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private func gitOutput(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = repo
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
