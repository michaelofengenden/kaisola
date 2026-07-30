import AppKit
import SwiftTerm
import XCTest
@testable import Kaisola

/// Scrolling up in a terminal used to stop after roughly a dozen screens.
///
/// Cause: SwiftTerm's `TerminalOptions.scrollback` defaults to **500** lines and
/// the native app never overrode it — one tenth of the 5000 the Electron
/// terminal it replaced used. Lines beyond the cap are pushed out of the
/// circular buffer permanently and are recoverable only from the broker spool.
@MainActor
final class TerminalScrollbackDepthTests: XCTestCase {
    private func makeView(scrollback: Int) -> ReadOnlyTerminalView {
        let view = ReadOnlyTerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        view.changeScrollback(NativePreviewSettings.clampedTerminalScrollback(scrollback))
        return view
    }

    func testSwiftTermDefaultIsTheShallowValueWeMustOverride() {
        // Documents the upstream default this fix exists to correct. If SwiftTerm
        // ever changes it, this test says so rather than silently going stale.
        let untouched = ReadOnlyTerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        XCTAssertEqual(untouched.getTerminal().options.scrollback, 500)
    }

    func testDefaultBalancesInteractiveDepthWithPagedHistory() {
        // Electron ran 5000. Twenty thousand keeps four times that interactive
        // depth while the broker-backed transcript owns lossless continuation.
        XCTAssertGreaterThanOrEqual(NativePreviewSettings.terminalScrollbackDefault, 5_000)
        XCTAssertEqual(NativePreviewSettings.terminalScrollbackDefault, 20_000)
    }

    func testChangeScrollbackTakesEffect() {
        let view = makeView(scrollback: 5_000)
        XCTAssertEqual(view.getTerminal().options.scrollback, 5_000)
    }

    func testScrollbackSurvivesResize() {
        // Resize is the most frequent event in this app — every pane geometry
        // change runs it. SwiftTerm's `resize` rewrites cols/rows only, so the
        // scrollback must persist.
        let view = makeView(scrollback: 5_000)
        view.getTerminal().resize(cols: 60, rows: 20)
        XCTAssertEqual(view.getTerminal().options.scrollback, 5_000)
    }

    func testScrollbackSurvivesReset() {
        // The reconciliation path calls `resetToInitialState()` on a stream
        // discontinuity; it rebuilds from `options.scrollback`, which
        // `changeScrollback` has already updated.
        let view = makeView(scrollback: 5_000)
        view.getTerminal().resetToInitialState()
        XCTAssertEqual(view.getTerminal().options.scrollback, 5_000)
    }

    func testDeepHistoryIsActuallyRetained() {
        let view = makeView(scrollback: 5_000)
        let terminal = view.getTerminal()
        terminal.resize(cols: 80, rows: 24)
        for line in 0..<3_000 {
            terminal.feed(text: "line-\(line)\r\n")
        }
        let text = String(decoding: terminal.getBufferAsData(kind: .active), as: UTF8.self)
        XCTAssertTrue(text.contains("line-0"), "Earliest line must still be reachable at 5000 scrollback")
        XCTAssertTrue(text.contains("line-2999"))
    }

    func testShallowScrollbackLosesTheSameHistory() {
        // The regression, stated directly: at the old default the same workload
        // drops its beginning on the floor.
        let view = makeView(scrollback: 500)
        let terminal = view.getTerminal()
        terminal.resize(cols: 80, rows: 24)
        for line in 0..<3_000 {
            terminal.feed(text: "line-\(line)\r\n")
        }
        let text = String(decoding: terminal.getBufferAsData(kind: .active), as: UTF8.self)
        XCTAssertFalse(text.contains("line-0"), "This is what the user was hitting")
    }

    func testClampingBoundsMemoryGrowth() {
        // ~24 bytes per cell means an unbounded setting is an unbounded heap.
        XCTAssertEqual(NativePreviewSettings.clampedTerminalScrollback(100), 500)
        XCTAssertEqual(NativePreviewSettings.clampedTerminalScrollback(10_000_000), 100_000)
        XCTAssertEqual(NativePreviewSettings.clampedTerminalScrollback(5_000), 5_000)
    }

    func testLegacyMaximumMigratesOnceWithoutOverwritingCustomDepth() {
        let suite = "terminal-scrollback-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(100_000, forKey: "terminalScrollbackLines")
        XCTAssertEqual(
            NativePreviewSettings(defaults: defaults, persistsChanges: false).terminalScrollbackLines,
            20_000
        )
        defaults.set(5_000, forKey: "terminalScrollbackLines")
        XCTAssertEqual(
            NativePreviewSettings(defaults: defaults, persistsChanges: false).terminalScrollbackLines,
            5_000
        )
    }

    func testExplicitMaximumSurvivesAfterCurrentPolicyMarker() {
        let suite = "terminal-scrollback-explicit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(100_000, forKey: "terminalScrollbackLines")
        defaults.set(
            NativePreviewSettings.terminalScrollbackPolicyVersion,
            forKey: "terminalScrollbackPolicyVersion"
        )
        XCTAssertEqual(
            NativePreviewSettings(defaults: defaults, persistsChanges: false).terminalScrollbackLines,
            100_000
        )
    }

    func testProductionMigrationPersistsTheNewTierAndMarker() {
        let suite = "terminal-scrollback-policy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(100_000, forKey: "terminalScrollbackLines")

        let settings = NativePreviewSettings(defaults: defaults)

        XCTAssertEqual(settings.terminalScrollbackLines, 20_000)
        XCTAssertEqual(defaults.integer(forKey: "terminalScrollbackLines"), 20_000)
        XCTAssertEqual(
            defaults.integer(forKey: "terminalScrollbackPolicyVersion"),
            NativePreviewSettings.terminalScrollbackPolicyVersion
        )
    }
}
