import SwiftUI

/// The permission review screen: full context, then a decision. Read-only
/// alpha shows the request and routes the decision to the Mac; once control
/// ships and context is complete, allow-once / reject resolve here.
struct PermissionDetailView: View {
    let permission: CompanionPermission
    @EnvironmentObject private var store: CompanionStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var canDecide: Bool {
        store.canControlAgents && (permission.completeness ?? "complete") == "complete"
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let completeness = permission.completeness, completeness != "complete" {
                        contextBanner(completeness)
                    }
                    ForEach(permission.diffs.indices, id: \.self) { i in
                        DiffCard(diff: permission.diffs[i])
                    }
                    if permission.diffs.isEmpty {
                        Text("This request has no file changes to preview.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14).kaisolaInset()
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) { decisionBar }
        }
        .navigationTitle("Permission")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text((permission.kind ?? "Permission").capitalized.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced)).tracking(0.6)
                    .foregroundStyle(KaisolaTheme.waiting)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(KaisolaTheme.waiting.opacity(0.16), in: Capsule())
                if let project = store.project(for: permission.projectId) {
                    Text(project.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Text(permission.title).font(.title3.weight(.semibold))
            Text("\(permission.agent) is waiting on your decision").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contextBanner(_ completeness: String) -> some View {
        Label("This request's context is \(completeness) on the phone. Approve from your Mac for the full diff.",
              systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).kaisolaInset()
    }

    @ViewBuilder private var decisionBar: some View {
        VStack(spacing: 8) {
            if canDecide {
                HStack(spacing: 10) {
                    Button { resolve("reject") } label: {
                        Text("Reject").font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }.buttonStyle(QuietPressStyle()).foregroundStyle(.primary)
                    Button { resolve("allow") } label: {
                        Text("Allow once").font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 48).foregroundStyle(KaisolaTheme.darkFrame)
                            .background(KaisolaTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }.buttonStyle(QuietPressStyle())
                }
            } else {
                Button { resolve("reject") } label: {
                    Text("Reject").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(KaisolaTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }.buttonStyle(QuietPressStyle()).foregroundStyle(.primary)
                ControlLockedBanner(text: store.canControlAgents
                    ? "Full context isn't available on the phone — approve this one from your Mac."
                    : "Approving needs agent control, which ships in a later update. You can reject from here.")
            }
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private func resolve(_ decision: String) {
        store.resolvePermission(permission.permId, decision: decision)
        dismiss()
    }
}

struct DiffCard: View {
    let diff: CompanionPermissionDiff
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(diff.relativePath)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KaisolaTheme.raised(for: colorScheme))
            diffBody
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
    }

    private var diffBody: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(lines(diff.oldText, sign: "-"), id: \.self) { line in diffLine(line, add: false) }
            ForEach(lines(diff.newText, sign: "+"), id: \.self) { line in diffLine(line, add: true) }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KaisolaTheme.terminalBackground)
    }

    private func diffLine(_ text: String, add: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(add ? KaisolaTheme.done : KaisolaTheme.failed)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
    }

    private func lines(_ text: String, sign: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).prefix(20).map { "\(sign) \($0)" }
    }
}

#Preview {
    let store = CompanionStore.preview()
    return NavigationStack {
        if let permission = store.permissions.first {
            PermissionDetailView(permission: permission)
        } else {
            Text("No pending permission")
        }
    }
    .environmentObject(store)
}
