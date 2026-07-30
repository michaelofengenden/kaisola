import AppKit
import SwiftUI

/// A compact Git panel: branch + ahead/behind, staged / unstaged / untracked
/// files with one-click stage/unstage, and a commit box. Backed by GitService
/// (git as a child process); refreshes on demand.
@MainActor
final class GitPanelModel: ObservableObject {
    @Published private(set) var status: GitService.Status?
    @Published private(set) var errorMessage: String?
    @Published var commitMessage = ""
    @Published private(set) var isBusy = false

    /// One-click PR state: the current branch's push/PR readiness, plus the
    /// result of the last Create-PR run (a PR or compare URL, and a status note).
    @Published private(set) var prPrepInfo: GitService.PRPrep?
    @Published private(set) var prState: String?
    @Published private(set) var prURL: String?

    let repoRoot: URL
    /// Whether the GitHub CLI is installed — resolved once (it may spawn a
    /// subprocess) so the view can render the fallback note without re-probing.
    let ghAvailable: Bool
    private let service: GitService

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
        self.service = GitService(repoRoot: repoRoot)
        self.ghAvailable = GitService.ghAvailable()
    }

    func refresh() {
        perform { svc -> (GitService.Status, GitService.PRPrep?) in
            (try svc.status(), try? svc.prPrep())
        } apply: {
            self.status = $0.0
            self.prPrepInfo = $0.1
        }
    }

    func stage(_ path: String) {
        perform { try $0.stage(path: path); return try $0.status() } apply: { self.status = $0 }
    }

    func unstage(_ path: String) {
        perform { try $0.unstage(path: path); return try $0.status() } apply: { self.status = $0 }
    }

    func commit() {
        let message = commitMessage
        perform { (try $0.commit(message: message), try $0.status(), try? $0.prPrep()) } apply: {
            self.status = $0.1
            self.prPrepInfo = $0.2
            self.commitMessage = ""
            ToastCenter.shared.show("Committed \($0.0.prefix(7))", style: .success)
        }
    }

    /// Diffs revealed inline per file, keyed by path.
    @Published private(set) var diffs: [String: String] = [:]
    /// Recent history (lazy, shown at the panel's foot).
    @Published private(set) var log: [GitService.Commit] = []

    func toggleDiff(_ path: String, staged: Bool) {
        if diffs[path] != nil {
            diffs[path] = nil
            return
        }
        perform { try $0.diff(path: path, staged: staged) } apply: { patch in
            self.diffs[path] = patch.isEmpty ? "No changes." : patch
        }
    }

    func loadLog() {
        perform { try $0.log(limit: 10) } apply: { self.log = $0 }
    }

    /// Discard unstaged changes to a file (destructive; confirmed by the view).
    func restore(_ path: String) {
        perform { try $0.restoreFile(path: path); return try $0.status() } apply: {
            self.status = $0
            self.diffs[path] = nil
        }
    }

    /// One-click "committed work → pushed branch + opened PR". Runs the whole
    /// sequence off the main actor in a single `perform`: fork a branch when on
    /// the default branch, capture the PR title/body from the ahead commits
    /// (before the push sets an upstream that would empty that range), push
    /// (-u the first time), then either `gh pr create` or — when gh is missing —
    /// resolve a browser compare URL. The apply step reports the result and
    /// refreshes branch/ahead state (the branch may have changed).
    func createPR(branchName rawName: String) {
        prState = nil
        prURL = nil
        let branchName = rawName.trimmingCharacters(in: .whitespaces)
        perform { service -> PROutcome in
            let prep = try service.prPrep()
            if prep.isDefaultBranch {
                guard !branchName.isEmpty else {
                    throw GitService.GitError.commandFailed("Enter a branch name for the pull request.")
                }
                try service.createBranchFromHead(named: branchName)
            }
            let subjects = try service.aheadSubjects()
            let title = subjects.first ?? "Kaisola changes"
            let body = subjects.isEmpty
                ? "Opened from Kaisola."
                : subjects.map { "- \($0)" }.joined(separator: "\n")

            let hasUpstream = (try? service.prPrep().hasUpstream) ?? false
            try service.pushCurrentBranch(setUpstream: !hasUpstream)

            let result: PRResult
            if GitService.ghAvailable() {
                result = .created(url: try service.createPullRequest(title: title, body: body))
            } else if let compare = try service.compareURL() {
                result = .compare(url: compare)
            } else {
                throw GitService.GitError.commandFailed("Install the GitHub CLI (gh) or add a GitHub origin remote to open a pull request.")
            }
            return PROutcome(result: result, status: try service.status(), prep: try? service.prPrep())
        } apply: { outcome in
            self.status = outcome.status
            self.prPrepInfo = outcome.prep
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
        _ work: @escaping @Sendable (GitService) throws -> T,
        apply: @escaping @MainActor (T) -> Void
    ) {
        isBusy = true
        errorMessage = nil
        let service = self.service
        Task {
            do {
                let value = try await Task.detached { try work(service) }.value
                apply(value)
                isBusy = false
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isBusy = false
            }
        }
    }
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
    @State private var restoreCandidate: String?
    @State private var prBranchName = "kaisola/pr-branch"

    init(repoRoot: URL) {
        _model = StateObject(wrappedValue: GitPanelModel(repoRoot: repoRoot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // An error shows as a banner ABOVE the content — it must never
            // replace the staged/unstaged lists, commit box, and PR section
            // (a transient op failure would otherwise blank the whole panel
            // until a manual refresh).
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08))
                Divider()
            }
            if let status = model.status {
                content(status)
            } else if model.errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { model.refresh() }
        .confirmationDialog(
            "Discard changes?",
            isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } })
        ) {
            Button("Discard Changes", role: .destructive) {
                if let restoreCandidate { model.restore(restoreCandidate) }
                restoreCandidate = nil
            }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: {
            Text("Unstaged changes to \((restoreCandidate as NSString?)?.lastPathComponent ?? "this file") are discarded permanently (git restore).")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
            Text(model.status?.branch ?? "—").font(.subheadline.weight(.medium))
            if let s = model.status, s.ahead > 0 { Text("↑\(s.ahead)").font(.caption).foregroundStyle(.secondary) }
            if let s = model.status, s.behind > 0 { Text("↓\(s.behind)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    @ViewBuilder
    private func content(_ status: GitService.Status) -> some View {
        if status.isClean {
            VStack(spacing: 0) {
                ContentUnavailableView("Working tree clean", systemImage: "checkmark.seal")
                logSection
                prSection
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    fileSection("Staged", status.staged.map { ($0.path, $0.code) }, action: "Unstage", staged: true) { model.unstage($0) }
                    fileSection("Changes", status.unstaged.map { ($0.path, $0.code) }, action: "Stage", staged: false, restorable: true) { model.stage($0) }
                    fileSection("Untracked", status.untracked.map { ($0, "?") }, action: "Stage", staged: false) { model.stage($0) }
                    logSection
                    prSection
                }
                .padding(12)
            }
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
        .padding(.horizontal, model.status?.isClean == true ? 12 : 0)
    }

    /// One-click Create-PR: the current branch + ahead count, a new-branch field
    /// when sitting on the default branch, and the button that pushes and opens
    /// the PR (or a browser compare page when gh is absent). The result URL is a
    /// tappable Link.
    @ViewBuilder
    private var prSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Create PR")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

            if let prep = model.prPrepInfo {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary)
                    Text(prep.branch).font(.caption.monospaced())
                    if prep.aheadCount > 0 {
                        Text("· \(prep.aheadCount) ahead").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("· nothing to push").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                if prep.isDefaultBranch {
                    Text("On \(prep.branch) — a new branch is created for the PR.")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("Branch name", text: $prBranchName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
            }

            Button {
                model.createPR(branchName: prBranchName)
            } label: {
                Label("Push & Create PR", systemImage: "arrow.up.forward.square")
                    .font(.caption)
            }
            .disabled(createPRDisabled)

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
                Text("GitHub CLI (gh) not found — Create PR opens a browser compare page instead.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, model.status?.isClean == true ? 12 : 0)
        .padding(.bottom, 10)
    }

    private var createPRDisabled: Bool {
        if model.isBusy { return true }
        guard let prep = model.prPrepInfo else { return true }
        if prep.isDefaultBranch && prBranchName.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return prep.aheadCount == 0
    }

    @ViewBuilder
    private func fileSection(
        _ title: String,
        _ files: [(String, String)],
        action: String,
        staged: Bool,
        restorable: Bool = false,
        perform: @escaping (String) -> Void
    ) -> some View {
        if !files.isEmpty {
            Text("\(title) (\(files.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(files, id: \.0) { path, code in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(code).font(.caption.monospaced()).foregroundStyle(color(code)).frame(width: 14)
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
                        .help("Show the diff")
                        Spacer()
                        if restorable {
                            Button("Discard") { restoreCandidate = path }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .disabled(model.isBusy)
                        }
                        Button(action) { perform(path) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            // Gate every mutating op on isBusy: a fast stage
                            // finishing mid-PR would otherwise clear isBusy,
                            // re-enable Push & Create PR (double-submit), and
                            // clobber status with a stale snapshot.
                            .disabled(model.isBusy)
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

/// A raw unified diff, tinted per line (+ green, − red, @@ blue), horizontally
/// scrollable so long lines never wrap into noise.
private struct PatchText: View {
    let patch: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tint(for: line))
                        .textSelection(.enabled)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 200)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func tint(for line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }
}
