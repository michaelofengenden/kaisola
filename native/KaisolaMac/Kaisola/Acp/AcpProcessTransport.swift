import Darwin
import Foundation

/// Spawns an ACP adapter as a child process and carries newline-delimited
/// JSON-RPC over its stdin/stdout — the same framing the broker uses, so the
/// line-frame decoder is shared. stderr is drained to avoid a full-pipe stall.
protocol AcpByteTransport: Sendable {
    func start(command: String, arguments: [String], environment: [String: String], cwd: String) async throws
    func send(_ data: Data) async throws
    func receive(maximumBytes: Int) async throws -> Data?
    func terminate() async
    func exitCode() async -> Int32?
}

/// The adapter is deliberately placed in its own process group. Adapter-owned
/// app servers and stdio MCP servers inherit that group, so closing one ACP
/// connection can reap exactly its descendants without touching detached
/// broker sessions or their intentionally durable PTYs.
actor AcpProcessTransport: AcpByteTransport {
    private var processID: pid_t?
    private var processGroupID: pid_t?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var terminationCode: Int32?
    private var waitTask: Task<Void, Never>?
    private var runGeneration: UInt64 = 0
    private var terminatingGeneration: UInt64?

    private static let eofGrace: Duration = .milliseconds(100)
    private static let terminateGrace: Duration = .milliseconds(1_500)
    private static let killGrace: Duration = .milliseconds(500)

    func start(command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        try Task.checkCancellation()
        if let generation = terminatingGeneration {
            while terminatingGeneration == generation { await Self.pause(.milliseconds(20)) }
        }
        try Task.checkCancellation()
        guard processID == nil else { return }
        let spawned: SpawnedProcess
        do {
            spawned = try Self.spawn(
                command: command,
                arguments: arguments,
                environment: environment,
                cwd: cwd
            )
        } catch {
            throw AcpClientError.spawnFailed(error.localizedDescription)
        }

        runGeneration &+= 1
        processID = spawned.pid
        processGroupID = spawned.pid
        terminationCode = nil
        stdinHandle = FileHandle(fileDescriptor: spawned.stdinDescriptor, closeOnDealloc: true)
        stdoutHandle = FileHandle(fileDescriptor: spawned.stdoutDescriptor, closeOnDealloc: true)
        let stderr = FileHandle(fileDescriptor: spawned.stderrDescriptor, closeOnDealloc: true)
        stderrHandle = stderr
        // Drain stderr so a chatty adapter never blocks on a full pipe. Its
        // contents are diagnostics only; the protocol is stdout.
        stderr.readabilityHandler = { handle in _ = handle.availableData }
        waitTask = nil
    }

    private func recordTermination(_ code: Int32, generation: UInt64) {
        guard generation == runGeneration else { return }
        terminationCode = code
    }

    func send(_ data: Data) async throws {
        guard let stdinHandle else { throw AcpClientError.notRunning }
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            throw AcpClientError.adapterExited(code: terminationCode ?? -1)
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        guard let descriptor = stdoutHandle?.fileDescriptor else { throw AcpClientError.notRunning }
        return try await Task.detached(priority: .userInitiated) {
            var bytes = [UInt8](repeating: 0, count: maximumBytes)
            let count = read(descriptor, &bytes, bytes.count)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { return Data() }
                throw AcpClientError.adapterExited(code: -1)
            }
            return Data(bytes.prefix(count))
        }.value
    }

    /// Close the stdio ownership edge, then terminate the entire adapter group.
    /// A stubborn adapter gets a bounded SIGTERM grace before SIGKILL.
    func terminate() async {
        if let generation = terminatingGeneration {
            while terminatingGeneration == generation { await Self.pause(.milliseconds(20)) }
            return
        }
        guard let pid = processID, let group = processGroupID else {
            closeHandles()
            return
        }
        let generation = runGeneration
        terminatingGeneration = generation

        try? stdinHandle?.close()
        stdinHandle = nil
        // Keep the direct child unreaped until after the final group signal.
        // Its PID therefore cannot be recycled into an unrelated process group
        // between an ownership check and kill(2).
        if await waitForOwnedGroupExit(
            pid: pid, group: group, generation: generation, timeout: Self.eofGrace
        ) {
            finishTermination(pid: pid, generation: generation)
            return
        }
        _ = signalOwnedGroup(SIGTERM, pid: pid, group: group, generation: generation)
        if await waitForOwnedGroupExit(
            pid: pid, group: group, generation: generation, timeout: Self.terminateGrace
        ) {
            finishTermination(pid: pid, generation: generation)
            return
        }
        _ = signalOwnedGroup(SIGKILL, pid: pid, group: group, generation: generation)
        _ = await waitForOwnedGroupExit(
            pid: pid, group: group, generation: generation, timeout: Self.killGrace
        )
        finishTermination(pid: pid, generation: generation)
    }

    private func finishTermination(pid: pid_t, generation: UInt64) {
        closeHandles()
        processID = nil
        processGroupID = nil
        terminatingGeneration = nil
        reap(pid: pid, generation: generation)
    }

    func exitCode() async -> Int32? {
        terminationCode
    }

    private func closeHandles() {
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        stderrHandle?.readabilityHandler = nil
        try? stderrHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
    }

    private func signalOwnedGroup(_ signal: Int32, pid: pid_t, group: pid_t, generation: UInt64) -> Bool {
        guard ownsLeaderIdentity(pid: pid, group: group, generation: generation),
              ownedGroupHasLiveMembers(pid: pid, group: group, generation: generation) else { return false }
        return Darwin.kill(-group, signal) == 0 || errno == ESRCH
    }

    private func ownsLeaderIdentity(pid: pid_t, group: pid_t, generation: UInt64) -> Bool {
        let currentGroup = Darwin.getpgid(pid)
        let leaderIsOurUnreapedZombie = currentGroup < 0 && errno == ESRCH
        return generation == runGeneration
            && processID == pid
            && processGroupID == group
            && group == pid
            && (currentGroup == group || leaderIsOurUnreapedZombie)
    }

    private func ownedGroupHasLiveMembers(pid: pid_t, group: pid_t, generation: UInt64) -> Bool {
        guard ownsLeaderIdentity(pid: pid, group: group, generation: generation) else { return false }
        if Darwin.kill(-group, 0) == 0 { return true }
        // Darwin reports EPERM for a group containing only an unreaped zombie.
        // All live members of this app-created group retain our uid, so EPERM
        // cannot represent a live adapter-owned process we lack permission for.
        return errno != ESRCH && errno != EPERM
    }

    private func waitForOwnedGroupExit(
        pid: pid_t,
        group: pid_t,
        generation: UInt64,
        timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ownedGroupHasLiveMembers(pid: pid, group: group, generation: generation) {
            guard ContinuousClock.now < deadline else { return false }
            await Self.pause(.milliseconds(20))
        }
        return true
    }

    private func reap(pid: pid_t, generation: UInt64) {
        var status: Int32 = 0
        let immediate = Darwin.waitpid(pid, &status, WNOHANG)
        if immediate == pid {
            recordTermination(Self.terminationStatus(from: status), generation: generation)
            return
        }
        guard immediate == 0 || (immediate < 0 && errno == EINTR) else { return }
        waitTask = Task.detached(priority: .utility) { [weak self] in
            var deferredStatus: Int32 = 0
            var result: pid_t
            repeat {
                result = Darwin.waitpid(pid, &deferredStatus, 0)
            } while result < 0 && errno == EINTR
            guard result == pid else { return }
            await self?.recordTermination(Self.terminationStatus(from: deferredStatus), generation: generation)
        }
    }

    private static func pause(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration.timeInterval) {
                continuation.resume()
            }
        }
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : signal
    }

    private struct SpawnedProcess {
        let pid: pid_t
        let stdinDescriptor: Int32
        let stdoutDescriptor: Int32
        let stderrDescriptor: Int32
    }

    /// `Process` has no API for atomically assigning a process group. Use
    /// posix_spawn so the ownership boundary exists before adapter code runs.
    private static func spawn(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String
    ) throws -> SpawnedProcess {
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard makePipe(&stdinPipe), makePipe(&stdoutPipe), makePipe(&stderrPipe) else {
            closeDescriptors(stdinPipe + stdoutPipe + stderrPipe)
            throw POSIXError(.EMFILE)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            closeDescriptors(stdinPipe + stdoutPipe + stderrPipe)
            throw POSIXError(.EIO)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let actions = [
            posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO),
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd),
        ]
        let descriptors = stdinPipe + stdoutPipe + stderrPipe
        let closeActions = descriptors.map { posix_spawn_file_actions_addclose(&fileActions, $0) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU] {
            sigaddset(&defaultSignals, signal)
        }
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        guard actions.allSatisfy({ $0 == 0 }),
              closeActions.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setflags(&attributes, flags) == 0 else {
            closeDescriptors(descriptors)
            throw POSIXError(.EIO)
        }

        let argumentValues = [command] + arguments
        let environmentValues = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let argv = argumentValues.map { strdup($0) } + [nil]
        let envp = environmentValues.map { strdup($0) } + [nil]
        defer {
            argv.dropLast().forEach { free($0) }
            envp.dropLast().forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { variables in
                posix_spawn(
                    &pid,
                    command,
                    &fileActions,
                    &attributes,
                    UnsafeMutablePointer(mutating: arguments.baseAddress),
                    UnsafeMutablePointer(mutating: variables.baseAddress)
                )
            }
        }
        guard result == 0, pid > 1 else {
            closeDescriptors(descriptors)
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }

        // Parent owns the adapter's stdin writer and stdout/stderr readers.
        closeDescriptors([stdinPipe[0], stdoutPipe[1], stderrPipe[1]])
        return SpawnedProcess(
            pid: pid,
            stdinDescriptor: stdinPipe[1],
            stdoutDescriptor: stdoutPipe[0],
            stderrDescriptor: stderrPipe[0]
        )
    }

    private static func makePipe(_ descriptors: inout [Int32]) -> Bool {
        descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress) == 0
        }
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
