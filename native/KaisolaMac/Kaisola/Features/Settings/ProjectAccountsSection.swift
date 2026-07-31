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
    @State private var accountError: String?
    @State private var pendingRemoval: UsageAccountProfile?
    private let store = ProjectAccountStore()
    private let usageAccountStore = UsageAccountStore()

    var body: some View {
        Section("Per-Project Account") {
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

        Section("Named Accounts") {
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
                        Button(role: .destructive) { pendingRemoval = profile } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this account from Kaisola; its provider files stay on disk")
                        .accessibilityLabel("Remove account \(profile.label)")
                    }
                }
            }

            Picker("Provider", selection: $newProvider) {
                ForEach(UsageAccountProfile.Provider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: newProvider) { _, _ in accountError = nil }
            TextField("Account label", text: $newLabel, prompt: Text("Work, Personal, Research…"))
                .onChange(of: newLabel) { _, _ in accountError = nil }
            TextField(
                "Account directory",
                text: $newDirectory,
                prompt: Text(suggestedDirectory ?? newProvider.defaultDirectory)
            )
            .onChange(of: newDirectory) { _, _ in accountError = nil }
            if let accountError {
                Text(accountError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Text("Only the label and directory are stored. Tokens remain in the provider's own credential files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Account") { addProfile() }
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
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaUsageAccountsChanged)) { _ in
            loadUsageProfiles()
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.label ?? "Account")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                guard let profile = pendingRemoval else { return }
                pendingRemoval = nil
                removeProfile(profile)
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Kaisola will forget this named account. Its provider files and sign-in stay on disk.")
        }
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
                    Button("App Default") { value.wrappedValue = "" }
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
        let resolved = directory.isEmpty ? suggestedDirectory : directory
        guard let resolved else {
            accountError = "Enter an account directory, or use a label containing letters or numbers so Kaisola can suggest one."
            return
        }
        let expanded = (resolved as NSString).expandingTildeInPath
        if usageProfiles.contains(where: {
            $0.provider == newProvider && $0.expandedDirectory == expanded
        }) {
            accountError = "A \(newProvider.displayName) account already uses \(resolved)."
            return
        }
        guard expanded.hasPrefix("/"),
              !resolved.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            accountError = "Enter an absolute directory or a path beginning with ~/."
            return
        }
        guard usageAccountStore.add(
            provider: newProvider,
            label: newLabel,
            directory: resolved
        ) != nil else {
            accountError = "Kaisola couldn't save this account. Check the label and directory, then try again."
            return
        }
        newLabel = ""
        newDirectory = ""
        accountError = nil
        loadUsageProfiles()
        NotificationCenter.default.post(name: .kaisolaUsageAccountsChanged, object: nil)
    }

    private func removeProfile(_ profile: UsageAccountProfile) {
        guard usageAccountStore.remove(id: profile.id) else { return }
        loadUsageProfiles()
        NotificationCenter.default.post(name: .kaisolaUsageAccountsChanged, object: nil)
    }
}
