import SwiftUI

/// Settings ▸ Agents section that pins a per-project Claude/Codex account on top
/// of the app-wide one. Overrides are project-scoped, so a nil `projectID` (no
/// active project) has nowhere to store them — the section shows a hint instead
/// of the editor, mirroring `McpSettingsTab`. Electron parity: per-project
/// CLAUDE_CONFIG_DIR / CODEX_HOME isolation.
struct ProjectAccountsSection: View {
    /// The active project's broker id (NativeSessionStore.projectID), or nil when
    /// no project is open.
    let projectID: String?
    /// The active project's display name, for the caption.
    let projectName: String?

    @State private var claudeConfigDir = ""
    @State private var codexHome = ""
    @State private var usageProfiles: [UsageAccountProfile] = []
    @State private var newProvider: UsageAccountProfile.Provider = .claude
    @State private var newLabel = ""
    @State private var newDirectory = ""
    private let store = ProjectAccountStore()
    private let usageAccountStore = UsageAccountStore()

    var body: some View {
        Section("Per-project account") {
            if let projectID {
                accountDirectoryRow(
                    title: "Claude",
                    environmentName: "CLAUDE_CONFIG_DIR",
                    provider: .claude,
                    value: $claudeConfigDir,
                    projectID: projectID
                )
                accountDirectoryRow(
                    title: "Codex",
                    environmentName: "CODEX_HOME",
                    provider: .codex,
                    value: $codexHome,
                    projectID: projectID
                )
                Text("Overrides the app-wide account for sessions in \(projectName ?? "this project") only. Leave a field blank to keep using the app default above for that CLI.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Open a project to give it its own Claude/Codex account. Its agent sessions then use these directories instead of the app-wide account above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("Named accounts") {
            if usageProfiles.isEmpty {
                Label("Add each subscription once, then view all of their exact limits together in Usage.", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(usageProfiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: profile.provider == .claude ? "bubble.left.and.text.bubble.right" : "terminal")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.label)
                                    .font(.callout.weight(.medium))
                                Text(profile.provider.displayName)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(profile.directory)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) { removeProfile(profile) } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this account from Kaisola; its provider files stay on disk")
                    }
                }
            }

            Picker("Provider", selection: $newProvider) {
                ForEach(UsageAccountProfile.Provider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            TextField("Account label", text: $newLabel, prompt: Text("Work, Personal, Research…"))
            TextField(
                "Account directory",
                text: $newDirectory,
                prompt: Text(suggestedDirectory ?? newProvider.defaultDirectory)
            )
            HStack {
                Text("Only the label and directory are stored. Tokens remain in the provider's own credential files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add account") { addProfile() }
                    .disabled(newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        // A fresh load whenever the active project changes underneath the window.
        .onAppear {
            load()
            loadUsageProfiles()
        }
        .onChange(of: projectID) { _, _ in load() }
        // Persist on every edit — the store no-ops when nothing changed, so the
        // load above never triggers a spurious write.
        .onChange(of: claudeConfigDir) { _, _ in if let projectID { save(projectID) } }
        .onChange(of: codexHome) { _, _ in if let projectID { save(projectID) } }
    }

    private func load() {
        let override = projectID.flatMap { store.override(forProject: $0) }
        claudeConfigDir = override?.claudeConfigDir ?? ""
        codexHome = override?.codexHome ?? ""
    }

    private func save(_ projectID: String) {
        store.set(
            ProjectAccountOverride(claudeConfigDir: claudeConfigDir, codexHome: codexHome),
            forProject: projectID
        )
    }

    @ViewBuilder
    private func accountDirectoryRow(
        title: String,
        environmentName: String,
        provider: UsageAccountProfile.Provider,
        value: Binding<String>,
        projectID: String
    ) -> some View {
        HStack(spacing: 8) {
            TextField(environmentName, text: value, prompt: Text("app default"))
                .onSubmit { save(projectID) }
            if usageProfiles.contains(where: { $0.provider == provider }) {
                Menu {
                    Button("App default") { value.wrappedValue = "" }
                    Divider()
                    ForEach(usageProfiles.filter { $0.provider == provider }) { profile in
                        Button(profile.label) { value.wrappedValue = profile.directory }
                    }
                } label: {
                    Label("Choose \(title)", systemImage: "person.crop.circle")
                        .labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .help("Choose a named \(title) account")
            }
        }
    }

    private var suggestedDirectory: String? {
        UsageAccountStore.suggestedDirectory(provider: newProvider, label: newLabel)
    }

    private func loadUsageProfiles() {
        usageProfiles = usageAccountStore.profiles()
    }

    private func addProfile() {
        let directory = newDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = directory.isEmpty ? suggestedDirectory : directory,
              usageAccountStore.add(provider: newProvider, label: newLabel, directory: resolved) != nil else { return }
        newLabel = ""
        newDirectory = ""
        loadUsageProfiles()
        NotificationCenter.default.post(name: .kaisolaUsageAccountsChanged, object: nil)
    }

    private func removeProfile(_ profile: UsageAccountProfile) {
        guard usageAccountStore.remove(id: profile.id) else { return }
        loadUsageProfiles()
        NotificationCenter.default.post(name: .kaisolaUsageAccountsChanged, object: nil)
    }
}
