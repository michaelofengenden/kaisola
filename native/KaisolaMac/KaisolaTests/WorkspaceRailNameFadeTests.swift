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
}
