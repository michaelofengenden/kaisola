import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Registry editors post one common invalidation without changing the
    /// stores' ownership or making them observable singletons.
    static let kaisolaExtensionsChanged = Notification.Name("kaisolaExtensionsChanged")
}

/// One searchable, keyboard-navigable destination over the five extension
/// registries. It is deliberately a presentation hub: MCP remains project
/// scoped and every other registry remains app-wide.
struct ExtensionsSettingsHub: View {
    @ObservedObject var settings: NativePreviewSettings
    let workspace: URL?
    let initialRoute: ExtensionsSettingsRoute?
    var routeChanged: ((String) -> Void)?

    @State private var selectedCategory: ExtensionsSettingsCategory?
    @State private var query = ""
    @State private var items: [ExtensionSettingsItem] = []
    @State private var isLoading = true
    @FocusState private var searchFocused: Bool

    init(
        settings: NativePreviewSettings,
        workspace: URL?,
        initialRoute: ExtensionsSettingsRoute?,
        routeChanged: ((String) -> Void)? = nil
    ) {
        self.settings = settings
        self.workspace = workspace
        self.initialRoute = initialRoute
        self.routeChanged = routeChanged
        _selectedCategory = State(initialValue: initialRoute?.category)
    }

    private var fixtureMode: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
            && ["settings-extensions", "settings-extensions-narrow"]
                .contains(environment["KAISOLA_NATIVE_VISUAL_SURFACE"] ?? "")
    }

    private var visibleItems: [ExtensionSettingsItem] {
        let filtered = ExtensionsSettingsCatalog.filtered(items, query: query)
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selectedCategory else { return filtered }
        return filtered.filter { $0.category == selectedCategory }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                searchHeader
                Divider().opacity(0.65)
                if geometry.size.width >= 760 {
                    HStack(spacing: 0) {
                        categoryRail
                        Divider().opacity(0.65)
                        detail
                    }
                } else {
                    compactCategoryPicker
                    Divider().opacity(0.65)
                    detail
                }
            }
        }
        .task(id: workspace) {
            isLoading = true
            await Task.yield()
            refreshCatalog()
            isLoading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaExtensionsChanged)) { _ in
            refreshCatalog()
        }
        .onChange(of: settings.terminalThemeID) { _, _ in refreshCatalog() }
        .onChange(of: selectedCategory) { _, category in
            routeChanged?(ExtensionsSettingsRoute(category: category, itemID: nil).rawValue)
        }
        .onMoveCommand { direction in
            switch direction {
            case .down, .right: moveCategory(.next)
            case .up, .left: moveCategory(.previous)
            default: break
            }
        }
        .accessibilityIdentifier("extensions.hub")
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.kaisolaSecondary)
                .accessibilityHidden(true)
            TextField("Search agents, servers, themes, grammars, and previews", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search extensions")
                .accessibilityIdentifier("extensions.search")
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.kaisolaSecondary)
                .accessibilityLabel("Clear extension search")
            }
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }

    private var categoryRail: some View {
        VStack(alignment: .leading, spacing: 5) {
            categoryButton(nil, title: "All Extensions", symbol: "square.grid.2x2")
            ForEach(ExtensionsSettingsCategory.allCases) { category in
                categoryButton(category, title: category.title, symbol: category.symbol)
            }
            Spacer()
            scopeLegend
        }
        .padding(10)
        .frame(width: 220)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Extension categories")
        .accessibilityIdentifier("extensions.categories")
    }

    private var compactCategoryPicker: some View {
        HStack(spacing: 10) {
            Text("Showing")
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)
            Picker("Extension category", selection: $selectedCategory) {
                Text("All Extensions").tag(nil as ExtensionsSettingsCategory?)
                ForEach(ExtensionsSettingsCategory.allCases) { category in
                    Text(category.title).tag(category as ExtensionsSettingsCategory?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            Spacer()
            Text(scopeSummary)
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .accessibilityIdentifier("extensions.compact-category-picker")
    }

    private func categoryButton(
        _ category: ExtensionsSettingsCategory?,
        title: String,
        symbol: String
    ) -> some View {
        let selected = selectedCategory == category
        let categoryItems = category.map { category in items.filter { $0.category == category } } ?? items
        let issueCount = categoryItems.filter { $0.validationMessage != nil }.count
        return Button {
            selectedCategory = category
            query = ""
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 17)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if issueCount > 0 {
                    Text("\(issueCount)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("\(issueCount) validation issue\(issueCount == 1 ? "" : "s")")
                } else {
                    Text("\(categoryItems.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.kaisolaTertiary)
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : .kaisolaSecondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(categoryItems.count) entries")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("extensions.category.\(category?.rawValue ?? "all")")
    }

    private var scopeLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("App-wide", systemImage: "macwindow")
            Label("Current project", systemImage: "folder")
        }
        .font(.caption2)
        .foregroundStyle(.kaisolaTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scopes: app-wide and current project")
    }

    private var scopeSummary: String {
        switch selectedCategory {
        case .mcpServers: "Current project"
        case nil: "App-wide + project"
        default: "App-wide"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading extensions…").foregroundStyle(.kaisolaSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("extensions.loading")
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            catalogList(title: "Search Results", items: visibleItems)
        } else if let selectedCategory {
            categoryEditor(selectedCategory)
        } else {
            catalogList(title: "All Extensions", items: visibleItems)
        }
    }

    private func catalogList(
        title: String,
        items visible: [ExtensionSettingsItem]
    ) -> some View {
        let state = ExtensionsSettingsCollectionState.resolve(
            isLoading: false,
            allItems: items,
            visibleItems: visible,
            query: query
        )
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.title3.weight(.semibold))
                            Text("Every row uses the same status, source, version and integrity, scope, and update vocabulary.")
                                .font(.caption)
                                .foregroundStyle(.kaisolaSecondary)
                        }
                        Spacer()
                        if case let .content(invalidCount) = state, invalidCount > 0 {
                            Label("\(invalidCount) need attention", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }

                    switch state {
                    case .loading:
                        ProgressView("Loading extensions…")
                    case .empty:
                        ExtensionsEmptyState(
                            title: "No extensions yet",
                            detail: "Choose a category to add an agent, server, theme, grammar, or preview mapping.",
                            symbol: "puzzlepiece.extension"
                        )
                    case let .noResults(term):
                        ExtensionsEmptyState(
                            title: "No results for “\(term)”",
                            detail: "Try a name, category, source, scope, or status.",
                            symbol: "magnifyingglass"
                        )
                    case .content:
                        ForEach(ExtensionsSettingsCategory.allCases) { category in
                            let categoryItems = visible.filter { $0.category == category }
                            if !categoryItems.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(category.title, systemImage: category.symbol)
                                            .font(.headline)
                                        Spacer()
                                        Button("Manage") {
                                            query = ""
                                            selectedCategory = category
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Manage \(category.title)")
                                    }
                                    ForEach(categoryItems, id: \.stableID) { item in
                                        ExtensionRegistryRow(item: item) {
                                            Button("Open") {
                                                query = ""
                                                selectedCategory = category
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .accessibilityLabel("Open \(item.name) in \(category.title)")
                                        }
                                        .id(item.stableID)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .onAppear {
                guard let category = initialRoute?.category,
                      let itemID = initialRoute?.itemID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo("\(category.rawValue):\(itemID)", anchor: .center)
                }
            }
        }
        .accessibilityIdentifier("extensions.catalog")
    }

    @ViewBuilder
    private func categoryEditor(_ category: ExtensionsSettingsCategory) -> some View {
        switch category {
        case .customAgents:
            ScrollViewReader { proxy in
                Form {
                    ExtensionCategoryIntro(category: category, workspace: workspace)
                    CustomAgentsSection(highlightedID: initialRoute?.itemID)
                }
                .formStyle(.grouped)
                .padding(6)
                .onAppear {
                    scrollToDeepLink(initialRoute?.itemID, using: proxy)
                }
            }
        case .mcpServers:
            VStack(spacing: 0) {
                ExtensionCategoryHeader(category: category, workspace: workspace)
                Divider().opacity(0.55)
                McpSettingsTab(workspace: workspace, highlightedID: initialRoute?.itemID)
            }
        case .terminalThemes:
            TerminalThemesExtensionEditor(
                settings: settings,
                highlightedID: initialRoute?.itemID
            )
        case .languageGrammars:
            LanguageGrammarsExtensionEditor(highlightedID: initialRoute?.itemID)
        case .previewMappings:
            PreviewMappingsExtensionEditor(highlightedID: initialRoute?.itemID)
        }
    }

    private func moveCategory(_ direction: ExtensionsSettingsNavigation.Direction) {
        let categories = ExtensionsSettingsCategory.allCases
        guard let selectedCategory else {
            self.selectedCategory = direction == .next ? categories.first : categories.last
            return
        }
        self.selectedCategory = ExtensionsSettingsNavigation.move(
            from: selectedCategory,
            direction: direction,
            in: categories
        )
    }

    private func refreshCatalog() {
        items = fixtureMode
            ? ExtensionsSettingsFixture.items
            : ExtensionsSettingsCatalog.load(
                workspace: workspace,
                selectedThemeID: settings.terminalThemeID
            )
    }

    private func scrollToDeepLink(_ itemID: String?, using proxy: ScrollViewProxy) {
        guard let itemID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(itemID, anchor: .center)
        }
    }
}

private struct ExtensionCategoryIntro: View {
    let category: ExtensionsSettingsCategory
    let workspace: URL?

    var body: some View {
        Section {
            Label(category.accessibilitySummary, systemImage: category.symbol)
                .font(.callout)
            Text(category == .mcpServers
                 ? "Changes apply only to \(workspace?.lastPathComponent ?? "the current project")."
                 : "Changes apply across Kaisola.")
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)
        }
        .accessibilityIdentifier("extensions.category-intro.\(category.rawValue)")
    }
}

private struct ExtensionCategoryHeader: View {
    let category: ExtensionsSettingsCategory
    let workspace: URL?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.symbol)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title).font(.headline)
                Text(category == .mcpServers
                     ? "Project scope · \(workspace?.lastPathComponent ?? "open a project")"
                     : "App-wide scope")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .accessibilityElement(children: .combine)
    }
}

struct ExtensionRegistryRow<Trailing: View>: View {
    let item: ExtensionSettingsItem
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.category.symbol)
                    .foregroundStyle(item.status.isEnabled ? Color.accentColor : .kaisolaSecondary)
                    .frame(width: 19)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.callout.weight(.medium))
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.kaisolaSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                ExtensionStatusBadge(status: item.status)
                trailing
            }
            ExtensionMetadataGrid(item: item)
            if let validation = item.validationMessage {
                Label(validation, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Validation error: \(validation)")
                    .accessibilityIdentifier("extensions.validation.\(item.stableID)")
            }
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.62),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilityDescription)
        .accessibilityIdentifier("extensions.item.\(item.stableID)")
    }
}

struct ExtensionMetadataGrid: View {
    let item: ExtensionSettingsItem

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 105), alignment: .leading),
                GridItem(.flexible(minimum: 105), alignment: .leading),
            ],
            alignment: .leading,
            spacing: 7
        ) {
            cell("Source", item.source.label)
            cell("Scope", item.scope.label)
            cell("Version & integrity", item.versionIntegrity)
            cell("Updates", item.updateState.label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Source: \(item.source.label). Scope: \(item.scope.label). "
                + "Version and integrity: \(item.versionIntegrity). Updates: \(item.updateState.label)."
        )
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.kaisolaSecondary)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.kaisolaSecondary)
                .lineLimit(2)
        }
    }
}

private struct ExtensionStatusBadge: View {
    let status: ExtensionSettingsStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.isEnabled ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status.label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.55), in: Capsule())
        .accessibilityLabel(status.label)
    }
}

private struct ExtensionsEmptyState: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.kaisolaSecondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.kaisolaSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("extensions.empty-state")
    }
}

// MARK: - Terminal themes

private struct TerminalThemesExtensionEditor: View {
    @ObservedObject var settings: NativePreviewSettings
    let highlightedID: String?
    @State private var specs: [CustomThemeSpec] = []
    private let store = CustomThemeStore()

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ExtensionCategoryIntro(category: .terminalThemes, workspace: nil)
                Section("Built-in Themes") {
                    ForEach(TerminalThemeRegistry.shipped) { definition in
                        let item = ExtensionSettingsItem.builtInTheme(
                            id: definition.id,
                            title: definition.title,
                            selected: settings.terminalThemeID == definition.id
                        )
                        ExtensionRegistryRow(item: item) {
                            Button(settings.terminalThemeID == definition.id ? "Active" : "Use") {
                                settings.terminalThemeID = definition.id
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(settings.terminalThemeID == definition.id)
                        }
                        .id(definition.id)
                    }
                }
                Section("Custom Themes") {
                    if specs.isEmpty {
                        Text("No custom themes yet. Import a JSON palette to add one.")
                            .font(.callout)
                            .foregroundStyle(.kaisolaSecondary)
                            .accessibilityIdentifier("extensions.themes.empty")
                    }
                    ForEach(specs) { spec in
                        let item = ExtensionSettingsItem.customTheme(
                            spec,
                            selected: settings.terminalThemeID == spec.id
                        )
                        ExtensionRegistryRow(item: item) {
                            HStack(spacing: 7) {
                                if spec.validationError == nil {
                                    Button(settings.terminalThemeID == spec.id ? "Active" : "Use") {
                                        settings.terminalThemeID = spec.id
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(settings.terminalThemeID == spec.id)
                                }
                                Button(role: .destructive) { remove(spec) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove theme \(item.name)")
                            }
                        }
                        .id(spec.id)
                        .overlay {
                            if highlightedID == spec.id {
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(Color.accentColor, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    Button {
                        importTheme()
                    } label: {
                        Label("Import Theme…", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityHint("Choose a JSON file with light and dark palettes")
                }
            }
            .formStyle(.grouped)
            .padding(6)
            .onAppear {
                specs = store.specs()
                scrollToHighlight(using: proxy)
            }
        }
    }

    private func scrollToHighlight(using proxy: ScrollViewProxy) {
        guard let highlightedID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(highlightedID, anchor: .center)
        }
    }

    private func remove(_ spec: CustomThemeSpec) {
        _ = store.remove(id: spec.id)
        specs = store.specs()
        NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import Theme"
        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else { return }
            Task { @MainActor in
                guard let data = try? Data(contentsOf: url),
                      let spec = try? JSONDecoder().decode(CustomThemeSpec.self, from: data) else {
                    ToastCenter.shared.show(
                        "That file is not a theme: it needs an id, title, and light and dark palettes.",
                        style: .error,
                        duration: 5
                    )
                    return
                }
                if let reason = store.upsert(spec) {
                    ToastCenter.shared.show(
                        "Imported as disabled: \(reason)",
                        style: .info,
                        duration: 6
                    )
                } else {
                    settings.terminalThemeID = spec.id
                    ToastCenter.shared.show("Imported \(spec.title) and made it active", style: .success)
                }
                specs = store.specs()
                NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
            }
        }
    }
}

// MARK: - Language grammars

private struct LanguageGrammarsExtensionEditor: View {
    let highlightedID: String?
    @State private var specs: [CustomGrammarSpec] = []
    @State private var name = ""
    @State private var extensionsText = ""
    @State private var fencesText = ""
    @State private var pattern = ""
    @State private var role = "keyword"
    private let store = CustomGrammarStore()

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ExtensionCategoryIntro(category: .languageGrammars, workspace: nil)
                Section("Installed Grammars") {
                    if specs.isEmpty {
                        Text("No custom grammars. Built-in languages keep working as usual.")
                            .font(.callout)
                            .foregroundStyle(.kaisolaSecondary)
                            .accessibilityIdentifier("extensions.grammars.empty")
                    }
                    ForEach(specs) { spec in
                        ExtensionRegistryRow(item: .languageGrammar(spec)) {
                            Button(role: .destructive) { remove(spec) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove grammar \(spec.title)")
                        }
                        .id(spec.id)
                        .overlay {
                            if highlightedID == spec.id {
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(Color.accentColor, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                Section("Add a Grammar") {
                    TextField("Name", text: $name, prompt: Text("Task language"))
                        .accessibilityLabel("Grammar name")
                    TextField("File extensions", text: $extensionsText, prompt: Text("task, tasks"))
                        .accessibilityLabel("Grammar file extensions")
                    TextField("Fence tokens (optional)", text: $fencesText, prompt: Text("task"))
                        .accessibilityLabel("Grammar fence tokens")
                    TextField("Regular expression", text: $pattern, prompt: Text("\\b(TODO|DONE)\\b"))
                        .font(.body.monospaced())
                        .accessibilityLabel("Grammar regular expression")
                    Picker("Color role", selection: $role) {
                        ForEach(["comment", "string", "keyword", "number", "tag"], id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }
                    Button("Add Grammar") { add() }
                        .disabled(!canAdd)
                    Text("A grammar is data only. Invalid expressions stay listed but disabled with the exact reason.")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                }
            }
            .formStyle(.grouped)
            .padding(6)
            .onAppear {
                specs = store.specs()
                scrollToHighlight(using: proxy)
            }
        }
    }

    private func scrollToHighlight(using proxy: ScrollViewProxy) {
        guard let highlightedID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(highlightedID, anchor: .center)
        }
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !extensionsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pattern.isEmpty
    }

    private func add() {
        let id = ExtensionsSettingsDraftPolicy.identifier(name, existing: Set(specs.map(\.id)))
        let fences = ExtensionsSettingsDraftPolicy.extensions(fencesText)
        let spec = CustomGrammarSpec(
            id: id,
            title: name.trimmingCharacters(in: .whitespacesAndNewlines),
            extensions: ExtensionsSettingsDraftPolicy.extensions(extensionsText),
            fences: fences.isEmpty ? nil : fences,
            rules: [.init(
                pattern: pattern,
                role: role,
                context: nil,
                priority: nil,
                caseInsensitive: nil,
                anchorsMatchLines: nil
            )]
        )
        if let reason = store.upsert(spec) {
            ToastCenter.shared.show("Added as disabled: \(reason)", style: .info, duration: 6)
        } else {
            ToastCenter.shared.show("Added \(spec.title)", style: .success)
        }
        specs = store.specs()
        name = ""
        extensionsText = ""
        fencesText = ""
        pattern = ""
        NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
    }

    private func remove(_ spec: CustomGrammarSpec) {
        _ = store.remove(id: spec.id)
        specs = store.specs()
        NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
    }
}

// MARK: - Preview mappings

private struct PreviewMappingsExtensionEditor: View {
    let highlightedID: String?
    @State private var snapshot = PreviewMappingStore.Snapshot(specs: [], state: .missing)
    @State private var name = ""
    @State private var extensionsText = ""
    @State private var kind = PreviewMappingSpec.Kind.text
    @State private var operationError: String?
    @State private var confirmReset = false
    private let store = PreviewMappingStore()

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ExtensionCategoryIntro(category: .previewMappings, workspace: nil)
                if !snapshot.state.allowsMutations {
                    Section("Registry Recovery") {
                        let item = ExtensionSettingsItem.previewMappingRegistryIssue(snapshot.state)
                        Label(item.versionIntegrity, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("extensions.previews.registry-warning")
                        if let message = item.validationMessage {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let recoveryURL = snapshot.state.preservedCopyURL {
                            Text(recoveryURL.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .accessibilityLabel("Preview mapping recovery copy \(recoveryURL.lastPathComponent)")
                            HStack {
                                Button("Reveal Recovery Copy") {
                                    NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
                                }
                                Button("Reset Registry", role: .destructive) {
                                    confirmReset = true
                                }
                                .disabled(!snapshot.state.canReset)
                                .accessibilityHint("Replaces the active unreadable registry with an empty version. The recovery copy is kept.")
                            }
                        } else {
                            Button("Reload Registry") { reload() }
                                .accessibilityHint("Tries to read and preserve the preview-mapping registry again.")
                        }
                    }
                }
                if let operationError {
                    Section("Save Error") {
                        Label(operationError, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("extensions.previews.save-error")
                    }
                }
                Section("Installed Mappings") {
                    if specs.isEmpty {
                        Text(snapshot.state.allowsMutations
                            ? "No custom preview mappings. Built-in file classifications still run first."
                            : "Preview mappings are unavailable until the registry issue is resolved.")
                            .font(.callout)
                            .foregroundStyle(.kaisolaSecondary)
                            .accessibilityIdentifier("extensions.previews.empty")
                    }
                    ForEach(specs) { spec in
                        ExtensionRegistryRow(item: .previewMapping(spec)) {
                            Button(role: .destructive) { remove(spec) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!snapshot.state.allowsMutations)
                            .accessibilityLabel("Remove preview mapping \(spec.id)")
                        }
                        .id(spec.id)
                        .overlay {
                            if highlightedID == spec.id {
                                RoundedRectangle(cornerRadius: 11)
                                    .stroke(Color.accentColor, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                Section("Add a Preview Mapping") {
                    TextField("Name", text: $name, prompt: Text("Notes files"))
                        .accessibilityLabel("Preview mapping name")
                    TextField("File extensions", text: $extensionsText, prompt: Text("notes, memo"))
                        .accessibilityLabel("Preview mapping file extensions")
                    Picker("Preview as", selection: $kind) {
                        ForEach(PreviewMappingSpec.Kind.allCases, id: \.rawValue) { kind in
                            Text(kind.rawValue.capitalized).tag(kind)
                        }
                    }
                    Button("Add Mapping") { add() }
                        .disabled(!canAdd)
                    Text("Mappings can select text previews only. Images, PDFs, documents, binary sniffing, and size limits cannot be overridden.")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                }
            }
            .formStyle(.grouped)
            .padding(6)
            .onAppear {
                reload()
                scrollToHighlight(using: proxy)
            }
            .confirmationDialog(
                "Reset preview mappings?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset Registry", role: .destructive) { reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Kaisola will replace the active unreadable registry with an empty version. The recovery copy will remain on disk.")
            }
        }
    }

    private var specs: [PreviewMappingSpec] { snapshot.specs }

    private func scrollToHighlight(using proxy: ScrollViewProxy) {
        guard let highlightedID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(highlightedID, anchor: .center)
        }
    }

    private var canAdd: Bool {
        snapshot.state.allowsMutations
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !extensionsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func add() {
        let id = ExtensionsSettingsDraftPolicy.identifier(name, existing: Set(specs.map(\.id)))
        let spec = PreviewMappingSpec(
            id: id,
            extensions: ExtensionsSettingsDraftPolicy.extensions(extensionsText),
            kind: kind.rawValue
        )
        do {
            let reason = try store.upsert(spec)
            reload()
            name = ""
            extensionsText = ""
            if let reason {
                ToastCenter.shared.show("Added as disabled: \(reason)", style: .info, duration: 6)
            } else {
                ToastCenter.shared.show("Added \(id)", style: .success)
            }
            NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
        } catch {
            report(error)
        }
    }

    private func remove(_ spec: PreviewMappingSpec) {
        do {
            _ = try store.remove(id: spec.id)
            reload()
            NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
        } catch {
            report(error)
        }
    }

    private func reset() {
        do {
            snapshot = try store.resetUnreadableRegistry()
            operationError = nil
            ToastCenter.shared.show("Reset preview mappings; recovery copy kept", style: .success, duration: 6)
            NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
        } catch {
            report(error)
        }
    }

    private func reload() {
        snapshot = store.load()
        operationError = nil
    }

    private func report(_ error: Error) {
        snapshot = store.load()
        operationError = error.localizedDescription
        ToastCenter.shared.show(error.localizedDescription, style: .error, duration: 6)
    }
}
