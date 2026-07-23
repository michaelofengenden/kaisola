import Foundation
import XCTest
@testable import KaisolaMacPreview

/// AcpTerminalHost against real child processes: create/output/wait/kill/release
/// semantics the ACP terminal bridge exposes to agents.
final class AcpTerminalHostTests: XCTestCase {

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
            command: "/bin/sleep",
            args: ["30"],
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
}
