import Darwin
import Foundation

protocol BrokerByteTransport: Sendable {
    func connect(path: String) async throws
    func send(_ data: Data) async throws
    func receive(maximumBytes: Int) async throws -> Data?
    func close() async
}

actor UnixBrokerTransport: BrokerByteTransport {
    private var fileHandle: FileHandle?
    /// Darwin socket calls are intentionally blocking, but never on Swift's
    /// cooperative executor. Separate serial queues preserve ordered writes
    /// while allowing a read to wait indefinitely without starving writes or
    /// unrelated Tasks. close() performs shutdown directly and wakes both.
    private nonisolated let readQueue: DispatchQueue
    private nonisolated let writeQueue: DispatchQueue

    init() {
        let identity = UUID().uuidString.lowercased()
        readQueue = DispatchQueue(label: "com.kaisola.broker-socket.read.\(identity)", qos: .userInitiated)
        writeQueue = DispatchQueue(label: "com.kaisola.broker-socket.write.\(identity)", qos: .userInitiated)
    }

    /// Test-only seam for proving that shutdown wakes an outstanding read.
    /// Production connects through the pathname API below.
    init(connectedFileDescriptor: Int32) {
        let identity = UUID().uuidString.lowercased()
        readQueue = DispatchQueue(label: "com.kaisola.broker-socket.read.\(identity)", qos: .userInitiated)
        writeQueue = DispatchQueue(label: "com.kaisola.broker-socket.write.\(identity)", qos: .userInitiated)
        fileHandle = FileHandle(fileDescriptor: connectedFileDescriptor, closeOnDealloc: true)
    }

    func connect(path: String) async throws {
        guard fileHandle == nil else { return }
        let descriptor = try await Self.runBlocking(on: writeQueue) {
            try Self.connectDescriptor(path: path)
        }
        fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private nonisolated static func connectDescriptor(path: String) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw BrokerClientError.socketPathTooLong }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrokerClientError.socketFailure(errno) }
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        address.sun_family = sa_family_t(AF_UNIX)
        let addressLength = MemoryLayout<sa_family_t>.size + pathBytes.count + 1
        address.sun_len = UInt8(addressLength)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: pathBytes)
            rawBuffer[pathBytes.count] = 0
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(addressLength))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw BrokerClientError.socketFailure(code)
        }
        return descriptor
    }

    func send(_ data: Data) async throws {
        guard let fileHandle else { throw BrokerClientError.notConnected }
        do {
            // The dedicated serial queue is the ordering primitive. Multiple
            // actor calls may suspend here, but their complete frames cannot
            // interleave and close() remains free to issue shutdown(2).
            try await Self.runBlocking(on: writeQueue) {
                try fileHandle.write(contentsOf: data)
            }
        } catch {
            throw BrokerClientError.connectionClosed
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        guard let descriptor = fileHandle?.fileDescriptor else {
            throw BrokerClientError.notConnected
        }
        return try await Self.runBlocking(on: readQueue) {
            var bytes = [UInt8](repeating: 0, count: maximumBytes)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { return Data() }
                throw BrokerClientError.socketFailure(errno)
            }
            return Data(bytes.prefix(count))
        }
    }

    func close() async {
        // close(2) alone does not reliably wake a concurrent blocking read on
        // macOS. Clear actor-visible state first, then shutdown both directions
        // before closing the descriptor so receive/send promptly unwind.
        let closingHandle = fileHandle
        fileHandle = nil
        if let descriptor = closingHandle?.fileDescriptor, descriptor >= 0 {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
        try? closingHandle?.close()
    }

    /// Bridge a blocking syscall onto a real GCD worker rather than
    /// `Task.detached`, whose body still occupies Swift's cooperative pool.
    private nonisolated static func runBlocking<Value: Sendable>(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
