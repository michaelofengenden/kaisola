import SwiftUI

/// The persistent, recoverable explanation for a workspace archive that could
/// not be restored.
///
/// Deliberately *not* a toast: the state it describes lasts for the whole
/// session, so it has to still be findable minutes later. It also occupies real
/// layout above the detail pane rather than floating over it, because the
/// window it explains is usually empty and covering that empty state's own
/// actions would be the wrong trade. Closing the banner collapses it to a
/// compact indicator rather than discarding it; only a successful restore
/// removes it.
struct WorkspaceRestorationNoticeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var projectAccountRecoveryCenter: ProjectAccountRecoveryCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingProjectAccountReset = false

    init(model: AppModel) {
        self.model = model
        _projectAccountRecoveryCenter = ObservedObject(
            wrappedValue: model.projectAccountRecoveryCenter
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            if let notice = model.workspaceRestorationNotice {
                Group {
                    if notice.isBannerDismissed {
                        collapsedIndicator(notice)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        banner(notice)
                            .frame(maxWidth: 620, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if let issue = projectAccountRecoveryCenter.issue {
                projectAccountBanner(issue)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: KaisolaVisualSystem.stateDuration)
                : .spring(response: 0.34, dampingFraction: 0.86),
            value: model.workspaceRestorationNotice
        )
        .animation(
            reduceMotion
                ? .easeOut(duration: KaisolaVisualSystem.stateDuration)
                : .spring(response: 0.34, dampingFraction: 0.86),
            value: projectAccountRecoveryCenter.issue
        )
        .confirmationDialog(
            "Reset all project account overrides?",
            isPresented: $confirmingProjectAccountReset,
            titleVisibility: .visible
        ) {
            Button("Reset Project Accounts", role: .destructive) {
                model.resetProjectAccountsAfterFailure()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kaisola will retain the preserved file, then clear every project's Claude and Codex selection. Agent launches can use app defaults again only after this explicit reset.")
        }
    }

    private func projectAccountBanner(_ issue: ProjectAccountRecoveryIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.title)
                    .font(.callout.weight(.semibold))
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Retry") { model.retryProjectAccountRecovery() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityHint("Read the project-account file again")
                    Button(issue.preservedCopyURL == nil
                        ? "Reveal Original in Finder"
                        : "Reveal Preserved Copy in Finder") {
                        model.revealProjectAccountRecovery()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Reset…", role: .destructive) {
                        confirmingProjectAccountReset = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius)
                .strokeBorder(Color.red.opacity(0.45), lineWidth: KaisolaVisualSystem.focusStroke)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(issue.title)
        .accessibilityIdentifier("kaisola.project-account-recovery")
    }

    private func banner(_ notice: WorkspaceRestorationNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Retry Restore") {
                        Task { await model.retryWorkspaceRestoration() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(notice.isRetrying)
                    .accessibilityLabel("Retry Restore")
                    .accessibilityHint("Read the saved window layout again")

                    Button(notice.revealActionTitle) {
                        model.revealWorkspaceRestorationArchive()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(notice.revealActionTitle)

                    if notice.isRetrying {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Retrying")
                    } else if notice.retryCount > 0 {
                        Text("Retried \(notice.retryCount)×")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 8)
            Button {
                model.dismissWorkspaceRestorationBanner()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Collapse this notice")
            .accessibilityLabel("Collapse Window Layout Notice")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: KaisolaVisualSystem.focusStroke)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.title)
    }

    private func collapsedIndicator(_ notice: WorkspaceRestorationNotice) -> some View {
        Button {
            model.presentWorkspaceRestorationBanner()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                Text(notice.summary)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.35)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(notice.summary)
        .accessibilityHint("Show what happened to your saved window layout")
    }
}
