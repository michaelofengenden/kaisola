import AppKit
import SwiftUI

extension Notification.Name {
    /// Bridges the in-workspace settings sheet to the delegate-owned Sparkle
    /// controller without coupling the SwiftUI shell to update infrastructure.
    static let kaisolaCheckForUpdates = Notification.Name("kaisolaCheckForUpdates")
}

/// The native Settings window (⌘,): General, Terminal, Guardrails, Agents.
struct SettingsView: View {
    @ObservedObject var settings: NativePreviewSettings
    /// Monospace families are enumerated once — probing every installed font
    /// per body evaluation is too slow.
    @State private var fontFamilies = [TerminalFontOptions.systemMonoSentinel]
    @State private var selectedSection: SettingsSection = .general
    /// Update affordance from the app delegate (Sparkle).
    var checkForUpdates: (() -> Void)?
    var updateDetail: String?
    /// The key window's active project (feeds workspace-scoped tabs like MCP).
    var workspace: URL?
    /// In-workspace presentation supplies a compact Done action. The standalone
    /// Command-comma window omits it and relies on normal window controls.
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            settingsNavigation
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedSection.title)
                            .font(.title3.weight(.semibold))
                        Text(selectedSection.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let dismiss {
                        Button("Done", action: dismiss)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 20)
                .frame(height: 64)
                Divider().opacity(0.65)
                settingsContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 810, height: 540)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
        .task {
            let families = await Task.detached(priority: .utility) {
                TerminalFontOptions.availableMonospaceFamilies()
            }.value
            fontFamilies = families
        }
    }

    private var settingsNavigation: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.white)
                }
                .frame(width: 30, height: 30)
                Text("Settings").font(.headline)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { selectedSection = section }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .frame(width: 18)
                        Text(section.title)
                        Spacer(minLength: 0)
                    }
                    .font(.callout.weight(selectedSection == section ? .semibold : .regular))
                    .foregroundStyle(selectedSection == section ? Color.primary : .secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background(
                        selectedSection == section ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
            Text("Changes apply instantly")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(width: 176)
        .background {
            ZStack {
                NativeVisualEffectView(material: .sidebar)
                LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.accentColor.opacity(0.035), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSection {
        case .general: general
        case .terminal: terminal
        case .guardrails: guardrails.scrollContentBackground(.hidden)
        case .mcp: McpSettingsTab(workspace: workspace).scrollContentBackground(.hidden)
        case .agents: agents.scrollContentBackground(.hidden)
        case .models: ApiKeysSettingsTab().scrollContentBackground(.hidden)
        case .usage: UsageSettingsTab(workspace: workspace).scrollContentBackground(.hidden)
        }
    }

    private var general: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard(title: "Workspace", symbol: "rectangle.3.group") {
                    SettingsRow(title: "Navigation", detail: "Project tree or horizontal tabs", symbol: "sidebar.left") {
                        Menu {
                            ForEach(NavigationLayout.allCases) { layout in
                                Button(layout.title) { settings.navigationLayout = layout }
                            }
                        } label: { SettingsChoiceLabel(settings.navigationLayout.title) }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Appearance", detail: "Follow macOS or pin a theme", symbol: "circle.lefthalf.filled") {
                        Menu {
                            ForEach(AppearanceMode.allCases) { mode in
                                Button(mode.title) { settings.appearance = mode }
                            }
                        } label: { SettingsChoiceLabel(settings.appearance.title) }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Project glass", detail: "Translucent navigation surface", symbol: "sparkles.rectangle.stack") {
                        Menu {
                            ForEach(SidebarAppearance.allCases) { mode in
                                Button(mode.title) { settings.sidebarAppearance = mode }
                            }
                        } label: { SettingsChoiceLabel(settings.sidebarAppearance.title) }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Canvas", detail: "Backdrop behind chats and tools", symbol: "square.on.square") {
                        Menu {
                            ForEach(WorkspaceBackdropMode.allCases) { mode in
                                Button(mode.title) { settings.workspaceBackdrop = mode }
                            }
                        } label: { SettingsChoiceLabel(settings.workspaceBackdrop.title) }
                    }
                }

                SettingsCard(title: "System", symbol: "macwindow") {
                    SettingsRow(title: "Native notifications", detail: "Alert when an agent needs you", symbol: "bell.badge") {
                        Toggle("", isOn: Binding(
                            get: { NotificationBridge.shared.enabled },
                            set: { NotificationBridge.shared.enabled = $0 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    SettingsDivider()
                    SettingsRow(title: "External editor", detail: "Used by Shift-Command-O", symbol: "arrow.up.forward.app") {
                        TextField("System default", text: $settings.externalEditorApp)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, 10)
                            .frame(width: 190, height: 30)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    }
                    SettingsDivider()
                    SettingsRow(title: "Software updates", detail: updateDetail ?? "Sparkle preview channel", symbol: "arrow.triangle.2.circlepath") {
                        Button("Check Now") { checkForUpdates?() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(checkForUpdates == nil)
                    }
                }
            }
            .padding(18)
        }
    }

    private var terminal: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard(title: "Typography", symbol: "textformat") {
                    SettingsRow(title: "Font size", detail: "Command-plus / Command-minus", symbol: "textformat.size") {
                        Slider(
                            value: $settings.terminalFontSize,
                            in: NativePreviewSettings.terminalFontRange,
                            step: 1
                        )
                        .frame(width: 140)
                        Text("\(Int(settings.terminalFontSize))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Typeface", detail: "Monospaced fonts only", symbol: "character.cursor.ibeam") {
                        Menu {
                            ForEach(fontFamilies, id: \.self) { family in
                                Button(family) { settings.terminalFontFamily = family }
                            }
                        } label: { SettingsChoiceLabel(settings.terminalFontFamily) }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Weight", detail: "Terminal glyph density", symbol: "bold") {
                        Menu {
                            ForEach(TerminalFontOptions.weightChoices, id: \.raw) { choice in
                                Button(choice.title) { settings.terminalFontWeight = choice.raw }
                            }
                        } label: {
                            SettingsChoiceLabel(TerminalFontOptions.weightChoices.first(where: { $0.raw == settings.terminalFontWeight })?.title ?? "Regular")
                        }
                    }
                }

                SettingsCard(title: "Color", symbol: "paintpalette") {
                    SettingsRow(title: "Terminal palette", detail: "Opaque for reliable contrast", symbol: "circle.hexagongrid") {
                        Menu {
                            ForEach(TerminalPaletteMode.allCases) { mode in
                                Button(mode.title) { settings.terminalPalette = mode }
                            }
                        } label: { SettingsChoiceLabel(settings.terminalPalette.title) }
                    }
                    TerminalPalettePreview(mode: settings.terminalPalette)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
            }
            .padding(18)
        }
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

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, terminal, guardrails, mcp, agents, models, usage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .guardrails: "Guardrails"
        case .mcp: "MCP"
        case .agents: "Agents"
        case .models: "Models & Keys"
        case .usage: "Usage"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Workspace behavior and appearance"
        case .terminal: "Typography, palette, and interaction"
        case .guardrails: "Standing rules and sensitive files"
        case .mcp: "Workspace tool servers"
        case .agents: "CLI accounts, adapters, and custom agents"
        case .models: "Provider credentials stored in Keychain"
        case .usage: "Context pressure and session activity"
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .terminal: "terminal"
        case .guardrails: "shield.lefthalf.filled"
        case .mcp: "puzzlepiece.extension"
        case .agents: "sparkles"
        case .models: "key"
        case .usage: "gauge.with.dots.needle.bottom.50percent"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 40)
            Divider().opacity(0.65)
            content
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.035), radius: 12, y: 5)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 50).opacity(0.55) }
}

private struct SettingsChoiceLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(minWidth: 108, minHeight: 30)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TerminalPalettePreview: View {
    let mode: TerminalPaletteMode
    var body: some View {
        HStack(spacing: 10) {
            Text("~/Kaisola")
                .foregroundStyle(.secondary)
            Text("%")
                .foregroundStyle(mode == .native ? Color.primary : .purple)
            Text("codex")
                .foregroundStyle(mode == .native ? Color.primary : .green)
            Rectangle().frame(width: 7, height: 15)
            Spacer()
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
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
