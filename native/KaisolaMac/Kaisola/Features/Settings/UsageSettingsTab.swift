import SwiftUI

/// Settings ▸ Usage: restored token usage across every ACP chat, the
/// native counterpart to Electron's session usage gauges. Per-chat context
/// gauges plus session totals, sourced from `UsageCenter.shared`.
struct UsageSettingsTab: View {
    @ObservedObject private var usage = UsageCenter.shared
    let workspace: URL?

    @State private var accountProfiles: [UsageAccountProfile] = []
    @State private var pendingAccountRemoval: UsageAccountProfile?
    @State private var signingIn: UsageAccountProfile?
    @State private var showsResetConfirmation = false
    private let accountStore = UsageAccountStore()

    /// Reading for a configured account. `ProviderPlanUsage.profileID` carries
    /// the account it was read for, so two Claude subscriptions never collapse
    /// onto one card.
    private func reading(for profile: UsageAccountProfile) -> UsageCenter.ProviderPlanUsage? {
        usage.planUsage.first { $0.profileID == profile.id }
    }

    private var unmatchedReadings: [UsageCenter.ProviderPlanUsage] {
        return usage.planUsage.filter { reading in
            guard let id = reading.profileID else { return true }
            // A removed named account can remain in the previous in-memory
            // reading until the forced refresh finishes. Do not resurrect it
            // as an anonymous provider row during that short handoff.
            return id == "active"
        }
    }

    /// What "Account limits" shows before there is anything to show.
    @ViewBuilder
    private var emptyAccountState: some View {
        if usage.isRefreshingPlanUsage {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Reading provider account limits…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let error = usage.planUsageError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label(
                "Add a Claude or Codex account under Accounts to see its plan and limits here.",
                systemImage: "person.2"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reveal(_ profile: UsageAccountProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: profile.expandedDirectory)
        ])
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !usage.byChat.isEmpty {
                    totals
                }

                SettingsCard(title: "Account limits", symbol: "gauge.with.dots.needle.bottom.50percent") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Each account is read separately, with no model prompt and no copied credentials.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 12)
                            Button {
                                usage.refreshPlanUsage(workspace: workspace, force: true)
                            } label: {
                                if usage.isRefreshingPlanUsage {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                            }
                            .controlSize(.small)
                            .disabled(usage.isRefreshingPlanUsage)
                            .accessibilityLabel("Refresh account limits")
                        }

                        // A configured account gets a card even before its
                        // first probe returns — an account you set up should
                        // never simply be absent from this list.
                        if accountProfiles.isEmpty, usage.planUsage.isEmpty {
                            emptyAccountState
                        } else {
                            ForEach(accountProfiles) { profile in
                                SubscriptionCardView(
                                    profile: profile,
                                    usage: reading(for: profile),
                                    isRefreshing: usage.isRefreshingPlanUsage,
                                    now: Date(),
                                    onSignIn: { signingIn = profile },
                                    onReveal: { reveal(profile) },
                                    onRemove: { pendingAccountRemoval = profile }
                                )
                            }
                            // A reading with no matching configured profile —
                            // the CLI's own default login, which has no named
                            // account entry.
                            ForEach(unmatchedReadings) { provider in
                                ProviderPlanUsageRow(provider: provider)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                SettingsCard(title: "Agent chats", symbol: "bubble.left.and.bubble.right") {
                    if usage.byChat.isEmpty {
                        Text("Context usage appears once an agent chat reports a window.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(Array(usage.all.enumerated()), id: \.element.id) { index, chat in
                            if index > 0 { SettingsDivider() }
                            ChatUsageRow(chat: chat)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        SettingsDivider()
                        HStack {
                            Spacer()
                            Button("Reset Usage", role: .destructive) {
                                showsResetConfirmation = true
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }
            .padding(18)
        }

        .task(id: workspace?.standardizedFileURL.path) {
            // Reading the account list is a small local JSON decode, so cards
            // can paint before any probe runs.
            accountProfiles = accountStore.profiles()
            // Hosted/local visual fixtures are deterministic and must never
            // replace their provider cards by probing an unsigned debug helper.
            // Production always performs the real signed-helper refresh.
            guard ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] != "1" else { return }
            usage.refreshPlanUsage(workspace: workspace)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kaisolaUsageAccountsChanged)) { _ in
            accountProfiles = accountStore.profiles()
            guard ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] != "1" else { return }
            usage.refreshPlanUsage(workspace: workspace, force: true)
        }
        .sheet(item: $signingIn) { profile in
            AccountSignInSheet(profile: profile) {
                signingIn = nil
                accountProfiles = accountStore.profiles()
            }
        }
        .confirmationDialog(
            "Remove \(pendingAccountRemoval?.label ?? "Account")?",
            isPresented: Binding(
                get: { pendingAccountRemoval != nil },
                set: { if !$0 { pendingAccountRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                guard let profile = pendingAccountRemoval else { return }
                pendingAccountRemoval = nil
                guard accountStore.remove(id: profile.id) else { return }
                accountProfiles.removeAll { $0.id == profile.id }
                NotificationCenter.default.post(name: .kaisolaUsageAccountsChanged, object: nil)
            }
            Button("Cancel", role: .cancel) { pendingAccountRemoval = nil }
        } message: {
            Text("Kaisola will forget this named account. Its provider files and sign-in stay on disk.")
        }
        .alert(
            "Reset Usage History?",
            isPresented: $showsResetConfirmation
        ) {
            Button("Reset Usage", role: .destructive) { usage.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears restored token, turn, and cost history for every agent chat. Provider account limits are not affected.")
        }
    }

    /// The session's headline numbers.
    ///
    /// A `Section` reads as a titled group only inside a `Form`; out here it
    /// would flatten into loose rows with no card around them. Same content, in
    /// the vocabulary the rest of Settings speaks.
    private var totals: some View {
        SettingsCard(title: "Restored totals", symbol: "sum") {
            SettingsRow(
                title: "Total peak tokens",
                detail: "Highest simultaneous context across chats",
                symbol: "number"
            ) {
                Text(Self.tokens(usage.totalPeakTokens))
                    .font(.callout.monospacedDigit())
            }
            SettingsDivider()
            SettingsRow(title: "Active chats", detail: "Reporting a context window", symbol: "bubble.left") {
                Text("\(usage.byChat.count)")
                    .font(.callout.monospacedDigit())
            }
            ForEach(usage.costTotals) { total in
                SettingsDivider()
                SettingsRow(title: "Session cost", detail: total.currency, symbol: "creditcard") {
                    Text(total.amount, format: .currency(code: total.currency))
                        .font(.callout.monospacedDigit())
                }
            }
            SettingsDivider()
            SettingsRow(
                title: "Context pressure",
                detail: "How full the fullest chat is",
                symbol: "gauge.with.dots.needle.bottom.50percent"
            ) {
                let pressure = usage.contextPressure
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(Int((pressure * 100).rounded()))%")
                        .font(.callout.monospacedDigit())
                    ProgressView(value: pressure)
                        .frame(width: 160)
                        .tint(pressure >= 0.85 ? .orange : .accentColor)
                        .accessibilityLabel("Context pressure")
                        .accessibilityValue("\(Int((pressure * 100).rounded())) percent")
                }
            }
        }
    }

    /// Compact token count that changes units at a million instead of emitting
    /// misleading values such as "1999k".
    static func tokens(_ n: Int) -> String {
        let value = max(0, n)
        if value < 1_000 { return "\(value)" }
        if value < 1_000_000 { return "\(value / 1_000)k" }
        let millions = (Double(value) / 1_000_000 * 10).rounded() / 10
        if millions.rounded() == millions { return "\(Int(millions))m" }
        return String(format: "%.1fm", millions)
    }
}

private struct ProviderPlanUsageRow: View {
    let provider: UsageCenter.ProviderPlanUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.displayName)
                    .font(.callout.weight(.semibold))
                if let label = provider.profileLabel, !label.isEmpty {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let plan = provider.plan, !plan.isEmpty {
                    Text(plan.capitalized)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Text(provider.ok ? "Available" : "Needs Attention")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let account = provider.account, !account.isEmpty {
                Text(account)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if provider.experimental == true {
                Text("Experimental usage support")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if provider.windows.isEmpty {
                Label(provider.message ?? "No limit windows available.", systemImage: provider.ok ? "info.circle" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(provider.windows) { window in
                    ProviderPlanWindowRow(window: window)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderPlanWindowRow: View {
    let window: UsageCenter.PlanWindow

    private var fraction: Double {
        min(max((window.usedPercent ?? 0) / 100, 0), 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.caption)
                Spacer()
                if let used = window.usedPercent {
                    Text("\(Int(used.rounded()))% used")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let resetsAt = window.resetsAt {
                    Text("resets")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(Date(timeIntervalSince1970: resetsAt), style: .relative)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: fraction)
                .tint(fraction >= 0.85 ? .orange : .accentColor)
                .accessibilityLabel("\(window.label) usage")
                .accessibilityValue("\(Int((window.usedPercent ?? 0).rounded())) percent used")
        }
    }
}

/// One chat's row: title + agent, a context-window gauge, and peak/turn meta.
private struct ChatUsageRow: View {
    let chat: UsageCenter.ChatUsage

    private var agentName: String {
        AgentRegistry.profile(id: chat.agentID)?.name
            ?? (chat.agentID.isEmpty ? "Agent" : chat.agentID)
    }

    private var fraction: Double {
        chat.latestMax > 0 ? Double(chat.latestUsed) / Double(chat.latestMax) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(chat.title.isEmpty ? "Untitled chat" : chat.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(agentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
                .tint(fraction >= 0.85 ? .orange : .accentColor)
                .accessibilityLabel("Context usage for \(chat.title.isEmpty ? "Untitled chat" : chat.title)")
                .accessibilityValue("\(chat.latestUsed) of \(chat.latestMax) tokens")
            HStack {
                Text("\(UsageSettingsTab.tokens(chat.latestUsed)) / \(UsageSettingsTab.tokens(chat.latestMax))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("peak \(UsageSettingsTab.tokens(chat.peakUsed)) · \(chat.turns) turn\(chat.turns == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let amount = chat.costAmount {
                Text(amount, format: .currency(code: chat.costCurrency ?? "USD"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
