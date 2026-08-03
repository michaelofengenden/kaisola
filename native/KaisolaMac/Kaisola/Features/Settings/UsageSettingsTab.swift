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
        let all = usage.planUsage
        return all.filter { reading in
            guard let id = reading.profileID else { return true }
            // A removed named account can remain in the previous in-memory
            // reading until the forced refresh finishes. Do not resurrect it
            // as an anonymous provider row during that short handoff.
            guard id == "active" else { return false }
            // The CLI's default login is usually one of the accounts already
            // listed. Drawing it again as "Current project" showed the same
            // subscription twice with identical numbers; the named card wears
            // the badge instead.
            return !SessionAccountBinding.isRepresentedByNamedAccount(reading, readings: all)
        }
    }

    /// Named accounts the CLI's own default resolves to.
    private var currentProjectIDs: Set<String> {
        SessionAccountBinding.currentProjectProfileIDs(readings: usage.planUsage)
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
                            // Accounts flow into columns rather than stacking.
                            //
                            // One card per row meant five subscriptions were
                            // five screens of scrolling to compare — and
                            // comparing them is the entire reason this list
                            // exists. At 320pt minimum a card still holds its
                            // longest line (an email and an org), so a wide
                            // window shows two or three abreast and a narrow
                            // one falls back to the single column it had.
                            // Two per row at the narrowest Settings can be, more
                            // as it widens. 320 needed a wide window before it
                            // broke into columns, which put us back to scrolling
                            // one account at a time; the card's own content — a
                            // label, a plan pill, three meters — sits happily at
                            // 250, and the directory line truncates as it always
                            // did.
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 250), spacing: 10, alignment: .top)],
                                alignment: .leading,
                                spacing: 10
                            ) {
                                ForEach(accountProfiles) { profile in
                                    SubscriptionCardView(
                                        profile: profile,
                                        usage: reading(for: profile),
                                        isRefreshing: usage.isRefreshingPlanUsage,
                                        now: Date(),
                                        isCurrentProject: currentProjectIDs.contains(profile.id),
                                    onSignIn: { signingIn = profile },
                                        onReveal: { reveal(profile) },
                                        onRemove: { pendingAccountRemoval = profile }
                                    )
                                }
                                // A reading with no matching configured profile
                                // — the CLI's own default login, which has no
                                // named account entry.
                                ForEach(unmatchedReadings) { provider in
                                    ProviderPlanUsageRow(provider: provider)
                                }
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

/// A reading with no named account behind it — the CLI's own default login.
///
/// It used to draw its own header, its own meters and its own card-less layout,
/// so the same Usage list showed two visibly different things: severity-tinted
/// hairline bars inside a card for a named account, and blue full-width bars on
/// their own lines, at roughly triple the height, for this. Michael: "see how
/// they're not consistent formatting.. the color and all, also the space is a
/// little wasted."
///
/// It is now the same card and the same `SubscriptionUsageMeter`. The only
/// thing that still distinguishes it is what it honestly is: an account Kaisola
/// has no entry for, so it says so instead of naming a directory it does not
/// own.
private struct ProviderPlanUsageRow: View {
    let provider: UsageCenter.ProviderPlanUsage
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                QuietIdentityMarkView(
                    identity: provider.provider == "claude" ? .claude : .openai,
                    size: 16
                )
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.profileLabel.flatMap { $0.isEmpty ? nil : $0 } ?? provider.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("Signed in to the CLI directly")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                if let plan = provider.plan, !plan.isEmpty {
                    Text(plan.capitalized)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }

            if let account = provider.account, !account.isEmpty {
                Text(account)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if provider.windows.isEmpty {
                Label(
                    provider.message ?? "No limit windows available.",
                    systemImage: provider.ok ? "info.circle" : "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            } else {
                ForEach(provider.windows) { window in
                    SubscriptionUsageMeter(window: window, now: now)
                }
            }
        }
        .padding(12)
        .background(
            .quaternary.opacity(0.28),
            in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: KaisolaVisualSystem.hairline)
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
