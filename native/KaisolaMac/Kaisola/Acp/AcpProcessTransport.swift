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

/// Retains only the most recent adapter stderr bytes and turns them into safe,
/// user-facing failure detail. The pipe itself remains separate from ACP
/// stdout; this object is diagnostics-only and is replaced for every spawn.
final class AcpStderrTail: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let retainedByteCount: Int
        let didTruncate: Bool
        let failureDetail: String?
    }

    static let defaultByteLimit = 32 * 1_024

    private let byteLimit: Int
    private let sensitiveValues: [String]
    private let lock = NSLock()
    private var retained = Data()
    private var didTruncate = false

    init(
        byteLimit: Int = AcpStderrTail.defaultByteLimit,
        sensitiveValues: [String] = []
    ) {
        self.byteLimit = max(0, byteLimit)
        self.sensitiveValues = Array(Set(sensitiveValues.filter { $0.utf8.count >= 4 }))
            .sorted { $0.utf8.count > $1.utf8.count }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let total = retained.count + data.count
        if total > byteLimit { didTruncate = true }
        guard byteLimit > 0 else {
            retained.removeAll(keepingCapacity: false)
            return
        }
        if data.count >= byteLimit {
            retained = Data(data.suffix(byteLimit))
            return
        }
        let bytesToDiscard = max(0, total - byteLimit)
        if bytesToDiscard > 0 { retained.removeFirst(bytesToDiscard) }
        retained.append(data)
    }

    func failureDetail() -> String? {
        lock.lock()
        let data = retained
        let truncated = didTruncate
        lock.unlock()
        return Self.failureDetail(
            data: data,
            truncated: truncated,
            sensitiveValues: sensitiveValues
        )
    }

    func snapshotForTesting() -> Snapshot {
        lock.lock()
        let data = retained
        let truncated = didTruncate
        lock.unlock()
        return Snapshot(
            retainedByteCount: data.count,
            didTruncate: truncated,
            failureDetail: Self.failureDetail(
                data: data,
                truncated: truncated,
                sensitiveValues: sensitiveValues
            )
        )
    }

    private static func failureDetail(
        data: Data,
        truncated: Bool,
        sensitiveValues: [String]
    ) -> String? {
        guard !data.isEmpty else { return nil }
        // A tail can begin in the middle of `api_key=<value>`. Never expose
        // that orphaned prefix: when bytes were discarded, start at the next
        // complete line before applying content redaction.
        let displayData: Data
        if truncated, let newline = data.firstIndex(of: 0x0A) {
            displayData = Data(data[data.index(after: newline)...])
        } else if truncated {
            displayData = Data()
        } else {
            displayData = data
        }
        var text = String(decoding: displayData, as: UTF8.self)
        for value in sensitiveValues {
            text = text.replacingOccurrences(of: value, with: "[redacted]")
        }
        let replacements: [(String, String)] = [
            // OSC/CSI and remaining C0 control bytes cannot alter or obscure
            // the visible failure message.
            (#"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, ""),
            (#"\x1B\[[0-?]*[ -/]*[@-~]"#, ""),
            (#"(?i)(https?://)[^/\s:@]+:[^@\s/]+@"#, "$1[redacted]@"),
            (#"(?i)\b(authorization\s*:\s*(?:bearer|basic)\s+)[^\s,;]+"#, "$1[redacted]"),
            (#"(?i)\b(api[_-]?(?:key|token)|access[_-]?token|auth[_-]?token|password|passwd|secret)\s*[:=]\s*[^\s,;]+"#, "$1=[redacted]"),
            (#"(?i)\b(?:sk-[A-Za-z0-9_-]{12,}|gh[opsu]_[A-Za-z0-9_]{12,}|xox[abprs]-[A-Za-z0-9-]{12,}|AKIA[A-Z0-9]{16})\b"#, "[redacted]"),
            (#"(?i)(?:/Users/[^/\s]+|/home/[^/\s]+|[A-Z]:\\Users\\[^\\\s]+)(?:[/\\][^\s,;]*)?"#, "[local path]"),
            (#"(?i)(?:/private/(?:var|tmp)|/var|/tmp)(?:/[^\s,;]*)+"#, "[local path]"),
            (#"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"#, ""),
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = expression.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: replacement
            )
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if truncated, text.isEmpty {
            return "Earlier adapter stderr was truncated; no complete diagnostic line was safe to display."
        }
        guard !text.isEmpty else { return nil }
        if truncated {
            return "Earlier adapter stderr was truncated.\n\(text)"
        }
        return text
    }
}

/// Serializes every read from one adapter stderr pipe and provides a close
/// barrier before its tail is inspected. `FileHandle` does not join an
/// already-dispatched readability callback when its handler is cleared: that
/// callback can consume bytes from the descriptor and append them after the
/// actor has mistaken the tail for empty. Keeping both callback reads and the
/// final drain on this queue makes consumed bytes visible before `finish()`
/// returns; callbacks delivered after the barrier are harmless no-ops.
final class AcpStderrDrain: @unchecked Sendable {
    typealias ReadOperation = @Sendable () -> Data?

    private let queue = DispatchQueue(label: "app.kaisola.acp.stderr-drain")
    private let tail: AcpStderrTail
    private let readOperation: ReadOperation
    private var isFinished = false

    convenience init(descriptor: Int32, tail: AcpStderrTail) {
        self.init(tail: tail) {
            var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 { return Data(bytes.prefix(count)) }
                if count < 0, errno == EINTR { continue }
                return nil
            }
        }
    }

    init(tail: AcpStderrTail, readOperation: @escaping ReadOperation) {
        self.tail = tail
        self.readOperation = readOperation
    }

    func consumeReadable() {
        queue.sync { [self] in
            drainAvailableBytes()
        }
    }

    func finish() {
        queue.sync { [self] in
            guard !isFinished else { return }
            drainAvailableBytes()
            isFinished = true
        }
    }

    private func drainAvailableBytes() {
        guard !isFinished else { return }
        while let data = readOperation(), !data.isEmpty {
            tail.append(data)
        }
    }
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
    private var stderrTail: AcpStderrTail?
    private var stderrDrain: AcpStderrDrain?

    private let stdinFrameDeadlineNanoseconds: UInt64
    private let maximumQueuedStdinFrames: Int
    private let maximumQueuedStdinBytes: Int
    private let stdinWriteOperation: AcpStdinWriteQueue.WriteOperation
    private let stderrByteLimit: Int

    private static var eofGrace: Duration { .milliseconds(100) }
    private static var terminateGrace: Duration { .milliseconds(1_500) }
    private static var killGrace: Duration { .milliseconds(500) }
    private static var exitStatusGrace: Duration { .milliseconds(500) }

    init(
        stdinFrameDeadlineNanoseconds: UInt64 =
            AcpStdinWriteQueue.defaultFrameDeadlineNanoseconds,
        maximumQueuedStdinFrames: Int = AcpStdinWriteQueue.defaultMaximumQueuedFrames,
        maximumQueuedStdinBytes: Int = AcpStdinWriteQueue.defaultMaximumQueuedBytes,
        stdinWriteOperation: @escaping AcpStdinWriteQueue.WriteOperation =
            AcpStdinWriteQueue.writeFrame,
        stderrByteLimit: Int = AcpStderrTail.defaultByteLimit
    ) {
        self.stdinFrameDeadlineNanoseconds = stdinFrameDeadlineNanoseconds
        self.maximumQueuedStdinFrames = maximumQueuedStdinFrames
        self.maximumQueuedStdinBytes = maximumQueuedStdinBytes
        self.stdinWriteOperation = stdinWriteOperation
        self.stderrByteLimit = max(0, stderrByteLimit)
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
        let tail = AcpStderrTail(
            byteLimit: stderrByteLimit,
            sensitiveValues: Self.sensitiveEnvironmentValues(environment)
        )
        let drain = AcpStderrDrain(descriptor: spawned.stderrDescriptor, tail: tail)
        stderrHandle = stderr
        stderrTail = tail
        stderrDrain = drain
        // Drain stderr so a chatty adapter never blocks on a full pipe. Its
        // contents are diagnostics only; the protocol is stdout.
        stderr.readabilityHandler = { _ in
            drain.consumeReadable()
        }
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
        let data: Data? = try await Task.detached(priority: .userInitiated) {
            var bytes = [UInt8](repeating: 0, count: maximumBytes)
            let count = read(descriptor, &bytes, bytes.count)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { return Data() }
                throw AcpClientError.adapterExited(code: -1)
            }
            return Data(bytes.prefix(count))
        }.value
        guard let data else {
            // Capture the final stderr bytes only after the owned process group
            // has closed its pipe. Clean stderr preserves the existing EOF
            // contract; diagnostics become the failure detail readLoop exposes.
            let generation = runGeneration
            let tail = stderrTail
            await terminate()
            let recordedCode = await waitForTerminationCode(generation: generation)
            guard let detail = tail?.failureDetail() else { return nil }
            let code = recordedCode.map(String.init) ?? "unknown"
            throw AcpClientError.requestFailed(
                "The agent process exited (code \(code)). Adapter stderr:\n\(detail)"
            )
        }
        return data
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

    private func waitForTerminationCode(generation: UInt64) async -> Int32? {
        let deadline = ContinuousClock.now.advanced(by: Self.exitStatusGrace)
        while generation == runGeneration,
              terminationCode == nil,
              ContinuousClock.now < deadline {
            await Self.pause(.milliseconds(10))
        }
        guard generation == runGeneration else { return nil }
        return terminationCode
    }

    private func closeHandles() {
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        stderrHandle?.readabilityHandler = nil
        stderrDrain?.finish()
        try? stderrHandle?.close()
        stdinHandle = nil
        stdinWriter = nil
        stdoutHandle = nil
        stderrHandle = nil
        stderrDrain = nil
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
        guard makeNonblockingAndSuppressSIGPIPE(stdinPipe[1]),
              makeNonblocking(stderrPipe[0]) else {
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
        guard makeNonblocking(descriptor),
              Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { return false }
        return true
    }

    private static func makeNonblocking(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        return flags >= 0 && Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func sensitiveEnvironmentValues(_ environment: [String: String]) -> [String] {
        let sensitiveKeyFragments = [
            "API_KEY", "APIKEY", "AUTH", "CREDENTIAL", "OAUTH", "PASSWD", "PASSWORD",
            "PRIVATE_KEY", "SECRET", "TOKEN",
        ]
        return environment.compactMap { key, value in
            let normalizedKey = key.uppercased()
            guard sensitiveKeyFragments.contains(where: normalizedKey.contains) else { return nil }
            return value
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
