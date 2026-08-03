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
    /// This account is what a session in the current project actually runs on.
    var isCurrentProject = false
    var onSignIn: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        }
        .padding(10)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.cardRadius, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: KaisolaVisualSystem.hairline)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
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
            // The brand mark already says Claude or Codex, so the word under
            // the label was a line spent restating the icon beside it.
            Text(profile.label)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if isCurrentProject {
                Text("Current")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .help("Sessions in this project use this account")
                    .accessibilityLabel("Current project account")
            }
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
            actionsMenu
        }
    }

    /// The card's actions. Moved up from a footer of its own: that row carried
    /// the config directory, which duplicates what the account's name already
    /// tells you and cost every card a line plus its spacing. The directory now
    /// lives in the menu, where it is one hover away when it actually matters.
    private var actionsMenu: some View {
        Menu {
            Section(profile.directory) {
                if let onSignIn { Button("Sign In…", action: onSignIn) }
                if let onReveal { Button("Reveal Directory in Finder", action: onReveal) }
            }
            if let staleness = stalenessCaption {
                Section { Text("Updated \(staleness)") }
            }
            if let onRemove {
                Divider()
                Button("Remove Account", role: .destructive, action: onRemove)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Account actions for \(profile.label)")
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

    /// Only the states that need saying.
    ///
    /// This used to print the account's email behind a click-to-reveal blur, on
    /// the reasoning that you might screenshot this screen while comparing
    /// subscriptions. Michael: "why are email accounts covered? no need to be
    /// shown i think." He is right, and the masking made it worse rather than
    /// better — a row of ●●●●●●● is *more* conspicuous than a line that was
    /// never there, and it cost a click to learn something the account's own
    /// label already told you. You named these accounts; the email underneath
    /// is the provider's business.
    ///
    /// A signed-in account therefore says nothing here at all. The two states
    /// you can act on still speak.
    @ViewBuilder
    private var authLine: some View {
        if let account = usage?.account, !account.isEmpty {
            EmptyView()
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

    private var tint: Color { UsageMeterPalette.color(for: fraction) }

    /// Column widths, fixed so the bars line up down the card.
    ///
    /// Alignment is what makes a stack of meters scannable — a ragged left edge
    /// makes the eye re-find the start of every bar. Sized for the real
    /// content: "Weekly" is the longest label, "100%" the widest number.
    private static let labelWidth: CGFloat = 44
    private static let percentWidth: CGFloat = 34

    /// One line per window, not two.
    ///
    /// This used to stack — label and numbers on one row, bar beneath — so
    /// three windows cost six lines and a card of them could not be taken in at
    /// a glance. Michael: "is there a way to make the cards even more
    /// compact/easy and fast to read?" On one line the bar sits between its
    /// name and its number, and three windows are three lines you read straight
    /// down.
    var body: some View {
        HStack(spacing: 7) {
            Text(window.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.55))
                    Capsule()
                        .fill(UsageMeterPalette.fill(for: fraction))
                        .frame(width: max(3, geometry.size.width * fraction))
                        // A meter running out should look like it is running
                        // hot, so the glow rises with the fill.
                        .shadow(color: tint.opacity(0.35 * fraction), radius: 3, y: 0.5)
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 40)

            // The number is the point of the row, so it carries the weight
            // rather than sharing the label's grey.
            if let percent = window.usedPercent {
                Text("\(Int(percent.rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(width: Self.percentWidth, alignment: .trailing)
            }
            // Lowest priority: in a narrow card the reset gives up its width to
            // the bar, which is the part that has to stay readable.
            if let resets = resetCaption {
                Text(resets)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) usage")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let percent = "\(Int((window.usedPercent ?? 0).rounded())) percent used"
        return resetCaption.map { "\(percent), \($0)" } ?? percent
    }

    /// When this window resets, said the way that horizon is actually useful.
    ///
    /// Short horizons want the countdown — "in 40m" is what you need when
    /// deciding whether to wait. Long ones want the clock: "in 2d" is a range
    /// covering forty-eight hours, and once you are planning a day around a
    /// reset you want to know it lands Tuesday morning. So this switches at
    /// twelve hours rather than picking one style and being vague half the
    /// time.
    private var resetCaption: String? {
        Self.resetCaption(resetsAt: window.resetsAt, now: now)
    }

    /// Pure, so the switch and its boundary are testable without a view.
    ///
    /// `nonisolated` because it is: a `View` is main-actor isolated and its
    /// statics inherit that, which made a synchronous test call an isolation
    /// error under CI's stricter concurrency settings while building fine
    /// locally. Nothing here touches actor state.
    nonisolated static func resetCaption(resetsAt: Double?, now: Date) -> String? {
        guard let resetsAt, resetsAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: resetsAt)
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        if remaining < 3_600 { return "in \(Int(remaining / 60))m" }
        if remaining < 43_200 { return "in \(Int(remaining / 3_600))h" }

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        // Within the week the weekday names it; beyond that the date does.
        formatter.setLocalizedDateFormatFromTemplate(
            remaining < 6 * 86_400 ? "EEE j:mm" : "MMM d"
        )
        return formatter.string(from: date)
    }
}
