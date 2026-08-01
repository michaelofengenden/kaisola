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

    // MARK: - Live smoke (no assertions beyond "did not crash")

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
}
