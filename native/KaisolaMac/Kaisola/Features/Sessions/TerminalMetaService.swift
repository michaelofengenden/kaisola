import Dispatch
import Foundation

/// Live per-session metadata shown on the session row: the foreground process
/// name and the TCP ports the session tree is listening on. Mirrors the
/// Electron per-session meta strip.
///
/// Every field is best-effort. A missing helper, a hung `lsof`, or a
/// permission failure degrades to empty meta — a row must never fail because a
/// probe misbehaved.
struct TerminalMeta: Equatable, Sendable {
    let processName: String?
    let ports: [Int]

    static let empty = TerminalMeta(processName: nil, ports: [])
}

/// Collects `TerminalMeta` by shelling out to system tools. The parsing is
/// factored into pure static helpers so it is unit-testable without spawning
/// any processes.
enum TerminalMetaService: Sendable {
    /// How many `pgrep -P` levels to descend before giving up. A real shell →
    /// launcher → agent chain is only a few deep; the bound guards against a
    /// pathological (or cyclic) process tree.
    private static let maxDescentDepth = 12

    /// Per-invocation wall-clock budget. `lsof` can block on a wedged network
    /// mount; the watchdog terminates a stuck child so the collector stays fast.
    private static let processTimeout: DispatchTimeInterval = .milliseconds(1500)

    /// Cap the bytes we decode from any one helper. The targeted tools emit
    /// only a few lines, so this only ever trips on a runaway.
    private static let maxOutputBytes = 64 * 1024

    private static let pgrepPath = "/usr/bin/pgrep"
    private static let psPath = "/bin/ps"
    private static let lsofPath = "/usr/sbin/lsof"

    /// Foreground process name + listening ports for a shell PID.
    ///
    /// Walks the descendant chain (`pgrep -P`, taking the most-recently-spawned
    /// child at each level as the foreground) and reads the deepest child's
    /// name (`ps -o comm=`). Listening ports come from a single `lsof` over the
    /// whole chain. Never throws — any failure yields empty (or partial) meta.
    static func collect(pid: Int32) -> TerminalMeta {
        guard pid > 0 else { return .empty }

        var chain: [Int32] = [pid]
        var current = pid
        for _ in 0 ..< maxDescentDepth {
            let output = run(pgrepPath, ["-P", String(current)]) ?? ""
            guard let child = mostRecentChild(fromPgrepOutput: output),
                  child != current,
                  !chain.contains(child) else { break }
            chain.append(child)
            current = child
        }

        let foreground = chain.last ?? pid
        let name = run(psPath, ["-o", "command=", "-p", String(foreground)])
            .flatMap { Self.processName(fromCommand: $0) }

        // One lsof for every PID in the chain — any of them may hold the socket.
        let joined = chain.map(String.init).joined(separator: ",")
        let lsofOutput = run(
            lsofPath,
            ["-n", "-P", "-a", "-p", joined, "-iTCP", "-sTCP:LISTEN", "-Fn"]
        ) ?? ""
        let ports = parsePorts(fromLsof: lsofOutput)

        return TerminalMeta(processName: name, ports: ports)
    }

    // MARK: - Pure parsers (unit-testable without processes)

    /// Unique, sorted, capped-at-5 TCP ports from `lsof -Fn` output.
    ///
    /// `-Fn` emits one field per line; only `n` (name) lines carry an address
    /// like `*:3000`, `127.0.0.1:8080`, or `[::1]:5432`. The port is the
    /// integer after the final colon. Lines with `->` are established peers,
    /// not listeners, and are skipped.
    static func parsePorts(fromLsof output: String) -> [Int] {
        var ports: Set<Int> = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.first == "n" else { continue }
            let address = line.dropFirst()
            guard !address.contains("->"),
                  let colon = address.lastIndex(of: ":") else { continue }
            let portText = address[address.index(after: colon)...]
            guard let port = Int(portText), port > 0, port <= 65535 else { continue }
            ports.insert(port)
        }
        return Array(ports.sorted().prefix(5))
    }

    /// The child PID to descend into from one `pgrep -P` block: the
    /// numerically-greatest PID (PIDs are handed out monotonically, so the
    /// largest is the most-recently spawned). `nil` ends the walk.
    static func mostRecentChild(fromPgrepOutput output: String) -> Int32? {
        output.split(whereSeparator: \.isNewline)
            .compactMap { Int32(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
            .max()
    }

    /// The deepest descendant across pre-collected `pgrep -P` outputs (one per
    /// descent level, in order). The last level that names any child is the
    /// foreground process. Pure form of `collect`'s live walk, for testing.
    static func deepestChild(fromPgrepOutputs outputs: [String]) -> Int32? {
        for output in outputs.reversed() {
            if let child = mostRecentChild(fromPgrepOutput: output) { return child }
        }
        return nil
    }

    /// Normalize a `ps -o comm=` value to a bare process name: trim, take the
    /// last path component (`/bin/zsh` → `zsh`), and drop a login-shell's
    /// leading `-` (`-zsh` → `zsh`). Empty input yields `nil`.
    static func processName(fromComm comm: String) -> String? {
        let trimmed = comm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var name = (trimmed as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    /// Prefer a recognizable CLI name even when it is launched through a
    /// runtime wrapper (`node …/@openai/codex…`, for example), otherwise fall
    /// back to the executable's basename.
    static func processName(fromCommand command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let markers: [(String, String)] = [
            ("codex", "codex"),
            ("claude", "claude"),
            ("gemini", "gemini"),
            ("opencode", "opencode"),
            ("aider", "aider"),
        ]
        for (marker, display) in markers {
            if lowered.range(of: #"(^|[/._@-])"# + marker + #"([/._ -]|$)"#, options: .regularExpression) != nil {
                return display
            }
        }
        guard let executable = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
        return processName(fromComm: String(executable))
    }

    // MARK: - Bounded process runner

    /// Run a tool, returning its stdout (bounded) or `nil` on any failure.
    /// stderr/stdin are discarded and a watchdog terminates a stuck child.
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + processTimeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let bounded = data.prefix(maxOutputBytes)
        return String(decoding: bounded, as: UTF8.self)
    }
}
