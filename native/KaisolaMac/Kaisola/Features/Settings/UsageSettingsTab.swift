import SwiftUI

/// Settings ▸ Usage: session-lifetime token usage across every ACP chat, the
/// native counterpart to Electron's session usage gauges. Per-chat context
/// gauges plus session totals, sourced from `UsageCenter.shared`.
struct UsageSettingsTab: View {
    @ObservedObject private var usage = UsageCenter.shared
    let workspace: URL?

    var body: some View {
        Form {
            Section {
                if usage.isRefreshingPlanUsage, usage.planUsage.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Reading provider account limits…")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = usage.planUsageError, usage.planUsage.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(usage.planUsage) { provider in
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
                }
            } footer: {
                Text("Codex uses its read-only app-server. Claude uses the pinned Agent SDK control request; no model prompt is sent.")
            }

            if usage.byChat.isEmpty {
                Section("This app session") {
                    Label("Context usage appears after an agent chat reports a window.", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Chats") {
                    ForEach(usage.all) { chat in
                        ChatUsageRow(chat: chat)
                    }
                }
                totals
                Section {
                    Button("Reset usage", role: .destructive) { usage.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(6)
        .task(id: workspace?.standardizedFileURL.path) {
            usage.refreshPlanUsage(workspace: workspace)
        }
    }

    private var totals: some View {
        Section("Session totals") {
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
