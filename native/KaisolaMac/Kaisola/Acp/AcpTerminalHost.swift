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
        let outputBufferStats: OutputBufferStats

        init(
            output: String,
            truncated: Bool,
            exitStatus: ExitStatus?,
            outputBufferStats: OutputBufferStats = .empty
        ) {
            self.output = output
            self.truncated = truncated
            self.exitStatus = exitStatus
            self.outputBufferStats = outputBufferStats
        }
    }

    /// Diagnostics for the pipe-to-actor backlog. Each queued element is no
    /// larger than `chunkByteLimit`, so the product of the two declared limits
    /// is a stable memory ceiling for the AsyncStream's retained payloads.
    struct OutputBufferStats: Equatable, Sendable {
        let chunkByteLimit: Int
        let bufferedChunkLimit: Int
        let bufferedByteCeiling: Int
        let peakBufferedChunks: Int
        let droppedChunks: UInt64
        let droppedBytes: UInt64

        static let empty = OutputBufferStats(
            chunkByteLimit: AcpTerminalHost.outputStreamChunkByteLimit,
            bufferedChunkLimit: AcpTerminalHost.outputStreamBufferedChunkLimit,
            bufferedByteCeiling: AcpTerminalHost.outputStreamBufferedByteCeiling,
            peakBufferedChunks: 0,
            droppedChunks: 0,
            droppedBytes: 0
        )
    }

    static let defaultOutputByteLimit = 1_048_576
    /// Hard ceiling for adapter-requested output limits (mirrors Electron's
    /// 8 MiB clamp) — a hostile `outputByteLimit` cannot exhaust app memory.
    static let maxOutputByteLimit = 8 * 1_048_576
    /// FileHandle callbacks are split before they enter the stream. Together
    /// these bounds cap retained AsyncStream payloads at 4 MiB per terminal.
    static let outputStreamChunkByteLimit = 64 * 1024
    static let outputStreamBufferedChunkLimit = 64
    static let outputStreamBufferedByteCeiling =
        outputStreamChunkByteLimit * outputStreamBufferedChunkLimit
    private static let signalNames: [Int32: String] = [
        SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGKILL: "SIGKILL",
        SIGTERM: "SIGTERM", SIGPIPE: "SIGPIPE", SIGSEGV: "SIGSEGV", SIGABRT: "SIGABRT",
    ]

    struct OutputChunk: Sendable {
        let sequence: UInt64
        let data: Data
    }

    struct OutputBufferState: Sendable {
        let stats: OutputBufferStats
        let latestDroppedSequence: UInt64?
    }

    struct OutputTailMetrics: Equatable, Sendable {
        let appendedBytes: UInt64
        let discardedBytes: UInt64
        let retainedBytes: Int
        let storedSegmentBytes: Int
        let peakRetainedBytes: Int
        let peakStoredSegmentBytes: Int
        let enqueuedSegments: UInt64
        let dequeuedSegments: UInt64
        let partialHeadAdvances: UInt64
        let bytesMovedWhileTrimming: UInt64
    }

    /// A byte-bounded deque whose front trim only releases whole segments or
    /// advances an offset into the first segment. Appending sustained output
    /// therefore never shifts the retained tail as `Data.removeFirst` does.
    struct SegmentedOutputTail {
        private let byteLimit: Int
        private var segments: [Data?] = Array(repeating: nil, count: 16)
        private var headIndex = 0
        private var segmentCount = 0
        private var headOffset = 0
        private var retainedBytes = 0
        private var storedSegmentBytes = 0
        private var peakRetainedBytes = 0
        private var peakStoredSegmentBytes = 0
        private var appendedBytes: UInt64 = 0
        private var discardedBytes: UInt64 = 0
        private var enqueuedSegments: UInt64 = 0
        private var dequeuedSegments: UInt64 = 0
        private var partialHeadAdvances: UInt64 = 0
        private(set) var truncated = false

        init(byteLimit: Int) {
            precondition(byteLimit > 0)
            self.byteLimit = byteLimit
        }

        var isEmpty: Bool { retainedBytes == 0 }

        var metrics: OutputTailMetrics {
            OutputTailMetrics(
                appendedBytes: appendedBytes,
                discardedBytes: discardedBytes,
                retainedBytes: retainedBytes,
                storedSegmentBytes: storedSegmentBytes,
                peakRetainedBytes: peakRetainedBytes,
                peakStoredSegmentBytes: peakStoredSegmentBytes,
                enqueuedSegments: enqueuedSegments,
                dequeuedSegments: dequeuedSegments,
                partialHeadAdvances: partialHeadAdvances,
                bytesMovedWhileTrimming: 0
            )
        }

        mutating func append(_ data: Data) {
            guard !data.isEmpty else { return }
            appendedBytes = Self.saturatingAdd(appendedBytes, UInt64(data.count))

            var payload = data
            if isEmpty, truncated {
                // A stream overflow may split a scalar between fixed-size
                // chunks. Start the new contiguous suffix at a UTF-8 boundary.
                var start = data.startIndex
                while start < data.endIndex, data[start] & 0xC0 == 0x80 {
                    start += 1
                }
                let skipped = data.distance(from: data.startIndex, to: start)
                if skipped > 0 {
                    discardedBytes = Self.saturatingAdd(discardedBytes, UInt64(skipped))
                    payload = Data(data[start..<data.endIndex])
                }
            }

            if !payload.isEmpty {
                enqueue(payload)
                retainedBytes += payload.count
            }

            if retainedBytes > byteLimit {
                discardFirst(retainedBytes - byteLimit)
                // Keep the retained tail on a clean UTF-8 boundary.
                while let byte = firstByte, byte & 0xC0 == 0x80 {
                    discardFirst(1)
                }
                truncated = true
            }

            peakRetainedBytes = max(peakRetainedBytes, retainedBytes)
            peakStoredSegmentBytes = max(peakStoredSegmentBytes, storedSegmentBytes)
        }

        /// Clears bytes before an AsyncStream overflow gap. The next append
        /// will re-establish a clean UTF-8 start for the new contiguous suffix.
        mutating func discardForDiscontinuity() {
            discardedBytes = Self.saturatingAdd(discardedBytes, UInt64(retainedBytes))
            while segmentCount > 0 { dequeueFirstSegment() }
            retainedBytes = 0
            headOffset = 0
            truncated = true
        }

        func materialized() -> Data {
            guard retainedBytes > 0 else { return Data() }
            var result = Data()
            result.reserveCapacity(retainedBytes)
            for offset in 0..<segmentCount {
                let index = (headIndex + offset) % segments.count
                guard let segment = segments[index] else { continue }
                let startOffset = offset == 0 ? headOffset : 0
                let start = segment.index(segment.startIndex, offsetBy: startOffset)
                result.append(contentsOf: segment[start..<segment.endIndex])
            }
            return result
        }

        private var firstByte: UInt8? {
            guard segmentCount > 0, let segment = segments[headIndex] else { return nil }
            return segment[segment.index(segment.startIndex, offsetBy: headOffset)]
        }

        private mutating func enqueue(_ data: Data) {
            if segmentCount == segments.count { grow() }
            let index = (headIndex + segmentCount) % segments.count
            segments[index] = data
            segmentCount += 1
            storedSegmentBytes += data.count
            enqueuedSegments = Self.saturatingAdd(enqueuedSegments, 1)
        }

        private mutating func discardFirst(_ requestedCount: Int) {
            var remaining = requestedCount
            while remaining > 0, segmentCount > 0 {
                guard let segment = segments[headIndex] else { break }
                let available = segment.count - headOffset
                let discarded = min(remaining, available)
                remaining -= discarded
                retainedBytes -= discarded
                discardedBytes = Self.saturatingAdd(discardedBytes, UInt64(discarded))

                if discarded == available {
                    dequeueFirstSegment()
                } else {
                    headOffset += discarded
                    partialHeadAdvances = Self.saturatingAdd(partialHeadAdvances, 1)
                }
            }
        }

        private mutating func dequeueFirstSegment() {
            guard segmentCount > 0, let segment = segments[headIndex] else { return }
            storedSegmentBytes -= segment.count
            segments[headIndex] = nil
            headIndex = (headIndex + 1) % segments.count
            segmentCount -= 1
            headOffset = 0
            dequeuedSegments = Self.saturatingAdd(dequeuedSegments, 1)
            if segmentCount == 0 { headIndex = 0 }
        }

        private mutating func grow() {
            var expanded: [Data?] = Array(repeating: nil, count: segments.count * 2)
            for offset in 0..<segmentCount {
                expanded[offset] = segments[(headIndex + offset) % segments.count]
            }
            segments = expanded
            headIndex = 0
        }

        private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : sum
        }
    }

    /// Owns the continuation and synchronously accounts for every overflow.
    /// Keeping this bookkeeping off the actor avoids replacing dropped stream
    /// elements with an unbounded queue of per-drop Tasks.
    final class OutputStreamBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncStream<OutputChunk>.Continuation
        private var nextSequence: UInt64 = 0
        private var peakBufferedChunks = 0
        private var droppedChunks: UInt64 = 0
        private var droppedBytes: UInt64 = 0
        private var latestDroppedSequence: UInt64?

        init(continuation: AsyncStream<OutputChunk>.Continuation) {
            self.continuation = continuation
        }

        func yield(_ data: Data) {
            guard !data.isEmpty else { return }
            var start = data.startIndex
            while start < data.endIndex {
                let end = min(start + AcpTerminalHost.outputStreamChunkByteLimit, data.endIndex)
                let payload = start == data.startIndex && end == data.endIndex
                    ? data
                    : Data(data[start..<end])
                lock.withLock {
                    let chunk = OutputChunk(sequence: nextSequence, data: payload)
                    nextSequence = nextSequence == .max ? .max : nextSequence + 1
                    switch continuation.yield(chunk) {
                    case .enqueued(let remainingCapacity):
                        let buffered = AcpTerminalHost.outputStreamBufferedChunkLimit - remainingCapacity
                        peakBufferedChunks = max(peakBufferedChunks, buffered)
                    case .dropped(let dropped):
                        peakBufferedChunks = AcpTerminalHost.outputStreamBufferedChunkLimit
                        droppedChunks = Self.saturatingAdd(droppedChunks, 1)
                        droppedBytes = Self.saturatingAdd(droppedBytes, UInt64(dropped.data.count))
                        latestDroppedSequence = dropped.sequence
                    case .terminated:
                        break
                    @unknown default:
                        break
                    }
                }
                start = end
            }
        }

        func finish() {
            lock.withLock { continuation.finish() }
        }

        func state() -> OutputBufferState {
            lock.withLock {
                OutputBufferState(
                    stats: OutputBufferStats(
                        chunkByteLimit: AcpTerminalHost.outputStreamChunkByteLimit,
                        bufferedChunkLimit: AcpTerminalHost.outputStreamBufferedChunkLimit,
                        bufferedByteCeiling: AcpTerminalHost.outputStreamBufferedByteCeiling,
                        peakBufferedChunks: peakBufferedChunks,
                        droppedChunks: droppedChunks,
                        droppedBytes: droppedBytes
                    ),
                    latestDroppedSequence: latestDroppedSequence
                )
            }
        }

        private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : sum
        }
    }

    private final class Entry {
        let process: Process
        var buffer: SegmentedOutputTail
        var exitStatus: ExitStatus?
        /// Exit reported by the termination handler, held until the pipe drains
        /// so `wait_for_exit` can never resolve ahead of the final output.
        var pendingExit: ExitStatus?
        var eofReached = false
        var released = false
        var waiters: [CheckedContinuation<ExitStatus, Never>] = []
        let outputStreamBuffer: OutputStreamBuffer
        /// Chunks at or below this sequence precede a stream overflow and can
        /// no longer be part of the contiguous retained suffix.
        var minimumRetainedSequence: UInt64 = 0

        init(process: Process, byteLimit: Int, outputStreamBuffer: OutputStreamBuffer) {
            self.process = process
            self.buffer = SegmentedOutputTail(byteLimit: byteLimit)
            self.outputStreamBuffer = outputStreamBuffer
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

        let (outputStream, outputStreamBuffer) = Self.makeOutputStream()
        let requestedLimit = outputByteLimit ?? Self.defaultOutputByteLimit
        let entry = Entry(
            process: process,
            byteLimit: min(max(1, requestedLimit), Self.maxOutputByteLimit),
            outputStreamBuffer: outputStreamBuffer
        )
        entries[id] = entry

        // FileHandle may call the readability handler once with bytes and then
        // immediately with EOF. Spawning an independent Task for each callback
        // lets the EOF task overtake the final append on a busy executor. Feed
        // one AsyncStream instead: its single consumer commits every chunk in
        // callback order, then marks EOF only after the buffer is fully drained.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outputStreamBuffer.finish()
                return
            }
            outputStreamBuffer.yield(data)
        }
        Task { [weak self] in
            for await chunk in outputStream {
                await self?.append(id: id, chunk: chunk)
            }
            await self?.markEOF(id: id)
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let status: ExitStatus = finished.terminationReason == .uncaughtSignal
                ? ExitStatus(exitCode: nil, signal: Self.signalNames[finished.terminationStatus] ?? "SIG\(finished.terminationStatus)")
                : ExitStatus(exitCode: finished.terminationStatus, signal: nil)
            Task { await self.recordExit(id: id, status: status) }
            // If a grandchild keeps the pipe open past exit, don't hold exit
            // waiters hostage — force completion after a grace period.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                Task { await self.forceEOF(id: id) }
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            outputStreamBuffer.finish()
            entries[id] = nil
            throw error
        }
        return id
    }

    func output(_ id: String) -> Snapshot? {
        guard let entry = entries[id] else { return nil }
        let bufferState = reconcileStreamOverflow(entry)
        return Snapshot(
            output: String(decoding: entry.buffer.materialized(), as: UTF8.self),
            truncated: entry.buffer.truncated,
            exitStatus: entry.exitStatus,
            outputBufferStats: bufferState.stats
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

    private func append(id: String, chunk: OutputChunk) {
        guard let entry = entries[id] else { return }
        _ = reconcileStreamOverflow(entry)
        guard chunk.sequence >= entry.minimumRetainedSequence else { return }

        entry.buffer.append(chunk.data)
    }

    /// Applies stream drops before exposing or appending output. Clearing the
    /// already-consumed prefix keeps snapshots a contiguous suffix rather than
    /// concatenating bytes from opposite sides of an overflow gap.
    private func reconcileStreamOverflow(_ entry: Entry) -> OutputBufferState {
        let state = entry.outputStreamBuffer.state()
        guard let latestDropped = state.latestDroppedSequence,
              latestDropped >= entry.minimumRetainedSequence else {
            return state
        }
        entry.buffer.discardForDiscontinuity()
        entry.minimumRetainedSequence = latestDropped == .max ? .max : latestDropped + 1
        return state
    }

    /// Exit lands here first; it only becomes visible once the pipe reached
    /// EOF, so `terminal/output` after `wait_for_exit` always sees full output.
    private func recordExit(id: String, status: ExitStatus) {
        guard let entry = entries[id] else { return }
        entry.pendingExit = status
        if entry.eofReached { finish(id: id, entry: entry) }
    }

    private func markEOF(id: String) {
        guard let entry = entries[id] else { return }
        entry.eofReached = true
        if entry.pendingExit != nil { finish(id: id, entry: entry) }
    }

    /// The grace-period fallback for grandchildren that hold the pipe open.
    private func forceEOF(id: String) {
        guard let entry = entries[id], entry.exitStatus == nil, entry.pendingExit != nil else { return }
        entry.eofReached = true
        finish(id: id, entry: entry)
    }

    private func finish(id: String, entry: Entry) {
        guard entry.exitStatus == nil, let status = entry.pendingExit else { return }
        entry.exitStatus = status
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

    /// Internal seam used by the host and by deterministic backlog stress
    /// tests. The newest elements survive overflow, matching tail semantics.
    static func makeOutputStream() -> (
        stream: AsyncStream<OutputChunk>,
        buffer: OutputStreamBuffer
    ) {
        let pair = AsyncStream<OutputChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(outputStreamBufferedChunkLimit)
        )
        return (pair.stream, OutputStreamBuffer(continuation: pair.continuation))
    }
}
