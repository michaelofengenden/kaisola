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

/// A single ordered writer for the adapter's stdin. Calls to `send` enqueue
/// complete JSON-RPC frames, but the potentially backpressured descriptor work
/// happens in a separate task so it can never monopolize `AcpProcessTransport`.
/// Both queue capacity and each frame's total queue+write lifetime are bounded.
actor AcpStdinWriteQueue {
    enum OperationError: Error, Equatable {
        case deadlineExceeded
        case posix(Int32)
    }

    typealias WriteOperation = @Sendable (
        _ descriptor: Int32,
        _ data: Data,
        _ deadlineNanoseconds: UInt64
    ) async throws -> Void
    typealias MonotonicNow = @Sendable () -> UInt64

    struct Snapshot: Equatable, Sendable {
        let queuedFrameCount: Int
        let queuedBytes: Int
        let isWriting: Bool
        let isClosed: Bool
    }

    private struct Frame {
        let id: UInt64
        let data: Data
        let deadlineNanoseconds: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    static let defaultFrameDeadlineNanoseconds: UInt64 = 5_000_000_000
    static let defaultMaximumQueuedFrames = 64
    /// ACP accepts attachment-bearing requests much larger than a pipe. Keep a
    /// single legal request possible while bounding aggregate queued ownership.
    static let defaultMaximumQueuedBytes = 64 * 1_024 * 1_024
    private static let pollSliceMilliseconds: Int32 = 20

    private let descriptor: Int32
    private let frameDeadlineNanoseconds: UInt64
    private let maximumQueuedFrames: Int
    private let maximumQueuedBytes: Int
    private let writeOperation: WriteOperation
    private let monotonicNow: MonotonicNow
    private var frames: [Frame] = []
    private var queuedBytes = 0
    private var nextID: UInt64 = 0
    private var activeFrameID: UInt64?
    private var drainTask: Task<Void, Never>?
    private var closedError: AcpClientError?

    init(
        descriptor: Int32,
        frameDeadlineNanoseconds: UInt64 = AcpStdinWriteQueue.defaultFrameDeadlineNanoseconds,
        maximumQueuedFrames: Int = AcpStdinWriteQueue.defaultMaximumQueuedFrames,
        maximumQueuedBytes: Int = AcpStdinWriteQueue.defaultMaximumQueuedBytes,
        writeOperation: @escaping WriteOperation = AcpStdinWriteQueue.writeFrame,
        monotonicNow: @escaping MonotonicNow = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.descriptor = descriptor
        self.frameDeadlineNanoseconds = frameDeadlineNanoseconds
        self.maximumQueuedFrames = max(1, maximumQueuedFrames)
        self.maximumQueuedBytes = max(1, maximumQueuedBytes)
        self.writeOperation = writeOperation
        self.monotonicNow = monotonicNow
    }

    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        if let closedError { throw closedError }

        let wouldOverflowFrames = frames.count >= maximumQueuedFrames
        let wouldOverflowBytes = data.count > maximumQueuedBytes - min(queuedBytes, maximumQueuedBytes)
        if wouldOverflowFrames || wouldOverflowBytes {
            let error = AcpClientError.requestFailed(
                "The agent input queue reached its bounded capacity; the connection was closed. Restart the agent and retry."
            )
            failAll(with: error, cancelDrain: true)
            throw error
        }

        nextID &+= 1
        let id = nextID
        let now = monotonicNow()
        let (sum, overflow) = now.addingReportingOverflow(frameDeadlineNanoseconds)
        let deadline = overflow ? UInt64.max : sum
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                frames.append(Frame(
                    id: id,
                    data: data,
                    deadlineNanoseconds: deadline,
                    continuation: continuation
                ))
                queuedBytes += data.count
                startDrainIfNeeded()
            }
        } onCancel: {
            Task { await self.cancel(frameID: id) }
        }
    }

    /// Stop accepting writes, fail every waiter, and join the descriptor task
    /// before its fd may be closed or reused by a later adapter generation.
    func close(with error: AcpClientError = .notRunning) async {
        let existing = closedError ?? error
        let task = drainTask
        failAll(with: existing, cancelDrain: true)
        await task?.value
    }

    func snapshotForTesting() -> Snapshot {
        Snapshot(
            queuedFrameCount: frames.count,
            queuedBytes: queuedBytes,
            isWriting: activeFrameID != nil,
            isClosed: closedError != nil
        )
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !Task.isCancelled, closedError == nil, let frame = frames.first {
            activeFrameID = frame.id
            do {
                try await writeOperation(descriptor, frame.data, frame.deadlineNanoseconds)
            } catch {
                guard frames.contains(where: { $0.id == frame.id }) else { return }
                let clientError = Self.clientError(for: error)
                failAll(with: clientError, cancelDrain: false)
                return
            }

            guard closedError == nil, frames.first?.id == frame.id else { return }
            frames.removeFirst()
            queuedBytes -= frame.data.count
            activeFrameID = nil
            frame.continuation.resume()
        }
        activeFrameID = nil
        drainTask = nil
    }

    private func cancel(frameID: UInt64) {
        guard let index = frames.firstIndex(where: { $0.id == frameID }) else { return }
        if activeFrameID == frameID {
            failAll(
                with: .requestFailed(
                    "The agent connection closed while a request write was cancelled. Restart the agent and retry."
                ),
                cancelDrain: true
            )
            return
        }
        let frame = frames.remove(at: index)
        queuedBytes -= frame.data.count
        frame.continuation.resume(throwing: CancellationError())
    }

    private func failAll(with error: AcpClientError, cancelDrain: Bool) {
        if closedError == nil { closedError = error }
        let finalError = closedError ?? error
        let pending = frames
        frames.removeAll(keepingCapacity: false)
        queuedBytes = 0
        activeFrameID = nil
        let task = drainTask
        drainTask = nil
        if cancelDrain { task?.cancel() }
        for frame in pending { frame.continuation.resume(throwing: finalError) }
    }

    private static func clientError(for error: any Error) -> AcpClientError {
        if let clientError = error as? AcpClientError { return clientError }
        if error is CancellationError {
            return .requestFailed(
                "The agent connection closed while writing a request. Restart the agent and retry."
            )
        }
        if let operationError = error as? OperationError {
            switch operationError {
            case .deadlineExceeded:
                return .requestFailed(
                    "The agent stopped reading requests; the connection was closed at the stdin write deadline. Restart the agent and retry."
                )
            case let .posix(code):
                return .requestFailed(
                    "The agent input connection failed (errno \(code)); restart the agent and retry."
                )
            }
        }
        return .requestFailed(
            "The agent input connection failed; restart the agent and retry."
        )
    }

    /// The fd is nonblocking, so each write attempt returns immediately. `poll`
    /// sleeps only in short slices, preserving cancellation while the absolute
    /// per-frame deadline bounds both queue delay and descriptor backpressure.
    nonisolated static func writeFrame(
        descriptor: Int32,
        data: Data,
        deadlineNanoseconds: UInt64
    ) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadlineNanoseconds else {
                        throw OperationError.deadlineExceeded
                    }

                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count > 0 {
                        offset += count
                        continue
                    }
                    if count < 0, errno == EINTR { continue }
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                        let remaining = deadlineNanoseconds - now
                        let remainingMilliseconds = max(
                            UInt64(1),
                            (remaining + 999_999) / 1_000_000
                        )
                        let timeout = Int32(min(
                            UInt64(Self.pollSliceMilliseconds),
                            remainingMilliseconds
                        ))
                        let result = Darwin.poll(&readiness, 1, timeout)
                        if result < 0, errno == EINTR { continue }
                        if result < 0 { throw OperationError.posix(errno) }
                        let failedEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
                        if result > 0, readiness.revents & failedEvents != 0 {
                            throw OperationError.posix(EPIPE)
                        }
                        continue
                    }
                    throw OperationError.posix(count == 0 ? EPIPE : errno)
                }
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
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
    private var stdinWriter: AcpStdinWriteQueue?

    private let stdinFrameDeadlineNanoseconds: UInt64
    private let maximumQueuedStdinFrames: Int
    private let maximumQueuedStdinBytes: Int
    private let stdinWriteOperation: AcpStdinWriteQueue.WriteOperation

    private static let eofGrace: Duration = .milliseconds(100)
    private static let terminateGrace: Duration = .milliseconds(1_500)
    private static let killGrace: Duration = .milliseconds(500)

    init(
        stdinFrameDeadlineNanoseconds: UInt64 =
            AcpStdinWriteQueue.defaultFrameDeadlineNanoseconds,
        maximumQueuedStdinFrames: Int = AcpStdinWriteQueue.defaultMaximumQueuedFrames,
        maximumQueuedStdinBytes: Int = AcpStdinWriteQueue.defaultMaximumQueuedBytes,
        stdinWriteOperation: @escaping AcpStdinWriteQueue.WriteOperation =
            AcpStdinWriteQueue.writeFrame
    ) {
        self.stdinFrameDeadlineNanoseconds = stdinFrameDeadlineNanoseconds
        self.maximumQueuedStdinFrames = maximumQueuedStdinFrames
        self.maximumQueuedStdinBytes = maximumQueuedStdinBytes
        self.stdinWriteOperation = stdinWriteOperation
    }

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
        stdinWriter = AcpStdinWriteQueue(
            descriptor: spawned.stdinDescriptor,
            frameDeadlineNanoseconds: stdinFrameDeadlineNanoseconds,
            maximumQueuedFrames: maximumQueuedStdinFrames,
            maximumQueuedBytes: maximumQueuedStdinBytes,
            writeOperation: stdinWriteOperation
        )
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
        guard stdinHandle != nil, let stdinWriter, processID != nil else {
            throw AcpClientError.notRunning
        }
        let generation = runGeneration
        do {
            try await stdinWriter.send(data)
        } catch {
            if error is CancellationError { throw error }
            await failConnectionAfterStdinWrite(error, generation: generation)
            throw error
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

        let writer = stdinWriter
        stdinWriter = nil
        let input = stdinHandle
        stdinHandle = nil
        await writer?.close()
        try? input?.close()
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

    private func failConnectionAfterStdinWrite(_ error: any Error, generation: UInt64) async {
        guard generation == runGeneration, processID != nil,
              stdinWriter != nil || stdinHandle != nil else { return }
        let writer = stdinWriter
        stdinWriter = nil
        let input = stdinHandle
        stdinHandle = nil
        let clientError = (error as? AcpClientError) ?? .requestFailed(
            "The agent input connection failed; restart the agent and retry."
        )
        await writer?.close(with: clientError)
        try? input?.close()
        Task { [weak self] in await self?.terminate() }
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
        stdinWriter = nil
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
        guard makeNonblockingAndSuppressSIGPIPE(stdinPipe[1]) else {
            let code = errno
            closeDescriptors(stdinPipe + stdoutPipe + stderrPipe)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
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

    private static func makeNonblockingAndSuppressSIGPIPE(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { return false }
        return true
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
