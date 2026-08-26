import AppKit
import SwiftUI

/// The transcript's live status word while a turn runs — what the shimmer
/// sweeps. Pure derivation from values, no conversation reference, the same
/// discipline as `QuietStatusDerivation`: every branch is a unit test rather
/// than a screenshot.
struct AcpThinkingStatus: Equatable, Sendable {
    /// Longest word the line carries. A tool title past this is cut on a
    /// character boundary and the view's trailing ellipsis doubles as its
    /// truncation tail, so `word` itself never holds one.
    static let maximumWordCharacters = 34

    let word: String
    let isActive: Bool

    /// VoiceOver speaks the fact, never the ellipsis the view draws.
    var spoken: String { "\(word), working" }

    static func derive(
        isRunning: Bool,
        isConnected: Bool,
        hasPendingPermission: Bool,
        lastRow: AcpTranscriptRow?
    ) -> AcpThinkingStatus? {
        // The line does not exist between turns; nothing animates at rest.
        // A detached adapter is not working either — the composer's
        // disconnect notice owns that state.
        guard isRunning, isConnected else { return nil }
        // While a permission waits, the permission bar is the only thing
        // that should be moving.
        guard !hasPendingPermission else { return nil }
        switch lastRow {
        case let .tool(call) where call.status == .inProgress:
            return AcpThinkingStatus(word: bounded(call.title), isActive: true)
        case .thought:
            return AcpThinkingStatus(word: "Thinking", isActive: true)
        default:
            return AcpThinkingStatus(word: "Working", isActive: true)
        }
    }

    private static func bounded(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Working" }
        guard trimmed.count > maximumWordCharacters else { return trimmed }
        return String(trimmed.prefix(maximumWordCharacters))
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A compact, shared description of a live agent turn. Keeping this beside the
/// transcript status means the pane header and every chat tab say the same
/// thing as the bottom of the conversation instead of falling back to an
/// anonymous spinner.
extension AcpConversation {
    var liveThinkingStatus: AcpThinkingStatus? {
        AcpThinkingStatus.derive(
            isRunning: isRunning,
            isConnected: isConnected,
            hasPendingPermission: pendingPermissionReview != nil,
            lastRow: visibleRows.last
        )
    }
}

// `AcpTranscriptSectionLabel` ("AGENT WORK" / "RESPONSE") is gone: it labeled
// every section boundary, and once bursts of tool calls fold into single
// expandable markers the alternation of prose and quiet work lines carries
// the same distinction without captions. `transcriptSection` itself remains —
// it is what the rhythm and the folding are derived from.

/// The mounted status line. It sits inside the transcript stack, between the
/// last row and the bottom sentinel, so the existing follow-stream scrolling
/// keeps it in view without new machinery.
struct AcpThinkingStatusRow: View {
    let status: AcpThinkingStatus
    /// The current turn's subagent headcount ("2 subagents, 1 working"),
    /// spoken beside the status word so checking on delegated work never
    /// requires scrolling back to find the chips. Nil when the turn has none.
    var subagentDetail: String?
    /// When the turn began, for the "Working… · 33s" clause. Ticks once per
    /// second through a periodic timeline — the one clock pattern the app
    /// allows (`UsageSettingsTab` precedent); never `.animation`. Nil (and in
    /// fixtures) renders no clock, keeping captures deterministic.
    var startedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "33s", then "4m 12s", then "1h 03m" — one number doing the work.
    static func elapsedLabel(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// The CI capture must never photograph a mid-sweep frame. Structural,
    /// like `TintFlowMotion.isPinned()`: every isolated fixture process pins
    /// the sweep, not just the visual-capture one.
    private var fixture: Bool {
        NativePreviewSettings.isIsolatedFixture(
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// One face for the shimmer mask and the static fallback, so a Reduce
    /// Motion change swaps them without moving a pixel.
    private static var font: NSFont {
        .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout, options: [:]).pointSize,
            weight: .medium
        )
    }

    var body: some View {
        // No ProgressView: the shimmer IS the progress signal, and the static
        // fallback deliberately adds no spinner either — the session card
        // header already carries the Reduce Motion hourglass for this fact,
        // and two indicators for one fact is the mistake being retired.
        HStack(spacing: 7) {
            if reduceMotion || fixture {
                Text(status.word + "…")
                    .font(Font(Self.font as CTFont))
                    .foregroundStyle(.kaisolaSecondary)
            } else {
                ShimmerTextView(text: status.word + "…", font: Self.font, animated: true)
                    .fixedSize()
            }
            if let startedAt, !fixture {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("· " + Self.elapsedLabel(from: startedAt, to: context.date))
                        .font(.callout)
                        .foregroundStyle(.kaisolaTertiary)
                        .monospacedDigit()
                }
            }
            if let subagentDetail {
                Text("· " + subagentDetail)
                    .font(.callout)
                    .foregroundStyle(.kaisolaSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            subagentDetail.map { "\(status.spoken), \($0)" } ?? status.spoken
        )
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("acp.thinkingStatus")
    }
}
