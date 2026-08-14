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

/// A horizontal strip of project tabs for the top-bar layout. Chats, Mesh runs,
/// and terminals live in the active project's surface strip underneath instead
/// of floating in a global bucket. Clicking a tab makes it the active project;
/// pointer drag and the tab's keyboard/assistive actions both persist through
/// the same absolute-index reorder callback. Tabs use a softly bordered,
/// continuous-corner treatment shared with session/file surfaces.
struct ProjectTabStripView: View {
    let projects: [AppModel.ProjectGroup]
    @Binding var selected: String?
    let menu: (AppModel.ProjectGroup) -> AnyView
    let newSession: (AppModel.ProjectGroup) -> Void
    let useSidebar: () -> Void
    /// Persist a pointer drag-reorder: move project `id` to absolute `toIndex`
    /// in the project order. Wired to `AppModel.moveProject(id:toIndex:)`.
    let reorder: (_ id: String, _ toIndex: Int) -> Void

    /// The id of the tab currently being dragged, or nil when idle. Set when a
    /// drag begins and read by the drop delegates while hovering. A stale value
    /// left by a cancelled drag is harmless — every new drag overwrites it
    /// before any hover can act on it.
    @State private var draggingID: String? = nil

    var body: some View {
        let selectedProject = projects.first { $0.id == selected }
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        let directions = ProjectTabReorder.availableDirections(
                            index: index,
                            count: projects.count
                        )
                        Button {
                            selected = project.id
                        } label: {
                            chipLabel(project)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(projectAccessibilityLabel(project))
                        .accessibilityValue(
                            ProjectTabReorder.positionDescription(
                                index: index,
                                count: projects.count
                            ) ?? ""
                        )
                        .accessibilityAddTraits(selected == project.id ? .isSelected : [])
                        .accessibilityActions {
                            if directions.contains(.left) {
                                Button("Move Left") { reorderProject(project, direction: .left) }
                            }
                            if directions.contains(.right) {
                                Button("Move Right") { reorderProject(project, direction: .right) }
                            }
                        }
                        .contextMenu { menu(project) }
                        .onDrag {
                            draggingID = project.id
                            return NSItemProvider(object: project.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: ProjectTabDropDelegate(
                                target: project,
                                projects: projects,
                                draggingID: $draggingID,
                                reorder: reorder
                            )
                        )
                        .id(project.id)
                    }
                    Button {
                        guard let selectedProject, selectedProject.directory != nil else { return }
                        newSession(selectedProject)
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.04), in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedProject?.directory == nil)
                    .help(
                        selectedProject.map { project in
                            project.directory == nil
                                ? "Locate this project before starting a session"
                                : "New session in \(project.name)"
                        } ?? "Open a project before starting a session"
                    )
                    .accessibilityLabel(
                        selectedProject.map { "New session in \($0.name)" }
                            ?? "New session"
                    )
                    .accessibilityHint(
                        selectedProject?.directory == nil
                            ? "A project with an available folder is required."
                            : "Opens a temporary tab for choosing a session type."
                    )
                    Button(action: useSidebar) {
                        Image(systemName: "sidebar.left")
                            .font(.caption.weight(.semibold))
                            .frame(width: 26, height: 26)
                            .background(Color.primary.opacity(0.04), in: Circle())
                            .overlay {
                                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Move projects and sessions to the sidebar")
                    .accessibilityLabel("Use sidebar navigation")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: 36)
    }

    /// Kept separate so the enclosing `Button` can carry drag/drop modifiers.
    @ViewBuilder
    private func chipLabel(_ project: AppModel.ProjectGroup) -> some View {
        HStack(spacing: 5) {
            if let tint = ProjectTint.color(project.colorHex) {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(project.name)
                .font(.callout.weight(selected == project.id ? .semibold : .regular))
            if project.attentionCount > 0 {
                KaisolaStatusBadge(
                    text: "\(project.attentionCount)",
                    systemImage: "exclamationmark",
                    tone: .needsYou
                )
            } else if project.workingCount > 0 {
                KaisolaStatusBadge(
                    text: "\(project.workingCount)",
                    systemImage: "hourglass",
                    tone: .working
                )
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius, style: .continuous)
                .fill(selected == project.id ? Color.primary.opacity(0.075) : Color.primary.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: KaisolaVisualSystem.controlRadius, style: .continuous)
                        .stroke(
                            selected == project.id
                                ? (ProjectTint.color(project.colorHex) ?? WorkspacePalette.project)
                                    .opacity(SurfaceTabChrome.projectSelectedStrokeOpacity)
                                : Color.primary.opacity(SurfaceTabChrome.inactiveStrokeOpacity),
                            lineWidth: KaisolaVisualSystem.hairline
                        )
                }
        }
    }

    private func projectAccessibilityLabel(_ project: AppModel.ProjectGroup) -> String {
        if project.attentionCount > 0 {
            let noun = project.attentionCount == 1 ? "item" : "items"
            return "\(project.name), \(project.attentionCount) \(noun) needing attention"
        }
        if project.workingCount > 0 {
            let noun = project.workingCount == 1 ? "session" : "sessions"
            return "\(project.name), \(project.workingCount) \(noun) working"
        }
        return project.name
    }

    private func reorderProject(
        _ project: AppModel.ProjectGroup,
        direction: ProjectTabReorder.Direction
    ) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        ProjectTabReorder.perform(
            projectID: project.id,
            projectName: project.name,
            index: index,
            count: projects.count,
            direction: direction,
            reorder: reorder
        ) { announcement in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }
}

/// Reorder-on-hover drop target for one project chip. While another tab is
/// dragged, entering this chip's slot moves the dragged tab to this chip's
/// current index; the parent persists it and republishes `projects`, which
/// re-lays out the strip so the tabs visibly swap under the pointer.
private struct ProjectTabDropDelegate: DropDelegate {
    let target: AppModel.ProjectGroup
    let projects: [AppModel.ProjectGroup]
    @Binding var draggingID: String?
    let reorder: (_ id: String, _ toIndex: Int) -> Void

    /// Only accept our own tab drags (draggingID set by `.onDrag`), never a
    /// stray text/file drop from elsewhere.
    func validateDrop(info: DropInfo) -> Bool {
        draggingID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != target.id,
              let toIndex = projects.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            reorder(dragging, toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
