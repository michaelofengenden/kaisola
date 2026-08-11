import Darwin
import Foundation
import XCTest
@testable import Kaisola

/// Unit coverage for the pure `lsof`/`ps` parsers, plus one live
/// smoke test that only asserts `collect` does not crash.
final class TerminalMetaServiceTests: XCTestCase {

    // MARK: - parsePorts

    func testParsePortsExtractsWildcardAndBoundAddresses() {
        let output = """
        p611
        f11
        n*:3000
        f15
        n127.0.0.1:8080
        """
        XCTAssertEqual(TerminalMetaService.parsePorts(fromLsof: output), [3000, 8080])
    }

    func testParsePortsDedupesRepeatedPortAcrossFileDescriptors() {
        // Same port on two fds (as real lsof emits) collapses to one entry.
        let output = """
        p703
        f81
        n*:63646
        f87
        n*:63646
        """
        XCTAssertEqual(TerminalMetaService.parsePorts(fromLsof: output), [63646])
    }

    func testParsePortsHandlesIPv6BracketedAddress() {
        let output = "n[::1]:5432\nn[fe80::1]:5432"
        XCTAssertEqual(TerminalMetaService.parsePorts(fromLsof: output), [5432])
    }

    func testParsePortsSortsAscending() {
        let output = "n*:9000\nn*:22\nn127.0.0.1:8080\nn*:443"
        XCTAssertEqual(TerminalMetaService.parsePorts(fromLsof: output), [22, 443, 8080, 9000])
    }

    func testParsePortsCapsAtFiveLowestPorts() {
        let output = (1 ... 9).map { "n*:\(9000 - $0)" }.joined(separator: "\n")
        let ports = TerminalMetaService.parsePorts(fromLsof: output)
        XCTAssertEqual(ports.count, 5)
        // Cap is applied after sorting, so the five lowest survive.
        XCTAssertEqual(ports, [8991, 8992, 8993, 8994, 8995])
    }

    func testParsePortsIgnoresNonNameLinesAndGarbage() {
        let output = """
        p123
        f5
        t IPv4
        n*:*
        n127.0.0.1:notaport
        n1.2.3.4:4321->5.6.7.8:80
        n0.0.0.0:5173
        """
        // *:*  (no port), non-numeric, and the established peer (->) are dropped.
        XCTAssertEqual(TerminalMetaService.parsePorts(fromLsof: output), [5173])
    }

    func testParsePortsEmptyOutputYieldsNoPorts() {
        XCTAssertEqual(TerminalMetaService.parsePorts(fromLsof: ""), [])
    }

    // MARK: - process snapshot and chains

    func testProcessSnapshotPreservesCommandsWithSpacesAndSkipsGarbage() {
        let records = TerminalMetaService.parseProcessSnapshot(
            """
              100     1 /bin/zsh -il
              205   100 /opt/homebrew/bin/node /opt/tools/codex.js
            not a process
              300   205
            """
        )
        XCTAssertEqual(records[100], TerminalProcessRecord(pid: 100, parentPID: 1, command: "/bin/zsh -il"))
        XCTAssertEqual(
            records[205],
            TerminalProcessRecord(
                pid: 205,
                parentPID: 100,
                command: "/opt/homebrew/bin/node /opt/tools/codex.js"
            )
        )
        XCTAssertEqual(records[300], TerminalProcessRecord(pid: 300, parentPID: 205, command: ""))
        XCTAssertEqual(records.count, 3)
    }

    func testProcessChainsUseNewestDirectChildAndDeduplicateRoots() {
        let records = TerminalMetaService.parseProcessSnapshot(
            """
            100 1 /bin/zsh
            200 100 older-child
            205 100 newest-child
            300 205 codex
            400 1 /bin/fish
            """
        )
        let chains = TerminalMetaService.processChains(
            rootPIDs: [100, 400, 100, -1],
            recordsByPID: records
        )
        XCTAssertEqual(chains, [100: [100, 205, 300], 400: [400]])
    }

    // MARK: - batched lsof

    func testParsePortsByPIDKeepsProcessOwnership() {
        let output = """
        p100
        f4
        n*:3000
        p205
        f8
        n127.0.0.1:8080
        n127.0.0.1:8080
        p999
        n1.2.3.4:4321->5.6.7.8:80
        """
        XCTAssertEqual(
            TerminalMetaService.parsePortsByPID(fromLsof: output),
            [100: [3000], 205: [8080]]
        )
    }

    // MARK: - processName

    func testProcessNameStripsPathAndLoginDash() {
        XCTAssertEqual(TerminalMetaService.processName(fromComm: "/bin/zsh"), "zsh")
        XCTAssertEqual(TerminalMetaService.processName(fromComm: "-zsh"), "zsh")
        XCTAssertEqual(TerminalMetaService.processName(fromComm: "/usr/local/bin/node\n"), "node")
        XCTAssertNil(TerminalMetaService.processName(fromComm: "   "))
    }

    func testProcessNameRecognizesAgentCLIsBehindRuntimeWrappers() {
        XCTAssertEqual(
            TerminalMetaService.processName(
                fromCommand: "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
            ),
            "codex"
        )
        XCTAssertEqual(TerminalMetaService.processName(fromCommand: "/usr/local/bin/claude --resume"), "claude")
        XCTAssertEqual(TerminalMetaService.processName(fromCommand: "/bin/zsh -il"), "zsh")
    }

    /// Only the executable — and, behind a runtime, the script it is running —
    /// may name the program. Matching an agent marker anywhere in the argv is
    /// what would turn a plain shell into a Claude row the moment somebody
    /// opened a file under `~/.claude`.
    func testOnlyTheProgramItselfCanClaimAnAgentName() {
        // The real second link of a Claude chain: a shell sourcing a snapshot
        // out of ~/.claude. It is a `zsh`, not a `claude`.
        XCTAssertNil(TerminalMetaService.agentName(
            fromCommand: "/bin/zsh -c source /Users/m/.claude/shell-snapshots/snapshot-zsh-1785393435850-x7ft8i.sh"
        ))
        XCTAssertNil(TerminalMetaService.agentName(fromCommand: "vim /Users/m/.claude/settings.json"))
        // A checkout that merely lives under an agent-named folder is not that agent.
        XCTAssertNil(TerminalMetaService.agentName(fromCommand: "node /Users/m/Developer/claude-tools/bin/serve.js"))
        // …but the package that IS the agent still resolves, one directory up
        // from its entry point.
        XCTAssertEqual(
            TerminalMetaService.agentName(
                fromCommand: "node /Users/m/.nvm/versions/node/v22.3.0/lib/node_modules/"
                    + "@anthropic-ai/claude-code/cli.js"
            ),
            "claude"
        )
        XCTAssertEqual(TerminalMetaService.agentName(fromCommand: "npx -y @openai/codex"), "codex")
        XCTAssertEqual(TerminalMetaService.agentName(fromCommand: "python3 -m aider --model gpt-5"), "aider")
    }

    // MARK: - foregroundName (the chain scan)

    /// Captured live on 2026-08-01 from a Kaisola broker terminal with `claude`
    /// running in it — `ps -axo pid=,ppid=,command=`, verbatim.
    ///
    /// This is the bug: the deepest child is `sleep`, so naming the row from
    /// `chain.last` reported "sleep", the row fell back to the shell mark, and
    /// Claude's coral never rendered. Michael saw it as "it's not recognizing
    /// claude cli from the terminal and nor is it orange".
    private static let liveClaudeChain = """
      69807 40496 /bin/zsh -i
      69863 69807 claude
      99646 69863 /bin/zsh -c source /Users/michaelofengenden/.claude/shell-snapshots/\
    snapshot-zsh-1785393435850-x7ft8i.sh 2>/dev/null || true && export \
    CODEX_COMPANION_SESSION_ID='b6f70f4a-e10c-465f-b21e-55faca02b61c'
      74322 99646 sleep 10
    """

    /// Captured live on 2026-08-01 from a Terminal.app shell running `codex`.
    /// Same shape, different leaf: the agent spawns an MCP server, so the
    /// deepest child reports as `node`.
    private static let liveCodexChain = """
       2465  2464 -zsh
       2490  2465 node /Users/michaelofengenden/miniforge3/bin/codex
       2491  2490 /Users/michaelofengenden/miniforge3/lib/node_modules/@openai/codex/node_modules/\
    @openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex
      82486  2491 node ./mcp/server.cjs --stdio
    """

    func testRunningAgentIsFoundAnywhereInTheChainNotOnlyAtItsLeaf() {
        let claude = TerminalMetaService.parseProcessSnapshot(Self.liveClaudeChain)
        let claudeChain = TerminalMetaService.processChains(rootPIDs: [69807], recordsByPID: claude)[69807]
        XCTAssertEqual(claudeChain, [69807, 69863, 99646, 74322])
        // The old rule: name the row from the deepest child.
        XCTAssertEqual(TerminalMetaService.processName(fromCommand: claude[74322]?.command ?? ""), "sleep")
        // The rule that ships.
        XCTAssertEqual(
            TerminalMetaService.foregroundName(chain: claudeChain ?? [], recordsByPID: claude),
            "claude"
        )

        let codex = TerminalMetaService.parseProcessSnapshot(Self.liveCodexChain)
        let codexChain = TerminalMetaService.processChains(rootPIDs: [2465], recordsByPID: codex)[2465]
        XCTAssertEqual(codexChain, [2465, 2490, 2491, 82486])
        XCTAssertEqual(TerminalMetaService.processName(fromCommand: codex[82486]?.command ?? ""), "node")
        XCTAssertEqual(
            TerminalMetaService.foregroundName(chain: codexChain ?? [], recordsByPID: codex),
            "codex"
        )
    }

    /// The agent is the *ancestor* of its helpers, so the shallowest match wins.
    /// A Codex session that shells out to `claude` must stay a Codex row.
    func testShallowestAgentInTheChainWins() {
        let records = TerminalMetaService.parseProcessSnapshot(
            """
            100 1 /bin/zsh -i
            200 100 /opt/homebrew/bin/codex
            300 200 /bin/zsh -c claude -p 'summarise'
            400 300 /usr/local/bin/claude -p summarise
            """
        )
        let chain = TerminalMetaService.processChains(rootPIDs: [100], recordsByPID: records)[100] ?? []
        XCTAssertEqual(TerminalMetaService.foregroundName(chain: chain, recordsByPID: records), "codex")
    }

    /// No agent anywhere means the leaf still names the row — the chain scan
    /// must not become a catch-all that flattens every build to its shell.
    func testChainWithoutAnAgentIsStillNamedByItsLeaf() {
        let records = TerminalMetaService.parseProcessSnapshot(
            """
            100 1 /bin/zsh -i
            200 100 npm run build
            300 200 /opt/homebrew/bin/node /Users/m/app/node_modules/.bin/vite build
            """
        )
        let chain = TerminalMetaService.processChains(rootPIDs: [100], recordsByPID: records)[100] ?? []
        XCTAssertEqual(TerminalMetaService.foregroundName(chain: chain, recordsByPID: records), "node")

        // A lone shell is a shell.
        XCTAssertEqual(
            TerminalMetaService.foregroundName(chain: [100], recordsByPID: records),
            "zsh"
        )
        XCTAssertNil(TerminalMetaService.foregroundName(chain: [999], recordsByPID: records))
    }

    /// A link the snapshot lost between `ps` and the walk must not blank the
    /// row: the fallback keeps stepping back up the chain.
    func testMissingLeafRecordFallsBackToTheDeepestKnownLink() {
        let records = TerminalMetaService.parseProcessSnapshot(
            """
            100 1 /bin/zsh -i
            200 100 /usr/bin/ssh build-box
            """
        )
        XCTAssertEqual(
            TerminalMetaService.foregroundName(chain: [100, 200, 300], recordsByPID: records),
            "ssh"
        )
    }

    // MARK: - Live collector coverage

    func testCollectForOwnProcessDoesNotCrash() {
        let meta = TerminalMetaService.collect(pid: ProcessInfo.processInfo.processIdentifier)
        // We only require a well-formed value back; contents are environmental.
        XCTAssertLessThanOrEqual(meta.ports.count, 5)
        if let name = meta.processName {
            XCTAssertFalse(name.isEmpty)
        }
    }

    func testBatchCollectDeduplicatesAndRejectsInvalidPids() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let collected = TerminalMetaService.collect(pids: [pid, pid, 0, -1])
        XCTAssertEqual(Set(collected.keys), [pid])
        XCTAssertLessThanOrEqual(collected[pid]?.ports.count ?? 0, 5)
    }

    func testCollectRejectsNonPositivePid() {
        XCTAssertEqual(TerminalMetaService.collect(pid: 0), .empty)
        XCTAssertEqual(TerminalMetaService.collect(pid: -1), .empty)
    }

    func testControlledAgentChainResolvesThroughTheShippedCollector() throws {
        let harness = try TerminalAgentProcessHarness(agentDirectoryName: "codex")
        defer { harness.stopAndVerify() }

        let snapshot = try harness.snapshot()
        XCTAssertEqual(snapshot[harness.wrapperPID]?.parentPID, harness.rootPID)
        XCTAssertEqual(snapshot[harness.agentPID]?.parentPID, harness.wrapperPID)
        XCTAssertEqual(TerminalMetaService.agentName(
            fromCommand: snapshot[harness.agentPID]?.command ?? ""
        ), "codex")

        let meta = try harness.collect(untilProcessNameIs: "codex")
        XCTAssertEqual(meta.processName, "codex")
        XCTAssertEqual(
            QuietIdentity.identity(agentName: nil, processName: meta.processName),
            .openai
        )
    }

    func testControlledNonAgentChainDoesNotClaimAnAgentIdentity() throws {
        let harness = try TerminalAgentProcessHarness(agentDirectoryName: "ordinary-worker")
        defer { harness.stopAndVerify() }

        let snapshot = try harness.snapshot()
        let command = snapshot[harness.agentPID]?.command ?? ""
        XCTAssertNil(TerminalMetaService.agentName(fromCommand: command))
        let executable = try XCTUnwrap(command.split(whereSeparator: \.isWhitespace).first)
        XCTAssertEqual((String(executable) as NSString).lastPathComponent, "mock-agent")
        XCTAssertTrue(
            String(executable).contains("/ordinary-worker/"),
            "the controlled fixture must execute its scoped binary directly: \(command)"
        )
        let expectedName = try XCTUnwrap(TerminalMetaService.processName(fromCommand: command))
        XCTAssertEqual(expectedName, "mock-agent")
        XCTAssertNotEqual(expectedName, "codex")
        let meta = try harness.collect(untilProcessNameIs: expectedName)
        XCTAssertEqual(meta.processName, expectedName)
    }

    func testExitedControlledTreeCannotRetainAnAgentIdentity() throws {
        let harness = try TerminalAgentProcessHarness(agentDirectoryName: "codex")
        defer { harness.stopAndVerify() }
        let rootPID = harness.rootPID
        _ = try harness.collect(untilProcessNameIs: "codex")

        harness.stopAndVerify()

        XCTAssertEqual(TerminalMetaService.collect(pid: rootPID), .empty)
    }

    func testFreshSnapshotDropsAReparentedAgentFromTheTerminalRoot() {
        let attached = TerminalMetaService.parseProcessSnapshot(
            """
            100 1 /bin/zsh -i
            200 100 /bin/zsh /tmp/wrapper.zsh
            300 200 /usr/bin/python3 /tmp/codex/mock-agent.py
            """
        )
        let attachedChain = TerminalMetaService.processChains(
            rootPIDs: [100],
            recordsByPID: attached
        )[100] ?? []
        XCTAssertEqual(
            TerminalMetaService.foregroundName(chain: attachedChain, recordsByPID: attached),
            "codex"
        )

        let reparented = TerminalMetaService.parseProcessSnapshot(
            """
            100 1 /bin/zsh -i
            300 1 /usr/bin/python3 /tmp/codex/mock-agent.py
            """
        )
        let reparentedChain = TerminalMetaService.processChains(
            rootPIDs: [100],
            recordsByPID: reparented
        )[100] ?? []
        XCTAssertEqual(reparentedChain, [100])
        XCTAssertEqual(
            TerminalMetaService.foregroundName(chain: reparentedChain, recordsByPID: reparented),
            "zsh"
        )
    }

    func testFreshSnapshotDoesNotReuseAnExitedPIDsAgentIdentity() {
        let original = TerminalMetaService.parseProcessSnapshot(
            """
            100 1 /bin/zsh -i
            200 100 /usr/bin/python3 /tmp/codex/mock-agent.py
            """
        )
        let originalChain = TerminalMetaService.processChains(
            rootPIDs: [100],
            recordsByPID: original
        )[100] ?? []
        XCTAssertEqual(
            TerminalMetaService.foregroundName(chain: originalChain, recordsByPID: original),
            "codex"
        )

        let reused = TerminalMetaService.parseProcessSnapshot(
            """
            100 1 /bin/zsh -i
            200 100 /usr/bin/python3 /tmp/ordinary-worker/mock-agent.py
            """
        )
        let reusedChain = TerminalMetaService.processChains(
            rootPIDs: [100],
            recordsByPID: reused
        )[100] ?? []
        XCTAssertEqual(reusedChain, [100, 200])
        XCTAssertEqual(
            TerminalMetaService.foregroundName(chain: reusedChain, recordsByPID: reused),
            "python3"
        )
    }
}

private final class TerminalAgentProcessHarness {
    private(set) var rootPID: Int32 = 0
    private(set) var wrapperPID: Int32 = 0
    private(set) var agentPID: Int32 = 0

    private let directory: URL
    private let rootProcess: Process
    private let pidPrefix: URL
    private var stopped = false

    init(agentDirectoryName: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-terminal-agent-harness-\(UUID().uuidString)", isDirectory: true)
        pidPrefix = directory.appendingPathComponent("fixture", isDirectory: false)
        rootProcess = Process()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let agentDirectory = directory.appendingPathComponent(agentDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)

        let agentExecutable = agentDirectory.appendingPathComponent("mock-agent", isDirectory: false)
        let wrapperScript = directory.appendingPathComponent("wrapper.zsh", isDirectory: false)
        let rootScript = directory.appendingPathComponent("root.zsh", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            at: agentExecutable,
            withDestinationURL: URL(fileURLWithPath: "/bin/sleep")
        )
        try Self.write(
            """
            set -u
            agent="$1"
            prefix="$2"
            "$agent" 120 &
            child=$!
            print -r -- "$$" > "$prefix.wrapper"
            print -r -- "$child" > "$prefix.agent"
            print -r -- "ready" > "$prefix.ready"
            cleanup() {
              trap - TERM INT EXIT
              kill -TERM "$child" 2>/dev/null || true
              wait "$child" 2>/dev/null || true
            }
            trap cleanup TERM INT EXIT
            wait "$child"
            status=$?
            trap - TERM INT EXIT
            exit "$status"
            """,
            to: wrapperScript
        )
        try Self.write(
            """
            set -u
            wrapper="$1"
            agent="$2"
            prefix="$3"
            /bin/zsh "$wrapper" "$agent" "$prefix" &
            child=$!
            print -r -- "$$" > "$prefix.root"
            cleanup() {
              trap - TERM INT EXIT
              kill -TERM "$child" 2>/dev/null || true
              wait "$child" 2>/dev/null || true
            }
            trap cleanup TERM INT EXIT
            wait "$child"
            status=$?
            trap - TERM INT EXIT
            exit "$status"
            """,
            to: rootScript
        )

        rootProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        rootProcess.arguments = [rootScript.path, wrapperScript.path, agentExecutable.path, pidPrefix.path]
        rootProcess.environment = [
            "HOME": directory.path,
            "PATH": "/usr/bin:/bin",
            "TMPDIR": directory.path,
        ]
        rootProcess.standardInput = FileHandle.nullDevice
        rootProcess.standardOutput = FileHandle.nullDevice
        rootProcess.standardError = FileHandle.nullDevice
        try rootProcess.run()
        rootPID = rootProcess.processIdentifier

        do {
            try waitUntilReady()
        } catch {
            stopAndVerify()
            throw error
        }
    }

    func snapshot() throws -> [Int32: TerminalProcessRecord] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure("ps exited with status \(process.terminationStatus)")
        }
        return TerminalMetaService.parseProcessSnapshot(String(decoding: data, as: UTF8.self))
    }

    func collect(
        untilProcessNameIs expected: String,
        timeout: TimeInterval = 5
    ) throws -> TerminalMeta {
        let deadline = Date().addingTimeInterval(timeout)
        var last = TerminalMeta.empty
        repeat {
            last = TerminalMetaService.collect(pid: rootPID)
            if last.processName == expected { return last }
            Thread.sleep(forTimeInterval: 0.02)
        } while rootProcess.isRunning && Date() < deadline
        throw failure("collector returned \(last.processName ?? "nil") instead of \(expected)")
    }

    func stopAndVerify(file: StaticString = #filePath, line: UInt = #line) {
        guard !stopped else { return }
        stopped = true

        if rootProcess.isRunning { rootProcess.terminate() }
        if !waitForRootExit(timeout: 2), rootProcess.isRunning {
            _ = kill(rootPID, SIGKILL)
            _ = waitForRootExit(timeout: 2)
        }
        if !rootProcess.isRunning { rootProcess.waitUntilExit() }

        terminateTrackedFixture(agentPID)
        terminateTrackedFixture(wrapperPID)
        for pid in [agentPID, wrapperPID] where pid > 0 {
            do {
                let remainingCommand = try fixtureCommand(pid: pid)
                XCTAssertNil(
                    remainingCommand,
                    "fixture process \(pid) survived teardown",
                    file: file,
                    line: line
                )
            } catch {
                XCTFail(
                    "could not verify fixture process \(pid) teardown: \(error)",
                    file: file,
                    line: line
                )
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntilReady(timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !rootProcess.isRunning {
                throw failure("fixture root exited before publishing readiness")
            }
            if FileManager.default.fileExists(atPath: pidPrefix.appendingPathExtension("ready").path),
               let root = try? readPID(extension: "root"),
               let wrapper = try? readPID(extension: "wrapper"),
               let agent = try? readPID(extension: "agent"),
               root == rootPID,
               let records = try? snapshot(),
               records[wrapper]?.parentPID == root,
               records[agent]?.parentPID == wrapper,
               records[wrapper]?.command.contains(directory.path) == true,
               records[agent]?.command.contains(directory.path) == true {
                wrapperPID = wrapper
                agentPID = agent
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        throw failure("fixture did not publish one scoped shell-wrapper-agent chain")
    }

    private func readPID(extension pathExtension: String) throws -> Int32 {
        let value = try String(
            contentsOf: pidPrefix.appendingPathExtension(pathExtension),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(value), pid > 0 else {
            throw failure("invalid \(pathExtension) PID: \(value)")
        }
        return pid
    }

    private func terminateTrackedFixture(_ pid: Int32) {
        guard pid > 0, (try? fixtureCommand(pid: pid)) != nil else { return }
        _ = kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if (try? fixtureCommand(pid: pid)) == nil { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard (try? fixtureCommand(pid: pid)) != nil else { return }
        _ = kill(pid, SIGKILL)
        let killDeadline = Date().addingTimeInterval(1)
        while Date() < killDeadline, (try? fixtureCommand(pid: pid)) != nil {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func fixtureCommand(pid: Int32) throws -> String? {
        guard let command = try snapshot()[pid]?.command,
              command.contains(directory.path) else { return nil }
        return command
    }

    private func waitForRootExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while rootProcess.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !rootProcess.isRunning
    }

    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "TerminalAgentProcessHarness",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data((text + "\n").utf8).write(to: url, options: .atomic)
    }
}
