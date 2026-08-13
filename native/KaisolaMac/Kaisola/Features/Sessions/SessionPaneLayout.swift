import Foundation

/// Persistable, project-scoped placement for every visible workspace session.
///
/// A column is a horizontal split. Session ids inside a column are vertical
/// splits. This is deliberately the same small model as Electron's dock grid,
/// but weights live beside the ids so a relaunch restores the user's actual
/// working geometry instead of merely reopening the same cards.
struct SessionPaneLayout: Codable, Equatable, Sendable {
    enum Edge: String, Codable, Sendable {
        case left
        case right
        case top
        case bottom
    }

    struct Column: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var sessionIDs: [String]
        var weight: Double
        var rowWeights: [Double]

        init(
            id: String = UUID().uuidString.lowercased(),
            sessionIDs: [String],
            weight: Double = 1,
            rowWeights: [Double] = []
        ) {
            self.id = id
            self.sessionIDs = sessionIDs
            self.weight = weight
            self.rowWeights = rowWeights
            reconcileWeights()
        }

        mutating func reconcileWeights() {
            weight = Self.validWeight(weight)
            guard rowWeights.count == sessionIDs.count else {
                rowWeights = Array(repeating: 1, count: sessionIDs.count)
                return
            }
            rowWeights = rowWeights.map(Self.validWeight)
        }

        private static func validWeight(_ value: Double) -> Double {
            value.isFinite && value > 0 ? value : 1
        }
    }

    /// Eight live cards is already a dense 2×4 workspace. Bounding the model
    /// keeps accidental repeated drops and hand-edited snapshots inexpensive.
    static let maximumPaneCount = 8

    var columns: [Column]

    init(columns: [Column] = []) {
        self.columns = columns
        normalize()
    }

    init(sessionID: String) {
        columns = [Column(sessionIDs: [sessionID])]
        normalize()
    }

    var sessionIDs: [String] { columns.flatMap(\.sessionIDs) }
    var isEmpty: Bool { columns.isEmpty }

    /// Whether a focus ring drawn on `sessionID` would carry any information.
    ///
    /// A focus ring means "this one, not the others". With a single pane there
    /// are no others, so the ring stops distinguishing anything and becomes a
    /// saturated accent rectangle drawn around the entire workspace — which is
    /// how it read: a blue border framing the terminal at all times, for no
    /// reason a reader could recover. The sidebar already marks which session
    /// you are in, and marks it in the same accent, so the ring was not even
    /// the only thing saying it.
    ///
    /// With two or more panes the ring earns its place again, because then it
    /// is answering a question the window genuinely poses.
    /// `maximizedID` matters because a maximized pane is rendered *alone* — see
    /// the grid, which draws only that card — so counting the layout's panes
    /// would say "you have siblings" about a window that is showing exactly one.
    /// That is the same lone accent rectangle by another route.
    func marksFocus(_ sessionID: String, focusedID: String?, maximizedID: String? = nil) -> Bool {
        if let maximizedID, contains(maximizedID) { return false }
        guard sessionIDs.count > 1 else { return false }
        return focusedID == sessionID
    }

    func contains(_ sessionID: String) -> Bool {
        columns.contains { $0.sessionIDs.contains(sessionID) }
    }

    /// Convert stable window-coordinate pointer movement into the persisted
    /// relative weights used by the pane model. Invalid geometry becomes a
    /// no-op instead of injecting NaN/Infinity into a restored workspace.
    static func weightDelta(
        pointDelta: Double,
        availableExtent: Double,
        totalWeight: Double
    ) -> Double {
        guard pointDelta.isFinite,
              availableExtent.isFinite,
              availableExtent > 0,
              totalWeight.isFinite,
              totalWeight > 0 else { return 0 }
        return pointDelta / availableExtent * totalWeight
    }

    static func minimumWeight(
        minimumExtent: Double,
        availableExtent: Double,
        totalWeight: Double
    ) -> Double {
        guard minimumExtent.isFinite,
              minimumExtent > 0 else { return 0.01 }
        return max(0.01, weightDelta(
            pointDelta: minimumExtent,
            availableExtent: availableExtent,
            totalWeight: totalWeight
        ))
    }

    /// Normal navigation focuses an already-visible card. A session that is not
    /// visible replaces only the primary slot, retaining every deliberate split.
    mutating func focus(_ sessionID: String) {
        guard !sessionID.isEmpty, !contains(sessionID) else { return }
        guard !columns.isEmpty, !columns[0].sessionIDs.isEmpty else {
            columns = [Column(sessionIDs: [sessionID])]
            return
        }
        columns[0].sessionIDs[0] = sessionID
        columns[0].reconcileWeights()
        normalize()
    }

    /// Explicit "open beside" uses readable defaults: the second card opens to
    /// the right; later cards balance into the shorter of at most two columns.
    mutating func add(_ sessionID: String) {
        guard !sessionID.isEmpty, !contains(sessionID), sessionIDs.count < Self.maximumPaneCount else { return }
        if columns.isEmpty {
            columns = [Column(sessionIDs: [sessionID])]
        } else if columns.count == 1 {
            columns.append(Column(sessionIDs: [sessionID], weight: columns[0].weight))
        } else {
            let target = columns.indices.min { lhs, rhs in
                columns[lhs].sessionIDs.count < columns[rhs].sessionIDs.count
            } ?? columns.startIndex
            columns[target].sessionIDs.append(sessionID)
            columns[target].reconcileWeights()
        }
        normalize()
    }

    mutating func remove(_ sessionID: String) {
        for index in columns.indices {
            columns[index].sessionIDs.removeAll { $0 == sessionID }
            columns[index].reconcileWeights()
        }
        columns.removeAll { $0.sessionIDs.isEmpty }
        normalize()
    }

    /// Replace one visible surface in place without disturbing the user's
    /// split geometry. Reopening an exited terminal creates a new broker/PTY
    /// identity, but it should still occupy the exact row and column the ended
    /// card occupied rather than replacing an unrelated primary pane.
    @discardableResult
    mutating func replace(_ sessionID: String, with replacementID: String) -> Bool {
        guard !sessionID.isEmpty,
              !replacementID.isEmpty,
              sessionID != replacementID,
              !contains(replacementID),
              let columnIndex = columns.firstIndex(where: { $0.sessionIDs.contains(sessionID) }),
              let rowIndex = columns[columnIndex].sessionIDs.firstIndex(of: sessionID) else {
            return false
        }
        columns[columnIndex].sessionIDs[rowIndex] = replacementID
        normalize()
        return true
    }

    /// Reposition a card at the nearest edge of another card. Horizontal edges
    /// make columns; vertical edges make stacks. The moved card keeps running.
    mutating func place(_ sessionID: String, relativeTo targetID: String, edge: Edge) {
        guard !sessionID.isEmpty, sessionID != targetID else { return }
        let wasPresent = contains(sessionID)
        if wasPresent { remove(sessionID) }
        guard let targetColumn = columns.firstIndex(where: { $0.sessionIDs.contains(targetID) }),
              let targetRow = columns[targetColumn].sessionIDs.firstIndex(of: targetID) else {
            add(sessionID)
            return
        }

        switch edge {
        case .left, .right:
            let insertion = targetColumn + (edge == .right ? 1 : 0)
            let targetWeight = columns[targetColumn].weight
            columns.insert(Column(sessionIDs: [sessionID], weight: targetWeight), at: insertion)
        case .top, .bottom:
            let insertion = targetRow + (edge == .bottom ? 1 : 0)
            columns[targetColumn].sessionIDs.insert(sessionID, at: insertion)
            columns[targetColumn].reconcileWeights()
        }
        normalize()
    }

    mutating func resizeColumns(boundary: Int, delta: Double, minimumWeight: Double) {
        guard boundary >= 0, boundary + 1 < columns.count else { return }
        let left = columns[boundary].weight
        let right = columns[boundary + 1].weight
        let minimum = max(0.01, min(minimumWeight, (left + right) / 2))
        let shift = max(-(left - minimum), min(right - minimum, delta))
        columns[boundary].weight = left + shift
        columns[boundary + 1].weight = right - shift
    }

    mutating func resizeRows(
        columnID: String,
        boundary: Int,
        delta: Double,
        minimumWeight: Double
    ) {
        guard let columnIndex = columns.firstIndex(where: { $0.id == columnID }),
              boundary >= 0,
              boundary + 1 < columns[columnIndex].rowWeights.count else { return }
        let top = columns[columnIndex].rowWeights[boundary]
        let bottom = columns[columnIndex].rowWeights[boundary + 1]
        let minimum = max(0.01, min(minimumWeight, (top + bottom) / 2))
        let shift = max(-(top - minimum), min(bottom - minimum, delta))
        columns[columnIndex].rowWeights[boundary] = top + shift
        columns[columnIndex].rowWeights[boundary + 1] = bottom - shift
    }

    mutating func resetColumnWeights() {
        for index in columns.indices { columns[index].weight = 1 }
    }

    mutating func resetRowWeights(columnID: String) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        columns[index].rowWeights = Array(repeating: 1, count: columns[index].sessionIDs.count)
    }

    /// Drop stale/duplicate ids when restoring a snapshot after sessions close.
    mutating func normalize(availableSessionIDs: Set<String>? = nil) {
        var seen = Set<String>()
        var remaining = Self.maximumPaneCount
        var normalized: [Column] = []
        for var column in columns where remaining > 0 {
            column.sessionIDs = column.sessionIDs.filter { id in
                guard !id.isEmpty,
                      availableSessionIDs?.contains(id) ?? true,
                      !seen.contains(id),
                      remaining > 0 else { return false }
                seen.insert(id)
                remaining -= 1
                return true
            }
            guard !column.sessionIDs.isEmpty else { continue }
            if normalized.contains(where: { $0.id == column.id }) {
                column.id = UUID().uuidString.lowercased()
            }
            column.reconcileWeights()
            normalized.append(column)
        }
        columns = normalized
    }
}

/// Keyboard traversal of the visible panes.
///
/// `SessionPaneLayout.sessionIDs` is already in reading order (columns left to
/// right, rows top to bottom), which is the order a user expects an arrow to
/// follow. Both directions wrap, and an unknown or absent current pane starts
/// from the appropriate end rather than making the command silently do nothing.
enum PaneFocusCycle {
    static func target(after current: String?, in ids: [String], forward: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return forward ? ids.first : ids.last
        }
        let count = ids.count
        return ids[forward ? (index + 1) % count : (index - 1 + count) % count]
    }

}

/// A repeatable request, not a Boolean focus state. Selecting an already-active
/// Chat or Mesh from its header must be able to focus its composer again, so a
/// monotonically increasing generation makes every explicit request observable.
struct SurfaceKeyboardFocusRequest: Equatable, Sendable {
    let targetID: String
    let generation: UInt64
}
