import AppKit
import SwiftUI
import XCTest
@testable import Kaisola

/// Issue #48: the rail drew a "⋯" menu on every visible row, so the trailing
/// edge became a column of repeated dots. The button now belongs to the row the
/// user is on, and hiding it may not cost discoverability or move the name.
final class WorkspaceRowActionsTests: XCTestCase {
    // MARK: - When the button is drawn

    func testARestingRowDrawsNoOptionsButton() {
        XCTAssertFalse(
            WorkspaceRowActions.isRevealed(
                isHovering: false,
                isFocused: false,
                isSelected: false,
                alwaysVisible: false
            ),
            "every idle row drawing its ⋯ is the clutter this issue is about"
        )
    }

    func testHoverKeyboardFocusAndSelectionEachRevealTheButton() {
        XCTAssertTrue(WorkspaceRowActions.isRevealed(
            isHovering: true, isFocused: false, isSelected: false, alwaysVisible: false
        ))
        XCTAssertTrue(WorkspaceRowActions.isRevealed(
            isHovering: false, isFocused: true, isSelected: false, alwaysVisible: false
        ))
        XCTAssertTrue(WorkspaceRowActions.isRevealed(
            isHovering: false, isFocused: false, isSelected: true, alwaysVisible: false
        ))
    }

    /// The distinction the whole issue turns on: a resting row and a hovered
    /// row must not look the same. An implementation that revealed the button
    /// unconditionally would satisfy every "true" case above and still be the
    /// reported bug.
    func testRestingAndHoveredRowsDifferAtAll() {
        let resting = WorkspaceRowActions.isRevealed(
            isHovering: false, isFocused: false, isSelected: false, alwaysVisible: false
        )
        let hovered = WorkspaceRowActions.isRevealed(
            isHovering: true, isFocused: false, isSelected: false, alwaysVisible: false
        )
        XCTAssertNotEqual(resting, hovered)
    }

    // MARK: - The always-visible fallback

    func testPointerlessInputsPinTheButtonVisible() {
        XCTAssertTrue(WorkspaceRowActions.alwaysVisible(
            voiceOverEnabled: true, fullKeyboardAccessEnabled: false
        ))
        XCTAssertTrue(WorkspaceRowActions.alwaysVisible(
            voiceOverEnabled: false, fullKeyboardAccessEnabled: true
        ))
        XCTAssertFalse(WorkspaceRowActions.alwaysVisible(
            voiceOverEnabled: false, fullKeyboardAccessEnabled: false
        ))
        XCTAssertTrue(
            WorkspaceRowActions.isRevealed(
                isHovering: false, isFocused: false, isSelected: false, alwaysVisible: true
            ),
            "VoiceOver and Full Keyboard Access cannot hover a row into revealing its actions"
        )
    }

    // MARK: - The row may not move when the button appears

    private enum RowButton {
        /// The row with no options button at all — the width the reserved
        /// trailing clearance alone produces.
        case absent
        case concealed
        case revealed
    }

    /// A rail row shaped like `WorkspaceRailView.nodeRow`: reserved trailing
    /// clearance, indentation by depth, and the "⋯" as a trailing *overlay*
    /// whose visibility is opacity, not presence.
    @MainActor
    private func rowSize(
        name: String,
        depth: Int,
        button: RowButton,
        proposedWidth: CGFloat,
        typeSize: DynamicTypeSize = .large
    ) -> CGSize {
        let row = HStack(spacing: 5) {
            Spacer().frame(width: 10)
            Image(systemName: "doc.text").font(.caption)
            FadingFileName(text: name)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2.5)
        .padding(.leading, CGFloat(depth) * 14 + 10)
        .padding(.trailing, 30)
        .overlay(alignment: .trailing) {
            if button != .absent {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 18)
                    .fixedSize()
                    .opacity(button == .revealed ? 1 : 0)
                    .padding(.trailing, 6)
            }
        }
        .dynamicTypeSize(typeSize)

        let host = NSHostingController(rootView: row)
        let fitted = host.sizeThatFits(in: NSSize(width: proposedWidth, height: 400))
        return CGSize(width: fitted.width, height: fitted.height)
    }

    /// The conditions the issue asks for: the narrowest the responsive shell
    /// ever compresses Files to, a name far past that width, deep indentation,
    /// and an accessibility text size. `fitsPane` is false only where the
    /// rail's fixed indent already overflows on its own — see
    /// `testFixedIndentAloneSetsTheRowWidthFloor`.
    private static let layoutCases:
        [(name: String, depth: Int, width: CGFloat, type: DynamicTypeSize, fitsPane: Bool)] = [
            ("a.md", 0, 260, .large, true),
            (String(repeating: "deeply-nested-configuration-", count: 12) + ".json", 0, 150, .large, true),
            ("Deployment Notes For The Broker.md", 6, 164, .large, true),
            ("Deployment Notes For The Broker.md", 6, 150, .large, false),
            ("Deployment Notes For The Broker.md", 6, 260, .accessibility3, true),
            (String(repeating: "long-", count: 30) + "name.swift", 4, 164, .accessibility3, true),
        ]

    @MainActor
    func testRevealingTheButtonMovesNothing() {
        for testCase in Self.layoutCases {
            let label = "\(testCase.name) at depth \(testCase.depth) in \(testCase.width)pt"
            let absent = rowSize(
                name: testCase.name, depth: testCase.depth, button: .absent,
                proposedWidth: testCase.width, typeSize: testCase.type
            )
            let concealed = rowSize(
                name: testCase.name, depth: testCase.depth, button: .concealed,
                proposedWidth: testCase.width, typeSize: testCase.type
            )
            let revealed = rowSize(
                name: testCase.name, depth: testCase.depth, button: .revealed,
                proposedWidth: testCase.width, typeSize: testCase.type
            )

            XCTAssertEqual(
                concealed.width, revealed.width, accuracy: 0.01,
                "\(label) changed width when the ⋯ appeared"
            )
            XCTAssertEqual(
                concealed.height, revealed.height, accuracy: 0.01,
                "\(label) changed height when the ⋯ appeared"
            )
            // The clearance is reserved unconditionally, so the button costs
            // the row nothing in either state.
            XCTAssertEqual(
                absent.width, revealed.width, accuracy: 0.01,
                "\(label) grew because the ⋯ overlay took part in layout"
            )
            if testCase.fitsPane {
                XCTAssertLessThanOrEqual(
                    revealed.width, testCase.width + 0.5,
                    "\(label) overflowed its Files pane, which carries the ⋯ off-panel"
                )
            }
        }
    }

    /// Not this issue's bug, and recorded so it is not mistaken for one: the
    /// rail's fixed 14pt-per-level indent plus the reserved clearance already
    /// exceeds a 150pt pane by depth 6, with or without an options button.
    @MainActor
    func testFixedIndentAloneSetsTheRowWidthFloor() {
        let withButton = rowSize(name: "a.md", depth: 6, button: .concealed, proposedWidth: 150)
        let withoutButton = rowSize(name: "a.md", depth: 6, button: .absent, proposedWidth: 150)
        XCTAssertGreaterThan(withoutButton.width, 150.5)
        XCTAssertEqual(withButton.width, withoutButton.width, accuracy: 0.01)
    }

    /// Control: an options button that participates in layout instead of
    /// floating does widen the row, which is what the overlay avoids. If this
    /// stops overflowing, the assertions above no longer measure anything.
    @MainActor
    func testControlInlineButtonWouldWidenTheRow() {
        let inlineRow = HStack(spacing: 5) {
            Spacer().frame(width: 10)
            Image(systemName: "doc.text").font(.caption)
            FadingFileName(text: "a.md")
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)
                .fixedSize()
        }
        .padding(.leading, 6 * 14 + 10)
        let host = NSHostingController(rootView: inlineRow)
        let width = host.sizeThatFits(in: NSSize(width: 1, height: 28)).width
        XCTAssertGreaterThan(width, 6 * 14 + 10 + 18)
    }
}
