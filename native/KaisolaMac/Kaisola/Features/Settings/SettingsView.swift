import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Bridges the in-workspace settings sheet to the delegate-owned Sparkle
    /// controller without coupling the SwiftUI shell to update infrastructure.
    static let kaisolaCheckForUpdates = Notification.Name("kaisolaCheckForUpdates")
}

/// The native Settings window (⌘,): workspace, terminal, Companion, and tools.
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthModel
    @ObservedObject var settings: NativePreviewSettings
    /// Monospace families are enumerated once — probing every installed font
    /// per body evaluation is too slow.
    @State private var fontFamilies = [TerminalFontOptions.systemMonoSentinel]
    @State private var selectedSection: SettingsSection = .general
    /// Update affordance from the app delegate (Sparkle).
    var checkForUpdates: (() -> Void)?
    var updateDetail: String?
    /// Turns a relaunch would abort, so the restart prompt can say so.
    var interruptibleTurnCount: (() -> Int)?
    @ObservedObject private var updates = UpdateCenter.shared
    @State private var restartRequest: RestartRequest?
    @State private var notificationsEnabled = true
    /// Bumped when a per-event notification rule changes, so the menu labels
    /// re-read the bridge (which owns the persisted rules).
    @State private var notificationRuleRevision = 0
    @State private var notificationAuthorization = NotificationAuthorizationState.unknown

    /// Identifiable wrapper so the confirmation presents via `.alert(item:)`.
    private struct RestartRequest: Identifiable { let id = UUID() }

    /// Names exactly what a relaunch costs. Terminals are called out as safe
    /// because they genuinely are — they live in the detached broker and resume
    /// from their byte cursor — and saying so is what makes the prompt
    /// answerable rather than alarming.
    private var restartWarning: String {
        let running = interruptibleTurnCount?() ?? 0
        let terminals = "Terminal sessions keep running in the background."
        guard running > 0 else { return terminals }
        let subject = running == 1 ? "1 chat or Mesh column is" : "\(running) chats or Mesh columns are"
        return "\(subject) mid-turn and will be interrupted. \(terminals)"
    }

    private var softwareUpdateDetail: String {
        if let pending = updates.pendingUpdate {
            return "Kaisola \(pending.version) is downloaded and ready to install"
        }
        return updateDetail ?? "Sparkle preview channel"
    }
    /// The key window's active project (feeds workspace-scoped tabs like MCP).
    var workspace: URL?
    /// In-workspace presentation supplies a compact Done action. The standalone
    /// Command-comma window omits it and relies on normal window controls.
    var dismiss: (() -> Void)?
    /// Hosted visual QA may open one section directly. Normal presentations
    /// leave this nil and retain the user's interactive selection.
    var initialSectionID: String?
    /// Visual QA can reveal a control below a section's first viewport without
    /// changing where the production Settings window normally opens.
    var initialContentAnchorID: String?
    /// The delegate uses this to preserve the selected tab when a live project
    /// switch rebuilds workspace-scoped Settings content.
    var sectionChanged: ((String) -> Void)? = nil

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
        // Settings opens large.
        //
        // The old ideal was 810×540, which is where the wasted space came from:
        // a card list laid out for a window barely taller than three rows, so
        // Usage could show one account and part of the next. These fill a laptop
        // display without pinning a larger one, and the account grid spends the
        // extra width on columns rather than margins.
        .frame(
            minWidth: 820,
            idealWidth: 1_100,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 800,
            maxHeight: .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
        .kaisolaReduceMotionFallback()
        .alert(item: $restartRequest) { _ in
            // A warning, never a block: the user is allowed to restart over a
            // running turn if they want to.
            Alert(
                title: Text("Restart Kaisola to install?"),
                message: Text(restartWarning),
                primaryButton: .default(Text("Restart and Update")) {
                    UpdateCenter.shared.installAndRelaunch()
                },
                secondaryButton: .cancel(Text("Later"))
            )
        }
        .onAppear {
            notificationsEnabled = NotificationBridge.shared.enabled
            refreshNotificationAuthorization()
            if let initialSectionID,
               let section = SettingsSection(rawValue: initialSectionID) {
                selectedSection = section
            }
        }
        .task {
            let families = await Task.detached(priority: .utility) {
                TerminalFontOptions.availableMonospaceFamilies()
            }.value
            fontFamilies = families
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationAuthorization()
        }
        .onChange(of: selectedSection) { _, section in
            sectionChanged?(section.rawValue)
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
                        .accessibilityHidden(true)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        selectedSection == section ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
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
        case .companion: CompanionSettingsTab()
        case .guardrails: guardrails.scrollContentBackground(.hidden)
        case .mcp: McpSettingsTab(workspace: workspace).scrollContentBackground(.hidden)
        case .accounts: accounts.scrollContentBackground(.hidden)
        case .agents: agents.scrollContentBackground(.hidden)
        case .models: ApiKeysSettingsTab(settings: settings).scrollContentBackground(.hidden)
        case .shortcuts: CommandKeymapSettingsView()
        case .usage: UsageSettingsTab(workspace: workspace).scrollContentBackground(.hidden)
        case .updates: softwareUpdates.scrollContentBackground(.hidden)
        }
    }

    private var general: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard(title: "Kaisola Account", symbol: "person.crop.circle") {
                    AppAccountSettingsView(auth: auth)
                }

                SettingsCard(title: "Projects", symbol: "rectangle.3.group") {
                    SettingsRow(title: "Navigation", detail: "Project tree or horizontal tabs", symbol: "sidebar.left") {
                        Menu {
                            ForEach(NavigationLayout.allCases) { layout in
                                Button(layout.title) {
                                    runCommand(.navigationLayout(layout))
                                }
                            }
                        } label: { SettingsChoiceLabel(settings.navigationLayout.title) }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Project navigation")
                    }
                    SettingsDivider()
                    SettingsRow(title: "Appearance", detail: "Follow macOS or pin a theme", symbol: "circle.lefthalf.filled") {
                        Menu {
                            ForEach(AppearanceMode.allCases) { mode in
                                Button(mode.title) { runCommand(.appearance(mode)) }
                            }
                        } label: { SettingsChoiceLabel(settings.appearance.title) }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Appearance")
                    }
                    SettingsDivider()
                    SettingsRow(title: "Project glass", detail: "Translucent navigation surface", symbol: "sparkles.rectangle.stack") {
                        Menu {
                            ForEach(SidebarAppearance.allCases) { mode in
                                Button(mode.title) { settings.sidebarAppearance = mode }
                            }
                        } label: { SettingsChoiceLabel(settings.sidebarAppearance.title) }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Project glass")
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Glass shows",
                        detail: "Your desktop picture, or whatever is behind the window",
                        symbol: "photo.on.rectangle.angled"
                    ) {
                        Menu {
                            ForEach(GlassBackdropSource.allCases) { source in
                                Button(source.title) { settings.glassBackdropSource = source }
                            }
                        } label: { SettingsChoiceLabel(settings.glassBackdropSource.title) }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Glass source")
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Glass wallpaper",
                        detail: settings.glassWallpaper.isEmpty
                            ? "Follows the desktop"
                            : (settings.glassWallpaper as NSString).lastPathComponent,
                        symbol: "photo"
                    ) {
                        HStack(spacing: 8) {
                            if !settings.glassWallpaper.isEmpty {
                                Button("Clear") { settings.glassWallpaper = "" }
                                    .controlSize(.small)
                            }
                            Button(settings.glassWallpaper.isEmpty ? "Choose…" : "Change…") {
                                chooseGlassWallpaper()
                            }
                            .controlSize(.small)
                        }
                        .help("Pin a picture for the glass. A rotating desktop keeps rotating; the glass stops chasing it.")
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Glass clarity",
                        detail: "How much of the desktop comes through",
                        symbol: "drop.halffull"
                    ) {
                        Menu {
                            ForEach(GlassClarity.allCases) { clarity in
                                Button(clarity.title) { settings.glassClarity = clarity }
                            }
                        } label: { SettingsChoiceLabel(settings.glassClarity.title) }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Glass clarity")
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Glass blur",
                        detail: "How far the wallpaper is softened behind the glass",
                        symbol: "circle.hexagongrid"
                    ) {
                        Menu {
                            ForEach(GlassTexture.allCases) { texture in
                                Button(texture.title) { settings.glassTexture = texture }
                            }
                        } label: { SettingsChoiceLabel(settings.glassTexture.title) }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Glass blur")
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Glass colour",
                        detail: "How much of the wallpaper's colour the glass carries",
                        symbol: "paintpalette"
                    ) {
                        Menu {
                            ForEach(GlassColour.allCases) { colour in
                                Button(colour.title) { settings.glassColour = colour }
                            }
                        } label: { SettingsChoiceLabel(settings.glassColour.title) }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Glass colour")
                    }
                    SettingsDivider()
                    SettingsRow(title: "Canvas", detail: "Backdrop behind chats and tools", symbol: "square.on.square") {
                        Menu {
                            ForEach(WorkspaceBackdropMode.allCases) { mode in
                                Button(mode.title) { settings.workspaceBackdrop = mode }
                            }
                        } label: { SettingsChoiceLabel(settings.workspaceBackdrop.title) }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Canvas backdrop")
                    }
                }

                SettingsCard(title: "System", symbol: "macwindow") {
                    SettingsRow(title: "Native notifications", detail: nativeNotificationDetail, symbol: "bell.badge") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Toggle("", isOn: Binding(
                                get: { notificationsEnabled },
                                set: { setNotificationsEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Native notifications")
                            if notificationAuthorization == .denied {
                                Button("Open Settings", action: openNotificationSettings)
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                        }
                    }
                    if notificationsEnabled {
                        SettingsDivider()
                        // Per-event delivery: each needs-you group carries its
                        // own Never / background-only / Always rule, so a user
                        // can hear about permission asks everywhere while
                        // finished turns stay quiet — the ChatGPT-app pattern.
                        ForEach(NotificationBridge.RuleGroup.allCases) { group in
                            SettingsRow(
                                title: group.title,
                                detail: "System notification for this event",
                                symbol: "bell"
                            ) {
                                Menu {
                                    ForEach(NotificationBridge.Rule.allCases) { rule in
                                        Button(rule.title) {
                                            NotificationBridge.shared.setRule(rule, for: group)
                                            notificationRuleRevision += 1
                                        }
                                    }
                                } label: {
                                    SettingsChoiceLabel(NotificationBridge.shared.rule(for: group).title)
                                }
                                .menuIndicator(.hidden)
                                .accessibilityLabel("\(group.title) notifications")
                                .id(notificationRuleRevision)
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "External editor", detail: "Used by Shift-Command-O", symbol: "arrow.up.forward.app") {
                        TextField("System default", text: $settings.externalEditorApp)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, 10)
                            .frame(width: 190, height: 30)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("External editor")
                    }
                }
            }
            .padding(18)
        }
    }

    /// Updates get their own section rather than a footnote under General.
    ///
    /// They used to be three rows below the external-editor field, at the
    /// bottom of the longest card in Settings — reachable, but only if you
    /// already knew to scroll General looking for them. Whether the app you are
    /// running is the current one is not a General preference; it is its own
    /// question, and the first one people go to Settings to answer. Michael:
    /// "software updates should be easily accessible in settings."
    private var softwareUpdates: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard(title: "Software updates", symbol: "arrow.triangle.2.circlepath") {
                    SettingsRow(
                        title: "This copy of Kaisola",
                        detail: softwareUpdateDetail,
                        symbol: "app.badge.checkmark"
                    ) {
                        if updates.pendingUpdate != nil {
                            Button("Restart and Update") { restartRequest = RestartRequest() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        } else {
                            Button("Check Now") { checkForUpdates?() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(checkForUpdates == nil)
                        }
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Check for updates automatically",
                        detail: "Looks for a new version in the background",
                        symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates },
                            set: { updates.setAutomaticallyChecksForUpdates($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!updates.canConfigureUpdates)
                        .accessibilityLabel("Check for updates automatically")
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Download updates in the background",
                        detail: "Kaisola asks before restarting to install",
                        symbol: "arrow.down.circle"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { updates.automaticallyDownloadsUpdates },
                            set: { updates.setAutomaticallyDownloadsUpdates($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        // Sparkle refuses silent downloads for update kinds it
                        // insists on showing (a major upgrade, for instance).
                        .disabled(!updates.canConfigureUpdates
                                  || !updates.allowsAutomaticUpdates
                                  || !updates.automaticallyChecksForUpdates)
                        .accessibilityLabel("Download updates in the background")
                    }
                }
            }
            .padding(18)
        }
    }

    /// Pin a picture for the glass.
    ///
    /// macOS will not name the wallpaper of a rotating desktop — a shuffle
    /// records only its own name, and a dynamic desktop like Tahoe Day returns
    /// the same stand-in a shuffle does. Choosing a file answers the question
    /// the system refuses to, without a permission or a guess.
    private func chooseGlassWallpaper() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose the picture the glass should use."
        panel.prompt = "Use for Glass"
        // Where macOS keeps its own, so the desktop you are actually looking at
        // is a couple of clicks away rather than a path to remember.
        panel.directoryURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.glassWallpaper = url.path
    }

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                SettingsCard(title: "Typography", symbol: "textformat") {
                    SettingsRow(title: "Terminal.app defaults", detail: "11 pt regular, native colors and spacing", symbol: "macwindow") {
                        Button("Use Defaults") { settings.applyTerminalAppDefaults() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Font size", detail: "Command-plus / Command-minus", symbol: "textformat.size") {
                        Slider(
                            value: $settings.terminalFontSize,
                            in: NativePreviewSettings.terminalFontRange,
                            step: 1
                        )
                        .frame(width: 140)
                        .accessibilityLabel("Font size")
                        .accessibilityValue("\(Int(settings.terminalFontSize)) points")
                        Text("\(Int(settings.terminalFontSize))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Line spacing", detail: "Terminal row height", symbol: "text.line.first.and.arrowtriangle.forward") {
                        Slider(
                            value: $settings.terminalLineSpacing,
                            in: NativePreviewSettings.terminalLineSpacingRange,
                            step: 0.02
                        )
                        .frame(width: 140)
                        .accessibilityLabel("Line spacing")
                        .accessibilityValue(String(format: "%.2f times", settings.terminalLineSpacing))
                        Text(String(format: "%.2f×", settings.terminalLineSpacing))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Scrollback",
                        detail: "Live rows; keep scrolling for the full transcript",
                        symbol: "arrow.up.and.down.text.horizontal"
                    ) {
                        Stepper(
                            value: $settings.terminalScrollbackLines,
                            in: NativePreviewSettings.terminalScrollbackRange,
                            step: 5_000
                        ) {
                            Text(settings.terminalScrollbackLines.formatted(.number.grouping(.automatic)))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .accessibilityLabel("Terminal scrollback")
                        .accessibilityValue(
                            "\(settings.terminalScrollbackLines.formatted(.number.grouping(.automatic))) lines"
                        )
                    }
                    SettingsDivider()
                    SettingsRow(title: "Typeface", detail: "Monospaced fonts only", symbol: "character.cursor.ibeam") {
                        Menu {
                            ForEach(fontFamilies, id: \.self) { family in
                                Button(family) { settings.terminalFontFamily = family }
                            }
                        } label: { SettingsChoiceLabel(settings.terminalFontFamily) }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Typeface")
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
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Font weight")
                    }
                }

                TerminalColorCard(settings: settings)

                SettingsCard(title: "History Storage", symbol: "externaldrive") {
                    SettingsRow(
                        title: "Disk warning",
                        detail: "Per terminal · never deletes output automatically",
                        symbol: "externaldrive.badge.exclamationmark"
                    ) {
                        Menu {
                            ForEach(NativePreviewSettings.terminalHistoryWarningChoicesMiB, id: \.self) { mib in
                                Button(TerminalHistoryStoragePolicy.budgetLabel(mib)) {
                                    settings.terminalHistoryWarningMiB = mib
                                }
                            }
                        } label: {
                            SettingsChoiceLabel(TerminalHistoryStoragePolicy.budgetLabel(settings.terminalHistoryWarningMiB))
                        }
                        .menuIndicator(.hidden)
                        .accessibilityLabel("Terminal history disk warning")
                        .accessibilityValue(TerminalHistoryStoragePolicy.budgetLabel(settings.terminalHistoryWarningMiB))
                    }
                    Text("Full terminal output stays append-only until you close that terminal. This threshold warns; changing it never removes history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
                .id("terminal-history")

                    SettingsCard(title: "Interaction", symbol: "keyboard") {
                        SettingsRow(
                            title: "Restore CLI drafts",
                            detail: "Retype unsent text after a resumed agent becomes quiet",
                            symbol: "text.cursor"
                        ) {
                            Toggle("", isOn: $settings.restoreCLIDrafts)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel("Restore CLI drafts")
                        }
                        SettingsRow(
                            title: "Semantic shell commands",
                            detail: "Experimental · adds command navigation to new zsh, Bash, and Fish terminals",
                            symbol: "arrow.up.arrow.down"
                        ) {
                            Toggle("", isOn: $settings.semanticShellIntegration)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel("Semantic shell commands")
                        }
                        SettingsRow(
                            title: "Allow terminal applications to write the clipboard",
                            detail: "Off by default · anything running in a terminal, local or remote, can replace what you paste next",
                            symbol: "doc.on.clipboard"
                        ) {
                            Toggle("", isOn: $settings.terminalClipboardWriteAllowed)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .accessibilityLabel("Allow terminal applications to write the clipboard")
                        }
                        Text("Terminal applications can never read your clipboard; Kaisola refuses those requests whether or not this is on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    }
                    .id("terminal-interaction")
                }
                .padding(18)
            }
            .onAppear {
                guard let initialContentAnchorID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(initialContentAnchorID, anchor: .bottom)
                }
            }
        }
    }

    private var guardrails: some View {
        GuardrailsSettings(settings: settings)
    }

    private var nativeNotificationDetail: String {
        switch notificationAuthorization {
        case .denied: "Blocked by macOS; enable notifications in System Settings"
        case .notDetermined: "macOS permission has not been granted yet"
        case .allowed: "Alert when an agent needs you"
        case .unknown: "Alert when an agent needs you"
        }
    }

    private func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        NotificationBridge.shared.enabled = enabled
        guard enabled else { return }
        NotificationBridge.shared.requestAuthorizationIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            refreshNotificationAuthorization()
        }
    }

    /// Always goes through `NotificationBridge`, never `UNUserNotificationCenter`
    /// directly: the bridge owns the single guard that keeps unbundled, XCTest,
    /// and headless visual-fixture processes from touching the notification
    /// daemon at all. Mounting Settings must stay safe in every one of them.
    private func refreshNotificationAuthorization() {
        Task {
            let state = await NotificationBridge.shared.authorizationState()
            guard !Task.isCancelled else { return }
            notificationAuthorization = state
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var accounts: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsCard(title: "App default account", symbol: "person.crop.circle") {
                    SettingsRow(
                        title: "Claude",
                        detail: "CLAUDE_CONFIG_DIR for new sessions",
                        symbol: "folder"
                    ) {
                        TextField("", text: $settings.claudeConfigDir, prompt: Text("CLI default"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 10)
                            .frame(width: 230, height: 30)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Default Claude account directory")
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Codex",
                        detail: "CODEX_HOME for new sessions",
                        symbol: "folder"
                    ) {
                        TextField("", text: $settings.codexHome, prompt: Text("CLI default"))
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 10)
                            .frame(width: 230, height: 30)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Default Codex account directory")
                    }
                }
                ProjectAccountsSection(
                    projectID: workspace.map { NativeSessionStore.projectID(forDirectory: $0.path) },
                    projectName: workspace.map { ($0.path as NSString).lastPathComponent }
                )
            }
            .padding(18)
        }
    }

    private var agents: some View {
        Form {
            CustomAgentsSection()
            Section("ACP Adapters") {
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

    private func runCommand(_ id: AppCommandID) {
        _ = AppCommandRegistry.execute(
            id,
            in: AppCommandContext(model: nil, settings: settings)
        )
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, terminal, companion, guardrails, mcp, accounts, agents, models, shortcuts, usage, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .companion: "Companion"
        case .guardrails: "Guardrails"
        case .mcp: "MCP"
        case .accounts: "Accounts"
        case .agents: "Agents"
        case .models: "Models & Keys"
        case .shortcuts: "Keyboard"
        case .usage: "Usage"
        case .updates: "Updates"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Project behavior and appearance"
        case .terminal: "Typography, palette, and interaction"
        case .companion: "Pair nearby devices and stay connected anywhere"
        case .guardrails: "Standing rules and sensitive files"
        case .mcp: "Project tool servers"
        case .accounts: "Sign-ins, named accounts, and project overrides"
        case .agents: "Custom agents and ACP adapters"
        case .models: "Provider credentials, models, and routing"
        case .shortcuts: "Shortcuts and keymap.json overrides"
        case .usage: "Provider limits and live context"
        case .updates: "Version, automatic checks, and downloads"
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .terminal: "terminal"
        case .companion: "iphone.and.arrow.forward"
        case .guardrails: "shield.lefthalf.filled"
        case .mcp: "puzzlepiece.extension"
        case .accounts: "person.crop.circle"
        case .agents: "sparkles"
        case .models: "key"
        case .shortcuts: "keyboard"
        case .usage: "gauge.with.dots.needle.bottom.50percent"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

struct SettingsCard<Content: View>: View {
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

struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
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

struct SettingsDivider: View {
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

/// The Color card: theme picker over the registry, a live preview drawn from
/// the selected theme's own palette, and the custom-theme roster — import,
/// remove, and an explanation line for any theme that cannot install (PR 6's
/// disabled-with-a-reason contract).
private struct TerminalColorCard: View {
    @ObservedObject var settings: NativePreviewSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var customSpecs: [CustomThemeSpec] = []
    private let store = CustomThemeStore()

    var body: some View {
        SettingsCard(title: "Color", symbol: "paintpalette") {
            SettingsRow(title: "Terminal theme", detail: "Opaque for reliable contrast", symbol: "circle.hexagongrid") {
                Menu {
                    ForEach(TerminalThemeRegistry.shipped) { definition in
                        Button(definition.title) { settings.terminalThemeID = definition.id }
                    }
                    let installable = customSpecs.compactMap { $0.asDefinition() }
                    if !installable.isEmpty {
                        Divider()
                        ForEach(installable) { definition in
                            Button(definition.title) { settings.terminalThemeID = definition.id }
                        }
                    }
                } label: {
                    SettingsChoiceLabel(
                        TerminalThemeRegistry.definition(id: settings.terminalThemeID, store: store).title
                    )
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("Terminal theme")
            }
            TerminalPalettePreview(
                definition: TerminalThemeRegistry.definition(id: settings.terminalThemeID, store: store),
                light: colorScheme == .light
            )
                .padding(.horizontal, 16)
                .padding(.bottom, customSpecs.isEmpty ? 14 : 6)
            customThemeRoster
        }
        .onAppear { customSpecs = store.specs() }
    }

    @ViewBuilder
    private var customThemeRoster: some View {
        ForEach(customSpecs) { spec in
            HStack(spacing: 8) {
                if let reason = spec.validationError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(spec.title.isEmpty ? spec.id : spec.title)
                            .foregroundStyle(.secondary)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "paintpalette")
                        .foregroundStyle(.secondary)
                    Text(spec.title)
                }
                Spacer()
                Button("Remove") {
                    store.remove(id: spec.id)
                    customSpecs = store.specs()
                    // Removing the selected theme falls back at resolve time;
                    // the stored choice is left alone so re-importing the
                    // theme restores it.
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 3)
        }
        HStack {
            Button {
                importCustomTheme()
            } label: {
                Label("Import Theme…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.link)
            .help("A JSON file with id, title, and light/dark palettes (hex colors, 16 ANSI slots)")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private func importCustomTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import Theme"
        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else { return }
            Task { @MainActor in
                guard let data = try? Data(contentsOf: url),
                      let spec = try? JSONDecoder().decode(CustomThemeSpec.self, from: data) else {
                    ToastCenter.shared.show(
                        "That file is not a theme: it must be JSON with id, title, and light/dark palettes.",
                        style: .error,
                        duration: 5
                    )
                    return
                }
                if let reason = store.upsert(spec) {
                    ToastCenter.shared.show(
                        "Imported, but it cannot be used yet: \(reason)",
                        style: .info,
                        duration: 6
                    )
                } else {
                    settings.terminalThemeID = spec.id
                    ToastCenter.shared.show("Imported \(spec.title) and switched to it", style: .success)
                }
                customSpecs = store.specs()
            }
        }
    }
}

private struct TerminalPalettePreview: View {
    let definition: ThemeDefinition
    let light: Bool
    var body: some View {
        let palette = light ? definition.light : definition.dark
        HStack(spacing: 10) {
            Text("~/Kaisola")
                .foregroundStyle(Color(nsColor: palette.foreground).opacity(0.65))
            Text("%")
                .foregroundStyle(Color(nsColor: palette.ansiColor(2)))
            Text("codex")
                .foregroundStyle(Color(nsColor: palette.ansiColor(4)))
            Rectangle()
                .fill(Color(nsColor: palette.cursor))
                .frame(width: 7, height: 15)
            Spacer()
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(Color(nsColor: palette.background), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
        .accessibilityHidden(true)
    }

}

enum SensitiveGlobPolicy {
    static func validationMessage(_ rawValue: String, existing: [String]) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count > 512 {
            return "Patterns must be 512 characters or fewer."
        }
        if value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "Patterns cannot contain control characters."
        }
        if value.rangeOfCharacter(from: CharacterSet(charactersIn: "?[]{}")) != nil {
            return "Only * and ** wildcards are supported; ?, brackets, and braces are not."
        }
        if value.allSatisfy({ $0 == "*" || $0 == "/" }) {
            return "Name at least part of a sensitive file; a wildcard-only pattern is too broad."
        }
        if existing.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            return "That sensitive-file pattern already exists."
        }
        return nil
    }
}

/// Guardrails tab: standing permission rules (delete) + sensitive globs (edit).
private struct GuardrailsSettings: View {
    @ObservedObject var settings: NativePreviewSettings
    @State private var rules: [PermissionRule] = []
    @State private var newGlob = ""
    @State private var showsRestoreDefaultsConfirmation = false
    private let store = PermissionRuleStore()

    var body: some View {
        Form {
            Section("Standing Allow Rules") {
                if rules.isEmpty {
                    Text("No rules yet — \"Always Allow\" on a permission ask creates one.")
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
                        .accessibilityLabel("Delete allow-rule \(AcpPermissionRules.ruleLabel(action: rule.action, resource: rule.resource))")
                    }
                }
            }
            Section("Sensitive Files (Always Ask, Never Rule-Covered)") {
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
                        .accessibilityLabel("Remove sensitive file pattern \(glob)")
                    }
                }
                HStack {
                    TextField("Add glob (e.g. **/*.p12)", text: $newGlob)
                        .onSubmit(addGlob)
                    Button("Add", action: addGlob)
                        .disabled(!canAddGlob)
                }
                if let issue = newGlobIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                }
                Button("Restore Defaults") { showsRestoreDefaultsConfirmation = true }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding(6)
        .onAppear { rules = store.rules() }
        .confirmationDialog(
            "Restore Default Sensitive-File Patterns?",
            isPresented: $showsRestoreDefaultsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                settings.sensitiveGlobs = AcpPermissionRules.defaultSensitiveGlobs
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces every custom sensitive-file pattern with Kaisola's defaults.")
        }
    }

    private var newGlobIssue: String? {
        SensitiveGlobPolicy.validationMessage(newGlob, existing: settings.sensitiveGlobs)
    }

    private var canAddGlob: Bool {
        !newGlob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && newGlobIssue == nil
    }

    private func addGlob() {
        let trimmed = newGlob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              SensitiveGlobPolicy.validationMessage(trimmed, existing: settings.sensitiveGlobs) == nil else {
            return
        }
        settings.sensitiveGlobs.append(trimmed)
        newGlob = ""
    }
}
