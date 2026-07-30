import SwiftUI

/// Settings ▸ Usage: restored token usage across every ACP chat, the
/// native counterpart to Electron's session usage gauges. Per-chat context
/// gauges plus session totals, sourced from `UsageCenter.shared`.
struct UsageSettingsTab: View {
    @ObservedObject private var usage = UsageCenter.shared
    let workspace: URL?

    @State private var accountProfiles: [UsageAccountProfile] = []
    private let accountStore = UsageAccountStore()

    /// Reading for a configured account. `ProviderPlanUsage.profileID` carries
    /// the account it was read for, so two Claude subscriptions never collapse
    /// onto one card.
    private func reading(for profile: UsageAccountProfile) -> UsageCenter.ProviderPlanUsage? {
        usage.planUsage.first { $0.profileID == profile.id }
    }

    private var unmatchedReadings: [UsageCenter.ProviderPlanUsage] {
        let known = Set(accountProfiles.map(\.id))
        return usage.planUsage.filter { reading in
            guard let id = reading.profileID else { return true }
            return !known.contains(id)
        }
    }

    /// Sign in *as this account* by scoping the CLI's own login to that
    /// account's config directory. Kaisola never touches the credential — the
    /// CLI writes it into that directory (or the Keychain entry derived from
    /// it), which is precisely what keeps two subscriptions separate.
    private func signIn(to profile: UsageAccountProfile) {
        let login = profile.provider == .claude ? "claude setup-token" : "codex login"
        let quoted = "'" + profile.expandedDirectory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        NotificationCenter.default.post(
            name: .kaisolaRunInTerminal,
            object: nil,
            userInfo: [
                SignInCardView.commandUserInfoKey:
                    "\(profile.provider.environmentKey)=\(quoted) \(login)"
            ]
        )
    }

    private func reveal(_ profile: UsageAccountProfile) {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: profile.expandedDirectory)
        ])
    }

    var body: some View {
        Form {
            if !usage.byChat.isEmpty {
                totals
            }

            Section {
                // Cards first, one per configured subscription, rendered from
                // whatever reading is already known. A configured account always
                // gets a card even before its first probe returns — an account
                // you set up should never simply be absent from this list.
                if accountProfiles.isEmpty, usage.planUsage.isEmpty {
                    if usage.isRefreshingPlanUsage {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Reading provider account limits…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = usage.planUsageError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(
                            "Add a Claude or Codex account in Agents settings to see its plan and limits here.",
                            systemImage: "person.2"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(accountProfiles) { profile in
                        SubscriptionCardView(
                            profile: profile,
                            usage: reading(for: profile),
                            isRefreshing: usage.isRefreshingPlanUsage,
                            now: Date(),
                            onSignIn: { signIn(to: profile) },
                            onReveal: { reveal(profile) }
                        )
                    }
                    // A reading with no matching configured profile — the CLI's
                    // own default login, which has no named account entry.
                    ForEach(unmatchedReadings) { provider in
                        ProviderPlanUsageRow(provider: provider)
                    }
                }
            } header: {
                HStack {
                    Text("Account limits")
                    Spacer()
                    Button {
                        usage.refreshPlanUsage(workspace: workspace, force: true)
                    } label: {
                        if usage.isRefreshingPlanUsage {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(usage.isRefreshingPlanUsage)
                    .accessibilityLabel("Refresh account limits")
                }
            } footer: {
                Text("Every named account is read independently. Codex uses its read-only app-server. Claude uses the pinned Agent SDK's experimental control-only usage request; no model prompt is sent and no credential is copied into Kaisola.")
            }

            if usage.byChat.isEmpty {
                Section("Agent chats") {
                    Label("Context usage appears after an agent chat reports a window.", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Agent chats") {
                    ForEach(usage.all) { chat in
                        ChatUsageRow(chat: chat)
                    }
                }
                Section {
                    Button("Reset usage", role: .destructive) { usage.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(6)
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
    }

    private var totals: some View {
        Section("Restored totals") {
            LabeledContent("Total peak tokens", value: Self.tokens(usage.totalPeakTokens))
            LabeledContent("Active chats", value: "\(usage.byChat.count)")
            ForEach(usage.costTotals) { total in
                LabeledContent("Session cost (\(total.currency))") {
                    Text(total.amount, format: .currency(code: total.currency))
                        .monospacedDigit()
                }
            }
            LabeledContent("Context pressure") {
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

    /// Compact token count: raw below 1k, otherwise "Nk" (parity with the chat
    /// header's `used/1000)k` formatting).
    static func tokens(_ n: Int) -> String {
        n < 1000 ? "\(n)" : "\(n / 1000)k"
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
                Text(provider.sourceLabel)
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
                Text("Experimental provider API · \(provider.sourceLabel)")
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
