import SwiftUI

struct SessionsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case agents = "Agents"
        case terminals = "Terminals"

        var id: Self { self }
    }

    @EnvironmentObject private var store: CompanionStore
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

    var body: some View {
        ZStack {
            AmbientBackdrop()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header

                    searchField
                    filterBar

                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(minHeight: 320)
                    } else {
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
            Text("\(activityCount) across \(store.projects.count) projects")
                .font(.caption)
                .foregroundStyle(.secondary)
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
