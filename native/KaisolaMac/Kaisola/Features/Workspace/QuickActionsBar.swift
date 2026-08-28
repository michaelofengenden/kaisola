import SwiftUI

// The legacy top-bar shell's persistent `QuickActionsBar` strip lived here
// until the 2026-08-28 graduation deleted that shell. Saved Quick Actions
// keep their working doors: each project's context menu ("Quick Actions…"
// opens the editor below) and the command palette still run them.

/// One reversible editor deletion. A unique token fences stale SwiftUI button
/// closures after another row is removed, while the action value and original
/// index preserve exact identity, command bytes, and ordering.
struct QuickActionDeletionUndo: Equatable, Identifiable, Sendable {
    let id: UUID
    let action: QuickAction
    let originalIndex: Int

    init(id: UUID = UUID(), action: QuickAction, originalIndex: Int) {
        self.id = id
        self.action = action
        self.originalIndex = originalIndex
    }

    static func actionDescriptor(for action: QuickAction, originalIndex: Int) -> String {
        let hasInvalidTitle = action.validationIssues.contains { issue in
            switch issue {
            case .titleRequired, .titleTooLong, .titleContainsControlCharacters:
                return true
            case .commandRequired, .commandTooLong, .commandContainsControlCharacters:
                return false
            }
        }
        let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hasInvalidTitle, !title.isEmpty else {
            return "Quick Action row \(max(0, originalIndex) + 1)"
        }
        return "Quick Action “\(title)”"
    }

    var actionDescriptor: String {
        Self.actionDescriptor(for: action, originalIndex: originalIndex)
    }

    /// Returns nil when this token is no longer current or another mutation
    /// already restored its row identity. Callers must not overwrite newer
    /// editor state in either case.
    func restoring(
        in currentActions: [QuickAction],
        activeUndoID: UUID?
    ) -> [QuickAction]? {
        guard activeUndoID == id,
              !currentActions.contains(where: { $0.id == action.id }) else {
            return nil
        }
        var restored = currentActions
        let insertionIndex = max(0, min(originalIndex, restored.count))
        restored.insert(action, at: insertionIndex)
        return restored
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
    @State private var deletionUndo: QuickActionDeletionUndo?

    /// Matches `QuickActionStore.capPerProject`; kept here to disable Add at the
    /// ceiling instead of silently dropping the oldest on save.
    private let cap = 8

    private var hasValidationErrors: Bool {
        actions.contains { !$0.validationIssues.isEmpty }
    }

    /// Reserve capacity for the exact row that Undo can restore. This keeps a
    /// delete-from-eight → add → undo sequence from exceeding the store cap or
    /// evicting a different action.
    private var canAddAction: Bool {
        actions.count + (deletionUndo == nil ? 0 : 1) < cap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Actions").font(.headline)
                Text(projectName).font(.caption).foregroundStyle(.kaisolaSecondary)
            }
            if actions.isEmpty {
                Text("No actions yet. Add a build, test, or dev-server command — it runs in a fresh terminal here.")
                    .font(.caption)
                    .foregroundStyle(.kaisolaTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach($actions) { $action in
                QuickActionEditorRow(
                    action: $action,
                    rowNumber: rowNumber(for: action.id)
                ) {
                    remove(action.id)
                }
            }
            if let deletionUndo {
                HStack(spacing: 8) {
                    Label(
                        "Removed \(deletionUndo.actionDescriptor).",
                        systemImage: "arrow.uturn.backward.circle"
                    )
                    .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Undo") {
                        restore(deletionUndo)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Undo removing \(deletionUndo.actionDescriptor)")
                    .accessibilityHint("Restores the exact action at its previous position")
                    .accessibilityIdentifier("quick-actions.deletion-undo-button")
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("quick-actions.deletion-undo")
            }
            if hasValidationErrors {
                Label(
                    "Fix highlighted rows to save changes. Previously saved actions remain active.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("quick-actions.validation-summary")
            }
            HStack {
                Button {
                    addRow()
                } label: {
                    Label("Add Action", systemImage: "plus")
                }
                .disabled(!canAddAction)
                .help(
                    canAddAction
                        ? "Add a command button"
                        : "Up to \(cap) actions per project, including the action available to undo"
                )
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            actions = QuickActionStore().load(forProject: projectID).rows.map(\.action)
        }
        .onChange(of: actions) { _, updated in persist(updated) }
    }

    private func addRow() {
        guard canAddAction else { return }
        actions.append(QuickAction(id: UUID().uuidString, title: "", command: ""))
    }

    private func remove(_ id: String) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        deletionUndo = QuickActionDeletionUndo(action: actions[index], originalIndex: index)
        actions.remove(at: index)
    }

    private func restore(_ undo: QuickActionDeletionUndo) {
        guard let restored = undo.restoring(
            in: actions,
            activeUndoID: deletionUndo?.id
        ) else {
            // Clear only this still-active token. A stale button closure must
            // not dismiss a newer deletion's Undo affordance.
            if deletionUndo?.id == undo.id {
                deletionUndo = nil
            }
            return
        }
        deletionUndo = nil
        actions = restored
    }

    private func rowNumber(for id: String) -> Int {
        (actions.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func persist(_ updated: [QuickAction]) {
        do {
            try QuickActionStore().save(updated, forProject: projectID)
            onSave()
        } catch let error {
            switch error {
            case .invalidActions:
                // Field-level feedback is derived from `actions`, while the
                // store leaves the last valid registry untouched until every
                // row is valid again.
                break
            }
        }
    }
}

private struct QuickActionEditorRow: View {
    @Binding var action: QuickAction
    let rowNumber: Int
    let delete: () -> Void

    private var errorMessage: String {
        action.validationIssues.compactMap(\.errorDescription).joined(separator: " ")
    }

    private var actionDescriptor: String {
        QuickActionDeletionUndo.actionDescriptor(
            for: action,
            originalIndex: rowNumber - 1
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Title", text: $action.title)
                    .frame(width: 96)
                    .accessibilityLabel("Quick Action row \(rowNumber) title")
                    .accessibilityHint(
                        "Required, one line, and at most \(QuickAction.maximumTitleBytes) UTF-8 bytes"
                    )
                TextField("command", text: $action.command)
                    .frame(minWidth: 180)
                    .accessibilityLabel("Quick Action row \(rowNumber) command")
                    .accessibilityHint(
                        "Required, one line, and at most \(QuickAction.maximumCommandBytes) UTF-8 bytes"
                    )
                Button(action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove \(actionDescriptor). You can undo this while the editor stays open.")
                .accessibilityLabel("Delete \(actionDescriptor)")
                .accessibilityHint("Removes this action and reveals an Undo control")
            }
            .textFieldStyle(.roundedBorder)
            .font(.callout)

            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Quick Action row \(rowNumber) error. \(errorMessage)")
                    .accessibilityHint("Fix this row before Quick Actions can be saved")
                    .accessibilityIdentifier("quick-actions.validation-row-\(rowNumber)")
            }
        }
    }
}
