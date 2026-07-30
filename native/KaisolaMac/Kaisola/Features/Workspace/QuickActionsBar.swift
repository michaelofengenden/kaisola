import SwiftUI

/// A slim per-project strip of one-click command buttons (build / test /
/// dev-server…). Each button runs its action through `run`; editing lives in
/// the project's context menu so an empty project contributes no stray chrome
/// above the session tabs.
///
/// Actions are read into `@State` on appear and re-read whenever the editor
/// reports a change (and when the project id changes, since the view is reused
/// across project switches).
struct QuickActionsBar: View {
    let projectID: String
    let projectName: String
    let run: (QuickAction) -> Void

    @State private var actions: [QuickAction] = []

    /// Only actions with a real command earn a button; a half-filled row in the
    /// editor never shows a blank chip in the bar.
    private var runnable: [QuickAction] {
        actions.filter { !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        Group {
            if !runnable.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(runnable) { action in
                            Button {
                                run(action)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "play.fill").font(.system(size: 9))
                                    Text(action.title.isEmpty ? action.command : action.title)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Run “\(action.command)” in a new terminal in \(projectName)")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: projectID) { _, _ in reload() }
    }

    private func reload() {
        actions = QuickActionStore().actions(forProject: projectID)
    }
}

/// The gear popover editor: one row per action (title + command + delete), an
/// Add button, capped at eight. Every mutation — field edit, add, delete —
/// persists immediately to `QuickActionStore` and calls `onSave` so the bar
/// refreshes its buttons live.
struct QuickActionsEditor: View {
    let projectID: String
    let projectName: String
    let onSave: () -> Void

    @State private var actions: [QuickAction] = []

    /// Matches `QuickActionStore.capPerProject`; kept here to disable Add at the
    /// ceiling instead of silently dropping the oldest on save.
    private let cap = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Actions").font(.headline)
                Text(projectName).font(.caption).foregroundStyle(.secondary)
            }
            if actions.isEmpty {
                Text("No actions yet. Add a build, test, or dev-server command — it runs in a fresh terminal here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach($actions) { $action in
                HStack(spacing: 6) {
                    TextField("Title", text: $action.title)
                        .frame(width: 96)
                    TextField("command", text: $action.command)
                        .frame(minWidth: 180)
                    Button {
                        delete(action.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this action")
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            }
            HStack {
                Button {
                    addRow()
                } label: {
                    Label("Add Action", systemImage: "plus")
                }
                .disabled(actions.count >= cap)
                .help(actions.count >= cap ? "Up to \(cap) actions per project" : "Add a command button")
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { actions = QuickActionStore().actions(forProject: projectID) }
        .onChange(of: actions) { _, updated in persist(updated) }
    }

    private func addRow() {
        guard actions.count < cap else { return }
        actions.append(QuickAction(id: UUID().uuidString, title: "", command: ""))
    }

    private func delete(_ id: String) {
        actions.removeAll { $0.id == id }
    }

    private func persist(_ updated: [QuickAction]) {
        QuickActionStore().save(updated, forProject: projectID)
        onSave()
    }
}
