import SwiftUI

/// A small value used by the first-run checklist and its focused tests. The
/// symbol and text always accompany color so every state remains legible under
/// VoiceOver, Increased Contrast, and color-vision differences.
struct OnboardingReadinessStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ready
        case checking
        case needsAction
        case information
    }

    let kind: Kind
    let detail: String
}

/// Pure readiness decisions kept outside the view. The UI observes live app
/// state, while tests can pin the important distinctions without launching a
/// window or touching a real provider account.
enum OnboardingReadiness {
    static func project(directory: URL?) -> OnboardingReadinessStatus {
        guard let directory else {
            return .init(
                kind: .needsAction,
                detail: "Choose the project folder where your sessions should work."
            )
        }
        return .init(
            kind: .ready,
            detail: "\(directory.lastPathComponent) is the active project."
        )
    }

    static func terminalService(
        connectionState: AppModel.ConnectionState,
        controlAvailable: Bool
    ) -> OnboardingReadinessStatus {
        switch connectionState {
        case .looking, .connecting:
            return .init(kind: .checking, detail: "Connecting to saved terminal sessions…")
        case let .reconnecting(attempt):
            return .init(
                kind: .checking,
                detail: "Reconnect attempt \(attempt). Running terminals continue safely."
            )
        case .connected where controlAvailable:
            return .init(
                kind: .ready,
                detail: "New terminals are enabled and running terminals can reconnect after Kaisola closes."
            )
        case .connected:
            return .init(
                kind: .needsAction,
                detail: "Saved terminals are visible, but new terminal control is temporarily unavailable."
            )
        case let .unavailable(message):
            return .init(kind: .needsAction, detail: message)
        }
    }

    static func agentAccount(
        agentID: String,
        readings: [UsageCenter.ProviderPlanUsage],
        isRefreshing: Bool
    ) -> OnboardingReadinessStatus {
        guard let provider = SessionAccountBinding.provider(forAgentID: agentID) else {
            return .init(
                kind: .ready,
                detail: "A plain terminal does not require an agent account."
            )
        }
        guard AcpAdapter.forAgent(agentID) != nil else {
            return .init(
                kind: .needsAction,
                detail: "The \(provider.displayName) chat adapter is not configured."
            )
        }
        if let reading = readings.first(where: { $0.provider == provider.rawValue }), reading.ok {
            let account = reading.account?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if let account, !account.isEmpty {
                detail = "\(provider.displayName) is signed in as \(account)."
            } else {
                detail = "The \(provider.displayName) adapter and account are verified."
            }
            return .init(
                kind: .ready,
                detail: detail
            )
        }
        if isRefreshing {
            return .init(
                kind: .checking,
                detail: "Checking the active \(provider.displayName) account…"
            )
        }
        return .init(
            kind: .needsAction,
            detail: "The adapter is ready, but the active \(provider.displayName) sign-in is not verified."
        )
    }

    static func updates(
        canConfigure: Bool,
        checksAutomatically: Bool,
        pendingVersion: String?
    ) -> OnboardingReadinessStatus {
        if let pendingVersion {
            return .init(
                kind: .needsAction,
                detail: "Kaisola \(pendingVersion) is ready to install from Settings."
            )
        }
        guard canConfigure else {
            return .init(
                kind: .information,
                detail: "Update controls become available in a signed Kaisola build."
            )
        }
        return checksAutomatically
            ? .init(kind: .ready, detail: "Kaisola will check for signed updates automatically.")
            : .init(kind: .needsAction, detail: "Automatic update checks are off.")
    }
}

/// First-run setup is an operational checklist rather than a feature tour. It
/// reflects the active project's real session-control and provider-account
/// state, keeps failed checks actionable, and can launch the first session only
/// when the project and terminal service are ready.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: NativePreviewSettings
    @ObservedObject private var usage = UsageCenter.shared
    @ObservedObject private var updates = UpdateCenter.shared

    let dismiss: () -> Void
    let openAccounts: () -> Void
    let openUpdateSettings: () -> Void

    @State private var selectedAgentID = "codex"

    private var launchChoices: [AgentProfile] {
        [.shell] + AgentRegistry.builtIns.filter {
            SessionAccountBinding.provider(forAgentID: $0.id) != nil
        }
    }

    private var selectedAgent: AgentProfile {
        launchChoices.first(where: { $0.id == selectedAgentID }) ?? .shell
    }

    private var projectStatus: OnboardingReadinessStatus {
        OnboardingReadiness.project(directory: model.currentProjectDirectory)
    }

    private var terminalStatus: OnboardingReadinessStatus {
        OnboardingReadiness.terminalService(
            connectionState: model.connectionState,
            controlAvailable: model.controlAvailable
        )
    }

    private var accountStatus: OnboardingReadinessStatus {
        OnboardingReadiness.agentAccount(
            agentID: selectedAgentID,
            readings: usage.planUsage,
            isRefreshing: usage.isRefreshingPlanUsage
        )
    }

    private var updateStatus: OnboardingReadinessStatus {
        OnboardingReadiness.updates(
            canConfigure: updates.canConfigureUpdates,
            checksAutomatically: updates.automaticallyChecksForUpdates,
            pendingVersion: updates.pendingUpdate?.version
        )
    }

    private var canStart: Bool {
        model.currentProjectDirectory != nil && model.controlAvailable
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    VStack(spacing: 10) {
                        readinessRow(
                            title: "Project",
                            symbol: "folder.fill",
                            status: projectStatus,
                            actionTitle: model.currentProjectDirectory == nil ? "Choose Project…" : nil,
                            action: { runCommand(.openProject) }
                        )
                        readinessRow(
                            title: "Terminal Continuity",
                            symbol: "terminal.fill",
                            status: terminalStatus,
                            actionTitle: terminalStatus.kind == .needsAction ? "Try Again" : nil,
                            action: { Task { await model.reload() } }
                        )
                        agentRow
                        readinessRow(
                            title: "Updates",
                            symbol: "arrow.triangle.2.circlepath",
                            status: updateStatus,
                            actionTitle: updateStatus.kind == .ready ? nil : "Update Settings",
                            action: openUpdateSettings
                        )
                    }

                    if !canStart {
                        Label(
                            "Choose a project and restore terminal control before starting the first session.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.kaisolaSecondary)
                    }
                }
                .padding(28)
            }

            Divider()
            controls
        }
        .frame(minWidth: 660, idealWidth: 700, minHeight: 500, idealHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            Button(action: dismiss) { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kaisola readiness checklist")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "checklist.checked")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 46, height: 46)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Get Ready to Work")
                    .font(.largeTitle.weight(.bold))
                Text("Confirm the essentials, then start a terminal or agent in your first project.")
                    .font(.title3)
                    .foregroundStyle(.kaisolaSecondary)
            }
        }
    }

    private var agentRow: some View {
        readinessRow(
            title: "Agent and Account",
            symbol: selectedAgent.symbol,
            status: accountStatus,
            actionTitle: accountStatus.kind == .needsAction ? "Open Accounts" : nil,
            action: openAccounts
        ) {
            Picker("First session", selection: $selectedAgentID) {
                ForEach(launchChoices) { agent in
                    Text(agent.name).tag(agent.id)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityLabel("First session type")
        }
    }

    @ViewBuilder
    private func readinessRow<Trailing: View>(
        title: String,
        symbol: String,
        status: OnboardingReadinessStatus,
        actionTitle: String?,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            statusSymbol(status.kind)
            Image(systemName: symbol)
                .foregroundStyle(.kaisolaSecondary)
                .frame(width: 19)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(status.detail)
                    .font(.subheadline)
                    .foregroundStyle(.kaisolaSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func readinessRow(
        title: String,
        symbol: String,
        status: OnboardingReadinessStatus,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        readinessRow(
            title: title,
            symbol: symbol,
            status: status,
            actionTitle: actionTitle,
            action: action
        ) { EmptyView() }
    }

    @ViewBuilder
    private func statusSymbol(_ kind: OnboardingReadinessStatus.Kind) -> some View {
        switch kind {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(KaisolaStatusTone.done.foregroundColor)
                .accessibilityLabel("Ready")
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
                .accessibilityLabel("Checking")
        case .needsAction:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(KaisolaStatusTone.needsYou.foregroundColor)
                .accessibilityLabel("Needs action")
        case .information:
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.kaisolaSecondary)
                .accessibilityLabel("Information")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Do This Later", action: dismiss)
                .fixedSize()
            Spacer()
            Button(startButtonTitle, action: startFirstSession)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .help(canStart ? "Start the selected session in the active project" : "Choose a project and reconnect first")
                .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var startButtonTitle: String {
        selectedAgent.id == AgentProfile.shell.id
            ? "Start Terminal"
            : "Start \(selectedAgent.name) Session"
    }

    private func startFirstSession() {
        guard canStart else { return }
        if selectedAgent.id == AgentProfile.shell.id {
            runCommand(.newTerminal)
        } else {
            runCommand(.newAgent(selectedAgent.id))
        }
        dismiss()
    }

    private func runCommand(_ id: AppCommandID) {
        _ = AppCommandRegistry.execute(
            id,
            in: AppCommandContext(model: model, settings: settings)
        )
    }
}

// MARK: - Persisted first-run flag

/// The one-time gate for ``OnboardingView``. Version 2 replaces the old feature
/// tour with a readiness checklist, so existing installs receive the useful
/// setup flow once without disturbing the v1 record.
enum OnboardingState {
    private static let seenKey = "onboardingSeen.v2"

    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: seenKey)
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}
