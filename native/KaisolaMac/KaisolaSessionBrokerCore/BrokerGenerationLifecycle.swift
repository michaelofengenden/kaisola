import Darwin
import Foundation

/// Owns the two filesystem authorities that make a detached broker generation
/// discoverable. The lock is acquired before the socket is touched; metadata
/// is published only after the listener is installed. Both files are removed
/// only when their device/inode identities still match what this process made.
final class BrokerGenerationLifecycle: @unchecked Sendable {
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
        }
    }

    private struct BrokerInfoPayload: Encodable {
        let protocolVersion: Int
        let securityEpoch: Int
        let implementationVersion: Int
        let packageSchema: Int
        let packageVersion: String
        let contentDigest: String
        let pid: Int32
        let socketPath: String
        let token: String
        let startedAt: Int64
        let version: String

        private enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case securityEpoch
            case implementationVersion
            case packageSchema
            case packageVersion
            case contentDigest
            case pid
            case socketPath
            case token
            case startedAt
            case version
        }
    }

    private enum OwnerHintReadError: Error {
        case unsafeFile
    }

    private let lockURL: URL
    private let infoURL: URL
    private let logURL: URL
    private let payload: BrokerInfoPayload
    private let stateLock = NSLock()
    private var lockDescriptor: Int32
    private var lockIdentity: FileIdentity
    private var infoIdentity: FileIdentity?
    private var cleaned = false

    init(configuration: ShadowBrokerConfiguration, pid: Int32 = getpid()) throws {
        guard configuration.runtimeMode == .launch,
              let packageVersion = configuration.packageVersion,
              let lockFile = configuration.lockFile,
              let infoFile = configuration.infoFile,
              let logFile = configuration.logFile,
              let startedAt = configuration.startedAt,
              let version = configuration.version else {
            throw BrokerGenerationLifecycleError.invalidConfiguration
        }
        let lockURL = URL(fileURLWithPath: lockFile)
        let infoURL = URL(fileURLWithPath: infoFile)
        let logURL = URL(fileURLWithPath: logFile)
        guard lockURL.deletingLastPathComponent() == infoURL.deletingLastPathComponent(),
              infoURL.deletingLastPathComponent() == logURL.deletingLastPathComponent() else {
            throw BrokerGenerationLifecycleError.invalidConfiguration
        }
        try Self.validatePrivateDirectory(lockURL.deletingLastPathComponent())

        let lock = try Self.acquireGenerationLock(
            lockURL: lockURL,
            infoURL: infoURL,
            logURL: logURL,
            pid: pid
        )
        self.lockURL = lockURL
        self.infoURL = infoURL
        self.logURL = logURL
        lockDescriptor = lock.descriptor
        lockIdentity = lock.identity
        payload = BrokerInfoPayload(
            protocolVersion: configuration.protocolVersion,
            securityEpoch: configuration.securityEpoch,
            implementationVersion: configuration.implementationVersion,
            packageSchema: configuration.packageSchema,
            packageVersion: packageVersion,
            contentDigest: configuration.contentDigest,
            pid: pid,
            socketPath: configuration.socketPath,
            token: configuration.token,
            startedAt: startedAt,
            version: version
        )
    }

    deinit {
        cleanup()
    }

    /// The listener is already bound, mode-checked, and installed when this is
    /// called. A failed first publication aborts this empty candidate instead
    /// of leaving a live but undiscoverable generation behind.
    func publish() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let identity = try Self.writeAtomically(data, to: infoURL)
        stateLock.lock()
        if cleaned {
            stateLock.unlock()
            Self.unlinkIfUnchanged(infoURL, identity: identity)
            throw BrokerGenerationLifecycleError.alreadyCleaned
        }
        infoIdentity = identity
        stateLock.unlock()
    }

    func cleanup() {
        let descriptor: Int32
        let ownedLock: FileIdentity
        let ownedInfo: FileIdentity?
        stateLock.lock()
        if cleaned {
            stateLock.unlock()
            return
        }
        cleaned = true
        descriptor = lockDescriptor
        lockDescriptor = -1
        ownedLock = lockIdentity
        ownedInfo = infoIdentity
        infoIdentity = nil
        stateLock.unlock()

        if descriptor >= 0 { Darwin.close(descriptor) }
        if let ownedInfo { Self.unlinkIfUnchanged(infoURL, identity: ownedInfo) }
        Self.unlinkIfUnchanged(lockURL, identity: ownedLock)
    }

    private static func acquireGenerationLock(
        lockURL: URL,
        infoURL: URL,
        logURL: URL,
        pid: Int32
    ) throws -> (descriptor: Int32, identity: FileIdentity) {
        // The lock must never exist without its owner's pid inside: creating
        // it empty and writing afterwards leaves a window in which a
        // concurrent relaunch (either runtime) reads an ownerless lock and
        // takes it over. Hard-linking a pre-written claim file makes creation
        // and content one atomic step — the same contract as the Node broker.
        let claimURL = lockURL.deletingLastPathComponent()
            .appendingPathComponent("\(lockURL.lastPathComponent).\(pid).claim")
        defer { _ = unlink(claimURL.path) }
        for attempt in 0..<2 {
            let claimIdentity = try writeClaim(at: claimURL, pid: pid)
            if link(claimURL.path, lockURL.path) == 0 {
                // Drop the claim's extra link before validating, so the lock
                // settles to nlink == 1 as fast as a reader can observe it.
                _ = unlink(claimURL.path)
                let descriptor = Darwin.open(
                    lockURL.path,
                    O_RDWR | O_CLOEXEC | O_NOFOLLOW
                )
                guard descriptor >= 0 else {
                    throw BrokerGenerationLifecycleError.systemCall(errno)
                }
                do {
                    var value = stat()
                    guard fstat(descriptor, &value) == 0,
                          FileIdentity(value) == claimIdentity,
                          value.st_uid == geteuid(),
                          value.st_mode & S_IFMT == S_IFREG,
                          value.st_mode & 0o777 == 0o600,
                          value.st_nlink == 1 else {
                        throw BrokerGenerationLifecycleError.unsafeLock
                    }
                    // Held for the broker's lifetime and released by close:
                    // the app-side stale cleanup arbitrates with
                    // flock(LOCK_EX | LOCK_NB), so the kernel is the single
                    // referee between a live broker and a cleanup pass.
                    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                        throw BrokerGenerationLifecycleError.lockHeld(nil)
                    }
                    return (descriptor, FileIdentity(value))
                } catch {
                    Darwin.close(descriptor)
                    unlinkIfUnchanged(lockURL, identity: claimIdentity)
                    if let lifecycleError = error as? BrokerGenerationLifecycleError,
                       lifecycleError.isGenerationLockUnavailable {
                        appendLog(
                            "generation lock unavailable \(lifecycleError.logCode) \(lifecycleError.localizedDescription)",
                            to: logURL
                        )
                    }
                    throw error
                }
            }

            let creationError = errno
            guard creationError == EEXIST, attempt == 0 else {
                let error = creationError == EEXIST
                    ? BrokerGenerationLifecycleError.lockHeld(nil)
                    : BrokerGenerationLifecycleError.systemCall(creationError)
                appendLog("generation lock unavailable \(error.logCode) \(error.localizedDescription)", to: logURL)
                throw error
            }

            var stale = stat()
            guard lstat(lockURL.path, &stale) == 0 else {
                if errno == ENOENT { continue }
                appendLog("generation lock unavailable ELOCKHELD unreadable lock", to: logURL)
                throw BrokerGenerationLifecycleError.lockHeld(nil)
            }
            guard stale.st_mode & S_IFMT == S_IFREG else {
                appendLog("generation lock unavailable ELOCKHELD unsafe lock", to: logURL)
                throw BrokerGenerationLifecycleError.unsafeLock
            }

            // Match the Node recovery contract exactly: an absent or malformed
            // owner hint is "unrecorded"; a valid PID from either authority
            // blocks takeover when kill(pid, 0) succeeds or returns EPERM —
            // but only when its authority file was written since the last
            // boot. No pre-boot process survives a reboot, so a living pid
            // recorded pre-boot can only be a post-reboot recycle.
            let owners: [(pid: Int32, authority: URL)]
            do {
                let hints: [(Int32?, URL)] = try [
                    (recordedLockPID(at: lockURL), lockURL),
                    (publishedRendezvousPID(at: infoURL), infoURL),
                ]
                owners = hints
                    .compactMap { hint in hint.0.map { (pid: $0, authority: hint.1) } }
                    .filter { $0.pid != pid }
            } catch {
                appendLog(
                    "generation lock unavailable ELOCKHELD unsafe owner authority",
                    to: logURL
                )
                throw BrokerGenerationLifecycleError.lockHeld(nil)
            }
            if let living = owners.first(where: { writtenSinceBoot($0.authority) && pidIsAlive($0.pid) }) {
                let error = BrokerGenerationLifecycleError.lockHeld(living.pid)
                appendLog("generation lock unavailable ELOCKHELD held by live pid \(living.pid)", to: logURL)
                throw error
            }

            // Remove only the exact inode judged stale. A concurrent fresh
            // owner that replaced the path must survive this takeover attempt.
            var current = stat()
            if lstat(lockURL.path, &current) == 0 {
                guard current.st_mode & S_IFMT == S_IFREG,
                      current.st_dev == stale.st_dev,
                      current.st_ino == stale.st_ino else {
                    appendLog("generation lock unavailable ELOCKHELD lock changed", to: logURL)
                    throw BrokerGenerationLifecycleError.lockHeld(nil)
                }
                guard unlink(lockURL.path) == 0 else {
                    if errno == ENOENT { continue }
                    throw BrokerGenerationLifecycleError.systemCall(errno)
                }
            } else if errno != ENOENT {
                throw BrokerGenerationLifecycleError.systemCall(errno)
            }
            let ownerDescription = owners.isEmpty
                ? "unrecorded"
                : owners.map { String($0.pid) }.joined(separator: ",")
            appendLog(
                "recovered stale generation lock deadOwner=\(ownerDescription)",
                to: logURL
            )
        }
        throw BrokerGenerationLifecycleError.lockHeld(nil)
    }

    /// The claim carries the owner pid before the lock path ever exists.
    /// O_TRUNC rather than O_EXCL: a crashed earlier run of this same pid can
    /// leave its claim behind, and pid identity makes reuse safe.
    private static func writeClaim(at claimURL: URL, pid: Int32) throws -> FileIdentity {
        let descriptor = Darwin.open(
            claimURL.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw BrokerGenerationLifecycleError.systemCall(errno)
        }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw BrokerGenerationLifecycleError.systemCall(errno)
        }
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_uid == geteuid(),
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o777 == 0o600,
              value.st_nlink == 1 else {
            throw BrokerGenerationLifecycleError.unsafeLock
        }
        try writeAll(Data("\(pid)\n".utf8), to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw BrokerGenerationLifecycleError.systemCall(errno)
        }
        return FileIdentity(value)
    }

    /// A file written before the last boot cannot have a living owner,
    /// whatever kill(0) says about a recycled pid. The minute of slack errs
    /// toward "written after boot", which fails closed; an unreadable boot
    /// time also fails closed by treating every file as post-boot.
    private static func writtenSinceBoot(_ url: URL) -> Bool {
        guard let boot = bootTime() else { return true }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return false }
        let modified = Double(value.st_mtimespec.tv_sec)
            + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000
        return modified > boot.timeIntervalSince1970 - 60
    }

    private static func bootTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&name, 2, &value, &size, nil, 0) == 0, value.tv_sec > 0 else {
            return nil
        }
        return Date(
            timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        )
    }

    private static func recordedLockPID(at url: URL) throws -> Int32? {
        guard let data = try readPrivateFile(at: url, maximumBytes: 128),
              let value = String(data: data, encoding: .utf8),
              let parsed = nodeStyleDecimalPID(value),
              parsed > 1 else { return nil }
        return parsed
    }

    /// Node's `Number.parseInt(..., 10)` deliberately accepts a decimal
    /// prefix. Mirroring it matters for fail-closed takeover: a live owner
    /// recorded as `123 trailing-data` must still prevent lock replacement.
    private static func nodeStyleDecimalPID(_ value: String) -> Int32? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bytes = Array(trimmed.utf8)
        var index = 0
        var sign: Int64 = 1
        if bytes[index] == 43 { // "+"
            index += 1
        } else if bytes[index] == 45 { // "-"
            sign = -1
            index += 1
        }
        let digitStart = index
        var magnitude: Int64 = 0
        while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
            let digit = Int64(bytes[index] - 48)
            guard magnitude <= (Int64.max - digit) / 10 else { return nil }
            magnitude = magnitude * 10 + digit
            index += 1
        }
        guard index > digitStart,
              let pid = Int32(exactly: sign * magnitude) else { return nil }
        return pid
    }

    private static func publishedRendezvousPID(at url: URL) throws -> Int32? {
        guard let data = try readPrivateFile(at: url, maximumBytes: 64 * 1_024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["pid"],
              let parsed = nodeStyleNumberPID(value),
              parsed > 1 else { return nil }
        return parsed
    }

    /// Mirrors JavaScript `Number(value)` for the scalar forms that a JSON PID
    /// can legitimately use, then applies Node's safe-integer requirement.
    /// Non-integral numbers must not be truncated into a different live PID.
    private static func nodeStyleNumberPID(_ value: Any) -> Int32? {
        let number: Double
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let lowercased = trimmed.lowercased()
            let radixValue: UInt64?
            if lowercased.hasPrefix("0x") {
                radixValue = UInt64(lowercased.dropFirst(2), radix: 16)
            } else if lowercased.hasPrefix("0b") {
                radixValue = UInt64(lowercased.dropFirst(2), radix: 2)
            } else if lowercased.hasPrefix("0o") {
                radixValue = UInt64(lowercased.dropFirst(2), radix: 8)
            } else {
                radixValue = nil
            }
            if lowercased.hasPrefix("0x")
                || lowercased.hasPrefix("0b")
                || lowercased.hasPrefix("0o") {
                guard let radixValue else { return nil }
                number = Double(radixValue)
            } else {
                guard let parsed = Double(trimmed) else { return nil }
                number = parsed
            }
        } else {
            return nil
        }
        guard number.isFinite,
              number.rounded(.towardZero) == number,
              abs(number) <= 9_007_199_254_740_991,
              let signed = Int64(exactly: number),
              let pid = Int32(exactly: signed) else { return nil }
        return pid
    }

    private static func readPrivateFile(at url: URL, maximumBytes: Int) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw OwnerHintReadError.unsafeFile
        }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_uid == geteuid(),
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o077 == 0,
              value.st_nlink == 1,
              value.st_size >= 0,
              value.st_size <= maximumBytes else {
            throw OwnerHintReadError.unsafeFile
        }
        var data = Data()
        data.reserveCapacity(Int(value.st_size))
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while data.count < maximumBytes {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes - data.count))
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw OwnerHintReadError.unsafeFile
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var extra: UInt8 = 0
        guard Darwin.read(descriptor, &extra, 1) == 0 else {
            throw OwnerHintReadError.unsafeFile
        }
        return data
    }

    private static func pidIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws -> FileIdentity {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(getpid()).\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw BrokerGenerationLifecycleError.systemCall(errno)
        }
        var temporaryExists = true
        var publishedIdentity: FileIdentity?
        var publicationComplete = false
        defer {
            Darwin.close(descriptor)
            if temporaryExists { _ = unlink(temporary.path) }
            if !publicationComplete, let publishedIdentity {
                unlinkIfUnchanged(destination, identity: publishedIdentity)
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw BrokerGenerationLifecycleError.systemCall(errno)
        }
        var temporaryMetadata = stat()
        guard fstat(descriptor, &temporaryMetadata) == 0,
              temporaryMetadata.st_uid == geteuid(),
              temporaryMetadata.st_mode & S_IFMT == S_IFREG,
              temporaryMetadata.st_mode & 0o777 == 0o600,
              temporaryMetadata.st_nlink == 1 else {
            throw BrokerGenerationLifecycleError.unsafeInfo
        }
        let temporaryIdentity = FileIdentity(temporaryMetadata)
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw BrokerGenerationLifecycleError.systemCall(errno)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw BrokerGenerationLifecycleError.systemCall(errno)
        }
        temporaryExists = false
        publishedIdentity = temporaryIdentity
        synchronizeDirectory(destination.deletingLastPathComponent())
        var value = stat()
        guard lstat(destination.path, &value) == 0,
              FileIdentity(value) == temporaryIdentity,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o777 == 0o600,
              value.st_nlink == 1 else {
            throw BrokerGenerationLifecycleError.unsafeInfo
        }
        publicationComplete = true
        return temporaryIdentity
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw BrokerGenerationLifecycleError.systemCall(errno)
                }
                guard count > 0 else {
                    throw BrokerGenerationLifecycleError.systemCall(EIO)
                }
                offset += count
            }
        }
    }

    private static func appendLog(_ message: String, to url: URL) {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              value.st_uid == geteuid(),
              value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else { return }
        try? writeAll(Data("\(message)\n".utf8), to: descriptor)
    }

    private static func validatePrivateDirectory(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_uid == geteuid(),
              value.st_mode & S_IFMT == S_IFDIR,
              value.st_mode & 0o777 == 0o700 else {
            throw BrokerGenerationLifecycleError.unsafeDirectory
        }
    }

    private static func synchronizeDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        Darwin.close(descriptor)
    }

    private static func unlinkIfUnchanged(_ url: URL, identity: FileIdentity) {
        var current = stat()
        guard lstat(url.path, &current) == 0,
              FileIdentity(current) == identity else { return }
        _ = unlink(url.path)
    }
}

public enum BrokerGenerationLifecycleError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case unsafeDirectory
    case unsafeLock
    case unsafeInfo
    case lockHeld(Int32?)
    case alreadyCleaned
    case systemCall(Int32)

    var logCode: String {
        switch self {
        case .lockHeld: "ELOCKHELD"
        case let .systemCall(code): String(cString: strerror(code))
        default: "ELOCKHELD"
        }
    }

    public var isGenerationLockUnavailable: Bool {
        switch self {
        case .lockHeld, .unsafeLock: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The production broker launch identity is incomplete."
        case .unsafeDirectory: "The generation metadata directory is not private."
        case .unsafeLock: "The generation lock is not a safe regular file."
        case .unsafeInfo: "The generation rendezvous is not a safe regular file."
        case let .lockHeld(pid):
            pid.map { "The generation lock is held by live pid \($0)." }
                ?? "The generation lock is unavailable."
        case .alreadyCleaned: "The generation stopped before rendezvous publication."
        case let .systemCall(code):
            "The generation lifecycle system call failed: \(String(cString: strerror(code)))."
        }
    }
}
