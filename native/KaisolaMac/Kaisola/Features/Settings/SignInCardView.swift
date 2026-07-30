import SwiftUI

extension Notification.Name {
    /// Posted when a Sign-in card button is tapped. The Settings window has no
    /// AppModel to drive a terminal directly, so it hands the command off via
    /// this notification; the root shell opens a terminal in the current project
    /// and types the command. `userInfo[SignInCardView.commandUserInfoKey]`
    /// carries the shell command to run.
    static let kaisolaRunInTerminal = Notification.Name("kaisolaRunInTerminal")
}

/// Settings ▸ Agents card explaining first-run CLI sign-in. Kaisola drives the
/// user's installed Claude / Codex CLIs, which authenticate themselves (device
/// code + browser), so the app can't sign in on their behalf — it can only open
/// a terminal and run the CLI's own login command. This card is pure UI: each
/// button hands its command to the injected `runInTerminal` closure and nothing
/// here spawns a process.
struct SignInCardView: View {
    /// Invoked with the shell command to run in a real terminal (e.g. the caller
    /// posts `.kaisolaRunInTerminal`). Pure UI — the card never spawns anything.
    let runInTerminal: (String) -> Void

    /// `userInfo` key the `.kaisolaRunInTerminal` notification carries its command
    /// under, so posters and observers agree on one string. Nonisolated: View
    /// statics otherwise infer MainActor and the delegate reads this from a
    /// Sendable observer closure (CI's stricter inference rejects that).
    nonisolated static let commandUserInfoKey = "command"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sign in to your CLIs", systemImage: "person.badge.key")
                .font(.headline)
            Text("Kaisola drives your installed Claude and Codex CLIs — sign in once per account directory. Sign-in runs in a real terminal here: a device-code flow prints in the terminal, and your browser may pop to finish it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    runInTerminal("claude setup-token")
                } label: {
                    Label("Sign in to Claude", systemImage: "sparkle")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    runInTerminal("codex login")
                } label: {
                    Label("Sign in to Codex", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.borderedProminent)
            }
            Text("Claude runs \u{201C}claude setup-token\u{201D}; Codex runs \u{201C}codex login\u{201D}. Each signs in to the CLAUDE_CONFIG_DIR / CODEX_HOME that applies to the active project — its per-project account if set, otherwise the app default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
