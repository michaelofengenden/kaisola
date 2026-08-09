import Foundation
import XCTest
@testable import Kaisola

/// AcpTerminalHost against real child processes: create/output/wait/kill/release
/// semantics the ACP terminal bridge exposes to agents.
final class AcpTerminalHostTests: XCTestCase {

    func testSnapshotFixtureDefaultsToAnEmptyBacklogState() {
        let snapshot = AcpTerminalHost.Snapshot(
            output: "fixture",
            truncated: false,
            exitStatus: nil
        )

        XCTAssertEqual(snapshot.outputBufferStats, .empty)
    }

    func testSegmentedOutputTailSustainsMaximumCaptureWithoutMovingRetainedBytes() {
        let chunkByteCount = AcpTerminalHost.outputStreamChunkByteLimit
        let retainedChunkCount = AcpTerminalHost.maxOutputByteLimit / chunkByteCount
        let totalChunkCount = retainedChunkCount * 16
        var tail = AcpTerminalHost.SegmentedOutputTail(
            byteLimit: AcpTerminalHost.maxOutputByteLimit
        )

        // Exercise 128 MiB of sustained output while the retained tail remains
        // pinned at the maximum 8 MiB. The deterministic movement counters are
        // the primary complexity contract; this generous wall limit catches a
        // regression to repeated multi-megabyte front shifts without acting as
        // a microbenchmark.
        let clock = ContinuousClock()
        let start = clock.now
        for sequence in 0..<totalChunkCount {
            let byte = UInt8(sequence % 95 + 32)
            tail.append(Data(repeating: byte, count: chunkByteCount))
        }
        let elapsed = start.duration(to: clock.now)

        let metrics = tail.metrics
        XCTAssertEqual(metrics.appendedBytes, UInt64(totalChunkCount * chunkByteCount))
        XCTAssertEqual(
            metrics.discardedBytes,
            UInt64((totalChunkCount - retainedChunkCount) * chunkByteCount)
        )
        XCTAssertEqual(metrics.retainedBytes, AcpTerminalHost.maxOutputByteLimit)
        XCTAssertEqual(metrics.storedSegmentBytes, AcpTerminalHost.maxOutputByteLimit)
        XCTAssertLessThanOrEqual(metrics.peakRetainedBytes, AcpTerminalHost.maxOutputByteLimit)
        XCTAssertLessThanOrEqual(
            metrics.peakStoredSegmentBytes,
            AcpTerminalHost.maxOutputByteLimit + chunkByteCount
        )
        XCTAssertEqual(metrics.enqueuedSegments, UInt64(totalChunkCount))
        XCTAssertEqual(metrics.dequeuedSegments, UInt64(totalChunkCount - retainedChunkCount))
        XCTAssertEqual(metrics.partialHeadAdvances, 0)
        XCTAssertEqual(metrics.bytesMovedWhileTrimming, 0)
        XCTAssertLessThan(elapsed, .seconds(15), "sustained bounded capture took \(elapsed)")

        var expected = Data()
        expected.reserveCapacity(AcpTerminalHost.maxOutputByteLimit)
        for sequence in (totalChunkCount - retainedChunkCount)..<totalChunkCount {
            let byte = UInt8(sequence % 95 + 32)
            expected.append(
                Data(repeating: byte, count: chunkByteCount)
            )
        }
        XCTAssertEqual(tail.materialized(), expected)
        XCTAssertTrue(tail.truncated)
    }

    func testSegmentedOutputTailPreservesContiguousUTF8SuffixAcrossSegmentsAndGaps() {
        var tail = AcpTerminalHost.SegmentedOutputTail(byteLimit: 5)
        tail.append(Data([0x78, 0x78, 0xF0, 0x9F]))
        tail.append(Data([0x8C, 0x8D, 0x21]))
        XCTAssertEqual(String(decoding: tail.materialized(), as: UTF8.self), "🌍!")
        XCTAssertEqual(tail.metrics.retainedBytes, 5)
        XCTAssertTrue(tail.truncated)

        tail.discardForDiscontinuity()
        tail.append(Data([0x80, 0x81, 0x6E, 0x65, 0x77]))
        XCTAssertEqual(String(decoding: tail.materialized(), as: UTF8.self), "new")
        XCTAssertEqual(tail.metrics.retainedBytes, 3)
    }

    func testHighThroughputOutputBacklogStaysWithinDeclaredCeilingAndAccountsForDrops() async {
        let (stream, buffer) = AcpTerminalHost.makeOutputStream()
        let chunk = Data(repeating: 0x78, count: AcpTerminalHost.outputStreamChunkByteLimit)
        let totalChunks = AcpTerminalHost.outputStreamBufferedChunkLimit * 256

        // Deliberately hold the consumer while the producer offers 1 GiB of
        // logical output. This deterministically saturates the bufferingNewest
        // policy without relying on scheduler timing or noisy process RSS.
        for _ in 0..<totalChunks {
            buffer.yield(chunk)
        }

        let saturated = buffer.state().stats
        let expectedDroppedChunks = totalChunks - AcpTerminalHost.outputStreamBufferedChunkLimit
        XCTAssertEqual(saturated.bufferedByteCeiling, 4 * 1_048_576)
        XCTAssertEqual(saturated.peakBufferedChunks, saturated.bufferedChunkLimit)
        XCTAssertLessThanOrEqual(
            saturated.peakBufferedChunks * saturated.chunkByteLimit,
            saturated.bufferedByteCeiling
        )
        XCTAssertEqual(saturated.droppedChunks, UInt64(expectedDroppedChunks))
        XCTAssertEqual(
            saturated.droppedBytes,
            UInt64(expectedDroppedChunks * AcpTerminalHost.outputStreamChunkByteLimit)
        )

        buffer.finish()
        var retainedSequences: [UInt64] = []
        for await retained in stream {
            XCTAssertEqual(retained.data.count, AcpTerminalHost.outputStreamChunkByteLimit)
            retainedSequences.append(retained.sequence)
        }
        XCTAssertEqual(retainedSequences.count, AcpTerminalHost.outputStreamBufferedChunkLimit)
        XCTAssertEqual(
            retainedSequences.first,
            UInt64(totalChunks - AcpTerminalHost.outputStreamBufferedChunkLimit)
        )
        XCTAssertEqual(retainedSequences.last, UInt64(totalChunks - 1))
    }

    func testCreateCapturesOutputAndExitCode() async throws {
        let host = AcpTerminalHost()
        let id = try await host.create(
            command: "/bin/sh",
            args: ["-c", "printf hello-acp; exit 3"],
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: nil
        )
        let status = await host.waitForExit(id)
        XCTAssertEqual(status?.exitCode, 3)
        XCTAssertNil(status?.signal)

        // EOF is a barrier: once wait_for_exit resolves, the snapshot must
        // already carry the complete output — no post-exit polling allowed.
        let snapshot = await host.output(id)
        XCTAssertTrue(snapshot?.output.contains("hello-acp") == true,
                      "output must be fully drained before exit resolves")
        XCTAssertEqual(snapshot?.truncated, false)
        XCTAssertEqual(snapshot?.exitStatus?.exitCode, 3)
        XCTAssertEqual(snapshot?.outputState, .complete)
    }

    func testGrandchildOutputAfterTheOldGracePeriodPrecedesWaitResolution() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-terminal-grandchild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateURL = directory.appendingPathComponent("write-now")
        let host = AcpTerminalHost(descendantPipeDrainTimeoutNanoseconds: 5_000_000_000)
        let id = try await host.create(
            command: "/bin/sh",
            args: [
                "-c",
                "(i=0; while [ ! -e \"$KAISOLA_WRITE_GATE\" ] && [ $i -lt 600 ]; do sleep 0.01; i=$((i + 1)); done; if [ -e \"$KAISOLA_WRITE_GATE\" ]; then printf grandchild-final; fi) & printf 'direct-child|'",
            ],
            env: ["KAISOLA_WRITE_GATE": gateURL.path],
            cwd: directory.path,
            outputByteLimit: nil
        )
        let receipt = TerminalExitReceipt()
        let waiter = Task {
            let status = await host.waitForExit(id)
            await receipt.record(status)
            return status
        }

        let drainDeadline = Date().addingTimeInterval(2)
        while Date() < drainDeadline {
            let snapshot = await host.output(id)
            if snapshot?.outputState == .drainingDescendants,
               snapshot?.output == "direct-child|" {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let draining = await host.output(id)
        XCTAssertEqual(draining?.outputState, .drainingDescendants)
        XCTAssertNil(draining?.exitStatus, "direct-child exit alone must not resolve the terminal")
        XCTAssertEqual(draining?.output, "direct-child|")

        // Cross the old synthetic-EOF deadline while the real grandchild still
        // owns the pipe. The waiter must remain unresolved until that child is
        // explicitly allowed to publish its final bytes and close the pipe.
        try await Task.sleep(nanoseconds: 2_200_000_000)
        let prematurelyResolved = await receipt.value()
        XCTAssertNil(prematurelyResolved)
        try Data().write(to: gateURL)

        let completionDeadline = Date().addingTimeInterval(3)
        while await receipt.value() == nil, Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let status = await waiter.value
        let completed = await host.output(id)
        XCTAssertEqual(status?.exitCode, 0)
        XCTAssertEqual(completed?.outputState, .complete)
        XCTAssertEqual(completed?.output, "direct-child|grandchild-final")
        XCTAssertFalse(completed?.truncated ?? true)

        // Resolution is the append barrier: no later poll can observe growth.
        try await Task.sleep(nanoseconds: 100_000_000)
        let stableOutput = await host.output(id)?.output
        XCTAssertEqual(stableOutput, completed?.output)
        await host.release(id)
    }

    func testLingeringDescendantTimeoutClosesThePipeAndReportsBoundedLoss() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-terminal-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateURL = directory.appendingPathComponent("write-after-timeout")
        let descendantDoneURL = directory.appendingPathComponent("descendant-done")
        let host = AcpTerminalHost(descendantPipeDrainTimeoutNanoseconds: 150_000_000)
        let clock = ContinuousClock()
        let started = clock.now
        let id = try await host.create(
            command: "/bin/sh",
            args: [
                "-c",
                "(trap '' PIPE; i=0; while [ ! -e \"$KAISOLA_WRITE_GATE\" ] && [ $i -lt 600 ]; do sleep 0.01; i=$((i + 1)); done; if [ -e \"$KAISOLA_WRITE_GATE\" ]; then printf should-not-append 2>/dev/null || :; fi; : > \"$KAISOLA_DESCENDANT_DONE\") & printf bounded-prefix",
            ],
            env: [
                "KAISOLA_WRITE_GATE": gateURL.path,
                "KAISOLA_DESCENDANT_DONE": descendantDoneURL.path,
            ],
            cwd: directory.path,
            outputByteLimit: nil
        )
        let status = await host.waitForExit(id)
        let elapsed = started.duration(to: clock.now)
        let timedOut = await host.output(id)

        XCTAssertEqual(status?.exitCode, 0)
        XCTAssertLessThan(elapsed, .seconds(2), "a descendant-held pipe must have a bounded wait")
        XCTAssertEqual(timedOut?.outputState, .descendantTimeout)
        XCTAssertEqual(timedOut?.output, "bounded-prefix")
        XCTAssertTrue(timedOut?.truncated == true, "timeout must visibly disclose possible lost output")

        try Data().write(to: gateURL)
        let descendantDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: descendantDoneURL.path),
              Date() < descendantDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: descendantDoneURL.path))
        let afterLateWrite = await host.output(id)
        XCTAssertEqual(afterLateWrite?.output, timedOut?.output)
        XCTAssertEqual(afterLateWrite?.outputState, .descendantTimeout)
        await host.release(id)
        let released = await host.output(id)
        XCTAssertNil(released)
    }

    func testReleaseClosesALingeringDescendantPipeImmediately() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-terminal-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gateURL = directory.appendingPathComponent("finish-descendant")
        let descendantDoneURL = directory.appendingPathComponent("descendant-done")
        let host = AcpTerminalHost(descendantPipeDrainTimeoutNanoseconds: 30_000_000_000)
        let id = try await host.create(
            command: "/bin/sh",
            args: [
                "-c",
                "(trap '' PIPE; i=0; while [ ! -e \"$KAISOLA_WRITE_GATE\" ] && [ $i -lt 600 ]; do sleep 0.01; i=$((i + 1)); done; printf released-late 2>/dev/null || :; : > \"$KAISOLA_DESCENDANT_DONE\") & printf released-prefix",
            ],
            env: [
                "KAISOLA_WRITE_GATE": gateURL.path,
                "KAISOLA_DESCENDANT_DONE": descendantDoneURL.path,
            ],
            cwd: directory.path,
            outputByteLimit: nil
        )

        let drainDeadline = Date().addingTimeInterval(2)
        while await host.output(id)?.outputState != .drainingDescendants,
              Date() < drainDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let draining = await host.output(id)
        XCTAssertEqual(draining?.outputState, .drainingDescendants)
        await host.release(id)

        let releaseDeadline = Date().addingTimeInterval(2)
        while await host.output(id) != nil, Date() < releaseDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let released = await host.output(id)
        XCTAssertNil(released)
        try Data().write(to: gateURL)
        let descendantDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: descendantDoneURL.path),
              Date() < descendantDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: descendantDoneURL.path))
    }

    func testAdapterProvidedLimitIsClampedToTheApplicationMaximum() async throws {
        let host = AcpTerminalHost()
        // A hostile outputByteLimit (Int.max) must not disable the bound; the
        // process still runs and output is captured under the clamp.
        let id = try await host.create(
            command: "/bin/sh",
            args: ["-c", "printf clamped"],
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: Int.max
        )
        _ = await host.waitForExit(id)
        let snapshot = await host.output(id)
        XCTAssertEqual(snapshot?.output, "clamped")
        XCTAssertEqual(snapshot?.truncated, false)
    }

    func testRapidExitAlwaysDrainsOutputBeforeWaitResolves() async throws {
        let host = AcpTerminalHost()
        for iteration in 0..<20 {
            let expected = "rapid-drain-\(iteration)-" + String(repeating: "x", count: 1_024)
            let id = try await host.create(
                command: "/usr/bin/printf",
                args: [expected],
                env: [:],
                cwd: FileManager.default.temporaryDirectory.path,
                outputByteLimit: nil
            )
            let status = await host.waitForExit(id)
            let snapshot = await host.output(id)
            XCTAssertEqual(status?.exitCode, 0)
            XCTAssertEqual(snapshot?.output, expected,
                           "iteration \(iteration) resolved before its final output was committed")
            await host.release(id)
        }
    }

    func testOutputByteLimitKeepsTailAndMarksTruncated() async throws {
        let host = AcpTerminalHost()
        let id = try await host.create(
            command: "/bin/sh",
            args: ["-c", "printf 'aaaaaaaaaabbbbbbbbbb'"],   // 20 bytes
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: 10
        )
        _ = await host.waitForExit(id)
        let snapshot = await host.output(id)
        XCTAssertEqual(snapshot?.truncated, true)
        // The retained tail is bounded and ends with the final bytes.
        XCTAssertTrue(snapshot?.output.hasSuffix("bbbbbbbbbb") == true)
        XCTAssertLessThanOrEqual(snapshot?.output.utf8.count ?? .max, 10)
    }

    func testKillTerminatesALongRunningProcess() async throws {
        let host = AcpTerminalHost()
        let id = try await host.create(
            command: "exec",
            args: ["/bin/sleep", "30"],
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: nil
        )
        await host.kill(id)
        let status = await host.waitForExit(id)
        // A shell wrapping the command may report the signal as an exit code
        // (128+SIGTERM) or propagate the signal itself — either proves death.
        XCTAssertNotNil(status)
        XCTAssertTrue(status?.signal != nil || (status?.exitCode ?? 0) != 0)
    }

    func testSIGKILLEscalationSuccessIsRecordedUntilActualExit() async throws {
        let sender = ScriptedSignalSender([
            .deliverAndReport(.sent),
        ])
        let host = AcpTerminalHost(
            sigkillEscalationDelayNanoseconds: 0,
            signalSender: { sender.send(pid: $0, signal: $1) }
        )
        let id = try await host.create(
            command: "exec",
            args: ["/bin/sleep", "30"],
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: nil
        )
        let createdPID = await host.processIdentifierForTesting(id)
        let pid = try XCTUnwrap(createdPID)
        defer { _ = Darwin.kill(pid, SIGKILL) }

        await host.forceKillForTesting(id)
        let statusAfterSend = await host.output(id)?.killStatus
        XCTAssertEqual(statusAfterSend?.state, .sigkillSent)
        XCTAssertEqual(statusAfterSend?.attempts, 1)
        XCTAssertNil(statusAfterSend?.errorNumber)
        XCTAssertEqual(sender.callCount, 1)

        let exit = await host.waitForExit(id)
        XCTAssertNotNil(exit)
        let completed = await host.output(id)
        XCTAssertEqual(completed?.killStatus, statusAfterSend)
        await host.release(id)
    }

    func testSIGKILLESRCHReconcilesWithoutSynthesizingExitOrRemovingEntry() async throws {
        let sender = ScriptedSignalSender([
            .report(.failed(errorNumber: ESRCH)),
        ])
        let host = AcpTerminalHost(
            sigkillEscalationDelayNanoseconds: 0,
            sigkillRetryDelayNanoseconds: 0,
            signalSender: { sender.send(pid: $0, signal: $1) }
        )
        let id = try await host.create(
            command: "exec",
            args: ["/bin/sleep", "30"],
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: nil
        )
        let createdPID = await host.processIdentifierForTesting(id)
        let pid = try XCTUnwrap(createdPID)
        defer { _ = Darwin.kill(pid, SIGKILL) }

        await host.forceKillForTesting(id)
        let reconciling = await host.output(id)
        XCTAssertNotNil(reconciling, "ESRCH is not proof of a delivered Process exit callback")
        XCTAssertNil(reconciling?.exitStatus)
        XCTAssertEqual(reconciling?.killStatus?.state, .reconcilingExit)
        XCTAssertEqual(reconciling?.killStatus?.errorNumber, ESRCH)
        XCTAssertFalse(reconciling?.killStatus?.processMayBeRunning ?? true)
        XCTAssertEqual(sender.callCount, 1)

        XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
        let exit = await host.waitForExit(id)
        XCTAssertNotNil(exit)
        let completed = await host.output(id)
        XCTAssertEqual(completed?.killStatus?.state, .reconcilingExit)
        await host.release(id)
    }

    func testSIGKILLEINTRRetriesOnceThenRecordsSuccessfulDelivery() async throws {
        let sender = ScriptedSignalSender([
            .report(.failed(errorNumber: EINTR)),
            .deliverAndReport(.sent),
        ])
        let host = AcpTerminalHost(
            sigkillEscalationDelayNanoseconds: 0,
            sigkillRetryDelayNanoseconds: 0,
            signalSender: { sender.send(pid: $0, signal: $1) }
        )
        let id = try await host.create(
            command: "exec",
            args: ["/bin/sleep", "30"],
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: nil
        )
        let createdPID = await host.processIdentifierForTesting(id)
        let pid = try XCTUnwrap(createdPID)
        defer { _ = Darwin.kill(pid, SIGKILL) }

        await host.forceKillForTesting(id)
        let delivered = await host.output(id)?.killStatus
        XCTAssertEqual(sender.callCount, 2)
        XCTAssertEqual(delivered?.state, .sigkillSent)
        XCTAssertEqual(delivered?.attempts, 2)
        XCTAssertFalse(delivered?.retryable ?? true)
        let exit = await host.waitForExit(id)
        XCTAssertNotNil(exit)
        await host.release(id)
    }

    func testSIGKILLPersistentEINTRStopsAtTheStrictAttemptBound() async throws {
        let sender = ScriptedSignalSender(Array(
            repeating: .report(.failed(errorNumber: EINTR)),
            count: AcpTerminalHost.maximumSIGKILLAttempts
        ))
        let host = AcpTerminalHost(
            sigkillEscalationDelayNanoseconds: 0,
            signalSender: { sender.send(pid: $0, signal: $1) }
        )
        let id = try await host.create(
            command: "exec",
            args: ["/bin/sleep", "30"],
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: nil
        )
        let createdPID = await host.processIdentifierForTesting(id)
        let pid = try XCTUnwrap(createdPID)
        defer { _ = Darwin.kill(pid, SIGKILL) }

        let clock = ContinuousClock()
        let started = clock.now
        await host.forceKillForTesting(id)
        let elapsed = started.duration(to: clock.now)
        let failure = await host.output(id)?.killStatus
        XCTAssertEqual(sender.callCount, AcpTerminalHost.maximumSIGKILLAttempts)
        XCTAssertLessThan(elapsed, .seconds(1), "EINTR retries must stay inside the strict retry window")
        XCTAssertEqual(failure?.state, .failed)
        XCTAssertEqual(failure?.attempts, AcpTerminalHost.maximumSIGKILLAttempts)
        XCTAssertEqual(failure?.errorNumber, EINTR)
        XCTAssertTrue(failure?.message.contains("Retry terminal/kill") == true)
        let retained = await host.output(id)
        XCTAssertNotNil(retained, "a failed escalation must retain the live entry")

        XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
        let exit = await host.waitForExit(id)
        XCTAssertNotNil(exit)
        await host.release(id)
    }

    func testSIGKILLEPERMReturnsActionableWaitFailureButRetainsEntryUntilEventualExit() async throws {
        let sender = ScriptedSignalSender([
            .report(.failed(errorNumber: EPERM)),
        ])
        let host = AcpTerminalHost(
            sigkillEscalationDelayNanoseconds: 0,
            sigkillRetryDelayNanoseconds: 0,
            signalSender: { sender.send(pid: $0, signal: $1) }
        )
        let id = try await host.create(
            command: "exec",
            args: ["/bin/sleep", "30"],
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: nil
        )
        let createdPID = await host.processIdentifierForTesting(id)
        let pid = try XCTUnwrap(createdPID)
        defer { _ = Darwin.kill(pid, SIGKILL) }

        await host.forceKillForTesting(id)
        let failedSnapshot = await host.output(id)
        let failure = try XCTUnwrap(failedSnapshot?.killStatus)
        XCTAssertEqual(failure.state, .failed)
        XCTAssertEqual(failure.errorNumber, EPERM)
        XCTAssertFalse(failure.retryable)
        XCTAssertTrue(failure.processMayBeRunning)
        XCTAssertTrue(failure.message.contains("Check permissions"))
        XCTAssertNil(failedSnapshot?.exitStatus)
        XCTAssertNotNil(failedSnapshot, "permanent failure must not discard a live terminal")
        let waitOutcome = await host.waitForExitOutcome(id)
        XCTAssertEqual(waitOutcome, .terminationFailed(failure))

        XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
        let exit = await host.waitForExit(id)
        XCTAssertNotNil(exit)
        let exitedSnapshot = await host.output(id)
        XCTAssertNotNil(exitedSnapshot, "actual exit remains inspectable until release")
        await host.release(id)
        let released = await host.output(id)
        XCTAssertNil(released)
    }

    func testReleaseInvalidatesTheTerminalID() async throws {
        let host = AcpTerminalHost()
        let id = try await host.create(
            command: "/bin/sh",
            args: ["-c", "exit 0"],
            env: [:],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: nil
        )
        _ = await host.waitForExit(id)
        await host.release(id)
        let snapshot = await host.output(id)
        XCTAssertNil(snapshot)
    }

    func testEnvOverlayReachesTheProcess() async throws {
        let host = AcpTerminalHost()
        let id = try await host.create(
            command: "/bin/sh",
            args: ["-c", "printf \"$KAISOLA_ACP_TEST\""],
            env: ["KAISOLA_ACP_TEST": "overlay-works"],
            cwd: FileManager.default.temporaryDirectory.path,
            outputByteLimit: nil
        )
        _ = await host.waitForExit(id)
        var snapshot = await host.output(id)
        let deadline = Date().addingTimeInterval(2)
        while snapshot?.output.contains("overlay-works") != true, Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
            snapshot = await host.output(id)
        }
        XCTAssertTrue(snapshot?.output.contains("overlay-works") == true)
    }

    @MainActor
    func testTerminalContentMissingOnFirstPollBecomesUnavailable() async {
        let model = AcpTerminalContentModel(pollIntervalNanoseconds: 0)

        await model.poll(terminalID: "missing-terminal") { _ in nil }

        XCTAssertEqual(model.status, .unavailable)
        XCTAssertEqual(model.output, "")
        XCTAssertFalse(model.outputIsTruncated)
    }

    @MainActor
    func testTerminalContentDisappearingAfterOutputPreservesOutputAndBecomesUnavailable() async {
        let snapshots = TerminalSnapshotSequence([
            AcpTerminalHost.Snapshot(output: "work in progress", truncated: true, exitStatus: nil),
            nil,
        ])
        let model = AcpTerminalContentModel(pollIntervalNanoseconds: 0)

        await model.poll(terminalID: "evicted-terminal") { _ in
            await snapshots.next()
        }

        XCTAssertEqual(model.status, .unavailable)
        XCTAssertEqual(model.output, "work in progress")
        XCTAssertTrue(model.outputIsTruncated)
    }

    @MainActor
    func testTerminalContentRetryFencesLateSnapshotFromOlderPoll() async {
        let olderPoll = SuspendedTerminalSnapshot()
        let model = AcpTerminalContentModel(pollIntervalNanoseconds: 0)
        let staleSnapshot = AcpTerminalHost.Snapshot(
            output: "stale output",
            truncated: false,
            exitStatus: .init(exitCode: 0, signal: nil)
        )

        let staleTask = Task { @MainActor in
            await model.poll(terminalID: "racing-terminal") { _ in
                await olderPoll.next()
            }
        }
        await olderPoll.waitUntilRequested()

        await model.poll(terminalID: "racing-terminal") { _ in nil }
        await olderPoll.resolve(with: staleSnapshot)
        await staleTask.value

        XCTAssertEqual(model.status, .unavailable)
        XCTAssertEqual(model.output, "")
    }
}

private actor TerminalSnapshotSequence {
    private var snapshots: [AcpTerminalHost.Snapshot?]

    init(_ snapshots: [AcpTerminalHost.Snapshot?]) {
        self.snapshots = snapshots
    }

    func next() -> AcpTerminalHost.Snapshot? {
        snapshots.isEmpty ? nil : snapshots.removeFirst()
    }
}

private actor SuspendedTerminalSnapshot {
    private var continuation: CheckedContinuation<AcpTerminalHost.Snapshot?, Never>?
    private var requested = false

    func next() async -> AcpTerminalHost.Snapshot? {
        requested = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        while !requested { await Task.yield() }
    }

    func resolve(with snapshot: AcpTerminalHost.Snapshot?) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

private actor TerminalExitReceipt {
    private var recorded: AcpTerminalHost.ExitStatus?

    func record(_ status: AcpTerminalHost.ExitStatus?) {
        recorded = status
    }

    func value() -> AcpTerminalHost.ExitStatus? {
        recorded
    }
}

private final class ScriptedSignalSender: @unchecked Sendable {
    enum Step {
        case report(AcpTerminalHost.SignalDeliveryResult)
        case deliverAndReport(AcpTerminalHost.SignalDeliveryResult)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var calls = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func send(pid: Int32, signal: Int32) -> AcpTerminalHost.SignalDeliveryResult {
        lock.withLock {
            calls += 1
            guard !steps.isEmpty else { return .failed(errorNumber: EIO) }
            switch steps.removeFirst() {
            case let .report(result):
                return result
            case let .deliverAndReport(result):
                _ = Darwin.kill(pid, signal)
                return result
            }
        }
    }
}
