import KaisolaCore
import SwiftUI

struct SessionsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case agents = "Agents"
        case terminals = "Terminals"

        var id: Self { self }
    }

    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var rememberedSessions: RememberedSessionCatalogCenter
    @State private var filter: Filter = .all
    @State private var query = ""
    @Namespace private var filterSelection

    private var filtered: [CompanionSession] {
        store.sessions.filter { session in
            guard session.kind != .panel else { return false }
            let matchesKind = switch filter {
            case .all: true
            case .agents: session.kind == .agent
            case .terminals: session.kind == .terminal
            }
            let matchesQuery = query.isEmpty
                || session.title.localizedCaseInsensitiveContains(query)
                || (session.summary?.localizedCaseInsensitiveContains(query) ?? false)
                || (session.provider?.localizedCaseInsensitiveContains(query) ?? false)
                || (store.project(for: session.projectId)?.name.localizedCaseInsensitiveContains(query) ?? false)
                || (store.project(for: session.projectId)?.windowName?.localizedCaseInsensitiveContains(query) ?? false)
            return matchesKind && matchesQuery
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var windowGroups: [SessionWindowGroup] {
        let byWindow = Dictionary(grouping: filtered) { session -> String in
            store.project(for: session.projectId)?.windowId ?? "main"
        }
        return byWindow.map { windowId, sessions in
            let byProject = Dictionary(grouping: sessions, by: \.projectId)
            let projects = byProject.map { projectId, projectSessions in
                SessionProjectGroup(
                    id: projectId,
                    project: store.project(for: projectId),
                    sessions: projectSessions.sorted { $0.updatedAt > $1.updatedAt }
                )
            }.sorted { $0.latestAt > $1.latestAt }
            let project = projects.compactMap(\.project).first
            return SessionWindowGroup(
                id: windowId,
                name: project?.windowName ?? (windowId == "main" || windowId == "primary" ? "Main window" : "Window"),
                projects: projects
            )
        }.sorted { $0.latestAt > $1.latestAt }
    }

    private var activityCount: Int { store.sessions.filter { $0.kind != .panel }.count }
    private var rememberedGroups: [RememberedDeviceGroup] {
        let liveIDs = Set(store.sessions.map(\.id))
        return rememberedSessions.remoteDevices.compactMap { device in
            let sessions = device.sessions.filter { session in
                guard !liveIDs.contains(session.id) else { return false }
                let matchesKind = switch filter {
                case .all: true
                case .agents: session.kind != .terminal
                case .terminals: session.kind == .terminal
                }
                let matchesQuery = query.isEmpty
                    || session.title.localizedCaseInsensitiveContains(query)
                    || session.projectName.localizedCaseInsensitiveContains(query)
                    || (session.agentId?.localizedCaseInsensitiveContains(query) ?? false)
                    || device.deviceName.localizedCaseInsensitiveContains(query)
                return matchesKind && matchesQuery
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            return sessions.isEmpty ? nil : RememberedDeviceGroup(device: device, sessions: sessions)
        }
        .sorted { $0.latestAt > $1.latestAt }
    }
    private var rememberedCount: Int {
        rememberedGroups.reduce(0) { $0 + $1.sessions.count }
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header

                    searchField
                    filterBar

                    if filtered.isEmpty && rememberedGroups.isEmpty {
                        emptyState
                    } else {
                        if !windowGroups.isEmpty {
                            sectionLabel("Connected Mac", count: filtered.count)
                            ForEach(windowGroups) { window in
                                VStack(alignment: .leading, spacing: 11) {
                                    HStack {
                                        Text(window.name.uppercased())
                                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                            .tracking(1.05)
                                        Spacer()
                                        Text(window.sessionCount, format: .number)
                                            .font(.caption2.monospacedDigit())
                                    }
                                    .foregroundStyle(.tertiary)

                                    ForEach(window.projects) { group in
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Text(group.project?.name ?? "Project")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Text(group.sessions.count, format: .number)
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .padding(.horizontal, 3)

                                            ForEach(group.sessions) { session in
                                                NavigationLink {
                                                    SessionDetailView(sessionId: session.id)
                                                } label: {
                                                    SessionCard(session: session, project: group.project)
                                                }
                                                .buttonStyle(QuietPressStyle())
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if !rememberedGroups.isEmpty {
                            rememberedSectionHeader
                            ForEach(rememberedGroups) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    rememberedDeviceHeader(group)
                                    ForEach(group.sessions) { session in
                                        RememberedSessionCard(session: session, device: group.device)
                                    }
                                }
                            }
                        }
                    }

                    if let error = rememberedSessions.errorMessage {
                        Label(error, systemImage: "exclamationmark.icloud")
                            .font(.caption)
                            .foregroundStyle(KaisolaTheme.waiting)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
        .animation(.smooth(duration: 0.28), value: filter)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sessions")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .tracking(-0.7)
            Text("\(activityCount) live · \(rememberedCount) remembered")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(1.05)
            Spacer()
            Text(count, format: .number).font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.tertiary)
    }

    private var rememberedSectionHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                sectionLabel("Remembered on your Macs", count: rememberedCount)
                Button { rememberedSessions.requestRefresh() } label: {
                    if rememberedSessions.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh remembered sessions")
                .disabled(rememberedSessions.isRefreshing)
            }
            if let freshness = rememberedSessions.freshnessTitle {
                Label(freshness, systemImage: rememberedSessions.source == .savedSnapshot
                    ? "clock.arrow.circlepath"
                    : "checkmark.icloud")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Remembered sessions, \(freshness)")
            }
        }
    }

    private func rememberedDeviceHeader(_ group: RememberedDeviceGroup) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(group.device.presence == .online ? KaisolaTheme.done : Color.secondary.opacity(0.45))
                .frame(width: 6, height: 6)
            Text(group.device.deviceName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(group.device.presence == .online ? "ONLINE" : "OFFLINE")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 3)
    }

    @ViewBuilder private var emptyState: some View {
        if rememberedSessions.isRefreshing && query.isEmpty {
            ContentUnavailableView {
                Label("Checking your Macs", systemImage: "icloud.and.arrow.down")
            } description: {
                Text("Loading sessions remembered by your Kaisola account.")
            } actions: {
                ProgressView().controlSize(.small)
            }
            .frame(minHeight: 320)
        } else if query.isEmpty {
            ContentUnavailableView(
                "No sessions yet",
                systemImage: "rectangle.stack",
                description: Text("Live and remembered sessions from your signed-in Macs will appear here.")
            )
            .frame(minHeight: 320)
        } else {
            ContentUnavailableView.search(text: query)
                .frame(minHeight: 320)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            TextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .kaisolaInset(radius: 14)
    }

    private var filterBar: some View {
        HStack(spacing: 7) {
            ForEach(Filter.allCases) { item in
                let selected = item == filter
                Button {
                    withAnimation(.snappy(duration: 0.28)) { filter = item }
                } label: {
                    Text(item.rawValue)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.thinMaterial)
                                    .overlay { Capsule().stroke(KaisolaTheme.accent.opacity(0.24), lineWidth: 0.5) }
                                    .matchedGeometryEffect(id: "session-filter", in: filterSelection)
                            }
                        }
                }
                .buttonStyle(QuietPressStyle())
            }
        }
    }
}

private struct RememberedDeviceGroup: Identifiable {
    var id: String { device.deviceId }
    let device: RememberedDeviceCatalog
    let sessions: [RememberedSessionRecord]
    var latestAt: Int64 { sessions.map(\.lastActivityAt).max() ?? 0 }
}

private struct RememberedSessionCard: View {
    let session: RememberedSessionRecord
    let device: RememberedDeviceCatalog

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(session.projectName) · \(activityTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Date(timeIntervalSince1970: TimeInterval(session.lastActivityAt) / 1_000), style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "icloud")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .kaisolaCard(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.projectName), \(activityTitle), remembered on \(device.deviceName)")
        .accessibilityHint("Connect to this Mac to open or control the session")
    }

    private var symbol: String {
        switch session.kind {
        case .terminal: "terminal"
        case .agentChat: "bubble.left.and.text.bubble.right"
        case .mesh: "circle.hexagongrid.fill"
        }
    }

    private var tint: Color {
        switch session.activity {
        case .working: KaisolaTheme.accent
        case .needsAttention: KaisolaTheme.waiting
        case .idle: .secondary
        case .ended: .secondary.opacity(0.6)
        }
    }

    private var activityTitle: String {
        switch session.activity {
        case .working: "Working"
        case .needsAttention: "Needs attention"
        case .idle: "Idle"
        case .ended: "Ended"
        }
    }
}

private struct SessionProjectGroup: Identifiable {
    let id: String
    let project: CompanionProject?
    let sessions: [CompanionSession]
    var latestAt: Int64 { sessions.map(\.updatedAt).max() ?? 0 }
}

private struct SessionWindowGroup: Identifiable {
    let id: String
    let name: String
    let projects: [SessionProjectGroup]
    var latestAt: Int64 { projects.map(\.latestAt).max() ?? 0 }
    var sessionCount: Int { projects.reduce(0) { $0 + $1.sessions.count } }
}

struct SessionDetailView: View {
    @EnvironmentObject private var store: CompanionStore
    let sessionId: String

    var body: some View {
        if let session = store.session(for: sessionId) {
            switch session.kind {
            case .agent:
                AgentSessionView(sessionId: sessionId)
            case .terminal:
                TerminalSessionView(sessionId: sessionId)
            case .panel:
                ContentUnavailableView("Panel preview", systemImage: "rectangle.3.group")
            }
        } else {
            ContentUnavailableView("Session unavailable", systemImage: "questionmark.circle")
        }
    }
}
