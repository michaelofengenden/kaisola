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

actor AcpProcessTransport: AcpByteTransport {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var terminationCode: Int32?

    func start(command: String, arguments: [String], environment: [String: String], cwd: String) async throws {
        guard process == nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command)
        task.arguments = arguments
        task.environment = environment
        task.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        // Drain stderr so a chatty adapter never blocks on a full pipe. Its
        // contents are diagnostics only; the protocol is stdout.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        task.terminationHandler = { [weak self] finished in
            Task { await self?.recordTermination(finished.terminationStatus) }
        }

        do {
            try task.run()
        } catch {
            throw AcpClientError.spawnFailed(error.localizedDescription)
        }
        process = task
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
    }

    private func recordTermination(_ code: Int32) {
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

    func terminate() async {
        process?.terminate()
        try? stdinHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
    }

    func exitCode() async -> Int32? {
        terminationCode
    }
}
