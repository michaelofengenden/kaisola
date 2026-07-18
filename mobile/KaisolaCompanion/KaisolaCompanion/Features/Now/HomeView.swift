import SwiftUI

/// The home tab: attention before noise. A Needs You band, then Running, then
/// Recent — each card a tap from the real session. Replaces the orb dashboard.
struct HomeView: View {
    @EnvironmentObject private var store: CompanionStore
    @Environment(\.colorScheme) private var colorScheme

    var onOpenSession: (CompanionSession) -> Void = { _ in }
    var onOpenPermission: (CompanionPermission) -> Void = { _ in }

    private var running: [CompanionSession] {
        store.visibleSessions.filter { $0.status == .running }
            .sorted { ($0.startedAt ?? $0.updatedAt) > ($1.startedAt ?? $1.updatedAt) }
    }
    private var recent: [CompanionSession] {
        store.visibleSessions.filter { $0.status == .done || $0.status == .failed }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6).map { $0 }
    }
    private var summaryLine: String {
        let n = store.needsYouCount, r = running.count, d = recent.count
        return "\(n) need\(n == 1 ? "s" : "") you · \(r) running · \(d) recent"
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    connectionPill

                    if store.needsYouCount > 0 {
                        SectionHeading(title: "Needs you", count: store.needsYouCount, color: KaisolaTheme.waiting)
                            .padding(.top, 4)
                        ForEach(store.permissions) { permission in
                            Button { onOpenPermission(permission) } label: {
                                NeedsYouCard(permission: permission, project: store.project(for: permission.projectId))
                            }
                            .buttonStyle(QuietPressStyle())
                        }
                        ForEach(waitingOrFailedSessions) { session in
                            Button { onOpenSession(session) } label: {
                                SessionCard(session: session, project: store.project(for: session.projectId))
                            }
                            .buttonStyle(QuietPressStyle())
                        }
                    }

                    SectionHeading(title: "Running", count: running.count, color: KaisolaTheme.accent)
                        .padding(.top, 6)
                    if running.isEmpty {
                        EmptyLane(text: "Nothing running. Start an agent on your Mac.")
                    } else {
                        ForEach(running) { session in
                            Button { onOpenSession(session) } label: {
                                SessionCard(session: session, project: store.project(for: session.projectId))
                            }
                            .buttonStyle(QuietPressStyle())
                        }
                    }

                    if !recent.isEmpty {
                        SectionHeading(title: "Recent", count: recent.count, color: KaisolaTheme.done)
                            .padding(.top, 6)
                        ForEach(recent) { session in
                            Button { onOpenSession(session) } label: {
                                SessionCard(session: session, project: store.project(for: session.projectId))
                            }
                            .buttonStyle(QuietPressStyle())
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.large)
        .animation(.smooth(duration: 0.32), value: store.needsYouCount)
    }

    private var waitingOrFailedSessions: [CompanionSession] {
        let represented = Set(store.permissions.compactMap(\.sessionId))
        return store.visibleSessions.filter {
            ($0.status == .waiting || $0.status == .failed) && !represented.contains($0.id)
        }
    }

    private var header: some View {
        Text(summaryLine)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private var connectionPill: some View {
        HStack(spacing: 7) {
            PulseDot(color: store.connection == .live ? KaisolaTheme.done : KaisolaTheme.electric,
                     animated: store.connection == .live, size: 5)
            Text(connectionLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(KaisolaTheme.panel(for: colorScheme), in: Capsule())
        .overlay { Capsule().stroke(KaisolaTheme.border(for: colorScheme), lineWidth: 0.5) }
    }

    private var connectionLabel: String {
        switch store.connection {
        case .live: "Live · connected to your Mac"
        case .reconnecting: "Reconnecting…"
        case .stale: "Cached · reconnecting"
        case .offline: "Offline"
        case .preview: "Local preview"
        }
    }
}

struct NeedsYouCard: View {
    let permission: CompanionPermission
    let project: CompanionProject?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(kindLabel.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(KaisolaTheme.waiting)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(KaisolaTheme.waiting.opacity(0.16), in: Capsule())
                if let project {
                    Text(project.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(relativeTime)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(KaisolaTheme.waiting)
            }
            Text(permission.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text("\(permission.agent) is waiting on your decision")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KaisolaTheme.panel(for: colorScheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(KaisolaTheme.waiting).frame(width: 2.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(KaisolaTheme.waiting.opacity(0.3), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
    }

    private var kindLabel: String {
        switch (permission.kind ?? "").lowercased() {
        case "review": "Review"
        case "question": "Question"
        default: "Permission"
        }
    }
    private var relativeTime: String {
        Date(timeIntervalSince1970: TimeInterval(permission.requestedAt) / 1_000)
            .formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

struct EmptyLane: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

#Preview {
    NavigationStack { HomeView() }
        .environmentObject(CompanionStore.preview())
        .environmentObject(AuthModel.previewSignedIn())
}
