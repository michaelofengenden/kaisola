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

/// The mounted status line. It sits inside the transcript stack, between the
/// last row and the bottom sentinel, so the existing follow-stream scrolling
/// keeps it in view without new machinery.
struct AcpThinkingStatusRow: View {
    let status: AcpThinkingStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The CI capture must never photograph a mid-sweep frame.
    private var fixture: Bool {
        ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1"
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
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.spoken)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("acp.thinkingStatus")
    }
}
