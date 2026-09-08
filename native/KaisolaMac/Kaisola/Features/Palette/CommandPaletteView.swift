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

enum CommandPaletteRanking {
    static func ranked(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let normalizedQuery = query.lowercased()
        return items.enumerated()
            .compactMap { index, item -> (item: PaletteItem, tier: Int, score: Int, index: Int)? in
                guard let score = FuzzyMatch.score(query: query, candidate: item.title) else { return nil }
                return (item, tier(for: item, query: normalizedQuery), score, index)
            }
            .sorted {
                if $0.tier != $1.tier { return $0.tier < $1.tier }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.index < $1.index
            }
            .map(\.item)
    }

    private static func tier(for item: PaletteItem, query: String) -> Int {
        let title = item.title.lowercased()
        let isFile = item.id.hasPrefix("file.")
        let filename = title.split(separator: "/").last.map(String.init) ?? title
        // A named file or explicit trailing path is a precise destination,
        // even if a command happens to mention that same filename.
        if title == query || (isFile && (filename == query
            || (query.contains("/") && title.hasSuffix("/" + query)))) {
            return 0
        }
        if !isFile {
            let words = title.split { !$0.isLetter && !$0.isNumber }
            if title.hasPrefix(query) || words.contains(where: { $0.hasPrefix(query) }) {
                return 1
            }
        } else {
            if query.contains("/"), title.hasPrefix(query) { return 1 }
            if filename.hasPrefix(query) { return 2 }
        }
        if title.contains(query) { return 3 }
        // Word-boundary bonuses still order loose matches, but cannot lift a
        // scattered match in a long path over a clearly named command.
        return 4
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var selection = 0
    @State private var projectFiles: [String] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        // One result snapshot per render keeps row drawing, empty state and
        // keyboard navigation consistent without re-ranking the file index.
        let items = filtered
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.kaisolaSecondary)
                TextField("Search commands, projects, and files", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
                    .onSubmit(runSelection)
                    .onChange(of: query) { _, _ in selection = 0 }
                    .accessibilityLabel("Search commands, projects, and files")
                    .accessibilityIdentifier("palette.search")
                Text("esc")
                    .font(.system(size: 11))
                    .foregroundStyle(.kaisolaSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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
                        if items.isEmpty {
                            VStack(spacing: 7) {
                                Text("No results for “\(query)”")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.kaisolaPrimary)
                                Text("Try a project name, file, or action.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.kaisolaSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 390)
                .onChange(of: selection) { _, new in
                    guard let itemID = CommandPaletteResultIdentity.itemID(
                        at: new,
                        in: items
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
            Divider()
            HStack(spacing: 16) {
                Label("Navigate", systemImage: "arrow.up.arrow.down")
                Label("Open", systemImage: "return")
                Spacer()
                Text("Commands & files")
            }
            .font(.system(size: 11))
            .foregroundStyle(.kaisolaSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: 600)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
            if !reduceTransparency {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.13), radius: 28, y: 12)
        .onAppear {
            // The overlay must enter the window before it can take focus from
            // the mounted chat or terminal underneath it.
            DispatchQueue.main.async { searchFocused = true }
        }
        .task(id: model.currentProjectDirectory?.standardizedFileURL.path) {
            guard let root = model.currentProjectDirectory else {
                projectFiles = []
                return
            }
            projectFiles = await ProjectFileIndex.shared.files(for: root)
        }
        .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
        .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
        .onKeyPress(.escape) { isPresented = false; return .handled }
        .onKeyPress(.return) { runSelection(); return .handled }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        let selectedText = QuietSelectionPill.ink
        let isFile = item.id.hasPrefix("file.")
        let parentFolder = (item.title as NSString).deletingLastPathComponent
        let detail = isFile ? (parentFolder.isEmpty ? "Project root" : parentFolder) : item.subtitle
        return HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .frame(width: 18)
                .foregroundStyle(selected ? selectedText : .kaisolaSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if isFile {
                        Text((item.title as NSString).lastPathComponent)
                            .help(item.title)
                    } else {
                        Text(item.title)
                    }
                }
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? selectedText : .primary)
                Text(item.disabledReason ?? detail)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? selectedText.opacity(0.78) : .kaisolaSecondary)
                    .lineLimit(2)
            }
            Spacer()
            if let shortcutHint = item.shortcutHint {
                Text(shortcutHint)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(selected ? selectedText.opacity(0.8) : .kaisolaSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.11) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .opacity(item.isEnabled ? 1 : 0.72)
    }

    private var filtered: [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allItems() }
        // With a query, project files join the candidates (⌘P-style).
        let ranked = CommandPaletteRanking.ranked(allItems() + fileItems(), query: trimmed)
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

    private func move(_ delta: Int, count: Int) {
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
