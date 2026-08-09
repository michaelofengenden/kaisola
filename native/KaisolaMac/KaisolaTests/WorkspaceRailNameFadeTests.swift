import AppKit
import SwiftUI
import XCTest
@testable import Kaisola

/// The rail regression from the 2026-08-06 design doc: a `fixedSize` file name
/// reported its full ideal width as its minimum, the row grew past the rail's
/// clip, and the floating "⋯" button anchored to the row's trailing edge was
/// carried off-panel. `FadingFileName` must stay compressible — a row's width
/// may never follow the name's length.
final class WorkspaceRailNameFadeTests: XCTestCase {
    private static let longName =
        String(repeating: "pathologically-long-file-name-", count: 40) + ".md"

    /// A tree-row-shaped container proposed a rail-like width. Returns the
    /// width the row actually reports back, which is what the "⋯" overlay
    /// anchors to.
    @MainActor
    private func reportedRowWidth(name: some View) -> CGFloat {
        let row = HStack(spacing: 5) {
            Spacer().frame(width: 10)
            Image(systemName: "doc.text").font(.caption)
            AnyView(name)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 30)
        let host = NSHostingController(rootView: row)
        return host.sizeThatFits(in: NSSize(width: 160, height: 28)).width
    }

    @MainActor
    func testLongNameRowStaysAtTheProposedRailWidth() {
        let width = reportedRowWidth(name: FadingFileName(text: Self.longName))
        XCTAssertLessThanOrEqual(
            width, 160.5,
            "a long name widened the row, which carries the ⋯ button off-panel"
        )
    }

    @MainActor
    func testShortNameRowStaysAtTheProposedRailWidth() {
        let width = reportedRowWidth(name: FadingFileName(text: "a.md"))
        XCTAssertLessThanOrEqual(width, 160.5)
    }

    /// Control: the exact pattern that caused the bug. If this ever stops
    /// overflowing, SwiftUI's sizing semantics changed and the assertions
    /// above are no longer measuring the failure they were written against.
    @MainActor
    func testControlFixedSizeNamePatternDoesOverflowTheRow() {
        let old = Text(Self.longName)
            .font(.callout)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        XCTAssertGreaterThan(reportedRowWidth(name: old), 200)
    }

    @MainActor
    func testAgentsFileCreationWritesTheExactTemplateWithoutReplacingACollision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaisola-agents-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = WorkspaceAgentsFileCreation.attempt(
            in: root,
            template: WorkspaceRailView.agentsTemplate
        )
        let target = try XCTUnwrap(first.successValue)
        XCTAssertEqual(target, root.appendingPathComponent("AGENTS.md"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), WorkspaceRailView.agentsTemplate)

        try "user-owned instructions".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            WorkspaceAgentsFileCreation.attempt(
                in: root,
                template: WorkspaceRailView.agentsTemplate
            ).failureValue,
            .destinationExists
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "user-owned instructions")
    }

    func testAgentsFileCreationClassifiesActionableFilesystemFailures() {
        let root = URL(fileURLWithPath: "/benign/project", isDirectory: true)

        XCTAssertEqual(
            WorkspaceAgentsFileCreation.attempt(
                in: root,
                template: "template",
                writer: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            ).failureValue,
            .permissionDenied
        )
        XCTAssertEqual(
            WorkspaceAgentsFileCreation.attempt(
                in: root,
                template: "template",
                writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
            ).failureValue,
            .diskFull
        )
        XCTAssertEqual(
            WorkspaceAgentsFileCreation.attempt(
                in: root,
                template: "template",
                writer: { _, _ in throw CocoaError(.fileWriteUnknown) }
            ).failureValue,
            .other
        )
        XCTAssertEqual(
            WorkspaceAgentsFileCreation.Failure.destinationExists.message,
            "AGENTS.md already exists. Rename or remove it, then try again."
        )
        XCTAssertEqual(
            WorkspaceAgentsFileCreation.Failure.permissionDenied.message,
            "Kaisola doesn't have permission to create AGENTS.md in this project."
        )
        XCTAssertEqual(
            WorkspaceAgentsFileCreation.Failure.diskFull.message,
            "There isn't enough disk space to create AGENTS.md."
        )
    }

    func testAgentsFileCreationCanRetryAndOnlyReturnsATargetAfterSuccess() {
        let root = URL(fileURLWithPath: "/benign/project", isDirectory: true)
        var attempts = 0
        let writer: WorkspaceAgentsFileCreation.Writer = { _, _ in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteNoPermission) }
        }

        let failed = WorkspaceAgentsFileCreation.attempt(
            in: root,
            template: "template",
            writer: writer
        )
        XCTAssertNil(failed.successValue)
        XCTAssertEqual(failed.failureValue, .permissionDenied)

        let retried = WorkspaceAgentsFileCreation.attempt(
            in: root,
            template: "template",
            writer: writer
        )
        XCTAssertEqual(retried.successValue, root.appendingPathComponent("AGENTS.md"))
        XCTAssertNil(retried.failureValue)
        XCTAssertEqual(attempts, 2)
    }
}

private extension Result {
    var successValue: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }

    var failureValue: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
