import Foundation
import SwiftUI

/// Settings tab for per-project MCP servers. Whatever is configured here rides
/// into every ACP chat's `session/new` for that project (see
/// `McpConfigStore.jsonValues`). MCP servers are workspace-scoped, so a nil
/// workspace (no active project) has nowhere to store them — the tab shows a hint
/// instead of an editor.
struct McpSettingsTab: View {
    let workspace: URL?

    var body: some View {
        if let workspace {
            // `.id(workspace)` rebuilds the editor — and re-runs its `onAppear`
            // load — whenever the active project changes underneath the window.
            McpServerEditor(store: McpConfigStore(workspace: workspace))
                .id(workspace)
        } else {
            Form {
                Section("MCP Servers") {
                    Text("Open a project to configure its MCP servers. Servers are scoped to that project and are available to every agent chat you start there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(6)
        }
    }
}

/// Pure add-form policy shared by the view and focused tests. Keeping the
/// catalog cap here prevents UI state from ever getting ahead of what the
/// bounded store can persist.
enum McpSettingsPolicy {
    private static let nameComparisonLocale = Locale(identifier: "en_US_POSIX")

    static func remainingCapacity(serverCount: Int) -> Int {
        max(0, McpConfigStore.maximumServerCount - max(0, serverCount))
    }

    static func normalizedName(_ rawName: String) -> String {
        rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func duplicateName(_ rawName: String, servers: [McpServerConfig]) -> String? {
        let name = normalizedName(rawName)
        let comparisonKey = name.folding(options: [.caseInsensitive], locale: nameComparisonLocale)
        guard !name.isEmpty,
              servers.contains(where: {
                  normalizedName($0.name)
                      .folding(options: [.caseInsensitive], locale: nameComparisonLocale) == comparisonKey
              }) else { return nil }
        return name
    }

    static func duplicateMessage(_ name: String) -> String {
        "A server named \"\(name)\" already exists in this project."
    }

    static func canAddServer(
        rawName: String,
        servers: [McpServerConfig],
        hasRequiredFields: Bool,
        remainingCapacity: Int
    ) -> Bool {
        hasRequiredFields
            && remainingCapacity > 0
            && !normalizedName(rawName).isEmpty
            && duplicateName(rawName, servers: servers) == nil
    }
}

/// The workspace-scoped editor: the configured list (toggle / delete) plus an
/// add-form whose visible fields follow the chosen transport.
private struct McpServerEditor: View {
    let store: McpConfigStore

    @State private var servers: [McpServerConfig] = []
    @State private var draft = Draft()
    @State private var addError: String?
    @State private var probeResults: [String: McpProbeResult] = [:]
    @State private var probingNames = Set<String>()
    @State private var discoveries: [McpDiscoveredServer] = []
    @State private var selectedDiscoveryIDs = Set<String>()
    @State private var isDiscovering = false
    @State private var isImporting = false
    @State private var discoveryMessage: String?
    @State private var recentlyDeleted: DeletedServer?

    private struct DeletedServer: Identifiable {
        let id = UUID()
        let server: McpServerConfig
        let index: Int
    }

    /// The in-progress new-server form.
    private struct Draft {
        var name = ""
        var kind: McpServerConfig.Kind = .stdio
        var command = ""
        var argsText = ""
        var url = ""
        var envText = ""
        var headerText = ""
    }

    var body: some View {
        Form {
            configuredSection
            discoverySection
            addSection
        }
        .formStyle(.grouped)
        .padding(6)
        .onAppear { loadInitialState() }
        .task(id: recentlyDeleted?.id) {
            guard recentlyDeleted != nil else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            recentlyDeleted = nil
        }
    }

    private func loadInitialState() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "settings-mcp" else {
            servers = store.servers()
            return
        }
        servers = [
            McpServerConfig(name: "project-files", kind: .stdio, command: "filesystem-mcp", args: ["--workspace"]),
            McpServerConfig(name: "design-library", kind: .http, url: "https://mcp.example.test/v1"),
        ]
        probeResults = [
            "project-files": .init(
                status: .configured,
                verified: false,
                message: "Configured · verified when a new agent session starts"
            ),
            "design-library": .init(
                status: .ready,
                verified: true,
                message: "Ready · 12 tools",
                serverName: "Design MCP",
                serverVersion: "2.1",
                toolCount: 12
            ),
        ]
        discoveries = [
            McpDiscoveredServer(
                origin: "Codex CLI",
                config: McpServerConfig(name: "docs", kind: .http, url: "https://docs.example.test/mcp", enabled: false)
            ),
        ]
        selectedDiscoveryIDs = Set(discoveries.map(\.id))
        discoveryMessage = "Found 1. Review the selection before importing."
    }

    // MARK: - Configured servers

    private var configuredSection: some View {
        Section("Configured Servers") {
            if servers.isEmpty {
                Text("No MCP servers yet — add one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(servers) { server in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: enabledBinding(for: server))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Enable MCP server \(server.name)")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name).font(.callout)
                            Text(subtitle(for: server))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(server.kind.rawValue.uppercased())
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Button {
                            probe(server)
                        } label: {
                            if probingNames.contains(server.name) {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "stethoscope")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(probingNames.contains(server.name))
                        .help("Check MCP server")
                        .accessibilityLabel("Check MCP server \(server.name)")
                        Button(role: .destructive) {
                            delete(server)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete MCP server \(server.name)")
                    }
                    if let result = probeResults[server.name] {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(probeColor(result.status))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(result.message)
                            if let identity = probeIdentity(result) {
                                Text(identity).foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(
                            result.status == .failed
                                ? KaisolaStatusTone.failed.foregroundColor
                                : Color.secondary
                        )
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let deleted = recentlyDeleted {
                HStack(spacing: 8) {
                    Label("\(deleted.server.name) removed", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { restore(deleted) }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func delete(_ server: McpServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        recentlyDeleted = DeletedServer(server: servers.remove(at: index), index: index)
        probeResults[server.name] = nil
        store.save(servers)
    }

    private func restore(_ deleted: DeletedServer) {
        guard servers.count < McpConfigStore.maximumServerCount,
              !servers.contains(where: { $0.id == deleted.server.id }) else {
            recentlyDeleted = nil
            return
        }
        servers.insert(deleted.server, at: min(deleted.index, servers.count))
        store.save(servers)
        recentlyDeleted = nil
    }

    private func probe(_ server: McpServerConfig) {
        guard probingNames.insert(server.name).inserted else { return }
        Task {
            let result = await McpProbeService.shared.probe(server)
            probeResults[server.name] = result
            probingNames.remove(server.name)
        }
    }

    private func probeColor(_ status: McpProbeResult.Status) -> Color {
        switch status {
        case .configured: .orange
        case .ready: .green
        case .failed: .red
        }
    }

    private func probeIdentity(_ result: McpProbeResult) -> String? {
        let values = [result.serverName, result.serverVersion].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " ")
    }

    private func subtitle(for server: McpServerConfig) -> String {
        switch server.kind {
        case .stdio:
            return ([server.command ?? ""] + server.args)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .http, .sse:
            return server.url ?? ""
        }
    }

    private func enabledBinding(for server: McpServerConfig) -> Binding<Bool> {
        Binding(
            get: { servers.first { $0.id == server.id }?.enabled ?? false },
            set: { newValue in
                guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
                servers[index].enabled = newValue
                store.save(servers)
            }
        )
    }

    // MARK: - Discovery and disabled import

    private var discoverySection: some View {
        Section("Import Existing Configuration") {
            Text("Find MCP servers already configured in Cursor, Claude, Codex, Gemini, VS Code, or Windsurf. Kaisola reads only their standard local config files, never expands secrets, and imports selected servers disabled.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if discoveries.isEmpty {
                Button {
                    discover()
                } label: {
                    if isDiscovering {
                        Label("Searching…", systemImage: "magnifyingglass")
                    } else {
                        Label("Find Configured Servers", systemImage: "magnifyingglass")
                    }
                }
                .disabled(isDiscovering)
            } else {
                ForEach(discoveries) { discovery in
                    Toggle(isOn: discoveryBinding(discovery.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(discovery.config.name)
                            Text("\(discovery.origin) · \(subtitle(for: discovery.config))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .accessibilityLabel("Import \(discovery.config.name) from \(discovery.origin)")
                }
                HStack {
                    Button("Import as Disabled") { importSelected() }
                        .disabled(selectedDiscoveryIDs.isEmpty || isImporting || remainingCapacity == 0)
                    Button("Search Again") { discover() }
                        .disabled(isDiscovering || isImporting)
                    if isImporting { ProgressView().controlSize(.small) }
                }
            }
            if let discoveryMessage {
                Text(discoveryMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if remainingCapacity == 0 {
                Text("MCP server limit reached (\(McpConfigStore.maximumServerCount)). Remove a server before importing another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func discoveryBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedDiscoveryIDs.contains(id) },
            set: { selected in
                if selected { selectedDiscoveryIDs.insert(id) }
                else { selectedDiscoveryIDs.remove(id) }
            }
        )
    }

    private func discover() {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryMessage = nil
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                McpConfigDiscovery.scan()
            }.value
            let existing = Set(servers.map(\.name))
            discoveries = found.filter { !existing.contains($0.config.name) }
            selectedDiscoveryIDs = Set(discoveries.map(\.id))
            discoveryMessage = discoveries.isEmpty
                ? "No new safe server configurations were found."
                : "Found \(discoveries.count). Review the selection before importing."
            isDiscovering = false
        }
    }

    private func importSelected() {
        guard !isImporting else { return }
        let selected = discoveries.filter { selectedDiscoveryIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isImporting = true
        Task {
            let imported = await Task.detached(priority: .userInitiated) {
                store.importDiscovered(selected)
            }.value
            servers = store.servers()
            let savedNames = Set(servers.map(\.name))
            discoveries.removeAll { savedNames.contains($0.config.name) }
            selectedDiscoveryIDs = Set(discoveries.map(\.id))
            if imported < selected.count {
                discoveryMessage = "Imported \(imported) of \(selected.count) selected servers as disabled; the \(McpConfigStore.maximumServerCount)-server limit was reached."
            } else {
                discoveryMessage = "Imported \(imported) server\(imported == 1 ? "" : "s") as disabled. Enable one only after reviewing its command or URL."
            }
            isImporting = false
        }
    }

    // MARK: - Add form

    private var addSection: some View {
        Section("Add a Server") {
            TextField("Name", text: $draft.name, prompt: Text("unique per project"))
                .onChange(of: draft.name) { _, _ in addError = nil }
                .accessibilityHint(
                    duplicateNameMessage ?? "Server names must be unique in this project."
                )
            Picker("Transport", selection: $draft.kind) {
                Text("stdio").tag(McpServerConfig.Kind.stdio)
                Text("http").tag(McpServerConfig.Kind.http)
                Text("sse").tag(McpServerConfig.Kind.sse)
            }
            .pickerStyle(.segmented)

            if draft.kind == .stdio {
                TextField("Command", text: $draft.command, prompt: Text("e.g. npx"))
                lineEditor("Arguments — one per line", text: $draft.argsText)
                lineEditor("Environment — NAME=value per line", text: $draft.envText)
            } else {
                TextField("URL", text: $draft.url, prompt: Text("https://example.com/mcp"))
                lineEditor("Headers — NAME=value per line", text: $draft.headerText)
            }

            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
            }
            if let duplicateNameMessage {
                Text(duplicateNameMessage)
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
            }
            if remainingCapacity == 0 {
                Text("MCP server limit reached (\(McpConfigStore.maximumServerCount)). Remove a server before adding another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Add Server", action: add)
                .disabled(!canAddServer)
                .accessibilityHint(
                    duplicateNameMessage ?? "Adds this server to the current project."
                )
        }
    }

    private func lineEditor(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.callout.monospaced())
                .frame(minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .accessibilityLabel(label)
        }
    }

    private var hasRequiredFields: Bool {
        guard !McpSettingsPolicy.normalizedName(draft.name).isEmpty else { return false }
        switch draft.kind {
        case .stdio:
            return !draft.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http, .sse:
            return !draft.url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var remainingCapacity: Int {
        McpSettingsPolicy.remainingCapacity(serverCount: servers.count)
    }

    private var duplicateName: String? {
        McpSettingsPolicy.duplicateName(draft.name, servers: servers)
    }

    private var duplicateNameMessage: String? {
        duplicateName.map { McpSettingsPolicy.duplicateMessage($0) }
    }

    private var canAddServer: Bool {
        McpSettingsPolicy.canAddServer(
            rawName: draft.name,
            servers: servers,
            hasRequiredFields: hasRequiredFields,
            remainingCapacity: remainingCapacity
        )
    }

    private func add() {
        let name = McpSettingsPolicy.normalizedName(draft.name)
        guard remainingCapacity > 0 else {
            addError = "MCP server limit reached (\(McpConfigStore.maximumServerCount))."
            return
        }
        guard hasRequiredFields else { return }
        guard canAddServer else { return }
        let server: McpServerConfig
        switch draft.kind {
        case .stdio:
            server = McpServerConfig(
                name: name,
                kind: .stdio,
                command: draft.command.trimmingCharacters(in: .whitespaces),
                args: Self.parseLines(draft.argsText),
                envPairs: Self.parsePairs(draft.envText)
            )
        case .http, .sse:
            server = McpServerConfig(
                name: name,
                kind: draft.kind,
                url: draft.url.trimmingCharacters(in: .whitespaces),
                headerPairs: Self.parsePairs(draft.headerText)
            )
        }
        if let error = server.validationError {
            addError = error
            return
        }
        servers.append(server)
        store.save(servers)
        draft = Draft()
        addError = nil
    }

    // MARK: - Lenient parsing

    /// One entry per non-blank line, trimmed. Used for stdio arguments.
    static func parseLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// One `{name,value}` per line, split on the first `=`. Blank lines, lines
    /// with no `=`, and lines with an empty name are skipped; an empty value is
    /// allowed.
    static func parsePairs(_ text: String) -> [McpServerConfig.Pair] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine -> McpServerConfig.Pair? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let separator = line.firstIndex(of: "=") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return McpServerConfig.Pair(name: name, value: value)
        }
    }
}
