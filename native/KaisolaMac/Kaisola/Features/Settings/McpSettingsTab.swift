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
                workspace: workspace,
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
    private static var nameComparisonLocale: Locale { Locale(identifier: "en_US_POSIX") }

    static let changeScopeTitle = "New chats only"
    static let storedSecretMarker = "<stored in Keychain>"

    static func changeScopeDetail(openChatCount: Int) -> String {
        let count = max(0, openChatCount)
        guard count > 0 else {
            return "Enable, disable, add, edit, delete, and import changes apply when you start a new chat."
        }
        let subject = count == 1 ? "1 open chat keeps" : "\(count) open chats keep"
        return "\(subject) their current MCP tools. Start a new chat to use enable, disable, add, edit, delete, or import changes."
    }

    static func offersNewChatAction(openChatCount: Int, canStartNewChat: Bool) -> Bool {
        openChatCount > 0 && canStartNewChat
    }

    static let mutationAccessibilityHint =
        "This MCP configuration change applies to new chats only. Existing chats keep their current tools."

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

    /// Prefill an edit without ever materializing a Keychain-backed or legacy
    /// plaintext credential into the Settings text editor. Keeping the marker
    /// on its original pair means Save can preserve the exact opaque reference;
    /// deleting the line still removes that pair from the configuration.
    static func pairEditorText(_ pairs: [McpServerConfig.Pair]) -> String {
        pairs.map { pair in
            let value = pair.secretReference != nil || McpOAuthSecretPolicy.requiresKeychain(pair)
                ? storedSecretMarker
                : pair.value
            return "\(pair.name)=\(value)"
        }
        .joined(separator: "\n")
    }
}

/// Lossless, value-blind edit state for one configured server. The immutable
/// name is the row identity; enabled state comes from the current row at Save
/// time so an in-place edit cannot silently rename, reorder, or toggle it.
struct McpServerEditDraft: Equatable {
    enum ValidationError: Error, Equatable, LocalizedError {
        case malformedPairs(field: String, problems: [McpSettingsPolicy.PairLineProblem])
        case storedSecretMarkerDoesNotMatch(line: Int)
        case invalidServer(String)

        var errorDescription: String? {
            switch self {
            case let .malformedPairs(field, problems):
                return McpSettingsPolicy.malformedPairMessage(field: field, problems: problems)
            case let .storedSecretMarkerDoesNotMatch(line):
                return "Line \(line) no longer matches a stored credential. Enter a replacement value or remove the line."
            case let .invalidServer(message):
                return message
            }
        }
    }

    let name: String
    var kind: McpServerConfig.Kind
    var command: String
    var argsText: String
    var url: String
    var envText: String
    var headerText: String

    init(server: McpServerConfig) {
        name = server.name
        kind = server.kind
        command = server.command ?? ""
        argsText = server.args.joined(separator: "\n")
        url = server.url ?? ""
        envText = McpSettingsPolicy.pairEditorText(server.envPairs)
        headerText = McpSettingsPolicy.pairEditorText(server.headerPairs)
    }

    func server(
        preservingIdentityAndEnabledFrom original: McpServerConfig
    ) throws -> McpServerConfig {
        let candidate: McpServerConfig
        switch kind {
        case .stdio:
            candidate = McpServerConfig(
                name: original.name,
                kind: .stdio,
                command: command.trimmingCharacters(in: .whitespaces),
                args: Self.parseLines(argsText),
                envPairs: try Self.resolvedPairs(
                    envText,
                    field: "Environment",
                    preserving: original.envPairs
                ),
                enabled: original.enabled
            )
        case .http, .sse:
            candidate = McpServerConfig(
                name: original.name,
                kind: kind,
                url: url.trimmingCharacters(in: .whitespaces),
                headerPairs: try Self.resolvedPairs(
                    headerText,
                    field: "Headers",
                    preserving: original.headerPairs
                ),
                enabled: original.enabled
            )
        }
        if let validationError = candidate.validationError {
            throw ValidationError.invalidServer(validationError)
        }
        return candidate
    }

    private static func parseLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func resolvedPairs(
        _ text: String,
        field: String,
        preserving original: [McpServerConfig.Pair]
    ) throws -> [McpServerConfig.Pair] {
        let parse = McpSettingsPolicy.parsePairs(text)
        guard parse.problems.isEmpty else {
            throw ValidationError.malformedPairs(field: field, problems: parse.problems)
        }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [McpServerConfig.Pair] = []
        var usedOriginalIndices = Set<Int>()
        for (index, rawLine) in normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard var pair = McpSettingsPolicy.parsePairs(line).pairs.first else {
                throw ValidationError.malformedPairs(
                    field: field,
                    problems: [.init(line: index + 1, reason: "the line could not be read.")]
                )
            }
            if pair.value == McpSettingsPolicy.storedSecretMarker {
                guard let preservedIndex = original.indices.first(where: {
                    !usedOriginalIndices.contains($0)
                        && original[$0].name == pair.name
                        && (original[$0].secretReference != nil
                            || McpOAuthSecretPolicy.requiresKeychain(original[$0]))
                }) else {
                    throw ValidationError.storedSecretMarkerDoesNotMatch(line: index + 1)
                }
                usedOriginalIndices.insert(preservedIndex)
                pair = original[preservedIndex]
            }
            result.append(pair)
        }
        return result
    }
}

/// The workspace-scoped editor: the configured list (toggle / delete) plus an
/// add-form whose visible fields follow the chosen transport.
private struct McpServerEditor: View {
    let store: McpConfigStore
    let workspace: URL
    let projectName: String
    let highlightedID: String?

    @Environment(\.dismiss) private var dismiss

    @State private var servers: [McpServerConfig] = []
    @State private var draft = Draft()
    @State private var addError: String?
    @State private var editDraft: McpServerEditDraft?
    @State private var editError: String?
    @State private var probeResults: [String: McpProbeResult] = [:]
    @State private var probingNames = Set<String>()
    @State private var discoveries: [McpDiscoveredServer] = []
    @State private var selectedDiscoveryIDs = Set<String>()
    @State private var isDiscovering = false
    @State private var isImporting = false
    @State private var discoveryMessage: String?
    @State private var recentlyDeleted: DeletedServer?
    @State private var pendingPlaintextSecretCount = 0
    @State private var secretMigrationMessage: String?
    @State private var isMigratingSecrets = false
    @State private var showsSecretMigrationConfirmation = false
    @State private var showsImportSecretConfirmation = false

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
                changeScopeSection
                secretMigrationSection
                configuredSection
                discoverySection.disabled(editDraft != nil)
                addSection.disabled(editDraft != nil)
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

    private var chatAgents: [AgentProfile] {
        AgentRegistry.all.filter { AcpAdapter.forAgent($0.id) != nil }
    }

    private var openChatCount: Int {
        KaisolaMacAppDelegate.sharedMcpOpenChatCount(in: workspace)
    }

    private var changeScopeSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(McpSettingsPolicy.changeScopeTitle)
                        .font(.callout.weight(.semibold))
                    Text(McpSettingsPolicy.changeScopeDetail(openChatCount: openChatCount))
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                }
                Spacer(minLength: 8)
                if McpSettingsPolicy.offersNewChatAction(
                    openChatCount: openChatCount,
                    canStartNewChat: !chatAgents.isEmpty
                ) {
                    Menu {
                        ForEach(chatAgents) { agent in
                            Button("Chat with \(agent.name)") {
                                startNewChat(agentID: agent.id)
                            }
                        }
                    } label: {
                        Label("Start New Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .fixedSize()
                    .accessibilityHint("Leaves existing chats open and starts a new chat with this MCP configuration.")
                    .accessibilityIdentifier("extensions.mcp.start-new-chat")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("extensions.mcp.new-chat-scope")
        }
    }

    private func startNewChat(agentID: String) {
        // A Settings sheet must get out of the command's way before the
        // existing account chooser is presented. In the standalone Settings
        // window this is a no-op; the delegate brings the owning workspace
        // forward before routing through the same New Chat command.
        dismiss()
        Task { @MainActor in
            await Task.yield()
            _ = KaisolaMacAppDelegate.sharedStartMcpChat(
                agentID: agentID,
                in: workspace
            )
        }
    }

    private func scopeSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(McpSettingsPolicy.changeScopeTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .textCase(nil)
        }
    }

    private func loadInitialState() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
              environment["KAISOLA_NATIVE_VISUAL_SURFACE"] == "settings-mcp" else {
            servers = store.servers()
            pendingPlaintextSecretCount = store.pendingPlaintextOAuthSecretCount()
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

    @ViewBuilder
    private var secretMigrationSection: some View {
        if pendingPlaintextSecretCount > 0 || secretMigrationMessage != nil {
            Section("Credential Storage") {
                if pendingPlaintextSecretCount > 0 {
                    Label(
                        "\(pendingPlaintextSecretCount) saved OAuth credential\(pendingPlaintextSecretCount == 1 ? "" : "s") still \(pendingPlaintextSecretCount == 1 ? "is" : "are") in this project's MCP configuration.",
                        systemImage: "key.fill"
                    )
                    .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                    Text("Move them to this Mac's app-scoped, this-device-only Keychain. The configuration is rewritten only after every Keychain write succeeds; exports and new chats omit plaintext while migration is pending.")
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                    Button("Move Credentials to Keychain…") {
                        showsSecretMigrationConfirmation = true
                    }
                    .disabled(isMigratingSecrets)
                    .confirmationDialog(
                        "Move MCP credentials to Keychain?",
                        isPresented: $showsSecretMigrationConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Move to Keychain") { migratePlaintextSecrets() }
                        Button("Not Now", role: .cancel) {}
                    } message: {
                        Text("Kaisola will replace the saved plaintext with opaque references only after the Keychain accepts every credential.")
                    }
                }
                if isMigratingSecrets {
                    ProgressView("Moving credentials…")
                }
                if let secretMigrationMessage {
                    Text(secretMigrationMessage)
                        .font(.caption)
                        .foregroundStyle(
                            pendingPlaintextSecretCount == 0
                                ? Color.kaisolaSecondary
                                : KaisolaStatusTone.failed.foregroundColor
                        )
                }
            }
        }
    }

    private func migratePlaintextSecrets() {
        guard !isMigratingSecrets else { return }
        isMigratingSecrets = true
        secretMigrationMessage = nil
        Task {
            do {
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try store.migratePlaintextOAuthSecrets(consent: true)
                }.value
                servers = receipt.servers
                pendingPlaintextSecretCount = 0
                secretMigrationMessage = "Moved \(receipt.migratedCount) credential\(receipt.migratedCount == 1 ? "" : "s") to Keychain. The MCP configuration now contains only opaque references."
                notifyCatalogChanged()
            } catch {
                pendingPlaintextSecretCount = store.pendingPlaintextOAuthSecretCount()
                secretMigrationMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isMigratingSecrets = false
        }
    }

    private var configuredSection: some View {
        Section {
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
                            .disabled(editDraft != nil)
                            .accessibilityLabel("Enable MCP server \(server.name)")
                            .accessibilityHint(McpSettingsPolicy.mutationAccessibilityHint)
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
                            beginEditing(server)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .disabled(editDraft != nil)
                        .help("Edit MCP server")
                        .accessibilityLabel("Edit MCP server \(server.name)")
                        .accessibilityHint(McpSettingsPolicy.mutationAccessibilityHint)
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
                        .disabled(editDraft != nil || probingNames.contains(server.name))
                        .help("Check MCP server")
                        .accessibilityLabel("Check MCP server \(server.name)")
                        Button(role: .destructive) {
                            delete(server)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(editDraft != nil)
                        .accessibilityLabel("Delete MCP server \(server.name)")
                        .accessibilityHint(McpSettingsPolicy.mutationAccessibilityHint)
                    }
                    if editDraft?.name == server.name {
                        editForm(for: server)
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
        } header: {
            scopeSectionHeader("Configured Servers")
        }
    }

    @ViewBuilder
    private func editForm(for original: McpServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Editing \(original.name)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(McpSettingsPolicy.changeScopeTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Picker("Transport", selection: editBinding(\.kind, default: original.kind)) {
                Text("stdio").tag(McpServerConfig.Kind.stdio)
                Text("http").tag(McpServerConfig.Kind.http)
                Text("sse").tag(McpServerConfig.Kind.sse)
            }
            .pickerStyle(.segmented)

            if editDraft?.kind == .stdio {
                TextField("Command", text: editBinding(\.command, default: ""))
                editLineEditor(
                    "Arguments — one per line",
                    text: editBinding(\.argsText, default: "")
                )
                editLineEditor(
                    "Environment — NAME=value per line",
                    text: editBinding(\.envText, default: "")
                )
            } else {
                TextField("URL", text: editBinding(\.url, default: ""))
                editLineEditor(
                    "Headers — NAME=value per line",
                    text: editBinding(\.headerText, default: "")
                )
            }

            Text("Stored credentials stay hidden behind \(McpSettingsPolicy.storedSecretMarker). Entering a replacement value moves only this server's changed credential to Keychain when you save.")
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)

            if let validationMessage = editValidationMessage(for: original) {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                    .accessibilityIdentifier("extensions.mcp.edit.validation.\(original.id)")
            }
            if let editError {
                Text(editError)
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                    .accessibilityIdentifier("extensions.mcp.edit.error.\(original.id)")
            }

            HStack {
                Button("Cancel") { cancelEditing() }
                    .accessibilityLabel("Cancel editing MCP server \(original.name)")
                Button("Save Changes") { saveEditing(original) }
                    .buttonStyle(.borderedProminent)
                    .disabled(editValidationMessage(for: original) != nil)
                    .accessibilityLabel("Save changes to MCP server \(original.name)")
                    .accessibilityHint(McpSettingsPolicy.mutationAccessibilityHint)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extensions.mcp.edit.\(original.id)")
    }

    private func editLineEditor(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)
            TextEditor(text: text)
                .font(.callout.monospaced())
                .frame(minHeight: 52)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .accessibilityLabel(label)
        }
    }

    private func editBinding<Value>(
        _ keyPath: WritableKeyPath<McpServerEditDraft, Value>,
        default fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { editDraft?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var updated = editDraft else { return }
                updated[keyPath: keyPath] = value
                editDraft = updated
                editError = nil
            }
        )
    }

    private func editValidationMessage(for original: McpServerConfig) -> String? {
        guard let draft = editDraft, draft.name == original.name else { return nil }
        let current = servers.first(where: { $0.id == original.id }) ?? original
        do {
            _ = try draft.server(preservingIdentityAndEnabledFrom: current)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func beginEditing(_ server: McpServerConfig) {
        editDraft = McpServerEditDraft(server: server)
        editError = nil
        recentlyDeleted = nil
    }

    private func cancelEditing() {
        editDraft = nil
        editError = nil
    }

    private func saveEditing(_ original: McpServerConfig) {
        guard let draft = editDraft, draft.name == original.name,
              let current = servers.first(where: { $0.id == original.id }) else {
            editError = McpConfigMutationError.serverNotFound(original.name).localizedDescription
            return
        }
        do {
            let replacement = try draft.server(preservingIdentityAndEnabledFrom: current)
            let receipt = try store.replaceSecuringOAuthServer(
                replacement,
                identifiedBy: current.id,
                in: servers,
                consent: true
            )
            servers = receipt.servers
            pendingPlaintextSecretCount = store.pendingPlaintextOAuthSecretCount()
            probeResults[current.name] = nil
            editDraft = nil
            editError = nil
            notifyCatalogChanged()
        } catch {
            editError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        guard let materialized = store.materializedServer(server) else {
            probeResults[server.name] = .init(
                status: .failed,
                verified: true,
                message: "MCP credential unavailable in Keychain",
                authentication: .unknown(.keychainDenied)
            )
            probingNames.remove(server.name)
            return
        }
        probeResults[server.name] = .probing
        Task {
            let result = await McpProbeService.shared.probe(materialized)
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
        Section {
            Text("Find MCP servers already configured in Cursor, Claude, Codex, Gemini, VS Code, or Windsurf. Kaisola reads only their standard local config files, never expands placeholders, and imports selected servers disabled. Literal credentials move directly to Keychain only after confirmation.")
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
                            if discovery.plaintextSecretCount > 0 {
                                Text("\(discovery.plaintextSecretCount) credential\(discovery.plaintextSecretCount == 1 ? "" : "s") will move to Keychain")
                                    .font(.caption2)
                                    .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                            }
                        }
                    }
                    .accessibilityLabel("Import \(discovery.config.name) from \(discovery.origin)")
                }
                HStack {
                    Button("Import as Disabled") {
                        if selectedDiscoverySecretCount > 0 {
                            showsImportSecretConfirmation = true
                        } else {
                            importSelected(consentToMigrateSecrets: false)
                        }
                    }
                        .disabled(selectedDiscoveryIDs.isEmpty || isImporting || remainingCapacity == 0)
                        .accessibilityHint(McpSettingsPolicy.mutationAccessibilityHint)
                        .confirmationDialog(
                            "Move imported MCP credentials to Keychain?",
                            isPresented: $showsImportSecretConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Import and Move to Keychain") {
                                importSelected(consentToMigrateSecrets: true)
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Kaisola will import the selected servers disabled and replace \(selectedDiscoverySecretCount) plaintext credential\(selectedDiscoverySecretCount == 1 ? "" : "s") with opaque Keychain references. The source configuration is not changed.")
                        }
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
        } header: {
            scopeSectionHeader("Import Existing Configuration")
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

    private var selectedDiscoverySecretCount: Int {
        discoveries
            .filter { selectedDiscoveryIDs.contains($0.id) }
            .reduce(0) { $0 + $1.plaintextSecretCount }
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

    private func importSelected(consentToMigrateSecrets: Bool) {
        guard !isImporting else { return }
        let selected = discoveries.filter { selectedDiscoveryIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        isImporting = true
        Task {
            do {
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try store.importDiscovered(
                        selected,
                        consentToMigrateSecrets: consentToMigrateSecrets
                    )
                }.value
                servers = receipt.servers
                notifyCatalogChanged()
                let savedNames = Set(servers.map(\.name))
                discoveries.removeAll { savedNames.contains($0.config.name) }
                selectedDiscoveryIDs = Set(discoveries.map(\.id))
                if receipt.importedCount < selected.count {
                    discoveryMessage = "Imported \(receipt.importedCount) of \(selected.count) selected servers as disabled; the \(McpConfigStore.maximumServerCount)-server limit was reached."
                } else if receipt.migratedSecretCount > 0 {
                    discoveryMessage = "Imported \(receipt.importedCount) server\(receipt.importedCount == 1 ? "" : "s") as disabled and moved \(receipt.migratedSecretCount) credential\(receipt.migratedSecretCount == 1 ? "" : "s") to Keychain."
                } else {
                    discoveryMessage = "Imported \(receipt.importedCount) server\(receipt.importedCount == 1 ? "" : "s") as disabled. Enable one only after reviewing its command or URL."
                }
            } catch {
                discoveryMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isImporting = false
        }
    }

    // MARK: - Add form

    private var addSection: some View {
        Section {
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

            Text("Authorization, client-secret, access-token, and refresh-token values are written directly to this Mac's Keychain. Only opaque references are saved in MCP configuration or export data.")
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)

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
                    duplicateNameMessage ?? McpSettingsPolicy.mutationAccessibilityHint
                )
        } header: {
            scopeSectionHeader("Add a Server")
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
        do {
            let receipt = try store.appendSecuringOAuthServer(server, to: servers, consent: true)
            servers = receipt.servers
        } catch {
            addError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
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
