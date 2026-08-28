import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One adjacent project-tab move shared by keyboard/assistive actions and the
/// pointer drag persistence callback supplied by the parent view.
enum ProjectTabReorder {
    enum Direction: CaseIterable, Equatable, Sendable {
        case left
        case right
    }

    static func availableDirections(index: Int, count: Int) -> [Direction] {
        guard count > 1, (0..<count).contains(index) else { return [] }
        return Direction.allCases.filter { direction in
            switch direction {
            case .left: index > 0
            case .right: index < count - 1
            }
        }
    }

    static func positionDescription(index: Int, count: Int) -> String? {
        guard count > 0, (0..<count).contains(index) else { return nil }
        return "Position \(index + 1) of \(count)"
    }

    /// Returns false at a boundary without invoking either callback. A valid
    /// move uses the same absolute-index closure as pointer drag, then emits
    /// exactly one position announcement for the completed user action.
    @discardableResult
    static func perform(
        projectID: String,
        projectName: String,
        index: Int,
        count: Int,
        direction: Direction,
        reorder: (_ id: String, _ toIndex: Int) -> Void,
        announce: (_ message: String) -> Void
    ) -> Bool {
        guard availableDirections(index: index, count: count).contains(direction) else {
            return false
        }
        let destinationIndex = direction == .left ? index - 1 : index + 1
        reorder(projectID, destinationIndex)
        announce("Moved \(projectName) to position \(destinationIndex + 1) of \(count).")
        return true
    }
}

// The legacy top-bar shell's `ProjectTabStripView` and its drop delegate
// lived here until the 2026-08-28 graduation deleted that shell: the merged
// bar's compact `TopBarProjectSwitcher` replaced the strip. `ProjectTabReorder`
// above survives as the pure adjacent-move contract (ProjectReorderTests) and
// the natural seed if tab-drag reordering returns to the switcher.
