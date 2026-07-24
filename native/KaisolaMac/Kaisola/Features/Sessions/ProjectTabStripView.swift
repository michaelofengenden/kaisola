import SwiftUI
import UniformTypeIdentifiers

/// A horizontal strip of project tabs for the top-bar layout. Chats, Mesh runs,
/// and terminals live in the active project's surface strip underneath instead
/// of floating in a global bucket. Clicking a tab makes it the active project;
/// **dragging** a tab with
/// the pointer reorders it live (the reorder-on-hover pattern), replacing the
/// former Move Left / Move Right menu items. Tabs use a softly bordered,
/// continuous-corner treatment shared with session/file surfaces rather than
/// floating text chips.
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(projects) { project in
                    Button {
                        selected = project.id
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
                    .id(project.id)
                    }
                    Button(action: openFolder) {
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
                    .help("Open a folder as a project (⌘O)")
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
            if project.workingCount > 0 {
                Text("\(project.workingCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4)
                    .background(Color.accentColor.opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(selected == project.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(
                            selected == project.id
                                ? Color.accentColor.opacity(0.30)
                                : Color.primary.opacity(0.075),
                            lineWidth: 0.8
                        )
                }
                .shadow(color: .black.opacity(selected == project.id ? 0.06 : 0.025), radius: 2, y: 1)
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
