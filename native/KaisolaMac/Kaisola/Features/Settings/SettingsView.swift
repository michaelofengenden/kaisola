import SwiftUI

/// The native Settings window (⌘,): General, Terminal, Guardrails, Agents.
struct SettingsView: View {
    @ObservedObject var settings: NativePreviewSettings
    /// Monospace families are enumerated once — probing every installed font
    /// per body evaluation is too slow.
    @State private var fontFamilies = TerminalFontOptions.availableMonospaceFamilies()
    /// Update affordance from the app delegate (Sparkle).
    var checkForUpdates: (() -> Void)?
    var updateDetail: String?
    /// The key window's active project (feeds workspace-scoped tabs like MCP).
    var workspace: URL?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            terminal.tabItem { Label("Terminal", systemImage: "terminal") }
            guardrails.tabItem { Label("Guardrails", systemImage: "shield.lefthalf.filled") }
            McpSettingsTab(workspace: workspace)
                .tabItem { Label("MCP", systemImage: "puzzlepiece.extension") }
            agents.tabItem { Label("Agents", systemImage: "sparkles") }
            ApiKeysSettingsTab()
                .tabItem { Label("Models & keys", systemImage: "key") }
            UsageSettingsTab()
                .tabItem { Label("Usage", systemImage: "gauge.with.dots.needle.bottom.50percent") }
        }
        .frame(width: 620, height: 460)
    }

    private var general: some View {
        Form {
            Picker("Navigation layout", selection: $settings.navigationLayout) {
                ForEach(NavigationLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Project sidebar", selection: $settings.sidebarAppearance) {
                ForEach(SidebarAppearance.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Picker("Workspace background", selection: $settings.workspaceBackdrop) {
                ForEach(WorkspaceBackdropMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text("Glass keeps project navigation light; System is the cleanest workspace canvas. Terminal panes always stay opaque for readability.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Native notifications", isOn: Binding(
                get: { NotificationBridge.shared.enabled },
                set: { NotificationBridge.shared.enabled = $0 }
            ))
            Text("When Kaisola is in the background, needs-you moments post a system notification. Click it to jump back.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("External editor", text: $settings.externalEditorApp, prompt: Text("System default"))
            Text("App name for ⇧⌘O — e.g. Visual Studio Code, Cursor, Zed. Blank opens with the file's default app.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Updates") {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Check for Updates…") { checkForUpdates?() }
                        .disabled(checkForUpdates == nil)
                    if let updateDetail {
                        Text(updateDetail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }

    private var terminal: some View {
        Form {
            LabeledContent("Font size") {
                HStack {
                    Slider(
                        value: $settings.terminalFontSize,
                        in: NativePreviewSettings.terminalFontRange,
                        step: 1
                    )
                    .frame(width: 220)
                    Text("\(Int(settings.terminalFontSize)) pt")
                        .font(.callout.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                    Button("Reset") { settings.resetTerminalFont() }
                }
            }
            Picker("Font family", selection: $settings.terminalFontFamily) {
                ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            Picker("Weight", selection: $settings.terminalFontWeight) {
                ForEach(TerminalFontOptions.weightChoices, id: \.raw) { Text($0.title).tag($0.raw) }
            }
            Picker("Palette", selection: $settings.terminalPalette) {
                ForEach(TerminalPaletteMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text("macOS Terminal is the quiet native default. Kaisola uses the richer Electron-matched ANSI palette.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(6)
    }

    private var guardrails: some View {
        GuardrailsSettings(settings: settings)
    }

    private var agents: some View {
        Form {
            Section("Account isolation") {
                TextField("CLAUDE_CONFIG_DIR", text: $settings.claudeConfigDir, prompt: Text("CLI default"))
                TextField("CODEX_HOME", text: $settings.codexHome, prompt: Text("CLI default"))
                Text("Applied to new agent terminals and chats; leave blank to use each CLI's own login.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ProjectAccountsSection(
                projectID: workspace.map { NativeSessionStore.projectID(forDirectory: $0.path) },
                projectName: workspace.map { ($0.path as NSString).lastPathComponent }
            )
            Section {
                SignInCardView { command in
                    NotificationCenter.default.post(
                        name: .kaisolaRunInTerminal,
                        object: nil,
                        userInfo: [SignInCardView.commandUserInfoKey: command]
                    )
                }
                .listRowInsets(EdgeInsets())
            }
            CustomAgentsSection()
            Section("ACP adapters") {
                ForEach(AgentRegistry.all) { agent in
                    if let adapter = AcpAdapter.forAgent(agent.id) {
                        LabeledContent(agent.name) {
                            Text(([adapter.command] + adapter.arguments).joined(separator: " "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Text("Adapters resolve @latest on every chat, so they stay current automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }
}

/// Guardrails tab: standing permission rules (delete) + sensitive globs (edit).
private struct GuardrailsSettings: View {
    @ObservedObject var settings: NativePreviewSettings
    @State private var rules: [PermissionRule] = []
    @State private var newGlob = ""
    private let store = PermissionRuleStore()

    var body: some View {
        Form {
            Section("Standing allow-rules") {
                if rules.isEmpty {
                    Text("No rules yet — \"Always allow\" on a permission ask creates one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AcpPermissionRules.ruleLabel(action: rule.action, resource: rule.resource))
                                .font(.callout)
                            Text(rule.workspace)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.remove(id: rule.id)
                            rules = store.rules()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section("Sensitive files (always ask, never rule-covered)") {
                ForEach(settings.sensitiveGlobs, id: \.self) { glob in
                    HStack {
                        Text(glob).font(.callout.monospaced())
                        Spacer()
                        Button(role: .destructive) {
                            settings.sensitiveGlobs.removeAll { $0 == glob }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add glob (e.g. **/*.p12)", text: $newGlob)
                        .onSubmit(addGlob)
                    Button("Add", action: addGlob)
                        .disabled(newGlob.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Restore defaults") {
                    settings.sensitiveGlobs = AcpPermissionRules.defaultSensitiveGlobs
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding(6)
        .onAppear { rules = store.rules() }
    }

    private func addGlob() {
        let trimmed = newGlob.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !settings.sensitiveGlobs.contains(trimmed) else { return }
        settings.sensitiveGlobs.append(trimmed)
        newGlob = ""
    }
}
