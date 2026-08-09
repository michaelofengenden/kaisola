import SwiftUI

/// Settings ▸ Accounts section that pins a per-project Claude/Codex account on top
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
    /// The account whose sign-in sheet is open, if any.
    @State private var signingIn: UsageAccountProfile?
    private let store = ProjectAccountStore()
    private let usageAccountStore = UsageAccountStore()

    var body: some View {
        VStack(spacing: 16) {
            namedAccountsCard
            perProjectCard
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
        .sheet(item: $signingIn) { profile in
            AccountSignInSheet(profile: profile) {
                signingIn = nil
                loadUsageProfiles()
            }
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

    // MARK: - Cards

    /// Every subscription, and the one place you add another.
    ///
    /// This section used to be raw `Form`/`Section` while General, Terminal and
    /// Updates were built from `SettingsCard`/`SettingsRow` — two visual
    /// languages inside one window, which is what made Settings read as
    /// unfinished here. It now speaks the same one.
    private var namedAccountsCard: some View {
        SettingsCard(title: "Named accounts", symbol: "person.2") {
            if usageProfiles.isEmpty {
                Text("Add each subscription once. Every account keeps its own credentials, and Usage shows their limits side by side.")
                    .font(.callout)
                    .foregroundStyle(.kaisolaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                ForEach(Array(usageProfiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { SettingsDivider() }
                    accountRow(profile)
                }
            }
            SettingsDivider()
            addAccountRow
        }
    }

    /// One named account: what it is, where its credentials live, and the two
    /// things you can do to it.
    ///
    /// The mark is the same one the sidebar draws, so a Claude account looks
    /// like Claude in both places. It used to be a speech bubble here and a
    /// starburst there, which made two views of one account look like two
    /// different things.
    private func accountRow(_ profile: UsageAccountProfile) -> some View {
        HStack(spacing: 12) {
            QuietIdentityMarkView(
                identity: profile.provider == .claude ? .claude : .openai,
                size: 18
            )
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.label)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(profile.directory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.kaisolaSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            // Sign-in belongs beside the account it signs in, not one tab away
            // under Usage. Adding a subscription and logging into it are one
            // intention; splitting them across two screens is why five logins
            // could go into one directory without a single new card appearing.
            Button("Sign In") { signingIn = profile }
                .controlSize(.small)
                .accessibilityLabel("Sign in to \(profile.label)")
            Button(role: .destructive) { pendingRemoval = profile } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Remove this account from Kaisola; its provider files stay on disk")
            .accessibilityLabel("Remove account \(profile.label)")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
    }

    /// Adding an account is a label and a provider; the directory is derived
    /// unless you insist otherwise, which is why it sits behind a placeholder
    /// rather than demanding a path up front.
    private var addAccountRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $newProvider) {
                    ForEach(UsageAccountProfile.Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: newProvider) { _, _ in accountError = nil }

                TextField("Label", text: $newLabel, prompt: Text("Work, Personal, Research…"))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: newLabel) { _, _ in accountError = nil }

                Button("Add") { addProfile() }
                    .controlSize(.small)
                    .disabled(newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TextField(
                "",
                text: $newDirectory,
                prompt: Text(suggestedDirectory ?? newProvider.defaultDirectory)
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            .onChange(of: newDirectory) { _, _ in accountError = nil }
            .accessibilityLabel("Account directory")

            if let accountError {
                Label(accountError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Kaisola stores only the label and this directory. Credentials stay with the provider.")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Which account this project's sessions actually run as.
    private var perProjectCard: some View {
        SettingsCard(title: "This project", symbol: "folder") {
            if let projectID {
                SettingsRow(
                    title: "Claude account",
                    detail: projectName.map { "Used by Claude sessions in \($0)" } ?? "Used by Claude sessions here",
                    symbol: "person.crop.circle"
                ) {
                    accountPicker(provider: .claude, value: $claudeConfigDir, projectID: projectID)
                }
                SettingsDivider()
                SettingsRow(
                    title: "Codex account",
                    detail: projectName.map { "Used by Codex sessions in \($0)" } ?? "Used by Codex sessions here",
                    symbol: "person.crop.circle"
                ) {
                    accountPicker(provider: .codex, value: $codexHome, projectID: projectID)
                }
            } else {
                Text("Open a project to give it its own account. Until then, sessions use the app default.")
                    .font(.callout)
                    .foregroundStyle(.kaisolaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
    }

    /// Pick a named account by name. The directory is what actually gets
    /// stored, but nobody thinks in config directories — they think "the work
    /// one" — so the menu shows labels and keeps the path in the caption.
    private func accountPicker(
        provider: UsageAccountProfile.Provider,
        value: Binding<String>,
        projectID: String
    ) -> some View {
        let matching = usageProfiles.filter { $0.provider == provider }
        let selected = matching.first { $0.directory == value.wrappedValue }
        return Menu {
            Button("App Default") {
                value.wrappedValue = ""
                save(projectID)
            }
            if !matching.isEmpty {
                Divider()
                ForEach(matching) { profile in
                    Button(profile.label) {
                        value.wrappedValue = profile.directory
                        save(projectID)
                    }
                }
            }
        } label: {
            Text(selected?.label ?? (value.wrappedValue.isEmpty ? "App Default" : value.wrappedValue))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 170)
        .accessibilityLabel("\(provider.displayName) account for this project")
    }

    private func removeProfile(_ profile: UsageAccountProfile) {
        guard usageAccountStore.remove(id: profile.id) else { return }
        loadUsageProfiles()
        NotificationCenter.default.post(name: .kaisolaUsageAccountsChanged, object: nil)
    }
}
