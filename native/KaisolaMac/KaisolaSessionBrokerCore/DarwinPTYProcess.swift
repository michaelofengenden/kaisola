import Darwin
import Dispatch
import Foundation

public struct DarwinPTYSpawnRequest: Equatable, Sendable {
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public let cwd: String
    public let columns: UInt16
    public let rows: UInt16

    public init(
        command: String,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        columns: UInt16,
        rows: UInt16
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.columns = columns
        self.rows = rows
    }
}

public struct DarwinPTYExit: Equatable, Sendable {
    public let rawWaitStatus: Int32

    public init(rawWaitStatus: Int32) {
        self.rawWaitStatus = rawWaitStatus
    }

    public var exitCode: Int32? {
        guard terminatingSignal == nil, (rawWaitStatus & 0x7f) == 0 else { return nil }
        return (rawWaitStatus >> 8) & 0xff
    }

    public var terminatingSignal: Int32? {
        let value = rawWaitStatus & 0x7f
        return value == 0 || value == 0x7f ? nil : value
    }
}

public enum DarwinPTYError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest(String)
    case systemCall(operation: String, code: Int32)
    case childSetupFailed(stage: DarwinPTYChildFailureStage, code: Int32)
    case childHandshakeTimedOut
    case childHandshakeMalformed
    case processExited
    case writeTimedOut
    case terminationTimedOut

    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            message
        case let .systemCall(operation, code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        case let .childSetupFailed(stage, code):
            "PTY child \(stage.description) failed: \(String(cString: strerror(code)))"
        case .childHandshakeTimedOut:
            "PTY child exec handshake timed out"
        case .childHandshakeMalformed:
            "PTY child returned a malformed exec handshake"
        case .processExited:
            "PTY process has exited"
        case .writeTimedOut:
            "PTY input write timed out"
        case .terminationTimedOut:
            "PTY process could not be reaped within the termination deadline"
        }
    }
}

extension DarwinPTYChildFailureStage {
    fileprivate var description: String {
        switch self {
        case .configuration: "configuration"
        case .loginTTY: "login_tty"
        case .changeDirectory: "chdir"
        case .execute: "exec"
        }
    }
}

/// Owns one fresh PTY session. The multithreaded broker never forks: it opens
/// the PTY in the parent and uses `posix_spawn` to re-enter its own executable's
/// minimal child mode, which performs the async-signal-sensitive terminal and
/// exec setup in a fresh process.
public final class DarwinPTYProcess: @unchecked Sendable {
    public typealias OutputHandler = @Sendable (Data) -> Void

    public let pid: pid_t

    private static let execHandshakeTimeoutMilliseconds: Int32 = 5_000
    private static let writeTimeoutMilliseconds: Int32 = 2_000
    private static let postKillReapNanoseconds: UInt64 = 2_000_000_000

    private let masterDescriptor: Int32
    private let outputHandler: OutputHandler
    private let outputQueue: DispatchQueue
    private let waitQueue: DispatchQueue
    private let outputSource: DispatchSourceRead
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var outputOpen = true
        var outputClosed = false
        var leaderExit: DarwinPTYExit?
        var exit: DarwinPTYExit?
        var exitWaiters: [CheckedContinuation<DarwinPTYExit, Never>] = []
        var ownedDescendants = Set<pid_t>()
        var terminationAttemptID: UUID?
        var terminationTask: Task<Result<DarwinPTYExit, DarwinPTYError>, Never>?
    }

    private struct TerminationTargets: Sendable {
        let leader: pid_t
        let leaderGroup: pid_t?
        let foregroundGroup: pid_t?
        let descendants: [pid_t]
    }

    private init(pid: pid_t, masterDescriptor: Int32, outputHandler: @escaping OutputHandler) {
        self.pid = pid
        self.masterDescriptor = masterDescriptor
        self.outputHandler = outputHandler
        self.outputQueue = DispatchQueue(label: "com.kaisola.session-broker.pty-output-\(pid)")
        self.waitQueue = DispatchQueue(label: "com.kaisola.session-broker.pty-wait-\(pid)")

        let source = DispatchSource.makeReadSource(
            fileDescriptor: masterDescriptor,
            queue: outputQueue
        )
        self.outputSource = source
        source.setEventHandler { [weak self] in self?.drainOutput() }
        source.setCancelHandler { [weak self] in
            _ = Darwin.close(masterDescriptor)
            self?.recordOutputClosed()
        }
        source.activate()

        waitQueue.async { [self] in
            var status = Int32(0)
            var result: pid_t
            repeat {
                result = Darwin.waitpid(pid, &status, 0)
            } while result < 0 && errno == EINTR
            if result == pid {
                recordLeaderExit(DarwinPTYExit(rawWaitStatus: status))
            } else {
                // ECHILD means the process was already reaped by a host-level
                // SIGCHLD policy. Preserve a stable observed completion.
                recordLeaderExit(DarwinPTYExit(rawWaitStatus: 0))
            }
        }
    }

    public static func spawn(
        _ request: DarwinPTYSpawnRequest,
        brokerExecutablePath: String? = nil,
        onOutput: @escaping OutputHandler
    ) async throws -> DarwinPTYProcess {
        try validate(request)
        let helperPath = try resolveBrokerExecutablePath(brokerExecutablePath)
        let payload = try DarwinPTYChild.encodedPayload(.init(
            command: request.command,
            arguments: request.arguments,
            environment: request.environment,
            cwd: request.cwd
        ))

        var windowSize = winsize()
        windowSize.ws_col = request.columns
        windowSize.ws_row = request.rows
        var master = Int32(-1)
        var slave = Int32(-1)
        guard Darwin.openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            throw systemError("openpty")
        }
        var configurationPipe = [Int32](repeating: -1, count: 2)
        var statusPipe = [Int32](repeating: -1, count: 2)
        guard makePipe(&configurationPipe), makePipe(&statusPipe) else {
            let code = errno
            closeDescriptors([master, slave] + configurationPipe + statusPipe)
            throw DarwinPTYError.systemCall(operation: "pipe", code: code)
        }

        let allDescriptors = [master, slave] + configurationPipe + statusPipe
        guard makeNonblocking(master),
              suppressSIGPIPE(master),
              makeNonblocking(configurationPipe[1]),
              suppressSIGPIPE(configurationPipe[1]),
              makeNonblocking(statusPipe[0]) else {
            let code = errno
            closeDescriptors(allDescriptors)
            throw DarwinPTYError.systemCall(operation: "fcntl", code: code)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            closeDescriptors(allDescriptors)
            throw DarwinPTYError.systemCall(operation: "posix_spawn initialization", code: EIO)
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let duplicateActions = [
            posix_spawn_file_actions_adddup2(
                &fileActions,
                slave,
                DarwinPTYChild.slaveDescriptor
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                configurationPipe[0],
                DarwinPTYChild.configurationDescriptor
            ),
            posix_spawn_file_actions_adddup2(
                &fileActions,
                statusPipe[1],
                DarwinPTYChild.statusDescriptor
            ),
        ]
        let closeActions = allDescriptors.map {
            posix_spawn_file_actions_addclose(&fileActions, $0)
        }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU] {
            sigaddset(&defaultSignals, signal)
        }
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        guard duplicateActions.allSatisfy({ $0 == 0 }),
              closeActions.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setflags(&attributes, flags) == 0 else {
            closeDescriptors(allDescriptors)
            throw DarwinPTYError.systemCall(operation: "posix_spawn configuration", code: EIO)
        }

        let argumentStorage: [UnsafeMutablePointer<CChar>?] = [
            strdup(helperPath), strdup("--pty-child"), nil,
        ]
        let environmentStorage: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argumentStorage.dropLast().forEach { free($0) }
            environmentStorage.dropLast().forEach { free($0) }
        }

        var childPID = pid_t(0)
        let spawnResult = helperPath.withCString { path in
            argumentStorage.withUnsafeBufferPointer { arguments in
                environmentStorage.withUnsafeBufferPointer { environment in
                    posix_spawn(
                        &childPID,
                        path,
                        &fileActions,
                        &attributes,
                        UnsafeMutablePointer(mutating: arguments.baseAddress),
                        UnsafeMutablePointer(mutating: environment.baseAddress)
                    )
                }
            }
        }
        guard spawnResult == 0, childPID > 1 else {
            closeDescriptors(allDescriptors)
            throw DarwinPTYError.systemCall(
                operation: "posix_spawn PTY child",
                code: spawnResult == 0 ? EIO : spawnResult
            )
        }

        closeDescriptors([slave, configurationPipe[0], statusPipe[1]])
        do {
            try writeAll(
                payload,
                to: configurationPipe[1],
                timeoutMilliseconds: execHandshakeTimeoutMilliseconds
            )
            _ = Darwin.close(configurationPipe[1])
            try awaitExecHandshake(
                from: statusPipe[0],
                timeoutMilliseconds: execHandshakeTimeoutMilliseconds
            )
            _ = Darwin.close(statusPipe[0])
            return DarwinPTYProcess(
                pid: childPID,
                masterDescriptor: master,
                outputHandler: onOutput
            )
        } catch {
            closeDescriptors([configurationPipe[1], statusPipe[0], master])
            reapFailedSpawn(childPID)
            throw error
        }
    }

    public func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        guard withLock({ state.outputOpen && state.leaderExit == nil }) else {
            throw DarwinPTYError.processExited
        }
        try Self.writeAll(
            data,
            to: masterDescriptor,
            timeoutMilliseconds: Self.writeTimeoutMilliseconds
        )
    }

    public func resize(columns: UInt16, rows: UInt16) throws {
        guard columns > 0, rows > 0 else {
            throw DarwinPTYError.invalidRequest("PTY dimensions must be nonzero")
        }
        guard withLock({ state.outputOpen && state.leaderExit == nil }) else {
            throw DarwinPTYError.processExited
        }
        var windowSize = winsize()
        windowSize.ws_col = columns
        windowSize.ws_row = rows
        guard Darwin.ioctl(masterDescriptor, TIOCSWINSZ, &windowSize) == 0 else {
            throw Self.systemError("ioctl(TIOCSWINSZ)")
        }
    }

    /// Sends a signal to the PTY's current foreground process group. This is
    /// the correct target for job-controlled shells whose foreground command
    /// is not the shell leader itself.
    public func send(signal: Int32) throws {
        guard signal > 0, signal < NSIG else {
            throw DarwinPTYError.invalidRequest("invalid POSIX signal")
        }
        guard withLock({ state.outputOpen && state.leaderExit == nil }) else {
            throw DarwinPTYError.processExited
        }
        if signal == SIGKILL {
            let targets = terminationTargets()
            withLock { state.ownedDescendants.formUnion(targets.descendants) }
            self.signal(targets: targets, with: SIGKILL)
            guard Self.waitForPIDsGoneBlocking(
                Set(targets.descendants),
                timeoutNanoseconds: Self.postKillReapNanoseconds
            ) else {
                throw DarwinPTYError.terminationTimedOut
            }
            withLock { state.ownedDescendants.subtract(targets.descendants) }
            completeExitIfReady()
            return
        }
        let foregroundGroup = Darwin.tcgetpgrp(masterDescriptor)
        guard foregroundGroup > 1 else {
            throw Self.systemError("tcgetpgrp")
        }
        guard Darwin.kill(-foregroundGroup, signal) == 0 else {
            throw Self.systemError("kill foreground process group")
        }
    }

    public func waitForExit() async -> DarwinPTYExit {
        if let exit = withLock({
            state.ownedDescendants.isEmpty ? state.exit : nil
        }) { return exit }
        return await withCheckedContinuation { continuation in
            let completed = withLock { () -> DarwinPTYExit? in
                if let exit = state.exit, state.ownedDescendants.isEmpty { return exit }
                state.exitWaiters.append(continuation)
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }

    /// Terminates the owned foreground job and shell, escalates to SIGKILL
    /// after the caller's grace interval, and does not return until the leader
    /// is reaped and captured descendants are gone. Repeated and concurrent
    /// calls share one result.
    public func terminate(
        graceNanoseconds: UInt64 = 500_000_000
    ) async throws -> DarwinPTYExit {
        let attempt = withLock { () -> (
            UUID?, Task<Result<DarwinPTYExit, DarwinPTYError>, Never>
        ) in
            if let exit = state.exit, state.ownedDescendants.isEmpty {
                return (nil, Task { .success(exit) })
            }
            if let existing = state.terminationTask {
                return (state.terminationAttemptID, existing)
            }
            let attemptID = UUID()
            let created = Task { [self] in
                await performTermination(graceNanoseconds: graceNanoseconds)
            }
            state.terminationAttemptID = attemptID
            state.terminationTask = created
            return (attemptID, created)
        }
        let result = await attempt.1.value
        if case .failure = result, let attemptID = attempt.0 {
            withLock {
                guard state.terminationAttemptID == attemptID else { return }
                state.terminationAttemptID = nil
                state.terminationTask = nil
            }
        }
        return try result.get()
    }

    private func performTermination(
        graceNanoseconds: UInt64
    ) async -> Result<DarwinPTYExit, DarwinPTYError> {
        if withLock({ state.leaderExit != nil }) {
            closeOutput()
            let rememberedDescendants = withLock { state.ownedDescendants }
            if let exit = await waitForExit(timeoutNanoseconds: Self.postKillReapNanoseconds),
               await ensureDescendantsGone(
                   Array(rememberedDescendants),
                   timeoutNanoseconds: Self.postKillReapNanoseconds
                ) {
                withLock { state.ownedDescendants.removeAll() }
                completeExitIfReady()
                return .success(exit)
            }
            return .failure(.terminationTimedOut)
        }

        let targets = terminationTargets()
        withLock { state.ownedDescendants.formUnion(targets.descendants) }
        signal(targets: targets, with: SIGHUP)
        signal(targets: targets, with: SIGTERM)
        closeOutput()
        if let exit = await waitForExit(timeoutNanoseconds: graceNanoseconds) {
            if await ensureDescendantsGone(
                targets.descendants,
                timeoutNanoseconds: Self.postKillReapNanoseconds
            ) {
                withLock { state.ownedDescendants.removeAll() }
                completeExitIfReady()
                return .success(exit)
            }
            return .failure(.terminationTimedOut)
        }

        let refreshed = terminationTargets(fallback: targets)
        withLock { state.ownedDescendants.formUnion(refreshed.descendants) }
        signal(targets: refreshed, with: SIGKILL)
        if let exit = await waitForExit(timeoutNanoseconds: Self.postKillReapNanoseconds),
           await waitForPIDsGone(
               Set(targets.descendants + refreshed.descendants),
               timeoutNanoseconds: Self.postKillReapNanoseconds
           ) {
            withLock { state.ownedDescendants.removeAll() }
            completeExitIfReady()
            return .success(exit)
        }
        return .failure(.terminationTimedOut)
    }

    private func ensureDescendantsGone(
        _ descendants: [pid_t],
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        let living = Set(descendants.filter(Self.isProcessAlive))
        guard !living.isEmpty else { return true }
        for process in living { _ = Darwin.kill(process, SIGKILL) }
        return await waitForPIDsGone(living, timeoutNanoseconds: timeoutNanoseconds)
    }

    private func waitForPIDsGone(
        _ processes: Set<pid_t>,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        guard !processes.isEmpty else { return true }
        let deadline = ContinuousClock.now.advanced(
            by: .nanoseconds(Int64(clamping: timeoutNanoseconds))
        )
        repeat {
            if processes.allSatisfy({ !Self.isProcessAlive($0) }) { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        } while true
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private static func waitForPIDsGoneBlocking(
        _ processes: Set<pid_t>,
        timeoutNanoseconds: UInt64
    ) -> Bool {
        guard !processes.isEmpty else { return true }
        let deadline = ContinuousClock.now.advanced(
            by: .nanoseconds(Int64(clamping: timeoutNanoseconds))
        )
        repeat {
            if processes.allSatisfy({ !isProcessAlive($0) }) { return true }
            if ContinuousClock.now >= deadline { return false }
            usleep(10_000)
        } while true
    }

    private func waitForExit(timeoutNanoseconds: UInt64) async -> DarwinPTYExit? {
        let deadline = ContinuousClock.now.advanced(
            by: .nanoseconds(Int64(clamping: timeoutNanoseconds))
        )
        repeat {
            if let exit = withLock({ state.exit }) { return exit }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        } while true
    }

    private func terminationTargets(
        fallback: TerminationTargets? = nil
    ) -> TerminationTargets {
        let foregroundGroup: pid_t? = withLock {
            guard state.outputOpen else { return fallback?.foregroundGroup }
            let group = Darwin.tcgetpgrp(masterDescriptor)
            return group > 1 ? group : fallback?.foregroundGroup
        }
        let group = Darwin.getpgid(pid)
        let leaderGroup = group == pid ? group : fallback?.leaderGroup
        let currentDescendants = Self.descendantPIDs(of: pid)
        return TerminationTargets(
            leader: pid,
            leaderGroup: leaderGroup,
            foregroundGroup: foregroundGroup,
            descendants: currentDescendants.isEmpty
                ? (fallback?.descendants ?? [])
                : currentDescendants
        )
    }

    private func signal(targets: TerminationTargets, with signal: Int32) {
        var groups = Set<pid_t>()
        if let foreground = targets.foregroundGroup { groups.insert(foreground) }
        if let leader = targets.leaderGroup { groups.insert(leader) }
        for group in groups where group > 1 {
            _ = Darwin.kill(-group, signal)
        }
        // A descendant that changes process group remains owned by this PTY
        // session. Signal the captured tree as well, deepest nodes first.
        for descendant in targets.descendants.reversed() where descendant > 1 {
            _ = Darwin.kill(descendant, signal)
        }
        _ = Darwin.kill(targets.leader, signal)
    }

    private static func descendantPIDs(of root: pid_t) -> [pid_t] {
        var discovered: [pid_t] = []
        var queue = [root]
        var visited = Set([root])
        while let parent = queue.first {
            queue.removeFirst()
            var children = [pid_t](repeating: 0, count: 256)
            let count = children.withUnsafeMutableBytes { bytes in
                Darwin.proc_listchildpids(parent, bytes.baseAddress, Int32(bytes.count))
            }
            guard count > 0 else { continue }
            for child in children.prefix(min(Int(count), children.count))
                where child > 1 && visited.insert(child).inserted {
                discovered.append(child)
                queue.append(child)
            }
        }
        return discovered
    }

    private func drainOutput() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(masterDescriptor, &buffer, buffer.count)
            if count > 0 {
                outputHandler(Data(buffer.prefix(count)))
            } else if count == 0 || (count < 0 && errno == EIO) {
                closeOutput()
                return
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                closeOutput()
                return
            }
        }
    }

    private func closeOutput() {
        let shouldCancel = withLock { () -> Bool in
            guard state.outputOpen else { return false }
            state.outputOpen = false
            return true
        }
        if shouldCancel { outputSource.cancel() }
    }

    private func recordLeaderExit(_ exit: DarwinPTYExit) {
        let shouldDrain = withLock { () -> Bool in
            guard state.leaderExit == nil else { return false }
            state.leaderExit = exit
            return state.outputOpen
        }
        completeExitIfReady()

        if shouldDrain {
            // Give the read source one final scheduling turn for bytes already
            // in the kernel. This block is serialized behind any callback in
            // progress, so completion cannot overtake delivery.
            outputQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.drainOutput()
                self?.closeOutput()
            }
        }
    }

    private func recordOutputClosed() {
        withLock { state.outputClosed = true }
        completeExitIfReady()
    }

    private func completeExitIfReady() {
        let completion = withLock { () -> (DarwinPTYExit, [CheckedContinuation<DarwinPTYExit, Never>])? in
            if state.exit == nil,
               state.outputClosed,
               let leaderExit = state.leaderExit {
                state.exit = leaderExit
            }
            guard let exit = state.exit,
                  state.ownedDescendants.isEmpty else { return nil }
            let waiters = state.exitWaiters
            state.exitWaiters.removeAll()
            return (exit, waiters)
        }
        guard let completion else { return }
        completion.1.forEach { $0.resume(returning: completion.0) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func validate(_ request: DarwinPTYSpawnRequest) throws {
        guard request.command.hasPrefix("/"),
              request.cwd.hasPrefix("/"),
              !request.command.utf8.contains(0),
              !request.cwd.utf8.contains(0),
              request.arguments.allSatisfy({ !$0.utf8.contains(0) }),
              request.environment.allSatisfy({ key, value in
                  !key.isEmpty
                      && !key.contains("=")
                      && !key.utf8.contains(0)
                      && !value.utf8.contains(0)
              }),
              request.columns > 0,
              request.rows > 0 else {
            throw DarwinPTYError.invalidRequest(
                "PTY command/cwd must be absolute, values must be NUL-free, and dimensions must be nonzero"
            )
        }
    }

    private static func resolveBrokerExecutablePath(_ supplied: String?) throws -> String {
        if let supplied {
            guard supplied.hasPrefix("/"), !supplied.utf8.contains(0) else {
                throw DarwinPTYError.invalidRequest("broker executable path must be absolute")
            }
            return supplied
        }

        var capacity = 4_096
        while capacity <= 1_048_576 {
            var bytes = [CChar](repeating: 0, count: capacity)
            var size = UInt32(capacity)
            if _NSGetExecutablePath(&bytes, &size) == 0 {
                let path = String(cString: bytes)
                if let resolved = realpath(path, nil) {
                    defer { free(resolved) }
                    return String(cString: resolved)
                }
                return path
            }
            capacity = max(capacity * 2, Int(size))
        }
        throw DarwinPTYError.systemCall(operation: "_NSGetExecutablePath", code: ENAMETOOLONG)
    }

    private static func makePipe(_ descriptors: inout [Int32]) -> Bool {
        descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress) == 0
        }
    }

    private static func makeNonblocking(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        return flags >= 0
            && Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func suppressSIGPIPE(_ descriptor: Int32) -> Bool {
        Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in Set(descriptors) where descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    guard remaining > .zero else { throw DarwinPTYError.writeTimedOut }
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let result = Darwin.poll(
                        &pollDescriptor,
                        1,
                        min(timeoutMilliseconds, remaining.millisecondsRoundedUp)
                    )
                    if result > 0 { continue }
                    if result < 0 && errno == EINTR { continue }
                    if result == 0 { throw DarwinPTYError.writeTimedOut }
                    throw systemError("poll PTY write")
                }
                throw systemError("write PTY")
            }
        }
    }

    private static func awaitExecHandshake(
        from descriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutMilliseconds)))
        var response = [UInt8]()
        while true {
            var bytes = [UInt8](repeating: 0, count: 16)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                response.append(contentsOf: bytes.prefix(count))
                if response.count >= 5 { break }
                continue
            }
            if count == 0 {
                if response.isEmpty { return }
                break
            }
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw systemError("read PTY child handshake")
            }
            if errno == EINTR { continue }

            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw DarwinPTYError.childHandshakeTimedOut }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = Darwin.poll(
                &pollDescriptor,
                1,
                min(timeoutMilliseconds, remaining.millisecondsRoundedUp)
            )
            if result > 0 { continue }
            if result < 0 && errno == EINTR { continue }
            if result == 0 { throw DarwinPTYError.childHandshakeTimedOut }
            throw systemError("poll PTY child handshake")
        }

        guard response.count == 5,
              let stage = DarwinPTYChildFailureStage(rawValue: response[0]) else {
            throw DarwinPTYError.childHandshakeMalformed
        }
        var code = Int32(0)
        withUnsafeMutableBytes(of: &code) { target in
            response.dropFirst().withContiguousStorageIfAvailable { source in
                target.copyBytes(from: UnsafeRawBufferPointer(source))
            }
        }
        throw DarwinPTYError.childSetupFailed(stage: stage, code: code)
    }

    private static func reapFailedSpawn(_ pid: pid_t) {
        _ = Darwin.kill(pid, SIGKILL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            var status = Int32(0)
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { return }
            if result < 0 && errno != EINTR { return }
            usleep(10_000)
        }
    }

    private static func systemError(_ operation: String) -> DarwinPTYError {
        DarwinPTYError.systemCall(operation: operation, code: errno)
    }
}

extension DarwinPTYProcess: FreshTerminalProcess {
    public func resize(columns: Int, rows: Int) throws {
        guard let columns = UInt16(exactly: columns),
              let rows = UInt16(exactly: rows),
              columns > 0,
              rows > 0 else {
            throw DarwinPTYError.invalidRequest("PTY dimensions must fit nonzero UInt16 values")
        }
        try resize(columns: columns, rows: rows)
    }

    public func waitForFreshTerminalExit() async {
        _ = await waitForExit()
    }

    public func terminateFreshTerminal(graceNanoseconds: UInt64) async throws {
        _ = try await terminate(graceNanoseconds: graceNanoseconds)
    }
}

public struct DarwinPTYProcessFactory: FreshTerminalProcessFactory, Sendable {
    private static let maximumOverrideCount = 256
    private static let maximumEnvironmentBytes = 524_288
    private static let inheritedKeys: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LANGUAGE",
        "LC_ALL", "LC_COLLATE", "LC_CTYPE", "LC_MESSAGES", "LC_MONETARY",
        "LC_NUMERIC", "LC_TIME", "LC_PAPER", "LC_NAME", "LC_ADDRESS",
        "LC_TELEPHONE", "LC_MEASUREMENT", "LC_IDENTIFICATION", "TZ",
        "SSH_AUTH_SOCK", "DISPLAY", "XAUTHORITY", "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
        "EDITOR", "VISUAL", "PAGER", "__CF_USER_TEXT_ENCODING",
    ]
    private static let removedTerminalKeys: Set<String> = [
        "NO_COLOR", "FORCE_COLOR", "CODEX_CI", "CODEX_MANAGED_BY_NPM",
        "CODEX_MANAGED_PACKAGE_ROOT", "CODEX_THREAD_ID", "TERM_SESSION_ID",
        "SHELL_SESSION_DID_INIT", "SHELL_SESSION_FILE", "SHELL_SESSION_HISTORY",
        "SHELL_SESSION_HISTFILE", "SHELL_SESSION_HISTFILE_NEW",
        "SHELL_SESSION_TIMESTAMP", "ELECTRON_RUN_AS_NODE", "KAISOLA_SESSION_BROKER",
    ]

    private let brokerExecutablePath: String?
    private let inheritedEnvironment: [String: String]
    private let homeDirectory: String

    public init(brokerExecutablePath: String? = nil) {
        self.brokerExecutablePath = brokerExecutablePath
        self.inheritedEnvironment = ProcessInfo.processInfo.environment
        self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    }

    public func spawn(
        request: FreshTerminalSpawnRequest,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> any FreshTerminalProcess {
        guard let columns = UInt16(exactly: request.columns),
              let rows = UInt16(exactly: request.rows) else {
            throw DarwinPTYError.invalidRequest("PTY dimensions must fit UInt16 values")
        }
        let environment = try Self.terminalEnvironment(
            inherited: inheritedEnvironment,
            overrides: request.environment,
            homeDirectory: homeDirectory
        )
        return try await DarwinPTYProcess.spawn(
            DarwinPTYSpawnRequest(
                command: request.command,
                arguments: request.arguments,
                environment: environment,
                cwd: request.cwd,
                columns: columns,
                rows: rows
            ),
            brokerExecutablePath: brokerExecutablePath,
            onOutput: onOutput
        )
    }

    /// Builds the same clean user-terminal boundary as the Node broker. Only
    /// ordinary session compatibility values enter from the broker launcher;
    /// project/account values must arrive explicitly in `overrides`.
    static func terminalEnvironment(
        inherited: [String: String],
        overrides: [String: String],
        homeDirectory: String
    ) throws -> [String: String] {
        guard overrides.count <= maximumOverrideCount,
              environmentByteCount(overrides) <= maximumEnvironmentBytes else {
            throw DarwinPTYError.invalidRequest("terminal environment exceeds the bounded override limit")
        }

        var environment = inherited.filter { inheritedKeys.contains($0.key) }
        let home = nonempty(environment["HOME"]) ?? homeDirectory
        environment["HOME"] = home
        environment["USER"] = nonempty(environment["USER"]) ?? NSUserName()
        environment["LOGNAME"] = nonempty(environment["LOGNAME"]) ?? environment["USER"]
        environment["SHELL"] = nonempty(environment["SHELL"]) ?? "/bin/zsh"
        environment["TMPDIR"] = nonempty(environment["TMPDIR"]) ?? NSTemporaryDirectory()
        environment["LANG"] = nonempty(environment["LANG"]) ?? "en_US.UTF-8"

        let path = terminalPath(inheritedPath: inherited["PATH"], home: home)
        for (key, value) in overrides { environment[key] = value }

        // Broker-authoritative terminal identity and rendering behavior.
        environment["PATH"] = path
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["SHELL_SESSIONS_DISABLE"] = "1"
        environment["TERM_PROGRAM"] = "Kaisola"
        environment["TERM_PROGRAM_VERSION"] = "1"
        environment["PROMPT_EOL_MARK"] = ""
        for key in removedTerminalKeys { environment.removeValue(forKey: key) }

        guard environment.count <= maximumOverrideCount + inheritedKeys.count + 8,
              environmentByteCount(environment) <= maximumEnvironmentBytes else {
            throw DarwinPTYError.invalidRequest("terminal environment exceeds the encoded size limit")
        }
        return environment
    }

    private static func terminalPath(inheritedPath: String?, home: String) -> String {
        let candidates = [
            inheritedPath,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/Library/TeX/texbin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        var seen = Set<String>()
        return candidates
            .compactMap { $0 }
            .flatMap { $0.split(separator: ":", omittingEmptySubsequences: true).map(String.init) }
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func environmentByteCount(_ environment: [String: String]) -> Int {
        environment.reduce(into: 0) { count, entry in
            count += entry.key.utf8.count + entry.value.utf8.count + 2
        }
    }
}

private extension Duration {
    var millisecondsRoundedUp: Int32 {
        let components = self.components
        let seconds = max(Int64(0), components.seconds)
        let attoseconds = max(Int64(0), components.attoseconds)
        let fromSeconds = seconds > Int64(Int32.max / 1_000)
            ? Int64(Int32.max)
            : seconds * 1_000
        let fromAttoseconds = (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(clamping: min(Int64(Int32.max), fromSeconds + fromAttoseconds))
    }
}
