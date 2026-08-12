import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Kaisola

/// The native-visual workflow used to check dimensions, file size, visible
/// alpha and luminance range. All four pass on a screenshot whose header is
/// printed over the window buttons, which is exactly what shipped. These tests
/// pin the structural gate that catches it, using the same reviewed baseline
/// CI runs against.
final class NativeVisualLayoutAuditTests: XCTestCase {
    private static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var fixturesURL: URL {
        repositoryRoot.appendingPathComponent("tests/fixtures/native-visual", isDirectory: true)
    }

    private static var expectationsURL: URL {
        repositoryRoot.appendingPathComponent(
            "native/KaisolaMac/VisualBaselines/layout-expectations.json",
            isDirectory: false
        )
    }

    private static var reviewURL: URL {
        repositoryRoot.appendingPathComponent(
            "native/KaisolaMac/VisualBaselines/layout-review.json",
            isDirectory: false
        )
    }

    private func loadExpectations() throws -> NativeVisualLayoutExpectations {
        try NativeVisualLayoutGate.loadExpectations(at: Self.expectationsURL).0
    }

    private func loadFixture(_ name: String) throws -> NativeVisualLayoutSnapshot {
        try NativeVisualLayoutGate.loadSnapshot(
            at: Self.fixturesURL.appendingPathComponent(name, isDirectory: false)
        )
    }

    private func failingRules(
        _ snapshot: NativeVisualLayoutSnapshot,
        _ expectations: NativeVisualLayoutExpectations
    ) -> Set<String> {
        Set(
            NativeVisualLayoutAudit.violations(in: snapshot, expectations: expectations)
                .filter { $0.severity == .fail }
                .map(\.rule)
        )
    }

    // MARK: - The reproduced regression

    func testGateFailsOnTheShippedSettingsTrafficLightOverlap() throws {
        let expectations = try loadExpectations()
        let snapshot = try loadFixture("settings-traffic-light-overlap.layout.json")
        let rules = failingRules(snapshot, expectations)
        XCTAssertTrue(
            rules.contains(NativeVisualLayoutRule.controlOverlap),
            "the sidebar mark overlaps the window buttons and must fail the gate: \(rules)"
        )
        XCTAssertTrue(
            rules.contains(NativeVisualLayoutRule.controlZoneInk),
            "app-drawn ink on the window buttons must fail the gate: \(rules)"
        )
    }

    func testGatePassesOnceTheTitlebarStripIsReserved() throws {
        let expectations = try loadExpectations()
        let snapshot = try loadFixture("settings-reserved-titlebar.layout.json")
        XCTAssertEqual(
            failingRules(snapshot, expectations),
            [],
            "a gate that fails a correct layout would be ignored within a week"
        )
    }

    func testGateFailsOnADeliberatelyTruncatedSheetLabel() throws {
        let expectations = try loadExpectations()
        let snapshot = try loadFixture("rename-sheet-truncated-label.layout.json")
        XCTAssertTrue(
            failingRules(snapshot, expectations).contains(NativeVisualLayoutRule.truncatedText)
        )
    }

    func testGateFailsWhenTheContentLayerDrewNothing() throws {
        let expectations = try loadExpectations()
        let snapshot = try loadFixture("settings-blank-content-layer.layout.json")
        XCTAssertTrue(
            failingRules(snapshot, expectations).contains(NativeVisualLayoutRule.contentInkFloor),
            "an empty content layer means the ink rules are measuring nothing"
        )
    }

    /// The same self-test CI runs, against the same fixtures and baseline.
    func testCheckedInSelfTestManifestPasses() throws {
        var lines: [String] = []
        let passed = try NativeVisualLayoutGate.selfTest(
            fixtures: Self.fixturesURL,
            expectationsURL: Self.expectationsURL,
            emit: { lines.append($0) }
        )
        XCTAssertTrue(passed, lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0.contains("=FAIL") }, [])
    }

    // MARK: - Rules

    func testClippedAndOffscreenElementsAreReported() {
        var expectations = try! loadExpectations()
        expectations.severities[NativeVisualLayoutRule.clipped] = .fail
        expectations.severities[NativeVisualLayoutRule.offscreen] = .fail
        let snapshot = snapshot(elements: [
            element(id: "clipped", frame: .init(x: 0.9, y: 0.4, width: 0.3, height: 0.1)),
            element(id: "offscreen", frame: .init(x: 1.4, y: 0.4, width: 0.2, height: 0.1)),
            element(id: "fine", frame: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.1)),
        ])
        let violations = NativeVisualLayoutAudit.violations(in: snapshot, expectations: expectations)
        XCTAssertEqual(
            violations.filter { $0.rule == NativeVisualLayoutRule.clipped }.count,
            1
        )
        XCTAssertEqual(
            violations.filter { $0.rule == NativeVisualLayoutRule.offscreen }.count,
            1
        )
    }

    func testOverlappingInteractiveControlsAreReported() {
        var expectations = try! loadExpectations()
        expectations.severities[NativeVisualLayoutRule.elementCollision] = .fail
        let snapshot = snapshot(elements: [
            element(id: "save", frame: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.1), interactive: true),
            element(id: "cancel", frame: .init(x: 0.45, y: 0.42, width: 0.2, height: 0.1), interactive: true),
        ])
        XCTAssertTrue(
            failingRules(snapshot, expectations).contains(NativeVisualLayoutRule.elementCollision)
        )
    }

    func testMissingCriticalLabelAndActionAreReported() {
        var expectations = try! loadExpectations()
        expectations.severities[NativeVisualLayoutRule.missingLabel] = .fail
        expectations.severities[NativeVisualLayoutRule.missingAction] = .fail
        expectations.surfaces["settings"] = NativeVisualLayoutExpectations.Surface(
            requiredLabels: ["Settings"],
            requiredActions: ["Done"]
        )
        let present = snapshot(elements: [
            element(id: "title", frame: .init(x: 0.1, y: 0.3, width: 0.2, height: 0.05), label: "Settings"),
            element(id: "done", frame: .init(x: 0.7, y: 0.3, width: 0.2, height: 0.05), label: "Done", interactive: true),
        ])
        XCTAssertEqual(failingRules(present, expectations), [])

        let missing = snapshot(elements: [
            element(id: "title", frame: .init(x: 0.1, y: 0.3, width: 0.2, height: 0.05), label: "Settings"),
        ])
        XCTAssertEqual(failingRules(missing, expectations), [NativeVisualLayoutRule.missingAction])
    }

    /// A full-bleed container legitimately sits under the buttons in a
    /// `fullSizeContentView` window; only leaves are judged.
    func testFullBleedContainerIsNotAnOverlap() throws {
        let expectations = try loadExpectations()
        var snapshot = try loadFixture("settings-reserved-titlebar.layout.json")
        snapshot.elements.append(element(
            id: "backdrop",
            frame: .init(x: 0, y: 0, width: 1, height: 1),
            leaf: true
        ))
        XCTAssertEqual(failingRules(snapshot, expectations), [])
    }

    func testControlOverlapIgnoresAChildClippedOutsideItsScrollViewport() throws {
        let expectations = try loadExpectations()
        let snapshot = snapshot(elements: [
            element(
                id: "0/scroll",
                frame: .init(x: 0.4, y: 0.02, width: 0.5, height: 0.2),
                role: "AXScrollArea",
                leaf: false
            ),
            element(
                id: "0/scroll/tab",
                frame: .init(x: -0.1, y: 0.01, width: 0.2, height: 0.04),
                role: "AXUnknown"
            ),
        ])
        XCTAssertFalse(
            failingRules(snapshot, expectations).contains(NativeVisualLayoutRule.controlOverlap),
            "offscreen scroll content is not visibly drawn over the window buttons"
        )
    }

    func testControlOverlapStillFailsForAVisibleChildInsideItsScrollViewport() throws {
        let expectations = try loadExpectations()
        let snapshot = snapshot(elements: [
            element(
                id: "0/scroll",
                frame: .init(x: 0.04, y: 0, width: 0.5, height: 0.2),
                role: "AXScrollArea",
                leaf: false
            ),
            element(
                id: "0/scroll/tab",
                frame: .init(x: 0, y: 0.01, width: 0.1, height: 0.04),
                role: "AXUnknown"
            ),
        ])
        XCTAssertTrue(
            failingRules(snapshot, expectations).contains(NativeVisualLayoutRule.controlOverlap),
            "viewport clipping must not hide a genuinely visible titlebar collision"
        )
    }

    func testMasksDropNondeterministicMaterialFromInkRules() {
        let grid = NativeVisualLayoutSnapshot.InkGrid(
            columns: 2,
            rows: 1,
            cells: [
                .init(coverage: 0, minimumLuminance: 0, maximumLuminance: 0, samples: 16),
                .init(coverage: 1, minimumLuminance: 0.1, maximumLuminance: 0.9, samples: 16),
            ]
        )
        let full = grid.sample(
            in: .init(x: 0, y: 0, width: 1, height: 1),
            masks: []
        )
        XCTAssertEqual(full.coverage, 0.5, accuracy: 0.001)
        let masked = grid.sample(
            in: .init(x: 0, y: 0, width: 1, height: 1),
            masks: [.init(x: 0, y: 0, width: 0.4, height: 1)]
        )
        XCTAssertEqual(masked.coverage, 1, accuracy: 0.001)
        XCTAssertEqual(masked.samples, 16)
    }

    // MARK: - Reviewed baseline

    func testCheckedInReviewRecordMatchesTheCheckedInBaseline() throws {
        let (_, data) = try NativeVisualLayoutGate.loadExpectations(at: Self.expectationsURL)
        XCTAssertNoThrow(
            try NativeVisualLayoutGate.verifyReview(
                expectationsData: data,
                reviewURL: Self.reviewURL
            ),
            "the reviewed digest no longer describes layout-expectations.json"
        )
    }

    func testBaselineChangeWithoutAReviewIsRejected() throws {
        let review = try JSONDecoder().decode(
            NativeVisualBaselineReview.self,
            from: try Data(contentsOf: Self.reviewURL)
        )
        let edited = Data("{\"schemaVersion\": 1}".utf8)
        XCTAssertNotNil(
            review.failureReason(forExpectations: edited),
            "an unreviewed threshold edit must not be able to relax the gate"
        )
    }

    func testReviewWithoutBeforeAndAfterArtifactsIsRejected() throws {
        let data = try Data(contentsOf: Self.expectationsURL)
        var review = try JSONDecoder().decode(
            NativeVisualBaselineReview.self,
            from: try Data(contentsOf: Self.reviewURL)
        )
        XCTAssertNil(review.failureReason(forExpectations: data))
        review.beforeArtifact = "  "
        XCTAssertEqual(
            review.failureReason(forExpectations: data),
            "review-field-empty=beforeArtifact"
        )
    }

    // MARK: - Gate plumbing

    func testEveryCaptureNeedsALayoutSnapshotBesideIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-layout-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = try loadFixture("settings-reserved-titlebar.layout.json")
        try NativeVisualLayoutProbe.write(
            snapshot,
            to: directory.appendingPathComponent("settings.layout.json", isDirectory: false)
        )
        try Data("png".utf8).write(
            to: directory.appendingPathComponent("settings.png", isDirectory: false)
        )
        try Data("png".utf8).write(
            to: directory.appendingPathComponent("usage.png", isDirectory: false)
        )

        let report = try NativeVisualLayoutGate.run(
            directory: directory,
            expectationsURL: Self.expectationsURL,
            reviewURL: Self.reviewURL,
            emit: { _ in }
        )
        XCTAssertEqual(report.failures.map(\.surface), ["usage"])
    }

    func testCommandLineParsesBothGateModes() {
        let gate = NativeVisualLayoutCommand.parse(arguments: [
            "--visual-layout-gate", "/tmp/shots",
            "--expectations", "/tmp/expect.json",
            "--review", "/tmp/review.json",
        ])
        XCTAssertEqual(gate?.mode, .gate(directory: "/tmp/shots"))
        XCTAssertEqual(gate?.expectations, "/tmp/expect.json")
        XCTAssertEqual(gate?.review, "/tmp/review.json")

        let selfTest = NativeVisualLayoutCommand.parse(arguments: [
            "--visual-layout-self-test", "/tmp/fixtures",
        ])
        XCTAssertEqual(selfTest?.mode, .selfTest(fixtures: "/tmp/fixtures"))
        XCTAssertNil(NativeVisualLayoutCommand.parse(arguments: ["-ApplePersistenceIgnoreState", "YES"]))
        XCTAssertFalse(NativeVisualLayoutCommand.requestsGate(arguments: ["--launch-probe"]))
    }

    // MARK: - Probe

    /// The live shape of the reproduced bug: host the real standalone Settings
    /// view in a real `fullSizeContentView` window, probe it, and judge it with
    /// the shipped baseline. Before the sidebar reserved the titlebar strip,
    /// the accent mark and the "Settings" headline landed inside the window
    /// buttons' zone and this failed.
    @MainActor
    func testStandaloneSettingsWindowKeepsItsHeaderOffTheWindowControls() throws {
        _ = NSApplication.shared
        let suite = "kaisola-visual-layout-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NativePreviewSettings(defaults: defaults, persistsChanges: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 810, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let hosting = NSHostingView(
            rootView: SettingsView(settings: settings)
                .environmentObject(AuthModel.previewSignedIn())
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let snapshot = try XCTUnwrap(NativeVisualLayoutProbe.snapshot(
            of: window,
            surface: "settings",
            appearance: "light"
        ))
        // A probe that measured nothing would pass every rule, so say out loud
        // that it saw the window buttons and the content layer.
        let zone = try XCTUnwrap(snapshot.controlZone, "no window-control zone measured")
        XCTAssertGreaterThan(zone.area, 0)
        let inked = snapshot.contentInk?.cells.filter { $0.coverage > 0 }.count ?? 0
        XCTAssertGreaterThan(inked, 0, "the content layer rendered nothing to measure")

        let violations = NativeVisualLayoutAudit.violations(
            in: snapshot,
            expectations: try loadExpectations()
        )
        XCTAssertEqual(
            violations.filter { $0.severity == .fail }.map(\.reportLine),
            [],
            "Settings drew over its own window controls"
        )
    }

    func testProbeNormalizesContentGeometryToATopLeftOrigin() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        let topLeft = NativeVisualLayoutProbe.normalize(
            CGRect(x: 0, y: 380, width: 80, height: 20),
            in: bounds
        )
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.0001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.0001)
        XCTAssertEqual(topLeft.width, 0.1, accuracy: 0.0001)
        XCTAssertEqual(topLeft.height, 0.05, accuracy: 0.0001)

        // SwiftUI hosts the settings window in a flipped view. Reading it as
        // bottom-left put the window buttons at the foot of the window.
        let flipped = NativeVisualLayoutProbe.normalize(
            CGRect(x: 0, y: 0, width: 80, height: 20),
            in: bounds,
            flipped: true
        )
        XCTAssertEqual(flipped.y, 0, accuracy: 0.0001)
        XCTAssertEqual(
            NativeVisualLayoutProbe.normalize(
                CGRect(x: 0, y: 0, width: 80, height: 20),
                in: bounds,
                flipped: false
            ).y,
            0.95,
            accuracy: 0.0001
        )
    }

    // MARK: - Helpers

    private func snapshot(
        surface: String = "settings",
        elements: [NativeVisualLayoutSnapshot.Element]
    ) -> NativeVisualLayoutSnapshot {
        NativeVisualLayoutSnapshot(
            surface: surface,
            contentWidth: 810,
            contentHeight: 540,
            windowControls: [
                .init(
                    name: "close",
                    frame: .init(x: 0.011, y: 0.014, width: 0.017, height: 0.026),
                    isHidden: false
                ),
            ],
            controlZone: .init(x: 0.0037, y: 0.0037, width: 0.0815, height: 0.0482),
            controlZoneInk: .init(
                coverage: 0.9,
                minimumLuminance: 0.79,
                maximumLuminance: 0.86,
                samples: 768
            ),
            contentInk: .init(
                columns: 1,
                rows: 1,
                cells: [.init(
                    coverage: 0.9,
                    minimumLuminance: 0.1,
                    maximumLuminance: 0.9,
                    samples: 16
                )]
            ),
            inventorySource: "accessibility",
            elements: elements
        )
    }

    private func element(
        id: String,
        frame: NativeVisualLayoutSnapshot.Rect,
        label: String = "",
        role: String = "AXStaticText",
        leaf: Bool = true,
        interactive: Bool = false
    ) -> NativeVisualLayoutSnapshot.Element {
        NativeVisualLayoutSnapshot.Element(
            id: id,
            role: interactive ? "AXButton" : role,
            label: label,
            frame: frame,
            isLeaf: leaf,
            isInteractive: interactive,
            pointHeight: frame.height * 540
        )
    }
}
