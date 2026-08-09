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
                ForEach(usage.windowRows) { row in
                    SubscriptionUsageMeter(window: row.window, now: now)
                }
            } else if let message = usage?.message, !message.isEmpty {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.kaisolaSecondary)
                    .lineLimit(2)
            }
            if let usage {
                let provenance = Self.provenanceCaption(
                    sourceLabel: usage.sourceLabel,
                    updatedAt: usage.updatedAt,
                    now: now
                )
                if !provenance.isEmpty {
                    Text(provenance)
                        .font(.caption2)
                        .foregroundStyle(.kaisolaSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(provenance)
                        .accessibilityLabel("Usage source: \(provenance)")
                }
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
                .foregroundStyle(.kaisolaSecondary)
        } else {
            Text("Not signed in")
                .font(.caption)
                .foregroundStyle(.kaisolaSecondary)
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

    /// The visible provenance line shared by named and provider-default cards.
    /// A missing timestamp stays omitted instead of masquerading as a fresh read.
    nonisolated static func provenanceCaption(
        sourceLabel: String,
        updatedAt: Double?,
        now: Date
    ) -> String {
        let source = String(sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        var parts = source.isEmpty ? [] : [source]
        if let age = updateAgeCaption(updatedAt: updatedAt, now: now) {
            parts.append("updated \(age)")
        }
        return parts.joined(separator: " · ")
    }

    nonisolated private static func updateAgeCaption(
        updatedAt: Double?,
        now: Date
    ) -> String? {
        guard let updatedAt, updatedAt.isFinite, updatedAt > 0 else { return nil }
        let epochSeconds = updatedAt > 10_000_000_000 ? updatedAt / 1_000 : updatedAt
        let elapsed = now.timeIntervalSince1970 - epochSeconds
        guard elapsed >= -60 else { return nil }
        let age = max(0, elapsed)
        if age < 90 { return "just now" }
        if age < 3_600 { return "\(Int(age / 60))m ago" }
        if age < 86_400 { return "\(Int(age / 3_600))h ago" }
        return "\(Int(age / 86_400))d ago"
    }
}

/// A single plan window (5-hour, weekly) with its reset countdown.
struct SubscriptionUsageMeter: View {
    let window: UsageCenter.PlanWindow
    let now: Date

    private var fraction: Double {
        min((window.reportedUsedPercent ?? 0) / 100, 1)
    }

    private var tint: Color { UsageMeterPalette.color(for: fraction) }

    /// Column widths, fixed so the bars line up down the card.
    ///
    /// Alignment is what makes a stack of meters scannable — a ragged left edge
    /// makes the eye re-find the start of every bar. Sized for the real
    /// content: "Weekly" is the longest label, "100%" the widest number.
    private static let labelWidth: CGFloat = 44
    private static let percentWidth: CGFloat = 42
    /// Wide enough for the longest form the caption can take ("Wed 11:59 PM").
    private static let resetWidth: CGFloat = 68

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
                .foregroundStyle(.kaisolaSecondary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.55))
                    if window.reportedUsedPercent != nil {
                        Capsule()
                            .fill(UsageMeterPalette.fill(for: fraction))
                            .frame(width: max(3, geometry.size.width * fraction))
                            // A meter running out should look like it is running
                            // hot, so the glow rises with the fill.
                            .shadow(color: tint.opacity(0.35 * fraction), radius: 3, y: 0.5)
                    }
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 40)

            // The number is the point of the row, so it carries the weight
            // rather than sharing the label's grey.
            Text(Self.percentCaption(window.usedPercent))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(window.reportedUsedPercent == nil ? .kaisolaSecondary : .primary)
                .frame(width: Self.percentWidth, alignment: .trailing)
            // When a limit comes back is genuinely useful, so it gets a column
            // of its own rather than whatever the bar leaves over. It had
            // negative layout priority, which in a narrow card let it truncate
            // to nothing — the one outcome that makes the information useless.
            // The bar flexes instead; it has a floor of its own.
            Text(resetCaption ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.kaisolaSecondary)
                .lineLimit(1)
                .frame(width: Self.resetWidth, alignment: .trailing)
                .help(resetDescription ?? "")
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label) usage")
        .accessibilityValue(Self.accessibilityValue(for: window, now: now))
    }

    nonisolated static func percentCaption(_ value: Double?) -> String {
        UsageCenter.PlanWindow.percentCaption(value)
    }

    nonisolated static func accessibilityValue(
        for window: UsageCenter.PlanWindow,
        now: Date
    ) -> String {
        let usage: String
        if let percent = window.reportedUsedPercent {
            usage = "\(UsageCenter.PlanWindow.percentCaption(percent).dropLast()) percent used"
        } else {
            usage = "Usage unavailable"
        }
        return resetDescription(resetsAt: window.resetsAt, now: now)
            .map { "\(usage). \($0)" } ?? usage
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

    private var resetDescription: String? {
        Self.resetDescription(resetsAt: window.resetsAt, now: now)
    }

    /// Pure, so the switch and its boundary are testable without a view.
    ///
    /// `nonisolated` because it is: a `View` is main-actor isolated and its
    /// statics inherit that, which made a synchronous test call an isolation
    /// error under CI's stricter concurrency settings while building fine
    /// locally. Nothing here touches actor state.
    nonisolated static func resetCaption(
        resetsAt: Double?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: resetsAt)
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return nil }

        // Under an hour you are deciding whether to wait, so the countdown is
        // the answer.
        if remaining < 3_600 { return "in \(Int(remaining / 60))m" }
        if remaining < 43_200 { return "in \(Int(remaining / 3_600))h" }

        // Past that you are planning around it, and a clock time is the answer.
        // Minutes are kept only when they carry information: a limit that comes
        // back at 3 PM should say "3 PM", not "3:00 PM".
        let minute = calendar.component(.minute, from: date)
        let clock = minute == 0 ? "j" : "j:mm"
        let sameDay = calendar.isDate(date, inSameDayAs: now)
        // Today needs no day name; this week wants the weekday; beyond that
        // only the date is meaningful.
        let template = sameDay ? clock
            : (remaining < 6 * 86_400 ? "EEE \(clock)" : "MMM d")

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        // The same zone the "is this today" question was answered in. Setting
        // only the calendar left the formatter on the system zone, so a
        // caption could say one day while `isDate(inSameDayAs:)` had decided
        // another.
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// The same moment, spelled out, for the row's tooltip.
    ///
    /// The row has to stay narrow enough that the bar survives, so it says
    /// "Wed 3 PM". Hovering gives the unabbreviated sentence — this is
    /// information worth being able to read exactly, which is why it is
    /// available in full rather than only in shorthand.
    nonisolated static func resetDescription(
        resetsAt: Double?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0 else { return nil }
        let date = Date(timeIntervalSince1970: resetsAt)
        guard date > now else { return nil }

        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        let relative = RelativeDateTimeFormatter()
        relative.locale = .autoupdatingCurrent
        relative.unitsStyle = .full
        return "Resets \(formatter.string(from: date)) — \(relative.localizedString(for: date, relativeTo: now))"
    }
}
