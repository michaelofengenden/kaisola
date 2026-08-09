import AppKit
import Combine
import SwiftUI

/// User-facing identity and cancellation truth for one serialized Git command.
/// Read-only work can be abandoned without changing the repository; mutating
/// work may have completed an earlier Git step before cancellation is observed.
struct GitPanelOperation: Equatable, Sendable {
    enum CancellationPolicy: Equatable, Sendable {
        case readOnly
        case completedChangesRemain

        var description: String {
            switch self {
            case .readOnly: "Safe to cancel; the repository is unchanged."
            case .completedChangesRemain: "Cancel stops the command; completed Git changes remain."
            }
        }

        var cancellationResult: String {
            switch self {
            case .readOnly: "The repository remains unchanged."
            case .completedChangesRemain: "Completed Git changes remain."
            }
        }
    }

    let name: String
    let cancellationPolicy: CancellationPolicy

    var cancellationDescription: String { cancellationPolicy.description }

    func accessibilityValue(cancellationRequested: Bool) -> String {
        if cancellationRequested {
            return "Canceling \(name). \(cancellationPolicy.cancellationResult)"
        }
        return "\(name) in progress. \(cancellationDescription)"
    }

    static let refresh = readOnly("Refreshing Git status")
    static let stageAll = mutating("Staging all changes")
    static let unstageAll = mutating("Unstaging all changes")
    static let pull = mutating("Pulling latest changes")
    static let commit = mutating("Committing changes")
    static let history = readOnly("Loading recent history")
    static let preparePullRequest = readOnly("Preparing pull request review")
    static let createPullRequest = mutating("Pushing and creating pull request")

    static func stage(_ path: String) -> Self { mutating("Staging \(path)") }
    static func unstage(_ path: String) -> Self { mutating("Unstaging \(path)") }
    static func diff(_ path: String) -> Self { readOnly("Loading diff for \(path)") }
    static func restore(_ path: String) -> Self { mutating("Discarding changes to \(path)") }

    private static func readOnly(_ name: String) -> Self {
        .init(name: name, cancellationPolicy: .readOnly)
    }

    private static func mutating(_ name: String) -> Self {
        .init(name: name, cancellationPolicy: .completedChangesRemain)
    }
}

/// Field-local validity for the editable pull-request review. Kept pure so the
/// view, confirmation guard, and tests all apply the same rules while a user is
/// typing instead of discovering them only after pressing Confirm.
struct GitPRDraftValidation: Equatable, Sendable {
    let branchMessage: String?
    let titleMessage: String?

    var isValid: Bool { branchMessage == nil && titleMessage == nil }

    static let valid = GitPRDraftValidation(branchMessage: nil, titleMessage: nil)

    static func evaluate(plan: PRPlan, branch: String, title: String) -> Self {
        let branchMessage: String?
        if plan.createsBranch {
            do {
                _ = try GitPRPlanner.validatedBranchName(branch)
                branchMessage = nil
            } catch {
                branchMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        } else {
            branchMessage = nil
        }

        let titleMessage = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter a title for the pull request."
            : nil
        return GitPRDraftValidation(branchMessage: branchMessage, titleMessage: titleMessage)
    }
}

/// A compact Git panel: branch + ahead/behind, staged / unstaged / untracked
/// files with one-click stage/unstage, and a commit box. Backed by GitService
/// (git as a child process). Operations are serialized so an older status cannot
/// win a race.
///
/// **Refresh is event-driven.** While the panel is open it follows the workspace
/// (`WorkspaceWatcher`, working-tree edits) and the git directory
/// (`GitDirectoryWatcher`, stage/commit/checkout/fetch), filtered through the
/// pure `GitRefreshPolicy` — replacing the fixed 3s poll that was both late for
/// an agent's commit and endless on an idle repository.
///
/// **Opening a pull request is two steps.** `preparePR` assembles a `PRPlan` and
/// shows it; `confirmPR` executes that reviewed plan and nothing else.
@MainActor
final class GitPanelModel: ObservableObject {
    @Published private(set) var status: GitService.Status?
    @Published private(set) var errorMessage: String?
    /// True when the last failure was a command Kaisola *stopped* on its
    /// deadline rather than one that failed. Git never reported anything about
    /// the repository, so the banner offers Retry instead of only explaining.
    @Published private(set) var errorIsRetryable = false
    @Published var commitMessage = ""
    @Published private(set) var activeOperation: GitPanelOperation?
    @Published private(set) var isCancellingOperation = false
    var isBusy: Bool { activeOperation != nil }

    /// Re-runs exactly the operation the timeout interrupted. Nil unless the
    /// last failure was retryable.
    private var retryOperation: (() -> Void)?
    /// Type-erased cancellation for the current generic worker Task. The Git
    /// process capture notices cancellation within 50 ms and stops the complete
    /// process group (including hooks and credential helpers).
    private var cancelActiveWork: (() -> Void)?

    /// One-click PR state: the current branch's push/PR readiness, plus the
    /// result of the last Create-PR run (a PR or compare URL, and a status note).
    @Published private(set) var prPrepInfo: GitService.PRPrep?
    @Published private(set) var prState: String?
    @Published private(set) var prURL: String?

    /// The assembled-but-unexecuted pull request. Non-nil means the panel is in
    /// its review stage: everything the confirm button will do is on screen and
    /// nothing has run.
    @Published private(set) var prPlan: PRPlan?
    /// True once a background refresh observes that the repository moved past
    /// the open plan (HEAD OID, checked-out branch, remote, or base destination
    /// differs from what it was reviewed against). The card stays on screen so
    /// the user's edits aren't lost, but Confirm is disabled until review.
    @Published private(set) var prPlanStale = false
    /// Review-stage edits. Seeded from the plan when it is assembled.
    @Published var prBranchDraft = "kaisola/pr-branch"
    @Published var prTitleDraft = ""
    @Published var prBodyDraft = ""

    var prDraftValidation: GitPRDraftValidation? {
        guard let prPlan else { return nil }
        return .evaluate(plan: prPlan, branch: prBranchDraft, title: prTitleDraft)
    }

    var canConfirmPR: Bool {
        guard let plan = prPlan, let validation = prDraftValidation else { return false }
        return !isBusy
            && !prPlanStale
            && plan.destination.isReadyForPullRequest
            && validation.isValid
    }

    var prConfirmationHelp: String {
        if isBusy { return "Wait for the current Git operation to finish." }
        if prPlanStale { return "Review the pull request again because the repository changed." }
        guard let plan = prPlan, let validation = prDraftValidation else {
            return "Review the pull request before confirming."
        }
        if !plan.destination.isReadyForPullRequest {
            return "Add a web origin remote, then review the pull request again."
        }
        if let branchMessage = validation.branchMessage { return branchMessage }
        if let titleMessage = validation.titleMessage { return titleMessage }
        return "Push the reviewed branch and create the pull request."
    }
    /// The title/body this model itself last wrote into the drafts above, so
    /// a later re-prepare ("Review Again", once the reviewed plan goes stale)
    /// can tell a user's edit apart from its own previous default and never
    /// silently overwrite it. Nil until the first `preparePR()` completes.
    private var seededPRTitle: String?
    private var seededPRBody: String?

    let repoRoot: URL
    /// Whether the GitHub CLI is installed — resolved once (it may spawn a
    /// subprocess) so the view can render the fallback note without re-probing.
    let ghAvailable: Bool
    private let service: GitService

    /// Which inline patches are open and whether each represents the index.
    /// Every authoritative refresh recomputes these patches with the status in
    /// one detached snapshot, preventing a staged/unstaged label from showing
    /// an old diff after external Git activity.
    private var diffRequests: [String: Bool] = [:]

    // MARK: - Live refresh wiring

    /// Working-tree events. `WorkspaceWatcher` ignores `.git` by design, so it
    /// reports edits but never a stage/commit — hence the second watcher.
    private var workspaceWatcher: WorkspaceWatcher?
    private var workspaceObservation: AnyCancellable?
    /// Git-directory events (`index`, `HEAD`, ref and lock churn).
    private var gitWatcher: GitDirectoryWatcher?

    private let refreshPolicy = GitRefreshPolicy()
    /// The first event of the current debounce window, or nil when nothing is
    /// pending. Later events in the window are absorbed rather than pushing the
    /// deadline out, so a continuous stream cannot starve the refresh.
    private var pendingEventAt: Date?
    /// When git last ran for this panel (any operation) — the rate floor.
    private var lastActivityAt: Date?
    /// The running decide/wait/refresh loop; nil while idle.
    private var refreshPump: Task<Void, Never>?

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
        self.service = GitService(repoRoot: repoRoot)
        self.ghAvailable = GitService.ghAvailable()
    }

    /// Load the current status and start following the repository. Idempotent.
    func startWatching() {
        guard workspaceWatcher == nil, gitWatcher == nil else { return }
        refresh()
        let watcher = WorkspaceWatcher(root: repoRoot)
        workspaceObservation = watcher.$changeToken
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.noteRepositoryEvent() }
            }
        workspaceWatcher = watcher
        gitWatcher = GitDirectoryWatcher(repoRoot: repoRoot) { [weak self] in
            self?.noteRepositoryEvent()
        }
    }

    /// Stop following the repository (the panel closed). Idempotent.
    func stopWatching() {
        workspaceObservation?.cancel()
        workspaceObservation = nil
        workspaceWatcher?.stop()
        workspaceWatcher = nil
        gitWatcher?.stop()
        gitWatcher = nil
        refreshPump?.cancel()
        refreshPump = nil
        pendingEventAt = nil
        cancelActiveOperation()
    }

    /// A workspace or git-directory change was observed. The first event of a
    /// window arms it; the policy decides when it becomes a `git status`.
    func noteRepositoryEvent(at date: Date = Date()) {
        if pendingEventAt == nil { pendingEventAt = date }
        pumpRefreshes()
    }

    /// Drive the pending event to a refresh. Runs only while something is
    /// pending: once the policy reports `.idle` the loop exits and the next event
    /// restarts it, so an untouched repository costs nothing.
    private func pumpRefreshes() {
        guard refreshPump == nil else { return }
        refreshPump = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                switch refreshPolicy.decide(
                    pendingEventAt: pendingEventAt,
                    lastRefreshAt: lastActivityAt,
                    isBusy: isBusy,
                    now: Date()
                ) {
                case .idle:
                    self.refreshPump = nil
                    return
                case let .wait(seconds):
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                case .refresh:
                    self.pendingEventAt = nil
                    self.refresh()
                }
            }
        }
    }

    func refresh() {
        let requests = diffRequests
        perform(.refresh) { svc -> GitRefreshSnapshot in
            let status = try svc.status()
            let livePaths = Set(
                status.staged.map(\.path)
                    + status.unstaged.map(\.path)
                    + status.untracked
            )
            var patches: [String: String] = [:]
            for (path, staged) in requests where livePaths.contains(path) {
                guard let patch = try? svc.diff(path: path, staged: staged) else { continue }
                patches[path] = patch.isEmpty ? "No changes." : patch
            }
            return GitRefreshSnapshot(
                status: status,
                prep: try? svc.prPrep(),
                headOID: try? svc.headOID(),
                destination: svc.prDestination(),
                diffs: patches
            )
        } apply: { snapshot in
            self.status = snapshot.status
            self.prPrepInfo = snapshot.prep
            self.diffs = snapshot.diffs
            self.diffRequests = self.diffRequests.filter { snapshot.diffs[$0.key] != nil }
            // An open review card must not silently outlive the repository it
            // was assembled against: once a background refresh sees the HEAD
            // OID or checked-out branch differ from the plan's recorded
            // identities, mark it stale so the UI disables Confirm instead of
            // waiting for the user's own click to discover it as an error.
            if let plan = self.prPlan {
                self.prPlanStale = GitPRPlanner.isStale(
                    plan: plan,
                    currentHeadOID: snapshot.headOID,
                    currentBranch: snapshot.prep?.branch,
                    currentDestination: snapshot.destination
                )
            } else {
                self.prPlanStale = false
            }
        } onError: { _ in
            // A failed refresh cannot certify that the old branch/file state is
            // still true. Clear it instead of presenting stale Git controls.
            self.status = nil
            self.prPrepInfo = nil
            self.diffs.removeAll()
            self.diffRequests.removeAll()
            self.log.removeAll()
        }
    }

    func stage(_ path: String) {
        perform(.stage(path)) { try $0.stage(path: path); return try $0.status() } apply: {
            self.status = $0
            self.closeDiff(path)
        }
    }

    func unstage(_ path: String) {
        perform(.unstage(path)) { try $0.unstage(path: path); return try $0.status() } apply: {
            self.status = $0
            self.closeDiff(path)
        }
    }

    func stageAll() {
        perform(.stageAll) { try $0.stageAll(); return try $0.status() } apply: {
            self.status = $0
            self.diffs.removeAll()
            self.diffRequests.removeAll()
        }
    }

    func unstageAll() {
        perform(.unstageAll) { try $0.unstageAll(); return try $0.status() } apply: {
            self.status = $0
            self.diffs.removeAll()
            self.diffRequests.removeAll()
        }
    }

    var canPull: Bool {
        !isBusy
            && prPlan == nil
            && status?.isClean == true
            && prPrepInfo?.hasUpstream == true
    }

    var pullHelp: String {
        if isBusy { return "Wait for the current Git operation to finish" }
        if prPlan != nil { return "Finish or cancel the pull request review before pulling" }
        if status?.isClean != true { return "Commit or discard local changes before pulling" }
        if prPrepInfo?.hasUpstream != true { return "Set an upstream branch before pulling" }
        return "Fetch and fast-forward the current branch without creating a merge commit"
    }

    func pull() {
        guard canPull else { return }
        perform(.pull) { service in
            let changed = try service.pullFastForward()
            return GitPullOutcome(
                changed: changed,
                status: try service.status(),
                prep: try? service.prPrep()
            )
        } apply: { outcome in
            self.status = outcome.status
            self.prPrepInfo = outcome.prep
            if outcome.changed {
                self.diffs.removeAll()
                self.diffRequests.removeAll()
                self.log.removeAll()
            }
            ToastCenter.shared.show(
                outcome.changed ? "Pulled latest changes" : "Already up to date",
                style: outcome.changed ? .success : .info
            )
        }
    }

    func commit() {
        let message = commitMessage
        perform(.commit) { (try $0.commit(message: message), try $0.status(), try? $0.prPrep()) } apply: {
            self.status = $0.1
            self.prPrepInfo = $0.2
            self.commitMessage = ""
            self.diffs.removeAll()
            self.diffRequests.removeAll()
            self.log.removeAll()
            ToastCenter.shared.show("Committed \($0.0.prefix(7))", style: .success)
        }
    }

    /// Diffs revealed inline per file, keyed by path.
    @Published private(set) var diffs: [String: String] = [:]
    /// Recent history (lazy, shown at the panel's foot).
    @Published private(set) var log: [GitService.Commit] = []

    func toggleDiff(_ path: String, staged: Bool) {
        guard !isBusy else { return }
        if diffRequests[path] != nil {
            closeDiff(path)
            return
        }
        diffRequests[path] = staged
        perform(.diff(path)) { try $0.diff(path: path, staged: staged) } apply: { patch in
            guard self.diffRequests[path] == staged else { return }
            self.diffs[path] = patch.isEmpty ? "No changes." : patch
        } onError: { _ in
            self.closeDiff(path)
        }
    }

    func loadLog() {
        perform(.history) { try $0.log(limit: 10) } apply: { self.log = $0 }
    }

    /// Discard unstaged changes to a file (destructive; confirmed by the view).
    func restore(_ path: String) {
        perform(.restore(path)) { try $0.restoreFile(path: path); return try $0.status() } apply: {
            self.status = $0
            self.closeDiff(path)
        }
    }

    /// Step one of two: assemble the pull request and show it. Reads only — no
    /// branch is created, nothing is pushed, `gh` is not invoked. Everything the
    /// confirm step will do is derived here, from one consistent snapshot of the
    /// branch (its base, upstream, ahead commits, and the files they touch),
    /// captured *before* a push could set an upstream that empties that range.
    func preparePR() {
        prState = nil
        prURL = nil
        let requested = prBranchDraft
        perform(.preparePullRequest) { service -> PRPlan in
            let destination = service.prDestination()
            let changedFiles = try service.aheadChangedFiles()
            return try GitPRPlanner.assemble(
                prep: try service.prPrep(),
                defaultBranch: destination.baseBranch,
                destination: destination,
                headOID: try service.headOID(),
                requestedBranchName: requested,
                commitSubjects: try service.aheadSubjects(),
                changedFileCount: changedFiles.count,
                changedFiles: changedFiles
            )
        } apply: { plan in
            self.prPlan = plan
            self.prPlanStale = false
            self.prBranchDraft = plan.headBranch
            // "Review Again" re-runs this exact path once the reviewed plan
            // goes stale. Only reseed a field the user left exactly as this
            // model last set it — anything else is a real edit and must
            // survive rather than being clobbered by the fresh default.
            if Self.shouldReseedDraft(current: self.prTitleDraft, previousDefault: self.seededPRTitle) {
                self.prTitleDraft = plan.title
            }
            if Self.shouldReseedDraft(current: self.prBodyDraft, previousDefault: self.seededPRBody) {
                self.prBodyDraft = plan.body
            }
            self.seededPRTitle = plan.title
            self.seededPRBody = plan.body
        }
    }

    /// Whether a review-stage draft should be overwritten with a freshly
    /// assembled default. True on the very first prepare (nothing to compare
    /// against yet) or when the draft still holds exactly the value this
    /// model seeded last time — i.e. the user never touched it since. Pulled
    /// out as a pure decision so it is directly unit-testable.
    nonisolated static func shouldReseedDraft(current: String, previousDefault: String?) -> Bool {
        previousDefault == nil || current == previousDefault
    }

    /// Leave the review without executing anything.
    func cancelPR() {
        guard !isBusy else { return }
        prPlan = nil
        prPlanStale = false
    }

    /// Step two of two: execute the plan that was reviewed, with the reviewer's
    /// edits and nothing else — no re-derivation of the title, body, or branch.
    /// Refuses to run when the repository moved past the reviewed commit, so a
    /// commit or checkout landing between the two clicks (an agent, a terminal)
    /// can never silently turn into a pull request nobody looked at.
    func confirmPR() {
        guard let reviewed = prPlan,
              prDraftValidation?.isValid == true,
              let plan = try? reviewed.applyingEdits(
                headBranch: prBranchDraft,
                title: prTitleDraft,
                body: prBodyDraft
              ) else { return }
        prState = nil
        prURL = nil
        perform(.createPullRequest) { service -> PROutcome in
            if let stale = GitPRPlanner.stalenessMessage(
                plan: plan,
                currentHeadOID: try service.headOID(),
                currentBranch: try service.prPrep().branch,
                currentDestination: service.prDestination()
            ) {
                throw GitService.GitError.commandFailed(stale)
            }
            guard plan.destination.isReadyForPullRequest,
                  let repositoryURL = plan.destination.webURL else {
                throw GitService.GitError.commandFailed(
                    "Add a web origin remote, then review the pull request again."
                )
            }
            if plan.createsBranch {
                try service.createBranchFromHead(named: plan.headBranch)
            }
            try service.pushCurrentBranch(
                setUpstream: plan.setsUpstream,
                remoteName: plan.destination.remoteName
            )

            let result: PRResult
            if GitService.ghAvailable() {
                result = .created(url: try service.createPullRequest(
                    title: plan.title,
                    body: plan.body,
                    baseBranch: plan.baseBranch,
                    headBranch: plan.headBranch,
                    repositoryURL: repositoryURL
                ))
            } else if let compare = service.compareURL(
                destination: plan.destination,
                headBranch: plan.headBranch
            ) {
                result = .compare(url: compare)
            } else {
                throw GitService.GitError.commandFailed("Install the GitHub CLI (gh) or add a GitHub origin remote to open a pull request.")
            }
            return PROutcome(result: result, status: try service.status(), prep: try? service.prPrep())
        } apply: { outcome in
            self.status = outcome.status
            self.prPrepInfo = outcome.prep
            self.prPlan = nil
            self.prPlanStale = false
            self.diffs.removeAll()
            self.diffRequests.removeAll()
            self.log.removeAll()
            switch outcome.result {
            case let .created(url):
                self.prURL = url
                self.prState = "Pull request opened."
                ToastCenter.shared.show("Pull request opened", style: .success)
            case let .compare(url):
                self.prURL = url
                self.prState = "gh not installed — opened a compare page in your browser."
                if let target = URL(string: url) { _ = NSWorkspace.shared.open(target) }
                ToastCenter.shared.show("Opened compare page in browser", style: .info)
            }
        }
    }

    /// Run a git operation off the main actor (git blocks), then apply its
    /// Sendable result back on the main actor. GitService and Status are
    /// Sendable, so nothing unsafe crosses the boundary.
    private func perform<T: Sendable>(
        _ operation: GitPanelOperation,
        _ work: @escaping @Sendable (GitService) throws -> T,
        apply: @escaping @MainActor (T) -> Void,
        onError: (@MainActor (any Error) -> Void)? = nil
    ) {
        guard !isBusy else { return }
        activeOperation = operation
        isCancellingOperation = false
        errorMessage = nil
        errorIsRetryable = false
        retryOperation = nil
        // Every operation re-reads status, so any of them satisfies the refresh
        // policy's rate floor — a stage and an event-driven refresh must not run
        // git twice in the same window.
        lastActivityAt = Date()
        let service = self.service
        let worker = Task.detached(priority: .userInitiated) { try work(service) }
        cancelActiveWork = { worker.cancel() }
        Task { @MainActor [weak self] in
            let result = await worker.result
            guard let self, self.activeOperation == operation else { return }
            self.cancelActiveWork = nil
            var refreshAfterCancellation = false
            defer {
                self.activeOperation = nil
                self.isCancellingOperation = false
                if refreshAfterCancellation { self.refresh() }
            }
            switch result {
            case let .success(value):
                apply(value)
            case let .failure(error):
                if Self.isCancellation(error) {
                    // Cancel is a requested outcome, not a red failure banner.
                    // Mutating operation copy already warned that any completed
                    // Git steps remain; the next refresh reports their truth.
                    self.errorMessage = nil
                    self.errorIsRetryable = false
                    self.retryOperation = nil
                    refreshAfterCancellation = operation.cancellationPolicy == .completedChangesRemain
                    return
                }
                onError?(error)
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.errorIsRetryable = Self.isRetryable(error)
                // Hold the same closures, so Retry re-runs this operation
                // rather than falling back to a generic refresh.
                self.retryOperation = self.errorIsRetryable
                    ? { [weak self] in self?.perform(operation, work, apply: apply, onError: onError) }
                    : nil
            }
        }
    }

    /// Stop the exact worker shown in the progress banner. `GitProcessCapture`
    /// owns process-group termination, so a hook/helper cannot outlive the
    /// canceled operation. The banner stays visible as “Canceling” until the
    /// worker acknowledges the request and the model clears it.
    func cancelActiveOperation() {
        guard activeOperation != nil, let cancelActiveWork else { return }
        isCancellingOperation = true
        self.cancelActiveWork = nil
        cancelActiveWork()
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let gitError = error as? GitService.GitError else { return false }
        return gitError == .cancelled
    }

    /// Whether a failed operation is worth offering again. Pulled out as a pure
    /// decision so the banner's Retry affordance is directly unit-testable.
    nonisolated static func isRetryable(_ error: any Error) -> Bool {
        (error as? GitService.GitError)?.isRetryable ?? false
    }

    /// Run the stopped operation again, from the banner's Retry button.
    func retryLastOperation() {
        guard !isBusy, let retry = retryOperation else { return }
        retryOperation = nil
        errorIsRetryable = false
        retry()
    }

    private func closeDiff(_ path: String) {
        diffRequests[path] = nil
        diffs[path] = nil
    }
}

private struct GitRefreshSnapshot: Sendable {
    let status: GitService.Status
    let prep: GitService.PRPrep?
    let headOID: String?
    let destination: GitService.PRDestination
    let diffs: [String: String]
}

private struct GitPullOutcome: Sendable {
    let changed: Bool
    let status: GitService.Status
    let prep: GitService.PRPrep?
}

/// The terminal outcome of a one-click Create-PR run, carried back across the
/// actor boundary with a fresh status/prep snapshot so the panel updates in one
/// step.
private struct PROutcome: Sendable {
    let result: PRResult
    let status: GitService.Status
    let prep: GitService.PRPrep?
}

private enum PRResult: Sendable {
    case created(url: String)   // gh opened a real pull request
    case compare(url: String)   // gh missing — a browser compare page instead
}

struct GitPanelView: View {
    @StateObject private var model: GitPanelModel
    @State private var restoreCandidate: GitDiscardCandidate?

    init(repoRoot: URL) {
        _model = StateObject(wrappedValue: GitPanelModel(repoRoot: repoRoot))
    }

    /// Internal injection keeps mounted layout contracts deterministic without
    /// weakening the production initializer's repository ownership.
    init(model: GitPanelModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let operation = model.activeOperation {
                operationBanner(operation)
                Divider()
            }
            // An error shows as a banner ABOVE the content — it must never
            // replace the staged/unstaged lists, commit box, and PR section
            // (a transient op failure would otherwise blank the whole panel
            // until a manual refresh).
            if let error = model.errorMessage {
                // A stopped command reads differently from a failed one: amber
                // rather than red, a clock rather than a warning triangle, and a
                // Retry button, because nothing is actually known to be wrong.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(
                        error,
                        systemImage: model.errorIsRetryable ? "clock.badge.exclamationmark" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        (model.errorIsRetryable ? KaisolaStatusTone.needsYou : .failed).foregroundColor
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if model.errorIsRetryable {
                        Button("Retry", action: model.retryLastOperation)
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("git.retry")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(model.errorIsRetryable ? Color.orange.opacity(0.10) : Color.red.opacity(0.08))
                Divider()
            }
            if let status = model.status {
                content(status)
            } else if model.errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.repoRoot) {
            // Git changes frequently arrive outside this panel (agent tools,
            // terminal commands, hooks). Follow the workspace and the git
            // directory while the panel is visible instead of polling: the
            // watchers report the change, GitRefreshPolicy decides when it
            // becomes a `git status`.
            model.startWatching()
            defer { model.stopWatching() }
            // A slow backstop, not the refresh path: it only exists so a
            // dropped filesystem event cannot leave the panel stale forever.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    break
                }
                model.noteRepositoryEvent()
            }
        }
        .confirmationDialog(
            "Discard changes?",
            isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } })
        ) {
            Button("Discard Changes", role: .destructive) {
                if let restoreCandidate { model.restore(restoreCandidate.path) }
                restoreCandidate = nil
            }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: {
            Text(
                restoreCandidate.map {
                    GitDiscardConfirmation.message(path: $0.path, code: $0.code)
                } ?? "These changes will be discarded permanently (git restore)."
            )
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func operationBanner(_ operation: GitPanelOperation) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isCancellingOperation ? "Canceling \(operation.name)…" : operation.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(operation.cancellationDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Git operation")
            .accessibilityValue(
                operation.accessibilityValue(cancellationRequested: model.isCancellingOperation)
            )
            .accessibilityIdentifier("git.operation")
            Button(model.isCancellingOperation ? "Canceling…" : "Cancel") {
                model.cancelActiveOperation()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(model.isCancellingOperation)
            .accessibilityLabel(model.isCancellingOperation ? "Canceling Git operation" : "Cancel Git operation")
            .accessibilityHint(operation.cancellationDescription)
            .accessibilityIdentifier("git.operation.cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
            Text(model.status?.branch ?? "—").font(.subheadline.weight(.medium))
            if let s = model.status, s.ahead > 0 { Text("↑\(s.ahead)").font(.caption).foregroundStyle(.secondary) }
            if let s = model.status, s.behind > 0 { Text("↓\(s.behind)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(action: model.pull) {
                Label("Pull", systemImage: "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canPull)
            .help(model.pullHelp)
            .accessibilityIdentifier("git.pull")
            Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
                .help("Refresh Git status")
                .accessibilityLabel("Refresh Git status")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    @ViewBuilder
    private func content(_ status: GitService.Status) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if status.isClean {
                    ContentUnavailableView("Working tree clean", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 180)
                } else {
                    bulkActions(status)
                    fileSection(
                        "Staged", status.staged.map { ($0.path, $0.code) }, stats: status.stagedStats,
                        action: "Unstage", staged: true
                    ) { model.unstage($0) }
                    fileSection(
                        "Changes", status.unstaged.map { ($0.path, $0.code) }, stats: status.unstagedStats,
                        action: "Stage", staged: false, restorable: true
                    ) { model.stage($0) }
                    fileSection(
                        "Untracked", status.untracked.map { ($0, "?") }, stats: nil,
                        action: "Stage", staged: false
                    ) { model.stage($0) }
                }
                logSection
                prSection
            }
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git.content.scroll")

        if !status.isClean {
            Divider()
            HStack(spacing: 8) {
                TextField("Commit message…", text: $model.commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.commit() }
                Button("Commit") { model.commit() }
                    .disabled(model.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty || status.staged.isEmpty || model.isBusy)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func bulkActions(_ status: GitService.Status) -> some View {
        HStack(spacing: 12) {
            if !status.staged.isEmpty {
                Button {
                    model.unstageAll()
                } label: {
                    Label("Unstage All", systemImage: "minus.circle")
                }
                .accessibilityIdentifier("git.unstageAll")
            }
            if !status.unstaged.isEmpty || !status.untracked.isEmpty {
                Button {
                    model.stageAll()
                } label: {
                    Label("Stage All", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("git.stageAll")
            }
            Spacer()
            if let summary = GitStatsRendering.summary(status.combinedStats) {
                Text("Total \(summary)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("git.stats.combined")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .disabled(model.isBusy)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("History")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.log.isEmpty ? "Show" : "Refresh") { model.loadLog() }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.top, 8)
            ForEach(model.log) { commit in
                HStack(spacing: 8) {
                    Text(commit.shortHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(commit.subject).font(.caption).lineLimit(1)
                    Spacer()
                }
            }
        }
    }

    /// Pull requests in two steps. "Review Pull Request" assembles the plan and
    /// shows it — remote, destination, base and head branch, commits, exact
    /// changed files, and editable title/body — without running anything. "Push
    /// and Create PR" then executes exactly what is on screen (or opens a
    /// browser compare page when gh is absent). The result URL is tappable.
    @ViewBuilder
    private var prSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pull Request")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

            if let plan = model.prPlan {
                reviewStage(plan)
            } else {
                prepareStage
            }

            if let url = model.prURL, let target = URL(string: url) {
                Link(destination: target) {
                    Label(url, systemImage: "link")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let note = model.prState {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if !model.ghAvailable {
                Text("GitHub CLI (gh) not found — the confirm step opens a browser compare page instead.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 10)
    }

    /// Before review: what branch we are on and what it would contain.
    @ViewBuilder
    private var prepareStage: some View {
        if let prep = model.prPrepInfo {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary)
                Text(prep.branch).font(.caption.monospaced())
                if prep.aheadCount > 0 {
                    Text("· \(prep.aheadCount) PR \(prep.aheadCount == 1 ? "commit" : "commits")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("· no pull request commits")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if prep.isDefaultBranch, prep.aheadCount > 0 {
                Text("On \(prep.branch) — the review proposes a new branch for the pull request.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }

        Button {
            model.preparePR()
        } label: {
            Label("Review Pull Request…", systemImage: "list.bullet.rectangle")
                .font(.caption)
        }
        .disabled(reviewDisabled)
        .accessibilityIdentifier("git.pr.review")
        .help("Assemble the pull request and show it before anything is pushed")
    }

    /// The review itself: nothing here has run yet.
    @ViewBuilder
    private func reviewStage(_ plan: PRPlan) -> some View {
        let validation = model.prDraftValidation ?? .valid

        VStack(alignment: .leading, spacing: 6) {
            if model.prPlanStale {
                Label("Repository changed — Review again", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                    .accessibilityIdentifier("git.pr.stale")
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull").font(.caption2).foregroundStyle(.secondary)
                Text(plan.baseBranch).font(.caption.monospaced())
                Image(systemName: "arrow.left").font(.caption2).foregroundStyle(.tertiary)
                Text(plan.headBranch).font(.caption.monospaced())
                if plan.createsBranch {
                    Text("new branch")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Remote")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(plan.destination.remoteName)
                    .font(.caption2.monospaced())
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(plan.destination.remoteDisplayURL)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Push remote \(plan.destination.remoteName), \(plan.destination.remoteDisplayURL)"
            )

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Destination")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(plan.destination.webURL ?? plan.destination.remoteDisplayURL) · \(plan.baseBranch)")
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Pull request destination \(plan.destination.webURL ?? plan.destination.remoteDisplayURL), base branch \(plan.baseBranch)"
            )

            if !plan.destination.isReadyForPullRequest {
                Label("Add a web origin remote, then review again", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                    .accessibilityIdentifier("git.pr.destinationUnavailable")
            }

            Text("\(plan.commitCount) \(plan.commitCount == 1 ? "commit" : "commits") · "
                 + "\(plan.changedFileCount) \(plan.changedFileCount == 1 ? "file" : "files") changed")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(Array(plan.commitSubjects.prefix(6).enumerated()), id: \.offset) { _, subject in
                Text("• \(subject)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if plan.commitSubjects.count > 6 {
                Text("+ \(plan.commitSubjects.count - 6) more")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            if !plan.changedFiles.isEmpty {
                DisclosureGroup {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(plan.changedFiles, id: \.self) { path in
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                } label: {
                    Label(
                        "Review \(plan.changedFiles.count) changed "
                            + "\(plan.changedFiles.count == 1 ? "file" : "files")",
                        systemImage: "doc.on.doc"
                    )
                    .font(.caption2.weight(.medium))
                }
                .accessibilityIdentifier("git.pr.changedFiles")
            }

            if plan.createsBranch {
                TextField("Branch name", text: $model.prBranchDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .accessibilityIdentifier("git.pr.branch")
                    .accessibilityLabel("Pull request branch name")
                    .accessibilityHint(
                        validation.branchMessage ?? "Required branch that will be created when the pull request is confirmed"
                    )
                if let branchMessage = validation.branchMessage {
                    draftFieldError(
                        branchMessage,
                        fieldName: "Branch name",
                        identifier: "git.pr.branch.error"
                    )
                }
            }
            TextField("Title", text: $model.prTitleDraft)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .accessibilityIdentifier("git.pr.title")
                .accessibilityLabel("Pull request title")
                .accessibilityHint(validation.titleMessage ?? "Required pull request title")
            if let titleMessage = validation.titleMessage {
                draftFieldError(
                    titleMessage,
                    fieldName: "Title",
                    identifier: "git.pr.title.error"
                )
            }
            TextEditor(text: $model.prBodyDraft)
                .font(.caption)
                .frame(height: 68)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                .accessibilityIdentifier("git.pr.body")
                .accessibilityLabel("Pull request description")

            if !model.prPlanStale {
                Text(
                    "Nothing has run yet — confirm to push \(plan.headBranch) to "
                        + "\(plan.destination.remoteName) and open the pull request against \(plan.baseBranch)."
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    model.confirmPR()
                } label: {
                    Label("Push and Create PR", systemImage: "arrow.up.forward.square")
                        .font(.caption)
                }
                .disabled(!model.canConfirmPR)
                .accessibilityIdentifier("git.pr.confirm")
                .accessibilityHint(model.prConfirmationHelp)
                .help(model.prConfirmationHelp)
                if model.prPlanStale {
                    Button {
                        model.preparePR()
                    } label: {
                        Label("Review Again", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("git.pr.reprepare")
                }
                Button("Cancel") { model.cancelPR() }
                    .font(.caption)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("git.pr.cancel")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git.pr.reviewStage")
        .accessibilityLabel(model.prPlanStale ? "Pull request review, repository changed, review again" : "Pull request review")
    }

    private func draftFieldError(_ message: String, fieldName: String, identifier: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("\(fieldName) error: \(message)")
    }

    private var reviewDisabled: Bool {
        if model.isBusy { return true }
        guard let prep = model.prPrepInfo else { return true }
        return prep.aheadCount == 0
    }

    @ViewBuilder
    private func fileSection(
        _ title: String,
        _ files: [(String, String)],
        stats: GitService.ChangeStats?,
        action: String,
        staged: Bool,
        restorable: Bool = false,
        perform: @escaping (String) -> Void
    ) -> some View {
        if !files.isEmpty {
            HStack(spacing: 6) {
                Text("\(title) (\(files.count))")
                    .fontWeight(.semibold)
                if let stats, let summary = GitStatsRendering.summary(stats) {
                    Text(summary)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("git.stats.\(staged ? "staged" : "unstaged")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            ForEach(files, id: \.0) { path, code in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(code)
                            .font(.caption.monospaced())
                            .foregroundStyle(color(code))
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        Button {
                            model.toggleDiff(path, staged: staged)
                        } label: {
                            HStack(spacing: 4) {
                                Text((path as NSString).lastPathComponent).lineLimit(1)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                        .help("Show the diff")
                        .accessibilityLabel(
                            GitStatusAccessibility.rowLabel(path: path, code: code, staged: staged)
                        )
                        .accessibilityHint("Show the \(staged ? "staged" : "unstaged") diff")
                        Spacer()
                        if restorable {
                            Button("Discard") {
                                restoreCandidate = GitDiscardCandidate(path: path, code: code)
                            }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                                .disabled(model.isBusy)
                                .accessibilityLabel("Discard unstaged changes to \(path)")
                        }
                        Button(action) { perform(path) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            // Gate every mutating op on isBusy: a fast stage
                            // finishing mid-PR would otherwise clear isBusy,
                            // re-enable Push & Create PR (double-submit), and
                            // clobber status with a stale snapshot.
                            .disabled(model.isBusy)
                            .accessibilityLabel("\(action) \(path)")
                    }
                    if let patch = model.diffs[path] {
                        PatchText(patch: patch)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func color(_ code: String) -> Color {
        switch code {
        case "M": .orange
        case "A": .green
        case "D": .red
        case "?": .secondary
        default: .primary
        }
    }
}

private struct GitDiscardCandidate: Equatable {
    let path: String
    let code: String
}

enum GitStatusAccessibility {
    /// Expand porcelain-v2's compact status codes without changing the visual
    /// row. Unknown codes stay inspectable instead of being announced as an
    /// unexplained letter.
    static func statusName(for code: String) -> String {
        switch code {
        case "M": "Modified"
        case "A": "Added"
        case "D": "Deleted"
        case "?": "Untracked"
        case "R": "Renamed"
        case "C": "Copied"
        case "T": "Type changed"
        case "U": "Unmerged"
        case "": "Unknown Git status"
        default: "Git status \(code)"
        }
    }

    /// The filename button is the row's primary accessible element. Include
    /// the complete relative path and index context so equal basenames and a
    /// partially staged file remain unambiguous to VoiceOver.
    static func rowLabel(path: String, code: String, staged: Bool) -> String {
        "\(statusName(for: code)), \(staged ? "staged" : "unstaged"), \(path)"
    }
}

enum GitDiscardConfirmation {
    /// A destructive restore must identify both the status category and the
    /// complete project-relative path. Keeping the path verbatim makes files
    /// with equal basenames distinguishable and leaves long paths selectable.
    static func message(path: String, code: String) -> String {
        "\(GitStatusAccessibility.statusName(for: code)) unstaged changes to \(path) "
            + "will be discarded permanently (git restore)."
    }
}

enum GitStatsRendering {
    /// Text and binary truth occupy separate parts of the summary. In
    /// particular an all-binary diff renders only "1 binary", never +0/-0.
    static func summary(_ stats: GitService.ChangeStats) -> String? {
        var parts: [String] = []
        if stats.textFiles > 0 {
            parts.append("+\(stats.additions) −\(stats.deletions)")
        }
        if stats.binaryFiles > 0 {
            parts.append("\(stats.binaryFiles) binary")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct GitBoundedPatch: Equatable, Sendable {
    let lines: [String]
    let isTruncated: Bool
}

enum GitPatchRendering {
    static let characterLimit = 160_000
    static let lineLimit = 2_500

    static func bounded(_ patch: String) -> GitBoundedPatch {
        let prefix = patch.prefix(characterLimit)
        let characterTruncated = prefix.endIndex != patch.endIndex
        let allLines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        let lineTruncated = allLines.count > lineLimit
        return GitBoundedPatch(
            lines: allLines.prefix(lineLimit).map(String.init),
            isTruncated: characterTruncated || lineTruncated
        )
    }
}

/// A raw unified diff whose prefixes remain readable in every appearance mode.
/// Semantic color lives in a restrained background tint rather than low-
/// contrast red/green/blue foreground text.
private struct PatchText: View {
    let patch: String

    private var rendered: GitBoundedPatch { GitPatchRendering.bounded(patch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rendered.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 3)
                        .background(tint(for: line))
                    }
                }
                .padding(6)
            }
            if rendered.isTruncated {
                Label("Large diff truncated in this view", systemImage: "ellipsis.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 5)
            }
        }
        .frame(maxHeight: 200)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func tint(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green.opacity(0.13) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red.opacity(0.13) }
        if line.hasPrefix("@@") { return .accentColor.opacity(0.13) }
        return .clear
    }
}
