import Darwin
import Foundation

enum DetachedBrokerProcess {
    static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw DetachedBrokerProcessError.couldNotInitialize
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addopen(
                &fileActions,
                descriptor,
                "/dev/null",
                O_RDWR,
                0
            ) == 0 else {
                throw DetachedBrokerProcessError.couldNotInitialize
            }
        }
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
            throw DetachedBrokerProcessError.couldNotInitialize
        }

        let argvValues = [executable.path] + arguments
        let environmentValues = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let argv = argvValues.map { strdup($0) } + [nil]
        let envp = environmentValues.map { strdup($0) } + [nil]
        defer {
            argv.dropLast().forEach { free($0) }
            envp.dropLast().forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { argumentBuffer in
            envp.withUnsafeBufferPointer { environmentBuffer in
                posix_spawn(
                    &pid,
                    executable.path,
                    &fileActions,
                    &attributes,
                    UnsafeMutablePointer(mutating: argumentBuffer.baseAddress),
                    UnsafeMutablePointer(mutating: environmentBuffer.baseAddress)
                )
            }
        }
        guard result == 0, pid > 1 else {
            throw DetachedBrokerProcessError.spawnFailed(result)
        }
        return pid
    }
}

enum DetachedBrokerProcessError: Error, Equatable {
    case couldNotInitialize
    case spawnFailed(Int32)
}
