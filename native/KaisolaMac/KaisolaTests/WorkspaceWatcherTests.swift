import Foundation
import XCTest
@testable import Kaisola

/// WorkspaceWatcher: the pure relevance filter (no I/O) plus a live FSEvents
/// round-trip on a throwaway directory. The live half is gated so a host where
/// FSEvents never delivers degrades to just the positive timeout, never a
/// spurious negative-path failure.
final class WorkspaceWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-watch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules/dep"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Pure: relevance matrix

    func testIsRelevantIgnoresBuildAndVendorComponents() {
        // Any ignored component anywhere in the path → not relevant.
        XCTAssertFalse(WorkspaceWatcher.isRelevant(path: "/proj/node_modules/left-pad/index.js"))
        XCTAssertFalse(WorkspaceWatcher.isRelevant(path: "/proj/.git/HEAD"))
        XCTAssertFalse(WorkspaceWatcher.isRelevant(path: "/proj/build/app.o"))
        XCTAssertFalse(WorkspaceWatcher.isRelevant(path: "/proj/.build/debug/thing"))
        XCTAssertFalse(WorkspaceWatcher.isRelevant(path: "/proj/dist/bundle.js"))
        XCTAssertFalse(WorkspaceWatcher.isRelevant(path: "/proj/DerivedData/y"))
        XCTAssertFalse(WorkspaceWatcher.isRelevant(path: "/proj/sub/node_modules/pkg/a.js"))
    }

    func testIsRelevantAllowsRealSourcePaths() {
        XCTAssertTrue(WorkspaceWatcher.isRelevant(path: "/proj/src/main.swift"))
        XCTAssertTrue(WorkspaceWatcher.isRelevant(path: "/proj/README.md"))
        XCTAssertTrue(WorkspaceWatcher.isRelevant(path: "/proj/Sources/App/View.swift"))
        // Component-wise, not substring: "rebuild" must not be caught by "build".
        XCTAssertTrue(WorkspaceWatcher.isRelevant(path: "/proj/rebuild/tool.swift"))
    }

    // MARK: - Live: FSEvents round-trip

    @MainActor
    func testLiveWriteBumpsTokenAndIgnoresNodeModules() throws {
        let watcher = WorkspaceWatcher(root: root)
        defer { watcher.stop() }

        // Positive path: a relevant write must bump changeToken within ~3s. The
        // run loop is *pumped* (not slept) so both the FSEvents callback and the
        // MainActor debounce Task get serviced. Expect ~1.2s in practice
        // (0.5s FSEvents latency + 0.7s debounce).
        try "hello".write(
            to: root.appendingPathComponent("src/live.swift"),
            atomically: true, encoding: .utf8
        )
        let bumped = pump(until: { watcher.changeToken > 0 }, timeout: 3.0)
        XCTAssertTrue(bumped, "a relevant write should bump changeToken within 3s")

        // Negative path (deliberately lenient): a write under node_modules must
        // not bump. This is only meaningful if the positive machinery actually
        // fired on this host — if FSEvents delivered nothing above, the stream is
        // inert here too and the check would be vacuous (and, on a flaky host,
        // could false-fail on unrelated noise), so we skip it rather than assert.
        guard bumped else { return }
        let baseline = watcher.changeToken
        try "junk".write(
            to: root.appendingPathComponent("node_modules/dep/late.js"),
            atomically: true, encoding: .utf8
        )
        _ = pump(until: { watcher.changeToken > baseline }, timeout: 1.5)
        XCTAssertEqual(watcher.changeToken, baseline,
                       "writes under node_modules must not bump the tree")
    }

    /// Pump the main run loop until `condition` holds or `timeout` elapses,
    /// returning whether it held. Uses `RunLoop.run` (not `Thread.sleep`) so
    /// FSEvents callbacks and queued MainActor work are actually serviced while
    /// waiting — a busy sleep would starve them and the token would never move.
    @MainActor
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
