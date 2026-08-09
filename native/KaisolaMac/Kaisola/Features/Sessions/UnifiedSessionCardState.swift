import Foundation

/// Project-scoped presentation state for the unified terminal, chat, and Mesh
/// cards rendered by `RootShellView`.
///
/// AppModel still owns broker and adapter side effects. This value owns the
/// synchronous card transitions those effects publish: geometry, focused card,
/// maximized presentation, and repeatable keyboard-focus requests.
struct UnifiedSessionCardState: Equatable, Sendable {
    private(set) var layouts: [String: SessionPaneLayout]
    private(set) var focusedPaneID: String?
    private(set) var maximizedPaneID: String?
    private(set) var keyboardFocusRequest: SurfaceKeyboardFocusRequest?
    private var keyboardFocusGeneration: UInt64

    init(
        layouts: [String: SessionPaneLayout] = [:],
        focusedPaneID: String? = nil,
        maximizedPaneID: String? = nil,
        keyboardFocusRequest: SurfaceKeyboardFocusRequest? = nil
    ) {
        self.layouts = layouts
        self.focusedPaneID = focusedPaneID
        self.maximizedPaneID = maximizedPaneID
        self.keyboardFocusRequest = keyboardFocusRequest
        keyboardFocusGeneration = keyboardFocusRequest?.generation ?? 0
    }

    var projectIDs: Set<String> { Set(layouts.keys) }

    func layout(for projectID: String?) -> SessionPaneLayout {
        guard let projectID else { return SessionPaneLayout() }
        return layouts[projectID] ?? SessionPaneLayout()
    }

    func contains(_ surfaceID: String, in projectID: String) -> Bool {
        layouts[projectID]?.contains(surfaceID) == true
    }

    mutating func focus(_ surfaceID: String, in projectID: String) {
        var layout = layout(for: projectID)
        layout.focus(surfaceID)
        layouts[projectID] = layout
        focusedPaneID = surfaceID
        maximizedPaneID = nil
    }

    mutating func revealBeside(_ surfaceID: String, in projectID: String) {
        var layout = layout(for: projectID)
        layout.add(surfaceID)
        layouts[projectID] = layout
        focusedPaneID = surfaceID
        maximizedPaneID = nil
    }

    mutating func place(
        _ surfaceID: String,
        relativeTo targetID: String,
        edge: SessionPaneLayout.Edge,
        in projectID: String
    ) {
        var layout = layout(for: projectID)
        layout.place(surfaceID, relativeTo: targetID, edge: edge)
        layouts[projectID] = layout
        focusedPaneID = surfaceID
        maximizedPaneID = nil
    }

    mutating func resizeColumns(
        in projectID: String,
        boundary: Int,
        delta: Double,
        minimumWeight: Double
    ) {
        guard var layout = layouts[projectID] else { return }
        layout.resizeColumns(boundary: boundary, delta: delta, minimumWeight: minimumWeight)
        layouts[projectID] = layout
    }

    mutating func resizeRows(
        in projectID: String,
        columnID: String,
        boundary: Int,
        delta: Double,
        minimumWeight: Double
    ) {
        guard var layout = layouts[projectID] else { return }
        layout.resizeRows(
            columnID: columnID,
            boundary: boundary,
            delta: delta,
            minimumWeight: minimumWeight
        )
        layouts[projectID] = layout
    }

    mutating func resetColumns(in projectID: String) {
        guard var layout = layouts[projectID] else { return }
        layout.resetColumnWeights()
        layouts[projectID] = layout
    }

    mutating func resetRows(in projectID: String, columnID: String) {
        guard var layout = layouts[projectID] else { return }
        layout.resetRowWeights(columnID: columnID)
        layouts[projectID] = layout
    }

    mutating func toggleMaximize(_ surfaceID: String) {
        maximizedPaneID = maximizedPaneID == surfaceID ? nil : surfaceID
        focusedPaneID = surfaceID
    }

    @discardableResult
    mutating func remove(_ surfaceID: String, from projectID: String) -> SessionPaneLayout? {
        guard var layout = layouts[projectID] else { return nil }
        layout.remove(surfaceID)
        layouts[projectID] = layout
        if focusedPaneID == surfaceID { focusedPaneID = layout.sessionIDs.first }
        if maximizedPaneID == surfaceID { maximizedPaneID = nil }
        return layout
    }

    mutating func move(_ surfaceID: String, from sourceProjectID: String, to targetProjectID: String) {
        var source = layout(for: sourceProjectID)
        source.remove(surfaceID)
        layouts[sourceProjectID] = source

        var target = layout(for: targetProjectID)
        if !target.contains(surfaceID) { target.add(surfaceID) }
        layouts[targetProjectID] = target
        focusedPaneID = surfaceID
        maximizedPaneID = nil
    }

    @discardableResult
    mutating func reconcile(_ projectID: String, availableSurfaceIDs: Set<String>) -> Bool {
        guard var layout = layouts[projectID] else { return false }
        let previous = layout
        layout.normalize(availableSessionIDs: availableSurfaceIDs)
        guard layout != previous else { return false }

        let removed = Set(previous.sessionIDs).subtracting(layout.sessionIDs)
        layouts[projectID] = layout
        if let focusedPaneID, removed.contains(focusedPaneID) {
            self.focusedPaneID = layout.sessionIDs.first
        }
        if let maximizedPaneID, removed.contains(maximizedPaneID) {
            self.maximizedPaneID = nil
        }
        return true
    }

    func isVisible(_ surfaceID: String) -> Bool {
        layouts.values.contains { $0.contains(surfaceID) }
    }

    mutating func install(_ layout: SessionPaneLayout, for projectID: String) {
        layouts[projectID] = layout
    }

    mutating func add(_ surfaceID: String, to projectID: String) {
        var layout = layout(for: projectID)
        layout.add(surfaceID)
        layouts[projectID] = layout
    }

    @discardableResult
    mutating func restoreFocus(_ surfaceID: String, in projectID: String) -> Bool {
        guard contains(surfaceID, in: projectID) else { return false }
        focusedPaneID = surfaceID
        return true
    }

    mutating func focusPresentation(on surfaceID: String?) {
        focusedPaneID = surfaceID
    }

    mutating func clearFocus(ifMatching surfaceID: String) {
        if focusedPaneID == surfaceID { focusedPaneID = nil }
    }

    @discardableResult
    mutating func requestKeyboardFocus(for surfaceID: String) -> SurfaceKeyboardFocusRequest {
        keyboardFocusGeneration &+= 1
        let request = SurfaceKeyboardFocusRequest(
            targetID: surfaceID,
            generation: keyboardFocusGeneration
        )
        keyboardFocusRequest = request
        return request
    }

    @discardableResult
    mutating func replace(
        _ surfaceID: String,
        with replacementID: String,
        in projectID: String,
        fallback: SessionPaneLayout? = nil
    ) -> Bool {
        guard var layout = layouts[projectID] ?? fallback,
              layout.replace(surfaceID, with: replacementID) else { return false }
        layouts[projectID] = layout
        focusedPaneID = replacementID
        if maximizedPaneID == surfaceID { maximizedPaneID = replacementID }
        return true
    }
}
