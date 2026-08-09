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
    nonisolated static func resolveExecutable(
        _ tool: String,
        shell: String = "/bin/zsh"
    ) -> String? {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: shell)
        probe.arguments = [
            "-ilc",
            NativeTerminalLaunchEnvironment.preferredPathPrelude() + "command -v \(tool)",
        ]
        let output = Pipe()
        probe.standardOutput = output
        probe.standardError = Pipe()
        do {
            try probe.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        // An interactive shell can print its own noise; the answer is the last
        // absolute path it emitted.
        return firstExecutablePath(in: text)
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
        guard let executable = Self.resolveExecutable(tool) else {
            phase = .failed(
                "Kaisola couldn’t find the \(tool) command. Open a terminal and check that \(tool) runs there."
            )
            return
        }
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
            Self.drain(handle) { text in
                Task { @MainActor [weak self] in self?.absorb(text) }
            }
            // EOF means the child closed its output; waiting now yields the
            // real status rather than racing it.
            process.waitUntilExit()
            let status = process.terminationStatus
            Task { @MainActor [weak self] in self?.finish(status: status) }
        }
    }

    /// Read `handle` to EOF, handing over text as fast as it becomes whole.
    ///
    /// Split out and `nonisolated` so the loop that actually ships can be
    /// driven from a test with any chunk size, including sizes that land in the
    /// middle of a character.
    nonisolated static func drain(
        _ handle: FileHandle,
        chunkSize: Int = 8_192,
        receive: (String) -> Void
    ) {
        var decoder = IncrementalUTF8Decoder()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            let text = decoder.decode(chunk)
            if !text.isEmpty { receive(text) }
        }
        // Anything still held back at EOF is a truncated character, so it is
        // said now rather than dropped.
        let trailing = decoder.flush()
        if !trailing.isEmpty { receive(trailing) }
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

/// Turns a stream of pipe chunks into text without losing a character that
/// straddles a read boundary.
///
/// A read of the pipe ends wherever the kernel filled it, which is regularly
/// mid-character. `String(data:encoding:.utf8)` returns nil for such a chunk,
/// and the reader used to skip it — throwing away the whole 8 KiB, so a single
/// `…` landing on the boundary could take the OAuth URL or the CLI's error line
/// with it. Holding the unfinished character back until its remaining bytes
/// arrive costs at most three carried bytes.
struct IncrementalUTF8Decoder {
    /// The tail of the last chunk that began a character no one has finished.
    private var carry: [UInt8] = []

    /// The text that is whole as of this chunk.
    mutating func decode(_ chunk: Data) -> String {
        guard !chunk.isEmpty else { return "" }
        var bytes = carry
        bytes.append(contentsOf: chunk)
        let boundary = Self.wholePrefixLength(of: bytes)
        carry = Array(bytes[boundary...])
        bytes.removeLast(bytes.count - boundary)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Whatever is still carried when the stream ends. A character truncated at
    /// EOF is genuinely broken input, so it comes back as U+FFFD rather than
    /// disappearing — a mangled tail is visible, a missing one is not.
    mutating func flush() -> String {
        guard !carry.isEmpty else { return "" }
        let remainder = carry
        carry = []
        return String(decoding: remainder, as: UTF8.self)
    }

    /// How much of `bytes` can be decoded now, i.e. everything up to a character
    /// that has started but not finished.
    ///
    /// Bytes that are invalid rather than unfinished are deliberately left in
    /// the decodable prefix; `String(decoding:as:)` marks them and moves on,
    /// which is what keeps a corrupt byte from stalling the stream.
    static func wholePrefixLength(of bytes: [UInt8]) -> Int {
        // A character is at most four bytes, so the only one that can still be
        // in flight started within the last three.
        var index = bytes.count - 1
        let earliest = max(0, bytes.count - 4)
        while index >= earliest {
            let byte = bytes[index]
            // Continuation byte: the character it belongs to starts earlier.
            if byte & 0b1100_0000 == 0b1000_0000 {
                index -= 1
                continue
            }
            guard let width = characterWidth(startingWith: byte) else { return bytes.count }
            return bytes.count - index < width ? index : bytes.count
        }
        return bytes.count
    }

    /// How many bytes the character starting with `byte` occupies, or nil if it
    /// cannot start one.
    private static func characterWidth(startingWith byte: UInt8) -> Int? {
        switch byte {
        case 0x00...0x7F: 1
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: nil
        }
    }
}
