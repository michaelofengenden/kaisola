import Darwin
import Foundation

public enum DarwinPTYChildFailureStage: UInt8, Equatable, Sendable {
    case configuration = 1
    case loginTTY = 2
    case changeDirectory = 3
    case execute = 4
}

/// The deliberately tiny child side of the broker's PTY self-spawn protocol.
/// The parent maps only these three descriptors into a process launched with
/// the exact `--pty-child` argument. Command details never appear in argv or
/// the broker environment.
public enum DarwinPTYChild {
    static let slaveDescriptor: Int32 = 197
    static let configurationDescriptor: Int32 = 198
    static let statusDescriptor: Int32 = 199
    static let maximumConfigurationBytes = 1_048_576

    struct LaunchPayload: Codable, Sendable {
        let command: String
        let arguments: [String]
        let environment: [String: String]
        let cwd: String
    }

    /// This entry point never returns: success replaces the process image and
    /// failure reports a bounded binary status before `_exit`.
    public static func run() -> Never {
        guard setCloseOnExec(statusDescriptor) else {
            fail(stage: .configuration, code: errno)
        }

        let payload: LaunchPayload
        do {
            payload = try readPayload(from: configurationDescriptor)
        } catch let error as POSIXError {
            fail(stage: .configuration, code: error.code.rawValue)
        } catch {
            fail(stage: .configuration, code: EINVAL)
        }
        _ = Darwin.close(configurationDescriptor)

        guard Darwin.login_tty(slaveDescriptor) == 0 else {
            fail(stage: .loginTTY, code: errno)
        }
        guard Darwin.chdir(payload.cwd) == 0 else {
            fail(stage: .changeDirectory, code: errno)
        }

        let argumentValues = [payload.command] + payload.arguments
        let argumentStorage: [UnsafeMutablePointer<CChar>?] =
            argumentValues.map { strdup($0) } + [nil]
        let environmentStorage: [UnsafeMutablePointer<CChar>?] = payload.environment
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argumentStorage.dropLast().forEach { free($0) }
            environmentStorage.dropLast().forEach { free($0) }
        }

        _ = payload.command.withCString { executable in
            argumentStorage.withUnsafeBufferPointer { arguments in
                environmentStorage.withUnsafeBufferPointer { environment in
                    Darwin.execve(
                        executable,
                        UnsafeMutablePointer(mutating: arguments.baseAddress),
                        UnsafeMutablePointer(mutating: environment.baseAddress)
                    )
                }
            }
        }
        fail(stage: .execute, code: errno)
    }

    static func encodedPayload(_ payload: LaunchPayload) throws -> Data {
        let body = try JSONEncoder().encode(payload)
        guard !body.isEmpty, body.count <= maximumConfigurationBytes else {
            throw DarwinPTYError.invalidRequest("PTY child configuration exceeds the size limit")
        }
        var length = UInt32(body.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(body)
        return framed
    }

    private static func readPayload(from descriptor: Int32) throws -> LaunchPayload {
        var encodedLength = UInt32(0)
        try withUnsafeMutableBytes(of: &encodedLength) { bytes in
            try readExactly(descriptor, into: bytes)
        }
        let length = Int(UInt32(bigEndian: encodedLength))
        guard length > 0, length <= maximumConfigurationBytes else {
            throw POSIXError(.EINVAL)
        }
        var body = Data(count: length)
        try body.withUnsafeMutableBytes { bytes in
            try readExactly(descriptor, into: bytes)
        }
        return try JSONDecoder().decode(LaunchPayload.self, from: body)
    }

    private static func readExactly(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws {
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.read(
                descriptor,
                buffer.baseAddress?.advanced(by: offset),
                buffer.count - offset
            )
            if count > 0 {
                offset += count
            } else if count == 0 {
                throw POSIXError(.EPIPE)
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        return flags >= 0 && Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    private static func fail(stage: DarwinPTYChildFailureStage, code: Int32) -> Never {
        var nativeCode = code
        var bytes = [stage.rawValue]
        withUnsafeBytes(of: &nativeCode) { bytes.append(contentsOf: $0) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    statusDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        Darwin._exit(127)
    }
}
