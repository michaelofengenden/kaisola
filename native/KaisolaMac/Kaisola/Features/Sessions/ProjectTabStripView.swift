import SwiftUI
import UniformTypeIdentifiers

/// A horizontal strip of project tabs for the top-bar layout. Chats, Mesh runs,
/// and terminals live in the active project's surface strip underneath instead
/// of floating in a global bucket. Clicking a tab makes it the active project;
/// **dragging** a tab with
/// the pointer reorders it live (the reorder-on-hover pattern), replacing the
/// former Move Left / Move Right menu items.
///
/// A drop-in replacement for the former `ProjectTabStrip`: identical inputs
/// (plus `reorder`) and byte-for-byte identical chip visuals — tint dot,
/// working-count badge, selected capsule, and "+" button all keep
/// the same fonts, paddings, and 40 pt strip height.
struct ProjectTabStripView: View {
    let projects: [AppModel.ProjectGroup]
    @Binding var selected: String?
    let menu: (AppModel.ProjectGroup) -> AnyView
    let openFolder: () -> Void
    /// Persist a pointer drag-reorder: move project `id` to absolute `toIndex`
    /// in the project order. Wired to `AppModel.moveProject(id:toIndex:)`.
    let reorder: (_ id: String, _ toIndex: Int) -> Void

    /// The id of the tab currently being dragged, or nil when idle. Set when a
    /// drag begins and read by the drop delegates while hovering. A stale value
    /// left by a cancelled drag is harmless — every new drag overwrites it
    /// before any hover can act on it.
    @State private var draggingID: String? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(projects) { project in
                    Button {
                        selected = project.name
                    } label: {
                        chipLabel(project)
                    }
                    .buttonStyle(.plain)
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
                }
                Button(action: openFolder) {
                    Image(systemName: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .help("Open a folder as a project (⌘O)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 40)
    }

    /// The chip contents — a pixel-for-pixel copy of the former `ProjectTabStrip`
    /// button label. Kept separate only so the enclosing `Button` can carry the
    /// drag and drop modifiers.
    @ViewBuilder
    private func chipLabel(_ project: AppModel.ProjectGroup) -> some View {
        HStack(spacing: 5) {
            if let tint = ProjectTint.color(project.colorHex) {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(project.name)
                .font(.callout.weight(selected == project.name ? .semibold : .regular))
            if project.workingCount > 0 {
                Text("\(project.workingCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4)
                    .background(Color.accentColor.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            selected == project.name ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear),
            in: Capsule()
        )
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
