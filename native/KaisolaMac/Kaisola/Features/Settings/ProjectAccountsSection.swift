import AppKit
import SwiftUI

/// What a project's stored account directory currently points at.
///
/// The stored value is a path, but the menu speaks in account names, so the
/// path has to be resolved back to a named account before it can be shown. A
/// path no named account claims is its own state rather than a third kind of
/// title: an account can be removed, moved, or edited outside Kaisola, and
/// printing the orphaned path where a name belongs made a broken assignment
/// look like an ordinary selection.
enum ProjectAccountSelection: Equatable {
    /// No override stored: sessions here run as the app-wide account.
    case appDefault
    /// The stored directory belongs to this named account.
    case account(UsageAccountProfile)
    /// Nothing claims the stored directory, which is kept verbatim so the row
    /// can show what broke and the repair menu can leave it alone.
    case missing(String)

    /// One way out of a broken (or merely unwanted) assignment. Repairs are a
    /// value rather than menu code so the offer and its tests agree on what is
    /// compatible: App Default always, plus the named accounts of this
    /// provider. Nothing is written until one is chosen.
    enum Repair: Equatable, Identifiable {
        case appDefault
        case account(UsageAccountProfile)

        var id: String {
            switch self {
            case .appDefault: "app-default"
            case .account(let profile): profile.id
            }
        }

        var title: String {
            switch self {
            case .appDefault: "App Default"
            case .account(let profile): profile.label
            }
        }

        /// What this repair stores in the override. App Default stores nothing,
        /// which is how the store learns to drop the entry.
        var storedDirectory: String {
            switch self {
            case .appDefault: ""
            case .account(let profile): profile.directory
            }
        }
    }

    static func resolve(
        storedDirectory: String,
        provider: UsageAccountProfile.Provider,
        profiles: [UsageAccountProfile]
    ) -> ProjectAccountSelection {
        let stored = storedDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return .appDefault }
        let target = canonicalPath(stored)
        let match = profiles.first {
            $0.provider == provider
                && !$0.directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && canonicalPath($0.directory) == target
        }
        return match.map(ProjectAccountSelection.account) ?? .missing(stored)
    }

    static func repairs(
        provider: UsageAccountProfile.Provider,
        profiles: [UsageAccountProfile]
    ) -> [Repair] {
        [.appDefault] + profiles.filter { $0.provider == provider }.map(Repair.account)
    }

    /// Tilde expansion plus path standardisation, the same shape UsageCenter
    /// uses to collapse duplicate accounts. Without it an account saved as
    /// `~/.claude-work` and an assignment saved in its expanded form would read
    /// as broken while pointing at one directory.
    private static func canonicalPath(_ value: String) -> String {
        let expanded = (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    /// The stored directory when nothing claims it; nil otherwise.
    var missingDirectory: String? {
        if case .missing(let directory) = self { return directory }
        return nil
    }

    var isMissing: Bool { missingDirectory != nil }

    /// What the menu button reads. A broken assignment says so instead of
    /// showing its path where a name belongs.
    var menuTitle: String {
        switch self {
        case .appDefault: "App Default"
        case .account(let profile): profile.label
        case .missing: "Missing account"
        }
    }

    /// The caption under the row title: normally who uses this account, and for
    /// a broken assignment the path that no longer resolves.
    func detail(provider: UsageAccountProfile.Provider, projectName: String?) -> String {
        if let missingDirectory {
            return "No named account uses \(missingDirectory)"
        }
        if let projectName {
            return "Used by \(provider.displayName) sessions in \(projectName)"
        }
        return "Used by \(provider.displayName) sessions here"
    }

    /// Header above the repairs, naming what broke.
    var repairHeader: String? {
        missingDirectory.map { "Missing: \($0)" }
    }

    /// VoiceOver reads the state, not just the row's name, so a broken
    /// assignment is audible without opening the menu.
    var accessibilityValue: String {
        if let missingDirectory {
            return "Missing account, \(missingDirectory)"
        }
        return menuTitle
    }
}

/// The spoken contract for the provider control in the add-account form.
///
/// The segmented picker hides its visual label to preserve the compact row, so
/// it must name both what it changes and the value that is currently selected.
enum NewAccountProviderAccessibility {
    static let label = "New account provider"

    static func value(_ provider: UsageAccountProfile.Provider) -> String {
        provider.displayName
    }
}

/// Copy for the destructive named-account confirmation. Keeping the wording in
/// a value lets tests prove that affected projects are listed and that the only
/// destructive choice says what replaces their assignment.
struct NamedAccountRemovalConfirmation: Equatable {
    let accountLabel: String
    let projectLabels: [String]

    var actionTitle: String {
        projectLabels.isEmpty ? "Remove Account" : "Use App Default and Remove Account"
    }

    var message: String {
        guard !projectLabels.isEmpty else {
            return "Kaisola will forget \(accountLabel). Its provider files and sign-in stay on disk."
        }
        let count = projectLabels.count
        return "\(accountLabel) is assigned to \(count) \(count == 1 ? "project" : "projects"): \(Self.list(projectLabels)). Those projects will use App Default. The provider files and sign-in stay on disk."
    }

    private static func list(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default: return values.dropLast().joined(separator: ", ") + ", and " + values.last!
        }
    }
}

/// Non-secret account state derived from the signed usage helper's latest
/// provider-scoped result. The UI never inspects credential files or retains
/// provider identity data; it shows only readiness, a bounded diagnostic, and
/// when the helper last answered.
struct NamedAccountAuthenticationPresentation: Equatable {
    enum Status: Equatable {
        case checking
        case unchecked
        case signedIn
        case signedOut
        case expired
        case failed
    }

    enum Action: Equatable {
        case signIn
        case reauthenticate
        case check
    }

    let status: Status
    let action: Action
    let lastVerification: Date?
    let diagnostic: String?

    static func resolve(
        reading: UsageCenter.ProviderPlanUsage?,
        isRefreshing: Bool
    ) -> NamedAccountAuthenticationPresentation {
        guard let reading else {
            return NamedAccountAuthenticationPresentation(
                status: isRefreshing ? .checking : .unchecked,
                action: .check,
                lastVerification: nil,
                diagnostic: nil
            )
        }
        if reading.ok {
            return NamedAccountAuthenticationPresentation(
                status: .signedIn,
                action: .check,
                lastVerification: reading.updatedDate,
                diagnostic: nil
            )
        }
        let message = reading.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if reading.authRequired == true {
            let expired = message.map(isExpiredAuthenticationMessage) ?? false
            return NamedAccountAuthenticationPresentation(
                status: expired ? .expired : .signedOut,
                action: expired ? .reauthenticate : .signIn,
                lastVerification: reading.updatedDate,
                diagnostic: message
            )
        }
        return NamedAccountAuthenticationPresentation(
            status: .failed,
            action: .check,
            lastVerification: reading.updatedDate,
            diagnostic: message
        )
    }

    var title: String {
        switch status {
        case .checking: "Checking"
        case .unchecked: "Not checked"
        case .signedIn: "Signed in"
        case .signedOut: "Not signed in"
        case .expired: "Sign-in expired"
        case .failed: "Check failed"
        }
    }

    var actionTitle: String {
        switch action {
        case .signIn: "Sign In"
        case .reauthenticate: "Reauthenticate"
        case .check: "Check"
        }
    }

    var symbolName: String {
        switch status {
        case .checking: "clock.arrow.circlepath"
        case .unchecked: "circle.dotted"
        case .signedIn: "checkmark.circle.fill"
        case .signedOut: "person.crop.circle.badge.questionmark"
        case .expired: "clock.badge.exclamationmark"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    func detail(now: Date) -> String {
        let checked = Self.lastCheckedCaption(lastVerification, now: now)
        switch status {
        case .checking:
            return "Checking provider authentication…"
        case .unchecked:
            return "No verification yet."
        case .signedIn:
            return checked
        case .signedOut, .expired, .failed:
            guard let diagnostic, !diagnostic.isEmpty else { return checked }
            return "\(diagnostic) · \(checked)"
        }
    }

    static func lastCheckedCaption(_ date: Date?, now: Date) -> String {
        guard let date else { return "No verification time." }
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "Last checked just now" }
        if elapsed < 3_600 { return "Last checked \(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "Last checked \(Int(elapsed / 3_600))h ago" }
        return "Last checked \(Int(elapsed / 86_400))d ago"
    }

    private static func isExpiredAuthenticationMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return ["expired", "revoked", "unauthorized", "invalidated oauth"].contains {
            normalized.contains($0)
        }
    }
}

/// Which surface the per-project card must show. Store recovery outranks an
/// ordinary project row because unreadable account data cannot safely be
/// interpreted as App Default or as a missing named-account assignment.
enum ProjectAccountCardMode: Equatable {
    case recovery
    case project
    case noProject

    static func resolve(hasRecoveryIssue: Bool, projectID: String?) -> ProjectAccountCardMode {
        if hasRecoveryIssue { return .recovery }
        return projectID == nil ? .noProject : .project
    }
}

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
    /// The usage helper scopes provider probes to the same effective account
    /// environment as the active workspace.
    let workspace: URL?

    @State private var claudeConfigDir = ""
    @State private var codexHome = ""
    @State private var usageProfiles: [UsageAccountProfile] = []
    @State private var newProvider: UsageAccountProfile.Provider = .claude
    @State private var newLabel = ""
    @State private var newDirectory = ""
    @State private var accountError: String?
    @State private var pendingRemoval: UsageAccountProfile?
    @State private var pendingRemovalProjectLabels: [String] = []
    @State private var confirmingRecoveryReset = false
    /// The account whose sign-in sheet is open, if any.
    @State private var signingIn: UsageAccountProfile?
    @ObservedObject private var recoveryCenter: ProjectAccountRecoveryCenter
    @ObservedObject private var usage: UsageCenter
    private let usageAccountStore = UsageAccountStore()

    init(
        projectID: String?,
        projectName: String?,
        workspace: URL? = nil,
        recoveryCenter: ProjectAccountRecoveryCenter = .shared,
        usage: UsageCenter = .shared
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.workspace = workspace
        _recoveryCenter = ObservedObject(wrappedValue: recoveryCenter)
        _usage = ObservedObject(wrappedValue: usage)
    }

    var body: some View {
        VStack(spacing: 16) {
            namedAccountsCard
            perProjectCard
        }
        // A fresh load whenever the active project changes underneath the window.
        .onAppear {
            load()
            loadUsageProfiles()
            refreshAuthentication()
        }
        .onChange(of: projectID) { _, _ in
            load()
            refreshAuthentication()
        }
        // Persist on every edit — the store no-ops when nothing changed, so the
        // load above never triggers a spurious write.
        .onChange(of: claudeConfigDir) { _, _ in if let projectID { save(projectID) } }
        .onChange(of: codexHome) { _, _ in if let projectID { save(projectID) } }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaUsageAccountsChanged)) { _ in
            loadUsageProfiles()
            refreshAuthentication(force: true)
        }
        .sheet(item: $signingIn) { profile in
            AccountSignInSheet(profile: profile) {
                signingIn = nil
                loadUsageProfiles()
                refreshAuthentication(force: true)
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.label ?? "Account")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: {
                    if !$0 {
                        pendingRemoval = nil
                        pendingRemovalProjectLabels = []
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(removalConfirmation.actionTitle, role: .destructive) {
                guard let profile = pendingRemoval else { return }
                pendingRemoval = nil
                pendingRemovalProjectLabels = []
                removeProfile(profile)
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
                pendingRemovalProjectLabels = []
            }
        } message: {
            Text(removalConfirmation.message)
        }
        .confirmationDialog(
            "Reset all project account overrides?",
            isPresented: $confirmingRecoveryReset,
            titleVisibility: .visible
        ) {
            Button("Reset Project Accounts", role: .destructive) { resetAfterFailure() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kaisola will keep the damaged or unsupported file beside the active one, then clear every project's Claude and Codex selection. Agent launches can use app defaults again only after this explicit reset.")
        }
    }

    private func load() {
        switch recoveryCenter.loadStatus() {
        case .missing:
            claudeConfigDir = ""
            codexHome = ""
        case .loaded(let payload):
            let override = projectID.flatMap { payload.projects[$0] }
            claudeConfigDir = override?.claudeConfigDir ?? ""
            codexHome = override?.codexHome ?? ""
        case .blocked:
            claudeConfigDir = ""
            codexHome = ""
        }
    }

    private func save(_ projectID: String) {
        guard recoveryCenter.issue == nil else { return }
        do {
            try recoveryCenter.set(
                ProjectAccountOverride(claudeConfigDir: claudeConfigDir, codexHome: codexHome),
                forProject: projectID
            )
        } catch ProjectAccountStore.StoreError.recoveryRequired {
        } catch {
            accountError = error.localizedDescription
        }
    }

    private func revealRecoveryFile() {
        guard let recoveryIssue = recoveryCenter.issue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryIssue.revealURL])
    }

    private func resetAfterFailure() {
        do {
            let preserved = try recoveryCenter.resetAfterFailure()
            load()
            ToastCenter.shared.show(
                "Reset project account overrides; kept \(preserved.lastPathComponent)",
                style: .success,
                duration: 6
            )
        } catch {
            load()
            accountError = error.localizedDescription
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
        guard expanded.hasPrefix("/"),
              !resolved.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            accountError = "Enter an absolute directory or a path beginning with ~/."
            return
        }
        // An alias is not a second subscription. Name the account the directory
        // already belongs to, so a symlink or a `..` path reads as the collision
        // it is rather than as an unexplained refusal.
        if let existing = UsageAccountStore.existingProfile(
            in: usageProfiles,
            provider: newProvider,
            directory: resolved
        ) {
            accountError = existing.directory == resolved
                ? "A \(newProvider.displayName) account already uses \(resolved)."
                : "\(resolved) is the same directory as “\(existing.label)” (\(existing.directory)). Kaisola keeps one account per credential directory."
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
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let authentication = authenticationPresentation(for: profile)
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
                    Label(authentication.title, systemImage: authentication.symbolName)
                        .font(.caption)
                        .foregroundStyle(authenticationColor(authentication.status))
                    Text(authentication.detail(now: timeline.date))
                        .font(.caption2)
                        .foregroundStyle(.kaisolaSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(authentication.actionTitle) {
                    performAuthenticationAction(authentication.action, profile: profile)
                }
                .controlSize(.small)
                .disabled(authentication.status == .checking)
                .accessibilityLabel("\(authentication.actionTitle) \(profile.label)")
                if usage.isRefreshingPlanUsage, authentication.action == .check {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Checking \(profile.label)")
                }
                Button(role: .destructive) { prepareRemoval(profile) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Remove this account from Kaisola; its provider files stay on disk")
                .accessibilityLabel("Remove account \(profile.label)")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 86)
        }
    }

    private func authenticationPresentation(
        for profile: UsageAccountProfile
    ) -> NamedAccountAuthenticationPresentation {
        let reading = usage.planUsage.first { $0.profileID == profile.id }
        return NamedAccountAuthenticationPresentation.resolve(
            reading: reading,
            isRefreshing: usage.isRefreshingPlanUsage
        )
    }

    private func performAuthenticationAction(
        _ action: NamedAccountAuthenticationPresentation.Action,
        profile: UsageAccountProfile
    ) {
        switch action {
        case .signIn, .reauthenticate:
            signingIn = profile
        case .check:
            refreshAuthentication(force: true)
        }
    }

    private func refreshAuthentication(force: Bool = false) {
        usage.refreshPlanUsage(workspace: workspace, force: force)
    }

    private func authenticationColor(
        _ status: NamedAccountAuthenticationPresentation.Status
    ) -> Color {
        switch status {
        case .signedIn: .green
        case .expired, .failed: KaisolaStatusTone.failed.foregroundColor
        case .signedOut: KaisolaStatusTone.needsYou.foregroundColor
        case .checking, .unchecked: .secondary
        }
    }

    /// Adding an account is a label and a provider; the directory is derived
    /// unless you insist otherwise, which is why it sits behind a placeholder
    /// rather than demanding a path up front.
    private var addAccountRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker(NewAccountProviderAccessibility.label, selection: $newProvider) {
                    ForEach(UsageAccountProfile.Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text(NewAccountProviderAccessibility.label))
                .accessibilityValue(Text(NewAccountProviderAccessibility.value(newProvider)))
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
            switch ProjectAccountCardMode.resolve(
                hasRecoveryIssue: recoveryCenter.issue != nil,
                projectID: projectID
            ) {
            case .recovery:
                if let recoveryIssue = recoveryCenter.issue {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(recoveryIssue.title, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                        Text(recoveryIssue.message)
                            .font(.caption)
                            .foregroundStyle(.kaisolaSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Retry") { load() }
                                .buttonStyle(.borderedProminent)
                            Button(recoveryIssue.preservedCopyURL == nil
                                ? "Reveal Original in Finder"
                                : "Reveal Preserved Copy in Finder") {
                                revealRecoveryFile()
                            }
                            .buttonStyle(.bordered)
                            Button("Reset…", role: .destructive) {
                                confirmingRecoveryReset = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("kaisola.project-account-recovery")
                }
            case .project:
                if let projectID {
                    projectAccountRow(provider: .claude, value: $claudeConfigDir, projectID: projectID)
                    SettingsDivider()
                    projectAccountRow(provider: .codex, value: $codexHome, projectID: projectID)
                }
            case .noProject:
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

    /// One provider's assignment for this project. The caption carries the
    /// broken path when there is one, because the menu button has room for a
    /// state but not for a diagnostic.
    private func projectAccountRow(
        provider: UsageAccountProfile.Provider,
        value: Binding<String>,
        projectID: String
    ) -> some View {
        let selection = ProjectAccountSelection.resolve(
            storedDirectory: value.wrappedValue,
            provider: provider,
            profiles: usageProfiles
        )
        return SettingsRow(
            title: "\(provider.displayName) account",
            detail: selection.detail(provider: provider, projectName: projectName),
            symbol: selection.isMissing ? "exclamationmark.triangle" : "person.crop.circle"
        ) {
            accountPicker(
                provider: provider,
                value: value,
                projectID: projectID,
                selection: selection
            )
        }
    }

    /// Pick a named account by name. The directory is what actually gets
    /// stored, but nobody thinks in config directories — they think "the work
    /// one" — so the menu shows labels and keeps the path in the caption.
    ///
    /// A directory no account claims reads as "Missing account" rather than as
    /// a selected value, and the same menu doubles as the repair: App Default
    /// or any account of this provider, one click each. The broken value stays
    /// stored until one of them is picked — a silent reset would hide that the
    /// project ever pointed somewhere else.
    private func accountPicker(
        provider: UsageAccountProfile.Provider,
        value: Binding<String>,
        projectID: String,
        selection: ProjectAccountSelection
    ) -> some View {
        Menu {
            if let repairHeader = selection.repairHeader {
                Section(repairHeader) {
                    repairItems(provider: provider, value: value, projectID: projectID)
                }
            } else {
                repairItems(provider: provider, value: value, projectID: projectID)
            }
        } label: {
            HStack(spacing: 4) {
                if selection.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                }
                Text(selection.menuTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(width: 170)
        .help(selection.missingDirectory.map { "No named \(provider.displayName) account uses \($0)" }
            ?? "Choose which account \(provider.displayName) sessions in this project run as")
        .accessibilityLabel("\(provider.displayName) account for this project")
        .accessibilityValue(selection.accessibilityValue)
    }

    private func repairItems(
        provider: UsageAccountProfile.Provider,
        value: Binding<String>,
        projectID: String
    ) -> some View {
        let repairs = ProjectAccountSelection.repairs(provider: provider, profiles: usageProfiles)
        return ForEach(Array(repairs.enumerated()), id: \.element.id) { index, repair in
            // App Default is the first entry; the named accounts follow it
            // under a rule, as they did before repairs became a list.
            if index == 1 { Divider() }
            Button(repair.title) {
                value.wrappedValue = repair.storedDirectory
                save(projectID)
            }
        }
    }

    private func removeProfile(_ profile: UsageAccountProfile) {
        do {
            _ = try recoveryCenter.clearAssignments(
                to: profile.directory,
                provider: profile.provider
            )
            guard usageAccountStore.remove(id: profile.id) else {
                load()
                accountError = "Kaisola reassigned affected projects to App Default, but couldn't remove \(profile.label). Try removing the account again."
                return
            }
            load()
            loadUsageProfiles()
            accountError = nil
            NotificationCenter.default.post(name: .kaisolaUsageAccountsChanged, object: nil)
        } catch {
            accountError = error.localizedDescription
        }
    }

    private var removalConfirmation: NamedAccountRemovalConfirmation {
        NamedAccountRemovalConfirmation(
            accountLabel: pendingRemoval?.label ?? "Account",
            projectLabels: pendingRemovalProjectLabels
        )
    }

    private func prepareRemoval(_ profile: UsageAccountProfile) {
        do {
            let projectIDs = try recoveryCenter.projectIDs(
                assignedTo: profile.directory,
                provider: profile.provider
            )
            let projectNames = NativeSessionStore().projects().reduce(into: [String: String]()) {
                // A malformed legacy session archive must not make the removal
                // confirmation trap. The account store remains authoritative;
                // this map is display-only, so the first known name is enough.
                if $0[$1.id] == nil { $0[$1.id] = $1.name }
            }
            pendingRemovalProjectLabels = projectIDs.map { projectID in
                if projectID == self.projectID,
                   let projectName,
                   !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return projectName
                }
                return projectNames[projectID] ?? projectID
            }
            pendingRemoval = profile
            accountError = nil
        } catch {
            pendingRemoval = nil
            pendingRemovalProjectLabels = []
            accountError = error.localizedDescription
        }
    }
}
