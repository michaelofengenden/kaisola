import SwiftUI

/// A single runnable entry in the command palette.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let shortcutHint: String?
    let systemImage: String
    let isEnabled: Bool
    let disabledReason: String?
    let run: () -> Void

    init(
        id: String,
        title: String,
        subtitle: String,
        shortcutHint: String? = nil,
        systemImage: String,
        isEnabled: Bool = true,
        disabledReason: String? = nil,
        run: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.run = run
    }
}

enum CommandPaletteResultIdentity {
    static func itemID(at selection: Int, in items: [PaletteItem]) -> String? {
        guard items.indices.contains(selection) else { return nil }
        return items[selection].id
    }
}

/// A ⌘K fuzzy command palette: app actions (new terminal/agent/chat, open
/// folder), view toggles (layout/appearance), and jump-to targets (projects,
/// sessions, chats). Filters with `FuzzyMatch`, arrow-key navigable, Enter runs,
/// Escape dismisses.
struct CommandPaletteView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: NativePreviewSettings
    @ObservedObject private var keymap = AppCommandKeymapCenter.shared
    @Binding var isPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var selection = 0
    @State private var projectFiles: [String] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.kaisolaSecondary)
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
                            Button {
                                selection = index
                                run(item)
                            } label: {
                                row(item, selected: index == selection)
                                    .contentShape(Rectangle())
                                    // Keep the explanation readable while the
                                    // outer Button remains semantically disabled.
                                    .environment(\.isEnabled, true)
                            }
                            .buttonStyle(.plain)
                            .disabled(!item.isEnabled)
                            .accessibilityLabel(item.title)
                            .accessibilityValue(item.subtitle)
                            .accessibilityHint(item.disabledReason ?? shortcutAccessibilityHint(item))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(index == selection ? .isSelected : [])
                            .id(item.id)
                        }
                        if filtered.isEmpty {
                            Text("No matching commands")
                                .foregroundStyle(.kaisolaSecondary)
                                .padding(16)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .onChange(of: selection) { _, new in
                    guard let itemID = CommandPaletteResultIdentity.itemID(
                        at: new,
                        in: filtered
                    ) else { return }
                    if reduceMotion {
                        proxy.scrollTo(itemID, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: KaisolaVisualSystem.hoverDuration)) {
                            proxy.scrollTo(itemID, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
        .shadow(radius: 24, y: 8)
        .onAppear { searchFocused = true }
        .task(id: model.currentProjectDirectory?.standardizedFileURL.path) {
            guard let root = model.currentProjectDirectory else {
                projectFiles = []
                return
            }
            projectFiles = await ProjectFileIndex.shared.files(for: root)
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .onKeyPress(.return) { runSelection(); return .handled }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        return HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 18)
                .foregroundStyle(selected ? selectedText : .kaisolaSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .foregroundStyle(selected ? selectedText : .primary)
                Text(item.disabledReason ?? item.subtitle)
                    .font(.caption)
                    .foregroundStyle(selected ? selectedText.opacity(0.78) : .kaisolaSecondary)
                    .lineLimit(2)
            }
            Spacer()
            if let shortcutHint = item.shortcutHint {
                Text(shortcutHint)
                    .font(.caption.monospaced())
                    .foregroundStyle(selected ? selectedText.opacity(0.8) : .kaisolaSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        .opacity(item.isEnabled ? 1 : 0.72)
    }

    private var filtered: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allItems() }
        // With a query, project files join the candidates (⌘P-style).
        let ranked = (allItems() + fileItems())
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = FuzzyMatch.score(query: trimmed, candidate: item.title) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        return Array(ranked.prefix(40))
    }

    /// Fuzzy file candidates from the active project (bounded, TTL-cached).
    private func fileItems() -> [PaletteItem] {
        guard let root = model.currentProjectDirectory else { return [] }
        return projectFiles.map { relative in
            PaletteItem(id: "file.\(relative)", title: relative, subtitle: "File", systemImage: "doc.text") {
                model.openFilePreview(root.appendingPathComponent(relative))
            }
        }
    }

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    private func runSelection() {
        let items = filtered
        guard selection >= 0, selection < items.count else { return }
        guard items[selection].isEnabled else {
            if let reason = items[selection].disabledReason {
                ToastCenter.shared.show(reason, style: .info)
            }
            return
        }
        run(items[selection])
    }

    private func run(_ item: PaletteItem) {
        guard item.isEnabled else { return }
        isPresented = false
        // Defer so the sheet is fully dismissed before an action opens a panel.
        DispatchQueue.main.async { item.run() }
    }

    private func allItems() -> [PaletteItem] {
        var items = registeredCommandItems()

        // Quick Actions for the active project run straight from the palette.
        if let active = model.projects.first(where: { $0.id == (model.selectedProjectID ?? model.projects.first?.id) }),
           let activeDir = active.directory {
            for action in QuickActionStore().actions(forProject: active.id) {
                items.append(PaletteItem(
                    id: "quickAction.\(active.id).\(action.id)",
                    title: "Run: \(action.title.isEmpty ? action.command : action.title)",
                    subtitle: "Quick Action · \(active.name)",
                    systemImage: "play.fill"
                ) {
                    Task { await model.runQuickAction(action, inProject: activeDir) }
                })
            }
        }

        for project in model.projects {
            items.append(PaletteItem(id: "project.\(project.id)", title: project.name, subtitle: "Project", systemImage: "folder.fill") {
                model.activateProject(id: project.id)
            })
        }
        for session in model.sessions {
            items.append(PaletteItem(id: "session.\(session.id)", title: model.sessionTitle(for: session), subtitle: "Session", systemImage: "terminal.fill") {
                model.selectedChatID = nil
                Task { await model.select(session.id) }
            })
        }
        for chat in model.chats {
            items.append(PaletteItem(id: "chat.\(chat.id)", title: chat.conversation.title, subtitle: "Chat", systemImage: "bubble.left.fill") {
                model.selectChat(chat.id)
            })
        }
        for mesh in model.meshes {
            let projectName = model.projects.first(where: { $0.id == mesh.projectID })?.name
            items.append(PaletteItem(
                id: "mesh.\(mesh.id)",
                title: mesh.title,
                subtitle: projectName.map { "Mesh · \($0)" } ?? "Mesh",
                systemImage: "circle.hexagongrid.fill"
            ) {
                model.selectMesh(mesh.id)
            })
        }
        return items
    }

    private func registeredCommandItems() -> [PaletteItem] {
        let context = AppCommandContext(model: model, settings: settings)
        return AppCommandRegistry.paletteDefinitions.map { definition in
            let availability = AppCommandRegistry.availability(of: definition.id, in: context)
            return PaletteItem(
                id: "command.\(definition.id.rawValue)",
                title: AppCommandRegistry.presentationTitle(for: definition.id, in: context),
                subtitle: definition.category.rawValue,
                shortcutHint: keymap.shortcut(for: definition.id)?.display,
                systemImage: definition.systemImage,
                isEnabled: availability.isEnabled,
                disabledReason: availability.reason
            ) {
                _ = AppCommandRegistry.execute(definition.id, in: context)
            }
        }
    }

    private func shortcutAccessibilityHint(_ item: PaletteItem) -> String {
        guard let shortcutHint = item.shortcutHint else { return "" }
        return "Keyboard shortcut \(shortcutHint)"
    }
}
