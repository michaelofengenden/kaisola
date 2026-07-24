import SwiftUI

/// Settings tab for per-workspace MCP servers. Whatever is configured here rides
/// into every ACP chat's `session/new` for that workspace (see
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
                Section("MCP servers") {
                    Text("Open a project to configure its MCP servers. Servers are scoped per workspace and ride into every agent chat you start there.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(6)
        }
    }
}

/// The workspace-scoped editor: the configured list (toggle / delete) plus an
/// add-form whose visible fields follow the chosen transport.
private struct McpServerEditor: View {
    let store: McpConfigStore

    @State private var servers: [McpServerConfig] = []
    @State private var draft = Draft()
    @State private var addError: String?

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
            addSection
        }
        .formStyle(.grouped)
        .padding(6)
        .onAppear { servers = store.servers() }
    }

    // MARK: - Configured servers

    private var configuredSection: some View {
        Section("Configured servers") {
            if servers.isEmpty {
                Text("No MCP servers yet — add one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(servers) { server in
                HStack(spacing: 8) {
                    Toggle("", isOn: enabledBinding(for: server))
                        .labelsHidden()
                        .toggleStyle(.switch)
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
                    Button(role: .destructive) {
                        servers.removeAll { $0.id == server.id }
                        store.save(servers)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
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

    // MARK: - Add form

    private var addSection: some View {
        Section("Add a server") {
            TextField("Name", text: $draft.name, prompt: Text("unique per workspace"))
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
                    .foregroundStyle(.red)
            }
            Button("Add server", action: add)
                .disabled(!canAdd)
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
        }
    }

    private var canAdd: Bool {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !servers.contains(where: { $0.id == name }) else { return false }
        switch draft.kind {
        case .stdio:
            return !draft.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http, .sse:
            return !draft.url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func add() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard canAdd else { return }
        if servers.contains(where: { $0.id == name }) {
            addError = "A server named \"\(name)\" already exists."
            return
        }
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
