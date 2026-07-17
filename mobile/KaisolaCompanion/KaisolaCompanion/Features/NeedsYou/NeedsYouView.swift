import SwiftUI

struct NeedsYouView: View {
    @EnvironmentObject private var store: CompanionStore

    var body: some View {
        ZStack {
            AmbientBackdrop()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ConsoleHeader(
                        eyebrow: "Action queue",
                        title: "Needs your input",
                        detail: "\(store.needsYouCount) open item\(store.needsYouCount == 1 ? "" : "s")",
                        symbol: "bell"
                    )

                    if store.permissions.isEmpty && store.attention.isEmpty {
                        emptyState
                    } else {
                        if !store.permissions.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeading(title: "Decisions", count: store.permissions.count, color: KaisolaTheme.waiting)
                                ForEach(store.permissions) { permission in
                                    NavigationLink {
                                        PermissionDetailView(permissionId: permission.id)
                                    } label: {
                                        permissionCard(permission)
                                    }
                                    .buttonStyle(QuietPressStyle())
                                }
                            }
                        }

                        if !store.attention.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeading(title: "Review", count: store.attention.count, color: KaisolaTheme.failed)
                                ForEach(store.attention) { item in
                                    NavigationLink {
                                        AttentionDetailView(attentionId: item.id)
                                    } label: {
                                        attentionCard(item)
                                    }
                                    .buttonStyle(QuietPressStyle())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(KaisolaTheme.done.opacity(0.25), lineWidth: 1).frame(width: 68, height: 68)
                Image(systemName: "checkmark")
                    .font(.title2.weight(.light))
                    .foregroundStyle(KaisolaTheme.done)
            }
            Text("All clear")
                .font(.title3.weight(.medium))
            Text("New permissions, failures, and reviews will surface here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }

    private func permissionCard(_ permission: CompanionPermission) -> some View {
        HStack(spacing: 13) {
            PulseDot(color: KaisolaTheme.waiting, size: 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(permission.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(permission.agent)
                    if let path = permission.diffs.first?.relativePath {
                        Text("/")
                        Text(path)
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.quaternary)
        }
        .kaisolaCard(padding: 14)
    }

    private func attentionCard(_ item: CompanionAttention) -> some View {
        let color = item.kind == "failed" ? KaisolaTheme.failed : KaisolaTheme.waiting
        return HStack(spacing: 13) {
            PulseDot(color: color, animated: item.kind == "failed", size: 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.quaternary)
        }
        .kaisolaCard(padding: 14)
    }
}

struct PermissionDetailView: View {
    @EnvironmentObject private var store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    let permissionId: String

    private var permission: CompanionPermission? {
        store.permissions.first { $0.id == permissionId }
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            Group {
                if let permission {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("AGENT REQUEST")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .tracking(1.3)
                                    .foregroundStyle(KaisolaTheme.waiting)
                                Text(permission.title)
                                    .font(.system(size: 28, weight: .medium, design: .rounded))
                                    .tracking(-0.6)
                                Text("\(permission.agent) / \(store.project(for: permission.projectId)?.name ?? "Unknown project")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            ControlLockedBanner(text: "This preview decision stays on this iPhone and never reaches your Mac.")

                            ForEach(Array(permission.diffs.enumerated()), id: \.offset) { _, diff in
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(KaisolaTheme.accent)
                                        Text(diff.relativePath)
                                            .font(.caption.weight(.semibold).monospaced())
                                            .lineLimit(1)
                                    }

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("− \(diff.oldText)").foregroundStyle(KaisolaTheme.failed)
                                        Text("+ \(diff.newText)").foregroundStyle(KaisolaTheme.done)
                                    }
                                    .font(.footnote.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(13)
                                    .kaisolaInset(radius: 12)
                                }
                                .kaisolaCard()
                            }

                            Text("Live V1 will allow a single-use approval or rejection. Persistent permission rules remain a Mac-only decision.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)
                        }
                        .padding(16)
                        .padding(.bottom, 72)
                    }
                    .scrollIndicators(.hidden)
                    .safeAreaInset(edge: .bottom) {
                        decisionBar(permission)
                    }
                } else {
                    ContentUnavailableView("Already resolved", systemImage: "checkmark.circle")
                }
            }
        }
        .navigationTitle("Permission")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func decisionBar(_ permission: CompanionPermission) -> some View {
        HStack(spacing: 10) {
            Button("Reject", role: .destructive) {
                store.resolvePermission(permission.id, decision: "Reject")
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .frame(maxWidth: .infinity)

            Button("Allow once") {
                store.resolvePermission(permission.id, decision: "Allow once")
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

struct AttentionDetailView: View {
    @EnvironmentObject private var store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    let attentionId: String

    private var item: CompanionAttention? { store.attention.first { $0.id == attentionId } }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            if let item {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 20)
                    PulseDot(color: KaisolaTheme.failed, size: 9)
                    Text("REVIEW REQUIRED")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(KaisolaTheme.failed)
                    Text(item.title)
                        .font(.system(size: 30, weight: .medium, design: .rounded))
                        .tracking(-0.7)
                    Text(item.detail ?? "This item needs review.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    ControlLockedBanner(text: "This acknowledgment only changes the local preview.")
                    Spacer()
                    Button("Mark reviewed") {
                        store.acknowledge(item.id)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
            } else {
                ContentUnavailableView("Already reviewed", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}
