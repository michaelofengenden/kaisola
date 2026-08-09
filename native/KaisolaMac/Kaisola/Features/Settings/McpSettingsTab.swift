import Foundation
import SwiftUI

/// Settings tab for per-project MCP servers. Whatever is configured here rides
/// into every ACP chat's `session/new` for that project (see
/// `McpConfigStore.jsonValues`). MCP servers are workspace-scoped, so a nil
/// workspace (no active project) has nowhere to store them — the tab shows a hint
/// instead of an editor.
struct McpSettingsTab: View {
    let workspace: URL?
    var highlightedID: String? = nil

    var body: some View {
        if let workspace {
            // `.id(workspace)` rebuilds the editor — and re-runs its `onAppear`
            // load — whenever the active project changes underneath the window.
            McpServerEditor(
                store: McpConfigStore(workspace: workspace),
                projectName: workspace.lastPathComponent,
                highlightedID: highlightedID
            )
                .id(workspace)
        } else {
            Form {
                Section("MCP Servers") {
                    Text("Open a project to configure its MCP servers. Servers are scoped to that project and are available to every agent chat you start there.")
                        .font(.callout)
                        .foregroundStyle(.kaisolaSecondary)
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

    /// One line of a `NAME=value` block that could not be read, addressed the
    /// way the user sees it: the 1-based line number plus what is wrong. Blank
    /// lines still count toward the number, so the report points at the line
    /// the editor shows.
    struct PairLineProblem: Equatable {
        let line: Int
        let reason: String
    }

    /// Everything a `NAME=value` block produced: the pairs that parsed and
    /// every line that did not. Both halves come back together so the caller
    /// can block on `problems` without re-walking the text.
    struct PairParse: Equatable {
        var pairs: [McpServerConfig.Pair]
        var problems: [PairLineProblem]
    }

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
        remainingCapacity: Int,
        pairText: String = ""
    ) -> Bool {
        hasRequiredFields
            && remainingCapacity > 0
            && !normalizedName(rawName).isEmpty
            && duplicateName(rawName, servers: servers) == nil
            && parsePairs(pairText).problems.isEmpty
    }

    /// Reads a `NAME=value` block strictly: one pair per non-blank line, split
    /// on the first `=`. A line that cannot become a pair is reported rather
    /// than dropped, because a silently discarded header or environment
    /// variable only shows up much later as a server that fails to start. An
    /// empty value (`NAME=`) is a real setting and stays legal. Per-line bounds
    /// mirror `McpServerConfig.safePair`, so the line-level message arrives
    /// before the whole-server validation error would.
    static func parsePairs(_ text: String) -> PairParse {
        var parse = PairParse(pairs: [], problems: [])
        // Normalize first so CRLF and lone CR do not shift the numbering the
        // user is being pointed at.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for (index, rawLine) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let separator = line.firstIndex(of: "=") else {
                parse.problems.append(.init(line: number, reason: "no \"=\" separator. Write NAME=value."))
                continue
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                parse.problems.append(.init(line: number, reason: "the name before \"=\" is empty."))
                continue
            }
            guard name.rangeOfCharacter(from: .controlCharacters) == nil, !value.contains("\0") else {
                parse.problems.append(.init(line: number, reason: "control characters are not allowed."))
                continue
            }
            guard name.utf8.count <= 128 else {
                parse.problems.append(.init(line: number, reason: "the name is longer than 128 bytes."))
                continue
            }
            guard value.utf8.count <= 4_096 else {
                parse.problems.append(.init(line: number, reason: "the value is longer than 4096 bytes."))
                continue
            }
            parse.pairs.append(McpServerConfig.Pair(name: name, value: value))
        }
        return parse
    }

    /// The exact gate the Add button binds to. Living here rather than in the
    /// view means a malformed line can never be the difference between what the
    /// screen allows and what the tests check.
    static func canAdd(
        hasRequiredFields: Bool,
        serverCount: Int,
        duplicateName: String?,
        pairText: String
    ) -> Bool {
        hasRequiredFields
            && remainingCapacity(serverCount: serverCount) > 0
            && duplicateName == nil
            && parsePairs(pairText).problems.isEmpty
    }

    /// A single message naming every malformed line, used for the inline report
    /// under the editor and for the error `add()` sets if it is ever reached
    /// with a bad draft.
    static func malformedPairMessage(field: String, problems: [PairLineProblem]) -> String? {
        guard !problems.isEmpty else { return nil }
        let detail = problems.map { "Line \($0.line): \($0.reason)" }.joined(separator: "\n")
        return "\(field) could not be read, so nothing was saved:\n\(detail)"
    }
}

/// The workspace-scoped editor: the configured list (toggle / delete) plus an
/// add-form whose visible fields follow the chosen transport.
private struct McpServerEditor: View {
    let store: McpConfigStore
    let projectName: String
    let highlightedID: String?

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
        ScrollViewReader { proxy in
            Form {
                configuredSection
                discoverySection
                addSection
            }
            .formStyle(.grouped)
            .padding(6)
            .onAppear {
                loadInitialState()
                guard let highlightedID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(highlightedID, anchor: .center)
                }
            }
            .task(id: recentlyDeleted?.id) {
                guard recentlyDeleted != nil else { return }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                recentlyDeleted = nil
            }
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
                    .foregroundStyle(.kaisolaSecondary)
                    .accessibilityIdentifier("extensions.mcp.empty")
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
                                .foregroundStyle(.kaisolaSecondary)
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
                                Text(identity).foregroundStyle(.kaisolaTertiary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(
                            result.status == .failed
                                ? KaisolaStatusTone.failed.foregroundColor
                                : Color.kaisolaSecondary
                        )
                        .accessibilityElement(children: .combine)

                        let authentication = result.authentication.presentation
                        HStack(spacing: 5) {
                            Circle()
                                .fill(authenticationColor(result.authentication))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(authentication.copy)
                            Spacer(minLength: 4)
                            if authentication.action == .retryProbe,
                               let title = authentication.action.title {
                                Button(title) { probe(server) }
                                    .buttonStyle(.borderless)
                                    .disabled(probingNames.contains(server.name))
                            } else if let title = authentication.action.title {
                                Text(title).foregroundStyle(.kaisolaTertiary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(authenticationColor(result.authentication))
                        .accessibilityElement(children: .combine)
                    }
                    ExtensionMetadataGrid(
                        item: .mcpServer(server, projectName: projectName)
                    )
                }
                .padding(.vertical, 4)
                .id(server.id)
                .overlay {
                    if highlightedID == server.id {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("extensions.mcp.\(server.id)")
            }
            if let deleted = recentlyDeleted {
                HStack(spacing: 8) {
                    Label("\(deleted.server.name) removed", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
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
        notifyCatalogChanged()
    }

    private func restore(_ deleted: DeletedServer) {
        guard servers.count < McpConfigStore.maximumServerCount,
              !servers.contains(where: { $0.id == deleted.server.id }) else {
            recentlyDeleted = nil
            return
        }
        servers.insert(deleted.server, at: min(deleted.index, servers.count))
        store.save(servers)
        notifyCatalogChanged()
        recentlyDeleted = nil
    }

    private func probe(_ server: McpServerConfig) {
        guard probingNames.insert(server.name).inserted else { return }
        probeResults[server.name] = .probing
        Task {
            let result = await McpProbeService.shared.probe(server)
            probeResults[server.name] = result
            probingNames.remove(server.name)
        }
    }

    private func authenticationColor(_ state: McpAuthenticationState) -> Color {
        switch state {
        case .signedIn: .green
        case .signedOut, .expired: .red
        case .probing: .secondary
        case .unknown: .orange
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
                notifyCatalogChanged()
            }
        )
    }

    // MARK: - Discovery and disabled import

    private var discoverySection: some View {
        Section("Import Existing Configuration") {
            Text("Find MCP servers already configured in Cursor, Claude, Codex, Gemini, VS Code, or Windsurf. Kaisola reads only their standard local config files, never expands secrets, and imports selected servers disabled.")
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)

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
                                .foregroundStyle(.kaisolaSecondary)
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
                    .foregroundStyle(.kaisolaSecondary)
            }
            if remainingCapacity == 0 {
                Text("MCP server limit reached (\(McpConfigStore.maximumServerCount)). Remove a server before importing another.")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
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
            notifyCatalogChanged()
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

            if !pairProblems.isEmpty {
                // Every malformed line, listed as the user types, so a header or
                // environment variable can never be dropped behind a successful
                // Add.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pairProblems, id: \.line) { problem in
                        Text("\(pairFieldLabel) line \(problem.line): \(problem.reason)")
                    }
                }
                .font(.caption)
                .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                .accessibilityElement(children: .combine)
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
                    .foregroundStyle(.kaisolaSecondary)
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
                .foregroundStyle(.kaisolaSecondary)
            TextEditor(text: text)
                .onChange(of: text.wrappedValue) { _, _ in addError = nil }
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

    /// The `NAME=value` editor the chosen transport actually shows — stdio
    /// carries environment variables, http/sse carry headers — and the label the
    /// per-line report names it by.
    private var pairFieldLabel: String {
        draft.kind == .stdio ? "Environment" : "Headers"
    }

    private var pairDraftText: String {
        draft.kind == .stdio ? draft.envText : draft.headerText
    }

    private var pairProblems: [McpSettingsPolicy.PairLineProblem] {
        McpSettingsPolicy.parsePairs(pairDraftText).problems
    }

    private var canAddServer: Bool {
        McpSettingsPolicy.canAddServer(
            rawName: draft.name,
            servers: servers,
            hasRequiredFields: hasRequiredFields,
            remainingCapacity: remainingCapacity,
            pairText: pairDraftText
        )
    }

    private func add() {
        let name = McpSettingsPolicy.normalizedName(draft.name)
        guard remainingCapacity > 0 else {
            addError = "MCP server limit reached (\(McpConfigStore.maximumServerCount))."
            return
        }
        guard hasRequiredFields else { return }
        guard canAddServer else {
            let parse = McpSettingsPolicy.parsePairs(pairDraftText)
            if let message = McpSettingsPolicy.malformedPairMessage(
                field: pairFieldLabel, problems: parse.problems
            ) {
                addError = message
            }
            return
        }
        // The button is already disabled while a line is malformed; this keeps
        // the draft (and its unparsed text) on screen if `add` is ever reached
        // another way.
        let parse = McpSettingsPolicy.parsePairs(pairDraftText)
        if let message = McpSettingsPolicy.malformedPairMessage(
            field: pairFieldLabel, problems: parse.problems
        ) {
            addError = message
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
                envPairs: parse.pairs
            )
        case .http, .sse:
            server = McpServerConfig(
                name: name,
                kind: draft.kind,
                url: draft.url.trimmingCharacters(in: .whitespaces),
                headerPairs: parse.pairs
            )
        }
        if let error = server.validationError {
            addError = error
            return
        }
        servers.append(server)
        store.save(servers)
        notifyCatalogChanged()
        draft = Draft()
        addError = nil
    }

    // MARK: - Line parsing

    /// One entry per non-blank line, trimmed. Used for stdio arguments, where a
    /// line carries no structure to get wrong. `NAME=value` blocks go through
    /// `McpSettingsPolicy.parsePairs`, which reports rather than drops.
    static func parseLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    private func notifyCatalogChanged() {
        NotificationCenter.default.post(name: .kaisolaExtensionsChanged, object: nil)
    }
}
