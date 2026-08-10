import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Bridges the in-workspace settings sheet to the delegate-owned Sparkle
    /// controller without coupling the SwiftUI shell to update infrastructure.
    static let kaisolaCheckForUpdates = Notification.Name("kaisolaCheckForUpdates")
}

/// What the Settings window owes AppKit: the style mask, the sizes it opens at,
/// and the band of the content view the three standard window buttons live in.
///
/// Settings draws a full-size content view under a hidden, transparent title
/// bar, so nothing but this type keeps custom content off the traffic lights.
/// Nothing did: the 30pt Settings mark was drawn straight over the minimize and
/// zoom controls, on every tab and in both appearances, and the window was not
/// even `.miniaturizable`, so the control it buried would have done nothing if
/// you had found it (#306).
///
/// The numbers the navigation column lays out with live here rather than inline
/// in the view, so `NativeVisualWindowControlGate` and its tests measure the
/// shipped layout instead of a copy of it.
enum SettingsWindowChrome {
    /// `.miniaturizable` is not decoration. AppKit draws the yellow control for
    /// any titled window and simply refuses to run it when the mask omits it.
    static let styleMask: NSWindow.StyleMask = [
        .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
    ]

    /// SettingsView's own frame contract, stated once so the ⌘, window, the
    /// visual fixtures, and the tests cannot drift from it.
    static let minimumContentSize = NSSize(width: 820, height: 560)
    static let idealContentSize = NSSize(width: 1_100, height: 800)

    /// The top band of the content view that belongs to AppKit.
    ///
    /// A standard title bar centres the three buttons in it, so reserving the
    /// whole band clears every button *and* leaves the drag and
    /// double-click-to-zoom region AppKit runs there empty. The bar is 28pt on
    /// macOS 14–15 and 32 on macOS 26, which is why
    /// `testSettingsReservesTheTitleBarBandAppKitOwns` measures a real window's
    /// `contentLayoutRect` instead of trusting this literal: 28 passed every
    /// review and failed that test on the first run.
    ///
    /// A sheet presentation reserves nothing. It has no window buttons and
    /// carries its own Done action.
    static let titleBarSafeArea: CGFloat = 32

    static let navigationColumnWidth: CGFloat = 176
    static let navigationOuterPadding: CGFloat = 8
    static let navigationContentPadding: CGFloat = 14
    static let navigationVerticalPadding: CGFloat = 14
    static let identityMarkSize: CGFloat = 30

    /// The Settings mark's frame in window points measured from the *top-left*
    /// corner of the content view — the corner the traffic lights sit in.
    ///
    /// Parameterised on the reserved band so a test can ask what the pre-fix
    /// layout did (pass 0) and what the shipped one does.
    static func identityMarkFrame(titleBarSafeArea: CGFloat = titleBarSafeArea) -> CGRect {
        CGRect(
            x: navigationOuterPadding + navigationContentPadding,
            y: titleBarSafeArea + navigationVerticalPadding,
            width: identityMarkSize,
            height: identityMarkSize
        )
    }

    /// The visual-fixture surfaces that open Settings instead of the workspace
    /// shell. Stated once because the app delegate asks twice: to build the
    /// content and to size the window.
    ///
    /// `settings-minimum` and `settings-ideal` are the two ends of the size
    /// contract above. Both open the General tab, which is where the mark that
    /// used to cover the traffic lights lives.
    static let visualSurfaces: Set<String> = [
        "settings",
        "settings-minimum",
        "settings-ideal",
        "settings-terminal",
        "settings-terminal-history",
        "settings-terminal-interaction",
        "settings-companion",
        "settings-mcp",
        "settings-extensions",
        "settings-extensions-narrow",
        "settings-accounts",
        "settings-models",
        "settings-shortcuts",
        "settings-account-recovery",
        "usage",
    ]

    /// What a fixture surface opens at. Every surface except `settings-ideal`
    /// captures the *minimum* window, which is the size the chrome is tightest
    /// at — and which the old 810×540 fixture sat below, so CI was inspecting a
    /// window the product cannot actually be resized to.
    static func visualContentSize(surface: String) -> NSSize {
        ["settings-ideal", "settings-extensions"].contains(surface)
            ? idealContentSize
            : minimumContentSize
    }

    /// Custom content the layout can name outright in the traffic-light corner.
    /// The gate walks the accessibility tree for everything it cannot know
    /// about; these are the rects the view declares.
    static func topLeadingContentFrames(
        titleBarSafeArea: CGFloat = titleBarSafeArea
    ) -> [(name: String, frame: CGRect)] {
        [(
            name: "settings-identity-mark",
            frame: identityMarkFrame(titleBarSafeArea: titleBarSafeArea)
        )]
    }
}

enum SettingsSidebarLayoutPolicy {
    /// A full-size-content window lets its sidebar paint beneath the titlebar.
    /// At the minimum Settings width AppKit stops reserving the titlebar inset,
    /// so the decorative brand would otherwise sit underneath the traffic
    /// lights. Keep the same vertical rhythm, but leave that compact titlebar
    /// region visually clear.
    static func showsBrand(contentWidth: CGFloat) -> Bool {
        contentWidth >= 900
    }
}

/// The native Settings window (⌘,): workspace, terminal, Companion, and tools.
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthModel
    @ObservedObject var settings: NativePreviewSettings
    /// Monospace families are enumerated once — probing every installed font
    /// per body evaluation is too slow.
    @State private var fontFamilies = [TerminalFontOptions.systemMonoSentinel]
    @State private var selectedSection: SettingsSection = .general
    @State private var settingsSearchQuery = ""
    @State private var extensionsRoute: ExtensionsSettingsRoute?
    @FocusState private var settingsSearchFocused: Bool
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
    @State private var externalEditorFeedback: String?

    /// Identifiable wrapper so the confirmation presents via `.alert(item:)`.
    private struct RestartRequest: Identifiable { let id = UUID() }

    enum SoftwareUpdateActionPresentation: Equatable {
        case restart
        case installing
        case checking
        case check(SoftwareUpdateCheckAvailability)

        static let installingAccessibilityLabel = "Installing update and restarting Kaisola"

        var checkAvailability: SoftwareUpdateCheckAvailability? {
            guard case .check(let availability) = self else { return nil }
            return availability
        }

        static func resolve(
            canInstall: Bool,
            isInstalling: Bool,
            isChecking: Bool,
            canCheck: Bool,
            sparkleIsPresenting: Bool
        ) -> SoftwareUpdateActionPresentation {
            // Installing wins even if an inconsistent caller also claims the
            // ready action is available: fail closed against a second invocation.
            if isInstalling { return .installing }
            if canInstall { return .restart }
            if isChecking { return .checking }
            if sparkleIsPresenting { return .check(.updateWindowOpen) }
            if !canCheck { return .check(.unavailable) }
            return .check(.ready)
        }
    }

    enum SoftwareUpdateCheckAvailability: Equatable {
        case ready
        case unavailable
        case updateWindowOpen

        var isEnabled: Bool { self == .ready }

        var visibleTitle: String {
            switch self {
            case .ready: "Check Now"
            case .unavailable: "Unavailable"
            case .updateWindowOpen: "Update Window Open"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .ready: "Check for updates now"
            case .unavailable: "Check for updates unavailable"
            case .updateWindowOpen: "Update window already open"
            }
        }

        var accessibilityHint: String {
            switch self {
            case .ready: "Opens Kaisola's update checker."
            case .unavailable: "This build does not include an update checker."
            case .updateWindowOpen:
                "Finish or close the existing update window before checking again."
            }
        }
    }

    enum SoftwareUpdateDownloadAvailability: Equatable {
        case ready
        case updaterUnavailable
        case interactiveUpdateRequired
        case automaticChecksRequired

        static func resolve(
            canConfigureUpdates: Bool,
            allowsAutomaticUpdates: Bool,
            automaticallyChecksForUpdates: Bool
        ) -> SoftwareUpdateDownloadAvailability {
            if !canConfigureUpdates { return .updaterUnavailable }
            if !allowsAutomaticUpdates { return .interactiveUpdateRequired }
            if !automaticallyChecksForUpdates { return .automaticChecksRequired }
            return .ready
        }

        var isEnabled: Bool { self == .ready }

        var visibleDetail: String {
            switch self {
            case .ready:
                "Kaisola asks before restarting to install"
            case .updaterUnavailable:
                "Unavailable because this build cannot configure automatic updates"
            case .interactiveUpdateRequired:
                "This update type must be downloaded interactively"
            case .automaticChecksRequired:
                "Turn on automatic checks first"
            }
        }

        var accessibilityHint: String {
            switch self {
            case .ready:
                "Downloads updates in the background. Kaisola asks before restarting to install."
            case .updaterUnavailable:
                "Background downloads are unavailable because this build cannot configure automatic updates."
            case .interactiveUpdateRequired:
                "Background downloads are unavailable because this update type requires an interactive download."
            case .automaticChecksRequired:
                "Enable Check for updates automatically before enabling background downloads."
            }
        }
    }

    private struct SoftwareUpdateInstallingIndicator: View {
        var body: some View {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Restarting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SoftwareUpdateActionPresentation.installingAccessibilityLabel)
        }
    }

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

    /// The row always answers "what am I running, and when did we last look?"
    /// (2026-08-06 spec §3d) — the one question the old row never answered.
    private var softwareUpdateDetail: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        if let pending = updates.pendingUpdate {
            switch pending.phase {
            case .ready:
                return "Kaisola \(version) — \(pending.version) is downloaded and ready to install"
            case .installing:
                return "Kaisola \(version) — installing \(pending.version) and restarting…"
            }
        }
        if let updateDetail {
            // An unavailable updater states its reason, not a channel name.
            return "Kaisola \(version) — \(updateDetail)"
        }
        switch updates.checkStatus {
        case .checking:
            return "Kaisola \(version) — checking for updates…"
        case .upToDate(let at):
            return "Kaisola \(version) — up to date (checked \(Self.relative(at)))"
        case .failed(let reason, let at):
            return "Kaisola \(version) — check failed \(Self.relative(at)): \(reason)"
        case .idle(let lastChecked):
            if let lastChecked {
                return "Kaisola \(version) — last checked \(Self.relative(lastChecked))"
            }
            return "Kaisola \(version)"
        }
    }

    private var softwareUpdateActionPresentation: SoftwareUpdateActionPresentation {
        SoftwareUpdateActionPresentation.resolve(
            canInstall: updates.canInstallPendingUpdate,
            isInstalling: updates.isInstallingUpdate,
            isChecking: {
                if case .checking = updates.checkStatus { return true }
                return false
            }(),
            canCheck: checkForUpdates != nil,
            sparkleIsPresenting: updates.sparkleIsPresentingUpdate
        )
    }

    private var softwareUpdateDownloadAvailability: SoftwareUpdateDownloadAvailability {
        SoftwareUpdateDownloadAvailability.resolve(
            canConfigureUpdates: updates.canConfigureUpdates,
            allowsAutomaticUpdates: updates.allowsAutomaticUpdates,
            automaticallyChecksForUpdates: updates.automaticallyChecksForUpdates
        )
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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

    /// The window presentation hands its title-bar band back to AppKit. The
    /// in-workspace sheet has no window buttons to clear and would only be
    /// paying for an empty strip.
    private var titleBarSafeArea: CGFloat {
        dismiss == nil ? SettingsWindowChrome.titleBarSafeArea : 0
    }

    private var settingsSearchResults: [SettingsSection] {
        SettingsCatalogSearch.matches(query: settingsSearchQuery)
    }

    private var externalEditorDetail: String {
        externalEditorFeedback ?? settings.externalEditorResolution.detail
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                settingsNavigation(
                    showsBrand: SettingsSidebarLayoutPolicy.showsBrand(
                        contentWidth: geometry.size.width
                    )
                )
                Divider()
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedSection.title)
                                .font(.title3.weight(.semibold))
                            Text(selectedSection.subtitle)
                                .font(.caption)
                                .foregroundStyle(.kaisolaSecondary)
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
            // The detail column starts below the title bar for the same reason
            // the navigation column does: everything above this line is the
            // band AppKit drags and double-click-zooms the window by.
            .padding(.top, titleBarSafeArea)
        }
        // Settings opens large.
        //
        // The old ideal was 810×540, which is where the wasted space came from:
        // a card list laid out for a window barely taller than three rows, so
        // Usage could show one account and part of the next. These fill a laptop
        // display without pinning a larger one, and the account grid spends the
        // extra width on columns rather than margins.
        .frame(
            minWidth: SettingsWindowChrome.minimumContentSize.width,
            idealWidth: SettingsWindowChrome.idealContentSize.width,
            maxWidth: .infinity,
            minHeight: SettingsWindowChrome.minimumContentSize.height,
            idealHeight: SettingsWindowChrome.idealContentSize.height,
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
                    restartRequest = nil
                    UpdateCenter.shared.installAndRelaunch()
                },
                secondaryButton: .cancel(Text("Later"))
            )
        }
        .onAppear {
            notificationsEnabled = NotificationBridge.shared.enabled
            refreshNotificationAuthorization()
            if let route = ExtensionsSettingsRoute.parse(initialSectionID) {
                extensionsRoute = route
                selectedSection = .extensions
            } else if let initialSectionID,
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
        .onChange(of: updates.canInstallPendingUpdate) { _, canInstall in
            // `UpdateCenter` is app-global: if another window starts the
            // install, dismiss this window's now-stale confirmation too.
            if !canInstall { restartRequest = nil }
        }
    }

    private func settingsNavigation(showsBrand: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if showsBrand {
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
                } else {
                    Color.clear
                        .frame(height: SettingsWindowChrome.identityMarkSize)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SettingsWindowChrome.navigationContentPadding)
            .padding(.bottom, 16)
            // A mark and the window's own name: nothing here answers a click.
            // Saying so keeps this row from claiming one near the controls even
            // if it ever drifts back up the column.
            .allowsHitTesting(false)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.kaisolaTertiary)
                    .accessibilityHidden(true)
                TextField("Search Settings", text: $settingsSearchQuery)
                    .textFieldStyle(.plain)
                    .focused($settingsSearchFocused)
                    .onSubmit {
                        if let first = settingsSearchResults.first {
                            selectedSection = first
                        }
                    }
                    .accessibilityLabel("Search settings")
                    .accessibilityValue(SettingsCatalogSearch.accessibilityValue(
                        query: settingsSearchQuery,
                        resultCount: settingsSearchResults.count
                    ))
                    .accessibilityIdentifier(SettingsCatalogSearch.fieldIdentifier)
                if SettingsCatalogSearch.isFiltering(settingsSearchQuery) {
                    Button {
                        settingsSearchQuery = ""
                        settingsSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.kaisolaTertiary)
                    .accessibilityLabel("Clear Settings search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, SettingsWindowChrome.navigationContentPadding)
            .padding(.bottom, 8)

            // Grouped clusters (spec §3a): quiet headers, eleven sections in
            // four families instead of one flat run.
            //
            // Eleven 34pt rows and their headers want about 600pt; the window's
            // own minimum is 560, and the reserved title-bar band takes 32 of
            // those. The run scrolls rather than being clipped, so every section
            // stays reachable at the minimum size — the column overflowed even
            // before the band was reserved. It carries no indicator at rest and
            // does not bounce when the list already fits.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    if SettingsCatalogSearch.isFiltering(settingsSearchQuery) {
                        Text(SettingsCatalogSearch.resultCountLabel(settingsSearchResults.count))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.kaisolaTertiary)
                            .padding(.horizontal, SettingsWindowChrome.navigationContentPadding)
                            .accessibilityLabel(
                                "Settings search, \(SettingsCatalogSearch.resultCountLabel(settingsSearchResults.count))"
                            )
                            .accessibilityIdentifier(SettingsCatalogSearch.resultCountIdentifier)
                        if settingsSearchResults.isEmpty {
                            Text("No settings match this search.")
                                .font(.caption)
                                .foregroundStyle(.kaisolaSecondary)
                                .padding(.horizontal, SettingsWindowChrome.navigationContentPadding)
                                .padding(.top, 4)
                                .accessibilityIdentifier(SettingsCatalogSearch.emptyStateIdentifier)
                        } else {
                            ForEach(settingsSearchResults) { section in
                                sectionButton(section)
                            }
                        }
                    } else {
                        ForEach(SettingsGroup.allCases) { group in
                            Text(group.title.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.kaisolaTertiary)
                                .padding(.horizontal, SettingsWindowChrome.navigationContentPadding)
                                .padding(.top, group == SettingsGroup.allCases.first ? 0 : 10)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.sections) { section in
                                sectionButton(section)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            Text("Changes apply instantly")
                .font(.caption2)
                .foregroundStyle(.kaisolaTertiary)
                .padding(.horizontal, SettingsWindowChrome.navigationContentPadding)
        }
        // The sidebar material still runs to the window's top edge; only its
        // content starts below the traffic lights. The mark used to sit 14pt
        // down, which put it on top of the minimize and zoom buttons.
        .padding(.top, titleBarSafeArea + SettingsWindowChrome.navigationVerticalPadding)
        .padding(.bottom, SettingsWindowChrome.navigationVerticalPadding)
        .padding(.horizontal, SettingsWindowChrome.navigationOuterPadding)
        .frame(width: SettingsWindowChrome.navigationColumnWidth)
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

    private func sectionButton(_ section: SettingsSection) -> some View {
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
            .foregroundStyle(selectedSection == section ? Color.primary : .kaisolaSecondary)
            .padding(.horizontal, 11)
            .frame(height: 34)
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

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSection {
        case .general: general
        case .terminal: terminal
        case .companion: CompanionSettingsTab()
        case .guardrails: guardrails.scrollContentBackground(.hidden)
        case .extensions:
            ExtensionsSettingsHub(
                settings: settings,
                workspace: workspace,
                initialRoute: extensionsRoute,
                routeChanged: { route in sectionChanged?(route) }
            )
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
                    SettingsRow(
                        title: "Summon with \(GlobalHotkeyCenter.comboDisplay)",
                        detail: "Bring Kaisola forward from any app, into the last chat",
                        symbol: "keyboard"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { settings.summonHotkeyEnabled },
                            set: { enabled in
                                settings.summonHotkeyEnabled = enabled
                                GlobalHotkeyCenter.shared.setEnabled(enabled)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Summon hotkey")
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "External editor",
                        detail: externalEditorDetail,
                        symbol: "arrow.up.forward.app"
                    ) {
                        VStack(alignment: .trailing, spacing: 6) {
                            Menu {
                                Button("System Default") {
                                    settings.useSystemDefaultExternalEditor()
                                    externalEditorFeedback = nil
                                }
                                Divider()
                                Button("Choose Application…") { chooseExternalEditor() }
                            } label: {
                                ExternalEditorChoiceLabel(resolution: settings.externalEditorResolution)
                            }
                            .menuIndicator(.hidden)
                            .accessibilityLabel("External editor application")

                            Button("Test Open") {
                                externalEditorFeedback = settings.testExternalEditor()
                                    ? "Sent a safe test file to \(settings.externalEditorResolution.displayName)"
                                    : "The external editor could not open the safe test file"
                            }
                            .controlSize(.small)
                            .disabled(!settings.externalEditorResolution.isAvailable)
                            .accessibilityHint("Opens a generated file containing no project or account data")
                        }
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
                        switch softwareUpdateActionPresentation {
                        case .restart:
                            Button("Restart and Update") { restartRequest = RestartRequest() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        case .installing:
                            SoftwareUpdateInstallingIndicator()
                        case .checking:
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Checking for updates")
                        case .check(let availability):
                            // Steps aside while Sparkle's own window is up so
                            // the two UIs never fight over one check.
                            Button(availability.visibleTitle) {
                                guard availability.isEnabled else { return }
                                checkForUpdates?()
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!availability.isEnabled)
                                .accessibilityLabel(availability.accessibilityLabel)
                                .accessibilityHint(availability.accessibilityHint)
                                .help(availability.accessibilityHint)
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
                        detail: softwareUpdateDownloadAvailability.visibleDetail,
                        symbol: "arrow.down.circle"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { updates.automaticallyDownloadsUpdates },
                            set: { updates.setAutomaticallyDownloadsUpdates($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!softwareUpdateDownloadAvailability.isEnabled)
                        .accessibilityLabel("Download updates in the background")
                        .accessibilityHint(softwareUpdateDownloadAvailability.accessibilityHint)
                        .help(softwareUpdateDownloadAvailability.accessibilityHint)
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

    private func chooseExternalEditor() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.message = "Choose the application Shift-Command-O should use."
        panel.prompt = "Use Application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        externalEditorFeedback = settings.selectExternalEditor(at: url)
            ? nil
            : "That item is not a resolvable macOS application"
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
                            .foregroundStyle(.kaisolaSecondary)
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
                            .foregroundStyle(.kaisolaSecondary)
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
                                .foregroundStyle(.kaisolaSecondary)
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
                        .foregroundStyle(.kaisolaSecondary)
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
                            .foregroundStyle(.kaisolaSecondary)
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
                    projectName: workspace.map { ($0.path as NSString).lastPathComponent },
                    workspace: workspace
                )
            }
            .padding(18)
        }
    }

    private var agents: some View {
        Form {
            AgentRunProfilesSection(workspace: workspace)
            Section("Built-in ACP Adapters") {
                ForEach(AgentRegistry.all) { agent in
                    if let adapter = AcpAdapter.forAgent(agent.id) {
                        LabeledContent(agent.name) {
                            Text(([adapter.command] + adapter.arguments).joined(separator: " "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.kaisolaSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Text("Built-in adapters resolve @latest. Custom adapters are pinned and launch only through their reviewed containment grant.")
                    .font(.caption).foregroundStyle(.kaisolaSecondary)
            }
            Section("Extension Management") {
                Text("Custom agents and project MCP servers now live with themes, grammars, and preview mappings in Extensions.")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
                HStack {
                    Button("Manage Custom Agents…") {
                        NSApp.sendAction(
                            #selector(KaisolaMacAppDelegate.openAgentSettings(_:)),
                            to: nil,
                            from: nil
                        )
                    }
                    Button("Manage MCP Servers…") {
                        NSApp.sendAction(
                            #selector(KaisolaMacAppDelegate.openMcpSettings(_:)),
                            to: nil,
                            from: nil
                        )
                    }
                }
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

/// CRUD surface for reusable ACP launch profiles. The built-ins are immutable;
/// Fork creates a fully editable snapshot so changing policy is always an
/// explicit user action rather than an in-place mutation of a shared default.
private struct AgentRunProfilesSection: View {
    let workspace: URL?
    private let store = AcpRunProfileStore()
    @State private var profiles: [AcpRunProfile] = []
    @State private var defaultProfileID = AcpRunProfile.write.id

    private var knownMCPServerNames: [String]? {
        workspace.map { McpConfigStore(workspace: $0).servers().map(\.name) }
    }

    private var mcpServerNames: [String] {
        knownMCPServerNames ?? []
    }

    var body: some View {
        Section("Run Profiles") {
            Text("Profiles fix the model, host tools, and MCP servers advertised to a new chat. Each turn records the exact snapshot it used.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(profiles) { profile in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if profile.isBuiltIn {
                            Text(profile.name).font(.callout.weight(.medium))
                        } else {
                            TextField("Profile name", text: nameBinding(profile.id))
                                .textFieldStyle(.roundedBorder)
                        }
                        if profile.id == defaultProfileID {
                            Text("Default")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Make Default") { setDefault(profile.id) }
                                .font(.caption)
                        }
                        Spacer()
                        Button("Fork") { fork(profile.id) }.font(.caption)
                        if !profile.isBuiltIn {
                            Button(role: .destructive) { delete(profile.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    TextField("Stable model ID (optional)", text: modelBinding(profile.id))
                        .font(.caption.monospaced())
                        .textFieldStyle(.roundedBorder)
                        .disabled(profile.isBuiltIn)
                    HStack(spacing: 14) {
                        ForEach(AcpRunProfile.ClientTool.allCases, id: \.rawValue) { tool in
                            Toggle(tool.title, isOn: toolBinding(profile.id, tool))
                                .toggleStyle(.checkbox)
                                .disabled(profile.isBuiltIn)
                        }
                    }
                    if !mcpServerNames.isEmpty {
                        HStack(spacing: 14) {
                            Text("MCP").font(.caption.weight(.semibold))
                            ForEach(mcpServerNames, id: \.self) { name in
                                Toggle(name, isOn: mcpBinding(profile.id, name))
                                    .toggleStyle(.checkbox)
                                    .disabled(profile.isBuiltIn)
                            }
                        }
                    }
                    let warnings = profile.availabilityWarnings(knownMCPServerNames: mcpServerNames)
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    let hasUnavailableClientTool = profile.enabledClientToolIDs.contains {
                        AcpRunProfile.ClientTool(rawValue: $0) == nil
                    }
                    if !warnings.isEmpty,
                       !profile.isBuiltIn,
                       knownMCPServerNames != nil || hasUnavailableClientTool {
                        Button("Remove unavailable references") {
                            removeUnavailableReferences(from: profile.id)
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .help("Remove only unavailable tool and MCP references; valid selections stay enabled.")
                        .accessibilityIdentifier("settings.run-profile.\(profile.id).repair-availability")
                    }
                }
                .padding(.vertical, 3)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.run-profile.\(profile.id)")
            }
            Button("New Profile") {
                let created = store.create(name: "New Profile")
                refresh(selecting: created.id)
            }
        }
        .onAppear { refresh() }
    }

    private func nameBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { profiles.first(where: { $0.id == id })?.name ?? "" },
            set: { value in
                guard store.rename(id, to: value) else { return }
                refresh()
            }
        )
    }

    private func modelBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { profiles.first(where: { $0.id == id })?.modelID ?? "" },
            set: { value in
                update(id) { profile in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.modelID = trimmed.isEmpty ? nil : trimmed
                }
            }
        )
    }

    private func toolBinding(_ id: String, _ tool: AcpRunProfile.ClientTool) -> Binding<Bool> {
        Binding(
            get: { profiles.first(where: { $0.id == id })?.allows(tool) == true },
            set: { enabled in
                update(id) { profile in
                    profile.enabledClientToolIDs.removeAll { $0 == tool.rawValue }
                    if enabled { profile.enabledClientToolIDs.append(tool.rawValue) }
                }
            }
        )
    }

    private func mcpBinding(_ id: String, _ name: String) -> Binding<Bool> {
        Binding(
            get: {
                guard let profile = profiles.first(where: { $0.id == id }) else { return false }
                return profile.enabledMCPServerNames.contains(AcpRunProfile.allMCPServersID)
                    || profile.enabledMCPServerNames.contains(name)
            },
            set: { enabled in
                update(id) { profile in
                    if profile.enabledMCPServerNames.contains(AcpRunProfile.allMCPServersID) {
                        profile.enabledMCPServerNames = mcpServerNames
                    }
                    profile.enabledMCPServerNames.removeAll { $0 == name }
                    if enabled { profile.enabledMCPServerNames.append(name) }
                }
            }
        )
    }

    private func update(_ id: String, mutation: (inout AcpRunProfile) -> Void) {
        guard var profile = store.profile(id: id), !profile.isBuiltIn else { return }
        mutation(&profile)
        _ = store.update(profile)
        refresh()
    }

    private func setDefault(_ id: String) {
        store.defaultProfileID = id
        refresh()
    }

    private func fork(_ id: String) {
        let created = store.fork(id)
        refresh(selecting: created?.id)
    }

    private func delete(_ id: String) {
        _ = store.delete(id)
        refresh()
    }

    private func removeUnavailableReferences(from id: String) {
        _ = store.removeUnavailableReferences(
            from: id,
            knownMCPServerNames: knownMCPServerNames
        )
        refresh()
    }

    private func refresh(selecting _: String? = nil) {
        profiles = store.all()
        defaultProfileID = store.defaultProfileID
    }
}

/// Sidebar clusters (2026-08-06 spec §3a). Internal — selection travels as
/// the enum end-to-end; deep links go through `SettingsSection(rawValue:)`.
enum SettingsGroup: String, CaseIterable, Identifiable {
    case app, workspace, agents, device
    var id: String { rawValue }
    var title: String {
        switch self {
        case .app: "App"
        case .workspace: "Workspace"
        case .agents: "Agents"
        case .device: "Device"
        }
    }
    var sections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.group == self }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, terminal, companion, guardrails, extensions, accounts, agents, models, shortcuts, usage, updates
    var id: String { rawValue }

    var group: SettingsGroup {
        switch self {
        case .general, .updates: .app
        case .terminal, .guardrails, .shortcuts: .workspace
        case .agents, .models, .accounts, .extensions, .usage: .agents
        case .companion: .device
        }
    }
    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .companion: "Companion"
        case .guardrails: "Guardrails"
        case .extensions: "Extensions"
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
        case .extensions: "Agents, servers, themes, grammars, and previews"
        case .accounts: "Sign-ins, named accounts, and project overrides"
        case .agents: "Built-in agents and ACP adapters"
        case .models: "Provider credentials, models, and routing"
        case .shortcuts: "Shortcuts and keymap.json overrides"
        case .usage: "Provider limits and live context"
        case .updates: "Version, automatic checks, and downloads"
        }
    }
    /// Visible row names and useful vocabulary that users reasonably search
    /// for even when it differs from the owning section title.
    var searchTerms: [String] {
        switch self {
        case .general:
            ["Default Project Directory", "On Launch", "External Editor", "Appearance", "sidebar transparency"]
        case .terminal:
            ["Font", "Font Size", "Theme", "Palette", "Copy on Select", "Option as Meta", "Scrollback", "Shell"]
        case .companion:
            ["Pair Device", "pairing code", "QR code", "nearby device", "remote access", "permissions"]
        case .guardrails:
            ["Standing Allow Rules", "Sensitive Files", "sensitive file patterns", "always ask", "safety approvals"]
        case .extensions:
            ["Custom Agents", "MCP Servers", "Themes", "Grammars", "Preview Mappings", "plugins"]
        case .accounts:
            ["Sign In", "Named Accounts", "Account Directory", "Project Overrides", "project assignments", "Claude", "Codex"]
        case .agents:
            ["Claude", "Codex", "Custom Agent", "ACP Adapter", "launch command"]
        case .models:
            ["API Keys", "Provider Credentials", "Models", "Routing", "default model"]
        case .shortcuts:
            ["Keyboard Shortcuts", "keymap", "Command Palette", "key bindings"]
        case .usage:
            ["Provider Limits", "Rate Limits", "Context Window", "Reset Time", "headroom"]
        case .updates:
            ["Check Now", "Automatic Updates", "Background Downloads", "Version", "restart"]
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .terminal: "terminal"
        case .companion: "iphone.and.arrow.forward"
        case .guardrails: "shield.lefthalf.filled"
        case .extensions: "puzzlepiece.extension"
        case .accounts: "person.crop.circle"
        case .agents: "sparkles"
        case .models: "key"
        case .shortcuts: "keyboard"
        case .usage: "gauge.with.dots.needle.bottom.50percent"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

enum SettingsCatalogSearch {
    static let fieldIdentifier = "settings.catalog-search"
    static let resultCountIdentifier = "settings.catalog-search.result-count"
    static let emptyStateIdentifier = "settings.catalog-search.empty"

    static func isFiltering(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func matches(query: String) -> [SettingsSection] {
        let queryTokens = tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }
        return SettingsSection.allCases.filter { section in
            let haystack = normalized(
                ([section.title, section.subtitle, section.rawValue, section.group.title] + section.searchTerms)
                    .joined(separator: " ")
            )
            return queryTokens.allSatisfy { haystack.contains($0) }
        }
    }

    static func resultCountLabel(_ count: Int) -> String {
        switch count {
        case 0: "No results"
        case 1: "1 result"
        default: "\(count) results"
        }
    }

    static func accessibilityValue(query: String, resultCount: Int) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Empty. Showing grouped Settings."
        }
        return "\(trimmed). \(resultCountLabel(resultCount))."
    }

    private static func tokens(in value: String) -> [String] {
        normalized(value)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
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
                .foregroundStyle(.kaisolaSecondary)
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
                .foregroundStyle(.kaisolaSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.kaisolaSecondary)
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
                .foregroundStyle(.kaisolaTertiary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(minWidth: 108, minHeight: 30)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ExternalEditorChoiceLabel: View {
    let resolution: ExternalEditorResolution

    var body: some View {
        HStack(spacing: 7) {
            icon
                .frame(width: 18, height: 18)
            Text(resolution.displayName)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.kaisolaTertiary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(minWidth: 170, minHeight: 30)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var icon: some View {
        switch resolution {
        case .systemDefault:
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.kaisolaSecondary)
        case .application(let application):
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                .resizable()
                .scaledToFit()
        case .unresolved:
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.orange)
        }
    }
}

/// The affected terminal surface keeps selection and a live preview here, then
/// deep-links registry management to the consolidated Extensions destination.
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
                .padding(.bottom, 8)
            if let invalidTheme = customSpecs.first(where: { $0.validationError != nil }),
               let reason = invalidTheme.validationError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    Spacer()
                    Button("Review") {
                        let route = ExtensionsSettingsRoute(
                            category: .terminalThemes,
                            itemID: invalidTheme.id
                        ).rawValue
                        NSApp.sendAction(
                            #selector(KaisolaMacAppDelegate.openExtensionSettings(_:)),
                            to: nil,
                            from: route
                        )
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Review invalid theme \(invalidTheme.title)")
                    .accessibilityHint("Opens its validation error in Extensions settings")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
            HStack {
                Label(
                    "Import, validate, and remove palettes in Extensions.",
                    systemImage: "puzzlepiece.extension"
                )
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)
                Spacer()
                Button("Manage Themes…") {
                    NSApp.sendAction(
                        #selector(KaisolaMacAppDelegate.openTerminalThemeSettings(_:)),
                        to: nil,
                        from: nil
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Opens Extensions settings at Terminal Themes")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .onAppear { customSpecs = store.specs() }
    }
}

struct TerminalPalettePreviewAccessibility: Equatable {
    static let identifier = "settings.terminal.palette-preview"

    let themeTitle: String

    var label: String {
        "Terminal palette preview, \(themeTitle) theme. "
            + "Foreground text: home path. "
            + "Background: terminal canvas. "
            + "Cursor: block cursor. "
            + "ANSI green: percent prompt. "
            + "ANSI blue: codex command."
    }
}

private struct TerminalPalettePreview: View {
    let definition: ThemeDefinition
    let light: Bool
    var body: some View {
        let palette = light ? definition.light : definition.dark
        let accessibility = TerminalPalettePreviewAccessibility(themeTitle: definition.title)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityIdentifier(TerminalPalettePreviewAccessibility.identifier)
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

struct SensitiveGlobFieldAccessibility: Equatable {
    static let identifier = "settings.guardrails.sensitive-glob"

    let issue: String?

    var value: String {
        issue == nil ? "Valid" : "Invalid"
    }

    var description: String {
        guard let issue else { return "No validation error." }
        return "Invalid. \(issue)"
    }

    static func announcement(previous: String?, current: String?) -> String? {
        guard previous != current else { return nil }
        if let current {
            return "Sensitive file pattern invalid. \(current)"
        }
        guard previous != nil else { return nil }
        return "Sensitive file pattern is valid."
    }
}

struct StandingRuleRemovalPresentation: Equatable {
    enum FocusTarget: Equatable {
        case rule(String)
        case emptyState
    }

    let rule: PermissionRule

    var title: String { "Delete Standing Allow Rule?" }

    var message: String {
        """
        Action: \(rule.action)
        Resource: \(rule.resource)
        Workspace: \(rule.workspace)

        Future matching requests will require approval again.
        """
    }

    var announcement: String {
        let label = AcpPermissionRules.ruleLabel(action: rule.action, resource: rule.resource)
        return "Standing allow rule deleted. \(label) in \(rule.workspace) now requires approval."
    }

    static func focusTarget(afterRemoving id: String, from rules: [PermissionRule]) -> FocusTarget {
        let originalIndex = rules.firstIndex { $0.id == id } ?? 0
        let remaining = rules.filter { $0.id != id }
        guard !remaining.isEmpty else { return .emptyState }
        return .rule(remaining[min(originalIndex, remaining.count - 1)].id)
    }

    static func didRemove(_ rule: PermissionRule, persistedRules: [PermissionRule]) -> Bool {
        !persistedRules.contains { candidate in
            candidate.id == rule.id
                || (candidate.workspace == rule.workspace
                    && candidate.action == rule.action
                    && candidate.resource == rule.resource)
        }
    }
}

enum SensitiveGlobControlFocus: Hashable {
    case remove(String)
    case newPattern
}

struct SensitiveGlobRemovalPlan: Equatable {
    let remaining: [String]
    let nextFocus: SensitiveGlobControlFocus
}

enum SensitiveGlobRemovalPolicy {
    static func plan(removing glob: String, from existing: [String]) -> SensitiveGlobRemovalPlan? {
        guard let removalIndex = existing.firstIndex(of: glob) else { return nil }
        var remaining = existing
        remaining.remove(at: removalIndex)
        let nextFocus: SensitiveGlobControlFocus
        if remaining.isEmpty {
            nextFocus = .newPattern
        } else {
            nextFocus = .remove(remaining[min(removalIndex, remaining.count - 1)])
        }
        return SensitiveGlobRemovalPlan(remaining: remaining, nextFocus: nextFocus)
    }

    static func confirmationMessage(for glob: String) -> String {
        "Remove \(glob)? Paths matching this pattern will no longer always require approval."
    }

    static func announcement(for glob: String) -> String {
        "Sensitive file pattern \(glob) removed. Matching paths are no longer always-ask protected."
    }
}

/// Guardrails tab: standing permission rules (delete) + sensitive globs (edit).
private struct GuardrailsSettings: View {
    @ObservedObject var settings: NativePreviewSettings
    @State private var rules: [PermissionRule] = []
    @State private var newGlob = ""
    @State private var globPendingRemoval: String?
    @State private var showsRestoreDefaultsConfirmation = false
    @State private var pendingRuleRemoval: PermissionRule?
    @State private var showsRuleRemovalConfirmation = false
    @State private var pendingRuleFocus: StandingRuleRemovalPresentation.FocusTarget?
    @State private var pendingRuleAnnouncement: String?
    @State private var ruleRemovalFailure: String?
    @FocusState private var focusedRuleID: String?
    @FocusState private var emptyRuleStateFocused: Bool
    @FocusState private var focusedControl: SensitiveGlobControlFocus?
    @AccessibilityFocusState private var accessibilityFocusedControl: SensitiveGlobControlFocus?
    private let store = PermissionRuleStore()

    var body: some View {
        Form {
            Section("Standing Allow Rules") {
                if rules.isEmpty {
                    Text("No rules yet — \"Always Allow\" on a permission ask creates one.")
                        .font(.caption).foregroundStyle(.kaisolaSecondary)
                        .focusable()
                        .focused($emptyRuleStateFocused)
                        .accessibilityIdentifier("settings.guardrails.allow-rules.empty")
                }
                ForEach(rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AcpPermissionRules.ruleLabel(action: rule.action, resource: rule.resource))
                                .font(.callout)
                            Text(rule.workspace)
                                .font(.caption2).foregroundStyle(.kaisolaSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            requestRuleRemoval(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .focused($focusedRuleID, equals: rule.id)
                        .accessibilityLabel("Delete allow-rule \(AcpPermissionRules.ruleLabel(action: rule.action, resource: rule.resource))")
                        .accessibilityHint("Opens a confirmation showing the exact action, resource, and workspace.")
                    }
                }
                if let ruleRemovalFailure {
                    Text(ruleRemovalFailure)
                        .font(.caption)
                        .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                        .accessibilityIdentifier("settings.guardrails.allow-rule-removal-error")
                }
            }
            Section("Sensitive Files (Always Ask, Never Rule-Covered)") {
                ForEach(settings.sensitiveGlobs, id: \.self) { glob in
                    HStack {
                        Text(glob).font(.callout.monospaced())
                        Spacer()
                        Button(role: .destructive) {
                            globPendingRemoval = glob
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove sensitive file pattern \(glob)")
                        .accessibilityHint("Requires confirmation before changing always-ask protection")
                        .focused($focusedControl, equals: .remove(glob))
                        .accessibilityFocused($accessibilityFocusedControl, equals: .remove(glob))
                    }
                }
                HStack {
                    TextField("Add glob (e.g. **/*.p12)", text: $newGlob)
                        .onSubmit(addGlob)
                        .focused($focusedControl, equals: .newPattern)
                        .accessibilityFocused($accessibilityFocusedControl, equals: .newPattern)
                        .accessibilityLabel("Sensitive file pattern")
                        .accessibilityValue(newGlobAccessibility.value)
                        .accessibilityHint(newGlobAccessibility.description)
                        .accessibilityIdentifier(SensitiveGlobFieldAccessibility.identifier)
                        .onChange(of: newGlobIssue) { previous, current in
                            announceValidationChange(previous: previous, current: current)
                        }
                    Button("Add", action: addGlob)
                        .disabled(!canAddGlob)
                }
                if let issue = newGlobIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(KaisolaStatusTone.failed.foregroundColor)
                        .accessibilityHidden(true)
                }
                Button("Restore Defaults") { showsRestoreDefaultsConfirmation = true }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding(6)
        .onAppear { rules = store.rules() }
        .confirmationDialog(
            pendingRuleRemoval.map { StandingRuleRemovalPresentation(rule: $0).title }
                ?? "Delete Standing Allow Rule?",
            isPresented: $showsRuleRemovalConfirmation,
            titleVisibility: .visible
        ) {
            if let rule = pendingRuleRemoval {
                Button("Delete Allow Rule", role: .destructive) {
                    confirmRuleRemoval(rule)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let rule = pendingRuleRemoval {
                Text(StandingRuleRemovalPresentation(rule: rule).message)
            }
        }
        .onChange(of: showsRuleRemovalConfirmation) { previous, current in
            guard previous, !current else { return }
            finishRuleRemovalDialog()
        }
        .confirmationDialog(
            "Remove Sensitive-File Pattern?",
            isPresented: showsGlobRemovalConfirmation,
            titleVisibility: .visible,
            presenting: globPendingRemoval
        ) { glob in
            Button("Remove \(glob)", role: .destructive) {
                removeSensitiveGlob(glob)
            }
            Button("Cancel", role: .cancel) {
                globPendingRemoval = nil
            }
        } message: { glob in
            Text(SensitiveGlobRemovalPolicy.confirmationMessage(for: glob))
        }
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

    private var showsGlobRemovalConfirmation: Binding<Bool> {
        Binding(
            get: { globPendingRemoval != nil },
            set: { isPresented in
                if !isPresented { globPendingRemoval = nil }
            }
        )
    }

    private var newGlobAccessibility: SensitiveGlobFieldAccessibility {
        SensitiveGlobFieldAccessibility(issue: newGlobIssue)
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

    private func requestRuleRemoval(_ rule: PermissionRule) {
        pendingRuleRemoval = rule
        pendingRuleFocus = .rule(rule.id)
        pendingRuleAnnouncement = nil
        ruleRemovalFailure = nil
        showsRuleRemovalConfirmation = true
    }

    private func confirmRuleRemoval(_ rule: PermissionRule) {
        let presentation = StandingRuleRemovalPresentation(rule: rule)
        let successFocus = StandingRuleRemovalPresentation.focusTarget(
            afterRemoving: rule.id,
            from: rules
        )
        store.remove(id: rule.id)
        let persistedRules = store.rules()
        rules = persistedRules
        if StandingRuleRemovalPresentation.didRemove(rule, persistedRules: persistedRules) {
            pendingRuleFocus = successFocus
            pendingRuleAnnouncement = presentation.announcement
            ruleRemovalFailure = nil
        } else {
            pendingRuleFocus = .rule(rule.id)
            pendingRuleAnnouncement = nil
            ruleRemovalFailure = "The allow rule could not be deleted. Nothing changed; try again."
        }
    }

    private func finishRuleRemovalDialog() {
        pendingRuleRemoval = nil
        if let pendingRuleFocus {
            focusedRuleID = nil
            emptyRuleStateFocused = false
            switch pendingRuleFocus {
            case let .rule(id):
                focusedRuleID = id
            case .emptyState:
                emptyRuleStateFocused = true
            }
        }
        pendingRuleFocus = nil
        if let pendingRuleAnnouncement {
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: pendingRuleAnnouncement,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
        pendingRuleAnnouncement = nil
    }

    private func removeSensitiveGlob(_ glob: String) {
        guard let plan = SensitiveGlobRemovalPolicy.plan(
            removing: glob,
            from: settings.sensitiveGlobs
        ) else {
            globPendingRemoval = nil
            return
        }
        settings.sensitiveGlobs = plan.remaining
        globPendingRemoval = nil

        DispatchQueue.main.async {
            focusedControl = plan.nextFocus
            accessibilityFocusedControl = plan.nextFocus
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: SensitiveGlobRemovalPolicy.announcement(for: glob),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func announceValidationChange(previous: String?, current: String?) {
        guard let announcement = SensitiveGlobFieldAccessibility.announcement(
            previous: previous,
            current: current
        ) else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ]
        )
    }
}
