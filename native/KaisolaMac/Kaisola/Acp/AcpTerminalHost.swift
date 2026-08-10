import Foundation

/// Executes agent-requested terminals (`terminal/create` … `terminal/release`)
/// as child processes of the app, mirroring the Electron ACP terminal host.
/// Output is buffered with a bounded tail (oldest bytes dropped once past the
/// byte limit, `truncated` set), and exit status resolves any `wait_for_exit`
/// callers. Terminals are app-scoped like the chats that spawn them.
actor AcpTerminalHost {
    struct ExitStatus: Equatable, Sendable {
        let exitCode: Int32?
        let signal: String?
    }

    struct Snapshot: Equatable, Sendable {
        let output: String
        let truncated: Bool
        let exitStatus: ExitStatus?
        /// The child exited while a descendant still held the write end of the
        /// output pipe, so the exit was reported without an EOF. The buffer is
        /// sealed at that moment: whatever the descendant writes afterwards is
        /// read and dropped, never appended behind the reported exit.
        let outputDetached: Bool
    }

    static let defaultOutputByteLimit = 1_048_576
    /// Hard ceiling for adapter-requested output limits (mirrors Electron's
    /// 8 MiB clamp) — a hostile `outputByteLimit` cannot exhaust app memory.
    static let maxOutputByteLimit = 8 * 1_048_576
    /// How long a lingering descendant may keep the pipe open after the child
    /// exits before exit waiters are answered without an EOF.
    private static let lingeringOutputGrace: TimeInterval = 2
    private static let signalNames: [Int32: String] = [
        SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGKILL: "SIGKILL",
        SIGTERM: "SIGTERM", SIGPIPE: "SIGPIPE", SIGSEGV: "SIGSEGV", SIGABRT: "SIGABRT",
    ]

    /// Ordered traffic from the output pipe. The grace-period tick rides the
    /// same stream as the bytes, so it can never overtake a chunk that was
    /// already read.
    private enum OutputEvent: Sendable {
        case chunk(Data)
        case exitGraceExpired
    }

    private final class Entry {
        let process: Process
        var buffer = Data()
        var truncated = false
        var byteLimit: Int
        var exitStatus: ExitStatus?
        /// Exit reported by the termination handler, held until the pipe drains
        /// so `wait_for_exit` can never resolve ahead of the final output.
        var pendingExit: ExitStatus?
        /// The pipe itself reported EOF: the child and every descendant that
        /// inherited the write end are done writing.
        var eofReached = false
        /// A separate fact from EOF: the child exited and a descendant still
        /// held the write end when the grace period ran out. Output ends here
        /// because we stop trusting it, not because the writer finished.
        var outputDetached = false
        /// Closed at `finish`, so no byte can join the buffer behind an exit a
        /// `wait_for_exit` caller has already seen.
        var outputSealed = false
        var released = false
        var waiters: [CheckedContinuation<ExitStatus, Never>] = []

        init(process: Process, byteLimit: Int) {
            self.process = process
            self.byteLimit = byteLimit
        }
    }

    private var entries: [String: Entry] = [:]
    private var counter = 0

    /// Spawn a command. `env` pairs overlay the app environment; a relative or
    /// missing cwd is the caller's responsibility (the client confines it to the
    /// workspace before calling).
    func create(
        command: String,
        args: [String],
        env: [String: String],
        cwd: String,
        outputByteLimit: Int?
    ) throws -> String {
        counter += 1
        let id = "acpterm-\(counter)-\(UUID().uuidString.prefix(6))"
        let process = Process()
        // Run through the login shell so agent commands resolve PATH the same
        // way the user's own terminal would.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let joined = ([command] + args).map { Self.shellQuote($0) }.joined(separator: " ")
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", joined]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let requestedLimit = outputByteLimit ?? Self.defaultOutputByteLimit
        let entry = Entry(process: process, byteLimit: min(max(1, requestedLimit), Self.maxOutputByteLimit))
        entries[id] = entry

        // FileHandle may call the readability handler once with bytes and then
        // immediately with EOF. Spawning an independent Task for each callback
        // lets the EOF task overtake the final append on a busy executor. Feed
        // one AsyncStream instead: its single consumer commits every chunk in
        // callback order, then marks EOF only after the buffer is fully drained.
        let (outputStream, outputContinuation) = AsyncStream<OutputEvent>.makeStream()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outputContinuation.finish()
                return
            }
            outputContinuation.yield(.chunk(data))
        }
        Task { [weak self] in
            for await event in outputStream {
                switch event {
                case .chunk(let data):
                    await self?.append(id: id, data: data)
                case .exitGraceExpired:
                    await self?.markOutputDetached(id: id)
                }
            }
            await self?.markEOF(id: id)
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let status: ExitStatus = finished.terminationReason == .uncaughtSignal
                ? ExitStatus(exitCode: nil, signal: Self.signalNames[finished.terminationStatus] ?? "SIG\(finished.terminationStatus)")
                : ExitStatus(exitCode: finished.terminationStatus, signal: nil)
            Task { await self.recordExit(id: id, status: status) }
            // A grandchild that inherited the pipe can hold it open long past
            // the child's exit. Don't hold exit waiters hostage — after a grace
            // period the output is declared detached instead of complete.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.lingeringOutputGrace) {
                outputContinuation.yield(.exitGraceExpired)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            outputContinuation.finish()
            entries[id] = nil
            throw error
        }
        return id
    }

    func output(_ id: String) -> Snapshot? {
        guard let entry = entries[id] else { return nil }
        return Snapshot(
            output: String(decoding: entry.buffer, as: UTF8.self),
            truncated: entry.truncated,
            exitStatus: entry.exitStatus,
            outputDetached: entry.outputDetached
        )
    }

    func waitForExit(_ id: String) async -> ExitStatus? {
        guard let entry = entries[id] else { return nil }
        if let status = entry.exitStatus { return status }
        return await withCheckedContinuation { continuation in
            entry.waiters.append(continuation)
        }
    }

    /// SIGTERM now, SIGKILL if the process lingers.
    func kill(_ id: String) {
        guard let entry = entries[id], entry.exitStatus == nil, entry.process.isRunning else { return }
        let pid = entry.process.processIdentifier
        entry.process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { await self?.forceKillIfRunning(id: id, pid: pid) }
        }
    }

    /// Invalidate the id; a still-running process is killed first.
    func release(_ id: String) {
        guard let entry = entries[id] else { return }
        entry.released = true
        if entry.exitStatus == nil, entry.process.isRunning {
            kill(id)
        } else {
            entries[id] = nil
        }
    }

    func releaseAll() {
        for id in Array(entries.keys) { release(id) }
    }

    // MARK: - Internal

    private func append(id: String, data: Data) {
        // A sealed buffer belongs to an exit that callers have already been
        // told about; a lingering descendant's late bytes are dropped here.
        guard let entry = entries[id], !entry.outputSealed else { return }
        entry.buffer.append(data)
        if entry.buffer.count > entry.byteLimit {
            // Keep the tail on a UTF-8 boundary so decoding stays clean.
            var dropCount = entry.buffer.count - entry.byteLimit
            while dropCount < entry.buffer.count,
                  entry.buffer[entry.buffer.startIndex + dropCount] & 0xC0 == 0x80 {
                dropCount += 1
            }
            entry.buffer.removeFirst(dropCount)
            entry.truncated = true
        }
    }

    /// Exit lands here first; it only becomes visible once the output ended —
    /// by EOF, or by detaching from a descendant that outlived the child — so
    /// `terminal/output` after `wait_for_exit` never grows afterwards.
    private func recordExit(id: String, status: ExitStatus) {
        guard let entry = entries[id] else { return }
        entry.pendingExit = status
        if entry.eofReached || entry.outputDetached { finish(id: id, entry: entry) }
    }

    private func markEOF(id: String) {
        guard let entry = entries[id] else { return }
        entry.eofReached = true
        if entry.pendingExit != nil { finish(id: id, entry: entry) }
    }

    /// The grace period ran out with the pipe still open, so a descendant of
    /// the exited child holds the write end. Its later bytes keep being read —
    /// a writer blocked on a full pipe would wedge a background process the
    /// agent meant to keep alive — but `append` drops them from here on.
    private func markOutputDetached(id: String) {
        guard let entry = entries[id], !entry.eofReached else { return }
        entry.outputDetached = true
        if entry.pendingExit != nil { finish(id: id, entry: entry) }
    }

    private func finish(id: String, entry: Entry) {
        guard entry.exitStatus == nil, let status = entry.pendingExit else { return }
        entry.exitStatus = status
        // The snapshot a caller reads after `wait_for_exit` has to be the one
        // the exit was reported against, so the buffer closes with it.
        entry.outputSealed = true
        for waiter in entry.waiters { waiter.resume(returning: status) }
        entry.waiters.removeAll()
        if entry.released { entries[id] = nil }
    }

    private func forceKillIfRunning(id: String, pid: Int32) {
        guard let entry = entries[id], entry.exitStatus == nil else { return }
        _ = Darwin.kill(pid, SIGKILL)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
