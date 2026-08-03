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

    @Published private(set) var phase: Phase = .launching
    /// Everything the CLI has said, for the disclosure the sheet can show. Kept
    /// verbatim so a flow that changes shape is visible rather than swallowed.
    @Published private(set) var transcript = ""

    private var process: Process?
    private var input: FileHandle?
    /// Ours, so the blocking read loop never occupies a cooperative thread.
    private let readQueue = DispatchQueue(label: "com.kaisola.account-signin.read")

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

    func start(profile: UsageAccountProfile) {
        let login = profile.provider == .claude ? "claude auth login --claudeai" : "codex login"
        let quoted = "'" + profile.expandedDirectory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Through a login shell, so the CLI resolves on the same PATH a
        // terminal would give it. Anything else finds `claude` only for users
        // whose install happens to sit in a system directory.
        let command = "\(profile.provider.environmentKey)=\(quoted) \(login)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
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
        process?.terminate()
        process = nil
        try? input?.close()
        input = nil
    }
}
