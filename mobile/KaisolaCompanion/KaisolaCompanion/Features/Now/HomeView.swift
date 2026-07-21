import SwiftUI

/// The home tab is intentionally sparse: exceptions, work happening now, and
/// the latest replies. Full history stays one tap away in Sessions.
struct HomeView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var coordinator: CompanionConnectionCoordinator

    var onOpenSession: (CompanionSession) -> Void = { _ in }
    var onOpenPermission: (CompanionPermission) -> Void = { _ in }

    private var running: [CompanionSession] {
        activitySessions.filter { $0.status == .running }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    private var latest: [CompanionSession] {
        activitySessions.filter { ($0.status == .idle || $0.status == .done) && $0.updatedAt > 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5).map { $0 }
    }
    private var activitySessions: [CompanionSession] {
        store.visibleSessions.filter { $0.kind != .panel }
    }
    private var summaryLine: String {
        let n = store.needsYouCount, r = running.count
        if n == 0 && r == 0 { return "Everything is quiet" }
        return "\(n) need\(n == 1 ? "s" : "") you · \(r) running"
    }

    private var showConnectPrompt: Bool {
        !store.isPreview && !coordinator.isPaired
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()
            if showConnectPrompt {
                connectPrompt
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if store.needsYouCount > 0 {
                        SectionHeading(title: "Needs you", count: store.needsYouCount, color: KaisolaTheme.waiting)
                            .padding(.top, 4)
                        ForEach(store.permissions) { permission in
                            Button { onOpenPermission(permission) } label: {
                                NeedsYouCard(permission: permission, project: store.project(for: permission.projectId))
                            }
                            .buttonStyle(QuietPressStyle())
                        }
                        ForEach(store.attention) { item in
                            if let sessionId = item.sessionId,
                               let session = store.session(for: sessionId) {
                                Button { onOpenSession(session) } label: {
                                    AttentionSummaryCard(item: item, project: store.project(for: item.projectId))
                                }
                                .buttonStyle(QuietPressStyle())
                            } else {
                                AttentionSummaryCard(item: item, project: store.project(for: item.projectId))
                            }
                        }
                        ForEach(waitingOrFailedSessions) { session in
                            Button { onOpenSession(session) } label: {
                                SessionCard(session: session, project: store.project(for: session.projectId))
                            }
                            .buttonStyle(QuietPressStyle())
                        }
                    }

                    if !running.isEmpty {
                        SectionHeading(title: "Running", count: running.count, color: KaisolaTheme.accent)
                            .padding(.top, 6)
                        ForEach(running) { session in
                            Button { onOpenSession(session) } label: {
                                SessionCard(session: session, project: store.project(for: session.projectId))
                            }
                            .buttonStyle(QuietPressStyle())
                        }
                    }

                    if !latest.isEmpty {
                        SectionHeading(title: "Latest replies", count: latest.count, color: KaisolaTheme.done)
                            .padding(.top, 6)
                        ForEach(latest) { session in
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
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.large)
        .animation(.smooth(duration: 0.32), value: store.needsYouCount)
    }

    private var connectPrompt: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(KaisolaTheme.accent)
            Text("Connect your Mac")
                .font(.title2.weight(.semibold))
            Text("Pair with the Kaisola app on your Mac to watch every agent and terminal from here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button { coordinator.presentPairing() } label: {
                Label("Pair your Mac", systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KaisolaTheme.darkFrame)
                    .padding(.horizontal, 22).frame(height: 50)
                    .background(KaisolaTheme.accent, in: Capsule())
            }
            .buttonStyle(QuietPressStyle())
            .padding(.top, 4)
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var waitingOrFailedSessions: [CompanionSession] {
        let represented = Set(store.permissions.compactMap(\.sessionId) + store.attention.compactMap(\.sessionId))
        return activitySessions.filter {
            ($0.status == .waiting || $0.status == .failed) && !represented.contains($0.id)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(summaryLine)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if store.connection == .live || store.isPreview {
                HStack(spacing: 6) {
                    PulseDot(color: store.connection == .live ? KaisolaTheme.done : KaisolaTheme.electric,
                             animated: store.connection == .live, size: 4)
                    Text(store.connection == .live ? "LIVE" : "PREVIEW")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.7)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}

private struct AttentionSummaryCard: View {
    let item: CompanionAttention
    let project: CompanionProject?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(item.severity == "critical" ? KaisolaTheme.failed : KaisolaTheme.waiting)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([project?.name, item.kind.capitalized].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: item.sessionId == nil ? "circle" : "chevron.right")
                .font(.caption2.weight(.semibold)).foregroundStyle(.quaternary)
        }
        .kaisolaCard(padding: 14)
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

#Preview {
    let store = CompanionStore.preview()
    let coordinator = CompanionConnectionCoordinator(store: store)
    return NavigationStack { HomeView() }
        .environmentObject(store)
        .environmentObject(AuthModel.previewSignedIn())
        .environmentObject(coordinator)
}
