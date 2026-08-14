import Darwin
import Foundation
import KaisolaBrokerProtocol

/// The single ordered outbound path for one connection. Responses, the hello,
/// and `{type:'event'}` frames all pass through here, so frames can never
/// interleave mid-JSON and response/event order is exactly enqueue order.
///
/// `queuedByteCount` is the Swift analog of Node's `socket.writableLength`:
/// bytes accepted but not yet handed to the kernel. Event enqueues compare it
/// against the subscriber's queue budget; responses are never capped, exactly
/// like the Node broker's `writeFrame` without `maxQueueBytes`.
final class BrokerOutboundFrameQueue: @unchecked Sendable {
    private enum State {
        case open
        /// No further enqueues; the writer drains what is queued, then ends.
        case finishing
        /// Queued frames are dropped; a reconnect replays snapshots.
        case closed
    }

    private let lock = NSLock()
    private var frames: [Data] = []
    private var head = 0
    private var unwrittenBytes = 0
    private var state: State = .open
    private var waiter: CheckedContinuation<Data?, Never>?

    var queuedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unwrittenBytes
    }

    /// Accepts or refuses one complete frame. Refusal (`false`) is the exact
    /// verdict the slow-consumer policy consumes: the frame was not queued and
    /// never will be. `force` bypasses the cap for recovery markers but can
    /// never resurrect a finishing or closed queue.
    func enqueue(_ frame: Data, maxQueueBytes: Int?, force: Bool) -> Bool {
        var parked: CheckedContinuation<Data?, Never>?
        lock.lock()
        guard state == .open else {
            lock.unlock()
            return false
        }
        if !force, let maxQueueBytes, unwrittenBytes + frame.count > maxQueueBytes {
            lock.unlock()
            return false
        }
        unwrittenBytes += frame.count
        if let waiting = waiter {
            waiter = nil
            parked = waiting
        } else {
            frames.append(frame)
        }
        lock.unlock()
        // Resumed outside the lock: the writer immediately re-enters `next()`.
        parked?.resume(returning: frame)
        return true
    }

    /// The writer's sole entry point. Returns frames in enqueue order and nil
    /// once the queue has finished (after draining) or closed.
    func next() async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if head < frames.count {
                let frame = frames[head]
                head += 1
                if head == frames.count {
                    frames.removeAll(keepingCapacity: true)
                    head = 0
                }
                lock.unlock()
                continuation.resume(returning: frame)
                return
            }
            if state != .open {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    /// Called by the writer after the kernel accepted a frame, releasing its
    /// bytes from the backpressure budget.
    func markWritten(_ byteCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        unwrittenBytes = max(0, unwrittenBytes - byteCount)
    }

    func finish() {
        var parked: CheckedContinuation<Data?, Never>?
        lock.lock()
        if state == .open { state = .finishing }
        // A parked waiter proves the buffer is empty, so finishing ends it.
        parked = waiter
        waiter = nil
        lock.unlock()
        parked?.resume(returning: nil)
    }

    func closeDiscarding() {
        var parked: CheckedContinuation<Data?, Never>?
        lock.lock()
        state = .closed
        frames.removeAll(keepingCapacity: false)
        head = 0
        unwrittenBytes = 0
        parked = waiter
        waiter = nil
        lock.unlock()
        parked?.resume(returning: nil)
    }
}

final class BrokerConnection: @unchecked Sendable {
    private static let maximumRequestFrameBytes = BrokerWire.maximumEncodedBytes(
        for: .request("terminal.write")
    )

    private let service: ShadowBrokerService
    private let peerUID: uid_t
    private let log: BrokerLog
    private let helloDeadlineNanoseconds: UInt64
    private let didAuthenticate: @Sendable () -> Void
    private let readQueue: DispatchQueue
    // Reads and writes block on separate workers: a writer stalled against a
    // slow peer must not park the reader (or the reverse) on one serial queue.
    private let writeQueue: DispatchQueue
    private let outbound = BrokerOutboundFrameQueue()
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
        let identity = UUID().uuidString.lowercased()
        readQueue = DispatchQueue(
            label: "com.kaisola.session-broker.connection.\(identity)",
            qos: .userInitiated
        )
        writeQueue = DispatchQueue(
            label: "com.kaisola.session-broker.connection-write.\(identity)",
            qos: .userInitiated
        )
    }

    func run() async {
        let writer = Task { await drainOutbound() }
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
        // Let already-accepted frames (a hello rejection, the final response)
        // drain before the descriptor closes; a wedged peer cannot pin this,
        // because cancel()/socket teardown fails the blocked write.
        outbound.finish()
        await writer.value
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
        outbound.closeDiscarding()
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
            try enqueueOutbound(response, purpose: .hello)
            // Attached only after the hello response is queued, so no event
            // frame can ever precede the hello on this socket.
            await service.attachConnection(client: client, sink: eventSink())
            log.record(.authenticationAccepted)
        case let .rejected(response):
            try enqueueOutbound(response, purpose: .hello)
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
        // The subscribe route answers through this responder from inside the
        // terminal's output critical section (and then returns nil), which is
        // what pins the response ahead of the first live event.
        let response = await service.dispatch(
            client: client,
            request: request,
            responder: responder(for: request.method)
        )
        if let response {
            try enqueueOutbound(response, purpose: .response(request.method))
        }
    }

    private func eventSink() -> BrokerConnectionEventSink {
        BrokerConnectionEventSink { [outbound] frame, maxQueueBytes, force in
            outbound.enqueue(frame, maxQueueBytes: maxQueueBytes, force: force)
        }
    }

    private func responder(for method: String) -> @Sendable (BrokerResponse) -> Bool {
        { [outbound] response in
            guard let data = try? Self.encodeFrame(response, purpose: .response(method)) else {
                return false
            }
            return outbound.enqueue(data, maxQueueBytes: nil, force: false)
        }
    }

    private func readChunk(helloDeadlineNanoseconds: UInt64?) async throws -> Data? {
        let current = currentDescriptor()
        guard current >= 0 else { return nil }
        return try await Self.runBlocking(on: readQueue) { () throws -> Data? in
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

    private func enqueueOutbound<Value: Encodable & Sendable>(
        _ value: Value,
        purpose: BrokerFramePurpose
    ) throws {
        let data = try Self.encodeFrame(value, purpose: purpose)
        guard outbound.enqueue(data, maxQueueBytes: nil, force: false) else {
            throw BrokerConnectionError.closed
        }
    }

    private static func encodeFrame<Value: Encodable>(
        _ value: Value,
        purpose: BrokerFramePurpose
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        try BrokerWire.validateEncodedFrame(data, purpose: purpose)
        data.append(0x0a)
        return data
    }

    /// The only socket writer. One frame is written completely before the next
    /// begins, so a JSON frame can never interleave with another.
    private func drainOutbound() async {
        while let frame = await outbound.next() {
            do {
                try await blockingWrite(frame)
                outbound.markWritten(frame.count)
            } catch {
                outbound.closeDiscarding()
                // The peer stopped accepting bytes; wake a blocked read so the
                // connection task can unwind and release the descriptor.
                let current = currentDescriptor()
                if current >= 0 {
                    _ = Darwin.shutdown(current, SHUT_RDWR)
                }
                return
            }
        }
    }

    private func blockingWrite(_ framedData: Data) async throws {
        let current = currentDescriptor()
        guard current >= 0 else { throw BrokerConnectionError.closed }
        try await Self.runBlocking(on: writeQueue) {
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
