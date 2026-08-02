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

struct TerminalProcessRecord: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let command: String
}

/// Collects `TerminalMeta` by shelling out to system tools. The parsing is
/// factored into pure static helpers so it is unit-testable without spawning
/// any processes.
enum TerminalMetaService: Sendable {
    /// How many process-tree levels to descend before giving up. A real shell
    /// to launcher to agent chain is only a few deep; the bound guards against
    /// a pathological (or cyclic) process tree.
    private static let maxDescentDepth = 12

    /// Per-invocation wall-clock budget. `lsof` can block on a wedged network
    /// mount; the watchdog terminates a stuck child so the collector stays fast.
    private static let processTimeout: DispatchTimeInterval = .milliseconds(1500)

    /// Cap the bytes retained from a targeted helper. The pipe is still fully
    /// drained so a noisy child cannot deadlock while exiting.
    private static let maxOutputBytes = 64 * 1024

    /// A process-table snapshot can legitimately be larger than one targeted
    /// helper response. It is still bounded to keep an idle refresh from
    /// becoming an unbounded allocation.
    private static let maxProcessSnapshotBytes = 1024 * 1024

    /// Keep one `lsof` argv and response bounded while still replacing the old
    /// per-terminal subprocess fan-out with a small number of batch probes.
    private static let portProbeBatchSize = 128
    private static let maxPortProbeOutputBytes = 512 * 1024

    private static let psPath = "/bin/ps"
    private static let lsofPath = "/usr/sbin/lsof"

    /// A bounded branch probe shared by the inventory metadata refresh. Git can
    /// otherwise wait forever on a disconnected network/FileProvider mount.
    static func gitBranch(at directory: URL) -> String? {
        guard let output = run(
            "/usr/bin/git",
            ["rev-parse", "--abbrev-ref", "HEAD"],
            currentDirectoryURL: directory
        ) else { return nil }
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    /// Foreground process name + listening ports for one shell PID.
    /// Retained for callers that need a one-off probe; inventory refreshes use
    /// the batched overload below.
    static func collect(pid: Int32) -> TerminalMeta {
        guard pid > 0 else { return .empty }
        return collect(pids: [pid])[pid] ?? .empty
    }

    /// Collect metadata for all owned terminal roots with one process-table
    /// snapshot and batched `lsof` calls. Duplicate roots are probed once.
    /// Every valid requested PID receives a value, even when a helper fails.
    static func collect(pids: [Int32]) -> [Int32: TerminalMeta] {
        let roots = Array(Set(pids.filter { $0 > 0 })).sorted()
        guard !roots.isEmpty else { return [:] }

        let snapshot = parseProcessSnapshot(
            run(
                psPath,
                ["-axo", "pid=,ppid=,command="],
                retainedOutputLimit: maxProcessSnapshotBytes
            ) ?? ""
        )
        let chains = processChains(rootPIDs: roots, recordsByPID: snapshot)
        let probedPIDs = Array(Set(chains.values.flatMap { $0 })).sorted()

        var portsByPID: [Int32: Set<Int>] = [:]
        for start in stride(from: 0, to: probedPIDs.count, by: portProbeBatchSize) {
            let end = min(start + portProbeBatchSize, probedPIDs.count)
            let joined = probedPIDs[start ..< end].map(String.init).joined(separator: ",")
            let output = run(
                lsofPath,
                ["-n", "-P", "-a", "-p", joined, "-iTCP", "-sTCP:LISTEN", "-Fn"],
                retainedOutputLimit: maxPortProbeOutputBytes
            ) ?? ""
            for (pid, ports) in parsePortsByPID(fromLsof: output) {
                portsByPID[pid, default: []].formUnion(ports)
            }
        }

        var result: [Int32: TerminalMeta] = [:]
        for root in roots {
            let chain = chains[root] ?? [root]
            let name = foregroundName(chain: chain, recordsByPID: snapshot)
            let ports = chain
                .reduce(into: Set<Int>()) { collected, pid in
                    collected.formUnion(portsByPID[pid] ?? [])
                }
                .sorted()
                .prefix(5)
            result[root] = TerminalMeta(processName: name, ports: Array(ports))
        }
        return result
    }

    // MARK: - Pure parsers (unit-testable without processes)

    /// Parse a single `ps -axo pid=,ppid=,command=` snapshot. The command may
    /// contain arbitrary spaces; only the first two whitespace-delimited
    /// columns are structural.
    static func parseProcessSnapshot(_ output: String) -> [Int32: TerminalProcessRecord] {
        var records: [Int32: TerminalProcessRecord] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard columns.count >= 2,
                  let pid = Int32(columns[0]), pid > 0,
                  let parentPID = Int32(columns[1]), parentPID >= 0 else { continue }
            let command = columns.count == 3 ? String(columns[2]) : ""
            records[pid] = TerminalProcessRecord(
                pid: pid,
                parentPID: parentPID,
                command: command
            )
        }
        return records
    }

    /// Reconstruct each root's foreground chain from one process snapshot.
    /// Choosing the greatest direct-child PID preserves the prior collector's
    /// most-recently-spawned heuristic without launching `pgrep` per level.
    static func processChains(
        rootPIDs: [Int32],
        recordsByPID: [Int32: TerminalProcessRecord]
    ) -> [Int32: [Int32]] {
        var childrenByParent: [Int32: [Int32]] = [:]
        for record in recordsByPID.values where record.pid != record.parentPID {
            childrenByParent[record.parentPID, default: []].append(record.pid)
        }

        var result: [Int32: [Int32]] = [:]
        for root in Set(rootPIDs.filter { $0 > 0 }) {
            var chain = [root]
            var current = root
            for _ in 0 ..< maxDescentDepth {
                guard let child = childrenByParent[current]?.max(),
                      !chain.contains(child) else { break }
                chain.append(child)
                current = child
            }
            result[root] = chain
        }
        return result
    }

    /// Unique, sorted, capped-at-5 TCP ports from `lsof -Fn` output.
    ///
    /// `-Fn` emits one field per line; only `n` (name) lines carry an address
    /// like `*:3000`, `127.0.0.1:8080`, or `[::1]:5432`. The port is the
    /// integer after the final colon. Lines with `->` are established peers,
    /// not listeners, and are skipped.
    static func parsePorts(fromLsof output: String) -> [Int] {
        var ports: Set<Int> = []
        for line in output.split(whereSeparator: \.isNewline) {
            if let port = port(fromLsofNameLine: line) { ports.insert(port) }
        }
        return Array(ports.sorted().prefix(5))
    }

    /// Associate `lsof -Fn` name fields with the most recent `p<PID>` header.
    static func parsePortsByPID(fromLsof output: String) -> [Int32: [Int]] {
        var currentPID: Int32?
        var portsByPID: [Int32: Set<Int>] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            if line.first == "p" {
                currentPID = Int32(line.dropFirst()).flatMap { $0 > 0 ? $0 : nil }
                continue
            }
            guard let currentPID,
                  let port = port(fromLsofNameLine: line) else { continue }
            portsByPID[currentPID, default: []].insert(port)
        }
        return portsByPID.mapValues { Array($0.sorted().prefix(5)) }
    }

    private static func port(fromLsofNameLine line: Substring) -> Int? {
        guard line.first == "n" else { return nil }
        let address = line.dropFirst()
        guard !address.contains("->"),
              let colon = address.lastIndex(of: ":") else { return nil }
        let portText = address[address.index(after: colon)...]
        guard let port = Int(portText), port > 0, port <= 65535 else { return nil }
        return port
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

    /// The agent CLIs the rail has something to say about, in precedence order.
    private static let agentMarkers: [(marker: String, display: String)] = [
        ("codex", "codex"),
        ("claude", "claude"),
        ("gemini", "gemini"),
        ("opencode", "opencode"),
        ("aider", "aider"),
    ]

    /// Interpreters that are never themselves the interesting program: what they
    /// are running is. Matched on the executable's basename.
    private static let runtimeWrappers: Set<String> = [
        "node", "nodejs", "bun", "deno", "npx", "pnpm", "yarn",
        "python", "python3", "uv", "uvx", "ruby", "perl",
    ]

    /// The parts of a command line that may legitimately *name* the program.
    ///
    /// Deliberately not the whole command. Matching a marker anywhere in the
    /// argv turns `zsh -c 'source ~/.claude/shell-snapshots/…'` — which is a
    /// real link in a real Claude chain, and a real shell everywhere else —
    /// into a Claude row, and would do the same for `vim ~/.claude/settings.json`.
    /// Only two things can name the program: the executable, and (when the
    /// executable is a runtime) the first non-flag argument after it, which is
    /// the script or package being run.
    ///
    /// Each candidate is reduced to its last **two** path components. One is too
    /// few — `…/@anthropic-ai/claude-code/cli.js` is named by its directory, not
    /// its file — and the whole path is too many, because any checkout under a
    /// folder with an agent's name in it would match.
    static func markerCandidates(fromCommand command: String) -> [String] {
        let tokens = command
            .split(whereSeparator: \.isWhitespace)
            .prefix(6)
            .map(String.init)
        guard let executable = tokens.first else { return [] }
        var candidates = [executable]
        if runtimeWrappers.contains((executable as NSString).lastPathComponent.lowercased()),
           let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            candidates.append(script)
        }
        return candidates.map { candidate in
            let components = candidate.split(separator: "/", omittingEmptySubsequences: true)
            return components.suffix(2).joined(separator: "/").lowercased()
        }
    }

    /// The agent CLI a command *is*, or `nil` when it is something else.
    ///
    /// Separate from `processName(fromCommand:)` because the chain scan needs to
    /// ask "is this link an agent?" without also being told "…and if not, it is
    /// called `sleep`".
    static func agentName(fromCommand command: String) -> String? {
        let candidates = markerCandidates(fromCommand: command)
        guard !candidates.isEmpty else { return nil }
        for (marker, display) in agentMarkers {
            let pattern = #"(^|[/._@-])"# + marker + #"([/._ -]|$)"#
            if candidates.contains(where: { $0.range(of: pattern, options: .regularExpression) != nil }) {
                return display
            }
        }
        return nil
    }

    /// Prefer a recognizable CLI name even when it is launched through a
    /// runtime wrapper (`node …/@openai/codex…`, for example), otherwise fall
    /// back to the executable's basename.
    static func processName(fromCommand command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let agent = agentName(fromCommand: trimmed) { return agent }
        guard let executable = trimmed.split(whereSeparator: \.isWhitespace).first else { return nil }
        return processName(fromComm: String(executable))
    }

    /// What to call a whole foreground chain, root first.
    ///
    /// The bug this exists for: `collect` used to name the row from
    /// `chain.last`, and a running agent is never the leaf. A real capture from
    /// a Kaisola broker terminal with `claude` in it —
    ///
    ///     69807 40496 /bin/zsh -i
    ///     69863 69807 claude
    ///     99646 69863 /bin/zsh -c source …/.claude/shell-snapshots/…
    ///     74322 99646 sleep 10
    ///
    /// — descends to `sleep`, so the row rendered the shell mark and Claude's
    /// coral never appeared. Codex is the same shape: `-zsh` → `node …/bin/codex`
    /// → `…/vendor/…/bin/codex` → `node ./mcp/server.cjs`, leaf `node`.
    ///
    /// So: scan the *whole* chain for an agent and prefer the **shallowest**
    /// match, because an agent is the ancestor of every helper it spawns — the
    /// `zsh -c` and the `sleep` above are Claude's children, not its peers. Only
    /// when no link is an agent does the leaf get to name the row, which is what
    /// keeps `zsh` → `npm` → `node` reading as the build it is.
    static func foregroundName(
        chain: [Int32],
        recordsByPID: [Int32: TerminalProcessRecord]
    ) -> String? {
        for pid in chain {
            if let command = recordsByPID[pid]?.command,
               let agent = agentName(fromCommand: command) {
                return agent
            }
        }
        for pid in chain.reversed() {
            if let command = recordsByPID[pid]?.command,
               let name = processName(fromCommand: command) {
                return name
            }
        }
        return nil
    }

    // MARK: - Bounded process runner

    /// Run a tool, returning its stdout (bounded) or `nil` on any failure.
    /// stderr/stdin are discarded and a watchdog terminates a stuck child.
    private static func run(
        _ path: String,
        _ arguments: [String],
        currentDirectoryURL: URL? = nil,
        retainedOutputLimit: Int = maxOutputBytes
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + processTimeout, execute: watchdog)

        let data = drain(
            pipe.fileHandleForReading,
            retainingAtMost: retainedOutputLimit
        )
        process.waitUntilExit()
        watchdog.cancel()

        return String(decoding: data, as: UTF8.self)
    }

    /// Continue reading after the retention cap so a helper can always exit;
    /// discard excess chunks instead of materializing unbounded output.
    private static func drain(_ handle: FileHandle, retainingAtMost limit: Int) -> Data {
        var retained = Data()
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 16 * 1024),
                      !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }
            let remaining = max(0, limit - retained.count)
            if remaining > 0 {
                retained.append(contentsOf: chunk.prefix(remaining))
            }
        }
        return retained
    }
}
