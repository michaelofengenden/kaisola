import SwiftUI

/// A single runnable entry in the command palette.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let run: () -> Void
}

/// A ⌘K fuzzy command palette: app actions (new terminal/agent/chat, open
/// folder), view toggles (layout/appearance), and jump-to targets (projects,
/// sessions, chats). Filters with `FuzzyMatch`, arrow-key navigable, Enter runs,
/// Escape dismisses.
struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: NativePreviewSettings
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Run a command or jump to…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit(runSelection)
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selection)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = index; runSelection() }
                        }
                        if filtered.isEmpty {
                            Text("No matching commands")
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: selection) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(radius: 24, y: 8)
        .onAppear { searchFocused = true }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .onKeyPress(.return) { runSelection(); return .handled }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 18)
                .foregroundStyle(selected ? Color.white : .secondary)
            Text(item.title)
                .foregroundStyle(selected ? Color.white : .primary)
            Spacer()
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(selected ? Color.accentColor : Color.clear)
    }

    private var filtered: [PaletteItem] {
        let items = allItems()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = FuzzyMatch.score(query: trimmed, candidate: item.title) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    private func runSelection() {
        let items = filtered
        guard selection >= 0, selection < items.count else { return }
        let item = items[selection]
        isPresented = false
        // Defer so the sheet is fully dismissed before an action opens a panel.
        DispatchQueue.main.async { item.run() }
    }

    private func allItems() -> [PaletteItem] {
        var items: [PaletteItem] = []

        items.append(PaletteItem(id: "action.newTerminal", title: "New Terminal Session", subtitle: "Action · ⌘T", systemImage: "terminal") {
            RootShellView.promptForNewTerminal(model: model)
        })
        for agent in AgentRegistry.all {
            items.append(PaletteItem(id: "action.newAgent.\(agent.id)", title: "New \(agent.name) Session", subtitle: "New Agent", systemImage: "sparkles") {
                RootShellView.promptForNewAgent(agent, model: model)
            })
        }
        for agent in AgentRegistry.all where AcpAdapter.forAgent(agent.id) != nil {
            items.append(PaletteItem(id: "action.newChat.\(agent.id)", title: "Chat with \(agent.name)", subtitle: "New Chat", systemImage: "bubble.left.and.bubble.right") {
                RootShellView.promptForNewChat(agent, model: model)
            })
        }
        items.append(PaletteItem(id: "action.openFolder", title: "Open Folder…", subtitle: "Action · ⌘O", systemImage: "folder") {
            RootShellView.promptForOpenFolder(model: model)
        })

        for layout in NavigationLayout.allCases {
            items.append(PaletteItem(id: "layout.\(layout.rawValue)", title: "Layout: \(layout.title)", subtitle: "View", systemImage: "sidebar.squares.left") {
                settings.navigationLayout = layout
            })
        }
        for mode in AppearanceMode.allCases {
            items.append(PaletteItem(id: "appearance.\(mode.rawValue)", title: "Appearance: \(mode.title)", subtitle: "View", systemImage: "circle.lefthalf.filled") {
                settings.appearance = mode
            })
        }

        for project in model.projects {
            items.append(PaletteItem(id: "project.\(project.id)", title: project.name, subtitle: "Project", systemImage: "folder.fill") {
                model.selectedProjectName = project.name
            })
        }
        for session in model.sessions {
            items.append(PaletteItem(id: "session.\(session.id)", title: session.title, subtitle: "Session", systemImage: "terminal.fill") {
                model.selectedChatID = nil
                Task { await model.select(session.id) }
            })
        }
        for chat in model.chats {
            items.append(PaletteItem(id: "chat.\(chat.id)", title: chat.conversation.title, subtitle: "Chat", systemImage: "bubble.left.fill") {
                model.selectChat(chat.id)
            })
        }
        return items
    }
}
