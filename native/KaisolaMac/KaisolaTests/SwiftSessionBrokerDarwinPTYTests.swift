import Darwin
import Foundation
import XCTest
@testable import KaisolaSessionBrokerCore

final class SwiftSessionBrokerDarwinPTYTests: XCTestCase {
    func testFactoryBuildsAUserTerminalEnvironmentWithoutLeakingLauncherState() throws {
        let environment = try DarwinPTYProcessFactory.terminalEnvironment(
            inherited: [
                "HOME": "/Users/tester",
                "USER": "tester",
                "LOGNAME": "tester",
                "SHELL": "/bin/zsh",
                "PATH": "/custom/bin:/usr/bin:/bin",
                "TMPDIR": "/tmp/user/",
                "LANG": "en_US.UTF-8",
                "LC_CTYPE": "UTF-8",
                "SECRET_FROM_LAUNCHER": "must-not-leak",
                "CODEX_HOME": "/outer/codex",
                "NO_COLOR": "1",
                "TERM_SESSION_ID": "outer-terminal",
            ],
            overrides: [
                "CODEX_HOME": "/project/codex",
                "OPENAI_API_KEY": "explicit-project-value",
                "TERM": "dumb",
                "TERM_PROGRAM": "outer",
                "PROMPT_EOL_MARK": "%",
                "NO_COLOR": "",
                "FORCE_COLOR": "1",
                "CODEX_THREAD_ID": "outer-thread",
                "SHELL_SESSION_HISTORY": "/tmp/history",
            ],
            homeDirectory: "/fallback/home"
        )

        XCTAssertEqual(environment["HOME"], "/Users/tester")
        XCTAssertEqual(environment["USER"], "tester")
        XCTAssertEqual(environment["LOGNAME"], "tester")
        XCTAssertEqual(environment["SHELL"], "/bin/zsh")
        XCTAssertEqual(environment["TMPDIR"], "/tmp/user/")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["LC_CTYPE"], "UTF-8")
        XCTAssertEqual(environment["CODEX_HOME"], "/project/codex")
        XCTAssertEqual(environment["OPENAI_API_KEY"], "explicit-project-value")
        XCTAssertNil(environment["SECRET_FROM_LAUNCHER"])

        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(environment["SHELL_SESSIONS_DISABLE"], "1")
        XCTAssertEqual(environment["TERM_PROGRAM"], "Kaisola")
        XCTAssertEqual(environment["TERM_PROGRAM_VERSION"], "1")
        XCTAssertEqual(environment["PROMPT_EOL_MARK"], "")
        XCTAssertTrue(environment["PATH", default: ""].contains("/custom/bin"))
        XCTAssertTrue(environment["PATH", default: ""].contains("/opt/homebrew/bin"))

        for removed in [
            "NO_COLOR", "FORCE_COLOR", "CODEX_CI", "CODEX_MANAGED_BY_NPM",
            "CODEX_MANAGED_PACKAGE_ROOT", "CODEX_THREAD_ID", "TERM_SESSION_ID",
            "SHELL_SESSION_DID_INIT", "SHELL_SESSION_FILE", "SHELL_SESSION_HISTORY",
            "SHELL_SESSION_HISTFILE", "SHELL_SESSION_HISTFILE_NEW",
            "SHELL_SESSION_TIMESTAMP", "ELECTRON_RUN_AS_NODE", "KAISOLA_SESSION_BROKER",
        ] {
            XCTAssertNil(environment[removed], "leaked \(removed)")
        }
    }

    func testFactoryRejectsAnUnboundedRequestEnvironment() {
        let overrides = Dictionary(uniqueKeysWithValues: (0..<257).map {
            ("KEY_\($0)", String(repeating: "x", count: 8))
        })
        XCTAssertThrowsError(try DarwinPTYProcessFactory.terminalEnvironment(
            inherited: [:],
            overrides: overrides,
            homeDirectory: "/tmp"
        )) { error in
            guard case DarwinPTYError.invalidRequest = error else {
                return XCTFail("unexpected environment-bound error: \(error)")
            }
        }
    }

    func testFreshZshUsesRequestedInitialSizeAndRoundTripsInput() async throws {
        let output = PTYOutputRecorder()
        let process = try await spawnZsh(columns: 97, rows: 31, output: output)
        addTeardownBlock { _ = try? await process.terminate(graceNanoseconds: 100_000_000) }

        try process.write(Data("stty size; printf '__INITIAL_SIZE_DONE__\\n'\n".utf8))
        try await output.waitForExecutedLine("__INITIAL_SIZE_DONE__")
        XCTAssertTrue(output.normalizedText.contains("\n31 97\n"), output.text)

        try process.write(Data("printf '__ROUND_TRIP__:swift-pty\\n'\n".utf8))
        try await output.waitForExecutedLine("__ROUND_TRIP__:swift-pty")
    }

    func testResizeUpdatesTheLiveTerminalWindowSize() async throws {
        let output = PTYOutputRecorder()
        let process = try await spawnZsh(columns: 80, rows: 24, output: output)
        addTeardownBlock { _ = try? await process.terminate(graceNanoseconds: 100_000_000) }

        try process.resize(columns: 119, rows: 43)
        try process.write(Data("stty size; printf '__RESIZE_DONE__\\n'\n".utf8))
        try await output.waitForExecutedLine("__RESIZE_DONE__")
        XCTAssertTrue(output.normalizedText.contains("\n43 119\n"), output.text)
    }

    func testETXAndExplicitSIGINTReachTheForegroundProcessGroup() async throws {
        let output = PTYOutputRecorder()
        let process = try await spawnZsh(output: output)
        addTeardownBlock { _ = try? await process.terminate(graceNanoseconds: 100_000_000) }

        try process.write(Data("sleep 30\n".utf8))
        try await Task.sleep(for: .milliseconds(100))
        let beforeETX = output.byteCount
        try process.write(Data([0x03]))
        try await output.waitForRawText("\u{001B}[?2004h", afterByteOffset: beforeETX)
        try process.write(Data("printf '__AFTER_ETX__\\n'\n".utf8))
        try await output.waitForExecutedLine("__AFTER_ETX__")

        try process.write(Data("sleep 30\n".utf8))
        try await Task.sleep(for: .milliseconds(100))
        let beforeSignal = output.byteCount
        try process.send(signal: SIGINT)
        try await output.waitForRawText("\u{001B}[?2004h", afterByteOffset: beforeSignal)
        try process.write(Data("printf '__AFTER_SIGNAL__\\n'\n".utf8))
        try await output.waitForExecutedLine("__AFTER_SIGNAL__")
    }

    func testSpawnReportsMissingExecutableAndWorkingDirectoryBeforeSuccess() async throws {
        let helper = try brokerExecutablePath()
        let base = DarwinPTYSpawnRequest(
            command: "/definitely/missing/kaisola-command",
            arguments: [],
            environment: zshEnvironment(),
            cwd: "/tmp",
            columns: 80,
            rows: 24
        )

        await XCTAssertThrowsErrorAsync(
            try await DarwinPTYProcess.spawn(
                base,
                brokerExecutablePath: helper,
                onOutput: { _ in }
            )
        ) { error in
            guard case let DarwinPTYError.childSetupFailed(stage, code) = error else {
                return XCTFail("unexpected missing-executable error: \(error)")
            }
            XCTAssertEqual(stage, .execute)
            XCTAssertEqual(code, ENOENT)
        }

        let missingDirectory = DarwinPTYSpawnRequest(
            command: "/bin/zsh",
            arguments: ["-f", "-i"],
            environment: zshEnvironment(),
            cwd: "/tmp/kaisola-directory-that-must-not-exist",
            columns: 80,
            rows: 24
        )
        await XCTAssertThrowsErrorAsync(
            try await DarwinPTYProcess.spawn(
                missingDirectory,
                brokerExecutablePath: helper,
                onOutput: { _ in }
            )
        ) { error in
            guard case let DarwinPTYError.childSetupFailed(stage, code) = error else {
                return XCTFail("unexpected missing-cwd error: \(error)")
            }
            XCTAssertEqual(stage, .changeDirectory)
            XCTAssertEqual(code, ENOENT)
        }
    }

    func testWaitForExitReturnsOnlyAfterTheFinalPTYBytesAreDelivered() async throws {
        let output = PTYOutputRecorder()
        let finalMarker = "__FINAL_OUTPUT_BEFORE_EXIT__"
        let process = try await DarwinPTYProcess.spawn(
            DarwinPTYSpawnRequest(
                command: "/bin/zsh",
                arguments: ["-f", "-i"],
                environment: zshEnvironment(),
                cwd: "/tmp",
                columns: 80,
                rows: 24
            ),
            brokerExecutablePath: try brokerExecutablePath()
        ) { data in
            if String(decoding: data, as: UTF8.self).contains(finalMarker) {
                usleep(200_000)
            }
            output.append(data)
        }
        addTeardownBlock { _ = try? await process.terminate(graceNanoseconds: 100_000_000) }

        // The full marker is deliberately absent from the echoed command, so
        // only bytes produced by the command can satisfy the assertion.
        try process.write(Data("printf '__FINAL_%s__\\n' OUTPUT_BEFORE_EXIT; exit\n".utf8))
        let exit = await process.waitForExit()

        XCTAssertEqual(exit.exitCode, 0)
        XCTAssertTrue(
            output.normalizedText.contains(finalMarker),
            "waitForExit beat the final output callback: \(output.text)"
        )
    }

    func testTerminateKillsTheForegroundDescendantGroupReapsTheLeaderAndIsIdempotent() async throws {
        let output = PTYOutputRecorder()
        let process = try await spawnZsh(output: output)

        try process.write(Data(
            "zsh -f -c 'trap \"\" HUP TERM; printf \"__DESCENDANT__:%d\\n\" $$; while :; do sleep 30; done'\n".utf8
        ))
        let descendant = try await output.waitForPID(prefix: "__DESCENDANT__:")
        XCTAssertTrue(isAlive(descendant))

        let started = ContinuousClock.now
        let firstExit = try await process.terminate(graceNanoseconds: 100_000_000)
        let elapsed = started.duration(to: .now)
        let secondExit = try await process.terminate(graceNanoseconds: 100_000_000)

        XCTAssertEqual(firstExit, secondExit)
        XCTAssertLessThan(elapsed, .seconds(3))
        XCTAssertFalse(
            isAlive(descendant),
            "terminate returned before captured descendant \(descendant) was gone"
        )
        XCTAssertFalse(isAlive(process.pid), "PTY leader \(process.pid) was not reaped")
    }

    func testSIGKILLTargetsTheWholeOwnedSessionAndWaitForExitReapsTheLeader() async throws {
        let output = PTYOutputRecorder()
        let process = try await spawnZsh(output: output)
        addTeardownBlock { _ = try? await process.terminate(graceNanoseconds: 100_000_000) }

        try process.write(Data(
            "zsh -f -c 'trap \"\" HUP TERM; printf \"__KILL_DESCENDANT__:%d\\n\" $$; while :; do sleep 30; done'\n".utf8
        ))
        let descendant = try await output.waitForPID(prefix: "__KILL_DESCENDANT__:")

        try process.send(signal: SIGKILL)
        let exit = try await exitWithinTwoSeconds(process)

        XCTAssertEqual(exit.terminatingSignal, SIGKILL)
        XCTAssertFalse(isAlive(process.pid), "SIGKILL did not reap the shell leader")
        XCTAssertFalse(isAlive(descendant), "SIGKILL left an owned descendant alive")
    }

    private func spawnZsh(
        columns: UInt16 = 80,
        rows: UInt16 = 24,
        output: PTYOutputRecorder
    ) async throws -> DarwinPTYProcess {
        let process = try await DarwinPTYProcess.spawn(
            DarwinPTYSpawnRequest(
                command: "/bin/zsh",
                arguments: ["-f", "-i"],
                environment: zshEnvironment(),
                cwd: "/tmp",
                columns: columns,
                rows: rows
            ),
            brokerExecutablePath: try brokerExecutablePath(),
            onOutput: { output.append($0) }
        )
        let readiness = "__KAISOLA_PTY_READY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        try process.write(Data(
            "PS1='\(readiness) '; PROMPT='\(readiness) '; printf '\\n\(readiness)\\n'\n".utf8
        ))
        try await output.waitForExecutedLine(readiness)
        return process
    }

    private func zshEnvironment() -> [String: String] {
        [
            "HOME": "/tmp",
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PROMPT": "",
            "PS1": "",
            "RPROMPT": "",
            "TERM": "xterm-256color",
            "TMPDIR": "/tmp",
        ]
    }

    private func brokerExecutablePath() throws -> String {
        var candidate = Bundle(for: Self.self).bundleURL
        for _ in 0..<8 {
            let executable = candidate.appendingPathComponent("KaisolaSessionBroker")
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                return executable.path
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(
            domain: "SwiftSessionBrokerDarwinPTYTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate KaisolaSessionBroker"]
        )
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func exitWithinTwoSeconds(_ process: DarwinPTYProcess) async throws -> DarwinPTYExit {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while isAlive(process.pid), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !isAlive(process.pid) else {
            throw NSError(
                domain: "SwiftSessionBrokerDarwinPTYTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "timed out waiting for PTY exit"]
            )
        }
        return await process.waitForExit()
    }

}

private final class PTYOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) {
        lock.lock()
        bytes.append(data)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes.count
    }

    var normalizedText: String {
        text
            // zsh's interactive line editor terminates an accepted command
            // with CR followed by the PTY's CRLF newline. Collapse that
            // three-byte sequence before ordinary CRLF normalization; Swift
            // otherwise retains a CRLF grapheme whose LF cannot match `\n`.
            .replacingOccurrences(of: "\r\r\n", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func text(afterByteOffset offset: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let boundedOffset = min(max(offset, 0), bytes.count)
        return String(decoding: bytes.dropFirst(boundedOffset), as: UTF8.self)
    }

    func waitForExecutedLine(_ line: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if normalizedText.contains("\n\(line)\n") { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "SwiftSessionBrokerDarwinPTYTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for executed line \(line); output=\(text)"]
        )
    }

    func waitForRawText(_ value: String, afterByteOffset offset: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let suffix = text(afterByteOffset: offset)
            if suffix.contains(value) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "SwiftSessionBrokerDarwinPTYTests",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for raw PTY text after offset \(offset); output=\(text)"]
        )
    }

    func waitForPID(prefix: String) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let expression = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: prefix) + "([0-9]+)")
            let snapshot = normalizedText
            let range = NSRange(snapshot.startIndex..<snapshot.endIndex, in: snapshot)
            if let match = expression.firstMatch(in: snapshot, range: range),
               let swiftRange = Range(match.range(at: 1), in: snapshot),
               let pid = pid_t(snapshot[swiftRange]),
               pid > 1 {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(
            domain: "SwiftSessionBrokerDarwinPTYTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for PID \(prefix); output=\(text)"]
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
