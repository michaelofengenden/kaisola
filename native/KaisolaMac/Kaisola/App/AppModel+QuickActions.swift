import Foundation

/// Quick Actions execution. A quick action opens a fresh **owned** terminal in
/// the project directory and runs the command there, then leaves the shell
/// interactive — the same "run then hand back control" shape as a launched
/// agent CLI (`<command>; exec <shell> -il`).
///
/// Implementation note / deliberate tradeoff: this extension uses only the
/// public AppModel surface — `createTerminal(inDirectory:)` to spawn the shell
/// (which now RETURNS the new terminal's id), then `sendInput(_:to:)` to type
/// the command into exactly that shell. The command therefore lands on the
/// shell's stdin as if the user had typed it: it appears in the terminal
/// scrollback and the shell's history. That is intentional (an honest "type it
/// into a fresh shell" flow, not a hidden exec) and mirrors what a human does
/// when they open a terminal and run `npm test`.
extension AppModel {
    /// Open a fresh owned shell in `directory` and run `action.command` in it.
    /// No-op for a blank command. Requires the broker's controller lane; if it
    /// is unavailable, `createTerminal` surfaces the reason and returns nil, so
    /// nothing is typed.
    func runQuickAction(_ action: QuickAction, inProject directory: URL) async {
        let command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        await runInFreshTerminal(command, inDirectory: directory, settleNanoseconds: 0)
    }

    /// Open a fresh owned shell in the current project (or home) and run a
    /// one-off command there — the Settings sign-in card's path. A brief settle
    /// after the shell lands keeps a heavy rc file from eating the keystrokes.
    func runCommandInNewTerminal(_ command: String) async {
        let directory = currentProjectDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await runInFreshTerminal(trimmed, inDirectory: directory, settleNanoseconds: 500_000_000)
    }

    /// Shared spawn-then-type core. `createTerminal` returns the id of the shell
    /// it created, so we type into THAT terminal specifically — never the shared
    /// `selectedSessionID`, which the user could change between the spawn and the
    /// write. Waits (≤5s at 100ms) for the PTY to register as owned before
    /// typing; an optional settle absorbs slow rc files.
    private func runInFreshTerminal(_ command: String, inDirectory directory: URL, settleNanoseconds: UInt64) async {
        guard let sessionID = await createTerminal(inDirectory: directory) else { return }
        var waitedMillis = 0
        while waitedMillis < 5_000, !isOwned(sessionID) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitedMillis += 100
        }
        guard isOwned(sessionID) else { return }
        if settleNanoseconds > 0 { try? await Task.sleep(nanoseconds: settleNanoseconds) }
        sendInput(command + "\r", to: sessionID)
    }
}
