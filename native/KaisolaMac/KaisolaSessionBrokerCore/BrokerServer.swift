import Darwin
import Foundation
import KaisolaBrokerProtocol

public final class BrokerServer: @unchecked Sendable {
    private let configuration: ShadowBrokerConfiguration
    private let expectedPeerUID: uid_t
    private let expectedSocketOwnerUID: uid_t
    private let service: ShadowBrokerService
    private let terminalStore: FreshTerminalStore?
    private let generationLifecycle: BrokerGenerationLifecycle?
    private let log: BrokerLog
    private let beforeStaleSocketRemoval: (@Sendable () -> Void)?
    private let afterSocketBind: (@Sendable () throws -> Void)?
    private let afterSocketChmodValidation: (@Sendable () throws -> Void)?
    private let maximumPreAuthenticationConnections: Int
    private let helloTimeoutMilliseconds: Int
    private let acceptQueue = DispatchQueue(
        label: "com.kaisola.session-broker.accept",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var started = false
    private var stopping = false
    private var listenerDescriptor: Int32 = -1
    private var connections: [UUID: BrokerConnection] = [:]
    private var preAuthenticationConnectionIDs: Set<UUID> = []

    public convenience init(configuration: ShadowBrokerConfiguration) throws {
        let generationLifecycle = configuration.runtimeMode == .launch
            ? try BrokerGenerationLifecycle(configuration: configuration)
            : nil
        try self.init(
            configuration: configuration,
            expectedPeerUID: geteuid(),
            generationLifecycle: generationLifecycle,
            serviceStartedAt: configuration.startedAt
                ?? Int64(Date().timeIntervalSince1970 * 1_000),
            serviceVersion: configuration.version ?? "kaisola-swift-shadow"
        )
    }

    init(
        configuration: ShadowBrokerConfiguration,
        expectedPeerUID: uid_t,
        expectedSocketOwnerUID: uid_t = geteuid(),
        log: BrokerLog = BrokerLog(),
        generationLifecycle: BrokerGenerationLifecycle? = nil,
        beforeStaleSocketRemoval: (@Sendable () -> Void)? = nil,
        afterSocketBind: (@Sendable () throws -> Void)? = nil,
        afterSocketChmodValidation: (@Sendable () throws -> Void)? = nil,
        maximumPreAuthenticationConnections: Int = 32,
        helloTimeoutMilliseconds: Int = 5_000,
        servicePID: Int32 = getpid(),
        serviceStartedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        serviceVersion: String = "kaisola-swift-shadow"
    ) throws {
        self.configuration = configuration
        self.expectedPeerUID = expectedPeerUID
        self.expectedSocketOwnerUID = expectedSocketOwnerUID
        self.log = log
        self.generationLifecycle = generationLifecycle
        self.beforeStaleSocketRemoval = beforeStaleSocketRemoval
        self.afterSocketBind = afterSocketBind
        self.afterSocketChmodValidation = afterSocketChmodValidation
        self.maximumPreAuthenticationConnections = min(
            max(maximumPreAuthenticationConnections, 1),
            128
        )
        self.helloTimeoutMilliseconds = min(max(helloTimeoutMilliseconds, 50), 30_000)
        let serviceConfiguration = try ShadowBrokerServiceConfiguration(
            expectedToken: configuration.token,
            expectedUID: UInt32(expectedPeerUID),
            packageSchema: configuration.packageSchema,
            packageVersion: configuration.packageVersion,
            contentDigest: configuration.contentDigest,
            pid: servicePID,
            startedAt: serviceStartedAt,
            version: serviceVersion,
            maximumLiveTerminals: configuration.maximumLiveTerminals
                ?? BrokerWire.defaultMaximumLiveTerminals
        )
        let terminalStore: FreshTerminalStore?
        switch configuration.runtimeMode {
        case .shadow:
            terminalStore = nil
        case .freshPTY, .launch:
            terminalStore = FreshTerminalStore(
                factory: DarwinPTYProcessFactory(),
                maximumLiveTerminals: configuration.maximumLiveTerminals
                    ?? BrokerWire.defaultMaximumLiveTerminals
            )
        }
        self.terminalStore = terminalStore
        service = try ShadowBrokerService(
            configuration: serviceConfiguration,
            terminalStore: terminalStore
        )
    }

    /// Runs until `stop()` closes the listener. Blocking socket calls are kept
    /// on dedicated GCD workers rather than Swift's cooperative executor.
    public func run() async throws {
        try beginRun()
        if isStopping { return }
        let prepared: PreparedListener
        do {
            prepared = try prepareListener()
        } catch {
            if markPreparationFailed() { return }
            throw error
        }

        guard installListener(prepared.descriptor) else {
            Darwin.close(prepared.descriptor)
            removeCreatedSocketIfUnchanged(prepared.identity)
            return
        }
        log.record(.serverStarted)

        defer {
            let closing = finishRun()
            if closing.listener >= 0 {
                _ = Darwin.shutdown(closing.listener, SHUT_RDWR)
                Darwin.close(closing.listener)
            }
            closing.connections.forEach { $0.cancel() }
            removeCreatedSocketIfUnchanged(prepared.identity)
            generationLifecycle?.cleanup()
            log.record(.serverStopped)
        }

        try generationLifecycle?.publish()

        do {
            try await serveConnections(on: prepared.descriptor)
        } catch {
            let servingError = error
            do {
                try await terminalStore?.shutdown()
            } catch {
                throw error
            }
            throw servingError
        }
        try await terminalStore?.shutdown()
    }

    private func serveConnections(on listener: Int32) async throws {
        while true {
            do {
                let accepted = try await acceptConnection(on: listener)
                if isStopping {
                    Darwin.close(accepted)
                    return
                }
                try admit(accepted)
            } catch {
                if isStopping { return }
                if let serverError = error as? BrokerServerError,
                   serverError == .interrupted {
                    continue
                }
                throw error
            }
        }
    }

    public func stop() async {
        stopSynchronously()
    }

    private func stopSynchronously() {
        stateLock.lock()
        stopping = true
        let listener = listenerDescriptor
        listenerDescriptor = -1
        let active = Array(connections.values)
        stateLock.unlock()

        if listener >= 0 {
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
        active.forEach { $0.cancel() }
    }

    private func beginRun() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !started else { throw BrokerServerError.alreadyRunning }
        started = true
    }

    private func markPreparationFailed() -> Bool {
        stateLock.lock()
        let stopWasRequested = stopping
        stopping = true
        stateLock.unlock()
        return stopWasRequested
    }

    private func installListener(_ descriptor: Int32) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopping else { return false }
        listenerDescriptor = descriptor
        return true
    }

    private var isStopping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    private func finishRun() -> (listener: Int32, connections: [BrokerConnection]) {
        stateLock.lock()
        stopping = true
        let listener = listenerDescriptor
        listenerDescriptor = -1
        let active = Array(connections.values)
        connections.removeAll()
        preAuthenticationConnectionIDs.removeAll()
        stateLock.unlock()
        return (listener, active)
    }

    private func admit(_ descriptor: Int32) throws {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0 else {
            Darwin.close(descriptor)
            log.record(.connectionRejected)
            throw BrokerServerError.systemCall(errno)
        }

        // This comparison intentionally precedes construction of a connection
        // (and therefore every read of attacker-controlled hello bytes).
        guard peerUID == expectedPeerUID else {
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            log.record(.connectionRejected)
            return
        }

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let id = UUID()
        let connection = BrokerConnection(
            descriptor: descriptor,
            peerUID: peerUID,
            service: service,
            log: log,
            helloTimeoutMilliseconds: helloTimeoutMilliseconds,
            didAuthenticate: { [weak self] in
                self?.connectionDidAuthenticate(id)
            }
        )

        stateLock.lock()
        let admitted = !stopping
            && preAuthenticationConnectionIDs.count < maximumPreAuthenticationConnections
        if admitted {
            connections[id] = connection
            preAuthenticationConnectionIDs.insert(id)
        }
        stateLock.unlock()
        guard admitted else {
            connection.closeBeforeRun()
            log.record(.connectionRejected)
            return
        }

        log.record(.connectionAccepted)
        Task { [weak self, connection] in
            await connection.run()
            self?.connectionDidEnd(id)
        }
    }

    private func connectionDidEnd(_ id: UUID) {
        stateLock.lock()
        connections.removeValue(forKey: id)
        preAuthenticationConnectionIDs.remove(id)
        stateLock.unlock()
    }

    private func connectionDidAuthenticate(_ id: UUID) {
        stateLock.lock()
        preAuthenticationConnectionIDs.remove(id)
        stateLock.unlock()
    }

    private func acceptConnection(on descriptor: Int32) async throws -> Int32 {
        try await Self.runBlocking(on: acceptQueue) {
            while true {
                let accepted = Darwin.accept(descriptor, nil, nil)
                if accepted >= 0 { return accepted }
                if errno == EINTR { throw BrokerServerError.interrupted }
                throw BrokerServerError.systemCall(errno)
            }
        }
    }

    private func prepareListener() throws -> PreparedListener {
        try validatePrivateRoot()
        try recoverStaleSocketIfNeeded()

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrokerServerError.systemCall(errno) }
        var boundIdentity: SocketIdentity?
        var succeeded = false
        defer {
            if !succeeded {
                Darwin.close(descriptor)
                if let boundIdentity { removeCreatedSocketIfUnchanged(boundIdentity) }
            }
        }

        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var address = try Self.unixAddress(path: configuration.socketPath)
        let addressLength = socklen_t(address.sun_len)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        guard bindResult == 0 else { throw BrokerServerError.systemCall(errno) }

        let createdIdentity = try socketIdentity(at: configuration.socketPath)
        boundIdentity = createdIdentity
        guard createdIdentity.owner == geteuid(), createdIdentity.linkCount == 1 else {
            throw BrokerServerError.unsafeSocketPath
        }
        try afterSocketBind?()
        let postBindIdentity = try socketIdentity(at: configuration.socketPath)
        guard postBindIdentity.isSameFile(as: createdIdentity) else {
            throw BrokerServerError.socketChanged
        }
        guard chmod(configuration.socketPath, 0o600) == 0 else {
            throw BrokerServerError.systemCall(errno)
        }
        let postChmodIdentity = try socketIdentity(at: configuration.socketPath)
        guard postChmodIdentity.isSameFile(as: createdIdentity) else {
            throw BrokerServerError.socketChanged
        }
        guard postChmodIdentity.owner == geteuid(),
              postChmodIdentity.linkCount == 1,
              postChmodIdentity.permissions == 0o600 else {
            throw BrokerServerError.unsafeSocketPath
        }
        boundIdentity = postChmodIdentity
        try afterSocketChmodValidation?()
        guard Darwin.listen(descriptor, 128) == 0 else {
            throw BrokerServerError.systemCall(errno)
        }
        let identity = try socketIdentity(at: configuration.socketPath)
        guard identity.isSameFile(as: createdIdentity) else {
            throw BrokerServerError.socketChanged
        }
        guard identity.owner == geteuid(),
              identity.linkCount == 1,
              identity.permissions == 0o600 else {
            throw BrokerServerError.unsafeSocketPath
        }
        succeeded = true
        return PreparedListener(descriptor: descriptor, identity: identity)
    }

    private func validatePrivateRoot() throws {
        let root = configuration.privateRootURL.standardizedFileURL.path
        guard configuration.socketURL.deletingLastPathComponent().standardizedFileURL.path == root else {
            throw BrokerServerError.unsafePrivateRoot
        }
        let identity = try pathIdentity(at: root)
        guard identity.fileType == S_IFDIR,
              identity.owner == geteuid(),
              identity.permissions == 0o700 else {
            throw BrokerServerError.unsafePrivateRoot
        }
    }

    private func recoverStaleSocketIfNeeded() throws {
        let path = configuration.socketPath
        let existing: SocketIdentity
        do {
            existing = try pathIdentity(at: path)
        } catch let error as POSIXError where error.code == .ENOENT {
            return
        }

        guard existing.fileType == S_IFSOCK,
              existing.owner == expectedSocketOwnerUID,
              existing.linkCount == 1 else {
            throw BrokerServerError.unsafeSocketPath
        }
        let probeResult = try probeSocket(at: path)
        guard probeResult == .stale else { throw BrokerServerError.liveSocket }

        beforeStaleSocketRemoval?()
        let current = try pathIdentity(at: path)
        guard current == existing else { throw BrokerServerError.socketChanged }

        let quarantine = configuration.privateRootURL.appendingPathComponent(
            ".broker-stale-\(UUID().uuidString.lowercased())"
        ).path
        guard Darwin.rename(path, quarantine) == 0 else {
            throw BrokerServerError.systemCall(errno)
        }
        let quarantined = try pathIdentity(at: quarantine)
        guard quarantined == existing else {
            if (try? pathIdentity(at: path)) == nil {
                _ = Darwin.rename(quarantine, path)
            }
            throw BrokerServerError.socketChanged
        }
        guard Darwin.unlink(quarantine) == 0 else {
            if (try? pathIdentity(at: path)) == nil {
                _ = Darwin.rename(quarantine, path)
            }
            throw BrokerServerError.systemCall(errno)
        }
        log.record(.staleSocketRecovered)
    }

    private func probeSocket(at path: String) throws -> SocketProbeResult {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrokerServerError.systemCall(errno) }
        defer { Darwin.close(descriptor) }
        var address = try Self.unixAddress(path: path)
        let addressLength = socklen_t(address.sun_len)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        if result == 0 { return .live }
        if errno == ECONNREFUSED { return .stale }
        throw BrokerServerError.systemCall(errno)
    }

    private func removeCreatedSocketIfUnchanged(_ created: SocketIdentity) {
        guard let current = try? pathIdentity(at: configuration.socketPath),
              current == created,
              current.fileType == S_IFSOCK,
              current.owner == geteuid(),
              current.linkCount == 1 else { return }
        let quarantine = configuration.privateRootURL.appendingPathComponent(
            ".broker-cleanup-\(UUID().uuidString.lowercased())"
        ).path
        guard Darwin.rename(configuration.socketPath, quarantine) == 0 else { return }
        guard let quarantined = try? pathIdentity(at: quarantine),
              quarantined == created else {
            restoreQuarantinedPath(quarantine)
            return
        }
        if Darwin.unlink(quarantine) != 0 {
            restoreQuarantinedPath(quarantine)
        }
    }

    private func restoreQuarantinedPath(_ quarantine: String) {
        guard (try? pathIdentity(at: configuration.socketPath)) == nil else { return }
        _ = Darwin.rename(quarantine, configuration.socketPath)
    }

    private static func unixAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw BrokerServerError.socketPathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
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

enum BrokerServerError: Error, Equatable, LocalizedError {
    case alreadyRunning
    case interrupted
    case liveSocket
    case socketChanged
    case socketPathTooLong
    case stopped
    case systemCall(Int32)
    case unsafePrivateRoot
    case unsafeSocketPath

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "shadow broker server is already running"
        case .interrupted: "shadow broker server was interrupted"
        case .liveSocket: "shadow broker socket is already live"
        case .socketChanged: "shadow broker socket changed during recovery"
        case .socketPathTooLong: "shadow broker socket path is too long"
        case .stopped: "shadow broker server stopped before listening"
        case let .systemCall(code): "shadow broker system call failed with errno \(code)"
        case .unsafePrivateRoot: "shadow broker private root is unsafe"
        case .unsafeSocketPath: "shadow broker socket path is unsafe"
        }
    }
}

private enum SocketProbeResult {
    case live
    case stale
}

private struct PreparedListener {
    let descriptor: Int32
    let identity: SocketIdentity
}

private struct SocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let owner: uid_t
    let linkCount: nlink_t

    var fileType: mode_t { mode & S_IFMT }
    var permissions: mode_t { mode & 0o777 }

    func isSameFile(as other: SocketIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

private func pathIdentity(at path: String) throws -> SocketIdentity {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return SocketIdentity(
        device: info.st_dev,
        inode: info.st_ino,
        mode: info.st_mode,
        owner: info.st_uid,
        linkCount: info.st_nlink
    )
}

private func socketIdentity(at path: String) throws -> SocketIdentity {
    let identity = try pathIdentity(at: path)
    guard identity.fileType == S_IFSOCK else { throw BrokerServerError.unsafeSocketPath }
    return identity
}
