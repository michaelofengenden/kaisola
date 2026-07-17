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
            let matchesKind = switch filter {
            case .all: true
            case .agents: session.kind == .agent
            case .terminals: session.kind == .terminal
            }
            let matchesQuery = query.isEmpty
                || session.title.localizedCaseInsensitiveContains(query)
                || (session.summary?.localizedCaseInsensitiveContains(query) ?? false)
            return matchesKind && matchesQuery
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ConsoleHeader(
                        eyebrow: "Activity",
                        title: "All sessions",
                        detail: "\(store.sessions.count) captured across \(store.projects.count) workspaces",
                        symbol: "waveform.path.ecg"
                    )

                    searchField
                    filterBar

                    if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(minHeight: 320)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(filtered) { session in
                                NavigationLink {
                                    SessionDetailView(sessionId: session.id)
                                } label: {
                                    SessionCard(session: session, project: store.project(for: session.projectId))
                                }
                                .buttonStyle(QuietPressStyle())
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
