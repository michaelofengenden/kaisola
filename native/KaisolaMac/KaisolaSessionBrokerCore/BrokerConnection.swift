import Darwin
import Foundation
import KaisolaBrokerProtocol

final class BrokerConnection: @unchecked Sendable {
    private static let maximumRequestFrameBytes = BrokerWire.maximumEncodedBytes(
        for: .request("terminal.write")
    )

    private let service: ShadowBrokerService
    private let peerUID: uid_t
    private let log: BrokerLog
    private let helloDeadlineNanoseconds: UInt64
    private let didAuthenticate: @Sendable () -> Void
    private let ioQueue: DispatchQueue
    private let descriptorLock = NSLock()
    private var descriptor: Int32

    init(
        descriptor: Int32,
        peerUID: uid_t,
        service: ShadowBrokerService,
        log: BrokerLog,
        helloTimeoutMilliseconds: Int,
        didAuthenticate: @escaping @Sendable () -> Void
    ) {
        self.descriptor = descriptor
        self.peerUID = peerUID
        self.service = service
        self.log = log
        let timeoutNanoseconds = UInt64(helloTimeoutMilliseconds) * 1_000_000
        helloDeadlineNanoseconds = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        self.didAuthenticate = didAuthenticate
        ioQueue = DispatchQueue(
            label: "com.kaisola.session-broker.connection.\(UUID().uuidString.lowercased())",
            qos: .userInitiated
        )
    }

    func run() async {
        var authenticatedClient: BrokerAuthenticatedClient?
        do {
            var buffer = Data()
            while let chunk = try await readChunk(
                helloDeadlineNanoseconds: authenticatedClient == nil
                    ? helloDeadlineNanoseconds
                    : nil
            ) {
                buffer.append(chunk)
                try await consumeFrames(
                    from: &buffer,
                    authenticatedClient: &authenticatedClient
                )
                let maximum = authenticatedClient == nil
                    ? BrokerWire.maximumEncodedBytes(for: .hello)
                    : Self.maximumRequestFrameBytes
                guard buffer.count <= maximum else {
                    throw BrokerConnectionError.frameTooLarge
                }
            }
            guard buffer.isEmpty else { throw BrokerConnectionError.incompleteFrame }
        } catch BrokerConnectionError.cleanClose {
            // A rejected hello is answered before the orderly close.
        } catch BrokerConnectionError.helloTimedOut {
            // Idle and slow-drip pre-authentication peers are closed quietly.
        } catch {
            log.record(.protocolViolation)
        }

        if let authenticatedClient {
            await service.disconnect(client: authenticatedClient)
        }
        finish()
    }

    /// Wake an outstanding blocking read. The connection task remains the sole
    /// closer, preventing descriptor reuse while its GCD worker unwinds.
    func cancel() {
        descriptorLock.lock()
        let current = descriptor
        descriptorLock.unlock()
        if current >= 0 {
            _ = Darwin.shutdown(current, SHUT_RDWR)
        }
    }

    func closeBeforeRun() {
        cancel()
        finish()
    }

    private func consumeFrames(
        from buffer: inout Data,
        authenticatedClient: inout BrokerAuthenticatedClient?
    ) async throws {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let frameBytes = buffer.distance(from: buffer.startIndex, to: newline)
            let maximum = authenticatedClient == nil
                ? BrokerWire.maximumEncodedBytes(for: .hello)
                : Self.maximumRequestFrameBytes
            guard frameBytes <= maximum else { throw BrokerConnectionError.frameTooLarge }

            let frame = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !frame.isEmpty else { throw BrokerConnectionError.invalidFrame }
            guard String(data: frame, encoding: .utf8) != nil else {
                throw BrokerConnectionError.invalidUTF8
            }

            if authenticatedClient == nil {
                try await authenticate(frame, authenticatedClient: &authenticatedClient)
            } else if let client = authenticatedClient {
                try await dispatch(frame, client: client)
            }
        }
    }

    private func authenticate(
        _ frame: Data,
        authenticatedClient: inout BrokerAuthenticatedClient?
    ) async throws {
        let envelope = try BrokerWire.validateDecodedFrame(frame) { _ in nil }
        guard envelope.type == "hello" else { throw BrokerConnectionError.invalidFrame }
        let hello = try JSONDecoder().decode(BrokerHelloRequest.self, from: frame)
        guard hello.type == "hello" else { throw BrokerConnectionError.invalidFrame }

        switch await service.authenticate(hello: hello, peerUID: peerUID) {
        case let .accepted(client, response):
            authenticatedClient = client
            didAuthenticate()
            try await write(response, purpose: .hello)
            log.record(.authenticationAccepted)
        case let .rejected(response):
            try await write(response, purpose: .hello)
            log.record(.authenticationRejected)
            throw BrokerConnectionError.cleanClose
        }
    }

    private func dispatch(
        _ frame: Data,
        client: BrokerAuthenticatedClient
    ) async throws {
        let envelope = try BrokerWire.validateDecodedFrame(frame) { _ in nil }
        guard envelope.type == "request", let method = envelope.method else {
            throw BrokerConnectionError.invalidFrame
        }
        let request = try JSONDecoder().decode(BrokerRequest.self, from: frame)
        guard request.type == "request", request.method == method else {
            throw BrokerConnectionError.invalidFrame
        }
        log.recordRequest(method: request.method)
        let response = await service.dispatch(client: client, request: request)
        try await write(response, purpose: .response(request.method))
    }

    private func readChunk(helloDeadlineNanoseconds: UInt64?) async throws -> Data? {
        let current = currentDescriptor()
        guard current >= 0 else { return nil }
        return try await Self.runBlocking(on: ioQueue) { () throws -> Data? in
            var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                if let deadline = helloDeadlineNanoseconds {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { throw BrokerConnectionError.helloTimedOut }
                    let remaining = deadline - now
                    let roundedMilliseconds = (remaining + 999_999) / 1_000_000
                    let timeout = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
                    var pollDescriptor = pollfd(
                        fd: current,
                        events: Int16(POLLIN | POLLHUP),
                        revents: 0
                    )
                    let readiness = Darwin.poll(&pollDescriptor, 1, timeout)
                    if readiness == 0 { throw BrokerConnectionError.helloTimedOut }
                    if readiness < 0 {
                        if errno == EINTR { continue }
                        if errno == EBADF || errno == EINVAL { return nil }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
                let count = Darwin.read(current, &bytes, bytes.count)
                if count > 0 { return Data(bytes.prefix(count)) }
                if count == 0 { return nil }
                if errno == EINTR { continue }
                if errno == ECONNRESET || errno == EBADF || errno == EINVAL { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func write<Value: Encodable & Sendable>(
        _ value: Value,
        purpose: BrokerFramePurpose
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        try BrokerWire.validateEncodedFrame(data, purpose: purpose)
        data.append(0x0a)
        let framedData = data

        let current = currentDescriptor()
        guard current >= 0 else { throw BrokerConnectionError.closed }
        try await Self.runBlocking(on: ioQueue) {
            try framedData.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        current,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count > 0 {
                        offset += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        throw BrokerConnectionError.closed
                    }
                }
            }
        }
    }

    private func currentDescriptor() -> Int32 {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        return descriptor
    }

    private func finish() {
        descriptorLock.lock()
        let closing = descriptor
        descriptor = -1
        descriptorLock.unlock()
        if closing >= 0 {
            _ = Darwin.shutdown(closing, SHUT_RDWR)
            Darwin.close(closing)
        }
    }

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

private enum BrokerConnectionError: Error {
    case cleanClose
    case closed
    case frameTooLarge
    case helloTimedOut
    case incompleteFrame
    case invalidFrame
    case invalidUTF8
}
