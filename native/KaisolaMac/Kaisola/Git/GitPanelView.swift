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

    let repoRoot: URL
    private let service: GitService

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
        self.service = GitService(repoRoot: repoRoot)
    }

    func refresh() {
        perform { try $0.status() } apply: { self.status = $0 }
    }

    func stage(_ path: String) {
        perform { try $0.stage(path: path); return try $0.status() } apply: { self.status = $0 }
    }

    func unstage(_ path: String) {
        perform { try $0.unstage(path: path); return try $0.status() } apply: { self.status = $0 }
    }

    func commit() {
        let message = commitMessage
        perform { _ = try $0.commit(message: message); return try $0.status() } apply: {
            self.status = $0
            self.commitMessage = ""
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

struct GitPanelView: View {
    @StateObject private var model: GitPanelModel

    init(repoRoot: URL) {
        _model = StateObject(wrappedValue: GitPanelModel(repoRoot: repoRoot))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            } else if let status = model.status {
                content(status)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { model.refresh() }
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
            ContentUnavailableView("Working tree clean", systemImage: "checkmark.seal")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    fileSection("Staged", status.staged.map { ($0.path, $0.code) }, action: "Unstage") { model.unstage($0) }
                    fileSection("Changes", status.unstaged.map { ($0.path, $0.code) }, action: "Stage") { model.stage($0) }
                    fileSection("Untracked", status.untracked.map { ($0, "?") }, action: "Stage") { model.stage($0) }
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
    private func fileSection(_ title: String, _ files: [(String, String)], action: String, perform: @escaping (String) -> Void) -> some View {
        if !files.isEmpty {
            Text("\(title) (\(files.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(files, id: \.0) { path, code in
                HStack(spacing: 8) {
                    Text(code).font(.caption.monospaced()).foregroundStyle(color(code)).frame(width: 14)
                    Text((path as NSString).lastPathComponent).lineLimit(1)
                    Text((path as NSString).deletingLastPathComponent)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    Button(action) { perform(path) }
                        .buttonStyle(.borderless)
                        .font(.caption)
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
