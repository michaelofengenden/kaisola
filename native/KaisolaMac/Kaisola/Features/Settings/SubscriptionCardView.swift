import SwiftUI

/// One configured Claude or Codex subscription, as a card.
///
/// Each account is a config-directory redirection — `CLAUDE_CONFIG_DIR` or
/// `CODEX_HOME` — which is how both CLIs isolate credentials, so two Max plans
/// can coexist. Kaisola holds no provider tokens: they stay in the Keychain and
/// in the CLIs' own stores. Everything shown here is a label, a plan name, a
/// percentage, or a timestamp.
///
/// The card renders from cache first and never blocks on a probe. That matters
/// because the authoritative read spawns a subprocess per account behind a
/// helper verification; showing the last known numbers with a staleness caption
/// beats showing a spinner.
struct SubscriptionCardView: View {
    let profile: UsageAccountProfile
    /// Latest reading for this account, if one has been taken or restored.
    let usage: UsageCenter.ProviderPlanUsage?
    let isRefreshing: Bool
    let now: Date
    var onSignIn: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: (() -> Void)?

    @State private var emailRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            authLine
            if let usage, !usage.windows.isEmpty {
                ForEach(usage.windows) { window in
                    SubscriptionUsageMeter(window: window, now: now)
                }
            } else if let message = usage?.message, !message.isEmpty {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            footer
        }
        .padding(12)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: KaisolaVisualSystem.hairline)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .topLeading) {
                // The mark the sidebar and the Accounts list both draw. This was
                // a generic `sparkle` / `chevron` pair, so one account wore a
                // different face on each surface that showed it.
                QuietIdentityMarkView(
                    identity: profile.provider == .claude ? .claude : .openai,
                    size: 16
                )
                .frame(width: 22, height: 22)
                // Four states shared one tinted dot, and the red one — the
                // account that needs attention — had no text anywhere to fall
                // back on. Each state now carries its own glyph and its own
                // words.
                Image(systemName: statusSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(statusColor, Color(nsColor: .windowBackgroundColor))
                    .offset(x: -4, y: -4)
                    .accessibilityElement()
                    .accessibilityLabel("\(profile.label): \(statusDescription)")
                    .help(statusDescription)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.label)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(profile.provider.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            if let plan = usage?.plan, !plan.isEmpty {
                Text(plan.capitalized)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if isRefreshing {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var statusColor: Color {
        guard let usage else { return .secondary }
        if !usage.ok { return .red }
        return usage.account?.isEmpty == false ? .green : .orange
    }

    private var statusSymbol: String {
        guard let usage else { return "circle.dotted" }
        if !usage.ok { return "exclamationmark.circle.fill" }
        return usage.account?.isEmpty == false ? "checkmark.circle.fill" : "circle"
    }

    private var statusDescription: String {
        guard let usage else { return "Checking this account" }
        if !usage.ok { return "Needs attention" }
        return usage.account?.isEmpty == false ? "Signed in" : "Not signed in"
    }

    // MARK: - Identity

    /// The account email is blurred until clicked. This is a screen you might
    /// share or screenshot while comparing two subscriptions.
    @ViewBuilder
    private var authLine: some View {
        if let account = usage?.account, !account.isEmpty {
            Button {
                emailRevealed.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text("Signed in as")
                        .foregroundStyle(.secondary)
                    Text(emailRevealed ? account : String(repeating: "●", count: min(account.count, 12)))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .help(emailRevealed ? "Hide email" : "Click to reveal email")
            .accessibilityLabel(
                emailRevealed
                    ? "Hide email for \(profile.label)"
                    : "Reveal email for \(profile.label)"
            )
        } else if usage == nil {
            Text("Checking this account…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Not signed in")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(profile.directory)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("This account's config directory (\(profile.provider.environmentKey))")
            Spacer(minLength: 6)
            if let staleness = stalenessCaption {
                Text(staleness)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Menu {
                if let onSignIn {
                    Button("Sign In…", action: onSignIn)
                }
                if let onReveal {
                    Button("Reveal Directory in Finder", action: onReveal)
                }
                if let onRemove {
                    Divider()
                    Button("Remove Account", role: .destructive, action: onRemove)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Account actions for \(profile.label)")
        }
    }

    /// Says how old the numbers are rather than hiding that they are cached.
    private var stalenessCaption: String? {
        Self.stalenessCaption(updatedAt: usage?.updatedAt, now: now)
    }

    /// Provider helpers report `updatedAt` in epoch milliseconds, while older
    /// cached fixtures used epoch seconds. Accept both so a restored card never
    /// loses its only indication that the numbers are stale. `resetsAt` remains
    /// epoch seconds and is handled separately by `SubscriptionUsageMeter`.
    static func stalenessCaption(updatedAt: Double?, now: Date) -> String? {
        guard let updatedAt, updatedAt > 0, updatedAt.isFinite else { return nil }
        let epochSeconds = updatedAt > 10_000_000_000 ? updatedAt / 1_000 : updatedAt
        let elapsed = now.timeIntervalSince(Date(timeIntervalSince1970: epochSeconds))
        guard elapsed > 90 else { return nil }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h ago" }
        return "\(Int(elapsed / 86_400))d ago"
    }
}

/// A single plan window (5-hour, weekly) with its reset countdown.
struct SubscriptionUsageMeter: View {
    let window: UsageCenter.PlanWindow
    let now: Date

    private var fraction: Double {
        min(max((window.usedPercent ?? 0) / 100, 0), 1)
    }

    private var tint: Color {
        switch fraction {
        case ..<0.75: .green
        case ..<0.9: .orange
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let percent = window.usedPercent {
                    Text("\(Int(percent.rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let resets = resetCaption {
                    Text(resets)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint).frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) usage")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let percent = "\(Int((window.usedPercent ?? 0).rounded())) percent used"
        return resetCaption.map { "\(percent), \($0)" } ?? percent
    }

    private var resetCaption: String? {
        guard let resetsAt = window.resetsAt, resetsAt > 0 else { return nil }
        let remaining = Date(timeIntervalSince1970: resetsAt).timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        if remaining < 3_600 { return "resets in \(Int(remaining / 60))m" }
        if remaining < 86_400 { return "resets in \(Int(remaining / 3_600))h" }
        return "resets in \(Int(remaining / 86_400))d"
    }
}
