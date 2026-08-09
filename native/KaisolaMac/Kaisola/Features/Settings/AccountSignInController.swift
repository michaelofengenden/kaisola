import AppKit
import Foundation

/// Runs a provider's own login command from inside Settings, rather than
/// spawning a terminal in whichever project happened to be in front.
///
/// This is possible without a PTY because the flow is entirely knowable.
/// `claude auth login` prints its OAuth URL and then **blocks reading a pasted
/// code from stdin**:
///
/// ```
/// Opening browser to sign in…
/// If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?…
/// Paste code here if prompted >
/// ```
///
/// So Settings can run it over pipes: surface the URL as a button, take the
/// code in a text field, and write it back down stdin. Kaisola still never
/// handles the credential — the CLI writes it to the Keychain entry derived
/// from `CLAUDE_CONFIG_DIR`, which is exactly what keeps two subscriptions
/// apart. `codex login` runs its own local callback instead of asking for a
/// code, so the code field simply never unlocks and the process exits on its
/// own; both shapes are handled by watching the output rather than assuming
/// one.
@MainActor
final class AccountSignInController: ObservableObject {
    enum Phase: Equatable {
        case launching
        /// The browser step. `url` is nil only until the CLI has printed it.
        case awaitingBrowser(URL?)
        /// The CLI asked for a pasted code.
        case awaitingCode(URL?)
        case submitting
        case succeeded
        case failed(String)

        var url: URL? {
            switch self {
            case let .awaitingBrowser(url), let .awaitingCode(url): url
            default: nil
            }
        }

        var acceptsCode: Bool {
            if case .awaitingCode = self { return true }
            return false
        }

        var isFinished: Bool {
            switch self {
            case .succeeded, .failed: true
            default: false
            }
        }
    }

    /// How discovery ended. A shell that never answered is a different problem
    /// from a CLI that was never installed, so the two are not collapsed into
    /// one absent path.
    enum ExecutableLookup: Equatable, Sendable {
        case found(String)
        case missing
        case timedOut
        case couldNotStart(String)
        case cancelled
    }

    @Published private(set) var phase: Phase = .launching
    /// Everything the CLI has said, for the disclosure the sheet can show. Kept
    /// verbatim so a flow that changes shape is visible rather than swallowed.
    @Published private(set) var transcript = ""

    private var process: Process?
    private var input: FileHandle?
    /// The off-main lookup, held so an abandoned sheet can call it off.
    private var discovery: Task<Void, Never>?
    /// Ours, so the blocking read loop never occupies a cooperative thread.
    private let readQueue = DispatchQueue(label: "com.kaisola.account-signin.read")

    /// How long a login shell gets to say where the CLI is. Long enough for the
    /// heavy `.zshrc` people actually have — nvm and mise both re-exec things —
    /// and short enough that a shell blocked on its own prompt gives Settings
    /// back rather than keeping it.
    nonisolated static let executableProbeTimeout: TimeInterval = 12

    /// The first `https://` URL in a chunk of CLI output.
    ///
    /// Pure and static so the parsing rule is testable without spawning
    /// anything. Trailing punctuation is trimmed because the CLI prints the URL
    /// inside a sentence.
    nonisolated static func signInURL(in output: String) -> URL? {
        guard let range = output.range(of: "https://") else { return nil }
        let tail = output[range.lowerBound...]
        let token = tail.prefix { !$0.isWhitespace }
        let trimmed = token.drop(while: { _ in false })
            .reversed()
            .drop { ".,;:)\"'".contains($0) }
            .reversed()
        return URL(string: String(trimmed))
    }

    /// Whether the CLI is now blocked on a pasted code.
    nonisolated static func promptsForCode(_ output: String) -> Bool {
        output.lowercased().contains("paste code")
    }

    /// The provider's CLI tool name.
    nonisolated static func toolName(for provider: UsageAccountProfile.Provider) -> String {
        provider == .claude ? "claude" : "codex"
    }

    /// Where that CLI actually is on disk.
    ///
    /// A GUI-launched app inherits `/usr/bin:/bin`, not your shell's PATH — and
    /// `zsh -lc` does **not** source `~/.zshrc`, because `-c` is not
    /// interactive. Every PATH-extending installer people actually use — nvm,
    /// conda, npm global, mise — writes into `.zshrc`, so the CLI is invisible
    /// to a plain login shell. That is why sign-in failed with
    /// `zsh:1: command not found: claude` while the identical command works in
    /// any Kaisola terminal, which runs an *interactive* shell.
    ///
    /// So the tool is located once, through an interactive login shell with the
    /// same PATH prelude terminals get, and the login then runs against an
    /// absolute path where nothing can lose it again.
    ///
    /// Asking an interactive shell a question means running whatever that
    /// person's startup files do, which is unbounded work and can be a prompt
    /// that never returns. This used to run synchronously from the main actor,
    /// so a shell that hung froze the whole Settings window with it. It is now
    /// async, off the main actor, and bounded: the watchdog terminates a shell
    /// still thinking after `timeout`, and cancelling the task terminates it
    /// immediately.
    nonisolated static func resolveExecutable(
        _ tool: String,
        shell: String = "/bin/zsh",
        timeout: TimeInterval = executableProbeTimeout
    ) async -> ExecutableLookup {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: shell)
        probe.arguments = [
            "-ilc",
            NativeTerminalLaunchEnvironment.preferredPathPrelude() + "command -v \(tool)",
        ]
        let output = Pipe()
        probe.standardOutput = output
        probe.standardError = Pipe()
        // A startup file that reads stdin gets EOF rather than the app's own
        // descriptor to sit on.
        probe.standardInput = FileHandle.nullDevice
        do {
            try probe.run()
        } catch {
            return .couldNotStart(error.localizedDescription)
        }

        // Whichever of the two gets here first decides the answer: the watchdog
        // that gave up on a shell still thinking, or the drain that reached EOF.
        let outcome = UsageProcessCompletionGate()
        let watchdog = DispatchWorkItem {
            guard probe.isRunning, outcome.claim() else { return }
            probe.terminate()
        }
        // Not the drain's own queue: a serial queue sitting inside a blocking
        // read would never get around to running its own watchdog.
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let handle = output.fileHandleForReading
        let text = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                // Blocking reads belong on a thread we own, for the same reason
                // the sign-in's own read loop has one.
                DispatchQueue.global(qos: .userInitiated).async {
                    var data = Data()
                    while let chunk = try? handle.read(upToCount: 8_192), !chunk.isEmpty {
                        data.append(chunk)
                    }
                    probe.waitUntilExit()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
            }
        } onCancel: {
            probe.terminate()
        }
        watchdog.cancel()

        if Task.isCancelled { return .cancelled }
        // The gate is still unclaimed only if the shell answered on its own.
        guard outcome.claim() else { return .timedOut }
        // An interactive shell can print its own noise; the answer is the last
        // absolute path it emitted.
        guard let path = firstExecutablePath(in: text) else { return .missing }
        return .found(path)
    }

    /// What to say when discovery came back without a path.
    ///
    /// Pure, so the wording is testable without spawning anything, and split by
    /// outcome because the fixes are unrelated: install the CLI, versus find
    /// what in your shell startup is waiting for you.
    nonisolated static func lookupFailureMessage(
        tool: String,
        lookup: ExecutableLookup,
        timeout: TimeInterval = executableProbeTimeout
    ) -> String? {
        switch lookup {
        case .found, .cancelled:
            return nil
        case .missing:
            return "Kaisola couldn’t find the \(tool) command. Open a terminal and check that \(tool) runs there."
        case .timedOut:
            let seconds = Int(timeout.rounded())
            return """
            Your shell didn’t answer within \(seconds) seconds while Kaisola looked for \(tool). \
            Something in its startup files is probably waiting for input. \
            Run `command -v \(tool)` in a terminal to see where it stops.
            """
        case let .couldNotStart(reason):
            return "Kaisola couldn’t run your shell to look for \(tool): \(reason)"
        }
    }

    /// Pure, so the parsing survives whatever a person's shell prints at start.
    nonisolated static func firstExecutablePath(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && !$0.contains(" ") }
    }

    func start(profile: UsageAccountProfile) {
        let tool = Self.toolName(for: profile.provider)
        phase = .launching
        transcript += "Looking for the \(tool) command…\n"
        discovery?.cancel()
        discovery = Task { [weak self] in
            let lookup = await Self.resolveExecutable(tool)
            guard let self else { return }
            switch lookup {
            case let .found(executable):
                self.transcript += "Found \(executable).\n"
                self.launch(profile: profile, executable: executable)
            case .cancelled:
                // The sheet is going away; there is nobody left to tell.
                break
            case .missing, .timedOut, .couldNotStart:
                let message = Self.lookupFailureMessage(tool: tool, lookup: lookup) ?? ""
                // The transcript is where someone looks when the sentence above
                // it was not enough, so the diagnosis lands there too.
                self.transcript += message + "\n"
                self.phase = .failed(message)
            }
        }
    }

    private func launch(profile: UsageAccountProfile, executable: String) {
        // The account's directory has to exist before the CLI is pointed at it.
        //
        // `claude` creates its config directory; `codex` does not — it reads
        // `CODEX_HOME`, finds nothing, and stops with "Error loading
        // configuration: CODEX_HOME points to …, but that path does not exist".
        // Kaisola invented the path when the account was added, so creating it
        // is Kaisola's job rather than something to hand back to the user.
        //
        // 0700 because a config directory is about to hold credentials.
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: profile.expandedDirectory, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            phase = .failed(
                "Kaisola couldn’t create \(profile.directory): \(error.localizedDescription)"
            )
            return
        }

        let quotedTool = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let login = profile.provider == .claude
            ? "\(quotedTool) auth login --claudeai"
            : "\(quotedTool) login"
        let quoted = "'" + profile.expandedDirectory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "\(profile.provider.environmentKey)=\(quoted) \(login)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A plain login shell is enough now that the tool is an absolute path;
        // the interactive shell was only ever needed to *find* it.
        process.arguments = ["-lc", command]
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = stdin
        self.process = process
        self.input = stdin.fileHandleForWriting

        do {
            try process.run()
        } catch {
            phase = .failed("Kaisola couldn't start the sign-in: \(error.localizedDescription)")
            return
        }

        // One dedicated thread reads to EOF and then reaps the child.
        //
        // Deliberately *not* `readabilityHandler`. That is a block owned by the
        // pipe's own dispatch source, and dropping the pipe while the source is
        // mid-callback releases the block underneath it — which crashed the
        // whole app the first time this shipped: a `doDecrementSlow` on
        // `com.apple.NSFileHandle.fd_monitoring` corrupted the heap, and the
        // segfault then surfaced in an unrelated timer closure in the sidebar.
        // A blocking read on a thread we own has no such lifetime to get wrong;
        // `read(upToCount:)` also throws in Swift rather than raising the
        // uncatchable ObjC exception `availableData` raises on a closed
        // descriptor.
        let handle = output.fileHandleForReading
        readQueue.async { [weak self] in
            while let chunk = try? handle.read(upToCount: 8_192), !chunk.isEmpty {
                guard let text = String(data: chunk, encoding: .utf8) else { continue }
                Task { @MainActor [weak self] in self?.absorb(text) }
            }
            // EOF means the child closed its output; waiting now yields the
            // real status rather than racing it.
            process.waitUntilExit()
            let status = process.terminationStatus
            Task { @MainActor [weak self] in self?.finish(status: status) }
        }
    }

    private func absorb(_ text: String) {
        transcript += text
        guard !phase.isFinished else { return }
        let url = Self.signInURL(in: transcript) ?? phase.url
        phase = Self.promptsForCode(transcript) ? .awaitingCode(url) : .awaitingBrowser(url)
    }

    /// Hand the pasted code to the waiting CLI.
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let input else { return }
        phase = .submitting
        try? input.write(contentsOf: Data((trimmed + "\n").utf8))
    }

    func openSignInPage() {
        guard let url = phase.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func finish(status: Int32) {
        // The pipes are left attached on purpose. Detaching them here is what
        // released a live dispatch source out from under itself; the process is
        // already reaped, and letting it deallocate normally is safe.
        process = nil
        try? input?.close()
        input = nil
        guard !phase.isFinished else { return }
        if status == 0 {
            phase = .succeeded
            // Usage reads per account, so the new card can only appear once
            // something tells it to look again.
            NotificationCenter.default.post(name: .kaisolaUsageAccountsChanged, object: nil)
        } else {
            phase = .failed(Self.failureMessage(transcript: transcript, status: status))
        }
    }

    /// The CLI's own last words beat a status code the user cannot act on.
    nonisolated static func failureMessage(transcript: String, status: Int32) -> String {
        let lastLine = transcript
            .split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let lastLine, !lastLine.contains("Paste code") {
            return String(lastLine).trimmingCharacters(in: .whitespaces)
        }
        return "Sign-in did not complete (exit code \(status))."
    }

    /// Stop a sign-in the user abandoned; a login left running would hold the
    /// account's directory open and keep a zsh alive for the session.
    func cancel() {
        // Discovery may still be the only thing running: a sheet dismissed
        // while a shell is thinking should take that shell with it.
        discovery?.cancel()
        discovery = nil
        process?.terminate()
        process = nil
        try? input?.close()
        input = nil
    }
}
