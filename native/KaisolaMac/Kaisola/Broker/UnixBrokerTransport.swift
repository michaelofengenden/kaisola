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

    func connect(path: String) async throws {
        guard fileHandle == nil else { return }
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
        fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func send(_ data: Data) async throws {
        guard let fileHandle else { throw BrokerClientError.notConnected }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            throw BrokerClientError.connectionClosed
        }
    }

    func receive(maximumBytes: Int) async throws -> Data? {
        guard let descriptor = fileHandle?.fileDescriptor else {
            throw BrokerClientError.notConnected
        }
        return try await Task.detached(priority: .userInitiated) {
            var bytes = [UInt8](repeating: 0, count: maximumBytes)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { return Data() }
                throw BrokerClientError.socketFailure(errno)
            }
            return Data(bytes.prefix(count))
        }.value
    }

    func close() async {
        try? fileHandle?.close()
        fileHandle = nil
    }
}
