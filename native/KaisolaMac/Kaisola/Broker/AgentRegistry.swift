import Foundation

/// A CLI agent the native app can launch into an owned terminal. Mirrors the
/// Electron renderer's TERMINAL_CLI_PROFILES (src/lib/terminalAgent.ts) so the
/// two shells recognize and label the same agents.
struct AgentProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The command that boots the agent CLI, run through a login shell so the
    /// user's PATH and CLI configuration apply exactly as in Electron.
    let launchCommand: String
    /// SF Symbol shown on the session row.
    let symbol: String

    /// Provider-supported, project-scoped continuation command. This is a
    /// best-effort "most recent in this workspace/account" continuation, not
    /// an exact session-id claim. Custom agents stay nil until they expose an
    /// explicit safe contract.
    let resumeCommand: String?

    init(
        id: String,
        name: String,
        launchCommand: String,
        symbol: String,
        resumeCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.launchCommand = launchCommand
        self.symbol = symbol
        self.resumeCommand = resumeCommand
    }

    /// A shell terminal with no agent, for a plain command line.
    static let shell = AgentProfile(id: "shell", name: "Terminal", launchCommand: "", symbol: "terminal")
}

enum AgentRegistry {
    /// The agents shipped with the app, in display order. Keep in sync with
    /// src/lib/terminalAgent.ts TERMINAL_CLI_PROFILES.
    static let builtIns: [AgentProfile] = [
        AgentProfile(
            id: "claude-code", name: "Claude", launchCommand: "claude", symbol: "sparkle",
            resumeCommand: "claude --continue"
        ),
        AgentProfile(
            id: "codex", name: "Codex", launchCommand: "codex",
            symbol: "chevron.left.forwardslash.chevron.right",
            resumeCommand: "codex resume --last"
        ),
        AgentProfile(
            id: "opencode", name: "OpenCode", launchCommand: "opencode", symbol: "curlybraces",
            resumeCommand: "opencode --continue --mini --replay-limit 60"
        ),
        AgentProfile(
            id: "gemini", name: "Gemini", launchCommand: "gemini", symbol: "diamond",
            resumeCommand: "gemini --resume latest"
        ),
    ]

    /// Test-only seam: when set, `custom` reads this store instead of the
    /// default on-disk one, so registry tests never touch the real
    /// application-support file. `nil` in production. `nonisolated(unsafe)`
    /// because it is a single-threaded test hook, not shared runtime state, and
    /// keeping the registry non-isolated preserves every existing call site.
    nonisolated(unsafe) static var customStoreOverride: CustomAgentStore?

    /// Typed custom-agent load state retained at the launch boundary. Callers
    /// that need to explain a degraded registry can inspect the error; the
    /// launch-facing `custom` view below fails closed to no custom profiles.
    static var customLoadResult: Result<[AgentProfile], CustomAgentStore.StoreError> {
        (customStoreOverride ?? CustomAgentStore()).asProfiles()
    }

    /// User-registered terminal agents. A corrupt, partially decoded, or
    /// forward-version registry contributes no launchable profiles.
    static var custom: [AgentProfile] {
        (try? customLoadResult.get()) ?? []
    }

    /// Agents offered in the New menu, in display order: built-ins first, then
    /// the user's custom agents. Computed so freshly saved custom agents appear
    /// without a relaunch.
    static var all: [AgentProfile] {
        builtIns + custom
    }

    static func profile(id: String) -> AgentProfile? {
        all.first { $0.id == id }
    }

    /// Resolve the display name reported by live process detection back to the
    /// same profile used by sessions launched directly from Kaisola. This is
    /// how a plain terminal that later starts `claude`, `codex`, etc. gains the
    /// same agent-specific presentation without being recreated as a new PTY.
    static func profile(displayName: String?) -> AgentProfile? {
        guard let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else { return nil }
        return all.first {
            $0.name.compare(displayName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// Recognizes an agent from a stored session's launch metadata.
    static func profile(forCommand command: String?) -> AgentProfile? {
        guard let command, !command.isEmpty else { return nil }
        let leaf = command.split(separator: "/").last.map(String.init) ?? command
        let word = leaf.split(separator: " ").first.map(String.init) ?? leaf
        return all.first { $0.launchCommand == word }
    }
}

struct TerminalAgentDraftInputEffect: Equatable, Sendable {
    var textChanged = false
    var userInteracted = false
    var submitted = false
}

enum TerminalDraftRestoreDecision: Equatable, Sendable {
    case wait
    case restore
    case expire
}

enum TerminalDraftRestorePolicy {
    static let minimumSessionAge: TimeInterval = 3
    static let quietInterval: TimeInterval = 2
    static let timeout: TimeInterval = 30

    static func decision(
        startedAt: Date,
        lastOutputAt: Date,
        now: Date
    ) -> TerminalDraftRestoreDecision {
        let age = now.timeIntervalSince(startedAt)
        if age > timeout { return .expire }
        if age >= minimumSessionAge,
           now.timeIntervalSince(lastOutputAt) >= quietInterval {
            return .restore
        }
        return .wait
    }
}

/// Best-effort model of an interactive CLI composer. It observes only bytes
/// already authorized for an app-owned PTY; terminal query replies are ignored,
/// bracketed paste stays multiline, and the persisted value is strictly
/// bounded by the same private archive limit as native chat drafts.
struct TerminalAgentDraftTracker: Equatable, Sendable {
    static let maximumBytes = NativeWorkspaceStateStore.maximumDraftBytes

    private enum EscapeState: Equatable, Sendable {
        case none
        case escape
        case csi(String)
        case ss3
        case controlString
        case controlStringEscape
    }

    private(set) var text: String
    private var textByteCount: Int
    private var escapeState: EscapeState = .none
    private var bracketedPaste = false
    private var pastedCarriageReturn = false

    init(text: String = "") {
        self.text = Self.bounded(text)
        self.textByteCount = self.text.utf8.count
    }

    mutating func apply(_ input: String) -> TerminalAgentDraftInputEffect {
        let before = text
        var effect = TerminalAgentDraftInputEffect()

        // A real Escape key arrives alone. Do not treat the ESC prefix of an
        // arrow, terminal report, or bracketed paste as a composer clear.
        if input == "\u{1B}" {
            effect.userInteracted = true
            text = ""
            textByteCount = 0
            escapeState = .none
            bracketedPaste = false
            effect.textChanged = before != text
            return effect
        }

        for scalar in input.unicodeScalars {
            consume(scalar, effect: &effect)
        }
        effect.textChanged = before != text
        return effect
    }

    static func retypePayload(for text: String) -> String {
        bounded(text).replacingOccurrences(of: "\n", with: "\\\r")
    }

    private mutating func consume(
        _ scalar: UnicodeScalar,
        effect: inout TerminalAgentDraftInputEffect
    ) {
        switch escapeState {
        case .escape:
            switch scalar.value {
            case 0x5B: escapeState = .csi("") // ESC [
            case 0x4F: escapeState = .ss3 // ESC O
            case 0x5D, 0x50, 0x5F, 0x5E, 0x58: escapeState = .controlString
            default: escapeState = .none
            }
            return
        case let .csi(prefix):
            let value = scalar.value
            if (0x40...0x7E).contains(value) {
                let sequence = prefix + String(scalar)
                if sequence == "200~" { bracketedPaste = true }
                else if sequence == "201~" { bracketedPaste = false }
                else if Self.isEditingCSI(sequence) { effect.userInteracted = true }
                escapeState = .none
            } else if prefix.utf8.count < 32, value >= 0x20, value <= 0x3F {
                escapeState = .csi(prefix + String(scalar))
            } else {
                escapeState = .none
            }
            return
        case .ss3:
            // Application-cursor arrows and Home/End are user navigation.
            if ["A", "B", "C", "D", "F", "H"].contains(String(scalar)) {
                effect.userInteracted = true
            }
            escapeState = .none
            return
        case .controlString:
            if scalar.value == 0x07 { escapeState = .none }
            else if scalar.value == 0x1B { escapeState = .controlStringEscape }
            return
        case .controlStringEscape:
            escapeState = scalar.value == 0x5C ? .none : .controlString
            return
        case .none:
            break
        }

        if scalar.value != 0x0A, scalar.value != 0x0D {
            pastedCarriageReturn = false
        }

        switch scalar.value {
        case 0x1B:
            escapeState = .escape
        case 0x9B:
            escapeState = .csi("")
        case 0x90, 0x98, 0x9D, 0x9E, 0x9F:
            escapeState = .controlString
        case 0x03, 0x15: // Ctrl-C / Ctrl-U
            effect.userInteracted = true
            text = ""
            textByteCount = 0
            bracketedPaste = false
        case 0x7F, 0x08:
            effect.userInteracted = true
            if let last = text.last {
                textByteCount -= String(last).utf8.count
                text.removeLast()
            }
        case 0x0D, 0x0A:
            effect.userInteracted = true
            if bracketedPaste {
                if scalar.value == 0x0D {
                    append("\n")
                    pastedCarriageReturn = true
                } else if pastedCarriageReturn {
                    pastedCarriageReturn = false
                } else {
                    append("\n")
                }
            } else if text.hasSuffix("\\") {
                text.removeLast()
                textByteCount -= 1
                append("\n")
            } else {
                text = ""
                textByteCount = 0
                effect.submitted = true
            }
        case 0x09:
            if bracketedPaste {
                effect.userInteracted = true
                append("\t")
            }
        default:
            guard !CharacterSet.controlCharacters.contains(scalar) else { return }
            effect.userInteracted = true
            append(String(scalar))
        }
    }

    private mutating func append(_ value: String) {
        let added = value.utf8.count
        guard textByteCount + added <= Self.maximumBytes else { return }
        text.append(value)
        textByteCount += added
    }

    private static func isEditingCSI(_ sequence: String) -> Bool {
        guard let final = sequence.last else { return false }
        if "ABCDFH".contains(final) { return true }
        // Insert/Delete/Page/Home/End and modifier-bearing editing keys.
        return final == "~" && sequence != "200~" && sequence != "201~"
    }

    private static func bounded(_ value: String) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        result.reserveCapacity(maximumBytes)
        var byteCount = 0
        for character in value {
            let next = String(character)
            let nextBytes = next.utf8.count
            guard byteCount + nextBytes <= maximumBytes else { break }
            result.append(next)
            byteCount += nextBytes
        }
        return result
    }
}
