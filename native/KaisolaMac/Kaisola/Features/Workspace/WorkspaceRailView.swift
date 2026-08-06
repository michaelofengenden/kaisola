import AppKit
import SwiftUI

/// The workspace rail: a lazy file tree for the active project (⌘B). Clicking a
/// file opens it in the preview pane.
struct WorkspaceRailView: View {
    private enum CreationKind: String, Sendable {
        case file = "File"
        case folder = "Folder"
    }

    private struct CreationRequest: Identifiable, Sendable {
        let id = UUID()
        let kind: CreationKind
        let parent: URL
    }

    @EnvironmentObject private var settings: NativePreviewSettings
    let root: URL
    let selectedFile: URL?
    let openFile: (URL, Bool) -> Void
    @Binding private var followsAgentFiles: Bool
    let canFollowAgentFiles: Bool
    let didMoveItem: (URL, URL) -> Void
    let didTrashItem: (WorkspaceFileOperations.TrashMove) -> Void
    let didCreateItem: (WorkspaceFileOperations.CreatedItem) -> Void
    let close: () -> Void

    @State private var expanded: Set<String> = []
    @State private var searchText = ""
    @State private var renameTarget: FileNode?
    @State private var renameDraft = ""
    @State private var moveTarget: FileNode?
    @State private var creationRequest: CreationRequest?
    @State private var creationDraft = ""
    @State private var trashTarget: FileNode?
    @State private var isMutating = false
    /// Live FSEvents watcher — agent writes refresh the tree automatically.
    @StateObject private var watcher: WorkspaceWatcher
    @StateObject private var tree: WorkspaceTreeModel

    init(
        root: URL,
        selectedFile: URL? = nil,
        openFile: @escaping (URL, Bool) -> Void,
        followsAgentFiles: Binding<Bool> = .constant(false),
        canFollowAgentFiles: Bool = false,
        didMoveItem: @escaping (URL, URL) -> Void,
        didTrashItem: @escaping (WorkspaceFileOperations.TrashMove) -> Void,
        didCreateItem: @escaping (WorkspaceFileOperations.CreatedItem) -> Void,
        close: @escaping () -> Void
    ) {
        self.root = root
        self.selectedFile = selectedFile?.standardizedFileURL
        self.openFile = openFile
        _followsAgentFiles = followsAgentFiles
        self.canFollowAgentFiles = canFollowAgentFiles
        self.didMoveItem = didMoveItem
        self.didTrashItem = didTrashItem
        self.didCreateItem = didCreateItem
        self.close = close
        _watcher = StateObject(wrappedValue: WorkspaceWatcher(root: root))
        _tree = StateObject(wrappedValue: WorkspaceTreeModel(root: root))
    }

    var body: some View {
        AnyView(VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: close) {
                    Image(systemName: "sidebar.trailing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Hide \(root.lastPathComponent) files (Command-B)")
                .accessibilityLabel("Hide Files")
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search files", text: $searchText)
                    .textFieldStyle(.plain)
                Menu {
                    Button("New File…") { beginCreate(.file, in: root) }
                    Button("New Folder…") { beginCreate(.folder, in: root) }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New file or folder")
                .accessibilityLabel("New project item")
                Button {
                    followsAgentFiles.toggle()
                } label: {
                    Image(systemName: "scope")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(followsAgentFiles ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!canFollowAgentFiles)
                .help(canFollowAgentFiles
                    ? (followsAgentFiles ? "Stop following the selected agent's files" : "Follow the selected agent's files")
                    : "Select a Chat or Mesh to follow its files")
                .accessibilityLabel("Follow selected agent files")
                .accessibilityValue(followsAgentFiles ? "On" : "Off")
                Button(action: { refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh files")
                if isMutating {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Updating project files")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        nodeRows(for: root, depth: 0)
                    }
                    .padding(.vertical, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else if tree.isSearching {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Indexing files…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tree.searchResults.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(tree.searchResults, id: \.self) { path in
                            Button {
                                openFile(root.appendingPathComponent(path), false)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    FadingFileName(text: path)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .padding(.trailing, Self.optionsClearance - 10)
                                .background(
                                    selectedFile?.standardizedFileURL.path
                                        == root.appendingPathComponent(path).standardizedFileURL.path
                                        ? Color.accentColor.opacity(0.15)
                                        : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(path)
                            .overlay(alignment: .trailing) {
                                itemMenu(FileNode(
                                    url: root.appendingPathComponent(path).standardizedFileURL,
                                    isDirectory: false
                                ))
                                .padding(.trailing, 6)
                            }
                            .contextMenu {
                                itemActions(FileNode(
                                    url: root.appendingPathComponent(path).standardizedFileURL,
                                    isDirectory: false
                                ))
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        // The persisted preference stays at least 164 pt, but the responsive
        // shell may temporarily compress Files to 150 pt at minimum window size.
        .frame(minWidth: 150, maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SidebarBackdropView(appearance: settings.sidebarAppearance)
        }
        .clipShape(RoundedRectangle(cornerRadius: KaisolaVisualSystem.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: KaisolaVisualSystem.panelRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.52), lineWidth: 0.65)
        }
        .padding(4)
        .task {
            tree.load(root)
            revealSelection()
            // Deterministic broker-free visual QA: present a real file-action
            // sheet over the real lazy tree without mutating any fixture file.
            if ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_FIXTURE"] == "1",
               let surface = ProcessInfo.processInfo.environment["KAISOLA_NATIVE_VISUAL_SURFACE"],
               surface == "workspace-rename" || surface == "workspace-new-file"
                || surface == "workspace-move" {
                for _ in 0..<20 {
                    if let first = tree.children(of: root)?.first {
                        if surface == "workspace-new-file" {
                            beginCreate(.file, in: first.isDirectory ? first.url : root)
                        } else if surface == "workspace-move" {
                            beginMove(first)
                        } else {
                            beginRename(first)
                        }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        .onChange(of: selectedFile?.standardizedFileURL.path) { _, _ in
            revealSelection()
        }
        .onChange(of: searchText) { _, query in tree.search(query) }
        .onChange(of: watcher.changeBatch) { _, batch in
            tree.refresh(
                changeBatch: batch,
                expandedDirectories: expanded.map { URL(fileURLWithPath: $0, isDirectory: true) }
            )
            tree.search(searchText)
        }
        .contextMenu {
            Button("New File…") { beginCreate(.file, in: root) }
                .disabled(isMutating)
            Button("New Folder…") { beginCreate(.folder, in: root) }
                .disabled(isMutating)
            Divider()
            Button("Refresh") { refresh() }
            Button("New AGENTS.md") {
                let target = root.appendingPathComponent("AGENTS.md")
                if !FileManager.default.fileExists(atPath: target.path) {
                    try? Self.agentsTemplate.write(to: target, atomically: true, encoding: .utf8)
                    ProjectFileIndex.shared.invalidate(root: root)
                    tree.refresh(expandedDirectories: expanded.map { URL(fileURLWithPath: $0, isDirectory: true) })
                }
                openFile(target, true)
            }
        }
        .alert(
            "Rename \(renameTarget?.isDirectory == true ? "Folder" : "File")",
            isPresented: renamePresented
        ) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { performRename() }
                .disabled(renameDraft.isEmpty || isMutating)
        } message: {
            Text("Enter a new name for \(renameTarget?.name ?? "this item").")
        })
        .sheet(item: $moveTarget) { target in
            WorkspaceMoveSheet(root: root, item: target) { destinationDirectory in
                performMove(target, to: destinationDirectory)
            }
        }
        .alert(
            "New \(creationRequest?.kind.rawValue ?? "Item")",
            isPresented: creationPresented
        ) {
            TextField("Name", text: $creationDraft)
            Button("Cancel", role: .cancel) { creationRequest = nil }
            Button("Create") { performCreate() }
                .keyboardShortcut(.defaultAction)
                .disabled(creationDraft.isEmpty || isMutating)
        } message: {
            Text("Create it inside \(creationRequest?.parent.lastPathComponent ?? root.lastPathComponent).")
        }
        .confirmationDialog(
            "Move \(trashTarget?.name ?? "item") to Trash?",
            isPresented: trashPresented
        ) {
            Button("Move to Trash", role: .destructive) { performTrash() }
                .disabled(isMutating)
            Button("Cancel", role: .cancel) { trashTarget = nil }
        } message: {
            Text("This is recoverable from the macOS Trash.")
        }
        .accessibilityLabel("Project files")
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var trashPresented: Binding<Bool> {
        Binding(
            get: { trashTarget != nil },
            set: { if !$0 { trashTarget = nil } }
        )
    }

    private var creationPresented: Binding<Bool> {
        Binding(
            get: { creationRequest != nil },
            set: { if !$0 { creationRequest = nil } }
        )
    }

    private func refresh(changedPaths: [URL]? = nil) {
        let expandedDirectories = expanded.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let changedPaths {
            ProjectFileIndex.shared.invalidate(
                root: root,
                changedPaths: changedPaths,
                requiresFullRefresh: false
            )
            tree.refresh(
                changeBatch: WorkspaceChangeBatch(
                    token: 0,
                    paths: changedPaths,
                    requiresFullRefresh: false
                ),
                expandedDirectories: expandedDirectories
            )
        } else {
            ProjectFileIndex.shared.invalidate(root: root)
            tree.refresh(expandedDirectories: expandedDirectories)
        }
        tree.search(searchText)
    }

    private func revealSelection() {
        guard let selectedFile else { return }
        let normalizedRoot = root.standardizedFileURL
        let normalizedFile = selectedFile.standardizedFileURL
        let prefix = normalizedRoot.path.hasSuffix("/")
            ? normalizedRoot.path
            : normalizedRoot.path + "/"
        guard normalizedFile.path.hasPrefix(prefix) else { return }

        var directory = normalizedFile.deletingLastPathComponent()
        while directory.path != normalizedRoot.path,
              directory.path.hasPrefix(prefix) {
            expanded.insert(directory.path)
            tree.load(directory)
            directory = directory.deletingLastPathComponent()
        }
        tree.load(normalizedRoot)
    }

    private func beginRename(_ node: FileNode) {
        guard !isMutating else { return }
        renameDraft = node.name
        renameTarget = node
    }

    private func beginCreate(_ kind: CreationKind, in parent: URL) {
        guard !isMutating else { return }
        creationDraft = ""
        creationRequest = CreationRequest(kind: kind, parent: parent.standardizedFileURL)
    }

    private func beginMove(_ node: FileNode) {
        guard !isMutating else { return }
        moveTarget = node
    }

    private func beginTrash(_ node: FileNode) {
        guard !isMutating else { return }
        trashTarget = node
    }

    @MainActor
    private func prepareMutation(_ node: FileNode) -> Bool {
        let request = WorkspaceFileMutationBarrierRequest(item: node.url)
        NotificationCenter.default.post(name: .kaisolaPrepareWorkspaceFileMutation, object: request)
        guard request.mayProceed else {
            ToastCenter.shared.show(
                "Resolve the unsaved changes in \(node.name) before changing it.",
                style: .error
            )
            return false
        }
        return true
    }

    private func performRename() {
        guard let target = renameTarget, prepareMutation(target) else { return }
        let proposedName = renameDraft
        let root = self.root
        isMutating = true
        Task {
            do {
                let move = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceFileOperations.rename(
                        item: target.url,
                        to: proposedName,
                        workspaceRoot: root
                    )
                }.value
                didMoveItem(move.source, move.destination)
                expanded = Set(expanded.map { path in
                    WorkspaceFileOperations.replacingPrefix(
                        of: URL(fileURLWithPath: path),
                        from: move.source,
                        to: move.destination
                    )?.path ?? path
                })
                renameTarget = nil
                refresh(changedPaths: [move.source, move.destination])
                ToastCenter.shared.show("Renamed to \(move.destination.lastPathComponent)", style: .success)
            } catch {
                ToastCenter.shared.show(
                    WorkspaceFileOperations.userFacingDescription(for: error, action: "rename"),
                    style: .error,
                    duration: 5
                )
            }
            isMutating = false
        }
    }

    @discardableResult
    private func performMove(_ target: FileNode, to destinationDirectory: URL) -> Bool {
        guard prepareMutation(target) else { return false }
        let destination = destinationDirectory.appendingPathComponent(
            target.name,
            isDirectory: target.isDirectory
        )
        let root = self.root
        isMutating = true
        Task {
            do {
                let move = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceFileOperations.move(
                        item: target.url,
                        to: destination,
                        workspaceRoot: root
                    )
                }.value
                didMoveItem(move.source, move.destination)
                expanded = Set(expanded.map { path in
                    WorkspaceFileOperations.replacingPrefix(
                        of: URL(fileURLWithPath: path),
                        from: move.source,
                        to: move.destination
                    )?.path ?? path
                })
                refresh(changedPaths: [move.source, move.destination])
                ToastCenter.shared.show(
                    "Moved \(target.name) to \(destinationDirectory.lastPathComponent)",
                    style: .success
                )
            } catch {
                ToastCenter.shared.show(
                    WorkspaceFileOperations.userFacingDescription(for: error, action: "move"),
                    style: .error,
                    duration: 5
                )
            }
            isMutating = false
        }
        return true
    }

    private func performCreate() {
        guard let request = creationRequest else { return }
        let proposedName = creationDraft
        let root = self.root
        isMutating = true
        Task {
            do {
                let created = try await Task.detached(priority: .userInitiated) {
                    switch request.kind {
                    case .file:
                        try WorkspaceFileOperations.createFile(
                            named: proposedName,
                            in: request.parent,
                            workspaceRoot: root
                        )
                    case .folder:
                        try WorkspaceFileOperations.createFolder(
                            named: proposedName,
                            in: request.parent,
                            workspaceRoot: root
                        )
                    }
                }.value
                didCreateItem(created)
                expanded.insert(request.parent.path)
                if created.kind == .folder {
                    expanded.insert(created.url.path)
                    tree.load(created.url)
                } else {
                    openFile(created.url, true)
                }
                creationRequest = nil
                refresh()
                ToastCenter.shared.show("Created \(created.url.lastPathComponent)", style: .success)
            } catch {
                ToastCenter.shared.show(
                    WorkspaceFileOperations.userFacingDescription(for: error, action: "create"),
                    style: .error,
                    duration: 5
                )
            }
            isMutating = false
        }
    }

    private func performTrash() {
        guard let target = trashTarget, prepareMutation(target) else { return }
        let root = self.root
        isMutating = true
        Task {
            do {
                let move = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceFileOperations.moveToTrash(item: target.url, workspaceRoot: root)
                }.value
                didTrashItem(move)
                expanded = Set(expanded.filter {
                    !WorkspaceFileOperations.contains(URL(fileURLWithPath: $0), in: target.url)
                })
                trashTarget = nil
                refresh()
                ToastCenter.shared.show("Moved \(target.name) to Trash", style: .success)
            } catch {
                ToastCenter.shared.show(
                    WorkspaceFileOperations.userFacingDescription(for: error, action: "move to Trash"),
                    style: .error,
                    duration: 5
                )
            }
            isMutating = false
        }
    }

    /// Starter AGENTS.md dropped at the project root — the emerging convention
    /// agent CLIs read for repo-specific guidance. Opens the existing file
    /// instead when one is already there.
    static let agentsTemplate = """
    # AGENTS.md

    Guidance for AI agents working in this repository.

    ## Project overview

    Describe what this project is and how it fits together.

    ## Commands

    - Build:
    - Test:
    - Lint:

    ## Conventions

    Code style, structure, and review expectations agents should follow.
    """


    @ViewBuilder
    private func nodeRows(for directory: URL, depth: Int) -> some View {
        if let nodes = tree.children(of: directory) {
            ForEach(nodes) { node in
                nodeRow(node, depth: depth)
                if node.isDirectory, expanded.contains(node.id) {
                    AnyView(nodeRows(for: node.url, depth: depth + 1))
                }
            }
        } else {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.leading, CGFloat(depth) * 14 + 12)
            .padding(.vertical, 6)
            .task { tree.load(directory) }
        }
    }

    private func nodeRow(_ node: FileNode, depth: Int) -> some View {
        Button {
            if node.isDirectory {
                if expanded.contains(node.id) {
                    expanded.remove(node.id)
                } else {
                    expanded.insert(node.id)
                    tree.load(node.url)
                }
            } else {
                openFile(node.url, false)
            }
        } label: {
            HStack(spacing: 5) {
                if node.isDirectory {
                    Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: node.isDirectory ? "folder" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                fileName(node.name)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2.5)
            .padding(.leading, CGFloat(depth) * 14 + 10)
            // The options button is a trailing *overlay*, so it floats over
            // whatever the row draws. Without this the name ran under it and
            // its own "…" landed on the three dots, which at a zoomed text
            // size read as one smeared "⋯⋯". This is the button's 18pt plus
            // its 6pt inset, plus a little air.
            .padding(.trailing, Self.optionsClearance)
            .background(
                !node.isDirectory && selectedFile?.standardizedFileURL.path == node.url.standardizedFileURL.path
                    ? Color.accentColor.opacity(0.15)
                    : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(node.name)
        .id(node.id)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard !node.isDirectory else { return }
                openFile(node.url, true)
            }
        )
        .contextMenu {
            itemActions(node)
        }
        .overlay(alignment: .trailing) {
            itemMenu(node)
                .padding(.trailing, 6)
        }
    }

    /// Room kept clear at the trailing edge for the floating options button.
    private static let optionsClearance: CGFloat = 30

    private func fileName(_ name: String) -> some View {
        FadingFileName(text: name)
    }

    private func itemMenu(_ node: FileNode) -> some View {
        Menu {
            itemActions(node)
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("File options")
        .accessibilityLabel("Options for \(node.name)")
    }

    @ViewBuilder
    private func itemActions(_ node: FileNode) -> some View {
        let creationParent = node.isDirectory
            ? node.url
            : node.url.deletingLastPathComponent()
        Button("New File…") { beginCreate(.file, in: creationParent) }
            .disabled(isMutating)
        Button("New Folder…") { beginCreate(.folder, in: creationParent) }
            .disabled(isMutating)
        Divider()
        if !node.isDirectory {
            Button("Open") { openFile(node.url, false) }
            Button("Keep Open") { openFile(node.url, true) }
            Button("Copy Contents") { copyContents(of: node.url) }
            Divider()
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Divider()
        Button("Rename…") { beginRename(node) }
            .disabled(isMutating)
        Button("Move…") { beginMove(node) }
            .disabled(isMutating)
        Button("Move to Trash…", role: .destructive) { beginTrash(node) }
            .disabled(isMutating)
    }

    private func copyContents(of url: URL) {
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                WorkspaceFileClipboard.contents(of: url)
            }.value
            guard let text else {
                ToastCenter.shared.show("This file has no copyable text preview", style: .error)
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                ToastCenter.shared.show("Could not copy file contents", style: .error)
                return
            }
            ToastCenter.shared.show("Copied \(url.lastPathComponent)", style: .success)
        }
    }
}

private struct WorkspaceMoveSheet: View {
    @Environment(\.dismiss) private var dismiss

    let root: URL
    let item: FileNode
    let commit: (URL) -> Bool

    @State private var directories: [URL] = []
    @State private var selectedPath: String?
    @State private var searchText = ""
    @State private var isLoading = true

    private var visibleDirectories: [URL] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return directories }
        return directories.filter {
            destinationLabel($0).localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedDirectory: URL? {
        guard let selectedPath else { return nil }
        return visibleDirectories.first { $0.path == selectedPath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move \(item.name)")
                    .font(.title3.weight(.semibold))
                Text("Choose a folder inside \(root.lastPathComponent). The item will keep its name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("Search folders", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Group {
                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finding project folders…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleDirectories.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Other Folders" : "No Matching Folders",
                        systemImage: "folder.badge.minus",
                        description: Text(
                            searchText.isEmpty
                                ? "This item has no safe cross-directory destination."
                                : "Try a different folder search."
                        )
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(visibleDirectories, id: \.path) { directory in
                                let isSelected = selectedPath == directory.path
                                Button {
                                    selectedPath = directory.path
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: directory.path == root.standardizedFileURL.path
                                            ? "shippingbox"
                                            : "folder")
                                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                            .frame(width: 18)
                                        Text(destinationLabel(directory))
                                            .font(.callout)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        isSelected ? Color.accentColor.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Move destination \(destinationLabel(directory))")
                                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                            }
                        }
                        .padding(4)
                    }
                    .background(
                        Color(nsColor: .controlBackgroundColor).opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.65)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") {
                    guard let selectedDirectory, commit(selectedDirectory) else { return }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedDirectory == nil || isLoading)
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
        .task(id: item.id) {
            isLoading = true
            let root = root
            let movingItem = item.url
            let scan = Task.detached(priority: .utility) {
                ProjectFiles.moveDestinationDirectories(
                    root: root,
                    movingItem: movingItem
                )
            }
            let loaded = await scan.value
            guard !Task.isCancelled else { return }
            directories = loaded
            selectedPath = loaded.first?.path
            isLoading = false
        }
        .onChange(of: searchText) { _, _ in
            if selectedDirectory == nil {
                selectedPath = visibleDirectories.first?.path
            }
        }
    }

    private func destinationLabel(_ directory: URL) -> String {
        let root = root.standardizedFileURL
        let directory = directory.standardizedFileURL
        guard directory.path != root.path else {
            return "\(root.lastPathComponent) — Project Root"
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard directory.path.hasPrefix(prefix) else { return directory.lastPathComponent }
        return String(directory.path.dropFirst(prefix.count))
    }
}

/// A name too long for its rail **fades out** rather than truncating.
///
/// A tail "…" beside a "⋯" button is two ellipses in a row, and at a zoomed
/// text size they collide into something that reads as neither. A fade also
/// tells the truth better: it says the name continues, where "…" says three
/// specific characters were dropped. Michael: "the words shouldn't run into
/// the three dots, the words should fade a little before."
///
/// The layout participant is a *hidden* copy of the text, which compresses
/// like any label and so can never report an oversized minimum width up the
/// row. That was the original regression: a `fixedSize` name reported its full
/// ideal width as its minimum, the row grew past the rail's clip, and the
/// floating "⋯" anchored to the row's trailing edge was carried off-panel with
/// it. The visible copy is an overlay — outside layout entirely — clipped to
/// the row, and faded only when the name genuinely overflows, so a short name
/// whose tail happens to sit near the edge is not dimmed for no reason.
struct FadingFileName: View {
    let text: String
    /// How far the name's last characters take to fade out.
    var fadeWidth: CGFloat = 18

    @State private var textWidth: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    private var overflows: Bool { textWidth > availableWidth + 0.5 }

    var body: some View {
        Text(text)
            .font(.callout)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Text(text)
                    .font(.callout)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { textWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { availableWidth = $0 }
            .clipped()
            .mask(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(
                        colors: [.black, .black.opacity(overflows ? 0 : 1)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: fadeWidth)
                }
            }
    }
}

enum WorkspaceFileClipboard {
    static func contents(of url: URL) -> String? {
        switch FilePreviewContent.load(url: url) {
        case let .text(text), let .markdown(text), let .csv(text),
             let .json(text), let .html(text):
            text
        case .docx:
            RichDocumentIO.load(url: url)?.value.string
        case .pdf, .image, .tooLarge, .binary, .unreadable:
            nil
        }
    }
}
